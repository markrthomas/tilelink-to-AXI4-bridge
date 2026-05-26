package tlbridge

import circt.stage.ChiselStage

object Main extends App {
  val outDir = "generated"
  ChiselStage.emitSystemVerilogFile(
    new TLUHToAXI4(BridgeParams()),
    Array("--target-dir", outDir),
    Array("-disable-all-randomization", "-strip-debug-info"),
  )
  println(s"Wrote SystemVerilog to ${outDir}/")
}
