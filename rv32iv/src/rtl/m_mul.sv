`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Zmmul multiplier of the EX stage. Purely combinational 32x32 multiply that
 *                returns the low 32 bits of the product (RISC-V `mul`).
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-002
 */
`timescale 1ns / 1ps

module m_mul #(
    // Operand and result width of the RV32 base ISA.
    localparam logic [31:0] LPARA_XLEN = 32
) (
    input  wire  [LPARA_XLEN-1:0] i_op_a,
    input  wire  [LPARA_XLEN-1:0] i_op_b,
    output logic [LPARA_XLEN-1:0] o_result
);

  logic [LPARA_XLEN-1:0] w_prod_lo;

  // Low-half product. The low XLEN bits of a two's-complement product are identical for signed
  // and unsigned operands, so an unsigned multiply truncated to XLEN bits equals the low 32 bits
  // of the signed product required by `mul`. The high half (mulh*, div, rem) is not implemented;
  // the decoder flags those opcodes as illegal. The operation is combinational so that the core
  // keeps one instruction per cycle; synthesis is expected to map it onto DSP blocks.
  assign w_prod_lo = $bits(w_prod_lo)'(i_op_a * i_op_b);

  // Output mapping forwards the low product to the EX-stage result mux. // REQ-002
  assign o_result  = w_prod_lo;

endmodule
`default_nettype wire
