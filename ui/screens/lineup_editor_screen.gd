extends Control

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")

const ROSTER_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "守備", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "適性", "key": "apt", "width": 170, "type": "string", "format": "string"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
	{"title": "打撃", "key": "bat", "width": 56, "type": "number", "format": "int"},
	{"title": "備考", "key": "note", "width": 90, "type": "string", "format": "string"},
]

const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher",
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}

const NON_DH_FIELDING_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9]
const DH_FIELDING_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9, 10]
const FIELDER_USAGE_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9]
const SUB_INTERVAL_FATIGUE_EMERGENCY: int = -1
const SUB_INTERVAL_OPTIONS: Array = [SUB_INTERVAL_FATIGUE_EMERGENCY, 2, 3, 4, 5, 6, 7, 10]
const PITCHER_SLOT_INDEX: int = 8

var dh_enabled: bool = false
var team_name_label: Label
var mode_non_dh_button: Button
var mode_dh_button: Button
var status_label: Label
var roster_list: Tree
var lineup_grid: GridContainer
var fielder_usage_grid: GridContainer
var save_button: Button
var auto_lineup_button: Button

var slot_player_buttons: Array = []
var slot_position_buttons: Array = []
var slot_player_ids: Array = []
var slot_positions: Array = []
var fielder_records: Array = []
var pitcher_records: Array = []
var rotation_pitcher_id: int = 0
var rotation_pitcher_name: String = "(未定)"
var usage_starter_buttons: Dictionary = {}
var usage_sub_buttons: Dictionary = {}
var usage_interval_buttons: Dictionary = {}


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
	title.text = "打順 / 守備位置設定"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	team_name_label = Label.new()
	team_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	team_name_label.add_theme_font_size_override("font_size", 18)
	header.add_child(team_name_label)

	mode_non_dh_button = Button.new()
	mode_non_dh_button.text = "非DHリーグ"
	mode_non_dh_button.toggle_mode = true
	mode_non_dh_button.custom_minimum_size = Vector2(110, 32)
	mode_non_dh_button.pressed.connect(func() -> void: _on_mode_pressed(false))
	header.add_child(mode_non_dh_button)

	mode_dh_button = Button.new()
	mode_dh_button.text = "DHリーグ"
	mode_dh_button.toggle_mode = true
	mode_dh_button.custom_minimum_size = Vector2(100, 32)
	mode_dh_button.pressed.connect(func() -> void: _on_mode_pressed(true))
	header.add_child(mode_dh_button)

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

	# Phase 5: 監督AI任せ (auto_lineup) トグル。ON で Phase 3/4 の日替わり打順/守備テンプレートが
	# 試合ごとに自動適用され、保存済み打順 (team_lineups) は無視される。
	auto_lineup_button = Button.new()
	auto_lineup_button.text = "監督AI任せ"
	auto_lineup_button.toggle_mode = true
	auto_lineup_button.custom_minimum_size = Vector2(120, 32)
	auto_lineup_button.pressed.connect(_on_auto_lineup_toggled)
	header.add_child(auto_lineup_button)

	status_label = Label.new()
	status_label.text = ""
	root.add_child(status_label)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var roster_panel: VBoxContainer = VBoxContainer.new()
	roster_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(roster_panel)

	var roster_title: Label = Label.new()
	roster_title.text = "ロスター (野手)"
	roster_title.add_theme_font_size_override("font_size", 16)
	roster_panel.add_child(roster_title)

	roster_list = SortableTable.new()
	roster_panel.add_child(roster_list)
	roster_list.configure(ROSTER_COLUMNS)
	roster_list.set_default_sort(3, false)

	var editor_scroll: ScrollContainer = ScrollContainer.new()
	editor_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(editor_scroll)

	var editor_panel: VBoxContainer = VBoxContainer.new()
	editor_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_panel.add_theme_constant_override("separation", 8)
	editor_scroll.add_child(editor_panel)

	var editor_title: Label = Label.new()
	editor_title.text = "打順"
	editor_title.add_theme_font_size_override("font_size", 16)
	editor_panel.add_child(editor_title)

	lineup_grid = GridContainer.new()
	lineup_grid.columns = 3
	lineup_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lineup_grid.add_theme_constant_override("h_separation", 8)
	lineup_grid.add_theme_constant_override("v_separation", 4)
	editor_panel.add_child(lineup_grid)

	var usage_title: Label = Label.new()
	usage_title.text = "野手スタメン設定"
	usage_title.add_theme_font_size_override("font_size", 16)
	editor_panel.add_child(usage_title)

	fielder_usage_grid = GridContainer.new()
	fielder_usage_grid.columns = 4
	fielder_usage_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fielder_usage_grid.add_theme_constant_override("h_separation", 8)
	fielder_usage_grid.add_theme_constant_override("v_separation", 4)
	editor_panel.add_child(fielder_usage_grid)

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
	_apply_dh_mode_availability(team)
	mode_non_dh_button.button_pressed = not dh_enabled
	mode_dh_button.button_pressed = dh_enabled
	auto_lineup_button.button_pressed = team.auto_lineup

	_load_roster(team_id)
	_populate_roster_panel()

	if team.auto_lineup:
		var preview: Dictionary = GameSimulator.preview_lineup(season, team_id, dh_enabled)
		if not bool(preview.get("ok", false)):
			_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
			_build_empty_grid()
		else:
			_render_grid(preview)
			_set_status("監督AI任せ ON: 試合ごとに日替わり打順/守備テンプレートが自動適用されます。", false)
	else:
		var lineup: Dictionary = season.get_lineup(team_id, dh_enabled)
		if lineup.is_empty():
			var preview: Dictionary = GameSimulator.preview_lineup(season, team_id, dh_enabled)
			if not bool(preview.get("ok", false)):
				_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
				_build_empty_grid()
				return
			_render_grid(preview)
			_set_status("保存された打順がありません。自動編成を表示しています。", false)
		else:
			_render_grid(lineup)
			_set_status("保存された打順を表示しています (Day %d 更新)" % int(lineup.get("updated_at_day", 0)), false)
	_apply_auto_lineup_state()


