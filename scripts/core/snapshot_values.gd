class_name SnapshotValues
extends RefCounted
## Narrow untrusted Variant values before they enter typed rules.

const MAX_INTEGER: int = 9223372036854775807
const MIN_INTEGER: int = -MAX_INTEGER - 1


static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	return value is int and value >= minimum and value <= maximum


static func number(value: Variant, minimum: float, maximum: float) -> bool:
	if not value is float:
		return false
	var numeric: float = value
	return is_finite(numeric) and numeric >= minimum and numeric <= maximum


static func direction(value: Variant) -> bool:
	return value is Vector3i and value in [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK,
	]


static func vector(value: Variant, limit: float) -> bool:
	if not value is Vector3:
		return false
	var position: Vector3 = value
	return position.is_finite() and (
		absf(position.x) <= limit and absf(position.y) <= limit and absf(position.z) <= limit
	)
