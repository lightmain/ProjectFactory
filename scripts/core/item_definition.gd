class_name ItemDefinition
extends Resource
## Shared item metadata, treated as immutable after registration.

@export var item_id: StringName
@export var display_name: String
@export_multiline var description: String
@export var max_stack: int = 100


func is_valid() -> bool:
	return not item_id.is_empty() and max_stack > 0
