// TC-030 | REQ-008, REQ-009, REQ-059
// vmv.v.x (splat to vl elements, tail unchanged), vmv.s.x (element 0 only, rest unchanged) and vmv.x.s (element 0
// of vs2 to scalar rd, sign-extended to 32 bits, also negative elements at SEW 8) at SEW 8 and SEW 32, three vl
// values each: 18 cases. The vmv.x.s result is consumed by the very next instruction (addi rd+1 = rd + 1) and
// both values are stored (REQ-009: write-back in the cycle the stall releases).
//   v3 = D (old destination), v1 = S (source of vmv.x.s); x5 = scalar of vmv.v.x / vmv.s.x.
task automatic tc_030_vmv_variants();
  logic [7:0]  d_b [18][16];
  logic [7:0]  s_b [18][16];
  int          c_op [18];
  int          c_sew [18];
  int          c_vl [18];
  logic [31:0] c_x [18];
  logic [31:0] sc_tab [8];
  logic [31:0] CB, r, xs, ev, rb, v, w;
  longint      la;
  logic [7:0]  ex_b [16];
  int          ci, op, sewi, vr, i, j, e, eb, vlmax, wd, sew, ne;

  sc_tab = '{32'h1234_5678, 32'hFFFF_FF85, 32'h8000_0000, 32'h0000_007F, 32'hFFFF_FFFF, 32'h0000_0080,
             32'hDEAD_BEEF, 32'h0000_0001};

  // ---- case table and data
  ci = 0;
  for (sewi = 0; sewi < 2; sewi++) begin
    for (op = 0; op < 3; op++) begin
      for (vr = 0; vr < 3; vr++) begin
        sew   = (sewi == 1) ? 32 : 8;
        vlmax = (sewi == 1) ? 4 : 16;
        c_op[ci]  = op;
        c_sew[ci] = sew;
        c_vl[ci]  = (vr == 0) ? vlmax : ((vr == 1) ? ((sewi == 1) ? 3 : 7) : 1);
        c_x[ci]   = sc_tab[(ci + vr) % 8];
        for (i = 0; i < 16; i++) d_b[ci][i] = 8'h31 + 8'(i * 11) + 8'(ci);
        for (i = 0; i < 16; i++) begin
          r = tb_rand32();
          s_b[ci][i] = r[7:0];
        end
        // element 0 of the source: negative for most cases (sign extension is visible), positive for vr == 2
        if (sew == 8) s_b[ci][0] = (vr == 2) ? 8'h45 : 8'h85;
        else          s_b[ci][3] = (vr == 2) ? 8'h45 : 8'h80;
        ci++;
      end
    end
  end

  // ---- memory image: CB = 0x1000_5000 + c*0x100 : D +0, S +0x10, O3 +0x20
  for (ci = 0; ci < 18; ci++) begin
    CB = 32'h1000_5000 + 32'(ci * 256);
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h00 + 32'(4 * wd), {d_b[ci][4*wd+3], d_b[ci][4*wd+2], d_b[ci][4*wd+1], d_b[ci][4*wd]});
      dmem_wr(CB + 32'h10 + 32'(4 * wd), {s_b[ci][4*wd+3], s_b[ci][4*wd+2], s_b[ci][4*wd+1], s_b[ci][4*wd]});
      dmem_wr(CB + 32'h20 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end
  for (i = 0; i < 40; i++) dmem_wr(TB_RES_BASE + 32'(4 * i), 32'hC0FF_EE11);

  // ---- program
  prog_reset();
  prog_org(0);
  emit_res_init();
  for (ci = 0; ci < 18; ci++) begin
    CB = 32'h1000_5000 + 32'(ci * 256);
    emit_li(5'd12, CB + 32'h00);
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd5, c_x[ci]);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd3, 5'd12));
    emit(rv_vle8(5'd1, 5'd13));
    emit_li(5'd10, 32'(c_vl[ci]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(c_sew[ci])));
    case (c_op[ci])
      0: emit(rv_vmv_v_x(5'd3, 5'd5));
      1: emit(rv_vmv_s_x(5'd3, 5'd5));
      default: begin
        emit(rv_vmv_x_s(5'd6, 5'd1));
        emit(rv_addi(5'd7, 5'd6, 1));                     // consumes the vmv.x.s result immediately
        emit_sw_res(5'd6, 2 * ci);
        emit_sw_res(5'd7, 2 * ci + 1);
      end
    endcase
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd3, 5'd14));
  end
  emit_halt();

  run_prog(200000);
  `TC_CHECK(tb_run_hit, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "o_err_illegal set: legal vmv.* (SEW 8/32) rejected")

  for (ci = 0; ci < 18; ci++) begin
    CB  = 32'h1000_5000 + 32'(ci * 256);
    sew = c_sew[ci];
    eb  = sew / 8;
    xs  = c_x[ci];
    for (i = 0; i < 16; i++) ex_b[i] = d_b[ci][i];
    if (c_op[ci] == 0) begin
      for (e = 0; e < c_vl[ci]; e++)
        for (j = 0; j < eb; j++) ex_b[e * eb + j] = xs[8*j +: 8];
    end else if (c_op[ci] == 1) begin
      for (j = 0; j < eb; j++) ex_b[j] = xs[8*j +: 8];
    end
    for (wd = 0; wd < 4; wd++) begin
      w = {ex_b[4*wd+3], ex_b[4*wd+2], ex_b[4*wd+1], ex_b[4*wd]};
      dmem_rd(CB + 32'h20 + 32'(4 * wd), v);
      `TC_CHECK(v === w, $sformatf("case %0d op %0d e%0d vl=%0d x=0x%08h: dest word %0d = 0x%08h, expected 0x%08h",
                                   ci, c_op[ci], sew, c_vl[ci], xs, wd, v, w))
    end
    if (c_op[ci] == 2) begin
      ev = 32'h0;
      for (j = 0; j < eb; j++) ev[8*j +: 8] = s_b[ci][j];
      la = sx(ev, sew);
      rb = la[31:0];
      res_rd(2 * ci, v);
      `TC_CHECK(v === rb, $sformatf("case %0d vmv.x.s e%0d: rd = 0x%08h, expected sign-extended 0x%08h", ci, sew, v, rb))
      res_rd(2 * ci + 1, v);
      `TC_CHECK(v === rb + 32'd1, $sformatf("case %0d vmv.x.s e%0d: dependent addi = 0x%08h, expected 0x%08h", ci, sew, v, rb + 32'd1))
    end
  end
  mon_check_all();
endtask
