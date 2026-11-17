#!/usr/bin/env python3
"""Check NTSCRT's command line and MCP server end to end, as an AI app would
use them: help, describe, looks, renders (PNG at times and zoomed, a still's
MP4 and GIF with keyframes and a loop, a clip), the errors, a saved look, and
a whole MCP session over pipes (initialize, tools/list, the guide, a preview
with images, a render job and its status, save_look).

    python port/scripts/cli-check.py <ntscrt(.exe)> <picture.png> <out dir>

Prints one line per check and exits 1 if any failed.

To drive a VM from the host, CLI_CHECK_WRAP is a JSON list put before every
command (e.g. ["prlctl", "exec", "Windows 11", "--current-user"]), and
CLI_CHECK_PATHS="<guest prefix>|<host prefix>" maps the guest paths it's
given to where the host sees them, for checking the files.
"""
import json, ntpath, os, subprocess, sys, time
# The check names use arrows; Windows consoles and CI default to cp1252.
sys.stdout.reconfigure(encoding="utf-8")

WRAP = json.loads(os.environ.get("CLI_CHECK_WRAP", "[]"))
GUEST, HOST = (os.environ.get("CLI_CHECK_PATHS", "|").split("|") + [""])[:2]
exe, picture, out = sys.argv[1], sys.argv[2], sys.argv[3]
if not WRAP:
    picture, out = os.path.abspath(picture), os.path.abspath(out)
pathmod = ntpath if WRAP else os.path
failures = []


def local(p):
    """A path the program was given (or reported), as this script sees it."""
    if GUEST and p.lower().startswith(GUEST.lower()):
        return HOST + p[len(GUEST):].replace("\\", "/")
    return p


def join(*parts):
    return pathmod.join(*parts)


os.makedirs(local(out), exist_ok=True)


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{' — ' + str(detail) if detail and not ok else ''}", flush=True)
    if not ok:
        failures.append(name)


def run(*args, timeout=900):
    p = subprocess.run([*WRAP, exe, *args], capture_output=True, timeout=timeout)
    stdout = p.stdout.decode("utf-8", "replace")
    stderr = p.stderr.decode("utf-8", "replace")
    lines = [l for l in stdout.splitlines() if l.strip()]
    result = None
    try:
        result = json.loads(stdout) if stdout.strip().startswith("{\n") else json.loads(lines[-1]) if lines else None
    except ValueError:
        pass
    return p.returncode, stdout, stderr, result


# help, describe, looks
code, stdout, _, _ = run("help")
check("help", code == 0 and "render <image|video>" in stdout, stdout[:200])

code, stdout, _, d = run("describe")
stages = set((d or {}).get("stages", {}))
check("describe: every stage", code == 0 and stages == {"crop", "downscale", "digital", "ntsc", "glitch", "vcr", "crt", "output"}, stages)
check("describe: stdout is only the JSON", stdout.lstrip().startswith("{"), stdout[:80])
if d:
    vcr = d["stages"]["vcr"]
    check("describe: vcr controls and pickers", len(vcr["controls"]) > 15 and len(vcr["tapes"]) == 8 and len(vcr["decks"]) == 5)
    ntsc_ids = json.dumps(d["stages"]["ntsc"]["controls"])
    check("describe: ntsc hides the retired VHS settings", '"head_switching"' not in ntsc_ids and '"luma_smear"' in ntsc_ids)
    crt = d["stages"]["crt"]
    check("describe: crt glow_gauss params", crt["presets"][0]["id"] == "glow_gauss" and len(crt["presets"][0]["params"]) > 3)
code, _, _, d = run("describe", "crt", "--crt", "royale")
check("describe crt --crt royale", code == 0 and d and d["stages"]["crt"]["presets"][0]["id"] == "royale" and list(d["stages"]) == ["crt"])
code, _, _, d = run("describe", "nonsense")
check("describe: a bad stage is exit 2", code == 2 and d and d.get("ok") is False, (code, d))

code, _, _, d = run("looks")
looks = (d or {}).get("looks", [])
check("looks", code == 0 and len(looks) >= 20 and all("stages" in l for l in looks), len(looks))
check("looks: descriptions", sum(1 for l in looks if l.get("description")) >= 20)
check("looks: tapes, decks, formats, crt presets", d and len(d["tapes"]) == 8 and len(d["decks"]) == 5 and len(d["digitalFormats"]) >= 5 and len(d["crtPresets"]) == 7)

