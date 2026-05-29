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

# TL-UL → AXI4-Lite variant — emitted alongside the standalone bridge in
# $(GEN_DIR)/ulite/.  Lint + Verilator TB + formal + cocotb parity targets
# below mirror the TL-UH bridge's verification surface.
ULITE_DIR := $(GEN_DIR)/ulite
ULITE_SV  := $(ULITE_DIR)/TLULToAXILite.sv

# TL-UC → AXI4 variant — emitted to $(GEN_DIR)/uc/.  TL-C wire shape
# (A/B/C/D/E) with no coherence; AXI4 downstream.  Carries TL-UH
# opcodes + AcquireBlock/AcquirePerm/Release/ReleaseData.
UC_DIR := $(GEN_DIR)/uc
UC_SV  := $(UC_DIR)/TLUCToAXI4.sv

# TL-C → CHI Issue-E variant — emitted to $(GEN_DIR)/chi/.  Stage 1
# skeleton only (lint-clean, no functional behavior).  See
# doc/CHI_PLAN.md for the roadmap and doc/DESIGN_SPEC_CHI.md for the
# protocol mapping.
CHI_DIR := $(GEN_DIR)/chi
CHI_SV  := $(CHI_DIR)/TLCToCHI.sv

SBT       := sbt
VERILATOR := verilator

TB_SRC      := test/cpp/tb_main.cpp
ULITE_TB    := test/cpp/tb_ulite.cpp
UC_TB       := test/cpp/tb_uc.cpp
CHI_TB      := test/cpp/tb_chi.cpp
BUILD_DIR   := build
ULITE_BUILD := build_ulite
UC_BUILD    := build_uc
CHI_BUILD   := build_chi
COV_DIR     := build_cov
SIM_EXE     := $(BUILD_DIR)/VTLUHToAXI4
ULITE_EXE   := $(ULITE_BUILD)/VTLULToAXILite
UC_EXE      := $(UC_BUILD)/VTLUCToAXI4
CHI_EXE     := $(CHI_BUILD)/VTLCToCHI
COV_EXE     := $(COV_DIR)/VTLUHToAXI4
COV_INFO    := coverage.info

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

ULITE_VERILATOR_FLAGS := \
    --cc \
    --exe \
    --build \
    --trace \
    -Wall \
    -Wno-fatal \
    $(LINT_SUPPRESS) \
    --top-module TLULToAXILite \
    -Mdir $(ULITE_BUILD) \
    -CFLAGS "-std=c++17 -O2"

UC_VERILATOR_FLAGS := \
    --cc \
    --exe \
    --build \
    --trace \
    -Wall \
    -Wno-fatal \
    $(LINT_SUPPRESS) \
    --top-module TLUCToAXI4 \
    -Mdir $(UC_BUILD) \
    -CFLAGS "-std=c++17 -O2"

CHI_VERILATOR_FLAGS := \
    --cc \
    --exe \
    --build \
    --trace \
    -Wall \
    -Wno-fatal \
    $(LINT_SUPPRESS) \
    --top-module TLCToCHI \
    -Mdir $(CHI_BUILD) \
    -CFLAGS "-std=c++17 -O2"

.PHONY: help all elab elab-widths build sim run lint lint-decoder lint-widths lint-ulite lint-uc lint-chi \
        build-ulite sim-ulite cocotb-ulite formal-ulite regress regress-ulite \
        build-uc sim-uc cocotb-uc formal-uc regress-uc \
        build-chi sim-chi cocotb-chi formal-chi regress-chi \
        coverage cov-report formal cocotb wave wave-formal wave-bmc ci clean

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
	@echo "  lint-ulite    Lint the TL-UL -> AXI4-Lite bridge variant"
	@echo "  build-ulite   Verilator TB build for the AXI-Lite bridge (no run)"
	@echo "  sim-ulite     Build + run the TL-UL -> AXI4-Lite Verilator TB"
	@echo "  formal-ulite  SymbiYosys BMC + cover for the AXI-Lite bridge"
	@echo "  cocotb-ulite  cocotb directed tests for the AXI-Lite bridge"
	@echo "  lint-uc       Lint the TL-UC (via TL-C) -> AXI4 bridge variant"
	@echo "  build-uc      Verilator TB build for the TL-UC bridge (no run)"
	@echo "  sim-uc        Build + run the TL-UC -> AXI4 Verilator TB"
	@echo "  formal-uc     SymbiYosys BMC + cover for the TL-UC bridge"
	@echo "  cocotb-uc     cocotb directed tests for the TL-UC bridge"
	@echo "  lint-chi      Lint the TL-C -> CHI bridge variant (Stage 1 skeleton)"
	@echo "  build-chi     Verilator TB build (gated on Stage 2 deliverables)"
	@echo "  sim-chi       Run the TL-C -> CHI TB (gated on Stage 2)"
	@echo "  formal-chi    SymbiYosys BMC + cover (gated on Stage 2)"
	@echo "  cocotb-chi    cocotb tests (gated on Stage 2)"
	@echo "  regress       lint(s) + sim across TLUH/ULite/UC plus lint-chi"
	@echo "  regress-ulite lint-ulite + sim-ulite"
	@echo "  regress-uc    lint-uc + sim-uc"
	@echo "  regress-chi   lint-chi (Stage 1)"
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

