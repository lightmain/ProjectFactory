//! Bounded CPU geometry matching the existing voxel surfaces. No engine objects.
use crate::world::{Block, Cell, World};

pub const CHUNK_SIZE: i32 = 8;
pub const MAX_MESH_BYTES: usize = 2 * 1024 * 1024;
const FACE_BYTES: usize = 4 * 64 + 6 * 4 + 6 * 12;
const NORMALS: [Cell; 6] = [
    Cell::new(1, 0, 0),
    Cell::new(-1, 0, 0),
    Cell::new(0, 1, 0),
    Cell::new(0, -1, 0),
    Cell::new(0, 0, 1),
    Cell::new(0, 0, -1),
];
const TRIANGLE: [u32; 6] = [0, 1, 2, 0, 2, 3];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidKey,
    InvalidDirection,
    Budget,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Mesh {
    pub origin: [f32; 3],
    pub world_revision: u64,
    pub bounds_min: [f32; 3],
    pub bounds_max: [f32; 3],
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub colors: Vec<[f32; 4]>,
    pub uv: Vec<[f32; 2]>,
    pub custom: Vec<[f32; 4]>,
    pub indices: Vec<u32>,
    pub collision: Vec<[f32; 3]>,
}

impl Mesh {
    pub fn payload_bytes(&self) -> usize {
        self.positions.len() * 12
            + self.normals.len() * 12
            + self.colors.len() * 16
            + self.uv.len() * 8
            + self.custom.len() * 16
            + self.indices.len() * 4
            + self.collision.len() * 12
    }
}

pub fn key_for(cell: Cell) -> Cell {
    Cell::new(
        cell.x.div_euclid(CHUNK_SIZE),
        cell.y.div_euclid(CHUNK_SIZE),
        cell.z.div_euclid(CHUNK_SIZE),
    )
}

/// Preflight the complete payload before allocating; never return a partial mesh.
pub fn build(
    world: &World,
    key: Cell,
    budget: usize,
    direction: &impl Fn(Cell) -> Option<Cell>,
) -> Result<Mesh, Error> {
    if budget > MAX_MESH_BYTES {
        return Err(Error::Budget);
    }
    let start = Cell::new(
        key.x.checked_mul(CHUNK_SIZE).ok_or(Error::InvalidKey)?,
        key.y.checked_mul(CHUNK_SIZE).ok_or(Error::InvalidKey)?,
        key.z.checked_mul(CHUNK_SIZE).ok_or(Error::InvalidKey)?,
    );
    start
        .checked_offset(CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE)
        .ok_or(Error::InvalidKey)?;
    let cells = || {
        (0..CHUNK_SIZE).flat_map(move |x| {
            (0..CHUNK_SIZE).flat_map(move |y| {
                (0..CHUNK_SIZE).map(move |z| Cell::new(start.x + x, start.y + y, start.z + z))
            })
        })
    };
    let mut faces = 0;
    for cell in cells() {
        let block = world.block(cell);
        if block != Block::Air {
            faces += NORMALS
                .iter()
                .filter(|&&normal| !covered(world, cell, block, normal))
                .count();
        }
    }
    if faces * FACE_BYTES > budget {
        return Err(Error::Budget);
    }
    let origin = vector(start).map(|v| (v * 0.5) as f32);
    let mut mesh = Mesh {
        origin,
        world_revision: world.revision(),
        bounds_min: [0.0; 3],
        bounds_max: [0.0; 3],
        positions: Vec::with_capacity(faces * 4),
        normals: Vec::with_capacity(faces * 4),
        colors: Vec::with_capacity(faces * 4),
        uv: Vec::with_capacity(faces * 4),
        custom: Vec::with_capacity(faces * 4),
        indices: Vec::with_capacity(faces * 6),
        collision: Vec::with_capacity(faces * 6),
    };
    for cell in cells() {
        let block = world.block(cell);
        if block == Block::Air {
            continue;
        }
        let facing =
            if matches!(block, Block::Miner | Block::Belt | Block::Chest) || block.is_slope() {
                direction(cell)
            } else {
                None
            };
        if facing.is_some_and(|d| ![NORMALS[0], NORMALS[1], NORMALS[4], NORMALS[5]].contains(&d)) {
            return Err(Error::InvalidDirection);
        }
        for normal in NORMALS {
            if !covered(world, cell, block, normal) {
                add_face(&mut mesh, cell, start, block, normal, facing);
            }
        }
    }
    debug_assert_eq!(mesh.payload_bytes(), faces * FACE_BYTES);
    Ok(mesh)
}

