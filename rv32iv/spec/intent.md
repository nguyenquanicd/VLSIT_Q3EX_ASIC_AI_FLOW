# Spec: RISC-V + VPU for MNIST image recognition (draft v0.2)

> Status: **DRAFT**. Items marked `[TBD]` or listed under "Open questions" need confirmation.
> Performance figures are initial estimates, not yet measured.
> **Applicable RTL rules:** `VLSIT_RTL_Design_Rule.md` (v2), at
> `VLSIT_RTL_Generator_AI_Model/spec_template/`. Module, port, parameter and FSM names in
> this spec follow those rules; the cross-reference table is in section 12. Rule IDs (e.g. NAM-07, P22) are quoted from the rules.
> **CSR:** the MMIO register block is generated with the APB-CSR-Generator, at `APB-CSR-Generator` (section 5.6).
> **Changes in v0.2 vs v0.1:** renamed modules/ports/parameters per the rules, added section 12, added section 13 (folder
> structure), changed how memory is loaded (the rules forbid `$readmemh` in RTL), added handling of signed numbers,
> added section 5.6 (CSR via the APB-CSR-Generator) and 12.5 (tool output vs. the rules).
> **Added after v0.2:** section 5.7, the host load port (`m_host_ld`): IMEM/DMEM access for an external host while
> the core is held in reset.

## 1. Goals and scope

**Goal:** a small system made of a RISC-V core and a Vector Processing Unit (VPU). The system loads the weights of a pre-trained neural network, takes one handwritten MNIST digit image (28x28, grayscale) and outputs the predicted label (0-9).

**In scope:**
- Inference on one image at a time; no training in hardware.
- An INT8-quantized MLP.
- Platform: RTL simulation (Verilator) and/or FPGA prototype.
- Toolchain: training, quantization, weight export, firmware, verification.

**Out of scope (v0.1):** real camera/image preprocessing, on-device training, ASIC/PPA, multiple images in parallel (batch > 1), CNN/conv.

**v0.1 deliverables (option A):** RTL (core + VPU) running on FPGA, firmware, quantized weights, golden model and test suite; detailed bit-level ISA/RTL documentation is not included yet.

## 2. Architecture overview

```
 +-------------------------------------------------------------+
 |                    m_soc_top (wrapper)                      |
 |                                                             |
 |  +-----------+  vector instr.   +----------------------+    |
 |  | m_cpu_top | ---------------> |  m_vpu_top           |    |
 |  | RV32I+    | <--------------- |  VLEN=128, 4 lanes   |    |
 |  | Zmmul     |  result/status   |  vector regfile      |    |
 |  +-----+-----+                  +----------+-----------+    |
 |        |                                    |                |
 |        |  m_soc_bus (address decode, mux)   |                |
 |  +-----+------------------------------------+-----------+    |
 |  |  m_host_ld (2:1 DMEM mux + IMEM write, see 5.7)      |    |<-- host load port
 |  +-------------------------+----------------------------+    |    (i_ld_*, o_ld_rd_data)
 |  |  m_imem (firmware)      |   m_dmem (weights,         |    |
 |  |                         |   image, activations)      |    |
 |  +-------------------------+----------------------------+    |
 |  |  m_apb_master -> m_soc_csr (APB CSR) + m_uart         |    |
 |  +-------------------------------------------------------+   |
 +-------------------------------------------------------------+
```

**Division of work:**

| Task | Done by |
|---|---|
| Control flow, loops, addressing, final argmax | Scalar RISC-V core |
| Dot product, bias add, requantize, ReLU | VPU |
| Loading firmware/weights/image into IMEM/DMEM | Memory-initialization flow, testbench, or an external host through the host load port (see 5.7, 6) |
| Result output | MMIO registers + UART |

**Clock domain:** a single domain named `core` (clock `i_clk_core`, reset `i_rst_n_core`, asynchronous active-low reset). No clock domain crossings (CDC) in v0.1.

## 3. Network model

| Item | Value |
|---|---|
| Input | 784 elements (28x28), INT8, normalized and quantized |
| Layer 1 | Fully connected 784 -> 128, ReLU |
| Layer 2 | Fully connected 128 -> 10 (logits) |
| Output | argmax of the 10 logits |
| Target accuracy | >= 96% on the MNIST test set (INT8); the original FP32 is typically ~97-98% |

**Weight size (INT8):**
- Layer 1: 784 x 128 = 100,352 bytes
- Layer 2: 128 x 10 = 1,280 bytes
- INT32 biases: (128 + 10) x 4 = 552 bytes
- Total ~ 102,184 bytes (~ 99.8 KB)

**Quantization:** post-training quantization, symmetric, per-tensor, INT8 for weights and activations, INT32 for biases and accumulators. Each layer's scale factor is rounded to a **power of 2** so that requantization is just a bit shift (`>> shift`). If accuracy is not met, switch to integer scale + shift (`[TBD]`).

## 4. VPU specification

### 4.1. Instruction set

Use a subset of the **RISC-V Vector Extension 1.0**, embedded profile **Zve32x** (integer only, ELEN = 32). Rationale: standardized, existing toolchain and simulator, no floating point needed.

| Parameter | Proposed value |
|---|---|
| VLEN | 128 bits (16 INT8 elements / register), **fixed for v0.1** |
| Lanes | 4 lanes x 32 bits (each instruction is exactly 1 pass at LMUL = 1), **fixed for v0.1** |
| ELEN | 32 bits |
| Supported SEW | 8, 16, 32 |
| LMUL | 1 (minimum); 2, 4 optional |
| Vector registers | 32 (v0-v31) |
| Floating point | No |

**Minimum required instructions:**

| Group | Instructions | Used for |
|---|---|---|
| Configuration | `vsetvli`, `vsetivli` | Set SEW/LMUL, get `vl` (handles the remainder automatically). The compiler also emits the form `vsetvli zero,zero,...` (change SEW while keeping `vl`) |
| Load/Store | `vle8.v`, `vse8.v`, `vle32.v`, `vse32.v` | Unit-stride vector load/store |
| Widening multiply | `vwmul.vv` (INT8 x INT8 -> INT16) | Element-wise products |
| Reduction | `vwredsum.vs` (INT16 -> INT32) | Sum the products into a single value |
| Arithmetic | `vadd.vv/vx`, `vsra.vi/vx`, `vmax.vx` | Bias add, shift, ReLU |
| Narrowing + saturation | `vnclip.wi/wx` | INT32 -> INT16 -> INT8, with clamping |
| Move | `vmv.v.x`, `vmv.s.x`, `vmv.x.s` | Initialize and extract scalar values (`vmv.s.x` sets the initial value for a reduction) |

Instructions not in this list (complex masking, gather/scatter, advanced fixed-point) are **not required** in v0.1.

### 4.2. Computation mapping (proposed)

**Chosen approach: each output neuron = one dot product (output-neuron-stationary).**

