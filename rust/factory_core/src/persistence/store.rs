//! Immutable payloads and two checked indexes. The index rename is the commit.
use super::{Error, MAX_BYTES, Reader, Result, Snapshot, Writer, decode, ensure};
use crate::factory::Ruleset;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_INDEX: usize = 1024 * 1024;
const MAX_ENTRIES: usize = 1024;
static IDENTITIES: AtomicU64 = AtomicU64::new(0);
pub fn new_id() -> String {
    let mut hash = Sha256::new();
    hash.update(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .to_le_bytes(),
    );
    hash.update(std::process::id().to_le_bytes());
    hash.update(IDENTITIES.fetch_add(1, Ordering::Relaxed).to_le_bytes());
    hex(&hash.finalize()[..16])
}
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn parse_id(value: &str) -> Result<[u8; 16]> {
    ensure(
        value.len() == 32
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "save id",
    )?;
    let mut bytes = [0; 16];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[i * 2..i * 2 + 2], 16)
            .map_err(|_| Error::Invalid("save id"))?;
    }
    Ok(bytes)
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Manual,
    Auto,
    Exit,
}
impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Auto => "auto",
            Self::Exit => "exit",
        }
    }
    pub fn parse(v: &str) -> Result<Self> {
        match v {
            "manual" => Ok(Self::Manual),
            "auto" => Ok(Self::Auto),
            "exit" => Ok(Self::Exit),
            _ => Err(Error::Invalid("save kind")),
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub id: String,
    pub payload: String,
    pub name: String,
    pub world_id: [u8; 16],
    pub world_name: String,
    pub ruleset: Ruleset,
    pub saved_at: f64,
    pub kind: Kind,
}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Directory {
    pub sequence: u64,
    pub entries: Vec<Entry>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct SaveRequest {
    pub name: String,
    pub overwrite: bool,
    pub kind: Kind,
    pub retention: u32,
    pub expected_sequence: u64,
}
impl SaveRequest {
    pub fn validate(&self) -> Result<()> {
        ensure(
            !self.name.trim().is_empty()
                && self.name.len() <= 640
                && self.name.chars().count() <= 160
                && (1..=100).contains(&self.retention),
            "save request",
        )
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    BeforeIndexRename,
    AfterIndexRename,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum IndexFingerprint {
    Missing,
    Valid([u8; 32]),
    Invalid,
}
pub struct Store {
    root: PathBuf,
    uncertain: bool,
    fault: Option<Fault>,
    verified: Option<Directory>,
    fingerprints: [IndexFingerprint; 2],
}

pub fn read_file(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    ensure(
        metadata.is_file() && metadata.len() <= limit as u64,
        "file type/length",
    )?;
    let mut bytes = Vec::new();
    File::open(path)?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure(bytes.len() <= limit, "file budget")?;
    Ok(bytes)
}
fn sync_directory(root: &Path) -> Result<()> {
    File::open(root)?.sync_all()?;
    Ok(())
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
impl Store {
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root)?;
        ensure(fs::symlink_metadata(&root)?.is_dir(), "save root")?;
        let mut store = Self {
            root,
            uncertain: false,
            fault: None,
            verified: None,
            fingerprints: [IndexFingerprint::Missing; 2],
        };
        let _lock = store.lock()?;
        store.current()?;
        Ok(store)
    }
    pub fn inject_fault(&mut self, fault: Option<Fault>) {
        self.fault = fault;
    }
    fn lock(&self) -> Result<File> {
        let path = self.root.join("directory.lock");
        if let Ok(metadata) = fs::symlink_metadata(&path) {
            ensure(metadata.is_file(), "directory lock")?;
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        match file.try_lock() {
            Ok(()) => Ok(file),
            Err(fs::TryLockError::WouldBlock) => Err(Error::Busy),
            Err(fs::TryLockError::Error(e)) => Err(e.into()),
        }
    }
    fn read_index(&self, slot: usize, validate_payload: bool) -> Result<Directory> {
        let bytes = read_file(&self.root.join(format!("index_{slot}.bin")), MAX_INDEX)?;
        ensure(
            bytes.len() >= 56 && &bytes[..8] == b"PFINDEX5",
            "index magic",
        )?;
        ensure(
            Sha256::digest(&bytes[..bytes.len() - 32]).as_slice() == &bytes[bytes.len() - 32..],
            "index checksum",
        )?;
        let mut r = Reader::new(&bytes[..bytes.len() - 32]);
        r.take(8)?;
        ensure(r.u32()? == 1 && r.u32()? == 0, "index schema")?;
        let sequence = r.u64()?;
        ensure(
            sequence > 0 && sequence <= i64::MAX as u64 && sequence as usize % 2 == slot,
            "index sequence",
        )?;
        let count = r.count(MAX_ENTRIES, 74)?;
        let mut entries = Vec::with_capacity(count);
        let mut ids = BTreeSet::new();
        let mut payloads = BTreeSet::new();
        for _ in 0..count {
            let id = hex(&r.array::<16>()?);
            let payload = hex(&r.array::<16>()?);
            let world_id = r.array()?;
            let name = r.string(640)?;
            let world_name = r.string(320)?;
            let ruleset = match r.u8()? {
                0 => Ruleset::LegacyDiscreteV1,
                1 => Ruleset::ConveyorContinuousV1,
                _ => return Err(Error::Unsupported),
            };
            let saved_at = r.f64()?;
            let kind = match r.u8()? {
                0 => Kind::Manual,
                1 => Kind::Auto,
                2 => Kind::Exit,
                _ => return Err(Error::Invalid("index kind")),
            };
            ensure(
                ids.insert(id.clone())
                    && payloads.insert(payload.clone())
                    && world_id != [0; 16]
                    && !name.trim().is_empty()
                    && name.chars().count() <= 160
                    && !world_name.trim().is_empty()
                    && world_name.chars().count() <= 80
                    && saved_at.is_finite()
                    && saved_at >= 0.0,
                "index entry",
            )?;
            let path = self.root.join(format!("{payload}.pfs"));
            let metadata = fs::symlink_metadata(&path)?;
            ensure(
                metadata.is_file() && metadata.len() <= MAX_BYTES as u64,
                "indexed payload",
            )?;
            if validate_payload {
                let checkpoint = decode(&read_file(&path, MAX_BYTES)?)?;
                ensure(
                    checkpoint.session.world_id == world_id
                        && checkpoint.session.world_name == world_name
                        && checkpoint.ruleset == ruleset,
                    "payload metadata",
                )?;
            }
            entries.push(Entry {
                id,
                payload,
                name,
                world_id,
                world_name,
                ruleset,
                saved_at,
                kind,
            });
        }
        r.end()?;
        entries.sort_by(|a, b| {
            b.saved_at
                .total_cmp(&a.saved_at)
                .then_with(|| b.id.cmp(&a.id))
        });
        Ok(Directory { sequence, entries })
    }
    fn recover(&self, validate_payload: bool) -> Result<Directory> {
        let mut valid = Vec::new();
        let mut exists = false;
        for slot in 0..2 {
            if self.root.join(format!("index_{slot}.bin")).try_exists()? {
                exists = true;
                if let Ok(index) = self.read_index(slot, validate_payload) {
                    valid.push(index);
                }
            }
        }
        if valid.is_empty() {
            ensure(!exists, "no valid directory index")?;
            return Ok(Directory::default());
        }
        Ok(valid.into_iter().max_by_key(|d| d.sequence).unwrap())
    }
    fn current(&mut self) -> Result<Directory> {
        let mut fingerprints = [IndexFingerprint::Missing; 2];
        for (slot, fingerprint) in fingerprints.iter_mut().enumerate() {
            let path = self.root.join(format!("index_{slot}.bin"));
            if path.try_exists()? {
                *fingerprint = match read_file(&path, MAX_INDEX) {
                    Ok(bytes) => IndexFingerprint::Valid(Sha256::digest(bytes).into()),
                    Err(_) => IndexFingerprint::Invalid,
                };
            }
        }
        if self.verified.is_none() || fingerprints != self.fingerprints {
            let verified = self.recover(true)?;
            // A new visible index from another instance is unconfirmed until
            // it has been checked and its directory successfully re-synced.
            sync_directory(&self.root)?;
            self.verified = Some(verified);
            self.fingerprints = fingerprints;
        }
        Ok(self.verified.as_ref().unwrap().clone())
    }
    pub fn list(&mut self) -> Result<Directory> {
        let _lock = self.lock()?;
        self.current()
    }
    pub fn load(&mut self, id: &str) -> Result<Snapshot> {
        parse_id(id)?;
        let _lock = self.lock()?;
        let directory = self.current()?;
        let entry = directory
            .entries
            .iter()
            .find(|e| e.id == id)
            .ok_or(Error::Invalid("save missing"))?;
        let snapshot = decode(&read_file(
            &self.root.join(format!("{}.pfs", entry.payload)),
            MAX_BYTES,
        )?)?;
        ensure(
            snapshot.session.world_id == entry.world_id
                && snapshot.ruleset == entry.ruleset
                && snapshot.session.world_name == entry.world_name,
            "entry metadata",
        )?;
        Ok(snapshot)
    }
    fn mutation(&self) -> Result<()> {
        if self.uncertain {
            Err(Error::CommitUncertain)
        } else {
            Ok(())
        }
    }
    fn commit(
        &mut self,
        directory: &Directory,
        progress: &mut dyn FnMut(&str) -> Result<()>,
    ) -> Result<()> {
        let mut w = Writer::default();
        w.raw(b"PFINDEX5");
        w.u32(1);
        w.u32(0);
        w.u64(directory.sequence);
        w.u64(directory.entries.len() as u64);
        for e in &directory.entries {
            w.raw(&parse_id(&e.id)?);
            w.raw(&parse_id(&e.payload)?);
            w.raw(&e.world_id);
            w.string(&e.name);
            w.string(&e.world_name);
            w.u8(if e.ruleset == Ruleset::LegacyDiscreteV1 {
                0
            } else {
                1
            });
            w.f64(e.saved_at);
            w.u8(match e.kind {
                Kind::Manual => 0,
                Kind::Auto => 1,
                Kind::Exit => 2,
            });
        }
        let hash = Sha256::digest(&w.0);
        w.raw(&hash);
        ensure(w.0.len() <= MAX_INDEX, "index budget")?;
        let temporary = self.root.join(format!("{}.tmp", new_id()));
        write_new(&temporary, &w.0)?;
        let result = (|| {
            progress("Committing")?;
            if self.fault == Some(Fault::BeforeIndexRename) {
                return Err(Error::Io("injected before commit".into()));
            }
            fs::rename(
                &temporary,
                self.root
                    .join(format!("index_{}.bin", directory.sequence % 2)),
            )?;
            if self.fault == Some(Fault::AfterIndexRename) || sync_directory(&self.root).is_err() {
                self.uncertain = true;
                return Err(Error::CommitUncertain);
            }
            Ok(())
        })();
        if temporary.exists() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
    pub fn save(
        &mut self,
        snapshot: Snapshot,
        request: SaveRequest,
        progress: &mut dyn FnMut(&str) -> Result<()>,
    ) -> Result<Entry> {
        self.mutation()?;
        request.validate()?;
        let _lock = self.lock()?;
        let mut directory = self.current()?;
        if directory.sequence != request.expected_sequence {
            return Err(Error::StaleDirectory);
        }
        let prior = directory
            .entries
            .iter()
            .find(|e| e.world_id == snapshot.session.world_id && e.name == request.name)
            .cloned();
        if prior.is_some() && !request.overwrite {
            return Err(Error::Invalid("overwrite confirmation required"));
        }
        ensure(
            prior.is_some() || directory.entries.len() < MAX_ENTRIES,
            "directory full",
        )?;
        progress("Encoding")?;
        let bytes = snapshot.encode()?;
        let payload = new_id();
        let temporary = self.root.join(format!("{payload}.tmp"));
        let path = self.root.join(format!("{payload}.pfs"));
        let entry = Entry {
            id: prior.as_ref().map_or_else(new_id, |e| e.id.clone()),
            payload,
            name: request.name,
            world_id: snapshot.session.world_id,
            world_name: snapshot.session.world_name,
            ruleset: snapshot.ruleset,
            saved_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| Error::Invalid("system clock"))?
                .as_secs_f64(),
            kind: request.kind,
        };
        let result = (|| {
            progress("Writing")?;
            write_new(&temporary, &bytes)?;
            progress("Verifying")?;
            decode(&read_file(&temporary, MAX_BYTES)?)?;
            fs::rename(&temporary, &path)?;
            sync_directory(&self.root)?;
            directory.entries.retain(|e| e.id != entry.id);
            directory.entries.insert(0, entry.clone());
            if request.kind == Kind::Auto {
                let mut retained = 0;
                directory.entries.retain(|e| {
                    if e.world_id == entry.world_id && e.kind == Kind::Auto {
                        retained += 1;
                        retained <= request.retention
                    } else {
                        true
                    }
                });
            }
            directory.sequence = directory
                .sequence
                .checked_add(1)
                .ok_or(Error::Invalid("sequence exhausted"))?;
            self.commit(&directory, progress)
        })();
        if temporary.exists() {
            let _ = fs::remove_file(temporary);
        }
        // Failed commits leave immutable orphans; recovery never promotes them.
        result?;
        self.collect_garbage();
        Ok(entry)
    }
    pub fn delete(&mut self, id: &str, expected_sequence: u64) -> Result<()> {
        self.mutation()?;
        parse_id(id)?;
        let _lock = self.lock()?;
        let mut directory = self.current()?;
        if directory.sequence != expected_sequence {
            return Err(Error::StaleDirectory);
        }
        ensure(directory.entries.iter().any(|e| e.id == id), "save missing")?;
        directory.entries.retain(|e| e.id != id);
        directory.sequence = directory
            .sequence
            .checked_add(1)
            .ok_or(Error::Invalid("sequence exhausted"))?;
        self.commit(&directory, &mut |_| Ok(()))?;
        self.collect_garbage();
        Ok(())
    }
    fn collect_garbage(&self) {
        let mut referenced = BTreeSet::new();
        for slot in 0..2 {
            if let Ok(index) = self.read_index(slot, false) {
                referenced.extend(
                    index
                        .entries
                        .into_iter()
                        .map(|e| format!("{}.pfs", e.payload)),
                );
            }
        }
        if let Ok(files) = fs::read_dir(&self.root) {
            for file in files.flatten() {
                let name = file.file_name().to_string_lossy().into_owned();
                if let Some(id) = name.strip_suffix(".pfs")
                    && parse_id(id).is_ok()
                    && !referenced.contains(&name)
                {
                    let _ = fs::remove_file(file.path());
                }
            }
        }
    }
}
