extends RefCounted
## Host geometry and device metadata only. All live belt queues belong to Rust.
## Loading and explicit edits rebuild a staged network; ordinary ticks visit devices.

const SPEED: float = 1.0
const SPACING: float = 0.25
const IDENTITY_LIMIT: int = SnapshotValues.MAX_INTEGER - 1

var error: String = ""
var work: int = 0
var prepare_usec: int = 0
var binding_usec: int = 0
var settle_usec: int = 0
var sample_usec: int = 0
var map_usec: int = 0
var core_ns: int = 0
var core_visited_nodes: int = 0
var segment_count: int = 0
var _network: Object
var _keys: PackedInt64Array = PackedInt64Array()
var _starts: PackedFloat64Array = PackedFloat64Array()
var _lengths: PackedFloat64Array = PackedFloat64Array()
var _input_slots: PackedInt32Array = PackedInt32Array()
var _segments: Dictionary[int, float] = {}
var _producers: Dictionary[int, int] = {}
var _consumers: Dictionary[int, int] = {}
var _devices: Array[int] = []
var _direct: Array[int] = []
var _last_stats: Dictionary = {}
var _incoming: Dictionary[int, Vector3i] = {}
var _links: PackedInt64Array = PackedInt64Array()
var _binding: Dictionary = {}
var _forced_heads: Dictionary[int, bool] = {}
var _pending_links: PackedInt64Array = PackedInt64Array()
var _port_sources: Dictionary[int, int] = {}
var _segment_specs: PackedInt64Array = PackedInt64Array()
var _port_directions: Dictionary[int, Vector3i] = {}
var _display_ready: bool = false
var _display_error: String = ""
var _display_bind_usec: int = 0
var _display_bind_count: int = 0
var _display_queries: int = 0
var _display_query_ns: int = 0
var _display_xyz_ns: int = 0


