# Changes to the generated `m_soc_csr`

`m_soc_csr.patch` is every change made to the module since the APB-CSR-Generator made it; the csr step applies it again whenever the tool makes the module again. Why, change by change:

## 2026-10-31T11:51
- lint fix: lint warning UNUSEDSIGNAL line 26: Bits of signal are not used: 'i_pprot'[2,0]; lint warning UNUSEDSIGNAL line 60: Bits of signal are not used: 'reg_pwdata'[31:16]

## 2026-10-31T14:06
- change request: From the simulation of the testbench (MMIO read PSLVERR, TC-059): The generated m_soc_csr raises PSLVERR for any access with PADDR[1:0] != 0, including reads (apb_slverr = ... | (|i_paddr[1:0]) | (~&i_pstrb & i_pwrite)). A sub-word or misaligned lw read of MMIO therefore gets PSLVERR and m_apb_master pulses o_sts_err_set. REQ-IF-001 / REQ-085 and 11.2 step 7 say reads never raise PSLVERR. The spec does not forbid editing m_soc_csr in place, so this is an rtl_bug for it. Patch m_soc_csr in place (keep it as a patch under src/rtl/csr/patches/, to be re-applied on regeneration): qualify the address-error term with the write flag, i.e. (|i_paddr[1:0]) & i_pwrite. Reads then complete without PSLVERR and keep the word-aligned decode. Writes with a misaligned address or PSTRB != 4'hF still give PSLVERR (REQ-ERR-002). Alternative: m_apb_master clears PADDR[1:0] for reads. | The checks 'MMIO reads must never raise PSLVERR' and 'o_sts_err_set pulsed although only reads were issued' fail because of the m_soc_csr read-PSLVERR bug above. The 'only x of 114 reads completed' line is the testbench last-store problem, see the tb_bug entry for this test. See the 'MMIO read PSLVERR' request for m_soc_csr.
