extends Node

signal records_changed

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const SaveContext = preload("res://services/storage/save_context.gd")

var _records_loaded: bool = false
var _player_records: Dictionary = {}
var _team_records: Dictionary = {}
var _season_archives: Array = []

var player_records: Dictionary:
	get:
		ensure_loaded()
		return _player_records

var team_records: Dictionary:
	get:
		ensure_loaded()
		return _team_records

var season_archives: Array:
	get:
		ensure_loaded()
		return _season_archives

# simulation_reporter など、レポート用のスナップショット/リストア中に
# save_records() がトリガーされて中間状態が永続化レイヤへ漏れるのを防ぐためのフラグ。
# 呼び出し側 (simulation_reporter.gd) で suspend_persistence() / resume_persistence() を使う。
var _suspend_persistence: bool = false


func _ready() -> void:
	pass


func ensure_loaded() -> void:
	if _records_loaded:
		return
	load_records()


func ensure_season_records(season: PSSeason, teams: Array, players: Array, persist: bool = true) -> void:
	ensure_loaded()
	var changed: bool = false
	var active_players_by_id: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		var key: String = _season_key(team.id, season.year, season.season_number)
		if not _team_records.has(key):
			_team_records[key] = PSTeamSeasonRecord.from_team(team, season.year, season.season_number)
			changed = true

	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		active_players_by_id[player.id] = player
		var key: String = _season_key(player.id, season.year, season.season_number)
		if not _player_records.has(key):
			_player_records[key] = PSPlayerSeasonRecord.from_player(player, season.year, season.season_number)
			changed = true
		else:
			var existing_record: PSPlayerSeasonRecord = _player_records[key] as PSPlayerSeasonRecord
			if _record_identity_changed(existing_record, player):
				_player_records[key] = _refreshed_player_record(existing_record, player)
				changed = true

	for key in _player_records.keys():
		var record: PSPlayerSeasonRecord = _player_records[key] as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if not active_players_by_id.has(record.player_id):
			_player_records.erase(key)
			changed = true

	if changed:
		if persist:
			save_records()
		records_changed.emit()

	_warn_missing_z_abilities(season)


func _warn_missing_z_abilities(season: PSSeason) -> void:
	var season_records: Array = []
	for record_value in _player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year == season.year and record.season_number == season.season_number:
			season_records.append(record)
	var missing: Dictionary = PSZAbilityAdapter.collect_missing_z_keys(season_records)
	if missing.is_empty():
		return
	var sample_ids: Array = missing.keys()
	var first_sample: int = int(sample_ids[0])
	var first_keys: Array = missing.get(first_sample, []) as Array
	push_warning("[RecordStore] z_abilities_snapshot missing for %d players (sample id=%d, keys=%s)" % [
		missing.size(),
		first_sample,
		", ".join(first_keys.slice(0, min(first_keys.size(), 6))),
	])


func get_player_record(player_id: int, year: int, season_number: int) -> PSPlayerSeasonRecord:
	ensure_loaded()
	return _player_records.get(_season_key(player_id, year, season_number)) as PSPlayerSeasonRecord


func get_team_record(team_id: int, year: int, season_number: int) -> PSTeamSeasonRecord:
	ensure_loaded()
	return _team_records.get(_season_key(team_id, year, season_number)) as PSTeamSeasonRecord


func get_player_records(player_id: int) -> Array:
	ensure_loaded()
	var records: Array = []
	for record_row in _player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			records.append(record)
	records.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		if record_a.year == record_b.year:
			return record_a.season_number < record_b.season_number
		return record_a.year < record_b.year
	)
	return records


func get_player_career_batter_stats(player_id: int) -> PSBatterStats:
	var career_stats: PSBatterStats = PSBatterStats.new()
	for record_row in get_player_records(player_id):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		career_stats.add_from(record.batter_stats)
	return career_stats


func get_player_career_pitcher_stats(player_id: int) -> PSPitcherStats:
	var career_stats: PSPitcherStats = PSPitcherStats.new()
	for record_row in get_player_records(player_id):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		career_stats.add_from(record.pitcher_stats)
	return career_stats


func get_team_player_records(team_id: int, year: int, season_number: int) -> Array:
	ensure_loaded()
	var records: Array = []
	for record_row in _player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.team_id == team_id and record.year == year and record.season_number == season_number:
			records.append(record)
	return records


func get_current_player_records_for_team(team_id: int) -> Array:
	var season: PSSeason = AppState.current_season
	if season == null:
		return []
	return get_team_player_records(team_id, season.year, season.season_number)


func clear_records() -> void:
	_player_records.clear()
	_team_records.clear()
	_season_archives.clear()
	_records_loaded = true
	records_changed.emit()


func add_season_archive(archive: PSSeasonArchive) -> void:
	if archive == null:
		return
	ensure_loaded()
	_season_archives.append(archive)
	save_records()
	records_changed.emit()


func get_season_archives() -> Array:
	ensure_loaded()
	return _season_archives


func to_dict() -> Dictionary:
	ensure_loaded()
	var payload: Dictionary = {
		"version": 2,
		"player_records": [],
		"team_records": [],
		"season_archives": [],
	}

	for record_row in _player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		payload["player_records"].append(record.to_dict())
	for record_row in _team_records.values():
		var record: PSTeamSeasonRecord = record_row as PSTeamSeasonRecord
		payload["team_records"].append(record.to_dict())
	for archive_row in _season_archives:
		var archive: PSSeasonArchive = archive_row as PSSeasonArchive
		payload["season_archives"].append(archive.to_dict())

	return payload


