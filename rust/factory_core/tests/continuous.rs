use factory_core::{
    belt_placement::Direction,
    logistics::{STEP, Settings, continuous::Factory},
    world::{Block, Bounds, Cell},
};

fn chain(count: i32) -> Factory {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 2,
        },
    )
    .unwrap();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    for x in 0..count {
        factory
            .place(Cell::new(x, 0, 0), Block::Belt, Direction::East)
            .unwrap();
    }
    factory
        .place(Cell::new(count, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory
}

#[test]
fn continuous_long_chain_owns_production_and_inventory_and_compresses_transport() {
    let mut factory = chain(20);
    for _ in 0..900 {
        factory.advance(STEP).unwrap();
    }
    let state = factory.observe().unwrap();
    assert_eq!(state.tick, 900);
    assert_eq!(factory.work().segments, 1);
    assert!(state.machines.last().unwrap().quantity > 0);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        300
    );
    assert_eq!(factory.ledger().produced, 300);
    assert_eq!(factory.ledger().removed, 0);
    assert!(factory.ledger().retired > 0);
    assert_eq!(state.next_id, factory.last_identity() + 1);
}

#[test]
fn blocked_transport_resumes_after_atomic_chest_replacement() {
    let mut factory = chain(2);
    factory.remove(Cell::new(2, 0, 0)).unwrap();
    for _ in 0..240 {
        factory.advance(STEP).unwrap();
    }
    let before = factory.observe().unwrap();
    assert!(before.machines[0].quantity > 0);
    let total: i64 = before.machines.iter().map(|row| row.quantity).sum();
    factory
        .place(Cell::new(2, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    for _ in 0..120 {
        factory.advance(STEP).unwrap();
    }
    let state = factory.observe().unwrap();
    assert!(state.machines.last().unwrap().quantity > 0);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        total + 40
    );
}

#[test]
fn slope_geometry_and_continuous_checkpoint_preserve_phase_items_and_retired_ids() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    )
    .unwrap();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(0, 0, 0), Block::BeltUpEast, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(1, 1, 0), Block::Belt, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(2, 1, 0), Block::Chest, Direction::East)
        .unwrap();
    assert!((factory.segment_lengths()[0] - (0.5_f64.sqrt() + 0.5)).abs() < 1e-12);
    factory.advance(1.003).unwrap();
    let mut restored = Factory::from_checkpoint(factory.checkpoint().unwrap()).unwrap();
    for _ in 0..240 {
        factory.advance(STEP).unwrap();
        restored.advance(STEP).unwrap();
        assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
        assert_eq!(factory.ledger(), restored.ledger());
    }
    let before = factory.observe().unwrap();
    assert!(
        restored
            .place(Cell::new(1, 1, 0), Block::Belt, Direction::East)
            .is_err()
    );
    assert_eq!(restored.observe().unwrap(), before);
    restored.remove(Cell::new(1, 1, 0)).unwrap();
    assert_eq!(factory.observe().unwrap(), before);
    assert!(restored.ledger().removed > 0);
}

#[test]
fn empty_network_and_invalid_time_do_not_invent_inventory_or_change_state() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    )
    .unwrap();
    factory.advance(10.0).unwrap();
    assert_eq!(factory.observe().unwrap().tick, 600);
    assert_eq!(factory.work().segments, 0);
    assert_eq!(factory.work().visited_nodes, 0);
    let before = factory.observe().unwrap();
    for delta in [f64::NAN, -1.0] {
        assert!(factory.advance(delta).is_err());
        assert_eq!(factory.observe().unwrap(), before);
    }
}

