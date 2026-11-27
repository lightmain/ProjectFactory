mod support;
use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::Settings,
    runtime::{Command, Error, Frame, Limits, Runtime, display},
    world::{Block, Bounds, Cell},
};
use support::{retry, run, stop};

#[test]
fn local_samples_match_rules_without_visiting_other_devices() {
    for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            rules,
        )
        .unwrap();
        let edits = [
            (Cell::new(0, 0, 0), Block::Miner, Direction::East),
            (Cell::new(1, 0, 0), Block::Belt, Direction::East),
            (Cell::new(2, 0, 0), Block::Belt, Direction::South),
            (Cell::new(2, 0, 1), Block::Chest, Direction::South),
        ];
        let preview = factory.preview(&edits).unwrap();
        factory.commit(&preview).unwrap();
        for _ in 0..90 {
            factory.advance(1.0 / 60.0).unwrap();
            for row in factory.observe().unwrap().machines {
                assert_eq!(factory.local_machine(row.cell, 1024).unwrap(), Some(row));
            }
        }
        assert_eq!(
            factory.local_machine(Cell::new(20, 0, 20), 0).unwrap(),
            None
        );
        assert!(factory.local_machine(Cell::new(1, 0, 0), 0).is_err());
    }
}

#[test]
fn dynamic_round_is_immutable_bounded_and_released_explicitly() {
    for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let runtime = Runtime::open(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            rules,
            1,
            Limits::default(),
        )
        .unwrap();
        run(
            &runtime,
            1,
            1,
            Command::Build(vec![
                (Cell::new(0, 0, 0), Block::Miner, Direction::East),
                (Cell::new(1, 0, 0), Block::Belt, Direction::East),
                (Cell::new(2, 0, 0), Block::Chest, Direction::East),
            ]),
        );
        run(
            &runtime,
            1,
            2,
            Command::Frame(Frame {
                frame_seq: 1,
                delta: 4.0 / 60.0,
            }),
        );
        retry(|| runtime.request_display(1, 1, vec![Cell::new(0, 0, 0)])).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let info = loop {
            assert!(
                std::time::Instant::now() < deadline,
                "display did not become ready"
            );
            match retry(|| runtime.poll_display(1, 1)) {
                Err(Error::NotReady) => std::thread::yield_now(),
                result => break result.unwrap(),
            }
        };
        assert_eq!(
            retry(|| runtime.request_display(1, 2, vec![Cell::new(0, 0, 0)])),
            Err(Error::Busy)
        );
        assert!(info.total_bytes <= display::MAX_BYTES);
        let first =
            retry(|| runtime.poll_display_page(1, 1, info.snapshot_id, 0, display::PAGE_BYTES))
                .unwrap();
        assert_eq!(first.devices.len(), 3);
        assert_eq!(
            retry(|| runtime.poll_display_page(1, 1, info.snapshot_id, 0, first.bytes - 1)),
            Err(Error::InvalidArgument)
        );
        run(
            &runtime,
            1,
            3,
            Command::Frame(Frame {
                frame_seq: 2,
                delta: 4.0 / 60.0,
            }),
        );
        assert_eq!(
            retry(|| runtime.poll_display_page(1, 1, info.snapshot_id, 0, display::PAGE_BYTES))
                .unwrap(),
            first
        );
        retry(|| runtime.release_display(1, 1)).unwrap();
        retry(|| runtime.request_display(1, 2, vec![Cell::new(1, 0, 1)])).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            assert!(
                std::time::Instant::now() < deadline,
                "display migration did not complete"
            );
            match retry(|| runtime.poll_display(1, 2)) {
                Err(Error::NotReady) => std::thread::yield_now(),
                Err(error) => panic!("display migration failed: {error:?}"),
                Ok(next) => {
                    assert!(next.tick > info.tick);
                    let page = retry(|| {
                        runtime.poll_display_page(1, 2, next.snapshot_id, 0, display::PAGE_BYTES)
                    })
                    .unwrap();
                    assert!(page.devices.is_empty());
                    break;
                }
            }
        }
        runtime.close();
        assert_eq!(runtime.poll_display(1, 2), Err(Error::Closed));
        stop(&runtime);
    }
}
