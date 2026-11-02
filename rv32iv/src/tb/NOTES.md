## tb_plan

- Requirement IDs are REQ-001..086 from schemas/structured_spec.md (not REQ-FUNC-*).
- Settled in spec: misaligned load = word>>(8*a) zero-fill; wrong-path illegal/ebreak no effect (REQ-084); MMIO reads never PSLVERR, sub-word reads only no-hang (REQ-085); unimplemented MMIO offset read 0/write ignored, sts.err unchecked (REQ-086); vsra masks shift to log2(SEW), vmv.x.s sign-extends; vm=0 and vle16/vse16 illegal; odd vs2 not checked.
- Excluded: 024,025,039,043,061,065,066,067,068,069,070,071,072,078.
- Open questions: held-high i_start_req (spec_gap); probes, elaboration build, expected-value source, reset latency, FSM force (design_choice).
- New TCs: TC-058 fsm recovery, TC-059 mmio subword reads, TC-060 unimplemented MMIO offsets.

## tb_top

- tb_top.sv was missing on disk and was rewritten in full from the earlier content plus: REQ-087 monitor (tb_vlat_short_cnt/tb_vlat_min, checked in mon_check_all), drain_halted() called by wait_halt() (>=8 cycles and cpu dmem req/apb psel idle 4 consecutive cycles, cap 64; tb_run_cycles taken at first o_halt cycle), chk_halted_stable() with internal drain (>=4 cycles / idle 4), host_cycle() comment fixed. TC-058 uses literal forces (no type()). Probe instance names: dut.u_cpu_top/u_vpu_top/u_apb_master.

## tb_g2

- tests/ was empty on disk (regenerated); TC-007..012 re-written from the plan. Pattern: preset result slots with dmem_fill(0xDEADBEEF/0xC0FFEE11), run_prog (drains after halt), check tb_run_hit/o_halt/o_err_illegal/tb_sts_err_events BEFORE res_rd, then slots, mon_check_all().
- TC-007: 36 branch cases with 2-instr shadow (x5 = 0 taken / 3 not taken), loops, jal/jalr link values via prog_here()/auipc. TC-008: 16 words x 13 loads + sb/sh/sw model. TC-009: misaligned load = word>>(8a) zero-fill; stores shifted, bytes beyond word dropped. TC-010: 8x8 mul pairs + rd=x0 + chains. TC-011: 12 illegal words, one program per reset. TC-012: directed forwarding/bypass/load-use/x0 cases with explicit expected values.

## tb_g1

- TC-001..006 written (src/tb/tests/). Conventions: programs via emit()/rv_*; check programs store CSR reads to DMEM (res area, TC-003 uses TB_RES_BASE+0x400 for check results); reads back via host (auto reset).
- TC-002 immediate async checks (before next clock edge) after rst_assert_offedge; start-latency bound 4 cycles via p_imem_addr change.
- TC-003 uses monitor vars m_v_busy/m_v_instr to catch vwredsum in flight; no mon_check_all (reset aborts legitimately trip APB/VPU monitors). Inference case emulated (firmware tested in TC-056/057).

## tb_g4

- TC-019..024 rewritten from scratch (tests dir was empty): 019 = 11-node jal chain over IMEM incl. 4095/4096 and 8189..8191; 020 = host/CPU DMEM row map (12 rows, CPU lw, CPU sw/sh/sb byte merge with neighbour check); 021 = vsetvli/vsetivli/x0-forms table + 1030 strip-mining (64x16 + 6); 022 = zero,zero keeps vl (e8 vl16 -> e32 stores 16 bytes; e8 vl4 -> e32 vadd.vx words; rd=x0 vl=7); 023 = 11 vle/vse cases with tail/byte-enable + early-ack probe; 024 = 15 unaligned cases, checks row part of o_mem_addr (bits [31:4]) via tb_vmem_log, low bits only TC_INFO, guard rows untouched.
- All rely on tb_top wait_halt() drain; checks of o_halt/err/sts events happen before the first host access.

## tb_g8

- TC-043..048 written. Notes: host_cycle() returns just after the edge that samples the request, so o_ld_rd_data then holds data of THAT call's request (tb_top header comment says 'previous' -- misleading).
- TC-043/044 use monitor log (tb_vlog_*) as oracle + firmware lw of cycles.cnt; TC-045 builds a node chain over IMEM (words incl. 0x7FFC) and writes with odd be/addr[1:0]; TC-046 per-row byte model with alias rows; TC-047 unique-value streams; TC-048 miss reads/writes + program survival.

## tb_g5

