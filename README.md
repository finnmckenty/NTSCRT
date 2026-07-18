# NTSCRT

A native macOS app for recreating vintage analog TV and VHS images: [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) emulates the analog signal path (composite artifacts, tape noise, head switching), and RetroArch's CRT shaders — run through [librashader](https://github.com/SnowflakePowered/librashader), so output matches RetroArch frame-for-frame — draw the display. Pipeline: **NTSC (full res) → downscale → CRT shader**, on stills or video, with a normal mouse/keyboard UI.

To be clear about what this is: **I basically hacked two much better projects together.** All of the actual image magic is ntsc-rs and the RetroArch shader ecosystem; this repo is the SwiftUI/Metal glue between them.

## Credits

- [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) — the NTSC/VHS signal emulation (MIT/ISC/Apache-2.0). The VHS panel is generated from its own settings schema, and its preset JSON works in both apps.
- [librashader](https://github.com/SnowflakePowered/librashader) by SnowflakePowered — the RetroArch-compatible shader runtime (MPL-2.0).
- [libretro/slang-shaders](https://github.com/libretro/slang-shaders) and the RetroArch community — the CRT shader presets themselves (crt-royale by TroggleMonkey, crt-easymode/crt-aperture by EasyMode, crt-hyllian by Hyllian, crtsim, crtglow — various licenses, largely GPL).

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
# Use release — the app encodes GPU work on every preview draw, and debug
# (-Onone) Swift/SwiftUI glue is noticeably slower. Plain `swift build`
# (debug) still works for iteration.
swift build -c release --product crt-smoke
swift build -c release --product crt-app
```

## Optional: the VHS stage (ntsc-rs)

The app can run [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) as a CPU signal-degradation stage: NTSC/VHS artifacts are applied at the source's full resolution, then the degraded signal is downscaled into the CRT shader (NTSC full res → downscale → CRT). Composite artifacts, tape noise, head switching, chroma bleed — enable scale_settings → "scale with video size" for artifact sizes that track the input resolution. Build it once:

```sh
git submodule update --init --recursive   # brings in Vendor/ntsc-rs
./scripts/build-ntscrs.sh                 # cargo-builds Vendor/ntscrs-capi/ntscrs_capi.dylib
```

The "VHS (ntsc-rs)" panel appears enabled-able in the sidebar when the dylib is present (the app runs fine without it). Its controls are generated from ntsc-rs's own settings schema, and settings use ntsc-rs's preset JSON format — presets copy/paste both ways with the ntsc-rs desktop app. Turn on **Animate** in the View panel to see noise, jitter, and tracking move; frame-seeded randomness means exports are deterministic.

Env overrides: `CRT_NTSCRS=<dylib path>`, `CRT_NTSC=1` (start with the stage enabled).

## Run the SwiftUI app

Two options.

### Bare CLI (quick iteration)

```sh
./.build/release/crt-app
```

The window may open behind other windows because SPM-built executables aren't proper `.app` bundles, so macOS treats them as background processes. Click Cmd-Tab to focus.

**Don't `open` the bare executable or double-click it in Finder** — Launch Services may hand it to Xcode for "editing".

### As a proper Mac app (recommended)

```sh
./scripts/wrap-app.sh
open build/NTSCRT.app
```

The script wraps the SPM-built binary in `build/NTSCRT.app` with a minimal `Info.plist`, embeds `librashader.dylib` under `Contents/Frameworks/`, ad-hoc signs it, and bakes the absolute path of `Vendor/slang-shaders/` into `LSEnvironment.CRT_PRESETS` so it can find presets from any launch context. Re-run after any rebuild. It bundles the release binary by default; pass `debug` to wrap a debug build instead.

### How it finds external assets

In order:

1. `CRT_LIBRASHADER` and `CRT_PRESETS` env vars
2. Walking up from the executable looking for `Vendor/librashader/librashader.dylib` and `Vendor/slang-shaders/`

The bare CLI relies on (2). The wrapped `.app` baked-in `LSEnvironment` makes (1) work regardless of cwd.

## CLI usage

```sh
.build/release/crt-smoke <input> <preset.slangp> <output.png> <librashader.dylib> \
                         [outW outH] [downW downH method]
```

- `outW outH` — final output / shader viewport size (default 1920×1080)
- `downW downH method` — optional pre-shader downscale. `method` ∈
  `nearest | bilinear | bicubic | lanczos | area`

Example: 4K image → 256×224 (lanczos) → crt-royale → 1080p PNG:

```sh
.build/release/crt-smoke ~/Pictures/source.png \
  Vendor/slang-shaders/crt/crt-royale.slangp ~/Desktop/out.png \
  Vendor/librashader/librashader.dylib 1920 1080 256 224 lanczos
```

The smoke binary prints all runtime parameters declared by the preset (the things the eventual UI will turn into sliders).

### crt-sweep: measuring parameter effects

`crt-sweep` renders every runtime parameter of each preset at its min and max and reports the mean pixel difference vs the default render — the tool used to verify which params are dead, weak, or gated behind another parameter (the app's gray-out rules in `Sources/CrtApp/ParamGates.swift` were derived and verified with it).

```sh
.build/release/crt-sweep <input.png> Vendor/slang-shaders Vendor/librashader/librashader.dylib \
    [--out W H] [--down W H method | --no-down] [--presets id1,id2] [--set NAME=VALUE]
```

`--set` pins a parameter for the whole sweep — use it to open a gate, e.g. `--set CURVATURE=1` to measure the warp params that only apply with curvature on. Params dead on a static frame are retried at frameCount 37 and reported `ANIM-ONLY` if they respond.

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
