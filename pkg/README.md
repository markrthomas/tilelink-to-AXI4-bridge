# pkg/ — IP packaging (tapeout-readiness T7)

Packaging deliverables for the TileLink → AXI bridges. Adopted from the shared sign-off kit
(`dv-swarm-kit/templates/signoff/pkg`), pathfound on `IP-axi-to-2apbs`.

## Contents

| Path | What |
|---|---|
| `ip-xact/TLUHToAXI4.xml` | IP-XACT (IEEE 1685-2014) component — TL-UH → AXI4 (53 ports). |
| `ip-xact/TLULToAXILite.xml` | IP-XACT component — TL-UL → AXI4-Lite (36 ports). |
| `ip-xact/TLUCToAXI4.xml` | IP-XACT component — TL-UC → AXI4 (68 ports). |
| `INTEGRATION.md` | Integration guide: variants, interfaces, clock/power, addressing, how to consume. |
| `check_ipxact.sh` | The `make pkg` gate: elaborate Chisel→SV, then well-formed + structural + IP-XACT↔SV port-sync. |

## Run the gate

```
make pkg          # make elab (if needed) + well-formed + structural + model-ports-match-SV (53/36/68)
IPXACT_XSD=/path/to/1685-2014/index.xsd make pkg   # + full XSD schema validation
```

Because the DUT is Chisel and `generated/*.sv` is git-ignored, the committed IP-XACT is the
contract and `make pkg` re-checks it against freshly-elaborated SV — it fails on any drift
between the model ports and the regenerated design.

## Scope

OSS, no-PDK packaging layer. Real-silicon collateral needing a PDK or licensed tool is
tracked in [`../syn/SIGNOFF.md`](../syn/SIGNOFF.md). Note T6-GLS: the iverilog gate is not
applicable to this Chisel/C++-TB block; see `../syn/gls/T6_PLAN.md` for the Verilator-netlist
recipe.
