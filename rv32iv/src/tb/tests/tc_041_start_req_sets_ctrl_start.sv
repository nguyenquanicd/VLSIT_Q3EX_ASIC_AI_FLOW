// TC-041 | REQ-026
// i_start_req level 1 for at least 1 cycle sets ctrl.start (hardware write); firmware clears it with a write of 0.
// Pulses only (never held while firmware clears, Q-TP20). The firmware announces each phase on result.label and the
// TB reacts to it:
//   phase 1: no pulse                       -> ctrl.start reads 0
//   phase 2..6: pulses of 1, 2, 5, 1 and 3 cycles at different delays, ended before the firmware reads ctrl
//               -> ctrl.start reads 1 (sticky), reads 0 after the firmware write of 0
//   phase 7: firmware polls ctrl.start in a tight loop, a 1-cycle pulse ends the poll
// Before the run a 3-cycle pulse is applied while reset is asserted: it must have no effect (phase 1 reads 0).
task automatic tc_041_start_req_sets_ctrl_start();
  logic [31:0] d;
  int          p, tmo, plen, pdel;

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  for (p = 1; p <= 6; p++) begin
    emit_li(5'd8, p);
    emit(rv_sw(5'd8, 5'd6, 8));                         // announce phase p on result.label
    emit_li(5'd9, 60);
    emit(rv_addi(5'd9, 5'd9, -1));                      // delay ~180 cycles (the TB pulses meanwhile)
    emit(rv_bne(5'd9, 5'd0, -4));
    emit(rv_lw(5'd7, 5'd6, 0));  emit_sw_res(5'd7, p);  // ctrl.start as seen by firmware
    emit(rv_sw(5'd0, 5'd6, 0));                         // firmware clears it
    emit(rv_lw(5'd7, 5'd6, 0));  emit_sw_res(5'd7, p + 8);
  end
  // phase 7: tight polling loop with a down-counter
  emit_li(5'd8, 7);
  emit(rv_sw(5'd8, 5'd6, 8));
  emit_li(5'd9, 3000);
  emit(rv_lw(5'd7, 5'd6, 0));                           // poll: i0
  emit(rv_andi(5'd7, 5'd7, 1));                         // i1
  emit(rv_bne(5'd7, 5'd0, 12));                         // i2 -> exit
  emit(rv_addi(5'd9, 5'd9, -1));                        // i3
  emit(rv_bne(5'd9, 5'd0, -16));                        // i4 -> i0
  emit_sw_res(5'd9, 7);                                 // exit: remaining count (non-zero when the pulse was seen)
  emit(rv_sw(5'd0, 5'd6, 0));
  emit(rv_lw(5'd7, 5'd6, 0));  emit_sw_res(5'd7, 15);
  emit_halt();

  // pulse while reset is asserted: no effect
  host_load_prog();
  i_start_req = 1'b1;
  wait_cycles(3);
  i_start_req = 1'b0;
  wait_cycles(2);
  host_end();

  for (p = 1; p <= 7; p++) begin
    tmo = 0;
    while (o_result_label !== p[3:0] && tmo < 20000) begin
      tick();
      tmo++;
    end
    `TC_CHECK(o_result_label === p[3:0], $sformatf("phase %0d was never announced on o_result_label", p))
    if (p >= 2 && p <= 6) begin
      case (p)
        2: begin plen = 1; pdel = 3;  end
        3: begin plen = 2; pdel = 10; end
        4: begin plen = 5; pdel = 17; end
        5: begin plen = 1; pdel = 24; end
        default: begin plen = 3; pdel = 31; end
      endcase
      wait_cycles(pdel);
      start_pulse(plen);
    end else if (p == 7) begin
      wait_cycles(150);                                 // the firmware is inside the polling loop
      start_pulse(1);
    end
  end
  wait_halt(20000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (poll loop never saw ctrl.start?)")
  `TC_CHECK(o_err_illegal === 1'b0, "unexpected illegal instruction")

  res_rd(1, d); `TC_CHECK(d === 32'h0, $sformatf("phase 1: ctrl.start = %08h without a pulse (reset-time pulse must have no effect)", d))
  for (p = 2; p <= 6; p++) begin
    res_rd(p, d);     `TC_CHECK(d === 32'h1, $sformatf("phase %0d: ctrl.start = %08h after the pulse, expected 1", p, d))
  end
  for (p = 1; p <= 6; p++) begin
    res_rd(p + 8, d); `TC_CHECK(d === 32'h0, $sformatf("phase %0d: ctrl.start = %08h after the firmware clear, expected 0", p, d))
  end
  res_rd(7, d);  `TC_CHECK(d !== 32'h0 && d < 32'd3000, $sformatf("phase 7: poll exit count %0d (0 = timeout, 3000 = seen at once)", d))
  res_rd(15, d); `TC_CHECK(d === 32'h0, $sformatf("phase 7: ctrl.start = %08h after the firmware clear, expected 0", d))
  mon_check_all();
endtask
