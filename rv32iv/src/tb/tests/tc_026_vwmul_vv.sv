// TC-026 | REQ-006, REQ-059
// vwmul.vv at SEW=8: v4/v5 <- v1 * v2 (INT8 x INT8 -> INT16), vd = v4 (even), result pair v4 (elements 0..7)
// and v5 (elements 8..15). 8 cases:
//   0: all -128 x -128 (= 16384), vl = 16
//   1: directed mix (-128*127, 127*127, 0, 1, -1, +/-100 ...), vl = 16
//   2..7: random with edge bias, vl = 1, 3, 8, 9, 15, 16
// Per case: v1=A, v2=B, v4=T4, v5=T5 (tail pattern), v6=C6 (untouched register) are loaded with vl=16;
// vwmul runs with the case vl; then v4, v5, v6, v1, v2 are stored (vl=16) and compared:
//   16-bit product for elements < vl, old register bytes for elements >= vl (tail undisturbed),
//   v6/v1/v2 unchanged (no other register written).
task automatic tc_026_vwmul_vv();
  logic [7:0]  a_b [8][16];
  logic [7:0]  b_b [8][16];
  logic [7:0]  t4_b [16];
  logic [7:0]  t5_b [16];
  logic [7:0]  c6_b [16];
  logic [7:0]  ex_b [32];
  int          vl_c [8];
  int          a1d [16];
  int          b1d [16];
  logic [7:0]  edge8 [5];
  logic [31:0] CB, r, v, w;
  longint      p;
  int          c, i, wd, e;

  vl_c  = '{16, 16, 1, 3, 8, 9, 15, 16};
  a1d   = '{-128, -128, -128, 127, 127, 0, 1, -1, -1, 1, 0, 5, -5, 100, -100, -128};
  b1d   = '{-128, 127, 1, -128, 127, 55, -1, -1, -1, -128, 99, -5, -5, -100, -100, 127};
  edge8 = '{8'h80, 8'h7F, 8'h00, 8'h01, 8'hFF};
  for (i = 0; i < 16; i++) begin
    t4_b[i] = 8'h30 + 8'(i * 3);
    t5_b[i] = 8'hC0 - 8'(i * 5);
    c6_b[i] = 8'h55 ^ 8'(i);
  end
  for (c = 0; c < 8; c++) begin
    for (i = 0; i < 16; i++) begin
      if (c == 0) begin
        a_b[c][i] = 8'h80;
        b_b[c][i] = 8'h80;
      end else if (c == 1) begin
        a_b[c][i] = 8'(a1d[i]);
        b_b[c][i] = 8'(b1d[i]);
      end else begin
        r = tb_rand32();
        a_b[c][i] = r[0] ? edge8[(r[15:8] % 5)] : r[23:16];
        r = tb_rand32();
        b_b[c][i] = r[0] ? edge8[(r[15:8] % 5)] : r[23:16];
      end
    end
  end

  // ---- memory image: per case CB = 0x1000_5000 + c*0x100 : A +0, B +0x10, T4 +0x20, T5 +0x30, C6 +0x40,
  //      outputs O4 +0x50, O5 +0x60, O6 +0x70, O1 +0x80, O2 +0x90
  for (c = 0; c < 8; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h00 + 32'(4 * wd), {a_b[c][4*wd+3], a_b[c][4*wd+2], a_b[c][4*wd+1], a_b[c][4*wd]});
      dmem_wr(CB + 32'h10 + 32'(4 * wd), {b_b[c][4*wd+3], b_b[c][4*wd+2], b_b[c][4*wd+1], b_b[c][4*wd]});
      dmem_wr(CB + 32'h20 + 32'(4 * wd), {t4_b[4*wd+3], t4_b[4*wd+2], t4_b[4*wd+1], t4_b[4*wd]});
      dmem_wr(CB + 32'h30 + 32'(4 * wd), {t5_b[4*wd+3], t5_b[4*wd+2], t5_b[4*wd+1], t5_b[4*wd]});
      dmem_wr(CB + 32'h40 + 32'(4 * wd), {c6_b[4*wd+3], c6_b[4*wd+2], c6_b[4*wd+1], c6_b[4*wd]});
      dmem_wr(CB + 32'h50 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h60 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h70 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h80 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h90 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  // ---- program
  prog_reset();
  prog_org(0);
  for (c = 0; c < 8; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    emit_li(5'd12, CB + 32'h00);
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd15, CB + 32'h30);
    emit_li(5'd16, CB + 32'h40);
    emit_li(5'd17, CB + 32'h50);
    emit_li(5'd18, CB + 32'h60);
    emit_li(5'd19, CB + 32'h70);
    emit_li(5'd20, CB + 32'h80);
    emit_li(5'd21, CB + 32'h90);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd1, 5'd12));
    emit(rv_vle8(5'd2, 5'd13));
    emit(rv_vle8(5'd4, 5'd14));
    emit(rv_vle8(5'd5, 5'd15));
    emit(rv_vle8(5'd6, 5'd16));
    emit_li(5'd10, 32'(vl_c[c]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vwmul_vv(5'd4, 5'd1, 5'd2));
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd4, 5'd17));
    emit(rv_vse8(5'd5, 5'd18));
    emit(rv_vse8(5'd6, 5'd19));
    emit(rv_vse8(5'd1, 5'd20));
    emit(rv_vse8(5'd2, 5'd21));
  end
  emit_halt();

  run_prog(100000);
  `TC_CHECK(tb_run_hit, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "o_err_illegal set: legal vwmul.vv rejected")

  for (c = 0; c < 8; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    for (i = 0; i < 16; i++) begin                       // expected pair content (32 bytes: v4 then v5)
      ex_b[i]      = t4_b[i];
      ex_b[16 + i] = t5_b[i];
    end
    for (e = 0; e < vl_c[c]; e++) begin
      p = sx({24'h0, a_b[c][e]}, 8) * sx({24'h0, b_b[c][e]}, 8);
      ex_b[2 * e]     = p[7:0];
      ex_b[2 * e + 1] = p[15:8];
    end
    for (wd = 0; wd < 8; wd++) begin                     // O4 (+0x50) words 0..3, O5 (+0x60) words 4..7
      w = {ex_b[4*wd+3], ex_b[4*wd+2], ex_b[4*wd+1], ex_b[4*wd]};
      dmem_rd(CB + ((wd < 4) ? 32'h50 : 32'h60) + 32'(4 * (wd % 4)), v);
      `TC_CHECK(v === w, $sformatf("case %0d vl=%0d: pair word %0d = 0x%08h, expected 0x%08h", c, vl_c[c], wd, v, w))
    end
    for (wd = 0; wd < 4; wd++) begin
      w = {c6_b[4*wd+3], c6_b[4*wd+2], c6_b[4*wd+1], c6_b[4*wd]};
      dmem_rd(CB + 32'h70 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d: v6 changed (word %0d = 0x%08h, expected 0x%08h)", c, wd, v, w))
      w = {a_b[c][4*wd+3], a_b[c][4*wd+2], a_b[c][4*wd+1], a_b[c][4*wd]};
      dmem_rd(CB + 32'h80 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d: source v1 changed (word %0d = 0x%08h)", c, wd, v))
      w = {b_b[c][4*wd+3], b_b[c][4*wd+2], b_b[c][4*wd+1], b_b[c][4*wd]};
      dmem_rd(CB + 32'h90 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d: source v2 changed (word %0d = 0x%08h)", c, wd, v))
    end
  end
  mon_check_all();
endtask
