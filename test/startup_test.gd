# GdUnit4 への移行後の最初のテスト雛形。
# 旧 run_startup_smoke.gd 相当: 主要スクリプトのロードと autoload 登録を確認する。
# 新しいテストは test/ 配下に *_test.gd を追加するだけで自動検出される(専用 .tscn 不要)。
extends GdUnitTestSuite

const SaveContext = preload("res://services/storage/save_context.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")


func test_core_scripts_load() -> void:
	assert_object(load("res://ui/main.gd")).is_not_null()
	assert_object(load("res://ui/screens/home_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/offseason_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/options_screen.gd")).is_not_null()


func test_dashboard_long_date_includes_weekday() -> void:
	var dashboard_script: GDScript = load("res://ui/components/dashboard_screen.gd") as GDScript
	var dashboard: Control = dashboard_script.new()
	assert_str(str(dashboard.call("_format_date_long", "2026-10-10"))).is_equal("2026年 10月10日(土)")
	dashboard.free()


func test_autoloads_registered() -> void:
	# autoload はシーン/プロジェクト起動時のみ登録される(=旧運用で .tscn が必要だった理由)。
	# GdUnit はプロジェクト文脈で実行するため singleton として参照できる。
	assert_object(Engine.get_main_loop().root.get_node_or_null("AppState")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("GameDb")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("ModManager")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("RecordStore")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("Rng")).is_not_null()


func test_mod_manager_default_rules_and_paths() -> void:
	assert_str(ModManager.resolve_data_path("initial_players", "res://fallback.csv")).is_equal("res://fallback.csv")
	assert_int(ModManager.rule_int("season.schedule.pennant_games_per_team", 0)).is_equal(PSSchedule.PENNANT_GAMES_PER_TEAM)
	assert_float(ModManager.rule_float("simulation.pa_probability.k_logit_base", -999.0)).is_equal(PSPaProbabilityCalculator.K_LOGIT_BASE)
	var metadata: Dictionary = ModManager.save_metadata()
	assert_str(str(metadata.get("rules_profile_id", ""))).is_equal("pennant_strategy_default")
	assert_int(int(metadata.get("rules_schema_version", 0))).is_equal(1)
	assert_bool(metadata.has("active_mods")).is_true()


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


func test_home_screen_calendar_distinguishes_offseason_from_rest_day() -> void:
	# シーズン期間外(日本シーズン終了〜翌年開幕まで)の空セルは「休養」ではなく「オフシーズン」と
	# 表示する。シーズン期間内の空セル(交流戦後の休養カード等)は従来どおり「休養」のまま。
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	var season: PSSeason = AppState.current_season

	var home_script: GDScript = load("res://ui/screens/home_screen.gd") as GDScript
	var screen: Control = home_script.new()
	add_child(screen)
	await get_tree().process_frame

	var first_date: String = str((season.schedule[0] as Dictionary).get("date", ""))
	var last_date: String = str((season.schedule[season.schedule.size() - 1] as Dictionary).get("date", ""))
	var after_season_date: String = SeasonCalendar.add_days(last_date, 30)
	var before_season_date: String = SeasonCalendar.add_days(first_date, -30)

	assert_bool(bool(screen.call("_is_within_season_schedule_range", first_date, season))).is_true()
	assert_bool(bool(screen.call("_is_within_season_schedule_range", last_date, season))).is_true()
	assert_bool(bool(screen.call("_is_within_season_schedule_range", after_season_date, season))).is_false()
	assert_bool(bool(screen.call("_is_within_season_schedule_range", before_season_date, season))).is_false()

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


func test_trade_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	var trade_script: GDScript = load("res://ui/screens/trade_screen.gd") as GDScript
	var screen: Control = trade_script.new()
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


func test_game_result_line_score_uses_result_or_log_innings() -> void:
	var screen_script: GDScript = load("res://ui/screens/game_result_screen.gd") as GDScript
	var screen = screen_script.new()

	var from_result: Array = screen._line_score_innings({
		"result": {
			"innings": [
				{"inning": 1, "away": 2, "home": 1, "home_half_played": true},
			],
		},
	}, {})
	assert_int(from_result.size()).is_equal(1)
	assert_int(int((from_result[0] as Dictionary).get("away", 0))).is_equal(2)

	var from_log: Array = screen._line_score_innings({"result": {}}, {
		"innings": [
			{"inning": 1, "away": 0, "home": 3, "home_half_played": true},
		],
	})
	assert_int(from_log.size()).is_equal(1)
	assert_int(int((from_log[0] as Dictionary).get("home", 0))).is_equal(3)

	screen.queue_free()


func test_game_result_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "game_results"
	var test_save_id: String = SaveContext.active_save_id()

	# 開幕日を消化して試合ログ (play_events) をメモリに残し、詳細描画経路を実データで通す。
	var GameSimulator = load("res://services/simulation/game_simulator.gd")
	GameSimulator.simulate_current_day(AppState.current_season, false)

	var screen_script: GDScript = load("res://ui/screens/game_result_screen.gd") as GDScript
	var screen: Control = screen_script.new()
	add_child(screen)
	await get_tree().process_frame

	# サイドバーナビ + 表示チームボタンが生成される。
	assert_int(screen.get_child_count()).is_greater(0)
	# 開幕試合が選択され、打席結果・投手成績の集計が組み立てられている。
	assert_int(screen._selected_index).is_greater_equal(0)
	assert_int((screen._box_data.get("rows", []) as Array).size()).is_greater(0)
	assert_int((screen._pitching.get("rows", []) as Array).size()).is_greater(0)
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


