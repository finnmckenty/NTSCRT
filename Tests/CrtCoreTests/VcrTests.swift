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

    /// Clogs (a chunk lodging: debris up by more than 0.1 µm in a field)
    /// over ten minutes of play.
    private func clogs(_ v: [String: Double]) -> Int {
        let d = DeckSimulator(settings: GlitchSettings(values: v))
        d.reset(atField: 0)
        var n = 0, last: [Float] = [0, 0]
        for f in Int64(1)...36000 {
            d.advance(toField: f)
            let now = d.heads(forField: f + 1).map(\.debris)
            for h in 0..<2 where now[h] - last[h] > 0.1 { n += 1 }
            last = now
        }
        return n
    }

    func testAnUncleanedDeckClogsNowAndThenOnAnyTape() {
        // Every tape sheds a trace, so Dirt buildup does something whatever
        // the tape: a clog every half minute or so on a new one in a deck
        // never cleaned, about never in one just cleaned.
        let never = clogs(["dirt_buildup": 1]), half = clogs(["dirt_buildup": 0.5]), cleaned = clogs(["dirt_buildup": 0])
        XCTAssertGreaterThan(never, 12, "every 50 s or oftener")
        XCTAssertLessThan(never, 50, "every 12 s or rarer")
        XCTAssertLessThanOrEqual(cleaned, 2)
        // The knob rises evenly: half way, about a third of full.
        XCTAssertGreaterThan(Double(half), Double(never) * 0.2, "\(half) of \(never)")
        XCTAssertLessThan(Double(half), Double(never) * 0.6)
        let deck = { (b: Double) in DeckParams(GlitchSettings(values: ["dirt_buildup": b])).pickup(0) }
        XCTAssertEqual(deck(0.5) / deck(1), 0.36, accuracy: 0.03)
        // A shedding tape still clogs it far more.
        XCTAssertGreaterThan(clogs(["dirt_buildup": 1, "tape_mold": 0.6]), never * 3)
    }

    func testWornHeadsClogMoreEasily() {
        let new = DeckParams(GlitchSettings(values: ["dirt_buildup": 0.5]))
        let worn = DeckParams(GlitchSettings(values: ["dirt_buildup": 0.5, "head_wear": 1]))
        XCTAssertEqual(worn.pickup(0), 2 * new.pickup(0), accuracy: 1e-4)
        XCTAssertGreaterThan(Double(clogs(["dirt_buildup": 1, "head_wear": 1])),
                             Double(clogs(["dirt_buildup": 1])) * 1.4)
    }

    func testBakedOnDirtShiftsOnEachHeadByItself() {
        let deck = DeckParams(GlitchSettings(values: ["head_dirt": 1]))
        var sum: [Float] = [0, 0], lo = Float.infinity, hi = -Float.infinity, apart: Float = 0, step: Float = 0
        let n = 6000
        for f in 0..<n {
            let a = DeckParams.dirtShift(0, field: Int64(f), seed: 3), b = DeckParams.dirtShift(1, field: Int64(f), seed: 3)
            sum[0] += a; sum[1] += b; lo = min(lo, a, b); hi = max(hi, a, b)
            apart = max(apart, abs(a - b))
            step = max(step, abs(a - DeckParams.dirtShift(0, field: Int64(f + 1), seed: 3)))
        }
        XCTAssertEqual(sum[0] / Float(n), 1, accuracy: 0.05)
        XCTAssertEqual(sum[1] / Float(n), 1, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(lo, 0.79); XCTAssertLessThanOrEqual(hi, 1.21)
        XCTAssertGreaterThan(apart, 0.15, "the heads drift apart")
        XCTAssertLessThan(step, 0.02, "slowly")
        // It is the same dirt, moved: the layer's own size times the shift.
        XCTAssertEqual(deck.baselineDirt(0, seed: 3, field: 40),
                       deck.baselineDirt(0, seed: 3) * DeckParams.dirtShift(0, field: 40, seed: 3), accuracy: 1e-6)
        XCTAssertEqual(DeckParams(GlitchSettings(values: [:])).baselineDirt(0, seed: 3, field: 40), 0)
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
        XCTAssertEqual(m["tape_dropouts"]!, TapeParams.knobIn028("tape_dropouts", forAmount: 0.3), accuracy: 1e-9,
                       "where Oxide flaws' slider stood for it in 0.28")
        XCTAssertNil(m["head_clog"])
        XCTAssertEqual(m["dropout_compensation"], 0)
        XCTAssertEqual(GlitchSettings.migrated(["vertical_hold": 0.3])["vcr"], 0, "no tape, no VCR")
        XCTAssertEqual(GlitchSettings.migrated(["tracking": 0.5])["vcr"], 1)
        let current: [String: Double] = ["vcr": 0, "tape_mold": 1]
        XCTAssertEqual(GlitchSettings.migrated(current), current, "already current")
        // 0.24's Tracking (an amount of error) and Time-base jitter (µs).
        let v24 = GlitchSettings.migrated(["vcr": 1, "tracking": 0.5, "timebase_jitter": 1])
        XCTAssertNil(v24["tracking"]); XCTAssertNil(v24["timebase_jitter"])
        XCTAssertEqual(v24["tracking_offset"]!, 0.65, accuracy: 1e-9)
        XCTAssertEqual(v24["transport_flutter"]!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(GlitchSettings.migrated(["vcr": 1, "tracking": 0])["tracking_offset"], 0)
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

    func testEPIsNoisierButTheCombFilterKeepsItsColor() throws {
        // EP's 19 µm tracks give a third of SP's signal (its narrow heads
        // make most of it back: a little noisier, not a lot), and its 26 µm
        // heads overlap both neighbors, whose color (the other azimuth,
        // turned the other way) only the comb filter cancels.
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let src = patch(try render(input, ["vcr": 0]))
        let sp = patch(try render(input, ["vcr": 1]))
        let ep = patch(try render(input, ["vcr": 1, "tape_speed": 2]))
        XCTAssertGreaterThan(ep.noise, sp.noise * 1.08, "EP is noisier")
        XCTAssertLessThan(ep.noise, sp.noise * 1.6, "but not much")
        XCTAssertEqual(ep.chroma, src.chroma, accuracy: 0.05, "the neighbors' color cancels")
        XCTAssertEqual(ep.luma, src.luma, accuracy: 0.03)
    }

    /// The color of a flat patch: its strength (the mean color, which noise
    /// averages out of) and its noise (how far pixels stray from it).
    private func color(_ px: [UInt8]) -> (level: Double, noise: Double) {
        var cs: [(Double, Double)] = []
        for y in 60..<180 { for x in 60..<260 { let c = yiq(px, x, y); cs.append((c.1, c.2)) } }
        let n = Double(cs.count)
        let mi = cs.reduce(0) { $0 + $1.0 } / n, mq = cs.reduce(0) { $0 + $1.1 } / n
        let v = cs.reduce(0) { $0 + ($1.0 - mi) * ($1.0 - mi) + ($1.1 - mq) * ($1.1 - mq) } / n
        return ((mi * mi + mq * mq).squareRoot(), v.squareRoot())
    }

    func testWearWearsThePictureButNotTheColor() throws {
        // Worn tape and heads lose up to 20 dB, which on EP used to sink the
        // color-under below the color killer. People turn wear up for a
        // worn picture, not a black-and-white one.
        // (At the realistic worst; full Wear goes on to wreck the picture.)
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let new = try render(input, ["vcr": 1, "tape_speed": 2])
        let worn = try render(input, ["vcr": 1, "tape_speed": 2, "tape_wear": asBefore("tape_wear", 1),
                                      "head_wear": 0.5])
        XCTAssertGreaterThan(patch(worn).noise, patch(new).noise * 1.5, "the picture is worn")
        // (Not faded. Where a worn head's contact sinks the picture below
        // the FM threshold for a moment, the TV's own color control reads a
        // noisy burst and turns the color up a little, as it does behind
        // any band of noise.)
        XCTAssertGreaterThan(color(worn).level, color(new).level - 0.03, "the color isn't")
        XCTAssertLessThan(color(worn).level, color(new).level + 0.05)
    }

    func testAWornHeadMakesTheColorNoisy() throws {
        // The deck holds the color's strength up (ACC); the head's noise
        // comes up with what the head lost. What the tape lost is made up
        // against the same noise, as before.
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let new = color(try render(input, ["vcr": 1]))
        let head = color(try render(input, ["vcr": 1, "head_wear": 1]))
        XCTAssertGreaterThan(head.noise, new.noise * 1.6, "a worn head's color is noisier: \(new.noise) → \(head.noise)")
        XCTAssertEqual(head.level, new.level, accuracy: 0.04, "and as strong")
        let fresh = DeckParams(GlitchSettings(values: [:]))
        let worn = DeckParams(GlitchSettings(values: ["head_wear": 1]))
        let wornTape = TapeParams(GlitchSettings(values: ["tape_wear": 0.5]))
        XCTAssertEqual(fresh.colorNoise(0), 1)
        XCTAssertGreaterThan(fresh.colorBoost(0, tape: wornTape), 1.5, "a worn tape's color is raised")
        XCTAssertEqual(fresh.colorNoise(0), 1, "but not the noise with it")
        XCTAssertGreaterThan(worn.colorNoise(0), 1.8)
        XCTAssertLessThan(worn.colorNoise(0), 3)
        XCTAssertEqual(worn.colorBoost(0, tape: TapeParams(GlitchSettings(values: [:]))), worn.colorNoise(0),
                       accuracy: 1e-4, "a worn head's noise rises by all it lost")
    }

    func testAWornHeadsNoiseComesAndGoes() throws {
        // A worn tip rides on what the tape is doing, so its noise drifts
        // through the picture and over time — not the same sheet of grain on
        // every frame. A clean deck's noise is the same on every frame.
        let input = texture { _, _ in (0.5, 0.5, 0.5) }
        func noise(_ wear: Double) throws -> [Double] {
            try (0..<8).map { patch(try render(input, time: 1 + Double($0) * 0.3,
                                               ["vcr": 1, "head_wear": wear])).noise }
        }
        let clean = try noise(0), worn = try noise(0.85)
        XCTAssertLessThan(clean.max()!, clean.min()! * 1.15, "steady: \(clean)")
        XCTAssertGreaterThan(worn.max()!, worn.min()! * 1.5, "comes and goes: \(worn)")
        XCTAssertGreaterThan(worn.min()!, clean.max()!, "but never clean")
        // And any moment plays the same again.
        XCTAssertEqual(try render(input, time: 2.2, ["vcr": 1, "head_wear": 0.85]),
                       try render(input, time: 2.2, ["vcr": 1, "head_wear": 0.85]))
    }

    func testAWornTipsContactAveragesOutAndIsWorstAtTheEnds() {
        let L = TapeGeometry.trackLength
        var sum = 0.0, lo = Float.infinity, hi = -Float.infinity, n = 0.0
        var top = 0.0, middle = 0.0
        for f in stride(from: Int64(0), to: 3000, by: 7) {
            for i in 0..<20 {
                let c = DeckParams.contact(field: f, along: (Double(i) + 0.5) / 20 * L, seed: 5)
                sum += Double(c); n += 1; lo = min(lo, c); hi = max(hi, c)
                if i == 0 { top += Double(c) }
                if i == 10 { middle += Double(c) }
            }
        }
        XCTAssertEqual(sum / n, 1.05, accuracy: 0.1, "about its average")
        XCTAssertGreaterThanOrEqual(lo, 0.15)
        XCTAssertLessThan(hi, 2.6)
        XCTAssertGreaterThan(top, middle * 1.15, "it meets the tape late")
        // Smooth in time: a field later it has barely moved.
        let a = DeckParams.contact(field: 100, along: L / 2, seed: 5)
        let b = DeckParams.contact(field: 101, along: L / 2, seed: 5)
        XCTAssertEqual(a, b, accuracy: 0.25)
        // No wear, no spacing, whatever the moment.
        XCTAssertEqual(DeckParams(GlitchSettings(values: [:])).wearSpacing(0, field: 9, along: 3, seed: 5), 0)
    }

    func testTheDecksNoiseCancellerTakesFineGrainAndTheFaintestDetail() throws {
        // Fine vertical stripes, faint and strong: the canceller takes the
        // faint ones for noise; the strong ones keep nearly all they had.
        func stripes(_ depth: Float) throws -> Double {
            let input = texture { x, _ in let v = 0.5 + ((x / 2) % 2 == 0 ? depth : -depth); return (v, v, v) }
            let px = try render(input, ["vcr": 1])
            var even = 0.0, odd = 0.0, n = 0.0
            for y in 100..<140 { for x in stride(from: 80, to: 240, by: 4) {
                even += yiq(px, x, y).0 + yiq(px, x + 1, y).0
                odd += yiq(px, x + 2, y).0 + yiq(px, x + 3, y).0; n += 2
            } }
            return abs(even - odd) / n / Double(2 * depth)
        }
        let faint = try stripes(0.012), strong = try stripes(0.2)
        XCTAssertLessThan(faint, strong * 0.6, "faint detail fades: \(faint) against \(strong)")
        XCTAssertGreaterThan(strong, 0.3, "strong detail stays")
        // A new tape's grain is all but gone from a flat picture.
        let flat = texture { _, _ in (0.5, 0.5, 0.5) }
        XCTAssertLessThan(patch(try render(flat, ["vcr": 1])).noise, 0.006, "48 dB or better")
    }

    func testTheLumaFilterIsSteep() {
        // Both sections, both ways: 3 dB down at 2.4 MHz, 20 at the color
        // subcarrier.
        func gain(_ mhz: Double) -> Double {
            let w = 2 * Double.pi * mhz / VcrChannel.sampleRate
            var g = 1.0
            for q in [VcrChannel.lumaQ.0, VcrChannel.lumaQ.1] {
                let c = VcrChannel.lowPass(VcrChannel.lumaMHz, q: q).map(Double.init)
                let nr = c[0] + c[1] * cos(w) + c[2] * cos(2 * w), ni = -c[1] * sin(w) - c[2] * sin(2 * w)
                let dr = 1 + c[3] * cos(w) + c[4] * cos(2 * w), di = -c[3] * sin(w) - c[4] * sin(2 * w)
                g *= (nr * nr + ni * ni) / (dr * dr + di * di)      // one way squared: both ways
            }
            return 20 * log10(g)      // g: both ways, so an amplitude gain
        }
        XCTAssertEqual(gain(0.5), 0, accuracy: 0.05)
        XCTAssertEqual(gain(2.4), -3, accuracy: 0.5)
        XCTAssertLessThan(gain(NTSCTiming.subcarrierMHz), -20)
    }

    /// Where a damaged tape's picture differs from the same tape undamaged:
    /// for each row, the share of it that is damaged.
    private func damage(_ values: [String: Double], time: Double = 1.0) throws -> [Double] {
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let clean = try render(input, time: time, ["vcr": 1])
        let px = try render(input, time: time, values.merging(["vcr": 1]) { a, _ in a })
        return (0..<A).map { y in
            var n = 0
            for x in 20..<(W - 20) {
                let i = (y * W + x) * 4
                let d = abs(Int(px[i]) - Int(clean[i])) + abs(Int(px[i + 1]) - Int(clean[i + 1])) + abs(Int(px[i + 2]) - Int(clean[i + 2]))
                if d > 60 { n += 1 }
            }
            return Double(n) / Double(W - 40)
        }
    }

    /// Runs of consecutive rows with damage: their heights.
    private func bands(_ rows: [Double], over share: Double = 0.02) -> [Int] {
        var out: [Int] = [], run = 0
        for r in rows + [0] {
            if r > share { run += 1 } else if run > 0 { out.append(run); run = 0 }
        }
        return out
    }

    func testEachKindOfTapeDamageKeepsItsOwnShape() throws {
        // At the top of their knobs Oxide flaws, Scratches and Mold had all
        // become bands of noise with torn picture between (0.27–0.28).
        // Flaws are dropouts: dashes, a line tall and mostly a fraction of
        // the picture wide, all over it. Scratches are lines right across,
        // a line or three tall, at the same heights from field to field.
        // Mold is patches: bands many lines tall.
        let flaws = try damage(["tape_dropouts": 1])
        let scratches = try damage(["tape_scratches": 1])
        let mold = try damage(["tape_mold": 1])
        func hit(_ rows: [Double]) -> [Double] { rows.filter { $0 > 0.02 } }
        func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
        // Flaws: many rows touched, each over a small share of its width;
        // hardly any row gone right across. (Measured 121 rows, median
        // 18% of the width, 7 rows over 80%.)
        XCTAssertGreaterThan(hit(flaws).count, 60)
        XCTAssertLessThan(median(hit(flaws)), 0.35, "dashes, not lines")
        XCTAssertLessThan(flaws.filter { $0 > 0.8 }.count, 20)
        // Scratches: right across, never taller than a few lines.
        // (Measured 52 rows, median 71%, tallest 4.)
        XCTAssertGreaterThan(hit(scratches).count, 25)
        XCTAssertGreaterThan(median(hit(scratches)), 0.5, "lines right across")
        XCTAssertLessThanOrEqual(bands(scratches).max() ?? 0, 6, "a scratch stays a line")
        // Mold: bands. (Measured seven bands, 4–11 rows tall, median 97%.)
        XCTAssertGreaterThan(median(hit(mold)), 0.8)
        XCTAssertGreaterThanOrEqual(bands(mold).sorted()[bands(mold).count / 2], 6, "patches many lines tall")
        // Two fields on (the same head again), a scratch is at the same
        // heights; a flake has moved on three lines or gone.
        let later = try damage(["tape_scratches": 1], time: 1.0 + 2 / NTSCTiming.fieldRate)
        let flawsLater = try damage(["tape_dropouts": 1], time: 1.0 + 2 / NTSCTiming.fieldRate)
        func same(_ a: [Double], _ b: [Double], over s: Double) -> Double {
            let ia = Set(a.indices.filter { a[$0] > s }), ib = Set(b.indices.filter { b[$0] > s })
            return Double(ia.intersection(ib).count) / Double(max(1, ia.count))
        }
        XCTAssertGreaterThan(same(scratches, later, over: 0.3), 0.75, "scratches stay put (0.95)")
        XCTAssertLessThan(same(flaws, flawsLater, over: 0.3), 0.5, "flaws don't (0.26)")
    }

    func testAFlawOverTheBurstDoesNotFloodTheNextLinesWithColor() throws {
        // ACC holds through a dropout on the burst; chasing it, it turned
        // the following lines' color up as far as 20× (bands of saturated
        // color behind big oxide flaws).
        let input = texture { _, _ in (0.7, 0.45, 0.3) }
        let src = patch(try render(input, ["vcr": 0])).chroma
        let px = try render(input, ["vcr": 1, "tape_dropouts": 1, "head_wear": 0.8])
        var worst = 0.0
        for y in 20..<(A - 20) {
            var c = 0.0
            for x in 40..<(W - 40) { let q = yiq(px, x, y); c += (q.1 * q.1 + q.2 * q.2).squareRoot() }
            worst = max(worst, c / Double(W - 80))
        }
        XCTAssertLessThan(worst, src * 1.6, "most saturated line \(worst) against \(src)")
    }

    func testFullWearIsFarPastTheRealisticWorst() throws {
        // Full Wear should read as too much for all but the most extreme
        // uses: the signal past the FM threshold, even on SP.
        let input = texture { _, _ in (0.5, 0.5, 0.5) }
        let realistic = patch(try render(input, ["vcr": 1, "tape_wear": asBefore("tape_wear", 1)])).noise
        let full = patch(try render(input, ["vcr": 1, "tape_wear": 1])).noise
        XCTAssertGreaterThan(full, realistic * 3, "\(realistic) → \(full)")
    }

    func testEveryCopyIsRecordedAndPlayedAgain() throws {
        let input = texture { _, _ in (0.5, 0.5, 0.5) }
        let original = patch(try render(input, ["vcr": 1])).noise
        let copy = patch(try render(input, ["vcr": 1, "tape_generation": 1])).noise
        let third = patch(try render(input, ["vcr": 1, "tape_generation": 3])).noise
        // (The earlier generation's noise is filtered again by the next
        // playback, so it adds less than its own.)
        XCTAssertGreaterThan(copy, original * 1.07, "a copy adds a generation's noise")
        XCTAssertGreaterThan(third, copy * 1.1, "and so does each copy after it")
    }

    func testFieldsPlayedByTheDirtierHeadAreNoisier() throws {
        let input = texture { _, _ in (0.5, 0.5, 0.5) }
        var noise: [Double] = []
        for i in 0..<4 {
            noise.append(patch(try render(input, time: 1 + Double(i) / 59.94,
                                          ["vcr": 1, "head_wear": 0.5, "head_dirt": 0.4, "head_mismatch": 1])).noise)
        }
        let hi = noise.max()!, lo = noise.min()!
        XCTAssertGreaterThan(hi, lo * 1.5, "alternate fields differ: \(noise)")
    }

    /// The damage knobs' top ends: up to half as calibrated on real tapes,
    /// above it stronger (a wrecked tape at full); the tape choices still
    /// damage a tape as much as before.
    func testDamageKnobsStrengthenOnlyAboveHalf() {
        for (key, gain) in TapeParams.topEndGains {
            for k in stride(from: 0.0, through: 0.5, by: 0.05) {
                XCTAssertEqual(TapeParams.topEnd(Float(k), gain), Float(k), "\(key) at \(k)")
            }
            XCTAssertEqual(TapeParams.topEnd(1, gain), 1 + gain, accuracy: 1e-6, key)
            for amount in [0.6, 0.75, 0.9, 1.0] {
                let knob = TapeParams.knob(forAmount: amount, gain: Double(gain))
                XCTAssertLessThanOrEqual(knob, 1)
                XCTAssertEqual(Double(TapeParams.topEnd(Float(knob), gain)), amount, accuracy: 1e-5, "\(key) \(amount)")
            }
        }
        func tape(_ name: String) -> TapeParams {
            TapeParams(GlitchSettings(values: VcrCondition.tapes.first { $0.name == name }!.values))
        }
        // (Oxide flaws keeps the slider position it had in 0.28, not the
        // amount: TapeParams.knobIn028.)
        let used = VcrCondition.tapes.first { $0.name == "Used" }!.values["tape_dropouts"]!
        XCTAssertEqual(used, TapeParams.knobIn028("tape_dropouts", forAmount: 0.15), accuracy: 1e-9)
        XCTAssertEqual(used, 0.0769, accuracy: 1e-3)
        XCTAssertEqual(tape("Worn out").scratches, 0.45, accuracy: 1e-5)
        XCTAssertEqual(tape("Worn out").wear, 0.75, accuracy: 1e-5)
        XCTAssertEqual(tape("Chewed").creases, 0.7, accuracy: 1e-5)
        XCTAssertEqual(tape("Chewed").edge, 0.7, accuracy: 1e-5)
        let worn = VcrCondition.decks.first { $0.name == "Worn transport" }!.values
        XCTAssertEqual(TransportParams(GlitchSettings(values: worn)).flutter, 0.6, accuracy: 1e-5)
    }

    /// Wear, Oxide flaws, Scratches and Edge damage follow measured curves
    /// (TapeParams.curves): rising all the way, as strong at full as in
    /// 0.27.0, and a look saved before them damages the tape the same.
    func testMeasuredCurvesRiseEvenlyAndKeepOldLooks() {
        for (key, c) in TapeParams.curves {
            XCTAssertEqual(c.count, 11, key)
            XCTAssertEqual(c[0], 0, key)
            for i in 1...10 { XCTAssertGreaterThan(c[i], c[i - 1], "\(key) rises at \(i)") }
            XCTAssertEqual(Double(c[10]), TapeParams.amountIn027(key, 1), accuracy: 1e-6, "\(key): full as before")
            for k in stride(from: 0.0, through: 1.0, by: 0.05) {
                let a = Double(TapeParams.amount(key, Float(k)))
                XCTAssertEqual(TapeParams.knob(key, forAmount: a), k, accuracy: 1e-5, "\(key) inverts at \(k)")
                // A 0.27.0 look: the same damage — except Oxide flaws,
                // whose look keeps the slider position 0.28 gave it.
                let old = GlitchSettings.upgraded([key: k], lookVersion: 2)[key]!
                if TapeParams.curvesIn028[key] == nil {
                    XCTAssertEqual(Double(TapeParams.amount(key, Float(old))), TapeParams.amountIn027(key, k),
                                   accuracy: 1e-4, "\(key): a 0.27.0 look at \(k)")
                } else {
                    XCTAssertEqual(old, TapeParams.knobIn028(key, forAmount: TapeParams.amountIn027(key, k)), accuracy: 1e-9)
                }
            }
        }
        XCTAssertEqual(GlitchSettings.upgraded(["tape_wear": 0.4], lookVersion: 3)["tape_wear"], 0.4,
                       "version 3 looks are read as they are")
    }
}
