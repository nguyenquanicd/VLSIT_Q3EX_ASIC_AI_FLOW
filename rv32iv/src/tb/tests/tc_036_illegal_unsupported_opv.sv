// TC-036 | REQ-054, REQ-052
// Every OP-V / vector memory form outside the exact legal set (REQ-004/005/008 forms plus vwmul.vv and vwredsum.vs)
// is an illegal instruction: o_halt=1, o_err_illegal=1, sts.err event, not dispatched to the VPU (only the preceding
// legal vsetvli e8 reaches it), no VPU memory access, older store completes, younger stores do not execute.
// One program per form (own reset). Operand registers are legal (even vd for widening, x30 = valid DMEM address)
// so that an accepted form would really execute.
task automatic tc_036_illegal_unsupported_opv();
  logic [31:0] c_ins [0:79];
  string       nm    [0:79];
  logic [31:0] d;
  int          n, c, c0, m0;

  n = 0;
  // ---- forms close to legal ones
  c_ins[n] = {1'b1, 6'b000000, 5'd12, 5'd10, 3'b111, 5'd11, 7'h57};          nm[n] = "vsetvl (register form)";  n++;
  c_ins[n] = enc_opv(6'b111000, 1'b1, 5'd1, 5'd2, 3'b010, 5'd4);             nm[n] = "vwmulu.vv";               n++;
  c_ins[n] = enc_opv(6'b110000, 1'b1, 5'd4, 5'd3, 3'b000, 5'd8);             nm[n] = "vwredsumu.vs";            n++;
  c_ins[n] = enc_opv(6'b000000, 1'b1, 5'd1, 5'd3, 3'b011, 5'd3);             nm[n] = "vadd.vi";                 n++;
  c_ins[n] = enc_opv(6'b101001, 1'b1, 5'd1, 5'd2, 3'b000, 5'd3);             nm[n] = "vsra.vv";                 n++;
  c_ins[n] = enc_opv(6'b000111, 1'b1, 5'd1, 5'd2, 3'b000, 5'd3);             nm[n] = "vmax.vv";                 n++;
  c_ins[n] = enc_opv(6'b101111, 1'b1, 5'd2, 5'd1, 3'b000, 5'd3);             nm[n] = "vnclip.wv";               n++;
  c_ins[n] = enc_opv(6'b111011, 1'b1, 5'd1, 5'd12, 3'b110, 5'd4);            nm[n] = "vwmul.vx";                n++;
  c_ins[n] = enc_opv(6'b010111, 1'b1, 5'd0, 5'd1, 3'b000, 5'd3);             nm[n] = "vmv.v.v";                 n++;
  c_ins[n] = enc_opv(6'b010111, 1'b1, 5'd0, 5'd5, 3'b011, 5'd3);             nm[n] = "vmv.v.i";                 n++;
  // ---- unsupported operations
  c_ins[n] = rv_vsub_vv(3, 1, 2);                                            nm[n] = "vsub.vv";                 n++;
  c_ins[n] = rv_vmul_vv(3, 1, 2);                                            nm[n] = "vmul.vv";                 n++;
  c_ins[n] = rv_vand_vv(3, 1, 2);                                            nm[n] = "vand.vv";                 n++;
  c_ins[n] = rv_vredsum_vs(3, 1, 2);                                         nm[n] = "vredsum.vs";              n++;
  c_ins[n] = rv_vfadd_vv(3, 1, 2);                                           nm[n] = "vfadd.vv";                n++;
  // ---- masked forms (vm = 0) of the supported instructions
  c_ins[n] = rv_vadd_vv(3, 1, 2, 1'b0);                                      nm[n] = "vadd.vv vm=0";            n++;
  c_ins[n] = rv_vadd_vx(3, 1, 12, 1'b0);                                     nm[n] = "vadd.vx vm=0";            n++;
  c_ins[n] = rv_vsra_vi(3, 1, 2, 1'b0);                                      nm[n] = "vsra.vi vm=0";            n++;
  c_ins[n] = rv_vsra_vx(3, 1, 12, 1'b0);                                     nm[n] = "vsra.vx vm=0";            n++;
  c_ins[n] = rv_vmax_vx(3, 1, 12, 1'b0);                                     nm[n] = "vmax.vx vm=0";            n++;
  c_ins[n] = rv_vnclip_wi(3, 2, 3, 1'b0);                                    nm[n] = "vnclip.wi vm=0";          n++;
  c_ins[n] = rv_vnclip_wx(3, 2, 12, 1'b0);                                   nm[n] = "vnclip.wx vm=0";          n++;
  c_ins[n] = rv_vwmul_vv(4, 1, 2, 1'b0);                                     nm[n] = "vwmul.vv vm=0";           n++;
  c_ins[n] = rv_vwredsum_vs(8, 4, 3, 1'b0);                                  nm[n] = "vwredsum.vs vm=0";        n++;
  c_ins[n] = enc_opv(6'b010111, 1'b0, 5'd1, 5'd12, 3'b100, 5'd3);            nm[n] = "vmerge.vxm (vmv.v.x vm=0)"; n++;
  c_ins[n] = enc_opv(6'b010000, 1'b0, 5'd0, 5'd12, 3'b110, 5'd3);            nm[n] = "vmv.s.x vm=0";            n++;
  c_ins[n] = enc_opv(6'b010000, 1'b0, 5'd1, 5'd0, 3'b010, 5'd5);             nm[n] = "vmv.x.s vm=0";            n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b0, 5'b00000, 5'd30, 3'b000, 5'd1);  nm[n] = "vle8 vm=0";   n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b0, 5'b00000, 5'd30, 3'b000, 5'd1);  nm[n] = "vse8 vm=0";   n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b0, 5'b00000, 5'd30, 3'b110, 5'd1);  nm[n] = "vle32 vm=0";  n++;
  // ---- 16-bit and 64-bit unit-stride accesses
  c_ins[n] = rv_vle16(1, 30);                                                nm[n] = "vle16";                   n++;
  c_ins[n] = rv_vse16(1, 30);                                                nm[n] = "vse16";                   n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd30, 3'b111, 5'd1);  nm[n] = "vle64";       n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd30, 3'b111, 5'd1);  nm[n] = "vse64";       n++;
  // ---- mask, whole-register, fault-only-first, segment, strided, indexed loads/stores
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b01011, 5'd30, 3'b000, 5'd1);  nm[n] = "vlm.v";       n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b01011, 5'd30, 3'b000, 5'd1);  nm[n] = "vsm.v";       n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b01000, 5'd30, 3'b000, 5'd1);  nm[n] = "vl1re8.v";    n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b01000, 5'd30, 3'b000, 5'd1);  nm[n] = "vs1r.v";      n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b10000, 5'd30, 3'b000, 5'd1);  nm[n] = "vle8ff.v";    n++;
  c_ins[n] = rv_vmem(1'b0, 3'b001, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd30, 3'b000, 5'd2);  nm[n] = "vlseg2e8.v";  n++;
  c_ins[n] = rv_vmem(1'b1, 3'b001, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd30, 3'b000, 5'd2);  nm[n] = "vsseg2e8.v";  n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b10, 1'b1, 5'd12,    5'd30, 3'b000, 5'd1);  nm[n] = "vlse8.v";     n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b10, 1'b1, 5'd12,    5'd30, 3'b000, 5'd1);  nm[n] = "vsse8.v";     n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b01, 1'b1, 5'd2,     5'd30, 3'b000, 5'd1);  nm[n] = "vluxei8.v";   n++;
  c_ins[n] = rv_vmem(1'b0, 3'b000, 1'b0, 2'b11, 1'b1, 5'd2,     5'd30, 3'b000, 5'd1);  nm[n] = "vloxei8.v";   n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b01, 1'b1, 5'd2,     5'd30, 3'b000, 5'd1);  nm[n] = "vsuxei8.v";   n++;
  c_ins[n] = rv_vmem(1'b1, 3'b000, 1'b0, 2'b11, 1'b1, 5'd2,     5'd30, 3'b000, 5'd1);  nm[n] = "vsoxei8.v";   n++;

  for (c = 0; c < n; c++) begin
    prog_reset();
    emit_res_init();
    emit_li(5'd30, TB_DATA_BASE);                       // valid, row-aligned DMEM address
    emit_li(5'd12, 3);
    emit_li(5'd10, 4);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));      // legal: SEW 8, vl = 4 (so SEW-dependent forms would be legal)
    emit_sw_res(5'd11, 0);                              // older store
    repeat (4) emit(rv_nop());
    emit(c_ins[c]);                                     // form under test
    emit_li(5'd2, 32'hBBBB);
    emit_sw_res(5'd2, 1);                               // younger stores: must not execute
    emit_sw_res(5'd2, 2);
    emit_halt();

    dmem_fill(TB_DATA_BASE, 8, 32'h0102_0304);
    dmem_fill(TB_RES_BASE, 8, 32'hC0FF_EE11);
    c0 = tb_vcmd_cnt;
    m0 = tb_vmem_xfer_cnt;
    run_prog(3000);

    // live state first (a host access resets the DUT)
    `TC_CHECK(tb_run_hit, $sformatf("[%s] core did not halt", nm[c]))
    `TC_CHECK(o_halt === 1'b1, $sformatf("[%s] o_halt not 1", nm[c]))
    `TC_CHECK(o_err_illegal === 1'b1, $sformatf("[%s] o_err_illegal not 1 (unsupported form %08h accepted)", nm[c], c_ins[c]))
    `TC_CHECK(tb_sts_err_events >= 1, $sformatf("[%s] sts.err not set", nm[c]))
    `TC_CHECK(tb_vcmd_cnt - c0 == 1, $sformatf("[%s] %0d commands dispatched, expected 1 (only the vsetvli)", nm[c], tb_vcmd_cnt - c0))
    `TC_CHECK(tb_vmem_xfer_cnt - m0 == 0, $sformatf("[%s] VPU memory access seen", nm[c]))
    chk_halted_stable(2);
    res_rd(0, d); `TC_CHECK(d === 32'd4, $sformatf("[%s] older vsetvli result = %08h, expected 4", nm[c], d))
    res_rd(1, d); `TC_CHECK(d === 32'hC0FF_EE11, $sformatf("[%s] younger store 1 executed (%08h)", nm[c], d))
    res_rd(2, d); `TC_CHECK(d === 32'hC0FF_EE11, $sformatf("[%s] younger store 2 executed (%08h)", nm[c], d))
  end
  mon_check_all();
endtask
