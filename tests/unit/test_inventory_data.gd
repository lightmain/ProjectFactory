extends GdUnitTestSuite


func _item(id: StringName, max_stack: int = 10) -> ItemDefinition:
	var definition: ItemDefinition = ItemDefinition.new()
	definition.item_id = id
	definition.display_name = String(id)
	definition.max_stack = max_stack
	return definition


func test_inventory_starts_empty_and_players_do_not_share_slots() -> void:
	var first: InventoryData = InventoryData.new()
	var second: InventoryData = InventoryData.new()
	assert_int(first.capacity()).is_equal(24)
	assert_int(first.used_slots()).is_equal(0)
	for index: int in range(first.capacity()):
		assert_object(first.get_slot(index)).is_null()
	first.add_item(_item(&"fixture"), 1)
	assert_int(second.used_slots()).is_equal(0)


func test_add_fills_existing_stacks_and_returns_overflow() -> void:
	var inventory: InventoryData = InventoryData.new(2)
	var item: ItemDefinition = _item(&"fixture")
	assert_int(inventory.add_item(item, 8)).is_equal(0)
	assert_int(inventory.add_item(item, 15)).is_equal(3)
	assert_int(inventory.get_slot(0).quantity).is_equal(10)
	assert_int(inventory.get_slot(1).quantity).is_equal(10)


func test_slot_snapshots_cannot_mutate_authoritative_quantities() -> void:
	var inventory: InventoryData = InventoryData.new()
	inventory.add_item(_item(&"fixture"), 5)
	var snapshot: ItemStack = inventory.get_slot(0)
	snapshot.quantity = 100
	assert_int(inventory.get_slot(0).quantity).is_equal(5)


func test_move_merge_swap_and_removal_conserve_items() -> void:
	var inventory: InventoryData = InventoryData.new(3)
	var first: ItemDefinition = _item(&"first")
	var second: ItemDefinition = _item(&"second")
	inventory.add_item(first, 14)
	assert_bool(inventory.move_slot(1, 2)).is_true()
	inventory.remove_from_slot(0, 5)
	assert_bool(inventory.move_slot(2, 0)).is_true()
	assert_int(inventory.get_slot(0).quantity).is_equal(9)
	assert_object(inventory.get_slot(2)).is_null()
	inventory.add_item(second, 2)
	assert_bool(inventory.move_slot(0, 1)).is_true()
	assert_str(String(inventory.get_slot(0).definition.item_id)).is_equal("second")
	assert_int(inventory.remove_from_slot(1, 100)).is_equal(9)
	assert_object(inventory.get_slot(1)).is_null()


func test_invalid_operations_do_not_change_inventory() -> void:
	var inventory: InventoryData = InventoryData.new(1)
	var invalid: ItemDefinition = ItemDefinition.new()
	assert_int(inventory.add_item(null, 5)).is_equal(5)
	assert_int(inventory.add_item(invalid, 5)).is_equal(5)
	assert_int(inventory.add_item(_item(&"fixture"), -1)).is_equal(0)
	assert_object(inventory.get_slot(-1)).is_null()
	assert_bool(inventory.move_slot(-1, 0)).is_false()
	assert_bool(inventory.move_slot(0, 1)).is_false()
	assert_int(inventory.remove_from_slot(0, -1)).is_equal(0)
	assert_int(inventory.used_slots()).is_equal(0)
