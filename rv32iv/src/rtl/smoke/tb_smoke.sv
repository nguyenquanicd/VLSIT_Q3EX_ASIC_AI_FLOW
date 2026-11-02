// Smoke testbench for m_soc_top (written from the spec only).
// Loads small hand-assembled programs through the host port while in reset, runs them and
// checks the observable outputs (o_sts_done, o_result_label, o_halt, o_err_illegal, o_uart_tx)
// and the DMEM contents read back through the host port.
`timescale 1ns/1ps

module tb_smoke;

  localparam PERIOD     = 10;
  localparam MAX_CYCLES = 600000;
  localparam RUN_LIMIT  = 5000;   // cycles allowed for one tiny program

  reg         clk;
  reg         rst_n;
  reg         start_req;
  reg         ld_en;
  reg         ld_req;
  reg         ld_wr_en;
  reg  [31:0] ld_addr;
  reg  [3:0]  ld_byte_en;
  reg  [31:0] ld_wr_data;

  wire        sts_done;
  wire [3:0]  result_label;
  wire        uart_tx;
  wire        err_illegal;
  wire        halt;
  wire [31:0] ld_rd_data;

  m_soc_top #(
    .PARA_VLEN       (128),
    .PARA_LANE_COUNT (4)
  ) dut (
    .i_clk_core     (clk),
    .i_rst_n_core   (rst_n),
    .i_start_req    (start_req),
    .o_sts_done     (sts_done),
    .o_result_label (result_label),
    .o_uart_tx      (uart_tx),
    .o_err_illegal  (err_illegal),
    .o_halt         (halt),
    .i_ld_en        (ld_en),
    .i_ld_req       (ld_req),
    .i_ld_wr_en     (ld_wr_en),
    .i_ld_addr      (ld_addr),
    .i_ld_byte_en   (ld_byte_en),
    .i_ld_wr_data   (ld_wr_data),
    .o_ld_rd_data   (ld_rd_data)
  );

  initial clk = 1'b0;
  always #(PERIOD/2) clk = ~clk;

  // ------------------------------------------------------------------
  // Bookkeeping
  // ------------------------------------------------------------------
  integer total;
  integer failed;
  integer bfail;
  string  bmsg;
  integer cyc;
  integer ld_viol;

  task chk32(input string nm, input [31:0] got, input [31:0] exp);
    begin
      if (got !== exp) begin
        bfail = bfail + 1;
        bmsg  = {bmsg, $sformatf(" [%s exp=%h got=%h]", nm, exp, got)};
      end
    end
  endtask

  task bend(input string id);
    begin
      total = total + 1;
      if (bfail == 0) begin
        $display("SMOKE_RESULT %s PASS", id);
      end else begin
        failed = failed + 1;
        $display("SMOKE_RESULT %s FAIL%s", id, bmsg);
      end
      bfail = 0;
      bmsg  = "";
    end
  endtask

  // Watchdog: a hang is a failure
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (cyc > MAX_CYCLES) begin
      $display("SMOKE_RESULT WATCHDOG FAIL simulation did not finish in %0d cycles", MAX_CYCLES);
      $display("SMOKE_SUMMARY total=%0d failed=%0d", total + 1, failed + 1);
      $finish;
    end
  end

  // REQ-IF-009 / SVA-001: i_ld_en must be 0 whenever i_rst_n_core = 1
  always @(posedge clk) begin
    if (rst_n === 1'b1 && ld_en === 1'b1) ld_viol = ld_viol + 1;
  end

  // ------------------------------------------------------------------
  // Host port tasks (drive on the clock edge, sample before the next edge)
  // ------------------------------------------------------------------
  task host_write(input [31:0] addr, input [31:0] data, input [3:0] be);
    begin
      @(posedge clk);
      ld_req <= 1'b1; ld_wr_en <= 1'b1; ld_addr <= addr; ld_wr_data <= data; ld_byte_en <= be;
      @(posedge clk);
      ld_req <= 1'b0; ld_wr_en <= 1'b0;
    end
  endtask

  // request cycle, then data valid exactly one cycle later
  task host_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      ld_req <= 1'b1; ld_wr_en <= 1'b0; ld_addr <= addr; ld_byte_en <= 4'hF;
      @(posedge clk);
      ld_req <= 1'b0;
      @(posedge clk);
      data = ld_rd_data;
    end
  endtask

  // ------------------------------------------------------------------
  // Reset / program control
  // ------------------------------------------------------------------
  task reset_assert;
    begin
      @(posedge clk);
      ld_en <= 1'b1; rst_n <= 1'b0; ld_req <= 1'b0; ld_wr_en <= 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task reset_release;
    begin
      @(posedge clk);
      ld_en <= 1'b0; ld_req <= 1'b0; ld_wr_en <= 1'b0;
      @(posedge clk);
      rst_n <= 1'b1;
    end
  endtask

  reg [31:0] prog [0:63];
  integer    plen;

  task padd(input [31:0] w);
    begin
      prog[plen] = w;
      plen = plen + 1;
    end
  endtask

  task load_prog;
    integer i;
    begin
      for (i = 0; i < plen; i = i + 1) host_write(i * 4, prog[i], 4'hF);
    end
  endtask

  task wait_halt;
    integer n;
    begin
      n = 0;
      while (halt !== 1'b1 && n < RUN_LIMIT) begin
        @(posedge clk);
        n = n + 1;
      end
      repeat (10) @(posedge clk);
    end
  endtask

  // common instruction words
  localparam [31:0] I_LUI_X1_MMIO = 32'h200000B7;  // lui  x1, 0x20000
  localparam [31:0] I_NOP         = 32'h00000013;
  localparam [31:0] I_EBREAK      = 32'h00100073;
  localparam [31:0] I_ADDI_X3_2   = 32'h00200193;  // addi x3, x0, 2
  localparam [31:0] I_SW_STS      = 32'h0030A223;  // sw   x3, 4(x1)   sts.done = 1
  localparam [31:0] I_JAL_SELF    = 32'h0000006F;  // jal  x0, 0

  task prog_tail_done;  // mark sts.done and halt
    begin
      padd(I_ADDI_X3_2);
      padd(I_SW_STS);
      padd(I_NOP);
      padd(I_NOP);
      padd(I_EBREAK);
    end
  endtask

  reg [31:0] rd;
  reg [31:0] rdA;
  reg [31:0] rdB;
  integer    k;
  reg [7:0]  uart_byte;
  reg        uart_start;
  reg        uart_stop;
  reg        uart_idle_ok;

  initial begin
    total = 0; failed = 0; bfail = 0; bmsg = ""; cyc = 0; ld_viol = 0; plen = 0;
    rst_n = 1'b0; start_req = 1'b0; ld_en = 1'b1; ld_req = 1'b0; ld_wr_en = 1'b0;
    ld_addr = 32'h0; ld_byte_en = 4'h0; ld_wr_data = 32'h0;

    // ================= S1: reset values =================
    repeat (6) @(posedge clk);
    chk32("o_halt",        {31'b0, halt},        32'h0);
    chk32("o_err_illegal", {31'b0, err_illegal}, 32'h0);
    chk32("o_sts_done",    {31'b0, sts_done},    32'h0);
    chk32("o_result_label", {28'b0, result_label}, 32'h0);
    chk32("o_uart_tx",     {31'b0, uart_tx},     32'h1);
    bend("S1");

    // ================= S2: host port, DMEM / IMEM / miss =================
    host_write(32'h10000020, 32'hA5A51234, 4'hF);
    host_write(32'h10000024, 32'h11111111, 4'hF);
    host_write(32'h10000030, 32'h22222222, 4'hF);
    host_write(32'h10000020, 32'hFFFFFFFF, 4'b0100);   // only byte 2 changes
    host_read(32'h10000020, rd);
    chk32("dmem byte-masked write", rd, 32'hA5FF1234);
    // back-to-back reads every cycle
    @(posedge clk);
    ld_req <= 1'b1; ld_wr_en <= 1'b0; ld_addr <= 32'h10000020;
    @(posedge clk);
    ld_addr <= 32'h10000024;
    @(posedge clk);
    rdA = ld_rd_data; ld_req <= 1'b0;
    @(posedge clk);
    rdB = ld_rd_data;
    chk32("b2b read A", rdA, 32'hA5FF1234);
    chk32("b2b read B", rdB, 32'h11111111);
    host_read(32'h10000030, rd);
    chk32("dmem other row", rd, 32'h22222222);
    // IMEM is write-only for the host: read returns 0
    host_write(32'h00000000, 32'h12345678, 4'hF);
    host_read(32'h00000000, rd);
    chk32("imem read", rd, 32'h0);
    // MMIO and unmapped reads return 0, unmapped write changes nothing
    host_read(32'h20000000, rd);
    chk32("mmio read", rd, 32'h0);
    host_read(32'h30000000, rd);
    chk32("unmapped read", rd, 32'h0);
    host_write(32'h50000020, 32'hDEADBEEF, 4'hF);
    host_write(32'h20000020, 32'hDEADBEEF, 4'hF);
    host_read(32'h10000020, rd);
    chk32("dmem after miss write", rd, 32'hA5FF1234);
    bend("S2");

    // ================= S3: scalar + MMIO + load-use, ebreak =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00700113);   // addi x2, x0, 7
    padd(32'h0020A423);   // sw   x2, 8(x1)   result.label = 7
    padd(32'h0080A203);   // lw   x4, 8(x1)
    padd(32'h00120213);   // addi x4, x4, 1   (load-use)
    padd(32'h0040A423);   // sw   x4, 8(x1)   result.label = 8
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h8);
    chk32("o_sts_done",     {31'b0, sts_done},     32'h1);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S3");

    // ================= S5: reset clears outputs, keeps DMEM =================
    reset_assert;
    chk32("o_halt",         {31'b0, halt},         32'h0);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    chk32("o_sts_done",     {31'b0, sts_done},     32'h0);
    chk32("o_result_label", {28'b0, result_label}, 32'h0);
    chk32("o_uart_tx",      {31'b0, uart_tx},      32'h1);
    host_read(32'h10000020, rd);
    chk32("dmem kept in reset", rd, 32'hA5FF1234);
    bend("S5");

    // ================= S4: mul + taken branch =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00300293);   // addi x5, x0, 3
    padd(32'h02528233);   // mul  x4, x5, x5  = 9
    padd(32'h00000463);   // beq  x0, x0, +8  (taken)
    padd(32'h00500213);   // addi x4, x0, 5   (skipped)
    padd(32'h0040A423);   // sw   x4, 8(x1)
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h9);
    chk32("o_sts_done",     {31'b0, sts_done},     32'h1);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S4");

    // ================= S6: illegal instruction (div) =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00300293);   // addi x5, x0, 3
    padd(32'h0252C233);   // div  x4, x5, x5  (illegal)
    padd(32'h00500113);   // addi x2, x0, 5
    padd(32'h0020A423);   // sw   x2, 8(x1)   must not execute
    padd(I_NOP);
    padd(I_NOP);
    padd(I_EBREAK);
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h1);
    chk32("o_result_label", {28'b0, result_label}, 32'h0);
    bend("S6");

    // ================= S7: sb to MMIO -> PSLVERR -> sts.err, no halt =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00008023);   // sb   x0, 0(x1)   partial write -> PSLVERR
    padd(32'h0040A303);   // lw   x6, 4(x1)   sts
    padd(32'h00235313);   // srli x6, x6, 2
    padd(32'h00137313);   // andi x6, x6, 1   sts.err
    padd(32'h00530313);   // addi x6, x6, 5
    padd(32'h0060A423);   // sw   x6, 8(x1)   label = 6 if sts.err set
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h6);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S7");

    // ================= S8: UART 8N1 frame =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00800113);   // addi x2, x0, 8
    padd(32'h0020AA23);   // sw   x2, 0x14(x1)  uart_cfg.baud_div = 8
    padd(32'h1A300193);   // addi x3, x0, 0x1A3
    padd(32'h0030A823);   // sw   x3, 0x10(x1)  uart_tx.data = 0xA3, send = 1
    padd(I_JAL_SELF);
    reset_assert;
    load_prog;
    reset_release;
    uart_idle_ok = 1'b1;
    k = 0;
    while (uart_tx !== 1'b0 && k < RUN_LIMIT) begin
      @(posedge clk);
      k = k + 1;
    end
    chk32("start bit seen", (k < RUN_LIMIT) ? 32'h1 : 32'h0, 32'h1);
    repeat (4) @(posedge clk);
    uart_start = uart_tx;
    uart_byte  = 8'h00;
    for (k = 0; k < 8; k = k + 1) begin
      repeat (8) @(posedge clk);
      uart_byte[k] = uart_tx;
    end
    repeat (8) @(posedge clk);
    uart_stop = uart_tx;
    chk32("start bit", {31'b0, uart_start}, 32'h0);
    chk32("data byte", {24'b0, uart_byte}, 32'hA3);
    chk32("stop bit", {31'b0, uart_stop}, 32'h1);
    bend("S8");

    // ================= S9: VPU: vsetivli, vmv, vle32, vse32 =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h10000437);   // lui  x8, 0x10000
    padd(32'h01040513);   // addi x10, x8, 16
    padd(32'hC104F257);   // vsetivli x4, 9, e32, m1  -> vl = 4
    padd(32'h00300293);   // addi x5, x0, 3
    padd(32'h5E02C0D7);   // vmv.v.x v1, x5
    padd(32'h42102357);   // vmv.x.s x6, v1           = 3
    padd(32'h02046107);   // vle32.v v2, (x8)
    padd(32'h422024D7);   // vmv.x.s x9, v2           = DMEM[0x10000000] = 2
    padd(32'h020560A7);   // vse32.v v1, (x10)        row at 0x10000010 = 3,3,3,3
    padd(32'h006203B3);   // add  x7, x4, x6          = 4 + 3
    padd(32'h009383B3);   // add  x7, x7, x9          = 7 + 2
    padd(32'h0070A423);   // sw   x7, 8(x1)           label = 9
    prog_tail_done;
    reset_assert;
    host_write(32'h10000000, 32'h00000002, 4'hF);
    host_write(32'h10000004, 32'h00000007, 4'hF);
    host_write(32'h10000008, 32'h00000007, 4'hF);
    host_write(32'h1000000C, 32'h00000007, 4'hF);
    host_write(32'h10000010, 32'hFFFFFFFF, 4'hF);
    host_write(32'h10000014, 32'hFFFFFFFF, 4'hF);
    host_write(32'h10000018, 32'hFFFFFFFF, 4'hF);
    host_write(32'h1000001C, 32'hFFFFFFFF, 4'hF);
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h9);
    chk32("o_sts_done",     {31'b0, sts_done},     32'h1);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    reset_assert;
    host_read(32'h10000010, rd); chk32("vse elem0", rd, 32'h3);
    host_read(32'h10000014, rd); chk32("vse elem1", rd, 32'h3);
    host_read(32'h10000018, rd); chk32("vse elem2", rd, 32'h3);
    host_read(32'h1000001C, rd); chk32("vse elem3", rd, 32'h3);
    bend("S9");

    // ================= S11: illegal instruction in a taken-branch shadow does not halt =========
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00000663);   // beq  x0, x0, +12 (taken, skips the next two words)
    padd(32'h0252C233);   // div  x4, x5, x5  (illegal, wrong path)
    padd(I_EBREAK);       // wrong path
    padd(32'h0040A303);   // lw   x6, 4(x1)   sts
    padd(32'h00437313);   // andi x6, x6, 4   sts.err
    padd(32'h00530313);   // addi x6, x6, 5
    padd(32'h0060A423);   // sw   x6, 8(x1)   label = 5 if sts.err clear
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h5);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S11");

    // ================= S12: unimplemented MMIO offset reads 0, write ignored, no halt ==========
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'h00700113);   // addi x2, x0, 7
    padd(32'h0420A023);   // sw   x2, 0x40(x1)  unimplemented offset
    padd(32'h0400A203);   // lw   x4, 0x40(x1)  reads 0
    padd(32'h00320213);   // addi x4, x4, 3
    padd(32'h0040A423);   // sw   x4, 8(x1)     label = 3
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h3);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S12");

    // ================= S13: vector command takes >= 5 cycles (cycles.cnt >= 5) =================
    plen = 0;
    padd(I_LUI_X1_MMIO);
    padd(32'hC104F257);   // vsetivli x4, 9, e32, m1
    padd(32'h00C0A303);   // lw   x6, 0xC(x1)   cycles.cnt
    padd(32'h00533313);   // sltiu x6, x6, 5    1 if cnt < 5
    padd(32'h00134313);   // xori x6, x6, 1     1 if cnt >= 5
    padd(32'h0060A423);   // sw   x6, 8(x1)     label = 1
    prog_tail_done;
    reset_assert;
    load_prog;
    reset_release;
    wait_halt;
    chk32("o_result_label", {28'b0, result_label}, 32'h1);
    chk32("o_halt",         {31'b0, halt},         32'h1);
    chk32("o_err_illegal",  {31'b0, err_illegal},  32'h0);
    bend("S13");

    // ================= S10: i_ld_en never 1 while reset released =================
    chk32("i_ld_en violations", ld_viol, 32'h0);
    bend("S10");

    $display("SMOKE_SUMMARY total=%0d failed=%0d", total, failed);
    $finish;
  end

endmodule
