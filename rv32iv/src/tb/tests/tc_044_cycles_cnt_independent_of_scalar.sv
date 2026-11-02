// TC-044 | REQ-013
// cycles.cnt is fed by m_vpu_perf only: after a vector instruction a long scalar loop (and many MMIO reads)
// must leave cycles.cnt unchanged; a new vector instruction replaces the value.
task automatic tc_044_cycles_cnt_independent_of_scalar();
  logic [31:0] w_vset, w_vle;
  logic [31:0] a, b, c, dd, e1, e2;

  w_vset = rv_vsetvli(5'd5, 5'd0, vtype_zimm(8));
  w_vle  = rv_vle8(5'd1, 5'd30);

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd30, TB_DATA_BASE);
  emit(w_vset);                                   // vector instruction 0
  emit(w_vle);                                    // vector instruction 1 (the one cycles.cnt must keep)
  emit(rv_lw(5'd7, 5'd6, 12));
  emit_sw_res(5'd7, 0);                           // A: right after the vector instruction
  emit(rv_addi(5'd1, 5'd0, 600));
  emit(rv_addi(5'd2, 5'd0, 0));
  emit(rv_addi(5'd1, 5'd1, -1));                  // loop: ~1800 cycles of scalar work
  emit(rv_addi(5'd2, 5'd2, 3));
  emit(rv_bne(5'd1, 5'd0, -8));
  emit(rv_lw(5'd7, 5'd6, 12));
  emit_sw_res(5'd7, 1);                           // B: after the long scalar loop
  emit(rv_lw(5'd8, 5'd6, 4));                     // MMIO traffic (sts, result, cycles, uart_cfg)
  emit(rv_lw(5'd8, 5'd6, 8));
  emit(rv_lw(5'd8, 5'd6, 20));
  emit(rv_lw(5'd8, 5'd6, 12));
  emit(rv_lw(5'd8, 5'd6, 12));
  emit(rv_lw(5'd7, 5'd6, 12));
  emit_sw_res(5'd7, 2);                           // C: after the MMIO reads
  emit(w_vset);                                   // vector instruction 2 replaces the value
  emit(rv_lw(5'd7, 5'd6, 12));
  emit_sw_res(5'd7, 3);                           // D
  emit_sw_res(5'd2, 4);                           // keep the loop live (x2 = 1800)
  emit_halt();

  dmem_fill(TB_DATA_BASE, 4, 32'h0102_0304);
  run_prog(20000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "unexpected illegal instruction")
  `TC_CHECK(tb_run_cycles > 1500, "scalar loop did not run long enough to prove independence")
  `TC_CHECK(tb_vlog_n == 3, $sformatf("expected 3 vector instructions, saw %0d", tb_vlog_n))

  res_rd(0, a);
  res_rd(1, b);
  res_rd(2, c);
  res_rd(3, dd);
  res_rd(4, e1);
  `TC_CHECK(e1 === 32'd1800, "scalar loop result wrong (loop did not execute fully)")
  e2 = tb_vlog_cnt_exp[1];                        // expected window of the vle8
  `TC_CHECK(a === e2, $sformatf("cycles.cnt right after vle8 = %0d, expected %0d", a, e2))
  `TC_CHECK(b === a,  $sformatf("cycles.cnt changed during scalar code: %0d -> %0d (fed by a free-running counter?)", a, b))
  `TC_CHECK(c === a,  $sformatf("cycles.cnt changed by MMIO reads: %0d -> %0d", a, c))
  `TC_CHECK(dd === tb_vlog_cnt_exp[2],
            $sformatf("cycles.cnt after the second vsetvli = %0d, expected its own window %0d", dd, tb_vlog_cnt_exp[2]))
  mon_check_all();
endtask