For neuron `j`, the weights `W[j][0..783]` are contiguous in memory:

```
acc = 0
for i in 0..783 step vl:                 // vl decided by vsetvli
    vx  = vle8(x + i)                    // 16 input elements
    vw  = vle8(W[j] + i)                 // 16 corresponding weights
    vp  = vwmul(vx, vw)                  // INT16, element-wise
    acc = vwredsum(vp, acc)              // INT32, reduced to a single value (reduction)
y[j] = clamp_int8( relu( (acc + bias[j]) >> shift ) )
```

These are exactly the two kinds of operations covered earlier: **element-wise** (`vwmul`, `vadd`, `vmax`) and **reduction** (`vwredsum`). With VLEN = 128: 784 / 16 = 49 iterations per neuron.

Alternative approach (noted, not chosen): scalar-times-vector multiply (`vwmacc.vx`) with transposed weights. More efficient, but needs a different weight layout.

Rough estimate: layer 1 needs 128 x 49 = 6,272 iterations. At ~6-10 cycles/iteration that is ~40-60k cycles for layer 1.

**Checked with the compiler:** an equivalent dot product (see `fw/dot_i8_test.c`) compiles with GCC 14.2 (`-march=rv32i_zmmul_zve32x`) and emits the expected sequence `vsetvli`, `vle8.v`, `vwmul.vv`, `vwredsum.vs`; `vwmul` writes its INT16 result to a register pair (LMUL = 2).

### 4.3. VPU functional requirements

| ID | Requirement |
|---|---|
| VPU-F1 | Execute the instructions of table 4.1 with correct RVV 1.0 semantics |
| VPU-F2 | `vsetvli` returns `vl = min(AVL, VLMAX)`; the last iteration handles the remainder correctly (e.g. `vl = 6` when 6 elements remain) |
| VPU-F3 | `vwredsum` does not overflow: INT16 products are accumulated in INT32 |
| VPU-F4 | `vnclip` saturates to [-128, 127], no wrap-around |
| VPU-F5 | Results **match bit-for-bit** with the reference model (golden model) |

### 4.4. Proposed VPU architecture (in-house design)

**Decision:** build the VPU ourselves instead of using an open-source IP. Rationale: the goal is a deep understanding of the VPU, and only about 10-15 instructions are needed. Version v0.1 prioritizes **simple and correct** over performance: one vector instruction executes at a time, and the next is accepted only when the current one finishes (no pipelining, no chaining, no scoreboard).

**Module hierarchy** (names per NAM, one module per file `<module name>.sv` per HIE-01; `m_vpu_top` is a structural wrapper with no logic per HIE-02):

```
m_vpu_top
├── m_vpu_if          interface receiving instructions from the scalar core, returning results
├── m_vpu_dec         decodes vector instructions -> control signals
├── m_vpu_csr         vtype, vl, vstart; computes vl for vsetvli
├── m_vpu_ctrl        sequencer (FSM): steps each instruction through its phases
├── m_vpu_regfile     32 registers x PARA_VLEN bits
├── m_vpu_lsu         load/store unit connected to memory (FSM)
├── m_vpu_lane [x PARA_LANE_COUNT]   (gen_lane[0..N-1].u_lane)
│   ├── m_lane_alu    add, subtract, shift, max/min, logic
│   ├── m_lane_mul    multiply (with INT8 -> INT16 widening mode)
│   └── m_lane_narrow shift + round + saturate (vnclip)
├── m_vpu_reduce      adder tree across lanes (vwredsum)
└── m_vpu_perf        cycle counter (CYCLES register)
```

**Role of each module:**

| Module | Function | Related to |
|---|---|---|
| `m_vpu_if` | Receives (instruction, rs1/rs2 values) from the scalar core; signals busy/done; returns scalar results (`vmv.x.s`) | Section 5.4 |
| `m_vpu_dec` | Extracts opcode/funct/vm/vs1/vs2/vd; determines the operation type and whether it widens/narrows | All instructions |
| `m_vpu_csr` | Holds `vtype` (SEW, LMUL), `vl`. Computes `vl = min(AVL, VLMAX)`, `VLMAX = VLEN/SEW x LMUL` | `vsetvli`, VPU-F2 |
| `m_vpu_ctrl` | FSM/sequencer: for each instruction, reads operands, feeds the lanes, writes results; iterates if an instruction needs several passes | All instructions |
| `m_vpu_regfile` | 32 x PARA_VLEN, 2-3 read ports, 1 write port, with byte-enable | All instructions |
| `m_vpu_lsu` | Generates addresses, reads/writes the bus, aligns, writes exactly `vl` elements | `vle8/32`, `vse8/32` |
| `m_lane_alu` | Arithmetic/logic/shift/compare on a group of elements | `vadd`, `vsra`, `vmax` |
| `m_lane_mul` | Signed multiply with double-width output (for how signed numbers are written, see 12.3) | `vwmul` |
| `m_lane_narrow` | Right shift with rounding, clamp to [-128, 127] | `vnclip`, VPU-F4 |
| `m_vpu_reduce` | Sums all elements of a vector into one value, stored in element 0 of the destination register | `vwredsum`, VPU-F3 |
| `m_vpu_perf` | Counts cycles from `start` to `done` | `CYCLES` |

**Parameters (PAR-01, PAR-02):**

| Parameter | Description | Value | Unit |
|---|---|---|---|
| `PARA_VLEN` | Width of one vector register; must be divisible by `PARA_LANE_COUNT x LPARA_LANE_W` | 128 or 256; default 128 | bit |
| `PARA_LANE_COUNT` | Number of parallel lanes | 1, 2, 4 or 8; default 4 | count |
| `LPARA_LANE_W` | Width of one lane (= ELEN) | 32 (fixed) | bit |
| `LPARA_VREG_COUNT` | Number of vector registers | 32 (fixed) | count |
| `LPARA_VL_W` | Width of the `vl` register, derived from `PARA_VLEN` | computed from the largest `VLMAX` | bit |

In RTL, each parameter has the full 3-line comment `Parameter Description / values / unit` right above its declaration (PAR-02). Invalid values (e.g. `PARA_VLEN` not divisible, `PARA_LANE_COUNT` not a power of 2) are rejected at elaboration with `$error` inside a generate-`if` (PAR-04). One 128-bit vector register is exactly one pass of the 4 lanes; each 32-bit lane processes 4 INT8 elements, or 2 INT16, or 1 INT32. Scaling up VLEN/lanes later only needs a parameter change.

**VPU FSMs (ENM-02, ENM-04, ENM-05):** the `<function>` name is at most 8 characters.

| Module | `<function>` | Signals | States (`ENUM_ST_*`) | Unused encodings |
|---|---|---|---|---|
| `m_vpu_ctrl` | `vctrl` | `reg_fsm_vctrl_current_state`, `w_fsm_vctrl_nxt_state` | `IDLE`, `DEC`, `RD`, `EXEC`, `WB`, `DONE` (3 bits) | The 2 remaining codes go to `ENUM_ST_IDLE` (ENM-03) |
| `m_vpu_lsu` | `vlsu` | `reg_fsm_vlsu_current_state`, `w_fsm_vlsu_nxt_state` | `IDLE`, `REQ`, `WAIT`, `DONE` (2 bits) | None |

