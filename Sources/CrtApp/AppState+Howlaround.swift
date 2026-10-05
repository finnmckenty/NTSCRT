import Foundation
import AppKit
import CrtCore

// MARK: - export sizes (shared by the Export popover and the Howlaround panel)

extension AppState {
    /// Video export size: the requested long edge at the source's aspect,
    /// even (H.264 requires it), snapped onto the scanline grid if asked.
    var exportVideoSize: (width: Int, height: Int) {
        let aspect = sourceAspect
        let longEdge = exportLongEdge
        let w: Int, h: Int
        if aspect >= 1 {
            w = longEdge
            h = max(64, Int((Double(longEdge) / Double(aspect)).rounded()))
        } else {
            h = longEdge
            w = max(64, Int((Double(longEdge) * Double(aspect)).rounded()))
        }
        return snappedExportSize(width: w & ~1, height: h & ~1)
    }

    var exportGifSize: (width: Int, height: Int) {
        let w = max(64, gifWidth)
        let h = max(64, Int((Double(w) / Double(sourceAspect)).rounded()))
        return snappedExportSize(width: w & ~1, height: h & ~1)
    }

    /// With snapping on, round onto the scanline grid (see ScanlineGrid).
    func snappedExportSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard snapExportToScanlineGrid else { return (width, height) }
        let input = chainInputSize
        guard input.width > 0, input.height > 0 else { return (width, height) }
        let s = ScanlineGrid.snappedSize(inputWidth: input.width, inputHeight: input.height,
                                         targetHeight: height)
        return (s.width & ~1, s.height & ~1)
    }

    func exportBitrate(for size: (width: Int, height: Int)) -> Int {
        let fps = videoSource.map { Double($0.frameRate) } ?? Double(timelineFPS)
        return max(2_000_000, Int(Double(size.width * size.height) * fps * exportQuality.bitsPerPixel))
    }

    /// The NTSC stage's settings for an export, nil when it's off.
    var exportNtscJSON: String? {
        (ntscEnabled && ntscAvailable) ? ntscStage?.settingsJSON() : nil
    }

    /// Per-frame keyframe values spread over the whole render, or nil when
    /// nothing is keyed.
    var exportFrameParams: FrameParams? {
        guard timelineEnabled, !timelineKeys.isEmpty, let ev = makeTimelineEvaluator() else { return nil }
        let glitchBase = glitchValues
        return { i, total in
            let t = total > 1 ? Double(i) / Double(total - 1) : 0
            return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                    glitch: ev.glitchSettings(at: t, base: glitchBase))
        }
    }
}

// MARK: - howlaround

extension AppState {
    var howlaroundSettings: HowlaroundSettings { HowlaroundSettings(values: howlaroundValues) }

    func setHowlaroundValue(_ id: String, _ value: Double) {
        setHowlaroundValues([id: value])
    }

    /// Several knobs at once (the preview's dots set up to four), with one
    /// new draft — and none when nothing changed.
    func setHowlaroundValues(_ values: [String: Double]) {
        guard values.contains(where: { howlaroundValues[$0.key] != $0.value }) else { return }
        howlaroundValues.merge(values) { _, new in new }
        scheduleHowlaroundDraft()
    }

    func resetHowlaround() {
        howlaroundValues = HowlaroundParam.defaultValues
        scheduleHowlaroundDraft()
    }

    /// The whole render's length in seconds: what a move spans.
    var howlRenderLength: Double { videoSource?.durationSeconds ?? howlaroundSeconds }

    /// The vanishing point and drift in words, under the preview: "Vanishing
    /// point 20% left, 22% up · drifts to 10% right and back".
    var howlaroundReadout: String {
        let s = howlaroundSettings
        guard s.tvInView else { return "Zoom is 0%: the camera doesn't see the TV, so there's no tunnel." }
        let start = HowlaroundParam.describe(s.vanishingPoint)
        var text = "Vanishing point " + (start == "the middle" ? "in the middle" : start)
        if s.driftTarget == s.vanishingPoint {
            text += " · no drift"
        } else {
            text += " · drifts to " + HowlaroundParam.describe(s.driftTarget) + (s.loop ? " and back" : "")
        }
        return text
    }

    /// How many copies the current framing shows (nil = they grow instead).
    var howlaroundCopies: Int? {
        howlaroundSettings.visibleCopies(aspect: Double(sourceAspect),
                                         chainHeight: max(16, chainInputSize.height))
    }

    // Builders: the panel's Render and Draft and the headless check all build
    // their settings here, from the Export builders, so a howlaround gets
    // exactly the look an export would.

