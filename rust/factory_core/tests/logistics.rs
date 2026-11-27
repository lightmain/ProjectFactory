//! Committed M04a state, rather than predicted display positions.
use factory_core::{
    belt_placement::Direction,
    logistics::{Factory, STEP, Settings},
    world::{Block, Bounds, Cell},
};

fn chain() -> Factory {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    );
    for (x, block) in [Block::Miner, Block::Belt, Block::Chest]
        .into_iter()
        .enumerate()
    {
        factory.place(Cell::new(x as i32, 0, 0), block).unwrap();
        factory
            .set_direction(Cell::new(x as i32, 0, 0), Direction::East)
            .unwrap();
    }
    factory
}

#[test]
fn three_devices_produce_and_settle_inventory_without_host_callbacks() {
    let mut factory = chain();
    for _ in 0..300 {
        factory.advance(STEP).unwrap();
    }
    let state = factory.observe();
    assert_eq!(state.tick, 300);
    assert_eq!(state.machines[0].cycles, 50);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        50
    );
    assert!(state.machines[2].quantity > 0);
    assert!(state.next_id > state.machines[2].quantity as u64);
    assert_eq!(state.machines[0].placed, 0.0);
}

#[test]
fn a_blocked_belt_keeps_its_items_and_resumes_when_the_chest_is_restored() {
    let mut factory = chain();
    factory.remove(Cell::new(2, 0, 0)).unwrap();
    for _ in 0..150 {
        factory.advance(STEP).unwrap();
    }
    let blocked = factory.observe();
    assert_eq!(blocked.machines[1].quantity, 2);
    assert!(blocked.machines[0].quantity > 0);
    let ids: Vec<_> = blocked.machines[1].ores.iter().map(|ore| ore.id).collect();
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1]);
    factory.place(Cell::new(2, 0, 0), Block::Chest).unwrap();
    factory
        .set_direction(Cell::new(2, 0, 0), Direction::East)
        .unwrap();
    factory.advance(STEP).unwrap();
    assert!(factory.observe().machines[2].quantity > 0);
    assert_eq!(factory.observe().machines[1].ores[0].id, ids[1]);
}

#[test]
fn miners_placed_between_ticks_keep_their_own_production_phase() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    );
    factory.advance(0.003).unwrap();
    factory.place(Cell::new(0, 0, 0), Block::Miner).unwrap();
    factory.advance(0.097).unwrap();
    let before = factory.observe();
    assert_eq!(before.tick, 6);
    assert_eq!(before.machines[0].quantity, 0);
    assert_eq!(before.machines[0].placed, 0.003);
    factory.advance(STEP).unwrap();
    assert_eq!(factory.observe().machines[0].quantity, 1);
}

#[test]
fn boundary_edit_flush_does_not_produce_or_output_twice_in_the_same_tick() {
    let mut factory = chain();
    for _ in 0..60 {
        factory.advance(STEP).unwrap();
    }
    let before = factory.observe();
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::North)
        .unwrap();
    factory.advance(1e-10).unwrap();
    let first = factory.observe();
    assert_eq!(first.tick, before.tick);
    assert_eq!(first.flushed, first.tick);
    assert_eq!(first.machines[0].cycles, before.machines[0].cycles);
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::East)
        .unwrap();
    factory.advance(1e-10).unwrap();
    let second = factory.observe();
    assert!(second.dirty);
    assert_eq!(second.machines[1].settled, Direction::North);
    assert_eq!(second.machines[0].cycles, first.machines[0].cycles);
    assert_eq!(second.next_id, first.next_id);
}

#[test]
fn invalid_time_failed_placement_and_fixed_slope_rotation_preserve_state() {
    let mut factory = chain();
    for _ in 0..60 {
        factory.advance(STEP).unwrap();
    }
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::North)
        .unwrap();
    let before = factory.observe();
    for invalid in [f64::NAN, f64::INFINITY, -1.0] {
        assert!(factory.advance(invalid).is_err());
        assert_eq!(factory.observe(), before);
    }
    assert!(factory.place(Cell::new(1, 0, 0), Block::Stone).is_err());
    assert_eq!(factory.observe(), before);
    assert_eq!(factory.world().block(Cell::new(1, 0, 0)), Block::Belt);
    let cell = Cell::new(5, 0, 0);
    factory.place(cell, Block::BeltUpEast).unwrap();
    let slope = factory.observe();
    assert!(factory.set_direction(cell, Direction::North).is_err());
    assert_eq!(factory.observe(), slope);
}

