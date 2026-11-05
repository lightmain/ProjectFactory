class_name GameConfig
extends Resource
## Shared tuning parameters; mutable factory state belongs to LogisticsData.

@export_group("Rendering")
## Distance from the active camera to the machine cell centre, in metres.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m")
var ore_render_distance: float = 12.0:
	set(value):
		ore_render_distance = value
		emit_changed()

@export_group("Mining")
## Seconds per cycle; invalid values disable newly placed miners.
@export var mining_interval: float = 1.0:
	set(value):
		mining_interval = value
		emit_changed()
@export var mining_amount: int = 1:
	set(value):
		mining_amount = value
		emit_changed()

@export_group("Autosave")
@export_range(0.1, 120.0, 0.1, "or_greater", "suffix:min")
var autosave_interval_minutes: float = 5.0
@export_range(1, 100, 1, "or_greater")
var autosave_retention: int = 3
