import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers
import CrtCore

struct ExportPanel: View {
    @Environment(AppState.self) private var state

    @State private var exportWidth: Int = 1920
    @State private var exportHeight: Int = 1080
    @State private var status: String = ""
    @State private var working: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)

            HStack {
                Stepper("W \(exportWidth)", value: $exportWidth, in: 64...8192, step: 64)
                Stepper("H \(exportHeight)", value: $exportHeight, in: 64...8192, step: 64)
            }
            .font(.caption)

            Button(working ? "Exporting…" : "Export PNG…") {
                exportPNG()
            }
            .disabled(state.sourceTexture == nil || state.chain == nil || working)

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportPNG() {
        guard let source = state.sourceTexture, let chain = state.chain else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt-output.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        working = true
        status = "Rendering…"

        let device = state.context.device
        let queue = state.context.queue
        guard let target = makeRenderTarget(device: device, width: exportWidth, height: exportHeight),
              let staging = makeStagingTexture(device: device, width: exportWidth, height: exportHeight),
              let cb = queue.makeCommandBuffer() else {
            status = "Failed to allocate textures"
            working = false
            return
        }

        do {
            try state.pipeline.encode(into: cb,
                                      chain: chain,
                                      inputTexture: source,
                                      outputTexture: target,
                                      downscale: state.downscaleSpec,
                                      frameCount: state.frameCounter)
        } catch {
            status = "Render failed: \(error.localizedDescription)"
            working = false
            return
        }

        guard let blit = cb.makeBlitCommandEncoder() else {
            status = "Blit encoder failed"; working = false; return
        }
        blit.copy(from: target,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: exportWidth, height: exportHeight, depth: 1),
                  to: staging,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        cb.addCompletedHandler { _ in
            DispatchQueue.main.async {
                do {
                    let cg = try makeCGImage(from: staging)
                    try writePNG(cg, to: url)
                    status = "Wrote \(url.lastPathComponent) (\(exportWidth) × \(exportHeight))"
                } catch {
                    status = "Write failed: \(error.localizedDescription)"
                }
                working = false
            }
        }
        cb.commit()
    }
}
