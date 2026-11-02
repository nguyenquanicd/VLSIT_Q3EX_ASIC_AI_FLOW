// TC-043 | REQ-013, REQ-062, REQ-087
// cycles.cnt = done_cycle - start_cycle + 1 of the LAST vector instruction (inclusive window), measured by the
// TB (monitor log, start = command transfer cycle) and read back by firmware with lw from cycles.cnt.
// Instructions of different latency: vsetvli, vle8, vle8, vwmul, vwredsum, vsetvli again, vse8.
// REQ-087: every vector command (including vsetvli) passes IDLE, DEC, RD, EXEC, WB, DONE, so the latency
// done_cycle - start_cycle is at least 5 cycles (window cycles.cnt >= 6).
task automatic tc_043_cycles_cnt_window();
  logic [31:0] w [0:6];
  logic [31:0] d;
  int          i;

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd30, TB_DATA_BASE);
  emit(rv_lw(5'd7, 5'd6, 12));                    // cycles.cnt right after reset: no vector instruction yet
  emit_sw_res(5'd7, 0);
  w[0] = rv_vsetvli(5'd5, 5'd0, vtype_zimm(8));
  w[1] = rv_vle8(5'd1, 5'd30);
  w[2] = rv_vle8(5'd2, 5'd30);
  w[3] = rv_vwmul_vv(5'd4, 5'd2, 5'd1);
  w[4] = rv_vwredsum_vs(5'd8, 5'd4, 5'd1);
  w[5] = rv_vsetvli(5'd5, 5'd0, vtype_zimm(8));   // short instruction after the long reduction
  w[6] = rv_vse8(5'd1, 5'd30);
  for (i = 0; i < 7; i++) begin
    emit(w[i]);
    emit(rv_lw(5'd7, 5'd6, 12));                  // cycles.cnt after instruction i (scalar read, no effect on it)
    emit_sw_res(5'd7, i + 1);
  end
  emit_halt();

  dmem_fill(TB_DATA_BASE, 4, 32'h80FF_7F01);      // includes -128 x -128 products
  host_load_prog();                               // DUT is in reset here
  wait_cycles(2);
  `TC_CHECK(p_vcyc_cnt === 32'h0, "cycles.cnt source must be 0 after reset")
  host_end();
  wait_halt(5000);                                // includes the post-halt drain
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "unexpected illegal instruction")
  `TC_CHECK(tb_vlog_n == 7, $sformatf("expected 7 completed vector instructions, monitor saw %0d", tb_vlog_n))

  res_rd(0, d);
  `TC_CHECK(d === 32'h0, "cycles.cnt must read 0 before any vector instruction after reset")
  for (i = 0; i < 7; i++) begin
    `TC_CHECK(tb_vlog_instr[i] === w[i],
              $sformatf("vector instruction %0d: logged %08h, expected %08h", i, tb_vlog_instr[i], w[i]))
    `TC_CHECK(tb_vlog_cnt_exp[i] === 32'(tb_vlog_lat[i] + 1), "inconsistent TB oracle")
    // TC-043 | REQ-087: six-state sequence -> at least 5 cycles from start to o_resp_done (also vsetvli)
    `TC_CHECK(tb_vlog_lat[i] >= 5,
              $sformatf("instr %0d (%08h): latency start->o_resp_done = %0d cycles, REQ-087 requires >= 5",
                        i, tb_vlog_instr[i], tb_vlog_lat[i]))
    `TC_CHECK(tb_vlog_cnt_exp[i] >= 32'd6, $sformatf("instr %0d: cycles.cnt window %0d shorter than 6", i, tb_vlog_cnt_exp[i]))
    `TC_CHECK(tb_vlog_cnt_obs[i] === tb_vlog_cnt_exp[i],
              $sformatf("instr %0d: o_cycles_cnt after done = %0d, expected done-start+1 = %0d",
                        i, tb_vlog_cnt_obs[i], tb_vlog_cnt_exp[i]))
    res_rd(i + 1, d);
    `TC_CHECK(d === tb_vlog_cnt_exp[i],
              $sformatf("instr %0d: firmware read of cycles.cnt = %0d, expected %0d (last instruction only)",
                        i, d, tb_vlog_cnt_exp[i]))
  end
  `TC_CHECK(tb_vlat_min >= 5, $sformatf("minimum vector command latency seen by the monitor = %0d (< 5)", tb_vlat_min))
  mon_check_all();
endtask
