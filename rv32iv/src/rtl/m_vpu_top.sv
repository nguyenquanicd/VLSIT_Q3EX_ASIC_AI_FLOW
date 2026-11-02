`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Structural VPU wrapper (Zve32x subset).
 *
 *                Implementation notes: the wrapper (VLEN 128, 4 lanes by default) checks the
 *                parameter combination at elaboration, derives the local parameters of REQ-051,
 *                and connects the command
 *                interface (m_vpu_if), the decoder (m_vpu_dec), the vtype/vl state (m_vpu_csr), the
 *                control FSM (m_vpu_ctrl), the register file (m_vpu_regfile), the load/store unit
 *                (m_vpu_lsu), the PARA_LANE_COUNT lanes (m_vpu_lane), the reduction unit
 *                (m_vpu_reduce) and the cycle counter (m_vpu_perf).
 *                The remaining glue is pure interconnect: operand word selection per lane, row
 *                assembly of the lane slot results and the register file write select. The lane
 *                results are written in the WB cycle (vd); the upper register of a vwmul result
 *                (vd + 1) is written in the following DONE cycle because the register file has one
 *                write port.
 * Parent       : m_soc_top (u_vpu_top)
 * REQ-IDs      : REQ-045, REQ-046, REQ-047, REQ-048, REQ-049, REQ-050, REQ-051
 */
`timescale 1ns / 1ps

