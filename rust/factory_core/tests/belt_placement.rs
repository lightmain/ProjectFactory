//! User-visible route sessions. Planning never mutates world or machine data.
use factory_core::{
    belt_placement::{Builder, Direction, Error},
    world::{Block, Bounds, Cell, World},
};
use std::collections::BTreeMap;

fn no_machine(_: Cell) -> Option<Direction> {
    None
}

fn builder() -> Builder {
    Builder::new(1024).unwrap()
}

#[test]
fn preview_lock_cancel_and_axis_order_are_reversible() {
    let world = World::flat(Bounds::default());
    let before = world.clone();
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 0, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 0)),
            Direction::East,
        )
        .unwrap();
    assert_eq!(
        build.path().iter().map(|row| row.cell).collect::<Vec<_>>(),
        (0..4).map(|x| Cell::new(x, 0, 0)).collect::<Vec<_>>()
    );
    build.lock(&world, &no_machine).unwrap();
    let prefix = build.path().to_vec();
    build.toggle_order();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(5, 0, 2)),
            Direction::North,
        )
        .unwrap();
    assert_eq!(&build.path()[..3], &prefix[..3]);
    assert_eq!(
        build.preview(&world, &no_machine, None, Direction::East),
        Err(Error::NoTarget)
    );
    assert!(build.active());
    assert_eq!(world.revision(), before.revision());
    assert_eq!(world.block(Cell::new(0, 0, 0)), Block::Air);
    build.cancel();
    assert!(!build.active());
    assert!(build.path().is_empty());
    assert!(build.north_south_first());
}

#[test]
fn all_four_directions_allow_the_empty_terminal_to_descend() {
    let world = World::flat(Bounds::default());
    for facing in [
        Direction::South,
        Direction::West,
        Direction::North,
        Direction::East,
    ] {
        let delta = facing.cell();
        let mut build = builder();
        build
            .begin(&world, &no_machine, Cell::new(0, 4, 0), facing)
            .unwrap();
        build
            .preview(
                &world,
                &no_machine,
                Some(Cell::new(delta.x * 3, 0, delta.z * 3)),
                facing,
            )
            .unwrap();
        for (index, row) in build.path().iter().enumerate() {
            assert_eq!(
                row.cell,
                Cell::new(
                    delta.x * index as i32,
                    3 - index as i32,
                    delta.z * index as i32
                )
            );
            assert_eq!(row.block as u8, 13 + facing as u8);
            assert_eq!(row.direction, facing);
        }
        build
            .begin(&world, &no_machine, Cell::new(0, 5, 0), facing)
            .unwrap();
        assert_eq!(
            build.preview(
                &world,
                &no_machine,
                Some(Cell::new(delta.x * 3, 0, delta.z * 3)),
                facing
            ),
            Err(Error::InsufficientRamps)
        );
    }
}

#[test]
fn locked_downhill_keeps_every_segment_and_continues_from_its_forward_outlet() {
    let world = World::flat(Bounds::default());
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 4, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 0)),
            Direction::East,
        )
        .unwrap();
    build.lock(&world, &no_machine).unwrap();
    let prefix = build.path().to_vec();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 0)),
            Direction::West,
        )
        .unwrap();
    assert_eq!(build.path(), prefix);
    for north in [true, false] {
        if build.north_south_first() != north {
            build.toggle_order();
        }
        build
            .preview(
                &world,
                &no_machine,
                Some(Cell::new(6, 0, 2)),
                Direction::West,
            )
            .unwrap();
        assert_eq!(&build.path()[..prefix.len()], prefix);
        assert_eq!(build.path()[prefix.len()].cell, Cell::new(4, 0, 0));
        assert_eq!(build.path()[prefix.len()].block, Block::Belt);
    }
}