func test_player_detail_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_player: int = AppState.current_player_id
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "player_detail"
	var GameSimulator = load("res://services/simulation/game_simulator.gd")
	GameSimulator.simulate_current_day(AppState.current_season, false)
	var history_keys: Array = AppState.current_season.player_game_history.keys()
	assert_array(history_keys).is_not_empty()
	AppState.current_player_id = int(str(history_keys[0]))
	var test_save_id: String = SaveContext.active_save_id()

	var screen_script: GDScript = load("res://ui/screens/player_detail_screen.gd") as GDScript
	var screen: Control = screen_script.new()
	add_child(screen)
	await get_tree().process_frame

	# サイドバーナビ + 絞り込み chip + タブ等のボタンが生成され、選手が解決されている。
	assert_int(screen.get_child_count()).is_greater(0)
	assert_array(screen._candidates).is_not_empty()
	assert_object(screen._record).is_not_null()
	assert_array(screen._basic_rows).is_not_empty()
	assert_array(screen._game_rows).is_not_empty()
	assert_array(screen._monthly_rows).is_not_empty()
	assert_array(screen._ability_rows).is_not_empty()
	var faint_month_found: bool = false
	for row_value in screen._monthly_rows:
		var row: Dictionary = row_value as Dictionary
		if row.has("__color"):
			faint_month_found = true
			break
	assert_bool(faint_month_found).is_true()

	# 今季タブ(既定)はカテゴリ別カードを遅延計算する。
	screen._ensure_season_cards()
	assert_array(screen._season_groups).is_not_empty()

	# 試合履歴は出場経路を表示し、単発の試合数/打率列は持たない。
	screen._active_tab = "games"
	var game_cols: Array = screen._columns_for_tab()
	var has_route_col: bool = false
	var has_game_count_col: bool = false
	var has_avg_col: bool = false
	for col_value in game_cols:
		var col: Dictionary = col_value as Dictionary
		var key: String = str(col.get("key", ""))
		has_route_col = has_route_col or key == "route"
		has_game_count_col = has_game_count_col or key == "g"
		has_avg_col = has_avg_col or key == "avg"
	assert_bool(has_route_col).is_true()
	assert_bool(has_game_count_col).is_false()
	assert_bool(has_avg_col).is_false()

	# 過去指標タブを開くと WAR/wOBA 集計が遅延計算される (末尾に通算行)。
	screen._active_tab = "advanced"
	screen._ensure_advanced()
	assert_array(screen._advanced_rows).is_not_empty()
	screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.current_player_id = old_player
	AppState.last_status_message = old_status
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_ability_stats_screen_builds_each_tab_and_mode() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "ability_stats"
	var test_save_id: String = SaveContext.active_save_id()

	var screen_script: GDScript = load("res://ui/screens/ability_stats_screen.gd") as GDScript
	var screen: Control = screen_script.new()
	screen.size = Vector2(1920, 1080)
	add_child(screen)
	await get_tree().process_frame

	# 既定 = 全球団 / 野手 / 能力値。母集団・行・列が構築され、_draw でヘッダ判定が積まれている。
	assert_array(screen._filtered).is_not_empty()
	assert_array(screen._rows).is_not_empty()
	assert_array(screen._columns_for_current()).is_not_empty()
	assert_str(screen._current_mode()).is_equal("batter")
	assert_array(screen._header_hits).is_not_empty()

	# 規定打席/投球回トグル: このシーズンはまだ1試合も消化していないので、規定到達者のみに
	# 絞ると全員 (PA=0) が対象外になり空になる。もう一度押すと元の人数に戻る。
	var rows_before_qualifier: int = screen._rows.size()
	screen._on_qualified_toggle()
	assert_bool(screen._qualified_only).is_true()
	assert_array(screen._filtered).is_empty()
	assert_array(screen._rows).is_empty()
	screen._on_qualified_toggle()
	assert_bool(screen._qualified_only).is_false()
	assert_int(screen._rows.size()).is_equal(rows_before_qualifier)

	# 行の左クリック=単独選択 / Ctrl=複数トグル / Shift=範囲選択 / 選択解除でゼロへ。
	assert_int(screen._rows.size()).is_greater_equal(4)
	var pid_a: int = int((screen._rows[0] as Dictionary).get("__meta", 0))
	var pid_b: int = int((screen._rows[1] as Dictionary).get("__meta", 0))
	var pid_d: int = int((screen._rows[3] as Dictionary).get("__meta", 0))
	screen._on_row_selected(pid_a, false, false)
	assert_int(screen._selected_ids.size()).is_equal(1)
	assert_bool(screen._selected_ids.has(pid_a)).is_true()
	screen._on_row_selected(pid_b, true, false)   # Ctrl+クリックで追加
	assert_int(screen._selected_ids.size()).is_equal(2)
	screen._on_row_selected(pid_b, true, false)   # 再Ctrlで解除
	assert_int(screen._selected_ids.size()).is_equal(1)
	screen._on_row_selected(pid_a, false, false)  # 単独クリックはその選手のみ (アンカー確立)
	assert_int(screen._selected_ids.size()).is_equal(1)
	screen._on_row_selected(pid_d, false, true)   # Shift+クリック → 表示順 rows[0..3] の4件
	assert_int(screen._selected_ids.size()).is_equal(4)
	assert_bool(screen._selected_ids.has(pid_a)).is_true()
	assert_bool(screen._selected_ids.has(pid_d)).is_true()
	screen._on_clear_selection()
	assert_int(screen._selected_ids.size()).is_equal(0)

	# 投手へ切替 → 列セットが投手 mode になる。能力タブの球種カラムは母集団の和集合。
	screen._on_filter_pressed("p_all")
	assert_str(screen._current_mode()).is_equal("pitcher")
	assert_array(screen._rows).is_not_empty()
	assert_array(screen._pitch_types).is_not_empty()

	# 成績タブへの切替: タブは列セットが変わるだけで母集団は同じなので、ソートをやり直さず
	# 直前の並び順 (player_id 列) を維持する。
	var order_before_stats: Array = screen._row_meta_order()
	screen._on_tab_pressed("stats")
	assert_array(screen._rows).is_not_empty()
	assert_array(screen._row_meta_order()).is_equal(order_before_stats)

	# 高度な指標タブ (WAR のリーグ文脈集計を行う経路) でも同様に並び順を維持する。
	var order_before_advanced: Array = screen._row_meta_order()
	screen._on_tab_pressed("advanced")
	assert_array(screen._rows).is_not_empty()
	assert_array(screen._row_meta_order()).is_equal(order_before_advanced)

	# ヘッダクリックのソート: 別カラムを選ぶと降順から始まり、同カラム再クリックで昇順へトグルする。
	screen._on_header_clicked("ip")
	assert_str(screen._sort_key).is_equal("ip")
	assert_bool(screen._sort_asc).is_false()
	screen._on_header_clicked("ip")
	assert_bool(screen._sort_asc).is_true()

	# 守備位置で絞り込み (野手 mode に戻る) + 描画でヘッダ判定再構築。
	screen._on_filter_pressed("b_6")
	assert_str(screen._current_mode()).is_equal("batter")
	screen.queue_redraw()
	await get_tree().process_frame
	assert_array(screen._header_hits).is_not_empty()

	# 球団絞り込み → 全球団 へ戻せる (PopupMenu の負 id 自動採番で戻れなくなる回帰の防止)。
	var sample_team: int = int(screen._team_ids[0])
	screen._on_team_selected(sample_team)
	assert_int(screen._view_team_id).is_equal(sample_team)
	screen._on_team_selected(screen.ALL_TEAMS_MENU_ID)
	assert_int(screen._view_team_id).is_equal(screen.ALL_TEAMS_ID)
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


