extends Control

const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")

var overview_label: Label
var status_label: Label
var days_spinbox: SpinBox
var next_team_game_label: Label
var auto_swap_checkbox: CheckButton
var auto_save_checkbox: CheckButton


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "スキップ設定"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)
	header.add_child(Control.new())

	overview_label = Label.new()
	overview_label.add_theme_font_size_override("font_size", 16)
	root.add_child(overview_label)

	next_team_game_label = Label.new()
	next_team_game_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(next_team_game_label)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	auto_swap_checkbox = CheckButton.new()
	auto_swap_checkbox.text = "スキップ中は成績ベースで自動的に一二軍入替を行う"
	auto_swap_checkbox.set_pressed_no_signal(AppState.auto_roster_swap_during_skip)
	auto_swap_checkbox.toggled.connect(_on_auto_swap_checkbox_toggled)
	root.add_child(auto_swap_checkbox)

	auto_save_checkbox = CheckButton.new()
	auto_save_checkbox.text = "自動セーブを有効にする (試合進行・オフシーズン処理時)"
	auto_save_checkbox.set_pressed_no_signal(AppState.auto_save_enabled)
	auto_save_checkbox.toggled.connect(_on_auto_save_checkbox_toggled)
	root.add_child(auto_save_checkbox)

	root.add_child(_section_label("単発スキップ"))
	var single_row: HBoxContainer = HBoxContainer.new()
	single_row.add_theme_constant_override("separation", 8)
	root.add_child(single_row)
	single_row.add_child(_action_button("次の試合", _on_next_game))
	single_row.add_child(_action_button("本日全試合", _on_current_day))

	root.add_child(_section_label("日数指定"))
	var days_row: HBoxContainer = HBoxContainer.new()
	days_row.add_theme_constant_override("separation", 8)
	root.add_child(days_row)

	var days_prefix: Label = Label.new()
	days_prefix.text = "進める日数"
	days_prefix.custom_minimum_size = Vector2(120, 32)
	days_row.add_child(days_prefix)

	days_spinbox = SpinBox.new()
	days_spinbox.min_value = 1
	days_spinbox.max_value = 143
	days_spinbox.value = 7
	days_spinbox.custom_minimum_size = Vector2(100, 32)
	days_row.add_child(days_spinbox)

	days_row.add_child(_action_button("指定日数進める", _on_days_pressed))
	days_row.add_child(_action_button("7日進める", func() -> void: _simulate_days(7)))
	days_row.add_child(_action_button("30日進める", func() -> void: _simulate_days(30)))

	root.add_child(_section_label("条件指定"))
	var cond_row: HBoxContainer = HBoxContainer.new()
	cond_row.add_theme_constant_override("separation", 8)
	root.add_child(cond_row)
	cond_row.add_child(_action_button("自軍の次戦まで", _on_until_team_game))
	cond_row.add_child(_action_button("残り全試合", _on_remaining_season))

	var refresh_button: Button = Button.new()
	refresh_button.text = "情報更新"
	refresh_button.custom_minimum_size = Vector2(120, 32)
	refresh_button.pressed.connect(_refresh_overview)
	root.add_child(refresh_button)

	root.add_child(Control.new())

	_refresh_overview()


func _section_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.86, 0.90, 0.94))
	return label


