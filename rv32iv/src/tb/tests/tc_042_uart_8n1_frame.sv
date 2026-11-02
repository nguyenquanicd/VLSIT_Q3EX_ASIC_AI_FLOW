// TC-042 | REQ-012, REQ-063
// UART 8N1 transmit: one program per baud divisor (1, 2, 3, 8, 100 and the reset value 0x06C8). The firmware writes
// uart_cfg.baud_div, then for every byte polls uart_tx.busy/send until both are 0 and writes {send=1, data}.
// The TB frame decoder (tb_uart_* monitor, bit time = divisor) checks per frame: idle high, start bit 0, 8 data bits
// LSB first, stop bit 1, every bit slot exactly baud_div clocks (10 bit times). Further checks:
//   - frames == bytes written, data equal, back-to-back after polling busy
//   - uart_tx.busy = 1 while the first frame is on the wire (divisors >= 8; shorter frames can finish before the
//     firmware reads), busy and send are 0 after the last frame (send cleared when the byte was taken)
task automatic tc_042_uart_8n1_frame();
  int          dvs [0:5];
  logic [7:0]  bytes [0:13];
  int          nb, nbytes, di, i, tmo;
  logic [31:0] d;

  dvs[0] = 1;  dvs[1] = 2;  dvs[2] = 3;  dvs[3] = 8;  dvs[4] = 100;  dvs[5] = 32'h06C8;
  bytes[0]  = 8'h00;  bytes[1]  = 8'hFF;  bytes[2]  = 8'h55;  bytes[3]  = 8'hAA;
  for (i = 0; i < 10; i++) bytes[4 + i] = 8'h30 + 8'(i);

  for (di = 0; di < 6; di++) begin
    // the slow default divisor sends 3 bytes only (a frame takes 17,360 clocks)
    nbytes = (di == 5) ? 3 : 14;
    prog_reset();
    emit_res_init();
    emit_li(5'd6, MMIO_BASE);
    emit_li(5'd7, 32'(dvs[di]));
    emit(rv_sw(5'd7, 5'd6, 20));                          // uart_cfg.baud_div
    for (i = 0; i < nbytes; i++) begin
      // wait until neither busy (bit 9) nor send (bit 8) is set
      emit(rv_lw(5'd8, 5'd6, 16));
      emit(rv_andi(5'd8, 5'd8, 32'h300));
      emit(rv_bne(5'd8, 5'd0, -8));
      emit_li(5'd7, 32'h100 | 32'(bytes[(di == 5) ? (i + 2) : i]));
      emit(rv_sw(5'd7, 5'd6, 16));                        // data + send
      if (i == 0) begin
        emit(rv_lw(5'd10, 5'd6, 16));                     // status right after the send write
        emit_sw_res(5'd10, 0);
      end
    end
    emit(rv_lw(5'd8, 5'd6, 16));                          // wait for the last frame to finish
    emit(rv_andi(5'd8, 5'd8, 32'h300));
    emit(rv_bne(5'd8, 5'd0, -8));
    emit(rv_lw(5'd10, 5'd6, 16));
    emit_sw_res(5'd10, 1);                                // busy / send / data after the last frame
    emit_halt();

    // frames decoded for the previous divisor must not leak into this one: clear the decoder queues
    tb_uart_rx_data.delete();
    tb_uart_rx_start_ok.delete();
    tb_uart_rx_stop_ok.delete();
    tb_uart_rx_len_ok.delete();
    tb_uart_rx_cyc.delete();
    tb_uart_baud = dvs[di];                               // decoder bit time, set before the first frame
    host_load_prog();
    host_end();
    tmo = nbytes * (10 * dvs[di] + 80) + 4000;
    wait_halt(tmo);
    uart_wait_frames(nbytes, 2 * dvs[di] + 200);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("divisor %0d: program did not reach ebreak", dvs[di]))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("divisor %0d: illegal instruction", dvs[di]))
    `TC_CHECK(tb_uart_rx_data.size() == nbytes,
              $sformatf("divisor %0d: %0d frames decoded, expected %0d", dvs[di], tb_uart_rx_data.size(), nbytes))
    `TC_CHECK(o_uart_tx === 1'b1, $sformatf("divisor %0d: o_uart_tx not idle high after the last frame", dvs[di]))
    for (i = 0; i < nbytes && i < tb_uart_rx_data.size(); i++) begin
      nb = (di == 5) ? (i + 2) : i;
      `TC_CHECK(tb_uart_rx_data[i] === bytes[nb],
                $sformatf("divisor %0d frame %0d: data %02h, expected %02h", dvs[di], i, tb_uart_rx_data[i], bytes[nb]))
      `TC_CHECK(tb_uart_rx_start_ok[i], $sformatf("divisor %0d frame %0d: start bit is not 0", dvs[di], i))
      `TC_CHECK(tb_uart_rx_stop_ok[i],  $sformatf("divisor %0d frame %0d: stop bit is not 1", dvs[di], i))
      `TC_CHECK(tb_uart_rx_len_ok[i],
                $sformatf("divisor %0d frame %0d: a bit slot is not exactly %0d clocks (10 bit times per byte)", dvs[di], i, dvs[di]))
    end
    res_rd(0, d);
    if (dvs[di] >= 8) `TC_CHECK(d[9] === 1'b1, $sformatf("divisor %0d: uart_tx.busy not set right after the send write (%08h)", dvs[di], d))
    res_rd(1, d);
    `TC_CHECK(d[9:8] === 2'b00, $sformatf("divisor %0d: busy/send still set after the last frame (%08h): send must clear when the byte is taken", dvs[di], d))
    tb_uart_baud = 0;
  end
  mon_check_all();
endtask
