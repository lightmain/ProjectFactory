class_name ItemStack
extends RefCounted

var definition: ItemDefinition
var quantity: int


func _init(item: ItemDefinition, amount: int) -> void:
	definition = item
	quantity = amount


func snapshot() -> ItemStack:
	return ItemStack.new(definition, quantity)
