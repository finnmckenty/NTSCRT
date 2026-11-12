//! media-probe <clip> <out-dir> [frame ...]: print the clip's info, then
//! decode the frames in the order given (straight runs continue the decode,
//! anything else seeks) and save each as <out-dir>/<n>.png with timings.
//! media-probe --image <picture>: read it through Windows Imaging Component
//! and compare with the image crate's decode.
//! media-probe --encode <clip> <out.mp4> [frames]: decode the clip and write
//! it straight back out at its own size (H.264, high bitrate).
use anyhow::{Context, Result};
use std::time::Instant;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--image") {
        let path = std::path::Path::new(args.get(1).context("picture")?);
        let (w, h, rgba) = ntscrt_media::read_image(path)?;
        println!("WIC {w} x {h}");
        if let Ok(img) = image::open(path) {
            let img = img.to_rgba8();
            let differ = img.as_raw().iter().zip(&rgba).filter(|(a, b)| a != b).count();
            println!("image crate {} x {}, {differ} bytes differ", img.width(), img.height());
        }
        return Ok(());
    }
    if args.first().map(String::as_str) == Some("--encode") {
        let mut reader = ntscrt_media::VideoReader::open(args.get(1).context("clip")?.as_ref())?;
        let info = reader.info();
        let frames = args.get(3).map(|n| n.parse()).transpose()?.unwrap_or(info.total_frames).min(info.total_frames);
        let mut writer = ntscrt_media::VideoWriter::create(
            args.get(2).context("out")?.as_ref(),
            (info.width, info.height),
            info.fps_rational,
            ntscrt_media::Codec::H264,
            40_000_000,
            None,
            1,
        )?;
        for n in 0..frames {
            writer.write(&reader.frame(n)?.rgba)?;
        }
        writer.finish()?;
        println!("wrote {frames} frames at {} x {}", info.width, info.height);
        return Ok(());
    }
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
