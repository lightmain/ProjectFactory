class_name LogisticsOreQueue
extends RefCounted
## An indexed snapshot row, or an internal borrowed authoritative queue.

var cell: Vector3i
var direction: Vector3i
var ores: Array[LogisticsOre] = []
