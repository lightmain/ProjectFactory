//! Load phase ordering, faults and independent disk/candidate cancellation.
use super::*;

fn prepared() -> (Runtime, Factory, WorkerState) {
    let mut runtime = tests::host(Limits::default());
    runtime._persistence = true;
    runtime._shared.lock().timing.paused = true;
    runtime
        .submit(
            1,
            &Input {
                request_id: 2,
                command: Command::PrepareLoad("01".repeat(16)),
            },
        )
        .unwrap();
    let settings = Settings {
        interval: 0.1,
        amount: 1,
    };
    let active = Factory::new(Bounds::default(), settings, Ruleset::LegacyDiscreteV1).unwrap();
    let mut saved =
        Factory::new(Bounds::default(), settings, Ruleset::ConveyorContinuousV1).unwrap();
    let preview = saved
        .preview(&[(Cell::new(0, 0, 0), Block::Chest, Direction::East)])
        .unwrap();
    saved.commit(&preview).unwrap();
    saved.advance(0.035).unwrap();
    let state = WorkerState {
        timing: Timing {
            paused: true,
            ..Timing::default()
        },
        candidate: Some(Candidate {
            factory: saved,
            session: Session {
                world_id: [3; 16],
                world_name: "排序候选".into(),
                autosave_minutes: 7.0,
                autosave_retention: 5,
                player: Player {
                    frame: 31,
                    ..Player::default()
                },
            },
        }),
        ..WorkerState::default()
    };
    {
        let mut mailbox = runtime._shared.lock();
        mailbox.status = Status::Running;
        mailbox.pending = false;
        mailbox.candidate.as_mut().unwrap().payload =
            Some(state.candidate.as_ref().unwrap().info(2));
        mailbox.publish(1, 2, 0, Outcome::LoadPrepared { job_id: 2 });
    }
    assert_eq!(
        tests::take(&runtime).outcome,
        Outcome::LoadPrepared { job_id: 2 }
    );
    (runtime, active, state)
}
fn phase(
    r: &Runtime,
    active: &mut Factory,
    state: &mut WorkerState,
    id: u64,
    command: Command,
) -> Completion {
    r.submit(
        1,
        &Input {
            request_id: id,
            command: command.clone(),
        },
    )
    .unwrap();
    {
        let mut m = r._shared.lock();
        m.pending = false;
        let outcome = controls::execute(&mut m, state, active, command);
        let epoch = m.epoch;
        m.publish(epoch, id, active.revision(), outcome);
    }
    tests::take(r)
}
fn ready() -> Command {
    Command::PresentationReady { job_id: 2 }
}
fn switch() -> Command {
    Command::SwitchApplied {
        job_id: 2,
        next_epoch: 2,
    }
}

#[test]
fn cancel_before_ready_discards_candidate_and_unfreezes_old_world() {
    let (r, mut active, mut state) = prepared();
    assert!(r.cancel(1, 2).unwrap());
    let result = phase(&r, &mut active, &mut state, 3, ready());
    assert_eq!(
        result.outcome,
        Outcome::LoadFailed {
            job_id: 2,
            error: SaveError::Cancelled
        }
    );
    assert_eq!(result.world_epoch, 1);
    assert!(state.candidate.is_none());
    assert_eq!(active.world().block(Cell::new(0, 0, 0)), Block::Air);
    r.submit(1, &tests::query(4)).unwrap();
}

#[test]
fn ready_acceptance_closes_cancellation_and_freezes_all_ordinary_operations() {
    let (r, mut active, mut state) = prepared();
    r.submit(
        1,
        &Input {
            request_id: 3,
            command: ready(),
        },
    )
    .unwrap();
    assert!(!r.cancel(1, 2).unwrap());
    let frozen = [
        Command::Cell(Cell::new(0, 0, 0)),
        Command::Pause,
        Command::Resume,
        Command::ListDirectory,
        Command::Remove(Cell::new(0, 0, 0)),
        Command::SetDirection(Cell::new(0, 0, 0), Direction::East),
        Command::Build(vec![(Cell::new(0, 0, 0), Block::Chest, Direction::East)]),
        Command::PrepareLoad("01".repeat(16)),
        Command::Frame(Frame {
            frame_seq: 1,
            delta: 0.0,
        }),
    ];
    for command in &frozen {
        assert_eq!(
            r.submit(
                1,
                &Input {
                    request_id: 4,
                    command: command.clone()
                }
            ),
            Err(Error::Busy)
        );
    }
    {
        let mut m = r._shared.lock();
        m.pending = false;
        let outcome = controls::execute(&mut m, &mut state, &mut active, ready());
        m.publish(1, 3, 0, outcome);
    }
    assert_eq!(
        tests::take(&r).outcome,
        Outcome::CommitDecided {
            job_id: 2,
            next_epoch: 2
        }
    );
    for command in frozen {
        assert_eq!(
            r.submit(
                1,
                &Input {
                    request_id: 4,
                    command
                }
            ),
            Err(Error::Busy)
        );
    }
    assert_eq!(active.world().block(Cell::new(0, 0, 0)), Block::Air);
    assert!(state.candidate.is_some());
}

