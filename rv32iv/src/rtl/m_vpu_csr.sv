`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Holds vl and vsew; ignores illegal vtype. On a legal set instruction it computes
 *                vl = min(AVL, VLMAX) with VLMAX = (PARA_VLEN/SEW) x LMUL (LMUL = 1 only),
 *                updates the vsew/vl registers and returns the new vl, zero extended to 32 bits,
 *                for o_resp_rd_data. An illegal vtype leaves vsew and vl unchanged.
 * Parent       : m_vpu_top
 * REQ-IDs      : REQ-004, REQ-051, REQ-077, REQ-078
 */
`timescale 1ns / 1ps

module m_vpu_csr #(
    // Parameter Description: width of one vector register; the largest VLMAX is PARA_VLEN/8.
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN        = 128,
    localparam logic [31:0] LPARA_LANE_W     = 32,
    localparam logic [31:0] LPARA_VREG_COUNT = 32,
    localparam logic [31:0] LPARA_ROW_LB     = $clog2(PARA_VLEN / 8),
    localparam logic [31:0] LPARA_VL_W       = $clog2(PARA_VLEN / 8 + 1),
    localparam logic [31:0] LPARA_XLEN       = 32
) (
    input  wire                   i_clk_core,
    input  wire                   i_rst_n_core,
    // Set instruction: one-cycle strobe for a vsetvli/vsetivli accepted by the VPU controller.
    input  wire                   i_set_en,
    // 1 = vsetivli (AVL = uimm), 0 = vsetvli (AVL = rs1 value).
    input  wire                   i_set_is_imm,
    // rs1 field is x0 / rd field is x0 (only meaningful for vsetvli).
    input  wire                   i_set_rs1_zero,
    input  wire                   i_set_rd_zero,
    // vtype immediate fields: vsew = zimm[5:3], vlmul = zimm[2:0].
    input  wire  [           2:0] i_set_vsew,
    input  wire  [           2:0] i_set_vlmul,
    // Application vector length request: rs1 value (vsetvli) or zero-extended uimm (vsetivli).
    input  wire  [LPARA_XLEN-1:0] i_set_avl,
    // Current state and the response data of the set instruction.
    output logic [           1:0] o_vsew,
    output logic [LPARA_VL_W-1:0] o_vl,
    output logic [LPARA_XLEN-1:0] o_set_vl_data
);

  // Largest VLMAX (SEW = 8, LMUL = 1); other SEW values shift it right.
  localparam logic [31:0] LPARA_VLMAX_8 = PARA_VLEN / 8;

  // SEW field encodings of the RVV vtype (vsew).
  localparam logic [ 1:0] LPARA_SEW_8   = 2'b00;
  localparam logic [ 1:0] LPARA_SEW_16  = 2'b01;
  localparam logic [ 1:0] LPARA_SEW_32  = 2'b10;

  // LMUL = 1 encoding of vlmul (the only supported value).
  localparam logic [ 2:0] LPARA_LMUL_1  = 3'b000;

  logic [           1:0] reg_vsew;
  logic [LPARA_VL_W-1:0] reg_vl;

  logic                  w_set_legal;
  logic                  w_keep_vl;
  logic                  w_avl_max;
  logic [           1:0] w_vsew_nxt;
  logic [LPARA_VL_W-1:0] w_vlmax;
  logic [LPARA_VL_W-1:0] w_vl_nxt;

  // Elaboration check of the legal parameter values.
  if ((PARA_VLEN != 32'd128) && (PARA_VLEN != 32'd256)) begin : gen_chk_vlen
    $error("m_vpu_csr: PARA_VLEN must be 128 or 256");
  end

  // Consistency checks of the derived local parameters of REQ-051: a row holds a whole number of
  // lanes, the row byte-offset width matches the largest VLMAX, and the vector register count
  // is a power of two (5-bit register index).
  if ((PARA_VLEN % LPARA_LANE_W) != 32'd0) begin : gen_chk_lane_w
    $error("m_vpu_csr: PARA_VLEN must be a multiple of LPARA_LANE_W");
  end
  if ((32'd1 << LPARA_ROW_LB) != LPARA_VLMAX_8) begin : gen_chk_row_lb
    $error("m_vpu_csr: LPARA_ROW_LB does not match PARA_VLEN/8");
  end
  if ((LPARA_VREG_COUNT & (LPARA_VREG_COUNT - 32'd1)) != 32'd0) begin : gen_chk_vreg_cnt
    $error("m_vpu_csr: LPARA_VREG_COUNT must be a power of two");
  end
  // REQ-051

  // Legality of the requested vtype: LMUL = 1 and SEW of 8, 16 or 32. The decoder in the CPU
  // already rejects other settings; a request with an illegal vtype that still reaches this
  // module is ignored: vsew and vl are unchanged and the current vl is returned.
  assign w_set_legal = (i_set_vlmul == LPARA_LMUL_1) &&
                       (i_set_vsew[2] == 1'b0) &&
                       (i_set_vsew[1:0] != 2'b11);
  // REQ-078

  // vsetvli with rs1 = x0 and rd = x0 keeps vl and, when the setting is legal, writes only the
  // new SEW; no VLMAX-preservation check is made. rs1 = x0 with rd != x0 requests AVL = VLMAX.
  // vsetivli always uses its uimm as AVL.
  assign w_keep_vl = ~i_set_is_imm & i_set_rs1_zero & i_set_rd_zero;
  assign w_avl_max = ~i_set_is_imm & i_set_rs1_zero & ~i_set_rd_zero;
  // REQ-004, REQ-077

  // VLMAX = (PARA_VLEN / SEW) x LMUL with LMUL = 1, computed for the SEW being set.
  assign w_vsew_nxt = i_set_vsew[1:0];
  always_comb begin : p_com_vlmax
    w_vlmax = LPARA_VL_W'(LPARA_VLMAX_8);
    case (w_vsew_nxt)
      LPARA_SEW_8:  w_vlmax = LPARA_VL_W'(LPARA_VLMAX_8);
      LPARA_SEW_16: w_vlmax = LPARA_VL_W'(LPARA_VLMAX_8 >> 1);
      LPARA_SEW_32: w_vlmax = LPARA_VL_W'(LPARA_VLMAX_8 >> 2);
      default:      w_vlmax = LPARA_VL_W'(LPARA_VLMAX_8);
    endcase
  end
  // REQ-004, REQ-051

  // New vl: min(AVL, VLMAX), VLMAX when AVL = VLMAX is requested, old vl when kept (REQ-077)
  // or when the request is illegal and ignored (REQ-078).
  always_comb begin : p_com_vl_nxt
    w_vl_nxt = reg_vl;
    if (i_set_en && w_set_legal && !w_keep_vl) begin
      if (w_avl_max || (i_set_avl >= LPARA_XLEN'(w_vlmax))) begin
        w_vl_nxt = w_vlmax;
      end else begin
        w_vl_nxt = i_set_avl[LPARA_VL_W-1:0];
      end
    end
  end
  // REQ-004, REQ-077, REQ-078

  // vtype/vl registers: control state, asynchronously reset to SEW = 8 and vl = 0. vsew is
  // written only for a legal setting; an illegal one leaves vsew and vl unchanged.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_vtype_vl
    if (!i_rst_n_core) begin
      reg_vsew <= LPARA_SEW_8;
      reg_vl   <= '0;
    end else begin
      if (i_set_en && w_set_legal) begin
        reg_vsew <= w_vsew_nxt;
      end
      reg_vl <= w_vl_nxt;
    end
  end
  // REQ-004, REQ-077, REQ-078

  // Outputs: current state, and the new vl zero-extended to 32 bits for o_resp_rd_data
  // (the current vl for a kept or ignored request).
  assign o_vsew        = reg_vsew;
  assign o_vl          = reg_vl;
  assign o_set_vl_data = LPARA_XLEN'(w_vl_nxt);
  // REQ-004, REQ-051, REQ-078

endmodule
`default_nettype wire
