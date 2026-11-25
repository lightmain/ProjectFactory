use std::io::{Read, Write};
use std::rc::Rc;

use crate::world::{_chunk_dimensions, Chunk};
use crate::{CHUNK_VOLUME, Cell, World, WorldError};

const MAGIC: &[u8; 8] = b"FWRLD001";
const VERSION: u32 = 1;

impl World {
    /// Streams a snapshot; file callers are responsible for sync_all.
    pub fn save(&self, mut writer: impl Write) -> Result<(), WorldError> {
        writer.write_all(MAGIC)?;
        writer.write_all(&VERSION.to_le_bytes())?;
        for axis in [self._size.x, self._size.y, self._size.z] {
            writer.write_all(&axis.to_le_bytes())?;
        }
        writer.write_all(&self._revision.to_le_bytes())?;
        writer.write_all(&(self._chunks.len() as u32).to_le_bytes())?;
        let mut buffer = [0_u8; CHUNK_VOLUME * 2];
        for chunk in &self._chunks {
            for (bytes, value) in buffer
                .as_chunks_mut::<2>()
                .0
                .iter_mut()
                .zip(chunk._blocks.iter())
            {
                bytes.copy_from_slice(&value.to_le_bytes());
            }
            writer.write_all(&buffer)?;
        }
        writer.flush()?;
        Ok(())
    }

    /// Allocates final chunks only, decoding and counting in the same pass.
    pub fn load(mut reader: impl Read) -> Result<Self, WorldError> {
        let mut header = [0_u8; 36];
        reader.read_exact(&mut header)?;
        if &header[..8] != MAGIC || header[8..12] != VERSION.to_le_bytes() {
            return Err(WorldError::Format("magic or version"));
        }
        let read_u32 = |offset: usize| {
            u32::from_le_bytes(header[offset..offset + 4].try_into().expect("fixed header"))
        };
        let size = Cell {
            x: read_u32(12),
            y: read_u32(16),
            z: read_u32(20),
        };
        let dimensions = _chunk_dimensions(size)?;
        let count = (dimensions.x * dimensions.y * dimensions.z) as usize;
        if read_u32(32) as usize != count {
            return Err(WorldError::Format("chunk count"));
        }
        let revision = u64::from_le_bytes(header[24..32].try_into().expect("fixed header"));
        let mut chunks = Vec::with_capacity(count);
        let mut counts = [0_u64; 5];
        let mut buffer = [0_u8; CHUNK_VOLUME * 2];
        for _ in 0..count {
            reader.read_exact(&mut buffer)?;
            let mut chunk = Chunk::_empty();
            chunk._revision = revision;
            for (target, bytes) in chunk
                ._blocks
                .iter_mut()
                .zip(buffer.as_chunks::<2>().0.iter())
            {
                let value = u16::from_le_bytes([bytes[0], bytes[1]]);
                if value > 4 {
                    return Err(WorldError::Format("block kind"));
                }
                *target = value;
                counts[value as usize] += 1;
            }
            chunks.push(chunk);
        }
        let mut extra = [0_u8; 1];
        if reader.read(&mut extra)? != 0 {
            return Err(WorldError::Format("trailing data"));
        }
        Ok(Self {
            _size: size,
            _chunks: chunks,
            _counts: counts,
            _revision: revision,
            _identity: Rc::new(()),
        })
    }
}
