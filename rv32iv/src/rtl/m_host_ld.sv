`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Host load port: combinational 2:1 mux between the m_soc_bus DMEM port and the
 *                host access (i_ld_en = 1), plus the IMEM word write. A host DMEM access selects a
 *                32-bit lane of a PARA_VLEN row; the lane index is registered (resetless) to pick
 *                the read word one cycle after the request. IMEM reads, MMIO and unmapped
 *                addresses read 0 and writes to them change nothing. No handshake, no reset gating.
 * Parent       : m_soc_top
 * REQ-IDs      : REQ-018, REQ-019, REQ-020, REQ-021, REQ-022, REQ-042
 */
`timescale 1ns / 1ps

module m_host_ld #(
    // Parameter Description: width of one DMEM row (vector register width); the host word is 32 bits
    //                        and the lane index is i_ld_addr[log2(PARA_VLEN/8)-1:2].
    // Parameter values: legal values are 128 or 256 (checked at elaboration); default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    // Width of the byte address and of the host word.
    localparam logic [31:0] LPARA_XLEN       = 32,
    // Number of bytes in one host word (host byte enable width).
    localparam logic [31:0] LPARA_WORD_BYTES = 4,
    // Number of bytes in one DMEM row (row byte enable width).
    localparam logic [31:0] LPARA_BYTE_COUNT = PARA_VLEN / 8,
    // LB: number of byte address bits inside a row.
    localparam logic [31:0] LPARA_ROW_LB     = $clog2(PARA_VLEN / 8),
    // Number of 32-bit lanes (host words) in a row.
    localparam logic [31:0] LPARA_ROW_WORDS  = PARA_VLEN / 32,
    // Width of the lane index inside a row (byte address bits [LB-1:2]).
    localparam logic [31:0] LPARA_LANE_IDX_W = LPARA_ROW_LB - 2,
    // DMEM address bits (256 KB window) and IMEM address bits (32 KB window).
    localparam logic [31:0] LPARA_DMEM_AW    = 18,
    localparam logic [31:0] LPARA_IMEM_AW    = 15,
    // Width of the DMEM row index (address bits [17:LB]).
    localparam logic [31:0] LPARA_ROW_IDX_W  = LPARA_DMEM_AW - LPARA_ROW_LB,
    // Width of the IMEM word index (address bits [14:2]).
    localparam logic [31:0] LPARA_IMEM_IDX_W = LPARA_IMEM_AW - 2,
    // DMEM window tag i_ld_addr[31:18] (DMEM base 0x1000_0000).
    localparam logic [13:0] LPARA_DMEM_TAG   = 14'h0400
) (
    input  wire                         i_clk_core,
    // Host load port.
    input  wire                         i_ld_en,
    input  wire                         i_ld_req,
    input  wire                         i_ld_wr_en,
    input  wire  [      LPARA_XLEN-1:0] i_ld_addr,
    input  wire  [LPARA_WORD_BYTES-1:0] i_ld_byte_en,
    input  wire  [      LPARA_XLEN-1:0] i_ld_wr_data,
    output logic [      LPARA_XLEN-1:0] o_ld_rd_data,
    // DMEM port from m_soc_bus (row based, passed through when i_ld_en = 0).
    input  wire                         i_bus_dmem_en,
    input  wire                         i_bus_dmem_wr_en,
    input  wire  [ LPARA_ROW_IDX_W-1:0] i_bus_dmem_addr,
    input  wire  [LPARA_BYTE_COUNT-1:0] i_bus_dmem_byte_en,
    input  wire  [       PARA_VLEN-1:0] i_bus_dmem_wr_data,
    output logic [       PARA_VLEN-1:0] o_bus_dmem_rd_data,
    // DMEM port to m_dmem.
    input  wire  [       PARA_VLEN-1:0] i_dmem_rd_data,
    output logic                        o_dmem_en,
    output logic                        o_dmem_wr_en,
    output logic [ LPARA_ROW_IDX_W-1:0] o_dmem_addr,
    output logic [LPARA_BYTE_COUNT-1:0] o_dmem_byte_en,
    output logic [       PARA_VLEN-1:0] o_dmem_wr_data,
    // IMEM host write port to m_imem.
    output logic                        o_imem_wr_en,
    output logic [LPARA_IMEM_IDX_W-1:0] o_imem_wr_addr,
    output logic [      LPARA_XLEN-1:0] o_imem_wr_data
);

  logic                        w_addr_lo_ign;
  logic                        w_acc;
  logic                        w_imem_hit;
  logic                        w_dmem_hit;
  logic [LPARA_LANE_IDX_W-1:0] w_lane_idx;
  logic [ LPARA_ROW_IDX_W-1:0] w_row_idx;
  logic [LPARA_BYTE_COUNT-1:0] w_row_byte_en;
  logic [       PARA_VLEN-1:0] w_row_wr_data;
  logic [      LPARA_XLEN-1:0] w_rd_word;
  logic                        w_rd_hit_nxt;
  logic                        reg_rd_hit;
  logic [LPARA_LANE_IDX_W-1:0] reg_lane_idx;

  // Elaboration check of the legal parameter value.
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_host_ld: PARA_VLEN must be 128 or 256");
  end

  // Host access decode: one access per cycle with i_ld_en and i_ld_req both 1, no handshake.
  // IMEM window is i_ld_addr[31:15] = 0, DMEM window is i_ld_addr[31:18] = 14'h0400; any other
  // address (MMIO, unmapped) is a miss. Address bits [1:0] are ignored (word access).
  // The ignored byte-offset bits are folded in through a masked term that is constant 0, so they
  // are consumed by design (no unused-signal warning) without changing behavior.
  assign w_addr_lo_ign  = |(i_ld_addr[1:0] & 2'b00);
  assign w_acc          = i_ld_en & i_ld_req & ~w_addr_lo_ign;
  assign w_imem_hit     = (i_ld_addr[LPARA_XLEN-1:LPARA_IMEM_AW] == '0);
  assign w_dmem_hit     = (i_ld_addr[LPARA_XLEN-1:LPARA_DMEM_AW] == LPARA_DMEM_TAG);
  assign w_lane_idx     = i_ld_addr[LPARA_ROW_LB-1:2];
  assign w_row_idx      = i_ld_addr[LPARA_DMEM_AW-1:LPARA_ROW_LB];
  // REQ-019
  // REQ-020
  // REQ-022

  // IMEM write: a write hit in the IMEM window writes the whole word at index i_ld_addr[14:2] at
  // the request edge; i_ld_byte_en is ignored. Disabled (0) when i_ld_en = 0.
  assign o_imem_wr_en   = w_acc & i_ld_wr_en & w_imem_hit;
  assign o_imem_wr_addr = i_ld_addr[LPARA_IMEM_AW-1:2];
  assign o_imem_wr_data = i_ld_wr_data;
  // REQ-018
  // REQ-019

  // Row write data and byte enables: the host word is replicated on every lane and the 4 host byte
  // enables are placed on the selected lane only, so exactly the enabled bytes change.
  always_comb begin : p_com_row_wr
    w_row_wr_data = '0;
    w_row_byte_en = '0;
    for (int idx = 0; idx < LPARA_ROW_WORDS; idx++) begin
      w_row_wr_data[idx*LPARA_XLEN+:LPARA_XLEN] = i_ld_wr_data;
      if (w_lane_idx == LPARA_LANE_IDX_W'(idx)) begin
        w_row_byte_en[idx*LPARA_WORD_BYTES+:LPARA_WORD_BYTES] = i_ld_byte_en;
      end
    end
  end
  // REQ-020

  // DMEM 2:1 mux, combinational (no added cycle): i_ld_en = 0 passes the m_soc_bus port through
  // unchanged; i_ld_en = 1 gives the host access (enable only on a DMEM hit; byte enables only
  // for writes). The read row from m_dmem always returns to m_soc_bus.
  always_comb begin : p_com_dmem_mux
    if (i_ld_en) begin
      o_dmem_en      = w_acc & w_dmem_hit;
      o_dmem_wr_en   = i_ld_wr_en;
      o_dmem_addr    = w_row_idx;
      o_dmem_byte_en = i_ld_wr_en ? w_row_byte_en : '0;
      o_dmem_wr_data = w_row_wr_data;
    end else begin
      o_dmem_en      = i_bus_dmem_en;
      o_dmem_wr_en   = i_bus_dmem_wr_en;
      o_dmem_addr    = i_bus_dmem_addr;
      o_dmem_byte_en = i_bus_dmem_byte_en;
      o_dmem_wr_data = i_bus_dmem_wr_data;
    end
  end
  assign o_bus_dmem_rd_data = i_dmem_rd_data;
  // REQ-018

  // Host read data: m_dmem returns the row one cycle after the request; the registered lane index
  // selects the host word. Zero when the previous cycle was not a DMEM read hit (IMEM read, MMIO,
  // unmapped address, write or idle).
  assign w_rd_hit_nxt = w_acc & w_dmem_hit & ~i_ld_wr_en;

  always_comb begin : p_com_rd_word
    w_rd_word = '0;
    for (int idx = 0; idx < LPARA_ROW_WORDS; idx++) begin
      if (reg_lane_idx == LPARA_LANE_IDX_W'(idx)) begin
        w_rd_word = i_dmem_rd_data[idx*LPARA_XLEN+:LPARA_XLEN];
      end
    end
  end

  assign o_ld_rd_data = reg_rd_hit ? w_rd_word : '0;
  // REQ-021

  // Read-hit flag and lane-select register. Resetless on purpose: the host port stays functional
  // during reset (REQ-042) and both are rewritten every cycle, so they are only consumed in the
  // cycle after the request that wrote them (o_ld_rd_data is valid only then).
  always_ff @(posedge i_clk_core) begin : p_ff_rd_sel
    reg_rd_hit   <= w_rd_hit_nxt;
    reg_lane_idx <= w_lane_idx;
  end
  // REQ-021
  // REQ-042

endmodule
`default_nettype wire
