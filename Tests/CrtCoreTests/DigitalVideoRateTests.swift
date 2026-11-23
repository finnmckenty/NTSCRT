import XCTest
@testable import CrtCodec
import CrtCore

/// Block size, the Bitrate limit with its Buffer, and Generations. Each is
/// off (or at the codec's own value) by default, so every earlier look is
/// untouched; each is checked for what it does to the picture, and that a
/// frame still looks the same however it's reached.
extension DigitalVideoTests {

    /// The picture the stage shows, at the capture size.
    private func shrunk(_ px: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: capture.width * capture.height * 4)
        let k = size.width / capture.width
        for y in 0..<capture.height {
            for x in 0..<capture.width {
                let s = ((y * k) * size.width + x * k) * 4, d = (y * capture.width + x) * 4
                for c in 0..<4 { out[d + c] = px[s + c] }
            }
        }
        return out
    }

    private var clean: [String: Double] {
        ["frame_rate": 30, "fields": 0, "sensor_noise": 0, "noise_reduction": 0, "quality": 0.9,
         "chroma": 2, "keyframe_interval": 0]
    }

    private func with(_ base: [String: Double], _ more: [String: Double]) -> DigitalSettings {
        DigitalSettings(values: base.merging(more) { _, n in n })
    }

    /// A smooth picture with one soft blob: nothing in it lines up with any
    /// block grid.
    private func smooth(_ g: CodecGeometry) -> CodecPicture {
        let p = CodecPicture(geometry: g)
        for y in 0..<g.lumaH {
            for x in 0..<g.lumaW {
                let dx = Float(x) - 0.43 * Float(g.lumaW), dy = Float(y) - 0.57 * Float(g.lumaH)
                p.y.data[y * g.lumaW + x] = 40 + 0.9 * Float(x) + 0.6 * Float(y) + 70 * exp(-(dx * dx + dy * dy) / 900)
            }
        }
        return p
    }

    /// A picture with detail at every scale and nothing lined up with any
    /// block grid (the clip's checkerboard is 4 capture pixels square, which
    /// 4-pixel blocks code for free).
    private func texture() -> [UInt8] {
        let (w, h) = size
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x), fy = Double(y)
                let a = sin(fx / 14.6 + fy / 22.2), b = sin(fx / 5.3 - fy / 7.9), c = sin(fx / 41 + fy / 9.7)
                let i = (y * w + x) * 4
                px[i] = UInt8(min(255, max(0, 120 + 60 * a + 35 * c)))
                px[i + 1] = UInt8(min(255, max(0, 128 + 50 * b + 40 * a)))
                px[i + 2] = UInt8(min(255, max(0, 110 + 70 * c + 30 * b + fx / 4)))
            }
        }
        return px
    }

    /// `picture` as a still through the stage, at the capture size.
    private func shown(_ picture: [UInt8], _ s: DigitalSettings) -> [UInt8] {
        var px = picture
        px.withUnsafeMutableBytes {
            DigitalVideoRenderer().process(frame: 0, pixels: $0.baseAddress!, width: size.width, height: size.height,
                                           rowBytes: size.width * 4, captureSize: capture, sourceFPS: 30, settings: s)
        }
        return shrunk(px)
    }

    // MARK: - off by default

    func testBlockSizeBitrateAndGenerationsStartNeutral() {
        let s = DigitalSettings()
        XCTAssertEqual(s.blockSize, 8)
        XCTAssertEqual(s.bitsPerPixel, 0)
        XCTAssertEqual(s.generations, 0)
        XCTAssertNil(s.bitrateLabel(width: 320, height: 240, sourceFPS: 30))
        for f in DigitalFormat.all {
            let fs = DigitalSettings(values: f.values)
            XCTAssertEqual(fs.blockSize, 8, f.id)
            XCTAssertEqual(fs.bitsPerPixel, 0, f.id)
            XCTAssertEqual(fs.generations, 0, f.id)
            XCTAssertNotNil(DigitalFormat.matching(values: fs.values, width: f.width), f.id)
        }
        // The Buffer alone does nothing: it works on the limit.
        let base = with(clean, ["keyframe_interval": 1])
        let a = DigitalVideoRenderer(), b = DigitalVideoRenderer()
        for n in 0..<12 {
            XCTAssertTrue(render(a, n, base) == render(b, n, with(base.values, ["rate_buffer": 0])), "frame \(n)")
        }
        // Video 1 has neither blocks to resize nor bits to count.
        let v1 = with(clean, ["codec": 1, "block_size": 2, "bitrate_limit": 0.8])
        XCTAssertEqual(v1.blockSize, 8)
        XCTAssertEqual(v1.bitsPerPixel, 0)
    }

    // MARK: - block size

    func testEveryBlockSizeTransformsThereAndBack() {
        for n in [4, 8, 16] {
            var block = [Float](repeating: 0, count: n * n)
            for i in 0..<(n * n) { block[i] = Float((i * 37) % 255) - 128 }
            var coef = block, back = block, tmp = block
            DigitalCodec.basis(n).withUnsafeBufferPointer { c in
                DigitalCodec.forwardDCT(block, stride: n, &coef, &tmp, c.baseAddress!, n: n)
                DigitalCodec.inverseDCT(coef, &back, stride: n, &tmp, c.baseAddress!, n: n)
            }
            for i in 0..<(n * n) { XCTAssertEqual(back[i], block[i], accuracy: 2e-3, "\(n)") }
            // Orthonormal: a flat block of 1s has an average of n, nothing else.
            let flat = [Float](repeating: 1, count: n * n)
            DigitalCodec.basis(n).withUnsafeBufferPointer { c in
                DigitalCodec.forwardDCT(flat, stride: n, &coef, &tmp, c.baseAddress!, n: n)
            }
            XCTAssertEqual(coef[0], Float(n), accuracy: 1e-4)
            XCTAssertEqual(coef[1...].map(abs).max()!, 0, accuracy: 1e-4)
        }
    }

    func testBlockSizeScalesTheWholeStructure() {
        for (n, cols, rows) in [(4, 16, 12), (8, 8, 6), (16, 4, 3)] {
            let g = CodecGeometry(width: 128, height: 96, chroma: .halfBoth, block: n)
            XCTAssertEqual(g.mb, 2 * n)
            XCTAssertEqual(g.mbCols, cols); XCTAssertEqual(g.mbRows, rows)
            XCTAssertEqual(g.lumaW % (2 * n), 0); XCTAssertEqual(g.chromaW % n, 0)
            // A lost macroblock is a square twice the block's size.
            var lost = [Bool](repeating: false, count: g.mbCount)
            lost[g.mbCols + 1] = true
            let p = smooth(g)
            DigitalCodec.conceal(p, lost: lost, mode: .green, geometry: g)
            for y in 0..<g.lumaH {
                for x in 0..<g.lumaW {
                    let inside = x >= 2 * n && x < 4 * n && y >= 2 * n && y < 4 * n
                    XCTAssertEqual(p.y.data[y * g.lumaW + x] == 0, inside, "\(n) px: \(x),\(y)")
                }
            }
        }
        // Sizes that aren't whole macroblocks pad up; the default is as it was.
        let odd = CodecGeometry(width: 100, height: 50, chroma: .quarterWide, block: 16)
        XCTAssertEqual(odd.lumaW, 128); XCTAssertEqual(odd.lumaH, 64); XCTAssertEqual(odd.chromaW, 32)
        let usual = CodecGeometry(width: 100, height: 50, chroma: .quarterWide)
        XCTAssertEqual(usual.block, 8); XCTAssertEqual(usual.lumaW, 112); XCTAssertEqual(usual.chromaW, 32)
    }

    /// Coded hard, a smooth picture turns into tiles: its steps fall on the
    /// block edges, so they tell the block's size.
    func testBlockEdgesFallEveryBlockSize() {
        for n in [4, 8, 16] {
            let g = CodecGeometry(width: 128, height: 96, chroma: .full, block: n)
            let src = smooth(g), out = CodecPicture(geometry: g)
            DigitalCodec.codeIntra(src, into: out, steps: .init(quality: 0.05, squeeze: 1, block: n))
            var onEdge: Float = 0, edges = 0, inside: Float = 0, insides = 0
            for y in 0..<g.lumaH {
                for x in 1..<g.lumaW {
                    let jump = abs(out.y.data[y * g.lumaW + x] - out.y.data[y * g.lumaW + x - 1])
                    if x % n == 0 { onEdge += jump; edges += 1 } else { inside += jump; insides += 1 }
                }
            }
            XCTAssertGreaterThan(onEdge / Float(edges), 4 * inside / Float(insides), "\(n) px")
        }
    }

    func testOneQualityDoesAboutTheSameDamageAtEveryBlockSize() {
        let picture = texture()
        for quality in [0.75, 0.5, 0.25] {
            let reference = shown(picture, with(clean, ["quality": 1, "chroma": 0]))
            let damage = [0.0, 1, 2].map { block in
                meanDifference(shown(picture, with(clean, ["quality": quality, "chroma": 0, "block_size": block])),
                               reference)
            }
            XCTAssertGreaterThan(damage.min()!, 1)
            XCTAssertLessThan(damage.max()!, 1.7 * damage.min()!, "quality \(quality): \(damage)")
        }
    }

    func testEveryBlockSizeLooksTheSameJumpedToAsPlayed() {
        for size in [0.0, 2] {
            checkJumpsMatchPlaying(with(clean, ["block_size": size, "keyframe_interval": 0.5, "quality": 0.5,
                                                "data_loss": 0.5, "datamosh": 0.5, "bit_errors": 0.5,
                                                "mosh_motion": 4, "deblocking": 0.5, "chroma": 3,
                                                "concealment": 3, "fixed_bitrate": 0.5]),
                                   cut: 16, "stream at block size \(size)")
            checkJumpsMatchPlaying(with(clean, ["block_size": size, "data_loss": 0.6, "loss_pattern": 1,
                                                "bit_errors": 0.4, "concealment": 2]),
                                   cut: 16, "tape at block size \(size)")
        }
    }

    /// The smallest pictures, with everything on: nothing reads past an edge.
    func testTinyPicturesSurviveEveryBlockSize() {
        for (w, h) in [(16, 16), (40, 24), (18, 34)] {
            for block in [0.0, 1, 2] {
                for chroma in [0.0, 2, 3] {
                    let s = with(clean, ["block_size": block, "chroma": chroma, "keyframe_interval": 0.2,
                                         "data_loss": 0.8, "loss_pattern": 2, "bit_errors": 1, "mosh_motion": 3,
                                         "mosh_speed": 1, "deblocking": 1, "concealment": 3, "generations": 2,
                                         "bitrate_limit": 0.7, "rate_buffer": 0.1, "datamosh": 0.5])
                    let r = DigitalVideoRenderer()
                    for n in 0..<10 {
                        var px = frame(n)
                        px.withUnsafeMutableBytes {
                            r.process(frame: n, pixels: $0.baseAddress!, width: self.size.width, height: self.size.height,
                                      rowBytes: self.size.width * 4, captureSize: (w, h), sourceFPS: 30,
                                      settings: s, earlier: visitor())
                        }
                        XCTAssertEqual(px.count, self.size.width * self.size.height * 4)
                    }
                }
            }
        }
    }

    // MARK: - counting bits

    func testBitsFallAsTheQuantizerCoarsens() {
        for n in [4, 8, 16] {
            let g = CodecGeometry(width: 128, height: 96, chroma: .halfBoth, block: n)
            let px = shrunk(frame(3))
            let src = DigitalVideoRenderer.capture(px, geometry: g, settings: with(clean, [:]), index: 0)
            let coefs = DigitalCodec.coefficients(of: src, minus: nil, geometry: g)
            var last = Int.max
            for scale: Float in [0.1, 0.5, 2, 8] {
                let bits = DigitalCodec.bits(coefs, steps: .init(scale: scale, block: n), intra: true)
                XCTAssertLessThan(bits, last, "\(n) px at \(scale)")
                last = bits
            }
            // A believable size: a detailed picture at a good quality takes
            // somewhere between a quarter of a bit and a few bits a pixel.
            let good = Double(DigitalCodec.bits(coefs, steps: .init(quality: 0.9, squeeze: 1, block: n), intra: true))
            XCTAssertGreaterThan(good / Double(128 * 96), 0.25)
            XCTAssertLessThan(good / Double(128 * 96), 6)
            // A difference of nothing costs nothing.
            let none = DigitalCodec.coefficients(of: src, minus: src, geometry: g)
            XCTAssertEqual(DigitalCodec.bits(none, steps: .init(quality: 0.9, squeeze: 1, block: n), intra: false), 0)
        }
    }

    func testFittingFindsTheFinestQuantizerWithinTheBudget() {
        let g = CodecGeometry(width: 128, height: 96, chroma: .halfBoth)
        let src = DigitalVideoRenderer.capture(shrunk(frame(3)), geometry: g, settings: with(clean, [:]), index: 0)
        let coefs = DigitalCodec.coefficients(of: src, minus: nil, geometry: g)
        let start = DigitalCodec.Steps(quality: 0.9, squeeze: 1)
        let full = DigitalCodec.bits(coefs, steps: start, intra: true)
        // Room to spare: the quantizer stays where Quality put it.
        let easy = DigitalCodec.fit(coefs, start: start, intra: true, budget: Double(full) * 1.5)
        XCTAssertEqual(easy.steps.scale, start.scale)
        XCTAssertEqual(easy.bits, full)
        // Half the room: coarser, within the budget, and not by much.
        let half = DigitalCodec.fit(coefs, start: start, intra: true, budget: Double(full) / 2)
        XCTAssertGreaterThan(half.steps.scale, start.scale)
        XCTAssertLessThanOrEqual(half.bits, full / 2)
        XCTAssertGreaterThan(half.bits, full / 3)
        // No room at all: as coarse as it goes, and no further.
        let none = DigitalCodec.fit(coefs, start: start, intra: true, budget: 10)
        XCTAssertEqual(none.steps.scale, DigitalCodec.coarsestScale)
    }

    func testBitrateLabelIsTheRealRate() {
        // 50% is 2 × (0.01 / 2)^0.5 = 0.1414 bits a pixel.
        let s = with(clean, ["bitrate_limit": 0.5, "frame_rate": 15])
        XCTAssertEqual(s.bitsPerPixel, 0.14142, accuracy: 1e-4)
        XCTAssertEqual(s.bitrateLabel(width: 320, height: 240, sourceFPS: 30), "≈ 163 kbps at 320 × 240, 15 fps")
        XCTAssertEqual(with(clean, ["bitrate_limit": 0.05]).bitrateLabel(width: 720, height: 480, sourceFPS: 30),
                       "≈ 16 Mbps at 720 × 480, 30 fps")
        XCTAssertEqual(with(clean, ["bitrate_limit": 1]).bitsPerPixel, 0.01, accuracy: 1e-9)
    }

    // MARK: - the bitrate limit

    /// Every frame on its own: each gets the same bits, so a tighter limit
    /// is a coarser picture, down to the coarsest the codec goes.
    func testALimitCoarsensFramesCodedAlone() {
        let g = CodecGeometry(width: 128, height: 96, chroma: .halfBoth)
        let src = DigitalVideoRenderer.capture(shrunk(texture()), geometry: g, settings: with(clean, [:]), index: 0)
        let coefs = DigitalCodec.coefficients(of: src, minus: nil, geometry: g)
        let pixels = Double(g.width * g.height)
        let full = Double(DigitalCodec.bits(coefs, steps: .init(quality: 0.9, squeeze: 1), intra: true))
        let least = Double(DigitalCodec.bits(coefs, steps: .init(scale: DigitalCodec.coarsestScale), intra: true))
        XCTAssertLessThan(least, full / 3)
        func coded(_ bitsPerPixel: Double) -> (error: Float, step: Float) {
            let state = CodecState(geometry: g)
            let out = DigitalCodec.step(state, source: src, kind: .intraOnly, index: 0,
                                        settings: .init(quality: 0.9, fixedBitrate: 0, dataLoss: 0,
                                                        bitsPerPixel: bitsPerPixel, bufferFrames: 30))
            var e: Float = 0
            for i in 0..<(g.lumaW * g.lumaH) { e += abs(out.picture.y.data[i] - src.y.data[i]) }
            // Alone, a frame leaves nothing in the buffer however big it is.
            XCTAssertEqual(state.bufferFill, 0)
            return (e / Float(g.lumaW * g.lumaH), out.step)
        }
        let free = coded(0)
        // Room to spare changes nothing.
        XCTAssertEqual(coded(full * 1.2 / pixels).error, free.error)
        var last = free
        for share in [0.75, 0.5, 0.25].map({ least + (full - least) * $0 }) {
            let now = coded(share / pixels)
            XCTAssertGreaterThan(now.error, last.error, "share \(share)")
            XCTAssertGreaterThan(now.step, last.step)
            last = now
        }
        // Past the coarsest it has nothing more to take.
        XCTAssertEqual(coded(least * 0.5 / pixels).error, coded(least * 0.1 / pixels).error)
        XCTAssertEqual(coded(least * 0.5 / pixels).step, DigitalCodec.Steps(scale: DigitalCodec.coarsestScale).inter)
    }

    /// Between keyframes a cut is a whole new picture to send as a
    /// difference. With the buffer spent it has to fit a frame's share: the
    /// picture collapses, then recovers as the frames after it catch up.
    func testACutCollapsesAndRecoversUnderALimit() {
        let stream = with(clean, ["keyframe_interval": 3, "quality": 0.95])
        let cut = 20
        let free = played(stream, frames: 60, cut: cut)
        let tight = played(with(stream.values, ["bitrate_limit": 0.6, "rate_buffer": 0.1]), frames: 60, cut: cut)
        let damage = (0..<60).map { meanDifference(tight[$0], free[$0]) }
        let before = damage[(cut - 5)..<cut].max()!
        let after = damage[cut..<(cut + 4)].max()!
        XCTAssertGreaterThan(after, 3 * before + 2, "\(damage.map { ($0 * 10).rounded() / 10 })")
        // Half a second on it has cleared again.
        XCTAssertLessThan(damage[(cut + 30)..<(cut + 40)].max()!, after / 2)
    }

    /// A stream that fits its share between cuts has the buffer free when
    /// one comes: a big buffer takes the cut whole, a small one can't.
    func testABiggerBufferLetsACutThrough() {
        let stream = with(clean, ["keyframe_interval": 3, "quality": 0.95, "bitrate_limit": 0.35])
        let cut = 24
        let free = played(with(stream.values, ["bitrate_limit": 0]), frames: 30, cut: cut)
        func damage(_ buffer: Double) -> [Double] {
            let out = played(with(stream.values, ["rate_buffer": buffer]), frames: 30, cut: cut)
            return (0..<30).map { meanDifference(out[$0], free[$0]) }
        }
        let big = damage(4), small = damage(0.1)
        // Before the cut both have settled (the small one's keyframe was
        // squeezed, and has been made good since).
        XCTAssertLessThan(small[cut - 1], small[0] / 3, "\(small.map { ($0 * 10).rounded() / 10 })")
        XCTAssertLessThan(big[cut...].max()!, 1, "\(big.map { ($0 * 10).rounded() / 10 })")
        XCTAssertGreaterThan(small[cut], 4 * small[cut - 1], "\(small.map { ($0 * 10).rounded() / 10 })")
        // And each frame after it is better than the one before.
        for n in (cut + 1)..<(cut + 6) { XCTAssertLessThan(small[n], small[n - 1], "frame \(n)") }
    }

    /// Starved past the coarsest quantizer, the encoder sends nothing and
    /// waits: the picture stands still.
    func testAStarvedStreamSkipsFrames() {
        let stream = with(clean, ["keyframe_interval": 3, "quality": 0.95, "bitrate_limit": 0.95, "rate_buffer": 0.3])
        let out = played(stream, frames: 40, cut: 20)
        let frozen = (1..<40).filter { out[$0] == out[$0 - 1] }.count
        XCTAssertGreaterThan(frozen, 5)
        // Without the limit the moving square changes every frame.
        let free = played(with(stream.values, ["bitrate_limit": 0]), frames: 40, cut: 20)
        XCTAssertEqual((1..<40).filter { free[$0] == free[$0 - 1] }.count, 0)
        // And it isn't stuck: the new scene does arrive.
        XCTAssertLessThan(meanDifference(out[39], free[39]), meanDifference(out[39], free[10]))
    }

    func testALimitedStreamLooksTheSameJumpedToAsPlayed() {
        let stream = with(clean, ["keyframe_interval": 0.5, "quality": 0.95])
        checkJumpsMatchPlaying(with(stream.values, ["bitrate_limit": 0.65, "rate_buffer": 0.2]), cut: 16, "limit")
        checkJumpsMatchPlaying(with(stream.values, ["bitrate_limit": 0.9, "rate_buffer": 0.3, "datamosh": 0.6,
                                                    "data_loss": 0.4, "deblocking": 0.6, "block_size": 2]),
                               cut: 16, "starved + mosh")
        checkJumpsMatchPlaying(with(clean, ["bitrate_limit": 0.6, "data_loss": 0.5, "loss_pattern": 2]),
                               cut: 16, "limit, frames alone")
        // The limit keyframed on the timeline.
        let history = DigitalHistory(id: 11) { n in
            var s = stream
            s.values["bitrate_limit"] = n > 12 ? 0.8 : 0.3
            s.values["rate_buffer"] = n > 25 ? 0.5 : 0.1
            return s
        }
        checkJumpsMatchPlaying(stream, cut: 16, history: history, "limit keyframed")
    }

    // MARK: - generations

    func testGenerationsWearThePictureDownAndLeaveItInPlace() {
        let base = with(clean, ["quality": 0.6])
        let first = shrunk(played(base, frames: 1)[0])
        var last = 0.0
        for count in [1.0, 4, 12] {
            let out = shrunk(played(with(base.values, ["generations": count]), frames: 1)[0])
            let damage = meanDifference(out, first)
            XCTAssertGreaterThan(damage, last + 0.2, "\(count) generations")
            last = damage
        }
        // The picture hasn't drifted: it's nearer the original where it is
        // than moved a pixel any way. (The crops between generations come
        // back off.)
        let worn = shrunk(played(with(base.values, ["generations": 12]), frames: 1)[0])
        func moved(_ dx: Int, _ dy: Int) -> Double {
            var s = 0, n = 0
            for y in 8..<(capture.height - 8) {
                for x in 8..<(capture.width - 8) {
                    let a = (y * capture.width + x) * 4, b = ((y + dy) * capture.width + x + dx) * 4
                    for c in 0..<3 { s += abs(Int(worn[a + c]) - Int(first[b + c])) }
                    n += 3
                }
            }
            return Double(s) / Double(n)
        }
        for (dx, dy) in [(2, 0), (-2, 0), (0, 2), (0, -2)] {
            XCTAssertLessThan(moved(0, 0), moved(dx, dy), "moved \(dx),\(dy)")
        }
        // The edges aren't eaten: the outermost pixels are no worse off
        // than the picture as a whole, give or take.
        var edge = 0, count = 0
        for y in 0..<capture.height {
            for x in [0, capture.width - 1] {
                let i = (y * capture.width + x) * 4
                for c in 0..<3 { edge += abs(Int(worn[i + c]) - Int(first[i + c])) }
                count += 3
            }
        }
        XCTAssertLessThan(Double(edge) / Double(count), 3 * last + 4)
    }

    /// What wears the picture down is the move between passes: compressed
    /// again on the same blocks, almost nothing more is lost.
    func testCompressingAgainOnTheSameBlocksChangesLittle() {
        let g = CodecGeometry(width: 128, height: 96, chroma: .halfBoth)
        let s = with(clean, ["quality": 0.6])
        let src = DigitalVideoRenderer.capture(shrunk(frame(2)), geometry: g, settings: s, index: 0)
        let once = CodecPicture(geometry: g), twice = CodecPicture(geometry: g)
        let steps = DigitalCodec.Steps(quality: 0.6, squeeze: 1)
        DigitalCodec.codeIntra(src, into: once, steps: steps)
        DigitalCodec.codeIntra(once, into: twice, steps: steps)
        let a = DigitalVideoRenderer.render(once, geometry: g, settings: s, step: steps.inter)
        let same = meanDifference(DigitalVideoRenderer.render(twice, geometry: g, settings: s, step: steps.inter), a)
        let moved = meanDifference(DigitalVideoRenderer.regenerate(a, geometry: g, settings: s, generation: 1), a)
        XCTAssertGreaterThan(moved, 3 * same + 0.3, "same grid \(same), moved \(moved)")
    }

    func testGenerationsLookTheSameJumpedToAsPlayed() {
        checkJumpsMatchPlaying(with(clean, ["generations": 3, "keyframe_interval": 0.5, "quality": 0.5,
                                            "data_loss": 0.4, "deblocking": 0.4, "chroma": 3, "block_size": 0]),
                               cut: 16, "generations")
        // Video 1 goes round again as Video 1.
        let v1 = settings("cd_rom", ["keyframe_interval": 0.5])
        checkJumpsMatchPlaying(with(v1.values, ["generations": 3]), cut: 16, "Video 1 generations")
        let once = played(v1, frames: 3), worn = played(with(v1.values, ["generations": 6]), frames: 3)
        XCTAssertGreaterThan(meanDifference(worn[2], once[2]), 0.5)
    }
}
