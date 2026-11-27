//! M07a CPU presentation acceptance; no engine resources or whole-world readback.
use factory_core::{
    meshing::{self, Error, MAX_MESH_BYTES, Mesh},
    world::{Block, Bounds, Cell, World},
};
use std::collections::BTreeMap;

fn empty() -> World {
    World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap()
}

fn mesh(world: &World, key: Cell) -> Mesh {
    meshing::build(world, key, MAX_MESH_BYTES, &|_| None).unwrap()
}

fn close(a: f32, b: f32) {
    assert!((a - b).abs() < 1e-6, "{a} != {b}");
}

#[test]
fn isolated_cube_has_complete_outward_surfaces_and_collision() {
    let mut world = empty();
    world.place(Cell::new(2, 2, 3), Block::Stone).unwrap();
    let m = mesh(&world, Cell::new(0, 0, 0));
    assert_eq!(m.positions.len(), 24);
    assert_eq!(m.indices.len(), 36);
    assert_eq!(m.collision.len(), 36);
    for array_len in [m.normals.len(), m.colors.len(), m.uv.len(), m.custom.len()] {
        assert_eq!(array_len, m.positions.len());
    }
    for (triangle, collision) in m
        .indices
        .as_chunks::<3>()
        .0
        .iter()
        .zip(m.collision.as_chunks::<3>().0)
    {
        let points = [
            m.positions[triangle[0] as usize],
            m.positions[triangle[1] as usize],
            m.positions[triangle[2] as usize],
        ];
        assert_eq!(points.as_slice(), collision);
        let a = std::array::from_fn::<_, 3, _>(|i| points[1][i] - points[0][i]);
        let b = std::array::from_fn::<_, 3, _>(|i| points[2][i] - points[0][i]);
        let cross = [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ];
        let n = m.normals[triangle[0] as usize];
        // Godot's front faces use clockwise winding.
        assert!(cross.iter().zip(n).map(|(a, b)| a * b).sum::<f32>() < 0.0);
    }
    assert_eq!(m.origin, [0.0; 3]);
    assert_eq!(m.world_revision, world.revision());
    assert_eq!(m.bounds_min, [1.0, 1.0, 1.5]);
    assert_eq!(m.bounds_max, [1.5, 1.5, 2.0]);
}

#[test]
fn shared_faces_and_neighbor_chunk_faces_are_culled() {
    let mut world = empty();
    world.place(Cell::new(6, 2, 2), Block::Stone).unwrap();
    world.place(Cell::new(7, 2, 2), Block::Dirt).unwrap();
    assert_eq!(mesh(&world, Cell::new(0, 0, 0)).indices.len(), 60);
    world.place(Cell::new(8, 2, 2), Block::Stone).unwrap();
    assert_eq!(mesh(&world, Cell::new(0, 0, 0)).indices.len(), 54);
    assert_eq!(mesh(&world, Cell::new(1, 0, 0)).indices.len(), 30);
    world.remove(Cell::new(8, 2, 2)).unwrap();
    assert_eq!(mesh(&world, Cell::new(0, 0, 0)).indices.len(), 60);
}

#[test]
fn negative_keys_use_local_geometry_and_world_decoration_centers() {
    let mut world = empty();
    let cell = Cell::new(-1, 2, -9);
    world.place(cell, Block::Stone).unwrap();
    assert_eq!(meshing::key_for(cell), Cell::new(-1, 0, -2));
    let m = mesh(&world, meshing::key_for(cell));
    assert_eq!(m.origin, [-4.0, 0.0, -8.0]);
    assert_eq!(m.bounds_min, [3.5, 1.0, 3.5]);
    assert_eq!(m.bounds_max, [4.0, 1.5, 4.0]);
    assert!(m.custom.iter().all(|v| *v == [-0.25, 1.25, -4.25, 0.0]));
    assert!(meshing::build(&world, Cell::new(i32::MAX, 0, 0), MAX_MESH_BYTES, &|_| None).is_err());
}

