extends Node

const ReporterScript = preload("res://services/reports/draft_growth_curve_reporter.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/draft_growth_curve_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/draft_growth_curve_latest.csv"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var reporter: Object = ReporterScript.new()
	var report: Dictionary = reporter.run(options)
	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var csv_path: String = str(options.get("csv", DEFAULT_CSV_PATH))
	var json_ok: bool = _write_text(output_path, JSON.stringify(report, "\t"))
	var csv_ok: bool = _write_text(csv_path, reporter.csv_text(report))

	_print_summary(report, output_path if json_ok else "", csv_path if csv_ok else "")
	get_tree().quit(0 if bool(report.get("ok", false)) and json_ok and csv_ok else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seed": 20260528,
		"samples": 50000,
		"min_age": 18,
		"max_age": 36,
		"output": DEFAULT_OUTPUT_PATH,
		"csv": DEFAULT_CSV_PATH,
	}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg_value in args:
		var arg: String = str(arg_value)
		if arg == "--help" or arg == "-h":
			options["help"] = true
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--samples="):
			options["samples"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--min-age="):
			options["min_age"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--max-age="):
			options["max_age"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--csv="):
			options["csv"] = arg.get_slice("=", 1)
	return options


func _write_text(path: String, text: String) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(parent_dir)
	if make_dir_error != OK:
		print("Output directory error: %s" % error_string(make_dir_error))
		return false

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Output write error: %s" % path)
		return false

	file.store_string(text)
	return true


func _print_summary(report: Dictionary, output_path: String, csv_path: String) -> void:
	print("Draft growth curve report: %s" % ("ok" if bool(report.get("ok", false)) else "failed"))
	print("Seed: %d  Samples: %d  Ages: %d-%d" % [
		int(report.get("seed", 0)),
		int(report.get("candidates_generated", 0)),
		int(report.get("min_age", 0)),
		int(report.get("max_age", 0)),
	])
	var min_age: int = int(report.get("min_age", 0))
	var max_age: int = int(report.get("max_age", 0))
	var checkpoints: Array = [max(min_age, 18), max(min_age, 22), max(min_age, 25), max(min_age, 28), max(min_age, 31), max_age]
	var source_order: Array = report.get("source_order", []) as Array
	var sources: Dictionary = report.get("sources", {}) as Dictionary
	var source_position_splits: Dictionary = report.get("source_position_splits", {}) as Dictionary
	for source_value in source_order:
		var source_type: String = str(source_value)
		var splits: Dictionary = source_position_splits.get(source_type, {}) as Dictionary
		if splits.is_empty():
			_print_group_summary(source_type, "all", sources.get(source_type, {}) as Dictionary, checkpoints)
			continue
		for player_group in ["pitcher", "fielder"]:
			if splits.has(player_group):
				_print_group_summary(source_type, str(player_group), splits[player_group] as Dictionary, checkpoints)
	if output_path != "":
		print("JSON: %s" % ProjectSettings.globalize_path(output_path))
	if csv_path != "":
		print("CSV: %s" % ProjectSettings.globalize_path(csv_path))


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_draft_growth_curve.tscn -- --samples=50000 --min-age=18 --max-age=36 --seed=20260528")
	print("Options:")
	print("  --samples=N")
	print("  --min-age=N")
	print("  --max-age=N")
	print("  --seed=N")
	print("  --output=res://reports/draft_growth_curve_latest.json")
	print("  --csv=res://reports/draft_growth_curve_latest.csv")


func _age_row(curve: Array, age: int) -> Dictionary:
	for row_value in curve:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("age", 0)) == age:
			return row
	return {}


func _print_group_summary(source_type: String, player_group: String, source: Dictionary, checkpoints: Array) -> void:
	var curve: Array = source.get("age_curve", []) as Array
	var parts: Array = []
	for age_value in checkpoints:
		var age: int = int(age_value)
		var row: Dictionary = _age_row(curve, age)
		if row.is_empty():
			continue
		var label: String = "age%d %.1f" % [age, float(row.get("overall_mean", 0.0))]
		if not parts.has(label):
			parts.append(label)
	print("%s/%s n=%d %s" % [
		source_type,
		player_group,
		int(source.get("count", 0)),
		"  ".join(parts),
	])
