import Foundation
import Metal
import MetalPerformanceShaders
import CoreGraphics
import CoreText
import CrtAppBridge

// MARK: - parameters

/// One knob of the howlaround camera: a camcorder pointed at the TV that is
/// showing the camcorder's own picture. Every knob is something you could
/// do to the real setup — move or turn the camera, defocus it, turn the
/// TV's brightness up, hold the camera in your hand.
public struct HowlaroundParam: Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case framing = "Framing"
        case movement = "Movement"
        case camera = "Camera"
        case feedback = "Feedback"
    }
    public enum Kind: Equatable, Sendable {
        case slider(min: Double, max: Double, percent: Bool, unit: String, step: Double?)
        case toggle
        /// A direction in degrees: 0 right, 90 up, 180 left, 270 down.
        case direction
    }
    /// For knobs either side of a neutral middle: the words for each side,
    /// so a value reads "20% left" rather than "−20%".
    public struct Sides: Equatable, Sendable {
        public let negative: String
        public let positive: String
        public let zero: String
    }
    /// For knobs that run from none to a lot: what each end of the slider means.
    public struct Ends: Equatable, Sendable {
        public let low: String
        public let high: String
    }
    public let id: String
    public let label: String
    public let group: Group
    public let kind: Kind
    /// Where a new howlaround starts: a tunnel worth looking at.
    public let defaultValue: Double
    /// Where the knob's effect is weakest — what a double-click goes to.
    public let neutralValue: Double
    public var sides: Sides? = nil
    public var ends: Ends? = nil
    public let help: String

    init(id: String, label: String, group: Group, kind: Kind, defaultValue: Double,
         neutralValue: Double, sides: Sides? = nil, ends: Ends? = nil, help: String) {
        self.id = id
        self.label = label
        self.group = group
        self.kind = kind
        self.defaultValue = defaultValue
        self.neutralValue = neutralValue
        self.sides = sides
        self.ends = ends
        self.help = help
    }

    /// How a value reads: its size in the knob's units and the word for its
    /// side ("20", "% right"), or the knob's word for the middle at zero.
    public func reading(_ value: Double) -> (magnitude: Double, side: String) {
        guard let sides else { return (value, "") }
        if abs(value) < 1e-9 { return (0, sides.zero) }
        return (abs(value), value < 0 ? sides.negative : sides.positive)
    }

    /// The compass word for a direction ("up-right").
    public static func compass(_ degrees: Double) -> String {
        let names = ["right", "up-right", "up", "up-left", "left", "down-left", "down", "down-right"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / 45).rounded()) % 8
        return names[i]
    }

    public static let all: [HowlaroundParam] = [
        HowlaroundParam(
            id: "zoom", label: "Zoom", group: .framing,
            kind: .slider(min: 0, max: 1.4, percent: true, unit: "", step: nil),
            defaultValue: 0.5, neutralValue: 0, ends: Ends(low: "Wide", high: "Close"),
            help: "How big the TV's screen is in the camera's frame. Below 100% each copy of the picture is smaller than the last — a tunnel, with more copies the closer you get to 100%. Above 100% the screen overfills the frame and every pass grows instead, into the swirling patterns feedback is known for. 0% points the camera away from the TV."),
        HowlaroundParam(
            id: "aim_x", label: "Left – right", group: .framing,
            kind: .slider(min: -0.5, max: 0.5, percent: true, unit: "", step: nil),
            defaultValue: 0.2, neutralValue: 0,
            sides: Sides(negative: "left", positive: "right", zero: "centre"),
            help: "Where the TV sits across the camera's frame. Off-centre, every pass shifts the picture again, so the tunnel recedes to that side."),
        HowlaroundParam(
            id: "aim_y", label: "Up – down", group: .framing,
            kind: .slider(min: -0.5, max: 0.5, percent: true, unit: "", step: nil),
            defaultValue: -0.18, neutralValue: 0,
            sides: Sides(negative: "up", positive: "down", zero: "centre"),
            help: "Where the TV sits up and down the camera's frame."),
        HowlaroundParam(
            id: "roll", label: "Roll", group: .framing,
            kind: .slider(min: -45, max: 45, percent: false, unit: "°", step: nil),
            defaultValue: 0, neutralValue: 0,
            sides: Sides(negative: "anticlockwise", positive: "clockwise", zero: "level"),
            help: "The TV turned against the camera. Every pass turns the picture again, so the tunnel becomes a spiral."),
        HowlaroundParam(
            id: "turn", label: "Side angle", group: .framing,
            kind: .slider(min: -45, max: 45, percent: false, unit: "°", step: nil),
            defaultValue: -10, neutralValue: 0,
            sides: Sides(negative: "from the left", positive: "from the right", zero: "straight on"),
            help: "The camera looking at the screen from one side, so the screen's far edge is narrower. Every pass skews the picture again."),
        HowlaroundParam(
            id: "tilt", label: "Vertical angle", group: .framing,
            kind: .slider(min: -45, max: 45, percent: false, unit: "°", step: nil),
            defaultValue: 0, neutralValue: 0,
            sides: Sides(negative: "from below", positive: "from above", zero: "straight on"),
            help: "The camera looking at the screen from above or below."),

        HowlaroundParam(
            id: "shake", label: "Handheld", group: .movement,
            kind: .slider(min: 0, max: 1, percent: true, unit: "", step: nil),
            defaultValue: 0.4, neutralValue: 0, ends: Ends(low: "Tripod", high: "Shaky"),
            help: "The camera operator's hands: a slow sway with a little tremor. Every copy is one trip round the loop older than the one around it, so the tunnel follows the camera a moment late and snakes."),
        HowlaroundParam(
            id: "take", label: "Take", group: .movement,
            kind: .slider(min: 1, max: 20, percent: false, unit: "", step: 1),
            defaultValue: 1, neutralValue: 1,
            help: "Which performance of the handheld shake. The same take always moves the same way — so the draft matches the render, and a take you like can always be found again."),
        HowlaroundParam(
            id: "drift_dir", label: "Drift direction", group: .movement,
            kind: .direction,
            defaultValue: 0, neutralValue: 0,
            help: "Which way the TV slides across the frame over the render."),
        HowlaroundParam(
            id: "drift", label: "Drift", group: .movement,
            kind: .slider(min: 0, max: 0.5, percent: true, unit: "", step: nil),
            defaultValue: 0, neutralValue: 0, ends: Ends(low: "None", high: "Half the frame"),
            help: "How far the TV slides across the frame over the render, easing in and out — from where the framing knobs put it."),
        HowlaroundParam(
            id: "push", label: "Push", group: .movement,
            kind: .slider(min: -0.5, max: 0.5, percent: true, unit: "", step: nil),
            defaultValue: 0, neutralValue: 0,
            sides: Sides(negative: "out", positive: "in", zero: "no push"),
            help: "Zooming in or out over the render, from the Zoom you set."),
        HowlaroundParam(
            id: "spin", label: "Spin", group: .movement,
            kind: .slider(min: -180, max: 180, percent: false, unit: "°", step: nil),
            defaultValue: 0, neutralValue: 0,
            sides: Sides(negative: "anticlockwise", positive: "clockwise", zero: "no spin"),
            help: "Rolling the camera over the render, from the Roll you set."),
        HowlaroundParam(
            id: "loop", label: "Seamless loop", group: .movement,
            kind: .toggle,
            defaultValue: 0, neutralValue: 0,
            help: "The move goes out and comes back, and the shake repeats over the length — so the file loops without a jump. Made for GIFs."),

        HowlaroundParam(
            id: "focus", label: "Softness", group: .camera,
            kind: .slider(min: 0, max: 1, percent: true, unit: "", step: nil),
            defaultValue: 0.2, neutralValue: 0, ends: Ends(low: "Sharp", high: "Soft"),
            help: "The camera's focus on the screen. A little softness on every pass melts the deep copies first; sharp focus keeps the moiré of the screen's dot pattern."),
        HowlaroundParam(
            id: "brightness", label: "Screen brightness", group: .camera,
            kind: .slider(min: 0.5, max: 1.5, percent: true, unit: "", step: nil),
            defaultValue: 1.0, neutralValue: 1.0, ends: Ends(low: "Fades to black", high: "Burns to white"),
            help: "How bright the TV looks to the camera — the loop's gain. Below 100% the deep copies fade to black; above, they burn to white."),
        HowlaroundParam(
            id: "contrast", label: "Contrast", group: .camera,
            kind: .slider(min: 0.6, max: 1.6, percent: true, unit: "", step: nil),
            defaultValue: 1.05, neutralValue: 1.0, ends: Ends(low: "Flatter", high: "Harsher"),
            help: "The TV's contrast as the camera sees it, applied again on every pass — so the deep copies get harsher (or flatter) than the outer ones."),
        HowlaroundParam(
            id: "colour_drift", label: "Colour drift", group: .camera,
            kind: .slider(min: -1, max: 1, percent: true, unit: "", step: nil),
            defaultValue: -0.3, neutralValue: 0,
            sides: Sides(negative: "cool", positive: "warm", zero: "neutral"),
            help: "The camera's white balance against the TV's colour temperature. The tint compounds on every pass: cool turns the deep copies teal and blue, warm turns them orange."),
        HowlaroundParam(
            id: "hue_drift", label: "Hue drift", group: .camera,
            kind: .slider(min: -30, max: 30, percent: false, unit: "° per pass", step: nil),
            defaultValue: 0, neutralValue: 0,
            help: "A tint error that turns the hue a little on every pass, so the tunnel cycles through the colours."),
        HowlaroundParam(
            id: "auto_exposure", label: "Auto exposure", group: .camera,
            kind: .slider(min: 0, max: 1, percent: true, unit: "", step: nil),
            defaultValue: 0, neutralValue: 0, ends: Ends(low: "Off", high: "Hunting"),
            help: "The camcorder's automatic exposure. It reacts to the brightness of its own picture a moment late, so the whole loop pulses."),

        HowlaroundParam(
            id: "mix", label: "Picture mix", group: .feedback,
            kind: .slider(min: 0, max: 1, percent: true, unit: "", step: nil),
            defaultValue: 0, neutralValue: 0, ends: Ends(low: "Camera only", high: "Your picture"),
            help: "A video mixer between the camera and the TV, fading your picture in over the camera's. At 0% the TV shows only what the camera sees, and your picture is just the room around the TV. Turned up, your picture is laid over every copy, so it echoes all the way down the tunnel."),
        HowlaroundParam(
            id: "delay", label: "Delay", group: .feedback,
            kind: .slider(min: 1, max: 4, percent: false, unit: "frames", step: 1),
            defaultValue: 1, neutralValue: 1,
            help: "How long one trip around the loop takes. Each copy is that much older than the one around it, so anything moving — the camera included — echoes down the tunnel."),
        HowlaroundParam(
            id: "counter", label: "Camcorder counter", group: .feedback,
            kind: .toggle,
            defaultValue: 0, neutralValue: 0,
            help: "The camcorder's elapsed-time counter, burned into its picture — so it's filmed again with everything else and repeats down the tunnel."),
    ]

    public static var defaultValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultValue) })
    }
}

