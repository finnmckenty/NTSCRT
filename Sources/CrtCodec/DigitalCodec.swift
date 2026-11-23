import Foundation

// The Digital video stage's codec: a small, real block-transform video codec
// in the MPEG/H.263/DV family, run on the CPU at the capture resolution.
//
// - Pictures are Y′CbCr (BT.601) with subsampled color, coded in 8×8 DCT
//   blocks against the JPEG reference quantization tables.
// - Keyframes are coded alone; between them each 16×16 macroblock is
//   predicted from the previous picture by a motion vector, and only the
//   quantized difference is sent.
// - The Block size control scales that whole structure: 4×4 or 16×16
//   transforms, with macroblocks always twice the transform's size.
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
/// macroblocks (luma) and whole transform blocks (color).
struct CodecGeometry: Equatable, Hashable {
    let width: Int
    let height: Int
    let chroma: ChromaSubsampling
    /// The transform's size: 8 (the family's own), 4 or 16.
    let block: Int

    init(width: Int, height: Int, chroma: ChromaSubsampling, block: Int = 8) {
        self.width = width; self.height = height; self.chroma = chroma; self.block = block
    }

    /// A macroblock (the unit of motion and of lost data): two blocks
    /// each way.
    var mb: Int { block * 2 }
    var lumaW: Int { (width + mb - 1) / mb * mb }
    var lumaH: Int { (height + mb - 1) / mb * mb }
    var sx: Int { chroma.factors.x }
    var sy: Int { chroma.factors.y }
    var chromaW: Int { (lumaW / sx + block - 1) / block * block }
    var chromaH: Int { (lumaH / sy + block - 1) / block * block }
    var mbCols: Int { lumaW / mb }
    var mbRows: Int { lumaH / mb }
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
    /// Bits waiting in the encoder's buffer (the Bitrate limit): what the
    /// frames since the last keyframe spent beyond their share.
    var bufferFill: Double = 0
    /// The quantizer step of the picture the decoder shows (it stays the
    /// same picture through frames the encoder skips).
    var shownStep: Float = 0

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
        s.bufferFill = bufferFill
        s.shownStep = shownStep
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

    /// The quantizer scale (a multiple of the reference tables) for the
    /// Quality control: 25× at 0 (JPEG quality 2) to 0.1× at 1 (JPEG 95).
    /// Measured damage grows with the square root of the step (mean error
    /// ∝ scale^0.51 across the whole range), so the square root is what
    /// runs linearly: every step of the slider changes the damage by the
    /// same amount. JPEG's own quality number (used before 0.19) spent
    /// two thirds of the damage in its bottom tenth.
    static let scaleRoots: (worst: Double, best: Double) = (5, 0.1.squareRoot())
    static func tableScale(quality: Double) -> Float {
        let q = min(1, max(0, quality))
        let r = scaleRoots.worst + (scaleRoots.best - scaleRoots.worst) * q
        return Float(r * r)
    }

    /// A Quality value from before 0.19 (JPEG quality 2 + 93u), as today's
    /// slider value giving the same quantizer.
    static func qualityFromJPEGScale(_ old: Double) -> Double {
        let q = 2 + 93 * min(1, max(0, old))
        let scale = (q < 50 ? 5000 / q : 200 - 2 * q) / 100
        return min(1, max(0, (scaleRoots.worst - scale.squareRoot()) / (scaleRoots.worst - scaleRoots.best)))
    }

    /// Step sizes for one frame. Keyframes use the perceptual tables;
    /// differences use a flat step, as MPEG's non-intra matrix does.
    struct Steps {
        var luma: [Float]
        var chroma: [Float]
        var inter: Float
        /// The transform's size the tables are for.
        let block: Int
        /// The multiple of the reference tables.
        let scale: Float

        init(quality: Double, squeeze: Float, block: Int = 8) {
            self.init(scale: tableScale(quality: quality) * squeeze, block: block)
        }

        init(scale s: Float, block: Int = 8) {
            self.block = block
            scale = s
            luma = table(lumaTable, block: block).map { max(1, ($0 * s).rounded()) }
            chroma = table(chromaTable, block: block).map { max(1, ($0 * s).rounded()) }
            inter = max(1, 16 * s * blockGain(block))
        }
    }

    /// A reference table for an n×n transform: each coefficient takes the
    /// step of the 8×8 one at the same spatial frequency (between two, for
    /// 16×16), times `blockGain`.
    static func table(_ base: [Float], block n: Int) -> [Float] {
        guard n != 8 else { return base }
        let gain = blockGain(n)
        var out = [Float](repeating: 0, count: n * n)
        for v in 0..<n {
            for u in 0..<n {
                let fu = Float(u) * 8 / Float(n), fv = Float(v) * 8 / Float(n)
                let u0 = min(7, Int(fu)), v0 = min(7, Int(fv))
                let u1 = min(7, u0 + 1), v1 = min(7, v0 + 1)
                let tu = fu - Float(u0), tv = fv - Float(v0)
                let top = base[v0 * 8 + u0] + (base[v0 * 8 + u1] - base[v0 * 8 + u0]) * tu
                let bottom = base[v1 * 8 + u0] + (base[v1 * 8 + u1] - base[v1 * 8 + u0]) * tu
                out[v * n + u] = (top + (bottom - top) * tv) * gain
            }
        }
        return out
    }

