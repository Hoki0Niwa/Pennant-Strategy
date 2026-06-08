extends Node

const ReporterScript = preload("res://services/reports/simulation_reporter.gd")

const DEFAULT_OUTPUT_PATH: String = "res://reports/defense_value_calibration_latest.json"
const DEFAULT_WEIGHTS_OUTPUT_PATH: String = "res://data/tuning/starter_value_weights.json"
const POSITIONS: Array[int] = [2, 6, 8, 4, 5, 9, 3, 7]
const POSITION_LABELS: Dictionary = {
	2: "C",
	3: "1B",
	4: "2B",
	5: "3B",
	6: "SS",
	7: "LF",
	8: "CF",
	9: "RF",
}
const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher",
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}
const BATTING_Z_KEYS: Array[String] = [
	"Bat_KAvoid",
	"Bat_BBCreate",
	"Bat_Impact",
	"Bat_Loft",
	"Bat_Barrel",
]
const DEFENSE_Z_KEYS_BY_POSITION: Dictionary = {
	2: ["C_Framing", "C_Blocking", "C_Throw", "C_GameCall", "C_FieldSecure"],
	3: ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit"],
	4: ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit"],
	5: ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit"],
	6: ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit"],
	7: ["OF_Reach", "OF_Route", "OF_Secure", "OF_ArmPower", "OF_ArmAccuracy", "OF_Release", "OF_PositionFit"],
	8: ["OF_Reach", "OF_Route", "OF_Secure", "OF_ArmPower", "OF_ArmAccuracy", "OF_Release", "OF_PositionFit"],
	9: ["OF_Reach", "OF_Route", "OF_Secure", "OF_ArmPower", "OF_ArmAccuracy", "OF_Release", "OF_PositionFit"],
}


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	print("Defense value calibration: preparing baseline")
	var original_players: Array = _snapshot_players()
	var baseline: Dictionary = _run_case("baseline", options, original_players, {})
	var position_rows: Array = []
	var target_positions: Array = options.get("positions", []) as Array
	if target_positions.is_empty():
		target_positions = POSITIONS.duplicate()
	for position_value in target_positions:
		var position: int = int(position_value)
		print("Defense value calibration: %s defense + batting probes" % _position_label(position))
		var defense_case: Dictionary = _run_case(
			"%s_defense_plus" % _position_label(position),
			options,
			original_players,
			{"kind": "defense", "position": position}
		)
		var batting_case: Dictionary = _run_case(
			"%s_batting_plus" % _position_label(position),
			options,
			original_players,
			{"kind": "batting", "position": position}
		)
		var defense_delta: Dictionary = _value_delta(baseline, defense_case)
		var batting_delta: Dictionary = _value_delta(baseline, batting_case)
		position_rows.append(_position_report_row(position, defense_case, batting_case, defense_delta, batting_delta))

	_restore_players(original_players)
	var report: Dictionary = {
		"version": 1,
		"seasons": int(options.get("seasons", 1)),
		"seed": int(options.get("seed", 12345)),
		"team_id": int(options.get("team_id", 1)),
		"delta_z": float(options.get("delta_z", 1.0)),
		"value_method": "0.35 * actual_delta_wins + 0.65 * run_differential_delta / 10",
		"baseline": baseline,
		"positions": position_rows,
	}
	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var ok: bool = _write_report(output_path, report)
	var weights_output_path: String = ""
	if ok and bool(options.get("write_weights", false)):
		weights_output_path = str(options.get("weights_output", DEFAULT_WEIGHTS_OUTPUT_PATH))
		ok = _write_weights(weights_output_path, report)
	_print_summary(report, output_path if ok else "", weights_output_path if ok else "")
	get_tree().quit(0 if ok else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seasons": 1,
		"team_id": 1,
		"start_year": 2026,
		"seed": 12345,
		"delta_z": 1.0,
		"positions": [],
		"output": DEFAULT_OUTPUT_PATH,
		"write_weights": false,
		"weights_output": DEFAULT_WEIGHTS_OUTPUT_PATH,
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
		elif arg.begins_with("--team="):
			options["team_id"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--start-year="):
			options["start_year"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--delta-z="):
			options["delta_z"] = float(arg.get_slice("=", 1))
		elif arg.begins_with("--positions="):
			options["positions"] = _parse_positions(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg == "--write-weights":
			options["write_weights"] = true
		elif arg.begins_with("--weights-output="):
			options["weights_output"] = arg.get_slice("=", 1)
	return options


func _parse_positions(text: String) -> Array[int]:
	var result: Array[int] = []
	for part in text.split(",", false):
		var position: int = int(str(part).strip_edges())
		if POSITIONS.has(position) and not result.has(position):
			result.append(position)
	return result


func _run_case(case_name: String, options: Dictionary, original_players: Array, modifier: Dictionary) -> Dictionary:
	_restore_players(original_players)
	if not modifier.is_empty():
		_apply_modifier(
			int(options.get("team_id", 1)),
			int(modifier.get("position", 0)),
			str(modifier.get("kind", "")),
			float(options.get("delta_z", 1.0))
		)
	var reporter: Object = ReporterScript.new()
	var report: Dictionary = reporter.call("run", {
		"seasons": int(options.get("seasons", 1)),
		"selected_team_id": int(options.get("team_id", 1)),
		"start_year": int(options.get("start_year", 2026)),
		"seed": int(options.get("seed", 12345)),
	}) as Dictionary
	var summary: Dictionary = _team_summary(report, int(options.get("team_id", 1)))
	summary["case"] = case_name
	summary["seasons_completed"] = int(report.get("seasons_completed", 0))
	return summary


func _apply_modifier(team_id: int, position: int, kind: String, delta_z: float) -> void:
	var keys: Array = BATTING_Z_KEYS if kind == "batting" else (DEFENSE_Z_KEYS_BY_POSITION.get(position, []) as Array)
	if keys.is_empty():
		return
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.team_id != team_id or player.is_pitcher():
			continue
		if not _matches_position(player, position):
			continue
		for key_value in keys:
			var key: String = str(key_value)
			player.z_abilities[key] = clamp(float(player.z_abilities.get(key, 0.0)) + delta_z, -4.0, 4.0)


func _matches_position(player: PSPlayer, position: int) -> bool:
	if player.position == position:
		return true
	var key: String = str(POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return false
	return int(player.position_aptitudes.get(key, 0)) >= 70


func _team_summary(report: Dictionary, team_id: int) -> Dictionary:
	var rows: Array = report.get("team_seasons", []) as Array
	var count: int = 0
	var games: float = 0.0
	var wins: float = 0.0
	var losses: float = 0.0
	var draws: float = 0.0
	var runs_scored: float = 0.0
	var runs_allowed: float = 0.0
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("team_id", 0)) != team_id:
			continue
		count += 1
		games += float(row.get("games", 0))
		wins += float(row.get("wins", 0))
		losses += float(row.get("losses", 0))
		draws += float(row.get("draws", 0))
		runs_scored += float(row.get("runs_scored", 0))
		runs_allowed += float(row.get("runs_allowed", 0))
	var divisor: float = max(1.0, float(count))
	var avg_games: float = games / divisor
	var avg_wins: float = wins / divisor
	var avg_runs_scored: float = runs_scored / divisor
	var avg_runs_allowed: float = runs_allowed / divisor
	return {
		"team_id": team_id,
		"seasons": count,
		"avg_games": _round_float(avg_games, 3),
		"avg_wins": _round_float(avg_wins, 3),
		"avg_losses": _round_float(losses / divisor, 3),
		"avg_draws": _round_float(draws / divisor, 3),
		"avg_win_rate": _round_float(avg_wins / max(1.0, avg_games), 4),
		"avg_runs_scored": _round_float(avg_runs_scored, 3),
		"avg_runs_allowed": _round_float(avg_runs_allowed, 3),
		"avg_run_diff": _round_float(avg_runs_scored - avg_runs_allowed, 3),
	}


func _value_delta(baseline: Dictionary, scenario: Dictionary) -> Dictionary:
	var delta_wins: float = float(scenario.get("avg_wins", 0.0)) - float(baseline.get("avg_wins", 0.0))
	var delta_run_diff: float = float(scenario.get("avg_run_diff", 0.0)) - float(baseline.get("avg_run_diff", 0.0))
	var wins_from_runs: float = delta_run_diff / 10.0
	var blended: float = delta_wins * 0.35 + wins_from_runs * 0.65
	return {
		"delta_wins": _round_float(delta_wins, 3),
		"delta_run_diff": _round_float(delta_run_diff, 3),
		"wins_from_runs": _round_float(wins_from_runs, 3),
		"blended_wins": _round_float(blended, 3),
	}


func _position_report_row(
	position: int,
	defense_case: Dictionary,
	batting_case: Dictionary,
	defense_delta: Dictionary,
	batting_delta: Dictionary
) -> Dictionary:
	var defense_value: float = max(0.0, float(defense_delta.get("blended_wins", 0.0)))
	var batting_value: float = max(0.0, float(batting_delta.get("blended_wins", 0.0)))
	var total: float = defense_value + batting_value
	var defense_share: float = 0.0
	var offense_weight: float = 0.0
	if total > 0.0:
		defense_share = defense_value / total
		offense_weight = batting_value / total
	return {
		"position": position,
		"label": _position_label(position),
		"defense_case": defense_case,
		"batting_case": batting_case,
		"defense_delta": defense_delta,
		"batting_delta": batting_delta,
		"positive_defense_value": _round_float(defense_value, 3),
		"positive_batting_value": _round_float(batting_value, 3),
		"suggested_defense_share": _round_float(defense_share, 3),
		"suggested_offense_weight": _round_float(offense_weight, 3),
	}


func _snapshot_players() -> Array:
	var rows: Array = []
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player != null:
			rows.append(player.to_dict())
	return rows


func _restore_players(rows: Array) -> void:
	if rows.is_empty():
		GameDb.load_initial_data()
		return
	GameDb.replace_players_from_rows(rows)


func _write_report(path: String, report: Dictionary) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(parent_dir)
	if make_dir_error != OK:
		print("Calibration report directory error: %s" % error_string(make_dir_error))
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Calibration report write error: %s" % path)
		return false
	file.store_string(JSON.stringify(report, "\t"))
	return true


func _write_weights(path: String, report: Dictionary) -> bool:
	var weights: Dictionary = {}
	var defense_shares: Dictionary = {}
	for row_value in report.get("positions", []) as Array:
		var row: Dictionary = row_value as Dictionary
		var position: int = int(row.get("position", 0))
		if position <= 0:
			continue
		var key: String = str(position)
		weights[key] = _round_float(clamp(float(row.get("suggested_offense_weight", 0.0)), 0.0, 1.0), 3)
		defense_shares[key] = _round_float(clamp(float(row.get("suggested_defense_share", 0.0)), 0.0, 1.0), 3)
	var payload: Dictionary = {
		"version": 1,
		"source": "defense_value_calibration",
		"source_method": str(report.get("value_method", "")),
		"team_id": int(report.get("team_id", 0)),
		"seasons": int(report.get("seasons", 0)),
		"seed": int(report.get("seed", 0)),
		"delta_z": float(report.get("delta_z", 0.0)),
		"offense_weight_by_position": weights,
		"defense_share_by_position": defense_shares,
	}
	return _write_report(path, payload)


func _print_summary(report: Dictionary, output_path: String, weights_output_path: String = "") -> void:
	print("Defense value calibration: seasons=%d seed=%d team=%d delta_z=%.2f" % [
		int(report.get("seasons", 0)),
		int(report.get("seed", 0)),
		int(report.get("team_id", 0)),
		float(report.get("delta_z", 0.0)),
	])
	if output_path != "":
		print("Output: %s" % ProjectSettings.globalize_path(output_path))
	if weights_output_path != "":
		print("Starter weights: %s" % ProjectSettings.globalize_path(weights_output_path))
	var baseline: Dictionary = report.get("baseline", {}) as Dictionary
	print("Baseline: wins %.1f run_diff %.1f" % [
		float(baseline.get("avg_wins", 0.0)),
		float(baseline.get("avg_run_diff", 0.0)),
	])
	for row_value in report.get("positions", []) as Array:
		var row: Dictionary = row_value as Dictionary
		print("%s: defense %.3f batting %.3f suggested offense %.3f defense %.3f" % [
			str(row.get("label", "")),
			float(row.get("positive_defense_value", 0.0)),
			float(row.get("positive_batting_value", 0.0)),
			float(row.get("suggested_offense_weight", 0.0)),
			float(row.get("suggested_defense_share", 0.0)),
		])


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_defense_value_calibration.tscn -- --seasons=1 --team=1 --seed=12345")
	print("Options:")
	print("  --seasons=N")
	print("  --team=ID")
	print("  --start-year=YYYY")
	print("  --seed=N")
	print("  --delta-z=1.0")
	print("  --positions=2,6,8")
	print("  --output=res://reports/defense_value_calibration_latest.json")
	print("  --write-weights")
	print("  --weights-output=res://data/tuning/starter_value_weights.json")


func _position_label(position: int) -> String:
	return str(POSITION_LABELS.get(position, "P%d" % position))


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
