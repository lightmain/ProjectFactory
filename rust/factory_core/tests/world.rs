//! M02 world acceptance, independent of Godot and the bridge.
use factory_core::world::{Block, Bounds, Cell, World, chunk_cell, chunk_index};
use std::collections::BTreeMap;

#[test]
fn default_terrain_is_derived_and_bounds_are_half_open() {
    let world = World::flat(Bounds::default());
    assert_eq!(world.block_count(), 64 * 64 * 4);
    assert_eq!(world.allocated_block_bytes(), 0);
    for (height, block) in [
        (-4, Block::Bedrock),
        (-3, Block::Stone),
        (-2, Block::Dirt),
        (-1, Block::Grass),
        (0, Block::Air),
    ] {
        assert_eq!(world.block(Cell::new(-32, height, -32)), block);
    }
    assert!(world.contains(Cell::new(31, 59, 31)));
    for cell in [
        Cell::new(32, 0, 0),
        Cell::new(0, 60, 0),
        Cell::new(0, -5, 0),
        Cell::new(-33, -1, 0),
    ] {
        assert!(!world.contains(cell));
        assert_eq!(world.block(cell), Block::Air);
    }
}

#[test]
fn dimension_validation_rejects_overflow_and_preserves_the_old_range() {
    assert!(Bounds::new(Cell::new(-64, -1, -64), Cell::new(64, 64, 64), 1).is_ok());
    for (low, high, depth) in [
        (Cell::new(-64, -1, -64), Cell::new(65, 64, 64), 1),
        (Cell::new(0, -1, 0), Cell::new(0, 8, 8), 1),
        (Cell::new(0, -1, 0), Cell::new(8, 0, 8), 1),
        (Cell::new(0, -2, 0), Cell::new(8, 8, 8), 1),
        (Cell::new(-257, -1, 0), Cell::new(-200, 8, 8), 1),
        (Cell::new(i32::MIN, -1, 0), Cell::new(i32::MAX, 8, 8), 1),
        (Cell::new(0, -5, 0), Cell::new(8, 8, 8), 5),
    ] {
        assert!(Bounds::new(low, high, depth).is_err());
    }
}

#[test]
fn negative_world_coordinates_have_the_existing_relative_chunk_layout() {
    let origin = Cell::new(-32, -4, -32);
    for chunk in [
        Cell::new(0, 0, 0),
        Cell::new(1, 0, 0),
        Cell::new(0, 1, 1),
        Cell::new(1, 1, 1),
    ] {
        for index in 0..32768_u16 {
            let cell = chunk_cell(origin, chunk, index).unwrap();
            assert_eq!(chunk_index(origin, cell), (chunk, index));
        }
    }
    assert_eq!(
        chunk_index(origin, Cell::new(-1, 27, -1)),
        (Cell::new(0, 0, 0), 32767)
    );
}

#[test]
fn edit_rejections_are_atomic_and_reverted_chunks_retire() {
    let mut world = World::flat(Bounds::default());
    let count = world.block_count();
    let cell = Cell::new(-1, 0, -1);
    assert!(world.place(cell, Block::Stone).is_ok());
    assert!(world.place(cell, Block::Dirt).is_err());
    assert_eq!(world.block(cell), Block::Stone);
    assert_eq!(world.block_count(), count + 1);
    assert!(world.remove(cell).is_ok());
    assert!(world.remove(cell).is_err());
    assert!(world.remove(Cell::new(-1, -4, -1)).is_err());
    assert!(world.place(cell, Block::Bedrock).is_err());
    assert!(world.place(Cell::new(32, 0, 0), Block::Stone).is_err());
    assert_eq!(world.block_count(), count);
    assert_eq!(world.allocated_block_bytes(), 0);
    let grass = Cell::new(0, -1, 0);
    world.remove(grass).unwrap();
    world.place(grass, Block::Grass).unwrap();
    assert_eq!(world.allocated_block_bytes(), 0);
}

#[test]
fn each_floor_depth_keeps_the_current_bedrock_and_surface_rules() {
    for depth in 1_i32..=4 {
        let bounds = Bounds::new(Cell::new(-4, -depth, -4), Cell::new(4, 4, 4), depth).unwrap();
        let world = World::flat(bounds);
        assert_eq!(world.block_count(), (64 * depth) as usize);
        assert_eq!(world.block(Cell::new(0, -depth, 0)), Block::Bedrock);
        if depth > 1 {
            assert_eq!(world.block(Cell::new(0, -1, 0)), Block::Grass);
        }
        assert_eq!(world.allocated_block_bytes(), 0);
    }
}

