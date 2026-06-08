extends RefCounted
class_name SaveService

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const SAVE_PATH = "user://pennant_strategy_m0.save"


static func save_state(app_state) -> bool:
	if not RecordStore.save_records():
		push_error("Could not write record store before saving game state.")
		return false

	var season_data: Dictionary = {}
	if app_state.current_season != null:
		season_data = app_state.current_season.to_dict()

	var payload: Dictionary = {
		"selected_team_id": app_state.selected_team_id,
		"current_screen": app_state.current_screen,
		"season": season_data,
		"players": _players_to_dicts(),
		# R4 Step1: チーム予算 (funds) を {team_id: funds} で永続化。teams 本体は初期シード
		# から再ロードされるため funds のみ保存する。
		"team_funds": _team_funds_map(),
		# records は RecordStore が record_store blob / 正規化テーブルへ独立永続化するため
		# game_state には含めない。全履歴の二重シリアライズ (autosave ごと) を避ける。
		"offseason_step": app_state.offseason_step,
		"offseason_results": app_state.offseason_results,
		"draft_state": app_state.draft_state,
		"fa_state": app_state.fa_state,
		"foreign_state": app_state.foreign_state,
		"offseason_active": app_state.offseason_active,
		"postseason_active": app_state.postseason_active,
		"current_postseason": app_state.current_postseason.to_dict() if app_state.current_postseason != null else {},
		"current_awards": app_state.current_awards.to_dict() if app_state.current_awards != null else {},
		"auto_roster_swap_for_user_team": app_state.auto_roster_swap_for_user_team,
		"auto_roster_swap_during_skip": app_state.auto_roster_swap_during_skip,
		"auto_save_enabled": app_state.auto_save_enabled,
		"league_dh_enabled": app_state.dh_settings_for_schedule(),
	}

	if SQLiteStoreService.save_game_state(payload):
		return true

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Could not write save file: %s" % SAVE_PATH)
		return false

	file.store_string(JSON.stringify(payload, "\t"))
	return true


static func load_state() -> Dictionary:
	var sqlite_payload: Dictionary = SQLiteStoreService.load_game_state()
	if not sqlite_payload.is_empty():
		return sqlite_payload

	if not FileAccess.file_exists(SAVE_PATH):
		return {}

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not read save file: %s" % SAVE_PATH)
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var payload: Dictionary = parsed as Dictionary
		if SQLiteStoreService.is_available():
			SQLiteStoreService.save_game_state(payload)
		return payload

	push_error("Save file is not valid: %s" % SAVE_PATH)
	return {}


# 肥大化した DB ファイルを必要に応じて切り詰める (freelist が多いときだけ VACUUM)。
# シーズンの節目 (オフシーズン開始時など) に呼ぶ想定。
static func compact_storage() -> void:
	SQLiteStoreService.vacuum_if_needed()


static func _players_to_dicts() -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		rows.append(player.to_dict())
	return rows


static func _team_funds_map() -> Dictionary:
	var out: Dictionary = {}
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			out[team.id] = team.funds
	return out
