// TC-018 | REQ-015, REQ-057
// CPU accesses to unmapped data addresses (beyond IMEM, beyond DMEM, beyond the 4 KB MMIO window, far regions):
// reads return 0, writes are ignored (no alias onto DMEM / IMEM / CSR), no error flag (o_err_illegal, sts.err).
//   Part 1: stores of an ebreak word to alias candidates of a later IMEM instruction (the "victim") -> the victim
//           must still execute (marker 0x55) and the program must reach its end marker.
//   Part 2: for 11 unmapped addresses: lw (0), sw + lw (0), sb + lbu (0).
//   Part 3: DMEM words at the base (aliased by 0x1004_0000/0x1004_0010) unchanged, CSRs ctrl/sts/result untouched
//           (alias candidates 0x2000_1000/0x2000_1004/0x2000_1008), uart_cfg keeps its reset value.
task automatic tc_018_unmapped_cpu_addresses();
  logic [31:0] ad  [0:10];
  logic [31:0] ali [0:3];
  logic [31:0] exp_s [0:127];
  logic [31:0] d;
  int          i, k, nslot, nerr, vic;

  // unmapped read/write addresses
  ad[0]  = 32'h0000_8000;  ad[1]  = 32'h0000_FFFC;  ad[2]  = 32'h1004_0000;  ad[3]  = 32'h1004_0010;
  ad[4]  = 32'h2000_1000;  ad[5]  = 32'h2000_1004;  ad[6]  = 32'h2000_1008;  ad[7]  = 32'h2000_1FFC;
  ad[8]  = 32'h3000_0000;  ad[9]  = 32'h8000_0000;  ad[10] = 32'hFFFF_FFFC;
  vic = 400;                                          // word index of the victim instruction (byte 0x640), after all code
  ali[0] = 32'h0000_8000 + 32'(vic * 4);              // alias candidates of the victim IMEM word
  ali[1] = 32'h0001_0000 + 32'(vic * 4);
  ali[2] = 32'h0004_0000 + 32'(vic * 4);
  ali[3] = 32'h8000_0000 + 32'(vic * 4);

  for (k = 0; k < 8; k++) dmem_wr(DMEM_BASE + 32'(4 * k), 32'h600D_0000 + k);
  for (i = 0; i < 64; i++) dmem_wr(TB_RES_BASE + 32'(4 * i), 32'hDEAD_BEEF);

  nslot = 0;
  prog_reset();
  emit_res_init();
  // ---- part 1: stores of an ebreak word over alias candidates of the victim
  emit_li(5, 32'h0010_0073);
  for (i = 0; i < 4; i++) begin
    emit_li(6, ali[i]);
    emit(rv_sw(5, 6, 0));
  end
  // ---- part 2: unmapped reads / writes
  for (i = 0; i < 11; i++) begin
    emit_li(3, ad[i]);
    emit(rv_lw(2, 3, 0));   emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;
    emit_li(4, 32'h0BAD_0000 + i);
    emit(rv_sw(4, 3, 0));
    emit(rv_lw(2, 3, 0));   emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;
    emit(rv_sb(4, 3, 0));
    emit(rv_lbu(2, 3, 0));  emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;
  end
  // ---- part 3: DMEM base and CSRs untouched
  emit_li(3, DMEM_BASE);
  emit(rv_lw(2, 3, 0));     emit_sw_res(2, nslot);  exp_s[nslot] = 32'h600D_0000;  nslot++;
  emit(rv_lw(2, 3, 16));    emit_sw_res(2, nslot);  exp_s[nslot] = 32'h600D_0004;  nslot++;
  emit_li(3, MMIO_BASE);
  emit(rv_lw(2, 3, 0));     emit(rv_andi(2, 2, 1));   emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;   // ctrl.start
  emit(rv_lw(2, 3, 4));     emit(rv_andi(2, 2, 7));   emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;   // sts (no err)
  emit(rv_lw(2, 3, 8));     emit(rv_andi(2, 2, 15));  emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0;  nslot++;   // result.label
  emit(rv_lw(2, 3, 20));    emit_sw_res(2, nslot);  exp_s[nslot] = 32'h0000_06C8;  nslot++;                      // uart_cfg
  // ---- jump to the victim (word 400), which must still be the original instruction
  emit(rv_jal(0, vic * 4 - prog_here()));
  prog_org(vic);
  emit(rv_addi(20, 0, 32'h55));                         // victim
  emit_sw_res(20, nslot);   exp_s[nslot] = 32'h55;  nslot++;
  emit_li(5, 32'h0E0D);
  emit_sw_res(5, nslot);    exp_s[nslot] = 32'h0E0D;  nslot++;                                                  // end marker
  emit_halt();

  run_prog(30000);
  `TC_CHECK(tb_run_hit, "program did not halt")
  `TC_CHECK(o_halt === 1'b1,        "expected the final ebreak halt")
  `TC_CHECK(o_err_illegal === 1'b0, "unmapped data access raised o_err_illegal")
  `TC_CHECK(tb_sts_err_events == 0, "unmapped data access set sts.err")
  `TC_CHECK(o_result_label === 4'h0, "o_result_label changed by an unmapped store (alias onto MMIO?)")
  `TC_CHECK(o_sts_done === 1'b0,     "o_sts_done changed by an unmapped store (alias onto MMIO?)")

  nerr = 0;
  for (i = 0; i < nslot; i++) begin
    res_rd(i, d);
    if (d !== exp_s[i]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_s[i], $sformatf("result slot %0d = %08h, expected %08h", i, d, exp_s[i]))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d result slots differ (unmapped read not 0, write not ignored, or core stopped early)", nerr))
  for (k = 0; k < 8; k++) begin
    dmem_rd(DMEM_BASE + 32'(4 * k), d);
    `TC_CHECK(d === (32'h600D_0000 + k), $sformatf("DMEM word %0d at the base changed by an unmapped store: %08h", k, d))
  end
  mon_check_all();
endtask
