import Foundation
import Accelerate

/// When the camera captures and where keyframes fall, for one render.
public struct DigitalTiming: Equatable, Hashable, Sendable {
    /// The clip's (or timeline's) frame rate.
    public let sourceFPS: Double
    /// The camera's, never above the source's (it can't make frames up).
    public let captureFPS: Double
    /// Captures from one keyframe to the next; 1 codes every frame alone.
    public let keyframeEvery: Int

    public init(sourceFPS: Double, settings: DigitalSettings) {
        self.sourceFPS = max(1, sourceFPS)
        // Whole frames a second (looks saved before the slider snapped
        // may hold fractions).
        captureFPS = min(self.sourceFPS, max(1, settings["frame_rate"].rounded()))
        let seconds = settings["keyframe_interval"]
        keyframeEvery = seconds <= 0 ? 1 : max(2, Int((seconds * captureFPS).rounded()))
    }

    private var ratio: Double { captureFPS / sourceFPS }

    /// The capture a source frame shows (the latest one taken by then).
    public func capture(ofFrame n: Int) -> Int {
        ratio >= 1 ? n : Int((Double(n) * ratio + 1e-9).rounded(.down))
    }

    /// The source frame a capture is taken from: the first that shows it.
    public func frame(ofCapture c: Int) -> Int {
        ratio >= 1 ? c : Int((Double(c) / ratio - 1e-9).rounded(.up))
    }

    public var intraOnly: Bool { keyframeEvery == 1 }

    func kind(ofCapture c: Int, datamosh: Double) -> CodecFrameKind {
        if intraOnly { return .intraOnly }
        guard c % keyframeEvery == 0 else { return .predicted }
        return DigitalCodec.dropsKey(c / keyframeEvery, amount: datamosh) ? .droppedKey : .key
    }
}

/// How the stage's settings vary over the timeline (keyframes), so a re-run
/// from an earlier keyframe repeats exactly what a straight run would do.
public struct DigitalHistory {
    /// Changes whenever the history would, so checkpoints taken under one
    /// history are never reused for another.
    public let id: Int
    /// The settings at a source frame.
    public let settingsAt: (Int) -> DigitalSettings
    public init(id: Int, settingsAt: @escaping (Int) -> DigitalSettings) {
        self.id = id
        self.settingsAt = settingsAt
    }
}

/// Supplies an earlier source frame's pixels (BGRA8, top row first) to
/// `body`, for re-running the codec from a keyframe. Frames are asked for in
/// increasing order. Returns false when the frame can't be had.
public typealias DigitalFrameVisitor =
    (_ frame: Int, _ body: (UnsafeRawPointer, _ width: Int, _ height: Int, _ rowBytes: Int) -> Void) -> Bool

/// The Digital video stage for one consumer (the preview, playback, or one
/// export): a camera plus the codec, holding the stream's state between
/// frames.
///
/// Moving forward a frame at a time — playback, Animate, an export —
/// continues the stream. A jump, or new settings while time stands still,
/// re-runs it from the last keyframe the decoder actually received, so a
/// given frame always looks the same. Keyframes a datamosh throws away
/// leave the decoder with history reaching further back; the state at each
/// one is checkpointed so later jumps don't re-run from the start.
///
/// Not thread-safe: one renderer per thread.
public final class DigitalVideoRenderer {

    private struct StreamKey: Hashable {
        let geometry: CodecGeometry
        let timing: DigitalTiming
        let history: Int?
    }
    private struct CheckpointKey: Hashable {
        let stream: StreamKey
        let settings: DigitalSettings?
        let capture: Int
    }

    private var stream: StreamKey?
    private var state: CodecState?
    private var lastCapture: Int?
    private var lastSettings: DigitalSettings?
    /// The settings every step since the last fresh start ran under (nil
    /// once they changed mid-run, which makes the run unfit to checkpoint).
    private var runSettings: DigitalSettings??
    /// The decoded picture of `lastCapture`, as BGRA at the capture size.
    private var shown: [UInt8] = []
    private var shownSize = (width: 0, height: 0)

