import XCTest
import Metal
import ImageIO
@testable import CrtCore

/// The howlaround camera: its geometry, and the loop driven end to end
/// through the GIF exporter with the CRT shader off (so it runs without the
/// vendored librashader) — what each knob does to the nested copies.
final class HowlaroundTests: XCTestCase {

    private var context: MetalContext!
    private let N = 240

    override func setUpWithError() throws {
        context = try MetalContext()
    }

    private func settings(_ values: [String: Double]) -> HowlaroundSettings {
        // A plain centred camera unless a test says otherwise.
        HowlaroundSettings(values: ["zoom": 0.5, "aim_x": 0, "aim_y": 0, "roll": 0, "turn": 0, "tilt": 0,
                                    "shake": 0, "take": 1, "drift": 0, "drift_dir": 0, "push": 0,
                                    "spin": 0, "loop": 0,
                                    "focus": 0, "brightness": 1, "contrast": 1, "colour_drift": 0,
                                    "hue_drift": 0, "auto_exposure": 0, "mix": 0, "delay": 1,
                                    "counter": 0].merging(values) { _, new in new })
    }

    // MARK: geometry

    func testCentredScreenMapsTheFrameToTheMiddleHalf() throws {
        let s = settings([:])
        let a = try XCTUnwrap(s.cameraPoint(tv: SIMD2(0, 0), aspect: 1))
        let b = try XCTUnwrap(s.cameraPoint(tv: SIMD2(1, 1), aspect: 1))
        XCTAssertEqual(a.x, 0.25, accuracy: 1e-9); XCTAssertEqual(a.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(b.x, 0.75, accuracy: 1e-9); XCTAssertEqual(b.y, 0.75, accuracy: 1e-9)
        let c = try XCTUnwrap(settings(["aim_x": 0.1]).cameraPoint(tv: SIMD2(0.5, 0.5), aspect: 1.5))
        XCTAssertEqual(c.x, 0.6, accuracy: 1e-9)
    }

    func testCopiesFollowTheZoom() {
        // Half size per pass: 240 lines → 120, 60, … 3.75 is the last copy
        // two lines or taller.
        XCTAssertEqual(settings([:]).visibleCopies(aspect: 1, chainHeight: 240), 6)
        XCTAssertEqual(settings(["zoom": 0]).visibleCopies(aspect: 1, chainHeight: 240), 0)
        let z3 = settings(["zoom": 0.3]).visibleCopies(aspect: 1, chainHeight: 240)!
        let z6 = settings(["zoom": 0.6]).visibleCopies(aspect: 1, chainHeight: 240)!
        let z8 = settings(["zoom": 0.8]).visibleCopies(aspect: 1, chainHeight: 240)!
        XCTAssertLessThan(z3, z6); XCTAssertLessThan(z6, z8)
        // Past 100% the copies grow instead of shrinking.
        XCTAssertNil(settings(["zoom": 1.2]).visibleCopies(aspect: 1, chainHeight: 240))
        // Aimed far off-centre the tunnel runs out of the frame sooner.
        let off = settings(["zoom": 0.8, "aim_x": 0.45]).visibleCopies(aspect: 1, chainHeight: 240)!
        XCTAssertLessThan(off, z8)
    }

    func testRunUpCoversTheTunnel() {
        let s = settings([:])
        XCTAssertGreaterThanOrEqual(s.runUpFrames(aspect: 1, chainHeight: 240), 6 + 4)
        XCTAssertEqual(settings(["zoom": 0]).runUpFrames(aspect: 1, chainHeight: 240), 0)
        let slow = settings(["delay": 3]).runUpFrames(aspect: 1, chainHeight: 240)
        XCTAssertGreaterThanOrEqual(slow, 3 * (6 + 4))
    }

    // MARK: movement

    func testAStillCameraHoldsItsFraming() {
        let s = settings(["aim_x": 0.1, "roll": 5])
        for t in [-1.0, 0, 0.7, 3.3] {
            XCTAssertEqual(s.pose(at: t, length: 4), s.basePose)
        }
    }

    func testTheSameTakeMovesTheSameWay() {
        let a = settings(["shake": 0.6, "take": 3]), b = settings(["shake": 0.6, "take": 3])
        let c = settings(["shake": 0.6, "take": 4])
        var moved = false, differs = false
        for t in stride(from: 0.0, to: 4, by: 0.37) {
            let pa = a.pose(at: t, length: 4)
            XCTAssertEqual(pa, b.pose(at: t, length: 4))
            moved = moved || pa != a.basePose
            differs = differs || pa != c.pose(at: t, length: 4)
        }
        XCTAssertTrue(moved, "the hands should move the camera")
        XCTAssertTrue(differs, "another take should move differently")
    }

    func testHandsSwayGentlyAndStayInRange() {
        // At full shake the aim wanders a few percent of the frame and
        // changes smoothly from frame to frame (30 fps).
        let s = settings(["shake": 1, "take": 7])
        var biggest = 0.0, fastest = 0.0
        var last = s.pose(at: 0, length: 10).aimX
        for i in 1...300 {
            let x = s.pose(at: Double(i) / 30, length: 10).aimX
            biggest = max(biggest, abs(x))
            fastest = max(fastest, abs(x - last))
            last = x
        }
        XCTAssertGreaterThan(biggest, 0.02)
        XCTAssertLessThan(biggest, 0.12)
        XCTAssertLessThan(fastest, 0.012)
    }

    func testAMoveRunsFromTheFramingToItsEnd() {
        let s = settings(["drift": 0.3, "drift_dir": 90, "push": 0.2, "spin": 30])
        let start = s.pose(at: 0, length: 5), end = s.pose(at: 5, length: 5)
        XCTAssertEqual(start, s.basePose)
        XCTAssertEqual(end.aimX, 0, accuracy: 1e-9)
        XCTAssertEqual(end.aimY, -0.3, accuracy: 1e-9)      // up
        XCTAssertEqual(end.zoom, 0.5 * 1.2, accuracy: 1e-9)
        XCTAssertEqual(end.roll, 30, accuracy: 1e-9)
        // Eased: slow at the ends, halfway at the middle.
        XCTAssertEqual(s.pose(at: 2.5, length: 5).aimY, -0.15, accuracy: 1e-9)
        XCTAssertLessThan(abs(s.pose(at: 0.25, length: 5).aimY), 0.3 * 0.05)
        // Before the first frame (the run-up) it holds its start.
        XCTAssertEqual(s.pose(at: -0.5, length: 5), s.basePose)
    }

    func testALoopEndsWhereItStarted() {
        let s = settings(["drift": 0.3, "drift_dir": 200, "push": -0.2, "spin": 45,
                          "shake": 0.8, "take": 5, "loop": 1])
        let L = 4.0
        let a = s.pose(at: 0, length: L), b = s.pose(at: L, length: L)
        XCTAssertEqual(a.aimX, b.aimX, accuracy: 1e-9)
        XCTAssertEqual(a.aimY, b.aimY, accuracy: 1e-9)
        XCTAssertEqual(a.zoom, b.zoom, accuracy: 1e-9)
        XCTAssertEqual(a.roll, b.roll, accuracy: 1e-9)
        XCTAssertEqual(a.turn, b.turn, accuracy: 1e-9)
        // Out and back: furthest out in the middle.
        let mid = s.pose(at: L / 2, length: L)
        XCTAssertGreaterThan(abs(mid.roll - a.roll), 30)
        // The run-up wraps round: just before the start is the end of the loop.
        let before = s.pose(at: -0.1, length: L), nearEnd = s.pose(at: L - 0.1, length: L)
        XCTAssertEqual(before.aimX, nearEnd.aimX, accuracy: 1e-9)
    }

    func testKnobsReadInWords() {
        let aim = HowlaroundParam.all.first { $0.id == "aim_x" }!
        XCTAssertEqual(aim.reading(-0.2).side, "left")
        XCTAssertEqual(aim.reading(-0.2).magnitude, 0.2, accuracy: 1e-12)
        XCTAssertEqual(aim.reading(0.15).side, "right")
        XCTAssertEqual(aim.reading(0).side, "centre")
        let up = HowlaroundParam.all.first { $0.id == "aim_y" }!
        XCTAssertEqual(up.reading(-0.1).side, "up")
        XCTAssertEqual(HowlaroundParam.all.first { $0.id == "roll" }!.reading(10).side, "clockwise")
        XCTAssertEqual(HowlaroundParam.compass(0), "right")
        XCTAssertEqual(HowlaroundParam.compass(45), "up-right")
        XCTAssertEqual(HowlaroundParam.compass(90), "up")
        XCTAssertEqual(HowlaroundParam.compass(180), "left")
        XCTAssertEqual(HowlaroundParam.compass(270), "down")
        XCTAssertEqual(HowlaroundParam.compass(350), "right")
        // Up on the knob is up in the picture: a drift "up" raises the TV.
        let s = settings(["drift": 0.2, "drift_dir": 90])
        XCTAssertLessThan(s.pose(at: 1, length: 1).aimY, 0)
    }

    // MARK: the loop, end to end

    private func texture(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: N, height: N,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: N * N * 4)
        for y in 0..<N { for x in 0..<N {
            let (r, g, b) = pixel(x, y)
            let i = (y * N + x) * 4
            bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
        } }
        t.replace(region: MTLRegionMake2D(0, 0, N, N), mipmapLevel: 0, withBytes: bytes, bytesPerRow: N * 4)
        return t
    }

