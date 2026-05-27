SBY ?= sby

.PHONY: all bmc cover clean

all: bmc cover

bmc:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby bmc

cover:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[formal] sby not on PATH"; exit 1; }
	$(SBY) -f tluhtoaxi4.sby cover

clean:
	rm -rf tluhtoaxi4_bmc tluhtoaxi4_cover