    private var checkpoints: [CheckpointKey: CodecState] = [:]
    private var checkpointOrder: [CheckpointKey] = []
    private var checkpointBytes = 0
    public static let checkpointBudget = 96 << 20

    /// Captures re-run since the last call (for tests and the perf log).
    public private(set) var lastRunLength = 0

    public init() {}

    /// The capture size for a picture of `width` × `height` at a capture
    /// width — the Downscale's own rule (height from the aspect, even).
    public static func captureSize(width: Int, height: Int, captureWidth: Int) -> (width: Int, height: Int) {
        let cw = max(16, min(captureWidth, width))
        let aspect = max(0.05, Double(width) / Double(max(1, height)))
        return (cw, max(16, 2 * Int((Double(cw) / aspect / 2).rounded())))
    }

    /// Replace frame `n`'s pixels with what the camera and codec make of it.
    ///
    /// - Parameters:
    ///   - pixels: frame `n` (BGRA8), rewritten in place at the same size —
    ///     the stage's picture scaled back up with hard pixels, so a
    ///     Downscale to `captureSize` afterwards gives it back exactly.
    ///   - captureSize: the camera's resolution (the Downscale size).
    ///   - sourceFPS: the clip's frame rate, or the timeline's for a still.
    ///   - history: per-frame settings from keyframes, else nil.
    ///   - earlier: earlier frames for a re-run; nil means the picture never
    ///     changes (a still), so `pixels` stands in for every frame.
    public func process(frame n: Int,
                        pixels: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int,
                        captureSize: (width: Int, height: Int),
                        sourceFPS: Double,
                        settings: DigitalSettings,
                        history: DigitalHistory? = nil,
                        earlier: DigitalFrameVisitor? = nil) {
        let structure = settings
        let timing = DigitalTiming(sourceFPS: sourceFPS, settings: structure)
        let geometry = CodecGeometry(width: captureSize.width, height: captureSize.height,
                                     chroma: structure.chroma)
        let key = StreamKey(geometry: geometry, timing: timing, history: history?.id)
        if key != stream {
            stream = key
            state = nil
            lastCapture = nil
            lastSettings = nil
        }
        func settingsFor(capture c: Int) -> DigitalSettings {
            guard let history else { return settings }
            var s = history.settingsAt(timing.frame(ofCapture: c)).holdingStructure(of: structure)
            s.values["chroma"] = structure["chroma"]
            return s
        }

        let c = timing.capture(ofFrame: n)
        let now = settingsFor(capture: c)
        lastRunLength = 0

        // The current picture at the capture size, scaled once.
        let current = Self.scale(pixels, width: width, height: height, rowBytes: rowBytes, to: captureSize,
                                 optics: structure)

        if let last = lastCapture, state != nil, last == c, lastSettings == now {
            // Same frame, same settings: what's shown already.
        } else if let last = lastCapture, state != nil, c > last, c - last <= max(2, 2 * timing.keyframeEvery) {
            // Moving forward: carry on (new settings act from here on).
            var ok = true
            for k in (last + 1)...c {
                let src = timing.frame(ofCapture: k) == n ? current
                    : earlierCapture(k, timing: timing, earlier: earlier, current: current, size: captureSize,
                                     optics: structure)
                guard let src else { ok = false; break }
                advance(capture: k, source: src, geometry: geometry, timing: timing,
                        settings: settingsFor(capture: k), key: key, history: history)
            }
            if !ok { rerun(to: c, frame: n, current: current, geometry: geometry, timing: timing, key: key,
                           history: history, earlier: earlier, settingsFor: settingsFor) }
        } else {
            rerun(to: c, frame: n, current: current, geometry: geometry, timing: timing, key: key,
                  history: history, earlier: earlier, settingsFor: settingsFor)
        }
        lastSettings = now

        Self.upscale(shown, size: captureSize, into: pixels, width: width, height: height, rowBytes: rowBytes)
    }

    // MARK: - running the stream

