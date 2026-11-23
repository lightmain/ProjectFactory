class_name BeltSegmentTransport
extends RefCounted
## Pure chains own an ordered ore queue and runs of equal cell positions.
## Internal transfers change runs, never expand the chain into individual ores.
## Inventory and merge cells remain single-cell boundaries. Cycles use the solver.


class Run extends RefCounted:
	var first: int
	var end: int
	var quantity: int = 0
	var head: float = 0.0
	var tail: float = 0.0
	var head_aligned: bool = false
	var tail_aligned: bool = false
	var eligible: int = 0
	# Keep output eligibility in the run so an edit's supplemental batch
	# can reject used sources without expanding per-cell metadata.
	var last_output: int = -1
	var downstream_ores: int = 0

	func copy_range(start: int, stop: int) -> Run:
		var result: Run = Run.new()
		result.first = start
		result.end = stop
		result.quantity = quantity
		result.head = head
		result.tail = tail
		result.head_aligned = head_aligned
		result.tail_aligned = tail_aligned
		result.eligible = eligible
		result.last_output = last_output
		return result

	func same(other: Run) -> bool:
		return quantity == other.quantity and head == other.head and tail == other.tail \
			and head_aligned == other.head_aligned and tail_aligned == other.tail_aligned \
			and eligible == other.eligible and last_output == other.last_output


class Identity extends RefCounted:
	var ore: LogisticsOre
	var origin: int


class RangeMarks extends RefCounted:
	# -2 means use the original machine's metadata; -3 means split children.
	var size: int = 1
	var values: PackedInt64Array = PackedInt64Array()
	var work: int = 0

	func setup(count: int) -> void:
		while size < count:
			size *= 2
		values.resize(size * 2)
		values.fill(-2)

	func assign_range(first: int, end: int, value: int, node: int = 1, low: int = 0, high: int = -1) -> void:
		work += 1
		if high < 0:
			high = size
		if first <= low and high <= end:
			values[node] = value
			return
		if values[node] != -3:
			values[node * 2] = values[node]
			values[node * 2 + 1] = values[node]
			values[node] = -3
		var middle: int = (low + high) / 2
		if first < middle:
			assign_range(first, end, value, node * 2, low, middle)
		if end > middle:
			assign_range(first, end, value, node * 2 + 1, middle, high)

	func at(position: int) -> int:
		var node: int = 1
		var low: int = 0
		var high: int = size
		while values[node] == -3:
			work += 1
			var middle: int = (low + high) / 2
			if position < middle:
				node *= 2
				high = middle
			else:
				node = node * 2 + 1
				low = middle
		work += 1
		return values[node]


class Segment extends RefCounted:
	var cells: Array[int] = []
	var runs: Array[Run] = []
	var moved: Array[Run] = []
	var predicted: Array[Run] = []
	var identities: Array[Identity] = []
	var read: int = 0
	var live_count: int = 0
	var output: bool = false
	var input_source: int = -1
	var input_amount: int = 0
	var output_amount: int = 0
	var incoming_ore: LogisticsOre
	var cursor_marks: RangeMarks = RangeMarks.new()
	var belt: bool = true


var active: bool = false
var work: int = 0
var internal_transfers: int = 0
var materialized_cells: int = 0
var materialize_work: int = 0
var fallback_ticks: int = 0
var run_visits: int = 0
var segment_count: int = 0
var prediction_work: int = 0
var _topology: LogisticsTopology
var _segments: Array[Segment] = []
var _owners: Array[int] = []
var _positions: Array[int] = []
var _ports: Array[int] = []
var _order: Array[int] = []
var _prediction_version: int = -1
var _prediction_delta: float = -1.0


func clear() -> void:
	active = false
	segment_count = 0
	_segments.clear()
	_owners.clear()
	_positions.clear()
	_ports.clear()
	_order.clear()
	_prediction_version = -1
	_topology = null


