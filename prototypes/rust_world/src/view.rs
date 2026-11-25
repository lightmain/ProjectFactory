use std::rc::Rc;

use crate::{CHUNK_EDGE, CHUNK_VOLUME, World, WorldError};

#[derive(Clone, Copy, Debug)]
pub struct Bounds {
    pub minimum: [i32; 3],
    pub maximum: [i32; 3],
}

pub struct ViewCursor {
    _identity: Rc<()>,
    _visible: Vec<(usize, u64)>,
    _next: Vec<(usize, u64)>,
}

impl ViewCursor {
    pub fn new(world: &World) -> Self {
        Self {
            _identity: Rc::clone(&world._identity),
            _visible: Vec::new(),
            _next: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ViewReport {
    pub entered: usize,
    pub updated: usize,
    pub left: usize,
    pub visited_chunks: usize,
    pub read_cells: usize,
    pub output_bytes: usize,
}

impl World {
    /// Packet: magic[8], revision:u64, counts:[u64;5], non_empty:u64,
    /// enter/update/leave counts:u32; entered then updated (id:u32, cells:u16),
    /// then left ids:u32. All fields little endian. Every packet includes stats.
    pub fn update_view(
        &self,
        bounds: Bounds,
        cursor: &mut ViewCursor,
        output: &mut Vec<u8>,
    ) -> Result<ViewReport, WorldError> {
        if !Rc::ptr_eq(&self._identity, &cursor._identity) {
            return Err(WorldError::WrongWorld);
        }
        if (0..3).any(|axis| bounds.minimum[axis] > bounds.maximum[axis]) {
            return Err(WorldError::InvalidBounds);
        }
        let size = [self._size.x, self._size.y, self._size.z];
        let mut start = [0_u32; 3];
        let mut end = [0_u32; 3];
        let mut empty = false;
        for axis in 0..3 {
            let low = bounds.minimum[axis].clamp(0, size[axis] as i32) as u32;
            let high = bounds.maximum[axis].clamp(0, size[axis] as i32) as u32;
            empty |= low == high;
            start[axis] = low / CHUNK_EDGE;
            end[axis] = high.div_ceil(CHUNK_EDGE);
        }
        cursor._next.clear();
        if !empty {
            let chunks_x = self._size.x / CHUNK_EDGE;
            let chunks_z = self._size.z / CHUNK_EDGE;
            for y in start[1]..end[1] {
                for z in start[2]..end[2] {
                    for x in start[0]..end[0] {
                        let id = (x + chunks_x * (z + chunks_z * y)) as usize;
                        cursor._next.push((id, self._chunks[id]._revision));
                    }
                }
            }
        }
        output.clear();
        output.extend_from_slice(b"FVIEW001");
        output.extend_from_slice(&self._revision.to_le_bytes());
        for count in self._counts {
            output.extend_from_slice(&count.to_le_bytes());
        }
        output.extend_from_slice(&self.stats().non_empty.to_le_bytes());
        output.extend_from_slice(&[0_u8; 12]);
        let mut report = ViewReport {
            visited_chunks: cursor._next.len(),
            ..ViewReport::default()
        };
        // Two passes over only visible chunks keep packet sections deterministic.
        for entering in [true, false] {
            for &(id, revision) in &cursor._next {
                let previous = cursor._visible.binary_search_by_key(&id, |&(key, _)| key);
                let emit = match previous {
                    Err(_) => entering,
                    Ok(index) => !entering && cursor._visible[index].1 != revision,
                };
                if emit {
                    output.extend_from_slice(&(id as u32).to_le_bytes());
                    for value in self._chunks[id]._blocks.iter() {
                        output.extend_from_slice(&value.to_le_bytes());
                    }
                    if entering {
                        report.entered += 1;
                    } else {
                        report.updated += 1;
                    }
                }
            }
        }
        for &(id, _) in &cursor._visible {
            if cursor
                ._next
                .binary_search_by_key(&id, |&(key, _)| key)
                .is_err()
            {
                output.extend_from_slice(&(id as u32).to_le_bytes());
                report.left += 1;
            }
        }
        for (offset, count) in [
            (64, report.entered),
            (68, report.updated),
            (72, report.left),
        ] {
            output[offset..offset + 4].copy_from_slice(&(count as u32).to_le_bytes());
        }
        std::mem::swap(&mut cursor._visible, &mut cursor._next);
        report.read_cells = (report.entered + report.updated) * CHUNK_VOLUME;
        report.output_bytes = output.len();
        Ok(report)
    }
}
