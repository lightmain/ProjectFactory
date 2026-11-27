//! Synchronous committed legacy logistics. No engine or caller callbacks.
//! The factory owns its world and machines; observations own independent data.
use crate::{
    belt_placement::{Direction, inlet_step, is_machine, outlet_step},
    world::{self, Block, Bounds, Cell, World},
};
use std::collections::{BTreeMap, VecDeque};

#[path = "continuous.rs"]
pub mod continuous;
#[path = "logistics_persistence.rs"]
mod persistence;

pub const STEP: f64 = 1.0 / 60.0;
const EPSILON: f64 = 1e-9;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    pub interval: f64,
    pub amount: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    World(world::Error),
    NoMachine,
    FixedDirection,
    InvalidTime,
    NotFresh,
    Exhausted,
}

impl From<world::Error> for Error {
    fn from(value: world::Error) -> Self {
        Self::World(value)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Ore {
    pub id: u64,
    pub incoming: Direction,
    pub outgoing: Direction,
    pub progress: f64,
}

impl Ore {
    pub fn position(&self, cell: Cell, block: Block) -> [f64; 3] {
        let offset = if self.progress <= 0.5 {
            self.incoming.cell()
        } else {
            self.outgoing.cell()
        };
        let t = self.progress - 0.5;
        let x = 0.25 + f64::from(offset.x) * t * 0.5;
        let z = 0.25 + f64::from(offset.z) * t * 0.5;
        let height = block
            .slope_elevation(x / 0.5, z / 0.5)
            .map_or(0.08, |height| height * 0.5 + 0.08);
        [
            f64::from(cell.x) * 0.5 + x,
            f64::from(cell.y) * 0.5 + height + 0.045,
            f64::from(cell.z) * 0.5 + z,
        ]
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MachineState {
    pub cell: Cell,
    pub block: Block,
    pub direction: Direction,
    pub settled: Direction,
    pub quantity: i64,
    pub eligible: i64,
    pub last_output: i64,
    pub interval: f64,
    pub amount: i64,
    pub next: f64,
    pub cursor: usize,
    pub placed: f64,
    pub cycles: i64,
    pub ores: Vec<Ore>,
    pub outgoing: Option<Cell>,
    pub inputs: [Option<Cell>; 3],
    pub input_ports: [Option<Direction>; 3],
    pub output_ports: [Option<Direction>; 3],
}

#[derive(Clone, Debug, PartialEq)]
pub struct State {
    pub time: f64,
    pub compensation: f64,
    pub tick: i64,
    pub flushed: i64,
    pub next_id: u64,
    pub dirty: bool,
    pub settings: Settings,
    pub machines: Vec<MachineState>,
}

/// Constant-size clock observation; does not visit machines or transport.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Clock {
    pub time: f64,
    pub compensation: f64,
    pub tick: i64,
    pub flushed: i64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Work {
    pub motion_nodes: usize,
    pub graph_visits: usize,
    pub production_visits: usize,
    pub preflight_production_visits: usize,
    pub batches: usize,
    pub transfers: usize,
}

#[derive(Clone)]
struct Machine {
    state: MachineState,
    outgoing: Option<usize>,
    inputs: [Option<usize>; 3],
    // Historical production boundary, required to validate a frozen phase.
    stop_tick: i64,
}

impl Machine {
    fn new(cell: Cell, block: Block, time: f64, settings: Settings) -> Self {
        let direction = if block.is_slope() {
            match (block as u8 - Block::BeltUp as u8) % 4 {
                0 => Direction::South,
                1 => Direction::West,
                2 => Direction::North,
                _ => Direction::East,
            }
        } else {
            Direction::North
        };
        let deadline = time + settings.interval;
        let next = if block == Block::Miner
            && settings.interval.is_finite()
            && settings.interval >= 0.001
            && settings.amount > 0
            && deadline > time
        {
            deadline
        } else {
            f64::INFINITY
        };
        Self {
            state: MachineState {
                cell,
                block,
                direction,
                settled: direction,
                quantity: 0,
                eligible: 0,
                last_output: -1,
                interval: settings.interval,
                amount: settings.amount,
                next,
                cursor: 0,
                placed: time,
                cycles: 0,
                ores: Vec::with_capacity(2),
                outgoing: None,
                inputs: [None; 3],
                input_ports: [Some(direction.opposite()), None, None],
                output_ports: [Some(direction), None, None],
            },
            outgoing: None,
            inputs: [None; 3],
            stop_tick: -1,
        }
    }

    fn cycles_at(&self, boundary: f64) -> Result<i64, Error> {
        if self.state.next > boundary + EPSILON {
            return Ok(self.state.cycles);
        }
        let cycles = ((boundary - self.state.placed + EPSILON) / self.state.interval).floor();
        if !cycles.is_finite() || cycles >= i64::MAX as f64 {
            return Err(Error::Exhausted);
        }
        Ok((cycles as i64).max(self.state.cycles))
    }

    fn produce(&mut self, tick: i64) {
        // advance preflights all integer growth before changing the clock.
        self.try_produce(tick).expect("preflighted production");
    }

    fn try_produce(&mut self, tick: i64) -> Result<(), Error> {
        let boundary = tick as f64 * STEP;
        let cycles = self.cycles_at(boundary)?;
        if cycles == self.state.cycles {
            return Ok(());
        }
        let produced = (cycles - self.state.cycles)
            .checked_mul(self.state.amount)
            .ok_or(Error::Exhausted)?;
        self.state.quantity = self
            .state
            .quantity
            .checked_add(produced)
            .ok_or(Error::Exhausted)?;
        self.state.cycles = cycles;
        let deadline = self.state.placed + (cycles + 1) as f64 * self.state.interval;
        self.state.next = if deadline > boundary && deadline > self.state.next {
            deadline
        } else {
            f64::INFINITY
        };
        if !self.state.next.is_finite() {
            self.stop_tick = tick;
        }
        Ok(())
    }

    fn available(&self, tick: i64) -> i64 {
        if self.state.last_output == tick {
            return 0;
        }
        if self.state.block.is_belt() {
            if self
                .state
                .ores
                .first()
                .is_none_or(|ore| ore.progress < 1.0 - EPSILON)
            {
                return 0;
            }
            self.state.eligible.min(1)
        } else {
            self.state.eligible
        }
    }

    fn full(&self) -> bool {
        self.state.block.is_belt() && self.state.quantity == 2
    }
}

/// In-memory checkpoint, retaining old settled adjacency and pending directions.
#[derive(Clone)]
pub struct Checkpoint {
    factory: Factory,
}

#[derive(Clone)]
pub struct Factory {
    _world: World,
    _machines: Vec<Machine>,
    _index: BTreeMap<Cell, usize>,
    _settings: Settings,
    _time: f64,
    _compensation: f64,
    _tick: i64,
    _flushed: i64,
    _next_id: u64,
    _dirty: bool,
    _work: Work,
    _ledger: continuous::Ledger,
}

impl Factory {
    pub fn new(bounds: Bounds, settings: Settings) -> Self {
        Self {
            _world: World::flat(bounds),
            _machines: Vec::new(),
            _index: BTreeMap::new(),
            _settings: settings,
            _time: 0.0,
            _compensation: 0.0,
            _tick: 0,
            _flushed: -1,
            _next_id: 1,
            _dirty: true,
            _work: Work::default(),
            _ledger: continuous::Ledger::default(),
        }
    }

    pub fn world(&self) -> &World {
        &self._world
    }

    pub fn direction_at(&self, cell: Cell) -> Option<Direction> {
        self._index
            .get(&cell)
            .map(|&index| self._machines[index].state.direction)
    }

    pub fn work(&self) -> Work {
        self._work
    }

    pub fn ledger(&self) -> continuous::Ledger {
        self._ledger
    }

    pub fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            factory: self.clone(),
        }
    }

    pub fn from_checkpoint(checkpoint: Checkpoint) -> Self {
        checkpoint.factory
    }

    pub fn clock(&self) -> Clock {
        Clock {
            time: self._time,
            compensation: self._compensation,
            tick: self._tick,
            flushed: self._flushed,
        }
    }

    pub fn observe(&self) -> State {
        let machines = self
            ._index
            .values()
            .map(|&index| {
                let machine = &self._machines[index];
                let mut row = machine.state.clone();
                row.outgoing = machine
                    .outgoing
                    .map(|target| self._machines[target].state.cell);
                row.inputs = machine
                    .inputs
                    .map(|source| source.map(|index| self._machines[index].state.cell));
                row.output_ports = [Some(row.direction), None, None];
                let mut sides = row.inputs.into_iter().flatten().map(|source| {
                    self._machines[self._index[&source]]
                        .state
                        .settled
                        .opposite()
                });
                row.input_ports = [sides.next(), sides.next(), sides.next()];
                if row.input_ports[0].is_none() {
                    row.input_ports[0] = Some(row.direction.opposite());
                }
                row
            })
            .collect();
        State {
            time: self._time,
            compensation: self._compensation,
            tick: self._tick,
            flushed: self._flushed,
            next_id: self._next_id,
            dirty: self._dirty,
            settings: self._settings,
            machines,
        }
    }

    pub fn place(&mut self, cell: Cell, block: Block) -> Result<(), Error> {
        self._world.place(cell, block)?;
        if is_machine(block) {
            self._index.insert(cell, self._machines.len());
            self._machines
                .push(Machine::new(cell, block, self._time, self._settings));
            self._dirty = true;
        }
        Ok(())
    }

    pub fn remove(&mut self, cell: Cell) -> Result<(), Error> {
        self._world.remove(cell)?;
        if let Some(index) = self._index.remove(&cell) {
            self._ledger.removed += self._machines[index].state.quantity;
            self._ledger.retired += self._machines[index].state.ores.len() as u64;
            let last = self._machines.len() - 1;
            self._machines.swap_remove(index);
            for machine in &mut self._machines {
                let remap = |edge: Option<usize>| {
                    edge.and_then(|value| {
                        if value == index {
                            None
                        } else if value == last {
                            Some(index)
                        } else {
                            Some(value)
                        }
                    })
                };
                machine.inputs = machine.inputs.map(remap);
                machine.outgoing = remap(machine.outgoing);
            }
            if index != last {
                self._index.insert(self._machines[index].state.cell, index);
            }
            self._dirty = true;
        }
        Ok(())
    }

    pub fn set_direction(&mut self, cell: Cell, direction: Direction) -> Result<(), Error> {
        let index = self._index.get(&cell).copied().ok_or(Error::NoMachine)?;
        let machine = &mut self._machines[index];
        if machine.state.direction == direction {
            return Ok(());
        }
        if machine.state.block.is_slope() {
            return Err(Error::FixedDirection);
        }
        machine.state.direction = direction;
        self._dirty = true;
        Ok(())
    }

    /// Author a full pressure layout before simulation starts.
    pub fn prefill_belts(&mut self) -> Result<(), Error> {
        if self._time != 0.0
            || self._tick != 0
            || self
                ._machines
                .iter()
                .any(|machine| machine.state.quantity != 0)
        {
            return Err(Error::NotFresh);
        }
        self._rebuild();
        for index in 0..self._machines.len() {
            let machine = &self._machines[index];
            if !machine.state.block.is_belt() {
                continue;
            }
            let incoming = machine
                .inputs
                .iter()
                .flatten()
                .next()
                .map_or(machine.state.settled, |&source| {
                    self._machines[source].state.settled
                });
            let machine = &mut self._machines[index];
            for progress in [1.0, 0.5] {
                machine.state.ores.push(Ore {
                    id: self._next_id,
                    incoming,
                    outgoing: machine.state.settled,
                    progress,
                });
                self._next_id += 1;
            }
            machine.state.quantity = 2;
            machine.state.eligible = 2;
            self._ledger.initial += 2;
        }
        Ok(())
    }

    pub fn advance(&mut self, delta: f64) -> Result<(), Error> {
        self._work = Work::default();
        if !delta.is_finite() || delta < 0.0 {
            return Err(Error::InvalidTime);
        }
        if delta == 0.0 {
            return Ok(());
        }
        let corrected = delta - self._compensation;
        let end_time = self._time + corrected;
        if !end_time.is_finite() || end_time / STEP >= i64::MAX as f64 {
            return Err(Error::InvalidTime);
        }
        let end_tick = ((end_time + EPSILON) / STEP).floor() as i64;
        self._preflight(end_tick)?;
        self._compensation = (end_time - self._time) - corrected;
        if self._dirty
            && self._flushed != self._tick
            && (self._time - self._tick as f64 * STEP).abs() <= EPSILON
        {
            self._rebuild();
            self._transfer();
            self._flushed = self._tick;
        }
        if self._machines.is_empty() {
            self._tick = end_tick;
        } else {
            while self._tick < end_tick {
                self._tick += 1;
                self._move();
                if self._dirty {
                    self._rebuild();
                }
                for machine in &mut self._machines {
                    self._work.production_visits += 1;
                    let before = machine.state.quantity;
                    machine.produce(self._tick);
                    self._ledger.produced += machine.state.quantity - before;
                    machine.state.eligible = machine.state.quantity;
                }
                self._transfer();
            }
        }
        self._time = end_time;
        Ok(())
    }

    fn _preflight(&mut self, end_tick: i64) -> Result<(), Error> {
        let mut total = 0_i64;
        for machine in &self._machines {
            let mut quantity = machine.state.quantity;
            if machine.state.next.is_finite() && end_tick > self._tick {
                // Dry-run the same deadlines. At large clocks a rounded
                // deadline can stop growing before the requested end tick.
                // Miners have no ore queue, so this copies only their phase.
                let mut projected = machine.clone();
                for tick in self._tick + 1..=end_tick {
                    self._work.preflight_production_visits += 1;
                    projected.try_produce(tick)?;
                    if !projected.state.next.is_finite() {
                        break;
                    }
                }
                quantity = projected.state.quantity;
            }
            total = total.checked_add(quantity).ok_or(Error::Exhausted)?;
        }
        let belts = self
            ._machines
            .iter()
            .filter(|machine| machine.state.block.is_belt())
            .count() as u64;
        let births = (end_tick - self._tick) as u64 + 1;
        self._next_id
            .checked_add(births.checked_mul(belts).ok_or(Error::Exhausted)?)
            .ok_or(Error::Exhausted)?;
        Ok(())
    }

    fn _rebuild(&mut self) {
        for machine in &mut self._machines {
            self._work.graph_visits += 1;
            let mut facing = machine.state.settled;
            while facing != machine.state.direction {
                facing = rotate(facing);
                for ore in &mut machine.state.ores {
                    ore.incoming = rotate(ore.incoming);
                }
            }
            machine.state.settled = facing;
            for ore in &mut machine.state.ores {
                ore.outgoing = facing;
            }
            machine.outgoing = None;
            machine.inputs = [None; 3];
        }
        for target in 0..self._machines.len() {
            let state = &self._machines[target].state;
            let at = state.cell;
            let facing = state.settled;
            let block = state.block;
            let count = if block == Block::Miner {
                0
            } else if block == Block::Belt {
                3
            } else {
                1
            };
            for port in 0..count {
                let direction = match port {
                    0 => facing,
                    1 => rotate(facing),
                    _ => rotate(facing).opposite(),
                };
                let vector = direction.cell();
                for height in 0..2 {
                    self._work.graph_visits += 1;
                    let source_cell = at
                        .checked_offset(-vector.x, inlet_step(block) - height, -vector.z)
                        .expect("bounded world neighbour");
                    let Some(&source) = self._index.get(&source_cell) else {
                        continue;
                    };
                    let source_state = &self._machines[source].state;
                    if source_state.settled == direction
                        && outlet_step(source_state.block) - height == 0
                    {
                        self._machines[target].inputs[port] = Some(source);
                        self._machines[source].outgoing = Some(target);
                        break;
                    }
                }
            }
        }
        self._dirty = false;
    }

    fn _move(&mut self) {
        let count = self._machines.len();
        let mut heads = vec![None; count];
        let mut tails = vec![None; count];
        let mut desired = Vec::with_capacity(2 * count);
        let mut leaders = Vec::with_capacity(2 * count);
        let mut weights = Vec::with_capacity(2 * count);
        let mut owners = Vec::with_capacity(2 * count);
        for (index, machine) in self._machines.iter().enumerate() {
            let mut limit = 1.0_f64;
            for (slot, ore) in machine.state.ores.iter().enumerate() {
                let node = desired.len();
                desired.push((ore.progress + STEP / 0.5).min(limit));
                limit = desired[node] - 0.5;
                leaders.push(tails[index]);
                weights.push(-0.5);
                owners.push((index, slot));
                heads[index].get_or_insert(node);
                tails[index] = Some(node);
            }
        }
        self._work.motion_nodes += desired.len();
        for (index, machine) in self._machines.iter().enumerate() {
            let (Some(head), Some(target)) = (heads[index], machine.outgoing) else {
                continue;
            };
            let Some(tail) = tails[target] else { continue };
            let (owner, slot) = owners[tail];
            let ore = &self._machines[owner].state.ores[slot];
            if ore.incoming == machine.state.settled
                && machine.state.ores[0].progress <= ore.progress + 0.5 + EPSILON
            {
                leaders[head] = Some(tail);
                weights[head] = 0.5;
            }
        }
        let positions = solve_positions(&desired, &leaders, &weights);
        for (node, &(index, slot)) in owners.iter().enumerate() {
            let ore = &mut self._machines[index].state.ores[slot];
            assert!(
                positions[node] >= ore.progress - EPSILON,
                "infeasible belt state"
            );
            ore.progress = positions[node];
        }
    }

    fn _transfer(&mut self) {
        self._work.batches += 1;
        let size = self._machines.len();
        let cycle_inputs = self._cycle_inputs();
        let mut candidates: Vec<Option<(usize, usize, i64)>> = vec![None; size];
        let mut output = vec![None; size];
        for target in 0..size {
            let machine = &self._machines[target];
            if machine.state.block == Block::Miner {
                continue;
            }
            if machine.state.block == Block::Chest {
                if let Some(source) = machine.inputs[0] {
                    let amount = self._machines[source].available(self._tick);
                    if amount > 0 {
                        candidates[target] = Some((source, 0, amount));
                        output[source] = Some(target);
                    }
                }
                continue;
            }
            if machine
                .state
                .ores
                .last()
                .is_some_and(|ore| ore.progress < 0.5 - EPSILON)
            {
                continue;
            }
            for offset in 0..3 {
                let port = (machine.state.cursor + offset) % 3;
                let Some(source) = machine.inputs[port] else {
                    continue;
                };
                if cycle_inputs[target].is_some_and(|input| input != source) {
                    continue;
                }
                if self._machines[source].available(self._tick) <= 0 {
                    if self._machines[source].state.block.is_belt()
                        && self._machines[source].state.quantity > 0
                    {
                        break;
                    }
                    continue;
                }
                candidates[target] = Some((source, port, 1));
                output[source] = Some(target);
                break;
            }
        }
        let mut rejected = VecDeque::new();
        for target in 0..size {
            if candidates[target].is_some()
                && self._machines[target].full()
                && output[target].is_none()
            {
                rejected.push_back(target);
            }
        }
        while let Some(target) = rejected.pop_front() {
            if let Some((source, _, _)) = candidates[target].take()
                && candidates[source].is_some()
                && self._machines[source].full()
            {
                rejected.push_back(source);
            }
        }
        let mut moved = vec![None; size];
        for target in 0..size {
            if let Some((source, _, amount)) = candidates[target] {
                self._work.transfers += 1;
                let machine = &mut self._machines[source];
                machine.state.quantity -= amount;
                machine.state.eligible -= amount;
                machine.state.last_output = self._tick;
                if machine.state.block.is_belt() {
                    moved[target] = Some(machine.state.ores.remove(0));
                }
            }
        }
        for target in 0..size {
            if let Some((source, port, amount)) = candidates[target] {
                let incoming = self._machines[source].state.settled;
                let machine = &mut self._machines[target];
                machine.state.quantity += amount;
                if !machine.state.block.is_belt() {
                    if moved[target].is_some() {
                        self._ledger.retired += 1;
                    }
                    continue;
                }
                let mut ore = moved[target].take().unwrap_or_else(|| {
                    let id = self._next_id;
                    self._next_id += 1;
                    self._ledger.created += 1;
                    Ore {
                        id,
                        incoming,
                        outgoing: machine.state.settled,
                        progress: 0.0,
                    }
                });
                ore.incoming = incoming;
                ore.outgoing = machine.state.settled;
                ore.progress = 0.0;
                machine.state.ores.push(ore);
                machine.state.cursor = (port + 1) % 3;
            }
        }
    }

    fn _cycle_inputs(&self) -> Vec<Option<usize>> {
        let size = self._machines.len();
        let ready: Vec<_> = self
            ._machines
            .iter()
            .map(|machine| {
                machine.full()
                    && machine.available(self._tick) > 0
                    && machine
                        .state
                        .ores
                        .last()
                        .is_some_and(|ore| ore.progress >= 0.5 - EPSILON)
            })
            .collect();
        let mut states = vec![0; size];
        let mut indices = vec![0; size];
        let mut predecessors = vec![None; size];
        for start in 0..size {
            if !ready[start] || states[start] != 0 {
                continue;
            }
            let mut stack = Vec::new();
            let mut current = Some(start);
            while let Some(index) = current {
                if !ready[index] || states[index] != 0 {
                    break;
                }
                states[index] = 1;
                indices[index] = stack.len();
                stack.push(index);
                current = self._machines[index].outgoing;
            }
            if let Some(index) = current
                && states[index] == 1
            {
                for &source in &stack[indices[index]..] {
                    predecessors[self._machines[source].outgoing.expect("cycle edge")] =
                        Some(source);
                }
            }
            for index in stack {
                states[index] = 2;
            }
        }
        predecessors
    }
}

fn rotate(direction: Direction) -> Direction {
    match direction {
        Direction::North => Direction::East,
        Direction::East => Direction::South,
        Direction::South => Direction::West,
        Direction::West => Direction::North,
    }
}

/// Greatest feasible positions on a functional graph, including full cycles.
fn solve_positions(desired: &[f64], leaders: &[Option<usize>], weights: &[f64]) -> Vec<f64> {
    let mut positions = desired.to_vec();
    let mut states = vec![0; desired.len()];
    let mut indices = vec![0; desired.len()];
    for start in 0..desired.len() {
        if states[start] != 0 {
            continue;
        }
        let mut stack = Vec::new();
        let mut current = Some(start);
        while let Some(node) = current {
            if states[node] != 0 {
                break;
            }
            states[node] = 1;
            indices[node] = stack.len();
            stack.push(node);
            current = leaders[node];
        }
        if let Some(node) = current
            && states[node] == 1
        {
            let first = indices[node];
            let count = stack.len() - first;
            let mut prefix = vec![0.0; 2 * count + 1];
            let mut values = vec![0.0; 2 * count];
            for index in 0..2 * count {
                let node = stack[first + index % count];
                values[index] = desired[node] + prefix[index];
                prefix[index + 1] = prefix[index] + weights[node];
            }
            assert!(prefix[count] >= -EPSILON, "negative belt constraint cycle");
            let mut deque: VecDeque<usize> = VecDeque::new();
            for index in 0..2 * count - 1 {
                while deque
                    .back()
                    .is_some_and(|&last| values[last] >= values[index])
                {
                    deque.pop_back();
                }
                deque.push_back(index);
                if index + 1 < count {
                    continue;
                }
                let window = index + 1 - count;
                while deque.front().is_some_and(|&first| first < window) {
                    deque.pop_front();
                }
                positions[stack[first + window]] =
                    values[*deque.front().expect("nonempty window")] - prefix[window];
            }
            for &node in &stack[first..] {
                states[node] = 2;
            }
        }
        while let Some(node) = stack.pop() {
            if states[node] == 2 {
                continue;
            }
            if let Some(leader) = leaders[node] {
                positions[node] = desired[node].min(positions[leader] + weights[node]);
            }
            states[node] = 2;
        }
    }
    positions
}
