// TC-004 | REQ-042, REQ-021
// Host port works while reset is asserted; reset pulses never clear IMEM/DMEM; the CPU never alters memory
// while it is held in reset.
task automatic tc_004_reset_keeps_memories_host_active();
  logic [31:0] addr [0:7];
  logic [31:0] va   [0:7];
  logic [31:0] vb   [0:7];
  logic [31:0] d, c1, c2;
  int          i, k;

  addr[0] = DMEM_BASE;
  addr[1] = DMEM_LAST;
  addr[2] = DMEM_BASE + 32'h10;
  addr[3] = DMEM_BASE + 32'h1C;
  addr[4] = 32'h1001_2344;
  addr[5] = 32'h1002_0000;
  addr[6] = 32'h1003_FFF0;
  addr[7] = TB_DATA_BASE + 32'h20;
  for (i = 0; i < 8; i++) begin
    va[i] = tb_rand32();
    vb[i] = tb_rand32();
  end

  // Part 1: harmless program (ebreak) so that a surviving IMEM shows up as a clean halt after every release
  prog_reset();
  emit_halt();
  host_load_prog();                                    // IMEM written while reset is asserted
  for (i = 0; i < 8; i++) dmem_wr(addr[i], va[i]);     // DMEM written while reset is asserted
  for (i = 0; i < 8; i++) begin                        // host reads work during reset
    host_rd32(addr[i], d);
    `TC_CHECK(d === va[i], "host read during reset must return the value just written")
  end

  for (k = 0; k < 4; k++) begin
    if ((k % 2) == 0) host_end();                      // release through the host sequence
    else              reset_dut(2 + k);                // plain reset pulse with i_ld_en=0
    wait_halt(100);
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, "IMEM content lost: program did not reach ebreak after a reset pulse")
    `TC_CHECK(o_err_illegal === 1'b0, "IMEM content lost: illegal instruction fetched after a reset pulse")
    host_begin();
    for (i = 0; i < 8; i++) begin
      host_rd32(addr[i], d);
      `TC_CHECK(d === va[i], "DMEM content must survive a reset pulse")
    end
  end

  // Host writes issued in reset right before a reset pulse are kept as well
  for (i = 0; i < 8; i++) dmem_wr(addr[i], vb[i]);
  reset_dut(2);
  wait_halt(100);
  `TC_CHECK(tb_run_hit && o_err_illegal === 1'b0, "program must still halt cleanly after the pulse")
  for (i = 0; i < 8; i++) begin
    host_rd32(addr[i], d);
    `TC_CHECK(d === vb[i], "host write done in reset must be kept after a reset pulse")
  end

  // Part 2: a CPU store loop is stopped by reset and does not touch memory while reset is held
  prog_reset();
  emit_li(5'd30, TB_DATA_BASE);
  emit(rv_addi(5'd1, 5'd0, 0));
  emit(rv_addi(5'd1, 5'd1, 1));                        // loop
  emit(rv_sw(5'd1, 5'd30, 0));
  emit(rv_jal(5'd0, -8));
  dmem_wr(TB_DATA_BASE, 32'h0);
  host_load_prog();
  host_end();
  wait_cycles(80);
  rst_assert();
  for (k = 0; k < 6; k++) begin
    tick();
    `TC_CHECK(p_cpu_dmem_req !== 1'b1, "CPU must not issue data requests while reset is asserted")
  end
  host_rd32(TB_DATA_BASE, c1);
  wait_cycles(40);
  host_rd32(TB_DATA_BASE, c2);
  `TC_CHECK(c1 !== 32'h0 && c1 !== 32'hx, "store loop did not run before the reset")
  `TC_CHECK(c2 === c1, "DMEM changed while the CPU was held in reset")
  for (i = 0; i < 7; i++) begin
    host_rd32(addr[i], d);
    `TC_CHECK(d === vb[i], "pattern DMEM word disturbed by the CPU / reset")
  end
  mon_check_all();
endtask