func prepare(topology: LogisticsTopology) -> bool:
	clear()
	work = 0
	_topology = topology
	var count: int = topology.machines.size()
	var indegrees: Array[int] = []
	indegrees.resize(count)
	_owners.resize(count)
	_owners.fill(-1)
	_positions.resize(count)
	_ports.resize(count)
	var pending: Array[int] = []
	for index: int in range(count):
		work += 1
		for port: int in range(3):
			if topology.inputs[index * 3 + port] >= 0:
				indegrees[index] += 1
				_ports[index] = port
		if indegrees[index] == 0:
			pending.append(index)
	var sorted: Array[int] = []
	var read: int = 0
	while read < pending.size():
		work += 1
		var index: int = pending[read]
		read += 1
		sorted.append(index)
		var target: int = topology.outgoing[index]
		if target >= 0:
			indegrees[target] -= 1
			if indegrees[target] == 0:
				pending.append(target)
	if sorted.size() != count:
		clear()
		return false
	for index: int in sorted:
		work += 1
		if _owners[index] >= 0:
			continue
		var segment: Segment = Segment.new()
		segment.belt = VoxelWorldData.is_belt(topology.machines[index].block)
		var next: int = index
		while next >= 0:
			work += 1
			_owners[next] = _segments.size()
			_positions[next] = segment.cells.size()
			segment.cells.append(next)
			var target: int = topology.outgoing[next]
			if not segment.belt or _input_count(index) > 1 or target < 0 \
				or not VoxelWorldData.is_belt(topology.machines[target].block) or _input_count(target) != 1:
				break
			next = target
		segment.cursor_marks.setup(segment.cells.size())
		_segments.append(segment)
		if segment.belt:
			segment_count += 1
			_prepare_runs(segment)
	# A functional DAG can visit each group once in reverse topological order.
	var seen: Dictionary[int, bool] = {}
	for cursor: int in range(sorted.size() - 1, -1, -1):
		var owner: int = _owners[sorted[cursor]]
		if not seen.has(owner):
			_order.append(owner)
			seen[owner] = true
	active = true
	return true


func _input_count(index: int) -> int:
	var count: int = 0
	for port: int in range(3):
		work += 1
		if _topology.inputs[index * 3 + port] >= 0:
			count += 1
	return count


func _prepare_runs(segment: Segment) -> void:
	# Capacity is fixed at the maximum occupancy of this chain. Consumption
	# and append wrap in place; a normal tick never copies the live queue.
	segment.identities.resize(segment.cells.size() * LogisticsData.BELT_CAPACITY)
	for position: int in range(segment.cells.size()):
		work += 1
		var index: int = segment.cells[position]
		var machine: LogisticsMachine = _topology.machines[index]
		var run: Run = Run.new()
		run.first = position
		run.end = position + 1
		run.quantity = machine.quantity
		run.eligible = machine.eligible_quantity
		run.last_output = machine.last_output_tick
		var predecessor: int = _topology.inputs[index * 3 + _ports[index]]
		if run.quantity > 0:
			run.head = machine.belt_ores[0].progress
			run.tail = machine.belt_ores[-1].progress
			if predecessor >= 0:
				var facing: Vector3i = _topology.machines[predecessor].settled_direction
				run.head_aligned = machine.belt_ores[0].incoming_direction == facing
				run.tail_aligned = machine.belt_ores[-1].incoming_direction == facing
		_append(segment.runs, run)
	for position: int in range(segment.cells.size() - 1, -1, -1):
		var machine: LogisticsMachine = _topology.machines[segment.cells[position]]
		for ore: LogisticsOre in machine.belt_ores:
			work += 1
			var identity: Identity = Identity.new()
			identity.ore = ore
			identity.origin = position
			segment.identities[segment.live_count] = identity
			segment.live_count += 1
		# Keep the borrowed array object for materialization after an edit.
		machine.belt_ores.clear()
	_prefix(segment.runs)


func advance_tick(tick: int, batch: LogisticsBatch) -> void:
	move_tick()
	var movement_work: int = work
	transfer_moved(tick, batch)
	work += movement_work


func move_tick() -> void:
	work = 0
	_move(LogisticsData.LOGIC_STEP, false)
	for segment: Segment in _segments:
		work += 1
		for run: Run in segment.moved:
			work += 1
			run.eligible = run.quantity


func accept_movement() -> int:
	for segment: Segment in _segments:
		if segment.belt:
			segment.runs = segment.moved
	return _segments.size()


