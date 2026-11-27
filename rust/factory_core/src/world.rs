//! Finite voxel rules. Unedited terrain is derived; edited chunks are shared
//! by read checkpoints and copied only when an edit touches that chunk.
use crate::entities::{EntityId, Structure, footprint};
use std::{collections::BTreeMap, sync::Arc};

pub const CHUNK_VOLUME: usize = 32 * 32 * 32;
const BELT_HEIGHT: f64 = 0.08 / 0.5;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct Cell {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

impl Cell {
    pub const fn new(x: i32, y: i32, z: i32) -> Self {
        Self { x, y, z }
    }

    pub fn checked_offset(self, x: i32, y: i32, z: i32) -> Option<Self> {
        Some(Self::new(
            self.x.checked_add(x)?,
            self.y.checked_add(y)?,
            self.z.checked_add(z)?,
        ))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Block {
    Air = 0,
    Grass,
    Dirt,
    Stone,
    Bedrock,
    Miner,
    Belt,
    Chest,
    Structure,
    BeltUp,
    BeltUpWest,
    BeltUpNorth,
    BeltUpEast,
    BeltDown,
    BeltDownWest,
    BeltDownNorth,
    BeltDownEast,
}

impl TryFrom<u8> for Block {
    type Error = Error;

    fn try_from(value: u8) -> Result<Self, Error> {
        const BLOCKS: [Block; 17] = [
            Block::Air,
            Block::Grass,
            Block::Dirt,
            Block::Stone,
            Block::Bedrock,
            Block::Miner,
            Block::Belt,
            Block::Chest,
            Block::Structure,
            Block::BeltUp,
            Block::BeltUpWest,
            Block::BeltUpNorth,
            Block::BeltUpEast,
            Block::BeltDown,
            Block::BeltDownWest,
            Block::BeltDownNorth,
            Block::BeltDownEast,
        ];
        BLOCKS
            .get(usize::from(value))
            .copied()
            .ok_or(Error::InvalidBlock)
    }
}

impl Block {
    pub fn is_slope(self) -> bool {
        self as u8 >= Self::BeltUp as u8
    }

    pub fn is_belt(self) -> bool {
        self == Self::Belt || self.is_slope()
    }

    /// Surface elevation in cell units at local X/Z (may extrapolate for rays).
    pub fn slope_elevation(self, x: f64, z: f64) -> Option<f64> {
        (self.is_slope() && x.is_finite() && z.is_finite()).then(|| self._elevation(x, z))
    }

    fn _height(self) -> f64 {
        if self == Self::Belt {
            BELT_HEIGHT
        } else if self.is_slope() {
            1.0 + BELT_HEIGHT
        } else {
            1.0
        }
    }

    fn _elevation(self, x: f64, z: f64) -> f64 {
        let progress = match (self as u8 - Self::BeltUp as u8) % 4 {
            0 => z,
            1 => 1.0 - x,
            2 => 1.0 - z,
            _ => x,
        };
        if (self as u8) < Self::BeltDown as u8 {
            progress
        } else {
            1.0 - progress
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidDimensions,
    InvalidCell,
    InvalidBlock,
    Occupied,
    GeometryConflict,
    Empty,
    ImmutableBedrock,
    InvalidRotation,
    RevisionExhausted,
    IdentityExhausted,
    InvalidDelta,
    InvalidStructure,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Bounds {
    _minimum: Cell,
    _maximum: Cell,
    _floor_depth: i32,
}

impl Default for Bounds {
    fn default() -> Self {
        Self {
            _minimum: Cell::new(-32, -4, -32),
            _maximum: Cell::new(32, 60, 32),
            _floor_depth: 4,
        }
    }
}

impl Bounds {
    pub fn new(low: Cell, high: Cell, depth: i32) -> Result<Self, Error> {
        let lengths = [
            i64::from(high.x) - i64::from(low.x),
            i64::from(high.y) - i64::from(low.y),
            i64::from(high.z) - i64::from(low.z),
        ];
        if !(1..=4).contains(&depth)
            || low.y != -depth
            || lengths.iter().any(|&length| !(1..=128).contains(&length))
            || lengths[1] <= i64::from(depth)
            || [low.x, low.y, low.z, high.x, high.y, high.z]
                .iter()
                .any(|axis| !(-256..=256).contains(axis))
        {
            return Err(Error::InvalidDimensions);
        }
        Ok(Self {
            _minimum: low,
            _maximum: high,
            _floor_depth: depth,
        })
    }

    pub fn minimum(self) -> Cell {
        self._minimum
    }
    pub fn maximum(self) -> Cell {
        self._maximum
    }
    pub fn floor_depth(self) -> i32 {
        self._floor_depth
    }

    pub fn contains(self, cell: Cell) -> bool {
        cell.x >= self._minimum.x
            && cell.x < self._maximum.x
            && cell.y >= self._minimum.y
            && cell.y < self._maximum.y
            && cell.z >= self._minimum.z
            && cell.z < self._maximum.z
    }
}

pub fn chunk_index(origin: Cell, cell: Cell) -> (Cell, u16) {
    let x = i64::from(cell.x) - i64::from(origin.x);
    let y = i64::from(cell.y) - i64::from(origin.y);
    let z = i64::from(cell.z) - i64::from(origin.z);
    (
        Cell::new((x >> 5) as i32, (y >> 5) as i32, (z >> 5) as i32),
        (((y & 31) << 10) | ((z & 31) << 5) | (x & 31)) as u16,
    )
}

pub fn chunk_cell(origin: Cell, chunk: Cell, index: u16) -> Result<Cell, Error> {
    if usize::from(index) >= CHUNK_VOLUME {
        return Err(Error::InvalidCell);
    }
    let axis = |base: i32, page: i32, local: u16| {
        i32::try_from(i64::from(base) + i64::from(page) * 32 + i64::from(local))
            .map_err(|_| Error::InvalidCell)
    };
    Ok(Cell::new(
        axis(origin.x, chunk.x, index & 31)?,
        axis(origin.y, chunk.y, index >> 10)?,
        axis(origin.z, chunk.z, (index >> 5) & 31)?,
    ))
}

#[derive(Clone)]
struct Chunk {
    _blocks: Arc<[u8]>,
    _differences: usize,
}

#[derive(Clone)]
pub struct World {
    _bounds: Bounds,
    _flat: bool,
    _chunks: BTreeMap<Cell, Chunk>,
    _block_count: usize,
    _structures: BTreeMap<EntityId, Structure>,
    _owners: BTreeMap<Cell, EntityId>,
    _next_structure_id: u64,
    _revision: u64,
}

impl World {
    pub(crate) fn write_disk(&self, w: &mut crate::persistence::Writer) {
        w.cell(self._bounds.minimum());
        w.cell(self._bounds.maximum());
        w.i32(self._bounds.floor_depth());
        w.bool(self._flat);
        w.u64(self._revision);
        w.u64(self._next_structure_id);
        let chunks = self.chunk_deltas();
        w.u64(chunks.len() as u64);
        for (at, records) in chunks {
            w.cell(at);
            w.bytes(&records);
        }
        w.u64(self._structures.len() as u64);
        for row in self._structures.values() {
            w.u64(row.id.value());
            w.cell(row.anchor);
            w.u8(row.rotation);
        }
    }
    pub(crate) fn read_disk(
        r: &mut crate::persistence::Reader<'_>,
    ) -> crate::persistence::Result<Self> {
        use crate::persistence::{Error as SaveError, ensure};
        let bounds = Bounds::new(r.cell()?, r.cell()?, r.i32()?)
            .map_err(|_| SaveError::Invalid("bounds"))?;
        let flat = r.bool()?;
        let revision = r.u64()?;
        let next = r.u64()?;
        let count = r.count(64, 20)?;
        let mut chunks = BTreeMap::new();
        for _ in 0..count {
            let at = r.cell()?;
            let records = r.bytes(CHUNK_VOLUME * 3)?.to_vec();
            ensure(chunks.insert(at, records).is_none(), "duplicate chunk")?;
        }
        let count = r.count(crate::persistence::MAX_MACHINES / 27, 21)?;
        let mut structures = Vec::with_capacity(count);
        for _ in 0..count {
            structures.push(Structure {
                id: EntityId(r.u64()?),
                anchor: r.cell()?,
                rotation: r.u8()?,
            });
        }
        let mut world = Self::from_deltas(bounds, flat, &chunks, &structures)
            .map_err(|_| SaveError::Invalid("world deltas"))?;
        ensure(
            next >= world._next_structure_id
                && next <= i64::MAX as u64
                && revision <= i64::MAX as u64,
            "world identity/revision",
        )?;
        world._next_structure_id = next;
        world._revision = revision;
        Ok(world)
    }

    pub fn flat(bounds: Bounds) -> Self {
        let block_count = ((bounds._maximum.x - bounds._minimum.x)
            * (bounds._maximum.z - bounds._minimum.z)
            * bounds._floor_depth) as usize;
        Self {
            _bounds: bounds,
            _flat: true,
            _chunks: BTreeMap::new(),
            _block_count: block_count,
            _structures: BTreeMap::new(),
            _owners: BTreeMap::new(),
            _next_structure_id: 1,
            _revision: 0,
        }
    }

    pub fn bounds(&self) -> Bounds {
        self._bounds
    }
    pub fn has_flat_baseline(&self) -> bool {
        self._flat
    }

    /// Import into an independent candidate. No live world is modified on error.
    pub fn from_deltas(
        bounds: Bounds,
        flat: bool,
        chunks: &BTreeMap<Cell, Vec<u8>>,
        structures: &[Structure],
    ) -> Result<Self, Error> {
        let mut candidate = Self::flat(bounds);
        candidate._flat = flat;
        if !flat {
            candidate._block_count = 0;
        }
        let extent = Cell::new(
            bounds._maximum.x - bounds._minimum.x,
            bounds._maximum.y - bounds._minimum.y,
            bounds._maximum.z - bounds._minimum.z,
        );
        if chunks.len() > 64 || structures.len() > (extent.x * extent.y * extent.z / 27) as usize {
            return Err(Error::InvalidDelta);
        }
        let mut placeholders = BTreeMap::new();
        let mut slopes = Vec::new();
        for (&chunk, records) in chunks {
            if chunk.x < 0
                || chunk.y < 0
                || chunk.z < 0
                || chunk.x >= (extent.x + 31) / 32
                || chunk.y >= (extent.y + 31) / 32
                || chunk.z >= (extent.z + 31) / 32
                || records.is_empty()
                || records.len() % 3 != 0
                || records.len() > CHUNK_VOLUME * 3
            {
                return Err(Error::InvalidDelta);
            }
            let mut previous = None;
            for record in records.as_chunks::<3>().0 {
                let index = u16::from_le_bytes([record[0], record[1]]);
                if previous.is_some_and(|last| index <= last) {
                    return Err(Error::InvalidDelta);
                }
                let cell = chunk_cell(bounds._minimum, chunk, index)?;
                let block = Block::try_from(record[2])?;
                if !bounds.contains(cell)
                    || block == Block::Bedrock
                    || (flat && cell.y == -bounds._floor_depth)
                {
                    return Err(Error::InvalidDelta);
                }
                previous = Some(index);
                if block == Block::Structure {
                    placeholders.insert(cell, ());
                }
                if block.is_slope() {
                    slopes.push((cell, block));
                }
                candidate._set_block(cell, block);
            }
        }
        for row in structures {
            if row.id.value() == 0
                || row.rotation > 3
                || candidate._structures.contains_key(&row.id)
            {
                return Err(Error::InvalidStructure);
            }
            let next = row
                .id
                .value()
                .checked_add(1)
                .ok_or(Error::IdentityExhausted)?;
            for cell in footprint(row.anchor)? {
                if !placeholders.contains_key(&cell)
                    || candidate._owners.insert(cell, row.id).is_some()
                {
                    return Err(Error::InvalidStructure);
                }
            }
            candidate._next_structure_id = candidate._next_structure_id.max(next);
            candidate._structures.insert(row.id, row.clone());
        }
        if candidate._owners.len() != placeholders.len() {
            return Err(Error::InvalidStructure);
        }
        for (cell, block) in slopes {
            candidate._check_geometry(cell, block)?;
        }
        Ok(candidate)
    }

    pub fn chunk_deltas(&self) -> BTreeMap<Cell, Vec<u8>> {
        self._chunks
            .iter()
            .map(|(&chunk, page)| {
                let mut records = Vec::with_capacity(page._differences * 3);
                for (index, &block) in page._blocks.iter().enumerate() {
                    let cell = chunk_cell(self._bounds._minimum, chunk, index as u16)
                        .expect("validated world chunk");
                    if block != self._baseline(cell) as u8 {
                        records.extend_from_slice(&(index as u16).to_le_bytes());
                        records.push(block);
                    }
                }
                (chunk, records)
            })
            .collect()
    }

    pub fn structure_rows(&self) -> Vec<Structure> {
        self._structures.values().cloned().collect()
    }
    pub fn contains(&self, cell: Cell) -> bool {
        self._bounds.contains(cell)
    }
    pub fn block_count(&self) -> usize {
        self._block_count
    }
    pub fn allocated_block_bytes(&self) -> usize {
        self._chunks.len() * CHUNK_VOLUME
    }
    pub fn revision(&self) -> u64 {
        self._revision
    }

    pub fn block(&self, cell: Cell) -> Block {
        if !self.contains(cell) {
            return Block::Air;
        }
        let (chunk, index) = chunk_index(self._bounds._minimum, cell);
        self._chunks.get(&chunk).map_or_else(
            || self._baseline(cell),
            |page| {
                Block::try_from(page._blocks[usize::from(index)])
                    .expect("only validated block values enter a world chunk")
            },
        )
    }

    pub fn structure(&self, id: EntityId) -> Option<&Structure> {
        self._structures.get(&id)
    }

    pub fn structure_at(&self, cell: Cell) -> Option<&Structure> {
        self._owners
            .get(&cell)
            .and_then(|id| self._structures.get(id))
    }

    pub fn place(&mut self, cell: Cell, block: Block) -> Result<(), Error> {
        if block == Block::Structure {
            return self.place_structure(cell, 0).map(|_| ());
        }
        if matches!(block, Block::Air | Block::Bedrock) {
            return Err(Error::InvalidBlock);
        }
        self._check_placement(cell, block)?;
        let revision = self._next_revision()?;
        self._set_block(cell, block);
        self._revision = revision;
        Ok(())
    }

    /// Spatial preflight only: no page allocation, revision or identity change.
    pub fn check_placement(&self, cell: Cell, block: Block) -> Result<(), Error> {
        if matches!(block, Block::Air | Block::Bedrock) {
            return Err(Error::InvalidBlock);
        }
        if block == Block::Structure {
            for part in footprint(cell)? {
                self._check_placement(part, Block::Stone)?;
            }
            return Ok(());
        }
        self._check_placement(cell, block)
    }

    pub fn place_structure(&mut self, anchor: Cell, rotation: u8) -> Result<EntityId, Error> {
        if rotation > 3 {
            return Err(Error::InvalidRotation);
        }
        let cells = footprint(anchor)?;
        for &cell in &cells {
            self._check_placement(cell, Block::Stone)?;
        }
        let revision = self._next_revision()?;
        let next = self
            ._next_structure_id
            .checked_add(1)
            .ok_or(Error::IdentityExhausted)?;
        let id = EntityId(self._next_structure_id);
        self._structures.insert(
            id,
            Structure {
                id,
                anchor,
                rotation,
            },
        );
        for cell in cells {
            self._owners.insert(cell, id);
            self._set_block(cell, Block::Structure);
        }
        self._next_structure_id = next;
        self._revision = revision;
        Ok(id)
    }

    pub fn remove(&mut self, cell: Cell) -> Result<(), Error> {
        if !self.contains(cell) {
            return Err(Error::InvalidCell);
        }
        match self.block(cell) {
            Block::Air => return Err(Error::Empty),
            Block::Bedrock => return Err(Error::ImmutableBedrock),
            _ => (),
        }
        let revision = self._next_revision()?;
        if let Some(id) = self._owners.get(&cell).copied() {
            let anchor = self._structures[&id].anchor;
            let cells = footprint(anchor)?;
            self._structures.remove(&id);
            for part in cells {
                self._owners.remove(&part);
                self._set_block(part, Block::Air);
            }
        } else {
            self._set_block(cell, Block::Air);
        }
        self._revision = revision;
        Ok(())
    }

    fn _next_revision(&self) -> Result<u64, Error> {
        self._revision
            .checked_add(1)
            .ok_or(Error::RevisionExhausted)
    }

    fn _baseline(&self, cell: Cell) -> Block {
        if !self._flat || !self.contains(cell) {
            return Block::Air;
        }
        if cell.y == -self._bounds._floor_depth {
            return Block::Bedrock;
        }
        match cell.y {
            -1 => Block::Grass,
            -2 => Block::Dirt,
            -3 => Block::Stone,
            _ => Block::Air,
        }
    }

    fn _check_placement(&self, cell: Cell, block: Block) -> Result<(), Error> {
        if !self.contains(cell) {
            return Err(Error::InvalidCell);
        }
        if self.block(cell) != Block::Air {
            return Err(Error::Occupied);
        }
        self._check_geometry(cell, block)
    }

    fn _check_geometry(&self, cell: Cell, block: Block) -> Result<(), Error> {
        if f64::from(cell.y) + block._height() > f64::from(self._bounds._maximum.y) {
            return Err(Error::GeometryConflict);
        }
        for step in [-1, 1] {
            let neighbor = cell.checked_offset(0, step, 0).ok_or(Error::InvalidCell)?;
            let other = self.block(neighbor);
            if other != Block::Air
                && (block.is_slope() || other.is_slope())
                && blocks_intersect(cell, block, neighbor, other)
            {
                return Err(Error::GeometryConflict);
            }
        }
        Ok(())
    }

    fn _set_block(&mut self, cell: Cell, block: Block) {
        let previous = self.block(cell);
        if previous == block {
            return;
        }
        let origin = self._bounds._minimum;
        let (key, index) = chunk_index(origin, cell);
        if !self._chunks.contains_key(&key) {
            let bytes: Vec<u8> = (0..CHUNK_VOLUME)
                .map(|index| {
                    let position = chunk_cell(origin, key, index as u16)
                        .expect("a valid world chunk has representable coordinates");
                    self._baseline(position) as u8
                })
                .collect();
            self._chunks.insert(
                key,
                Chunk {
                    _blocks: bytes.into(),
                    _differences: 0,
                },
            );
        }
        let baseline = self._baseline(cell);
        let chunk = self._chunks.get_mut(&key).expect("chunk just allocated");
        chunk._differences =
            chunk._differences + usize::from(block != baseline) - usize::from(previous != baseline);
        Arc::make_mut(&mut chunk._blocks)[usize::from(index)] = block as u8;
        self._block_count = self._block_count + usize::from(block != Block::Air)
            - usize::from(previous != Block::Air);
        if chunk._differences == 0 {
            self._chunks.remove(&key);
        }
    }
}

/// Physical intersection for vertically adjacent cells. A slope occupies only
/// its inclined slab; stacked parallel slopes can therefore have clear space.
pub fn blocks_intersect(cell: Cell, block: Block, other_cell: Cell, other: Block) -> bool {
    if block == Block::Air
        || other == Block::Air
        || cell.x != other_cell.x
        || cell.z != other_cell.z
    {
        return false;
    }
    let bottom = f64::from(cell.y).max(f64::from(other_cell.y));
    let top = (f64::from(cell.y) + block._height()).min(f64::from(other_cell.y) + other._height());
    if bottom >= top {
        return false;
    }
    if block.is_slope() && other.is_slope() {
        let mut low = f64::INFINITY;
        let mut high = f64::NEG_INFINITY;
        for x in [0.0, 1.0] {
            for z in [0.0, 1.0] {
                let difference = f64::from(cell.y) - f64::from(other_cell.y)
                    + block._elevation(x, z)
                    - other._elevation(x, z);
                low = low.min(difference);
                high = high.max(difference);
            }
        }
        low < BELT_HEIGHT && high > -BELT_HEIGHT
    } else if block.is_slope() || other.is_slope() {
        let (slope_cell, slope) = if block.is_slope() {
            (cell, block)
        } else {
            (other_cell, other)
        };
        let mut low = f64::INFINITY;
        let mut high = f64::NEG_INFINITY;
        for x in [0.0, 1.0] {
            for z in [0.0, 1.0] {
                let elevation = f64::from(slope_cell.y) + slope._elevation(x, z);
                low = low.min(elevation);
                high = high.max(elevation + BELT_HEIGHT);
            }
        }
        bottom < high && top > low
    } else {
        true
    }
}
