extends Node

signal seed_changed(seed_value: int)

var generator: RandomNumberGenerator = RandomNumberGenerator.new()
var current_seed: int = 1


func _ready() -> void:
	randomize_seed()


func randomize_seed() -> void:
	generator.randomize()
	current_seed = generator.seed
	seed_changed.emit(current_seed)


func set_seed_value(seed_value: int) -> void:
	current_seed = seed_value
	generator.seed = seed_value
	seed_changed.emit(current_seed)


func roll_float() -> float:
	return generator.randf()


func roll_percent() -> int:
	return generator.randi_range(1, 100)


func range_int(min_value: int, max_value: int) -> int:
	return generator.randi_range(min_value, max_value)