**Anticipated difficulties:**
1. Widening/narrowing instructions (`vwmul`, `vwredsum`, `vnclip`): input and output widths differ, widened results go to a register pair, easy to misalign.
2. Tail handling (`vl` < VLMAX): excess elements must be masked, not overwritten.
3. Reduction across lanes: decide whether it takes one cycle or several. `[TBD]`
4. Hazards: v0.1 is not pipelined so they are avoided; they must be handled when upgrading.
5. Signed numbers: the rules forbid `signed`/`$signed` (P22), so signed multiply/shift/compare must be written as bit-level logic on unsigned vectors (12.3).

**Out of scope for v0.1:** masking (`v0`), gather/scatter, strided loads, floating point, chaining, exceptions.

### 4.5. Module build and test order

| Step | Module | Tested by |
|---|---|---|
| 1 | `m_vpu_regfile` | Write/read, byte-enable |
| 2 | `m_vpu_csr` | Correct `vl` for AVL = 1030, SEW = 8 (last iteration `vl = 6`) |
| 3 | `m_lane_alu` (add, shift, max) | Compare against Spike/Python |
| 4 | `m_lane_mul` (`vwmul`) | Corner case: -128 x -128 |
| 5 | `m_vpu_reduce` (`vwredsum`) | Sum of many elements, no overflow |
| 6 | `m_lane_narrow` (`vnclip`) | Clamp at both ends |
| 7 | `m_vpu_lsu` | Load/store with odd `vl` |
| 8 | `m_vpu_ctrl`, `m_vpu_dec`, `m_vpu_if` | Run a full dot-product loop (section 4.2) |

## 5. RISC-V core and system

### 5.1. CPU core overview (in-house design)

**Decision:** write the scalar core ourselves, a classic 5-stage in-order pipeline (IF, ID, EX, MEM, WB). The VPU interface does not depend on the internal pipeline structure.

| Item | Requirement |
|---|---|
| Scalar ISA | **RV32I + Zmmul** (has `mul`, **no `div/rem`**) |
| Pipeline | 5 stages, in-order, one instruction per cycle when there are no hazards |
| Branch prediction | None; predict not-taken, flush when actually taken (~2-cycle penalty) |
| Interrupts/exceptions | None in v0.1; an illegal instruction halts and raises an error flag (`o_err_illegal`) |
| CSR | Minimal: cycle counter `[TBD: read via CSR or only via MMIO]`. Note: firmware running on Spike must set `mstatus.VS` (see `fw/spike_test/start.S`); the project's chip has no `mstatus`, so firmware for the chip uses its own `start.S` without that instruction |
| VPU interface | See 5.4 |
| Instruction memory | 16-32 KB, M20K, synchronous 1-cycle read, behind the `m_imem` wrapper |
| Data memory | 256 KB SRAM (weights ~100 KB, image 784 B, activations ~128 B, stack), behind the `m_dmem` wrapper |
| MMIO bus | **APB4** to the tool-generated CSR block (section 5.6). APB port names follow section 9 of the rules (`i_apb_*`, `o_apb_*`) for hand-written parts; for the tool-generated part see 12.5 |
| Peripherals | UART (prints the result), control/status registers |
| FPGA target frequency | 200 MHz (not a hard requirement in v0.1) |

**On `div`:** not needed in the inference flow because requantization uses a bit shift (section 3, power-of-2 scale). Even with an integer scale (the fallback in section 3) it is still multiply then shift, no division. Firmware must not use division/modulo by runtime variables (the compiler emits library calls); division/modulo by constant powers of 2 is turned into shift/and by the compiler. Check the build with `objdump | grep __divsi3`. Checked on the test dot product: no division instructions.

### 5.2. CPU modules

`m_cpu_top` is a structural wrapper (HIE-02). Pipeline registers live in their own modules (no logic in the top):

```
m_cpu_top
├── m_pc_gen        PC register + next PC: PC+4, branch target, jal/jalr
├── m_if_id_reg     IF/ID pipeline register
├── m_cpu_dec       decodes RV32I+Zmmul, recognizes vector instructions
├── m_imm_gen       I/S/B/U/J immediates
├── m_regfile       32 x 32 bits, 2 read ports, 1 write port, x0 = 0
├── m_id_ex_reg     ID/EX pipeline register
├── m_alu           add, subtract, logic, shift, compare
├── m_branch_unit   resolves branches in EX, signals flush
├── m_mul           multiply using DSP blocks (signed numbers: see 12.3)
├── m_ex_mem_reg    EX/MEM pipeline register
├── m_lsu           alignment, byte-enable, sign extension, selects RAM or MMIO
├── m_mem_wb_reg    MEM/WB pipeline register
├── m_hazard_unit   forwarding, stall (load-use, VPU busy), flush
├── m_vpu_dispatch  sends vector instructions + rs1/rs2 to the VPU, receives results
└── m_csr_min       cycle counter
```

SoC level: `m_soc_top` (wrapper) contains `m_cpu_top`, `m_vpu_top`, `m_imem`, `m_dmem`, `m_soc_bus`, `m_apb_master` (bridge from the CPU data bus to APB), `m_soc_csr` (CSR block **generated by the tool**, section 5.6), `m_uart`, `m_rst_sync`, `m_host_ld` (host load port, section 5.7).

### 5.3. Scalar instruction set and hazard handling

| Group | Instructions |
|---|---|
| Arithmetic/logic | `add sub and or xor sll srl sra slt sltu` (and `-i` forms) |
| Constants | `lui auipc` |
| Jumps/branches | `jal jalr beq bne blt bge bltu bgeu` |
| Memory | `lb lh lw lbu lhu sb sh sw` |
| Multiply | `mul` (Zmmul); no `div/rem` |
| System | `ebreak` or an MMIO write to halt |
| Vector (forwarded to the VPU) | `OP-V` opcode, vector loads/stores (see 4.1) |

| Situation | Handling |
|---|---|
| Data dependency (EX/MEM -> EX, MEM/WB -> EX) | Forwarding |
| Load followed by immediate use | Insert 1 bubble |
| Branch/jump | Resolved in EX, flush IF/ID when taken |
| Vector instruction | Stall the whole pipeline until the VPU signals done |

### 5.4. CPU - VPU interface and main ports (provisional, may change)

Ports per NAM: `i_`/`o_`, abbreviations per NAM-08 (`command`→`cmd`, `response`→`resp`, `write`→`wr`, `read`→`rd`, `request`→`req`, `acknowledge`→`ack`, `enable`→`en`).

**`m_vpu_top`** (VPU side; the `m_vpu_dispatch` side has the dual ports `o_vpu_*`/`i_vpu_*`):