func supplemental(tick: int, batch: LogisticsBatch) -> void:
	for segment: Segment in _segments:
		segment.moved = segment.runs
	transfer_moved(tick, batch, false)
	work += _segments.size()


func transfer_moved(tick: int, batch: LogisticsBatch, reset_eligibility: bool = true) -> void:
	work = 0
	var marks_before: int = _mark_work()
	for owner: int in _order:
		work += 1
		var segment: Segment = _segments[owner]
		segment.output = false
		segment.output_amount = 0
		segment.input_source = -1
		segment.input_amount = 0
		segment.incoming_ore = null
		if not segment.belt and reset_eligibility:
			var machine: LogisticsMachine = _topology.machines[segment.cells[0]]
			machine.eligible_quantity = machine.quantity
	# Decisions use pretransfer positions and downstream acceptance, before
	# any queue or inventory is changed. New arrivals cannot forward this tick.
	for owner: int in _order:
		var segment: Segment = _segments[owner]
		if segment.belt:
			_transfer_segment(segment, tick)
		else:
			_transfer_inventory(segment, tick)
	for segment: Segment in _segments:
		work += 1
		if not segment.belt:
			var machine: LogisticsMachine = _topology.machines[segment.cells[0]]
			machine.quantity -= segment.output_amount
			machine.eligible_quantity -= segment.output_amount
			if segment.output_amount > 0:
				machine.last_output_tick = tick
		elif segment.output:
			var identity: Identity = segment.identities[segment.read]
			var target: int = _topology.outgoing[segment.cells[-1]]
			_segments[_owners[target]].incoming_ore = identity.ore
			segment.identities[segment.read] = null
			segment.read = (segment.read + 1) % segment.identities.size()
			segment.live_count -= 1
	for segment: Segment in _segments:
		work += 1
		if segment.input_source < 0:
			continue
		if not segment.belt:
			_topology.machines[segment.cells[0]].quantity += segment.input_amount
			segment.incoming_ore = null
			continue
		var incoming: Vector3i = _topology.machines[segment.input_source].settled_direction
		var ore: LogisticsOre = segment.incoming_ore
		if ore == null:
			ore = LogisticsOre.new(0, incoming)
			batch.created_ores[_topology.cells[segment.cells[0]]] = ore
		ore.incoming_direction = incoming
		var identity: Identity = Identity.new()
		identity.ore = ore
		identity.origin = 0
		assert(segment.live_count < segment.identities.size())
		segment.identities[(segment.read + segment.live_count) % segment.identities.size()] = identity
		segment.live_count += 1
		segment.incoming_ore = null
	work += _mark_work() - marks_before
	_prediction_version = -1


func _move(delta: float, prediction: bool) -> void:
	var movement: float = delta / LogisticsData.BELT_TRAVEL_TIME
	for owner: int in _order:
		work += 1
		var segment: Segment = _segments[owner]
		if not segment.belt:
			continue
		var result: Array[Run] = []
		var target: int = _topology.outgoing[segment.cells[-1]]
		var old_next: Run
		var moved_next: Run
		var aligned: bool = false
		if target >= 0 and _segments[_owners[target]].belt:
			var next_segment: Segment = _segments[_owners[target]]
			old_next = next_segment.runs[0]
			moved_next = (next_segment.predicted if prediction else next_segment.moved)[0]
			aligned = old_next.quantity > 0 and _incoming(target, old_next.quantity - 1) \
				== _topology.machines[segment.cells[-1]].settled_direction
		for cursor: int in range(segment.runs.size() - 1, -1, -1):
			work += 1
			run_visits += 1
			var old: Run = segment.runs[cursor]
			var last: Run = _move_cell(old, old_next, moved_next, aligned, movement, old.end - 1)
			_append_reverse(result, last)
			var stop: int = old.end - 1
			# In an equal run, the second cell reaches the fixed point for a
			# two-ore queue. A single ore needs at most two .5 spacing steps.
			if stop > old.first:
				var second: Run = _move_cell(old, old, last, old.tail_aligned, movement, stop - 1)
				_append_reverse(result, second)
				stop -= 1
				if stop > old.first:
					var rest: Run = _move_cell(old, old, second, old.tail_aligned, movement, stop - 1)
					rest.first = old.first
					_append_reverse(result, rest)
			old_next = old
			moved_next = result[-1]
			aligned = old.tail_aligned
		result.reverse()
		_prefix(result)
		if prediction:
			segment.predicted = result
		else:
			segment.moved = result


