// TC-031 | REQ-009, REQ-031, REQ-032, REQ-034, REQ-036, REQ-037, REQ-080, REQ-081, REQ-087
// Vector instructions between scalar instructions (one program, 9 vector commands):
//   vsetvli e8, vle8, vle8, vwmul.vv, vmv.v.x, vwredsum.vs (back to back), vsetvli e32, vmv.x.s, vse32.
//   * the pipeline is stalled while a command executes: no CPU data request and no APB transfer between the
//     command transfer and the done pulse (checked cycle by cycle in the run loop);
//   * every command (including vsetvli) takes at least 5 cycles from start to o_resp_done (REQ-087, six states);
//   * cmd valid/instr/rs1/rs2 stable until transfer, ready only in IDLE, done a 1-cycle pulse, CPU and VPU never
//     request DMEM in the same cycle: monitors, evaluated by mon_check_all();
//   * scalar write-back in the done cycle: add x6,x5,x5 right behind vsetvli, addi x8,x7,1 right behind vmv.x.s
//     (immediate use); o_resp_rd_valid / o_resp_rd_data of vsetvli and vmv.x.s are logged and checked;
//   * the VPU memory FSM runs once per memory instruction (vle8, vle8, vse32 -> 3 accesses);
//   * a scalar lw right behind the vse32 sees the stored data.
task automatic tc_031_vector_dispatch_stall();
  logic [31:0] w [0:8];
  logic [31:0] d;
  int          nw, k, busy_cyc, bad_cpu, bad_apb, i;
  longint      sum;

  sum = 4 * (128 * 128 + 127 * 127 + 1 + 1);            // bytes 80 7F FF 01 repeated, vwmul squares, vl = 16

  prog_reset();
  emit_res_init();
  emit_li(5'd30, TB_DATA_BASE);
  emit_li(5'd29, TB_DATA_BASE + 32'h40);
  repeat (4) emit(rv_nop());
  nw = 0;
  w[nw] = rv_vsetvli(5'd5, 5'd0, vtype_zimm(8));  emit(w[nw]);  nw++;      // 0: rd = 16
  emit(rv_add(5'd6, 5'd5, 5'd5));                                           // immediate use of the vsetvli rd
  emit_sw_res(5'd6, 0);                                                     // 32
  repeat (4) emit(rv_nop());
  w[nw] = rv_vle8(5'd1, 5'd30);                   emit(w[nw]);  nw++;      // 1
  w[nw] = rv_vle8(5'd2, 5'd30);                   emit(w[nw]);  nw++;      // 2 (back to back)
  w[nw] = rv_vwmul_vv(5'd4, 5'd2, 5'd1);          emit(w[nw]);  nw++;      // 3
  w[nw] = rv_vmv_v_x(5'd3, 5'd0);                 emit(w[nw]);  nw++;      // 4
  w[nw] = rv_vwredsum_vs(5'd8, 5'd4, 5'd3);       emit(w[nw]);  nw++;      // 5
  w[nw] = rv_vsetvli(5'd5, 5'd0, vtype_zimm(32)); emit(w[nw]);  nw++;      // 6: rd = 4
  w[nw] = rv_vmv_x_s(5'd7, 5'd8);                 emit(w[nw]);  nw++;      // 7: rd = sum
  emit(rv_addi(5'd8, 5'd7, 1));                                             // immediate use of the vmv.x.s rd
  emit_sw_res(5'd7, 1);                                                     // sum
  emit_sw_res(5'd8, 2);                                                     // sum + 1
  repeat (4) emit(rv_nop());
  w[nw] = rv_vse32(5'd8, 5'd29);                  emit(w[nw]);  nw++;      // 8: memory write
  emit(rv_lw(5'd9, 5'd29, 0));                                              // scalar load right behind the vector store
  emit_sw_res(5'd9, 3);                                                     // sum
  emit_halt();

  dmem_fill(TB_DATA_BASE, 4, 32'h01FF_7F80);
  dmem_fill(TB_RES_BASE, 8, 32'hC0FF_EE11);
  host_load_prog();
  host_end();

  // run loop: check the stall window cycle by cycle (xfer+1 .. done-1)
  bad_cpu = 0;  bad_apb = 0;  busy_cyc = 0;  k = 0;
  while (o_halt !== 1'b1 && k < 5000) begin
    tick();
    k++;
    if (m_v_busy && p_vresp_done !== 1'b1) begin
      busy_cyc++;
      if (p_cpu_dmem_req === 1'b1) bad_cpu++;
      if (p_apb_psel === 1'b1)     bad_apb++;
    end
  end
  tb_run_hit    = (o_halt === 1'b1);
  tb_run_cycles = tb_cycle - tb_rel_cycle;
  if (tb_run_hit) drain_halted();

  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "unexpected illegal instruction")
  `TC_CHECK(bad_cpu == 0, $sformatf("%0d CPU data requests while a vector command was executing (pipeline not stalled)", bad_cpu))
  `TC_CHECK(bad_apb == 0, $sformatf("%0d APB transfers while a vector command was executing", bad_apb))
  `TC_CHECK(busy_cyc >= 9 * 4, $sformatf("busy window too short (%0d cycles for 9 commands)", busy_cyc))
  `TC_CHECK(tb_vlog_n == 9, $sformatf("expected 9 completed vector commands, monitor saw %0d", tb_vlog_n))
  `TC_CHECK(tb_vcmd_cnt == 9, $sformatf("expected 9 command transfers, saw %0d", tb_vcmd_cnt))
  `TC_CHECK(tb_vmem_xfer_cnt == 3, $sformatf("expected 3 VPU memory accesses (vle8, vle8, vse32), saw %0d", tb_vmem_xfer_cnt))
  for (i = 0; i < 9; i++) begin
    `TC_CHECK(tb_vlog_instr[i] === w[i], $sformatf("command %0d: logged %08h, expected %08h", i, tb_vlog_instr[i], w[i]))
    `TC_CHECK(tb_vlog_lat[i] >= 5, $sformatf("command %0d (%08h): %0d cycles start->o_resp_done, REQ-087 requires >= 5", i, w[i], tb_vlog_lat[i]))
  end
  `TC_CHECK(tb_vlog_rdv[0] === 1'b1 && tb_vlog_rdd[0] === 32'd16, "vsetvli e8: o_resp_rd_valid/o_resp_rd_data must carry vl = 16")
  `TC_CHECK(tb_vlog_rdv[6] === 1'b1 && tb_vlog_rdd[6] === 32'd4,  "vsetvli e32: o_resp_rd_valid/o_resp_rd_data must carry vl = 4")
  `TC_CHECK(tb_vlog_rdv[7] === 1'b1 && tb_vlog_rdd[7] === 32'(sum), "vmv.x.s: o_resp_rd_valid/o_resp_rd_data must carry the element")

  res_rd(0, d); `TC_CHECK(d === 32'd32,        $sformatf("add right behind vsetvli = %0d, expected 32 (write-back in the done cycle)", d))
  res_rd(1, d); `TC_CHECK(d === 32'(sum),      $sformatf("vmv.x.s result stored = %0d, expected %0d", d, sum))
  res_rd(2, d); `TC_CHECK(d === 32'(sum + 1),  $sformatf("addi right behind vmv.x.s = %0d, expected %0d", d, sum + 1))
  res_rd(3, d); `TC_CHECK(d === 32'(sum),      $sformatf("lw right behind vse32 = %0d, expected %0d", d, sum))
  mon_check_all();
endtask
