use factory_core::{
    belt_placement::{Builder, Direction},
    factory::{Factory, Ruleset},
    logistics::Settings,
    world::{Block, Bounds, Cell},
};

fn factory() -> Factory {
    Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        Ruleset::ConveyorContinuousV1,
    )
    .unwrap()
}

fn route(factory: &mut Factory, start: Cell, end: Cell) {
    let mut builder = Builder::new(1024).unwrap();
    let directions = factory
        .observe()
        .unwrap()
        .machines
        .into_iter()
        .map(|row| (row.cell, row.direction))
        .collect::<std::collections::BTreeMap<_, _>>();
    builder
        .begin(
            factory.world(),
            &|at| directions.get(&at).copied(),
            start,
            Direction::East,
        )
        .unwrap();
    builder
        .preview(
            factory.world(),
            &|at| directions.get(&at).copied(),
            Some(end),
            Direction::East,
        )
        .unwrap();
    let preview = factory.preview_route(&builder).unwrap();
    factory.commit(&preview).unwrap();
}

#[test]
fn corner_positions_follow_both_half_arms_without_teleporting() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(0, 0, 0), Block::Belt, Direction::South)
        .unwrap();
    factory
        .place(Cell::new(0, 0, 1), Block::Belt, Direction::South)
        .unwrap();
    factory
        .place(Cell::new(0, 0, 2), Block::Chest, Direction::South)
        .unwrap();
    let mut previous = std::collections::BTreeMap::<u64, [f64; 3]>::new();
    let mut turned = false;
    for _ in 0..180 {
        factory.advance(1.0 / 60.0).unwrap();
        for row in factory.observe().unwrap().machines {
            for ore in &row.ores {
                let p = ore.position(row.cell, row.block);
                if row.cell == Cell::new(0, 0, 0) {
                    assert!(p[0] <= 0.25 + 1e-9);
                    assert!(p[2] >= 0.25 - 1e-9);
                    turned |= p[2] > 0.3;
                }
                if let Some(old) = previous.insert(ore.id, p) {
                    let distance = p
                        .into_iter()
                        .zip(old)
                        .map(|(a, b)| (a - b).powi(2))
                        .sum::<f64>()
                        .sqrt();
                    assert!(distance <= 0.02, "item {} moved {distance}", ore.id);
                }
            }
        }
    }
    assert!(turned);
}

#[test]
fn building_and_removing_branches_preserves_ports_and_unrelated_queues() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
    factory
        .place(Cell::new(4, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(-1, 0, 5), Block::Miner, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 5), Cell::new(3, 0, 5));
    factory
        .place(Cell::new(4, 0, 5), Block::Chest, Direction::East)
        .unwrap();
    factory.advance(2.0).unwrap();
    let before = factory.observe().unwrap();
    let mut control = Factory::from_checkpoint(factory.checkpoint().unwrap()).unwrap();
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
    let after = factory.observe().unwrap();
    assert_eq!(before.time, after.time);
    let junction = after
        .machines
        .iter()
        .find(|r| r.cell == Cell::new(1, 0, 0))
        .unwrap();
    assert_eq!(junction.output_ports.iter().flatten().count(), 2);
    factory.remove(Cell::new(1, 0, 1)).unwrap();
    let after = factory.observe().unwrap();
    let junction = after
        .machines
        .iter()
        .find(|r| r.cell == Cell::new(1, 0, 0))
        .unwrap();
    assert_eq!(junction.output_ports.iter().flatten().count(), 1);
    for _ in 0..120 {
        factory.advance(1.0 / 60.0).unwrap();
        control.advance(1.0 / 60.0).unwrap();
        let unrelated = |f: &Factory| {
            f.observe()
                .unwrap()
                .machines
                .into_iter()
                .filter(|r| r.cell.z == 5)
                .collect::<Vec<_>>()
        };
        assert_eq!(unrelated(&factory), unrelated(&control));
    }
}

