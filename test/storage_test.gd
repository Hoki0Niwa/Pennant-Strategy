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