    func howlaroundMp4Settings(outputURL: URL, size: (width: Int, height: Int), bitrate: Int,
                               codec: Mp4Exporter.Codec, render: HowlaroundRender,
                               loops: Int) -> Mp4Exporter.Settings {
        var s = mp4ExportSettings(route: videoSource == nil ? .still : .video, outputURL: outputURL,
                                  size: size, bitrate: bitrate, codec: codec)
        // A clip repeats in passes inside the exporter; a still's repeats are
        // rendered frames (see renderHowlaround).
        s.loopCount = videoSource == nil ? 1 : loops
        s.howlaround = render
        return s
    }

    func howlaroundGifSettings(outputURL: URL, size: (width: Int, height: Int),
                               render: HowlaroundRender) -> GifExporter.Settings {
        var s = gifExportSettings(outputURL: outputURL, size: size)
        s.howlaround = render
        return s
    }

    /// Render a howlaround to `url`. `draftSeconds` makes a short render
    /// (of a video: its first seconds); nil renders the whole thing — a still
    /// for `howlaroundSeconds`, a video for its full length.
    func renderHowlaround(to url: URL, gif: Bool, size: (width: Int, height: Int),
                          draftSeconds: Double?, cancel: HowlaroundCancel?,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        howlActiveRenders += 1
        if howlActiveRenders > 1 { howlOverlapSeen = true }
        defer { howlActiveRenders -= 1 }
        let params = paramValues
        let ntscJSON = exportNtscJSON
        let frameParams = exportFrameParams
        let codec = exportFormat.codec ?? .h264
        let bitrate = exportBitrate(for: size)
        // The Export settings' Loop repeats a full render (GIFs loop by
        // themselves); a draft is always one pass.
        let loops = draftSeconds == nil && !gif ? max(1, exportLoopCount) : 1
        if let vs = videoSource {
            let length = vs.durationSeconds
            if gif {
                let limit = draftSeconds.map { max(1, Int(($0 * Double(gifFPS)).rounded())) }
                let render = HowlaroundRender(settings: howlaroundSettings, length: length,
                                              frameLimit: limit, cancel: cancel)
                let settings = howlaroundGifSettings(outputURL: url, size: size, render: render)
                try await GifExporter(context: context).exportVideo(
                    source: vs, paramValues: params, settings: settings, ntscSettingsJSON: ntscJSON,
                    frameParams: frameParams, progress: progress)
            } else {
                let limit = draftSeconds.map { max(1, Int(($0 * Double(max(1, vs.frameRate))).rounded())) }
                let render = HowlaroundRender(settings: howlaroundSettings, length: length,
                                              frameLimit: limit, cancel: cancel)
                let settings = howlaroundMp4Settings(outputURL: url, size: size, bitrate: bitrate,
                                                     codec: codec, render: render, loops: loops)
                try await Mp4Exporter(context: context).export(
                    source: vs, paramValues: params, settings: settings, ntscSettingsJSON: ntscJSON,
                    frameParams: frameParams, progress: progress)
            }
        } else if let source = sourceTexture {
            // A draft of a still covers its start; the move still spans the
            // whole length, so the draft shows the start of the same move.
            let seconds = min(howlaroundSeconds, draftSeconds ?? howlaroundSeconds)
            let render = HowlaroundRender(settings: howlaroundSettings, length: howlaroundSeconds,
                                          cancel: cancel)
            if gif {
                let frames = max(1, Int((seconds * Double(gifFPS)).rounded()))
                let settings = howlaroundGifSettings(outputURL: url, size: size, render: render)
                try await GifExporter(context: context).exportStill(
                    source: source, totalFrames: frames, paramValues: params, settings: settings,
                    ntscSettingsJSON: ntscJSON, frameParams: frameParams, progress: progress)
            } else {
                let fps = timelineFPS
                let frames = max(1, Int((seconds * Double(fps)).rounded())) * loops
                let settings = howlaroundMp4Settings(outputURL: url, size: size, bitrate: bitrate,
                                                     codec: codec, render: render, loops: loops)
                try await Mp4Exporter(context: context).exportStill(
                    source: source, totalFrames: frames, fps: fps, paramValues: params,
                    settings: settings, ntscSettingsJSON: ntscJSON, frameParams: frameParams,
                    progress: progress)
            }
        } else {
            throw NSError(domain: "VideoFeedback", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Open an image or a video first."])
        }
    }

    // MARK: draft

    /// The draft's size: small, so it comes back in a second or two. The
    /// loop itself runs at a fixed size, so the draft shows the same tunnel
    /// the full render will — just less sharp.
    var howlDraftSize: (width: Int, height: Int) {
        let aspect = Double(sourceAspect)
        let long = 480.0
        let w = aspect >= 1 ? long : long * aspect
        let h = aspect >= 1 ? long / aspect : long
        return (max(64, Int(w.rounded())) & ~1, max(64, Int(h.rounded())) & ~1)
    }

    /// Drafts cover the whole render up to this long — a move spans the
    /// whole render, so a short draft would miss most of it.
    static let howlDraftSeconds = 10.0

    /// How long the draft runs: the whole render, up to `howlDraftSeconds`.
    var howlDraftLength: Double {
        min(Self.howlDraftSeconds, videoSource?.durationSeconds ?? howlaroundSeconds)
    }

    /// Re-render the draft shortly after the knobs stop moving. A draft still
    /// running is canceled and allowed to wind down first: two renders must
    /// never drive the shared Metal queue (and librashader) at once.
    func scheduleHowlaroundDraft(delay: Duration = .milliseconds(350)) {
        guard sourceTexture != nil || videoSource != nil else { return }
        howlDraftCancel?.cancel()
        let previous = howlDraftTask
        howlDraftGeneration += 1
        let generation = howlDraftGeneration
        howlDraftTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            await previous?.value
            guard let self, generation == self.howlDraftGeneration, !self.howlRenderWorking else { return }
            let cancel = HowlaroundCancel()
            self.howlDraftCancel = cancel
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ntscrt-feedback-draft-\(generation).mp4")
            self.howlDraftWorking = true
            self.howlDraftProgress = 0
            self.howlDraftStatus = "Rendering draft…"
            let started = Date()
            do {
                try await self.renderHowlaround(to: url, gif: false, size: self.howlDraftSize,
                                                draftSeconds: Self.howlDraftSeconds, cancel: cancel,
                                                progress: { p in
                                                    Task { @MainActor in
                                                        if generation == self.howlDraftGeneration {
                                                            self.howlDraftProgress = p
                                                        }
                                                    }
                                                })
                guard generation == self.howlDraftGeneration else { return }
                if let old = self.howlDraftURL, old != url { try? FileManager.default.removeItem(at: old) }
                self.howlDraftURL = url
                self.howlDraftStatus = String(format: "Draft · %.1f s at %d px · rendered in %.1f s",
                                              self.howlDraftLength, self.howlDraftSize.width,
                                              Date().timeIntervalSince(started))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                if generation == self.howlDraftGeneration {
                    self.howlDraftStatus = "Draft failed: \(error.localizedDescription)"
                }
            }
            if generation == self.howlDraftGeneration { self.howlDraftWorking = false }
        }
    }

