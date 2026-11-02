// TC-059 | REQ-085
// Sub-word (lb/lh/lbu/lhu at every byte offset 0..3) and misaligned lw (+1, +2, +3) reads of every CSR word:
// each read completes (no hang), the core does not halt or raise an illegal instruction, MMIO reads never produce
// a PSLVERR pulse (o_sts_err_set) and the defined registers keep their values. Read data and sts.err are not checked
// (unspecified, REQ-085).
task automatic tc_059_mmio_subword_misaligned_reads();
  int          reg_i, b, nrd;
  logic [31:0] d;

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  // known register state (written with aligned sw before the reads)
  emit_li(5'd7, 32'h9);      emit(rv_sw(5'd7, 5'd6, 8));       // result.label = 9
  emit_li(5'd7, 32'h3);      emit(rv_sw(5'd7, 5'd6, 4));       // sts.busy | sts.done
  emit_li(5'd7, 32'h0123);   emit(rv_sw(5'd7, 5'd6, 20));      // uart_cfg.baud_div = 0x0123
  nrd = 0;
  for (reg_i = 0; reg_i < 6; reg_i++) begin
    for (b = 0; b < 4; b++) begin
      emit(rv_lb (5'd8, 5'd6, 4 * reg_i + b));  nrd++;
      emit(rv_lbu(5'd8, 5'd6, 4 * reg_i + b));  nrd++;
      emit(rv_lh (5'd8, 5'd6, 4 * reg_i + b));  nrd++;
      emit(rv_lhu(5'd8, 5'd6, 4 * reg_i + b));  nrd++;
    end
    for (b = 1; b < 4; b++) begin
      emit(rv_lw (5'd8, 5'd6, 4 * reg_i + b));  nrd++;
    end
  end
  emit(rv_addi(5'd9, 5'd0, 1));                                 // execution continues after the reads
  emit_sw_res(5'd9, 0);
  // registers unchanged
  emit(rv_lw(5'd7, 5'd6, 8));   emit(rv_andi(5'd7, 5'd7, 15));   emit_sw_res(5'd7, 1);   // result.label
  emit(rv_lw(5'd7, 5'd6, 4));   emit(rv_andi(5'd7, 5'd7, 3));    emit_sw_res(5'd7, 2);   // sts busy/done
  emit(rv_lw(5'd7, 5'd6, 20));                                    emit_sw_res(5'd7, 3);   // uart_cfg
  emit(rv_lw(5'd7, 5'd6, 0));   emit(rv_andi(5'd7, 5'd7, 1));    emit_sw_res(5'd7, 4);   // ctrl.start
  emit_li(5'd5, 32'h0E0D);
  emit_sw_res(5'd5, 5);
  emit_halt();

  dmem_fill(TB_RES_BASE, 8, 32'hC0FF_EE11);
  run_prog(60000);                                              // includes the post-halt drain

  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak: a sub-word / misaligned MMIO read hung the core")
  `TC_CHECK(o_err_illegal === 1'b0, "sub-word / misaligned MMIO read raised an illegal instruction")
  `TC_CHECK(tb_errpulse_cnt == 0, $sformatf("o_sts_err_set pulsed %0d times: an MMIO read must never raise PSLVERR", tb_errpulse_cnt))
  `TC_CHECK(tb_apb_slverr_cnt == 0, $sformatf("%0d APB transfers ended with PSLVERR, reads must not", tb_apb_slverr_cnt))
  `TC_CHECK(tb_apb_xfer_cnt >= nrd, $sformatf("%0d APB transfers seen for %0d emitted reads (reads must reach the APB)", tb_apb_xfer_cnt, nrd))
  `TC_CHECK(o_result_label === 4'd9, "result.label changed by a read")

  res_rd(0, d); `TC_CHECK(d === 32'd1,     "execution did not continue after the reads")
  res_rd(1, d); `TC_CHECK(d === 32'd9,     "result.label changed by a sub-word read")
  res_rd(2, d); `TC_CHECK(d === 32'd3,     "sts.busy/done changed by a sub-word read")
  res_rd(3, d); `TC_CHECK(d === 32'h0123,  "uart_cfg changed by a sub-word read")
  res_rd(4, d); `TC_CHECK(d === 32'd0,     "ctrl.start changed by a sub-word read")
  res_rd(5, d); `TC_CHECK(d === 32'h0E0D,  "end marker missing")
  mon_check_all();
endtask
