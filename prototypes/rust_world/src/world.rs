use std::{error::Error, fmt, io, rc::Rc};

pub const CHUNK_EDGE: u32 = 16;
pub const CHUNK_VOLUME: usize = 4096;
pub type BlockId = u16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    pub x: u32,
    pub y: u32,
    pub z: u32,
}

#[derive(Debug)]
pub enum WorldError {
    InvalidDimensions,
    InvalidCell,
    InvalidKind,
    InvalidBounds,
    WrongWorld,
    RevisionExhausted,
    Format(&'static str),
    Io(io::Error),
}

impl fmt::Display for WorldError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            other => write!(formatter, "{other:?}"),
        }
    }
}

impl Error for WorldError {}

impl From<io::Error> for WorldError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WorldStats {
    pub revision: u64,
    pub counts: [u64; 5],
    pub non_empty: u64,
    pub chunk_count: usize,
    pub block_bytes: usize,
}

pub(crate) struct Chunk {
    pub(crate) _blocks: Box<[BlockId; CHUNK_VOLUME]>,
    pub(crate) _revision: u64,
}

impl Chunk {
    pub(crate) fn _empty() -> Self {
        Self {
            _blocks: Box::new([0; CHUNK_VOLUME]),
            _revision: 0,
        }
    }
}

pub struct World {
    pub(crate) _identity: Rc<()>,
    pub(crate) _size: Cell,
    pub(crate) _chunks: Vec<Chunk>,
    pub(crate) _counts: [u64; 5],
    pub(crate) _revision: u64,
}

pub(crate) fn _chunk_dimensions(size: Cell) -> Result<Cell, WorldError> {
    if [size.x, size.y, size.z]
        .into_iter()
        .any(|axis| axis == 0 || axis > 128 || !axis.is_multiple_of(CHUNK_EDGE))
    {
        return Err(WorldError::InvalidDimensions);
    }
    Ok(Cell {
        x: size.x / CHUNK_EDGE,
        y: size.y / CHUNK_EDGE,
        z: size.z / CHUNK_EDGE,
    })
}

/// Fixed integer fixture mixer. All arithmetic is explicitly modulo 2^32.
pub fn fixture_kind(cell: Cell, seed: u32) -> BlockId {
    let mut value = seed
        ^ cell.x.wrapping_mul(73_856_093)
        ^ cell.y.wrapping_mul(19_349_663)
        ^ cell.z.wrapping_mul(83_492_791);
    value ^= value >> 16;
    value = value.wrapping_mul(0x85eb_ca6b);
    value ^= value >> 13;
    value = value.wrapping_mul(0xc2b2_ae35);
    value ^= value >> 16;
    (value % 4 + 1) as BlockId
}

impl World {
    pub fn new(size: Cell) -> Result<Self, WorldError> {
        let dimensions = _chunk_dimensions(size)?;
        let count = (dimensions.x * dimensions.y * dimensions.z) as usize;
        Ok(Self {
            _identity: Rc::new(()),
            _size: size,
            _chunks: (0..count).map(|_| Chunk::_empty()).collect(),
            _counts: [(count * CHUNK_VOLUME) as u64, 0, 0, 0, 0],
            _revision: 0,
        })
    }

    pub fn generate(size: Cell, seed: u32) -> Result<Self, WorldError> {
        let mut world = Self::new(size)?;
        let dimensions = _chunk_dimensions(size)?;
        world._counts = [0; 5];
        for (index, chunk) in world._chunks.iter_mut().enumerate() {
            let index = index as u32;
            let base = Cell {
                x: index % dimensions.x * CHUNK_EDGE,
                z: index / dimensions.x % dimensions.z * CHUNK_EDGE,
                y: index / (dimensions.x * dimensions.z) * CHUNK_EDGE,
            };
            for (offset, value) in chunk._blocks.iter_mut().enumerate() {
                let offset = offset as u32;
                *value = fixture_kind(
                    Cell {
                        x: base.x + offset % CHUNK_EDGE,
                        z: base.z + offset / CHUNK_EDGE % CHUNK_EDGE,
                        y: base.y + offset / (CHUNK_EDGE * CHUNK_EDGE),
                    },
                    seed,
                );
                world._counts[*value as usize] += 1;
            }
        }
        Ok(world)
    }

    pub fn size(&self) -> Cell {
        self._size
    }

    pub fn cell_count(&self) -> usize {
        self._chunks.len() * CHUNK_VOLUME
    }

    pub fn stats(&self) -> WorldStats {
        WorldStats {
            revision: self._revision,
            counts: self._counts,
            non_empty: self.cell_count() as u64 - self._counts[0],
            chunk_count: self._chunks.len(),
            block_bytes: self.cell_count() * size_of::<BlockId>(),
        }
    }

    pub(crate) fn _checked_index(&self, cell: Cell) -> Result<(usize, usize), WorldError> {
        if cell.x >= self._size.x || cell.y >= self._size.y || cell.z >= self._size.z {
            return Err(WorldError::InvalidCell);
        }
        let chunks_x = self._size.x / CHUNK_EDGE;
        let chunks_z = self._size.z / CHUNK_EDGE;
        let chunk = cell.x / CHUNK_EDGE
            + chunks_x * (cell.z / CHUNK_EDGE + chunks_z * (cell.y / CHUNK_EDGE));
        let offset = cell.x % CHUNK_EDGE
            + CHUNK_EDGE * (cell.z % CHUNK_EDGE + CHUNK_EDGE * (cell.y % CHUNK_EDGE));
        Ok((chunk as usize, offset as usize))
    }

    pub fn get_block(&self, cell: Cell) -> Result<BlockId, WorldError> {
        let (chunk, offset) = self._checked_index(cell)?;
        Ok(self._chunks[chunk]._blocks[offset])
    }

    pub fn set_block(&mut self, cell: Cell, kind: BlockId) -> Result<bool, WorldError> {
        if kind > 4 {
            return Err(WorldError::InvalidKind);
        }
        let (chunk, offset) = self._checked_index(cell)?;
        let old = self._chunks[chunk]._blocks[offset];
        if old == kind {
            return Ok(false);
        }
        let revision = self
            ._revision
            .checked_add(1)
            .ok_or(WorldError::RevisionExhausted)?;
        self._chunks[chunk]._blocks[offset] = kind;
        self._chunks[chunk]._revision = revision;
        self._counts[old as usize] -= 1;
        self._counts[kind as usize] += 1;
        self._revision = revision;
        Ok(true)
    }
}
