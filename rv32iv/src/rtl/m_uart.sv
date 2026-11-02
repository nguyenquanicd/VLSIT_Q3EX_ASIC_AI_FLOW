/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : UART 8N1 transmitter with FSM uart (IDLE, START, DATA, STOP).
 * Parent       : m_soc_top (u_uart)
 * REQ-IDs      : REQ-012, REQ-027, REQ-038, REQ-041, REQ-063
 */
`timescale 1ns / 1ps
`default_nettype none

module m_uart #(
    localparam logic [31:0] LPARA_DATA_W = 8,
    localparam logic [31:0] LPARA_BAUD_W = 16,
    localparam logic [31:0] LPARA_BIT_W  = $clog2(LPARA_DATA_W)
) (
    input wire i_clk_core,
    input wire i_rst_n_core,
    input wire i_uart_tx_send,
    input wire [LPARA_DATA_W-1:0] i_uart_tx_data,
    input wire [LPARA_BAUD_W-1:0] i_uart_cfg_baud_div,
    output logic o_uart_tx_busy,
    output logic o_uart_tx_send_clr,
    output logic o_uart_tx
);

  // FSM states: idle until uart_tx.send is seen, then start bit, 8 data bits (LSB first),
  // stop bit. The 3-bit encoding leaves unused codes that recover to ENUM_ST_IDLE.
  typedef enum logic [2:0] {
    ENUM_ST_IDLE  = 3'b000,
    ENUM_ST_START = 3'b001,
    ENUM_ST_DATA  = 3'b010,
    ENUM_ST_STOP  = 3'b100
  } uart_state_type_def;

  // Internal signal declarations
  uart_state_type_def                    reg_fsm_uart_current_state;
  uart_state_type_def                    w_fsm_uart_nxt_state;

  logic               [LPARA_BAUD_W-1:0] reg_baud_cnt;
  logic               [LPARA_BAUD_W-1:0] w_baud_cnt_nxt;
  logic               [LPARA_BAUD_W-1:0] reg_baud_div;
  logic               [LPARA_BAUD_W-1:0] w_baud_div_nxt;
  logic               [LPARA_DATA_W-1:0] reg_shift;
  logic               [LPARA_DATA_W-1:0] w_shift_nxt;
  logic               [ LPARA_BIT_W-1:0] reg_bit_idx;
  logic               [ LPARA_BIT_W-1:0] w_bit_idx_nxt;
  logic                                  reg_tx;
  logic                                  w_tx_nxt;

  logic                                  w_take;
  logic                                  w_bit_end;
  logic                                  w_last_bit;
  logic               [LPARA_BAUD_W-1:0] w_load_new;
  logic               [LPARA_BAUD_W-1:0] w_load_reg;

  // Byte take: in IDLE a pending send request is accepted and uart_tx.send is cleared with a
  // one-cycle hardware write (the CSR gives a software write priority over this clear).
  // REQ-012, REQ-063
  assign w_take = (reg_fsm_uart_current_state == ENUM_ST_IDLE) & i_uart_tx_send;

  // Bit-time bookkeeping: reg_baud_cnt holds the clocks left in the current bit, so each bit
  // lasts baud_div clocks; a divisor of 0 is treated as 1 clock per bit.
  // REQ-063
  assign w_bit_end = (reg_baud_cnt == '0);
  assign w_last_bit = (reg_bit_idx == $bits(reg_bit_idx)'(LPARA_DATA_W - 32'd1));
  assign w_load_new = (i_uart_cfg_baud_div == '0) ? '0 : $bits(
      w_load_new
  )'(i_uart_cfg_baud_div - 1'b1);
  assign w_load_reg = (reg_baud_div == '0) ? '0 : $bits(w_load_reg)'(reg_baud_div - 1'b1);

  // Output mapping: busy covers a pending byte as well as the frame in flight so software
  // polling right after writing send never sees a gap; the pin comes straight from a flop.
  // REQ-012, REQ-027
  assign o_uart_tx_busy = (reg_fsm_uart_current_state != ENUM_ST_IDLE) | i_uart_tx_send;
  assign o_uart_tx_send_clr = w_take;
  assign o_uart_tx = reg_tx;

  // FSM next state: IDLE -> START on take, START -> DATA -> STOP after one bit time each
  // (8 data bits), STOP -> IDLE. Unused encodings recover to IDLE.
  // REQ-038, REQ-063
  always_comb begin : p_com_fsm_uart
    w_fsm_uart_nxt_state = ENUM_ST_IDLE;
    case (reg_fsm_uart_current_state)
      ENUM_ST_IDLE: begin
        if (w_take) w_fsm_uart_nxt_state = ENUM_ST_START;
      end
      ENUM_ST_START: begin
        if (w_bit_end) w_fsm_uart_nxt_state = ENUM_ST_DATA;
        else w_fsm_uart_nxt_state = ENUM_ST_START;
      end
      ENUM_ST_DATA: begin
        if (w_bit_end & w_last_bit) w_fsm_uart_nxt_state = ENUM_ST_STOP;
        else w_fsm_uart_nxt_state = ENUM_ST_DATA;
      end
      ENUM_ST_STOP: begin
        if (w_bit_end) w_fsm_uart_nxt_state = ENUM_ST_IDLE;
        else w_fsm_uart_nxt_state = ENUM_ST_STOP;
      end
      default: w_fsm_uart_nxt_state = ENUM_ST_IDLE;
    endcase
  end

  // Datapath next values: on take the byte and divisor are captured and the start bit (0) is
  // driven; in DATA the next LSB is moved to the pin at every bit boundary; the stop bit (1)
  // follows the last data bit and the line idles high.
  // REQ-012, REQ-063
  always_comb begin : p_com_datapath
    w_baud_cnt_nxt = reg_baud_cnt;
    w_baud_div_nxt = reg_baud_div;
    w_shift_nxt    = reg_shift;
    w_bit_idx_nxt  = reg_bit_idx;
    w_tx_nxt       = reg_tx;
    case (reg_fsm_uart_current_state)
      ENUM_ST_IDLE: begin
        w_tx_nxt = 1'b1;
        if (w_take) begin
          w_baud_cnt_nxt = w_load_new;
          w_baud_div_nxt = i_uart_cfg_baud_div;
          w_shift_nxt    = i_uart_tx_data;
          w_bit_idx_nxt  = '0;
          w_tx_nxt       = 1'b0;
        end
      end
      ENUM_ST_START: begin
        if (w_bit_end) begin
          w_baud_cnt_nxt = w_load_reg;
          w_tx_nxt       = reg_shift[0];
          w_shift_nxt    = {1'b0, reg_shift[LPARA_DATA_W-1:1]};
        end else begin
          w_baud_cnt_nxt = $bits(w_baud_cnt_nxt)'(reg_baud_cnt - 1'b1);
        end
      end
      ENUM_ST_DATA: begin
        if (w_bit_end) begin
          w_baud_cnt_nxt = w_load_reg;
          if (w_last_bit) begin
            w_tx_nxt = 1'b1;
          end else begin
            w_tx_nxt      = reg_shift[0];
            w_shift_nxt   = {1'b0, reg_shift[LPARA_DATA_W-1:1]};
            w_bit_idx_nxt = $bits(w_bit_idx_nxt)'(reg_bit_idx + 1'b1);
          end
        end else begin
          w_baud_cnt_nxt = $bits(w_baud_cnt_nxt)'(reg_baud_cnt - 1'b1);
        end
      end
      ENUM_ST_STOP: begin
        w_tx_nxt = 1'b1;
        if (w_bit_end) w_baud_cnt_nxt = '0;
        else w_baud_cnt_nxt = $bits(w_baud_cnt_nxt)'(reg_baud_cnt - 1'b1);
      end
      default: begin
        w_tx_nxt       = 1'b1;
        w_baud_cnt_nxt = '0;
        w_bit_idx_nxt  = '0;
      end
    endcase
  end

  // State registers: all asynchronously reset; FSM resets to IDLE and the pin to 1 (idle high).
  // REQ-027, REQ-038, REQ-041
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_uart
    if (!i_rst_n_core) begin
      reg_fsm_uart_current_state <= ENUM_ST_IDLE;
      reg_baud_cnt               <= '0;
      reg_baud_div               <= '0;
      reg_shift                  <= '0;
      reg_bit_idx                <= '0;
      reg_tx                     <= 1'b1;
    end else begin
      reg_fsm_uart_current_state <= w_fsm_uart_nxt_state;
      reg_baud_cnt               <= w_baud_cnt_nxt;
      reg_baud_div               <= w_baud_div_nxt;
      reg_shift                  <= w_shift_nxt;
      reg_bit_idx                <= w_bit_idx_nxt;
      reg_tx                     <= w_tx_nxt;
    end
  end

endmodule

`default_nettype wire
