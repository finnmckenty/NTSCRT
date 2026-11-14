//! The Glitch stage: a simulated TV receiver (`receiver`), a VCR playing a
//! simulated tape (`tape`, `deck`, `vcr`), and the GPU passes that draw the
//! field the TV displays (`stage`, `vcr`; WGSL ports of the Mac's Metal
//! kernels). A port of the Mac's GlitchParams, Tape, Deck, Receiver,
//! VcrStage, GlitchStage and GlitchRenderer.

pub mod deck;
pub mod params;
pub mod receiver;
pub mod stage;
pub mod tape;
pub mod vcr;

pub use params::{controls, GlitchParam, GlitchSettings, Group, Kind, VcrCondition, DECKS, DECK_KEYS, PARAMS, TAPES, TAPE_KEYS, VCR_ID};
pub use stage::{GlitchFrame, GlitchHistory};
