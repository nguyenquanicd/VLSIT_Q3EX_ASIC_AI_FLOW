/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : 256 KB single-port data memory wrapper, row-wide with byte enable. Each row is
 *                PARA_VLEN bits wide, with one write enable per byte. The read is registered: data
 *                appears in the cycle after the request, so the memory side never answers in the
 *                same cycle as the request. A same-row read during a write returns the old data (read-first). The
 *                array is inferred as FPGA block RAM; its initial contents come from the flow's
 *                memory initialization file, not from RTL. The memory has no reset input, so reset
 *                never clears or gates it. The lane and byte selection of a host or CPU address is
 *                done by the requester (m_host_ld / m_soc_bus / m_vpu_lsu), this module only sees a
 *                row index, a row-wide write data and a per-byte write mask.
 * Parent       : m_soc_top
 * REQ-IDs      : REQ-011, REQ-020, REQ-042, REQ-061, REQ-070, REQ-079
 */
`timescale 1ns / 1ps

module m_dmem #(
    // Parameter Description: width of one memory row, equal to the vector register width. The row
    //                        count is derived from it so that the total size stays 256 KB.
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter logic [31:0] PARA_VLEN = 128,
    localparam logic [31:0] LPARA_BYTE_W   = 8,
    localparam logic [31:0] LPARA_SIZE_B   = 262144,
    localparam logic [31:0] LPARA_ROW_B    = PARA_VLEN / LPARA_BYTE_W,
    localparam logic [31:0] LPARA_DEPTH    = LPARA_SIZE_B / LPARA_ROW_B,
    localparam logic [31:0] LPARA_ADDR_W   = $clog2(LPARA_DEPTH)
) (
    input  wire                     i_clk_core,
    input  wire                     i_en,
    input  wire                     i_wr_en,
    input  wire  [LPARA_ADDR_W-1:0] i_addr,
    input  wire  [ LPARA_ROW_B-1:0] i_byte_en,
    input  wire  [   PARA_VLEN-1:0] i_wr_data,
    output logic [   PARA_VLEN-1:0] o_rd_data
);

  // Elaboration check: only the supported row widths are accepted.
  if ((PARA_VLEN != 128) && (PARA_VLEN != 256)) begin : gen_para_chk
    $error("m_dmem: PARA_VLEN must be 128 or 256");
  end

  // Internal signal declarations
  // Memory array: not reset (REQ-042). Contents are defined by the flow's init file (REQ-070)
  // or by writes; consumers only use data that software or the host has written.
  logic [PARA_VLEN-1:0] reg_mem[0:LPARA_DEPTH-1];
  // Registered read data (1-cycle synchronous read).
  logic [PARA_VLEN-1:0] reg_rd_data;

  // Output mapping forwards the registered read data to the requester one cycle after the request.
  // REQ-011
  assign o_rd_data = reg_rd_data;

  // Byte-masked write: on an enabled write only the bytes whose enable bit is 1 change; all other
  // bytes of the row keep their value. The module has no reset input, so the write is never gated
  // by reset and a reset never clears the contents. The row index selects the 32-bit lane and the
  // byte mask by the requester (REQ-020).
  // REQ-011
  // REQ-020
  // REQ-042
  always_ff @(posedge i_clk_core) begin : p_ff_mem_wr
    if (i_en && i_wr_en) begin
      for (int idx = 0; idx < LPARA_ROW_B; idx++) begin
        if (i_byte_en[idx]) begin
          reg_mem[i_addr][(idx * LPARA_BYTE_W) +: LPARA_BYTE_W]
            <= i_wr_data[(idx * LPARA_BYTE_W) +: LPARA_BYTE_W];
        end
      end
    end
  end

  // Registered read: on a request the addressed row is captured at the rising edge and appears on
  // the output in the next cycle. There is no write-through path, so a read of the row being
  // written returns the old row (read-first).
  // The read register is resetless on purpose; the requester ignores it until it has issued a read.
  // The read data is never available in the request cycle, so the DMEM path answers at least
  // 1 cycle after o_mem_req rises, as m_vpu_lsu samples i_mem_ack only in WAIT.
  // REQ-011
  // REQ-061
  // REQ-079
  always_ff @(posedge i_clk_core) begin : p_ff_mem_rd
    if (i_en) begin
      reg_rd_data <= reg_mem[i_addr];
    end
  end

  // REQ-070: the module contains no initial block and no memory-load system task; memory
  // initialization is done by the flow's init file attached to this wrapper's memory.

endmodule
