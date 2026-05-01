# crt-app

A native macOS tool that runs RetroArch CRT shaders on still images and (eventually) video, with a normal mouse/keyboard UI instead of RetroArch's gamepad menus. Built around [librashader](https://github.com/SnowflakePowered/librashader), so output matches RetroArch frame-for-frame.

Status:
- **Phase 1** — librashader bridge: working, all 6 shaders verified.
- **Phase 1+** — downscale pre-pass: working, all 5 sampling methods verified.
- **Phase 2** — SwiftUI app shell with sidebar (source / downscale / shader / export panels) and live MTKView preview: builds and launches. Visual verification of the window UI is pending (waiting on full Xcode for proper iteration).
- **Phase 3** — video pipeline: not yet built.

## Layout

```
Sources/
  CrtAppBridge/    Objective-C wrapper around librashader's Metal C API
  CrtCore/         Shared Swift: Downscaler, Pipeline, ImageIO, presets list
  CrtSmoke/        CLI verifier: input image → optional downscale → shader → PNG
  CrtApp/          SwiftUI app: sidebar UI + MTKView preview + PNG export
Vendor/
  librashader/     librashader.dylib + headers (built locally; not in git)
  slang-shaders/   submodule of libretro/slang-shaders (preset .slangp files)
```

## Prerequisites

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) — enough for the CLI
- Full Xcode (App Store) — required for the SwiftUI app target (Phase 2)
- Rust toolchain (`brew install rust`) — to build librashader from source

## Build

```sh
git submodule update --init --recursive

# Build librashader once. The `stable` feature lets it compile on stable Rust.
git clone --depth 1 https://github.com/SnowflakePowered/librashader.git /tmp/librashader-src
(cd /tmp/librashader-src && cargo build --release -p librashader-capi --features stable)
cp /tmp/librashader-src/target/release/liblibrashader_capi.dylib Vendor/librashader/librashader.dylib
install_name_tool -id @rpath/librashader.dylib Vendor/librashader/librashader.dylib

# Build the CLI verifier and the SwiftUI app.
swift build --product crt-smoke
swift build --product crt-app
```

## Run the SwiftUI app

Two options.

### Bare CLI (quick iteration)

```sh
./.build/debug/crt-app
```

The window may open behind other windows because SPM-built executables aren't proper `.app` bundles, so macOS treats them as background processes. Click Cmd-Tab to focus.

**Don't `open` the bare executable or double-click it in Finder** — Launch Services may hand it to Xcode for "editing".

### As a proper Mac app (recommended)

```sh
./scripts/wrap-app.sh
open build/CrtApp.app
```

The script wraps the SPM-built binary in `build/CrtApp.app` with a minimal `Info.plist`, embeds `librashader.dylib` under `Contents/Frameworks/`, ad-hoc signs it, and bakes the absolute path of `Vendor/slang-shaders/` into `LSEnvironment.CRT_PRESETS` so it can find presets from any launch context. Re-run after any rebuild.

### How it finds external assets

In order:

1. `CRT_LIBRASHADER` and `CRT_PRESETS` env vars
2. Walking up from the executable looking for `Vendor/librashader/librashader.dylib` and `Vendor/slang-shaders/`

The bare CLI relies on (2). The wrapped `.app` baked-in `LSEnvironment` makes (1) work regardless of cwd.

## CLI usage

```sh
.build/debug/crt-smoke <input> <preset.slangp> <output.png> <librashader.dylib> \
                       [outW outH] [downW downH method]
```

- `outW outH` — final output / shader viewport size (default 1920×1080)
- `downW downH method` — optional pre-shader downscale. `method` ∈
  `nearest | bilinear | bicubic | lanczos | area`

Example: 4K image → 256×224 (lanczos) → crt-royale → 1080p PNG:

```sh
.build/debug/crt-smoke ~/Pictures/source.png \
  Vendor/slang-shaders/crt/crt-royale.slangp ~/Desktop/out.png \
  Vendor/librashader/librashader.dylib 1920 1080 256 224 lanczos
```

The smoke binary prints all runtime parameters declared by the preset (the things the eventual UI will turn into sliders).

## The 6 target shaders

All in `Vendor/slang-shaders/crt/`:

| User name      | File                                    |
| -------------- | --------------------------------------- |
| crt-aperture   | `crt-aperture.slangp`                   |
| crt-easymode   | `crt-easymode.slangp`                   |
| crtglow (gauss)   | `crtglow_gauss.slangp`               |
| crtglow (lanczos) | `crtglow_lanczos.slangp`             |
| crt-hyllian    | `crt-hyllian.slangp`                    |
| crt-royale     | `crt-royale.slangp`                     |
| crtsim         | `crtsim.slangp`                         |

## Notes on the bridge

`Sources/CrtAppBridge/LibrashaderBridge.{h,m}` exposes a small Objective-C class `LRShaderChain`:

- `+loadLibrary:error:` — `dlopen`s the librashader dylib at an explicit path, then resolves all symbols by name. Verifies ABI version match.
- `-initWithPresetPath:commandQueue:error:` — parses a `.slangp`, snapshots its runtime parameters, builds a Metal filter chain.
- `-renderInputTexture:outputTexture:viewport:frameCount:commandBuffer:error:` — encodes one frame of the chain into a command buffer.
- `-parameters` / `-setParameter:value:error:` / `-parameterValue:` — UI-facing slider plumbing.

Swift sees these as `throws` methods via NSError bridging.

The librashader Metal runtime is **not thread-safe**. All chain calls must happen on the same dispatch queue that drives the Metal command buffer.

## Roadmap

- **Phase 2**: SwiftUI app shell (sidebar with shader picker / params / downscale / export, MTKView preview). Needs full Xcode.
- **Phase 3**: video. `AVAssetReader` for input, `AVAssetWriterInputPixelBufferAdaptor` for MP4 export, scrub-only preview.