#[test]
fn thin_belts_do_not_hide_taller_neighbor_sides() {
    let mut world = empty();
    world.place(Cell::new(1, 2, 1), Block::Stone).unwrap();
    world.place(Cell::new(2, 2, 1), Block::Belt).unwrap();
    let m = mesh(&world, Cell::new(0, 0, 0));
    assert_eq!(m.indices.len(), 66);
    let belt = m.custom.iter().enumerate().filter(|(_, v)| v[0] == 1.25);
    for (i, _) in belt {
        assert!(m.positions[i][1] >= 1.0 && m.positions[i][1] <= 1.080001);
    }
}

#[test]
fn all_slopes_keep_vertical_ports_and_absolute_surface_height() {
    for raw in 9..=16 {
        let block = Block::try_from(raw).unwrap();
        let mut world = empty();
        let cell = Cell::new(2, 2, 2);
        world.place(cell, block).unwrap();
        let m = mesh(&world, Cell::new(0, 0, 0));
        assert_eq!(m.indices.len(), 36);
        for (i, p) in m.positions.iter().enumerate() {
            let rise = block
                .slope_elevation(f64::from(p[0] - 1.0) * 2.0, f64::from(p[2] - 1.0) * 2.0)
                .unwrap() as f32
                * 0.5;
            let base = p[1] - rise;
            assert!((base - 1.0).abs() < 1e-6 || (base - 1.08).abs() < 1e-6);
            close(m.normals[i].iter().map(|v| v * v).sum::<f32>(), 1.0);
        }
        close(m.bounds_min[1], 1.0);
        close(m.bounds_max[1], 1.58);
    }
}

#[test]
fn structure_occupancy_produces_only_its_outer_shell() {
    let mut world = empty();
    world.place_structure(Cell::new(1, 2, 1), 0).unwrap();
    let m = mesh(&world, Cell::new(0, 0, 0));
    assert_eq!(m.indices.len(), 6 * 9 * 6);
}

#[test]
fn machine_marks_follow_each_direction_and_miner_has_no_input_mark() {
    for direction in [
        Cell::new(1, 0, 0),
        Cell::new(-1, 0, 0),
        Cell::new(0, 0, 1),
        Cell::new(0, 0, -1),
    ] {
        for block in [Block::Miner, Block::Belt, Block::Chest] {
            let mut world = empty();
            world.place(Cell::new(2, 2, 2), block).unwrap();
            let m = meshing::build(&world, Cell::new(0, 0, 0), MAX_MESH_BYTES, &|_| {
                Some(direction)
            })
            .unwrap();
            let count = |mark: f32| m.custom.iter().filter(|v| v[3] == mark).count();
            assert_eq!(count(1.0), 4);
            assert_eq!(count(2.0), 4);
            assert_eq!(
                count(3.0),
                if block == Block::Miner {
                    0
                } else if block == Block::Belt {
                    12
                } else {
                    4
                }
            );
            assert!(m.uv.iter().flatten().all(|v| v.is_finite()));
        }
    }
}

#[test]
fn exact_payload_budget_is_atomic_and_world_remains_read_only() {
    let mut world = empty();
    world.place(Cell::new(2, 2, 2), Block::Stone).unwrap();
    let before = world.revision();
    let m = mesh(&world, Cell::new(0, 0, 0));
    assert_eq!(m.payload_bytes(), 6 * (4 * 64 + 6 * 4 + 6 * 12));
    assert_eq!(
        meshing::build(&world, Cell::new(0, 0, 0), m.payload_bytes() - 1, &|_| None),
        Err(Error::Budget)
    );
    assert_eq!(
        meshing::build(&world, Cell::new(0, 0, 0), m.payload_bytes(), &|_| None).unwrap(),
        m
    );
    assert!(meshing::build(&world, Cell::new(0, 0, 0), MAX_MESH_BYTES + 1, &|_| None).is_err());
    assert!(mesh(&world, Cell::new(3, 3, 3)).positions.is_empty());
    assert_eq!(world.revision(), before);
    assert_eq!(world.block(Cell::new(2, 2, 2)), Block::Stone);
}
