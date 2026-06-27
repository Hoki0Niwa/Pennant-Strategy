extends Node

signal data_loaded

const TEAM_DATA_PATH = "res://data/initial_teams.json"
const PLAYER_DATA_PATH = "res://data/initial_players.json"
const SQLITE_DATA_PATH = "res://data/pennant_strategy.sqlite"
# 本ゲーム由来のシード。存在すれば CSV を最優先し、無ければ SQLite/JSON へフォールバックする。
const CSV_PLAYER_PATH = "res://data/initial_players.csv"
const CSV_TEAM_PATH = "res://data/initial_teams.csv"


var data_loaded_ok: bool = false
var data_source: String = "json"
var teams: Array = []
var teams_by_id: Dictionary = {}
var players: Array = []
var players_by_id: Dictionary = {}
var players_by_team: Dictionary = {}


func _ready() -> void:
	load_initial_data()


func load_initial_data() -> void:
	teams.clear()
	teams_by_id.clear()
	players.clear()
	players_by_id.clear()
	players_by_team.clear()

	# CSV は現在の正準シード形式。存在しない環境だけ SQLite/JSON へフォールバックする。
	if _load_initial_data_from_csv():
		data_loaded_ok = true
		data_loaded.emit()
		return

	if _load_initial_data_from_sqlite():
		_overlay_phase1_fields_from_json()
		data_loaded_ok = true
		data_loaded.emit()
		return

	_load_initial_data_from_json()
	data_loaded_ok = true
	data_loaded.emit()


# SQLite シードを使う環境では、SQLite に無い追加フィールドを JSON から id 一致で重ねる。
# z_abilities や起用固定情報が欠けたまま起動しないようにするための補完ルート。
func _overlay_phase1_fields_from_json() -> void:
	var player_data_path: String = ModManager.resolve_data_path("initial_players_json", PLAYER_DATA_PATH)
	if not FileAccess.file_exists(player_data_path):
		return
	var file: FileAccess = FileAccess.open(player_data_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Array):
		return
	var rows: Array = parsed as Array
	for row_value in rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var player_id: int = int(row.get("id", 0))
		var player: PSPlayer = players_by_id.get(player_id) as PSPlayer
		if player == null:
			continue
		var z_abilities_value: Variant = row.get("z_abilities", null)
		if z_abilities_value is Dictionary:
			player.z_abilities = (z_abilities_value as Dictionary).duplicate(true)
		if row.has("condition"):
			player.condition = clampi(int(row.get("condition", 0)), PSPlayer.CONDITION_MIN, PSPlayer.CONDITION_MAX)
		if row.has("fixed_slot"):
			player.fixed_slot = int(row.get("fixed_slot", 0))
		if row.has("allowed_slots"):
			player.allowed_slots = _normalize_slot_list(row.get("allowed_slots", []))
		if row.has("preferred_slots"):
			player.preferred_slots = _normalize_slot_list(row.get("preferred_slots", []))


func _normalize_slot_list(source: Variant) -> Array[int]:
	var result: Array[int] = []
	if not (source is Array):
		return result
	for raw in source:
		var slot: int = int(raw)
		if slot >= 1 and slot <= 9 and not result.has(slot):
			result.append(slot)
	return result


func _load_initial_data_from_csv() -> bool:
	var player_path: String = ModManager.resolve_data_path("initial_players", CSV_PLAYER_PATH)
	var team_path: String = ModManager.resolve_data_path("initial_teams", CSV_TEAM_PATH)
	if not (FileAccess.file_exists(player_path) and FileAccess.file_exists(team_path)):
		return false
	var team_rows: Array = PSPlayerCsvIo.read_teams(team_path)
	var player_rows: Array = PSPlayerCsvIo.normalize_initial_seed_players(
		PSPlayerCsvIo.read_players(player_path),
		SeasonService.DEFAULT_START_YEAR
	)
	if team_rows.is_empty() or player_rows.is_empty():
		return false

	for row in team_rows:
		var team: PSTeam = PSTeam.from_dict(row as Dictionary)
		teams.append(team)
		teams_by_id[team.id] = team

	for row in player_rows:
		var player: PSPlayer = PSPlayer.from_dict(row as Dictionary)
		players.append(player)
		players_by_id[player.id] = player
		if not players_by_team.has(player.team_id):
			players_by_team[player.team_id] = []
		players_by_team[player.team_id].append(player)

	data_source = "csv"
	return true


