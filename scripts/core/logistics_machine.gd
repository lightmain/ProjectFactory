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