func _action_button(text: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(160, 32)
	button.pressed.connect(callback)
	return button


func _refresh_overview() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		overview_label.text = "シーズンが開始されていません"
		next_team_game_label.text = ""
		return
	overview_label.text = "%d年 / %d年目  Day %d  残り%d試合 (全%d試合)" % [
		season.year, season.season_number, season.current_day,
		season.games_remaining(), season.total_games(),
	]
	next_team_game_label.text = _format_next_team_game(season, AppState.selected_team_id)


func _format_next_team_game(season: PSSeason, team_id: int) -> String:
	if team_id <= 0:
		return ""
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("away_team_id", 0)) != team_id and int(game.get("home_team_id", 0)) != team_id:
			continue
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		var venue: String = "@" if team_id == away_id else "vs"
		var opp_id: int = home_id if team_id == away_id else away_id
		var opp_team: PSTeam = GameDb.get_team(opp_id)
		var opp_name: String = opp_team.short_name if opp_team != null else "-"
		var day_gap: int = int(game.get("day", 0)) - season.current_day
		var gap_text: String = "本日" if day_gap == 0 else "%d日後" % day_gap
		return "次の自軍試合: Day %d (%s) %s %s" % [int(game.get("day", 0)), gap_text, venue, opp_name]
	return "自軍の未消化試合がありません"


func _on_next_game() -> void:
	# 1 試合だけなので同期で十分 (~100-300ms)
	var result: Dictionary = AppState.simulate_next_game(true)
	_apply_result(result)


func _on_current_day() -> void:
	var ov: Dictionary = _show_progress_overlay("本日の試合を消化中…")
	var result: Dictionary = await AppState.simulate_current_day_async(
		get_tree(), ov["callback"], ov["cancel_token"], true
	)
	_hide_progress_overlay(ov)
	_apply_result(result)


func _on_days_pressed() -> void:
	await _simulate_days(int(days_spinbox.value))


func _simulate_days(days: int) -> void:
	var ov: Dictionary = _show_progress_overlay("%d日分を消化中…" % days)
	var result: Dictionary = await AppState.simulate_days_async(
		days, get_tree(), ov["callback"], ov["cancel_token"], true
	)
	_hide_progress_overlay(ov)
	_apply_result(result)


func _on_until_team_game() -> void:
	var ov: Dictionary = _show_progress_overlay("自軍の次戦まで消化中…")
	var result: Dictionary = await AppState.simulate_until_team_game_async(
		get_tree(), ov["callback"], ov["cancel_token"], true
	)
	_hide_progress_overlay(ov)
	_apply_result(result)


func _on_remaining_season() -> void:
	var ov: Dictionary = _show_progress_overlay("残り全試合を消化中…")
	var result: Dictionary = await AppState.simulate_remaining_season_async(
		get_tree(), ov["callback"], ov["cancel_token"], true
	)
	_hide_progress_overlay(ov)
	_apply_result(result)


func _show_progress_overlay(label: String) -> Dictionary:
	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress(label)
	var update_cb: Callable = func(done: int, total: int, sub: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, sub)
	return {
		"overlay": overlay,
		"cancel_token": cancel_token,
		"callback": update_cb,
	}


func _hide_progress_overlay(ov: Dictionary) -> void:
	var overlay: ProgressOverlay = ov.get("overlay") as ProgressOverlay
	if overlay != null:
		overlay.hide_progress()
		overlay.queue_free()


func _on_auto_swap_checkbox_toggled(pressed: bool) -> void:
	AppState.auto_roster_swap_during_skip = pressed
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if pressed and season != null and team_id > 0:
		# ON 直後のスキップで即発動するよう、最終入替日を current_day - SWAP_INTERVAL_DAYS に
		season.set_last_auto_swap_day(team_id, season.current_day - TeamAutoAI.SWAP_INTERVAL_DAYS)
	SaveService.save_state(AppState)


func _on_auto_save_checkbox_toggled(pressed: bool) -> void:
	AppState.auto_save_enabled = pressed
	# このトグル自体はユーザの明示操作なので、フラグ反転を保存しておく (auto_save_enabled の値が反映された状態でセーブ)
	SaveService.save_state(AppState)


func _apply_result(result: Dictionary) -> void:
	var ok: bool = bool(result.get("ok", false))
	status_label.text = str(result.get("message", ""))
	status_label.add_theme_color_override("font_color", Color(0.78, 0.92, 0.78) if ok else Color(0.95, 0.55, 0.55))
	_refresh_overview()