# errors
code, _, _, d = run("render", picture)
check("render without -o is exit 2", code == 2 and d and d["ok"] is False and "-o" in d["error"], d)
code, _, _, d = run("render", picture, "-o", join(out, "x.mov"))
check("ProRes refused", code == 2 and d and "ProRes" in d["error"], d)
code, _, _, d = run("render", picture, "-o", join(out, "x.png"), "--vcr-set", "signal_strength=0.2")
check("a glitch knob in vcr is refused", code == 2 and d and "belongs to \"glitch\"" in d["error"], d)
code, _, _, d = run("render", picture, "-o", join(out, "x.png"), "--ntsc-set", "head_switching=true")
check("retired NTSC VHS refused", code == 2 and d and "retired" in d["error"], d)
code, _, _, d = run("render", picture, "-o", join(out, "x.png"), "--look", "No such look")
check("unknown look", code == 2 and d and "No built-in look" in d["error"], d)
code, _, _, d = run("render", picture, "--dry-run", "--glitch-set", "signal_strength=3")
check("out-of-range values clamp with a warning", code == 0 and d and any("outside" in w for w in d.get("warnings", [])), d)

# dry run and summary
code, _, _, d = run("render", picture, "-o", join(out, "plan.mp4"), "--dry-run", "--look", "90s VHS bootleg", "--duration", "2")
plan = (d or {}).get("plan", {})
check("dry run: plan", code == 0 and plan.get("route") == "still" and plan.get("frames") == 60 and plan.get("width") == 1920, plan)
look = (d or {}).get("look", {})
check("dry run: look summary", isinstance(look.get("vcr"), dict) and "lines" in look.get("downscale", "") and look.get("source", "").count("×") == 1, look)
check("dry run writes nothing", not os.path.exists(local(join(out, "plan.mp4"))))

# PNGs at times, zoomed
t0 = time.time()
code, _, stderr, d = run("render", picture, "-o", join(out, "frames.png"), "--tape", "Moldy", "--deck", "Dirty heads", "--time", "0.5,2", "--long-edge", "640")
outs = (d or {}).get("outputs", [])
check("png at two times", code == 0 and len(outs) == 2 and all(os.path.getsize(local(o["path"])) > 1000 for o in outs), d)
check("png names carry the time", [pathmod.basename(o["path"]) for o in outs] == ["frames 0.50s.png", "frames 2.00s.png"], outs)
check("png times", [o.get("time") for o in outs] == [0.5, 2], outs)
code, _, _, d = run("render", picture, "-o", join(out, "zoom.png"), "--downscale", "160", "--crt", "royale", "--zoom", "8", "--zoom-at", "0.3,0.4", "--long-edge", "640")
check("png zoomed", code == 0 and d and os.path.getsize(local(d["outputs"][0]["path"])) > 1000, d)
print(f"  ({time.time() - t0:.0f} s)")

# a still's video: keyframes, loop, MP4 and GIF
keys = {
    "look": "Clean VHS" if any(l["name"] == "Clean VHS" for l in looks) else looks[0]["name"],
    "timeline": {"duration": 1.5, "fps": 10, "loop": True},
    "keyframes": [{"time": 0}, {"time": 0.7, "easing": "ease-in", "glitch": {"values": {"vertical_hold": 0.6}}}],
}
settings_file = join(out, "keys.json")
json.dump(keys, open(local(settings_file), "w"))
code, _, stderr, d = run("render", picture, "-o", join(out, "keys.mp4"), "--settings", "@" + settings_file, "--long-edge", "480")
o = (d or {}).get("outputs", [{}])[0]
check("still → mp4 with keyframes and a loop", code == 0 and o.get("frames") == 15 and o.get("bytes", 0) > 1000, d)
check("keyframes in the summary (3 with the loop's closing key)", d and d["look"].get("keyframes") == 3, d and d["look"])
check("progress on stderr", '{"progress":' in stderr, stderr[-300:])
code, _, _, d = run("render", picture, "-o", join(out, "keys.gif"), "--settings", "@" + settings_file, "--gif-width", "240", "--gif-fps", "8")
check("still → gif", code == 0 and d and d["plan"]["route"] == "gif" and d["outputs"][0]["frames"] == 12, d)

# a clip: the MP4 just made, through another look
clip = join(out, "keys.mp4")
code, _, _, d = run("render", clip, "-o", join(out, "clip.mp4"), "--digital", "minidv", "--ntsc", "off", "--long-edge", "320")
check("clip → mp4", code == 0 and d and d["plan"]["route"] == "clip" and d["outputs"][0]["frames"] == 15 and d["look"]["digital"] != "off", d)
code, _, _, d = run("render", clip, "-o", join(out, "clip.png"), "--time", "1", "--vcr", "on")
check("clip → png at a time", code == 0 and d and d["outputs"][0]["time"] == 1, d)

# a saved look, loaded again
look_file = join(out, "looks", "saved look.json")
save_file = join(out, "save.json")
json.dump({"look": keys["look"], "vcr": {"tape": "Chewed"}, "description": "A chewed tape."}, open(local(save_file), "w"))
code, _, _, d = run("render", "--save-look", look_file, "--settings", "@" + save_file)
saved = json.load(open(local(look_file))) if os.path.exists(local(look_file)) else {}
check("save-look", code == 0 and saved.get("description") == "A chewed tape." and saved.get("glitch", {}).get("values", {}).get("vcr") == 1, d)
code, _, _, d = run("render", picture, "--dry-run", "--look", look_file)
check("a saved look loads", code == 0 and d and d["look"]["vcr"]["tape"] == "Chewed", d)

