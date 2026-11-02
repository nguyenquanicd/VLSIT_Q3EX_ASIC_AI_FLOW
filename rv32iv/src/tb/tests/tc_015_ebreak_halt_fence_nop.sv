// TC-015 | REQ-073, REQ-053
// v0: ebreak halts (o_halt=1, o_err_illegal=0, no sts.err), PC stops and the pipeline is drained,
//     older instructions complete, younger ones have no effect.
// v1: ebreak right behind a pending MMIO store: the store completes (o_result_label), a younger MMIO store
//     after the ebreak never executes.
// v2/v3: fence executes as a NOP: same results and same time-to-halt as a program with nop instead of fence.
// run_prog() drains the halted core (older stores reach DMEM / the CSR) before returning; chk_halted_stable()
// drains again internally and is strict afterwards (request stays low, PC fixed).
task automatic tc_015_ebreak_halt_fence_nop();
  int          v, i;
  logic [31:0] r0, r1, r2, r3, r5;
  longint unsigned t_fence, t_nop;
  logic [31:0] x;

  // ---------------- v0: plain ebreak
  for (i = 0; i < 8; i++) dmem_wr(TB_RES_BASE + 4 * i, 32'h0);
  prog_reset();
  emit_res_init();
  emit_li(1, 32'h1111);
  emit_sw_res(1, 0);
  emit_li(2, 32'h2222);
  emit_sw_res(2, 1);                  // directly before the ebreak
  emit_halt();
  emit_li(3, 32'h3333);
  emit_sw_res(3, 5);                  // younger than the ebreak: must not execute
  emit_halt();
  run_prog(3000);
  // TC-015 | REQ-053
  `TC_CHECK(tb_run_hit, "ebreak program did not halt")
  `TC_CHECK(o_halt === 1'b1, "o_halt not 1 after ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "ebreak raised o_err_illegal")
  chk_halted_stable(16);             // PC stopped, o_halt stays 1, no data requests
  snap_status();
  res_rd(0, r0);
  res_rd(1, r1);
  res_rd(5, r5);
  // TC-015 | REQ-073
  `TC_CHECK(snap_sts_err_events == 0, "ebreak set sts.err")
  `TC_CHECK(r0 === 32'h1111, $sformatf("older store (slot0) missing: %08h", r0))
  `TC_CHECK(r1 === 32'h2222, $sformatf("store directly before ebreak (slot1) missing: %08h", r1))
  `TC_CHECK(r5 === 32'h0, $sformatf("store after ebreak was executed: %08h", r5))
  `TC_CHECK(tb_post_halt_dmem_cnt == 0 && tb_post_halt_pc_cnt == 0, "CPU activity after halt (data request or PC change)")

  // ---------------- v1: ebreak behind an MMIO store
  prog_reset();
  emit_li(4, CSR_RESULT);
  emit_li(5, 32'h7);
  emit(rv_sw(5, 4, 0));               // older MMIO store: result.label = 7
  emit_halt();
  emit_li(6, 32'h9);
  emit(rv_sw(6, 4, 0));               // younger: must never reach the CSR
  emit_halt();
  run_prog(3000);
  // TC-015 | REQ-053
  `TC_CHECK(tb_run_hit, "ebreak-after-MMIO program did not halt")
  `TC_CHECK(o_err_illegal === 1'b0, "ebreak after MMIO store raised o_err_illegal")
  chk_halted_stable(16);
  // TC-015 | REQ-073
  `TC_CHECK(o_result_label === 4'd7, $sformatf("older MMIO store must complete, younger must not: o_result_label=%0d", o_result_label))

  // ---------------- v2/v3: fence vs nop
  for (v = 2; v < 4; v++) begin
    for (i = 0; i < 8; i++) dmem_wr(TB_RES_BASE + 4 * i, 32'h0);
    prog_reset();
    emit_res_init();
    emit(rv_addi(1, 0, 5));
    x = (v == 2) ? rv_fence() : rv_nop();
    emit(x);
    emit(rv_addi(2, 1, 1));           // depends on x1 across the fence/nop
    emit_sw_res(2, 0);
    emit(x);
    emit(x);
    emit_sw_res(1, 1);
    emit_li(6, 32'hABCD);
    emit_sw_res(6, 2);
    emit(x);
    emit(rv_lw(7, 31, 8));            // read slot2 back after the fence/nop
    emit_sw_res(7, 3);
    emit_halt();
    run_prog(3000);
    if (v == 2) t_fence = tb_run_cycles; else t_nop = tb_run_cycles;   // taken at the first o_halt cycle
    snap_status();
    res_rd(0, r0);
    res_rd(1, r1);
    res_rd(2, r2);
    res_rd(3, r3);
    // TC-015 | REQ-073
    `TC_CHECK(tb_run_hit, $sformatf("variant %0d (fence/nop) did not halt", v))
    `TC_CHECK(snap_err_illegal === 1'b0, $sformatf("variant %0d: fence raised o_err_illegal", v))
    `TC_CHECK(snap_sts_err_events == 0, $sformatf("variant %0d: fence set sts.err", v))
    `TC_CHECK(r0 === 32'd6, $sformatf("variant %0d: dependent addi across fence = %08h (want 6)", v, r0))
    `TC_CHECK(r1 === 32'd5, $sformatf("variant %0d: x1 corrupted = %08h", v, r1))
    `TC_CHECK(r3 === 32'hABCD, $sformatf("variant %0d: store/load across fence = %08h", v, r3))
  end
  // TC-015 | REQ-073: fence is a NOP without extra stall
  `TC_CHECK(t_fence == t_nop, $sformatf("fence must not stall: fence run %0d cycles, nop run %0d cycles", t_fence, t_nop))

  mon_check_all();
endtask
