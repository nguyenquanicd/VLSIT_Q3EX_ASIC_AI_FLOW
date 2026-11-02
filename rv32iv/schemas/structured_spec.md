# Requirements — rv32_vpu_mnist (spec rev 0.3)

Top module `m_soc_top` · 87 requirement(s) · 0 need review · 0 need your decision · gate: pending

## Functional (46)

| REQ | Score | Modules | SVA | Requirement |
|---|---|---|---|---|
| REQ-001 | 0.15 ✓ | m_cpu_top, m_cpu_dec, m_alu, m_lsu, m_branch_unit | property | The core shall implement RV32I base instructions (arithmetic/logic, lui, auipc, jumps, branches, lb lh lw lbu lhu sb sh sw) with a 5-stage in-order pipeline (IF, ID, EX, MEM, WB) at one instruction per cycle absent hazards. |
| REQ-002 | 0.20 ✓ | m_cpu_dec, m_mul | property | The core shall implement `mul` (Zmmul) returning the low 32 bits of the signed product and shall treat `div`, `divu`, `rem`, `remu` and `mulh*` as illegal instructions. |
| REQ-003 | 0.15 ✓ | m_hazard_unit, m_branch_unit, m_pc_gen, m_if_id_reg | property | The core shall resolve branches and jumps in EX, predict not-taken, and flush IF/ID when taken; it shall forward EX/MEM→EX and MEM/WB→EX, and insert exactly 1 bubble for a load followed by an immediate use. |
| REQ-084 | 0.15 ✓ | m_cpu_dec, m_cpu_top, m_hazard_unit, m_if_id_reg | property | A wrong-path instruction flushed by a taken branch or jump before it commits shall have no effect: an illegal instruction or `ebreak` in that shadow shall not halt the core and shall not set `o_err_illegal` or `sts.err`. |
| REQ-004 | 0.15 ✓ | m_vpu_csr, m_vpu_dec | property | The VPU shall execute `vsetvli`, `vsetivli` (including `vsetvli zero,zero,...`) with vl = min(AVL, VLMAX), VLMAX = (PARA_VLEN/SEW) x LMUL, and return vl through `o_resp_rd_data`. |
| REQ-005 | 0.20 ✓ | m_vpu_lsu, m_vpu_regfile | property | The VPU shall execute `vle8.v`, `vse8.v`, `vle32.v`, `vse32.v` as unit-stride accesses of exactly vl elements, leaving tail elements and non-written bytes unchanged (byte-enable on stores). |
| REQ-006 | 0.25 ✓ | m_lane_mul | property | The VPU shall execute `vwmul.vv` (INT8xINT8→INT16 signed, including -128 x -128 = 16384) writing a register pair. |
| REQ-007 | 0.20 ✓ | m_vpu_reduce | property | The VPU shall execute `vwredsum.vs` accumulating signed INT16 elements into a signed INT32 without overflow for up to 784 elements and write the sum plus the initial scalar (vs1[0]) to element 0 of the destination. |
| REQ-008 | 0.25 ✓ | m_lane_alu, m_lane_narrow, m_vpu_ctrl | property | The VPU shall execute `vadd.vv/vx`, `vsra.vi/vx`, `vmax.vx`, `vnclip.wi/wx`, `vmv.v.x`, `vmv.s.x`, `vmv.x.s`; `vnclip` shall saturate to the signed range of the destination element width with no wrap-around ([-32768, 32767] for 32→16, [-128, 127] for 16→8), using shift[4:0] for 32→16 and shift[3:0] for 16→8; `vsra` shall mask the shift amount to log2(SEW) bits and `vmv.x.s` shall sign-extend the element to 32 bits (RVV 1.0 semantics, also at SEW = 8); results shall match the golden model bit-for-bit. |
| REQ-009 | 0.15 ✓ | m_vpu_dispatch, m_hazard_unit, m_vpu_if | property | On a vector instruction the CPU shall send the instruction and rs1/rs2 values to the VPU and stall the whole pipeline until `o_resp_done`; one vector instruction shall execute at a time. |
| REQ-010 | 0.10 ✓ | m_imem | property | `m_imem` shall provide 32 KB (8192 x 32) with a synchronous 1-cycle read. |
| REQ-011 | 0.15 ✓ | m_dmem | property | `m_dmem` shall provide 256 KB, single port, PARA_VLEN bits wide, with byte enable and registered read data valid in the cycle after the read. |
| REQ-012 | 0.25 ✓ | m_uart, m_soc_csr | property | `m_uart` shall transmit one byte at 8N1 with baud divisor `uart_cfg.baud_div` when `uart_tx.send` is written 1, assert `uart_tx.busy` during transmission, and clear `send` when it takes the byte. |
| REQ-013 | 0.15 ✓ | m_vpu_perf, m_soc_csr | property | `m_vpu_perf` shall count `i_clk_core` cycles from vector-instruction start to done and present the value on `i_cycles_cnt`, which feeds `cycles.cnt`; the window is inclusive (counting starts at 1 in the cycle after the start pulse, so the start cycle is counted, and includes the done-pulse cycle); `m_csr_min` is a separate CPU-side counter and shall not feed `cycles.cnt`. |
| REQ-014 | 0.10 ✓ | m_soc_top | — | The system shall classify the image with a result bit-identical (logits and label) to the golden model for the delivered firmware and weights. |
| REQ-015 | 0.20 ✓ | m_soc_bus | property | The memory map shall be IMEM 0x0000_0000 (32 KB), DMEM 0x1000_0000 (256 KB), MMIO 0x2000_0000 (4 KB); `m_soc_bus` shall decode by address and mux the VPU and CPU memory ports. |
| REQ-027 | 0.10 ✓ | m_cpu_top, m_soc_csr, m_uart, m_soc_top | property | The status outputs `o_err_illegal`, `o_halt`, `o_sts_done` and `o_result_label` shall be registered level outputs in the core domain and reset to 0; `o_uart_tx` shall reset to 1 (idle high). |
| REQ-034 | 0.10 ✓ | m_soc_bus, m_hazard_unit | property | The CPU and the VPU shall never request DMEM in the same cycle, and the host shall never access DMEM when `i_rst_n_core` = 1. |
| REQ-035 | 0.05 ✓ | m_regfile | property | `x0` of `m_regfile` shall always read 0. |
| REQ-036 | 0.15 ✓ | m_vpu_ctrl | property | `m_vpu_ctrl` shall step IDLE → DEC (on `i_cmd_valid`) → RD → EXEC (one or more passes, load/store through `m_vpu_lsu`) → WB → DONE (pulse `o_resp_done`) → IDLE, with reset state IDLE and the 2 unused 3-bit codes recovering to IDLE. |
| REQ-037 | 0.10 ✓ | m_vpu_lsu | property | `m_vpu_lsu` shall step IDLE → REQ (assert `o_mem_req` with address) → WAIT → DONE (on `i_mem_ack`) → IDLE, with reset state IDLE (2-bit encoding, no unused codes). |
| REQ-038 | 0.10 ✓ | m_apb_master, m_uart | property | The `m_apb_master` (apbm: IDLE, SETUP, ACCESS) and `m_uart` (uart: IDLE, START, DATA, STOP) FSMs shall reset to IDLE and recover to IDLE from unused encodings. |
| REQ-041 | 0.10 ✓ | m_pc_gen, m_cpu_top, m_vpu_ctrl, m_vpu_lsu, m_apb_master, m_uart | property | After reset the PC shall be 0x0000_0000, the pipeline empty, all FSMs in IDLE, `o_halt` and `o_err_illegal` 0. |
| REQ-042 | 0.15 ✓ | m_host_ld, m_imem, m_dmem | property | Reset shall not gate the host port and shall not clear IMEM or DMEM contents. |
| REQ-043 | 0.05 ✓ | m_soc_top | — | Firmware `start.S` shall not clear DMEM. |
| REQ-044 | 0.10 ✓ | m_rst_sync, m_apb_master, m_soc_csr, m_vpu_ctrl, m_cpu_top | property | A reset during a running inference shall abort any in-flight instruction or APB transfer and reset the CSR registers and results, while keeping IMEM and DMEM contents. |
| REQ-052 | 0.15 ✓ | m_cpu_dec, m_cpu_top, m_pc_gen | property | An illegal instruction shall halt the core (`o_halt` = 1), assert `o_err_illegal` and set `sts.err`; the instruction shall not be dispatched to the VPU. |
| REQ-053 | 0.10 ✓ | m_cpu_top, m_pc_gen, m_hazard_unit | property | In the Halted state (entered on an illegal instruction or `ebreak`) the PC shall stop and the pipeline be drained; `o_halt` shall stay 1 until reset, with `o_err_illegal` = 1 if the cause was an illegal instruction and 0 for `ebreak`. |
| REQ-054 | 0.15 ✓ | m_cpu_dec | property | `m_cpu_dec` shall decode the supported Zve32x subset itself, including the SEW and LMUL fields of `vsetvli`/`vsetivli` immediates (only LMUL = 1 and SEW 8, 16, 32 are legal), and shall flag any other OP-V instruction as illegal before dispatch: only the exact forms of REQ-004, REQ-005, REQ-008 plus `vwmul.vv` and `vwredsum.vs` are legal, and every other form is illegal, including `vsetvl` (register form), `vwmulu`, `vwredsumu`, `vadd.vi`, `vsra.vv`, `vmax.vv`, `vnclip.wv`, `vwmul.vx`, `vmv.v.v`, `vmv.v.i`, masked forms (vm = 0), `vle16`/`vse16`, and mask, segment, whole-register and fault-only-first loads and stores; the `m_vpu_top` interface has no error response. |
| REQ-055 | 0.10 ✓ | m_soc_csr, m_apb_master | property | A partial (PSTRB != 4'b1111) or misaligned APB write to `m_soc_csr` shall produce PSLVERR and not modify any register; a misaligned MMIO store is a partial write and therefore sets `sts.err`. |
| REQ-056 | 0.10 ✓ | m_lsu, m_apb_master | property | `m_lsu` shall let `sb`/`sh` accesses to the MMIO region reach the APB master (not block them), which forwards the CPU byte enables to PSTRB, so that the resulting PSLVERR sets `sts.err`. |
| REQ-057 | 0.10 ✓ | m_soc_bus | property | A CPU access to an unmapped data address, including the IMEM range (0x0000_0000-0x0000_7FFF), shall return 0 on a read and ignore a write, with no error flag. |
| REQ-058 | 0.10 ✓ | m_vpu_lsu, m_soc_bus | property | When a VPU unit-stride access address is not row-aligned, the VPU shall ignore the low log2(PARA_VLEN/8) address bits and access the aligned row, without raising an error; only the row part of `o_mem_addr` is significant, and `m_vpu_top` may drive the ignored low bits unmodified or cleared (they are not checked). |
| REQ-059 | 0.25 ✓ | m_vpu_regfile, m_vpu_ctrl, m_lane_alu | property | For vector instructions, elements with index >= vl shall be left unchanged (tail-undisturbed) and the destination registers other than those written shall not change. |
| REQ-060 | 0.10 ✓ | m_lane_narrow | property | `vnclip` shall use rounding mode round-to-nearest-up (vxrm = 0), matching the golden model. |
| REQ-061 | 0.20 ✓ | m_dmem | property | A same-address read-during-write inside `m_dmem` shall return the old data (read-first). |
| REQ-073 | 0.10 ✓ | m_cpu_dec, m_cpu_top | property | `ebreak` shall halt the core (`o_halt` = 1, `o_err_illegal` = 0); `fence` shall execute as a NOP; `ecall` and all CSR and other SYSTEM opcodes shall be illegal instructions. |
| REQ-074 | 0.15 ✓ | m_cpu_dec | property | Vector instructions shall be legal only for these SEW combinations: `vwmul.vv` with SEW = 8 sources and 16-bit results; `vwredsum.vs` with 16-bit source elements and a 32-bit sum, reading element indexes below vl (up to PARA_VLEN/8 elements) from the register pair vs2/vs2+1; `vadd`, `vsra`, `vmax`, `vmv` at SEW = 32 and 8; `vnclip` in the steps 32→16 and 16→8. Any other SEW combination, or a widening-result `vd` that is not an even register, shall be an illegal instruction; only the widening-result `vd` is alignment-checked and an odd `vs2` of a wide source is not checked. |
| REQ-075 | 0.10 ✓ | m_lsu | property | Misaligned scalar loads and stores shall not trap: byte enables and data shall be shifted by addr[1:0] and bytes falling outside the word shall be dropped, with no word-crossing split; a misaligned load shall return word >> (8 x addr[1:0]) with the missing upper bytes zero-filled, then the normal sign or zero extension of the access width. |
| REQ-076 | 0.10 ✓ | m_regfile | property | `m_regfile` shall bypass a same-cycle write-back write to a read port (write-to-read bypass), with `x0` still reading 0. |
| REQ-077 | 0.15 ✓ | m_vpu_csr, m_vpu_dec | property | For `vsetvli zero,zero,...` the VPU shall keep vl and write the new SEW when the setting is legal (LMUL = 1, SEW 8/16/32), without a VLMAX-preservation check. |
| REQ-078 | 0.15 ✓ | m_vpu_csr | property | A request with an illegal vtype that reaches `m_vpu_csr` shall be ignored: vsew and vl are unchanged and the current vl is returned. |
| REQ-080 | 0.15 ✓ | m_vpu_dispatch | property | The scalar write-back valid for a vector instruction shall be the done pulse AND `o_resp_rd_valid`, so write-back occurs in the cycle the stall releases, with `o_rd_data` passed through from `o_resp_rd_data`. |
| REQ-081 | 0.15 ✓ | m_cpu_dec, m_hazard_unit, m_vpu_dispatch | property | `m_cpu_dec` shall assert the vector-valid signal only for a legal, unflushed instruction, and the stalled pipeline shall keep the instruction and rs1/rs2 stable until the done pulse. |
| REQ-082 | 0.15 ✓ | m_soc_bus | property | A VPU access to an address outside DMEM shall be acknowledged immediately, a read returns 0, a write is ignored and no error is raised. |
| REQ-083 | 0.20 ✓ | m_cpu_dec | property | A SEW-dependent vector instruction (`vadd`, `vsra`, `vmax`, `vmv`, `vnclip`, `vwmul`, `vwredsum`) shall be illegal until a legal `vsetvli`/`vsetivli` has been accepted (the shadow SEW is invalid after reset); `vle`/`vse` shall not be checked against vtype. |

## Interface (19)

| REQ | Score | Modules | SVA | Requirement |
|---|---|---|---|---|
| REQ-016 | 0.10 ✓ | m_apb_master | property | `m_apb_master` shall convert CPU data-bus accesses to the MMIO region into APB SETUP/ACCESS cycles and hold `i_dmem_ack` low until PREADY; for writes it shall forward the CPU byte enables to PSTRB and keep the low 2 address bits on PADDR, with PSTRB = 4'b1111 only for an aligned full-word access. |
| REQ-085 | 0.25 ✓ | m_apb_master, m_soc_csr | property | MMIO reads shall never raise PSLVERR (no PSTRB is forwarded for reads); a sub-word (`lb`, `lh`, `lbu`, `lhu`) or misaligned `lw` read of MMIO shall complete without hanging or halting the core, and its data and `sts.err` are not specified. |
| REQ-017 | 0.10 ✓ | m_apb_master, m_soc_csr | property | When PSLVERR is sampled with PREADY = 1, `m_apb_master` shall drive a 1-cycle pulse (`o_sts_err_set`) to the CSR hardware-write port of `sts.err`; the CPU shall see a normal `i_dmem_ack`. |
| REQ-018 | 0.10 ✓ | m_host_ld | property | When `i_ld_en` = 0, the `m_soc_bus` DMEM port shall pass to `m_dmem` unchanged through a combinational 2:1 mux (no added cycle), the IMEM write enable shall be 0 and other `i_ld_*` inputs shall be ignored. |
| REQ-019 | 0.10 ✓ | m_host_ld, m_imem | property | When `i_ld_en` = 1 and `i_ld_req` = 1 an IMEM write at `i_ld_addr[31:15]` = 0 shall write the whole word at index `i_ld_addr[14:2]` at that rising edge, ignoring `i_ld_byte_en`. |
| REQ-020 | 0.10 ✓ | m_host_ld, m_dmem | property | A DMEM access (`i_ld_addr[31:18]` = 14'h0400) shall address 32-bit lane `i_ld_addr[LB-1:2]` of row `i_ld_addr[17:LB]` (LB = log2(PARA_VLEN/8)) and a write shall change exactly the bytes enabled by `i_ld_byte_en`. |
| REQ-021 | 0.10 ✓ | m_host_ld | property | A host read shall return data on `o_ld_rd_data` exactly 1 cycle after the request; a read of IMEM, MMIO or an unmapped address shall return 0, and a write to MMIO or an unmapped address shall change nothing. |
| REQ-022 | 0.10 ✓ | m_host_ld | cover | The host port shall accept back-to-back accesses every cycle with no handshake. |
| REQ-023 | 0.15 ✓ | m_soc_top | assume | `i_ld_en` shall be 0 at every rising edge of `i_clk_core` where `i_rst_n_core` = 1; the testbench shall check this with an assertion. |
| REQ-024 | 0.10 ✓ | m_soc_top, m_soc_csr | static | `m_soc_csr` shall be connected with `i_slverr_en` = 1 and `i_protect_en` = 0 and be generated with Asynchronous = 0. |
| REQ-086 | 0.20 ✓ | m_soc_csr, m_apb_master | property | An access to an unimplemented offset inside the 4 KB MMIO window shall read 0 and ignore a write, shall not hang the core and shall not change any defined register; `sts.err` is not specified for such accesses. |
| REQ-025 | 0.10 ✓ | m_soc_top | static | `m_soc_top` shall provide the ports i_clk_core (1), i_rst_n_core (1), i_start_req (1), o_sts_done (1), o_result_label (4), o_uart_tx (1), o_err_illegal (1), o_halt (1), i_ld_en (1), i_ld_req (1), i_ld_wr_en (1), i_ld_addr (32), i_ld_byte_en (4), i_ld_wr_data (32), o_ld_rd_data (32); the port list shall be the same in every configuration. |
| REQ-026 | 0.10 ✓ | m_soc_top, m_soc_csr | property | A level 1 on `i_start_req` for at least 1 cycle shall set `ctrl.start` through the `i_hw_wdata_ctrl_start`/`i_hw_we_ctrl_start` ports of `m_soc_csr`; firmware clears it. |
| REQ-028 | 0.10 ✓ | m_apb_master | property | `m_apb_master` shall run the APB transfer as SETUP then ACCESS: `o_apb_psel` high from SETUP through ACCESS, `o_apb_penable` high in ACCESS only, address/control/write data stable from SETUP until completion; for writes `o_apb_pstrb` shall carry the CPU byte enables (4'b1111 only for an aligned full-word access); `o_apb_paddr` shall be the CPU address minus 0x2000_0000 with the low 2 bits being the CPU address bits; `o_apb_pprot` = 0; the transfer completes at the rising edge where `i_apb_pready` = 1 in ACCESS, when `i_apb_prdata` and `i_apb_pslverr` are sampled. |
| REQ-030 | 0.15 ✓ | m_apb_master | property | `m_apb_master` shall not start a new transfer until the previous one completes (one outstanding transfer). |
| REQ-031 | 0.15 ✓ | m_vpu_dispatch, m_vpu_if, m_vpu_ctrl | property | A CPU→VPU command shall transfer at the rising edge where `i_cmd_valid` = 1 and `o_cmd_ready` = 1; `i_cmd_valid` shall be held with stable `i_cmd_instr`/`i_cmd_rs1_data`/`i_cmd_rs2_data` until then, and `o_resp_done` shall be a 1-cycle pulse. |
| REQ-032 | 0.10 ✓ | m_vpu_ctrl, m_vpu_if | property | `o_cmd_ready` shall be asserted only when `m_vpu_ctrl` is in IDLE. |
| REQ-033 | 0.10 ✓ | m_vpu_lsu, m_soc_bus | property | On the VPU memory interface `o_mem_req` shall be held with stable address and data until `i_mem_ack`, and the low log2(PARA_VLEN/8) address bits shall be ignored so that every access is to a PARA_VLEN/8-byte-aligned row. |
| REQ-079 | 0.15 ✓ | m_vpu_lsu, m_soc_bus, m_dmem | assume | `m_vpu_lsu` shall sample `i_mem_ack` only in WAIT, so the memory side (`m_vpu_top`/DMEM path) shall answer at least 1 cycle after `o_mem_req` rises. |

## Timing (11)

| REQ | Score | Modules | SVA | Requirement |
|---|---|---|---|---|
| REQ-087 | 0.15 ✓ | m_vpu_ctrl, m_vpu_if | property | Every vector command, including `vsetvli`/`vsetivli`, shall pass through all six `m_vpu_ctrl` states (IDLE, DEC, RD, EXEC, WB, DONE), so the latency from command start to `o_resp_done` shall be at least 5 cycles. |
| REQ-029 | 0.20 ✓ | m_apb_master, m_hazard_unit | property | An MMIO access shall take at least 3 cycles (SETUP, ACCESS, plus at least 1 cycle of PREADY latency), and the CPU pipeline shall be stalled until the transfer completes. |
| REQ-039 | 0.05 ✓ | m_soc_top | — | The design shall use a single clock domain `core` (`i_clk_core`) with no CDC and no clock gating. |
| REQ-040 | 0.10 ✓ | m_rst_sync | property | `i_rst_n_core` shall be asserted asynchronously and released synchronously through `m_rst_sync`. |
| REQ-062 | 0.10 ✓ | m_vpu_ctrl, m_vpu_reduce | — | The vector instruction latency shall be multi-cycle and not fixed by this spec beyond the 5-cycle minimum (initiation interval = latency); `vwredsum` reduction latency is also unspecified and only result values are checked. |
| REQ-063 | 0.20 ✓ | m_uart | property | A UART byte shall take 10 bit times of `baud_div` clocks each (start, 8 data, stop), and `uart_tx.send` shall be cleared when the byte is taken. |
| REQ-064 | 0.10 ✓ | m_soc_top | — | The inference time shall be below 1,000,000 cycles per image (target). |
| REQ-065 | 0.05 ✓ | m_soc_top | — | The INT8 accuracy on the 10,000 test images shall be at least 96% (golden model). |
| REQ-066 | 0.15 ✓ | m_hazard_unit, m_branch_unit | — | A taken branch shall cost about 2 cycles of penalty (estimate). |
| REQ-067 | 0.20 ✓ | m_vpu_ctrl, m_hazard_unit | — | A dot-product iteration (vle8, vle8, vwmul.vv, vwredsum.vs) shall take about 6-10 cycles (goal, not hard). |
| REQ-068 | 0.10 ✓ | m_soc_top | — | The design shall target a 200 MHz `i_clk_core` (5 ns) on Arria 10 with Quartus (goal, not hard); closure is claimed only by STA with the SDC in `constraints/`. |

## Constraint (11)

| REQ | Score | Modules | SVA | Requirement |
|---|---|---|---|---|
| REQ-045 | 0.10 ✓ | m_vpu_top | static | `PARA_VLEN` shall be 128 or 256 (default 128) and divisible by PARA_LANE_COUNT x LPARA_LANE_W. |
| REQ-046 | 0.05 ✓ | m_vpu_top | static | `PARA_LANE_COUNT` shall be 1, 2, 4 or 8 (default 4). |
| REQ-047 | 0.10 ✓ | m_vpu_top | static | Illegal parameter values shall be rejected at elaboration with `$error` in a generate-`if`. |
| REQ-048 | 0.05 ✓ | m_vpu_top | static | Elaboration constraint C1: PARA_VLEN == 128 \|\| PARA_VLEN == 256. |
| REQ-049 | 0.05 ✓ | m_vpu_top | static | Elaboration constraint C2: PARA_LANE_COUNT shall be 1, 2, 4 or 8 (a power of 2). |
| REQ-050 | 0.05 ✓ | m_vpu_top | static | Elaboration constraint C3: PARA_VLEN % (PARA_LANE_COUNT * LPARA_LANE_W) == 0 (LPARA_LANE_W = 32). |
| REQ-051 | 0.10 ✓ | m_vpu_top, m_vpu_csr | static | The derived local parameters shall be LPARA_LANE_W = 32, LPARA_VREG_COUNT = 32, LPARA_ROW_LB = $clog2(PARA_VLEN/8) and LPARA_VL_W = $clog2(PARA_VLEN/8 + 1), the largest VLMAX being PARA_VLEN/8 (SEW = 8, LMUL = 1). |
| REQ-069 | 0.10 ✓ | m_soc_top | — | All RTL except `m_soc_csr` shall comply with REF-003. |
| REQ-070 | 0.10 ✓ | m_imem, m_dmem | — | RTL shall contain no `initial` block or `$readmemh`; memory initialization shall use the flow's init file inside the `m_imem`/`m_dmem` wrappers, and simulation shall load memories by testbench hierarchical reference. |
| REQ-071 | 0.05 ✓ | m_soc_top | — | Testbenches, models and SVA shall reside in `tb/`, outside the synthesis filelist. |
| REQ-072 | 0.05 ✓ | m_soc_top | — | A regression script shall report PASS/FAIL over instruction-, layer- and system-level tests. |

## Parameters

| Name | Type | Default | Range | Locked |
|---|---|---|---|---|
| `PARA_VLEN` | parameter logic [31:0] | `128` | 128, 256 |  |
| `PARA_LANE_COUNT` | parameter logic [31:0] | `4` | 1, 2, 4, 8 |  |

## Constraints

- **C1** `PARA_VLEN == 128 || PARA_VLEN == 256` PARA_VLEN is 128 or 256.
- **C2** `PARA_LANE_COUNT == 1 || PARA_LANE_COUNT == 2 || PARA_LANE_COUNT == 4 || PARA_LANE_COUNT == 8` PARA_LANE_COUNT is a power of 2 from 1 to 8.
- **C3** `PARA_VLEN % (PARA_LANE_COUNT * 32) == 0` PARA_VLEN is divisible by PARA_LANE_COUNT x LPARA_LANE_W (LPARA_LANE_W = 32).
- **C4** `PARA_VLEN >= PARA_LANE_COUNT * 32` Implied by C3 with PARA_VLEN > 0.

## Modules (leaves first)

- `m_rst_sync` — Reset synchronizer: async assert, synchronous release (2-flop). (2 REQ)
- `m_pc_gen` — Program counter generation and fetch redirect/halt. (4 REQ)
- `m_if_id_reg` — IF/ID pipeline register with flush/stall. (2 REQ)
- `m_cpu_dec` — ID-stage decoder: RV32I/Zmmul/Zve32x subset decode and illegal detection. (9 REQ)
- `m_imm_gen` — Immediate generator. (0 REQ)
- `m_regfile` — 32x32 register file with write-to-read bypass; x0 = 0. (2 REQ)
- `m_id_ex_reg` — ID/EX pipeline register. (0 REQ)
- `m_alu` — Integer ALU. (1 REQ)
- `m_branch_unit` — Branch/jump resolution in EX. (3 REQ)
- `m_mul` — 32-bit multiplier (low 32 bits, Zmmul). (1 REQ)
- `m_ex_mem_reg` — EX/MEM pipeline register. (0 REQ)
- `m_lsu` — Scalar load/store unit with misaligned handling. (3 REQ)
- `m_mem_wb_reg` — MEM/WB pipeline register. (0 REQ)
- `m_hazard_unit` — Forwarding, load-use bubble, stall and flush control. (9 REQ)
- `m_vpu_dispatch` — CPU-to-VPU command passthrough and write-back valid. (4 REQ)
- `m_csr_min` — Free-running CPU-side cycle counter. (0 REQ)
- `m_cpu_top` — Structural CPU wrapper: 5-stage RV32I+Zmmul pipeline with vector dispatch. (8 REQ)
- `m_vpu_if` — VPU command interface; latches instruction and operands. (4 REQ)
- `m_vpu_dec` — VPU vsetvli decode: new vl, SEW and scalar result. (2 REQ)
- `m_vpu_csr` — vl and vsew storage. (4 REQ)
- `m_vpu_ctrl` — VPU control FSM (IDLE, DEC, RD, EXEC, WB, DONE). (10 REQ)
- `m_vpu_regfile` — 32 x PARA_VLEN vector register file. (2 REQ)
- `m_vpu_lsu` — VPU memory FSM (IDLE, REQ, WAIT, DONE). (6 REQ)
- `m_lane_alu` — Lane add/shift/max/move ALU. (2 REQ)
- `m_lane_mul` — Lane widening INT8 multiplier. (1 REQ)
- `m_lane_narrow` — Lane vnclip narrowing with saturation. (2 REQ)
- `m_vpu_lane` — Lane datapath, instantiated PARA_LANE_COUNT times. (0 REQ)
- `m_vpu_reduce` — vwredsum reduction unit. (2 REQ)
- `m_vpu_perf` — Vector-instruction cycle counter driving cycles.cnt. (1 REQ)
- `m_vpu_top` — Structural VPU wrapper (Zve32x subset). (7 REQ)
- `m_soc_bus` — Address decode and CPU/VPU memory mux; MMIO routing. (7 REQ)
- `m_host_ld` — Host load port: DMEM 2:1 mux and IMEM write. (6 REQ)
- `m_imem` — 32 KB instruction memory wrapper. (4 REQ)
- `m_dmem` — 256 KB single-port data memory wrapper, PARA_VLEN wide. (6 REQ)
- `m_apb_master` — APB4 requester for MMIO accesses; pulses sts.err on PSLVERR. (12 REQ)
- `m_soc_csr` — Tool-generated APB4 CSR slave. (10 REQ)
- `m_uart` — UART 8N1 transmitter. (5 REQ)
- `m_soc_top` — Structural top of the MNIST inference SoC. (14 REQ)
