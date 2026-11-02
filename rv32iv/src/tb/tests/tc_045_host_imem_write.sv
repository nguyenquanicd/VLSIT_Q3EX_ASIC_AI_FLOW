// TC-045 | REQ-019, REQ-042
// Host IMEM write in reset: the whole word at index addr[14:2] is written, i_ld_byte_en and addr[1:0] are ignored,
// writes with i_ld_req=0, wr_en=0 or addr[31:15] != 0 do nothing. Verified by EXECUTING the loaded code:
// a chain of nodes (addi x1 + jal) scattered over IMEM, the last node on word 8190/8191 (0x7FFC).
task automatic tc_045_host_imem_write();
  int          nodew [0:12];
  int          j, wi, style, target;
  logic [31:0] rnd, bad, d0, d1;
  logic [31:0] wa;

  // ---- program image (built with the program API, written below with deliberately odd host cycles)
  for (j = 0; j < 12; j++) begin
    rnd = tb_rand32();
    nodew[j] = 100 + j * 600 + int'(rnd % 300);
  end
  nodew[12] = 8190;                                   // last two IMEM words: addr 0x7FF8 / 0x7FFC

  prog_reset();
  emit(rv_addi(5'd1, 5'd0, 0));                       // w0  x1 = 0
  emit(rv_addi(5'd2, 5'd0, 0));                       // w1  x2 = 0
  emit_res_init();                                    // w2  lui x31, result base
  emit(rv_addi(5'd2, 5'd2, 1));                       // w3  guard: must stay addi x2,x2,1
  emit(rv_jal(5'd0, (nodew[0] - 4) * 4));             // w4  jump to node 0
  emit(rv_sw(5'd1, 5'd31, 0));                        // w5  epilogue: store x1 and x2, halt
  emit(rv_sw(5'd2, 5'd31, 4));                        // w6
  emit(rv_ebreak());                                  // w7
  for (j = 0; j < 13; j++) begin
    prog_org(nodew[j]);
    emit(rv_addi(5'd1, 5'd1, j + 1));
    target = (j < 12) ? nodew[j + 1] : 5;
    emit(rv_jal(5'd0, (target - (nodew[j] + 1)) * 4));
  end

  dmem_wr(TB_RES_BASE + 32'h0, 32'h0);
  dmem_wr(TB_RES_BASE + 32'h4, 32'h0);

  // ---- write every word back-to-back (no idle cycle) with 4 different request styles
  for (wi = 0; wi < 8192; wi++) begin
    if (prog_dirty[wi]) begin
      wa    = 32'(wi * 4);
      style = (wi + wi / 7) % 4;
      case (style)
        0:       host_cycle(1'b1, 1'b1, wa,        4'hF, prog_mem[wi]);   // plain
        1:       host_cycle(1'b1, 1'b1, wa + 32'd1, 4'h1, prog_mem[wi]);  // addr[1:0]=1, byte enable 0001
        2:       host_cycle(1'b1, 1'b1, wa + 32'd2, 4'h0, prog_mem[wi]);  // addr[1:0]=2, byte enable 0000
        default: host_cycle(1'b1, 1'b1, wa + 32'd3, 4'h6, prog_mem[wi]);  // addr[1:0]=3, byte enable 0110
      endcase
    end
  end
  host_idle();

  // ---- writes that must NOT change IMEM (the guard word 3 must stay addi x2,x2,1)
  bad = rv_addi(5'd2, 5'd2, 100);
  host_cycle(1'b0, 1'b1, 32'h0000_000C, 4'hF, bad);   // i_ld_req = 0
  host_cycle(1'b1, 1'b0, 32'h0000_000C, 4'hF, bad);   // read, wr_en = 0
  host_cycle(1'b1, 1'b1, 32'h0000_800C, 4'hF, bad);   // addr[31:15] = 1 (outside IMEM)
  host_cycle(1'b1, 1'b1, 32'h0004_000C, 4'hF, bad);   // addr[18] set
  host_cycle(1'b1, 1'b1, 32'h8000_000C, 4'hF, bad);   // addr[31] set
  host_cycle(1'b1, 1'b1, 32'hFFFF_800C, 4'hF, bad);
  host_cycle(1'b0, 1'b0, 32'h0000_000C, 4'hF, bad);   // idle with data on the bus
  host_idle();

  host_end();
  wait_halt(5000);                                    // includes the post-halt drain
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "loaded program did not reach its ebreak (IMEM word lost or corrupted)")
  `TC_CHECK(o_err_illegal === 1'b0,        "illegal instruction fetched: a host IMEM write was partial or misplaced")
  res_rd(0, d0);
  res_rd(1, d1);
  `TC_CHECK(d0 === 32'd91, $sformatf("x1 = %0d, expected 91 (sum over the 13 scattered nodes)", d0))
  `TC_CHECK(d1 === 32'd1,  $sformatf("x2 = %0d, expected 1 (guard word overwritten by a non-write)", d1))
  mon_check_all();
endtask