| Port | Direction | Width | Meaning |
|---|---|---|---|
| `i_clk_core`, `i_rst_n_core` | in | 1 | Clock and reset of the `core` domain |
| `i_cmd_valid` | in | 1 | A valid vector instruction is present |
| `i_cmd_instr` | in | 32 | Vector instruction |
| `i_cmd_rs1_data`, `i_cmd_rs2_data` | in | 32 | The instruction's `rs1`, `rs2` values |
| `o_cmd_ready` | out | 1 | VPU accepted the instruction |
| `o_resp_done` | out | 1 | Instruction finished |
| `o_resp_rd_valid` | out | 1 | `o_resp_rd_data` is valid (e.g. `vl`) |
| `o_resp_rd_data` | out | 32 | Result written back to `rd` |
| `o_mem_req`, `o_mem_wr_en` | out | 1 | Memory access request, write flag |
| `o_mem_addr` | out | 32 | Address (16-byte aligned in v0.1) |
| `o_mem_byte_en` | out | `PARA_VLEN/8` | Byte-enable for writes |
| `o_mem_wr_data` | out | `PARA_VLEN` | Write data |
| `i_mem_rd_data` | in | `PARA_VLEN` | Read data |
| `i_mem_ack` | in | 1 | Memory acknowledge |

**`m_cpu_top`**: besides clock/reset it has the instruction-memory ports (`o_imem_addr`, `i_imem_rd_data`), the 32-bit data-memory ports (`o_dmem_req`, `o_dmem_wr_en`, `o_dmem_byte_en`, `o_dmem_addr`, `o_dmem_wr_data`, `i_dmem_rd_data`, `i_dmem_ack`), the `o_vpu_*`/`i_vpu_*` port group above, and the flags `o_err_illegal`, `o_halt`.

ID recognizes a vector instruction, EX sends the instruction with `rs1/rs2` to the VPU, and the pipeline stalls. When the VPU raises `o_resp_done` (with `o_resp_rd_data` if any), the pipeline resumes.

### 5.5. Memory, address map and MMIO

- **Data SRAM:** the CPU accesses 32 bits (with byte-enable), the VPU accesses 128 bits (one vector register at a time). Use a mixed-width dual-port M20K or banking `[TBD: check Quartus capability]`. The memories sit behind the `m_imem`/`m_dmem` wrappers (HIE-06, HIE-07): the only place containing technology-specific structures.
- **Arbitration:** the CPU stalls while the VPU runs, so the two never access memory at the same time; only a mux is needed (in `m_soc_bus`), no arbiter. The host load port (5.7) uses the memories only while the core is held in reset, so it also needs only a 2:1 mux (in `m_host_ld`).
- **Alignment:** `vle/vse` addresses must be 16-byte aligned in v0.1 (MNIST satisfies this: 784 = 49 x 16, 128 = 8 x 16).

**Memory map (proposed, to be confirmed):**

| Region | Address | Size | Contents |
|---|---|---|---|
| Instr mem | `0x0000_0000` | 32 KB | Firmware |
| Data SRAM | `0x1000_0000` | 256 KB | See layout below |
| MMIO | `0x2000_0000` | 4 KB | CSR block (APB), see 5.6 |

Data SRAM layout: `[W1 | b1 | W2 | b2 | image | act1 | logits | stack]`, 16-byte aligned.

**MMIO registers:** located in the CSR block generated by the APB-CSR-Generator, defined in section 5.6 (replacing the 4-register table of v0.1). The `0x2000_0000` region (4 KB) is the APB address space of the CSR block; internal APB addresses are 16-bit offsets.

### 5.6. CSR (MMIO) via the APB-CSR-Generator

Reference source: `APB-CSR-Generator` (`README.md`, `CSR_Generation.py`, sample workbooks `CSR_FORMAT_PROPOSAL.xlsx` and `CSR_Example.xlsx`). The tool reads an Excel workbook and generates one SystemVerilog module that is an **APB4 slave** with address decoding, `PREADY`/`PSLVERR` and the register fields; no hand-written RTL is needed for the CSR block. The content below summarizes the tool features used by this design, checked against the tool's README.

**Workbook configuration** (`Table - Configuration`):

| Item | Value | Notes |
|---|---|---|
| Module Name | `m_soc_csr` | Per NAM: `m_<function>` |
| Protocol | `APB` | The tool only supports APB |
| Data Width | 32 | Fixed in the current tool version |
| Address Width | 16 | Fixed in the current tool version |
| Write Strobe | 4 | Fixed |
| Asynchronous | **0** | Single `core` clock domain (section 2), no CDC bridge needed. If 1, the tool adds `i_reg_clk`, `i_reg_rstn` and a synchronizer |

**Tool field types:**

| Type | SW read | SW write | Generated HW ports |
|---|---|---|---|
| `ro` | Yes | Ignored | `i_<reg>_<bit>` (direct, no flop) |
| `rw` | Yes | Yes | `o_<reg>_<bit>` |
| `rwi` | Yes | Yes (priority over HW) | `o_<reg>_<bit>`, `i_hw_wdata_<reg>_<bit>`, `i_hw_we_<reg>_<bit>` |
| `w1c` | Yes | Write 1 to clear | `o_<reg>_<bit>`, `i_hw_wdata_<reg>_<bit>`, `i_hw_we_<reg>_<bit>` (HW usually sets the bit) |

A field named `reserved` has no port, reads as 0, and writes are ignored.

**Proposed register map** (APB offset; CPU address = `0x2000_0000` + offset). Register and field names use NAM-08 abbreviations because the tool concatenates them into port names:

| Offset | Register | Field | Bits | Type | Reset | Meaning |
|---|---|---|---|---|---|---|
| `0x00` | `ctrl` | `start` | [0] | rwi | 0 | Request one inference run. HW sets it from an external pin (`i_start_req`), firmware clears it by writing 0 |
| | | `reserved` | [31:1] | ro | 0 | |
| `0x04` | `sts` | `busy` | [0] | rw | 0 | Set by firmware while inference is running |
| | | `done` | [1] | rw | 0 | Set by firmware once `result` is written; read externally via port `o_sts_done` |
| | | `err` | [2] | w1c | 0 | Set by HW on an illegal instruction (`o_err_illegal`) or `PSLVERR`; firmware writes 1 to clear |
| | | `reserved` | [31:3] | ro | 0 | |
| `0x08` | `result` | `label` | [3:0] | rw | 0 | Predicted label 0-9 |
| | | `reserved` | [31:4] | ro | 0 | |
| `0x0C` | `cycles` | `cnt` | [31:0] | ro | 0 | Cycle count of the most recent inference, from `m_vpu_perf` (port `i_cycles_cnt`) |
| `0x10` | `uart_tx` | `data` | [7:0] | rw | 0 | Byte to send |
| | | `send` | [8] | rwi | 0 | Firmware writes 1 to send; `m_uart` clears it when it takes the byte |
| | | `busy` | [9] | ro | 0 | UART is transmitting (port `i_uart_tx_busy`) |
| | | `reserved` | [31:10] | ro | 0 | |
| `0x14` | `uart_cfg` | `baud_div` | [15:0] | rw | `0x06C8` `[TBD]` | Baud-rate divisor (200 MHz / 115200 ~ 1736) |
| | | `reserved` | [31:16] | ro | 0 | |