func _move_cell(old: Run, next: Run, moved_next: Run, aligned: bool, movement: float, position: int) -> Run:
	work += 1
	var result: Run = old.copy_range(position, position + 1)
	if old.quantity == 0:
		return result
	result.head = minf(old.head + movement, 1.0)
	var desired_tail: float = minf(old.tail + movement, result.head - 0.5) if old.quantity == 2 else result.head
	if next != null and next.quantity > 0 and aligned and old.head <= next.tail + 0.5 + 1e-9:
		result.head = minf(result.head, moved_next.tail + 0.5)
	result.tail = minf(desired_tail, result.head - 0.5) if old.quantity == 2 else result.head
	return result


func _transfer_segment(segment: Segment, tick: int) -> void:
	var last_index: int = segment.cells[-1]
	# Downstream groups have already selected this segment's external output.
	var outgoing: bool = segment.output
	var target_cursor: int = segment.moved.size() - 1
	var source_cursor: int = target_cursor
	var position: int = segment.cells.size()
	var result: Array[Run] = []
	while position > 1:
		work += 1
		run_visits += 1
		var target: Run = segment.moved[target_cursor]
		while segment.moved[source_cursor].first > position - 2:
			source_cursor -= 1
			work += 1
		var source: Run = segment.moved[source_cursor]
		var first: int = maxi(1, maxi(target.first, source.first + 1))
		var candidate: bool = source.eligible > 0 and source.last_output != tick and source.head >= 1.0 - 1e-9 \
			and (target.quantity == 0 or target.tail >= 0.5 - 1e-9)
		var incoming: bool = candidate and (target.quantity < 2 or outgoing)
		_append_reverse(result, _commit_run(segment, target, position - 1, position, outgoing, incoming, tick, 4))
		position -= 1
		outgoing = incoming
		if position > first:
			incoming = candidate and (target.quantity < 2 or outgoing)
			_append_reverse(result, _commit_run(segment, target, first, position, outgoing, incoming, tick, 4))
			position = first
			outgoing = incoming
		if position == target.first:
			target_cursor -= 1
	var first_run: Run = segment.moved[0]
	var port: int = _select_input(segment.cells[0], first_run, tick)
	var source: int = _topology.inputs[segment.cells[0] * 3 + port] if port >= 0 else -1
	var incoming: bool = source >= 0 and (first_run.quantity < 2 or outgoing)
	if incoming:
		segment.input_source = source
		segment.input_amount = 1
		_accept_output(source, 1)
	_append_reverse(result, _commit_run(segment, first_run, 0, 1, outgoing, incoming, tick, (port + 1) % 3))
	result.reverse()
	_prefix(result)
	segment.runs = result
	# External output metadata is covered by the last cell's outgoing flag.
	if segment.output:
		assert(_topology.outgoing[last_index] >= 0)


func _commit_run(segment: Segment, old: Run, first: int, end: int, outgoing: bool, incoming: bool, tick: int, cursor: int) -> Run:
	work += 1
	var result: Run = old.copy_range(first, end)
	result.eligible = old.eligible - int(outgoing)
	var remaining: int = old.quantity - int(outgoing)
	result.quantity = remaining + int(incoming)
	if outgoing:
		result.last_output = tick
		result.head = old.tail if old.quantity == 2 else 0.0
		result.head_aligned = old.tail_aligned if old.quantity == 2 else false
	if incoming:
		segment.cursor_marks.assign_range(first, end, cursor)
		if remaining == 0:
			result.head = 0.0
			result.head_aligned = true
		result.tail = 0.0
		result.tail_aligned = true
		internal_transfers += end - maxi(first, 1)
	else:
		result.tail = result.head
		result.tail_aligned = result.head_aligned
		if result.quantity == 2:
			result.tail = old.tail
			result.tail_aligned = old.tail_aligned
	if result.quantity == 0:
		result.head = 0.0
		result.tail = 0.0
		result.head_aligned = false
		result.tail_aligned = false
	return result


