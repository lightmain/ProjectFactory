//! Versioned little-endian checkpoints, independent of Godot and Rust layouts.
use crate::factory::{Factory, Ruleset};
use flate2::{Compression, bufread::DeflateDecoder, write::DeflateEncoder};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};

pub mod jobs;
pub mod store;

pub const MAX_BYTES: usize = 512 * 1024 * 1024;
pub(crate) const MAX_MACHINES: usize = 128 * 128 * 128;
const HEADER: usize = 128;
const TABLE: usize = 6 * 96;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    Invalid(&'static str),
    Unsupported,
    Io(String),
    Busy,
    Closed,
    WorkerFault,
    StaleDirectory,
    Cancelled,
    CommitUncertain,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(reason) => write!(f, "invalid_save: {reason}"),
            Self::Io(reason) => write!(f, "disk_error: {reason}"),
            other => write!(f, "{other:?}"),
        }
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}
pub(crate) type Result<T> = std::result::Result<T, Error>;
pub(crate) fn ensure(valid: bool, reason: &'static str) -> Result<()> {
    if valid {
        Ok(())
    } else {
        Err(Error::Invalid(reason))
    }
}

#[cfg(test)]
mod semantic_tests {
    use super::*;
    use crate::{
        belt_placement::Direction,
        logistics::Settings,
        world::{Block, Bounds, Cell},
    };
    fn snapshot(with_devices: bool) -> Snapshot {
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.6,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        if with_devices {
            factory
                .place(Cell::new(0, 0, 0), Block::Miner, Direction::East)
                .unwrap();
            factory
                .place(Cell::new(1, 0, 0), Block::Chest, Direction::East)
                .unwrap();
            factory.advance(1.0).unwrap();
        }
        capture(
            &factory,
            &Session {
                world_id: [7; 16],
                world_name: "test".into(),
                autosave_minutes: 5.0,
                autosave_retention: 3,
                player: Player::default(),
            },
        )
        .unwrap()
    }
    #[test]
    fn rejects_checksum_correct_illegal_compensation() {
        let mut snapshot = snapshot(false);
        // Factory clock prefix is revision,next_request,layout byte length.
        // Layout clock starts settings(16),time(8),compensation(8).
        snapshot.sections[4][48..56].copy_from_slice(&0.02f64.to_le_bytes());
        let encoded = snapshot.encode().unwrap();
        assert!(decode(&encoded).unwrap().restore().is_err());
    }
    #[test]
    fn rejects_checksum_correct_missing_settled_adjacency() {
        let mut snapshot = snapshot(true);
        // Two non-belt records have a fixed 135-byte prefix including stop tick.
        snapshot.sections[1][103..135].fill(255);
        snapshot.sections[1][238..270].fill(255);
        assert!(
            decode(&snapshot.encode().unwrap())
                .unwrap()
                .restore()
                .is_err()
        );
    }
    #[test]
    fn rejects_checksum_correct_impossible_miner_phases() {
        for (range, bytes) in [
            (63..71, f64::INFINITY.to_le_bytes()),
            (87..95, 100i64.to_le_bytes()),
        ] {
            let mut snapshot = snapshot(true);
            snapshot.sections[1][range].copy_from_slice(&bytes);
            assert!(
                decode(&snapshot.encode().unwrap())
                    .unwrap()
                    .restore()
                    .is_err()
            );
        }
    }
    #[test]
    fn rejects_checksum_correct_joint_miner_phase_rollback() {
        let mut snapshot = snapshot(true);
        snapshot.sections[1][63..71].copy_from_slice(&0.6f64.to_le_bytes());
        snapshot.sections[1][87..95].copy_from_slice(&0i64.to_le_bytes());
        assert!(
            decode(&snapshot.encode().unwrap())
                .unwrap()
                .restore()
                .is_err()
        );
    }
    #[test]
    fn rejects_checksum_correct_joint_miner_phase_false_stop() {
        let (mut factory, session) = snapshot(true).restore().unwrap();
        factory.advance(1.0).unwrap();
        for stop_tick in [-1i64, 72, 120] {
            let mut snapshot = capture(&factory, &session).unwrap();
            snapshot.sections[1][63..71].copy_from_slice(&f64::INFINITY.to_le_bytes());
            snapshot.sections[1][87..95].copy_from_slice(&1i64.to_le_bytes());
            snapshot.sections[1][135..143].copy_from_slice(&stop_tick.to_le_bytes());
            assert!(
                decode(&snapshot.encode().unwrap())
                    .unwrap()
                    .restore()
                    .is_err()
            );
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Player {
    pub frame: u64,
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub spawn: [f64; 3],
    pub body_rotation: [f64; 3],
    pub view_rotation: [f64; 3],
    pub tool: u8,
    pub build_rotation: u8,
    pub free_view: bool,
    pub free_position: [f64; 3],
    pub free_rotation: [f64; 3],
}
impl Default for Player {
    fn default() -> Self {
        Self {
            frame: 0,
            position: [2.8, 0.05, 4.0],
            velocity: [0.0; 3],
            spawn: [2.8, 0.05, 4.0],
            body_rotation: [0.0; 3],
            view_rotation: [0.0; 3],
            tool: 6,
            build_rotation: 0,
            free_view: false,
            free_position: [4.0, 7.0, 6.0],
            free_rotation: [0.0; 3],
        }
    }
}
impl Player {
    pub fn validate(&self) -> Result<()> {
        for values in [
            self.position,
            self.velocity,
            self.spawn,
            self.body_rotation,
            self.view_rotation,
            self.free_position,
            self.free_rotation,
        ] {
            ensure(
                values
                    .iter()
                    .all(|v| v.is_finite() && v.abs() < 1_000_000.0),
                "player values",
            )?;
        }
        ensure(
            (1..=7).contains(&self.tool) || self.tool == 9 || self.tool == 13,
            "tool",
        )?;
        ensure(
            self.build_rotation <= 3 && self.frame <= i64::MAX as u64,
            "player frame/rotation",
        )
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub world_id: [u8; 16],
    pub world_name: String,
    pub autosave_minutes: f64,
    pub autosave_retention: u32,
    pub player: Player,
}
impl Session {
    pub fn validate(&self) -> Result<()> {
        ensure(
            self.world_id != [0; 16]
                && !self.world_name.trim().is_empty()
                && self.world_name.chars().count() <= 80
                && self.world_name.len() <= 320,
            "world identity/name",
        )?;
        ensure(
            self.autosave_minutes.is_finite()
                && (0.0..=1440.0).contains(&self.autosave_minutes)
                && (1..=100).contains(&self.autosave_retention),
            "autosave settings",
        )?;
        self.player.validate()
    }
    pub(crate) fn write(&self, w: &mut Writer) {
        w.raw(&self.world_id);
        w.string(&self.world_name);
        w.f64(self.autosave_minutes);
        w.u32(self.autosave_retention);
        let p = &self.player;
        w.u64(p.frame);
        for values in [
            p.position,
            p.velocity,
            p.spawn,
            p.body_rotation,
            p.view_rotation,
        ] {
            for v in values {
                w.f64(v);
            }
        }
        w.u8(p.tool);
        w.u8(p.build_rotation);
        w.bool(p.free_view);
        for values in [p.free_position, p.free_rotation] {
            for v in values {
                w.f64(v);
            }
        }
    }
    pub(crate) fn read(r: &mut Reader<'_>) -> Result<Self> {
        let world_id = r.array()?;
        let world_name = r.string(320)?;
        let autosave_minutes = r.f64()?;
        let autosave_retention = r.u32()?;
        let frame = r.u64()?;
        let position = r.vec3()?;
        let velocity = r.vec3()?;
        let spawn = r.vec3()?;
        let body_rotation = r.vec3()?;
        let view_rotation = r.vec3()?;
        let tool = r.u8()?;
        let build_rotation = r.u8()?;
        let free_view = r.bool()?;
        let free_position = r.vec3()?;
        let free_rotation = r.vec3()?;
        let session = Self {
            world_id,
            world_name,
            autosave_minutes,
            autosave_retention,
            player: Player {
                frame,
                position,
                velocity,
                spawn,
                body_rotation,
                view_rotation,
                tool,
                build_rotation,
                free_view,
                free_position,
                free_rotation,
            },
        };
        session.validate()?;
        Ok(session)
    }
}

/// Pure bytes may cross the I/O thread boundary; no engine or live world values.
pub struct Snapshot {
    pub session: Session,
    pub ruleset: Ruleset,
    pub tick: u64,
    pub time: f64,
    pub revision: u64,
    sections: [Vec<u8>; 6],
}
pub fn capture(factory: &Factory, session: &Session) -> Result<Snapshot> {
    session.validate()?;
    let state = factory.observe().map_err(|_| Error::Invalid("capture"))?;
    let mut sections = factory.disk_sections()?;
    let mut player = Writer::default();
    session.write(&mut player);
    sections[5] = player.0;
    Ok(Snapshot {
        session: session.clone(),
        ruleset: factory.ruleset(),
        tick: state.tick as u64,
        time: state.time,
        revision: factory.revision(),
        sections,
    })
}
impl Snapshot {
    pub fn restore(self) -> Result<(Factory, Session)> {
        let factory = Factory::from_disk_sections(self.ruleset, &self.sections)?;
        let state = factory
            .observe()
            .map_err(|_| Error::Invalid("observation"))?;
        ensure(
            state.tick >= 0
                && state.tick as u64 == self.tick
                && state.time.to_bits() == self.time.to_bits()
                && factory.revision() == self.revision,
            "checkpoint header",
        )?;
        Ok((factory, self.session))
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.session.validate()?;
        let mut output = vec![0; HEADER + TABLE];
        let raw_total = self.sections.iter().try_fold(0usize, |total, s| {
            total
                .checked_add(s.len())
                .ok_or(Error::Invalid("size overflow"))
        })?;
        ensure(raw_total <= MAX_BYTES, "raw size")?;
        for (index, section) in self.sections.iter().enumerate() {
            let mut compressor = DeflateEncoder::new(Vec::new(), Compression::new(3));
            compressor.write_all(section)?;
            let compressed = compressor.finish()?;
            let (mode, stored) = if compressed.len() < section.len() {
                (1u32, compressed.as_slice())
            } else {
                (0, section.as_slice())
            };
            let mut row = Writer::default();
            row.u32(index as u32 + 1);
            row.u32(1);
            row.u32(1);
            row.u32(mode);
            row.u64(output.len() as u64);
            row.u64(stored.len() as u64);
            row.u64(section.len() as u64);
            row.u64(1);
            row.raw(&Sha256::digest(section));
            row.raw(&[0; 16]);
            output[HEADER + index * 96..HEADER + (index + 1) * 96].copy_from_slice(&row.0);
            ensure(
                output
                    .len()
                    .checked_add(stored.len())
                    .is_some_and(|n| n <= MAX_BYTES),
                "file size",
            )?;
            output.extend_from_slice(stored);
        }
        let mut head = Writer::default();
        head.raw(b"PFSAVE5\0");
        head.u32(5);
        head.u32((HEADER + TABLE) as u32);
        head.u32(6);
        head.u32(0);
        head.u64(output.len() as u64);
        head.raw(&self.session.world_id);
        head.u32(if self.ruleset == Ruleset::LegacyDiscreteV1 {
            0
        } else {
            1
        });
        head.u32(1);
        head.u64(self.tick);
        head.f64(self.time);
        head.u64(self.revision);
        head.u64(self.session.player.frame);
        head.raw(&[0; 8]);
        head.raw(&[0; 32]);
        output[..HEADER].copy_from_slice(&head.0);
        let hash = Sha256::digest(&output);
        output[96..128].copy_from_slice(&hash);
        Ok(output)
    }
}
/// Validates the container without constructing a second factory during save.
pub fn decode(bytes: &[u8]) -> Result<Snapshot> {
    ensure(
        (HEADER + TABLE..=MAX_BYTES).contains(&bytes.len()),
        "file size",
    )?;
    let mut hash = Sha256::new();
    hash.update(&bytes[..96]);
    hash.update([0; 32]);
    hash.update(&bytes[128..]);
    ensure(
        hash.finalize().as_slice() == &bytes[96..128],
        "file checksum",
    )?;
    let mut r = Reader::new(bytes);
    ensure(r.take(8)? == b"PFSAVE5\0", "magic")?;
    if r.u32()? != 5 {
        return Err(Error::Unsupported);
    }
    ensure(
        r.u32()? as usize == HEADER + TABLE && r.u32()? == 6 && r.u32()? == 0,
        "header",
    )?;
    ensure(r.u64()? == bytes.len() as u64, "file length")?;
    let world_id: [u8; 16] = r.array()?;
    let ruleset = match r.u32()? {
        0 => Ruleset::LegacyDiscreteV1,
        1 => Ruleset::ConveyorContinuousV1,
        _ => return Err(Error::Unsupported),
    };
    if r.u32()? != 1 {
        return Err(Error::Unsupported);
    }
    let tick = r.u64()?;
    let time = r.f64()?;
    let revision = r.u64()?;
    let frame = r.u64()?;
    ensure(
        time.is_finite() && time >= 0.0 && tick <= i64::MAX as u64,
        "clock",
    )?;
    ensure(r.take(8)? == [0; 8], "header reserved")?;
    r.take(32)?;
    let mut offset = HEADER + TABLE;
    let mut total = 0usize;
    let mut sections: [Vec<u8>; 6] = Default::default();
    for (index, section) in sections.iter_mut().enumerate() {
        ensure(
            r.u32()? == index as u32 + 1 && r.u32()? == 1 && r.u32()? == 1,
            "section schema",
        )?;
        let mode = r.u32()?;
        ensure(r.length(MAX_BYTES)? == offset, "section offset")?;
        let stored = r.length(MAX_BYTES)?;
        let raw = r.length(MAX_BYTES)?;
        ensure(r.u64()? == 1, "section count")?;
        let checksum: [u8; 32] = r.array()?;
        ensure(r.take(16)? == [0; 16], "reserved")?;
        total = total
            .checked_add(raw)
            .ok_or(Error::Invalid("raw overflow"))?;
        ensure(total <= MAX_BYTES, "raw budget")?;
        let end = offset
            .checked_add(stored)
            .ok_or(Error::Invalid("offset overflow"))?;
        let payload = bytes
            .get(offset..end)
            .ok_or(Error::Invalid("section length"))?;
        match mode {
            0 => {
                ensure(stored == raw, "raw length")?;
                section.extend_from_slice(payload);
            }
            1 => {
                let mut decoder = DeflateDecoder::new(payload);
                (&mut decoder).take(raw as u64 + 1).read_to_end(section)?;
                ensure(
                    section.len() == raw && decoder.total_in() == stored as u64,
                    "deflate length",
                )?;
            }
            _ => return Err(Error::Unsupported),
        }
        ensure(
            Sha256::digest(&*section).as_slice() == checksum,
            "section checksum",
        )?;
        offset = end;
    }
    ensure(offset == bytes.len(), "trailing data")?;
    let mut p = Reader::new(&sections[5]);
    let session = Session::read(&mut p)?;
    p.end()?;
    ensure(
        session.world_id == world_id && session.player.frame == frame,
        "session header",
    )?;
    Ok(Snapshot {
        session,
        ruleset,
        tick,
        time,
        revision,
        sections,
    })
}

#[derive(Default)]
pub(crate) struct Writer(pub Vec<u8>);
impl Writer {
    pub fn raw(&mut self, v: &[u8]) {
        self.0.extend_from_slice(v);
    }
    pub fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    pub fn bool(&mut self, v: bool) {
        self.u8(u8::from(v));
    }
    pub fn u32(&mut self, v: u32) {
        self.raw(&v.to_le_bytes());
    }
    pub fn i32(&mut self, v: i32) {
        self.raw(&v.to_le_bytes());
    }
    pub fn u64(&mut self, v: u64) {
        self.raw(&v.to_le_bytes());
    }
    pub fn i64(&mut self, v: i64) {
        self.raw(&v.to_le_bytes());
    }
    pub fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }
    pub fn bytes(&mut self, v: &[u8]) {
        self.u64(v.len() as u64);
        self.raw(v);
    }
    pub fn string(&mut self, v: &str) {
        self.bytes(v.as_bytes());
    }
    pub fn cell(&mut self, v: crate::world::Cell) {
        self.i32(v.x);
        self.i32(v.y);
        self.i32(v.z);
    }
}
pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    position: usize,
}
impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, position: 0 }
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self
            .position
            .checked_add(n)
            .ok_or(Error::Invalid("read overflow"))?;
        let value = self
            .bytes
            .get(self.position..end)
            .ok_or(Error::Invalid("truncated"))?;
        self.position = end;
        Ok(value)
    }
    pub fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().unwrap())
    }
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.array::<1>()?[0])
    }
    pub fn bool(&mut self) -> Result<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(Error::Invalid("boolean")),
        }
    }
    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.array()?))
    }
    pub fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.array()?))
    }
    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.array()?))
    }
    pub fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_le_bytes(self.array()?))
    }
    pub fn f64(&mut self) -> Result<f64> {
        Ok(f64::from_bits(self.u64()?))
    }
    pub fn length(&mut self, max: usize) -> Result<usize> {
        let length = usize::try_from(self.u64()?).map_err(|_| Error::Invalid("length"))?;
        ensure(length <= max, "length limit")?;
        Ok(length)
    }
    pub fn count(&mut self, max: usize, minimum_width: usize) -> Result<usize> {
        let n = self.length(max)?;
        ensure(
            n <= (self.bytes.len() - self.position) / minimum_width,
            "record count",
        )?;
        Ok(n)
    }
    pub fn bytes(&mut self, max: usize) -> Result<&'a [u8]> {
        let n = self.length(max)?;
        self.take(n)
    }
    pub fn string(&mut self, max: usize) -> Result<String> {
        String::from_utf8(self.bytes(max)?.to_vec()).map_err(|_| Error::Invalid("utf8"))
    }
    pub fn cell(&mut self) -> Result<crate::world::Cell> {
        Ok(crate::world::Cell::new(
            self.i32()?,
            self.i32()?,
            self.i32()?,
        ))
    }
    pub fn vec3(&mut self) -> Result<[f64; 3]> {
        Ok([self.f64()?, self.f64()?, self.f64()?])
    }
    pub fn end(&self) -> Result<()> {
        ensure(self.position == self.bytes.len(), "trailing fields")
    }
}
