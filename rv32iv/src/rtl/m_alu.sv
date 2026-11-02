`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Integer ALU of the EX stage. Purely combinational RV32I arithmetic, logic,
 *                shift and set-less-than operations on two XLEN-bit operands.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-001
 */
`timescale 1ns / 1ps

module m_alu #(
    // Operand and result width of the RV32 base ISA.
    localparam logic [31:0] LPARA_XLEN    = 32,
    // Width of the shift amount (low bits of operand B) derived from the operand width.
    localparam logic [31:0] LPARA_SHAMT_W = $clog2(LPARA_XLEN),
    // Width of the operation select code.
    localparam logic [31:0] LPARA_OP_W    = 4
) (
    input  wire  [LPARA_XLEN-1:0] i_op_a,
    input  wire  [LPARA_XLEN-1:0] i_op_b,
    input  wire  [LPARA_OP_W-1:0] i_alu_op,
    output logic [LPARA_XLEN-1:0] o_result
);

  // ALU operation codes. The decoder chooses operand sources (rs1/pc, rs2/imm); this module only
  // applies the operation. ADD also serves load/store/jalr address generation and auipc,
  // PASS_B serves lui.
  typedef enum logic [3:0] {
    ENUM_ALU_OP_ADD    = 4'b0000,
    ENUM_ALU_OP_SUB    = 4'b0001,
    ENUM_ALU_OP_SLL    = 4'b0010,
    ENUM_ALU_OP_SLT    = 4'b0011,
    ENUM_ALU_OP_SLTU   = 4'b0100,
    ENUM_ALU_OP_XOR    = 4'b0101,
    ENUM_ALU_OP_SRL    = 4'b0110,
    ENUM_ALU_OP_SRA    = 4'b0111,
    ENUM_ALU_OP_OR     = 4'b1000,
    ENUM_ALU_OP_AND    = 4'b1001,
    ENUM_ALU_OP_PASS_B = 4'b1010
  } alu_op_type_def;

  logic [LPARA_SHAMT_W-1:0] w_shamt;
  logic [   LPARA_XLEN-1:0] w_sum;
  logic [   LPARA_XLEN-1:0] w_diff;
  logic [   LPARA_XLEN-1:0] w_sll;
  logic [   LPARA_XLEN-1:0] w_srl;
  logic [   LPARA_XLEN-1:0] w_sra;
  logic [   LPARA_XLEN-1:0] w_sra_fill;
  logic                     w_sign_a;
  logic                     w_sign_b;
  logic                     w_ltu;
  logic                     w_lts;
  logic [   LPARA_XLEN-1:0] w_result;

  // Arithmetic, shift and compare datapaths computed in parallel (result mux below).
  // The shift amount is the low log2(XLEN) bits of operand B, as defined by RV32I.
  assign w_shamt    = i_op_b[LPARA_SHAMT_W-1:0];
  assign w_sum      = $bits(w_sum)'(i_op_a + i_op_b);
  assign w_diff     = $bits(w_diff)'(i_op_a - i_op_b);
  assign w_sll      = $bits(w_sll)'(i_op_a << w_shamt);
  assign w_srl      = $bits(w_srl)'(i_op_a >> w_shamt);

  // Arithmetic right shift without signed types: the vacated upper w_shamt bits are filled with
  // the sign bit of operand A through a mask built from a logical shift of all ones.
  assign w_sign_a   = i_op_a[LPARA_XLEN-1];
  assign w_sign_b   = i_op_b[LPARA_XLEN-1];
  assign w_sra_fill = $bits(w_sra_fill)'(~({LPARA_XLEN{1'b1}} >> w_shamt));
  assign w_sra      = w_srl | (w_sra_fill & {LPARA_XLEN{w_sign_a}});

  // Set-less-than flags. Signed compare: operands of different sign are ordered by operand A's sign
  // bit (negative is smaller); operands of equal sign compare like unsigned values.
  assign w_ltu      = (i_op_a < i_op_b);
  assign w_lts      = (w_sign_a != w_sign_b) ? w_sign_a : w_ltu;

  // Result selection by operation code. Unused codes return zero (defined safe value).
  always_comb begin : p_com_result
    w_result = '0;
    case (i_alu_op)
      ENUM_ALU_OP_ADD:    w_result = w_sum;
      ENUM_ALU_OP_SUB:    w_result = w_diff;
      ENUM_ALU_OP_SLL:    w_result = w_sll;
      ENUM_ALU_OP_SLT:    w_result = {{(LPARA_XLEN - 1) {1'b0}}, w_lts};
      ENUM_ALU_OP_SLTU:   w_result = {{(LPARA_XLEN - 1) {1'b0}}, w_ltu};
      ENUM_ALU_OP_XOR:    w_result = i_op_a ^ i_op_b;
      ENUM_ALU_OP_SRL:    w_result = w_srl;
      ENUM_ALU_OP_SRA:    w_result = w_sra;
      ENUM_ALU_OP_OR:     w_result = i_op_a | i_op_b;
      ENUM_ALU_OP_AND:    w_result = i_op_a & i_op_b;
      ENUM_ALU_OP_PASS_B: w_result = i_op_b;
      default:            w_result = '0;
    endcase
  end

  // Output mapping forwards the selected result to the EX-stage consumers. // REQ-001
  assign o_result = w_result;

endmodule
`default_nettype wire