    /// Re-run from the last point the decoder's picture is known: a keyframe
    /// it received, or a checkpoint at one it lost.
    private func rerun(to c: Int, frame n: Int, current: [UInt8], geometry: CodecGeometry, timing: DigitalTiming,
                       key: StreamKey, history: DigitalHistory?, earlier: DigitalFrameVisitor?,
                       settingsFor: (Int) -> DigitalSettings) {
        let g = timing.keyframeEvery
        let checkpointSettings: DigitalSettings? = history == nil ? settingsFor(c) : nil
        var start: Int
        var restored: CodecState?
        if timing.intraOnly {
            // Each frame stands alone; only the one before (for patching
            // lost blocks) matters.
            start = max(0, c - 1)
        } else {
            var b = (c / g) * g
            while b > 0 {
                let kind = timing.kind(ofCapture: b, datamosh: settingsFor(b).effective("datamosh"))
                if kind == .key { break }
                let ck = CheckpointKey(stream: key, settings: checkpointSettings, capture: b)
                if let saved = checkpoints[ck] { restored = saved.copy(); break }
                b -= g
            }
            start = b
        }
        state = restored ?? CodecState(geometry: geometry)
        runSettings = .some(checkpointSettings)
        let first = restored == nil ? start : start + 1
        lastCapture = restored == nil ? nil : start
        if first > c {
            // The checkpoint is the frame itself.
            shown = Self.render(state!.decoder!, geometry: geometry, settings: settingsFor(c),
                                step: DigitalCodec.Steps(quality: settingsFor(c)["quality"], squeeze: 1).inter)
            shownSize = (geometry.width, geometry.height)
            lastCapture = c
            return
        }
        for k in first...c {
            // The camera took capture k at its first frame; `current` is
            // frame n, which may be a later repeat of it.
            let src = timing.frame(ofCapture: k) == n ? current
                : (earlierCapture(k, timing: timing, earlier: earlier, current: current,
                                  size: (geometry.width, geometry.height), optics: settingsFor(c)) ?? current)
            advance(capture: k, source: src, geometry: geometry, timing: timing,
                    settings: settingsFor(k), key: key, history: history)
        }
    }

    /// The capture-size picture for capture `k`, from an earlier frame —
    /// or the current one when the picture never changes.
    private func earlierCapture(_ k: Int, timing: DigitalTiming, earlier: DigitalFrameVisitor?,
                                current: [UInt8], size: (width: Int, height: Int),
                                optics: DigitalSettings) -> [UInt8]? {
        guard let earlier else { return current }
        var out: [UInt8]?
        let ok = earlier(timing.frame(ofCapture: k)) { base, w, h, rb in
            out = Self.scale(UnsafeMutableRawPointer(mutating: base), width: w, height: h, rowBytes: rb,
                             to: size, optics: optics)
        }
        return ok ? out : nil
    }

    /// Code capture `k` and keep what the decoder shows.
    private func advance(capture k: Int, source: [UInt8], geometry: CodecGeometry, timing: DigitalTiming,
                         settings: DigitalSettings, key: StreamKey, history: DigitalHistory?) {
        if state == nil { state = CodecState(geometry: geometry) }
        let picture = Self.capture(source, geometry: geometry, settings: settings, index: k)
        var kind = timing.kind(ofCapture: k, datamosh: settings.effective("datamosh"))
        if kind != .intraOnly && state?.encoder == nil { kind = .key }
        let frame = DigitalCodec.FrameSettings(quality: settings["quality"],
                                               fixedBitrate: settings["fixed_bitrate"],
                                               dataLoss: settings["data_loss"])
        let result: (picture: CodecPicture, step: Float)
        switch settings.codec {
        case .dct:
            result = DigitalCodec.step(state!, source: picture, kind: kind, index: k, settings: frame)
        case .blockColors:
            result = (Video1Codec.step(state!, source: picture, kind: kind, index: k, settings: frame), 0)
        }
        lastRunLength += 1
        lastCapture = k
        shown = Self.render(result.picture, geometry: geometry, settings: settings, step: result.step)
        shownSize = (geometry.width, geometry.height)

        // A run under one set of settings can be checkpointed at keyframes
        // the decoder lost (the only places its history reaches past).
        let checkpointSettings: DigitalSettings? = history == nil ? settings : nil
        if case .some(let run) = runSettings, run != checkpointSettings { runSettings = .none }
        if kind == .droppedKey, case .some(let run) = runSettings {
            store(CheckpointKey(stream: key, settings: run, capture: k), state!.copy())
        }
    }

