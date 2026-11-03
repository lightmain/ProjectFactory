extends GdUnitTestSuite


func _packed_path(count: int, reversed: bool = false) -> LogisticsTopology:
	var topology: LogisticsTopology = LogisticsTopology.new()
	var cells: Array[Vector3i] = []
	for index: int in range(count):
		var row: int = index / 32
		var column: int = index % 32 if row % 2 == 0 else 31 - index % 32
		cells.append(Vector3i(column - 16, 0, row - 16))
	for ordinal: int in range(count):
		var index: int = count - ordinal - 1 if reversed else ordinal
		var machine: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.BELT, 0, 1, 1)
		machine.direction = (
			cells[index + 1] - cells[index] if index + 1 < count else cells[index] - cells[index - 1]
		)
		machine.quantity = 2
		machine.eligible_quantity = 2
		var incoming: Vector3i = cells[index] - cells[index - 1] if index > 0 else Vector3i.RIGHT
		for offset: int in range(2):
			var ore: LogisticsOre = LogisticsOre.new(index * 2 + offset + 1, incoming)
			ore.progress = 1.0 - float(offset) * 0.5
			machine.belt_ores.append(ore)
		topology.add(cells[index], machine)
	topology.rebuild()
	return topology


func test_blocked_chain_rejects_all_dependencies_once_without_changing_ore() -> void:
	for count: int in [16, 128, 512]:
		for reversed: bool in [false, true]:
			var topology: LogisticsTopology = _packed_path(count, reversed)
			var batch: LogisticsBatch = LogisticsBatch.new()
			batch.transfer(topology, 1)
			for machine: LogisticsMachine in topology.machines:
				assert_int(machine.quantity).is_equal(2)
				assert_int(machine.input_cursor).is_equal(0)
			assert_int(batch.work).is_less_equal(20 * count)


func test_removing_a_middle_slot_keeps_settled_neighbors_of_the_swapped_facility() -> void:
	var topology: LogisticsTopology = _packed_path(100)
	var moved_cell: Vector3i = topology.cells[-1]
	var predecessor_cell: Vector3i = topology.cells[-2]
	var removed_cell: Vector3i = topology.cells[10]
	topology.remove(10)
	assert_int(topology.index_at(removed_cell)).is_equal(-1)
	assert_int(topology.index_at(moved_cell)).is_equal(10)
	assert_int(topology.outgoing[topology.index_at(predecessor_cell)]).is_equal(10)
	var queues: Array[LogisticsOreQueue] = []
	for machine: LogisticsMachine in topology.machines:
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.ores = machine.belt_ores
		queues.append(queue)
	var solver: BeltPositionSolver = BeltPositionSolver.new()
	solver.advance(topology, queues, 0.01)
	for machine: LogisticsMachine in topology.machines:
		assert_float(machine.belt_ores[0].progress).is_equal(1.0)
		assert_float(machine.belt_ores[1].progress).is_equal(0.5)


func test_full_ring_reserves_its_internal_predecessor_and_transfers_original_heads() -> void:
	var topology: LogisticsTopology = LogisticsTopology.new()
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for index: int in range(4):
		var machine: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.BELT, 0, 1, 1)
		machine.direction = cells[(index + 1) % 4] - cells[index]
		machine.quantity = 2
		machine.eligible_quantity = 2
		for offset: int in range(2):
			var ore: LogisticsOre = LogisticsOre.new(index * 2 + offset + 1, machine.direction)
			ore.progress = 1.0 - float(offset) * 0.5
			machine.belt_ores.append(ore)
		topology.add(cells[index], machine)
	var feeder: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.MINER, 0, 1, 1)
	feeder.direction = Vector3i.RIGHT
	feeder.quantity = 100
	feeder.eligible_quantity = 100
	topology.add(Vector3i.LEFT, feeder)
	topology.rebuild()
	var batch: LogisticsBatch = LogisticsBatch.new()
	batch.transfer(topology, 1)
	assert_int(feeder.quantity).is_equal(100)
	for index: int in range(4):
		assert_int(topology.machines[index].quantity).is_equal(2)
		assert_int(topology.machines[index].belt_ores[0].id).is_equal(index * 2 + 2)
		assert_int(topology.machines[index].belt_ores[1].id).is_equal(((index + 3) % 4) * 2 + 1)
	assert_int(batch.work).is_less_equal(20 * 5)
