// TC-022 | REQ-077, REQ-004
// vsetvli zero,zero,<new SEW> keeps vl and writes the new SEW (legal setting), without a VLMAX-preservation check.
//   A: e8 / vl=16, vle8 v1; vsetvli zero,zero,e32 (vl stays 16 although VLMAX(e32) = 4); vse8 v1 stores 16 bytes
//   B: e8 / vl=4; vsetvli zero,zero,e32 (vl stays 4 = VLMAX(e32)); vadd.vx at SEW=32 adds to whole words and
//      vse32 stores 4 words -> proves SEW changed to 32 and vl was kept
//   D: vsetvli zero,x10,e8 (rd = x0, rs1 != x0) sets vl = 7 (vse8 stores exactly 7 bytes)
task automatic tc_022_vsetvli_zero_zero_keeps_vl();
  logic [7:0]  b1 [0:15];
  logic [31:0] w2 [0:3];
  logic [31:0] DATA1, DATA2, AOUT, BOUT, DOUT, d, ev;
  int          i, k, nerr;

  DATA1 = TB_DATA_BASE;
  DATA2 = TB_DATA_BASE + 32'h40;
  AOUT  = TB_DATA_BASE + 32'h100;
  BOUT  = TB_DATA_BASE + 32'h110;
  DOUT  = TB_DATA_BASE + 32'h120;
  nerr  = 0;
  for (i = 0; i < 16; i++) b1[i] = 8'h80 + 8'(i * 3);
  for (k = 0; k < 4; k++) w2[k] = {8'(k * 16 + 4), 8'(k * 16 + 3), 8'(k * 16 + 2), 8'(k * 16 + 1)};

  for (k = 0; k < 4; k++) begin
    dmem_wr(DATA1 + 32'(4 * k), {b1[4*k+3], b1[4*k+2], b1[4*k+1], b1[4*k]});
    dmem_wr(DATA2 + 32'(4 * k), w2[k]);
  end
  for (k = 0; k < 12; k++) dmem_wr(AOUT + 32'(4 * k), 32'hEEEE_EEEE);

  prog_reset();
  emit_li(5'd30, DATA1);
  emit_li(5'd29, DATA2);
  emit_li(5'd14, AOUT);
  emit_li(5'd15, BOUT);
  emit_li(5'd16, DOUT);
  emit_li(5'd12, 32'h0101_0101);
  // A
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  emit(rv_vle8(5'd1, 5'd30));
  emit(rv_vsetvli(5'd0, 5'd0, vtype_zimm(32)));       // zero,zero: keep vl = 16, SEW = 32
  emit(rv_vse8(5'd1, 5'd14));
  // B
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
  emit(rv_vle8(5'd1, 5'd29));
  emit_li(5'd10, 32'd4);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));      // vl = 4
  emit(rv_vsetvli(5'd0, 5'd0, vtype_zimm(32)));       // zero,zero: keep vl = 4, SEW = 32
  emit(rv_vadd_vx(5'd2, 5'd1, 5'd12));
  emit(rv_vse32(5'd2, 5'd15));
  // D
  emit_li(5'd10, 32'd16);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));      // v1 still holds DATA2 bytes
  emit_li(5'd10, 32'd7);
  emit(rv_vsetvli(5'd0, 5'd10, vtype_zimm(8)));       // rd = x0, rs1 != x0: vl = 7
  emit(rv_vse8(5'd1, 5'd16));
  emit_halt();

  run_prog(10000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "legal vsetvli zero,zero / vadd raised an illegal instruction")

  for (i = 0; i < 16; i++) begin                      // A: 16 bytes stored => vl was kept (not clipped to 4)
    dmem_rd(AOUT + 32'(i & ~3), d);
    `TC_CHECK(d[8*(i%4) +: 8] === b1[i],
              $sformatf("A: byte %0d = %02h, expected %02h (vl must stay 16 after zero,zero e32)", i, d[8*(i%4) +: 8], b1[i]))
  end
  for (k = 0; k < 4; k++) begin                       // B: SEW=32 add on 4 words
    dmem_rd(BOUT + 32'(4 * k), d);
    ev = w2[k] + 32'h0101_0101;
    if (d !== ev) begin
      nerr++;
      `TC_CHECK(d === ev, $sformatf("B: word %0d = %08h, expected %08h (SEW must be 32, vl kept 4)", k, d, ev))
    end
  end
  for (i = 0; i < 16; i++) begin                      // D: exactly 7 bytes stored
    dmem_rd(DOUT + 32'(i & ~3), d);
    ev = (i < 7) ? w2[i / 4][8*(i%4) +: 8] : 8'hEE;
    `TC_CHECK(d[8*(i%4) +: 8] === ev[7:0],
              $sformatf("D: byte %0d = %02h, expected %02h (vl must be 7)", i, d[8*(i%4) +: 8], ev[7:0]))
  end
  `TC_CHECK(nerr == 0, "SEW/vl mismatches")
  mon_check_all();
endtask
