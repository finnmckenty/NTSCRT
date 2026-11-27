import Foundation

/// The picture reaching the TV on channel 3 through its antenna socket (RF),
/// the way a game console or a VCR sent it: as a composite video signal,
/// through the tuner — instead of arriving already separated into
/// brightness and color.
///
/// Brightness and color share one wire: the color rides on a subcarrier at
/// 3.58 MHz, inside the band the brightness uses. The set pulls them apart
/// with filters, and can't do it cleanly. A hard edge has energy at the
/// subcarrier's frequency, which the set takes for color: every edge gets a
/// colored fringe. The subcarrier's phase steps from line to line and field
/// to field, so the fringes differ on neighboring lines and change every
/// field (they crawl). And the brightness filter that keeps the subcarrier
/// out also takes the picture's finest detail.
///
/// None of that can be drawn onto a decoded picture; it is what decoding
/// does. So here the picture is really made into the signal, at its own
/// pixel scale (after Downscale: a 256-wide picture is 256 hard-edged
/// pixels of video across the line, as a console's is), and decoded as a
/// set would:
///
///   - The signal is sampled six times a subcarrier cycle (21.5 MHz, 1131
///     samples across the picture): at each sample, the pixel's brightness
///     plus its color on the subcarrier.
///   - What the tuner and the cable do is done to that signal: the
///     tuner's noise and the antenna's, a reflection (the Ghost knobs: the
///     same signal again, later, its color wherever its subcarrier's phase
///     lands), and the Edge crawl and Color knobs.
///   - The set decodes it: brightness is the signal low-passed under the
///     subcarrier; color is the signal against the subcarrier's two phases,
///     low-passed to the color's bandwidth.
///
/// The subcarrier's phase advances a third of a cycle a line and a third a
/// field, as an NES's or SNES's does (a choice: broadcast video advances a
/// half, which gives a finer, calmer crawl). Its frequency against the
/// pixels is the real one for a picture filling the line: 0.74 of a cycle a
/// pixel at 256 wide, 0.59 at 320, 0.29 at 640 — so the fringes are bold on
/// a coarse picture and fine on a fine one.
///
/// After J. Kyle Pittman's CRT Sim, whose composite pass draws these three
/// things by hand (edge artifacts from a texture that flips each frame, a
/// ringing halo, bleed), and Themaister's NTSC shaders, which do it as
/// signal processing; the filters here are designed to the same bandwidths
/// as the latter's, not copied. Judged against Finn's photos of an NES on
/// one CRT both ways (2026-11-26) and a prototype he approved the same day.
/// Not modeled: the tuner's IF curve, sound, interference from another
/// transmitter, a comb filter.
///
/// (A video cable carries the same signal without the tuner. It was an
/// option for a few hours on 2026-11-26; Finn: little difference from
/// Direct and no controls of its own, so it went.)
public struct CompositeSignal: Equatable, Sendable {

    /// The picture comes in through the antenna socket. Off: brightness and
    /// color arrive apart, and nothing here acts.
    public let on: Bool
    /// Edge crawl, 0…1 (see `taps`).
    public let crawl: Double
    /// Color: the picture's own color, 0 (black and white) through 1 (as
    /// sent) to `mostColor`.
    public let color: Double

    /// Tuner smear, 0…1: the color arriving late and drawn out (see
    /// `smearKernel`).
    public let smear: Double
    /// Softness, 0…1: the brightness filter's cutoff brought down (see
    /// `lumaCutoffMHz`).
    public let soft: Double
    /// Tuner offset, 0…1: the set tuned off the channel, toward the side
    /// that loses the color (see `burstGain`, `taps`).
    public let offset: Double

    public init(_ s: GlitchSettings) {
        let rf = s.flag("rf")
        func knob(_ id: String) -> Double { rf ? min(1, max(0, s[id])) : 0 }
        on = rf
        crawl = knob("rf_crawl")
        color = rf ? min(Self.mostColor, max(0, s["rf_color"])) : 1
        smear = knob("rf_smear")
        soft = knob("rf_soft")
        offset = knob("rf_offset")
    }

