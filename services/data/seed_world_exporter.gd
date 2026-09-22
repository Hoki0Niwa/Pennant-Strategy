extends RefCounted
class_name PSSeedWorldExporter

# 進化させた世界を初期世界のシードとして書き出す。PSLongAutoplayReporter を
# keep_world=true / collect_history=true で回した直後の GameDb と reporter を渡す。
# ツール (tools/run_export_seed_world) とオプション画面の再生成の両方がここを通る。
#
# 書き出すもの:
# - 選手: 球団に所属する現役 + 海外組 (メジャー挑戦中)。海外組は retired=true で名簿には出ないが、
#   開始後に古巣へ戻ってくる (OverseasService)。引退者・帰国した外国人は入れない。
# - 球団
# - 開始前の年の選手成績と季の履歴 (PSSeedHistoryIo)。上の選手の分だけ。
#
# 進化 run の年は、経歴ログと同じオフセット (PSPlayerCsvIo.career_log_year_offset) で
# 「最終季 = 開始年の前年」になるようずらす。経歴ログと成績の年がずれないよう、同じ値を使う。

const DEFAULT_PATHS: Dictionary = {
	"players": "res://data/initial_players.csv",
	"teams": "res://data/initial_teams.csv",
	"player_records": "res://data/initial_player_records.csv",
	"seasons": "res://data/initial_seasons.json",
}


# paths は DEFAULT_PATHS の一部を上書きする。返り値は件数と成否 ({"ok": bool, ...})。
static func export_world(reporter: PSLongAutoplayReporter, end_year: int, paths: Dictionary = {}, initial_year: int = SeasonService.DEFAULT_START_YEAR) -> Dictionary:
	var resolved: Dictionary = DEFAULT_PATHS.duplicate()
	resolved.merge(paths, true)

	var raw_players: Array = seed_player_dicts(GameDb.players)
	var year_offset: int = PSPlayerCsvIo.career_log_year_offset(raw_players, initial_year)
	var expected_offset: int = end_year - (initial_year - 1)
	if end_year > 0 and year_offset != expected_offset:
		push_warning("PSSeedWorldExporter: career log offset %d != season offset %d (end_year=%d)" % [year_offset, expected_offset, end_year])
	var players: Array = PSPlayerCsvIo.normalize_initial_seed_players(raw_players, initial_year)
	var teams: Array = team_dicts(GameDb.teams)

	var record_rows: Array = []
	var overseas_count: int = 0
	for player_value in players:
		var row: Dictionary = player_value as Dictionary
		if (row.get("source_data", {}) as Dictionary).has(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR):
			overseas_count += 1
		record_rows.append_array(reporter.history_records.get(int(row.get("id", 0)), []) as Array)
	record_rows = PSSeedHistoryIo.shift_record_rows(record_rows, year_offset, initial_year)
	record_rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["player_id"]) != int(db["player_id"]):
			return int(da["player_id"]) < int(db["player_id"])
		return int(da["year"]) < int(db["year"])
	)
	# 季の履歴は、書き出す選手の誰かが出場した最古の季から。それより前の季は誰の成績にも使われない。
	var first_year: int = initial_year
	for row_value in record_rows:
		first_year = mini(first_year, int((row_value as Dictionary)["year"]))
	var seasons: Array = PSSeedHistoryIo.shift_season_entries(reporter.history_seasons, year_offset, initial_year).filter(
		func(entry: Variant) -> bool: return int((entry as Dictionary)["year"]) >= first_year
	)

	var ok: bool = PSPlayerCsvIo.write_players(str(resolved["players"]), players)
	ok = PSPlayerCsvIo.write_teams(str(resolved["teams"]), teams) and ok
	ok = PSSeedHistoryIo.write_records(str(resolved["player_records"]), record_rows) and ok
	ok = PSSeedHistoryIo.write_seasons(str(resolved["seasons"]), seasons) and ok
	return {
		"ok": ok,
		"players": players.size(),
		"overseas_players": overseas_count,
		"teams": teams.size(),
		"player_records": record_rows.size(),
		"seasons": seasons.size(),
		"first_year": first_year,
		"year_offset": year_offset,
		"paths": resolved,
	}


# シードに入れる選手: 12 球団に所属する現役と海外組。現役を球団順・ID 順に並べ、海外組は末尾に置く
# (players の先頭は球団所属の現役、という並びを崩さない)。
# ファーム専用球団の選手は入れない — 専用球団のロスターは読み込み時に生成する (GameDb._finish_initial_load)。
static func seed_player_dicts(players: Array) -> Array:
	var rows: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		var active: bool = player.team_id > 0 and not player.is_retired()
		if not active and not player.is_overseas():
			continue
		rows.append(player.to_dict())
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ta: int = _team_sort_key(int((a as Dictionary).get("team_id", 0)))
		var tb: int = _team_sort_key(int((b as Dictionary).get("team_id", 0)))
		if ta == tb:
			return int((a as Dictionary).get("id", 0)) < int((b as Dictionary).get("id", 0))
		return ta < tb
	)
	return rows


# 海外組 (team_id 0) を末尾へ回す並び順のキー。
static func _team_sort_key(team_id: int) -> int:
	return team_id if team_id > 0 else 1 << 30


# 予算はシードに焼き込まず常に固定額で書き出す (進化後の funds をそのまま出すと球団ごとに
# バラバラな値がシードへ入り、新規ペナントで固定予算制が崩れる)。
static func team_dicts(teams: Array) -> Array:
	TeamFinance.apply_fixed_budget(teams)
	var rows: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			rows.append(team.to_dict())
	return rows