func _select_input(index: int, target: Run, tick: int) -> int:
	if target.quantity > 0 and target.tail < 0.5 - 1e-9:
		return -1
	var cursor: int = _cursor(index)
	for offset: int in range(3):
		work += 1
		var port: int = (cursor + offset) % 3
		var source: int = _topology.inputs[index * 3 + port]
		if source < 0:
			continue
		if _available(source, tick) > 0:
			return port
		if _segments[_owners[source]].belt and _segments[_owners[source]].moved[-1].quantity > 0:
			break
	return -1


func _available(index: int, tick: int) -> int:
	work += 1
	var segment: Segment = _segments[_owners[index]]
	if segment.belt:
		var run: Run = segment.moved[-1]
		return 1 if run.eligible > 0 and run.last_output != tick and run.head >= 1.0 - 1e-9 else 0
	var machine: LogisticsMachine = _topology.machines[index]
	return machine.eligible_quantity if machine.last_output_tick != tick else 0


func _accept_output(source: int, amount: int) -> void:
	var segment: Segment = _segments[_owners[source]]
	segment.output = true
	segment.output_amount = amount


func _transfer_inventory(segment: Segment, tick: int) -> void:
	work += 1
	var index: int = segment.cells[0]
	if _topology.machines[index].block != VoxelWorldData.Block.CHEST:
		return
	var source: int = _topology.inputs[index * 3]
	if source < 0:
		return
	var amount: int = _available(source, tick)
	if amount > 0:
		segment.input_source = source
		segment.input_amount = amount
		_accept_output(source, amount)


func _prefix(runs: Array[Run]) -> void:
	var count: int = 0
	for cursor: int in range(runs.size() - 1, -1, -1):
		work += 1
		runs[cursor].downstream_ores = count
		count += runs[cursor].quantity * (runs[cursor].end - runs[cursor].first)


static func _append(runs: Array[Run], run: Run) -> void:
	if not runs.is_empty() and runs[-1].end == run.first and runs[-1].same(run):
		runs[-1].end = run.end
	else:
		runs.append(run)


static func _append_reverse(runs: Array[Run], run: Run) -> void:
	if not runs.is_empty() and runs[-1].first == run.end and runs[-1].same(run):
		runs[-1].first = run.first
	else:
		runs.append(run)


func _run_at(runs: Array[Run], position: int) -> Run:
	var low: int = 0
	var high: int = runs.size()
	while low + 1 < high:
		work += 1
		var middle: int = (low + high) / 2
		if runs[middle].first <= position:
			low = middle
		else:
			high = middle
	work += 1
	return runs[low]


func _identity_at(segment: Segment, run: Run, position: int, slot: int) -> Identity:
	var rank: int = run.downstream_ores + (run.end - position - 1) * run.quantity + slot
	assert(rank < segment.live_count)
	return segment.identities[(segment.read + rank) % segment.identities.size()]


func _incoming(index: int, slot: int) -> Vector3i:
	var segment: Segment = _segments[_owners[index]]
	var position: int = _positions[index]
	var run: Run = _run_at(segment.runs, position)
	var identity: Identity = _identity_at(segment, run, position, slot)
	if position == identity.origin:
		return identity.ore.incoming_direction
	return _topology.machines[segment.cells[position - 1]].settled_direction


func _cursor(index: int) -> int:
	var segment: Segment = _segments[_owners[index]]
	var mark: int = segment.cursor_marks.at(_positions[index])
	return (_ports[index] + 1) % 3 if mark == 4 else \
		(_topology.machines[index].input_cursor if mark == -2 else mark)


func quantity(index: int) -> int:
	var segment: Segment = _segments[_owners[index]]
	return _run_at(segment.runs, _positions[index]).quantity if segment.belt else _topology.machines[index].quantity


func total_ore() -> int:
	var total: int = 0
	for segment: Segment in _segments:
		total += segment.live_count if segment.belt else _topology.machines[segment.cells[0]].quantity
	return total


