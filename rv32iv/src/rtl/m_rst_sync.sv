/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Reset synchronizer: asynchronous assert, synchronous release (2 flops).
 * Parent       : m_soc_top (u_rst_sync)
 * REQ-IDs      : REQ-040, REQ-044
 */
`timescale 1ns / 1ps
`default_nettype none

module m_rst_sync (
    input  wire  i_clk_core,
    input  wire  i_rst_n_core,
    output logic o_rst_n_core
);

  // Internal signal declarations
  // Two-stage synchronizer chain; stage 1 may go metastable on release, stage 0 is the filter.
  logic reg_rst_sync_0;
  logic reg_rst_sync_1;

  // Reset synchronizer chain: asserting i_rst_n_core clears both flops immediately (async assert).
  // On release the constant 1 is shifted through two i_clk_core edges, so the internal reset
  // deasserts synchronously to i_clk_core. Reset aborts any in-flight instruction or APB
  // transfer in every block that receives o_rst_n_core. IMEM/DMEM contents are not cleared
  // here because this module only drives the reset net and the memories are resetless.
  // REQ-040, REQ-044
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_rst_sync
    if (!i_rst_n_core) begin
      reg_rst_sync_0 <= 1'b0;
      reg_rst_sync_1 <= 1'b0;
    end else begin
      reg_rst_sync_0 <= 1'b1;
      reg_rst_sync_1 <= reg_rst_sync_0;
    end
  end

  // Output mapping forwards the synchronized reset to the design.
  // REQ-040
  assign o_rst_n_core = reg_rst_sync_1;

endmodule

`default_nettype wire
