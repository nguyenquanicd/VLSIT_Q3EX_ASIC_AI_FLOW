// TC-003 | REQ-044, REQ-042, REQ-041
// Reset in the middle of (s=0) a vector reduction, (s=1) an APB transfer, (s=2) a UART frame.
// Each scenario: program sets CSR state, reset aborts the activity, memories are kept (counter in DMEM, program
// in IMEM re-runs from PC 0 without reloading), a check program then proves that every CSR/VPU/APB/UART state
// is back at its reset value and that vector, APB and scalar operation work normally.
// The "running inference" case needs the MNIST firmware and is covered by the same abort mechanism with
// ctrl.start/sts/result written before the abort (the delivered firmware is exercised by TC-056/057).
task automatic tc_003_reset_during_activity_abort();
  logic [31:0] d, cnt1, cnt2, chk_base;
  int          s, k, tmo, uf_a, uf_b;
  bit          seen;

  chk_base = TB_RES_BASE + 32'h400;

  for (s = 0; s < 3; s++) begin
    // ---------------- activity program (never halts)
    prog_reset();
    emit_res_init();
    emit_li(5'd5, 32'hC0FF_EE00 + s);
    emit_sw_res(5'd5, 0);                               // slot0 marker (DMEM must survive the reset)
    emit(rv_lw(5'd1, 5'd31, 8));                        // slot2 run counter (IMEM must survive the reset)
    emit(rv_addi(5'd1, 5'd1, 1));
    emit(rv_sw(5'd1, 5'd31, 8));
    emit_li(5'd6, MMIO_BASE);
    if (s == 0) begin
      emit_li(5'd7, 5);  emit(rv_sw(5'd7, 5'd6, 8));    // result.label = 5
      emit_li(5'd7, 3);  emit(rv_sw(5'd7, 5'd6, 4));    // sts.busy | sts.done
      emit_li(5'd7, 1);  emit(rv_sb(5'd7, 5'd6, 8));    // partial write -> PSLVERR -> sts.err
      emit_li(5'd30, TB_DATA_BASE);
      emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(8)));
      emit(rv_vle8(5'd1, 5'd30));                       // loop start
      emit(rv_vle8(5'd2, 5'd30));
      emit(rv_vwmul_vv(5'd4, 5'd2, 5'd1));
      emit(rv_vwredsum_vs(5'd8, 5'd4, 5'd1));
      emit(rv_jal(5'd0, -16));
    end else if (s == 1) begin
      emit_li(5'd7, 32'h0123);
      emit_li(5'd8, 7);
      emit(rv_sw(5'd7, 5'd6, 20));                      // loop start: uart_cfg = 0x0123
      emit(rv_sw(5'd8, 5'd6, 8));                       // result.label = 7
      emit(rv_jal(5'd0, -8));
    end else begin
      emit_li(5'd7, 200);
      emit(rv_sw(5'd7, 5'd6, 20));                      // baud_div = 200
      emit_li(5'd7, 32'h141);
      emit(rv_sw(5'd7, 5'd6, 16));                      // uart_tx.data = 0x41, send = 1
      emit(rv_jal(5'd0, 0));                            // spin
    end
    dmem_fill(TB_DATA_BASE, 4, 32'h0102_0304);
    dmem_wr(TB_RES_BASE + 32'h0, 32'h0);
    dmem_wr(TB_RES_BASE + 32'h8, 32'h0);
    host_load_prog();
    host_end();

    // ---------------- wait for the activity, then abort with an asynchronous reset
    seen = 0;
    if (s == 0) begin
      wait_cycles(40);
      start_pulse(1);                                   // ctrl.start = 1 (cleared by the reset)
      for (tmo = 0; tmo < 3000 && !seen; tmo++) begin
        tick();
        if (m_v_busy && m_v_instr[31:26] == 6'b110001) seen = 1;   // vwredsum in flight
      end
      `TC_CHECK(seen, "s0: vwredsum was never seen in flight")
    end else if (s == 1) begin
      wait_cycles(30);
      for (tmo = 0; tmo < 3000 && !seen; tmo++) begin
        tick();
        if (p_apb_psel === 1'b1 && p_apb_penable !== 1'b1) seen = 1;  // SETUP cycle of a transfer
      end
      `TC_CHECK(seen, "s1: no APB transfer seen")
    end else begin
      for (tmo = 0; tmo < 3000 && !seen; tmo++) begin
        tick();
        if (o_uart_tx === 1'b0) seen = 1;               // start bit
      end
      `TC_CHECK(seen, "s2: UART frame never started")
      wait_cycles(300);                                 // inside the frame (200 clocks per bit)
    end
    rst_assert_offedge();
    wait_cycles(2);
    `TC_CHECK(o_halt === 1'b0 && o_err_illegal === 1'b0, "reset must leave o_halt/o_err_illegal at 0")
    `TC_CHECK(o_sts_done === 1'b0,     "reset must clear sts.done (o_sts_done)")
    `TC_CHECK(o_result_label === 4'h0,  "reset must clear result.label (o_result_label)")
    `TC_CHECK(o_uart_tx === 1'b1,       "reset must abort the UART frame (o_uart_tx = 1)")
    `TC_CHECK(p_apb_psel !== 1'b1 && p_apb_penable !== 1'b1, "reset must abort the APB transfer")
    `TC_CHECK(p_vcmd_valid !== 1'b1 && p_vmem_req !== 1'b1 && p_vresp_done !== 1'b1,
              "reset must abort the vector instruction")
    `TC_CHECK(p_cpu_dmem_req !== 1'b1, "no CPU data request while reset is asserted")
    `TC_CHECK(p_vcyc_cnt === 32'h0,    "reset must clear cycles.cnt")
    uf_a = tb_uart_fall_cnt;
    for (k = 0; k < 40; k++) begin
      tick();
      `TC_CHECK(o_uart_tx === 1'b1 && p_apb_psel !== 1'b1, "UART/APB must stay idle while reset is asserted")
    end
    `TC_CHECK(tb_uart_fall_cnt == uf_a, "UART produced a start bit during reset")

    // ---------------- memories kept: counter and marker in DMEM
    host_rd32(TB_RES_BASE + 32'h8, cnt1);
    `TC_CHECK(cnt1 === 32'd1, "run counter must be 1 after the first (aborted) run")
    host_rd32(TB_RES_BASE + 32'h0, d);
    `TC_CHECK(d === (32'hC0FF_EE00 + s), "DMEM marker must survive the reset")
    // ---------------- IMEM kept: release without reloading, program restarts from PC 0
    host_end();
    wait_cycles(400);
    host_rd32(TB_RES_BASE + 32'h8, cnt2);
    `TC_CHECK(cnt2 === 32'd2, "IMEM must survive the reset: program must restart from PC 0 and run again")

    // ---------------- check program: all CSR/VPU/APB/UART state at reset values, everything works
    prog_reset();
    emit_li(5'd31, chk_base);
    emit_li(5'd6, MMIO_BASE);
    emit(rv_lw(5'd7, 5'd6, 0));   emit(rv_andi(5'd7, 5'd7, 1));      emit_sw_res(5'd7, 0);  // ctrl.start
    emit(rv_lw(5'd7, 5'd6, 4));   emit(rv_andi(5'd7, 5'd7, 7));      emit_sw_res(5'd7, 1);  // sts
    emit(rv_lw(5'd7, 5'd6, 8));   emit(rv_andi(5'd7, 5'd7, 15));     emit_sw_res(5'd7, 2);  // result
    emit(rv_lw(5'd7, 5'd6, 12));                                     emit_sw_res(5'd7, 3);  // cycles
    emit(rv_lw(5'd7, 5'd6, 20));                                     emit_sw_res(5'd7, 4);  // uart_cfg
    emit(rv_lw(5'd7, 5'd6, 16));  emit(rv_andi(5'd7, 5'd7, 32'h300)); emit_sw_res(5'd7, 5);  // uart_tx
    emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(8)));                     emit_sw_res(5'd5, 6);  // vl
    emit_li(5'd8, 32'h5A);
    emit_li(5'd30, TB_DATA_BASE);
    emit(rv_vmv_v_x(5'd2, 5'd8));
    emit(rv_vse8(5'd2, 5'd30));
    emit(rv_lw(5'd10, 5'd30, 0));                                    emit_sw_res(5'd10, 7); // vector store
    emit_li(5'd11, 32'h1234);
    emit(rv_sw(5'd11, 5'd6, 20));                                    // APB write
    emit(rv_lw(5'd12, 5'd6, 20));                                    emit_sw_res(5'd12, 8); // APB readback
    emit_halt();
    host_load_prog();
    uf_a = tb_uart_fall_cnt;
    host_end();
    wait_halt(20000);                                   // includes the post-halt drain (last sw lands in DMEM)
    uf_b = tb_uart_fall_cnt;
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, "check program did not finish after the abort")
    `TC_CHECK(o_err_illegal === 1'b0, "check program must not raise an illegal instruction")
    `TC_CHECK(uf_a == uf_b, "no UART frame may be produced after the aborted one")
    host_rd32(chk_base + 32'd0,  d); `TC_CHECK(d === 32'h0, "ctrl.start must be 0 after reset")
    host_rd32(chk_base + 32'd4,  d); `TC_CHECK(d === 32'h0, "sts busy/done/err must be 0 after reset")
    host_rd32(chk_base + 32'd8,  d); `TC_CHECK(d === 32'h0, "result.label must be 0 after reset")
    host_rd32(chk_base + 32'd12, d); `TC_CHECK(d === 32'h0, "cycles.cnt must be 0 after reset")
    host_rd32(chk_base + 32'd16, d); `TC_CHECK(d === {16'h0, BAUD_DIV_RESET}, "uart_cfg.baud_div must be back at 0x06C8")
    host_rd32(chk_base + 32'd20, d); `TC_CHECK(d === 32'h0, "uart_tx.send/busy must be 0 after reset")
    host_rd32(chk_base + 32'd24, d); `TC_CHECK(d === 32'd16, "vsetvli must work after reset (vl = 16)")
    host_rd32(chk_base + 32'd28, d); `TC_CHECK(d === 32'h5A5A_5A5A, "vector store must work after reset")
    host_rd32(chk_base + 32'd32, d); `TC_CHECK(d === 32'h0000_1234, "APB write/read must work after reset")
    host_rd32(TB_RES_BASE + 32'h0, d);
    `TC_CHECK(d === (32'hC0FF_EE00 + s), "DMEM marker must still be intact after the second reset")
  end
  `TC_CHECK(tb_ldv_cnt == 0,       "i_ld_en must be 0 whenever reset is released")
  `TC_CHECK(tb_out_async_cnt == 0, "status outputs must change only at clock edges while reset is released")
endtask
