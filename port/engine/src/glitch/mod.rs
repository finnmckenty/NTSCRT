//! The Glitch stage: a simulated TV receiver (`receiver`), a VCR playing a
//! simulated tape (`tape`, `deck`, `vcr`), and the GPU passes that draw the
//! field the TV displays (`stage`, `vcr`; WGSL ports of the Mac's Metal
//! kernels), and the picture arriving as a composite signal through the
//! antenna socket (`composite`). A port of the Mac's GlitchParams, Tape,
//! Deck, Receiver, VcrStage, GlitchStage, GlitchRenderer and CompositeSignal.

pub mod composite;
pub mod deck;
pub mod params;
pub mod receiver;
pub mod stage;
pub mod tape;
pub mod transport;
pub mod vcr;

pub use params::{controls, GlitchParam, GlitchSettings, Group, Kind, VcrCondition, CONNECTIONS, CONNECTION_KEYS, DECKS, DECK_KEYS, PARAMS, TAPES, TAPE_KEYS, VCR_ID};
pub use stage::{GlitchFrame, GlitchHistory};
