// TC-009 | REQ-075, REQ-001
// Misaligned accesses to DMEM do not trap (no halt, no o_err_illegal, no sts.err):
//   loads : value = (word >> (8*addr[1:0])) with zero-filled upper bytes, then the normal sign / zero extension of
//           the access width (lw at a=1,2,3; lh/lhu at a=1,3; also lh/lhu at a=2 for reference).
//   stores: data is shifted by addr[1:0], byte enables = (mask << a) & 4'hF, bytes outside the word are dropped and
//           the neighbouring word is never touched (sw at a=1,2,3; sh at a=1,3).
task automatic tc_009_load_store_misaligned_no_trap();
  logic [7:0]  ma [0:63];          // load window model (16 words)
  logic [7:0]  mb [0:63];          // store window model (16 words)
  logic [31:0] exp_v [0:255];
  logic [31:0] rnd, v, d, wd, sh_w;
  int          w, a, k, nslot, nerr, off, c, st;
  logic [31:0] LA, LB;

  LA = TB_DATA_BASE;
  LB = TB_DATA_BASE + 32'h200;
  nslot = 0;
  nerr  = 0;

  for (w = 0; w < 16; w++) begin
    rnd = tb_rand32();
    {ma[4*w+3], ma[4*w+2], ma[4*w+1], ma[4*w]} = rnd;
    dmem_wr(LA + 32'(4 * w), rnd);
    rnd = tb_rand32();
    {mb[4*w+3], mb[4*w+2], mb[4*w+1], mb[4*w]} = rnd;
    dmem_wr(LB + 32'(4 * w), rnd);
  end
  dmem_fill(TB_RES_BASE, 256, 32'hDEAD_BEEF);

  prog_reset();
  emit_res_init();
  emit_li(5'd30, LA);
  emit_li(5'd29, LB);

  // ---------------- misaligned loads (words 1..8 of the load window; neighbours differ)
  for (w = 1; w <= 8; w++) begin
    wd = {ma[4*w+3], ma[4*w+2], ma[4*w+1], ma[4*w]};
    for (a = 1; a <= 3; a++) begin
      off = 4 * w + a;
      emit(rv_lw(5'd2, 5'd30, off));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = wd >> (8 * a);  nslot++;
    end
    for (a = 1; a <= 3; a++) begin
      off  = 4 * w + a;
      sh_w = (wd >> (8 * a)) & 32'h0000_FFFF;                // zero-filled halfword
      emit(rv_lh (5'd2, 5'd30, off));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = 32'(sx(sh_w, 16));  nslot++;
      emit(rv_lhu(5'd2, 5'd30, off));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = sh_w;               nslot++;
    end
  end

  // ---------------- misaligned stores (words 1..13 of the store window, one access per word)
  for (c = 0; c < 15; c++) begin
    w = 1 + c;                                                // neighbours w-1 and w+1 must stay untouched
    v = tb_rand32();
    emit_li(5'd3, v);
    case (c % 5)
      0: begin st = 1; a = 1; end                             // sw @+1 : bytes 1..3 <- data[7:0],[15:8],[23:16]
      1: begin st = 1; a = 2; end                             // sw @+2 : bytes 2..3
      2: begin st = 1; a = 3; end                             // sw @+3 : byte 3
      3: begin st = 0; a = 1; end                             // sh @+1 : bytes 1..2
      default: begin st = 0; a = 3; end                       // sh @+3 : byte 3 only
    endcase
    off = 4 * w + a;
    if (st == 1) begin
      emit(rv_sw(5'd3, 5'd29, off));
      for (k = 0; k < 4 - a; k++) mb[4*w + a + k] = v[8*k +: 8];
    end else begin
      emit(rv_sh(5'd3, 5'd29, off));
      for (k = 0; k < 2 && (a + k) < 4; k++) mb[4*w + a + k] = v[8*k +: 8];
    end
  end
  emit_halt();

  run_prog(60000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak (trap on a misaligned access?)")
  `TC_CHECK(o_err_illegal === 1'b0,        "misaligned access raised o_err_illegal")
  `TC_CHECK(tb_sts_err_events == 0,        "misaligned access set sts.err")

  for (k = 0; k < nslot; k++) begin
    res_rd(k, d);
    if (d !== exp_v[k]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_v[k], $sformatf("misaligned load slot %0d = %08h, expected %08h", k, d, exp_v[k]))
    end
  end
  for (w = 0; w < 16; w++) begin
    dmem_rd(LB + 32'(4 * w), d);
    wd = {mb[4*w+3], mb[4*w+2], mb[4*w+1], mb[4*w]};
    if (d !== wd) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === wd, $sformatf("store window word %0d = %08h, expected %08h (shifted bytes / dropped bytes / neighbour)", w, d, wd))
    end
    dmem_rd(LA + 32'(4 * w), d);
    wd = {ma[4*w+3], ma[4*w+2], ma[4*w+1], ma[4*w]};
    `TC_CHECK(d === wd, $sformatf("load window word %0d changed by loads: %08h", w, d))
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d misaligned access mismatches", nerr))
  mon_check_all();
endtask
