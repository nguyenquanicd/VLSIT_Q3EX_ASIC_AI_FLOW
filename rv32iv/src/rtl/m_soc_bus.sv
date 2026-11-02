`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Address decode, CPU/VPU memory mux and MMIO routing. Memory map: IMEM 0x0000_0000
 *                (32 KB, fetch/host-write only), DMEM 0x1000_0000 (256 KB), MMIO 0x2000_0000 (4 KB).
 *                The CPU 32-bit data bus and the VPU row bus are muxed onto the single DMEM row port
 *                (the VPU wins, there is no arbitration because the CPU stalls during vector
 *                instructions). A DMEM access is issued in the first request cycle and acknowledged
 *                in the next cycle, when the registered DMEM read data is valid. CPU accesses to the
 *                MMIO region are routed to the APB master; CPU accesses to any other address,
 *                including the IMEM range, are unmapped: read 0, write ignored, immediate ack, no
 *                error flag. Only the row part of the VPU address is significant: the low
 *                log2(PARA_VLEN/8) bits may be driven unmodified or cleared by the VPU and are
 *                ignored here (not checked), so every VPU access is a row access. A VPU access
 *                outside DMEM is acknowledged at once: a read returns 0, a write is ignored, no
 *                error is raised. A DMEM access is acknowledged at least 1 cycle after the request
 *                rises, as m_vpu_lsu samples the ack only in its WAIT state.
 *                Assumptions (checked by assertions, no logic): the CPU and the VPU never request
 *                DMEM in the same cycle, and the host never accesses DMEM while i_rst_n_core = 1.
 * Parent       : m_soc_top
 * REQ-IDs      : REQ-015, REQ-033, REQ-034, REQ-057, REQ-058, REQ-079, REQ-082
 */
`timescale 1ns / 1ps

