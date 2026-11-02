`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Hazard unit. Forwarding selects (EX/MEM -> EX, MEM/WB -> EX), the load-use
 *                bubble, the taken branch/jump flush, the whole-pipeline stall for a vector
 *                instruction or an MMIO/bus wait, the ordering wait of a vector instruction in
 *                ID, and the drain of the pipeline after halt.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-003, REQ-009, REQ-029, REQ-034, REQ-053, REQ-066, REQ-067, REQ-081,
 *                REQ-084
 */
`timescale 1ns / 1ps

module m_hazard_unit #(
    // Parameter Description: width of a scalar register index (32 integer registers).
    // Parameter values: fixed to 5 (RV32I); default is 5.
    // Parameter unit: bit
    localparam logic [31:0] LPARA_REG_IDX_W = 5,
    // Parameter Description: width of an EX operand forwarding select.
    // Parameter values: fixed to 2 (register file, EX/MEM, MEM/WB); default is 2.
    // Parameter unit: bit
    localparam logic [31:0] LPARA_FWD_SEL_W = 2
) (
    // ID stage (instruction held in IF/ID): source indices, source usage and vector flag.
    // i_id_valid = 0 marks an IF/ID bubble; the use flags and i_id_is_vec are 0 for it.
    input  wire                        i_id_valid,
    input  wire  [LPARA_REG_IDX_W-1:0] i_id_rs1_idx,
    input  wire  [LPARA_REG_IDX_W-1:0] i_id_rs2_idx,
    input  wire                        i_id_use_rs1,
    input  wire                        i_id_use_rs2,
    input  wire                        i_id_is_vec,
    // Decode-stage halt request: illegal instruction or ebreak (qualified with i_id_valid)
    input  wire                        i_halt_req,
    // Core halted flag from the PC generator (sticky until reset)
    input  wire                        i_halt,
    // EX stage (ID/EX register outputs); strobes are 0 for a bubble
    input  wire  [LPARA_REG_IDX_W-1:0] i_idex_rs1_idx,
    input  wire  [LPARA_REG_IDX_W-1:0] i_idex_rs2_idx,
    input  wire  [LPARA_REG_IDX_W-1:0] i_idex_rd_idx,
    input  wire                        i_idex_rf_we,
    input  wire                        i_idex_mem_rd,
    input  wire                        i_idex_mem_wr,
    input  wire                        i_idex_is_vec,
    // Branch/jump taken in EX (from m_branch_unit)
    input  wire                        i_redirect_taken,
    // MEM stage (EX/MEM register outputs); strobes are 0 for a bubble
    input  wire  [LPARA_REG_IDX_W-1:0] i_exmem_rd_idx,
    input  wire                        i_exmem_rf_we,
    input  wire                        i_exmem_mem_rd,
    input  wire                        i_exmem_mem_wr,
    // WB stage (MEM/WB register outputs); o_rf_we is 0 for a bubble
    input  wire  [LPARA_REG_IDX_W-1:0] i_memwb_rd_idx,
    input  wire                        i_memwb_rf_we,
    // Data-bus wait: the access in MEM is not completed yet (MMIO wait, no i_dmem_ack)
    input  wire                        i_mem_wait,
    // VPU response: 1-cycle pulse when the vector instruction in EX is done
    input  wire                        i_vpu_resp_done,
    // Forwarding selects of the EX operands: 00 register file, 01 EX/MEM, 10 MEM/WB
    output logic [LPARA_FWD_SEL_W-1:0] o_fwd_a_sel,
    output logic [LPARA_FWD_SEL_W-1:0] o_fwd_b_sel,
    // Stage holds. o_stall_pc / o_stall_if_id also cover the load-use and vector-order waits
    output logic                       o_stall_pc,
    output logic                       o_stall_if_id,
    output logic                       o_stall_id_ex,
    output logic                       o_stall_ex_mem,
    output logic                       o_stall_mem_wb,
    // Stage flushes (turn the stage into a bubble); the flush of ID/EX also inserts the bubble
    output logic                       o_flush_if_id,
    output logic                       o_flush_id_ex
);

  // Forwarding select codes (EX operand mux).
  localparam logic [LPARA_FWD_SEL_W-1:0] LPARA_FWD_REG   = 2'b00;
  localparam logic [LPARA_FWD_SEL_W-1:0] LPARA_FWD_EXMEM = 2'b01;
  localparam logic [LPARA_FWD_SEL_W-1:0] LPARA_FWD_MEMWB = 2'b10;

  // Internal signal declarations
  logic w_exmem_wr;
  logic w_memwb_wr;
  logic w_idex_wr;
  logic w_fwd_a_exmem;
  logic w_fwd_a_memwb;
  logic w_fwd_b_exmem;
  logic w_fwd_b_memwb;
  logic w_load_use_rs1;
  logic w_load_use_rs2;
  logic w_load_use;
  logic w_raw_rs1;
  logic w_raw_rs2;
  logic w_older_mem_op;
  logic w_vec_id_wait;
  logic w_vec_busy;
  logic w_stall_all;
  logic w_id_hold;
  logic w_front_stall;
  logic w_halt_commit;

  // Valid destination write per stage: the write enable is already 0 for a bubble, and x0 is
  // never a real destination, so rd = 0 never forwards or creates a dependency.
  // REQ-003
  assign w_idex_wr = i_idex_rf_we & (|i_idex_rd_idx);
  assign w_exmem_wr = i_exmem_rf_we & (|i_exmem_rd_idx);
  assign w_memwb_wr = i_memwb_rf_we & (|i_memwb_rd_idx);

  // Forwarding hit per EX operand: the nearest producer wins (EX/MEM before MEM/WB). A load in
  // EX/MEM never forwards: the load-use bubble keeps its consumer one stage behind, so the
  // consumer meets the load in MEM/WB, where the loaded data is available.
  // REQ-003
  assign w_fwd_a_exmem = w_exmem_wr && !i_exmem_mem_rd && (i_exmem_rd_idx == i_idex_rs1_idx);
  assign w_fwd_a_memwb = w_memwb_wr && (i_memwb_rd_idx == i_idex_rs1_idx);
  assign w_fwd_b_exmem = w_exmem_wr && !i_exmem_mem_rd && (i_exmem_rd_idx == i_idex_rs2_idx);
  assign w_fwd_b_memwb = w_memwb_wr && (i_memwb_rd_idx == i_idex_rs2_idx);

  // Operand A forwarding select: EX/MEM, else MEM/WB, else the register-file value read in ID.
  // REQ-003
  always_comb begin : p_com_fwd_a
    o_fwd_a_sel = LPARA_FWD_REG;
    if (w_fwd_a_exmem) begin
      o_fwd_a_sel = LPARA_FWD_EXMEM;
    end else if (w_fwd_a_memwb) begin
      o_fwd_a_sel = LPARA_FWD_MEMWB;
    end
  end

  // Operand B forwarding select: same priority as operand A.
  // REQ-003
  always_comb begin : p_com_fwd_b
    o_fwd_b_sel = LPARA_FWD_REG;
    if (w_fwd_b_exmem) begin
      o_fwd_b_sel = LPARA_FWD_EXMEM;
    end else if (w_fwd_b_memwb) begin
      o_fwd_b_sel = LPARA_FWD_MEMWB;
    end
  end

  // Load-use detection: the instruction in ID reads a register that the load in EX writes. The
  // load data is only available in MEM/WB, so ID and IF are held for exactly 1 cycle and a
  // bubble enters EX; the next cycle the consumer reads the load through MEM/WB forwarding.
  // REQ-003
  assign w_load_use_rs1 = i_id_use_rs1 && (i_id_rs1_idx == i_idex_rd_idx);
  assign w_load_use_rs2 = i_id_use_rs2 && (i_id_rs2_idx == i_idex_rd_idx);
  assign w_load_use     = i_id_valid && i_idex_mem_rd && w_idex_wr &&
                          (w_load_use_rs1 || w_load_use_rs2);

  // Vector-order wait: a vector instruction in ID may enter EX only when (a) no older
  // instruction in EX, MEM or WB still writes one of its scalar sources (the register-file value
  // read in ID must be final, because the stalled instruction cannot re-forward), and (b) no older
  // memory access is in EX or MEM, so it completes before the VPU can use the DMEM.
  // REQ-009, REQ-034
  assign w_raw_rs1 = i_id_use_rs1 &&
                     ((w_idex_wr  && (i_idex_rd_idx  == i_id_rs1_idx)) ||
                      (w_exmem_wr && (i_exmem_rd_idx == i_id_rs1_idx)) ||
                      (w_memwb_wr && (i_memwb_rd_idx == i_id_rs1_idx)));
  assign w_raw_rs2 = i_id_use_rs2 &&
                     ((w_idex_wr  && (i_idex_rd_idx  == i_id_rs2_idx)) ||
                      (w_exmem_wr && (i_exmem_rd_idx == i_id_rs2_idx)) ||
                      (w_memwb_wr && (i_memwb_rd_idx == i_id_rs2_idx)));
  assign w_older_mem_op = i_idex_mem_rd || i_idex_mem_wr || i_exmem_mem_rd || i_exmem_mem_wr;
  assign w_vec_id_wait = i_id_valid && i_id_is_vec && (w_raw_rs1 || w_raw_rs2 || w_older_mem_op);

  // Whole-pipeline stall: a vector instruction in EX holds every stage until the VPU pulses
  // i_vpu_resp_done (one vector instruction at a time); an incomplete MMIO/bus access in MEM holds
  // every stage until it completes. The VPU is therefore the only DMEM requester while it runs.
  // Holding ID/EX keeps the vector instruction and its rs1/rs2 values stable until the done pulse.
  // REQ-009, REQ-029, REQ-034, REQ-067, REQ-081
  assign w_vec_busy = i_idex_is_vec && !i_vpu_resp_done;
  assign w_stall_all = w_vec_busy || i_mem_wait;

  // Front-end hold: the load-use bubble and the vector-order wait hold PC and IF/ID. A taken
  // branch/jump in EX makes the instruction in ID wrong-path, so the redirect overrides both waits
  // and the branch/jump is never lost behind a front-end hold.
  // The vector-order wait only gates a decoded legal vector instruction (i_id_valid, i_id_is_vec).
  // REQ-003, REQ-009, REQ-081
  assign w_id_hold = (w_load_use || w_vec_id_wait) && !i_redirect_taken;
  assign w_front_stall = w_stall_all || w_id_hold;

  // Halt commit: same condition as m_pc_gen. The halting instruction is not executed (ID/EX gets a
  // bubble) and the instruction fetched behind it is dropped; older instructions keep draining.
  // A halt request (illegal instruction or ebreak) from the wrong-path shadow of a taken
  // branch/jump in EX never commits (!i_redirect_taken), so it cannot halt the core or raise the
  // error flags; the request is also ignored while a front-end hold keeps the instruction in ID.
  // REQ-053, REQ-084
  assign w_halt_commit = !i_halt && !w_front_stall && !i_redirect_taken && i_halt_req;

  // Stall outputs: PC and IF/ID take the front-end hold; ID/EX, EX/MEM and MEM/WB take only the
  // whole-pipeline stall (the bubble for load-use/vector wait is made by the ID/EX flush).
  // REQ-009, REQ-029, REQ-034
  assign o_stall_pc = w_front_stall;
  assign o_stall_if_id = w_front_stall;
  assign o_stall_id_ex = w_stall_all;
  assign o_stall_ex_mem = w_stall_all;
  assign o_stall_mem_wb = w_stall_all;

  // Flush outputs. A taken branch/jump flushes IF/ID and ID/EX (the two wrong-path instructions),
  // which is the taken-branch penalty of 2 cycles; it is held back while the whole pipeline is
  // stalled so the branch in EX is not lost and re-presents its redirect after the stall.
  // The load-use bubble and vector-order wait bubble ID/EX only. After the halt commit and while
  // halted IF/ID is flushed so nothing younger than the halting instruction executes.
  // Flushed wrong-path instructions (including a vector, illegal or ebreak one) have no effect.
  // REQ-003, REQ-053, REQ-066, REQ-081, REQ-084
  assign o_flush_if_id = (i_redirect_taken && !w_stall_all) || w_halt_commit || i_halt;
  assign o_flush_id_ex = !w_stall_all &&
                         (i_redirect_taken || w_load_use || w_vec_id_wait || w_halt_commit);

endmodule
`default_nettype wire