    /// How the steps grow with the transform's size. An orthonormal
    /// transform's coefficients grow with its size (a flat block's average
    /// is n times its level), so the same step is finer in a big block and
    /// coarser in a small one; this keeps the damage at one Quality about
    /// the same whatever the block.
    static func blockGain(_ n: Int) -> Float { pow(Float(n) / 8, blockGainPower) }
    static let blockGainPower: Float = 0.5

    // MARK: - DCT

    /// Orthonormal 8-point DCT-II basis, C[u * 8 + x].
    static let basis: [Float] = makeBasis(8)
    static let basis4: [Float] = makeBasis(4)
    static let basis16: [Float] = makeBasis(16)

    /// The n-point basis, C[u * n + x].
    static func basis(_ n: Int) -> [Float] { n == 4 ? basis4 : (n == 16 ? basis16 : basis) }

    static func makeBasis(_ n: Int) -> [Float] {
        var c = [Float](repeating: 0, count: n * n)
        for u in 0..<n {
            let a = u == 0 ? (1.0 / Double(n)).squareRoot() : (2.0 / Double(n)).squareRoot()
            for x in 0..<n {
                c[u * n + x] = Float(a * cos(Double(2 * x + 1) * Double(u) * .pi / Double(2 * n)))
            }
        }
        return c
    }

    /// out[u,v] = Σ C[u,x] C[v,y] in[x,y] — `input` row-major with `stride`.
    @inline(__always)
    static func forwardDCT(_ input: UnsafePointer<Float>, stride: Int,
                           _ out: UnsafeMutablePointer<Float>, _ tmp: UnsafeMutablePointer<Float>,
                           _ c: UnsafePointer<Float>, n: Int = 8) {
        // Rows: tmp[y, u] = Σx C[u,x] in[y,x]
        for y in 0..<n {
            let row = input + y * stride
            for u in 0..<n {
                let cu = c + u * n
                var s: Float = 0
                for x in 0..<n { s += cu[x] * row[x] }
                tmp[y * n + u] = s
            }
        }
        // Columns: out[v, u] = Σy C[v,y] tmp[y,u]
        for v in 0..<n {
            let cv = c + v * n
            for u in 0..<n {
                var s: Float = 0
                for y in 0..<n { s += cv[y] * tmp[y * n + u] }
                out[v * n + u] = s
            }
        }
    }

    /// The inverse: out[y,x] = Σ C[v,y] C[u,x] coef[v,u].
    @inline(__always)
    static func inverseDCT(_ coef: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>,
                           stride: Int, _ tmp: UnsafeMutablePointer<Float>,
                           _ c: UnsafePointer<Float>, n: Int = 8) {
        // Columns: tmp[y, u] = Σv C[v,y] coef[v,u]
        for y in 0..<n {
            for u in 0..<n {
                var s: Float = 0
                for v in 0..<n { s += c[v * n + y] * coef[v * n + u] }
                tmp[y * n + u] = s
            }
        }
        // Rows: out[y, x] = Σu C[u,x] tmp[y,u]
        for y in 0..<n {
            let row = out + y * stride
            for x in 0..<n {
                var s: Float = 0
                for u in 0..<n { s += c[u * n + x] * tmp[y * n + u] }
                row[x] = s
            }
        }
    }