func load_from_dict(payload: Dictionary) -> void:
	_player_records.clear()
	_team_records.clear()
	_season_archives.clear()

	var player_rows: Array = payload.get("player_records", []) as Array
	for row in player_rows:
		var player_row: Dictionary = row as Dictionary
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(player_row)
		_player_records[_season_key(record.player_id, record.year, record.season_number)] = record

	var team_rows: Array = payload.get("team_records", []) as Array
	for row in team_rows:
		var team_row: Dictionary = row as Dictionary
		var record: PSTeamSeasonRecord = PSTeamSeasonRecord.from_dict(team_row)
		_team_records[_season_key(record.team_id, record.year, record.season_number)] = record

	var archive_rows: Array = payload.get("season_archives", []) as Array
	for row in archive_rows:
		var archive_dict: Dictionary = row as Dictionary
		var archive: PSSeasonArchive = PSSeasonArchive.from_dict(archive_dict)
		_season_archives.append(archive)

	_records_loaded = true
	records_changed.emit()


func save_records() -> bool:
	if _suspend_persistence:
		return true
	ensure_loaded()

	var payload: Dictionary = to_dict()
	# blob (team_records / season_archives) + 正規化テーブル (player_records) を
	# 同一 transaction で更新する。player_records は正規化テーブルが真実なので blob には
	# 含めない (sqlite_store 側で slim blob 化)。
	if SQLiteStoreService.save_record_store_and_normalized(payload):
		return true

	var records_path: String = SaveContext.records_path()
	if records_path.is_empty():
		push_error("Could not write records file: no active save folder.")
		return false
	var file: FileAccess = FileAccess.open(records_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write records file: %s" % records_path)
		return false

	file.store_string(JSON.stringify(payload, "\t"))
	return true


func load_records() -> void:
	_player_records.clear()
	_team_records.clear()
	_season_archives.clear()
	_records_loaded = true

	# 新テーブルが populated ならそこから hydrate (検索高速化の本命)。
	# team_records / season_archives はまだ blob 管理なので、その分は後段で blob から拾う。
	if not SQLiteStoreService.normalized_tables_empty():
		var psr_dicts: Array = SQLiteStoreService.load_all_player_season_record_dicts()
		for row_value in psr_dicts:
			var row: Dictionary = row_value as Dictionary
			var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(row)
			_player_records[_season_key(record.player_id, record.year, record.season_number)] = record
		# team_records / season_archives は依然 blob 側にあるので blob からも読む。
		var blob_payload: Dictionary = SQLiteStoreService.load_record_store()
		_load_team_and_archives_from_blob(blob_payload)
		records_changed.emit()
		return

	var sqlite_payload: Dictionary = SQLiteStoreService.load_record_store()
	if not sqlite_payload.is_empty():
		load_from_dict(sqlite_payload)
		return

	var records_path: String = SaveContext.records_path()
	if records_path.is_empty() or not FileAccess.file_exists(records_path):
		records_changed.emit()
		return

	var file: FileAccess = FileAccess.open(records_path, FileAccess.READ)
	if file == null:
		push_error("Could not read records file: %s" % records_path)
		return

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_error("Records file is not valid: %s" % records_path)
		return
	var payload: Dictionary = parsed as Dictionary
	load_from_dict(payload)
	if SQLiteStoreService.is_available():
		SQLiteStoreService.save_record_store_and_normalized(payload)


# simulation_reporter のようなスナップショット/リストア処理中に
# save_records() をスキップして中間状態を永続化レイヤへ漏らさないようにする。
func suspend_persistence() -> void:
	_suspend_persistence = true


func resume_persistence() -> void:
	_suspend_persistence = false


# blob payload から team_records / season_archives だけ拾う。
# player_records は正規化テーブル側が真実なので、blob 側の player_records は無視する。
func _load_team_and_archives_from_blob(blob_payload: Dictionary) -> void:
	if blob_payload.is_empty():
		return
	var team_rows: Array = blob_payload.get("team_records", []) as Array
	for row in team_rows:
		var team_row: Dictionary = row as Dictionary
		var record: PSTeamSeasonRecord = PSTeamSeasonRecord.from_dict(team_row)
		_team_records[_season_key(record.team_id, record.year, record.season_number)] = record
	var archive_rows: Array = blob_payload.get("season_archives", []) as Array
	for row in archive_rows:
		var archive_dict: Dictionary = row as Dictionary
		var archive: PSSeasonArchive = PSSeasonArchive.from_dict(archive_dict)
		_season_archives.append(archive)


func _season_key(entity_id: int, year: int, season_number: int) -> String:
	return "%d:%d:%d" % [entity_id, year, season_number]


func _record_identity_changed(record: PSPlayerSeasonRecord, player: PSPlayer) -> bool:
	if record.name != player.name or record.sensyu_num != player.sensyu_num:
		return true
	if record.source_data.get("source_table", "") != player.source_data.get("source_table", ""):
		return true
	# 防御的: record が z_abilities_snapshot を持たない (能力欠落) 場合は player から取り直す
	if record.z_abilities_snapshot.is_empty() and not player.z_abilities.is_empty():
		return true
	return false


func _refreshed_player_record(record: PSPlayerSeasonRecord, player: PSPlayer) -> PSPlayerSeasonRecord:
	var refreshed: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, record.year, record.season_number)
	refreshed.batter_stats = record.batter_stats
	refreshed.pitcher_stats = record.pitcher_stats
	return refreshed
