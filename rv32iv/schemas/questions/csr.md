# Open questions — CSR (APB-CSR-Generator)

_No open questions._

# Closed

- **CS1** The spec gives the register and field names (section 11.2, ASM-011) but no offsets, because the CSR workbook is not authored yet. What register offsets should be used? → Sequential word offsets in the order of section 11.2: ctrl 0x00, sts 0x04, result 0x08, cycles 0x0C, uart_tx 0x10, uart_cfg 0x14. _(default accepted)_
- **CS2** The spec gives no bit positions or widths for the fields. Are the bit positions and widths right: sts.busy/done/err at bits 0/1/2, uart_tx.data at [7:0] with send at bit 8 and busy at bit 9, baud_div 16 bits, cycles.cnt 32 bits? → Bit positions as listed in the register map; baud_div 16 bits, enough for the reset value 0x06C8; label 4 bits as o_result_label[3:0]; cnt 32 bits. _(default accepted)_
- **CS3** Should uart_tx.send be modelled as rwi (software writes 1, m_uart clears it through the hardware-write port)? The tool has no write-only self-clearing pulse type, and REQ-012 says send is cleared when the byte is taken. → rwi with hardware clearing: i_hw_we_uart_tx_send and i_hw_wdata_uart_tx_send = 0 when m_uart takes the byte. _(default accepted)_
- **CS4** Should sts.done and sts.busy be plain rw, written only by firmware? Spec 11.2 says firmware sets and clears them, and no hardware source is described. → rw for both; no hardware-write ports. _(default accepted)_

_Answer with `q3tui answer <ID> "..."` or in the TUI (Questions tab)._
