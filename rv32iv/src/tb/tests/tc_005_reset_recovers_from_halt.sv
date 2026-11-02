// TC-005 | REQ-041, REQ-052, REQ-053
// After an illegal-instruction halt (c=0) and after an ebreak halt (c=1) reset returns o_halt, o_err_illegal and
// sts.err to 0 and a new program runs normally.
// run_prog() includes the post-halt drain, so the sts.err event counter has seen the o_err_illegal rise and the
// store older than the halting instruction has reached DMEM before any check or reset below.
task automatic tc_005_reset_recovers_from_halt();
  logic [31:0] d;
  int          c;

  for (c = 0; c < 2; c++) begin
    // ---- program that halts; the younger instructions after the halting one must not execute
    prog_reset();
    emit_res_init();
    emit_li(5'd5, 32'h1111_0000 + c);
    emit_sw_res(5'd5, 0);                              // older instruction: completes
    if (c == 0) emit(rv_div(5'd6, 5'd5, 5'd5));        // illegal (no div in Zmmul)
    else        emit(rv_ebreak());
    emit_li(5'd5, 32'h99);
    emit_sw_res(5'd5, 1);                              // younger: must NOT execute
    emit_halt();
    dmem_wr(TB_RES_BASE + 32'h0, 32'h0);
    dmem_wr(TB_RES_BASE + 32'h4, 32'h0);
    run_prog(3000);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, "core must halt")
    if (c == 0) begin
      `TC_CHECK(o_err_illegal === 1'b1,  "illegal instruction must set o_err_illegal")
      `TC_CHECK(tb_sts_err_events >= 1,  "illegal instruction must set sts.err")
    end else begin
      `TC_CHECK(o_err_illegal === 1'b0,  "ebreak must not set o_err_illegal")
      `TC_CHECK(tb_sts_err_events == 0,  "ebreak must not set sts.err")
    end

    // ---- reset clears the halt state at once and keeps it clear after release
    rst_assert();
    #1;
    `TC_CHECK(o_halt === 1'b0,        "reset must clear o_halt")
    `TC_CHECK(o_err_illegal === 1'b0, "reset must clear o_err_illegal")
    wait_cycles(3);
    `TC_CHECK(o_halt === 1'b0 && o_err_illegal === 1'b0, "halt flags must stay 0 while reset is held")

    // ---- new program runs normally; sts.err is clear
    prog_reset();
    emit_res_init();
    emit_li(5'd6, MMIO_BASE);
    emit(rv_lw(5'd7, 5'd6, 4));
    emit(rv_andi(5'd7, 5'd7, 7));
    emit_sw_res(5'd7, 2);                              // sts busy/done/err must be 0
    emit_li(5'd8, 6);
    emit_li(5'd9, 7);
    emit(rv_mul(5'd10, 5'd8, 5'd9));
    emit_sw_res(5'd10, 3);                             // 42
    emit_halt();
    run_prog(3000);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1,   "new program must run to its ebreak after the reset")
    `TC_CHECK(o_err_illegal === 1'b0,           "new program must not raise o_err_illegal")
    `TC_CHECK(tb_sts_err_events == 0,           "sts.err must not be set by the new program")
    res_rd(0, d); `TC_CHECK(d === (32'h1111_0000 + c), "older instruction before the halt must have completed")
    res_rd(1, d); `TC_CHECK(d === 32'h0,                "younger instruction after the halt must not execute")
    res_rd(2, d); `TC_CHECK(d === 32'h0,                "sts.err (and busy/done) must be cleared by reset")
    res_rd(3, d); `TC_CHECK(d === 32'd42,               "new program result wrong")
  end
  mon_check_all();
endtask
