# crt-app

A native macOS tool that runs RetroArch CRT shaders on still images and (eventually) video, with a normal mouse/keyboard UI instead of RetroArch's gamepad menus. Built around [librashader](https://github.com/SnowflakePowered/librashader), so output matches RetroArch frame-for-frame.

Status: **Phase 1 (librashader bridge) + downscale pre-pass: working via CLI.** SwiftUI app shell and video pipeline still to come.

## Layout

```
Sources/
  CrtAppBridge/    Objective-C wrapper around librashader's Metal C API
  CrtSmoke/        CLI verifier: input image → optional downscale → shader → PNG
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

# Build the CLI verifier.
swift build --product crt-smoke
```

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