#[test]
fn protruding_slopes_reject_upper_occupancy_and_the_world_ceiling() {
    let mut world = World::flat(Bounds::default());
    let slope = Cell::new(0, 0, 0);
    world.place(slope, Block::BeltUpEast).unwrap();
    let before = world.block_count();
    assert!(world.place(Cell::new(0, 1, 0), Block::Belt).is_err());
    assert!(world.place_structure(Cell::new(0, 1, 0), 0).is_err());
    assert!(
        world
            .place(Cell::new(2, 59, 0), Block::BeltDownEast)
            .is_err()
    );
    assert_eq!(world.block_count(), before);
    world.place(Cell::new(2, 59, 0), Block::Belt).unwrap();
}

#[test]
fn read_checkpoints_and_revisions_observe_whole_edits_only() {
    let mut world = World::flat(Bounds::default());
    let revision = world.revision();
    let id = world.place_structure(Cell::new(0, 0, 0), 2).unwrap();
    assert_eq!(world.revision(), revision + 1);
    let checkpoint = world.clone();
    assert!(world.place_structure(Cell::new(0, 0, 0), 1).is_err());
    assert_eq!(world.revision(), revision + 1);
    world.remove(Cell::new(1, 2, 1)).unwrap();
    assert_eq!(world.revision(), revision + 2);
    assert!(world.structure(id).is_none());
    assert_eq!(checkpoint.structure(id).unwrap().rotation, 2);
    for x in -1..=1 {
        for y in 0..3 {
            for z in -1..=1 {
                let cell = Cell::new(x, y, z);
                assert_eq!(world.block(cell), Block::Air);
                assert_eq!(checkpoint.block(cell), Block::Structure);
            }
        }
    }
}

#[test]
fn any_of_the_27_structure_parts_removes_the_whole_instance() {
    for x in -1..=1 {
        for y in 0..3 {
            for z in -1..=1 {
                let mut world = World::flat(Bounds::default());
                let baseline = world.block_count();
                let id = world.place_structure(Cell::new(0, 27, 0), 3).unwrap();
                assert_eq!(world.block_count(), baseline + 27);
                let part = Cell::new(x, 27 + y, z);
                let structure = world.structure_at(part).unwrap();
                assert_eq!(structure.id, id);
                assert_eq!(structure.rotation, 3);
                world.remove(part).unwrap();
                assert!(world.structure_at(part).is_none());
                assert_eq!(world.block_count(), baseline);
                assert_eq!(world.allocated_block_bytes(), 0);
            }
        }
    }
}

#[test]
fn failed_structure_transactions_leave_no_partial_occupancy() {
    let mut world = World::flat(Bounds::default());
    world.place(Cell::new(1, 2, 1), Block::Stone).unwrap();
    let before = world.block_count();
    for (anchor, rotation) in [
        (Cell::new(0, 0, 0), 0),
        (Cell::new(31, 0, 0), 0),
        (Cell::new(0, 58, 0), 0),
        (Cell::new(4, 0, 0), 4),
    ] {
        assert!(world.place_structure(anchor, rotation).is_err());
        assert_eq!(world.block_count(), before);
        assert!(world.structure_at(anchor).is_none());
    }
    assert_eq!(world.block(Cell::new(0, 0, 0)), Block::Air);
}

#[test]
fn removed_structure_identity_cannot_resolve_to_a_new_instance() {
    let mut world = World::flat(Bounds::default());
    let first = world.place_structure(Cell::new(0, 0, 0), 0).unwrap();
    let other = world.place_structure(Cell::new(3, 0, 0), 2).unwrap();
    world.remove(Cell::new(1, 2, 1)).unwrap();
    let replacement = world.place_structure(Cell::new(0, 0, 0), 1).unwrap();
    assert_ne!(first, replacement);
    assert!(world.structure(first).is_none());
    assert_eq!(world.structure(other).unwrap().rotation, 2);
    assert_eq!(world.structure(replacement).unwrap().rotation, 1);
}

#[test]
fn a_million_belts_use_at_most_the_bounded_dense_chunk_bytes() {
    let bounds = Bounds::new(Cell::new(-64, -1, -64), Cell::new(64, 64, 64), 1).unwrap();
    let mut world = World::flat(bounds);
    assert_eq!(world.allocated_block_bytes(), 0);
    for y in 0..64 {
        for z in -64..64 {
            for x in -64..64 {
                world.place(Cell::new(x, y, z), Block::Belt).unwrap();
            }
        }
    }
    assert_eq!(world.block_count(), 128 * 128 * 65);
    assert!(world.allocated_block_bytes() <= 64 * 32768);
    assert_eq!(world.block(Cell::new(63, 63, 63)), Block::Belt);
}

