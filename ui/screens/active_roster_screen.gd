extends Control

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")

const ROSTER_COLUMNS: Array = [
	{"title": "区分", "key": "role", "width": 56, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 130, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
	{"title": "備考", "key": "note", "width": 96, "type": "string", "format": "string"},
]

const ROSTER_MAX: int = 31
const FOREIGN_MAX: int = 4
const TARGET_PITCHERS_MIN: int = 14
const TARGET_PITCHERS_MAX: int = 15
const TARGET_STARTERS: int = 6
const MIN_CATCHERS: int = 2

var team_name_label: Label
var status_label: Label
var summary_label: Label
var auto_swap_checkbox: CheckButton

var active_list: Tree
var inactive_list: Tree
var active_title: Label
var inactive_title: Label
var demote_button: Button
var promote_button: Button

var all_records: Array = []
var active_ids: Dictionary = {}


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
	title.text = "1軍入れ替え"
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

	var perf_auto_button: Button = Button.new()
	perf_auto_button.text = "成績ベース自動編成"
	perf_auto_button.custom_minimum_size = Vector2(160, 32)
	perf_auto_button.pressed.connect(_on_perf_auto_pressed)
	header.add_child(perf_auto_button)

	var reset_button: Button = Button.new()
	reset_button.text = "リセット"
	reset_button.custom_minimum_size = Vector2(80, 32)
	reset_button.pressed.connect(_load_initial_state)
	header.add_child(reset_button)

	var save_button: Button = Button.new()
	save_button.text = "保存"
	save_button.custom_minimum_size = Vector2(80, 32)
	save_button.pressed.connect(_on_save_pressed)
	header.add_child(save_button)

	auto_swap_checkbox = CheckButton.new()
	auto_swap_checkbox.text = "成績ベースで自動的に一二軍入替を行う"
	auto_swap_checkbox.set_pressed_no_signal(AppState.auto_roster_swap_for_user_team)
	auto_swap_checkbox.toggled.connect(_on_auto_swap_checkbox_toggled)
	root.add_child(auto_swap_checkbox)

	summary_label = Label.new()
	summary_label.add_theme_font_size_override("font_size", 14)
	root.add_child(summary_label)

	status_label = Label.new()
	status_label.text = ""
	root.add_child(status_label)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	split.add_child(_build_active_panel())
	split.add_child(_build_inactive_panel())

	_load_initial_state()


func _build_active_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	active_title = Label.new()
	active_title.add_theme_font_size_override("font_size", 16)
	panel.add_child(active_title)

	active_list = SortableTable.new()
	panel.add_child(active_list)
	active_list.configure(ROSTER_COLUMNS)
	active_list.set_default_sort(3, false)
	active_list.row_activated.connect(func(meta: Variant) -> void: _demote(int(meta)))

	demote_button = Button.new()
	demote_button.text = "→ 2軍へ"
	demote_button.custom_minimum_size = Vector2(140, 32)
	demote_button.pressed.connect(_on_demote_pressed)
	panel.add_child(demote_button)
	return panel


func _build_inactive_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	inactive_title = Label.new()
	inactive_title.add_theme_font_size_override("font_size", 16)
	panel.add_child(inactive_title)

	inactive_list = SortableTable.new()
	panel.add_child(inactive_list)
	inactive_list.configure(ROSTER_COLUMNS)
	inactive_list.set_default_sort(3, false)
	inactive_list.row_activated.connect(func(meta: Variant) -> void: _promote(int(meta)))

	promote_button = Button.new()
	promote_button.text = "← 1軍へ"
	promote_button.custom_minimum_size = Vector2(140, 32)
	promote_button.pressed.connect(_on_promote_pressed)
	panel.add_child(promote_button)
	return panel


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

	all_records = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	all_records.sort_custom(func(a, b) -> bool:
		return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
	)

	active_ids = {}
	var saved: Dictionary = season.get_active_roster(team_id)
	var initial_ids: Array = []
	var status_text: String = ""
	if saved.is_empty():
		var preview: Dictionary = GameSimulator.preview_active_roster(season, team_id)
		if not bool(preview.get("ok", false)):
			_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
			_render_lists()
			return
		initial_ids = preview.get("player_ids", []) as Array
		status_text = "保存されたロスターがありません。自動編成を表示しています。"
	else:
		initial_ids = saved.get("player_ids", []) as Array
		status_text = "保存されたロスターを表示しています (Day %d 更新)" % int(saved.get("updated_at_day", 0))

	for id_value in initial_ids:
		active_ids[int(id_value)] = true

	_render_lists()
	_set_status(status_text, false)


func _render_lists() -> void:
	var active_rows: Array = []
	var inactive_rows: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_ids.has(record.player_id):
			active_rows.append(_player_row(record))
		else:
			inactive_rows.append(_player_row(record))

	active_list.set_rows(active_rows)
	inactive_list.set_rows(inactive_rows)

	_update_summary()


func _player_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var role_label: String
	if record.is_pitcher():
		role_label = "先発" if record.role == "starter" else "中継"
	else:
		role_label = str(PSPlayer.POSITION_NAMES.get(record.position, "?"))
	var note_parts: Array = []
	if record.foreign_player:
		note_parts.append("外")
	if record.injury_days > 0:
		note_parts.append("怪我%d日" % record.injury_days)
	return {
		"role": role_label,
		"name": record.name,
		"age": record.age,
		"eval": PlayerValueEvaluator.overall_score(record),
		"note": " ".join(note_parts),
		"__meta": record.player_id,
	}


func _update_summary() -> void:
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(active_ids.keys(), all_records)
	var total: int = int(summary.get("total", 0))
	var pitchers: int = int(summary.get("pitchers", 0))
	var starters: int = int(summary.get("starters", 0))
	var fielders: int = int(summary.get("fielders", 0))
	var catchers: int = int(summary.get("catchers", 0))
	var foreigners: int = int(summary.get("foreigners", 0))

	active_title.text = "1軍 (%d/%d)" % [total, ROSTER_MAX]
	inactive_title.text = "2軍 (%d人)" % (all_records.size() - total)

	var parts: Array = []
	parts.append("人数 %d/%d" % [total, ROSTER_MAX])
	parts.append("投手 %d(先発%d 中継%d)" % [pitchers, starters, pitchers - starters])
	parts.append("野手 %d(捕手%d)" % [fielders, catchers])
	parts.append("外国人 %d/%d" % [foreigners, FOREIGN_MAX])
	summary_label.text = "  ".join(parts)

	var has_violation: bool = total > ROSTER_MAX or foreigners > FOREIGN_MAX
	var has_warning: bool = pitchers < TARGET_PITCHERS_MIN or pitchers > TARGET_PITCHERS_MAX or starters < TARGET_STARTERS or catchers < MIN_CATCHERS
	if has_violation:
		summary_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	elif has_warning:
		summary_label.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
	else:
		summary_label.add_theme_color_override("font_color", Color(0.78, 0.92, 0.78))


func _on_demote_pressed() -> void:
	var meta: Variant = active_list.get_selected_meta()
	if meta == null:
		_set_status("1軍リストから選手を選択してください", true)
		return
	_demote(int(meta))


func _on_promote_pressed() -> void:
	var meta: Variant = inactive_list.get_selected_meta()
	if meta == null:
		_set_status("2軍リストから選手を選択してください", true)
		return
	_promote(int(meta))


func _demote(player_id: int) -> void:
	if not active_ids.has(player_id):
		return
	var record: PSPlayerSeasonRecord = _find_record(player_id)
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(active_ids.keys(), all_records)
	if _is_catcher(record) and int(summary.get("catchers", 0)) <= MIN_CATCHERS:
		_set_status("捕手は1軍に最低%d人必要です" % MIN_CATCHERS, true)
		return
	active_ids.erase(player_id)
	_render_lists()
	_set_status("選手を2軍に移しました", false)


func _promote(player_id: int) -> void:
	if active_ids.has(player_id):
		return
	var record: PSPlayerSeasonRecord = _find_record(player_id)
	if record == null:
		return
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(active_ids.keys(), all_records)
	var total: int = int(summary.get("total", 0))
	var foreigners: int = int(summary.get("foreigners", 0))
	if total >= ROSTER_MAX:
		_set_status("1軍は最大%d人です" % ROSTER_MAX, true)
		return
	if record.foreign_player and foreigners >= FOREIGN_MAX:
		_set_status("外国人枠は最大%d人です" % FOREIGN_MAX, true)
		return
	active_ids[player_id] = true
	_render_lists()
	_set_status("選手を1軍に上げました", false)


func _find_record(player_id: int) -> PSPlayerSeasonRecord:
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record
	return null


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_active_roster(season, team_id)
	if not bool(preview.get("ok", false)):
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		return
	active_ids = {}
	for id_value in (preview.get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	_render_lists()
	_set_status("自動編成を表示中 (未保存)", false)


func _on_perf_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		return
	var preview: Dictionary = TeamAutoAI.preview_perf_based_active_roster(season, team_id)
	if not bool(preview.get("ok", false)):
		_set_status("成績ベース自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		return
	active_ids = {}
	for id_value in (preview.get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	_render_lists()
	_set_status("成績ベース自動編成を表示中 (未保存)", false)


func _on_auto_swap_checkbox_toggled(pressed: bool) -> void:
	AppState.auto_roster_swap_for_user_team = pressed
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if pressed and season != null and team_id > 0:
		# ON にした直後の試合日に発動するよう、直前の週次入替日を current_day - SWAP_INTERVAL_DAYS に巻き戻す
		season.set_last_auto_swap_day(team_id, season.current_day - TeamAutoAI.SWAP_INTERVAL_DAYS)
	SaveService.save_state(AppState)


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	var team_id: int = AppState.selected_team_id
	if season == null or team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
		return

	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(active_ids.keys(), all_records)
	var total: int = int(summary.get("total", 0))
	var foreigners: int = int(summary.get("foreigners", 0))
	var catchers: int = int(summary.get("catchers", 0))
	if total > ROSTER_MAX:
		_set_status("保存失敗: 1軍は最大%d人です(%d人)" % [ROSTER_MAX, total], true)
		return
	if foreigners > FOREIGN_MAX:
		_set_status("保存失敗: 外国人枠は最大%d人です(%d人)" % [FOREIGN_MAX, foreigners], true)
		return

	if catchers < MIN_CATCHERS:
		_set_status("保存失敗: 捕手は1軍に最低%d人必要です (%d人)" % [MIN_CATCHERS, catchers], true)
		return

	var player_ids: Array = []
	for id_value in active_ids.keys():
		player_ids.append(int(id_value))

	season.set_active_roster(team_id, {"player_ids": player_ids})
	GameSimulator.preview_lineup(season, team_id, false)
	SaveService.save_state(AppState)
	_set_status("保存しました (Day %d)" % season.current_day, false)


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	else:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))


func _is_catcher(record: PSPlayerSeasonRecord) -> bool:
	return record != null and not record.is_pitcher() and TeamSetupBuilder.position_aptitude(record, 2) > 0
