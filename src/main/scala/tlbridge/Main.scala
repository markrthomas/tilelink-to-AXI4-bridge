package tlbridge

import circt.stage.ChiselStage

object EmitConfig {
  val firtoolArgs: Array[String] = Array(
    "-disable-all-randomization",
    "-strip-debug-info",
    // Yosys' SystemVerilog frontend rejects `automatic logic` declarations
    // inside always blocks; disallow them so firtool lifts temporaries to
    // module-level wires. Keeps the emitted SV consumable by SymbiYosys.
    "--lowering-options=disallowLocalVariables",
  )
}

object Main extends App {
  val outDir = "generated"

  // Single-port bridge — the primary output, consumed by tb_main.cpp,
  // SymbiYosys, cocotb, and the CI pipeline.
  ChiselStage.emitSystemVerilogFile(
    new TLUHToAXI4(BridgeParams()),
    Array("--target-dir", outDir),
    EmitConfig.firtoolArgs,
  )

  // Address-decoded variant — sample 2-region split at the 2 GiB
  // boundary.  Downstream consumers customize the region table for their
  // own SoC.  Emitted to a separate subdirectory because firtool's
  // child-module inlining (which prunes unused inputs and constant
  // outputs on TLUHToAXI4 when it's a child of the decoder) would
  // otherwise overwrite the standalone bridge that the C++ TB, formal
  // wrapper, and cocotb env consume.
  val decoderOutDir = s"$outDir/decoder"
  val sampleRegions = Seq(
    DecodeRegion(BigInt(0),           BigInt("80000000", 16)),  // low 2 GiB
    DecodeRegion(BigInt("80000000", 16), BigInt("100000000", 16)),  // high 2 GiB
  )
  ChiselStage.emitSystemVerilogFile(
    new TLUHToAXI4Decoder(BridgeParams(), sampleRegions),
    Array("--target-dir", decoderOutDir),
    EmitConfig.firtoolArgs,
  )

  // TL-UL → AXI4-Lite bridge — Get/Put/PutPartial/Hint, single-beat, 32-bit
  // default data path.  Emitted into a separate subdirectory so the file
  // layout mirrors the address-decoded variant and downstream consumers
  // (lint, formal, cocotb, C++ TB) pick up the right top.
  val uliteOutDir = s"$outDir/ulite"
  ChiselStage.emitSystemVerilogFile(
    new TLULToAXILite(ULBridgeParams()),
    Array("--target-dir", uliteOutDir),
    EmitConfig.firtoolArgs,
  )

  // TL-UC → AXI4 bridge — TL-C channel shape (A/B/C/D/E) with no
  // coherence.  Carries TL-UH opcodes plus AcquireBlock/AcquirePerm and
  // Release/ReleaseData; B (probe) is tied off.
  val ucOutDir = s"$outDir/uc"
  ChiselStage.emitSystemVerilogFile(
    new TLUCToAXI4(BridgeParams()),
    Array("--target-dir", ucOutDir),
    EmitConfig.firtoolArgs,
  )

  // TL-C → CHI Issue-E bridge.  Stage 1 skeleton: all five TL-C
  // channels (A/B/C/D/E) + all four CHI channels (REQ/RSP/DAT/SNP,
  // split into RN-tx and RN-rx halves) exposed; every output tied to
  // a safe default; no functional behavior yet.  See doc/CHI_PLAN.md
  // for the staged roadmap and doc/DESIGN_SPEC_CHI.md for the mapping.
  val chiOutDir = s"$outDir/chi"
  ChiselStage.emitSystemVerilogFile(
    new TLCToCHI(CHIBridgeParams()),
    Array("--target-dir", chiOutDir),
    EmitConfig.firtoolArgs,
  )

  println(s"Wrote SystemVerilog to $outDir/, $decoderOutDir/, $uliteOutDir/, $ucOutDir/, and $chiOutDir/")
}

object WidthSweep extends App {
  val widths = Seq(32, 64, 128, 256)
  widths.foreach { dataBits =>
    val outDir = s"generated/widths/w$dataBits"
    ChiselStage.emitSystemVerilogFile(
      new TLUHToAXI4(BridgeParams(dataBits = dataBits)),
      Array("--target-dir", outDir),
      EmitConfig.firtoolArgs,
    )
  }
  println(s"Wrote width-sweep SystemVerilog for dataBits=${widths.mkString(",")}")
}
