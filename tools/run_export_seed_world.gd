extends Node

# 本ゲームのペナントを N 年（既定 40）自動進行させ、その時点の球団・選手を
# 初期データ用 CSV として書き出す。借り物の初期選手を廃止し、本ゲーム由来のシードに置き換える。
#
# 進化ロジックは PSLongAutoplayReporter を keep_world=true で再利用する（復元せず最終状態を残す）。
#
# 使い方:
#   godot --headless --path . --scene res://tools/run_export_seed_world.tscn -- --seasons=40 --seed=20260528
# 出力:
#   data/initial_players.csv / data/initial_teams.csv（既定）

const ReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const PSPlayerCsvIo = preload("res://services/data/player_csv_io.gd")

const DEFAULT_PLAYERS_PATH: String = "res://data/initial_players.csv"
const DEFAULT_TEAMS_PATH: String = "res://data/initial_teams.csv"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var seasons: int = int(options.get("seasons", 40))
	var seed: int = int(options.get("seed", 20260528))
	var players_path: String = str(options.get("players", DEFAULT_PLAYERS_PATH))
	var teams_path: String = str(options.get("teams", DEFAULT_TEAMS_PATH))

	print("Export seed world: evolving %d seasons (seed=%d) ..." % [seasons, seed])
	var reporter: Object = ReporterScript.new()
	var report: Dictionary = reporter.run({
		"seasons": seasons,
		"seed": seed,
		"keep_world": true,
	})

	var completed: int = int(report.get("seasons_completed", 0))
	if completed <= 0:
		print("Evolution failed: %s" % JSON.stringify(report.get("errors", [])))
		get_tree().quit(1)
		return

	var player_dicts: Array = PSPlayerCsvIo.normalize_initial_seed_players(
		_active_player_dicts(),
		SeasonService.DEFAULT_START_YEAR
	)
	var team_dicts: Array = _team_dicts()

	var players_ok: bool = PSPlayerCsvIo.write_players(players_path, player_dicts)
	var teams_ok: bool = PSPlayerCsvIo.write_teams(teams_path, team_dicts)

	print("Seasons completed: %d/%d (end_year=%d)" % [
		completed, int(report.get("seasons_requested", 0)), int(report.get("end_year", 0)),
	])
	print("Exported players: %d -> %s" % [player_dicts.size(), ProjectSettings.globalize_path(players_path)])
	print("Exported teams:   %d -> %s" % [team_dicts.size(), ProjectSettings.globalize_path(teams_path)])
	var final_roster: Dictionary = report.get("final_roster_after_last_offseason", {}) as Dictionary
	print("Final roster: active %d  draft ratio %.1f%%  avg overall %.1f  avg age %.1f" % [
		int(final_roster.get("active_players", 0)),
		float(final_roster.get("draft_generated_ratio", 0.0)) * 100.0,
		float(final_roster.get("average_overall", 0.0)),
		float(final_roster.get("average_age", 0.0)),
	])

	get_tree().quit(0 if players_ok and teams_ok else 1)


# 球団に所属し現役の選手のみをシード対象にする（PSLongAutoplayReporter._is_active_roster_player 相当）。
func _active_player_dicts() -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired() or player.is_manager_candidate():
			continue
		rows.append(player.to_dict())
	rows.sort_custom(func(a, b) -> bool:
		var ta: int = int((a as Dictionary).get("team_id", 0))
		var tb: int = int((b as Dictionary).get("team_id", 0))
		if ta == tb:
			return int((a as Dictionary).get("id", 0)) < int((b as Dictionary).get("id", 0))
		return ta < tb
	)
	return rows


func _team_dicts() -> Array:
	var rows: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			rows.append(team.to_dict())
	return rows


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seasons": 40,
		"seed": 20260528,
		"players": DEFAULT_PLAYERS_PATH,
		"teams": DEFAULT_TEAMS_PATH,
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
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--players="):
			options["players"] = arg.get_slice("=", 1)
		elif arg.begins_with("--teams="):
			options["teams"] = arg.get_slice("=", 1)
	return options


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_export_seed_world.tscn -- --seasons=40 --seed=20260528")
	print("Options:")
	print("  --seasons=N    進行年数 (既定 40)")
	print("  --seed=N       乱数シード (既定 20260528)")
	print("  --players=PATH 出力先 (既定 res://data/initial_players.csv)")
	print("  --teams=PATH   出力先 (既定 res://data/initial_teams.csv)")
