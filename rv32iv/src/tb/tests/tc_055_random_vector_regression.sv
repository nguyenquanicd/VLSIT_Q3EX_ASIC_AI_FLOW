// TC-055 | REQ-004, REQ-005, REQ-006, REQ-007, REQ-008, REQ-009, REQ-059, REQ-074
// Seeded random legal vector programs mixed with scalar code, compared with a TB reference model through DMEM dump.
// Per program: all 32 vector registers are first loaded with random data (so the model is fully defined), then 120
// random operations:
//   vsetvli / vsetivli (SEW 8/16/32, AVL 1..40: returned vl checked), scalar addi/lw/sw/mul (sw/lw hit the same
//   memory window the vector loads/stores use), vle8/vle32, vse8/vse32 (random row, vl elements, tail untouched),
//   vwmul.vv (SEW=8), vwredsum.vs (SEW=8), vadd.vv/vx, vsra.vi/vx, vmax.vx, vmv.v.x, vmv.s.x, vmv.x.s (SEW 8/32),
//   vnclip.wi/wx (dest SEW 16 or 8).
// Only legal SEW combinations are generated (REQ-074); widening destinations are even registers and never overlap
// their sources; vl is always >= 1. At the end vl=16/SEW=8 and every vector register is stored (32 x 16 bytes),
// then registers, the 512-byte memory window and all recorded scalar results are compared with the model.
// RVV 1.0 semantics: tail-undisturbed, vsra shift masked to log2(SEW), vmv.x.s sign-extends, vxrm=0 rounding.
// Seed: +SEED=<n> (logged as TC_INFO).
task automatic tc_055_random_vector_regression();
  logic [7:0]  vr  [0:31][0:15];
  logic [7:0]  mem [0:511];
  logic [7:0]  ini [0:511];
  logic [31:0] exp_slot [0:511];
  logic [31:0] rnd, rnd2, xs, ev, ev2, res_b, d, wv, acc, WB, INI, DMP;
  logic [10:0] zz;
  longint      la, lb, lres, sum;
  int          NPROG, NOPS, p, n, k, i, j, e, r, w, pick, op, sew, vl, nsew, avl, nvl, lmx, eb, wb, bi, oo, rr;
  int          nb, ar, vd, vs1, vs2, nslot, nerr, shamt, dst, imm, sub, wsel;

  NPROG = 3;
  NOPS  = 120;
  WB    = 32'h1000_5000;                  // memory window (32 rows of 16 bytes)
  INI   = 32'h1000_5800;                  // initial register contents (32 rows)
  DMP   = 32'h1000_5C00;                  // final register dump (32 rows)
  nerr  = 0;

  for (p = 0; p < NPROG; p++) begin
    $display("TC_INFO TC-055 seed=%0d program=%0d", tb_seed, p);

    // ---- random memory window / initial register images (host written, mirrored in the model)
    for (w = 0; w < 128; w++) begin
      rnd = tb_rand32();
      mem[4*w] = rnd[7:0];  mem[4*w+1] = rnd[15:8];  mem[4*w+2] = rnd[23:16];  mem[4*w+3] = rnd[31:24];
      dmem_wr(WB + 32'(4 * w), rnd);
      rnd = tb_rand32();
      ini[4*w] = rnd[7:0];  ini[4*w+1] = rnd[15:8];  ini[4*w+2] = rnd[23:16];  ini[4*w+3] = rnd[31:24];
      dmem_wr(INI + 32'(4 * w), rnd);
      dmem_wr(DMP + 32'(4 * w), 32'hEEEE_EEEE);
    end

    // ---- prologue: SEW=8, vl=16, load all 32 registers
    prog_reset();
    emit_res_init();
    emit(rv_addi(5'd20, 5'd0, 0));
    acc   = 32'h0;
    nslot = 0;
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    sew = 8;
    vl  = 16;
    for (r = 0; r < 32; r++) begin
      emit_li(5'd12, INI + 32'(16 * r));
      emit(rv_vle8(r[4:0], 5'd12));
      for (i = 0; i < 16; i++) vr[r][i] = ini[16 * r + i];
    end

    // ---- random operations
    for (n = 0; n < NOPS; n++) begin
      rnd  = tb_rand32();
      rnd2 = tb_rand32();
      pick = int'(rnd[7:4]);
      case (pick)
        0, 1, 2: op = 0;                       // vsetvli / vsetivli
        3:       op = 1;                       // scalar
        4:       op = 2;                       // vle
        5:       op = 3;                       // vse
        6:       op = 4;                       // vwmul
        7:       op = 5;                       // vwredsum
        8:       op = 6;                       // vadd.vv
        9:       op = 7;                       // vadd.vx
        10:      op = 8;                       // vsra.vi
        11:      op = 9;                       // vsra.vx
        12:      op = 10;                      // vmax.vx
        13:      op = 11;                      // vmv.v.x
        14:      op = rnd[8] ? 12 : 13;        // vmv.s.x / vmv.x.s
        default: op = rnd[8] ? 14 : 15;        // vnclip.wi / vnclip.wx
      endcase
      // legalize for the current SEW (REQ-074)
      if (sew == 16) begin
        if (!(op == 0 || op == 1 || op == 14 || op == 15)) op = rnd[8] ? 14 : 15;
      end else if (sew == 32) begin
        if (op == 4)                    op = 6;
        else if (op == 5)               op = 10;
        else if (op == 14 || op == 15)  op = 11;
      end
      eb = sew / 8;

      case (op)
        0: begin  // ---------------- vsetvli / vsetivli
          nsew = (int'(rnd2 % 3) == 0) ? 8 : ((int'(rnd2 % 3) == 1) ? 16 : 32);
          avl  = 1 + int'(rnd2[15:8] % 40);
          lmx  = 16 / (nsew / 8);
          nvl  = (avl < lmx) ? avl : lmx;
          zz   = vtype_zimm(nsew);
          if (avl <= 31 && rnd2[20]) begin
            emit(rv_vsetivli(5'd11, avl[4:0], zz[9:0]));
          end else begin
            emit_li(5'd10, 32'(avl));
            emit(rv_vsetvli(5'd11, 5'd10, zz));
          end
          emit_sw_res(5'd11, nslot);
          exp_slot[nslot] = 32'(nvl);
          nslot++;
          sew = nsew;
          vl  = nvl;
        end

        1: begin  // ---------------- scalar code touching the shared memory window
          sub  = int'(rnd2[19:18]);
          wsel = int'(rnd2[10:4]);
          if (sub == 0) begin
            imm = int'($signed(rnd2[11:0]));
            emit(rv_addi(5'd20, 5'd20, imm));
            acc = acc + 32'(imm);
          end else if (sub == 1) begin
            emit_li(5'd12, WB + 32'(4 * wsel));
            emit(rv_lw(5'd21, 5'd12, 0));
            emit_sw_res(5'd21, nslot);
            exp_slot[nslot] = {mem[4*wsel+3], mem[4*wsel+2], mem[4*wsel+1], mem[4*wsel]};
            nslot++;
          end else if (sub == 2) begin
            emit_li(5'd12, WB + 32'(4 * wsel));
            emit(rv_sw(5'd20, 5'd12, 0));
            mem[4*wsel] = acc[7:0];  mem[4*wsel+1] = acc[15:8];  mem[4*wsel+2] = acc[23:16];  mem[4*wsel+3] = acc[31:24];
          end else begin
            emit(rv_mul(5'd22, 5'd20, 5'd20));
            emit_sw_res(5'd22, nslot);
            exp_slot[nslot] = acc * acc;
            nslot++;
          end
        end

        2: begin  // ---------------- vle8 (SEW 8) / vle32 (SEW 32)
          ar = int'(rnd2[4:0]);
          vd = int'(rnd2[9:5]);
          nb = (sew == 8) ? vl : 4 * vl;
          emit_li(5'd12, WB + 32'(16 * ar));
          if (sew == 8) emit(rv_vle8 (vd[4:0], 5'd12));
          else          emit(rv_vle32(vd[4:0], 5'd12));
          for (i = 0; i < nb; i++) vr[vd][i] = mem[16 * ar + i];
        end

        3: begin  // ---------------- vse8 / vse32
          ar = int'(rnd2[4:0]);
          vd = int'(rnd2[9:5]);
          nb = (sew == 8) ? vl : 4 * vl;
          emit_li(5'd12, WB + 32'(16 * ar));
          if (sew == 8) emit(rv_vse8 (vd[4:0], 5'd12));
          else          emit(rv_vse32(vd[4:0], 5'd12));
          for (i = 0; i < nb; i++) mem[16 * ar + i] = vr[vd][i];
        end

        4: begin  // ---------------- vwmul.vv (SEW=8): INT16 results in the pair vd / vd+1
          vd  = 2 * int'(rnd2[3:0]);
          vs2 = int'(tb_rand32() % 32);
          while (vs2 == vd || vs2 == vd + 1) vs2 = int'(tb_rand32() % 32);
          vs1 = int'(tb_rand32() % 32);
          while (vs1 == vd || vs1 == vd + 1) vs1 = int'(tb_rand32() % 32);
          emit(rv_vwmul_vv(vd[4:0], vs2[4:0], vs1[4:0]));
          for (e = 0; e < vl; e++) begin
            la   = sx({24'h0, vr[vs2][e]}, 8);
            lb   = sx({24'h0, vr[vs1][e]}, 8);
            lres = la * lb;
            res_b = lres[31:0];
            bi = 2 * e;
            rr = vd + bi / 16;
            oo = bi % 16;
            vr[rr][oo]     = res_b[7:0];
            vr[rr][oo + 1] = res_b[15:8];
          end
        end

        5: begin  // ---------------- vwredsum.vs (SEW=8): vd[0] (32 bit) = vs1[0] + sum of int16 elements of vs2/vs2+1
          vs2 = 2 * int'(rnd2[3:0]);
          vd  = int'(tb_rand32() % 32);
          while (vd == vs2 || vd == vs2 + 1) vd = int'(tb_rand32() % 32);
          vs1 = rnd2[4] ? vd : int'(tb_rand32() % 32);
          emit(rv_vwredsum_vs(vd[4:0], vs2[4:0], vs1[4:0]));
          sum = 0;
          for (e = 0; e < vl; e++) begin
            bi  = 2 * e;
            rr  = vs2 + bi / 16;
            oo  = bi % 16;
            ev  = {16'h0, vr[rr][oo + 1], vr[rr][oo]};
            sum = sum + sx(ev, 16);
          end
          xs    = {vr[vs1][3], vr[vs1][2], vr[vs1][1], vr[vs1][0]};
          res_b = xs + sum[31:0];
          vr[vd][0] = res_b[7:0];  vr[vd][1] = res_b[15:8];  vr[vd][2] = res_b[23:16];  vr[vd][3] = res_b[31:24];
        end

        6, 7, 8, 9, 10, 11, 12, 13: begin  // ---------------- element-wise ops at SEW 8 / 32
          vd  = int'(rnd2[4:0]);
          vs2 = int'(rnd2[9:5]);
          vs1 = int'(rnd2[14:10]);
          xs  = tb_rand32();
          imm = int'(rnd2[19:15]);
          if (op == 6)       emit(rv_vadd_vv(vd[4:0], vs2[4:0], vs1[4:0]));
          else if (op == 7)  begin emit_li(5'd13, xs); emit(rv_vadd_vx(vd[4:0], vs2[4:0], 5'd13)); end
          else if (op == 8)  emit(rv_vsra_vi(vd[4:0], vs2[4:0], imm[4:0]));
          else if (op == 9)  begin emit_li(5'd13, xs); emit(rv_vsra_vx(vd[4:0], vs2[4:0], 5'd13)); end
          else if (op == 10) begin emit_li(5'd13, xs); emit(rv_vmax_vx(vd[4:0], vs2[4:0], 5'd13)); end
          else if (op == 11) begin emit_li(5'd13, xs); emit(rv_vmv_v_x(vd[4:0], 5'd13)); end
          else if (op == 12) begin emit_li(5'd13, xs); emit(rv_vmv_s_x(vd[4:0], 5'd13)); end
          else               begin emit(rv_vmv_x_s(5'd14, vs2[4:0])); end

          if (op == 13) begin                          // vmv.x.s: element 0 sign-extended to the scalar rd
            ev = 32'h0;
            for (j = 0; j < eb; j++) ev[8*j +: 8] = vr[vs2][j];
            la = sx(ev, sew);
            emit_sw_res(5'd14, nslot);
            exp_slot[nslot] = la[31:0];
            nslot++;
          end else begin
            for (e = 0; e < ((op == 12) ? 1 : vl); e++) begin
              ev  = 32'h0;
              ev2 = 32'h0;
              for (j = 0; j < eb; j++) begin
                ev [8*j +: 8] = vr[vs2][e * eb + j];
                ev2[8*j +: 8] = vr[vs1][e * eb + j];
              end
              case (op)
                6:  res_b = ev + ev2;
                7:  res_b = ev + xs;
                8:  begin shamt = imm & (sew - 1);            la = sx(ev, sew); lres = la >>> shamt; res_b = lres[31:0]; end
                9:  begin shamt = int'(xs & 32'(sew - 1));    la = sx(ev, sew); lres = la >>> shamt; res_b = lres[31:0]; end
                10: begin la = sx(ev, sew); lb = sx(xs, sew); lres = (la > lb) ? la : lb; res_b = lres[31:0]; end
                default: res_b = xs;                           // vmv.v.x / vmv.s.x
              endcase
              for (j = 0; j < eb; j++) vr[vd][e * eb + j] = res_b[8*j +: 8];
            end
          end
        end

        default: begin  // ---------------- vnclip.wi / vnclip.wx : source pair vs2/vs2+1, narrow destination vd
          dst = sew;                                 // 16 (32->16) or 8 (16->8)
          wb  = 2 * eb;
          vs2 = 2 * int'(rnd2[3:0]);
          vd  = int'(tb_rand32() % 32);
          while (vd == vs2 || vd == vs2 + 1) vd = int'(tb_rand32() % 32);
          if (op == 14) begin
            imm = int'(rnd2[8:4]);
            emit(rv_vnclip_wi(vd[4:0], vs2[4:0], imm[4:0]));
            xs = 32'(imm);
          end else begin
            xs = tb_rand32();
            emit_li(5'd13, xs);
            emit(rv_vnclip_wx(vd[4:0], vs2[4:0], 5'd13));
          end
          shamt = int'(xs & ((dst == 16) ? 32'd31 : 32'd15));
          for (e = 0; e < vl; e++) begin
            bi = e * wb;
            rr = vs2 + bi / 16;
            oo = bi % 16;
            ev = 32'h0;
            for (j = 0; j < wb; j++) ev[8*j +: 8] = vr[rr][oo + j];
            la    = sx(ev, 8 * wb);
            lres  = ref_vnclip(la, shamt, dst);
            res_b = lres[31:0];
            for (j = 0; j < eb; j++) vr[vd][e * eb + j] = res_b[8*j +: 8];
          end
        end
      endcase
    end

    // ---- epilogue: vl=16/SEW=8, dump all vector registers, scalar accumulator, halt
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    for (r = 0; r < 32; r++) begin
      emit_li(5'd12, DMP + 32'(16 * r));
      emit(rv_vse8(r[4:0], 5'd12));
    end
    emit_sw_res(5'd20, nslot);
    exp_slot[nslot] = acc;
    nslot++;
    emit_halt();

    run_prog(300000);                                       // includes the post-halt drain
    `TC_CHECK(tb_run_hit && o_halt === 1'b1, $sformatf("program %0d (seed %0d) did not reach ebreak", p, tb_seed))
    `TC_CHECK(o_err_illegal === 1'b0, $sformatf("program %0d (seed %0d): legal vector program raised an illegal instruction", p, tb_seed))

    for (k = 0; k < nslot; k++) begin
      res_rd(k, d);
      if (d !== exp_slot[k]) begin
        nerr++;
        if (nerr <= 20)
          `TC_CHECK(d === exp_slot[k], $sformatf("seed %0d program %0d: scalar result slot %0d = %08h, model %08h",
                                                 tb_seed, p, k, d, exp_slot[k]))
      end
    end
    for (r = 0; r < 32; r++) begin
      for (w = 0; w < 4; w++) begin
        dmem_rd(DMP + 32'(16 * r + 4 * w), d);
        wv = {vr[r][4*w+3], vr[r][4*w+2], vr[r][4*w+1], vr[r][4*w]};
        if (d !== wv) begin
          nerr++;
          if (nerr <= 20)
            `TC_CHECK(d === wv, $sformatf("seed %0d program %0d: v%0d word %0d = %08h, model %08h", tb_seed, p, r, w, d, wv))
        end
      end
    end
    for (w = 0; w < 128; w++) begin
      dmem_rd(WB + 32'(4 * w), d);
      wv = {mem[4*w+3], mem[4*w+2], mem[4*w+1], mem[4*w]};
      if (d !== wv) begin
        nerr++;
        if (nerr <= 20)
          `TC_CHECK(d === wv, $sformatf("seed %0d program %0d: memory window word %0d = %08h, model %08h", tb_seed, p, w, d, wv))
      end
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d mismatches against the vector reference model (seed %0d)", nerr, tb_seed))
  mon_check_all();
endtask
