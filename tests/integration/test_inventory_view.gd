extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.set_controls_captured(true)


func after_test() -> void:
	Input.action_release("move_forward")
	Input.action_release("jump")
	_game.player.set_controls_captured(false)


func _key(key: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = key
	event.keycode = key
	event.pressed = true
	return event


func test_inventory_starts_empty_and_can_open_and_close() -> void:
	assert_int(_game.inventory.used_slots()).is_equal(0)
	assert_bool(_game.inventory_view.visible).is_false()
	_game.player.handle_input(_key(KEY_I))
	assert_bool(_game.inventory_view.visible).is_true()
	assert_bool(_game.player.controls_captured()).is_false()
	assert_int(_game.inventory_view.slot_grid.get_child_count()).is_equal(24)
	_game.player.handle_input(_key(KEY_ESCAPE))
	assert_bool(_game.inventory_view.visible).is_false()
	assert_bool(_game.player.controls_captured()).is_true()


func test_open_inventory_blocks_clicks_movement_and_view_rotation() -> void:
	_game.player.handle_input(_key(KEY_I))
	var before_basis: Basis = _game.player.camera.basis
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(100, 100)
	_game.player.handle_input(motion)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	_game.player.handle_input(click)
	assert_bool(_game.player.controls_captured()).is_false()
	assert_bool(_game.player.camera.basis.is_equal_approx(before_basis)).is_true()
	Input.action_press("move_forward")
	Input.action_press("jump")
	for frame: int in range(20):
		await get_tree().physics_frame
	assert_float(_game.player.position.z).is_equal_approx(_game.player.spawn_position.z, 0.0001)
	assert_float(_game.player.position.y).is_less(0.02)
	assert_int(_game.world_data.block_count()).is_equal(4096)


func test_selection_and_data_changes_refresh_view_and_close_button() -> void:
	_game.player.handle_input(_key(KEY_I))
	var first: Button = _game.inventory_view.slot_grid.get_child(0) as Button
	first.pressed.emit()
	assert_int(_game.inventory_view.selected_slot).is_equal(0)
	assert_bool(_game.inventory_view.detail_label.text.contains("Empty")).is_true()
	var fixture: ItemDefinition = ItemDefinition.new()
	fixture.item_id = &"test_fixture"
	fixture.display_name = "Test fixture"
	fixture.max_stack = 10
	_game.inventory.add_item(fixture, 4)
	assert_bool(first.text.contains("Test fixture")).is_true()
	assert_bool(_game.inventory_view.detail_label.text.contains("4")).is_true()
	_game.inventory_view.close_button.pressed.emit()
	assert_bool(_game.inventory_view.visible).is_false()
	assert_bool(_game.player.controls_captured()).is_true()


func test_space_used_to_close_inventory_does_not_jump() -> void:
	for frame: int in range(10):
		await get_tree().physics_frame
	_game.player.handle_input(_key(KEY_I))
	Input.action_press("jump")
	_game.get_viewport().push_input(_key(KEY_SPACE))
	var release: InputEventKey = _key(KEY_SPACE)
	release.pressed = false
	_game.get_viewport().push_input(release)
	Input.action_release("jump")
	assert_bool(_game.inventory_view.visible).is_false()
	for frame: int in range(4):
		await get_tree().physics_frame
	assert_float(_game.player.position.y).is_less(0.02)
	# A later, distinct jump still works.
	Input.action_press("jump")
	for frame: int in range(4):
		await get_tree().physics_frame
	Input.action_release("jump")
	assert_float(_game.player.position.y).is_greater(0.1)


func test_focus_loss_does_not_recapture_mouse_when_inventory_closes() -> void:
	_game.player.handle_input(_key(KEY_I))
	_game.player.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_game.inventory_view.close_button.pressed.emit()
	assert_bool(_game.player.controls_captured()).is_false()


func test_nonempty_unselected_inventory_does_not_claim_to_be_empty() -> void:
	var item: ItemDefinition = ItemDefinition.new()
	item.item_id = &"fixture"
	item.display_name = "Fixture"
	_game.inventory.add_item(item, 1)
	assert_bool(_game.inventory_view.detail_label.text.contains("inventory is empty")).is_false()
