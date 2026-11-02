`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : Structural top of the MNIST inference SoC. It holds
 *                only the interface, parameters, interconnect and child instances: reset
 *                synchronizer, CPU, VPU, bus decode, host load mux, IMEM, DMEM, APB master, the
 *                tool-generated CSR slave and the UART. Single clock domain core (i_clk_core): no
 *                CDC and no clock gating. Every block receives the synchronized reset of m_rst_sync.
 *                The port list is the same in every configuration; only PARA_VLEN and
 *                PARA_LANE_COUNT are passed down to the children.
 *
 *                CSR wiring: i_start_req is a level request that sets ctrl.start through the
 *                hardware-write port (write data 1, write enable = i_start_req); firmware clears
 *                it. m_apb_master pulses the hardware write of sts.err on PSLVERR. m_uart clears
 *                uart_tx.send with a hardware write of 0 when it takes a byte. m_soc_csr is
 *                connected with i_slverr_en = 1 and i_protect_en = 0 (generated with Asynchronous
 *                = 0).
 *
 *                Non-RTL requirements traced here: the 200 MHz target is claimed only by STA with
 *                the SDC in constraints/; the inference time and accuracy are checked by system
 *                simulation against the golden model; testbenches, models and SVA live in tb/,
 *                outside the synthesis filelist; the regression script reports PASS/FAIL.
 *                Firmware start.S does not clear DMEM, and the memory contents come from the flow's
 *                init files inside the wrappers.
 * Parent       : none (design top)
 * REQ-IDs      : REQ-014, REQ-023, REQ-024, REQ-025, REQ-026, REQ-027, REQ-039, REQ-043,
 *                REQ-064, REQ-065, REQ-068, REQ-069, REQ-071, REQ-072
 */
`timescale 1ns / 1ps

