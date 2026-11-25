# Integration guide — TileLink → AXI bridges

Tapeout-readiness program **T7** (integration / packaging) deliverable. This guide + the
IP-XACT in `ip-xact/` are what an SoC integrator needs to instance the IP. The DUT is
Chisel; the IP-XACT model ports are kept in sync with the elaborated SV by `make pkg`
(which elaborates Chisel → SV first if needed).

## IP variants

| Top (module / IP-XACT name) | What | Ports |
|---|---|---|
| `TLUHToAXI4`    | TileLink-UH subordinate → AXI4 manager bridge | 53 |
| `TLULToAXILite` | TileLink-UL subordinate → AXI4-Lite manager bridge | 36 |
| `TLUCToAXI4`    | TileLink-UC subordinate → AXI4 manager bridge | 68 |

(`TLCToCHI` — TileLink-C → CHI — is coherence WIP and out of this T6/T7 scope, as in `syn/synth.sh`.)

## Interfaces

Each top presents, grouped in the IP-XACT by `io_` prefix:

| Interface | Role | Signals |
|---|---|---|
| `TL`  | TileLink **subordinate** (slave) | `io_tl_*` (A/D channels: valid/ready/bits_*) |
| `AXI` | AXI(-Lite) **manager** (master) | `io_axi_*` (AW/W/B/AR/R channels: valid/ready/bits_*) |
| `clock` | clock | single clock domain (whole IP). |

The tops are **reset-less at the port boundary** (no `reset` port on the generated module —
Chisel folds initialization); drive `clock` from the SoC and follow the design-contract
power-on sequence.

## Clock / reset / power

- **Clock:** one domain, `clock`. No internal CDC (single-clock; T1-CDC = n/a). Constrain
  with `../syn/constraints/tl_axi4.sdc` (T2).
- **Power:** single always-on domain, no power gating (T3: `../syn/lp/tl_axi4.upf` confirms
  the always-on contract is well-formed).

## Register / address map

Pure protocol bridges — no memory-mapped CSR block, so no CSR RAL. Addressing is pass-through:
the TileLink A-channel address is translated to the AXI AW/AR address (width per the AXI
channel). The AXI manager's downstream address map is the integrator's SoC decode, not part
of this IP.

## Parameters / configuration

The bridges are **Chisel-parameterized at elaboration**, not via SystemVerilog parameters —
the generated SV has fixed widths (AXI data 64 / TL as configured in `src/main/scala/tlbridge`).
To change a width, edit the Scala and re-`make elab`; the IP-XACT (and `make pkg`) then
reflect the new ports. There are no runtime SV parameters to override.

## Consuming the package

- **IP-XACT** (`ip-xact/{TLUHToAXI4,TLULToAXILite,TLUCToAXI4}.xml`): IEEE 1685-2014 components
  — `TL` + `AXI` bus interfaces (grouped by `io_` prefix) + `clock`, full model port list.
- **Source**: the component `fileSet` references the generated SV (git-ignored; `make elab`)
  and the Chisel source `src/main/scala/tlbridge`.
- **Validate** with `make pkg` (`pkg/check_ipxact.sh`): elaborates Chisel → SV, then
  well-formed + structural + a hard IP-XACT↔SV model-port match (53/36/68; fails on drift).
  Full XSD: `IPXACT_XSD=… make pkg`.

## Sign-off cross-reference

See [`../syn/SIGNOFF.md`](../syn/SIGNOFF.md) for T0–T7. T6: PPA proxy passes; the iverilog
GLS gate is not applicable to this Chisel/C++-TB block — the Verilator-netlist GLS recipe is
authored in `../syn/gls/T6_PLAN.md`. Real STA / SDF GLS / PPA / scan+ATPG are needs-pdk.