    /// Run `body(row)` for every row of n×n tiles in a plane, across cores.
    /// Each row gets its own scratch (3 × n² floats).
    static func forEachTileRow(_ rows: Int, block n: Int = 8,
                               _ body: (Int, UnsafeMutablePointer<Float>) -> Void) {
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 3 * n * n)
            defer { scratch.deallocate() }
            body(r, scratch)
        }
    }

    // MARK: - keyframes

    /// Code `source` with no prediction into `recon`.
    static func codeIntra(_ source: CodecPicture, into recon: CodecPicture, steps: Steps) {
        let n = steps.block, nn = n * n
        basis(n).withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for (i, (src, dst)) in zip(source.planes, recon.planes).enumerated() {
                let table = i == 0 ? steps.luma : steps.chroma
                table.withUnsafeBufferPointer { tp in
                    let t = tp.baseAddress!
                    let w = src.width
                    forEachTileRow(src.height / n, block: n) { ty, scratch in
                        let block = scratch, coef = scratch + nn, tmp = scratch + 2 * nn
                        for tx in 0..<(w / n) {
                            let origin = ty * n * w + tx * n
                            for y in 0..<n {
                                for x in 0..<n { block[y * n + x] = src.data[origin + y * w + x] - 128 }
                            }
                            // (The usual size by its number, so the
                            // compiler unrolls it: a little faster.)
                            if n == 8 { forwardDCT(block, stride: 8, coef, tmp, c, n: 8) }
                            else { forwardDCT(block, stride: n, coef, tmp, c, n: n) }
                            for k in 0..<nn {
                                // JPEG rounding: to the nearest step.
                                coef[k] = (coef[k] / t[k]).rounded() * t[k]
                            }
                            if n == 8 { inverseDCT(coef, block, stride: 8, tmp, c, n: 8) }
                            else { inverseDCT(coef, block, stride: n, tmp, c, n: n) }
                            for y in 0..<n {
                                for x in 0..<n {
                                    dst.data[origin + y * w + x] = (block[y * n + x] + 128).rounded().clamped(0, 255)
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
                    dx: Int, dy: Int, limit: Float, size m: Int = 16) -> Float {
        let w = src.width
        let rx = bx + dx, ry = by + dy
        var total: Float = 0
        if rx >= 0, ry >= 0, rx + m <= ref.width, ry + m <= ref.height {
            for y in 0..<m {
                let s = src.data + (by + y) * w + bx
                let r = ref.data + (ry + y) * w + rx
                for x in 0..<m { total += abs(s[x] - r[x]) }
                if total >= limit { return total }
            }
        } else {
            for y in 0..<m {
                let s = src.data + (by + y) * w + bx
                for x in 0..<m { total += abs(s[x] - ref.clamped(rx + x, ry + y)) }
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
        let m = g.mb
        // A small bias keeps still areas still (48 for a 16×16 block).
        let stillBias = Float(-48 * m * m / 256)
        vectors.withUnsafeMutableBufferPointer { vp in
            rowError.withUnsafeMutableBufferPointer { ep in
                let out = vp.baseAddress!, err = ep.baseAddress!
                DispatchQueue.concurrentPerform(iterations: g.mbRows) { my in
                    var left = MotionVector()
                    var sum: Float = 0
                    for mx in 0..<g.mbCols {
                        let bx = mx * m, by = my * m
                        let r = searchRange
                        func cost(_ v: (Int, Int), _ limit: Float) -> Float {
                            guard abs(v.0) <= r, abs(v.1) <= r else { return .infinity }
                            let bias: Float = (v.0 == 0 && v.1 == 0) ? stillBias : 0
                            return sad(src, ref, bx: bx, by: by, dx: v.0, dy: v.1, limit: limit - bias, size: m) + bias
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
                        sum += sad(src, ref, bx: bx, by: by, dx: best.0, dy: best.1, limit: .infinity, size: m)
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
            let bw = g.mb / fx, bh = g.mb / fy
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
                             step: Float, block n: Int = 8, into residual: CodecPicture) {
        let nn = n * n
        basis(n).withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for (src, (pred, dst)) in zip(source.planes, zip(prediction.planes, residual.planes)) {
                let w = src.width
                forEachTileRow(src.height / n, block: n) { ty, scratch in
                    let block = scratch, coef = scratch + nn, tmp = scratch + 2 * nn
                    for tx in 0..<(w / n) {
                        let origin = ty * n * w + tx * n
                        for y in 0..<n {
                            for x in 0..<n {
                                let i = origin + y * w + x
                                block[y * n + x] = src.data[i] - pred.data[i]
                            }
                        }
                        if n == 8 { forwardDCT(block, stride: 8, coef, tmp, c, n: 8) }
                        else { forwardDCT(block, stride: n, coef, tmp, c, n: n) }
                        var any = false
                        for k in 0..<nn {
                            // A dead zone, as encoders use: small changes
                            // round to nothing, so blocks stay stale.
                            let q = coef[k] / step
                            let level = q < 0 ? -(-q + 0.2).rounded(.down) : (q + 0.2).rounded(.down)
                            coef[k] = level * step
                            if level != 0 { any = true }
                        }
                        if any {
                            if n == 8 { inverseDCT(coef, dst.data + origin, stride: w, tmp, c, n: 8) }
                            else { inverseDCT(coef, dst.data + origin, stride: w, tmp, c, n: n) }
                        } else {
                            for y in 0..<n {
                                (dst.data + origin + y * w).update(repeating: 0, count: n)
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
            let m = g.mb
            DispatchQueue.concurrentPerform(iterations: dst.height) { y in
                let my = min(g.mbRows - 1, y * fy / m)
                for x in 0..<w {
                    let k = y * w + x
                    var v = pred.data[k]
                    let mx = min(g.mbCols - 1, x * fx / m)
                    if lost?[my * g.mbCols + mx] != true { v += res.data[k] }
                    dst.data[k] = v.rounded().clamped(0, 255)
                }
            }
        }
    }

    // MARK: - errors

    /// Where Data loss falls (the Loss pattern control).
    enum LossPattern: Int {
        /// Runs of blocks in reading order: a stream's lost packets.
        case packets = 0
        /// DV tape dropouts: each track's blocks lie scattered over five
        /// rectangles of the picture.
        case dvTape
        /// One of a DV deck's two heads clogged: every other track.
        case cloggedHead
    }

    /// Which macroblocks frame `index` loses: runs of blocks (a lost packet
    /// or a damaged stretch of tape), mostly short, sometimes a row or more.
    static func lostBlocks(amount: Double, index: Int, geometry g: CodecGeometry,
                           pattern: LossPattern = .packets) -> [Bool]? {
        guard amount > 0 else { return nil }
        switch pattern {
        case .packets: break
        case .dvTape: return dvTapeLoss(amount: amount, index: index, geometry: g)
        case .cloggedHead: return cloggedHeadLoss(amount: amount, index: index, geometry: g)
        }
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

    // DV's layout (SMPTE 314M, 525/60): the picture is 50 superblocks, 5
    // across and 10 down, each 27 macroblocks. A frame is 10 tracks on
    // the tape. Track i holds, block by block in step, the superblocks at
    // rows i+2, i+6, i+8, i and i+4 of columns 2, 1, 3, 0 and 4: a stretch
    // of one track is the same stretch of five rectangles spread over the
    // picture. Row i's superblocks all lie on tracks of i's parity, so a
    // deck's two heads (alternate tracks) each own every other band.
    static let dvRows = 10, dvColumns = 5
    /// On tape, a patch holds the last picture the decoder showed, which
    /// could reach back without limit. Every this many captures the tape
    /// reads clean (a clogged head clears for a moment, as they do), so a
    /// frame's picture never depends on more than that much before it.
    static let tapeRefresh = 24
    static let dvTrackOrder: [(rowOffset: Int, column: Int)] = [(2, 2), (6, 1), (8, 3), (0, 0), (4, 4)]

    /// The macroblocks of superblock (row, column), in the order DV writes
    /// them: down the first column of blocks, up the next, and so on.
    static func dvSuperblock(row: Int, column: Int, geometry g: CodecGeometry) -> [Int] {
        let rows = min(dvRows, g.mbRows), cols = min(dvColumns, g.mbCols)
        guard row < rows, column < cols else { return [] }
        let y0 = row * g.mbRows / rows, y1 = (row + 1) * g.mbRows / rows
        let x0 = column * g.mbCols / cols, x1 = (column + 1) * g.mbCols / cols
        var out: [Int] = []
        out.reserveCapacity((y1 - y0) * (x1 - x0))
        for x in x0..<x1 {
            let ys = (x - x0) % 2 == 0 ? Array(y0..<y1) : Array((y0..<y1).reversed())
            for y in ys { out.append(y * g.mbCols + x) }
        }
        return out
    }

    /// Mark the stretch [from, to) (fractions of a track) of track `track`.
    static func loseDVStretch(track: Int, from: Double, to: Double, geometry g: CodecGeometry,
                              into lost: inout [Bool]) {
        let rows = min(dvRows, g.mbRows)
        for (offset, column) in dvTrackOrder {
            let blocks = dvSuperblock(row: (track + offset * rows / dvRows) % rows, column: column, geometry: g)
            guard !blocks.isEmpty else { continue }
            let a = Int((from * Double(blocks.count)).rounded(.down))
            let b = max(a + 1, Int((to * Double(blocks.count)).rounded(.up)))
            for k in a..<min(blocks.count, b) { lost[blocks[k]] = true }
        }
    }

    /// DV tape dropouts: short stretches of single tracks, now and then a
    /// whole track, and scratches along the tape, which cross every track
    /// at the same place and stay for a while.
    static func dvTapeLoss(amount: Double, index: Int, geometry g: CodecGeometry) -> [Bool]? {
        guard index % tapeRefresh != 0 else { return nil }
        var lost = [Bool](repeating: false, count: g.mbCount)
        var any = false
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9 ^ 0xD7A9E)
        for track in 0..<dvRows where rng.unit() < amount * 0.6 {
            let u = rng.unit()
            if u > 1 - 0.25 * amount {
                loseDVStretch(track: track, from: 0, to: 1, geometry: g, into: &lost)
            } else {
                let start = rng.unit(), v = rng.unit()
                loseDVStretch(track: track, from: start, to: min(1, start + 0.04 + 0.5 * v * v * amount),
                              geometry: g, into: &lost)
            }
            any = true
        }
        // A scratch: the same few blocks of every track, for about half a
        // second of tape.
        var slow = SplitMix(seed: UInt64(bitPattern: Int64(index / 14)) &* 0xC2B2_AE3D ^ 0x5C4A7C)
        if slow.unit() < amount * 0.7 {
            let start = slow.unit() * 0.94, width = 0.04 + 0.1 * slow.unit() * amount
            for track in 0..<dvRows {
                loseDVStretch(track: track, from: start, to: start + width, geometry: g, into: &lost)
            }
            any = true
        }
        return any ? lost : nil
    }

    /// A clogged head: the odd tracks read badly, more or less so as the
    /// dirt shifts. Their bands lose runs of blocks; badly clogged, all.
    static func cloggedHeadLoss(amount: Double, index: Int, geometry g: CodecGeometry) -> [Bool]? {
        guard index % tapeRefresh != 0 else { return nil }
        var lost = [Bool](repeating: false, count: g.mbCount)
        var any = false
        // How bad it is right now: drifting over a second or so.
        func level(_ step: Int) -> Double {
            var r = SplitMix(seed: UInt64(bitPattern: Int64(step)) &* 0xA24B_AED4 ^ 0xC106)
            return r.unit()
        }
        let t = Double(index) / 24
        let i0 = Int(t.rounded(.down)), f = t - Double(i0)
        let drift = level(i0) + (level(i0 + 1) - level(i0)) * f * f * (3 - 2 * f)
        let clog = min(1, amount * (0.7 + 0.6 * drift))
        let chance = min(1, clog * clog * 1.6)
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9 ^ 0xC106_6ED)
        let rows = min(dvRows, g.mbRows), cols = min(dvColumns, g.mbCols)
        for row in stride(from: 1, to: rows, by: 2) {
            for column in 0..<cols {
                let blocks = dvSuperblock(row: row, column: column, geometry: g)
                var k = 0
                while k < blocks.count {
                    let run = 1 + Int(rng.unit() * 6)
                    if rng.unit() < chance {
                        for j in k..<min(blocks.count, k + run) { lost[blocks[j]] = true }
                        any = true
                    }
                    k += run
                }
            }
        }
        return any ? lost : nil
    }

    // MARK: - concealment (what the decoder puts where data was lost)

    enum Concealment: Int {
        /// The same place in the last picture (or, between keyframes, the
        /// last picture moved by a guessed vector).
        case lastPicture = 0
        /// Nothing: flat gray.
        case gray
        /// Nothing: an all-zero picture, which is green.
        case green
        /// The row of pixels above the gap, repeated down through it.
        case stretched
    }

    /// Fill the lost macroblocks of `target` (modes other than the last
    /// picture, which the caller has already put there). A stretch from a
    /// lost block above carries on down; at the top edge the patch stays.
    static func conceal(_ target: CodecPicture, lost: [Bool], mode: Concealment, geometry g: CodecGeometry) {
        guard mode != .lastPicture else { return }
        for (i, plane) in target.planes.enumerated() {
            let fx = i == 0 ? 1 : g.sx, fy = i == 0 ? 1 : g.sy
            let bw = g.mb / fx, bh = g.mb / fy
            let w = plane.width
            let fill: Float = mode == .gray ? 128 : 0
            for my in 0..<g.mbRows {
                for mx in 0..<g.mbCols where lost[my * g.mbCols + mx] {
                    let x0 = mx * bw, y0 = my * bh
                    let x1 = min(w, x0 + bw), y1 = min(plane.height, y0 + bh)
                    guard x0 < x1, y0 < y1 else { continue }
                    switch mode {
                    case .stretched:
                        guard y0 > 0 else { continue }
                        for y in y0..<y1 {
                            (plane.data + y * w + x0).update(from: plane.data + (y0 - 1) * w + x0, count: x1 - x0)
                        }
                    default:
                        for y in y0..<y1 { (plane.data + y * w + x0).update(repeating: fill, count: x1 - x0) }
                    }
                }
            }
        }
    }

    // MARK: - bit errors (data that arrives damaged)

    /// One piece of damage, in the terms of the coded stream. Each is what
    /// one wrong bit does to a block codec's data: applied to the decoded
    /// picture, which by the transform's linearity is the same as decoding
    /// the damaged coefficients.
    enum BitError {
        /// A block's coefficient (u across, v down) off by `amount`: the
        /// block shows that cosine pattern. `tile` is the tile within the
        /// plane.
        case coefficient(plane: Int, tileX: Int, tileY: Int, u: Int, v: Int, amount: Float)
        /// A block's average off by `amount`. Averages are sent as the
        /// difference from the block before, so every block after it in the
        /// row is off too — or, where nothing resets the chain, the rest of
        /// the picture (`toEnd`).
        case average(plane: Int, mbX: Int, mbY: Int, amount: Float, toEnd: Bool)
        /// The decoder losing its place: the rest of the row's blocks land
        /// `by` macroblocks along.
        case displaced(mbX: Int, mbY: Int, by: Int)
    }

    /// The damage frame `index` takes.
    static func bitErrors(amount: Double, index: Int, geometry g: CodecGeometry) -> [BitError] {
        guard amount > 0 else { return [] }
        var out: [BitError] = []
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(index)) &* 0x8CB9_2BA7 ^ 0xB17E_44)
        let chance = 0.035 * pow(min(1, amount), 1.3)
        for my in 0..<g.mbRows {
            for mx in 0..<g.mbCols where rng.unit() < chance {
                let kind = rng.unit()
                if kind < 0.45 {
                    // A short burst of wrong coefficients.
                    let plane = [0, 0, 0, 0, 0, 0, 1, 2][Int(rng.unit() * 8)]
                    // The macroblock's first tile in that plane (luma has
                    // two rows of them).
                    let fx = plane == 0 ? 1 : g.sx, fy = plane == 0 ? 1 : g.sy
                    let tileX = mx * g.mb / fx / g.block
                    let tileY = my * g.mb / fy / g.block + (plane == 0 ? Int(rng.unit() * 2) : 0)
                    let count = 1 + Int(rng.unit() * rng.unit() * 5)
                    for n in 0..<count {
                        let a = rng.unit(), b = rng.unit()
                        let u = Int(a * a * Double(g.block)), v = Int(b * b * Double(g.block))
                        let size = Float(300 + 700 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1)
                        out.append(.coefficient(plane: plane, tileX: tileX + n, tileY: tileY,
                                                u: u, v: (u == 0 && v == 0) ? 1 : v, amount: size))
                    }
                } else if kind < 0.8 {
                    let plane = [0, 0, 1, 2][Int(rng.unit() * 4)]
                    let size = Float(15 + 75 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1)
                    out.append(.average(plane: plane, mbX: mx, mbY: my, amount: size, toEnd: rng.unit() < 0.05))
                } else {
                    out.append(.displaced(mbX: mx, mbY: my, by: 1 + Int(rng.unit() * 3)))
                }
            }
        }
        return out
    }

    /// Apply `errors` to a decoded picture, in place.
    static func damage(_ p: CodecPicture, with errors: [BitError], geometry g: CodecGeometry) {
        let planes = p.planes
        let n = g.block, basis = Self.basis(n)
        // (A wrong coefficient is as visible whatever the block: a bigger
        // transform spreads the same value over more pixels.)
        let gain = Float(n) / 8
        for error in errors {
            switch error {
            case let .coefficient(pl, tx, ty, u, v, amount):
                let plane = planes[pl]
                guard tx * n + n <= plane.width, ty * n + n <= plane.height else { continue }
                for y in 0..<n {
                    let cv = basis[v * n + y] * amount * gain
                    let row = plane.data + (ty * n + y) * plane.width + tx * n
                    for x in 0..<n { row[x] = (row[x] + cv * basis[u * n + x]).rounded().clamped(0, 255) }
                }
            case let .average(pl, mx, my, amount, toEnd):
                let plane = planes[pl]
                let fx = pl == 0 ? 1 : g.sx, fy = pl == 0 ? 1 : g.sy
                let bw = g.mb / fx, bh = g.mb / fy
                let rows = toEnd ? my..<g.mbRows : my..<(my + 1)
                for r in rows {
                    let x0 = r == my ? mx * bw : 0
                    for y in (r * bh)..<min(plane.height, (r + 1) * bh) {
                        let row = plane.data + y * plane.width
                        for x in x0..<plane.width { row[x] = (row[x] + amount).clamped(0, 255) }
                    }
                }
            case let .displaced(mx, my, by):
                for (pl, plane) in planes.enumerated() {
                    let fx = pl == 0 ? 1 : g.sx, fy = pl == 0 ? 1 : g.sy
                    let bw = g.mb / fx, bh = g.mb / fy
                    let from = mx * bw, shift = by * bw
                    guard from + shift < plane.width else { continue }
                    for y in (my * bh)..<min(plane.height, (my + 1) * bh) {
                        let row = plane.data + y * plane.width
                        // Right to left, so each pixel is read before it's
                        // written over.
                        var x = plane.width - 1
                        while x >= from + shift { row[x] = row[x - shift]; x -= 1 }
                    }
                }
            }
        }
    }

    // MARK: - added motion (vectors that never happened)

    /// The Added motion control's field for capture `index`: one vector a
    /// macroblock, in whole pixels. A speed below a pixel a frame moves on
    /// some frames and not others, so that on average it's right.
    /// `speed` is the fraction of 1/40 of the picture's width its edge
    /// moves per frame. Vectors point where the prediction reads from, so
    /// the picture moves the other way.
    static func addedMotion(kind: Int, speed: Double, index: Int, geometry g: CodecGeometry) -> [MotionVector]? {
        guard kind != 0, speed != 0, index > 0 else { return nil }
        let top = speed * Double(g.width) / 40
        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        let reach = max(cx, cy)
        var out = [MotionVector](repeating: MotionVector(), count: g.mbCount)
        var any = false
        /// This frame's whole-pixel share of a speed of `v` pixels a frame.
        func step(_ v: Double) -> Int32 {
            Int32((Double(index) * v).rounded() - (Double(index - 1) * v).rounded())
        }
        for my in 0..<g.mbRows {
            for mx in 0..<g.mbCols {
                let x = (Double(mx * g.mb + g.mb / 2) - cx) / reach, y = (Double(my * g.mb + g.mb / 2) - cy) / reach
                let v: (Double, Double)
                switch kind {
                case 1: v = (top, 0)
                case 2: v = (0, top)
                case 3: v = (top * x, top * y)
                default: v = (-top * y, top * x)
                }
                let mv = MotionVector(dx: -step(v.0), dy: -step(v.1))
                if mv.dx != 0 || mv.dy != 0 { any = true }
                out[my * g.mbCols + mx] = mv
            }
        }
        return any ? out : nil
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

    // MARK: - a real bitrate (the Bitrate limit)

    /// The coarsest the Bitrate limit may push the quantizer (Quality 46%):
    /// about as far as real encoders' quantizers went. Blocks flatten to
    /// their averages, but the averages stay near the right color — past
    /// this, differences round to such large steps that the picture turns
    /// to posterized garbage no starved encoder ever sent. A frame that
    /// doesn't fit even so is skipped, or takes what it takes.
    static let coarsestScale: Float = 8

    /// The transform of `source` (less 128, a keyframe) or of its
    /// difference from `prediction`: every tile's coefficients, in place
    /// of its pixels. Made once, so trying a quantizer costs only a count.
    static func coefficients(of source: CodecPicture, minus prediction: CodecPicture?,
                             geometry g: CodecGeometry) -> CodecPicture {
        let out = CodecPicture(geometry: g)
        let n = g.block, nn = n * n
        basis(n).withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for (i, (src, dst)) in zip(source.planes, out.planes).enumerated() {
                let pred = prediction?.planes[i]
                let w = src.width
                forEachTileRow(src.height / n, block: n) { ty, scratch in
                    let block = scratch, coef = scratch + nn, tmp = scratch + 2 * nn
                    for tx in 0..<(w / n) {
                        let origin = ty * n * w + tx * n
                        for y in 0..<n {
                            for x in 0..<n {
                                let k = origin + y * w + x
                                block[y * n + x] = src.data[k] - (pred?.data[k] ?? 128)
                            }
                        }
                        forwardDCT(block, stride: n, coef, tmp, c, n: n)
                        for y in 0..<n {
                            (dst.data + origin + y * w).update(from: coef + y * n, count: n)
                        }
                    }
                }
            }
        }
        return out
    }

    /// Bits one quantized value costs in a run-length code: a few for
    /// where it is and its sign, and two more each time it doubles.
    @inline(__always) static func levelBits(_ level: Float) -> Int {
        let a = Int(abs(level))
        return a == 0 ? 0 : 2 + 2 * (Int.bitWidth - a.leadingZeroBitCount)
    }

    /// An estimate of the bits a frame takes at `steps`, from its
    /// `coefficients`: each value that survives the quantizer by its size,
    /// a keyframe's block averages as their change from the block before,
    /// and a little for every block sent. The same rounding as `codeIntra`
    /// and `codeResidual`, so it counts exactly what they will keep.
    static func bits(_ coefficients: CodecPicture, steps: Steps, intra: Bool) -> Int {
        let n = steps.block, nn = n * n
        var total = 0
        for (i, plane) in coefficients.planes.enumerated() {
            let table = i == 0 ? steps.luma : steps.chroma
            let w = plane.width, rows = plane.height / n
            var rowBits = [Int](repeating: 0, count: rows)
            rowBits.withUnsafeMutableBufferPointer { rp in
                table.withUnsafeBufferPointer { tp in
                    let out = rp.baseAddress!, t = tp.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: rows) { ty in
                        var sum = 0
                        var lastAverage: Float = 0
                        for tx in 0..<(w / n) {
                            let origin = plane.data + ty * n * w + tx * n
                            var block = 0
                            for k in 0..<nn {
                                let c = origin[(k / n) * w + k % n]
                                if intra {
                                    let level = (c / t[k]).rounded()
                                    if k == 0 {
                                        block += 2 + levelBits(level - lastAverage)
                                        lastAverage = level
                                    } else {
                                        block += levelBits(level)
                                    }
                                } else {
                                    let q = c / steps.inter
                                    block += levelBits(q < 0 ? -(-q + 0.2).rounded(.down) : (q + 0.2).rounded(.down))
                                }
                            }
                            // The end-of-block mark; a difference block with
                            // nothing in it is one bit in its macroblock.
                            sum += block > 0 ? block + 2 : 0
                        }
                        out[ty] = sum
                    }
                }
            }
            total += rowBits.reduce(0, +)
        }
        return total
    }

    /// Bits for a predicted frame's vectors (each as its change from the
    /// one to its left) and its one-bit-a-macroblock map of what was sent.
    static func vectorBits(_ vectors: [MotionVector], geometry g: CodecGeometry) -> Int {
        var total = g.mbCount
        for my in 0..<g.mbRows {
            var left = MotionVector()
            for mx in 0..<g.mbCols {
                let v = vectors[my * g.mbCols + mx]
                for d in [v.dx - left.dx, v.dy - left.dy] {
                    total += 1 + 2 * (Int.bitWidth - Int(abs(d)).leadingZeroBitCount)
                }
                left = v
            }
        }
        return total
    }

    /// The finest quantizer, from `start` down to `coarsestScale`, at which
    /// the frame fits `budget` bits, and what it then costs.
    static func fit(_ coefficients: CodecPicture, start: Steps, intra: Bool,
                    budget: Double) -> (steps: Steps, bits: Int) {
        let first = bits(coefficients, steps: start, intra: intra)
        guard Double(first) > budget, start.scale < coarsestScale else { return (start, first) }
        let coarsest = Steps(scale: coarsestScale, block: start.block)
        let most = bits(coefficients, steps: coarsest, intra: intra)
        guard Double(most) <= budget else { return (coarsest, most) }
        var lo = log(start.scale), hi = log(coarsestScale)
        var best = (steps: coarsest, bits: most)
        for _ in 0..<8 {
            let mid = (lo + hi) / 2
            let steps = Steps(scale: exp(mid), block: start.block)
            let cost = bits(coefficients, steps: steps, intra: intra)
            if Double(cost) <= budget { hi = mid; best = (steps, cost) } else { lo = mid }
        }
        return best
    }

    // MARK: - one frame

    /// Settings that act on one frame.
    struct FrameSettings {
        var quality: Double
        var fixedBitrate: Double
        var dataLoss: Double
        var lossPattern: LossPattern = .packets
        var concealment: Concealment = .lastPicture
        var bitErrors: Double = 0
        /// Added motion: which (0 none) and how fast (−1…1).
        var motion: Int = 0
        var motionSpeed: Double = 0
        /// The Bitrate limit: bits a frame may spend for each pixel of the
        /// picture (0: no limit), and the buffer's size in frames' worth.
        var bitsPerPixel: Double = 0
        var bufferFrames: Double = 0
    }

    /// Code `source` as `kind`, advancing `state`. Returns the picture the
    /// decoder shows (its reference — not a copy; read it before the next
    /// step) and the quantizer step for the deblocking filter.
    @discardableResult
    static func step(_ state: CodecState, source: CodecPicture, kind: CodecFrameKind,
                     index: Int, settings s: FrameSettings) -> (picture: CodecPicture, step: Float) {
        let g = state.geometry
        let lost = lostBlocks(amount: s.dataLoss, index: index, geometry: g, pattern: s.lossPattern)

        switch kind {
        case .intraOnly, .key, .droppedKey:
            let squeeze = Self.squeeze(complexity: detail(source, geometry: g), typical: 14,
                                       strictness: s.fixedBitrate)
            var steps = Steps(quality: s.quality, squeeze: squeeze, block: g.block)
            if s.bitsPerPixel > 0 {
                // A frame coded alone gets its own share and no more (DV:
                // the same bits for every frame). A keyframe opens a fresh
                // buffer and may fill it — what it takes beyond its share
                // the frames after it have to give back.
                let share = s.bitsPerPixel * Double(g.width * g.height)
                let buffer = kind == .intraOnly ? 0 : s.bufferFrames * share
                let fitted = fit(coefficients(of: source, minus: nil, geometry: g), start: steps,
                                 intra: true, budget: share + buffer)
                steps = fitted.steps
                state.bufferFill = min(buffer, max(0, Double(fitted.bits) - share))
            } else {
                state.bufferFill = 0
            }
            // What a lost block is patched from: the previous frame as
            // coded (a stream's packets: the damage lasts one frame), or on
            // tape the picture the decoder last showed, which holds until
            // new data arrives — a clogged head's bands freeze.
            let previous = s.lossPattern == .packets ? state.encoder : (state.decoder ?? state.encoder)
            let recon = CodecPicture(geometry: g)
            codeIntra(source, into: recon, steps: steps)
            state.encoder = recon
            state.vectors = Array(repeating: MotionVector(), count: g.mbCount)
            switch kind {
            case .intraOnly:
                // Each frame stands alone; a lost block is patched from the
                // previous frame (DV's error concealment) and the damage is
                // gone by the next one.
                let errors = bitErrors(amount: s.bitErrors, index: index, geometry: g)
                let patched = lost != nil && (previous != nil || s.concealment != .lastPicture)
                if patched || !errors.isEmpty {
                    let shown = recon.copy()
                    damage(shown, with: errors, geometry: g)
                    if patched, let lost {
                        if s.concealment == .lastPicture, let previous {
                            copyBlocks(from: previous, into: shown, where: lost, geometry: g)
                        } else {
                            // (Stretched leaves the top row's gaps to the patch.)
                            if s.concealment == .stretched, let previous {
                                var top = [Bool](repeating: false, count: g.mbCount)
                                for mx in 0..<g.mbCols { top[mx] = lost[mx] }
                                copyBlocks(from: previous, into: shown, where: top, geometry: g)
                            }
                            conceal(shown, lost: lost, mode: s.concealment, geometry: g)
                        }
                    }
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
            state.shownStep = steps.inter
            return (state.decoder!, steps.inter)

        case .predicted:
            guard let encRef = state.encoder else {
                return step(state, source: source, kind: .key, index: index, settings: s)
            }
            let motion = searchMotion(source, reference: encRef, previous: state.vectors, geometry: g)
            let squeeze = Self.squeeze(complexity: motion.error, typical: 3, strictness: s.fixedBitrate)
            var steps = Steps(quality: s.quality, squeeze: squeeze, block: g.block)
            let prediction = CodecPicture(geometry: g)
            compensate(encRef, vectors: motion.vectors, geometry: g, into: prediction)
            if s.bitsPerPixel > 0 {
                // Its share, plus whatever room the buffer has left. With
                // the buffer full, a cut (a whole new picture to send as a
                // difference) has to fit one frame's share: it lands as
                // coarse blocks, and the frames after it sharpen them.
                let share = s.bitsPerPixel * Double(g.width * g.height)
                let buffer = s.bufferFrames * share
                let sent = Double(vectorBits(motion.vectors, geometry: g))
                let room = share + max(0, buffer - state.bufferFill)
                let fitted = fit(coefficients(of: source, minus: prediction, geometry: g), start: steps,
                                 intra: false, budget: room - sent)
                if Double(fitted.bits) + sent > room, state.bufferFill > 0, let held = state.decoder {
                    // Too much even at the coarsest: the encoder sends
                    // nothing and waits for the buffer to drain. The
                    // picture freezes — the stutter of a starved stream.
                    state.bufferFill = max(0, state.bufferFill - share)
                    return (held, state.shownStep)
                }
                steps = fitted.steps
                state.bufferFill = min(buffer, max(0, state.bufferFill + Double(fitted.bits) + sent - share))
            } else {
                state.bufferFill = 0
            }
            let residual = CodecPicture(geometry: g)
            codeResidual(source, prediction: prediction, step: steps.inter, block: g.block, into: residual)
            let encRecon = CodecPicture(geometry: g)
            reconstruct(prediction: prediction, residual: residual, lost: nil, geometry: g, into: encRecon)

            let errors = bitErrors(amount: s.bitErrors, index: index, geometry: g)
            let added = addedMotion(kind: s.motion, speed: s.motionSpeed, index: index, geometry: g)
            if !state.diverged && lost == nil && errors.isEmpty && added == nil {
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
                // Motion that never happened, on top of the real one: the
                // differences were made for the real one, so nothing puts
                // the picture back.
                if let added {
                    for i in 0..<g.mbCount {
                        vectors[i].dx += added[i].dx
                        vectors[i].dy += added[i].dy
                    }
                }
                let decRef = state.decoder ?? encRef
                let decPrediction = CodecPicture(geometry: g)
                compensate(decRef, vectors: vectors, geometry: g, into: decPrediction)
                let decRecon = CodecPicture(geometry: g)
                reconstruct(prediction: decPrediction, residual: residual, lost: lost,
                            geometry: g, into: decRecon)
                damage(decRecon, with: errors, geometry: g)
                if let lost { conceal(decRecon, lost: lost, mode: s.concealment, geometry: g) }
                state.decoder = decRecon
                state.diverged = true
            }
            state.encoder = encRecon
            state.vectors = motion.vectors
            state.shownStep = steps.inter
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
                let my = min(g.mbRows - 1, y * fy / g.mb)
                for x in 0..<w where mask[my * g.mbCols + min(g.mbCols - 1, x * fx / g.mb)] {
                    dst.data[y * w + x] = src.data[y * w + x]
                }
            }
        }
    }

    // MARK: - deblocking (the decoder's display filter)

    /// Smooth steps across block edges that are small enough to be
    /// quantization rather than picture edges, as H.264's loop filter does.
    static func deblock(_ p: CodecPicture, strength: Double, step: Float, block n: Int = 8) {
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
                var x = n
                while x < w {
                    let k = y * w + x
                    filter(k - 2, k - 1, k, k + 1)
                    x += n
                }
            }
            var y = n
            while y < h {
                for x in 0..<w {
                    let k = y * w + x
                    filter(k - 2 * w, k - w, k, k + w)
                }
                y += n
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
