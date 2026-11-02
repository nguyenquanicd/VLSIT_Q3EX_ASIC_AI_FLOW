// TC-051 | REQ-045, REQ-046, REQ-047, REQ-048, REQ-049, REQ-050
// Elaboration negative tests. A single simulation elaborates ONE parameter set (here PARA_VLEN=128,
// PARA_LANE_COUNT=4), so the "illegal values are rejected with $error in a generate-if" part is run by the flow
// script, one compile per set with -G overrides (design choice Q-TP23): the set passes if elaboration FAILS with the
// $error text. This TC (a) prints the list of sets the script must compile (TC_INFO ELAB_EXPECT_FAIL ...),
// (b) checks with the TB's own predicate of constraints C1/C2/C3 that every listed set really is illegal and the
// running configuration is legal, and (c) proves in the running DUT that the legal default build elaborated and
// has the VLMAX of its parameters (vsetvli returns PARA_VLEN/8 at SEW=8).
task automatic tc_051_param_illegal_rejected();
  logic [31:0] iv [0:11];
  logic [31:0] il [0:11];
  logic [31:0] d;
  bit          c1, c2, c3, leg;
  int          k;

  iv[0] = 64;   il[0] = 4;     // C1: PARA_VLEN not 128/256
  iv[1] = 192;  il[1] = 4;
  iv[2] = 512;  il[2] = 4;
  iv[3] = 0;    il[3] = 4;
  iv[4] = 100;  il[4] = 4;
  iv[5] = 128;  il[5] = 0;     // C2: PARA_LANE_COUNT not 1/2/4/8
  iv[6] = 128;  il[6] = 3;
  iv[7] = 128;  il[7] = 16;
  iv[8] = 256;  il[8] = 16;
  iv[9] = 128;  il[9] = 8;     // C3: 128 % (8*32) != 0
  iv[10] = 256; il[10] = 5;
  iv[11] = 256; il[11] = 6;

  for (k = 0; k < 12; k++) begin
    c1  = (iv[k] == 128 || iv[k] == 256);
    c2  = (il[k] == 1 || il[k] == 2 || il[k] == 4 || il[k] == 8);
    c3  = (il[k] != 0) && ((iv[k] % (il[k] * 32)) == 0);
    leg = c1 && c2 && c3;
    `TC_CHECK(!leg, $sformatf("set PARA_VLEN=%0d PARA_LANE_COUNT=%0d is listed as illegal but satisfies C1..C3", iv[k], il[k]))
    $display("TC_INFO ELAB_EXPECT_FAIL PARA_VLEN=%0d PARA_LANE_COUNT=%0d (C1=%0d C2=%0d C3=%0d)",
             iv[k], il[k], c1, c2, c3);
  end

  // the running configuration must itself be legal
  c1  = (PARA_VLEN == 128 || PARA_VLEN == 256);
  c2  = (PARA_LANE_COUNT == 1 || PARA_LANE_COUNT == 2 || PARA_LANE_COUNT == 4 || PARA_LANE_COUNT == 8);
  c3  = ((PARA_VLEN % (PARA_LANE_COUNT * 32)) == 0);
  `TC_CHECK(c1 && c2 && c3, "running configuration violates C1..C3 (it must not have elaborated)")

  // the legal build runs: VLMAX at SEW=8 is PARA_VLEN/8
  prog_reset();
  emit_res_init();
  emit_li(5'd10, 32'd1030);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  emit_sw_res(5'd11, 0);
  emit_halt();
  run_prog(2000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1 && o_err_illegal === 1'b0, "legal default build did not run a vsetvli program")
  res_rd(0, d);
  `TC_CHECK(d === VLMAX_E8, $sformatf("vsetvli AVL=1030 e8 returned %0d, expected PARA_VLEN/8 = %0d", d, VLMAX_E8))
  mon_check_all();
endtask