func prepare(topology: LogisticsTopology, identity_floor: int = 1, tick: int = 0, binding: Dictionary = {}) -> bool:
	_display_ready = false
	if not ClassDB.class_exists("RustConveyorNetwork"):
		error = "RustConveyor native library is not installed."
		return false
	_network = ClassDB.instantiate("RustConveyorNetwork")
	if not _accept(_network.call("configure", SPEED, LogisticsData.LOGIC_STEP, SPACING)):
		return false
	# Keep MAX_INTEGER available as the host's exhausted next-ID sentinel.
	if not _accept(_network.call("set_identity_limit", IDENTITY_LIMIT)):
		return false
	if not _accept(_network.call("initialize_clock", tick, identity_floor - 1)):
		return false
	var count: int = topology.machines.size()
	_keys.resize(count)
	_keys.fill(0)
	_starts.resize(count)
	_lengths.resize(count)
	_input_slots.resize(count * 3)
	_input_slots.fill(-1)
	var saved_pending: PackedInt64Array = PackedInt64Array()
	if not binding.is_empty():
		if not binding.get("keys") is PackedInt64Array or not binding.get("pending") is PackedInt64Array:
			error = "Invalid host geometry binding."
			return false
		var saved_keys: PackedInt64Array = binding["keys"]
		saved_pending = binding["pending"]
		if saved_keys.size() != count or saved_pending.size() % 4 != 0:
			error = "Invalid host geometry binding."
			return false
		for index: int in range(count):
			if saved_keys[index] == index + 1:
				_forced_heads[index] = true
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(count)
	visited.fill(0)
	var heads: Array[int] = []
	for index: int in range(count):
		var machine: LogisticsMachine = topology.machines[index]
		_lengths[index] = belt_length(machine.block) if VoxelWorldData.is_belt(machine.block) else 0.0
		if not VoxelWorldData.is_belt(machine.block):
			_devices.append(index)
			continue
		var predecessors: int = 0
		var previous: int = -1
		for port: int in range(3):
			var source: int = topology.inputs[index * 3 + port]
			if source >= 0:
				predecessors += 1
				previous = source
		if predecessors != 1 or not VoxelWorldData.is_belt(topology.machines[previous].block) or (
			_forced_heads.has(index) or not _can_compress(topology, previous, index)
		):
			heads.append(index)
	# Pure cycles have no head; break them at a deterministic facility.
	for head: int in heads:
		if not _build_segment(topology, head, visited):
			return false
	for index: int in range(count):
		if _lengths[index] > 0.0 and visited[index] == 0:
			# The core rejects a segment linked to itself. Two explicit ends
			# retain a compressed long ring without one segment per belt.
			_forced_heads[index] = true
			var next: int = topology.outgoing[index]
			if next >= 0:
				_forced_heads[next] = true
			if not _build_segment(topology, index, visited):
				return false
			if next >= 0 and not _build_segment(topology, next, visited):
				return false
	for target: int in range(count):
		if _keys[target] == 0 or _starts[target] != 0.0:
			continue
		var slot: int = 0
		for port: int in range(3):
			var source: int = topology.inputs[target * 3 + port]
			if source < 0:
				continue
			_input_slots[target * 3 + port] = slot
			_port_sources[_device_key(_keys[target], slot)] = source
			_port_directions[_device_key(_keys[target], slot)] = topology.machines[source].settled_direction
			if _keys[source] > 0:
				var edge: PackedInt64Array = PackedInt64Array([_keys[source], 0, _keys[target], slot])
				var wait: bool = not _can_compress(topology, source, target)
				if not binding.is_empty():
					wait = false
					for row: int in range(0, saved_pending.size(), 4):
						if saved_pending.slice(row, row + 4) == edge:
							wait = true
				if wait:
					_pending_links.append_array(edge)
				elif not _accept(_network.call("link_segments", _keys[source], 0, _keys[target], slot)):
					return false
			else:
				_producers[_device_key(_keys[target], slot)] = source
			slot += 1
	for source: int in range(count):
		var target: int = topology.outgoing[source]
		if _keys[source] > 0 and (target < 0 or _keys[target] == 0):
			if target >= 0:
				_consumers[_keys[source]] = target
		elif _keys[source] == 0 and target >= 0 and _keys[target] == 0:
			_direct.append(source)
	segment_count = _segments.size()
	_last_stats = _network.call("stats")
	var layout: Dictionary = _network.call("layout")
	_links = layout["links"]
	_segment_specs = layout.get("segment_specs", PackedInt64Array())
	var geometry: PackedInt32Array = PackedInt32Array()
	for index: int in range(count):
		var machine: LogisticsMachine = topology.machines[index]
		var cell: Vector3i = topology.cells[index]
		var direction: Vector3i = machine.settled_direction
		geometry.append_array(PackedInt32Array([cell.x, cell.y, cell.z, machine.block,
			direction.x, direction.y, direction.z]))
	_binding = {"keys": _keys.duplicate(), "starts": _starts.duplicate(),
		"lengths": _lengths.duplicate(), "geometry": geometry, "pending": _pending_links.duplicate()}
	if not binding.is_empty() and binding != _binding:
		error = "Checkpoint path pieces do not match the ordered host geometry."
		return false
	return true