- TC-025..030 rewritten (files were gone). TC-025: IMEM code block at word 0x400 (addr 0x1000) proves ignored VPU stores; all-ones store data; MMIO CSRs/UART untouched. TC-026 pair layout v4=elem0..7, v5=elem8..15; TC-027 vwredsum at SEW=8 (vd[0] 32-bit, tail unchanged); TC-028 30 cases e8/e32 with RVV masking; TC-029 vnclip dst SEW = vtype SEW, source pair v2/v3, vxrm=0; TC-030 vmv.x.s consumed by next addi. All rely on run_prog()/wait_halt() draining the halted core.

## tb_g7

- TC-037..042 written (src/tb/tests/). Macros T37_/T38_/T40_ are #undef'd at file end.
- TC-037: 2 programs (A: reset values + write/readback incl. reserved bits, ends sts=3/label=9; B: ends sts=0/label=6), xfer count == emitted accesses; cycles.cnt only read (RO assumed).
- TC-038: manual run loop (not run_prog) samples PSEL vs CPU DMEM requests; checks tb_apb_log_* vs expected, min PSEL cycles >= 3 (REQ-029 read as SETUP+ACCESS+>=1 latency).
- TC-039: 7 partial writes per CSR (42), expected PSTRB = shifted CPU byte enables (sb 0001/1000, sh 0011/1100, sw+1 1110, +2 1100, +3 1000), pulses==PSLVERR==42; readback of all CSRs unchanged, sts=0x4.
- TC-040: events compared via tb_sts_err_events right after run (before res_rd resets it). Program 3 = PSLVERR then div -> 2 events.
- TC-041: phases announced on o_result_label; pulses 1/2/5 cycles; pulse during reset; pulse during delay loop is sticky.
- TC-042: one program per divisor, frames decoded by tb_uart_* monitor (tb_uart_baud set before run, reset to 0 at end); busy-after-send checked for baud>=8 only.

## tb_g6

- TC-031..036 written (tests/tc_031..036). Conventions: per-case run_prog (fresh reset), legal vsetvli e8 AVL=4 before the instruction under test, markers in result slots (prefill 0xC0FFEE11), vcmd delta via tb_vcmd_cnt, VPU mem delta via tb_vmem_xfer_cnt.
- TC-031 uses own cycle loop (busy window = xfer+1..done-1: no CPU dmem req / APB psel); assumes latency >= 5 (IDLE,DEC,RD,EXEC,WB,DONE), o_resp_rd_valid=1 only for vsetvli/vmv.x.s.
- vwredsum is exercised at SEW=8 (16-bit pair source, 32-bit sum), initial scalar set with vmv.s.x at e32.
- TC-036 also treats vsetvl, vwmulu/vwredsumu, vadd.vi, vsra.vv, vmax.vv, vnclip.wv, vwmul.vx, vmv.v.v/vmv.v.i and mask/segment/whole-register loads as illegal (anything outside the listed subset).

## tb_g10

- TC-056..060 rewritten (files were gone). 056/057: golden plusargs (+FW_HEX +DMEM_HEX +IMG_HEX +EXP_HEX +IMG_ADDR +LOGIT_ADDR, +IMG_IDX/+NIMG/+BAUD/+DMEM_WORDS) else TC_DV_TODO + failing 'DV_TODO' check. 058: literal forces, instance paths via TB_FSM_* macros. 059: 6 CSR words x (lb/lbu/lh/lhu at +0..3, lw +1..3), checks no PSLVERR pulse/no hang/regs unchanged. 060: unimplemented offsets 0x18/0x20/0x100/0xFFC read 0, writes ignored, defined regs and cycles.cnt unchanged.

## tb_g9

- TC-049/050/051/052/054/055 written. TC-049: noise runs without IMEM reload + identical time-to-halt. TC-050: per-cycle ownership checks + self-test of tb_ldv_cnt (one deliberate i_ld_en=1 cycle, then mon_clear()). TC-051/052: in-sim part only (predicate for C1..C3 + behavioural checks of derived params); per-set compile is done by the flow script, TC prints TC_INFO ELAB_EXPECT_FAIL/OK lines.
- TC-054: reference ISS generated alongside program (forward branches/jal skip regions); TC-055: vector reference model (32 regs x16B, 512B window), only legal SEW combos, vwredsum vd[0] 32-bit + tail undisturbed, vwmul pair layout as TC-026.

## tb_g1_triage

