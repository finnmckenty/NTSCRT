#!/usr/bin/env python3
"""Every control's visible strength, against a saved baseline.

For each control of the NTSC, Glitch, VCR and Digital video stages (from
`NTSCRT describe`), render the app's default look with the control at its
minimum, middle and maximum (a toggle off and on; a choice at each option)
and measure how far the picture moves from the default look: the largest
mean absolute difference in RGB, 0-255. A control that only acts when
another is on (a group's settings, Ghost delay, Digital video's controls)
is measured with that on, in the reference render too. Some controls are measured in several contexts too (another
Downscale, a 4K source, the VCR off), because the regressions this catches
came from one panel weakening another's controls: Composite noise faded
with a Smooth downscale and a bigger source (0.27.0), Wear did almost
nothing at 100%, Flutter did nothing visible.

    scripts/check-control-strength.py            # compare with the baseline
    scripts/check-control-strength.py --update   # accept the current strengths

It fails when a control that had an effect now has none, or when its
strength moved by more than the tolerance. After a deliberate change, run
with --update and review the baseline's diff: it shows every control whose
strength the change moved. Needs the release CLI (it builds it: swift build
-c release) and sips; renders run four at a time (~2-3 min).
"""
import argparse, concurrent.futures as cf, json, os, struct, subprocess, sys, tempfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, 'scripts', 'control-strength-baseline.json')
APP = os.path.join(ROOT, '.build', 'release', 'crt-app')
STAGES = ['ntsc', 'glitch', 'vcr', 'digital']
# Contexts: extra CLI flags and the source size. Beyond the default, only the
# stages whose controls other panels could weaken are measured.
CONTEXTS = {
    'default':    {'flags': [], 'source': (1440, 1080), 'stages': STAGES},
    'chunky-320': {'flags': ['--downscale', '320', '--downscale-method', 'chunky'],
                   'source': (1440, 1080), 'stages': ['ntsc', 'glitch']},
    'smooth-320': {'flags': ['--downscale', '320', '--downscale-method', 'smooth'],
                   'source': (1440, 1080), 'stages': ['ntsc', 'glitch']},
    '4k-source':  {'flags': [], 'source': (2880, 2160), 'stages': ['ntsc', 'glitch']},
    'vcr-off':    {'flags': ['--vcr', 'off'], 'source': (1440, 1080), 'stages': ['ntsc', 'glitch']},
}
DEAD = 0.3          # below this a control has no visible effect
# A slider's curve: the share of its full effect at a quarter, half and three
# quarters of its travel. Less than this at half or three quarters is a flat
# spot (Wear in 0.27.0: 5% at half, 24% at 80%, most of it in the last tenth).
FLAT_HALF, FLAT_THREE_QUARTERS = 0.10, 0.30
# Effects that need motion: on the still test picture Data loss patches from
# an identical picture and Datamosh has nothing to drag, so their curves
# can't be judged here.
# Sticky shed grabs in episodes at places along the tape: one instant either
# catches a patch under the guides or doesn't, at any setting.
NEEDS_MOTION = {'digital.data_loss', 'digital.datamosh', 'vcr.tape_sticky'}
TOLERANCE = 1.6     # strength may move by this factor either way
TIME = '2.0'        # the VCR and the TV change over time

