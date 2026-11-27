//! Preparing, deciding and applying use successive world operations.
mod support;
use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::{Clock, Settings},
    persistence::{
        Player, Session, capture,
        store::{Kind, SaveRequest, Store, new_id},
    },
    runtime::{
        Command, Error, Frame, Input, Limits, Outcome, Runtime, Timing,
        presentation::{Interest, PAGE_BYTES, Stage},
    },
    world::{Block, Bounds, Cell},
};
use std::time::{Duration, Instant};
use support::{page, retry, run, stop, take};
struct Fixture {
    runtime: Runtime,
    root: std::path::PathBuf,
    session: Session,
    clock: Clock,
    revision: u64,
    before: Timing,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("factory-switch-{}", new_id()));
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let bounds = Bounds::new(Cell::new(-16, -2, -8), Cell::new(48, 30, 24), 2).unwrap();
        let mut saved = Factory::new(bounds, settings, Ruleset::ConveyorContinuousV1).unwrap();
        let preview = saved
            .preview(&[(Cell::new(40, 0, 0), Block::Chest, Direction::East)])
            .unwrap();
        saved.commit(&preview).unwrap();
        saved.advance(0.035).unwrap();
        let session = Session {
            world_id: [9; 16],
            world_name: "交接世界".into(),
            autosave_minutes: 17.0,
            autosave_retention: 8,
            player: Player {
                frame: 57,
                position: [40.1, 1.5, 4.0],
                velocity: [0.1, 0.2, 0.3],
                spawn: [40.0, 2.0, 0.0],
                body_rotation: [0.0, 0.8, 0.0],
                view_rotation: [-0.4, 0.0, 0.0],
                build_rotation: 3,
                free_position: [43.0, 7.0, 6.0],
                free_rotation: [0.2, 0.3, 0.4],
                tool: 13,
                free_view: true,
            },
        };
        let mut store = Store::open(&root).unwrap();
        let entry = store
            .save(
                capture(&saved, &session).unwrap(),
                SaveRequest {
                    name: "交接档".into(),
                    overwrite: false,
                    kind: Kind::Manual,
                    retention: 3,
                    expected_sequence: 0,
                },
                &mut |_| Ok(()),
            )
            .unwrap();
        drop(store);
        let runtime = Runtime::open_with_persistence(
            Bounds::default(),
            settings,
            Ruleset::LegacyDiscreteV1,
            1,
            Limits::default(),
            root.clone(),
        )
        .unwrap();
        run(
            &runtime,
            1,
            1,
            Command::Frame(Frame {
                frame_seq: 1,
                delta: 0.02,
            }),
        );
        run(&runtime, 1, 2, Command::Pause);
        let before = page(&runtime, 0).timing;
        assert_eq!(
            run(&runtime, 1, 3, Command::PrepareLoad(entry.id)).outcome,
            Outcome::LoadPrepared { job_id: 3 }
        );
        Self {
            runtime,
            root,
            session,
            clock: saved.clock(),
            revision: saved.revision(),
            before,
        }
    }
    fn ready(&self) {
        let decision = run(
            &self.runtime,
            1,
            4,
            Command::PresentationReady { job_id: 3 },
        );
        assert_eq!(
            decision.outcome,
            Outcome::CommitDecided {
                job_id: 3,
                next_epoch: 2
            }
        );
        assert_eq!(decision.world_epoch, 1);
        assert_eq!(page(&self.runtime, 0).timing, self.before);
    }
    fn apply(&self) {
        let result = run(
            &self.runtime,
            1,
            5,
            Command::SwitchApplied {
                job_id: 3,
                next_epoch: 2,
            },
        );
        assert_eq!(
            result.outcome,
            Outcome::LoadCompleted {
                job_id: 3,
                next_epoch: 2
            }
        );
        assert_eq!(result.world_epoch, 2);
    }
    fn candidate_pages(&self) -> factory_core::runtime::presentation::Info {
        retry(|| {
            self.runtime.subscribe_presentation(
                1,
                &Interest {
                    generation: 1,
                    job_id: 3,
                    keys: vec![Cell::new(5, 0, 0)],
                },
            )
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let info = retry(|| self.runtime.poll_presentation(1)).unwrap();
            if info.stage == Stage::Ready {
                return info;
            }
            assert!(Instant::now() < deadline, "{info:?}");
            std::thread::yield_now();
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        stop(&self.runtime);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn candidate_mesh_uses_candidate_bounds_and_cancel_discards_its_pages() {
    let f = Fixture::new();
    assert_eq!(
        retry(|| f.runtime.subscribe_presentation(
            1,
            &Interest {
                generation: 1,
                job_id: 0,
                keys: vec![Cell::new(5, 0, 0)]
            }
        )),
        Err(Error::InvalidArgument)
    );
    let info = f.candidate_pages();
    let data = retry(|| {
        f.runtime
            .poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES)
    })
    .unwrap();
    assert_eq!(data.job_id, 3);
    assert_eq!(data.revision, f.revision);
    assert_eq!(data.mesh.origin, [20.0, 0.0, 0.0]);
    assert_eq!(data.mesh.indices.len(), 30);
    assert_eq!(data.tick, f.clock.tick);
    assert!(retry(|| f.runtime.cancel(1, 3)).unwrap());
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadFailed {
            job_id: 3,
            error: factory_core::runtime::SaveError::Cancelled
        }
    );
    assert!(
        retry(|| f
            .runtime
            .poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES))
        .is_err()
    );
}

