// TC-017 | REQ-057, REQ-015
// CPU data accesses to the IMEM range 0x0000_0000..0x0000_7FFF are unmapped: loads return 0, stores are ignored
// (instructions overwritten by sw/sh/sb still execute unchanged), no o_halt/o_err_illegal and sts.err stays 0.
// run_prog() drains the halted core, so the end-marker store (directly before ebreak) reaches DMEM before the
// host reads reset the DUT.
task automatic tc_017_imem_range_data_access_unmapped();
  int          i, idxA, idxB, idxC, t1, t2, t3;
  logic [31:0] r [0:15];

  for (i = 0; i < 16; i++) dmem_wr(TB_RES_BASE + 4 * i, 32'hDEAD_BEEF);   // 0 can be told from "not written"

  prog_reset();
  emit_res_init();
  // ---- loads from the IMEM range (word 0 = lui x31 = bytes B7 8F 00 10 is non-zero)
  emit(rv_lw (2, 0, 0));      emit_sw_res(2, 0);
  emit(rv_lw (2, 0, 4));      emit_sw_res(2, 1);
  emit(rv_lb (2, 0, 1));      emit_sw_res(2, 2);
  emit(rv_lbu(2, 0, 3));      emit_sw_res(2, 3);
  emit(rv_lh (2, 0, 0));      emit_sw_res(2, 4);
  emit(rv_lhu(2, 0, 0));      emit_sw_res(2, 5);
  emit_li(3, 32'h0000_7FFC);
  emit(rv_lw (2, 3, 0));      emit_sw_res(2, 6);    // last IMEM word
  emit_li(3, 32'h0000_1000);
  emit(rv_lw (2, 3, 0));      emit_sw_res(2, 7);
  // ---- stores over instructions that execute later
  emit_li(6, 32'h0010_0073);                          // ebreak word: would halt early if a store took effect
  idxA = prog_pc; emit(rv_addi(3,  0, 0));            // x3  = address of T1 (patched)
  idxB = prog_pc; emit(rv_addi(10, 0, 0));            // x10 = address of T2 (patched)
  idxC = prog_pc; emit(rv_addi(11, 0, 0));            // x11 = address of T3 (patched)
  emit(rv_sw(6, 3, 0));
  emit(rv_sh(6, 10, 0));
  emit(rv_sb(6, 11, 0));
  for (i = 0; i < 6; i++) emit(rv_nop());             // store completes well before the targets are fetched
  t1 = prog_here(); emit(rv_addi(7, 0, 32'h71));
  t2 = prog_here(); emit(rv_addi(8, 0, 32'h72));
  t3 = prog_here(); emit(rv_addi(9, 0, 32'h73));
  prog_patch(idxA, rv_addi(3,  0, t1));
  prog_patch(idxB, rv_addi(10, 0, t2));
  prog_patch(idxC, rv_addi(11, 0, t3));
  emit_sw_res(7, 8);
  emit_sw_res(8, 9);
  emit_sw_res(9, 10);
  // ---- sts.err must still be 0
  emit_li(4, CSR_STS);
  emit(rv_lw(3, 4, 0));
  emit_sw_res(3, 11);
  emit_li(5, 32'h0E0D);
  emit_sw_res(5, 12);
  emit_halt();

  run_prog(5000);
  snap_status();
  for (i = 0; i < 13; i++) res_rd(i, r[i]);

  // TC-017 | REQ-057
  `TC_CHECK(tb_run_hit, "program did not halt")
  `TC_CHECK(snap_halt === 1'b1 && snap_err_illegal === 1'b0, "expected ebreak halt without o_err_illegal (IMEM-range access must not error)")
  `TC_CHECK(snap_sts_err_events == 0, "IMEM-range data access set sts.err")
  for (i = 0; i < 8; i++) begin
    `TC_CHECK(r[i] === 32'h0, $sformatf("IMEM-range load %0d returned %08h, expected 0", i, r[i]))
  end
  `TC_CHECK(r[8]  === 32'h71, $sformatf("instruction overwritten by sw executed differently (%08h)", r[8]))
  `TC_CHECK(r[9]  === 32'h72, $sformatf("instruction overwritten by sh executed differently (%08h)", r[9]))
  `TC_CHECK(r[10] === 32'h73, $sformatf("instruction overwritten by sb executed differently (%08h)", r[10]))
  `TC_CHECK(r[11][2] === 1'b0, $sformatf("sts.err set after IMEM-range accesses (sts=%08h)", r[11]))
  // TC-017 | REQ-015: execution continued to the end of the program
  `TC_CHECK(r[12] === 32'h0E0D, $sformatf("end marker missing (%08h): core stopped early", r[12]))

  mon_check_all();
endtask
