//! Real I/O barriers keep pending/late cancellation and shutdown deterministic.
use super::*;
use crate::persistence::{
    jobs::Service,
    store::{Directory, Entry, Kind, Store, new_id},
};
use std::sync::mpsc::{self, Receiver, SyncSender};

struct Fixture {
    runtime: Runtime,
    root: PathBuf,
    release: SyncSender<()>,
}
impl Fixture {
    fn new(panic_io: bool) -> Self {
        let root = std::env::temp_dir().join(format!("factory-directory-stage-{}", new_id()));
        let mut runtime = tests::host(Limits::default());
        runtime._persistence = true;
        let (entered, waiting) = mpsc::sync_channel(1);
        let (release, resume): (SyncSender<()>, Receiver<()>) = mpsc::sync_channel(1);
        let shared = runtime._shared.clone();
        let done = shared.clone();
        let directory = root.clone();
        crate::thread_lifecycle::spawn(
            "factory-directory-stage-test",
            move || {
                supervise(&shared, 1, || {
                    let service = Service::with_observer(directory, move |stage| {
                        if stage == "Reading" {
                            entered.send(()).unwrap();
                            resume.recv_timeout(Duration::from_secs(5)).unwrap();
                            assert!(!panic_io, "injected directory I/O panic");
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
                    run_commands_with_io(
                        &shared,
                        1,
                        factory,
                        Some(SaveWorker::from_service(service)),
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
        let f = Self {
            runtime,
            root,
            release,
        };
        f.retry(|| {
            f.runtime.submit(
                1,
                &Input {
                    request_id: 1,
                    command: Command::ListDirectory,
                },
            )
        })
        .unwrap();
        waiting.recv_timeout(Duration::from_secs(5)).unwrap();
        f
    }
    fn retry<T>(&self, mut operation: impl FnMut() -> Result<T, Error>) -> Result<T, Error> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match operation() {
                Err(Error::Busy) if Instant::now() < deadline => std::thread::yield_now(),
                value => return value,
            }
        }
    }
    fn results(&self, count: usize) -> Page {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let page = self
                .retry(|| self.runtime.poll_updates(PollLimits::default()))
                .unwrap();
            if page.results.len() >= count {
                return page;
            }
            assert!(Instant::now() < deadline, "{page:?}");
            std::thread::yield_now();
        }
    }
    fn stop(&self) {
        self.runtime.close();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.runtime.is_stopped() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(self.runtime.is_stopped());
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.release.try_send(());
        self.stop();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn pending_directory_is_not_ready_and_cancellation_does_not_release_the_operation() {
    let f = Fixture::new(false);
    assert_eq!(
        f.retry(|| f
            .runtime
            .poll_directory(1, 1, 0, DirectoryLimits::default())),
        Err(Error::NotReady)
    );
    assert_eq!(
        f.retry(|| f.runtime.ack_directory(1, 1)),
        Err(Error::NotReady)
    );
    assert!(f.retry(|| f.runtime.cancel(1, 1)).unwrap());
    assert!(
        f.retry(|| f.runtime.poll_updates(PollLimits::default()))
            .unwrap()
            .results
            .is_empty()
    );
    assert_eq!(f.runtime.submit(1, &tests::query(2)), Err(Error::Busy));
    f.release.send(()).unwrap();
    let terminal = tests::take(&f.runtime);
    assert_eq!(
        terminal.outcome,
        Outcome::DirectoryFailed {
            job_id: 1,
            error: SaveError::Cancelled
        }
    );
    assert_eq!(
        f.retry(|| f
            .runtime
            .poll_directory(1, 1, 0, DirectoryLimits::default())),
        Err(Error::InvalidArgument)
    );
}

#[test]
fn completed_empty_directory_can_be_consumed_and_late_cancel_keeps_its_payload() {
    let f = Fixture::new(false);
    f.release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match f.retry(|| {
            f.runtime
                .poll_directory(1, 1, 0, DirectoryLimits::default())
        }) {
            Err(Error::NotReady) if Instant::now() < deadline => std::thread::yield_now(),
            data => {
                data.unwrap();
                break;
            }
        }
    }
    assert!(!f.retry(|| f.runtime.cancel(1, 1)).unwrap());
    assert!(matches!(
        tests::take(&f.runtime).outcome,
        Outcome::DirectoryReady { job_id: 1, .. }
    ));
    let data = f
        .retry(|| {
            f.runtime
                .poll_directory(1, 1, 0, DirectoryLimits::default())
        })
        .unwrap();
    assert!(data.entries.is_empty());
    assert_eq!(data.next_offset, 0);
    f.retry(|| f.runtime.ack_directory(1, 1)).unwrap();
}

#[test]
fn close_is_nonblocking_and_waits_for_the_reading_child_before_reporting_stopped() {
    let f = Fixture::new(false);
    let started = Instant::now();
    f.runtime.close();
    assert!(started.elapsed() < Duration::from_millis(100));
    assert!(
        !f.runtime.is_stopped(),
        "child is still blocked at the disk stage"
    );
    assert_eq!(
        f.runtime
            .poll_directory(1, 1, 0, DirectoryLimits::default()),
        Err(Error::Closed)
    );
    f.release.send(()).unwrap();
    f.stop();
    assert!(
        Store::open(&f.root)
            .unwrap()
            .list()
            .unwrap()
            .entries
            .is_empty(),
        "the directory lock is released after actual child reclamation"
    );
}

#[test]
fn io_panic_is_one_fixed_failure_and_does_not_fault_the_world() {
    let f = Fixture::new(true);
    f.release.send(()).unwrap();
    let page = f.results(1);
    assert_eq!(page.status, Status::Running);
    assert!(page.results.iter().any(|r| r.outcome
        == Outcome::DirectoryFailed {
            job_id: 1,
            error: SaveError::Failed,
        }));
    assert_eq!(
        tests::run(&f.runtime, 2, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
}

fn retained_metadata(name: String, world_name: String) -> Runtime {
    let mut runtime = tests::host(Limits::default());
    runtime._persistence = true;
    runtime
        .submit(
            1,
            &Input {
                request_id: 1,
                command: Command::ListDirectory,
            },
        )
        .unwrap();
    let entries = (0..65)
        .map(|index| Entry {
            id: format!("{index:032x}"),
            payload: format!("{:032x}", index + 100),
            name: name.clone(),
            world_id: [7; 16],
            world_name: world_name.clone(),
            ruleset: Ruleset::LegacyDiscreteV1,
            saved_at: 1000.0 + f64::from(index),
            kind: Kind::Manual,
        })
        .collect();
    let mut mailbox = runtime._shared.lock();
    mailbox.directory.as_mut().unwrap().payload = Some(Directory {
        sequence: 65,
        entries,
    });
    mailbox.publish(
        1,
        1,
        0,
        Outcome::DirectoryReady {
            job_id: 1,
            directory_sequence: 65,
            entry_count: 65,
        },
    );
    drop(mailbox);
    runtime
}

#[test]
fn directory_ack_matches_identity_even_when_requests_decrease() {
    let runtime = retained_metadata("存档".into(), "世界".into());
    {
        let mut mailbox = runtime._shared.lock();
        mailbox.directory.as_mut().unwrap().job_id = 41;
    }
    runtime.ack_directory(1, 41).unwrap();
    tests::take(&runtime);
    runtime
        .submit(
            1,
            &Input {
                request_id: 6,
                command: Command::ListDirectory,
            },
        )
        .unwrap();
    {
        let mut mailbox = runtime._shared.lock();
        mailbox.directory.as_mut().unwrap().payload = Some(Directory {
            sequence: 65,
            entries: vec![],
        });
        mailbox.publish(
            1,
            6,
            0,
            Outcome::DirectoryReady {
                job_id: 6,
                directory_sequence: 65,
                entry_count: 0,
            },
        );
    }
    tests::take(&runtime);
    // An earlier receipt must not acknowledge the active payload.
    runtime.ack_directory(1, 41).unwrap();
    assert!(
        runtime
            .poll_directory(1, 6, 0, DirectoryLimits::default())
            .is_ok()
    );
    runtime.ack_directory(1, 6).unwrap();
    assert_eq!(
        runtime.poll_directory(1, 6, 0, DirectoryLimits::default()),
        Err(Error::InvalidArgument)
    );
    runtime.ack_directory(1, 6).unwrap();
    assert!(
        runtime
            .submit(
                1,
                &Input {
                    request_id: 3,
                    command: Command::ListDirectory
                }
            )
            .is_ok()
    );
}

#[test]
fn oversized_requested_pages_still_obey_both_hard_limits() {
    // Pure metadata fixtures exercise the actual host boundary without saving
    // dozens of complete factories merely to test copying a directory page.
    let limits = DirectoryLimits {
        entry_count: usize::MAX,
        entry_bytes: usize::MAX,
    };
    let short = retained_metadata("a".repeat(10), "w".repeat(10));
    let page = short.poll_directory(1, 1, 0, limits).unwrap();
    assert_eq!(page.entries.len(), 64);
    assert_eq!(page.entry_bytes, 64 * 180);
    assert_eq!(page.next_offset, 64);
    assert_eq!(
        short
            .poll_directory(1, 1, 64, limits)
            .unwrap()
            .entries
            .len(),
        1
    );

    let long = retained_metadata("🚚".repeat(160), "🏭".repeat(80));
    let page = long.poll_directory(1, 1, 0, limits).unwrap();
    assert_eq!(page.entries.len(), 58);
    assert_eq!(page.entry_bytes, 58 * 1120);
    assert!(page.entry_bytes <= 64 * 1024);
    assert_eq!(page.next_offset, 58);
    assert_eq!(
        long.poll_directory(1, 1, 58, limits).unwrap().entries.len(),
        7
    );
}

#[test]
fn exact_entry_byte_budget_keeps_whole_entries_and_one_byte_less_rejects_or_stops() {
    let runtime = retained_metadata("🚚".repeat(160), "🏭".repeat(80));
    for (budget, count) in [(1120, 1), (2240, 2), (2239, 1)] {
        let page = runtime
            .poll_directory(
                1,
                1,
                0,
                DirectoryLimits {
                    entry_count: 64,
                    entry_bytes: budget,
                },
            )
            .unwrap();
        assert_eq!(page.entries.len(), count);
        assert_eq!(page.entry_bytes, count * 1120);
        assert_eq!(page.next_offset, count);
    }
    assert_eq!(
        runtime.poll_directory(
            1,
            1,
            0,
            DirectoryLimits {
                entry_count: 64,
                entry_bytes: 1119,
            }
        ),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        runtime
            .poll_directory(
                1,
                1,
                0,
                DirectoryLimits {
                    entry_count: 64,
                    entry_bytes: 1120,
                }
            )
            .unwrap()
            .entries
            .len(),
        1,
        "insufficient budget never consumes a payload"
    );
}

#[test]
fn directory_calls_return_busy_without_waiting_for_the_mailbox_and_close_stays_reachable() {
    let runtime = retained_metadata("存档".into(), "世界".into());
    let guard = runtime._shared.lock();
    assert_eq!(
        runtime.poll_directory(1, 1, 0, DirectoryLimits::default()),
        Err(Error::Busy)
    );
    assert_eq!(runtime.ack_directory(1, 1), Err(Error::Busy));
    runtime.close();
    assert_eq!(
        runtime.poll_directory(1, 1, 0, DirectoryLimits::default()),
        Err(Error::Closed)
    );
    assert_eq!(runtime.ack_directory(1, 1), Err(Error::Closed));
    drop(guard);
}
