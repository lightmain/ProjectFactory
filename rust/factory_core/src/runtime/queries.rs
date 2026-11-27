//! One bounded query payload, replaced when a later query is accepted.
use super::{Error, Outcome, Runtime};
use crate::{
    belt_placement::{self, Builder, Direction, Segment},
    factory::{self, Factory},
    queries::{self, Hit},
    world::{Block, Bounds, Cell},
};

pub const MAX_QUERY_BYTES: usize = 8192;
pub const MAX_ROUTE_SEGMENTS: usize = 256;
pub const MAX_ROUTE_TARGETS: usize = 16;
const HEADER_BYTES: usize = 96;
const RAY_BYTES: usize = 160;
// Three i32 cell coordinates, one i32 block and one i32 direction.
const SEGMENT_BYTES: usize = 20;

#[derive(Clone, Debug, PartialEq)]
pub struct RouteTarget {
    pub cell: Cell,
    pub north_south_first: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub struct RouteRequest {
    pub start: Cell,
    pub direction: Direction,
    pub max_cells: usize,
    /// Every target except the last is locked before continuing.
    pub targets: Vec<RouteTarget>,
}
impl RouteRequest {
    pub(super) fn bytes(&self, bounds: Bounds) -> Result<usize, Error> {
        if self.max_cells == 0
            || self.max_cells > MAX_ROUTE_SEGMENTS
            || self.targets.is_empty()
            || self.targets.len() > MAX_ROUTE_TARGETS
        {
            return Err(Error::InvalidArgument);
        }
        if !bounds.contains(self.start) || self.targets.iter().any(|t| !bounds.contains(t.cell)) {
            return Err(Error::OutOfBounds);
        }
        Ok(64 + 16 * self.targets.len())
    }
    pub(super) fn plan(&self, factory: &Factory) -> Result<Builder, factory::Error> {
        let mut builder = Builder::new(self.max_cells).map_err(factory::Error::Route)?;
        let directions = |cell| factory.direction_at(cell);
        builder
            .begin(factory.world(), &directions, self.start, self.direction)
            .map_err(factory::Error::Route)?;
        for (index, target) in self.targets.iter().enumerate() {
            if builder.north_south_first() != target.north_south_first {
                builder.toggle_order();
            }
            builder
                .preview(
                    factory.world(),
                    &directions,
                    Some(target.cell),
                    self.direction,
                )
                .map_err(factory::Error::Route)?;
            if index + 1 < self.targets.len() {
                builder
                    .lock(factory.world(), &directions)
                    .map_err(factory::Error::Route)?;
            }
        }
        Ok(builder)
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum QueryKind {
    Ray {
        origin: [f64; 3],
        direction: [f64; 3],
        distance: f64,
    },
    Build(Vec<(Cell, Block, Direction)>),
    Route(RouteRequest),
}
#[derive(Clone, Debug, PartialEq)]
pub struct Query {
    pub query_id: u64,
    pub view_generation: u64,
    pub kind: QueryKind,
}
impl Query {
    pub(super) fn bytes(&self, bounds: Bounds) -> Result<usize, Error> {
        if self.query_id == 0
            || self.query_id > i64::MAX as u64
            || self.view_generation == 0
            || self.view_generation > i64::MAX as u64
        {
            return Err(Error::InvalidArgument);
        }
        let bytes = match &self.kind {
            QueryKind::Ray {
                origin,
                direction,
                distance,
            } => {
                if !origin.iter().chain(direction).all(|v| v.is_finite())
                    || direction.iter().all(|v| v.abs() < 0.00001)
                    || !distance.is_finite()
                    || *distance < 0.0
                {
                    return Err(Error::InvalidArgument);
                }
                80
            }
            QueryKind::Build(cells) => {
                if cells.is_empty()
                    || cells.len() > super::MAX_BUILD_CELLS
                    || cells.iter().any(|(_, block, _)| *block == Block::Air)
                {
                    return Err(Error::InvalidArgument);
                }
                if cells.iter().any(|(cell, _, _)| !bounds.contains(*cell)) {
                    return Err(Error::OutOfBounds);
                }
                32 + 16 * cells.len()
            }
            QueryKind::Route(route) => route.bytes(bounds)?,
        };
        Ok(16 + bytes)
    }
    pub(super) fn payload_budget(&self) -> usize {
        match &self.kind {
            QueryKind::Ray { .. } => RAY_BYTES,
            QueryKind::Build(cells) => HEADER_BYTES + SEGMENT_BYTES * cells.len(),
            QueryKind::Route(route) => HEADER_BYTES + SEGMENT_BYTES * route.max_cells,
        }
    }
    pub(super) fn execute(&self, factory: &mut Factory) -> Result<QueryPayload, factory::Error> {
        match &self.kind {
            QueryKind::Ray {
                origin,
                direction,
                distance,
            } => {
                let hit =
                    queries::cast(factory.world(), *origin, *direction, *distance).map(|hit| {
                        RayHit {
                            block: factory.world().block(hit.cell),
                            direction: factory.direction_at(hit.cell),
                            route_target: belt_placement::target_cell(factory.world(), hit),
                            hit,
                        }
                    });
                Ok(QueryPayload::Ray(hit))
            }
            QueryKind::Build(cells) => {
                let preview = factory.preview(cells)?;
                let rows = preview
                    .additions()
                    .iter()
                    .map(|&(cell, block, direction)| Segment {
                        cell,
                        block,
                        direction,
                    })
                    .collect();
                factory.cancel_preview();
                Ok(QueryPayload::Preview(rows))
            }
            QueryKind::Route(route) => {
                let builder = route.plan(factory)?;
                Ok(QueryPayload::Preview(builder.path().to_vec()))
            }
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct RayHit {
    pub hit: Hit,
    pub block: Block,
    pub direction: Option<Direction>,
    pub route_target: Option<Cell>,
}
#[derive(Clone, Debug, PartialEq)]
pub enum QueryPayload {
    Ray(Option<RayHit>),
    Preview(Vec<Segment>),
}
impl QueryPayload {
    pub fn bytes(&self) -> usize {
        match self {
            Self::Ray(_) => RAY_BYTES,
            Self::Preview(rows) => HEADER_BYTES + SEGMENT_BYTES * rows.len(),
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct QueryPage {
    pub world_epoch: u64,
    pub request_id: u64,
    pub query_id: u64,
    pub view_generation: u64,
    pub tick: i64,
    pub revision: u64,
    pub payload_bytes: usize,
    pub payload: QueryPayload,
}
pub(super) struct QuerySlot {
    pub request_id: u64,
    pub query_id: u64,
    pub payload: Option<QueryPage>,
}
impl Runtime {
    /// Pure bounded memory copy. Completion consumption does not discard payload.
    pub fn poll_query(
        &self,
        epoch: u64,
        request_id: u64,
        query_id: u64,
        bytes: usize,
    ) -> Result<QueryPage, Error> {
        if self
            ._shared
            .closing
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Err(Error::Closed);
        }
        let mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if mailbox.status == super::Status::Faulted {
            return Err(Error::Faulted);
        }
        let slot = mailbox.query.as_ref().ok_or(Error::InvalidArgument)?;
        if request_id == 0
            || query_id == 0
            || slot.request_id != request_id
            || slot.query_id != query_id
        {
            return Err(Error::InvalidArgument);
        }
        let payload = slot.payload.as_ref().ok_or(Error::NotReady)?;
        if bytes.min(MAX_QUERY_BYTES) < payload.payload_bytes {
            return Err(Error::InvalidArgument);
        }
        Ok(payload.clone())
    }
}
pub(super) fn outcome(query: &Query, payload: &QueryPayload) -> Outcome {
    Outcome::QueryReady {
        query_id: query.query_id,
        view_generation: query.view_generation,
        payload_bytes: payload.bytes(),
    }
}
