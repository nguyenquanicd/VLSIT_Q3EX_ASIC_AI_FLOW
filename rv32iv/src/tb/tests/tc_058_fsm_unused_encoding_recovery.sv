// TC-058 | REQ-036, REQ-038, REQ-037
// Unused FSM encodings recover to IDLE. The FSM state registers named by the spec convention
// (reg_fsm_<fn>_current_state) are forced to an unused code for one clock cycle while the FSM is idle, then released;
// the FSM must return to its IDLE code, produce no spurious activity, and a vector instruction, an MMIO access and a
// UART byte must still complete normally.
//   m_vpu_ctrl  (3 bits, codes 6 and 7 unused)     m_apb_master apbm (code 3 unused)     m_uart uart (code 7)
// The hierarchical paths can be overridden with +define+TB_FSM_VCTRL / TB_FSM_APBM / TB_FSM_UART=<path>.
// +define+TB_NO_FSM_FORCE removes the force (the TC then only checks idle-after-reset and normal operation).
// m_vpu_lsu's FSM (REQ-037) has no unused code and is exercised by the vector load/store in the check program.
// The forced codes are literals: force may not use automatic variables (the TC task is automatic) and the type()
// operator may not take a hierarchical reference.
`ifndef TB_FSM_VCTRL
 `define TB_FSM_VCTRL dut.u_vpu_top.u_vpu_ctrl.reg_fsm_vctrl_current_state
`endif
`ifndef TB_FSM_APBM
 `define TB_FSM_APBM dut.u_apb_master.reg_fsm_apbm_current_state
`endif
`ifndef TB_FSM_UART
 `define TB_FSM_UART dut.u_uart.reg_fsm_uart_current_state
`endif
task automatic tc_058_fsm_unused_encoding_recovery();
  logic [31:0] d, idle_v;
  int          run, k, which, code;
  bit          first_load;

  // ---- program: idle busy loop (FSMs idle, force window), then vector + MMIO + UART operations
  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd1, 1500);
  emit(rv_addi(5'd1, 5'd1, -1));                  // loop: ~4500 cycles with no VPU / APB / UART activity
  emit(rv_bne(5'd1, 5'd0, -4));
  emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(8)));
  emit_sw_res(5'd5, 0);                           // slot0: vl = 16
  emit_li(5'd8, 32'h5A);
  emit_li(5'd30, TB_DATA_BASE);
  emit(rv_vmv_v_x(5'd2, 5'd8));
  emit(rv_vse8(5'd2, 5'd30));
  emit(rv_lw(5'd10, 5'd30, 0));
  emit_sw_res(5'd10, 1);                          // slot1: 0x5A5A5A5A
  emit_li(5'd7, 4);
  emit(rv_sw(5'd7, 5'd6, 20));                    // baud_div = 4
  emit(rv_lw(5'd9, 5'd6, 20));
  emit_sw_res(5'd9, 2);                           // slot2: 4 (APB write + read)
  emit_li(5'd7, 32'h141);
  emit(rv_sw(5'd7, 5'd6, 16));                    // uart_tx: data 0x41, send
  emit(rv_lw(5'd8, 5'd6, 16));                    // poll until send and busy are both clear
  emit(rv_andi(5'd8, 5'd8, 32'h300));
  emit(rv_bne(5'd8, 5'd0, -8));
  emit_halt();

  first_load = 1;
  // run 0..3: vctrl code 6, vctrl code 7, apbm code 3, uart code 7
  for (run = 0; run < 4; run++) begin
    which = (run < 2) ? 0 : (run == 2 ? 1 : 2);
    code  = (run == 0) ? 6 : (run == 1 ? 7 : (run == 2 ? 3 : 7));
    if (first_load) begin
      dmem_fill(TB_DATA_BASE, 4, 32'h0);
      host_load_prog();
      first_load = 0;
    end else begin
      host_begin();
    end
    dmem_fill(TB_RES_BASE, 8, 32'h0);             // stale results from the previous run must not count
    tb_uart_baud = 4;
    host_end();
    wait_cycles(40);                              // CPU is in the idle loop; all FSMs idle

    // FSMs idle before the force
    `TC_CHECK(p_apb_psel !== 1'b1 && p_vcmd_valid !== 1'b1 && p_vmem_req !== 1'b1 && o_uart_tx === 1'b1,
              "FSMs must be idle during the idle loop")
