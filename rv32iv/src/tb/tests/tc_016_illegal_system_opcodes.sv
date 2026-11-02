// TC-016 | REQ-073, REQ-052, REQ-053, REQ-027
// Each SYSTEM opcode other than ebreak (ecall, all CSR forms, mret/sret/uret/wfi/sfence.vma) is an illegal
// instruction: o_halt=1, o_err_illegal=1, sts.err set; older instruction completes, younger one does not;
// outputs stay sticky until reset and (mon_check_all) change only at clock edges.
// run_prog() drains the halted core (the older sw legitimately issues after o_halt rises); chk_halted_stable()
// drains again internally and is strict afterwards (no data request, fixed PC).
task automatic tc_016_illegal_system_opcodes();
  logic [31:0] ops [0:13];     // 14 SYSTEM opcodes
  int          v, i;
  logic [31:0] r0, r1;

  ops[0]  = rv_ecall();
  ops[1]  = rv_csr(3'b001, 1, 12'h300, 2);   // csrrw  x1, mstatus, x2
  ops[2]  = rv_csr(3'b010, 1, 12'hC00, 0);   // csrrs  x1, cycle, x0
  ops[3]  = rv_csr(3'b011, 3, 12'h305, 4);   // csrrc  x3, mtvec, x4
  ops[4]  = rv_csr(3'b101, 1, 12'h340, 5);   // csrrwi x1, mscratch, 5
  ops[5]  = rv_csr(3'b110, 0, 12'h300, 3);   // csrrsi x0, mstatus, 3
  ops[6]  = rv_csr(3'b111, 1, 12'h7B0, 1);   // csrrci x1, dcsr, 1
  ops[7]  = rv_mret();
  ops[8]  = 32'h1020_0073;                   // sret
  ops[9]  = rv_wfi();
  ops[10] = 32'h1200_0073;                   // sfence.vma x0, x0
  ops[11] = rv_csr(3'b010, 0, 12'hC01, 0);   // csrr x0, time
  ops[12] = 32'h0020_0073;                   // uret
  ops[13] = rv_csr(3'b001, 0, 12'hC02, 0);   // csrrw x0, instret, x0

  for (v = 0; v < 14; v++) begin
    for (i = 0; i < 4; i++) dmem_wr(TB_RES_BASE + 4 * i, 32'h0);
    prog_reset();
    emit_res_init();
    emit_li(1, 32'hAAAA);
    emit_sw_res(1, 0);                       // older instruction: must complete
    emit(ops[v]);                            // the SYSTEM opcode under test
    emit_li(2, 32'hBBBB);
    emit_sw_res(2, 1);                       // younger instruction: must have no effect
    emit_halt();
    run_prog(3000);

    // TC-016 | REQ-073, REQ-052
    `TC_CHECK(tb_run_hit, $sformatf("opcode %08h: core did not halt", ops[v]))
    `TC_CHECK(o_halt === 1'b1, $sformatf("opcode %08h: o_halt not 1", ops[v]))
    `TC_CHECK(o_err_illegal === 1'b1, $sformatf("opcode %08h: o_err_illegal not 1", ops[v]))
    // TC-016 | REQ-053, REQ-027: flags are sticky level outputs until reset
    chk_halted_stable(12);
    `TC_CHECK(o_err_illegal === 1'b1, $sformatf("opcode %08h: o_err_illegal dropped while halted", ops[v]))
    snap_status();
    res_rd(0, r0);
    res_rd(1, r1);
    // TC-016 | REQ-052
    `TC_CHECK(snap_sts_err_events >= 1, $sformatf("opcode %08h: sts.err not set (no hardware set event)", ops[v]))
    `TC_CHECK(r0 === 32'hAAAA, $sformatf("opcode %08h: older store missing (%08h)", ops[v], r0))
    `TC_CHECK(r1 === 32'h0, $sformatf("opcode %08h: younger store executed (%08h)", ops[v], r1))
  end

  // TC-016 | REQ-027: outputs changed only at rising edges while reset was released
  mon_check_all();
endtask
