import Foundation
import AVFoundation
import Metal
import CoreVideo
import CrtAppBridge

/// Background producer for video playback: decodes sequentially and runs the
/// NTSC stage on the CPU, feeding finished frames to the main thread through
/// a small bounded queue.
///
/// This is the standard player/NLE pipeline shape, and it exists for measured
/// reasons:
///
/// - Serial playback paid for every stage in sequence — decode + NTSC + GPU
///   round-trip syncs, ~45 ms a frame at 2 MP (21 fps against a 24 fps clip).
///   Pipelined, throughput is the slowest stage, not the sum.
/// - The old path uploaded decoded pixels to the GPU, then immediately
///   blitted them back (with a full `waitUntilCompleted`) for the CPU effect.
///   The decoder hands us CPU-visible pixels; here ntsc-rs runs directly on
///   them, in place, inside MTLBuffer-backed texture memory — one stride-aware
///   copy total, no upload step.
/// - One NTSC pass at 2 MP costs ~35 ms — too close to a 41.7 ms frame budget
///   to ever build a cushion. Two filter instances process alternating frames
///   concurrently (ntsc-rs is deterministic per (settings, frameIndex), so
///   frames are independent).
///
/// librashader's main-thread constraint applies to the shader chain only; the
/// NTSC filter instances here never touch Metal command encoding.
public final class PlaybackPipeline {

    /// One finished frame. `clean` is the decoded image (zero-copy, backed by
    /// `retain`); `processed` has the NTSC stage baked in, nil when the stage
    /// is disabled or failed.
    public struct Output {
        public let clean: MTLTexture
        public let processed: MTLTexture?
        /// Frame number within the clip.
        public let frameIndex: Int
        /// Monotonic across loop wraps, for real-time scheduling.
        public let absoluteIndex: Int
        public let generation: Int
        let retain: CVPixelBuffer
    }

    /// NTSC settings snapshot, updated from the main thread when the user
    /// edits values. Bumping the generation invalidates queued frames.
    public final class Config {
        private let lock = NSLock()
        private var enabled: Bool
        private var baseJSON: String?
        /// Per-frame settings for keyframed playback (frame index → JSON).
        private var perFrameJSON: (@Sendable (Int) -> String?)?
        private var generation: Int

        public init(enabled: Bool, baseJSON: String?,
                    perFrameJSON: (@Sendable (Int) -> String?)?,
                    generation: Int) {
            self.enabled = enabled
            self.baseJSON = baseJSON
            self.perFrameJSON = perFrameJSON
            self.generation = generation
        }

        public func update(enabled: Bool, baseJSON: String?,
                           perFrameJSON: (@Sendable (Int) -> String?)?,
                           generation: Int) {
            lock.lock()
            self.enabled = enabled
            self.baseJSON = baseJSON
            self.perFrameJSON = perFrameJSON
            self.generation = generation
            lock.unlock()
        }

        func snapshot() -> (enabled: Bool, baseJSON: String?,
                            perFrameJSON: (@Sendable (Int) -> String?)?,
                            generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (enabled, baseJSON, perFrameJSON, generation)
        }
    }

    private final class BoundedQueue {
        private let cond = NSCondition()
        private var buffer: [Output] = []
        private var closed = false
        private let capacity: Int

        init(capacity: Int) { self.capacity = capacity }

        /// Blocks while full — this is the producer's backpressure.
        func push(_ o: Output) -> Bool {
            cond.lock()
            while buffer.count >= capacity && !closed { cond.wait() }
            if closed { cond.unlock(); return false }
            buffer.append(o)
            cond.broadcast()
            cond.unlock()
            return true
        }

        /// The frame due at `schedule` (or the newest one before it), leaving
        /// frames that are still in the future queued for later ticks —
        /// taking those early would eat the producer's whole ahead-buffer as
        /// "drops" and collapse the pipeline's cushion. Superseded and
        /// stale-generation frames are discarded and counted. Non-blocking;
        /// nil means nothing due yet.
        struct TakeStats { var staleGen = 0; var superseded = 0; var emptyTakes = 0; var futureOnly = 0; var takes = 0 }
        var stats = TakeStats()

        func takeReady(schedule: Int, generation: Int) -> (output: Output?, dropped: Int) {
            cond.lock()
            defer { cond.broadcast(); cond.unlock() }
            guard !buffer.isEmpty else { stats.emptyTakes += 1; return (nil, 0) }
            var dropped = 0
            // Throw away frames from before a settings change outright.
            let fresh = buffer.filter { $0.generation == generation }
            dropped += buffer.count - fresh.count
            stats.staleGen += buffer.count - fresh.count
            let due = fresh.filter { $0.absoluteIndex <= schedule }
            let future = fresh.filter { $0.absoluteIndex > schedule }
            buffer = future
            guard let take = due.last else { stats.futureOnly += 1; return (nil, dropped) }
            dropped += due.count - 1        // superseded by a newer due frame
            stats.superseded += due.count - 1
            stats.takes += 1
            return (take, dropped)
        }

