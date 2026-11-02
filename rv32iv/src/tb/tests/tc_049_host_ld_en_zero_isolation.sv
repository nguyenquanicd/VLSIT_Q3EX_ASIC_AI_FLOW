// TC-049 | REQ-018, REQ-011
// With i_ld_en = 0 and reset released the host port must be invisible: i_ld_req / i_ld_wr_en / i_ld_addr /
// i_ld_byte_en / i_ld_wr_data are toggled randomly every cycle (addresses hit the program, the data area, the
// result area and MMIO on purpose) while a CPU + vector program runs. IMEM and DMEM must be unaffected, results
// identical and the CPU DMEM timing identical (same time-to-halt as with i_ld_* tied to 0).
//   run 0 : quiet (host inputs 0), program loaded
//   run 1 : noise, IMEM NOT reloaded (a corrupted IMEM would show here or in run 3)
//   run 2 : noise again
//   run 3 : quiet again, IMEM still NOT reloaded
task automatic tc_049_host_ld_en_zero_isolation();
  longint unsigned t [0:3];
  logic [31:0] hot [0:15];
  logic [31:0] rnd, rnd2, d;
  int          run, n, k;

  hot[0]  = 32'h0000_0000;          hot[1]  = 32'h0000_0004;          hot[2]  = 32'h0000_0020;
  hot[3]  = 32'h0000_0040;          hot[4]  = TB_DATA_BASE;           hot[5]  = TB_DATA_BASE + 32'h4;
  hot[6]  = TB_DATA_BASE + 32'h8;   hot[7]  = TB_DATA_BASE + 32'hC;   hot[8]  = TB_DATA_BASE + 32'h100;
  hot[9]  = TB_DATA_BASE + 32'h110; hot[10] = TB_RES_BASE;            hot[11] = TB_RES_BASE + 32'h4;
  hot[12] = TB_RES_BASE + 32'h8;    hot[13] = CSR_RESULT;             hot[14] = CSR_UART_CFG;
  hot[15] = CSR_STS;

  // ---- program: scalar loop with DMEM store/load, then a vector dot product
  prog_reset();
  emit_res_init();
  emit_li(5'd30, TB_DATA_BASE);
  emit_li(5'd29, TB_DATA_BASE + 32'h100);
  emit(rv_addi(5'd1, 5'd0, 20));
  emit(rv_addi(5'd2, 5'd0, 0));
  emit(rv_add (5'd2, 5'd2, 5'd1));                 // loop: x2 += x1
  emit(rv_sw  (5'd2, 5'd29, 16));
  emit(rv_lw  (5'd3, 5'd29, 16));
  emit(rv_add (5'd2, 5'd3, 5'd0));
  emit(rv_addi(5'd1, 5'd1, -1));
  emit(rv_bne (5'd1, 5'd0, -20));
  emit_sw_res(5'd2, 0);                            // 210
  emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(8)));
  emit(rv_vle8(5'd1, 5'd30));
  emit(rv_vle8(5'd2, 5'd30));
  emit(rv_vmv_v_x(5'd3, 5'd0));
  emit(rv_vwmul_vv(5'd4, 5'd2, 5'd1));
  emit(rv_vwredsum_vs(5'd8, 5'd4, 5'd3));
  emit(rv_vse8(5'd1, 5'd29));
  emit(rv_vsetvli(5'd5, 5'd0, vtype_zimm(32)));
  emit(rv_vmv_x_s(5'd6, 5'd8));
  emit_sw_res(5'd6, 1);                            // 4 * (16 + 9 + 4 + 1) = 120
  emit(rv_lw(5'd7, 5'd29, 0));
  emit_sw_res(5'd7, 2);                            // 0x01020304 copied through the VPU
  emit_halt();

  for (k = 0; k < 4; k++) dmem_wr(TB_DATA_BASE + 32'(4 * k), 32'h0102_0304);

  for (run = 0; run < 4; run++) begin
    if (run == 0) host_load_prog();
    else          host_begin();
    for (k = 0; k < 3; k++) dmem_wr(TB_RES_BASE + 32'(4 * k), 32'hDEAD_0000 + k);
    host_end();

    if (run == 1 || run == 2) begin
      // noise on every host input, i_ld_en stays 0
      n = 0;
      while (o_halt !== 1'b1 && n < 20000) begin
        rnd  = tb_rand32();
        rnd2 = tb_rand32();
        i_ld_en      = 1'b0;
        i_ld_req     = rnd[0];
        i_ld_wr_en   = rnd[1] | rnd[2];
        i_ld_addr    = rnd2[8] ? (hot[rnd2[15:12]] + {30'h0, rnd2[1:0]}) : tb_rand32();
        i_ld_byte_en = rnd2[19:16];
        i_ld_wr_data = rnd2[20] ? tb_rand32() : 32'h0010_0073;     // random or an ebreak encoding
        tick();
        n++;
      end
      i_ld_req     = 1'b0;
      i_ld_wr_en   = 1'b0;
      i_ld_addr    = 32'h0;
      i_ld_byte_en = 4'h0;
      i_ld_wr_data = 32'h0;
      tb_run_hit    = (o_halt === 1'b1);
      tb_run_cycles = tb_cycle - tb_rel_cycle;        // first o_halt cycle, same definition as wait_halt()
      if (tb_run_hit) drain_halted();                 // last store lands before the host access below
    end else begin
      wait_halt(20000);                               // includes the post-halt drain
    end
    t[run] = tb_run_cycles;
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("run %0d did not halt (IMEM disturbed by the host port?)", run))
    `TC_CHECK(o_err_illegal === 1'b0,        $sformatf("run %0d: illegal instruction (IMEM disturbed?)", run))
    res_rd(0, d); `TC_CHECK(d === 32'd210,       $sformatf("run %0d: scalar loop result %0d, expected 210", run, d))
    res_rd(1, d); `TC_CHECK(d === 32'd120,       $sformatf("run %0d: vector dot product %0d, expected 120", run, d))
    res_rd(2, d); `TC_CHECK(d === 32'h0102_0304, $sformatf("run %0d: vector copy %08h, expected 01020304", run, d))
    for (k = 0; k < 4; k++) begin
      dmem_rd(TB_DATA_BASE + 32'(4 * k), d);
      `TC_CHECK(d === 32'h0102_0304, $sformatf("run %0d: DMEM data word %0d changed by host-port noise: %08h", run, k, d))
    end
  end

  for (run = 1; run < 4; run++)
    `TC_CHECK(t[run] == t[0],
              $sformatf("time-to-halt differs: run0=%0d run%0d=%0d (host noise must not change CPU/DMEM timing)", t[0], run, t[run]))
  `TC_CHECK(tb_ldv_cnt == 0, "i_ld_en must stay 0 while reset is released")
  mon_check_all();
endtask
