// TC-054 | REQ-001, REQ-002, REQ-003
// Seeded random scalar programs (ALU reg/imm, mul, lui, aligned lw/lh/lhu/lb/lbu/sw/sh/sb on a 256-byte data window,
// forward branches and jal) with dense register dependencies (only x0..x8 are used, so back-to-back hazards,
// forwarding and load-use are frequent). A TB reference ISS (register file + byte memory) is advanced while the
// program is generated; branch/jal decisions are taken from the model, the skipped instructions are emitted but
// not applied. The final x1..x8 and the whole data window are compared with the model.
// Seed: +SEED=<n> (logged as TC_INFO); a failing seed reproduces the same programs.
task automatic tc_054_random_scalar_regression();
  logic [31:0] rf [0:31];
  logic [7:0]  mem [0:255];
  logic [31:0] a, b, r, simm, rnd, rnd2, d, wv, wbase;
  int          NPROG, NINS, p, n, k, cls, op, rd, rs1, rs2, imm, sh, skip, m, off, pc_b, nerr, ntaken, exec;
  bit          taken;

  NPROG = 3;
  NINS  = 250;
  wbase = TB_DATA_BASE + 32'h200;          // x30 = base of the data window
  nerr  = 0;

  for (p = 0; p < NPROG; p++) begin
    $display("TC_INFO TC-054 seed=%0d program=%0d", tb_seed, p);
    for (n = 0; n < 32; n++) rf[n] = 32'h0;

    // ---- data window: random bytes in DMEM and in the model
    for (k = 0; k < 64; k++) begin
      rnd = tb_rand32();
      mem[4*k]     = rnd[7:0];
      mem[4*k + 1] = rnd[15:8];
      mem[4*k + 2] = rnd[23:16];
      mem[4*k + 3] = rnd[31:24];
      dmem_wr(wbase + 32'(4 * k), rnd);
    end

    // ---- prologue
    prog_reset();
    emit_res_init();
    emit_li(5'd30, wbase);
    for (n = 1; n <= 8; n++) begin
      rf[n] = tb_rand32();
      emit_li(n[4:0], rf[n]);
    end

    skip   = 0;
    ntaken = 0;
    for (n = 0; n < NINS; n++) begin
      rnd  = tb_rand32();
      rnd2 = tb_rand32();
      exec = (skip == 0);
      if (skip > 0) skip--;
      pc_b = prog_here();
      cls  = int'(rnd[3:0]);
      rd   = 1 + int'(rnd[7:4] % 8);
      rs1  = int'(rnd[11:8] % 9);
      rs2  = int'(rnd[15:12] % 9);
      imm  = int'($signed(rnd[27:16]));
      sh   = int'(rnd[20:16]);
      a    = (rs1 == 0) ? 32'h0 : rf[rs1];
      b    = (rs2 == 0) ? 32'h0 : rf[rs2];
      simm = 32'(imm);

      if (cls <= 8) begin                                    // ALU
        op = int'(rnd2 % 19);
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
        if (exec) rf[rd] = r;
      end else if (cls == 9) begin                           // mul (low 32 bits)
        emit(rv_mul(rd[4:0], rs1[4:0], rs2[4:0]));
        r = a * b;
        if (exec) rf[rd] = r;
      end else if (cls == 10) begin                          // lui
        emit(rv_lui(rd[4:0], rnd2[19:0]));
        r = {rnd2[19:0], 12'h0};
        if (exec) rf[rd] = r;
      end else if (cls == 11 || cls == 12) begin             // loads from the window, aligned
        case (int'(rnd2 % 5))
          0: begin off = 4 * int'(rnd2[15:8] % 64);  emit(rv_lw (rd[4:0], 5'd30, off));
                   r = {mem[off+3], mem[off+2], mem[off+1], mem[off]}; end
          1: begin off = 2 * int'(rnd2[15:8] % 128); emit(rv_lh (rd[4:0], 5'd30, off));
                   r = 32'(sx({16'h0, mem[off+1], mem[off]}, 16)); end
          2: begin off = 2 * int'(rnd2[15:8] % 128); emit(rv_lhu(rd[4:0], 5'd30, off));
                   r = {16'h0, mem[off+1], mem[off]}; end
          3: begin off = int'(rnd2[15:8]);           emit(rv_lb (rd[4:0], 5'd30, off));
                   r = 32'(sx({24'h0, mem[off]}, 8)); end
          default: begin off = int'(rnd2[15:8]);     emit(rv_lbu(rd[4:0], 5'd30, off));
                   r = {24'h0, mem[off]}; end
        endcase
        if (exec) rf[rd] = r;
      end else if (cls == 13) begin                          // stores to the window, aligned
        case (int'(rnd2 % 3))
          0: begin off = 4 * int'(rnd2[15:8] % 64);  emit(rv_sw(rs2[4:0], 5'd30, off));
                   if (exec) begin mem[off] = b[7:0]; mem[off+1] = b[15:8]; mem[off+2] = b[23:16]; mem[off+3] = b[31:24]; end end
          1: begin off = 2 * int'(rnd2[15:8] % 128); emit(rv_sh(rs2[4:0], 5'd30, off));
                   if (exec) begin mem[off] = b[7:0]; mem[off+1] = b[15:8]; end end
          default: begin off = int'(rnd2[15:8]);     emit(rv_sb(rs2[4:0], 5'd30, off));
                   if (exec) mem[off] = b[7:0]; end
        endcase
      end else if (cls == 14) begin                          // forward conditional branch over m instructions
        m = 1 + int'(rnd2[11:8] % 3);
        case (int'(rnd2 % 6))
          0: begin emit(rv_beq (rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = (a == b); end
          1: begin emit(rv_bne (rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = (a != b); end
          2: begin emit(rv_blt (rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = ($signed(a) < $signed(b)); end
          3: begin emit(rv_bge (rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = ($signed(a) >= $signed(b)); end
          4: begin emit(rv_bltu(rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = (a < b); end
          default: begin emit(rv_bgeu(rs1[4:0], rs2[4:0], (m + 1) * 4)); taken = (a >= b); end
        endcase
        if (exec && taken) begin skip = m; ntaken++; end
      end else begin                                         // jal (rd may be x0), forward over m instructions
        m  = 1 + int'(rnd2[11:8] % 3);
        rd = int'(rnd2[19:16] % 9);
        emit(rv_jal(rd[4:0], (m + 1) * 4));
        if (exec) begin
          if (rd != 0) rf[rd] = 32'(pc_b + 4);
          skip = m;
          ntaken++;
        end
      end
    end
    while (skip > 0) begin                                   // pad a skip region that runs to the end
      emit(rv_nop());
      skip--;
    end
    for (n = 1; n <= 8; n++) emit_sw_res(n[4:0], n - 1);
    emit_halt();

    run_prog(60000);                                         // includes the post-halt drain
    `TC_CHECK(tb_run_hit && o_halt === 1'b1,
              $sformatf("program %0d (seed %0d) did not reach ebreak", p, tb_seed))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("program %0d (seed %0d): illegal instruction", p, tb_seed))
    for (n = 1; n <= 8; n++) begin
      res_rd(n - 1, d);
      if (d !== rf[n]) begin
        nerr++;
        if (nerr <= 20)
          `TC_CHECK(d === rf[n], $sformatf("seed %0d program %0d: x%0d = %08h, model %08h", tb_seed, p, n, d, rf[n]))
      end
    end
    for (k = 0; k < 64; k++) begin
      dmem_rd(wbase + 32'(4 * k), d);
      wv = {mem[4*k+3], mem[4*k+2], mem[4*k+1], mem[4*k]};
      if (d !== wv) begin
        nerr++;
        if (nerr <= 20)
          `TC_CHECK(d === wv, $sformatf("seed %0d program %0d: window word %0d = %08h, model %08h", tb_seed, p, k, d, wv))
      end
    end
    $display("TC_INFO TC-054 program %0d: %0d taken branches/jumps, %0d cycles to halt", p, ntaken, tb_run_cycles);
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d mismatches against the reference ISS (seed %0d)", nerr, tb_seed))
  mon_check_all();
endtask
