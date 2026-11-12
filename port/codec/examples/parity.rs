//! Parity with the Mac: runs every case of `ref/cases.json` through the port
//! and compares with the Mac reference CLI's outputs (`ref/build.sh`, then
//! `ntscrt-codec-ref run ref/cases.json <dir>`).
//!
//!   cargo run --release -p ntscrt-codec --example parity -- ref/cases.json <dir> [case…]
//!
//! Prints, per case, the mean and largest difference (0–255, over R, G and
//! B of every output pixel) and how many outputs are identical.
//! Inputs are generated exactly as `ref/main.swift` does (integer math).

#![allow(clippy::type_complexity)]

use std::collections::BTreeMap;

use ntscrt_codec::{DigitalFormat, DigitalHistory, DigitalParam, DigitalSettings, DigitalVideoRenderer};
use serde_json::Value;

// MARK: - inputs (keep in step with ref/main.swift)

fn pattern_pixel(name: &str, x: i64, y: i64, n: i64, w: i64, h: i64, cut: Option<i64>) -> (i64, i64, i64) {
    let scene = if cut.is_some_and(|c| n >= c) { 1 } else { 0 };
    let tex = |a: i64, b: i64| ((a * 7919 + b * 104_729) ^ (a * b)) % 31;
    let (mut r, mut g, mut b);
    match name {
        "square" => {
            if scene == 0 {
                r = (x * 255) / w;
                g = ((x / 8 + y / 8) % 2) * 120 + 40;
                b = (y * 255) / h;
            } else {
                r = 200 - (y * 150) / h;
                g = ((x / 16) % 2) * 60 + 90;
                b = 60 + (x * 120) / w;
            }
            let (sx, sy) = (20 + 4 * n, 60 + 2 * n);
            if x >= sx && x < sx + 40 && y >= sy && y < sy + 40 {
                r = 250;
                g = 240;
                b = 30;
            }
        }
        "clip" => {
            let px = x + 3 * n;
            if scene == 0 {
                r = 40 + (px * 160) / (w + 1) % 160 + tex(px / 3, y / 3) % 24;
                g = 60 + ((px + y) % 64) * 2;
                b = 200 - (y * 150) / h + tex(y / 2, px / 5) % 20;
            } else {
                r = 120 + tex(px / 2, y / 2) % 31 * 3;
                g = 30 + (y * 180) / h;
                b = 90 + ((px / 6) % 2) * 50;
            }
            let (cx, cy, rad) = (w / 3 + 5 * n, h / 2 + (n % 7) * 3, h / 5);
            if (x - cx) * (x - cx) + (y - cy) * (y - cy) < rad * rad {
                r = 230;
                g = 196;
                b = 170;
            }
            if x < w / 3 && y > (2 * h) / 3 {
                r = r * 3 / 10;
                g = g * 3 / 10;
                b = b * 3 / 10;
            }
        }
        "stripes" => {
            let v = if (x * 3) % 7 < 3 { 228 } else { 28 };
            r = v;
            g = v;
            b = v;
            if (y / 16) % 2 == 1 {
                g = 255 - v;
            }
        }
        "night" => {
            r = 18 + tex(x, y + n) % 6;
            g = r;
            b = r + 4;
            if (x - w / 2).abs() < w / 5 && (y - h / 2).abs() < h / 3 {
                r = 236;
                g = 214;
                b = 190;
            }
        }
        _ => panic!("pattern {name}"),
    }
    (r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255))
}

/// Frame n as RGBA. A name ending "+1" is that pattern with one pixel in
/// 200 moved by one code value (see ref/main.swift).
fn pattern_rgba(name: &str, n: i64, w: usize, h: usize, cut: Option<i64>) -> Vec<u8> {
    let base = name.strip_suffix("+1");
    let mut px = vec![255u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let (r, g, b) = pattern_pixel(base.unwrap_or(name), x as i64, y as i64, n, w as i64, h as i64, cut);
            let i = (y * w + x) * 4;
            px[i] = r as u8;
            px[i + 1] = g as u8;
            px[i + 2] = b as u8;
        }
    }
    if base.is_some() {
        for y in 0..h {
            for x in 0..w {
                if (x as i64 * 7919 + y as i64 * 104_729 + n * 31) % 200 == 0 {
                    let i = (y * w + x) * 4 + 1;
                    px[i] = if px[i] == 255 { 254 } else { px[i] + 1 };
                }
            }
        }
    }
    px
}

