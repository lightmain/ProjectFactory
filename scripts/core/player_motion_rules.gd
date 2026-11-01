class_name PlayerMotionRules
extends RefCounted

const GRAVITY: float = 9.81
const MAX_JUMP_HEIGHT: float = 1.5
const STEP_HEIGHT: float = VoxelWorldData.CELL_SIZE * 0.5


static func jump_speed() -> float:
	return sqrt(2.0 * GRAVITY * MAX_JUMP_HEIGHT)


static func vertical_step(speed: float, delta: float) -> Vector2:
	## x: displacement in metres; y: final velocity in metres per second.
	return Vector2(speed * delta - GRAVITY * delta * delta * 0.5, speed - GRAVITY * delta)
