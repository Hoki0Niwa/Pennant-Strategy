extends Node

const RunnerScript = preload("res://services/reports/player_probe_runner.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/player_probe_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/player_probe_latest.csv"
const DEFAULT_GRAPH_PATH: String = "res://reports/player_probe_latest.svg"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var runner: Object = RunnerScript.new()
	var report: Dictionary = runner.run(options)
	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var write_ok: bool = _write_text(output_path, JSON.stringify(report, "\t"))

	var csv_path: String = str(options.get("csv", DEFAULT_CSV_PATH))
	var csv_ok: bool = _write_text(csv_path, runner.csv_text(report))
	var graph_path: String = str(options.get("graph", DEFAULT_GRAPH_PATH))
	var graph_text: String = runner.svg_text(report)
	var graph_ok: bool = true
	if not graph_text.is_empty():
		graph_ok = _write_text(graph_path, graph_text)

	_print_summary(report, output_path if write_ok else "", csv_path if csv_ok else "", graph_path if graph_ok and not graph_text.is_empty() else "")
	get_tree().quit(0 if bool(report.get("ok", false)) and write_ok and csv_ok and graph_ok else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"mode": "batter",
		"player_id": 0,
		"player_name": "",
		"plate_appearances": 600,
		"innings": 200.0,
		"target_outs": 0,
		"seed": 12345,
		"output": DEFAULT_OUTPUT_PATH,
		"csv": DEFAULT_CSV_PATH,
		"graph": DEFAULT_GRAPH_PATH,
		"sweep_ability": "",
		"sweep_values": [],
		"sweep_start": -1.0,
		"sweep_end": 3.0,
		"sweep_step": 0.5,
		"iterations": 1,
		"metric": "",
		"set_overrides": {},
		"dh": true,
		"exclude_subject_team": true,
		"defense_team_id": 0,
		"reliever": false,
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
			continue
		if arg.begins_with("--mode="):
			options["mode"] = arg.get_slice("=", 1)
		elif arg.begins_with("--player-id="):
			options["player_id"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--player-name="):
			options["player_name"] = arg.get_slice("=", 1)
		elif arg.begins_with("--plate-appearances="):
			options["plate_appearances"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--pa="):
			options["plate_appearances"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--innings="):
			options["innings"] = float(arg.get_slice("=", 1))
		elif arg.begins_with("--outs="):
			options["target_outs"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--csv="):
			options["csv"] = arg.get_slice("=", 1)
		elif arg.begins_with("--graph="):
			options["graph"] = arg.get_slice("=", 1)
		elif arg.begins_with("--ability="):
			options["sweep_ability"] = arg.get_slice("=", 1)
		elif arg.begins_with("--sweep-ability="):
			options["sweep_ability"] = arg.get_slice("=", 1)
		elif arg.begins_with("--values="):
			options["sweep_values"] = _parse_float_list(arg.get_slice("=", 1))
		elif arg.begins_with("--range="):
			_apply_range(options, arg.get_slice("=", 1))
		elif arg.begins_with("--sweep-start="):
			options["sweep_start"] = float(arg.get_slice("=", 1))
		elif arg.begins_with("--sweep-end="):
			options["sweep_end"] = float(arg.get_slice("=", 1))
		elif arg.begins_with("--sweep-step="):
			options["sweep_step"] = float(arg.get_slice("=", 1))
		elif arg.begins_with("--iterations="):
			options["iterations"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--metric="):
			options["metric"] = arg.get_slice("=", 1)
		elif arg.begins_with("--set="):
			options["set_overrides"] = _parse_set_overrides(arg.get_slice("=", 1))
		elif arg.begins_with("--dh="):
			options["dh"] = _parse_bool(arg.get_slice("=", 1))
		elif arg.begins_with("--exclude-subject-team="):
			options["exclude_subject_team"] = _parse_bool(arg.get_slice("=", 1))
		elif arg.begins_with("--defense-team="):
			options["defense_team_id"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--reliever="):
			options["reliever"] = _parse_bool(arg.get_slice("=", 1))
	return options


func _parse_float_list(text: String) -> Array:
	var values: Array = []
	if text.strip_edges().is_empty():
		return values
	for part in text.split(",", false):
		values.append(float(str(part).strip_edges()))
	return values


func _apply_range(options: Dictionary, text: String) -> void:
	var parts: PackedStringArray = text.split(":", false)
	if parts.size() >= 1:
		options["sweep_start"] = float(parts[0])
	if parts.size() >= 2:
		options["sweep_end"] = float(parts[1])
	if parts.size() >= 3:
		options["sweep_step"] = float(parts[2])


func _parse_set_overrides(text: String) -> Dictionary:
	var overrides: Dictionary = {}
	if text.strip_edges().is_empty():
		return overrides
	for part_value in text.split(",", false):
		var part: String = str(part_value).strip_edges()
		if part.is_empty() or not part.contains(":"):
			continue
		var key: String = part.get_slice(":", 0).strip_edges()
		var value: float = float(part.get_slice(":", 1).strip_edges())
		overrides[key] = value
	return overrides


func _parse_bool(text: String) -> bool:
	var lowered: String = text.to_lower()
	return lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"


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


func _print_summary(report: Dictionary, output_path: String, csv_path: String, graph_path: String) -> void:
	print("Player probe: %s" % ("ok" if bool(report.get("ok", false)) else "failed"))
	print("Mode: %s" % str(report.get("mode", "")))
	var subject: Dictionary = report.get("subject", {}) as Dictionary
	print("Subject: %s (#%d)" % [str(subject.get("name", "")), int(subject.get("id", 0))])
	var sweep: Dictionary = report.get("sweep", {}) as Dictionary
	if not str(sweep.get("ability", "")).is_empty():
		print("Sweep: %s -> %s" % [str(sweep.get("ability", "")), str(sweep.get("metric", ""))])
	var rows: Array = report.get("rows", []) as Array
	if not rows.is_empty():
		var last_row: Dictionary = rows[rows.size() - 1] as Dictionary
		print("Last metric: %s = %.3f" % [str(last_row.get("metric", "")), float(last_row.get("metric_value", 0.0))])
	if output_path != "":
		print("JSON: %s" % ProjectSettings.globalize_path(output_path))
	if csv_path != "":
		print("CSV: %s" % ProjectSettings.globalize_path(csv_path))
	if graph_path != "":
		print("Graph: %s" % ProjectSettings.globalize_path(graph_path))
	var errors: Array = report.get("errors", []) as Array
	for error in errors:
		print("Error: %s" % str(error))


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_player_probe.tscn -- --mode=batter --player-id=710 --pa=5000")
	print("  godot --headless --path . --scene res://tools/run_player_probe.tscn -- --mode=batter --player-id=710 --ability=Bat_Impact --range=-1:3:0.5 --iterations=3 --metric=home_runs")
	print("  godot --headless --path . --scene res://tools/run_player_probe.tscn -- --mode=pitcher --player-id=1 --innings=300 --ability=Pit_BBPrevent --values=-1,0,1,2")
	print("Options:")
	print("  --mode=batter|pitcher")
	print("  --player-id=N or --player-name=NAME")
	print("  --pa=N / --plate-appearances=N")
	print("  --innings=N or --outs=N")
	print("  --set=ability:value,ability:value")
	print("  --ability=KEY / --sweep-ability=KEY")
	print("  --values=-1,0,1 or --range=-1:3:0.5")
	print("  --iterations=N")
	print("  --metric=home_runs|home_run_rate|batting_average|woba|xwoba|re24|bsr|era|strikeouts_per_nine|...")
	print("  --output=res://reports/player_probe_latest.json")
	print("  --csv=res://reports/player_probe_latest.csv")
	print("  --graph=res://reports/player_probe_latest.svg")