module m_vpu_top #(
    // Parameter Description: width of one vector register and of one memory row; must be divisible by
    //                        PARA_LANE_COUNT x LPARA_LANE_W (elaboration constraint C3).
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN         = 128,
    // Parameter Description: number of parallel 32-bit lanes; must be a power of 2 and satisfy C3
    //                        together with PARA_VLEN.
    // Parameter values: legal values are 1, 2, 4, or 8; default is 4.
    // Parameter unit: count
    parameter  logic [31:0] PARA_LANE_COUNT   = 4,
    // Width of one lane datapath (spec constant).
    localparam logic [31:0] LPARA_LANE_W      = 32,
    // Number of vector registers (spec constant).
    localparam logic [31:0] LPARA_VREG_COUNT  = 32,
    // Number of low address bits ignored for row alignment: log2 of the row size in bytes.
    localparam logic [31:0] LPARA_ROW_LB      = $clog2(PARA_VLEN / 8),
    // Width of vl: the largest VLMAX is PARA_VLEN/8 (SEW = 8, LMUL = 1).
    localparam logic [31:0] LPARA_VL_W        = $clog2(PARA_VLEN / 8 + 1),
    // Width of the scalar instruction word, of rs1/rd data and of the memory address.
    localparam logic [31:0] LPARA_XLEN        = 32,
    // Width of a vector register index.
    localparam logic [31:0] LPARA_VREG_AW     = $clog2(LPARA_VREG_COUNT),
    // Bytes of one row (memory byte-enable width) and bytes of one lane word.
    localparam logic [31:0] LPARA_BYTE_COUNT  = PARA_VLEN / 8,
    localparam logic [31:0] LPARA_LANE_BYTES  = LPARA_LANE_W / 8,
    // Number of lane words of one row, of a register pair, and the index widths to select them.
    localparam logic [31:0] LPARA_WORD_N      = PARA_VLEN / LPARA_LANE_W,
    localparam logic [31:0] LPARA_PAIR_WORD_N = LPARA_WORD_N + LPARA_WORD_N,
    localparam logic [31:0] LPARA_WORD_IDX_W  = $clog2(LPARA_WORD_N),
    localparam logic [31:0] LPARA_PAIR_IDX_W  = $clog2(LPARA_PAIR_WORD_N),
    // Passes of a non-widening instruction, slots of a widening one, width of the pass index.
    localparam logic [31:0] LPARA_PASS_N      = PARA_VLEN / (PARA_LANE_COUNT * LPARA_LANE_W),
    localparam logic [31:0] LPARA_SLOT_N      = LPARA_PASS_N + LPARA_PASS_N,
    localparam logic [31:0] LPARA_PASS_W      = $clog2(LPARA_SLOT_N),
    // Width of one narrowed (vnclip) result half-lane and its byte enable.
    localparam logic [31:0] LPARA_HALF_W      = LPARA_LANE_W / 2,
    localparam logic [31:0] LPARA_HALF_BYTES  = LPARA_HALF_W / 8,
    // Width of the immediate field of an OP-V instruction.
    localparam logic [31:0] LPARA_IMM_W       = 5,
    // Legal parameter values checked at elaboration.
    localparam logic [31:0] LPARA_VLEN_MIN    = 128,
    localparam logic [31:0] LPARA_VLEN_MAX    = 256
) (
    input  wire                         i_clk_core,
    input  wire                         i_rst_n_core,
    // CPU command channel: the command transfers where i_cmd_valid and o_cmd_ready are both 1.
    input  wire                         i_cmd_valid,
    input  wire  [      LPARA_XLEN-1:0] i_cmd_instr,
    input  wire  [      LPARA_XLEN-1:0] i_cmd_rs1_data,
    input  wire  [      LPARA_XLEN-1:0] i_cmd_rs2_data,
    // VPU memory response.
    input  wire  [       PARA_VLEN-1:0] i_mem_rd_data,
    input  wire                         i_mem_ack,
    // CPU command handshake and response.
    output logic                        o_cmd_ready,
    output logic                        o_resp_done,
    output logic                        o_resp_rd_valid,
    output logic [      LPARA_XLEN-1:0] o_resp_rd_data,
    // VPU memory request: held with stable address/data until i_mem_ack.
    output logic                        o_mem_req,
    output logic                        o_mem_wr_en,
    output logic [      LPARA_XLEN-1:0] o_mem_addr,
    output logic [LPARA_BYTE_COUNT-1:0] o_mem_byte_en,
    output logic [       PARA_VLEN-1:0] o_mem_wr_data,
    // Cycle count of the last vector instruction, to i_cycles_cnt of m_soc_csr (cycles.cnt).
    output logic [      LPARA_XLEN-1:0] o_cycles_cnt
);

  // Elaboration constraint C1: PARA_VLEN is 128 or 256.
  if ((PARA_VLEN != LPARA_VLEN_MIN) && (PARA_VLEN != LPARA_VLEN_MAX)) begin : gen_chk_c1
    $error("m_vpu_top: PARA_VLEN must be 128 or 256");
  end
  // REQ-045, REQ-047, REQ-048

  // Elaboration constraint C2: PARA_LANE_COUNT is 1, 2, 4 or 8 (a power of 2).
  if ((PARA_LANE_COUNT != 32'd1) && (PARA_LANE_COUNT != 32'd2) &&
      (PARA_LANE_COUNT != 32'd4) && (PARA_LANE_COUNT != 32'd8)) begin : gen_chk_c2
    $error("m_vpu_top: PARA_LANE_COUNT must be 1, 2, 4 or 8");
  end
  // REQ-046, REQ-047, REQ-049

  // Elaboration constraint C3: a row holds a whole number of lane words per pass.
  if ((PARA_VLEN % (PARA_LANE_COUNT * LPARA_LANE_W)) != 32'd0) begin : gen_chk_c3
    $error("m_vpu_top: PARA_VLEN must be divisible by PARA_LANE_COUNT x LPARA_LANE_W");
  end
  // REQ-045, REQ-047, REQ-050

  // Command interface and control FSM status.
  logic                                     w_cmd_xfer;
  logic [                   LPARA_XLEN-1:0] w_instr;
  logic [                   LPARA_XLEN-1:0] w_rs1_data;
  logic                                     w_ctrl_idle;
  logic                                     w_ctrl_done;
  logic                                     w_ctrl_rd_valid;
  logic [                   LPARA_XLEN-1:0] w_ctrl_rd_data;
  logic                                     w_ctrl_rd;
  logic                                     w_ctrl_exec;
  logic                                     w_ctrl_wb;
  logic                                     w_lsu_start;
  logic                                     w_reduce_start;
  logic [                 LPARA_PASS_W-1:0] w_pass_idx;

  // Open child outputs (see the connections) and their collector.
  logic                                     w_cmd_pending_unused;
  logic [                   LPARA_XLEN-1:0] w_rs2_data_unused;
  logic                                     w_is_vsetvl_unused;
  logic                                     w_dec_valid_unused;
  logic [                   LPARA_VL_W-1:0] w_vset_vl_unused;
  logic [                   LPARA_XLEN-1:0] w_vset_rd_data_unused;
  logic                                     w_ctrl_dec_unused;
  logic                                     w_pass_last_unused;
  logic                                     w_unused_ok;

  // Decoder outputs.
  logic                                     w_is_vle;
  logic                                     w_is_vse;
  logic                                     w_is_vadd;
  logic                                     w_is_vsra;
  logic                                     w_is_vmax;
  logic                                     w_is_vnclip;
  logic                                     w_is_vmv_vx;
  logic                                     w_is_vmv_sx;
  logic                                     w_is_vmv_xs;
  logic                                     w_is_vwmul;
  logic                                     w_is_vwredsum;
  logic                                     w_src_scalar;
  logic                                     w_src_imm;
  logic [                LPARA_VREG_AW-1:0] w_vd;
  logic [                LPARA_VREG_AW-1:0] w_vs1;
  logic [                LPARA_VREG_AW-1:0] w_vs2;
  logic [                  LPARA_IMM_W-1:0] w_imm5;
  logic [                LPARA_VREG_AW-1:0] w_rd;
  logic [                              1:0] w_mem_eew;
  logic                                     w_vset_we;
  logic [                              1:0] w_vset_sew;
  logic                                     w_vset_rd_en;

  // vtype/vl state.
  logic                                     w_set_en;
  logic                                     w_set_is_imm;
  logic                                     w_set_rs1_zero;
  logic                                     w_set_rd_zero;
  logic [                              2:0] w_set_vsew;
  logic [                   LPARA_XLEN-1:0] w_set_avl;
  logic [                              1:0] w_vsew;
  logic [                   LPARA_VL_W-1:0] w_vl;
  logic [                   LPARA_XLEN-1:0] w_set_vl_data;

  // Instruction class flags for the control FSM and the write-back select.
  logic                                     w_is_alu;
  logic                                     w_dec_mem;
  logic                                     w_dec_wide;
  logic                                     w_dec_rd_wr;
  logic [                   LPARA_XLEN-1:0] w_rd_data;

  // Register file ports.
  logic [                LPARA_VREG_AW-1:0] w_rf_rd_addr_2;
  logic [                    PARA_VLEN-1:0] w_rf_rd_data_0;
  logic [                    PARA_VLEN-1:0] w_rf_rd_data_1;
  logic [                    PARA_VLEN-1:0] w_rf_rd_data_2;
  logic                                     w_rf_wr_en;
  logic [                LPARA_VREG_AW-1:0] w_rf_wr_addr;
  logic [             LPARA_BYTE_COUNT-1:0] w_rf_wr_byte_en;
  logic [                    PARA_VLEN-1:0] w_rf_wr_data;
  logic [                  2*PARA_VLEN-1:0] w_src_pair;

  // Load/store and reduction units.
  logic                                     w_lsu_done;
  logic [                    PARA_VLEN-1:0] w_lsu_rd_data;
  logic [             LPARA_BYTE_COUNT-1:0] w_lsu_rd_byte_en;
  logic                                     w_reduce_done;
  logic [                    PARA_VLEN-1:0] w_red_wr_data;
  logic [             LPARA_BYTE_COUNT-1:0] w_red_wr_byte_en;

  // Lane operands and results.
  logic [                   LPARA_XLEN-1:0] w_b_common;
  logic [                 LPARA_LANE_W-1:0] w_lane_a_word         [PARA_LANE_COUNT-1:0];
  logic [                 LPARA_LANE_W-1:0] w_lane_b_word         [PARA_LANE_COUNT-1:0];
  logic [    LPARA_SLOT_N*LPARA_LANE_W-1:0] w_lane_res_data       [PARA_LANE_COUNT-1:0];
  logic [LPARA_SLOT_N*LPARA_LANE_BYTES-1:0] w_lane_res_be         [PARA_LANE_COUNT-1:0];
  logic [                 LPARA_LANE_W-1:0] w_lane_xs_data        [PARA_LANE_COUNT-1:0];

  // Row assembly of the lane slots for each instruction class.
  logic [                    PARA_VLEN-1:0] w_alu_row_data;
  logic [             LPARA_BYTE_COUNT-1:0] w_alu_row_be;
  logic [                    PARA_VLEN-1:0] w_nc_row_data;
  logic [             LPARA_BYTE_COUNT-1:0] w_nc_row_be;
  logic [                  2*PARA_VLEN-1:0] w_mul_pair_data;
  logic [           2*LPARA_BYTE_COUNT-1:0] w_mul_pair_be;
  logic                                     w_wr_lo_en;
  logic [                    PARA_VLEN-1:0] w_wr_lo_data;
  logic [             LPARA_BYTE_COUNT-1:0] w_wr_lo_be;
  logic                                     w_hi_phase;
  logic                                     reg_is_vwmul;
  logic                                     reg_rf_addr2_pair;

  // Command interface: latches the CPU command and returns the done pulse and the scalar result.
  m_vpu_if u_vpu_if (
      .i_clk_core     (i_clk_core),
      .i_rst_n_core   (i_rst_n_core),
      .i_cmd_valid    (i_cmd_valid),
      .i_cmd_instr    (i_cmd_instr),
      .i_cmd_rs1_data (i_cmd_rs1_data),
      .i_cmd_rs2_data (i_cmd_rs2_data),
      .i_ctrl_idle    (w_ctrl_idle),
      .i_ctrl_done    (w_ctrl_done),
      .i_ctrl_rd_valid(w_ctrl_rd_valid),
      .i_ctrl_rd_data (w_ctrl_rd_data),
      .o_cmd_ready    (o_cmd_ready),
      .o_resp_done    (o_resp_done),
      .o_resp_rd_valid(o_resp_rd_valid),
      .o_resp_rd_data (o_resp_rd_data),
      .o_cmd_xfer     (w_cmd_xfer),
      // o_cmd_pending is not needed: the FSM state already tells when an instruction is running.
      .o_cmd_pending  (w_cmd_pending_unused),
      .o_instr        (w_instr),
      .o_rs1_data     (w_rs1_data),
      // rs2 is not used by any instruction of the supported subset (vsetvl is not supported).
      .o_rs2_data     (w_rs2_data_unused)
  );
  // REQ-051

  // Decoder: instruction flags and fields; vl/SEW of a set instruction come from m_vpu_csr.
  m_vpu_dec #(
      .PARA_VLEN(PARA_VLEN)
  ) u_vpu_dec (
      .i_instr       (w_instr),
      .i_rs1_data    (w_rs1_data),
      .i_vl_cur      (w_vl),
      // o_is_vsetvl equals o_vset_we, which is used instead.
      .o_is_vsetvl   (w_is_vsetvl_unused),
      .o_is_vle      (w_is_vle),
      .o_is_vse      (w_is_vse),
      .o_is_vadd     (w_is_vadd),
      .o_is_vsra     (w_is_vsra),
      .o_is_vmax     (w_is_vmax),
      .o_is_vnclip   (w_is_vnclip),
      .o_is_vmv_vx   (w_is_vmv_vx),
      .o_is_vmv_sx   (w_is_vmv_sx),
      .o_is_vmv_xs   (w_is_vmv_xs),
      .o_is_vwmul    (w_is_vwmul),
      .o_is_vwredsum (w_is_vwredsum),
      // Only decoded-legal instructions reach the VPU (m_cpu_dec), so no illegal flag is needed.
      .o_dec_valid   (w_dec_valid_unused),
      .o_src_scalar  (w_src_scalar),
      .o_src_imm     (w_src_imm),
      .o_vd          (w_vd),
      .o_vs1         (w_vs1),
      .o_vs2         (w_vs2),
      .o_imm5        (w_imm5),
      .o_rd          (w_rd),
      .o_mem_eew     (w_mem_eew),
      .o_vset_we     (w_vset_we),
      // vl and the scalar result of a set instruction are taken from m_vpu_csr.
      .o_vset_vl     (w_vset_vl_unused),
      .o_vset_sew    (w_vset_sew),
      .o_vset_rd_data(w_vset_rd_data_unused),
      .o_vset_rd_en  (w_vset_rd_en)
  );

  // Set-instruction strobe: applied once, in the WB cycle, only for a legal setting.
  assign w_set_en       = w_vset_we & w_ctrl_wb;
  assign w_set_is_imm   = &w_instr[LPARA_XLEN-1-:2];
  assign w_set_rs1_zero = (w_vs1 == '0);
  assign w_set_rd_zero  = (w_rd == '0);
  assign w_set_vsew     = {1'b0, w_vset_sew};
  assign w_set_avl      = w_set_is_imm ? LPARA_XLEN'(w_imm5) : w_rs1_data;
  // REQ-051

  // vtype/vl state.
  m_vpu_csr #(
      .PARA_VLEN(PARA_VLEN)
  ) u_vpu_csr (
      .i_clk_core    (i_clk_core),
      .i_rst_n_core  (i_rst_n_core),
      .i_set_en      (w_set_en),
      .i_set_is_imm  (w_set_is_imm),
      .i_set_rs1_zero(w_set_rs1_zero),
      .i_set_rd_zero (w_set_rd_zero),
      .i_set_vsew    (w_set_vsew),
      // The decoder only enables a set instruction with LMUL = 1 (vlmul = 0).
      .i_set_vlmul   ('0),
      .i_set_avl     (w_set_avl),
      .o_vsew        (w_vsew),
      .o_vl          (w_vl),
      .o_set_vl_data (w_set_vl_data)
  );
  // REQ-051

  // Instruction class flags: lane instructions, memory access, double-width operand and scalar
  // result write-back (vmv.x.s, or vsetvli/vsetivli with rd != x0).
  assign w_is_alu    = w_is_vadd | w_is_vsra | w_is_vmax | w_is_vmv_vx | w_is_vmv_sx;
  assign w_dec_mem   = w_is_vle | w_is_vse;
  assign w_dec_wide  = w_is_vwmul | w_is_vnclip;
  assign w_dec_rd_wr = w_is_vmv_xs | w_vset_rd_en;
  assign w_rd_data   = w_is_vmv_xs ? w_lane_xs_data[0] : w_set_vl_data;

  // Control FSM.
  m_vpu_ctrl #(
      .PARA_VLEN      (PARA_VLEN),
      .PARA_LANE_COUNT(PARA_LANE_COUNT)
  ) u_vpu_ctrl (
      .i_clk_core    (i_clk_core),
      .i_rst_n_core  (i_rst_n_core),
      .i_cmd_xfer    (w_cmd_xfer),
      .i_dec_mem     (w_dec_mem),
      .i_dec_reduce  (w_is_vwredsum),
      .i_dec_wide    (w_dec_wide),
      .i_dec_rd_wr   (w_dec_rd_wr),
      .i_lsu_done    (w_lsu_done),
      .i_reduce_done (w_reduce_done),
      .i_rd_data     (w_rd_data),
      .o_idle        (w_ctrl_idle),
      .o_done        (w_ctrl_done),
      .o_rd_valid    (w_ctrl_rd_valid),
      .o_rd_data     (w_ctrl_rd_data),
      // The DEC step has no datapath action.
      .o_dec_en      (w_ctrl_dec_unused),
      .o_rd_en       (w_ctrl_rd),
      .o_exec_en     (w_ctrl_exec),
      .o_wb_en       (w_ctrl_wb),
      .o_lsu_start   (w_lsu_start),
      .o_reduce_start(w_reduce_start),
      .o_pass_idx    (w_pass_idx),
      // The lanes decode the last pass themselves through the slot strobes.
      .o_pass_last   (w_pass_last_unused)
  );

  // Open child outputs, collected so that they are visibly intentional: each is documented at its
  // connection above. The signal names carry "unused", which the lint flow treats as intentional.
  assign w_unused_ok = &{1'b0, w_cmd_pending_unused, w_rs2_data_unused, w_is_vsetvl_unused,
                         w_dec_valid_unused, w_vset_vl_unused, w_vset_rd_data_unused,
                         w_ctrl_dec_unused, w_pass_last_unused};

  // Register file read addresses: port 0 = vs1, port 1 = vs2, port 2 = vs2 + 1 (upper half of the
  // source pair of vnclip/vwredsum) or vd (store data of vse). The select is the registered flag
  // reg_rf_addr2_pair, so no instruction decode sits in front of the register file read mux. The
  // fields vs1/vs2/vd are plain slices of the latched instruction (no decoder logic).
  always_comb begin : p_com_rf_rd_addr
    w_rf_rd_addr_2 = w_vd;
    if (reg_rf_addr2_pair) begin
      w_rf_rd_addr_2 = $bits(w_rf_rd_addr_2)'(w_vs2 + 1'b1);
    end
  end
  assign w_src_pair = {w_rf_rd_data_2, w_rf_rd_data_1};
  // REQ-051

  // Vector register file.
  m_vpu_regfile #(
      .PARA_VLEN(PARA_VLEN)
  ) u_vpu_regfile (
      .i_clk_core  (i_clk_core),
      .i_wr_en     (w_rf_wr_en),
      .i_wr_addr   (w_rf_wr_addr),
      .i_wr_byte_en(w_rf_wr_byte_en),
      .i_wr_data   (w_rf_wr_data),
      .i_rd_addr_0 (w_vs1),
      .i_rd_addr_1 (w_vs2),
      .i_rd_addr_2 (w_rf_rd_addr_2),
      .o_rd_data_0 (w_rf_rd_data_0),
      .o_rd_data_1 (w_rf_rd_data_1),
      .o_rd_data_2 (w_rf_rd_data_2)
  );

  // Load/store unit: the base address is rs1; the low log2(PARA_VLEN/8) bits are dropped here
  // (row alignment).
  m_vpu_lsu #(
      .PARA_VLEN(PARA_VLEN)
  ) u_vpu_lsu (
      .i_clk_core   (i_clk_core),
      .i_rst_n_core (i_rst_n_core),
      .i_start      (w_lsu_start),
      .i_is_store   (w_is_vse),
      .i_eew        (w_mem_eew),
      .i_vl         (w_vl),
      .i_addr_row   (w_rs1_data[LPARA_XLEN-1:LPARA_ROW_LB]),
      .i_st_data    (w_rf_rd_data_2),
      .i_mem_rd_data(i_mem_rd_data),
      .i_mem_ack    (i_mem_ack),
      .o_done       (w_lsu_done),
      .o_rd_data    (w_lsu_rd_data),
      .o_rd_byte_en (w_lsu_rd_byte_en),
      .o_mem_req    (o_mem_req),
      .o_mem_wr_en  (o_mem_wr_en),
      .o_mem_addr   (o_mem_addr),
      .o_mem_byte_en(o_mem_byte_en),
      .o_mem_wr_data(o_mem_wr_data)
  );

  // Reduction unit (vwredsum.vs): vs2 pair on read ports 1/2, vs1[0] from port 0.
  m_vpu_reduce #(
      .PARA_VLEN      (PARA_VLEN),
      .PARA_LANE_COUNT(PARA_LANE_COUNT)
  ) u_vpu_reduce (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .i_start     (w_reduce_start),
      .i_vl        (w_vl),
      .i_vs2_lo    (w_rf_rd_data_1),
      .i_vs2_hi    (w_rf_rd_data_2),
      .i_vs1_elem0 (w_rf_rd_data_0[LPARA_LANE_W-1:0]),
      .o_done      (w_reduce_done),
      .o_wr_data   (w_red_wr_data),
      .o_wr_byte_en(w_red_wr_byte_en)
  );

  // Cycle counter from command transfer to done, to cycles.cnt of m_soc_csr.
  m_vpu_perf u_vpu_perf (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .i_start     (w_cmd_xfer),
      .i_done      (w_ctrl_done),
      .o_cycles_cnt(o_cycles_cnt)
  );
  // REQ-051

  // Second operand of the lanes for scalar (.vx/.sx) and immediate (.vi/.wi) forms: rs1 or the
  // zero-extended 5-bit immediate. Vector forms (.vv) take the vs1 lane word instead.
  assign w_b_common = w_src_scalar ? w_rs1_data : LPARA_XLEN'(w_imm5);

  // Registered copy of the vwmul flag. m_vpu_if latches the instruction at the command transfer, so
  // the decoded flag is stable from the DEC cycle on; this flop samples it in DEC and holds the same
  // value through RD, EXEC, WB and DONE. The source word index below is used only in EXEC, so the
  // flop keeps the cycle behaviour while it removes the decoder net (reg_instr -> m_vpu_dec) from
  // the register file read -> lane operand path. Reset keeps the index defined before the first
  // instruction.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vwmul_flag
    if (!i_rst_n_core) begin
      reg_is_vwmul <= 1'b0;
    end else begin
      reg_is_vwmul <= w_is_vwmul;
    end
  end
  // REQ-051

  // Registered read-port-2 address select: samples (vnclip | vwredsum) in the DEC cycle exactly like
  // reg_is_vwmul (the instruction is latched at the command transfer, so the decode is stable in DEC)
  // and is valid from RD on, the first cycle that reads port 2 (reduction operands, vse store data
  // captured with the LSU start pulse in RD). Reset keeps the select defined (vd) before the first
  // instruction.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_rf_addr2_flag
    if (!i_rst_n_core) begin
      reg_rf_addr2_pair <= 1'b0;
    end else begin
      reg_rf_addr2_pair <= w_is_vnclip | w_is_vwredsum;
    end
  end
  // REQ-051

  // Lanes: lane k of pass p works on source word w = p x PARA_LANE_COUNT + k of the vs2/vs2+1 pair
  // (vwmul spends two passes per word, so its word index uses p >> 1). The word index depends only
  // on the registered flag and the registered pass index.
  for (genvar gen_idx = 0; gen_idx < PARA_LANE_COUNT; gen_idx++) begin : gen_lane
    localparam logic [31:0] LPARA_LANE_IDX = 32'(gen_idx);
    logic [    LPARA_PASS_W-1:0] w_src_pass;
    logic [LPARA_PAIR_IDX_W-1:0] w_word_idx;
    logic [    LPARA_LANE_W-1:0] w_vs1_word;

    assign w_src_pass = reg_is_vwmul ? $bits(w_src_pass)'(w_pass_idx >> 1) : w_pass_idx;
    assign w_word_idx = $bits(w_word_idx)'(32'(w_src_pass) * PARA_LANE_COUNT + LPARA_LANE_IDX);
    assign w_vs1_word = w_rf_rd_data_0[w_word_idx[LPARA_WORD_IDX_W-1:0]*LPARA_LANE_W+:LPARA_LANE_W];
    assign w_lane_a_word[gen_idx] = w_src_pair[w_word_idx*LPARA_LANE_W+:LPARA_LANE_W];
    assign w_lane_b_word[gen_idx] = (w_src_scalar | w_src_imm) ? w_b_common : w_vs1_word;

    m_vpu_lane #(
        .PARA_VLEN      (PARA_VLEN),
        .PARA_LANE_COUNT(PARA_LANE_COUNT),
        .PARA_LANE_IDX  (LPARA_LANE_IDX)
    ) u_vpu_lane (
        .i_clk_core   (i_clk_core),
        .i_rst_n_core (i_rst_n_core),
        .i_clr_en     (w_ctrl_rd),
        .i_exec_en    (w_ctrl_exec),
        .i_pass_idx   (w_pass_idx),
        .i_is_vadd    (w_is_vadd),
        .i_is_vsra    (w_is_vsra),
        .i_is_vmax    (w_is_vmax),
        .i_is_vmv_vx  (w_is_vmv_vx),
        .i_is_vmv_sx  (w_is_vmv_sx),
        .i_is_vmv_xs  (w_is_vmv_xs),
        .i_is_vnclip  (w_is_vnclip),
        // The lane uses the flag only while i_exec_en is 1, where it equals the decoded flag.
        .i_is_vwmul   (reg_is_vwmul),
        .i_sew        (w_vsew),
        .i_vl         (w_vl),
        .i_b_scalar   (w_src_scalar | w_src_imm),
        .i_a_word     (w_lane_a_word[gen_idx]),
        .i_b_word     (w_lane_b_word[gen_idx]),
        .o_res_data   (w_lane_res_data[gen_idx]),
        .o_res_byte_en(w_lane_res_be[gen_idx]),
        // Only lane 0 holds element 0 of vs2; its value is used for vmv.x.s.
        .o_xs_data    (w_lane_xs_data[gen_idx])
    );
  end
  // REQ-051

  // Row assembly of the slot results. Slot p of lane k holds: for vadd/vsra/vmax/vmv the row word
  // p x N + k; for vnclip the 16-bit row half p x N + k; for vwmul the pair word
  // 2 x ((p >> 1) x N + k) + (p & 1). N = PARA_LANE_COUNT.
  for (genvar gen_k = 0; gen_k < PARA_LANE_COUNT; gen_k++) begin : gen_asm_lane
    for (genvar gen_p = 0; gen_p < LPARA_SLOT_N; gen_p++) begin : gen_asm_slot
      localparam logic [31:0] LPARA_ROW_WORD = 32'(gen_p) * PARA_LANE_COUNT + 32'(gen_k);
      localparam logic [31:0] LPARA_PAIR_WORD = 32'd2 * ((32'(gen_p) >> 1) * PARA_LANE_COUNT +
                                                         32'(gen_k)) + (32'(gen_p) & 32'd1);
      logic [    LPARA_LANE_W-1:0] w_slot_data;
      logic [LPARA_LANE_BYTES-1:0] w_slot_be;

      assign w_slot_data = w_lane_res_data[gen_k][gen_p*LPARA_LANE_W+:LPARA_LANE_W];
      assign w_slot_be = w_lane_res_be[gen_k][gen_p*LPARA_LANE_BYTES+:LPARA_LANE_BYTES];

      // vnclip: one narrowed half-lane per slot.
      assign w_nc_row_data[LPARA_ROW_WORD*LPARA_HALF_W +: LPARA_HALF_W] =
        w_slot_data[LPARA_HALF_W-1:0];
      assign w_nc_row_be[LPARA_ROW_WORD*LPARA_HALF_BYTES +: LPARA_HALF_BYTES] =
        w_slot_be[LPARA_HALF_BYTES-1:0];

      // vwmul: one pair word per slot.
      assign w_mul_pair_data[LPARA_PAIR_WORD*LPARA_LANE_W+:LPARA_LANE_W] = w_slot_data;
      assign w_mul_pair_be[LPARA_PAIR_WORD*LPARA_LANE_BYTES+:LPARA_LANE_BYTES] = w_slot_be;

      // vadd/vsra/vmax/vmv: one row word per slot of the first LPARA_PASS_N slots.
      if (gen_p < LPARA_PASS_N) begin : gen_alu_word
        assign w_alu_row_data[LPARA_ROW_WORD*LPARA_LANE_W+:LPARA_LANE_W] = w_slot_data;
        assign w_alu_row_be[LPARA_ROW_WORD*LPARA_LANE_BYTES+:LPARA_LANE_BYTES] = w_slot_be;
      end
    end
  end
  // REQ-051

  // Register file write select. WB writes vd with the result of the executed instruction; vse,
  // vmv.x.s and the set instructions write no vector register. The upper register of a vwmul
  // result (vd + 1) is written in the DONE cycle; the lane slots stay stable until the next RD.
  assign w_hi_phase = w_ctrl_done & w_is_vwmul;

  always_comb begin : p_com_rf_wr
    w_wr_lo_en   = 1'b1;
    w_wr_lo_data = '0;
    w_wr_lo_be   = '0;
    if (w_is_alu) begin
      w_wr_lo_data = w_alu_row_data;
      w_wr_lo_be   = w_alu_row_be;
    end else if (w_is_vwmul) begin
      w_wr_lo_data = w_mul_pair_data[PARA_VLEN-1:0];
      w_wr_lo_be   = w_mul_pair_be[LPARA_BYTE_COUNT-1:0];
    end else if (w_is_vnclip) begin
      w_wr_lo_data = w_nc_row_data;
      w_wr_lo_be   = w_nc_row_be;
    end else if (w_is_vwredsum) begin
      w_wr_lo_data = w_red_wr_data;
      w_wr_lo_be   = w_red_wr_byte_en;
    end else if (w_is_vle) begin
      w_wr_lo_data = w_lsu_rd_data;
      w_wr_lo_be   = w_lsu_rd_byte_en;
    end else begin
      w_wr_lo_en = 1'b0;
    end

    w_rf_wr_en      = w_ctrl_wb & w_wr_lo_en;
    w_rf_wr_addr    = w_vd;
    w_rf_wr_byte_en = w_wr_lo_be;
    w_rf_wr_data    = w_wr_lo_data;
    if (w_hi_phase) begin
      w_rf_wr_en      = 1'b1;
      w_rf_wr_addr    = $bits(w_rf_wr_addr)'(w_vd + 1'b1);
      w_rf_wr_byte_en = w_mul_pair_be[LPARA_BYTE_COUNT+:LPARA_BYTE_COUNT];
      w_rf_wr_data    = w_mul_pair_data[PARA_VLEN+:PARA_VLEN];
    end
  end
  // REQ-051

endmodule
`default_nettype wire
