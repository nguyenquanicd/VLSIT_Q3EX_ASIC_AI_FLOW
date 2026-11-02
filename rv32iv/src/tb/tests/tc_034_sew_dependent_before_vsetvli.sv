// TC-034 | REQ-083, REQ-054, REQ-052
// A SEW-dependent vector instruction is illegal until a legal vsetvli/vsetivli has been accepted (the shadow SEW is
// invalid after reset); vle/vse are not checked against vtype.
//   A: 12 SEW-dependent instructions as the FIRST vector instruction after reset  -> illegal, not dispatched
//   B: vle8 / vse8 / vle32 / vse32 before any vsetvli                              -> legal, dispatched, no halt error
//   C: legal vsetvli first, then vadd.vv / vsra.vx at e8 and e32                   -> legal
//   D: reset invalidates the shadow SEW: the same vadd.vv alone in a fresh run     -> illegal again
// One program per case (own reset; the TB reset is the DUT reset).
task automatic tc_034_sew_dependent_before_vsetvli();
  logic [31:0] c_ins [0:31];
  string       nm    [0:31];
  logic [31:0] d;
  int          n, c, c0, m0, v;

  n = 0;
  c_ins[n] = rv_vadd_vv(3, 1, 2);     nm[n] = "vadd.vv";     n++;
  c_ins[n] = rv_vadd_vx(3, 1, 12);    nm[n] = "vadd.vx";     n++;
  c_ins[n] = rv_vsra_vi(3, 1, 2);     nm[n] = "vsra.vi";     n++;
  c_ins[n] = rv_vsra_vx(3, 1, 13);    nm[n] = "vsra.vx";     n++;
  c_ins[n] = rv_vmax_vx(3, 1, 12);    nm[n] = "vmax.vx";     n++;
  c_ins[n] = rv_vmv_v_x(3, 12);       nm[n] = "vmv.v.x";     n++;
  c_ins[n] = rv_vmv_s_x(3, 12);       nm[n] = "vmv.s.x";     n++;
  c_ins[n] = rv_vmv_x_s(5, 1);        nm[n] = "vmv.x.s";     n++;
  c_ins[n] = rv_vnclip_wi(3, 2, 3);   nm[n] = "vnclip.wi";   n++;
  c_ins[n] = rv_vnclip_wx(3, 2, 13);  nm[n] = "vnclip.wx";   n++;
  c_ins[n] = rv_vwmul_vv(4, 1, 2);    nm[n] = "vwmul.vv";    n++;
  c_ins[n] = rv_vwredsum_vs(8, 4, 3); nm[n] = "vwredsum.vs"; n++;

  // ---------------- A: illegal before any vsetvli
  for (c = 0; c < n; c++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd30, TB_DATA_BASE);
    emit_li(5'd12, 3);
    emit_li(5'd13, 3);
    emit_li(5'd14, 32'hAAAA);
    emit_sw_res(5'd14, 0);                              // older store
    repeat (4) emit(rv_nop());
    emit(c_ins[c]);                                     // first vector instruction after reset
    emit_li(5'd2, 32'hBBBB);
    emit_sw_res(5'd2, 1);                               // younger: must not execute
    emit_halt();
    dmem_fill(TB_RES_BASE, 4, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    run_prog(3000);
    `TC_CHECK(tb_run_hit, $sformatf("A [%s]: core did not halt", nm[c]))
    `TC_CHECK(o_halt === 1'b1, $sformatf("A [%s]: o_halt not 1", nm[c]))
    `TC_CHECK(o_err_illegal === 1'b1, $sformatf("A [%s]: o_err_illegal not 1 (accepted before any vsetvli)", nm[c]))
    `TC_CHECK(tb_sts_err_events >= 1, $sformatf("A [%s]: sts.err not set", nm[c]))
    `TC_CHECK(tb_vcmd_cnt - c0 == 0, $sformatf("A [%s]: command reached the VPU", nm[c]))
    res_rd(0, d); `TC_CHECK(d === 32'hAAAA, $sformatf("A [%s]: older store missing (%08h)", nm[c], d))
    res_rd(1, d); `TC_CHECK(d === 32'hC0FF_EE11, $sformatf("A [%s]: younger store executed (%08h)", nm[c], d))
  end

  // ---------------- B: vle/vse are not checked against vtype
  for (v = 0; v < 4; v++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd30, TB_DATA_BASE);
    emit_li(5'd29, TB_DATA_BASE + 32'h40);
    repeat (4) emit(rv_nop());
    case (v)
      0: emit(rv_vle8 (5'd1, 5'd30));
      1: emit(rv_vse8 (5'd1, 5'd29));
      2: emit(rv_vle32(5'd1, 5'd30));
      default: emit(rv_vse32(5'd1, 5'd29));
    endcase
    emit_li(5'd2, 32'hBBBB);
    emit_sw_res(5'd2, 1);                               // younger store must execute
    emit_halt();
    dmem_fill(TB_DATA_BASE, 4, 32'h0102_0304);
    dmem_fill(TB_RES_BASE, 4, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    m0 = tb_vmem_xfer_cnt;
    run_prog(3000);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("B%0d: program did not reach ebreak", v))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("B%0d: vle/vse before vsetvli wrongly rejected", v))
    `TC_CHECK(tb_vcmd_cnt - c0 == 1, $sformatf("B%0d: %0d commands dispatched, expected 1", v, tb_vcmd_cnt - c0))
    `TC_CHECK(tb_vmem_xfer_cnt - m0 >= 1, $sformatf("B%0d: no VPU memory access", v))
    res_rd(1, d); `TC_CHECK(d === 32'hBBBB, $sformatf("B%0d: younger store missing (%08h)", v, d))
  end

  // ---------------- C: after a legal vsetvli the same instructions are legal
  for (v = 0; v < 4; v++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd12, 3);
    emit_li(5'd13, 3);
    emit_li(5'd10, 4);
    repeat (4) emit(rv_nop());
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm((v < 2) ? 8 : 32)));
    if ((v % 2) == 0) emit(rv_vadd_vv(5'd3, 5'd1, 5'd2));
    else              emit(rv_vsra_vx(5'd3, 5'd1, 5'd13));
    emit_li(5'd2, 32'hBBBB);
    emit_sw_res(5'd2, 1);
    emit_halt();
    dmem_fill(TB_RES_BASE, 4, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    run_prog(3000);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("C%0d: program did not reach ebreak", v))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("C%0d: SEW-dependent instruction rejected after a legal vsetvli", v))
    `TC_CHECK(tb_vcmd_cnt - c0 == 2, $sformatf("C%0d: %0d commands dispatched, expected 2", v, tb_vcmd_cnt - c0))
    res_rd(1, d); `TC_CHECK(d === 32'hBBBB, $sformatf("C%0d: younger store missing (%08h)", v, d))
  end

  // ---------------- D: reset invalidates the shadow SEW again (run C0 left it valid, the next run starts with a reset)
  prog_reset();
  emit_res_init();
  emit_li(5'd10, 4);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  emit(rv_vadd_vv(5'd3, 5'd1, 5'd2));
  emit_halt();
  run_prog(3000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1 && o_err_illegal === 1'b0, "D1: legal sequence must run")
  prog_reset();
  emit_res_init();
  emit(rv_vadd_vv(5'd3, 5'd1, 5'd2));                   // no vsetvli in this run: shadow SEW must be invalid again
  emit_halt();
  c0 = tb_vcmd_cnt;
  run_prog(3000);
  `TC_CHECK(tb_run_hit, "D2: core did not halt")
  `TC_CHECK(o_err_illegal === 1'b1, "D2: vadd.vv accepted after a reset (shadow SEW not invalidated by reset)")
  `TC_CHECK(tb_vcmd_cnt - c0 == 0, "D2: command reached the VPU")
  mon_check_all();
endtask
