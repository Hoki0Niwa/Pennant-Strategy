extends "res://ui/components/player_record_table.gd"

const SaveContext = preload("res://services/storage/save_context.gd")
const NARRATIVE_RECT: Rect2 = Rect2(262, 270, 1000, 244)
const AWARDS_RECT: Rect2 = Rect2(1280, 270, 620, 244)
const PLAYERS_RECT: Rect2 = Rect2(262, 630, 1638, 428)

var _year_entries: Array = []
var _review: PSSeasonReview
var _view: Dictionary = {}
var _selected_team: int = 0
var _tab: String = PLAYER_TAB_FIELDER
var _year_picker: OptionButton
var _team_picker: OptionButton
var _narrative_scroll: ScrollContainer
var _award_scroll: ScrollContainer
var _narrative_box: VBoxContainer
var _award_box: VBoxContainer
var _updating: bool = false
var _layout_size: Vector2 = Vector2(-1, -1)
var _revision: int = 0


func _ready() -> void:
	_init_chrome()
	_year_picker = OptionButton.new()
	_team_picker = OptionButton.new()
	for picker: OptionButton in [_year_picker, _team_picker]:
		picker.fit_to_longest_item = false
		picker.clip_text = true
	add_child(_year_picker)
	add_child(_team_picker)
	_year_picker.item_selected.connect(_on_year_selected)
	_team_picker.item_selected.connect(_on_team_selected)
	_narrative_scroll = _make_scroll()
	_award_scroll = _make_scroll()
	_narrative_box = _make_box(_narrative_scroll)
	_award_box = _make_box(_award_scroll)
	_narrative_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _remember_view())
	_award_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _remember_view())
	_refresh()


func _make_scroll() -> ScrollContainer:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	return scroll


func _make_box(scroll: ScrollContainer) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box


func _refresh() -> void:
	_updating = true
	_revision += 1
	var state: Dictionary = AppState.season_review_view_state
	if str(state.get("save_id", "")) != SaveContext.active_save_id():
		state = {}
	_year_entries = RecordStore.get_season_review_index()
	_year_picker.clear()
	var selected_index: int = maxi(0, _year_entries.size() - 1)
	for index in _year_entries.size():
		var entry: Dictionary = _year_entries[index] as Dictionary
		_year_picker.add_item(Loc.t("season_review.season_label", {"year": int(entry["year"]), "season": int(entry["season_number"])}))
		if int(state.get("year", 0)) == int(entry["year"]) and int(state.get("season_number", 0)) == int(entry["season_number"]):
			selected_index = index
	_review = null
	if not _year_entries.is_empty():
		_year_picker.select(selected_index)
		var entry: Dictionary = _year_entries[selected_index] as Dictionary
		_review = RecordStore.get_season_review(int(entry["year"]), int(entry["season_number"]))
	_team_picker.clear()
	_selected_team = int(state.get("team_id", AppState.selected_team_id))
	if _review != null:
		var teams: Array = _review.teams
		var team_index: int = 0
		for index in teams.size():
			var team: Dictionary = teams[index] as Dictionary
			_team_picker.add_item(str(team["team_name"]), int(team["team_id"]))
			if int(team["team_id"]) == _selected_team:
				team_index = index
		if not teams.is_empty():
			_team_picker.select(team_index)
			_selected_team = _team_picker.get_item_id(team_index)
	_tab = str(state.get("tab", PLAYER_TAB_FIELDER))
	if _tab not in [PLAYER_TAB_FIELDER, PLAYER_TAB_PITCHER]:
		_tab = PLAYER_TAB_FIELDER
	_scroll = (state.get("scroll", {}) as Dictionary).duplicate()
	_view = PSSeasonReviewService.team_view(_review, _selected_team) if _review != null else {}
	_populate_text()
	_build_buttons()
	_layout_content(true)
	_restore_scroll(_revision, int(state.get("scroll_narrative", 0)), int(state.get("scroll_awards", 0)))
	_updating = false
	_remember_view()
	queue_redraw()


func _populate_text() -> void:
	for box: VBoxContainer in [_narrative_box, _award_box]:
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()
	if _view.is_empty():
		return
	if not (_view["sentences"] as Array).has(str(_view["comparison_text"])):
		_add_paragraph(_narrative_box, str(_view["comparison_text"]), MUTED)
	for sentence: String in _view["sentences"]:
		_add_paragraph(_narrative_box, sentence, TEXT)
	var awards: Array = _view["awards"] as Array
	if awards.is_empty():
		_add_paragraph(_award_box, Loc.t("season_review.no_awards"), MUTED)
	for award: Dictionary in awards:
		var row: HBoxContainer = HBoxContainer.new()
		_award_box.add_child(row)
		var label: Label = Label.new()
		label.text = str(award["label"])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		var button: Button = Button.new()
		button.text = str(award["name"])
		button.tooltip_text = str(award["name"])
		button.clip_text = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var player_id: int = int(award["player_id"])
		button.disabled = GameDb.get_player(player_id) == null
		button.pressed.connect(func() -> void: _open_player(player_id))
		row.add_child(button)