Expected tool-generated HW ports (names per the tool's convention): `o_ctrl_start`, `i_hw_wdata_ctrl_start`, `i_hw_we_ctrl_start`, `o_sts_busy`, `o_sts_done`, `o_sts_err`, `i_hw_wdata_sts_err`, `i_hw_we_sts_err`, `o_result_label[3:0]`, `i_cycles_cnt[31:0]`, `o_uart_tx_data[7:0]`, `o_uart_tx_send`, `i_hw_wdata_uart_tx_send`, `i_hw_we_uart_tx_send`, `i_uart_tx_busy`, `o_uart_cfg_baud_div[15:0]`. All names <= 30 characters (NAM-07).

**APB interface and tool constraints (affecting CPU/firmware design):**

| Tool constraint | Consequence |
|---|---|
| Only **full 4-byte** writes accepted (`PSTRB = 4'b1111`); partial writes give `PSLVERR` | Firmware accesses MMIO only with `lw`/`sw` (`volatile uint32_t *`); no `sb`/`sh`. `m_lsu` must either block them or let the error reach `sts.err` `[TBD]` |
| Addresses must be 4-byte aligned (`paddr[1:0] == 0`), otherwise `PSLVERR` | All offsets in the table above are multiples of 4 |
| `PREADY` has a fixed latency of at least 1 cycle | `m_apb_master` must hold `i_dmem_ack` low; the pipeline stalls until the APB transfer completes |
| `PSLVERR` is generated from `i_slverr_en`; `PPROT` is checked via `i_protect_en` | Tie off: `i_slverr_en = 1`, `i_protect_en = 0` (no protection in v0.1) |
| The tool does not check for duplicate offsets or overlapping field bits | The workbook must be reviewed manually; add a check step to `scripts/` |

**`m_apb_master` (hand-written, per the rules):** takes 32-bit data-memory requests from `m_soc_bus` when the address is in the MMIO region, generates APB SETUP/ACCESS cycles (`PSEL`, `PENABLE`, `PADDR`, `PWRITE`, `PWDATA`, `PSTRB = 4'b1111`), returns `PRDATA` to the CPU and flags `PSLVERR`. APB ports are named per section 9 of the rules (`o_apb_psel`, `o_apb_penable`...). Its FSM is named per ENM-04 (`<function>` = `apbm`).

**CSR generation procedure:**

1. Fill in the workbook following the `CSR_FORMAT_PROPOSAL.xlsx` template (one sheet with `Table - Configuration` and `Table - Register Definition`); save it as `csr/rv32_vpu_mnist_csr.xlsx` in the project.
2. Run `python3.9 CSR_Generation.py <workbook.xlsx> <sheet_name>`; the tool creates `RTL/<module_name>.sv`, `RTL/filelist.f` and `Debug/debug.json`.
3. Inspect `Debug/debug.json` to confirm the tool read the workbook correctly, then check the RTL against the rules (12.5) before moving it into `rtl/`.

**Environment note:** the tool needs `openpyxl`. On this machine the system `openpyxl` fails on import (newer `numpy` removed `np.float`), so running the tool as-is fails. A workaround (e.g. a virtual environment with a newer `openpyxl`) has not been tried yet. `[TBD]`

### 5.7. Host load port (IMEM/DMEM interface for an external host)

**Purpose:** let an external host load the firmware into `m_imem`, load the weights, biases and image into `m_dmem`, and read the results (e.g. the 10 logits) back from `m_dmem`, at run time and without re-synthesis. The port is used only while the core is held in reset. On the FPGA it is driven by a PCIe wrapper (on the Catapult v3: an Avalon-MM slave behind PCIe BAR4); that wrapper is outside this IP. Without a host, all `i_ld_*` inputs are tied to 0 and `o_ld_rd_data` is left open, and the design behaves exactly as it would without the port.

**Structure:** a new module `m_host_ld` (instance `u_host_ld`) sits between `m_soc_bus` and `m_dmem` and drives the `m_imem` write port. `m_soc_top` stays a structural wrapper (HIE-02). `m_cpu_top`, `m_vpu_top`, `m_soc_bus`, `m_soc_csr` and the firmware are unchanged.

**`m_soc_top` ports** (`core` clock domain, all synchronous to `i_clk_core`):

| Port | Direction | Width | Meaning |
|---|---|---|---|
| `i_ld_en` | in | 1 | The host owns the memories. May be 1 only while `i_rst_n_core` = 0 |
| `i_ld_req` | in | 1 | One 32-bit access in this cycle |
| `i_ld_wr_en` | in | 1 | 1 = write, 0 = read |
| `i_ld_addr` | in | 32 | Byte address in the CPU memory map (5.5); bits [1:0] are ignored |
| `i_ld_byte_en` | in | 4 | Byte enables of a DMEM write. An IMEM write always writes the whole word (drive 4'hF) |
| `i_ld_wr_data` | in | 32 | Write data |
| `o_ld_rd_data` | out | 32 | Read data, valid only in the cycle after the read; 0 on a miss |

**Behaviour:**

| Item | Requirement |
|---|---|
| Handshake | None: no ack, no backpressure. Each cycle with `i_ld_en` = 1 and `i_ld_req` = 1 is one access, and back-to-back accesses are allowed. A write takes effect at that rising edge; the read latency is fixed at 1 cycle |
| IMEM range | `0x0000_0000`-`0x0000_7FFF` (`i_ld_addr[31:15]` = 0). Write only, word index `i_ld_addr[14:2]`. No read-back: a read returns 0 |
| DMEM range | `0x1000_0000`-`0x1003_FFFF` (`i_ld_addr[31:18]` = 14'h0400). Read and write. A DMEM row is `PARA_VLEN` bits wide, so the host word is 32-bit lane `i_ld_addr[LB-1:2]` of row `i_ld_addr[17:LB]`, with LB = log2(`PARA_VLEN`/8) (LB = 4 at VLEN = 128). Exactly the enabled bytes of the addressed 32-bit word change |
| Other addresses | MMIO and unmapped addresses are a miss: a write changes nothing, a read returns 0 |
| `i_ld_en` = 0 | The `m_soc_bus` DMEM port passes to `m_dmem` unchanged (combinational 2:1 mux, no added cycle), the IMEM write enable is 0, and the other `i_ld_*` inputs are ignored |
| Ownership | `i_ld_en` must be 0 at every rising edge of `i_clk_core` at which `i_rst_n_core` = 1, so it falls no later than reset is released. The CPU and VPU are idle in reset, so no arbiter is needed (5.5). Breaking this rule is an integration error: there is no hardware check, and the testbench checks it with an assertion in `tb/` |
| Reset | Reset does not gate the port, and the memories are not reset. Data written during reset is kept after release, and the results stay in DMEM until the host reads them in the next reset window. The firmware `start.S` must not clear DMEM |
| Image and logits addresses | Set by the firmware build (exported next to the firmware, e.g. a `.layout` file), not fixed by the hardware |

**Memory wrapper ports** (internal, connected by `m_host_ld`):

| Wrapper | Ports | Driven by | Notes |
|---|---|---|---|
| `m_imem` | `i_rd_addr` → `o_rd_data` (32) | `m_cpu_top` fetch | Word index = byte address [14:2], 1-cycle read |
| `m_imem` | `i_init_wr_en`, `i_init_wr_addr` (13), `i_init_wr_data` (32) | `m_host_ld` | Whole-word write, no byte enables; the host has no IMEM read path |
| `m_dmem` | `i_en`, `i_wr_en`, `i_addr` (row index, 14 at VLEN = 128), `i_byte_en` (`PARA_VLEN`/8), `i_wr_data` → `o_rd_data` (`PARA_VLEN`) | `m_host_ld` (the host, or `m_soc_bus` passed through) | Single port; registered read data, valid in the cycle after the read |

**Typical host sequence:**
1. Hold reset (`i_rst_n_core` = 0) and set `i_ld_en` = 1.
2. Write the firmware to IMEM and the weights, biases and image to DMEM. Optionally read DMEM back to check it.
3. Set `i_ld_en` = 0, release reset, request a run (`i_start_req`) and wait for `o_sts_done`.
4. Hold reset again, set `i_ld_en` = 1, read the logits from DMEM, write the next image and repeat from step 3. The firmware and weights stay loaded.

## 6. Data flow: loading weights and recognition

1. **Offline:** training (PyTorch) -> INT8 quantization -> export `weights.bin` (layout per section 5) + `scales.h`.
2. **Loading weights/firmware:** the rules forbid `initial` and system tasks such as `$readmemh` in RTL (P2, P14). Therefore: (a) **FPGA:** a memory initialization file (`.mif`/`.hex`) is attached through the memory-initialization mechanism supported by the flow, inside the `m_imem`/`m_dmem` wrappers `[TBD: confirm the Quartus mechanism and that rule P2 allows it]`; (b) **simulation:** the testbench loads the memory contents (part of the verification sources, hierarchical references allowed); (c) **host load port** (5.7): an external host writes IMEM and DMEM while the core is held in reset, so firmware and weights can change without re-synthesis. A UART bootloader is an extension, not required.
3. **Loading the image:** the testbench, or an external host through the host load port (5.7) while the core is held in reset, writes 784 bytes to the `image` region.
4. **Run:** firmware waits for `ctrl.start` = 1 (set by an external pin or by firmware), clears `ctrl.start`, sets `sts.busy`, runs layer 1 -> layer 2 on the VPU, and the scalar core does the 10-element argmax.
5. **Result:** writes `result.label`, sets `sts.done` and clears `sts.busy`, prints the label over UART via `uart_tx` (one digit: `'0' + label`, no division needed). The outside world reads the result via ports `o_result_label` and `o_sts_done`. An external host can also read the 10 logits from DMEM through the host load port once the core is held in reset again (5.7).

## 7. Software and tools

| Component | Proposal |
|---|---|
| Training/quantization | Python, PyTorch, NumPy |
| Golden model | Integer NumPy, **bit-exact** with the hardware |
| Firmware | C with RVV intrinsics, `-march=rv32i_zmmul_zve32x -mabi=ilp32` |
| Compiler | `riscv64-unknown-elf-gcc` 14.2.0. Checked: compiles RVV intrinsics with `-march=rv32i_zmmul_zve32x -mabi=ilp32`, emits no `div`. Linking not tried yet |
| Early software development | **Spike 1.1.1-dev built and installed in the project** at `tools/spike/bin/spike` (built with `scripts/build_spike.sh`). Run with `--isa=rv32i_zmmul_zve32x_zvl128b_zicsr`: VLEN is set by the `zvl<N>b` suffix (this version no longer has the `--varch` option). The test `fw/spike_test/test_dot.c` (INT8 dot product, lengths 1 to 1030 including odd `vl` and -128 x -128) PASSES at VLEN = 128 and 256: `scripts/run_spike_test.sh [VLEN]` |
| RTL simulation | Verilator 5.041 (OSS CAD Suite), QuestaSim |
| CSR generation | `APB-CSR-Generator/CSR_Generation.py` (Python 3.9 + `openpyxl`); generates an APB4 slave from an Excel workbook. See 5.6 and the note on `openpyxl` |
| RTL rule checking | `verible` (lint/format), `verilator --lint-only`, and custom scripts for rules no tool checks (NAM-07 names <= 30 characters, CMT-05 comments <= 100 characters, P29 no tabs) `[TBD]` |
| FPGA | Catapult v3 board, Intel Arria 10 1150 chip (the user wrote "GT 1150, 10AXF40GAA"; **the `AX` code is usually the GX family, `AT` is GT: the part number needs re-confirming**). Toolchain: Intel Quartus Prime; 22.1 std, 25.1 pro, 26.1 pro are available; version to use `[TBD]` |

**Synthesis record (SCP-02):** each synthesis result must record: top (`m_soc_top`), filelist, parameter override values, chip name, Quartus version, options, SDC. Stored in `scripts/` and `constraints/`.

## 8. Non-functional requirements

| ID | Requirement | Level |
|---|---|---|
| NFR-1 | INT8 accuracy on the 10,000 test images >= 96% | Mandatory |
| NFR-2 | RTL results match the golden model 100% on the test suite | Mandatory |
| NFR-3 | Inference time < 1,000,000 cycles/image | Target (estimate) |
| NFR-4 | Reproducible sources: one script runs from training to comparison | Should have |
| NFR-5 | RTL complies with `VLSIT_RTL_Design_Rule.md`; lint clean or waived with a reason and an approver | Mandatory |

## 9. Verification plan

1. **Instruction level:** test each vector instruction with random and corner-case vectors (overflow, saturation, odd `vl`) against Spike.
2. **Layer level:** run layer 1 and layer 2 separately, compare intermediate activations with the golden model.
3. **System level:** run 100 MNIST images, compare labels and logits bit-for-bit with the golden model.
4. **Accuracy:** run all 10,000 test images on the golden model (fast), cross-check a subset on RTL.
5. **Regression:** an automated script reports PASS/FAIL.
6. **Rule checks:** run lint and the name/comment/tab check scripts over all of `rtl/` (section 12).

Testbenches, simulation models and SVA live in `tb/`, separate from `rtl/`, and are **not** included in the synthesis filelist (SCP-01, P19).

## 10. Risks

| Risk | Mitigation |
|---|---|
| In-house VPU: easy to get RVV semantics wrong, time-consuming to debug | Build module by module per 4.5, check each instruction against Spike, bit-exact golden model |
| Quantization loses too much accuracy | Switch to integer scale + shift, or quantization-aware training |
| Memory bandwidth makes the VPU wait for data | Measure CYCLES, try other VLEN/LMUL, change the weight layout |
| ~100 KB of weights do not fit in on-chip memory | With the Arria 10 1150 (tens of Mb of M20K, see section 11) there is plenty; if moving to a smaller chip, shrink the hidden layer (784-64-10 is ~50 KB) |
| Large chip but the design uses very little: risk of waste/losing focus | Keep v0.1 small; use the spare resources to increase `PARA_VLEN`/`PARA_LANE_COUNT` once the basic version works |
| The rules forbid signed types (P22), so the signed INT8 multiply is written bit-level; Quartus may not infer DSP blocks as expected | Write an unsigned multiply + sign correction (12.3), check the resource report; if needed, place the DSP block in a technology wrapper (HIE-07) |
| The rules are written for ASIC tapeout, v0.1 runs on FPGA: many DFT/UPF items do not apply | List the deferred items and the reasons explicitly (12.2); request confirmation |
| The rules forbid `$readmemh`/`initial`: loading weights into BRAM needs another mechanism | Use the flow's memory initialization inside the wrapper, or have the testbench load it (section 6) |

## 11. Open questions (need confirmation from you/the team)

1. ~~**Core + VPU:** existing IP or in-house design?~~ **Decided: in-house design of both the VPU (4.4) and the scalar core (5.1)**: RV32I + Zmmul, 5-stage pipeline.
2. **FPGA board:** Catapult v3 with an Intel **Arria 10 1150** chip. Still to confirm: (a) the exact part number (`10AXF40GAA` or a GT/GX variant); (b) actual resources per the datasheet. Reference figures, **from memory, not checked against the datasheet**: ~1.15M logic elements, ~2,700 M20K blocks (~53 Mb, i.e. about 6.6 MB), ~1,500 DSP blocks. For a network with ~100 KB of weights, both memory and DSP are far more than enough. (c) Board access: programming via JTAG or via dedicated infrastructure, and whether UART/GPIO are available externally. `[TBD]`
3. ~~**VLEN** 128 or 256, and the number of lanes?~~ **Decided: VLEN = 128, 4 lanes x 32 bits** (see 4.1 and 4.4). Can be increased later thanks to parameterization.
4. ~~**Scope of "VPU"** in the original request~~ **Decided: option A** (a working system: RTL + firmware that correctly recognizes MNIST on FPGA). Detailed bit-level ISA/RTL documentation (option B) comes later, once the RTL is stable.
5. **Who the spec's users are** (RTL, firmware, verification teams), to adjust the depth of each section.
6. **ASIC rules applied to an FPGA project:** do you agree with the list of deferred items in 12.2 (DFT, clock gating, UPF, equivalence)? `[Needs confirmation]`
7. **Project name and author name** for the RTL file header (FIL-01: `Project`, `Author = <USER_NAME> (user)`). The provisional project name is `rv32_vpu_mnist`; no author name yet. `[TBD]`
8. ~~**MMIO bus:** internal req/ack or APB?~~ **Decided: APB4, CSR generated by the APB-CSR-Generator** (5.6).
9. **Is the CSR register list in 5.6** (`ctrl`, `sts`, `result`, `cycles`, `uart_tx`, `uart_cfg`) complete and as intended? `[Needs confirmation]`
10. ~~**Tool output does not match the rules** (12.5)~~ **Decided (provisionally): use the tool as-is, the rest of the project follows the rules; how to handle the tool output will be decided later** (12.5).

## 12. Compliance with the VLSIT RTL Design Rule

Rules: `VLSIT_RTL_Design_Rule.md` (v2). This table states how the spec/design meets each rule group. When writing RTL, the original rules apply in full (including items not mentioned here).

### 12.1. Cross-reference by rule group

| Rule group | Application in the project |
|---|---|
| **Naming (NAM-01..08)** | Modules `m_<function>`; ports `i_`, `o_`; clock `i_clk_core`; reset `i_rst_n_core`; flops `reg_`; wires `w_`; parameters `PARA_*`; localparams `LPARA_*`; instances `u_<function>` (repeated: `u_<function>_<idx>`); generate `gen_<function>`; processes `p_com_*`, `p_ff_*`. Indices start at 0. All names <= 30 characters (NAM-07). Abbreviations per the NAM-08 table (`decoder`→`dec`, `control`→`ctrl`, `command`→`cmd`, `response`→`resp`, `write`→`wr`, `read`→`rd`...). Module/port names in sections 4.4, 5.2, 5.4 already follow these rules |
| **Data types (TYP-01..05)** | Only unsigned `logic`; inputs `input wire`, outputs `output logic`; no `package`, no `interface` in RTL. Instruction-code constants (opcode, funct) are declared locally in each module (`m_vpu_dec`, `m_cpu_dec`), not shared through a package (P11) |
| **Parameters (PAR-01..04)** | Section 4.4 has a parameter table (description, value, unit) for PAR-02; values checked with `$error` in a generate (PAR-04) |
| **Enum/FSM (ENM-01..05)** | Every FSM uses a logic enum, named per ENM-04/05, with recovery from unused encodings (ENM-03). The FSM list is in 4.4; any additional FSM (e.g. `m_uart`) must be added to the list |
| **Combinational (COM-01..06)** | `always_comb`; default assignments at the top of the process; `case` with a defined `default`; no combinational loops |
| **Arithmetic (ARI-01..04)** | Explicit width casting; sized literals; `for` in `always_comb` with static bounds, `int` declared in the header |
| **Sequential/reset (SEQ, RST)** | `always_ff` + nonblocking; asynchronous active-low reset for control/valid registers; data registers may be left unreset when their usage condition is documented (see 12.4); reset released synchronously through `m_rst_sync` (RST-02) |
| **Clock (CLK-01..04)** | One `core` clock domain; no CDC, no clock gating in v0.1. `m_rst_sync` in its own module (CLK-02) |
| **Hierarchy (HIE-01..07)** | One module per file, file name = module name; `m_soc_top`, `m_vpu_top`, `m_cpu_top` contain only instances and wires (pipeline registers live in `m_*_reg` modules); connections by name; memories inside the `m_imem`/`m_dmem` wrappers |
| **File (FIL-01..03)** | Header per the template (Project, Author, AI Flow, AI Flow Page, Date, Description), ANSI, 2-space indentation |
| **Forbidden (P1..P29)** | No `initial`, `defparam`, `casex`, plain `always`, signed/`$signed`, `reg/wire/integer`, `package`, `` `define``, tabs, SVA in RTL... Design impacts are detailed in 6 (memory loading) and 12.3 (signed numbers) |
| **Comments (CMT-01..05)** | Each logic block has a functional comment; one comment line <= 100 characters; SVA only in `tb/` |
| **Standard protocols (PRT-01..04)** | The hand-written APB part (`m_apb_master`) follows section 9 of the rules. Tool-generated CSR block: see 12.5 |
| **Tapeout checklist (section 11 of the rules)** | See 12.2 |

### 12.2. Items deferred in v0.1 (FPGA prototype) `[Needs confirmation]`

The rules are written for ASIC tapeout; this spec targets FPGA in v0.1 (section 1: ASIC/PPA out of scope). Section 0 of the rules requires a reason for every deviation, so the following items are **intentionally deferred**:

| Rule item | Content | Reason for deferral | Revisit when |
|---|---|---|---|
| NAM-06, RST-04 | DFT ports (`i_dft_*`), reset controllable in test mode | FPGA has no scan insertion | Moving to ASIC |
| CLK-03 | Clock gating with test-enable | No clock gating used (clock-enable per SEQ-03 instead) | Power reduction is needed |
| HIE-06 (DFT/BIST hook) | Memory wrapper with DFT/BIST hooks | FPGA memory is inferred M20K | Moving to ASIC |
| Checklist: DFT readiness, UPF, equivalence, CDC/RDC | ASIC checks | Not applicable to FPGA, single clock domain | Moving to ASIC |

**Still fully applied** in v0.1: naming, data types, parameters, FSMs, hierarchy, prohibitions, comments, reproducibility record (SCP-02), lint.

### 12.3. Signed numbers when the rules forbid `signed` types (TYP-01, P22)

INT8/INT16/INT32 data are two's complement, but the RTL only uses unsigned `logic` vectors. Conventions:
- Sign extension written explicitly: replicate the top bit (e.g. `{{8{w_a[7]}}, w_a}`).
- Signed multiply `a x b` (n bits): compute the unsigned product then correct using the two sign bits: subtract `(b << n)` if `a` is negative and subtract `(a << n)` if `b` is negative, truncated to `2n` bits.
- Arithmetic right shift (`vsra`, `vnclip`): fill the upper bits with the sign bit.
- Signed compare (`vmax`, clamp): flip the sign bit then compare unsigned, or check the signs first.
- Saturation (clamp to [-128, 127]): check the sign bit and overflow bits with bit-level logic.

Helper functions (if any) must be `automatic`, purely combinational, side-effect free (COM-06, P9), declared locally in the module.

### 12.4. Unreset registers

Allowed only for data registers whose users ignore them until a valid signal arrives or they have been written (SEQ-04). Applies to `m_vpu_regfile` and `m_regfile` (except `x0`): firmware must write before reading. Also applies to the lane-select register of `m_host_ld` (5.7), which is loaded by a host read and used only in the next cycle. This condition must be stated in each module's comments. Control, valid and FSM registers are always reset.

### 12.5. APB-CSR-Generator output vs. the rules

The README of the VLSIT template set requires tool-generated RTL to be checked against the rules before use. I read `RTL/m_vlsi_csr.sv` (the `Asynchronous=1` sample) and found the deviations below. Lint has not been run, so this list may be incomplete. The `Asynchronous=0` version has not been checked separately.

| # | Observation in the tool output | Related rule |
|---|---|---|
| 1 | Clock/reset are `i_bus_clk`, `i_bus_rstn` | NAM: `i_clk_<domain>`, `i_rst_n_<domain>`; PRT-02: `i_clk_apb`, `i_rst_n_apb` |
| 2 | APB ports are `i_paddr`, `i_psel`, `o_prdata`... (no protocol prefix) | PRT-01: `i_apb_paddr`, `i_apb_psel`, `o_apb_prdata` |
| 3 | Ports declared as bare `input`/`output`, without `wire`/`logic` | TYP-02 |
| 4 | `localparam PARA_<REG>_OFFSET = 16'h0000` | PAR-01: localparams must be `LPARA_*` and typed `logic [31:0]` |
| 5 | Combinational/next signals named `apb_*`, `nxt_*`, `we_*` | NAM: combinational `w_<name>`, next `w_<name>_nxt` |
| 6 | Has `casez ... default: reg_read_req <= 'x;` in the CDC bridge | COM-04: `'x` is allowed only when the `casez` is full-case and commented; must be reviewed |
| 7 | File header comment in the form `Project/Generator/Date/Module/Function/Page` | FIL-01: header `Project/Author/AI Flow/AI Flow Page/Date/Description` |
| 8 | `m_vlsi_synch.sv` is a behavioral model; the tool's README says it must be replaced by a verified cell | CLK-02; only relevant if `Asynchronous=1` |

**Current decision:** use the tool as-is. All the rest of the project's RTL complies with the rules. The tool-generated module `m_soc_csr` is a **temporary exception** to the rules: it is recorded here, kept separately in `csr/` (not mixed with the hand-written RTL in `rtl/`), and must be excluded from rule checks or waived during lint. Whether to fix the tool, issue a formal waiver or add a wrapper will be decided later. The parts outside `m_soc_csr` that connect to it (e.g. `m_apb_master`, wiring in `m_soc_top`) are still named per the rules; `m_soc_csr`'s ports are connected by name as the tool generates them.

Three options to choose from later:

| Option | Pros | Cons |
|---|---|---|
| **A. Fix the template in `CSR_Generation.py`** to generate rule-compliant code | Every future CSR is correct; fixed once | Needs permission to modify the tool; may affect other users of the tool |
| B. Accept the deviations, record a waiver (reason and approver) | Tool untouched | The rules require a reason for every deviation; more review work |
| C. Wrap it in a port-renaming wrapper | Fixes items 1-3 (ports) | Cannot fix internal names (4-7) |

## 13. Project folder structure

```
rv32_vpu_mnist/
├── README.md
├── docs/            this spec and design documents
├── rtl/             synthesizable RTL (.sv files only, one module per file)
│   ├── cpu/         m_cpu_top, m_pc_gen, m_alu, ...
│   ├── vpu/         m_vpu_top, m_vpu_regfile, m_lane_*, ...
│   ├── mem/         m_imem, m_dmem (memory wrappers)
│   └── soc/         m_soc_top, m_soc_bus, m_apb_master, m_soc_csr (from the tool), m_uart, m_rst_sync, m_host_ld
├── csr/             CSR workbook (.xlsx), APB-CSR-Generator output (reviewed), debug.json
├── tb/              testbenches, simulation models, SVA (not in the synthesis filelist)
├── fw/              C firmware (RVV intrinsics), linker script, build scripts
│   └── spike_test/  RVV dot-product test running on Spike (start.S, link.ld, test_dot.c)
├── tools/           tools built inside the project (not project code): spike/, src/, bin/, logs/
├── model/           training, quantization, bit-exact golden model (Python)
├── scripts/         build, simulation, lint, synthesis, rule checks
└── constraints/     SDC and pin constraints for the Arria 10
```