# the MCP server over pipes (CLI_CHECK_SKIP_MCP=1 when the wrapper can't stream stdin)
if os.environ.get("CLI_CHECK_SKIP_MCP"):
    print("ALL PASS" if not failures else f"{len(failures)} FAILED: {', '.join(failures)}")
    sys.exit(1 if failures else 0)
server = subprocess.Popen([*WRAP, exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
next_id = [0]


def rpc(method, params=None, timeout=600):
    next_id[0] += 1
    server.stdin.write((json.dumps({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params or {}}) + "\n").encode())
    server.stdin.flush()
    while True:
        line = server.stdout.readline()
        if not line:
            return None
        msg = json.loads(line)
        if msg.get("id") == next_id[0]:
            return msg


def tool(name, args, timeout=600):
    r = rpc("tools/call", {"name": name, "arguments": args}, timeout)
    return (r or {}).get("result", {})


r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cli-check", "version": "1"}})
res = (r or {}).get("result", {})
check("mcp initialize", res.get("protocolVersion") == "2025-06-18" and res.get("serverInfo", {}).get("name") == "ntscrt" and "ntscrt_guide" in res.get("instructions", ""), res)
server.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
server.stdin.flush()
r = rpc("tools/list")
names = [t["name"] for t in (r or {}).get("result", {}).get("tools", [])]
check("mcp tools/list", names == ["ntscrt_list_looks", "ntscrt_guide", "ntscrt_describe", "ntscrt_preview", "ntscrt_render", "ntscrt_render_status", "ntscrt_save_look"], names)
g = tool("ntscrt_guide", {"topics": ["resolution"]})
check("mcp guide topic", "LOW downscale width" in g["content"][0]["text"] and "## " in g["content"][0]["text"])
l = tool("ntscrt_list_looks", {})
check("mcp list_looks", json.loads(l["content"][0]["text"])["looks"])
dsc = tool("ntscrt_describe", {"stages": ["vcr"]})
check("mcp describe", list(json.loads(dsc["content"][0]["text"])["stages"]) == ["vcr"])
p = tool("ntscrt_preview", {"source": picture, "settings": {"vcr": {"tape": "Used"}}, "times": [0.5, 1.5], "long_edge": 320})
kinds = [c["type"] for c in p.get("content", [])]
check("mcp preview returns images", kinds == ["text", "text", "image", "text", "image"] and not p.get("isError"), p if p.get("isError") else kinds)
if "image" in kinds:
    img = next(c for c in p["content"] if c["type"] == "image")
    check("mcp preview is a JPEG", img["mimeType"] == "image/jpeg" and img["data"].startswith("/9j/"))
bad = tool("ntscrt_preview", {"source": "relative.png"})
check("mcp: relative paths refused", bad.get("isError") and "absolute" in bad["content"][0]["text"], bad)
gif = join(out, "mcp render.gif")
rr = tool("ntscrt_render", {"source": picture, "output": gif, "duration": 1, "gif_width": 200, "gif_fps": 6, "wait_seconds": 0})
st = rr.get("structuredContent", {})
check("mcp render starts a job", st.get("job_id") and st.get("state") in ("queued", "running") and st.get("plan", {}).get("route") == "gif", rr)
done = {}
for _ in range(20):
    s = tool("ntscrt_render_status", {"job_id": st.get("job_id", ""), "wait_seconds": 30})
    done = s.get("structuredContent", {})
    if done.get("state") in ("done", "failed"):
        break
check("mcp render_status: done", done.get("state") == "done" and done.get("outputs", [{}])[0].get("path") == gif and os.path.getsize(local(gif)) > 1000, done)
bad = tool("ntscrt_render", {"source": picture, "output": join(out, "x.mov")})
check("mcp render: ProRes refused before the job", bad.get("isError") and "ProRes" in bad["content"][0]["text"], bad)
sl = tool("ntscrt_save_look", {"settings": {"vcr": {"tape": "Moldy"}}, "path": join(out, "looks", "mcp look.json"), "description": "Moldy."})
check("mcp save_look", sl.get("structuredContent", {}).get("savedLook", "").endswith("mcp look.json") and os.path.exists(local(join(out, "looks", "mcp look.json"))), sl)
server.stdin.close()
try:
    server.wait(timeout=30)
    check("mcp exits when stdin closes", server.returncode == 0, server.returncode)
except subprocess.TimeoutExpired:
    server.kill()
    check("mcp exits when stdin closes", False, "still running")

print("ALL PASS" if not failures else f"{len(failures)} FAILED: {', '.join(failures)}")
sys.exit(1 if failures else 0)
