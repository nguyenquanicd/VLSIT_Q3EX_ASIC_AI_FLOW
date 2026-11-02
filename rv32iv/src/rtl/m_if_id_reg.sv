/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : IF/ID pipeline register with flush and stall. Holds the fetched PC and
 *                instruction for the ID stage. A taken branch/jump resolved in EX flushes the
 *                stage (predict not-taken); a stall holds it (load-use bubble, vector stall).
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-003, REQ-084
 */
`timescale 1ns / 1ps

module m_if_id_reg #(
    localparam logic [31:0] LPARA_PC_W    = 32,
    localparam logic [31:0] LPARA_INSTR_W = 32
) (
    input  wire                      i_clk_core,
    input  wire                      i_rst_n_core,
    input  wire                      i_flush,
    input  wire                      i_stall,
    input  wire                      i_valid,
    input  wire  [   LPARA_PC_W-1:0] i_pc,
    input  wire  [LPARA_INSTR_W-1:0] i_instr,
    output logic                     o_valid,
    output logic [   LPARA_PC_W-1:0] o_pc,
    output logic [LPARA_INSTR_W-1:0] o_instr
);

  // Internal signal declarations
  logic                     reg_valid;
  logic [   LPARA_PC_W-1:0] reg_pc;
  logic [LPARA_INSTR_W-1:0] reg_instr;
  logic                     w_valid_nxt;

  // Output mapping forwards the registered IF/ID stage to the ID stage.
  // o_valid = 0 marks a bubble; ID must ignore o_pc / o_instr in that case.
  assign o_valid = reg_valid;
  assign o_pc    = reg_pc;
  assign o_instr = reg_instr;

  // Next-valid selection: flush (taken branch/jump from EX) has priority and turns the stage
  // into a bubble. A stall keeps the current valid state. Otherwise the fetched valid is taken.
  // A wrong-path instruction in the shadow of a taken branch/jump is dropped here (o_valid = 0),
  // so ID never decodes it: an illegal instruction or ebreak there cannot halt the core or
  // raise o_err_illegal / sts.err. Flush wins over stall so a stalled wrong-path word is dropped too.
  // REQ-003
  // REQ-084
  always_comb begin : p_com_valid
    w_valid_nxt = reg_valid;
    if (i_flush) begin
      w_valid_nxt = 1'b0;
    end else if (!i_stall) begin
      w_valid_nxt = i_valid;
    end
  end

  // Validity state: asynchronously cleared by reset so the pipeline starts empty (REQ-RESET-002).
  // REQ-003
  // REQ-084
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_valid
    if (!i_rst_n_core) begin
      reg_valid <= 1'b0;
    end else begin
      reg_valid <= w_valid_nxt;
    end
  end

  // Payload capture: PC and instruction load when the stage advances (no stall).
  // Resetless on purpose (SEQ-04): consumers ignore them until reg_valid is set, and a
  // flushed stage is already invalidated by reg_valid, so no NOP encoding is needed.
  // REQ-003
  always_ff @(posedge i_clk_core) begin : p_ff_payload
    if (!i_stall) begin
      reg_pc    <= i_pc;
      reg_instr <= i_instr;
    end
  end

endmodule
