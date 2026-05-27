TOPLEVEL_LANG = verilog
SIM ?= icarus

VERILOG_SOURCES = $(PWD)/../generated/TLUHToAXI4.sv
TOPLEVEL        = TLUHToAXI4
MODULE          = test_bridge

# OSS CAD Suite ships its own Icarus + Python; force the system installs so
# the GPI module loads the same Python that has cocotb on PYTHONPATH.
ICARUS_BIN_DIR ?= /usr/bin
SIM_CMD_PREFIX := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export PYTHONPATH := $(PWD):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