func _build_segment(topology: LogisticsTopology, head: int, visited: PackedByteArray) -> bool:
	if visited[head] != 0:
		return true
	var members: Array[int] = []
	var cursor: int = head
	var length: float = 0.0
	var key: int = head + 1
	while cursor >= 0 and visited[cursor] == 0 and _lengths[cursor] > 0.0:
		visited[cursor] = 1
		_keys[cursor] = key
		_starts[cursor] = length
		length += _lengths[cursor]
		members.append(cursor)
		var target: int = topology.outgoing[cursor]
		if target < 0 or _lengths[target] == 0.0:
			break
		var inputs: int = 0
		for port: int in range(3):
			inputs += 1 if topology.inputs[target * 3 + port] >= 0 else 0
		if inputs != 1 or _forced_heads.has(target) or not _can_compress(topology, cursor, target):
			break
		cursor = target
	if members.size() > 1 and topology.outgoing[members[-1]] == head:
		# A loop may also begin at a merge fed by an external device.
		# Leave its last cell as the second segment instead of self-linking.
		var tail: int = members.pop_back()
		length = _starts[tail]
		visited[tail] = 0
		_keys[tail] = 0
		_starts[tail] = 0.0
	var ids: PackedInt64Array = PackedInt64Array()
	var distances: PackedFloat64Array = PackedFloat64Array()
	var corrections: PackedFloat64Array = PackedFloat64Array()
	var pending: float = 0.0
	var pending_correction: float = 0.0
	for ordinal: int in range(members.size() - 1, -1, -1):
		var index: int = members[ordinal]
		var previous_progress: float = 1.0
		for ore: LogisticsOre in topology.machines[index].belt_ores:
			var amount: float = (previous_progress - ore.progress) * _lengths[index]
			var sum: float = pending + amount
			var part: float = sum - pending
			var low: float = pending_correction + (pending - (sum - part)) + (amount - part)
			var main: float = sum + low
			ids.append(ore.id)
			distances.append(main)
			corrections.append(low - (main - sum))
			pending = 0.0
			pending_correction = 0.0
			previous_progress = ore.progress
			if index == head:
				_incoming[ore.id] = ore.incoming_direction
		var amount: float = previous_progress * _lengths[index]
		var sum: float = pending + amount
		var part: float = sum - pending
		var low: float = pending_correction + (pending - (sum - part)) + (amount - part)
		pending = sum + low
		pending_correction = low - (pending - sum)
	var ports: int = 0
	for port: int in range(3):
		ports += 1 if topology.inputs[head * 3 + port] >= 0 else 0
	if not _accept(_network.call("add_segment_gaps", key, length, ids, distances, corrections, maxi(1, ports), 1)):
		error += " (segment=%d length=%.17f items=%d)" % [key, length, ids.size()]
		return false
	_segments[key] = length
	return true


func _can_compress(topology: LogisticsTopology, source: int, target: int) -> bool:
	if source < 0 or not VoxelWorldData.is_belt(topology.machines[source].block):
		return false
	var upstream: Array[LogisticsOre] = topology.machines[source].belt_ores
	var downstream: Array[LogisticsOre] = topology.machines[target].belt_ores
	if upstream.is_empty() or downstream.is_empty():
		return true
	# Disconnected queues may legally overlap when their ports are reconnected.
	# Keeping the seam allows normal native spacing constraints to clear it.
	return (1.0 - upstream[0].progress) * belt_length(topology.machines[source].block) + (
		downstream[-1].progress * belt_length(topology.machines[target].block)
	) >= SPACING


