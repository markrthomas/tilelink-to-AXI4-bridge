# TLUHToAXI4 build / sim / lint / coverage
#   make sim         — elab + build + run the Verilator TB (default)
#   make lint        — Verilator --lint-only on the emitted SV
#   make regress     — lint + sim (DV_STANDARDS fast CI gate)
#   make coverage    — Verilator --coverage build + coverage.info
#   make formal      — SymbiYosys BMC + cover (verification/formal/)
#   make cocotb      — cocotb directed tests on Icarus (cocotb/)
#   make ci          — regress + coverage + formal + cocotb
#   make elab        — Chisel -> SystemVerilog into generated/
#   make build       — Verilator TB build (no run)
#   make clean       — wipe every generated artifact

SHELL := /bin/bash

GEN_DIR   := generated
SV        := $(GEN_DIR)/TLUHToAXI4.sv

# Address-decoded variant — emitted alongside the standalone bridge in
# $(GEN_DIR)/decoder/.  Lint-only validation today; full TB is a follow-up.
DECODER_DIR := $(GEN_DIR)/decoder
DECODER_SV  := $(DECODER_DIR)/TLUHToAXI4Decoder.sv $(DECODER_DIR)/TLUHToAXI4.sv

SBT       := sbt
VERILATOR := verilator

TB_SRC    := test/cpp/tb_main.cpp
BUILD_DIR := build
COV_DIR   := build_cov
SIM_EXE   := $(BUILD_DIR)/VTLUHToAXI4
COV_EXE   := $(COV_DIR)/VTLUHToAXI4
COV_INFO  := coverage.info

# Five UNUSEDSIGNAL warnings are expected and intentional:
#   io_tl_a_bits_param, io_tl_a_bits_corrupt  — TL fields the bridge ignores
#   io_axi_b_bits_id,   io_axi_r_bits_id      — bridge uses latched a_source
#   regAddr[2:0]                              — masked off by bus alignment
LINT_SUPPRESS := -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

LINT_FLAGS := \
    --lint-only \
    -Wall \
    $(LINT_SUPPRESS) \
    --top-module TLUHToAXI4

VERILATOR_FLAGS := \
    --cc \
    --exe \
    --build \
    --trace \
    -Wall \
    -Wno-fatal \
    $(LINT_SUPPRESS) \
    --top-module TLUHToAXI4 \
    -Mdir $(BUILD_DIR) \
    -CFLAGS "-std=c++17 -O2"

COV_FLAGS := \
    --cc \
    --exe \
    --build \
    --coverage \
    --trace \
    -Wall \
    -Wno-fatal \
    $(LINT_SUPPRESS) \
    --top-module TLUHToAXI4 \
    -Mdir $(COV_DIR) \
    -CFLAGS "-std=c++17 -O2"

.PHONY: all elab build sim run lint lint-decoder regress coverage cov-report formal cocotb ci clean

all: sim

elab $(SV) $(DECODER_SV):
	$(SBT) -batch "runMain tlbridge.Main"

build $(SIM_EXE): $(SV) $(TB_SRC)
	$(VERILATOR) $(VERILATOR_FLAGS) -o VTLUHToAXI4 $(SV) $(TB_SRC)

sim: $(SIM_EXE)
	cd $(BUILD_DIR) && ./VTLUHToAXI4
	-@mv -f $(BUILD_DIR)/sim.vcd sim.vcd 2>/dev/null

run: sim

lint: $(SV)
	$(VERILATOR) $(LINT_FLAGS) $(SV)
	@echo "lint: 0 warnings"

lint-decoder: $(DECODER_SV)
	$(VERILATOR) --lint-only -Wall $(LINT_SUPPRESS) \
	    --top-module TLUHToAXI4Decoder $(DECODER_SV)
	@echo "lint-decoder: 0 warnings"

regress: lint lint-decoder sim

# --------- Coverage ---------
# Build a separate harness with --coverage; run; convert to lcov info.
$(COV_EXE): $(SV) $(TB_SRC)
	$(VERILATOR) $(COV_FLAGS) -o VTLUHToAXI4 $(SV) $(TB_SRC)

coverage: $(COV_EXE)
	cd $(COV_DIR) && ./VTLUHToAXI4
	verilator_coverage --write-info $(COV_INFO) $(COV_DIR)/coverage.dat
	@echo ""
	@echo "Coverage written to $(COV_INFO)"
	@awk -F'[,:]' '/^DA:/{lf++; if ($$3+0 > 0) lh++} END{if (lf>0) printf "Line coverage: %d/%d (%.1f%%)\n", lh, lf, (100.0*lh)/lf; else print "no coverable lines"}' $(COV_INFO)

cov-report: coverage
	@command -v genhtml >/dev/null 2>&1 || { echo "genhtml not on PATH; install lcov to build the HTML report"; exit 1; }
	genhtml $(COV_INFO) -o coverage_html
	@echo "HTML report: coverage_html/index.html"

formal:
	$(MAKE) -C verification/formal all

cocotb: $(SV)
	$(MAKE) -C cocotb

ci: regress coverage formal cocotb

clean:
	rm -rf $(GEN_DIR) $(BUILD_DIR) $(COV_DIR) sim.vcd $(COV_INFO) coverage_html target project/target project/project
	$(MAKE) -C verification/formal clean
	rm -rf cocotb/sim_build cocotb/__pycache__ cocotb/results.xml cocotb/*.vcd
