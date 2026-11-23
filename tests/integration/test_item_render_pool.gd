extends GdUnitTestSuite

var _pool: ItemRenderPool
var _mesh: BoxMesh
var _material: StandardMaterial3D


func before_test() -> void:
	_pool = auto_free(ItemRenderPool.new()) as ItemRenderPool
	add_child(_pool)
	_mesh = BoxMesh.new()
	_material = StandardMaterial3D.new()
	_pool.register_visual(&"iron_ore", _mesh, _material)


func _submit(id: int, cell: Vector3i, item_id: StringName = &"iron_ore") -> void:
	assert_bool(_pool.submit(id, item_id, cell, Transform3D(
		Basis.IDENTITY, VoxelWorldData.cell_center(cell)
	))).is_true()


func test_shared_visuals_batch_together_and_other_meshes_or_materials_separate() -> void:
	_pool.register_visual(&"same_model", _mesh, _material)
	var gear: CylinderMesh = CylinderMesh.new()
	_pool.register_visual(&"gear", gear, _material)
	var copper: StandardMaterial3D = StandardMaterial3D.new()
	_pool.register_visual(&"copper_ore", _mesh, copper)
	_pool.begin_frame()
	_submit(1, Vector3i.ZERO)
	_submit(2, Vector3i.RIGHT, &"same_model")
	_submit(3, Vector3i.ZERO, &"gear")
	_submit(4, Vector3i.ZERO, &"copper_ore")
	_pool.end_frame()
	assert_int(_pool.stats()["active_batches"]).is_equal(3)
	assert_int(_pool.stats()["visible_items"]).is_equal(4)
	assert_object(_pool.item_batch(1)).is_same(_pool.item_batch(2))
	assert_object(_pool.item_batch(3).multimesh.mesh).is_same(gear)
	assert_object(_pool.item_batch(4).material_override).is_same(copper)
	assert_int(_pool.find_children("*", "CollisionObject3D", true, false).size()).is_equal(0)


func test_capacity_and_multimesh_survive_shrink_cull_and_return() -> void:
	_pool.begin_frame()
	for id: int in range(19):
		_submit(id, Vector3i.ZERO)
	_pool.end_frame()
	var batch: ItemRenderBatch = _pool.item_batch(0)
	var multimesh: MultiMesh = batch.multimesh
	var capacity: int = multimesh.instance_count
	assert_int(capacity).is_greater_equal(19)
	_pool.begin_frame()
	_submit(0, Vector3i.ZERO)
	_pool.end_frame()
	assert_int(multimesh.visible_instance_count).is_equal(1)
	assert_int(multimesh.instance_count).is_equal(capacity)
	_pool.begin_frame()
	_pool.end_frame()
	assert_int(multimesh.visible_instance_count).is_equal(0)
	assert_bool(batch.visible).is_false()
	assert_bool(_pool.has_item(0)).is_false()
	_pool.begin_frame()
	_submit(0, Vector3i.ZERO)
	_pool.end_frame()
	assert_object(_pool.item_batch(0)).is_same(batch)
	assert_object(batch.multimesh).is_same(multimesh)
	assert_int(multimesh.instance_count).is_equal(capacity)


func test_partition_boundary_and_transformed_parent_preserve_world_positions() -> void:
	_pool.transform = Transform3D(
		Basis(Vector3.UP, 0.7).scaled(Vector3.ONE * 2.0), Vector3(15, 3, -6)
	)
	_pool.begin_frame()
	_submit(1, Vector3i(-1, 0, 0))
	_submit(2, Vector3i(-8, 0, 0))
	_submit(3, Vector3i(-9, 0, 0))
	_submit(4, Vector3i.ZERO)
	_submit(5, Vector3i(8, 0, 0))
	_pool.end_frame()
	assert_int(_pool.stats()["active_batches"]).is_equal(4)
	assert_object(_pool.item_batch(1)).is_same(_pool.item_batch(2))
	for id: int in [1, 2, 3, 4, 5]:
		var batch: ItemRenderBatch = _pool.item_batch(id)
		var position: Vector3 = _pool.item_transform(id).origin
		assert_bool(batch.multimesh.custom_aabb.has_point(
			batch.global_transform.affine_inverse() * position
		)).is_true()
	assert_vector(_pool.item_transform(1).origin).is_equal_approx(
		VoxelWorldData.cell_center(Vector3i(-1, 0, 0)), Vector3.ONE * 0.00001
	)
	_pool.begin_frame()
	var boundary: Vector3 = Vector3(4, 0.12, 0.25)
	assert_bool(_pool.submit(5, &"iron_ore", Vector3i(7, 0, 0), Transform3D(
		Basis.IDENTITY, boundary
	))).is_true()
	_pool.end_frame()
	_pool.begin_frame()
	assert_bool(_pool.submit(5, &"iron_ore", Vector3i(8, 0, 0), Transform3D(
		Basis.IDENTITY, boundary
	))).is_true()
	_pool.end_frame()
	assert_vector(_pool.item_transform(5).origin).is_equal_approx(
		boundary, Vector3.ONE * 0.00001
	)


