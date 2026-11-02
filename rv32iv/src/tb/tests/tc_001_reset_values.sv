// TC-001 | REQ-041, REQ-027
// Reset values: registered level outputs during/after reset, first fetch from PC 0x0, FSMs idle, CSR and VPU
// reset values, first vector / MMIO operations start normally.
task automatic tc_001_reset_values();
  logic [31:0] d;
  int          k;

  // Program at address 0. First instruction = lui x31 (result pointer); marker proves fetch started at PC 0.
  prog_reset();
  emit_res_init();
  emit_li(5'd5, 32'hA5A5_1234);
  emit_sw_res(5'd5, 0);                               // slot0: marker
  emit_li(5'd6, MMIO_BASE);
  emit(rv_lw(5'd7, 5'd6, 12));                        // cycles.cnt before any vector instruction
  emit_sw_res(5'd7, 1);
  emit(rv_lw(5'd7, 5'd6, 0));                         // ctrl
  emit(rv_andi(5'd7, 5'd7, 1));
  emit_sw_res(5'd7, 2);                               // ctrl.start
  emit(rv_lw(5'd7, 5'd6, 4));                         // sts
  emit(rv_andi(5'd7, 5'd7, 7));
  emit_sw_res(5'd7, 3);                               // sts busy/done/err
  emit(rv_lw(5'd7, 5'd6, 8));                         // result
  emit(rv_andi(5'd7, 5'd7, 15));
  emit_sw_res(5'd7, 4);                               // result.label
  emit(rv_lw(5'd7, 5'd6, 20));                        // uart_cfg
  emit_sw_res(5'd7, 5);                               // baud_div reset value
  emit(rv_lw(5'd7, 5'd6, 16));                        // uart_tx
  emit(rv_andi(5'd7, 5'd7, 32'h300));
  emit_sw_res(5'd7, 6);                               // uart_tx.send / busy
  emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(8)));        // first vector operation: vl = VLMAX = 16 at SEW=8
  emit_sw_res(5'd5, 7);
  emit_li(5'd8, 32'h5A);
  emit_li(5'd30, TB_DATA_BASE);
  emit(rv_vmv_v_x(5'd2, 5'd8));
  emit(rv_vse8(5'd2, 5'd30));
  emit(rv_lw(5'd10, 5'd30, 0));
  emit_sw_res(5'd10, 8);                              // 0x5A5A5A5A
  emit_halt();

  host_load_prog();                                   // reset asserted, i_ld_en=1 (host port active in reset)

  // --- during reset
  `TC_CHECK(o_halt === 1'b0,        "o_halt must be 0 during reset")
  `TC_CHECK(o_err_illegal === 1'b0, "o_err_illegal must be 0 during reset")
  `TC_CHECK(o_uart_tx === 1'b1,     "o_uart_tx must be 1 (idle) during reset")
  `TC_CHECK(o_sts_done === 1'b0,    "o_sts_done must be 0 during reset")
  `TC_CHECK(o_result_label === 4'h0, "o_result_label must be 0 during reset")
  wait_cycles(3);
  `TC_CHECK(o_halt === 1'b0 && o_err_illegal === 1'b0 && o_sts_done === 1'b0 && o_result_label === 4'h0 &&
            o_uart_tx === 1'b1, "reset values must be stable while reset is held")
  `TC_CHECK(p_apb_psel !== 1'b1 && p_vcmd_valid !== 1'b1 && p_vmem_req !== 1'b1,
            "APB / VPU FSMs must be idle during reset")

  // --- release and look at the first cycles: outputs still at reset values, FSMs idle
  host_end();
  for (k = 0; k < 3; k++) begin
    tick();
    `TC_CHECK(o_halt === 1'b0 && o_err_illegal === 1'b0, "o_halt/o_err_illegal must stay 0 right after reset release")
    `TC_CHECK(o_sts_done === 1'b0 && o_result_label === 4'h0, "o_sts_done/o_result_label must stay 0 after release")
    `TC_CHECK(o_uart_tx === 1'b1, "o_uart_tx must stay 1 after release")
    `TC_CHECK(p_apb_psel !== 1'b1 && p_vcmd_valid !== 1'b1 && p_vmem_req !== 1'b1 && p_cpu_dmem_req !== 1'b1,
              "no APB / VPU / data activity expected in the first cycles after release (FSMs idle)")
  end

  wait_halt(5000);                                    // includes the post-halt drain (last sw lands in DMEM)
  `TC_CHECK(tb_run_hit, "program did not reach ebreak (fetch did not start at PC 0?)")
  `TC_CHECK(o_halt === 1'b1,        "o_halt must be 1 after ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "ebreak must not set o_err_illegal")
  `TC_CHECK(tb_sts_err_events == 0, "no sts.err event expected for a clean program")
  `TC_CHECK(tb_uart_fall_cnt == 0,  "no UART start bit expected after reset")

  res_rd(0, d); `TC_CHECK(d === 32'hA5A5_1234, "marker not written: first instruction not fetched from PC 0x0")
  res_rd(1, d); `TC_CHECK(d === 32'h0,         "cycles.cnt reset value must be 0")
  res_rd(2, d); `TC_CHECK(d === 32'h0,         "ctrl.start reset value must be 0")
  res_rd(3, d); `TC_CHECK(d === 32'h0,         "sts.busy/done/err reset value must be 0")
  res_rd(4, d); `TC_CHECK(d === 32'h0,         "result.label reset value must be 0")
  res_rd(5, d); `TC_CHECK(d === {16'h0, BAUD_DIV_RESET}, "uart_cfg.baud_div reset value must be 0x06C8")
  res_rd(6, d); `TC_CHECK(d === 32'h0,         "uart_tx.send/busy reset value must be 0")
  res_rd(7, d); `TC_CHECK(d === 32'd16,        "first vsetvli e8 must return VLMAX=16")
  res_rd(8, d); `TC_CHECK(d === 32'h5A5A_5A5A, "first vector store (vmv.v.x + vse8) must work after reset")
  mon_check_all();
endtask
