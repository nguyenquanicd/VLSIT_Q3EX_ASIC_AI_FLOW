// TC-029 | REQ-008, REQ-060
// vnclip.wi / vnclip.wx, source pair v2/v3 (wide elements), destination v4 (narrow elements), vxrm = 0
// (round-to-nearest-up): result = saturate(((src >>> s) + round_bit), signed dst range), no wrap-around.
//   32 -> 16 : vtype SEW=16 (vl <= 8), shift = shift_field[4:0]    -- 12 cases (6 wi, 6 wx)
//   16 -> 8  : vtype SEW=8  (vl <= 16), shift = shift_field[3:0]   -- 12 cases (7 wi, 5 wx)
// Source data mixes edge values with values just below/above the clamp thresholds scaled by the shift, so both
// saturation ends and the rounding increment are hit. The wx scalar carries shift_field with garbage upper bits
// (0x20, 0xFFFF_FFE1, 0x10, 0xFFFF_FFF9) to check the shift masking. Elements >= vl keep their old value.
task automatic tc_029_vnclip_saturation();
  logic [7:0]  src_b [24][32];
  logic [7:0]  d_b   [24][16];
  int          c_dst [24];
  int          c_wx  [24];
  logic [31:0] c_raw [24];
  int          c_vl  [24];
  logic [31:0] raw_wi32 [6];
  logic [31:0] raw_wx32 [6];
  logic [31:0] raw_wi16 [7];
  logic [31:0] raw_wx16 [5];
  logic [31:0] edge32 [10];
  logic [31:0] edge16 [10];
  logic [7:0]  ex_b [16];
  logic [31:0] CB, r, vv, v, w, rbits, ev;
  longint      base, val, mask, res, thr;
  int          ci, i, j, e, grp, k, dst, sw, db, eff, vlmax, wd, m;

  raw_wi32 = '{32'd0, 32'd1, 32'd8, 32'd15, 32'd16, 32'd31};
  raw_wx32 = '{32'd0, 32'd3, 32'd16, 32'd31, 32'h0000_0020, 32'hFFFF_FFE1};
  raw_wi16 = '{32'd0, 32'd1, 32'd4, 32'd8, 32'd15, 32'd16, 32'd31};
  raw_wx16 = '{32'd0, 32'd3, 32'd15, 32'h0000_0010, 32'hFFFF_FFF9};
  edge32   = '{32'h0000_0000, 32'h0000_0001, 32'hFFFF_FFFF, 32'h7FFF_FFFF, 32'h8000_0000, 32'h0000_7FFF,
               32'h0000_8000, 32'hFFFF_8000, 32'hFFFF_7FFF, 32'h0001_0000};
  edge16   = '{32'h0000_0000, 32'h0000_0001, 32'h0000_FFFF, 32'h0000_7FFF, 32'h0000_8000, 32'h0000_007F,
               32'h0000_0080, 32'h0000_FF80, 32'h0000_FF7F, 32'h0000_0100};

  // ---- case table
  ci = 0;
  for (grp = 0; grp < 2; grp++) begin
    for (k = 0; k < 13; k++) begin
      // grp 0 (32->16): k 0..5 wi, 6..11 wx ; grp 1 (16->8): k 0..6 wi, 7..11 wx
      if (grp == 0 && k < 12) begin
        c_dst[ci] = 16;  c_wx[ci] = (k >= 6);  c_raw[ci] = (k < 6) ? raw_wi32[k] : raw_wx32[k - 6];
        ci++;
      end else if (grp == 1 && k < 12) begin
        c_dst[ci] = 8;   c_wx[ci] = (k >= 7);  c_raw[ci] = (k < 7) ? raw_wi16[k] : raw_wx16[k - 7];
        ci++;
      end
    end
  end

  // ---- data
  for (ci = 0; ci < 24; ci++) begin
    dst   = c_dst[ci];
    sw    = 2 * dst;
    db    = dst / 8;
    vlmax = 16 / db;
    eff   = int'(c_raw[ci] & ((dst == 16) ? 32'd31 : 32'd15));
    c_vl[ci] = ((ci % 3) == 0) ? vlmax : (((ci % 3) == 1) ? ((dst == 16) ? 5 : 11) : 1);
    for (i = 0; i < 16; i++) d_b[ci][i] = 8'h5A + 8'(i * 9) + 8'(ci);
    thr = 64'sd1 <<< (dst - 1);
    for (e = 0; e < vlmax; e++) begin
      r = tb_rand32();
      m = int'(r[1:0]);
      if (m == 0) begin
        vv = (dst == 16) ? edge32[(r[11:4] % 10)] : edge16[(r[11:4] % 10)];
      end else if (m == 1) begin
        vv = tb_rand32();
      end else begin
        base = ((r[4] ? thr : -thr)) + (longint'(r[7:5] % 5) - 2);
        mask = (64'sd1 <<< eff) - 64'sd1;
        val  = (base <<< eff) + longint'(tb_rand32() & mask[31:0]);
        vv   = val[31:0];
      end
      for (j = 0; j < db * 2; j++) src_b[ci][e * db * 2 + j] = vv[8*j +: 8];
    end
  end

  // ---- memory image: CB = 0x1000_5000 + c*0x100 : P0 +0, P1 +0x10 (32 source bytes), D +0x20, O +0x30
  for (ci = 0; ci < 24; ci++) begin
    CB = 32'h1000_5000 + 32'(ci * 256);
    for (wd = 0; wd < 8; wd++)
      dmem_wr(CB + 32'(4 * wd), {src_b[ci][4*wd+3], src_b[ci][4*wd+2], src_b[ci][4*wd+1], src_b[ci][4*wd]});
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h20 + 32'(4 * wd), {d_b[ci][4*wd+3], d_b[ci][4*wd+2], d_b[ci][4*wd+1], d_b[ci][4*wd]});
      dmem_wr(CB + 32'h30 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  // ---- program
  prog_reset();
  prog_org(0);
  for (ci = 0; ci < 24; ci++) begin
    CB  = 32'h1000_5000 + 32'(ci * 256);
    dst = c_dst[ci];
    emit_li(5'd12, CB + 32'h00);
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd15, CB + 32'h30);
    emit_li(5'd5, c_raw[ci]);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd2, 5'd12));
    emit(rv_vle8(5'd3, 5'd13));
    emit(rv_vle8(5'd4, 5'd14));
    emit_li(5'd10, 32'(c_vl[ci]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(dst)));
    if (c_wx[ci]) emit(rv_vnclip_wx(5'd4, 5'd2, 5'd5));
    else          emit(rv_vnclip_wi(5'd4, 5'd2, 5'(c_raw[ci])));
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd4, 5'd15));
  end
  emit_halt();

  run_prog(200000);

  `TC_CHECK(tb_run_hit, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "o_err_illegal set: legal vnclip (32->16 / 16->8) rejected")

  for (ci = 0; ci < 24; ci++) begin
    CB    = 32'h1000_5000 + 32'(ci * 256);
    dst   = c_dst[ci];
    sw    = 2 * dst;
    db    = dst / 8;
    vlmax = 16 / db;
    eff   = int'(c_raw[ci] & ((dst == 16) ? 32'd31 : 32'd15));
    for (e = 0; e < vlmax; e++) begin
      ev = 32'h0;
      for (j = 0; j < db * 2; j++) ev[8*j +: 8] = src_b[ci][e * db * 2 + j];
      res   = ref_vnclip(sx(ev, sw), eff, dst);
      rbits = res[31:0];
      for (j = 0; j < db; j++) ex_b[e * db + j] = (e < c_vl[ci]) ? rbits[8*j +: 8] : d_b[ci][e * db + j];
    end
    for (wd = 0; wd < 4; wd++) begin
      w = {ex_b[4*wd+3], ex_b[4*wd+2], ex_b[4*wd+1], ex_b[4*wd]};
      dmem_rd(CB + 32'h30 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d %s %0d->%0d raw=0x%08h shift=%0d vl=%0d: word %0d = 0x%08h, expected 0x%08h",
                                   ci, c_wx[ci] ? "wx" : "wi", sw, dst, c_raw[ci], eff, c_vl[ci], wd, v, w))
    end
  end

  mon_check_all();
endtask
