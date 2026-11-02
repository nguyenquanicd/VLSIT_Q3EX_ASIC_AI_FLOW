// TC-052 | REQ-045, REQ-046, REQ-050, REQ-051
// Legal parameter sets elaborate (flow script: one compile per set, must succeed; TC_INFO ELAB_EXPECT_OK lines list
// them) and the derived local parameters of the DEFAULT build are checked through their observable effect:
//   LPARA_VL_W   : vsetvli returns min(AVL, VLMAX) with VLMAX = 16 / 8 / 4 (SEW 8/16/32) -> vl width covers 16
//   LPARA_ROW_LB : DMEM rows are 16 bytes: vse32 of consecutive registers to consecutive 16-byte rows and host reads
//   LPARA_VREG_COUNT = 32 : all 32 vector registers v0..v31 hold independent values
//   LPARA_LANE_W = 32     : full 32-bit elements (SEW=32) survive a register / lane round trip
task automatic tc_052_param_legal_elaborate();
  logic [31:0] iv [0:6];
  logic [31:0] il [0:6];
  logic [31:0] sw_t [0:6];
  logic [31:0] av_t [0:6];
  logic [31:0] ev_t [0:6];
  logic [31:0] d, val, DATA;
  bit          c1, c2, c3;
  int          k, r, w;

  iv[0] = 128; il[0] = 1;
  iv[1] = 128; il[1] = 2;
  iv[2] = 128; il[2] = 4;
  iv[3] = 256; il[3] = 1;
  iv[4] = 256; il[4] = 2;
  iv[5] = 256; il[5] = 4;
  iv[6] = 256; il[6] = 8;
  for (k = 0; k < 7; k++) begin
    c1 = (iv[k] == 128 || iv[k] == 256);
    c2 = (il[k] == 1 || il[k] == 2 || il[k] == 4 || il[k] == 8);
    c3 = (il[k] != 0) && ((iv[k] % (il[k] * 32)) == 0);
    `TC_CHECK(c1 && c2 && c3, $sformatf("set PARA_VLEN=%0d PARA_LANE_COUNT=%0d is listed as legal but violates C1..C3", iv[k], il[k]))
    $display("TC_INFO ELAB_EXPECT_OK PARA_VLEN=%0d PARA_LANE_COUNT=%0d", iv[k], il[k]);
  end

  // vsetvli table: (SEW, AVL) -> expected vl for PARA_VLEN = 128
  sw_t[0] = 8;  av_t[0] = 16;   ev_t[0] = 16;
  sw_t[1] = 8;  av_t[1] = 17;   ev_t[1] = 16;
  sw_t[2] = 8;  av_t[2] = 1030; ev_t[2] = 16;
  sw_t[3] = 16; av_t[3] = 100;  ev_t[3] = 8;
  sw_t[4] = 32; av_t[4] = 100;  ev_t[4] = 4;
  sw_t[5] = 32; av_t[5] = 3;    ev_t[5] = 3;
  sw_t[6] = 8;  av_t[6] = 15;   ev_t[6] = 15;

  DATA = TB_DATA_BASE + 32'h400;
  prog_reset();
  emit_res_init();
  for (k = 0; k < 7; k++) begin
    emit_li(5'd10, av_t[k]);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(int'(sw_t[k]))));
    emit_sw_res(5'd11, k);
  end
  emit_li(5'd10, 32'd4);
  emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(32)));                 // SEW=32, vl=4: one full row of 32-bit elements
  for (r = 0; r < 32; r++) begin
    emit_li(5'd5, (r + 1) * 32'h0102_0305);                       // distinct 32-bit value per register
    emit(rv_vmv_v_x(r[4:0], 5'd5));
  end
  for (r = 0; r < 32; r++) begin
    emit_li(5'd12, DATA + 32'(16 * r));
    emit(rv_vse32(r[4:0], 5'd12));
  end
  emit_halt();

  run_prog(100000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0,        "illegal instruction in the register-file / vl program")

  for (k = 0; k < 7; k++) begin
    res_rd(k, d);
    `TC_CHECK(d === ev_t[k], $sformatf("vsetvli e%0d AVL=%0d returned %0d, expected %0d", sw_t[k], av_t[k], d, ev_t[k]))
  end
  for (r = 0; r < 32; r++) begin
    val = (r + 1) * 32'h0102_0305;
    for (w = 0; w < 4; w++) begin
      dmem_rd(DATA + 32'(16 * r + 4 * w), d);
      `TC_CHECK(d === val, $sformatf("v%0d element %0d = %08h, expected %08h (register count / lane width / row map)", r, w, d, val))
    end
  end
  mon_check_all();
endtask
