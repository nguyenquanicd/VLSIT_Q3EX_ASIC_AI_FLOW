// TC-040 | REQ-017, REQ-052, REQ-055
// sts.err sources and clearing.
//   program 1: PSLVERR (sb to a CSR) sets sts.err; a write of 0 to sts keeps it (busy/done are plain RW and follow
//              the write); a write with bit 2 = 1 clears it (w1c) while the other bits keep the written value;
//              the error can be set again and cleared again; result.label is never modified by the partial write.
//   program 2: an illegal instruction (div) sets sts.err (observed through the o_err_illegal rise, the hardware set
//              event of the TB monitor) and halts.
//   program 3: PSLVERR and an illegal instruction in close succession: both events are seen.
// The CSR field itself can only be read by firmware, so program 1 reads sts with lw; for the illegal-instruction
// source the TB uses the hardware set event (tb_sts_err_events) because the halted core cannot read sts.
task automatic tc_040_sts_err_set_clear_sources();
  logic [31:0] d;
  int          pg;

  // ---------------- program 1: PSLVERR set / w1c clear
  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd9, 32'hFF);
  emit_li(5'd7, 3);  emit(rv_sw(5'd7, 5'd6, 4));               // sts = busy | done
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 0);           // 3
  emit(rv_sb(5'd9, 5'd6, 8));                                   // partial write -> PSLVERR -> sts.err
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 1);           // 7
  emit(rv_sw(5'd0, 5'd6, 4));                                   // write 0: busy/done cleared, err kept
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 2);           // 4
  emit_li(5'd7, 5);  emit(rv_sw(5'd7, 5'd6, 4));               // busy = 1, err cleared (w1c)
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 3);           // 1
  emit(rv_sb(5'd9, 5'd6, 8));                                   // second PSLVERR
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 4);           // 5
  emit_li(5'd7, 4);  emit(rv_sw(5'd7, 5'd6, 4));               // w1c with busy = 0
  emit(rv_lw(5'd8, 5'd6, 4));  emit_sw_res(5'd8, 5);           // 0
  emit(rv_lw(5'd8, 5'd6, 8));  emit_sw_res(5'd8, 6);           // result.label untouched = 0
  emit_halt();
  run_prog(20000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program 1 did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "program 1: PSLVERR must not raise o_err_illegal / halt the core")
  `TC_CHECK(tb_errpulse_cnt == 2, $sformatf("program 1: %0d o_sts_err_set pulses, expected 2", tb_errpulse_cnt))
  `TC_CHECK(tb_sts_err_events == 2, $sformatf("program 1: %0d sts.err set events, expected 2", tb_sts_err_events))
  res_rd(0, d); `TC_CHECK(d === 32'h3, $sformatf("sts after write 3 = %08h, expected 3 (busy/done plain RW)", d))
  res_rd(1, d); `TC_CHECK(d === 32'h7, $sformatf("sts after PSLVERR = %08h, expected 7 (err set)", d))
  res_rd(2, d); `TC_CHECK(d === 32'h4, $sformatf("sts after write 0 = %08h, expected 4 (err kept)", d))
  res_rd(3, d); `TC_CHECK(d === 32'h1, $sformatf("sts after write 5 = %08h, expected 1 (err cleared by w1c, busy kept)", d))
  res_rd(4, d); `TC_CHECK(d === 32'h5, $sformatf("sts after second PSLVERR = %08h, expected 5", d))
  res_rd(5, d); `TC_CHECK(d === 32'h0, $sformatf("sts after write 4 = %08h, expected 0", d))
  res_rd(6, d); `TC_CHECK(d === 32'h0, $sformatf("result.label = %08h, must not be changed by the partial write", d))

  // ---------------- program 2: illegal instruction
  prog_reset();
  emit_res_init();
  emit_li(5'd5, 32'h1111);
  emit(rv_div(5'd6, 5'd5, 5'd5));
  emit_halt();
  mon_clear();                                                  // per-program counters (pulses, events)
  run_prog(3000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program 2: core must halt on the illegal instruction")
  `TC_CHECK(o_err_illegal === 1'b1, "program 2: o_err_illegal must be 1")
  `TC_CHECK(tb_sts_err_events == 1, $sformatf("program 2: %0d sts.err set events, expected 1", tb_sts_err_events))
  `TC_CHECK(tb_errpulse_cnt == 0, "program 2: no APB error expected")

  // ---------------- program 3: PSLVERR followed closely by an illegal instruction
  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd9, 32'hFF);
  emit(rv_sb(5'd9, 5'd6, 8));                                   // PSLVERR
  emit(rv_div(5'd7, 5'd9, 5'd9));                               // illegal right behind it
  emit_halt();
  mon_clear();
  run_prog(3000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program 3: core must halt")
  `TC_CHECK(o_err_illegal === 1'b1, "program 3: o_err_illegal must be 1")
  `TC_CHECK(tb_errpulse_cnt == 1, $sformatf("program 3: %0d o_sts_err_set pulses, expected 1", tb_errpulse_cnt))
  `TC_CHECK(tb_sts_err_events == 2, $sformatf("program 3: %0d sts.err set events, expected 2 (PSLVERR + illegal)", tb_sts_err_events))
  mon_check_all();
endtask