#[test]
fn a_corner_after_locked_downhill_has_no_extra_ramp_capacity() {
    let world = World::flat(Bounds::default());
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 5, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(1, 3, 0)),
            Direction::East,
        )
        .unwrap();
    build.lock(&world, &no_machine).unwrap();
    assert_eq!(
        build.preview(
            &world,
            &no_machine,
            Some(Cell::new(2, 1, 1)),
            Direction::East
        ),
        Err(Error::InsufficientRamps)
    );
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(2, 1, 2)),
            Direction::East,
        )
        .unwrap();
    assert_eq!(build.path()[2].cell, Cell::new(2, 3, 0));
    assert_eq!(build.path()[2].block, Block::Belt);
    assert_eq!(build.path()[3].block, Block::BeltDown);
    assert_eq!(build.path()[4].block, Block::BeltDown);
}

#[test]
fn fixed_machine_ports_and_terminal_belt_directions_are_preserved() {
    let mut world = World::flat(Bounds::default());
    let start = Cell::new(0, 0, 0);
    let end = Cell::new(4, 0, 2);
    world.place(start, Block::Miner).unwrap();
    world.place(end, Block::Chest).unwrap();
    let machines = BTreeMap::from([(start, Direction::East), (end, Direction::South)]);
    let directions = |cell| machines.get(&cell).copied();
    let mut build = builder();
    build
        .begin(&world, &directions, start, Direction::North)
        .unwrap();
    assert_eq!(
        build.preview(&world, &directions, Some(end), Direction::North),
        Err(Error::StartPort)
    );
    build.toggle_order();
    build
        .preview(&world, &directions, Some(end), Direction::North)
        .unwrap();
    assert_eq!(build.path()[1].cell, Cell::new(1, 0, 0));
    assert_eq!(
        build.path()[build.path().len() - 2].cell,
        Cell::new(4, 0, 1)
    );
    assert_eq!(build.lock(&world, &directions), Err(Error::Occupied));
    build.validate(&world, &directions).unwrap();
    let changed = |cell| {
        if cell == end {
            Some(Direction::West)
        } else {
            directions(cell)
        }
    };
    assert_eq!(build.validate(&world, &changed), Err(Error::EndChanged));
    assert_eq!(machines[&start], Direction::East);
}

#[test]
fn crossing_existing_belts_slopes_and_structures_uses_their_whole_clearance() {
    let mut world = World::flat(Bounds::default());
    world.place(Cell::new(2, 0, 0), Block::Belt).unwrap();
    world.place(Cell::new(3, 0, 0), Block::BeltUpEast).unwrap();
    world.place_structure(Cell::new(0, 0, 8), 0).unwrap();
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 0, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(6, 0, 0)),
            Direction::East,
        )
        .unwrap();
    assert!(
        build
            .path()
            .iter()
            .any(|row| row.cell == Cell::new(3, 2, 0))
    );
    build
        .begin(&world, &no_machine, Cell::new(-6, 0, 8), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(6, 0, 8)),
            Direction::East,
        )
        .unwrap();
    assert!(
        build
            .path()
            .iter()
            .any(|row| row.cell == Cell::new(0, 3, 8))
    );
    assert_eq!(world.block(Cell::new(-6, 0, 8)), Block::Air);
}

#[test]
fn stale_world_edits_and_invalid_start_shapes_reject_without_losing_locks() {
    let mut world = World::flat(Bounds::default());
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 4, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 0)),
            Direction::East,
        )
        .unwrap();
    build.lock(&world, &no_machine).unwrap();
    let prefix = build.locked_path().to_vec();
    world.place(Cell::new(4, 0, 0), Block::Stone).unwrap();
    assert!(
        build
            .preview(
                &world,
                &no_machine,
                Some(Cell::new(6, 0, 0)),
                Direction::East
            )
            .is_err()
    );
    assert_eq!(build.locked_path(), prefix);
    assert!(build.validate(&world, &no_machine).is_err());
    world.remove(Cell::new(4, 0, 0)).unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(6, 0, 0)),
            Direction::East,
        )
        .unwrap();
    world.place(Cell::new(4, 0, 0), Block::Stone).unwrap();
    assert!(build.validate(&world, &no_machine).is_err());
    world.place(Cell::new(8, 0, 0), Block::BeltUp).unwrap();
    assert_eq!(
        build.begin(&world, &no_machine, Cell::new(8, 0, 0), Direction::South),
        Err(Error::Occupied)
    );
}

