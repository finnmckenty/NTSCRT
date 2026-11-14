import XCTest
import Metal
@testable import CrtCore

/// The VCR: tape geometry, the tape's surface, the heads, and the recording
/// and playback chain on the GPU — checked against the physics they model.
final class VcrTests: XCTestCase {

    // MARK: - geometry

    func testHeightAcrossTheTapeIsHeightInThePicture() {
        // A point at a fixed height is read on the same line in every field
        // whose track crosses it: a lengthwise scratch is a streak at a fixed
        // height.
        let L = 262
        func lineReading(y: Double, field: Int64) -> Double {
            let along = (y - TapeGeometry.trackStart) / sin(TapeGeometry.angle)
            return along / TapeGeometry.trackLength * Double(L)
        }
        XCTAssertEqual(lineReading(y: 6, field: 10), lineReading(y: 6, field: 400), accuracy: 1e-9)
        // And neighboring tracks sit one track pitch (58 µm) apart.
        XCTAssertEqual(TapeGeometry.trackPitch * 1000, 57.9, accuracy: 0.5)
        // A field's track spans the video area: about 10 mm of the 12.65.
        let top = TapeGeometry.point(field: 0, along: TapeGeometry.trackLength).y
        XCTAssertEqual(Double(top) - TapeGeometry.trackStart, 10.1, accuracy: 0.1)
    }

    func testACreaseSweepsUpThePicture() {
        // The heads cross a fold across the tape a little earlier along the
        // track each field: it climbs ~1.5 NTSC lines a field.
        let t = TapeParams(GlitchSettings(values: ["tape_creases": 1, "tape_seed": 3]))
        var seen: [(Int64, Double)] = []
        for f in Int64(0)..<400 {
            if let fold = TapeSurface.folds(field: f, t).first { seen.append((f, fold.along)) }
        }
        XCTAssertGreaterThan(seen.count, 20, "creases are crossed")
        // Consecutive fields crossing the same crease: its place moves back.
        var steps: [Double] = []
        for i in 1..<seen.count where seen[i].0 == seen[i - 1].0 + 1 {
            let d = seen[i].1 - seen[i - 1].1
            if abs(d) < 5 { steps.append(d) }
        }
        XCTAssertFalse(steps.isEmpty)
        let lineMM = TapeGeometry.lineLength
        for d in steps { XCTAssertLessThan(d, 0); XCTAssertLessThan(abs(d) / lineMM, 3) }
    }

    // MARK: - the tape

    func testANewTapeIsCleanAndAWornOneIsNot() {
        func survey(_ v: [String: Double]) -> (low: Int, meanOut: Float) {
            let t = TapeParams(GlitchSettings(values: v))
            var low = 0, sum: Float = 0
            let n = 4000
            for i in 0..<n {
                let p = TapeSurface.at(TapeGeometry.point(field: Int64(i / 40),
                                                          along: Double(i % 40) * 2.4), t)
                if p.output < 0.3 { low += 1 }
                sum += p.output
            }
            return (low, sum / Float(n))
        }
        let new = survey([:]), worn = survey(["tape_wear": 1, "tape_dropouts": 1])
        XCTAssertEqual(new.meanOut, 1, accuracy: 0.03)
        XCTAssertEqual(new.low, 0)
        XCTAssertLessThan(worn.meanOut, 0.5, "wear loses up to 7 dB")
        XCTAssertGreaterThan(worn.low, 5, "and flaws appear")
    }

    func testMoldGrowsTowardTheEdges() {
        let t = TapeParams(GlitchSettings(values: ["tape_mold": 0.8]))
        var edge: Float = 0, middle: Float = 0
        for i in 0..<3000 {
            let x = Double(i) * 0.37
            edge += TapeSurface.at(TapePosition(x: x, y: 1.0), t, detail: false).lift
            edge += TapeSurface.at(TapePosition(x: x, y: 11.6), t, detail: false).lift
            middle += 2 * TapeSurface.at(TapePosition(x: x, y: 6.3), t, detail: false).lift
        }
        XCTAssertGreaterThan(edge, middle * 1.3)
    }

