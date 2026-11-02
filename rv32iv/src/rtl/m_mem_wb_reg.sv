`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : MEM/WB pipeline register. Holds the result of the MEM stage (ALU result, load
 *                data, PC+4) with the destination index and the register-file write strobe for
 *                the WB stage, and selects the write-back data. A flush turns the stage into a
 *                bubble; a stall holds it. The WB data also feeds the MEM/WB to EX forwarding.
 * Parent       : m_cpu_top
 * REQ-IDs      : none assigned (implements the spec, MEM/WB pipeline register)
 */
`timescale 1ns / 1ps

module m_mem_wb_reg #(
    // Width of the ALU result, load data, PC+4 and write-back data (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN      = 32,
    // Width of a scalar register index (32 integer registers).
    localparam logic [31:0] LPARA_REG_IDX_W = 5,
    // Width of the write-back source select (ALU result, load data, PC+4).
    localparam logic [31:0] LPARA_WB_SEL_W  = 2
) (
    input  wire                        i_clk_core,
    input  wire                        i_rst_n_core,
    input  wire                        i_flush,
    input  wire                        i_stall,
    input  wire                        i_valid,
    input  wire  [LPARA_REG_IDX_W-1:0] i_rd_idx,
    input  wire  [ LPARA_WB_SEL_W-1:0] i_wb_sel,
    input  wire                        i_rf_we,
    input  wire  [     LPARA_XLEN-1:0] i_alu_result,
    input  wire  [     LPARA_XLEN-1:0] i_load_data,
    input  wire  [     LPARA_XLEN-1:0] i_pc_plus4,
    output logic                       o_valid,
    output logic [LPARA_REG_IDX_W-1:0] o_rd_idx,
    output logic                       o_rf_we,
    output logic [     LPARA_XLEN-1:0] o_wb_data
);

  // Write-back source select codes (produced by m_cpu_dec as wb_sel).
  // Unused encoding 2'b11 recovers to the ALU result.
  typedef enum logic [LPARA_WB_SEL_W-1:0] {
    ENUM_WB_SEL_ALU  = 2'b00,
    ENUM_WB_SEL_LOAD = 2'b01,
    ENUM_WB_SEL_PC4  = 2'b10
  } wb_sel_type_def;

  // Internal signal declarations
  logic                       reg_valid;
  logic                       reg_rf_we;
  logic                       w_valid_nxt;
  logic                       w_rf_we_nxt;
  logic [LPARA_REG_IDX_W-1:0] reg_rd_idx;
  logic [ LPARA_WB_SEL_W-1:0] reg_wb_sel;
  logic [     LPARA_XLEN-1:0] reg_alu_result;
  logic [     LPARA_XLEN-1:0] reg_load_data;
  logic [     LPARA_XLEN-1:0] reg_pc_plus4;
  logic [     LPARA_XLEN-1:0] w_wb_data;

  // Output mapping forwards the registered MEM/WB stage to the WB stage and the forwarding unit.
  // o_valid = 0 marks a bubble; o_rf_we is 0 then, other fields must be ignored by WB.
  assign o_valid   = reg_valid;
  assign o_rf_we   = reg_rf_we;
  assign o_rd_idx  = reg_rd_idx;
  assign o_wb_data = w_wb_data;

  // Next control selection: flush has priority and turns the stage into a bubble. A stall keeps
  // the current control state; otherwise the MEM result is taken. The write strobe is qualified
  // with i_valid so a bubble from MEM never writes the register file.
  always_comb begin : p_com_ctrl
    w_valid_nxt = reg_valid;
    w_rf_we_nxt = reg_rf_we;
    if (i_flush) begin
      w_valid_nxt = 1'b0;
      w_rf_we_nxt = 1'b0;
    end else if (!i_stall) begin
      w_valid_nxt = i_valid;
      w_rf_we_nxt = i_rf_we & i_valid;
    end
  end

  // Write-back data selection: picks the ALU result, the load data or PC+4 (jal/jalr link).
  // Unsupported select codes return the ALU result.
  always_comb begin : p_com_wb_data
    w_wb_data = reg_alu_result;
    case (reg_wb_sel)
      ENUM_WB_SEL_ALU:  w_wb_data = reg_alu_result;
      ENUM_WB_SEL_LOAD: w_wb_data = reg_load_data;
      ENUM_WB_SEL_PC4:  w_wb_data = reg_pc_plus4;
      default:          w_wb_data = reg_alu_result;
    endcase
  end

  // Control state: asynchronously cleared by reset so the pipeline starts empty (REQ-RESET-002).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_ctrl
    if (!i_rst_n_core) begin
      reg_valid <= 1'b0;
      reg_rf_we <= 1'b0;
    end else begin
      reg_valid <= w_valid_nxt;
      reg_rf_we <= w_rf_we_nxt;
    end
  end

  // Payload capture: destination index, select code and result data load when the stage advances
  // (no stall). Resetless on purpose (SEQ-04): WB ignores them while o_rf_we is 0, and the only
  // side-effect strobe lives in the reset control group above.
  always_ff @(posedge i_clk_core) begin : p_ff_payload
    if (!i_stall) begin
      reg_rd_idx     <= i_rd_idx;
      reg_wb_sel     <= i_wb_sel;
      reg_alu_result <= i_alu_result;
      reg_load_data  <= i_load_data;
      reg_pc_plus4   <= i_pc_plus4;
    end
  end

endmodule
`default_nettype wire
