`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Lane widening INT8 multiplier. Multiplies the four signed 8-bit elements of
 *                one 32-bit lane word pairwise and returns four signed 16-bit products
 *                (vwmul.vv, SEW = 8 sources, 16-bit results).
 * Parent       : m_vpu_lane
 * REQ-IDs      : REQ-006
 */
`timescale 1ns / 1ps

module m_lane_mul #(
    // Width of one lane word (source operand of the lane).
    localparam logic [31:0] LPARA_LANE_W   = 32,
    // Width of one source element (SEW = 8 for vwmul.vv).
    localparam logic [31:0] LPARA_ELEM_W   = 8,
    // Number of source elements in one lane word.
    localparam logic [31:0] LPARA_ELEM_NUM = LPARA_LANE_W / LPARA_ELEM_W,
    // Width of one widened product (twice the source element width).
    localparam logic [31:0] LPARA_PROD_W   = 2 * LPARA_ELEM_W
) (
    input  wire  [               LPARA_LANE_W-1:0] i_op_a,
    input  wire  [               LPARA_LANE_W-1:0] i_op_b,
    output logic [LPARA_ELEM_NUM*LPARA_PROD_W-1:0] o_result
);

  // Per-element products, packed element 0 in the least significant bits.
  logic [LPARA_ELEM_NUM*LPARA_PROD_W-1:0] w_result;

  // Output mapping forwards the packed products to the lane result path.
  // REQ-006
  assign o_result = w_result;

  // Element-wise signed multiply with one multiplier per element and no sign-correction adders
  // after it. Operands are unsigned vectors (TYP-01, P22), so each element is sign-extended
  // explicitly to the product width and the product is truncated to that width. Two's-complement
  // multiplication is exact modulo 2^16, and the signed product range -16256..16384
  // (-128 x -128 = 16384) fits in 16 bits, so the truncated product is the exact signed product.
  // The multiply is combinational.
  for (genvar gen_idx = 0; gen_idx < LPARA_ELEM_NUM; gen_idx++) begin : gen_elem
    logic [LPARA_ELEM_W-1:0] w_a;
    logic [LPARA_ELEM_W-1:0] w_b;
    logic [LPARA_PROD_W-1:0] w_a_sx;
    logic [LPARA_PROD_W-1:0] w_b_sx;
    logic [LPARA_PROD_W-1:0] w_prod_s;

    assign w_a = i_op_a[LPARA_ELEM_W*gen_idx+:LPARA_ELEM_W];
    assign w_b = i_op_b[LPARA_ELEM_W*gen_idx+:LPARA_ELEM_W];

    // Sign extension of each element to the widened product width.
    assign w_a_sx = {{(LPARA_PROD_W - LPARA_ELEM_W) {w_a[LPARA_ELEM_W-1]}}, w_a};
    assign w_b_sx = {{(LPARA_PROD_W - LPARA_ELEM_W) {w_b[LPARA_ELEM_W-1]}}, w_b};

    // Single product narrowed to the 16-bit widened element.
    assign w_prod_s = $bits(w_prod_s)'(w_a_sx * w_b_sx);

    assign w_result[LPARA_PROD_W*gen_idx+:LPARA_PROD_W] = w_prod_s;
  end

endmodule
`default_nettype wire