    /// Tuner offset: what is left of everything around the subcarrier — the
    /// color, and the burst the set's color circuits lock to — as the
    /// tuning slides it down the edge of the tuner's passband: all of it
    /// tuned, 15% at the end. The set's own circuits do the rest
    /// (Receiver, `glitch_chroma`): its color gain control makes the loss
    /// up, to three times, and the noise in the color comes up with it;
    /// its oscillator has less burst to hold on to, so the hue wanders
    /// from line to line; and under about a third the color killer cuts
    /// in — flickering first, then black and white.
    public var burstGain: Double { 1 - Self.offsetLoss * offset }
    static let offsetLoss = 0.85
    static let offsetTilt = 2.0

    /// Softness: the brightness filter's half-gain frequency, MHz, from
    /// the plain set's 2.1 down to 0.8 (text a few pixels tall merges).
    public var lumaCutoffMHz: Double { 2.1 - 1.3 * soft }

    /// Edge crawl's emphasis of the brightness's edges, and of what the set
    /// takes for color (see `taps`).
    var edgeEmphasis: Double { Self.edgeMost * crawl }
    var fringeEmphasis: Double { Self.fringeMost * crawl }

    /// The color as it goes into the signal: the Color knob's, less what
    /// Edge crawl's emphasis will add to it (everything at the subcarrier
    /// comes out 1 + 4·fringeEmphasis times over), so Edge crawl leaves the
    /// picture's own color where Color put it — as a set's color control
    /// loop would.
    ///
    /// Tuner offset takes some of it too, up to half (`offsetFade`): the
    /// set's gain control makes up what the burst lost, but the color's
    /// outer sideband is further down the edge than the burst is. (A
    /// choice: it is what makes the knob weaken the color all the way
    /// along, before the killer takes the rest.)
    public var colorInSignal: Double { color * (1 - Self.offsetFade * offset) / (1 + 4 * fringeEmphasis) }
    static let offsetFade = 0.5

    // MARK: - the signal

    /// Samples in a subcarrier cycle.
    public static let samplesPerCycle = 6
    /// A sample's length, µs.
    public static let sampleUS = 1 / (Double(samplesPerCycle) * NTSCTiming.subcarrierMHz)
    /// The subcarrier's advance from one line to the next and one field to
    /// the next, cycles.
    public static let cyclesPerLine = 1.0 / 3

    /// The tuner's own noise on a strong signal, IRE in the video band
    /// (36 dB down: a choice, about what a console's modulator into a set's
    /// tuner managed).
    public static let tunerNoiseIRE = 1.5
    /// The receiver's noise figure is IRE in the 4.2 MHz video band; a
    /// sample here carries the band to half the sampling rate.
    public static let noisePerSample = (0.5 / sampleUS / 4.2).squareRoot()

    // MARK: - the set's filters

    /// The decode filters' reach either side, samples (1.1 µs).
    public static let reach = 24
    /// Edge crawl's emphasis compares the signal with itself half a
    /// subcarrier cycle either side.
    static let emphasisStep = samplesPerCycle / 2
    /// The reach of the filters with the emphasis folded in.
    public static let tapRadius = reach + emphasisStep

    /// Edge crawl at the top: the brightness's edges emphasized by 0.75
    /// (two and a half times at half the subcarrier), and what the set
    /// takes for color — the fringes, the noise — by 0.3: 2.2 times. (It
    /// was 0.75 for both, four times the fringes, and no notch; Finn,
    /// 2026-11-26: "adds more color/saturation than a real RF cable does".
    /// His photos of an NES on RF show the crawl beside edges as teeth of
    /// brightness with little color in them. At 0.125 for the color and
    /// 0.4 for the edges the knob did too little to see.)
    static let edgeMost = 0.75
    static let fringeMost = 0.3
    /// Color's range: four times the color as sent (garish).
    public static let mostColor = 4.0

