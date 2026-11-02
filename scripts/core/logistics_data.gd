class_name LogisticsData
extends RefCounted
## Authoritative production and transport; no scene, input or visibility dependencies.

signal machine_changed(cell: Vector3i)
signal reset

const TRANSPORT_INTERVAL: float = 0.5
const BELT_CAPACITY: int = 2
const TIME_EPSILON: float = 0.000000001

var _world: VoxelWorldData
var _machines: Dictionary[Vector3i, LogisticsMachine] = {}
var _time: float = 0.0
var _time_compensation: float = 0.0
var _next_transport: float = TRANSPORT_INTERVAL
var _mining_interval: float = 1.0
var _mining_amount: int = 1


static func is_machine(block: int) -> bool:
	return block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST]


func bind_world(world: VoxelWorldData, interval: float = 1.0, amount: int = 1) -> void:
	if _world != null:
		_world.cell_changed.disconnect(_on_cell_changed)
		_world.world_reset.disconnect(_on_world_reset)
	_world = world
	configure_miners(interval, amount)
	_world.cell_changed.connect(_on_cell_changed)
	_world.world_reset.connect(_on_world_reset)
	_on_world_reset()


func configure_miners(interval: float, amount: int) -> void:
	## Only future placements copy these settings; existing state is untouched.
	_mining_interval = interval
	_mining_amount = amount


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	# Compensated summation keeps long runs independent of delta partitioning.
	var corrected_delta: float = delta - _time_compensation
	var end_time: float = _time + corrected_delta
	if not is_finite(end_time):
		return
	_time_compensation = (end_time - _time) - corrected_delta
	if _machines.is_empty():
		_time = end_time
		_next_transport = (floorf(_time / TRANSPORT_INTERVAL) + 1.0) * TRANSPORT_INTERVAL
		if _next_transport <= _time:
			_next_transport = INF
		return
	# Visit deadlines chronologically, so catch-up equals many short updates.
	while true:
		var event_time: float = _next_transport
		for machine: LogisticsMachine in _machines.values():
			event_time = minf(event_time, machine.next_production)
		if event_time > end_time + TIME_EPSILON:
			break
		var transport_due: bool = _next_transport <= event_time + TIME_EPSILON
		for machine: LogisticsMachine in _machines.values():
			if machine.next_production <= event_time + TIME_EPSILON:
				machine.produce()
		_transfer(transport_due)
		if transport_due:
			_next_transport += TRANSPORT_INTERVAL
			if _next_transport <= event_time:
				_next_transport = INF
	_time = end_time


func set_direction(cell: Vector3i, direction: Vector3i) -> bool:
	if not _machines.has(cell) or direction not in [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK,
	]:
		return false
	_machines[cell].direction = direction
	machine_changed.emit(cell)
	return true


func direction_at(cell: Vector3i) -> Vector3i:
	return _machines[cell].direction if _machines.has(cell) else Vector3i.ZERO


func ore_count(cell: Vector3i) -> int:
	return _machines[cell].quantity if _machines.has(cell) else 0


func total_ore() -> int:
	var count: int = 0
	for machine: LogisticsMachine in _machines.values():
		count += machine.quantity
	return count


func machine_cells() -> Array[Vector3i]:
	return _machines.keys()


func _on_world_reset() -> void:
	_machines.clear()
	_time = 0.0
	_time_compensation = 0.0
	_next_transport = TRANSPORT_INTERVAL
	for cell: Vector3i in _world.solid_cells():
		var block: int = _world.get_block(cell)
		if is_machine(block):
			_machines[cell] = LogisticsMachine.new(block, _time, _mining_interval, _mining_amount)
	reset.emit()


func _on_cell_changed(cell: Vector3i) -> void:
	var block: int = _world.get_block(cell)
	if is_machine(block):
		_machines[cell] = LogisticsMachine.new(block, _time, _mining_interval, _mining_amount)
	else:
		_machines.erase(cell)
	machine_changed.emit(cell)


func _transfer(transport_due: bool) -> void:
	# Plans use pre-transfer quantities: no received ore can move again this event.
	var changes: Dictionary[Vector3i, int] = {}
	var sent: Dictionary[Vector3i, int] = {}
	for target_cell: Vector3i in _machines:
		var target: LogisticsMachine = _machines[target_cell]
		if target.block == VoxelWorldData.Block.MINER:
			continue
		if target.block == VoxelWorldData.Block.CHEST:
			var source_cell: Vector3i = target_cell - target.direction
			var amount: int = _output_available(source_cell, target.direction, transport_due, sent)
			if amount > 0:
				_plan_transfer(source_cell, target_cell, amount, changes, sent)
			continue
		var side: Vector3i = Vector3i(-target.direction.z, 0, target.direction.x)
		var inputs: Array[Vector3i] = [target.direction, side, -side]
		# At most two free slots, reserved one at a time before applying any transfer.
		for slot: int in range(BELT_CAPACITY - target.quantity):
			var accepted: bool = false
			for offset: int in range(inputs.size()):
				var port: int = (target.input_cursor + offset) % inputs.size()
				var source_cell: Vector3i = target_cell - inputs[port]
				if _output_available(source_cell, inputs[port], transport_due, sent) <= 0:
					continue
				_plan_transfer(source_cell, target_cell, 1, changes, sent)
				target.input_cursor = (port + 1) % inputs.size()
				accepted = true
				break
			if not accepted:
				break
	for cell: Vector3i in changes:
		_machines[cell].quantity += changes[cell]


func _output_available(
	cell: Vector3i, direction: Vector3i, transport_due: bool, sent: Dictionary[Vector3i, int]
) -> int:
	if not _machines.has(cell):
		return 0
	var source: LogisticsMachine = _machines[cell]
	if source.direction != direction:
		return 0
	var available: int = source.quantity
	if source.block == VoxelWorldData.Block.BELT:
		available = mini(available, 1) if transport_due else 0
	return available - sent.get(cell, 0)


static func _plan_transfer(
	source: Vector3i, target: Vector3i, amount: int,
	changes: Dictionary[Vector3i, int], sent: Dictionary[Vector3i, int]
) -> void:
	changes[source] = changes.get(source, 0) - amount
	changes[target] = changes.get(target, 0) + amount
	sent[source] = sent.get(source, 0) + amount
