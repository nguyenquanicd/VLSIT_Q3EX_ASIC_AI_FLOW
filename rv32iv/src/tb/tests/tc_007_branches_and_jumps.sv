// TC-007 | REQ-001, REQ-003
// Branches and jumps:
//   * 36 cases: beq/bne/blt/bge/bltu/bgeu x 6 operand pairs, each taken or not taken; two shadow instructions
//     (addi x5,+1 / addi x5,+2) follow the branch: x5 must be 3 when not taken and 0 when taken (flushed).
//   * backward loops (bne, blt) with known iteration counts.
//   * jal with link register (value = address of the jal + 4) and jal x0 (no link, shadow flushed).
//   * jalr (target and link, with and without immediate), shadow flushed.
task automatic tc_007_branches_and_jumps();
  logic [31:0] opa [0:5];
  logic [31:0] opb [0:5];
  logic [31:0] exp_v [0:63];
  logic [31:0] a, b, d;
  int          t, p, c, nslot, pc0, nerr;
  bit          taken;

  opa[0] = 32'h0000_0000; opb[0] = 32'h0000_0000;
  opa[1] = 32'h0000_0001; opb[1] = 32'h0000_0002;
  opa[2] = 32'h0000_0002; opb[2] = 32'h0000_0001;
  opa[3] = 32'hFFFF_FFFF; opb[3] = 32'h0000_0001;
  opa[4] = 32'h0000_0001; opb[4] = 32'hFFFF_FFFF;
  opa[5] = 32'h8000_0000; opb[5] = 32'h7FFF_FFFF;
  nslot = 0;
  nerr  = 0;

  prog_reset();
  emit_res_init();
  emit(rv_addi(5'd11, 5'd0, 0));                         // x11: shadow marker for jal/jalr, must stay 0

  // ---------------- conditional branches over a two-instruction shadow
  for (t = 0; t < 6; t++) begin
    for (p = 0; p < 6; p++) begin
      a = opa[p];
      b = opb[p];
      emit_li(5'd1, a);
      emit_li(5'd2, b);
      emit(rv_addi(5'd5, 5'd0, 0));
      case (t)
        0: begin emit(rv_beq (5'd1, 5'd2, 12)); taken = (a == b); end
        1: begin emit(rv_bne (5'd1, 5'd2, 12)); taken = (a != b); end
        2: begin emit(rv_blt (5'd1, 5'd2, 12)); taken = ($signed(a) <  $signed(b)); end
        3: begin emit(rv_bge (5'd1, 5'd2, 12)); taken = ($signed(a) >= $signed(b)); end
        4: begin emit(rv_bltu(5'd1, 5'd2, 12)); taken = (a <  b); end
        default: begin emit(rv_bgeu(5'd1, 5'd2, 12)); taken = (a >= b); end
      endcase
      emit(rv_addi(5'd5, 5'd5, 1));                      // shadow 1 (executed only when not taken)
      emit(rv_addi(5'd5, 5'd5, 2));                      // shadow 2
      emit_sw_res(5'd5, nslot);                          // branch target
      exp_v[nslot] = taken ? 32'd0 : 32'd3;
      nslot++;
    end
  end

  // ---------------- backward loops
  emit(rv_addi(5'd6, 5'd0, 10));
  emit(rv_addi(5'd7, 5'd0, 0));
  emit(rv_addi(5'd7, 5'd7, 3));                          // loop: x7 += 3
  emit(rv_addi(5'd6, 5'd6, -1));
  emit(rv_bne (5'd6, 5'd0, -8));                         // 10 iterations
  emit_sw_res(5'd7, nslot);  exp_v[nslot] = 32'd30;  nslot++;

  emit(rv_addi(5'd6, 5'd0, 0));
  emit(rv_addi(5'd9, 5'd0, 5));
  emit(rv_addi(5'd6, 5'd6, 1));                          // loop: x6++ while x6 < 5 (signed)
  emit(rv_blt (5'd6, 5'd9, -4));
  emit_sw_res(5'd6, nslot);  exp_v[nslot] = 32'd5;   nslot++;

  emit(rv_addi(5'd6, 5'd0, 4));
  emit(rv_addi(5'd8, 5'd0, 0));
  emit(rv_addi(5'd8, 5'd8, 2));                          // loop: x8 += 2, x6-- while x6 != 0, taken 3 times
  emit(rv_addi(5'd6, 5'd6, -1));
  emit(rv_bgeu(5'd6, 5'd0, 8));                          // x6 >= 0 unsigned: always taken, skips the next instruction
  emit(rv_addi(5'd8, 5'd8, 100));                        // flushed
  emit(rv_bne (5'd6, 5'd0, -16));
  emit_sw_res(5'd8, nslot);  exp_v[nslot] = 32'd8;   nslot++;

  // ---------------- jal with link
  pc0 = prog_here();
  emit(rv_jal(5'd10, 8));                                // skips the next instruction
  emit(rv_addi(5'd11, 5'd11, 99));                       // shadow: must be flushed
  emit_sw_res(5'd10, nslot); exp_v[nslot] = 32'(pc0 + 4); nslot++;
  emit_sw_res(5'd11, nslot); exp_v[nslot] = 32'd0;        nslot++;

  // jal x0: no link, x0 stays 0
  emit(rv_jal(5'd0, 8));
  emit(rv_addi(5'd11, 5'd11, 98));                       // shadow
  emit(rv_add (5'd12, 5'd0, 5'd0));
  emit_sw_res(5'd12, nslot); exp_v[nslot] = 32'd0;        nslot++;
  emit_sw_res(5'd11, nslot); exp_v[nslot] = 32'd0;        nslot++;

  // jal backwards over a small body (call / return style): jal x13 -> body -> jalr x0,x13
  emit(rv_jal(5'd0, 12));                                // jump over the body to the call
  pc0 = prog_here();
  emit(rv_addi(5'd14, 5'd0, 55));                        // body (subroutine): x14 = 55
  emit(rv_jalr(5'd0, 5'd13, 0));                         // return
  emit(rv_jal(5'd13, pc0 - prog_here()));                // call (offset back to the body)
  emit_sw_res(5'd14, nslot); exp_v[nslot] = 32'd55;       nslot++;
  emit_sw_res(5'd13, nslot); exp_v[nslot] = 32'(prog_here() - 8);  nslot++;   // link = address after the call

  // ---------------- jalr: target in a register, shadow flushed
  pc0 = prog_here();
  emit(rv_auipc(5'd12, 20'h0));                          // x12 = pc0
  emit(rv_addi (5'd12, 5'd12, 16));                      // x12 = pc0 + 16 (target)
  emit(rv_jalr (5'd13, 5'd12, 0));                       // pc0 + 8
  emit(rv_addi (5'd11, 5'd11, 77));                      // shadow (pc0 + 12)
  emit_sw_res(5'd13, nslot); exp_v[nslot] = 32'(pc0 + 12); nslot++;   // target at pc0 + 16
  emit_sw_res(5'd11, nslot); exp_v[nslot] = 32'd0;         nslot++;

  pc0 = prog_here();
  emit(rv_auipc(5'd12, 20'h0));
  emit(rv_addi (5'd12, 5'd12, 20));                      // x12 = pc0 + 20
  emit(rv_jalr (5'd14, 5'd12, -4));                      // target = pc0 + 16, link = pc0 + 12
  emit(rv_addi (5'd11, 5'd11, 66));                      // shadow
  emit_sw_res(5'd14, nslot); exp_v[nslot] = 32'(pc0 + 12); nslot++;
  emit_sw_res(5'd11, nslot); exp_v[nslot] = 32'd0;         nslot++;

  emit_halt();

  dmem_fill(TB_RES_BASE, 64, 32'hDEAD_BEEF);
  run_prog(100000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "branch/jump program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "illegal instruction in the branch/jump program")
  `TC_CHECK(tb_sts_err_events == 0,        "sts.err event during the branch/jump program")
  for (c = 0; c < nslot; c++) begin
    res_rd(c, d);
    if (d !== exp_v[c]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_v[c], $sformatf("slot %0d (case %0d): got %08h expected %08h", c, c, d, exp_v[c]))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d branch/jump results differ", nerr))
  mon_check_all();
endtask
