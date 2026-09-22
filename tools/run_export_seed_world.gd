extends Node

# 本ゲームのペナントを N 年（既定 40）自動進行させ、その時点の球団・選手と、選手が開始前に残した
# 成績を初期データとして書き出す。初期選手を本ゲーム由来のシードで用意するためのツール。
#
# 進化ロジックは PSLongAutoplayReporter を keep_world=true / collect_history=true で再利用し
# （復元せず最終状態を残す）、書き出しは PSSeedWorldExporter に任せる。
#
# 使い方:
#   godot --headless --path . --scene res://tools/run_export_seed_world.tscn -- --seasons=40 --seed=20260528
# 出力（既定）:
#   data/initial_players.csv / data/initial_teams.csv / data/initial_player_records.csv /
#   data/initial_seasons.json

const ReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
# 出力先の上書き (コマンドライン引数のキー → PSSeedWorldExporter.DEFAULT_PATHS のキー)。
const PATH_OPTIONS: Dictionary = {
	"players": "players",
	"teams": "teams",
	"records": "player_records",
	"seasons_history": "seasons",
}


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var seasons: int = int(options.get("seasons", 40))
	var seed_value: int = int(options.get("seed", 20260528))
	var paths: Dictionary = {}
	for option_key in PATH_OPTIONS.keys():
		if options.has(option_key):
			paths[PATH_OPTIONS[option_key]] = str(options[option_key])

	print("Export seed world: evolving %d seasons (seed=%d) ..." % [seasons, seed_value])
	var reporter: PSLongAutoplayReporter = ReporterScript.new()
	var report: Dictionary = reporter.run({
		"seasons": seasons,
		"seed": seed_value,
		"keep_world": true,
		"collect_history": true,
	})

	var completed: int = int(report.get("seasons_completed", 0))
	if completed <= 0:
		print("Evolution failed: %s" % JSON.stringify(report.get("errors", [])))
		get_tree().quit(1)
		return

	var exported: Dictionary = PSSeedWorldExporter.export_world(reporter, int(report.get("end_year", 0)), paths)
	var written_paths: Dictionary = exported.get("paths", {}) as Dictionary

	print("Seasons completed: %d/%d (end_year=%d)" % [
		completed, int(report.get("seasons_requested", 0)), int(report.get("end_year", 0)),
	])
	print("Exported players: %d (overseas %d) -> %s" % [
		int(exported.get("players", 0)), int(exported.get("overseas_players", 0)),
		ProjectSettings.globalize_path(str(written_paths.get("players", ""))),
	])
	print("Exported teams:   %d -> %s" % [
		int(exported.get("teams", 0)), ProjectSettings.globalize_path(str(written_paths.get("teams", ""))),
	])
	print("Exported records: %d player-seasons, %d seasons (from %d, year offset %d) -> %s" % [
		int(exported.get("player_records", 0)), int(exported.get("seasons", 0)),
		int(exported.get("first_year", 0)), int(exported.get("year_offset", 0)),
		ProjectSettings.globalize_path(str(written_paths.get("player_records", ""))),
	])
	var final_roster: Dictionary = report.get("final_roster_after_last_offseason", {}) as Dictionary
	print("Final roster: active %d  draft ratio %.1f%%  avg overall %.1f  avg age %.1f" % [
		int(final_roster.get("active_players", 0)),
		float(final_roster.get("draft_generated_ratio", 0.0)) * 100.0,
		float(final_roster.get("average_overall", 0.0)),
		float(final_roster.get("average_age", 0.0)),
	])

	get_tree().quit(0 if bool(exported.get("ok", false)) else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seasons": 40,
		"seed": 20260528,
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
		elif arg.begins_with("--records="):
			options["records"] = arg.get_slice("=", 1)
		elif arg.begins_with("--seasons-history="):
			options["seasons_history"] = arg.get_slice("=", 1)
	return options


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_export_seed_world.tscn -- --seasons=40 --seed=20260528")
	print("Options:")
	print("  --seasons=N    進行年数 (既定 40)")
	print("  --seed=N       乱数シード (既定 20260528)")
	print("  --players=PATH 出力先 (既定 res://data/initial_players.csv)")
	print("  --teams=PATH   出力先 (既定 res://data/initial_teams.csv)")
	print("  --records=PATH 開始前の選手成績の出力先 (既定 res://data/initial_player_records.csv)")
	print("  --seasons-history=PATH 開始前の季の履歴の出力先 (既定 res://data/initial_seasons.json)")
