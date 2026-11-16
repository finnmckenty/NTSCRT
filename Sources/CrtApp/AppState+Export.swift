import Foundation
import CrtCore

// MARK: - movie exports (the Export popover's buttons and `NTSCRT render`)
//
// The popover picks a file and calls `runMovieExport`; the command line
// calls `exportMovie` directly. Both reach the exporters through here, so
// what the command line renders is what the Export button would have.

extension AppState {
    /// What a movie export writes for the loaded source and format.
    enum MovieRoute: String {
        /// A GIF, of a clip or a still.
        case gif
        /// A clip, re-encoded through the look.
        case clip
        /// A video made from a still (VHS motion, or its keyframes).
        case still
    }

    struct MovieExportResult {
        let url: URL
        let width: Int
        let height: Int
        let frames: Int
        let fps: Double
        var seconds: Double { fps > 0 ? Double(frames) / fps : 0 }
    }

    enum MovieExportError: Swift.Error, LocalizedError {
        case notReady
        var errorDescription: String? { "The source and the CRT shader aren't loaded yet." }
    }

    var movieRoute: MovieRoute {
        if exportFormat.isGIF { return .gif }
        return videoSource != nil ? .clip : .still
    }

    var hasTimelineKeys: Bool { timelineEnabled && !timelineKeys.isEmpty }

    /// The output size the route uses.
    var movieExportSize: (width: Int, height: Int) {
        movieRoute == .gif ? exportGifSize : exportVideoSize
    }

    /// Frames a GIF holds: the clip's length (or the timeline's) at the
    /// GIF's own frame rate.
    var gifFrameCount: Int {
        if let vs = videoSource {
            let seconds = Double(vs.totalFrames) / Double(max(1, vs.frameRate))
            return max(1, Int((seconds * Double(gifFPS)).rounded(.down)))
        }
        return max(1, Int((timelineDuration * Double(gifFPS)).rounded()))
    }

    /// Frames and frame rate the export will write.
    var movieExportFrames: (frames: Int, fps: Double) {
        switch movieRoute {
        case .gif:
            return (gifFrameCount, Double(gifFPS))
        case .clip:
            let vs = videoSource!
            return (vs.totalFrames * max(1, exportLoopCount), Double(max(1, vs.frameRate)))
        case .still:
            return (timelineTotalFrames * max(1, exportLoopCount), Double(timelineFPS))
        }
    }

    /// Render the loaded source through the look into `url`, by the
    /// current export format. The caller keeps the preview from touching
    /// the Metal queue meanwhile (`exportInProgress`).
    func exportMovie(to url: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> MovieExportResult {
        guard let source = sourceTexture, chain != nil else { throw MovieExportError.notReady }
        let route = movieRoute
        let size = movieExportSize
        let (frames, fps) = movieExportFrames
        let params = paramValues
        let ntscJSON = exportNtscJSON
        let glitchBase = glitchValues
        let receptionOn = glitchEnabled
        let evaluator = hasTimelineKeys ? makeTimelineEvaluator() : nil

        switch route {
        case .gif:
            let settings = gifExportSettings(outputURL: url, size: size)
            let exporter = GifExporter(context: context)
            // GIFs loop forever by themselves, so the animation spans the
            // whole file rather than repeating in passes.
            let frameParams: FrameParams? = evaluator.map { ev in
                { i, total in
                    let t = total > 1 ? Double(i) / Double(total - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                            glitch: ev.glitchSettings(at: t, base: glitchBase, receptionOn: receptionOn))
                }
            }
            if let vs = videoSource {
                try await exporter.exportVideo(source: vs, paramValues: params, settings: settings,
                                               ntscSettingsJSON: ntscJSON,
                                               frameParams: exportFrameParams, progress: progress)
            } else {
                try await exporter.exportStill(source: source, totalFrames: frames,
                                               paramValues: params, settings: settings,
                                               ntscSettingsJSON: ntscJSON,
                                               frameParams: frameParams, progress: progress)
            }

        case .clip:
            let vs = videoSource!
            let settings = mp4ExportSettings(route: .video, outputURL: url, size: size,
                                             bitrate: exportBitrate(for: size),
                                             codec: exportFormat.codec ?? .h264)
            try await Mp4Exporter(context: context).export(
                source: vs, paramValues: params, settings: settings,
                ntscSettingsJSON: ntscJSON, frameParams: exportFrameParams, progress: progress)

        case .still:
            let settings = mp4ExportSettings(route: .still, outputURL: url, size: size,
                                             bitrate: exportBitrate(for: size),
                                             codec: exportFormat.codec ?? .h264)
            let baseFrames = timelineTotalFrames
            // Keyframes drive per-frame parameters; without keys the params
            // hold and only the frame-seeded VHS noise animates.
            let frameParams: FrameParams? = evaluator.map { ev in
                { i, _ in
                    // Phase within the pass, so each loop replays the
                    // animation instead of stretching it across all passes.
                    let within = i % baseFrames
                    let t = baseFrames > 1 ? Double(within) / Double(baseFrames - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                            glitch: ev.glitchSettings(at: t, base: glitchBase, receptionOn: receptionOn))
                }
            }
            try await Mp4Exporter(context: context).exportStill(
                source: source, totalFrames: frames, fps: timelineFPS,
                paramValues: params, settings: settings, ntscSettingsJSON: ntscJSON,
                frameParams: frameParams, progress: progress)
        }
        return MovieExportResult(url: url, width: size.width, height: size.height,
                                 frames: frames, fps: fps)
    }

    /// The Export popover's movie button: export, reporting progress and
    /// the outcome in the popover's status line.
    func runMovieExport(to url: URL) {
        guard sourceTexture != nil, chain != nil else { return }
        exportWorking = true
        exportProgress = 0
        exportStatus = movieRoute == .gif ? "Encoding GIF…" : "Encoding…"
        // Suspend preview animation and playback for the duration: the
        // exporter drives the same Metal queue from its own loop and
        // librashader's Metal runtime is not thread-safe.
        stopPlayback()
        stopTimelinePreview()
        exportInProgress = true
        Task { @MainActor in
            do {
                let r = try await exportMovie(to: url) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                var detail = "\(r.width) × \(r.height)"
                if movieRoute == .gif {
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    detail += ", " + ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0), countStyle: .file)
                }
                exportStatus = "Wrote \(url.lastPathComponent) (\(detail))"
                exportProgress = 1
            } catch {
                exportStatus = (movieRoute == .gif ? "GIF export failed: " : "Export failed: ")
                    + error.localizedDescription
            }
            exportWorking = false
            exportInProgress = false
        }
    }

    /// `exportPNG`, awaited.
    func exportPNG(to url: URL, size: (width: Int, height: Int)) async -> Bool {
        await withCheckedContinuation { c in
            exportPNG(to: url, size: size) { c.resume(returning: $0) }
        }
    }
}
