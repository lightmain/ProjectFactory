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
