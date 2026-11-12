//! media-probe <clip> <out-dir> [frame ...]: print the clip's info, then
//! decode the frames in the order given (straight runs continue the decode,
//! anything else seeks) and save each as <out-dir>/<n>.png with timings.
use anyhow::{Context, Result};
use std::time::Instant;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let clip = args.first().context("usage: media-probe <clip> <out-dir> [frame ...]")?;
    let out = std::path::PathBuf::from(args.get(1).context("out dir")?);
    std::fs::create_dir_all(&out)?;
    let mut reader = ntscrt_media::VideoReader::open(clip.as_ref())?;
    println!("{:?}", reader.info());
    for n in &args[2..] {
        let n: usize = n.parse()?;
        let t = Instant::now();
        let f = reader.frame(n)?;
        println!("frame {n} -> {} ({} x {}) in {} ms", f.index, f.width, f.height, t.elapsed().as_millis());
        image::RgbaImage::from_raw(f.width, f.height, f.rgba).context("image")?.save(out.join(format!("{n}.png")))?;
    }
    Ok(())
}