fn height(block: Block) -> f64 {
    if block == Block::Belt {
        0.08
    } else if block.is_slope() {
        0.58
    } else {
        0.5
    }
}

fn covered(world: &World, cell: Cell, block: Block, normal: Cell) -> bool {
    let Some(neighbor_cell) = cell.checked_offset(normal.x, normal.y, normal.z) else {
        return false;
    };
    let neighbor = world.block(neighbor_cell);
    if neighbor == Block::Air || block.is_slope() || neighbor.is_slope() {
        return false;
    }
    let position = vector(cell).map(|v| v * 0.5);
    let other_position = vector(neighbor_cell).map(|v| v * 0.5);
    let size = [0.5, height(block), 0.5];
    let other_size = [0.5, height(neighbor), 0.5];
    let n = vector(normal);
    let axis = if normal.x != 0 {
        0
    } else if normal.y != 0 {
        1
    } else {
        2
    };
    let face = position[axis] + if n[axis] > 0.0 { size[axis] } else { 0.0 };
    let other_face = other_position[axis] + if n[axis] > 0.0 { 0.0 } else { other_size[axis] };
    if (face - other_face).abs() > 1e-5 * face.abs().max(1.0) {
        return false;
    }
    (0..3).filter(|&i| i != axis).all(|i| {
        other_position[i] <= position[i]
            && other_position[i] + other_size[i] >= position[i] + size[i]
    })
}

