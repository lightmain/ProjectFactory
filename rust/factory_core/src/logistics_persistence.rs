use super::*;
use crate::persistence::{Error as SaveError, MAX_MACHINES, Reader, Result, Writer, ensure};
use std::collections::BTreeSet;

fn facing(r: &mut Reader<'_>) -> Result<Direction> {
    match r.u8()? {
        0 => Ok(Direction::South),
        1 => Ok(Direction::West),
        2 => Ok(Direction::North),
        3 => Ok(Direction::East),
        _ => Err(SaveError::Invalid("direction")),
    }
}
fn optional_index(w: &mut Writer, index: Option<usize>) {
    w.u64(index.map_or(u64::MAX, |v| v as u64));
}
fn read_index(r: &mut Reader<'_>, count: usize) -> Result<Option<usize>> {
    let n = r.u64()?;
    if n == u64::MAX {
        return Ok(None);
    }
    ensure(n < count as u64, "adjacency index")?;
    Ok(Some(n as usize))
}
pub(crate) fn write_ledger(w: &mut Writer, ledger: continuous::Ledger) {
    w.i64(ledger.initial);
    w.i64(ledger.produced);
    w.i64(ledger.removed);
    w.u64(ledger.created);
    w.u64(ledger.retired);
}
pub(crate) fn read_ledger(r: &mut Reader<'_>) -> Result<continuous::Ledger> {
    let ledger = continuous::Ledger {
        initial: r.i64()?,
        produced: r.i64()?,
        removed: r.i64()?,
        created: r.u64()?,
        retired: r.u64()?,
    };
    ensure(
        ledger.initial >= 0
            && ledger.produced >= 0
            && ledger.removed >= 0
            && ledger
                .initial
                .checked_add(ledger.produced)
                .is_some_and(|total| total >= ledger.removed)
            && ledger.initial as u128 + u128::from(ledger.created) <= u128::from(u64::MAX),
        "ledger",
    )?;
    ensure(
        u128::from(ledger.retired) <= ledger.initial as u128 + u128::from(ledger.created),
        "identity ledger",
    )?;
    Ok(ledger)
}
impl Factory {
    pub(crate) fn disk_sections(&self) -> [Vec<u8>; 6] {
        let mut world = Writer::default();
        self._world.write_disk(&mut world);
        let mut devices = Writer::default();
        devices.u64(self._machines.len() as u64);
        for machine in &self._machines {
            let s = &machine.state;
            devices.cell(s.cell);
            devices.u8(s.block as u8);
            devices.u8(s.direction as u8);
            devices.u8(s.settled as u8);
            for v in [s.quantity, s.eligible, s.last_output] {
                devices.i64(v);
            }
            devices.f64(s.interval);
            devices.i64(s.amount);
            devices.f64(s.next);
            devices.u64(s.cursor as u64);
            devices.f64(s.placed);
            devices.i64(s.cycles);
            devices.u64(s.ores.len() as u64);
            for ore in &s.ores {
                devices.u64(ore.id);
                devices.u8(ore.incoming as u8);
                devices.u8(ore.outgoing as u8);
                devices.f64(ore.progress);
            }
            optional_index(&mut devices, machine.outgoing);
            for input in machine.inputs {
                optional_index(&mut devices, input);
            }
            devices.i64(machine.stop_tick);
        }
        let mut clock = Writer::default();
        clock.f64(self._settings.interval);
        clock.i64(self._settings.amount);
        clock.f64(self._time);
        clock.f64(self._compensation);
        clock.i64(self._tick);
        clock.i64(self._flushed);
        clock.u64(self._next_id);
        clock.bool(self._dirty);
        write_ledger(&mut clock, self._ledger);
        [
            world.0,
            devices.0,
            Vec::new(),
            Vec::new(),
            clock.0,
            Vec::new(),
        ]
    }
    pub(crate) fn from_disk_sections(sections: &[&[u8]; 6], continuous: bool) -> Result<Self> {
        let mut w = Reader::new(sections[0]);
        let world = World::read_disk(&mut w)?;
        w.end()?;
        let mut c = Reader::new(sections[4]);
        let settings = Settings {
            interval: c.f64()?,
            amount: c.i64()?,
        };
        let time = c.f64()?;
        let compensation = c.f64()?;
        let tick = c.i64()?;
        let flushed = c.i64()?;
        let next_id = c.u64()?;
        let dirty = c.bool()?;
        let ledger = read_ledger(&mut c)?;
        c.end()?;
        ensure(
            time.is_finite()
                && time >= 0.0
                && compensation.is_finite()
                && compensation.abs() <= time * f64::EPSILON * 4.0
                && (0..i64::MAX).contains(&tick)
                && flushed >= -1
                && flushed <= tick
                && (tick as f64 * STEP - time).abs() <= STEP + 1e-7
                && tick as f64 * STEP <= time + 1e-7
                && next_id > 0
                && next_id <= i64::MAX as u64,
            "simulation clock",
        )?;
        let mut factory = Self::new(world.bounds(), settings);
        factory._world = world;
        factory._time = time;
        factory._compensation = compensation;
        factory._tick = tick;
        factory._flushed = flushed;
        factory._next_id = next_id;
        factory._dirty = dirty;
        factory._ledger = ledger;
        let mut d = Reader::new(sections[1]);
        let count = d.count(MAX_MACHINES, 127)?;
        let mut ids = BTreeSet::new();
        let mut total = 0i64;
        for index in 0..count {
            let cell = d.cell()?;
            let block = Block::try_from(d.u8()?).map_err(|_| SaveError::Invalid("block"))?;
            let direction = facing(&mut d)?;
            let settled = facing(&mut d)?;
            let quantity = d.i64()?;
            let eligible = d.i64()?;
            let last_output = d.i64()?;
            let interval = d.f64()?;
            let amount = d.i64()?;
            let next = d.f64()?;
            let cursor = d.length(2)?;
            let placed = d.f64()?;
            let cycles = d.i64()?;
            ensure(
                is_machine(block)
                    && factory._world.contains(cell)
                    && factory._world.block(cell) == block
                    && factory._index.insert(cell, index).is_none(),
                "machine/world correspondence",
            )?;
            ensure(
                quantity >= 0
                    && eligible >= 0
                    && eligible <= quantity
                    && last_output >= -1
                    && last_output <= tick
                    && placed.is_finite()
                    && placed >= 0.0
                    && placed <= time
                    && cycles >= 0
                    && (next.is_finite() || next == f64::INFINITY)
                    && next >= placed,
                "machine state",
            )?;
            ensure(
                interval.to_bits() == settings.interval.to_bits() && amount == settings.amount,
                "machine settings",
            )?;
            let enabled = block == Block::Miner
                && interval.is_finite()
                && interval >= 0.001
                && amount > 0
                && placed + interval > placed;
            if enabled {
                let latest_cycles = ((time - placed + EPSILON) / interval).floor();
                ensure(
                    cycles as f64 <= latest_cycles && cycles < i64::MAX,
                    "miner cycles",
                )?;
                let deadline = placed + (cycles + 1) as f64 * interval;
                if next.is_finite() {
                    let boundary_cycles = ((tick as f64 * STEP - placed + EPSILON) / interval)
                        .floor()
                        .max(0.0);
                    ensure(
                        boundary_cycles < i64::MAX as f64
                            && cycles == boundary_cycles as i64
                            && next.to_bits() == deadline.to_bits(),
                        "miner deadline",
                    )?;
                }
            } else {
                ensure(next == f64::INFINITY && cycles == 0, "disabled production")?;
            }
            if block.is_slope() {
                let fixed = [
                    Direction::South,
                    Direction::West,
                    Direction::North,
                    Direction::East,
                ][usize::from((block as u8 - 9) % 4)];
                ensure(direction == fixed && settled == fixed, "slope direction")?;
            }
            if !dirty {
                ensure(direction == settled, "settled direction")?;
            }
            let ore_count = d.count(2, 18)?;
            let mut ores = Vec::with_capacity(ore_count);
            for _ in 0..ore_count {
                let id = d.u64()?;
                let incoming = facing(&mut d)?;
                let outgoing = facing(&mut d)?;
                let progress = d.f64()?;
                ensure(
                    id > 0
                        && id < next_id
                        && ids.insert(id)
                        && progress.is_finite()
                        && (0.0..=1.0 + EPSILON).contains(&progress),
                    "ore",
                )?;
                if let Some(previous) = ores.last() {
                    let previous: &Ore = previous;
                    ensure(previous.progress - progress >= 0.5 - EPSILON, "ore spacing")?;
                }
                ores.push(Ore {
                    id,
                    incoming,
                    outgoing,
                    progress,
                });
            }
            ensure(
                if block.is_belt() {
                    if continuous {
                        quantity == 0 && ores.is_empty()
                    } else {
                        quantity <= 2 && quantity == ores.len() as i64
                    }
                } else {
                    ores.is_empty()
                },
                "belt inventory",
            )?;
            total = total
                .checked_add(quantity)
                .ok_or(SaveError::Invalid("inventory overflow"))?;
            let outgoing = read_index(&mut d, count)?;
            let inputs = [
                read_index(&mut d, count)?,
                read_index(&mut d, count)?,
                read_index(&mut d, count)?,
            ];
            let stop_tick = d.i64()?;
            if enabled && next == f64::INFINITY && cycles > 0 {
                let boundary = stop_tick as f64 * STEP;
                let boundary_cycles = ((boundary - placed + EPSILON) / interval).floor();
                let deadline = placed + (cycles + 1) as f64 * interval;
                let previous_deadline = placed + cycles as f64 * interval;
                ensure(
                    stop_tick >= 0
                        && stop_tick <= tick
                        && boundary >= placed
                        && boundary_cycles < i64::MAX as f64
                        && cycles == boundary_cycles as i64
                        && (!deadline.is_finite()
                            || deadline <= boundary
                            || deadline <= previous_deadline),
                    "miner stop boundary",
                )?;
            } else {
                ensure(stop_tick == -1, "unexpected stop boundary")?;
                if enabled && next == f64::INFINITY {
                    ensure(
                        !(placed + interval).is_finite() && cycles == 0,
                        "initial miner deadline",
                    )?;
                }
            }
            factory._machines.push(Machine {
                state: MachineState {
                    cell,
                    block,
                    direction,
                    settled,
                    quantity,
                    eligible,
                    last_output,
                    interval,
                    amount,
                    next,
                    cursor,
                    placed,
                    cycles,
                    ores,
                    outgoing: None,
                    inputs: [None; 3],
                    input_ports: [None; 3],
                    output_ports: [None; 3],
                },
                outgoing,
                inputs,
                stop_tick,
            });
        }
        d.end()?;
        let bounds = factory._world.bounds();
        let mut expected = 0;
        for y in bounds.minimum().y..bounds.maximum().y {
            for z in bounds.minimum().z..bounds.maximum().z {
                for x in bounds.minimum().x..bounds.maximum().x {
                    if is_machine(factory._world.block(Cell::new(x, y, z))) {
                        expected += 1;
                    }
                }
            }
        }
        ensure(expected == count, "missing machine")?;
        for (index, machine) in factory._machines.iter().enumerate() {
            ensure(
                machine
                    .inputs
                    .into_iter()
                    .flatten()
                    .collect::<BTreeSet<_>>()
                    .len()
                    == machine.inputs.iter().flatten().count(),
                "duplicate input",
            )?;
            for source in machine.inputs.into_iter().flatten() {
                ensure(source != index, "self adjacency")?;
                let source = &factory._machines[source];
                let offset = source.state.settled.cell();
                ensure(
                    source.state.cell.x + offset.x == machine.state.cell.x
                        && source.state.cell.z + offset.z == machine.state.cell.z
                        && source.state.cell.y + outlet_step(source.state.block)
                            == machine.state.cell.y + inlet_step(machine.state.block),
                    "adjacency geometry",
                )?;
            }
            if let Some(target) = machine.outgoing {
                ensure(
                    factory._machines[target].inputs.contains(&Some(index)),
                    "adjacency reciprocity",
                )?;
            }
        }
        if !dirty {
            let mut derived = factory.clone();
            derived._rebuild();
            ensure(
                factory
                    ._machines
                    .iter()
                    .zip(&derived._machines)
                    .all(|(a, b)| a.inputs == b.inputs && a.outgoing == b.outgoing),
                "settled adjacency completeness",
            )?;
        }
        if !continuous {
            ensure(
                total == ledger.initial + ledger.produced - ledger.removed,
                "inventory ledger",
            )?;
            ensure(
                ids.len() as u128
                    == ledger.initial as u128 + u128::from(ledger.created)
                        - u128::from(ledger.retired),
                "identity count",
            )?;
        }
        Ok(factory)
    }
}
