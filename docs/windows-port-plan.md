# NTSCRT for Windows — plan

Started 2026-11-11.

## Where we start

- About 19,000 lines of Swift. The interface (SwiftUI/AppKit), graphics (Metal: 24 files, including Metal kernels in Downscaler, GlitchStage and Howlaround) and video input/output (AVFoundation, ImageIO) don't exist on Windows.
- These already run on Windows:
  - **ntsc-rs** (Rust, CPU). Today we call it through our own small C shim, `Vendor/ntscrs-capi`.
  - **librashader**, pinned at `76462c03`. That commit already includes `librashader-runtime-wgpu` alongside the D3D11/D3D12/Vulkan/GL runtimes.
  - The **slang shaders**.
- Everything else (codec, Glitch receiver, Screen Loop, timeline, presets) is ordinary math and logic: it gets translated, not redesigned.
- ntsc-rs's own desktop app runs on Windows, built with **eframe/egui** and GStreamer. It's a useful reference for the toolchain.

## Decisions (confirmed by Finn, 2026-11-11)

| | Recommendation | Why |
|---|---|---|
| Architecture | **A Rust engine with the Windows app on top, in `port/`.** The Mac app — code, interface, build, releases — stays exactly as it is; it is the priority and is not touched for the port. New features get built twice (Swift for the Mac, Rust for Windows), kept in line by golden-image tests. | ntsc-rs and librashader are Rust already. |
| GPU | **wgpu**: D3D12/Vulkan on real PCs, GL in the VM (Metal when the Rust code runs on the Mac for testing) | librashader has a wgpu runtime; the engine can be built and checked on the Mac first. |
| Windows interface | **egui (eframe)** — confirmed | Fast to build; ntsc-rs proves it with the same libraries; the panels are mostly parameter lists, which egui does well. Less native-looking than WinUI. |
| Video in/out | **Media Foundation** (Windows' own) | Hardware H.264/HEVC decode and encode with no licensing burden. **No ProRes on Windows** (Finn: not needed). |
| GIF | A Rust GIF encoder with an MIT/BSD quantizer | Avoid `imagequant`/gifski, which are GPL/AGPL. |
| Targets | **x64** first (most users), plus native **ARM64** (the VM, Snapdragon laptops) | The VM runs both: ARM64 natively, x64 under emulation. |
| Looks | The **same JSON** as the Mac app | Looks and presets move between platforms. |

## Phase 0 — VM setup (done 2026-11-11)

- Parallels Desktop 27.1, Windows 11 on Arm (build 26300), VM "Windows 11".
  - 4 cores, 8 GB memory, 225 GB free.
  - Raise it to 6 cores and 12 GB if builds feel slow; the VM has to be shut down to change that.
- **No SSH or MCP needed.** `prlctl exec` (Parallels' own command-line tool) runs commands in the guest.
  - `scripts/win-vm.sh` wraps it: it takes a PowerShell script on stdin, sends it encoded so quoting survives, and runs it as SYSTEM, or as Finn's Windows account with `--user`.
  - Builds run with `--user`. winget doesn't work as SYSTEM.
- **Installed:**
  - Git 2.56.1 (ARM64; signature checked).
  - Visual Studio 2022 Build Tools (C++ with ARM64 and x64 compilers, Windows 11 SDK 26100; Microsoft-signed).
  - Rust 1.99.1 via rustup (host `aarch64-pc-windows-msvc`, plus the `x86_64-pc-windows-msvc` target; installer checked against the published SHA-256).
  - Installers are in `C:\setup`.
- **Repo:** `C:\src\NTSCRT`, cloned with submodules (ntsc-rs v0.9.4, slang-shaders). `core.autocrlf=false`, so test files stay byte-identical to the Mac's.
- **Toolchain check:** a test program builds and runs for both ARM64 (native) and x64 (emulated).
- **Graphics** (`C:\src\gpuprobe`, wgpu 30.0.1 adapter list):
  - `Gl | Parallels using Metal (Apple M1 Max) | IntegratedGpu | 4.3`: the **hardware path**.
  - `Dx12 | Microsoft Basic Render Driver | Cpu`: WARP, software only.
  - No Vulkan.
  - In the VM, wgpu should use the GL backend for speed. D3D12/WARP still works for matching output, slowly. Real PCs will use D3D12 or Vulkan.
- **wgpu 30 API note:** use `InstanceDescriptor::new_without_display_handle()`, which has no `Default`. `Instance::new` takes the descriptor by value, and `enumerate_adapters` is async.

## Phase 1 — Spike: **GO** (2026-11-11)

**The tool:** `port/spike` (`ntscrt-spike`) mirrors the Mac's `crt-smoke`:
- PNG → ntsc-rs at full resolution (CPU) → area downscale (WGSL port of the Metal kernel) → librashader on wgpu → PNG.
- It includes crt-smoke's self-test, which sets the preset's first parameter to its midpoint.
- `compare` reports RGB difference statistics. `COMPARE_BORDER=n` leaves out n edge pixels.

**Test cases:** 14 = 7 CRT shaders × {plain, NTSC default}. Input `TestAssets/testpattern.png` (640×480) → 320×240 area → 1280×960 output, frame 1. References are from `crt-smoke` (`port/spike/ref-mac`).

**Results** (difference out of 255):

| Where | Inside an 8 px border | Whole image |
|---|---|---|
| Mac, wgpu on Metal | 6 shaders: mean ≤ 0.008, max 1–6. crtsim: mean 0.23, max 28 | mean 0.03–0.45 |
| Windows ARM64, GL (Parallels → M1 Max) | **identical to the Mac row**, NTSC included | identical |
| Windows x64 (emulated), GL | **identical to the Mac row**, NTSC included | identical |
| Windows ARM64, D3D12 on WARP (software) | mean 0.06–0.92, max up to 85 (aperture) | mean 0.12–0.98 |

- ntsc-rs gives the same output on ARM and x64.
- The area downscale port is exact.

**Problem found and fixed: a librashader bug at our pin.**
- Its wgpu 27→28 bump (`5281c781`, January 2026) removed the pipeline-layout entry for push-constant blocks, but the draw code still binds them. Every shader failed with "Binding is missing from the pipeline layout".
- Fixed by restoring the uniform-buffer case (`port/librashader-wgpu-push-constants.patch`, applied in `port/vendor/librashader` through a Cargo `[patch]`).
- Upstream had already fixed it in `90d88d5a` (2026-05-21, "fix(wgsl): bind the PCB buffer"). Our pin predates that; `port/fetch-librashader.sh` checks out the pin and applies the patch.

**Follow-ups (not blocking):**
- The outermost 1–2 rows and columns differ, up to 125: edge sampling in the final pass differs between the Metal and wgpu runtimes.
- crtsim has thin vertical-line differences (likely naga's translation versus SPIRV-Cross for some shader operation).
- WARP differs more than hardware, as expected from a software rasterizer.
- Speed in the VM on GL: 0.3–0.6 s per still including startup, crt-royale about 2–3 s. That's the first run of each process and includes shader compilation, so it's not a frame rate.

**Continuous testing:** `.github/workflows/windows-port.yml` builds the spike on GitHub's `windows-latest` and checks all 14 cases (D3D12 on WARP, 8 px border, fails above a mean difference of 1.0) on every push that touches `port/`.

## Phase 2 — The engine, a piece at a time, checked against the Mac

The order follows the signal chain. Each piece gets a golden-image test: the Swift app renders references into `TestAssets/golden/`, and the Rust core must match within a set tolerance.

1. Crop, downscale (Chunky/Smooth, One field), scanline-grid sizing.
2. Digital video: camera, DCT codec, Video 1, timing and history. This is a straight translation of `CrtCodec`, which already has unit tests to port.
3. Glitch: the receiver simulation, plus its Metal kernels rewritten in WGSL.
4. Preview compositing (integer scale, zoom, compare split) and render-ahead caching.
5. Screen Loop.
6. Timeline: keyframes, easing, frame-exact evaluation.
7. Looks and presets: read and write the Mac JSON, including the migrations.

## Phase 3 — Media

- Media Foundation: decode MP4/MOV, seek frame-accurately, read sequentially (for the codec's re-runs), and encode H.264/HEVC .mp4 with audio passed through.
- PNG, JPEG and HEIC stills.
  - HEIC needs the "HEIF Image Extensions" from Microsoft's store, or gets skipped.
- GIF export with the same size estimate as the Mac.

## Phase 4 — The Windows app (egui)

- Generate the panels from the existing parameter tables, so the Windows app and the Mac app list the same controls with the same help text.
- Preview with palette, compare split, zoom and pan, transport bar.
- Timeline, Export, the Preset menu and the Screen Loop window.
- Use the same test hooks as the Mac app (environment variables), so Claude can verify headlessly over SSH.

## Phase 5 — Shipping

- Installer: start with a portable .zip plus an Inno Setup installer, and consider MSIX later.
- Code signing with **Azure Trusted Signing** (roughly $10 a month), to avoid Windows' "unknown publisher" warning.
- A GitHub Actions release job that builds x64 and ARM64, signs, and attaches the files to the same GitHub release as the Mac DMG.
- Bundle presets, shaders and license notices; the slang shaders are largely GPL, as on the Mac.
- **Before the first release:** test on real Windows hardware, an NVIDIA and an Intel/AMD machine, for speed and driver bugs. Use a borrowed PC, a cheap mini PC, or an hourly cloud PC with a graphics card.

## Where each kind of test runs

| Where | Graphics | Used for |
|---|---|---|
| Mac (wgpu on Metal) | M1 Max | The reference for matching output; fastest iteration |
| Parallels VM | GL or D3D12 WARP | Checking it works on Windows; x64 and ARM64 builds; the interface |
| GitHub Actions windows-latest | D3D12 WARP | Unit and golden tests on every push |
| Real PC | NVIDIA / Intel / AMD | Speed and drivers, before each release |

## Settled questions

- egui's look: yes.
- ProRes on Windows: not needed.
- The Mac app moving onto the Rust engine: no — the Mac app isn't touched.
