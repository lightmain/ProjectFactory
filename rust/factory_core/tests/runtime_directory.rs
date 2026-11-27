mod support;
use factory_core::{
    factory::{Factory, Ruleset},
    logistics::Settings,
    persistence::{
        Player, Session, capture,
        store::{Kind, SaveRequest, Store, new_id},
    },
    runtime::{Command, DirectoryLimits, Error, Input, Limits, Outcome, Runtime, Save, SaveError},
    world::Bounds,
};
use support::{page, retry, run, stop, take};
struct Fixture {
    runtime: Runtime,
    root: std::path::PathBuf,
}
impl Fixture {
    fn new(limits: Limits) -> Self {
        let root = std::env::temp_dir().join(format!("factory-directory-pages-{}", new_id()));
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let factory = Factory::new(Bounds::default(), settings, Ruleset::LegacyDiscreteV1).unwrap();
        let mut store = Store::open(&root).unwrap();
        for sequence in 0..4 {
            store
                .save(
                    capture(
                        &factory,
                        &Session {
                            world_id: [7; 16],
                            world_name: "目录分页世界".into(),
                            autosave_minutes: 5.0,
                            autosave_retention: 3,
                            player: Player::default(),
                        },
                    )
                    .unwrap(),
                    SaveRequest {
                        name: format!("命名档 {sequence}"),
                        overwrite: false,
                        kind: Kind::Manual,
                        retention: 3,
                        expected_sequence: sequence,
                    },
                    &mut |_| Ok(()),
                )
                .unwrap();
        }
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
        Self { runtime, root }
    }
    fn list(&self, id: u64) -> Outcome {
        run(&self.runtime, 1, id, Command::ListDirectory).outcome
    }
    fn data(
        &self,
        id: u64,
        offset: usize,
        limits: DirectoryLimits,
    ) -> Result<factory_core::runtime::DirectoryPage, Error> {
        retry(|| self.runtime.poll_directory(1, id, offset, limits))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        stop(&self.runtime);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn directory_pages_are_bounded_repeatable_and_survive_terminal_consumption() {
    let f = Fixture::new(Limits::default());
    assert_eq!(
        f.list(1),
        Outcome::DirectoryReady {
            job_id: 1,
            directory_sequence: 4,
            entry_count: 4
        }
    );
    let limits = DirectoryLimits {
        entry_count: 1,
        entry_bytes: 2048,
    };
    let first = f.data(1, 0, limits).unwrap();
    assert_eq!(first.entries.len(), 1);
    assert_eq!(
        (
            first.next_offset,
            first.total_entries,
            first.directory_sequence
        ),
        (1, 4, 4)
    );
    assert!(first.entry_bytes <= limits.entry_bytes);
    assert_eq!(f.data(1, 0, limits).unwrap(), first);
    assert!(page(&f.runtime, 192).results.is_empty());
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 2,
                command: Command::ListDirectory
            }
        )),
        Err(Error::Busy)
    );
    let mut names = vec![first.entries[0].name.clone()];
    for offset in 1..4 {
        let next = f.data(1, offset, limits).unwrap();
        assert_eq!(next.next_offset, offset + 1);
        names.push(next.entries[0].name.clone());
    }
    names.sort();
    assert_eq!(
        names,
        (0..4).map(|i| format!("命名档 {i}")).collect::<Vec<_>>()
    );
    let end = f.data(1, 4, limits).unwrap();
    assert!(end.entries.is_empty());
    assert_eq!(end.next_offset, 4);
    retry(|| f.runtime.ack_directory(1, 1)).unwrap();
    retry(|| f.runtime.ack_directory(1, 1)).unwrap();
    assert!(matches!(
        f.list(2),
        Outcome::DirectoryReady { job_id: 2, .. }
    ));
    // An old payload receipt cannot discard a newer snapshot.
    retry(|| f.runtime.ack_directory(1, 1)).unwrap();
    assert_eq!(
        f.data(2, 0, DirectoryLimits::default())
            .unwrap()
            .entries
            .len(),
        4
    );
}