/// Where the camera is at one moment: the framing knobs plus the move and
/// the operator's hands. Angles in degrees.
public struct HowlaroundPose: Equatable, Sendable {
    public var zoom: Double
    public var aimX: Double
    public var aimY: Double
    public var roll: Double
    public var turn: Double
    public var tilt: Double
}

/// The howlaround camera's settings, with the derived quantities the
/// simulation uses.
public struct HowlaroundSettings: Equatable, Sendable {
    public var values: [String: Double]

    public init(values: [String: Double] = HowlaroundParam.defaultValues) {
        self.values = HowlaroundParam.defaultValues.merging(values) { _, new in new }
    }

    public subscript(id: String) -> Double {
        values[id] ?? HowlaroundParam.all.first { $0.id == id }?.defaultValue ?? 0
    }

    public var zoom: Double { max(0, self["zoom"]) }
    /// Zero zoom: the camera sees the room only, so the picture is exactly
    /// the scene and nothing feeds back.
    public var tvInView: Bool { zoom > 0.001 }
    public var delay: Int { max(1, min(4, Int(self["delay"].rounded()))) }
    public var counter: Bool { self["counter"] >= 0.5 }
    public var loop: Bool { self["loop"] >= 0.5 }
    public var take: Int { max(1, Int(self["take"].rounded())) }

