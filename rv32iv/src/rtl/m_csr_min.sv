/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : CPU-side free-running cycle counter; does not feed cycles.cnt.
 * Parent       : m_cpu_top (u_csr_min)
 * REQ-IDs      : REQ-FUNC-013
 */
`timescale 1ns / 1ps
`default_nettype none

module m_csr_min #(
    // Parameter Description: width of the CPU-side cycle counter (RV32 XLEN-wide count).
    // Parameter values: fixed at 32 for RV32I; default is 32.
    // Parameter unit: bit
    parameter logic [31:0] PARA_CNT_W = 32
) (
    input wire i_clk_core,
    input wire i_rst_n_core,
    output logic [PARA_CNT_W-1:0] o_cycle_cnt
);

  // Internal signal declarations
  logic [PARA_CNT_W-1:0] reg_cycle_cnt;
  logic [PARA_CNT_W-1:0] w_cycle_cnt_nxt;

  // Next-count logic: increments by one each i_clk_core cycle and wraps at the counter width.
  // This counter is CPU-side only and is separate from the m_vpu_perf count behind cycles.cnt.
  // REQ-FUNC-013
  always_comb begin : p_com_cycle_cnt
    w_cycle_cnt_nxt = $bits(w_cycle_cnt_nxt)'(reg_cycle_cnt + PARA_CNT_W'(1'b1));
  end

  // Cycle counter register: cleared asynchronously by reset, otherwise free-running.
  // REQ-FUNC-013
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_cycle_cnt
    if (!i_rst_n_core) reg_cycle_cnt <= '0;
    else reg_cycle_cnt <= w_cycle_cnt_nxt;
  end

  // Output mapping forwards the counter value to the CPU; it is not connected to cycles.cnt.
  // REQ-FUNC-013
  assign o_cycle_cnt = reg_cycle_cnt;

endmodule

`default_nettype wire