func advance_tick(topology: LogisticsTopology, tick: int) -> bool:
	if not error.is_empty():
		return false
	var started: int = Time.get_ticks_usec()
	if not _activate_pending():
		return false
	var producers: PackedInt64Array = PackedInt64Array()
	var consumers: PackedInt64Array = PackedInt64Array()
	var staged: Dictionary[int, LogisticsMachine] = {}
	work = _devices.size() + _producers.size() + _consumers.size()
	for index: int in _devices:
		var original: LogisticsMachine = topology.machines[index]
		var pending: LogisticsMachine = LogisticsMachine.new(original.block, original._placed_at,
			original.interval, original.amount)
		pending.quantity = original.quantity
		pending._produced_cycles = original._produced_cycles
		pending.next_production = original.next_production
		pending.produce_until(float(tick) * LogisticsData.LOGIC_STEP)
		staged[index] = pending
	for port_key: int in _producers:
		var index: int = _producers[port_key]
		producers.append_array(PackedInt64Array([port_key / 4, port_key % 4,
			1 if staged[index].quantity > 0 else 0, 1]))
	for key: int in _consumers:
		consumers.append_array(PackedInt64Array([key, 0, 1, 1]))
	prepare_usec = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var frame: Dictionary = _network.call("tick", producers, consumers)
	binding_usec = Time.get_ticks_usec() - started
	if not _accept(frame):
		return false
	core_ns = frame["total_ns"]
	core_visited_nodes = frame.get("visited_nodes", 0)
	_last_stats = frame["stats"]
	started = Time.get_ticks_usec()
	var produced: PackedInt64Array = frame["produced"]
	var consumed: PackedInt64Array = frame["consumed"]
	var transferred: PackedInt64Array = frame.get("transferred", PackedInt64Array())
	for index: int in _devices:
		var machine: LogisticsMachine = topology.machines[index]
		machine.quantity = staged[index].quantity
		machine.eligible_quantity = machine.quantity
		machine._produced_cycles = staged[index]._produced_cycles
		machine.next_production = staged[index].next_production
	for row: int in range(0, produced.size(), 3):
		var source: int = _producers[_device_key(produced[row], produced[row + 1])]
		topology.machines[source].quantity -= 1
		topology.machines[source].eligible_quantity -= 1
		topology.machines[source].last_output_tick = tick
		_incoming[produced[row + 2]] = topology.machines[source].settled_direction
	for row: int in range(0, transferred.size(), 5):
		var source: int = _port_sources[_device_key(transferred[row + 2], transferred[row + 3])]
		_incoming[transferred[row + 4]] = topology.machines[source].settled_direction
	for row: int in range(0, consumed.size(), 3):
		topology.machines[_consumers[consumed[row]]].quantity += 1
		_incoming.erase(consumed[row + 2])
	# Eligibility is fixed before native arrivals; inventory edges move a batch.
	var targets: Dictionary[int, bool] = {}
	for source: int in _direct:
		targets[topology.outgoing[source]] = true
	var arrivals: Dictionary[int, int] = {}
	for target: int in targets:
		var receiver: LogisticsMachine = topology.machines[target]
		for offset: int in range(3):
			var port: int = (receiver.input_cursor + offset) % 3
			var source: int = topology.inputs[target * 3 + port]
			if source < 0 or _keys[source] > 0:
				continue
			var sender: LogisticsMachine = topology.machines[source]
			if sender.eligible_quantity <= 0 or sender.last_output_tick == tick:
				continue
			arrivals[target] = sender.eligible_quantity
			sender.quantity -= sender.eligible_quantity
			sender.eligible_quantity = 0
			sender.last_output_tick = tick
			receiver.input_cursor = (port + 1) % 3
			break
	for target: int in arrivals:
		topology.machines[target].quantity += arrivals[target]
	settle_usec = Time.get_ticks_usec() - started
	return true


func _activate_pending() -> bool:
	if _pending_links.is_empty():
		return true
	var waiting: PackedInt64Array = PackedInt64Array()
	for row: int in range(0, _pending_links.size(), 4):
		var source: int = _pending_links[row]
		var target: int = _pending_links[row + 2]
		var exit_page: Dictionary = _network.call("sample_ranges", PackedInt64Array([source]),
			PackedFloat64Array([0.0]), PackedFloat64Array([_segments[source]]), 1)
		var entry_page: Dictionary = _network.call("sample_ranges", PackedInt64Array([target]),
			PackedFloat64Array([0.0]), PackedFloat64Array([SPACING]), 4)
		if not _accept(exit_page) or not _accept(entry_page):
			return false
		var upstream: PackedFloat64Array = exit_page["positions"]
		var downstream: PackedFloat64Array = entry_page["positions"]
		var gap: float = INF
		if not upstream.is_empty() and not downstream.is_empty():
			gap = _segments[source] - upstream[0] + downstream[-1]
		if gap < SPACING:
			waiting.append_array(_pending_links.slice(row, row + 4))
		else:
			var linked: Dictionary = _network.call("link_segments", source, 0, target, _pending_links[row + 3])
			if not linked.get("ok", false) and linked.get("error") == "InsufficientSpace":
				# Public f64 positions can round to the threshold while the
				# compensated native gap is still smaller. Native preflight
				# leaves this edge unchanged; wait for the next boundary.
				waiting.append_array(_pending_links.slice(row, row + 4))
			elif not _accept(linked):
				return false
			else:
				_display_ready = false
	_pending_links = waiting
	_binding["pending"] = waiting.duplicate()
	var layout: Dictionary = _network.call("layout")
	_links = layout["links"]
	return true


