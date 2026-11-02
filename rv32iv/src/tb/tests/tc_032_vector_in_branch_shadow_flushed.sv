// TC-032 | REQ-081, REQ-084, REQ-009, REQ-003
// Vector instructions in the wrong-path shadow of a taken jump/branch are neither dispatched nor executed.
//   shadow A (jal)  : vsetvli x12,x11,e32 (AVL 2) -- if executed vl would become 2 and the later vse8 would write 2 bytes
//   shadow B (beq)  : vse8 v1,(x28)               -- if executed the shadow row would change
//   shadow C (bne)  : vmv.x.s x13,v1              -- if executed x13 would no longer be 0x77
// Legal commands only: vsetvli, vle8, vse8 (3 dispatches, 2 VPU memory accesses).
task automatic tc_032_vector_in_branch_shadow_flushed();
  logic [31:0] d, w0, w1, w2;
  int          i;

  prog_reset();
  emit_res_init();
  emit_li(5'd30, TB_DATA_BASE);
  emit_li(5'd29, TB_DATA_BASE + 32'h40);        // OUT row
  emit_li(5'd28, TB_DATA_BASE + 32'h80);        // shadow row
  emit_li(5'd10, 16);
  emit_li(5'd11, 2);
  emit_li(5'd13, 32'h77);
  repeat (3) emit(rv_nop());
  emit(rv_vsetvli(5'd5, 5'd10, vtype_zimm(8)));  // legal: vl = 16
  emit(rv_vle8(5'd1, 5'd30));                    // legal
  repeat (4) emit(rv_nop());
  // ---- shadow A: taken jal over a vsetvli
  emit(rv_jal(5'd0, 12));
  emit(rv_vsetvli(5'd12, 5'd11, vtype_zimm(32)));
  emit(rv_nop());
  emit(rv_vse8(5'd1, 5'd29));                    // jump target: legal vse8 of all 16 bytes (vl must still be 16)
  repeat (4) emit(rv_nop());
  // ---- shadow B: taken beq over a vse8
  emit(rv_beq(5'd0, 5'd0, 12));
  emit(rv_vse8(5'd1, 5'd28));
  emit(rv_nop());
  emit(rv_nop());                                // target
  // ---- shadow C: taken bne over a vmv.x.s
  emit(rv_bne(5'd10, 5'd0, 12));
  emit(rv_vmv_x_s(5'd13, 5'd1));
  emit(rv_nop());
  emit_sw_res(5'd13, 0);                         // target: x13 must still be 0x77
  emit_halt();

  dmem_fill(TB_DATA_BASE, 4, 32'h0403_0201);
  w0 = 32'h0403_0201;
  dmem_wr(TB_DATA_BASE + 32'h0, 32'h0403_0201);
  dmem_wr(TB_DATA_BASE + 32'h4, 32'h0807_0605);
  dmem_wr(TB_DATA_BASE + 32'h8, 32'h0C0B_0A09);
  dmem_wr(TB_DATA_BASE + 32'hC, 32'h100F_0E0D);
  dmem_fill(TB_DATA_BASE + 32'h40, 4, 32'hEEEE_EEEE);
  dmem_fill(TB_DATA_BASE + 32'h80, 4, 32'hBBBB_BBBB);
  dmem_fill(TB_RES_BASE, 4, 32'hC0FF_EE11);
  run_prog(5000);

  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "unexpected illegal instruction (wrong-path vector instruction decoded as illegal?)")
  `TC_CHECK(tb_vcmd_cnt == 3, $sformatf("%0d vector commands dispatched, expected 3 (vsetvli, vle8, vse8): a wrong-path command reached the VPU", tb_vcmd_cnt))
  `TC_CHECK(tb_vmem_xfer_cnt == 2, $sformatf("%0d VPU memory accesses, expected 2", tb_vmem_xfer_cnt))
  w1 = 32'h0807_0605;
  for (i = 0; i < 4; i++) begin
    dmem_rd(TB_DATA_BASE + 32'h40 + 32'(4 * i), d);
    case (i)
      0: w2 = 32'h0403_0201;
      1: w2 = 32'h0807_0605;
      2: w2 = 32'h0C0B_0A09;
      default: w2 = 32'h100F_0E0D;
    endcase
    `TC_CHECK(d === w2, $sformatf("OUT word %0d = %08h, expected %08h (wrong-path vsetvli changed vl, or vse8 incomplete)", i, d, w2))
    dmem_rd(TB_DATA_BASE + 32'h80 + 32'(4 * i), d);
    `TC_CHECK(d === 32'hBBBB_BBBB, $sformatf("shadow row word %0d changed (%08h): wrong-path vse8 executed", i, d))
  end
  res_rd(0, d);
  `TC_CHECK(d === 32'h77, $sformatf("x13 = %08h, expected 0x77: wrong-path vmv.x.s executed", d))
  mon_check_all();
endtask