#[test]
fn applied_candidate_discards_old_epoch_pages_and_requires_a_new_subscription() {
    let f = Fixture::new();
    f.candidate_pages();
    f.ready();
    f.apply();
    assert_eq!(
        retry(|| f.runtime.poll_presentation(1)),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.poll_presentation(2)),
        Err(Error::NotReady)
    );
    retry(|| {
        f.runtime.subscribe_presentation(
            2,
            &Interest {
                generation: 1,
                job_id: 0,
                keys: vec![Cell::new(5, 0, 0)],
            },
        )
    })
    .unwrap();
}

#[test]
fn decision_keeps_old_world_then_switch_restores_bounds_clock_player_and_pause() {
    let f = Fixture::new();
    f.ready();
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 3, 704))
            .unwrap()
            .session,
        f.session
    );
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 5,
                command: Command::Cell(Cell::new(0, 0, 0))
            }
        )),
        Err(Error::Busy)
    );
    assert!(!retry(|| f.runtime.cancel(1, 3)).unwrap());
    f.apply();
    let timing = page(&f.runtime, 0).timing;
    assert_eq!(timing.clock, f.clock);
    assert_eq!(timing.revision, f.revision);
    assert_eq!(timing.completed_frame, 57);
    assert!(timing.paused);
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 3, 704)),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 6,
                command: Command::Cell(Cell::new(40, 0, 0))
            }
        )),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.submit(
            2,
            &Input {
                request_id: 6,
                command: Command::Frame(Frame {
                    frame_seq: 1,
                    delta: 0.0
                })
            }
        )),
        Err(Error::InvalidFrame)
    );
    assert_eq!(
        run(&f.runtime, 2, 6, Command::Cell(Cell::new(40, 0, 0))).outcome,
        Outcome::Cell(Block::Chest)
    );
    run(&f.runtime, 2, 7, Command::Resume);
    run(
        &f.runtime,
        2,
        8,
        Command::Frame(Frame {
            frame_seq: 58,
            delta: 0.02,
        }),
    );
    let resumed = page(&f.runtime, 0).timing;
    assert_eq!(resumed.completed_frame, 58);
    assert!(!resumed.paused);
    assert!(resumed.clock.time > f.clock.time);
}

#[test]
fn cancel_before_decision_keeps_old_epoch_state_and_allows_resume() {
    let f = Fixture::new();
    assert!(retry(|| f.runtime.cancel(1, 3)).unwrap());
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadFailed {
            job_id: 3,
            error: factory_core::runtime::SaveError::Cancelled
        }
    );
    assert_eq!(page(&f.runtime, 0).timing, f.before);
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 4,
                command: Command::PresentationReady { job_id: 3 }
            }
        )),
        Err(Error::InvalidArgument)
    );
    run(&f.runtime, 1, 4, Command::Resume);
    assert!(!page(&f.runtime, 0).timing.paused);
}

#[test]
fn each_load_phase_uses_the_single_operation_and_is_taken_once() {
    let f = Fixture::new();
    retry(|| {
        f.runtime.submit(
            1,
            &Input {
                request_id: 4,
                command: Command::PresentationReady { job_id: 3 },
            },
        )
    })
    .unwrap();
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 5,
                command: Command::SwitchApplied {
                    job_id: 3,
                    next_epoch: 2
                }
            }
        )),
        Err(Error::Busy)
    );
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::CommitDecided {
            job_id: 3,
            next_epoch: 2
        }
    );
    f.apply();
    assert!(page(&f.runtime, 192).results.is_empty());
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 5,
                command: Command::SwitchApplied {
                    job_id: 3,
                    next_epoch: 2
                }
            }
        )),
        Err(Error::StaleEpoch)
    );
}

#[test]
fn close_after_decision_reclaims_worlds_and_io() {
    let f = Fixture::new();
    f.ready();
    f.runtime.close();
    assert_eq!(
        f.runtime.submit(
            1,
            &Input {
                request_id: 5,
                command: Command::SwitchApplied {
                    job_id: 3,
                    next_epoch: 2
                }
            }
        ),
        Err(Error::Closed)
    );
    stop(&f.runtime);
    assert_eq!(
        Store::open(&f.root).unwrap().list().unwrap().entries.len(),
        1
    );
}