func _load_roster(team_id: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		fielder_records = []
		pitcher_records = []
		return

	var records: Array = _active_roster_records(season, team_id, RecordStore.get_team_player_records(team_id, season.year, season.season_number))
	fielder_records = []
	pitcher_records = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitcher_records.append(record)
		else:
			fielder_records.append(record)
	fielder_records.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return record_a.name < record_b.name
	)

	var preview: Dictionary = GameSimulator.preview_lineup(season, team_id, false)
	if bool(preview.get("ok", false)):
		rotation_pitcher_id = int(preview.get("pitcher_id", 0))
		var pitcher_record: PSPlayerSeasonRecord = _find_pitcher(rotation_pitcher_id)
		rotation_pitcher_name = pitcher_record.name if pitcher_record != null else "(未定)"
	else:
		rotation_pitcher_id = 0
		rotation_pitcher_name = "(未定)"


func _apply_dh_mode_availability(team: PSTeam) -> void:
	var central_dh: bool = AppState.is_dh_enabled_for_league("central")
	var pacific_dh: bool = AppState.is_dh_enabled_for_league("pacific")
	var dh_mode_available: bool = central_dh or pacific_dh
	var non_dh_mode_available: bool = not central_dh or not pacific_dh

	mode_dh_button.visible = dh_mode_available
	mode_non_dh_button.visible = non_dh_mode_available

	if not dh_mode_available:
		dh_enabled = false
	elif not non_dh_mode_available:
		dh_enabled = true
	elif team != null:
		dh_enabled = AppState.is_dh_enabled_for_league(team.league)


func _find_pitcher(pitcher_id: int) -> PSPlayerSeasonRecord:
	for record_row in pitcher_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == pitcher_id:
			return record
	return null


