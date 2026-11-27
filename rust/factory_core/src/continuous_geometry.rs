//! Three-dimensional half-arm adapter. Port edits and junction scheduling are
//! delegated to RustConveyor; this module owns only host geometry and devices.
use super::{Binding, Error, Geometry};
use crate::{
    belt_placement::{Direction, Segment, inlet_step, outlet_step},
    logistics::{self, Ore},
    world::{Block, Cell},
};
use rust_conveyor::{
    api::{Config, EntryPolicy, ExitPolicy, Network, SeedGap, SegmentKey, SegmentSpec},
    belt_operation,
    grid::{Cell as PortCell, Coord, Direction as Side, PortState},
};
use std::collections::{BTreeMap, BTreeSet};

pub(super) type Ports = BTreeMap<Cell, PortCell>;

pub(super) fn side(direction: Direction) -> Side {
    match direction {
        Direction::North => Side::North,
        Direction::East => Side::East,
        Direction::South => Side::South,
        Direction::West => Side::West,
    }
}
pub(super) fn direction(side: Side) -> Direction {
    match side {
        Side::North => Direction::North,
        Side::East => Direction::East,
        Side::South => Direction::South,
        Side::West => Direction::West,
    }
}
fn coord(cell: Cell) -> Coord {
    Coord {
        x: cell.x,
        y: cell.z,
    }
}

/// Legacy direct placement keeps its compatible device entrances. Explicit
/// route operations below use the viewer's frozen-cell port patch.
pub(super) fn synchronize(layout: &logistics::Factory, ports: &mut Ports) {
    ports.retain(|at, _| layout.world().block(*at).is_belt());
    for machine in &layout._machines {
        let row = &machine.state;
        if !row.block.is_belt() {
            continue;
        }
        let fresh = !ports.contains_key(&row.cell);
        let cell = ports.entry(row.cell).or_insert_with(|| {
            PortCell::ordinary(
                coord(row.cell),
                side(row.direction.opposite()),
                side(row.direction),
            )
        });
        if fresh || !cell.is_split() {
            let mut values = cell.ports();
            if machine.inputs.iter().any(Option::is_some) {
                for value in &mut values {
                    if *value == PortState::Input {
                        *value = PortState::Closed;
                    }
                }
            }
            for source in machine.inputs.iter().flatten() {
                let input = side(layout._machines[*source].state.direction.opposite());
                if values[input as usize] != PortState::Output {
                    values[input as usize] = PortState::Input;
                }
            }
            if let Ok(updated) = PortCell::from_ports(coord(row.cell), values) {
                *cell = updated;
            }
        }
    }
}