#[test]
fn three_way_split_uses_library_routing_and_recovers_from_blocked_branches() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, -2));
    let junction = factory
        .observe()
        .unwrap()
        .machines
        .into_iter()
        .find(|r| r.cell == Cell::new(1, 0, 0))
        .unwrap();
    assert_eq!(junction.output_ports.iter().flatten().count(), 3);
    factory
        .place(Cell::new(4, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory.advance(5.0).unwrap();
    let total = factory
        .observe()
        .unwrap()
        .machines
        .iter()
        .map(|r| r.quantity)
        .sum::<i64>();
    assert_eq!(total, factory.ledger().produced);
    for z in [-3, 3] {
        factory
            .place(
                Cell::new(1, 0, z),
                Block::Chest,
                if z > 0 {
                    Direction::South
                } else {
                    Direction::North
                },
            )
            .unwrap();
    }
    factory.advance(5.0).unwrap();
    let state = factory.observe().unwrap();
    assert!(
        state
            .machines
            .iter()
            .filter(|r| r.block == Block::Chest)
            .all(|r| r.quantity > 0)
    );
    assert_eq!(
        state.machines.iter().map(|r| r.quantity).sum::<i64>(),
        factory.ledger().produced
    );
    let ids: Vec<_> = state
        .machines
        .iter()
        .flat_map(|r| r.ores.iter().map(|o| o.id))
        .collect();
    assert_eq!(
        ids.len(),
        ids.iter().collect::<std::collections::BTreeSet<_>>().len()
    );
    assert_eq!(factory.ledger().removed, 0);
}

#[test]
fn routes_use_devices_as_endpoints_without_replacing_their_inventory() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(3, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(-1, 0, 0), Cell::new(3, 0, 0));
    factory.advance(4.0).unwrap();
    let state = factory.observe().unwrap();
    assert!(
        state
            .machines
            .iter()
            .find(|r| r.block == Block::Chest)
            .unwrap()
            .quantity
            > 0
    );
    assert_eq!(
        state.machines.iter().map(|r| r.quantity).sum::<i64>(),
        factory.ledger().produced
    );
}

#[test]
fn adding_a_third_exit_with_items_keeps_the_existing_output_arm() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
    factory
        .place(Cell::new(4, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    for _ in 0..300 {
        factory.advance(1.0 / 60.0).unwrap();
        let state = factory.observe().unwrap();
        let junction = state
            .machines
            .iter()
            .find(|r| r.cell == Cell::new(1, 0, 0))
            .unwrap();
        if junction
            .ores
            .iter()
            .any(|o| o.progress > 0.5 && o.outgoing == Direction::East)
        {
            route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, -2));
            let after = factory.observe().unwrap();
            assert_eq!(state.time, after.time);
            let ids = |s: &factory_core::logistics::State| {
                s.machines
                    .iter()
                    .flat_map(|r| r.ores.iter().map(|o| o.id))
                    .collect::<std::collections::BTreeSet<_>>()
            };
            assert_eq!(ids(&state), ids(&after));
            return;
        }
    }
    panic!("No item reached the existing output arm");
}