func _active_roster_records(season: PSSeason, team_id: int, records: Array) -> Array:
	var active_ids: Dictionary = {}
	var roster: Dictionary = season.get_active_roster(team_id)
	var active_id_rows: Array = roster.get("player_ids", []) as Array
	if active_id_rows.is_empty():
		var preview: Dictionary = GameSimulator.preview_active_roster(season, team_id)
		if bool(preview.get("ok", false)):
			active_id_rows = preview.get("player_ids", []) as Array
	for id_value in active_id_rows:
		active_ids[int(id_value)] = true
	if active_ids.is_empty():
		return records
	var filtered: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_ids.has(record.player_id):
			filtered.append(record)
	return filtered


func _populate_roster_panel() -> void:
	var rows: Array = []
	for record_row in fielder_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var aptitude_parts: Array = []
		for position in [2, 3, 4, 5, 6, 7, 8, 9]:
			var apt: int = _position_aptitude(record, position)
			if apt > 0:
				aptitude_parts.append("%s%d" % [_short_position_name(position), apt])
		var aptitude_text: String = " / ".join(aptitude_parts) if not aptitude_parts.is_empty() else "適性無し"
		rows.append({
			"name": record.name,
			"pos": str(PSPlayer.POSITION_NAMES.get(record.position, "?")),
			"apt": aptitude_text,
			"eval": PlayerValueEvaluator.overall_score(record),
			"bat": PlayerValueEvaluator.batting_score(record),
			"note": "怪我%d日" % record.injury_days if record.injury_days > 0 else "",
		})
	roster_list.set_rows(rows)


func _populate_fielder_usage_panel() -> void:
	for child in fielder_usage_grid.get_children():
		fielder_usage_grid.remove_child(child)
		child.queue_free()
	usage_starter_buttons = {}
	usage_sub_buttons = {}
	usage_interval_buttons = {}

	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	var usage: Dictionary = season.get_fielder_usage(team_id) if season != null and team_id > 0 else {}
	var position_slots: Dictionary = usage.get("position_slots", {}) as Dictionary
	var lineup_starters: Dictionary = _lineup_starter_id_by_position()
	var lineup_starter_ids: Dictionary = _lineup_starter_id_set(lineup_starters)

	_add_usage_header("守備", fielder_usage_grid)
	_add_usage_header("スタメン", fielder_usage_grid)
	_add_usage_header("サブ", fielder_usage_grid)
	_add_usage_header("頻度", fielder_usage_grid)

	for position_row in FIELDER_USAGE_POSITIONS:
		var position: int = int(position_row)
		var slot: Dictionary = _usage_slot(position_slots, position)
		var starter_id: int = int(lineup_starters.get(position, int(slot.get("starter_id", 0))))
		var pos_label: Label = Label.new()
		pos_label.text = str(PSPlayer.POSITION_NAMES.get(position, "?"))
		pos_label.custom_minimum_size = Vector2(48, 28)
		fielder_usage_grid.add_child(pos_label)

		var starter_button: OptionButton = OptionButton.new()
		starter_button.custom_minimum_size = Vector2(180, 28)
		_populate_usage_player_options(starter_button, position, starter_id)
		starter_button.disabled = true
		fielder_usage_grid.add_child(starter_button)
		usage_starter_buttons[position] = starter_button

		var sub_button: OptionButton = OptionButton.new()
		sub_button.custom_minimum_size = Vector2(180, 28)
		_populate_usage_player_options(sub_button, position, int(slot.get("sub_id", 0)), lineup_starter_ids)
		fielder_usage_grid.add_child(sub_button)
		usage_sub_buttons[position] = sub_button

		var interval_button: OptionButton = OptionButton.new()
		interval_button.custom_minimum_size = Vector2(110, 28)
		_populate_interval_options(interval_button, int(slot.get("sub_start_interval", 0)))
		fielder_usage_grid.add_child(interval_button)
		usage_interval_buttons[position] = interval_button


func _refresh_fielder_usage_panel() -> void:
	_populate_fielder_usage_panel()
	_import_current_lineup_to_usage_buttons()


