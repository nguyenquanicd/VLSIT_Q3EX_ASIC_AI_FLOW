`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Lane datapath, instantiated PARA_LANE_COUNT times.
 *
 *                Implementation notes: one 32-bit lane (gen_lane[i].u_lane) instantiated by
 *                m_vpu_top. The lane wraps the three datapath units m_lane_alu
 *                (vadd, vsra, vmax, vmv), m_lane_mul (vwmul.vv) and m_lane_narrow (vnclip), derives
 *                the per-byte element mask (index < vl: tail-undisturbed) from its lane index and the
 *                pass index, and collects the result of every EXEC pass in slot registers so that
 *                m_vpu_top can write the destination register(s) in the single WB cycle.
 *
 *                Pass p (m_vpu_ctrl o_pass_idx, EXEC state) of lane k works on one 32-bit source
 *                word per operand supplied by the parent. Slot s = pass index of the writing pass.
 *                Let N = PARA_LANE_COUNT, k = PARA_LANE_IDX, w = word index below, and each slot hold
 *                a 32-bit data word with a 4-bit byte enable:
 *                  vadd/vsra/vmax/vmv : pass p < PASS_N, w = p*N + k, source word w of vs2/vs1.
 *                                       Slot p = destination row word w (bytes enabled per element).
 *                  vwmul.vv           : pass p < 2*PASS_N, w = (p>>1)*N + k, source word w of vs2/vs1.
 *                                       Slot p = destination pair word 2*w + p[0] (pair = vd, vd+1,
 *                                       word 0 first), i.e. the low (p[0] = 0) or high half of the
 *                                       four 16-bit products of word w.
 *                  vnclip             : pass p < 2*PASS_N, w = p*N + k, source word w of the pair
 *                                       vs2, vs2+1 (word 0 first). Slot p holds one 16-bit result
 *                                       in bits [15:0] (byte enable bits [1:0]): the destination row
 *                                       bits [16*w +: 16] (32->16: one element; 16->8: two bytes).
 *                Slots that the instruction does not write have a byte enable of 0. The byte enables
 *                are cleared by i_clr_en (RD state) and at reset; slot data is resetless and is
 *                consumed only while its byte enable is set. vmv.x.s returns element 0 on o_xs_data,
 *                valid in lane 0 only (word 0 of vs2 is processed by lane 0 in pass 0).
 * Parent       : m_vpu_top
 * REQ-IDs      : none assigned (lane datapath integration of REQ-006, REQ-008, REQ-059, REQ-060)
 */
`timescale 1ns / 1ps

