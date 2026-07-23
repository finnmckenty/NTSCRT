// crt-video-smoke: Phase 3 verifier for Mp4Exporter.
//
// Usage:
//   crt-video-smoke <input.mp4> <preset.slangp> <output.mp4> <librashader.dylib>
//                   [outW outH] [downW downH method]

import Foundation
import CrtAppBridge
import CrtCore

@main
struct VideoSmoke {
    static func main() async {
        var raw = Array(CommandLine.arguments.dropFirst())
        var codec: Mp4Exporter.Codec = .h264
        var bitrate: Int? = nil
        var positional: [String] = [CommandLine.arguments[0]]
        while !raw.isEmpty {
            let a = raw.removeFirst()
            if a == "--codec", !raw.isEmpty {
                switch raw.removeFirst().lowercased() {
                case "h264": codec = .h264
                case "hevc": codec = .hevc
                case "prores422": codec = .prores422
                case "prores422hq": codec = .prores422HQ
                default: fputs("unknown codec\n", stderr); exit(2)
                }
            } else if a == "--bitrate", !raw.isEmpty {
                bitrate = Int(raw.removeFirst())
            } else {
                positional.append(a)
            }
        }
        let args = positional
        guard args.count >= 5 else {
            fputs("usage: crt-video-smoke <input.mp4> <preset.slangp> <output.mp4> <librashader.dylib> [outW outH] [downW downH method]\n", stderr)
            exit(2)
        }
        let inputPath  = args[1]
        let presetPath = args[2]
        let outputPath = args[3]
        let dylibPath  = args[4]
        let outW = args.count > 5 ? Int(args[5]) ?? 1920 : 1920
        let outH = args.count > 6 ? Int(args[6]) ?? 1080 : 1080
        let downscale: DownscaleSpec? = {
            guard args.count > 9,
                  let dw = Int(args[7]), let dh = Int(args[8]),
                  let m = DownscaleMethod(rawValue: args[9]) else { return nil }
            return DownscaleSpec(width: dw, height: dh, method: m)
        }()

        do {
            try LRShaderChain.loadLibrary(dylibPath)
        } catch {
            fputs("loadLibrary: \(error.localizedDescription)\n", stderr); exit(3)
        }

        let context: MetalContext
        do { context = try MetalContext() }
        catch { fputs("MetalContext: \(error.localizedDescription)\n", stderr); exit(4) }

        do {
            let inputURL = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath)
            let vs = try await VideoSource(url: inputURL, device: context.device)
            print("input: \(Int(vs.pixelSize.width))x\(Int(vs.pixelSize.height)), \(vs.totalFrames) frames @ \(vs.frameRate) fps, \(String(format: "%.2fs", vs.durationSeconds))")

            let exporter = Mp4Exporter(context: context)
            let settings = Mp4Exporter.Settings(
                outputURL: outputURL,
                outputWidth: outW,
                outputHeight: outH,
                downscale: downscale,
                presetPath: presetPath,
                codec: codec,
                averageBitrate: bitrate
            )
            try await exporter.export(source: vs, paramValues: [:], settings: settings) { p in
                let pct = Int((p * 100).rounded())
                FileHandle.standardError.write(Data("\rprogress \(pct)%".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            print("wrote \(outputPath)")
        } catch {
            fputs("export failed: \(error.localizedDescription)\n", stderr); exit(10)
        }
    }
}
