// TC-025 | REQ-082, REQ-015
// VPU loads/stores addressing the IMEM range, MMIO and unmapped regions (outside DMEM):
//   * every access completes (no hang), no halt / illegal instruction / sts.err event,
//   * vle8 / vle32 from such an address yields zeros in vd (vd was preset to a non-zero pattern),
//   * vse8 to such an address is ignored: an executable code block placed in the addressed IMEM row still runs
//     (marker), the MMIO CSRs are untouched (sts, result, uart_tx send/busy read back 0, no UART frame).
// The vse data is all-ones, so any store that leaked into the CSR block would be visible.
task automatic tc_025_vpu_access_outside_dmem();
  logic [31:0] ad [0:5];
  logic [31:0] OUT, A, d;
  int          i, j, jidx, ridx, blk_w;

  ad[0] = 32'h0000_1008;      // IMEM range (row 0x1000 holds executable code, see below)
  ad[1] = 32'h2000_0000;      // MMIO: ctrl / sts / result / cycles row
  ad[2] = 32'h2000_0010;      // MMIO: uart_tx / uart_cfg row
  ad[3] = 32'h1004_0000;      // just beyond DMEM
  ad[4] = 32'h3000_0000;      // unmapped
  ad[5] = 32'hFFFF_FFF0;      // top of the address space
  A     = TB_DATA_BASE;       // all-ones source row
  OUT   = TB_DATA_BASE + 32'h100;
  blk_w = 32'h1000 / 4;       // word index of the code block in IMEM

  // ---------------- data
  for (j = 0; j < 4; j++) dmem_wr(A + 32'(4 * j), 32'hFFFF_FFFF);
  for (j = 0; j < 8 * 4; j++) dmem_wr(OUT + 32'(4 * j), 32'hEEEE_EEEE);     // 8 output rows
  for (j = 0; j < 8; j++) dmem_wr(TB_RES_BASE + 32'(4 * j), 32'hC0FF_EE11);

  // ---------------- program
  prog_reset();
  emit_res_init();
  emit_li(5'd30, A);
  emit_li(5'd8, 32'hAA);
  emit_li(5'd9, 32'h5555_5555);
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  emit(rv_vle8(5'd1, 5'd30));                              // v1 = all-ones data for the stores
  for (i = 0; i < 6; i++) begin                            // vle8 from outside DMEM -> zeros
    emit(rv_vmv_v_x(5'd2, 5'd8));                          // v2 = 0xAA..
    emit_li(5'd12, ad[i]);
    emit(rv_vle8(5'd2, 5'd12));
    emit_li(5'd13, OUT + 32'(16 * i));
    emit(rv_vse8(5'd2, 5'd13));
  end
  emit_li(5'd10, 32'd4);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(32)));
  for (i = 0; i < 2; i++) begin                            // vle32 from outside DMEM -> zeros
    emit(rv_vmv_v_x(5'd3, 5'd9));
    emit_li(5'd12, ad[3 * i]);
    emit(rv_vle32(5'd3, 5'd12));
    emit_li(5'd13, OUT + 32'(16 * (6 + i)));
    emit(rv_vse32(5'd3, 5'd13));
  end
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  for (i = 0; i < 6; i++) begin                            // vse8 of all-ones to outside DMEM -> ignored
    emit_li(5'd12, ad[i]);
    emit(rv_vse8(5'd1, 5'd12));
  end
  jidx = prog_pc;
  emit(rv_jal(5'd0, 0));                                   // patched: jump to the IMEM code block
  ridx = prog_pc;                                          // return point
  emit_li(5'd6, MMIO_BASE);
  emit(rv_lw(5'd7, 5'd6, 4));  emit(rv_andi(5'd7, 5'd7, 7));       emit_sw_res(5'd7, 1);   // sts
  emit(rv_lw(5'd7, 5'd6, 8));  emit(rv_andi(5'd7, 5'd7, 15));      emit_sw_res(5'd7, 2);   // result.label
  emit(rv_lw(5'd7, 5'd6, 16)); emit(rv_andi(5'd7, 5'd7, 32'h300)); emit_sw_res(5'd7, 3);   // uart_tx send/busy
  emit_li(5'd5, 32'h0E0D);
  emit_sw_res(5'd5, 4);
  emit_halt();
  // code block inside the IMEM row addressed by the ignored stores: runs only if it survived
  prog_org(blk_w);
  emit(rv_addi(5'd20, 5'd0, 32'h77));
  emit_sw_res(5'd20, 0);
  emit(rv_jal(5'd0, ridx * 4 - prog_here()));
  prog_patch(jidx, rv_jal(5'd0, blk_w * 4 - jidx * 4));

  run_prog(20000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (access outside DMEM hung or halted early)")
  `TC_CHECK(o_err_illegal === 1'b0, "access outside DMEM raised o_err_illegal")
  `TC_CHECK(tb_sts_err_events == 0, "access outside DMEM set sts.err (no error is raised)")
  `TC_CHECK(tb_uart_fall_cnt == 0,  "a VPU store leaked into uart_tx (UART frame seen)")

  for (i = 0; i < 8; i++) begin
    for (j = 0; j < 4; j++) begin
      dmem_rd(OUT + 32'(16 * i + 4 * j), d);
      `TC_CHECK(d === 32'h0, $sformatf("load %0d (%s) word %0d = %08h, expected 0", i, (i < 6) ? "vle8" : "vle32", j, d))
    end
  end
  res_rd(0, d); `TC_CHECK(d === 32'h77, $sformatf("IMEM code block overwritten by an ignored VPU store (marker %08h)", d))
  res_rd(1, d); `TC_CHECK(d === 32'h0,  $sformatf("sts changed by a VPU store to MMIO (%08h)", d))
  res_rd(2, d); `TC_CHECK(d === 32'h0,  $sformatf("result.label changed by a VPU store to MMIO (%08h)", d))
  res_rd(3, d); `TC_CHECK(d === 32'h0,  $sformatf("uart_tx send/busy set by a VPU store to MMIO (%08h)", d))
  res_rd(4, d); `TC_CHECK(d === 32'h0E0D, $sformatf("end marker missing (%08h)", d))
  mon_check_all();
endtask
