//! Real disk barriers exercise the job flag, independent world slot and shutdown.
use super::*;
use crate::persistence::{
    jobs::Service,
    store::{Kind, Store, new_id},
};
use std::sync::mpsc::{self, Receiver, SyncSender};
use tests::{retry, run, stop, submit, take};

fn save() -> Save {
    Save {
        player: Player {
            frame: 1,
            ..Player::default()
        },
        world_id: [7; 16],
        world_name: "阶段屏障".into(),
        autosave_minutes: 5.0,
        request: SaveRequest {
            name: "保存".into(),
            overwrite: false,
            kind: Kind::Manual,
            retention: 3,
            expected_sequence: 0,
        },
    }
}
struct Fixture {
    runtime: Runtime,
    root: PathBuf,
    release: SyncSender<()>,
    entered: Receiver<()>,
}
impl Fixture {
    fn new(stage: &'static str, panic_world: bool, panic_io: bool, take_started: bool) -> Self {
        let root = std::env::temp_dir().join(format!("factory-runtime-stage-{}", new_id()));
        let mut runtime = tests::host(Limits::default());
        runtime._persistence = true;
        let (entered, waiting) = mpsc::sync_channel(1);
        let (release, resume) = mpsc::sync_channel(1);
        let shared = runtime._shared.clone();
        let done = shared.clone();
        let directory = root.clone();
        crate::thread_lifecycle::spawn(
            "factory-save-stage-test",
            move || {
                supervise(&shared, 1, || {
                    let service = Service::with_observer(directory, move |name| {
                        if name == stage {
                            entered.send(()).unwrap();
                            resume.recv_timeout(Duration::from_secs(5)).unwrap();
                            assert!(!panic_io, "injected I/O worker panic");
                        }
                    })
                    .unwrap();
                    let factory = Factory::new(
                        Bounds::default(),
                        Settings {
                            interval: 0.1,
                            amount: 1,
                        },
                        Ruleset::LegacyDiscreteV1,
                    )?;
                    let mut executed_save = false;
                    run_commands_with_io(
                        &shared,
                        1,
                        factory,
                        Some(SaveWorker::from_service(service)),
                        |factory, state, command| {
                            // Pause executes before capture. World panic is injected by the
                            // next cell query, independently of the blocked disk worker.
                            if panic_world && matches!(command, Command::Cell(_)) {
                                panic!("injected world fault");
                            }
                            executed_save |= matches!(command, Command::Pause);
                            assert!(executed_save);
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
        let f = Self {
            runtime,
            root,
            release,
            entered: waiting,
        };
        run(&f.runtime, 1, Command::Pause);
        submit(
            &f.runtime,
            &Input {
                request_id: 2,
                command: Command::Save(save()),
            },
        );
        f.entered.recv_timeout(Duration::from_secs(5)).unwrap();
        // I/O dispatch happens before publication. Wait for the published
        // notification without taking it before injecting a world fault.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if f.runtime
                ._shared
                .lock()
                .result
                .as_ref()
                .is_some_and(|r| matches!(r.outcome, Outcome::SaveStarted { job_id: 2 }))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "capture notification not published"
            );
            std::thread::yield_now();
        }
        if take_started {
            assert_eq!(take(&f.runtime).outcome, Outcome::SaveStarted { job_id: 2 });
        }
        f
    }
    fn sequence(&self) -> u64 {
        Store::open(&self.root).unwrap().list().unwrap().sequence
    }
    fn cancellation(&self) -> Cancellation {
        self.runtime
            ._shared
            .lock()
            .disk_cancellation
            .clone()
            .unwrap()
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
fn cancellation_before_capture_never_dispatches_io() {
    let root = std::env::temp_dir().join(format!("factory-before-capture-{}", new_id()));
    let mut r = tests::host(Limits::default());
    r._persistence = true;
    r._shared.lock().timing.paused = true;
    submit(
        &r,
        &Input {
            request_id: 2,
            command: Command::Save(save()),
        },
    );
    assert!(r.cancel(1, 2).unwrap());
    let cancellation = r._shared.lock().disk_cancellation.clone().unwrap();
    let factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        Ruleset::LegacyDiscreteV1,
    )
    .unwrap();
    let mut io = SaveWorker::new(root.clone()).unwrap();
    io.capture(
        &r._shared,
        1,
        2,
        &factory,
        &WorkerState {
            timing: Timing {
                paused: true,
                ..Timing::default()
            },
            ..WorkerState::default()
        },
        save(),
        cancellation,
    );
    assert_eq!(
        take(&r).outcome,
        Outcome::SaveFailed {
            job_id: 2,
            frame_seq: 1,
            error: SaveError::Cancelled
        }
    );
    drop(io);
    assert!(!root.exists());
}

#[test]
fn cancellation_competes_with_real_commit_and_world_commands_continue_after_capture() {
    for (stage, cancelled) in [("Encoding", true), ("Committing", false)] {
        let f = Fixture::new(stage, false, false, true);
        assert_eq!(
            run(&f.runtime, 3, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        assert_eq!(retry(|| f.runtime.cancel(1, 2)).unwrap(), cancelled);
        assert_eq!(retry(|| f.runtime.cancel(1, 2)).unwrap(), cancelled);
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
        assert_eq!(
            f.runtime.submit(
                1,
                &Input {
                    request_id: 4,
                    command: Command::Save(save())
                }
            ),
            Err(Error::Busy)
        );
        f.release.send(()).unwrap();
        let result = take(&f.runtime);
        assert_eq!(result.request_id, 2);
        if cancelled {
            assert_eq!(
                result.outcome,
                Outcome::SaveFailed {
                    job_id: 2,
                    frame_seq: 1,
                    error: SaveError::Cancelled
                }
            );
        } else {
            assert!(matches!(
                result.outcome,
                Outcome::SaveCompleted {
                    job_id: 2,
                    frame_seq: 1,
                    directory_sequence: 1,
                    ..
                }
            ));
        }
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
        stop(&f.runtime);
        assert_eq!(f.sequence(), u64::from(!cancelled));
    }
}

#[test]
fn close_waits_for_child_io_and_keeps_a_committing_save() {
    for (stage, sequence) in [("Encoding", 0), ("Committing", 1)] {
        let f = Fixture::new(stage, false, false, true);
        let cancellation = f.cancellation();
        f.runtime.close();
        assert!(!f.runtime.is_stopped());
        assert_eq!(f.runtime.cancel(1, 2), Err(Error::Closed));
        if sequence == 0 {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !cancellation.is_cancelled() && Instant::now() < deadline {
                std::thread::yield_now();
            }
            assert!(cancellation.is_cancelled());
        }
        f.release.send(()).unwrap();
        stop(&f.runtime);
        assert_eq!(f.sequence(), sequence);
    }
}

#[test]
fn world_fault_reaps_child_and_finalizes_the_disk_job_once() {
    for (stage, sequence) in [("Encoding", 0), ("Committing", 1)] {
        let f = Fixture::new(stage, true, false, true);
        submit(&f.runtime, &tests::query(3));
        assert!(!f.runtime.is_stopped());
        f.release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !f.runtime.is_stopped() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(f.runtime.is_stopped());
        let results = retry(|| f.runtime.poll_updates(PollLimits::default())).unwrap();
        assert_eq!(results.status, Status::Faulted);
        assert_eq!(results.results.len(), 2);
        assert_eq!(
            results
                .results
                .iter()
                .map(|r| (r.request_id, r.outcome.clone()))
                .collect::<Vec<_>>(),
            [(3, Outcome::Faulted), (2, Outcome::Faulted)]
        );
        assert!(
            retry(|| f.runtime.poll_updates(PollLimits::default()))
                .unwrap()
                .results
                .is_empty()
        );
        stop(&f.runtime);
        assert_eq!(f.sequence(), sequence);
    }
}

#[test]
fn fault_before_save_started_is_taken_preserves_both_capture_and_disk_terminal() {
    let f = Fixture::new("Encoding", false, false, false);
    // Regression: the disk terminal still exists when SaveStarted owns the
    // ordinary result slot at the moment the world fails.
    fault(&f.runtime._shared, 1);
    let results = f.runtime.poll_updates(PollLimits::default()).unwrap();
    assert_eq!(results.results.len(), 2);
    assert_eq!(
        results.results[0].outcome,
        Outcome::SaveStarted { job_id: 2 }
    );
    assert_eq!(results.results[1].outcome, Outcome::Faulted);
    assert_eq!(results.results[1].request_id, 2);
    // Close the injected-fault fixture before letting the worker publish again.
    f.runtime.close();
    f.release.send(()).unwrap();
}

#[test]
fn io_panic_is_one_failed_terminal_and_world_remains_usable() {
    let f = Fixture::new("Encoding", false, true, true);
    f.release.send(()).unwrap();
    assert_eq!(
        take(&f.runtime).outcome,
        Outcome::SaveFailed {
            job_id: 2,
            frame_seq: 1,
            error: SaveError::Failed
        }
    );
    assert_eq!(
        run(&f.runtime, 3, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
    assert_eq!(
        retry(|| f.runtime.poll_updates(PollLimits::default()))
            .unwrap()
            .status,
        Status::Running
    );
    stop(&f.runtime);
    assert_eq!(f.sequence(), 0);
}
