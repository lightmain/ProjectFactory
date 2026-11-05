class_name LogisticsMachine
extends RefCounted
## Mutable state owned exclusively by LogisticsData.

const MIN_INTERVAL: float = 0.001

var block: int
var direction: Vector3i = Vector3i.FORWARD
var quantity: int = 0
var interval: float
var amount: int
var next_production: float = INF
var input_cursor: int = 0
var belt_ores: Array[LogisticsOre] = []
var settled_direction: Vector3i = Vector3i.FORWARD
var eligible_quantity: int = 0
var last_output_tick: int = -1
var _placed_at: float
var _produced_cycles: int = 0


func save_state() -> Dictionary:
	var ores: Array[Dictionary] = []
	for ore: LogisticsOre in belt_ores:
		ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
	return {
		"block": block, "direction": direction, "settled": settled_direction,
		"quantity": quantity, "eligible": eligible_quantity, "last_output": last_output_tick,
		"interval": interval, "amount": amount, "next": next_production,
		"cursor": input_cursor, "placed": _placed_at, "cycles": _produced_cycles, "ores": ores,
	}


static func decode(state: Dictionary, time: float, tick: int) -> LogisticsMachine:
	if not SnapshotValues.integer(state.get("block"), 5, 7) or (
		not SnapshotValues.direction(state.get("direction"))
		or not SnapshotValues.direction(state.get("settled"))
		or not SnapshotValues.integer(state.get("quantity"), 0, SnapshotValues.MAX_INTEGER)
		or not SnapshotValues.integer(state.get("eligible"), 0, SnapshotValues.MAX_INTEGER)
		or not SnapshotValues.integer(state.get("last_output"), -1, tick)
		or not state.get("interval") is float
		or not SnapshotValues.integer(state.get("amount"), SnapshotValues.MIN_INTEGER, SnapshotValues.MAX_INTEGER)
		or not state.get("next") is float
		or not SnapshotValues.integer(state.get("cursor"), 0, 2)
		or not SnapshotValues.number(state.get("placed"), 0.0, time)
		or not SnapshotValues.integer(state.get("cycles"), 0, SnapshotValues.MAX_INTEGER)
		or not state.get("ores") is Array
	):
		return null
	var kind: int = state["block"]
	var placed: float = state["placed"]
	var mining_interval: float = state["interval"]
	var mining_amount: int = state["amount"]
	var result: LogisticsMachine = LogisticsMachine.new(kind, placed, mining_interval, mining_amount)
	result.direction = state["direction"]
	result.settled_direction = state["settled"]
	result.quantity = state["quantity"]
	result.eligible_quantity = state["eligible"]
	result.last_output_tick = state["last_output"]
	result.input_cursor = state["cursor"]
	result._produced_cycles = state["cycles"]
	result.next_production = state["next"]
	if result.eligible_quantity > result.quantity:
		return null
	if not result._valid_phase(float(tick) * LogisticsData.LOGIC_STEP):
		return null
	var rows: Array = state["ores"]
	if rows.size() > 2 or (result.block != VoxelWorldData.Block.BELT and not rows.is_empty()):
		return null
	var previous: float = 2.0
	for value: Variant in rows:
		if not value is Dictionary:
			return null
		var row: Dictionary = value
		if not SnapshotValues.integer(row.get("id"), 1, SnapshotValues.MAX_INTEGER) or (
			not SnapshotValues.direction(row.get("incoming"))
			or not SnapshotValues.number(row.get("progress"), 0.0, 1.0)
		):
			return null
		var ore_id: int = row["id"]
		var incoming: Vector3i = row["incoming"]
		var ore: LogisticsOre = LogisticsOre.new(ore_id, incoming)
		ore.progress = row["progress"]
		if previous < ore.progress + 0.5 - LogisticsData.TIME_EPSILON:
			return null
		previous = ore.progress
		result.belt_ores.append(ore)
	if result.block == VoxelWorldData.Block.BELT and result.quantity != rows.size():
		return null
	return result


func _valid_phase(boundary: float) -> bool:
	var enabled: bool = (
		block == VoxelWorldData.Block.MINER and is_finite(interval)
		and interval >= MIN_INTERVAL and amount > 0
	)
	if not enabled:
		return _produced_cycles == 0 and next_production == INF
	var elapsed: float = floorf((boundary - _placed_at + LogisticsData.TIME_EPSILON) / interval)
	if not is_finite(elapsed) or elapsed >= float(SnapshotValues.MAX_INTEGER):
		return next_production == INF
	var cycles: int = maxi(0, int(elapsed))
	if _produced_cycles != cycles:
		return false
	var deadline: float = _placed_at + float(cycles + 1) * interval
	var expected: float = deadline if deadline > boundary and deadline > _placed_at else INF
	return next_production == expected


func _init(kind: int, placed_at: float, mining_interval: float, mining_amount: int) -> void:
	block = kind
	interval = mining_interval
	amount = mining_amount
	_placed_at = placed_at
	if (
		block == VoxelWorldData.Block.MINER and is_finite(interval)
		and interval >= MIN_INTERVAL and amount > 0
	):
		var deadline: float = placed_at + interval
		if deadline > placed_at:
			next_production = deadline


func produce_until(time: float) -> void:
	## One integer calculation per miner, independent of the number of deadlines.
	if next_production > time + 1e-9:
		return
	var elapsed_cycles: float = floorf((time - _placed_at + 1e-9) / interval)
	if not is_finite(elapsed_cycles) or elapsed_cycles >= float(9223372036854775807):
		next_production = INF
		return
	var cycles: int = int(elapsed_cycles)
	if cycles <= _produced_cycles:
		return
	quantity += (cycles - _produced_cycles) * amount
	_produced_cycles = cycles
	var deadline: float = _placed_at + float(cycles + 1) * interval
	next_production = deadline if deadline > time and deadline > next_production else INF
