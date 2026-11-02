// TC-013 | REQ-001, REQ-003, REQ-011
// Differential time-to-halt measurements (tb_run_cycles = cycles from reset release to the FIRST o_halt cycle;
// wait_halt() drains after that without changing it):
//   v0/v1 : N independent instructions -> +1 cycle each (one instruction per cycle absent hazards)
//   v2/v3/v4/v5 : load-use costs exactly 1 bubble
//   v6/v7 : a not-taken branch adds no stall
// Taken-branch penalty and dot-product iteration length are only logged (TC_INFO), never checked.
task automatic tc_013_pipeline_timing_differential();
  longint unsigned t [0:15];
  int v;
  int k;
  int n_vec;

  dmem_wr(TB_DATA_BASE, 32'h0000_1234);       // known word for the loads

  for (v = 0; v < 9; v++) begin
    prog_reset();
    emit_li(1, TB_DATA_BASE);                 // x1 = data address (non-zero)
    for (k = 0; k < 6; k++) emit(rv_nop());   // let x1 settle: identical prefix in every variant
    case (v)
      0: begin
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      1: begin
        for (k = 0; k < 12; k++) emit(rv_addi(5 + (k % 20), 0, k + 1));
      end
      2: begin                                // load, immediate use of rd as rs1
        emit(rv_lw(2, 1, 0));
        emit(rv_add(3, 2, 2));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      3: begin                                // load, one independent instruction, then use (no bubble)
        emit(rv_lw(2, 1, 0));
        emit(rv_addi(4, 0, 1));
        emit(rv_add(3, 2, 2));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      4: begin                                // load followed by an instruction independent of the load
        emit(rv_lw(2, 1, 0));
        emit(rv_add(3, 1, 1));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      5: begin                                // load, immediate use of rd as rs2
        emit(rv_lw(2, 1, 0));
        emit(rv_add(3, 1, 2));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      6: begin                                // not-taken branch (x1 != 0)
        emit(rv_beq(1, 0, 8));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      7: begin                                // same instruction count, plain addi instead of the branch
        emit(rv_addi(4, 0, 1));
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      8: begin                                // taken branch over one instruction (penalty logged only)
        emit(rv_beq(0, 0, 8));
        emit(rv_nop());
        for (k = 0; k < 4; k++) emit(rv_addi(5 + k, 0, k + 1));
      end
      default: ;
    endcase
    emit_halt();
    run_prog(2000);
    snap_status();
    t[v] = tb_run_cycles;
    // TC-013 | REQ-001
    `TC_CHECK(tb_run_hit, $sformatf("variant %0d did not halt (timeout)", v))
    `TC_CHECK(snap_halt === 1'b1 && snap_err_illegal === 1'b0,
              $sformatf("variant %0d: expected ebreak halt without o_err_illegal", v))
  end

  // TC-013 | REQ-001: one instruction per cycle absent hazards
  `TC_CHECK(t[1] - t[0] == 8, $sformatf("8 extra independent instructions must cost exactly 8 cycles (t0=%0d t1=%0d)", t[0], t[1]))
  // TC-013 | REQ-003: exactly one bubble for load followed by an immediate use
  `TC_CHECK(t[2] == t[3], $sformatf("load-use must cost exactly 1 bubble: load+use=%0d, load+indep+use=%0d", t[2], t[3]))
  `TC_CHECK(t[2] - t[4] == 1, $sformatf("load-use bubble must be 1 cycle: load+use=%0d, load+indep=%0d", t[2], t[4]))
  `TC_CHECK(t[5] == t[2], $sformatf("load-use bubble on rs2 must equal rs1 case: %0d vs %0d", t[5], t[2]))
  // TC-013 | REQ-003: not-taken branch adds no stall
  `TC_CHECK(t[6] == t[7], $sformatf("not-taken branch must add no stall: branch=%0d, addi=%0d", t[6], t[7]))
  // TC-013 | REQ-011: DMEM read data valid the cycle after the request (lw works in the load-use runs above)
  `TC_CHECK(t[2] > t[4], "load-use run unexpectedly not slower than the independent run")

  $display("TC_INFO TC-013 taken-branch penalty (informational) = %0d cycles", t[8] - t[7]);

  mon_check_all();

  // Informational: dot-product iteration (vsetvli + vle8 x2 + vwmul + vwredsum), not checked.
  prog_reset();
  emit_li(1, TB_DATA_BASE);
  emit(rv_addi(5, 0, 16));
  emit(rv_vsetvli(6, 5, vtype_zimm(8)));
  emit(rv_vle8(1, 1));
  emit(rv_vle8(2, 1));
  emit(rv_vwmul_vv(4, 2, 1));
  emit(rv_vwredsum_vs(8, 4, 6));
  emit_halt();
  run_prog(5000);
  n_vec = tb_vlog_n;
  if (n_vec >= 5) begin
    $display("TC_INFO TC-013 dot-product iteration (vle8,vle8,vwmul,vwredsum) latencies = %0d %0d %0d %0d cycles",
             tb_vlog_lat[1] + 1, tb_vlog_lat[2] + 1, tb_vlog_lat[3] + 1, tb_vlog_lat[4] + 1);
  end else begin
    $display("TC_INFO TC-013 dot-product iteration not measured (%0d vector instructions completed)", n_vec);
  end
endtask