def png_rgb(path):
    """8-bit RGB(A), non-interlaced PNG → bytes of RGB (no dependencies)."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    pos, idat, w = 8, b'', 0
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and ctype in (2, 6) and inter == 0, (path, depth, ctype)
            bpp = 3 if ctype == 2 else 4
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    raw, stride = zlib.decompress(idat), w * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        out += line if bpp == 3 else bytes(v for i, v in enumerate(line) if i % 4 != 3)
    return bytes(out)

def mad(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / max(1, min(len(a), len(b)))

# Controls that only act when another one is on: measured with it on (in
# the reference render too, so only the control itself is measured).
REQUIRES = {
    'glitch.ghost_delay': {'glitch': {'values': {'ghost_level': 0.5}}},
    'ntsc.snow_anisotropy': {'ntsc': {'settings': {'snow_intensity': 0.5}}},
    'ntsc.tracking_noise_snow_anisotropy': {'ntsc': {'settings': {'tracking_noise_snow_intensity': 0.5}}},
    'digital.low_light_noise': {'digital': {'values': {'sensor_noise': 0.5}}},
    'digital.datamosh': {'digital': {'values': {'keyframe_interval': 2}}},
    'digital.loss_pattern': {'digital': {'values': {'data_loss': 1}}},
    'digital.concealment': {'digital': {'values': {'data_loss': 1}}},
    'digital.chroma_upsampling': {'digital': {'values': {'chroma': '4:1:1 (DV)'}}},
    # (A 10 s interval: at the 2 s the renders are taken, an interval of 2
    # would have just put the picture right.)
    'digital.mosh_motion': {'digital': {'values': {'keyframe_interval': 10}}},
    'digital.mosh_speed': {'digital': {'values': {'keyframe_interval': 10, 'mosh_motion': 'Pan'}}},
    # (An interval of 2: the frame at 2 s is then a keyframe, which is what
    # the buffer's size decides the budget of.)
    'digital.rate_buffer': {'digital': {'values': {'bitrate_limit': 0.6, 'keyframe_interval': 2}}},
}
# (Still dead in some contexts, as they should be: Closed captions show only
# when the picture rolls; Scale with video size does nothing at exactly 480
# lines; AFC speed does nothing without the VCR's timing errors; Loss pattern
# on the still test picture only moves a patch of the same picture.)

def controls(stage, describe):
    """(id, values to try, settings it needs) for each of a stage's controls.
    Each value is compared with the look at that control's default."""
    out = []
    def lift(group):
        if stage == 'digital': return {'digital': {'values': {}}}   # Digital video on
        if group: return {'ntsc': {'settings': {group: True}}} if stage == 'ntsc' else {stage: {'values': {group: 1}}}
        return {}
    def walk(cs, group=None):
        for c in cs:
            k, cid = c.get('kind'), c.get('id')
            if k == 'group':
                out.append((cid, [False, True], lift(None)))
                walk(c.get('children', []), cid)
            elif k == 'section':
                walk(c.get('children', []), group)
            elif k in ('slider', 'integer'):
                lo, hi = c['min'], c['max']
                mid = (lo + hi) / 2 if k == 'slider' else round((lo + hi) / 2)
                out.append((cid, [lo, mid, hi], lift(group)))     # mid: periodic and two-sided knobs
            elif k == 'toggle':
                out.append((cid, [False, True], lift(group)))
            elif k == 'choice':
                out.append((cid, list(c['options']), lift(group)))
            elif k == 'seed':
                out.append((cid, [2, 3], lift(group)))
    walk(describe['stages'][stage].get('controls', []))
    return [(cid, vals, merge(pre, REQUIRES.get(f'{stage}.{cid}', {}))) for cid, vals, pre in out]

def merge(a, b):
    out = json.loads(json.dumps(a))
    for k, v in b.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out

def setting(stage, key, value):
    return {'ntsc': {'settings': {key: value}}} if stage == 'ntsc' else {stage: {'values': {key: value}}}

