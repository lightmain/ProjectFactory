mod support;
use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::Settings,
    persistence::{
        Player, Session, capture,
        store::{Kind, SaveRequest, Store, hex, new_id},
    },
    runtime::{Command, Error, Frame, Input, Limits, Outcome, Runtime, Save},
    world::{Block, Bounds, Cell},
};
use support::{page, retry, run, stop, take};

fn settings() -> Settings {
    Settings {
        interval: 0.1,
        amount: 1,
    }
}
fn player(frame: u64) -> Player {
    Player {
        frame,
        position: [2.0, 3.0, -4.0],
        velocity: [0.5, -0.1, 0.2],
        spawn: [-1.0, 4.0, 1.0],
        body_rotation: [0.0, 0.4, 0.0],
        view_rotation: [-0.2, 0.1, 0.0],
        tool: 13,
        build_rotation: 3,
        free_view: true,
        free_position: [-2.0, 6.0, 7.0],
        free_rotation: [-0.6, 0.8, 0.0],
    }
}
fn save(frame: u64) -> Save {
    Save {
        player: player(frame),
        world_id: [7; 16],
        world_name: "后台世界".into(),
        autosave_minutes: 5.0,
        request: SaveRequest {
            name: "暂停后保存".into(),
            overwrite: false,
            kind: Kind::Manual,
            retention: 3,
            expected_sequence: 0,
        },
    }
}
struct Fixture {
    runtime: Runtime,
    root: std::path::PathBuf,
}
impl Fixture {
    fn new(ruleset: Ruleset) -> Self {
        let root = std::env::temp_dir().join(format!("factory-runtime-save-{}", new_id()));
        let runtime = Runtime::open_with_persistence(
            Bounds::default(),
            settings(),
            ruleset,
            1,
            Limits::default(),
            root.clone(),
        )
        .unwrap();
        Self { runtime, root }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        stop(&self.runtime);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn paused_capture_preserves_both_rules_and_full_player_without_per_frame_pairing() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let f = Fixture::new(ruleset);
        let runtime = &f.runtime;
        let cells = vec![
            (Cell::new(0, 0, 0), Block::Miner, Direction::East),
            (Cell::new(1, 0, 0), Block::Belt, Direction::East),
            (Cell::new(2, 0, 0), Block::Chest, Direction::East),
        ];
        assert_eq!(
            run(runtime, 1, 1, Command::Build(cells.clone())).outcome,
            Outcome::Committed
        );
        run(
            runtime,
            1,
            2,
            Command::Frame(Frame {
                frame_seq: 7,
                delta: 1.0 / 120.0,
            }),
        );
        run(runtime, 1, 3, Command::Pause);
        assert_eq!(
            run(runtime, 1, 4, Command::Save(save(7))).outcome,
            Outcome::SaveStarted { job_id: 4 }
        );
        // A subsequent edit can execute after capture, even before disk completion.
        retry(|| {
            runtime.submit(
                1,
                &Input {
                    request_id: 5,
                    command: Command::Remove(Cell::new(2, 0, 0)),
                },
            )
        })
        .unwrap();
        let mut terminal = None;
        let mut edited = false;
        while terminal.is_none() || !edited {
            let completion = take(runtime);
            if completion.request_id == 4 {
                terminal = Some(completion);
            } else {
                assert_eq!(completion.request_id, 5);
                edited = true;
            }
        }
        run(runtime, 1, 6, Command::Resume);
        run(
            runtime,
            1,
            7,
            Command::Frame(Frame {
                frame_seq: 8,
                delta: 1.0 / 60.0,
            }),
        );
        let terminal = terminal.unwrap();
        assert_eq!((terminal.tick, terminal.revision), (0, 1));
        let save_id = match terminal.outcome {
            Outcome::SaveCompleted {
                job_id: 4,
                frame_seq: 7,
                save_id,
                directory_sequence: 1,
            } => save_id,
            other => panic!("{other:?}"),
        };
        let mut expected = Factory::new(Bounds::default(), settings(), ruleset).unwrap();
        let preview = expected.preview(&cells).unwrap();
        expected.commit(&preview).unwrap();
        expected.advance(1.0 / 120.0).unwrap();
        let expected = capture(
            &expected,
            &Session {
                world_id: [7; 16],
                world_name: "后台世界".into(),
                autosave_minutes: 5.0,
                autosave_retention: 3,
                player: player(7),
            },
        )
        .unwrap()
        .encode()
        .unwrap();
        stop(runtime);
        let mut store = Store::open(&f.root).unwrap();
        assert_eq!(store.list().unwrap().sequence, 1);
        assert_eq!(store.list().unwrap().entries.len(), 1);
        assert_eq!(
            store.load(&hex(&save_id)).unwrap().encode().unwrap(),
            expected
        );
    }
}

