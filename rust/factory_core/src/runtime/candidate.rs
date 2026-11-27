//! The mailbox retains only a bounded description; the world owns both factories.
use super::{Error, Runtime};
use crate::{
    factory::{Factory, Ruleset},
    logistics::Clock,
    persistence::{Session, jobs::Cancellation},
    world::Bounds,
};

pub(super) const MAX_CANDIDATE_BYTES: usize = 704;
const FIXED_BYTES: usize = 384;

#[derive(Clone, Debug, PartialEq)]
pub struct CandidateInfo {
    pub job_id: u64,
    pub session: Session,
    pub ruleset: Ruleset,
    pub clock: Clock,
    pub revision: u64,
    pub bounds: Bounds,
    pub bytes: usize,
}
pub(super) struct CandidateSlot {
    pub job_id: u64,
    pub cancellation: Cancellation,
    pub payload: Option<CandidateInfo>,
    pub ready_requested: bool,
    pub next_epoch: Option<u64>,
    pub switch_requested: bool,
}
pub(super) struct Candidate {
    pub factory: Factory,
    pub session: Session,
}
impl Candidate {
    pub fn info(&self, job_id: u64) -> CandidateInfo {
        CandidateInfo {
            job_id,
            session: self.session.clone(),
            ruleset: self.factory.ruleset(),
            clock: self.factory.clock(),
            revision: self.factory.revision(),
            bounds: self.factory.world().bounds(),
            bytes: FIXED_BYTES + self.session.world_name.len(),
        }
    }
}
impl Runtime {
    /// Repeated bounded reads never acknowledge the preparation or destroy it.
    pub fn poll_candidate(
        &self,
        epoch: u64,
        job_id: u64,
        bytes: usize,
    ) -> Result<CandidateInfo, Error> {
        let mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if job_id == 0 || bytes == 0 {
            return Err(Error::InvalidArgument);
        }
        let slot = mailbox.candidate.as_ref().ok_or(Error::InvalidArgument)?;
        if slot.job_id != job_id {
            return Err(Error::InvalidArgument);
        }
        let info = slot.payload.as_ref().ok_or(Error::NotReady)?;
        if info.bytes > bytes.min(MAX_CANDIDATE_BYTES) {
            return Err(Error::InvalidArgument);
        }
        Ok(info.clone())
    }
}
