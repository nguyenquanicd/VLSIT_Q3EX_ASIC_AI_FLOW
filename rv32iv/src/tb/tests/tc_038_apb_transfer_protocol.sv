// TC-038 | REQ-016, REQ-028, REQ-029, REQ-030
// APB transfers of single and back-to-back MMIO accesses (probe of m_apb_master ports):
//   SETUP (PSEL only) then ACCESS (PENABLE), PADDR = CPU address - 0x2000_0000 (low 2 bits kept), PWRITE/PWDATA/PSTRB
//   stable until PREADY, PPROT = 0, one outstanding transfer, PSTRB = 4'b1111 for aligned sw, at least 3 PSEL cycles
//   per transfer, i_dmem_ack not before PREADY (the always-on monitor), and a younger DMEM store never issues while
//   a transfer is in progress (CPU pipeline stalled until completion).
task automatic tc_038_apb_transfer_protocol();
  logic [15:0] e_off [0:15];
  bit          e_wr  [0:15];
  logic [31:0] e_wd  [0:15];
  logic [31:0] e_rd  [0:15];     // expected read-back, 32'hx = not checked
  logic [31:0] d;
  int          ne, i, n, viol_young, k;

  ne = 0;
  prog_reset();
  emit_res_init();
  emit_li(5'd6, MMIO_BASE);
  emit_li(5'd30, TB_DATA_BASE);

  // 0: W uart_cfg 0x1111, younger DMEM store
  emit_li(5'd7, 32'h1111);  emit(rv_sw(5'd7, 5'd6, 20));  emit(rv_sw(5'd7, 5'd30, 0));
  e_off[ne] = 16'h14; e_wr[ne] = 1; e_wd[ne] = 32'h1111; e_rd[ne] = 32'hx; ne++;
  // 1: R uart_cfg
  emit(rv_lw(5'd8, 5'd6, 20));  emit_sw_res(5'd8, 1);
  e_off[ne] = 16'h14; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h1111; ne++;
  // 2: W result 5, younger DMEM store
  emit_li(5'd7, 32'h5);  emit(rv_sw(5'd7, 5'd6, 8));  emit(rv_sw(5'd7, 5'd30, 4));
  e_off[ne] = 16'h08; e_wr[ne] = 1; e_wd[ne] = 32'h5; e_rd[ne] = 32'hx; ne++;
  // 3: R result
  emit(rv_lw(5'd8, 5'd6, 8));  emit_sw_res(5'd8, 3);
  e_off[ne] = 16'h08; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h5; ne++;
  // 4..6: three back-to-back reads (sts, uart_cfg, result)
  emit(rv_lw(5'd8, 5'd6, 4));
  emit(rv_lw(5'd9, 5'd6, 20));  emit_sw_res(5'd9, 5);
  emit(rv_lw(5'd10, 5'd6, 8));  emit_sw_res(5'd10, 6);
  e_off[ne] = 16'h04; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'hx;    ne++;
  e_off[ne] = 16'h14; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h1111; ne++;
  e_off[ne] = 16'h08; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h5;    ne++;
  // 7, 8: two back-to-back writes
  emit_li(5'd7, 32'h2222);  emit_li(5'd11, 32'h7);
  emit(rv_sw(5'd7, 5'd6, 20));
  emit(rv_sw(5'd11, 5'd6, 8));
  emit(rv_sw(5'd7, 5'd30, 8));                       // younger DMEM store
  e_off[ne] = 16'h14; e_wr[ne] = 1; e_wd[ne] = 32'h2222; e_rd[ne] = 32'hx; ne++;
  e_off[ne] = 16'h08; e_wr[ne] = 1; e_wd[ne] = 32'h7;    e_rd[ne] = 32'hx; ne++;
  // 9, 10: read back both
  emit(rv_lw(5'd8, 5'd6, 20));  emit_sw_res(5'd8, 9);
  emit(rv_lw(5'd9, 5'd6, 8));   emit_sw_res(5'd9, 10);
  e_off[ne] = 16'h14; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h2222; ne++;
  e_off[ne] = 16'h08; e_wr[ne] = 0; e_wd[ne] = 32'h0; e_rd[ne] = 32'h7;    ne++;
  // restore the reset value of uart_cfg
  emit_li(5'd7, 32'h06C8);  emit(rv_sw(5'd7, 5'd6, 20));
  e_off[ne] = 16'h14; e_wr[ne] = 1; e_wd[ne] = 32'h06C8; e_rd[ne] = 32'hx; ne++;
  emit_halt();

  // manual run so that APB activity and CPU data requests can be sampled together
  host_load_prog();
  host_end();
  n = 0;
  viol_young = 0;
  while (o_halt !== 1'b1 && n < 5000) begin
    tick();
    n++;
    if (p_apb_psel === 1'b1 && p_cpu_dmem_req === 1'b1 && p_cpu_dmem_wr === 1'b1 && p_cpu_dmem_adr[31:28] === 4'h1)
      viol_young++;
  end
  tb_run_hit    = (o_halt === 1'b1);
  tb_run_cycles = tb_cycle - tb_rel_cycle;
  if (tb_run_hit) drain_halted();

  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (CPU hung on an MMIO access?)")
  `TC_CHECK(o_err_illegal === 1'b0, "unexpected illegal instruction")
  `TC_CHECK(tb_apb_log_n == ne, $sformatf("%0d APB transfers seen, expected %0d", tb_apb_log_n, ne))
  `TC_CHECK(viol_young == 0, "a younger DMEM store was issued while an APB transfer was in progress")
  `TC_CHECK(tb_apb_min_len >= 3,
            $sformatf("shortest APB transfer has %0d PSEL cycles, expected >= 3 (SETUP + ACCESS + latency)", tb_apb_min_len))
  for (i = 0; i < ne && i < tb_apb_log_n; i++) begin
    `TC_CHECK(tb_apb_log_addr[i] === e_off[i],
              $sformatf("transfer %0d: PADDR %04h, expected %04h (CPU address - 0x2000_0000)", i, tb_apb_log_addr[i], e_off[i]))
    `TC_CHECK(tb_apb_log_write[i] === e_wr[i], $sformatf("transfer %0d: PWRITE %0d, expected %0d", i, tb_apb_log_write[i], e_wr[i]))
    `TC_CHECK(tb_apb_log_slverr[i] === 1'b0, $sformatf("transfer %0d: unexpected PSLVERR", i))
    `TC_CHECK(tb_apb_log_len[i] >= 3, $sformatf("transfer %0d: only %0d PSEL cycles", i, tb_apb_log_len[i]))
    if (e_wr[i]) begin
      `TC_CHECK(tb_apb_log_pstrb[i] === 4'b1111, $sformatf("transfer %0d: PSTRB %b for an aligned sw", i, tb_apb_log_pstrb[i]))
      `TC_CHECK(tb_apb_log_wdata[i] === e_wd[i],
                $sformatf("transfer %0d: PWDATA %08h, expected %08h", i, tb_apb_log_wdata[i], e_wd[i]))
    end
  end
  // read data delivered to the CPU (write-back after the stall)
  for (k = 0; k < 11; k++) begin
    case (k)
      1:  begin res_rd(1,  d); `TC_CHECK(d === 32'h1111, $sformatf("read of uart_cfg returned %08h", d)) end
      3:  begin res_rd(3,  d); `TC_CHECK(d === 32'h5,    $sformatf("read of result returned %08h", d)) end
      5:  begin res_rd(5,  d); `TC_CHECK(d === 32'h1111, $sformatf("back-to-back read 2 returned %08h", d)) end
      6:  begin res_rd(6,  d); `TC_CHECK(d === 32'h5,    $sformatf("back-to-back read 3 returned %08h", d)) end
      9:  begin res_rd(9,  d); `TC_CHECK(d === 32'h2222, $sformatf("read after back-to-back writes (uart_cfg) = %08h", d)) end
      10: begin res_rd(10, d); `TC_CHECK(d === 32'h7,    $sformatf("read after back-to-back writes (result) = %08h", d)) end
      default: ;
    endcase
  end
  mon_check_all();                                    // PSEL/PENABLE order, stability, PPROT, early ack, one outstanding
endtask
