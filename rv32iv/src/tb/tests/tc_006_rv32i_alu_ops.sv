// TC-006 | REQ-001
// RV32I ALU: phase 0 = directed corner operands through every register/immediate ALU op plus lui/auipc,
// phase 1 = seeded random dependent chains. Results are compared with a TB reference.
task automatic tc_006_rv32i_alu_ops();
  int          NOPS;
  int          NPAIR;
  logic [31:0] exp_v [0:511];
  int          exp_op [0:511];
  logic [31:0] rf [0:31];
  logic [31:0] cv [0:11];
  int          icv [0:4];
  logic [31:0] a, b, r, simm, rnd, d;
  int          phase, n, nsteps, op, rd, rs1, rs2, imm, sh, nslot, p, s, nerr;

  NOPS  = 19;
  NPAIR = 24;
  cv[0]  = 32'h0000_0000;  cv[1]  = 32'h0000_0001;  cv[2]  = 32'hFFFF_FFFF;  cv[3]  = 32'h7FFF_FFFF;
  cv[4]  = 32'h8000_0000;  cv[5]  = 32'h0000_FFFF;  cv[6]  = 32'hFFFF_0000;  cv[7]  = 32'h1234_5678;
  cv[8]  = 32'hDEAD_BEEF;  cv[9]  = 32'h8000_0001;  cv[10] = 32'h0000_001F;  cv[11] = 32'h0000_0020;
  icv[0] = 0;  icv[1] = 1;  icv[2] = -1;  icv[3] = 2047;  icv[4] = -2048;
  for (n = 0; n < 32; n++) rf[n] = 32'h0;

  for (phase = 0; phase < 2; phase++) begin
    prog_reset();
    emit_res_init();
    nslot = 0;
    if (phase == 0) nsteps = NPAIR * NOPS;
    else begin
      nsteps = 150;
      for (n = 1; n <= 8; n++) begin                   // random initial register values
        rf[n] = tb_rand32();
        emit_li(n[4:0], rf[n]);
      end
    end

    for (n = 0; n < nsteps; n++) begin
      rnd = tb_rand32();
      if (phase == 0) begin
        p  = n / NOPS;
        op = n % NOPS;
        if (op == 0) begin                             // new operand pair in x1 / x2
          if (p < 12) begin a = cv[p % 12]; b = cv[(p * 5 + 3) % 12]; end
          else        begin a = tb_rand32(); b = tb_rand32(); end
          emit_li(5'd1, a);
          emit_li(5'd2, b);
          rf[1] = a;
          rf[2] = b;
        end
        rd = 3; rs1 = 1; rs2 = 2;
        if ((n % 3) == 0) imm = icv[(n / 3) % 5];
        else              imm = int'($signed(rnd[11:0]));
        sh = ((n % 4) == 0) ? ((n % 8) == 0 ? 0 : 31) : int'(rnd[16:12]);
      end else begin
        op  = int'(rnd[7:0] % NOPS);
        rd  = 1 + int'(rnd[11:8] % 8);
        rs1 = int'(rnd[15:12] % 9);                    // x0..x8 (x0 included)
        rs2 = int'(rnd[19:16] % 9);
        imm = int'($signed(rnd[31:20]));
        sh  = int'(rnd[24:20]);
      end
      a    = (rs1 == 0) ? 32'h0 : rf[rs1];
      b    = (rs2 == 0) ? 32'h0 : rf[rs2];
      simm = 32'(imm);
      case (op)
        0:  begin emit(rv_add (rd[4:0], rs1[4:0], rs2[4:0])); r = a + b; end
        1:  begin emit(rv_sub (rd[4:0], rs1[4:0], rs2[4:0])); r = a - b; end
        2:  begin emit(rv_sll (rd[4:0], rs1[4:0], rs2[4:0])); r = a << b[4:0]; end
        3:  begin emit(rv_slt (rd[4:0], rs1[4:0], rs2[4:0])); r = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; end
        4:  begin emit(rv_sltu(rd[4:0], rs1[4:0], rs2[4:0])); r = (a < b) ? 32'd1 : 32'd0; end
        5:  begin emit(rv_xor (rd[4:0], rs1[4:0], rs2[4:0])); r = a ^ b; end
        6:  begin emit(rv_srl (rd[4:0], rs1[4:0], rs2[4:0])); r = a >> b[4:0]; end
        7:  begin emit(rv_sra (rd[4:0], rs1[4:0], rs2[4:0])); r = $signed(a) >>> b[4:0]; end
        8:  begin emit(rv_or  (rd[4:0], rs1[4:0], rs2[4:0])); r = a | b; end
        9:  begin emit(rv_and (rd[4:0], rs1[4:0], rs2[4:0])); r = a & b; end
        10: begin emit(rv_addi (rd[4:0], rs1[4:0], imm)); r = a + simm; end
        11: begin emit(rv_slti (rd[4:0], rs1[4:0], imm)); r = ($signed(a) < $signed(simm)) ? 32'd1 : 32'd0; end
        12: begin emit(rv_sltiu(rd[4:0], rs1[4:0], imm)); r = (a < simm) ? 32'd1 : 32'd0; end
        13: begin emit(rv_xori (rd[4:0], rs1[4:0], imm)); r = a ^ simm; end
        14: begin emit(rv_ori  (rd[4:0], rs1[4:0], imm)); r = a | simm; end
        15: begin emit(rv_andi (rd[4:0], rs1[4:0], imm)); r = a & simm; end
        16: begin emit(rv_slli (rd[4:0], rs1[4:0], sh));  r = a << sh[4:0]; end
        17: begin emit(rv_srli (rd[4:0], rs1[4:0], sh));  r = a >> sh[4:0]; end
        default: begin emit(rv_srai(rd[4:0], rs1[4:0], sh)); r = $signed(a) >>> sh[4:0]; end
      endcase
      rf[rd] = r;
      if (phase == 0) begin                            // store every result
        emit_sw_res(5'd3, nslot);
        exp_v[nslot]  = r;
        exp_op[nslot] = op;
        nslot++;
      end
    end

    if (phase == 0) begin
      // lui / auipc (auipc result depends on the instruction address)
      emit(rv_lui(5'd3, 20'hABCDE));  emit_sw_res(5'd3, nslot);  exp_v[nslot] = 32'hABCD_E000; exp_op[nslot] = 100; nslot++;
      emit(rv_lui(5'd3, 20'hFFFFF));  emit_sw_res(5'd3, nslot);  exp_v[nslot] = 32'hFFFF_F000; exp_op[nslot] = 101; nslot++;
      exp_v[nslot] = 32'(prog_here()) + 32'h0001_0000; exp_op[nslot] = 102;
      emit(rv_auipc(5'd3, 20'h00010)); emit_sw_res(5'd3, nslot); nslot++;
      exp_v[nslot] = 32'(prog_here()) + 32'hFFFF_F000; exp_op[nslot] = 103;
      emit(rv_auipc(5'd3, 20'hFFFFF)); emit_sw_res(5'd3, nslot); nslot++;
    end else begin
      for (n = 1; n <= 8; n++) begin
        emit_sw_res(n[4:0], n - 1);
        exp_v[n - 1]  = rf[n];
        exp_op[n - 1] = 200;
      end
      nslot = 8;
    end
    emit_halt();

    run_prog(60000);                                   // includes the post-halt drain (final store lands)
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, "ALU program did not reach ebreak")
    `TC_CHECK(o_err_illegal === 1'b0,        "ALU program raised an illegal instruction")
    nerr = 0;
    for (s = 0; s < nslot; s++) begin
      res_rd(s, d);
      if (d !== exp_v[s]) begin
        nerr++;
        if (nerr <= 20)
          `TC_CHECK(d === exp_v[s], $sformatf("phase %0d slot %0d op %0d: expected %08h got %08h",
                                              phase, s, exp_op[s], exp_v[s], d))
      end
    end
    `TC_CHECK(nerr == 0, $sformatf("phase %0d: %0d ALU results mismatch", phase, nerr))
  end
  mon_check_all();
endtask
