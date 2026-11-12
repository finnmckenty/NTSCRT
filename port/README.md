# NTSCRT for Windows (in progress)

The Windows version, in Rust on wgpu. Nothing here is used by the Mac app, which stays Swift. Plan and status: [docs/windows-port-plan.md](../docs/windows-port-plan.md).

## What's here

- `engine/` — the pipeline: Digital video → ntsc-rs → downscale (WGSL ports of the Mac's kernels; One field) → Glitch → librashader on wgpu. Plus Screen Loop (`howl/`): the camera, the ring of TV pictures and the vanishing-point pad.
- `codec/` — `ntscrt-codec`, the Digital video stage (camera, DCT codec, Video 1), a port of `Sources/CrtCodec` with its tests; `codec/ref` runs the Swift original for parity.
- `app/` — `ntscrt`, the Windows app (egui): pictures and video, crop, Downscale (all six methods), the Digital video, NTSC, Glitch and CRT panels, looks and presets (the Mac's JSON) with the Digital video formats, the timeline, Screen Loop (drafts as you turn the knobs, renders with the Export settings, its own presets), the Mac's preview (integer scale, Live noise, zoom, Compare), and Export: PNG, MP4 (H.264/HEVC with the clip's sound, looped) and GIF.
- `media/` — video in and out through Media Foundation, and pictures the `image` crate can't read (HEIC) through Windows Imaging Component (Windows only): decoding with frames numbered the Mac's way; MP4 writing with the source's sound re-encoded as AAC. `media-probe` decodes chosen frames to PNGs (`--image` reads a picture through WIC).
- `spike/` — `ntscrt-spike`: a still through the engine from the command line, mirroring the Mac's `crt-smoke`. Plus `compare`, which measures how far two PNGs differ.
- `spike/ref-mac/` — `crt-smoke` renders of all seven CRT shaders, with and without NTSC, as references.
- `fetch-librashader.sh` + `librashader-wgpu-push-constants.patch` — librashader at the Mac app's pinned commit, with a fix its wgpu runtime needs at that commit.

## Build

```sh
port/fetch-librashader.sh          # once; Git Bash on Windows
cd port && cargo build --release   # target/release/ntscrt(.exe), ntscrt-spike, compare
```

## Check against the Mac

From `port/`:

```sh
target/release/ntscrt-spike ../TestAssets/testpattern.png ../Vendor/slang-shaders/crt/crt-royale.slangp out.png 1280 960 320 240 area --ntsc default
COMPARE_BORDER=8 target/release/compare spike/ref-mac/crt-royale-ntsc.png out.png
```

- `NTSCRT_BACKEND=gl|dx12|vulkan|metal` picks the graphics backend (the spike also reads `SPIKE_BACKEND`).
- The app's hooks: `NTSCRT_SOURCE=<picture or clip>`, `NTSCRT_LOOK=<look.json>`, `NTSCRT_CROP=ratio[,x,y,zoom]`, `NTSCRT_COMPARE=1`, `NTSCRT_PLAY=1` (or seconds to wait first), `NTSCRT_PROFILE=1` (where each preview frame's time goes, on stderr), `NTSCRT_ANIMATE=0`; `NTSCRT_EXPORT=<file.png|mp4|gif>` exports once the preview is up (with `NTSCRT_EXPORT_HEVC=1`, `NTSCRT_EXPORT_LOOPS=n`, `NTSCRT_EXPORT_QUALITY=0–3`), writes the result to `<file>.log` and quits; `NTSCRT_DUMP_SETTINGS=<file>` writes the settings an export got; `NTSCRT_SCREEN_LOOP=1` opens Screen Loop (`NTSCRT_SCREEN_LOOP_PRESET=<preset.json>` loads one), `NTSCRT_SCREEN_LOOP_RENDER=<file.mp4|gif>` renders it, writes `<file>.log` and quits; `NTSCRT_UI_SNAPSHOT=<png>` saves a screenshot of the window once the latest frame is on screen (after `NTSCRT_SNAPSHOT_AFTER` seconds), then quits.
- `COMPARE_BORDER=n` leaves out n edge pixels. `COMPARE_MAX_MEAN=x` fails above a mean difference of x.
- GitHub Actions runs every case on Windows for each push that touches `port/` (`.github/workflows/windows-port.yml`).

## The Windows VM

`scripts/win-vm.sh [--user] < script.ps1` runs PowerShell in the Parallels VM "Windows 11" through `prlctl`. Repo checkout: `C:\src\NTSCRT`.
