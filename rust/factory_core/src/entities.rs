//! Logical structure identities, independent of scene nodes and memory addresses.
use crate::world::Cell;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct EntityId(pub(crate) u64);

impl EntityId {
    pub fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Structure {
    pub id: EntityId,
    pub anchor: Cell,
    pub rotation: u8,
}

/// Bottom-centre snapping, including Godot's half-away-from-zero rounding.
pub fn structure_anchor(point: [f64; 3]) -> Result<Cell, crate::world::Error> {
    let mut axes = [0_i32; 3];
    for (axis, position) in point.into_iter().enumerate() {
        let snapped = (position / 0.5 - if axis == 1 { 0.0 } else { 0.5 }).round();
        if !snapped.is_finite() || snapped < i32::MIN as f64 || snapped > i32::MAX as f64 {
            return Err(crate::world::Error::InvalidCell);
        }
        axes[axis] = snapped as i32;
    }
    Ok(Cell::new(axes[0], axes[1], axes[2]))
}

pub(crate) fn footprint(anchor: Cell) -> Result<[Cell; 27], crate::world::Error> {
    let mut cells = [anchor; 27];
    for x in -1..=1 {
        for y in 0..3 {
            for z in -1..=1 {
                let index = ((x + 1) * 9 + y * 3 + z + 1) as usize;
                cells[index] = anchor
                    .checked_offset(x, y, z)
                    .ok_or(crate::world::Error::InvalidCell)?;
            }
        }
    }
    Ok(cells)
}
