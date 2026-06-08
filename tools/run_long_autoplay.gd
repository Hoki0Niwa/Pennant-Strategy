extends Node

const ReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/long_autoplay_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/long_autoplay_latest.csv"


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
	get_tree().quit(0 if int(report.get("seasons_completed", 0)) > 0 and json_ok and csv_ok else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seasons": 40,
		"selected_team_id": 1,
		"start_year": 2026,
		"seed": 20260528,
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
		elif arg.begins_with("--seasons="):
			options["seasons"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--selected-team="):
			options["selected_team_id"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--start-year="):
			options["start_year"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
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
	var completed: int = int(report.get("seasons_completed", 0))
	var requested: int = int(report.get("seasons_requested", 0))
	var milestones: Dictionary = report.get("milestones", {}) as Dictionary
	var final_roster: Dictionary = report.get("final_roster_after_last_offseason", {}) as Dictionary
	var windows: Dictionary = report.get("window_summaries", {}) as Dictionary
	var last_10: Dictionary = windows.get("last_10_years", {}) as Dictionary

	print("Long autoplay report: %d/%d seasons" % [completed, requested])
	print("Seed: %d  Years: %d-%d" % [
		int(report.get("seed", 0)),
		int(report.get("start_year", 0)),
		int(report.get("end_year", 0)),
	])
	print("Milestones: draft>=95%% year=%d  draft-only year=%d" % [
		int(milestones.get("draft_generated_95_percent_year", 0)),
		int(milestones.get("draft_only_year", 0)),
	])
	print("Final roster: active %d  draft ratio %.1f%%  avg overall %.1f" % [
		int(final_roster.get("active_players", 0)),
		float(final_roster.get("draft_generated_ratio", 0.0)) * 100.0,
		float(final_roster.get("average_overall", 0.0)),
	])
	if not last_10.is_empty():
		print("Last 10y: runs/team-game %.3f  OPS %.3f  ERA %.2f  avg overall %.1f" % [
			float(last_10.get("runs_per_team_game", 0.0)),
			float(last_10.get("ops", 0.0)),
			float(last_10.get("era", 0.0)),
			float(last_10.get("average_overall", 0.0)),
		])
	var errors: Array = report.get("errors", []) as Array
	if not errors.is_empty():
		print("Errors: %d" % errors.size())
	if output_path != "":
		print("JSON: %s" % ProjectSettings.globalize_path(output_path))
	if csv_path != "":
		print("CSV: %s" % ProjectSettings.globalize_path(csv_path))


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_long_autoplay.tscn -- --seasons=40 --seed=20260528")
	print("Options:")
	print("  --seasons=N")
	print("  --selected-team=ID")
	print("  --start-year=YYYY")
	print("  --seed=N")
	print("  --output=res://reports/long_autoplay_latest.json")
	print("  --csv=res://reports/long_autoplay_latest.csv")