func quantity(index: int, topology: LogisticsTopology) -> int:
	if _keys[index] == 0:
		return topology.machines[index].quantity
	var result: Dictionary = _network.call("sample_ranges", PackedInt64Array([_keys[index]]),
		PackedFloat64Array([_starts[index]]), PackedFloat64Array([_starts[index] + _lengths[index]]), 0)
	if not _accept(result):
		return 0
	var required: PackedInt64Array = result["required"]
	return required[0]


func total(topology: LogisticsTopology) -> int:
	var count: int = _last_stats.get("items", 0)
	for index: int in _devices:
		count += topology.machines[index].quantity
	return count


func sample(indices: Array[int], topology: LogisticsTopology) -> Array[LogisticsOreQueue]:
	var keys: PackedInt64Array = PackedInt64Array()
	var starts: PackedFloat64Array = PackedFloat64Array()
	var ends: PackedFloat64Array = PackedFloat64Array()
	var belt_indices: Array[int] = []
	var result: Array[LogisticsOreQueue] = []
	for index: int in indices:
		if _keys[index] > 0:
			keys.append(_keys[index])
			starts.append(_starts[index])
			ends.append(_starts[index] + _lengths[index])
			belt_indices.append(result.size())
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.cell = topology.cells[index]
		queue.direction = topology.machines[index].settled_direction
		queue.block = topology.machines[index].block
		result.append(queue)
	if keys.is_empty():
		return result
	var started: int = Time.get_ticks_usec()
	var page: Dictionary = _network.call("sample_ranges", keys, starts, ends, 4)
	sample_usec = Time.get_ticks_usec() - started
	if not _accept(page):
		return []
	started = Time.get_ticks_usec()
	var ids: PackedInt64Array = page["ids"]
	var positions: PackedFloat64Array = page["positions"]
	var entry_slots: PackedInt64Array = page["entry_slots"]
	var offsets: PackedInt64Array = page["offsets"]
	for row: int in range(keys.size()):
		var queue: LogisticsOreQueue = result[belt_indices[row]]
		var index: int = indices[belt_indices[row]]
		var incoming: Vector3i = queue.direction
		for port: int in range(3):
			var source: int = topology.inputs[index * 3 + port]
			if source >= 0:
				incoming = topology.machines[source].settled_direction
				break
		for item: int in range(offsets[row], offsets[row + 1]):
			var direction: Vector3i = _incoming.get(ids[item], incoming) if _starts[index] == 0.0 else incoming
			if _starts[index] == 0.0 and entry_slots[item] >= 0:
				direction = _port_directions.get(_device_key(keys[row], entry_slots[item]), direction)
			var ore: LogisticsOre = LogisticsOre.new(ids[item], direction)
			ore.progress = (positions[item] - starts[row]) / _lengths[index]
			queue.ores.append(ore)
	map_usec = Time.get_ticks_usec() - started
	return result


func sample_display(indices: PackedInt64Array, topology: LogisticsTopology, offset: Vector3) -> Dictionary:
	## Only geometry changes rebuild this cache; committed ticks retain it.
	reset_display_stats()
	if not _display_ready and not _bind_display(topology):
		return {"ok": false, "error": _display_error}
	var started: int = Time.get_ticks_usec()
	var page: Dictionary = _network.call("sample_display_cells", indices, 4, offset)
	sample_usec = Time.get_ticks_usec() - started
	map_usec = 0
	if not page.get("ok", false):
		return page
	_display_queries = page["queries"]
	_display_query_ns = page["query_ns"]
	_display_xyz_ns = page["xyz_ns"]
	return page


func reset_display_stats() -> void:
	sample_usec = 0
	map_usec = 0
	_display_queries = 0
	_display_query_ns = 0
	_display_xyz_ns = 0


