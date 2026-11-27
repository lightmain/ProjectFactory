//! Complete independent current-Godot observations, bound to an exact keyset.
use factory_core::{
    belt_placement::{self, Builder, Direction, Segment},
    queries::Hit,
    world::{Block, Bounds, Cell, World},
};
use std::collections::{BTreeMap, BTreeSet};

const DIRECTIONS: [Direction; 4] = [
    Direction::South,
    Direction::West,
    Direction::North,
    Direction::East,
];

fn reset(layout: usize) -> World {
    let mut world = World::flat(Bounds::default());
    match layout {
        1 => world.place(Cell::new(1, 0, 0), Block::Stone).unwrap(),
        2 => world.place(Cell::new(1, 0, 0), Block::BeltUpEast).unwrap(),
        3 => {
            world.place_structure(Cell::new(3, 0, 0), 0).unwrap();
        }
        _ => {}
    }
    world
}

fn selected(world: &World, cell: Cell) -> Cell {
    let cell = if belt_placement::is_machine(world.block(cell)) {
        cell
    } else {
        cell.checked_offset(0, -1, 0).unwrap()
    };
    belt_placement::target_cell(
        world,
        Hit {
            cell,
            normal: Cell::new(0, 1, 0),
            distance: 1.0,
            position: [0.0; 3],
        },
    )
    .unwrap()
}

fn rows(path: &[Segment]) -> String {
    if path.is_empty() {
        return "_".to_owned();
    }
    path.iter()
        .map(|row| {
            format!(
                "{},{},{},{},{}",
                row.cell.x, row.cell.y, row.cell.z, row.block as u8, row.direction as u8
            )
        })
        .collect::<Vec<_>>()
        .join(";")
}

fn record(expected: &mut BTreeMap<String, String>, label: String, build: &Builder) {
    let status = build
        .error()
        .map_or("ok".to_owned(), |error| format!("{error:?}"));
    assert!(
        expected
            .insert(
                label.clone(),
                format!(
                    "{label} {status} {} {} {}",
                    rows(build.path()),
                    rows(build.locked_path()),
                    u8::from(build.active())
                )
            )
            .is_none()
    );
}

#[test]
fn current_godot_plans_match_ports_slopes_locks_and_every_preview_segment() {
    let mut expected = BTreeMap::new();
    for layout in 0..4 {
        for start_y in 0..4 {
            for x in -3..=3 {
                for end_y in 0..4 {
                    for z in -3..=3 {
                        for north in [false, true] {
                            let world = reset(layout);
                            let directions = |cell| {
                                if belt_placement::is_machine(world.block(cell)) {
                                    Some(Direction::East)
                                } else {
                                    None
                                }
                            };
                            let mut build = Builder::new(1024).unwrap();
                            if build
                                .begin(
                                    &world,
                                    &directions,
                                    selected(&world, Cell::new(0, start_y, 0)),
                                    Direction::East,
                                )
                                .is_ok()
                            {
                                if !north {
                                    build.toggle_order();
                                }
                                let _ = build.preview(
                                    &world,
                                    &directions,
                                    Some(selected(&world, Cell::new(x, end_y, z))),
                                    Direction::East,
                                );
                            }
                            record(
                                &mut expected,
                                format!(
                                    "basic:{layout}:{start_y}:{x}:{end_y}:{z}:{}",
                                    u8::from(north)
                                ),
                                &build,
                            );
                        }
                    }
                }
            }
        }
    }
    for (direction, facing) in DIRECTIONS.into_iter().enumerate() {
        let world = reset(0);
        let none = |_| None;
        let delta = facing.cell();
        let cross = DIRECTIONS[(direction + 1) % 4].cell();
        let target = Cell::new(delta.x * 3, 0, delta.z * 3);
        let mut build = Builder::new(1024).unwrap();
        build
            .begin(&world, &none, Cell::new(0, 4, 0), facing)
            .unwrap();
        build.preview(&world, &none, Some(target), facing).unwrap();
        record(&mut expected, format!("locked:{direction}:0"), &build);
        build.lock(&world, &none).unwrap();
        record(&mut expected, format!("locked:{direction}:1"), &build);
        build
            .preview(&world, &none, Some(target), facing.opposite())
            .unwrap();
        record(&mut expected, format!("locked:{direction}:2"), &build);
        for stage in [3, 4] {
            if stage == 4 {
                build.toggle_order();
            }
            build
                .preview(
                    &world,
                    &none,
                    Some(Cell::new(
                        delta.x * 6 + cross.x * 2,
                        0,
                        delta.z * 6 + cross.z * 2,
                    )),
                    facing.opposite(),
                )
                .unwrap();
            record(&mut expected, format!("locked:{direction}:{stage}"), &build);
        }
        build.cancel();
        build
            .begin(&world, &none, Cell::new(0, 5, 0), facing)
            .unwrap();
        for (stage, (length, height)) in [(1, 3), (3, 1), (4, 0)].into_iter().enumerate() {
            build
                .preview(
                    &world,
                    &none,
                    Some(Cell::new(delta.x * length, height, delta.z * length)),
                    facing,
                )
                .unwrap();
            build.lock(&world, &none).unwrap();
            record(&mut expected, format!("repeat:{direction}:{stage}"), &build);
        }
    }
    for start_kind in 5..=7 {
        for end_kind in 5..=7 {
            for (start_dir, start_facing) in DIRECTIONS.into_iter().enumerate() {
                for (end_dir, end_facing) in DIRECTIONS.into_iter().enumerate() {
                    for north in [false, true] {
                        let mut world = reset(0);
                        let start = Cell::new(0, 0, 0);
                        let end = Cell::new(3, 0, 2);
                        world
                            .place(start, Block::try_from(start_kind).unwrap())
                            .unwrap();
                        world
                            .place(end, Block::try_from(end_kind).unwrap())
                            .unwrap();
                        let directions = |cell| {
                            if cell == start {
                                Some(start_facing)
                            } else if cell == end {
                                Some(end_facing)
                            } else {
                                None
                            }
                        };
                        let mut build = Builder::new(1024).unwrap();
                        if build
                            .begin(&world, &directions, start, Direction::East)
                            .is_ok()
                        {
                            if !north {
                                build.toggle_order();
                            }
                            let _ = build.preview(&world, &directions, Some(end), Direction::East);
                        }
                        record(
                            &mut expected,
                            format!(
                                "ports:{start_kind}:{end_kind}:{start_dir}:{end_dir}:{}",
                                u8::from(north)
                            ),
                            &build,
                        );
                    }
                }
            }
        }
    }
    let path = std::env::var("FACTORY_BELT_PLACEMENT_ORACLE").expect("fresh Godot plans required");
    let observations = std::fs::read_to_string(path).unwrap();
    let mut seen = BTreeSet::new();
    for line in observations.lines() {
        let key = line.split_whitespace().next().unwrap();
        assert!(seen.insert(key.to_owned()), "duplicate plan: {key}");
        assert_eq!(
            Some(line),
            expected.get(key).map(String::as_str),
            "plan: {key}"
        );
    }
    assert_eq!(
        seen,
        expected.into_keys().collect::<BTreeSet<_>>(),
        "missing plans"
    );
}
