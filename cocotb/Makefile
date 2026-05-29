TOPLEVEL_LANG = verilog
SIM ?= icarus
VARIANT ?= tluh

# Variant switch — `make` (with no VARIANT) runs the TL-UH bridge tests;
# `make ulite` / `make uc` run the AXI-Lite / TL-UC variants against the
# same cocotb harness.  cocotb's Makefile.sim defines the `sim` target as
# its default goal; we delegate to it via VARIANT={ulite,uc}.
ifeq ($(VARIANT),ulite)
VERILOG_SOURCES = $(PWD)/../generated/ulite/TLULToAXILite.sv
TOPLEVEL        = TLULToAXILite
MODULE          = test_ulite
SIM_BUILD       = sim_build_ulite
else ifeq ($(VARIANT),uc)
VERILOG_SOURCES = $(PWD)/../generated/uc/TLUCToAXI4.sv
TOPLEVEL        = TLUCToAXI4
MODULE          = test_uc
SIM_BUILD       = sim_build_uc
else
VERILOG_SOURCES = $(PWD)/../generated/TLUHToAXI4.sv
TOPLEVEL        = TLUHToAXI4
MODULE          = test_bridge
endif

# `make` (no arg) should run the default TL-UH suite via cocotb's Makefile.sim;
# `make ulite` / `make uc` re-invoke make with the matching VARIANT and an
# explicit `sim` goal.  Without .DEFAULT_GOAL the variant recipes (declared
# before the include) would become the default goal and steal `make` invocations.
.DEFAULT_GOAL := sim

.PHONY: ulite uc
ulite:
	$(MAKE) VARIANT=ulite sim

uc:
	$(MAKE) VARIANT=uc sim

# OSS CAD Suite ships its own Icarus + Python; force the system installs so
# the GPI module loads the same Python that has cocotb on PYTHONPATH.
ICARUS_BIN_DIR ?= /usr/bin
SIM_CMD_PREFIX := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export PYTHONPATH := $(PWD):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
