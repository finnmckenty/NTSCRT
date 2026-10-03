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
        HowlaroundSettings(values: ["zoom": 0.5, "centre_x": 0, "centre_y": 0, "roll": 0, "turn": 0, "tilt": 0,
                                    "shake": 0, "seed": 1, "drift": 0, "drift_dir": 0, "push": 0,
                                    "spin": 0, "loop": 0,
                                    "focus": 0, "brightness": 1, "contrast": 1, "colour_drift": 0,
                                    "hue_drift": 0, "auto_exposure": 0, "key": 0, "key_invert": 0, "delay": 1,
                                    "counter": 0].merging(values) { _, new in new })
    }

    // MARK: geometry

    func testCentredScreenMapsTheFrameToTheMiddleHalf() throws {
        let s = settings([:])
        let a = try XCTUnwrap(s.cameraPoint(tv: SIMD2(0, 0), aspect: 1))
        let b = try XCTUnwrap(s.cameraPoint(tv: SIMD2(1, 1), aspect: 1))
        XCTAssertEqual(a.x, 0.25, accuracy: 1e-9); XCTAssertEqual(a.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(b.x, 0.75, accuracy: 1e-9); XCTAssertEqual(b.y, 0.75, accuracy: 1e-9)
        // The tunnel's centre is a fixed point: that point of the picture is
        // filmed exactly where it is. At half zoom the screen sits halfway.
        let c = try XCTUnwrap(settings(["centre_x": 0.1]).cameraPoint(tv: SIMD2(0.6, 0.5), aspect: 1.5))
        XCTAssertEqual(c.x, 0.6, accuracy: 1e-9)
        let middle = try XCTUnwrap(settings(["centre_x": 0.1]).cameraPoint(tv: SIMD2(0.5, 0.5), aspect: 1.5))
        XCTAssertEqual(middle.x, 0.55, accuracy: 1e-9)
    }

    func testTheTunnelCentreStaysPutAsTheCameraChanges() throws {
        // Any zoom, angle, frame shape or moment of the movement: the centre
        // maps to itself (GPT Astra's test, kept).
        for aspect in [1.0, 4.0 / 3.0, 16.0 / 9.0] {
            for zoom in [0.5, 0.87, 0.97, 1.0, 1.2] {
                let s = settings(["centre_x": 0.2, "centre_y": -0.15, "zoom": zoom, "turn": -25, "tilt": 15,
                                  "roll": 12, "shake": 0.4, "drift": 0.1, "push": 0.1])
                for t in [-1.0, 0, 1, 3, 5] {
                    let pose = s.pose(at: t, length: 5)
                    let centre = SIMD2(pose.centreX + 0.5, pose.centreY + 0.5)
                    let filmed = try XCTUnwrap(HowlaroundSettings.cameraPoint(tv: centre, pose: pose, aspect: aspect))
                    XCTAssertEqual(filmed.x, centre.x, accuracy: 1e-10)
                    XCTAssertEqual(filmed.y, centre.y, accuracy: 1e-10)
                }
            }
        }
    }

    func testEvenTheKnobsExtremesKeepTheCentreInFront() throws {
        // Big zoom, a corner, steep angles on the same side: the solve alone
        // put the screen behind the camera here.
        for zoom in [1.2, 1.3, 1.4] {
            for (cx, cy) in [(-0.5, -0.5), (-0.5, 0.5), (0.5, -0.5), (0.5, 0.5)] {
                for (turn, tilt, roll) in [(-45.0, -45.0, -45.0), (-45, 45, 45), (45, -45, 45), (45, 45, -45)] {
                    let s = settings(["zoom": zoom, "centre_x": cx, "centre_y": cy,
                                      "turn": turn, "tilt": tilt, "roll": roll])
                    let p = s.basePose
                    let centre = SIMD2(cx + 0.5, cy + 0.5)
                    let filmed = try XCTUnwrap(HowlaroundSettings.cameraPoint(tv: centre, pose: p, aspect: 16.0 / 9))
                    XCTAssertEqual(filmed.x, centre.x, accuracy: 1e-9)
                    XCTAssertEqual(filmed.y, centre.y, accuracy: 1e-9)
                }
            }
        }
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
        // A tunnel converging near the edge still keeps its copies: zooming
        // doesn't push it out of the frame.
        let edge = settings(["zoom": 0.8, "centre_x": 0.45]).visibleCopies(aspect: 1, chainHeight: 240)!
        XCTAssertGreaterThanOrEqual(edge, z8 - 2)
    }

    func testTheDefaultTunnelConvergesOnEveryFrameShape() throws {
        // Every point of the frame shrinks a little on every pass, portrait
        // to widescreen — a steeper side angle smears the near side outward.
        for aspect in [9.0 / 16, 3.0 / 4, 1, 4.0 / 3, 3.0 / 2, 16.0 / 9] {
            let s = HowlaroundSettings(values: ["shake": 0])
            for i in 0...8 { for j in 0...8 {
                let rate = try XCTUnwrap(s.shrink(at: SIMD2(Double(i) / 8, Double(j) / 8), aspect: aspect))
                XCTAssertLessThan(rate, 0.99, "aspect \(aspect) at (\(i), \(j))")
            } }
            let copies = try XCTUnwrap(s.visibleCopies(aspect: aspect, chainHeight: 240))
            XCTAssertGreaterThan(copies, 25, "a deep tunnel, like the reference")
        }
    }

    func testRunUpCoversTheTunnel() {
        // One trip per copy to build the tunnel, then the delay's worth of
        // history — not copies × delay, which at a 20-frame delay would be
        // hundreds of frames before the first one is written.
        let plan = settings([:]).runUpPlan(aspect: 1, chainHeight: 240)
        XCTAssertGreaterThanOrEqual(plan.build, 6 + 4)
        XCTAssertEqual(plan.settle, 1)
        XCTAssertEqual(settings(["zoom": 0]).runUpFrames(aspect: 1, chainHeight: 240), 0)
        let slow = settings(["delay": 20]).runUpPlan(aspect: 1, chainHeight: 240)
        XCTAssertEqual(slow.build, plan.build)
        XCTAssertEqual(slow.settle, 20)
        // A seamless loop settles longer, so the first copies carry the lag
        // they'll have at the end.
        let loop = settings(["delay": 20, "loop": 1]).runUpPlan(aspect: 1, chainHeight: 240)
        XCTAssertGreaterThan(loop.settle, 20 * 6)
    }

    // MARK: movement

    func testAStillCameraHoldsItsFraming() {
        let s = settings(["centre_x": 0.1, "roll": 5])
        for t in [-1.0, 0, 0.7, 3.3] {
            XCTAssertEqual(s.pose(at: t, length: 4), s.basePose)
        }
    }

    func testTheSameTakeMovesTheSameWay() {
        let a = settings(["shake": 0.6, "seed": 3]), b = settings(["shake": 0.6, "seed": 3])
        let c = settings(["shake": 0.6, "seed": 4])
        var moved = false, differs = false
        for t in stride(from: 0.0, to: 4, by: 0.37) {
            let pa = a.pose(at: t, length: 4)
            XCTAssertEqual(pa, b.pose(at: t, length: 4))
            moved = moved || pa != a.basePose
            differs = differs || pa != c.pose(at: t, length: 4)
        }
        XCTAssertTrue(moved, "the hands should move the camera")
        XCTAssertTrue(differs, "another seed should move differently")
    }

    func testHandsSwayGentlyAndStayInRange() {
        // At full shake the tunnel centre wanders a few percent of the frame and
        // changes smoothly from frame to frame (30 fps).
        let s = settings(["shake": 1, "seed": 7])
        var biggest = 0.0, fastest = 0.0
        var last = s.pose(at: 0, length: 10).centreX
        for i in 1...300 {
            let x = s.pose(at: Double(i) / 30, length: 10).centreX
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
        XCTAssertEqual(end.centreX, 0, accuracy: 1e-9)
        XCTAssertEqual(end.centreY, -0.3, accuracy: 1e-9)      // up
        XCTAssertEqual(end.zoom, 0.5 * 1.2, accuracy: 1e-9)
        XCTAssertEqual(end.roll, 30, accuracy: 1e-9)
        // Eased: slow at the ends, halfway at the middle.
        XCTAssertEqual(s.pose(at: 2.5, length: 5).centreY, -0.15, accuracy: 1e-9)
        XCTAssertLessThan(abs(s.pose(at: 0.25, length: 5).centreY), 0.3 * 0.05)
        // Before the first frame (the run-up) it holds its start.
        XCTAssertEqual(s.pose(at: -0.5, length: 5), s.basePose)
    }

    func testALoopEndsWhereItStarted() {
        let s = settings(["drift": 0.3, "drift_dir": 200, "push": -0.2, "spin": 45,
                          "shake": 0.8, "seed": 5, "loop": 1])
        let L = 4.0
        let a = s.pose(at: 0, length: L), b = s.pose(at: L, length: L)
        XCTAssertEqual(a.centreX, b.centreX, accuracy: 1e-9)
        XCTAssertEqual(a.centreY, b.centreY, accuracy: 1e-9)
        XCTAssertEqual(a.zoom, b.zoom, accuracy: 1e-9)
        XCTAssertEqual(a.roll, b.roll, accuracy: 1e-9)
        XCTAssertEqual(a.turn, b.turn, accuracy: 1e-9)
        // Out and back: furthest out in the middle.
        let mid = s.pose(at: L / 2, length: L)
        XCTAssertGreaterThan(abs(mid.roll - a.roll), 30)
        // The run-up wraps round: just before the start is the end of the loop.
        let before = s.pose(at: -0.1, length: L), nearEnd = s.pose(at: L - 0.1, length: L)
        XCTAssertEqual(before.centreX, nearEnd.centreX, accuracy: 1e-9)
    }

    func testKnobsReadInWords() {
        let across = HowlaroundParam.all.first { $0.id == "centre_x" }!
        XCTAssertEqual(across.reading(-0.2).side, "left")
        XCTAssertEqual(across.reading(-0.2).magnitude, 0.2, accuracy: 1e-12)
        XCTAssertEqual(across.reading(0.15).side, "right")
        XCTAssertEqual(across.reading(0).side, "middle")
        let up = HowlaroundParam.all.first { $0.id == "centre_y" }!
        XCTAssertEqual(up.reading(-0.1).side, "up")
        XCTAssertEqual(HowlaroundParam.all.first { $0.id == "roll" }!.reading(10).side, "clockwise")
        XCTAssertEqual(HowlaroundParam.compass(0), "right")
        XCTAssertEqual(HowlaroundParam.compass(45), "up-right")
        XCTAssertEqual(HowlaroundParam.compass(90), "up")
        XCTAssertEqual(HowlaroundParam.compass(180), "left")
        XCTAssertEqual(HowlaroundParam.compass(270), "down")
        XCTAssertEqual(HowlaroundParam.compass(350), "right")
        // Up on the knob is up in the picture: a drift "up" raises the tunnel.
        let s = settings(["drift": 0.2, "drift_dir": 90])
        XCTAssertLessThan(s.pose(at: 1, length: 1).centreY, 0)
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

    func testALongDelayStillOpensOnTheWholeTunnel() async throws {
        // 20 frames per trip round the loop, three frames rendered: the
        // copies are there from the first frame.
        let url = try await gif(framed, settings(["delay": 20]))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(isRed(try pixel(url, 0.5, 0.27)), "first copy's frame")
        XCTAssertTrue(isRed(try pixel(url, 0.5, 0.385)), "second copy's frame")
    }

    /// Bright in the middle, dark around it.
    private lazy var spot: MTLTexture = texture { x, y in
        let dx = Double(x - N / 2), dy = Double(y - N / 2)
        return (dx * dx + dy * dy).squareRoot() < Double(N) * 0.12 ? (250, 250, 250) : (30, 30, 30)
    }

    func testTheLumaKeyPutsTheBrightPartsOnTop() async throws {
        // The room is dark with a bright spot in the middle; the TV — dim,
        // so the copies stand apart — covers the middle half. Keyed, the
        // spot sits on top of the copies; the dark parts show the feedback.
        let off = try await gif(spot, settings(["brightness": 0.6]))
        let keyed = try await gif(spot, settings(["brightness": 0.6, "key": 0.5]))
        let inverted = try await gif(spot, settings(["brightness": 0.6, "key": 0.5, "key_invert": 1]))
        defer { for u in [off, keyed, inverted] { try? FileManager.default.removeItem(at: u) } }
        func luma(_ u: URL, _ fx: Double, _ fy: Double) throws -> Double {
            let c = try pixel(u, fx, fy); return (c.0 + c.1 + c.2) / 3
        }
        // In the TV, unkeyed, the middle is a dimmed copy of the room.
        XCTAssertLessThan(try luma(off, 0.5, 0.5), 0.75)
        // Keyed: the bright spot is on top, full brightness.
        XCTAssertGreaterThan(try luma(keyed, 0.5, 0.5), 0.9)
        // Inverted: the dark room is keyed instead, so the spot's place
        // shows the feedback (dim), and the dark parts are your picture.
        XCTAssertLessThan(try luma(inverted, 0.5, 0.5), 0.75)
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
