// TC-037 | REQ-016, REQ-027
// Aligned lw/sw to the CSRs at the interim offsets (ctrl 0x00, sts 0x04, result 0x08, cycles 0x0C, uart_tx 0x10,
// uart_cfg 0x14). Table-driven: each step is one MMIO word access in a firmware program; reads are stored to the
// result area and compared with the expected value (reserved bits read 0, writes to reserved bits ignored).
//   program A: reset values, write/readback of every writable CSR incl. reserved bits; ends with sts=3, label=9
//   program B: ends with sts=0, label=6
// Checked: read data, number of APB transfers == number of accesses (CPU stalled until completion, resumes with the
// right data), no PSLVERR / sts.err event, o_sts_done follows sts.done, o_result_label follows result.label.
`define T37_W(o, v)     begin st_kind[nst] = 0; st_off[nst] = (o); st_val[nst] = (v); st_msk[nst] = 32'hFFFF_FFFF; nst++; end
`define T37_R(o, v, m)  begin st_kind[nst] = 1; st_off[nst] = (o); st_val[nst] = (v); st_msk[nst] = (m); nst++; end
task automatic tc_037_mmio_csr_word_access();
  int          st_kind [0:63];
  int          st_off  [0:63];
  logic [31:0] st_val  [0:63];
  logic [31:0] st_msk  [0:63];
  logic [31:0] exp_slot [0:63];
  logic [31:0] d;
  int          pg, i, nst, nrd, cum;

  cum = 0;
  for (pg = 0; pg < 2; pg++) begin
    nst = 0;
    if (pg == 0) begin
      // reset values
      `T37_R(0,  32'h0,      32'hFFFF_FFFF)     // ctrl
      `T37_R(4,  32'h0,      32'hFFFF_FFFF)     // sts
      `T37_R(8,  32'h0,      32'hFFFF_FFFF)     // result
      `T37_R(12, 32'h0,      32'hFFFF_FFFF)     // cycles (no vector instruction yet)
      `T37_R(16, 32'h0,      32'h0000_0300)     // uart_tx send/busy
      `T37_R(20, 32'h06C8,   32'hFFFF_FFFF)     // uart_cfg.baud_div
      // ctrl: bit 0 only
      `T37_W(0,  32'h1)
      `T37_R(0,  32'h1,      32'hFFFF_FFFF)
      `T37_W(0,  32'hFFFF_FFFE)
      `T37_R(0,  32'h0,      32'hFFFF_FFFF)
      `T37_W(0,  32'hFFFF_FFFF)
      `T37_R(0,  32'h1,      32'hFFFF_FFFF)
      `T37_W(0,  32'h0)
      `T37_R(0,  32'h0,      32'hFFFF_FFFF)
      // sts: busy/done plain RW, err w1c (bit 2 = 0 in the writes), reserved bits read 0
      `T37_W(4,  32'h3)
      `T37_R(4,  32'h3,      32'hFFFF_FFFF)
      `T37_W(4,  32'hFFFF_FFFB)
      `T37_R(4,  32'h3,      32'hFFFF_FFFF)
      `T37_W(4,  32'h0)
      `T37_R(4,  32'h0,      32'hFFFF_FFFF)
      `T37_W(4,  32'h1)
      `T37_R(4,  32'h1,      32'hFFFF_FFFF)
      // result.label: 4 bits
      `T37_W(8,  32'hFFFF_FFFF)
      `T37_R(8,  32'hF,      32'hFFFF_FFFF)
      `T37_W(8,  32'h5)
      `T37_R(8,  32'h5,      32'hFFFF_FFFF)
      // uart_cfg.baud_div: 16 bits
      `T37_W(20, 32'hFFFF_FFFF)
      `T37_R(20, 32'hFFFF,   32'hFFFF_FFFF)
      `T37_W(20, 32'h1234)
      `T37_R(20, 32'h1234,   32'hFFFF_FFFF)
      `T37_W(20, 32'h06C8)
      `T37_R(20, 32'h06C8,   32'hFFFF_FFFF)
      // uart_tx.data with send = 0 (bit 8 = 0, busy bit 9 written as 1 must be ignored): no transmission
      `T37_W(16, 32'hFFFF_FE5A)
      `T37_R(16, 32'h5A,     32'hFFFF_FFFF)
      // final state of program A
      `T37_W(4,  32'h3)
      `T37_W(8,  32'h9)
    end else begin
      `T37_W(4,  32'h0)
      `T37_W(8,  32'h6)
      `T37_R(4,  32'h0,      32'hFFFF_FFFF)
      `T37_R(8,  32'h6,      32'hFFFF_FFFF)
      `T37_R(0,  32'h0,      32'hFFFF_FFFF)
    end

    prog_reset();
    emit_res_init();
    emit_li(5'd6, MMIO_BASE);
    nrd = 0;
    for (i = 0; i < nst; i++) begin
      if (st_kind[i] == 0) begin
        emit_li(5'd7, st_val[i]);
        emit(rv_sw(5'd7, 5'd6, st_off[i]));
      end else begin
        emit(rv_lw(5'd7, 5'd6, st_off[i]));
        if (st_msk[i] != 32'hFFFF_FFFF) emit(rv_andi(5'd7, 5'd7, int'(st_msk[i])));
        emit_sw_res(5'd7, nrd);
        exp_slot[nrd] = st_val[i];
        nrd++;
      end
    end
    emit_halt();
    cum = cum + nst;

    run_prog(20000);                                  // includes the post-halt drain
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("program %0d did not reach ebreak (CPU hung on an MMIO access?)", pg))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("program %0d: illegal instruction", pg))
    `TC_CHECK(tb_apb_xfer_cnt == cum,
              $sformatf("program %0d: %0d APB transfers, expected %0d (one per MMIO access)", pg, tb_apb_xfer_cnt, cum))
    `TC_CHECK(tb_apb_slverr_cnt == 0, "aligned word accesses must not raise PSLVERR")
    `TC_CHECK(tb_sts_err_events == 0, "aligned word accesses must not set sts.err")
    if (pg == 0) begin
      `TC_CHECK(o_sts_done === 1'b1,     "o_sts_done must follow sts.done (=1)")
      `TC_CHECK(o_result_label === 4'd9, "o_result_label must follow result.label (=9)")
    end else begin
      `TC_CHECK(o_sts_done === 1'b0,     "o_sts_done must follow sts.done (=0)")
      `TC_CHECK(o_result_label === 4'd6, "o_result_label must follow result.label (=6)")
    end
    for (i = 0; i < nrd; i++) begin
      res_rd(i, d);
      `TC_CHECK(d === exp_slot[i], $sformatf("program %0d read %0d: %08h, expected %08h", pg, i, d, exp_slot[i]))
    end
  end
  mon_check_all();
endtask
`undef T37_W
`undef T37_R
