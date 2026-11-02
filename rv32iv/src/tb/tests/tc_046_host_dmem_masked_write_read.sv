// TC-046 | REQ-020, REQ-011, REQ-051
// Host DMEM masked writes: all 16 byte-enable patterns on all 4 lanes of the first, last, a middle and a random row,
// with random addr[1:0] noise on writes and reads. Exactly the enabled bytes change; lane = addr[3:2],
// row = addr[17:4]; neighbouring lanes/rows and far-away alias rows are untouched.
task automatic tc_046_host_dmem_masked_write_read();
  logic [31:0] mdl  [0:11];                 // 3 rows x 4 lanes around the tested row
  logic [31:0] amdl [0:7];                  // 2 alias rows x 4 lanes (row ^ 0x2000, row ^ 0x1000)
  int          rows [0:3];
  int          ri, row, rb, ci, lane, be, i, b, nerr, arow0, arow1;
  logic [31:0] rnd, wd, rd_d, a;

  rows[0] = 0;
  rows[1] = 16383;                          // last row of 256 KB / 16 B
  rows[2] = 2048;
  rnd = tb_rand32();
  rows[3] = 1 + int'(rnd % 16000);
  nerr = 0;

  for (ri = 0; ri < 4; ri++) begin
    row = rows[ri];
    if (row == 0)          rb = 0;
    else if (row == 16383) rb = 16381;
    else                   rb = row - 1;
    ci    = row - rb;
    arow0 = row ^ 32'h2000;
    arow1 = row ^ 32'h1000;

    // known contents of the 3 rows and of the 2 alias rows (full-word writes, back to back)
    for (i = 0; i < 12; i++) begin
      mdl[i] = tb_rand32();
      dmem_wr(DMEM_BASE + 32'(rb * 16 + i * 4), mdl[i]);
    end
    for (i = 0; i < 4; i++) begin
      amdl[i]     = tb_rand32();
      amdl[4 + i] = tb_rand32();
      dmem_wr(DMEM_BASE + 32'(arow0 * 16 + i * 4), amdl[i]);
      dmem_wr(DMEM_BASE + 32'(arow1 * 16 + i * 4), amdl[4 + i]);
    end

    for (lane = 0; lane < 4; lane++) begin
      for (be = 0; be < 16; be++) begin
        wd  = tb_rand32();
        rnd = tb_rand32();
        a   = DMEM_BASE + 32'(row * 16 + lane * 4) + {30'h0, rnd[1:0]};     // addr[1:0] noise
        host_cycle(1'b1, 1'b1, a, be[3:0], wd);
        for (b = 0; b < 4; b++)
          if (be[b]) mdl[ci * 4 + lane][b * 8 +: 8] = wd[b * 8 +: 8];
        // read back all 12 words, back to back, with addr[1:0] noise
        for (i = 0; i < 12; i++) begin
          rnd = tb_rand32();
          host_cycle(1'b1, 1'b0, DMEM_BASE + 32'(rb * 16 + i * 4) + {30'h0, rnd[1:0]}, 4'h0, 32'h0);
          rd_d = o_ld_rd_data;
          if (rd_d !== mdl[i]) begin
            nerr++;
            if (nerr <= 12)
              `TC_CHECK(rd_d === mdl[i],
                        $sformatf("row %0d lane %0d be %b: word %0d (row %0d lane %0d) = %08h, expected %08h",
                                  row, lane, be[3:0], i, rb + i / 4, i % 4, rd_d, mdl[i]))
          end
        end
      end
    end

    // alias rows (address bits far from the tested row) must be untouched
    for (i = 0; i < 4; i++) begin
      host_cycle(1'b1, 1'b0, DMEM_BASE + 32'(arow0 * 16 + i * 4), 4'h0, 32'h0);
      `TC_CHECK(o_ld_rd_data === amdl[i], $sformatf("alias row %0d lane %0d changed by writes to row %0d", arow0, i, row))
      host_cycle(1'b1, 1'b0, DMEM_BASE + 32'(arow1 * 16 + i * 4), 4'h0, 32'h0);
      `TC_CHECK(o_ld_rd_data === amdl[4 + i], $sformatf("alias row %0d lane %0d changed by writes to row %0d", arow1, i, row))
    end
    host_idle();
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d host DMEM read/write mismatches", nerr))
  mon_check_all();
endtask