def render(source, flags, extra, out):
    cmd = [APP, 'render', source, '-o', out, '--time', TIME, '--long-edge', '320'] + flags
    if extra: cmd += ['--settings', json.dumps(extra)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if '"ok":true' not in r.stdout:
        raise RuntimeError(f'render failed: {" ".join(cmd)}\n{r.stdout[:400]}{r.stderr[:400]}')
    return png_rgb(out)

def measure(tmp, sources):
    describe = json.loads(subprocess.run([APP, 'describe'], capture_output=True, text=True).stdout)
    plan, todo = [], {}          # plan: (ctx, key, reference id, [render ids]); todo: id -> (ctx, settings)
    def job(ctx, extra):
        rid = f'{ctx}|{json.dumps(extra, sort_keys=True)}'
        todo[rid] = (ctx, extra)
        return rid
    for ctx, spec in CONTEXTS.items():
        for stage in spec['stages']:
            for cid, values, pre in controls(stage, describe):
                ref = job(ctx, pre)
                plan.append((ctx, f'{stage}.{cid}', ref,
                             [job(ctx, merge(pre, setting(stage, cid, v))) for v in values]))
    # Curves, in the default look: sliders that start at their minimum.
    curves = []
    for stage in STAGES:
        sliders = {}
        def walk(cs):
            for c in cs:
                if c.get('kind') == 'slider' and c.get('default') == c['min']: sliders[c['id']] = c
                walk(c.get('children', []))
        walk(describe['stages'][stage].get('controls', []))
        for cid, values, pre in controls(stage, describe):
            if cid not in sliders: continue
            lo, hi = sliders[cid]['min'], sliders[cid]['max']
            steps = [job('default', merge(pre, setting(stage, cid, lo + (hi - lo) * f)))
                     for f in (0, 0.25, 0.5, 0.75, 1)]
            curves.append((f'{stage}.{cid}', steps))
    pics, ids = {}, list(todo)
    def run(i_rid):
        i, rid = i_rid
        ctx, extra = todo[rid]
        spec = CONTEXTS[ctx]
        return rid, render(sources[spec['source']], spec['flags'], extra, os.path.join(tmp, f'{i}.png'))
    with cf.ThreadPoolExecutor(4) as pool:
        for n, (rid, px) in enumerate(pool.map(run, enumerate(ids)), 1):
            pics[rid] = px
            if n % 100 == 0: print(f'  {n}/{len(ids)} renders', file=sys.stderr)
    result = {}
    for ctx, key, ref, renders in plan:
        result.setdefault(ctx, {})[key] = round(max(mad(pics[ref], pics[r]) for r in renders), 2)
    for key, steps in curves:
        full = mad(pics[steps[0]], pics[steps[4]])
        if full < DEAD: continue
        result.setdefault('curve', {})[key] = [round(mad(pics[steps[0]], pics[r]) / full, 2) for r in steps[1:4]]
    return result

def flat_spots(now):
    out = []
    for key, (q1, half, q3) in sorted(now.get('curve', {}).items()):
        if key in NEEDS_MOTION: continue
        if half < FLAT_HALF or q3 < FLAT_THREE_QUARTERS:
            out.append(f'curve: {key} has a flat spot: {round(q1 * 100)}% / {round(half * 100)}% / '
                       f'{round(q3 * 100)}% of its effect at 25 / 50 / 75%')
    return out

def compare(now, base):
    problems, notes = flat_spots(now), []
    for ctx in sorted((set(now) | set(base)) - {'curve'}):
        a, b = now.get(ctx, {}), base.get(ctx, {})
        for key in sorted(set(a) | set(b)):
            if key not in b: notes.append(f'{ctx}: {key} is new ({a[key]})'); continue
            if key not in a: notes.append(f'{ctx}: {key} is gone (was {b[key]})'); continue
            s, was = a[key], b[key]
            if was >= DEAD and s < DEAD:
                problems.append(f'{ctx}: {key} now has no visible effect (was {was})')
            elif was >= 1 and not (was / TOLERANCE <= s <= was * TOLERANCE):
                word = 'weaker' if s < was else 'stronger'
                problems.append(f'{ctx}: {key} is {was / s if s < was else s / was:.1f}x {word} ({was} -> {s})')
            elif was < 1 and abs(s - was) > 0.6:
                problems.append(f'{ctx}: {key} moved {was} -> {s}')
    return problems, notes

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--update', action='store_true', help='save the current strengths as the baseline')
    ap.add_argument('--app', help='check this NTSCRT binary instead of building the release CLI')
    args = ap.parse_args()
    global APP
    if args.app:
        APP = args.app
    else:
        subprocess.run(['swift', 'build', '-c', 'release', '--product', 'crt-app'], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        sources = {}
        for w, h in {c['source'] for c in CONTEXTS.values()}:
            p = os.path.join(tmp, f'source-{w}x{h}.png')
            subprocess.run(['sips', '-z', str(h), str(w), os.path.join(ROOT, 'TestAssets', 'testpattern.png'),
                            '--out', p], check=True, capture_output=True)
            sources[(w, h)] = p
        now = measure(tmp, sources)
    dead = [f'{c}: {k}' for c, v in now.items() if c != 'curve' for k, s in v.items() if s < DEAD]
    if args.update:
        json.dump(now, open(BASELINE, 'w'), indent=1, sort_keys=True)
        print(f'baseline saved: {sum(len(v) for c, v in now.items() if c != "curve")} strengths, '
              f'{len(now.get("curve", {}))} curves; {len(dead)} with no visible effect in their context')
        for f in flat_spots(now): print('FLAT:', f)
        return 0
    if not os.path.exists(BASELINE):
        print('no baseline yet: run with --update'); return 1
    problems, notes = compare(now, json.load(open(BASELINE)))
    for n in notes: print('note:', n)
    for p in problems: print('FAIL:', p)
    print(f'{sum(len(v) for c, v in now.items() if c != "curve")} strengths and '
          f'{len(now.get("curve", {}))} curves checked, {len(problems)} problems')
    return 1 if problems else 0

if __name__ == '__main__':
    sys.exit(main())
