// TC-050 | REQ-023, REQ-034
// Ownership rule of the host port: i_ld_en is 0 at every rising edge where i_rst_n_core = 1 (checked for every cycle
// of every test by the always-on monitor tb_ldv_cnt), i_ld_en is dropped no later than reset release, and the TB
// never issues a host access (i_ld_req) while reset is released.
//   Part A: all TB reset/host sequences (host_begin/host_end, reset_dut, off-edge assert/release): explicit
//           per-cycle check of the rule plus the monitor counter.
//   Part B: self-test of the checker: one deliberate 1-cycle i_ld_en = 1 (no request) with reset released while the
//           core is halted; the monitor must count exactly one violation (then the counter is cleared).
task automatic tc_050_host_ld_en_ownership_checker();
  int k, s;
  logic [31:0] d;

  prog_reset();
  emit(rv_nop());
  emit_halt();

  // ---- Part A
  for (s = 0; s < 4; s++) begin
    // host sequence: reset asserted first, i_ld_en raised only while in reset, dropped with the release
    host_begin();
    `TC_CHECK(i_rst_n_core === 1'b0 && i_ld_en === 1'b1, "host mode: i_ld_en=1 only while reset is asserted")
    host_load_prog();
    dmem_wr(TB_DATA_BASE + 32'(4 * s), 32'hA5A5_0000 + s);
    `TC_CHECK(!(i_ld_en === 1'b1 && i_rst_n_core === 1'b1), "i_ld_en high with reset released during host accesses")
    case (s)
      0: host_end();
      1: begin                                          // reset pulse with i_ld_en dropped first
           reset_dut(3);
         end
      2: begin                                          // release off the clock edge
           wait_cycles(1);
           rst_release_offedge();
         end
      default: begin                                    // re-assert asynchronously, then release
           i_ld_req = 1'b0;
           rst_assert_offedge();
           wait_cycles(2);
           host_end();
         end
    endcase
    for (k = 0; k < 40; k++) begin
      tick();
      `TC_CHECK(!(i_rst_n_core === 1'b1 && i_ld_en === 1'b1), "i_ld_en must be 0 whenever reset is released")
      `TC_CHECK(!(i_rst_n_core === 1'b1 && i_ld_en === 1'b1 && i_ld_req === 1'b1),
                "host access issued while reset is released")
    end
  end
  wait_halt(200);
  `TC_CHECK(o_halt === 1'b1, "halt program did not halt")
  `TC_CHECK(tb_ldv_cnt == 0, "monitor reported i_ld_en = 1 with reset released during the TB reset/host sequences")
  for (k = 0; k < 4; k++) begin
    dmem_rd(TB_DATA_BASE + 32'(4 * k), d);
    `TC_CHECK(d === (32'hA5A5_0000 + k), "host DMEM write in reset lost")
  end
  host_end();                                           // back to a halted core with reset released
  wait_halt(200);
  `TC_CHECK(o_halt === 1'b1, "core must halt again after the last release")

  // ---- Part B: the checker itself (core is halted, no request is issued, so the DUT sees no access)
  mon_clear();
  i_ld_req   = 1'b0;
  i_ld_wr_en = 1'b0;
  i_ld_en    = 1'b1;                                    // deliberate integration error for exactly one cycle
  tick();
  i_ld_en    = 1'b0;
  `TC_CHECK(tb_ldv_cnt == 1, $sformatf("ownership monitor must flag the deliberate i_ld_en=1 cycle (count=%0d)", tb_ldv_cnt))
  tick();
  `TC_CHECK(tb_ldv_cnt == 1, "ownership monitor must not count cycles with i_ld_en = 0")
  mon_clear();                                          // remove the deliberate violation from the TC statistics
  `TC_CHECK(tb_ldv_cnt == 0, "monitor counter not cleared")
  `TC_CHECK(o_halt === 1'b1 && o_err_illegal === 1'b0, "halted core disturbed by the one-cycle i_ld_en pulse")
  mon_check_all();
endtask
