class_name LogisticsProductionSchedule
extends RefCounted
## Deadline heap borrowing live miners. Cell keys survive topology compaction.

var work: int = 0
var deadline_checks: int = 0
var due_visits: int = 0
var heap_comparisons: int = 0
var _heap: Array[LogisticsMachine] = []
var _cells: Array[Vector3i] = []
var _indices: Dictionary[Vector3i, int] = {}


func clear() -> void:
	_heap.clear()
	_cells.clear()
	_indices.clear()
	work = 0
	deadline_checks = 0
	due_visits = 0
	heap_comparisons = 0


func size() -> int:
	return _heap.size()


func add(cell: Vector3i, machine: LogisticsMachine) -> void:
	work += 1
	if machine.block != VoxelWorldData.Block.MINER or not is_finite(machine.next_production):
		return
	assert(not _indices.has(cell), "Duplicate production deadline")
	_indices[cell] = _heap.size()
	_heap.append(machine)
	_cells.append(cell)
	work += 1
	_rise(_heap.size() - 1)


func remove(cell: Vector3i) -> void:
	var index: int = _indices.get(cell, -1)
	if index < 0:
		return
	var last: int = _heap.size() - 1
	_indices.erase(cell)
	if index != last:
		_heap[index] = _heap[last]
		_cells[index] = _cells[last]
		_indices[_cells[index]] = index
	_heap.pop_back()
	_cells.pop_back()
	work += 1
	if index >= _heap.size():
		return
	if index > 0 and _less(index, (index - 1) / 2):
		_rise(index)
	else:
		_sink(index)


func produce_due(boundary: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var produced: Array[LogisticsMachine] = []
	while not _heap.is_empty():
		deadline_checks += 1
		work += 1
		var machine: LogisticsMachine = _heap[0]
		if machine.next_production > boundary + LogisticsData.TIME_EPSILON:
			break
		var cell: Vector3i = _cells[0]
		remove(cell)
		due_visits += 1
		work += 1
		machine.produce_until(boundary)
		result.append(cell)
		produced.append(machine)
	# Even when floating-point rounding leaves a deadline unchanged, the same
	# miner must not be processed twice at this formal boundary.
	for index: int in range(result.size()):
		add(result[index], produced[index])
	return result


func _less(left: int, right: int) -> bool:
	heap_comparisons += 1
	work += 2
	return _heap[left].next_production < _heap[right].next_production


func _swap(left: int, right: int) -> void:
	var machine: LogisticsMachine = _heap[left]
	var cell: Vector3i = _cells[left]
	_heap[left] = _heap[right]
	_cells[left] = _cells[right]
	_heap[right] = machine
	_cells[right] = cell
	_indices[_cells[left]] = left
	_indices[_cells[right]] = right
	work += 1


func _rise(start: int) -> void:
	var index: int = start
	while index > 0:
		var parent: int = (index - 1) / 2
		if not _less(index, parent):
			break
		_swap(index, parent)
		index = parent


func _sink(start: int) -> void:
	var index: int = start
	while index * 2 + 1 < _heap.size():
		var child: int = index * 2 + 1
		if child + 1 < _heap.size() and _less(child + 1, child):
			child += 1
		if not _less(child, index):
			break
		_swap(child, index)
		index = child
