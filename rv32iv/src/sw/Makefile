# src/sw/Makefile -- test programs and data of the testbench (TC-056 / TC-057: MNIST firmware system tests).
#
#   make -C src/sw PROG_DIR=<dir> RISCV_PREFIX=<prefix> SPIKE=<spike>
#
# PROG_DIR: absolute, or relative to the PROJECT ROOT (default build/tb/programs). Files written there:
#   mnist_fw.hex     firmware image, word 0 = IMEM address 0          (+FW_HEX)
#   mnist_dmem.hex   static DMEM image: W1 | b1 | W2 | b2 at DMEM_BASE (+DMEM_HEX, +DMEM_WORDS)
#   mnist_img.hex    NIMG test images, 196 words (784 INT8 pixels) each (+IMG_HEX)
#   mnist_exp.hex    expected results, 11 words per image: label, logit[0..9] (+EXP_HEX)
#   mnist.layout     layout of the data (IMG_ADDR, LOGIT_ADDR, shifts)
#   mnist.plusargs   the complete plusarg list of TC-056/TC-057 for these files
# Expected results: the firmware model build runs on Spike (standard RVV) and its signature is cross-checked
# bit-for-bit against the independent Python golden model (scripts/gen_model.py). SPIKE_CHECK=0 skips Spike.

RISCV_PREFIX ?= riscv64-unknown-elf-
SPIKE        ?= spike
PROG_DIR     ?= build/tb/programs
SPIKE_CHECK  ?= 1
NIMG         ?= 100
MODEL        ?=
PYTHON       ?= python3 -I

SW_DIR   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
PROJ_DIR := $(abspath $(SW_DIR)/../..)
ifeq ($(patsubst /%,/,$(PROG_DIR)),/)
OUT := $(patsubst %/,%,$(PROG_DIR))
else
OUT := $(PROJ_DIR)/$(patsubst %/,%,$(PROG_DIR))
endif
WORK := $(OUT)/work

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy

MARCH   := rv32i_zmmul_zve32x
CFLAGS  := -march=$(MARCH)_zicsr -mabi=ilp32 -nostdlib -nostartfiles -static -mno-relax -I$(WORK) -I$(SW_DIR)/fw
SPIKE_ISA := rv32im_zve32x_zvl128b

OUT_FILES := $(OUT)/mnist_fw.hex $(OUT)/mnist_dmem.hex $(OUT)/mnist_img.hex $(OUT)/mnist_exp.hex \
             $(OUT)/mnist.layout $(OUT)/mnist.plusargs

.PHONY: all clean
all: $(OUT_FILES)

$(WORK):
	mkdir -p $@

# ---- model data (weights, images, golden results, layout header) -----------------------------------------------
$(WORK)/model_cfg.h: $(SW_DIR)/scripts/gen_model.py | $(WORK)
	$(PYTHON) $(SW_DIR)/scripts/gen_model.py --work $(WORK) --prog-dir $(OUT) --nimg $(NIMG) \
	  $(if $(MODEL),--model $(MODEL),)

$(WORK)/dmem_static.bin $(WORK)/images.bin $(WORK)/golden_exp.hex $(OUT)/mnist.layout $(OUT)/mnist.plusargs: $(WORK)/model_cfg.h ;

# ---- DUT firmware image ----------------------------------------------------------------------------------------
$(WORK)/mnist_fw.elf: $(SW_DIR)/fw/mnist_fw.S $(SW_DIR)/fw/link_dut.ld $(WORK)/model_cfg.h
	$(CC) $(CFLAGS) -T $(SW_DIR)/fw/link_dut.ld $< -o $@

$(WORK)/mnist_fw.bin: $(WORK)/mnist_fw.elf
	$(OBJCOPY) -O binary $< $@

$(OUT)/mnist_fw.hex: $(WORK)/mnist_fw.bin $(SW_DIR)/scripts/bin2hex.py
	$(PYTHON) $(SW_DIR)/scripts/bin2hex.py $< $@ 8192

$(OUT)/mnist_dmem.hex: $(WORK)/dmem_static.bin $(SW_DIR)/scripts/bin2hex.py
	$(PYTHON) $(SW_DIR)/scripts/bin2hex.py $< $@ 65536

$(OUT)/mnist_img.hex: $(WORK)/images.bin $(SW_DIR)/scripts/bin2hex.py
	$(PYTHON) $(SW_DIR)/scripts/bin2hex.py $< $@ 65536

# ---- expected results ------------------------------------------------------------------------------------------
ifeq ($(SPIKE_CHECK),1)
$(WORK)/mnist_spike.elf: $(SW_DIR)/fw/mnist_fw.S $(SW_DIR)/fw/spike_data.S $(SW_DIR)/fw/link_spike.ld \
                         $(WORK)/model_cfg.h $(WORK)/dmem_static.bin $(WORK)/images.bin
	$(CC) $(CFLAGS) -DSPIKE_MODEL -T $(SW_DIR)/fw/link_spike.ld $(SW_DIR)/fw/mnist_fw.S $(SW_DIR)/fw/spike_data.S -o $@

$(WORK)/spike.sig: $(WORK)/mnist_spike.elf
	$(SPIKE) --isa=$(SPIKE_ISA) -m64 +signature=$@ +signature-granularity=4 $<

$(OUT)/mnist_exp.hex: $(WORK)/spike.sig $(WORK)/golden_exp.hex $(SW_DIR)/scripts/check_spike.py
	$(PYTHON) $(SW_DIR)/scripts/check_spike.py $(WORK)/spike.sig $(WORK)/golden_exp.hex $@
else
$(OUT)/mnist_exp.hex: $(WORK)/golden_exp.hex
	cp $< $@
endif

clean:
	rm -rf $(WORK) $(OUT_FILES)
