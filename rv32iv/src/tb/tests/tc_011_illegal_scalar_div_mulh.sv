// TC-011 | REQ-002, REQ-052, REQ-053
// One program (= one reset) per illegal scalar opcode: div, divu, rem, remu, mulh, mulhsu, mulhu and unknown words
// (all-zero, all-one, custom-0, OP-32, reserved). Each program: older sw (must complete), the illegal word,
// younger sw (must have no effect), ebreak. Expected: o_halt=1, o_err_illegal=1, sts.err event, PC stops and
// o_halt stays 1, older store visible in DMEM, younger store absent.
task automatic tc_011_illegal_scalar_div_mulh();
  logic [31:0] ops [0:11];
  string       nm  [0:11];
  logic [31:0] d;
  int          c;

  ops[0]  = rv_div   (5'd3, 5'd1, 5'd2);  nm[0]  = "div";
  ops[1]  = rv_divu  (5'd3, 5'd1, 5'd2);  nm[1]  = "divu";
  ops[2]  = rv_rem   (5'd3, 5'd1, 5'd2);  nm[2]  = "rem";
  ops[3]  = rv_remu  (5'd3, 5'd1, 5'd2);  nm[3]  = "remu";
  ops[4]  = rv_mulh  (5'd3, 5'd1, 5'd2);  nm[4]  = "mulh";
  ops[5]  = rv_mulhsu(5'd3, 5'd1, 5'd2);  nm[5]  = "mulhsu";
  ops[6]  = rv_mulhu (5'd3, 5'd1, 5'd2);  nm[6]  = "mulhu";
  ops[7]  = rv_illegal_zero();            nm[7]  = "all-zero word";
  ops[8]  = rv_illegal_ones();            nm[8]  = "all-one word";
  ops[9]  = 32'h0000_000B;                nm[9]  = "custom-0 opcode";
  ops[10] = 32'h0000_003B;                nm[10] = "OP-32 opcode (RV64 only)";
  ops[11] = 32'h0000_007F;                nm[11] = "reserved 0x7F opcode";

  for (c = 0; c < 12; c++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd1, 32'h0000_0064);
    emit_li(5'd2, 32'h0000_0007);
    emit_li(5'd4, 32'hAAAA_0000 + c);
    emit_sw_res(5'd4, 0);                                 // older store: must complete
    emit(ops[c]);                                         // illegal word
    emit_li(5'd5, 32'hBBBB_0000 + c);
    emit_sw_res(5'd5, 1);                                 // younger store: must not execute
    emit_sw_res(5'd5, 2);
    emit_halt();

    dmem_fill(TB_RES_BASE, 4, 32'hC0FF_EE11);
    run_prog(3000);                                       // includes the post-halt drain

    `TC_CHECK(tb_run_hit && o_halt === 1'b1,   $sformatf("[%s] core did not halt", nm[c]))
    `TC_CHECK(o_err_illegal === 1'b1,          $sformatf("[%s] o_err_illegal not 1", nm[c]))
    `TC_CHECK(tb_sts_err_events >= 1,          $sformatf("[%s] sts.err not set (no hardware set event)", nm[c]))
    chk_halted_stable(8);                                 // PC stopped, o_halt / o_err_illegal sticky, no requests
    res_rd(0, d);
    `TC_CHECK(d === (32'hAAAA_0000 + c), $sformatf("[%s] older store missing: %08h", nm[c], d))
    res_rd(1, d);
    `TC_CHECK(d === 32'hC0FF_EE11,       $sformatf("[%s] younger store 1 executed: %08h", nm[c], d))
    res_rd(2, d);
    `TC_CHECK(d === 32'hC0FF_EE11,       $sformatf("[%s] younger store 2 executed: %08h", nm[c], d))
  end
  mon_check_all();
endtask