func _add_paragraph(box: VBoxContainer, content: String, color: Color) -> void:
	var label: Label = Label.new()
	label.text = content
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", color)
	box.add_child(label)


func _build_buttons() -> void:
	# 年度・球団のOptionButtonは再利用し、ナビとタブだけを組み直す。
	for spec: Dictionary in _buttons:
		var button: Button = spec["button"] as Button
		remove_child(button)
		button.queue_free()
	_buttons.clear()
	_build_nav_buttons()
	_add_button("draft_review", Loc.t("draft_review.nav"), Rect2(1460, 98, 210, 34),
		func() -> void: _remember_view(); AppState.show_draft_retrospective(0, 0, _selected_team), "chip")
	var history: Button = _add_button("review_history", Loc.t("season_review.history"), Rect2(1690, 98, 210, 34), _open_history, "chip")
	history.disabled = _review == null
	if not _view.is_empty():
		var pitchers: Array = _view["contributors_pitcher"] as Array
		var fielders: Array = _view["contributors_fielder"] as Array
		_add_button("review_fielders", Loc.t("season_review.fielders", {"n": fielders.size()}), Rect2(278, 646, 96, 32),
			func() -> void: _set_player_tab(PLAYER_TAB_FIELDER), "chip_active" if _tab == PLAYER_TAB_FIELDER else "chip")
		_add_button("review_pitchers", Loc.t("season_review.pitchers", {"n": pitchers.size()}), Rect2(382, 646, 96, 32),
			func() -> void: _set_player_tab(PLAYER_TAB_PITCHER), "chip_active" if _tab == PLAYER_TAB_PITCHER else "chip")
	_layout_buttons()


func _layout_content(force: bool = false) -> void:
	if _year_picker == null:
		return
	if not force and _layout_size == size:
		return
	_layout_size = size
	_update_transform()
	_place(_year_picker, Rect2(322, 98, 242, 34))
	_place(_team_picker, Rect2(648, 98, 320, 34))
	for picker: OptionButton in [_year_picker, _team_picker]:
		_apply_button_style(picker, "action")
		_style_popup(picker.get_popup())
	_update_panel_visibility()
	_place(_narrative_scroll, NARRATIVE_RECT.grow_individual(-18, -50, -18, -16))
	_place(_award_scroll, AWARDS_RECT.grow_individual(-18, -50, -18, -16))
	for box: VBoxContainer in [_narrative_box, _award_box]:
		box.add_theme_constant_override("separation", maxi(4, int(12.0 * _scale_f)))
		for child in box.get_children():
			if child is Label:
				_style_label(child as Label)
			elif child is HBoxContainer:
				for cell in child.get_children():
					if cell is Label:
						_style_label(cell as Label)
					elif cell is Button:
						_apply_button_style(cell as Button, "action")
						cell.custom_minimum_size.y = 30.0 * _scale_f


func _update_panel_visibility() -> void:
	_year_picker.disabled = _year_entries.is_empty()
	_team_picker.disabled = _view.is_empty()
	_narrative_scroll.visible = not _view.is_empty()
	_award_scroll.visible = not _view.is_empty()


func _style_label(label: Label) -> void:
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", maxi(10, int(round(16.0 * _scale_f))))


func _place(control: Control, rect: Rect2) -> void:
	var scaled: Rect2 = _r(rect)
	control.position = scaled.position
	control.size = scaled.size