#[test]
fn directory_identity_offsets_and_page_budgets_are_validated_without_losing_payload() {
    let f = Fixture::new(Limits::default());
    f.list(1);
    let limits = DirectoryLimits {
        entry_count: 1,
        entry_bytes: 2048,
    };
    assert_eq!(
        retry(|| f.runtime.poll_directory(2, 1, 0, limits)),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.ack_directory(2, 1)),
        Err(Error::StaleEpoch)
    );
    assert_eq!(
        retry(|| f.runtime.ack_directory(1, 2)),
        Err(Error::InvalidArgument)
    );
    assert_eq!(f.data(2, 0, limits), Err(Error::InvalidArgument));
    assert_eq!(f.data(1, 5, limits), Err(Error::InvalidArgument));
    assert_eq!(
        f.data(
            1,
            0,
            DirectoryLimits {
                entry_count: 0,
                ..limits
            }
        ),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        f.data(
            1,
            0,
            DirectoryLimits {
                entry_bytes: 1,
                ..limits
            }
        ),
        Err(Error::InvalidArgument)
    );
    assert_eq!(f.data(1, 0, limits).unwrap().entries.len(), 1);
}

#[test]
fn payload_receipt_before_terminal_does_not_release_the_operation() {
    let f = Fixture::new(Limits::default());
    retry(|| {
        f.runtime.submit(
            1,
            &Input {
                request_id: 1,
                command: Command::ListDirectory,
            },
        )
    })
    .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match f.data(1, 0, DirectoryLimits::default()) {
            Err(Error::NotReady) if std::time::Instant::now() < deadline => {
                std::thread::yield_now()
            }
            result => {
                result.unwrap();
                break;
            }
        }
    }
    retry(|| f.runtime.ack_directory(1, 1)).unwrap();
    assert_eq!(
        retry(|| f.runtime.submit(
            1,
            &Input {
                request_id: 2,
                command: Command::ListDirectory
            }
        )),
        Err(Error::Busy)
    );
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::DirectoryReady { job_id: 1, .. }
    ));
    assert!(matches!(
        f.list(2),
        Outcome::DirectoryReady { job_id: 2, .. }
    ));
}

#[test]
fn retained_directory_remains_a_snapshot_while_saving() {
    let f = Fixture::new(Limits::default());
    f.list(1);
    let before = f.data(1, 0, DirectoryLimits::default()).unwrap();
    run(&f.runtime, 1, 2, Command::Pause);
    let save = Save {
        player: Player::default(),
        world_id: [7; 16],
        world_name: "目录分页世界".into(),
        autosave_minutes: 5.0,
        request: SaveRequest {
            name: "新增档".into(),
            overwrite: false,
            kind: Kind::Manual,
            retention: 3,
            expected_sequence: 4,
        },
    };
    assert_eq!(
        run(&f.runtime, 1, 3, Command::Save(save)).outcome,
        Outcome::SaveStarted { job_id: 3 }
    );
    assert!(matches!(
        take(&f.runtime).outcome,
        Outcome::SaveCompleted {
            job_id: 3,
            directory_sequence: 5,
            ..
        }
    ));
    assert_eq!(f.data(1, 0, DirectoryLimits::default()).unwrap(), before);
}

#[test]
fn payload_limit_failure_keeps_disk_reservation_until_terminal_is_taken() {
    for limits in [
        Limits {
            directory_count: 3,
            ..Limits::default()
        },
        Limits {
            directory_bytes: 1,
            ..Limits::default()
        },
    ] {
        let f = Fixture::new(limits);
        retry(|| {
            f.runtime.submit(
                1,
                &Input {
                    request_id: 1,
                    command: Command::ListDirectory,
                },
            )
        })
        .unwrap();
        assert_eq!(
            retry(|| f.runtime.submit(
                1,
                &Input {
                    request_id: 2,
                    command: Command::ListDirectory
                }
            )),
            Err(Error::Busy)
        );
        assert_eq!(
            take(&f.runtime).outcome,
            Outcome::DirectoryFailed {
                job_id: 1,
                error: SaveError::Failed
            }
        );
        assert_eq!(
            f.data(1, 0, DirectoryLimits::default()),
            Err(Error::InvalidArgument)
        );
        assert_eq!(
            f.list(2),
            Outcome::DirectoryFailed {
                job_id: 2,
                error: SaveError::Failed
            }
        );
    }
}
