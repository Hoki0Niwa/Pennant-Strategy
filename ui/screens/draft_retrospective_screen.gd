extends "res://ui/components/player_record_table.gd"

const SaveContext = preload("res://services/storage/save_context.gd")
const PLAYERS_RECT: Rect2 = Rect2(262, 240, 1638, 552)
const DETAILS_RECT: Rect2 = Rect2(262, 810, 1638, 248)

var _draft_class: PSDraftClass
var _view: Dictionary = {}
var _year_entries: Array = []
var _selected_team: int = 0
var _kind: String = "main"
var _scope: String = "all"
var _period_text: String = ""
var _selected_player_id: int = 0
var _rows: Array = []
var _year_picker: OptionButton
var _team_picker: OptionButton
var _details_scroll: ScrollContainer
var _details_text: Label
var _layout_size: Vector2 = Vector2(-1, -1)
var _updating: bool = false
var _revision: int = 0


func _ready() -> void:
	_init_chrome()
	_year_picker = OptionButton.new()
	_team_picker = OptionButton.new()
	for picker: OptionButton in [_year_picker, _team_picker]:
		picker.fit_to_longest_item = false
		picker.clip_text = true
		add_child(picker)
	_year_picker.item_selected.connect(_on_year_selected)
	_team_picker.item_selected.connect(_on_team_selected)
	_details_scroll = ScrollContainer.new()
	_details_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_details_scroll)
	_details_text = Label.new()
	_details_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details_scroll.add_child(_details_text)
	_details_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _remember_view())
	_refresh()


func _refresh() -> void:
	_updating = true
	_revision += 1
	var state: Dictionary = AppState.draft_review_view_state
	if str(state.get("save_id", "")) != SaveContext.active_save_id():
		state = {}
	_year_entries = RecordStore.get_draft_class_index()
	_year_picker.clear()
	var selected_year: int = maxi(0, _year_entries.size() - 1)
	for index in _year_entries.size():
		var entry: Dictionary = _year_entries[index]
		_year_picker.add_item(Loc.t("draft_review.year_label", {"year": int(entry["year"]), "season": int(entry["season_number"])}))
		if int(state.get("year", 0)) == int(entry["year"]) and int(state.get("season_number", 0)) == int(entry["season_number"]):
			selected_year = index
	_draft_class = null
	if not _year_entries.is_empty():
		_year_picker.select(selected_year)
		var entry: Dictionary = _year_entries[selected_year]
		_draft_class = RecordStore.get_draft_class(int(entry["year"]), int(entry["season_number"]))
	_selected_team = int(state.get("team_id", AppState.selected_team_id))
	_team_picker.clear()
	if _draft_class != null:
		var team_index: int = 0
		for team: Dictionary in _draft_class.teams:
			_team_picker.add_item(str(team["team_name"]), int(team["team_id"]))
			if int(team["team_id"]) == _selected_team:
				team_index = _team_picker.item_count - 1
		if _team_picker.item_count > 0:
			_team_picker.select(team_index)
			_selected_team = _team_picker.get_item_id(team_index)
	_kind = "development" if str(state.get("kind", "main")) == "development" else "main"
	_scope = "team" if str(state.get("scope", "all")) == "team" else "all"
	_selected_player_id = int(state.get("selected_player_id", 0))
	_scroll = (state.get("scroll", {}) as Dictionary).duplicate()
	_view = {}
	_period_text = Loc.t("draft_review.uncompleted")
	if _draft_class != null:
		var reviews: Array = []
		var end_year: int = _draft_class.year
		var end_number: int = _draft_class.season_number
		for entry: Dictionary in RecordStore.get_season_review_index():
			if int(entry["year"]) <= _draft_class.year or int(entry["season_number"]) <= _draft_class.season_number:
				continue
			var review: PSSeasonReview = RecordStore.get_season_review(int(entry["year"]), int(entry["season_number"]))
			if review != null:
				reviews.append(review)
				end_year = review.year
				end_number = review.season_number
		_view = PSDraftRetrospectiveService.build(_draft_class, reviews, end_year, end_number, _selected_team)
		if bool(_view["has_completed_season"]):
			_period_text = Loc.t("draft_review.career_period", {"start": _draft_class.year + 1, "end": end_year})
		if not (_view["missing_seasons"] as Array).is_empty():
			_period_text += "  " + Loc.t("draft_review.missing", {"n": (_view["missing_seasons"] as Array).size()})
	_rebuild_rows()
	_build_buttons()
	_layout_content(true)
	_restore_scroll(_revision, int(state.get("scroll_details", 0)))
	_updating = false
	_remember_view()
	queue_redraw()