    /// The framing knobs alone, before any movement.
    public var basePose: HowlaroundPose {
        HowlaroundPose(zoom: zoom, aimX: self["aim_x"], aimY: self["aim_y"],
                       roll: self["roll"], turn: self["turn"], tilt: self["tilt"])
    }

    /// Where the camera is `t` seconds into a render `length` seconds long:
    /// the framing knobs, then the move (eased from start to end, or out and
    /// back for a loop), then the operator's hands. Defined for negative `t`
    /// too — the run-up before the first frame — where a loop wraps round
    /// (so the tunnel at frame one is the one the last frame leads into) and
    /// a one-way move holds its start while the hands keep moving.
    public func pose(at t: Double, length: Double) -> HowlaroundPose {
        var p = basePose
        guard tvInView else { return p }
        let L = max(0.1, length)
        let m: Double
        if loop {
            let s = sin(Double.pi * t / L)
            m = s * s
        } else {
            let x = min(1, max(0, t / L))
            m = x * x * (3 - 2 * x)
        }
        let dir = self["drift_dir"] * Double.pi / 180
        p.aimX += self["drift"] * m * cos(dir)
        p.aimY -= self["drift"] * m * sin(dir)          // up is towards −y
        p.zoom *= max(0.05, 1 + self["push"] * m)
        p.roll += self["spin"] * m
        let shake = self["shake"]
        if shake > 0 {
            let hands = HowlaroundHands(take: take, period: loop ? L : nil)
            p.aimX += shake * 0.050 * hands.value(0, t)
            p.aimY += shake * 0.045 * hands.value(1, t)
            p.turn += shake * 6.0 * hands.value(2, t)
            p.tilt += shake * 4.5 * hands.value(3, t)
            p.roll += shake * 3.5 * hands.value(4, t)
            p.zoom *= 1 + shake * 0.06 * hands.value(5, t)
        }
        return p
    }

