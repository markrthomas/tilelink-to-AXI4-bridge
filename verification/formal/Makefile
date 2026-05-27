SBY ?= sby
RTL_SV := ../../generated/TLUHToAXI4.sv

.PHONY: all bmc cover clean

all: bmc cover

$(RTL_SV):
	$(MAKE) -C ../.. elab

bmc: $(RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby bmc

cover: $(RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby cover

clean:
	rm -rf tluhtoaxi4_bmc tluhtoaxi4_cover
