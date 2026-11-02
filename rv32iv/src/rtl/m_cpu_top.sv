`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Structural RV32I+Zmmul 5-stage CPU wrapper. Connects the PC generator, decoder,
 *                register file, pipeline registers, ALU/branch/mul units, load/store unit,
 *                hazard unit and the VPU dispatch interface.
 *
 * Interface notes:
 *   - PARA_VLEN and PARA_LANE_COUNT do not reach the CPU: the VPU memory bus is routed by
 *     m_soc_bus, and the CPU only sees the 32-bit command/response group. m_cpu_top therefore
 *     has no overridable parameter.
 *   - o_imem_addr is the 32-bit fetch byte address; the IMEM wrapper uses bits [14:2] as the
 *     word index. The IMEM read is registered (1 cycle), so the fetch alignment registers below
 *     pair every returned word with the address it was read from. While the front end is held
 *     the last address is presented again, so no instruction is skipped.
 *   - Small glue logic (fetch alignment, forwarding muxes, EX result mux, code mapping between
 *     decoder and pipeline registers) lives here because no child module owns it.
 *   - Unconnected child outputs are listed at their instance with the reason.
 * Parent       : m_soc_top (u_cpu_top)
 * REQ-IDs      : REQ-001, REQ-027, REQ-041, REQ-044, REQ-052, REQ-053, REQ-073, REQ-084
 */
`timescale 1ns / 1ps