#[test]
fn independent_checkpoints_resume_with_the_same_items_phase_and_pending_edges() {
    let mut factory = chain();
    for _ in 0..59 {
        factory.advance(STEP).unwrap();
    }
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::North)
        .unwrap();
    let mut restored = Factory::from_checkpoint(factory.checkpoint());
    assert_eq!(factory.observe(), restored.observe());
    let original = factory.observe();
    restored.advance(STEP).unwrap();
    assert_eq!(factory.observe(), original);
    factory.advance(STEP).unwrap();
    assert_eq!(factory.observe(), restored.observe());
    for _ in 0..120 {
        factory.advance(STEP).unwrap();
        restored.advance(STEP).unwrap();
        assert_eq!(factory.observe(), restored.observe());
    }
    restored.remove(Cell::new(1, 0, 0)).unwrap();
    assert_eq!(factory.world().block(Cell::new(1, 0, 0)), Block::Belt);
    assert_eq!(restored.world().block(Cell::new(1, 0, 0)), Block::Air);
}

#[test]
fn an_empty_replacement_cannot_take_a_second_output_at_the_same_boundary() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 3,
        },
    );
    for (x, block) in [Block::Miner, Block::Belt].into_iter().enumerate() {
        let at = Cell::new(x as i32, 0, 0);
        factory.place(at, block).unwrap();
        factory.set_direction(at, Direction::East).unwrap();
    }
    factory.advance(0.1).unwrap();
    let settled = factory.observe();
    assert_eq!(settled.machines[0].quantity, 2);
    assert_eq!(settled.machines[0].last_output, 6);
    factory.remove(Cell::new(1, 0, 0)).unwrap();
    factory.place(Cell::new(1, 0, 0), Block::Belt).unwrap();
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::East)
        .unwrap();
    factory.advance(0.0).unwrap();
    assert_eq!(factory.observe().flushed, settled.flushed);
    factory.advance(1e-10).unwrap();
    let flushed = factory.observe();
    assert_eq!(flushed.machines[0].quantity, 2);
    assert_eq!(flushed.machines[0].cycles, 1);
    assert!(flushed.machines[1].ores.is_empty());
    assert_eq!(flushed.next_id, settled.next_id);
    factory
        .set_direction(Cell::new(1, 0, 0), Direction::North)
        .unwrap();
    let mut checkpoint = Factory::from_checkpoint(factory.checkpoint());
    assert_eq!(checkpoint.observe(), factory.observe());
    checkpoint
        .set_direction(Cell::new(1, 0, 0), Direction::West)
        .unwrap();
    assert_eq!(factory.observe().machines[1].direction, Direction::North);
}

#[test]
fn newly_arrived_inventory_is_ineligible_for_a_supplemental_flush() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    );
    for (x, block) in [Block::Miner, Block::Chest].into_iter().enumerate() {
        let at = Cell::new(x as i32, 0, 0);
        factory.place(at, block).unwrap();
        factory.set_direction(at, Direction::East).unwrap();
    }
    factory.advance(0.1).unwrap();
    assert_eq!(factory.observe().machines[1].quantity, 1);
    assert_eq!(factory.observe().machines[1].eligible, 0);
    factory.place(Cell::new(2, 0, 0), Block::Belt).unwrap();
    factory
        .set_direction(Cell::new(2, 0, 0), Direction::East)
        .unwrap();
    factory.advance(1e-10).unwrap();
    assert_eq!(factory.observe().machines[1].quantity, 1);
    assert!(factory.observe().machines[2].ores.is_empty());
    factory.advance(STEP).unwrap();
    assert_eq!(factory.observe().machines[1].quantity, 0);
    assert_eq!(factory.observe().machines[2].quantity, 1);
}
