# GdUnit4 への移行後の最初のテスト雛形。
# 旧 run_startup_smoke.gd 相当: 主要スクリプトのロードと autoload 登録を確認する。
# 新しいテストは test/ 配下に *_test.gd を追加するだけで自動検出される(専用 .tscn 不要)。
extends GdUnitTestSuite

const SaveContext = preload("res://services/storage/save_context.gd")


func test_core_scripts_load() -> void:
	assert_object(load("res://ui/main.gd")).is_not_null()
	assert_object(load("res://ui/screens/home_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/offseason_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/options_screen.gd")).is_not_null()


func test_autoloads_registered() -> void:
	# autoload はシーン/プロジェクト起動時のみ登録される(=旧運用で .tscn が必要だった理由)。
	# GdUnit はプロジェクト文脈で実行するため singleton として参照できる。
	assert_object(Engine.get_main_loop().root.get_node_or_null("AppState")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("GameDb")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("RecordStore")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("Rng")).is_not_null()


func test_home_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	var home_script: GDScript = load("res://ui/screens/home_screen.gd") as GDScript
	var screen: Control = home_script.new()
	add_child(screen)
	await get_tree().process_frame

	assert_int(screen.get_child_count()).is_greater(0)
	screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.last_status_message = old_status
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_rotation_editor_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "rotation_editor"
	var test_save_id: String = SaveContext.active_save_id()

	var screen_script: GDScript = load("res://ui/screens/rotation_editor_screen.gd") as GDScript
	var screen: Control = screen_script.new()
	add_child(screen)
	await get_tree().process_frame

	# サイドバーナビ + アクションボタン + 6スロットの OptionButton が生成されている。
	assert_int(screen.get_child_count()).is_greater(0)
	screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.last_status_message = old_status
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_screen_history_back_navigation() -> void:
	var old_screen: String = AppState.current_screen
	var old_player: int = AppState.current_player_id
	var old_season: PSSeason = AppState.current_season
	var old_history: Array = AppState._screen_history.duplicate(true)
	var old_forward: Array = AppState._forward_history.duplicate(true)

	AppState.current_season = PSSeason.new()
	AppState._screen_history.clear()
	AppState._forward_history.clear()
	# standings -> rankings -> player_detail(42) と進む。
	AppState.request_screen("standings")
	AppState.request_screen("rankings")
	AppState.show_player_detail(42)
	assert_str(AppState.current_screen).is_equal("player_detail")
	assert_int(AppState.current_player_id).is_equal(42)

	# 右クリック相当: rankings に戻る。
	assert_bool(AppState.go_back()).is_true()
	assert_str(AppState.current_screen).is_equal("rankings")

	# さらに戻ると standings。
	assert_bool(AppState.go_back()).is_true()
	assert_str(AppState.current_screen).is_equal("standings")

	# 進む: rankings -> player_detail(42) と復元され、player_id も戻る。
	assert_bool(AppState.go_forward()).is_true()
	assert_str(AppState.current_screen).is_equal("rankings")
	assert_bool(AppState.go_forward()).is_true()
	assert_str(AppState.current_screen).is_equal("player_detail")
	assert_int(AppState.current_player_id).is_equal(42)

	# 進む履歴が尽きたら false。
	assert_bool(AppState.go_forward()).is_false()
	assert_str(AppState.current_screen).is_equal("player_detail")

	# 新規ナビゲーションは進む履歴を無効化する。
	AppState.go_back()  # rankings へ (forward=[player_detail])
	AppState.request_screen("team_detail")  # 新規遷移 → forward クリア
	assert_bool(AppState.go_forward()).is_false()

	# 戻る履歴が尽きたら false を返し、現画面を維持する。
	AppState._screen_history.clear()
	AppState._forward_history.clear()
	AppState.current_screen = "standings"
	assert_bool(AppState.go_back()).is_false()
	assert_str(AppState.current_screen).is_equal("standings")

	AppState._screen_history = old_history
	AppState._forward_history = old_forward
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.current_player_id = old_player