func test_ability_stats_screen_sort_tiebreaks_by_playing_time() -> void:
	# 本塁打などの加算統計が同値 (=0) のとき、今季出場なしの選手が出場ありの選手の
	# 間に挟まる回帰の防止: 同値時は出場量 (打者は打席数) の多い方を向きに関係なく先に出す。
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "ability_stats"
	var test_save_id: String = SaveContext.active_save_id()

	var screen_script: GDScript = load("res://ui/screens/ability_stats_screen.gd") as GDScript
	var screen: Control = screen_script.new()
	screen.size = Vector2(1920, 1080)
	add_child(screen)
	await get_tree().process_frame

	assert_str(screen._current_mode()).is_equal("batter")
	screen._rows = [
		{"name": "Active0HR", "hr": 0, "pa": 350, "__meta": 1},
		{"name": "NoGames", "hr": 0, "pa": 0, "__meta": 2},
		{"name": "PowerHitter", "hr": 30, "pa": 500, "__meta": 3},
	]
	screen._sort_key = "hr"
	screen._sort_asc = false
	screen._sort_rows()
	var names_desc: Array = []
	for row_value in screen._rows:
		names_desc.append(str((row_value as Dictionary).get("name", "")))
	assert_array(names_desc).is_equal(["PowerHitter", "Active0HR", "NoGames"])

	# 昇順にトグルしても、出場なし選手が出場ありの選手より前に出ることはない。
	screen._sort_asc = true
	screen._sort_rows()
	var names_asc: Array = []
	for row_value in screen._rows:
		names_asc.append(str((row_value as Dictionary).get("name", "")))
	assert_array(names_asc).is_equal(["Active0HR", "NoGames", "PowerHitter"])
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


