extends GdUnitTestSuite
## Engine mesh/collision resources must appear only as one complete round.

var _view: FactoryStaticView


func before_test() -> void:
	_view = auto_free(FactoryStaticView.new()) as FactoryStaticView
	add_child(_view)


func test_pages_prepare_resources_without_enabling_collision_until_complete_activation() -> void:
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	assert_bool(_view.begin_snapshot(_info(1, 2), keys)).is_true()
	assert_bool(_view.stage_page(_page(1, 0, 2))).is_true()
	assert_bool(_view.prepared()).is_false()
	assert_bool(_view.activate(1, 1)).is_false()
	assert_int(_view.get_child_count()).is_equal(0)
	assert_bool(_view.stage_page(_page(1, 1, 2))).is_true()
	assert_bool(_view.prepared()).is_true()
	assert_int(_view.get_child_count()).is_equal(0)
	assert_bool(_view.activate(1, 1)).is_true()
	if _view.get_child_count() == 0:
		return
	var root: Node3D = _view.get_child(0) as Node3D
	var body: StaticBody3D = root.get_child(0) as StaticBody3D
	var visual: MeshInstance3D = body.get_node("Mesh") as MeshInstance3D
	var collision: CollisionShape3D = body.get_node("Collision") as CollisionShape3D
	var mesh: ArrayMesh = visual.mesh as ArrayMesh
	assert_int(mesh.get_surface_count()).is_equal(2)
	assert_vector(body.position).is_equal(Vector3(-4, 0, 0))
	assert_int(body.collision_layer).is_equal(1)
	assert_int((collision.shape as ConcavePolygonShape3D).get_faces().size()).is_equal(12)
	for surface: int in range(2):
		var arrays: Array = mesh.surface_get_arrays(surface)
		assert_array(arrays[Mesh.ARRAY_VERTEX]).is_equal(_page(1, surface, 2).positions)
		assert_array(arrays[Mesh.ARRAY_INDEX]).is_equal(PackedInt32Array([0, 1, 2, 0, 2, 3]))


func test_missing_stale_and_invalid_pages_keep_old_complete_resources() -> void:
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	assert_bool(_view.begin_snapshot(_info(1, 1), keys)).is_true()
	assert_bool(_view.stage_page(_page(1, 0, 1))).is_true()
	assert_bool(_view.activate(1, 1)).is_true()
	if _view.get_child_count() == 0:
		return
	var original: int = _view.get_child(0).get_instance_id()
	assert_bool(_view.begin_snapshot(_info(2, 2), keys)).is_true()
	assert_bool(_view.stage_page(_page(2, 0, 2))).is_true()
	var stale: Dictionary = _page(2, 1, 2)
	stale["revision"] = 6
	assert_bool(_view.stage_page(stale)).is_false()
	assert_bool(_view.prepared()).is_false()
	assert_bool(_view.activate(1, 2)).is_false()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(original)
	assert_bool(_view.begin_snapshot(_info(3, 1), keys)).is_true()
	var invalid: Dictionary = _page(3, 0, 1)
	invalid["indices"] = PackedInt32Array([999, 1, 2, 0, 2, 3])
	assert_bool(_view.stage_page(invalid)).is_false()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(original)


func test_sweep_requires_all_keys_current_revision_and_parent_transform() -> void:
	_view.position = Vector3(10, 2, 8)
	_view.rotation.y = PI * 0.5
	_view.scale = Vector3(2, 1, 2)
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	assert_bool(_view.begin_snapshot(_info(1, 1), keys)).is_true()
	assert_bool(_view.stage_page(_page(1, 0, 1))).is_true()
	assert_bool(_view.activate(1, 1)).is_true()
	if _view.get_child_count() == 0:
		return
	var from: Vector3 = _view.to_global(Vector3(-3, 1, 1))
	var to: Vector3 = _view.to_global(Vector3(-2, 1, 1))
	assert_bool(_view.covers_sweep(from, to, Vector3.ONE * 0.1, 1, 5)).is_true()
	assert_bool(_view.covers_sweep(from, to, Vector3.ONE * 0.1, 1, 6)).is_false()
	assert_bool(_view.covers_sweep(from, to, Vector3.ONE * 0.1, 2, 5)).is_false()
	to = _view.to_global(Vector3(1, 1, 1))
	assert_bool(_view.covers_sweep(from, to, Vector3.ONE * 0.1, 1, 5)).is_false()
	var body: Node3D = _view.get_child(0).get_child(0) as Node3D
	assert_vector(body.to_global(Vector3(0.25, 0, 0.25))).is_equal(
		_view.to_global(Vector3(-3.75, 0, 0.25)))


