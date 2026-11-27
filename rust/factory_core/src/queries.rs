//! Logical ray queries in metres, independent of meshes and physics updates.
use crate::world::{Block, Cell, World};

const CELL_SIZE: f64 = 0.5;
const BELT_HEIGHT: f64 = 0.08;
const EPSILON: f64 = 0.000001;

/// Two-component local coordinates retain crossings smaller than one ulp.
/// In particular, a nearly horizontal ray can cross a plane long before
/// the clipped coordinate changes its rounded f64 value.
#[derive(Clone)]
struct Coordinate {
    value: f64,
    residual: f64,
}

#[derive(Clone, Copy)]
struct Ray {
    vector: [f64; 3],
}

impl Ray {
    fn crossing(self, coordinate: &Coordinate, boundary: f64, axis: usize) -> f64 {
        coordinate.crossing(boundary, self.vector[axis])
    }

    fn offset(self, axis: usize, distance: f64) -> Coordinate {
        Coordinate::product(self.vector[axis], distance)
    }
}

impl Coordinate {
    fn exact(value: f64) -> Self {
        Self {
            value,
            residual: 0.0,
        }
    }

    fn sum(a: f64, b: f64) -> Self {
        let value = a + b;
        let rounded_b = value - a;
        let residual = (a - (value - rounded_b)) + (b - rounded_b);
        Self { value, residual }
    }

    fn product(a: f64, b: f64) -> Self {
        let value = a * b;
        Self {
            value,
            residual: a.mul_add(b, -value),
        }
    }

    fn add(&self, other: Self) -> Self {
        let sum = Self::sum(self.value, other.value);
        Self::sum(sum.value, sum.residual + self.residual + other.residual)
    }

    fn negate(&self) -> Self {
        Self {
            value: -self.value,
            residual: -self.residual,
        }
    }

    fn divide(&self, divisor: f64) -> Self {
        let value = self.value / divisor;
        if !value.is_finite() {
            return Self::exact(value);
        }
        let remainder = divisor.mul_add(-value, self.value) + self.residual;
        Self::sum(value, remainder / divisor)
    }

    fn crossing(&self, boundary: f64, ray: f64) -> f64 {
        if ray == 0.0 {
            return if !self.below(boundary) && !self.above(boundary) {
                0.0
            } else {
                f64::INFINITY
            };
        }
        Self::exact(boundary).add(self.negate()).divide(ray).value
    }

    fn multiply(&self, factor: f64) -> Self {
        Self::product(self.value, factor).add(Self::product(self.residual, factor))
    }

    fn finite(&self) -> bool {
        self.value.is_finite() && self.residual.is_finite()
    }

    fn below(&self, boundary: f64) -> bool {
        self.value < boundary || (self.value == boundary && self.residual < 0.0)
    }