func _load_initial_data_from_json() -> void:
	data_source = "json"
	var team_path: String = ModManager.resolve_data_path("initial_teams_json", TEAM_DATA_PATH)
	var player_path: String = ModManager.resolve_data_path("initial_players_json", PLAYER_DATA_PATH)
	var team_rows: Array = _read_json_array(team_path)
	for row in team_rows:
		var team: PSTeam = PSTeam.from_dict(row as Dictionary)
		teams.append(team)
		teams_by_id[team.id] = team

	var player_rows: Array = _read_json_array(player_path)
	for row in player_rows:
		var player: PSPlayer = PSPlayer.from_dict(row as Dictionary)
		players.append(player)
		players_by_id[player.id] = player
		if not players_by_team.has(player.team_id):
			players_by_team[player.team_id] = []
		players_by_team[player.team_id].append(player)


func _load_initial_data_from_sqlite() -> bool:
	var sqlite_path: String = ModManager.resolve_data_path("initial_sqlite", SQLITE_DATA_PATH)
	if not FileAccess.file_exists(sqlite_path):
		return false
	if not ClassDB.class_exists("SQLite"):
		return false

	var db: Object = ClassDB.instantiate("SQLite") as Object
	if db == null:
		return false
	db.set("path", sqlite_path)
	db.set("read_only", true)
	db.set("verbosity_level", 0)
	if not bool(db.call("open_db")):
		return false

	var team_rows: Array = _sqlite_query(db, "SELECT id, name, short_name, league, color, previous_rank, funds, ratings_json FROM teams ORDER BY id")
	var player_columns: Dictionary = _sqlite_table_columns(db, "players")
	var position_experience_select: String = "position_experience_json" if player_columns.has("position_experience_json") else "'{}' AS position_experience_json"
	# 旧 *_abilities_json 列は読まない (apply_dict は z_abilities のみ参照)。
	var player_rows: Array = _sqlite_query(db, "SELECT id, sensyu_num, jersey_number, development_player, team_id, name, age, years, height, weight, position, role, throwing_hand, batting_side, salary, draft_round, hometown, registered_roster, contract_status, foreign_player, position_aptitudes_json, %s, source_data_json, fatigue, injury_days FROM players ORDER BY id" % position_experience_select)
	if db.has_method("close_db"):
		db.call("close_db")

	if team_rows.is_empty() or player_rows.is_empty():
		return false

	for row in team_rows:
		var team_row: Dictionary = row as Dictionary
		var team: PSTeam = PSTeam.from_dict(_team_row_from_sqlite(team_row))
		teams.append(team)
		teams_by_id[team.id] = team

	for row in player_rows:
		var player_row: Dictionary = row as Dictionary
		var player: PSPlayer = PSPlayer.from_dict(_player_row_from_sqlite(player_row))
		players.append(player)
		players_by_id[player.id] = player
		if not players_by_team.has(player.team_id):
			players_by_team[player.team_id] = []
		players_by_team[player.team_id].append(player)

	data_source = "sqlite"
	return true


func _sqlite_query(db: Object, sql: String) -> Array:
	if not bool(db.call("query", sql)):
		return []
	var result: Variant = db.get("query_result")
	if result is Array:
		return result as Array
	return []


func _sqlite_table_columns(db: Object, table_name: String) -> Dictionary:
	var columns: Dictionary = {}
	var rows: Array = _sqlite_query(db, "PRAGMA table_info(%s)" % table_name)
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var column_name: String = str(row.get("name", ""))
		if not column_name.is_empty():
			columns[column_name] = true
	return columns


func _team_row_from_sqlite(row: Dictionary) -> Dictionary:
	return {
		"id": int(row.get("id", 0)),
		"name": str(row.get("name", "")),
		"short_name": str(row.get("short_name", "")),
		"league": str(row.get("league", "")),
		"color": str(row.get("color", "#ffffff")),
		"previous_rank": int(row.get("previous_rank", 0)),
		"funds": int(row.get("funds", 0)),
		"ratings": _json_dict(str(row.get("ratings_json", "{}"))),
	}


