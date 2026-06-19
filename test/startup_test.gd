# GdUnit4 への移行後の最初のテスト雛形。
# 旧 run_startup_smoke.gd 相当: 主要スクリプトのロードと autoload 登録を確認する。
# 新しいテストは test/ 配下に *_test.gd を追加するだけで自動検出される(専用 .tscn 不要)。
extends GdUnitTestSuite


func test_core_scripts_load() -> void:
	assert_object(load("res://ui/main.gd")).is_not_null()
	assert_object(load("res://ui/screens/home_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/offseason_screen.gd")).is_not_null()


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

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()

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


func test_screen_history_back_navigation() -> void:
	var old_screen: String = AppState.current_screen
	var old_player: int = AppState.current_player_id
	var old_history: Array = AppState._screen_history.duplicate(true)
	var old_forward: Array = AppState._forward_history.duplicate(true)

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
	AppState.current_screen = old_screen
	AppState.current_player_id = old_player


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
