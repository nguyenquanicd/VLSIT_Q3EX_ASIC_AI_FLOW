// TC-035 | REQ-074, REQ-052
// Per case (own reset): legal vsetvli with the case SEW (AVL=4, vl=4 for every SEW), then ONE vector instruction.
// Illegal cases (halt, o_err_illegal=1, sts.err, only the vsetvli dispatched, younger stores absent):
//   vwmul.vv / vwredsum.vs at SEW 16 and 32; vadd/vsra/vmax/vmv at SEW 16; vnclip to SEW 32;
//   widening vwmul with an odd vd (1, 5, 31) at SEW 8.
// Legal cases (no halt, both commands dispatched, younger stores execute):
//   SEW 8: vwmul (vd 4, 30), vwredsum, vadd, vsra, vmax, vmv.*, vnclip 16->8
//   SEW 16: vnclip 32->16        SEW 32: vadd, vsra, vmax, vmv.*
// An odd vs2 of a wide source is not alignment-checked and is not used here.
task automatic tc_035_illegal_sew_combinations_and_vd_alignment();
  int          c_sew [0:63];
  logic [31:0] c_ins [0:63];
  bit          c_ill [0:63];
  string       nm    [0:63];
  logic [31:0] rdv, A, OUT;
  int          n, c, c0, m0;

  A   = TB_DATA_BASE;
  OUT = TB_DATA_BASE + 32'h100;
  n   = 0;

  // ---------------- illegal combinations ----------------
  c_sew[n] = 16; c_ins[n] = rv_vwmul_vv(4, 1, 2);     c_ill[n] = 1; nm[n] = "vwmul.vv e16";      n++;
  c_sew[n] = 32; c_ins[n] = rv_vwmul_vv(4, 1, 2);     c_ill[n] = 1; nm[n] = "vwmul.vv e32";      n++;
  c_sew[n] = 16; c_ins[n] = rv_vwredsum_vs(8, 4, 3);  c_ill[n] = 1; nm[n] = "vwredsum.vs e16";   n++;
  c_sew[n] = 32; c_ins[n] = rv_vwredsum_vs(8, 4, 3);  c_ill[n] = 1; nm[n] = "vwredsum.vs e32";   n++;
  c_sew[n] = 16; c_ins[n] = rv_vadd_vv(3, 1, 2);      c_ill[n] = 1; nm[n] = "vadd.vv e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vadd_vx(3, 1, 12);     c_ill[n] = 1; nm[n] = "vadd.vx e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vsra_vi(3, 1, 2);      c_ill[n] = 1; nm[n] = "vsra.vi e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vsra_vx(3, 1, 13);     c_ill[n] = 1; nm[n] = "vsra.vx e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vmax_vx(3, 1, 12);     c_ill[n] = 1; nm[n] = "vmax.vx e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vmv_v_x(3, 12);        c_ill[n] = 1; nm[n] = "vmv.v.x e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vmv_s_x(3, 12);        c_ill[n] = 1; nm[n] = "vmv.s.x e16";       n++;
  c_sew[n] = 16; c_ins[n] = rv_vmv_x_s(5, 1);         c_ill[n] = 1; nm[n] = "vmv.x.s e16";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vnclip_wi(3, 2, 3);    c_ill[n] = 1; nm[n] = "vnclip.wi e32";     n++;
  c_sew[n] = 32; c_ins[n] = rv_vnclip_wx(3, 2, 13);   c_ill[n] = 1; nm[n] = "vnclip.wx e32";     n++;
  c_sew[n] = 8;  c_ins[n] = rv_vwmul_vv(1, 2, 4);     c_ill[n] = 1; nm[n] = "vwmul.vv e8 vd=1";  n++;
  c_sew[n] = 8;  c_ins[n] = rv_vwmul_vv(5, 2, 4);     c_ill[n] = 1; nm[n] = "vwmul.vv e8 vd=5";  n++;
  c_sew[n] = 8;  c_ins[n] = rv_vwmul_vv(31, 2, 4);    c_ill[n] = 1; nm[n] = "vwmul.vv e8 vd=31"; n++;

  // ---------------- legal combinations ----------------
  c_sew[n] = 8;  c_ins[n] = rv_vwmul_vv(4, 1, 2);     c_ill[n] = 0; nm[n] = "vwmul.vv e8 vd=4";  n++;
  c_sew[n] = 8;  c_ins[n] = rv_vwmul_vv(30, 1, 2);    c_ill[n] = 0; nm[n] = "vwmul.vv e8 vd=30"; n++;
  c_sew[n] = 8;  c_ins[n] = rv_vwredsum_vs(8, 4, 3);  c_ill[n] = 0; nm[n] = "vwredsum.vs e8";    n++;
  c_sew[n] = 8;  c_ins[n] = rv_vadd_vv(3, 1, 2);      c_ill[n] = 0; nm[n] = "vadd.vv e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vadd_vx(3, 1, 12);     c_ill[n] = 0; nm[n] = "vadd.vx e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vsra_vi(3, 1, 2);      c_ill[n] = 0; nm[n] = "vsra.vi e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vsra_vx(3, 1, 13);     c_ill[n] = 0; nm[n] = "vsra.vx e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vmax_vx(3, 1, 12);     c_ill[n] = 0; nm[n] = "vmax.vx e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vmv_v_x(3, 12);        c_ill[n] = 0; nm[n] = "vmv.v.x e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vmv_s_x(3, 12);        c_ill[n] = 0; nm[n] = "vmv.s.x e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vmv_x_s(5, 1);         c_ill[n] = 0; nm[n] = "vmv.x.s e8";        n++;
  c_sew[n] = 8;  c_ins[n] = rv_vnclip_wi(3, 2, 3);    c_ill[n] = 0; nm[n] = "vnclip.wi e8 (16->8)";  n++;
  c_sew[n] = 8;  c_ins[n] = rv_vnclip_wx(3, 2, 13);   c_ill[n] = 0; nm[n] = "vnclip.wx e8 (16->8)";  n++;
  c_sew[n] = 16; c_ins[n] = rv_vnclip_wi(3, 2, 3);    c_ill[n] = 0; nm[n] = "vnclip.wi e16 (32->16)"; n++;
  c_sew[n] = 16; c_ins[n] = rv_vnclip_wx(3, 2, 13);   c_ill[n] = 0; nm[n] = "vnclip.wx e16 (32->16)"; n++;
  c_sew[n] = 32; c_ins[n] = rv_vadd_vv(3, 1, 2);      c_ill[n] = 0; nm[n] = "vadd.vv e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vadd_vx(3, 1, 12);     c_ill[n] = 0; nm[n] = "vadd.vx e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vsra_vi(3, 1, 2);      c_ill[n] = 0; nm[n] = "vsra.vi e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vsra_vx(3, 1, 13);     c_ill[n] = 0; nm[n] = "vsra.vx e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vmax_vx(3, 1, 12);     c_ill[n] = 0; nm[n] = "vmax.vx e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vmv_v_x(3, 12);        c_ill[n] = 0; nm[n] = "vmv.v.x e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vmv_s_x(3, 12);        c_ill[n] = 0; nm[n] = "vmv.s.x e32";       n++;
  c_sew[n] = 32; c_ins[n] = rv_vmv_x_s(5, 1);         c_ill[n] = 0; nm[n] = "vmv.x.s e32";       n++;

  for (c = 0; c < n; c++) begin
    prog_reset();
    emit_res_init();
    emit_li(10, 4);                                     // AVL 4 -> vl = 4 at every SEW
    emit_li(12, A);
    emit_li(13, 32'd3);
    emit_li(14, OUT);
    emit(rv_vsetvli(11, 10, vtype_zimm(c_sew[c])));     // legal vsetvli
    emit_sw_res(11, 0);                                 // older instruction: vl
    emit(c_ins[c]);                                     // instruction under test
    emit_sw_res(10, 1);                                 // younger stores
    emit_sw_res(10, 2);
    emit_halt();

    dmem_fill(TB_RES_BASE, 8, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    m0 = tb_vmem_xfer_cnt;
    run_prog(3000);                                     // includes the post-halt drain

    // All checks on the live DUT state (o_halt, o_err_illegal, sts.err events, halted-stable, command counts) come
    // BEFORE the first res_rd(): the host access puts the DUT in reset and clears them.
    if (c_ill[c]) begin
      // TC-035 | REQ-074, REQ-052 : illegal combination / odd widening vd
      `TC_CHECK(tb_run_hit, $sformatf("[%s] core did not halt", nm[c]))
      `TC_CHECK(o_halt === 1'b1, $sformatf("[%s] o_halt not 1 (illegal combination accepted)", nm[c]))
      `TC_CHECK(o_err_illegal === 1'b1, $sformatf("[%s] o_err_illegal not 1", nm[c]))
      `TC_CHECK(tb_sts_err_events >= 1, $sformatf("[%s] sts.err not set", nm[c]))
      `TC_CHECK(tb_vcmd_cnt - c0 == 1,
                $sformatf("[%s] %0d commands dispatched, expected 1 (only the vsetvli)", nm[c], tb_vcmd_cnt - c0))
      `TC_CHECK(tb_vmem_xfer_cnt - m0 == 0, $sformatf("[%s] VPU memory access seen", nm[c]))
      chk_halted_stable(4);
      res_rd(0, rdv);
      `TC_CHECK(rdv === 32'd4, $sformatf("[%s] vsetvli returned 0x%08h, expected 4", nm[c], rdv))
      res_rd(1, rdv); `TC_CHECK(rdv === 32'hC0FF_EE11, $sformatf("[%s] younger store 1 executed (0x%08h)", nm[c], rdv))
      res_rd(2, rdv); `TC_CHECK(rdv === 32'hC0FF_EE11, $sformatf("[%s] younger store 2 executed (0x%08h)", nm[c], rdv))
    end else begin
      // TC-035 | REQ-074 : legal combination executes
      `TC_CHECK(tb_run_hit, $sformatf("[%s] program did not reach ebreak (hang?)", nm[c]))
      `TC_CHECK(o_halt === 1'b1, $sformatf("[%s] program must end in its ebreak halt", nm[c]))
      `TC_CHECK(o_err_illegal === 1'b0, $sformatf("[%s] legal combination rejected (o_err_illegal)", nm[c]))
      `TC_CHECK(tb_sts_err_events == 0, $sformatf("[%s] legal combination set sts.err", nm[c]))
      `TC_CHECK(tb_vcmd_cnt - c0 == 2,
                $sformatf("[%s] %0d commands dispatched, expected 2", nm[c], tb_vcmd_cnt - c0))
      res_rd(0, rdv);
      `TC_CHECK(rdv === 32'd4, $sformatf("[%s] vsetvli returned 0x%08h, expected 4", nm[c], rdv))
      res_rd(1, rdv); `TC_CHECK(rdv === 32'd4, $sformatf("[%s] younger store 1 = 0x%08h, expected 4", nm[c], rdv))
      res_rd(2, rdv); `TC_CHECK(rdv === 32'd4, $sformatf("[%s] younger store 2 = 0x%08h, expected 4", nm[c], rdv))
    end
  end
  mon_check_all();
endtask
