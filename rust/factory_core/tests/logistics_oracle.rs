//! Each record is a fresh legacy Godot observation bound to a fixed operation.
use factory_core::{
    belt_placement::Direction,
    logistics::{Factory, STEP, Settings},
    world::{Block, Bounds, Cell},
};
use std::collections::BTreeSet;

fn number(value: &str) -> f64 {
    assert_eq!(value.len(), 16);
    let bytes = std::array::from_fn(|index| {
        u8::from_str_radix(&value[index * 2..index * 2 + 2], 16).unwrap()
    });
    f64::from_le_bytes(bytes)
}

fn cell(value: &str) -> Option<Cell> {
    if value == "-" {
        return None;
    }
    let axes: Vec<i32> = value.split(',').map(|axis| axis.parse().unwrap()).collect();
    assert_eq!(axes.len(), 3);
    Some(Cell::new(axes[0], axes[1], axes[2]))
}

fn direction(value: &str) -> Direction {
    match value {
        "0" => Direction::South,
        "1" => Direction::West,
        "2" => Direction::North,
        "3" => Direction::East,
        _ => panic!("invalid direction: {value}"),
    }
}

fn apply(factory: &mut Factory, scenario: &str, operation: usize) {
    if operation == 0 {
        for (x, block) in [Block::Miner, Block::Belt, Block::Chest]
            .into_iter()
            .enumerate()
        {
            if scenario == "partial" && x == 0 {
                continue;
            }
            if matches!(scenario, "output" | "arrival") && x == 2 {
                continue;
            }
            let block = if scenario == "arrival" && x == 1 {
                Block::Chest
            } else {
                block
            };
            let at = Cell::new(x as i32, 0, 0);
            factory.place(at, block).unwrap();
            factory.set_direction(at, Direction::East).unwrap();
        }
    } else if operation == 301 {
        factory
            .set_direction(
                Cell::new(if scenario == "arrival" { 2 } else { 1 }, 0, 0),
                Direction::North,
            )
            .unwrap();
        *factory = Factory::from_checkpoint(factory.checkpoint());
    } else if scenario == "output" && operation == 7 {
        factory.remove(Cell::new(1, 0, 0)).unwrap();
        factory.place(Cell::new(1, 0, 0), Block::Belt).unwrap();
        factory
            .set_direction(Cell::new(1, 0, 0), Direction::East)
            .unwrap();
        factory.advance(1e-10).unwrap();
    } else if scenario == "arrival" && operation == 7 {
        factory.place(Cell::new(2, 0, 0), Block::Belt).unwrap();
        factory
            .set_direction(Cell::new(2, 0, 0), Direction::East)
            .unwrap();
        factory.advance(1e-10).unwrap();
    } else if matches!(scenario, "output" | "arrival") && operation == 8 {
        factory.advance(0.0).unwrap();
    } else if scenario == "partial" && operation == 1 {
        factory.advance(0.003).unwrap();
        factory.place(Cell::new(0, 0, 0), Block::Miner).unwrap();
        factory
            .set_direction(Cell::new(0, 0, 0), Direction::East)
            .unwrap();
    } else if scenario == "blocked" && operation == 40 {
        factory.remove(Cell::new(2, 0, 0)).unwrap();
        factory.advance(STEP).unwrap();
    } else if scenario == "blocked" && operation == 160 {
        factory.place(Cell::new(2, 0, 0), Block::Chest).unwrap();
        factory
            .set_direction(Cell::new(2, 0, 0), Direction::East)
            .unwrap();
        factory.advance(STEP).unwrap();
    } else if scenario == "flush" && (60..=62).contains(&operation) {
        factory
            .set_direction(
                Cell::new(1, 0, 0),
                if operation == 60 {
                    Direction::North
                } else {
                    Direction::East
                },
            )
            .unwrap();
        factory.advance(1e-10).unwrap();
    } else {
        factory.advance(STEP).unwrap();
    }
}

fn apply_complex(factory: &mut Factory, scenario: &str, operation: usize) {
    fn place(factory: &mut Factory, at: Cell, block: Block, direction: Direction) {
        factory.place(at, block).unwrap();
        factory.set_direction(at, direction).unwrap();
    }
    if operation != 0 {
        if scenario == "merge" && matches!(operation, 120 | 125) {
            factory
                .set_direction(
                    Cell::new(0, 0, 0),
                    if operation == 120 {
                        Direction::North
                    } else {
                        Direction::East
                    },
                )
                .unwrap();
        }
        factory.advance(STEP).unwrap();
        return;
    }
    if scenario == "merge" {
        place(factory, Cell::new(0, 0, 0), Block::Belt, Direction::East);
        place(factory, Cell::new(1, 0, 0), Block::Chest, Direction::East);
        for direction in [Direction::East, Direction::South, Direction::North] {
            let vector = direction.cell();
            place(
                factory,
                Cell::new(-vector.x, 0, -vector.z),
                Block::Miner,
                direction,
            );
        }
    } else if scenario == "ring" {
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
            place(factory, cells[index], Block::Belt, direction);
        }
        place(factory, Cell::new(-1, 0, 0), Block::Miner, Direction::East);
        factory.prefill_belts().unwrap();
    } else {
        let rotation: u8 = scenario.strip_prefix("slope").unwrap().parse().unwrap();
        let facing = [
            Direction::South,
            Direction::West,
            Direction::North,
            Direction::East,
        ][usize::from(rotation)];
        let vector = facing.cell();
        let side = Cell::new(-vector.z, 0, vector.x);
        let side_direction = [
            Direction::West,
            Direction::North,
            Direction::East,
            Direction::South,
        ][usize::from(rotation)];
        let cells = [
            Cell::new(-vector.x, 0, -vector.z),
            Cell::new(0, 0, 0),
            vector,
            Cell::new(2 * vector.x, 1, 2 * vector.z),
            Cell::new(3 * vector.x, 1, 3 * vector.z),
            Cell::new(4 * vector.x, 0, 4 * vector.z),
            Cell::new(5 * vector.x, 0, 5 * vector.z),
            Cell::new(5 * vector.x + side.x, 0, 5 * vector.z + side.z),
        ];
        let blocks = [
            5,
            6,
            9 + rotation,
            9 + rotation,
            13 + rotation,
            13 + rotation,
            6,
            7,
        ];
        for (index, cell) in cells.into_iter().enumerate() {
            place(
                factory,
                cell,
                Block::try_from(blocks[index]).unwrap(),
                if index < 6 { facing } else { side_direction },
            );
        }
        place(
            factory,
            Cell::new(5 * vector.x - side.x, 0, 5 * vector.z - side.z),
            Block::Miner,
            side_direction,
        );
        place(
            factory,
            Cell::new(vector.x - side.x, 0, vector.z - side.z),
            Block::Miner,
            side_direction,
        );
        factory.prefill_belts().unwrap();
    }
}