    /// Stop any draft and wait for it to finish (before a full render, or
    /// when the panel closes).
    func stopHowlaroundDraft() async {
        howlDraftGeneration += 1
        howlDraftCancel?.cancel()
        await howlDraftTask?.value
        howlDraftWorking = false
    }

    // MARK: full render

    func renderHowlaroundFile(to url: URL) {
        let gif = exportFormat.isGIF
        let size = gif ? exportGifSize : exportVideoSize
        let cancel = HowlaroundCancel()
        howlRenderCancel = cancel
        howlRenderWorking = true
        howlRenderProgress = 0
        howlRenderStatus = "Rendering…"
        howlLastOutput = nil
        exportInProgress = true
        Task { @MainActor in
            await self.stopHowlaroundDraft()
            do {
                try await self.renderHowlaround(to: url, gif: gif, size: size, draftSeconds: nil,
                                                cancel: cancel) { p in
                    Task { @MainActor in self.howlRenderProgress = p }
                }
                self.howlRenderStatus = "Wrote \(url.lastPathComponent) (\(size.width) × \(size.height))"
                self.howlLastOutput = url
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                self.howlRenderStatus = "Render canceled"
            } catch {
                self.howlRenderStatus = "Render failed: \(error.localizedDescription)"
            }
            self.howlRenderWorking = false
            self.howlRenderProgress = 1
            self.howlRenderCancel = nil
            // Closed meanwhile: nothing else is holding the preview paused.
            if !self.howlPanelOpen { self.exportInProgress = false }
        }
    }

    func cancelHowlaroundRender() {
        howlRenderCancel?.cancel()
    }

    // MARK: presets (their own folder — FeedbackPresets)

    func saveFeedbackPreset(to url: URL) throws {
        // Version 2: the American ids and the drift as a line (see
        // HowlaroundParam.migrated, which reads version 1 too).
        var dict: [String: Any] = ["kind": FeedbackPresets.kind, "version": 2, "values": howlaroundValues]
        if videoSource == nil { dict["seconds"] = howlaroundSeconds }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func loadFeedbackPreset(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["kind"] as? String == FeedbackPresets.kind,
              let values = dict["values"] as? [String: Double] else {
            throw NSError(domain: "VideoFeedback", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Not a Screen Loop preset. Look presets load from the toolbar's Preset menu."])
        }
        howlaroundValues = HowlaroundParam.defaultValues.merging(HowlaroundParam.migrated(values)) { _, new in new }
        if let seconds = dict["seconds"] as? Double { howlaroundSeconds = min(60, max(0.5, seconds)) }
        scheduleHowlaroundDraft()
    }
}
