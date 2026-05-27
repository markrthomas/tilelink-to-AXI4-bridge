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

  println(s"Wrote SystemVerilog to $outDir/ and $decoderOutDir/")
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
