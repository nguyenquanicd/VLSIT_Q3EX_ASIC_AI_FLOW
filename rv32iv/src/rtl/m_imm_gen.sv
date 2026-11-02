`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Immediate generator. Extracts and sign-extends the RV32I immediate
 *                (I/S/B/U/J formats) from the instruction word, selected by its opcode.
 * Parent       : m_cpu_top
 * REQ-IDs      : none assigned (implements the spec, RV32I immediate formats)
 */
`timescale 1ns / 1ps

module m_imm_gen #(
    // Width of the instruction word and of the generated immediate (RV32 base ISA).
    localparam logic [31:0] LPARA_XLEN = 32,
    // Number of immediate bits carried by the I-type format (sign bit included).
    localparam logic [31:0] LPARA_IMM_I_W = 12,
    // Number of immediate bits carried by the B-type format (sign bit included, bit 0 implicit 0).
    localparam logic [31:0] LPARA_IMM_B_W = 13,
    // Number of immediate bits carried by the J-type format (sign bit included, bit 0 implicit 0).
    localparam logic [31:0] LPARA_IMM_J_W = 21,
    // Number of low bits that the U-type format forces to zero.
    localparam logic [31:0] LPARA_IMM_U_LOW = 12
) (
    input  wire  [LPARA_XLEN-1:0] i_instr,
    output logic [LPARA_XLEN-1:0] o_imm
);

  // Instruction formats handled by the generator.
  typedef enum logic [2:0] {
    ENUM_FMT_NONE = 3'b000,
    ENUM_FMT_I    = 3'b001,
    ENUM_FMT_S    = 3'b010,
    ENUM_FMT_B    = 3'b011,
    ENUM_FMT_U    = 3'b100,
    ENUM_FMT_J    = 3'b101
  } imm_fmt_type_def;

  // RV32I major opcodes (instruction bits [6:0]).
  localparam logic [6:0] LPARA_OPC_LUI    = 7'b0110111;
  localparam logic [6:0] LPARA_OPC_AUIPC  = 7'b0010111;
  localparam logic [6:0] LPARA_OPC_JAL    = 7'b1101111;
  localparam logic [6:0] LPARA_OPC_JALR   = 7'b1100111;
  localparam logic [6:0] LPARA_OPC_BRANCH = 7'b1100011;
  localparam logic [6:0] LPARA_OPC_LOAD   = 7'b0000011;
  localparam logic [6:0] LPARA_OPC_STORE  = 7'b0100011;
  localparam logic [6:0] LPARA_OPC_OP_IMM = 7'b0010011;

  logic            [           6:0] w_opcode;
  imm_fmt_type_def                  w_fmt;
  logic            [LPARA_XLEN-1:0] w_imm;
  logic            [LPARA_XLEN-1:0] w_imm_i;
  logic            [LPARA_XLEN-1:0] w_imm_s;
  logic            [LPARA_XLEN-1:0] w_imm_b;
  logic            [LPARA_XLEN-1:0] w_imm_u;
  logic            [LPARA_XLEN-1:0] w_imm_j;
  logic                             w_sign;

  assign w_opcode = i_instr[6:0];
  assign w_sign   = i_instr[LPARA_XLEN-1];

  // Format decode from the opcode; opcodes without an immediate map to ENUM_FMT_NONE (imm = 0).
  always_comb begin : p_com_fmt
    w_fmt = ENUM_FMT_NONE;
    case (w_opcode)
      LPARA_OPC_LUI:    w_fmt = ENUM_FMT_U;
      LPARA_OPC_AUIPC:  w_fmt = ENUM_FMT_U;
      LPARA_OPC_JAL:    w_fmt = ENUM_FMT_J;
      LPARA_OPC_JALR:   w_fmt = ENUM_FMT_I;
      LPARA_OPC_LOAD:   w_fmt = ENUM_FMT_I;
      LPARA_OPC_OP_IMM: w_fmt = ENUM_FMT_I;
      LPARA_OPC_BRANCH: w_fmt = ENUM_FMT_B;
      LPARA_OPC_STORE:  w_fmt = ENUM_FMT_S;
      default:          w_fmt = ENUM_FMT_NONE;
    endcase
  end

  // Per-format immediate assembly with sign extension from instruction bit 31 (ISA-defined layout).
  assign w_imm_i = {{(LPARA_XLEN - LPARA_IMM_I_W) {w_sign}}, i_instr[31:20]};
  assign w_imm_s = {{(LPARA_XLEN - LPARA_IMM_I_W) {w_sign}}, i_instr[31:25], i_instr[11:7]};
  assign w_imm_b = {
    {(LPARA_XLEN - LPARA_IMM_B_W) {w_sign}},
    i_instr[31],
    i_instr[7],
    i_instr[30:25],
    i_instr[11:8],
    1'b0
  };
  assign w_imm_u = {i_instr[31:12], {LPARA_IMM_U_LOW{1'b0}}};
  assign w_imm_j = {
    {(LPARA_XLEN - LPARA_IMM_J_W) {w_sign}},
    i_instr[31],
    i_instr[19:12],
    i_instr[20],
    i_instr[30:21],
    1'b0
  };

  // Immediate selection by format; formats without an immediate return zero.
  always_comb begin : p_com_imm
    w_imm = '0;
    case (w_fmt)
      ENUM_FMT_I:    w_imm = w_imm_i;
      ENUM_FMT_S:    w_imm = w_imm_s;
      ENUM_FMT_B:    w_imm = w_imm_b;
      ENUM_FMT_U:    w_imm = w_imm_u;
      ENUM_FMT_J:    w_imm = w_imm_j;
      ENUM_FMT_NONE: w_imm = '0;
      default:       w_imm = '0;
    endcase
  end

  // Output mapping forwards the generated immediate to the module interface.
  assign o_imm = w_imm;

endmodule
`default_nettype wire
