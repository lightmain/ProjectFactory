//! Untimed, flat reference and independent wire decoder for the experiment.
use factory_world_probe::{Bounds, Cell, World};
use std::collections::{BTreeMap, BTreeSet};

pub struct Reference {
    _size: Cell,
    _cells: Vec<u16>,
    _counts: [u64; 5],
    _revision: u64,
}

impl Reference {
    pub fn new(size: Cell, seed: u32) -> Self {
        let mut cells = Vec::with_capacity((size.x * size.y * size.z) as usize);
        let mut counts = [0; 5];
        for y in 0..size.y {
            for z in 0..size.z {
                for x in 0..size.x {
                    let mut mixed = seed
                        ^ x.wrapping_mul(73_856_093)
                        ^ y.wrapping_mul(19_349_663)
                        ^ z.wrapping_mul(83_492_791);
                    mixed = (mixed ^ (mixed >> 16)).wrapping_mul(0x85eb_ca6b);
                    mixed = (mixed ^ (mixed >> 13)).wrapping_mul(0xc2b2_ae35);
                    mixed ^= mixed >> 16;
                    let kind = (mixed % 4 + 1) as u16;
                    cells.push(kind);
                    counts[kind as usize] += 1;
                }
            }
        }
        Self {
            _size: size,
            _cells: cells,
            _counts: counts,
            _revision: 0,
        }
    }

    fn _index(&self, cell: Cell) -> usize {
        (cell.x + self._size.x * (cell.z + self._size.z * cell.y)) as usize
    }

    pub fn edit(&mut self, cell: Cell, kind: u16) {
        let index = self._index(cell);
        let old = self._cells[index];
        if old != kind {
            self._counts[old as usize] -= 1;
            self._counts[kind as usize] += 1;
            self._cells[index] = kind;
            self._revision += 1;
        }
    }

    pub fn check_world(&self, world: &World) -> Result<(), String> {
        if world.size() != self._size
            || world.stats().counts != self._counts
            || world.stats().revision != self._revision
        {
            return Err("world stats differ from reference".into());
        }
        for (index, &expected) in self._cells.iter().enumerate() {
            let index = index as u32;
            let cell = Cell {
                x: index % self._size.x,
                z: index / self._size.x % self._size.z,
                y: index / (self._size.x * self._size.z),
            };
            if world.get_block(cell).map_err(|error| error.to_string())? != expected {
                return Err(format!("world cell differs at {cell:?}"));
            }
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct Cache {
    _chunks: BTreeMap<u32, Vec<u16>>,
}

fn take<const N: usize>(packet: &mut &[u8]) -> Result<[u8; N], String> {
    if packet.len() < N {
        return Err("truncated packet".into());
    }
    let (field, rest) = packet.split_at(N);
    *packet = rest;
    field.try_into().map_err(|_| "invalid field".into())
}

impl Cache {
    pub fn apply(
        &mut self,
        mut packet: &[u8],
        bounds: Bounds,
        reference: &Reference,
    ) -> Result<(), String> {
        if &take::<8>(&mut packet)? != b"FVIEW001" {
            return Err("packet magic".into());
        }
        let revision = u64::from_le_bytes(take(&mut packet)?);
        let mut counts = [0; 5];
        for count in &mut counts {
            *count = u64::from_le_bytes(take(&mut packet)?);
        }
        let non_empty = u64::from_le_bytes(take(&mut packet)?);
        if revision != reference._revision
            || counts != reference._counts
            || non_empty != reference._cells.len() as u64 - counts[0]
        {
            return Err("packet statistics differ".into());
        }
        let entered = u32::from_le_bytes(take(&mut packet)?);
        let updated = u32::from_le_bytes(take(&mut packet)?);
        let left = u32::from_le_bytes(take(&mut packet)?);
        let mut touched = BTreeSet::new();
        for (count, entering) in [(entered, true), (updated, false)] {
            for _ in 0..count {
                let id = u32::from_le_bytes(take(&mut packet)?);
                if !touched.insert(id) || self._chunks.contains_key(&id) == entering {
                    return Err("duplicate or invalid enter/update".into());
                }
                let mut cells = Vec::with_capacity(4096);
                for _ in 0..4096 {
                    let kind = u16::from_le_bytes(take(&mut packet)?);
                    if kind > 4 {
                        return Err("invalid wire kind".into());
                    }
                    cells.push(kind);
                }
                self._chunks.insert(id, cells);
            }
        }
        for _ in 0..left {
            let id = u32::from_le_bytes(take(&mut packet)?);
            if !touched.insert(id) || self._chunks.remove(&id).is_none() {
                return Err("invalid leave".into());
            }
        }
        if !packet.is_empty() {
            return Err("trailing packet bytes".into());
        }
        let size = reference._size;
        let mut visible = BTreeSet::new();
        // Deliberately enumerate the reference grid instead of reusing the producer's range math.
        for cy in 0..size.y / 16 {
            for cz in 0..size.z / 16 {
                for cx in 0..size.x / 16 {
                    let base = [cx * 16, cy * 16, cz * 16];
                    let intersects = (0..3).all(|axis| {
                        bounds.minimum[axis] < bounds.maximum[axis]
                            && (base[axis] as i32) < bounds.maximum[axis]
                            && (base[axis] + 16) as i32 > bounds.minimum[axis]
                    });
                    if !intersects {
                        continue;
                    }
                    let id = cx + size.x / 16 * (cz + size.z / 16 * cy);
                    visible.insert(id);
                    let actual = self._chunks.get(&id).ok_or("missing visible chunk")?;
                    for (offset, &kind) in actual.iter().enumerate() {
                        let offset = offset as u32;
                        let cell = Cell {
                            x: base[0] + offset % 16,
                            z: base[2] + offset / 16 % 16,
                            y: base[1] + offset / 256,
                        };
                        if kind != reference._cells[reference._index(cell)] {
                            return Err(format!("cache differs at {cell:?}"));
                        }
                    }
                }
            }
        }
        if visible.len() != self._chunks.len()
            || self._chunks.keys().any(|id| !visible.contains(id))
        {
            return Err("cache visibility differs".into());
        }
        Ok(())
    }
}
