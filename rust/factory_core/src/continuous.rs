//! Synchronous factory using RustConveyor's authoritative metric queues.
use super::{Direction, STEP, Settings, State};
use crate::{
    belt_placement::Segment,
    world::{Block, Bounds, Cell, World},
};
use rust_conveyor::api::{DeviceCommand, Event, Network, SegmentKey};
use std::collections::BTreeMap;

#[path = "continuous_geometry.rs"]
mod geometry;
#[path = "continuous_persistence.rs"]
mod persistence;
use geometry::{Arm, Ports};

#[derive(Clone, Debug, PartialEq)]
pub enum Error {
    Factory(super::Error),
    Transport(rust_conveyor::api::Error),
}
impl From<super::Error> for Error {
    fn from(error: super::Error) -> Self {
        Self::Factory(error)
    }
}
impl From<rust_conveyor::api::Error> for Error {
    fn from(error: rust_conveyor::api::Error) -> Self {
        Self::Transport(error)
    }
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Ledger {
    pub initial: i64,
    pub produced: i64,
    pub removed: i64,
    pub created: u64,
    pub retired: u64,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Work {
    pub segments: usize,
    pub devices: usize,
    pub visited_nodes: u64,
    pub rebuilt_machines: usize,
    pub waiting_seams: usize,
}
#[derive(Clone, Copy)]
struct Binding {
    segment: SegmentKey,
    start: f64,
    length: f64,
    arm: Arm,
}
#[derive(Clone)]
struct Geometry {
    bindings: BTreeMap<Cell, Vec<Binding>>,
    lengths: BTreeMap<SegmentKey, f64>,
    producers: BTreeMap<(SegmentKey, usize), usize>,
    consumers: BTreeMap<(SegmentKey, usize), usize>,
    pending: Vec<(SegmentKey, usize, SegmentKey, usize)>,
    ports: Ports,
    paths: BTreeMap<SegmentKey, Vec<Arm>>,
}
pub struct Checkpoint {
    layout: super::Checkpoint,
    network: Vec<u8>,
    geometry: Geometry,
    ledger: Ledger,
}
pub struct Factory {
    _layout: super::Factory,
    _network: Network,
    _geometry: Geometry,
    _ledger: Ledger,
    _work: Work,
}

/// Legacy adjacency is used for devices only. Its rotation rules must not
/// rewrite the authoritative continuous items' incoming/outgoing half-arms.
fn rebuild_devices(layout: &mut super::Factory) {
    let ores: Vec<_> = layout
        ._machines
        .iter()
        .map(|m| m.state.ores.clone())
        .collect();
    for machine in &mut layout._machines {
        machine.state.settled = machine.state.direction;
    }
    layout._rebuild();
    for (machine, ores) in layout._machines.iter_mut().zip(ores) {
        machine.state.ores = ores;
    }
}
impl Factory {
    pub fn new(bounds: Bounds, settings: Settings) -> Result<Self, Error> {
        let mut layout = super::Factory::new(bounds, settings);
        layout._rebuild();
        let (network, geometry) = geometry::build(&layout, Ports::new(), 0, None)?;
        Ok(Self {
            _layout: layout,
            _network: network,
            _geometry: geometry,
            _ledger: Ledger::default(),
            _work: Work::default(),
        })
    }
    pub fn world(&self) -> &World {
        self._layout.world()
    }
    pub fn direction_at(&self, cell: Cell) -> Option<Direction> {
        self._layout.direction_at(cell)
    }
    pub fn ledger(&self) -> Ledger {
        self._ledger
    }
    pub fn work(&self) -> Work {
        self._work
    }
    pub fn clock(&self) -> super::Clock {
        self._layout.clock()
    }
    pub fn last_identity(&self) -> u64 {
        self._network.last_identity()
    }
    pub fn segment_lengths(&self) -> Vec<f64> {
        self._geometry.lengths.values().copied().collect()
    }
    pub fn checkpoint(&self) -> Result<Checkpoint, Error> {
        Ok(Checkpoint {
            layout: self._layout.checkpoint(),
            network: self._network.snapshot()?,
            geometry: self._geometry.clone(),
            ledger: self._ledger,
        })
    }
    pub fn from_checkpoint(checkpoint: Checkpoint) -> Result<Self, Error> {
        Ok(Self {
            _layout: super::Factory::from_checkpoint(checkpoint.layout),
            _network: Network::restore(&checkpoint.network)?,
            _geometry: checkpoint.geometry,
            _ledger: checkpoint.ledger,
            _work: Work::default(),
        })
    }
    pub fn observe(&self) -> Result<State, Error> {
        let mut state = self._layout.observe();
        state.next_id = self.last_identity() + 1;
        for row in &mut state.machines {
            let Some(bindings) = self._geometry.bindings.get(&row.cell) else {
                continue;
            };
            row.input_ports = self._geometry.ports[&row.cell]
                .inputs
                .map(|s| s.map(geometry::direction));
            row.output_ports = self._geometry.ports[&row.cell]
                .outputs
                .map(|s| s.map(geometry::direction));
            row.ores.clear();
            for &binding in bindings {
                let page = self._network.sample(
                    binding.segment,
                    binding.start,
                    binding.start + binding.length,
                    usize::MAX,
                )?;
                row.ores.extend(page.items.into_iter().map(|item| {
                    geometry::ore(binding, item.position, item.id.0, &self._geometry.ports)
                }));
            }
            row.ores.sort_by(|a, b| {
                b.progress
                    .total_cmp(&a.progress)
                    .then_with(|| a.id.cmp(&b.id))
            });
            row.quantity = row.ores.len() as i64;
            row.eligible = row.quantity;
        }
        Ok(state)
    }
    pub fn local_machine(
        &self,
        cell: Cell,
        limit: usize,
    ) -> Result<Option<super::MachineState>, Error> {
        let Some(mut row) = self._layout.local_machine(cell, limit)? else {
            return Ok(None);
        };
        let Some(bindings) = self._geometry.bindings.get(&cell) else {
            return Ok(Some(row));
        };
        row.input_ports = self._geometry.ports[&cell]
            .inputs
            .map(|s| s.map(geometry::direction));
        row.output_ports = self._geometry.ports[&cell]
            .outputs
            .map(|s| s.map(geometry::direction));
        row.ores.clear();
        for &binding in bindings {
            let page = self._network.sample(
                binding.segment,
                binding.start,
                binding.start + binding.length,
                limit.saturating_sub(row.ores.len()),
            )?;
            if page.required > limit.saturating_sub(row.ores.len()) {
                return Err(super::Error::Exhausted.into());
            }
            row.ores.extend(page.items.into_iter().map(|item| {
                geometry::ore(binding, item.position, item.id.0, &self._geometry.ports)
            }));
        }
        row.ores.sort_by(|a, b| {
            b.progress
                .total_cmp(&a.progress)
                .then_with(|| a.id.cmp(&b.id))
        });
        row.quantity = row.ores.len() as i64;
        row.eligible = row.quantity;
        Ok(Some(row))
    }
    /// Stage owned world/geometry edits, keeping untouched Network segments
    /// (including their queue corrections, junction holds and cursors).
    fn _edit(
        &mut self,
        edit: impl FnOnce(&mut super::Factory, &mut Ports) -> Result<(), Error>,
    ) -> Result<(), Error> {
        self._edit_network(edit, true)
    }
    fn _edit_network(
        &mut self,
        edit: impl FnOnce(&mut super::Factory, &mut Ports) -> Result<(), Error>,
        preserve: bool,
    ) -> Result<(), Error> {
        let observed = self.observe()?;
        let before: i64 = observed.machines.iter().map(|r| r.quantity).sum();
        let mut candidate = self._layout.clone();
        for row in observed.machines {
            if row.block.is_belt() {
                let index = candidate._index[&row.cell];
                candidate._machines[index].state = row;
            }
        }
        let mut ports = self._geometry.ports.clone();
        edit(&mut candidate, &mut ports)?;
        // The geometry edit determines the new path. Do not rotate old item
        // coordinates while rebuilding the legacy device-only adjacency.
        rebuild_devices(&mut candidate);
        let after: i64 = candidate._machines.iter().map(|m| m.state.quantity).sum();
        let previous = preserve.then_some((&self._network, &self._geometry));
        let (network, geometry) =
            geometry::build(&candidate, ports, self.last_identity(), previous)?;
        self._ledger.retired += self
            ._network
            .stats()
            .items
            .saturating_sub(network.stats().items) as u64;
        for machine in &mut candidate._machines {
            if machine.state.block.is_belt() {
                machine.state.quantity = 0;
                machine.state.eligible = 0;
                machine.state.ores.clear();
            }
        }
        if after >= before {
            self._ledger.initial += after - before;
        } else {
            self._ledger.removed += before - after;
        }
        self._work.rebuilt_machines = candidate._machines.len();
        self._work.segments = geometry.lengths.len();
        self._layout = candidate;
        self._network = network;
        self._geometry = geometry;
        Ok(())
    }
    pub fn place(&mut self, cell: Cell, block: Block, direction: Direction) -> Result<(), Error> {
        self.place_many(&[(cell, block, direction)])
    }
    pub fn place_many(&mut self, additions: &[(Cell, Block, Direction)]) -> Result<(), Error> {
        self.place_route(additions, &[])
    }
    pub fn place_route(
        &mut self,
        additions: &[(Cell, Block, Direction)],
        path: &[Segment],
    ) -> Result<(), Error> {
        self._edit(|layout, ports| {
            for &(cell, block, direction) in additions {
                layout.place(cell, block)?;
                if super::is_machine(block) {
                    layout.set_direction(cell, direction)?;
                }
            }
            let frozen = ports.clone();
            rebuild_devices(layout);
            geometry::synchronize(layout, ports);
            if !path.is_empty() {
                // Existing cells must be read before the operation; new cells
                // are absent in the shared frozen world.
                let mut route_ports = ports.clone();
                for segment in path {
                    if let Some(old) = frozen.get(&segment.cell) {
                        route_ports.insert(segment.cell, *old);
                    } else if !segment.block.is_slope() {
                        route_ports.remove(&segment.cell);
                    }
                }
                geometry::build_route(layout, &mut route_ports, path)?;
                *ports = route_ports;
                for segment in path {
                    if let Some(&index) = layout._index.get(&segment.cell) {
                        layout._machines[index].state.direction = segment.direction;
                    }
                }
            }
            Ok(())
        })
    }
    pub fn remove(&mut self, cell: Cell) -> Result<(), Error> {
        self._edit(|layout, ports| {
            geometry::delete(layout, ports, cell)?;
            layout.remove(cell)?;
            Ok(())
        })
    }
    pub fn set_direction(&mut self, cell: Cell, direction: Direction) -> Result<(), Error> {
        self._edit(|layout, ports| {
            layout.set_direction(cell, direction)?;
            if let Some(port) = ports.get_mut(&cell) {
                *port = rust_conveyor::grid::Cell::ordinary(
                    port.position,
                    geometry::side(direction.opposite()),
                    geometry::side(direction),
                );
            }
            rebuild_devices(layout);
            geometry::synchronize(layout, ports);
            Ok(())
        })
    }
    pub fn prefill_belts(&mut self) -> Result<(), Error> {
        self._edit_network(
            |layout, _| {
                layout.prefill_belts()?;
                Ok(())
            },
            false,
        )
    }
    pub fn advance(&mut self, delta: f64) -> Result<(), Error> {
        if !delta.is_finite() || delta < 0.0 {
            return Err(super::Error::InvalidTime.into());
        }
        if delta == 0.0 {
            return Ok(());
        }
        let corrected = delta - self._layout._compensation;
        let end = self._layout._time + corrected;
        if !end.is_finite() || end / STEP >= i64::MAX as f64 {
            return Err(super::Error::InvalidTime.into());
        }
        let tick = ((end + super::EPSILON) / STEP).floor() as i64;
        self._layout._preflight(tick)?;
        self._work = Work {
            segments: self._geometry.lengths.len(),
            devices: self
                ._layout
                ._machines
                .iter()
                .filter(|m| !m.state.block.is_belt())
                .count(),
            ..Work::default()
        };
        while self._layout._tick < tick {
            self._step()?;
        }
        self._layout._compensation = (end - self._layout._time) - corrected;
        self._layout._time = end;
        self._work.waiting_seams = self._geometry.pending.len();
        Ok(())
    }
    fn _activate_pending(&mut self) -> Result<(), Error> {
        let mut waiting = Vec::new();
        for &link @ (source, output, target, input) in &self._geometry.pending {
            match self._network.connect(source, output, target, input) {
                Ok(()) => (),
                Err(rust_conveyor::api::Error::InsufficientSpace) => waiting.push(link),
                Err(error) => return Err(error.into()),
            }
        }
        self._geometry.pending = waiting;
        Ok(())
    }
    fn _step(&mut self) -> Result<(), Error> {
        self._activate_pending()?;
        let tick = self._layout._tick + 1;
        let mut staged = BTreeMap::new();
        let mut produced = 0;
        for (index, machine) in self._layout._machines.iter().enumerate() {
            if machine.state.block.is_belt() {
                continue;
            }
            let mut pending = machine.clone();
            let old = pending.state.quantity;
            pending.try_produce(tick)?;
            produced += pending.state.quantity - old;
            pending.state.eligible = pending.state.quantity;
            staged.insert(index, pending);
        }
        let mut commands = Vec::new();
        for (&(segment, slot), &source) in &self._geometry.producers {
            commands.push(DeviceCommand {
                segment,
                slot,
                enabled: staged[&source].state.quantity > 0,
                quota: 1,
                producer: true,
            });
        }
        for &(segment, slot) in self._geometry.consumers.keys() {
            commands.push(DeviceCommand {
                segment,
                slot,
                enabled: true,
                quota: 1,
                producer: false,
            });
        }
        // Remove device endpoints that disappeared while retaining untouched
        // segment scheduling. configure_devices updates only supplied ports.
        let active = self._network.active_devices();
        for old in active {
            let exists = if old.producer {
                self._geometry
                    .producers
                    .contains_key(&(old.segment, old.slot))
            } else {
                self._geometry
                    .consumers
                    .contains_key(&(old.segment, old.slot))
            };
            if !exists {
                if old.producer {
                    self._network
                        .set_producer(old.segment, old.slot, false, 0)?;
                } else {
                    self._network
                        .set_consumer(old.segment, old.slot, false, 0)?;
                }
            }
        }
        self._network.configure_devices(&commands)?;
        let frame = self._network.tick()?;
        self._ledger.produced += produced;
        self._work.visited_nodes += frame.visited_nodes;
        for (index, machine) in staged {
            self._layout._machines[index] = machine;
        }
        for event in frame.events {
            match event {
                Event::Produced { segment, slot, .. } => {
                    let source = self._geometry.producers[&(segment, slot)];
                    let row = &mut self._layout._machines[source].state;
                    row.quantity -= 1;
                    row.eligible -= 1;
                    row.last_output = tick;
                    self._ledger.created += 1;
                }
                Event::Consumed { segment, slot, .. } => {
                    self._layout._machines[self._geometry.consumers[&(segment, slot)]]
                        .state
                        .quantity += 1;
                    self._ledger.retired += 1;
                }
                Event::Transferred { .. } => (),
            }
        }
        let mut moves = Vec::new();
        for (source, machine) in self._layout._machines.iter().enumerate() {
            if machine.state.block.is_belt() {
                continue;
            }
            if let Some(target) = machine.outgoing
                && !self._layout._machines[target].state.block.is_belt()
                && machine.state.eligible > 0
            {
                moves.push((source, target, machine.state.eligible));
            }
        }
        for (source, target, amount) in moves {
            self._layout._machines[source].state.quantity -= amount;
            self._layout._machines[source].state.eligible -= amount;
            self._layout._machines[source].state.last_output = tick;
            self._layout._machines[target].state.quantity += amount;
        }
        self._layout._tick = tick;
        self._layout._flushed = tick;
        Ok(())
    }
}
