class_name LogisticsPacked
extends RefCounted
## Format 1: little-endian 136-byte rows. Integers remain int64, floats float64.
## Cell int32[3], four byte enums; eight 64-bit machine fields, ore count,
## seven zero padding bytes; two (id:int64, direction:byte, padding[7], float64).

const ROW_SIZE: int = 136
const DIRECTIONS: Array[Vector3i] = [Vector3i.FORWARD, Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT]


static func write_row(bytes: PackedByteArray, index: int, cell: Vector3i, machine: LogisticsMachine) -> void:
	var offset: int = index * ROW_SIZE
	for axis: int in range(3):
		bytes.encode_s32(offset + axis * 4, cell[axis])
	bytes[offset + 12] = machine.block
	bytes[offset + 13] = DIRECTIONS.find(machine.direction)
	bytes[offset + 14] = DIRECTIONS.find(machine.settled_direction)
	bytes[offset + 15] = machine.input_cursor
	bytes.encode_s64(offset + 16, machine.quantity)
	bytes.encode_s64(offset + 24, machine.eligible_quantity)
	bytes.encode_s64(offset + 32, machine.last_output_tick)
	bytes.encode_double(offset + 40, machine.interval)
	bytes.encode_s64(offset + 48, machine.amount)
	bytes.encode_double(offset + 56, machine.next_production)
	var phase: Dictionary = machine.production_phase()
	var placed: float = phase["placed"]
	var cycles: int = phase["cycles"]
	bytes.encode_double(offset + 64, placed)
	bytes.encode_s64(offset + 72, cycles)
	bytes[offset + 80] = machine.belt_ores.size()
	for ore_index: int in range(machine.belt_ores.size()):
		var ore: LogisticsOre = machine.belt_ores[ore_index]
		var ore_offset: int = offset + 88 + ore_index * 24
		bytes.encode_s64(ore_offset, ore.id)
		bytes[ore_offset + 8] = DIRECTIONS.find(ore.incoming_direction)
		bytes.encode_double(ore_offset + 16, ore.progress)


static func read_row(bytes: PackedByteArray, index: int) -> Dictionary:
	var offset: int = index * ROW_SIZE
	if offset < 0 or offset + ROW_SIZE > bytes.size() or (
		bytes[offset + 13] > 3 or bytes[offset + 14] > 3 or bytes[offset + 80] > 2
	):
		return {}
	var ores: Array[Dictionary] = []
	for ore_index: int in range(bytes[offset + 80]):
		var ore_offset: int = offset + 88 + ore_index * 24
		if bytes[ore_offset + 8] > 3:
			return {}
		ores.append({"id": bytes.decode_s64(ore_offset),
			"incoming": DIRECTIONS[bytes[ore_offset + 8]], "progress": bytes.decode_double(ore_offset + 16)})
	return {
		"cell": Vector3i(bytes.decode_s32(offset), bytes.decode_s32(offset + 4), bytes.decode_s32(offset + 8)),
		"block": int(bytes[offset + 12]), "direction": DIRECTIONS[bytes[offset + 13]],
		"settled": DIRECTIONS[bytes[offset + 14]], "cursor": int(bytes[offset + 15]),
		"quantity": bytes.decode_s64(offset + 16), "eligible": bytes.decode_s64(offset + 24),
		"last_output": bytes.decode_s64(offset + 32), "interval": bytes.decode_double(offset + 40),
		"amount": bytes.decode_s64(offset + 48), "next": bytes.decode_double(offset + 56),
		"placed": bytes.decode_double(offset + 64), "cycles": bytes.decode_s64(offset + 72), "ores": ores,
	}