module m_cpu_top #(
    // Parameter Description: width of the PC, instruction, register data and CPU data bus.
    // Parameter values: fixed to 32 (RV32I); default is 32.
    // Parameter unit: bit
    localparam logic [31:0] LPARA_XLEN = 32,
    // Parameter Description: number of byte enables of the CPU data bus, derived from the width.
    // Parameter values: fixed to 4 (LPARA_XLEN / 8); default is 4.
    // Parameter unit: count
    localparam logic [31:0] LPARA_BE_W = 4
) (
    // Clock and reset
    input  wire                   i_clk_core,
    input  wire                   i_rst_n_core,
    // Instruction memory: registered 1-cycle read
    input  wire  [LPARA_XLEN-1:0] i_imem_rd_data,
    // Data bus: response
    input  wire  [LPARA_XLEN-1:0] i_dmem_rd_data,
    input  wire                   i_dmem_ack,
    // VPU: command ready and response
    input  wire                   i_vpu_cmd_ready,
    input  wire                   i_vpu_resp_done,
    input  wire                   i_vpu_resp_rd_valid,
    input  wire  [LPARA_XLEN-1:0] i_vpu_resp_rd_data,
    // Instruction memory: fetch byte address
    output logic [LPARA_XLEN-1:0] o_imem_addr,
    // Data bus: request
    output logic                  o_dmem_req,
    output logic                  o_dmem_wr_en,
    output logic [LPARA_BE_W-1:0] o_dmem_byte_en,
    output logic [LPARA_XLEN-1:0] o_dmem_addr,
    output logic [LPARA_XLEN-1:0] o_dmem_wr_data,
    // VPU: command
    output logic                  o_vpu_cmd_valid,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_instr,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_rs1_data,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_rs2_data,
    // Status flags (registered in m_pc_gen)
    output logic                  o_err_illegal,
    output logic                  o_halt
);

  // Widths of the interconnect between the child modules (they mirror the child ports).
  localparam logic [                31:0] LPARA_REG_IDX_W    = 5;
  localparam logic [                31:0] LPARA_ALU_OP_W     = 4;
  localparam logic [                31:0] LPARA_F3_W         = 3;
  localparam logic [                31:0] LPARA_FWD_SEL_W    = 2;
  localparam logic [                31:0] LPARA_PIPE_WB_W    = 2;
  localparam logic [                31:0] LPARA_DEC_WB_W     = 3;
  localparam logic [                31:0] LPARA_DEC_ASEL_W   = 2;
  localparam logic [                31:0] LPARA_DEC_IMM_W    = 3;

  // Forwarding select codes of m_hazard_unit.
  localparam logic [ LPARA_FWD_SEL_W-1:0] LPARA_FWD_EXMEM    = 2'b01;
  localparam logic [ LPARA_FWD_SEL_W-1:0] LPARA_FWD_MEMWB    = 2'b10;
  // Write-back source codes of the pipeline registers (m_id_ex_reg ... m_mem_wb_reg).
  localparam logic [ LPARA_PIPE_WB_W-1:0] LPARA_PIPE_WB_ALU  = 2'b00;
  localparam logic [ LPARA_PIPE_WB_W-1:0] LPARA_PIPE_WB_LOAD = 2'b01;
  localparam logic [ LPARA_PIPE_WB_W-1:0] LPARA_PIPE_WB_PC4  = 2'b10;
  // Write-back source and ALU operand A codes of m_cpu_dec.
  localparam logic [  LPARA_DEC_WB_W-1:0] LPARA_DEC_WB_MEM   = 3'd1;
  localparam logic [  LPARA_DEC_WB_W-1:0] LPARA_DEC_WB_PC4   = 3'd2;
  localparam logic [LPARA_DEC_ASEL_W-1:0] LPARA_DEC_ASEL_PC  = 2'd1;

  // IF stage signals
  logic [      LPARA_XLEN-1:0] w_pc;
  logic [      LPARA_XLEN-1:0] w_imem_addr;
  logic [      LPARA_XLEN-1:0] reg_fetch_pc;
  logic                        reg_fetch_valid;
  logic                        w_fetch_valid_nxt;

  // IF/ID stage outputs
  logic                        w_ifid_valid;
  logic [      LPARA_XLEN-1:0] w_ifid_pc;
  logic [      LPARA_XLEN-1:0] w_ifid_instr;

  // ID stage signals
  logic                        w_id_instr_valid;
  logic                        w_id_adv;
  logic                        w_dec_illegal;
  logic                        w_dec_ebreak;
  logic                        w_dec_is_vec;
  logic                        w_dec_rd_wr_en;
  logic                        w_dec_use_rs1;
  logic                        w_dec_use_rs2;
  logic                        w_dec_alu_b_imm;
  logic                        w_dec_is_branch;
  logic                        w_dec_is_jal;
  logic                        w_dec_is_jalr;
  logic                        w_dec_mem_rd;
  logic                        w_dec_mem_wr;
  logic                        w_dec_is_mul;
  logic [  LPARA_ALU_OP_W-1:0] w_dec_alu_op;
  logic [LPARA_DEC_ASEL_W-1:0] w_dec_alu_a_sel;
  logic [ LPARA_DEC_IMM_W-1:0] w_dec_imm_type;
  logic [  LPARA_DEC_WB_W-1:0] w_dec_wb_sel;
  logic [      LPARA_F3_W-1:0] w_dec_branch_fn;
  logic [      LPARA_F3_W-1:0] w_dec_mem_fn;
  logic [ LPARA_REG_IDX_W-1:0] w_dec_rs1_addr;
  logic [ LPARA_REG_IDX_W-1:0] w_dec_rs2_addr;
  logic [ LPARA_REG_IDX_W-1:0] w_dec_rd_addr;
  logic [ LPARA_REG_IDX_W-1:0] w_id_rs1_idx;
  logic [ LPARA_REG_IDX_W-1:0] w_id_rs2_idx;
  logic [      LPARA_XLEN-1:0] w_id_rs1_data;
  logic [      LPARA_XLEN-1:0] w_id_rs2_data;
  logic [      LPARA_XLEN-1:0] w_id_imm;
  logic [      LPARA_F3_W-1:0] w_id_funct3;
  logic [ LPARA_PIPE_WB_W-1:0] w_id_wb_sel;
  logic                        w_id_alu_a_pc_sel;

  // ID/EX stage outputs
  logic                        w_idex_valid;
  logic [      LPARA_XLEN-1:0] w_idex_pc;
  logic [      LPARA_XLEN-1:0] w_idex_instr;
  logic [      LPARA_XLEN-1:0] w_idex_rs1_data;
  logic [      LPARA_XLEN-1:0] w_idex_rs2_data;
  logic [      LPARA_XLEN-1:0] w_idex_imm;
  logic [ LPARA_REG_IDX_W-1:0] w_idex_rs1_idx;
  logic [ LPARA_REG_IDX_W-1:0] w_idex_rs2_idx;
  logic [ LPARA_REG_IDX_W-1:0] w_idex_rd_idx;
  logic [  LPARA_ALU_OP_W-1:0] w_idex_alu_op;
  logic                        w_idex_alu_a_pc_sel;
  logic                        w_idex_alu_b_imm_sel;
  logic [      LPARA_F3_W-1:0] w_idex_funct3;
  logic [ LPARA_PIPE_WB_W-1:0] w_idex_wb_sel;
  logic                        w_idex_is_branch;
  logic                        w_idex_is_jal;
  logic                        w_idex_is_jalr;
  logic                        w_idex_is_mul;
  logic                        w_idex_is_vec;
  logic                        w_idex_mem_rd;
  logic                        w_idex_mem_wr;
  logic                        w_idex_rf_we;

  // EX stage signals
  logic [ LPARA_FWD_SEL_W-1:0] w_fwd_a_sel;
  logic [ LPARA_FWD_SEL_W-1:0] w_fwd_b_sel;
  logic [      LPARA_XLEN-1:0] w_exmem_fwd_data;
  logic [      LPARA_XLEN-1:0] w_ex_rs1_data;
  logic [      LPARA_XLEN-1:0] w_ex_rs2_data;
  logic [      LPARA_XLEN-1:0] w_alu_op_a;
  logic [      LPARA_XLEN-1:0] w_alu_op_b;
  logic [      LPARA_XLEN-1:0] w_alu_result;
  logic [      LPARA_XLEN-1:0] w_mul_result;
  logic [      LPARA_XLEN-1:0] w_ex_result;
  logic                        w_redirect_taken;
  logic [      LPARA_XLEN-1:0] w_redirect_addr;
  logic [      LPARA_XLEN-1:0] w_link_data;

  // VPU dispatch signals
  logic                        w_disp_stall;
  logic                        w_disp_rd_valid;
  logic [      LPARA_XLEN-1:0] w_disp_rd_data;
  logic [      LPARA_XLEN-1:0] w_vpu_rd_data;
  logic                        w_vpu_done_hz;

  // EX/MEM stage outputs
  logic                        w_exmem_valid;
  logic [      LPARA_XLEN-1:0] w_exmem_alu_result;
  logic [      LPARA_XLEN-1:0] w_exmem_store_data;
  logic [      LPARA_XLEN-1:0] w_exmem_pc_plus4;
  logic [ LPARA_REG_IDX_W-1:0] w_exmem_rd_idx;
  logic [      LPARA_F3_W-1:0] w_exmem_funct3;
  logic [ LPARA_PIPE_WB_W-1:0] w_exmem_wb_sel;
  logic                        w_exmem_mem_rd;
  logic                        w_exmem_mem_wr;
  logic                        w_exmem_rf_we;

  // MEM stage signals
  logic [      LPARA_XLEN-1:0] w_load_data;
  logic                        w_mem_wait;

  // MEM/WB stage outputs
  logic                        w_memwb_valid;
  logic [ LPARA_REG_IDX_W-1:0] w_memwb_rd_idx;
  logic                        w_memwb_rf_we;
  logic [      LPARA_XLEN-1:0] w_memwb_wb_data;

  // Intentionally open child outputs (see the instance comments)
  logic [      LPARA_XLEN-1:0] w_csr_cycle_cnt;
  logic                        w_unused_ok;

  // Hazard unit stall and flush controls
  logic                        w_stall_pc;
  logic                        w_stall_if_id;
  logic                        w_stall_id_ex;
  logic                        w_stall_ex_mem;
  logic                        w_stall_mem_wb;
  logic                        w_flush_if_id;
  logic                        w_flush_id_ex;

  // Fetch address selection: the IMEM returns the word one cycle after the address. While the
  // front end is held, the previously presented address is read again, because the word that
  // was returned in the held cycle is dropped by the stalled IF/ID register.
  // REQ-001
  assign w_imem_addr = w_stall_pc ? reg_fetch_pc : w_pc;
  assign o_imem_addr = w_imem_addr;

  // Fetch validity: the word returned next cycle belongs to the address presented now. It is
  // invalid when that address is a wrong path address of a taken branch/jump resolved in EX
  // (the PC generator redirects in the same cycle). A hold keeps the validity of the word that
  // is read again.
  // REQ-001
  always_comb begin : p_com_fetch_valid
    w_fetch_valid_nxt = reg_fetch_valid;
    if (!w_stall_pc) begin
      w_fetch_valid_nxt = !w_redirect_taken;
    end
  end

  // Fetch alignment state: validity is control state and is cleared by reset, so no word read
  // before the first fetch enters the pipeline (empty pipeline after reset). The address of the
  // returned word is cleared as well so that a hold right after reset stays defined.
  // REQ-041, REQ-044
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_fetch
    if (!i_rst_n_core) begin
      reg_fetch_valid <= 1'b0;
      reg_fetch_pc    <= '0;
    end else begin
      reg_fetch_valid <= w_fetch_valid_nxt;
      reg_fetch_pc    <= w_imem_addr;
    end
  end

  // PC generator: PC = 0 after reset, redirect on a taken branch/jump, and halt on an illegal
  // instruction or ebreak. It owns the registered o_halt and o_err_illegal flags.
  // The halt commit inside ignores a request raised while a taken branch/jump is in EX.
  // REQ-027, REQ-041, REQ-052, REQ-053, REQ-073, REQ-084
  m_pc_gen u_pc_gen (
      .i_clk_core      (i_clk_core),
      .i_rst_n_core    (i_rst_n_core),
      .i_stall         (w_stall_pc),
      .i_redirect_taken(w_redirect_taken),
      .i_redirect_addr (w_redirect_addr),
      .i_illegal       (w_dec_illegal),
      .i_ebreak        (w_dec_ebreak),
      .o_pc            (w_pc),
      .o_halt          (o_halt),
      .o_err_illegal   (o_err_illegal)
  );

  // IF/ID register: takes the returned instruction word with the address it was read from.
  // REQ-001, REQ-084
  m_if_id_reg u_if_id_reg (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .i_flush     (w_flush_if_id),
      .i_stall     (w_stall_if_id),
      .i_valid     (reg_fetch_valid),
      .i_pc        (reg_fetch_pc),
      .i_instr     (i_imem_rd_data),
      .o_valid     (w_ifid_valid),
      .o_pc        (w_ifid_pc),
      .o_instr     (w_ifid_instr)
  );

  // Decode qualification: the instruction in ID is a wrong-path instruction while a taken
  // branch/jump is in EX, so it must not raise halt, illegal or any side effect. It leaves ID in
  // every cycle the front end is not held. Qualifying the decode input, the ID/EX valid and the
  // hazard-unit request with the same flag means an illegal instruction or ebreak in the shadow
  // of a taken branch/jump cannot halt the core nor set o_err_illegal (and so sts.err).
  // REQ-052, REQ-084
  assign w_id_instr_valid = w_ifid_valid && !w_redirect_taken;
  assign w_id_adv         = !w_stall_if_id;

  // Decoder: scalar and Zve32x-subset decode with illegal-instruction and ebreak detection. An
  // illegal instruction has all side-effect outputs at 0, so it is never dispatched to the VPU.
  // o_imm_type is not used: m_imm_gen selects the immediate format from the opcode itself.
  // REQ-001, REQ-052, REQ-073, REQ-084
  m_cpu_dec u_cpu_dec (
      .i_clk_core   (i_clk_core),
      .i_rst_n_core (i_rst_n_core),
      .i_instr_valid(w_id_instr_valid),
      .i_id_adv     (w_id_adv),
      .i_instr      (w_ifid_instr),
      .o_illegal    (w_dec_illegal),
      .o_ebreak     (w_dec_ebreak),
      .o_is_vec     (w_dec_is_vec),
      .o_rd_wr_en   (w_dec_rd_wr_en),
      .o_use_rs1    (w_dec_use_rs1),
      .o_use_rs2    (w_dec_use_rs2),
      .o_alu_b_imm  (w_dec_alu_b_imm),
      .o_is_branch  (w_dec_is_branch),
      .o_is_jal     (w_dec_is_jal),
      .o_is_jalr    (w_dec_is_jalr),
      .o_mem_rd     (w_dec_mem_rd),
      .o_mem_wr     (w_dec_mem_wr),
      .o_is_mul     (w_dec_is_mul),
      .o_alu_op     (w_dec_alu_op),
      .o_alu_a_sel  (w_dec_alu_a_sel),
      .o_imm_type   (w_dec_imm_type),
      .o_wb_sel     (w_dec_wb_sel),
      .o_branch_fn  (w_dec_branch_fn),
      .o_mem_fn     (w_dec_mem_fn),
      .o_rs1_addr   (w_dec_rs1_addr),
      .o_rs2_addr   (w_dec_rs2_addr),
      .o_rd_addr    (w_dec_rd_addr)
  );

  // Source index gating: an index is used only when the instruction reads that scalar source.
  // Instructions without rs1 (lui, auipc, jal, vector .vv forms) therefore read x0 = 0 and never
  // match a forwarding or hazard comparison, which also provides the zero operand of lui.
  // REQ-001
  assign w_id_rs1_idx      = w_dec_use_rs1 ? w_dec_rs1_addr : '0;
  assign w_id_rs2_idx      = w_dec_use_rs2 ? w_dec_rs2_addr : '0;

  // Code mapping between the decoder and the pipeline registers: funct3 carries the branch
  // condition or the memory access size; ALU operand A is the PC only for the PC-relative
  // formats; mul and VPU results travel in the EX result slot, so their select is ALU.
  // REQ-001
  assign w_id_funct3       = w_dec_is_branch ? w_dec_branch_fn : w_dec_mem_fn;
  assign w_id_alu_a_pc_sel = (w_dec_alu_a_sel == LPARA_DEC_ASEL_PC);

  always_comb begin : p_com_id_wb_sel
    w_id_wb_sel = LPARA_PIPE_WB_ALU;
    case (w_dec_wb_sel)
      LPARA_DEC_WB_MEM: w_id_wb_sel = LPARA_PIPE_WB_LOAD;
      LPARA_DEC_WB_PC4: w_id_wb_sel = LPARA_PIPE_WB_PC4;
      default:          w_id_wb_sel = LPARA_PIPE_WB_ALU;
    endcase
  end

  // Immediate generator: I/S/B/U/J immediate of the instruction in ID.
  // REQ-001
  m_imm_gen u_imm_gen (
      .i_instr(w_ifid_instr),
      .o_imm  (w_id_imm)
  );

  // Register file: read in ID, written from WB (same-cycle bypass inside the module).
  // REQ-001
  m_regfile u_regfile (
      .i_clk_core(i_clk_core),
      .i_wr_en   (w_memwb_rf_we),
      .i_wr_addr (w_memwb_rd_idx),
      .i_wr_data (w_memwb_wb_data),
      .i_rs1_addr(w_id_rs1_idx),
      .i_rs2_addr(w_id_rs2_idx),
      .o_rs1_data(w_id_rs1_data),
      .o_rs2_data(w_id_rs2_data)
  );

  // ID/EX register: a flush (taken branch, load-use bubble, halt commit) makes the stage a
  // bubble; a whole-pipeline stall holds it.
  // REQ-001, REQ-052
  m_id_ex_reg u_id_ex_reg (
      .i_clk_core     (i_clk_core),
      .i_rst_n_core   (i_rst_n_core),
      .i_flush        (w_flush_id_ex),
      .i_stall        (w_stall_id_ex),
      .i_valid        (w_id_instr_valid),
      .i_pc           (w_ifid_pc),
      .i_instr        (w_ifid_instr),
      .i_rs1_data     (w_id_rs1_data),
      .i_rs2_data     (w_id_rs2_data),
      .i_imm          (w_id_imm),
      .i_rs1_idx      (w_id_rs1_idx),
      .i_rs2_idx      (w_id_rs2_idx),
      .i_rd_idx       (w_dec_rd_addr),
      .i_alu_op       (w_dec_alu_op),
      .i_alu_a_pc_sel (w_id_alu_a_pc_sel),
      .i_alu_b_imm_sel(w_dec_alu_b_imm),
      .i_funct3       (w_id_funct3),
      .i_wb_sel       (w_id_wb_sel),
      .i_is_branch    (w_dec_is_branch),
      .i_is_jal       (w_dec_is_jal),
      .i_is_jalr      (w_dec_is_jalr),
      .i_is_mul       (w_dec_is_mul),
      .i_is_vec       (w_dec_is_vec),
      .i_mem_rd       (w_dec_mem_rd),
      .i_mem_wr       (w_dec_mem_wr),
      .i_rf_we        (w_dec_rd_wr_en),
      .o_valid        (w_idex_valid),
      .o_pc           (w_idex_pc),
      .o_instr        (w_idex_instr),
      .o_rs1_data     (w_idex_rs1_data),
      .o_rs2_data     (w_idex_rs2_data),
      .o_imm          (w_idex_imm),
      .o_rs1_idx      (w_idex_rs1_idx),
      .o_rs2_idx      (w_idex_rs2_idx),
      .o_rd_idx       (w_idex_rd_idx),
      .o_alu_op       (w_idex_alu_op),
      .o_alu_a_pc_sel (w_idex_alu_a_pc_sel),
      .o_alu_b_imm_sel(w_idex_alu_b_imm_sel),
      .o_funct3       (w_idex_funct3),
      .o_wb_sel       (w_idex_wb_sel),
      .o_is_branch    (w_idex_is_branch),
      .o_is_jal       (w_idex_is_jal),
      .o_is_jalr      (w_idex_is_jalr),
      .o_is_mul       (w_idex_is_mul),
      .o_is_vec       (w_idex_is_vec),
      .o_mem_rd       (w_idex_mem_rd),
      .o_mem_wr       (w_idex_mem_wr),
      .o_rf_we        (w_idex_rf_we)
  );

  // EX/MEM forwarding value: the link address for jal/jalr, otherwise the EX result. A load in
  // EX/MEM is never forwarded (the hazard unit inserts the load-use bubble instead).
  // REQ-001
  always_comb begin : p_com_exmem_fwd
    w_exmem_fwd_data = w_exmem_alu_result;
    if (w_exmem_wb_sel == LPARA_PIPE_WB_PC4) begin
      w_exmem_fwd_data = w_exmem_pc_plus4;
    end
  end

  // EX operand A forwarding: register-file value read in ID, EX/MEM result or MEM/WB data.
  // REQ-001
  always_comb begin : p_com_fwd_a
    w_ex_rs1_data = w_idex_rs1_data;
    case (w_fwd_a_sel)
      LPARA_FWD_EXMEM: w_ex_rs1_data = w_exmem_fwd_data;
      LPARA_FWD_MEMWB: w_ex_rs1_data = w_memwb_wb_data;
      default:         w_ex_rs1_data = w_idex_rs1_data;
    endcase
  end

  // EX operand B forwarding: same sources and priority as operand A (also the store data).
  // REQ-001
  always_comb begin : p_com_fwd_b
    w_ex_rs2_data = w_idex_rs2_data;
    case (w_fwd_b_sel)
      LPARA_FWD_EXMEM: w_ex_rs2_data = w_exmem_fwd_data;
      LPARA_FWD_MEMWB: w_ex_rs2_data = w_memwb_wb_data;
      default:         w_ex_rs2_data = w_idex_rs2_data;
    endcase
  end

  // ALU operand selection: A is the PC for the PC-relative formats, else the forwarded rs1
  // (zero for lui); B is the immediate for immediate formats, else the forwarded rs2.
  // REQ-001
  assign w_alu_op_a = w_idex_alu_a_pc_sel ? w_idex_pc : w_ex_rs1_data;
  assign w_alu_op_b = w_idex_alu_b_imm_sel ? w_idex_imm : w_ex_rs2_data;

  // Integer ALU: arithmetic, logic, shift, compare and address generation.
  // REQ-001
  m_alu u_alu (
      .i_op_a  (w_alu_op_a),
      .i_op_b  (w_alu_op_b),
      .i_alu_op(w_idex_alu_op),
      .o_result(w_alu_result)
  );

  // Branch unit: condition, redirect target and link address, using the forwarded operands.
  // REQ-001
  m_branch_unit u_branch_unit (
      .i_branch   (w_idex_is_branch),
      .i_jal      (w_idex_is_jal),
      .i_jalr     (w_idex_is_jalr),
      .i_funct3   (w_idex_funct3),
      .i_rs1_data (w_ex_rs1_data),
      .i_rs2_data (w_ex_rs2_data),
      .i_pc       (w_idex_pc),
      .i_imm      (w_idex_imm),
      .o_taken    (w_redirect_taken),
      .o_target   (w_redirect_addr),
      .o_link_data(w_link_data)
  );

  // Multiplier: low 32 bits of rs1 * rs2 (mul).
  // REQ-001
  m_mul u_mul (
      .i_op_a  (w_ex_rs1_data),
      .i_op_b  (w_ex_rs2_data),
      .o_result(w_mul_result)
  );

  // VPU dispatch: offers the vector instruction in EX with its forwarded rs1/rs2 to the VPU and
  // stalls the pipeline until the done pulse. Its stall output is the vector-busy state of the
  // hazard unit (below). The scalar result is used only when the VPU returns a valid rd value.
  // REQ-001, REQ-052
  m_vpu_dispatch u_vpu_dispatch (
      .i_clk_core         (i_clk_core),
      .i_rst_n_core       (i_rst_n_core),
      .i_vec_valid        (w_idex_is_vec),
      .i_vec_instr        (w_idex_instr),
      .i_vec_rs1_data     (w_ex_rs1_data),
      .i_vec_rs2_data     (w_ex_rs2_data),
      .i_vpu_cmd_ready    (i_vpu_cmd_ready),
      .i_vpu_resp_done    (i_vpu_resp_done),
      .i_vpu_resp_rd_valid(i_vpu_resp_rd_valid),
      .i_vpu_resp_rd_data (i_vpu_resp_rd_data),
      .o_vpu_cmd_valid    (o_vpu_cmd_valid),
      .o_vpu_cmd_instr    (o_vpu_cmd_instr),
      .o_vpu_cmd_rs1_data (o_vpu_cmd_rs1_data),
      .o_vpu_cmd_rs2_data (o_vpu_cmd_rs2_data),
      .o_stall            (w_disp_stall),
      .o_rd_valid         (w_disp_rd_valid),
      .o_rd_data          (w_disp_rd_data)
  );

  // VPU scalar result and done indication toward the pipeline: the hazard unit stalls a vector
  // instruction in EX until its done indication, which is the dispatch stall being low.
  // REQ-001
  assign w_vpu_rd_data = w_disp_rd_valid ? w_disp_rd_data : '0;
  assign w_vpu_done_hz = !w_disp_stall;

  // EX result selection: the VPU scalar result for vsetvli/vsetivli/vmv.x.s, the product for
  // mul, otherwise the ALU result (jal/jalr link and load data use their own slots).
  // REQ-001
  always_comb begin : p_com_ex_result
    w_ex_result = w_alu_result;
    if (w_idex_is_vec) begin
      w_ex_result = w_vpu_rd_data;
    end else if (w_idex_is_mul) begin
      w_ex_result = w_mul_result;
    end
  end

  // EX/MEM register: holds the EX result, store data (forwarded rs2) and controls; a
  // whole-pipeline stall holds it.
  // REQ-001
  m_ex_mem_reg u_ex_mem_reg (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .i_stall     (w_stall_ex_mem),
      .i_valid     (w_idex_valid),
      .i_alu_result(w_ex_result),
      .i_store_data(w_ex_rs2_data),
      .i_pc_plus4  (w_link_data),
      .i_rd_idx    (w_idex_rd_idx),
      .i_funct3    (w_idex_funct3),
      .i_wb_sel    (w_idex_wb_sel),
      .i_mem_rd    (w_idex_mem_rd),
      .i_mem_wr    (w_idex_mem_wr),
      .i_rf_we     (w_idex_rf_we),
      .o_valid     (w_exmem_valid),
      .o_alu_result(w_exmem_alu_result),
      .o_store_data(w_exmem_store_data),
      .o_pc_plus4  (w_exmem_pc_plus4),
      .o_rd_idx    (w_exmem_rd_idx),
      .o_funct3    (w_exmem_funct3),
      .o_wb_sel    (w_exmem_wb_sel),
      .o_mem_rd    (w_exmem_mem_rd),
      .o_mem_wr    (w_exmem_mem_wr),
      .o_rf_we     (w_exmem_rf_we)
  );

  // Load/store unit: builds the data-bus request of the access in MEM, aligns load data, and
  // reports a wait while the bus has not acknowledged.
  // REQ-001
  m_lsu u_lsu (
      .i_mem_rd_en   (w_exmem_mem_rd),
      .i_mem_wr_en   (w_exmem_mem_wr),
      .i_funct3      (w_exmem_funct3),
      .i_addr        (w_exmem_alu_result),
      .i_store_data  (w_exmem_store_data),
      .i_dmem_rd_data(i_dmem_rd_data),
      .i_dmem_ack    (i_dmem_ack),
      .o_dmem_req    (o_dmem_req),
      .o_dmem_wr_en  (o_dmem_wr_en),
      .o_dmem_byte_en(o_dmem_byte_en),
      .o_dmem_addr   (o_dmem_addr),
      .o_dmem_wr_data(o_dmem_wr_data),
      .o_load_data   (w_load_data),
      .o_stall       (w_mem_wait)
  );

  // MEM/WB register: selects the write-back data. There is no flush: instructions older than a
  // halting instruction keep draining. o_valid is not used because the bubble state is already
  // folded into o_rf_we (the only consumer of the stage); it is collected in w_unused_ok.
  // REQ-053
  m_mem_wb_reg u_mem_wb_reg (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .i_flush     (1'b0),
      .i_stall     (w_stall_mem_wb),
      .i_valid     (w_exmem_valid),
      .i_rd_idx    (w_exmem_rd_idx),
      .i_wb_sel    (w_exmem_wb_sel),
      .i_rf_we     (w_exmem_rf_we),
      .i_alu_result(w_exmem_alu_result),
      .i_load_data (w_load_data),
      .i_pc_plus4  (w_exmem_pc_plus4),
      .o_valid     (w_memwb_valid),
      .o_rd_idx    (w_memwb_rd_idx),
      .o_rf_we     (w_memwb_rf_we),
      .o_wb_data   (w_memwb_wb_data)
  );

  // Hazard unit: forwarding selects, load-use bubble, taken-branch flush, vector/bus stall,
  // vector ordering wait and halt drain.
  // REQ-001, REQ-052, REQ-053, REQ-084
  m_hazard_unit u_hazard_unit (
      .i_id_valid      (w_id_instr_valid),
      .i_id_rs1_idx    (w_id_rs1_idx),
      .i_id_rs2_idx    (w_id_rs2_idx),
      .i_id_use_rs1    (w_dec_use_rs1),
      .i_id_use_rs2    (w_dec_use_rs2),
      .i_id_is_vec     (w_dec_is_vec),
      .i_halt_req      (w_dec_illegal || w_dec_ebreak),
      .i_halt          (o_halt),
      .i_idex_rs1_idx  (w_idex_rs1_idx),
      .i_idex_rs2_idx  (w_idex_rs2_idx),
      .i_idex_rd_idx   (w_idex_rd_idx),
      .i_idex_rf_we    (w_idex_rf_we),
      .i_idex_mem_rd   (w_idex_mem_rd),
      .i_idex_mem_wr   (w_idex_mem_wr),
      .i_idex_is_vec   (w_idex_is_vec),
      .i_redirect_taken(w_redirect_taken),
      .i_exmem_rd_idx  (w_exmem_rd_idx),
      .i_exmem_rf_we   (w_exmem_rf_we),
      .i_exmem_mem_rd  (w_exmem_mem_rd),
      .i_exmem_mem_wr  (w_exmem_mem_wr),
      .i_memwb_rd_idx  (w_memwb_rd_idx),
      .i_memwb_rf_we   (w_memwb_rf_we),
      .i_mem_wait      (w_mem_wait),
      .i_vpu_resp_done (w_vpu_done_hz),
      .o_fwd_a_sel     (w_fwd_a_sel),
      .o_fwd_b_sel     (w_fwd_b_sel),
      .o_stall_pc      (w_stall_pc),
      .o_stall_if_id   (w_stall_if_id),
      .o_stall_id_ex   (w_stall_id_ex),
      .o_stall_ex_mem  (w_stall_ex_mem),
      .o_stall_mem_wb  (w_stall_mem_wb),
      .o_flush_if_id   (w_flush_if_id),
      .o_flush_id_ex   (w_flush_id_ex)
  );

  // CPU-side free-running cycle counter. It is not connected to cycles.cnt (that value comes from
  // m_vpu_perf) and nothing in the CPU reads it, so its output is left open on purpose.
  // REQ-001
  m_csr_min u_csr_min (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .o_cycle_cnt (w_csr_cycle_cnt)
  );

  // Open child outputs, collected so that they are visibly intentional: o_imm_type (the immediate
  // format is chosen inside m_imm_gen), the MEM/WB o_valid (folded into o_rf_we) and the CPU-side
  // cycle counter. The signal name carries "unused", which the lint flow treats as intentional.
  assign w_unused_ok = &{1'b0, w_dec_imm_type, w_memwb_valid, w_csr_cycle_cnt};

endmodule
`default_nettype wire