    /// The screen's axes and centre in camera space (image plane at z = 1,
    /// frame height 1 and width `aspect`, y down) for a pose. The camera
    /// stays put and the TV turns, so the room — the scene — always fills
    /// the frame.
    static func screen(_ pose: HowlaroundPose, aspect: Double)
        -> (ax: SIMD3<Double>, ay: SIMD3<Double>, n: SIMD3<Double>, c: SIMD3<Double>) {
        let deg = Double.pi / 180
        let yaw = max(-60, min(60, pose.turn)) * deg
        let pitch = max(-60, min(60, pose.tilt)) * deg
        let roll = pose.roll * deg
        func ry(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(cos(yaw) * v.x + sin(yaw) * v.z, v.y, -sin(yaw) * v.x + cos(yaw) * v.z)
        }
        func rx(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(v.x, cos(pitch) * v.y - sin(pitch) * v.z, sin(pitch) * v.y + cos(pitch) * v.z)
        }
        func rz(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(cos(roll) * v.x - sin(roll) * v.y, sin(roll) * v.x + cos(roll) * v.y, v.z)
        }
        func r(_ v: SIMD3<Double>) -> SIMD3<Double> { ry(rx(rz(v))) }
        let centre = SIMD3(pose.aimX * aspect, pose.aimY, 1)
        return (r(SIMD3(1, 0, 0)), r(SIMD3(0, 1, 0)), r(SIMD3(0, 0, 1)), centre)
    }

    /// Where a point of the TV picture (0…1 each way) lands in the camera's
    /// frame (0…1) for a pose, or nil behind the camera.
    static func cameraPoint(tv s: SIMD2<Double>, pose: HowlaroundPose, aspect: Double) -> SIMD2<Double>? {
        let (ax, ay, _, c) = screen(pose, aspect: aspect)
        let p = c + (s.x - 0.5) * pose.zoom * aspect * ax + (s.y - 0.5) * pose.zoom * ay
        guard p.z > 1e-4 else { return nil }
        return SIMD2(p.x / p.z / aspect + 0.5, p.y / p.z + 0.5)
    }

    func cameraPoint(tv s: SIMD2<Double>, aspect: Double) -> SIMD2<Double>? {
        Self.cameraPoint(tv: s, pose: basePose, aspect: aspect)
    }

    /// How many nested copies of the picture are visible at the framing
    /// knobs' pose: the frame mapped through the camera again and again until
    /// the copy is smaller than a couple of scan lines or out of frame. nil
    /// when the copies grow instead (the screen overfills the frame).
    public func visibleCopies(aspect: Double, chainHeight: Int) -> Int? {
        guard tvInView else { return 0 }
        var quad = [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        var lastSize = 1.0
        for level in 1...200 {
            var next: [SIMD2<Double>] = []
            for p in quad {
                guard let q = cameraPoint(tv: p, aspect: aspect) else { return level - 1 }
                next.append(q)
            }
            quad = next
            let xs = quad.map(\.x), ys = quad.map(\.y)
            let size = max((xs.max()! - xs.min()!) * aspect, ys.max()! - ys.min()!)
            if level > 3 && size > lastSize * 0.995 { return nil }
            lastSize = size
            let outside = xs.max()! < 0 || xs.min()! > 1 || ys.max()! < 0 || ys.min()! > 1
            if outside || size * Double(chainHeight) < 2 { return level - 1 }
        }
        return 200
    }

    /// Passes to run before the first frame is written, so it already shows
    /// the whole tunnel (one more copy appears per trip round the loop).
    public func runUpFrames(aspect: Double, chainHeight: Int) -> Int {
        guard tvInView else { return 0 }
        let copies = visibleCopies(aspect: aspect, chainHeight: chainHeight) ?? 60
        let settle = self["auto_exposure"] > 0 ? 30 : 0
        return max(4 * delay, min(300, delay * (copies + 4) + settle))
    }
}

/// The camera operator's hands: per axis, a slow sway (a few incommensurate
/// sinusoids around 0.15–0.7 Hz) with a little tremor (4–7 Hz), the same for
/// the same take. With a `period` every frequency is rounded to a whole
/// number of cycles over it, so the motion repeats exactly — a seamless loop.
/// `value` stays mostly within ±1.
struct HowlaroundHands {
    private var parts: [[(f: Double, phase: Double, amp: Double)]] = []

    init(take: Int, period: Double?) {
        let seed = UInt64(take)
        func snap(_ f: Double) -> Double {
            guard let period else { return f }
            return max(1, (f * period).rounded()) / period
        }
        for axis in 0..<6 {
            var p: [(Double, Double, Double)] = []
            var power = 0.0
            for k in 0..<3 {
                let u = GlitchRandom.uniform(seed, 900 + UInt64(axis), Int64(k))
                let v = GlitchRandom.uniform(seed, 920 + UInt64(axis), Int64(k))
                let w = GlitchRandom.uniform(seed, 940 + UInt64(axis), Int64(k))
                let amp = 0.5 + 0.5 * w
                p.append((snap(0.15 + 0.55 * u), 2 * Double.pi * v, amp))
                power += amp * amp / 2
            }
            // Normalise the sway to an RMS of 0.45, then add the tremor.
            let scale = 0.45 / power.squareRoot()
            p = p.map { ($0.0, $0.1, $0.2 * scale) }
            for k in 0..<2 {
                let u = GlitchRandom.uniform(seed, 960 + UInt64(axis), Int64(k))
                let v = GlitchRandom.uniform(seed, 980 + UInt64(axis), Int64(k))
                p.append((snap(4 + 3 * u), 2 * Double.pi * v, 0.02))
            }
            parts.append(p)
        }
    }