    func testTheShaderReadsTheSameTape() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let stage = try VcrStage(device: device)
        let t = TapeParams(GlitchSettings(values: ["tape_wear": 0.6, "tape_dropouts": 0.8, "tape_scratches": 0.8,
                                                   "tape_creases": 0.8, "tape_edge_damage": 0.8,
                                                   "tape_mold": 0.8, "tape_vaseline": 0.8, "tape_seed": 5]))
        var pts: [TapePosition] = []
        for i in 0..<2000 {
            pts.append(TapeGeometry.point(field: Int64(i % 97) * 13 + 2000,
                                          along: Double(i) * 0.0483, across: (Double(i % 3) - 1) * 0.0145))
        }
        let gpu = try stage.probeTape(pts, t)
        var worst: Float = 0
        for (p, g) in zip(pts, gpu) {
            let c = TapeSurface.at(p, t)
            worst = max(worst, abs(c.lift - g.lift), abs(c.film - g.film), abs(c.output - g.output))
        }
        XCTAssertLessThan(worst, 0.02, "CPU and GPU tape maps agree")
    }

    // MARK: - the heads

    func testASheddingTapeClogsAnUncleanedDeck() {
        func debris(_ v: [String: Double]) -> Float {
            let d = DeckSimulator(settings: GlitchSettings(values: v))
            d.reset(atField: 0)
            var most: Float = 0
            for f in Int64(1)...1800 {
                d.advance(toField: f)
                most = max(most, d.heads(forField: f).map(\.debris).max()!)
            }
            return most
        }
        let cleanDeck = debris(["tape_mold": 0.8, "dirt_buildup": 0])
        let dirtyDeck = debris(["tape_mold": 0.8, "dirt_buildup": 1])
        let goodTape = debris(["dirt_buildup": 1])
        XCTAssertLessThan(cleanDeck, 0.15, "a clean deck stays clean")
        XCTAssertGreaterThan(dirtyDeck, 0.5, "a moldy tape clogs a dirty deck")
        XCTAssertLessThan(goodTape, dirtyDeck / 3, "a good tape doesn't shed much")
    }

    func testVaselineRubsOffOntoTheHeads() {
        let d = DeckSimulator(settings: GlitchSettings(values: ["tape_vaseline": 1]))
        d.reset(atField: 0)
        var grease: Float = 0
        for f in Int64(1)...1200 { d.advance(toField: f); grease = max(grease, d.heads(forField: f)[0].grease) }
        XCTAssertGreaterThan(grease, 0.2)
    }

    // MARK: - migration

    func testOldTapeKnobsBecomeTheirCauses() {
        let m = GlitchSettings.migrated(["head_clog": 0.5, "crinkle": 0.4, "dropouts": 0.3, "dropout_compensation": 0])
        XCTAssertEqual(m["vcr"], 1)
        XCTAssertEqual(m["head_dirt"]!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(m["tape_creases"], 0.4)
        XCTAssertEqual(m["tape_dropouts"], 0.3)
        XCTAssertNil(m["head_clog"])
        XCTAssertEqual(m["dropout_compensation"], 0)
        XCTAssertEqual(GlitchSettings.migrated(["vertical_hold": 0.3])["vcr"], 0, "no tape, no VCR")
        XCTAssertEqual(GlitchSettings.migrated(["tracking": 0.5])["vcr"], 1)
        let current: [String: Double] = ["vcr": 0, "tape_mold": 1]
        XCTAssertEqual(GlitchSettings.migrated(current), current, "already current")
    }
}

/// The recording and playback chain, on the GPU.
final class VcrPlaybackTests: XCTestCase {
    private var context: MetalContext!
    private let W = 320, A = 240

    override func setUpWithError() throws { context = try MetalContext() }

