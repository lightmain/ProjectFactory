//! Real I/O and world-owned restore barriers.
use super::*;
use crate::persistence::{
    capture,
    jobs::Service,
    store::{Kind, Store, new_id},
};
use std::sync::mpsc::{self, SyncSender};
use std::thread::{self, ThreadId};
use tests::{retry, run, stop, submit, take};

struct Fixture {
    runtime: Runtime,
    root: PathBuf,
    release: SyncSender<()>,
    owner: ThreadId,
    observed: ThreadId,
}
impl Fixture {
    fn new(stage: &'static str, panic_stage: bool, bad_header: bool) -> Self {
        let root = std::env::temp_dir().join(format!("factory-load-stage-{}", new_id()));
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let mut saved =
            Factory::new(Bounds::default(), settings, Ruleset::ConveyorContinuousV1).unwrap();
        let preview = saved
            .preview(&[(Cell::new(0, 0, 0), Block::Chest, Direction::East)])
            .unwrap();
        saved.commit(&preview).unwrap();
        saved.advance(0.035).unwrap();
        let clock = saved.clock();
        let session = Session {
            world_id: [8; 16],
            world_name: "恢复屏障".into(),
            autosave_minutes: 5.0,
            autosave_retention: 3,
            player: Player::default(),
        };
        let mut snapshot = capture(&saved, &session).unwrap();
        if bad_header {
            snapshot.tick += 1;
        }
        let mut store = Store::open(&root).unwrap();
        let entry = store
            .save(
                snapshot,
                SaveRequest {
                    name: "恢复屏障".into(),
                    overwrite: false,
                    kind: Kind::Manual,
                    retention: 3,
                    expected_sequence: 0,
                },
                &mut |_| Ok(()),
            )
            .unwrap();
        drop(store);
        let mut runtime = tests::host(Limits::default());
        runtime._persistence = true;
        let (entered, waiting) = mpsc::sync_channel(1);
        let (release, resume) = mpsc::sync_channel(1);
        let (owner_sender, owner_receiver) = mpsc::sync_channel(1);
        let shared = runtime._shared.clone();
        let done = shared.clone();
        let directory = root.clone();
        crate::thread_lifecycle::spawn(
            "factory-load-stage-test",
            move || {
                let owner = thread::current().id();
                owner_sender.send(owner).unwrap();
                supervise(&shared, 1, || {
                    let block = move || {
                        entered.send(thread::current().id()).unwrap();
                        resume.recv_timeout(Duration::from_secs(5)).unwrap();
                        assert!(!panic_stage, "injected load stage panic");
                    };
                    let io = if stage == "Reading" {
                        SaveWorker::from_service(
                            Service::with_observer(directory, move |name| {
                                if name == "Reading" {
                                    block();
                                }
                            })
                            .unwrap(),
                        )
                    } else {
                        let mut io = SaveWorker::new(directory).unwrap();
                        io.restore_observer = Some(Box::new(move |name| {
                            if name == stage {
                                block();
                            }
                        }));
                        io
                    };
                    let factory =
                        Factory::new(Bounds::default(), settings, Ruleset::LegacyDiscreteV1)?;
                    run_commands_with_io(
                        &shared,
                        1,
                        factory,
                        Some(io),
                        move |factory, state, command| {
                            assert_eq!(thread::current().id(), owner);
                            if matches!(&command, Command::Cell(cell) if cell.x == 1) {
                                let candidate = state
                                    .candidate
                                    .as_ref()
                                    .expect("query sees restored live candidate");
                                assert_eq!(
                                    candidate.factory.world().block(Cell::new(0, 0, 0)),
                                    Block::Chest
                                );
                                assert_eq!(candidate.factory.clock(), clock);
                                assert_eq!(candidate.session, session);
                                assert_eq!(factory.world().block(Cell::new(0, 0, 0)), Block::Air);
                            }
                            execute(factory, state, command)
                        },
                    )
                });
            },
            move |clean| {
                if !clean {
                    fault(&done, 1);
                }
                done.stopped.store(true, Ordering::Release);
            },
        )
        .unwrap();
        let owner = owner_receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        run(
            &runtime,
            1,
            Command::Frame(Frame {
                frame_seq: 1,
                delta: 0.02,
            }),
        );
        run(&runtime, 2, Command::Pause);
        submit(
            &runtime,
            &Input {
                request_id: 3,
                command: Command::PrepareLoad(entry.id),
            },
        );
        let observed = waiting.recv_timeout(Duration::from_secs(5)).unwrap();
        Self {
            runtime,
            root,
            release,
            owner,
            observed,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.release.try_send(());
        stop(&self.runtime);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn cancellation_at_reading_or_restore_boundaries_never_publishes_candidate() {
    for stage in ["Reading", "BeforeRestore", "AfterRestore"] {
        let f = Fixture::new(stage, false, false);
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)),
            Err(Error::NotReady)
        );
        assert!(retry(|| f.runtime.cancel(1, 3)).unwrap());
        assert_eq!(f.runtime.submit(1, &tests::query(4)), Err(Error::Busy));
        f.release.send(()).unwrap();
        assert_eq!(
            take(&f.runtime).outcome,
            Outcome::LoadFailed {
                job_id: 3,
                error: SaveError::Cancelled
            }
        );
        let page = retry(|| f.runtime.poll_updates(PollLimits::default())).unwrap();
        assert!(page.results.is_empty());
        assert!(page.timing.paused);
        assert_eq!(page.timing.completed_frame, 1);
        assert_eq!(page.timing.clock.time, 0.02);
        assert_eq!(page.timing.revision, 0);
        assert_eq!(
            retry(|| f.runtime.poll_candidate(1, 3, 704)),
            Err(Error::InvalidArgument)
        );
    }
}

