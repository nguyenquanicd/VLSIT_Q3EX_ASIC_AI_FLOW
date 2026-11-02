// TC-020 | REQ-011, REQ-015, REQ-020, REQ-051
// DMEM depth and row map (256 KB = 16384 rows of 16 bytes; lane i of row r at 0x1000_0000 + 16*r + 4*i):
//   A) host writes unique words to 12 rows (first, last, powers of two, random), host reads them back;
//   B) the CPU reads the same words with lw (slots 0..47) and the host compares them -> CPU path, no aliasing;
//   C) the CPU writes 4 other rows with sw / sh / sb at lane offsets (lanes pre-set to 0xFFFFFFFF by the host):
//      only the selected bytes change, neighbouring rows and lanes are untouched; checked through host reads.
task automatic tc_020_dmem_depth_and_row_map();
  int          rowsA [0:11];
  int          rowsB [0:3];
  logic [31:0] mdl_b [0:3][0:3];
  logic [31:0] d, rnd, a, v0, v1, v2, v3, ev;
  int          ri, lane, n, row, nerr;

  // The result area (TB_RES_BASE = 0x1000_8000) occupies rows 2048..2059 (48 slots, written by the CPU in part B):
  // no data row may lie in that window, so rowsA[5] is 2100 (bit 15 of the address is still covered by row 16383).
  rowsA[0] = 0;     rowsA[1] = 1;     rowsA[2] = 2;     rowsA[3] = 3;      rowsA[4] = 1024;  rowsA[5] = 2100;
  rowsA[6] = 4096;  rowsA[7] = 8192;  rowsA[8] = 16383;
  rnd = tb_rand32();  rowsA[9]  = 5 + int'(rnd % 900);
  rnd = tb_rand32();  rowsA[10] = 5000 + int'(rnd % 900);
  rnd = tb_rand32();  rowsA[11] = 10000 + int'(rnd % 900);
  rowsB[0] = 5;  rowsB[1] = 1030;  rowsB[2] = 8199;  rowsB[3] = 16380;
  nerr = 0;

  // ---- A) host write / host read
  for (ri = 0; ri < 12; ri++) begin
    row = rowsA[ri];
    for (lane = 0; lane < 4; lane++)
      dmem_wr(DMEM_BASE + 32'(16 * row + 4 * lane), {row[13:0], lane[1:0], 16'(row * 131 + lane * 17 + 3)});
  end
  for (ri = 0; ri < 12; ri++) begin
    row = rowsA[ri];
    for (lane = 0; lane < 4; lane++) begin
      dmem_rd(DMEM_BASE + 32'(16 * row + 4 * lane), d);
      ev = {row[13:0], lane[1:0], 16'(row * 131 + lane * 17 + 3)};
      if (d !== ev) begin
        nerr++;
        `TC_CHECK(d === ev, $sformatf("A: host read row %0d lane %0d = %08h, expected %08h", row, lane, d, ev))
      end
    end
  end

  // ---- B) CPU reads the same words
  prog_reset();
  emit_res_init();
  n = 0;
  for (ri = 0; ri < 12; ri++) begin
    row = rowsA[ri];
    for (lane = 0; lane < 4; lane++) begin
      emit_li(5'd5, DMEM_BASE + 32'(16 * row + 4 * lane));
      emit(rv_lw(5'd6, 5'd5, 0));
      emit_sw_res(5'd6, n);
      n++;
    end
  end
  emit_halt();
  dmem_fill(TB_RES_BASE, 48, 32'h0);
  run_prog(30000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "B: CPU read program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "B: unexpected illegal instruction")
  n = 0;
  for (ri = 0; ri < 12; ri++) begin
    row = rowsA[ri];
    for (lane = 0; lane < 4; lane++) begin
      res_rd(n, d);
      ev = {row[13:0], lane[1:0], 16'(row * 131 + lane * 17 + 3)};
      if (d !== ev) begin
        nerr++;
        `TC_CHECK(d === ev, $sformatf("B: CPU lw row %0d lane %0d = %08h, expected %08h", row, lane, d, ev))
      end
      n++;
    end
  end

  // ---- C) CPU writes with sw / sh / sb
  for (ri = 0; ri < 4; ri++) begin
    row = rowsB[ri];
    a   = DMEM_BASE + 32'(16 * row);
    dmem_wr(a + 32'h00, 32'h0);
    dmem_wr(a + 32'h04, 32'hFFFF_FFFF);
    dmem_wr(a + 32'h08, 32'hFFFF_FFFF);
    dmem_wr(a + 32'h0C, 32'h0);
    dmem_wr(a - 32'h10, 32'hBAD0_BAD0 + ri);          // previous row, lane 0
    dmem_wr(a + 32'h10, 32'hBAD1_BAD1 + ri);          // next row, lane 0
  end
  prog_reset();
  for (ri = 0; ri < 4; ri++) begin
    row = rowsB[ri];
    v0 = {row[13:0], 2'd0, 16'(row * 7 + 1)};
    v1 = {row[13:0], 2'd1, 16'(row * 7 + 2)};
    v2 = {row[13:0], 2'd2, 16'(row * 7 + 3)};
    v3 = {row[13:0], 2'd3, 16'(row * 7 + 4)};
    mdl_b[ri][0] = v0;
    mdl_b[ri][1] = {16'hFFFF, v1[15:0]};
    mdl_b[ri][2] = {8'hFF, 8'hFF, v2[7:0], 8'hFF};
    mdl_b[ri][3] = v3;
    emit_li(5'd5, DMEM_BASE + 32'(16 * row));
    emit_li(5'd6, v0);  emit(rv_sw(5'd6, 5'd5, 0));
    emit_li(5'd7, v1);  emit(rv_sh(5'd7, 5'd5, 4));
    emit_li(5'd8, v2);  emit(rv_sb(5'd8, 5'd5, 9));
    emit_li(5'd9, v3);  emit(rv_sw(5'd9, 5'd5, 12));
  end
  emit_halt();
  run_prog(30000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "C: CPU write program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "C: unexpected illegal instruction")
  for (ri = 0; ri < 4; ri++) begin
    row = rowsB[ri];
    a   = DMEM_BASE + 32'(16 * row);
    for (lane = 0; lane < 4; lane++) begin
      dmem_rd(a + 32'(4 * lane), d);
      if (d !== mdl_b[ri][lane]) begin
        nerr++;
        `TC_CHECK(d === mdl_b[ri][lane],
                  $sformatf("C: row %0d lane %0d = %08h, expected %08h (only selected bytes may change)",
                            row, lane, d, mdl_b[ri][lane]))
      end
    end
    dmem_rd(a - 32'h10, d);
    `TC_CHECK(d === 32'hBAD0_BAD0 + ri, $sformatf("C: row %0d - 1 modified (%08h)", row, d))
    dmem_rd(a + 32'h10, d);
    `TC_CHECK(d === 32'hBAD1_BAD1 + ri, $sformatf("C: row %0d + 1 modified (%08h)", row, d))
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d DMEM mismatches", nerr))
  mon_check_all();
endtask
