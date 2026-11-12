//! compare <a.png> <b.png> [diff.png]: RGB difference statistics (alpha
//! reported separately), and optionally a 4x-amplified difference image.
use anyhow::{bail, Result};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 { bail!("usage: compare <a.png> <b.png> [diff.png]"); }
    let a = image::open(&args[0])?.to_rgba8();
    let b = image::open(&args[1])?.to_rgba8();
    if a.dimensions() != b.dimensions() { bail!("sizes differ: {:?} vs {:?}", a.dimensions(), b.dimensions()); }
    let (mut sum, mut max, mut over2, mut sq, mut amin, mut bmin) = (0u64, 0u8, 0u64, 0f64, 255u8, 255u8);
    let mut diff = image::RgbaImage::new(a.width(), a.height());
    // COMPARE_BORDER=n: leave out n pixels along every edge.
    let border: u32 = std::env::var("COMPARE_BORDER").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let (w, h) = a.dimensions();
    let mut n_px = 0u64;
    for (((x, y, pa), pb), pd) in a.enumerate_pixels().zip(b.pixels()).zip(diff.pixels_mut()) {
        if x < border || y < border || x + border >= w || y + border >= h { continue; }
        n_px += 1;
        amin = amin.min(pa[3]); bmin = bmin.min(pb[3]);
        let mut worst = 0u8;
        for c in 0..3 {
            let d = pa[c].abs_diff(pb[c]);
            sum += d as u64; sq += (d as f64).powi(2); max = max.max(d); worst = worst.max(d);
            pd[c] = d.saturating_mul(4);
        }
        pd[3] = 255;
        if worst > 2 { over2 += 1; }
    }
    let n = n_px as f64;
    let mse = sq / (n * 3.0);
    let psnr = if mse == 0.0 { f64::INFINITY } else { 10.0 * (255.0f64 * 255.0 / mse).log10() };
    println!("mean {:.3}  max {}  >2: {:.2}%  psnr {:.1} dB  alpha-min {}/{}",
             sum as f64 / (n * 3.0), max, 100.0 * over2 as f64 / n, psnr, amin, bmin);
    if let Some(p) = args.get(2) { diff.save(p)?; }
    // COMPARE_MAX_MEAN=x: fail (exit 1) when the mean difference is above x.
    if let Some(limit) = std::env::var("COMPARE_MAX_MEAN").ok().and_then(|v| v.parse::<f64>().ok()) {
        if sum as f64 / (n * 3.0) > limit { bail!("mean difference above {limit}"); }
    }
    Ok(())
}