func _rebuild_rows() -> void:
	_rows = []
	for player: Dictionary in _view.get("players", []):
		var identity: Dictionary = player["identity"]
		if bool(identity.get("development", false)) == (_kind == "development"):
			_rows.append(PSPlayerRecordTableRow.from_history(identity, player[_scope] as Dictionary))
	var found: bool = false
	for row: Dictionary in _rows:
		if int(row["entry"]["player_id"]) == _selected_player_id:
			found = true
	if not found:
		_selected_player_id = 0
		_details_scroll.scroll_vertical = 0
	_update_details()


func _build_buttons() -> void:
	for spec: Dictionary in _buttons:
		var button: Button = spec["button"]
		remove_child(button)
		button.queue_free()
	_buttons.clear()
	_build_nav_buttons()
	_add_button("season_review", Loc.t("season_review.nav"), Rect2(1690, 22, 210, 40), _open_review, "chip")
	if _draft_class != null:
		for index in 2:
			var key: String = "main" if index == 0 else "development"
			var label_key: String = "draft_review.main" if index == 0 else "draft_review.development"
			_add_button("kind_" + key, Loc.t(label_key), Rect2(262 + index * 166, 152, 156, 34),
				func() -> void: _set_kind(key), "chip_active" if _kind == key else "chip")
		for index in 2:
			var scope: String = "all" if index == 0 else "team"
			var label_key: String = "draft_review.all_teams" if index == 0 else "draft_review.draft_team"
			_add_button("scope_" + scope, Loc.t(label_key), Rect2(690 + index * 240, 152, 230, 34),
				func() -> void: _set_scope(scope), "chip_active" if _scope == scope else "chip")
		var detail: Button = _add_button("player_detail", Loc.t("draft_review.player_detail"), Rect2(1630, 820, 252, 32), _open_player, "chip")
		detail.disabled = _selected_player_id <= 0 or GameDb.get_player(_selected_player_id) == null
	_layout_buttons()


func _layout_content(force: bool = false) -> void:
	if _year_picker == null or (not force and _layout_size == size):
		return
	_layout_size = size
	_update_transform()
	_place(_year_picker, Rect2(346, 98, 300, 34))
	_place(_team_picker, Rect2(730, 98, 330, 34))
	for picker: OptionButton in [_year_picker, _team_picker]:
		_apply_button_style(picker, "action")
		_style_popup(picker.get_popup())
	_year_picker.disabled = _year_entries.is_empty()
	_team_picker.disabled = _draft_class == null
	_details_scroll.visible = _draft_class != null
	_place(_details_scroll, DETAILS_RECT.grow_individual(-18, -56, -18, -16))
	_details_text.add_theme_font_override("font", _font)
	_details_text.add_theme_font_size_override("font_size", maxi(10, int(16.0 * _scale_f)))
	_details_text.add_theme_color_override("font_color", TEXT)


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
	_round(Rect2(SIDEBAR_W, 0, BASE.x - SIDEBAR_W, HEADER_H), HEADER_BG, Color.TRANSPARENT, 0, 0)
	_draw_sidebar()
	_text(Loc.t("draft_review.nav"), Vector2(262, 56), 28, TEXT)
	_text(str(_view.get("team_name", "")), Vector2(530, 54), 20, TEXT, 900)
	_text(Loc.t("draft_review.year"), Vector2(262, 121), 14, MUTED)
	_text(Loc.t("season_review.team"), Vector2(670, 121), 14, MUTED)
	_layout_content()
	if _draft_class == null:
		_text(Loc.t("draft_review.empty"), Vector2(350, 430), 24, TEXT, 1500)
		_text(Loc.t("draft_review.empty_hint"), Vector2(350, 478), 16, MUTED, 1500)
		return
	_text(_period_text, Vector2(278, 222), 14, MUTED, 1590)
	_draw_draft_pick_table(PLAYERS_RECT, _rows, _selected_player_id, _kind)
	_panel(DETAILS_RECT, Loc.t("draft_review.details"))


