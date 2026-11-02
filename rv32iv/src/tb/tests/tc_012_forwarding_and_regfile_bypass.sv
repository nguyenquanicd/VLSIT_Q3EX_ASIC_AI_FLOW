// TC-012 | REQ-003, REQ-001, REQ-035, REQ-076
// Data hazards, all with explicit expected values:
//   EX/MEM->EX forwarding (distance 1), MEM/WB->EX forwarding (distance 2), both operands from different stages,
//   same-cycle WB->read bypass of the register file (distance 3) at read port 1 and read port 2,
//   long dependent chains, load-use (rs1 and rs2) , store-data forwarding (ALU result and load result into sw),
//   forwarding into a branch comparison, and x0 reading 0 (write to x0 ignored, load/jal with rd = x0).
task automatic tc_012_forwarding_and_regfile_bypass();
  logic [31:0] exp_v [0:63];
  logic [31:0] d;
  int          n, k, nerr;
  logic [31:0] s;

  n    = 0;
  nerr = 0;
  prog_reset();
  emit_res_init();
  emit_li(5'd30, TB_DATA_BASE);
  // ---- distance-1 forwarding (EX/MEM -> EX), both operand ports
  emit(rv_addi(5'd1, 5'd0, 5));
  emit(rv_add (5'd2, 5'd1, 5'd1));                         // 10
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd10;  n++;
  emit(rv_addi(5'd3, 5'd0, 7));
  emit(rv_sub (5'd4, 5'd0, 5'd3));                         // rs2 from EX/MEM: -7
  emit_sw_res(5'd4, n);  exp_v[n] = 32'hFFFF_FFF9;  n++;
  // ---- distance-2 forwarding (MEM/WB -> EX)
  emit(rv_addi(5'd1, 5'd0, 9));
  emit(rv_nop());
  emit(rv_add (5'd2, 5'd1, 5'd1));                         // 18
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd18;  n++;
  emit(rv_addi(5'd3, 5'd0, 4));
  emit(rv_nop());
  emit(rv_sub (5'd4, 5'd0, 5'd3));                         // rs2 from MEM/WB: -4
  emit_sw_res(5'd4, n);  exp_v[n] = 32'hFFFF_FFFC;  n++;
  // ---- operands from two different stages
  emit(rv_addi(5'd1, 5'd0, 3));
  emit(rv_addi(5'd2, 5'd0, 4));
  emit(rv_add (5'd3, 5'd1, 5'd2));                         // x1 from MEM/WB, x2 from EX/MEM: 7
  emit_sw_res(5'd3, n);  exp_v[n] = 32'd7;  n++;
  emit(rv_addi(5'd1, 5'd0, 20));
  emit(rv_addi(5'd2, 5'd0, 30));
  emit(rv_sub (5'd3, 5'd2, 5'd1));                         // 30 - 20 = 10 (swapped ports)
  emit_sw_res(5'd3, n);  exp_v[n] = 32'd10;  n++;
  // ---- same-cycle write-back -> read bypass (distance 3), port 1 and port 2
  emit(rv_addi(5'd1, 5'd0, 11));
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_add (5'd2, 5'd1, 5'd0));                         // reads x1 at port 1 in the WB cycle
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd11;  n++;
  emit(rv_addi(5'd1, 5'd0, 13));
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_add (5'd2, 5'd0, 5'd1));                         // reads x1 at port 2 in the WB cycle
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd13;  n++;
  emit(rv_addi(5'd1, 5'd0, 17));
  emit(rv_nop());
  emit(rv_nop());
  emit(rv_add (5'd2, 5'd1, 5'd1));                         // both ports
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd34;  n++;
  // ---- long dependent chain: x1 doubled 8 times from 1
  emit(rv_addi(5'd1, 5'd0, 1));
  for (k = 0; k < 8; k++) emit(rv_add(5'd1, 5'd1, 5'd1));
  emit_sw_res(5'd1, n);  exp_v[n] = 32'd256;  n++;
  // alternating chain with mixed ports: x1 = x1 + x2, x2 = x1 + x2 (Fibonacci style)
  emit(rv_addi(5'd1, 5'd0, 1));
  emit(rv_addi(5'd2, 5'd0, 1));
  s = 0;
  for (k = 0; k < 6; k++) begin
    emit(rv_add(5'd1, 5'd1, 5'd2));
    emit(rv_add(5'd2, 5'd1, 5'd2));
  end
  emit_sw_res(5'd1, n);  exp_v[n] = 32'd233;  n++;         // F: (1,1) -> x1 after 6 rounds
  emit_sw_res(5'd2, n);  exp_v[n] = 32'd377;  n++;
  // ---- load-use on rs1 and on rs2 (one bubble)
  emit_li(5'd6, 32'h0000_0123);
  emit(rv_sw(5'd6, 5'd30, 0));
  emit(rv_lw (5'd2, 5'd30, 0));
  emit(rv_addi(5'd3, 5'd2, 1));                            // load-use rs1
  emit_sw_res(5'd3, n);  exp_v[n] = 32'h0000_0124;  n++;
  emit(rv_lw (5'd2, 5'd30, 0));
  emit(rv_sub(5'd3, 5'd0, 5'd2));                          // load-use rs2: -0x123
  emit_sw_res(5'd3, n);  exp_v[n] = 32'hFFFF_FEDD;  n++;
  // ---- store-data forwarding: ALU result and load result straight into sw
  emit(rv_addi(5'd3, 5'd0, 85));
  emit(rv_sw(5'd3, 5'd30, 4));                             // x3 just produced
  emit(rv_lw(5'd4, 5'd30, 4));
  emit_sw_res(5'd4, n);  exp_v[n] = 32'd85;  n++;
  emit(rv_lw(5'd5, 5'd30, 0));
  emit(rv_sw(5'd5, 5'd30, 8));                             // load result straight into the store data
  emit(rv_lw(5'd7, 5'd30, 8));
  emit_sw_res(5'd7, n);  exp_v[n] = 32'h0000_0123;  n++;
  // ---- forwarding into a branch comparison
  emit(rv_addi(5'd8, 5'd0, 4));
  emit(rv_addi(5'd9, 5'd0, 0));
  emit(rv_bne (5'd8, 5'd0, 8));                            // x8 forwarded: taken, shadow flushed
  emit(rv_addi(5'd9, 5'd9, 1));
  emit_sw_res(5'd9, n);  exp_v[n] = 32'd0;  n++;
  // ---- x0: writes ignored, always reads 0
  emit(rv_addi(5'd0, 5'd0, 5));
  emit(rv_add (5'd5, 5'd0, 5'd0));
  emit_sw_res(5'd5, n);  exp_v[n] = 32'd0;  n++;
  emit(rv_addi(5'd1, 5'd0, 9));
  emit(rv_addi(5'd0, 5'd1, 7));                            // x0 <- 16 ignored
  emit(rv_add (5'd5, 5'd0, 5'd1));                         // 0 + 9
  emit_sw_res(5'd5, n);  exp_v[n] = 32'd9;  n++;
  emit(rv_lw  (5'd0, 5'd30, 0));                           // load with rd = x0
  emit(rv_add (5'd5, 5'd0, 5'd0));
  emit_sw_res(5'd5, n);  exp_v[n] = 32'd0;  n++;
  emit(rv_jal (5'd0, 4));                                  // jal with rd = x0 (target = next instruction)
  emit(rv_add (5'd5, 5'd0, 5'd1));
  emit_sw_res(5'd5, n);  exp_v[n] = 32'd9;  n++;
  emit_sw_res(5'd0, n);  exp_v[n] = 32'd0;  n++;
  emit_halt();

  dmem_fill(TB_RES_BASE, 64, 32'hDEAD_BEEF);
  run_prog(30000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "forwarding program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "illegal instruction in the forwarding program")
  for (k = 0; k < n; k++) begin
    res_rd(k, d);
    if (d !== exp_v[k]) begin
      nerr++;
      if (nerr <= 20)
        `TC_CHECK(d === exp_v[k], $sformatf("hazard case %0d: got %08h expected %08h", k, d, exp_v[k]))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d forwarding / bypass results differ", nerr))
  mon_check_all();
endtask
