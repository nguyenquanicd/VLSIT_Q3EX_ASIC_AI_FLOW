/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : 32x32 integer register file, x0 = 0, write-to-read bypass.
 *                2 combinational read ports and 1 write port. A same-cycle write to the
 *                register being read is bypassed to the read port.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-035, REQ-076
 */
`timescale 1ns / 1ps

module m_regfile #(
    localparam logic [31:0] LPARA_XLEN      = 32,
    localparam logic [31:0] LPARA_REG_COUNT = 32,
    localparam logic [31:0] LPARA_ADDR_W    = $clog2(LPARA_REG_COUNT)
) (
    input  wire                     i_clk_core,
    input  wire                     i_wr_en,
    input  wire  [LPARA_ADDR_W-1:0] i_wr_addr,
    input  wire  [  LPARA_XLEN-1:0] i_wr_data,
    input  wire  [LPARA_ADDR_W-1:0] i_rs1_addr,
    input  wire  [LPARA_ADDR_W-1:0] i_rs2_addr,
    output logic [  LPARA_XLEN-1:0] o_rs1_data,
    output logic [  LPARA_XLEN-1:0] o_rs2_data
);

  // Internal signal declarations
  // Resetless storage (SEQ-04): a register is only consumed after software has written it.
  // x0 has no storage; it is a constant zero in the read logic.
  logic [LPARA_XLEN-1:0] reg_x[1:LPARA_REG_COUNT-1];
  logic [LPARA_REG_COUNT-1:1] w_wr_sel;
  logic [LPARA_XLEN-1:0] w_rs1_data;
  logic [LPARA_XLEN-1:0] w_rs2_data;

  // Output mapping forwards the read-port results to the ID stage.
  assign o_rs1_data = w_rs1_data;
  assign o_rs2_data = w_rs2_data;

  // Write decode: one select per register x1..x31. A write to x0 matches no select, so x0 is
  // never modified.
  // REQ-035
  for (genvar gen_idx = 1; gen_idx < LPARA_REG_COUNT; gen_idx++) begin : gen_wr_sel
    assign w_wr_sel[gen_idx] = i_wr_en && (i_wr_addr == LPARA_ADDR_W'(gen_idx));
  end

  // Read port 1: x0 reads 0; a same-cycle write to the addressed register is bypassed;
  // otherwise the stored value is returned (combinational read).
  // REQ-035, REQ-076
  always_comb begin : p_com_rs1
    w_rs1_data = '0;
    if (i_rs1_addr == '0) begin
      w_rs1_data = '0;
    end else if (w_wr_sel[i_rs1_addr]) begin
      w_rs1_data = i_wr_data;
    end else begin
      w_rs1_data = reg_x[i_rs1_addr];
    end
  end

  // Read port 2: same behavior as read port 1 for the rs2 address.
  // REQ-035, REQ-076
  always_comb begin : p_com_rs2
    w_rs2_data = '0;
    if (i_rs2_addr == '0) begin
      w_rs2_data = '0;
    end else if (w_wr_sel[i_rs2_addr]) begin
      w_rs2_data = i_wr_data;
    end else begin
      w_rs2_data = reg_x[i_rs2_addr];
    end
  end

  // Register storage x1..x31: written with the write-port data when selected (clock enable).
  // Resetless on purpose; x0 is not part of this array.
  // REQ-035
  for (genvar gen_idx = 1; gen_idx < LPARA_REG_COUNT; gen_idx++) begin : gen_reg
    always_ff @(posedge i_clk_core) begin : p_ff_reg
      if (w_wr_sel[gen_idx]) begin
        reg_x[gen_idx] <= i_wr_data;
      end
    end
  end

endmodule