func live_stats() -> Dictionary[String, int]:
	var result: Dictionary[String, int] = {
		"pure_segment_count": segment_count,
		"pure_segment_runs": 0, "pure_segment_prediction_runs": 0,
		"pure_segment_identity_count": 0, "pure_segment_identity_capacity": 0,
	}
	for segment: Segment in _segments:
		result["pure_segment_runs"] += segment.runs.size()
		result["pure_segment_prediction_runs"] += segment.predicted.size()
		result["pure_segment_identity_count"] += segment.live_count
		result["pure_segment_identity_capacity"] += segment.identities.size()
	return result


func save_row(index: int) -> Dictionary:
	var machine: LogisticsMachine = _topology.machines[index]
	var row: Dictionary = machine.save_state()
	var segment: Segment = _segments[_owners[index]]
	if not segment.belt:
		return row
	var position: int = _positions[index]
	var run: Run = _run_at(segment.runs, position)
	row["quantity"] = run.quantity
	row["eligible"] = run.eligible
	row["cursor"] = _cursor(index)
	row["last_output"] = run.last_output
	var ores: Array[Dictionary] = []
	for slot: int in range(run.quantity):
		work += 1
		var identity: Identity = _identity_at(segment, run, position, slot)
		ores.append({"id": identity.ore.id, "incoming": _incoming(index, slot),
			"progress": run.head if slot == 0 else run.tail})
	row["ores"] = ores
	return row


func refresh_prediction(queue: LogisticsOreQueue, index: int, predicted: bool = false) -> int:
	var machine: LogisticsMachine = _topology.machines[index]
	var segment: Segment = _segments[_owners[index]]
	if not segment.belt:
		return queue.refresh_prediction(machine, _topology.cells[index])
	var position: int = _positions[index]
	var run: Run = _run_at(segment.runs, position)
	var positions: Run = _run_at(segment.predicted, position) if predicted else run
	var created: int = queue.resize_prediction(run.quantity)
	queue.cell = _topology.cells[index]
	queue.block = machine.block
	queue.direction = machine.settled_direction
	for slot: int in range(run.quantity):
		work += 1
		queue.ores[slot].id = _identity_at(segment, run, position, slot).ore.id
		queue.ores[slot].incoming_direction = _incoming(index, slot)
		queue.ores[slot].progress = positions.head if slot == 0 else positions.tail
	return created


func prepare_prediction(version: int, delta: float) -> bool:
	var before: int = work
	if _prediction_version == version and _prediction_delta == delta:
		prediction_work = 0
		return false
	_move(delta, true)
	prediction_work = work - before
	_prediction_version = version
	_prediction_delta = delta
	return true


func write_row(bytes: PackedByteArray, global_index: int, index: int) -> void:
	var row: Dictionary = save_row(index)
	var machine: LogisticsMachine = _topology.machines[index]
	LogisticsPacked.write_row(bytes, global_index, _topology.cells[index], machine)
	# Preserve the format and phase fields without mutating authoritative machines.
	var offset: int = global_index * LogisticsPacked.ROW_SIZE
	bytes[offset + 15] = row["cursor"]
	var count: int = row["quantity"]
	var eligible: int = row["eligible"]
	var output: int = row["last_output"]
	bytes.encode_s64(offset + 16, count)
	bytes.encode_s64(offset + 24, eligible)
	bytes.encode_s64(offset + 32, output)
	var ores: Array = row["ores"]
	bytes[offset + 80] = ores.size()
	for slot: int in range(ores.size()):
		var ore: Dictionary = ores[slot]
		var ore_offset: int = offset + 88 + slot * 24
		var ore_id: int = ore["id"]
		var progress: float = ore["progress"]
		bytes.encode_s64(ore_offset, ore_id)
		bytes[ore_offset + 8] = LogisticsPacked.DIRECTIONS.find(ore["incoming"])
		bytes.encode_double(ore_offset + 16, progress)


