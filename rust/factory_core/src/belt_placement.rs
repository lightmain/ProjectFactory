//! Read-only, bounded belt planning. Factory transactions own actual commits.
use crate::{
    queries::Hit,
    route::{self, MAX_ROUTE_CELLS},
    world::{self, Block, Cell, World},
};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Direction {
    South,
    West,
    North,
    East,
}

impl Direction {
    pub const fn cell(self) -> Cell {
        match self {
            Self::South => Cell::new(0, 0, 1),
            Self::West => Cell::new(-1, 0, 0),
            Self::North => Cell::new(0, 0, -1),
            Self::East => Cell::new(1, 0, 0),
        }
    }

    pub const fn opposite(self) -> Self {
        match self {
            Self::South => Self::North,
            Self::West => Self::East,
            Self::North => Self::South,
            Self::East => Self::West,
        }
    }

    fn between(from: Cell, to: Cell) -> Self {
        if to.x > from.x {
            Self::East
        } else if to.x < from.x {
            Self::West
        } else if to.z > from.z {
            Self::South
        } else {
            Self::North
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Segment {
    pub cell: Cell,
    pub block: Block,
    pub direction: Direction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidLimit,
    TooLong,
    Inactive,
    NoTarget,
    OutOfBounds,
    Occupied,
    BeltCrossing,
    GeometryConflict,
    StartChanged,
    StartDirectionChanged,
    EndChanged,
    MissingDirection,
    MinerHasNoInput,
    StartPort,
    EndPort,
    BeltOutput,
    InsufficientRamps,
    Disconnected,
    SlopeTurn,
    SelfCrossing,
}

pub fn target_cell(world: &World, hit: Hit) -> Option<Cell> {
    if is_machine(world.block(hit.cell)) {
        Some(hit.cell)
    } else {
        hit.adjacent_cell()
    }
}

pub fn is_machine(block: Block) -> bool {
    block.is_belt() || matches!(block, Block::Miner | Block::Chest)
}

pub fn inlet_step(block: Block) -> i32 {
    i32::from(block as u8 >= Block::BeltDown as u8)
}

pub fn outlet_step(block: Block) -> i32 {
    i32::from(block.is_slope() && (block as u8) < Block::BeltDown as u8)
}

#[derive(Clone, Debug)]
pub struct Builder {
    _max_cells: usize,
    _active: bool,
    _north_south_first: bool,
    _path: Vec<Segment>,
    _locked: Vec<Segment>,
    _locked_points: BTreeSet<Cell>,
    _start_block: Block,
    _start_direction: Option<Direction>,
    _end_block: Block,
    _end_direction: Option<Direction>,
    _error: Option<Error>,
}

impl Builder {
    pub fn new(max_cells: usize) -> Result<Self, Error> {
        if max_cells == 0 || max_cells > MAX_ROUTE_CELLS {
            return Err(Error::InvalidLimit);
        }
        Ok(Self {
            _max_cells: max_cells,
            _active: false,
            _north_south_first: true,
            _path: Vec::new(),
            _locked: Vec::new(),
            _locked_points: BTreeSet::new(),
            _start_block: Block::Air,
            _start_direction: None,
            _end_block: Block::Air,
            _end_direction: None,
            _error: None,
        })
    }

    pub fn active(&self) -> bool {
        self._active
    }
    pub fn north_south_first(&self) -> bool {
        self._north_south_first
    }
    pub fn path(&self) -> &[Segment] {
        &self._path
    }
    pub fn locked_path(&self) -> &[Segment] {
        &self._locked
    }
    pub fn locked_points(&self) -> impl Iterator<Item = Cell> + '_ {
        self._locked_points.iter().copied()
    }
    pub fn error(&self) -> Option<Error> {
        self._error
    }

    pub fn toggle_order(&mut self) {
        if self._active {
            self._north_south_first = !self._north_south_first;
        }
    }

    pub fn cancel(&mut self) {
        self._active = false;
        self._path.clear();
        self._locked.clear();
        self._locked_points.clear();
        self._north_south_first = true;
        self._error = None;
    }

    pub fn begin(
        &mut self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
        cell: Cell,
        preferred: Direction,
    ) -> Result<(), Error> {
        let result = self._begin(world, directions, cell, preferred);
        self._error = result.err();
        result
    }

    fn _begin(
        &mut self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
        cell: Cell,
        preferred: Direction,
    ) -> Result<(), Error> {
        let block = world.block(cell);
        if block == Block::Air {
            _empty_cell(world, cell, Block::Belt)?;
        } else if !is_machine(block) || block.is_slope() {
            return Err(Error::Occupied);
        }
        let direction = if is_machine(block) {
            Some(directions(cell).ok_or(Error::MissingDirection)?)
        } else {
            None
        };
        if matches!(block, Block::Miner | Block::Chest) {
            let offset = direction.expect("machine direction").cell();
            if let Err(error) = _empty_cell(world, _offset(cell, offset)?, Block::Belt) {
                self.cancel();
                return Err(error);
            }
        }
        self.cancel();
        self._start_block = block;
        self._start_direction = direction;
        self._end_block = block;
        self._end_direction = direction;
        self._path.push(Segment {
            cell,
            block: Block::Belt,
            direction: preferred,
        });
        self._locked.clone_from(&self._path);
        self._active = true;
        Ok(())
    }

    pub fn preview(
        &mut self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
        target: Option<Cell>,
        preferred: Direction,
    ) -> Result<(), Error> {
        let result = self._preview(world, directions, target, preferred);
        self._error = result.err();
        result
    }

    fn _preview(
        &mut self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
        target: Option<Cell>,
        preferred: Direction,
    ) -> Result<(), Error> {
        if !self._active {
            return Err(Error::Inactive);
        }
        self._path.clone_from(&self._locked);
        self._validate_prefix(world, directions)?;
        let mut end = target.ok_or(Error::NoTarget)?;
        if self._locked.len() == 1
            && end == self._locked[0].cell
            && matches!(self._start_block, Block::Miner | Block::Chest)
        {
            end = _offset(
                end,
                self._start_direction.expect("machine direction").cell(),
            )?;
        }
        self._end_block = world.block(end);
        self._end_direction = if is_machine(self._end_block) {
            Some(directions(end).ok_or(Error::MissingDirection)?)
        } else {
            None
        };
        let last = *self._locked.last().expect("active prefix");
        let after_downhill = inlet_step(last.block) == 1;
        if after_downhill && end == last.cell {
            return self._validate_path(world, directions);
        }
        let start = if after_downhill {
            _offset(last.cell, last.direction.cell())?
        } else {
            last.cell
        };
        let preserved = self._locked.len() - usize::from(!after_downhill);
        let allowance = self
            ._max_cells
            .checked_sub(preserved)
            .filter(|&count| count > 0)
            .ok_or(Error::TooLong)?;
        let suffix = route::footprint(start, end, self._north_south_first, allowance)
            .map_err(|_| Error::TooLong)?;
        let mut facing = Vec::with_capacity(suffix.len());
        for index in 0..suffix.len() {
            facing.push(if index + 1 < suffix.len() {
                Direction::between(suffix[index], suffix[index + 1])
            } else if self._end_block == Block::Belt {
                self._end_direction.expect("terminal belt direction")
            } else if index > 0 {
                facing[index - 1]
            } else {
                preferred
            });
        }
        if after_downhill && suffix.len() == 1 && self._end_block == Block::Air {
            facing[0] = last.direction;
        }
        self._path.truncate(preserved);
        for (cell, direction) in suffix.iter().zip(&facing) {
            self._path.push(Segment {
                cell: *cell,
                block: Block::Belt,
                direction: *direction,
            });
        }
        self._path.last_mut().expect("suffix").cell = end;
        match self._end_block {
            Block::Miner => return Err(Error::MinerHasNoInput),
            Block::Air if !world.contains(end) => return Err(Error::OutOfBounds),
            Block::Air | Block::Belt | Block::Chest => {}
            _ => return Err(Error::Occupied),
        }
        if !after_downhill && suffix.len() == 1 && end.y != start.y {
            if self._path.len() == self._max_cells {
                return Err(Error::TooLong);
            }
            self._path.push(Segment {
                cell: end,
                block: Block::Belt,
                direction: preferred,
            });
            return Err(Error::InsufficientRamps);
        }
        self._port_error()?;
        let mut prefix_tops = BTreeMap::new();
        for row in &self._locked[..preserved] {
            let top = row.cell.y + if row.block.is_slope() { 2 } else { 1 };
            prefix_tops
                .entry((row.cell.x, row.cell.z))
                .and_modify(|height: &mut i32| *height = (*height).max(top))
                .or_insert(top);
        }
        let virtual_end = self._end_block == Block::Air && (suffix.len() > 1 || after_downhill);
        if suffix.len() + usize::from(virtual_end) > MAX_ROUTE_CELLS {
            return Err(Error::TooLong);
        }
        let mut floors = Vec::with_capacity(suffix.len() + usize::from(virtual_end));
        let mut capacities = Vec::with_capacity(suffix.len());
        for (index, &cell) in suffix.iter().enumerate() {
            let mut floor = end.y;
            if index == 0 && !after_downhill {
                floor = start.y;
                if self._locked_points.is_empty()
                    && self._start_block == Block::Air
                    && suffix.len() > 1
                {
                    let down =
                        Block::try_from(Block::BeltDown as u8 + facing[0] as u8).expect("slope");
                    if start
                        .checked_offset(0, -1, 0)
                        .is_some_and(|cell| _empty_cell(world, cell, down).is_ok())
                    {
                        floor -= 1;
                    }
                }
            } else if index < suffix.len() - 1 {
                floor = _column_floor(world, cell, &prefix_tops);
            }
            floors.push(floor);
            let mut can_slope = index == 0 || facing[index - 1] == facing[index];
            if index == 0 {
                if after_downhill {
                    can_slope = facing[0] == last.direction;
                } else if !self._locked_points.is_empty() || self._start_block != Block::Air {
                    can_slope = false;
                }
            }
            if index < suffix.len() - 1 {
                capacities.push(u8::from(can_slope));
            } else if virtual_end {
                floors.push(end.y);
                capacities.push(u8::from(can_slope));
            }
        }
        let heights = route::fit_heights(&floors, &capacities, start.y, end.y)
            .map_err(|_| Error::InsufficientRamps)?;
        for index in 0..suffix.len() {
            let rise = if index + 1 < heights.len() {
                heights[index + 1] - heights[index]
            } else {
                0
            };
            let row = &mut self._path[preserved + index];
            row.cell.y = heights[index].min(heights[index] + rise);
            if rise != 0 {
                row.block = Block::try_from(
                    (if rise > 0 {
                        Block::BeltUp
                    } else {
                        Block::BeltDown
                    }) as u8
                        + facing[index] as u8,
                )
                .expect("slope");
            }
        }
        self._validate_path(world, directions)
    }

    pub fn lock(
        &mut self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
    ) -> Result<(), Error> {
        if let Err(error) = self.validate(world, directions) {
            self._error = Some(error);
            return Err(error);
        }
        let end = self._path.last().ok_or(Error::NoTarget)?.cell;
        if world.block(end) != Block::Air {
            return Err(Error::Occupied);
        }
        self._locked.clone_from(&self._path);
        self._locked_points.insert(end);
        Ok(())
    }

    pub fn validate(
        &self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
    ) -> Result<(), Error> {
        if !self._active {
            return Err(Error::Inactive);
        }
        if let Some(error) = self._error {
            return Err(error);
        }
        self._validate_path(world, directions)
    }

    fn _validate_prefix(
        &self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
    ) -> Result<(), Error> {
        if world.block(self._locked[0].cell) != self._start_block {
            return Err(Error::StartChanged);
        }
        if matches!(self._start_block, Block::Miner | Block::Chest)
            && directions(self._locked[0].cell) != self._start_direction
        {
            return Err(Error::StartDirectionChanged);
        }
        for (index, row) in self._locked.iter().enumerate() {
            if index == 0 && self._start_block != Block::Air {
                continue;
            }
            _empty_cell(world, row.cell, row.block)?;
        }
        Ok(())
    }

    fn _port_error(&self) -> Result<(), Error> {
        if self._path.len() < 2 {
            return Ok(());
        }
        if matches!(self._start_block, Block::Miner | Block::Chest)
            && Some(self._path[0].direction) != self._start_direction
        {
            return Err(Error::StartPort);
        }
        let incoming = self._path[self._path.len() - 2].direction;
        if self._end_block == Block::Chest && Some(incoming) != self._end_direction {
            return Err(Error::EndPort);
        }
        if self._end_block == Block::Belt && Some(incoming.opposite()) == self._end_direction {
            return Err(Error::BeltOutput);
        }
        Ok(())
    }

    fn _validate_path(
        &self,
        world: &World,
        directions: &impl Fn(Cell) -> Option<Direction>,
    ) -> Result<(), Error> {
        self._validate_prefix(world, directions)?;
        self._port_error()?;
        let mut planned = BTreeMap::new();
        for (index, row) in self._path.iter().enumerate() {
            if index > 0 {
                let source = self._path[index - 1];
                let source_block = if index == 1 && self._start_block != Block::Air {
                    self._start_block
                } else {
                    source.block
                };
                let target_block = if index == self._path.len() - 1 && self._end_block != Block::Air
                {
                    self._end_block
                } else {
                    row.block
                };
                let delta = source.direction.cell();
                let outlet = source
                    .cell
                    .checked_offset(delta.x, outlet_step(source_block), delta.z)
                    .ok_or(Error::OutOfBounds)?;
                let inlet = row
                    .cell
                    .checked_offset(0, inlet_step(target_block), 0)
                    .ok_or(Error::OutOfBounds)?;
                if outlet != inlet {
                    return Err(Error::Disconnected);
                }
                if target_block.is_slope() && source.direction != row.direction {
                    return Err(Error::SlopeTurn);
                }
                if target_block == Block::Belt && source.direction == row.direction.opposite() {
                    return Err(Error::BeltOutput);
                }
            }
            if planned.contains_key(&row.cell) {
                return Err(Error::SelfCrossing);
            }
            for step in [-1, 1] {
                if let Some(neighbor) = row.cell.checked_offset(0, step, 0)
                    && let Some(&block) = planned.get(&neighbor)
                    && world::blocks_intersect(row.cell, row.block, neighbor, block)
                {
                    return Err(Error::GeometryConflict);
                }
            }
            planned.insert(row.cell, row.block);
            if index == 0 && self._start_block != Block::Air {
                continue;
            }
            if index == self._path.len() - 1 && self._end_block != Block::Air {
                if world.block(row.cell) != self._end_block
                    || directions(row.cell) != self._end_direction
                {
                    return Err(Error::EndChanged);
                }
                continue;
            }
            _empty_cell(world, row.cell, row.block)?;
        }
        Ok(())
    }
}

fn _offset(cell: Cell, direction: Cell) -> Result<Cell, Error> {
    cell.checked_offset(direction.x, direction.y, direction.z)
        .ok_or(Error::OutOfBounds)
}

fn _empty_cell(world: &World, cell: Cell, block: Block) -> Result<(), Error> {
    if !world.contains(cell) {
        return Err(Error::OutOfBounds);
    }
    match world.block(cell) {
        Block::Belt => return Err(Error::BeltCrossing),
        Block::Air => {}
        _ => return Err(Error::Occupied),
    }
    world
        .check_placement(cell, block)
        .map_err(|_| Error::GeometryConflict)
}

fn _column_floor(world: &World, cell: Cell, prefix: &BTreeMap<(i32, i32), i32>) -> i32 {
    let bounds = world.bounds();
    let mut floor = bounds.minimum().y;
    for y in (bounds.minimum().y..bounds.maximum().y).rev() {
        let block = world.block(Cell::new(cell.x, y, cell.z));
        if block != Block::Air {
            floor = y + if block.is_slope() { 2 } else { 1 };
            break;
        }
    }
    floor.max(
        prefix
            .get(&(cell.x, cell.z))
            .copied()
            .unwrap_or(bounds.minimum().y),
    )
}
