// TC-014 | REQ-084, REQ-052, REQ-073, REQ-003
// Part A (v0..v4): an illegal instruction and an ebreak in the shadow of a taken branch/jump (flushed before
//   commit) have no effect: no halt from them, o_err_illegal=0, no sts.err (read via lw), execution continues
//   at the target and ends with the final ebreak.
// Part B (v5, v6): the same instructions on the correct path do halt.
// run_prog() returns after the post-halt drain, so older stores have landed and the monitor has counted the
// o_err_illegal rise (sts.err event) before snap_status() and the first host access.
task automatic tc_014_illegal_in_wrong_path_not_halting();
  int          v, i, t0;
  logic [31:0] shw0, shw1, r0, r1;

  for (v = 0; v < 7; v++) begin
    // clear result slots 0..7
    for (i = 0; i < 8; i++) dmem_wr(TB_RES_BASE + 4 * i, 32'h0);

    prog_reset();
    emit_res_init();
    emit(rv_addi(1, 0, 1));
    if (v <= 4) begin
      case (v)
        0: begin shw0 = rv_div(2, 1, 1);      shw1 = rv_ebreak();        end
        1: begin shw0 = rv_ecall();           shw1 = rv_ebreak();        end
        2: begin shw0 = rv_illegal_zero();    shw1 = rv_ebreak();        end
        3: begin shw0 = rv_ebreak();          shw1 = rv_div(2, 1, 1);    end
        default: begin shw0 = rv_ecall();     shw1 = rv_illegal_ones();  end
      endcase
      if (v == 2) begin                         // jalr: addi(t0) nop(t0+4) jalr(t0+8) shadow(t0+12,t0+16) target(t0+20)
        t0 = prog_here();
        emit(rv_addi(2, 0, t0 + 20));
        emit(rv_nop());
        emit(rv_jalr(0, 2, 0));
      end else begin
        case (v)
          0: emit(rv_beq(0, 0, 12));
          1: emit(rv_jal(0, 12));
          3: emit(rv_bne(1, 0, 12));
          default: emit(rv_bgeu(1, 0, 12));
        endcase
      end
      emit(shw0);                               // wrong-path instruction 1
      emit(shw1);                               // wrong-path instruction 2
      // branch/jump target
      emit_li(5, 32'h600D);
      emit_sw_res(5, 0);                        // marker: execution continued at the target
      emit_li(4, CSR_STS);
      emit(rv_lw(3, 4, 0));
      emit_sw_res(3, 1);                        // sts (bit 2 = err) must stay 0
      emit_halt();
    end else if (v == 5) begin                  // correct-path illegal instruction
      emit_li(5, 32'h1111);
      emit_sw_res(5, 2);
      emit(rv_div(2, 1, 1));
      emit_li(5, 32'h2222);
      emit_sw_res(5, 3);                        // must not execute
      emit_halt();
    end else begin                              // correct-path ebreak
      emit_li(5, 32'h3333);
      emit_sw_res(5, 4);
      emit_halt();
      emit_li(5, 32'h4444);
      emit_sw_res(5, 5);                        // must not execute
      emit_halt();
    end

    run_prog(3000);
    snap_status();

    // TC-014 | REQ-084, REQ-052
    `TC_CHECK(tb_run_hit, $sformatf("variant %0d: core did not halt", v))
    `TC_CHECK(snap_halt === 1'b1, $sformatf("variant %0d: o_halt not 1 at the end", v))
    if (v <= 4) begin
      res_rd(0, r0);
      res_rd(1, r1);
      `TC_CHECK(snap_err_illegal === 1'b0, $sformatf("variant %0d: wrong-path instruction raised o_err_illegal", v))
      `TC_CHECK(snap_sts_err_events == 0, $sformatf("variant %0d: wrong-path instruction set sts.err", v))
      `TC_CHECK(r0 === 32'h600D, $sformatf("variant %0d: execution did not continue at the target (marker=%08h)", v, r0))
      `TC_CHECK(r1[2] === 1'b0, $sformatf("variant %0d: sts.err read via lw is set (sts=%08h)", v, r1))
    end else if (v == 5) begin
      res_rd(2, r0);
      res_rd(3, r1);
      // TC-014 | REQ-052: same instruction on the correct path halts
      `TC_CHECK(snap_err_illegal === 1'b1, "correct-path illegal instruction did not raise o_err_illegal")
      `TC_CHECK(snap_sts_err_events >= 1, "correct-path illegal instruction did not set sts.err")
      `TC_CHECK(r0 === 32'h1111, $sformatf("older store before the illegal instruction missing (%08h)", r0))
      `TC_CHECK(r1 === 32'h0, $sformatf("younger store after the illegal instruction was executed (%08h)", r1))
    end else begin
      res_rd(4, r0);
      res_rd(5, r1);
      // TC-014 | REQ-073: same ebreak on the correct path halts without error
      `TC_CHECK(snap_err_illegal === 1'b0, "correct-path ebreak raised o_err_illegal")
      `TC_CHECK(snap_sts_err_events == 0, "correct-path ebreak set sts.err")
      `TC_CHECK(r0 === 32'h3333, $sformatf("older store before ebreak missing (%08h)", r0))
      `TC_CHECK(r1 === 32'h0, $sformatf("younger store after ebreak was executed (%08h)", r1))
    end
  end

  mon_check_all();
endtask