func _import_current_lineup_to_usage_buttons() -> void:
	var starter_by_position: Dictionary = _lineup_starter_id_by_position()
	var lineup_starter_ids: Dictionary = _lineup_starter_id_set(starter_by_position)
	for position_value in starter_by_position.keys():
		var position: int = int(position_value)
		var starter_id: int = int(starter_by_position[position_value])
		var starter_button: OptionButton = usage_starter_buttons.get(position, null) as OptionButton
		if starter_button == null:
			continue
		_select_option_by_id(starter_button, starter_id)
		starter_button.disabled = true
		var sub_button: OptionButton = usage_sub_buttons.get(position, null) as OptionButton
		if sub_button != null:
			var current_sub_id: int = sub_button.get_selected_id()
			if lineup_starter_ids.has(current_sub_id):
				current_sub_id = 0
			_populate_usage_player_options(sub_button, position, current_sub_id, lineup_starter_ids)


func _lineup_starter_id_by_position() -> Dictionary:
	var starter_by_position: Dictionary = {}
	for i in range(slot_positions.size()):
		var position: int = int(slot_positions[i])
		var player_id: int = int(slot_player_ids[i])
		if position >= 2 and position <= 9 and player_id > 0:
			starter_by_position[position] = player_id
	return starter_by_position


func _lineup_starter_id_set(starter_by_position: Dictionary) -> Dictionary:
	var starter_ids: Dictionary = {}
	for starter_id_value in starter_by_position.values():
		var starter_id: int = int(starter_id_value)
		if starter_id > 0:
			starter_ids[starter_id] = true
	return starter_ids


func _select_option_by_id(button: OptionButton, item_id: int) -> void:
	for i in range(button.item_count):
		if button.get_item_id(i) == item_id:
			button.select(i)
			return


func _add_usage_header(text: String, grid: GridContainer) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	grid.add_child(label)


func _usage_slot(position_slots: Dictionary, position: int) -> Dictionary:
	var key: String = str(position)
	if position_slots.has(key):
		return position_slots.get(key, {}) as Dictionary
	if position_slots.has(position):
		return position_slots.get(position, {}) as Dictionary
	return {}


func _populate_usage_player_options(button: OptionButton, position: int, current_player_id: int, excluded_player_ids: Dictionary = {}) -> void:
	button.clear()
	button.add_item("(自動)", 0)
	var select_index: int = 0
	var option_index: int = 1
	for record_row in fielder_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if excluded_player_ids.has(record.player_id):
			continue
		var aptitude: int = _position_aptitude(record, position)
		if aptitude <= 0:
			continue
		var label: String = "%s (適%d 評%d)" % [
			record.name,
			aptitude,
			PlayerValueEvaluator.overall_score(record),
		]
		if record.injury_days > 0:
			label += " [怪我%d日]" % record.injury_days
		button.add_item(label, record.player_id)
		if record.player_id == current_player_id:
			select_index = option_index
		option_index += 1
	button.select(select_index)


func _populate_interval_options(button: OptionButton, current_interval: int) -> void:
	button.clear()
	var select_index: int = 0
	for i in range(SUB_INTERVAL_OPTIONS.size()):
		var interval: int = int(SUB_INTERVAL_OPTIONS[i])
		var label: String = "疲労・緊急時" if interval < 0 else "%d試合に1回" % interval
		button.add_item(label, interval)
		if interval == current_interval:
			select_index = i
	button.select(select_index)


func _build_empty_grid() -> void:
	for child in lineup_grid.get_children():
		lineup_grid.remove_child(child)
		child.queue_free()
	slot_player_buttons = []
	slot_position_buttons = []
	slot_player_ids = []
	slot_positions = []


func _render_grid(lineup: Dictionary) -> void:
	_build_empty_grid()

	var batting_order: Array = lineup.get("batting_order", []) as Array
	var slot_data: Array = []
	for _i in range(9):
		slot_data.append({"position": 0, "player_id": 0})

	for entry_row in batting_order:
		var entry: Dictionary = entry_row as Dictionary
		var slot_index: int = int(entry.get("slot", 0)) - 1
		if slot_index < 0 or slot_index >= 9:
			continue
		slot_data[slot_index] = {
			"position": int(entry.get("position", 0)),
			"player_id": int(entry.get("player_id", 0)),
		}

	_add_header_row()

	for i in range(9):
		slot_player_ids.append(0)
		slot_positions.append(0)
		_add_slot_row(i, slot_data[i])
	_refresh_fielder_usage_panel()


