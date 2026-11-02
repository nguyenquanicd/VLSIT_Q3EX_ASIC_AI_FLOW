/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : 32 KB instruction memory wrapper (8192 x 32), single clock. One fetch read port
 *                with a registered 1-cycle read and one whole-word host write port. The array is
 *                inferred as FPGA block RAM; its initial contents come from the flow's memory
 *                initialization file, not from RTL. The memory has no reset and the host write
 *                port is not gated by reset.
 * Parent       : m_soc_top
 * REQ-IDs      : REQ-010, REQ-019, REQ-042, REQ-070
 */
`timescale 1ns / 1ps

module m_imem #(
    localparam logic [31:0] LPARA_DATA_W = 32,
    localparam logic [31:0] LPARA_DEPTH  = 8192,
    localparam logic [31:0] LPARA_ADDR_W = $clog2(LPARA_DEPTH)
) (
    input  wire                     i_clk_core,
    input  wire  [LPARA_ADDR_W-1:0] i_rd_addr,
    input  wire                     i_init_wr_en,
    input  wire  [LPARA_ADDR_W-1:0] i_init_wr_addr,
    input  wire  [LPARA_DATA_W-1:0] i_init_wr_data,
    output logic [LPARA_DATA_W-1:0] o_rd_data
);

  // Internal signal declarations
  // Memory array: not reset (REQ-042). Contents are defined by the flow's init file (REQ-070)
  // or by the host write port; the CPU only consumes fetched words after a program is loaded.
  logic [LPARA_DATA_W-1:0] reg_mem[0:LPARA_DEPTH-1];
  // Registered read data (1-cycle synchronous read).
  logic [LPARA_DATA_W-1:0] reg_rd_data;

  // Output mapping forwards the registered fetch data to the instruction fetch stage.
  // REQ-010
  assign o_rd_data = reg_rd_data;

  // Host write: when enabled, the whole 32-bit word at the word index is written at the rising
  // edge. The wrapper has no reset input, so the write is never gated by reset and a reset never
  // clears the contents. Byte enables are not used for IMEM.
  // REQ-019
  // REQ-042
  always_ff @(posedge i_clk_core) begin : p_ff_mem_wr
    if (i_init_wr_en) begin
      reg_mem[i_init_wr_addr] <= i_init_wr_data;
    end
  end

  // Fetch read: the addressed word is registered at the rising edge and appears on the output in
  // the next cycle. A same-cycle read of the word being written returns the old word.
  // The read register is resetless on purpose; the fetch stage ignores it until the first valid
  // fetch after reset.
  // REQ-010
  always_ff @(posedge i_clk_core) begin : p_ff_mem_rd
    reg_rd_data <= reg_mem[i_rd_addr];
  end

  // REQ-070: the module contains no initial block and no memory-load system task; memory
  // initialization is done by the flow's init file attached to this wrapper's memory.

endmodule