#[test]
fn committed_clock_phase_inventory_items_and_settled_connections_match_godot() {
    let complex = std::env::var("FACTORY_LOGISTICS_COMPLEX_ORACLE").ok();
    let path = complex
        .clone()
        .or_else(|| std::env::var("FACTORY_LOGISTICS_ORACLE").ok())
        .expect("fresh Godot logistics observations required");
    let observations = std::fs::read_to_string(path).unwrap();
    let mut lines = observations.lines();
    let mut seen = BTreeSet::new();
    let scenarios = if complex.is_some() {
        ["merge", "ring", "slope0", "slope1", "slope2", "slope3"]
    } else {
        ["chain", "blocked", "partial", "flush", "output", "arrival"]
    };
    let operations = if complex.is_some() { 361 } else { 362 };
    for scenario in scenarios {
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: if complex.is_some() { 0.17 } else { 0.1 },
                amount: if complex.is_some() {
                    2
                } else if scenario == "output" {
                    3
                } else {
                    1
                },
            },
        );
        for operation in 0..operations {
            let line = lines.next().expect("missing clock record");
            let values: Vec<_> = line.split_whitespace().collect();
            assert_eq!(values.len(), 12, "{line}");
            assert_eq!(&values[..3], &["S", scenario, &operation.to_string()]);
            assert!(seen.insert((scenario, operation)));
            if complex.is_some() {
                apply_complex(&mut factory, scenario, operation);
            } else {
                apply(&mut factory, scenario, operation);
            }
            let state = factory.observe();
            assert_eq!(state.time, number(values[3]), "{scenario}:{operation} time");
            assert_eq!(
                state.compensation,
                number(values[4]),
                "{scenario}:{operation} compensation"
            );
            assert_eq!(state.tick, values[5].parse::<i64>().unwrap());
            assert_eq!(state.flushed, values[6].parse::<i64>().unwrap());
            assert_eq!(state.next_id, values[7].parse::<u64>().unwrap());
            assert_eq!(state.dirty, values[8] == "1");
            assert!(matches!(values[8], "0" | "1"));
            assert_eq!(state.settings.interval, number(values[9]));
            assert_eq!(state.settings.amount, values[10].parse::<i64>().unwrap());
            assert_eq!(state.machines.len(), values[11].parse::<usize>().unwrap());
            for row in state.machines {
                let line = lines.next().expect("missing machine");
                let values: Vec<_> = line.split_whitespace().collect();
                assert_eq!(values.len(), 19, "{line}");
                assert_eq!(values[0], "M");
                assert_eq!(Some(row.cell), cell(values[1]), "{scenario}:{operation}");
                assert_eq!(row.block as u8, values[2].parse::<u8>().unwrap());
                assert_eq!(row.direction, direction(values[3]));
                assert_eq!(row.settled, direction(values[4]));
                assert_eq!(
                    row.quantity,
                    values[5].parse::<i64>().unwrap(),
                    "{scenario}:{operation} quantity at {:?}",
                    row.cell
                );
                assert_eq!(row.eligible, values[6].parse::<i64>().unwrap());
                assert_eq!(row.last_output, values[7].parse::<i64>().unwrap());
                assert_eq!(row.interval, number(values[8]));
                assert_eq!(row.amount, values[9].parse::<i64>().unwrap());
                assert_eq!(row.next, number(values[10]), "{scenario}:{operation} next");
                assert_eq!(row.cursor, values[11].parse::<usize>().unwrap());
                assert_eq!(row.placed, number(values[12]));
                assert_eq!(row.cycles, values[13].parse::<i64>().unwrap());
                assert_eq!(row.outgoing, cell(values[14]));
                assert_eq!(
                    row.inputs,
                    [cell(values[15]), cell(values[16]), cell(values[17])]
                );
                assert_eq!(row.ores.len(), values[18].parse::<usize>().unwrap());
                for ore in row.ores {
                    let line = lines.next().expect("missing ore");
                    let values: Vec<_> = line.split_whitespace().collect();
                    assert_eq!(values.len(), 4, "{line}");
                    assert_eq!(values[0], "O");
                    assert_eq!(ore.id, values[1].parse::<u64>().unwrap());
                    assert_eq!(ore.incoming, direction(values[2]));
                    assert!(
                        (ore.progress - number(values[3])).abs() <= 1e-12,
                        "{scenario}:{operation} progress"
                    );
                }
            }
        }
    }
    assert_eq!(seen.len(), operations * scenarios.len());
    assert!(lines.next().is_none(), "unexpected trailing records");
}
