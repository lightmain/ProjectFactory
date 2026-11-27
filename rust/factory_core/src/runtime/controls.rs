//! Load phases use the same operation slot as world commands.
use super::{Command, Error, Factory, Mailbox, Outcome, SaveError, Timing, WorkerState};

pub(super) fn accept(mailbox: &mut Mailbox, command: &Command) -> Result<(), Error> {
    match command {
        Command::PresentationReady { job_id } => {
            let slot = mailbox
                .candidate
                .as_ref()
                .filter(|s| s.job_id == *job_id)
                .ok_or(Error::InvalidArgument)?;
            if slot.payload.is_none() {
                return Err(Error::NotReady);
            }
            if slot.ready_requested || mailbox.disk_slot.is_some() {
                return Err(Error::Busy);
            }
            if !mailbox.timing.paused {
                return Err(Error::NotPaused);
            }
            mailbox
                .epoch
                .checked_add(1)
                .filter(|n| *n <= i64::MAX as u64)
                .ok_or(Error::InvalidArgument)?;
            // Acceptance closes the cancellation window in call order.
            let decided = slot.cancellation.decide_commit();
            let slot = mailbox.candidate.as_mut().expect("candidate");
            slot.ready_requested = true;
            if decided {
                slot.next_epoch = Some(mailbox.epoch + 1);
            }
            mailbox.handoff_frozen = true;
        }
        Command::SwitchApplied { job_id, next_epoch } => {
            let slot = mailbox
                .candidate
                .as_mut()
                .filter(|s| s.job_id == *job_id)
                .ok_or(Error::InvalidArgument)?;
            if slot.next_epoch.is_none() {
                return Err(Error::NotReady);
            }
            if slot.next_epoch != Some(*next_epoch) {
                return Err(Error::InvalidArgument);
            }
            if slot.switch_requested {
                return Err(Error::Busy);
            }
            slot.switch_requested = true;
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn discard_cancelled(mailbox: &mut Mailbox, state: &mut WorkerState) {
    let Some(slot) = &mailbox.candidate else {
        return;
    };
    if !slot.cancellation.is_cancelled() || slot.ready_requested || slot.payload.is_none() {
        return;
    }
    let job_id = slot.job_id;
    // A directory request may still own the disk lane. Finish and take it first.
    if mailbox.disk_slot.is_some_and(|id| id != job_id) || mailbox.job_result.is_some() {
        return;
    }
    let cancellation = slot.cancellation.clone();
    super::presentation::discard_candidate(mailbox, state, job_id);
    state.candidate = None;
    mailbox.candidate = None;
    mailbox.handoff_frozen = false;
    // A prepared candidate owns the disk terminal slot until cancellation is taken.
    assert!(mailbox.job_result.is_none());
    mailbox.disk_slot = Some(job_id);
    mailbox.disk_cancellation = Some(cancellation);
    mailbox.job_result = Some(super::Completion {
        world_epoch: mailbox.epoch,
        request_id: job_id,
        tick: mailbox.timing.clock.tick,
        revision: mailbox.timing.revision,
        outcome: Outcome::LoadFailed {
            job_id,
            error: SaveError::Cancelled,
        },
    });
}

pub(super) fn execute(
    mailbox: &mut Mailbox,
    state: &mut WorkerState,
    factory: &mut Factory,
    command: Command,
) -> Outcome {
    match command {
        Command::PresentationReady { job_id } => {
            if let Some(next_epoch) = mailbox.candidate.as_ref().and_then(|s| s.next_epoch) {
                Outcome::CommitDecided { job_id, next_epoch }
            } else {
                super::presentation::discard_candidate(mailbox, state, job_id);
                state.candidate = None;
                mailbox.candidate = None;
                mailbox.handoff_frozen = false;
                Outcome::LoadFailed {
                    job_id,
                    error: SaveError::Cancelled,
                }
            }
        }
        Command::SwitchApplied { job_id, next_epoch } => {
            let candidate = state.candidate.take().expect("decided candidate");
            let frame = candidate.session.player.frame;
            *factory = candidate.factory;
            state.timing = Timing {
                clock: factory.clock(),
                revision: factory.revision(),
                completed_frame: frame,
                paused: true,
                ..Timing::default()
            };
            mailbox.epoch = next_epoch;
            mailbox.bounds = factory.world().bounds();
            mailbox.timing = state.timing;
            mailbox.candidate = None;
            mailbox.handoff_frozen = false;
            mailbox.query = None;
            mailbox.presentation = None;
            mailbox.presentation_generation = 0;
            state.presentation = None;
            Outcome::LoadCompleted { job_id, next_epoch }
        }
        _ => unreachable!("load phase"),
    }
}
