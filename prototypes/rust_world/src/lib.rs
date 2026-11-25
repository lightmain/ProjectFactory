//! A standalone static world experiment. No engine or transport dependency.
mod snapshot;
mod view;
mod world;

pub use view::{Bounds, ViewCursor, ViewReport};

pub use world::{
    BlockId, CHUNK_EDGE, CHUNK_VOLUME, Cell, World, WorldError, WorldStats, fixture_kind,
};
