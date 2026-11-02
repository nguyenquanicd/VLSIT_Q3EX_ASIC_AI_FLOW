// TC-002 | REQ-040, REQ-027
// Reset asserted asynchronously (between clock edges) and released away from the clock edge.
task automatic tc_002_reset_async_assert_sync_release();
  logic [31:0] pc_rst;
  logic [31:0] c1, c2;
  int          k, first_chg;

  // ---- A: halted on an illegal instruction; asynchronous assert clears every status output at once
  prog_reset();
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_illegal_zero());
  run_prog(2000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1,   "A: core must halt on the illegal instruction")
  `TC_CHECK(o_err_illegal === 1'b1,          "A: o_err_illegal must be 1 before reset")
  rst_assert_offedge();                      // reset low ~2 ns after a clock edge, no clock edge follows yet
  #1;
  `TC_CHECK(($time - tb_last_posedge_t) < (CLK_PERIOD / 2), "A: check must happen before the next clock edge")
  `TC_CHECK(o_halt === 1'b0,         "A: o_halt must clear asynchronously on reset assertion")
  `TC_CHECK(o_err_illegal === 1'b0,  "A: o_err_illegal must clear asynchronously on reset assertion")
  `TC_CHECK(o_uart_tx === 1'b1,      "A: o_uart_tx must be 1 after asynchronous reset")
  `TC_CHECK(o_sts_done === 1'b0,     "A: o_sts_done must be 0 after asynchronous reset")
  `TC_CHECK(o_result_label === 4'h0, "A: o_result_label must be 0 after asynchronous reset")

  // ---- B: running store loop; reset stops all DMEM writes
  prog_reset();
  emit_li(5'd30, TB_DATA_BASE);
  emit(rv_addi(5'd1, 5'd0, 0));
  emit(rv_addi(5'd1, 5'd1, 1));              // loop
  emit(rv_sw(5'd1, 5'd30, 0));
  emit(rv_jal(5'd0, -8));
  dmem_wr(TB_DATA_BASE, 32'h0);
  host_load_prog();
  host_end();
  wait_cycles(60);
  rst_assert_offedge();
  #1;
  `TC_CHECK(p_cpu_dmem_req !== 1'b1, "B: no CPU data request right after asynchronous reset assertion")
  for (k = 0; k < 6; k++) begin
    tick();
    `TC_CHECK(p_cpu_dmem_req !== 1'b1, "B: no CPU data request while reset is asserted")
  end
  host_rd32(TB_DATA_BASE, c1);               // enters host mode (reset stays asserted)
  wait_cycles(30);
  host_rd32(TB_DATA_BASE, c2);
  `TC_CHECK(c1 !== 32'h0 && c1 !== 32'hx, "B: store loop did not run before the reset")
  `TC_CHECK(c2 === c1, "B: DMEM changed while reset was asserted (no further writes expected)")

  // ---- C: release away from the clock edge; core starts within a bounded number of cycles
  prog_reset();
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_nop());
  emit_halt();
  host_load_prog();
  wait_cycles(2);
  pc_rst = p_imem_addr;
  rst_release_offedge();                     // i_ld_en=0 and i_rst_n_core=1 together, 2 ns after an edge
  first_chg = -1;
  for (k = 1; k <= 8; k++) begin
    tick();
    if (first_chg < 0 && p_imem_addr !== pc_rst) first_chg = k;
  end
  `TC_CHECK(first_chg > 0 && first_chg <= 4, "C: core must start fetching within 4 cycles of reset release")
  wait_halt(200);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "C: program must run to ebreak after release")
  `TC_CHECK(o_err_illegal === 1'b0,        "C: ebreak must not set o_err_illegal")
  `TC_CHECK(tb_out_async_cnt == 0, "C: status outputs changed away from a clock edge after the release")
  `TC_CHECK(tb_ldv_cnt == 0,       "i_ld_en must be 0 whenever reset is released")
endtask