    /// A low-pass filter of `2·reach + 1` taps, half its gain at `cutoff`
    /// cycles a sample, unit gain at rest. `blackman` trades a wider skirt
    /// for a deeper stop band.
    static func lowpass(cutoff: Double, blackman: Bool) -> [Double] {
        let n = reach
        var h = (-n...n).map { k -> Double in
            let x = Double(k)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let a = .pi * (x + Double(n)) / Double(n)          // 0…2π across the window
            let w = blackman ? 0.42 - 0.5 * cos(a) + 0.08 * cos(2 * a) : 0.54 - 0.46 * cos(a)
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h
    }

    /// Brightness: half gain at 2.1 MHz, nothing left at the subcarrier.
    static let lumaFilter = lowpass(cutoff: 2.1 * sampleUS, blackman: true)
    /// The picture's broadest strokes only (half gain near half a
    /// megahertz): what a tuner off its channel favors (see `taps`).
    static let broadFilter = lowpass(cutoff: 0.5 * sampleUS, blackman: false)
    /// Color: half gain at 0.85 MHz, nothing left at 1.8 (where the
    /// brightness's detail and, at twice the subcarrier, the decoding's own
    /// leftovers would come through).
    static let chromaFilter = lowpass(cutoff: 0.85 * sampleUS, blackman: false)

    /// The brightness filter of a set with a notch: everything to 4.6 MHz
    /// except a band a megahertz wide around the subcarrier. A steady color
    /// is in that band and stays out of the brightness; where the color
    /// changes, the subcarrier's sidebands fall outside it and come through
    /// as dots beside the edge — in step with the subcarrier, so they
    /// alternate from line to line and move every field: edge crawl.
    static let notchFilter: [Double] = {
        let wide = lowpass(cutoff: 4.6 * sampleUS, blackman: true)
        let band = lowpass(cutoff: 0.5 * sampleUS, blackman: false)
        let h = (-reach...reach).map { k in
            wide[k + reach] - 2 * cos(2 * .pi * Double(k) / Double(samplesPerCycle)) * band[k + reach]
        }
        // (Unit gain at rest, so levels hold.)
        let sum = h.reduce(0, +)
        return h.map { $0 / sum }
    }()

    /// The set's two filters with the knobs in them, each `2·tapRadius + 1`
    /// long, brightness then color.
    ///
    /// Softness sets the brightness filter's cutoff. Tuner offset tilts it:
    /// tuned off toward the side that loses the color, the tuner passes the
    /// picture's slow changes more strongly than its fast ones, so the
    /// broad strokes (`broadFilter`) are added, up to twice as much again
    /// (`offsetTilt`), and the whole brought back to level — fine detail
    /// down to a third of its contrast with a soft halo round large
    /// shapes, which is not what Softness does (that takes the detail
    /// away).
    ///
    /// Edge crawl does three things, all to what the set makes of the
    /// signal's fast changes:
    ///   - The brightness filter goes from the low-pass toward the notch
    ///     (`notchFilter`): dots crawling beside every change of color, a
    ///     crisper and grainier picture. No color is added: this is
    ///     brightness.
    ///   - The signal's difference from itself half a subcarrier cycle
    ///     either side is added to it, c + e·(2c − c₋ − c₊): gain 1 at rest
    ///     (levels hold), 1 + 2e at half the subcarrier — harder edges, a
    ///     light line inside a light edge. For the brightness e is
    ///     `edgeEmphasis`.
    ///   - For the color e is `fringeEmphasis`, much smaller: at the
    ///     subcarrier 1 + 4e, which is everything the set takes for color —
    ///     the fringes, the noise, and the color itself, which
    ///     `colorInSignal` takes back out. Half a cycle away the subcarrier
    ///     is upside down, which is the sign change in the color's filter.
    ///
    /// Choices of shape, not a measured set.
    public var taps: (luma: [Float], chroma: [Float]) {
        let r = Self.tapRadius, n = Self.reach, d = Self.emphasisStep
        let el = edgeEmphasis, ec = fringeEmphasis
        let low = soft > 0 ? Self.lowpass(cutoff: lumaCutoffMHz * Self.sampleUS, blackman: true) : Self.lumaFilter
        let tilt = Self.offsetTilt * offset
        let base = (0...2 * n).map { i -> Double in
            let plain = low[i] + crawl * (Self.notchFilter[i] - low[i])
            return (plain + tilt * Self.broadFilter[i]) / (1 + tilt)
        }
        func at(_ f: [Double], _ k: Int) -> Double { abs(k) <= n ? f[k + n] : 0 }
        var luma = [Float](), chroma = [Float]()
        for k in -r...r {
            luma.append(Float((1 + 2 * el) * at(base, k) - el * (at(base, k - d) + at(base, k + d))))
            chroma.append(Float((1 + 2 * ec) * at(Self.chromaFilter, k)
                                + ec * (at(Self.chromaFilter, k - d) + at(Self.chromaFilter, k + d))))
        }
        return (luma, chroma)
    }

    // MARK: - tuner smear

    /// Tuner smear: the color is late and drawn out. At the edge of the
    /// tuner's passband, where the subcarrier sits, the delay is longest
    /// and least even, so the color — and only the color — arrives after
    /// the brightness it belongs to and takes a while to arrive: it trails
    /// to the right of everything it colors and is thin just inside each
    /// left edge.
    ///
    /// Here the color in the signal is the picture's color as it was up to
    /// `smearSteps` whole subcarrier cycles back (0.28 µs each, 1.4 pixels
    /// at 256 wide), weighted 1, a, a², …: nothing at 0; at the top a is
    /// 0.9 — on average 0.9 µs late (4.5 pixels at 256), still arriving
    /// 2.2 µs on. a goes as the knob's square root, so the lateness grows
    /// evenly along it (1.3 pixels at a quarter, 2.5 at half). Whole
    /// cycles, so the subcarrier's phase is the same at each and the sum
    /// is still one color on one subcarrier. It is done to the signal, so
    /// the dots beside a change of color (Edge crawl) trail with it.
    ///
    /// A choice of shape: an echo-free, one-sided lag. A set's IF gave an
    /// uncorrected signal a few tenths of a microsecond of it; the top of
    /// the knob is well past that. (At 0.45 µs the knob was hard to see.)
    public var smearKernel: [Double] {
        let a = Self.smearMost * smear.squareRoot()
        let w = (0...Self.smearSteps).map { pow(a, Double($0)) }
        let sum = w.reduce(0, +)
        return w.map { $0 / sum }
    }
    static let smearSteps = 8
    static let smearMost = 0.9
    /// How far back the smear reaches, samples.
    static let smearReach = smearSteps * samplesPerCycle

    /// The stage's filter table. For each sample from `tapLeft` before the
    /// pixel to `tapRadius` after it, four weights: what the sample's
    /// brightness adds to the pixel's brightness and to its color, and
    /// what the sample's color (on its subcarrier) adds to each. The first
    /// two are `taps`; the second two are `taps` with the smear in them
    /// (the color `k` cycles back counts for the pixel as if it were here).
    public static let tapLeft = tapRadius + smearReach
    public static let tapSpan = tapLeft + tapRadius + 1
    public var signalTaps: [Float] {
        let (luma, chroma) = taps
        let r = Self.tapRadius, w = smearKernel
        func at(_ f: [Float], _ k: Int) -> Double { abs(k) <= r ? Double(f[k + r]) : 0 }
        var table = [Float](repeating: 0, count: 4 * Self.tapSpan)
        for m in -Self.tapLeft...r {
            let i = m + Self.tapLeft
            table[i] = Float(at(luma, m))
            table[i + Self.tapSpan] = Float(at(chroma, m))
            var l = 0.0, c = 0.0
            for (j, wj) in w.enumerated() where wj != 0 {
                l += wj * at(luma, m + j * Self.samplesPerCycle)
                c += wj * at(chroma, m + j * Self.samplesPerCycle)
            }
            table[i + 2 * Self.tapSpan] = Float(l)
            table[i + 3 * Self.tapSpan] = Float(c)
        }
        return table
    }
    /// How far before the pixel the table is in use: the smear's reach
    /// only when there is smear.
    public var tapsBefore: Int { smear > 0 ? Self.tapLeft : Self.tapRadius }

    /// A filter's gain at `cyclesPerSample` (the taps are symmetric).
    public static func gain(_ taps: [Float], cyclesPerSample f: Double) -> Double {
        let r = taps.count / 2
        return (-r...r).reduce(0.0) { $0 + Double(taps[$1 + r]) * cos(2 * .pi * f * Double($1)) }
    }
}
