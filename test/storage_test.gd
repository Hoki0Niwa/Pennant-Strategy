extends GdUnitTestSuite

const SaveContext = preload("res://services/storage/save_context.gd")
const GameLogService = preload("res://services/storage/game_log_service.gd")
const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")


func test_new_save_folder_scopes_storage_paths() -> void:
	var old_save_id: String = SaveContext.active_save_id()

	assert_bool(SaveService.begin_new_game()).is_true()
	var new_save_id: String = SaveContext.active_save_id()
	var save_dir: String = SaveContext.active_save_dir()

	assert_bool(new_save_id.begins_with("save_")).is_true()
	assert_str(save_dir).is_equal("user://saves/%s" % new_save_id)
	assert_str(SaveContext.game_state_path()).is_equal("%s/pennant_strategy_m0.save" % save_dir)
	assert_str(SaveContext.records_path()).is_equal("%s/pennant_strategy_records_m1.json" % save_dir)
	assert_str(SQLiteStoreService.runtime_db_path()).is_equal("%s/pennant_strategy_runtime.sqlite" % save_dir)
	assert_str(GameLogService.log_root()).is_equal("%s/game_logs" % save_dir)

	SaveContext.delete_current_save_data()
	assert_str(SaveContext.game_state_path()).is_equal("")
	assert_str(SaveContext.records_path()).is_equal("")
	assert_str(SQLiteStoreService.runtime_db_path()).is_equal("")
	assert_str(GameLogService.log_root()).is_equal("")
	assert_str(SaveContext.display_path()).is_equal("未作成")
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_save_state_records_mod_metadata() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	assert_bool(SaveService.save_state(AppState)).is_true()

	var payload: Dictionary = SaveService.load_state()
	assert_bool(payload.has("active_mods")).is_true()
	assert_str(JSON.stringify(payload.get("active_mods", []) as Array)).is_equal(JSON.stringify(ModManager.active_mods_snapshot()))
	assert_str(str(payload.get("rules_profile_id", ""))).is_equal(ModManager.rules_profile_id())
	assert_int(int(payload.get("rules_schema_version", 0))).is_equal(ModManager.rules_schema_version())
	assert_int(int(payload.get("data_schema_version", 0))).is_equal(ModManager.data_schema_version())

	_restore_app_state(old_state, test_save_id)


