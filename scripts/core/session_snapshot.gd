class_name SessionSnapshot
extends RefCounted
## Fully validated, independent rules. No live nodes are touched during decoding.

const FORMAT_VERSION: int = 4
const GENERATOR_VERSION: int = 1

var world: VoxelWorldData = VoxelWorldData.new()
var logistics: LogisticsData = LogisticsData.new()
var inventory: InventoryData = InventoryData.new()
var position: Vector3
var velocity: Vector3
var spawn: Vector3
var view_rotation: Vector3
var selected_block: int
var build_rotation: int
var world_id: String = ""
var world_name: String = "新世界"


static func decode(state: Dictionary, phase_observer: Callable = Callable()) -> SessionSnapshot:
	if not SnapshotValues.integer(state.get("version"), 1, FORMAT_VERSION) or (
		not SnapshotValues.integer(state.get("generator"), GENERATOR_VERSION, GENERATOR_VERSION)
		or not state.get("minimum") is Vector3i or not state.get("maximum") is Vector3i
		or not state.get("flat") is bool or not state.get("chunks") is Dictionary
		or not state.get("logistics") is Dictionary or not state.get("inventory") is Array
		or not state.get("player") is Dictionary
	):
		return null
	var chunk_values: Dictionary = state["chunks"]
	var version: int = state["version"]
	var low: Vector3i = state["minimum"]
	var high: Vector3i = state["maximum"]
	var depth: int = 4
	if version < 4:
		if low != VoxelWorldData.MIN_CELL or high != VoxelWorldData.MAX_CELL:
			return null
	else:
		if not SnapshotValues.integer(state.get("floor_depth"), 1, 4):
			return null
		depth = state["floor_depth"]
	if not VoxelWorldData.valid_dimensions(low, high, depth) or chunk_values.size() > VoxelWorldData.MAX_CHUNKS:
		return null
	var chunks: Dictionary[Vector3i, PackedByteArray] = {}
	for key: Variant in chunk_values:
		if not key is Vector3i or not chunk_values[key] is PackedByteArray:
			return null
		chunks[key] = chunk_values[key]
	var result: SessionSnapshot = SessionSnapshot.new()
	if state.has("world_id") or state.has("world_name"):
		if not state.get("world_id") is String or not state.get("world_name") is String:
			return null
		result.world_id = state["world_id"]
		result.world_name = state["world_name"]
		if result.world_id.length() != 32 or not result.world_id.is_valid_hex_number() or (
			result.world_name.strip_edges().is_empty() or result.world_name.length() > 80
		):
			return null
	var flat: bool = state["flat"]
	var logistics_state: Dictionary = state["logistics"]
	if version < 4 and not logistics_state.get("machines") is Array:
		return null
	var inventory_state: Array = state["inventory"]
	var structures: Array = []
	if version >= 2 or state.has("structures"):
		if not state.get("structures") is Array:
			return null
		structures = state["structures"]
	if version < 3:
		# Version one had neither this block type nor instance metadata.
		if version == 1 and not structures.is_empty():
			return null
		for records: PackedByteArray in chunks.values():
			for offset: int in range(2, records.size(), 3):
				if records[offset] > (VoxelWorldData.Block.CHEST if version == 1 else VoxelWorldData.Block.STRUCTURE):
					return null
	if phase_observer.is_valid():
		phase_observer.call("world_restore", true)
	var world_valid: bool = result.world.restore_chunks(flat, chunks, structures, low, high, depth)
	if phase_observer.is_valid():
		phase_observer.call("world_restore", false)
	if not world_valid:
		return null
	if phase_observer.is_valid():
		phase_observer.call("default_logistics_bind", true)
	result.logistics.bind_world(result.world)
	if phase_observer.is_valid():
		phase_observer.call("default_logistics_bind", false)
	if phase_observer.is_valid():
		phase_observer.call("logistics_restore", true)
	var logistics_valid: bool = result.logistics.restore_state(logistics_state)
	if phase_observer.is_valid():
		phase_observer.call("logistics_restore", false)
	if not logistics_valid or (
		not result.inventory.restore_state(inventory_state)
	):
		return null
	var player: Dictionary = state["player"]
	if not SnapshotValues.vector(player.get("position"), 10000.0) or (
		not SnapshotValues.vector(player.get("velocity"), 1000.0)
		or not SnapshotValues.vector(player.get("spawn"), 10000.0)
		or not SnapshotValues.vector(player.get("rotation"), 100000.0)
		or not SnapshotValues.integer(player.get("tool"), 1, 13 if version >= 3 else (8 if version >= 2 else 7))
		or player.get("tool") == VoxelWorldData.Block.BEDROCK
		or not SnapshotValues.integer(player.get("build_rotation"), 0, 3)
	):
		return null
	var tool: int = player["tool"]
	if tool > 8 and tool not in [VoxelWorldData.Block.BELT_UP, VoxelWorldData.Block.BELT_DOWN]:
		return null
	result.position = player["position"]
	result.velocity = player["velocity"]
	result.spawn = player["spawn"]
	result.view_rotation = player["rotation"]
	if absf(result.view_rotation.x) > 1.5 or result.view_rotation.z != 0.0:
		return null
	result.selected_block = tool
	result.build_rotation = player["build_rotation"]
	return result
