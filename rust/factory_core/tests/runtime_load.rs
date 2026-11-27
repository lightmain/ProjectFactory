mod support;
use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::{Clock, Settings},
    persistence::{
        Player, Session, capture,
        store::{Kind, SaveRequest, Store, new_id},
    },
    runtime::{Command, Error, Frame, Input, Limits, Outcome, Runtime, SaveError},
    world::{Block, Bounds, Cell},
};
use std::path::PathBuf;
use support::{page, retry, run, stop, take};

struct Fixture {
    runtime: Runtime,
    root: PathBuf,
    id: String,
    session: Session,
    clock: Clock,
    revision: u64,
    bounds: Bounds,
}
impl Fixture {
    fn new(ruleset: Ruleset, limits: Limits) -> Self {
        let root = std::env::temp_dir().join(format!("factory-load-candidate-{}", new_id()));
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let bounds = if ruleset == Ruleset::ConveyorContinuousV1 {
            Bounds::new(Cell::new(-16, -2, -8), Cell::new(48, 30, 24), 2).unwrap()
        } else {
            Bounds::default()
        };
        let mut factory = Factory::new(bounds, settings, ruleset).unwrap();
        let preview = factory
            .preview(&[(Cell::new(0, 0, 0), Block::Chest, Direction::East)])
            .unwrap();
        factory.commit(&preview).unwrap();
        factory.advance(0.035).unwrap();
        let session = Session {
            world_id: [9; 16],
            world_name: "🏭".repeat(80),
            autosave_minutes: 17.0,
            autosave_retention: 8,
            player: Player {
                frame: 57,
                position: [6.0, 1.5, 4.0],
                velocity: [1.0, -2.0, 3.0],
                spawn: [1.0, 2.0, 3.0],
                body_rotation: [0.1, 0.2, 0.3],
                view_rotation: [0.4, 0.5, 0.6],
                tool: 13,
                build_rotation: 3,
                free_view: true,
                free_position: [8.0, 7.0, 6.0],
                free_rotation: [0.7, 0.8, 0.9],
            },
        };
        let mut store = Store::open(&root).unwrap();
        let entry = store
            .save(
                capture(&factory, &session).unwrap(),
                SaveRequest {
                    name: "候选恢复".into(),
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
            limits,
            root.clone(),
        )
        .unwrap();
        Self {
            runtime,
            root,
            id: entry.id,
            session,
            clock: factory.clock(),
            revision: factory.revision(),
            bounds,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        stop(&self.runtime);
        std::fs::remove_dir_all(&self.root).unwrap();
    }
}
fn input(request_id: u64, command: Command) -> Input {
    Input {
        request_id,
        command,
    }
}
fn old_frame() -> Command {
    Command::Frame(Frame {
        frame_seq: 1,
        delta: 0.02,
    })
}

#[test]
fn prepared_candidate_preserves_both_rules_and_full_session_without_switching_or_advancing() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let f = Fixture::new(ruleset, Limits::default());
        run(&f.runtime, 1, 1, old_frame());
        run(&f.runtime, 1, 2, Command::Pause);
        let before = page(&f.runtime, 0).timing;
        assert_eq!(
            run(&f.runtime, 1, 3, Command::PrepareLoad(f.id.clone())).outcome,
            Outcome::LoadPrepared { job_id: 3 }
        );
        assert_eq!(
            run(&f.runtime, 1, 4, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        assert_eq!(page(&f.runtime, 0).timing, before);
        let candidate = retry(|| f.runtime.poll_candidate(1, 3, 704)).unwrap();
        assert_eq!(candidate.job_id, 3);
        assert_eq!(candidate.session, f.session);
        assert_eq!(candidate.ruleset, ruleset);
        assert_eq!(candidate.clock, f.clock);
        assert_eq!(candidate.revision, f.revision);
        assert_eq!(candidate.bounds, f.bounds);
        assert_eq!(
            retry(|| f
                .runtime
                .submit(1, &input(5, Command::Cell(Cell::new(40, 0, 0))))),
            Err(Error::OutOfBounds),
            "candidate bounds do not yet replace the active world's boundary"
        );
        assert_eq!(candidate.bytes, 704);
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)).unwrap(),
            candidate
        );
        assert!(page(&f.runtime, 192).results.is_empty());
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)).unwrap(),
            candidate
        );
        assert!(retry(|| f.runtime.cancel(1, 3)).unwrap());
        let cancelled = take(&f.runtime);
        assert_eq!(
            cancelled.outcome,
            Outcome::LoadFailed {
                job_id: 3,
                error: SaveError::Cancelled
            }
        );
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)),
            Err(Error::InvalidArgument)
        );
        assert_eq!(page(&f.runtime, 0).timing, before);
        run(&f.runtime, 1, 5, Command::Resume);
        assert!(!page(&f.runtime, 0).timing.paused);
    }
}

#[test]
fn preparation_requires_pause_and_freezes_mutations_atomically_until_cancelled() {
    let f = Fixture::new(Ruleset::LegacyDiscreteV1, Limits::default());
    assert_eq!(
        retry(|| f
            .runtime
            .submit(1, &input(1, Command::PrepareLoad(f.id.clone())))),
        Err(Error::NotPaused)
    );
    run(&f.runtime, 1, 1, Command::Pause);
    for id in ["../outside", "", "A1234567890123456789012345678901"] {
        assert_eq!(
            retry(|| f
                .runtime
                .submit(1, &input(2, Command::PrepareLoad(id.into())))),
            Err(Error::InvalidArgument)
        );
        assert!(page(&f.runtime, 192).results.is_empty());
    }
    let prepare = input(2, Command::PrepareLoad(f.id.clone()));
    retry(|| f.runtime.submit(1, &prepare)).unwrap();
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadPrepared { job_id: 2 }
    );
    for command in [
        Command::Resume,
        old_frame(),
        Command::Build(vec![(Cell::new(0, 0, 0), Block::Chest, Direction::East)]),
        Command::Remove(Cell::new(0, 0, 0)),
        Command::SetDirection(Cell::new(0, 0, 0), Direction::North),
        Command::PrepareLoad(f.id.clone()),
    ] {
        assert_eq!(
            retry(|| f.runtime.submit(1, &input(3, command.clone()))),
            Err(Error::Busy)
        );
    }
    assert_eq!(
        retry(|| f.runtime.poll_candidate(2, 2, 704)),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 3, 704)),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 2, 703)),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 2, 0)),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 2, usize::MAX))
            .unwrap()
            .session,
        f.session
    );
}

#[test]
fn failed_load_releases_candidate_reservation_and_keeps_old_state_paused() {
    for (id, limits, error) in [
        (
            Some("11111111111111111111111111111111"),
            Limits::default(),
            SaveError::Invalid,
        ),
        (
            None,
            Limits {
                candidate_bytes: 703,
                ..Limits::default()
            },
            SaveError::Failed,
        ),
    ] {
        let f = Fixture::new(Ruleset::LegacyDiscreteV1, limits);
        run(&f.runtime, 1, 1, old_frame());
        run(&f.runtime, 1, 2, Command::Pause);
        let before = page(&f.runtime, 0).timing;
        let result = run(
            &f.runtime,
            1,
            3,
            Command::PrepareLoad(id.unwrap_or(&f.id).into()),
        );
        assert_eq!(result.outcome, Outcome::LoadFailed { job_id: 3, error });
        assert_eq!(page(&f.runtime, 0).timing, before);
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)),
            Err(Error::InvalidArgument)
        );
        run(&f.runtime, 1, 4, Command::Resume);
        assert!(!page(&f.runtime, 0).timing.paused);
    }
}
