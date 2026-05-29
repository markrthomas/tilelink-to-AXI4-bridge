SBY ?= sby
RTL_SV       := ../../generated/TLUHToAXI4.sv
ULITE_RTL_SV := ../../generated/ulite/TLULToAXILite.sv
UC_RTL_SV    := ../../generated/uc/TLUCToAXI4.sv
CHI_RTL_SV   := ../../generated/chi/TLCToCHI.sv

.PHONY: all bmc cover ulite ulite-bmc ulite-cover uc uc-bmc uc-cover chi chi-bmc chi-cover clean

all: bmc cover

$(RTL_SV) $(ULITE_RTL_SV) $(UC_RTL_SV) $(CHI_RTL_SV):
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

# ---- TL-C → CHI variant ----
# Stage 1 has no formal wrapper yet; the chi target prints a notice and
# exits 0 so CI doesn't fail on its absence.  Stage 2 will land
# tlctochi.sby + tlctochi_props.sv.
chi:
	@echo "[formal] chi: Stage 1 skeleton has no formal wrapper yet (see doc/CHI_PLAN.md Stage 2)"

chi-bmc chi-cover: chi

clean:
	rm -rf tluhtoaxi4_bmc tluhtoaxi4_cover tlultoaxilite_bmc tlultoaxilite_cover tluctoaxi4_bmc tluctoaxi4_cover tlctochi_bmc tlctochi_cover
