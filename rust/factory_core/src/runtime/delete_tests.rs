//! Delete cancellation and shutdown at real transaction stages.
use super::*;
use crate::persistence::{
    capture,
    jobs::Service,
    store::{Fault, Kind, Store, new_id, parse_id},
};
use std::sync::mpsc::{self, Receiver, SyncSender};
use tests::{retry, run, stop, submit, take};

struct Fixture {
    runtime: Runtime,
    root: PathBuf,
    id: String,
    entered: Receiver<()>,
    release: SyncSender<()>,
}
impl Fixture {
    fn new(ruleset: Ruleset, stage: Option<&'static str>, injected: Option<Fault>) -> Self {
        let root = std::env::temp_dir().join(format!("factory-runtime-delete-{}", new_id()));
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let factory = Factory::new(Bounds::default(), settings, ruleset).unwrap();
        let mut store = Store::open(&root).unwrap();
        let entry = store
            .save(
                capture(
                    &factory,
                    &Session {
                        world_id: [7; 16],
                        world_name: "删除世界".into(),
                        autosave_minutes: 5.0,
                        autosave_retention: 3,
                        player: Player::default(),
                    },
                )
                .unwrap(),
                SaveRequest {
                    name: "待删档案".into(),
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
        let shared = runtime._shared.clone();
        let done = shared.clone();
        let directory = root.clone();
        let (entered, waiting) = mpsc::sync_channel(1);
        let (release, resume) = mpsc::sync_channel(1);
        crate::thread_lifecycle::spawn(
            "factory-delete-test",
            move || {
                supervise(&shared, 1, || {
                    let factory = Factory::new(Bounds::default(), settings, ruleset)?;
                    let io = Service::with_observer_and_fault(
                        directory,
                        move |name| {
                            if Some(name) == stage {
                                entered.send(()).unwrap();
                                resume.recv_timeout(Duration::from_secs(5)).unwrap();
                            }
                        },
                        injected,
                    )
                    .unwrap();
                    run_commands_with_io(
                        &shared,
                        1,
                        factory,
                        Some(SaveWorker::from_service(io)),
                        execute,
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
        Self {
            runtime,
            root,
            id: entry.id,
            entered: waiting,
            release,
        }
    }
    fn delete(&self, id: u64, expected: u64) {
        submit(
            &self.runtime,
            &Input {
                request_id: id,
                command: Command::Delete(self.id.clone(), expected),
            },
        );
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
fn delete_owns_the_operation_until_terminal_is_taken() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let f = Fixture::new(ruleset, None, None);
        f.delete(1, 1);
        assert_eq!(f.runtime.submit(1, &tests::query(2)), Err(Error::Busy));
        assert_eq!(
            take(&f.runtime).outcome,
            Outcome::DeleteCompleted {
                job_id: 1,
                save_id: parse_id(&f.id).unwrap(),
                directory_sequence: 2
            }
        );
        assert_eq!(
            run(&f.runtime, 2, Command::ListDirectory).outcome,
            Outcome::DirectoryReady {
                job_id: 2,
                directory_sequence: 2,
                entry_count: 0
            }
        );
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
    }
}

#[test]
fn stale_delete_preserves_archive() {
    let f = Fixture::new(Ruleset::LegacyDiscreteV1, None, None);
    f.delete(1, 0);
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::DeleteFailed {
            job_id: 1,
            error: SaveError::StaleDirectory
        }
    );
    stop(&f.runtime);
    let mut store = Store::open(&f.root).unwrap();
    assert_eq!(store.list().unwrap().sequence, 1);
    assert!(store.load(&f.id).is_ok());
}

#[test]
fn delete_cancel_uses_the_existing_job_and_does_not_release_its_operation() {
    for (stage, cancelled) in [("Queued", true), ("Committing", false)] {
        let f = Fixture::new(Ruleset::LegacyDiscreteV1, Some(stage), None);
        f.delete(1, 1);
        f.entered.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(retry(|| f.runtime.cancel(1, 1)).unwrap(), cancelled);
        assert_eq!(retry(|| f.runtime.cancel(1, 1)).unwrap(), cancelled);
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
        assert_eq!(f.runtime.submit(1, &tests::query(2)), Err(Error::Busy));
        f.release.send(()).unwrap();
        assert_eq!(
            take(&f.runtime).outcome,
            if cancelled {
                Outcome::DeleteFailed {
                    job_id: 1,
                    error: SaveError::Cancelled,
                }
            } else {
                Outcome::DeleteCompleted {
                    job_id: 1,
                    save_id: parse_id(&f.id).unwrap(),
                    directory_sequence: 2,
                }
            }
        );
        stop(&f.runtime);
        let mut store = Store::open(&f.root).unwrap();
        assert_eq!(
            store.list().unwrap().sequence,
            if cancelled { 1 } else { 2 }
        );
        assert_eq!(store.load(&f.id).is_ok(), cancelled);
    }
}

#[test]
fn invalid_delete_is_unaccepted_and_candidate_blocks_delete() {
    let mut r = tests::host(Limits::default());
    r._persistence = true;
    for command in [
        Command::Delete("bad".into(), 0),
        Command::Delete(new_id(), u64::MAX),
    ] {
        assert_eq!(
            r.submit(
                1,
                &Input {
                    request_id: 1,
                    command
                }
            ),
            Err(Error::InvalidArgument)
        );
        assert!(r._shared.lock().operation.is_none());
    }
    r._shared.lock().candidate = Some(CandidateSlot {
        job_id: 3,
        cancellation: Cancellation::default(),
        payload: None,
        ready_requested: false,
        next_epoch: None,
        switch_requested: false,
    });
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 1,
                command: Command::Delete(new_id(), 0)
            }
        ),
        Err(Error::Busy)
    );
}

#[test]
fn delete_failure_after_commit_reports_real_disk_or_uncertain_terminal() {
    for (injected, error, sequence, present) in [
        (Fault::BeforeIndexRename, SaveError::Disk, 1, true),
        (
            Fault::AfterIndexRename,
            SaveError::CommitUncertain,
            2,
            false,
        ),
    ] {
        let f = Fixture::new(
            Ruleset::LegacyDiscreteV1,
            Some("Committing"),
            Some(injected),
        );
        f.delete(1, 1);
        f.entered.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(!retry(|| f.runtime.cancel(1, 1)).unwrap());
        f.release.send(()).unwrap();
        assert_eq!(
            take(&f.runtime).outcome,
            Outcome::DeleteFailed { job_id: 1, error }
        );
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
        stop(&f.runtime);
        let mut store = Store::open(&f.root).unwrap();
        assert_eq!(store.list().unwrap().sequence, sequence);
        assert_eq!(store.load(&f.id).is_ok(), present);
    }
}

#[test]
fn close_waits_for_delete_io_and_preserves_commit_boundary() {
    for (stage, sequence, present) in [("Queued", 1, true), ("Committing", 2, false)] {
        let f = Fixture::new(Ruleset::LegacyDiscreteV1, Some(stage), None);
        f.delete(1, 1);
        f.entered.recv_timeout(Duration::from_secs(5)).unwrap();
        f.runtime.close();
        assert!(!f.runtime.is_stopped());
        assert_eq!(f.runtime.submit(1, &tests::query(2)), Err(Error::Closed));
        f.release.send(()).unwrap();
        stop(&f.runtime);
        let mut store = Store::open(&f.root).unwrap();
        assert_eq!(store.list().unwrap().sequence, sequence);
        assert_eq!(store.load(&f.id).is_ok(), present);
    }
}

#[test]
fn retained_directory_stays_a_snapshot_after_delete() {
    let f = Fixture::new(Ruleset::LegacyDiscreteV1, None, None);
    run(&f.runtime, 1, Command::ListDirectory);
    let before = retry(|| {
        f.runtime
            .poll_directory(1, 1, 0, DirectoryLimits::default())
    })
    .unwrap();
    f.delete(2, 1);
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::DeleteCompleted {
            directory_sequence: 2,
            ..
        }
    ));
    assert_eq!(
        retry(|| f
            .runtime
            .poll_directory(1, 1, 0, DirectoryLimits::default()))
        .unwrap(),
        before
    );
    assert_eq!(before.entries[0].id, f.id);
}