func materialize() -> int:
	var before: int = work
	var marks_before: int = _mark_work()
	for segment: Segment in _segments:
		work += 1
		if not segment.belt:
			continue
		for index: int in segment.cells:
			work += 1
			materialized_cells += 1
			var row: Dictionary = save_row(index)
			var machine: LogisticsMachine = _topology.machines[index]
			machine.quantity = row["quantity"]
			machine.eligible_quantity = row["eligible"]
			machine.input_cursor = row["cursor"]
			machine.last_output_tick = row["last_output"]
			var ores: Array = row["ores"]
			for ore: Dictionary in ores:
				work += 1
				var ore_id: int = ore["id"]
				var incoming: Vector3i = ore["incoming"]
				var restored: LogisticsOre = LogisticsOre.new(ore_id, incoming)
				restored.progress = ore["progress"]
				machine.belt_ores.append(restored)
	work += _mark_work() - marks_before
	var expanded_work: int = work - before
	materialize_work += expanded_work
	clear()
	return expanded_work


func _mark_work() -> int:
	var total: int = 0
	for segment: Segment in _segments:
		work += 1
		total += segment.cursor_marks.work
	return total


func accepts_edges(index: int) -> bool:
	work += 1
	var segment: Segment = _segments[_owners[index]]
	var position: int = _positions[index]
	if position + 1 < segment.cells.size() and _topology.outgoing[index] != segment.cells[position + 1]:
		return false
	var count: int = 0
	for port: int in range(3):
		work += 1
		var source: int = _topology.inputs[index * 3 + port]
		if source < 0:
			continue
		count += 1
		if position > 0:
			if source != segment.cells[position - 1]:
				return false
		elif _positions[source] != _segments[_owners[source]].cells.size() - 1:
			return false
	if position > 0 and count != 1:
		return false
	return true


func refresh_boundaries() -> bool:
	# Internal edges were checked only at edited neighbors. Visit group
	# boundaries here; disconnected groups can retain the same scheduler.
	var previous_work: int = work
	var indegrees: Array[int] = []
	indegrees.resize(_segments.size())
	var targets: Array[int] = []
	targets.resize(_segments.size())
	targets.fill(-1)
	for owner: int in range(_segments.size()):
		work += 1
		var segment: Segment = _segments[owner]
		var target: int = _topology.outgoing[segment.cells[-1]]
		if target >= 0:
			if _positions[target] != 0:
				work -= previous_work
				return false
			targets[owner] = _owners[target]
			indegrees[_owners[target]] += 1
	var pending: Array[int] = []
	for owner: int in range(_segments.size()):
		work += 1
		if indegrees[owner] == 0:
			pending.append(owner)
	var sorted: Array[int] = []
	var read: int = 0
	while read < pending.size():
		work += 1
		var owner: int = pending[read]
		read += 1
		sorted.append(owner)
		var target: int = targets[owner]
		if target >= 0:
			indegrees[target] -= 1
			if indegrees[target] == 0:
				pending.append(target)
	if sorted.size() != _segments.size():
		work -= previous_work
		return false
	sorted.reverse()
	_order = sorted
	for segment: Segment in _segments:
		work += 1
		var index: int = segment.cells[0]
		for port: int in range(3):
			work += 1
			if _topology.inputs[index * 3 + port] >= 0:
				_ports[index] = port
		if segment.belt:
			var predecessor: int = _topology.inputs[index * 3 + _ports[index]]
			var head_aligned: bool = predecessor >= 0 and segment.runs[0].quantity > 0 \
				and _incoming(index, 0) == _topology.machines[predecessor].settled_direction
			var tail_aligned: bool = predecessor >= 0 and segment.runs[0].quantity > 0 \
				and _incoming(index, segment.runs[0].quantity - 1) == _topology.machines[predecessor].settled_direction
			_refresh_alignment(segment.runs, head_aligned, tail_aligned)
			if not segment.moved.is_empty() and segment.moved != segment.runs:
				_refresh_alignment(segment.moved, head_aligned, tail_aligned)
	_prediction_version = -1
	work -= previous_work
	return true


func _refresh_alignment(runs: Array[Run], head_aligned: bool, tail_aligned: bool) -> void:
	work += 1
	var original: Run = runs[0]
	if original.head_aligned == head_aligned and original.tail_aligned == tail_aligned:
		return
	var first: Run = original.copy_range(0, 1)
	first.head_aligned = head_aligned
	first.tail_aligned = tail_aligned
	if original.end > 1:
		# Shallow copies may share Run objects with the authoritative array.
		runs[0] = original.copy_range(1, original.end)
		runs.push_front(first)
	else:
		runs[0] = first
	_prefix(runs)