#[test]
fn chunk_deltas_restore_terrain_edits_and_structure_ownership() {
    let bounds = Bounds::new(Cell::new(-8, -4, -8), Cell::new(8, 12, 8), 4).unwrap();
    let mut original = World::flat(bounds);
    original.remove(Cell::new(-7, -1, -7)).unwrap();
    original.place(Cell::new(-7, 0, -7), Block::Miner).unwrap();
    let id = original.place_structure(Cell::new(0, 0, 0), 3).unwrap();
    let chunks = original.chunk_deltas();
    let rows = original.structure_rows();
    let mut restored = World::from_deltas(bounds, true, &chunks, &rows).unwrap();
    assert_eq!(restored.block_count(), original.block_count());
    assert!(restored.has_flat_baseline());
    for x in -8..8 {
        for y in -4..12 {
            for z in -8..8 {
                let cell = Cell::new(x, y, z);
                assert_eq!(restored.block(cell), original.block(cell));
                assert_eq!(restored.structure_at(cell), original.structure_at(cell));
            }
        }
    }
    assert_eq!(restored.chunk_deltas(), chunks);
    restored.remove(Cell::new(1, 2, 1)).unwrap();
    assert!(restored.structure(id).is_none());
    let new_id = restored.place_structure(Cell::new(0, 0, 0), 0).unwrap();
    assert_ne!(id, new_id);
}

fn delta(origin: Cell, cell: Cell, block: u8) -> (Cell, Vec<u8>) {
    let (chunk, index) = chunk_index(origin, cell);
    let [low, high] = index.to_le_bytes();
    (chunk, vec![low, high, block])
}

#[test]
fn malformed_delta_inputs_and_unowned_structure_parts_are_rejected() {
    let bounds = Bounds::default();
    let (chunk, record) = delta(bounds.minimum(), Cell::new(0, 0, 0), Block::Miner as u8);
    for bytes in [
        vec![],
        vec![0, 1],
        [record.clone(), record.clone()].concat(),
        vec![0, 128, Block::Miner as u8],
        vec![record[0], record[1], 255],
        vec![record[0], record[1], Block::Bedrock as u8],
        vec![record[0], record[1], Block::Structure as u8],
    ] {
        assert!(World::from_deltas(bounds, true, &BTreeMap::from([(chunk, bytes)]), &[]).is_err());
    }
    let (floor_chunk, floor_record) =
        delta(bounds.minimum(), Cell::new(0, -4, 0), Block::Air as u8);
    assert!(
        World::from_deltas(
            bounds,
            true,
            &BTreeMap::from([(floor_chunk, floor_record)]),
            &[]
        )
        .is_err()
    );
    assert!(
        World::from_deltas(
            bounds,
            true,
            &BTreeMap::from([(Cell::new(-1, 0, 0), record)]),
            &[]
        )
        .is_err()
    );
}

#[test]
fn explicit_empty_baseline_and_imported_slope_clearance_are_preserved() {
    let bounds = Bounds::default();
    let empty = World::from_deltas(bounds, false, &BTreeMap::new(), &[]).unwrap();
    assert_eq!(empty.block_count(), 0);
    assert_eq!(empty.allocated_block_bytes(), 0);
    assert!(!empty.has_flat_baseline());
    assert_eq!(empty.block(Cell::new(0, -4, 0)), Block::Air);
    let (chunk, lower) = delta(
        bounds.minimum(),
        Cell::new(0, 0, 0),
        Block::BeltUpEast as u8,
    );
    let (_, upper) = delta(bounds.minimum(), Cell::new(0, 1, 0), Block::Belt as u8);
    assert!(
        World::from_deltas(
            bounds,
            true,
            &BTreeMap::from([(chunk, [lower, upper].concat())]),
            &[]
        )
        .is_err()
    );
}

#[test]
fn bottom_centre_snapping_and_coordinate_conversion_reject_invalid_values() {
    use factory_core::entities::structure_anchor;
    assert_eq!(
        structure_anchor([0.25, 0.0, 0.25]).unwrap(),
        Cell::new(0, 0, 0)
    );
    assert_eq!(
        structure_anchor([0.0, 0.25, 0.0]).unwrap(),
        Cell::new(-1, 1, -1)
    );
    assert_eq!(
        structure_anchor([-0.25, -0.25, -0.25]).unwrap(),
        Cell::new(-1, -1, -1)
    );
    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, f64::MAX] {
        assert!(structure_anchor([bad, 0.0, 0.0]).is_err());
    }
    assert!(chunk_cell(Cell::new(0, 0, 0), Cell::new(0, 0, 0), 32768).is_err());
    assert!(chunk_cell(Cell::new(i32::MAX, 0, 0), Cell::new(1, 0, 0), 0).is_err());
}

