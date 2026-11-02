`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : vwredsum reduction unit. The signed 16-bit elements of
 *                the source register pair vs2 (PARA_VLEN/8 elements, element index < vl) are
 *                accumulated into a signed 32-bit sum that starts at the scalar vs1[0]. One step
 *                consumes one 32-bit word per lane (PARA_LANE_COUNT words = 2 x PARA_LANE_COUNT
 *                elements); the cross-lane step sum is registered (pipeline register) before it is
 *                added to the accumulator. The steps are sequenced by a small FSM (IDLE, RUN,
 *                DRAIN, DONE); DRAIN accumulates the last registered step. The 32-bit
 *                sum is returned as element 0 of the destination row together with a byte write
 *                mask, so all other destination bytes stay unchanged (tail-undisturbed). The
 *                latency is multi-cycle (steps + 2 cycles after the start pulse) and not fixed by
 *                the spec beyond the 5-cycle minimum of the vector instruction, which is enforced
 *                by the instruction controller m_vpu_ctrl, not by this module.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-007, REQ-062
 */
`timescale 1ns / 1ps

module m_vpu_reduce #(
    // Parameter Description: vector register width. The source operand is a register pair
    //                        (2 x PARA_VLEN bits = PARA_VLEN/8 elements of 16 bits, the product of a
    //                        vwmul.vv); must satisfy PARA_VLEN % (16 x PARA_LANE_COUNT) == 0.
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    // Parameter Description: number of parallel lanes; each lane delivers one 32-bit word
    //                        (two 16-bit elements) per reduction step.
    // Parameter values: legal values are 1, 2, 4, or 8; default is 4.
    // Parameter unit: count
    parameter  logic [31:0] PARA_LANE_COUNT  = 4,
    // Width of one source element (INT16) and of one lane word.
    localparam logic [31:0] LPARA_ELEM_W     = 16,
    localparam logic [31:0] LPARA_LANE_W     = 32,
    // Width of the signed sum (INT32) and of a byte of the write mask.
    localparam logic [31:0] LPARA_SUM_W      = 32,
    localparam logic [31:0] LPARA_BYTE_W     = 8,
    // Elements per lane word, number of write-mask bytes of one row and number of bytes of the sum.
    localparam logic [31:0] LPARA_HALF_N     = LPARA_LANE_W / LPARA_ELEM_W,
    localparam logic [31:0] LPARA_BYTE_COUNT = PARA_VLEN / LPARA_BYTE_W,
    localparam logic [31:0] LPARA_SUM_BYTES  = LPARA_SUM_W / LPARA_BYTE_W,
    // Width of vl: the largest VLMAX is PARA_VLEN/8 (SEW = 8), so vl needs clog2(VLMAX + 1) bits.
    localparam logic [31:0] LPARA_VL_W       = $clog2(PARA_VLEN / 8 + 1),
    // Number of 32-bit words of the register pair, number of reduction steps and their index width.
    localparam logic [31:0] LPARA_WORD_N     = (PARA_VLEN + PARA_VLEN) / LPARA_LANE_W,
    localparam logic [31:0] LPARA_WORD_IDX_W = $clog2(LPARA_WORD_N),
    localparam logic [31:0] LPARA_STEP_N     = LPARA_WORD_N / PARA_LANE_COUNT,
    localparam logic [31:0] LPARA_STEP_W     = (LPARA_STEP_N > 1) ? $clog2(LPARA_STEP_N) : 1
) (
    input  wire                         i_clk_core,
    input  wire                         i_rst_n_core,
    // Start pulse from m_vpu_ctrl (RD state), the element count vl and the operands: the register pair
    // vs2 (low half = vs2, high half = vs2+1) and element 0 of vs1 (initial scalar). The operands are
    // held stable by the register file / decode until the write-back, so they are not copied.
    input  wire                         i_start,
    input  wire  [      LPARA_VL_W-1:0] i_vl,
    input  wire  [       PARA_VLEN-1:0] i_vs2_lo,
    input  wire  [       PARA_VLEN-1:0] i_vs2_hi,
    input  wire  [     LPARA_SUM_W-1:0] i_vs1_elem0,
    // Completion pulse to m_vpu_ctrl (1 cycle, at least 1 cycle after the start pulse).
    output logic                        o_done,
    // Destination row: the sum in element 0, and the byte mask of the bytes to write.
    output logic [       PARA_VLEN-1:0] o_wr_data,
    output logic [LPARA_BYTE_COUNT-1:0] o_wr_byte_en
);

  // FSM states: idle until a start pulse, compute one step sum per cycle, drain the last registered
  // step into the accumulator, then a 1-cycle done pulse. All four encodings are used; the default
  // branch of the next-state logic still recovers to ENUM_ST_IDLE.
  typedef enum logic [1:0] {
    ENUM_ST_IDLE  = 2'b00,
    ENUM_ST_RUN   = 2'b01,
    ENUM_ST_DONE  = 2'b10,
    ENUM_ST_DRAIN = 2'b11
  } vred_state_type_def;

  vred_state_type_def                    reg_fsm_vred_current_state;
  vred_state_type_def                    w_fsm_vred_nxt_state;

  logic               [LPARA_STEP_W-1:0] reg_step;
  logic               [LPARA_STEP_W-1:0] w_step_nxt;
  logic                                  w_step_last;
  logic               [ LPARA_SUM_W-1:0] reg_acc;
  logic               [ LPARA_SUM_W-1:0] w_acc_nxt;
  logic               [ LPARA_SUM_W-1:0] w_step_sum;
  logic               [ LPARA_SUM_W-1:0] reg_step_sum;
  logic                                  reg_step_vld;
  logic               [ 2*PARA_VLEN-1:0] w_vs2_pair;
  logic               [LPARA_LANE_W-1:0] w_word                     [   LPARA_WORD_N-1:0];
  logic               [ LPARA_SUM_W-1:0] w_lane_sum                 [PARA_LANE_COUNT-1:0];

  // Elaboration checks of the parameter combination (illegal values are rejected).
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_vpu_reduce: PARA_VLEN must be 128 or 256");
  end
  if (PARA_LANE_COUNT == 0 || (PARA_LANE_COUNT & (PARA_LANE_COUNT - 1)) != 0) begin : gen_chk_lane
    $error("m_vpu_reduce: PARA_LANE_COUNT must be a power of 2");
  end
  if (PARA_LANE_COUNT != 0 &&
      ((PARA_VLEN + PARA_VLEN) % (LPARA_LANE_W * PARA_LANE_COUNT)) != 0) begin : gen_chk_div
    $error("m_vpu_reduce: PARA_VLEN must be divisible by 16 x PARA_LANE_COUNT");
  end

  // Source register pair split into 32-bit words (word w holds elements 2w and 2w+1).
  assign w_vs2_pair = {i_vs2_hi, i_vs2_lo};
  for (genvar gen_word = 0; gen_word < LPARA_WORD_N; gen_word++) begin : gen_word_split
    assign w_word[gen_word] = w_vs2_pair[gen_word*LPARA_LANE_W+:LPARA_LANE_W];
  end
  // REQ-007

  // Per-lane partial sum of one step: the lane picks word (step x lanes + lane); each of its two
  // INT16 elements is sign-extended to 32 bits and zeroed when its index is not below vl.
  for (genvar gen_lane = 0; gen_lane < PARA_LANE_COUNT; gen_lane++) begin : gen_lane_sum
    logic [LPARA_WORD_IDX_W-1:0] w_word_idx;
    logic [    LPARA_LANE_W-1:0] w_word_sel;
    logic [      LPARA_VL_W-1:0] w_idx_lo;
    logic [      LPARA_VL_W-1:0] w_idx_hi;
    logic [     LPARA_SUM_W-1:0] w_ext_lo;
    logic [     LPARA_SUM_W-1:0] w_ext_hi;
    logic                        w_sel_lo;
    logic                        w_sel_hi;

    assign w_word_idx = LPARA_WORD_IDX_W'(32'(reg_step) * PARA_LANE_COUNT + 32'(gen_lane));
    assign w_word_sel = w_word[w_word_idx];
    assign w_idx_lo = LPARA_VL_W'((32'(reg_step) * PARA_LANE_COUNT + 32'(gen_lane)) * LPARA_HALF_N);
    assign w_idx_hi = LPARA_VL_W'(w_idx_lo + 1'b1);
    assign w_sel_lo = (w_idx_lo < i_vl);
    assign w_sel_hi = (w_idx_hi < i_vl);
    assign w_ext_lo = {
      {(LPARA_SUM_W - LPARA_ELEM_W) {w_word_sel[LPARA_ELEM_W-1]}}, w_word_sel[LPARA_ELEM_W-1:0]
    };
    assign w_ext_hi = {
      {(LPARA_SUM_W - LPARA_ELEM_W) {w_word_sel[LPARA_LANE_W-1]}},
      w_word_sel[LPARA_LANE_W-1:LPARA_ELEM_W]
    };
    assign w_lane_sum[gen_lane] = $bits(
        w_lane_sum[gen_lane]
    )'((w_ext_lo & {LPARA_SUM_W{w_sel_lo}}) + (w_ext_hi & {LPARA_SUM_W{w_sel_hi}}));
  end
  // REQ-007

  // Cross-lane sum of one step: adds the partial sums of all lanes (wraps on 32 bits; the sum of up
  // to 784 INT16 products and the initial scalar fits without overflow).
  always_comb begin : p_com_step_sum
    w_step_sum = '0;
    for (int idx = 0; idx < PARA_LANE_COUNT; idx++) begin
      w_step_sum = $bits(w_step_sum)'(w_step_sum + w_lane_sum[idx]);
    end
  end
  // REQ-007

  // Accumulator next value: loaded with vs1[0] on the start pulse in IDLE, then adds the registered
  // step sum whenever it is valid (one cycle after each RUN cycle, including the DRAIN cycle);
  // otherwise it holds the finished sum.
  always_comb begin : p_com_acc
    w_acc_nxt = reg_acc;
    if (reg_step_vld) begin
      w_acc_nxt = $bits(w_acc_nxt)'(reg_acc + reg_step_sum);
    end else if (reg_fsm_vred_current_state == ENUM_ST_IDLE && i_start) begin
      w_acc_nxt = i_vs1_elem0;
    end
  end
  // REQ-007

  // Step counter: counts the RUN cycles 0 .. LPARA_STEP_N - 1 and is 0 in every other state.
  assign w_step_last = (reg_step == $bits(reg_step)'(LPARA_STEP_N - 1));
  always_comb begin : p_com_step
    w_step_nxt = '0;
    if (reg_fsm_vred_current_state == ENUM_ST_RUN && !w_step_last) begin
      w_step_nxt = $bits(w_step_nxt)'(reg_step + 1'b1);
    end
  end
  // REQ-062

  // Next state: IDLE -> RUN on the start pulse, RUN -> DRAIN after the last step, DRAIN -> DONE,
  // DONE -> IDLE; any other code recovers to IDLE.
  always_comb begin : p_com_vred_fsm
    w_fsm_vred_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_vred_current_state)
      ENUM_ST_IDLE: begin
        if (i_start) begin
          w_fsm_vred_nxt_state = ENUM_ST_RUN;
        end else begin
          w_fsm_vred_nxt_state = ENUM_ST_IDLE;
        end
      end
      ENUM_ST_RUN: begin
        if (w_step_last) begin
          w_fsm_vred_nxt_state = ENUM_ST_DRAIN;
        end else begin
          w_fsm_vred_nxt_state = ENUM_ST_RUN;
        end
      end
      ENUM_ST_DRAIN: w_fsm_vred_nxt_state = ENUM_ST_DONE;
      ENUM_ST_DONE:  w_fsm_vred_nxt_state = ENUM_ST_IDLE;
      default:       w_fsm_vred_nxt_state = ENUM_ST_IDLE;
    endcase
  end
  // REQ-062

  // Completion pulse: the DONE state lasts exactly 1 cycle per reduction.
  assign o_done = (reg_fsm_vred_current_state == ENUM_ST_DONE);
  // REQ-062

  // Destination row: the sum occupies element 0 (bits 31:0), all other bits are 0 and not written.
  // The low 4 bytes are enabled only when vl != 0 (no element is written for vl = 0), so every
  // other destination element keeps its old value.
  always_comb begin : p_com_result
    o_wr_data    = '0;
    o_wr_data[LPARA_SUM_W-1:0] = reg_acc;
    o_wr_byte_en = '0;
    if (i_vl != '0) begin
      o_wr_byte_en[LPARA_SUM_BYTES-1:0] = {LPARA_SUM_BYTES{1'b1}};
    end
  end
  // REQ-007

  // Control state: asynchronous active-low reset aborts a running reduction and returns to IDLE.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vred_ctrl
    if (!i_rst_n_core) begin
      reg_fsm_vred_current_state <= ENUM_ST_IDLE;
      reg_step                   <= '0;
      reg_step_vld               <= 1'b0;
    end else begin
      reg_fsm_vred_current_state <= w_fsm_vred_nxt_state;
      reg_step                   <= w_step_nxt;
      reg_step_vld               <= (reg_fsm_vred_current_state == ENUM_ST_RUN);
    end
  end
  // REQ-062

  // Accumulator payload: resetless because it is loaded with vs1[0] on every start pulse and
  // consumed only after the DONE pulse of that reduction.
  always_ff @(posedge i_clk_core) begin : p_ff_acc
    reg_acc <= w_acc_nxt;
  end
  // REQ-007

  // Pipeline register of the cross-lane step sum: resetless payload, consumed by the accumulator
  // only while reg_step_vld (reset to 0) marks it as the registered result of a RUN cycle.
  always_ff @(posedge i_clk_core) begin : p_ff_step_sum
    reg_step_sum <= w_step_sum;
  end
  // REQ-007

endmodule
`default_nettype wire