module m_soc_bus #(
    // Parameter Description: width of one DMEM row / VPU memory row; the DMEM row index and the
    //                        CPU word-lane select are derived from it.
    // Parameter values: legal values are 128 or 256 (checked at elaboration); default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    // Width of the CPU data bus and of the MMIO address space word.
    localparam logic [31:0] LPARA_XLEN       = 32,
    // Number of byte lanes of the CPU data bus.
    localparam logic [31:0] LPARA_WORD_BYTES = LPARA_XLEN / 8,
    // Number of low address bits that select the byte inside a CPU word.
    localparam logic [31:0] LPARA_WORD_LB    = $clog2(LPARA_XLEN / 8),
    // Number of byte lanes of one DMEM / VPU row (byte-enable width).
    localparam logic [31:0] LPARA_BYTE_COUNT = PARA_VLEN / 8,
    // Number of low address bits ignored for row alignment.
    localparam logic [31:0] LPARA_ROW_LB     = $clog2(PARA_VLEN / 8),
    // Number of CPU words in one row.
    localparam logic [31:0] LPARA_WORD_COUNT = PARA_VLEN / LPARA_XLEN,
    // Width of the CPU word-lane select inside a row.
    localparam logic [31:0] LPARA_LANE_W     = LPARA_ROW_LB - LPARA_WORD_LB,
    // DMEM base address.
    localparam logic [31:0] LPARA_DMEM_BASE  = 32'h1000_0000,
    // DMEM size as log2 of its byte count (256 KB).
    localparam logic [31:0] LPARA_DMEM_SIZE  = 18,
    // Width of the DMEM row index.
    localparam logic [31:0] LPARA_DMEM_ROW_W = LPARA_DMEM_SIZE - LPARA_ROW_LB,
    // MMIO base address.
    localparam logic [31:0] LPARA_MMIO_BASE  = 32'h2000_0000,
    // MMIO size as log2 of its byte count (4 KB).
    localparam logic [31:0] LPARA_MMIO_SIZE  = 12
) (
    input  wire                         i_clk_core,
    input  wire                         i_rst_n_core,
    // CPU data bus (from m_lsu): the request is held until o_cpu_ack.
    input  wire                         i_cpu_req,
    input  wire                         i_cpu_wr_en,
    input  wire  [LPARA_WORD_BYTES-1:0] i_cpu_byte_en,
    input  wire  [      LPARA_XLEN-1:0] i_cpu_addr,
    input  wire  [      LPARA_XLEN-1:0] i_cpu_wr_data,
    // VPU memory bus (from m_vpu_top): the request is held until o_vpu_ack.
    input  wire                         i_vpu_req,
    input  wire                         i_vpu_wr_en,
    input  wire  [LPARA_BYTE_COUNT-1:0] i_vpu_byte_en,
    input  wire  [      LPARA_XLEN-1:0] i_vpu_addr,
    input  wire  [       PARA_VLEN-1:0] i_vpu_wr_data,
    // DMEM read data (registered, valid in the cycle after the request).
    input  wire  [       PARA_VLEN-1:0] i_dmem_rd_data,
    // MMIO response from the APB master.
    input  wire  [      LPARA_XLEN-1:0] i_mmio_rd_data,
    input  wire                         i_mmio_ack,
    // CPU response.
    output logic [      LPARA_XLEN-1:0] o_cpu_rd_data,
    output logic                        o_cpu_ack,
    // VPU response.
    output logic [       PARA_VLEN-1:0] o_vpu_rd_data,
    output logic                        o_vpu_ack,
    // DMEM row port (towards the host mux in front of m_dmem).
    output logic                        o_dmem_en,
    output logic                        o_dmem_wr_en,
    output logic [LPARA_DMEM_ROW_W-1:0] o_dmem_addr,
    output logic [LPARA_BYTE_COUNT-1:0] o_dmem_byte_en,
    output logic [       PARA_VLEN-1:0] o_dmem_wr_data,
    // MMIO request towards the APB master: full CPU address, byte enables and write data.
    output logic                        o_mmio_req,
    output logic                        o_mmio_wr_en,
    output logic [LPARA_WORD_BYTES-1:0] o_mmio_byte_en,
    output logic [      LPARA_XLEN-1:0] o_mmio_addr,
    output logic [      LPARA_XLEN-1:0] o_mmio_wr_data
);

  logic                        w_cpu_dmem_sel;
  logic                        w_cpu_mmio_sel;
  logic                        w_cpu_unmapped;
  logic                        w_vpu_dmem_sel;
  logic                        w_cpu_issue;
  logic                        w_vpu_issue;
  logic                        reg_cpu_ack;
  logic                        reg_vpu_ack;
  logic                        w_cpu_ack_nxt;
  logic                        w_vpu_ack_nxt;
  logic [    LPARA_LANE_W-1:0] w_cpu_lane;
  logic [    LPARA_LANE_W-1:0] reg_cpu_lane;
  logic [LPARA_BYTE_COUNT-1:0] w_cpu_row_be;
  logic [      LPARA_XLEN-1:0] w_cpu_dmem_rd;
  logic [LPARA_DMEM_ROW_W-1:0] w_cpu_row_addr;

  // Elaboration check of the legal parameter value.
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_soc_bus: PARA_VLEN must be 128 or 256");
  end

  // Region match: the address bits above the region size equal the region base.
  function automatic logic f_in_region(input logic [LPARA_XLEN-1:0] addr,
                                       input logic [LPARA_XLEN-1:0] base,
                                       input logic [31:0] size_lb);
    logic [LPARA_XLEN-1:0] w_diff;
    w_diff = LPARA_XLEN'((addr ^ base) >> size_lb);
    return (w_diff == '0);
  endfunction

  // Address decode: CPU data accesses hit DMEM or MMIO; everything else, including the IMEM range
  // 0x0000_0000-0x0000_7FFF (fetch and host write only), is unmapped. The VPU only targets DMEM.
  assign w_cpu_dmem_sel = i_cpu_req & f_in_region(i_cpu_addr, LPARA_DMEM_BASE, LPARA_DMEM_SIZE);
  assign w_cpu_mmio_sel = i_cpu_req & f_in_region(i_cpu_addr, LPARA_MMIO_BASE, LPARA_MMIO_SIZE);
  assign w_cpu_unmapped = i_cpu_req & ~w_cpu_dmem_sel & ~w_cpu_mmio_sel;
  assign w_vpu_dmem_sel = i_vpu_req & f_in_region(i_vpu_addr, LPARA_DMEM_BASE, LPARA_DMEM_SIZE);
  // REQ-015, REQ-057

  // DMEM issue: a request is sent to DMEM in its first cycle only (not again while the registered
  // ack is high). The VPU has priority; the CPU never requests DMEM together with the VPU.
  assign w_vpu_issue = w_vpu_dmem_sel & ~reg_vpu_ack;
  assign w_cpu_issue = w_cpu_dmem_sel & ~i_vpu_req & ~reg_cpu_ack;
  // REQ-015, REQ-034

  // Ack registers: set in the cycle after a DMEM issue, when the DMEM read data is valid, and
  // cleared in the following cycle so that the next access can issue again. The VPU ack is
  // therefore never combinational with its request, which meets the 1-cycle minimum latency
  // that m_vpu_lsu needs (it samples the ack only in WAIT).
  assign w_vpu_ack_nxt = w_vpu_issue;
  assign w_cpu_ack_nxt = w_cpu_issue;

  // Ack state: asynchronous active-low reset, no ack after reset.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_ack
    if (!i_rst_n_core) begin
      reg_cpu_ack <= 1'b0;
      reg_vpu_ack <= 1'b0;
    end else begin
      reg_cpu_ack <= w_cpu_ack_nxt;
      reg_vpu_ack <= w_vpu_ack_nxt;
    end
  end
  // REQ-015, REQ-079

  // CPU word lane inside the row. The lane of the issued access is captured for the read data
  // select in the ack cycle. Resetless: consumed only while reg_cpu_ack = 1.
  assign w_cpu_lane = i_cpu_addr[LPARA_ROW_LB-1:LPARA_WORD_LB];

  always_ff @(posedge i_clk_core) begin : p_ff_cpu_lane
    if (w_cpu_issue) begin
      reg_cpu_lane <= w_cpu_lane;
    end
  end
  // REQ-015

  // CPU to row mapping: byte enables are placed in the addressed word lane; the write data is
  // replicated to every lane (only the enabled lane is written). The read word is picked from
  // the row by the captured lane.
  always_comb begin : p_com_cpu_lane
    w_cpu_row_be  = '0;
    w_cpu_dmem_rd = '0;
    for (int idx = 0; idx < LPARA_WORD_COUNT; idx++) begin
      if (w_cpu_lane == LPARA_LANE_W'(idx)) begin
        w_cpu_row_be[idx*LPARA_WORD_BYTES+:LPARA_WORD_BYTES] = i_cpu_byte_en;
      end
      if (reg_cpu_lane == LPARA_LANE_W'(idx)) begin
        w_cpu_dmem_rd = i_dmem_rd_data[idx*LPARA_XLEN+:LPARA_XLEN];
      end
    end
  end
  // REQ-015

  // DMEM row address of the CPU access (row-aligned by dropping the low bits).
  assign w_cpu_row_addr = LPARA_DMEM_ROW_W'(i_cpu_addr >> LPARA_ROW_LB);

  // DMEM port mux: VPU row access or CPU word access (no added cycle, combinational). Only the row
  // part of the VPU address is used; its low bits (unmodified or cleared by the VPU) are dropped
  // and not checked, so an unaligned VPU address accesses the aligned row without error.
  always_comb begin : p_com_dmem_mux
    o_dmem_en      = w_vpu_issue | w_cpu_issue;
    o_dmem_wr_en   = 1'b0;
    o_dmem_addr    = '0;
    o_dmem_byte_en = '0;
    o_dmem_wr_data = '0;
    if (w_vpu_issue) begin
      o_dmem_wr_en   = i_vpu_wr_en;
      o_dmem_addr    = LPARA_DMEM_ROW_W'(i_vpu_addr >> LPARA_ROW_LB);
      o_dmem_byte_en = i_vpu_byte_en;
      o_dmem_wr_data = i_vpu_wr_data;
    end else if (w_cpu_issue) begin
      o_dmem_wr_en   = i_cpu_wr_en;
      o_dmem_addr    = w_cpu_row_addr;
      o_dmem_byte_en = w_cpu_row_be;
      o_dmem_wr_data = {LPARA_WORD_COUNT{i_cpu_wr_data}};
    end
  end
  // REQ-015, REQ-033, REQ-034, REQ-058

  // MMIO routing: the CPU request is forwarded unchanged (full address with its low 2 bits, byte
  // enables, write data) to the APB master, which holds the CPU stalled until its ack.
  assign o_mmio_req     = w_cpu_mmio_sel;
  assign o_mmio_wr_en   = i_cpu_wr_en;
  assign o_mmio_byte_en = i_cpu_byte_en;
  assign o_mmio_addr    = i_cpu_addr;
  assign o_mmio_wr_data = i_cpu_wr_data;
  // REQ-015

  // CPU response: DMEM data and ack one cycle after the issue, MMIO data and ack from the APB
  // master, immediate ack with zero data for an unmapped address (write ignored, no error flag).
  always_comb begin : p_com_cpu_resp
    o_cpu_rd_data = '0;
    o_cpu_ack     = 1'b0;
    if (w_cpu_dmem_sel) begin
      o_cpu_rd_data = w_cpu_dmem_rd;
      o_cpu_ack     = reg_cpu_ack;
    end else if (w_cpu_mmio_sel) begin
      o_cpu_rd_data = i_mmio_rd_data;
      o_cpu_ack     = i_mmio_ack;
    end else if (w_cpu_unmapped) begin
      o_cpu_rd_data = '0;
      o_cpu_ack     = 1'b1;
    end
  end
  // REQ-015, REQ-057

  // VPU response: the whole row and ack one cycle after the issue. A VPU address outside DMEM
  // is acknowledged at once with zero data and its write is ignored, with no error raised, so the
  // VPU never hangs.
  always_comb begin : p_com_vpu_resp
    o_vpu_rd_data = '0;
    o_vpu_ack     = 1'b0;
    if (w_vpu_dmem_sel) begin
      o_vpu_rd_data = i_dmem_rd_data;
      o_vpu_ack     = reg_vpu_ack;
    end else if (i_vpu_req) begin
      o_vpu_ack = 1'b1;
    end
  end
  // REQ-033, REQ-058, REQ-079, REQ-082

endmodule
`default_nettype wire
