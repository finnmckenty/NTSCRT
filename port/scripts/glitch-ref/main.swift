// glitch-ref: the Mac's receiver simulation (Receiver.swift, GlitchParams.swift,
// compiled as-is) printing field plans as JSON, for checking the Rust port.
//   glitch-ref <width> <height> <time> [key=value ...]
import Foundation

let a = CommandLine.arguments
let w = Int(a[1])!, h = Int(a[2])!, time = Double(a[3])!
var values: [String: Double] = [:]
for kv in a.dropFirst(4) {
    let p = kv.split(separator: "=")
    values[String(p[0])] = Double(p[1])!
}
let settings = GlitchSettings(values: values)
let sim = ReceiverSimulator(raster: ReceiverRaster(width: w, activeLines: h))
// Frame by frame at 30 fps, as playback and export advance.
var t = 0.0
sim.advance(to: 0, settings: settings)
while t < time { t = min(time, t + 1.0 / 30.0); sim.advance(to: t, settings: settings) }
let plan = sim.plan()
let rows = plan.rows.map { r in
    [Double(r.u0), Double(r.fieldLine), Double(r.lenPrev), Double(r.lenCur), Double(r.lenNext),
     Double(r.noiseIRE), Double(r.humIRE), Double(r.burstScale), Double(r.tapeLoss), Double(r.gateShift)]
}
let drops = plan.dropouts.map { [Double($0.fieldLine), Double($0.uStart), Double($0.uLength)] }
let out: [String: Any] = [
    "time": sim.time, "nominalTrigger": sim.nominalTrigger, "rows": rows, "dropouts": drops,
    "chroma": [Double(plan.chromaPhase), Double(plan.chromaGain), Double(plan.killer), plan.colorOn ? 1.0 : 0.0],
    "pictureGain": Double(plan.pictureGain), "ccBits": Int(plan.ccBits), "fieldIndex": Int(plan.fieldIndex),
]
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
