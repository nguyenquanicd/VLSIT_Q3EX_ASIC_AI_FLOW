// TC-033 | REQ-054, REQ-052, REQ-004
// vsetvli / vsetivli with an unsupported vtype (LMUL 2/4/8, fractional LMUL, SEW=64, reserved vsew) is an illegal
// instruction: o_halt=1, o_err_illegal=1, sts.err event, the instruction is not dispatched (only the preceding legal
// vsetvli reaches the VPU), older store completes, younger stores do not execute. One program per case (own reset).
task automatic tc_033_illegal_vsetvli_vtype();
  int          c_vsew [0:31];
  int          c_lmul [0:31];
  bit          c_imm  [0:31];
  logic [10:0] zz;
  logic [31:0] d;
  int          n, c, c0, m0;

  n = 0;
  c_vsew[n] = 0; c_lmul[n] = 1; c_imm[n] = 0; n++;      // e8,  LMUL 2
  c_vsew[n] = 0; c_lmul[n] = 2; c_imm[n] = 0; n++;      // e8,  LMUL 4
  c_vsew[n] = 0; c_lmul[n] = 3; c_imm[n] = 0; n++;      // e8,  LMUL 8
  c_vsew[n] = 0; c_lmul[n] = 5; c_imm[n] = 0; n++;      // e8,  LMUL 1/8
  c_vsew[n] = 0; c_lmul[n] = 6; c_imm[n] = 0; n++;      // e8,  LMUL 1/4
  c_vsew[n] = 0; c_lmul[n] = 7; c_imm[n] = 0; n++;      // e8,  LMUL 1/2
  c_vsew[n] = 1; c_lmul[n] = 1; c_imm[n] = 0; n++;      // e16, LMUL 2
  c_vsew[n] = 2; c_lmul[n] = 1; c_imm[n] = 0; n++;      // e32, LMUL 2
  c_vsew[n] = 2; c_lmul[n] = 2; c_imm[n] = 0; n++;      // e32, LMUL 4
  c_vsew[n] = 3; c_lmul[n] = 0; c_imm[n] = 0; n++;      // SEW = 64
  c_vsew[n] = 4; c_lmul[n] = 0; c_imm[n] = 0; n++;      // reserved vsew 4
  c_vsew[n] = 5; c_lmul[n] = 0; c_imm[n] = 0; n++;      // reserved vsew 5
  c_vsew[n] = 7; c_lmul[n] = 7; c_imm[n] = 0; n++;      // reserved vsew 7, LMUL 1/2
  c_vsew[n] = 0; c_lmul[n] = 1; c_imm[n] = 1; n++;      // vsetivli e8,  LMUL 2
  c_vsew[n] = 3; c_lmul[n] = 0; c_imm[n] = 1; n++;      // vsetivli SEW = 64
  c_vsew[n] = 2; c_lmul[n] = 3; c_imm[n] = 1; n++;      // vsetivli e32, LMUL 8
  c_vsew[n] = 1; c_lmul[n] = 5; c_imm[n] = 1; n++;      // vsetivli e16, LMUL 1/8

  for (c = 0; c < n; c++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd10, 4);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));       // legal: vl = 4
    emit_sw_res(5'd11, 0);                               // older store
    repeat (4) emit(rv_nop());
    zz = {5'b00000, c_vsew[c][2:0], c_lmul[c][2:0]};
    if (c_imm[c]) emit(rv_vsetivli(5'd12, 5'd4, zz[9:0]));
    else          emit(rv_vsetvli(5'd12, 5'd10, zz));
    emit_li(5'd2, 32'hBBBB);
    emit_sw_res(5'd2, 1);                                // younger stores: must not execute
    emit_sw_res(5'd2, 2);
    emit_halt();

    dmem_fill(TB_RES_BASE, 8, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    m0 = tb_vmem_xfer_cnt;
    run_prog(3000);

    // live state first (a host access resets the DUT)
    `TC_CHECK(tb_run_hit, $sformatf("case %0d (vsew %0d lmul %0d %s): core did not halt", c, c_vsew[c], c_lmul[c], c_imm[c] ? "vsetivli" : "vsetvli"))
    `TC_CHECK(o_halt === 1'b1, $sformatf("case %0d: o_halt not 1", c))
    `TC_CHECK(o_err_illegal === 1'b1, $sformatf("case %0d (vsew %0d lmul %0d): o_err_illegal not 1 (unsupported vtype accepted)", c, c_vsew[c], c_lmul[c]))
    `TC_CHECK(tb_sts_err_events >= 1, $sformatf("case %0d: sts.err not set", c))
    chk_halted_stable(4);
    `TC_CHECK(tb_vcmd_cnt - c0 == 1, $sformatf("case %0d: %0d commands dispatched, expected 1 (only the legal vsetvli)", c, tb_vcmd_cnt - c0))
    `TC_CHECK(tb_vmem_xfer_cnt - m0 == 0, $sformatf("case %0d: VPU memory access seen", c))
    res_rd(0, d); `TC_CHECK(d === 32'd4, $sformatf("case %0d: older vsetvli result = %08h, expected 4", c, d))
    res_rd(1, d); `TC_CHECK(d === 32'hC0FF_EE11, $sformatf("case %0d: younger store 1 executed (%08h)", c, d))
    res_rd(2, d); `TC_CHECK(d === 32'hC0FF_EE11, $sformatf("case %0d: younger store 2 executed (%08h)", c, d))
  end
  mon_check_all();
endtask