#[test]
fn original_serial_events_preserve_complete_state_and_restored_continuation() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let fixture = Fixture::new(ruleset);
        let runtime = &fixture.runtime;
        let mut expected = Factory::new(Bounds::default(), settings(), ruleset).unwrap();
        let cells = vec![
            (Cell::new(0, 0, 0), Block::Miner, Direction::East),
            (Cell::new(1, 0, 0), Block::Belt, Direction::East),
            (Cell::new(2, 0, 0), Block::Chest, Direction::East),
        ];
        let mut request = 1;
        let mut frame = 0;
        for delta in [0.003, 0.007] {
            frame += 1;
            run(
                runtime,
                1,
                request,
                Command::Frame(Frame {
                    frame_seq: frame,
                    delta,
                }),
            );
            expected.advance(delta).unwrap();
            request += 1;
        }
        run(runtime, 1, request, Command::Build(cells.clone()));
        let preview = expected.preview(&cells).unwrap();
        expected.commit(&preview).unwrap();
        request += 1;
        for index in 0..120 {
            if index == 20 || index == 40 {
                let direction = if index == 20 {
                    Direction::West
                } else {
                    Direction::East
                };
                run(
                    runtime,
                    1,
                    request,
                    Command::SetDirection(Cell::new(1, 0, 0), direction),
                );
                expected
                    .set_direction(Cell::new(1, 0, 0), direction)
                    .unwrap();
                request += 1;
            }
            let delta = if index == 0 {
                0.0
            } else if index % 2 == 0 {
                0.013
            } else {
                0.021
            };
            frame += 1;
            run(
                runtime,
                1,
                request,
                Command::Frame(Frame {
                    frame_seq: frame,
                    delta,
                }),
            );
            expected.advance(delta).unwrap();
            request += 1;
        }
        run(runtime, 1, request, Command::Pause);
        request += 1;
        let save_request = save(frame);
        let session = Session {
            world_id: save_request.world_id,
            world_name: save_request.world_name.clone(),
            autosave_minutes: save_request.autosave_minutes,
            autosave_retention: save_request.request.retention,
            player: save_request.player.clone(),
        };
        run(runtime, 1, request, Command::Save(save_request));
        let id = match take(runtime).outcome {
            Outcome::SaveCompleted { save_id, .. } => save_id,
            outcome => panic!("{outcome:?}"),
        };
        request += 1;
        run(runtime, 1, request, Command::PrepareLoad(hex(&id)));
        let job = request;
        request += 1;
        run(
            runtime,
            1,
            request,
            Command::PresentationReady { job_id: job },
        );
        request += 1;
        run(
            runtime,
            1,
            request,
            Command::SwitchApplied {
                job_id: job,
                next_epoch: 2,
            },
        );
        request += 1;
        run(runtime, 2, request, Command::Resume);
        request += 1;
        let mut continued_frame = frame;
        let before_bytes = capture(&expected, &session).unwrap().encode().unwrap();
        for delta in [0.013, 0.0, 0.021, 1.0 / 60.0, 0.031] {
            continued_frame += 1;
            run(
                runtime,
                2,
                request,
                Command::Frame(Frame {
                    frame_seq: continued_frame,
                    delta,
                }),
            );
            expected.advance(delta).unwrap();
            request += 1;
        }
        run(runtime, 2, request, Command::Pause);
        request += 1;
        let mut continued = save(continued_frame);
        continued.request.name = "恢复续跑".into();
        continued.request.expected_sequence = 1;
        run(runtime, 2, request, Command::Save(continued));
        let continued_id = match take(runtime).outcome {
            Outcome::SaveCompleted { save_id, .. } => save_id,
            outcome => panic!("{outcome:?}"),
        };
        let continued_session = Session {
            player: player(continued_frame),
            ..session
        };
        let after_bytes = capture(&expected, &continued_session)
            .unwrap()
            .encode()
            .unwrap();
        stop(runtime);
        let mut store = Store::open(&fixture.root).unwrap();
        // Full disk bytes include inventory, belt progress, production phases,
        // ledger, compensated clock and player/session metadata.
        assert_eq!(
            store.load(&hex(&id)).unwrap().encode().unwrap(),
            before_bytes
        );
        assert_eq!(
            store.load(&hex(&continued_id)).unwrap().encode().unwrap(),
            after_bytes
        );
    }
}

#[test]
fn save_requires_confirmed_pause_and_valid_snapshot_metadata() {
    let f = Fixture::new(Ruleset::LegacyDiscreteV1);
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 1,
                command: Command::Save(save(1))
            }
        )),
        Err(Error::NotPaused)
    );
    run(&f.runtime, 1, 1, Command::Pause);
    for invalid in 0..3 {
        let mut request = save(1);
        match invalid {
            0 => request.request.name.clear(),
            1 => request.player.position[0] = f64::NAN,
            _ => request.world_name = "🏭".repeat(81),
        }
        assert_eq!(
            retry(|| f.runtime.submit(
                1,
                &Input {
                    request_id: 2,
                    command: Command::Save(request.clone())
                }
            )),
            Err(Error::InvalidArgument)
        );
        assert!(page(&f.runtime, 192).results.is_empty());
        assert_eq!(page(&f.runtime, 0).timing.completed_frame, 0);
    }
    // No frame event or matching frame number is required for a paused capture.
    assert_eq!(
        run(&f.runtime, 1, 2, Command::Save(save(57))).outcome,
        Outcome::SaveStarted { job_id: 2 }
    );
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::SaveCompleted { frame_seq: 57, .. }
    ));
}

#[test]
fn disk_slot_is_released_only_when_the_terminal_is_taken() {
    let f = Fixture::new(Ruleset::LegacyDiscreteV1);
    run(&f.runtime, 1, 1, Command::Pause);
    run(&f.runtime, 1, 2, Command::Save(save(0)));
    // A zero-byte poll cannot consume the terminal or its reservation.
    assert!(page(&f.runtime, 0).results.is_empty());
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 3,
                command: Command::Save(save(0))
            }
        )),
        Err(Error::Busy)
    );
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::SaveCompleted { job_id: 2, .. }
    ));
    let mut next = save(0);
    next.request.name = "第二槽位".into();
    next.request.expected_sequence = 1;
    assert_eq!(
        run(&f.runtime, 1, 3, Command::Save(next)).outcome,
        Outcome::SaveStarted { job_id: 3 }
    );
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::SaveCompleted { job_id: 3, .. }
    ));
    assert!(page(&f.runtime, 192).results.is_empty());
}