    func value(_ axis: Int, _ t: Double) -> Double {
        parts[axis].reduce(0) { $0 + $1.amp * sin(2 * Double.pi * $1.f * t + $1.phase) }
    }
}

/// Thread-safe flag for stopping a render early (a draft superseded by the
/// next one).
public final class HowlaroundCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// A howlaround render: the camera's settings plus how the render runs.
public struct HowlaroundRender: Sendable {
    public var settings: HowlaroundSettings
    /// The whole render's length in seconds — what a move spans and a loop
    /// repeats over. A draft covering only the start still uses the full
    /// length, so it shows the start of the same move.
    public var length: Double
    /// Stop after this many written frames (drafts).
    public var frameLimit: Int?
    public var cancel: HowlaroundCancel?
    public init(settings: HowlaroundSettings, length: Double, frameLimit: Int? = nil,
                cancel: HowlaroundCancel? = nil) {
        self.settings = settings
        self.length = length
        self.frameLimit = frameLimit
        self.cancel = cancel
    }
}

// MARK: - the loop

/// Where the TV's picture is drawn for the camera to film next time round:
/// the same chain input as the exported frame, through its own copy of the
/// CRT chain, at a fixed size — so the loop looks the same whatever size the
/// export (or the draft) is.
public struct HowlaroundFeedback {
    let chain: LRShaderChain?
    let bypass: ShaderBypass
    let texture: MTLTexture

    func render(into cb: MTLCommandBuffer, pipeline: Pipeline, input: MTLTexture,
                downscale: DownscaleSpec?, frameCount: Int) throws {
        if let chain {
            try pipeline.encode(into: cb, chain: chain, inputTexture: input, outputTexture: texture,
                                downscale: downscale, frameCount: frameCount)
        } else {
            try bypass.encode(into: cb, inputTexture: input, outputTexture: texture,
                              downscale: downscale)
        }
    }
}

/// Video feedback ("howlaround"): a camcorder pointed at the TV that shows
/// the camcorder's own picture. Each frame the camera films the room — the
/// scene — with the TV in it, showing what the TV displayed a frame (or a
/// few) ago; that picture then goes through the whole chain (NTSC, the
/// receiver, the CRT) and onto the TV for the next pass. The nth copy in the
/// tunnel has been through everything n times, so the degradation compounds
/// the way it does in the real loop. Depth comes from time, not from extra
/// work per frame: one pass of the chain per frame, plus the camera.
public final class HowlaroundLoop: @unchecked Sendable {
    public let render: HowlaroundRender
    public var settings: HowlaroundSettings { render.settings }
    private let context: MetalContext
    private let feedbackChain: LRShaderChain?
    private let bypass: ShaderBypass
    private let ring: [MTLTexture]
    private let cameraPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let mean: MPSImageStatisticsMean
    private let meanCamera: MTLTexture
    private let meanScene: MTLTexture
    private var camera: MTLTexture?
    private var blurA: MTLTexture?
    private var blurB: MTLTexture?
    private var counterTexture: MTLTexture?
    private var counterText = ""
    private var counterAspect = 1.0
    private var frame = 0
    private var exposure = 1.0
    private var measured = false
    /// The fixed size the TV's picture is drawn at for the camera.
    public let feedbackSize: (width: Int, height: Int)
    public let chainInputSize: (width: Int, height: Int)

    public var isCancelled: Bool { render.cancel?.isCancelled ?? false }

    public init(context: MetalContext, render: HowlaroundRender, presetPath: String,
                shaderEnabled: Bool, paramValues: [String: Float],
                chainInputSize: (width: Int, height: Int)) throws {
        self.context = context
        self.render = render
        self.chainInputSize = chainInputSize
        let device = context.device
        if shaderEnabled {
            let c = try LRShaderChain(presetPath: presetPath, commandQueue: context.queue)
            for (n, v) in paramValues { try? c.setParameter(n, value: v) }
            feedbackChain = c
        } else {
            feedbackChain = nil
        }
        bypass = ShaderBypass(context: context)

        // A whole, even multiple of the chain input (odd multiples make the
        // glow shaders' scanlines jitter), about 1280 wide, at most ~2048.
        let w = max(1, chainInputSize.width), h = max(1, chainInputSize.height)
        var k = max(2, 2 * Int((640.0 / Double(w)).rounded(.up)))
        while k > 1 && w * k > 2048 { k -= 1 }
        feedbackSize = (w * k, h * k)
        var slots: [MTLTexture] = []
        for _ in 0...render.settings.delay {
            guard let t = makeRenderTarget(device: device, width: feedbackSize.width,
                                           height: feedbackSize.height) else {
                throw Self.error("feedback texture")
            }
            slots.append(t)
        }
        ring = slots

        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        func pipe(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw Self.error("kernel \(name)") }
            return try device.makeComputePipelineState(function: fn)
        }
        cameraPipeline = try pipe("howl_camera")
        blurPipeline = try pipe("howl_blur")

