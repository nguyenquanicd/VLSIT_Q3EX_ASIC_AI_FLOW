// TC-019 | REQ-010, REQ-019
// IMEM depth and fetch: a chain of 11 three-word nodes {addi x2,#; sw x2,slot(x31); jal next} is host-loaded at
// scattered word indices (8, 255/256 boundary, 511/512, 1022, 2046, three random words, the 4095/4096 boundary,
// 6143, and the very last words 8189..8191 = 0x7FF4..0x7FFC). The CPU executes the chain: every node must run
// (distinct marker per node), execution crosses word boundaries and jumps to/from the last IMEM word. Nodes sit
// at power-of-two distances, so an aliased IMEM address would overwrite another node and break the chain.
task automatic tc_019_imem_depth_and_fetch();
  int          nw [0:10];
  int          j, target, nerr;
  logic [31:0] rnd, d;

  rnd = tb_rand32();  nw[5] = 3000 + int'(rnd % 900);
  rnd = tb_rand32();  nw[7] = 5000 + int'(rnd % 900);
  rnd = tb_rand32();  nw[9] = 7000 + int'(rnd % 900);
  nw[0] = 8;     nw[1] = 255;   nw[2] = 511;   nw[3] = 1022;  nw[4] = 2046;
  nw[6] = 4094;  nw[8] = 6143;  nw[10] = 8189;

  prog_reset();
  emit_res_init();                                     // w0: lui x31, result base
  emit(rv_jal(5'd0, (nw[0] - 1) * 4));                 // w1: jump to node 0
  emit(rv_ebreak());                                   // w2: epilogue
  for (j = 0; j < 11; j++) begin
    prog_org(nw[j]);
    emit(rv_addi(5'd2, 5'd0, 32'h100 + j));
    emit(rv_sw(5'd2, 5'd31, 4 * j));
    target = (j < 10) ? nw[j + 1] : 2;
    emit(rv_jal(5'd0, (target - (nw[j] + 2)) * 4));    // last node (jal at 0x7FFC) jumps back to the epilogue
  end

  for (j = 0; j < 11; j++) dmem_wr(TB_RES_BASE + 32'(4 * j), 32'h0);
  run_prog(20000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "IMEM chain did not reach the epilogue ebreak (word lost / aliased?)")
  `TC_CHECK(o_err_illegal === 1'b0, "illegal instruction fetched from IMEM")
  nerr = 0;
  for (j = 0; j < 11; j++) begin
    res_rd(j, d);
    if (d !== 32'h100 + j) begin
      nerr++;
      `TC_CHECK(d === 32'h100 + j, $sformatf("node %0d at word %0d did not execute (marker %08h)", j, nw[j], d))
    end
  end
  `TC_CHECK(nerr == 0, "some IMEM nodes were not executed")
  mon_check_all();
endtask
