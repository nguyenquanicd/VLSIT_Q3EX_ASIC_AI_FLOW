`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : CPU-to-VPU command dispatch and write-back valid generation. A legal vector
 *                instruction in the dispatch stage is offered to the VPU with i_vpu_cmd_valid held
 *                (with stable instruction, rs1 and rs2) until i_vpu_cmd_ready; the whole pipeline
 *                is then stalled until the 1-cycle i_vpu_resp_done pulse. The scalar write-back
 *                valid is the done pulse AND i_vpu_resp_rd_valid. One vector instruction is in
 *                flight at a time.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-009, REQ-031, REQ-080, REQ-081
 */
`timescale 1ns / 1ps

module m_vpu_dispatch #(
    // Width of the scalar instruction word and of the rs1/rs2/rd operands (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN = 32
) (
    input  wire                   i_clk_core,
    input  wire                   i_rst_n_core,
    // Dispatch stage: a legal vector instruction (already accepted by m_cpu_dec) with its operands.
    input  wire                   i_vec_valid,
    input  wire  [LPARA_XLEN-1:0] i_vec_instr,
    input  wire  [LPARA_XLEN-1:0] i_vec_rs1_data,
    input  wire  [LPARA_XLEN-1:0] i_vec_rs2_data,
    // VPU response side.
    input  wire                   i_vpu_cmd_ready,
    input  wire                   i_vpu_resp_done,
    input  wire                   i_vpu_resp_rd_valid,
    input  wire  [LPARA_XLEN-1:0] i_vpu_resp_rd_data,
    // VPU command side.
    output logic                  o_vpu_cmd_valid,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_instr,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_rs1_data,
    output logic [LPARA_XLEN-1:0] o_vpu_cmd_rs2_data,
    // Pipeline side: stall of every stage, scalar write-back of the VPU result.
    output logic                  o_stall,
    output logic                  o_rd_valid,
    output logic [LPARA_XLEN-1:0] o_rd_data
);

  // FSM states: IDLE offers the command (or has nothing to do), WAIT waits for the done pulse.
  // Unused encodings 2'b10 and 2'b11 recover to ENUM_ST_IDLE.
  typedef enum logic [1:0] {
    ENUM_ST_IDLE = 2'b00,
    ENUM_ST_WAIT = 2'b01
  } disp_state_type_def;

  disp_state_type_def reg_fsm_disp_current_state;
  disp_state_type_def w_fsm_disp_nxt_state;

  logic w_st_idle;
  logic w_st_wait;
  logic w_cmd_xfer;
  logic w_resp_done_acc;

  // State decode: any encoding other than WAIT behaves as IDLE (safe recovery).
  assign w_st_wait          = (reg_fsm_disp_current_state == ENUM_ST_WAIT);
  assign w_st_idle          = ~w_st_wait;

  // Command channel: valid is raised for a vector instruction in IDLE and stays high until the
  // VPU is ready. The pipeline is stalled meanwhile, so instr/rs1/rs2 are stable (pass-through).
  // The transfer happens at the clock edge where valid and ready are both 1.
  assign o_vpu_cmd_valid    = i_vec_valid & w_st_idle;
  assign o_vpu_cmd_instr    = i_vec_instr;
  assign o_vpu_cmd_rs1_data = i_vec_rs1_data;
  assign o_vpu_cmd_rs2_data = i_vec_rs2_data;
  assign w_cmd_xfer         = o_vpu_cmd_valid & i_vpu_cmd_ready;
  // REQ-031, REQ-081

  // Response: only a done pulse received while a command is outstanding completes the instruction.
  assign w_resp_done_acc    = w_st_wait & i_vpu_resp_done;

  // Pipeline stall: from the first cycle the vector instruction is present until the cycle where
  // the done pulse arrives, so every stage advances together with the done pulse.
  // The stage holds its instruction and rs1/rs2 while stalled; i_vec_valid is asserted by
  // m_cpu_dec only for a legal, unflushed instruction.
  assign o_stall            = i_vec_valid & ~w_resp_done_acc;
  // REQ-009, REQ-081

  // Scalar write-back: valid = done pulse AND resp rd_valid, so write-back occurs in the cycle
  // the stall releases; rd_data is passed through from the VPU response.
  assign o_rd_valid         = w_resp_done_acc & i_vpu_resp_rd_valid;
  assign o_rd_data          = i_vpu_resp_rd_data;
  // REQ-009, REQ-080

  // Next-state: IDLE -> WAIT on command transfer, WAIT -> IDLE on the done pulse.
  always_comb begin : p_com_disp_fsm
    w_fsm_disp_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_disp_current_state)
      ENUM_ST_IDLE: begin
        if (w_cmd_xfer) begin
          w_fsm_disp_nxt_state = ENUM_ST_WAIT;
        end else begin
          w_fsm_disp_nxt_state = ENUM_ST_IDLE;
        end
      end
      ENUM_ST_WAIT: begin
        if (i_vpu_resp_done) begin
          w_fsm_disp_nxt_state = ENUM_ST_IDLE;
        end else begin
          w_fsm_disp_nxt_state = ENUM_ST_WAIT;
        end
      end
      default: w_fsm_disp_nxt_state = ENUM_ST_IDLE;
    endcase
  end
  // REQ-009

  // State register: asynchronous active-low reset to IDLE (control state must be reset).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_disp_fsm
    if (!i_rst_n_core) begin
      reg_fsm_disp_current_state <= ENUM_ST_IDLE;
    end else begin
      reg_fsm_disp_current_state <= w_fsm_disp_nxt_state;
    end
  end
  // REQ-009, REQ-031

endmodule
`default_nettype wire