func test_history_screen_builds_with_archive() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.current_screen = "history"

	# アーカイブを1件、永続化せずに live 配列へ直接差し込んで集計経路を検証する。
	var archives: Array = RecordStore.get_season_archives()
	var archive: PSSeasonArchive = _make_test_archive()
	archives.append(archive)

	var script: GDScript = load("res://ui/screens/history_screen.gd") as GDScript
	var screen: Control = script.new()
	add_child(screen)
	await get_tree().process_frame

	# 集計結果が表示用に展開されている (全リーグ行 / ポストシーズン / 表彰)。
	assert_int(screen._rows_by_league.size()).is_equal(2)
	assert_int((screen._rows_by_league.get("central", []) as Array).size()).is_greater(0)
	assert_int(screen._post_champion_id).is_equal(archive.postseason.champion_team_id)
	assert_bool(screen._post_by_stage.has("japan_series")).is_true()
	assert_int(((screen._post_by_stage["japan_series"] as Dictionary).get("games", []) as Array).size()).is_equal(2)
	assert_int(screen._award_cards.size()).is_equal(4)
	assert_int(screen._bat_rows.size()).is_equal(PSAwards.BATTING_CATEGORIES.size())
	assert_int(screen._pit_rows.size()).is_equal(PSAwards.PITCHING_CATEGORIES.size())
	screen.queue_free()

	archives.erase(archive)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func _make_test_archive() -> PSSeasonArchive:
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.year = 2099
	archive.season_number = 9
	var standings: Dictionary = {}
	var i: int = 0
	for team_value in GameDb.teams:
		var t: PSTeam = team_value as PSTeam
		standings[str(t.id)] = {
			"wins": 80 - i, "losses": 60 + i, "draws": 3,
			"runs_scored": 600 - i * 5, "runs_allowed": 500 + i * 5,
		}
		i += 1
	archive.standings = standings

	var top_id: int = (GameDb.teams[0] as PSTeam).id
	var chal_id: int = (GameDb.teams[1] as PSTeam).id
	var post: PSPostseasonResult = PSPostseasonResult.new()
	post.japan_series = {
		"top_id": top_id, "challenger_id": chal_id, "winner_id": top_id,
		"top_wins_final": 4, "challenger_wins_final": 2, "completed": true,
		"advantage_wins": 0,
		"games": [
			{"game_num": 1, "away_id": chal_id, "home_id": top_id, "away_score": 2, "home_score": 5, "winner_id": top_id, "draw": false},
			{"game_num": 2, "away_id": chal_id, "home_id": top_id, "away_score": 4, "home_score": 1, "winner_id": chal_id, "draw": false},
		],
	}
	post.champion_team_id = top_id
	archive.postseason = post

	var awards: PSAwards = PSAwards.new()
	awards.mvp_central_player_id = 1
	awards.batting_titles = {"central": {"average": 1}, "pacific": {"home_runs": 2}}
	awards.pitching_titles = {"central": {"wins": 3}, "pacific": {"era": 4}}
	archive.awards = awards
	return archive


func test_offseason_view_state_exposes_ui_phase() -> void:
	var old_active: bool = AppState.offseason_active
	var old_step: int = AppState.offseason_step
	var old_draft_state: Dictionary = AppState.draft_state.duplicate(true)

	AppState.offseason_active = false
	var inactive: Dictionary = AppState.get_offseason_view_state()
	assert_bool(bool(inactive.get("active", true))).is_false()
	assert_str(str(inactive.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_NONE)
	assert_bool(bool(inactive.get("can_advance", true))).is_false()

	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_RELEASE_EDIT
	var release_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(release_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_RELEASE)
	assert_bool(bool(release_view.get("is_interactive", false))).is_true()
	assert_bool(bool(release_view.get("can_advance", true))).is_false()

	AppState.offseason_step = AppState.OFFSEASON_STEP_DRAFT_MAIN
	AppState.draft_state = {"complete": false, "segment": "main"}
	var draft_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(draft_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_DRAFT)
	assert_str(str(draft_view.get("status", ""))).is_equal("本指名")

	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.draft_state = old_draft_state
