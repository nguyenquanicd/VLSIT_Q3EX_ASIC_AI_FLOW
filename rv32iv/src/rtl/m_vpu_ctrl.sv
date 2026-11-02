`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : VPU control FSM (IDLE, DEC, RD, EXEC, WB, DONE), owns write-mask generation.
 *                One vector instruction is sequenced at a time: IDLE -> DEC (on the accepted CPU
 *                command) -> RD -> EXEC (one or more lane passes, or a load/store through m_vpu_lsu,
 *                or a reduction through m_vpu_reduce) -> WB -> DONE (1-cycle completion pulse) ->
 *                IDLE. Every command, including vsetvli/vsetivli, passes through all six states,
 *                so the latency from the command transfer to the DONE pulse is at least 5 cycles
 *                (IDLE, DEC, RD, >= 1 EXEC, WB); beyond that minimum it is multi-cycle and depends
 *                on the instruction (initiation interval = latency).
 *                Write-mask generation: the FSM sequences the mask steps through the one-hot
 *                strobes (RD clears the element byte enables, EXEC builds them per lane pass,
 *                WB commits the single masked register write), so tail elements are never written.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-008, REQ-031, REQ-032, REQ-036, REQ-041, REQ-044, REQ-059, REQ-062, REQ-067,
 *                REQ-087
 */
`timescale 1ns / 1ps