// MARK: - cases

struct Case {
    name: String,
    kind: String,
    src: (usize, usize),
    cap: (usize, usize),
    fps: f64,
    pattern: String,
    cut: Option<i64>,
    settings: DigitalSettings,
    history: Option<String>,
    calls: Vec<i64>,
    fresh: bool,
    still: bool,
    /// For a perturbed case: the unperturbed one, to compare the Mac with
    /// itself.
    baseline: Option<String>,
}

fn pair(v: &Value) -> (usize, usize) {
    (v[0].as_u64().unwrap() as usize, v[1].as_u64().unwrap() as usize)
}

fn parse_cases(path: &str) -> Vec<Case> {
    let root: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    root["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            let src = pair(&c["src"]);
            let cap = if c["cap"].is_null() { src } else { pair(&c["cap"]) };
            let mut values: BTreeMap<String, f64> = BTreeMap::new();
            if c["base"].as_str() == Some("starting") {
                values = DigitalParam::starting_values();
            }
            if let Some(f) = c["format"].as_str() {
                values.extend(DigitalFormat::by_id(f).unwrap().values_map());
            }
            if let Some(o) = c["settings"].as_object() {
                for (k, v) in o {
                    values.insert(k.clone(), v.as_f64().unwrap());
                }
            }
            let mut calls: Vec<i64> = vec![];
            if let Some(p) = c["play"].as_i64() {
                calls.extend(0..p);
            }
            if let Some(a) = c["calls"].as_array() {
                calls.extend(a.iter().map(|v| v.as_i64().unwrap()));
            }
            Case {
                name: c["name"].as_str().unwrap().to_string(),
                kind: c["kind"].as_str().unwrap_or("process").to_string(),
                src,
                cap,
                fps: c["fps"].as_f64().unwrap_or(30.0),
                pattern: c["pattern"].as_str().unwrap_or("square").to_string(),
                cut: c["cut"].as_i64(),
                settings: DigitalSettings::new(values),
                history: c["history"].as_str().map(str::to_string),
                calls,
                fresh: c["fresh"].as_bool().unwrap_or(false),
                still: c["still"].as_bool().unwrap_or(false),
                baseline: c["baseline"].as_str().map(str::to_string),
            }
        })
        .collect()
}

fn history(name: Option<&str>, base: &DigitalSettings) -> Option<DigitalHistory> {
    let b = base.clone();
    match name {
        None => None,
        Some("ramp") => Some(DigitalHistory::new(7, move |n| {
            let mut s = b.clone();
            s.set("quality", 0.1 + 0.02 * n as f64);
            s.set("data_loss", if n > 15 { 0.5 } else { 0.0 });
            s
        })),
        Some("fade") => Some(DigitalHistory::new(11, move |n| {
            let mut s = b.clone();
            s.set("sensor_noise", 0.05 * (n % 9) as f64);
            s.set("saturation", 0.6 + 0.05 * n as f64);
            s.set("sharpening", if n > 10 { 0.7 } else { 0.2 });
            s
        })),
        Some(other) => panic!("history {other}"),
    }
}

