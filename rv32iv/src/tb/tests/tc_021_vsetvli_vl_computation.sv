// TC-021 | REQ-004, REQ-051
// vsetvli / vsetivli return vl = min(AVL, VLMAX) with VLMAX = 16 / 8 / 4 for SEW 8 / 16 / 32 (PARA_VLEN = 128):
//   vsetvli  rd, rs1, e<sew> with AVL 0, 1, VLMAX-1, VLMAX, VLMAX+1, 1030   (3 SEW x 6 = 18 results)
//   vsetivli rd, uimm, e<sew> with AVL 0, 1, VLMAX-1, VLMAX, VLMAX+1, 31    (18 results)
//   vsetvli rd, x0, e<sew>   (rs1 = x0, rd != x0 -> vl = VLMAX)            (3 results)
//   strip-mining loop at SEW 8, AVL = 1030: 64 x 16 followed by 6 (the vl width covers 16)
task automatic tc_021_vsetvli_vl_computation();
  int          sews [0:2];
  int          avls [0:5];
  int          slot, s, k, vlmax, avl, ev, i, nerr;
  logic [10:0] zz;
  logic [31:0] exp_s [0:63];
  logic [31:0] d;

  sews[0] = 8;  sews[1] = 16;  sews[2] = 32;
  slot = 0;
  nerr = 0;
  prog_reset();
  emit_res_init();

  for (s = 0; s < 3; s++) begin                       // vsetvli rd, rs1
    vlmax = 16 / (sews[s] / 8);
    avls[0] = 0;  avls[1] = 1;  avls[2] = vlmax - 1;  avls[3] = vlmax;  avls[4] = vlmax + 1;  avls[5] = 1030;
    for (k = 0; k < 6; k++) begin
      avl = avls[k];
      emit_li(5'd10, 32'(avl));
      emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(sews[s])));
      emit_sw_res(5'd11, slot);
      exp_s[slot] = 32'((avl < vlmax) ? avl : vlmax);
      slot++;
    end
  end
  for (s = 0; s < 3; s++) begin                       // vsetivli rd, uimm
    vlmax = 16 / (sews[s] / 8);
    avls[0] = 0;  avls[1] = 1;  avls[2] = vlmax - 1;  avls[3] = vlmax;  avls[4] = vlmax + 1;  avls[5] = 31;
    zz = vtype_zimm(sews[s]);
    for (k = 0; k < 6; k++) begin
      avl = avls[k];
      emit(rv_vsetivli(5'd11, avl[4:0], zz[9:0]));
      emit_sw_res(5'd11, slot);
      exp_s[slot] = 32'((avl < vlmax) ? avl : vlmax);
      slot++;
    end
  end
  for (s = 0; s < 3; s++) begin                       // rs1 = x0, rd != x0
    vlmax = 16 / (sews[s] / 8);
    emit(rv_vsetvli(5'd11, 5'd0, vtype_zimm(sews[s])));
    emit_sw_res(5'd11, slot);
    exp_s[slot] = 32'(vlmax);
    slot++;
  end

  // strip-mining: x12 = remaining AVL, x13 = output pointer (result slots from 128)
  emit_li(5'd12, 32'd1030);
  emit_li(5'd13, TB_RES_BASE + 32'h200);
  emit(rv_vsetvli(5'd11, 5'd12, vtype_zimm(8)));     // loop start
  emit(rv_sw(5'd11, 5'd13, 0));
  emit(rv_sub(5'd12, 5'd12, 5'd11));
  emit(rv_addi(5'd13, 5'd13, 4));
  emit(rv_bne(5'd12, 5'd0, -16));
  emit_halt();

  dmem_fill(TB_RES_BASE, slot, 32'hDEAD_DEAD);
  dmem_fill(TB_RES_BASE + 32'h200, 66, 32'hDEAD_DEAD);
  run_prog(40000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "legal vsetvli/vsetivli raised an illegal instruction")

  for (i = 0; i < slot; i++) begin
    res_rd(i, d);
    if (d !== exp_s[i]) begin
      nerr++;
      `TC_CHECK(d === exp_s[i], $sformatf("result %0d: vl = %0d, expected %0d", i, d, exp_s[i]))
    end
  end
  for (i = 0; i < 66; i++) begin
    res_rd(128 + i, d);
    ev = (i < 64) ? 16 : ((i == 64) ? 6 : -1);
    if (ev >= 0) begin
      if (d !== 32'(ev)) begin
        nerr++;
        `TC_CHECK(d === 32'(ev), $sformatf("strip-mining iteration %0d: vl = %0d, expected %0d", i, d, ev))
      end
    end else begin
      `TC_CHECK(d === 32'hDEAD_DEAD, $sformatf("strip-mining ran more than 65 iterations (slot %0d = %08h)", i, d))
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d vl mismatches", nerr))
  mon_check_all();
endtask
