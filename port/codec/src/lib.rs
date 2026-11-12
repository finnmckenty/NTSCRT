//! NTSCRT's Digital video stage for Windows: a faithful port of the Mac
//! app's `Sources/CrtCodec` (Swift). A camera's capture (sensor sampling,
//! noise, tone, sharpening) feeding a small real video codec — 8×8 DCT
//! blocks with JPEG tables and motion-compensated prediction, or Microsoft
//! Video 1's block colors — whose decoder can lose data and keyframes.
//! Blocking, smearing and datamoshing come out of the codec; nothing is
//! drawn.
//!
//! Same math in the same order as the Mac, same random numbers, same frame
//! numbering and keyframe / re-run / checkpoint rules — so a frame looks the
//! same whether it's jumped to or played to, and bit for bit what the Mac
//! makes of it (`examples/parity.rs` against `ref/`, the Mac's own sources
//! compiled into a CLI). The one exception is the camera's capture scaling,
//! which on the Mac is vImage's high-quality resampler: [`resample`]
//! reproduces that filter as measured (Lanczos-5, area-aware), to within one
//! code value on under 1% of values. Between keyframes the codec carries
//! even differences that small a long way (the Mac does the same with its
//! own input nudged as little), so a downscaled predicted stream drifts from
//! the Mac's; intra-only formats and every unscaled capture match.
//!
//! Pixels are RGBA8 throughout (the Mac's are BGRA8; every channel-specific
//! step reads the same color it does there). Float tables the Mac computes
//! with its libm (`cos`, `pow`) are embedded as its exact bits; the few
//! `powf` calls left at run time (sRGB encode, exposure, the bitrate
//! squeeze) use the platform's, identical on macOS and at most an ulp off
//! elsewhere.
//!
//! The engine's entry point is [`DigitalVideoRenderer::process`]; the panel
//! uses [`DigitalParam`], [`DigitalFormat`] and [`DigitalSettings`].

// The port keeps the Swift's shape on purpose — indexed loops (they fix the
// order every sum is taken in), `!(a > b)` guards (Swift's `guard a > b`,
// NaN included), `(n + 7) / 8` padding — so a reader can check it against
// the Mac line by line.
#![allow(
    clippy::needless_range_loop,
    clippy::neg_cmp_op_on_partial_ord,
    clippy::manual_div_ceil,
    clippy::should_implement_trait,
    clippy::needless_option_as_deref,
    clippy::type_complexity
)]

mod codec;
mod params;
pub mod resample;
mod renderer;
mod tables;
mod video1;

pub use codec::{
    CodecFrameKind, CodecGeometry, CodecPicture, CodecPlane, CodecState, DigitalCodec, FrameSettings, MotionVector,
    SplitMix, Steps,
};
pub use params::{
    ChromaSubsampling, DigitalCodecKind, DigitalFormat, DigitalGroup, DigitalParam, DigitalParamKind, DigitalSettings,
    STRUCTURE_IDS,
};
pub use renderer::{CcdResponse, DigitalHistory, DigitalTiming, DigitalVideoRenderer, FrameVisitor};
pub use video1::{Video1Codec, Video1Mode, V3};

#[cfg(test)]
mod tests;
