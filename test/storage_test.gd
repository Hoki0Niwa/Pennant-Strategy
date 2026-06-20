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