    /// A red frame (the outer tenth) round a blue picture.
    private lazy var framed: MTLTexture = texture { x, y in
        let edge = min(x, y, N - 1 - x, N - 1 - y)
        return edge < N / 10 ? (230, 20, 20) : (20, 20, 230)
    }

    /// A white frame round mid grey.
    private lazy var grey: MTLTexture = texture { x, y in
        let edge = min(x, y, N - 1 - x, N - 1 - y)
        return edge < N / 10 ? (240, 240, 240) : (128, 128, 128)
    }

    private func gif(_ source: MTLTexture, _ howl: HowlaroundSettings?, frames: Int = 3,
                     cancel: HowlaroundCancel? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("howl-\(UUID().uuidString).gif")
        let s = GifExporter.Settings(outputURL: url, width: N, height: N, fps: 12, downscale: nil,
                                     presetPath: "", shaderEnabled: false, glitch: nil,
                                     howlaround: howl.map { HowlaroundRender(settings: $0, length: Double(frames) / 12,
                                                                             cancel: cancel) })
        try await GifExporter(context: context).exportStill(source: source, totalFrames: frames,
                                                            paramValues: [:], settings: s,
                                                            progress: { _ in })
        return url
    }

    /// RGB of the last frame at (fx, fy) in 0…1.
    private func pixel(_ url: URL, _ fx: Double, _ fy: Double) throws -> (Double, Double, Double) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, CGImageSourceGetCount(src) - 1, nil))
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                      bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        let x = Int(fx * Double(img.width)), y = Int(fy * Double(img.height))
        let i = (y * img.width + x) * 4
        return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
    }

    private func isRed(_ c: (Double, Double, Double)) -> Bool { c.0 > 0.6 && c.2 < 0.35 }
    private func isBlue(_ c: (Double, Double, Double)) -> Bool { c.2 > 0.6 && c.0 < 0.35 }

    func testNestedCopiesLandWhereTheCameraPutsThem() async throws {
        let url = try await gif(framed, settings([:]))
        defer { try? FileManager.default.removeItem(at: url) }
        // Down the middle column: the room's frame, the room, the first
        // copy's frame (the screen spans 25–75%, its frame the outer tenth of
        // that), the first copy's picture, the second copy's frame.
        XCTAssertTrue(isRed(try pixel(url, 0.5, 0.04)), "room frame")
        XCTAssertTrue(isBlue(try pixel(url, 0.5, 0.18)), "room")
        XCTAssertTrue(isRed(try pixel(url, 0.5, 0.27)), "first copy's frame")
        XCTAssertTrue(isBlue(try pixel(url, 0.5, 0.33)), "first copy")
        XCTAssertTrue(isRed(try pixel(url, 0.5, 0.385)), "second copy's frame")
    }

    func testZoomZeroIsExactlyTheNormalExport() async throws {
        let plain = try await gif(framed, nil)
        let zero = try await gif(framed, settings(["zoom": 0, "counter": 0]))
        defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: zero) }
        XCTAssertEqual(try Data(contentsOf: plain), try Data(contentsOf: zero))
    }

    func testSameSettingsRenderTheSameFrames() async throws {
        let a = try await gif(framed, settings(["roll": 7, "focus": 0.3, "auto_exposure": 0.5]))
        let b = try await gif(framed, settings(["roll": 7, "focus": 0.3, "auto_exposure": 0.5]))
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }

    func testColourDriftCompoundsWithDepth() async throws {
        let url = try await gif(grey, settings(["colour_drift": -1]))
        defer { try? FileManager.default.removeItem(at: url) }
        // Blue minus red in the room (untouched), the first copy, the second.
        func cool(_ fy: Double) throws -> Double { let c = try pixel(url, 0.5, fy); return c.2 - c.0 }
        let room = try cool(0.18), first = try cool(0.33), second = try cool(0.41)
        XCTAssertEqual(room, 0, accuracy: 0.03)
        XCTAssertGreaterThan(first, room + 0.04)
        XCTAssertGreaterThan(second, first + 0.03)
    }

    func testDimScreenFadesTheDeepCopies() async throws {
        let url = try await gif(grey, settings(["brightness": 0.7]))
        defer { try? FileManager.default.removeItem(at: url) }
        func luma(_ fy: Double) throws -> Double { let c = try pixel(url, 0.5, fy); return (c.0 + c.1 + c.2) / 3 }
        let room = try luma(0.18), first = try luma(0.33), second = try luma(0.41)
        XCTAssertLessThan(first, room - 0.1)
        XCTAssertLessThan(second, first - 0.05)
    }

    func testCancelStopsTheRender() async throws {
        let cancel = HowlaroundCancel()
        cancel.cancel()
        do {
            _ = try await gif(framed, settings([:]), frames: 30, cancel: cancel)
            XCTFail("a cancelled render finished")
        } catch is CancellationError {
        }
    }
}