        func statsLine() -> String {
            let s = stats; stats = TakeStats()
            return "takes \(s.takes) emptyQ \(s.emptyTakes) futureOnly \(s.futureOnly) staleGen \(s.staleGen) superseded \(s.superseded)"
        }

        /// True once at least one frame is available (used to prime the
        /// consumer's clock, so the schedule doesn't start running before
        /// anything exists to show).
        func hasOutput() -> Bool {
            cond.lock(); defer { cond.unlock() }
            return !buffer.isEmpty
        }

        func peekFirstAbsoluteIndex() -> Int? {
            cond.lock(); defer { cond.unlock() }
            return buffer.first?.absoluteIndex
        }

        func close() {
            cond.lock()
            closed = true
            buffer.removeAll()
            cond.broadcast()
            cond.unlock()
        }
    }

    public let config: Config
    private let source: VideoSource
    private let device: MTLDevice
    private let queue: BoundedQueue
    private let startFrame: Int
    private let stopFlag = ManagedAtomic(false)
    /// The consumer's current schedule position; frames behind it skip the
    /// (expensive) NTSC step so the producer catches up at decode cost.
    private let targetAbsolute = ManagedAtomicInt(0)
    private let poolDepth: Int

    public init(source: VideoSource, device: MTLDevice,
                startFrame: Int, config: Config, queueDepth: Int = 3) {
        self.source = source
        self.device = device
        self.config = config
        self.queue = BoundedQueue(capacity: queueDepth)
        self.startFrame = max(0, startFrame)
        // Queue depth + on-screen + previous + the two lanes being written.
        self.poolDepth = queueDepth + 5
    }

    public func setTargetAbsoluteIndex(_ i: Int) { targetAbsolute.store(i) }

    public func takeReady(schedule: Int, generation: Int) -> (output: Output?, dropped: Int) {
        queue.takeReady(schedule: schedule, generation: generation)
    }

    public func hasOutput() -> Bool { queue.hasOutput() }
    public func takeStatsLine() -> String { queue.statsLine() }
    public func firstQueuedIndex() -> Int? { queue.peekFirstAbsoluteIndex() }