#[test]
fn complete_session_limit_is_checked_before_allocating_a_suffix() {
    assert!(matches!(Builder::new(0), Err(Error::InvalidLimit)));
    let world = World::flat(Bounds::default());
    let mut build = Builder::new(4).unwrap();
    build
        .begin(&world, &no_machine, Cell::new(0, 0, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 0)),
            Direction::East,
        )
        .unwrap();
    build.lock(&world, &no_machine).unwrap();
    let prefix = build.locked_path().to_vec();
    assert_eq!(
        build.preview(
            &world,
            &no_machine,
            Some(Cell::new(3, 0, 1)),
            Direction::South
        ),
        Err(Error::TooLong)
    );
    assert_eq!(build.locked_path(), prefix);
    assert_eq!(
        build.preview(
            &world,
            &no_machine,
            Some(Cell::new(i32::MAX, 0, i32::MIN)),
            Direction::East
        ),
        Err(Error::TooLong)
    );
    assert_eq!(world.revision(), 0);
}

#[test]
fn read_only_placement_check_matches_real_geometry_without_allocating_pages() {
    let mut world = World::flat(Bounds::default());
    let cell = Cell::new(0, 0, 0);
    assert_eq!(world.check_placement(cell, Block::BeltUpEast), Ok(()));
    assert_eq!(world.revision(), 0);
    assert_eq!(world.allocated_block_bytes(), 0);
    world.place(cell, Block::BeltUpEast).unwrap();
    let upper = Cell::new(0, 1, 0);
    assert_eq!(
        world.check_placement(upper, Block::Belt),
        Err(factory_core::world::Error::GeometryConflict)
    );
    assert_eq!(
        world.check_placement(upper, Block::Belt),
        world.place(upper, Block::Belt)
    );
}

#[test]
fn locking_a_stale_preview_rejects_and_preserves_the_previous_prefix() {
    let mut world = World::flat(Bounds::default());
    let mut build = builder();
    build
        .begin(&world, &no_machine, Cell::new(0, 0, 0), Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(6, 0, 0)),
            Direction::East,
        )
        .unwrap();
    let prefix = build.locked_path().to_vec();
    world.place(Cell::new(3, 0, 0), Block::Stone).unwrap();
    assert_eq!(build.lock(&world, &no_machine), Err(Error::Occupied));
    assert_eq!(build.locked_path(), prefix);
    assert_eq!(build.error(), Some(Error::Occupied));
    world.remove(Cell::new(3, 0, 0)).unwrap();
    build
        .preview(
            &world,
            &no_machine,
            Some(Cell::new(6, 0, 0)),
            Direction::East,
        )
        .unwrap();
    build.lock(&world, &no_machine).unwrap();
    assert_eq!(build.locked_path().len(), 7);
    build.cancel();
    let start = Cell::new(0, 0, 0);
    world.place(start, Block::Miner).unwrap();
    let directions = |_| Some(Direction::East);
    build
        .begin(&world, &directions, start, Direction::East)
        .unwrap();
    build
        .preview(
            &world,
            &directions,
            Some(Cell::new(6, 0, 0)),
            Direction::East,
        )
        .unwrap();
    let prefix = build.locked_path().to_vec();
    let changed = |_| Some(Direction::South);
    assert_eq!(
        build.lock(&world, &changed),
        Err(Error::StartDirectionChanged)
    );
    assert_eq!(build.locked_path(), prefix);
    assert_eq!(build.error(), Some(Error::StartDirectionChanged));
}
