// TC-024 | REQ-058, REQ-033, REQ-005
// Vector loads/stores at addresses that are not row-aligned (row + 1 .. row + 15): the low log2(PARA_VLEN/8) = 4 address
// bits are ignored and the aligned row is accessed, no error. 15 cases: vle8/vse8 (vl 16, 5, 11) at offsets 1..15 and
// vle32/vse32 (vl 4, 3) at offsets 4, 10, 15. Per case (CB = 0x1000_5000 + c*0x100):
//   rows +0x00 / +0x20 (SRC-1 / SRC+1) hold other data (a wrong-row load would show), SRC +0x10 is the source row,
//   DST +0x50 (pre-set 0xEE) is stored through DST+off, guard rows +0x40 / +0x60 (0xDD) must stay untouched.
// Expected: DST row = SRC row bytes (not shifted by off) for the stored elements, 0xEE beyond vl, guard rows unchanged.
// Only the row part of o_mem_addr (bits [31:4]) is checked through the monitor log; the ignored low bits are only
// reported as TC_INFO (they may be driven unmodified or cleared, REQ-058).
task automatic tc_024_vle_vse_unaligned_address();
  int          c_off [0:14];
  int          c_vl  [0:14];
  int          c_sew [0:14];
  logic [7:0]  srcb [0:14][0:15];
  logic [31:0] CB, r, d, SRC, DST;
  int          c, i, wd, nb, nerr, nlow;
  logic [7:0]  ex;

  c_off[0]  = 1;   c_vl[0]  = 16; c_sew[0]  = 8;    c_off[1]  = 2;   c_vl[1]  = 16; c_sew[1]  = 8;
  c_off[2]  = 3;   c_vl[2]  = 16; c_sew[2]  = 8;    c_off[3]  = 4;   c_vl[3]  = 16; c_sew[3]  = 8;
  c_off[4]  = 5;   c_vl[4]  = 16; c_sew[4]  = 8;    c_off[5]  = 7;   c_vl[5]  = 16; c_sew[5]  = 8;
  c_off[6]  = 8;   c_vl[6]  = 16; c_sew[6]  = 8;    c_off[7]  = 9;   c_vl[7]  = 16; c_sew[7]  = 8;
  c_off[8]  = 12;  c_vl[8]  = 16; c_sew[8]  = 8;    c_off[9]  = 15;  c_vl[9]  = 16; c_sew[9]  = 8;
  c_off[10] = 1;   c_vl[10] = 5;  c_sew[10] = 8;    c_off[11] = 9;   c_vl[11] = 11; c_sew[11] = 8;
  c_off[12] = 4;   c_vl[12] = 4;  c_sew[12] = 32;   c_off[13] = 10;  c_vl[13] = 4;  c_sew[13] = 32;
  c_off[14] = 15;  c_vl[14] = 3;  c_sew[14] = 32;
  nerr = 0;

  for (c = 0; c < 15; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    for (i = 0; i < 16; i++) begin
      r = tb_rand32();
      srcb[c][i] = r[7:0];
    end
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h00 + 32'(4 * wd), tb_rand32());                                    // SRC - 1 row
      dmem_wr(CB + 32'h10 + 32'(4 * wd), {srcb[c][4*wd+3], srcb[c][4*wd+2], srcb[c][4*wd+1], srcb[c][4*wd]});
      dmem_wr(CB + 32'h20 + 32'(4 * wd), tb_rand32());                                    // SRC + 1 row
      dmem_wr(CB + 32'h40 + 32'(4 * wd), 32'hDDDD_DDDD);                                  // guard low
      dmem_wr(CB + 32'h50 + 32'(4 * wd), 32'hEEEE_EEEE);                                  // DST row
      dmem_wr(CB + 32'h60 + 32'(4 * wd), 32'hDDDD_DDDD);                                  // guard high
    end
  end

  prog_reset();
  for (c = 0; c < 15; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    emit_li(5'd12, CB + 32'h10 + 32'(c_off[c]));         // unaligned source address
    emit_li(5'd14, CB + 32'h50 + 32'(c_off[c]));         // unaligned destination address
    emit_li(5'd10, 32'(c_vl[c]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(c_sew[c])));
    if (c_sew[c] == 8) begin
      emit(rv_vle8 (5'd1, 5'd12));
      emit(rv_vse8 (5'd1, 5'd14));
    end else begin
      emit(rv_vle32(5'd1, 5'd12));
      emit(rv_vse32(5'd1, 5'd14));
    end
  end
  emit_halt();

  run_prog(100000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (unaligned vector access hung / halted?)")
  `TC_CHECK(o_err_illegal === 1'b0, "unaligned vector access must not raise an error")
  `TC_CHECK(tb_sts_err_events == 0, "unaligned vector access must not set sts.err")
  `TC_CHECK(tb_vmem_xfer_cnt == 30, $sformatf("expected 30 VPU memory accesses (one row access per vle/vse), saw %0d", tb_vmem_xfer_cnt))

  // row part of o_mem_addr (monitor log: access 2c = load, 2c+1 = store); low bits only reported
  nlow = 0;
  for (c = 0; c < 15; c++) begin
    CB  = 32'h1000_5000 + 32'(c * 256);
    SRC = CB + 32'h10;
    DST = CB + 32'h50;
    `TC_CHECK(tb_vmem_log_addr[2*c][31:4] === SRC[31:4] && !tb_vmem_log_wr[2*c],
              $sformatf("case %0d: load row address %08h, expected row of %08h", c, tb_vmem_log_addr[2*c], SRC))
    `TC_CHECK(tb_vmem_log_addr[2*c+1][31:4] === DST[31:4] && tb_vmem_log_wr[2*c+1],
              $sformatf("case %0d: store row address %08h, expected row of %08h", c, tb_vmem_log_addr[2*c+1], DST))
    if (tb_vmem_log_addr[2*c][3:0] !== 4'h0) nlow++;
    if (tb_vmem_log_addr[2*c+1][3:0] !== 4'h0) nlow++;
  end
  $display("TC_INFO %s: %0d of 30 o_mem_addr values carry non-zero low bits (ignored by the memory side)", tc_id_s, nlow);

  for (c = 0; c < 15; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    nb = (c_sew[c] == 8) ? c_vl[c] : 4 * c_vl[c];
    for (wd = 0; wd < 4; wd++) begin
      dmem_rd(CB + 32'h50 + 32'(4 * wd), d);
      for (i = 0; i < 4; i++) begin
        ex = (4 * wd + i < nb) ? srcb[c][4*wd+i] : 8'hEE;
        if (d[8*i +: 8] !== ex) begin
          nerr++;
          `TC_CHECK(d[8*i +: 8] === ex,
                    $sformatf("case %0d (off %0d, vl %0d, e%0d): DST byte %0d = %02h, expected %02h (aligned row, not shifted)",
                              c, c_off[c], c_vl[c], c_sew[c], 4 * wd + i, d[8*i +: 8], ex))
        end
      end
      dmem_rd(CB + 32'h40 + 32'(4 * wd), d);
      `TC_CHECK(d === 32'hDDDD_DDDD, $sformatf("case %0d: guard row below DST modified (%08h)", c, d))
      dmem_rd(CB + 32'h60 + 32'(4 * wd), d);
      `TC_CHECK(d === 32'hDDDD_DDDD, $sformatf("case %0d: guard row above DST modified (%08h)", c, d))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d unaligned access mismatches", nerr))
  mon_check_all();
endtask
