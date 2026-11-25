use factory_world_probe::{Bounds, Cell, ViewCursor, World, WorldError, fixture_kind};

#[path = "../src/audit.rs"]
mod audit;

#[test]
fn every_packet_matches_a_flat_reference_and_detects_missed_edits() {
    let size = Cell {
        x: 64,
        y: 32,
        z: 64,
    };
    let mut world = World::generate(size, 20_261_125).unwrap();
    let mut reference = audit::Reference::new(size, 20_261_125);
    reference.check_world(&world).unwrap();
    let mut cache = audit::Cache::default();
    let mut cursor = ViewCursor::new(&world);
    let mut packet = Vec::new();
    let bounds = Bounds {
        minimum: [0, 0, 0],
        maximum: [32, 16, 32],
    };
    world.update_view(bounds, &mut cursor, &mut packet).unwrap();
    cache.apply(&packet, bounds, &reference).unwrap();
    world.update_view(bounds, &mut cursor, &mut packet).unwrap();
    let stale = packet.clone();
    let cell = Cell { x: 17, y: 3, z: 17 };
    reference.edit(cell, 0);
    world.set_block(cell, 0).unwrap();
    assert!(cache.apply(&stale, bounds, &reference).is_err());
    world.update_view(bounds, &mut cursor, &mut packet).unwrap();
    cache.apply(&packet, bounds, &reference).unwrap();
    let mut corrupt = packet.clone();
    corrupt[80] = 5;
    assert!(cache.apply(&corrupt, bounds, &reference).is_err());
    for x in [1, 16, 32, 16, 0] {
        let moved = Bounds {
            minimum: [x, 0, 0],
            maximum: [x + 32, 16, 32],
        };
        world.update_view(moved, &mut cursor, &mut packet).unwrap();
        cache.apply(&packet, moved, &reference).unwrap();
    }
    reference.check_world(&world).unwrap();
}

fn small_size() -> Cell {
    Cell {
        x: 32,
        y: 16,
        z: 32,
    }
}

#[test]
fn fixture_mixer_has_fixed_known_values() {
    for (cell, expected) in [
        (Cell { x: 0, y: 0, z: 0 }, 3),
        (Cell { x: 1, y: 0, z: 0 }, 2),
        (Cell { x: 16, y: 0, z: 31 }, 3),
        (
            Cell {
                x: 31,
                y: 15,
                z: 31,
            },
            4,
        ),
    ] {
        assert_eq!(fixture_kind(cell, 20_261_125), expected);
    }
}

#[test]
fn views_are_local_incremental_and_observers_are_independent() {
    let mut world = World::generate(
        Cell {
            x: 64,
            y: 32,
            z: 64,
        },
        20_261_125,
    )
    .unwrap();
    let bounds = Bounds {
        minimum: [0, 0, 0],
        maximum: [32, 16, 32],
    };
    let mut first = ViewCursor::new(&world);
    let mut second = ViewCursor::new(&world);
    let mut output = Vec::new();
    let initial = world.update_view(bounds, &mut first, &mut output).unwrap();
    assert_eq!(
        (
            initial.entered,
            initial.updated,
            initial.left,
            initial.visited_chunks
        ),
        (4, 0, 0, 4)
    );
    assert_eq!(initial.read_cells, 16_384);
    assert_eq!(initial.output_bytes, 76 + 4 * (4 + 8192));
    let unchanged = world.update_view(bounds, &mut first, &mut output).unwrap();
    assert_eq!((unchanged.read_cells, unchanged.output_bytes), (0, 76));
    world.set_block(Cell { x: 0, y: 0, z: 0 }, 0).unwrap();
    let refreshed = world.update_view(bounds, &mut first, &mut output).unwrap();
    assert_eq!((refreshed.entered, refreshed.updated), (0, 1));
    let other = world.update_view(bounds, &mut second, &mut output).unwrap();
    assert_eq!(other.entered, 4);
    world
        .set_block(
            Cell {
                x: 63,
                y: 31,
                z: 63,
            },
            0,
        )
        .unwrap();
    assert_eq!(
        world
            .update_view(bounds, &mut first, &mut output)
            .unwrap()
            .read_cells,
        0
    );
    let moved = world
        .update_view(
            Bounds {
                minimum: [16, 0, 0],
                maximum: [48, 16, 32],
            },
            &mut first,
            &mut output,
        )
        .unwrap();
    assert_eq!(
        (
            moved.entered,
            moved.updated,
            moved.left,
            moved.visited_chunks
        ),
        (2, 0, 2, 4)
    );
}

#[test]
fn bounds_are_half_open_clipped_and_bound_to_a_world_instance() {
    let world = World::new(small_size()).unwrap();
    let mut cursor = ViewCursor::new(&world);
    let mut output = vec![99];
    let invalid = Bounds {
        minimum: [1, 0, 0],
        maximum: [0, 16, 16],
    };
    assert!(
        world
            .update_view(invalid, &mut cursor, &mut output)
            .is_err()
    );
    assert_eq!(output, [99]);
    let clipped = Bounds {
        minimum: [-9, -9, -9],
        maximum: [16, 16, 16],
    };
    assert_eq!(
        world
            .update_view(clipped, &mut cursor, &mut output)
            .unwrap()
            .entered,
        1
    );
    let empty = Bounds {
        minimum: [32, 0, 0],
        maximum: [40, 16, 16],
    };
    let report = world.update_view(empty, &mut cursor, &mut output).unwrap();
    assert_eq!((report.left, report.visited_chunks), (1, 0));
    let zero = Bounds {
        minimum: [1, 0, 0],
        maximum: [1, 16, 16],
    };
    assert_eq!(
        world
            .update_view(zero, &mut cursor, &mut output)
            .unwrap()
            .visited_chunks,
        0
    );
    let other = World::new(small_size()).unwrap();
    assert!(matches!(
        other.update_view(clipped, &mut cursor, &mut output),
        Err(WorldError::WrongWorld)
    ));
    let world = Box::new(world);
    assert_eq!(
        world
            .update_view(clipped, &mut cursor, &mut output)
            .unwrap()
            .entered,
        1
    );
}

