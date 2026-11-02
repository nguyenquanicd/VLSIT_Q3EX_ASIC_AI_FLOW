`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : 32 x PARA_VLEN vector register file with 3 combinational read ports and 1 write
 *                port with per-byte write enables. Only the bytes enabled by i_wr_byte_en change,
 *                so tail elements (index >= vl), non-written bytes and all other vector registers
 *                keep their value. The writer drives the byte enables (element mask for vl).
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-005, REQ-059
 */
`timescale 1ns / 1ps

module m_vpu_regfile #(
    // Parameter Description: width of one vector register; the byte-enable width is PARA_VLEN/8.
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    localparam logic [31:0] LPARA_VREG_COUNT = 32,
    localparam logic [31:0] LPARA_ADDR_W     = $clog2(LPARA_VREG_COUNT),
    localparam logic [31:0] LPARA_BYTE_W     = 8,
    localparam logic [31:0] LPARA_BYTE_COUNT = PARA_VLEN / LPARA_BYTE_W
) (
    input  wire                         i_clk_core,
    // Write port: one register per cycle, only the bytes flagged in i_wr_byte_en are modified.
    input  wire                         i_wr_en,
    input  wire  [    LPARA_ADDR_W-1:0] i_wr_addr,
    input  wire  [LPARA_BYTE_COUNT-1:0] i_wr_byte_en,
    input  wire  [       PARA_VLEN-1:0] i_wr_data,
    // Read ports 0..2 (combinational): operand vs1, operand vs2 and old vd / store data.
    input  wire  [    LPARA_ADDR_W-1:0] i_rd_addr_0,
    input  wire  [    LPARA_ADDR_W-1:0] i_rd_addr_1,
    input  wire  [    LPARA_ADDR_W-1:0] i_rd_addr_2,
    output logic [       PARA_VLEN-1:0] o_rd_data_0,
    output logic [       PARA_VLEN-1:0] o_rd_data_1,
    output logic [       PARA_VLEN-1:0] o_rd_data_2
);

  // Resetless storage (SEQ-04): a vector register is only consumed after it has been written
  // (write-before-read guaranteed by the program / controller).
  logic [PARA_VLEN-1:0]    reg_v [LPARA_VREG_COUNT-1:0];
  logic [LPARA_VREG_COUNT-1:0] w_wr_sel;

  // Elaboration check of the legal parameter value.
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_vpu_regfile: PARA_VLEN must be 128 or 256");
  end

  // Output mapping: the read ports return the stored registers (no write bypass; the controller
  // reads operands in RD and writes the result in WB).
  assign o_rd_data_0 = reg_v[i_rd_addr_0];
  assign o_rd_data_1 = reg_v[i_rd_addr_1];
  assign o_rd_data_2 = reg_v[i_rd_addr_2];
  // REQ-005

  // Write decode: one select per vector register; registers other than i_wr_addr are never
  // selected, so they cannot change.
  for (genvar gen_idx = 0; gen_idx < LPARA_VREG_COUNT; gen_idx++) begin : gen_wr_sel
    assign w_wr_sel[gen_idx] = i_wr_en && (i_wr_addr == LPARA_ADDR_W'(gen_idx));
  end
  // REQ-059

  // Register storage with per-byte clock enable: a byte is written only when its register is
  // selected and its byte enable is set. Disabled bytes (tail elements, non-written bytes of
  // vse8/vse32, other registers) keep their old value.
  for (genvar gen_idx = 0; gen_idx < LPARA_VREG_COUNT; gen_idx++) begin : gen_reg
    for (genvar gen_byte = 0; gen_byte < LPARA_BYTE_COUNT; gen_byte++) begin : gen_byte_lane
      always_ff @(posedge i_clk_core) begin : p_ff_byte
        if (w_wr_sel[gen_idx] && i_wr_byte_en[gen_byte]) begin
          reg_v[gen_idx][gen_byte*LPARA_BYTE_W +: LPARA_BYTE_W] <=
            i_wr_data[gen_byte*LPARA_BYTE_W +: LPARA_BYTE_W];
        end
      end
    end
  end
  // REQ-005, REQ-059

endmodule
`default_nettype wire