fn add_face(
    mesh: &mut Mesh,
    cell: Cell,
    start: Cell,
    block: Block,
    normal: Cell,
    facing: Option<Cell>,
) {
    // Slopes start with a thin belt slab, then elevate each corner.
    let size = [
        0.5,
        if block.is_slope() {
            0.08
        } else {
            height(block)
        },
        0.5,
    ];
    let cell_local = [
        f64::from(cell.x - start.x) * 0.5,
        f64::from(cell.y - start.y) * 0.5,
        f64::from(cell.z - start.z) * 0.5,
    ];
    let center = std::array::from_fn::<_, 3, _>(|i| cell_local[i] + size[i] * 0.5);
    let n = vector(normal);
    let up = [0.0, 1.0, 0.0];
    let mut u = cross(n, up);
    let mut v = up;
    if normal.y != 0 {
        u = [1.0, 0.0, 0.0];
        v = [0.0, 0.0, if normal.y > 0 { 1.0 } else { -1.0 }];
    }
    let face_center = std::array::from_fn::<_, 3, _>(|i| center[i] + n[i] * size[i] * 0.5);
    u = std::array::from_fn(|i| u[i] * size[i] * 0.5);
    v = std::array::from_fn(|i| v[i] * size[i] * 0.5);
    let mut corners = [[0.0; 3]; 4];
    for (i, (su, sv)) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
        .into_iter()
        .enumerate()
    {
        corners[i] = std::array::from_fn(|a| face_center[a] + su * u[a] + sv * v[a]);
        if block.is_slope() {
            corners[i][1] += elevation(block, corners[i], cell_local);
        }
    }
    let mut face_normal = n;
    if block.is_slope() && normal.y != 0 {
        let h = block.slope_elevation(0.0, 0.0).unwrap();
        face_normal = [
            -(block.slope_elevation(1.0, 0.0).unwrap() - h),
            1.0,
            -(block.slope_elevation(0.0, 1.0).unwrap() - h),
        ];
        let length = dot(face_normal, face_normal).sqrt();
        face_normal = face_normal.map(|v| v / length * f64::from(normal.y));
    }
    let mark = match facing {
        Some(_) if normal.y > 0 => 1,
        Some(d) if normal == d => 2,
        Some(d)
            if normal.y == 0
                && (block == Block::Belt
                    || (block != Block::Miner && normal == Cell::new(-d.x, -d.y, -d.z))) =>
        {
            3
        }
        _ => 0,
    };
    let forward = facing.map_or([0.0; 3], vector);
    let left = cross(up, forward);
    let port_width = cross(n, up);
    let port_height = 0.12_f64.min(size[1] * 0.6);
    let variation =
        0.94 + f64::from((cell.x * 31 + cell.y * 17 + cell.z * 13).rem_euclid(11)) * 0.01;
    let rgb = color(block, normal);
    let color = [
        (f64::from(rgb[0]) / 255.0 * variation) as f32,
        (f64::from(rgb[1]) / 255.0 * variation) as f32,
        (f64::from(rgb[2]) / 255.0 * variation) as f32,
        1.0,
    ];
    let cell_center = vector(cell).map(|v| (v * 0.5 + 0.25) as f32);
    let first = mesh.positions.len() as u32;
    for corner in corners {
        let mut offset = std::array::from_fn(|i| corner[i] - center[i]);
        let uv = if mark == 1 {
            [dot(offset, left), -dot(offset, forward)]
        } else if mark > 1 {
            if block.is_slope() {
                offset[1] -= elevation(block, corner, cell_local);
            }
            [dot(offset, port_width) / 0.16, offset[1] / port_height]
        } else {
            [0.0; 2]
        };
        let point = corner.map(|v| v as f32);
        if mesh.positions.is_empty() {
            mesh.bounds_min = point;
            mesh.bounds_max = point;
        } else {
            for (axis, coordinate) in point.into_iter().enumerate() {
                mesh.bounds_min[axis] = mesh.bounds_min[axis].min(coordinate);
                mesh.bounds_max[axis] = mesh.bounds_max[axis].max(coordinate);
            }
        }
        mesh.positions.push(point);
        mesh.normals.push(face_normal.map(|v| v as f32));
        mesh.colors.push(color);
        mesh.uv.push(uv.map(|v| v as f32));
        mesh.custom
            .push([cell_center[0], cell_center[1], cell_center[2], mark as f32]);
    }
    for index in TRIANGLE {
        mesh.indices.push(first + index);
        mesh.collision
            .push(mesh.positions[(first + index) as usize]);
    }
}

fn elevation(block: Block, corner: [f64; 3], cell: [f64; 3]) -> f64 {
    block
        .slope_elevation((corner[0] - cell[0]) * 2.0, (corner[2] - cell[2]) * 2.0)
        .unwrap()
        * 0.5
}

fn color(block: Block, normal: Cell) -> [u8; 3] {
    let top = normal.y > 0;
    let rgb = if block.is_slope() {
        if top { 0x444444 } else { 0x969696 }
    } else {
        match block {
            Block::Grass => {
                if top {
                    0x65965a
                } else {
                    0x80634a
                }
            }
            Block::Dirt => 0x997457,
            Block::Stone => 0x8d99a5,
            Block::Miner => {
                if top {
                    0xd69238
                } else {
                    0x9a652d
                }
            }
            Block::Belt => {
                if top {
                    0x344b58
                } else {
                    0x657b85
                }
            }
            Block::Chest => {
                if top {
                    0xb98a56
                } else {
                    0x805e40
                }
            }
            Block::Structure => {
                if top {
                    0xd4d4d4
                } else {
                    0x969696
                }
            }
            _ => 0x454e5b,
        }
    };
    [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8]
}

fn vector(cell: Cell) -> [f64; 3] {
    [f64::from(cell.x), f64::from(cell.y), f64::from(cell.z)]
}
fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    (0..3).map(|i| a[i] * b[i]).sum()
}
fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
