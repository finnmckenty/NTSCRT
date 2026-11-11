import XCTest
@testable import CrtCodec

/// Microsoft Video 1: 4×4 blocks of one, two or eight 15-bit colors,
/// skipped between keyframes where nothing changed.
final class Video1Tests: XCTestCase {

    func block(_ f: (Int) -> SIMD3<Float>) -> [SIMD3<Float>] { (0..<16).map(f) }

    func testFlatBlocksAreOneColorAndTwoToneBlocksAreExact() {
        let flat = block { _ in SIMD3(100, 150, 200) }
        XCTAssertEqual(Video1Codec.codeBlock(flat, reference: nil, limit: 48).mode, .fill)
        // Half black, half white: two colors reproduce it exactly.
        let edge = block { $0 % 4 < 2 ? SIMD3(0, 0, 0) : SIMD3(255, 255, 255) }
        let coded = Video1Codec.codeBlock(edge, reference: nil, limit: 48)
        XCTAssertEqual(coded.mode, .two)
        XCTAssertEqual(coded.pixels, edge)
        // Four different quarters need eight colors.
        let quads = block { i in
            let q = (i / 8) * 2 + (i % 4) / 2
            let base: [SIMD3<Float>] = [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(255, 255, 0)]
            return (i % 2 == 0) ? base[q] : base[q] * 0.3
        }
        XCTAssertEqual(Video1Codec.codeBlock(quads, reference: nil, limit: 48).mode, .eight)
    }

    func testColorsAreFifteenBit() {
        let px = block { i in SIMD3(Float(i * 13 % 256), Float(i * 29 % 256), Float(i * 7 % 256)) }
        for c in Video1Codec.codeBlock(px, reference: nil, limit: 1).pixels {
            for v in [c.x, c.y, c.z] {
                XCTAssertEqual((v * 31 / 255).rounded() * 255 / 31, v, accuracy: 1e-3)
            }
        }
    }

    func testUnchangedBlocksAreSkipped() {
        let px = block { i in SIMD3(Float(i * 9), 80, 160) }
        XCTAssertEqual(Video1Codec.codeBlock(px, reference: px, limit: 4).mode, .skip)
        let moved = block { i in SIMD3(Float((15 - i) * 9), 80, 160) }
        XCTAssertNotEqual(Video1Codec.codeBlock(moved, reference: px, limit: 4).mode, .skip)
    }

    func testTheHiddenControlsDoNothing() {
        var s = DigitalSettings(values: ["codec": 1, "datamosh": 1, "deblocking": 1, "chroma": 3])
        XCTAssertEqual(s.chroma, .full, "Video 1 keeps full color")
        XCTAssertEqual(s.effective("datamosh"), 0)
        XCTAssertEqual(s.effective("deblocking"), 0)
        s.values["codec"] = 0
        XCTAssertEqual(s.effective("datamosh"), 1)
        XCTAssertEqual(s.chroma, .quarterWide)
        XCTAssertFalse(DigitalParam.byID["datamosh"]!.applies(to: .blockColors))
        XCTAssertTrue(DigitalParam.byID["quality"]!.applies(to: .blockColors))
    }

    func testMoreQualityNeverHurts() {
        // Texture at several scales. (On a real frame of Finn's clip the
        // error runs 14.6, 14.0, 13.3 … 4.0, 3.6 per tenth — even along the
        // slider; real Video 1 measured 9.1 there, which the CD-ROM
        // format's 57% matches.)
        let (w, h) = (96, 72)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            func wave(_ fx: Double, _ fy: Double, _ p: Double) -> Double { sin(Double(x) * fx + Double(y) * fy + p) }
            let v = 0.5 * wave(0.05, 0.03, 0) + 0.3 * wave(0.21, -0.17, 1) + 0.2 * wave(0.9, 0.7, 2)
            px[i] = UInt8(128 + 100 * v)
            px[i + 1] = UInt8(128 + 100 * (0.6 * wave(0.04, 0.08, 3) + 0.4 * wave(0.5, 0.3, 4)))
            px[i + 2] = UInt8(128 + 100 * (0.7 * wave(0.07, -0.02, 5) + 0.3 * wave(1.1, 0.4, 6)))
        } }
        let g = CodecGeometry(width: w, height: h, chroma: .full)
        let src = DigitalVideoRenderer.capture(px, geometry: g,
                                               settings: DigitalSettings(values: ["sensor_noise": 0, "noise_reduction": 0, "codec": 1]),
                                               index: 0)
        let errors: [Float] = [0, 0.1, 0.5, 1].map { q in
            let out = Video1Codec.step(CodecState(geometry: g), source: src, kind: .key, index: 0,
                                       settings: .init(quality: q, fixedBitrate: 0, dataLoss: 0))
            var e: Float = 0
            for y in 0..<h { for x in 0..<w { e += abs(out.y.data[y * out.y.width + x] - src.y.data[y * src.y.width + x]) } }
            return e / Float(w * h)
        }
        // Thresholds are absolute, so how far down the slider blocks stay one
        // color depends on the content (this smooth texture stays one color
        // up to the middle). What holds for any picture: more quality never
        // hurts, and the slider spans a wide range.
        XCTAssertTrue(zip(errors, errors.dropFirst()).allSatisfy { $0 >= $1 }, "\(errors)")
        XCTAssertGreaterThan(errors[0], 2 * errors[3], "\(errors)")
    }

    func testLostBlocksStayStaleUntilTheyAreCodedAgain() {
        // Through the renderer, as the app runs it: a moving scene, keyframes
        // every 10 frames, heavy loss. Damage appears, and every keyframe
        // (which arrives whole) clears it.
        let t = DigitalVideoTests()
        var clean = DigitalSettings(values: DigitalFormat.byID["cd_rom"]!.values)
        clean.values["frame_rate"] = 30; clean.values["keyframe_interval"] = 1.0 / 3
        var lossy = clean; lossy.values["data_loss"] = 0.8
        let a = t.played(clean, frames: 21), b = t.played(lossy, frames: 21)
        XCTAssertTrue(a[0] == b[0] && a[10] == b[10] && a[20] == b[20], "keyframes arrive whole")
        XCTAssertTrue((1..<10).contains { a[$0] != b[$0] }, "loss shows between keyframes")
    }
}
