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