/// Every output of a case, one per call.
fn run(c: &Case) -> Vec<Vec<u8>> {
    let (w, h) = c.src;
    match c.kind.as_str() {
        "scale" => c
            .calls
            .iter()
            .map(|&n| DigitalVideoRenderer::scale(&pattern_rgba(&c.pattern, n, w, h, c.cut), w, h, w * 4, c.cap, &c.settings))
            .collect(),
        "process" => {
            let hist = history(c.history.as_deref(), &c.settings);
            let mut renderer = DigitalVideoRenderer::new();
            let mut visitor = |i: i64, body: &mut dyn FnMut(&[u8], usize, usize, usize)| {
                let f = pattern_rgba(&c.pattern, i, w, h, c.cut);
                body(&f, w, h, w * 4);
                true
            };
            let mut outs = vec![];
            for &n in &c.calls {
                if c.fresh {
                    renderer = DigitalVideoRenderer::new();
                }
                let mut px = pattern_rgba(&c.pattern, if c.still { 0 } else { n }, w, h, c.cut);
                let earlier: Option<&mut ntscrt_codec::FrameVisitor> = if c.still { None } else { Some(&mut visitor) };
                renderer.process(n, &mut px, w, h, w * 4, c.cap, c.fps, &c.settings, hist.as_ref(), earlier);
                outs.push(px);
            }
            outs
        }
        k => panic!("kind {k}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: parity <cases.json> <mac-output-dir> [case…]");
        std::process::exit(2);
    }
    let only: Vec<&String> = args[3..].iter().collect();
    println!("{:<40} {:>7} {:>9} {:>4} {:>9} {:>9}", "case", "outputs", "mean", "max", "differ", "identical");
    let per_frame = std::env::var("PARITY_FRAMES").is_ok();
    let mut worst_exact = 0u8;
    for c in parse_cases(&args[1]) {
        if !only.is_empty() && !only.iter().any(|o| **o == c.name) {
            continue;
        }
        let file = format!("{}/{}.rgba", args[2], c.name.replace('/', "__"));
        let mac = std::fs::read(&file).unwrap_or_else(|e| panic!("{file}: {e}"));
        let ours = run(&c);
        let each = mac.len() / ours.len();
        let (mut sum, mut count, mut max, mut differ, mut same) = (0u64, 0u64, 0u8, 0u64, 0);
        let mut frames = vec![];
        for (k, o) in ours.iter().enumerate() {
            assert_eq!(o.len(), each, "{}: output size", c.name);
            let m = &mac[k * each..(k + 1) * each];
            if o == m {
                same += 1;
            }
            let mut fsum = 0u64;
            for i in (0..each).step_by(4) {
                for ch in 0..3 {
                    let d = o[i + ch].abs_diff(m[i + ch]);
                    fsum += d as u64;
                    max = max.max(d);
                    differ += (d != 0) as u64;
                    count += 1;
                }
            }
            sum += fsum;
            frames.push(fsum as f64 / (each / 4 * 3) as f64);
        }
        if c.name.starts_with("exact/") {
            worst_exact = worst_exact.max(max);
        }
        println!(
            "{:<40} {:>7} {:>9.5} {:>4} {:>8.3}% {:>5}/{:<3}",
            c.name,
            ours.len(),
            sum as f64 / count as f64,
            max,
            100.0 * differ as f64 / count as f64,
            same,
            ours.len(),
        );
        if let Some(b) = &c.baseline {
            // The Mac against itself: how far differences as small as the
            // resampler's carry through the codec.
            let base = std::fs::read(format!("{}/{}.rgba", args[2], b.replace('/', "__"))).unwrap();
            let (mut s2, mut m2) = (0u64, 0u8);
            for i in (0..mac.len()).step_by(4) {
                for ch in 0..3 {
                    let d = mac[i + ch].abs_diff(base[i + ch]);
                    s2 += d as u64;
                    m2 = m2.max(d);
                }
            }
            println!("    Mac vs Mac unperturbed: mean {:.5}, max {m2}", s2 as f64 / (mac.len() / 4 * 3) as f64);
        }
        if per_frame {
            let line: Vec<String> = frames.iter().map(|f| format!("{f:.2}")).collect();
            println!("    per output: {}", line.join(" "));
        }
    }
    println!("largest difference in the exact (no-resampling) cases: {worst_exact}");
}
