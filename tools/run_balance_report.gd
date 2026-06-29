extends Node

const ReporterScript = preload("res://services/reports/simulation_reporter.gd")
const ReportHealth = preload("res://services/reports/report_health.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/balance_report_latest.json"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var reporter: Object = ReporterScript.new()
	var report: Dictionary
	if options.has("seeds"):
		report = _run_multi_seed(reporter, options)
	else:
		var report_value: Variant = reporter.call("run", options)
		report = report_value as Dictionary
	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var write_ok: bool = _write_report(output_path, report)
	_print_summary(report, output_path if write_ok else "")

	var completed: int = int(report.get("seasons_completed", 0))
	var multi_ok: bool = bool(report.get("multi_seed", false)) and int((report.get("seed_runs", []) as Array).size()) > 0
	get_tree().quit(0 if write_ok and (completed > 0 or multi_ok) else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seasons": 5,
		"selected_team_id": 1,
		"start_year": 2026,
		"seed": 12345,
		"output": DEFAULT_OUTPUT_PATH,
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
		if arg.begins_with("--seasons="):
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
		reports.append(reporter.call("run", run_options) as Dictionary)
	return {
		"multi_seed": true,
		"report_type": "balance_report",
		"seasons_requested": int(options.get("seasons", 0)),
		"seed_count": seed_values.size(),
		"seeds": seed_values,
		"summary": ReportHealth.multi_seed_summary(reports, {
			"ops": ["batting", "ops"],
			"era": ["pitching", "era"],
			"runs_per_team_game": ["run_environment", "runs_per_team_game"],
			"batter_ops_max": ["distributions", "batters", "ops", "max"],
			"pitcher_era_min": ["distributions", "pitchers", "era", "min"],
		}),
		"seed_runs": reports,
	}


func _write_report(path: String, report: Dictionary) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(parent_dir)
	if make_dir_error != OK:
		print("Report directory error: %s" % error_string(make_dir_error))
		return false

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Report write error: %s" % path)
		return false

	file.store_string(JSON.stringify(report, "\t"))
	return true


func _print_summary(report: Dictionary, output_path: String) -> void:
	if bool(report.get("multi_seed", false)):
		_print_multi_seed_summary(report, output_path)
		return
	var run_environment: Dictionary = report.get("run_environment", {}) as Dictionary
	var batting: Dictionary = report.get("batting", {}) as Dictionary
	var pitching: Dictionary = report.get("pitching", {}) as Dictionary
	var batted_ball: Dictionary = report.get("batted_ball", {}) as Dictionary
	var advanced: Dictionary = report.get("advanced", {}) as Dictionary
	var advanced_players: Dictionary = advanced.get("players", {}) as Dictionary
	var advanced_pitchers: Dictionary = advanced.get("pitchers", {}) as Dictionary
	var completed: int = int(report.get("seasons_completed", 0))
	var requested: int = int(report.get("seasons_requested", 0))

	print("Balance report: %d/%d seasons" % [completed, requested])
	if output_path != "":
		print("Output: %s" % ProjectSettings.globalize_path(output_path))
	print("Run scoring: %.3f runs/team-game, %.3f runs/game total" % [
		float(run_environment.get("runs_per_team_game", 0.0)),
		float(run_environment.get("runs_per_game_total", 0.0)),
	])
	print("Batting: AVG %.3f OBP %.3f SLG %.3f OPS %.3f HR/G %.3f SO/G %.3f" % [
		float(batting.get("batting_average", 0.0)),
		float(batting.get("on_base_percentage", 0.0)),
		float(batting.get("slugging_percentage", 0.0)),
		float(batting.get("ops", 0.0)),
		float(batting.get("home_runs_per_game", 0.0)),
		float(batting.get("strikeouts_per_game", 0.0)),
	])
	print("Running: SB/G %.3f SBA/G %.3f SB%% %.3f" % [
		float(batting.get("stolen_bases_per_game", 0.0)),
		float(batting.get("stolen_base_attempts_per_game", 0.0)),
		float(batting.get("stolen_base_success_rate", 0.0)),
	])
	var b_pa: int = int(batting.get("plate_appearances", 0))
	var b_ab: int = int(batting.get("at_bats", 0))
	var b_k: int = int(batting.get("strikeouts", 0))
	var b_bb: int = int(batting.get("walks", 0))
	var b_hr: int = int(batting.get("home_runs", 0))
	print("Pitching: ERA %.2f WHIP %.3f PA/K %.2f PA/BB %.2f AB/HR %.2f P/BF %.2f P/IP %.1f" % [
		float(pitching.get("era", 0.0)),
		float(pitching.get("whip", 0.0)),
		(float(b_pa) / float(b_k)) if b_k > 0 else 0.0,
		(float(b_pa) / float(b_bb)) if b_bb > 0 else 0.0,
		(float(b_ab) / float(b_hr)) if b_hr > 0 else 0.0,
		float(pitching.get("pitches_per_batter_faced", 0.0)),
		float(pitching.get("pitches_per_inning", 0.0)),
	])
	print("Batted ball: count %d EV %.1f LA %.1f barrel%% %.1f hard-hit%% %.1f HR barrel%% %.1f" % [
		int(batted_ball.get("batted_balls", 0)),
		float(batted_ball.get("average_exit_velocity", 0.0)),
		float(batted_ball.get("average_launch_angle", 0.0)),
		float(batted_ball.get("barrel_rate", 0.0)) * 100.0,
		float(batted_ball.get("hard_hit_rate", 0.0)) * 100.0,
		float(batted_ball.get("home_run_barrel_rate", 0.0)) * 100.0,
	])
	if int(advanced_players.get("plate_appearances", 0)) > 0 or int(advanced_pitchers.get("plate_appearances", 0)) > 0:
		print("Advanced batting: PA %d wOBA %.3f xwOBA %.3f wRC+ %.1f RE24 %.1f BsR %.1f" % [
			int(advanced_players.get("plate_appearances", 0)),
			float(advanced_players.get("woba", 0.0)),
			float(advanced_players.get("xwoba", 0.0)),
			float(advanced_players.get("wrc_plus", 0.0)),
			float(advanced_players.get("re24", 0.0)),
			float(advanced_players.get("bsr", 0.0)),
		])
		print("Advanced pitching: BF %d wOBA %.3f xwOBA %.3f wRC+ %.1f RE24 %.1f BsR %.1f" % [
			int(advanced_pitchers.get("plate_appearances", 0)),
			float(advanced_pitchers.get("woba", 0.0)),
			float(advanced_pitchers.get("xwoba", 0.0)),
			float(advanced_pitchers.get("wrc_plus", 0.0)),
			float(advanced_pitchers.get("re24", 0.0)),
			float(advanced_pitchers.get("bsr", 0.0)),
		])
		var oaa_zone_label: String = _oaa_zone_label(str(advanced_players.get("primary_oaa_zone", "")))
		var uzr_pos_label: String = _uzr_position_label(int(advanced_players.get("primary_uzr_position", 0)))
		# OAA / UZR は集計対象ゾーン / ポジション (= 守備機会の多い方) を明示する。
		print("Advanced fielding: chances %d OAA[%s] %.1f (IF %.1f OF %.1f) UZR[%s] %.1f RngR %.1f ErrR %.1f DPR %.1f DRS %.1f PosAdj %.1f Def %.1f" % [
			int(advanced_players.get("fielding_chances", 0)),
			oaa_zone_label,
			float(advanced_players.get("oaa", 0.0)),
			float(advanced_players.get("oaa_infield", 0.0)),
			float(advanced_players.get("oaa_outfield", 0.0)),
			uzr_pos_label,
			float(advanced_players.get("uzr", 0.0)),
			float(advanced_players.get("rngr", 0.0)),
			float(advanced_players.get("errr", 0.0)),
			float(advanced_players.get("dpr", 0.0)),
			float(advanced_players.get("drs", 0.0)),
			float(advanced_players.get("positional_adjustment_runs", 0.0)),
			float(advanced_players.get("def_runs", 0.0)),
		])
	else:
		print("Advanced: no full play-event data")

	_print_war_allocation(report.get("war_allocation", {}) as Dictionary)

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


# Phase 0 計測: リーグ WAR 配分・per-team・ベンチマーク選手WAR・負WAR率を、参照目標(57:43/.294)と並べて表示。
func _print_war_allocation(war_alloc: Dictionary) -> void:
	if war_alloc.is_empty():
		return
	var reference: Dictionary = war_alloc.get("reference", {}) as Dictionary
	var benchmarks: Dictionary = war_alloc.get("benchmarks", {}) as Dictionary
	var batting_target_share: float = float(reference.get("batting_share_target", 0.0)) * 100.0
	var pitching_target_share: float = float(reference.get("pitching_share_target", 0.0)) * 100.0
	print("WAR split: batting %.1f (%.0f%%) / pitching %.1f (%.0f%%)  [target %.0f%% / %.0f%%]" % [
		float(war_alloc.get("batting_war_total", 0.0)), float(war_alloc.get("batting_share", 0.0)) * 100.0,
		float(war_alloc.get("pitching_war_total", 0.0)), float(war_alloc.get("pitching_share", 0.0)) * 100.0,
		batting_target_share, pitching_target_share,
	])
	print("WAR per team-season: batting %.2f / pitching %.2f  [target bat %.2f / pit %.2f, pool %.2f]" % [
		float(war_alloc.get("batting_war_per_team_season", 0.0)), float(war_alloc.get("pitching_war_per_team_season", 0.0)),
		float(reference.get("batting_target_per_team_season", 0.0)), float(reference.get("pitching_target_per_team_season", 0.0)),
		float(reference.get("pool_per_team_season", 0.0)),
	])
	print("WAR benchmarks (avg player): batter(600PA) %.2f / starter(162IP) %.2f / reliever(60IP) %.2f" % [
		float(benchmarks.get("avg_batter_war_per_600_pa", 0.0)),
		float(benchmarks.get("avg_starter_war_per_162_ip", 0.0)),
		float(benchmarks.get("avg_reliever_war_per_60_ip", 0.0)),
	])
	print("WAR negatives: pitchers %d/%d (%.0f%%) / batters %d/%d (%.0f%%)" % [
		int(war_alloc.get("negative_pitchers", 0)), int(war_alloc.get("pitcher_count", 0)), float(war_alloc.get("negative_pitcher_rate", 0.0)) * 100.0,
		int(war_alloc.get("negative_batters", 0)), int(war_alloc.get("batter_count", 0)), float(war_alloc.get("negative_batter_rate", 0.0)) * 100.0,
	])


func _print_multi_seed_summary(report: Dictionary, output_path: String) -> void:
	var summary: Dictionary = report.get("summary", {}) as Dictionary
	var statuses: Dictionary = summary.get("statuses", {}) as Dictionary
	print("Balance report multi-seed: %d seeds x %d seasons" % [
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
		print("Output: %s" % ProjectSettings.globalize_path(output_path))


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_balance_report.tscn -- --seasons=5 --seed=12345")
	print("Options:")
	print("  --seasons=N")
	print("  --selected-team=ID")
	print("  --start-year=YYYY")
	print("  --seed=N")
	print("  --seeds=1,2,3  (multi-seed JSON aggregation)")
	print("  --output=res://reports/balance_report_latest.json")


# OAA ゾーンを内部表現 "infield" / "outfield" から表示用 "IF" / "OF" に変換。
# OAA はゾーン単位 (内野 / 外野) の集計値なので、どちら側を集計したかを示す。
func _oaa_zone_label(zone: String) -> String:
	match zone:
		"infield":
			return "IF"
		"outfield":
			return "OF"
		_:
			return "-"


# UZR / RngR / ErrR / DPR はポジション単位の集計値なので、どのポジション (1-9) を
# 集計したかを示す。0 (未集計) の場合は "-" を返す。
func _uzr_position_label(position: int) -> String:
	if position <= 0 or position > 9:
		return "-"
	return "P%d" % position