module m_vpu_ctrl #(
    // Parameter Description: vector register width; must be divisible by
    //                        PARA_LANE_COUNT x LPARA_LANE_W (checked at elaboration).
    // Parameter values: legal values are 128 or 256 (checked by m_vpu_top); default is 128.
    // Parameter unit: bit
    parameter logic [31:0] PARA_VLEN = 128,
    // Parameter Description: number of parallel lanes; sets the number of EXEC passes per instruction
    //                        (PARA_VLEN / (PARA_LANE_COUNT x LPARA_LANE_W)); power of 2.
    // Parameter values: legal values are 1, 2, 4, or 8; default is 4.
    // Parameter unit: count
    parameter logic [31:0] PARA_LANE_COUNT = 4,
    // Width of one lane datapath (spec-derived constant).
    localparam logic [31:0] LPARA_LANE_W = 32,
    // Number of EXEC passes of a non-widening lane instruction.
    localparam logic [31:0] LPARA_PASS_N = PARA_VLEN / (PARA_LANE_COUNT * LPARA_LANE_W),
    // Number of EXEC passes of a widening or narrowing lane instruction (double-width operand).
    localparam logic [31:0] LPARA_PASS_WIDE_N = LPARA_PASS_N + LPARA_PASS_N,
    // Width of the pass index (holds 0 .. LPARA_PASS_WIDE_N - 1).
    localparam logic [31:0] LPARA_PASS_W = $clog2(LPARA_PASS_WIDE_N),
    // Width of the scalar result forwarded to the CPU.
    localparam logic [31:0] LPARA_XLEN = 32
) (
    input  wire                     i_clk_core,
    input  wire                     i_rst_n_core,
    // Command handshake from m_vpu_if: 1-cycle pulse where i_cmd_valid and o_cmd_ready are both 1.
    input  wire                     i_cmd_xfer,
    // Decode of the latched instruction (from m_vpu_dec), stable from DEC to DONE.
    input  wire                     i_dec_mem,
    input  wire                     i_dec_reduce,
    input  wire                     i_dec_wide,
    input  wire                     i_dec_rd_wr,
    // Completion from the execution units and the scalar result candidate.
    input  wire                     i_lsu_done,
    input  wire                     i_reduce_done,
    input  wire  [  LPARA_XLEN-1:0] i_rd_data,
    // Status to m_vpu_if.
    output logic                    o_idle,
    output logic                    o_done,
    output logic                    o_rd_valid,
    output logic [  LPARA_XLEN-1:0] o_rd_data,
    // Step strobes to the VPU datapath (one-hot by FSM state).
    output logic                    o_dec_en,
    output logic                    o_rd_en,
    output logic                    o_exec_en,
    output logic                    o_wb_en,
    // Start pulses (RD state) for m_vpu_lsu and m_vpu_reduce; each finishes at least 1 cycle later.
    output logic                    o_lsu_start,
    output logic                    o_reduce_start,
    // Lane pass index and last-pass flag valid while o_exec_en is 1.
    output logic [LPARA_PASS_W-1:0] o_pass_idx,
    output logic                    o_pass_last
);

  // FSM states (3-bit code); unused encodings 3'b110 and 3'b111 recover to ENUM_ST_IDLE.
  typedef enum logic [2:0] {
    ENUM_ST_IDLE = 3'b000,
    ENUM_ST_DEC  = 3'b001,
    ENUM_ST_RD   = 3'b010,
    ENUM_ST_EXEC = 3'b011,
    ENUM_ST_WB   = 3'b100,
    ENUM_ST_DONE = 3'b101
  } vctrl_state_type_def;

  vctrl_state_type_def                    reg_fsm_vctrl_current_state;
  vctrl_state_type_def                    w_fsm_vctrl_nxt_state;

  logic                [LPARA_PASS_W-1:0] reg_pass_cnt;
  logic                [LPARA_PASS_W-1:0] w_pass_cnt_nxt;
  logic                [LPARA_PASS_W-1:0] w_pass_last_idx;
  logic                                   w_exec_lane;
  logic                                   w_exec_done;
  logic                                   reg_rd_valid;
  logic                                   w_rd_valid_nxt;
  logic                [  LPARA_XLEN-1:0] reg_rd_data;

  // Elaboration checks of the parameter combination (illegal values are rejected).
  if (PARA_LANE_COUNT == 0 || (PARA_LANE_COUNT & (PARA_LANE_COUNT - 1)) != 0) begin : gen_chk_lane
    $error("m_vpu_ctrl: PARA_LANE_COUNT must be a power of 2");
  end
  if (PARA_VLEN == 0 || (PARA_VLEN % (PARA_LANE_COUNT * LPARA_LANE_W)) != 0) begin : gen_chk_vlen
    $error("m_vpu_ctrl: PARA_VLEN must be divisible by PARA_LANE_COUNT x LPARA_LANE_W");
  end

  // State strobes: exactly one is 1 per state; an unused encoding drives none (recovers to IDLE).
  // o_idle is 1 only in the IDLE state, so m_vpu_if asserts o_cmd_ready only in IDLE.
  assign o_idle = (reg_fsm_vctrl_current_state == ENUM_ST_IDLE);
  assign o_dec_en = (reg_fsm_vctrl_current_state == ENUM_ST_DEC);
  assign o_rd_en = (reg_fsm_vctrl_current_state == ENUM_ST_RD);
  assign o_exec_en = (reg_fsm_vctrl_current_state == ENUM_ST_EXEC);
  assign o_wb_en = (reg_fsm_vctrl_current_state == ENUM_ST_WB);
  // o_done is high for exactly one cycle (DONE state lasts one cycle) per instruction.
  assign o_done = (reg_fsm_vctrl_current_state == ENUM_ST_DONE);
  // REQ-031, REQ-032, REQ-036

  // Unit start pulses: a load/store starts m_vpu_lsu and a reduction starts m_vpu_reduce while in RD,
  // so the unit runs during EXEC. The units report done at least 1 cycle after the start pulse.
  assign o_lsu_start = o_rd_en & i_dec_mem;
  assign o_reduce_start = o_rd_en & i_dec_reduce & ~i_dec_mem;
  // REQ-008, REQ-036

  // Lane passes: all other instructions run PASS_N passes (PASS_WIDE_N for double-width operands).
  // The pass index is a register; the last-pass flag compares it with the last index of the
  // instruction. Tail elements and unwritten registers are protected by the datapath write masks;
  // the destination is written only in the single WB cycle (o_wb_en).
  assign w_exec_lane = ~i_dec_mem & ~i_dec_reduce;
  assign w_pass_last_idx = i_dec_wide ? $bits(
      w_pass_last_idx
  )'(LPARA_PASS_WIDE_N - 1) : $bits(
      w_pass_last_idx
  )'(LPARA_PASS_N - 1);
  assign o_pass_idx = reg_pass_cnt;
  assign o_pass_last = (reg_pass_cnt == w_pass_last_idx);
  // REQ-008, REQ-059, REQ-062

  // EXEC completion: the load/store unit, the reduction unit or the last lane pass ends EXEC.
  always_comb begin : p_com_exec_done
    w_exec_done = o_pass_last;
    if (i_dec_mem) begin
      w_exec_done = i_lsu_done;
    end else if (i_dec_reduce) begin
      w_exec_done = i_reduce_done;
    end
  end
  // REQ-036, REQ-062, REQ-067

  // Pass counter next value: cleared in RD, incremented in EXEC for lane passes until the last one.
  always_comb begin : p_com_pass_cnt
    w_pass_cnt_nxt = reg_pass_cnt;
    if (o_rd_en) begin
      w_pass_cnt_nxt = '0;
    end else if (o_exec_en && w_exec_lane && !o_pass_last) begin
      w_pass_cnt_nxt = $bits(w_pass_cnt_nxt)'(reg_pass_cnt + 1'b1);
    end
  end
  // REQ-008, REQ-062

  // Next state: IDLE -> DEC on the command transfer, DEC -> RD -> EXEC, EXEC -> WB when the passes
  // (or the lsu/reduce unit) complete, WB -> DONE -> IDLE; unused codes recover to IDLE.
  // There is no shortcut around any state (vsetvli/vsetivli included): DEC, RD and WB last exactly
  // one cycle and EXEC at least one, so DONE is reached >= 5 cycles after the command transfer.
  always_comb begin : p_com_vctrl_fsm
    w_fsm_vctrl_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_vctrl_current_state)
      ENUM_ST_IDLE: begin
        if (i_cmd_xfer) begin
          w_fsm_vctrl_nxt_state = ENUM_ST_DEC;
        end else begin
          w_fsm_vctrl_nxt_state = ENUM_ST_IDLE;
        end
      end
      ENUM_ST_DEC:  w_fsm_vctrl_nxt_state = ENUM_ST_RD;
      ENUM_ST_RD:   w_fsm_vctrl_nxt_state = ENUM_ST_EXEC;
      ENUM_ST_EXEC: begin
        if (w_exec_done) begin
          w_fsm_vctrl_nxt_state = ENUM_ST_WB;
        end else begin
          w_fsm_vctrl_nxt_state = ENUM_ST_EXEC;
        end
      end
      ENUM_ST_WB:   w_fsm_vctrl_nxt_state = ENUM_ST_DONE;
      ENUM_ST_DONE: w_fsm_vctrl_nxt_state = ENUM_ST_IDLE;
      default:      w_fsm_vctrl_nxt_state = ENUM_ST_IDLE;
    endcase
  end
  // REQ-036, REQ-062, REQ-087

  // Scalar result flag: set in WB when the instruction writes a scalar register, cleared in DEC.
  always_comb begin : p_com_rd_valid
    w_rd_valid_nxt = reg_rd_valid;
    if (o_dec_en) begin
      w_rd_valid_nxt = 1'b0;
    end else if (o_wb_en) begin
      w_rd_valid_nxt = i_dec_rd_wr;
    end
  end
  // REQ-008

  // Scalar result forwarding: valid only together with the DONE pulse (m_vpu_if also qualifies it).
  assign o_rd_valid = reg_rd_valid & o_done;
  assign o_rd_data  = reg_rd_data;
  // REQ-008, REQ-031

  // Control state: asynchronous active-low reset. A reset aborts any in-flight instruction and
  // returns the FSM to IDLE with an empty pass counter and no scalar result (VPU registers and
  // memories outside this module are not touched).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vctrl_ctrl
    if (!i_rst_n_core) begin
      reg_fsm_vctrl_current_state <= ENUM_ST_IDLE;
      reg_pass_cnt                <= '0;
      reg_rd_valid                <= 1'b0;
    end else begin
      reg_fsm_vctrl_current_state <= w_fsm_vctrl_nxt_state;
      reg_pass_cnt                <= w_pass_cnt_nxt;
      reg_rd_valid                <= w_rd_valid_nxt;
    end
  end
  // REQ-036, REQ-041, REQ-044

  // Scalar result payload: captured in WB; resetless because it is consumed only while
  // reg_rd_valid (reset to 0, set in WB after this capture) is 1.
  always_ff @(posedge i_clk_core) begin : p_ff_rd_data
    if (o_wb_en) begin
      reg_rd_data <= i_rd_data;
    end
  end
  // REQ-008

endmodule
`default_nettype wire
