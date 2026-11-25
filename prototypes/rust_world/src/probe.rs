use crate::audit::{Cache, Reference};
use factory_world_probe::{Bounds, Cell, ViewCursor, ViewReport, World};
use std::{
    hint::black_box,
    io::{self, Write},
    time::Instant,
};

#[derive(Default)]
struct Measurements {
    _samples: Vec<u128>,
    _totals: ViewReport,
}

impl Measurements {
    fn _record(&mut self, ns: u128, report: ViewReport) {
        self._samples.push(ns);
        self._totals.entered += report.entered;
        self._totals.updated += report.updated;
        self._totals.left += report.left;
        self._totals.visited_chunks += report.visited_chunks;
        self._totals.read_cells += report.read_cells;
        self._totals.output_bytes += report.output_bytes;
    }

    fn _json(&self) -> String {
        format!(
            "{{\"samples_ns\":{:?},{}}}",
            self._samples,
            report_fields(self._totals)
        )
    }
}

fn report_fields(report: ViewReport) -> String {
    format!(
        "\"entered\":{},\"updated\":{},\"left\":{},\"visited_chunks\":{},\"read_cells\":{},\"output_bytes\":{}",
        report.entered,
        report.updated,
        report.left,
        report.visited_chunks,
        report.read_cells,
        report.output_bytes
    )
}

fn bounds(x: i32) -> Bounds {
    Bounds {
        minimum: [x, 0, 0],
        maximum: [x + 32, 16, 32],
    }
}

pub fn run(
    mut world: World,
    load_ns: u128,
    seed: u32,
    warmup: usize,
    samples: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    let size = world.size();
    println!(
        "{{\"event\":\"loaded\",\"pid\":{},\"load_ns\":{load_ns},\"population\":{},\"revision\":{},\"size\":[{},{},{}]}}",
        std::process::id(),
        world.stats().non_empty,
        world.stats().revision,
        size.x,
        size.y,
        size.z
    );
    io::stdout().flush()?;
    let mut line = String::new();
    if io::stdin().read_line(&mut line)? == 0 || line.trim() != "continue" {
        return Err("expected continue handshake".into());
    }
    if size.x < 32 || size.z < 32 {
        return Err("probe fixture requires at least 32x16x32".into());
    }
    let mut reference = Reference::new(size, seed);
    reference.check_world(&world)?;
    println!("{{\"event\":\"audit\",\"stage\":\"loaded\"}}");
    let mut cache = Cache::default();
    let mut cursor = ViewCursor::new(&world);
    let mut output = Vec::new();
    let started = Instant::now();
    let first = black_box(world.update_view(bounds(0), &mut cursor, &mut output)?);
    let first_ns = started.elapsed().as_nanos();
    cache.apply(&output, bounds(0), &reference)?;
    if first.entered != 4 || first.read_cells != 16_384 {
        return Err("first view must return four chunks".into());
    }

    let mut unchanged = Measurements {
        _samples: Vec::with_capacity(samples),
        ..Measurements::default()
    };
    let mut packets = Vec::with_capacity(warmup + samples);
    for ordinal in 0..warmup + samples {
        let started = Instant::now();
        let report = black_box(world.update_view(bounds(0), &mut cursor, &mut output)?);
        let ns = started.elapsed().as_nanos();
        packets.push(output.clone());
        if report.read_cells != 0 || report.entered + report.updated + report.left != 0 {
            return Err("unchanged view sent chunk data".into());
        }
        if ordinal >= warmup {
            unchanged._record(ns, report);
        }
    }
    for packet in &packets {
        cache.apply(packet, bounds(0), &reference)?;
    }
    drop(packets);

    let mut edit = Measurements {
        _samples: Vec::with_capacity(samples),
        ..Measurements::default()
    };
    let mut records = Vec::with_capacity(samples);
    for ordinal in 0..samples {
        // Coprime stride gives unique positions inside the fixed observation volume.
        let index = ordinal as u32 * 13 % 16_384;
        let cell = Cell {
            x: index % 32,
            z: index / 32 % 32,
            y: index / 1024,
        };
        let started = Instant::now();
        let old = world.get_block(cell)?;
        let kind = if ordinal.is_multiple_of(3) {
            0
        } else {
            old % 4 + 1
        };
        if !world.set_block(cell, kind)? {
            return Err("edit unexpectedly unchanged".into());
        }
        let report = black_box(world.update_view(bounds(0), &mut cursor, &mut output)?);
        let ns = started.elapsed().as_nanos();
        records.push((cell, kind, output.clone()));
        edit._record(ns, report);
    }
    // Replay each edit before moving; re-entry cannot conceal a missed refresh.
    for (cell, kind, packet) in &records {
        reference.edit(*cell, *kind);
        cache.apply(packet, bounds(0), &reference)?;
    }
    reference.check_world(&world)?;
    drop(records);
    println!("{{\"event\":\"audit\",\"stage\":\"edited\"}}");

    let moving = if size
        == (Cell {
            x: 128,
            y: 64,
            z: 128,
        }) {
        let mut moving = Measurements {
            _samples: Vec::with_capacity(samples),
            ..Measurements::default()
        };
        let mut packets = Vec::with_capacity(warmup + samples);
        for ordinal in 0..warmup + samples {
            let phase = ((ordinal + 1) % 192) as i32;
            let x = if phase <= 96 { phase } else { 192 - phase };
            let started = Instant::now();
            let report = black_box(world.update_view(bounds(x), &mut cursor, &mut output)?);
            let ns = started.elapsed().as_nanos();
            packets.push((x, output.clone()));
            if ordinal >= warmup {
                moving._record(ns, report);
            }
        }
        for (x, packet) in &packets {
            cache.apply(packet, bounds(*x), &reference)?;
        }
        drop(packets);
        moving._json()
    } else {
        "null".into()
    };
    println!(
        "{{\"event\":\"complete\",\"audit\":true,\"first_ns\":{first_ns},\"first\":{{{}}},\"unchanged\":{},\"edit\":{{\"modifications\":{samples},{}}},\"moving\":{},\"revision\":{},\"counts\":{:?},\"population\":{}}}",
        report_fields(first),
        unchanged._json(),
        report_fields(edit._totals) + &format!(",\"samples_ns\":{:?}", edit._samples),
        moving,
        world.stats().revision,
        world.stats().counts,
        world.stats().non_empty
    );
    Ok(())
}
