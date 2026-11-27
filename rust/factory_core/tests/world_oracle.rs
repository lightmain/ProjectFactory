//! Read freshly generated Godot observations; require the oracle input explicitly.
use factory_core::{
    entities::structure_anchor,
    world::{Block, Bounds, Cell, World, blocks_intersect},
};
use std::collections::{BTreeMap, BTreeSet};

#[test]
fn current_godot_world_matches_rust_cell_by_cell_and_geometry() {
    let bounds = Bounds::new(Cell::new(-4, -4, -4), Cell::new(4, 8, 4), 4).unwrap();
    let flat = World::flat(bounds);
    let mut edited = flat.clone();
    edited.remove(Cell::new(-3, -1, -3)).unwrap();
    edited.place(Cell::new(-3, 0, -3), Block::Miner).unwrap();
    edited.place(Cell::new(3, 0, 3), Block::BeltUpEast).unwrap();
    edited.place_structure(Cell::new(0, 0, 0), 3).unwrap();
    let restored = World::from_deltas(
        bounds,
        true,
        &edited.chunk_deltas(),
        &edited.structure_rows(),
    )
    .unwrap();
    let mut removed = restored.clone();
    removed.remove(Cell::new(1, 2, 1)).unwrap();
    let worlds = BTreeMap::from([
        ("flat", flat),
        ("edited", edited),
        ("restored", restored),
        ("removed", removed),
    ]);
    let path = std::env::var("FACTORY_WORLD_ORACLE").expect("fresh Godot observations required");
    let observations = std::fs::read_to_string(path).unwrap();
    let mut counts = [0; 5];
    let mut seen = BTreeSet::new();
    for line in observations.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        let key = fields[..fields.len() - 1].join(" ");
        // World records also have a count, which is an observation, not identity.
        let key = if fields[0] == "world" {
            format!("world {}", fields[1])
        } else {
            key
        };
        assert!(seen.insert(key), "duplicate oracle observation: {line}");
        let number = |index: usize| fields[index].parse::<i32>().unwrap();
        match fields[0] {
            "world" => {
                assert_eq!(fields.len(), 5);
                let world = &worlds[fields[1]];
                assert_eq!(world.block_count(), fields[2].parse::<usize>().unwrap());
                let bytes = fields[3].as_bytes();
                let owners = fields[4].as_bytes();
                assert_eq!(bytes.len(), owners.len());
                let mut cursor = 0;
                for x in -4..4 {
                    for y in -4..8 {
                        for z in -4..4 {
                            let block = u8::from_str_radix(
                                std::str::from_utf8(&bytes[cursor..cursor + 2]).unwrap(),
                                16,
                            )
                            .unwrap();
                            assert_eq!(
                                world.block(Cell::new(x, y, z)) as u8,
                                block,
                                "{line}: {x},{y},{z}"
                            );
                            let presence = &owners[cursor..cursor + 2];
                            assert!(presence == b"00" || presence == b"01");
                            assert_eq!(
                                world.structure_at(Cell::new(x, y, z)).is_some(),
                                presence == b"01",
                                "owner presence {}: {x},{y},{z}",
                                fields[1]
                            );
                            cursor += 2;
                        }
                    }
                }
                assert_eq!(cursor, bytes.len());
                counts[0] += 1;
            }
            "owner" => {
                assert_eq!(fields.len(), 7);
                let owner = worlds[fields[1]]
                    .structure_at(Cell::new(number(2), number(3), number(4)))
                    .unwrap();
                assert_eq!(owner.id.value(), fields[5].parse::<u64>().unwrap());
                assert_eq!(i32::from(owner.rotation), number(6));
                counts[1] += 1;
            }
            "geometry" => {
                assert_eq!(fields.len(), 7);
                assert!([-3, 3].contains(&number(1)));
                assert!((9..=16).contains(&number(2)));
                assert!((1..=16).contains(&number(3)));
                assert!((-2..=2).contains(&number(4)));
                assert!((-1..=1).contains(&number(5)));
                assert!([0, 1].contains(&number(6)));
                let cell = Cell::new(-2, number(1), 2);
                let neighbor = cell.checked_offset(number(5), number(4), 0).unwrap();
                assert_eq!(
                    blocks_intersect(
                        cell,
                        Block::try_from(number(2) as u8).unwrap(),
                        neighbor,
                        Block::try_from(number(3) as u8).unwrap()
                    ),
                    number(6) == 1,
                    "{line}"
                );
                counts[2] += 1;
            }
            "anchor" => {
                assert_eq!(fields.len(), 7);
                assert!((1..=3).all(|axis| (-4..=4).contains(&number(axis))));
                assert_eq!(
                    structure_anchor([
                        f64::from(number(1)) * 0.125,
                        f64::from(number(2)) * 0.125,
                        f64::from(number(3)) * 0.125
                    ])
                    .unwrap(),
                    Cell::new(number(4), number(5), number(6)),
                    "{line}"
                );
                counts[3] += 1;
            }
            "elevation" => {
                assert_eq!(fields.len(), 5);
                assert!((9..=16).contains(&number(1)));
                assert!([(1, 3), (7, 1), (2, 6)].contains(&(number(2), number(3))));
                let actual = Block::try_from(number(1) as u8)
                    .unwrap()
                    .slope_elevation(f64::from(number(2)) / 8.0, f64::from(number(3)) / 8.0)
                    .unwrap();
                assert!(
                    (actual - fields[4].parse::<f64>().unwrap()).abs() < 1e-8,
                    "{line}"
                );
                counts[4] += 1;
            }
            _ => panic!("unexpected observation: {line}"),
        }
    }
    assert_eq!(counts, [4, 54, 3840, 729, 24]);
}
