// TC-056 | REQ-014, REQ-012
// System test: delivered firmware + weights + one MNIST image loaded through the host port in reset, run from
// i_start_req, compare label/logits with the golden model and the UART byte with '0'+label.
//
// Vector files from the golden-model / firmware flow (plusargs, all $readmemh text files, one 32-bit hex word
// per line, little-endian byte packing):
//   +FW_HEX=<file>      firmware image, word 0 = IMEM address 0 (at most 8192 words)
//   +DMEM_HEX=<file>    static DMEM image (weights, biases, ...) starting at DMEM_BASE (0x1000_0000);
//                       +DMEM_WORDS=<n> limits how many words are written (default 65536)
//   +IMG_HEX=<file>     test images, 196 words (784 INT8 pixels) per image
//   +EXP_HEX=<file>     expected results, 11 words per image: label, logit[0..9]
//   +IMG_ADDR=<hex>     DMEM address the firmware reads the image from  (from the firmware .layout file)
//   +LOGIT_ADDR=<hex>   DMEM address of the 10 INT32 logits written by the firmware (from the .layout file)
//   +IMG_IDX=<n>        image index (default 0)      +BAUD=<n> uart_cfg.baud_div used by the firmware (default 1736)
// Default vectors: every plusarg that is missing is taken from the golden-model flow output directory
//   <dir>/mnist_fw.hex, mnist_dmem.hex, mnist_img.hex, mnist_exp.hex and <dir>/mnist.plusargs
//   (tokens IMG_ADDR=<hex> LOGIT_ADDR=<hex> DMEM_WORDS=<n> NIMG=<n> BAUD=<n>, with or without a leading '+',
//   separated by blanks / newlines / commas). <dir> = +VEC_DIR=<dir>, else build/tb/programs relative to the run
//   directory (also ../, ../../, ../../../) or the absolute project build directory.
// Only when the files really do not exist the test is NOT run: it prints TC_DV_TODO and records a failing check whose
// detail starts with "DV_TODO" (never a PASS; the marker separates this run-configuration problem from a DUT failure).
task automatic tc_056_mnist_single_image_system();
  string       fw_p, dm_p, img_p, exp_p;
  string       cand [0:5];
  string       vdir, pa_path, ln, tok, key, val;
  logic [31:0] img_addr, log_addr, d;
  logic [31:0] expa [0:1099];
  int          idx, baud, ndm, j, k, p, fd, nerr, ninf;
  bit          ok_fw, ok_dm, ok_img, ok_exp, ok_ia, ok_la, ok_baud, ok_ndm, ok_f, ok, found;
  byte         ch;
  longint unsigned t0, lat;

  idx = 0;  baud = 1736;  ndm = 65536;  ninf = 0;
  void'($value$plusargs("IMG_IDX=%d", idx));
  ok_baud = $value$plusargs("BAUD=%d", baud);
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
                  if (key == "BAUD"       && !ok_baud) begin void'($sscanf(val, "%d", baud));     ok_baud = 1; end
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
      $display("TB_INFO %s: golden vectors from %s (IMG_ADDR=%h LOGIT_ADDR=%h DMEM_WORDS=%0d BAUD=%0d)",
               tc_id_s, vdir, img_addr, log_addr, ndm, baud);
    end
  end

  if (!(ok_fw && ok_dm && ok_img && ok_exp && ok_ia && ok_la)) begin
    $display("TC_DV_TODO %s: not run - golden-model vector files not found (+VEC_DIR / build/tb/programs)", tc_id_s);
    `TC_CHECK(1'b0, "DV_TODO (not run, no DUT activity): golden vectors mnist_{fw,dmem,img,exp}.hex + mnist.plusargs not found; pass +FW_HEX +DMEM_HEX +IMG_HEX +EXP_HEX +IMG_ADDR +LOGIT_ADDR or +VEC_DIR")
    return;
  end

  // ---- expected results first (tb_buf is reused for the other files afterwards)
  tb_readmem(exp_p, ok);
  `TC_CHECK(ok, $sformatf("cannot open expected-result file %s", exp_p))
  if (!ok) return;
  for (j = 0; j < 1100; j++) expa[j] = tb_buf[j];

  // ---- load firmware, weights, image through the host port (reset asserted, i_ld_en = 1)
  host_begin();
  tb_readmem(fw_p, ok_f);
  `TC_CHECK(ok_f, $sformatf("cannot open firmware file %s", fw_p))
  host_load_buf(IMEM_BASE, 8192);
  tb_readmem(dm_p, ok_f);
  `TC_CHECK(ok_f, $sformatf("cannot open DMEM image file %s", dm_p))
  host_load_buf(DMEM_BASE, ndm);
  tb_readmem(img_p, ok_f);
  `TC_CHECK(ok_f, $sformatf("cannot open image file %s", img_p))
  host_load_buf(img_addr, 196, idx * 196);
  dmem_fill(log_addr, 10, 32'h0);                 // stale logits must not be mistaken for a result

  // ---- run
  tb_uart_baud = baud;
  host_end();
  wait_cycles(20);
  t0 = tb_cycle;
  start_pulse(1);                                 // ctrl.start is set by hardware, firmware clears it
  wait_sts_done(1_500_000);
  lat = tb_cycle - t0;
  `TC_CHECK(tb_run_hit, "o_sts_done never rose: inference did not complete")
  `TC_CHECK(o_err_illegal === 1'b0, "illegal instruction during inference")
  `TC_CHECK(o_halt === 1'b0,        "core halted before the result was reported")
  `TC_CHECK(o_result_label === expa[idx * 11][3:0],
            $sformatf("o_result_label = %0d, golden label = %0d", o_result_label, expa[idx * 11]))
  `TC_CHECK(lat < 1000000, $sformatf("inference took %0d cycles (target < 1,000,000)", lat))
  $display("TB_INFO TC-056 inference latency %0d cycles, label %0d", lat, o_result_label);

  // ---- UART byte '0' + label
  uart_wait_frames(1, 12 * baud + 40000);
  `TC_CHECK(tb_uart_rx_data.size() >= 1, "no UART frame after the result (check +BAUD)")
  if (tb_uart_rx_data.size() >= 1) begin
    `TC_CHECK(tb_uart_rx_data[0] === (8'h30 + expa[idx * 11][7:0]),
              $sformatf("UART byte %02h, expected '0'+label = %02h", tb_uart_rx_data[0], 8'h30 + expa[idx * 11][7:0]))
    `TC_CHECK(tb_uart_rx_start_ok[0] && tb_uart_rx_stop_ok[0] && tb_uart_rx_len_ok[0], "UART frame malformed")
  end
  `TC_CHECK(o_err_illegal === 1'b0, "illegal instruction after the result")

  // ---- logits (read through the host port; this puts the DUT in reset)
  nerr = 0;
  for (j = 0; j < 10; j++) begin
    dmem_rd(log_addr + 32'(j * 4), d);
    if (d !== expa[idx * 11 + 1 + j]) begin
      nerr++;
      `TC_CHECK(d === expa[idx * 11 + 1 + j],
                $sformatf("logit %0d = %08h, golden %08h", j, d, expa[idx * 11 + 1 + j]))
    end
  end
  `TC_CHECK(nerr == 0, "logits are not bit-identical to the golden model")
  tb_uart_baud = 0;
  mon_check_all();
endtask
