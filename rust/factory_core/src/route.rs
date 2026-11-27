//! Bounded orthogonal footprint and minimum-height geometry. No world or ports.
use crate::world::Cell;

/// Covers any non-self-intersecting route in the inherited finite world.
pub const MAX_ROUTE_CELLS: usize = 128 * 128 * 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidLimit,
    TooLong,
    InvalidHeights,
    NoRoute,
}

pub fn footprint(
    start: Cell,
    end: Cell,
    north_south_first: bool,
    max_cells: usize,
) -> Result<Vec<Cell>, Error> {
    if max_cells == 0 || max_cells > MAX_ROUTE_CELLS {
        return Err(Error::InvalidLimit);
    }
    let length = (i64::from(end.x) - i64::from(start.x)).unsigned_abs()
        + (i64::from(end.z) - i64::from(start.z)).unsigned_abs()
        + 1;
    if length > max_cells as u64 {
        return Err(Error::TooLong);
    }
    let mut cells = Vec::with_capacity(length as usize);
    let mut cursor = start;
    cells.push(cursor);
    for axis in if north_south_first { [2, 0] } else { [0, 2] } {
        let target = if axis == 0 { end.x } else { end.z };
        let position = if axis == 0 {
            &mut cursor.x
        } else {
            &mut cursor.z
        };
        let step = (i64::from(target) - i64::from(*position)).signum() as i32;
        // The cursor stays between two representable endpoints.
        while if axis == 0 { cursor.x } else { cursor.z } != target {
            if axis == 0 {
                cursor.x += step;
            } else {
                cursor.z += step;
            }
            cells.push(cursor);
        }
    }
    Ok(cells)
}

/// Each link has capacity zero (fixed/corner) or one (straight ramp).
/// Endpoints are fixed; an infeasible endpoint returns no route.
pub fn fit_heights(
    floors: &[i32],
    capacities: &[u8],
    start_height: i32,
    end_height: i32,
) -> Result<Vec<i32>, Error> {
    if floors.len() > MAX_ROUTE_CELLS {
        return Err(Error::TooLong);
    }
    if floors.is_empty()
        || capacities.len() != floors.len() - 1
        || capacities.iter().any(|&capacity| capacity > 1)
    {
        return Err(Error::InvalidHeights);
    }
    let mut heights = Vec::with_capacity(floors.len());
    heights.push(floors[0]);
    for pair in floors.windows(2) {
        // The lower end of a ramp also clears its preceding column.
        heights.push(pair[0].max(pair[1]));
    }
    heights[0] = heights[0].max(start_height);
    let last = heights.len() - 1;
    heights[last] = heights[last].max(end_height);
    for (index, &capacity) in capacities.iter().enumerate() {
        // Saturation is exact here: a lower bound below i32::MIN cannot
        // raise any representable floor.
        heights[index + 1] =
            heights[index + 1].max(heights[index].saturating_sub(i32::from(capacity)));
    }
    for (index, &capacity) in capacities.iter().enumerate().rev() {
        heights[index] = heights[index].max(heights[index + 1].saturating_sub(i32::from(capacity)));
    }
    if heights[0] != start_height || heights[last] != end_height {
        return Err(Error::NoRoute);
    }
    Ok(heights)
}