#[test]
fn adjacent_merge_and_split_accept_short_real_geometry() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(0, 0, 1), Block::Miner, Direction::North)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
    factory
        .place(Cell::new(4, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
    factory
        .place(Cell::new(1, 0, 3), Block::Chest, Direction::South)
        .unwrap();
    factory.advance(4.0).unwrap();
    let state = factory.observe().unwrap();
    assert!(
        state
            .machines
            .iter()
            .filter(|r| r.block == Block::Chest)
            .all(|r| r.quantity > 0)
    );
    assert_eq!(
        state.machines.iter().map(|r| r.quantity).sum::<i64>(),
        factory.ledger().produced
    );
}

#[test]
fn deleting_stacked_upper_slope_preserves_lower_slope_connection() {
    let mut factory = factory();
    factory
        .place(Cell::new(0, 0, 0), Block::BeltUpEast, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(0, 1, 0), Block::BeltUpEast, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(1, 1, 0), Block::Belt, Direction::East)
        .unwrap();
    factory
        .place(Cell::new(1, 1, 1), Block::Miner, Direction::North)
        .unwrap();
    let before = factory.observe().unwrap();
    let inputs = before
        .machines
        .iter()
        .find(|r| r.cell == Cell::new(1, 1, 0))
        .unwrap()
        .input_ports;
    assert!(inputs.contains(&Some(Direction::West)));
    factory.remove(Cell::new(0, 1, 0)).unwrap();
    let after = factory.observe().unwrap();
    assert_eq!(
        inputs,
        after
            .machines
            .iter()
            .find(|r| r.cell == Cell::new(1, 1, 0))
            .unwrap()
            .input_ports
    );
}

#[test]
fn slope_to_corner_route_keeps_the_entrance_before_further_edits() {
    use factory_core::{belt_placement::Segment, logistics::continuous};
    let mut factory = continuous::Factory::new(
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
    let additions = [
        (Cell::new(0, 0, 0), Block::BeltUpEast, Direction::East),
        (Cell::new(1, 1, 0), Block::Belt, Direction::South),
        (Cell::new(1, 1, 1), Block::Belt, Direction::South),
    ];
    let path: Vec<_> = additions
        .iter()
        .map(|&(cell, block, direction)| Segment {
            cell,
            block,
            direction,
        })
        .collect();
    factory.place_route(&additions, &path).unwrap();
    let state = factory.observe().unwrap();
    assert_eq!(
        state
            .machines
            .iter()
            .find(|r| r.cell == Cell::new(1, 1, 0))
            .unwrap()
            .input_ports[0],
        Some(Direction::West)
    );
}

#[test]
fn adding_branch_keeps_an_existing_chest_or_downhill_outlet() {
    for downhill in [false, true] {
        let mut factory = factory();
        let y = i32::from(downhill);
        let junction = Cell::new(0, y, 0);
        factory
            .place(Cell::new(-1, y, 0), Block::Miner, Direction::East)
            .unwrap();
        factory
            .place(junction, Block::Belt, Direction::East)
            .unwrap();
        if downhill {
            factory
                .place(Cell::new(1, 0, 0), Block::BeltDownEast, Direction::East)
                .unwrap();
        }
        factory
            .place(
                Cell::new(if downhill { 2 } else { 1 }, 0, 0),
                Block::Chest,
                Direction::East,
            )
            .unwrap();
        route(&mut factory, junction, Cell::new(0, y, 2));
        let state = factory.observe().unwrap();
        let row = state.machines.iter().find(|r| r.cell == junction).unwrap();
        assert!(row.output_ports.contains(&Some(Direction::East)));
        assert!(row.output_ports.contains(&Some(Direction::South)));
        factory.advance(4.0).unwrap();
        assert!(
            factory
                .observe()
                .unwrap()
                .machines
                .iter()
                .find(|r| r.block == Block::Chest)
                .unwrap()
                .quantity
                > 0
        );
    }
}

#[test]
fn extending_a_blocked_split_keeps_the_center_waiter_and_all_identities() {
    let mut factory = factory();
    factory
        .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
    route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
    factory.advance(5.0).unwrap();
    let before = factory.observe().unwrap();
    assert!(
        before
            .machines
            .iter()
            .find(|r| r.cell == Cell::new(1, 0, 0))
            .unwrap()
            .ores
            .iter()
            .any(|ore| ore.progress == 0.5)
    );
    factory
        .place(Cell::new(4, 0, 0), Block::Belt, Direction::East)
        .unwrap();
    let after = factory.observe().unwrap();
    let positions = |state: &factory_core::logistics::State| {
        state
            .machines
            .iter()
            .flat_map(|row| {
                row.ores
                    .iter()
                    .map(|ore| (ore.id, ore.position(row.cell, row.block)))
            })
            .collect::<std::collections::BTreeMap<_, _>>()
    };
    assert_eq!(before.time, after.time);
    assert_eq!(positions(&before), positions(&after));
    factory
        .place(Cell::new(5, 0, 0), Block::Chest, Direction::East)
        .unwrap();
    factory.advance(4.0).unwrap();
    assert!(
        factory
            .observe()
            .unwrap()
            .machines
            .iter()
            .find(|r| r.block == Block::Chest)
            .unwrap()
            .quantity
            > 0
    );
}