func test_empty_batches_are_bounded_reused_and_cleared() -> void:
	_pool.begin_frame()
	for id: int in range(48):
		_submit(id, Vector3i(id * 8, 0, 0))
	_pool.end_frame()
	assert_int(_pool.stats()["active_batches"]).is_equal(48)
	_pool.begin_frame()
	_pool.end_frame()
	assert_int(_pool.stats()["cached_batches"]).is_equal(ItemRenderPool.MAX_IDLE_BATCHES)
	assert_int(_pool.get_child_count()).is_equal(ItemRenderPool.MAX_IDLE_BATCHES)
	var cached_ids: Array[int] = []
	for node: Node in _pool.get_children():
		cached_ids.append(node.get_instance_id())
	_pool.begin_frame()
	_submit(100, Vector3i(1000, 0, 0))
	_pool.end_frame()
	assert_array(cached_ids).contains([_pool.item_batch(100).get_instance_id()])
	assert_int(_pool.get_child_count()).is_equal(ItemRenderPool.MAX_IDLE_BATCHES)
	_pool.clear()
	assert_int(_pool.get_child_count()).is_equal(0)
	assert_int(_pool.stats()["visible_items"]).is_equal(0)


func test_unknown_types_and_duplicate_ids_do_not_create_phantom_instances() -> void:
	_pool.begin_frame()
	assert_bool(_pool.submit(1, &"unknown", Vector3i.ZERO, Transform3D.IDENTITY)).is_false()
	_submit(1, Vector3i.ZERO)
	assert_bool(_pool.submit(1, &"iron_ore", Vector3i.ZERO, Transform3D.IDENTITY)).is_false()
	_pool.end_frame()
	assert_int(_pool.stats()["visible_items"]).is_equal(1)
	assert_int(_pool.item_batch(1).multimesh.visible_instance_count).is_equal(1)


func test_bulk_upload_preserves_real_gpu_transforms_and_recomputes_parent_inverse_per_frame() -> void:
	await _assert_uploaded_transforms(false)


func test_upload_without_native_helper_preserves_gpu_transforms_and_bounds() -> void:
	await _assert_uploaded_transforms(true)


func _assert_uploaded_transforms(disable_native: bool) -> void:
	var native_expected: bool = false
	if not disable_native and ClassDB.class_exists("RustConveyorNetwork"):
		var helper: Object = ClassDB.instantiate("RustConveyorNetwork")
		native_expected = helper.has_method("upload_multimesh")
	for frame: int in range(2):
		_pool.transform = Transform3D(
			Basis.from_euler(Vector3(0.2, 0.7 + float(frame), -0.3)).scaled(Vector3(2, 1.5, 0.75)),
			Vector3(15 + frame, 3, -6)
		)
		_pool.begin_frame()
		var expected: Array[Transform3D] = []
		for id: int in range(19 if frame == 0 else 3):
			var cell: Vector3i = Vector3i(-8 if id % 2 == 0 else 8, 0, 0)
			var transform: Transform3D = Transform3D(
				Basis.from_euler(Vector3(0.1 * float(id), -0.3, 0.4)).scaled(Vector3(0.5, 1.5, 2)),
				VoxelWorldData.cell_center(cell) + Vector3(0.01 * float(id), 0.04, 0)
			)
			expected.append(transform)
			assert_bool(_pool.submit(id, &"iron_ore", cell, transform)).is_true()
			if disable_native:
				_pool.item_batch(id).set("_native_upload", null)
		_pool.end_frame()
		await get_tree().process_frame
		assert_int(_pool.stats().get("batch_uploads", -1)).is_equal(2)
		assert_int(_pool.stats().get("buffer_uploads", -1)).is_equal(2 if native_expected else 0)
		assert_int(_pool.stats().get("inverse_calculations", -1)).is_equal(2)
		var slots: Dictionary[ItemRenderBatch, int] = {}
		for id: int in range(expected.size()):
			var batch: ItemRenderBatch = _pool.item_batch(id)
			var slot: int = slots.get(batch, 0)
			slots[batch] = slot + 1
			# The headless dummy renderer does not retain GPU transforms.
			# The same suite also runs in a real graphical verification window.
			var local: Transform3D = batch.transforms[slot] if DisplayServer.get_name() == "headless" else (
				batch.multimesh.get_instance_transform(slot)
			)
			var uploaded: Transform3D = batch.global_transform * local
			assert_vector(uploaded.origin).is_equal_approx(expected[id].origin, Vector3.ONE * 0.00001)
			assert_vector(uploaded.basis.x).is_equal_approx(expected[id].basis.x, Vector3.ONE * 0.00001)
			assert_vector(uploaded.basis.y).is_equal_approx(expected[id].basis.y, Vector3.ONE * 0.00001)
			assert_vector(uploaded.basis.z).is_equal_approx(expected[id].basis.z, Vector3.ONE * 0.00001)
			assert_bool(batch.multimesh.custom_aabb.encloses(
				(batch.global_transform.affine_inverse() * expected[id]) * _mesh.get_aabb()
			)).is_true()
