// Bounded conversions only. This object never owns the worker's live factory.
use factory_core::runtime::{self as rt, Command as RuntimeCommand};

fn runtime_error(error: rt::Error) -> VarDictionary {
    let code = match error {
        rt::Error::InvalidArgument => "invalid_argument",
        rt::Error::OutOfBounds => "out_of_bounds",
        rt::Error::InvalidSequence => "invalid_sequence",
        rt::Error::ConflictingReplay => "conflicting_replay",
        rt::Error::AlreadyFinalized => "already_finalized",
        rt::Error::StaleEpoch => "stale_epoch",
        rt::Error::InvalidAck => "invalid_ack",
        rt::Error::Busy => "busy",
        rt::Error::Closed => "closed",
        rt::Error::Faulted => "faulted",
        rt::Error::SpawnFailed => "spawn_failed",
        rt::Error::InvalidFrame => "invalid_frame",
        rt::Error::Paused => "paused",
        rt::Error::NotReady => "not_ready",
        rt::Error::NotPaused => "not_paused",
    };
    vdict! { "ok" => false, "error" => code }
}
fn runtime_integer(value: i64) -> Result<u64, rt::Error> {
    u64::try_from(value).map_err(|_| rt::Error::InvalidArgument)
}
fn runtime_size(value: i64) -> Result<usize, rt::Error> {
    usize::try_from(value).map_err(|_| rt::Error::InvalidArgument)
}
fn runtime_id(d: &VarDictionary, key: &str) -> Result<String, String> {
    let value: GString = input(d, key)?;
    if value.len() != 32 { return Err("invalid_save_id".into()); }
    let value = value.to_string();
    parse_id(&value).map_err(|_| "invalid_save_id")?;
    Ok(value)
}
fn runtime_save(d: &VarDictionary) -> Result<rt::Save, String> {
    let world_id = parse_id(&runtime_id(d, "world_id")?).map_err(|_| "invalid_world_id")?;
    let world_name: GString = input(d, "world_name")?;
    let name: GString = input(d, "name")?;
    let kind: GString = input(d, "save_kind")?;
    if world_name.len() > 320 || name.len() > 640 || kind.len() > 16 {
        return Err("invalid_save_metadata".into());
    }
    Ok(rt::Save {
        player: player_input(&input(d, "player")?)?,
        world_id, world_name: world_name.to_string(), autosave_minutes: input(d, "autosave_minutes")?,
        request: SaveRequest {
            name: name.to_string(), overwrite: input(d, "overwrite")?,
            kind: Kind::parse(&kind.to_string()).map_err(|_| "invalid_save_kind")?,
            retention: u32::try_from(input::<i64>(d, "retention")?).map_err(|_| "invalid_retention")?,
            expected_sequence: u64::try_from(input::<i64>(d, "sequence")?).map_err(|_| "invalid_sequence")?,
        },
    })
}
fn runtime_limits(options: &VarDictionary) -> Result<rt::Limits, String> {
    let mut limits = rt::Limits::default();
    let Some(value) = options.get("limits") else { return Ok(limits); };
    let values = value.try_to::<VarDictionary>().map_err(|_| "invalid_limits")?;
    for (name, target) in [
        ("input_bytes", &mut limits.input_bytes),
        ("directory_count", &mut limits.directory_count), ("directory_bytes", &mut limits.directory_bytes),
        ("candidate_bytes", &mut limits.candidate_bytes), ("query_bytes", &mut limits.query_bytes),
    ] {
        if values.contains_key(name) {
            *target = usize::try_from(input::<i64>(&values, name)?).map_err(|_| "invalid_limit")?;
        }
    }
    Ok(limits)
}
fn runtime_input(d: &VarDictionary) -> Result<rt::Input, String> {
    let seq = u64::try_from(input::<i64>(d, "request_id")?).map_err(|_| "invalid_sequence")?;
    let kind: GString = input(d, "kind")?;
    if kind.len() > 32 { return Err("invalid_command".into()); }
    let command = match kind.to_string().as_str() {
        "query_ray" | "query_build" | "query_route" => {
            let query_kind = match kind.to_string().as_str() {
                "query_ray" => {
                    let origin: Vector3 = input(d, "origin")?;
                    let ray: Vector3 = input(d, "ray")?;
                    rt::queries::QueryKind::Ray {
                        origin: [f64::from(origin.x), f64::from(origin.y), f64::from(origin.z)],
                        direction: [f64::from(ray.x), f64::from(ray.y), f64::from(ray.z)],
                        distance: input(d, "distance")?,
                    }
                }
                "query_build" => rt::queries::QueryKind::Build(runtime_build(d)?),
                _ => rt::queries::QueryKind::Route(runtime_route(d)?),
            };
            RuntimeCommand::Query(rt::queries::Query {
                query_id: u64::try_from(input::<i64>(d, "query_id")?).map_err(|_| "invalid_query_id")?,
                view_generation: u64::try_from(input::<i64>(d, "view_generation")?).map_err(|_| "invalid_generation")?,
                kind: query_kind,
            })
        }
        "build_route" => RuntimeCommand::BuildRoute(runtime_route(d)?),
        "cell" => RuntimeCommand::Cell(cell(input(d, "cell")?)),
        "remove" => RuntimeCommand::Remove(cell(input(d, "cell")?)),
        "direction" => RuntimeCommand::SetDirection(cell(input(d, "cell")?), direction(input(d, "direction")?)?),
        "pause" => RuntimeCommand::Pause,
        "resume" => RuntimeCommand::Resume,
        "save" => RuntimeCommand::Save(runtime_save(d)?),
        "list_directory" => RuntimeCommand::ListDirectory,
        "prepare_load" => RuntimeCommand::PrepareLoad(runtime_id(d, "save_id")?),
        "delete" => RuntimeCommand::Delete(runtime_id(d, "save_id")?,
            u64::try_from(input::<i64>(d, "sequence")?).map_err(|_| "invalid_sequence")?),
        "frame" => RuntimeCommand::Frame(rt::Frame {
            frame_seq: u64::try_from(input::<i64>(d, "frame_seq")?).map_err(|_| "invalid_frame")?,
            delta: input(d, "delta")?,
        }),
        "ready" => RuntimeCommand::PresentationReady {
            job_id: u64::try_from(input::<i64>(d, "job_id")?).map_err(|_| "invalid_job")?,
        },
        "switch" => RuntimeCommand::SwitchApplied {
            job_id: u64::try_from(input::<i64>(d, "job_id")?).map_err(|_| "invalid_job")?,
            next_epoch: u64::try_from(input::<i64>(d, "next_epoch")?).map_err(|_| "invalid_epoch")?,
        },
        "build" => RuntimeCommand::Build(runtime_build(d)?),
        _ => return Err("invalid_command".into()),
    };
    Ok(rt::Input { request_id: seq, command })
}
fn runtime_build(d: &VarDictionary) -> Result<Vec<(Cell, Block, Direction)>, String> {
    let cells: godot::builtin::AnyArray = input(d, "cells")?;
    let blocks: PackedInt32Array = input(d, "blocks")?;
    let directions: PackedInt32Array = input(d, "directions")?;
    if cells.is_empty() || cells.len() > 64 || cells.len() != blocks.len() || cells.len() != directions.len() {
        return Err("invalid_build".into());
    }
    let mut batch = Vec::with_capacity(cells.len());
    for (index, at) in cells.iter_shared().enumerate() {
        let at = at.try_to::<Vector3i>().map_err(|_| "invalid_cell")?;
        let block = u8::try_from(blocks[index]).map_err(|_| "invalid_block")?;
        batch.push((cell(at), Block::try_from(block).map_err(|_| "invalid_block")?,
            direction(i64::from(directions[index]))?));
    }
    Ok(batch)
}
fn runtime_route(d: &VarDictionary) -> Result<rt::queries::RouteRequest, String> {
    let targets: godot::builtin::AnyArray = input(d, "targets")?;
    let orders: PackedInt32Array = input(d, "orders")?;
    let max_cells = usize::try_from(input::<i64>(d, "max_cells")?).map_err(|_| "invalid_route_limit")?;
    if max_cells == 0 || max_cells > rt::queries::MAX_ROUTE_SEGMENTS
        || targets.is_empty() || targets.len() > rt::queries::MAX_ROUTE_TARGETS
        || orders.len() != targets.len() {
        return Err("invalid_route".into());
    }
    let mut route = Vec::with_capacity(targets.len());
    for (index, at) in targets.iter_shared().enumerate() {
        if orders[index] != 0 && orders[index] != 1 { return Err("invalid_route_order".into()); }
        route.push(rt::queries::RouteTarget {
            cell: cell(at.try_to::<Vector3i>().map_err(|_| "invalid_cell")?),
            north_south_first: orders[index] == 1,
        });
    }
    Ok(rt::queries::RouteRequest {
        start: cell(input(d, "start")?), direction: direction(input(d, "direction")?)?,
        max_cells, targets: route,
    })
}
fn runtime_factory_error(error: factory_core::factory::Error) -> &'static str {
    match error {
        factory_core::factory::Error::InvalidRequest => "invalid_request",
        factory_core::factory::Error::StalePreview => "stale_preview",
        factory_core::factory::Error::Legacy(_) => "legacy_rejected",
        factory_core::factory::Error::Continuous(_) => "continuous_rejected",
        factory_core::factory::Error::Route(_) => "route_rejected",
    }
}
fn runtime_query(page: rt::queries::QueryPage) -> VarDictionary {
    let mut value = vdict! {
        "ok" => true, "world_epoch" => page.world_epoch as i64,
        "request_id" => page.request_id as i64, "query_id" => page.query_id as i64,
        "view_generation" => page.view_generation as i64, "tick" => page.tick,
        "revision" => page.revision as i64, "payload_bytes" => page.payload_bytes as i64,
    };
    match page.payload {
        rt::queries::QueryPayload::Ray(hit) => {
            value.set("kind", "ray");
            value.set("found", hit.is_some());
            if let Some(hit) = hit {
                value.set("cell", vector(hit.hit.cell));
                value.set("normal", vector(hit.hit.normal));
                value.set("position", Vector3::new(hit.hit.position[0] as f32,
                    hit.hit.position[1] as f32, hit.hit.position[2] as f32));
                value.set("distance", hit.hit.distance);
                value.set("block", i64::from(hit.block as u8));
                value.set("direction", hit.direction.map(|d| i64::from(d as u8)).unwrap_or(-1));
                value.set("has_route_target", hit.route_target.is_some());
                if let Some(target) = hit.route_target { value.set("route_target", vector(target)); }
            }
        }
        rt::queries::QueryPayload::Preview(rows) => {
            value.set("kind", "preview");
            // Integer cell coordinates remain exact and use one contiguous array.
            let cells = PackedInt32Array::from_iter(rows.iter().flat_map(|s| [s.cell.x, s.cell.y, s.cell.z]));
            let blocks = PackedInt32Array::from_iter(rows.iter().map(|s| i32::from(s.block as u8)));
            let directions = PackedInt32Array::from_iter(rows.iter().map(|s| i32::from(s.direction as u8)));
            value.set("cells", &cells);
            value.set("blocks", &blocks);
            value.set("directions", &directions);
        }
    }
    value
}
fn runtime_result(r: rt::Completion) -> VarDictionary {
    let mut value = vdict! {
        "world_epoch" => r.world_epoch as i64, "request_id" => r.request_id as i64,
        "tick" => r.tick, "revision" => r.revision as i64,
    };
    let outcome = match r.outcome {
        rt::Outcome::Committed => "committed",
        rt::Outcome::QueryReady { query_id, view_generation, payload_bytes } => {
            value.set("query_id", query_id as i64);
            value.set("view_generation", view_generation as i64);
            value.set("payload_bytes", payload_bytes as i64);
            "query_ready"
        }
        rt::Outcome::QueryFailed { query_id, view_generation, error } => {
            value.set("query_id", query_id as i64);
            value.set("view_generation", view_generation as i64);
            value.set("error", runtime_factory_error(error));
            "query_failed"
        }
        rt::Outcome::Cell(block) => { value.set("block", i64::from(block as u8)); "cell" }
        rt::Outcome::Rejected(error) => {
            value.set("error", runtime_factory_error(error));
            "rejected"
        }
        rt::Outcome::Faulted => "faulted",
        rt::Outcome::FrameCompleted { frame_seq } => { value.set("frame_seq", frame_seq as i64); "frame_completed" }
        rt::Outcome::Paused(paused) => { value.set("paused", paused); "paused" }
        rt::Outcome::SaveStarted { job_id } => {
            value.set("job_id", job_id as i64);
            "save_started"
        }
        rt::Outcome::SaveCompleted { job_id, frame_seq, save_id, directory_sequence } => {
            value.set("job_id", job_id as i64);
            value.set("frame_seq", frame_seq as i64);
            value.set("save_id", hex(&save_id).as_str());
            value.set("directory_sequence", directory_sequence as i64);
            "save_completed"
        }
        rt::Outcome::SaveFailed { job_id, frame_seq, error } => {
            value.set("job_id", job_id as i64);
            value.set("frame_seq", frame_seq as i64);
            value.set("error", runtime_save_error(error));
            "save_failed"
        }
        rt::Outcome::DeleteCompleted { job_id, save_id, directory_sequence } => {
            value.set("job_id", job_id as i64);
            value.set("save_id", hex(&save_id).as_str());
            value.set("directory_sequence", directory_sequence as i64);
            "delete_completed"
        }
        rt::Outcome::DeleteFailed { job_id, error } => {
            value.set("job_id", job_id as i64);
            value.set("error", runtime_save_error(error));
            "delete_failed"
        }
        rt::Outcome::DirectoryReady { job_id, directory_sequence, entry_count } => {
            value.set("job_id", job_id as i64);
            value.set("directory_sequence", directory_sequence as i64);
            value.set("entry_count", entry_count as i64);
            "directory_ready"
        }
        rt::Outcome::DirectoryFailed { job_id, error } => {
            value.set("job_id", job_id as i64);
            value.set("error", runtime_save_error(error));
            "directory_failed"
        }
        rt::Outcome::LoadPrepared { job_id } => {
            value.set("job_id", job_id as i64);
            "load_prepared"
        }
        rt::Outcome::LoadFailed { job_id, error } => {
            value.set("job_id", job_id as i64);
            value.set("error", runtime_save_error(error));
            "load_failed"
        }
        rt::Outcome::CommitDecided { job_id, next_epoch } => {
            value.set("job_id", job_id as i64);
            value.set("next_epoch", next_epoch as i64);
            "commit_decided"
        }
        rt::Outcome::LoadCompleted { job_id, next_epoch } => {
            value.set("job_id", job_id as i64);
            value.set("next_epoch", next_epoch as i64);
            "load_completed"
        }
    };
    value.set("outcome", outcome);
    value
}
fn runtime_save_error(error: rt::SaveError) -> &'static str {
    match error {
        rt::SaveError::Invalid => "invalid",
        rt::SaveError::Disk => "disk",
        rt::SaveError::Busy => "busy",
        rt::SaveError::StaleDirectory => "stale_directory",
        rt::SaveError::Cancelled => "cancelled",
        rt::SaveError::CommitUncertain => "commit_uncertain",
        rt::SaveError::Failed => "failed",
    }
}
fn runtime_page(p: rt::Page) -> VarDictionary {
    let results = Array::<VarDictionary>::from_iter(p.results.into_iter().map(runtime_result));
    let t = p.timing;
    let timing = vdict! {
        "time" => t.clock.time, "compensation" => t.clock.compensation,
        "tick" => t.clock.tick, "flushed" => t.clock.flushed, "revision" => t.revision as i64,
        "completed_frame" => t.completed_frame as i64, "paused" => t.paused,
        "last_advance_seconds" => t.last_advance_seconds, "max_advance_seconds" => t.max_advance_seconds,
        "last_advance_ticks" => t.last_advance_ticks,
    };
    vdict! {
        "ok" => true, "world_epoch" => p.world_epoch as i64,
        "status" => match p.status { rt::Status::Starting => "starting", rt::Status::Running => "running", rt::Status::Faulted => "faulted" },
        "results" => &results, "result_bytes" => p.result_bytes as i64,
        "timing" => &timing,
    }
}
#[godot_api(secondary)]
impl FactoryBackend {
    #[func]
    fn open_runtime(&mut self, options: VarDictionary) -> VarDictionary {
        if !self.backend.is_open() { return save_error("backend_closed"); }
        if self.factory.is_some() || self.persistence.is_some() || self.candidate.is_some()
            || self.runtime.as_ref().is_some_and(|r| !r.is_stopped()) {
            return save_error("runtime_busy");
        }
        let parsed = (|| -> Result<_, String> {
            let ruleset: GString = input(&options, "ruleset")?;
            if ruleset.len() > 32 { return Err("invalid_ruleset".into()); }
            let ruleset = Ruleset::parse(&ruleset.to_string()).map_err(|_| "invalid_ruleset")?;
            let epoch = u64::try_from(input::<i64>(&options, "epoch")?).map_err(|_| "invalid_epoch")?;
            let bounds = Bounds::new(cell(input(&options, "minimum")?), cell(input(&options, "maximum")?),
                i32::try_from(input::<i64>(&options, "floor_depth")?).map_err(|_| "invalid_floor_depth")?)
                .map_err(|_| "invalid_bounds")?;
            let settings = Settings { interval: input(&options, "interval")?, amount: input(&options, "amount")? };
            let root = if options.contains_key("save_root") {
                let value: GString = input(&options, "save_root")?;
                if value.len() > 4096 { return Err("invalid_save_root".into()); }
                Some(std::path::PathBuf::from(value.to_string()))
            } else { None };
            Ok((ruleset, epoch, bounds, settings, runtime_limits(&options)?, root))
        })();
        let (ruleset, epoch, bounds, settings, limits, root) = match parsed {
            Ok(values) => values, Err(error) => return save_error(error),
        };
        let result = match root {
            Some(root) => rt::Runtime::open_with_persistence(bounds, settings, ruleset, epoch, limits, root),
            None => rt::Runtime::open(bounds, settings, ruleset, epoch, limits),
        };
        match result {
            Ok(runtime) => { self.runtime = Some(runtime); vdict! { "ok" => true } }
            Err(error) => runtime_error(error),
        }
    }
    #[func]
    fn submit_runtime(&self, epoch: i64, command: VarDictionary) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let epoch = match runtime_integer(epoch) { Ok(epoch) => epoch, Err(e) => return runtime_error(e) };
        let request = match runtime_input(&command) {
            Ok(request) => request, Err(error) => return save_error(error),
        };
        match runtime.submit(epoch, &request) {
            Ok(()) => vdict! { "ok" => true }, Err(error) => runtime_error(error),
        }
    }
    #[func]
    fn poll_runtime(&self, bytes: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| {
            runtime.poll_updates(rt::PollLimits {
                result_bytes: runtime_size(bytes)?,
            })
        })();
        match result { Ok(page) => runtime_page(page), Err(error) => runtime_error(error) }
    }
    #[func]
    fn poll_query_runtime(&self, epoch: i64, request_id: i64, query_id: i64, bytes: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.poll_query(runtime_integer(epoch)?, runtime_integer(request_id)?,
            runtime_integer(query_id)?, runtime_size(bytes)?))();
        match result { Ok(page) => runtime_query(page), Err(error) => runtime_error(error) }
    }
    #[func]
    fn cancel_runtime(&self, epoch: i64, job_id: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.cancel(runtime_integer(epoch)?, runtime_integer(job_id)?))();
        match result { Ok(cancelled) => vdict! { "ok" => true, "cancelled" => cancelled }, Err(error) => runtime_error(error) }
    }
    #[func]
    fn poll_directory_runtime(&self, epoch: i64, job_id: i64, offset: i64, count: i64, bytes: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.poll_directory(runtime_integer(epoch)?, runtime_integer(job_id)?,
            runtime_size(offset)?, rt::DirectoryLimits {
                entry_count: runtime_size(count)?, entry_bytes: runtime_size(bytes)?,
            }))();
        match result {
            Ok(page) => {
                let entries = Array::<VarDictionary>::from_iter(page.entries.iter().map(entry_dictionary));
                vdict! { "ok" => true, "job_id" => page.job_id as i64,
                    "directory_sequence" => page.directory_sequence as i64, "entries" => &entries,
                    "entry_bytes" => page.entry_bytes as i64, "next_offset" => page.next_offset as i64,
                    "total_entries" => page.total_entries as i64 }
            }
            Err(error) => runtime_error(error),
        }
    }
    #[func]
    fn ack_directory_runtime(&self, epoch: i64, job_id: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.ack_directory(runtime_integer(epoch)?, runtime_integer(job_id)?))();
        match result { Ok(()) => vdict! { "ok" => true }, Err(error) => runtime_error(error) }
    }
    #[func]
    fn poll_candidate_runtime(&self, epoch: i64, job_id: i64, bytes: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.poll_candidate(runtime_integer(epoch)?, runtime_integer(job_id)?, runtime_size(bytes)?))();
        match result {
            Ok(info) => vdict! { "ok" => true, "job_id" => info.job_id as i64,
                "session" => &session_dictionary(&info.session), "ruleset" => info.ruleset.name(),
                "time" => info.clock.time, "compensation" => info.clock.compensation,
                "tick" => info.clock.tick, "flushed" => info.clock.flushed, "revision" => info.revision as i64,
                "minimum" => vector(info.bounds.minimum()), "maximum" => vector(info.bounds.maximum()),
                "floor_depth" => i64::from(info.bounds.floor_depth()), "candidate_bytes" => info.bytes as i64 },
            Err(error) => runtime_error(error),
        }
    }
    #[func]
    fn close_runtime(&self) -> VarDictionary {
        if let Some(runtime) = &self.runtime { runtime.close(); }
        vdict! { "ok" => true }
    }
    #[func]
    fn runtime_stopped(&self) -> VarDictionary {
        vdict! { "ok" => true, "stopped" => self.runtime.as_ref().is_none_or(rt::Runtime::is_stopped) }
    }
}
