`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Branch/jump resolution in EX. Evaluates the branch condition, selects the
 *                redirect target and produces the link address of jal/jalr.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-001, REQ-003, REQ-066
 */
`timescale 1ns / 1ps

module m_branch_unit #(
    // Parameter Description: width of the register operands, the PC and the target address.
    // Parameter values: fixed to 32 (RV32I); default is 32.
    // Parameter unit: bit
    localparam logic [31:0] LPARA_XLEN   = 32,
    // Parameter Description: size of one instruction, used for the jal/jalr link address.
    // Parameter values: fixed to 4 (32-bit instructions, no compressed extension); default is 4.
    // Parameter unit: byte
    localparam logic [31:0] LPARA_PC_INC = 4
) (
    // Instruction in EX: conditional branch, jal or jalr (all 0 for any other instruction or bubble)
    input  wire                   i_branch,
    input  wire                   i_jal,
    input  wire                   i_jalr,
    input  wire  [           2:0] i_funct3,
    // Forwarded register operands, PC of the instruction in EX and its decoded immediate
    input  wire  [LPARA_XLEN-1:0] i_rs1_data,
    input  wire  [LPARA_XLEN-1:0] i_rs2_data,
    input  wire  [LPARA_XLEN-1:0] i_pc,
    input  wire  [LPARA_XLEN-1:0] i_imm,
    // Taken flag and target address (sent to the PC generator and the IF/ID flush)
    output logic                  o_taken,
    output logic [LPARA_XLEN-1:0] o_target,
    // Return address (PC + 4) written to rd by jal/jalr
    output logic [LPARA_XLEN-1:0] o_link_data
);

  // funct3 encodings of the RV32I conditional branches.
  localparam logic [2:0] LPARA_F3_BEQ  = 3'b000;
  localparam logic [2:0] LPARA_F3_BNE  = 3'b001;
  localparam logic [2:0] LPARA_F3_BLT  = 3'b100;
  localparam logic [2:0] LPARA_F3_BGE  = 3'b101;
  localparam logic [2:0] LPARA_F3_BLTU = 3'b110;
  localparam logic [2:0] LPARA_F3_BGEU = 3'b111;

  // Internal signal declarations
  logic                  w_eq;
  logic                  w_lt_u;
  logic                  w_lt_s;
  logic                  w_sign_diff;
  logic                  w_cond_met;
  logic [LPARA_XLEN-1:0] w_pc_rel_target;
  logic [LPARA_XLEN-1:0] w_jalr_sum;
  logic [LPARA_XLEN-1:0] w_jalr_target;

  // Operand comparison: equality, unsigned less-than, and signed less-than built from the sign
  // bits (operands differ in sign: the negative one is smaller; otherwise unsigned order holds).
  // REQ-001, REQ-003
  assign w_eq        = (i_rs1_data == i_rs2_data);
  assign w_lt_u      = (i_rs1_data < i_rs2_data);
  assign w_sign_diff = i_rs1_data[LPARA_XLEN-1] ^ i_rs2_data[LPARA_XLEN-1];
  assign w_lt_s      = w_sign_diff ? i_rs1_data[LPARA_XLEN-1] : w_lt_u;

  // Branch condition by funct3; reserved funct3 values (010, 011) are never taken.
  // REQ-001, REQ-003
  always_comb begin : p_com_cond
    w_cond_met = 1'b0;
    case (i_funct3)
      LPARA_F3_BEQ:  w_cond_met = w_eq;
      LPARA_F3_BNE:  w_cond_met = !w_eq;
      LPARA_F3_BLT:  w_cond_met = w_lt_s;
      LPARA_F3_BGE:  w_cond_met = !w_lt_s;
      LPARA_F3_BLTU: w_cond_met = w_lt_u;
      LPARA_F3_BGEU: w_cond_met = !w_lt_u;
      default:       w_cond_met = 1'b0;
    endcase
  end

  // Target addresses: branch and jal use PC + immediate; jalr uses (rs1 + immediate) with
  // bit 0 cleared as defined by the ISA. The sums are narrowed to the address width.
  // REQ-001, REQ-003
  assign w_pc_rel_target = $bits(w_pc_rel_target)'(i_pc + i_imm);
  assign w_jalr_sum      = $bits(w_jalr_sum)'(i_rs1_data + i_imm);
  assign w_jalr_target   = w_jalr_sum & {{(LPARA_XLEN - 1) {1'b1}}, 1'b0};

  // Redirect: jal/jalr are always taken, a conditional branch is taken when its condition holds.
  // Not-taken is the default (predict not-taken, no redirect); a taken result lets the PC
  // generator redirect and flush IF/ID, which costs the taken-branch penalty of about 2 cycles.
  // REQ-003, REQ-066
  always_comb begin : p_com_redirect
    o_taken  = 1'b0;
    o_target = w_pc_rel_target;
    if (i_jalr) begin
      o_taken  = 1'b1;
      o_target = w_jalr_target;
    end else if (i_jal) begin
      o_taken  = 1'b1;
      o_target = w_pc_rel_target;
    end else if (i_branch) begin
      o_taken  = w_cond_met;
      o_target = w_pc_rel_target;
    end
  end

  // Link address for jal/jalr: PC of the next sequential instruction.
  // REQ-001
  assign o_link_data = $bits(o_link_data)'(i_pc + LPARA_PC_INC);

endmodule
`default_nettype wire
