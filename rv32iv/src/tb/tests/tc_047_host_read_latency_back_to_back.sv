// TC-047 | REQ-021, REQ-022
// Host port: no handshake, an access every cycle. o_ld_rd_data carries the data of a read exactly one cycle after
// the request (host_cycle() returns just after the edge that samples the request, so o_ld_rd_data then holds the
// data of the request issued by that same call). All values are unique, so a latency of 0 or 2 cycles, or a lost
// access, shows up as a mismatch.
task automatic tc_047_host_read_latency_back_to_back();
  logic [31:0] ad  [0:7];
  logic [31:0] mdl [0:7];
  logic [31:0] nv, rnd;
  int          i, c, op, nerr, uniq;

  ad[0] = DMEM_BASE + 32'h0000;
  ad[1] = DMEM_BASE + 32'h0004;
  ad[2] = DMEM_BASE + 32'h0008;
  ad[3] = DMEM_BASE + 32'h000C;
  ad[4] = DMEM_BASE + 32'h0010;
  ad[5] = DMEM_BASE + 32'h001C;
  ad[6] = DMEM_BASE + 32'h3_FFF0;
  ad[7] = DMEM_LAST;
  uniq  = 0;
  nerr  = 0;
  host_begin();

  // (a) 8 writes back to back (every cycle), then 8 reads back to back
  for (i = 0; i < 8; i++) begin
    uniq++;
    rnd = tb_rand32();
    mdl[i] = {uniq[7:0], rnd[23:0]};
    host_cycle(1'b1, 1'b1, ad[i], 4'hF, mdl[i]);
  end
  for (i = 0; i < 8; i++) begin
    host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === mdl[i], $sformatf("(a) read %0d: data %08h not equal to %08h one cycle after the request",
                                                 i, o_ld_rd_data, mdl[i]))
  end
  // reads in reverse order, again every cycle
  for (i = 7; i >= 0; i--) begin
    host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === mdl[i], $sformatf("(a2) read %0d: data %08h not equal to %08h", i, o_ld_rd_data, mdl[i]))
  end
  host_idle();

  // (b) read-after-write on the very next cycle returns the new data
  for (c = 0; c < 16; c++) begin
    i = c % 8;
    uniq++;
    rnd = tb_rand32();
    nv = {uniq[7:0], rnd[23:0]};
    host_cycle(1'b1, 1'b1, ad[i], 4'hF, nv);
    mdl[i] = nv;
    host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === nv, $sformatf("(b) read-after-write %0d: data %08h expected new value %08h", c, o_ld_rd_data, nv))
  end

  // (c) read, write, read of the same address on three consecutive cycles: old, (write), new
  for (c = 0; c < 8; c++) begin
    i = c;
    uniq++;
    rnd = tb_rand32();
    nv = {uniq[7:0], rnd[23:0]};
    host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === mdl[i], $sformatf("(c) read before write %0d: data %08h expected old %08h", c, o_ld_rd_data, mdl[i]))
    host_cycle(1'b1, 1'b1, ad[i], 4'hF, nv);
    mdl[i] = nv;
    host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
    `TC_CHECK(o_ld_rd_data === nv, $sformatf("(c) read after write %0d: data %08h expected new %08h", c, o_ld_rd_data, nv))
  end
  host_idle();

  // (d) 400 random cycles: write / read / idle, reads checked in the cycle after their request
  for (c = 0; c < 400; c++) begin
    rnd = tb_rand32();
    i   = int'(rnd[10:8]);
    op  = int'(rnd[13:12] % 3);
    if (op == 0) begin
      uniq++;
      nv = {uniq[7:0], rnd[31:24] ^ rnd[7:0], rnd[23:8]};
      host_cycle(1'b1, 1'b1, ad[i], 4'hF, nv);
      mdl[i] = nv;
    end else if (op == 1) begin
      host_cycle(1'b1, 1'b0, ad[i], 4'h0, 32'h0);
      if (o_ld_rd_data !== mdl[i]) begin
        nerr++;
        if (nerr <= 10)
          `TC_CHECK(o_ld_rd_data === mdl[i], $sformatf("(d) cycle %0d read of word %0d: %08h expected %08h",
                                                       c, i, o_ld_rd_data, mdl[i]))
      end
    end else begin
      host_idle();
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("(d) %0d random-stream mismatches", nerr))
  host_idle();
  mon_check_all();
endtask
