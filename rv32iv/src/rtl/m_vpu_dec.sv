`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : VPU decode and new vl/SEW computation for vsetvli/vsetivli. Purely
 *                combinational: splits the vector instruction into operation flags and
 *                register/immediate fields, and evaluates the vector configuration
 *                instructions vsetvli/vsetivli (vl = min(AVL, VLMAX),
 *                VLMAX = (PARA_VLEN/SEW) x LMUL with LMUL = 1) so that the new vl, the new SEW
 *                and the scalar result (vl) are available to m_vpu_csr / m_vpu_ctrl.
 *                vsetvli zero,zero keeps vl and writes only the new SEW when the setting is
 *                legal, without a VLMAX-preservation check. Only instructions already accepted
 *                as legal by m_cpu_dec reach this module; an unrecognised encoding simply
 *                raises no operation flag.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-004, REQ-077
 */
`timescale 1ns / 1ps

module m_vpu_dec #(
    // Parameter Description: vector register length (one memory row). VLMAX at SEW = 8 is
    //                        PARA_VLEN/8, which fixes the width of vl (LPARA_VL_W).
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter logic [31:0] PARA_VLEN = 128,
    // Width of the scalar instruction word, of rs1/rd data and of the AVL.
    localparam logic [31:0] LPARA_XLEN = 32,
    // Width of the vl register: the largest VLMAX is PARA_VLEN/8, so vl needs clog2(VLMAX + 1) bits.
    localparam logic [31:0] LPARA_VL_W = $clog2(PARA_VLEN / 8 + 1),
    // Supported element widths used in the VLMAX formula (VLMAX = (PARA_VLEN / SEW) x LMUL, LMUL = 1).
    localparam logic [31:0] LPARA_SEW_8 = 8,
    localparam logic [31:0] LPARA_SEW_16 = 16,
    localparam logic [31:0] LPARA_SEW_32 = 32,
    // Legal PARA_VLEN values accepted by the elaboration check.
    localparam logic [31:0] LPARA_VLEN_MIN = 128,
    localparam logic [31:0] LPARA_VLEN_MAX = 256
) (
    // Instruction word, scalar rs1 value (AVL for vsetvli) and the current vl (kept by vsetvli zero,zero).
    input wire [LPARA_XLEN-1:0] i_instr,
    input wire [LPARA_XLEN-1:0] i_rs1_data,
    input wire [LPARA_VL_W-1:0] i_vl_cur,

    // Operation flags (one-hot, 0 when the encoding is not part of the supported subset).
    output logic o_is_vsetvl,
    output logic o_is_vle,
    output logic o_is_vse,
    output logic o_is_vadd,
    output logic o_is_vsra,
    output logic o_is_vmax,
    output logic o_is_vnclip,
    output logic o_is_vmv_vx,
    output logic o_is_vmv_sx,
    output logic o_is_vmv_xs,
    output logic o_is_vwmul,
    output logic o_is_vwredsum,
    output logic o_dec_valid,

    // Operand form: second source is a scalar (.vx/.sx) or a 5-bit immediate (.vi/.wi).
    output logic o_src_scalar,
    output logic o_src_imm,

    // Register and immediate fields.
    output logic [4:0] o_vd,
    output logic [4:0] o_vs1,
    output logic [4:0] o_vs2,
    output logic [4:0] o_imm5,
    output logic [4:0] o_rd,

    // Unit-stride memory element width: 2'd0 = 8 bit (vle8/vse8), 2'd2 = 32 bit (vle32/vse32).
    output logic [1:0] o_mem_eew,

    // vsetvli/vsetivli result: vl and SEW update, and the scalar result returned to the CPU
    // (o_resp_rd_data of m_vpu_top). Writes are only requested for a legal setting (LMUL = 1).
    output logic                  o_vset_we,
    output logic [LPARA_VL_W-1:0] o_vset_vl,
    output logic [           1:0] o_vset_sew,
    output logic [LPARA_XLEN-1:0] o_vset_rd_data,
    output logic                  o_vset_rd_en
);

  // Major opcodes and funct3 / funct6 codes of the supported RVV subset (RVV 1.0 encoding).
  localparam logic [6:0] LPARA_OPC_V     = 7'h57;
  localparam logic [6:0] LPARA_OPC_VLD   = 7'h07;
  localparam logic [6:0] LPARA_OPC_VST   = 7'h27;
  localparam logic [2:0] LPARA_F3_OPIVV  = 3'b000;
  localparam logic [2:0] LPARA_F3_OPMVV  = 3'b010;
  localparam logic [2:0] LPARA_F3_OPIVI  = 3'b011;
  localparam logic [2:0] LPARA_F3_OPIVX  = 3'b100;
  localparam logic [2:0] LPARA_F3_OPMVX  = 3'b110;
  localparam logic [2:0] LPARA_F3_CFG    = 3'b111;
  localparam logic [2:0] LPARA_F3_MEM8   = 3'b000;
  localparam logic [2:0] LPARA_F3_MEM32  = 3'b110;
  localparam logic [5:0] LPARA_F6_VADD   = 6'b000000;
  localparam logic [5:0] LPARA_F6_VMAX   = 6'b000111;
  localparam logic [5:0] LPARA_F6_VSRA   = 6'b101001;
  localparam logic [5:0] LPARA_F6_VNCLIP = 6'b101111;
  localparam logic [5:0] LPARA_F6_VMV    = 6'b010111;
  localparam logic [5:0] LPARA_F6_VWXUN  = 6'b010000;
  localparam logic [5:0] LPARA_F6_VWMUL  = 6'b111011;
  localparam logic [5:0] LPARA_F6_VWRED  = 6'b110001;
  localparam logic [2:0] LPARA_VSEW_8    = 3'd0;
  localparam logic [2:0] LPARA_VSEW_16   = 3'd1;
  localparam logic [2:0] LPARA_VSEW_32   = 3'd2;
  localparam logic [2:0] LPARA_LMUL_1    = 3'd0;
  localparam logic [1:0] LPARA_VSETIVLI  = 2'b11;

  // Elaboration check: PARA_VLEN outside the supported range is rejected.
  if ((PARA_VLEN != LPARA_VLEN_MIN) && (PARA_VLEN != LPARA_VLEN_MAX)) begin : gen_chk_vlen
    $error("m_vpu_dec: PARA_VLEN must be 128 or 256");
  end

  // Instruction field split.
  logic [           6:0] w_opcode;
  logic [           2:0] w_funct3;
  logic [           5:0] w_funct6;
  logic                  w_vm;
  logic                  w_op_v;
  logic                  w_mem_fmt_ok;

  // vsetvli / vsetivli evaluation.
  logic                  w_is_cfg;
  logic                  w_is_vsetvli;
  logic                  w_is_vsetivli;
  logic                  w_vtype_rsv_ok;
  logic [           2:0] w_vsew;
  logic [           2:0] w_vlmul;
  logic                  w_vsew_ok;
  logic                  w_vset_ok;
  logic                  w_rs1_zero;
  logic                  w_rd_zero;
  logic                  w_vl_keep;
  logic [LPARA_XLEN-1:0] w_vlmax;
  logic [LPARA_XLEN-1:0] w_avl;
  logic [LPARA_VL_W-1:0] w_vl_nxt;
  logic [           1:0] w_sew_enc;

  // Operation flags before the final decode-valid reduction.
  logic                  w_vadd;
  logic                  w_vsra;
  logic                  w_vmax;
  logic                  w_vnclip;
  logic                  w_vmv_vx;
  logic                  w_vmv_sx;
  logic                  w_vmv_xs;
  logic                  w_vwmul;
  logic                  w_vwredsum;
  logic                  w_vle;
  logic                  w_vse;

  // Field extraction: standard RISC-V / RVV positions. Unmasked operation (vm = 1) is the only
  // form supported (no masking in this design).
  assign w_opcode      = i_instr[6:0];
  assign w_funct3      = i_instr[14:12];
  assign w_funct6      = i_instr[31:26];
  assign w_vm          = i_instr[25];
  assign w_op_v        = (w_opcode == LPARA_OPC_V);

  assign o_vd          = i_instr[11:7];
  assign o_rd          = i_instr[11:7];
  assign o_vs1         = i_instr[19:15];
  assign o_imm5        = i_instr[19:15];
  assign o_vs2         = i_instr[24:20];
  // REQ-004

  // Configuration instructions: vsetvli has bit 31 = 0, vsetivli has bits 31:30 = 2'b11.
  // vtype: vsew = bits 25:23, vlmul = bits 22:20; vta/vma (bits 27:26) are ignored because tail
  // elements are always undisturbed (ASM-004). Reserved vtype bits must be 0.
  assign w_is_cfg      = w_op_v & (w_funct3 == LPARA_F3_CFG);
  assign w_is_vsetvli  = w_is_cfg & ~i_instr[31];
  assign w_is_vsetivli = w_is_cfg & (i_instr[31:30] == LPARA_VSETIVLI);
  assign w_vsew        = i_instr[25:23];
  assign w_vlmul       = i_instr[22:20];
  assign w_rs1_zero    = (i_instr[19:15] == '0);
  assign w_rd_zero     = (i_instr[11:7] == '0);
  assign w_vl_keep     = w_is_vsetvli & w_rs1_zero & w_rd_zero;

  always_comb begin : p_com_vtype
    w_vtype_rsv_ok = 1'b0;
    if (w_is_vsetvli) begin
      w_vtype_rsv_ok = (i_instr[30:28] == '0);
    end else if (w_is_vsetivli) begin
      w_vtype_rsv_ok = (i_instr[29:28] == '0);
    end
    w_vsew_ok = 1'b0;
    w_sew_enc = '0;
    case (w_vsew)
      LPARA_VSEW_8: begin
        w_vsew_ok = 1'b1;
        w_sew_enc = 2'd0;
      end
      LPARA_VSEW_16: begin
        w_vsew_ok = 1'b1;
        w_sew_enc = 2'd1;
      end
      LPARA_VSEW_32: begin
        w_vsew_ok = 1'b1;
        w_sew_enc = 2'd2;
      end
      default: begin
        w_vsew_ok = 1'b0;
        w_sew_enc = '0;
      end
    endcase
  end
  assign w_vset_ok = (w_is_vsetvli | w_is_vsetivli) & w_vtype_rsv_ok & w_vsew_ok &
                     (w_vlmul == LPARA_LMUL_1);
  // REQ-004

  // VLMAX = (PARA_VLEN / SEW) x LMUL, LMUL = 1; one value per supported SEW.
  always_comb begin : p_com_vlmax
    w_vlmax = '0;
    case (w_vsew)
      LPARA_VSEW_8:  w_vlmax = PARA_VLEN / LPARA_SEW_8;
      LPARA_VSEW_16: w_vlmax = PARA_VLEN / LPARA_SEW_16;
      LPARA_VSEW_32: w_vlmax = PARA_VLEN / LPARA_SEW_32;
      default:       w_vlmax = '0;
    endcase
  end
  // REQ-004

  // AVL selection: vsetivli uses the 5-bit unsigned immediate; vsetvli uses rs1, except that
  // rs1 = x0 with rd != x0 requests the maximum (AVL = all ones, so vl = VLMAX).
  always_comb begin : p_com_avl
    w_avl = i_rs1_data;
    if (w_is_vsetivli) begin
      w_avl = $bits(w_avl)'(i_instr[19:15]);
    end else if (w_rs1_zero) begin
      w_avl = '1;
    end else begin
      w_avl = i_rs1_data;
    end
  end
  // REQ-004

  // vl = min(AVL, VLMAX). VLMAX <= PARA_VLEN/8 so the narrowing to the vl width cannot lose bits.
  // vsetvli zero,zero (rs1 = rd = x0) keeps the current vl; the new SEW is still written through
  // o_vset_we/o_vset_sew when the setting is legal (LMUL = 1, SEW 8/16/32). No check that VLMAX
  // is preserved is made for this form, so vl may exceed the VLMAX of the new SEW.
  always_comb begin : p_com_vl
    if (w_avl < w_vlmax) begin
      w_vl_nxt = $bits(w_vl_nxt)'(w_avl);
    end else begin
      w_vl_nxt = $bits(w_vl_nxt)'(w_vlmax);
    end
    if (w_vl_keep) begin
      w_vl_nxt = i_vl_cur;
    end
  end
  // REQ-004, REQ-077

  // vsetvl results: vl/SEW update only for a legal setting; vl is returned to the CPU when
  // rd != x0 (zero-extended to XLEN).
  assign o_is_vsetvl = w_vset_ok;
  assign o_vset_we = w_vset_ok;
  assign o_vset_vl = w_vl_nxt;
  assign o_vset_sew = w_sew_enc;
  assign o_vset_rd_en = w_vset_ok & ~w_rd_zero;
  assign o_vset_rd_data = w_vset_ok ? $bits(o_vset_rd_data)'(w_vl_nxt) : '0;
  // REQ-004, REQ-077

  // Unit-stride loads/stores: nf = 0, mew = 0, mop = 0 (unit stride), lumop/sumop = 0, vm = 1.
  assign w_mem_fmt_ok = (i_instr[31:26] == '0) & (i_instr[24:20] == '0) & w_vm;
  assign w_vle        = (w_opcode == LPARA_OPC_VLD) & w_mem_fmt_ok &
                        ((w_funct3 == LPARA_F3_MEM8) | (w_funct3 == LPARA_F3_MEM32));
  assign w_vse        = (w_opcode == LPARA_OPC_VST) & w_mem_fmt_ok &
                        ((w_funct3 == LPARA_F3_MEM8) | (w_funct3 == LPARA_F3_MEM32));
  assign o_mem_eew = (w_funct3 == LPARA_F3_MEM32) ? 2'd2 : 2'd0;

  // Vector arithmetic subset (all unmasked, vm = 1).
  assign w_vadd     = w_op_v & w_vm & (w_funct6 == LPARA_F6_VADD) &
                      ((w_funct3 == LPARA_F3_OPIVV) | (w_funct3 == LPARA_F3_OPIVX));
  assign w_vsra     = w_op_v & w_vm & (w_funct6 == LPARA_F6_VSRA) &
                      ((w_funct3 == LPARA_F3_OPIVI) | (w_funct3 == LPARA_F3_OPIVX));
  assign w_vmax = w_op_v & w_vm & (w_funct6 == LPARA_F6_VMAX) & (w_funct3 == LPARA_F3_OPIVX);
  assign w_vnclip   = w_op_v & w_vm & (w_funct6 == LPARA_F6_VNCLIP) &
                      ((w_funct3 == LPARA_F3_OPIVI) | (w_funct3 == LPARA_F3_OPIVX));
  assign w_vmv_vx   = w_op_v & w_vm & (w_funct6 == LPARA_F6_VMV) & (w_funct3 == LPARA_F3_OPIVX) &
                      (i_instr[24:20] == '0);
  assign w_vmv_sx   = w_op_v & w_vm & (w_funct6 == LPARA_F6_VWXUN) & (w_funct3 == LPARA_F3_OPMVX) &
                      (i_instr[24:20] == '0);
  assign w_vmv_xs   = w_op_v & w_vm & (w_funct6 == LPARA_F6_VWXUN) & (w_funct3 == LPARA_F3_OPMVV) &
                      (i_instr[19:15] == '0);
  assign w_vwmul = w_op_v & w_vm & (w_funct6 == LPARA_F6_VWMUL) & (w_funct3 == LPARA_F3_OPMVV);
  assign w_vwredsum = w_op_v & w_vm & (w_funct6 == LPARA_F6_VWRED) & (w_funct3 == LPARA_F3_OPIVV);

  assign o_is_vle = w_vle;
  assign o_is_vse = w_vse;
  assign o_is_vadd = w_vadd;
  assign o_is_vsra = w_vsra;
  assign o_is_vmax = w_vmax;
  assign o_is_vnclip = w_vnclip;
  assign o_is_vmv_vx = w_vmv_vx;
  assign o_is_vmv_sx = w_vmv_sx;
  assign o_is_vmv_xs = w_vmv_xs;
  assign o_is_vwmul = w_vwmul;
  assign o_is_vwredsum = w_vwredsum;

  // Operand form: scalar for OPIVX/OPMVX, 5-bit immediate for OPIVI.
  assign o_src_scalar = w_op_v & ((w_funct3 == LPARA_F3_OPIVX) | (w_funct3 == LPARA_F3_OPMVX));
  assign o_src_imm = w_op_v & (w_funct3 == LPARA_F3_OPIVI);

  // Any recognised operation of the supported subset.
  assign o_dec_valid = w_vset_ok | w_vle | w_vse | w_vadd | w_vsra | w_vmax | w_vnclip |
                       w_vmv_vx | w_vmv_sx | w_vmv_xs | w_vwmul | w_vwredsum;
  // REQ-004

endmodule
`default_nettype wire