pub(super) fn build_route(
    layout: &logistics::Factory,
    ports: &mut Ports,
    path: &[Segment],
) -> Result<(), Error> {
    // Each horizontal run uses the shared operation unchanged. Height is a
    // separate host coordinate; stacked belts never alias in the port map.
    let frozen = ports.clone();
    let mut start = 0;
    while start < path.len() {
        if path[start].block.is_slope() || !layout.world().block(path[start].cell).is_belt() {
            start += 1;
            continue;
        }
        let y = path[start].cell.y;
        let mut end = start + 1;
        while end < path.len()
            && path[end].cell.y == y
            && !path[end].block.is_slope()
            && layout.world().block(path[end].cell).is_belt()
        {
            end += 1;
        }
        // Boundary slopes/devices supply the confirmed path direction but
        // are not editable flat cells in this projected horizontal run.
        let first = start.saturating_sub(1);
        let last = (end + usize::from(end < path.len())).min(path.len());
        let anchors: BTreeMap<_, _> = path[first..last]
            .iter()
            .filter(|s| {
                s.cell.y != y || s.block.is_slope() || !layout.world().block(s.cell).is_belt()
            })
            .map(|s| {
                let p = coord(s.cell);
                let cell = frozen.get(&s.cell).copied().unwrap_or_else(|| {
                    PortCell::ordinary(p, side(s.direction.opposite()), side(s.direction))
                });
                (p, cell)
            })
            .collect();
        let mut neighbors = BTreeMap::new();
        let mut sources = BTreeSet::new();
        for segment in &path[start..end] {
            for side in Side::ALL {
                for input in [true, false] {
                    let arm = Arm {
                        cell: segment.cell,
                        input,
                        side,
                    };
                    if let Some(other) = arm.matching(layout, &frozen) {
                        neighbors.insert(coord(other.cell), frozen[&other.cell]);
                    }
                }
                let offset = direction(side).cell();
                if let Some(at) = segment.cell.checked_offset(offset.x, 0, offset.z)
                    && let Some(&index) = layout._index.get(&at)
                {
                    let device = &layout._machines[index].state;
                    if !device.block.is_belt()
                        && (device.direction == direction(side).opposite()
                            || (device.block != Block::Miner
                                && device.direction == direction(side)))
                    {
                        neighbors.insert(
                            coord(at),
                            PortCell::ordinary(
                                coord(at),
                                self::side(device.direction.opposite()),
                                self::side(device.direction),
                            ),
                        );
                        if device.block == Block::Miner {
                            sources.insert(coord(at));
                        }
                    }
                }
            }
        }
        let run: Vec<_> = path[first..last].iter().map(|s| coord(s.cell)).collect();
        let cells = |p: Coord| {
            anchors
                .get(&p)
                .copied()
                .or_else(|| neighbors.get(&p).copied())
                .or_else(|| frozen.get(&Cell::new(p.x, y, p.y)).copied())
        };
        let delta = belt_operation::build(&run, side(path[end - 1].direction), cells, |p| {
            !anchors.contains_key(&p) && sources.contains(&p)
        })?;
        for change in delta.cells {
            if anchors.contains_key(&change.position) {
                continue;
            }
            let at = Cell::new(change.position.x, y, change.position.y);
            if let Some(after) = change.after {
                ports.insert(at, after);
            }
        }
        start = end;
    }
    Ok(())
}