func _draw_draft_pick_table(rect: Rect2, rows: Array, selected_id: int, scroll_key: String) -> void:
	_draw_player_record_table(rect, Loc.t("draft_review.players"), rows, false, "draft_player", scroll_key,
		"", selected_id, Loc.t("draft_review.no_rows"), false, false, "draft_history_mixed", false, false, true)


func _update_details() -> void:
	_details_text.text = Loc.t("draft_review.select_player")
	for row: Dictionary in _rows:
		var identity: Dictionary = row["entry"]
		if int(identity["player_id"]) == _selected_player_id:
			_details_text.text = str(identity["name"]) + "\n" + Loc.t("draft_review.current", {"status": _current_status(_selected_player_id)})
			for player: Dictionary in _view["players"]:
				if int(player["identity"]["player_id"]) != _selected_player_id:
					continue
				for annual: Dictionary in player["years"]:
					var totals: Dictionary = annual[_scope]
					var outs: int = int(totals["pitcher_stats"].get("outs_pitched", 0))
					_details_text.text += "\n" + Loc.t("draft_review.year_stats", {"year": int(annual["year"]),
						"pa": int(totals["batter_stats"].get("plate_appearances", 0)),
						"ip": "%d.%d" % [int(float(outs) / 3.0), outs % 3], "war": "%.1f" % float(totals["war"])})
			break


func _current_status(player_id: int) -> String:
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null:
		return Loc.t("draft_review.unknown")
	if player.is_overseas():
		return Loc.t("draft_review.overseas")
	if player.is_retired():
		return Loc.t("draft_review.retired")
	var team: PSTeam = GameDb.get_team(player.team_id)
	return team.name if team != null else Loc.t("draft_review.unattached")


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
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
					_select_player(int(hit["meta"]))
					break


func _remember_view() -> void:
	if _updating:
		return
	AppState.draft_review_view_state = {"save_id": SaveContext.active_save_id(),
		"year": _draft_class.year if _draft_class != null else 0, "season_number": _draft_class.season_number if _draft_class != null else 0,
		"team_id": _selected_team, "kind": _kind, "scope": _scope, "selected_player_id": _selected_player_id,
		"scroll": _scroll.duplicate(), "scroll_details": _details_scroll.scroll_vertical}


func _restore_scroll(revision: int, offset: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or revision != _revision:
		return
	_updating = true
	_details_scroll.scroll_vertical = offset
	_updating = false
	_remember_view()


func _on_year_selected(index: int) -> void:
	var entry: Dictionary = _year_entries[index]
	AppState.draft_review_view_state.merge({"year": int(entry["year"]), "season_number": int(entry["season_number"]),
		"selected_player_id": 0, "scroll": {}, "scroll_details": 0}, true)
	_refresh()


func _on_team_selected(index: int) -> void:
	AppState.draft_review_view_state.merge({"team_id": _team_picker.get_item_id(index), "selected_player_id": 0, "scroll": {}, "scroll_details": 0}, true)
	_refresh()


func _set_kind(kind: String) -> void:
	_kind = "development" if kind == "development" else "main"
	_rebuild_rows()
	_build_buttons()
	_remember_view()
	queue_redraw()


func _select_player(player_id: int) -> void:
	_selected_player_id = player_id
	_details_scroll.scroll_vertical = 0
	_update_details()
	_build_buttons()
	_remember_view()
	queue_redraw()


func _set_scope(scope: String) -> void:
	_scope = "team" if scope == "team" else "all"
	_rebuild_rows()
	_build_buttons()
	_remember_view()
	queue_redraw()


func _open_player() -> void:
	if _selected_player_id > 0 and GameDb.get_player(_selected_player_id) != null:
		_remember_view()
		AppState.show_player_detail(_selected_player_id)


func _open_review() -> void:
	_remember_view()
	AppState.show_season_review(0, 0, _selected_team)
