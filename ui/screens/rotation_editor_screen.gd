extends Control

const ROTATION_SIZE: int = 6
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")

const PITCHER_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "球速", "key": "velocity", "width": 56, "type": "number", "format": "int"},
	{"title": "球質", "key": "stuff", "width": 56, "type": "number", "format": "int"},
	{"title": "制球", "key": "control", "width": 56, "type": "number", "format": "int"},
	{"title": "スタ", "key": "stamina", "width": 56, "type": "number", "format": "int"},
	{"title": "備考", "key": "note", "width": 90, "type": "string", "format": "string"},
]

var team_name_label: Label
var status_label: Label
var next_pitcher_label: Label
var rotation_grid: GridContainer
var save_button: Button
var pitcher_list: Tree

var slot_buttons: Array = []
var slot_player_ids: Array = []
var pitcher_records: Array = []


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "起用法 (先発ローテーション)"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	team_name_label = Label.new()
	team_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	team_name_label.add_theme_font_size_override("font_size", 18)
	header.add_child(team_name_label)

	var auto_button: Button = Button.new()
	auto_button.text = "自動編成"
	auto_button.custom_minimum_size = Vector2(96, 32)
	auto_button.pressed.connect(_on_auto_pressed)
	header.add_child(auto_button)

	var reset_button: Button = Button.new()
	reset_button.text = "リセット"
	reset_button.custom_minimum_size = Vector2(80, 32)
	reset_button.pressed.connect(_load_initial_state)
	header.add_child(reset_button)

	save_button = Button.new()
	save_button.text = "保存"
	save_button.custom_minimum_size = Vector2(80, 32)
	save_button.pressed.connect(_on_save_pressed)
	header.add_child(save_button)

	next_pitcher_label = Label.new()
	next_pitcher_label.add_theme_font_size_override("font_size", 14)
	root.add_child(next_pitcher_label)

	status_label = Label.new()
	status_label.text = ""
	root.add_child(status_label)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var ref_panel: VBoxContainer = VBoxContainer.new()
	ref_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(ref_panel)

	var ref_title: Label = Label.new()
	ref_title.text = "先発候補 (能力順)"
	ref_title.add_theme_font_size_override("font_size", 16)
	ref_panel.add_child(ref_title)

	pitcher_list = SortableTable.new()
	ref_panel.add_child(pitcher_list)
	pitcher_list.configure(PITCHER_COLUMNS)
	pitcher_list.set_default_sort(1, false)

	var editor_panel: VBoxContainer = VBoxContainer.new()
	editor_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(editor_panel)

	var editor_title: Label = Label.new()
	editor_title.text = "ローテーション (1〜6番手)"
	editor_title.add_theme_font_size_override("font_size", 16)
	editor_panel.add_child(editor_title)

	rotation_grid = GridContainer.new()
	rotation_grid.columns = 2
	rotation_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rotation_grid.add_theme_constant_override("h_separation", 8)
	rotation_grid.add_theme_constant_override("v_separation", 4)
	editor_panel.add_child(rotation_grid)

	_load_initial_state()


func _load_initial_state() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		_set_status("チームが選択されていません", true)
		return

	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		_set_status("チーム情報が取得できません", true)
		return
	team_name_label.text = "%s (%s)" % [team.name, team.short_name]

	_load_pitcher_pool(team_id)
	_populate_pitcher_list()

	var preview: Dictionary = GameSimulator.preview_rotation(season, team_id)
	var saved: Dictionary = season.get_rotation(team_id)

	var displayed_ids: Array = []
	var status_text: String = ""
	if saved.is_empty():
		if not bool(preview.get("ok", false)):
			_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
			_build_empty_grid()
			return
		displayed_ids = (preview.get("pitcher_ids", []) as Array).duplicate()
		status_text = "保存されたローテーションがありません。自動編成を表示しています。"
	else:
		displayed_ids = (saved.get("pitcher_ids", []) as Array).duplicate()
		if bool(saved.get("auto_generated", false)):
			status_text = "自動ローテーション状態を表示しています (Day %d 更新)" % int(saved.get("updated_at_day", 0))
		else:
			status_text = "保存されたローテーションを表示しています (Day %d 更新)" % int(saved.get("updated_at_day", 0))

	while displayed_ids.size() < ROTATION_SIZE:
		displayed_ids.append(0)
	if displayed_ids.size() > ROTATION_SIZE:
		displayed_ids = displayed_ids.slice(0, ROTATION_SIZE)

	_render_grid(displayed_ids)
	_set_status(status_text, false)
	_update_next_pitcher_label(preview)


func _load_pitcher_pool(team_id: int) -> void:
	var season: PSSeason = AppState.current_season
	pitcher_records = []
	if season == null:
		return
	var records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher():
			continue
		if not record.is_starter_pitcher():
			continue
		pitcher_records.append(record)
	pitcher_records.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return PlayerValueEvaluator.pitching_score(record_a) > PlayerValueEvaluator.pitching_score(record_b)
	)


