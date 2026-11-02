// TC-008 | REQ-001, REQ-011, REQ-015
// Aligned lb/lh/lw/lbu/lhu/sb/sh/sw over all four lanes of four DMEM rows (16 words):
//   Part A (loads): per word 13 loads (lw, lh@0/2, lhu@0/2, lb@0..3, lbu@0..3) with sign / zero extension.
//   Part B (stores): per word sb at one byte offset, sh at one half-word offset (and sw for every 5th word) on a
//   second window; only the addressed bytes may change (all 16 words compared via host reads).
task automatic tc_008_load_store_aligned();
  logic [7:0]  ma [0:63];          // load window model
  logic [7:0]  mb [0:63];          // store window model
  logic [31:0] exp_v [0:255];
  logic [31:0] rnd, v, d, wa, wb;
  int          w, k, nslot, nerr, off, sbo, sho;
  logic [31:0] LA, LB;

  LA = TB_DATA_BASE;               // load window  (rows 0..3 -> 64 bytes)
  LB = TB_DATA_BASE + 32'h200;     // store window
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

  // ---------------- Part A: loads
  for (w = 0; w < 16; w++) begin
    off = 4 * w;
    emit(rv_lw (5'd2, 5'd30, off));
    emit_sw_res(5'd2, nslot);  exp_v[nslot] = {ma[off+3], ma[off+2], ma[off+1], ma[off]};  nslot++;
    for (k = 0; k < 4; k += 2) begin
      emit(rv_lh (5'd2, 5'd30, off + k));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = 32'(sx({16'h0, ma[off+k+1], ma[off+k]}, 16));  nslot++;
      emit(rv_lhu(5'd2, 5'd30, off + k));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = {16'h0, ma[off+k+1], ma[off+k]};               nslot++;
    end
    for (k = 0; k < 4; k++) begin
      emit(rv_lb (5'd2, 5'd30, off + k));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = 32'(sx({24'h0, ma[off+k]}, 8));  nslot++;
      emit(rv_lbu(5'd2, 5'd30, off + k));
      emit_sw_res(5'd2, nslot);  exp_v[nslot] = {24'h0, ma[off+k]};               nslot++;
    end
  end

  // ---------------- Part B: stores on the second window (model applied in program order)
  for (w = 0; w < 16; w++) begin
    off = 4 * w;
    if ((w % 5) == 0) begin                                  // sw first
      v = tb_rand32();
      emit_li(5'd3, v);
      emit(rv_sw(5'd3, 5'd29, off));
      {mb[off+3], mb[off+2], mb[off+1], mb[off]} = v;
    end
    sbo = w % 4;                                              // sb at byte offset (w mod 4)
    v   = tb_rand32();
    emit_li(5'd3, v);
    emit(rv_sb(5'd3, 5'd29, off + sbo));
    mb[off + sbo] = v[7:0];
    sho = 2 * ((w / 2) % 2);                                  // sh at half-word offset 0 or 2
    v   = tb_rand32();
    emit_li(5'd3, v);
    emit(rv_sh(5'd3, 5'd29, off + sho));
    mb[off + sho]     = v[7:0];
    mb[off + sho + 1] = v[15:8];
  end
  emit_halt();

  run_prog(60000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "aligned loads/stores raised an illegal instruction")
  `TC_CHECK(tb_sts_err_events == 0,        "aligned loads/stores set sts.err")

  for (k = 0; k < nslot; k++) begin
    res_rd(k, d);
    if (d !== exp_v[k]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_v[k], $sformatf("load result slot %0d = %08h, expected %08h", k, d, exp_v[k]))
    end
  end
  for (w = 0; w < 16; w++) begin                              // store window: all words (partial stores)
    dmem_rd(LB + 32'(4 * w), d);
    wb = {mb[4*w+3], mb[4*w+2], mb[4*w+1], mb[4*w]};
    if (d !== wb) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === wb, $sformatf("store window word %0d = %08h, expected %08h", w, d, wb))
    end
    dmem_rd(LA + 32'(4 * w), d);                              // load window must be untouched
    wa = {ma[4*w+3], ma[4*w+2], ma[4*w+1], ma[4*w]};
    if (d !== wa) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === wa, $sformatf("load window word %0d changed: %08h expected %08h", w, d, wa))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d load/store mismatches", nerr))
  mon_check_all();
endtask