func test_awards_screen_builds_with_current_awards() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_awards: PSAwards = AppState.current_awards
	var old_post: PSPostseasonResult = AppState.current_postseason
	var old_post_active: bool = AppState.postseason_active
	var old_save_id: String = SaveContext.active_save_id()

	var central_team: PSTeam = null
	var pacific_team: PSTeam = null
	for team_value in GameDb.teams:
		var t: PSTeam = team_value as PSTeam
		if t.league == "central" and central_team == null:
			central_team = t
		elif t.league == "pacific" and pacific_team == null:
			pacific_team = t
	assert_object(central_team).is_not_null()
	assert_object(pacific_team).is_not_null()

	AppState.select_team(central_team.id)
	AppState.start_new_season()
	AppState.current_screen = "awards"
	var test_save_id: String = SaveContext.active_save_id()

	var central_records: Array = RecordStore.get_team_player_records(central_team.id, AppState.current_season.year, AppState.current_season.season_number)
	var pacific_records: Array = RecordStore.get_team_player_records(pacific_team.id, AppState.current_season.year, AppState.current_season.season_number)
	var central_batter: PSPlayerSeasonRecord = _first_record(central_records, false)
	var central_pitcher: PSPlayerSeasonRecord = _first_record(central_records, true)
	var pacific_batter: PSPlayerSeasonRecord = _first_record(pacific_records, false)
	var pacific_pitcher: PSPlayerSeasonRecord = _first_record(pacific_records, true)
	assert_object(central_batter).is_not_null()
	assert_object(central_pitcher).is_not_null()
	assert_object(pacific_batter).is_not_null()
	assert_object(pacific_pitcher).is_not_null()

	var awards: PSAwards = PSAwards.new()
	awards.year = AppState.current_season.year
	awards.season_number = AppState.current_season.season_number
	awards.mvp_central_player_id = central_batter.player_id
	awards.rookie_central_player_id = central_pitcher.player_id
	awards.mvp_pacific_player_id = pacific_batter.player_id
	awards.rookie_pacific_player_id = pacific_pitcher.player_id
	awards.batting_titles = {
		"central": {"average": central_batter.player_id},
		"pacific": {"home_runs": pacific_batter.player_id},
	}
	awards.pitching_titles = {
		"central": {"wins": central_pitcher.player_id},
		"pacific": {"era": pacific_pitcher.player_id},
	}
	AppState.current_awards = awards

	var post: PSPostseasonResult = PSPostseasonResult.new()
	post.japan_series = {
		"top_id": central_team.id, "challenger_id": pacific_team.id, "winner_id": central_team.id,
		"top_wins_final": 4, "challenger_wins_final": 2, "completed": true,
	}
	post.champion_team_id = central_team.id
	AppState.current_postseason = post

	var script: GDScript = load("res://ui/screens/awards_screen.gd") as GDScript
	var screen: Control = script.new()
	add_child(screen)
	await get_tree().process_frame

	assert_int(screen.get_child_count()).is_greater(0)
	assert_bool(screen._has_awards).is_true()
	assert_int(screen._champion_id).is_equal(central_team.id)
	assert_int((screen._award_rows as Array).size()).is_equal(2)
	assert_int((screen._bat_rows as Array).size()).is_equal(PSAwards.BATTING_CATEGORIES.size())
	assert_int((screen._pit_rows as Array).size()).is_equal(PSAwards.PITCHING_CATEGORIES.size())
	screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.current_awards = old_awards
	AppState.current_postseason = old_post
	AppState.postseason_active = old_post_active
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_team_detail_screen_builds_with_active_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "team_detail"
	var test_save_id: String = SaveContext.active_save_id()

	# 開幕日を消化して打撃/投球成績を残し、打線・ローテ・ランキング集計を実データで通す。
	var GameSimulator = load("res://services/simulation/game_simulator.gd")
	GameSimulator.simulate_current_day(AppState.current_season, false)

	# 直近5年パネルのポストシーズン表示経路を検証するためアーカイブを1件差し込む
	# (_make_test_archive は teams[0] を日本一にする → 直近成績の ps が "日本一")。
	var archives: Array = RecordStore.get_season_archives()
	var archive: PSSeasonArchive = _make_test_archive()
	archives.append(archive)

	var script: GDScript = load("res://ui/screens/team_detail_screen.gd") as GDScript
	var screen: Control = script.new()
	add_child(screen)
	await get_tree().process_frame

	# サイドバーナビ + チーム巡回ボタンが生成されている。
	assert_int(screen.get_child_count()).is_greater(0)
	# 今期成績と巡回順が集計されている。
	assert_int(screen._team_ids.size()).is_equal(GameDb.teams.size())
	assert_int(screen._rank).is_greater(0)
	# 打順 (9枠) と先発ローテが組み立てられている。
	assert_int((screen._lineup_rows as Array).size()).is_greater(0)
	assert_int((screen._rotation_rows as Array).size()).is_greater(0)
	# チーム内ランキングは野手5 + 投手5 = 10カテゴリ。
	assert_int((screen._ranking_cards as Array).size()).is_equal(10)
	# サマリーの指標リーグ内順位 (得点/失点/打率…) が算出されている。
	assert_bool(screen._metric_ranks.has("rs")).is_true()
	assert_int(int(screen._metric_ranks.get("avg", 0))).is_greater(0)
	# 直近5年パネルにアーカイブ行があり、日本一のポストシーズン結果が付与されている。
	assert_int((screen._recent5 as Array).size()).is_greater(0)
	assert_str(str((screen._recent5[0] as Dictionary).get("ps", ""))).is_equal("日本一")
	# プルダウンで別球団へ切り替えても落ちない。
	var other_id: int = int(screen._team_ids[screen._team_ids.size() - 1])
	screen._on_team_selected(other_id)
	await get_tree().process_frame
	assert_int(screen._team_id).is_equal(other_id)
	screen.queue_free()

	archives.erase(archive)
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


func _first_record(records: Array, pitcher: bool) -> PSPlayerSeasonRecord:
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null and record.is_pitcher() == pitcher:
			return record
	return null


# オフシーズン画面 (dashboard_screen 継承の自前描画刷新) の build/draw スモーク。
# 戦力外通告 (対話パネル) と 引退/成長/ドラフト (結果テーブル + 2カラム + 12球団グリッド) の
# 描画経路を、画面を tree に載せて 1 フレーム回し例外なく通ることで確認する。
func test_offseason_screen_builds_each_step() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_active: bool = AppState.offseason_active
	var old_step: int = AppState.offseason_step
	var old_results: Dictionary = AppState.offseason_results.duplicate(true)
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	AppState.current_screen = "offseason"
	var test_save_id: String = SaveContext.active_save_id()

	# 戦力外 WAR 列のため開幕日を消化して成績を残す。
	var GameSimulator = load("res://services/simulation/game_simulator.gd")
	GameSimulator.simulate_current_day(AppState.current_season, false)

	AppState.offseason_active = true
	var script: GDScript = load("res://ui/screens/offseason_screen.gd") as GDScript

	# (1) 戦力外通告: 対話パネル (実データで populate)。
	AppState.offseason_step = AppState.OFFSEASON_STEP_RELEASE_EDIT
	var release_screen: Control = script.new()
	add_child(release_screen)
	await get_tree().process_frame
	assert_str(str(release_screen._active_panel)).is_equal(AppState.OFFSEASON_PANEL_RELEASE)
	assert_int((release_screen._release_rows as Array).size()).is_greater(0)
	# 行クリックのトグル経路 (戦力外 → 育成降格 → 解除) が落ちない。
	var first_pid: int = int((release_screen._release_rows[0] as Dictionary).get("__meta", 0))
	release_screen._toggle_release(first_pid)
	assert_bool(release_screen.selected_release_ids.has(first_pid)).is_true()
	release_screen.queue_free()

	# (2) 結果テーブル群: 引退 / 成長 (2カラム) / ドラフト (12球団グリッド) を inject して描画。
	AppState.offseason_results["step_%d" % AppState.OFFSEASON_STEP_RETIREMENT] = {
		"title": "引退",
		"retired": [{"team_id": team.id, "name": "テスト 引退", "age": 38, "position": 3, "role": "fielder", "years": 15, "overall": 60}],
	}
	AppState.offseason_results["step_%d" % AppState.OFFSEASON_STEP_GROWTH] = {
		"title": "成長",
		"growers_count": 1, "decayers_count": 0,
		"growth_kind_counts": {"awakening": 1},
		"pitchers": [{"name": "成長 投手", "age": 22, "growth_label": "成長", "after": 70, "delta": 5,
			"abilities": [{"key": "velocity", "after": 150, "delta": 2, "suffix": ""}]}],
		"fielders": [{"name": "成長 野手", "age": 23, "growth_label": "覚醒", "after": 72, "delta": 8,
			"abilities": [{"key": "contact", "after": 68, "delta": 6, "suffix": ""}]}],
	}
	AppState.offseason_results["step_%d" % AppState.OFFSEASON_STEP_DRAFT_MAIN] = {
		"title": "本指名", "priority_league": "central", "logs": [], "rookies": [],
		"draft_picks": [{"team_id": team.id, "overall_pick": 1, "round": 1, "name": "ルーキー", "age": 18,
			"position": 1, "overall": 65, "source_type": "high_school", "development": false, "lottery": false}],
	}
	for step in [AppState.OFFSEASON_STEP_RETIREMENT, AppState.OFFSEASON_STEP_GROWTH, AppState.OFFSEASON_STEP_DRAFT_MAIN]:
		AppState.offseason_step = step
		var result_screen: Control = script.new()
		add_child(result_screen)
		await get_tree().process_frame
		assert_str(str(result_screen._active_panel)).is_equal(AppState.OFFSEASON_PANEL_RESULTS)
		assert_bool((result_screen._view as Dictionary).get("active", false)).is_true()
		result_screen.queue_free()

	# 後始末。
	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.offseason_results = old_results
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


