// tb_top.sv -- top-level testbench of m_soc_top (rv32_vpu_mnist), pure SystemVerilog-2012, no UVM.
//
// HOW TO WRITE A TC (read this first)
// -----------------------------------
// * Timing convention: every drive happens 1 ns AFTER a rising clock edge (tick() returns there).
//   Values read right after tick() are the values of the cycle that started at that edge.
//   A host read driven before tick() has its data on o_ld_rd_data right after that tick() (1-cycle latency).
// * The DUT has no testbench-visible CPU register/memory port. The TB works by PROGRAMS:
//     1. build a program with emit()/rv_*() encoders (prog_reset(), emit(rv_addi(...)), ...),
//     2. run_prog(timeout)  : host-loads the program in reset, releases reset, waits for o_halt and then drains
//                             the halted core (older stores reach DMEM),
//     3. read results back through the host port (dmem_rd / res_rd). Reset keeps IMEM/DMEM contents.
//   Programs end with rv_ebreak() (o_halt=1, o_err_illegal=0); falling off the end hits an all-zero word
//   (illegal instruction, o_err_illegal=1), because host_load_prog() pads 8 zero words after the program.
// * Result convention: x31 is the result base pointer when emit_res_init() is used; emit_sw_res(reg, slot)
//   stores to TB_RES_BASE + 4*slot (slot 0..511); read with res_rd(slot, data).
// * CSR state (sts.err, ctrl.start, ...) is lost when the core is put in reset to read DMEM, so a program must
//   copy the CSR values it wants to check into the result area with lw/sw before it halts. Likewise o_halt,
//   o_err_illegal and tb_sts_err_events must be checked BEFORE the first host access (or use snap_*).
// * Monitors (always on) count protocol violations; call mon_check_all() at the end of a TC.
//   All monitor counters are cleared automatically at the first clock edge of each new TC.
// * Hierarchical probes are READ-ONLY and use the instance names of the macros below (override with +define+
//   or edit once here if the RTL uses different instance names).
`ifndef TB_P_CPU
 `define TB_P_CPU dut.u_cpu_top
`endif
`ifndef TB_P_VPU
 `define TB_P_VPU dut.u_vpu_top
`endif
`ifndef TB_P_APB
 `define TB_P_APB dut.u_apb_master