#[test]
fn snapshot_round_trip_preserves_cells_counts_and_revision() {
    let mut world = World::generate(small_size(), 20_261_125).unwrap();
    world
        .set_block(
            Cell {
                x: 31,
                y: 15,
                z: 31,
            },
            0,
        )
        .unwrap();
    let mut bytes = Vec::new();
    world.save(&mut bytes).unwrap();
    assert_eq!(bytes.len(), 36 + world.stats().block_bytes);
    let loaded = World::load(bytes.as_slice()).unwrap();
    assert_eq!(loaded.stats(), world.stats());
    for y in 0..16 {
        for z in 0..32 {
            for x in 0..32 {
                let cell = Cell { x, y, z };
                assert_eq!(
                    loaded.get_block(cell).unwrap(),
                    world.get_block(cell).unwrap()
                );
            }
        }
    }
}

#[test]
fn snapshot_rejects_bad_headers_payload_and_lengths() {
    let world = World::new(small_size()).unwrap();
    let mut bytes = Vec::new();
    world.save(&mut bytes).unwrap();
    for (offset, value) in [(0, 0), (8, 2), (12, 17), (32, 5), (36, 5)] {
        let mut corrupt = bytes.clone();
        corrupt[offset] = value;
        assert!(World::load(corrupt.as_slice()).is_err(), "offset {offset}");
    }
    for length in [0, 35, 36, bytes.len() - 1] {
        assert!(World::load(&bytes[..length]).is_err());
    }
    bytes.push(0);
    assert!(World::load(bytes.as_slice()).is_err());
}

#[test]
fn empty_world_has_exact_population_and_rejects_invalid_dimensions() {
    let world = World::new(small_size()).unwrap();
    assert_eq!(world.stats().counts, [16_384, 0, 0, 0, 0]);
    assert_eq!(world.stats().chunk_count, 4);
    assert_eq!(world.stats().block_bytes, 32_768);
    for size in [
        Cell { x: 0, y: 16, z: 16 },
        Cell {
            x: 17,
            y: 16,
            z: 16,
        },
        Cell {
            x: 144,
            y: 16,
            z: 16,
        },
    ] {
        assert!(matches!(
            World::new(size),
            Err(WorldError::InvalidDimensions)
        ));
    }
}

#[test]
fn edits_preserve_counts_on_no_op_and_rejection() {
    let mut world = World::new(small_size()).unwrap();
    let cell = Cell { x: 16, y: 0, z: 31 };
    assert!(world.set_block(cell, 2).unwrap());
    assert_eq!(world.get_block(cell).unwrap(), 2);
    assert_eq!(world.stats().counts, [16_383, 0, 1, 0, 0]);
    let stats = world.stats();
    assert!(!world.set_block(cell, 2).unwrap());
    assert!(world.set_block(cell, 5).is_err());
    assert!(world.set_block(Cell { x: 32, ..cell }, 1).is_err());
    assert_eq!(world.stats(), stats);
    assert!(world.set_block(cell, 4).unwrap());
    assert!(world.set_block(cell, 0).unwrap());
    assert_eq!(world.stats().counts, [16_384, 0, 0, 0, 0]);
    assert_eq!(world.stats().revision, 3);
}

#[test]
fn generated_world_stores_every_cell_and_edits_match_a_flat_reference() {
    let size = small_size();
    let mut world = World::generate(size, 20_261_125).unwrap();
    let mut reference = Vec::new();
    let mut counts = [0_u64; 5];
    for y in 0..size.y {
        for z in 0..size.z {
            for x in 0..size.x {
                let cell = Cell { x, y, z };
                let kind = fixture_kind(cell, 20_261_125);
                assert_eq!(world.get_block(cell).unwrap(), kind);
                reference.push(kind);
                counts[kind as usize] += 1;
            }
        }
    }
    assert_eq!(world.stats().counts, counts);
    assert_eq!(world.stats().non_empty, 16_384);
    assert!(counts[1..].iter().all(|&count| count > 0));
    for ordinal in 0..1_000_u32 {
        let index = ordinal as usize * 13 % reference.len();
        let cell = Cell {
            x: index as u32 % size.x,
            z: index as u32 / size.x % size.z,
            y: index as u32 / (size.x * size.z),
        };
        let kind = (ordinal % 5) as u16;
        counts[reference[index] as usize] -= 1;
        reference[index] = kind;
        counts[kind as usize] += 1;
        world.set_block(cell, kind).unwrap();
    }
    assert_eq!(world.stats().counts, counts);
    for (index, expected) in reference.into_iter().enumerate() {
        let cell = Cell {
            x: index as u32 % size.x,
            z: index as u32 / size.x % size.z,
            y: index as u32 / (size.x * size.z),
        };
        assert_eq!(world.get_block(cell).unwrap(), expected);
    }
}
