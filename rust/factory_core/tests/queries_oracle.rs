//! Fresh, independent Godot ray results. Missing/duplicate samples fail closed.
use factory_core::{
    queries::cast,
    world::{Block, Bounds, Cell, World},
};
use std::collections::{BTreeMap, BTreeSet};

#[test]
fn current_godot_rays_match_cells_faces_distances_and_points() {
    let path = std::env::var("FACTORY_QUERIES_ORACLE").expect("fresh Godot rays required");
    let observations = std::fs::read_to_string(path).unwrap();
    let mut worlds = BTreeMap::new();
    for block in 1..=16 {
        if block == Block::Bedrock as u8 {
            continue;
        }
        let mut world =
            World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap();
        world
            .place(Cell::new(-2, 1, 2), Block::try_from(block).unwrap())
            .unwrap();
        worlds.insert(block.to_string(), world);
    }
    let flat = World::flat(Bounds::default());
    let mut edited = flat.clone();
    edited.remove(Cell::new(0, -1, 0)).unwrap();
    let mut slope = World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap();
    slope.place(Cell::new(0, 0, 0), Block::BeltUpEast).unwrap();
    let mut next = slope.clone();
    next.place(Cell::new(0, 0, 2), Block::Stone).unwrap();
    let mut stone = World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap();
    stone.place(Cell::new(-2, 0, 0), Block::Stone).unwrap();
    let mut corner = stone.clone();
    corner.place(Cell::new(0, 0, 0), Block::Stone).unwrap();
    let special = [
        "ground", "short", "zero", "tiny", "negative", "edit", "air", "lip", "next", "nonunit",
        "corner",
    ];
    for name in special {
        worlds.insert(
            name.to_owned(),
            match name {
                "edit" => edited.clone(),
                "air" | "lip" => slope.clone(),
                "next" => next.clone(),
                "nonunit" => stone.clone(),
                "corner" => corner.clone(),
                _ => flat.clone(),
            },
        );
    }
    let expected: BTreeSet<String> = (1..=16)
        .filter(|&block| block != Block::Bedrock as u8)
        .flat_map(|block| (0..270).map(move |index| format!("{block}:{index}")))
        .chain(special.into_iter().map(str::to_owned))
        .collect();
    let mut seen = BTreeSet::new();
    for line in observations.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        assert!(
            fields.len() == 9 || fields.len() == 18,
            "invalid ray record: {line}"
        );
        assert!(expected.contains(fields[0]), "unexpected sample: {line}");
        assert!(
            seen.insert(fields[0].to_owned()),
            "duplicate sample: {line}"
        );
        let expected_input = _input(fields[0]);
        for (index, value) in expected_input.into_iter().enumerate() {
            assert_eq!(
                fields[index + 1],
                format!("{value:.9}"),
                "oracle input: {line}"
            );
        }
        let number = |index: usize| fields[index].parse::<f64>().unwrap();
        let cell = |index: usize| {
            Cell::new(
                fields[index].parse().unwrap(),
                fields[index + 1].parse().unwrap(),
                fields[index + 2].parse().unwrap(),
            )
        };
        let origin = [number(1), number(2), number(3)];
        let ray = [number(4), number(5), number(6)];
        let world = &worlds[fields[0].split(':').next().unwrap()];
        let hit = cast(world, origin, ray, number(7));
        if fields.len() == 9 {
            assert_eq!(fields[8], "none");
            assert!(hit.is_none(), "{line}: {hit:?}");
        } else {
            let hit = hit.unwrap_or_else(|| panic!("missing ray hit: {line}"));
            assert_eq!(hit.cell, cell(8), "{line}");
            assert_eq!(hit.normal, cell(11), "{line}");
            assert!(
                (hit.distance - number(14)).abs() < 0.00001,
                "{line}: {hit:?}"
            );
            for axis in 0..3 {
                assert!(
                    (hit.position[axis] - number(15 + axis)).abs() < 0.00001,
                    "{line}: {hit:?}"
                );
            }
        }
    }
    assert_eq!(seen, expected, "missing oracle samples");
}

fn _input(label: &str) -> [f64; 7] {
    // Godot Vector3 inputs use f32; GDScript distance remains f64.
    let (origin, ray, distance) = if let Some((_, index)) = label.split_once(':') {
        let index = index.parse::<usize>().unwrap();
        let offsets = [-0.25, 0.125, 0.75];
        let rays = [
            [1.0, 0.0, 0.0],
            [-1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, -1.0, 0.0],
            [0.0, 0.0, 1.0],
            [0.0, 0.0, -1.0],
            [1.0, 1.0, 0.0],
            [-1.0, -1.0, 0.0],
            [1.13, -2.17, 3.31],
            [-2.23, 3.37, -0.97],
        ];
        (
            [
                -1.0 + offsets[index / 90],
                0.5 + offsets[index / 30 % 3],
                1.0 + offsets[index / 10 % 3],
            ],
            rays[index % 10],
            5.0,
        )
    } else {
        match label {
            "ground" => ([0.25, 2.0, 0.25], [0.0, -1.0, 0.0], 2.0),
            "short" => ([0.25, 2.0, 0.25], [0.0, -1.0, 0.0], 1.9),
            "zero" => ([0.0; 3], [0.0; 3], 5.0),
            "tiny" => ([0.0; 3], [1e-8; 3], 5.0),
            "negative" => ([0.0; 3], [0.0, -1.0, 0.0], -1.0),
            "edit" => ([0.25, 1.0, 0.25], [0.0, -1.0, 0.0], 5.0),
            "air" => ([0.4, 0.1, -0.2], [0.0, 0.0, 1.0], 1.0),
            "lip" => ([0.48, 0.55, -0.2], [0.0, 0.0, 1.0], 1.0),
            "next" => ([0.4, 0.1, -0.2], [0.0, 0.0, 1.0], 2.0),
            "nonunit" => ([0.0, 0.25, 0.25], [-4.0, 0.0, 0.0], 5.0),
            "corner" => ([-0.5, -0.5, 0.25], [1.0, 1.0, 0.0], 3.0),
            _ => panic!("unknown oracle input"),
        }
    };
    [
        origin[0] as f32 as f64,
        origin[1] as f32 as f64,
        origin[2] as f32 as f64,
        ray[0] as f32 as f64,
        ray[1] as f32 as f64,
        ray[2] as f32 as f64,
        distance,
    ]
}
