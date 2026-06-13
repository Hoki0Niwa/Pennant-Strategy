extends Node


func _ready() -> void:
	var failures: Array = []
	var main_script: Resource = load("res://ui/main.gd")
	if main_script == null:
		failures.append("ui/main.gd failed to load")
	var home_script: Resource = load("res://ui/screens/home_screen.gd")
	if home_script == null:
		failures.append("home_screen.gd failed to load")
	if failures.is_empty():
		print("Startup smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Startup smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)
