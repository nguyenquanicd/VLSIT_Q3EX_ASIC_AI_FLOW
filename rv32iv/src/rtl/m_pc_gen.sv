/*
 * Project      : rv32iv_s
 * Author       : VLSIT - Q3TUI
 * AI Flow      : VLSIT RTL Generator AI Automation Flow
 * AI Flow Page : https://github.com/nguyenquanicd/VLSIT_RTL_Generator_AI_Model
 * Date         : 2026-10-31
 * Description  : PC generation, branch/jump redirect and halt.
 * Parent       : m_cpu_top
 * REQ-IDs      : REQ-003, REQ-041, REQ-052, REQ-053
 */
`timescale 1ns / 1ps

module m_pc_gen #(
    // Parameter Description: width of the program counter and of the redirect target address.
    // Parameter values: fixed to 32 (RV32I byte address space); default is 32.
    // Parameter unit: bit
    localparam logic [31:0] LPARA_PC_W   = 32,
    // Parameter Description: sequential PC increment, the size of one instruction.
    // Parameter values: fixed to 4 (32-bit instructions, no compressed extension); default is 4.
    // Parameter unit: byte
    localparam logic [31:0] LPARA_PC_INC = 4
) (
    input  wire                   i_clk_core,
    input  wire                   i_rst_n_core,
    // Hold request from the hazard unit / vector dispatch / bus wait (whole-pipeline or IF-ID stall)
    input  wire                   i_stall,
    // Branch or jump resolved as taken in EX, with its target address
    input  wire                   i_redirect_taken,
    input  wire  [LPARA_PC_W-1:0] i_redirect_addr,
    // Decode-stage detection of an illegal instruction or an ebreak
    input  wire                   i_illegal,
    input  wire                   i_ebreak,
    // Current fetch address
    output logic [LPARA_PC_W-1:0] o_pc,
    // Core halted flag (sticky until reset)
    output logic                  o_halt,
    // Halt cause was an illegal instruction (0 for ebreak)
    output logic                  o_err_illegal
);

  // Internal signal declarations
  logic [LPARA_PC_W-1:0] reg_pc;
  logic [LPARA_PC_W-1:0] w_pc_nxt;
  logic [LPARA_PC_W-1:0] w_pc_plus_inc;
  logic                  reg_halt;
  logic                  reg_err_illegal;
  logic                  w_halt_commit;

  // Sequential next-PC: fetch address plus one instruction.
  assign w_pc_plus_inc = $bits(w_pc_plus_inc)'(reg_pc + LPARA_PC_INC);

  // Halt commit: an illegal instruction or ebreak in decode halts the core only when it is not
  // held by a stall and not on a wrong path (a taken branch in EX flushes IF/ID). Once halted
  // the request is ignored so the first cause is kept until reset.
  // REQ-052, REQ-053
  assign w_halt_commit = !reg_halt && !i_stall && !i_redirect_taken && (i_illegal || i_ebreak);

  // Next-PC selection: PC is held while halted, on the halt commit cycle and on a stall;
  // otherwise a taken branch/jump redirects to its target, else the PC advances by one
  // instruction (predict not-taken). Stall has priority: a branch held in EX re-presents
  // its redirect when the stall ends.
  // REQ-003, REQ-053
  always_comb begin : p_com_pc_nxt
    w_pc_nxt = reg_pc;
    if (reg_halt || w_halt_commit || i_stall) begin
      w_pc_nxt = reg_pc;
    end else if (i_redirect_taken) begin
      w_pc_nxt = i_redirect_addr;
    end else begin
      w_pc_nxt = w_pc_plus_inc;
    end
  end

  // PC and halt state: asynchronously reset to PC = 0, not halted and no error flag.
  // Halt is sticky; the error flag records the cause (illegal = 1, ebreak = 0) at commit.
  // REQ-041, REQ-052, REQ-053
  always_ff @(posedge i_clk_core, negedge i_rst_n_core) begin : p_ff_pc_halt
    if (!i_rst_n_core) begin
      reg_pc          <= '0;
      reg_halt        <= 1'b0;
      reg_err_illegal <= 1'b0;
    end else begin
      reg_pc <= w_pc_nxt;
      if (w_halt_commit) begin
        reg_halt        <= 1'b1;
        reg_err_illegal <= i_illegal;
      end
    end
  end

  // Output mapping of the registered PC and halt flags.
  // REQ-041, REQ-052, REQ-053
  assign o_pc          = reg_pc;
  assign o_halt        = reg_halt;
  assign o_err_illegal = reg_err_illegal;

endmodule