func _bind_display(topology: LogisticsTopology) -> bool:
	var started: int = Time.get_ticks_usec()
	var centers: PackedVector3Array = PackedVector3Array()
	var incoming: PackedVector3Array = PackedVector3Array()
	var outgoing: PackedVector3Array = PackedVector3Array()
	var ports: PackedVector3Array = PackedVector3Array()
	var rises: PackedFloat64Array = PackedFloat64Array()
	var count: int = topology.machines.size()
	centers.resize(count)
	incoming.resize(count)
	outgoing.resize(count)
	ports.resize(count * 3)
	rises.resize(count)
	for index: int in range(count):
		var cell: Vector3i = topology.cells[index]
		var machine: LogisticsMachine = topology.machines[index]
		var center: Vector3 = VoxelWorldData.cell_center(cell)
		center.y = float(cell.y) * VoxelWorldData.CELL_SIZE + VoxelWorldData.BELT_HEIGHT
		centers[index] = center
		outgoing[index] = Vector3(machine.settled_direction)
		incoming[index] = outgoing[index]
		for port: int in range(3):
			var source: int = topology.inputs[index * 3 + port]
			if source >= 0:
				incoming[index] = Vector3(topology.machines[source].settled_direction)
				break
		for slot: int in range(3):
			var port_direction: Vector3i = _port_directions.get(
				_device_key(_keys[index], slot), Vector3i.ZERO)
			ports[index * 3 + slot] = Vector3(port_direction)
		rises[index] = float(VoxelWorldData.slope_rise(machine.block)) * VoxelWorldData.CELL_SIZE
	var fallback_ids: PackedInt64Array = PackedInt64Array()
	var fallback_directions: PackedVector3Array = PackedVector3Array()
	for id: int in _incoming:
		fallback_ids.append(id)
		fallback_directions.append(Vector3(_incoming[id]))
	var page: Dictionary = _network.call("set_display_geometry", {
		"segments": _keys, "starts": _starts, "lengths": _lengths, "centers": centers,
		"incoming": incoming, "outgoing": outgoing, "ports": ports, "rises": rises,
		"span": VoxelWorldData.CELL_SIZE, "fallback_ids": fallback_ids,
		"fallback_directions": fallback_directions})
	_display_bind_usec += Time.get_ticks_usec() - started
	_display_bind_count += 1
	_display_ready = page.get("ok", false)
	_display_error = "" if _display_ready else str(page.get("error", "Invalid display geometry."))
	return _display_ready


func materialize(topology: LogisticsTopology) -> void:
	## Explicit O(world) edit boundary; never called by ticks or visible queries.
	var indices: Array[int] = []
	for index: int in range(topology.machines.size()):
		indices.append(index)
	var rows: Array[LogisticsOreQueue] = sample(indices, topology)
	for index: int in range(rows.size()):
		if _keys[index] > 0:
			topology.machines[index].belt_ores = rows[index].ores
			topology.machines[index].quantity = rows[index].ores.size()
			topology.machines[index].eligible_quantity = rows[index].ores.size()


func release_host_queues(topology: LogisticsTopology) -> void:
	for index: int in range(topology.machines.size()):
		if _keys[index] > 0:
			topology.machines[index].belt_ores.clear()
			topology.machines[index].quantity = 0
			topology.machines[index].eligible_quantity = 0


func snapshot() -> PackedByteArray:
	return _network.call("snapshot")


func restore(bytes: PackedByteArray, tick: int) -> bool:
	var staged: Object = ClassDB.instantiate("RustConveyorNetwork")
	if not _accept(staged.call("restore", bytes)):
		return false
	if not _accept(staged.call("set_identity_limit", IDENTITY_LIMIT)):
		return false
	var manifest: Dictionary = staged.call("layout")
	var layout: Dictionary = manifest.get("segments", {})
	if manifest.get("speed") != SPEED or manifest.get("dt") != LogisticsData.LOGIC_STEP or (
		manifest.get("minimum") != SPACING or layout != _segments or manifest.get("links") != _links
		or manifest.get("segment_specs") != _segment_specs
	):
		error = "Native checkpoint does not match host topology or transport settings."
		return false
	if not _validate_devices(manifest):
		error = "Native checkpoint contains undeclared device endpoints."
		return false
	var statistics: Dictionary = staged.call("stats")
	if statistics.get("frame") != tick:
		error = "Native checkpoint clock does not match host clock."
		return false
	_network = staged
	_display_ready = false
	_last_stats = statistics
	return true