func test_empty_complete_page_retires_old_geometry_and_abort_keeps_it() -> void:
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	assert_bool(_view.begin_snapshot(_info(1, 1), keys)).is_true()
	assert_bool(_view.stage_page(_page(1, 0, 1))).is_true()
	assert_bool(_view.activate(1, 1)).is_true()
	if _view.get_child_count() == 0:
		return
	var original: int = _view.get_child(0).get_instance_id()
	assert_bool(_view.begin_snapshot(_info(2, 1), keys)).is_true()
	_view.abort()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(original)
	var info: Dictionary = _info(3, 1)
	info["total_bytes"] = 4096
	assert_bool(_view.begin_snapshot(info, keys)).is_true()
	var empty: Dictionary = _page(3, 0, 1)
	empty["page_bytes"] = 4096
	empty["positions"] = PackedVector3Array()
	empty["normals"] = PackedVector3Array()
	empty["colors"] = PackedColorArray()
	empty["uv"] = PackedVector2Array()
	empty["custom"] = PackedFloat32Array()
	empty["indices"] = PackedInt32Array()
	empty["collision"] = PackedVector3Array()
	assert_bool(_view.stage_page(empty)).is_true()
	assert_bool(_view.activate(1, 3)).is_true()
	assert_bool(is_instance_id_valid(original)).is_false()
	assert_int(_view.get_child(0).get_child_count()).is_equal(0)
	assert_bool(_view.covers_sweep(Vector3(-2, 1, 1), Vector3(-2, 1, 1),
		Vector3.ONE * 0.1, 1, 5)).is_true()


func test_freeing_detached_view_releases_its_detached_staging_nodes() -> void:
	var detached: FactoryStaticView = FactoryStaticView.new()
	assert_bool(detached.begin_snapshot(_info(1, 1), [Vector3i(-1, 0, 0)])).is_true()
	assert_bool(detached.stage_page(_page(1, 0, 1))).is_true()
	var staging: Node3D = detached.get("_staging") as Node3D
	assert_object(staging).is_not_null()
	if staging == null:
		detached.free()
		return
	var identity: int = staging.get_instance_id()
	detached.free()
	assert_bool(is_instance_id_valid(identity)).is_false()
	# Preserve test isolation when the regression is deliberately RED.
	if is_instance_id_valid(identity):
		(instance_from_id(identity) as Node).free()


func test_chunk_exceeding_engine_surface_limit_is_rejected_before_resource_creation() -> void:
	assert_bool(_view.begin_snapshot(_info(1, 257), [Vector3i(-1, 0, 0)])).is_true()
	assert_bool(_view.stage_page(_page(1, 0, 257))).is_false()
	assert_bool(_view.prepared()).is_false()
	assert_int(_view.get_child_count()).is_equal(0)


static func _info(snapshot: int, pages: int) -> Dictionary:
	return {"ok": true, "world_epoch": 1, "view_generation": 1, "job_id": 0,
		"snapshot_id": snapshot, "revision": 5, "tick": 0, "stage": "ready",
		"total_pages": pages, "total_bytes": pages * 4448}


static func _page(snapshot: int, index: int, count: int) -> Dictionary:
	var positions: PackedVector3Array = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(0, 0, 0.5), Vector3(0.5, 0, 0.5), Vector3(0.5, 0, 0)])
	return {"ok": true, "world_epoch": 1, "view_generation": 1, "job_id": 0,
		"snapshot_id": snapshot, "revision": 5, "world_revision": 5, "tick": 0,
		"page_index": index, "total_pages": count,
		"keys": PackedInt32Array([-1, 0, 0]), "key": Vector3i(-1, 0, 0),
		"chunk_page": index, "chunk_pages": count, "page_bytes": 4448,
		"origin": Vector3(-4, 0, 0), "bounds_min": Vector3.ZERO, "bounds_max": Vector3(0.5, 0, 0.5),
		"positions": positions, "normals": PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]),
		"colors": PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]),
		"uv": PackedVector2Array([Vector2.ZERO, Vector2.DOWN, Vector2.ONE, Vector2.RIGHT]),
		"custom": PackedFloat32Array([-3.75, 0.25, 0.25, 0, -3.75, 0.25, 0.25, 0,
			-3.75, 0.25, 0.25, 0, -3.75, 0.25, 0.25, 0]),
		"indices": PackedInt32Array([0, 1, 2, 0, 2, 3]),
		"collision": PackedVector3Array([positions[0], positions[1], positions[2],
			positions[0], positions[2], positions[3]])}