    private func store(_ key: CheckpointKey, _ s: CodecState) {
        guard checkpoints[key] == nil else { return }
        let bytes = (s.encoder?.byteCount ?? 0) * 2
        checkpoints[key] = s
        checkpointOrder.append(key)
        checkpointBytes += bytes
        while checkpointBytes > Self.checkpointBudget, let oldest = checkpointOrder.first {
            checkpointOrder.removeFirst()
            if let old = checkpoints.removeValue(forKey: oldest) {
                checkpointBytes -= (old.encoder?.byteCount ?? 0) * 2
            }
        }
    }

    // MARK: - pixels in

    /// BGRA8 at any size → tightly packed BGRA8 at `size`: what the sensor
    /// reads through the lens. A proper area sampling (vImage's
    /// high-quality resampler), blended toward point samples as Aliasing
    /// rises to 50%, so detail the sensor can't resolve beats into moiré.
    /// Red, green and blue are read a third of a capture pixel apart: where
    /// a beat drifts slowly the three see it at phases 120° apart, so its
    /// color turns full circle — rainbows. (Half a pixel, as a 3-CCD
    /// camera's green offset is, puts them in opposite phase there: only a
    /// faint magenta-green survives DV's quarter-width color.) Above 50% the
    /// source's finest detail is boosted at each sample, for strong moiré
    /// even from sources not much sharper than the camera. Then, for One
    /// field, every other line repeated.
    static func scale(_ base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int,
                      to size: (width: Int, height: Int), optics: DigitalSettings) -> [UInt8] {
        let cw = size.width, ch = size.height
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        out.withUnsafeMutableBytes { dst in
            var srcBuf = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: rowBytes)
            var dstBuf = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(ch),
                                       width: vImagePixelCount(cw), rowBytes: cw * 4)
            if width == cw && height == ch {
                for y in 0..<height {
                    memcpy(dst.baseAddress! + y * cw * 4, base + y * rowBytes, width * 4)
                }
            } else {
                vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        let aliasing = Float(optics["aliasing"])
        if aliasing > 0 {
            let mix = min(1, aliasing * 2)
            let boost = max(0, aliasing * 2 - 1) * 1.5
            let src = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
            let kx = Double(width) / Double(cw), ky = Double(height) / Double(ch)
            out.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress!
                DispatchQueue.concurrentPerform(iterations: ch) { y in
                    let sy = min(height - 1, Int((Double(y) + 0.5) * ky))
                    let rows = [max(0, sy - 1), sy, min(height - 1, sy + 1)].map { src + $0 * rowBytes }
                    /// One channel at source pixel `sx`, its fine detail boosted.
                    @inline(__always) func read(_ sx: Int, _ c: Int) -> Float {
                        let v = Float(rows[1][sx * 4 + c])
                        guard boost > 0 else { return v }
                        var sum: Float = 0
                        for r in rows {
                            for dx in -1...1 { sum += Float(r[min(width - 1, max(0, sx + dx)) * 4 + c]) }
                        }
                        return (v + boost * (v - sum / 9)).clamped(0, 255)
                    }
                    for x in 0..<cw {
                        let center = (Double(x) + 0.5) * kx
                        let xg = min(width - 1, Int(center))
                        let xr = min(width - 1, max(0, Int(center - kx / 3)))
                        let xb = min(width - 1, Int(center + kx / 3))
                        let i = (y * cw + x) * 4
                        let pb = read(xb, 0), pg = read(xg, 1), pr = read(xr, 2)
                        o[i] = UInt8((Float(o[i]) + (pb - Float(o[i])) * mix).rounded())
                        o[i + 1] = UInt8((Float(o[i + 1]) + (pg - Float(o[i + 1])) * mix).rounded())
                        o[i + 2] = UInt8((Float(o[i + 2]) + (pr - Float(o[i + 2])) * mix).rounded())
                    }
                }
            }
        }
        if optics["fields"] >= 0.5 {
            // One field: the even lines, each shown twice.
            out.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress!
                for y in stride(from: 1, to: ch, by: 2) {
                    (o + y * cw * 4).update(from: o + (y - 1) * cw * 4, count: cw * 4)
                }
            }
        }
        return out
    }

    /// The camera's electronics, on what the sensor read (`bgra`, at the
    /// capture size). In light (linear): white balance as gains, then the
    /// CCD response's auto exposure and lens flare. Back in video levels:
    /// sensor noise, then each channel through the knee and clipped at
    /// white on its own. Then, in Y′CbCr: noise reduction, the detail
    /// circuit's sharpening, the setup lift and saturation, and finally the
    /// color subsampled.
    static func capture(_ bgra: [UInt8], geometry g: CodecGeometry, settings: DigitalSettings,
                        index: Int) -> CodecPicture {
        let w = g.width, h = g.height
        var noise = Float(settings["sensor_noise"])
        let lowLight = Float(settings["low_light_noise"])
        let nr = Float(settings["noise_reduction"])
        let warm = Float(settings["white_balance"]), magenta = Float(settings["tint"])
        let ccd = Float(settings["ccd_response"])
        let curve = CCDResponse(strength: ccd)
        var gainR = 1 + 0.25 * warm, gainB = 1 - 0.25 * warm
        var gainG = 1 - 0.15 * magenta
        var flare: Float = 0
        if lowLight > 0 && noise > 0 {
            noise *= 1 + lowLight * (Self.sensorGain(medianLuma: Self.medianLuma(bgra, width: w, height: h)) - 1)
        }
        if ccd > 0 {
            let exposure = curve.exposure(meteredMean: Self.meteredMean(bgra, width: w, height: h,
                                                                         gains: (gainR, gainG, gainB)))
            gainR *= exposure; gainG *= exposure; gainB *= exposure
            flare = curve.flare(meteredMean: Self.meteredMean(bgra, width: w, height: h,
                                                              gains: (gainR, gainG, gainB)))
        }
        // Gains act on light, so they need linear values (decoded sRGB).
        let linear = gainR != 1 || gainG != 1 || gainB != 1 || flare > 0
        let decode = Self.srgbToLinear
        var yf = [Float](repeating: 0, count: w * h)
        var cbf = [Float](repeating: 0, count: w * h)
        var crf = [Float](repeating: 0, count: w * h)
        bgra.withUnsafeBufferPointer { src in
            yf.withUnsafeMutableBufferPointer { yp in
                cbf.withUnsafeMutableBufferPointer { cbp in
                    crf.withUnsafeMutableBufferPointer { crp in
                        let s = src.baseAddress!, Y = yp.baseAddress!, CB = cbp.baseAddress!, CR = crp.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            // The row's seed hashed first: SplitMix steps its
                            // state by the same constant the row number is
                            // multiplied by, so unhashed, each row would
                            // replay the row above a few pixels along
                            // (streaks instead of grain).
                            var seeder = SplitMix(seed: (UInt64(index) &* 0x2545_F491_4F6C_DD1D) ^ (UInt64(y) &* 0x9E37_79B9_7F4A_7C15))
                            var rng = SplitMix(seed: seeder.next())
                            @inline(__always) func gauss() -> Float {
                                Float(rng.unit() + rng.unit() - 1) * 2.449
                            }
                            for x in 0..<w {
                                let i = y * w + x
                                var b = Float(s[i * 4]), gr = Float(s[i * 4 + 1]), r = Float(s[i * 4 + 2])
                                if linear {
                                    r = Self.linearToSRGB(decode[Int(r)] * gainR + flare)
                                    gr = Self.linearToSRGB(decode[Int(gr)] * gainG + flare)
                                    b = Self.linearToSRGB(decode[Int(b)] * gainB + flare)
                                }
                                if noise > 0 {
                                    // Gain noise: worst in the shadows, and
                                    // under the clip (a blown sky is clean).
                                    let shade = 1.3 - 0.6 * min(255, 0.299 * r + 0.587 * gr + 0.114 * b) / 255
                                    let n = gauss() * 7 * noise * shade
                                    let nb = gauss() * 11 * noise * shade, nc = gauss() * 11 * noise * shade
                                    // Luma noise plus color noise along Cb and Cr.
                                    r += n + 1.402 * nc
                                    gr += n - 0.344136 * nb - 0.714136 * nc
                                    b += n + 1.772 * nb
                                }
                                if ccd > 0 {
                                    r = curve.knee(r); gr = curve.knee(gr); b = curve.knee(b)
                                }
                                if linear || noise > 0 {
                                    r = r.clamped(0, 255); gr = gr.clamped(0, 255); b = b.clamped(0, 255)
                                }
                                Y[i] = 0.299 * r + 0.587 * gr + 0.114 * b
                                CB[i] = 128 - 0.168736 * r - 0.331264 * gr + 0.5 * b
                                CR[i] = 128 + 0.5 * r - 0.418688 * gr - 0.081312 * b
                            }
                        }
                    }
                }
            }
        }
        if nr > 0 {
            yf = sigmaFilter(yf, width: w, height: h, threshold: 4 + 26 * nr, mix: min(1, nr * 1.2))
            cbf = boxBlur(cbf, width: w, height: h, radius: 2, mix: nr)
            crf = boxBlur(crf, width: w, height: h, radius: 2, mix: nr)
        }
        let sharpening = Float(settings["sharpening"])
        if sharpening > 0 {
            // Detail: add back the difference from a local blur, so edges
            // overshoot both ways (halos), as wide as the blur. A fractional
            // width blends the two nearest whole radii.
            let width = min(4, max(1, Float(settings["sharpening_width"])))
            let r = Int(width), f = width - Float(r)
            var soft = boxBlur(yf, width: w, height: h, radius: r, mix: 1)
            if f > 0 {
                let wider = boxBlur(yf, width: w, height: h, radius: r + 1, mix: 1)
                for i in 0..<soft.count { soft[i] += (wider[i] - soft[i]) * f }
            }
            for i in 0..<yf.count { yf[i] = (yf[i] + 2.2 * sharpening * (yf[i] - soft[i])).clamped(0, 255) }
        }
        let black = curve.setup * 255
        let saturation = Float(settings["saturation"])
        if black > 0 || saturation != 1 {
            for i in 0..<yf.count {
                yf[i] = black + yf[i] * (1 - black / 255)
                cbf[i] = 128 + (cbf[i] - 128) * saturation
                crf[i] = 128 + (crf[i] - 128) * saturation
            }
        }
        let pic = CodecPicture(geometry: g)
        // Luma, padded by repeating the edge.
        let lw = pic.y.width
        for y in 0..<pic.y.height {
            let sy = min(h - 1, y)
            for x in 0..<lw {
                pic.y.data[y * lw + x] = yf[sy * w + min(w - 1, x)]
            }
        }
        // Color, averaged over each sample's footprint.
        let fx = g.sx, fy = g.sy
        let cw = pic.cb.width
        let n = Float(fx * fy)
        for cy in 0..<pic.cb.height {
            for cx in 0..<cw {
                var sb: Float = 0, sr: Float = 0
                for dy in 0..<fy {
                    let yy = min(h - 1, cy * fy + dy)
                    for dx in 0..<fx {
                        let i = yy * w + min(w - 1, cx * fx + dx)
                        sb += cbf[i]; sr += crf[i]
                    }
                }
                pic.cb.data[cy * cw + cx] = sb / n
                pic.cr.data[cy * cw + cx] = sr / n
            }
        }
        return pic
    }

    /// sRGB code value (0–255) → linear light.
    static let srgbToLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light → sRGB code value (0–255), unclipped above white so the
    /// knee can still see how far over a channel is.
    @inline(__always) static func linearToSRGB(_ l: Float) -> Float {
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
        return c * 255
    }

    /// Center-weighted mean of linear luminance, as camcorder auto exposure
    /// meters (the middle counts most, the edges a little).
    /// The sensor gain a camera would have needed for a scene this dark,
    /// judged by its median brightness (`medianLuma`, linear): none down to
    /// `gainKnee` (sRGB 100 — daylight footage sits above it), then rising
    /// as the median falls, up to 8× (+18 dB, a consumer camcorder's top).
    /// The median, not the exposure meter's center-weighted mean: sources
    /// are footage some camera already exposed, and a night shot's lit
    /// subject in the middle meters as bright as daylight, while half its
    /// frame stays black.
    static let gainKnee: Float = srgbToLinear[100]
    static func sensorGain(medianLuma m: Float) -> Float {
        min(8, max(1, gainKnee / max(m, 1e-4)))
    }

    /// The median of the picture's brightness (Y′, every other pixel each
    /// way), as linear light.
    static func medianLuma(_ bgra: [UInt8], width w: Int, height h: Int) -> Float {
        var counts = [Int](repeating: 0, count: 256)
        var n = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                let l = (306 * Int(bgra[i + 2]) + 601 * Int(bgra[i + 1]) + 117 * Int(bgra[i])) >> 10
                counts[min(255, l)] += 1
                n += 1
            }
        }
        var seen = 0
        for v in 0..<256 {
            seen += counts[v]
            if seen * 2 >= n { return srgbToLinear[v] }
        }
        return 1
    }

    static func meteredMean(_ bgra: [UInt8], width w: Int, height h: Int,
                            gains: (Float, Float, Float)) -> Float {
        var sum: Float = 0, weight: Float = 0
        let lut = srgbToLinear
        for y in stride(from: 0, to: h, by: 2) {
            let dy = (Float(y) + 0.5) / Float(h) * 2 - 1
            for x in stride(from: 0, to: w, by: 2) {
                let dx = (Float(x) + 0.5) / Float(w) * 2 - 1
                let wt = max(0.15, 1 - 0.6 * (dx * dx + dy * dy))
                let i = (y * w + x) * 4
                let l = 0.2126 * lut[Int(bgra[i + 2])] * gains.0 + 0.7152 * lut[Int(bgra[i + 1])] * gains.1
                    + 0.0722 * lut[Int(bgra[i])] * gains.2
                sum += l * wt; weight += wt
            }
        }
        return weight > 0 ? sum / weight : 0.18
    }

    /// Edge-preserving smoothing: each pixel moves toward the neighbors
    /// that are within `threshold` of it (a camera's noise reduction).
    static func sigmaFilter(_ p: [Float], width w: Int, height h: Int, threshold: Float, mix: Float) -> [Float] {
        var out = p
        out.withUnsafeMutableBufferPointer { op in
            let o = op.baseAddress!
            p.withUnsafeBufferPointer { ip in
                let s = ip.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let c = s[y * w + x]
                        var sum: Float = 0, n: Float = 0
                        for dy in -1...1 {
                            let yy = min(h - 1, max(0, y + dy))
                            for dx in -1...1 {
                                let v = s[yy * w + min(w - 1, max(0, x + dx))]
                                if abs(v - c) < threshold { sum += v; n += 1 }
                            }
                        }
                        o[y * w + x] = c + (sum / n - c) * mix
                    }
                }
            }
        }
        return out
    }

    static func boxBlur(_ p: [Float], width w: Int, height h: Int, radius r: Int, mix: Float) -> [Float] {
        var tmp = p, out = p
        let n = Float(2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for d in -r...r { s += p[y * w + min(w - 1, max(0, x + d))] }
                tmp[y * w + x] = s / n
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for d in -r...r { s += tmp[min(h - 1, max(0, y + d)) * w + x] }
                out[y * w + x] = p[y * w + x] + (s / n - p[y * w + x]) * mix
            }
        }
        return out
    }

    // MARK: - pixels out

    /// The decoder's picture as BGRA8 at the capture size: deblocked (on a
    /// copy — the reference stays as coded), color interpolated back up.
    static func render(_ decoded: CodecPicture, geometry g: CodecGeometry,
                       settings: DigitalSettings, step: Float) -> [UInt8] {
        var picture = decoded
        let deblocking = settings.effective("deblocking")
        if deblocking > 0 {
            picture = decoded.copy()
            DigitalCodec.deblock(picture, strength: deblocking, step: step)
        }
        let w = g.width, h = g.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let fx = Float(g.sx), fy = Float(g.sy)
        let cb = picture.cb, cr = picture.cr, luma = picture.y
        out.withUnsafeMutableBufferPointer { op in
            let o = op.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let cyf = (Float(y) + 0.5) / fy - 0.5
                let cy0 = Int(cyf.rounded(.down)), ty = cyf - Float(cy0)
                for x in 0..<w {
                    let cxf = (Float(x) + 0.5) / fx - 0.5
                    let cx0 = Int(cxf.rounded(.down)), tx = cxf - Float(cx0)
                    func bil(_ p: CodecPlane) -> Float {
                        let a = p.clamped(cx0, cy0), b = p.clamped(cx0 + 1, cy0)
                        let c = p.clamped(cx0, cy0 + 1), d = p.clamped(cx0 + 1, cy0 + 1)
                        return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
                    }
                    let Y = luma.data[y * luma.width + x]
                    let u = bil(cb) - 128, v = bil(cr) - 128
                    let r = Y + 1.402 * v
                    let gg = Y - 0.344136 * u - 0.714136 * v
                    let b = Y + 1.772 * u
                    let i = (y * w + x) * 4
                    o[i] = UInt8(b.rounded().clamped(0, 255))
                    o[i + 1] = UInt8(gg.rounded().clamped(0, 255))
                    o[i + 2] = UInt8(r.rounded().clamped(0, 255))
                    o[i + 3] = 255
                }
            }
        }
        return out
    }

    /// Scale the capture-size picture back up with hard pixels. Each source
    /// pixel takes the capture pixel its center falls in, so a nearest
    /// Downscale (which samples pixel centers) returns the picture exactly.
    static func upscale(_ picture: [UInt8], size: (width: Int, height: Int),
                        into base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int) {
        let cw = size.width, ch = size.height
        guard picture.count == cw * ch * 4 else { return }
        let xs = (0..<width).map { min(cw - 1, Int((Double($0) + 0.5) * Double(cw) / Double(width))) }
        picture.withUnsafeBufferPointer { pp in
            let src = UnsafeRawPointer(pp.baseAddress!).assumingMemoryBound(to: UInt32.self)
            xs.withUnsafeBufferPointer { xp in
                let map = xp.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let sy = min(ch - 1, Int((Double(y) + 0.5) * Double(ch) / Double(height)))
                    let srow = src + sy * cw
                    let drow = (base + y * rowBytes).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width { drow[x] = srow[map[x]] }
                }
            }
        }
    }
}

