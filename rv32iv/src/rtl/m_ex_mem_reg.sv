`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : EX/MEM pipeline register. Holds the EX result (ALU/MUL result or address),
 *                the store data, the PC+4 link value and the memory/write-back controls for
 *                the MEM stage. A stall (vector stall, MMIO wait) holds it; there is no flush
 *                because a taken branch/jump only flushes IF/ID and ID/EX.
 * Parent       : m_cpu_top
 * REQ-IDs      : none assigned (implements the spec, EX/MEM pipeline register)
 */
`timescale 1ns / 1ps

module m_ex_mem_reg #(
    // Width of the ALU result, store data and PC+4 (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN      = 32,
    // Width of a scalar register index (32 integer registers).
    localparam logic [31:0] LPARA_REG_IDX_W = 5,
    // Width of the funct3 field (load/store size and sign).
    localparam logic [31:0] LPARA_FUNCT3_W  = 3,
    // Width of the write-back source select (ALU, load data, PC+4).
    localparam logic [31:0] LPARA_WB_SEL_W  = 2
) (
    input  wire                        i_clk_core,
    input  wire                        i_rst_n_core,
    input  wire                        i_stall,
    input  wire                        i_valid,
    input  wire  [     LPARA_XLEN-1:0] i_alu_result,
    input  wire  [     LPARA_XLEN-1:0] i_store_data,
    input  wire  [     LPARA_XLEN-1:0] i_pc_plus4,
    input  wire  [LPARA_REG_IDX_W-1:0] i_rd_idx,
    input  wire  [ LPARA_FUNCT3_W-1:0] i_funct3,
    input  wire  [ LPARA_WB_SEL_W-1:0] i_wb_sel,
    input  wire                        i_mem_rd,
    input  wire                        i_mem_wr,
    input  wire                        i_rf_we,
    output logic                       o_valid,
    output logic [     LPARA_XLEN-1:0] o_alu_result,
    output logic [     LPARA_XLEN-1:0] o_store_data,
    output logic [     LPARA_XLEN-1:0] o_pc_plus4,
    output logic [LPARA_REG_IDX_W-1:0] o_rd_idx,
    output logic [ LPARA_FUNCT3_W-1:0] o_funct3,
    output logic [ LPARA_WB_SEL_W-1:0] o_wb_sel,
    output logic                       o_mem_rd,
    output logic                       o_mem_wr,
    output logic                       o_rf_we
);

  // Packed control group whose bits have side effects downstream (validity and the
  // strobes that access memory or write the register file).
  localparam logic [31:0] LPARA_CTRL_W = 4;

  // Internal signal declarations
  logic [   LPARA_CTRL_W-1:0] reg_ctrl;
  logic [   LPARA_CTRL_W-1:0] w_ctrl_in;
  logic [   LPARA_CTRL_W-1:0] w_ctrl_nxt;
  logic [     LPARA_XLEN-1:0] reg_alu_result;
  logic [     LPARA_XLEN-1:0] reg_store_data;
  logic [     LPARA_XLEN-1:0] reg_pc_plus4;
  logic [LPARA_REG_IDX_W-1:0] reg_rd_idx;
  logic [ LPARA_FUNCT3_W-1:0] reg_funct3;
  logic [ LPARA_WB_SEL_W-1:0] reg_wb_sel;

  // Input control grouping: an invalid EX stage (bubble) never raises a strobe, so every
  // side-effect bit is qualified with i_valid.
  assign w_ctrl_in    = {i_valid, i_mem_rd & i_valid, i_mem_wr & i_valid, i_rf_we & i_valid};

  // Output mapping forwards the registered EX/MEM stage to the MEM stage and the EX forwarding mux.
  // o_valid = 0 marks a bubble; all strobes are 0 then, other fields must be ignored by MEM.
  assign o_valid      = reg_ctrl[3];
  assign o_mem_rd     = reg_ctrl[2];
  assign o_mem_wr     = reg_ctrl[1];
  assign o_rf_we      = reg_ctrl[0];
  assign o_alu_result = reg_alu_result;
  assign o_store_data = reg_store_data;
  assign o_pc_plus4   = reg_pc_plus4;
  assign o_rd_idx     = reg_rd_idx;
  assign o_funct3     = reg_funct3;
  assign o_wb_sel     = reg_wb_sel;

  // Next control selection: a stall keeps the current control state (the MEM access in flight
  // is not repeated or lost); otherwise the EX control is taken.
  always_comb begin : p_com_ctrl
    w_ctrl_nxt = reg_ctrl;
    if (!i_stall) begin
      w_ctrl_nxt = w_ctrl_in;
    end
  end

  // Control state: asynchronously cleared by reset so the pipeline starts empty (REQ-RESET-002).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_ctrl
    if (!i_rst_n_core) begin
      reg_ctrl <= '0;
    end else begin
      reg_ctrl <= w_ctrl_nxt;
    end
  end

  // Payload capture: result, store data, link value, destination index and selects load when
  // the stage advances (no stall). Resetless on purpose (SEQ-04): MEM and WB ignore them while
  // o_valid is 0, and every side-effect strobe lives in the reset control group above.
  always_ff @(posedge i_clk_core) begin : p_ff_payload
    if (!i_stall) begin
      reg_alu_result <= i_alu_result;
      reg_store_data <= i_store_data;
      reg_pc_plus4   <= i_pc_plus4;
      reg_rd_idx     <= i_rd_idx;
      reg_funct3     <= i_funct3;
      reg_wb_sel     <= i_wb_sel;
    end
  end

endmodule
`default_nettype wire