        mean = MPSImageStatisticsMean(device: device)
        func meanTarget() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1,
                                                             height: 1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard let t = device.makeTexture(descriptor: d) else { throw Self.error("mean texture") }
            return t
        }
        meanCamera = try meanTarget()
        meanScene = try meanTarget()

        // The TV starts dark: nothing has gone round the loop yet.
        if let cb = context.queue.makeCommandBuffer() {
            for t in ring {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = t
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }
    }

    private static func error(_ what: String) -> NSError {
        NSError(domain: "Howlaround", code: 1, userInfo: [NSLocalizedDescriptionKey: "howlaround: \(what)"])
    }

    /// Keyframed shader values for this frame, for the loop's copy of the
    /// chain (the export's own copy gets them too).
    public func setShaderParams(_ params: [String: Float]) {
        guard let feedbackChain else { return }
        for (n, v) in params { try? feedbackChain.setParameter(n, value: v) }
    }

    private var writeSlot: Int { frame % ring.count }
    private var readSlot: Int { (frame + 1) % ring.count }   // `delay` frames ago

    /// The TV's picture for this frame goes here (see ExportFrame).
    public var feedback: HowlaroundFeedback {
        HowlaroundFeedback(chain: feedbackChain, bypass: bypass, texture: ring[writeSlot])
    }

    /// What the camera sees this frame: the scene (the room) with the TV in
    /// it showing the picture from `delay` frames ago. Encoded and committed
    /// on its own command buffer, so the NTSC stage's readback — submitted
    /// after it on the same queue — sees the finished image.
    /// - Parameter time: seconds into the render, for the counter.
    public func cameraImage(scene: MTLTexture, time: Double) throws -> MTLTexture {
        let device = context.device
        if camera == nil || camera!.width != scene.width || camera!.height != scene.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: scene.width,
                                                             height: scene.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            camera = device.makeTexture(descriptor: d)
        }
        guard let camera, let cb = context.queue.makeCommandBuffer() else { throw Self.error("camera texture") }
        let s = settings
        let aspect = Double(scene.width) / Double(max(1, scene.height))
        let pose = s.pose(at: time, length: render.length)

        // Defocus, in the TV picture's own pixels: a camera blur of `sigma`
        // chain-input lines is that over the screen's size in the frame.
        var tv = ring[readSlot]
        let sigmaLines = 2.5 * s["focus"]
        let scale = Double(feedbackSize.height) / Double(max(1, chainInputSize.height))
        let sigma = min(24, sigmaLines * scale / max(0.25, min(1, pose.zoom)))
        if s.tvInView && sigma > 0.3 {
            let a = try scratch(&blurA, like: tv), b = try scratch(&blurB, like: tv)
            blur(cb, from: tv, to: a, sigma: sigma, dir: SIMD2(1, 0))
            blur(cb, from: a, to: b, sigma: sigma, dir: SIMD2(0, 1))
            tv = b
        }