module m_soc_top #(
    // Parameter Description: vector register width and DMEM row width; passed to the VPU, the bus,
    //                        the host load mux and DMEM. Must be divisible by
    //                        PARA_LANE_COUNT x 32 (checked in the children).
    // Parameter values: legal values are 128 or 256; default is 128.
    // Parameter unit: bit
    parameter  logic [31:0] PARA_VLEN          = 128,
    // Parameter Description: number of parallel 32-bit lanes of the VPU; must be a power of 2 and
    //                        PARA_VLEN must be divisible by PARA_LANE_COUNT x 32.
    // Parameter values: legal values are 1, 2, 4, or 8; default is 4.
    // Parameter unit: count
    parameter  logic [31:0] PARA_LANE_COUNT    = 4,
    // Width of the byte addresses, of the CPU/host data words and of the CSR cycle counter.
    localparam logic [31:0] LPARA_XLEN         = 32,
    // Number of byte enables of a 32-bit word.
    localparam logic [31:0] LPARA_BE_W         = LPARA_XLEN / 8,
    // Width of the predicted label (result.label).
    localparam logic [31:0] LPARA_LABEL_W      = 4,
    // Number of bytes in one DMEM / VPU row (VPU and DMEM byte-enable width).
    localparam logic [31:0] LPARA_ROW_BYTES    = PARA_VLEN / 8,
    // Number of low address bits that select a byte inside a row.
    localparam logic [31:0] LPARA_ROW_LB       = $clog2(PARA_VLEN / 8),
    // Number of low address bits that select a byte inside a 32-bit word.
    localparam logic [31:0] LPARA_WORD_LB      = $clog2(LPARA_XLEN / 8),
    // log2 of the DMEM byte count (256 KB) and of the IMEM byte count (32 KB).
    localparam logic [31:0] LPARA_DMEM_SIZE_LB = 18,
    localparam logic [31:0] LPARA_IMEM_SIZE_LB = 15,
    // Width of the DMEM row index and of the IMEM word index.
    localparam logic [31:0] LPARA_DMEM_ROW_W   = LPARA_DMEM_SIZE_LB - LPARA_ROW_LB,
    localparam logic [31:0] LPARA_IMEM_IDX_W   = LPARA_IMEM_SIZE_LB - LPARA_WORD_LB,
    // Widths of the APB address, of PPROT and of the UART byte and baud divisor.
    localparam logic [31:0] LPARA_PADDR_W      = 16,
    localparam logic [31:0] LPARA_PPROT_W      = 3,
    localparam logic [31:0] LPARA_UART_DATA_W  = 8,
    localparam logic [31:0] LPARA_BAUD_W       = 16
) (
    // Clock and reset
    input  wire                      i_clk_core,
    input  wire                      i_rst_n_core,
    // Control in
    input  wire                      i_start_req,
    // Host load port
    input  wire                      i_ld_en,
    input  wire                      i_ld_req,
    input  wire                      i_ld_wr_en,
    input  wire  [   LPARA_XLEN-1:0] i_ld_addr,
    input  wire  [   LPARA_BE_W-1:0] i_ld_byte_en,
    input  wire  [   LPARA_XLEN-1:0] i_ld_wr_data,
    // Control out
    output logic                     o_sts_done,
    output logic [LPARA_LABEL_W-1:0] o_result_label,
    output logic                     o_uart_tx,
    output logic                     o_err_illegal,
    output logic                     o_halt,
    // Data out
    output logic [   LPARA_XLEN-1:0] o_ld_rd_data
);

  // Synchronized reset
  logic                                     w_rst_n_core;

  // CPU instruction fetch
  logic [                   LPARA_XLEN-1:0] w_cpu_imem_addr;
  logic [                   LPARA_XLEN-1:0] w_imem_rd_data;

  // CPU data bus
  logic                                     w_cpu_dmem_req;
  logic                                     w_cpu_dmem_wr_en;
  logic [                   LPARA_BE_W-1:0] w_cpu_dmem_byte_en;
  logic [                   LPARA_XLEN-1:0] w_cpu_dmem_addr;
  logic [                   LPARA_XLEN-1:0] w_cpu_dmem_wr_data;
  logic [                   LPARA_XLEN-1:0] w_cpu_dmem_rd_data;
  logic                                     w_cpu_dmem_ack;

  // CPU to VPU command and VPU response
  logic                                     w_vpu_cmd_valid;
  logic [                   LPARA_XLEN-1:0] w_vpu_cmd_instr;
  logic [                   LPARA_XLEN-1:0] w_vpu_cmd_rs1_data;
  logic [                   LPARA_XLEN-1:0] w_vpu_cmd_rs2_data;
  logic                                     w_vpu_cmd_ready;
  logic                                     w_vpu_resp_done;
  logic                                     w_vpu_resp_rd_valid;
  logic [                   LPARA_XLEN-1:0] w_vpu_resp_rd_data;

  // VPU memory bus and cycle count
  logic                                     w_vpu_mem_req;
  logic                                     w_vpu_mem_wr_en;
  logic [                   LPARA_XLEN-1:0] w_vpu_mem_addr;
  logic [              LPARA_ROW_BYTES-1:0] w_vpu_mem_byte_en;
  logic [                    PARA_VLEN-1:0] w_vpu_mem_wr_data;
  logic [                    PARA_VLEN-1:0] w_vpu_mem_rd_data;
  logic                                     w_vpu_mem_ack;
  logic [                   LPARA_XLEN-1:0] w_cycles_cnt;

  // DMEM row port from the bus to the host mux, and from the host mux to DMEM
  logic                                     w_bus_dmem_en;
  logic                                     w_bus_dmem_wr_en;
  logic [             LPARA_DMEM_ROW_W-1:0] w_bus_dmem_addr;
  logic [              LPARA_ROW_BYTES-1:0] w_bus_dmem_byte_en;
  logic [                    PARA_VLEN-1:0] w_bus_dmem_wr_data;
  logic [                    PARA_VLEN-1:0] w_bus_dmem_rd_data;
  logic                                     w_dmem_en;
  logic                                     w_dmem_wr_en;
  logic [             LPARA_DMEM_ROW_W-1:0] w_dmem_addr;
  logic [              LPARA_ROW_BYTES-1:0] w_dmem_byte_en;
  logic [                    PARA_VLEN-1:0] w_dmem_wr_data;
  logic [                    PARA_VLEN-1:0] w_dmem_rd_data;

  // IMEM host write port
  logic                                     w_imem_wr_en;
  logic [             LPARA_IMEM_IDX_W-1:0] w_imem_wr_addr;
  logic [                   LPARA_XLEN-1:0] w_imem_wr_data;

  // MMIO request from the bus to the APB master and response
  logic                                     w_mmio_req;
  logic                                     w_mmio_wr_en;
  logic [                   LPARA_BE_W-1:0] w_mmio_byte_en;
  logic [                   LPARA_XLEN-1:0] w_mmio_addr;
  logic [                   LPARA_XLEN-1:0] w_mmio_wr_data;
  logic [                   LPARA_XLEN-1:0] w_mmio_rd_data;
  logic                                     w_mmio_ack;

  // APB bus between m_apb_master and m_soc_csr
  logic                                     w_apb_psel;
  logic                                     w_apb_penable;
  logic                                     w_apb_pwrite;
  logic [                LPARA_PADDR_W-1:0] w_apb_paddr;
  logic [                   LPARA_XLEN-1:0] w_apb_pwdata;
  logic [                   LPARA_BE_W-1:0] w_apb_pstrb;
  logic [                LPARA_PPROT_W-1:0] w_apb_pprot;
  logic [                   LPARA_XLEN-1:0] w_apb_prdata;
  logic                                     w_apb_pready;
  logic                                     w_apb_pslverr;
  logic                                     w_sts_err_set;

  // CSR hardware ports and UART link
  logic                                     w_uart_tx_send;
  logic                                     w_uart_tx_send_clr;
  logic                                     w_uart_tx_busy;
  logic [            LPARA_UART_DATA_W-1:0] w_uart_tx_data;
  logic [                 LPARA_BAUD_W-1:0] w_uart_cfg_baud_div;

  // Open outputs and their collector (see the connections for the reason of each)
  logic                                     w_ctrl_start_unused;
  logic                                     w_sts_err_unused;
  logic                                     w_sts_busy_unused;
  logic [LPARA_XLEN-LPARA_IMEM_SIZE_LB-1:0] w_imem_addr_hi_unused;
  logic [                LPARA_WORD_LB-1:0] w_imem_addr_lo_unused;
  logic                                     w_unused_ok;

  // Fetch address mapping: IMEM is word addressed, so address bits [14:2] select the word; the
  // upper bits are always 0 for a legal program counter and the low two bits are 0 for aligned
  // fetches, so both groups are collected as intentionally open.
  // REQ-025, REQ-039
  assign w_imem_addr_hi_unused = w_cpu_imem_addr[LPARA_XLEN-1:LPARA_IMEM_SIZE_LB];
  assign w_imem_addr_lo_unused = w_cpu_imem_addr[LPARA_WORD_LB-1:0];

  // Open child outputs, collected so that they are visibly intentional. ctrl.start, sts.err and
  // sts.busy are consumed by firmware through APB reads only; the CSR module drives them to
  // dedicated ports that nothing else in the design needs.
  assign w_unused_ok = &{1'b0, w_ctrl_start_unused, w_sts_err_unused, w_sts_busy_unused,
                         w_imem_addr_hi_unused, w_imem_addr_lo_unused};

  // Reset synchronizer: asynchronous assert, synchronous release; its output resets every block.
  // REQ-039
  m_rst_sync u_rst_sync (
      .i_clk_core  (i_clk_core),
      .i_rst_n_core(i_rst_n_core),
      .o_rst_n_core(w_rst_n_core)
  );

  // Scalar CPU: fetches from IMEM, uses the data bus, dispatches vector instructions to the VPU and
  // drives the registered illegal/halt flags straight to the top ports.
  // REQ-014, REQ-025, REQ-027, REQ-043
  m_cpu_top u_cpu_top (
      .i_clk_core         (i_clk_core),
      .i_rst_n_core       (w_rst_n_core),
      .i_imem_rd_data     (w_imem_rd_data),
      .i_dmem_rd_data     (w_cpu_dmem_rd_data),
      .i_dmem_ack         (w_cpu_dmem_ack),
      .i_vpu_cmd_ready    (w_vpu_cmd_ready),
      .i_vpu_resp_done    (w_vpu_resp_done),
      .i_vpu_resp_rd_valid(w_vpu_resp_rd_valid),
      .i_vpu_resp_rd_data (w_vpu_resp_rd_data),
      .o_imem_addr        (w_cpu_imem_addr),
      .o_dmem_req         (w_cpu_dmem_req),
      .o_dmem_wr_en       (w_cpu_dmem_wr_en),
      .o_dmem_byte_en     (w_cpu_dmem_byte_en),
      .o_dmem_addr        (w_cpu_dmem_addr),
      .o_dmem_wr_data     (w_cpu_dmem_wr_data),
      .o_vpu_cmd_valid    (w_vpu_cmd_valid),
      .o_vpu_cmd_instr    (w_vpu_cmd_instr),
      .o_vpu_cmd_rs1_data (w_vpu_cmd_rs1_data),
      .o_vpu_cmd_rs2_data (w_vpu_cmd_rs2_data),
      .o_err_illegal      (o_err_illegal),
      .o_halt             (o_halt)
  );

  // Vector unit: executes one vector instruction at a time, owns the row-wide memory bus and drives
  // the cycle count of the last vector instruction to cycles.cnt of the CSR.
  // REQ-014, REQ-064, REQ-065
  m_vpu_top #(
      .PARA_VLEN      (PARA_VLEN),
      .PARA_LANE_COUNT(PARA_LANE_COUNT)
  ) u_vpu_top (
      .i_clk_core     (i_clk_core),
      .i_rst_n_core   (w_rst_n_core),
      .i_cmd_valid    (w_vpu_cmd_valid),
      .i_cmd_instr    (w_vpu_cmd_instr),
      .i_cmd_rs1_data (w_vpu_cmd_rs1_data),
      .i_cmd_rs2_data (w_vpu_cmd_rs2_data),
      .i_mem_rd_data  (w_vpu_mem_rd_data),
      .i_mem_ack      (w_vpu_mem_ack),
      .o_cmd_ready    (w_vpu_cmd_ready),
      .o_resp_done    (w_vpu_resp_done),
      .o_resp_rd_valid(w_vpu_resp_rd_valid),
      .o_resp_rd_data (w_vpu_resp_rd_data),
      .o_mem_req      (w_vpu_mem_req),
      .o_mem_wr_en    (w_vpu_mem_wr_en),
      .o_mem_addr     (w_vpu_mem_addr),
      .o_mem_byte_en  (w_vpu_mem_byte_en),
      .o_mem_wr_data  (w_vpu_mem_wr_data),
      .o_cycles_cnt   (w_cycles_cnt)
  );

  // Bus: address decode, CPU/VPU mux onto the single DMEM row port and MMIO routing to the APB
  // master. IMEM-range data accesses are unmapped (read 0, write ignored).
  // REQ-014
  m_soc_bus #(
      .PARA_VLEN(PARA_VLEN)
  ) u_soc_bus (
      .i_clk_core    (i_clk_core),
      .i_rst_n_core  (w_rst_n_core),
      .i_cpu_req     (w_cpu_dmem_req),
      .i_cpu_wr_en   (w_cpu_dmem_wr_en),
      .i_cpu_byte_en (w_cpu_dmem_byte_en),
      .i_cpu_addr    (w_cpu_dmem_addr),
      .i_cpu_wr_data (w_cpu_dmem_wr_data),
      .i_vpu_req     (w_vpu_mem_req),
      .i_vpu_wr_en   (w_vpu_mem_wr_en),
      .i_vpu_byte_en (w_vpu_mem_byte_en),
      .i_vpu_addr    (w_vpu_mem_addr),
      .i_vpu_wr_data (w_vpu_mem_wr_data),
      .i_dmem_rd_data(w_bus_dmem_rd_data),
      .i_mmio_rd_data(w_mmio_rd_data),
      .i_mmio_ack    (w_mmio_ack),
      .o_cpu_rd_data (w_cpu_dmem_rd_data),
      .o_cpu_ack     (w_cpu_dmem_ack),
      .o_vpu_rd_data (w_vpu_mem_rd_data),
      .o_vpu_ack     (w_vpu_mem_ack),
      .o_dmem_en     (w_bus_dmem_en),
      .o_dmem_wr_en  (w_bus_dmem_wr_en),
      .o_dmem_addr   (w_bus_dmem_addr),
      .o_dmem_byte_en(w_bus_dmem_byte_en),
      .o_dmem_wr_data(w_bus_dmem_wr_data),
      .o_mmio_req    (w_mmio_req),
      .o_mmio_wr_en  (w_mmio_wr_en),
      .o_mmio_byte_en(w_mmio_byte_en),
      .o_mmio_addr   (w_mmio_addr),
      .o_mmio_wr_data(w_mmio_wr_data)
  );

  // Host load port: i_ld_en is 0 at every rising edge of i_clk_core where i_rst_n_core = 1 (checked
  // by an assertion in tb/). When 1 it owns DMEM and writes IMEM; otherwise the bus port passes
  // through to DMEM. The host reads one lane of a DMEM row one cycle after the request.
  // REQ-023, REQ-025
  m_host_ld #(
      .PARA_VLEN(PARA_VLEN)
  ) u_host_ld (
      .i_clk_core        (i_clk_core),
      .i_ld_en           (i_ld_en),
      .i_ld_req          (i_ld_req),
      .i_ld_wr_en        (i_ld_wr_en),
      .i_ld_addr         (i_ld_addr),
      .i_ld_byte_en      (i_ld_byte_en),
      .i_ld_wr_data      (i_ld_wr_data),
      .o_ld_rd_data      (o_ld_rd_data),
      .i_bus_dmem_en     (w_bus_dmem_en),
      .i_bus_dmem_wr_en  (w_bus_dmem_wr_en),
      .i_bus_dmem_addr   (w_bus_dmem_addr),
      .i_bus_dmem_byte_en(w_bus_dmem_byte_en),
      .i_bus_dmem_wr_data(w_bus_dmem_wr_data),
      .o_bus_dmem_rd_data(w_bus_dmem_rd_data),
      .i_dmem_rd_data    (w_dmem_rd_data),
      .o_dmem_en         (w_dmem_en),
      .o_dmem_wr_en      (w_dmem_wr_en),
      .o_dmem_addr       (w_dmem_addr),
      .o_dmem_byte_en    (w_dmem_byte_en),
      .o_dmem_wr_data    (w_dmem_wr_data),
      .o_imem_wr_en      (w_imem_wr_en),
      .o_imem_wr_addr    (w_imem_wr_addr),
      .o_imem_wr_data    (w_imem_wr_data)
  );

  // Instruction memory (32 KB): registered fetch read by word index and host word write. The
  // memories are resetless and initialized by the flow's init file; start.S does not clear DMEM.
  // REQ-043
  m_imem u_imem (
      .i_clk_core    (i_clk_core),
      .i_rd_addr     (w_cpu_imem_addr[LPARA_IMEM_SIZE_LB-1:LPARA_WORD_LB]),
      .i_init_wr_en  (w_imem_wr_en),
      .i_init_wr_addr(w_imem_wr_addr),
      .i_init_wr_data(w_imem_wr_data),
      .o_rd_data     (w_imem_rd_data)
  );

  // Data memory (256 KB): one row port shared by the bus (CPU, VPU) and the host mux.
  // REQ-043
  m_dmem #(
      .PARA_VLEN(PARA_VLEN)
  ) u_dmem (
      .i_clk_core(i_clk_core),
      .i_en      (w_dmem_en),
      .i_wr_en   (w_dmem_wr_en),
      .i_addr    (w_dmem_addr),
      .i_byte_en (w_dmem_byte_en),
      .i_wr_data (w_dmem_wr_data),
      .o_rd_data (w_dmem_rd_data)
  );

  // APB requester: turns a CPU MMIO access into an APB transfer; PSLVERR becomes a 1-cycle pulse on
  // the hardware-write port of sts.err. PSTRB carries the CPU byte enables.
  // REQ-024
  m_apb_master u_apb_master (
      .i_clk_core    (i_clk_core),
      .i_rst_n_core  (w_rst_n_core),
      .i_mmio_req    (w_mmio_req),
      .i_mmio_wr_en  (w_mmio_wr_en),
      .i_mmio_byte_en(w_mmio_byte_en),
      .i_mmio_addr   (w_mmio_addr),
      .i_mmio_wr_data(w_mmio_wr_data),
      .i_apb_prdata  (w_apb_prdata),
      .i_apb_pready  (w_apb_pready),
      .i_apb_pslverr (w_apb_pslverr),
      .o_mmio_rd_data(w_mmio_rd_data),
      .o_mmio_ack    (w_mmio_ack),
      .o_apb_psel    (w_apb_psel),
      .o_apb_penable (w_apb_penable),
      .o_apb_pwrite  (w_apb_pwrite),
      .o_apb_paddr   (w_apb_paddr),
      .o_apb_pwdata  (w_apb_pwdata),
      .o_apb_pstrb   (w_apb_pstrb),
      .o_apb_pprot   (w_apb_pprot),
      .o_sts_err_set (w_sts_err_set)
  );

  // CSR slave (tool-generated, Asynchronous = 0): connected with i_slverr_en = 1 and i_protect_en = 0.
  // ctrl.start is set by i_start_req (write data 1, enable = i_start_req) and cleared by firmware.
  // sts.err is set by the APB master pulse; uart_tx.send is cleared by m_uart when it takes a byte.
  // o_ctrl_start, o_sts_err and o_sts_busy have no consumer: they are read back through APB only.
  // o_sts_done and o_result_label are the registered top-level status outputs.
  // REQ-024, REQ-026, REQ-027
  m_soc_csr u_soc_csr (
      .i_bus_clk              (i_clk_core),
      .i_bus_rstn             (w_rst_n_core),
      .i_paddr                (w_apb_paddr),
      .i_protect_en           (1'b0),
      .i_slverr_en            (1'b1),
      .i_pprot                (w_apb_pprot),
      .i_pwdata               (w_apb_pwdata),
      .i_pwrite               (w_apb_pwrite),
      .i_penable              (w_apb_penable),
      .i_psel                 (w_apb_psel),
      .i_pstrb                (w_apb_pstrb),
      .o_pslverr              (w_apb_pslverr),
      .o_pready               (w_apb_pready),
      .o_prdata               (w_apb_prdata),
      .o_ctrl_start           (w_ctrl_start_unused),
      .i_hw_wdata_ctrl_start  (1'b1),
      .i_hw_we_ctrl_start     (i_start_req),
      .o_sts_err              (w_sts_err_unused),
      .i_hw_wdata_sts_err     (1'b1),
      .i_hw_we_sts_err        (w_sts_err_set),
      .o_sts_done             (o_sts_done),
      .o_sts_busy             (w_sts_busy_unused),
      .o_result_label         (o_result_label),
      .i_cycles_cnt           (w_cycles_cnt),
      .i_uart_tx_busy         (w_uart_tx_busy),
      .o_uart_tx_send         (w_uart_tx_send),
      .i_hw_wdata_uart_tx_send(1'b0),
      .i_hw_we_uart_tx_send   (w_uart_tx_send_clr),
      .o_uart_tx_data         (w_uart_tx_data),
      .o_uart_cfg_baud_div    (w_uart_cfg_baud_div)
  );

  // UART transmitter: sends the CSR byte as 8N1 at the CSR baud divisor; the pin idles high.
  // REQ-027
  m_uart u_uart (
      .i_clk_core         (i_clk_core),
      .i_rst_n_core       (w_rst_n_core),
      .i_uart_tx_send     (w_uart_tx_send),
      .i_uart_tx_data     (w_uart_tx_data),
      .i_uart_cfg_baud_div(w_uart_cfg_baud_div),
      .o_uart_tx_busy     (w_uart_tx_busy),
      .o_uart_tx_send_clr (w_uart_tx_send_clr),
      .o_uart_tx          (o_uart_tx)
  );

endmodule

`default_nettype wire
