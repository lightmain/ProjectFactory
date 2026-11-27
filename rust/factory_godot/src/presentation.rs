// Engine arrays are created only in the calling Godot thread, after core preflight.
use factory_core::runtime::presentation as pres;

fn presentation_info(info: pres::Info) -> VarDictionary {
    vdict! {
        "ok" => true, "world_epoch" => info.world_epoch as i64,
        "view_generation" => info.generation as i64, "job_id" => info.job_id as i64,
        "snapshot_id" => info.snapshot_id as i64, "revision" => info.revision as i64,
        "tick" => info.tick, "total_pages" => info.total_pages as i64,
        "total_bytes" => info.total_bytes as i64,
        "stage" => match info.stage { pres::Stage::Building => "building", pres::Stage::Ready => "ready", pres::Stage::Aborted => "aborted" },
        "error" => match info.failure { None => "", Some(pres::Failure::Budget) => "budget", Some(pres::Failure::Expired) => "expired", Some(pres::Failure::Geometry) => "geometry" },
    }
}

fn presentation_page(page: pres::Page) -> VarDictionary {
    let mesh = page.mesh;
    let v3 = |v: [f32; 3]| Vector3::new(v[0], v[1], v[2]);
    let keys = PackedInt32Array::from_iter(page.keys.iter().flat_map(|key| [key.x, key.y, key.z]));
    let positions = PackedVector3Array::from_iter(mesh.positions.into_iter().map(v3));
    let normals = PackedVector3Array::from_iter(mesh.normals.into_iter().map(v3));
    let colors = PackedColorArray::from_iter(mesh.colors.into_iter().map(|c| Color::from_rgba(c[0], c[1], c[2], c[3])));
    let uv = PackedVector2Array::from_iter(mesh.uv.into_iter().map(|v| Vector2::new(v[0], v[1])));
    let custom = PackedFloat32Array::from_iter(mesh.custom.into_iter().flatten());
    let indices = PackedInt32Array::from_iter(mesh.indices.into_iter().map(|v| v as i32));
    let collision = PackedVector3Array::from_iter(mesh.collision.into_iter().map(v3));
    vdict! {
        "ok" => true, "world_epoch" => page.world_epoch as i64,
        "view_generation" => page.generation as i64, "job_id" => page.job_id as i64,
        "snapshot_id" => page.snapshot_id as i64, "revision" => page.revision as i64,
        "world_revision" => mesh.world_revision as i64, "tick" => page.tick,
        "page_index" => page.page_index as i64, "total_pages" => page.total_pages as i64,
        "keys" => &keys, "key" => vector(page.key), "chunk_page" => page.chunk_page as i64,
        "chunk_pages" => page.chunk_pages as i64, "page_bytes" => page.bytes as i64,
        "origin" => v3(mesh.origin), "bounds_min" => v3(mesh.bounds_min), "bounds_max" => v3(mesh.bounds_max),
        "positions" => &positions, "normals" => &normals, "colors" => &colors,
        "uv" => &uv, "custom" => &custom, "indices" => &indices, "collision" => &collision,
    }
}

#[godot_api(secondary)]
impl FactoryBackend {
    #[func]
    fn subscribe_presentation_runtime(&self, epoch: i64, generation: i64, job_id: i64, keys: Array<Vector3i>) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        if keys.is_empty() || keys.len() > pres::MAX_KEYS { return runtime_error(rt::Error::InvalidArgument); }
        let result = (|| {
            let interest = pres::Interest { generation: runtime_integer(generation)?,
                job_id: runtime_integer(job_id)?, keys: keys.iter_shared().map(cell).collect() };
            runtime.subscribe_presentation(runtime_integer(epoch)?, &interest)
        })();
        match result { Ok(()) => vdict! { "ok" => true }, Err(error) => runtime_error(error) }
    }
    #[func]
    fn unsubscribe_presentation_runtime(&self, epoch: i64, generation: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.unsubscribe_presentation(runtime_integer(epoch)?, runtime_integer(generation)?))();
        match result { Ok(()) => vdict! { "ok" => true }, Err(error) => runtime_error(error) }
    }
    #[func]
    fn poll_presentation_runtime(&self, epoch: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.poll_presentation(runtime_integer(epoch)?))();
        match result { Ok(info) => presentation_info(info), Err(error) => runtime_error(error) }
    }
    #[func]
    fn poll_presentation_page_runtime(&self, epoch: i64, generation: i64, snapshot_id: i64, page_index: i64, bytes: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.poll_presentation_page(runtime_integer(epoch)?, runtime_integer(generation)?,
            runtime_integer(snapshot_id)?, runtime_size(page_index)?, runtime_size(bytes)?))();
        match result { Ok(page) => presentation_page(page), Err(error) => runtime_error(error) }
    }
    #[func]
    fn ack_presentation_runtime(&self, epoch: i64, generation: i64, snapshot_id: i64) -> VarDictionary {
        let Some(runtime) = &self.runtime else { return save_error("runtime_not_open"); };
        let result = (|| runtime.acknowledge_presentation(runtime_integer(epoch)?, runtime_integer(generation)?, runtime_integer(snapshot_id)?))();
        match result { Ok(()) => vdict! { "ok" => true }, Err(error) => runtime_error(error) }
    }
}