        let (ax, ay, n, c) = HowlaroundSettings.screen(pose, aspect: aspect)
        func f4(_ v: SIMD3<Double>, _ w: Double = 0) -> SIMD4<Float> {
            SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w))
        }
        // White balance: red against blue, keeping luminance where it was.
        let wb = 0.07 * s["colour_drift"]
        let r = 1 + wb, b = 1 - wb
        let luma = 0.299 * r + 0.587 + 0.114 * b
        let hue = s["hue_drift"] * Double.pi / 180
        var rect = SIMD4<Float>(0, 0, 0, 0)
        if s.counter, let tex = counter(for: time) {
            let h = 0.075, w = h * counterAspect / aspect
            rect = SIMD4(Float(0.07), Float(0.86 - h), Float(0.07 + w), Float(0.86))
            counterTexture = tex
        }
        var u = CameraUniforms(
            axisX: f4(ax), axisY: f4(ay), normal: f4(n), centre: f4(c),
            balance: SIMD4(Float(r / luma), Float(1 / luma), Float(b / luma), Float(s.tvInView ? s["mix"] : 0)),
            counterRect: rect,
            params: SIMD4(Float(aspect), Float(max(0.001, pose.zoom)), Float(s["brightness"]), Float(s["contrast"])),
            params2: SIMD4(Float(cos(hue)), Float(sin(hue)), Float(exposure), s.tvInView ? 1 : 0))

        guard let enc = cb.makeComputeCommandEncoder() else { throw Self.error("encoder") }
        enc.setComputePipelineState(cameraPipeline)
        enc.setTexture(scene, index: 0)
        enc.setTexture(tv, index: 1)
        enc.setTexture(counterTexture ?? tv, index: 2)
        enc.setTexture(camera, index: 3)
        enc.setBytes(&u, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        dispatch(enc, cameraPipeline, camera)
        enc.endEncoding()

        // The camcorder's exposure meter: its own picture against the room's.
        if s["auto_exposure"] > 0 {
            mean.encode(commandBuffer: cb, sourceTexture: camera, destinationTexture: meanCamera)
            mean.encode(commandBuffer: cb, sourceTexture: scene, destinationTexture: meanScene)
            if !device.hasUnifiedMemory, let blit = cb.makeBlitCommandEncoder() {
                blit.synchronize(resource: meanCamera)
                blit.synchronize(resource: meanScene)
                blit.endEncoding()
            }
            measured = true
        }
        cb.commit()
        return camera
    }

    /// One frame has gone round: rotate the loop, and let the auto exposure
    /// react to what it measured — a frame late, which is what makes it hunt.
    public func advance() {
        if measured {
            func luma(_ t: MTLTexture) -> Double {
                var px = [Float](repeating: 0, count: 4)
                t.getBytes(&px, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
                return Double(0.299 * px[2] + 0.587 * px[1] + 0.114 * px[0])   // BGRA
            }
            let target = max(0.02, luma(meanScene)), seen = max(0.02, luma(meanCamera))
            let rate = 0.6 * settings["auto_exposure"]
            exposure = min(4, max(0.25, exposure * pow(target / seen, rate)))
            measured = false
        }
        frame += 1
    }

    /// Run the loop `frames` times on `scene` without writing anything, so
    /// the first frame of the render already shows the whole tunnel. Uses the
    /// export's own NTSC stage and glitch renderer, standing still at its
    /// first moment.
    public func runUp(frames: Int, fps: Double, scene: MTLTexture, pipeline: Pipeline, ntsc: NtscStage?,
                      glitch: GlitchFrame?, downscale: DownscaleSpec?) throws {
        for k in 0..<frames {
            if isCancelled { throw CancellationError() }
            // The camera's moment: before the first frame, so the tunnel
            // already carries the motion that leads into it.
            let image = try cameraImage(scene: scene, time: Double(k - frames) / max(1, fps))
            var input = image
            var spec = downscale
            if let ntsc {
                input = try pipeline.prepareChainInput(source: image, downscale: spec, ntsc: ntsc,
                                                       frameCount: 100_000 + k, sourceVersion: nil)
                spec = nil
            }
            guard let cb = context.queue.makeCommandBuffer() else { throw Self.error("command buffer") }
            let (chainInput, chainSpec) = try ExportFrame.chainInput(into: cb, glitch: glitch,
                                                                    inputTexture: input, downscale: spec)
            try feedback.render(into: cb, pipeline: pipeline, input: chainInput,
                                downscale: chainSpec, frameCount: 100_000 + k)
            cb.commit()
            cb.waitUntilCompleted()
            advance()
        }
    }

    // MARK: helpers

    private func scratch(_ slot: inout MTLTexture?, like t: MTLTexture) throws -> MTLTexture {
        if let s = slot, s.width == t.width, s.height == t.height { return s }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width,
                                                         height: t.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let s = context.device.makeTexture(descriptor: d) else { throw Self.error("blur texture") }
        slot = s
        return s
    }

    private func blur(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture,
                      sigma: Double, dir: SIMD2<Float>) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        var u = BlurUniforms(dir: dir, sigma: Float(sigma), radius: Int32(min(64, (2.5 * sigma).rounded(.up))))
        enc.setComputePipelineState(blurPipeline)
        enc.setTexture(from, index: 0)
        enc.setTexture(to, index: 1)
        enc.setBytes(&u, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        dispatch(enc, blurPipeline, to)
        enc.endEncoding()
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ t: MTLTexture) {
        let w = p.threadExecutionWidth
        let h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// The counter's text ("0:04"), drawn once per new value: white figures
    /// with a dark edge, as camcorders burned them in.
    private func counter(for time: Double) -> MTLTexture? {
        let secs = max(0, Int(time))
        let text = "\(secs / 60):" + String(format: "%02d", secs % 60)
        if text == counterText, let t = counterTexture { return t }
        let fontSize: CGFloat = 96
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        func line(_ color: CGColor) -> CTLine {
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
            return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
        }
        let white = line(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let bounds = CTLineGetImageBounds(white, nil)
        let pad: CGFloat = 12
        let w = Int(ceil(bounds.width + 2 * pad)), h = Int(ceil(fontSize * 0.9 + 2 * pad))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return }
            let origin = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY + (CGFloat(h) - 2 * pad - bounds.height) / 2)
            let shadow = line(CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
            for (dx, dy) in [(-4, 0), (4, 0), (0, -4), (0, 4), (4, -4)] {
                ctx.textPosition = CGPoint(x: origin.x + CGFloat(dx), y: origin.y + CGFloat(dy))
                CTLineDraw(shadow, ctx)
            }
            ctx.textPosition = origin
            CTLineDraw(white, ctx)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        guard let tex = context.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        counterText = text
        counterAspect = Double(w) / Double(h)
        return tex
    }

    private struct CameraUniforms {
        var axisX: SIMD4<Float>
        var axisY: SIMD4<Float>
        var normal: SIMD4<Float>
        var centre: SIMD4<Float>
        var balance: SIMD4<Float>
        var counterRect: SIMD4<Float>
        var params: SIMD4<Float>      // aspect, zoom, brightness, contrast
        var params2: SIMD4<Float>     // hue cos, hue sin, exposure, TV in view
    }

    private struct BlurUniforms {
        var dir: SIMD2<Float>
        var sigma: Float
        var radius: Int32
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CameraUniforms {
        float4 axisX, axisY, normal, centre, balance, counterRect, params, params2;
    };
    struct BlurUniforms { float2 dir; float sigma; int radius; };

    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge, coord::normalized);

    // What the camera sees at each pixel: the room, or — where the ray hits
    // the TV's screen — the TV's picture, as bright and as tinted as the
    // camera sees it.
    kernel void howl_camera(texture2d<float, access::read> scene [[texture(0)]],
                            texture2d<float, access::sample> tv [[texture(1)]],
                            texture2d<float, access::sample> counter [[texture(2)]],
                            texture2d<float, access::write> out [[texture(3)]],
                            constant CameraUniforms& u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = out.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float3 c = scene.read(gid).rgb;
        float aspect = u.params.x, zoom = u.params.y;
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        if (u.params2.w > 0.5) {
            float3 d = float3((uv.x - 0.5) * aspect, uv.y - 0.5, 1.0);
            float3 n = u.normal.xyz;
            float denom = dot(d, n);
            if (fabs(denom) > 1e-6) {
                float t = dot(u.centre.xyz, n) / denom;
                if (t > 0) {
                    float3 p = d * t - u.centre.xyz;
                    float sx = dot(p, u.axisX.xyz) / (zoom * aspect) + 0.5;
                    float sy = dot(p, u.axisY.xyz) / zoom + 0.5;
                    // Anti-aliased screen edge, about a pixel wide.
                    float ex = min(sx, 1.0 - sx) * zoom * float(W);
                    float ey = min(sy, 1.0 - sy) * zoom * float(H);
                    float cover = saturate(min(ex, ey) + 0.5);
                    if (cover > 0.0) {
                        float3 s = tv.sample(linearClamp, float2(sx, sy)).rgb;
                        s *= u.params.z;
                        s = (s - 0.5) * u.params.w + 0.5;
                        s *= u.balance.rgb;
                        float y = dot(s, float3(0.299, 0.587, 0.114));
                        float i = dot(s, float3(0.596, -0.274, -0.322));
                        float q = dot(s, float3(0.211, -0.523, 0.312));
                        float i2 = i * u.params2.x - q * u.params2.y;
                        float q2 = i * u.params2.y + q * u.params2.x;
                        s = float3(y + 0.956 * i2 + 0.621 * q2,
                                   y - 0.272 * i2 - 0.647 * q2,
                                   y - 1.106 * i2 + 1.703 * q2);
                        c = mix(c, saturate(s), cover);
                    }
                }
            }
        }
        // The mixer: your picture faded in over the camera's.
        c = mix(c, scene.read(gid).rgb, u.balance.w);
        c *= u.params2.z;
        float4 r = u.counterRect;
        if (r.z > r.x && uv.x >= r.x && uv.x <= r.z && uv.y >= r.y && uv.y <= r.w) {
            float4 t = counter.sample(linearClamp, (uv - r.xy) / (r.zw - r.xy));
            c = c * (1.0 - t.a) + t.rgb;
        }
        out.write(float4(saturate(c), 1.0), gid);
    }

    kernel void howl_blur(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant BlurUniforms& u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float4 acc = 0.0;
        float wsum = 0.0;
        int2 step = int2(u.dir);
        for (int k = -u.radius; k <= u.radius; k++) {
            float w = exp(-0.5 * float(k * k) / (u.sigma * u.sigma));
            int2 p = clamp(int2(gid) + step * k, int2(0), int2(int(W) - 1, int(H) - 1));
            acc += src.read(uint2(p)) * w;
            wsum += w;
        }
        dst.write(acc / wsum, gid);
    }
    """
}
