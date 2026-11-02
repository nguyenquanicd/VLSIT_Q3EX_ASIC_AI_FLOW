`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : VPU command interface: latches instruction/rs1/rs2, ready/done handling.
 *                A CPU command is accepted when i_cmd_valid and o_cmd_ready are both 1; the
 *                instruction/rs1/rs2 are latched for the VPU core. The completion of m_vpu_ctrl
 *                is forwarded as a 1-cycle o_resp_done pulse together with the scalar result.
 *                o_cmd_ready is asserted only while m_vpu_ctrl is IDLE, and o_resp_done is
 *                accepted only from the DONE state of an outstanding command, so every command
 *                (including vsetvli/vsetivli) sees the full m_vpu_ctrl IDLE-DEC-RD-EXEC-WB-DONE
 *                sequence, i.e. at least 5 cycles from command start to o_resp_done.
 *                One vector instruction is outstanding at a time.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-009, REQ-031, REQ-032, REQ-087
 */
`timescale 1ns / 1ps

module m_vpu_if #(
    // Width of the scalar instruction word and of the rs1/rs2/rd operands (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN = 32
) (
    input  wire                   i_clk_core,
    input  wire                   i_rst_n_core,
    // CPU command channel.
    input  wire                   i_cmd_valid,
    input  wire  [LPARA_XLEN-1:0] i_cmd_instr,
    input  wire  [LPARA_XLEN-1:0] i_cmd_rs1_data,
    input  wire  [LPARA_XLEN-1:0] i_cmd_rs2_data,
    // Status from m_vpu_ctrl: FSM in IDLE, FSM in DONE, and the scalar result of the instruction.
    input  wire                   i_ctrl_idle,
    input  wire                   i_ctrl_done,
    input  wire                   i_ctrl_rd_valid,
    input  wire  [LPARA_XLEN-1:0] i_ctrl_rd_data,
    // CPU command handshake and response.
    output logic                  o_cmd_ready,
    output logic                  o_resp_done,
    output logic                  o_resp_rd_valid,
    output logic [LPARA_XLEN-1:0] o_resp_rd_data,
    // Towards the VPU core: accepted command (1-cycle transfer pulse, then latched copy).
    output logic                  o_cmd_xfer,
    output logic                  o_cmd_pending,
    output logic [LPARA_XLEN-1:0] o_instr,
    output logic [LPARA_XLEN-1:0] o_rs1_data,
    output logic [LPARA_XLEN-1:0] o_rs2_data
);

  logic                  reg_pending;
  logic                  w_pending_nxt;
  logic                  w_done_acc;
  logic [LPARA_XLEN-1:0] reg_instr;
  logic [LPARA_XLEN-1:0] reg_rs1_data;
  logic [LPARA_XLEN-1:0] reg_rs2_data;

  // Command handshake: ready only while m_vpu_ctrl is IDLE and no command is outstanding.
  // The command transfers at the clock edge where i_cmd_valid and o_cmd_ready are both 1.
  assign o_cmd_ready     = i_ctrl_idle & ~reg_pending;
  assign o_cmd_xfer      = i_cmd_valid & o_cmd_ready;
  // REQ-031, REQ-032

  // Response: a done pulse from m_vpu_ctrl counts only while a command is outstanding. The pending
  // flag clears on that cycle, so o_resp_done is exactly 1 cycle wide per instruction. No bypass
  // exists from command transfer to response: the done pulse comes only from the DONE state of
  // m_vpu_ctrl, which is entered after IDLE, DEC, RD, EXEC and WB (>= 5 cycles of latency).
  assign w_done_acc      = i_ctrl_done & reg_pending;
  assign o_resp_done     = w_done_acc;
  assign o_resp_rd_valid = w_done_acc & i_ctrl_rd_valid;
  assign o_resp_rd_data  = i_ctrl_rd_data & {LPARA_XLEN{o_resp_rd_valid}};
  // REQ-009, REQ-031, REQ-087

  // Latched command outputs towards the VPU core.
  assign o_cmd_pending   = reg_pending;
  assign o_instr         = reg_instr;
  assign o_rs1_data      = reg_rs1_data;
  assign o_rs2_data      = reg_rs2_data;
  // REQ-009

  // Outstanding-command flag: set on the command transfer, cleared on the accepted done pulse.
  always_comb begin : p_com_pending
    w_pending_nxt = reg_pending;
    if (o_cmd_xfer) begin
      w_pending_nxt = 1'b1;
    end else if (w_done_acc) begin
      w_pending_nxt = 1'b0;
    end
  end
  // REQ-009, REQ-032

  // Control state: asynchronous active-low reset, no command outstanding after reset.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_pending
    if (!i_rst_n_core) begin
      reg_pending <= 1'b0;
    end else begin
      reg_pending <= w_pending_nxt;
    end
  end
  // REQ-009, REQ-032

  // Command capture: payload registers are resetless; they are consumed only while the pending
  // flag is set, i.e. after they have been written by a command transfer.
  always_ff @(posedge i_clk_core) begin : p_ff_cmd_payload
    if (o_cmd_xfer) begin
      reg_instr    <= i_cmd_instr;
      reg_rs1_data <= i_cmd_rs1_data;
      reg_rs2_data <= i_cmd_rs2_data;
    end
  end
  // REQ-009, REQ-031

endmodule
`default_nettype wire