elab $(SV) $(DECODER_SV) $(ULITE_SV) $(UC_SV) $(CHI_SV):
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

lint-ulite: $(ULITE_SV)
	$(VERILATOR) --lint-only -Wall $(LINT_SUPPRESS) \
	    --top-module TLULToAXILite $(ULITE_SV)
	@echo "lint-ulite: 0 warnings"

lint-uc: $(UC_SV)
	$(VERILATOR) --lint-only -Wall $(LINT_SUPPRESS) \
	    --top-module TLUCToAXI4 $(UC_SV)
	@echo "lint-uc: 0 warnings"

lint-chi: $(CHI_SV)
	$(VERILATOR) --lint-only -Wall $(LINT_SUPPRESS) \
	    --top-module TLCToCHI $(CHI_SV)
	@echo "lint-chi: 0 warnings"

# ---- TL-UL → AXI4-Lite Verilator TB ----
build-ulite $(ULITE_EXE): $(ULITE_SV) $(ULITE_TB)
	$(VERILATOR) $(ULITE_VERILATOR_FLAGS) -o VTLULToAXILite $(ULITE_SV) $(ULITE_TB)

sim-ulite: $(ULITE_EXE)
	cd $(ULITE_BUILD) && ./VTLULToAXILite
	-@mv -f $(ULITE_BUILD)/sim_ulite.vcd sim_ulite.vcd 2>/dev/null

formal-ulite: $(ULITE_SV)
	$(MAKE) -C verification/formal ulite

cocotb-ulite: $(ULITE_SV)
	$(MAKE) -C cocotb ulite

# ---- TL-UC → AXI4 Verilator TB ----
build-uc $(UC_EXE): $(UC_SV) $(UC_TB)
	$(VERILATOR) $(UC_VERILATOR_FLAGS) -o VTLUCToAXI4 $(UC_SV) $(UC_TB)

sim-uc: $(UC_EXE)
	cd $(UC_BUILD) && ./VTLUCToAXI4
	-@mv -f $(UC_BUILD)/sim_uc.vcd sim_uc.vcd 2>/dev/null

formal-uc: $(UC_SV)
	$(MAKE) -C verification/formal uc

cocotb-uc: $(UC_SV)
	$(MAKE) -C cocotb uc

# ---- TL-C → CHI Verilator TB (Stage 1: TB stub not yet built) ----
# Stage 2+ will add test/cpp/tb_chi.cpp.  For now `sim-chi` only checks
# that elaboration + lint succeed; the build target is wired but the
# TB source is absent until Stage 2.
build-chi $(CHI_EXE): $(CHI_SV) $(CHI_TB)
	$(VERILATOR) $(CHI_VERILATOR_FLAGS) -o VTLCToCHI $(CHI_SV) $(CHI_TB)

sim-chi: $(CHI_EXE)
	cd $(CHI_BUILD) && ./VTLCToCHI
	-@mv -f $(CHI_BUILD)/sim_chi.vcd sim_chi.vcd 2>/dev/null

formal-chi: $(CHI_SV)
	$(MAKE) -C verification/formal chi

cocotb-chi: $(CHI_SV)
	$(MAKE) -C cocotb chi

# Regress includes lint-chi (Stage 1 deliverable).  sim-chi / formal-chi /
# cocotb-chi gate on Stage 2+ deliverables and are NOT in the default
# regress until those land.
regress: lint lint-decoder lint-widths lint-ulite lint-uc lint-chi sim sim-ulite sim-uc
regress-ulite: lint-ulite sim-ulite
regress-uc: lint-uc sim-uc
regress-chi: lint-chi

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

ci: regress coverage formal formal-ulite formal-uc cocotb cocotb-ulite cocotb-uc

clean:
	rm -rf $(GEN_DIR) $(BUILD_DIR) $(ULITE_BUILD) $(UC_BUILD) $(CHI_BUILD) $(COV_DIR) sim.vcd sim_ulite.vcd sim_uc.vcd sim_chi.vcd $(COV_INFO) coverage_html target project/target project/project
	$(MAKE) -C verification/formal clean
	rm -rf cocotb/sim_build cocotb/sim_build_ulite cocotb/sim_build_uc cocotb/sim_build_chi cocotb/__pycache__ cocotb/results.xml cocotb/*.vcd