#[test]
fn partial_chunks_and_structure_record_failures_never_change_the_source() {
    let bounds = Bounds::new(Cell::new(-4, -1, -4), Cell::new(4, 8, 4), 1).unwrap();
    let mut source = World::flat(bounds);
    source.place_structure(Cell::new(0, 0, 0), 2).unwrap();
    let chunks = source.chunk_deltas();
    let rows = source.structure_rows();
    let mut duplicate = rows.clone();
    duplicate.push(rows[0].clone());
    let mut bad_rotation = rows.clone();
    bad_rotation[0].rotation = 4;
    let mut missing = rows.clone();
    missing[0].anchor = Cell::new(0, 1, 0);
    let mut outside = rows.clone();
    outside[0].anchor = Cell::new(i32::MAX, 0, 0);
    for rejected in [duplicate, bad_rotation, missing, outside, vec![]] {
        assert!(World::from_deltas(bounds, true, &chunks, &rejected).is_err());
        assert_eq!(source.structure_rows(), rows);
        assert_eq!(source.chunk_deltas(), chunks);
        assert_eq!(source.block_count(), 64 + 27);
    }
    for cell in [Cell::new(4, 0, 0), Cell::new(0, 8, 0)] {
        let (chunk, record) = delta(bounds.minimum(), cell, Block::Miner as u8);
        assert!(World::from_deltas(bounds, true, &BTreeMap::from([(chunk, record)]), &[]).is_err());
    }
    let (chunk, low) = delta(bounds.minimum(), Cell::new(-3, 0, -3), Block::Miner as u8);
    let (_, high) = delta(bounds.minimum(), Cell::new(-3, 1, -3), Block::Chest as u8);
    assert!(
        World::from_deltas(
            bounds,
            true,
            &BTreeMap::from([(chunk, [high, low].concat())]),
            &[]
        )
        .is_err()
    );
}

#[test]
fn imported_empty_baseline_edits_and_redundant_records_are_canonical() {
    let bounds = Bounds::default();
    let (chunk, record) = delta(bounds.minimum(), Cell::new(0, -4, 0), Block::Miner as u8);
    let mut world =
        World::from_deltas(bounds, false, &BTreeMap::from([(chunk, record)]), &[]).unwrap();
    assert_eq!(world.block_count(), 1);
    assert_eq!(world.block(Cell::new(0, -4, 0)), Block::Miner);
    world.remove(Cell::new(0, -4, 0)).unwrap();
    assert_eq!(world.allocated_block_bytes(), 0);
    let (chunk, record) = delta(bounds.minimum(), Cell::new(0, -1, 0), Block::Grass as u8);
    let unchanged =
        World::from_deltas(bounds, true, &BTreeMap::from([(chunk, record)]), &[]).unwrap();
    assert!(unchanged.chunk_deltas().is_empty());
    assert_eq!(unchanged.block_count(), World::flat(bounds).block_count());
}

#[test]
fn thousands_of_structures_keep_exact_owners_across_chunks() {
    let bounds = Bounds::new(Cell::new(-64, -1, -64), Cell::new(64, 64, 64), 1).unwrap();
    let mut world = World::flat(bounds);
    let mut instances = Vec::new();
    for x in (-48..48).step_by(6) {
        for y in (0..64).step_by(4) {
            for z in (-48..48).step_by(6) {
                let anchor = Cell::new(x, y, z);
                let id = world.place_structure(anchor, 3).unwrap();
                instances.push((anchor, id));
            }
        }
    }
    assert_eq!(instances.len(), 4096);
    assert_eq!(world.structure_rows().len(), 4096);
    assert_eq!(world.block_count(), 128 * 128 + 4096 * 27);
    assert!(world.allocated_block_bytes() <= 64 * 32768);
    // Logical payload excludes tree nodes/capacity; process RSS is measured separately.
    let structure_bytes =
        instances.len() * std::mem::size_of::<factory_core::entities::Structure>();
    let owner_bytes =
        instances.len() * 27 * std::mem::size_of::<(Cell, factory_core::entities::EntityId)>();
    println!(
        "M02_STRUCTURE_DATA records={} owners={} structure_payload_bytes={} owner_payload_bytes={} block_page_bytes={}",
        instances.len(),
        instances.len() * 27,
        structure_bytes,
        owner_bytes,
        world.allocated_block_bytes()
    );
    for (anchor, id) in instances {
        for x in -1..=1 {
            for y in 0..3 {
                for z in -1..=1 {
                    let cell = anchor.checked_offset(x, y, z).unwrap();
                    assert_eq!(world.block(cell), Block::Structure);
                    assert_eq!(world.structure_at(cell).unwrap().id, id);
                }
            }
        }
    }
}

#[test]
fn all_slope_elevations_preserve_absolute_direction() {
    for (raw, expected) in (9..=16).zip([0.375, 0.875, 0.625, 0.125, 0.625, 0.125, 0.375, 0.875]) {
        let block = Block::try_from(raw).unwrap();
        assert_eq!(block.slope_elevation(0.125, 0.375), Some(expected));
    }
    assert_eq!(Block::Belt.slope_elevation(0.125, 0.375), None);
    assert_eq!(Block::BeltUp.slope_elevation(f64::NAN, 0.375), None);
}
