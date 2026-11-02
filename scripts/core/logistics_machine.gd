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


func produce() -> void:
	quantity += amount
	_produced_cycles += 1
	# Multiplication avoids accumulating drift at every production cycle.
	var deadline: float = _placed_at + float(_produced_cycles + 1) * interval
	next_production = deadline if deadline > next_production else INF