pub(super) fn delete(
    layout: &logistics::Factory,
    ports: &mut Ports,
    at: Cell,
) -> Result<(), Error> {
    // Project only the physically connected neighbors, using each arm's
    // inlet/outlet height. A belt stacked at the same X/Z is not a neighbor.
    let mut projection = BTreeMap::new();
    if let Some(&cell) = ports.get(&at) {
        projection.insert(coord(at), at);
        for side in Side::ALL {
            let value = cell.ports()[side as usize];
            if value == PortState::Closed {
                continue;
            }
            let arm = Arm {
                cell: at,
                input: value == PortState::Input,
                side,
            };
            if let Some(other) = arm.matching(layout, ports) {
                projection.insert(coord(other.cell), other.cell);
            }
        }
    }
    let delta = belt_operation::delete(
        &[coord(at)],
        |p| projection.get(&p).and_then(|at| ports.get(at)).copied(),
        |p| layout.world().block(Cell::new(p.x, at.y, p.y)) == Block::Miner,
    )?;
    for change in delta.cells {
        let cell = projection[&change.position];
        match change.after {
            Some(after) => {
                ports.insert(cell, after);
            }
            None => {
                ports.remove(&cell);
            }
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(super) struct Arm {
    pub cell: Cell,
    pub input: bool,
    pub side: Side,
}
impl Arm {
    fn length(self, layout: &logistics::Factory) -> f64 {
        if layout.world().block(self.cell).is_slope() {
            0.5_f64.sqrt() / 2.0
        } else {
            0.25
        }
    }
    fn key(self, layout: &logistics::Factory) -> SegmentKey {
        let bounds = layout.world().bounds();
        let min = bounds.minimum();
        let max = bounds.maximum();
        let index = ((i64::from(self.cell.y - min.y) * i64::from(max.z - min.z)
            + i64::from(self.cell.z - min.z))
            * i64::from(max.x - min.x)
            + i64::from(self.cell.x - min.x)) as u64;
        SegmentKey(index * 8 + u64::from(!self.input) * 4 + self.side as u64 + 1)
    }
    fn matching(self, layout: &logistics::Factory, ports: &Ports) -> Option<Arm> {
        let offset = direction(self.side).cell();
        let block = layout.world().block(self.cell);
        let edge_height = if self.input {
            inlet_step(block)
        } else {
            outlet_step(block)
        };
        for height in 0..2 {
            let at = self
                .cell
                .checked_offset(offset.x, edge_height - height, offset.z)?;
            let other = layout.world().block(at);
            let opposite_height = if self.input {
                outlet_step(other)
            } else {
                inlet_step(other)
            };
            let port = if self.input {
                PortState::Output
            } else {
                PortState::Input
            };
            if other.is_belt()
                && opposite_height == height
                && ports
                    .get(&at)
                    .is_some_and(|cell| cell.ports()[self.side.opposite() as usize] == port)
            {
                return Some(Arm {
                    cell: at,
                    input: !self.input,
                    side: self.side.opposite(),
                });
            }
        }
        None
    }
}

pub(super) fn build(
    layout: &logistics::Factory,
    ports: Ports,
    last_identity: u64,
    previous: Option<(&Network, &Geometry)>,
) -> Result<(Network, Geometry), Error> {
    let mut arms = BTreeSet::new();
    for (&at, cell) in &ports {
        for side in cell.inputs.into_iter().flatten() {
            arms.insert(Arm {
                cell: at,
                input: true,
                side,
            });
        }
        for side in cell.outputs.into_iter().flatten() {
            arms.insert(Arm {
                cell: at,
                input: false,
                side,
            });
        }
    }
    let mut next = BTreeMap::new();
    for &arm in &arms {
        let cell = ports[&arm.cell];
        let successor = if arm.input {
            (!cell.is_merge() && !cell.is_split()).then(|| Arm {
                cell: arm.cell,
                input: false,
                side: cell.outputs[0].unwrap(),
            })
        } else {
            arm.matching(layout, &ports)
        };
        if let Some(successor) = successor {
            next.insert(arm, successor);
        }
    }
    let predecessors: BTreeMap<_, _> = next.iter().map(|(&a, &b)| (b, a)).collect();
    let mut visited = BTreeSet::new();
    let mut groups = BTreeMap::new();
    for head in arms
        .iter()
        .filter(|a| !predecessors.contains_key(a))
        .chain(arms.iter())
    {
        if visited.contains(head) {
            continue;
        }
        let mut path = Vec::new();
        let mut current = *head;
        loop {
            visited.insert(current);
            path.push(current);
            let Some(&successor) = next.get(&current) else {
                break;
            };
            if visited.contains(&successor) {
                break;
            }
            current = successor;
        }
        // The API disallows short segments with both Merge and Split policies.
        // A normal boundary between half-arms keeps the actual length while
        // letting the library own both junctions. Loops also need a boundary.
        let tail = *path.last().unwrap();
        let short_merge_split = !head.input
            && ports[&head.cell].is_merge()
            && tail.input
            && ports[&tail.cell].is_split()
            && path.iter().map(|arm| arm.length(layout)).sum::<f64>() < 2.0;
        if path.len() > 1 && (short_merge_split || next.get(&tail) == Some(head)) {
            let cut = path.len() / 2;
            let tail = path.split_off(cut);
            groups.insert(tail[0].key(layout), tail);
        }
        groups.insert(head.key(layout), path);
    }
    let mut geometry = Geometry {
        bindings: BTreeMap::new(),
        lengths: BTreeMap::new(),
        producers: BTreeMap::new(),
        consumers: BTreeMap::new(),
        pending: Vec::new(),
        ports,
        paths: groups.clone(),
    };
    let mut ownership = BTreeMap::new();
    let mut specs = BTreeMap::new();
    for (&key, path) in &groups {
        let mut length = 0.0;
        for &arm in path {
            let size = arm.length(layout);
            geometry
                .bindings
                .entry(arm.cell)
                .or_default()
                .push(Binding {
                    segment: key,
                    start: length,
                    length: size,
                    arm,
                });
            ownership.insert(arm, (key, length));
            length += size;
        }
        geometry.lengths.insert(key, length);
        let head = path[0];
        let tail = *path.last().unwrap();
        let mut spec = SegmentSpec::new(key, length);
        if !head.input {
            let cell = geometry.ports[&head.cell];
            spec.entry = match cell.inputs.iter().flatten().count() {
                3 => EntryPolicy::Merge3,
                2 => EntryPolicy::Merge,
                _ => EntryPolicy::Single,
            };
        }
        if tail.input {
            let cell = geometry.ports[&tail.cell];
            spec.exit = match cell.outputs.iter().flatten().count() {
                3 => ExitPolicy::Split3,
                2 => ExitPolicy::Split,
                _ => ExitPolicy::Single,
            };
        }
        specs.insert(key, spec);
    }
    let unchanged: BTreeSet<_> = groups
        .iter()
        .filter_map(|(&key, path)| {
            let (network, old) = previous?;
            let old_spec = network.segment_spec(key).ok()?;
            (old.paths.get(&key) == Some(path)
                && old_spec.entry == specs[&key].entry
                && old_spec.exit == specs[&key].exit)
                .then_some(key)
        })
        .collect();
    let mut network = if let Some((old, _)) = previous {
        Network::restore(&old.snapshot()?)?
    } else {
        let mut net = Network::new(Config::default())?;
        net.initialize_clock(layout._tick as u64, last_identity)?;
        net
    };
    for (key, _) in network.segments() {
        if !unchanged.contains(&key) {
            network.remove_segment(key)?;
        }
    }
    let mut seeds: BTreeMap<SegmentKey, Vec<(u64, f64)>> = BTreeMap::new();
    // Progress alone cannot identify an arm at a junction center: the input
    // segment's terminal waiter and an output's start both have progress 0.5.
    // Recover ownership from the old authoritative segment's sample interval.
    let mut old_arms = BTreeMap::new();
    if let Some((network, geometry)) = previous {
        for bindings in geometry.bindings.values() {
            for binding in bindings {
                for item in network
                    .sample(
                        binding.segment,
                        binding.start,
                        binding.start + binding.length,
                        usize::MAX,
                    )?
                    .items
                {
                    old_arms.insert(item.id.0, binding.arm);
                }
            }
        }
    }
    for machine in &layout._machines {
        let row = &machine.state;
        if !row.block.is_belt() {
            continue;
        }
        let cell = geometry.ports[&row.cell];
        for ore in &row.ores {
            let old_arm = old_arms.get(&ore.id);
            let input = old_arm.map_or(ore.progress < 0.5, |arm| arm.input);
            let preferred = old_arm.map_or_else(
                || {
                    if input {
                        side(ore.incoming.opposite())
                    } else {
                        side(ore.outgoing)
                    }
                },
                |arm| arm.side,
            );
            let available = if input { cell.inputs } else { cell.outputs };
            let arm = Arm {
                cell: row.cell,
                input,
                side: available
                    .into_iter()
                    .flatten()
                    .find(|&s| s == preferred)
                    .unwrap_or(available[0].unwrap()),
            };
            let (key, start) = ownership[&arm];
            if !unchanged.contains(&key) {
                let p = if input {
                    ore.progress * 2.0
                } else {
                    (ore.progress - 0.5) * 2.0
                };
                seeds
                    .entry(key)
                    .or_default()
                    .push((ore.id, start + p * arm.length(layout)));
            }
        }
    }
    for (&key, spec) in &specs {
        if unchanged.contains(&key) {
            continue;
        }
        let mut items = seeds.remove(&key).unwrap_or_default();
        items.sort_by(|a, b| b.1.total_cmp(&a.1));
        let mut previous = spec.length;
        let mut gaps = Vec::new();
        for (id, position) in items {
            let mut distance = previous - position;
            if !gaps.is_empty() && (distance - 0.25).abs() < 1e-7 {
                distance = 0.25;
            }
            gaps.push(SeedGap {
                id: rust_conveyor::api::ItemId(id),
                distance: distance.max(0.0),
                correction: 0.0,
            });
            previous = position;
        }
        network.add_segment_gaps(*spec, &gaps)?;
    }
    let mut links = BTreeSet::new();
    for (&key, path) in &groups {
        let head = path[0];
        let tail = *path.last().unwrap();
        let cell = geometry.ports[&head.cell];
        if !head.input && cell.is_merge() {
            for (slot, side) in cell.inputs.into_iter().flatten().enumerate() {
                let source = ownership[&Arm {
                    cell: head.cell,
                    input: true,
                    side,
                }]
                    .0;
                links.insert((source, 0, key, slot));
            }
        } else if !head.input && cell.is_split() {
            let source = ownership[&Arm {
                cell: head.cell,
                input: true,
                side: cell.inputs[0].unwrap(),
            }]
                .0;
            let slot = cell
                .outputs
                .into_iter()
                .flatten()
                .position(|s| s == head.side)
                .unwrap();
            links.insert((source, slot, key, 0));
        } else if let Some(&source) = predecessors.get(&head) {
            links.insert((ownership[&source].0, 0, key, 0));
        } else if head.input {
            let vector = direction(head.side).cell();
            let height = inlet_step(layout.world().block(head.cell));
            if let Some(at) = head.cell.checked_offset(vector.x, height, vector.z)
                && let Some(&index) = layout._index.get(&at)
                && !layout._machines[index].state.block.is_belt()
                && layout._machines[index].state.direction == direction(head.side).opposite()
            {
                geometry.producers.insert((key, 0), index);
            }
        }
        if !tail.input && tail.matching(layout, &geometry.ports).is_none() {
            let vector = direction(tail.side).cell();
            let height = outlet_step(layout.world().block(tail.cell));
            if let Some(at) = tail.cell.checked_offset(vector.x, height, vector.z)
                && let Some(&index) = layout._index.get(&at)
                && !layout._machines[index].state.block.is_belt()
                && layout._machines[index].state.direction == direction(tail.side)
            {
                geometry.consumers.insert((key, 0), index);
            }
        }
    }
    for (source, slot, target, input) in network.links() {
        if !links.contains(&(source, slot, target, input)) {
            network.disconnect(source, slot)?;
        }
    }
    let connected: BTreeSet<_> = network.links().into_iter().collect();
    for link @ (source, slot, target, input) in links {
        if connected.contains(&link) {
            continue;
        }
        match network.connect(source, slot, target, input) {
            Ok(()) => (),
            Err(rust_conveyor::api::Error::InsufficientSpace) => geometry.pending.push(link),
            Err(error) => return Err(error.into()),
        }
    }
    Ok((network, geometry))
}

pub(super) fn ore(binding: Binding, position: f64, id: u64, ports: &Ports) -> Ore {
    let cell = ports[&binding.arm.cell];
    let progress = ((position - binding.start) / binding.length).clamp(0.0, 1.0);
    Ore {
        id,
        incoming: direction(if binding.arm.input {
            binding.arm.side
        } else {
            cell.inputs[0].unwrap()
        })
        .opposite(),
        outgoing: direction(if binding.arm.input {
            cell.outputs[0].unwrap()
        } else {
            binding.arm.side
        }),
        progress: if binding.arm.input {
            progress * 0.5
        } else {
            0.5 + progress * 0.5
        },
    }
}
