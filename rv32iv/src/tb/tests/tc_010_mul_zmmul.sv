// TC-010 | REQ-002
// mul (Zmmul): low 32 bits of the signed product.
//   * 8 x 8 operand pairs from {0, 1, -1, INT_MIN, INT_MAX, 0x0000FFFF, 0xFFFF0000, random} (64 cases)
//   * rd = x0: the product is discarded, x0 still reads 0
//   * dependent mul chain (forwarding into the multiplier) and mul with rd = rs1 = rs2
//   * mul result used immediately by an add and by a store
task automatic tc_010_mul_zmmul();
  logic [31:0] ops [0:7];
  logic [31:0] exp_v [0:127];
  logic [31:0] a, b, r, d, x;
  int          i, j, nslot, k, nerr;

  ops[0] = 32'h0000_0000;
  ops[1] = 32'h0000_0001;
  ops[2] = 32'hFFFF_FFFF;
  ops[3] = 32'h8000_0000;
  ops[4] = 32'h7FFF_FFFF;
  ops[5] = 32'h0000_FFFF;
  ops[6] = 32'hFFFF_0000;
  ops[7] = tb_rand32();
  nslot = 0;
  nerr  = 0;

  prog_reset();
  emit_res_init();
  for (i = 0; i < 8; i++) begin
    for (j = 0; j < 8; j++) begin
      a = ops[i];
      b = ops[j];
      emit_li(5'd1, a);
      emit_li(5'd2, b);
      emit(rv_mul(5'd3, 5'd1, 5'd2));
      emit_sw_res(5'd3, nslot);
      exp_v[nslot] = a * b;
      nslot++;
    end
  end

  // rd = x0: result discarded
  emit_li(5'd1, 32'h1234_5678);
  emit_li(5'd2, 32'h0000_0007);
  emit(rv_mul(5'd0, 5'd1, 5'd2));
  emit(rv_add(5'd4, 5'd0, 5'd0));
  emit_sw_res(5'd4, nslot);  exp_v[nslot] = 32'h0;  nslot++;
  emit_sw_res(5'd0, nslot);  exp_v[nslot] = 32'h0;  nslot++;

  // dependent chain: x6 = x6 * x2 repeated, and mul of a register with itself
  x = 32'd3;
  emit_li(5'd6, x);
  emit_li(5'd2, 32'hFFFF_FFFD);                              // -3
  for (k = 0; k < 6; k++) begin
    emit(rv_mul(5'd6, 5'd6, 5'd2));
    x = x * 32'hFFFF_FFFD;
  end
  emit_sw_res(5'd6, nslot);  exp_v[nslot] = x;  nslot++;
  emit_li(5'd7, 32'h0001_0001);
  emit(rv_mul(5'd7, 5'd7, 5'd7));                            // rd = rs1 = rs2
  emit_sw_res(5'd7, nslot);  exp_v[nslot] = 32'h0001_0001 * 32'h0001_0001;  nslot++;

  // mul result consumed by the very next instruction (add) and by a store
  emit_li(5'd1, 32'h0000_00F1);
  emit_li(5'd2, 32'h0000_0011);
  emit(rv_mul(5'd8, 5'd1, 5'd2));
  emit(rv_add(5'd9, 5'd8, 5'd8));
  emit_sw_res(5'd9, nslot);  exp_v[nslot] = (32'hF1 * 32'h11) + (32'hF1 * 32'h11);  nslot++;
  emit(rv_mul(5'd10, 5'd1, 5'd1));
  emit_sw_res(5'd10, nslot); exp_v[nslot] = 32'hF1 * 32'hF1;  nslot++;
  emit_halt();

  dmem_fill(TB_RES_BASE, 128, 32'hDEAD_BEEF);
  run_prog(100000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "mul program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "mul raised an illegal instruction (it is legal in Zmmul)")
  `TC_CHECK(tb_sts_err_events == 0,        "mul program set sts.err")
  for (k = 0; k < nslot; k++) begin
    res_rd(k, d);
    if (d !== exp_v[k]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_v[k], $sformatf("mul slot %0d = %08h, expected %08h", k, d, exp_v[k]))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d mul results differ", nerr))
  mon_check_all();
endtask