func _populate_pitcher_list() -> void:
	var rows: Array = []
	for record_row in pitcher_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		rows.append({
			"name": record.name,
			"eval": PlayerValueEvaluator.pitching_score(record),
			"age": record.age,
			"velocity": PlayerVisibleRatings.pitcher_velocity(record),
			"stuff": PlayerVisibleRatings.pitcher_stuff(record),
			"control": PlayerVisibleRatings.pitcher_control(record),
			"stamina": PlayerVisibleRatings.pitcher_stamina(record),
			"note": "怪我%d日" % record.injury_days if record.injury_days > 0 else "",
		})
	pitcher_list.set_rows(rows)


func _build_empty_grid() -> void:
	for child in rotation_grid.get_children():
		rotation_grid.remove_child(child)
		child.queue_free()
	slot_buttons = []
	slot_player_ids = []


func _render_grid(initial_ids: Array) -> void:
	_build_empty_grid()

	var header_slot: Label = Label.new()
	header_slot.text = "番手"
	header_slot.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	rotation_grid.add_child(header_slot)
	var header_pitcher: Label = Label.new()
	header_pitcher.text = "投手"
	header_pitcher.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	rotation_grid.add_child(header_pitcher)

	for i in range(ROTATION_SIZE):
		var slot_label: Label = Label.new()
		slot_label.text = "%d番手" % (i + 1)
		slot_label.custom_minimum_size = Vector2(70, 28)
		rotation_grid.add_child(slot_label)

		var button: OptionButton = OptionButton.new()
		button.custom_minimum_size = Vector2(280, 28)
		var current_id: int = int(initial_ids[i]) if i < initial_ids.size() else 0
		_populate_pitcher_options(button, current_id)
		var slot_index_captured: int = i
		button.item_selected.connect(func(_index: int) -> void: _on_pitcher_changed(slot_index_captured))
		rotation_grid.add_child(button)
		slot_buttons.append(button)
		slot_player_ids.append(current_id)


func _populate_pitcher_options(button: OptionButton, current_id: int) -> void:
	button.clear()
	button.add_item("(自動)", 0)
	var select_index: int = 0
	for i in range(pitcher_records.size()):
		var record: PSPlayerSeasonRecord = pitcher_records[i] as PSPlayerSeasonRecord
		var label: String = "%s (評%d 球速%d 制球%d)" % [
			record.name,
			PlayerValueEvaluator.pitching_score(record),
			PlayerVisibleRatings.pitcher_velocity(record),
			PlayerVisibleRatings.pitcher_control(record),
		]
		if record.injury_days > 0:
			label += " [怪我%d日]" % record.injury_days
		button.add_item(label, record.player_id)
		if record.player_id == current_id:
			select_index = i + 1
	if button.item_count > 0:
		button.select(select_index)


func _on_pitcher_changed(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= slot_buttons.size():
		return
	var button: OptionButton = slot_buttons[slot_index] as OptionButton
	if button == null:
		return
	var new_id: int = button.get_selected_id()
	slot_player_ids[slot_index] = new_id
	if new_id > 0:
		_clear_pitcher_from_other_slots(new_id, slot_index)


func _clear_pitcher_from_other_slots(pitcher_id: int, exclude_slot: int) -> void:
	for i in range(slot_player_ids.size()):
		if i == exclude_slot:
			continue
		if int(slot_player_ids[i]) != pitcher_id:
			continue
		slot_player_ids[i] = 0
		var other_button: OptionButton = slot_buttons[i] as OptionButton
		if other_button != null:
			other_button.select(0)


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_rotation(season, team_id)
	if not bool(preview.get("ok", false)):
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		return
	var ids: Array = (preview.get("pitcher_ids", []) as Array).duplicate()
	while ids.size() < ROTATION_SIZE:
		ids.append(0)
	if ids.size() > ROTATION_SIZE:
		ids = ids.slice(0, ROTATION_SIZE)
	_render_grid(ids)
	_set_status("自動編成を表示中 (未保存)", false)


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
		return

	var ids: Array = []
	for value in slot_player_ids:
		ids.append(int(value))

	season.set_rotation(team_id, {"pitcher_ids": ids, "auto_generated": false})
	SaveService.save_state(AppState)
	var preview: Dictionary = GameSimulator.preview_rotation(season, team_id)
	_update_next_pitcher_label(preview)
	_set_status("保存しました (Day %d)" % season.current_day, false)


func _update_next_pitcher_label(preview: Dictionary) -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0 or next_pitcher_label == null:
		return
	var next_pitcher: PSPlayerSeasonRecord = null
	var next_pitcher_id: int = int(preview.get("next_pitcher_id", 0))
	if next_pitcher_id > 0:
		next_pitcher = _pitcher_record_by_id(next_pitcher_id)
	if next_pitcher == null:
		next_pitcher_label.text = "次回先発: (未定)"
	else:
		var reason: String = str(preview.get("rotation_reason", ""))
		var note: String = ""
		if reason == "spot":
			note = " / スポット"
		elif reason == "emergency":
			note = " / 緊急"
		next_pitcher_label.text = "次回先発: %s (評%d%s)" % [next_pitcher.name, PlayerValueEvaluator.pitching_score(next_pitcher), note]


func _pitcher_record_by_id(player_id: int) -> PSPlayerSeasonRecord:
	for record_row in pitcher_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return record
	return null


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	else:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
