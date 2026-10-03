import SwiftUI
import CrtCore

// The export options, in one place: the Export popover and the Video
// Feedback panel both show these views, bound to the same settings in
// AppState, so an option added or changed here reaches both — and a
// render made from either uses the same values.

/// Output size: the long edge, and the size it gives at the source's aspect.
struct ExportSizeOptions: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 4) {
            Stepper("Long edge \(state.exportLongEdge) px",
                    value: $state.exportLongEdge, in: 64...8192, step: 64)
                .font(.caption)
            let size = state.exportVideoSize
            Text("Output: \(size.width) × \(size.height) px (matches source aspect)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Format, loop count, scanline snapping, and quality — or, for a GIF, its
/// own width and frame rate with a size estimate.
struct ExportVideoOptions: View {
    @Environment(AppState.self) private var state
    /// How long one pass of the export runs, in seconds (for the loop
    /// caption and the GIF size estimate).
    let lengthSeconds: Double

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Format").font(.caption)
                Picker("", selection: $state.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if !state.exportFormat.isGIF {
                HStack(spacing: 6) {
                    Text("Loop").font(.caption)
                    IntField(value: $state.exportLoopCount, range: 1...100, width: 44)
                    Text(state.exportLoopCount == 1 ? "× (plays once)"
                                                    : "× (\(loopedLengthText))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tooltip("Repeat the content this many times in the exported file, so it runs longer somewhere that won't loop it for you. 1 plays through once. GIFs loop forever on their own, so this doesn't apply to them.")
            }

            Toggle("Snap size to scanline grid", isOn: $state.snapExportToScanlineGrid)
                .toggleStyle(.checkbox)
                .font(.caption)
                .tooltip("Round the output so every source line gets the same whole number of rows — the sizes where scanlines land perfectly even. Off, the exporter renders larger and averages down instead, which keeps your exact dimensions.")

            if state.exportFormat.isGIF {
                gifControls
            } else if !state.exportFormat.isProRes {
                HStack {
                    Text("Quality").font(.caption)
                    Picker("", selection: $state.exportQuality) {
                        ForEach(ExportQuality.allCases, id: \.self) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                    Text(String(format: "≈ %.1f Mbps",
                                Double(state.exportBitrate(for: state.exportVideoSize)) / 1_000_000))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Scanline detail is brutal on codecs — use High or above, or ProRes for editing.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Length of the export once looped, for the field's caption.
    private var loopedLengthText: String {
        let total = lengthSeconds * Double(max(1, state.exportLoopCount))
        return total >= 60
            ? String(format: "%d:%04.1f total", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
            : String(format: "%.1f s total", total)
    }

    /// GIF gets its own width and frame rate — the video settings produce
    /// files nothing will accept (see GifExporter).
    private var gifControls: some View {
        @Bindable var state = state
        let size = state.exportGifSize
        let frames = max(1, Int((lengthSeconds * Double(state.gifFPS)).rounded(.down)))
        let bytes = GifExporter.estimatedBytes(width: size.width, height: size.height, frames: frames)
        let trueFPS = GifExporter.trueFPS(for: state.gifFPS)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Width").font(.caption)
                IntField(value: $state.gifWidth, range: 64...4096, width: 56)
                Text("px").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $state.gifFPS) {
                    ForEach([6, 12, 24, 30], id: \.self) { f in
                        Text("\(f) fps").tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .tooltip("GIF size and frame rate. Height follows the source aspect ratio.")

            Text("\(size.width) × \(size.height) px  ·  \(frames) frames  ·  ≈ \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(bytes > 10_000_000 ? .orange : .secondary)

            if bytes > 10_000_000 {
                Text("Most platforms cap GIFs around 10–15 MB. Drop the width or frame rate.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("GIF is 256 colours and compresses noise badly, so size climbs fast. Estimate assumes a noisy look; clean ones come in under.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if abs(trueFPS - Double(state.gifFPS)) > 0.2 {
                // GIF delays are whole hundredths of a second, so the rate
                // lands on that grid rather than exactly where asked.
                Text(String(format: "Plays at %.1f fps (GIF timing grid).", trueFPS))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension AppState {
    /// One line describing the current export settings ("1920 × 1080 ·
    /// H.264 · High"), for places that show them without the controls.
    var exportSummary: String {
        if exportFormat.isGIF {
            let s = exportGifSize
            return "\(s.width) × \(s.height) GIF · \(gifFPS) fps"
        }
        let s = exportVideoSize
        let quality = exportFormat.isProRes ? "" : " · \(exportQuality.rawValue)"
        let loops = exportLoopCount > 1 ? " · ×\(exportLoopCount)" : ""
        return "\(s.width) × \(s.height) · \(exportFormat.rawValue)\(quality)\(loops)"
    }
}
