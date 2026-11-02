`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : VPU unit-stride memory access FSM (IDLE, REQ, WAIT, DONE) for vle8/vle32/vse8/
 *                vse32. One row access of PARA_VLEN bits per instruction: IDLE -> REQ (assert
 *                o_mem_req with the row-aligned address) -> WAIT (hold request; i_mem_ack is
 *                sampled only here, so the memory side answers at least 1 cycle after o_mem_req
 *                rises) -> DONE (completion pulse to m_vpu_ctrl) -> IDLE. The low
 *                log2(PARA_VLEN/8) address bits are ignored (no error): only the row part of
 *                o_mem_addr is significant; this module drives the ignored low bits cleared.
 *                The byte mask covers exactly vl elements: stores write only those bytes to
 *                memory, loads return the row together with the same mask so that the register
 *                file leaves tail bytes unchanged.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-005, REQ-033, REQ-037, REQ-041, REQ-058, REQ-079
 */
`timescale 1ns / 1ps

module m_vpu_lsu #(
    // Parameter Description: width of one vector register / memory row; the byte-enable width is
    //                        PARA_VLEN/8 and the low log2(PARA_VLEN/8) address bits are ignored.
    // Parameter values: legal values are 128 or 256 (checked at elaboration); default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    // Width of the scalar base address.
    localparam logic [31:0] LPARA_XLEN       = 32,
    // Number of bytes of one row (byte-enable width).
    localparam logic [31:0] LPARA_BYTE_COUNT = PARA_VLEN / 8,
    // Number of low address bits ignored (row alignment).
    localparam logic [31:0] LPARA_ROW_LB     = $clog2(PARA_VLEN / 8),
    // Width of vl: the largest VLMAX is PARA_VLEN/8.
    localparam logic [31:0] LPARA_VL_W       = $clog2(PARA_VLEN / 8 + 1),
    // Width of the byte limit vl x element bytes (element size up to 4 bytes).
    localparam logic [31:0] LPARA_LIM_W      = LPARA_VL_W + 3,
    // Element width encoding of m_vpu_dec o_mem_eew for 32-bit elements (0 = 8-bit).
    localparam logic [ 1:0] LPARA_EEW_32     = 2'd2
) (
    input  wire                                i_clk_core,
    input  wire                                i_rst_n_core,
    // Start pulse from m_vpu_ctrl (RD state) with the decoded access: direction, element width,
    // vl, scalar base address bits [31:LPARA_ROW_LB] (the parent drops the ignored low bits, REQ-058)
    // and the store source row (vector register vd).
    input  wire                                i_start,
    input  wire                                i_is_store,
    input  wire  [                        1:0] i_eew,
    input  wire  [             LPARA_VL_W-1:0] i_vl,
    input  wire  [LPARA_XLEN-LPARA_ROW_LB-1:0] i_addr_row,
    input  wire  [              PARA_VLEN-1:0] i_st_data,
    // Memory response.
    input  wire  [              PARA_VLEN-1:0] i_mem_rd_data,
    input  wire                                i_mem_ack,
    // Completion to m_vpu_ctrl and the loaded row with its element byte mask (valid from DONE).
    output logic                               o_done,
    output logic [              PARA_VLEN-1:0] o_rd_data,
    output logic [       LPARA_BYTE_COUNT-1:0] o_rd_byte_en,
    // VPU memory interface.
    output logic                               o_mem_req,
    output logic                               o_mem_wr_en,
    output logic [             LPARA_XLEN-1:0] o_mem_addr,
    output logic [       LPARA_BYTE_COUNT-1:0] o_mem_byte_en,
    output logic [              PARA_VLEN-1:0] o_mem_wr_data
);

  // FSM states (2-bit code, all four codes used; default recovers to IDLE).
  typedef enum logic [1:0] {
    ENUM_ST_IDLE = 2'b00,
    ENUM_ST_REQ  = 2'b01,
    ENUM_ST_WAIT = 2'b10,
    ENUM_ST_DONE = 2'b11
  } vlsu_state_type_def;

  vlsu_state_type_def                               reg_fsm_vlsu_current_state;
  vlsu_state_type_def                               w_fsm_vlsu_nxt_state;

  logic                                             w_accept;
  logic               [            LPARA_LIM_W-1:0] w_byte_lim;
  logic               [       LPARA_BYTE_COUNT-1:0] w_byte_mask;
  logic                                             reg_wr_en;
  logic               [LPARA_XLEN-LPARA_ROW_LB-1:0] reg_addr_row;
  logic               [       LPARA_BYTE_COUNT-1:0] reg_byte_mask;
  logic               [              PARA_VLEN-1:0] reg_wr_data;
  logic               [              PARA_VLEN-1:0] reg_rd_data;

  // Elaboration check of the legal parameter value.
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_vpu_lsu: PARA_VLEN must be 128 or 256");
  end

  // A start pulse is accepted only in IDLE; m_vpu_ctrl issues one pulse per memory instruction.
  assign w_accept = i_start & (reg_fsm_vlsu_current_state == ENUM_ST_IDLE);
  // REQ-037

  // Element byte mask: the first vl x element-bytes bytes of the row (4 bytes per element for
  // vle32/vse32, 1 for vle8/vse8). A limit above the row width simply selects the whole row.
  always_comb begin : p_com_byte_mask
    if (i_eew == LPARA_EEW_32) begin
      w_byte_lim = $bits(w_byte_lim)'({i_vl, 2'b00});
    end else begin
      w_byte_lim = $bits(w_byte_lim)'(i_vl);
    end
    w_byte_mask = '0;
    for (int idx = 0; idx < LPARA_BYTE_COUNT; idx++) begin
      w_byte_mask[idx] = ($bits(w_byte_lim)'(idx) < w_byte_lim);
    end
  end
  // REQ-005

  // Next state: IDLE -> REQ on start, REQ -> WAIT, WAIT -> DONE on i_mem_ack, DONE -> IDLE.
  // i_mem_ack is looked at only in WAIT, never in REQ, so an acknowledge in the same cycle in
  // which o_mem_req rises is ignored (the memory side answers at least 1 cycle later).
  always_comb begin : p_com_vlsu_fsm
    w_fsm_vlsu_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_vlsu_current_state)
      ENUM_ST_IDLE: begin
        if (i_start) begin
          w_fsm_vlsu_nxt_state = ENUM_ST_REQ;
        end else begin
          w_fsm_vlsu_nxt_state = ENUM_ST_IDLE;
        end
      end
      ENUM_ST_REQ:  w_fsm_vlsu_nxt_state = ENUM_ST_WAIT;
      ENUM_ST_WAIT: begin
        if (i_mem_ack) begin
          w_fsm_vlsu_nxt_state = ENUM_ST_DONE;
        end else begin
          w_fsm_vlsu_nxt_state = ENUM_ST_WAIT;
        end
      end
      ENUM_ST_DONE: w_fsm_vlsu_nxt_state = ENUM_ST_IDLE;
      default:      w_fsm_vlsu_nxt_state = ENUM_ST_IDLE;
    endcase
  end
  // REQ-037, REQ-079

  // FSM state: asynchronous active-low reset to IDLE (no request, no completion pulse).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vlsu_fsm
    if (!i_rst_n_core) begin
      reg_fsm_vlsu_current_state <= ENUM_ST_IDLE;
    end else begin
      reg_fsm_vlsu_current_state <= w_fsm_vlsu_nxt_state;
    end
  end
  // REQ-037, REQ-041

  // Access capture: direction, row address (the low bits are never stored), byte mask and store
  // row are latched when the start is accepted, so they stay stable from REQ until i_mem_ack
  // although the decode inputs may change.
  // Resetless: consumed only while o_mem_req (state REQ/WAIT, reset to IDLE) is 1.
  always_ff @(posedge i_clk_core) begin : p_ff_access
    if (w_accept) begin
      reg_wr_en     <= i_is_store;
      reg_addr_row  <= i_addr_row;
      reg_byte_mask <= w_byte_mask;
      reg_wr_data   <= i_st_data;
    end
  end
  // REQ-033

  // Load data capture: the row returned with i_mem_ack (sampled only in WAIT) is held for the
  // register file write that follows DONE. Resetless: consumed only after the DONE pulse.
  always_ff @(posedge i_clk_core) begin : p_ff_rd_data
    if ((reg_fsm_vlsu_current_state == ENUM_ST_WAIT) && i_mem_ack) begin
      reg_rd_data <= i_mem_rd_data;
    end
  end
  // REQ-005, REQ-079

  // Completion pulse: exactly one cycle (DONE state) per access.
  assign o_done = (reg_fsm_vlsu_current_state == ENUM_ST_DONE);
  // REQ-037

  // Memory request: asserted in REQ and held in WAIT with stable address/data until i_mem_ack.
  // Only the row part of o_mem_addr is significant: the ignored low log2(PARA_VLEN/8) bits are
  // driven cleared, so every access targets an aligned row and an unaligned address raises no
  // error. Stores drive the element byte mask, loads drive 0.
  assign o_mem_req     = (reg_fsm_vlsu_current_state == ENUM_ST_REQ) ||
                         (reg_fsm_vlsu_current_state == ENUM_ST_WAIT);
  assign o_mem_wr_en = o_mem_req & reg_wr_en;
  assign o_mem_addr = {reg_addr_row, {LPARA_ROW_LB{1'b0}}};
  assign o_mem_byte_en = reg_wr_en ? reg_byte_mask : '0;
  assign o_mem_wr_data = reg_wr_data;
  // REQ-005, REQ-033, REQ-058

  // Load result: row and element mask for the register file (tail bytes keep their old value).
  assign o_rd_data = reg_rd_data;
  assign o_rd_byte_en = reg_byte_mask;
  // REQ-005

endmodule
`default_nettype wire
