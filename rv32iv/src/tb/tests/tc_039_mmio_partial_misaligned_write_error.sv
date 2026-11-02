// TC-039 | REQ-055, REQ-056, REQ-016, REQ-017
// Partial and misaligned writes to every CSR: sb (+0, +3), sh (+0, +2) and sw at +1/+2/+3 -- 7 variants x 6 CSRs = 42.
// They reach the APB master (not blocked in the LSU) with PSTRB = the CPU byte enables shifted by addr[1:0]
// (never 4'b1111) and the low address bits kept on PADDR; the CSR answers PSLVERR, m_apb_master pulses o_sts_err_set
// once per error (1 cycle), sts.err becomes 1, no register is modified, the CPU gets a normal ack (no hang, no halt,
// o_err_illegal = 0). The aligned setup writes / readbacks give no pulse.
task automatic tc_039_mmio_partial_misaligned_write_error();
  int          csr_off [0:5];
  int          v_kind  [0:6];       // 0 sb, 1 sh, 2 sw
  int          v_add   [0:6];
  logic [3:0]  v_stb   [0:6];
  logic [31:0] d;
  int          c, v, idx, ne;

  csr_off[0] = 0;  csr_off[1] = 4;  csr_off[2] = 8;  csr_off[3] = 12;  csr_off[4] = 16;  csr_off[5] = 20;
  v_kind[0] = 0; v_add[0] = 0; v_stb[0] = 4'b0001;    // sb  +0
  v_kind[1] = 0; v_add[1] = 3; v_stb[1] = 4'b1000;    // sb  +3
  v_kind[2] = 1; v_add[2] = 0; v_stb[2] = 4'b0011;    // sh  +0
  v_kind[3] = 1; v_add[3] = 2; v_stb[3] = 4'b1100;    // sh  +2
  v_kind[4] = 2; v_add[4] = 1; v_stb[4] = 4'b1110;    // sw  +1 (misaligned)
  v_kind[5] = 2; v_add[5] = 2; v_stb[5] = 4'b1100;    // sw  +2
  v_kind[6] = 2; v_add[6] = 3; v_stb[6] = 4'b1000;    // sw  +3

  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit(rv_addi(5'd7, 5'd0, -1));                      // x7 = 0xFFFF_FFFF: data that would change every field
  // 5 aligned setup writes: ctrl=0, sts=0, result=0xA, uart_cfg=0x1234, uart_tx=0
  emit(rv_sw(5'd0, 5'd6, 0));
  emit(rv_sw(5'd0, 5'd6, 4));
  emit_li(5'd8, 32'hA);     emit(rv_sw(5'd8, 5'd6, 8));
  emit_li(5'd8, 32'h1234);  emit(rv_sw(5'd8, 5'd6, 20));
  emit(rv_sw(5'd0, 5'd6, 16));
  // 42 partial / misaligned writes
  for (c = 0; c < 6; c++) begin
    for (v = 0; v < 7; v++) begin
      if (v_kind[v] == 0)      emit(rv_sb(5'd7, 5'd6, csr_off[c] + v_add[v]));
      else if (v_kind[v] == 1) emit(rv_sh(5'd7, 5'd6, csr_off[c] + v_add[v]));
      else                     emit(rv_sw(5'd7, 5'd6, csr_off[c] + v_add[v]));
    end
  end
  // read back (aligned): nothing may have been modified, sts.err = 1
  emit(rv_lw(5'd9, 5'd6, 0));                         emit_sw_res(5'd9, 0);
  emit(rv_lw(5'd9, 5'd6, 4));                         emit_sw_res(5'd9, 1);
  emit(rv_lw(5'd9, 5'd6, 8));                         emit_sw_res(5'd9, 2);
  emit(rv_lw(5'd9, 5'd6, 20));                        emit_sw_res(5'd9, 3);
  emit(rv_lw(5'd9, 5'd6, 16));  emit(rv_andi(5'd9, 5'd9, 32'h3FF));  emit_sw_res(5'd9, 4);
  emit_halt();

  run_prog(20000);                                    // includes the post-halt drain
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (hang on a partial write?)")
  `TC_CHECK(o_err_illegal === 1'b0, "partial MMIO writes must not raise o_err_illegal (no halt, normal ack)")
  `TC_CHECK(tb_apb_log_n == 52, $sformatf("%0d APB transfers, expected 52 (5 setup + 42 partial + 5 readback)", tb_apb_log_n))
  `TC_CHECK(tb_apb_slverr_cnt == 42, $sformatf("%0d transfers with PSLVERR, expected 42", tb_apb_slverr_cnt))
  `TC_CHECK(tb_errpulse_cnt == 42, $sformatf("%0d o_sts_err_set pulses, expected one per PSLVERR (42)", tb_errpulse_cnt))
  `TC_CHECK(tb_errpulse_long_cnt == 0, "o_sts_err_set must be a 1-cycle pulse")
  `TC_CHECK(tb_sts_err_events == 42, $sformatf("%0d sts.err hardware-set events, expected 42", tb_sts_err_events))

  for (idx = 0; idx < 5; idx++) begin                 // aligned setup writes: PSTRB = 1111, no error
    `TC_CHECK(tb_apb_log_write[idx] === 1'b1 && tb_apb_log_pstrb[idx] === 4'b1111 && tb_apb_log_slverr[idx] === 1'b0,
              $sformatf("setup write %0d: PSTRB %b slverr %0d (aligned sw must be 1111 without error)",
                        idx, tb_apb_log_pstrb[idx], tb_apb_log_slverr[idx]))
  end
  ne = 5;
  for (c = 0; c < 6; c++) begin
    for (v = 0; v < 7; v++) begin
      `TC_CHECK(tb_apb_log_write[ne] === 1'b1, $sformatf("transfer %0d: expected a write", ne))
      `TC_CHECK(tb_apb_log_pstrb[ne] === v_stb[v],
                $sformatf("CSR offset %0d variant %0d: PSTRB %b, expected %b", csr_off[c], v, tb_apb_log_pstrb[ne], v_stb[v]))
      `TC_CHECK(tb_apb_log_pstrb[ne] !== 4'b1111, $sformatf("transfer %0d: partial write with PSTRB 1111", ne))
      `TC_CHECK(tb_apb_log_addr[ne] === 16'(csr_off[c] + v_add[v]),
                $sformatf("transfer %0d: PADDR %04h, expected %04h (low bits kept)", ne, tb_apb_log_addr[ne], csr_off[c] + v_add[v]))
      `TC_CHECK(tb_apb_log_slverr[ne] === 1'b1, $sformatf("transfer %0d: no PSLVERR for a partial/misaligned write", ne))
      ne++;
    end
  end

  res_rd(0, d); `TC_CHECK(d === 32'h0,      "ctrl modified by a partial write")
  res_rd(1, d); `TC_CHECK(d === 32'h4,      $sformatf("sts = %08h, expected 4 (err set, busy/done untouched)", d))
  res_rd(2, d); `TC_CHECK(d === 32'hA,      "result.label modified by a partial write")
  res_rd(3, d); `TC_CHECK(d === 32'h1234,   "uart_cfg modified by a partial write")
  res_rd(4, d); `TC_CHECK(d === 32'h0,      "uart_tx modified / byte sent by a partial write")
  `TC_CHECK(tb_uart_fall_cnt == 0, "a partial write to uart_tx started a UART frame")
  mon_check_all();
endtask