`endif

module tb_top;

  `include "tb_common.svh"

  // ---------------------------------------------------------------------------------------------
  // Parameters of the DUT (final_config.json) and derived constants
  // ---------------------------------------------------------------------------------------------
  localparam logic [31:0] PARA_VLEN       = 32'd128;
  localparam logic [31:0] PARA_LANE_COUNT = 32'd4;
  localparam int VLEN_BYTES  = 16;          // PARA_VLEN/8 : bytes per vector register / DMEM row
  localparam int ROW_LB      = 4;           // log2(VLEN_BYTES)
  localparam int VLMAX_E8    = 16;          // VLMAX at SEW=8,  LMUL=1
  localparam int VLMAX_E16   = 8;
  localparam int VLMAX_E32   = 4;
  localparam int CLK_PERIOD  = 10;          // ns (functional sim; 200 MHz target is a goal only)

  // Memory map (spec 3, REQ-015)
  localparam logic [31:0] IMEM_BASE   = 32'h0000_0000;   // 32 KB
  localparam logic [31:0] IMEM_LAST   = 32'h0000_7FFC;
  localparam logic [31:0] DMEM_BASE   = 32'h1000_0000;   // 256 KB
  localparam logic [31:0] DMEM_LAST   = 32'h1003_FFFC;
  localparam logic [31:0] MMIO_BASE   = 32'h2000_0000;   // 4 KB
  // Interim CSR map (ASM-014)
  localparam logic [31:0] CSR_CTRL     = 32'h2000_0000;  // bit0 = ctrl.start
  localparam logic [31:0] CSR_STS      = 32'h2000_0004;  // bit0 busy, bit1 done, bit2 err (w1c)
  localparam logic [31:0] CSR_RESULT   = 32'h2000_0008;  // [3:0] label
  localparam logic [31:0] CSR_CYCLES   = 32'h2000_000C;  // cycles.cnt
  localparam logic [31:0] CSR_UART_TX  = 32'h2000_0010;  // [7:0] data, bit8 send, bit9 busy
  localparam logic [31:0] CSR_UART_CFG = 32'h2000_0014;  // [15:0] baud_div, reset 0x06C8
  localparam logic [15:0] BAUD_DIV_RESET = 16'h06C8;
  // Default result area used by emit_res_init()/emit_sw_res()/res_rd()
  localparam logic [31:0] TB_RES_BASE  = 32'h1000_8000;
  // Default scratch data area for TC data (host-loaded)
  localparam logic [31:0] TB_DATA_BASE = 32'h1000_4000;

  // ---------------------------------------------------------------------------------------------
  // DUT signals
  // ---------------------------------------------------------------------------------------------
  logic        i_clk_core = 1'b0;
  logic        i_rst_n_core = 1'b0;     // asserted from time 0
  logic        i_start_req = 1'b0;
  wire         o_sts_done;
  wire  [3:0]  o_result_label;
  wire         o_uart_tx;
  wire         o_err_illegal;
  wire         o_halt;
  logic        i_ld_en = 1'b0;
  logic        i_ld_req = 1'b0;
  logic        i_ld_wr_en = 1'b0;
  logic [31:0] i_ld_addr = 32'h0;
  logic [3:0]  i_ld_byte_en = 4'h0;
  logic [31:0] i_ld_wr_data = 32'h0;
  wire  [31:0] o_ld_rd_data;

  m_soc_top #(
    .PARA_VLEN       (PARA_VLEN),
    .PARA_LANE_COUNT (PARA_LANE_COUNT)
  ) dut (
    .i_clk_core     (i_clk_core),
    .i_rst_n_core   (i_rst_n_core),
    .i_start_req    (i_start_req),
    .o_sts_done     (o_sts_done),
    .o_result_label (o_result_label),
    .o_uart_tx      (o_uart_tx),
    .o_err_illegal  (o_err_illegal),
    .o_halt         (o_halt),
    .i_ld_en        (i_ld_en),
    .i_ld_req       (i_ld_req),
    .i_ld_wr_en     (i_ld_wr_en),
    .i_ld_addr      (i_ld_addr),
    .i_ld_byte_en   (i_ld_byte_en),
    .i_ld_wr_data   (i_ld_wr_data),
    .o_ld_rd_data   (o_ld_rd_data)
  );

  // ---------------------------------------------------------------------------------------------
  // Read-only probes of spec-defined internal interfaces (Q-TP22)
  // ---------------------------------------------------------------------------------------------
  // CPU <-> VPU command interface (m_vpu_top ports)
  wire                    p_vcmd_valid   = `TB_P_VPU.i_cmd_valid;
  wire [31:0]             p_vcmd_instr   = `TB_P_VPU.i_cmd_instr;
  wire [31:0]             p_vcmd_rs1     = `TB_P_VPU.i_cmd_rs1_data;
  wire [31:0]             p_vcmd_rs2     = `TB_P_VPU.i_cmd_rs2_data;
  wire                    p_vcmd_ready   = `TB_P_VPU.o_cmd_ready;
  wire                    p_vresp_done   = `TB_P_VPU.o_resp_done;
  wire                    p_vresp_rdv    = `TB_P_VPU.o_resp_rd_valid;
  wire [31:0]             p_vresp_rdd    = `TB_P_VPU.o_resp_rd_data;
  // VPU memory interface
  wire                    p_vmem_req     = `TB_P_VPU.o_mem_req;
  wire                    p_vmem_wr_en   = `TB_P_VPU.o_mem_wr_en;
  wire [31:0]             p_vmem_addr    = `TB_P_VPU.o_mem_addr;
  wire [VLEN_BYTES-1:0]   p_vmem_be      = `TB_P_VPU.o_mem_byte_en;
  wire [127:0]            p_vmem_wdata   = `TB_P_VPU.o_mem_wr_data;
  wire                    p_vmem_ack     = `TB_P_VPU.i_mem_ack;
  // cycles.cnt source (m_vpu_perf via m_vpu_top)
  wire [31:0]             p_vcyc_cnt     = `TB_P_VPU.o_cycles_cnt;
  // CPU data bus / fetch
  wire                    p_cpu_dmem_req = `TB_P_CPU.o_dmem_req;
  wire                    p_cpu_dmem_wr  = `TB_P_CPU.o_dmem_wr_en;
  wire [31:0]             p_cpu_dmem_adr = `TB_P_CPU.o_dmem_addr;
  wire                    p_cpu_dmem_ack = `TB_P_CPU.i_dmem_ack;
  wire [31:0]             p_imem_addr    = `TB_P_CPU.o_imem_addr;
  // APB master ports
  wire                    p_apb_psel     = `TB_P_APB.o_apb_psel;
  wire                    p_apb_penable  = `TB_P_APB.o_apb_penable;
  wire                    p_apb_pwrite   = `TB_P_APB.o_apb_pwrite;
  wire [15:0]             p_apb_paddr    = `TB_P_APB.o_apb_paddr;
  wire [31:0]             p_apb_pwdata   = `TB_P_APB.o_apb_pwdata;
  wire [3:0]              p_apb_pstrb    = `TB_P_APB.o_apb_pstrb;
  wire [2:0]              p_apb_pprot    = `TB_P_APB.o_apb_pprot;
  wire [31:0]             p_apb_prdata   = `TB_P_APB.i_apb_prdata;
  wire                    p_apb_pready   = `TB_P_APB.i_apb_pready;
  wire                    p_apb_pslverr  = `TB_P_APB.i_apb_pslverr;
  wire                    p_sts_err_set  = `TB_P_APB.o_sts_err_set;

  // ---------------------------------------------------------------------------------------------
  // Clock, cycle counter, global watchdog
  // ---------------------------------------------------------------------------------------------
  always #(CLK_PERIOD/2) i_clk_core = ~i_clk_core;

  longint unsigned tb_cycle = 0;          // number of rising edges seen so far
  time             tb_last_posedge_t = 0;
  longint unsigned tb_max_cycles = 500_000_000;
  int              tb_seed = 1;

  // ---------------------------------------------------------------------------------------------
  // Basic helpers
  // ---------------------------------------------------------------------------------------------
  // tick(): wait for one rising edge of i_clk_core, then 1 ns. All TB drives happen right after tick().
  task automatic tick();
    @(posedge i_clk_core);
    #1;
  endtask

  // wait_cycles(n): n x tick().
  task automatic wait_cycles(input int n);
    repeat (n) tick();
  endtask

  // tb_rand32(): next 32-bit pseudo random value (seed logged at start, override with +SEED=<n>).
  function automatic logic [31:0] tb_rand32();
    return $urandom();
  endfunction

  // sx(v, bits): sign-extend the low 'bits' bits of v to a 64-bit signed value.
  function automatic longint sx(input logic [31:0] v, input int bits);
    longint t;
    t = longint'({32'h0, v});
    t = (t <<< (64 - bits)) >>> (64 - bits);
    return t;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Reset control
  // ---------------------------------------------------------------------------------------------
  int              tb_sts_err_events = 0; // sts.err hardware-set events since reset: o_err_illegal rising + o_sts_err_set
                                          // pulses (ever-set indicator; firmware w1c clears are NOT tracked)
  longint unsigned tb_rel_cycle = 0;      // value of tb_cycle when reset was last released
  bit              tb_host_mode = 0;      // 1 while reset is held for host access (host_begin .. host_end)
  bit              tb_mon_run   = 0;      // set after the first reset release

  // rst_assert(): drive i_rst_n_core=0 NOW (asynchronous w.r.t. the clock), idle all host/start inputs.
  task automatic rst_assert();
    i_rst_n_core = 1'b0;
    i_start_req  = 1'b0;
    i_ld_en      = 1'b0;
    i_ld_req     = 1'b0;
    i_ld_wr_en   = 1'b0;
    tb_sts_err_events = 0;
  endtask

  // rst_release(): wait for the next edge (+1 ns), drive i_ld_en=0 and i_rst_n_core=1 together
  //   (REQ-023: i_ld_en is 0 no later than release). Sets tb_rel_cycle.
  task automatic rst_release();
    tick();
    i_ld_en      = 1'b0;
    i_ld_req     = 1'b0;
    i_ld_wr_en   = 1'b0;
    i_rst_n_core = 1'b1;
    tb_rel_cycle = tb_cycle;
    tb_host_mode = 0;
    tb_mon_run   = 1;
  endtask

  // reset_dut(n=4): from any state: assert reset, hold n cycles, release. Memories keep their contents.
  task automatic reset_dut(input int n = 4);
    rst_assert();
    wait_cycles(n);
    rst_release();
  endtask

  // rst_assert_offedge(): assert reset a quarter period after a clock edge (async, away from the edge).
  task automatic rst_assert_offedge();
    @(posedge i_clk_core);
    #(CLK_PERIOD/4);
    rst_assert();
  endtask

  // rst_release_offedge(): release reset a quarter period after a clock edge (not aligned to the edge).
  task automatic rst_release_offedge();
    @(posedge i_clk_core);
    #(CLK_PERIOD/4);
    i_ld_en      = 1'b0;
    i_rst_n_core = 1'b1;
    tb_rel_cycle = tb_cycle;
    tb_host_mode = 0;
    tb_mon_run   = 1;
  endtask

  // ---------------------------------------------------------------------------------------------
  // Status snapshot taken when the core is put in reset for host access (CSR state is lost afterwards)
  // ---------------------------------------------------------------------------------------------
  logic        snap_halt, snap_err_illegal, snap_done;
  logic [3:0]  snap_label;
  logic [31:0] snap_cycles_cnt;       // m_vpu_perf count (cycles.cnt source) at snapshot time
  int          snap_sts_err_events;   // sts.err hardware set events seen (illegal instr + o_sts_err_set)

  // snap_status(): copy the current output/probe state into snap_*.
  task automatic snap_status();
    snap_halt           = o_halt;
    snap_err_illegal    = o_err_illegal;
    snap_done           = o_sts_done;
    snap_label          = o_result_label;
    snap_cycles_cnt     = p_vcyc_cnt;
    snap_sts_err_events = tb_sts_err_events;
  endtask

  // ---------------------------------------------------------------------------------------------
  // Host load port (valid only while i_rst_n_core=0 and i_ld_en=1)
  // ---------------------------------------------------------------------------------------------
  // host_begin(): snapshot status, assert reset, enable host port. No-op if already in host mode.
  task automatic host_begin();
    if (!tb_host_mode) begin
      snap_status();
      rst_assert();
      wait_cycles(3);
      i_ld_en      = 1'b1;
      tb_host_mode = 1;
      tick();
    end
  endtask

  // host_end(): drop i_ld_en and release reset (core starts from PC 0).
  task automatic host_end();
    i_ld_req   = 1'b0;
    i_ld_wr_en = 1'b0;
    rst_release();
  endtask

  // host_cycle(req, wr, addr, be, wdata): drive one host cycle (generic, for back-to-back streams) and
  //   tick(). The request is sampled at the edge inside tick(), so o_ld_rd_data after return holds the read
  //   data of the request driven by THIS call (1-cycle latency); back-to-back calls give one result per call.
  //   Requires i_ld_en=1 (host mode).
  task automatic host_cycle(input bit req, input bit wr, input logic [31:0] addr,
                            input logic [3:0] be, input logic [31:0] wdata);
    i_ld_req     = req;
    i_ld_wr_en   = wr;
    i_ld_addr    = addr;
    i_ld_byte_en = be;
    i_ld_wr_data = wdata;
    tick();
  endtask

  // host_idle(): one idle host cycle (i_ld_req=0).
  task automatic host_idle();
    host_cycle(1'b0, 1'b0, 32'h0, 4'h0, 32'h0);
  endtask

  // host_wr32(addr, data, be=4'hF): one-cycle host write (CPU memory map address). Enters host mode if needed.
  task automatic host_wr32(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] be = 4'hF);
    host_begin();
    host_cycle(1'b1, 1'b1, addr, be, data);
    host_idle();
  endtask

  // host_rd32(addr, data): one-cycle host read, data = o_ld_rd_data 1 cycle after the request.
  task automatic host_rd32(input logic [31:0] addr, output logic [31:0] data);
    host_begin();
    host_cycle(1'b1, 1'b0, addr, 4'h0, 32'h0);   // request sampled at the edge inside tick()
    data = o_ld_rd_data;                         // valid right after that edge
    host_idle();
  endtask

  // dmem_wr(addr, data, be=4'hF) / dmem_rd(addr, data): host access to DMEM (addr = 0x1000_0000 + offset).
  task automatic dmem_wr(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] be = 4'hF);
    host_wr32(addr, data, be);
  endtask
  task automatic dmem_rd(input logic [31:0] addr, output logic [31:0] data);
    host_rd32(addr, data);
  endtask

  // imem_wr(addr, data): host write of one IMEM word (addr = byte address, 0x0000_0000..0x0000_7FFC).
  task automatic imem_wr(input logic [31:0] addr, input logic [31:0] data);
    host_wr32(addr, data, 4'hF);
  endtask

  // res_rd(slot, data): read result word 'slot' (TB_RES_BASE + 4*slot) through the host port.
  task automatic res_rd(input int slot, output logic [31:0] data);
    host_rd32(TB_RES_BASE + 32'(slot * 4), data);
  endtask

  // dmem_fill(base_addr, nwords, value): host-write value to nwords consecutive words.
  task automatic dmem_fill(input logic [31:0] base_addr, input int nwords, input logic [31:0] value);
    host_begin();
    for (int i = 0; i < nwords; i++) host_cycle(1'b1, 1'b1, base_addr + 32'(i * 4), 4'hF, value);
    host_idle();
  endtask

  // Bulk buffer for $readmemh vector files / TC data (word array). tb_readmem(path) loads a hex file into it.
  logic [31:0] tb_buf [0:65535];
  // tb_readmem(path, ok): $readmemh path into tb_buf (ok=0 if the file cannot be opened).
  task automatic tb_readmem(input string path, output bit ok);
    int fd;
    fd = $fopen(path, "r");
    if (fd == 0) begin
      ok = 0;
    end else begin
      $fclose(fd);
      for (int i = 0; i < 65536; i++) tb_buf[i] = 32'h0;
      $readmemh(path, tb_buf);
      ok = 1;
    end
  endtask

  // host_load_buf(base_addr, nwords, first=0): host-write tb_buf[first .. first+nwords-1] to consecutive
  //   words starting at base_addr (IMEM or DMEM byte address), one word per cycle.
  task automatic host_load_buf(input logic [31:0] base_addr, input int nwords, input int first = 0);
    host_begin();
    for (int i = 0; i < nwords; i++) host_cycle(1'b1, 1'b1, base_addr + 32'(i * 4), 4'hF, tb_buf[first + i]);
    host_idle();
  endtask

  // ---------------------------------------------------------------------------------------------
  // Instruction encoders (RV32I + Zmmul + SYSTEM + Zve32x subset). All return the 32-bit instruction word.
  // Register arguments are 0..31. Immediate/offset arguments are plain ints (byte offsets for branches/jal).
  // ---------------------------------------------------------------------------------------------
  function automatic logic [31:0] enc_r(input logic [6:0] f7, input logic [4:0] rs2, input logic [4:0] rs1,
                                        input logic [2:0] f3, input logic [4:0] rd, input logic [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic logic [31:0] enc_i(input int imm, input logic [4:0] rs1, input logic [2:0] f3,
                                        input logic [4:0] rd, input logic [6:0] op);
    logic [31:0] w;
    w = imm;
    return {w[11:0], rs1, f3, rd, op};
  endfunction
  function automatic logic [31:0] enc_s(input int imm, input logic [4:0] rs2, input logic [4:0] rs1,
                                        input logic [2:0] f3, input logic [6:0] op);
    logic [31:0] w;
    w = imm;
    return {w[11:5], rs2, rs1, f3, w[4:0], op};
  endfunction
  function automatic logic [31:0] enc_b(input int off, input logic [4:0] rs2, input logic [4:0] rs1,
                                        input logic [2:0] f3);
    logic [31:0] w;
    w = off;
    return {w[12], w[10:5], rs2, rs1, f3, w[4:1], w[11], 7'h63};
  endfunction
  function automatic logic [31:0] enc_u(input logic [19:0] imm20, input logic [4:0] rd, input logic [6:0] op);
    return {imm20, rd, op};
  endfunction
  function automatic logic [31:0] enc_j(input int off, input logic [4:0] rd);
    logic [31:0] w;
    w = off;
    return {w[20], w[10:1], w[11], w[19:12], rd, 7'h6F};
  endfunction

  // --- OP-IMM
  function automatic logic [31:0] rv_addi (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b000, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_slti (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b010, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_sltiu(input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b011, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_xori (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b100, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_ori  (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b110, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_andi (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b111, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_slli (input logic [4:0] rd, input logic [4:0] rs1, input int sh);
    return enc_r(7'h00, sh[4:0], rs1, 3'b001, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_srli (input logic [4:0] rd, input logic [4:0] rs1, input int sh);
    return enc_r(7'h00, sh[4:0], rs1, 3'b101, rd, 7'h13);
  endfunction
  function automatic logic [31:0] rv_srai (input logic [4:0] rd, input logic [4:0] rs1, input int sh);
    return enc_r(7'h20, sh[4:0], rs1, 3'b101, rd, 7'h13);
  endfunction
  // --- OP (register-register), rv_<op>(rd, rs1, rs2)
  function automatic logic [31:0] rv_add (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b000, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_sub (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h20, rs2, rs1, 3'b000, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_sll (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b001, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_slt (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b010, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_sltu(input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b011, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_xor (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b100, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_srl (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b101, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_sra (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h20, rs2, rs1, 3'b101, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_or  (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b110, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_and (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h00, rs2, rs1, 3'b111, rd, 7'h33);
  endfunction
  // --- M extension opcodes: only rv_mul is legal (Zmmul); the others must be illegal instructions
  function automatic logic [31:0] rv_mul   (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b000, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_mulh  (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b001, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_mulhsu(input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b010, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_mulhu (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b011, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_div   (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b100, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_divu  (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b101, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_rem   (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b110, rd, 7'h33);
  endfunction
  function automatic logic [31:0] rv_remu  (input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
    return enc_r(7'h01, rs2, rs1, 3'b111, rd, 7'h33);
  endfunction
  // --- upper immediates and jumps. imm20 = the 20-bit field (value<<12 goes to rd)
  function automatic logic [31:0] rv_lui  (input logic [4:0] rd, input logic [19:0] imm20);
    return enc_u(imm20, rd, 7'h37);
  endfunction
  function automatic logic [31:0] rv_auipc(input logic [4:0] rd, input logic [19:0] imm20);
    return enc_u(imm20, rd, 7'h17);
  endfunction
  function automatic logic [31:0] rv_jal  (input logic [4:0] rd, input int off);
    return enc_j(off, rd);
  endfunction
  function automatic logic [31:0] rv_jalr (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b000, rd, 7'h67);
  endfunction
  // --- branches: rv_b<cc>(rs1, rs2, byte_offset_from_this_instruction)
  function automatic logic [31:0] rv_beq (input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b000);
  endfunction
  function automatic logic [31:0] rv_bne (input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b001);
  endfunction
  function automatic logic [31:0] rv_blt (input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b100);
  endfunction
  function automatic logic [31:0] rv_bge (input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b101);
  endfunction
  function automatic logic [31:0] rv_bltu(input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b110);
  endfunction
  function automatic logic [31:0] rv_bgeu(input logic [4:0] rs1, input logic [4:0] rs2, input int off);
    return enc_b(off, rs2, rs1, 3'b111);
  endfunction
  // --- loads: rv_l*(rd, rs1, imm) ; stores: rv_s*(rs2_data, rs1_base, imm)
  function automatic logic [31:0] rv_lb (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b000, rd, 7'h03);
  endfunction
  function automatic logic [31:0] rv_lh (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b001, rd, 7'h03);
  endfunction
  function automatic logic [31:0] rv_lw (input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b010, rd, 7'h03);
  endfunction
  function automatic logic [31:0] rv_lbu(input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b100, rd, 7'h03);
  endfunction
  function automatic logic [31:0] rv_lhu(input logic [4:0] rd, input logic [4:0] rs1, input int imm);
    return enc_i(imm, rs1, 3'b101, rd, 7'h03);
  endfunction
  function automatic logic [31:0] rv_sb (input logic [4:0] rs2, input logic [4:0] rs1, input int imm);
    return enc_s(imm, rs2, rs1, 3'b000, 7'h23);
  endfunction
  function automatic logic [31:0] rv_sh (input logic [4:0] rs2, input logic [4:0] rs1, input int imm);
    return enc_s(imm, rs2, rs1, 3'b001, 7'h23);
  endfunction
  function automatic logic [31:0] rv_sw (input logic [4:0] rs2, input logic [4:0] rs1, input int imm);
    return enc_s(imm, rs2, rs1, 3'b010, 7'h23);
  endfunction
  // --- misc / system
  function automatic logic [31:0] rv_nop();    return 32'h0000_0013; endfunction  // addi x0,x0,0
  function automatic logic [31:0] rv_ebreak(); return 32'h0010_0073; endfunction  // halt, o_err_illegal=0
  function automatic logic [31:0] rv_ecall();  return 32'h0000_0073; endfunction  // illegal
  function automatic logic [31:0] rv_fence();  return 32'h0FF0_000F; endfunction  // NOP
  function automatic logic [31:0] rv_mret();   return 32'h3020_0073; endfunction  // illegal
  function automatic logic [31:0] rv_wfi();    return 32'h1050_0073; endfunction  // illegal
  // rv_csr(f3, rd, csr12, rs1_or_zimm): f3 1=csrrw 2=csrrs 3=csrrc 5=csrrwi 6=csrrsi 7=csrrci (all illegal)
  function automatic logic [31:0] rv_csr(input logic [2:0] f3, input logic [4:0] rd, input logic [11:0] csr,
                                         input logic [4:0] rs1);
    return {csr, rs1, f3, rd, 7'h73};
  endfunction
  // rv_illegal_zero(): all-zero word (illegal); rv_illegal_ones(): all-ones word (illegal)
  function automatic logic [31:0] rv_illegal_zero(); return 32'h0000_0000; endfunction
  function automatic logic [31:0] rv_illegal_ones(); return 32'hFFFF_FFFF; endfunction

  // --- Zve32x subset (OP-V = 0x57). Vector register args are 0..31, scalar rs1/rd are x-registers.
  // enc_opv(funct6, vm, vs2, vs1_or_rs1_or_imm5, funct3, vd): generic OP-V encoder (vm=1 unmasked).
  //   funct3: 000 OPIVV, 001 OPFVV, 010 OPMVV, 011 OPIVI, 100 OPIVX, 101 OPFVF, 110 OPMVX, 111 OPCFG.
  function automatic logic [31:0] enc_opv(input logic [5:0] f6, input logic vm, input logic [4:0] vs2,
                                          input logic [4:0] s1, input logic [2:0] f3, input logic [4:0] vd);
    return {f6, vm, vs2, s1, f3, vd, 7'h57};
  endfunction
  // vsew_code(sew): 8->0, 16->1, 32->2, 64->3 (3 = illegal SEW=64 for this design)
  function automatic logic [2:0] vsew_code(input int sew);
    case (sew)
      8:       return 3'd0;
      16:      return 3'd1;
      32:      return 3'd2;
      default: return 3'd3;
    endcase
  endfunction
  // vtype_zimm(sew, lmul_code, ta, ma): 11-bit zimm of vsetvli (vlmul code 0=LMUL1, 1=2, 2=4, 3=8, 5..7 fractional)
  function automatic logic [10:0] vtype_zimm(input int sew, input int lmul_code = 0, input bit ta = 0,
                                             input bit ma = 0);
    return {3'b000, ma, ta, vsew_code(sew), lmul_code[2:0]};
  endfunction
  // vsetvli rd, rs1, zimm   (rd=x0 & rs1=x0 -> keep vl) ; vsetivli rd, uimm5(AVL), zimm10
  function automatic logic [31:0] rv_vsetvli(input logic [4:0] rd, input logic [4:0] rs1, input logic [10:0] zimm);
    return {1'b0, zimm, rs1, 3'b111, rd, 7'h57};
  endfunction
  function automatic logic [31:0] rv_vsetivli(input logic [4:0] rd, input logic [4:0] uimm5, input logic [9:0] zimm);
    return {2'b11, zimm, uimm5, 3'b111, rd, 7'h57};
  endfunction
  // unit-stride loads/stores: rv_vle8(vd, rs1) etc. (vm=1). width: 8-bit 000, 16-bit 101, 32-bit 110.
  // rv_vmem(is_store, nf, mew, mop, vm, rs2_lumop, rs1, width, vd_vs3): generic (for illegal variants).
  function automatic logic [31:0] rv_vmem(input bit is_store, input logic [2:0] nf, input logic mew,
                                          input logic [1:0] mop, input logic vm, input logic [4:0] rs2_lumop,
                                          input logic [4:0] rs1, input logic [2:0] width, input logic [4:0] vd);
    return {nf, mew, mop, vm, rs2_lumop, rs1, width, vd, (is_store ? 7'h27 : 7'h07)};
  endfunction
  function automatic logic [31:0] rv_vle8  (input logic [4:0] vd, input logic [4:0] rs1);
    return rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b000, vd);
  endfunction
  function automatic logic [31:0] rv_vle16 (input logic [4:0] vd, input logic [4:0] rs1);   // illegal here
    return rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b101, vd);
  endfunction
  function automatic logic [31:0] rv_vle32 (input logic [4:0] vd, input logic [4:0] rs1);
    return rv_vmem(1'b0, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b110, vd);
  endfunction
  function automatic logic [31:0] rv_vse8  (input logic [4:0] vs3, input logic [4:0] rs1);
    return rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b000, vs3);
  endfunction
  function automatic logic [31:0] rv_vse16 (input logic [4:0] vs3, input logic [4:0] rs1);   // illegal here
    return rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b101, vs3);
  endfunction
  function automatic logic [31:0] rv_vse32 (input logic [4:0] vs3, input logic [4:0] rs1);
    return rv_vmem(1'b1, 3'b000, 1'b0, 2'b00, 1'b1, 5'b00000, rs1, 3'b110, vs3);
  endfunction
  // arithmetic (vm=1 unmasked by default; pass vm=0 to build an illegal masked form)
  function automatic logic [31:0] rv_vadd_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1,
                                             input logic vm = 1'b1);
    return enc_opv(6'b000000, vm, vs2, vs1, 3'b000, vd);
  endfunction
  function automatic logic [31:0] rv_vadd_vx(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] rs1,
                                             input logic vm = 1'b1);
    return enc_opv(6'b000000, vm, vs2, rs1, 3'b100, vd);
  endfunction
  function automatic logic [31:0] rv_vsra_vi(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] uimm5,
                                             input logic vm = 1'b1);
    return enc_opv(6'b101001, vm, vs2, uimm5, 3'b011, vd);
  endfunction
  function automatic logic [31:0] rv_vsra_vx(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] rs1,
                                             input logic vm = 1'b1);
    return enc_opv(6'b101001, vm, vs2, rs1, 3'b100, vd);
  endfunction
  function automatic logic [31:0] rv_vmax_vx(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] rs1,
                                             input logic vm = 1'b1);
    return enc_opv(6'b000111, vm, vs2, rs1, 3'b100, vd);
  endfunction
  function automatic logic [31:0] rv_vnclip_wi(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] uimm5,
                                               input logic vm = 1'b1);
    return enc_opv(6'b101111, vm, vs2, uimm5, 3'b011, vd);
  endfunction
  function automatic logic [31:0] rv_vnclip_wx(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] rs1,
                                               input logic vm = 1'b1);
    return enc_opv(6'b101111, vm, vs2, rs1, 3'b100, vd);
  endfunction
  function automatic logic [31:0] rv_vwmul_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1,
                                              input logic vm = 1'b1);
    return enc_opv(6'b111011, vm, vs2, vs1, 3'b010, vd);
  endfunction
  function automatic logic [31:0] rv_vwredsum_vs(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1,
                                                 input logic vm = 1'b1);
    return enc_opv(6'b110001, vm, vs2, vs1, 3'b000, vd);
  endfunction
  function automatic logic [31:0] rv_vmv_v_x(input logic [4:0] vd, input logic [4:0] rs1);
    return enc_opv(6'b010111, 1'b1, 5'd0, rs1, 3'b100, vd);
  endfunction
  function automatic logic [31:0] rv_vmv_s_x(input logic [4:0] vd, input logic [4:0] rs1);
    return enc_opv(6'b010000, 1'b1, 5'd0, rs1, 3'b110, vd);
  endfunction
  function automatic logic [31:0] rv_vmv_x_s(input logic [4:0] rd, input logic [4:0] vs2);
    return enc_opv(6'b010000, 1'b1, vs2, 5'd0, 3'b010, rd);
  endfunction
  // unsupported OP-V examples (must be illegal): vsub.vv, vand.vv, vmul.vv, vredsum.vs, vfadd.vv
  function automatic logic [31:0] rv_vsub_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1);
    return enc_opv(6'b000010, 1'b1, vs2, vs1, 3'b000, vd);
  endfunction
  function automatic logic [31:0] rv_vand_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1);
    return enc_opv(6'b001001, 1'b1, vs2, vs1, 3'b000, vd);
  endfunction
  function automatic logic [31:0] rv_vmul_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1);
    return enc_opv(6'b100101, 1'b1, vs2, vs1, 3'b010, vd);
  endfunction
  function automatic logic [31:0] rv_vredsum_vs(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1);
    return enc_opv(6'b000000, 1'b1, vs2, vs1, 3'b010, vd);
  endfunction
  function automatic logic [31:0] rv_vfadd_vv(input logic [4:0] vd, input logic [4:0] vs2, input logic [4:0] vs1);
    return enc_opv(6'b000000, 1'b1, vs2, vs1, 3'b001, vd);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Reference helpers (golden arithmetic, independent of the DUT)
  // ---------------------------------------------------------------------------------------------
  // ref_vnclip(val, shift, dst_bits): arithmetic shift right with round-to-nearest-up (vxrm=0) then saturate
  //   to the signed range of dst_bits (16 for 32->16, 8 for 16->8). val = signed source element.
  function automatic longint ref_vnclip(input longint val, input int shift, input int dst_bits);
    longint r, lo, hi, inc;
    inc = (shift > 0) ? ((val >>> (shift - 1)) & 64'sd1) : 64'sd0;
    r   = (val >>> shift) + inc;
    hi  = (64'sd1 <<< (dst_bits - 1)) - 64'sd1;
    lo  = -(64'sd1 <<< (dst_bits - 1));
    if (r > hi) r = hi;
    else if (r < lo) r = lo;
    return r;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Program builder (IMEM image in the TB, loaded through the host port)
  // ---------------------------------------------------------------------------------------------
  logic [31:0] prog_mem   [0:8191];
  bit          prog_dirty [0:8191];
  int          prog_pc = 0;          // next word index to emit (byte address = 4*prog_pc)

  // prog_reset(): forget the current program (all words clean, prog_pc=0).
  task automatic prog_reset();
    for (int i = 0; i < 8192; i++) prog_dirty[i] = 0;
    prog_pc = 0;
  endtask

  // prog_org(word_idx): continue emitting at word index word_idx (byte address 4*word_idx).
  task automatic prog_org(input int word_idx);
    prog_pc = word_idx;
  endtask

  // emit(w): place instruction/data word w at prog_pc and advance.
  task automatic emit(input logic [31:0] w);
    prog_mem[prog_pc]   = w;
    prog_dirty[prog_pc] = 1;
    prog_pc++;
  endtask

  // prog_patch(word_idx, w): overwrite an already emitted word (forward-branch fixups).
  task automatic prog_patch(input int word_idx, input logic [31:0] w);
    prog_mem[word_idx]   = w;
    prog_dirty[word_idx] = 1;
  endtask

  // prog_here(): byte address of the next instruction to be emitted (use for branch offsets).
  function automatic int prog_here();
    return prog_pc * 4;
  endfunction

  // emit_li(rd, value): load a 32-bit constant (1 or 2 instructions: addi, or lui+addi).
  task automatic emit_li(input logic [4:0] rd, input logic [31:0] val);
    int          lo;
    logic [31:0] hi;
    lo = int'($signed(val[11:0]));
    hi = val - 32'(lo);
    if (hi == 32'h0) begin
      emit(rv_addi(rd, 5'd0, lo));
    end else begin
      emit(rv_lui(rd, hi[31:12]));
      if (lo != 0) emit(rv_addi(rd, rd, lo));
    end
  endtask

  // emit_res_init(): li x31, TB_RES_BASE (result base pointer; keep x31 untouched afterwards).
  task automatic emit_res_init();
    emit_li(5'd31, TB_RES_BASE);
  endtask

  // emit_sw_res(reg, slot): sw reg, 4*slot(x31)   (slot 0..511).
  task automatic emit_sw_res(input logic [4:0] rs, input int slot);
    emit(rv_sw(rs, 5'd31, slot * 4));
  endtask

  // emit_halt(): ebreak.
  task automatic emit_halt();
    emit(rv_ebreak());
  endtask

  // host_load_prog(pad=8): host-write every emitted word, then pad words (all-zero = illegal) after the
  //   highest emitted word. Enters host mode (reset asserted, i_ld_en=1) if needed.
  task automatic host_load_prog(input int pad = 8);
    int hi;
    hi = -1;
    host_begin();
    for (int i = 0; i < 8192; i++) begin
      if (prog_dirty[i]) begin
        host_cycle(1'b1, 1'b1, 32'(i * 4), 4'hF, prog_mem[i]);
        hi = i;
      end
    end
    for (int j = 1; j <= pad; j++) begin
      if (hi + j < 8192) begin
        if (!prog_dirty[hi + j]) host_cycle(1'b1, 1'b1, 32'((hi + j) * 4), 4'hF, 32'h0);
      end
    end
    host_idle();
  endtask

  // ---------------------------------------------------------------------------------------------
  // Run control
  // ---------------------------------------------------------------------------------------------
  bit              tb_run_hit = 0;        // last wait_halt/run_prog: o_halt seen before the timeout
  longint unsigned tb_run_cycles = 0;     // cycles from reset release to the first cycle with o_halt=1

  // drain_halted(): after o_halt rose, let the halted core drain: an instruction older than the halting one
  //   (e.g. the last sw before ebreak) may still be in MEM / on the APB. Ticks at least 8 cycles and until
  //   p_cpu_dmem_req and p_apb_psel were low for 4 consecutive cycles (hard cap 64 cycles). The first host access
  //   after a run (host_begin) resets the DUT, so this must complete before it.
  task automatic drain_halted();
    int k, idle;
    k    = 0;
    idle = 0;
    while ((k < 8 || idle < 4) && k < 64) begin
      tick();
      k++;
      if (p_cpu_dmem_req !== 1'b1 && p_apb_psel !== 1'b1) idle++;
      else                                                idle = 0;
    end
  endtask

  // wait_halt(timeout_cycles): tick until o_halt=1 or timeout. Sets tb_run_hit, tb_run_cycles (cycles from reset
  //   release to the FIRST o_halt cycle, taken before the drain, so timing comparisons are unaffected). When the
  //   core halted, a post-halt drain window (drain_halted()) runs before returning, so older stores have reached
  //   DMEM and the sts.err event counter has seen the o_err_illegal rise when the caller checks / resets.
  task automatic wait_halt(input int timeout_cycles = 20000);
    int n;
    n = 0;
    while (o_halt !== 1'b1 && n < timeout_cycles) begin
      tick();
      n++;
    end
    tb_run_hit    = (o_halt === 1'b1);
    tb_run_cycles = tb_cycle - tb_rel_cycle;
    if (tb_run_hit) drain_halted();
  endtask

  // run_prog(timeout_cycles=20000): host-load the current program (reset, i_ld_en=1), release reset and
  //   wait for o_halt (plus the post-halt drain). After it returns the core is still halted/running; the first
  //   host access afterwards (dmem_rd, res_rd, ...) calls host_begin(), which snapshots
  //   o_halt/o_err_illegal/... into snap_* and puts the DUT in reset (CSR state lost, memories kept).
  task automatic run_prog(input int timeout_cycles = 20000);
    host_load_prog();
    host_end();
    wait_halt(timeout_cycles);
  endtask

  // run_prog_cycles(): same as run_prog; tb_run_cycles holds the cycle count to the first o_halt cycle
  // (differential timing). This alias exists for readability.
  task automatic run_prog_cycles(input int timeout_cycles = 20000);
    run_prog(timeout_cycles);
  endtask

  // wait_sts_done(timeout_cycles): tick until o_sts_done=1 or timeout; returns via tb_run_hit.
  task automatic wait_sts_done(input int timeout_cycles = 2000000);
    int n;
    n = 0;
    while (o_sts_done !== 1'b1 && n < timeout_cycles) begin
      tick();
      n++;
    end
    tb_run_hit    = (o_sts_done === 1'b1);
    tb_run_cycles = tb_cycle - tb_rel_cycle;
  endtask

  // start_pulse(n=1): drive i_start_req=1 for n cycles then 0 (only pulses; held-high overlap not tested).
  task automatic start_pulse(input int n = 1);
    i_start_req = 1'b1;
    wait_cycles(n);
    i_start_req = 1'b0;
  endtask

  // chk_halted_stable(n): first let the older instructions drain (CPU data request and APB idle for 4 consecutive
  //   cycles, at least 4 cycles, cap 64: an older sw legitimately issues after o_halt rises, an MMIO one takes
  //   longer), then for n cycles check o_halt stays 1, o_err_illegal does not change, the fetch address does not
  //   change and the CPU issues no data request (PC stopped, pipeline drained). Nothing is relaxed after the drain.
  task automatic chk_halted_stable(input int n = 16);
    logic        h0, e0;
    logic [31:0] pc0;
    int          kd, idle;
    h0  = o_halt;
    e0  = o_err_illegal;
    `TC_CHECK(h0 === 1'b1, "core not halted when chk_halted_stable was called")
    kd   = 0;
    idle = 0;
    while ((kd < 4 || idle < 4) && kd < 64) begin
      tick();
      kd++;
      if (p_cpu_dmem_req !== 1'b1 && p_apb_psel !== 1'b1) idle++;
      else                                                idle = 0;
    end
    pc0 = p_imem_addr;
    repeat (n) begin
      tick();
      `TC_CHECK(o_halt === 1'b1, "o_halt dropped while halted")
      `TC_CHECK(o_err_illegal === e0, "o_err_illegal changed while halted")
      `TC_CHECK(p_imem_addr === pc0, "fetch address moved while halted")
      `TC_CHECK(p_cpu_dmem_req !== 1'b1, "CPU data request while halted")
    end
  endtask

  // ---------------------------------------------------------------------------------------------
  // Monitors (always on). Counters are cleared automatically when a new TC starts (tc_id_s changes).
  // ---------------------------------------------------------------------------------------------
  // -- global
  int tb_ldv_cnt;                 // i_ld_en=1 at a rising edge with i_rst_n_core=1 (REQ-023 violation)
  int tb_out_async_cnt;           // registered output changed away from a clock edge while reset released
  // -- APB (REQ-016/028/029/030, SVA-004)
  int tb_apb_viol_cnt;            // protocol violations (PENABLE w/o PSEL, setup/access order, instability, pprot!=0)
  int tb_apb_xfer_cnt;            // completed transfers
  int tb_apb_slverr_cnt;          // transfers completed with PSLVERR=1
  int tb_apb_last_len;            // cycles with PSEL=1 of the last completed transfer (SETUP + ACCESS cycles)
  int tb_apb_min_len;             // minimum over completed transfers (large when none)
  int tb_apb_early_ack_cnt;       // CPU i_dmem_ack=1 while an APB transfer was still in progress
  int tb_errpulse_cnt;            // rising edges of o_sts_err_set
  int tb_errpulse_long_cnt;       // o_sts_err_set high for more than 1 cycle
  int tb_apb_log_n;               // number of logged completed transfers (log index = n % 256)
  logic [15:0] tb_apb_log_addr  [0:255];
  bit          tb_apb_log_write [0:255];
  logic [31:0] tb_apb_log_wdata [0:255];
  logic [3:0]  tb_apb_log_pstrb [0:255];
  bit          tb_apb_log_slverr[0:255];
  int          tb_apb_log_len   [0:255];
  // -- VPU command interface (REQ-009/031/032/087, SVA-003)
  int tb_vcmd_viol_cnt;           // valid dropped/unstable before ready, ready while busy, spurious/long done
  int tb_vcmd_cnt;                // commands transferred (valid && ready)
  int tb_vlat_short_cnt;          // commands whose latency done_cycle - start_cycle is below 5 (REQ-087: IDLE..DONE = 5)
  int tb_vlat_min;                // smallest done_cycle - start_cycle seen (large when no command completed)
  int tb_vlog_n;                  // completed vector instructions logged (log index = n % 256)
  logic [31:0] tb_vlog_instr [0:255];
  int          tb_vlog_lat   [0:255];   // done_cycle - start_cycle
  logic [31:0] tb_vlog_cnt_exp [0:255]; // expected cycles.cnt = done_cycle - start_cycle + 1 (REQ-013)
  logic [31:0] tb_vlog_cnt_obs [0:255]; // o_cycles_cnt observed in the cycle after the done pulse
  logic        tb_vlog_rdv   [0:255];
  logic [31:0] tb_vlog_rdd   [0:255];
  // -- VPU memory interface (REQ-033/079)
  int tb_vmem_viol_cnt;           // o_mem_req dropped or address/data/byte-enable changed before i_mem_ack
  int tb_vmem_early_ack_cnt;      // i_mem_ack in the same cycle as the first o_mem_req cycle (REQ-079: >=1 cycle later)
  int tb_vmem_xfer_cnt;           // completed VPU memory accesses
  int tb_vmem_log_n;
  logic [31:0] tb_vmem_log_addr [0:255];
  bit          tb_vmem_log_wr   [0:255];
  logic [15:0] tb_vmem_log_be   [0:255];
  logic [127:0] tb_vmem_log_wdata [0:255];
  // -- CPU/VPU exclusivity and halt (REQ-034, REQ-053)
  int tb_cpu_vpu_overlap_cnt;     // CPU o_dmem_req and VPU o_mem_req high in the same cycle
  int tb_post_halt_dmem_cnt;      // CPU data requests more than 4 cycles after o_halt
  int tb_post_halt_pc_cnt;        // fetch address changes more than 4 cycles after o_halt
  // -- UART frame decoder (enabled when tb_uart_baud > 0; set it BEFORE the frame starts)
  int tb_uart_baud = 0;           // bit time in clocks (= uart_cfg.baud_div programmed by the program)
  int tb_uart_fall_cnt;           // falling edges of o_uart_tx
  logic [7:0] tb_uart_rx_data [$];     // decoded bytes (LSB first on the wire)
  bit         tb_uart_rx_start_ok [$]; // start bit low for exactly one bit time
  bit         tb_uart_rx_stop_ok  [$]; // stop bit high
  bit         tb_uart_rx_len_ok   [$]; // every one of the 10 bit slots constant for exactly tb_uart_baud clocks
  longint unsigned tb_uart_rx_cyc [$]; // tb_cycle of the first low sample of each frame

  // mon_clear(): reset all monitor counters/logs (called automatically at the start of each TC).
  task automatic mon_clear();
    tb_ldv_cnt = 0;  tb_out_async_cnt = 0;
    tb_apb_viol_cnt = 0;  tb_apb_xfer_cnt = 0;  tb_apb_slverr_cnt = 0;  tb_apb_last_len = 0;
    tb_apb_min_len = 32'h7FFF_FFFF;  tb_apb_early_ack_cnt = 0;  tb_errpulse_cnt = 0;  tb_errpulse_long_cnt = 0;
    tb_apb_log_n = 0;
    tb_vcmd_viol_cnt = 0;  tb_vcmd_cnt = 0;  tb_vlog_n = 0;
    tb_vlat_short_cnt = 0;  tb_vlat_min = 32'h7FFF_FFFF;
    tb_vmem_viol_cnt = 0;  tb_vmem_early_ack_cnt = 0;  tb_vmem_xfer_cnt = 0;  tb_vmem_log_n = 0;
    tb_cpu_vpu_overlap_cnt = 0;  tb_post_halt_dmem_cnt = 0;  tb_post_halt_pc_cnt = 0;
    tb_uart_fall_cnt = 0;
    tb_uart_rx_data.delete();  tb_uart_rx_start_ok.delete();  tb_uart_rx_stop_ok.delete();
    tb_uart_rx_len_ok.delete();  tb_uart_rx_cyc.delete();
    tb_sts_err_events = 0;
  endtask

  // mon_check_all(): TC_CHECK that no protocol/ownership/exclusivity monitor fired. Call at the end of a TC.
  task automatic mon_check_all();
    `TC_CHECK(tb_ldv_cnt == 0,              "REQ-023: i_ld_en was 1 at a rising edge with reset released")
    `TC_CHECK(tb_apb_viol_cnt == 0,         "APB protocol violation (SETUP/ACCESS order, stability, PPROT)")
    `TC_CHECK(tb_vcmd_viol_cnt == 0,        "VPU command interface violation (valid/stable/ready/done)")
    `TC_CHECK(tb_vlat_short_cnt == 0,       "REQ-087: a vector command completed in fewer than 5 cycles (start to o_resp_done)")
    `TC_CHECK(tb_vmem_viol_cnt == 0,        "VPU memory request dropped or changed before i_mem_ack")
    `TC_CHECK(tb_cpu_vpu_overlap_cnt == 0,  "CPU and VPU requested DMEM in the same cycle")
    `TC_CHECK(tb_out_async_cnt == 0,        "registered output changed away from a clock edge")
    `TC_CHECK(tb_apb_early_ack_cnt == 0,    "CPU i_dmem_ack before PREADY of an APB transfer")
    `TC_CHECK(tb_errpulse_long_cnt == 0,    "o_sts_err_set pulse longer than 1 cycle")
  endtask

  // uart_wait_frames(n, timeout_cycles): tick until at least n frames were decoded (tb_uart_baud must be set).
  task automatic uart_wait_frames(input int n, input int timeout_cycles);
    int k;
    k = 0;
    while (tb_uart_rx_data.size() < n && k < timeout_cycles) begin
      tick();
      k++;
    end
    tb_run_hit = (tb_uart_rx_data.size() >= n);
  endtask

  // ---- previous-cycle registers of the monitors
  logic        m_rst_q;                // i_rst_n_core was high at the previous edge (APB checks need 2 released edges)
  logic        m_apb_psel, m_apb_pen, m_apb_rdy, m_apb_wr;
  logic [15:0] m_apb_adr;
  logic [31:0] m_apb_wd;
  logic [3:0]  m_apb_stb;
  int          m_apb_len;
  logic        m_errset;
  logic        m_v_valid, m_v_ready, m_v_done, m_v_busy;
  logic [31:0] m_v_instr, m_v_rs1, m_v_rs2;
  longint unsigned m_v_start;
  bit          m_vcyc_pend;
  int          m_vcyc_idx;
  logic        m_vm_req, m_vm_ack, m_vm_wr;
  logic [31:0] m_vm_addr;
  logic [15:0] m_vm_be;
  logic [127:0] m_vm_wd;
  logic        m_err_ill;
  int          m_halt_age;
  logic [31:0] m_pc_halt;
  // UART decoder state
  bit          u_act;
  int          u_cnt;
  logic        u_seg;
  logic [9:0]  u_bits;
  bit          u_len_ok;
  longint unsigned u_start_cyc;

  initial begin
    mon_clear();
    m_rst_q = 0;
    m_apb_psel = 0; m_apb_pen = 0; m_apb_rdy = 0; m_apb_len = 0; m_errset = 0;
    m_v_valid = 0; m_v_ready = 0; m_v_done = 0; m_v_busy = 0; m_vcyc_pend = 0; m_vcyc_idx = 0;
    m_vm_req = 0; m_vm_ack = 0; m_err_ill = 0; m_halt_age = 0; u_act = 0; u_cnt = 0;
  end

  string tb_mon_tc = "";

  always @(posedge i_clk_core) begin : mon_main
    logic a_psel, a_pen, a_rdy, a_inflight_prev, apb_chk;
    logic v_valid, v_ready, v_done, v_xfer;
    logic vm_req, vm_ack, vm_first;
    // new TC -> clear monitor counters
    if (tc_id_s != tb_mon_tc) begin
      mon_clear();
      tb_mon_tc = tc_id_s;
    end
    a_psel = (p_apb_psel === 1'b1);
    a_pen  = (p_apb_penable === 1'b1);
    a_rdy  = (p_apb_pready === 1'b1);
    v_valid = (p_vcmd_valid === 1'b1);
    v_ready = (p_vcmd_ready === 1'b1);
    v_done  = (p_vresp_done === 1'b1);
    vm_req  = (p_vmem_req === 1'b1);
    vm_ack  = (p_vmem_ack === 1'b1);

    // ---- REQ-023: host port ownership
    if (i_rst_n_core === 1'b1 && i_ld_en === 1'b1) tb_ldv_cnt++;

    // ---- sts.err hardware set events (illegal instruction rising, APB error pulse)
    if (i_rst_n_core === 1'b1) begin
      if (o_err_illegal === 1'b1 && !m_err_ill) tb_sts_err_events++;
      if (p_sts_err_set === 1'b1 && !m_errset)  tb_sts_err_events++;
    end
    if (p_sts_err_set === 1'b1 && !m_errset) tb_errpulse_cnt++;
    if (p_sts_err_set === 1'b1 &&  m_errset) tb_errpulse_long_cnt++;

    // ---- APB protocol
    // A reset aborts an in-flight APB transfer (REQ-044, ERR-006): PSEL/PENABLE and the registered address/data
    // drop at once. While i_rst_n_core is low, and in the first cycle after the release, nothing is scored and the
    // previous-cycle APB tracking is cleared, so the abort is not counted as 'PSEL dropped', 'stability' or
    // 'SETUP/ACCESS order'. Every check is active whenever reset has been released for a full cycle.
    apb_chk = (i_rst_n_core === 1'b1) && m_rst_q;
    if (!apb_chk) begin
      m_apb_psel = 1'b0;
      m_apb_pen  = 1'b0;
      m_apb_rdy  = 1'b0;
      m_apb_len  = 0;
    end
    a_inflight_prev = m_apb_psel && !(m_apb_pen && m_apb_rdy);
    if (apb_chk) begin
      if (a_pen && !a_psel) tb_apb_viol_cnt++;                       // PENABLE without PSEL
      if (m_apb_psel && a_inflight_prev && !a_psel) tb_apb_viol_cnt++; // PSEL dropped before completion
      if (a_psel && !a_pen && a_inflight_prev) tb_apb_viol_cnt++;    // SETUP while previous transfer pending
      if (a_psel &&  a_pen && !a_inflight_prev) tb_apb_viol_cnt++;   // ACCESS without SETUP
      if (a_psel && a_inflight_prev) begin                           // address/control/data stable
        if (p_apb_paddr !== m_apb_adr || p_apb_pwrite !== m_apb_wr || p_apb_pwdata !== m_apb_wd ||
            p_apb_pstrb !== m_apb_stb) tb_apb_viol_cnt++;
      end
      if (a_psel && p_apb_pprot !== 3'b000) tb_apb_viol_cnt++;       // PPROT always 0
    end
    if (a_psel && !a_pen) m_apb_len = 1;
    else if (a_psel)      m_apb_len = m_apb_len + 1;
    if (apb_chk && a_psel && a_pen && a_rdy) begin
      tb_apb_xfer_cnt++;
      tb_apb_last_len = m_apb_len;
      if (m_apb_len < tb_apb_min_len) tb_apb_min_len = m_apb_len;
      if (p_apb_pslverr === 1'b1) tb_apb_slverr_cnt++;
      tb_apb_log_addr  [tb_apb_log_n % 256] = p_apb_paddr;
      tb_apb_log_write [tb_apb_log_n % 256] = p_apb_pwrite;
      tb_apb_log_wdata [tb_apb_log_n % 256] = p_apb_pwdata;
      tb_apb_log_pstrb [tb_apb_log_n % 256] = p_apb_pstrb;
      tb_apb_log_slverr[tb_apb_log_n % 256] = (p_apb_pslverr === 1'b1);
      tb_apb_log_len   [tb_apb_log_n % 256] = m_apb_len;
      tb_apb_log_n++;
    end
    if (apb_chk && p_cpu_dmem_ack === 1'b1 && a_psel && !(a_pen && a_rdy)) tb_apb_early_ack_cnt++;

    // ---- VPU command interface
    if (m_v_valid && !m_v_ready) begin                             // pending command must be held stable
      if (!v_valid || p_vcmd_instr !== m_v_instr || p_vcmd_rs1 !== m_v_rs1 || p_vcmd_rs2 !== m_v_rs2)
        tb_vcmd_viol_cnt++;
    end
    if (m_vcyc_pend) begin                                         // cycle after the done pulse
      tb_vlog_cnt_obs[m_vcyc_idx % 256] = p_vcyc_cnt;
      m_vcyc_pend = 0;
    end
    if (m_v_busy && v_ready) tb_vcmd_viol_cnt++;                   // ready only in IDLE
    if (v_done) begin
      if (!m_v_busy) tb_vcmd_viol_cnt++;                           // done without a command
      if (m_v_done)  tb_vcmd_viol_cnt++;                           // done longer than 1 cycle
      if (m_v_busy) begin
        tb_vlog_instr  [tb_vlog_n % 256] = m_v_instr;
        tb_vlog_lat    [tb_vlog_n % 256] = int'(tb_cycle - m_v_start);
        if (int'(tb_cycle - m_v_start) < 5) tb_vlat_short_cnt++;       // REQ-087: six states -> >= 5 cycles
        if (int'(tb_cycle - m_v_start) < tb_vlat_min) tb_vlat_min = int'(tb_cycle - m_v_start);
        tb_vlog_cnt_exp[tb_vlog_n % 256] = 32'(tb_cycle - m_v_start + 1);
        tb_vlog_cnt_obs[tb_vlog_n % 256] = 32'hFFFF_FFFF;
        tb_vlog_rdv    [tb_vlog_n % 256] = (p_vresp_rdv === 1'b1);
        tb_vlog_rdd    [tb_vlog_n % 256] = p_vresp_rdd;
        m_vcyc_idx  = tb_vlog_n;
        m_vcyc_pend = 1;
        tb_vlog_n++;
      end
    end
    v_xfer = v_valid && v_ready;
    if (v_xfer) begin
      tb_vcmd_cnt++;
      m_v_start = tb_cycle;
      m_v_instr = p_vcmd_instr;       // latched instruction of the executing command
    end
    if (v_done) m_v_busy = 1'b0;
    if (v_xfer) m_v_busy = 1'b1;

    // ---- VPU memory interface
    if (m_vm_req && !m_vm_ack) begin
      if (!vm_req || p_vmem_addr !== m_vm_addr || p_vmem_wr_en !== m_vm_wr) tb_vmem_viol_cnt++;
      else if (m_vm_wr && (p_vmem_be !== m_vm_be || p_vmem_wdata !== m_vm_wd)) tb_vmem_viol_cnt++;
    end
    vm_first = vm_req && !(m_vm_req && !m_vm_ack);
    if (vm_first && vm_ack) tb_vmem_early_ack_cnt++;
    if (vm_req && vm_ack) begin
      tb_vmem_xfer_cnt++;
      tb_vmem_log_addr [tb_vmem_log_n % 256] = p_vmem_addr;
      tb_vmem_log_wr   [tb_vmem_log_n % 256] = (p_vmem_wr_en === 1'b1);
      tb_vmem_log_be   [tb_vmem_log_n % 256] = 16'(p_vmem_be);
      tb_vmem_log_wdata[tb_vmem_log_n % 256] = p_vmem_wdata;
      tb_vmem_log_n++;
    end

    // ---- CPU / VPU exclusivity, halted core
    if (p_cpu_dmem_req === 1'b1 && vm_req) tb_cpu_vpu_overlap_cnt++;
    if (o_halt === 1'b1) begin
      if (m_halt_age == 0) m_pc_halt = p_imem_addr;
      m_halt_age = m_halt_age + 1;
      if (m_halt_age > 4) begin
        if (p_cpu_dmem_req === 1'b1) tb_post_halt_dmem_cnt++;
        if (p_imem_addr !== m_pc_halt) tb_post_halt_pc_cnt++;
      end
    end else begin
      m_halt_age = 0;
    end

    // ---- UART frame decoder
    if (tb_uart_baud > 0) begin
      if (!u_act && o_uart_tx === 1'b0) begin
        u_act = 1; u_cnt = 0; u_bits = 10'h3FF; u_len_ok = 1; u_start_cyc = tb_cycle;
      end
      if (u_act) begin
        if ((u_cnt % tb_uart_baud) == 0) u_seg = o_uart_tx;
        else if (o_uart_tx !== u_seg) u_len_ok = 0;
        u_bits[u_cnt / tb_uart_baud] = u_seg;
        u_cnt++;
        if (u_cnt == 10 * tb_uart_baud) begin
          tb_uart_rx_data.push_back(u_bits[8:1]);
          tb_uart_rx_start_ok.push_back(u_bits[0] === 1'b0);
          tb_uart_rx_stop_ok.push_back(u_bits[9] === 1'b1);
          tb_uart_rx_len_ok.push_back(u_len_ok);
          tb_uart_rx_cyc.push_back(u_start_cyc);
          u_act = 0;
        end
      end
    end

    // ---- previous-cycle registers
    if (apb_chk) begin
      m_apb_psel = a_psel; m_apb_pen = a_pen; m_apb_rdy = a_rdy; m_apb_wr = p_apb_pwrite;
      m_apb_adr = p_apb_paddr; m_apb_wd = p_apb_pwdata; m_apb_stb = p_apb_pstrb;
    end else begin                       // reset low / first cycle after release: no APB history
      m_apb_psel = 1'b0; m_apb_pen = 1'b0; m_apb_rdy = 1'b0; m_apb_len = 0;
    end
    m_rst_q = (i_rst_n_core === 1'b1);
    m_errset = (p_sts_err_set === 1'b1);
    m_v_valid = v_valid; m_v_ready = v_ready; m_v_done = v_done;
    m_v_rs1 = p_vcmd_rs1; m_v_rs2 = p_vcmd_rs2;
    if (v_valid && !v_ready) m_v_instr = p_vcmd_instr;   // pending command: remember for stability check
    if (v_xfer) m_v_instr = p_vcmd_instr;
    m_vm_req = vm_req; m_vm_ack = vm_ack; m_vm_wr = (p_vmem_wr_en === 1'b1);
    m_vm_addr = p_vmem_addr; m_vm_be = 16'(p_vmem_be); m_vm_wd = p_vmem_wdata;
    m_err_ill = (o_err_illegal === 1'b1);

    tb_last_posedge_t = $time;
    tb_cycle = tb_cycle + 1;
  end

  // UART start-bit counter
  always @(negedge o_uart_tx) tb_uart_fall_cnt++;

  // Registered outputs may only change at a rising edge while reset is released (REQ-027, TC-016)
  always @(o_halt or o_err_illegal or o_sts_done or o_result_label or o_uart_tx) begin
    if (tb_mon_run && i_rst_n_core === 1'b1 && $time != tb_last_posedge_t) tb_out_async_cnt++;
  end

  // Global cycle watchdog (override with +MAXCYC=<n>)
  always @(posedge i_clk_core) begin
    if (tb_cycle > tb_max_cycles) begin
      $display("TB_TIMEOUT: global cycle limit %0d reached", tb_max_cycles);
      `TC_SUMMARY
      $fatal(1, "tb_top global timeout");
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Test case tasks (one file per TC under tests/) and the run sequence
  // ---------------------------------------------------------------------------------------------
  `include "tb_tests.svh"

  initial begin
    void'($value$plusargs("SEED=%d", tb_seed));
    void'($value$plusargs("MAXCYC=%d", tb_max_cycles));
    $display("TB_SEED %0d", tb_seed);
    void'($urandom(tb_seed));
    prog_reset();
    // power-up reset: asserted from time 0, held for a few cycles, released synchronously by the TB
    i_rst_n_core = 1'b0;
    wait_cycles(6);
    rst_release();
    wait_cycles(2);
    `include "tb_run.svh"
    `TC_SUMMARY
    $finish;
  end

endmodule
