# Open questions — RISC-V + VPU MNIST Inference System (rv32_vpu_mnist) — Block Specification

_No open questions._

# Closed

- **Q-S1** How many cycles shall `vwredsum` (reduction across lanes) take? → Multi-cycle, not fixed by this spec; the golden model checks values only, not latency _(default accepted)_
- **Q-S2** Does `vnclip` use rounding mode vxrm = 0 (round-to-nearest-up) and is the golden model written accordingly? → vxrm = 0 _(default accepted)_
- **Q-S3** Shall `sb`/`sh` to MMIO be blocked in `m_lsu` or reach APB and raise `sts.err`? → Reach APB, `PSLVERR` sets `sts.err` _(default accepted)_
- **Q-S4** How is `i_start_req` sampled (level or rising edge) and what clears it? → Level 1 for at least 1 cycle sets `ctrl.start`; firmware clears it _(default accepted)_
- **Q-S5** Is the memory initialization via the flow's init file acceptable under rule P2, and which Quartus mechanism is used? → Init file inside the wrappers, acceptable under P2 _(default accepted)_
- **Q-S6** Are LMUL 2 and 4 required in v0.1, and what is the response to an unsupported `vsetvli` setting? → LMUL = 1 only; unsupported settings are treated as an illegal instruction _(default accepted)_
- **Q-S7** Does the tool-generated `m_soc_csr` stay as a temporary rule exception, and who approves the waiver? → Temporary exception, kept in `csr/`, waived in lint _(default accepted)_

_Answer with `q3tui answer <ID> "..."` or in the TUI (Questions tab)._
