`default_nettype none
/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : APB4 requester for MMIO accesses; pulses sts.err on PSLVERR.
 *                FSM apbm (IDLE, SETUP, ACCESS). Converts a CPU MMIO access
 *                from m_soc_bus into an APB SETUP/ACCESS transfer and holds the CPU ack low until
 *                PREADY. Address, control, byte enables and write data are captured when the
 *                transfer starts and stay stable from SETUP until completion. Only one transfer
 *                is outstanding: a new transfer starts from IDLE only. PSLVERR sampled with
 *                PREADY = 1 is reported as a 1-cycle pulse on o_sts_err_set (hardware write of
 *                sts.err); the CPU sees a normal ack. A reset aborts any in-flight transfer.
 * Parent       : m_soc_top
 * REQ-IDs      : REQ-016, REQ-017, REQ-028, REQ-029, REQ-030, REQ-038, REQ-041, REQ-044,
 *                REQ-055, REQ-056, REQ-085, REQ-086
 */
`timescale 1ns / 1ps

module m_apb_master #(
    // Width of the CPU data bus and of the APB data buses.
    localparam logic [31:0] LPARA_XLEN       = 32,
    // Number of byte lanes of the CPU data bus (width of PSTRB).
    localparam logic [31:0] LPARA_WORD_BYTES = LPARA_XLEN / 8,
    // Width of the APB byte address (MMIO window offset).
    localparam logic [31:0] LPARA_PADDR_W    = 16,
    // Width of PPROT.
    localparam logic [31:0] LPARA_PPROT_W    = 3,
    // MMIO base address, subtracted from the CPU address to form PADDR.
    localparam logic [31:0] LPARA_MMIO_BASE  = 32'h2000_0000
) (
    input  wire                         i_clk_core,
    input  wire                         i_rst_n_core,
    // MMIO request from m_soc_bus: held stable by the CPU until o_mmio_ack.
    input  wire                         i_mmio_req,
    input  wire                         i_mmio_wr_en,
    input  wire  [LPARA_WORD_BYTES-1:0] i_mmio_byte_en,
    input  wire  [      LPARA_XLEN-1:0] i_mmio_addr,
    input  wire  [      LPARA_XLEN-1:0] i_mmio_wr_data,
    // APB completer response.
    input  wire  [      LPARA_XLEN-1:0] i_apb_prdata,
    input  wire                         i_apb_pready,
    input  wire                         i_apb_pslverr,
    // MMIO response to m_soc_bus (ack is the CPU i_dmem_ack source for MMIO accesses).
    output logic [      LPARA_XLEN-1:0] o_mmio_rd_data,
    output logic                        o_mmio_ack,
    // APB requester outputs.
    output logic                        o_apb_psel,
    output logic                        o_apb_penable,
    output logic                        o_apb_pwrite,
    output logic [   LPARA_PADDR_W-1:0] o_apb_paddr,
    output logic [      LPARA_XLEN-1:0] o_apb_pwdata,
    output logic [LPARA_WORD_BYTES-1:0] o_apb_pstrb,
    output logic [   LPARA_PPROT_W-1:0] o_apb_pprot,
    // 1-cycle pulse to the hardware-write port of sts.err.
    output logic                        o_sts_err_set
);

  // FSM states: IDLE until an MMIO request arrives, SETUP (PSEL only) for one cycle, then ACCESS
  // (PSEL and PENABLE) until PREADY. The unused encoding 2'b11 recovers to ENUM_ST_IDLE.
  typedef enum logic [1:0] {
    ENUM_ST_IDLE   = 2'b00,
    ENUM_ST_SETUP  = 2'b01,
    ENUM_ST_ACCESS = 2'b10
  } apbm_state_type_def;

  apbm_state_type_def                        reg_fsm_apbm_current_state;
  apbm_state_type_def                        w_fsm_apbm_nxt_state;

  logic                                      w_start;
  logic                                      w_complete;
  logic               [   LPARA_PADDR_W-1:0] w_paddr_nxt;
  logic               [LPARA_WORD_BYTES-1:0] w_pstrb_nxt;
  logic                                      w_aligned;
  logic                                      w_full_be;
  logic                                      reg_pwrite;
  logic               [   LPARA_PADDR_W-1:0] reg_paddr;
  logic               [      LPARA_XLEN-1:0] reg_pwdata;
  logic               [LPARA_WORD_BYTES-1:0] reg_pstrb;
  logic                                      reg_err_set;

  // Transfer control: a transfer starts only from IDLE (one outstanding transfer) and completes
  // in the ACCESS cycle where PREADY = 1, which gives at least SETUP + ACCESS + PREADY latency.
  assign w_start    = (reg_fsm_apbm_current_state == ENUM_ST_IDLE) & i_mmio_req;
  assign w_complete = (reg_fsm_apbm_current_state == ENUM_ST_ACCESS) & i_apb_pready;
  // REQ-016, REQ-029, REQ-030

  // Next-state logic: IDLE -> SETUP on a request, SETUP -> ACCESS unconditionally, ACCESS -> IDLE
  // on PREADY. Unused encodings recover to IDLE.
  always_comb begin : p_com_apbm_nxt
    w_fsm_apbm_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_apbm_current_state)
      ENUM_ST_IDLE: begin
        if (i_mmio_req) begin
          w_fsm_apbm_nxt_state = ENUM_ST_SETUP;
        end else begin
          w_fsm_apbm_nxt_state = ENUM_ST_IDLE;
        end
      end
      ENUM_ST_SETUP: begin
        w_fsm_apbm_nxt_state = ENUM_ST_ACCESS;
      end
      ENUM_ST_ACCESS: begin
        if (i_apb_pready) begin
          w_fsm_apbm_nxt_state = ENUM_ST_IDLE;
        end else begin
          w_fsm_apbm_nxt_state = ENUM_ST_ACCESS;
        end
      end
      default: begin
        w_fsm_apbm_nxt_state = ENUM_ST_IDLE;
      end
    endcase
  end
  // REQ-028, REQ-029, REQ-030, REQ-038

  // FSM state: asynchronous active-low reset to IDLE, so a reset aborts any transfer.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_apbm_state
    if (!i_rst_n_core) begin
      reg_fsm_apbm_current_state <= ENUM_ST_IDLE;
    end else begin
      reg_fsm_apbm_current_state <= w_fsm_apbm_nxt_state;
    end
  end
  // REQ-038, REQ-041, REQ-044

  // PADDR and PSTRB sources. PADDR is the CPU address minus the MMIO base with the low 2 bits kept
  // visible to the completer. PSTRB carries the CPU byte enables for writes (0 for reads); the
  // all-ones value is only allowed for an aligned access, so a misaligned full-word write is made
  // partial (bit 0 cleared) and the completer answers PSLVERR. A misaligned MMIO store is thus a
  // partial write and sets sts.err through the error pulse. No PSTRB is forwarded for reads
  // (PSTRB = 0), so an MMIO read never raises PSLVERR; sub-word or misaligned reads are plain
  // word reads at the APB level and complete on PREADY without hanging the core.
  assign w_aligned   = (i_mmio_addr[1:0] == 2'b00);
  assign w_full_be   = (i_mmio_byte_en == {LPARA_WORD_BYTES{1'b1}});
  assign w_paddr_nxt = LPARA_PADDR_W'(i_mmio_addr - LPARA_MMIO_BASE);

  always_comb begin : p_com_pstrb
    w_pstrb_nxt = '0;
    if (i_mmio_wr_en) begin
      if (w_full_be & ~w_aligned) begin
        w_pstrb_nxt = {i_mmio_byte_en[LPARA_WORD_BYTES-1:1], 1'b0};
      end else begin
        w_pstrb_nxt = i_mmio_byte_en;
      end
    end
  end
  // REQ-016, REQ-028, REQ-055, REQ-056, REQ-085

  // Request capture: taken when the transfer starts so that address, control and write data are
  // stable from SETUP until completion, as APB requires. Reset to 0 as the APB outputs idle at 0.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_apbm_req
    if (!i_rst_n_core) begin
      reg_pwrite <= 1'b0;
      reg_paddr  <= '0;
      reg_pwdata <= '0;
      reg_pstrb  <= '0;
    end else if (w_start) begin
      reg_pwrite <= i_mmio_wr_en;
      reg_paddr  <= w_paddr_nxt;
      reg_pwdata <= i_mmio_wr_data;
      reg_pstrb  <= w_pstrb_nxt;
    end
  end
  // REQ-016, REQ-028, REQ-044

  // Error pulse: PSLVERR sampled with PREADY = 1 in ACCESS gives a 1-cycle pulse (registered, in
  // the cycle after completion). The state returns to IDLE in that cycle, so it cannot repeat.
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_apbm_err
    if (!i_rst_n_core) begin
      reg_err_set <= 1'b0;
    end else begin
      reg_err_set <= w_complete & i_apb_pslverr;
    end
  end
  // REQ-017, REQ-044

  // APB outputs: PSEL from SETUP through ACCESS, PENABLE in ACCESS only, PPROT fixed to 0.
  assign o_apb_psel    = (reg_fsm_apbm_current_state == ENUM_ST_SETUP)
                       | (reg_fsm_apbm_current_state == ENUM_ST_ACCESS);
  assign o_apb_penable = (reg_fsm_apbm_current_state == ENUM_ST_ACCESS);
  assign o_apb_pwrite = reg_pwrite;
  assign o_apb_paddr = reg_paddr;
  assign o_apb_pwdata = reg_pwdata;
  assign o_apb_pstrb = reg_pstrb;
  assign o_apb_pprot = '0;
  assign o_sts_err_set = reg_err_set;
  // REQ-016, REQ-017, REQ-028

  // CPU response: ack and read data only in the completion cycle, so the CPU stays stalled until
  // PREADY. PSLVERR does not change the ack (the CPU sees a normal completion). Every access,
  // including one to an unimplemented offset in the MMIO window (the completer reads 0 / ignores
  // the write) or a sub-word / misaligned read, completes on PREADY, so the core never hangs.
  assign o_mmio_ack = w_complete;
  assign o_mmio_rd_data = w_complete ? i_apb_prdata : '0;
  // REQ-016, REQ-017, REQ-029, REQ-085, REQ-086

endmodule
`default_nettype wire