#[test]
fn close_at_all_load_boundaries_waits_for_actual_reclamation() {
    for stage in ["Reading", "BeforeRestore", "AfterRestore"] {
        let f = Fixture::new(stage, false, false);
        let started = Instant::now();
        f.runtime.close();
        assert!(started.elapsed() < Duration::from_millis(100));
        assert!(!f.runtime.is_stopped());
        assert_eq!(f.runtime.poll_candidate(1, 3, 704), Err(Error::Closed));
        f.release.send(()).unwrap();
        stop(&f.runtime);
        assert_eq!(
            Store::open(&f.root).unwrap().list().unwrap().entries.len(),
            1
        );
    }
}

#[test]
fn io_panic_is_fixed_load_failure_and_keeps_old_world_queryable() {
    let f = Fixture::new("Reading", true, false);
    f.release.send(()).unwrap();
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadFailed {
            job_id: 3,
            error: SaveError::Failed
        }
    );
    assert_eq!(
        run(&f.runtime, 4, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
    let page = retry(|| f.runtime.poll_updates(PollLimits::default())).unwrap();
    assert_eq!(page.status, Status::Running);
    assert!(page.timing.paused);
}

#[test]
fn world_panic_after_restore_drops_candidate_and_faults_pending_operation_once() {
    let f = Fixture::new("AfterRestore", true, false);
    f.release.send(()).unwrap();
    assert_eq!(take(&f.runtime).outcome, Outcome::Faulted);
    let page = retry(|| f.runtime.poll_updates(PollLimits::default())).unwrap();
    assert_eq!(page.status, Status::Faulted);
    assert!(page.results.is_empty());
    assert_eq!(
        retry(|| f.runtime.poll_candidate(1, 3, 704)),
        Err(Error::InvalidArgument)
    );
    assert_eq!(f.runtime.submit(1, &tests::query(4)), Err(Error::Faulted));
}

#[test]
fn live_factory_restoration_and_queries_stay_on_world_owner_without_advancing_candidate() {
    let f = Fixture::new("AfterRestore", false, false);
    assert_eq!(f.observed, f.owner);
    f.release.send(()).unwrap();
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadPrepared { job_id: 3 }
    );
    assert_eq!(
        run(&f.runtime, 4, Command::Cell(Cell::new(1, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
}

#[test]
fn semantic_checkpoint_mismatch_keeps_old_world_paused() {
    let f = Fixture::new("BeforeRestore", false, true);
    f.release.send(()).unwrap();
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::LoadFailed {
            job_id: 3,
            error: SaveError::Invalid
        }
    );
    assert_eq!(
        run(&f.runtime, 4, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
    assert!(
        retry(|| f.runtime.poll_updates(PollLimits::default()))
            .unwrap()
            .timing
            .paused
    );
}

#[test]
fn candidate_reservations_are_not_installed_when_the_operation_is_occupied() {
    let mut r = tests::host(Limits::default());
    r._persistence = true;
    r._shared.lock().timing.paused = true;
    r.submit(1, &tests::query(1)).unwrap();
    let prepare = Input {
        request_id: 2,
        command: Command::PrepareLoad("1".repeat(32)),
    };
    assert_eq!(r.submit(1, &prepare), Err(Error::Busy));
    {
        let mut m = r._shared.lock();
        assert!(m.candidate.is_none());
        assert!(m.disk_slot.is_none());
        m.pending = false;
        m.publish(1, 1, 0, Outcome::Cell(Block::Air));
    }
    assert_eq!(r.submit(1, &prepare), Err(Error::Busy));
    take(&r);
    r.submit(1, &prepare).unwrap();
    assert_eq!(r._shared.lock().candidate.as_ref().unwrap().job_id, 2);
    assert_eq!(r._shared.lock().disk_slot, Some(2));
}
