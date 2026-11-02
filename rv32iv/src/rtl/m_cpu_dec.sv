// REQ-IDs: REQ-001, REQ-002, REQ-052, REQ-054, REQ-073, REQ-074, REQ-081, REQ-083, REQ-084
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : ID-stage decode: RV32I, mul, fence/ebreak, Zve32x subset and
 *                illegal-instruction detection. Parent: m_cpu_top.
 *
 * Interface notes:
 *   - Purely combinational decode of i_instr, plus one shadow copy of the vtype SEW that
 *     is updated by every accepted legal vsetvli/vsetivli (the VPU interface has no error
 *     response, so legality must be known here).
 *   - i_instr_valid must be 0 for bubbles and for a wrong-path instruction that is being
 *     flushed in the same cycle; o_illegal and every side effect output are 0 then.
 *   - i_id_adv = 1 in the cycle where the instruction leaves ID (not stalled); only then
 *     the shadow SEW is updated, so a stalled instruction updates it exactly once.
 *   - Encodings of the o_alu_op, o_alu_a_sel, o_imm_type, o_wb_sel outputs are the enum
 *     values of the typedefs below.
 *   - PARA_VLEN and PARA_LANE_COUNT do not influence decode, so the module has no
 *     overridable parameter.
 */
`default_nettype none
`timescale 1ns / 1ps