func _add_header_row() -> void:
	var header_slot: Label = Label.new()
	header_slot.text = "順"
	header_slot.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	lineup_grid.add_child(header_slot)
	var header_player: Label = Label.new()
	header_player.text = "選手"
	header_player.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	lineup_grid.add_child(header_player)
	var header_pos: Label = Label.new()
	header_pos.text = "守備"
	header_pos.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	lineup_grid.add_child(header_pos)


func _add_slot_row(slot_index: int, slot_data: Dictionary) -> void:
	var slot_label: Label = Label.new()
	slot_label.text = "%d" % (slot_index + 1)
	slot_label.custom_minimum_size = Vector2(28, 28)
	lineup_grid.add_child(slot_label)

	var is_fixed_pitcher_slot: bool = (not dh_enabled) and slot_index == PITCHER_SLOT_INDEX

	if is_fixed_pitcher_slot:
		var fixed_player_label: Label = Label.new()
		fixed_player_label.text = "(ローテ): %s" % rotation_pitcher_name
		fixed_player_label.custom_minimum_size = Vector2(240, 28)
		fixed_player_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		lineup_grid.add_child(fixed_player_label)
		slot_player_buttons.append(null)

		var fixed_position_label: Label = Label.new()
		fixed_position_label.text = "投手"
		fixed_position_label.custom_minimum_size = Vector2(160, 28)
		fixed_position_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		lineup_grid.add_child(fixed_position_label)
		slot_position_buttons.append(null)

		slot_player_ids[slot_index] = 0
		slot_positions[slot_index] = 1
		return

	var player_button: OptionButton = OptionButton.new()
	player_button.custom_minimum_size = Vector2(240, 28)
	_populate_player_options(player_button, slot_data["player_id"])
	player_button.item_selected.connect(func(_index: int) -> void: _on_player_changed(slot_index))
	lineup_grid.add_child(player_button)
	slot_player_buttons.append(player_button)

	var position_button: OptionButton = OptionButton.new()
	position_button.custom_minimum_size = Vector2(160, 28)
	_populate_position_options(position_button, slot_data["player_id"], slot_data["position"])
	position_button.item_selected.connect(func(_index: int) -> void: _on_position_changed(slot_index))
	lineup_grid.add_child(position_button)
	slot_position_buttons.append(position_button)

	slot_player_ids[slot_index] = int(slot_data["player_id"])
	slot_positions[slot_index] = int(slot_data["position"])


func _populate_player_options(button: OptionButton, current_player_id: int) -> void:
	button.clear()
	button.add_item("(自動)", 0)
	var select_index: int = 0
	for i in range(fielder_records.size()):
		var record: PSPlayerSeasonRecord = fielder_records[i] as PSPlayerSeasonRecord
		var label: String = "%s (%s Eval%d Bat%d)" % [
			record.name,
			str(PSPlayer.POSITION_NAMES.get(record.position, "?")),
			PlayerValueEvaluator.overall_score(record),
			PlayerValueEvaluator.batting_score(record),
		]
		if record.injury_days > 0:
			label += " [怪我%d日]" % record.injury_days
		button.add_item(label, record.player_id)
		if record.player_id == current_player_id:
			select_index = i + 1
	if button.item_count > 0:
		button.select(select_index)


