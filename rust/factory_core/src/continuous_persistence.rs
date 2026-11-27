use super::*;
use crate::persistence::{
    Error as SaveError, MAX_BYTES, MAX_MACHINES, Reader, Result, Writer, ensure,
};
use rust_conveyor::grid::{Cell as PortCell, Coord, Direction as Side};
use std::collections::BTreeSet;

fn write_side(w: &mut Writer, side: Option<Side>) {
    w.u8(side.map_or(255, |s| s as u8));
}
fn read_side(r: &mut Reader<'_>) -> Result<Option<Side>> {
    match r.u8()? {
        0 => Ok(Some(Side::North)),
        1 => Ok(Some(Side::East)),
        2 => Ok(Some(Side::South)),
        3 => Ok(Some(Side::West)),
        255 => Ok(None),
        _ => Err(SaveError::Invalid("transport side")),
    }
}
impl Factory {
    pub(crate) fn disk_sections(&self) -> Result<[Vec<u8>; 6]> {
        let mut sections = self._layout.disk_sections();
        let network = self
            ._network
            .snapshot()
            .map_err(|_| SaveError::Invalid("transport capture"))?;
        let mut transport = Writer::default();
        transport.u32(u32::from(network[4]));
        transport.bytes(&network);
        sections[2] = transport.0;
        let mut topology = Writer::default();
        topology.u64(self._geometry.ports.len() as u64);
        for (at, cell) in &self._geometry.ports {
            topology.cell(*at);
            for side in cell.inputs.into_iter().chain(cell.outputs) {
                write_side(&mut topology, side);
            }
        }
        sections[3] = topology.0;
        let mut clock = Writer::default();
        clock.bytes(&sections[4]);
        super::super::persistence::write_ledger(&mut clock, self._ledger);
        sections[4] = clock.0;
        Ok(sections)
    }
    pub(crate) fn from_disk_sections(sections: &[&[u8]; 6]) -> Result<Self> {
        let mut clock = Reader::new(sections[4]);
        let mut layout_sections = *sections;
        layout_sections[4] = clock.bytes(MAX_BYTES)?;
        let ledger = super::super::persistence::read_ledger(&mut clock)?;
        clock.end()?;
        let layout = crate::logistics::Factory::from_disk_sections(&layout_sections, true)?;
        let mut t = Reader::new(sections[2]);
        let version = t.u32()?;
        let bytes = t.bytes(MAX_BYTES)?;
        t.end()?;
        ensure(
            bytes.len() >= 8 && &bytes[..4] == b"RCNV" && u32::from(bytes[4]) == version,
            "native version",
        )?;
        if !(1..=2).contains(&version) {
            return Err(SaveError::Unsupported);
        }
        let network =
            Network::restore(bytes).map_err(|_| SaveError::Invalid("native transport"))?;
        network
            .validate()
            .map_err(|_| SaveError::Invalid("transport invariants"))?;
        let config = network.config();
        let expected = rust_conveyor::api::Config::default();
        ensure(
            config.speed.to_bits() == expected.speed.to_bits()
                && config.dt.to_bits() == STEP.to_bits()
                && config.minimum.to_bits() == expected.minimum.to_bits()
                && network.stats().frame == layout._tick as u64
                && network.last_identity() < i64::MAX as u64,
            "native clock/configuration",
        )?;
        let mut topology = Reader::new(sections[3]);
        let count = topology.count(MAX_MACHINES, 18)?;
        let mut ports = Ports::new();
        for _ in 0..count {
            let at = topology.cell()?;
            let inputs = [
                read_side(&mut topology)?,
                read_side(&mut topology)?,
                read_side(&mut topology)?,
            ];
            let outputs = [
                read_side(&mut topology)?,
                read_side(&mut topology)?,
                read_side(&mut topology)?,
            ];
            let cell = PortCell {
                position: Coord { x: at.x, y: at.z },
                inputs,
                outputs,
            };
            ensure(
                inputs[0].is_some()
                    && outputs[0].is_some()
                    && !(inputs[1].is_none() && inputs[2].is_some())
                    && !(outputs[1].is_none() && outputs[2].is_some())
                    && inputs
                        .into_iter()
                        .chain(outputs)
                        .flatten()
                        .collect::<BTreeSet<_>>()
                        .len()
                        == inputs.iter().chain(&outputs).flatten().count(),
                "transport ports",
            )?;
            PortCell::from_ports(cell.position, cell.ports())
                .map_err(|_| SaveError::Invalid("ports"))?;
            ensure(
                layout.world().contains(at)
                    && layout.world().block(at).is_belt()
                    && ports.insert(at, cell).is_none(),
                "port/world correspondence",
            )?;
        }
        topology.end()?;
        ensure(
            count
                == layout
                    ._machines
                    .iter()
                    .filter(|m| m.state.block.is_belt())
                    .count(),
            "missing ports",
        )?;
        // Derive only empty geometry. The restored native queues and junction
        // reservations are never seeded, stepped or reconstructed by this adapter.
        let (derived, mut geometry) =
            geometry::build(&layout, ports, network.last_identity(), None)
                .map_err(|_| SaveError::Invalid("derived geometry"))?;
        let actual = network.segment_specs();
        let expected = derived.segment_specs();
        ensure(
            actual.len() == expected.len()
                && actual.iter().zip(&expected).all(|(a, b)| {
                    a.key == b.key
                        && a.length.to_bits() == b.length.to_bits()
                        && a.entry == b.entry
                        && a.exit == b.exit
                }),
            "native geometry mismatch",
        )?;
        let expected: BTreeSet<_> = derived.links().into_iter().collect();
        let actual: BTreeSet<_> = network.links().into_iter().collect();
        ensure(actual.is_subset(&expected), "native links")?;
        geometry.pending = expected.difference(&actual).copied().collect();
        for command in network.active_devices() {
            ensure(
                if command.producer {
                    geometry
                        .producers
                        .contains_key(&(command.segment, command.slot))
                } else {
                    geometry
                        .consumers
                        .contains_key(&(command.segment, command.slot))
                },
                "native device",
            )?;
        }
        let total = layout
            ._machines
            .iter()
            .try_fold(network.stats().items as i64, |n, m| {
                n.checked_add(m.state.quantity)
                    .ok_or(SaveError::Invalid("inventory overflow"))
            })?;
        ensure(
            total == ledger.initial + ledger.produced - ledger.removed,
            "continuous inventory ledger",
        )?;
        ensure(
            network.stats().items as u128
                == ledger.initial as u128 + u128::from(ledger.created) - u128::from(ledger.retired),
            "continuous identity ledger",
        )?;
        Ok(Self {
            _layout: layout,
            _network: network,
            _geometry: geometry,
            _ledger: ledger,
            _work: Work::default(),
        })
    }
}
