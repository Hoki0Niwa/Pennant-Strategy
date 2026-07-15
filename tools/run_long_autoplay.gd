extends Node

const ReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const ReportHealth = preload("res://services/reports/report_health.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/long_autoplay_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/long_autoplay_latest.csv"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var reporter: Object = ReporterScript.new()
	var report: Dictionary = _run_multi_seed(reporter, options) if options.has("seeds") else reporter.run(options)
	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var csv_path: String = str(options.get("csv", DEFAULT_CSV_PATH))
	var json_ok: bool = _write_text(output_path, JSON.stringify(report, "\t"))
	var csv_ok: bool = _write_text(csv_path, _multi_seed_csv_text(report) if bool(report.get("multi_seed", false)) else reporter.csv_text(report))

	_print_summary(report, output_path if json_ok else "", csv_path if csv_ok else "")
	var multi_ok: bool = bool(report.get("multi_seed", false)) and int((report.get("seed_runs", []) as Array).size()) > 0
	get_tree().quit(0 if (int(report.get("seasons_completed", 0)) > 0 or multi_ok) and json_ok and csv_ok else 1)


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
		elif arg.begins_with("--seeds="):
			options["seeds"] = _parse_seed_list(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--csv="):
			options["csv"] = arg.get_slice("=", 1)
	return options


func _parse_seed_list(text: String) -> Array:
	var seeds: Array = []
	for part in text.split(",", false):
		var trimmed: String = str(part).strip_edges()
		if trimmed.is_empty():
			continue
		seeds.append(int(trimmed))
	return seeds


func _run_multi_seed(reporter: Object, options: Dictionary) -> Dictionary:
	var seed_values: Array = options.get("seeds", []) as Array
	var reports: Array = []
	for seed_value in seed_values:
		var run_options: Dictionary = options.duplicate(true)
		run_options.erase("seeds")
		run_options["seed"] = int(seed_value)
		reports.append(reporter.run(run_options))
	return {
		"multi_seed": true,
		"report_type": "long_autoplay",
		"seasons_requested": int(options.get("seasons", 0)),
		"seed_count": seed_values.size(),
		"seeds": seed_values,
		"summary": ReportHealth.multi_seed_summary(reports, {
			"last10_ops": ["window_summaries", "last_10_years", "ops"],
			"last10_era": ["window_summaries", "last_10_years", "era"],
			"last10_average_age": ["window_summaries", "last_10_years", "average_age"],
			"released_per_year": ["window_summaries", "last_10_years", "released_per_year"],
			"released_fielders_per_pitcher": ["window_summaries", "last_10_years", "released_fielders_per_pitcher"],
			"released_average_age": ["window_summaries", "last_10_years", "released_average_age"],
			"noshow_thirties_survivors_per_year": ["window_summaries", "last_10_years", "noshow_thirties_survivors_per_year"],
			"team_shienka_max": ["distributions", "roster", "team_shienka_max", "max"],
			"team_development_max": ["distributions", "roster", "team_development_max", "max"],
			"team_foreign_max": ["distributions", "roster", "team_foreign_max", "max"],
		}),
		"seed_runs": reports,
	}


func _multi_seed_csv_text(report: Dictionary) -> String:
	var lines: Array = ["seed,status,fail_count,warn_count,seasons_completed,last10_ops,last10_era,last10_average_age,released_per_year,released_fielders_per_pitcher,released_average_age,noshow_thirties_survivors_per_year,final_active,final_shienka,final_development,team_shienka_max,team_development_max,team_foreign_max"]
	for run_value in report.get("seed_runs", []) as Array:
		var run: Dictionary = run_value as Dictionary
		var health: Dictionary = run.get("health", {}) as Dictionary
		var last_10: Dictionary = ((run.get("window_summaries", {}) as Dictionary).get("last_10_years", {}) as Dictionary)
		var final_roster: Dictionary = run.get("final_roster_after_last_offseason", {}) as Dictionary
		lines.append("%d,%s,%d,%d,%d,%.3f,%.2f,%.2f,%.2f,%.3f,%.2f,%.2f,%d,%d,%d,%d,%d,%d" % [
			int(run.get("seed", 0)),
			str(health.get("status", "")),
			int(health.get("fail_count", 0)),
			int(health.get("warn_count", 0)),
			int(run.get("seasons_completed", 0)),
			float(last_10.get("ops", 0.0)),
			float(last_10.get("era", 0.0)),
			float(last_10.get("average_age", 0.0)),
			float(last_10.get("released_per_year", 0.0)),
			float(last_10.get("released_fielders_per_pitcher", 0.0)),
			float(last_10.get("released_average_age", 0.0)),
			float(last_10.get("noshow_thirties_survivors_per_year", 0.0)),
			int(final_roster.get("active_players", 0)),
			int(final_roster.get("shienka_players", 0)),
			int(final_roster.get("development_players", 0)),
			int(final_roster.get("team_shienka_max", 0)),
			int(final_roster.get("team_development_max", 0)),
			int(final_roster.get("team_foreign_max", 0)),
		])
	return "\n".join(lines)


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
	if bool(report.get("multi_seed", false)):
		_print_multi_seed_summary(report, output_path, csv_path)
		return
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
	var health: Dictionary = report.get("health", {}) as Dictionary
	if not health.is_empty():
		print("Health: %s (fail=%d warn=%d)" % [
			str(health.get("status", "")),
			int(health.get("fail_count", 0)),
			int(health.get("warn_count", 0)),
		])
	if output_path != "":
		print("JSON: %s" % ProjectSettings.globalize_path(output_path))
	if csv_path != "":
		print("CSV: %s" % ProjectSettings.globalize_path(csv_path))


func _print_multi_seed_summary(report: Dictionary, output_path: String, csv_path: String) -> void:
	var summary: Dictionary = report.get("summary", {}) as Dictionary
	var statuses: Dictionary = summary.get("statuses", {}) as Dictionary
	print("Long autoplay multi-seed: %d seeds x %d seasons" % [
		int(report.get("seed_count", 0)),
		int(report.get("seasons_requested", 0)),
	])
	print("Health statuses: pass=%d warn=%d fail=%d" % [
		int(statuses.get("pass", 0)),
		int(statuses.get("warn", 0)),
		int(statuses.get("fail", 0)),
	])
	var metrics: Dictionary = summary.get("metrics", {}) as Dictionary
	for key_value in metrics.keys():
		var metric: Dictionary = metrics[key_value] as Dictionary
		print("%s: p50 %.3f  min %.3f  max %.3f" % [
			str(key_value),
			float(metric.get("p50", 0.0)),
			float(metric.get("min", 0.0)),
			float(metric.get("max", 0.0)),
		])
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
	print("  --seeds=1,2,3  (multi-seed JSON/CSV aggregation)")
	print("  --output=res://reports/long_autoplay_latest.json")
	print("  --csv=res://reports/long_autoplay_latest.csv")
