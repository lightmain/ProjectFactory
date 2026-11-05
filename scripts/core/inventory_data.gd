class_name InventoryData
extends RefCounted
## Owns slot quantities. Public reads are snapshots; no world or input dependencies.

signal changed

const DEFAULT_CAPACITY: int = 24

var _slots: Array[ItemStack] = []


func _init(slot_count: int = DEFAULT_CAPACITY) -> void:
	_slots.resize(maxi(0, slot_count))


func capacity() -> int:
	return _slots.size()


func used_slots() -> int:
	var used: int = 0
	for stack: ItemStack in _slots:
		if stack != null:
			used += 1
	return used


func get_slot(index: int) -> ItemStack:
	if not _valid_index(index) or _slots[index] == null:
		return null
	return _slots[index].snapshot()


func save_state() -> Array:
	var result: Array = []
	for stack: ItemStack in _slots:
		result.append(null if stack == null else {
			"id": String(stack.definition.item_id), "name": stack.definition.display_name,
			"description": stack.definition.description, "max": stack.definition.max_stack,
			"quantity": stack.quantity,
		})
	return result


func restore_state(rows: Array) -> bool:
	if rows.size() != DEFAULT_CAPACITY:
		return false
	var slots: Array[ItemStack] = []
	var definitions: Dictionary[String, ItemDefinition] = {}
	for value: Variant in rows:
		if value == null:
			slots.append(null)
			continue
		if not value is Dictionary:
			return false
		var row: Dictionary = value
		if not row.get("id") is String or not row.get("name") is String or (
			not row.get("description") is String
			or not SnapshotValues.integer(row.get("max"), 1, 1000000)
			or not SnapshotValues.integer(row.get("quantity"), 1, 1000000)
		):
			return false
		var item_id: String = row["id"]
		var display_name: String = row["name"]
		var description: String = row["description"]
		var max_stack: int = row["max"]
		var quantity: int = row["quantity"]
		if item_id.is_empty() or item_id.length() > 128 or display_name.length() > 256 or (
			description.length() > 4096 or quantity > max_stack
		):
			return false
		var definition: ItemDefinition = definitions.get(item_id)
		if definition == null:
			definition = ItemDefinition.new()
			definition.item_id = StringName(item_id)
			definition.display_name = display_name
			definition.description = description
			definition.max_stack = max_stack
			definitions[item_id] = definition
		elif definition.display_name != display_name or definition.description != description or (
			definition.max_stack != max_stack
		):
			return false
		slots.append(ItemStack.new(definition, quantity))
	_slots = slots
	changed.emit()
	return true


func add_item(definition: ItemDefinition, amount: int) -> int:
	## Returns the amount not accepted. Invalid operations never emit changed.
	var remaining: int = maxi(0, amount)
	if definition == null or not definition.is_valid() or remaining == 0:
		return remaining
	for stack: ItemStack in _slots:
		if stack == null or stack.definition != definition:
			continue
		var accepted: int = mini(remaining, maxi(0, definition.max_stack - stack.quantity))
		stack.quantity += accepted
		remaining -= accepted
	for index: int in range(_slots.size()):
		if remaining == 0:
			break
		if _slots[index] != null:
			continue
		var accepted: int = mini(remaining, definition.max_stack)
		_slots[index] = ItemStack.new(definition, accepted)
		remaining -= accepted
	if remaining < amount:
		changed.emit()
	return remaining


func remove_from_slot(index: int, amount: int) -> int:
	if not _valid_index(index) or amount <= 0 or _slots[index] == null:
		return 0
	var removed: int = mini(amount, _slots[index].quantity)
	_slots[index].quantity -= removed
	if _slots[index].quantity == 0:
		_slots[index] = null
	changed.emit()
	return removed


func move_slot(source: int, target: int) -> bool:
	if not _valid_index(source) or not _valid_index(target) or source == target:
		return false
	var from: ItemStack = _slots[source]
	var to: ItemStack = _slots[target]
	if from == null:
		return false
	if to != null and from.definition == to.definition:
		var amount: int = mini(from.quantity, maxi(0, to.definition.max_stack - to.quantity))
		if amount == 0:
			return false
		to.quantity += amount
		from.quantity -= amount
		if from.quantity == 0:
			_slots[source] = null
	else:
		_slots[source] = to
		_slots[target] = from
	changed.emit()
	return true


func _valid_index(index: int) -> bool:
	return index >= 0 and index < _slots.size()
