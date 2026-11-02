// TC-057 | REQ-014, REQ-064
// 100 MNIST images, each run from reset: label and logits bit-exact vs the golden model, inference time
// (start pulse to o_sts_done) below 1,000,000 cycles, no halt / illegal instruction.
// Plusargs and file formats as in TC-056 (+FW_HEX +DMEM_HEX +IMG_HEX +EXP_HEX +IMG_ADDR +LOGIT_ADDR);
// +NIMG=<n> selects the number of images (default 100, at most 334).
// Default vectors as in TC-056: every missing plusarg is taken from <dir>/mnist_{fw,dmem,img,exp}.hex and
// <dir>/mnist.plusargs (IMG_ADDR, LOGIT_ADDR, DMEM_WORDS, NIMG, BAUD); <dir> = +VEC_DIR, else build/tb/programs
// (relative to the run directory, ../, ../../, ../../../) or the absolute project build directory.
// Only when the files really do not exist the test is NOT run: TC_DV_TODO is printed and a failing check with a
// "DV_TODO" detail is recorded (never a PASS, and distinguishable from a DUT failure).
task automatic tc_057_mnist_100_images_latency();
  string       fw_p, dm_p, img_p, exp_p;
  string       cand [0:5];
  string       vdir, pa_path, ln, tok, key, val;
  logic [31:0] img_addr, log_addr, d;
  logic [31:0] expa [0:3999];
  int          nimg, ndm, baud, i, j, k, p, fd, nbad_lbl, nbad_log, nslow, nfail_run;
  bit          ok_fw, ok_dm, ok_img, ok_exp, ok_ia, ok_la, ok_nimg, ok_ndm, ok_f, ok, found;
  byte         ch;
  longint unsigned t0, lat, lat_max, lat_sum;

  nimg = 100;  ndm = 65536;  baud = 1736;
  ok_nimg = $value$plusargs("NIMG=%d", nimg);
  ok_ndm  = $value$plusargs("DMEM_WORDS=%d", ndm);
  ok_fw  = $value$plusargs("FW_HEX=%s",   fw_p);
  ok_dm  = $value$plusargs("DMEM_HEX=%s", dm_p);
  ok_img = $value$plusargs("IMG_HEX=%s",  img_p);
  ok_exp = $value$plusargs("EXP_HEX=%s",  exp_p);
  ok_ia  = $value$plusargs("IMG_ADDR=%h", img_addr);
  ok_la  = $value$plusargs("LOGIT_ADDR=%h", log_addr);

  // ---- default vectors for everything that was not given on the command line
  if (!(ok_fw && ok_dm && ok_img && ok_exp && ok_ia && ok_la)) begin
    cand[0] = "";
    if (!$value$plusargs("VEC_DIR=%s", cand[0])) cand[0] = "";
    cand[1] = "build/tb/programs";
    cand[2] = "../build/tb/programs";
    cand[3] = "../../build/tb/programs";
    cand[4] = "../../../build/tb/programs";
    cand[5] = "build/tb/programs";
    found = 0;
    vdir  = "";
    for (k = 0; k < 6 && !found; k++) begin
      if (cand[k] != "") begin
        fd = $fopen($sformatf("%s/mnist_fw.hex", cand[k]), "r");
        if (fd != 0) begin
          $fclose(fd);
          vdir  = cand[k];
          found = 1;
        end
      end
    end
    if (found) begin
      if (!ok_fw)  begin fw_p  = $sformatf("%s/mnist_fw.hex",   vdir); ok_fw  = 1; end
      if (!ok_dm)  begin dm_p  = $sformatf("%s/mnist_dmem.hex", vdir); ok_dm  = 1; end
      if (!ok_img) begin img_p = $sformatf("%s/mnist_img.hex",  vdir); ok_img = 1; end
      if (!ok_exp) begin exp_p = $sformatf("%s/mnist_exp.hex",  vdir); ok_exp = 1; end
      pa_path = $sformatf("%s/mnist.plusargs", vdir);
      fd = $fopen(pa_path, "r");
      if (fd != 0) begin
        while (!$feof(fd)) begin
          ln = "";
          void'($fgets(ln, fd));
          tok = "";
          for (k = 0; k <= ln.len(); k++) begin
            ch = (k < ln.len()) ? ln.getc(k) : 8'h20;
            if (ch == 8'h20 || ch == 8'h09 || ch == 8'h0A || ch == 8'h0D || ch == 8'h2C) begin
              if (tok.len() > 1 || (tok.len() == 1 && tok.getc(0) != 8'h2B)) begin
                if (tok.getc(0) == 8'h2B) tok = tok.substr(1, tok.len() - 1);          // strip a leading '+'
                p = -1;
                for (j = 0; j < tok.len() && p < 0; j++) if (tok.getc(j) == 8'h3D) p = j;   // '='
                if (p > 0 && p < tok.len() - 1) begin
                  key = tok.substr(0, p - 1);
                  val = tok.substr(p + 1, tok.len() - 1);
                  if (val.len() > 2 && val.substr(0, 1) == "0x") val = val.substr(2, val.len() - 1);
                  if (key == "IMG_ADDR"   && !ok_ia)   begin void'($sscanf(val, "%h", img_addr)); ok_ia = 1; end
                  if (key == "LOGIT_ADDR" && !ok_la)   begin void'($sscanf(val, "%h", log_addr)); ok_la = 1; end
                  if (key == "DMEM_WORDS" && !ok_ndm)  begin void'($sscanf(val, "%d", ndm));      ok_ndm = 1; end
                  if (key == "NIMG"       && !ok_nimg) begin void'($sscanf(val, "%d", nimg));     ok_nimg = 1; end
                end
              end
              tok = "";
            end else begin
              tok = $sformatf("%s%c", tok, ch);
            end
          end
        end
        $fclose(fd);
      end
      $display("TB_INFO %s: golden vectors from %s (IMG_ADDR=%h LOGIT_ADDR=%h DMEM_WORDS=%0d NIMG=%0d)",
               tc_id_s, vdir, img_addr, log_addr, ndm, nimg);
    end
  end

  if (!(ok_fw && ok_dm && ok_img && ok_exp && ok_ia && ok_la)) begin
    $display("TC_DV_TODO %s: not run - golden-model vector files not found (+VEC_DIR / build/tb/programs)", tc_id_s);
    `TC_CHECK(1'b0, "DV_TODO (not run, no DUT activity): golden vectors mnist_{fw,dmem,img,exp}.hex + mnist.plusargs not found; pass +FW_HEX +DMEM_HEX +IMG_HEX +EXP_HEX +IMG_ADDR +LOGIT_ADDR or +VEC_DIR")
    return;
  end
  if (nimg > 334) nimg = 334;
  `TC_CHECK(nimg * 11 <= 4000, "too many images for the expected-result buffer")
  if (nimg * 11 > 4000) return;

  tb_readmem(exp_p, ok);
  `TC_CHECK(ok, $sformatf("cannot open expected-result file %s", exp_p))
  if (!ok) return;
  for (j = 0; j < 4000; j++) expa[j] = tb_buf[j];

  // ---- firmware and weights are loaded once; the images stay in tb_buf and are written one by one
  host_begin();
  tb_readmem(fw_p, ok_f);
  `TC_CHECK(ok_f, $sformatf("cannot open firmware file %s", fw_p))
  host_load_buf(IMEM_BASE, 8192);
  tb_readmem(dm_p, ok_f);
  `TC_CHECK(ok_f, $sformatf("cannot open DMEM image file %s", dm_p))
  host_load_buf(DMEM_BASE, ndm);
  tb_readmem(img_p, ok_f);                         // tb_buf now holds the images
  `TC_CHECK(ok_f, $sformatf("cannot open image file %s", img_p))

  nbad_lbl = 0;  nbad_log = 0;  nslow = 0;  nfail_run = 0;
  lat_max = 0;   lat_sum = 0;
  for (i = 0; i < nimg; i++) begin
    host_begin();                                  // reset (no-op for the first image); firmware/weights stay
    host_load_buf(img_addr, 196, i * 196);
    dmem_fill(log_addr, 10, 32'h0);
    host_end();
    wait_cycles(20);
    t0 = tb_cycle;
    start_pulse(1);
    wait_sts_done(1_200_000);
    lat = tb_cycle - t0;
    if (!tb_run_hit) begin
      nfail_run++;
      `TC_CHECK(tb_run_hit, $sformatf("image %0d: o_sts_done never rose", i))
    end else begin
      if (lat > lat_max) lat_max = lat;
      lat_sum += lat;
      if (lat >= 1000000) begin
        nslow++;
        `TC_CHECK(lat < 1000000, $sformatf("image %0d: inference took %0d cycles (target < 1,000,000)", i, lat))
      end
      if (o_err_illegal !== 1'b0 || o_halt !== 1'b0) begin
        nfail_run++;
        `TC_CHECK(1'b0, $sformatf("image %0d: halt/illegal instruction during inference", i))
      end
      if (o_result_label !== expa[i * 11][3:0]) begin
        nbad_lbl++;
        `TC_CHECK(o_result_label === expa[i * 11][3:0],
                  $sformatf("image %0d: o_result_label %0d, golden %0d", i, o_result_label, expa[i * 11]))
      end
      for (j = 0; j < 10; j++) begin
        dmem_rd(log_addr + 32'(j * 4), d);         // first read puts the DUT in reset (snapshot taken)
        if (d !== expa[i * 11 + 1 + j]) begin
          nbad_log++;
          if (nbad_log <= 20)
            `TC_CHECK(d === expa[i * 11 + 1 + j],
                      $sformatf("image %0d logit %0d = %08h, golden %08h", i, j, d, expa[i * 11 + 1 + j]))
        end
      end
    end
  end
  `TC_CHECK(nfail_run == 0, $sformatf("%0d images did not complete cleanly", nfail_run))
  `TC_CHECK(nbad_lbl == 0,  $sformatf("%0d labels differ from the golden model", nbad_lbl))
  `TC_CHECK(nbad_log == 0,  $sformatf("%0d logits differ from the golden model", nbad_log))
  `TC_CHECK(nslow == 0,     $sformatf("%0d inferences exceeded 1,000,000 cycles", nslow))
  $display("TB_INFO TC-057 images %0d, max latency %0d cycles, mean %0d", nimg, lat_max, (nimg > 0) ? lat_sum / nimg : 0);
  mon_check_all();
endtask
