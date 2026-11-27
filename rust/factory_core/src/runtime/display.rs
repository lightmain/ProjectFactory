//! Explicit, immutable local dynamic rounds. No engine objects or full observations.
use super::{Error, Mailbox, Runtime, Shared, Status};
use crate::{factory::Factory, world::Cell};
use std::collections::BTreeSet;
use std::sync::atomic::Ordering;

pub const MAX_BYTES: usize = 1024 * 1024;
pub const PAGE_BYTES: usize = 65536;
const HEADER: usize = 256;
const DEVICE_BYTES: usize = 40;
const ORE_BYTES: usize = 56;

#[derive(Clone, Debug, PartialEq)]
pub struct Device {
    pub cell: Cell,
    pub block: u8,
    pub direction: u8,
    pub quantity: i64,
    pub inputs: u8,
    pub outputs: u8,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Ore {
    pub id: u64,
    /// Godot's row-major 3x4 MultiMesh transform buffer.
    pub transform: [f32; 12],
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Info {
    pub world_epoch: u64,
    pub generation: u64,
    pub snapshot_id: u64,
    pub tick: i64,
    pub revision: u64,
    pub total_pages: usize,
    pub total_bytes: usize,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub info: Info,
    pub index: usize,
    pub bytes: usize,
    pub devices: Vec<Device>,
    pub ores: Vec<Ore>,
}
pub(super) struct Round {
    generation: u64,
    snapshot_id: u64,
    keys: Vec<Cell>,
    payload: Option<Result<Vec<Page>, Error>>,
}
fn check(mailbox: &Mailbox, epoch: u64) -> Result<(), Error> {
    if mailbox.epoch != epoch {
        return Err(Error::StaleEpoch);
    }
    if mailbox.status == Status::Faulted {
        return Err(Error::Faulted);
    }
    if mailbox.handoff_frozen {
        return Err(Error::NotReady);
    }
    Ok(())
}
impl Runtime {
    pub fn request_display(
        &self,
        epoch: u64,
        generation: u64,
        keys: Vec<Cell>,
    ) -> Result<(), Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        if generation == 0
            || generation > i64::MAX as u64
            || keys.is_empty()
            || keys.len() > 64
            || keys.iter().copied().collect::<BTreeSet<_>>().len() != keys.len()
            || keys.iter().any(|key| {
                [key.x, key.y, key.z]
                    .iter()
                    .any(|v| v.checked_mul(8).and_then(|v| v.checked_add(8)).is_none())
            })
        {
            return Err(Error::InvalidArgument);
        }
        let mut mailbox = self._shared.try_lock()?;
        check(&mailbox, epoch)?;
        if mailbox.display.is_some() {
            return Err(Error::Busy);
        }
        let snapshot_id = mailbox.next_display_id;
        mailbox.next_display_id = snapshot_id
            .checked_add(1)
            .filter(|next| *next <= i64::MAX as u64)
            .ok_or(Error::InvalidArgument)?;
        mailbox.display = Some(Round {
            generation,
            snapshot_id,
            keys,
            payload: None,
        });
        self._shared.wake.notify_one();
        Ok(())
    }
    pub fn poll_display(&self, epoch: u64, generation: u64) -> Result<Info, Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mailbox = self._shared.try_lock()?;
        check(&mailbox, epoch)?;
        let round = mailbox.display.as_ref().ok_or(Error::NotReady)?;
        if round.generation != generation {
            return Err(Error::InvalidArgument);
        }
        let pages = round
            .payload
            .as_ref()
            .ok_or(Error::NotReady)?
            .as_ref()
            .map_err(|e| *e)?;
        Ok(pages[0].info.clone())
    }
    pub fn poll_display_page(
        &self,
        epoch: u64,
        generation: u64,
        snapshot: u64,
        index: usize,
        bytes: usize,
    ) -> Result<Page, Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mailbox = self._shared.try_lock()?;
        check(&mailbox, epoch)?;
        let round = mailbox.display.as_ref().ok_or(Error::NotReady)?;
        if round.generation != generation {
            return Err(Error::InvalidArgument);
        }
        let pages = round
            .payload
            .as_ref()
            .ok_or(Error::NotReady)?
            .as_ref()
            .map_err(|e| *e)?;
        let page = pages.get(index).ok_or(Error::InvalidArgument)?;
        if page.info.snapshot_id != snapshot || bytes.min(PAGE_BYTES) < page.bytes {
            return Err(Error::InvalidArgument);
        }
        Ok(page.clone())
    }
    /// Also cancels pending capture. Identity checking prevents retiring a newer round.
    pub fn release_display(&self, epoch: u64, generation: u64) -> Result<(), Error> {
        if self._shared.closing.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let mut mailbox = self._shared.try_lock()?;
        if mailbox.epoch != epoch {
            return Err(Error::StaleEpoch);
        }
        if mailbox
            .display
            .as_ref()
            .is_some_and(|r| r.generation != generation)
        {
            return Err(Error::InvalidArgument);
        }
        mailbox.display = None;
        Ok(())
    }
}
fn build(
    factory: &Factory,
    epoch: u64,
    generation: u64,
    snapshot: u64,
    keys: &[Cell],
) -> Result<Vec<Page>, Error> {
    let info = Info {
        world_epoch: epoch,
        generation,
        snapshot_id: snapshot,
        tick: factory.clock().tick,
        revision: factory.revision(),
        total_pages: 0,
        total_bytes: 0,
    };
    let mut pages = vec![Page {
        info,
        index: 0,
        bytes: HEADER,
        devices: vec![],
        ores: vec![],
    }];
    let mut total = HEADER;
    let mut push = |device: Option<Device>, ore: Option<Ore>, charge: usize| -> Result<(), Error> {
        if pages.last().expect("page").bytes + charge > PAGE_BYTES {
            total += HEADER;
            let info = pages[0].info.clone();
            pages.push(Page {
                info,
                index: pages.len(),
                bytes: HEADER,
                devices: vec![],
                ores: vec![],
            });
        }
        if total + charge > MAX_BYTES {
            return Err(Error::InvalidArgument);
        }
        total += charge;
        let page = pages.last_mut().expect("page");
        page.bytes += charge;
        if let Some(device) = device {
            page.devices.push(device);
        }
        if let Some(ore) = ore {
            page.ores.push(ore);
        }
        Ok(())
    };
    let bounds = factory.world().bounds();
    for key in keys {
        for x in 0..8 {
            for y in 0..8 {
                for z in 0..8 {
                    let cell = Cell::new(key.x * 8 + x, key.y * 8 + y, key.z * 8 + z);
                    if !bounds.contains(cell) {
                        continue;
                    }
                    let Some(row) = factory
                        .local_machine(cell, (MAX_BYTES - HEADER) / ORE_BYTES)
                        .map_err(|_| Error::InvalidArgument)?
                    else {
                        continue;
                    };
                    let mask = |ports: [Option<crate::belt_placement::Direction>; 3]| {
                        ports
                            .into_iter()
                            .flatten()
                            .fold(0, |mask, side| mask | (1 << side as u8))
                    };
                    push(
                        Some(Device {
                            cell,
                            block: row.block as u8,
                            direction: row.direction as u8,
                            quantity: row.quantity,
                            inputs: mask(row.input_ports),
                            outputs: mask(row.output_ports),
                        }),
                        None,
                        DEVICE_BYTES,
                    )?;
                    for ore in row.ores {
                        let [x, y, z] = ore.position(cell, row.block).map(|v| v as f32);
                        push(
                            None,
                            Some(Ore {
                                id: ore.id,
                                transform: [1., 0., 0., x, 0., 1., 0., y, 0., 0., 1., z],
                            }),
                            ORE_BYTES,
                        )?;
                    }
                }
            }
        }
    }
    let count = pages.len();
    for page in &mut pages {
        page.info.total_pages = count;
        page.info.total_bytes = total;
    }
    Ok(pages)
}
pub(super) fn service(shared: &Shared, factory: &Factory) -> bool {
    capture(shared, factory, || {})
}

