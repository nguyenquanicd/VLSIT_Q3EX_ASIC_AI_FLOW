# Open questions — Requirements (spec parser)

_No open questions._

# Closed

- **Q-P13** The CSR workbook (REF-005) is not yet authored, so sheet name and revision are TBD. Shall RTL and firmware use the interim map of ASM-014 (ctrl 0x00, sts 0x04, result 0x08, cycles 0x0C, uart_tx 0x10, uart_cfg 0x14) until the workbook replaces it? → Yes: use the interim map of ASM-014; regenerate m_soc_csr and update firmware when the workbook is authored. _(default accepted)_
- **Q-P14** Which Quartus version and FPGA part (10AXF40GAA GX vs GT) shall be used for synthesis and STA scripts? → Quartus Prime Pro 25.1 with the Arria 10 GX part; to be reconfirmed (DEP-002). _(default accepted)_

_Answer with `q3tui answer <ID> "..."` or in the TUI (Questions tab)._