`ifndef TB_NO_FSM_FORCE
    case (which)
      0: begin
        idle_v = 32'(`TB_FSM_VCTRL);
        if (code == 6) force `TB_FSM_VCTRL = 6;   // unused 3-bit code 6
        else           force `TB_FSM_VCTRL = 7;   // unused 3-bit code 7
        tick();
        release `TB_FSM_VCTRL;
        for (k = 0; k < 4; k++) tick();
        `TC_CHECK(32'(`TB_FSM_VCTRL) === idle_v,
                  $sformatf("m_vpu_ctrl did not recover to IDLE (%0d) from unused code %0d, now %0d",
                            idle_v, code, 32'(`TB_FSM_VCTRL)))
      end
      1: begin
        idle_v = 32'(`TB_FSM_APBM);
        force `TB_FSM_APBM = 3;                   // unused 2-bit code 3
        tick();
        release `TB_FSM_APBM;
        for (k = 0; k < 4; k++) tick();
        `TC_CHECK(32'(`TB_FSM_APBM) === idle_v,
                  $sformatf("m_apb_master did not recover to IDLE (%0d) from unused code %0d, now %0d",
                            idle_v, code, 32'(`TB_FSM_APBM)))
      end
      default: begin
        idle_v = 32'(`TB_FSM_UART);
        force `TB_FSM_UART = 7;                   // unused code 7
        tick();
        release `TB_FSM_UART;
        for (k = 0; k < 4; k++) tick();
        `TC_CHECK(32'(`TB_FSM_UART) === idle_v,
                  $sformatf("m_uart did not recover to IDLE (%0d) after forced code %0d, now %0d",
                            idle_v, code, 32'(`TB_FSM_UART)))
      end
    endcase
`endif
    // no spurious activity after the recovery
    for (k = 0; k < 10; k++) begin
      tick();
      `TC_CHECK(p_vresp_done !== 1'b1 && p_vmem_req !== 1'b1 && p_apb_psel !== 1'b1 && p_apb_penable !== 1'b1 &&
                o_uart_tx === 1'b1, "spurious VPU/APB/UART activity after FSM recovery")
    end
    `TC_CHECK(tb_uart_fall_cnt == 0, "spurious UART start bit after FSM recovery")

    // everything still works: vector instruction, MMIO access, UART byte
    wait_halt(40000);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("run %0d: program did not finish (hang after FSM recovery?)", run))
    `TC_CHECK(o_err_illegal === 1'b0, "unexpected illegal instruction")
    uart_wait_frames(1, 2000);
    `TC_CHECK(tb_uart_rx_data.size() == 1, $sformatf("run %0d: expected one UART frame, got %0d", run, tb_uart_rx_data.size()))
    if (tb_uart_rx_data.size() >= 1) begin
      `TC_CHECK(tb_uart_rx_data[0] === 8'h41, "UART byte must be 0x41")
      `TC_CHECK(tb_uart_rx_start_ok[0] && tb_uart_rx_stop_ok[0] && tb_uart_rx_len_ok[0], "UART frame malformed")
    end
    res_rd(0, d); `TC_CHECK(d === 32'd16,        "vsetvli result wrong after FSM recovery")
    res_rd(1, d); `TC_CHECK(d === 32'h5A5A_5A5A, "vector store result wrong after FSM recovery")
    res_rd(2, d); `TC_CHECK(d === 32'd4,         "APB write/read wrong after FSM recovery")
    tb_uart_baud = 0;
    mon_check_all();                              // spurious done / APB / memory activity would show up here
    mon_clear();                                  // the next run starts with fresh monitor state
  end
endtask
