//! One bounded static subscription. Only the owning world thread builds meshes.
use super::{Command, Error, Mailbox, Runtime, Shared, Status, WorkerState};
use crate::{
    factory::Factory,
    meshing::{self, Mesh},
    world::{Bounds, Cell},
};
use std::{
    collections::BTreeSet,
    time::{Duration, Instant},
};

pub const MAX_KEYS: usize = 64;
pub const SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
pub const PAGE_BYTES: usize = 64 * 1024;
const PAGE_DESCRIPTION_BYTES: usize = 4096;
const FACES_PER_PAGE: usize = 128;
const FACE_BYTES: usize = 352;
const LIFETIME: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Interest {
    pub generation: u64,
    /// Zero selects the active factory; a nonzero ID selects a prepared load.
    pub job_id: u64,
    pub keys: Vec<Cell>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stage {
    Building,
    Ready,
    Aborted,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    Budget,
    Expired,
    Geometry,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Info {
    pub world_epoch: u64,
    pub generation: u64,
    pub job_id: u64,
    pub snapshot_id: u64,
    pub revision: u64,
    pub tick: i64,
    pub total_pages: usize,
    /// Includes a conservative description charge for every page.
    pub total_bytes: usize,
    pub stage: Stage,
    pub failure: Option<Failure>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub world_epoch: u64,
    pub generation: u64,
    pub job_id: u64,
    pub snapshot_id: u64,
    pub revision: u64,
    pub tick: i64,
    pub page_index: usize,
    pub total_pages: usize,
    pub keys: Vec<Cell>,
    pub key: Cell,
    pub chunk_page: usize,
    pub chunk_pages: usize,
    pub bytes: usize,
    pub mesh: Mesh,
}
pub(super) struct Stream {
    pub interest: Interest,
    requested: Instant,
    serial: u64,
    info: Info,
    meshes: Vec<Mesh>,
    delivered: Vec<bool>,
    acknowledged: bool,
}
impl Stream {
    fn new(epoch: u64, interest: Interest) -> Self {
        Self {
            info: Info {
                world_epoch: epoch,
                generation: interest.generation,
                job_id: interest.job_id,
                snapshot_id: 0,
                revision: 0,
                tick: 0,
                total_pages: 0,
                total_bytes: 0,
                stage: Stage::Building,
                failure: None,
            },
            interest,
            requested: Instant::now(),
            serial: 0,
            meshes: Vec::new(),
            delivered: Vec::new(),
            acknowledged: false,
        }
    }
    pub(super) fn invalidate(&mut self, serial: u64) {
        self.serial = serial;
        if self.info.stage == Stage::Aborted {
            return;
        }
        if self.acknowledged {
            self.requested = Instant::now();
        }
        self.meshes.clear();
        self.delivered.clear();
        self.acknowledged = false;
        self.info.snapshot_id = 0;
        self.info.total_pages = 0;
        self.info.total_bytes = 0;
        self.info.stage = Stage::Building;
    }
    fn abort(&mut self, failure: Failure) {
        self.meshes.clear();
        self.delivered.clear();
        self.info.total_pages = 0;
        self.info.total_bytes = 0;
        self.info.stage = Stage::Aborted;
        self.info.failure = Some(failure);
    }
    fn expire(&mut self, now: Instant) {
        if !self.acknowledged && now.saturating_duration_since(self.requested) >= LIFETIME {
            self.abort(Failure::Expired);
        }
    }
}

fn intersects(key: Cell, bounds: Bounds) -> bool {
    let Some(start) = key
        .x
        .checked_mul(meshing::CHUNK_SIZE)
        .zip(key.y.checked_mul(meshing::CHUNK_SIZE))
        .zip(key.z.checked_mul(meshing::CHUNK_SIZE))
        .map(|((x, y), z)| Cell::new(x, y, z))
    else {
        return false;
    };
    let Some(end) = start.checked_offset(
        meshing::CHUNK_SIZE,
        meshing::CHUNK_SIZE,
        meshing::CHUNK_SIZE,
    ) else {
        return false;
    };
    let low = bounds.minimum();
    let high = bounds.maximum();
    start.x < high.x
        && end.x > low.x
        && start.y < high.y
        && end.y > low.y
        && start.z < high.z
        && end.z > low.z
}
fn target_bounds(mailbox: &Mailbox, job: u64) -> Result<Bounds, Error> {
    if job == 0 {
        return Ok(mailbox.bounds);
    }
    mailbox
        .candidate
        .as_ref()
        .filter(|slot| slot.job_id == job)
        .and_then(|slot| slot.payload.as_ref())
        .map(|info| info.bounds)
        .ok_or(Error::NotReady)
}
fn checked_stream(mailbox: &mut Mailbox, epoch: u64) -> Result<&mut Stream, Error> {
    if mailbox.epoch != epoch {
        return Err(Error::StaleEpoch);
    }
    if mailbox.status == Status::Faulted {
        return Err(Error::Faulted);
    }
    let job = mailbox
        .presentation
        .as_ref()
        .ok_or(Error::NotReady)?
        .interest
        .job_id;
    target_bounds(mailbox, job)?;
    let stream = mailbox.presentation.as_mut().expect("checked subscription");
    stream.expire(Instant::now());
    Ok(stream)
}
impl Runtime {
    pub fn subscribe_presentation(&self, epoch: u64, interest: &Interest) -> Result<(), Error> {
        if interest.generation == 0
            || interest.generation > i64::MAX as u64
            || interest.keys.is_empty()
            || interest.keys.len() > MAX_KEYS
        {
            return Err(Error::InvalidArgument);
        }
        let mut mailbox = self._shared.try_lock()?;
        if mailbox.epoch != epoch {
            return Err(Error::StaleEpoch);
        }
        if mailbox.status == Status::Faulted {
            return Err(Error::Faulted);
        }
        let bounds = target_bounds(&mailbox, interest.job_id)?;
        if interest.keys.iter().any(|&key| !intersects(key, bounds))
            || interest.keys.iter().copied().collect::<BTreeSet<_>>().len() != interest.keys.len()
        {
            return Err(Error::InvalidArgument);
        }
        if interest.generation <= mailbox.presentation_generation {
            return match mailbox.presentation.as_ref() {
                Some(stream) if &stream.interest == interest => Ok(()),
                Some(stream) if stream.interest.generation == interest.generation => {
                    Err(Error::ConflictingReplay)
                }
                _ => Err(Error::AlreadyFinalized),
            };
        }
        mailbox.presentation_generation = interest.generation;
        mailbox.presentation = Some(Stream::new(epoch, interest.clone()));
        drop(mailbox);
        self._shared.wake.notify_one();
        Ok(())
    }
    pub fn unsubscribe_presentation(&self, epoch: u64, generation: u64) -> Result<(), Error> {
        let mut mailbox = self._shared.try_lock()?;
        if mailbox.epoch != epoch {
            return Err(Error::StaleEpoch);
        }
        if generation == 0 || generation != mailbox.presentation_generation {
            return Err(Error::InvalidArgument);
        }
        mailbox.presentation = None;
        drop(mailbox);
        self._shared.wake.notify_one();
        Ok(())
    }
    pub fn poll_presentation(&self, epoch: u64) -> Result<Info, Error> {
        let mut mailbox = self._shared.try_lock()?;
        Ok(checked_stream(&mut mailbox, epoch)?.info.clone())
    }
    pub fn poll_presentation_page(
        &self,
        epoch: u64,
        generation: u64,
        snapshot: u64,
        index: usize,
        bytes: usize,
    ) -> Result<Page, Error> {
        let mut mailbox = self._shared.try_lock()?;
        let stream = checked_stream(&mut mailbox, epoch)?;
        if generation != stream.interest.generation
            || snapshot == 0
            || snapshot != stream.info.snapshot_id
        {
            return Err(Error::InvalidArgument);
        }
        if stream.info.stage != Stage::Ready {
            return Err(Error::NotReady);
        }
        if index >= stream.info.total_pages {
            return Err(Error::InvalidArgument);
        }
        let mut chunk_page = index;
        let mut chunk = 0;
        while chunk_page >= page_count(&stream.meshes[chunk]) {
            chunk_page -= page_count(&stream.meshes[chunk]);
            chunk += 1;
        }
        let mesh = &stream.meshes[chunk];
        let face_start = chunk_page * FACES_PER_PAGE;
        let faces = (mesh.indices.len() / 6)
            .saturating_sub(face_start)
            .min(FACES_PER_PAGE);
        let payload = PAGE_DESCRIPTION_BYTES + faces * FACE_BYTES;
        if payload > bytes.min(PAGE_BYTES) {
            return Err(Error::InvalidArgument);
        }
        let vertex_start = face_start * 4;
        let vertex_end = vertex_start + faces * 4;
        let index_start = face_start * 6;
        let index_end = index_start + faces * 6;
        let page_mesh = Mesh {
            origin: mesh.origin,
            // A presentation round includes directions as well as geometry.
            // Raw World revisions count cells, while Factory counts commands.
            world_revision: stream.info.revision,
            bounds_min: mesh.bounds_min,
            bounds_max: mesh.bounds_max,
            positions: mesh.positions[vertex_start..vertex_end].to_vec(),
            normals: mesh.normals[vertex_start..vertex_end].to_vec(),
            colors: mesh.colors[vertex_start..vertex_end].to_vec(),
            uv: mesh.uv[vertex_start..vertex_end].to_vec(),
            custom: mesh.custom[vertex_start..vertex_end].to_vec(),
            indices: mesh.indices[index_start..index_end]
                .iter()
                .map(|v| v - vertex_start as u32)
                .collect(),
            collision: mesh.collision[index_start..index_end].to_vec(),
        };
        stream.delivered[index] = true;
        Ok(Page {
            world_epoch: epoch,
            generation,
            job_id: stream.interest.job_id,
            snapshot_id: snapshot,
            revision: stream.info.revision,
            tick: stream.info.tick,
            page_index: index,
            total_pages: stream.info.total_pages,
            keys: stream.interest.keys.clone(),
            key: stream.interest.keys[chunk],
            chunk_page,
            chunk_pages: page_count(mesh),
            bytes: payload,
            mesh: page_mesh,
        })
    }
    pub fn acknowledge_presentation(
        &self,
        epoch: u64,
        generation: u64,
        snapshot: u64,
    ) -> Result<(), Error> {
        let mut mailbox = self._shared.try_lock()?;
        let stream = checked_stream(&mut mailbox, epoch)?;
        if stream.info.stage != Stage::Ready
            || generation != stream.interest.generation
            || snapshot == 0
            || snapshot != stream.info.snapshot_id
            || stream.delivered.iter().any(|&delivered| !delivered)
        {
            return Err(Error::InvalidAck);
        }
        stream.acknowledged = true;
        Ok(())
    }
}
fn page_count(mesh: &Mesh) -> usize {
    (mesh.indices.len() / 6).div_ceil(FACES_PER_PAGE).max(1)
}
pub(super) fn is_edit(command: &Command) -> bool {
    matches!(
        command,
        Command::Build(_)
            | Command::BuildRoute(_)
            | Command::Remove(_)
            | Command::SetDirection(_, _)
    )
}
pub(super) struct Build {
    epoch: u64,
    generation: u64,
    serial: u64,
    job_id: u64,
    revision: u64,
    meshes: Vec<Mesh>,
    bytes: usize,
}
/// Retire only the discarded candidate; keep the generation replay barrier.
pub(super) fn discard_candidate(mailbox: &mut Mailbox, state: &mut WorkerState, job_id: u64) {
    if mailbox
        .presentation
        .as_ref()
        .is_some_and(|stream| stream.interest.job_id == job_id)
    {
        mailbox.presentation = None;
    }
    if state
        .presentation
        .as_ref()
        .is_some_and(|build| build.job_id == job_id)
    {
        state.presentation = None;
    }
}
/// Returns true only after doing bounded work, so idle workers can keep building.
pub(super) fn service(shared: &Shared, active: &Factory, state: &mut WorkerState) -> bool {
    let mut mailbox = shared.lock();
    let Some(stream) = mailbox.presentation.as_mut() else {
        state.presentation = None;
        return false;
    };
    stream.expire(Instant::now());
    if stream.info.stage != Stage::Building {
        state.presentation = None;
        return false;
    }
    let interest = stream.interest.clone();
    let serial = stream.serial;
    let epoch = mailbox.epoch;
    let previous = state.presentation.take();
    let target = if interest.job_id == 0 {
        Some(active)
    } else {
        state
            .candidate
            .as_ref()
            .filter(|_| {
                mailbox
                    .candidate
                    .as_ref()
                    .is_some_and(|slot| slot.job_id == interest.job_id)
            })
            .map(|candidate| &candidate.factory)
    };
    let Some(target) = target else {
        mailbox.presentation = None;
        return false;
    };
    if interest.job_id == 0
        && mailbox.result.is_none()
        && mailbox
            .operation
            .as_ref()
            .is_some_and(|record| is_edit(&record.input.command))
    {
        return false;
    }
    let mut build = match previous {
        Some(build)
            if build.epoch == epoch
                && build.generation == interest.generation
                && build.serial == serial
                && build.revision == target.revision()
                && build.job_id == interest.job_id =>
        {
            build
        }
        _ => {
            let id = mailbox.next_presentation_id;
            if id >= i64::MAX as u64 {
                mailbox
                    .presentation
                    .as_mut()
                    .expect("subscription")
                    .abort(Failure::Geometry);
                return false;
            }
            mailbox.next_presentation_id += 1;
            let stream = mailbox.presentation.as_mut().expect("subscription");
            stream.info.snapshot_id = id;
            stream.info.revision = target.revision();
            stream.info.tick = target.clock().tick;
            Build {
                epoch,
                generation: interest.generation,
                serial,
                job_id: interest.job_id,
                revision: target.revision(),
                meshes: Vec::new(),
                bytes: 0,
            }
        }
    };
    drop(mailbox);
    let mesh = meshing::build(
        target.world(),
        interest.keys[build.meshes.len()],
        (SNAPSHOT_BYTES - build.bytes).min(meshing::MAX_MESH_BYTES),
        &|cell| target.direction_at(cell).map(|d| d.cell()),
    );
    let mut mailbox = shared.lock();
    if mailbox.epoch != epoch {
        return true;
    }
    let Some(stream) = mailbox
        .presentation
        .as_mut()
        .filter(|stream| stream.interest == interest && stream.serial == serial)
    else {
        return true;
    };
    stream.expire(Instant::now());
    if stream.info.stage != Stage::Building {
        return true;
    }
    match mesh {
        Ok(mesh) => {
            let charge = mesh.payload_bytes() + page_count(&mesh) * PAGE_DESCRIPTION_BYTES;
            if charge > SNAPSHOT_BYTES - build.bytes {
                stream.abort(Failure::Budget);
                return true;
            }
            build.bytes += charge;
            build.meshes.push(mesh);
            if build.meshes.len() == interest.keys.len() {
                stream.info.total_pages = build.meshes.iter().map(page_count).sum();
                stream.info.total_bytes = build.bytes;
                stream.info.stage = Stage::Ready;
                stream.delivered = vec![false; stream.info.total_pages];
                stream.meshes = build.meshes;
            } else {
                state.presentation = Some(build);
            }
        }
        Err(meshing::Error::Budget) => stream.abort(Failure::Budget),
        Err(_) => stream.abort(Failure::Geometry),
    }
    true
}

#[cfg(test)]
mod tests {
    use super::super::{
        Command, Input, Limits, Outcome,
        candidate::{Candidate, CandidateSlot},
        controls,
    };
    use super::*;
    use crate::{
        factory::Ruleset,
        logistics::Settings,
        persistence::{Player, Session, jobs::Cancellation},
    };
    use std::sync::Arc;

    fn candidate_fixture() -> (Runtime, Factory, WorkerState) {
        let settings = Settings {
            interval: 0.1,
            amount: 1,
        };
        let active = Factory::new(Bounds::default(), settings, Ruleset::LegacyDiscreteV1).unwrap();
        let candidate = Candidate {
            factory: Factory::new(Bounds::default(), settings, Ruleset::LegacyDiscreteV1).unwrap(),
            session: Session {
                world_id: [1; 16],
                world_name: "Candidate".into(),
                autosave_minutes: 0.0,
                autosave_retention: 3,
                player: Player::default(),
            },
        };
        let shared = Arc::new(Shared::default());
        {
            let mut mailbox = shared.lock();
            mailbox.status = Status::Running;
            mailbox.timing.paused = true;
            mailbox.candidate = Some(CandidateSlot {
                job_id: 3,
                cancellation: Cancellation::default(),
                payload: Some(candidate.info(3)),
                ready_requested: false,
                next_epoch: None,
                switch_requested: false,
            });
        }
        (
            Runtime {
                _shared: shared,
                _limits: Limits::default(),
                _persistence: true,
            },
            active,
            WorkerState {
                candidate: Some(candidate),
                ..WorkerState::default()
            },
        )
    }

    #[test]
    fn cancelling_acknowledged_candidate_releases_arrays_without_resetting_generation() {
        let (runtime, active, mut state) = candidate_fixture();
        let interest = Interest {
            generation: 7,
            job_id: 3,
            keys: vec![Cell::new(0, -1, 0)],
        };
        runtime.subscribe_presentation(1, &interest).unwrap();
        assert!(service(&runtime._shared, &active, &mut state));
        let info = runtime.poll_presentation(1).unwrap();
        assert_eq!(info.stage, Stage::Ready);
        let page = runtime
            .poll_presentation_page(1, 7, info.snapshot_id, 0, PAGE_BYTES)
            .unwrap();
        assert!(!page.mesh.positions.is_empty());
        runtime
            .acknowledge_presentation(1, 7, info.snapshot_id)
            .unwrap();
        runtime.cancel(1, 3).unwrap();
        {
            let mut mailbox = runtime._shared.lock();
            controls::discard_cancelled(&mut mailbox, &mut state);
            assert_eq!(
                mailbox.job_result.as_ref().unwrap().outcome,
                Outcome::LoadFailed {
                    job_id: 3,
                    error: super::super::SaveError::Cancelled,
                }
            );
            assert!(mailbox.candidate.is_none() && state.candidate.is_none());
            assert!(mailbox.presentation.is_none(), "cancelled arrays retained");
            assert!(state.presentation.is_none());
            assert_eq!(mailbox.presentation_generation, 7);
        }
        assert_eq!(runtime.poll_presentation(1), Err(Error::NotReady));
        assert_eq!(
            runtime.subscribe_presentation(
                1,
                &Interest {
                    job_id: 0,
                    ..interest
                }
            ),
            Err(Error::AlreadyFinalized)
        );
    }

    #[test]
    fn candidate_discard_releases_partial_build_on_cancel_and_failed_ready() {
        for ready in [false, true] {
            let (runtime, mut active, mut state) = candidate_fixture();
            runtime
                .subscribe_presentation(
                    1,
                    &Interest {
                        generation: 1,
                        job_id: 3,
                        keys: vec![Cell::new(0, -1, 0), Cell::new(1, -1, 0)],
                    },
                )
                .unwrap();
            assert!(service(&runtime._shared, &active, &mut state));
            assert!(state.presentation.is_some());
            assert_eq!(runtime.poll_presentation(1).unwrap().stage, Stage::Building);
            assert!(runtime.cancel(1, 3).unwrap());
            if ready {
                runtime
                    .submit(
                        1,
                        &Input {
                            request_id: 4,
                            command: Command::PresentationReady { job_id: 3 },
                        },
                    )
                    .unwrap();
            }
            let mut mailbox = runtime._shared.lock();
            if ready {
                mailbox.pending = false;
                let outcome = controls::execute(
                    &mut mailbox,
                    &mut state,
                    &mut active,
                    Command::PresentationReady { job_id: 3 },
                );
                mailbox.publish(1, 4, 0, outcome);
            } else {
                controls::discard_cancelled(&mut mailbox, &mut state);
            }
            let result = if ready {
                &mailbox.result
            } else {
                &mailbox.job_result
            };
            assert_eq!(
                result.as_ref().unwrap().outcome,
                Outcome::LoadFailed {
                    job_id: 3,
                    error: super::super::SaveError::Cancelled
                }
            );
            assert!(state.candidate.is_none() && mailbox.candidate.is_none());
            assert!(!mailbox.handoff_frozen);
            assert!(
                mailbox.presentation.is_none(),
                "discarded subscription retained"
            );
            assert!(
                state.presentation.is_none(),
                "discarded partial build retained"
            );
        }
    }

    #[test]
    fn cancelling_candidate_preserves_active_world_subscription_and_partial_build() {
        let (runtime, active, mut state) = candidate_fixture();
        runtime
            .subscribe_presentation(
                1,
                &Interest {
                    generation: 1,
                    job_id: 0,
                    keys: vec![Cell::new(0, -1, 0), Cell::new(1, -1, 0)],
                },
            )
            .unwrap();
        assert!(service(&runtime._shared, &active, &mut state));
        runtime.cancel(1, 3).unwrap();
        {
            let mut mailbox = runtime._shared.lock();
            controls::discard_cancelled(&mut mailbox, &mut state);
            assert!(mailbox.presentation.is_some() && state.presentation.is_some());
            assert_eq!(mailbox.presentation_generation, 1);
        }
        assert!(service(&runtime._shared, &active, &mut state));
        assert_eq!(runtime.poll_presentation(1).unwrap().stage, Stage::Ready);
    }

    fn interest() -> Interest {
        Interest {
            generation: 1,
            job_id: 0,
            keys: vec![Cell::new(0, 0, 0)],
        }
    }

    #[test]
    fn timeout_releases_pages_and_requires_a_fresh_generation() {
        let mut stream = Stream::new(1, interest());
        let world = crate::world::World::flat(Bounds::default());
        stream.meshes.push(
            meshing::build(
                &world,
                Cell::new(0, -1, 0),
                meshing::MAX_MESH_BYTES,
                &|_| None,
            )
            .unwrap(),
        );
        stream.delivered.push(false);
        stream.info.stage = Stage::Ready;
        stream.expire(stream.requested + LIFETIME);
        assert_eq!(stream.info.failure, Some(Failure::Expired));
        assert!(stream.meshes.is_empty() && stream.delivered.is_empty());
        stream.invalidate(2);
        assert_eq!(stream.info.stage, Stage::Aborted);
    }

    #[test]
    fn total_budget_failure_publishes_no_partial_pages() {
        let active = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        let shared = Shared::default();
        shared.lock().presentation = Some(Stream::new(1, interest()));
        let mut state = WorkerState {
            presentation: Some(Build {
                epoch: 1,
                generation: 1,
                serial: 0,
                job_id: 0,
                revision: active.revision(),
                meshes: Vec::new(),
                bytes: SNAPSHOT_BYTES - 1,
            }),
            ..WorkerState::default()
        };
        assert!(service(&shared, &active, &mut state));
        let mailbox = shared.lock();
        let stream = mailbox.presentation.as_ref().unwrap();
        assert_eq!(stream.info.stage, Stage::Aborted);
        assert_eq!(stream.info.failure, Some(Failure::Budget));
        assert!(stream.meshes.is_empty() && stream.delivered.is_empty());
        assert!(state.presentation.is_none());
    }
}
