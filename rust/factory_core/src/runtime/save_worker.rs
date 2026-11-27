//! World-owned snapshot capture and child I/O lifetime. No live factory crosses
//! into the child or the shared mailbox.
use super::{Limits, Outcome, Save, SaveError, Shared, WorkerState, directory};
use crate::{
    factory::Factory,
    persistence::{
        self,
        jobs::{Cancellation, Output, Request, Service},
        store::parse_id,
    },
};
use std::{path::PathBuf, sync::atomic::Ordering};

struct Pending {
    request_id: u64,
    io_id: u64,
    kind: PendingKind,
    tick: i64,
    revision: u64,
}
enum PendingKind {
    Save {
        frame_seq: u64,
        directory_sequence: u64,
    },
    List,
    Delete {
        save_id: [u8; 16],
        directory_sequence: u64,
    },
    Load {
        cancellation: Cancellation,
    },
}
#[cfg(test)]
type RestoreObserver = Box<dyn FnMut(&str)>;
pub(super) struct SaveWorker {
    service: Service,
    pending: Option<Pending>,
    limits: Limits,
    #[cfg(test)]
    pub(super) restore_observer: Option<RestoreObserver>,
}
impl SaveWorker {
    #[cfg(test)]
    pub(super) fn new(root: PathBuf) -> Result<Self, persistence::Error> {
        Ok(Self::from_service(Service::new(root)?))
    }
    pub(super) fn with_limits(root: PathBuf, limits: Limits) -> Result<Self, persistence::Error> {
        Ok(Self {
            service: Service::new(root)?,
            pending: None,
            limits,
            #[cfg(test)]
            restore_observer: None,
        })
    }
    #[cfg(test)]
    pub(super) fn from_service(service: Service) -> Self {
        Self {
            service,
            pending: None,
            limits: Limits::default(),
            restore_observer: None,
        }
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) fn capture(
        &mut self,
        shared: &Shared,
        epoch: u64,
        seq: u64,
        factory: &Factory,
        state: &WorkerState,
        save: Save,
        cancellation: Cancellation,
    ) {
        self.capture_with(
            shared,
            epoch,
            seq,
            factory,
            state,
            save,
            cancellation,
            persistence::capture,
        );
    }
    #[allow(clippy::too_many_arguments)]
    fn capture_with(
        &mut self,
        shared: &Shared,
        epoch: u64,
        seq: u64,
        factory: &Factory,
        state: &WorkerState,
        save: Save,
        cancellation: Cancellation,
        capture: impl FnOnce(
            &Factory,
            &crate::persistence::Session,
        ) -> Result<crate::persistence::Snapshot, persistence::Error>,
    ) {
        let tick = factory.clock().tick;
        let revision = factory.revision();
        let frame_seq = save.player.frame;
        let failed = |error| Outcome::SaveFailed {
            job_id: seq,
            frame_seq,
            error,
        };
        let result = (|| {
            if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                return Err(failed(SaveError::Cancelled));
            }
            if !state.timing.paused {
                return Err(failed(SaveError::Invalid));
            }
            let snapshot = capture(factory, &save.session()).map_err(|e| failed(error_code(e)))?;
            if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                return Err(failed(SaveError::Cancelled));
            }
            let directory_sequence = save
                .request
                .expected_sequence
                .checked_add(1)
                .ok_or(failed(SaveError::Invalid))?;
            let io_id = self
                .service
                .submit_with_cancellation(
                    Request::Save(Box::new(snapshot), save.request),
                    cancellation,
                )
                .map_err(|e| failed(error_code(e)))?;
            self.pending = Some(Pending {
                request_id: seq,
                io_id,
                kind: PendingKind::Save {
                    frame_seq,
                    directory_sequence,
                },
                tick,
                revision,
            });
            shared.lock().publish_at(
                epoch,
                seq,
                tick,
                revision,
                Outcome::SaveStarted { job_id: seq },
            );
            Ok(())
        })();
        if let Err(outcome) = result
            && !shared.closing.load(Ordering::Acquire)
        {
            shared
                .lock()
                .publish_at(epoch, seq, tick, revision, outcome);
        }
    }
    pub(super) fn list(
        &mut self,
        shared: &Shared,
        epoch: u64,
        seq: u64,
        factory: &Factory,
        cancellation: Cancellation,
    ) {
        let result = if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
            Err(persistence::Error::Cancelled)
        } else {
            self.service
                .submit_with_cancellation(Request::List, cancellation)
        };
        match result {
            Ok(io_id) => {
                self.pending = Some(Pending {
                    request_id: seq,
                    io_id,
                    kind: PendingKind::List,
                    tick: factory.clock().tick,
                    revision: factory.revision(),
                });
            }
            Err(error) if !shared.closing.load(Ordering::Acquire) => {
                shared.lock().publish_at(
                    epoch,
                    seq,
                    factory.clock().tick,
                    factory.revision(),
                    Outcome::DirectoryFailed {
                        job_id: seq,
                        error: error_code(error),
                    },
                );
            }
            Err(_) => {}
        }
    }
    pub(super) fn load(
        &mut self,
        shared: &Shared,
        epoch: u64,
        seq: u64,
        factory: &Factory,
        id: String,
        cancellation: Cancellation,
    ) {
        let result = if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
            Err(persistence::Error::Cancelled)
        } else {
            self.service
                .submit_with_cancellation(Request::Load(id), cancellation.clone())
        };
        match result {
            Ok(io_id) => {
                self.pending = Some(Pending {
                    request_id: seq,
                    io_id,
                    kind: PendingKind::Load { cancellation },
                    tick: factory.clock().tick,
                    revision: factory.revision(),
                })
            }
            Err(error) if !shared.closing.load(Ordering::Acquire) => {
                shared.lock().publish_at(
                    epoch,
                    seq,
                    factory.clock().tick,
                    factory.revision(),
                    Outcome::LoadFailed {
                        job_id: seq,
                        error: error_code(error),
                    },
                );
            }
            Err(_) => {}
        }
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) fn delete(
        &mut self,
        shared: &Shared,
        epoch: u64,
        seq: u64,
        factory: &Factory,
        id: String,
        expected_sequence: u64,
        cancellation: Cancellation,
    ) {
        let result = (|| {
            if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                return Err(persistence::Error::Cancelled);
            }
            let save_id = parse_id(&id)?;
            let directory_sequence = expected_sequence
                .checked_add(1)
                .ok_or(persistence::Error::Invalid("sequence exhausted"))?;
            let io_id = self
                .service
                .submit_with_cancellation(Request::Delete(id, expected_sequence), cancellation)?;
            self.pending = Some(Pending {
                request_id: seq,
                io_id,
                kind: PendingKind::Delete {
                    save_id,
                    directory_sequence,
                },
                tick: factory.clock().tick,
                revision: factory.revision(),
            });
            Ok(())
        })();
        if let Err(error) = result
            && !shared.closing.load(Ordering::Acquire)
        {
            shared.lock().publish_at(
                epoch,
                seq,
                factory.clock().tick,
                factory.revision(),
                Outcome::DeleteFailed {
                    job_id: seq,
                    error: error_code(error),
                },
            );
        }
    }
    pub(super) fn poll(&mut self, shared: &Shared, epoch: u64, state: &mut WorkerState) {
        let Some(update) = self.service.poll() else {
            return;
        };
        let Some(result) = update.result else {
            return;
        };
        let pending = self.pending.take().expect("accepted I/O job");
        let job_id = pending.request_id;
        let mut payload = None;
        let result = if update.id == pending.io_id {
            result
        } else {
            Err(persistence::Error::WorkerFault)
        };
        if let PendingKind::Load { cancellation } = pending.kind {
            let result = (|| {
                if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                    return Err(SaveError::Cancelled);
                }
                let snapshot = match result {
                    Ok(Output::Loaded(snapshot)) => snapshot,
                    Err(error) => return Err(error_code(error)),
                    _ => return Err(SaveError::Failed),
                };
                #[cfg(test)]
                if let Some(observer) = &mut self.restore_observer {
                    observer("BeforeRestore");
                }
                if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                    return Err(SaveError::Cancelled);
                }
                let (factory, session) = snapshot.restore().map_err(error_code)?;
                let candidate = super::Candidate { factory, session };
                #[cfg(test)]
                if let Some(observer) = &mut self.restore_observer {
                    observer("AfterRestore");
                }
                if cancellation.is_cancelled() || shared.closing.load(Ordering::Acquire) {
                    return Err(SaveError::Cancelled);
                }
                let info = candidate.info(job_id);
                if info.bytes > self.limits.candidate_bytes {
                    return Err(SaveError::Failed);
                }
                Ok((candidate, info))
            })();
            if !shared.closing.load(Ordering::Acquire) {
                let mut mailbox = shared.lock();
                // A control accepted after the last restore boundary still wins
                // before preparation becomes visible under this same lock.
                let result = if cancellation.is_cancelled() {
                    Err(SaveError::Cancelled)
                } else {
                    result
                };
                let outcome = match result {
                    Ok((candidate, info)) => {
                        state.candidate = Some(candidate);
                        mailbox
                            .candidate
                            .as_mut()
                            .expect("reserved candidate")
                            .payload = Some(info);
                        Outcome::LoadPrepared { job_id }
                    }
                    Err(error) => Outcome::LoadFailed { job_id, error },
                };
                mailbox.publish_at(epoch, job_id, pending.tick, pending.revision, outcome);
            }
            return;
        }
        let is_list = matches!(pending.kind, PendingKind::List);
        let mut outcome = match pending.kind {
            PendingKind::Save {
                frame_seq,
                directory_sequence,
            } => {
                let failed = |error| Outcome::SaveFailed {
                    job_id,
                    frame_seq,
                    error,
                };
                match result {
                    Ok(Output::Saved(entry)) => match parse_id(&entry.id) {
                        Ok(save_id) => Outcome::SaveCompleted {
                            job_id,
                            frame_seq,
                            save_id,
                            directory_sequence,
                        },
                        Err(_) => failed(SaveError::Failed),
                    },
                    Err(error) => failed(error_code(error)),
                    _ => failed(SaveError::Failed),
                }
            }
            PendingKind::Delete {
                save_id,
                directory_sequence,
            } => match result {
                Ok(Output::Deleted) => Outcome::DeleteCompleted {
                    job_id,
                    save_id,
                    directory_sequence,
                },
                Err(error) => Outcome::DeleteFailed {
                    job_id,
                    error: error_code(error),
                },
                _ => Outcome::DeleteFailed {
                    job_id,
                    error: SaveError::Failed,
                },
            },
            PendingKind::List => match result {
                Ok(Output::Listed(data))
                    if directory::fits(
                        &data,
                        self.limits.directory_count,
                        self.limits.directory_bytes,
                    ) =>
                {
                    let outcome = Outcome::DirectoryReady {
                        job_id,
                        directory_sequence: data.sequence,
                        entry_count: data.entries.len(),
                    };
                    payload = Some(data);
                    outcome
                }
                Err(error) => Outcome::DirectoryFailed {
                    job_id,
                    error: error_code(error),
                },
                _ => Outcome::DirectoryFailed {
                    job_id,
                    error: SaveError::Failed,
                },
            },
            PendingKind::Load { .. } => unreachable!("load restored in world owner"),
        };
        if !shared.closing.load(Ordering::Acquire) {
            let mut mailbox = shared.lock();
            if is_list
                && mailbox
                    .disk_cancellation
                    .as_ref()
                    .is_some_and(Cancellation::is_cancelled)
            {
                payload = None;
                outcome = Outcome::DirectoryFailed {
                    job_id,
                    error: SaveError::Cancelled,
                };
            }
            if let Some(data) = payload {
                mailbox
                    .directory
                    .as_mut()
                    .expect("reserved directory")
                    .payload = Some(data);
            }
            mailbox.publish_at(epoch, job_id, pending.tick, pending.revision, outcome);
        }
    }
}
impl Drop for SaveWorker {
    fn drop(&mut self) {
        // Runs only in the world worker, also during unwind. The world's owner
        // cannot report stopped until the child's join receipt is available.
        self.service.close();
        self.service.wait_stopped();
    }
}
fn error_code(error: persistence::Error) -> SaveError {
    match error {
        persistence::Error::Invalid(_) | persistence::Error::Unsupported => SaveError::Invalid,
        persistence::Error::Io(_) => SaveError::Disk,
        persistence::Error::Busy => SaveError::Busy,
        persistence::Error::StaleDirectory => SaveError::StaleDirectory,
        persistence::Error::Cancelled => SaveError::Cancelled,
        persistence::Error::CommitUncertain => SaveError::CommitUncertain,
        persistence::Error::Closed | persistence::Error::WorkerFault => SaveError::Failed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        factory::Ruleset,
        logistics::Settings,
        persistence::{
            Player,
            store::{Kind, SaveRequest, new_id},
        },
        world::Bounds,
    };

    #[test]
    fn close_during_capture_does_not_submit_new_io() {
        let root = std::env::temp_dir().join(format!("factory-capture-close-{}", new_id()));
        let mut worker = SaveWorker::new(root.clone()).unwrap();
        let shared = Shared::default();
        let factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        let state = WorkerState {
            timing: super::super::Timing {
                paused: true,
                ..super::super::Timing::default()
            },
            ..WorkerState::default()
        };
        let save = Save {
            player: Player {
                frame: 1,
                ..Player::default()
            },
            world_id: [7; 16],
            world_name: "捕获关闭".into(),
            autosave_minutes: 5.0,
            request: SaveRequest {
                name: "保存".into(),
                overwrite: false,
                kind: Kind::Manual,
                retention: 3,
                expected_sequence: 0,
            },
        };
        worker.capture_with(
            &shared,
            1,
            1,
            &factory,
            &state,
            save,
            Cancellation::default(),
            |factory, session| {
                let snapshot = persistence::capture(factory, session)?;
                shared.closing.store(true, Ordering::Release);
                Ok(snapshot)
            },
        );
        let submitted = worker.service.busy();
        drop(worker);
        assert!(!submitted, "capture observed close before dispatching I/O");
        assert!(!root.exists());
    }
}