#[test]
fn full_continuous_ring_keeps_seed_identities_and_three_miner_merge_is_fair() {
    let settings = Settings {
        interval: 0.1,
        amount: 1,
    };
    let mut ring = Factory::new(Bounds::default(), settings).unwrap();
    for (cell, direction) in [
        (Cell::new(0, 0, 0), Direction::East),
        (Cell::new(1, 0, 0), Direction::South),
        (Cell::new(1, 0, 1), Direction::West),
        (Cell::new(0, 0, 1), Direction::North),
    ] {
        ring.place(cell, Block::Belt, direction).unwrap();
    }
    ring.prefill_belts().unwrap();
    let ids: std::collections::BTreeSet<_> = ring
        .observe()
        .unwrap()
        .machines
        .iter()
        .flat_map(|row| row.ores.iter().map(|ore| ore.id))
        .collect();
    for _ in 0..300 {
        ring.advance(STEP).unwrap();
    }
    let state = ring.observe().unwrap();
    assert_eq!(
        state
            .machines
            .iter()
            .flat_map(|row| row.ores.iter().map(|ore| ore.id))
            .collect::<std::collections::BTreeSet<_>>(),
        ids
    );
    assert_eq!(ring.ledger().initial, 8);
    assert_eq!(ring.work().segments, 2);

    let mut merge = Factory::new(Bounds::default(), settings).unwrap();
    merge
        .place(Cell::new(0, 0, 0), Block::Belt, Direction::East)
        .unwrap();
    merge
        .place(Cell::new(1, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    for direction in [Direction::East, Direction::South, Direction::North] {
        let vector = direction.cell();
        merge
            .place(Cell::new(-vector.x, 0, -vector.z), Block::Miner, direction)
            .unwrap();
    }
    for _ in 0..600 {
        merge.advance(STEP).unwrap();
    }
    let state = merge.observe().unwrap();
    let sent: Vec<_> = state
        .machines
        .iter()
        .filter(|row| row.block == Block::Miner)
        .map(|row| row.cycles - row.quantity)
        .collect();
    assert!(sent.iter().all(|&count| count > 0));
    assert!(sent.iter().max().unwrap() - sent.iter().min().unwrap() <= 1);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        merge.ledger().produced
    );
}

#[test]
fn reconnecting_overlapping_queues_waits_for_real_spacing_without_losing_items() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
    )
    .unwrap();
    factory
        .place(Cell::new(0, 0, 0), Block::Belt, Direction::North)
        .unwrap();
    factory
        .place(Cell::new(1, 0, 0), Block::Belt, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(2, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(1, 0, 1), Block::Miner, Direction::North)
        .unwrap();
    factory.prefill_belts().unwrap();
    factory.advance(0.1).unwrap();
    let before = factory.observe().unwrap();
    factory
        .set_direction(Cell::new(0, 0, 0), Direction::East)
        .unwrap();
    factory.advance(STEP).unwrap();
    // The three-dimensional adapter now cuts merges at the cell centre.
    // Separate incoming half-arms can safely connect before the old full-cell
    // seam would have opened; the package decides whether spacing must wait.
    assert!(
        factory.work().waiting_seams <= 1,
        "before reconnect: {before:?}"
    );
    for _ in 0..60 {
        factory.advance(STEP).unwrap();
    }
    assert_eq!(factory.work().waiting_seams, 0);
    let total: i64 = factory
        .observe()
        .unwrap()
        .machines
        .iter()
        .map(|row| row.quantity)
        .sum();
    assert_eq!(total, factory.ledger().initial + factory.ledger().produced);
}

#[test]
fn dense_blocked_slopes_can_be_reconnected_to_a_chest() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 2,
        },
    )
    .unwrap();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    for x in 0..20 {
        factory
            .place(
                Cell::new(x, 0, 0),
                if x % 2 == 0 {
                    Block::BeltUpEast
                } else {
                    Block::BeltDownEast
                },
                Direction::East,
            )
            .unwrap();
    }
    factory.advance(15.0).unwrap();
    factory
        .place(Cell::new(20, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory.advance(2.0).unwrap();
    let state = factory.observe().unwrap();
    assert!(state.machines.last().unwrap().quantity > 0);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        factory.ledger().produced
    );
}