- Triage fixes: after run_prog()/wait_halt() always wait_cycles(>=6) before reading o_err_illegal/tb_sts_err_events, snap_status() or any host access (monitor counts o_err_illegal one edge late; older store may still be in MEM; host_begin resets DUT and clears counters). Applied to TC-005, TC-014, TC-035 (live-state checks now before first res_rd).
- TC-056/057: without golden plusargs they print TC_DV_TODO and fail with a 'DV_TODO' detail (result never PASS, marker lets triage separate it from DUT failures); regression script must pass +FW_HEX +DMEM_HEX +IMG_HEX +EXP_HEX +IMG_ADDR +LOGIT_ADDR.
- Open: sts.err proxy (o_err_illegal edge) hides that the CSR sts.err field is not set by an illegal instruction; would need a CSR field probe.

## tb_g4_triage

- TC-054/055/059/060: wait_cycles(8) drain after run_prog (last sw before ebreak lost to immediate host reset). NOTE tb_top wait_halt() still has no drain window; a central fix there (e.g. 6-8 cycles after o_halt) would make the per-TC waits unnecessary.
- TC-056/057: golden vectors default to <dir>/mnist_{fw,dmem,img,exp}.hex + <dir>/mnist.plusargs (IMG_ADDR, LOGIT_ADDR, DMEM_WORDS, NIMG, BAUD) when plusargs are absent; <dir> = +VEC_DIR or build/tb/programs (cwd, ../, ../../, ../../../) or the project build dir (absolute). DV_TODO failure only if files really missing.

## tb_g1_drain

- DEC-HALT-DRAIN triage: tb_top.sv could not be edited in this task (hook: only TC-001/003/006/015/016/017 + NOTES). Each of these TCs now has an inline post-halt drain loop after run_prog()/wait_halt() (>= 8 cycles and CPU data request + APB psel idle for 4 consecutive cycles, cap 64) before checks/snap_status()/host access. TC-015/016 call chk_halted_stable() only after the drain (still strict). tb_run_cycles is unchanged (taken at the first o_halt cycle).
- STILL OPEN for the tb_top owner: put drain_halted() in tb_top wait_halt() and make chk_halted_stable() drain internally (as requested in the triage); other TCs with a last store before ebreak (e.g. TC-049 noise loop, TC-004/005 style resets) rely on per-TC wait_cycles.

## tb_g6_rewrite

- TC-031..036 rewritten from the plan (files were absent). Conventions: per-case run_prog (fresh reset), legal vsetvli e8 AVL=4 before the form under test, markers in result slots (prefill 0xC0FFEE11), vcmd delta via tb_vcmd_cnt, VPU mem delta via tb_vmem_xfer_cnt, live-state checks (o_halt/o_err_illegal/tb_sts_err_events/chk_halted_stable) BEFORE the first res_rd. wait_halt() drains the halted core.
- TC-031: own run loop; stall window = m_v_busy && !done: no CPU dmem req / APB psel; 9 commands; rdv/rdd checked for vsetvli x2 and vmv.x.s; assumes o_resp_rd_valid=1 for those.
- TC-036: ~53 forms (vsetvl, vwmulu, vwredsumu, vadd.vi, vsra.vv, vmax.vv, vnclip.wv, vwmul.vx, vmv.v.v/i, unsupported ops, vm=0, vle/vse16/64, mask/whole-reg/ff/seg/strided/indexed).

## tb_g7_rewrite

- TC-037..042 (re)written (files were missing). TC-037 table-driven (macros T37_W/T37_R, undef at end), TC-038 manual run loop + monitor log (tb_apb_log_*), TC-039 42 partial writes (PSTRB per variant, 42 pulses), TC-040 3 programs (mon_clear before programs 2/3), TC-041 phases announced on o_result_label, TC-042 per-divisor programs decoded by tb_uart_* monitor (default divisor sends 3 bytes only). Depend on tb_top wait_halt/run_prog drain.

## tb_g1_triage2

- TC-020: rowsA[5] 2048 -> 2100 (result area TB_RES_BASE=0x1000_8000 is rows 2048..2059). TC-042: UART decoder queues (tb_uart_rx_*) cleared at the start of every divisor iteration (mon_clear only runs per TC).
- TC-056/057: default-vector fallback implemented: missing plusargs are taken from <dir>/mnist_{fw,dmem,img,exp}.hex + <dir>/mnist.plusargs (IMG_ADDR/LOGIT_ADDR hex, DMEM_WORDS/NIMG/BAUD dec; tokens with/without '+', separated by blank/newline/comma); <dir> = +VEC_DIR, build/tb/programs (cwd, ../, ../../, ../../../) or the absolute project build dir. DV_TODO only if the files do not exist. Format of mnist.plusargs assumed (not seen).