func _populate_position_options(button: OptionButton, player_id: int, current_position: int) -> void:
	button.clear()
	button.add_item("(自動)", 0)
	var allowed: Array = DH_FIELDING_POSITIONS if dh_enabled else NON_DH_FIELDING_POSITIONS
	var record: PSPlayerSeasonRecord = _find_fielder(player_id)
	var select_index: int = 0
	for i in range(allowed.size()):
		var position: int = int(allowed[i])
		var label: String = str(PSPlayer.POSITION_NAMES.get(position, "?"))
		if record != null and position >= 2 and position <= 9:
			label = "%s (適性%d)" % [label, _position_aptitude(record, position)]
			label = "%s Def%d" % [label, PlayerValueEvaluator.defensive_score_for_position(record, position)]
		button.add_item(label, position)
		if position == current_position:
			select_index = i + 1
	if button.item_count > 0:
		button.select(select_index)


func _find_fielder(player_id: int) -> PSPlayerSeasonRecord:
	if player_id <= 0:
		return null
	for record_row in fielder_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record
	return null


func _on_player_changed(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= slot_player_buttons.size():
		return
	var player_button: OptionButton = slot_player_buttons[slot_index] as OptionButton
	var position_button: OptionButton = slot_position_buttons[slot_index] as OptionButton
	if player_button == null or position_button == null:
		return
	var new_player_id: int = player_button.get_selected_id()
	slot_player_ids[slot_index] = new_player_id
	if new_player_id > 0:
		_clear_player_from_other_slots(new_player_id, slot_index)
	var current_position: int = position_button.get_selected_id()
	var record: PSPlayerSeasonRecord = _find_fielder(new_player_id)
	var preferred_position: int = current_position
	if record != null:
		preferred_position = _suggest_position_for_player(record, current_position)
	_populate_position_options(position_button, new_player_id, preferred_position)
	slot_positions[slot_index] = position_button.get_selected_id()
	_import_current_lineup_to_usage_buttons()


func _clear_player_from_other_slots(player_id: int, exclude_slot: int) -> void:
	for i in range(slot_player_ids.size()):
		if i == exclude_slot:
			continue
		if int(slot_player_ids[i]) != player_id:
			continue
		slot_player_ids[i] = 0
		var other_button: OptionButton = slot_player_buttons[i] as OptionButton
		if other_button != null:
			other_button.select(0)
		var other_position_button: OptionButton = slot_position_buttons[i] as OptionButton
		if other_position_button != null:
			_populate_position_options(other_position_button, 0, int(slot_positions[i]))
			slot_positions[i] = other_position_button.get_selected_id()


func _clear_position_from_other_slots(position: int, exclude_slot: int) -> void:
	for i in range(slot_positions.size()):
		if i == exclude_slot:
			continue
		if int(slot_positions[i]) != position:
			continue
		slot_positions[i] = 0
		var other_button: OptionButton = slot_position_buttons[i] as OptionButton
		if other_button != null:
			other_button.select(0)


func _suggest_position_for_player(record: PSPlayerSeasonRecord, current_position: int) -> int:
	if current_position == 10:
		return current_position
	if current_position >= 2 and current_position <= 9 and _position_aptitude(record, current_position) > 0:
		return current_position
	if record.position >= 2 and record.position <= 9:
		return record.position
	var best_position: int = 0
	var best_apt: int = 0
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var apt: int = _position_aptitude(record, position)
		if apt > best_apt:
			best_apt = apt
			best_position = position
	return best_position if best_position > 0 else current_position


func _on_position_changed(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= slot_position_buttons.size():
		return
	var position_button: OptionButton = slot_position_buttons[slot_index] as OptionButton
	if position_button == null:
		return
	var new_position: int = position_button.get_selected_id()
	slot_positions[slot_index] = new_position
	if new_position > 0:
		_clear_position_from_other_slots(new_position, slot_index)
	_import_current_lineup_to_usage_buttons()


func _on_mode_pressed(new_mode: bool) -> void:
	if (new_mode and not mode_dh_button.visible) or (not new_mode and not mode_non_dh_button.visible):
		mode_non_dh_button.button_pressed = not dh_enabled
		mode_dh_button.button_pressed = dh_enabled
		return
	if new_mode == dh_enabled:
		mode_non_dh_button.button_pressed = not dh_enabled
		mode_dh_button.button_pressed = dh_enabled
		return
	dh_enabled = new_mode
	_load_initial_state()


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_lineup(season, team_id, dh_enabled)
	if not bool(preview.get("ok", false)):
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		return
	_render_grid(preview)
	_apply_auto_lineup_state()
	_set_status("自動編成を表示中 (未保存)", false)


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
		return

	var team: PSTeam = GameDb.get_team(team_id)
	var usage: Dictionary = _collect_fielder_usage()
	var usage_errors: Array = _validate_fielder_usage(usage)
	if not usage_errors.is_empty():
		_set_status("野手起用設定の保存失敗: %s" % " / ".join(usage_errors), true)
		return

	season.set_fielder_usage(team_id, usage)

	if team != null and team.auto_lineup:
		SaveService.save_state(AppState)
		_set_status("野手起用設定を保存しました (Day %d)" % season.current_day, false)
		return

	var lineup: Dictionary = _collect_lineup()
	var errors: Array = _validate(lineup)
	if not errors.is_empty():
		_set_status("保存失敗: %s" % " / ".join(errors), true)
		return

	season.set_lineup(team_id, dh_enabled, lineup)
	SaveService.save_state(AppState)
	_set_status("保存しました (Day %d)" % season.current_day, false)


# Phase 5: 監督AI任せトグルのハンドラ。
# ON で team.auto_lineup=true + 永続化 → build_team_setup が saved を無視して
# Phase 3/4 サービス (日替わり打順 + 守備テンプレート) を毎試合呼ぶ。
# OFF で従来通り手動編集 + season.set_lineup 保存を行う。
func _on_auto_lineup_toggled() -> void:
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		return
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		auto_lineup_button.button_pressed = false
		return
	team.auto_lineup = auto_lineup_button.button_pressed
	SaveService.save_state(AppState)
	_load_initial_state()


func _apply_auto_lineup_state() -> void:
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		return
	var team: PSTeam = GameDb.get_team(team_id)
	var auto: bool = team != null and team.auto_lineup
	# auto ON 時は手動編集系をすべて disable
	save_button.disabled = false
	if roster_list != null:
		roster_list.modulate = Color(1, 1, 1, 0.5) if auto else Color(1, 1, 1, 1)
	for btn_row in slot_player_buttons:
		if btn_row != null:
			(btn_row as OptionButton).disabled = auto
	for btn_row in slot_position_buttons:
		if btn_row != null:
			(btn_row as OptionButton).disabled = auto


func _collect_fielder_usage() -> Dictionary:
	var position_slots: Dictionary = {}
	var lineup_starters: Dictionary = _lineup_starter_id_by_position()
	for position_row in FIELDER_USAGE_POSITIONS:
		var position: int = int(position_row)
		var starter_button: OptionButton = usage_starter_buttons.get(position, null) as OptionButton
		var sub_button: OptionButton = usage_sub_buttons.get(position, null) as OptionButton
		var interval_button: OptionButton = usage_interval_buttons.get(position, null) as OptionButton
		var starter_id: int = int(lineup_starters.get(position, 0))
		if starter_id <= 0 and starter_button != null:
			starter_id = starter_button.get_selected_id()
		var sub_id: int = 0 if sub_button == null else sub_button.get_selected_id()
		var interval: int = 0 if interval_button == null else interval_button.get_selected_id()
		if starter_id > 0 or sub_id > 0 or interval != 0:
			position_slots[str(position)] = {
				"starter_id": starter_id,
				"sub_id": sub_id,
				"sub_start_interval": interval,
			}

	return {
		"position_slots": position_slots,
	}


func _validate_fielder_usage(usage: Dictionary) -> Array:
	var errors: Array = []
	var position_slots: Dictionary = usage.get("position_slots", {}) as Dictionary
	var starter_ids: Dictionary = {}
	for position_row in FIELDER_USAGE_POSITIONS:
		var position: int = int(position_row)
		var slot: Dictionary = _usage_slot(position_slots, position)
		var starter_id: int = int(slot.get("starter_id", 0))
		if starter_id > 0:
			starter_ids[starter_id] = true
	var starter_seen: Dictionary = {}
	for position_row in FIELDER_USAGE_POSITIONS:
		var position: int = int(position_row)
		var slot: Dictionary = _usage_slot(position_slots, position)
		if slot.is_empty():
			continue
		var starter_id: int = int(slot.get("starter_id", 0))
		var sub_id: int = int(slot.get("sub_id", 0))
		var interval: int = int(slot.get("sub_start_interval", 0))
		if starter_id > 0:
			var starter: PSPlayerSeasonRecord = _find_fielder(starter_id)
			if starter == null or _position_aptitude(starter, position) <= 0:
				errors.append("%sのスタメン適性がありません" % str(PSPlayer.POSITION_NAMES.get(position, "?")))
			if starter_seen.has(starter_id):
				errors.append("%sが複数ポジションのスタメンです" % _player_name(starter_id))
			starter_seen[starter_id] = true
		if sub_id > 0:
			var sub: PSPlayerSeasonRecord = _find_fielder(sub_id)
			if sub == null or _position_aptitude(sub, position) <= 0:
				errors.append("%sのサブ適性がありません" % str(PSPlayer.POSITION_NAMES.get(position, "?")))
		if starter_id > 0 and starter_id == sub_id:
			errors.append("%sのスタメンとサブが同じ選手です" % str(PSPlayer.POSITION_NAMES.get(position, "?")))
		elif sub_id > 0 and starter_ids.has(sub_id):
			errors.append("%sはスタメン選手なのでサブに設定できません" % _player_name(sub_id))
		if interval != 0 and sub_id <= 0:
			errors.append("%sの頻度設定にサブ選手が必要です" % str(PSPlayer.POSITION_NAMES.get(position, "?")))
	return errors


func _collect_lineup() -> Dictionary:
	var batting_order: Array = []
	for i in range(9):
		var position: int = int(slot_positions[i])
		var player_id: int = int(slot_player_ids[i])
		if not dh_enabled and i == PITCHER_SLOT_INDEX:
			position = 1
			player_id = 0
		batting_order.append({
			"slot": i + 1,
			"position": position,
			"player_id": player_id,
		})
	return {"batting_order": batting_order}


func _validate(lineup: Dictionary) -> Array:
	var errors: Array = []
	var batting_order: Array = lineup.get("batting_order", []) as Array
	var positions_seen: Dictionary = {}
	var players_seen: Dictionary = {}
	var dh_slot_count: int = 0

	for entry_row in batting_order:
		var entry: Dictionary = entry_row as Dictionary
		var position: int = int(entry.get("position", 0))
		var player_id: int = int(entry.get("player_id", 0))

		if position == 1:
			continue

		if positions_seen.has(position):
			errors.append("ポジション %s が重複しています" % str(PSPlayer.POSITION_NAMES.get(position, "?")))
		positions_seen[position] = true

		if position == 10:
			dh_slot_count += 1
		if player_id > 0:
			if players_seen.has(player_id):
				errors.append("選手 %s が複数スロットに含まれています" % _player_name(player_id))
			players_seen[player_id] = true

	if dh_enabled and dh_slot_count != 1:
		errors.append("DHスロットが%d個あります (1個必要)" % dh_slot_count)

	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		if not positions_seen.has(position):
			errors.append("守備位置 %s が含まれていません" % str(PSPlayer.POSITION_NAMES.get(position, "?")))

	return errors


func _player_name(player_id: int) -> String:
	var record: PSPlayerSeasonRecord = _find_fielder(player_id)
	if record == null:
		return "ID %d" % player_id
	return record.name


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	else:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))


func _position_aptitude(record: PSPlayerSeasonRecord, position: int) -> int:
	var key: String = str(POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == position else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


func _short_position_name(position: int) -> String:
	match position:
		1: return "投"
		2: return "捕"
		3: return "一"
		4: return "二"
		5: return "三"
		6: return "遊"
		7: return "左"
		8: return "中"
		9: return "右"
		10: return "DH"
		_: return "?"
