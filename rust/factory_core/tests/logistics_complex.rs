use factory_core::{
    belt_placement::Direction,
    logistics::{Factory, STEP, Settings},
    world::{Block, Bounds, Cell},
};
use std::collections::BTreeSet;

fn place(factory: &mut Factory, cell: Cell, block: Block, direction: Direction) {
    factory.place(cell, block).unwrap();
    factory.set_direction(cell, direction).unwrap();
}

fn factory() -> Factory {
    Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.17,
            amount: 2,
        },
    )
}

#[test]
fn a_prefilled_full_ring_reserves_internal_heads_and_retains_all_identities() {
    let mut factory = factory();
    let cells = [
        Cell::new(0, 0, 0),
        Cell::new(1, 0, 0),
        Cell::new(1, 0, 1),
        Cell::new(0, 0, 1),
    ];
    for (index, direction) in [
        Direction::East,
        Direction::South,
        Direction::West,
        Direction::North,
    ]
    .into_iter()
    .enumerate()
    {
        place(&mut factory, cells[index], Block::Belt, direction);
    }
    place(
        &mut factory,
        Cell::new(-1, 0, 0),
        Block::Miner,
        Direction::East,
    );
    factory.prefill_belts().unwrap();
    let before = factory.observe();
    let initial: BTreeSet<u64> = before
        .machines
        .iter()
        .flat_map(|row| row.ores.iter().map(|ore| ore.id))
        .collect();
    assert_eq!(initial.len(), 8);
    assert_eq!(before.next_id, 9);
    for _ in 0..360 {
        factory.advance(STEP).unwrap();
        let state = factory.observe();
        let ids: BTreeSet<u64> = state
            .machines
            .iter()
            .flat_map(|row| row.ores.iter().map(|ore| ore.id))
            .collect();
        assert_eq!(ids, initial);
        assert_eq!(state.next_id, before.next_id);
        for cell in cells {
            let row = state.machines.iter().find(|row| row.cell == cell).unwrap();
            assert_eq!(row.quantity, 2);
            let predecessor = state
                .machines
                .iter()
                .find(|source| source.block.is_belt() && source.outgoing == Some(cell))
                .unwrap();
            assert_eq!(row.ores[1].incoming, predecessor.settled);
        }
    }
    assert!(factory.observe().machines[0].quantity > 0);
}

#[test]
fn prefill_is_only_accepted_for_an_empty_fresh_factory() {
    let mut factory = factory();
    place(
        &mut factory,
        Cell::new(0, 0, 0),
        Block::Belt,
        Direction::East,
    );
    factory.prefill_belts().unwrap();
    let before = factory.observe();
    assert!(factory.prefill_belts().is_err());
    assert_eq!(factory.observe(), before);
    let mut late = self::factory();
    late.advance(0.003).unwrap();
    place(&mut late, Cell::new(0, 0, 0), Block::Belt, Direction::East);
    let before = late.observe();
    assert!(late.prefill_belts().is_err());
    assert_eq!(late.observe(), before);
}

#[test]
fn all_three_ready_inventory_inputs_receive_fair_committed_output_turns() {
    let mut factory = factory();
    place(
        &mut factory,
        Cell::new(0, 0, 0),
        Block::Belt,
        Direction::East,
    );
    place(
        &mut factory,
        Cell::new(1, 0, 0),
        Block::Chest,
        Direction::East,
    );
    for direction in [Direction::East, Direction::South, Direction::North] {
        let vector = direction.cell();
        place(
            &mut factory,
            Cell::new(-vector.x, 0, -vector.z),
            Block::Miner,
            direction,
        );
    }
    for _ in 0..360 {
        factory.advance(STEP).unwrap();
    }
    let state = factory.observe();
    let sent: Vec<i64> = state
        .machines
        .iter()
        .filter(|row| row.block == Block::Miner)
        .map(|row| row.cycles * row.amount - row.quantity)
        .collect();
    assert!(sent.iter().all(|&count| count > 0));
    assert!(sent.iter().max().unwrap() - sent.iter().min().unwrap() <= 1);
    assert_eq!(
        state.machines.iter().map(|row| row.quantity).sum::<i64>(),
        state
            .machines
            .iter()
            .map(|row| row.cycles * row.amount)
            .sum::<i64>()
    );
}
