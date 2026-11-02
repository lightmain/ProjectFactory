class_name PlayerMotionRules
extends RefCounted

const GRAVITY: float = 9.81
const STEP_HEIGHT: float = VoxelWorldData.CELL_SIZE


static func jump_speed(max_jump_height: float) -> float:
	return sqrt(2.0 * GRAVITY * maxf(0.0, max_jump_height))


static func vertical_step(speed: float, delta: float) -> Vector2:
	## x: displacement in metres; y: final velocity in metres per second.
	return Vector2(speed * delta - GRAVITY * delta * delta * 0.5, speed - GRAVITY * delta)
