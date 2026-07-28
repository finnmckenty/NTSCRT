# NTSCRT

![NTSCRT — full VHS + CRT pipeline on the left of the split, untouched source on the right](docs/header.webp)

**Make any image or video look like it's playing on a 1980s TV.** NTSCRT runs your media through a real analog signal emulation ([ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) — composite artifacts, tape noise, head switching) and then through RetroArch's CRT shaders (via [librashader](https://github.com/SnowflakePowered/librashader) — scanlines, phosphor masks, glow), frame-identical to RetroArch itself.

Full disclosure: **this is two much better projects hacked together.** All of the actual image magic belongs to ntsc-rs and the RetroArch shader community; NTSCRT is the native Mac interface that connects them into one pipeline:

```
your image/video → NTSC/VHS signal degradation (full res) → downscale to retro resolution → CRT shader → screen
```

## Download

Grab the DMG from [**Releases**](../../releases/latest), open it, and drag **NTSCRT** to Applications.

**Requirements:** macOS 14 or later. The app is a universal binary (Apple Silicon + Intel).

> **Intel note:** I build and test NTSCRT on Apple Silicon and haven't personally tested the Intel build. Intel support exists thanks to a contributed fix ([#1](../../pull/1)) verified by its author on an Intel iMac Pro — if something misbehaves on your Intel Mac, please open an issue.

## Using the app

**Toolbar** — file actions live in the window toolbar: **Open** (⌘O) an image (PNG/JPEG/HEIC) or video (MP4/MOV), save/load a **Preset** (your entire configuration as a JSON file — downscale, VHS, shader, view, and the whole timeline: duration, frame rate and every keyframe), and **Export** (⌘E): stills to PNG; videos to H.264/HEVC .mp4, ProRes .mov (with audio), or animated **GIF**, at your choice of resolution and quality. Scanline detail is brutal on lossy codecs — use the High/Very high quality tiers, or ProRes when it's headed into an edit. Exports are deterministic: same settings + same frame = same pixels.

**Scanline banding.** CRT shaders draw scanlines in *output* pixels, so if the export height isn't a whole multiple of the downscale height, one source line covers a fractional number of rows and the scanlines group into visible bands. Exports handle this automatically — they render at a whole multiple and average down — so you can ask for any size. **Snap size to scanline grid** takes the other route: it rounds the output to the nearest size where every source line gets the same whole number of rows, which keeps scanlines at their crispest but changes your dimensions. As a rule of thumb, crisp scanlines want 3+ output rows per downscale line, so a 320px-wide downscale wants ~960px+ of output.

**GIF** gets its own width and frame rate (6/12/24/30 fps), because it doesn't behave like the video codecs: 256 colours and run-length compression versus full-frame analog noise means files run large — roughly 0.65–0.95 bytes per pixel per frame. A 5-second 480px GIF at 12 fps lands near 8 MB; at 1080px it would be 30 MB+, past what most platforms accept. The panel estimates the size before you export and warns past ~10 MB. GIF stores frame delays in hundredths of a second, so the rates land on that grid (12 fps plays at 12.5, 24 at 25, 30 at 33.3), and 60 fps isn't offered — GIF can't reliably go past 50.

**Preview** — the floating palette holds the display controls. **Compare** (split-square) divides the preview: full pipeline on the left of the line, untouched original on the right — drag the line to move the split. **Integer scale** (grid) locks the image to whole-pixel multiples for perfectly uniform scanlines. **Animate** (sparkles — the preview's own, distinct from the toolbar's timeline button) runs the preview continuously so tape noise, jitter, and interlacing actually move — leave it on for the real experience. Zoom with the slider (or ⌥-scroll), hold Space to pan when zoomed. The palette fades out when the mouse goes idle; move the mouse to bring it back. Videos get a transport bar docked under the preview — play/pause plus a full-width, frame-accurate scrubber, with all effects applied during playback.

**Animate (timeline)** — with an image loaded, toggle **Animate** in the toolbar to keyframe-animate the entire effect chain and render it as video: scrub the playhead, dial in a look, press **Keyframe** to set one, move the playhead, dial in another look, keyframe again. Everything keys together as one master keyframe — parameters you don't change between keys hold still automatically. Click a keyframe to jump to it, and any parameter you change from there updates that keyframe in place, the way After Effects and Premiere behave. Drag a diamond to retime it, pick its interpolation from the dropdown underneath (linear, ease in, ease out, ease in-out, hold), and set the video length and frame rate in the timeline itself — export uses those. Keyframe times are proportional, so changing the duration stretches the whole animation. Image sources can export video even without keyframes — tape noise, jitter, and interlacing animate on their own ("VHS motion").

**Sidebar** — the creative pipeline, top to bottom in signal order:

- **Source** — the loaded file (drag & drop onto the panel works too).
- **Downscale** — the retro horizontal resolution the CRT shader sees (SNES 256px, VGA 320px, or any custom width — height always follows your source's aspect ratio) and the resampling method. Nearest keeps pixels crunchy (best for pixel art), Nearest+ keeps the punch without shimmering on video, Area is the smooth neutral choice.
- **NTSC (TV)** — the analog signal stage: composite noise, chroma bleed, head switching, tracking noise, tape speed, edge wave, and about sixty more. These are ntsc-rs's own settings — preset JSON copy/pastes both ways with the [ntsc-rs desktop app](https://github.com/ntsc-rs/ntsc-rs/releases).
- **CRT** — seven RetroArch CRT presets (crt-royale, crt-hyllian, crt-aperture, crt-easymode, two crtglow variants, crtsim) with every runtime parameter exposed. Grayed-out controls tell you which switch activates them — many CRT parameters only apply when their feature (curvature, mask, geometry mode…) is on.

**Tips**

- Every value next to a slider is a text field — click and type exact numbers.
- The effect reads best on game-art-style content: dark scenes, bright sprites, hard edges. Photos work too, but analog artifacts live on contrast.
- High-resolution sources: turn on **Intensity → Scale with video size** in the NTSC panel so artifact sizes track your input, and expect the NTSC stage to take longer per frame.

## Limitations

- The Intel half of the universal build is community-tested, not author-tested (see the note up top).
- The NTSC stage runs on the CPU at your source's full resolution — with **Animate** on or during video playback, 4K+ sources will noticeably drop the preview frame rate. Exports always render every frame regardless.
- Video preview playback favors correctness over speed and can run below native fps on heavy footage; the exported MP4 is full quality.
- A few crt-royale parameters are compile-time disabled in the shader itself (marked "static in this shader build") — they do nothing in RetroArch either.
- No undo — save Presets before big experiments.

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full developer setup (Swift + Rust toolchains, vendored dependencies, CLI tools, release pipeline).

## Credits

- [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) — the NTSC/VHS signal emulation (MIT/ISC/Apache-2.0)
- [librashader](https://github.com/SnowflakePowered/librashader) by SnowflakePowered — the RetroArch-compatible shader runtime (MPL-2.0)
- [libretro/slang-shaders](https://github.com/libretro/slang-shaders) and the RetroArch community — the CRT shaders themselves: crt-royale by TroggleMonkey, crt-easymode and crt-aperture by EasyMode, crt-hyllian by Hyllian, crtsim, crtglow (various licenses, largely GPL)
