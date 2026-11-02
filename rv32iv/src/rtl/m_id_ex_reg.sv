`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : ID/EX pipeline register. Holds the decoded instruction (operands, immediate,
 *                register indices and control) for the EX stage. A flush (taken branch/jump
 *                from EX, or the load-use bubble from the hazard unit) turns the stage into a
 *                bubble; a stall (vector stall) holds it.
 * Parent       : m_cpu_top
 * REQ-IDs      : none assigned (implements the spec, ID/EX pipeline register)
 */
`timescale 1ns / 1ps

module m_id_ex_reg #(
    // Width of the PC, instruction word, register data and immediate (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN      = 32,
    // Width of a scalar register index (32 integer registers).
    localparam logic [31:0] LPARA_REG_IDX_W = 5,
    // Width of the ALU operation code produced by m_cpu_dec.
    localparam logic [31:0] LPARA_ALU_OP_W  = 4,
    // Width of the funct3 field (branch condition / load-store size / mul variant).
    localparam logic [31:0] LPARA_FUNCT3_W  = 3,
    // Width of the write-back source select (ALU, load data, PC+4).
    localparam logic [31:0] LPARA_WB_SEL_W  = 2
) (
    input  wire                        i_clk_core,
    input  wire                        i_rst_n_core,
    input  wire                        i_flush,
    input  wire                        i_stall,
    input  wire                        i_valid,
    input  wire  [     LPARA_XLEN-1:0] i_pc,
    input  wire  [     LPARA_XLEN-1:0] i_instr,
    input  wire  [     LPARA_XLEN-1:0] i_rs1_data,
    input  wire  [     LPARA_XLEN-1:0] i_rs2_data,
    input  wire  [     LPARA_XLEN-1:0] i_imm,
    input  wire  [LPARA_REG_IDX_W-1:0] i_rs1_idx,
    input  wire  [LPARA_REG_IDX_W-1:0] i_rs2_idx,
    input  wire  [LPARA_REG_IDX_W-1:0] i_rd_idx,
    input  wire  [ LPARA_ALU_OP_W-1:0] i_alu_op,
    input  wire                        i_alu_a_pc_sel,
    input  wire                        i_alu_b_imm_sel,
    input  wire  [ LPARA_FUNCT3_W-1:0] i_funct3,
    input  wire  [ LPARA_WB_SEL_W-1:0] i_wb_sel,
    input  wire                        i_is_branch,
    input  wire                        i_is_jal,
    input  wire                        i_is_jalr,
    input  wire                        i_is_mul,
    input  wire                        i_is_vec,
    input  wire                        i_mem_rd,
    input  wire                        i_mem_wr,
    input  wire                        i_rf_we,
    output logic                       o_valid,
    output logic [     LPARA_XLEN-1:0] o_pc,
    output logic [     LPARA_XLEN-1:0] o_instr,
    output logic [     LPARA_XLEN-1:0] o_rs1_data,
    output logic [     LPARA_XLEN-1:0] o_rs2_data,
    output logic [     LPARA_XLEN-1:0] o_imm,
    output logic [LPARA_REG_IDX_W-1:0] o_rs1_idx,
    output logic [LPARA_REG_IDX_W-1:0] o_rs2_idx,
    output logic [LPARA_REG_IDX_W-1:0] o_rd_idx,
    output logic [ LPARA_ALU_OP_W-1:0] o_alu_op,
    output logic                       o_alu_a_pc_sel,
    output logic                       o_alu_b_imm_sel,
    output logic [ LPARA_FUNCT3_W-1:0] o_funct3,
    output logic [ LPARA_WB_SEL_W-1:0] o_wb_sel,
    output logic                       o_is_branch,
    output logic                       o_is_jal,
    output logic                       o_is_jalr,
    output logic                       o_is_mul,
    output logic                       o_is_vec,
    output logic                       o_mem_rd,
    output logic                       o_mem_wr,
    output logic                       o_rf_we
);

  // Packed control group whose bits have side effects downstream (validity and the
  // strobes that write the register file, memory, VPU or redirect the PC).
  localparam logic [31:0] LPARA_CTRL_W = 9;

  // Internal signal declarations
  logic [   LPARA_CTRL_W-1:0] reg_ctrl;
  logic [   LPARA_CTRL_W-1:0] w_ctrl_in;
  logic [   LPARA_CTRL_W-1:0] w_ctrl_nxt;
  logic [     LPARA_XLEN-1:0] reg_pc;
  logic [     LPARA_XLEN-1:0] reg_instr;
  logic [     LPARA_XLEN-1:0] reg_rs1_data;
  logic [     LPARA_XLEN-1:0] reg_rs2_data;
  logic [     LPARA_XLEN-1:0] reg_imm;
  logic [LPARA_REG_IDX_W-1:0] reg_rs1_idx;
  logic [LPARA_REG_IDX_W-1:0] reg_rs2_idx;
  logic [LPARA_REG_IDX_W-1:0] reg_rd_idx;
  logic [ LPARA_ALU_OP_W-1:0] reg_alu_op;
  logic                       reg_alu_a_pc_sel;
  logic                       reg_alu_b_imm_sel;
  logic [ LPARA_FUNCT3_W-1:0] reg_funct3;
  logic [ LPARA_WB_SEL_W-1:0] reg_wb_sel;

  // Input control grouping: an invalid ID stage (IF/ID bubble) never raises a strobe, so
  // every side-effect bit is qualified with i_valid.
  assign w_ctrl_in = {
    i_valid,
    i_is_branch & i_valid,
    i_is_jal & i_valid,
    i_is_jalr & i_valid,
    i_is_mul & i_valid,
    i_is_vec & i_valid,
    i_mem_rd & i_valid,
    i_mem_wr & i_valid,
    i_rf_we & i_valid
  };

  // Output mapping forwards the registered ID/EX stage to the EX stage.
  // o_valid = 0 marks a bubble; all strobes are 0 then, other fields must be ignored by EX.
  assign o_valid = reg_ctrl[8];
  assign o_is_branch = reg_ctrl[7];
  assign o_is_jal = reg_ctrl[6];
  assign o_is_jalr = reg_ctrl[5];
  assign o_is_mul = reg_ctrl[4];
  assign o_is_vec = reg_ctrl[3];
  assign o_mem_rd = reg_ctrl[2];
  assign o_mem_wr = reg_ctrl[1];
  assign o_rf_we = reg_ctrl[0];
  assign o_pc = reg_pc;
  assign o_instr = reg_instr;
  assign o_rs1_data = reg_rs1_data;
  assign o_rs2_data = reg_rs2_data;
  assign o_imm = reg_imm;
  assign o_rs1_idx = reg_rs1_idx;
  assign o_rs2_idx = reg_rs2_idx;
  assign o_rd_idx = reg_rd_idx;
  assign o_alu_op = reg_alu_op;
  assign o_alu_a_pc_sel = reg_alu_a_pc_sel;
  assign o_alu_b_imm_sel = reg_alu_b_imm_sel;
  assign o_funct3 = reg_funct3;
  assign o_wb_sel = reg_wb_sel;

  // Next control selection: flush has priority and turns the stage into a bubble (all zero).
  // A stall keeps the current control state; otherwise the decoded control is taken.
  always_comb begin : p_com_ctrl
    w_ctrl_nxt = reg_ctrl;
    if (i_flush) begin
      w_ctrl_nxt = '0;
    end else if (!i_stall) begin
      w_ctrl_nxt = w_ctrl_in;
    end
  end

  // Control state: asynchronously cleared by reset so the pipeline starts empty (REQ-RESET-002).
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_ctrl
    if (!i_rst_n_core) begin
      reg_ctrl <= '0;
    end else begin
      reg_ctrl <= w_ctrl_nxt;
    end
  end

  // Payload capture: operands, immediate, indices and datapath selects load when the stage
  // advances (no stall). Resetless on purpose (SEQ-04): EX ignores them while o_valid is 0, and
  // every side-effect strobe lives in the reset control group above.
  always_ff @(posedge i_clk_core) begin : p_ff_payload
    if (!i_stall) begin
      reg_pc            <= i_pc;
      reg_instr         <= i_instr;
      reg_rs1_data      <= i_rs1_data;
      reg_rs2_data      <= i_rs2_data;
      reg_imm           <= i_imm;
      reg_rs1_idx       <= i_rs1_idx;
      reg_rs2_idx       <= i_rs2_idx;
      reg_rd_idx        <= i_rd_idx;
      reg_alu_op        <= i_alu_op;
      reg_alu_a_pc_sel  <= i_alu_a_pc_sel;
      reg_alu_b_imm_sel <= i_alu_b_imm_sel;
      reg_funct3        <= i_funct3;
      reg_wb_sel        <= i_wb_sel;
    end
  end

endmodule
`default_nettype wire
