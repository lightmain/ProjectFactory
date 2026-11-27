//! Public acceptance for the single-operation host contract.
use factory_core::{
    belt_placement::Direction,
    factory::Ruleset,
    logistics::Settings,
    runtime::{Command, Error, Frame, Input, Limits, Outcome, PollLimits, Runtime},
    world::{Block, Bounds, Cell},
};
use std::time::{Duration, Instant};

fn runtime(ruleset: Ruleset) -> Runtime {
    Runtime::open(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
        1,
        Limits::default(),
    )
    .unwrap()
}

fn completion(runtime: &Runtime) -> factory_core::runtime::Completion {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match runtime.poll_updates(PollLimits::default()) {
            Ok(mut page) if !page.results.is_empty() => return page.results.remove(0),
            Ok(_) | Err(Error::Busy) if Instant::now() < deadline => std::thread::yield_now(),
            other => panic!("completion not delivered: {other:?}"),
        }
    }
}

#[test]
fn one_operation_blocks_new_work_until_its_result_is_taken_once() {
    let runtime = runtime(Ruleset::LegacyDiscreteV1);
    let cell = Cell::new(0, 0, 0);
    runtime
        .submit(
            1,
            &Input {
                request_id: 41,
                command: Command::Build(vec![(cell, Block::Chest, Direction::East)]),
            },
        )
        .unwrap();
    assert_eq!(
        runtime.submit(
            1,
            &Input {
                request_id: 92,
                command: Command::Remove(cell),
            }
        ),
        Err(Error::Busy)
    );
    let result = completion(&runtime);
    assert_eq!(result.request_id, 41);
    assert_eq!(result.outcome, Outcome::Committed);
    assert!(
        runtime
            .poll_updates(PollLimits::default())
            .unwrap()
            .results
            .is_empty()
    );
    runtime
        .submit(
            1,
            &Input {
                request_id: 92,
                command: Command::Cell(cell),
            },
        )
        .unwrap();
    assert_eq!(completion(&runtime).outcome, Outcome::Cell(Block::Chest));
}

#[test]
fn pause_waits_for_the_previous_step_and_frames_have_no_player_payload() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let runtime = runtime(ruleset);
        runtime
            .submit(
                1,
                &Input {
                    request_id: 5,
                    command: Command::Frame(Frame {
                        frame_seq: 1,
                        delta: 0.02,
                    }),
                },
            )
            .unwrap();
        assert_eq!(
            runtime.submit(
                1,
                &Input {
                    request_id: 8,
                    command: Command::Pause,
                }
            ),
            Err(Error::Busy)
        );
        assert_eq!(
            completion(&runtime).outcome,
            Outcome::FrameCompleted { frame_seq: 1 }
        );
        runtime
            .submit(
                1,
                &Input {
                    request_id: 8,
                    command: Command::Pause,
                },
            )
            .unwrap();
        assert_eq!(completion(&runtime).outcome, Outcome::Paused(true));
        assert_eq!(
            runtime.submit(
                1,
                &Input {
                    request_id: 9,
                    command: Command::Frame(Frame {
                        frame_seq: 2,
                        delta: 0.02
                    }),
                }
            ),
            Err(Error::Paused)
        );
        let page = runtime.poll_updates(PollLimits::default()).unwrap();
        assert_eq!(page.timing.clock.time, 0.02);
        assert_eq!(page.timing.completed_frame, 1);
    }
}