#[test]
fn switch_requires_a_decision_and_atomically_replaces_clock_and_epoch() {
    let (r, mut active, mut state) = prepared();
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 3,
                command: switch()
            }
        ),
        Err(Error::NotReady)
    );
    phase(&r, &mut active, &mut state, 3, ready());
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 4,
                command: Command::SwitchApplied {
                    job_id: 2,
                    next_epoch: 3
                }
            }
        ),
        Err(Error::InvalidArgument)
    );
    let expected_clock = state.candidate.as_ref().unwrap().factory.clock();
    let result = phase(&r, &mut active, &mut state, 4, switch());
    assert_eq!(result.world_epoch, 2);
    assert_eq!(
        result.outcome,
        Outcome::LoadCompleted {
            job_id: 2,
            next_epoch: 2
        }
    );
    assert_eq!(active.world().block(Cell::new(0, 0, 0)), Block::Chest);
    assert_eq!(state.timing.clock, expected_clock);
    assert_eq!(state.timing.completed_frame, 31);
    assert!(state.timing.paused);
    assert_eq!(r.cancel(1, 2), Err(Error::StaleEpoch));
}

#[test]
fn ready_waits_for_an_ordinary_completion_to_be_taken() {
    let (r, mut active, mut state) = prepared();
    r.submit(1, &tests::query(3)).unwrap();
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 4,
                command: ready()
            }
        ),
        Err(Error::Busy)
    );
    r._shared.lock().publish(1, 3, 0, Outcome::Cell(Block::Air));
    assert_eq!(
        r.submit(
            1,
            &Input {
                request_id: 4,
                command: ready()
            }
        ),
        Err(Error::Busy)
    );
    tests::take(&r);
    assert_eq!(
        phase(&r, &mut active, &mut state, 4, ready()).outcome,
        Outcome::CommitDecided {
            job_id: 2,
            next_epoch: 2
        }
    );
}

#[test]
fn faults_finalize_each_pending_load_phase_once_and_keep_taken_decisions() {
    for decided in [false, true] {
        let (r, mut active, mut state) = prepared();
        if decided {
            phase(&r, &mut active, &mut state, 3, ready());
            r.submit(
                1,
                &Input {
                    request_id: 4,
                    command: switch(),
                },
            )
            .unwrap();
        } else {
            r.submit(
                1,
                &Input {
                    request_id: 3,
                    command: ready(),
                },
            )
            .unwrap();
        }
        supervise(&r._shared, 1, || panic!("handoff fault"));
        fault(&r._shared, 1);
        let p = r.poll_updates(PollLimits::default()).unwrap();
        assert_eq!(p.status, Status::Faulted);
        assert_eq!(p.world_epoch, 1);
        assert_eq!(p.results.len(), 1);
        assert_eq!(p.results[0].outcome, Outcome::Faulted);
        assert!(r._shared.lock().candidate.is_none());
        assert!(
            r.poll_updates(PollLimits::default())
                .unwrap()
                .results
                .is_empty()
        );
        assert_eq!(active.world().block(Cell::new(0, 0, 0)), Block::Air);
    }
}

#[test]
fn supervisor_fault_after_switch_uses_the_current_epoch() {
    let (r, mut active, mut state) = prepared();
    phase(&r, &mut active, &mut state, 3, ready());
    phase(&r, &mut active, &mut state, 4, switch());
    r.submit(2, &tests::query(5)).unwrap();
    supervise(&r._shared, 1, || panic!("new world fault"));
    let p = r.poll_updates(PollLimits::default()).unwrap();
    assert_eq!(p.world_epoch, 2);
    assert_eq!(p.results[0].world_epoch, 2);
    assert_eq!(p.results[0].outcome, Outcome::Faulted);
}

#[test]
fn candidate_cancel_cannot_overwrite_an_independent_directory_job_or_terminal() {
    let (r, _, mut state) = prepared();
    r.submit(
        1,
        &Input {
            request_id: 3,
            command: Command::ListDirectory,
        },
    )
    .unwrap();
    assert!(r.cancel(1, 2).unwrap());
    controls::discard_cancelled(&mut r._shared.lock(), &mut state);
    assert_eq!(r._shared.lock().disk_slot, Some(3));
    assert!(state.candidate.is_some());
    r._shared.lock().publish(
        1,
        3,
        0,
        Outcome::DirectoryReady {
            job_id: 3,
            directory_sequence: 0,
            entry_count: 0,
        },
    );
    controls::discard_cancelled(&mut r._shared.lock(), &mut state);
    assert_eq!(tests::take(&r).request_id, 3);
    controls::discard_cancelled(&mut r._shared.lock(), &mut state);
    assert_eq!(
        tests::take(&r).outcome,
        Outcome::LoadFailed {
            job_id: 2,
            error: SaveError::Cancelled
        }
    );
    assert!(state.candidate.is_none());
    assert!(r._shared.lock().disk_slot.is_none());
}

#[test]
fn cancelling_an_untaken_preparation_keeps_its_disk_terminal_reserved() {
    let (r, _, mut state) = prepared();
    // Reinstall the prepared notification to model cancellation winning just
    // before its first take, then publish the candidate's terminal separately.
    {
        let mut m = r._shared.lock();
        m.disk_slot = Some(2);
        m.disk_cancellation = Some(m.candidate.as_ref().unwrap().cancellation.clone());
        m.operation = Some(Record {
            input: Input {
                request_id: 2,
                command: Command::PrepareLoad("01".repeat(16)),
            },
            cancellation: m.disk_cancellation.clone(),
        });
        m.publish(1, 2, 0, Outcome::LoadPrepared { job_id: 2 });
    }
    assert!(r.cancel(1, 2).unwrap());
    controls::discard_cancelled(&mut r._shared.lock(), &mut state);
    assert_eq!(tests::take(&r).outcome, Outcome::LoadPrepared { job_id: 2 });
    assert_eq!(r._shared.lock().disk_slot, Some(2));
    assert_eq!(
        tests::take(&r).outcome,
        Outcome::LoadFailed {
            job_id: 2,
            error: SaveError::Cancelled
        }
    );
    assert!(r._shared.lock().disk_slot.is_none());
}
