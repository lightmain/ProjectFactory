//! Retained pure metadata, independent of the ordinary terminal receipt.
use super::{Error, Runtime};
use crate::persistence::store::{Directory, Entry};

pub(super) const MAX_DIRECTORY_ENTRIES: usize = 1024;
pub(super) const MAX_DIRECTORY_BYTES: usize = 2 * 1024 * 1024;
const MAX_PAGE_ENTRIES: usize = 64;
const MAX_PAGE_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DirectoryLimits {
    pub entry_count: usize,
    pub entry_bytes: usize,
}
impl Default for DirectoryLimits {
    fn default() -> Self {
        Self {
            entry_count: MAX_PAGE_ENTRIES,
            entry_bytes: MAX_PAGE_BYTES,
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct DirectoryPage {
    pub job_id: u64,
    pub directory_sequence: u64,
    pub entries: Vec<Entry>,
    pub entry_bytes: usize,
    pub next_offset: usize,
    pub total_entries: usize,
}
pub(super) struct DirectorySlot {
    pub job_id: u64,
    pub payload: Option<Directory>,
}
impl DirectorySlot {
    pub fn new(job_id: u64) -> Self {
        Self {
            job_id,
            payload: None,
        }
    }
}
// Fixed metadata plus every UTF-8 string returned to the host. This is the
// transport budget, not the compressed on-disk index size.
pub(super) fn entry_bytes(entry: &Entry) -> usize {
    96 + entry.id.len() + entry.payload.len() + entry.name.len() + entry.world_name.len()
}
pub(super) fn fits(directory: &Directory, count: usize, bytes: usize) -> bool {
    directory.entries.len() <= count
        && directory.entries.iter().map(entry_bytes).sum::<usize>() <= bytes
}
impl Runtime {
    /// Copy whole entries from retained memory; never scans disk or consumes a
    /// terminal. Identical identity/offset/budgets return identical pages.
    pub fn poll_directory(
        &self,
        epoch: u64,
        job_id: u64,
        offset: usize,
        limits: DirectoryLimits,
    ) -> Result<DirectoryPage, Error> {
        let mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if job_id == 0 || limits.entry_count == 0 || limits.entry_bytes == 0 {
            return Err(Error::InvalidArgument);
        }
        let slot = mailbox.directory.as_ref().ok_or(Error::InvalidArgument)?;
        if slot.job_id != job_id {
            return Err(Error::InvalidArgument);
        }
        let directory = slot.payload.as_ref().ok_or(Error::NotReady)?;
        if offset > directory.entries.len() {
            return Err(Error::InvalidArgument);
        }
        let mut entries = Vec::new();
        let mut bytes = 0;
        for entry in directory.entries[offset..]
            .iter()
            .take(limits.entry_count.min(MAX_PAGE_ENTRIES))
        {
            let size = entry_bytes(entry);
            if bytes + size > limits.entry_bytes.min(MAX_PAGE_BYTES) {
                if entries.is_empty() {
                    return Err(Error::InvalidArgument);
                }
                break;
            }
            entries.push(entry.clone());
            bytes += size;
        }
        Ok(DirectoryPage {
            job_id,
            directory_sequence: directory.sequence,
            next_offset: offset + entries.len(),
            total_entries: directory.entries.len(),
            entries,
            entry_bytes: bytes,
        })
    }

    /// Explicit payload receipt. An old receipt can never release a newer slot.
    pub fn ack_directory(&self, epoch: u64, job_id: u64) -> Result<(), Error> {
        let mut mailbox = self._shared.try_lock()?;
        if epoch != mailbox.epoch {
            return Err(Error::StaleEpoch);
        }
        if job_id == 0 {
            return Err(Error::InvalidArgument);
        }
        let Some(slot) = mailbox.directory.as_ref() else {
            return if job_id == mailbox.acknowledged_directory {
                Ok(())
            } else {
                Err(Error::InvalidArgument)
            };
        };
        if slot.job_id != job_id {
            return if job_id == mailbox.acknowledged_directory {
                Ok(())
            } else {
                Err(Error::InvalidArgument)
            };
        }
        if slot.payload.is_none() {
            return Err(Error::NotReady);
        }
        mailbox.directory = None;
        mailbox.acknowledged_directory = job_id;
        Ok(())
    }
}
