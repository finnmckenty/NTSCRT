import Foundation

// The Digital video stage's codec: a small, real block-transform video codec
// in the MPEG/H.263/DV family, run on the CPU at the capture resolution.
//
// - Pictures are Y′CbCr (BT.601) with subsampled color, coded in 8×8 DCT
//   blocks against the JPEG reference quantization tables.
// - Keyframes are coded alone; between them each 16×16 macroblock is
//   predicted from the previous picture by a motion vector, and only the
//   quantized difference is sent.
// - The encoder and decoder each keep their own reference picture. They
//   agree until data is lost or a keyframe is thrown away; after that the
//   decoder applies the encoder's motion and differences to the wrong
//   picture — which is exactly what packet-loss smearing and datamoshing
//   are. Neither is drawn.
//
// Everything is deterministic: the same captures and settings give the same
// pictures, bit for bit, however the work is split across cores.

/// One plane of samples on the 0…255 scale, padded to whole blocks.
final class CodecPlane {
    let width: Int
    let height: Int
    let data: UnsafeMutablePointer<Float>

    init(width: Int, height: Int, fill: Float = 0) {
        self.width = width
        self.height = height
        data = .allocate(capacity: width * height)
        data.initialize(repeating: fill, count: width * height)
    }

    deinit { data.deallocate() }

    func copy() -> CodecPlane {
        let p = CodecPlane(width: width, height: height)
        p.data.update(from: data, count: width * height)
        return p
    }

    func assign(from other: CodecPlane) {
        precondition(other.width == width && other.height == height)
        data.update(from: other.data, count: width * height)
    }

    @inline(__always) func clamped(_ x: Int, _ y: Int) -> Float {
        data[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))]
    }
}

/// A picture: brightness and two color-difference planes.
final class CodecPicture {
    let y: CodecPlane
    let cb: CodecPlane
    let cr: CodecPlane
    var planes: [CodecPlane] { [y, cb, cr] }

    init(geometry g: CodecGeometry) {
        y = CodecPlane(width: g.lumaW, height: g.lumaH, fill: 0)
        cb = CodecPlane(width: g.chromaW, height: g.chromaH, fill: 128)
        cr = CodecPlane(width: g.chromaW, height: g.chromaH, fill: 128)
    }

    private init(y: CodecPlane, cb: CodecPlane, cr: CodecPlane) {
        self.y = y; self.cb = cb; self.cr = cr
    }

    func copy() -> CodecPicture { CodecPicture(y: y.copy(), cb: cb.copy(), cr: cr.copy()) }

    func assign(from other: CodecPicture) {
        y.assign(from: other.y); cb.assign(from: other.cb); cr.assign(from: other.cr)
    }

    var byteCount: Int { (y.width * y.height + 2 * cb.width * cb.height) * MemoryLayout<Float>.size }
}

/// Sizes of the coded picture: the visible capture, padded to whole
/// macroblocks (luma) and whole 8×8 blocks (color).
struct CodecGeometry: Equatable, Hashable {
    let width: Int
    let height: Int
    let chroma: ChromaSubsampling

    var lumaW: Int { (width + 15) / 16 * 16 }
    var lumaH: Int { (height + 15) / 16 * 16 }
    var sx: Int { chroma.factors.x }
    var sy: Int { chroma.factors.y }
    var chromaW: Int { (lumaW / sx + 7) / 8 * 8 }
    var chromaH: Int { (lumaH / sy + 7) / 8 * 8 }
    var mbCols: Int { lumaW / 16 }
    var mbRows: Int { lumaH / 16 }
    var mbCount: Int { mbCols * mbRows }
}

/// What a capture is coded as.
enum CodecFrameKind: Equatable {
    /// Every frame on its own (Motion JPEG, DV): no prediction at all.
    case intraOnly
    /// A keyframe in a predicted stream.
    case key
    /// A keyframe the decoder never receives (datamosh).
    case droppedKey
    /// A frame predicted from the previous one.
    case predicted
}

/// Motion vector of one macroblock, in luma pixels.
struct MotionVector: Equatable, Hashable {
    var dx: Int32 = 0
    var dy: Int32 = 0
}

/// The codec's state between frames.
final class CodecState {
    let geometry: CodecGeometry
    /// The encoder's reference: what a perfect decoder would hold.
    var encoder: CodecPicture?
    /// The decoder's reference: what this decoder actually holds.
    var decoder: CodecPicture?
    /// The previous frame's vectors (the motion search's first guess).
    var vectors: [MotionVector]
    /// The decoder's picture differs from the encoder's.
    var diverged = false

