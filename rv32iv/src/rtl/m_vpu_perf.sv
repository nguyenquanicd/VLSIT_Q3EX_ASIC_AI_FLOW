`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Vector-instruction cycle counter driving cycles.cnt. It counts i_clk_core cycles
 *                over an inclusive window: counting starts at 1 in the cycle after the start
 *                pulse (so the start cycle is counted) and includes the done-pulse cycle. The
 *                value of the last instruction is held until the next start and drives
 *                i_cycles_cnt of m_soc_csr (cycles.cnt); it is separate from m_csr_min.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-013
 */
`timescale 1ns / 1ps

module m_vpu_perf #(
    // Width of the cycle count (matches the 32-bit cycles.cnt field of m_soc_csr).
    localparam logic [31:0] LPARA_CNT_W = 32
) (
    input  wire                    i_clk_core,
    input  wire                    i_rst_n_core,
    // Instruction start: 1-cycle pulse on the accepted CPU command (m_vpu_if handshake).
    input  wire                    i_start,
    // Instruction done: 1-cycle completion pulse from m_vpu_ctrl (o_done).
    input  wire                    i_done,
    // Cycle count of the last (or the running) vector instruction, to i_cycles_cnt of m_soc_csr.
    output logic [LPARA_CNT_W-1:0] o_cycles_cnt
);

  // Internal signal declarations
  logic                   reg_run;
  logic                   w_run_nxt;
  logic [LPARA_CNT_W-1:0] reg_cycles_cnt;
  logic [LPARA_CNT_W-1:0] w_cycles_cnt_nxt;
  logic                   w_cnt_full;

  // Saturation flag: the count stops at all-ones instead of wrapping.
  assign w_cnt_full = &reg_cycles_cnt;
  // REQ-013

  // Run flag and count next-state logic.
  // - start: the count restarts at 1 (the start cycle itself) and the flag is set; a start has
  //   priority over a done in the same cycle (cannot occur: commands are accepted only when idle).
  // - running: the count increments every cycle including the done cycle; done clears the flag.
  // - not running: the count holds the value of the last instruction.
  always_comb begin : p_com_perf_nxt
    w_run_nxt        = reg_run;
    w_cycles_cnt_nxt = reg_cycles_cnt;
    if (i_start) begin
      w_run_nxt        = 1'b1;
      w_cycles_cnt_nxt = LPARA_CNT_W'(1'b1);
    end else if (reg_run) begin
      if (i_done) begin
        w_run_nxt = 1'b0;
      end
      if (!w_cnt_full) begin
        w_cycles_cnt_nxt = $bits(w_cycles_cnt_nxt)'(reg_cycles_cnt + LPARA_CNT_W'(1'b1));
      end
    end
  end
  // REQ-013

  // Control state: the run flag is cleared asynchronously by reset (no instruction running).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_perf_run
    if (!i_rst_n_core) reg_run <= 1'b0;
    else reg_run <= w_run_nxt;
  end
  // REQ-013

  // Cycle count register: cleared by reset so cycles.cnt reads 0 before the first instruction.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_perf_cnt
    if (!i_rst_n_core) reg_cycles_cnt <= '0;
    else reg_cycles_cnt <= w_cycles_cnt_nxt;
  end
  // REQ-013

  // Output mapping forwards the count to i_cycles_cnt of m_soc_csr (cycles.cnt).
  assign o_cycles_cnt = reg_cycles_cnt;
  // REQ-013

endmodule

`default_nettype wire