func _validate_devices(manifest: Dictionary) -> bool:
	if not manifest.get("producers") is PackedInt64Array or not manifest.get("consumers") is PackedInt64Array:
		return false
	var producers: PackedInt64Array = manifest["producers"]
	var consumers: PackedInt64Array = manifest["consumers"]
	if producers.size() % 4 != 0 or consumers.size() % 4 != 0:
		return false
	var seen: Dictionary[int, bool] = {}
	for row: int in range(0, producers.size(), 4):
		var port: int = _device_key(producers[row], producers[row + 1])
		if not _producers.has(port) or seen.has(port) or producers[row + 2] not in [0, 1] or (
			producers[row + 3] != 1
		):
			return false
		seen[port] = true
	seen.clear()
	for row: int in range(0, consumers.size(), 4):
		var key: int = consumers[row]
		if not _consumers.has(key) or seen.has(key) or consumers[row + 1] != 0 or (
			consumers[row + 2] not in [0, 1] or consumers[row + 3] != 1
		):
			return false
		seen[key] = true
	return true


func last_identity() -> int:
	return _network.call("last_identity")


func save_incoming() -> Dictionary[int, Vector3i]:
	return _incoming.duplicate()


func save_binding() -> Dictionary:
	return _binding.duplicate(true)


func restore_incoming(rows: Dictionary) -> bool:
	var result: Dictionary[int, Vector3i] = {}
	for id: Variant in rows:
		if not SnapshotValues.integer(id, 1, last_identity()) or not SnapshotValues.direction(rows[id]):
			return false
		var location: Dictionary = _network.call("locate_item", id)
		if not location.get("ok", false):
			return false
		var route: Dictionary = _network.call("item_entry_route", id)
		if not route.get("ok", false):
			return false
		if route.get("known", false):
			var segment: int = route["segment"]
			var input: int = route["input"]
			if rows[id] != _port_directions.get(_device_key(segment, input), Vector3i.ZERO):
				return false
		result[id] = rows[id]
	_incoming = result
	_display_ready = false
	return true


func stats() -> Dictionary[String, int]:
	return {"rust_segments": segment_count, "rust_items": _last_stats.get("items", 0),
		"rust_produced": _last_stats.get("produced", 0),
		"rust_consumed": _last_stats.get("consumed", 0),
		"rust_transferred": _last_stats.get("transferred", 0),
		"rust_core_visited_nodes": core_visited_nodes,
		"rust_producer_ports": _producers.size(), "rust_consumer_ports": _consumers.size(),
		"rust_prepare_usec": prepare_usec, "rust_binding_usec": binding_usec,
		"rust_settle_usec": settle_usec, "rust_sample_usec": sample_usec,
		"rust_display_bind_usec": _display_bind_usec, "rust_display_bind_count": _display_bind_count,
		"rust_display_queries": _display_queries, "rust_display_query_ns": _display_query_ns,
		"rust_display_xyz_ns": _display_xyz_ns,
		"rust_map_usec": map_usec, "rust_core_ns": core_ns}


static func belt_length(block: int) -> float:
	return sqrt(0.5) if VoxelWorldData.is_slope(block) else 0.5


static func _device_key(key: int, slot: int) -> int:
	return key * 4 + slot


func _accept(value: Variant) -> bool:
	if value is Dictionary:
		var result: Dictionary = value
		if result.get("ok", false):
			return true
		error = result.get("error", "Native operation failed.")
		return false
	error = "Invalid native response."
	return false
