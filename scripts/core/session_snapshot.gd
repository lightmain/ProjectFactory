class_name SessionSnapshot
extends RefCounted
## Fully validated, independent rules. No live nodes are touched during decoding.

const FORMAT_VERSION: int = 1
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


static func decode(state: Dictionary) -> SessionSnapshot:
	if not SnapshotValues.integer(state.get("version"), FORMAT_VERSION, FORMAT_VERSION) or (
		not SnapshotValues.integer(state.get("generator"), GENERATOR_VERSION, GENERATOR_VERSION)
		or state.get("minimum") != VoxelWorldData.MIN_CELL
		or state.get("maximum") != VoxelWorldData.MAX_CELL
		or not state.get("flat") is bool or not state.get("chunks") is Dictionary
		or not state.get("logistics") is Dictionary or not state.get("inventory") is Array
		or not state.get("player") is Dictionary
	):
		return null
	var chunk_values: Dictionary = state["chunks"]
	if chunk_values.size() > 8:
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
	var inventory_state: Array = state["inventory"]
	if not result.world.restore_chunks(flat, chunks):
		return null
	result.logistics.bind_world(result.world)
	if not result.logistics.restore_state(logistics_state) or (
		not result.inventory.restore_state(inventory_state)
	):
		return null
	var player: Dictionary = state["player"]
	if not SnapshotValues.vector(player.get("position"), 10000.0) or (
		not SnapshotValues.vector(player.get("velocity"), 1000.0)
		or not SnapshotValues.vector(player.get("spawn"), 10000.0)
		or not SnapshotValues.vector(player.get("rotation"), 100000.0)
		or not SnapshotValues.integer(player.get("tool"), 1, 7)
		or player.get("tool") == VoxelWorldData.Block.BEDROCK
		or not SnapshotValues.integer(player.get("build_rotation"), 0, 3)
	):
		return null
	result.position = player["position"]
	result.velocity = player["velocity"]
	result.spawn = player["spawn"]
	result.view_rotation = player["rotation"]
	if absf(result.view_rotation.x) > 1.5 or result.view_rotation.z != 0.0:
		return null
	result.selected_block = player["tool"]
	result.build_rotation = player["build_rotation"]
	return result