    public func stop() {
        stopFlag.store(true)
        queue.close()
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "ntscrt.playback.producer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - producer thread

    static let perfLog = ProcessInfo.processInfo.environment["CRT_PERF_LOG"] != nil

    private func run() {
        let filter = NTSCFilter()
        // Two filter instances process alternating frames concurrently; each
        // is used by exactly one lane of a batch at a time.
        let filters: [NTSCFilter?] = [filter, filter == nil ? nil : NTSCFilter()]
        var appliedJSON: [String?] = [nil, nil]
        var reader = try? source.makeSequentialReader(startingAtFrame: startFrame)
        var frameIndex = startFrame
        var absolute = startFrame
        let total = max(1, source.totalFrames)
        var perf = (decode: 0.0, ntsc: 0.0, push: 0.0, n: 0)
        func ms(_ from: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - from) / 1_000_000
        }

        struct Pending {
            let frame: VideoSource.SequentialReader.Frame
            let frameIndex: Int
            let absolute: Int
            let generation: Int
            let json: String?
            let wantsNtsc: Bool
        }

        while !stopFlag.load() {
            // Decode up to two frames for one parallel batch.
            var batch: [Pending] = []
            let tDecode = DispatchTime.now().uptimeNanoseconds
            while batch.count < 2 && !stopFlag.load() {
                guard let r = reader else { return }
                guard let frame = r.nextFrame() else {
                    reader = try? source.makeSequentialReader(startingAtFrame: 0)
                    frameIndex = 0
                    continue
                }
                // Frames already behind the consumer's schedule get dropped
                // on arrival — decode them (h264 needs the sequence) but skip
                // the NTSC cost, so catch-up runs at decode speed.
                let hopeless = targetAbsolute.load() - absolute > 0
                if !hopeless {
                    let snap = config.snapshot()
                    batch.append(Pending(frame: frame,
                                         frameIndex: frameIndex,
                                         absolute: absolute,
                                         generation: snap.generation,
                                         json: snap.perFrameJSON?(frameIndex) ?? snap.baseJSON,
                                         wantsNtsc: snap.enabled))
                }
                frameIndex = (frameIndex + 1) % total
                absolute += 1
                // Don't wait around assembling a pair while the consumer is
                // starved — ship a single immediately at startup/after seeks.
                if batch.count == 1 && !queue.hasOutput() { break }
            }
            if batch.isEmpty { continue }
            let decodeMs = ms(tDecode)

            // Process concurrently, one filter lane per frame. Slots are
            // MTLBuffer-backed textures: ntsc-rs runs in place inside texture
            // memory, so there's no upload afterwards.
            let tNtsc = DispatchTime.now().uptimeNanoseconds
            var slots: [PoolSlot?] = batch.map { p in
                p.wantsNtsc ? preparedSlot(for: p.frame) : nil
            }
            if batch.contains(where: { $0.wantsNtsc }) {
                let batchCopy = batch
                slots.withUnsafeMutableBufferPointer { slotsPtr in
                    DispatchQueue.concurrentPerform(iterations: batchCopy.count) { i in
                        guard batchCopy[i].wantsNtsc,
                              let f = filters[i],
                              let slot = slotsPtr[i] else { return }
                        if let json = batchCopy[i].json, json != appliedJSON[i] {
                            try? f.setSettingsJSON(json)
                            appliedJSON[i] = json
                        }
                        if !f.processBGRA8(slot.bytes, width: UInt(slot.width),
                                           height: UInt(slot.height),
                                           rowBytes: UInt(slot.rowBytes),
                                           frameIndex: batchCopy[i].frameIndex + 1) {
                            slotsPtr[i] = nil
                        }
                    }
                }
            }
            let ntscMs = ms(tNtsc)

            // Emit in order.
            let tPush = DispatchTime.now().uptimeNanoseconds
            for (i, p) in batch.enumerated() {
                let out = Output(clean: p.frame.texture,
                                 processed: slots[i]?.texture,
                                 frameIndex: p.frameIndex,
                                 absoluteIndex: p.absolute,
                                 generation: p.generation,
                                 retain: p.frame._retain)
                if !queue.push(out) { return }
            }
            if Self.perfLog {
                perf.decode += decodeMs
                perf.ntsc += ntscMs
                perf.push += ms(tPush)
                perf.n += batch.count
                if perf.n >= 48 {
                    let batches = max(1.0, Double(perf.n) / 2)
                    FileHandle.standardError.write(Data(String(
                        format: "[producer] per 2-frame batch: decode %.1f  ntsc(parallel) %.1f  push-wait %.1f ms\n",
                        perf.decode / batches, perf.ntsc / batches, perf.push / batches).utf8))
                    perf = (0, 0, 0, 0)
                }
            }
        }
    }

    // MARK: - buffer-backed texture pool

    /// A pool texture whose storage is an MTLBuffer: the CPU writes decoded
    /// pixels straight into texture memory and ntsc-rs processes them in
    /// place — one copy total, no upload step.
    struct PoolSlot {
        let buffer: MTLBuffer
        let texture: MTLTexture
        let width: Int
        let height: Int
        let rowBytes: Int
        var bytes: UnsafeMutableRawPointer { buffer.contents() }
    }

    private var slotPool: [PoolSlot] = []
    private var slotIndex = 0
    private let slotLock = NSLock()

    /// Copy the decoded frame into the next pool slot (stride-aware).
    private func preparedSlot(for frame: VideoSource.SequentialReader.Frame) -> PoolSlot? {
        let pb = frame._retain
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let slot = nextSlot(width: w, height: h) else { return nil }
        if srcRowBytes == slot.rowBytes {
            memcpy(slot.bytes, base, srcRowBytes * h)
        } else {
            for y in 0..<h {
                memcpy(slot.bytes.advanced(by: y * slot.rowBytes),
                       base.advanced(by: y * srcRowBytes), w * 4)
            }
        }
        return slot
    }

    private func nextSlot(width: Int, height: Int) -> PoolSlot? {
        slotLock.lock()
        defer { slotLock.unlock() }
        if slotPool.first?.width != width || slotPool.first?.height != height {
            slotPool.removeAll()
            slotIndex = 0
        }
        if slotPool.count < poolDepth {
            // Buffer-backed textures need 256-byte-aligned rows.
            let rowBytes = (width * 4 + 255) & ~255
            guard let buf = device.makeBuffer(length: rowBytes * height,
                                              options: .storageModeShared) else { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let tex = buf.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else {
                return nil
            }
            let slot = PoolSlot(buffer: buf, texture: tex,
                                width: width, height: height, rowBytes: rowBytes)
            slotPool.append(slot)
            return slot
        }
        slotIndex = (slotIndex + 1) % poolDepth
        return slotPool[slotIndex]
    }
}

// MARK: - tiny atomics (no external dependency)

final class ManagedAtomic {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

final class ManagedAtomicInt {
    private let lock = NSLock()
    private var value: Int
    init(_ v: Int) { value = v }
    func load() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ v: Int) { lock.lock(); value = v; lock.unlock() }
}