func _player_row_from_sqlite(row: Dictionary) -> Dictionary:
	return {
		"id": int(row.get("id", 0)),
		"sensyu_num": int(row.get("sensyu_num", 0)),
		"jersey_number": int(row.get("jersey_number", 0)),
		"development_player": bool(int(row.get("development_player", 0))),
		"team_id": int(row.get("team_id", 0)),
		"name": str(row.get("name", "")),
		"age": int(row.get("age", 18)),
		"years": int(row.get("years", 1)),
		"height": int(row.get("height", 180)),
		"weight": int(row.get("weight", 80)),
		"position": int(row.get("position", 1)),
		"role": str(row.get("role", "fielder")),
		"throws": str(row.get("throwing_hand", "R")),
		"bats": str(row.get("batting_side", "R")),
		"salary": int(row.get("salary", 1000)),
		"draft_round": int(row.get("draft_round", 0)),
		"hometown": str(row.get("hometown", "")),
		"registered_roster": str(row.get("registered_roster", "支配下")),
		"contract_status": str(row.get("contract_status", "通常")),
		"foreign_player": bool(int(row.get("foreign_player", 0))),
		"position_aptitudes": _json_dict(str(row.get("position_aptitudes_json", "{}"))),
		"position_experience": _json_dict(str(row.get("position_experience_json", "{}"))),
		"source_data": _json_dict(str(row.get("source_data_json", "{}"))),
		"fatigue": int(row.get("fatigue", 0)),
		"injury_days": int(row.get("injury_days", 0)),
	}


func _json_dict(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func get_team(team_id: int) -> PSTeam:
	return teams_by_id.get(team_id) as PSTeam


func get_players_for_team(team_id: int) -> Array:
	return players_by_team.get(team_id, []) as Array


func get_player(player_id: int) -> PSPlayer:
	return players_by_id.get(player_id) as PSPlayer


func get_team_count() -> int:
	return teams.size()


func get_player_count() -> int:
	return players.size()


func advance_players_one_year() -> void:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		player.age += 1
		player.years += 1


func rebuild_player_indices() -> void:
	players_by_id.clear()
	players_by_team.clear()
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		players_by_id[player.id] = player
		if not players_by_team.has(player.team_id):
			players_by_team[player.team_id] = []
		players_by_team[player.team_id].append(player)


func replace_players_from_rows(player_rows: Array) -> void:
	var sanitized_rows: Array = _sanitize_player_rows(player_rows)
	if sanitized_rows.is_empty():
		push_warning("Saved player rows did not contain initial players; keeping bundled initial data.")
		return

	players.clear()
	players_by_id.clear()
	players_by_team.clear()

	for row in sanitized_rows:
		var player: PSPlayer = PSPlayer.from_dict(row as Dictionary)
		players.append(player)
		players_by_id[player.id] = player
		if not players_by_team.has(player.team_id):
			players_by_team[player.team_id] = []
		players_by_team[player.team_id].append(player)


func _read_json_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("Missing data file: %s" % path)
		return []

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open data file: %s" % path)
		return []

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Array:
		return parsed as Array

	push_error("Data file must contain a JSON array: %s" % path)
	return []


func _sanitize_player_rows(player_rows: Array) -> Array:
	var rows: Array = []
	for row in player_rows:
		if not (row is Dictionary):
			continue
		var row_data: Dictionary = row as Dictionary
		var source: Dictionary = row_data.get("source_data", {}) as Dictionary
		if str(source.get("source_table", "")) == "SENSYU_DATA_INIT":
			rows.append(row_data)
			continue
		if str(source.get("generated_by", "")) == "pennant_strategy":
			rows.append(row_data)
			continue
		if _looks_like_saved_player_row(row_data):
			rows.append(row_data)
	return rows


func _looks_like_saved_player_row(row_data: Dictionary) -> bool:
	if int(row_data.get("id", 0)) <= 0:
		return false
	if str(row_data.get("name", "")).is_empty():
		return false
	if int(row_data.get("team_id", -1)) < 0:
		return false
	if int(row_data.get("position", 0)) <= 0:
		return false
	return row_data.get("z_abilities", {}) is Dictionary
