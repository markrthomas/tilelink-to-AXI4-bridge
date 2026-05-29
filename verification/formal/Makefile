SBY ?= sby
RTL_SV       := ../../generated/TLUHToAXI4.sv
ULITE_RTL_SV := ../../generated/ulite/TLULToAXILite.sv
UC_RTL_SV    := ../../generated/uc/TLUCToAXI4.sv

.PHONY: all bmc cover ulite ulite-bmc ulite-cover uc uc-bmc uc-cover clean

all: bmc cover

$(RTL_SV) $(ULITE_RTL_SV) $(UC_RTL_SV):
	$(MAKE) -C ../.. elab

bmc: $(RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby bmc

cover: $(RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby cover

# ---- TL-UL → AXI4-Lite variant ----
ulite: ulite-bmc ulite-cover

ulite-bmc: $(ULITE_RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tlultoaxilite.sby bmc

ulite-cover: $(ULITE_RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tlultoaxilite.sby cover

# ---- TL-UC → AXI4 variant ----
uc: uc-bmc uc-cover

uc-bmc: $(UC_RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluctoaxi4.sby bmc

uc-cover: $(UC_RTL_SV)
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluctoaxi4.sby cover

clean:
	rm -rf tluhtoaxi4_bmc tluhtoaxi4_cover tlultoaxilite_bmc tlultoaxilite_cover tluctoaxi4_bmc tluctoaxi4_cover
