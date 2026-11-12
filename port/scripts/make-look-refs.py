#!/usr/bin/env python3
"""Render the Mac references for the look-parity check (port/spike/ref-mac/looks/).

For every bundled preset the Windows version can show completely (CRT on; no
Glitch, Digital video, crop or animation), run the Mac's crt-smoke with the
look's settings: its NTSC settings, Downscale (width, method; height by the
Mac app's aspect rule) and shader parameters on top of the shader's starting
values (the preset's own, the Mac app's tweaks, and crt-smoke's self-test
undone). Run from the repo root on the Mac after `swift build -c release
--product crt-smoke`.
"""
import json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SMOKE = os.path.join(ROOT, ".build/release/crt-smoke")
LIBRA = os.path.join(ROOT, "Vendor/librashader/librashader.dylib")
NTSC = os.path.join(ROOT, "Vendor/ntscrs-capi/ntscrs_capi.dylib")
SOURCE = os.path.join(ROOT, "TestAssets/testpattern.png")  # 640 x 480
OUT = os.path.join(ROOT, "port/spike/ref-mac/looks")
SHADERS = {"aperture": "crt-aperture", "easymode": "crt-easymode", "glow_gauss": "crtglow_gauss",
           "glow_lanczos": "crtglow_lanczos", "hyllian": "crt-hyllian", "royale": "crt-royale", "sim": "crtsim"}
APP_DEFAULTS = {"glow_gauss": {"BOOST": 1.1, "GLOW_ROLLOFF": 2.4, "BLOOM_STRENGTH": 0.1},
                "glow_lanczos": {"BOOST": 1.1, "GLOW_ROLLOFF": 2.4, "BLOOM_STRENGTH": 0.1}}
GLITCH_HEALTHY = {"signal_strength": 1, "vertical_hold": 0, "horizontal_hold": 0, "brightness": 0, "ghost_level": 0,
                  "hum": 0, "head_switch": 0, "timebase_jitter": 0, "crinkle": 0, "head_clog": 0, "tracking": 0,
                  "search_speed": 1, "dropouts": 0}


def complete_on_windows(look):
    g = look.get("glitch", {})
    if g.get("enabled", True) and any(abs(g.get("values", {}).get(k, v) - v) > 1e-9 for k, v in GLITCH_HEALTHY.items()):
        return False
    if look.get("digital", {}).get("enabled") or "crop" in look:
        return False
    if len(look.get("timeline", {}).get("keys", [])) > 1:
        return False
    return look.get("shader", {}).get("enabled", True)


def main():
    os.makedirs(OUT, exist_ok=True)
    made = []
    for name in sorted(os.listdir(os.path.join(ROOT, "presets"))):
        if not name.endswith(".json"):
            continue
        look = json.load(open(os.path.join(ROOT, "presets", name)))
        if not complete_on_windows(look):
            continue
        shader_id = look["shader"].get("preset", "glow_gauss")
        preset = os.path.join(ROOT, "Vendor/slang-shaders/crt", SHADERS[shader_id] + ".slangp")
        listing = subprocess.run([SMOKE, SOURCE, preset, "/dev/null", LIBRA, "64", "48"], capture_output=True, text=True).stdout
        initial = {m.group(1): float(m.group(2)) for m in re.finditer(r"^  - (\S+) \[.*default ([-0-9.e]+)\]", listing, re.M)}
        params = dict(initial)
        params.update(APP_DEFAULTS.get(shader_id, {}))
        params.update(look["shader"].get("params", {}))
        ds = look.get("downscale", {})
        width = ds.get("width", 320)
        height = max(16, 2 * round(width / (640 / 480) / 2))
        args = [SMOKE, SOURCE, preset, os.path.join(OUT, name.replace(".json", ".png")), LIBRA, "1280", "960",
                str(width), str(height), ds.get("method", "nearest")]
        if look.get("ntsc", {}).get("enabled", True):
            f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(look["ntsc"]["settings"], f)
            f.close()
            args += ["--ntsc", f.name, "--ntsc-dylib", NTSC]
        for k, v in params.items():
            args += ["--set", f"{k}={v}"]
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"{name}: crt-smoke failed\n{r.stderr}")
        made.append(name)
    print(f"{len(made)} references in {OUT}:", ", ".join(m[:-5] for m in made))


main()
