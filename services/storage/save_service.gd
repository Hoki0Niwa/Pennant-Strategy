extends RefCounted
class_name SaveService

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const SaveContext = preload("res://services/storage/save_context.gd")
const GameLogService = preload("res://services/storage/game_log_service.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

# セーブ一覧 UI 用の軽量メタ情報。セーブ本体 (SQLite blob) を開かずに一覧表示できるよう、
# save_state のたびにフォルダ直下へ小さな JSON を書き出す。
const SAVE_META_FILE: String = "save_meta.json"

static var _saved_state_fingerprint: int = 0
static var _saved_state_save_id: String = ""


static func save_state(app_state) -> bool:
	if not SaveContext.has_active_save():
		if not SaveContext.begin_new_save():
			push_error("Could not create save folder.")
			return false

	if not RecordStore.save_records():
		push_error("Could not write record store before saving game state.")
		return false

	var season_data: Dictionary = {}
	var history_in_blob: bool = true
	if app_state.current_season != null:
		GameLogService.write_pending_game_logs(app_state.current_season)
		# 選手履歴 (試合別差分 / 日次スナップショット) は season_history テーブルへ日単位で
		# 増分永続化し、成功したときだけ blob から外す (失敗時は従来通り blob に全量を残す)。
		history_in_blob = not _persist_season_history(app_state.current_season)
		season_data = app_state.current_season.to_dict(history_in_blob)
	if app_state.current_postseason != null:
		GameLogService.write_pending_postseason_game_logs(app_state.current_postseason, app_state.current_season)

	var payload: Dictionary = {
		"save_id": SaveContext.active_save_id(),
		"active_mods": ModManager.active_mods_snapshot(),
		"rules_profile_id": ModManager.rules_profile_id(),
		"rules_schema_version": ModManager.rules_schema_version(),
		"data_schema_version": ModManager.data_schema_version(),
		"selected_team_id": app_state.selected_team_id,
		"current_screen": app_state.current_screen,
		"season": season_data,
		"players": _players_to_dicts(),
		# R4 Step1: チーム予算 (funds) を {team_id: funds} で永続化。teams 本体は初期シード
		# から再ロードされるため funds のみ保存する。
		"team_funds": _team_funds_map(),
		"team_previous_ranks": _team_previous_ranks_map(),
		"team_auto_lineup": _team_auto_lineup_map(),
		# records は RecordStore が record_store blob / 正規化テーブルへ独立永続化するため
		# game_state には含めない。全履歴の二重シリアライズ (autosave ごと) を避ける。
		"offseason_step": app_state.offseason_step,
		"offseason_results": app_state.offseason_results,
		"draft_state": app_state.draft_state,
		"released_market_state": app_state.released_market_state,
		"geneki_draft_state": app_state.geneki_draft_state,
		"fa_state": app_state.fa_state,
		"foreign_state": app_state.foreign_state,
		"camp_state": app_state.camp_state,
		"contract_update_state": app_state.contract_update_state,
		"offseason_active": app_state.offseason_active,
		"postseason_active": app_state.postseason_active,
		"current_postseason": app_state.current_postseason.to_dict() if app_state.current_postseason != null else {},
		"current_awards": app_state.current_awards.to_dict() if app_state.current_awards != null else {},
		"auto_roster_swap_for_user_team": app_state.auto_roster_swap_for_user_team,
		"auto_roster_swap_during_skip": app_state.auto_roster_swap_during_skip,
		"auto_trade_for_user_team": app_state.auto_trade_for_user_team,
		"draft_full_waiver": app_state.draft_full_waiver,
		"auto_save_enabled": app_state.auto_save_enabled,
		"league_dh_enabled": app_state.dh_settings_for_schedule(),
	}

	if SQLiteStoreService.save_game_state(payload):
		_write_save_meta(app_state)
		_remember_saved_state(payload)
		return true

	# JSON fallback は SQLite 全体が使えない状況なので、履歴を分離したままでは
	# 復元できない。blob から外していた場合は履歴込みの payload に差し替える。
	if not history_in_blob and app_state.current_season != null:
		payload["season"] = app_state.current_season.to_dict()

	var save_path: String = SaveContext.game_state_path()
	var file: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write save file: %s" % save_path)
		return false

	file.store_string(JSON.stringify(payload, "\t"))
	_write_save_meta(app_state)
	_remember_saved_state(payload)
	return true


static func load_state() -> Dictionary:
	if not SaveContext.select_active_or_latest_save():
		return {}
	var sqlite_payload: Dictionary = SQLiteStoreService.load_game_state()
	if not sqlite_payload.is_empty():
		return sqlite_payload

	var save_path: String = SaveContext.game_state_path()
	if save_path.is_empty() or not FileAccess.file_exists(save_path):
		return {}

	var file: FileAccess = FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		push_error("Could not read save file: %s" % save_path)
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var payload: Dictionary = parsed as Dictionary
		if SQLiteStoreService.is_available():
			SQLiteStoreService.save_game_state(payload)
		return payload

	push_error("Save file is not valid: %s" % save_path)
	return {}


# season.to_dict の履歴2種を SQLite season_history テーブルへ日単位で増分保存する。
# 成功時 true (= blob から履歴を外してよい)。
static func _persist_season_history(season: PSSeason) -> bool:
	if not SQLiteStoreService.is_available():
		return false
	var game_days: Dictionary = _group_history_by_day(season.player_game_history)
	if not SQLiteStoreService.save_season_history(season.year, season.season_number, "game", game_days, season.current_day):
		return false
	var stat_days: Dictionary = _group_history_by_day(season.player_stat_history)
	var retention_cutoff: int = season.current_day - PSSeason.SNAPSHOT_RETENTION_DAYS
	return SQLiteStoreService.save_season_history(season.year, season.season_number, "stat", stat_days, season.current_day, retention_cutoff)


# {player_id_str: [entries]} を {day:int → {player_id_str: [その日のentries]}} へ変換する。
# 各エントリは "day" キーを持つ (append_player_game_log / append_player_stat_snapshot が付与)。
static func _group_history_by_day(history: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for player_key in history.keys():
		var entries: Array = history[player_key] as Array
		for entry_value in entries:
			var entry: Dictionary = entry_value as Dictionary
			var day: int = int(entry.get("day", 0))
			if not out.has(day):
				out[day] = {}
			var day_bucket: Dictionary = out[day] as Dictionary
			if not day_bucket.has(player_key):
				day_bucket[player_key] = []
			(day_bucket[player_key] as Array).append(entry)
	return out


# blob に履歴が入っていない新形式セーブでは、season_history テーブルから履歴を復元して
# season へ直接代入する (restore_from_save が PSSeason.from_dict の後に呼ぶ)。
# payload 経由にせず直接代入するのは、from_dict の duplicate(true) による
# 数十MB構造の深コピーを避けるため (テーブルから再構成した Dictionary は共有元が無い)。
# 旧形式 (blob に履歴あり) は from_dict が復元済みなので何もしない。
static func hydrate_season_history(season: PSSeason) -> void:
	if season == null or not SQLiteStoreService.is_available():
		return
	if season.player_game_history.is_empty():
		season.player_game_history = SQLiteStoreService.load_season_history(season.year, season.season_number, "game", season.current_day)
	if season.player_stat_history.is_empty():
		season.player_stat_history = SQLiteStoreService.load_season_history(season.year, season.season_number, "stat", season.current_day)


# 肥大化した DB ファイルを必要に応じて切り詰める (freelist が多いときだけ VACUUM)。
# シーズンの節目 (オフシーズン開始時など) に呼ぶ想定。
static func compact_storage() -> void:
	SQLiteStoreService.vacuum_if_needed()


static func begin_new_game() -> bool:
	return SaveContext.begin_new_save()


# 現在の進行状態が、同じセーブスロットへ最後に正常保存した内容と一致するかを返す。
# 画面遷移はゲーム進行ではないため current_screen は比較対象に含めない。
static func is_state_current(app_state) -> bool:
	if _saved_state_fingerprint == 0:
		return false
	if _saved_state_save_id != SaveContext.active_save_id():
		return false
	return _state_fingerprint(_current_state_snapshot(app_state)) == _saved_state_fingerprint


# ロード完了後の復元状態を「保存済み」の基準にする。
static func mark_state_loaded(app_state) -> void:
	if not SaveContext.has_active_save():
		_saved_state_fingerprint = 0
		_saved_state_save_id = ""
		return
	_saved_state_fingerprint = _state_fingerprint(_current_state_snapshot(app_state))
	_saved_state_save_id = SaveContext.active_save_id()


static func current_save_display_path() -> String:
	return SaveContext.display_path()


static func delete_current_save() -> Array:
	return SaveContext.delete_current_save_data()


# セーブ選択 UI 用: 全 save_* フォルダのメタ情報を新しい順で返す。
# 各要素: {save_id, is_active, team_name, year, season_number, date, offseason_active, updated_at}
# (メタ未保存の旧セーブは save_id / is_active のみ確実)。
static func list_saves() -> Array:
	var active_id: String = SaveContext.active_save_id()
	var out: Array = []
	var ids: Array = SaveContext.save_ids()
	for i in range(ids.size() - 1, -1, -1):
		var save_id: String = str(ids[i])
		var meta: Dictionary = _read_save_meta(save_id)
		meta["save_id"] = save_id
		meta["is_active"] = save_id == active_id
		out.append(meta)
	return out


# 指定セーブをアクティブ化して読み込む。成功時は restore_from_save へ渡せる payload、
# 失敗時は空 Dictionary (アクティブ選択は変更されている可能性がある点に注意)。
static func load_save(save_id: String) -> Dictionary:
	if not SaveContext.activate_save_id(save_id):
		return {}
	return load_state()


static func delete_save(save_id: String) -> bool:
	return SaveContext.delete_save_id(save_id)


static func _write_save_meta(app_state) -> void:
	var dir: String = SaveContext.active_save_dir()
	if dir.is_empty():
		return
	var meta: Dictionary = {
		"updated_at": Time.get_datetime_string_from_system(false, true),
	}
	var team: PSTeam = GameDb.get_team(app_state.selected_team_id)
	if team != null:
		meta["team_name"] = team.name
	var season: PSSeason = app_state.current_season
	if season != null:
		meta["year"] = season.year
		meta["season_number"] = season.season_number
		meta["date"] = SeasonCalendar.current_date(season)
		meta["offseason_active"] = bool(app_state.offseason_active)
	var file: FileAccess = FileAccess.open("%s/%s" % [dir, SAVE_META_FILE], FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(meta, "\t"))


static func _read_save_meta(save_id: String) -> Dictionary:
	var path: String = "%s/%s" % [SaveContext.save_dir_for_id(save_id), SAVE_META_FILE]
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


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


static func _team_previous_ranks_map() -> Dictionary:
	var out: Dictionary = {}
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			out[team.id] = team.previous_rank
	return out


static func _team_auto_lineup_map() -> Dictionary:
	var out: Dictionary = {}
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			out[team.id] = team.auto_lineup
	return out


static func _remember_saved_state(payload: Dictionary) -> void:
	_saved_state_fingerprint = _state_fingerprint(payload)
	_saved_state_save_id = SaveContext.active_save_id()


static func _current_state_snapshot(app_state) -> Dictionary:
	return {
		"selected_team_id": app_state.selected_team_id,
		"season": app_state.current_season.to_dict(false) if app_state.current_season != null else {},
		"players": _players_to_dicts(),
		"team_funds": _team_funds_map(),
		"team_previous_ranks": _team_previous_ranks_map(),
		"team_auto_lineup": _team_auto_lineup_map(),
		"offseason_step": app_state.offseason_step,
		"offseason_results": app_state.offseason_results,
		"draft_state": app_state.draft_state,
		"released_market_state": app_state.released_market_state,
		"geneki_draft_state": app_state.geneki_draft_state,
		"fa_state": app_state.fa_state,
		"foreign_state": app_state.foreign_state,
		"camp_state": app_state.camp_state,
		"contract_update_state": app_state.contract_update_state,
		"offseason_active": app_state.offseason_active,
		"postseason_active": app_state.postseason_active,
		"current_postseason": app_state.current_postseason.to_dict() if app_state.current_postseason != null else {},
		"current_awards": app_state.current_awards.to_dict() if app_state.current_awards != null else {},
		"auto_roster_swap_for_user_team": app_state.auto_roster_swap_for_user_team,
		"auto_roster_swap_during_skip": app_state.auto_roster_swap_during_skip,
		"auto_trade_for_user_team": app_state.auto_trade_for_user_team,
		"draft_full_waiver": app_state.draft_full_waiver,
		"auto_save_enabled": app_state.auto_save_enabled,
		"league_dh_enabled": app_state.dh_settings_for_schedule(),
	}


static func _state_fingerprint(snapshot: Dictionary) -> int:
	var season_data: Dictionary = (snapshot.get("season", {}) as Dictionary).duplicate(false)
	# 履歴は通常の SQLite セーブでは別テーブルへ分離される。保存経路による payload 形式の
	# 違いで誤って「未保存」にならないよう、進行本体と選手状態を比較する。
	# 成績更新は同時に season の日付・日程結果も変わるため、分離ストアの全レコード再構築は行わない。
	season_data.erase("player_stat_history")
	season_data.erase("player_game_history")
	var comparable: Dictionary = {
		"selected_team_id": snapshot.get("selected_team_id", 0),
		"season": season_data,
		"players": snapshot.get("players", []),
		"team_funds": snapshot.get("team_funds", {}),
		"team_previous_ranks": snapshot.get("team_previous_ranks", {}),
		"team_auto_lineup": snapshot.get("team_auto_lineup", {}),
		"offseason_step": snapshot.get("offseason_step", ""),
		"offseason_results": snapshot.get("offseason_results", {}),
		"draft_state": snapshot.get("draft_state", {}),
		"released_market_state": snapshot.get("released_market_state", {}),
		"geneki_draft_state": snapshot.get("geneki_draft_state", {}),
		"fa_state": snapshot.get("fa_state", {}),
		"foreign_state": snapshot.get("foreign_state", {}),
		"camp_state": snapshot.get("camp_state", {}),
		"contract_update_state": snapshot.get("contract_update_state", {}),
		"offseason_active": snapshot.get("offseason_active", false),
		"postseason_active": snapshot.get("postseason_active", false),
		"current_postseason": snapshot.get("current_postseason", {}),
		"current_awards": snapshot.get("current_awards", {}),
		"auto_roster_swap_for_user_team": snapshot.get("auto_roster_swap_for_user_team", false),
		"auto_roster_swap_during_skip": snapshot.get("auto_roster_swap_during_skip", true),
		"auto_trade_for_user_team": snapshot.get("auto_trade_for_user_team", false),
		"draft_full_waiver": snapshot.get("draft_full_waiver", false),
		"auto_save_enabled": snapshot.get("auto_save_enabled", true),
		"league_dh_enabled": snapshot.get("league_dh_enabled", {}),
	}
	return comparable.hash()
