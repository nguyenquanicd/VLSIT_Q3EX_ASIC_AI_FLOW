# Test results (released RTL as the DUT)

Status is read from the simulator log of each run (`schemas/dv_evidence.json`).

| Test | Name | Requirements | Status | Note |
|---|---|---|---|---|
| TC-001 | `reset_values` | REQ-041, REQ-027 | PASS |  |
| TC-002 | `reset_async_assert_sync_release` | REQ-040, REQ-027 | PASS |  |
| TC-003 | `reset_during_activity_abort` | REQ-044, REQ-042, REQ-041 | PASS |  |
| TC-004 | `reset_keeps_memories_host_active` | REQ-042, REQ-021 | PASS |  |
| TC-005 | `reset_recovers_from_halt` | REQ-041, REQ-052, REQ-053 | PASS |  |
| TC-006 | `rv32i_alu_ops` | REQ-001 | PASS |  |
| TC-007 | `branches_and_jumps` | REQ-001, REQ-003 | PASS |  |
| TC-008 | `load_store_aligned` | REQ-001, REQ-011, REQ-015 | PASS |  |
| TC-009 | `load_store_misaligned_no_trap` | REQ-075, REQ-001 | PASS |  |
| TC-010 | `mul_zmmul` | REQ-002 | PASS |  |
| TC-011 | `illegal_scalar_div_mulh` | REQ-002, REQ-052, REQ-053 | PASS |  |
| TC-012 | `forwarding_and_regfile_bypass` | REQ-003, REQ-001, REQ-035, REQ-076 | PASS |  |
| TC-013 | `pipeline_timing_differential` | REQ-001, REQ-003, REQ-011 | PASS |  |
| TC-014 | `illegal_in_wrong_path_not_halting` | REQ-084, REQ-052, REQ-073, REQ-003 | PASS |  |
| TC-015 | `ebreak_halt_fence_nop` | REQ-073, REQ-053 | PASS |  |
| TC-016 | `illegal_system_opcodes` | REQ-073, REQ-052, REQ-053, REQ-027 | PASS |  |
| TC-017 | `imem_range_data_access_unmapped` | REQ-057, REQ-015 | PASS |  |
| TC-018 | `unmapped_cpu_addresses` | REQ-015, REQ-057 | PASS |  |
| TC-019 | `imem_depth_and_fetch` | REQ-010, REQ-019 | PASS |  |
| TC-020 | `dmem_depth_and_row_map` | REQ-011, REQ-015, REQ-020, REQ-051 | PASS |  |
| TC-021 | `vsetvli_vl_computation` | REQ-004, REQ-051 | PASS |  |
| TC-022 | `vsetvli_zero_zero_keeps_vl` | REQ-077, REQ-004 | PASS |  |
| TC-023 | `vle_vse_unit_stride` | REQ-005, REQ-011, REQ-059, REQ-033, REQ-079 | PASS |  |
| TC-024 | `vle_vse_unaligned_address` | REQ-058, REQ-033, REQ-005 | PASS |  |
| TC-025 | `vpu_access_outside_dmem` | REQ-082, REQ-015 | PASS |  |
| TC-026 | `vwmul_vv` | REQ-006, REQ-059 | PASS |  |
| TC-027 | `vwredsum_vs` | REQ-007, REQ-062, REQ-059 | PASS |  |
| TC-028 | `vadd_vsra_vmax` | REQ-008, REQ-059 | PASS |  |
| TC-029 | `vnclip_saturation` | REQ-008, REQ-060 | PASS |  |
| TC-030 | `vmv_variants` | REQ-008, REQ-009, REQ-059 | PASS |  |
| TC-031 | `vector_dispatch_stall` | REQ-009, REQ-031, REQ-032, REQ-034, REQ-036, REQ-037, REQ-080, REQ-081, REQ-087 | PASS |  |
| TC-032 | `vector_in_branch_shadow_flushed` | REQ-081, REQ-084, REQ-009, REQ-003 | PASS |  |
| TC-033 | `illegal_vsetvli_vtype` | REQ-054, REQ-052, REQ-004 | PASS |  |
| TC-034 | `sew_dependent_before_vsetvli` | REQ-083, REQ-054, REQ-052 | PASS |  |
| TC-035 | `illegal_sew_combinations_and_vd_alignment` | REQ-074, REQ-052 | PASS |  |
| TC-036 | `illegal_unsupported_opv` | REQ-054, REQ-052 | PASS |  |
| TC-037 | `mmio_csr_word_access` | REQ-016, REQ-027 | PASS |  |
| TC-038 | `apb_transfer_protocol` | REQ-016, REQ-028, REQ-029, REQ-030 | PASS |  |
| TC-039 | `mmio_partial_misaligned_write_error` | REQ-055, REQ-056, REQ-016, REQ-017 | PASS |  |
| TC-040 | `sts_err_set_clear_sources` | REQ-017, REQ-052, REQ-055 | PASS |  |
| TC-041 | `start_req_sets_ctrl_start` | REQ-026 | PASS |  |
| TC-042 | `uart_8n1_frame` | REQ-012, REQ-063 | PASS |  |
| TC-043 | `cycles_cnt_window` | REQ-013, REQ-062, REQ-087 | PASS |  |
| TC-044 | `cycles_cnt_independent_of_scalar` | REQ-013 | PASS |  |
| TC-045 | `host_imem_write` | REQ-019, REQ-042 | PASS |  |
| TC-046 | `host_dmem_masked_write_read` | REQ-020, REQ-011, REQ-051 | PASS |  |
| TC-047 | `host_read_latency_back_to_back` | REQ-021, REQ-022 | PASS |  |
| TC-048 | `host_miss_addresses` | REQ-021, REQ-042 | PASS |  |
| TC-049 | `host_ld_en_zero_isolation` | REQ-018, REQ-011 | PASS |  |
| TC-050 | `host_ld_en_ownership_checker` | REQ-023, REQ-034 | PASS |  |
| TC-051 | `param_illegal_rejected` | REQ-045, REQ-046, REQ-047, REQ-048, REQ-049, REQ-050 | PASS |  |
| TC-052 | `param_legal_elaborate` | REQ-045, REQ-046, REQ-050, REQ-051 | PASS |  |
| TC-054 | `random_scalar_regression` | REQ-001, REQ-002, REQ-003 | PASS |  |
| TC-055 | `random_vector_regression` | REQ-004, REQ-005, REQ-006, REQ-007, REQ-008, REQ-009, REQ-059, REQ-074 | PASS |  |
| TC-056 | `mnist_single_image_system` | REQ-014, REQ-012 | PASS |  |
| TC-057 | `mnist_100_images_latency` | REQ-014, REQ-064 | PASS |  |
| TC-058 | `fsm_unused_encoding_recovery` | REQ-036, REQ-038, REQ-037 | PASS |  |
| TC-059 | `mmio_subword_misaligned_reads` | REQ-085 | PASS |  |
| TC-060 | `mmio_unimplemented_offsets` | REQ-086 | PASS |  |
