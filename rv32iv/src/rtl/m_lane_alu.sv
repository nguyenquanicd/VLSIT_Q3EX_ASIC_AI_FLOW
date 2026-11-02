`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Lane add, shift-right-arithmetic, max, move. One 32-bit lane datapath for vadd,
 *                vsra, vmax, vmv.v.x, vmv.s.x and vmv.x.s at SEW = 8 (four byte elements) or
 *                SEW = 32 (one element). The vsra shift amount is masked to log2(SEW) bits and
 *                vmv.x.s sign-extends the element to 32 bits, also at SEW = 8 (RVV 1.0).
 *                Purely combinational. The result is accompanied by a per-byte write enable that is
 *                the parent's element mask (index < vl) gated by the operation and SEW legality,
 *                so tail elements and unselected bytes are never written (tail-undisturbed).
 *                vnclip is handled by m_lane_narrow.
 * Parent       : m_vpu_lane
 * REQ-IDs      : REQ-008, REQ-059
 */
`timescale 1ns / 1ps

module m_lane_alu #(
    // Width of one lane datapath (spec-derived constant, LPARA_LANE_W).
    localparam logic [31:0] LPARA_LANE_W   = 32,
    // Width of one byte element (SEW = 8).
    localparam logic [31:0] LPARA_BYTE_W   = 8,
    // Number of byte elements per lane word.
    localparam logic [31:0] LPARA_BYTE_NUM = LPARA_LANE_W / LPARA_BYTE_W,
    // Width of the shift amount at SEW = 32 (5 bits) and SEW = 8 (3 bits).
    localparam logic [31:0] LPARA_SH32_W   = $clog2(LPARA_LANE_W),
    localparam logic [31:0] LPARA_SH8_W    = $clog2(LPARA_BYTE_W)
) (
    // Operation flags from m_vpu_dec (one-hot or all 0 when this lane has nothing to do).
    input wire i_is_vadd,
    input wire i_is_vsra,
    input wire i_is_vmax,
    input wire i_is_vmv_vx,
    input wire i_is_vmv_sx,
    input wire i_is_vmv_xs,

    // Current SEW encoding: 2'd0 = 8 bit, 2'd2 = 32 bit. Other values are not legal for these
    // instructions (REQ-FUNC-019) and disable every write.
    input wire [1:0] i_sew,

    // Operand b is a scalar / 5-bit immediate (.vx/.vi/.sx): the element in the low SEW bits
    // of i_b is applied to every element of the lane. For .vv it is the vs1 lane word.
    input wire i_b_scalar,

    // Operand a (vs2 lane word) and operand b (vs1 lane word, scalar rs1 or imm5 in i_b[4:0]).
    input wire [LPARA_LANE_W-1:0] i_a,
    input wire [LPARA_LANE_W-1:0] i_b,

    // Element mask from the parent: bit k = element slot k of this lane is active (index < vl,
    // and only element 0 of the whole vector for vmv.s.x). At SEW = 32 only bit 0 is used.
    input wire [LPARA_BYTE_NUM-1:0] i_elem_en,

    // Result lane word, per-byte write enable for the vector register file, and the scalar
    // result of vmv.x.s (element 0 of i_a, sign-extended to the lane width).
    output logic [  LPARA_LANE_W-1:0] o_result,
    output logic [LPARA_BYTE_NUM-1:0] o_byte_en,
    output logic [  LPARA_LANE_W-1:0] o_xs_data
);

  // SEW encodings handled by the lane.
  localparam logic [1:0] LPARA_SEW_8  = 2'd0;
  localparam logic [1:0] LPARA_SEW_32 = 2'd2;

  logic                    w_sew8;
  logic                    w_sew32;
  logic                    w_wr_op;
  logic [LPARA_LANE_W-1:0] w_b_eff;

  // Word (SEW = 32) results.
  logic [LPARA_LANE_W-1:0] w_add32;
  logic [LPARA_LANE_W-1:0] w_sra32;
  logic [LPARA_LANE_W-1:0] w_max32;
  logic [LPARA_LANE_W-1:0] w_sra32_fill;

  // Byte (SEW = 8) results, one per byte element.
  logic [LPARA_LANE_W-1:0] w_add8;
  logic [LPARA_LANE_W-1:0] w_sra8;
  logic [LPARA_LANE_W-1:0] w_max8;

  logic [LPARA_LANE_W-1:0] w_add_res;
  logic [LPARA_LANE_W-1:0] w_sra_res;
  logic [LPARA_LANE_W-1:0] w_max_res;

  // SEW decode and effective operand b: for a scalar operand at SEW = 8 the low byte is
  // replicated into every byte element; at SEW = 32 the word is used as is.
  assign w_sew8 = (i_sew == LPARA_SEW_8);
  assign w_sew32 = (i_sew == LPARA_SEW_32);
  assign w_b_eff = (i_b_scalar && w_sew8) ? {LPARA_BYTE_NUM{i_b[LPARA_BYTE_W-1:0]}} : i_b;
  // REQ-008

  // SEW = 32: add (wraps modulo 2^32), arithmetic shift right (shift = b[4:0], sign fill) and
  // signed max (sign bits flipped, then an unsigned compare).
  assign w_add32 = $bits(w_add32)'(i_a + w_b_eff);
  assign w_sra32_fill = i_a[LPARA_LANE_W-1] ? ~({LPARA_LANE_W{1'b1}} >> w_b_eff[LPARA_SH32_W-1:0])
                                            : '0;
  assign w_sra32 = (i_a >> w_b_eff[LPARA_SH32_W-1:0]) | w_sra32_fill;
  assign w_max32     = ({~i_a[LPARA_LANE_W-1], i_a[LPARA_LANE_W-2:0]} >
                        {~w_b_eff[LPARA_LANE_W-1], w_b_eff[LPARA_LANE_W-2:0]}) ? i_a : w_b_eff;
  // REQ-008

  // SEW = 8: four independent byte elements; carries and shifts never cross a byte boundary.
  for (genvar gen_idx = 0; gen_idx < LPARA_BYTE_NUM; gen_idx++) begin : gen_byte
    logic [LPARA_BYTE_W-1:0] w_a_byte;
    logic [LPARA_BYTE_W-1:0] w_b_byte;
    logic [LPARA_BYTE_W-1:0] w_sra_fill;
    logic [LPARA_BYTE_W-1:0] w_sra_byte;

    assign w_a_byte = i_a[gen_idx*LPARA_BYTE_W+:LPARA_BYTE_W];
    assign w_b_byte = w_b_eff[gen_idx*LPARA_BYTE_W+:LPARA_BYTE_W];
    assign w_sra_fill = w_a_byte[LPARA_BYTE_W-1] ?
                        ~({LPARA_BYTE_W{1'b1}} >> w_b_byte[LPARA_SH8_W-1:0]) : '0;
    assign w_sra_byte = (w_a_byte >> w_b_byte[LPARA_SH8_W-1:0]) | w_sra_fill;

    assign w_add8[gen_idx*LPARA_BYTE_W+:LPARA_BYTE_W] = $bits(w_a_byte)'(w_a_byte + w_b_byte);
    assign w_sra8[gen_idx*LPARA_BYTE_W+:LPARA_BYTE_W] = w_sra_byte;
    assign w_max8[gen_idx*LPARA_BYTE_W +: LPARA_BYTE_W] =
      ({~w_a_byte[LPARA_BYTE_W-1], w_a_byte[LPARA_BYTE_W-2:0]} >
       {~w_b_byte[LPARA_BYTE_W-1], w_b_byte[LPARA_BYTE_W-2:0]}) ? w_a_byte : w_b_byte;
  end
  // REQ-008

  // SEW selection of the arithmetic results; an illegal SEW yields zero (and no write enable).
  always_comb begin : p_com_sew_sel
    w_add_res = '0;
    w_sra_res = '0;
    w_max_res = '0;
    if (w_sew8) begin
      w_add_res = w_add8;
      w_sra_res = w_sra8;
      w_max_res = w_max8;
    end else if (w_sew32) begin
      w_add_res = w_add32;
      w_sra_res = w_sra32;
      w_max_res = w_max32;
    end
  end
  // REQ-008

  // Result selection by operation. vmv.v.x / vmv.s.x return the scalar element (splatted to
  // every element at SEW = 8; the full word at SEW = 32). Unknown operation returns zero.
  always_comb begin : p_com_result
    o_result = '0;
    if (i_is_vadd) begin
      o_result = w_add_res;
    end else if (i_is_vsra) begin
      o_result = w_sra_res;
    end else if (i_is_vmax) begin
      o_result = w_max_res;
    end else if (i_is_vmv_vx || i_is_vmv_sx) begin
      o_result = w_b_eff;
    end
  end
  // REQ-008

  // vmv.x.s scalar result: element 0 of vs2 sign-extended to the lane width (SEW < XLEN);
  // zero for every other operation.
  always_comb begin : p_com_xs
    o_xs_data = '0;
    if (i_is_vmv_xs) begin
      if (w_sew8) begin
        o_xs_data = {{(LPARA_LANE_W - LPARA_BYTE_W) {i_a[LPARA_BYTE_W-1]}}, i_a[LPARA_BYTE_W-1:0]};
      end else if (w_sew32) begin
        o_xs_data = i_a;
      end
    end
  end
  // REQ-008

  // Write enable per byte. Only the ops that write vd, at a legal SEW, enable bytes, and only for
  // active elements (index < vl): all other bytes of vd keep their value (tail-undisturbed).
  // At SEW = 32 element 0 controls all four bytes of the lane word. vmv.x.s writes no vd.
  assign w_wr_op = i_is_vadd | i_is_vsra | i_is_vmax | i_is_vmv_vx | i_is_vmv_sx;

  always_comb begin : p_com_byte_en
    o_byte_en = '0;
    if (w_wr_op) begin
      if (w_sew8) begin
        o_byte_en = i_elem_en;
      end else if (w_sew32) begin
        o_byte_en = {LPARA_BYTE_NUM{i_elem_en[0]}};
      end
    end
  end
  // REQ-008, REQ-059

endmodule
`default_nettype wire
