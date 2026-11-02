// TC-023 | REQ-005, REQ-011, REQ-059, REQ-033, REQ-079
// Unit-stride vector loads/stores at row-aligned addresses, 11 cases: vle8/vse8 at SEW 8 with vl = 0, 1, 3, 7, 15, 16
// and vle32/vse32 at SEW 32 with vl = 0, 1, 2, 3, 4. Per case (row CB = 0x1000_5000 + c*0x100):
//   SRC +0x00 source row, PAT +0x10 register pre-load, DST +0x20 store target (pre-set 0xEE), OUT +0x30 register dump
//   1. v1 <- PAT (vl 16);  2. vle (vl elements) from SRC;  3. dump v1 with vl 16 -> OUT;  4. vse (vl elements) v1 -> DST
// Expected: v1 = SRC for the loaded bytes, PAT for the tail (tail undisturbed); DST = v1 for the stored bytes and
// 0xEE elsewhere (non-written bytes unchanged, byte-enable). Probe checks (monitors): o_mem_req held stable until
// i_mem_ack (mon_check_all) and i_mem_ack never in the first cycle of o_mem_req (REQ-079).
task automatic tc_023_vle_vse_unit_stride();
  int          c_sew [0:10];
  int          c_vl  [0:10];
  logic [7:0]  srcb [0:10][0:15];
  logic [7:0]  patb [0:10][0:15];
  logic [7:0]  regb [0:15];
  logic [31:0] CB, r, d, w;
  int          c, i, nb, wd, nerr;
  logic [7:0]  ex;

  c_sew[0]  = 8;   c_vl[0]  = 0;   c_sew[1]  = 8;   c_vl[1]  = 1;   c_sew[2]  = 8;   c_vl[2]  = 3;
  c_sew[3]  = 8;   c_vl[3]  = 7;   c_sew[4]  = 8;   c_vl[4]  = 15;  c_sew[5]  = 8;   c_vl[5]  = 16;
  c_sew[6]  = 32;  c_vl[6]  = 0;   c_sew[7]  = 32;  c_vl[7]  = 1;   c_sew[8]  = 32;  c_vl[8]  = 2;
  c_sew[9]  = 32;  c_vl[9]  = 3;   c_sew[10] = 32;  c_vl[10] = 4;
  nerr = 0;

  for (c = 0; c < 11; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    for (i = 0; i < 16; i++) begin
      r = tb_rand32();
      srcb[c][i] = r[7:0];
      patb[c][i] = r[15:8] ^ 8'h5A;
    end
    for (wd = 0; wd < 4; wd++) begin
      dmem_wr(CB + 32'h00 + 32'(4 * wd), {srcb[c][4*wd+3], srcb[c][4*wd+2], srcb[c][4*wd+1], srcb[c][4*wd]});
      dmem_wr(CB + 32'h10 + 32'(4 * wd), {patb[c][4*wd+3], patb[c][4*wd+2], patb[c][4*wd+1], patb[c][4*wd]});
      dmem_wr(CB + 32'h20 + 32'(4 * wd), 32'hEEEE_EEEE);
      dmem_wr(CB + 32'h30 + 32'(4 * wd), 32'hEEEE_EEEE);
    end
  end

  prog_reset();
  for (c = 0; c < 11; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    emit_li(5'd12, CB + 32'h00);
    emit_li(5'd13, CB + 32'h10);
    emit_li(5'd14, CB + 32'h20);
    emit_li(5'd15, CB + 32'h30);
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vle8(5'd1, 5'd13));                         // v1 <- PAT (all 16 bytes)
    emit_li(5'd10, 32'(c_vl[c]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(c_sew[c])));
    if (c_sew[c] == 8) emit(rv_vle8 (5'd1, 5'd12));     // vl elements from SRC, tail undisturbed
    else               emit(rv_vle32(5'd1, 5'd12));
    emit_li(5'd10, 32'd16);
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(8)));
    emit(rv_vse8(5'd1, 5'd15));                         // dump v1 (16 bytes)
    emit_li(5'd10, 32'(c_vl[c]));
    emit(rv_vsetvli(5'd11, 5'd10, vtype_zimm(c_sew[c])));
    if (c_sew[c] == 8) emit(rv_vse8 (5'd1, 5'd14));     // vl elements to DST, byte enables
    else               emit(rv_vse32(5'd1, 5'd14));
  end
  emit_halt();

  run_prog(100000);
  `TC_CHECK(tb_run_hit && o_halt === 1'b1, "program did not reach ebreak")
  `TC_CHECK(o_err_illegal === 1'b0, "legal vle/vse raised an illegal instruction")
  `TC_CHECK(tb_vmem_early_ack_cnt == 0, "REQ-079: i_mem_ack in the first cycle of o_mem_req")

  for (c = 0; c < 11; c++) begin
    CB = 32'h1000_5000 + 32'(c * 256);
    nb = (c_sew[c] == 8) ? c_vl[c] : 4 * c_vl[c];
    for (i = 0; i < 16; i++) regb[i] = (i < nb) ? srcb[c][i] : patb[c][i];
    for (wd = 0; wd < 4; wd++) begin
      dmem_rd(CB + 32'h30 + 32'(4 * wd), d);            // register dump: tail undisturbed
      w = {regb[4*wd+3], regb[4*wd+2], regb[4*wd+1], regb[4*wd]};
      if (d !== w) begin
        nerr++;
        `TC_CHECK(d === w, $sformatf("case %0d (e%0d vl=%0d): v1 word %0d = %08h, expected %08h",
                                     c, c_sew[c], c_vl[c], wd, d, w))
      end
      dmem_rd(CB + 32'h20 + 32'(4 * wd), d);            // stored row: only vl elements written
      for (i = 0; i < 4; i++) begin
        ex = (4 * wd + i < nb) ? regb[4*wd+i] : 8'hEE;
        if (d[8*i +: 8] !== ex) begin
          nerr++;
          `TC_CHECK(d[8*i +: 8] === ex, $sformatf("case %0d (e%0d vl=%0d): stored byte %0d = %02h, expected %02h",
                                                  c, c_sew[c], c_vl[c], 4 * wd + i, d[8*i +: 8], ex))
        end
      end
    end
  end
  `TC_CHECK(nerr == 0, $sformatf("%0d vector load/store mismatches", nerr))
  mon_check_all();
endtask