fn capture(shared: &Shared, factory: &Factory, after_capture: impl FnOnce()) -> bool {
    let mailbox = shared.lock();
    let Some(round) = &mailbox.display else {
        return false;
    };
    if round.payload.is_some() || mailbox.handoff_frozen {
        return false;
    }
    let generation = round.generation;
    let keys = round.keys.clone();
    let epoch = mailbox.epoch;
    let snapshot = round.snapshot_id;
    drop(mailbox);
    let payload = if snapshot >= i64::MAX as u64 {
        Err(Error::InvalidArgument)
    } else {
        build(factory, epoch, generation, snapshot, &keys)
    };
    after_capture();
    let mut mailbox = shared.lock();
    if mailbox.epoch == epoch
        && let Some(round) = mailbox
            .display
            .as_mut()
            .filter(|r| r.generation == generation && r.snapshot_id == snapshot)
    {
        round.payload = Some(payload);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        belt_placement::Direction,
        factory::Ruleset,
        logistics::Settings,
        runtime::Limits,
        world::{Block, Bounds},
    };
    use std::sync::Arc;

    fn harness() -> Runtime {
        let shared = Arc::new(Shared::default());
        shared.lock().status = Status::Running;
        Runtime {
            _shared: shared,
            _limits: Limits::default(),
            _persistence: false,
        }
    }
    #[test]
    fn cancelling_in_flight_capture_cannot_fill_replacement_with_reused_generation() {
        let runtime = harness();
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 1.,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        factory
            .place(Cell::new(0, 0, 0), Block::Chest, Direction::South)
            .unwrap();
        runtime
            .request_display(1, 1, vec![Cell::new(0, 0, 0)])
            .unwrap();
        capture(&runtime._shared, &factory, || {
            runtime.release_display(1, 1).unwrap();
            runtime
                .request_display(1, 1, vec![Cell::new(1, 0, 0)])
                .unwrap();
        });
        assert_eq!(runtime.poll_display(1, 1), Err(Error::NotReady));
        service(&runtime._shared, &factory);
        let info = runtime.poll_display(1, 1).unwrap();
        assert!(
            runtime
                .poll_display_page(1, 1, info.snapshot_id, 0, PAGE_BYTES)
                .unwrap()
                .devices
                .is_empty()
        );
    }
    #[test]
    fn multipage_manifest_is_complete_and_overflow_never_exposes_partial_pages() {
        for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
            let runtime = harness();
            let mut factory = Factory::new(
                Bounds::default(),
                Settings {
                    interval: 1.,
                    amount: 1,
                },
                rules,
            )
            .unwrap();
            let mut cells = vec![];
            let mut keys = vec![];
            for x in 0..32 {
                for y in 0..32 {
                    for z in 0..32 {
                        cells.push((Cell::new(x, y, z), Block::Chest, Direction::South));
                    }
                }
            }
            for x in 0..4 {
                for y in 0..4 {
                    for z in 0..4 {
                        keys.push(Cell::new(x, y, z));
                    }
                }
            }
            let preview = factory.preview(&cells).unwrap();
            factory.commit(&preview).unwrap();
            runtime.request_display(1, 1, keys[..4].to_vec()).unwrap();
            service(&runtime._shared, &factory);
            let info = runtime.poll_display(1, 1).unwrap();
            assert_eq!(info.total_pages, 2);
            let mut members = BTreeSet::new();
            let mut bytes = 0;
            for index in 0..info.total_pages {
                let page = runtime
                    .poll_display_page(1, 1, info.snapshot_id, index, PAGE_BYTES)
                    .unwrap();
                assert_eq!(page.info, info);
                assert!(page.bytes <= PAGE_BYTES);
                bytes += page.bytes;
                for device in page.devices {
                    assert!(members.insert(device.cell));
                }
            }
            assert_eq!(members.len(), 2048);
            assert_eq!(bytes, info.total_bytes);
            runtime.release_display(1, 1).unwrap();
            runtime.request_display(1, 2, keys).unwrap();
            service(&runtime._shared, &factory);
            assert_eq!(runtime.poll_display(1, 2), Err(Error::InvalidArgument));
            assert_eq!(
                runtime.poll_display_page(1, 2, info.snapshot_id, 0, PAGE_BYTES),
                Err(Error::InvalidArgument)
            );
            runtime.release_display(1, 2).unwrap();
            runtime
                .request_display(1, 3, vec![Cell::new(-1, 0, -1)])
                .unwrap();
            service(&runtime._shared, &factory);
            assert!(runtime.poll_display(1, 3).is_ok());
        }
    }
}
