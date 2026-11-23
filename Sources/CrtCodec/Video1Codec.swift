import Foundation

// Microsoft Video 1 (1992, Video for Windows; "CRAM"), the Digital video
// stage's second codec: block truncation coding in 15-bit RGB, no transform
// at all. Every 4×4 block is coded the cheapest way that keeps its error
// under the quality's threshold:
//
// - skip (between keyframes): leave the previous picture's block;
// - one color: the block's average;
// - two colors: each pixel picks one of a pair (hard two-tone edges);
// - eight colors: a pair for each 2×2 quarter (busy detail stays readable).
//
// Colors are 5 bits a channel, so gradients step into bands. Coded blocks
// are absolute, so a decoder that lost data heals wherever a block is coded
// again; skipped and lost blocks keep whatever it last had. Apple Video
// (QuickTime's "road pizza") is the same family; starved, it collapses to
// one-color mosaic — this codec's low end.
enum Video1Codec {

    /// The largest mean squared error (per pixel and channel, 0–255 scale)
    /// a block may carry in a cheaper mode. Quality runs √threshold
    /// linearly, as the DCT codec runs √step: the damage changes evenly
    /// along the slider. 0 → 2,500 (nearly everything one color, frozen
    /// between keyframes), 1 → 1 (nearly every block exact to 15 bits).
    static let thresholdRoots: (worst: Double, best: Double) = (50, 1)
    static func threshold(quality: Double, squeeze: Float) -> Float {
        let q = min(1, max(0, quality))
        let r = thresholdRoots.worst + (thresholdRoots.best - thresholdRoots.worst) * q
        return Float(r * r) * squeeze * squeeze
    }

    enum Mode { case skip, fill, two, eight }

    /// 5 bits a channel.
    @inline(__always) static func q555(_ v: Float) -> Float {
        (min(255, max(0, v)) * 31 / 255).rounded() * 255 / 31
    }

