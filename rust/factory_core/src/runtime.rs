//! Single-operation transport. The world is created and used only in its worker.
//! No engine types or live transport networks cross this boundary.
use crate::{
    belt_placement::Direction,
    factory::{self, Factory, Ruleset},
    logistics::{Clock, Settings},
    persistence::{Player, Session, jobs::Cancellation, store::SaveRequest},
    world::{Block, Bounds, Cell},
};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Condvar, Mutex, MutexGuard, TryLockError,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
mod save_worker;
use save_worker::SaveWorker;
mod directory;
pub use directory::{DirectoryLimits, DirectoryPage};
use directory::{DirectorySlot, MAX_DIRECTORY_BYTES, MAX_DIRECTORY_ENTRIES};
mod candidate;
pub use candidate::CandidateInfo;
use candidate::{Candidate, CandidateSlot, MAX_CANDIDATE_BYTES};
mod controls;
pub mod display;
pub mod presentation;
pub mod queries;
pub mod safety;

pub const RESULT_BYTES: usize = 96;
const MAX_INPUT_BYTES: usize = 64 * 1024;
const MAX_BUILD_CELLS: usize = 64;
pub const MAX_FRAME_DELTA: f64 = 4.0 / 60.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub frame_seq: u64,
    pub delta: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Save {
    pub player: Player,
    pub world_id: [u8; 16],
    pub world_name: String,
    pub autosave_minutes: f64,
    pub request: SaveRequest,
}
impl Save {
    fn session(&self) -> Session {
        Session {
            world_id: self.world_id,
            world_name: self.world_name.clone(),
            autosave_minutes: self.autosave_minutes,
            autosave_retention: self.request.retention,
            player: self.player.clone(),
        }
    }
    fn bytes(&self) -> Result<usize, Error> {
        if self.world_name.len() > 320
            || self.request.name.len() > 640
            || self.request.expected_sequence == u64::MAX
            || self.request.validate().is_err()
            || self.session().validate().is_err()
        {
            return Err(Error::InvalidArgument);
        }
        Ok(288 + self.world_name.len() + self.request.name.len())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    PrepareBuild(safety::Request),
    ConfirmBuild {
        token: u64,
        pose: safety::Pose,
        engine_clear: bool,
    },
    Build(Vec<(Cell, Block, Direction)>),
    BuildRoute(queries::RouteRequest),
    Query(queries::Query),
    Remove(Cell),
    SetDirection(Cell, Direction),
    Cell(Cell),
    Frame(Frame),
    Pause,
    Resume,
    Save(Save),
    ListDirectory,
    PrepareLoad(String),
    Delete(String, u64),
    PresentationReady {
        job_id: u64,
    },
    SwitchApplied {
        job_id: u64,
        next_epoch: u64,
    },
}
impl Command {
    fn bytes(&self, bounds: Bounds) -> Result<usize, Error> {
        match self {
            Self::PrepareBuild(request) => request.bytes(bounds),
            Self::ConfirmBuild { token, pose, .. } => {
                if *token == 0 || *token > i64::MAX as u64 || !pose.valid() {
                    return Err(Error::InvalidArgument);
                }
                Ok(192)
            }
            Self::Query(query) => query.bytes(bounds),
            Self::BuildRoute(route) => route.bytes(bounds),
            Self::Build(cells) => {
                if cells.is_empty()
                    || cells.len() > MAX_BUILD_CELLS
                    || cells.iter().any(|(_, block, _)| *block == Block::Air)
                {
                    return Err(Error::InvalidArgument);
                }
                if cells.iter().any(|(cell, _, _)| !bounds.contains(*cell)) {
                    return Err(Error::OutOfBounds);
                }
                Ok(32 + 16 * cells.len())
            }
            Self::Remove(cell) | Self::SetDirection(cell, _) | Self::Cell(cell) => {
                if !bounds.contains(*cell) {
                    return Err(Error::OutOfBounds);
                }
                Ok(32)
            }
            Self::Frame(frame) => {
                if !frame.delta.is_finite()
                    || !(0.0..=MAX_FRAME_DELTA).contains(&frame.delta)
                    || frame.frame_seq == 0
                    || frame.frame_seq > i64::MAX as u64
                {
                    return Err(Error::InvalidArgument);
                }
                Ok(48)
            }
            Self::Pause | Self::Resume | Self::ListDirectory => Ok(32),
            Self::Save(save) => save.bytes(),
            Self::PrepareLoad(id) => {
                crate::persistence::store::parse_id(id).map_err(|_| Error::InvalidArgument)?;
                Ok(64)
            }
            Self::Delete(id, expected_sequence) => {
                crate::persistence::store::parse_id(id).map_err(|_| Error::InvalidArgument)?;
                if *expected_sequence == u64::MAX {
                    return Err(Error::InvalidArgument);
                }
                Ok(72)
            }
            Self::PresentationReady { job_id } | Self::SwitchApplied { job_id, .. } => {
                if *job_id == 0 || *job_id > i64::MAX as u64 {
                    return Err(Error::InvalidArgument);
                }
                Ok(32)
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Input {
    pub request_id: u64,
    pub command: Command,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub input_bytes: usize,
    pub directory_count: usize,
    pub directory_bytes: usize,
    pub candidate_bytes: usize,
    pub query_bytes: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            input_bytes: MAX_INPUT_BYTES,
            directory_count: MAX_DIRECTORY_ENTRIES,
            directory_bytes: MAX_DIRECTORY_BYTES,
            candidate_bytes: MAX_CANDIDATE_BYTES,
            query_bytes: queries::MAX_QUERY_BYTES,
        }
    }
}
impl Limits {
    fn validate(self) -> Result<(), Error> {
        if self.input_bytes == 0
            || self.input_bytes > MAX_INPUT_BYTES
            || self.directory_count == 0
            || self.directory_count > MAX_DIRECTORY_ENTRIES
            || self.directory_bytes == 0
            || self.directory_bytes > MAX_DIRECTORY_BYTES
            || self.candidate_bytes == 0
            || self.candidate_bytes > MAX_CANDIDATE_BYTES
            || self.query_bytes == 0
            || self.query_bytes > queries::MAX_QUERY_BYTES
        {
            return Err(Error::InvalidArgument);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PollLimits {
    pub result_bytes: usize,
}
impl Default for PollLimits {
    fn default() -> Self {
        Self {
            result_bytes: 2 * RESULT_BYTES,
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidArgument,
    OutOfBounds,
    InvalidSequence,
    // Static presentation generations and page acknowledgement remain separate.
    ConflictingReplay,
    AlreadyFinalized,
    InvalidAck,
    StaleEpoch,
    Busy,
    Closed,
    Faulted,
    SpawnFailed,
    InvalidFrame,
    Paused,
    NotReady,
    NotPaused,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Starting,
    Running,
    Faulted,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    BuildPrepared {
        token: u64,
        pose_frame: u64,
        lift: f64,
    },
    BuildCommitted {
        lift: f64,
    },
    Committed,
    QueryReady {
        query_id: u64,
        view_generation: u64,
        payload_bytes: usize,
    },
    QueryFailed {
        query_id: u64,
        view_generation: u64,
        error: factory::Error,
    },
    Cell(Block),
    Rejected(factory::Error),
    Faulted,
    FrameCompleted {
        frame_seq: u64,
    },
    Paused(bool),
    SaveStarted {
        job_id: u64,
    },
    SaveCompleted {
        job_id: u64,
        frame_seq: u64,
        save_id: [u8; 16],
        directory_sequence: u64,
    },
    SaveFailed {
        job_id: u64,
        frame_seq: u64,
        error: SaveError,
    },
    DeleteCompleted {
        job_id: u64,
        save_id: [u8; 16],
        directory_sequence: u64,
    },
    DeleteFailed {
        job_id: u64,
        error: SaveError,
    },
    DirectoryReady {
        job_id: u64,
        directory_sequence: u64,
        entry_count: usize,
    },
    DirectoryFailed {
        job_id: u64,
        error: SaveError,
    },
    LoadPrepared {
        job_id: u64,
    },
    LoadFailed {
        job_id: u64,
        error: SaveError,
    },
    CommitDecided {
        job_id: u64,
        next_epoch: u64,
    },
    LoadCompleted {
        job_id: u64,
        next_epoch: u64,
    },
}
/// Fixed-size failure codes; disk paths and arbitrary I/O text never enter
/// the reliable result budget.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SaveError {
    Invalid,
    Disk,
    Busy,
    StaleDirectory,
    Cancelled,
    CommitUncertain,
    Failed,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Completion {
    pub world_epoch: u64,
    pub request_id: u64,
    pub tick: i64,
    pub revision: u64,
    pub outcome: Outcome,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub world_epoch: u64,
    pub status: Status,
    pub results: Vec<Completion>,
    pub result_bytes: usize,
    pub timing: Timing,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Timing {
    pub clock: Clock,
    pub revision: u64,
    pub completed_frame: u64,
    pub paused: bool,
    /// Wall time of the entire advance event, not a measured individual tick.
    pub last_advance_seconds: f64,
    pub max_advance_seconds: f64,
    pub last_advance_ticks: i64,
}

struct Record {
    input: Input,
    cancellation: Option<Cancellation>,
}
struct Mailbox {
    epoch: u64,
    bounds: Bounds,
    handoff_frozen: bool,
    status: Status,
    operation: Option<Record>,
    pending: bool,
    result: Option<Completion>,
    job_result: Option<Completion>,
    timing: Timing,
    disk_slot: Option<u64>,
    disk_cancellation: Option<Cancellation>,
    directory: Option<DirectorySlot>,
    acknowledged_directory: u64,
    candidate: Option<CandidateSlot>,
    query: Option<queries::QuerySlot>,
    presentation: Option<presentation::Stream>,
    presentation_generation: u64,
    next_presentation_id: u64,
    display: Option<display::Round>,
    next_display_id: u64,
}
impl Default for Mailbox {
    fn default() -> Self {
        Self {
            epoch: 1,
            bounds: Bounds::default(),
            handoff_frozen: false,
            status: Status::Starting,
            operation: None,
            pending: false,
            result: None,
            job_result: None,
            timing: Timing::default(),
            disk_slot: None,
            disk_cancellation: None,
            directory: None,
            acknowledged_directory: 0,
            candidate: None,
            query: None,
            presentation: None,
            presentation_generation: 0,
            next_presentation_id: 1,
            display: None,
            next_display_id: 1,
        }
    }
}
impl Mailbox {
    fn publish(&mut self, epoch: u64, seq: u64, revision: u64, outcome: Outcome) {
        self.publish_at(epoch, seq, self.timing.clock.tick, revision, outcome);
    }
    fn publish_at(&mut self, epoch: u64, seq: u64, tick: i64, revision: u64, outcome: Outcome) {
        if self
            .candidate
            .as_ref()
            .is_some_and(|slot| slot.job_id == seq)
            && !matches!(outcome, Outcome::LoadPrepared { .. })
        {
            self.candidate = None;
        }
        if self
            .directory
            .as_ref()
            .is_some_and(|slot| slot.job_id == seq)
            && !matches!(outcome, Outcome::DirectoryReady { .. })
        {
            self.directory = None;
        }
        let result = Completion {
            world_epoch: epoch,
            request_id: seq,
            tick,
            revision,
            outcome,
        };
        // Capture completion frees the world independently of the disk job.
        if self.result.is_none()
            && self
                .operation
                .as_ref()
                .is_some_and(|r| r.input.request_id == seq)
        {
            self.result = Some(result);
        } else {
            assert_eq!(self.disk_slot, Some(seq), "reserved disk job");
            assert!(self.job_result.is_none(), "disk terminal delivered once");
            self.job_result = Some(result);
        }
    }
}
#[derive(Default)]
struct Shared {
    mailbox: Mutex<Mailbox>,
    wake: Condvar,
    closing: AtomicBool,
    stopped: AtomicBool,
}
impl Shared {
    fn lock(&self) -> MutexGuard<'_, Mailbox> {
        self.mailbox.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn try_lock(&self) -> Result<MutexGuard<'_, Mailbox>, Error> {
        if self.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mailbox = match self.mailbox.try_lock() {
            Ok(value) => value,
            Err(TryLockError::WouldBlock) => return Err(Error::Busy),
            Err(TryLockError::Poisoned(_)) => return Err(Error::Faulted),
        };
        if self.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        Ok(mailbox)
    }
}

/// A host handle, not an owner of any live world or native network.
pub struct Runtime {
    _shared: Arc<Shared>,
    _limits: Limits,
    _persistence: bool,
}
impl Runtime {
    pub fn open(
        bounds: Bounds,
        settings: Settings,
        ruleset: Ruleset,
        epoch: u64,
        limits: Limits,
    ) -> Result<Self, Error> {
        Self::open_inner(bounds, settings, ruleset, epoch, limits, None)
    }
    pub fn open_with_persistence(
        bounds: Bounds,
        settings: Settings,
        ruleset: Ruleset,
        epoch: u64,
        limits: Limits,
        root: PathBuf,
    ) -> Result<Self, Error> {
        if !root.is_absolute() {
            return Err(Error::InvalidArgument);
        }
        Self::open_inner(bounds, settings, ruleset, epoch, limits, Some(root))
    }
    fn open_inner(
        bounds: Bounds,
        settings: Settings,
        ruleset: Ruleset,
        epoch: u64,
        limits: Limits,
        root: Option<PathBuf>,
    ) -> Result<Self, Error> {
        limits.validate()?;
        if epoch == 0 || epoch > i64::MAX as u64 {
            return Err(Error::InvalidArgument);
        }
        let shared = Arc::new(Shared::default());
        {
            let mut mailbox = shared.lock();
            mailbox.epoch = epoch;
            mailbox.bounds = bounds;
        }
        let worker = Arc::clone(&shared);
        let owner = Arc::clone(&shared);
        let persistence = root.is_some();
        crate::thread_lifecycle::spawn(
            "factory-world",
            move || {
                supervise(&worker, epoch, || {
                    run(&worker, bounds, settings, ruleset, epoch, root, limits)
                });
            },
            move |clean| {
                if !clean {
                    fault(&owner, epoch);
                }
                owner.stopped.store(true, Ordering::Release);
            },
        )
        .map_err(|_| Error::SpawnFailed)?;
        Ok(Self {
            _shared: shared,
            _limits: limits,
            _persistence: persistence,
        })
    }

    /// Busy means unaccepted. Accepted work is never retried or replayed.
    pub fn submit(&self, epoch: u64, input: &Input) -> Result<(), Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mut mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if input.request_id == 0 || input.request_id >= i64::MAX as u64 {
            return Err(Error::InvalidSequence);
        }
        let bytes = input.command.bytes(mailbox.bounds)?;
        if mailbox.status == Status::Faulted {
            return Err(Error::Faulted);
        }
        if mailbox.operation.is_some() || bytes > self._limits.input_bytes {
            return Err(Error::Busy);
        }
        if mailbox.disk_slot == Some(input.request_id)
            || mailbox
                .candidate
                .as_ref()
                .is_some_and(|s| s.job_id == input.request_id)
        {
            return Err(Error::InvalidArgument);
        }
        let handoff = matches!(
            input.command,
            Command::PresentationReady { .. } | Command::SwitchApplied { .. }
        );
        if mailbox.handoff_frozen && !handoff {
            return Err(Error::Busy);
        }
        if mailbox.candidate.is_some()
            && !handoff
            && !matches!(
                input.command,
                Command::Cell(_) | Command::Pause | Command::ListDirectory
            )
        {
            return Err(Error::Busy);
        }
        let disk = matches!(
            input.command,
            Command::Save(_)
                | Command::ListDirectory
                | Command::PrepareLoad(_)
                | Command::Delete(_, _)
        );
        if disk && (!self._persistence || mailbox.disk_slot.is_some()) {
            return Err(if self._persistence {
                Error::Busy
            } else {
                Error::InvalidArgument
            });
        }
        match &input.command {
            Command::Frame(frame) => {
                if frame.frame_seq <= mailbox.timing.completed_frame {
                    return Err(Error::InvalidFrame);
                }
                if mailbox.timing.paused && frame.delta > 0.0 {
                    return Err(Error::Paused);
                }
            }
            Command::Save(_) | Command::PrepareLoad(_) if !mailbox.timing.paused => {
                return Err(Error::NotPaused);
            }
            Command::ListDirectory if mailbox.directory.is_some() => return Err(Error::Busy),
            Command::Query(query) if query.payload_budget() > self._limits.query_bytes => {
                return Err(Error::InvalidArgument);
            }
            _ => {}
        }
        controls::accept(&mut mailbox, &input.command)?;
        let cancellation = disk.then(Cancellation::default);
        if let Command::Query(query) = &input.command {
            mailbox.query = Some(queries::QuerySlot {
                request_id: input.request_id,
                query_id: query.query_id,
                payload: None,
            });
        }
        if presentation::is_edit(&input.command)
            && let Some(stream) = mailbox.presentation.as_mut()
            && stream.interest.job_id == 0
        {
            stream.invalidate(input.request_id);
        }
        if disk {
            mailbox.disk_slot = Some(input.request_id);
            mailbox.disk_cancellation = cancellation.clone();
        }
        if matches!(input.command, Command::PrepareLoad(_)) {
            mailbox.candidate = Some(CandidateSlot {
                job_id: input.request_id,
                cancellation: cancellation.clone().expect("load cancellation"),
                payload: None,
                ready_requested: false,
                next_epoch: None,
                switch_requested: false,
            });
        }
        if matches!(input.command, Command::ListDirectory) {
            mailbox.directory = Some(DirectorySlot::new(input.request_id));
        }
        mailbox.operation = Some(Record {
            input: input.clone(),
            cancellation,
        });
        mailbox.pending = true;
        drop(mailbox);
        self._shared.wake.notify_one();
        Ok(())
    }

    /// A flag on the existing job, with no second command stream or receipt.
    pub fn cancel(&self, epoch: u64, job_id: u64) -> Result<bool, Error> {
        let mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if mailbox.status == Status::Faulted {
            return Err(Error::Faulted);
        }
        let prepared = mailbox
            .candidate
            .as_ref()
            .is_some_and(|s| s.job_id == job_id);
        if mailbox
            .job_result
            .as_ref()
            .is_some_and(|r| r.request_id == job_id)
            || (!prepared
                && mailbox.result.as_ref().is_some_and(|r| {
                    r.request_id == job_id && !matches!(r.outcome, Outcome::SaveStarted { .. })
                }))
        {
            return Ok(false);
        }
        let cancellation = mailbox
            .candidate
            .as_ref()
            .filter(|s| s.job_id == job_id)
            .map(|s| &s.cancellation)
            .or_else(|| {
                (mailbox.disk_slot == Some(job_id))
                    .then_some(mailbox.disk_cancellation.as_ref())
                    .flatten()
            })
            .ok_or(Error::InvalidArgument)?;
        let cancelled = cancellation.cancel();
        self._shared.wake.notify_one();
        Ok(cancelled)
    }

    /// Takes whole completions once. An insufficient byte budget consumes nothing.
    pub fn poll_updates(&self, limits: PollLimits) -> Result<Page, Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mut mailbox = self._shared.try_lock()?;
        let count = (limits.result_bytes / RESULT_BYTES).min(2);
        let mut results = Vec::with_capacity(count);
        if count > 0
            && let Some(result) = mailbox.result.take()
        {
            let terminal_disk = mailbox.disk_slot == Some(result.request_id)
                && !matches!(result.outcome, Outcome::SaveStarted { .. })
                && mailbox
                    .job_result
                    .as_ref()
                    .is_none_or(|r| r.request_id != result.request_id);
            if terminal_disk {
                mailbox.disk_slot = None;
                mailbox.disk_cancellation = None;
            }
            mailbox.operation = None;
            results.push(result);
        }
        if results.len() < count
            && let Some(result) = mailbox.job_result.take()
        {
            assert_eq!(mailbox.disk_slot, Some(result.request_id));
            mailbox.disk_slot = None;
            mailbox.disk_cancellation = None;
            results.push(result);
        }
        Ok(Page {
            world_epoch: mailbox.epoch,
            status: mailbox.status,
            result_bytes: results.len() * RESULT_BYTES,
            results,
            timing: mailbox.timing,
        })
    }

    /// Never joins or competes for the ordinary queue's capacity.
    pub fn close(&self) {
        self._shared.closing.store(true, Ordering::Release);
        self._shared.wake.notify_one();
    }
    pub fn is_stopped(&self) -> bool {
        self._shared.stopped.load(Ordering::Acquire)
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.close();
    }
}

fn supervise(shared: &Shared, epoch: u64, operation: impl FnOnce() -> Result<(), factory::Error>) {
    let result = catch_unwind(AssertUnwindSafe(operation));
    if result.is_err() || result.is_ok_and(|r| r.is_err()) {
        fault(shared, epoch);
    }
}

fn fault(shared: &Shared, epoch: u64) {
    let mut mailbox = shared.lock();
    // A supervisor can outlive several world switches.
    debug_assert!(epoch <= mailbox.epoch);
    let epoch = mailbox.epoch;
    mailbox.status = Status::Faulted;
    mailbox.candidate = None;
    mailbox.handoff_frozen = false;
    if !shared.closing.load(Ordering::Acquire) {
        if mailbox.result.is_none()
            && let Some(seq) = mailbox.operation.as_ref().map(|r| r.input.request_id)
        {
            mailbox.publish(epoch, seq, 0, Outcome::Faulted);
        }
        if mailbox.job_result.is_none()
            && let Some(seq) = mailbox.disk_slot
            && (mailbox
                .operation
                .as_ref()
                .is_none_or(|r| r.input.request_id != seq)
                || mailbox
                    .result
                    .as_ref()
                    .is_some_and(|r| matches!(r.outcome, Outcome::SaveStarted { .. })))
        {
            mailbox.publish(epoch, seq, 0, Outcome::Faulted);
        }
        mailbox.pending = false;
    }
    // The world stays stopped. Only receipt/retirement operations resume,
    // after the reliable fault results have been prepared under this lock.
    shared.mailbox.clear_poison();
}

fn run(
    shared: &Shared,
    bounds: Bounds,
    settings: Settings,
    ruleset: Ruleset,
    epoch: u64,
    root: Option<PathBuf>,
    limits: Limits,
) -> Result<(), factory::Error> {
    let factory = Factory::new(bounds, settings, ruleset)?;
    let io = root
        .map(|root| SaveWorker::with_limits(root, limits))
        .transpose()
        .map_err(|_| factory::Error::InvalidRequest)?;
    run_commands_with_io(shared, epoch, factory, io, execute)
}

#[derive(Default)]
struct WorkerState {
    timing: Timing,
    candidate: Option<Candidate>,
    presentation: Option<presentation::Build>,
    prepared_build: Option<safety::Prepared>,
    request_id: u64,
}

fn execute(
    factory: &mut Factory,
    state: &mut WorkerState,
    command: Command,
) -> Result<Outcome, factory::Error> {
    match command {
        Command::PrepareBuild(request) => {
            safety::prepare(factory, state, state.request_id, request)
        }
        Command::ConfirmBuild {
            token,
            pose,
            engine_clear,
        } => safety::confirm(factory, state, token, pose, engine_clear),
        Command::Build(cells) => factory
            .preview(&cells)
            .and_then(|p| factory.commit(&p))
            .map(|()| Outcome::Committed),
        Command::BuildRoute(route) => route
            .plan(factory)
            .and_then(|builder| factory.preview_route(&builder))
            .and_then(|preview| factory.commit(&preview))
            .map(|()| Outcome::Committed),
        Command::Query(_) => unreachable!("query payloads are published at the worker boundary"),
        Command::Remove(cell) => factory.remove(cell).map(|()| Outcome::Committed),
        Command::SetDirection(cell, direction) => factory
            .set_direction(cell, direction)
            .map(|()| Outcome::Committed),
        Command::Cell(cell) => Ok(Outcome::Cell(factory.world().block(cell))),
        Command::Frame(frame) => {
            let before = factory.clock().tick;
            let started = Instant::now();
            // One original event, never split/re-summed into a new clock stream.
            factory.advance(frame.delta)?;
            state.timing.last_advance_seconds = started.elapsed().as_secs_f64();
            state.timing.max_advance_seconds = state
                .timing
                .max_advance_seconds
                .max(state.timing.last_advance_seconds);
            state.timing.last_advance_ticks = factory.clock().tick - before;
            state.timing.completed_frame = frame.frame_seq;
            Ok(Outcome::FrameCompleted {
                frame_seq: frame.frame_seq,
            })
        }
        Command::Pause | Command::Resume => {
            state.timing.paused = matches!(command, Command::Pause);
            Ok(Outcome::Paused(state.timing.paused))
        }
        Command::PresentationReady { .. } | Command::SwitchApplied { .. } => {
            unreachable!("load phases use the world boundary")
        }
        Command::Save(_)
        | Command::ListDirectory
        | Command::PrepareLoad(_)
        | Command::Delete(_, _) => {
            unreachable!("disk jobs are intercepted at the worker event boundary")
        }
    }
}

#[cfg(test)]
fn run_commands(
    shared: &Shared,
    epoch: u64,
    factory: Factory,
    execute: impl FnMut(&mut Factory, &mut WorkerState, Command) -> Result<Outcome, factory::Error>,
) -> Result<(), factory::Error> {
    run_commands_with_io(shared, epoch, factory, None, execute)
}

fn run_commands_with_io(
    shared: &Shared,
    epoch: u64,
    mut factory: Factory,
    mut io: Option<SaveWorker>,
    mut execute: impl FnMut(&mut Factory, &mut WorkerState, Command) -> Result<Outcome, factory::Error>,
) -> Result<(), factory::Error> {
    let mut state = WorkerState::default();
    {
        let mut mailbox = shared.lock();
        debug_assert_eq!(mailbox.epoch, epoch);
        mailbox.status = Status::Running;
    }
    loop {
        let mut mailbox = shared.lock();
        if shared.closing.load(Ordering::Acquire) {
            mailbox.operation = None;
            mailbox.pending = false;
            mailbox.result = None;
            mailbox.job_result = None;
            mailbox.directory = None;
            mailbox.candidate = None;
            mailbox.presentation = None;
            mailbox.display = None;
            return Ok(());
        }
        // Controls win their position at an event boundary. I/O independently
        // competes for the same cancellation token's commit transition.
        controls::discard_cancelled(&mut mailbox, &mut state);
        let epoch = mailbox.epoch;
        drop(mailbox);
        if let Some(io) = &mut io {
            io.poll(shared, epoch, &mut state);
        }
        let built_chunk = presentation::service(shared, &factory, &mut state)
            | display::service(shared, &factory);
        let mut mailbox = shared.lock();
        if !mailbox.pending {
            if built_chunk {
                continue;
            }
            // close() deliberately never locks. A bounded wait also handles a
            // notification racing with this wait without leaving an idle worker alive.
            let _wait = shared.wake.wait_timeout(mailbox, Duration::from_millis(50));
            continue;
        }
        mailbox.pending = false;
        let record = mailbox.operation.as_ref().expect("pending operation");
        let seq = record.input.request_id;
        let command = record.input.command.clone();
        let cancellation = record.cancellation.clone();
        if matches!(
            command,
            Command::PresentationReady { .. } | Command::SwitchApplied { .. }
        ) {
            let outcome = controls::execute(&mut mailbox, &mut state, &mut factory, command);
            let epoch = mailbox.epoch;
            mailbox.publish(epoch, seq, factory.revision(), outcome);
            continue;
        }
        drop(mailbox);
        if let Command::Save(save) = command {
            io.as_mut().expect("persistence enabled").capture(
                shared,
                epoch,
                seq,
                &factory,
                &state,
                save,
                cancellation.expect("reserved cancellation"),
            );
            continue;
        }
        if matches!(command, Command::ListDirectory) {
            io.as_mut().expect("persistence enabled").list(
                shared,
                epoch,
                seq,
                &factory,
                cancellation.expect("reserved cancellation"),
            );
            continue;
        }
        if let Command::PrepareLoad(id) = command {
            io.as_mut().expect("persistence enabled").load(
                shared,
                epoch,
                seq,
                &factory,
                id,
                cancellation.expect("reserved cancellation"),
            );
            continue;
        }
        if let Command::Delete(id, expected_sequence) = command {
            io.as_mut().expect("persistence enabled").delete(
                shared,
                epoch,
                seq,
                &factory,
                id,
                expected_sequence,
                cancellation.expect("reserved cancellation"),
            );
            continue;
        }
        if let Command::Query(query) = &command {
            let result = query.execute(&mut factory);
            let mut mailbox = shared.lock();
            if !shared.closing.load(Ordering::Acquire) {
                let outcome = match result {
                    Ok(payload) => {
                        let outcome = queries::outcome(query, &payload);
                        let slot = mailbox.query.as_mut().expect("reserved query");
                        slot.payload = Some(queries::QueryPage {
                            world_epoch: epoch,
                            request_id: seq,
                            query_id: query.query_id,
                            view_generation: query.view_generation,
                            tick: factory.clock().tick,
                            revision: factory.revision(),
                            payload_bytes: payload.bytes(),
                            payload,
                        });
                        outcome
                    }
                    Err(error) if is_backend_fault(&error) => return Err(error),
                    Err(error) => Outcome::QueryFailed {
                        query_id: query.query_id,
                        view_generation: query.view_generation,
                        error,
                    },
                };
                mailbox.publish(epoch, seq, factory.revision(), outcome);
            }
            continue;
        }
        let is_frame = matches!(command, Command::Frame(_));
        state.request_id = seq;
        let result = execute(&mut factory, &mut state, command);
        let outcome = match result {
            Ok(outcome) => outcome,
            // A failed accepted clock event cannot be skipped: freeze the stream.
            Err(error) if is_frame || is_backend_fault(&error) => return Err(error),
            Err(error) => Outcome::Rejected(error),
        };
        let mut mailbox = shared.lock();
        if !shared.closing.load(Ordering::Acquire) {
            state.timing.clock = factory.clock();
            state.timing.revision = factory.revision();
            mailbox.timing = state.timing;
            mailbox.publish(epoch, seq, factory.revision(), outcome);
        }
    }
}

fn is_backend_fault(error: &factory::Error) -> bool {
    use crate::logistics::continuous;
    use rust_conveyor::api::Error as NativeError;
    matches!(
        error,
        factory::Error::Continuous(continuous::Error::Transport(
            NativeError::Invariant
                | NativeError::Stopped
                | NativeError::Numerical
                | NativeError::Injected
        ))
    )
}

#[cfg(test)]
mod delete_tests;
#[cfg(test)]
mod directory_tests;
#[cfg(test)]
mod load_tests;
#[cfg(test)]
mod save_tests;
#[cfg(test)]
mod switch_tests;

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn host(limits: Limits) -> Runtime {
        Runtime {
            _shared: Arc::new(Shared::default()),
            _limits: limits,
            _persistence: false,
        }
    }
    pub(super) fn query(seq: u64) -> Input {
        Input {
            request_id: seq,
            command: Command::Cell(Cell::new(0, 0, 0)),
        }
    }

    #[test]
    fn competing_host_calls_return_busy_and_close_does_not_wait_for_lock() {
        let r = host(Limits::default());
        let guard = r._shared.lock();
        assert_eq!(r.submit(1, &query(1)), Err(Error::Busy));
        assert_eq!(r.poll_updates(PollLimits::default()), Err(Error::Busy));
        r.close();
        assert_eq!(r.submit(1, &query(1)), Err(Error::Closed));
        drop(guard);
    }

    #[test]
    fn completion_holds_the_single_operation_until_taken() {
        let r = host(Limits::default());
        r.submit(1, &query(1)).unwrap();
        assert_eq!(r.submit(1, &query(2)), Err(Error::Busy));
        r._shared.lock().publish(1, 1, 0, Outcome::Cell(Block::Air));
        assert!(
            r.poll_updates(PollLimits { result_bytes: 95 })
                .unwrap()
                .results
                .is_empty()
        );
        assert_eq!(r.submit(1, &query(2)), Err(Error::Busy));
        assert_eq!(take(&r).request_id, 1);
        assert!(
            r.poll_updates(PollLimits::default())
                .unwrap()
                .results
                .is_empty()
        );
        r.submit(1, &query(2)).unwrap();
    }

    #[test]
    fn worker_panic_preserves_a_published_completion() {
        let r = host(Limits::default());
        r.submit(1, &query(1)).unwrap();
        r._shared.lock().publish(1, 1, 0, Outcome::Cell(Block::Air));
        supervise(&r._shared, 1, || panic!("injected world panic"));
        assert!(
            !r.is_stopped(),
            "fault handling is not a thread exit receipt"
        );
        let p = r.poll_updates(PollLimits::default()).unwrap();
        assert_eq!(p.status, Status::Faulted);
        assert_eq!(p.results.len(), 1);
        assert_eq!(p.results[0].outcome, Outcome::Cell(Block::Air));
        assert_eq!(r.submit(1, &query(2)), Err(Error::Faulted));
        assert!(
            r.poll_updates(PollLimits::default())
                .unwrap()
                .results
                .is_empty()
        );
    }

    #[test]
    fn panic_while_holding_mailbox_still_allows_fault_receipts() {
        let r = host(Limits::default());
        r.submit(1, &query(1)).unwrap();
        supervise(&r._shared, 1, || {
            let _guard = r._shared.lock();
            panic!("injected panic while publishing");
        });
        let p = r.poll_updates(PollLimits::default()).unwrap();
        assert_eq!(p.status, Status::Faulted);
        assert_eq!(p.results.len(), 1);
        assert!(p.results.iter().all(|r| r.outcome == Outcome::Faulted));
        assert!(
            r.poll_updates(PollLimits::default())
                .unwrap()
                .results
                .is_empty()
        );
    }

    #[test]
    fn native_invariant_and_stopped_failures_stop_before_the_next_accepted_operation() {
        for error in [
            rust_conveyor::api::Error::Invariant,
            rust_conveyor::api::Error::Stopped,
        ] {
            let r = host(Limits::default());
            r.submit(1, &query(1)).unwrap();
            let factory = Factory::new(
                Bounds::default(),
                Settings {
                    interval: 0.1,
                    amount: 1,
                },
                Ruleset::ConveyorContinuousV1,
            )
            .unwrap();
            let mut calls = 0;
            supervise(&r._shared, 1, || {
                run_commands(&r._shared, 1, factory, |_, _, _| {
                    calls += 1;
                    assert_eq!(calls, 1, "backend must stop after internal failure");
                    Err(factory::Error::Continuous(
                        crate::logistics::continuous::Error::Transport(error.clone()),
                    ))
                })
            });
            assert_eq!(calls, 1);
            let p = r.poll_updates(PollLimits::default()).unwrap();
            assert_eq!(p.status, Status::Faulted);
            assert!(p.results.iter().all(|r| r.outcome == Outcome::Faulted));
        }
    }

    #[test]
    fn out_of_bounds_is_distinct_from_invalid_parameters_and_never_accepts_an_operation() {
        let r = host(Limits::default());
        for command in [
            Command::Cell(Cell::new(32, 0, 0)),
            Command::Remove(Cell::new(32, 0, 0)),
            Command::Build(vec![(Cell::new(32, 0, 0), Block::Belt, Direction::East)]),
        ] {
            assert_eq!(
                r.submit(
                    1,
                    &Input {
                        request_id: 1,
                        command
                    }
                ),
                Err(Error::OutOfBounds)
            );
        }
        assert!(r._shared.lock().operation.is_none());
    }

    pub(super) fn frame(seq: u64, delta: f64) -> Input {
        Input {
            request_id: seq,
            command: Command::Frame(Frame {
                frame_seq: seq,
                delta,
            }),
        }
    }

    #[test]
    fn frame_execution_blocks_the_next_operation() {
        let r = host(Limits::default());
        r.submit(1, &frame(1, 0.04)).unwrap();
        let factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        let mut calls = 0;
        supervise(&r._shared, 1, || {
            run_commands(&r._shared, 1, factory, |factory, state, command| {
                calls += 1;
                let p = r.poll_updates(PollLimits::default()).unwrap();
                assert!(p.results.is_empty());
                assert_eq!(r.submit(1, &frame(2, 0.01)), Err(Error::Busy));
                assert_eq!(p.timing.completed_frame, 0);
                r.close();
                execute(factory, state, command)
            })
        });
        assert_eq!(calls, 1);
        assert!(
            !r.is_stopped(),
            "returning from the loop is not a join receipt"
        );
    }

    #[test]
    fn failed_advance_keeps_the_last_completed_clock_and_freezes_the_world() {
        let r = host(Limits::default());
        r._shared.lock().timing = Timing {
            clock: Clock {
                time: 0.01,
                ..Clock::default()
            },
            completed_frame: 1,
            ..Timing::default()
        };
        r.submit(1, &frame(2, 0.02)).unwrap();
        let factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        let mut calls = 0;
        supervise(&r._shared, 1, || {
            run_commands(&r._shared, 1, factory, |_, _, _| {
                calls += 1;
                Err(factory::Error::Legacy(crate::logistics::Error::InvalidTime))
            })
        });
        assert_eq!(calls, 1);
        let p = r.poll_updates(PollLimits::default()).unwrap();
        assert_eq!(p.status, Status::Faulted);
        assert_eq!(p.timing.clock.time, 0.01);
        assert_eq!(p.timing.completed_frame, 1);
        assert_eq!(p.results[0].outcome, Outcome::Faulted);
        assert_eq!(r.submit(1, &query(3)), Err(Error::Faulted));
    }

    #[test]
    fn original_serial_events_match_synchronous_factory_without_player_transport() {
        for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
            let settings = Settings {
                interval: 0.1,
                amount: 1,
            };
            let mut expected = Factory::new(Bounds::default(), settings, ruleset).unwrap();
            let r =
                Runtime::open(Bounds::default(), settings, ruleset, 1, Limits::default()).unwrap();
            let mut inputs = vec![frame(1, 0.003), frame(2, 0.007)];
            inputs.push(Input {
                request_id: 3,
                command: Command::Build(vec![
                    (Cell::new(0, 0, 0), Block::Miner, Direction::East),
                    (Cell::new(1, 0, 0), Block::Belt, Direction::East),
                    (Cell::new(2, 0, 0), Block::Chest, Direction::East),
                ]),
            });
            inputs.push(frame(4, 1.0 / 60.0 - 0.01));
            for (seq, direction) in [(5, Direction::West), (6, Direction::East)] {
                inputs.push(Input {
                    request_id: seq,
                    command: Command::SetDirection(Cell::new(1, 0, 0), direction),
                });
            }
            inputs.push(frame(7, 0.0));
            for seq in 8..=20 {
                inputs.push(frame(seq, if seq % 2 == 0 { 0.013 } else { 0.021 }));
            }
            for input in &inputs {
                match &input.command {
                    Command::Frame(f) => {
                        expected.advance(f.delta).unwrap();
                    }
                    Command::Build(cells) => {
                        let preview = expected.preview(cells).unwrap();
                        expected.commit(&preview).unwrap();
                    }
                    Command::SetDirection(cell, direction) => {
                        expected.set_direction(*cell, *direction).unwrap();
                    }
                    _ => {}
                }
            }
            for input in inputs {
                submit(&r, &input);
                assert_eq!(take(&r).request_id, input.request_id);
            }
            assert_eq!(
                r.poll_updates(PollLimits::default()).unwrap().timing.clock,
                expected.clock()
            );
            stop(&r);
        }
    }

    pub(super) fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> Result<T, Error> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match call() {
                Err(Error::Busy) if Instant::now() < deadline => std::thread::yield_now(),
                value => return value,
            }
        }
    }
    pub(super) fn submit(r: &Runtime, input: &Input) {
        retry(|| r.submit(1, input)).unwrap();
    }
    pub(super) fn take(r: &Runtime) -> Completion {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let mut p = retry(|| {
                r.poll_updates(PollLimits {
                    result_bytes: RESULT_BYTES,
                })
            })
            .unwrap();
            if !p.results.is_empty() {
                return p.results.remove(0);
            }
            assert!(Instant::now() < deadline, "{p:?}");
            std::thread::yield_now();
        }
    }
    pub(super) fn run(r: &Runtime, request_id: u64, command: Command) -> Completion {
        submit(
            r,
            &Input {
                request_id,
                command,
            },
        );
        let result = take(r);
        assert_eq!(result.request_id, request_id);
        result
    }
    pub(super) fn stop(r: &Runtime) {
        r.close();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !r.is_stopped() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(r.is_stopped());
    }
}