    init(geometry: CodecGeometry) {
        self.geometry = geometry
        vectors = Array(repeating: MotionVector(), count: geometry.mbCount)
    }

    func copy() -> CodecState {
        let s = CodecState(geometry: geometry)
        s.encoder = encoder?.copy()
        s.decoder = decoder === encoder ? s.encoder : decoder?.copy()
        s.vectors = vectors
        s.diverged = diverged
        return s
    }
}

enum DigitalCodec {

    // MARK: - quantization

    /// JPEG reference tables (ITU T.81 Annex K), natural order.
    static let lumaTable: [Float] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]
    static let chromaTable: [Float] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]

    /// The JPEG quality scale (percent of the reference tables) for the
    /// Quality control: 0 → JPEG quality 2, 1 → 95.
    static func tableScale(quality: Double) -> Float {
        let q = 2 + 93 * min(1, max(0, quality))
        return Float(q < 50 ? 5000 / q : 200 - 2 * q) / 100
    }

    /// Step sizes for one frame. Keyframes use the perceptual tables;
    /// differences use a flat step, as MPEG's non-intra matrix does.
    struct Steps {
        var luma: [Float]
        var chroma: [Float]
        var inter: Float

        init(quality: Double, squeeze: Float) {
            let s = tableScale(quality: quality) * squeeze
            luma = lumaTable.map { max(1, ($0 * s).rounded()) }
            chroma = chromaTable.map { max(1, ($0 * s).rounded()) }
            inter = max(1, 16 * s)
        }
    }

    // MARK: - DCT

    /// Orthonormal 8-point DCT-II basis, C[u * 8 + x].
    static let basis: [Float] = {
        var c = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            let a = u == 0 ? (1.0 / 8).squareRoot() : (2.0 / 8).squareRoot()
            for x in 0..<8 {
                c[u * 8 + x] = Float(a * cos(Double(2 * x + 1) * Double(u) * .pi / 16))
            }
        }
        return c
    }()

    /// out[u,v] = Σ C[u,x] C[v,y] in[x,y] — `input` row-major with `stride`.
    @inline(__always)
    static func forwardDCT(_ input: UnsafePointer<Float>, stride: Int,
                           _ out: UnsafeMutablePointer<Float>, _ tmp: UnsafeMutablePointer<Float>,
                           _ c: UnsafePointer<Float>) {
        // Rows: tmp[y, u] = Σx C[u,x] in[y,x]
        for y in 0..<8 {
            let row = input + y * stride
            for u in 0..<8 {
                let cu = c + u * 8
                var s: Float = 0
                for x in 0..<8 { s += cu[x] * row[x] }
                tmp[y * 8 + u] = s
            }
        }
        // Columns: out[v, u] = Σy C[v,y] tmp[y,u]
        for v in 0..<8 {
            let cv = c + v * 8
            for u in 0..<8 {
                var s: Float = 0
                for y in 0..<8 { s += cv[y] * tmp[y * 8 + u] }
                out[v * 8 + u] = s
            }
        }
    }

    /// The inverse: out[y,x] = Σ C[v,y] C[u,x] coef[v,u].
    @inline(__always)
    static func inverseDCT(_ coef: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>,
                           stride: Int, _ tmp: UnsafeMutablePointer<Float>,
                           _ c: UnsafePointer<Float>) {
        // Columns: tmp[y, u] = Σv C[v,y] coef[v,u]
        for y in 0..<8 {
            for u in 0..<8 {
                var s: Float = 0
                for v in 0..<8 { s += c[v * 8 + y] * coef[v * 8 + u] }
                tmp[y * 8 + u] = s
            }
        }
        // Rows: out[y, x] = Σu C[u,x] tmp[y,u]
        for y in 0..<8 {
            let row = out + y * stride
            for x in 0..<8 {
                var s: Float = 0
                for u in 0..<8 { s += c[u * 8 + x] * tmp[y * 8 + u] }
                row[x] = s
            }
        }
    }

    /// Run `body(row)` for every row of 8×8 tiles in a plane, across cores.
    /// Each row gets its own scratch (3 × 64 floats).
    static func forEachTileRow(_ rows: Int,
                               _ body: (Int, UnsafeMutablePointer<Float>) -> Void) {
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 192)
            defer { scratch.deallocate() }
            body(r, scratch)
        }
    }

    // MARK: - keyframes

    /// Code `source` with no prediction into `recon`.
    static func codeIntra(_ source: CodecPicture, into recon: CodecPicture, steps: Steps) {
        basis.withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for (i, (src, dst)) in zip(source.planes, recon.planes).enumerated() {
                let table = i == 0 ? steps.luma : steps.chroma
                table.withUnsafeBufferPointer { tp in
                    let t = tp.baseAddress!
                    let w = src.width
                    forEachTileRow(src.height / 8) { ty, scratch in
                        let block = scratch, coef = scratch + 64, tmp = scratch + 128
                        for tx in 0..<(w / 8) {
                            let origin = ty * 8 * w + tx * 8
                            for y in 0..<8 {
                                for x in 0..<8 { block[y * 8 + x] = src.data[origin + y * w + x] - 128 }
                            }
                            forwardDCT(block, stride: 8, coef, tmp, c)
                            for k in 0..<64 {
                                // JPEG rounding: to the nearest step.
                                coef[k] = (coef[k] / t[k]).rounded() * t[k]
                            }
                            inverseDCT(coef, block, stride: 8, tmp, c)
                            for y in 0..<8 {
                                for x in 0..<8 {
                                    dst.data[origin + y * w + x] = (block[y * 8 + x] + 128).rounded().clamped(0, 255)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - prediction

    /// Sum of absolute differences between the source macroblock at
    /// (bx, by) and the reference displaced by (dx, dy), giving up past
    /// `limit`.
    @inline(__always)
    static func sad(_ src: CodecPlane, _ ref: CodecPlane, bx: Int, by: Int,
                    dx: Int, dy: Int, limit: Float) -> Float {
        let w = src.width
        let rx = bx + dx, ry = by + dy
        var total: Float = 0
        if rx >= 0, ry >= 0, rx + 16 <= ref.width, ry + 16 <= ref.height {
            for y in 0..<16 {
                let s = src.data + (by + y) * w + bx
                let r = ref.data + (ry + y) * w + rx
                for x in 0..<16 { total += abs(s[x] - r[x]) }
                if total >= limit { return total }
            }
        } else {
            for y in 0..<16 {
                let s = src.data + (by + y) * w + bx
                for x in 0..<16 { total += abs(s[x] - ref.clamped(rx + x, ry + y)) }
                if total >= limit { return total }
            }
        }
        return total
    }

    static let searchRange = 24

    /// Motion search for every macroblock: the colocated vector from the
    /// last frame, the left neighbor's and zero as starting points, then a
    /// shrinking diamond. Rows run in parallel (each only uses its own left
    /// neighbor), so the result doesn't depend on the core count.
    /// Returns the vectors and the mean absolute prediction error.
    static func searchMotion(_ source: CodecPicture, reference: CodecPicture,
                             previous: [MotionVector], geometry g: CodecGeometry)
        -> (vectors: [MotionVector], error: Float) {
        var vectors = [MotionVector](repeating: MotionVector(), count: g.mbCount)
        var rowError = [Float](repeating: 0, count: g.mbRows)
        let src = source.y, ref = reference.y
        vectors.withUnsafeMutableBufferPointer { vp in
            rowError.withUnsafeMutableBufferPointer { ep in
                let out = vp.baseAddress!, err = ep.baseAddress!
                DispatchQueue.concurrentPerform(iterations: g.mbRows) { my in
                    var left = MotionVector()
                    var sum: Float = 0
                    for mx in 0..<g.mbCols {
                        let bx = mx * 16, by = my * 16
                        let r = searchRange
                        func cost(_ v: (Int, Int), _ limit: Float) -> Float {
                            guard abs(v.0) <= r, abs(v.1) <= r else { return .infinity }
                            // A small bias keeps still areas still.
                            let bias: Float = (v.0 == 0 && v.1 == 0) ? -48 : 0
                            return sad(src, ref, bx: bx, by: by, dx: v.0, dy: v.1, limit: limit - bias) + bias
                        }
                        var best = (0, 0)
                        var bestCost = cost(best, .infinity)
                        for cand in [previous[my * g.mbCols + mx], left] {
                            let v = (Int(cand.dx), Int(cand.dy))
                            if v == best { continue }
                            let cst = cost(v, bestCost)
                            if cst < bestCost { bestCost = cst; best = v }
                        }
                        var step = 8
                        while step >= 1 {
                            var moved = true
                            var guardCount = 0
                            while moved && guardCount < 8 {
                                moved = false
                                guardCount += 1
                                for d in [(step, 0), (-step, 0), (0, step), (0, -step)] {
                                    let v = (best.0 + d.0, best.1 + d.1)
                                    let cst = cost(v, bestCost)
                                    if cst < bestCost { bestCost = cst; best = v; moved = true }
                                }
                            }
                            step /= 2
                        }
                        let mv = MotionVector(dx: Int32(best.0), dy: Int32(best.1))
                        out[my * g.mbCols + mx] = mv
                        left = mv
                        sum += sad(src, ref, bx: bx, by: by, dx: best.0, dy: best.1, limit: .infinity)
                    }
                    err[my] = sum
                }
            }
        }
        let total = rowError.reduce(0, +)
        return (vectors, total / Float(g.lumaW * g.lumaH))
    }

    /// Fill `prediction` with `reference` moved by each macroblock's vector.
    static func compensate(_ reference: CodecPicture, vectors: [MotionVector],
                           geometry g: CodecGeometry, into prediction: CodecPicture) {
        for (i, (ref, dst)) in zip(reference.planes, prediction.planes).enumerated() {
            let fx = i == 0 ? 1 : g.sx, fy = i == 0 ? 1 : g.sy
            let bw = 16 / fx, bh = 16 / fy
            let w = dst.width
            DispatchQueue.concurrentPerform(iterations: g.mbRows) { my in
                for mx in 0..<g.mbCols {
                    let v = vectors[my * g.mbCols + mx]
                    let dx = Int((Float(v.dx) / Float(fx)).rounded())
                    let dy = Int((Float(v.dy) / Float(fy)).rounded())
                    let x0 = mx * bw, y0 = my * bh
                    for y in y0..<min(dst.height, y0 + bh) {
                        for x in x0..<min(w, x0 + bw) {
                            dst.data[y * w + x] = ref.clamped(x + dx, y + dy)
                        }
                    }
                }
            }
            // Color planes padded past the last macroblock follow the edge.
            if bw * g.mbCols < w || bh * g.mbRows < dst.height {
                for y in 0..<dst.height {
                    for x in 0..<w where x >= bw * g.mbCols || y >= bh * g.mbRows {
                        dst.data[y * w + x] = dst.clamped(min(x, bw * g.mbCols - 1), min(y, bh * g.mbRows - 1))
                    }
                }
            }
        }
    }

    /// Quantize the difference between `source` and `prediction`, writing
    /// the difference the decoder reconstructs into `residual`.
    static func codeResidual(_ source: CodecPicture, prediction: CodecPicture,
                             step: Float, into residual: CodecPicture) {
        basis.withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for (src, (pred, dst)) in zip(source.planes, zip(prediction.planes, residual.planes)) {
                let w = src.width
                forEachTileRow(src.height / 8) { ty, scratch in
                    let block = scratch, coef = scratch + 64, tmp = scratch + 128
                    for tx in 0..<(w / 8) {
                        let origin = ty * 8 * w + tx * 8
                        for y in 0..<8 {
                            for x in 0..<8 {
                                let i = origin + y * w + x
                                block[y * 8 + x] = src.data[i] - pred.data[i]
                            }
                        }
                        forwardDCT(block, stride: 8, coef, tmp, c)
                        var any = false
                        for k in 0..<64 {
                            // A dead zone, as encoders use: small changes
                            // round to nothing, so blocks stay stale.
                            let q = coef[k] / step
                            let level = q < 0 ? -(-q + 0.2).rounded(.down) : (q + 0.2).rounded(.down)
                            coef[k] = level * step
                            if level != 0 { any = true }
                        }
                        if any {
                            inverseDCT(coef, dst.data + origin, stride: w, tmp, c)
                        } else {
                            for y in 0..<8 {
                                (dst.data + origin + y * w).update(repeating: 0, count: 8)
                            }
                        }
                    }
                }
            }
        }
    }

    /// recon = clamp(round(prediction + residual)), skipping lost macroblocks'
    /// residual when `lost` is given.
    static func reconstruct(prediction: CodecPicture, residual: CodecPicture,
                            lost: [Bool]?, geometry g: CodecGeometry, into recon: CodecPicture) {
        for (i, (pred, (res, dst))) in zip(prediction.planes, zip(residual.planes, recon.planes)).enumerated() {
            let fx = i == 0 ? 1 : g.sx, fy = i == 0 ? 1 : g.sy
            let w = dst.width
            DispatchQueue.concurrentPerform(iterations: dst.height) { y in
                let my = min(g.mbRows - 1, y * fy / 16)
                for x in 0..<w {
                    let k = y * w + x
                    var v = pred.data[k]
                    let mx = min(g.mbCols - 1, x * fx / 16)
                    if lost?[my * g.mbCols + mx] != true { v += res.data[k] }
                    dst.data[k] = v.rounded().clamped(0, 255)
                }
            }
        }
    }

    // MARK: - errors

    /// Which macroblocks frame `index` loses: runs of blocks (a lost packet
    /// or a damaged stretch of tape), mostly short, sometimes a row or more.
    static func lostBlocks(amount: Double, index: Int, geometry g: CodecGeometry) -> [Bool]? {
        guard amount > 0 else { return nil }
        var lost = [Bool](repeating: false, count: g.mbCount)
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9 ^ 0x10C5)
        let meanRun = 1 + Double(g.mbCols) * 2 / 3
        let start = min(1, amount * 0.3 / meanRun)
        var i = 0
        var any = false
        while i < g.mbCount {
            if rng.unit() < start {
                let u = rng.unit()
                let run = 1 + Int(u * u * Double(2 * g.mbCols))
                for j in i..<min(g.mbCount, i + run) { lost[j] = true }
                any = true
                i += run
            } else {
                i += 1
            }
        }
        return any ? lost : nil
    }

    /// Whether the keyframe numbered `keyIndex` is thrown away.
    static func dropsKey(_ keyIndex: Int, amount: Double) -> Bool {
        guard amount > 0, keyIndex > 0 else { return false }
        var rng = SplitMix(seed: UInt64(keyIndex) &* 0xD1B5_4A32_D192_ED03 ^ 0xDA7A)
        return rng.unit() < amount
    }

    // MARK: - complexity (the fixed-bitrate squeeze)

    /// How much a fixed bitrate coarsens this frame's quantizer: in
    /// proportion to how much there is to code, against a typical frame.
    static func squeeze(complexity: Float, typical: Float, strictness: Double) -> Float {
        guard strictness > 0 else { return 1 }
        let ratio = max(0.05, complexity / typical)
        return min(6, max(0.5, pow(ratio, Float(strictness))))
    }

    /// Mean absolute gradient of the luma — how much detail a keyframe holds.
    static func detail(_ p: CodecPicture, geometry g: CodecGeometry) -> Float {
        let w = p.y.width
        var rows = [Float](repeating: 0, count: g.height)
        rows.withUnsafeMutableBufferPointer { rp in
            let out = rp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: g.height) { y in
                var s: Float = 0
                let row = p.y.data + y * w
                let below = p.y.data + min(g.height - 1, y + 1) * w
                for x in 0..<(g.width - 1) {
                    s += abs(row[x + 1] - row[x]) + abs(below[x] - row[x])
                }
                out[y] = s
            }
        }
        return rows.reduce(0, +) / Float(g.width * g.height)
    }

    // MARK: - one frame

    /// Settings that act on one frame.
    struct FrameSettings {
        var quality: Double
        var fixedBitrate: Double
        var dataLoss: Double
    }

    /// Code `source` as `kind`, advancing `state`. Returns the picture the
    /// decoder shows (its reference — not a copy; read it before the next
    /// step) and the quantizer step for the deblocking filter.
    @discardableResult
    static func step(_ state: CodecState, source: CodecPicture, kind: CodecFrameKind,
                     index: Int, settings s: FrameSettings) -> (picture: CodecPicture, step: Float) {
        let g = state.geometry
        let lost = lostBlocks(amount: s.dataLoss, index: index, geometry: g)

        switch kind {
        case .intraOnly, .key, .droppedKey:
            let squeeze = Self.squeeze(complexity: detail(source, geometry: g), typical: 14,
                                       strictness: s.fixedBitrate)
            let steps = Steps(quality: s.quality, squeeze: squeeze)
            let previous = state.encoder
            let recon = CodecPicture(geometry: g)
            codeIntra(source, into: recon, steps: steps)
            state.encoder = recon
            state.vectors = Array(repeating: MotionVector(), count: g.mbCount)
            switch kind {
            case .intraOnly:
                // Each frame stands alone; a lost block is patched from the
                // previous frame (DV's error concealment) and the damage is
                // gone by the next one.
                if let lost, let previous {
                    let shown = recon.copy()
                    copyBlocks(from: previous, into: shown, where: lost, geometry: g)
                    state.decoder = shown
                    state.diverged = true
                } else {
                    state.decoder = recon
                    state.diverged = false
                }
            case .key:
                // Keyframes arrive whole (streams protect them).
                state.decoder = recon
                state.diverged = false
            default:
                // Never arrives: the decoder holds its old picture.
                if state.decoder == nil { state.decoder = recon.copy() }
                state.diverged = state.decoder !== recon
            }
            return (state.decoder!, steps.inter)

        case .predicted:
            guard let encRef = state.encoder else {
                return step(state, source: source, kind: .key, index: index, settings: s)
            }
            let motion = searchMotion(source, reference: encRef, previous: state.vectors, geometry: g)
            let squeeze = Self.squeeze(complexity: motion.error, typical: 3, strictness: s.fixedBitrate)
            let steps = Steps(quality: s.quality, squeeze: squeeze)
            let prediction = CodecPicture(geometry: g)
            compensate(encRef, vectors: motion.vectors, geometry: g, into: prediction)
            let residual = CodecPicture(geometry: g)
            codeResidual(source, prediction: prediction, step: steps.inter, into: residual)
            let encRecon = CodecPicture(geometry: g)
            reconstruct(prediction: prediction, residual: residual, lost: nil, geometry: g, into: encRecon)

            if !state.diverged && lost == nil {
                state.decoder = encRecon
            } else {
                // The decoder moves its own picture: the encoder's vectors,
                // except where they were lost — there it guesses from the
                // block above, and gets no difference at all.
                var vectors = motion.vectors
                if let lost {
                    for i in 0..<g.mbCount where lost[i] {
                        let above = i - g.mbCols
                        vectors[i] = above >= 0 && !lost[above] ? vectors[above] : MotionVector()
                    }
                }
                let decRef = state.decoder ?? encRef
                let decPrediction = CodecPicture(geometry: g)
                compensate(decRef, vectors: vectors, geometry: g, into: decPrediction)
                let decRecon = CodecPicture(geometry: g)
                reconstruct(prediction: decPrediction, residual: residual, lost: lost,
                            geometry: g, into: decRecon)
                state.decoder = decRecon
                state.diverged = true
            }
            state.encoder = encRecon
            state.vectors = motion.vectors
            return (state.decoder!, steps.inter)
        }
    }

    /// Copy whole macroblocks of `source` over `target` where `mask` is set.
    static func copyBlocks(from source: CodecPicture, into target: CodecPicture,
                           where mask: [Bool], geometry g: CodecGeometry) {
        for (i, (src, dst)) in zip(source.planes, target.planes).enumerated() {
            let fx = i == 0 ? 1 : g.sx, fy = i == 0 ? 1 : g.sy
            let w = dst.width
            for y in 0..<dst.height {
                let my = min(g.mbRows - 1, y * fy / 16)
                for x in 0..<w where mask[my * g.mbCols + min(g.mbCols - 1, x * fx / 16)] {
                    dst.data[y * w + x] = src.data[y * w + x]
                }
            }
        }
    }

    // MARK: - deblocking (the decoder's display filter)

    /// Smooth steps across 8×8 block edges that are small enough to be
    /// quantization rather than picture edges, as H.264's loop filter does.
    static func deblock(_ p: CodecPicture, strength: Double, step: Float) {
        guard strength > 0 else { return }
        let w8 = Float(strength)
        let threshold = Float(strength) * (4 + 0.9 * step)
        for plane in p.planes {
            let w = plane.width, h = plane.height
            func filter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
                // a, b | c, d across the edge.
                let p1 = plane.data[a], p0 = plane.data[b], q0 = plane.data[c], q1 = plane.data[d]
                let delta = q0 - p0
                guard abs(delta) < threshold, abs(p1 - p0) < threshold / 2, abs(q1 - q0) < threshold / 2 else { return }
                plane.data[b] = p0 + delta * 0.375 * w8
                plane.data[c] = q0 - delta * 0.375 * w8
                plane.data[a] = p1 + delta * 0.125 * w8
                plane.data[d] = q1 - delta * 0.125 * w8
            }
            for y in 0..<h {
                var x = 8
                while x < w {
                    let k = y * w + x
                    filter(k - 2, k - 1, k, k + 1)
                    x += 8
                }
            }
            var y = 8
            while y < h {
                for x in 0..<w {
                    let k = y * w + x
                    filter(k - 2 * w, k - w, k, k + w)
                }
                y += 8
            }
        }
    }
}

// MARK: - small helpers

extension Float {
    @inline(__always) func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, self)) }
}

/// SplitMix64: a small, fast, seedable generator for deterministic noise
/// and error patterns.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
