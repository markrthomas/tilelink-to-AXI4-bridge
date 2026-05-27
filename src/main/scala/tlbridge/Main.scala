package tlbridge

import circt.stage.ChiselStage

object Main extends App {
  val outDir = "generated"
  ChiselStage.emitSystemVerilogFile(
    new TLUHToAXI4(BridgeParams()),
    Array("--target-dir", outDir),
    Array(
      "-disable-all-randomization",
      "-strip-debug-info",
      // Yosys' SystemVerilog frontend rejects `automatic logic` declarations
      // inside always blocks; disallow them so firtool lifts temporaries to
      // module-level wires. Keeps the emitted SV consumable by SymbiYosys.
      "--lowering-options=disallowLocalVariables",
    ),
  )
  println(s"Wrote SystemVerilog to ${outDir}/")
}