func test_unsaved_simulation_does_not_persist_records_or_logs() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""
	var first_game_index: int = -1

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	first_game_index = _first_unplayed_game_index(AppState.current_season)
	assert_int(first_game_index).is_greater_equal(0)
	assert_int(_played_game_count(AppState.current_season)).is_equal(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(0)

	var result: Dictionary = AppState.simulate_next_game()
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_int(_played_game_count(AppState.current_season)).is_equal(1)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(2)
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	assert_int(_played_game_count(AppState.current_season)).is_equal(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(0)
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()

	_restore_app_state(old_state, test_save_id)


func test_manual_save_flushes_pending_game_logs() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""
	var first_game_index: int = -1

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	first_game_index = _first_unplayed_game_index(AppState.current_season)
	var result: Dictionary = AppState.simulate_next_game()
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()

	assert_bool(SaveService.save_state(AppState)).is_true()
	var written_log: Dictionary = GameLogService.read_game_log(AppState.current_season, first_game_index)
	assert_bool(written_log.is_empty()).is_false()
	assert_int((written_log.get("innings", []) as Array).size()).is_greater(0)

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	assert_int(_played_game_count(AppState.current_season)).is_equal(1)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(2)
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_false()

	_restore_app_state(old_state, test_save_id)


func test_unsaved_next_season_progress_does_not_persist_records() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_RETIREMENT
	AppState.offseason_results = {"step_0": {"title": "引退判定", "retired": []}}
	assert_bool(SaveService.save_state(AppState)).is_true()

	var saved_season_number: int = AppState.current_season.season_number
	AppState.offseason_step = AppState.OFFSEASON_TOTAL_STEPS
	assert_bool(AppState.finalize_offseason()).is_true()
	var unsaved_season: PSSeason = AppState.current_season
	assert_int(unsaved_season.season_number).is_equal(saved_season_number + 1)
	assert_int(_record_count_for_season(unsaved_season.year, unsaved_season.season_number)).is_greater(0)

	var result: Dictionary = AppState.simulate_next_game()
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_int(_played_game_count(unsaved_season)).is_equal(1)
	assert_int(_recorded_team_games(unsaved_season)).is_equal(2)

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	assert_bool(AppState.offseason_active).is_true()
	assert_int(AppState.current_season.season_number).is_equal(saved_season_number)
	assert_int(_record_count_for_season(unsaved_season.year, unsaved_season.season_number)).is_equal(0)

	_restore_app_state(old_state, test_save_id)


func test_player_season_stats_round_trip_through_normalized_tables() -> void:
	# ユーザー報告「ポストシーズン終了セーブから再開すると支配下が激減」の根本原因調査:
	# 実セーブの batter_stats / pitcher_stats 正規化テーブルが全行 0 だった。
	# 選手個人成績が save_records → load_records (正規化テーブル経由) を往復できることを検証する。
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	var target: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			target = record
			break
	assert_object(target).is_not_null()
	target.batter_stats.games = 123
	target.batter_stats.hits = 145
	var target_id: int = target.player_id

	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	var reloaded: PSPlayerSeasonRecord = RecordStore.get_player_record(target_id, season.year, season.season_number)
	assert_object(reloaded).is_not_null()
	assert_int(reloaded.batter_stats.games).is_equal(123)
	assert_int(reloaded.batter_stats.hits).is_equal(145)

	_restore_app_state(old_state, test_save_id)


func test_season_history_split_saves_incrementally_and_round_trips() -> void:
	# player_game_history / player_stat_history は game_state blob から分離し、
	# season_history テーブルへ日単位で増分永続化する (2026-07-16 セーブ高速化)。
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	var pid: int = (GameDb.players[0] as PSPlayer).id
	season.current_day = 2
	season.append_player_game_log(pid, {"game_index": 0, "day": 1, "batter": {"hits": 2}})
	season.append_player_game_log(pid, {"game_index": 6, "day": 2, "batter": {"hits": 1}})
	season.append_player_stat_snapshot(pid, 1, PSBatterStats.new(), PSPitcherStats.new())
	assert_bool(SaveService.save_state(AppState)).is_true()

	# blob 側に履歴が残らないこと (SQLite 利用時のみ分離される)
	if SQLiteStoreService.is_available():
		var raw_blob: Dictionary = SQLiteStoreService.load_game_state()
		var blob_season: Dictionary = raw_blob.get("season", {}) as Dictionary
		assert_bool(blob_season.has("player_game_history")).is_false()
		assert_bool(blob_season.has("player_stat_history")).is_false()

	# 日を進めて追記 → 増分セーブ → ロードで全日分が復元される。
	# from_dict は「current_day より前の未消化試合」があると current_day を巻き戻し、
	# 履歴の hydrate も current_day までに絞られるため、進めた日数分は消化済みにしておく。
	season.current_day = 3
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) < 3:
			game["played"] = true
	season.append_player_game_log(pid, {"game_index": 12, "day": 3, "batter": {"hits": 3}})
	assert_bool(SaveService.save_state(AppState)).is_true()

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	var logs: Array = AppState.current_season.get_player_game_logs(pid)
	assert_int(logs.size()).is_equal(3)
	assert_int(int((logs[0] as Dictionary).get("day", 0))).is_equal(1)
	assert_int(int((logs[2] as Dictionary).get("day", 0))).is_equal(3)
	assert_int(int(((logs[2] as Dictionary).get("batter", {}) as Dictionary).get("hits", 0))).is_equal(3)
	var snapshots: Array = AppState.current_season.player_stat_history.get(str(pid), []) as Array
	assert_int(snapshots.size()).is_equal(1)
	assert_int(int((snapshots[0] as Dictionary).get("day", 0))).is_equal(1)

	_restore_app_state(old_state, test_save_id)


func test_record_store_saves_only_changed_rows() -> void:
	# save_records はレコード内容のフィンガープリントで変更行だけを upsert する。
	# 過去年度の不変レコードや、日送り時の二重 save_records 呼び出しの2回目が
	# 全行書き込みにならないことの検証。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	# start_new_season 内の初回セーブで全行書き込み+キャッシュ確立済み。
	# 以後、変更なしの再セーブは 0 行になる。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(0)

	# 1 レコードだけ変更 → 書き込み 1 行
	var target: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			target = record
			break
	assert_object(target).is_not_null()
	target.batter_stats.hits = 77
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(1)

	# ロード直後 (フィンガープリントのシード後) の無変更セーブも 0 行
	RecordStore.load_records()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(0)

	# メモリから消えたレコードは save で DB からも消える
	var removed_id: int = target.player_id
	RecordStore.player_records.erase("%d:%d:%d" % [removed_id, season.year, season.season_number])
	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	assert_object(RecordStore.get_player_record(removed_id, season.year, season.season_number)).is_null()

	_restore_app_state(old_state, test_save_id)


func test_save_selection_list_load_delete() -> void:
	# セーブ選択機能: list_saves のメタ情報 / load_save でのアクティブ切替ロード /
	# delete_save での個別削除 (save_select 画面のバックエンド)。
	var old_state: Dictionary = _capture_app_state()

	var first_team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(first_team.id)
	AppState.start_new_season()
	var first_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	var second_team: PSTeam = GameDb.teams[1] as PSTeam
	AppState.select_team(second_team.id)
	AppState.start_new_season()
	var second_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(second_id != first_id).is_true()

	# 一覧: 両方が現れ、アクティブは2つ目、メタに球団名・年目が入る
	var ids: Array = []
	var first_meta: Dictionary = {}
	for row_value in SaveService.list_saves():
		var row: Dictionary = row_value as Dictionary
		var row_id: String = str(row.get("save_id", ""))
		ids.append(row_id)
		if row_id == first_id:
			first_meta = row
	assert_bool(ids.has(first_id)).is_true()
	assert_bool(ids.has(second_id)).is_true()
	assert_bool(bool(first_meta.get("is_active", true))).is_false()
	assert_str(str(first_meta.get("team_name", ""))).is_equal(first_team.name)
	assert_int(int(first_meta.get("season_number", 0))).is_equal(1)

	# 1つ目を選択ロード → アクティブが切り替わり、選択球団も復元される
	var payload: Dictionary = SaveService.load_save(first_id)
	assert_bool(payload.is_empty()).is_false()
	assert_bool(AppState.restore_from_save(payload)).is_true()
	assert_str(SaveContext.active_save_id()).is_equal(first_id)
	assert_int(AppState.selected_team_id).is_equal(first_team.id)

	# 2つ目 (非アクティブ) を削除 → 一覧から消え、アクティブは変わらない
	assert_bool(SaveService.delete_save(second_id)).is_true()
	var ids_after: Array = []
	for row_value in SaveService.list_saves():
		ids_after.append(str((row_value as Dictionary).get("save_id", "")))
	assert_bool(ids_after.has(second_id)).is_false()
	assert_str(SaveContext.active_save_id()).is_equal(first_id)

	# アクティブなセーブの削除はアクティブ参照もクリアする
	assert_bool(SaveService.delete_save(first_id)).is_true()
	assert_bool(SaveContext.has_active_save()).is_false()

	_restore_app_state(old_state, "")


func _capture_app_state() -> Dictionary:
	return {
		"selected_team_id": AppState.selected_team_id,
		"current_season": AppState.current_season,
		"current_screen": AppState.current_screen,
		"auto_save_enabled": AppState.auto_save_enabled,
		"active_save_id": SaveContext.active_save_id(),
		"records": RecordStore.to_dict().duplicate(true),
	}


func _restore_app_state(old_state: Dictionary, test_save_id: String) -> void:
	if not test_save_id.is_empty() and SaveContext.active_save_id() == test_save_id:
		SaveContext.delete_current_save_data()
	AppState.selected_team_id = int(old_state.get("selected_team_id", 0))
	AppState.current_season = old_state.get("current_season", null) as PSSeason
	AppState.current_screen = str(old_state.get("current_screen", "start"))
	AppState.auto_save_enabled = bool(old_state.get("auto_save_enabled", false))
	RecordStore.load_from_dict(old_state.get("records", {}) as Dictionary)
	var old_save_id: String = str(old_state.get("active_save_id", ""))
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func _first_unplayed_game_index(season: PSSeason) -> int:
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			return index
	return -1


func _played_game_count(season: PSSeason) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			count += 1
	return count


func _recorded_team_games(season: PSSeason) -> int:
	var count: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		var record: PSTeamSeasonRecord = RecordStore.get_team_record(team.id, season.year, season.season_number)
		if record != null:
			count += record.stats.games
	return count


func _record_count_for_season(year: int, season_number: int) -> int:
	var count: int = 0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == year and record.season_number == season_number:
			count += 1
	for record_value in RecordStore.team_records.values():
		var record: PSTeamSeasonRecord = record_value as PSTeamSeasonRecord
		if record.year == year and record.season_number == season_number:
			count += 1
	return count