    private var readable: MTLStorageMode { context.device.hasUnifiedMemory ? .shared : .managed }

    private func texture(_ pixel: (Int, Int) -> (Float, Float, Float)) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: A, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = readable
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: W * A * 4)
        for y in 0..<A { for x in 0..<W {
            let (r, g, b) = pixel(x, y)
            let i = (y * W + x) * 4
            bytes[i] = UInt8(b * 255); bytes[i + 1] = UInt8(g * 255); bytes[i + 2] = UInt8(r * 255)
        } }
        t.replace(region: MTLRegionMake2D(0, 0, W, A), mipmapLevel: 0, withBytes: bytes, bytesPerRow: W * 4)
        return t
    }

    private func render(_ input: MTLTexture, time: Double = 1.0, _ values: [String: Double]) throws -> [UInt8] {
        let renderer = try GlitchRenderer(context: context)
        let cb = context.queue.makeCommandBuffer()!
        let out = try renderer.encode(into: cb, chainInput: input, time: time,
                                      settings: GlitchSettings(values: values))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: A, mipmapped: false)
        d.storageMode = readable
        let staging = context.device.makeTexture(descriptor: d)!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: out, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: W * A * 4)
        staging.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, A), mipmapLevel: 0)
        return px
    }

    private func yiq(_ px: [UInt8], _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * W + x) * 4
        let b = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, r = Double(px[i + 2]) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b,
                0.596 * r - 0.274 * g - 0.322 * b,
                0.211 * r - 0.523 * g + 0.312 * b)
    }

    /// Luma noise (std over a flat patch's middle), mean luma and mean
    /// chroma magnitude.
    private func patch(_ px: [UInt8]) -> (noise: Double, luma: Double, chroma: Double) {
        var ys: [Double] = [], cs: [Double] = []
        for y in 60..<180 { for x in 60..<260 {
            let c = yiq(px, x, y); ys.append(c.0); cs.append((c.1 * c.1 + c.2 * c.2).squareRoot())
        } }
        let m = ys.reduce(0, +) / Double(ys.count)
        let sd = (ys.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(ys.count)).squareRoot()
        return (sd, m, cs.reduce(0, +) / Double(cs.count))
    }

    func testANewTapeInACleanDeckPlaysCleanly() throws {
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let src = patch(try render(input, ["vcr": 0]))
        let out = patch(try render(input, ["vcr": 1]))
        XCTAssertEqual(out.luma, src.luma, accuracy: 0.03, "levels survive FM recording")
        XCTAssertEqual(out.chroma, src.chroma, accuracy: 0.04, "color-under and ACC keep saturation")
        XCTAssertLessThan(out.noise, 0.02, "about 45 dB: barely visible noise")
    }

    func testSpacingCostsThePictureFarMoreThanTheColor() throws {
        // The heads held off the tape (dirt): the FM carrier's ~1.5 µm
        // wavelength loses ~38 dB per µm, the 9 µm color-under ~6 — so the
        // picture breaks into noise while the color survives.
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let clean = patch(try render(input, ["vcr": 1]))
        let held = patch(try render(input, ["vcr": 1, "head_dirt": 1, "head_mismatch": 0]))
        XCTAssertGreaterThan(held.noise, 0.06, "luma at the FM threshold")
        XCTAssertGreaterThan(held.chroma, clean.chroma * 0.6, "color still there")
    }

    func testFieldsPlayedByTheDirtierHeadAreNoisier() throws {
        let input = texture { _, _ in (0.5, 0.5, 0.5) }
        var noise: [Double] = []
        for i in 0..<4 {
            noise.append(patch(try render(input, time: 1 + Double(i) / 59.94,
                                          ["vcr": 1, "head_dirt": 0.75, "head_mismatch": 0.8])).noise)
        }
        let hi = noise.max()!, lo = noise.min()!
        XCTAssertGreaterThan(hi, lo * 1.5, "alternate fields differ: \(noise)")
    }
}
