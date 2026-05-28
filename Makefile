# TLUHToAXI4 build / sim / lint / coverage
# Run `make` with no arguments to print the target list.

SHELL := /bin/bash

GEN_DIR   := generated
SV        := $(GEN_DIR)/TLUHToAXI4.sv

# Address-decoded variant — emitted alongside the standalone bridge in
# $(GEN_DIR)/decoder/.  Lint-only validation today; full TB is a follow-up.
DECODER_DIR := $(GEN_DIR)/decoder
DECODER_SV  := $(DECODER_DIR)/TLUHToAXI4Decoder.sv $(DECODER_DIR)/TLUHToAXI4.sv
WIDTHS      := 32 64 128 256
WIDTH_DIR   := $(GEN_DIR)/widths

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

.PHONY: help all elab elab-widths build sim run lint lint-decoder lint-widths regress coverage cov-report formal cocotb wave wave-formal wave-bmc ci clean

# ---- Waveform viewer ----
# Override on the command line, e.g. `make wave WAVE_VIEWER=surfer`.
WAVE_VIEWER ?= gtkwave
# Default trace path — `make wave WAVE_FILE=foo.vcd` opens an arbitrary VCD.
WAVE_FILE   ?= sim.vcd
BMC_TRACE   := verification/formal/tluhtoaxi4_bmc/engine_0/trace.vcd
COVER_TRACE := verification/formal/tluhtoaxi4_cover/engine_0/trace0.vcd

.DEFAULT_GOAL := help

help:
	@echo "TLUHToAXI4 — available targets:"
	@echo ""
	@echo "  elab          Chisel -> SystemVerilog into generated/"
	@echo "  elab-widths   Elaborate the parameterized data-width sweep"
	@echo "  build         Verilator TB build (no run)"
	@echo "  sim           elab + build + run the Verilator TB"
	@echo "  run           alias for sim"
	@echo "  lint          Verilator --lint-only on the emitted SV"
	@echo "  lint-decoder  Lint the address-decoded bridge variant"
	@echo "  lint-widths   Lint each dataBits in the width sweep"
	@echo "  regress       lint + lint-decoder + lint-widths + sim (CI gate)"
	@echo "  coverage      Verilator --coverage build + coverage.info"
	@echo "  cov-report    Coverage + HTML report via genhtml (lcov)"
	@echo "  formal        SymbiYosys BMC + cover (verification/formal/)"
	@echo "  cocotb        cocotb directed tests on Icarus (cocotb/)"
	@echo "  wave          run sim then open sim.vcd in GTKWave"
	@echo "  wave-formal   open the formal cover witness in GTKWave"
	@echo "  wave-bmc      open the BMC counter-example (if present)"
	@echo "  ci            regress + coverage + formal + cocotb"
	@echo "  clean         wipe every generated artifact"
	@echo ""
	@echo "Overrides: WAVE_VIEWER=surfer  WAVE_FILE=path/to.vcd"

all: sim

elab $(SV) $(DECODER_SV):
	$(SBT) -batch "runMain tlbridge.Main"

elab-widths:
	$(SBT) -batch "runMain tlbridge.WidthSweep"

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

lint-widths: elab-widths
	@set -euo pipefail; \
	for width in $(WIDTHS); do \
	    sv="$(WIDTH_DIR)/w$$width/TLUHToAXI4.sv"; \
	    echo "lint-widths: dataBits=$$width"; \
	    $(VERILATOR) $(LINT_FLAGS) "$$sv"; \
	done
	@echo "lint-widths: 0 warnings for dataBits=$(WIDTHS)"

regress: lint lint-decoder lint-widths sim

# --------- Waveforms ---------
# `wave` runs the sim (refreshing sim.vcd if anything changed) and pops up
# GTKWave on the result.  Override WAVE_FILE to view a different VCD:
#   make wave WAVE_FILE=verification/formal/.../trace0.vcd
#   make wave WAVE_VIEWER=surfer
wave: sim
	@command -v $(WAVE_VIEWER) >/dev/null 2>&1 || { \
	    echo "$(WAVE_VIEWER) not on PATH — install it or override WAVE_VIEWER"; exit 1; }
	@test -f $(WAVE_FILE) || { echo "$(WAVE_FILE) not found"; exit 1; }
	$(WAVE_VIEWER) $(WAVE_FILE) &

# Cover-witness trace from SymbiYosys (depth-bounded reachability example).
# Multiple witnesses exist in tluhtoaxi4_cover/engine_0/trace*.vcd; this opens
# the first.  Override WAVE_FILE to pick a specific one.
wave-formal: formal
	@command -v $(WAVE_VIEWER) >/dev/null 2>&1 || { \
	    echo "$(WAVE_VIEWER) not on PATH"; exit 1; }
	@test -f $(COVER_TRACE) || { echo "$(COVER_TRACE) not found — run make formal first"; exit 1; }
	$(WAVE_VIEWER) $(COVER_TRACE) &

# BMC counter-example only exists when an assertion failed; if BMC currently
# passes, the file is absent.
wave-bmc:
	@test -f $(BMC_TRACE) || { \
	    echo "no BMC counter-example at $(BMC_TRACE) — BMC is currently passing"; exit 1; }
	@command -v $(WAVE_VIEWER) >/dev/null 2>&1 || { \
	    echo "$(WAVE_VIEWER) not on PATH"; exit 1; }
	$(WAVE_VIEWER) $(BMC_TRACE) &

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

formal: $(SV)
	$(MAKE) -C verification/formal all

cocotb: $(SV)
	$(MAKE) -C cocotb

ci: regress coverage formal cocotb

clean:
	rm -rf $(GEN_DIR) $(BUILD_DIR) $(COV_DIR) sim.vcd $(COV_INFO) coverage_html target project/target project/project
	$(MAKE) -C verification/formal clean
	rm -rf cocotb/sim_build cocotb/__pycache__ cocotb/results.xml cocotb/*.vcd