func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_row_hits.clear()
	_scroll_zones.clear()
	_round(Rect2(0, 0, SIDEBAR_W, BASE.y), SIDEBAR_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, 0), Vector2(SIDEBAR_W, BASE.y), BORDER_SOFT, 1.0)
	_round(Rect2(SIDEBAR_W, 0, BASE.x - SIDEBAR_W, HEADER_H), HEADER_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, HEADER_H), Vector2(BASE.x, HEADER_H), BORDER_SOFT, 1.0)
	_draw_sidebar()
	_text(Loc.t("season_review.title"), Vector2(262, 56), 28, TEXT)
	if not _view.is_empty():
		_text(str(_view["team"]["team_name"]), Vector2(530, 54), 20, TEXT, 900)
	_text(Loc.t("season_review.year"), Vector2(262, 121), 14, MUTED)
	_text(Loc.t("season_review.team"), Vector2(586, 121), 14, MUTED)
	_layout_content()
	if _view.is_empty():
		_text(Loc.t("season_review.empty") if _year_entries.is_empty() else Loc.t("season_review.unavailable"), Vector2(400, 430), 24, TEXT, 1300)
		_text(Loc.t("season_review.empty_hint"), Vector2(400, 478), 16, MUTED, 1300)
		return
	var team: Dictionary = _view["team"] as Dictionary
	var standing: Dictionary = team["standings"] as Dictionary
	var metrics: Dictionary = _view["metrics"] as Dictionary
	_stat_strip(Rect2(262, 152, 1638, 102), [
		{"label": Loc.t("season_review.completed_only"), "value": Loc.t("season_review.league_rank", {"league": PSTeam.league_label_for(str(team["league"])), "rank": int(team["rank"])})},
		{"label": Loc.t("season_review.wins_losses"), "value": Loc.t("season_review.record", {"wins": int(standing["wins"]), "losses": int(standing["losses"]), "draws": int(standing["draws"])})},
		{"label": Loc.t("season_review.win_rate"), "value": _metric(metrics.get("win_rate"), 3)},
		{"label": Loc.t("season_review.run_difference"), "value": "%+d" % int(metrics["run_difference"]), "color": _pm_color(float(metrics["run_difference"]))},
		{"label": Loc.t("season_review.postseason"), "value": str(_view["postseason_text"])},
	])
	_panel(NARRATIVE_RECT, Loc.t("season_review.narrative"))
	_panel(AWARDS_RECT, Loc.t("season_review.awards"))
	var bat: PSBatterStats = PSBatterStats.from_dict(team["batter_stats"] as Dictionary)
	var pit: PSPitcherStats = PSPitcherStats.from_dict(team["pitcher_stats"] as Dictionary)
	_stat_strip(Rect2(262, 530, 1638, 82), [
		{"label": Loc.t("season_review.avg"), "value": _rate_short(bat.batting_average()) if bat.at_bats > 0 else "-"},
		{"label": Loc.t("season_review.ops"), "value": _rate_short(bat.ops()) if bat.at_bats > 0 else "-"},
		{"label": Loc.t("season_review.hr"), "value": str(bat.home_runs)},
		{"label": Loc.t("season_review.era"), "value": _era_str_from_stats(pit)},
		{"label": Loc.t("season_review.strikeouts"), "value": str(pit.strikeouts)},
		{"label": Loc.t("season_review.rs_per_game"), "value": _metric(metrics.get("runs_scored_per_game"), 2)},
		{"label": Loc.t("season_review.ra_per_game"), "value": _metric(metrics.get("runs_allowed_per_game"), 2)},
	])
	var rows: Array = _view["contributors_" + _tab] as Array
	_draw_player_record_table(PLAYERS_RECT, Loc.t("season_review.contributors"), rows,
		_tab == PLAYER_TAB_PITCHER, "review_player", _tab, "", 0,
		Loc.t("season_review.no_contributors"), true, false, "", false, false, true)


func _metric(value: Variant, places: int) -> String:
	if value == null:
		return "-"
	return ("%.3f" if places == 3 else "%.2f") % float(value)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_update_transform()
		var base_pos: Vector2 = (event.position - _offset) / maxf(_scale_f, 0.001)
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			for zone: Dictionary in _scroll_zones:
				if (zone["rect"] as Rect2).has_point(base_pos):
					var step: int = -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
					_scroll[str(zone["key"])] = clampi(int(_scroll.get(str(zone["key"]), 0)) + step, 0, int(zone["max"]))
					_remember_view()
					queue_redraw()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			for hit: Dictionary in _row_hits:
				if (hit["rect"] as Rect2).has_point(base_pos):
					_open_player(int(hit["meta"]))
					break


func _remember_view() -> void:
	if _updating:
		return
	AppState.season_review_view_state = {"save_id": SaveContext.active_save_id(),
		"year": _review.year if _review != null else 0,
		"season_number": _review.season_number if _review != null else 0,
		"team_id": _selected_team, "tab": _tab, "scroll": _scroll.duplicate(),
		"scroll_narrative": _narrative_scroll.scroll_vertical, "scroll_awards": _award_scroll.scroll_vertical}


func _restore_scroll(revision: int, narrative: int, awards: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or revision != _revision:
		return
	_updating = true
	_narrative_scroll.scroll_vertical = narrative
	_award_scroll.scroll_vertical = awards
	_updating = false
	_remember_view()


func _on_year_selected(index: int) -> void:
	var entry: Dictionary = _year_entries[index] as Dictionary
	AppState.season_review_view_state.merge({"year": int(entry["year"]), "season_number": int(entry["season_number"]),
		"scroll": {}, "scroll_narrative": 0, "scroll_awards": 0}, true)
	_refresh()


func _on_team_selected(index: int) -> void:
	AppState.season_review_view_state.merge({"team_id": _team_picker.get_item_id(index), "scroll": {}, "scroll_narrative": 0, "scroll_awards": 0}, true)
	_refresh()


func _set_player_tab(tab: String) -> void:
	_tab = tab
	_remember_view()
	_build_buttons()
	queue_redraw()


func _open_player(player_id: int) -> void:
	if GameDb.get_player(player_id) == null:
		return
	_remember_view()
	AppState.show_player_detail(player_id)


func _open_history() -> void:
	if _review == null:
		return
	_remember_view()
	AppState.show_season_history(_review.year, _review.season_number)
