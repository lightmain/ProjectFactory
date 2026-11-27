//! Short build preparation, with bounded authoritative geometry checks.
use super::{Command, Error, Outcome, WorkerState, queries::RouteRequest};
use crate::{
    belt_placement::Direction,
    factory::{self, Factory, Preview},
    world::{Block, Bounds, Cell},
};

#[derive(Clone, Debug, PartialEq)]
pub struct Aabb {
    pub low: [f64; 3],
    pub high: [f64; 3],
}
impl Aabb {
    fn valid(&self) -> bool {
        (0..3).all(|i| {
            self.low[i].is_finite()
                && self.high[i].is_finite()
                && self.low[i].abs() <= 256.
                && self.high[i].abs() <= 256.
                && self.high[i] > self.low[i]
                && self.high[i] - self.low[i] <= 4.
        })
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Pose {
    pub frame: u64,
    pub player: Aabb,
    pub camera: Option<Aabb>,
    pub margin: f64,
}
impl Pose {
    pub(super) fn valid(&self) -> bool {
        self.frame > 0
            && self.frame <= i64::MAX as u64
            && self.player.valid()
            && self.camera.as_ref().is_none_or(Aabb::valid)
            && self.margin.is_finite()
            && (0.0..=0.1).contains(&self.margin)
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum Intent {
    Cells(Vec<(Cell, Block, Direction)>),
    Route(RouteRequest),
}
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub pose: Pose,
    pub intent: Intent,
}
impl Request {
    pub(super) fn bytes(&self, bounds: Bounds) -> Result<usize, Error> {
        if !self.pose.valid() {
            return Err(Error::InvalidArgument);
        }
        Ok(160
            + match &self.intent {
                Intent::Cells(cells) => Command::Build(cells.clone()).bytes(bounds)?,
                Intent::Route(route) => route.bytes(bounds)?,
            })
    }
    fn preview(&self, factory: &mut Factory) -> Result<Preview, factory::Error> {
        match &self.intent {
            Intent::Cells(cells) => factory.preview(cells),
            Intent::Route(route) => factory.preview_route(&route.plan(factory)?),
        }
    }
}
pub(super) struct Prepared {
    token: u64,
    revision: u64,
    request: Request,
    lift: f64,
}

fn surface(cell: Cell, block: Block, x: f64, z: f64) -> f64 {
    f64::from(cell.y) * 0.5
        + block
            .slope_elevation(x * 2. - f64::from(cell.x), z * 2. - f64::from(cell.z))
            .map_or(if block == Block::Belt { 0.08 } else { 0.5 }, |elevation| {
                elevation * 0.5 + 0.08
            })
}
fn overlaps(cell: Cell, block: Block, bounds: &Aabb) -> bool {
    if block == Block::Air {
        return false;
    }
    let low = [
        f64::from(cell.x) * 0.5,
        f64::from(cell.y) * 0.5,
        f64::from(cell.z) * 0.5,
    ];
    let height = if block.is_slope() {
        0.58
    } else if block == Block::Belt {
        0.08
    } else {
        0.5
    };
    let high = [low[0] + 0.5, low[1] + height, low[2] + 0.5];
    if (0..3).any(|i| bounds.low[i] >= high[i] || bounds.high[i] <= low[i]) {
        return false;
    }
    if !block.is_slope() {
        return true;
    }
    let mut bottom = f64::INFINITY;
    let mut top = f64::NEG_INFINITY;
    for x in [bounds.low[0].max(low[0]), bounds.high[0].min(high[0])] {
        for z in [bounds.low[2].max(low[2]), bounds.high[2].min(high[2])] {
            let y = surface(cell, block, x, z);
            bottom = bottom.min(y - 0.08);
            top = top.max(y);
        }
    }
    bounds.low[1] < top && bounds.high[1] > bottom
}
/// Cells must be the new additions only; existing route members cannot lift again.
pub fn validate(
    factory: &Factory,
    pose: &Pose,
    additions: &[(Cell, Block, Direction)],
    allow_lift: bool,
) -> Result<f64, factory::Error> {
    if !pose.valid() {
        return Err(factory::Error::InvalidRequest);
    }
    let mut lift = pose.player.low[1];
    for &(cell, block, _) in additions {
        if pose
            .camera
            .as_ref()
            .is_some_and(|camera| overlaps(cell, block, camera))
        {
            return Err(factory::Error::InvalidRequest);
        }
        if !overlaps(cell, block, &pose.player) {
            continue;
        }
        if !allow_lift || !block.is_belt() {
            return Err(factory::Error::InvalidRequest);
        }
        let low_x = pose.player.low[0].max(f64::from(cell.x) * 0.5);
        let high_x = pose.player.high[0].min(f64::from(cell.x) * 0.5 + 0.5);
        let low_z = pose.player.low[2].max(f64::from(cell.z) * 0.5);
        let high_z = pose.player.high[2].min(f64::from(cell.z) * 0.5 + 0.5);
        for x in [low_x, high_x] {
            for z in [low_z, high_z] {
                lift = lift.max(surface(cell, block, x, z));
            }
        }
    }
    if lift <= pose.player.low[1] {
        return Ok(lift);
    }
    let mut head = pose.player.clone();
    head.low[1] = pose.player.high[1];
    head.high[1] += lift + pose.margin - pose.player.low[1];
    for i in 0..3 {
        head.low[i] -= pose.margin;
        head.high[i] += pose.margin;
    }
    for &(cell, block, _) in additions {
        if !overlaps(cell, block, &pose.player) && overlaps(cell, block, &head) {
            return Err(factory::Error::InvalidRequest);
        }
    }
    let low = head.low.map(|v| (v * 2.).floor() as i32);
    let high = head.high.map(|v| (v * 2.).floor() as i32);
    let count: i64 = (0..3)
        .map(|i| i64::from(high[i]) - i64::from(low[i]) + 1)
        .product();
    if !(1..=32768).contains(&count) {
        return Err(factory::Error::InvalidRequest);
    }
    // Include the lower cell because slopes protrude into the next cell.
    for x in low[0]..=high[0] {
        for y in low[1] - 1..=high[1] {
            for z in low[2]..=high[2] {
                let cell = Cell::new(x, y, z);
                if overlaps(cell, factory.world().block(cell), &head) {
                    return Err(factory::Error::InvalidRequest);
                }
            }
        }
    }
    Ok(lift)
}
pub(super) fn prepare(
    factory: &mut Factory,
    state: &mut WorkerState,
    token: u64,
    request: Request,
) -> Result<Outcome, factory::Error> {
    state.prepared_build = None;
    let preview = request.preview(factory)?;
    let lift = validate(
        factory,
        &request.pose,
        preview.additions(),
        matches!(request.intent, Intent::Route(_)),
    )?;
    factory.cancel_preview();
    let pose_frame = request.pose.frame;
    state.prepared_build = Some(Prepared {
        token,
        revision: factory.revision(),
        request,
        lift,
    });
    Ok(Outcome::BuildPrepared {
        token,
        pose_frame,
        lift,
    })
}
pub(super) fn confirm(
    factory: &mut Factory,
    state: &mut WorkerState,
    token: u64,
    pose: Pose,
    engine_clear: bool,
) -> Result<Outcome, factory::Error> {
    let prepared = state
        .prepared_build
        .take()
        .ok_or(factory::Error::StalePreview)?;
    if !engine_clear
        || token != prepared.token
        || pose != prepared.request.pose
        || factory.revision() != prepared.revision
    {
        return Err(factory::Error::StalePreview);
    }
    let preview = prepared.request.preview(factory)?;
    let lift = validate(
        factory,
        &pose,
        preview.additions(),
        matches!(prepared.request.intent, Intent::Route(_)),
    )?;
    if lift != prepared.lift {
        return Err(factory::Error::StalePreview);
    }
    factory.commit(&preview)?;
    Ok(Outcome::BuildCommitted { lift })
}
