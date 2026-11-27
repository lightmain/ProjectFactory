mod support;
use factory_core::{
    belt_placement::Direction,
    factory::Ruleset,
    logistics::Settings,
    runtime::{Command, Error, Input, Limits, Outcome, Runtime},
    world::{Block, Bounds, Cell},
};
use support::{page, retry, run, stop, take};

fn open(ruleset: Ruleset, limits: Limits) -> Runtime {
    Runtime::open(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
        1,
        limits,
    )
    .unwrap()
}
fn build(x: i32) -> Command {
    Command::Build(vec![(Cell::new(x, 0, 0), Block::Chest, Direction::East)])
}

#[test]
fn both_workers_apply_noncontiguous_request_ids_in_order() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = open(ruleset, Limits::default());
        assert_eq!(run(&r, 1, 41, build(0)).outcome, Outcome::Committed);
        assert_eq!(
            run(&r, 1, 6, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Chest)
        );
        assert_eq!(
            run(&r, 1, 92, Command::Remove(Cell::new(0, 0, 0))).outcome,
            Outcome::Committed
        );
        assert_eq!(
            run(&r, 1, 8, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        stop(&r);
    }
}

#[test]
fn invalid_identity_bounds_and_input_bytes_do_not_accept_work() {
    let r = open(
        Ruleset::LegacyDiscreteV1,
        Limits {
            input_bytes: 32,
            ..Limits::default()
        },
    );
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 0,
                command: build(0)
            }
        )),
        Err(Error::InvalidSequence)
    );
    assert_eq!(
        retry(|| r.submit(
            2,
            &Input {
                request_id: 7,
                command: build(0)
            }
        )),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 7,
                command: build(1000)
            }
        )),
        Err(Error::OutOfBounds)
    );
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 7,
                command: build(0)
            }
        )),
        Err(Error::Busy)
    );
    assert_eq!(
        run(&r, 1, 7, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
    stop(&r);
}

#[test]
fn build_is_atomic_and_an_edit_rejection_does_not_fault_the_world() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = open(ruleset, Limits::default());
        let bad = Command::Build(vec![
            (Cell::new(0, 0, 0), Block::Chest, Direction::East),
            (Cell::new(0, -1, 0), Block::Chest, Direction::East),
        ]);
        assert!(matches!(run(&r, 1, 1, bad).outcome, Outcome::Rejected(_)));
        assert_eq!(
            run(&r, 1, 2, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        assert_eq!(run(&r, 1, 3, build(0)).outcome, Outcome::Committed);
        stop(&r);
    }
}

#[test]
fn short_poll_budget_does_not_consume_and_close_reaches_a_full_slot() {
    let r = open(Ruleset::LegacyDiscreteV1, Limits::default());
    retry(|| {
        r.submit(
            1,
            &Input {
                request_id: 83,
                command: build(0),
            },
        )
    })
    .unwrap();
    assert!(page(&r, 95).results.is_empty());
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 8,
                command: build(1)
            }
        ),
        Err(Error::Busy)
    );
    assert_eq!(take(&r).request_id, 83);
    assert!(page(&r, 192).results.is_empty());
    retry(|| {
        r.submit(
            1,
            &Input {
                request_id: 8,
                command: build(1),
            },
        )
    })
    .unwrap();
    r.close();
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 9,
                command: build(2)
            }
        ),
        Err(Error::Closed)
    );
    stop(&r);
}
