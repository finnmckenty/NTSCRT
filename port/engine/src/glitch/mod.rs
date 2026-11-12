//! The Glitch stage: a simulated TV receiver and VCR (`receiver`), and the
//! GPU pass that draws the field it displays (`stage`, WGSL ports of the
//! Mac's Metal kernels). A port of the Mac's GlitchParams, Receiver,
//! GlitchStage and GlitchRenderer.

pub mod params;
pub mod receiver;
pub mod stage;

pub use params::{GlitchParam, GlitchSettings, Group, Kind, PARAMS, TIMING_IDS};
pub use stage::{GlitchFrame, GlitchHistory};
