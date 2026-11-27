mod support;
use factory_core::{
    factory::{Factory, Ruleset},
    logistics::Settings,
    runtime::{Command, Error, Frame, Input, Limits, Outcome, Runtime},
    world::Bounds,
};
use support::{page, retry, run, stop, take};

fn open(ruleset: Ruleset) -> Runtime {
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
fn frame(frame_seq: u64, delta: f64) -> Command {
    Command::Frame(Frame { frame_seq, delta })
}

#[test]
fn original_deltas_match_synchronous_factory_in_both_rulesets() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = open(ruleset);
        let mut synchronous = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            ruleset,
        )
        .unwrap();
        for (index, delta) in [0.003, 0.007, 0.009, 0.011, 1.0 / 120.0, 4.0 / 60.0]
            .into_iter()
            .enumerate()
        {
            let id = index as u64 + 1;
            synchronous.advance(delta).unwrap();
            assert_eq!(
                run(&r, 1, id, frame(id, delta)).outcome,
                Outcome::FrameCompleted { frame_seq: id }
            );
            assert_eq!(page(&r, 0).timing.clock, synchronous.clock());
        }
        let timing = page(&r, 0).timing;
        assert_eq!(page(&r, 0).timing, timing, "polling does not advance time");
        assert!(timing.max_advance_seconds >= timing.last_advance_seconds);
        stop(&r);
    }
}

#[test]
fn invalid_frames_never_advance_clock_and_pause_blocks_positive_delta() {
    let r = open(Ruleset::LegacyDiscreteV1);
    for delta in [-0.01, 4.0 / 60.0 + 0.001, f64::NAN, f64::INFINITY] {
        assert_eq!(
            retry(|| r.submit(
                1,
                &Input {
                    request_id: 1,
                    command: frame(1, delta)
                }
            )),
            Err(Error::InvalidArgument)
        );
    }
    assert_eq!(page(&r, 0).timing.clock.time, 0.0);
    run(&r, 1, 8, frame(2, 0.01));
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 9,
                command: frame(1, 0.01)
            }
        )),
        Err(Error::InvalidFrame)
    );
    assert_eq!(
        run(&r, 1, 10, Command::Pause).outcome,
        Outcome::Paused(true)
    );
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 11,
                command: frame(3, 0.01)
            }
        )),
        Err(Error::Paused)
    );
    run(&r, 1, 11, frame(3, 0.0));
    assert_eq!(page(&r, 0).timing.clock.time, 0.01);
    run(&r, 1, 12, Command::Resume);
    run(&r, 1, 13, frame(4, 0.02));
    assert!((page(&r, 0).timing.clock.time - 0.03).abs() < 1e-15);
    stop(&r);
}

#[test]
fn next_frame_waits_until_prior_completion_is_taken() {
    let r = open(Ruleset::LegacyDiscreteV1);
    retry(|| {
        r.submit(
            1,
            &Input {
                request_id: 7,
                command: frame(1, 0.003),
            },
        )
    })
    .unwrap();
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 19,
                command: frame(2, 0.007)
            }
        ),
        Err(Error::Busy)
    );
    assert_eq!(take(&r).request_id, 7);
    run(&r, 1, 19, frame(2, 0.007));
    assert_eq!(page(&r, 0).timing.clock.time, 0.01);
    stop(&r);
}