module m_cpu_dec #(
    localparam logic        [ 6:0] LPARA_OPC_LOAD     = 7'b0000011,
    localparam logic        [ 6:0] LPARA_OPC_LOAD_FP  = 7'b0000111,
    localparam logic        [ 6:0] LPARA_OPC_MISC_MEM = 7'b0001111,
    localparam logic        [ 6:0] LPARA_OPC_OP_IMM   = 7'b0010011,
    localparam logic        [ 6:0] LPARA_OPC_AUIPC    = 7'b0010111,
    localparam logic        [ 6:0] LPARA_OPC_STORE    = 7'b0100011,
    localparam logic        [ 6:0] LPARA_OPC_STORE_FP = 7'b0100111,
    localparam logic        [ 6:0] LPARA_OPC_OP       = 7'b0110011,
    localparam logic        [ 6:0] LPARA_OPC_LUI      = 7'b0110111,
    localparam logic        [ 6:0] LPARA_OPC_OP_V     = 7'b1010111,
    localparam logic        [ 6:0] LPARA_OPC_BRANCH   = 7'b1100011,
    localparam logic        [ 6:0] LPARA_OPC_JALR     = 7'b1100111,
    localparam logic        [ 6:0] LPARA_OPC_JAL      = 7'b1101111,
    localparam logic        [ 6:0] LPARA_OPC_SYSTEM   = 7'b1110011,
    localparam logic        [31:0] LPARA_INSTR_EBREAK = 32'h0010_0073,
    localparam logic        [ 6:0] LPARA_F7_BASE      = 7'b0000000,
    localparam logic        [ 6:0] LPARA_F7_ALT       = 7'b0100000,
    localparam logic        [ 6:0] LPARA_F7_MUL       = 7'b0000001,
    localparam logic        [ 2:0] LPARA_V_OPIVV      = 3'b000,
    localparam logic        [ 2:0] LPARA_V_OPMVV      = 3'b010,
    localparam logic        [ 2:0] LPARA_V_OPIVI      = 3'b011,
    localparam logic        [ 2:0] LPARA_V_OPIVX      = 3'b100,
    localparam logic        [ 2:0] LPARA_V_OPMVX      = 3'b110,
    localparam logic        [ 2:0] LPARA_V_OPCFG      = 3'b111,
    localparam logic        [ 2:0] LPARA_VW_E8        = 3'b000,
    localparam logic        [ 2:0] LPARA_VW_E32       = 3'b110,
    localparam logic        [ 5:0] LPARA_F6_VADD      = 6'b000000,
    localparam logic        [ 5:0] LPARA_F6_VMAX      = 6'b000111,
    localparam logic        [ 5:0] LPARA_F6_VMV_XS    = 6'b010000,
    localparam logic        [ 5:0] LPARA_F6_VMV_V     = 6'b010111,
    localparam logic        [ 5:0] LPARA_F6_VSRA      = 6'b101001,
    localparam logic        [ 5:0] LPARA_F6_VNCLIP    = 6'b101111,
    localparam logic        [ 5:0] LPARA_F6_VWREDSUM  = 6'b110001,
    localparam logic        [ 5:0] LPARA_F6_VWMUL     = 6'b111011,
    localparam logic        [ 1:0] LPARA_SEW_8        = 2'b00,
    localparam logic        [ 1:0] LPARA_SEW_16       = 2'b01,
    localparam logic        [ 1:0] LPARA_SEW_32       = 2'b10,
    localparam int unsigned        LPARA_REG_W        = 5,
    localparam int unsigned        LPARA_ALU_OP_W     = 4,
    localparam int unsigned        LPARA_ASEL_W       = 2,
    localparam int unsigned        LPARA_IMM_W        = 3,
    localparam int unsigned        LPARA_WB_W         = 3,
    localparam int unsigned        LPARA_F3_W         = 3
) (
    // Clock and reset
    input  wire                       i_clk_core,
    input  wire                       i_rst_n_core,
    // Control in
    input  wire                       i_instr_valid,
    input  wire                       i_id_adv,
    // Data in
    input  wire  [              31:0] i_instr,
    // Control out
    output logic                      o_illegal,
    output logic                      o_ebreak,
    output logic                      o_is_vec,
    output logic                      o_rd_wr_en,
    output logic                      o_use_rs1,
    output logic                      o_use_rs2,
    output logic                      o_alu_b_imm,
    output logic                      o_is_branch,
    output logic                      o_is_jal,
    output logic                      o_is_jalr,
    output logic                      o_mem_rd,
    output logic                      o_mem_wr,
    output logic                      o_is_mul,
    // Data out
    output logic [LPARA_ALU_OP_W-1:0] o_alu_op,
    output logic [  LPARA_ASEL_W-1:0] o_alu_a_sel,
    output logic [   LPARA_IMM_W-1:0] o_imm_type,
    output logic [    LPARA_WB_W-1:0] o_wb_sel,
    output logic [    LPARA_F3_W-1:0] o_branch_fn,
    output logic [    LPARA_F3_W-1:0] o_mem_fn,
    output logic [   LPARA_REG_W-1:0] o_rs1_addr,
    output logic [   LPARA_REG_W-1:0] o_rs2_addr,
    output logic [   LPARA_REG_W-1:0] o_rd_addr
);

  // Module-local type declarations
  typedef enum logic [LPARA_ALU_OP_W-1:0] {
    ENUM_ALU_ADD  = 4'd0,
    ENUM_ALU_SUB  = 4'd1,
    ENUM_ALU_SLL  = 4'd2,
    ENUM_ALU_SLT  = 4'd3,
    ENUM_ALU_SLTU = 4'd4,
    ENUM_ALU_XOR  = 4'd5,
    ENUM_ALU_SRL  = 4'd6,
    ENUM_ALU_SRA  = 4'd7,
    ENUM_ALU_OR   = 4'd8,
    ENUM_ALU_AND  = 4'd9
  } alu_op_type_def;

  // ALU operand A source: rs1, the PC (auipc, jal, branches) or zero (lui)
  typedef enum logic [LPARA_ASEL_W-1:0] {
    ENUM_ASEL_RS1  = 2'd0,
    ENUM_ASEL_PC   = 2'd1,
    ENUM_ASEL_ZERO = 2'd2
  } alu_asel_type_def;

  // Immediate format for m_imm_gen
  typedef enum logic [LPARA_IMM_W-1:0] {
    ENUM_IMM_I = 3'd0,
    ENUM_IMM_S = 3'd1,
    ENUM_IMM_B = 3'd2,
    ENUM_IMM_U = 3'd3,
    ENUM_IMM_J = 3'd4
  } imm_type_def;

  // Write-back source: ALU, load data, PC+4 (jal/jalr), mul result, VPU response rd data
  typedef enum logic [LPARA_WB_W-1:0] {
    ENUM_WB_ALU = 3'd0,
    ENUM_WB_MEM = 3'd1,
    ENUM_WB_PC4 = 3'd2,
    ENUM_WB_MUL = 3'd3,
    ENUM_WB_VPU = 3'd4
  } wb_sel_type_def;

  // Internal signal declarations
  logic             [6:0] w_opcode;
  logic             [2:0] w_funct3;
  logic             [6:0] w_funct7;
  logic             [5:0] w_funct6;
  logic                   w_is_vec_op;
  logic                   w_legal;
  logic                   w_ok;
  logic                   w_vm;
  logic                   w_vmem_fmt_ok;
  logic                   w_vset_fld_ok;

  logic                   w_s_illegal;
  logic                   w_s_ebreak;
  logic                   w_s_rd_wr;
  logic                   w_s_use_rs1;
  logic                   w_s_use_rs2;
  logic                   w_s_b_imm;
  logic                   w_s_branch;
  logic                   w_s_jal;
  logic                   w_s_jalr;
  logic                   w_s_mem_rd;
  logic                   w_s_mem_wr;
  logic                   w_s_mul;
  alu_op_type_def         w_alu_op;
  alu_asel_type_def       w_a_sel;
  imm_type_def            w_imm_type;
  wb_sel_type_def         w_wb_sel;
  wb_sel_type_def         w_wb_sel_out;

  logic                   w_v_legal;
  logic                   w_v_use_rs1;
  logic                   w_v_rd_wr;
  logic                   w_v_vset;
  logic             [1:0] w_v_vsew;

  logic                   reg_vsew_vld;
  logic             [1:0] reg_vsew;
  logic                   w_sew8;
  logic                   w_sew16;
  logic                   w_sew32;
  logic                   w_sew_8_16;
  logic                   w_sew_8_32;

  // Instruction field extraction
  assign w_opcode = i_instr[6:0];
  assign w_funct3 = i_instr[14:12];
  assign w_funct7 = i_instr[31:25];
  assign w_funct6 = i_instr[31:26];
  assign w_vm = i_instr[25];

  // Register address fields go straight to m_regfile and m_hazard_unit.
  assign o_rs1_addr = i_instr[19:15];
  assign o_rs2_addr = i_instr[24:20];
  assign o_rd_addr = i_instr[11:7];

  // Vector class: OP-V plus the FP load/store major opcodes that carry vle/vse. Every other
  // opcode in these three classes is illegal because the F extension is not implemented.
  assign w_is_vec_op = (w_opcode == LPARA_OPC_OP_V) || (w_opcode == LPARA_OPC_LOAD_FP) ||
                       (w_opcode == LPARA_OPC_STORE_FP);

  // vle/vse format: nf = 0, mew = 0, mop = 0 (unit-stride), vm = 1, lumop/sumop = 0.
  assign w_vmem_fmt_ok = (i_instr[31:28] == 4'b0000) && (i_instr[27:26] == 2'b00) &&
                         i_instr[25] && (i_instr[24:20] == 5'b00000);

  // vtype immediate checks shared by vsetvli and vsetivli: LMUL = 1 (vlmul = 0) and
  // SEW in {8, 16, 32} (vsew = 0, 1, 2). The vta/vma bits are accepted because the VPU
  // keeps tail elements undisturbed (a legal tail-agnostic implementation).
  assign w_vset_fld_ok = (i_instr[22:20] == 3'b000) && (i_instr[25] == 1'b0) &&
                         (i_instr[24:23] != 2'b11);

  // Shadow SEW flags; all 0 until the first legal vsetvli/vsetivli (vtype.vill state).
  assign w_sew8 = reg_vsew_vld && (reg_vsew == LPARA_SEW_8);
  assign w_sew16 = reg_vsew_vld && (reg_vsew == LPARA_SEW_16);
  assign w_sew32 = reg_vsew_vld && (reg_vsew == LPARA_SEW_32);
  assign w_sew_8_16 = w_sew8 || w_sew16;
  assign w_sew_8_32 = w_sew8 || w_sew32;
  // REQ-054, REQ-074

  // Scalar decode: RV32I, mul, fence (NOP) and ebreak. Every encoding outside this set,
  // including div/rem, mulh*, ecall, CSR and other SYSTEM opcodes, compressed encodings and
  // the vector opcode classes, sets w_s_illegal. Side-effect flags are gated later.
  // Branches and jumps compute the target on the ALU (PC + imm, or rs1 + imm for jalr);
  // the branch comparison itself uses o_branch_fn in m_branch_unit.
  always_comb begin : p_com_scalar
    w_s_illegal = 1'b0;
    w_s_ebreak  = 1'b0;
    w_s_rd_wr   = 1'b0;
    w_s_use_rs1 = 1'b0;
    w_s_use_rs2 = 1'b0;
    w_s_b_imm   = 1'b0;
    w_s_branch  = 1'b0;
    w_s_jal     = 1'b0;
    w_s_jalr    = 1'b0;
    w_s_mem_rd  = 1'b0;
    w_s_mem_wr  = 1'b0;
    w_s_mul     = 1'b0;
    w_alu_op    = ENUM_ALU_ADD;
    w_a_sel     = ENUM_ASEL_RS1;
    w_imm_type  = ENUM_IMM_I;
    w_wb_sel    = ENUM_WB_ALU;
    if (i_instr[1:0] != 2'b11) begin
      w_s_illegal = 1'b1;
    end else begin
      case (w_opcode)
        LPARA_OPC_LUI: begin
          w_s_rd_wr  = 1'b1;
          w_s_b_imm  = 1'b1;
          w_a_sel    = ENUM_ASEL_ZERO;
          w_imm_type = ENUM_IMM_U;
        end
        LPARA_OPC_AUIPC: begin
          w_s_rd_wr  = 1'b1;
          w_s_b_imm  = 1'b1;
          w_a_sel    = ENUM_ASEL_PC;
          w_imm_type = ENUM_IMM_U;
        end
        LPARA_OPC_JAL: begin
          w_s_rd_wr  = 1'b1;
          w_s_b_imm  = 1'b1;
          w_s_jal    = 1'b1;
          w_a_sel    = ENUM_ASEL_PC;
          w_imm_type = ENUM_IMM_J;
          w_wb_sel   = ENUM_WB_PC4;
        end
        LPARA_OPC_JALR: begin
          w_s_rd_wr   = 1'b1;
          w_s_use_rs1 = 1'b1;
          w_s_b_imm   = 1'b1;
          w_s_jalr    = 1'b1;
          w_wb_sel    = ENUM_WB_PC4;
          if (w_funct3 != 3'b000) begin
            w_s_illegal = 1'b1;
          end
        end
        LPARA_OPC_BRANCH: begin
          w_s_use_rs1 = 1'b1;
          w_s_use_rs2 = 1'b1;
          w_s_b_imm   = 1'b1;
          w_s_branch  = 1'b1;
          w_a_sel     = ENUM_ASEL_PC;
          w_imm_type  = ENUM_IMM_B;
          case (w_funct3)
            3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: w_s_illegal = 1'b0;  // beq..bgeu
            default: w_s_illegal = 1'b1;
          endcase
        end
        LPARA_OPC_LOAD: begin
          w_s_rd_wr   = 1'b1;
          w_s_use_rs1 = 1'b1;
          w_s_b_imm   = 1'b1;
          w_s_mem_rd  = 1'b1;
          w_wb_sel    = ENUM_WB_MEM;
          case (w_funct3)
            3'b000, 3'b001, 3'b010, 3'b100, 3'b101: w_s_illegal = 1'b0;  // lb lh lw lbu lhu
            default: w_s_illegal = 1'b1;
          endcase
        end
        LPARA_OPC_STORE: begin
          w_s_use_rs1 = 1'b1;
          w_s_use_rs2 = 1'b1;
          w_s_b_imm   = 1'b1;
          w_s_mem_wr  = 1'b1;
          w_imm_type  = ENUM_IMM_S;
          case (w_funct3)
            3'b000, 3'b001, 3'b010: w_s_illegal = 1'b0;  // sb sh sw
            default: w_s_illegal = 1'b1;
          endcase
        end
        LPARA_OPC_OP_IMM: begin
          w_s_rd_wr   = 1'b1;
          w_s_use_rs1 = 1'b1;
          w_s_b_imm   = 1'b1;
          case (w_funct3)
            3'b000:  w_alu_op = ENUM_ALU_ADD;  // addi
            3'b010:  w_alu_op = ENUM_ALU_SLT;  // slti
            3'b011:  w_alu_op = ENUM_ALU_SLTU;  // sltiu
            3'b100:  w_alu_op = ENUM_ALU_XOR;  // xori
            3'b110:  w_alu_op = ENUM_ALU_OR;  // ori
            3'b111:  w_alu_op = ENUM_ALU_AND;  // andi
            3'b001: begin  // slli
              w_alu_op = ENUM_ALU_SLL;
              if (w_funct7 != LPARA_F7_BASE) begin
                w_s_illegal = 1'b1;
              end
            end
            3'b101: begin  // srli / srai
              if (w_funct7 == LPARA_F7_BASE) begin
                w_alu_op = ENUM_ALU_SRL;
              end else if (w_funct7 == LPARA_F7_ALT) begin
                w_alu_op = ENUM_ALU_SRA;
              end else begin
                w_s_illegal = 1'b1;
              end
            end
            default: w_s_illegal = 1'b1;
          endcase
        end
        LPARA_OPC_OP: begin
          w_s_rd_wr   = 1'b1;
          w_s_use_rs1 = 1'b1;
          w_s_use_rs2 = 1'b1;
          if (w_funct7 == LPARA_F7_MUL) begin
            // Only mul (funct3 = 000, Zmmul) is legal: mulh, mulhsu, mulhu, div, divu,
            // rem and remu are illegal.
            w_wb_sel = ENUM_WB_MUL;
            if (w_funct3 == 3'b000) begin
              w_s_mul = 1'b1;
            end else begin
              w_s_illegal = 1'b1;
            end
          end else if (w_funct7 == LPARA_F7_BASE) begin
            case (w_funct3)
              3'b000:  w_alu_op = ENUM_ALU_ADD;  // add
              3'b001:  w_alu_op = ENUM_ALU_SLL;  // sll
              3'b010:  w_alu_op = ENUM_ALU_SLT;  // slt
              3'b011:  w_alu_op = ENUM_ALU_SLTU;  // sltu
              3'b100:  w_alu_op = ENUM_ALU_XOR;  // xor
              3'b101:  w_alu_op = ENUM_ALU_SRL;  // srl
              3'b110:  w_alu_op = ENUM_ALU_OR;  // or
              3'b111:  w_alu_op = ENUM_ALU_AND;  // and
              default: w_s_illegal = 1'b1;
            endcase
          end else if (w_funct7 == LPARA_F7_ALT) begin
            case (w_funct3)
              3'b000:  w_alu_op = ENUM_ALU_SUB;  // sub
              3'b101:  w_alu_op = ENUM_ALU_SRA;  // sra
              default: w_s_illegal = 1'b1;
            endcase
          end else begin
            w_s_illegal = 1'b1;
          end
        end
        LPARA_OPC_MISC_MEM: begin
          // fence (funct3 = 000) executes as a NOP; fence.i and other encodings are illegal.
          if (w_funct3 != 3'b000) begin
            w_s_illegal = 1'b1;
          end
        end
        LPARA_OPC_SYSTEM: begin
          // Only ebreak is accepted (halt, no error); ecall, CSR and all other SYSTEM
          // opcodes are illegal.
          if (i_instr == LPARA_INSTR_EBREAK) begin
            w_s_ebreak = 1'b1;
          end else begin
            w_s_illegal = 1'b1;
          end
        end
        default: begin
          w_s_illegal = 1'b1;
        end
      endcase
    end
  end
  // REQ-001, REQ-002, REQ-073

  // Vector decode: legal only for the supported Zve32x subset with the SEW combinations
  // of REQ-074 and an even vd for the widening vwmul; masked forms (vm = 0), vsetvl and any
  // other OP-V/vle/vse form are illegal. SEW comes from the shadow vtype (sources of
  // vwmul/vwredsum, destination of vnclip, as in the RVV SEW field). vwredsum.vs is legal
  // only under vtype e8 (16-bit sources from the pair vs2/vs2+1, 32-bit sum): up to
  // PARA_VLEN/8 elements are reachable only at SEW = 8, the same vsetvli as vwmul.vv. It is
  // illegal at SEW 16/32 and before the first vsetvli. vwredsum writes one 32-bit element, so
  // it has no even-vd constraint. Defaults give "not legal".
  always_comb begin : p_com_vec
    w_v_legal   = 1'b0;
    w_v_use_rs1 = 1'b0;
    w_v_rd_wr   = 1'b0;
    w_v_vset    = 1'b0;
    w_v_vsew    = i_instr[24:23];
    case (w_opcode)
      LPARA_OPC_LOAD_FP, LPARA_OPC_STORE_FP: begin
        // vle8.v / vle32.v / vse8.v / vse32.v (EEW from the width field)
        if (w_vmem_fmt_ok && ((w_funct3 == LPARA_VW_E8) || (w_funct3 == LPARA_VW_E32))) begin
          w_v_legal   = 1'b1;
          w_v_use_rs1 = 1'b1;
        end
      end
      LPARA_OPC_OP_V: begin
        case (w_funct3)
          LPARA_V_OPCFG: begin
            if (i_instr[31] == 1'b0) begin
              // vsetvli: zimm = instr[30:20], reserved bits [30:28] must be 0
              w_v_legal   = w_vset_fld_ok && (i_instr[30:28] == 3'b000);
              w_v_use_rs1 = w_v_legal;
              w_v_rd_wr   = w_v_legal;
              w_v_vset    = w_v_legal;
            end else if (i_instr[31:30] == 2'b11) begin
              // vsetivli: zimm = instr[29:20], uimm = instr[19:15], reserved [29:28] = 0
              w_v_legal = w_vset_fld_ok && (i_instr[29:28] == 2'b00);
              w_v_rd_wr = w_v_legal;
              w_v_vset  = w_v_legal;
            end else begin
              w_v_legal = 1'b0;  // vsetvl (register vtype) is not supported
            end
          end
          LPARA_V_OPIVV: begin
            case (w_funct6)
              LPARA_F6_VADD:     w_v_legal = w_vm && w_sew_8_32;
              LPARA_F6_VWREDSUM: w_v_legal = w_vm && w_sew8;
              default:           w_v_legal = 1'b0;
            endcase
          end
          LPARA_V_OPIVX: begin
            case (w_funct6)
              LPARA_F6_VADD, LPARA_F6_VSRA, LPARA_F6_VMAX: w_v_legal = w_vm && w_sew_8_32;
              LPARA_F6_VNCLIP: w_v_legal = w_vm && w_sew_8_16;
              LPARA_F6_VMV_V: w_v_legal = w_vm && (i_instr[24:20] == 5'b00000) && w_sew_8_32;
              default: w_v_legal = 1'b0;
            endcase
            w_v_use_rs1 = w_v_legal;
          end
          LPARA_V_OPIVI: begin
            case (w_funct6)
              LPARA_F6_VSRA:   w_v_legal = w_vm && w_sew_8_32;
              LPARA_F6_VNCLIP: w_v_legal = w_vm && w_sew_8_16;
              default:         w_v_legal = 1'b0;
            endcase
          end
          LPARA_V_OPMVV: begin
            case (w_funct6)
              // vwmul.vv: SEW = 8 sources, 16-bit results in the pair vd, vd+1 (vd even)
              LPARA_F6_VWMUL:  w_v_legal = w_vm && w_sew8 && !i_instr[7];
              // vmv.x.s: vs1 field = 0, result goes to the scalar rd
              LPARA_F6_VMV_XS: w_v_legal = w_vm && (i_instr[19:15] == 5'b00000) && w_sew_8_32;
              default:         w_v_legal = 1'b0;
            endcase
            w_v_rd_wr = w_v_legal && (w_funct6 == LPARA_F6_VMV_XS);
          end
          LPARA_V_OPMVX: begin
            // vmv.s.x: vs2 field = 0, scalar rs1 value is sent to the VPU
            if (w_funct6 == LPARA_F6_VMV_XS) begin
              w_v_legal = w_vm && (i_instr[24:20] == 5'b00000) && w_sew_8_32;
            end else begin
              w_v_legal = 1'b0;
            end
            w_v_use_rs1 = w_v_legal;
          end
          default: begin
            w_v_legal = 1'b0;  // OPFVV, OPFVF and reserved funct3 values
          end
        endcase
      end
      default: begin
        w_v_legal = 1'b0;
      end
    endcase
  end
  // REQ-054, REQ-074

  // Shadow vtype: the SEW of the last accepted legal vsetvli/vsetivli. It is invalid after
  // reset, so a SEW-dependent vector instruction before the first vsetvli is illegal
  // (vle/vse are not checked against vtype). Control state, so it is reset. Updated only for
  // a valid, advancing instruction, so a flushed wrong-path vsetvli has no effect.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vtype
    if (!i_rst_n_core) begin
      reg_vsew_vld <= 1'b0;
      reg_vsew     <= LPARA_SEW_8;
    end else if (i_instr_valid && i_id_adv && w_v_vset) begin
      reg_vsew_vld <= 1'b1;
      reg_vsew     <= w_v_vsew;
    end
  end
  // REQ-054, REQ-074, REQ-083, REQ-084

  // Write-back source override: every vector instruction that writes rd (vsetvli, vsetivli,
  // vmv.x.s) takes the VPU response data.
  always_comb begin : p_com_wb
    w_wb_sel_out = w_wb_sel;
    if (w_is_vec_op) begin
      w_wb_sel_out = ENUM_WB_VPU;
    end
  end

  // Legality merge: ebreak is legal (halt, no error). An illegal instruction raises
  // o_illegal and all side-effect outputs stay 0, so nothing is written, accessed, branched
  // or dispatched to the VPU. The vector-valid output o_is_vec is asserted only for a legal
  // instruction that is valid (not flushed); a wrong-path illegal instruction or ebreak
  // flushed by a taken branch/jump (i_instr_valid = 0) raises neither o_illegal nor o_ebreak.
  // The parent keeps the instruction and rs1/rs2 stable while the pipeline stalls.
  assign w_legal = w_is_vec_op ? w_v_legal : !w_s_illegal;
  assign w_ok    = i_instr_valid && w_legal;
  // REQ-052, REQ-054, REQ-074, REQ-081, REQ-084

  assign o_illegal   = i_instr_valid && !w_legal;
  assign o_ebreak    = w_ok && !w_is_vec_op && w_s_ebreak;
  assign o_is_vec    = w_ok && w_is_vec_op;
  assign o_rd_wr_en  = w_ok && (w_is_vec_op ? w_v_rd_wr : w_s_rd_wr) && (i_instr[11:7] != 5'd0);
  assign o_use_rs1   = w_ok && (w_is_vec_op ? w_v_use_rs1 : w_s_use_rs1);
  assign o_use_rs2   = w_ok && !w_is_vec_op && w_s_use_rs2;
  assign o_alu_b_imm = w_s_b_imm;
  assign o_is_branch = w_ok && w_s_branch;
  assign o_is_jal    = w_ok && w_s_jal;
  assign o_is_jalr   = w_ok && w_s_jalr;
  assign o_mem_rd    = w_ok && w_s_mem_rd;
  assign o_mem_wr    = w_ok && w_s_mem_wr;
  assign o_is_mul    = w_ok && w_s_mul;
  assign o_alu_op    = w_alu_op;
  assign o_alu_a_sel = w_a_sel;
  assign o_imm_type  = w_imm_type;
  assign o_wb_sel    = w_wb_sel_out;
  assign o_branch_fn = w_funct3;
  assign o_mem_fn    = w_funct3;
  // REQ-001, REQ-002, REQ-052, REQ-073

endmodule
`default_nettype wire
