// TC-028 | REQ-008, REQ-059
// vadd.vv / vadd.vx / vsra.vi / vsra.vx / vmax.vx at SEW=8 (16 elements) and SEW=32 (4 elements), with edge-biased
// random data, three vl values per (op, SEW) (VLMAX, odd, 1): 30 cases.
//   v1 = A (vs2), v2 = B (vs1, vv form), v3 = D (old destination), scalar x5 (vx form), imm (vi form).
//   result v3 : elements < vl = op(A, B|x|imm), elements >= vl = D (tail undisturbed); v1 stays A.
// Reference (RVV 1.0): vadd wraps at SEW; vsra shifts arithmetically by (amount & (SEW-1)) -- amounts above
//   log2(SEW) bits (9, 33, 0xFFFF_FFE5, imm 31 at SEW 8, ...) are masked; vmax is signed, scalar taken as the low SEW bits
//   sign-extended.
task automatic tc_028_vadd_vsra_vmax();
  logic [7:0]  a_b [30][16];
  logic [7:0]  b_b [30][16];
  logic [7:0]  d_b [30][16];
  int          c_op [30];
  int          c_sew [30];
  int          c_vl [30];
  int          c_imm [30];
  logic [31:0] c_x [30];
  logic [7:0]  edge8 [5];
  logic [31:0] edge32 [6];
  logic [31:0] sc_tab [10];
  int          imm_tab [2][3];
  logic [31:0] shx_tab [2][3];
  logic [31:0] CB, r, aw, bw, rb, v, w;
  longint      a, bb, res;
  int          ci, op, sewi, vr, i, j, e, eb, ne, vlmax, sh, wd, sew;
  logic [7:0]  ex_b [16];

  edge8   = '{8'h00, 8'h01, 8'h7F, 8'h80, 8'hFF};
  edge32  = '{32'h0000_0000, 32'h0000_0001, 32'h7FFF_FFFF, 32'h8000_0000, 32'hFFFF_FFFF, 32'h0000_FFFF};
  sc_tab  = '{32'h0000_0000, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_007F, 32'h0000_0080, 32'h8000_0000,
              32'h7FFF_FFFF, 32'h0000_0101, 32'hFFFF_FF80, 32'h0000_7F7F};
  imm_tab = '{'{9, 7, 31}, '{1, 31, 16}};
  shx_tab = '{'{32'd9, 32'd7, 32'd33}, '{32'd33, 32'd31, 32'hFFFF_FFE5}};

  // ---- case table and data
  ci = 0;
  for (op = 0; op < 5; op++) begin
    for (sewi = 0; sewi < 2; sewi++) begin
      for (vr = 0; vr < 3; vr++) begin
        sew   = (sewi == 1) ? 32 : 8;
        vlmax = (sewi == 1) ? 4 : 16;
        c_op[ci]  = op;
        c_sew[ci] = sew;
        c_vl[ci]  = (vr == 0) ? vlmax : ((vr == 1) ? ((sewi == 1) ? 3 : 7) : 1);
        c_imm[ci] = 0;
        c_x[ci]   = 32'h0;
        if (op == 2)      c_imm[ci] = imm_tab[sewi][vr];
        else if (op == 3) c_x[ci]   = shx_tab[sewi][vr];
        else if (op == 1 || op == 4) c_x[ci] = sc_tab[(sewi * 3 + vr + op) % 10];
        for (i = 0; i < 16; i++) d_b[ci][i] = 8'h21 + 8'(i * 13) + 8'(ci);
        if (sew == 8) begin
          for (i = 0; i < 16; i++) begin
            r = tb_rand32();
            a_b[ci][i] = r[0] ? edge8[(r[15:8] % 5)] : r[23:16];
            r = tb_rand32();
            b_b[ci][i] = r[0] ? edge8[(r[15:8] % 5)] : r[23:16];
          end
        end else begin
          for (e = 0; e < 4; e++) begin
            r = tb_rand32();
            aw = r[0] ? edge32[(r[15:8] % 6)] : tb_rand32();
            r = tb_rand32();
            bw = r[0] ? edge32[(r[15:8] % 6)] : tb_rand32();
            for (j = 0; j < 4; j++) begin
              a_b[ci][4 * e + j] = aw[8*j +: 8];
              b_b[ci][4 * e + j] = bw[8*j +: 8];
            end
          end
        end
        ci++;
      end
    end
  end

  // ---- memory image: CB = 0x1000_5000 + c*0x100 : A +0, B +0x10, D +0x20, O3 +0x30, O1 +0x40
  for (ci = 0; ci < 30; ci++) begin
    CB = 32'h1000_5000 + 32'(ci * 256);
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h00 + 32'(4 * wd), {a_b[ci][4*wd+3], a_b[ci][4*wd+2], a_b[ci][4*wd+1], a_b[ci][4*wd]});
      dmem_wr(CB + 32'h10 + 32'(4 * wd), {b_b[ci][4*wd+3], b_b[ci][4*wd+2], b_b[ci][4*wd+1], b_b[ci][4*wd]});
      dmem_wr(CB + 32'h20 + 32'(4 * wd), {d_b[ci][4*wd+3], d_b[ci][4*wd+2], d_b[ci][4*wd+1], d_b[ci][4*wd]});
      dmem_wr(CB + 32'h30 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h40 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  // ---- program
  prog_reset();
  prog_org(0);
  for (ci = 0; ci < 30; ci++) begin
    CB = 32'h1000_5000 + 32'(ci * 256);
    emit_li(5'd12, CB + 32'h00);
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd15, CB + 32'h30);
    emit_li(5'd16, CB + 32'h40);
    emit_li(5'd5, c_x[ci]);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd1, 5'd12));
    emit(rv_vle8(5'd2, 5'd13));
    emit(rv_vle8(5'd3, 5'd14));
    emit_li(5'd10, 32'(c_vl[ci]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(c_sew[ci])));
    case (c_op[ci])
      0: emit(rv_vadd_vv(5'd3, 5'd1, 5'd2));
      1: emit(rv_vadd_vx(5'd3, 5'd1, 5'd5));
      2: emit(rv_vsra_vi(5'd3, 5'd1, 5'(c_imm[ci])));
      3: emit(rv_vsra_vx(5'd3, 5'd1, 5'd5));
      default: emit(rv_vmax_vx(5'd3, 5'd1, 5'd5));
    endcase
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd3, 5'd15));
    emit(rv_vse8(5'd1, 5'd16));
  end
  emit_halt();

  run_prog(200000);
  `TC_CHECK(tb_run_hit, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "o_err_illegal set: legal vadd/vsra/vmax (SEW 8/32) rejected")

  for (ci = 0; ci < 30; ci++) begin
    CB  = 32'h1000_5000 + 32'(ci * 256);
    sew = c_sew[ci];
    eb  = sew / 8;
    ne  = 16 / eb;
    for (i = 0; i < 16; i++) ex_b[i] = d_b[ci][i];
    for (e = 0; e < c_vl[ci]; e++) begin
      aw = 32'h0;
      bw = 32'h0;
      for (j = 0; j < eb; j++) begin
        aw[8*j +: 8] = a_b[ci][e * eb + j];
        bw[8*j +: 8] = b_b[ci][e * eb + j];
      end
      a = sx(aw, sew);
      case (c_op[ci])
        0: rb = aw + bw;
        1: rb = aw + c_x[ci];
        2: begin sh = c_imm[ci] & (sew - 1);                 res = a >>> sh; rb = res[31:0]; end
        3: begin sh = int'(c_x[ci] & 32'(sew - 1));          res = a >>> sh; rb = res[31:0]; end
        default: begin bb = sx(c_x[ci], sew); res = (a > bb) ? a : bb; rb = res[31:0]; end
      endcase
      for (j = 0; j < eb; j++) ex_b[e * eb + j] = rb[8*j +: 8];
    end
    for (wd = 0; wd < 4; wd++) begin
      w = {ex_b[4*wd+3], ex_b[4*wd+2], ex_b[4*wd+1], ex_b[4*wd]};
      dmem_rd(CB + 32'h30 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d op %0d e%0d vl=%0d x=0x%08h imm=%0d: word %0d = 0x%08h, expected 0x%08h",
                                   ci, c_op[ci], sew, c_vl[ci], c_x[ci], c_imm[ci], wd, v, w))
      w = {a_b[ci][4*wd+3], a_b[ci][4*wd+2], a_b[ci][4*wd+1], a_b[ci][4*wd]};
      dmem_rd(CB + 32'h40 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d: source v1 changed (word %0d = 0x%08h)", ci, wd, v))
    end
  end
  mon_check_all();
endtask