    /// RGB of a picture pixel (full-resolution color: Video 1 has no
    /// subsampling, so its pictures are coded 4:4:4).
    @inline(__always) static func rgb(_ p: CodecPicture, _ i: Int) -> SIMD3<Float> {
        let y = p.y.data[i], cb = p.cb.data[i] - 128, cr = p.cr.data[i] - 128
        return SIMD3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb)
    }

    @inline(__always) static func store(_ c: SIMD3<Float>, _ p: CodecPicture, _ i: Int) {
        p.y.data[i] = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        p.cb.data[i] = 128 - 0.168736 * c.x - 0.331264 * c.y + 0.5 * c.z
        p.cr.data[i] = 128 + 0.5 * c.x - 0.418688 * c.y - 0.081312 * c.z
    }

    @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    @inline(__always) static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum()
    }

    /// Two 15-bit colors for `pixels` (indices into them in `members`), and
    /// which one each takes: split at the mean brightness, then one pass of
    /// reassigning to the nearer color. Writes the coded colors into `out`;
    /// returns the squared error.
    static func twoColors(_ pixels: [SIMD3<Float>], _ members: [Int],
                          into out: inout [SIMD3<Float>]) -> Float {
        let mean = members.reduce(Float(0)) { $0 + luma(pixels[$1]) } / Float(members.count)
        var hi = members.map { luma(pixels[$0]) > mean }
        func centers() -> (SIMD3<Float>, SIMD3<Float>)? {
            var a = SIMD3<Float>(repeating: 0), b = a
            var na: Float = 0, nb: Float = 0
            for (k, i) in members.enumerated() {
                if hi[k] { b += pixels[i]; nb += 1 } else { a += pixels[i]; na += 1 }
            }
            guard na > 0, nb > 0 else { return nil }
            return (a / na, b / nb)
        }
        guard var (a, b) = centers() else {
            // All one brightness: one color, twice.
            let m = members.reduce(SIMD3<Float>(repeating: 0)) { $0 + pixels[$1] } / Float(members.count)
            let c = SIMD3(q555(m.x), q555(m.y), q555(m.z))
            var e: Float = 0
            for i in members { out[i] = c; e += distance(pixels[i], c) }
            return e
        }
        for (k, i) in members.enumerated() { hi[k] = distance(pixels[i], b) < distance(pixels[i], a) }
        if let c = centers() { (a, b) = c }
        let qa = SIMD3(q555(a.x), q555(a.y), q555(a.z)), qb = SIMD3(q555(b.x), q555(b.y), q555(b.z))
        var e: Float = 0
        for i in members {
            let c = distance(pixels[i], qb) < distance(pixels[i], qa) ? qb : qa
            out[i] = c
            e += distance(pixels[i], c)
        }
        return e
    }

    static let quarters: [[Int]] = [[0, 1, 4, 5], [2, 3, 6, 7], [8, 9, 12, 13], [10, 11, 14, 15]]

    /// Code one block's 16 pixels the cheapest way that's within `limit`
    /// (squared error summed over the block) — or no worse than the best
    /// any mode can do: on a flat block, 15-bit rounding alone can exceed a
    /// fine limit, and spending eight colors on it would buy nothing.
    static func codeBlock(_ src: [SIMD3<Float>], reference: [SIMD3<Float>]?, limit: Float)
        -> (mode: Mode, pixels: [SIMD3<Float>]) {
        if let reference {
            var e: Float = 0
            for i in 0..<16 { e += distance(src[i], reference[i]) }
            if e <= limit { return (.skip, reference) }
        }
        let mean = src.reduce(SIMD3<Float>(repeating: 0), +) / 16
        let fill = SIMD3(q555(mean.x), q555(mean.y), q555(mean.z))
        var fillError: Float = 0
        for p in src { fillError += distance(p, fill) }
        if fillError <= limit { return (.fill, Array(repeating: fill, count: 16)) }
        var two = src
        let twoError = twoColors(src, Array(0..<16), into: &two)
        var eight = src
        var eightError: Float = 0
        for q in quarters { eightError += twoColors(src, q, into: &eight) }
        let good = max(limit, eightError * 1.05 + 1e-3)
        if fillError <= good { return (.fill, Array(repeating: fill, count: 16)) }
        if twoError <= good { return (.two, two) }
        return (.eight, eight)
    }

    // MARK: - the same, without allocating
    //
    // `codeBlock` above makes a dozen small arrays a block, and shares
    // static ones between every core: at 640 × 480 (19,200 blocks) a frame
    // took 130 ms, and playback stood still. `step` uses the versions
    // below, which do the same arithmetic in the same order on scratch
    // memory (tested equal to `codeBlock`, bit for bit).

    /// Scratch for one thread: five 16-pixel blocks and 16 flags.
    struct Scratch {
        let base: UnsafeMutablePointer<SIMD3<Float>>
        let hi: UnsafeMutablePointer<Bool>
        var src: UnsafeMutablePointer<SIMD3<Float>> { base }
        var ref: UnsafeMutablePointer<SIMD3<Float>> { base + 16 }
        var fill: UnsafeMutablePointer<SIMD3<Float>> { base + 32 }
        var two: UnsafeMutablePointer<SIMD3<Float>> { base + 48 }
        var eight: UnsafeMutablePointer<SIMD3<Float>> { base + 64 }

        init() {
            base = .allocate(capacity: 80)
            base.initialize(repeating: .zero, count: 80)
            hi = .allocate(capacity: 16)
            hi.initialize(repeating: false, count: 16)
        }
        func free() { base.deallocate(); hi.deallocate() }
    }

    /// Which pixels each coding works on: all sixteen, then the quarters.
    static let members: [Int] = Array(0..<16) + quarters.flatMap { $0 }

    /// `twoColors` on scratch memory: `members` points at `count` indices.
    @inline(__always)
    static func twoColors(_ pixels: UnsafePointer<SIMD3<Float>>, _ members: UnsafePointer<Int>, _ count: Int,
                          into out: UnsafeMutablePointer<SIMD3<Float>>, hi: UnsafeMutablePointer<Bool>) -> Float {
        var sum: Float = 0
        for k in 0..<count { sum = sum + luma(pixels[members[k]]) }
        let mean = sum / Float(count)
        for k in 0..<count { hi[k] = luma(pixels[members[k]]) > mean }
        var a = SIMD3<Float>(repeating: 0), b = a
        var na: Float = 0, nb: Float = 0
        for k in 0..<count {
            let i = members[k]
            if hi[k] { b += pixels[i]; nb += 1 } else { a += pixels[i]; na += 1 }
        }
        guard na > 0, nb > 0 else {
            // All one brightness: one color, twice.
            var m = SIMD3<Float>(repeating: 0)
            for k in 0..<count { m = m + pixels[members[k]] }
            m = m / Float(count)
            let c = SIMD3(q555(m.x), q555(m.y), q555(m.z))
            var e: Float = 0
            for k in 0..<count { let i = members[k]; out[i] = c; e += distance(pixels[i], c) }
            return e
        }
        a = a / na; b = b / nb
        for k in 0..<count {
            let i = members[k]
            hi[k] = distance(pixels[i], b) < distance(pixels[i], a)
        }
        var a2 = SIMD3<Float>(repeating: 0), b2 = a2
        na = 0; nb = 0
        for k in 0..<count {
            let i = members[k]
            if hi[k] { b2 += pixels[i]; nb += 1 } else { a2 += pixels[i]; na += 1 }
        }
        if na > 0, nb > 0 { a = a2 / na; b = b2 / nb }
        let qa = SIMD3(q555(a.x), q555(a.y), q555(a.z)), qb = SIMD3(q555(b.x), q555(b.y), q555(b.z))
        var e: Float = 0
        for k in 0..<count {
            let i = members[k]
            let c = distance(pixels[i], qb) < distance(pixels[i], qa) ? qb : qa
            out[i] = c
            e += distance(pixels[i], c)
        }
        return e
    }

    /// `codeBlock` on scratch memory: codes `s.src` (against `s.ref` when
    /// `hasReference`) and returns the mode and where the coded pixels are.
    @inline(__always)
    static func codeBlock(_ s: Scratch, hasReference: Bool, limit: Float, members: UnsafePointer<Int>)
        -> (mode: Mode, pixels: UnsafeMutablePointer<SIMD3<Float>>) {
        let src = s.src
        if hasReference {
            var e: Float = 0
            for i in 0..<16 { e += distance(src[i], s.ref[i]) }
            if e <= limit { return (.skip, s.ref) }
        }
        var total = SIMD3<Float>(repeating: 0)
        for i in 0..<16 { total = total + src[i] }
        let mean = total / 16
        let fill = SIMD3(q555(mean.x), q555(mean.y), q555(mean.z))
        var fillError: Float = 0
        for i in 0..<16 { fillError += distance(src[i], fill) }
        if fillError <= limit {
            for i in 0..<16 { s.fill[i] = fill }
            return (.fill, s.fill)
        }
        let twoError = twoColors(src, members, 16, into: s.two, hi: s.hi)
        var eightError: Float = 0
        for q in 0..<4 { eightError += twoColors(src, members + 16 + 4 * q, 4, into: s.eight, hi: s.hi) }
        let good = max(limit, eightError * 1.05 + 1e-3)
        if fillError <= good {
            for i in 0..<16 { s.fill[i] = fill }
            return (.fill, s.fill)
        }
        if twoError <= good { return (.two, s.two) }
        return (.eight, s.eight)
    }

    /// Mean absolute luma change against the reference — how much there is
    /// to code (for the fixed-bitrate squeeze).
    static func change(_ a: CodecPicture, _ b: CodecPicture, geometry g: CodecGeometry) -> Float {
        var rows = [Float](repeating: 0, count: g.height)
        rows.withUnsafeMutableBufferPointer { rp in
            let out = rp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: g.height) { y in
                var s: Float = 0
                for x in 0..<g.width { s += abs(a.y.data[y * a.y.width + x] - b.y.data[y * b.y.width + x]) }
                out[y] = s
            }
        }
        return rows.reduce(0, +) / Float(g.width * g.height)
    }

    /// Code `source` as `kind`, advancing `state` — the same contract as
    /// `DigitalCodec.step` (datamosh doesn't apply: there's no motion to
    /// drag, so a lost keyframe is coded as one that arrived).
    static func step(_ state: CodecState, source: CodecPicture, kind: CodecFrameKind,
                     index: Int, settings s: DigitalCodec.FrameSettings) -> CodecPicture {
        let g = state.geometry
        let lost = DigitalCodec.lostBlocks(amount: s.dataLoss, index: index, geometry: g, pattern: s.lossPattern)
        let predicted = kind == .predicted && state.encoder != nil
        let encRef = predicted ? state.encoder : nil
        let complexity = predicted ? change(source, encRef!, geometry: g) : DigitalCodec.detail(source, geometry: g)
        let squeeze = DigitalCodec.squeeze(complexity: complexity, typical: predicted ? 3 : 14,
                                           strictness: s.fixedBitrate)
        let limit = threshold(quality: s.quality, squeeze: squeeze) * 48

        let previous = state.encoder
        let enc = CodecPicture(geometry: g)
        // The decoder starts from what it had; coded blocks overwrite it.
        let dec = CodecPicture(geometry: g)
        let decBase = state.decoder ?? previous
        let w = g.lumaW, cols = g.lumaW / 4
        var anyLoss = false
        if let lost { anyLoss = lost.contains(true) }
        let mbCols = g.mbCols
        Self.members.withUnsafeBufferPointer { table in
        let members = table.baseAddress!
        DispatchQueue.concurrentPerform(iterations: g.lumaH / 4) { by in
            let scratch = Scratch()
            defer { scratch.free() }
            let src = scratch.src, ref = scratch.ref
            for bx in 0..<cols {
                for i in 0..<16 {
                    let k = (by * 4 + i / 4) * w + bx * 4 + i % 4
                    src[i] = rgb(source, k)
                    if let encRef { ref[i] = rgb(encRef, k) }
                }
                let coded = codeBlock(scratch, hasReference: encRef != nil, limit: limit, members: members)
                let mb = (by * 4 / 16) * mbCols + bx * 4 / 16
                let blockLost = lost?[mb] == true
                for i in 0..<16 {
                    let k = (by * 4 + i / 4) * w + bx * 4 + i % 4
                    if coded.mode == .skip, let encRef {
                        // Copied exactly, never re-converted: a block can
                        // be skipped for hundreds of frames.
                        enc.y.data[k] = encRef.y.data[k]
                        enc.cb.data[k] = encRef.cb.data[k]
                        enc.cr.data[k] = encRef.cr.data[k]
                    } else {
                        store(coded.pixels[i], enc, k)
                    }
                    if blockLost || coded.mode == .skip, let base = (kind == .intraOnly ? previous : decBase) {
                        // Nothing arrived: whatever the decoder had stays.
                        // (Each frame on its own: patched from the last
                        // frame as coded, so the damage lasts one frame.)
                        dec.y.data[k] = base.y.data[k]
                        dec.cb.data[k] = base.cb.data[k]
                        dec.cr.data[k] = base.cr.data[k]
                    } else {
                        store(coded.pixels[i], dec, k)
                    }
                }
            }
        }
        }
        state.encoder = enc
        state.vectors = Array(repeating: MotionVector(), count: g.mbCount)
        switch kind {
        case .key, .droppedKey:
            // Keyframes arrive whole (streams protect them).
            state.decoder = enc
            state.diverged = false
        case .intraOnly:
            state.decoder = anyLoss && previous != nil ? dec : enc
            state.diverged = state.decoder !== enc
        case .predicted:
            if !state.diverged && !anyLoss {
                state.decoder = enc
            } else {
                state.decoder = dec
                state.diverged = true
            }
        }
        return state.decoder!
    }
}
