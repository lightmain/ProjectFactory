//! Bind every observation to an independently constructed fixture and vertex.
use factory_core::{
    meshing::{self, MAX_MESH_BYTES, Mesh},
    world::{Block, Bounds, Cell, World},
};
use std::collections::{BTreeMap, BTreeSet};

fn empty() -> World {
    World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap()
}

fn fixtures() -> BTreeMap<(String, Cell), Mesh> {
    let mut output = BTreeMap::new();
    let mut record = |name: String, world: &World, key: Cell, direction: Cell| {
        let mesh = meshing::build(world, key, MAX_MESH_BYTES, &|_| Some(direction)).unwrap();
        assert!(output.insert((name, key), mesh).is_none());
    };
    let directions = [
        Cell::new(1, 0, 0),
        Cell::new(-1, 0, 0),
        Cell::new(0, 0, 1),
        Cell::new(0, 0, -1),
    ];
    for raw in [1, 2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16] {
        for (direction, facing) in directions.into_iter().enumerate() {
            for location in 0..2 {
                let cell = if location == 0 {
                    Cell::new(-1, 2, -1)
                } else {
                    Cell::new(2, 2, 2)
                };
                let mut world = empty();
                world.place(cell, Block::try_from(raw).unwrap()).unwrap();
                record(
                    format!("block_{raw}_{direction}_{location}"),
                    &world,
                    meshing::key_for(cell),
                    facing,
                );
            }
        }
    }
    for raw in [3, 6, 12] {
        let mut world = empty();
        world.place(Cell::new(7, 2, 2), Block::Stone).unwrap();
        world
            .place(Cell::new(8, 2, 2), Block::try_from(raw).unwrap())
            .unwrap();
        for key in [Cell::new(0, 0, 0), Cell::new(1, 0, 0)] {
            record(format!("neighbor_{raw}"), &world, key, directions[0]);
        }
    }
    for anchor in [1, 7] {
        let mut world = empty();
        world.place_structure(Cell::new(anchor, 2, 2), 3).unwrap();
        record(
            format!("structure_{anchor}"),
            &world,
            Cell::new(0, 0, 0),
            directions[0],
        );
        if anchor == 7 {
            record(
                format!("structure_{anchor}"),
                &world,
                Cell::new(1, 0, 0),
                directions[0],
            );
        }
    }
    let flat = World::flat(Bounds::default());
    record("flat".into(), &flat, Cell::new(-1, -1, -1), directions[0]);
    record("flat".into(), &flat, Cell::new(-4, -1, -4), directions[0]);
    output
}

#[test]
fn current_godot_surface_arrays_match_every_rust_triangle_attribute() {
    let fixtures = fixtures();
    assert_eq!(fixtures.len(), 123);
    let path =
        std::env::var("FACTORY_MESHING_ORACLE").expect("fresh Godot mesh observations required");
    let data = std::fs::read_to_string(path).unwrap();
    let mut meshes = BTreeSet::new();
    let mut vertices = BTreeSet::new();
    for line in data.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        assert!(fields.len() >= 6, "malformed observation: {line}");
        let key = (
            fields[1].to_string(),
            Cell::new(
                fields[2].parse().unwrap(),
                fields[3].parse().unwrap(),
                fields[4].parse().unwrap(),
            ),
        );
        let mesh = fixtures.get(&key).expect("unknown oracle fixture");
        match fields[0] {
            "mesh" => {
                assert_eq!(fields.len(), 6);
                assert_eq!(fields[5].parse::<usize>().unwrap(), mesh.indices.len());
                assert!(meshes.insert(key), "duplicate mesh header");
            }
            "vertex" => {
                assert_eq!(fields.len(), 22);
                let index: usize = fields[5].parse().unwrap();
                assert!(index < mesh.indices.len());
                let vertex = mesh.indices[index] as usize;
                let mut expected = Vec::with_capacity(16);
                expected.extend((0..3).map(|i| mesh.positions[vertex][i] + mesh.origin[i]));
                expected.extend(mesh.normals[vertex]);
                expected.extend(mesh.colors[vertex]);
                expected.extend(mesh.uv[vertex]);
                expected.extend(mesh.custom[vertex]);
                for (actual, expected) in fields[6..].iter().zip(expected) {
                    let actual: f32 = actual.parse().unwrap();
                    assert!(
                        actual.is_finite() && (actual - expected).abs() <= 2e-5,
                        "{line}: expected {expected}, observed {actual}"
                    );
                }
                assert!(vertices.insert((key, index)), "duplicate mesh vertex");
            }
            _ => panic!("unknown oracle record"),
        }
    }
    assert_eq!(
        meshes,
        fixtures.keys().cloned().collect(),
        "missing oracle meshes"
    );
    let expected: BTreeSet<_> = fixtures
        .iter()
        .flat_map(|(key, mesh)| (0..mesh.indices.len()).map(move |i| (key.clone(), i)))
        .collect();
    assert_eq!(vertices, expected, "missing oracle vertices");
}
