import XCTest
@testable import CrtCodec

/// The Digital video stage: a real block codec, so the tests check codec
/// behavior — transforms, timing, the encoder/decoder split behind smearing
/// and datamoshing — and above all that a frame looks the same however it's
/// reached (played through, jumped to, re-run from a checkpoint).
final class DigitalVideoTests: XCTestCase {

    // A synthetic clip: a textured background with a bright square moving
    // right; `cut` switches to a different scene from that frame on.
    let size = (width: 256, height: 192)
    let capture = (width: 128, height: 96)

    func frame(_ n: Int, cut: Int? = nil) -> [UInt8] {
        let (w, h) = size
        let scene = (cut.map { n >= $0 } ?? false) ? 1 : 0
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var r: Int, g: Int, b: Int
                if scene == 0 {
                    r = (x * 255) / w
                    g = ((x / 8 + y / 8) % 2) * 120 + 40
                    b = (y * 255) / h
                } else {
                    r = 200 - (y * 150) / h
                    g = ((x / 16) % 2) * 60 + 90
                    b = 60 + (x * 120) / w
                }
                let sx = 20 + 4 * n, sy = 60 + 2 * n
                if x >= sx, x < sx + 40, y >= sy, y < sy + 40 { r = 250; g = 240; b = 30 }
                px[i] = UInt8(b); px[i + 1] = UInt8(g); px[i + 2] = UInt8(r)
            }
        }
        return px
    }

    func visitor(cut: Int? = nil) -> DigitalFrameVisitor {
        { [self] i, body in
            let f = frame(i, cut: cut)
            f.withUnsafeBytes { body($0.baseAddress!, size.width, size.height, size.width * 4) }
            return true
        }
    }

    func settings(_ format: String, _ overrides: [String: Double] = [:]) -> DigitalSettings {
        DigitalSettings(values: DigitalFormat.byID[format]!.values.merging(overrides) { _, n in n })
    }

    func render(_ r: DigitalVideoRenderer, _ n: Int, _ s: DigitalSettings, fps: Double = 30,
                cut: Int? = nil, history: DigitalHistory? = nil) -> [UInt8] {
        var px = frame(n, cut: cut)
        px.withUnsafeMutableBytes {
            r.process(frame: n, pixels: $0.baseAddress!, width: size.width, height: size.height,
                      rowBytes: size.width * 4, captureSize: capture, sourceFPS: fps,
                      settings: s, history: history, earlier: visitor(cut: cut))
        }
        return px
    }

    func played(_ s: DigitalSettings, frames: Int, cut: Int? = nil,
                history: DigitalHistory? = nil) -> [[UInt8]] {
        let r = DigitalVideoRenderer()
        return (0..<frames).map { render(r, $0, s, cut: cut, history: history) }
    }

    func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var s = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            s += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
        }
        return Double(s) / Double(a.count / 4 * 3)
    }

    // MARK: - transforms

    func testDCTRoundTripIsIdentity() {
        var block = [Float](repeating: 0, count: 64)
        for i in 0..<64 { block[i] = Float((i * 37) % 255) - 128 }
        var coef = [Float](repeating: 0, count: 64), back = coef, tmp = coef
        DigitalCodec.basis.withUnsafeBufferPointer { c in
            DigitalCodec.forwardDCT(block, stride: 8, &coef, &tmp, c.baseAddress!)
            DigitalCodec.inverseDCT(coef, &back, stride: 8, &tmp, c.baseAddress!)
        }
        for i in 0..<64 { XCTAssertEqual(back[i], block[i], accuracy: 1e-3) }
        // Orthonormal: a flat block of 1s has DC 8 and nothing else.
        let flat = [Float](repeating: 1, count: 64)
        DigitalCodec.basis.withUnsafeBufferPointer { c in
            DigitalCodec.forwardDCT(flat, stride: 8, &coef, &tmp, c.baseAddress!)
        }
        XCTAssertEqual(coef[0], 8, accuracy: 1e-4)
        XCTAssertEqual(coef[1...].map(abs).max()!, 0, accuracy: 1e-4)
    }

    func testLowerQualityLosesMoreOfThePicture() {
        let clean = DigitalSettings(values: ["frame_rate": 30, "sensor_noise": 0, "noise_reduction": 0,
                                             "chroma": 0, "keyframe_interval": 0])
        var errors: [Double] = []
        for q in [0.95, 0.6, 0.3, 0.05] {
            var s = clean; s.values["quality"] = q
            let out = render(DigitalVideoRenderer(), 0, s)
            // Against the stage at its finest, with nothing else in play.
            errors.append(meanDifference(out, frame(0)))
        }
        XCTAssertEqual(errors, errors.sorted(), "quality \(errors)")
        XCTAssertLessThan(errors[0], 6, "near-lossless at 95: \(errors)")
        XCTAssertGreaterThan(errors[3], 3 * errors[0], "\(errors)")
    }

    // MARK: - timing

    func testCaptureTimingHoldsFramesAndPlacesKeyframes() {
        let t = DigitalTiming(sourceFPS: 30, settings: DigitalSettings(values: ["frame_rate": 15, "keyframe_interval": 2]))
        XCTAssertEqual((0..<6).map(t.capture(ofFrame:)), [0, 0, 1, 1, 2, 2])
        for c in 0..<50 { XCTAssertEqual(t.capture(ofFrame: t.frame(ofCapture: c)), c) }
        XCTAssertEqual(t.keyframeEvery, 30)
        XCTAssertEqual(t.kind(ofCapture: 0, datamosh: 1), .key, "the first keyframe always arrives")
        XCTAssertEqual(t.kind(ofCapture: 30, datamosh: 1), .droppedKey)
        XCTAssertEqual(t.kind(ofCapture: 31, datamosh: 1), .predicted)
        // Never faster than the source; 0 s means every frame on its own.
        let fast = DigitalTiming(sourceFPS: 24, settings: DigitalSettings(values: ["frame_rate": 60, "keyframe_interval": 0]))
        XCTAssertEqual(fast.captureFPS, 24)
        XCTAssertTrue(fast.intraOnly)
        XCTAssertEqual((0..<4).map(fast.capture(ofFrame:)), [0, 1, 2, 3])
    }

    func testLowerFrameRateRepeatsFrames() {
        let out = played(settings("webcam", ["sensor_noise": 0]), frames: 4)   // 15 fps of 30
        XCTAssertTrue(out[0] == out[1])
        XCTAssertTrue(out[1] != out[2])
        XCTAssertTrue(out[2] == out[3])
    }

    // MARK: - the same frame however it's reached

    func checkJumpsMatchPlaying(_ s: DigitalSettings, frames: Int = 40, cut: Int? = nil,
                                history: DigitalHistory? = nil, _ label: String) {
        let straight = played(s, frames: frames, cut: cut, history: history)
        let jumper = DigitalVideoRenderer()
        for n in [frames - 1, 3, 27, 12, frames - 2, 0, 33] where n < frames {
            XCTAssertTrue(render(jumper, n, s, cut: cut, history: history) == straight[n],
                          "\(label): frame \(n) jumped to")
        }
        // A fresh renderer per frame too (nothing cached at all).
        for n in [5, 19, 36] where n < frames {
            XCTAssertTrue(render(DigitalVideoRenderer(), n, s, cut: cut, history: history) == straight[n],
                          "\(label): frame \(n) fresh")
        }
    }

    func testEveryFormatLooksTheSameJumpedToAsPlayed() {
        for f in DigitalFormat.all {
            checkJumpsMatchPlaying(settings(f.id, ["keyframe_interval": min(1, DigitalFormat.byID[f.id]!.values["keyframe_interval"]!)]),
                                   cut: 20, f.id)
        }
    }

    func testDataLossAndDatamoshLookTheSameJumpedTo() {
        let s = DigitalSettings(values: ["frame_rate": 30, "keyframe_interval": 0.5, "quality": 0.4,
                                         "data_loss": 0.6, "datamosh": 0.6, "sensor_noise": 0.2,
                                         "noise_reduction": 0.3, "deblocking": 0.5, "fixed_bitrate": 0.5])
        checkJumpsMatchPlaying(s, cut: 16, "loss + mosh")
    }

    func testKeyframedSettingsLookTheSameJumpedTo() {
        let base = settings("video_call", ["keyframe_interval": 0.5, "frame_rate": 30])
        let history = DigitalHistory(id: 7) { n in
            var s = base
            s.values["quality"] = 0.1 + 0.02 * Double(n)
            s.values["data_loss"] = n > 15 ? 0.5 : 0
            return s
        }
        checkJumpsMatchPlaying(base, history: history, "keyframes")
    }

    func testDatamoshCheckpointsSpareTheReRun() {
        let s = settings("datamosh", ["keyframe_interval": 0.2])   // keyframes every 6 frames, all lost
        let r = DigitalVideoRenderer()
        for n in 0..<40 { _ = render(r, n, s) }
        _ = render(r, 3, s)                       // jump back...
        _ = render(r, 38, s)                      // ...and forward again
        XCTAssertLessThanOrEqual(r.lastRunLength, 6, "resumed from the checkpoint at 36, not from frame 0")
    }

    // MARK: - errors behave like a codec's

    func testLostDataSmearsUntilTheNextKeyframe() {
        let clean = settings("early_web", ["keyframe_interval": 0.5, "frame_rate": 30, "fixed_bitrate": 0])
        var lossy = clean
        lossy.values["data_loss"] = 0.8
        let a = played(clean, frames: 31), b = played(lossy, frames: 31)
        // Keyframes at 0, 15, 30 arrive whole: the damage is gone there.
        XCTAssertTrue(a[0] == b[0], "frame 0")
        XCTAssertTrue(a[15] == b[15], "frame 15")
        XCTAssertTrue(a[30] == b[30], "frame 30")
        // Between them it lingers — and builds.
        XCTAssertGreaterThan(meanDifference(a[14], b[14]), 0.5)
        XCTAssertGreaterThan(meanDifference(a[14], b[14]), meanDifference(a[2], b[2]))
    }

    func testDVDropoutsLastOneFrame() {
        let clean = settings("minidv", ["sensor_noise": 0])
        var lossy = clean
        lossy.values["data_loss"] = 0.8
        let a = played(clean, frames: 10), b = played(lossy, frames: 10)
        let damaged = (1..<10).filter { a[$0] != b[$0] }
        XCTAssertFalse(damaged.isEmpty)
        // Each frame is coded alone: damage never exceeds a patch from the
        // previous frame (the moving square moves 4 px a frame).
        for n in damaged { XCTAssertLessThan(meanDifference(a[n], b[n]), 8, "frame \(n)") }
    }

    func testDatamoshDragsTheOldSceneAcrossACut() {
        let normal = settings("datamosh", ["datamosh": 0, "keyframe_interval": 0.5])   // keys at 0, 15, 30
        let moshed = settings("datamosh", ["datamosh": 1, "keyframe_interval": 0.5])
        let cut = 15
        let a = played(normal, frames: 25, cut: cut), b = played(moshed, frames: 25, cut: cut)
        XCTAssertTrue(a[14] == b[14], "identical until the lost keyframe")
        // After the cut a normal decoder shows the new scene; the moshed one
        // is still mostly the old one.
        let newScene = frame(20, cut: cut), oldScene = frame(20)
        XCTAssertLessThan(meanDifference(a[20], newScene), meanDifference(a[20], oldScene))
        XCTAssertLessThan(meanDifference(b[20], oldScene), meanDifference(b[20], newScene))
    }

    // MARK: - fitting into the chain

    func testNearestDownscaleGetsTheCapturePictureBack() {
        for (w, h, cw, ch) in [(256, 192, 128, 96), (1000, 750, 320, 240), (480, 360, 320, 240), (333, 250, 320, 240)] {
            var pic = [UInt8](repeating: 0, count: cw * ch * 4)
            for i in 0..<pic.count { pic[i] = UInt8((i * 7919) % 251) }
            var big = [UInt8](repeating: 0, count: w * h * 4)
            big.withUnsafeMutableBytes {
                DigitalVideoRenderer.upscale(pic, size: (cw, ch), into: $0.baseAddress!, width: w, height: h, rowBytes: w * 4)
            }
            // The Downscaler's nearest kernel samples each pixel's center.
            for y in 0..<ch {
                for x in 0..<cw {
                    let sx = Int((Double(x) + 0.5) * Double(w) / Double(cw))
                    let sy = Int((Double(y) + 0.5) * Double(h) / Double(ch))
                    let s = (sy * w + sx) * 4, d = (y * cw + x) * 4
                    XCTAssertEqual(Array(big[s..<s + 4]), Array(pic[d..<d + 4]), "\(w)x\(h)→\(cw)x\(ch) at \(x),\(y)")
                    if big[s..<s + 4] != pic[d..<d + 4] { return }
                }
            }
        }
    }

    func testCaptureSizeFollowsTheDownscaleRule() {
        XCTAssertEqual(DigitalVideoRenderer.captureSize(width: 1920, height: 1080, captureWidth: 320).height, 180)
        XCTAssertEqual(DigitalVideoRenderer.captureSize(width: 2048, height: 2048, captureWidth: 320).height, 320)
        XCTAssertEqual(DigitalVideoRenderer.captureSize(width: 200, height: 100, captureWidth: 720).width, 200,
                       "never larger than the picture")
    }

    func testQuarterWideColorSmearsSideways() {
        // 4:1:1 keeps a quarter of the color across, all of it down.
        let g = CodecGeometry(width: 64, height: 64, chroma: .quarterWide)
        var px = [UInt8](repeating: 128, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 where x % 4 < 2 { px[(y * 64 + x) * 4 + 2] = 255 } }   // red stripes
        let pic = DigitalVideoRenderer.capture(px, geometry: g, settings: DigitalSettings(values: ["sensor_noise": 0, "noise_reduction": 0]), index: 0)
        XCTAssertEqual(pic.cr.width, 16)
        let row = (0..<16).map { pic.cr.data[$0] }
        XCTAssertLessThan(row.max()! - row.min()!, 0.01, "stripes 2 px wide average out")
        let g2 = CodecGeometry(width: 64, height: 64, chroma: .full)
        let full = DigitalVideoRenderer.capture(px, geometry: g2, settings: DigitalSettings(values: ["sensor_noise": 0, "noise_reduction": 0]), index: 0)
        XCTAssertGreaterThan(full.cr.data[0] - full.cr.data[2], 50)
    }

    func testFormatsAreRecognizedByTheirValues() {
        for f in DigitalFormat.all {
            XCTAssertEqual(DigitalFormat.matching(values: f.values, width: f.width)?.id, f.id)
        }
        var v = DigitalFormat.byID["webcam"]!.values
        v["quality"] = 0.9
        XCTAssertNil(DigitalFormat.matching(values: v, width: 320))
    }

    // MARK: - cost

    func testCodecIsFastEnoughForPlayback() {
        func perFrame(_ format: String, width: Int, height: Int) -> Double {
            let r = DigitalVideoRenderer()
            let s = settings(format, ["frame_rate": 30])
            var px = [UInt8](repeating: 0, count: 1280 * 720 * 4)
            for i in 0..<px.count { px[i] = UInt8((i * 31 + i / 5000) & 255) }
            let t0 = Date()
            for n in 0..<20 {
                px.withUnsafeMutableBytes {
                    r.process(frame: n, pixels: $0.baseAddress!, width: 1280, height: 720, rowBytes: 1280 * 4,
                              captureSize: (width, height), sourceFPS: 30, settings: s)
                }
            }
            return Date().timeIntervalSince(t0) / 20 * 1000
        }
        let call = perFrame("video_call", width: 320, height: 180)
        let dv = perFrame("minidv", width: 720, height: 404)
        print("DIGITAL-PERF video call 320: \(String(format: "%.1f", call)) ms/frame, MiniDV 720: \(String(format: "%.1f", dv)) ms/frame (from 1280×720)")
        #if !DEBUG
        // Only an optimized build says anything about real cost.
        XCTAssertLessThan(call, 30)
        XCTAssertLessThan(dv, 40)
        #endif
    }
}
