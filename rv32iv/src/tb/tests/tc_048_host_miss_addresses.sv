// TC-048 | REQ-021, REQ-042
// Host accesses that miss DMEM: a read of IMEM, MMIO or an unmapped address returns 0 one cycle later; a write to
// MMIO or an unmapped address changes nothing (DMEM, IMEM and the CSR outputs stay as they were, no aliasing).
task automatic tc_048_host_miss_addresses();
  logic [31:0] ma [0:31];                  // MMIO + unmapped addresses
  int          nm, i, k;
  logic [31:0] d;

  // ---- miss address list
  nm = 0;
  ma[nm] = 32'h2000_0000; nm++;            // MMIO: ctrl, sts, result, cycles, uart_tx, uart_cfg
  ma[nm] = 32'h2000_0004; nm++;
  ma[nm] = 32'h2000_0008; nm++;
  ma[nm] = 32'h2000_000C; nm++;
  ma[nm] = 32'h2000_0010; nm++;
  ma[nm] = 32'h2000_0014; nm++;
  ma[nm] = 32'h2000_0100; nm++;            // unimplemented CSR offset
  ma[nm] = 32'h2000_0FFC; nm++;            // last MMIO word
  ma[nm] = 32'h2000_1000; nm++;            // just beyond MMIO
  ma[nm] = 32'h0000_8000; nm++;            // just beyond IMEM
  ma[nm] = 32'h0000_FFFC; nm++;
  ma[nm] = 32'h0001_0000; nm++;
  ma[nm] = 32'h0004_0000; nm++;
  ma[nm] = 32'h1004_0000; nm++;            // just beyond DMEM (would alias DMEM base)
  ma[nm] = 32'h1004_0010; nm++;            // would alias DMEM row 1
  ma[nm] = 32'h1008_0000; nm++;
  ma[nm] = 32'h1800_0000; nm++;
  ma[nm] = 32'h3000_0000; nm++;
  ma[nm] = 32'h8000_0000; nm++;
  ma[nm] = 32'hFFFF_FFFC; nm++;

  // ---- small program that must survive all the attempts (stores a marker and reads CSR state)
  prog_reset();
  emit_res_init();
  emit_li(5'd5, 32'h1357);
  emit_sw_res(5'd5, 0);                                   // slot0: marker
  emit_li(5'd6, MMIO_BASE);
  emit(rv_lw(5'd7, 5'd6, 4));  emit(rv_andi(5'd7, 5'd7, 7));   emit_sw_res(5'd7, 1);   // sts must be 0
  emit(rv_lw(5'd7, 5'd6, 8));  emit(rv_andi(5'd7, 5'd7, 15));  emit_sw_res(5'd7, 2);   // result.label must be 0
  emit(rv_lw(5'd7, 5'd6, 20));                                 emit_sw_res(5'd7, 3);   // uart_cfg reset value
  emit_halt();
  host_load_prog();
  dmem_wr(TB_RES_BASE + 32'h0, 32'h0);
  dmem_wr(TB_RES_BASE + 32'h4, 32'hFFFF_FFFF);

  // ---- known DMEM words (also the targets of potential aliasing) and non-zero IMEM words
  for (k = 0; k < 16; k++) dmem_wr(DMEM_BASE + 32'(k * 4), 32'h600D_0000 + k);
  imem_wr(32'h0000_7FFC, 32'hDEAD_0001);
  imem_wr(32'h0000_1000, 32'hDEAD_0002);

  // ---- reads of IMEM (non-zero content) return 0 one cycle later
  host_cycle(1'b1, 1'b0, 32'h0000_0000, 4'h0, 32'h0);
  `TC_CHECK(o_ld_rd_data === 32'h0, "host read of IMEM word 0 must return 0")
  host_cycle(1'b1, 1'b0, 32'h0000_0004, 4'h0, 32'h0);
  `TC_CHECK(o_ld_rd_data === 32'h0, "host read of IMEM word 1 must return 0")
  host_cycle(1'b1, 1'b0, 32'h0000_1000, 4'h0, 32'h0);
  `TC_CHECK(o_ld_rd_data === 32'h0, "host read of IMEM 0x1000 (written with non-zero data) must return 0")
  host_cycle(1'b1, 1'b0, 32'h0000_7FFC, 4'h0, 32'h0);
  `TC_CHECK(o_ld_rd_data === 32'h0, "host read of IMEM 0x7FFC (written with non-zero data) must return 0")

  // ---- reads of MMIO and unmapped addresses return 0
  for (i = 0; i < nm; i++) begin
    host_cycle(1'b1, 1'b0, ma[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === 32'h0, $sformatf("host read of miss address %08h must return 0, got %08h", ma[i], o_ld_rd_data))
  end

  // ---- back-to-back hit / miss / hit / miss: every read answers in its own cycle
  for (k = 0; k < 8; k++) begin
    host_cycle(1'b1, 1'b0, DMEM_BASE + 32'(k * 4), 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === (32'h600D_0000 + k), $sformatf("DMEM hit %0d between misses returned %08h", k, o_ld_rd_data))
    host_cycle(1'b1, 1'b0, ma[(k * 3) % nm], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === 32'h0, $sformatf("miss read %08h after a DMEM hit must return 0", ma[(k * 3) % nm]))
  end
  host_idle();

  // ---- writes to MMIO / unmapped addresses: nothing changes
  for (i = 0; i < nm; i++) begin
    host_cycle(1'b1, 1'b1, ma[i], 4'hF, 32'h0010_0073);          // ebreak encoding (would break the program if aliased)
    host_cycle(1'b1, 1'b1, ma[i], 4'hF, 32'hBAD0_0000 + i);
  end
  for (k = 0; k < 8; k++) begin
    host_cycle(1'b1, 1'b1, 32'h0000_8000 + 32'(k * 4), 4'hF, 32'h0010_0073);   // alias candidates of IMEM words 0..7
    host_cycle(1'b1, 1'b1, 32'h1004_0000 + 32'(k * 4), 4'hF, 32'hBAD1_0000 + k); // alias candidates of DMEM words 0..7
    host_cycle(1'b1, 1'b1, 32'h1008_0000 + 32'(k * 4), 4'hF, 32'hBAD2_0000 + k);
  end
  host_idle();
  `TC_CHECK(o_sts_done === 1'b0 && o_result_label === 4'h0, "CSR outputs changed by host writes to MMIO addresses")

  // ---- DMEM words unchanged, miss addresses still read 0
  for (k = 0; k < 16; k++) begin
    host_cycle(1'b1, 1'b0, DMEM_BASE + 32'(k * 4), 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === (32'h600D_0000 + k),
              $sformatf("DMEM word %0d changed by a miss-address write: %08h", k, o_ld_rd_data))
  end
  for (i = 0; i < nm; i++) begin
    host_cycle(1'b1, 1'b0, ma[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === 32'h0, $sformatf("miss address %08h reads non-zero after the writes: %08h", ma[i], o_ld_rd_data))
  end
  host_idle();

  // ---- IMEM unchanged and CSR state untouched: the program still runs to completion
  host_end();
  wait_halt(5000);                                         // includes the post-halt drain
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak: IMEM modified by a miss-address write?")
  `TC_CHECK(o_err_illegal === 1'b0,        "illegal instruction: IMEM modified by a miss-address write?")
  res_rd(0, d); `TC_CHECK(d === 32'h1357,       "marker not stored: program disturbed by host miss writes")
  res_rd(1, d); `TC_CHECK(d === 32'h0,          "sts must be 0: CSR changed by host MMIO write")
  res_rd(2, d); `TC_CHECK(d === 32'h0,          "result.label must be 0: CSR changed by host MMIO write")
  res_rd(3, d); `TC_CHECK(d === {16'h0, BAUD_DIV_RESET}, "uart_cfg must keep its reset value")
  mon_check_all();
endtask