    fn above(&self, boundary: f64) -> bool {
        self.value > boundary || (self.value == boundary && self.residual > 0.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hit {
    pub cell: Cell,
    pub normal: Cell,
    pub distance: f64,
    pub position: [f64; 3],
}

impl Hit {
    pub fn adjacent_cell(self) -> Option<Cell> {
        self.cell
            .checked_offset(self.normal.x, self.normal.y, self.normal.z)
    }
}

/// The finite world is clipped before DDA: work depends on world dimensions,
/// never on the distance from the origin. Corner ties step X, then Y, then Z,
/// matching the current grid query rather than skipping the intervening cells.
pub fn cast(
    world: &World,
    origin: [f64; 3],
    direction: [f64; 3],
    max_distance: f64,
) -> Option<Hit> {
    if !origin
        .iter()
        .chain(&direction)
        .all(|value| value.is_finite())
        || direction.iter().all(|value| value.abs() < 0.00001)
        || !max_distance.is_finite()
        || max_distance < 0.0
    {
        return None;
    }
    // Scaling first also accepts finite vectors whose squared length overflows.
    let scale = direction.iter().fold(0.0_f64, |a, b| a.max(b.abs()));
    let scaled = direction.map(|value| value / scale);
    let length = scaled.iter().map(|value| value * value).sum::<f64>().sqrt();
    let ray = scaled.map(|value| value / length);
    let bounds = world.bounds();
    let low = _coordinates(bounds.minimum()).map(|value| value * CELL_SIZE);
    let high = _coordinates(bounds.maximum()).map(|value| value * CELL_SIZE);
    // Rebase on the dominant entry plane to keep traversal local.
    let reference = (0..3).max_by(|&a, &b| ray[a].abs().total_cmp(&ray[b].abs()))?;
    let plane = origin[reference].clamp(low[reference], high[reference]);
    let offset = (plane - origin[reference]) / ray[reference];
    if !offset.is_finite() || offset < 0.0 {
        return None;
    }
    let rebased = if offset == 0.0 {
        origin.map(Coordinate::exact)
    } else {
        std::array::from_fn(|axis| {
            Coordinate::product(origin[axis], ray[reference])
                .add(Coordinate::product(origin[reference], ray[axis]).negate())
                .divide(ray[reference])
                .add(Coordinate::product(plane, ray[axis]).divide(ray[reference]))
        })
    };
    if !rebased.iter().all(|value| value.finite()) {
        return None;
    }
    // Compute the endpoint in the same local frame.
    let remaining =
        (ray[reference].mul_add(max_distance, origin[reference]) - plane) / ray[reference];
    let traversal = Ray { vector: ray };
    let (entry, exit, mut normal) = _interval(low, high, &rebased, traversal, remaining, 1e-12)?;
    let offset = offset + entry;
    if offset == 0.0 {
        normal = Cell::new(0, 0, 0);
    }
    let start = std::array::from_fn(|axis| rebased[axis].add(traversal.offset(axis, entry)));
    let limit = (remaining - entry).min((exit - entry).max(0.0));
    let mut cell = start.each_ref().map(|coordinate| {
        let floor = (coordinate.value / CELL_SIZE).floor() as i32;
        floor - i32::from(coordinate.below(f64::from(floor) * CELL_SIZE))
    });
    let step = direction.map(|value| {
        if value > 0.0 {
            1
        } else if value < 0.0 {
            -1
        } else {
            0
        }
    });
    if offset > 0.0 {
        // Reconstruct the cell just before all entry-plane crossings. DDA
        // must perform tied crossings one axis at a time, including cells
        // touched only at the world boundary.
        for axis in 0..3 {
            let boundary = (start[axis].value / CELL_SIZE).round();
            if step[axis] != 0
                && traversal
                    .crossing(&start[axis], boundary * CELL_SIZE, axis)
                    .abs()
                    <= 1e-12
            {
                cell[axis] = boundary as i32 - i32::from(step[axis] > 0);
            }
        }
    }
    let mut next = [f64::INFINITY; 3];
    let mut increment = [f64::INFINITY; 3];
    for axis in 0..3 {
        if step[axis] != 0 {
            let boundary = f64::from(cell[axis] + i32::from(step[axis] > 0)) * CELL_SIZE;
            let crossing = traversal.crossing(&start[axis], boundary, axis);
            next[axis] = if offset > 0.0 && crossing.abs() <= 1e-12 {
                0.0
            } else {
                crossing.max(0.0)
            };
            increment[axis] = traversal
                .crossing(&Coordinate::exact(0.0), CELL_SIZE, axis)
                .abs();
        }
    }
    let mut distance = 0.0;
    let minimum = bounds.minimum();
    let maximum = bounds.maximum();
    let steps = maximum.x - minimum.x + maximum.y - minimum.y + maximum.z - minimum.z + 6;
    for _ in 0..steps {
        if distance > limit {
            break;
        }
        let position = Cell::new(cell[0], cell[1], cell[2]);
        let segment_end = limit.min(next[0].min(next[1]).min(next[2]));
        let block = world.block(position);
        let mut nearest = if block == Block::Air {
            None
        } else if block.is_belt() {
            _cast_block(position, block, &start, traversal, segment_end)
                .filter(|hit| hit.distance >= distance - EPSILON)
        } else {
            Some(Hit {
                cell: position,
                normal,
                distance,
                position: _point(&start, traversal, distance),
            })
        };
        if let Some(below) = position.checked_offset(0, -1, 0) {
            let below_block = world.block(below);
            if below_block.is_slope()
                && let Some(lip) = _cast_block(below, below_block, &start, traversal, segment_end)
                && lip.distance >= distance - EPSILON
                && nearest.is_none_or(|hit| lip.distance < hit.distance)
            {
                nearest = Some(lip);
            }
        }
        if let Some(mut hit) = nearest {
            hit.distance += offset;
            return Some(hit);
        }
        let mut axis = 0;
        if next[1] < next[0] - 1e-12 {
            axis = 1;
        }
        if next[2] < next[axis] - 1e-12 {
            axis = 2;
        }
        distance = next[axis];
        cell[axis] += step[axis];
        normal = Cell::new(0, 0, 0);
        match axis {
            0 => normal.x = -step[axis],
            1 => normal.y = -step[axis],
            _ => normal.z = -step[axis],
        }
        next[axis] += increment[axis];
    }
    None
}

fn _coordinates(cell: Cell) -> [f64; 3] {
    [f64::from(cell.x), f64::from(cell.y), f64::from(cell.z)]
}

fn _point(origin: &[Coordinate; 3], ray: Ray, distance: f64) -> [f64; 3] {
    std::array::from_fn(|axis| origin[axis].add(ray.offset(axis, distance)).value)
}

fn _interval(
    low: [f64; 3],
    high: [f64; 3],
    origin: &[Coordinate; 3],
    ray: Ray,
    max_distance: f64,
    tie_tolerance: f64,
) -> Option<(f64, f64, Cell)> {
    let mut entry = 0.0;
    let mut exit = f64::INFINITY;
    let mut normal = [0; 3];
    for axis in 0..3 {
        if ray.vector[axis] == 0.0 {
            if origin[axis].below(low[axis]) || origin[axis].above(high[axis]) {
                return None;
            }
            continue;
        }
        let near = ray.crossing(&origin[axis], low[axis], axis);
        let far = ray.crossing(&origin[axis], high[axis], axis);
        if near.min(far) >= entry {
            entry = near.min(far);
            normal = [0; 3];
            normal[axis] = if ray.vector[axis] > 0.0 { -1 } else { 1 };
        }
        exit = exit.min(near.max(far));
        if entry > exit + tie_tolerance {
            return None;
        }
    }
    (entry <= max_distance).then_some((entry, exit, Cell::new(normal[0], normal[1], normal[2])))
}

fn _cast_block(
    cell: Cell,
    block: Block,
    origin: &[Coordinate; 3],
    ray: Ray,
    max_distance: f64,
) -> Option<Hit> {
    let low = _coordinates(cell).map(|value| value * CELL_SIZE);
    let mut high = low.map(|value| value + CELL_SIZE);
    high[1] = low[1] + BELT_HEIGHT;
    if !block.is_slope() {
        let (distance, _, normal) = _interval(low, high, origin, ray, max_distance, 0.0)?;
        return Some(Hit {
            cell,
            normal,
            distance,
            position: _point(origin, ray, distance),
        });
    }
    let elevation = |point: [f64; 3]| {
        block
            .slope_elevation(
                (point[0] - low[0]) / CELL_SIZE,
                (point[2] - low[2]) / CELL_SIZE,
            )
            .expect("slope block")
            * CELL_SIZE
    };
    let mut flat_origin = origin.clone();
    let mut flat_ray = ray;
    let base = block.slope_elevation(0.0, 0.0).expect("slope block");
    let gradient_x = block.slope_elevation(1.0, 0.0).expect("slope block") - base;
    let gradient_z = block.slope_elevation(0.0, 1.0).expect("slope block") - base;
    let displacement_x = origin[0].add(Coordinate::exact(-low[0]));
    let displacement_z = origin[2].add(Coordinate::exact(-low[2]));
    let slope = Coordinate::exact(base * CELL_SIZE)
        .add(displacement_x.multiply(gradient_x))
        .add(displacement_z.multiply(gradient_z));
    flat_origin[1] = flat_origin[1].add(slope.negate());
    flat_ray.vector[1] -= gradient_x * ray.vector[0] + gradient_z * ray.vector[2];
    let (flat_entry, _, flat_normal) =
        _interval(low, high, &flat_origin, flat_ray, max_distance, 0.0)?;
    high[1] += CELL_SIZE;
    let (outer_entry, _, outer_normal) = _interval(low, high, origin, ray, max_distance, 0.0)?;
    let distance = flat_entry.max(outer_entry);
    let point = _point(origin, ray, distance);
    let mut projected = point;
    projected[1] -= elevation(point);
    let mut flat_high = high;
    flat_high[1] -= CELL_SIZE;
    if !(0..3).all(|axis| {
        projected[axis] >= low[axis] - EPSILON
            && projected[axis] <= flat_high[axis] + EPSILON
            && point[axis] >= low[axis] - EPSILON
            && point[axis] <= high[axis] + EPSILON
    }) {
        return None;
    }
    Some(Hit {
        cell,
        normal: if flat_entry >= outer_entry {
            flat_normal
        } else {
            outer_normal
        },
        distance,
        position: point,
    })
}
