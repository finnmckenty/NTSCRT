import Foundation

/// One control of the Digital video stage. The stage is a small video codec
/// run for real — a camera's capture, 8×8 DCT blocks, real quantization
/// tables, motion-compensated prediction between keyframes, and a decoder
/// that can lose data — so, as with the Glitch stage, every control is a
/// setting the format or its transmission actually had. Blocking, smearing
/// and datamoshing come out of the codec; nothing is drawn.
public struct DigitalParam: Identifiable, Sendable {
    /// In the panel's order: the codec first, as the stage's main choice.
    public enum Group: String, CaseIterable, Sendable {
        case compression = "Compression"
        case capture = "Capture"
        case picture = "Picture"
        case errors = "Errors"
    }
    public enum Kind: Sendable, Equatable {
        case slider(min: Double, max: Double, percent: Bool, unit: String)
        /// A list of named choices, stored as the index.
        case choice([String])
    }

    public let id: String
    public let label: String
    public let group: Group
    public let kind: Kind
    public let defaultValue: Double
    public let help: String
    /// Whole steps only (frame rate), else nil: continuous.
    public var step: Double? = nil

    public var isChoice: Bool { if case .choice = kind { return true } else { return false } }

    /// The camera's picture controls (and its optics and sampling) default
    /// to leaving the picture alone, so a double-click returns them there;
    /// the rest default to the Webcam format's values.
    public static let all: [DigitalParam] = [
        DigitalParam(
            id: "frame_rate", label: "Frame rate", group: .capture,
            kind: .slider(min: 1, max: 60, percent: false, unit: "fps"), defaultValue: 15,
            help: "How many pictures a second the camera captures. Below the clip's own rate, frames repeat — the stutter of old webcams and video calls.",
            step: 1),
        DigitalParam(
            id: "fields", label: "Fields", group: .capture,
            kind: .choice(["Progressive", "One field", "Woven fields", "Blended fields"]), defaultValue: 1,
            help: "Interlaced cameras like the VX1000 record each frame as two fields of alternate lines, taken a moment apart. One field keeps just one, as most DV reached the web: the CRT gets half as many lines, each twice as tall, and draws a scanline per line — the 240p look — while anywhere without the CRT each line shows twice, turning diagonals to stairs. Woven fields shows the two together: anything that moved between them breaks into comb teeth, which the codec then struggles with. Blended fields mixes them instead, the cheap deinterlacing of DV on the web: moving things get a ghosted double edge and the picture softens a little. Both need a clip with motion; the earlier field comes from the frame before."),
        DigitalParam(
            id: "sensor", label: "Sensor", group: .capture,
            kind: .choice(["Three chips", "One chip (webcam)", "One chip (camcorder)"]), defaultValue: 0,
            help: "Three chips (3-CCD, the VX1000) read red, green and blue everywhere. One chip (webcam) has a mosaic of red, green and blue filters over a single sensor, each pixel seeing one color and guessing the other two from its neighbors, as webcams and digital cameras do: fine detail and sharp edges pick up false colors and a zipper pattern. One chip (camcorder) is how 90s consumer camcorders worked: cyan, yellow, magenta and green filters read two rows at a time, with color carried as two signals on alternate lines, so every line borrows half its color from the line above. Color has half the detail and lags a line, smearing down and fringing at horizontal edges; sharp vertical edges pick up false color; brightness is a little soft. With either one chip, Sensor noise goes through the same reconstruction, so its color grain comes out in blotches rather than fine specks. Aliasing makes the false color stronger."),
        DigitalParam(
            id: "smear", label: "Vertical smear", group: .capture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "A CCD's vertical smear: light from a very bright spot leaks into its whole column as the picture is read out, drawing a pale streak up and down through lamps, headlights and the sun. Strongest in dark scenes, where the camera has opened up."),
        DigitalParam(
            id: "aliasing", label: "Aliasing", group: .capture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The sensor reading detail it can't resolve, with nothing blurring it away first: fine stripes beat into moiré and edges into jaggies. Red, green and blue are sampled a third of a pixel apart, so where a beat drifts slowly its colors cycle through the rainbow. Above 50% the finest detail is boosted as it's read, for stronger moiré from sources not much sharper than the camera."),
        DigitalParam(
            id: "sensor_noise", label: "Sensor noise", group: .capture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0.4,
            help: "Grain from a small, cheap image sensor, strongest in the color. It changes every frame, so the codec spends its bits on it and blocks crawl in flat areas."),
        DigitalParam(
            id: "low_light_noise", label: "Low-light noise", group: .capture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "How much the grain grows in dark scenes. As the light drops, the camera turns up its gain, and the sensor noise with it: up to eight times as strong at night, while daylight stays as set. Works on Sensor noise, so it needs some."),
        DigitalParam(
            id: "noise_reduction", label: "Noise reduction", group: .capture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0.5,
            help: "The camera smoothing its own grain away before compressing. It flattens fine detail into a smeary, plastic look."),
        DigitalParam(
            id: "ccd_response", label: "CCD response", group: .picture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The tone of a 90s DV camcorder: four things this one slider turns up together. Auto exposure meters the middle of the frame and exposes bright, as far as the gain the camera has left, so a dark scene stays dark instead of being pushed up to gray. Highlights: each color is compressed by the knee and then clips at white on its own, so warm skin and skies go yellow, then white; what is already white in the source clips too. Lens flare lays a veil over the shadows, more in bright scenes. And DV's levels are shown as stored: black sits at 16 of 255, a milky gray, and color comes out a few percent weak. The amounts are fitted to VX1000 footage. 0% leaves the picture alone."),
        DigitalParam(
            id: "white_balance", label: "White balance", group: .picture,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Warm (positive) or cool (negative): the camera's guess at the light, often wrong."),
        DigitalParam(
            id: "tint", label: "Tint", group: .picture,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Magenta (positive) or green (negative), the other way a camera's color can drift."),
        DigitalParam(
            id: "saturation", label: "Saturation", group: .picture,
            kind: .slider(min: 0, max: 2, percent: true, unit: ""), defaultValue: 1,
            help: "Color strength. Consumer camcorders pushed it, reds and oranges most visibly."),
        DigitalParam(
            id: "sharpening", label: "Sharpening", group: .picture,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The camera's detail circuit: edges get bright and dark outlines (halos), the crisp, hard-edged video look."),
        DigitalParam(
            id: "sharpening_width", label: "Halo width", group: .picture,
            kind: .slider(min: 1, max: 4, percent: false, unit: "px"), defaultValue: 1,
            help: "How far the sharpening halos reach, in camera pixels. 1 px is a 3-CCD camera's tight, crunchy edge; wider is the soft white rim around everything that cheap consumer camcorders drew. Works on Sharpening, so it needs some."),
        DigitalParam(
            id: "codec", label: "Codec", group: .compression,
            kind: .choice(["DCT (MPEG, DV)", "Block colors (Video 1)"]), defaultValue: 0,
            help: "How the picture is compressed. DCT, the MPEG, H.263 and DV family, blurs detail inside 8×8 blocks and rings around edges. Block colors is Microsoft Video 1 (1992, Video for Windows): each 4×4 block becomes one, two or eight flat 15-bit colors and unchanged blocks are skipped — chunky two-tone edges and banded gradients, the early CD-ROM look."),
        DigitalParam(
            id: "block_size", label: "Block size", group: .compression,
            kind: .choice(["4 px", "8 px", "16 px"]), defaultValue: 1,
            help: "The size of the blocks the picture is compressed in, whatever its resolution. 8 px is what MPEG, JPEG and DV use. 16 px makes the tiles, the ringing around edges and everything else the codec does twice as big, for blocks that still show in a large picture; 4 px makes them half the size, a finer grit for a small one. Motion, lost data and datamoshing work in squares twice the block's size, so they grow and shrink with it."),
        DigitalParam(
            id: "chroma", label: "Color", group: .compression,
            kind: .choice(["4:4:4 (full)", "4:2:2 (half)", "4:2:0 (quarter)", "4:1:1 (DV)"]),
            defaultValue: 2,
            help: "How much color detail is kept against brightness detail. Codecs store color at lower resolution because eyes notice it less: 4:2:2 halves it across, 4:2:0 across and down, and 4:1:1, NTSC DV's choice, quarters it across, smearing color sideways."),
        DigitalParam(
            id: "chroma_upsampling", label: "Color decode", group: .compression,
            kind: .choice(["Smooth", "Blocky"]), defaultValue: 0,
            help: "How the decoder scales the stored color back up to the picture. Smooth interpolates. Blocky repeats each color sample, as early DV decoders did: colored edges, reds most of all, turn into steps two or four pixels wide. Needs Color below 4:4:4."),
        DigitalParam(
            id: "quality", label: "Quality", group: .compression,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0.749,
            help: "How finely each 8×8 block's detail is kept (the quantizer). Lower turns blocks into flat tiles and rings edges with mosquito noise."),
        DigitalParam(
            id: "keyframe_interval", label: "Keyframe interval", group: .compression,
            kind: .slider(min: 0, max: 10, percent: false, unit: "s"), defaultValue: 0,
            help: "Seconds between keyframes (whole pictures). Between them the codec only sends what moved, so errors and datamoshing persist until the next one. 0 compresses every frame on its own, like Motion JPEG and DV."),
        DigitalParam(
            id: "fixed_bitrate", label: "Fixed bitrate", group: .compression,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "How strictly the codec keeps to a fixed bitrate. Busy frames — motion, detail, grain — have to share the same bits, so they turn blocky, and the picture sharpens again when things settle."),
        DigitalParam(
            id: "bitrate_limit", label: "Bitrate limit", group: .compression,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "A real budget of bits, counted from what the codec actually sends. 0% is no limit; from there it tightens from about 2 bits for each pixel of a frame down to a hundredth of one (the panel shows it in kbps for the current size and frame rate). A frame that needs more than its share is compressed harder until it fits, as far as about Quality 46%. Every frame on its own, each frame gets the same bits, as on DV tape, and that floor is reached around the middle of the slider. With a keyframe interval, bits can be borrowed from the Buffer: once it's used up, a cut or a keyframe has to fit in one frame's share, lands as coarse blocks, and sharpens over the frames that follow; tighter still, the codec skips frames and the picture freezes for a moment. It starts to bite sooner at a high Quality."),
        DigitalParam(
            id: "rate_buffer", label: "Buffer", group: .compression,
            kind: .slider(min: 0, max: 5, percent: false, unit: "s"), defaultValue: 1,
            help: "How far ahead of the Bitrate limit the codec may run: this many seconds' worth of bits to borrow for a keyframe, a cut or a burst of motion, paid back by the frames after it. Small, every keyframe and cut collapses into blocks and recovers; large, they pass cleanly and the picture sags later instead, when the buffer runs out. Each keyframe starts a fresh buffer. Works on Bitrate limit, and needs a keyframe interval above 0."),
        DigitalParam(
            id: "deblocking", label: "Deblocking", group: .compression,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The decoder smoothing block edges, as H.264 does. Off keeps the hard tiles of older codecs; on trades them for smear."),
        DigitalParam(
            id: "generations", label: "Generations", group: .compression,
            kind: .slider(min: 0, max: 20, percent: false, unit: ""), defaultValue: 0,
            help: "How many more times the picture has been decoded and compressed again at the same Quality: a video saved and re-uploaded over and over. Each time its blocks land a few pixels from where the last ones were, so block edges turn into ringing, the ringing into mush, and color bleeds and drifts — the deep-fried look. 0 is the first compression alone.",
            step: 1),
        DigitalParam(
            id: "data_loss", label: "Data loss", group: .errors,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Lost packets or tape dropouts. The decoder patches the gap from the last picture it had. Every frame on its own (DV), the patches flash and vanish; between keyframes, they smear and drift until the next keyframe."),
        DigitalParam(
            id: "loss_pattern", label: "Loss pattern", group: .errors,
            kind: .choice(["Packets", "DV tape", "Clogged head"]), defaultValue: 0,
            help: "Where Data loss falls. Packets: runs of blocks in reading order, as a stream loses them. DV tape: DV scatters each track's blocks over five rectangles of the picture, so a dropout shows as small stale blocks repeated in a regular pattern, a scratch holds its pattern for a while, and a lost track freezes five whole rectangles. Clogged head: one of the two heads reads badly, so every other band of the picture (a tenth of its height each) breaks up and freezes. The two tape patterns hold the last good picture until new data arrives; about once a second the tape reads clean and everything catches up."),
        DigitalParam(
            id: "concealment", label: "Lost blocks show", group: .errors,
            kind: .choice(["Last picture", "Gray", "Green", "Stretched"]), defaultValue: 0,
            help: "What the decoder puts where data was lost. Last picture is the usual patch. Gray and Green are decoders that leave the gap empty: flat gray, or the green of an all-zero picture. Stretched fills the gap by pulling the row above it downward. Between keyframes, whatever is put there is then dragged around by the motion that follows. Works on Data loss, so it needs some."),
        DigitalParam(
            id: "bit_errors", label: "Bit errors", group: .errors,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Damaged data that still arrives, and is decoded wrong. A block's detail turns into a bright striped or checkered pattern; a brightness or color error carries on along the row as a band, sometimes down the rest of the picture; the rest of a row lands a block or two out of place. Every frame on its own, the damage flashes; between keyframes it stays, and moves with the picture, until the next keyframe."),
        DigitalParam(
            id: "datamosh", label: "Datamosh", group: .errors,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Keyframes thrown away. The changes that follow are applied to the old picture instead of the new one: motion drags the previous scene's pixels around until a keyframe gets through. Needs a keyframe interval above 0."),
        DigitalParam(
            id: "mosh_motion", label: "Added motion", group: .errors,
            kind: .choice(["None", "Pan", "Tilt", "Zoom", "Swirl"]), defaultValue: 0,
            help: "Motion the decoder is told about that never happened, like a camera move's frames repeated over and over (a datamosher's \"bloom\"): the picture is pushed along it a block at a time with nothing to correct it, melting until the next keyframe puts it right. It gives a still picture something to mosh with; on a clip it adds to the clip's own motion. Needs a keyframe interval above 0; turn up Datamosh to keep the keyframes from repairing it."),
        DigitalParam(
            id: "mosh_speed", label: "Motion speed", group: .errors,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0.5,
            help: "How fast the added motion pushes the picture, and which way: right or left, down or up, in or out, clockwise or counterclockwise. At 100% the picture's edge moves a fortieth of its width every frame."),
    ]

    /// The settings the stage starts with in a new window (it starts
    /// switched off), and what a user gets the first time they switch it
    /// on: Finn's "MiniDV tape" look (2026-11-22) — a one-chip camcorder
    /// at 24 frames a second, DV's quarter-width color decoded blocky,
    /// strong aliasing, a little sharpening and grain — because MiniDV is
    /// what most people switching this on are looking for. Kept apart from
    /// each control's `defaultValue`, which formats, double-click resets
    /// and looks saved before a control existed rely on. Only this stage's
    /// values: the Downscale and the other stages stay as they are.
    public static let startingValues: [String: Double] = defaultValues.merging([
        "frame_rate": 24,
        "fields": 1,
        "sensor": 2,
        "smear": 0,
        "aliasing": 0.8209776182432433,
        "sensor_noise": 0.37214335851899205,
        "low_light_noise": 0.135962134009009,
        "noise_reduction": 0,
        "ccd_response": 0.16154631193693694,
        "white_balance": 0,
        "tint": 0,
        "saturation": 1,
        "sharpening": 0.2507859421921922,
        "sharpening_width": 1.2710830023435595,
        "codec": 0,
        "block_size": 1,
        "chroma": 3,
        "chroma_upsampling": 1,
        "quality": 0.749,
        "keyframe_interval": 0,
        "fixed_bitrate": 0,
        "bitrate_limit": 0,
        "rate_buffer": 1,
        "deblocking": 0,
        "generations": 0,
        "data_loss": 0,
        "loss_pattern": 0,
        "concealment": 0,
        "bit_errors": 0,
        "datamosh": 0,
        "mosh_motion": 0,
        "mosh_speed": 0.5,
    ]) { _, new in new }

    public static let byID: [String: DigitalParam] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static var defaultValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultValue) })
    }

    /// Controls that set the stream's structure — when frames are captured,
    /// where keyframes fall, the color layout, and how the sensor samples
    /// through the lens. They hold for a whole render (keyframes on
    /// the timeline don't animate them).
    public static let structureIDs: Set<String> = ["frame_rate", "keyframe_interval", "chroma",
                                                    "fields", "aliasing", "codec", "sensor", "block_size"]

    /// Controls that do nothing with a codec, so the panel hides them:
    /// Video 1 keeps full-resolution color, has no deblocking, no motion
    /// for a datamosh to drag, and (here) only the plain patch for lost
    /// blocks, no coefficients for bit errors to damage, blocks of one size
    /// and no bit count for a limit to act on.
    public static let unusedBy: [DigitalCodecKind: Set<String>] = [
        .blockColors: ["chroma", "chroma_upsampling", "deblocking", "datamosh",
                       "concealment", "bit_errors", "mosh_motion", "mosh_speed",
                       "block_size", "bitrate_limit", "rate_buffer"],
    ]

    public func applies(to codec: DigitalCodecKind) -> Bool {
        !(Self.unusedBy[codec]?.contains(id) ?? false)
    }
}

public enum DigitalCodecKind: Int, CaseIterable, Sendable {
    /// The MPEG / H.263 / DV family (`DigitalCodec`).
    case dct = 0
    /// Microsoft Video 1 (`Video1Codec`).
    case blockColors
}

/// The Sensor control: how the camera separates color.
public enum SensorKind: Int, CaseIterable, Sendable {
    /// A prism and a sensor for each of red, green and blue.
    case threeChips = 0
    /// One sensor under a mosaic of red, green and blue filters.
    case mosaic
    /// One sensor under cyan, yellow, magenta and green filters, read two
    /// rows at a time: the 90s one-chip camcorder.
    case complementary
}

/// The Fields control: what becomes of an interlaced camera's two fields.
public enum FieldMode: Int, CaseIterable, Sendable {
    /// Whole frames, every line from one moment.
    case progressive = 0
    /// One field, each line shown twice (the chain gets half the lines).
    case oneField
    /// Both fields in one frame: lines alternate between two moments.
    case woven
    /// Both fields mixed together (a blend deinterlacer).
    case blended

    /// Two moments in one frame: needs the frame before as well.
    public var isInterlaced: Bool { self == .woven || self == .blended }
}

public enum ChromaSubsampling: Int, CaseIterable, Sendable {
    case full = 0, halfWide, halfBoth, quarterWide

    /// Chroma plane step (luma pixels per chroma sample) across and down.
    public var factors: (x: Int, y: Int) {
        switch self {
        case .full: return (1, 1)
        case .halfWide: return (2, 1)
        case .halfBoth: return (2, 2)
        case .quarterWide: return (4, 1)
        }
    }
}

/// The Digital video stage's settings for one moment, keyed by
/// `DigitalParam.id` (the same flat form looks and keyframes store).
public struct DigitalSettings: Equatable, Hashable, Sendable {
    public var values: [String: Double]

    public init(values: [String: Double] = DigitalParam.defaultValues) {
        self.values = DigitalParam.defaultValues.merging(values) { _, new in new }
    }

    public subscript(_ id: String) -> Double {
        values[id] ?? DigitalParam.byID[id]?.defaultValue ?? 0
    }

    public var codec: DigitalCodecKind {
        DigitalCodecKind(rawValue: Int(self["codec"].rounded())) ?? .dct
    }

    /// The color layout the codec codes: Video 1 always keeps full color.
    public var chroma: ChromaSubsampling {
        if codec == .blockColors { return .full }
        return ChromaSubsampling(rawValue: Int(self["chroma"].rounded())) ?? .halfBoth
    }

    /// How the camera separates color.
    public var sensor: SensorKind {
        SensorKind(rawValue: Int(self["sensor"].rounded())) ?? .threeChips
    }

    /// How the camera's two fields reach the codec.
    public var fields: FieldMode {
        FieldMode(rawValue: Int(self["fields"].rounded())) ?? .progressive
    }

    /// The DCT codec's block size in pixels (Video 1's structure is fixed).
    public var blockSize: Int {
        guard codec == .dct else { return 8 }
        return [4, 8, 16][min(2, max(0, Int(self["block_size"].rounded())))]
    }

    /// The Bitrate limit as bits for each pixel of a frame; 0 is no limit.
    /// The slider runs evenly through the ratio: about 2 at its start,
    /// 0.01 at 100%.
    public var bitsPerPixel: Double {
        let v = min(1, effective("bitrate_limit"))
        return v <= 0 ? 0 : Self.loosestBitsPerPixel * pow(Self.tightestBitsPerPixel / Self.loosestBitsPerPixel, v)
    }
    public static let loosestBitsPerPixel = 2.0, tightestBitsPerPixel = 0.01

    /// The Bitrate limit in kbps for a capture size and rate, nil when off.
    public func bitrateKbps(width: Int, height: Int, fps: Double) -> Double? {
        let bpp = bitsPerPixel
        return bpp > 0 ? bpp * Double(width * height) * fps / 1000 : nil
    }

    /// The same as words for the panel: "≈ 163 kbps at 320 × 240, 15 fps".
    public func bitrateLabel(width: Int, height: Int, sourceFPS: Double) -> String? {
        let fps = DigitalTiming(sourceFPS: sourceFPS, settings: self).captureFPS
        guard let kbps = bitrateKbps(width: width, height: height, fps: fps) else { return nil }
        let rate = kbps >= 1000 ? String(format: kbps >= 10_000 ? "%.0f Mbps" : "%.1f Mbps", kbps / 1000)
            : String(format: kbps >= 10 ? "%.0f kbps" : "%.1f kbps", kbps)
        return "≈ \(rate) at \(width) × \(height), \(Int(fps)) fps"
    }

    /// How many more times the picture is compressed (the Generations control).
    public var generations: Int { max(0, Int(self["generations"].rounded())) }

    /// A control's value as the codec uses it: 0 for controls it doesn't
    /// have (deblocking and datamosh under Video 1).
    public func effective(_ id: String) -> Double {
        DigitalParam.unusedBy[codec]?.contains(id) == true && id != "chroma" ? 0 : self[id]
    }

    /// Values saved before 0.19 (look version 1), mapped onto today's
    /// controls: Exposure and Black level became CCD response (the stronger
    /// of the two decides), Lens softness is gone, and Quality moved to an
    /// even curve — converted to the value giving the same quantizer.
    public static func migrated(_ values: [String: Double], lookVersion: Int) -> [String: Double] {
        var v = values
        if lookVersion < 2, let q = v["quality"] { v["quality"] = DigitalCodec.qualityFromJPEGScale(q) }
        let exposure = v.removeValue(forKey: "exposure")
        let black = v.removeValue(forKey: "black_level")
        v.removeValue(forKey: "lens_blur")
        if v["ccd_response"] == nil, exposure != nil || black != nil {
            v["ccd_response"] = min(1, max(0, (exposure ?? 0) / 0.6, (black ?? 0) / 0.08))
        }
        return v
    }

    /// The same settings with the structure controls taken from `base`.
    public func holdingStructure(of base: DigitalSettings) -> DigitalSettings {
        var v = values
        for id in DigitalParam.structureIDs { v[id] = base[id] }
        return DigitalSettings(values: v)
    }
}

/// A named starting point: the stage's settings plus the capture width,
/// which becomes the Downscale width.
public struct DigitalFormat: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let width: Int
    public let values: [String: Double]
    public let blurb: String

    public static let all: [DigitalFormat] = [
        DigitalFormat(
            id: "webcam", name: "Webcam (2005)", width: 320,
            values: ["frame_rate": 15, "aliasing": 0.15,
                     "sensor_noise": 0.4, "noise_reduction": 0.5,
                     "ccd_response": 0.5, "white_balance": -0.15, "saturation": 0.85,
                     "sharpening": 0.25, "chroma": 2,
                     "quality": 0.749, "keyframe_interval": 0, "fixed_bitrate": 0,
                     "deblocking": 0, "data_loss": 0, "datamosh": 0],
            blurb: "320 × 240, 15 fps, a noisy sensor, each frame compressed on its own."),
        DigitalFormat(
            id: "video_call", name: "Video call", width: 320,
            values: ["frame_rate": 15, "sensor_noise": 0.25, "noise_reduction": 0.6,
                     "ccd_response": 0.3, "saturation": 0.9, "chroma": 2,
                     "quality": 0.749, "keyframe_interval": 4, "fixed_bitrate": 0.8,
                     "deblocking": 0.6, "data_loss": 0.15, "datamosh": 0],
            blurb: "A squeezed bitrate and lost packets that smear until the next keyframe."),
        DigitalFormat(
            id: "minidv", name: "MiniDV", width: 720,
            values: ["frame_rate": 30, "fields": 1, "aliasing": 0.6,
                     "sensor_noise": 0.12, "noise_reduction": 0,
                     "ccd_response": 1, "white_balance": 0.4, "tint": 0.2, "saturation": 1.15,
                     "sharpening": 0.6, "chroma": 3,
                     "quality": 0.894, "keyframe_interval": 0, "fixed_bitrate": 0.3,
                     "deblocking": 0, "data_loss": 0, "datamosh": 0],
            blurb: "The VX1000 skate-video look: one field line-doubled, hard sharpening, aliasing and color moiré, blown highlights, warm saturated color, gray blacks, color at a quarter width (4:1:1)."),
        DigitalFormat(
            id: "early_web", name: "Early web video", width: 320,
            values: ["frame_rate": 15, "sensor_noise": 0, "noise_reduction": 0, "chroma": 2,
                     "quality": 0.651, "keyframe_interval": 5, "fixed_bitrate": 0.7,
                     "deblocking": 0, "data_loss": 0, "datamosh": 0],
            blurb: "240p streaming: few bits, coarse blocks, and keyframes that pump."),
        DigitalFormat(
            id: "cd_rom", name: "CD-ROM (Video 1)", width: 240,
            values: ["codec": 1, "frame_rate": 12, "sensor_noise": 0, "noise_reduction": 0,
                     "quality": 0.57, "keyframe_interval": 1.25, "fixed_bitrate": 0,
                     "data_loss": 0],
            blurb: "Video for Windows off a 90s CD-ROM: 240 wide, 12 fps, Microsoft Video 1's flat two-tone blocks and banded 15-bit color, a keyframe every 15 frames."),
        DigitalFormat(
            id: "datamosh", name: "Datamosh", width: 480,
            values: ["frame_rate": 30, "sensor_noise": 0, "noise_reduction": 0, "chroma": 2,
                     "quality": 0.826, "keyframe_interval": 1, "fixed_bitrate": 0.3,
                     "deblocking": 0, "data_loss": 0, "datamosh": 1],
            blurb: "Keyframes removed: motion drags the old picture around."),
    ]

    public static let byID: [String: DigitalFormat] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The format these values (and width) match exactly, if any.
    public static func matching(values: [String: Double], width: Int) -> DigitalFormat? {
        let s = DigitalSettings(values: values)
        return all.first { f in
            f.width == width && DigitalParam.all.allSatisfy { abs(s[$0.id] - DigitalSettings(values: f.values)[$0.id]) < 1e-9 }
        }
    }
}
