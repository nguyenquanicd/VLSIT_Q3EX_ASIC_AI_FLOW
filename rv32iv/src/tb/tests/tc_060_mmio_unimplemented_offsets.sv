// TC-060 | REQ-086
// Accesses to unimplemented offsets inside the 4 KB MMIO window (0x2000_0018, 0x2000_0020, 0x2000_0100,
// 0x2000_0FFC): reads return 0, writes are ignored, the core does not hang or halt and no defined register
// (ctrl, sts busy/done, result, uart_cfg, uart_tx, cycles) changes. sts.err is not checked for these accesses.
task automatic tc_060_mmio_unimplemented_offsets();
  logic [31:0] off [0:3];
  logic [31:0] d;
  int          i;

  off[0] = 32'h018;
  off[1] = 32'h020;
  off[2] = 32'h100;
  off[3] = 32'hFFC;

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  // known defined-register state
  emit_li(5'd7, 32'h9);      emit(rv_sw(5'd7, 5'd6, 8));       // result.label = 9
  emit_li(5'd7, 32'h3);      emit(rv_sw(5'd7, 5'd6, 4));       // sts.busy | sts.done
  emit_li(5'd7, 32'h0456);   emit(rv_sw(5'd7, 5'd6, 20));      // uart_cfg.baud_div = 0x0456
  emit(rv_lw(5'd7, 5'd6, 12));  emit_sw_res(5'd7, 12);         // cycles.cnt before
  emit_li(5'd10, 32'hFFFF_FFFF);
  emit_li(5'd11, 32'hA5A5_A5A5);
  for (i = 0; i < 4; i++) begin
    emit_li(5'd12, MMIO_BASE + off[i]);
    emit(rv_lw(5'd8, 5'd12, 0));   emit_sw_res(5'd8, i);        // read before any write: 0
    emit(rv_sw(5'd10, 5'd12, 0));                               // ignored writes
    emit(rv_sw(5'd11, 5'd12, 0));
    emit(rv_lw(5'd8, 5'd12, 0));   emit_sw_res(5'd8, 4 + i);    // read after the writes: still 0
  end
  emit(rv_addi(5'd9, 5'd0, 1));
  emit_sw_res(5'd9, 8);                                         // execution continued
  // defined registers unchanged
  emit(rv_lw(5'd7, 5'd6, 8));   emit(rv_andi(5'd7, 5'd7, 15));   emit_sw_res(5'd7, 9);    // result.label
  emit(rv_lw(5'd7, 5'd6, 4));   emit(rv_andi(5'd7, 5'd7, 3));    emit_sw_res(5'd7, 10);   // sts busy/done
  emit(rv_lw(5'd7, 5'd6, 20));                                    emit_sw_res(5'd7, 11);   // uart_cfg
  emit(rv_lw(5'd7, 5'd6, 12));                                    emit_sw_res(5'd7, 13);   // cycles.cnt after
  emit(rv_lw(5'd7, 5'd6, 0));   emit(rv_andi(5'd7, 5'd7, 1));    emit_sw_res(5'd7, 14);   // ctrl.start
  emit(rv_lw(5'd7, 5'd6, 16));  emit(rv_andi(5'd7, 5'd7, 32'h300)); emit_sw_res(5'd7, 15); // uart_tx send/busy
  emit_li(5'd5, 32'h0E0D);
  emit_sw_res(5'd5, 16);
  emit_halt();

  dmem_fill(TB_RES_BASE, 20, 32'hC0FF_EE11);
  run_prog(30000);                                              // includes the post-halt drain

  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak: an access to an unimplemented offset hung the core")
  `TC_CHECK(o_err_illegal === 1'b0, "access to an unimplemented MMIO offset raised an illegal instruction")
  `TC_CHECK(o_result_label === 4'd9, "o_result_label changed by a write to an unimplemented offset")
  `TC_CHECK(o_sts_done === 1'b1,     "sts.done changed by a write to an unimplemented offset")
  `TC_CHECK(tb_uart_fall_cnt == 0,   "a write to an unimplemented offset started a UART frame")

  for (i = 0; i < 4; i++) begin
    res_rd(i, d);     `TC_CHECK(d === 32'h0, $sformatf("read of unimplemented offset 0x%03h returned %08h, expected 0", off[i], d))
    res_rd(4 + i, d); `TC_CHECK(d === 32'h0, $sformatf("read of 0x%03h after writes returned %08h, expected 0 (write ignored)", off[i], d))
  end
  res_rd(8, d);  `TC_CHECK(d === 32'd1,    "execution did not continue after the accesses")
  res_rd(9, d);  `TC_CHECK(d === 32'd9,    "result.label changed")
  res_rd(10, d); `TC_CHECK(d === 32'd3,    "sts.busy/done changed")
  res_rd(11, d); `TC_CHECK(d === 32'h0456, "uart_cfg changed")
  begin
    logic [31:0] c0, c1;
    res_rd(12, c0);
    res_rd(13, c1);
    `TC_CHECK(c0 === c1, $sformatf("cycles.cnt changed (%08h -> %08h)", c0, c1))
  end
  res_rd(14, d); `TC_CHECK(d === 32'd0,    "ctrl.start changed")
  res_rd(15, d); `TC_CHECK(d === 32'd0,    "uart_tx send/busy changed")
  res_rd(16, d); `TC_CHECK(d === 32'h0E0D, "end marker missing")
  mon_check_all();
endtask
