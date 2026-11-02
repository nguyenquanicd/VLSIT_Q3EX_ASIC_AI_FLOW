`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Scalar load/store unit with byte enables and misaligned handling. Purely
 *                combinational: builds the CPU data-bus request (byte enables, lane-aligned write
 *                data), aligns and sign/zero-extends load data, and stalls while the bus ack is low.
 *                Misaligned accesses never trap and are not split: byte enables and data are shifted
 *                by addr[1:0] and bytes outside the word are dropped; a misaligned load returns
 *                word >> (8 x addr[1:0]) with zero-filled upper bytes, then the normal extension.
 *                Address decode (DMEM / MMIO / unmapped IMEM range) is done by m_soc_bus, so every
 *                access, including sb/sh to the MMIO region, is passed on unchanged.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-001, REQ-056, REQ-075
 */
`timescale 1ns / 1ps

module m_lsu #(
    // Data width of the CPU data bus (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN    = 32,
    // Width of one byte lane of the data bus.
    localparam logic [31:0] LPARA_BYTE_W  = 8,
    // Width of a halfword access.
    localparam logic [31:0] LPARA_HALF_W  = 16,
    // Number of byte lanes (byte enables) of the data bus.
    localparam logic [31:0] LPARA_BE_W    = LPARA_XLEN / LPARA_BYTE_W,
    // Width of the byte offset inside a word (low address bits).
    localparam logic [31:0] LPARA_OFF_W   = $clog2(LPARA_BE_W),
    // Width of the bit-shift amount that aligns data to the byte offset.
    localparam logic [31:0] LPARA_SHAMT_W = $clog2(LPARA_XLEN)
) (
    input  wire                   i_mem_rd_en,
    input  wire                   i_mem_wr_en,
    input  wire  [           2:0] i_funct3,
    input  wire  [LPARA_XLEN-1:0] i_addr,
    input  wire  [LPARA_XLEN-1:0] i_store_data,
    input  wire  [LPARA_XLEN-1:0] i_dmem_rd_data,
    input  wire                   i_dmem_ack,
    output logic                  o_dmem_req,
    output logic                  o_dmem_wr_en,
    output logic [LPARA_BE_W-1:0] o_dmem_byte_en,
    output logic [LPARA_XLEN-1:0] o_dmem_addr,
    output logic [LPARA_XLEN-1:0] o_dmem_wr_data,
    output logic [LPARA_XLEN-1:0] o_load_data,
    output logic                  o_stall
);

  // funct3 access-size codes shared by loads and stores (RV32I encoding).
  typedef enum logic [2:0] {
    ENUM_LSU_F3_B  = 3'b000,
    ENUM_LSU_F3_H  = 3'b001,
    ENUM_LSU_F3_W  = 3'b010,
    ENUM_LSU_F3_BU = 3'b100,
    ENUM_LSU_F3_HU = 3'b101
  } lsu_f3_type_def;

  logic [LPARA_OFF_W-1:0]   w_off;
  logic [LPARA_SHAMT_W-1:0] w_shamt;
  logic [LPARA_BE_W-1:0]    w_be_base;
  logic [LPARA_BE_W-1:0]    w_be_shift;
  logic [LPARA_XLEN-1:0]    w_wr_data;
  logic [LPARA_XLEN-1:0]    w_rd_shift;
  logic [LPARA_XLEN-1:0]    w_load_ext;

  // Byte offset inside the word and the matching bit shift.
  assign w_off = i_addr[LPARA_OFF_W-1:0];
  assign w_shamt = {w_off, 3'b000};

  // Bus request: always forwards the unmodified address (low bits stay visible to the APB
  // completer). The request is held while the stage is stalled, so address and data stay stable
  // until the ack. sb/sh to MMIO are not blocked here (REQ-056).
  assign o_dmem_req = i_mem_rd_en | i_mem_wr_en;
  assign o_dmem_wr_en = i_mem_wr_en;
  assign o_dmem_addr = i_addr;

  // MEM stage stall: pipeline waits until the data bus acknowledges the access (a normal ack is
  // also returned for MMIO accesses that raised PSLVERR).
  assign o_stall = o_dmem_req & ~i_dmem_ack;

  // Base byte enables by access size (before alignment); unsupported funct3 enables nothing.
  always_comb begin : p_com_be_base
    w_be_base = '0;
    case (i_funct3)
      ENUM_LSU_F3_B: w_be_base = LPARA_BE_W'(1'b1);
      ENUM_LSU_F3_H: w_be_base = LPARA_BE_W'(2'b11);
      ENUM_LSU_F3_W: w_be_base = '1;
      default:       w_be_base = '0;
    endcase
  end

  // Byte enables aligned to the byte offset. Bits shifted beyond the word are dropped, so a
  // misaligned sh/sw never produces 4'b1111 and is visible as a partial write to the APB master.
  // Reads request the full word; the load aligner below picks the bytes. No word-crossing split
  // and no trap is generated (REQ-075).
  always_comb begin : p_com_be_shift
    w_be_shift = LPARA_BE_W'(w_be_base << w_off);
    if (!i_mem_wr_en) begin
      w_be_shift = '1;
    end
  end

  // Store data shifted by addr[1:0] to the byte lanes selected by the byte enables; bytes shifted
  // beyond the word are dropped (REQ-075).
  assign w_wr_data = LPARA_XLEN'(i_store_data << w_shamt);

  assign o_dmem_byte_en = w_be_shift;
  assign o_dmem_wr_data = w_wr_data;

  // Load data alignment: word >> (8 x addr[1:0]); the missing upper bytes are zero-filled by the
  // logical shift, then the extension below applies (REQ-075).
  assign w_rd_shift = LPARA_XLEN'(i_dmem_rd_data >> w_shamt);

  // Load extension: lb/lh sign extend, lbu/lhu zero extend, lw passes the word. An unsupported
  // funct3 returns zero.
  always_comb begin : p_com_load_ext
    w_load_ext = '0;
    case (i_funct3)
      ENUM_LSU_F3_B:
      w_load_ext = {
        {(LPARA_XLEN - LPARA_BYTE_W) {w_rd_shift[LPARA_BYTE_W-1]}}, w_rd_shift[LPARA_BYTE_W-1:0]
      };
      ENUM_LSU_F3_H:
      w_load_ext = {
        {(LPARA_XLEN - LPARA_HALF_W) {w_rd_shift[LPARA_HALF_W-1]}}, w_rd_shift[LPARA_HALF_W-1:0]
      };
      ENUM_LSU_F3_W: w_load_ext = w_rd_shift;
      ENUM_LSU_F3_BU:
      w_load_ext = {{(LPARA_XLEN - LPARA_BYTE_W) {1'b0}}, w_rd_shift[LPARA_BYTE_W-1:0]};
      ENUM_LSU_F3_HU:
      w_load_ext = {{(LPARA_XLEN - LPARA_HALF_W) {1'b0}}, w_rd_shift[LPARA_HALF_W-1:0]};
      default: w_load_ext = '0;
    endcase
  end

  // Load result is only meaningful for a load; zero otherwise.
  assign o_load_data = i_mem_rd_en ? w_load_ext : '0;

endmodule

`default_nettype wire
