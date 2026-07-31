# NTSCRT

![NTSCRT: VHS + CRT pipeline on the left of the split, untouched source on the right](docs/screenshot.webp)

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
- Full Xcode (App Store) — only for `swift test` (XCTest) and universal `--arch` builds; the app itself builds with the CLT
- Rust toolchain (`brew install rust`) — to build librashader from source

## Build

```sh
git submodule update --init --recursive

# Build librashader once (universal). The `stable` feature lets it compile on
# stable Rust. Homebrew's rust is host-only; install rustup for the x86_64
# target: brew install rustup && rustup toolchain install stable &&
#         rustup target add --toolchain stable x86_64-apple-darwin
# PINNED to 76462c03: newer librashader changes crt-royale rendering
# (verified ~8/255 mean pixel change). Re-run the crt-smoke byte-compare
# against current renders before ever bumping this.
git clone https://github.com/SnowflakePowered/librashader.git /tmp/librashader-src
git -C /tmp/librashader-src checkout 76462c03
TC="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin"
(cd /tmp/librashader-src && RUSTC="$TC/bin/rustc" "$TC/bin/cargo" build --release -p librashader-capi --features stable --target aarch64-apple-darwin)
(cd /tmp/librashader-src && RUSTC="$TC/bin/rustc" "$TC/bin/cargo" build --release -p librashader-capi --features stable --target x86_64-apple-darwin)
lipo -create /tmp/librashader-src/target/aarch64-apple-darwin/release/liblibrashader_capi.dylib /tmp/librashader-src/target/x86_64-apple-darwin/release/liblibrashader_capi.dylib -output Vendor/librashader/librashader.dylib
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

The "VHS (ntsc-rs)" panel appears enabled-able in the sidebar when the dylib is present (the app runs fine without it). Its controls are generated from ntsc-rs's own settings schema, and settings use ntsc-rs's preset JSON format — presets copy/paste both ways with the ntsc-rs desktop app. Turn on **Animate** in the view palette (floating over the preview) to see noise, jitter, and tracking move; frame-seeded randomness means exports are deterministic.

Env overrides: `CRT_NTSCRS=<dylib path>`, `CRT_NTSC=1` (start with the stage enabled).

## Tests

```sh
./scripts/test.sh
```

Covers the preview's sizing rules — that integer scale snaps to whole
multiples of the chain input and letterboxes, that the chain still renders at
enough rows per source line for the shader to look the same at any window
size, and that the step between the two stays an exact integer factor. Those
requirements pull against each other, and a fix for one silently broke the
other once. `scripts/make-release.sh` runs the suite as a gate.

The wrapper exists because XCTest ships with full Xcode, not the Command Line
Tools, and `xcode-select` here points at the CLT — so it sets `DEVELOPER_DIR`
for the test run only (no `sudo xcode-select` needed) and uses its own scratch
path, since the two toolchains can't share a build database. Plain
`swift test` works too if `xcode-select -p` already points at Xcode.

## Bundled presets

Drop a `.json` look preset into `presets/` and rebuild — `wrap-app.sh` and
`make-release.sh` copy the folder into `Contents/Resources/presets`, and the
app lists whatever it finds there under Save/Load in the Preset menu, named
after the file. No code change needed to add one.

## Dev hooks (env vars)

For iteration and headless/screenshot verification:

- `CRT_SOURCE=<path>` — preload an image or video at launch
- `CRT_PRESET=<id>` — start on a shader preset (ids in `Presets.swift`, e.g. `royale`, `hyllian`)
- `CRT_NTSC=1` — start with the VHS stage enabled
- `CRT_NTSCRS` / `CRT_LIBRASHADER` / `CRT_PRESETS` — override dylib/shader locations
- `CRT_PERF_LOG=1` — log chain-render vs composite-only draws, plus fps / ms-per-draw / main-thread duty cycle every 60 frames
- `CRT_DUMP_CONTROLS=1` — print the param→control classification for every preset, then exit
- `CRT_FORCE_MANAGED=1` — use `.managed` CPU-readback textures (the discrete-GPU path) even on unified memory
- `CRT_PALETTE_FADE=<seconds>` — override the floating view palette's 2 s idle fade
- `CRT_SHOW_EXPORT=1` — open the Export popover at launch
- `CRT_TIMELINE=1` — open the keyframe timeline at launch (image sources)
- `CRT_TL_DEMO=1` — open the timeline and drop two demo keyframes on it
- `CRT_TL_SELFTEST=<out.mp4>` — headless end-to-end check of the keyframe export: builds a two-key animation, renders it to `<out.mp4>`, exits
- `CRT_GIF_SELFTEST=<out.gif>` — render a GIF headlessly and exit (image source → keyframed GIF, video source → decimated GIF). `CRT_GIF_W`, `CRT_GIF_FPS`, `CRT_GIF_SECONDS` override the defaults and `CRT_GIF_PLAIN=1` skips the keyframes; the run prints bytes-per-pixel-per-frame, which is how `GifExporter.estimatedBytes` was calibrated
- `CRT_EXPORT_FORMAT=<GIF|H.264|…>` — preselect an export format at launch
- `CRT_SNAP=1` — turn on "snap size to scanline grid" at launch
- `CRT_NTSC_OFF=1` / `CRT_NTSC_SET="key=value,…"` — disable the VHS stage, or set individual ntsc-rs values, to bisect a rendering artifact
- `CRT_INTEGER_OFF=1` / `CRT_COMPARE_OFF=1` — start with integer scale or compare off
- `CRT_WINDOW_SIZE=WxH` — force the window size, so both letterbox parities can be reproduced deliberately
- `CRT_SCALE_LOG=1` — log drawable/target sizes and letterbox parity on each size change
- `CRT_PANEL_BENCH=1` — time showing/hiding each VHS group's children and exit (`CRT_PANEL_BENCH_ORDER=a,b,c` picks the groups). Collapsing near the TOP of the panel costs more, since every row below is re-laid out — measured 40 ms for the first group vs ~9 ms mid-list
- `CRT_NO_HOUSE_ORDER=1` — keep ntsc-rs's own setting order (Intensity not hoisted), for that A/B
- `CRT_DUMP_NTSC_LAYOUT=1` — print the NTSC panel's grouping/label tree and exit (verifies `NtscSetting.houseLayout`)
- `CRT_LOAD_BUILTIN=<name>` — list the bundled presets, load one by name, report what it restored (and whether it opened the timeline), then exit
- `CRT_LOOK_PRESETS=<dir>` — override where bundled look presets are read from
- `CRT_PLAY_BENCH=<seconds>` — play the loaded video and report the frame rate actually achieved (with `CRT_PERF_LOG=1`, also per-frame work vs wall clock)
- `CRT_PLAY_FRAME_CHECK=<n>` — play to frame n, then verify the decoded frame matches the *seeked* frame n more closely than its neighbours (guards against the sequential decoder drifting out of step)
- `CRT_FORCE_SEEK_DECODE=1` — decode playback frames by seeking to each one (the old, slow path; also what rotated tracks use)
- `CRT_LOOP_TEST=<out.mp4>` / `CRT_STILL_LOOP_TEST=<out.mp4>` (+ `CRT_LOOP_N=<n>`) — export a looped video from a clip or a still and report the frame count, for checking duration and audio continuity
- `CRT_VIDEO_TL_TEST=<out.gif>` — keyframe a *video* source headlessly and assert the timeline follows the clip: length from the clip, scrubbing seeks it, playhead quantizes to frames, editing while parked rewrites the key (half-frame tolerance), and a keyframed export renders
- `CRT_PRESET_ROUNDTRIP=<out.json>` — save a preset with a keyframed timeline, wipe the state, load it back, and assert duration/frame rate/keyframe times/easings/captured values all survived; prints PASS/FAIL and exits
- `CRT_TL_AUTOKEY_TEST=1` — assert the auto-key rules (edit on a keyframe rewrites it, edits between keyframes don't, scrubbing never mutates), print PASS/FAIL, exit
- `CRT_COMPARE_X=<0…1>` — place the compare divider at launch (edge-case captures)
- `CRT_FRONT=1` — activate the app at launch
- `CRT_DUMP_TOOLTIPS=1` — print every NSView carrying tooltip text, plus what a click at its centre hits, then exit
- `CRT_HOVER_LOG=1` — log preview hover events and the palette's measured frame

**Verifying hover/tooltip behaviour:** `CGWarpMouseCursorPosition` moves the cursor *without* posting events, so it cannot drive SwiftUI's `.onHover`/`.onContinuousHover` (AppKit's tooltip manager polls the cursor, so tooltips *do* appear that way — an easy false positive). Real synthetic movement needs `CGEventPost`, which needs Accessibility. Use `CRT_DUMP_TOOLTIPS`/`CRT_HOVER_LOG` for ground truth instead of screenshots.

## Releasing (signed + notarized DMG)

One-time setup (requires an Apple Developer Program membership):

1. Create a **Developer ID Application** certificate: developer.apple.com → Account → Certificates → "+" → Developer ID Application. Create the CSR with Keychain Access (Certificate Assistant → Request a Certificate From a Certificate Authority), upload it, download the .cer and double-click to install.
2. Store notarization credentials (uses an app-specific password from appleid.apple.com → Sign-In and Security):

   ```sh
   xcrun notarytool store-credentials ntscrt-notary --apple-id YOU@EXAMPLE.COM --team-id YOURTEAMID
   ```

Then every release is:

```sh
./scripts/make-release.sh 0.1.0
gh release create v0.1.0 dist/NTSCRT-0.1.0.dmg --title "NTSCRT 0.1.0"
```

The script builds everything, assembles a fully self-contained bundle (shaders in Resources/, both dylibs in Frameworks/), signs with hardened runtime, notarizes, staples, and produces a drag-to-Applications DMG. `--adhoc` skips signing/notarization for local testing.

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
  `nearest | nearest+ | bilinear | bicubic | lanczos | area`

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
