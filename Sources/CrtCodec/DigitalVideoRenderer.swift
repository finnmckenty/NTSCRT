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

    /// What the sensor read for the last couple of source frames (before the
    /// fields are put together), so an interlaced camera's earlier field
    /// doesn't cost another decode of the frame before. Valid for one
    /// sensing setup (`sensedFor`).
    private struct SensingKey: Equatable {
        let source: [Int]
        let width: Int, height: Int
        let aliasing: Double, sensor: Double
    }
    private var sensed: [(frame: Int, pixels: [UInt8])] = []
    private var sensedFor: SensingKey?

    private var checkpoints: [CheckpointKey: CodecState] = [:]
    private var checkpointOrder: [CheckpointKey] = []
    private var checkpointBytes = 0
    public static let checkpointBudget = 96 << 20

    /// Captures re-run since the last call (for tests and the perf log).
    public private(set) var lastRunLength = 0

    /// Checked once a capture during a re-run; true abandons it (the
    /// renderer is left mid-stream, so only a throwaway one should be
    /// cancelled).
    public var isCancelled: (() -> Bool)?

    /// After a `process` that deferred its re-run: the frame's pixels as
    /// they came in, for running it exactly elsewhere.
    public private(set) var deferredPixels: [UInt8]?
    public func takeDeferredPixels() -> [UInt8]? {
        defer { deferredPixels = nil }
        return deferredPixels
    }

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
                        earlier: DigitalFrameVisitor? = nil,
                        deferRerunAbove: Int? = nil) {
        deferredPixels = nil
        let structure = settings
        let timing = DigitalTiming(sourceFPS: sourceFPS, settings: structure)
        let geometry = CodecGeometry(width: captureSize.width, height: captureSize.height,
                                     chroma: structure.chroma, block: structure.blockSize)
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

        // What the sensor reads of the current frame, scaled once, and the
        // capture made of it. An interlaced camera's frame is two fields a
        // moment apart: this frame's even lines, the frame before's odd ones.
        let sensingKey = SensingKey(source: [width, height], width: captureSize.width, height: captureSize.height,
                                    aliasing: structure["aliasing"], sensor: structure["sensor"])
        if sensingKey != sensedFor || earlier == nil { sensed.removeAll() }
        sensedFor = sensingKey
        let sensedNow = Self.sense(pixels, width: width, height: height, rowBytes: rowBytes, to: captureSize,
                                   optics: structure)
        // The same frame number reading differently is another clip (or
        // another crop of it): nothing remembered belongs to it.
        if let same = sensed.first(where: { $0.frame == n }), same.pixels != sensedNow { sensed.removeAll() }
        let fieldMode = structure.fields
        /// What the sensor read of source frame `f`: nil when it can't be had.
        func sensedFrame(_ f: Int) -> [UInt8]? {
            if f == n || earlier == nil { return sensedNow }
            if let hit = sensed.first(where: { $0.frame == f }) { return hit.pixels }
            var out: [UInt8]?
            let ok = earlier!(f) { base, w, h, rb in
                out = Self.sense(UnsafeMutableRawPointer(mutating: base), width: w, height: h, rowBytes: rb,
                                 to: captureSize, optics: structure)
            }
            guard ok, let out else { return nil }
            sensed.append((f, out))
            if sensed.count > 3 { sensed.removeFirst() }
            return out
        }
        /// The picture the camera hands the codec for source frame `f`.
        func captured(_ f: Int) -> [UInt8]? {
            // (The earlier field first: frames are asked for in order.)
            let before = fieldMode.isInterlaced && f > 0 ? sensedFrame(f - 1) : nil
            guard let now = sensedFrame(f) else { return nil }
            return Self.fields(now, before: before, size: captureSize, mode: fieldMode)
        }
        let current = captured(n) ?? Self.fields(sensedNow, before: nil, size: captureSize, mode: fieldMode)
        defer {
            // Keep this frame (and the one before) for the next call.
            sensed.removeAll { $0.frame == n }
            sensed.append((n, sensedNow))
            if sensed.count > 3 { sensed.removeFirst() }
        }

        var deferred = false
        if let last = lastCapture, state != nil, last == c, lastSettings == now {
            // Same frame, same settings: what's shown already.
        } else if let last = lastCapture, state != nil, c > last, c - last <= max(2, 2 * timing.keyframeEvery) {
            // Moving forward: carry on (new settings act from here on).
            var ok = true
            for k in (last + 1)...c {
                let src = timing.frame(ofCapture: k) == n ? current : captured(timing.frame(ofCapture: k))
                guard let src else { ok = false; break }
                advance(capture: k, source: src, geometry: geometry, timing: timing,
                        settings: settingsFor(capture: k), key: key, history: history)
            }
            if !ok { deferred = rerun(to: c, frame: n, current: current, geometry: geometry, timing: timing, key: key,
                                      history: history, captured: captured, settingsFor: settingsFor,
                                      deferAbove: deferRerunAbove) }
        } else {
            deferred = rerun(to: c, frame: n, current: current, geometry: geometry, timing: timing, key: key,
                             history: history, captured: captured, settingsFor: settingsFor,
                             deferAbove: deferRerunAbove)
        }
        lastSettings = now
        if deferred {
            deferredPixels = Array(UnsafeRawBufferPointer(start: pixels, count: rowBytes * height))
        }

        Self.upscale(shown, size: captureSize, into: pixels, width: width, height: height, rowBytes: rowBytes)
    }

    // MARK: - running the stream

    /// Re-run from the last point the decoder's picture is known: a keyframe
    /// it received, or a checkpoint at one it lost.
    ///
    /// With `deferAbove`, a re-run of more captures than that isn't done:
    /// the frame is coded on its own instead (a keyframe under the new
    /// settings — no smear or datamosh from before it) and the call returns
    /// true, for the caller to run the exact re-run elsewhere.
    @discardableResult
    private func rerun(to c: Int, frame n: Int, current: [UInt8], geometry: CodecGeometry, timing: DigitalTiming,
                       key: StreamKey, history: DigitalHistory?, captured: (Int) -> [UInt8]?,
                       settingsFor: (Int) -> DigitalSettings, deferAbove: Int? = nil) -> Bool {
        let g = timing.keyframeEvery
        let checkpointSettings: DigitalSettings? = history == nil ? settingsFor(c) : nil
        var start: Int
        var restored: CodecState?
        if timing.intraOnly {
            // Each frame stands alone; only the one before (for patching
            // lost blocks) matters — except on tape, where a patch holds
            // what the decoder last showed: back to the last clean read
            // (and the frame before that, which a stream's patch at it
            // would use).
            let now = settingsFor(c)
            let held = now["data_loss"] > 0 && Int(now["loss_pattern"].rounded()) != 0
            let clean = (c / DigitalCodec.tapeRefresh) * DigitalCodec.tapeRefresh
            start = max(0, (held ? min(c, clean) : c) - 1)
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
        if let deferAbove, c - start > deferAbove {
            state = CodecState(geometry: geometry)
            runSettings = .none                  // not fit to checkpoint
            advance(capture: c, source: current, geometry: geometry, timing: timing,
                    settings: settingsFor(c), key: key, history: history)
            return true
        }
        state = restored ?? CodecState(geometry: geometry)
        runSettings = .some(checkpointSettings)
        let first = restored == nil ? start : start + 1
        lastCapture = restored == nil ? nil : start
        if first > c {
            // The checkpoint is the frame itself.
            shown = Self.present(state!.decoder!, geometry: geometry, settings: settingsFor(c),
                                 step: DigitalCodec.Steps(quality: settingsFor(c)["quality"], squeeze: 1,
                                                          block: geometry.block).inter)
            shownSize = (geometry.width, geometry.height)
            lastCapture = c
            return false
        }
        for k in first...c {
            if let isCancelled, isCancelled() { return false }
            // The camera took capture k at its first frame; `current` is
            // frame n, which may be a later repeat of it.
            let src = timing.frame(ofCapture: k) == n ? current : (captured(timing.frame(ofCapture: k)) ?? current)
            advance(capture: k, source: src, geometry: geometry, timing: timing,
                    settings: settingsFor(k), key: key, history: history)
        }
        return false
    }

    /// Code capture `k` and keep what the decoder shows.
    private func advance(capture k: Int, source: [UInt8], geometry: CodecGeometry, timing: DigitalTiming,
                         settings: DigitalSettings, key: StreamKey, history: DigitalHistory?) {
        if state == nil { state = CodecState(geometry: geometry) }
        let picture = Self.capture(source, geometry: geometry, settings: settings, index: k)
        var kind = timing.kind(ofCapture: k, datamosh: settings.effective("datamosh"))
        if kind != .intraOnly && state?.encoder == nil { kind = .key }
        let frame = DigitalCodec.FrameSettings(
            quality: settings["quality"],
            fixedBitrate: settings["fixed_bitrate"],
            dataLoss: settings["data_loss"],
            lossPattern: DigitalCodec.LossPattern(rawValue: Int(settings["loss_pattern"].rounded())) ?? .packets,
            concealment: DigitalCodec.Concealment(rawValue: Int(settings.effective("concealment").rounded())) ?? .lastPicture,
            bitErrors: settings.effective("bit_errors"),
            motion: Int(settings.effective("mosh_motion").rounded()),
            motionSpeed: settings.effective("mosh_speed"),
            bitsPerPixel: settings.bitsPerPixel,
            bufferFrames: max(0, settings["rate_buffer"]) * timing.captureFPS)
        let result: (picture: CodecPicture, step: Float)
        switch settings.codec {
        case .dct:
            result = DigitalCodec.step(state!, source: picture, kind: kind, index: k, settings: frame)
        case .blockColors:
            result = (Video1Codec.step(state!, source: picture, kind: kind, index: k, settings: frame), 0)
        }
        lastRunLength += 1
        lastCapture = k
        shown = Self.present(result.picture, geometry: geometry, settings: settings, step: result.step)
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
        fields(sense(base, width: width, height: height, rowBytes: rowBytes, to: size, optics: optics),
               before: nil, size: size, mode: optics.fields)
    }

    /// The sensor's reading of one source frame (see `scale`), before the
    /// fields are put together. A one-chip sensor reads all three colors at
    /// the same place (there is no prism to offset them) and then sees only
    /// one of them at each pixel.
    static func sense(_ base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int,
                      to size: (width: Int, height: Int), optics: DigitalSettings) -> [UInt8] {
        let cw = size.width, ch = size.height
        let oneChip = optics["sensor"] >= 0.5
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
                        let xr = oneChip ? xg : min(width - 1, max(0, Int(center - kx / 3)))
                        let xb = oneChip ? xg : min(width - 1, Int(center + kx / 3))
                        let i = (y * cw + x) * 4
                        let pb = read(xb, 0), pg = read(xg, 1), pr = read(xr, 2)
                        o[i] = UInt8((Float(o[i]) + (pb - Float(o[i])) * mix).rounded())
                        o[i + 1] = UInt8((Float(o[i + 1]) + (pg - Float(o[i + 1])) * mix).rounded())
                        o[i + 2] = UInt8((Float(o[i + 2]) + (pr - Float(o[i + 2])) * mix).rounded())
                    }
                }
            }
        }
        switch optics.sensor {
        case .threeChips: break
        case .mosaic: mosaic(&out, width: cw, height: ch)
        case .complementary: complementary(&out, width: cw, height: ch)
        }
        return out
    }

    // MARK: - the camcorder's one chip (complementary filters)
    //
    // Most one-chip camcorders of the 90s didn't use red, green and blue
    // filters. Theirs were cyan, yellow, magenta and green — each passing
    // two thirds of the light instead of one — laid out
    //
    //     Cy Ye Cy Ye
    //     G  Mg G  Mg
    //     Cy Ye Cy Ye
    //     Mg G  Mg G
    //
    // and read two rows at a time, summed (field integration: one field
    // pairs rows 0+1, 2+3…, the other 1+2, 3+4…). Along a summed line the
    // pixels alternate between two sums, whose average is brightness
    // (2R + 3G + 2B) and whose difference is one color-difference signal:
    // 2R − G on one line, 2B − G on the field's next. Each line therefore
    // has only one of the two, and takes the other from the line before
    // it in its field (a one-line delay).
    //
    // Everything that makes these cameras look the way they do follows
    // from that, with nothing added: color has half the detail across and
    // comes a line late down the picture, so it smears and fringes at
    // horizontal edges; a sharp vertical edge reads as a difference
    // between neighboring pixels, which is what color is, so it picks up
    // false color; brightness is softened a little both ways by the sums.

    /// What the photosite at (x, y) reads of linear red, green and blue.
    @inline(__always)
    static func complementarySite(_ x: Int, _ y: Int, _ r: Float, _ g: Float, _ b: Float) -> Float {
        let evenX = x & 1 == 0
        switch y & 3 {
        case 0, 2: return evenX ? g + b : r + g            // Cy, Ye
        case 1: return evenX ? g : r + b                   // G, Mg
        default: return evenX ? r + b : g                  // Mg, G
        }
    }

    /// Linear RGB from complementary photosites, as the camera forms it.
    /// The planes hold columns −2…w+2 and rows 0…h (`w + 5` by `h + 1`).
    /// Even lines read `even`, odd lines `odd`: the two fields are separate
    /// exposures, so their noise differs (a noise-free picture is passed
    /// as both).
    static func complementaryColors(even: [Float], odd: [Float], width w: Int, height h: Int)
        -> (r: [Float], g: [Float], b: [Float]) {
        let pw = w + 5
        var luma = [Float](repeating: 0, count: w * h)
        var color = [Float](repeating: 0, count: w * h)     // 2R − G or 2B − G, by line
        even.withUnsafeBufferPointer { ep in
            odd.withUnsafeBufferPointer { op in
                luma.withUnsafeMutableBufferPointer { lp in
                    color.withUnsafeMutableBufferPointer { cp in
                        let L = lp.baseAddress!, C = cp.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            let p = (y & 1 == 0 ? ep.baseAddress! : op.baseAddress!) + y * pw
                            // The line as read: each pixel and the one below it.
                            var sum = [Float](repeating: 0, count: pw)
                            for k in 0..<pw { sum[k] = p[k] + p[k + pw] }
                            // 2R − G lines pair an odd pixel less the even
                            // one before it; 2B − G lines the other way.
                            let redLine = y & 3 < 2
                            for x in 0..<w {
                                let k = x + 2
                                L[y * w + x] = (sum[k - 1] + 2 * sum[k] + sum[k + 1]) / 4
                                var c: Float = 0
                                for (j, weight) in [(k - 2, Float(1)), (k - 1, 3), (k, 3), (k + 1, 1)] {
                                    let step = sum[j + 1] - sum[j]
                                    c += weight * (((j - 2) & 1 == 0) == redLine ? step : -step)
                                }
                                C[y * w + x] = c / 8
                            }
                        }
                    }
                }
            }
        }
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for y in 0..<h {
            let redLine = y & 3 < 2
            // The other color difference: the line before in this field.
            let from = y >= 2 ? y - 2 : y + 2
            for x in 0..<w {
                let own = color[y * w + x], other = color[from * w + x]
                let cr = redLine ? own : other, cb = redLine ? other : own
                let green = (2 * luma[y * w + x] - cr - cb) / 5
                g[y * w + x] = green
                r[y * w + x] = (cr + green) / 2
                b[y * w + x] = (cb + green) / 2
            }
        }
        return (r, g, b)
    }

    /// A one-chip camcorder's reading of the picture (see above), in place.
    static func complementary(_ bgra: inout [UInt8], width w: Int, height h: Int) {
        guard w >= 4, h >= 4 else { return }
        let pw = w + 5, ph = h + 1
        let decode = srgbToLinear
        var sites = [Float](repeating: 0, count: pw * ph)
        for y in 0..<ph {
            let sy = min(h - 1, y)
            for k in 0..<pw {
                let x = k - 2
                let i = (sy * w + min(w - 1, max(0, x))) * 4
                sites[y * pw + k] = complementarySite(x, y, decode[Int(bgra[i + 2])], decode[Int(bgra[i + 1])],
                                                      decode[Int(bgra[i])])
            }
        }
        let rgb = complementaryColors(even: sites, odd: sites, width: w, height: h)
        for i in 0..<(w * h) {
            bgra[i * 4] = UInt8(linearToSRGB(rgb.b[i].clamped(0, 1)).rounded().clamped(0, 255))
            bgra[i * 4 + 1] = UInt8(linearToSRGB(rgb.g[i].clamped(0, 1)).rounded().clamped(0, 255))
            bgra[i * 4 + 2] = UInt8(linearToSRGB(rgb.r[i].clamped(0, 1)).rounded().clamped(0, 255))
        }
    }

    // MARK: - a one-chip sensor's grain

    /// Noise at a photosite for Sensor noise at 100%, on the 0–255 scale.
    /// Three chips' grain is 7 in brightness and 11 along each color
    /// signal — set by eye, stronger in color than three sensors' own
    /// noise would be (that would be about equal in all three: 0.67, 0.62
    /// and 0.66 of the photosite's). So the two can't be matched part for
    /// part; this is the photosite noise with the same total energy:
    /// √((7² + 11² + 11²) / (0.67² + 0.62² + 0.66²)).
    static let photositeNoise: Float = 15.1

    /// Unit noise at every photosite, put through the sensor's own color
    /// reconstruction: what its grain looks like in red, green and blue.
    /// (The reconstruction is linear, so the picture's and the noise's can
    /// be made apart and added.) On one chip each color is pieced together
    /// from several photosites, so the grain isn't independent from pixel
    /// to pixel: color noise comes out in blotches a few pixels across —
    /// which color subsampling then can't average away — while brightness
    /// grain, summed over more light, is finer and weaker.
    static func sensorGrain(_ sensor: SensorKind, width w: Int, height h: Int, index: Int)
        -> (r: [Float], g: [Float], b: [Float])? {
        func plane(_ tag: UInt64, _ pw: Int, _ ph: Int) -> [Float] {
            var out = [Float](repeating: 0, count: pw * ph)
            out.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress!
                DispatchQueue.concurrentPerform(iterations: ph) { y in
                    var seeder = SplitMix(seed: (UInt64(index) &* 0x2545_F491_4F6C_DD1D) ^ (UInt64(y) &* 0x9E37_79B9_7F4A_7C15)
                                          ^ (tag &* 0xD6E8_FEB8_6659_FD93))
                    var rng = SplitMix(seed: seeder.next())
                    for x in 0..<pw { o[y * pw + x] = Float(rng.unit() + rng.unit() - 1) * 2.449 }
                }
            }
            return out
        }
        switch sensor {
        case .threeChips:
            return nil
        case .mosaic:
            guard w >= 2, h >= 2 else { return nil }
            return mosaicColors(plane(1, w, h), width: w, height: h)
        case .complementary:
            guard w >= 4, h >= 4 else { return nil }
            return complementaryColors(even: plane(2, w + 5, h + 1), odd: plane(3, w + 5, h + 1), width: w, height: h)
        }
    }

    /// `mosaic`'s reconstruction on a plane of photosite values (for its
    /// grain): each color where it was read, else the mean of the nearest
    /// photosites that read it.
    static func mosaicColors(_ site: [Float], width w: Int, height h: Int) -> (r: [Float], g: [Float], b: [Float]) {
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        @inline(__always) func mx(_ x: Int) -> Int { x < 0 ? -x : (x >= w ? 2 * w - 2 - x : x) }
        @inline(__always) func my(_ y: Int) -> Int { y < 0 ? -y : (y >= h ? 2 * h - 2 - y : y) }
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float { site[my(y) * w + mx(x)] }
        for y in 0..<h {
            for x in 0..<w {
                let evenX = x % 2 == 0, evenY = y % 2 == 0
                let i = y * w + x
                if evenX == evenY {
                    // A red (even, even) or blue (odd, odd) photosite.
                    let cross = (at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)) / 4
                    let diagonal = (at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) + at(x + 1, y + 1)) / 4
                    g[i] = cross
                    r[i] = evenX ? site[i] : diagonal
                    b[i] = evenX ? diagonal : site[i]
                } else {
                    // A green photosite: red and blue from the two beside it.
                    let across = (at(x - 1, y) + at(x + 1, y)) / 2, along = (at(x, y - 1) + at(x, y + 1)) / 2
                    g[i] = site[i]
                    r[i] = evenY ? across : along
                    b[i] = evenY ? along : across
                }
            }
        }
        return (r, g, b)
    }

    /// A one-chip sensor: a mosaic of color filters (red and green on even
    /// lines, green and blue on odd ones), so each pixel reads one color,
    /// and the camera fills in the other two from the nearest pixels that
    /// have them. Flat areas come out right; at an edge or in fine detail
    /// the three colors are guessed from different places, which shows as
    /// false color and a zipper along the edge.
    static func mosaic(_ bgra: inout [UInt8], width w: Int, height h: Int) {
        guard w >= 2, h >= 2 else { return }
        let src = bgra
        // Neighbors past the edge are mirrored (keeping each one's color).
        @inline(__always) func mx(_ x: Int) -> Int { x < 0 ? -x : (x >= w ? 2 * w - 2 - x : x) }
        @inline(__always) func my(_ y: Int) -> Int { y < 0 ? -y : (y >= h ? 2 * h - 2 - y : y) }
        src.withUnsafeBufferPointer { sp in
            bgra.withUnsafeMutableBufferPointer { op in
                let s = sp.baseAddress!, o = op.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    /// Channel `c` (0 blue, 1 green, 2 red) at a pixel.
                    @inline(__always) func at(_ x: Int, _ yy: Int, _ c: Int) -> Int {
                        Int(s[(my(yy) * w + mx(x)) * 4 + c])
                    }
                    for x in 0..<w {
                        let evenX = x % 2 == 0, evenY = y % 2 == 0
                        let r: Int, g: Int, b: Int
                        if evenX == evenY {
                            // A red (even, even) or blue (odd, odd) pixel:
                            // green from the four beside it, the other color
                            // from the four diagonals.
                            let own = evenX ? 2 : 0, other = evenX ? 0 : 2
                            g = (at(x - 1, y, 1) + at(x + 1, y, 1) + at(x, y - 1, 1) + at(x, y + 1, 1) + 2) / 4
                            let d = (at(x - 1, y - 1, other) + at(x + 1, y - 1, other)
                                     + at(x - 1, y + 1, other) + at(x + 1, y + 1, other) + 2) / 4
                            let mine = at(x, y, own)
                            r = evenX ? mine : d
                            b = evenX ? d : mine
                        } else {
                            // A green pixel: red and blue from the two
                            // beside it, along the row or the column.
                            g = at(x, y, 1)
                            let across = evenY ? 2 : 0, along = evenY ? 0 : 2
                            let a = (at(x - 1, y, across) + at(x + 1, y, across) + 1) / 2
                            let c = (at(x, y - 1, along) + at(x, y + 1, along) + 1) / 2
                            r = evenY ? a : c
                            b = evenY ? c : a
                        }
                        let i = (y * w + x) * 4
                        o[i] = UInt8(b); o[i + 1] = UInt8(g); o[i + 2] = UInt8(r)
                    }
                }
            }
        }
    }

    /// The frame the camera hands on, from what its sensor read: whole
    /// (progressive), one field with each line shown twice, or both fields
    /// of an interlaced frame — the even lines of this reading and the odd
    /// lines of the one `before` (the same reading when there is none, so a
    /// still picture is whole) — woven together or blended.
    static func fields(_ now: [UInt8], before: [UInt8]?, size: (width: Int, height: Int),
                       mode: FieldMode) -> [UInt8] {
        let cw = size.width, ch = size.height
        var out = now
        switch mode {
        case .progressive:
            break
        case .oneField:
            // The even lines, each shown twice.
            out.withUnsafeMutableBufferPointer { op in
                let o = op.baseAddress!
                for y in stride(from: 1, to: ch, by: 2) {
                    (o + y * cw * 4).update(from: o + (y - 1) * cw * 4, count: cw * 4)
                }
            }
        case .woven, .blended:
            if let before, before.count == now.count {
                out.withUnsafeMutableBufferPointer { op in
                    before.withUnsafeBufferPointer { bp in
                        for y in stride(from: 1, to: ch, by: 2) {
                            (op.baseAddress! + y * cw * 4).update(from: bp.baseAddress! + y * cw * 4, count: cw * 4)
                        }
                    }
                }
            }
            if mode == .blended {
                // A blend deinterlacer: each line mixed with the ones above
                // and below, which belong to the other field (1-2-1).
                let woven = out
                woven.withUnsafeBufferPointer { wp in
                    out.withUnsafeMutableBufferPointer { op in
                        let s = wp.baseAddress!, o = op.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: ch) { y in
                            let up = s + max(0, y - 1) * cw * 4, mid = s + y * cw * 4
                            let down = s + min(ch - 1, y + 1) * cw * 4
                            let row = o + y * cw * 4
                            for i in 0..<(cw * 4) {
                                row[i] = UInt8((Int(up[i]) + 2 * Int(mid[i]) + Int(down[i]) + 2) / 4)
                            }
                        }
                    }
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
        let curve = CCDResponse(strength: Float(settings["ccd_response"]))
        var gainR = 1 + 0.25 * warm, gainB = 1 - 0.25 * warm
        var gainG = 1 - 0.15 * magenta
        var flare: Float = 0
        // How far the camera has had to turn its gain up for this scene.
        let sensorGain = (lowLight > 0 && noise > 0) || curve.exposure > 0
            ? Self.sensorGain(medianLuma: Self.medianLuma(bgra, width: w, height: h)) : 1
        if lowLight > 0 && noise > 0 { noise *= 1 + lowLight * (sensorGain - 1) }
        if curve.exposure > 0 {
            let exposure = curve.exposureGain(meteredMean: Self.meteredMean(bgra, width: w, height: h,
                                                                            gains: (gainR, gainG, gainB)),
                                              sensorGain: sensorGain)
            gainR *= exposure; gainG *= exposure; gainB *= exposure
        }
        if curve.flare > 0 {
            flare = curve.flareLight(meteredMean: Self.meteredMean(bgra, width: w, height: h,
                                                                   gains: (gainR, gainG, gainB)))
        }
        // A one-chip sensor's grain comes through its color reconstruction.
        let sensor = settings.sensor
        let grain = noise > 0 && sensor != .threeChips
            ? Self.sensorGrain(sensor, width: w, height: h, index: index) : nil
        // Vertical smear: the light each column's brightest pixels leak
        // into the whole column on its way off the chip.
        let smear = Self.smear(bgra, width: w, height: h, strength: Float(settings["smear"]))
        // Gains act on light, so they need linear values (decoded sRGB).
        let linear = gainR != 1 || gainG != 1 || gainB != 1 || flare > 0 || smear != nil || curve.highlights > 0
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
                                    let veil = flare + (smear?[x] ?? 0)
                                    let over = curve.recovered(top: max(r, gr, b), low: min(r, gr, b))
                                    r = Self.linearToSRGB(decode[Int(r)] * gainR * over + veil)
                                    gr = Self.linearToSRGB(decode[Int(gr)] * gainG * over + veil)
                                    b = Self.linearToSRGB(decode[Int(b)] * gainB * over + veil)
                                }
                                if noise > 0 {
                                    // Gain noise: worst in the shadows, and
                                    // under the clip (a blown sky is clean).
                                    let shade = 1.3 - 0.6 * min(255, 0.299 * r + 0.587 * gr + 0.114 * b) / 255
                                    if let grain {
                                        let k = Self.photositeNoise * noise * shade
                                        r += k * grain.r[i]; gr += k * grain.g[i]; b += k * grain.b[i]
                                    } else {
                                        let n = gauss() * 7 * noise * shade
                                        let nb = gauss() * 11 * noise * shade, nc = gauss() * 11 * noise * shade
                                        // Luma noise plus color noise along Cb and Cr.
                                        r += n + 1.402 * nc
                                        gr += n - 0.344136 * nb - 0.714136 * nc
                                        b += n + 1.772 * nb
                                    }
                                }
                                if curve.highlights > 0 {
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
        let black = curve.black, lumaScale = curve.lumaScale
        let saturation = Float(settings["saturation"]) * curve.chromaScale
        if black > 0 || saturation != 1 {
            for i in 0..<yf.count {
                yf[i] = black + yf[i] * lumaScale
                cbf[i] = 128 + (cbf[i] - 128) * saturation
                crf[i] = 128 + (crf[i] - 128) * saturation
            }
        }
        return picture(y: yf, cb: cbf, cr: crf, geometry: g)
    }

    /// Full-resolution Y′, Cb and Cr (`g.width` × `g.height`) as the picture
    /// the codec codes: padded to whole blocks, the color subsampled.
    static func picture(y yf: [Float], cb cbf: [Float], cr crf: [Float], geometry g: CodecGeometry) -> CodecPicture {
        let w = g.width, h = g.height
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

    /// A CCD's vertical smear, as light (linear) added to each column, or
    /// nil for none. While a frame is shifted down the chip to be read out,
    /// every pixel passes under every other pixel of its column and picks
    /// up a little of the light falling there, so a spot bright enough to
    /// matter shows as a streak the full height of the picture. Sources are
    /// footage already exposed, so "bright enough" is what sits at the clip
    /// (sRGB 235 and up, counted in full at white); the streak follows that
    /// column's share of such pixels, a pixel either side mixed in — by its
    /// square root, since how far over white the light really was is lost,
    /// and a lamp a few pixels tall was far further over than a sky filling
    /// a third of the frame. A dark scene makes it stronger, as Low-light
    /// noise's gain does: the camera has opened up, and the lamp is that
    /// much further over white.
    static func smear(_ bgra: [UInt8], width w: Int, height h: Int, strength: Float) -> [Float]? {
        guard strength > 0, w > 0, h > 0 else { return nil }
        var share = [Float](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let top = max(bgra[i], bgra[i + 1], bgra[i + 2])
                if top >= 235 { share[x] += Float(Int(top) - 234) / 21 }
            }
        }
        let gain = sensorGain(medianLuma: medianLuma(bgra, width: w, height: h))
        let scale = strength * 1.25 * (gain / 8).squareRoot()
        var out = [Float](repeating: 0, count: w)
        var any = false
        for x in 0..<w {
            let part = (share[max(0, x - 1)] + 2 * share[x] + share[min(w - 1, x + 1)]) / 4 / Float(h)
            let v = part.squareRoot() * scale
            out[x] = min(1, v)
            if v > 0 { any = true }
        }
        return any ? out : nil
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

    /// What the viewer gets of the decoder's picture: rendered, then put
    /// through the Generations control's further rounds of compression.
    static func present(_ decoded: CodecPicture, geometry g: CodecGeometry,
                        settings: DigitalSettings, step: Float) -> [UInt8] {
        var out = render(decoded, geometry: g, settings: settings, step: step)
        let generations = settings.generations
        if generations > 0 {
            for k in 1...generations { out = regenerate(out, geometry: g, settings: settings, generation: k) }
        }
        return out
    }

    /// One more generation: the decoded picture (BGRA at the capture size)
    /// compressed again at the same Quality, every frame on its own, and
    /// decoded — a video saved, cropped a little and uploaded again. The
    /// crop is what does the damage: compressing the same picture twice on
    /// the same blocks changes almost nothing the second time, but each
    /// generation's blocks fall a few pixels away from the last one's, so
    /// the old block edges are detail the new blocks have to spend on and
    /// get wrong. The offset depends only on the generation's number, so
    /// one more generation is one more pass on top of the same ones.
    static func regenerate(_ bgra: [UInt8], geometry g: CodecGeometry, settings: DigitalSettings,
                           generation k: Int) -> [UInt8] {
        let w = g.width, h = g.height
        // The grid to move against: the codec's blocks (Video 1's are 4×4).
        let grid = settings.codec == .dct ? g.block : 4
        let dx = 1 + (2 * k) % (grid - 1), dy = 1 + (4 * k + 1) % (grid - 1)
        // The picture with a margin, its content (dx, dy) in; the edge
        // pixels repeat into the margin.
        let padded = CodecGeometry(width: w + grid, height: h + grid, chroma: g.chroma, block: g.block)
        let pw = padded.width, ph = padded.height
        var yf = [Float](repeating: 0, count: pw * ph), cbf = yf, crf = yf
        bgra.withUnsafeBufferPointer { src in
            yf.withUnsafeMutableBufferPointer { yp in
                cbf.withUnsafeMutableBufferPointer { cbp in
                    crf.withUnsafeMutableBufferPointer { crp in
                        let s = src.baseAddress!, Y = yp.baseAddress!, CB = cbp.baseAddress!, CR = crp.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: ph) { y in
                            let sy = min(h - 1, max(0, y - dy))
                            for x in 0..<pw {
                                let i = (sy * w + min(w - 1, max(0, x - dx))) * 4
                                let b = Float(s[i]), gr = Float(s[i + 1]), r = Float(s[i + 2])
                                let o = y * pw + x
                                Y[o] = 0.299 * r + 0.587 * gr + 0.114 * b
                                CB[o] = 128 - 0.168736 * r - 0.331264 * gr + 0.5 * b
                                CR[o] = 128 + 0.5 * r - 0.418688 * gr - 0.081312 * b
                            }
                        }
                    }
                }
            }
        }
        let source = picture(y: yf, cb: cbf, cr: crf, geometry: padded)
        let coded: CodecPicture
        var step: Float = 0
        switch settings.codec {
        case .dct:
            let steps = DigitalCodec.Steps(quality: settings["quality"], squeeze: 1, block: g.block)
            coded = CodecPicture(geometry: padded)
            DigitalCodec.codeIntra(source, into: coded, steps: steps)
            step = steps.inter
        case .blockColors:
            coded = Video1Codec.step(CodecState(geometry: padded), source: source, kind: .key, index: 0,
                                     settings: .init(quality: settings["quality"], fixedBitrate: 0, dataLoss: 0))
        }
        let full = render(coded, geometry: padded, settings: settings, step: step)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        full.withUnsafeBufferPointer { fp in
            out.withUnsafeMutableBufferPointer { op in
                for y in 0..<h {
                    (op.baseAddress! + y * w * 4).update(from: fp.baseAddress! + ((y + dy) * pw + dx) * 4, count: w * 4)
                }
            }
        }
        return out
    }

    /// The decoder's picture as BGRA8 at the capture size: deblocked (on a
    /// copy — the reference stays as coded), color interpolated back up.
    static func render(_ decoded: CodecPicture, geometry g: CodecGeometry,
                       settings: DigitalSettings, step: Float) -> [UInt8] {
        var picture = decoded
        let deblocking = settings.effective("deblocking")
        if deblocking > 0 {
            picture = decoded.copy()
            DigitalCodec.deblock(picture, strength: deblocking, step: step, block: g.block)
        }
        let w = g.width, h = g.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let fx = Float(g.sx), fy = Float(g.sy)
        let cb = picture.cb, cr = picture.cr, luma = picture.y
        // Color decode, Blocky: each color sample repeated over the pixels
        // it stands for, instead of interpolated.
        let blocky = settings.effective("chroma_upsampling") >= 0.5
        out.withUnsafeMutableBufferPointer { op in
            let o = op.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let cyf = (Float(y) + 0.5) / fy - 0.5
                let cy0 = Int(cyf.rounded(.down)), ty = cyf - Float(cy0)
                for x in 0..<w {
                    let cxf = (Float(x) + 0.5) / fx - 0.5
                    let cx0 = Int(cxf.rounded(.down)), tx = cxf - Float(cx0)
                    func bil(_ p: CodecPlane) -> Float {
                        if blocky { return p.clamped(x / g.sx, y / g.sy) }
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

/// A 90s DV camcorder's tone, in its four real parts. One slider (CCD
/// response) sets all four today; each has its own strength here, so they
/// can become separate controls without changing what they do.
///
/// The constants are fitted, not published: across six reference frames of
/// VX1000 footage the darkest pixels sat at 20–45 (not 0), medians at
/// 130–210, and 10–32% of each frame piled up in the top bins, with warm
/// shots' red reaching white well before blue. (Sony's specs stop at the
/// sensor; measuring a real camera needs footage straight off its tape.)
struct CCDResponse {
    /// Auto exposure: how far the camera re-exposes the scene.
    var exposure: Float
    /// The knee and the clip: how hard highlights are squeezed.
    var highlights: Float
    /// Veiling flare from the lens.
    var flare: Float
    /// DV's levels shown as stored: black at 16, not 0.
    var levels: Float

    init(strength: Float) {
        exposure = strength; highlights = strength; flare = strength; levels = strength
    }

    var isOn: Bool { exposure > 0 || highlights > 0 || flare > 0 || levels > 0 }

    /// Auto exposure: bring the metered mean to a bright target — these
    /// cameras exposed for faces and shadows and let skies go. Stopping
    /// down is always possible. Opening up is only possible with the gain
    /// the camera has left: in a dark scene it is already wide open with
    /// its gain turned up (`sensorGain`, 1 in daylight to its top of 8 at
    /// night, the same measure Low-light noise uses), so a night scene
    /// stays night instead of being pushed up to gray daylight.
    static let target: Float = 0.40
    static let topGain: Float = 8
    func exposureGain(meteredMean m: Float, sensorGain: Float) -> Float {
        var full = min(4, max(0.5, Self.target / max(m, 1e-4)))
        if full > 1 { full = max(1, min(full, Self.topGain / max(1, sensorGain))) }
        return pow(full, exposure)
    }

    /// Veiling flare from a cheap lens (and the fisheye adapters these were
    /// shot through): a share of the whole frame's light scattered over
    /// everything, so bright scenes lift their shadows most.
    func flareLight(meteredMean m: Float) -> Float { 0.03 * flare * m }

    /// The knee: above it each channel is compressed, then clips at white.
    static let kneePoint: Float = 0.72 * 255
    var kneeSlope: Float { 1 - 0.62 * highlights }
    func knee(_ v: Float) -> Float {
        guard v > Self.kneePoint else { return v }
        return min(255, Self.kneePoint + (v - Self.kneePoint) * kneeSlope)
    }

    /// The light at which a channel clips, as a multiple of the source's
    /// white: where the knee's line reaches 255 (2.37 at full strength —
    /// 1.2 stops of highlights squeezed in above the knee).
    var clipLight: Float {
        let v = (Self.kneePoint + (255 - Self.kneePoint) / kneeSlope) / 255
        return pow((v + 0.055) / 1.055, 2.4)
    }

    /// What's white in the source was brighter than white: the camera that
    /// shot it clipped there, and a lamp or the sun is far over. Such
    /// pixels (from sRGB 235, in full at 255) are taken to be as far over
    /// as this camera's own clip, so they clip here too. Without this the
    /// knee, which makes room above white for highlights the source no
    /// longer has, would turn every lamp and white wall gray whenever the
    /// exposure isn't pushed up. Only what is near white counts (by the
    /// square of its lowest channel against its highest): one channel at
    /// the top is a saturated color, a blue sky or a red sign, not a
    /// blown highlight. Returns the factor on the pixel's light, from its
    /// highest and lowest channels (0–255).
    func recovered(top: Float, low: Float) -> Float {
        guard highlights > 0, top >= 235 else { return 1 }
        let t = min(1, (top - 234) / 21), white = low / top
        return 1 + (clipLight - 1) * t * t * white * white
    }

    /// Levels. DV stores black at 16 and white at 235 of 255, and the
    /// camera records on past white to its clip at about 109% (255). Shown
    /// on a computer as stored, without stretching that range back out,
    /// black is a milky gray (16 of 255, 6.3%), the picture keeps its
    /// highlights right up to 255, and color comes out a few percent weak
    /// (its range is 16–240). That is the lifted black of DV footage on
    /// the web — it was fitted first as a 6.5% "setup" lift; this is where
    /// the number comes from.
    var black: Float { 16 * levels }
    /// (The clip, 109% of white, lands on 255: luma spans 16…255.)
    var lumaScale: Float { 1 - levels * 16 / 255 }
    /// (Color's ±112 around 128 for 100%, so ±1.09 × 112 at the clip.)
    var chromaScale: Float { 1 - levels * (1 - 1.09 * 224 / 255) }
}
