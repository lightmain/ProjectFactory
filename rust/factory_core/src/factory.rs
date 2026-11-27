//! Shared synchronous factory entry point with atomic, versioned construction.
use crate::{
    belt_placement::{self, Builder, Direction},
    logistics::{self, Settings, State, continuous},
    world::{Block, Bounds, Cell, World},
};
pub use continuous::Ledger;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Ruleset {
    LegacyDiscreteV1,
    ConveyorContinuousV1,
}
impl Ruleset {
    pub fn name(self) -> &'static str {
        match self {
            Self::LegacyDiscreteV1 => "legacy_discrete_v1",
            Self::ConveyorContinuousV1 => "conveyor_continuous_v1",
        }
    }
    pub fn parse(value: &str) -> Result<Self, Error> {
        match value {
            "legacy_discrete_v1" => Ok(Self::LegacyDiscreteV1),
            "conveyor_continuous_v1" => Ok(Self::ConveyorContinuousV1),
            _ => Err(Error::InvalidRequest),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Error {
    Legacy(logistics::Error),
    Continuous(continuous::Error),
    Route(belt_placement::Error),
    InvalidRequest,
    StalePreview,
}
impl From<logistics::Error> for Error {
    fn from(error: logistics::Error) -> Self {
        Self::Legacy(error)
    }
}
impl From<continuous::Error> for Error {
    fn from(error: continuous::Error) -> Self {
        Self::Continuous(error)
    }
}

#[derive(Clone, Debug)]
pub struct Preview {
    owner: Arc<()>,
    request: u64,
    revision: u64,
    additions: Vec<(Cell, Block, Direction)>,
    start_redirect: Option<(Cell, Direction)>,
    route: Vec<belt_placement::Segment>,
}
impl Preview {
    pub fn additions(&self) -> &[(Cell, Block, Direction)] {
        &self.additions
    }
}

enum Storage {
    Legacy(Box<logistics::Factory>),
    Continuous(Box<continuous::Factory>),
}
enum Saved {
    Legacy(Box<logistics::Checkpoint>),
    Continuous(Box<continuous::Checkpoint>),
}
pub struct Checkpoint {
    saved: Saved,
    revision: u64,
    next_request: u64,
}
pub struct Factory {
    _owner: Arc<()>,
    _storage: Storage,
    _revision: u64,
    _next_request: u64,
    _active: Option<u64>,
}

impl Factory {
    pub(crate) fn disk_sections(&self) -> crate::persistence::Result<[Vec<u8>; 6]> {
        let mut sections = match &self._storage {
            Storage::Legacy(f) => f.disk_sections(),
            Storage::Continuous(f) => f.disk_sections()?,
        };
        let mut clock = crate::persistence::Writer::default();
        clock.u64(self._revision);
        clock.u64(self._next_request);
        clock.bytes(&sections[4]);
        sections[4] = clock.0;
        Ok(sections)
    }
    pub(crate) fn from_disk_sections(
        ruleset: Ruleset,
        sections: &[Vec<u8>; 6],
    ) -> crate::persistence::Result<Self> {
        use crate::persistence::{MAX_BYTES, Reader, ensure};
        let mut c = Reader::new(&sections[4]);
        let revision = c.u64()?;
        let next_request = c.u64()?;
        ensure(
            revision < i64::MAX as u64 && next_request > 0 && next_request < u64::MAX,
            "factory identity",
        )?;
        let mut inner = sections.each_ref().map(Vec::as_slice);
        inner[4] = c.bytes(MAX_BYTES)?;
        c.end()?;
        let storage = match ruleset {
            Ruleset::LegacyDiscreteV1 => {
                ensure(
                    inner[2].is_empty() && inner[3].is_empty(),
                    "legacy transport sections",
                )?;
                Storage::Legacy(Box::new(logistics::Factory::from_disk_sections(
                    &inner, false,
                )?))
            }
            Ruleset::ConveyorContinuousV1 => {
                Storage::Continuous(Box::new(continuous::Factory::from_disk_sections(&inner)?))
            }
        };
        Ok(Self {
            _owner: Arc::new(()),
            _storage: storage,
            _revision: revision,
            _next_request: next_request,
            _active: None,
        })
    }

    pub fn new(bounds: Bounds, settings: Settings, ruleset: Ruleset) -> Result<Self, Error> {
        let storage = match ruleset {
            Ruleset::LegacyDiscreteV1 => {
                Storage::Legacy(Box::new(logistics::Factory::new(bounds, settings)))
            }
            Ruleset::ConveyorContinuousV1 => {
                Storage::Continuous(Box::new(continuous::Factory::new(bounds, settings)?))
            }
        };
        Ok(Self {
            _owner: Arc::new(()),
            _storage: storage,
            _revision: 0,
            _next_request: 1,
            _active: None,
        })
    }
    pub fn ruleset(&self) -> Ruleset {
        match self._storage {
            Storage::Legacy(_) => Ruleset::LegacyDiscreteV1,
            Storage::Continuous(_) => Ruleset::ConveyorContinuousV1,
        }
    }
    pub fn world(&self) -> &World {
        match &self._storage {
            Storage::Legacy(factory) => factory.world(),
            Storage::Continuous(factory) => factory.world(),
        }
    }
    pub fn ledger(&self) -> Ledger {
        match &self._storage {
            Storage::Legacy(factory) => factory.ledger(),
            Storage::Continuous(factory) => factory.ledger(),
        }
    }
    /// A bounded index lookup; presentation must never materialize all machines.
    pub fn direction_at(&self, cell: Cell) -> Option<Direction> {
        match &self._storage {
            Storage::Legacy(factory) => factory.direction_at(cell),
            Storage::Continuous(factory) => factory.direction_at(cell),
        }
    }
    pub fn revision(&self) -> u64 {
        self._revision
    }
    pub fn clock(&self) -> logistics::Clock {
        match &self._storage {
            Storage::Legacy(factory) => factory.clock(),
            Storage::Continuous(factory) => factory.clock(),
        }
    }
    pub fn observe(&self) -> Result<State, Error> {
        match &self._storage {
            Storage::Legacy(factory) => Ok(factory.observe()),
            Storage::Continuous(factory) => Ok(factory.observe()?),
        }
    }
    pub fn local_machine(
        &self,
        cell: Cell,
        limit: usize,
    ) -> Result<Option<logistics::MachineState>, Error> {
        match &self._storage {
            Storage::Legacy(factory) => Ok(factory.local_machine(cell, limit)?),
            Storage::Continuous(factory) => Ok(factory.local_machine(cell, limit)?),
        }
    }
    pub fn checkpoint(&self) -> Result<Checkpoint, Error> {
        let saved = match &self._storage {
            Storage::Legacy(factory) => Saved::Legacy(Box::new(factory.checkpoint())),
            Storage::Continuous(factory) => Saved::Continuous(Box::new(factory.checkpoint()?)),
        };
        Ok(Checkpoint {
            saved,
            revision: self._revision,
            next_request: self._next_request,
        })
    }
    pub fn from_checkpoint(checkpoint: Checkpoint) -> Result<Self, Error> {
        let storage = match checkpoint.saved {
            Saved::Legacy(saved) => {
                Storage::Legacy(Box::new(logistics::Factory::from_checkpoint(*saved)))
            }
            Saved::Continuous(saved) => {
                Storage::Continuous(Box::new(continuous::Factory::from_checkpoint(*saved)?))
            }
        };
        Ok(Self {
            _owner: Arc::new(()),
            _storage: storage,
            _revision: checkpoint.revision,
            _next_request: checkpoint.next_request,
            _active: None,
        })
    }
    pub fn advance(&mut self, delta: f64) -> Result<(), Error> {
        match &mut self._storage {
            Storage::Legacy(factory) => factory.advance(delta)?,
            Storage::Continuous(factory) => factory.advance(delta)?,
        }
        Ok(())
    }

    pub fn preview(&mut self, additions: &[(Cell, Block, Direction)]) -> Result<Preview, Error> {
        self._preview(additions, None)
    }

    fn _preview(
        &mut self,
        additions: &[(Cell, Block, Direction)],
        start_redirect: Option<(Cell, Direction)>,
    ) -> Result<Preview, Error> {
        self._active = None;
        if (additions.is_empty() && start_redirect.is_none())
            || additions.len() > crate::route::MAX_ROUTE_CELLS
        {
            return Err(Error::InvalidRequest);
        }
        let mut world = self.world().clone();
        for &(cell, block, direction) in additions {
            world.place(cell, block).map_err(logistics::Error::from)?;
            if block.is_slope() {
                let fixed = [
                    Direction::South,
                    Direction::West,
                    Direction::North,
                    Direction::East,
                ][usize::from((block as u8 - 9) % 4)];
                if direction != fixed {
                    return Err(logistics::Error::FixedDirection.into());
                }
            }
        }
        let request = self._next_request;
        self._next_request += 1;
        self._active = Some(request);
        Ok(Preview {
            owner: self._owner.clone(),
            request,
            revision: self._revision,
            additions: additions.to_vec(),
            start_redirect,
            route: Vec::new(),
        })
    }

    pub fn preview_route(&mut self, builder: &Builder) -> Result<Preview, Error> {
        self._active = None;
        builder
            .validate(self.world(), &|cell| self.direction_at(cell))
            .map_err(Error::Route)?;
        let additions = builder
            .path()
            .iter()
            .filter(|segment| self.world().block(segment.cell) == Block::Air)
            .map(|segment| (segment.cell, segment.block, segment.direction))
            .collect::<Vec<_>>();
        let start_redirect = builder.path().first().and_then(|segment| {
            (self.world().block(segment.cell) == Block::Belt)
                .then_some((segment.cell, segment.direction))
        });
        let mut preview = self._preview(&additions, start_redirect)?;
        preview.route = builder.path().to_vec();
        Ok(preview)
    }

    pub fn cancel_preview(&mut self) {
        self._active = None;
    }

    pub fn commit(&mut self, preview: &Preview) -> Result<(), Error> {
        if !Arc::ptr_eq(&self._owner, &preview.owner)
            || self._active != Some(preview.request)
            || self._revision != preview.revision
        {
            return Err(Error::StalePreview);
        }
        let mut candidate = Self::from_checkpoint(self.checkpoint()?)?;
        match &mut candidate._storage {
            Storage::Legacy(factory) => {
                for &(cell, block, direction) in &preview.additions {
                    factory.place(cell, block)?;
                    if belt_placement::is_machine(block) {
                        factory.set_direction(cell, direction)?;
                    }
                }
            }
            Storage::Continuous(factory) => {
                factory.place_route(&preview.additions, &preview.route)?
            }
        }
        if let Some((cell, direction)) = preview.start_redirect {
            match &mut candidate._storage {
                Storage::Legacy(factory) => factory.set_direction(cell, direction)?,
                Storage::Continuous(_) => (),
            }
        }
        candidate._revision += 1;
        self._storage = candidate._storage;
        self._revision = candidate._revision;
        self._active = None;
        Ok(())
    }

    pub fn place(&mut self, cell: Cell, block: Block, direction: Direction) -> Result<(), Error> {
        let preview = self.preview(&[(cell, block, direction)])?;
        self.commit(&preview)
    }
    pub fn remove(&mut self, cell: Cell) -> Result<(), Error> {
        match &mut self._storage {
            Storage::Legacy(factory) => factory.remove(cell)?,
            Storage::Continuous(factory) => factory.remove(cell)?,
        }
        self._revision += 1;
        self._active = None;
        Ok(())
    }
    pub fn set_direction(&mut self, cell: Cell, direction: Direction) -> Result<(), Error> {
        match &mut self._storage {
            Storage::Legacy(factory) => factory.set_direction(cell, direction)?,
            Storage::Continuous(factory) => factory.set_direction(cell, direction)?,
        }
        self._revision += 1;
        self._active = None;
        Ok(())
    }
}