/// The tone of a 90s 3-CCD camcorder (the VX1000), fitted to its footage:
/// across six reference frames the darkest pixels sat at 20–45 (not 0),
/// medians at 130–210, and 10–32% of each frame piled up in the top bins,
/// with warm shots' red reaching white well before blue. `strength` blends
/// every part from nothing (0) to the full response (1).
struct CCDResponse {
    let strength: Float

    /// Auto exposure: bring the metered mean to a bright target — these
    /// cameras exposed for faces and shadows and let skies go.
    static let target: Float = 0.40
    func exposure(meteredMean m: Float) -> Float {
        let full = min(4, max(0.5, Self.target / max(m, 1e-4)))
        return pow(full, strength)
    }

    /// Veiling flare from a cheap lens (and the fisheye adapters these were
    /// shot through): a share of the whole frame's light scattered over
    /// everything, so bright scenes lift their shadows most.
    func flare(meteredMean m: Float) -> Float { 0.03 * strength * m }

    /// The knee: above it each channel is compressed, then clips at white.
    static let kneePoint: Float = 0.72 * 255
    func knee(_ v: Float) -> Float {
        guard v > Self.kneePoint else { return v }
        let slope = 1 - 0.62 * strength
        return min(255, Self.kneePoint + (v - Self.kneePoint) * slope)
    }

    /// NTSC DV's 7.5 IRE setup, mishandled in transfer: black shows as gray.
    var setup: Float { 0.065 * strength }
}
