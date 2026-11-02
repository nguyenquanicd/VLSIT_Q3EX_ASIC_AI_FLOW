// TC-027 | REQ-007, REQ-062, REQ-059
// vwredsum.vs vd=v7, vs2=v4 (pair v4/v5 of INT16 elements), vs1=v6 at SEW=8:
//   v7[0] (32-bit) = v6[0] + sum(int16 element i of v4/v5, i < vl). Value-only check: latency is not checked
//   (beyond the 5-cycle minimum enforced by mon_check_all).
// Part A (9 cases): the pair is loaded with raw INT16 data (vle8 of little-endian halfwords incl. -32768/32767),
//   vl = 1,2,5,8,9,15,16 plus two all-extreme rows. Checks word 0 of v7, bytes 4..15 of v7 unchanged
//   (tail undisturbed), v6 unchanged.
// Part B (3 scenarios): 49 iterations (784 elements) of { vle8 A; vle8 B; vwmul.vv v4,v1,v2; vwredsum.vs v3,v4,v3 }
//   accumulating in v3[0] (as the MNIST layer-1 loop): random INT8, all (-128)*(-128) (max positive sum 12,845,056)
//   and all (-128)*127 (max negative sum -12,744,704), each with a non-zero initial scalar. No overflow.
task automatic tc_027_vwredsum_vs();
  logic [15:0] el [9][16];
  int          vl_c [9];
  logic [31:0] init_c [9];
  logic [7:0]  s_b [9][16];
  logic [7:0]  d_b [16];
  logic [15:0] edge16 [7];
  logic [31:0] CB, r, v, w, expw;
  logic [7:0]  a_b [3][784];
  logic [7:0]  b_b [3][784];
  logic [31:0] initb [3];
  logic [7:0]  pat_b [16];
  longint      sum;
  int          c, i, wd, s, loop_here;

  vl_c   = '{1, 2, 5, 8, 9, 15, 16, 16, 16};
  init_c = '{32'h0000_0000, 32'h0000_03E8, 32'hFFFF_FF38, 32'h1234_5678, 32'h0000_0001, 32'hFFFF_0000,
             32'h0001_0000, 32'h0000_04D2, 32'h0000_162E};
  edge16 = '{16'h8000, 16'h7FFF, 16'h0000, 16'h0001, 16'hFFFF, 16'h00FF, 16'hFF00};
  for (i = 0; i < 16; i++) d_b[i] = 8'h90 + 8'(i * 7);

  for (c = 0; c < 9; c++) begin
    for (i = 0; i < 16; i++) begin
      if (c == 7)      el[c][i] = 16'h7FFF;      // all max positive
      else if (c == 8) el[c][i] = 16'h8000;      // all max negative
      else begin
        r = tb_rand32();
        el[c][i] = r[0] ? edge16[(r[15:8] % 7)] : r[31:16];
      end
    end
    // init scalar row: word0 = init, words 1..3 pattern
    s_b[c][0] = init_c[c][7:0];
    s_b[c][1] = init_c[c][15:8];
    s_b[c][2] = init_c[c][23:16];
    s_b[c][3] = init_c[c][31:24];
    for (i = 4; i < 16; i++) s_b[c][i] = 8'h11 * 8'(i - 3);
  end

  // ================= Part A =================
  // per case CB = 0x1000_5000 + c*0x100: P4 +0, P5 +0x10, S +0x20, D +0x30, O7 +0x40, O6 +0x50
  for (c = 0; c < 9; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    for (wd = 0; wd < 8; wd++) begin   // 16 halfwords = 8 words over P4/P5
      w = {el[c][2*wd+1], el[c][2*wd]};
      dmem_wr(CB + 32'(4 * wd), w);       // words 0..3 = P4 row, words 4..7 = P5 row (CB + 0x10)
    end
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h20 + 32'(4 * wd), {s_b[c][4*wd+3], s_b[c][4*wd+2], s_b[c][4*wd+1], s_b[c][4*wd]});
      dmem_wr(CB + 32'h30 + 32'(4 * wd), {d_b[4*wd+3], d_b[4*wd+2], d_b[4*wd+1], d_b[4*wd]});
      dmem_wr(CB + 32'h40 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h50 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  prog_reset();
  prog_org(0);
  for (c = 0; c < 9; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    emit_li(5'd12, CB + 32'h00);   // P4 (P5 = P4 + 0x10 is the next row of the same 32-byte block)
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd15, CB + 32'h30);
    emit_li(5'd16, CB + 32'h40);
    emit_li(5'd17, CB + 32'h50);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd4, 5'd12));
    emit(rv_vle8(5'd5, 5'd13));
    emit(rv_vle8(5'd6, 5'd14));
    emit(rv_vle8(5'd7, 5'd15));
    emit_li(5'd10, 32'(vl_c[c]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vwredsum_vs(5'd7, 5'd4, 5'd6));
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd7, 5'd16));
    emit(rv_vse8(5'd6, 5'd17));
  end
  emit_halt();

  run_prog(100000);

  `TC_CHECK(tb_run_hit, "part A: program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "part A: o_err_illegal set: legal vwredsum.vs rejected")

  for (c = 0; c < 9; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    sum = 0;
    for (i = 0; i < vl_c[c]; i++) sum = sum + sx({16'h0, el[c][i]}, 16);
    expw = init_c[c] + 32'(sum);
    dmem_rd(CB + 32'h40, v);
    `TC_CHECK(v === expw, $sformatf("A case %0d vl=%0d: vd[0] = 0x%08h, expected 0x%08h (init 0x%08h + sum %0d)",
                                    c, vl_c[c], v, expw, init_c[c], sum))
    for (wd = 1; wd < 4; wd++) begin
      w = {d_b[4*wd+3], d_b[4*wd+2], d_b[4*wd+1], d_b[4*wd]};
      dmem_rd(CB + 32'h40 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("A case %0d: vd word %0d = 0x%08h, expected unchanged 0x%08h (tail)", c, wd, v, w))
    end
    for (wd = 0; wd < 4; wd++) begin
      w = {s_b[c][4*wd+3], s_b[c][4*wd+2], s_b[c][4*wd+1], s_b[c][4*wd]};
      dmem_rd(CB + 32'h50 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("A case %0d: source vs1 changed: word %0d = 0x%08h", c, wd, v))
    end
  end

  // ================= Part B: 784-element accumulation =================
  initb = '{32'h0000_03E8, 32'h0000_0000, 32'hFFFF_EC78};   // 1000, 0, -5000
  for (s = 0; s < 3; s++) begin
    for (i = 0; i < 784; i++) begin
      if (s == 0) begin
        r = tb_rand32();
        a_b[s][i] = r[7:0];
        b_b[s][i] = r[15:8];
      end else if (s == 1) begin
        a_b[s][i] = 8'h80;
        b_b[s][i] = 8'h80;
      end else begin
        a_b[s][i] = 8'h80;
        b_b[s][i] = 8'h7F;
      end
    end
  end
  // memory: A rows at 0x1001_0000 + s*0x2000, B rows at +0x1000; init row at 0x1000_6000 + s*0x20;
  // outputs at 0x1000_6100 + s*0x10
  for (s = 0; s < 3; s++) begin
    for (i = 0; i < 196; i++) begin
      dmem_wr(32'h1001_0000 + 32'(s * 8192) + 32'(4 * i),
              {a_b[s][4*i+3], a_b[s][4*i+2], a_b[s][4*i+1], a_b[s][4*i]});
      dmem_wr(32'h1001_1000 + 32'(s * 8192) + 32'(4 * i),
              {b_b[s][4*i+3], b_b[s][4*i+2], b_b[s][4*i+1], b_b[s][4*i]});
    end
    for (i = 0; i < 16; i++) pat_b[i] = (i < 4) ? initb[s][8*i +: 8] : (8'hA0 + 8'(i));
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(32'h1000_6000 + 32'(s * 32) + 32'(4 * wd), {pat_b[4*wd+3], pat_b[4*wd+2], pat_b[4*wd+1], pat_b[4*wd]});
      dmem_wr(32'h1000_6100 + 32'(s * 16) + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  prog_reset();
  prog_org(0);
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  for (s = 0; s < 3; s++) begin
    emit_li(5'd12, 32'h1001_0000 + 32'(s * 8192));
    emit_li(5'd13, 32'h1001_1000 + 32'(s * 8192));
    emit_li(5'd14, 32'd49);
    emit_li(5'd15, 32'h1000_6000 + 32'(s * 32));
    emit_li(5'd16, 32'h1000_6100 + 32'(s * 16));
    emit(rv_vle8(5'd3, 5'd15));                  // v3 = init scalar (element 0) + pattern
    loop_here = prog_here();
    emit(rv_vle8(5'd1, 5'd12));
    emit(rv_vle8(5'd2, 5'd13));
    emit(rv_vwmul_vv(5'd4, 5'd1, 5'd2));
    emit(rv_vwredsum_vs(5'd3, 5'd4, 5'd3));      // v3[0] += sum of 16 products
    emit(rv_addi(5'd12, 5'd12, 16));
    emit(rv_addi(5'd13, 5'd13, 16));
    emit(rv_addi(5'd14, 5'd14, -1));
    emit(rv_bne(5'd14, 5'd0, loop_here - prog_here()));
    emit(rv_vse8(5'd3, 5'd16));
  end
  emit_halt();

  run_prog(600000);

  `TC_CHECK(tb_run_hit, "part B: program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "part B: o_err_illegal set")

  for (s = 0; s < 3; s++) begin
    sum = 0;
    for (i = 0; i < 784; i++) sum = sum + sx({24'h0, a_b[s][i]}, 8) * sx({24'h0, b_b[s][i]}, 8);
    expw = initb[s] + 32'(sum);
    dmem_rd(32'h1000_6100 + 32'(s * 16), v);
    `TC_CHECK(v === expw, $sformatf("B scenario %0d: accumulated value 0x%08h, expected 0x%08h (init 0x%08h + sum %0d)",
                                    s, v, expw, initb[s], sum))
    for (i = 0; i < 16; i++) pat_b[i] = (i < 4) ? initb[s][8*i +: 8] : (8'hA0 + 8'(i));
    for (wd = 1; wd < 4; wd++) begin
      w = {pat_b[4*wd+3], pat_b[4*wd+2], pat_b[4*wd+1], pat_b[4*wd]};
      dmem_rd(32'h1000_6100 + 32'(s * 16) + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("B scenario %0d: vd word %0d = 0x%08h, expected unchanged 0x%08h", s, wd, v, w))
    end
  end

  mon_check_all();
endtask