module m_vpu_lane #(
    // Parameter Description: vector register width (one memory row); the lane processes
    //                        PARA_VLEN / (PARA_LANE_COUNT x LPARA_LANE_W) words per row.
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN       = 128,
    // Parameter Description: number of parallel lanes of the VPU; PARA_VLEN must be divisible by
    //                        PARA_LANE_COUNT x LPARA_LANE_W.
    // Parameter values: legal values are 1, 2, 4, or 8; default is 4.
    // Parameter unit: count
    parameter  logic [31:0] PARA_LANE_COUNT = 4,
    // Parameter Description: index of this lane (0-based); selects the source words p x
    //                        PARA_LANE_COUNT + PARA_LANE_IDX processed by this lane.
    // Parameter values: 0 to PARA_LANE_COUNT - 1; default is 0.
    // Parameter unit: count
    parameter  logic [31:0] PARA_LANE_IDX   = 0,
    // Width of one lane datapath (spec-derived constant, LPARA_LANE_W).
    localparam logic [31:0] LPARA_LANE_W    = 32,
    // Number of byte elements per lane word and width of one byte.
    localparam logic [31:0] LPARA_BYTE_W    = 8,
    localparam logic [31:0] LPARA_BYTE_NUM  = LPARA_LANE_W / LPARA_BYTE_W,
    // Width of vl: the largest VLMAX is PARA_VLEN/8, so vl needs clog2(VLMAX + 1) bits.
    localparam logic [31:0] LPARA_VL_W      = $clog2(PARA_VLEN / 8 + 1),
    // Passes of a non-widening instruction, slots (passes of a widening/narrowing instruction)
    // and the width of the pass index.
    localparam logic [31:0] LPARA_PASS_N    = PARA_VLEN / (PARA_LANE_COUNT * LPARA_LANE_W),
    localparam logic [31:0] LPARA_SLOT_N    = LPARA_PASS_N + LPARA_PASS_N,
    localparam logic [31:0] LPARA_PASS_W    = $clog2(LPARA_SLOT_N),
    // Width of the vwmul product of one lane word (four 16-bit elements) and of a narrowed half-lane.
    localparam logic [31:0] LPARA_MUL_W     = LPARA_LANE_W + LPARA_LANE_W,
    localparam logic [31:0] LPARA_HALF_W    = LPARA_LANE_W / 2
) (
    input wire i_clk_core,
    input wire i_rst_n_core,

    // Control from m_vpu_ctrl: RD-state strobe that clears the slot byte enables, EXEC-state strobe
    // and the pass index valid while i_exec_en is 1.
    input wire                    i_clr_en,
    input wire                    i_exec_en,
    input wire [LPARA_PASS_W-1:0] i_pass_idx,

    // Operation flags from m_vpu_dec (one-hot, or all 0 when this lane has nothing to do).
    input wire i_is_vadd,
    input wire i_is_vsra,
    input wire i_is_vmax,
    input wire i_is_vmv_vx,
    input wire i_is_vmv_sx,
    input wire i_is_vmv_xs,
    input wire i_is_vnclip,
    input wire i_is_vwmul,

    // Current SEW encoding (2'd0 = 8, 2'd1 = 16, 2'd2 = 32 bit), element count vl and the operand b
    // form: scalar / 5-bit immediate (in i_b_word[4:0], see m_lane_alu) or a vs1 lane word.
    input wire [           1:0] i_sew,
    input wire [LPARA_VL_W-1:0] i_vl,
    input wire                  i_b_scalar,

    // Source words of this pass: i_a_word = vs2 word (or pair word for vnclip), i_b_word = vs1 word
    // (or scalar / imm5 with the shift amount in bits [4:0]).
    input wire [LPARA_LANE_W-1:0] i_a_word,
    input wire [LPARA_LANE_W-1:0] i_b_word,

    // Slot results: slot s occupies bits [32*s +: 32] of the data and [4*s +: 4] of the byte enable.
    output logic [  LPARA_SLOT_N*LPARA_LANE_W-1:0] o_res_data,
    output logic [LPARA_SLOT_N*LPARA_BYTE_NUM-1:0] o_res_byte_en,

    // vmv.x.s scalar result (element 0 of vs2, sign-extended); meaningful in lane 0 only.
    output logic [LPARA_LANE_W-1:0] o_xs_data
);

  // SEW encodings used by the lane operations.
  localparam logic [1:0] LPARA_SEW_8  = 2'd0;
  localparam logic [1:0] LPARA_SEW_16 = 2'd1;
  localparam logic [1:0] LPARA_SEW_32 = 2'd2;

  // Elaboration checks of the parameter combination (illegal values are rejected).
  if (PARA_LANE_COUNT == 0 || (PARA_LANE_COUNT & (PARA_LANE_COUNT - 1)) != 0) begin : gen_chk_lane
    $error("m_vpu_lane: PARA_LANE_COUNT must be a power of 2");
  end
  if (PARA_VLEN == 0 || (PARA_VLEN % (PARA_LANE_COUNT * LPARA_LANE_W)) != 0) begin : gen_chk_vlen
    $error("m_vpu_lane: PARA_VLEN must be divisible by PARA_LANE_COUNT x LPARA_LANE_W");
  end
  if (PARA_LANE_IDX >= PARA_LANE_COUNT) begin : gen_chk_idx
    $error("m_vpu_lane: PARA_LANE_IDX must be below PARA_LANE_COUNT");
  end

  // Word index and element masks.
  logic [  LPARA_PASS_W-1:0] w_src_pass;
  logic [    LPARA_VL_W-1:0] w_word;
  logic                      w_word_zero;
  logic                      w_sew8;
  logic                      w_sew16;
  logic                      w_sew32;
  logic [LPARA_BYTE_NUM-1:0] w_en_byte;
  logic                      w_en_word;
  logic [LPARA_BYTE_NUM-1:0] w_elem_en;
  logic                      w_mul_en_lo;
  logic                      w_mul_en_hi;
  logic [LPARA_BYTE_NUM-1:0] w_mul_be;
  logic                      w_nc_en_0;
  logic                      w_nc_en_1;
  logic [LPARA_BYTE_NUM-1:0] w_nc_be;

  // Unit results.
  logic [  LPARA_LANE_W-1:0] w_alu_res;
  logic [LPARA_BYTE_NUM-1:0] w_alu_be;
  logic [  LPARA_LANE_W-1:0] w_alu_xs;
  logic [   LPARA_MUL_W-1:0] w_mul_res;
  logic [  LPARA_HALF_W-1:0] w_nc_res;

  // Pass result before it is stored in its slot.
  logic                      w_alu_wr;
  logic [  LPARA_LANE_W-1:0] w_pass_data;
  logic [LPARA_BYTE_NUM-1:0] w_pass_be;
  logic [  LPARA_SLOT_N-1:0] w_slot_wr;
  logic [  LPARA_LANE_W-1:0] reg_xs_data;

  // SEW decode.
  assign w_sew8      = (i_sew == LPARA_SEW_8);
  assign w_sew16     = (i_sew == LPARA_SEW_16);
  assign w_sew32     = (i_sew == LPARA_SEW_32);

  // Word index of the source word: vwmul spends two passes per source word (low and high half of
  // the product), every other operation one pass per word. w = pass * PARA_LANE_COUNT + lane.
  assign w_src_pass  = i_is_vwmul ? $bits(w_src_pass)'(i_pass_idx >> 1) : i_pass_idx;
  assign w_word      = $bits(w_word)'(w_src_pass * PARA_LANE_COUNT + PARA_LANE_IDX);
  assign w_word_zero = (w_word == '0);
  // REQ-059

  // Element mask of the add/shift/max/move group. SEW = 8: byte j is element 4w + j. SEW = 32:
  // element w. vmv.s.x writes element 0 of the whole vector only (word 0, element slot 0).
  for (genvar gen_idx = 0; gen_idx < LPARA_BYTE_NUM; gen_idx++) begin : gen_en_byte
    assign w_en_byte[gen_idx] = ($bits(
        w_word
    )'(w_word * LPARA_BYTE_NUM + gen_idx) < i_vl) & (~i_is_vmv_sx | (w_word_zero & (gen_idx == 0)));
  end
  assign w_en_word = (w_word < i_vl) & (~i_is_vmv_sx | w_word_zero);
  assign w_elem_en = w_sew32 ? {{(LPARA_BYTE_NUM - 1) {1'b0}}, w_en_word} : w_en_byte;
  // REQ-059

  // vwmul byte enables of the half selected by the pass: elements 4w + 2h and 4w + 2h + 1
  // (h = i_pass_idx[0]) own two bytes each of the 32-bit slot word; only SEW = 8 is legal.
  assign w_mul_en_lo = w_sew8 & ($bits(
      w_word
  )'(w_word * LPARA_BYTE_NUM + (i_pass_idx[0] ? 2 : 0)) < i_vl);
  assign w_mul_en_hi = w_sew8 & ($bits(
      w_word
  )'(w_word * LPARA_BYTE_NUM + (i_pass_idx[0] ? 3 : 1)) < i_vl);
  assign w_mul_be = {w_mul_en_hi, w_mul_en_hi, w_mul_en_lo, w_mul_en_lo};
  // REQ-006, REQ-059

  // vnclip byte enables. 32 -> 16 (SEW = 16): destination element w gets two bytes. 16 -> 8
  // (SEW = 8): destination elements 2w and 2w + 1 get one byte each. Other SEW writes nothing.
  assign w_nc_en_0 = w_sew16 ? (w_word < i_vl) : (w_sew8 & ($bits(w_word)'(w_word * 2) < i_vl));
  assign w_nc_en_1 = w_sew16 ? (w_word < i_vl) : (w_sew8 & ($bits(w_word)'(w_word * 2 + 1) < i_vl));
  assign w_nc_be = {2'b00, w_nc_en_1, w_nc_en_0};
  // REQ-060, REQ-059

  // Datapath units. The add/shift/max/move unit receives the element mask and returns its own
  // byte enable; the multiplier and the narrowing unit are combinational on the pass words.
  m_lane_alu u_lane_alu (
      .i_is_vadd  (i_is_vadd),
      .i_is_vsra  (i_is_vsra),
      .i_is_vmax  (i_is_vmax),
      .i_is_vmv_vx(i_is_vmv_vx),
      .i_is_vmv_sx(i_is_vmv_sx),
      .i_is_vmv_xs(i_is_vmv_xs),
      .i_sew      (i_sew),
      .i_b_scalar (i_b_scalar),
      .i_a        (i_a_word),
      .i_b        (i_b_word),
      .i_elem_en  (w_elem_en),
      .o_result   (w_alu_res),
      .o_byte_en  (w_alu_be),
      .o_xs_data  (w_alu_xs)
  );

  m_lane_mul u_lane_mul (
      .i_op_a  (i_a_word),
      .i_op_b  (i_b_word),
      .o_result(w_mul_res)
  );

  m_lane_narrow u_lane_narrow (
      .i_src_data (i_a_word),
      .i_shift    (i_b_word[$clog2(LPARA_LANE_W)-1:0]),
      .i_src_is_32(w_sew16),
      .o_result   (w_nc_res)
  );
  // REQ-006, REQ-008, REQ-060

  // Pass result select: the operation flags are one-hot; vwmul returns the half of the products
  // chosen by pass bit 0, vnclip zero-extends its half-lane result, anything else returns zero
  // with no byte enable (vmv.x.s writes no vector register).
  assign w_alu_wr = i_is_vadd | i_is_vsra | i_is_vmax | i_is_vmv_vx | i_is_vmv_sx;

  always_comb begin : p_com_pass_res
    w_pass_data = '0;
    w_pass_be   = '0;
    if (w_alu_wr) begin
      w_pass_data = w_alu_res;
      w_pass_be   = w_alu_be;
    end else if (i_is_vwmul) begin
      if (i_pass_idx[0]) begin
        w_pass_data = w_mul_res[LPARA_MUL_W-1:LPARA_LANE_W];
      end else begin
        w_pass_data = w_mul_res[LPARA_LANE_W-1:0];
      end
      w_pass_be = w_mul_be;
    end else if (i_is_vnclip) begin
      w_pass_data = $bits(w_pass_data)'(w_nc_res);
      w_pass_be   = w_nc_be;
    end
  end
  // REQ-006, REQ-008, REQ-059, REQ-060

  // Slot write strobes: the slot whose index equals the current EXEC pass is written.
  for (genvar gen_idx = 0; gen_idx < LPARA_SLOT_N; gen_idx++) begin : gen_slot
    logic [  LPARA_LANE_W-1:0] reg_slot_data;
    logic [LPARA_BYTE_NUM-1:0] reg_slot_be;

    assign w_slot_wr[gen_idx] = i_exec_en & (i_pass_idx == LPARA_PASS_W'(gen_idx));

    // Slot byte enable (control state, reset): cleared by the RD strobe and at reset, loaded
    // with the pass byte enable when the slot is written.
    always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_slot_be
      if (!i_rst_n_core) begin
        reg_slot_be <= '0;
      end else if (i_clr_en) begin
        reg_slot_be <= '0;
      end else if (w_slot_wr[gen_idx]) begin
        reg_slot_be <= w_pass_be;
      end
    end

    // Slot payload: resetless; it is consumed only while the slot byte enable is set, which
    // happens only after this register has been written in the same pass.
    always_ff @(posedge i_clk_core) begin : p_ff_slot_data
      if (w_slot_wr[gen_idx]) begin
        reg_slot_data <= w_pass_data;
      end
    end

    assign o_res_data[gen_idx*LPARA_LANE_W+:LPARA_LANE_W]        = reg_slot_data;
    assign o_res_byte_en[gen_idx*LPARA_BYTE_NUM+:LPARA_BYTE_NUM] = reg_slot_be;
  end
  // REQ-059

  // vmv.x.s result: captured in pass 0 (word 0 of vs2 is processed by lane 0 in pass 0). The
  // register is resetless; the parent uses it only after a vmv.x.s instruction has run its passes.
  always_ff @(posedge i_clk_core) begin : p_ff_xs_data
    if (w_slot_wr[0]) begin
      reg_xs_data <= w_alu_xs;
    end
  end

  assign o_xs_data = reg_xs_data;
  // REQ-008

endmodule
`default_nettype wire