# 契約更新 延長交渉パネル (OFFSEASON_PANEL_CONTRACT_EXTENSION) が実データで populate/draw できるか。
# 候補は GameDb.players に登録せず注入した Array だけで作る (GdUnit プロセス内で共有される
# GameDb.players を汚染しないため)。_ext_entry_row は player==null (GameDb未登録) を許容する。
func test_offseason_screen_builds_contract_extension_panel() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_active: bool = AppState.offseason_active
	var old_step: int = AppState.offseason_step
	var old_state: Dictionary = AppState.contract_update_state.duplicate(true)

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.selected_team_id = team.id
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	season.calendar_start_date = "2026-03-27"
	AppState.current_season = season
	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_CONTRACT_UPDATE

	var OffseasonServiceRef = load("res://services/season/offseason_service.gd")
	# player_value_score が EXTENSION_MIN_VALUE(60) 以上になるよう主要な z 能力を平均より高くする
	# (z_abilities={} の平均的選手だと閾値を下回りプールが空になり phase が "done" のままになる)。
	var strong_z: Dictionary = {}
	for key in ["Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "IF_Reach", "IF_Secure", "Run_Speed"]:
		strong_z[key] = 2.5
	var candidate: PSPlayer = PSPlayer.from_dict({
		"id": 999901, "team_id": team.id, "position": 3, "role": "fielder", "age": 26, "years": 8,
		"salary": 6000, "contract_status": "FA可能", "z_abilities": strong_z, "raw_abilities": {},
		"source_data": {"fa_nissuu": 9999},
	})
	AppState.contract_update_state = OffseasonServiceRef.create_contract_update_state([candidate], [team], season, team.id)
	assert_str(str(AppState.contract_update_state.get("phase", ""))).is_equal("extension")

	var script: GDScript = load("res://ui/screens/offseason_screen.gd") as GDScript
	var screen: Control = script.new()
	add_child(screen)
	await get_tree().process_frame
	assert_str(str(screen._active_panel)).is_equal(AppState.OFFSEASON_PANEL_CONTRACT_EXTENSION)
	var total_rows: int = (screen._ext_pitcher_rows as Array).size() + (screen._ext_fielder_rows as Array).size()
	assert_int(total_rows).is_equal(1)
	screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.contract_update_state = old_state


func test_offseason_salary_table_layout_and_market_salary_priority() -> void:
	var script: GDScript = load("res://ui/screens/offseason_screen.gd") as GDScript
	var screen: Control = script.new()
	var rect: Rect2 = Rect2(262.0, 256.0, 1638.0, 804.0)

	assert_bool((screen.call("_player_table_x", rect, "", false) as Dictionary).has("salary_r")).is_false()
	for team_mode in ["", "team", "move"]:
		var xs: Dictionary = screen.call("_player_table_x", rect, team_mode, true) as Dictionary
		assert_bool(xs.has("salary_r")).is_true()
		assert_float(float(xs["salary_r"])).is_less(float(xs["age_r"]))
		assert_float(float(xs["stam_r"])).is_less_equal(float(xs["g_r"]) - 44.0)
		assert_float(float(xs["eye_r"])).is_less_equal(float(xs["g_r"]) - 42.0)

	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.salary = 1000
	assert_int(int(screen.call("_player_table_salary", {}, record))).is_equal(1000)
	assert_int(int(screen.call("_player_table_salary", {"candidate": {"salary": 1200}}, record))).is_equal(1200)
	assert_int(int(screen.call("_player_table_salary", {"candidate": {"salary": 1200, "offer_salary": 1800}}, record))).is_equal(1800)
	assert_int(int(screen.call("_player_table_salary", {"salary": 1400, "offer_salary": 2000}, record))).is_equal(2000)
	assert_int(int(screen.call("_player_table_salary", {"new_salary": 2200, "offer_salary": 2000}, record))).is_equal(2200)
	screen.free()


func test_offseason_view_state_exposes_ui_phase() -> void:
	var old_active: bool = AppState.offseason_active
	var old_step: int = AppState.offseason_step
	var old_draft_state: Dictionary = AppState.draft_state.duplicate(true)
	var old_contract_update_state: Dictionary = AppState.contract_update_state.duplicate(true)

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

	AppState.offseason_step = AppState.OFFSEASON_STEP_CONTRACT_UPDATE
	AppState.contract_update_state = {"complete": false, "phase": "extension"}
	var ext_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(ext_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_CONTRACT_EXTENSION)
	assert_bool(bool(ext_view.get("is_interactive", false))).is_true()
	AppState.contract_update_state = {"complete": true, "phase": "done"}
	var ext_done_view: Dictionary = AppState.get_offseason_view_state()
	assert_bool(bool(ext_done_view.get("is_interactive", true))).is_false()

	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.draft_state = old_draft_state
	AppState.contract_update_state = old_contract_update_state


# 外国人ステップ (step7) は phase "contract"→"contract_result"→"scout"→"scout_result" の4段が
# それぞれ専用の active_panel へ写像される (Fix3: 結果パネルを契約市場/スカウトで分離)。
func test_offseason_view_state_foreign_market_phases_map_to_panels() -> void:
	var old_active: bool = AppState.offseason_active
	var old_step: int = AppState.offseason_step
	var old_foreign_state: Dictionary = AppState.foreign_state.duplicate(true)

	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_FOREIGN_MARKET

	AppState.foreign_state = {"complete": false, "phase": "contract"}
	var contract_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(contract_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT)
	assert_bool(bool(contract_view.get("is_interactive", false))).is_true()

	AppState.foreign_state = {"complete": false, "phase": "contract_result"}
	var contract_result_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(contract_result_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT)
	assert_bool(bool(contract_result_view.get("is_interactive", false))).is_true()

	AppState.foreign_state = {"complete": false, "phase": "scout"}
	var scout_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(scout_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_FOREIGN)

	AppState.foreign_state = {"complete": false, "phase": "scout_result"}
	var scout_result_view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(scout_result_view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_FOREIGN_RESULT)

	# complete=true になれば phase を問わずステップ結果画面 (対話パネルなし) へ落ちる。
	AppState.foreign_state = {"complete": true, "phase": "scout_result"}
	var done_view: Dictionary = AppState.get_offseason_view_state()
	assert_bool(bool(done_view.get("is_interactive", true))).is_false()

	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.foreign_state = old_foreign_state


# ポストシーズン: 引き分けで規定試合数に達しイーブンなら、追加試合なしで上位 (top) が勝ち抜ける。
# games.size() >= 規定試合数のシリーズは play_series_game がシミュ前に確定するため season は不要。
func test_postseason_tie_break_advances_higher_seed() -> void:
	var dummy_games: Array = [{"game_num": 1}, {"game_num": 2}, {"game_num": 3}]
	# CSファースト相当 (win_target=2, advantage=0 → 規定3試合)。1-1 のイーブン → 上位が勝ち抜け。
	var even_series: Dictionary = {
		"top_id": 10, "challenger_id": 20, "win_target": 2, "advantage_wins": 0,
		"games": dummy_games.duplicate(true), "top_wins": 1, "challenger_wins": 1, "completed": false,
	}
	var r1: Dictionary = PostseasonService.play_series_game(null, even_series, 1)
	assert_bool(bool(r1.get("completed", false))).is_true()
	assert_bool(bool(even_series.get("completed", false))).is_true()
	assert_int(int(even_series.get("winner_id", 0))).is_equal(10)

	# 挑戦者が勝ち越していれば挑戦者が勝ち抜け。
	var chal_series: Dictionary = {
		"top_id": 10, "challenger_id": 20, "win_target": 2, "advantage_wins": 0,
		"games": dummy_games.duplicate(true), "top_wins": 0, "challenger_wins": 1, "completed": false,
	}
	PostseasonService.play_series_game(null, chal_series, 1)
	assert_int(int(chal_series.get("winner_id", 0))).is_equal(20)


func test_postseason_calendar_slots_are_scheduled() -> void:
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	var post: PSPostseasonResult = PostseasonService.build_initial_state(season, GameDb.teams)

	assert_array(post.cs1_central.get("scheduled_dates", []) as Array).is_equal(["2026-10-10", "2026-10-11", "2026-10-12"])
	assert_array(post.cs2_central.get("scheduled_dates", []) as Array).is_equal(["2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19"])
	assert_array(post.japan_series.get("scheduled_dates", []) as Array).is_equal(["2026-10-24", "2026-10-25", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-31", "2026-11-01"])
	assert_str(str(post.japan_series.get("first_home_league", ""))).is_equal(PostseasonService.FIRST_LEAGUE)
	assert_array(post.japan_series.get("home_sides", []) as Array).is_equal([
		PostseasonService.HOME_SIDE_TOP,
		PostseasonService.HOME_SIDE_TOP,
		PostseasonService.HOME_SIDE_CHALLENGER,
		PostseasonService.HOME_SIDE_CHALLENGER,
		PostseasonService.HOME_SIDE_CHALLENGER,
		PostseasonService.HOME_SIDE_TOP,
		PostseasonService.HOME_SIDE_TOP,
	])

	var next_season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2027, {})
	next_season.season_number = 2
	var next_post: PSPostseasonResult = PostseasonService.build_initial_state(next_season, GameDb.teams)
	assert_str(str(next_post.japan_series.get("first_home_league", ""))).is_equal(PostseasonService.SECOND_LEAGUE)


func test_start_postseason_sets_current_date_to_cs1_opening_day() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_post: PSPostseasonResult = AppState.current_postseason
	var old_post_active: bool = AppState.postseason_active
	var old_awards: PSAwards = AppState.current_awards
	var old_auto_save: bool = AppState.auto_save_enabled
	var old_save_id: String = SaveContext.active_save_id()

	AppState.auto_save_enabled = false
	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	assert_bool(AppState.start_new_season()).is_true()
	var test_save_id: String = SaveContext.active_save_id()

	var last_regular_day: int = 1
	for game_value in AppState.current_season.schedule:
		var game: Dictionary = game_value as Dictionary
		game["played"] = true
		last_regular_day = max(last_regular_day, int(game.get("day", 0)))
	AppState.current_season.current_day = last_regular_day + 1

	var start_result: Dictionary = AppState.start_postseason()
	assert_bool(bool(start_result.get("ok", false))).is_true()
	assert_bool(AppState.postseason_active).is_true()
	assert_str(SeasonCalendar.current_date(AppState.current_season)).is_equal("2026-10-10")
	assert_int(AppState.current_season.current_day).is_equal(SeasonCalendar.season_day_for_date(AppState.current_season, "2026-10-10"))
	assert_int(AppState.current_postseason.current_day).is_equal(0)
	assert_int((AppState.current_postseason.cs1_central.get("games", []) as Array).size()).is_equal(0)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.last_status_message = old_status
	AppState.current_postseason = old_post
	AppState.postseason_active = old_post_active
	AppState.current_awards = old_awards
	AppState.auto_save_enabled = old_auto_save
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


# ポストシーズン: 日単位消化 (第1/第2リーグ同時) → 完了 → ダッシュボード生成 → 試合結果タブ収集。
func test_postseason_day_advance_and_dashboard() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_screen: String = AppState.current_screen
	var old_status: String = AppState.last_status_message
	var old_post: PSPostseasonResult = AppState.current_postseason
	var old_post_active: bool = AppState.postseason_active
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	AppState.current_postseason = PostseasonService.build_initial_state(AppState.current_season, GameDb.teams)
	AppState.postseason_active = true
	AppState.current_screen = "home"
	var non_playing_record: PSPlayerSeasonRecord = _first_record_not_in_cs1(AppState.current_postseason, AppState.current_season)
	assert_object(non_playing_record).is_not_null()
	non_playing_record.fatigue = 100
	var sync_result: Dictionary = PostseasonService.sync_to_next_postseason_day(AppState.current_postseason, AppState.current_season)
	assert_bool(bool(sync_result.get("ok", false))).is_true()
	assert_str(str(sync_result.get("date", ""))).is_equal("2026-10-10")
	assert_str(SeasonCalendar.current_date(AppState.current_season)).is_equal("2026-10-10")
	assert_int(non_playing_record.fatigue).is_equal(0)

	# 1日進める = CS1 第1/第2リーグが同時に1試合ずつ消化される。
	var day_result: Dictionary = AppState.advance_postseason_day()
	assert_bool(bool(day_result.get("ok", false))).is_true()
	assert_int(AppState.current_postseason.current_day).is_equal(1)
	assert_str(str(day_result.get("date", ""))).is_equal("2026-10-10")
	assert_int(AppState.current_season.current_day).is_equal(SeasonCalendar.season_day_for_date(AppState.current_season, "2026-10-11"))
	assert_int(non_playing_record.fatigue).is_equal(0)
	assert_int((AppState.current_postseason.cs1_central.get("games", []) as Array).size()).is_equal(1)
	assert_int((AppState.current_postseason.cs1_pacific.get("games", []) as Array).size()).is_equal(1)
	var first_game: Dictionary = (AppState.current_postseason.cs1_central.get("games", []) as Array)[0] as Dictionary
	assert_str(str(first_game.get("date", ""))).is_equal("2026-10-10")
	assert_int(int(first_game.get("season_day", 0))).is_equal(SeasonCalendar.season_day_for_date(AppState.current_season, "2026-10-10"))
	var ps_status_script: GDScript = load("res://ui/screens/postseason_screen.gd") as GDScript
	var ps_status_screen: Control = ps_status_script.new()
	assert_str(str(ps_status_screen.call("_day_status_message", day_result))).contains("10/10(土)")
	ps_status_screen.free()

	var stage_guard: int = 20
	while stage_guard > 0 and PostseasonService.active_group_index(AppState.current_postseason) == 0:
		stage_guard -= 1
		var cs1_step: Dictionary = AppState.advance_postseason_day()
		assert_bool(bool(cs1_step.get("ok", false))).is_true()
	assert_int(PostseasonService.active_group_index(AppState.current_postseason)).is_equal(1)
	assert_str(SeasonCalendar.current_date(AppState.current_season)).is_equal("2026-10-14")

	stage_guard = 20
	while stage_guard > 0 and PostseasonService.active_group_index(AppState.current_postseason) == 1:
		stage_guard -= 1
		var cs2_step: Dictionary = AppState.advance_postseason_day()
		assert_bool(bool(cs2_step.get("ok", false))).is_true()
	assert_int(PostseasonService.active_group_index(AppState.current_postseason)).is_equal(2)
	assert_str(SeasonCalendar.current_date(AppState.current_season)).is_equal("2026-10-24")

	# ポストシーズン用ダッシュボードがブラケット込みで生成される。
	var ps_script: GDScript = load("res://ui/screens/postseason_screen.gd") as GDScript
	var ps_screen: Control = ps_script.new()
	add_child(ps_screen)
	await get_tree().process_frame
	assert_int(ps_screen.get_child_count()).is_greater(0)
	ps_screen.queue_free()

	# 残りを全消化 → 日本一が確定する。
	var guard: int = 400
	while guard > 0 and not PostseasonService.is_complete(AppState.current_postseason):
		guard -= 1
		var step: Dictionary = AppState.advance_postseason_day()
		if not bool(step.get("ok", false)):
			break
	assert_bool(PostseasonService.is_complete(AppState.current_postseason)).is_true()
	assert_int(AppState.current_postseason.champion_team_id).is_greater(0)

	# 試合結果画面: 日本一チーム視点でポストシーズン試合が収集される。
	AppState.select_team(AppState.current_postseason.champion_team_id)
	AppState.current_screen = "game_results"
	var gr_script: GDScript = load("res://ui/screens/game_result_screen.gd") as GDScript
	var gr_screen: Control = gr_script.new()
	add_child(gr_screen)
	await get_tree().process_frame
	assert_int((gr_screen._ps_games_for_view as Array).size()).is_greater(0)
	var ps_entry: Dictionary = (gr_screen._ps_games_for_view as Array)[0] as Dictionary
	var ps_game: Dictionary = ps_entry.get("game", {}) as Dictionary
	var ps_date_label: String = SeasonCalendar.compact_label_for_game(ps_game, AppState.current_season)
	assert_str(ps_date_label).contains("(")
	assert_str(ps_date_label).contains(")")
	gr_screen.queue_free()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_screen = old_screen
	AppState.last_status_message = old_status
	AppState.current_postseason = old_post
	AppState.postseason_active = old_post_active
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


# ポストシーズンの詳細結果 (box score / play-by-play) 永続化の回帰。
# auto_save_enabled=false で PS 試合を消化すると PostseasonService.advance_one_day(persist=false) は
# ログファイルを書かない (docs/agent_memory/project_save_folder_layout.md の「暗黙保存」方針: 通常
# シーズンの GameLogService.write_pending_game_logs と同様、手動保存時にまとめて flush する想定)。
# メモリ上の games[].result はこの時点ではまだフル (to_dict の SLIM_RESULT_KEYS 縮小前) なので、
# GameLogService.write_pending_postseason_game_logs を挟めばログファイルへ退避でき、その後
# to_dict/from_dict でスリム化されても game_result_screen._ps_game_log と同じフォールバックで
# 詳細を復元できることを検証する。
func test_postseason_pending_game_log_persists_through_save_and_reload() -> void:
	var old_season: PSSeason = AppState.current_season
	var old_post: PSPostseasonResult = AppState.current_postseason
	var old_post_active: bool = AppState.postseason_active
	var old_auto_save: bool = AppState.auto_save_enabled
	var old_team_id: int = AppState.selected_team_id
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.auto_save_enabled = false
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	AppState.current_postseason = PostseasonService.build_initial_state(AppState.current_season, GameDb.teams)
	AppState.postseason_active = true
	PostseasonService.sync_to_next_postseason_day(AppState.current_postseason, AppState.current_season)

	# auto_save_enabled=false のまま1日進める → PostseasonService.advance_one_day(persist=false) が呼ばれる。
	var day_result: Dictionary = AppState.advance_postseason_day()
	assert_bool(bool(day_result.get("ok", false))).is_true()

	var games_before: Array = AppState.current_postseason.cs1_central.get("games", []) as Array
	assert_int(games_before.size()).is_equal(1)
	var game_before: Dictionary = games_before[0] as Dictionary
	var result_before: Dictionary = game_before.get("result", {}) as Dictionary
	assert_bool(result_before.has("play_events")).is_true()  # まだフル result (縮小前)

	# バグ再現: persist=false だったのでログファイルはまだ存在しない。
	var log_before_flush: Dictionary = PSGameLogService.read_postseason_game_log(AppState.current_season, "cs1_central", 1)
	assert_bool(log_before_flush.is_empty()).is_true()

	# 修正: 手動保存が行うべき pending ログ flush を直接呼ぶ。
	# (本来は SaveService.save_state から呼ぶ配線が必要だが、当該ファイルは本タスクでは編集禁止。
	# 詳細は対応する調査タスクの最終報告を参照。)
	PSGameLogService.write_pending_postseason_game_logs(AppState.current_postseason, AppState.current_season)
	var log_after_flush: Dictionary = PSGameLogService.read_postseason_game_log(AppState.current_season, "cs1_central", 1)
	assert_bool(log_after_flush.is_empty()).is_false()
	assert_array(log_after_flush.get("pa_log", []) as Array).is_not_empty()

	# to_dict/from_dict の往復でも試合結果サマリ (スコア・勝敗) は保持される。
	var restored: PSPostseasonResult = PSPostseasonResult.from_dict(AppState.current_postseason.to_dict())
	var restored_games: Array = restored.cs1_central.get("games", []) as Array
	assert_int(restored_games.size()).is_equal(1)
	var restored_game: Dictionary = restored_games[0] as Dictionary
	assert_int(int(restored_game.get("away_score", -1))).is_equal(int(game_before.get("away_score", -2)))
	assert_int(int(restored_game.get("home_score", -1))).is_equal(int(game_before.get("home_score", -2)))
	assert_int(int(restored_game.get("winner_id", -1))).is_equal(int(game_before.get("winner_id", -2)))
	var restored_result: Dictionary = restored_game.get("result", {}) as Dictionary
	assert_bool(restored_result.has("play_events")).is_false()  # to_dict でスリム化される

	# game_result_screen._ps_game_log と同じフォールバック経路: スリム化後の result には
	# play_events が無いので、事前に flush されたログファイルから詳細を復元できる。
	var reloaded_log: Dictionary = PSGameLogService.read_postseason_game_log(AppState.current_season, "cs1_central", int(restored_game.get("game_num", 0)))
	assert_bool(reloaded_log.is_empty()).is_false()
	assert_array(reloaded_log.get("pa_log", []) as Array).is_not_empty()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.current_postseason = old_post
	AppState.postseason_active = old_post_active
	AppState.auto_save_enabled = old_auto_save
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func _first_record_not_in_cs1(post: PSPostseasonResult, season: PSSeason) -> PSPlayerSeasonRecord:
	var playing: Dictionary = {}
	for key in ["cs1_central", "cs1_pacific"]:
		var series: Dictionary = post.stage_dict(str(key))
		playing[int(series.get("top_id", 0))] = true
		playing[int(series.get("challenger_id", 0))] = true
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or playing.has(team.id):
			continue
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		if not records.is_empty():
			return records[0] as PSPlayerSeasonRecord
	return null
