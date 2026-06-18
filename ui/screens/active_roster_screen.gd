extends Control

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

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
# roadmap #3: 育成選手リスト + 支配下登録 (昇格)。
var development_list: Tree
var development_title: Label
var promote_to_shienka_button: Button

var all_records: Array = []
var active_ids: Dictionary = {}
# 当チームの育成選手 (live GameDb.players が正準)。{player_id: PSPlayer}
var development_players: Array = []


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

	var columns: HBoxContainer = HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 8)
	root.add_child(columns)

	columns.add_child(_build_active_panel())
	columns.add_child(_build_inactive_panel())
	columns.add_child(_build_development_panel())

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


func _build_development_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	development_title = Label.new()
	development_title.add_theme_font_size_override("font_size", 16)
	panel.add_child(development_title)

	development_list = SortableTable.new()
	panel.add_child(development_list)
	development_list.configure(ROSTER_COLUMNS)
	development_list.set_default_sort(3, false)
	development_list.row_activated.connect(func(meta: Variant) -> void: _promote_to_shienka(int(meta)))

	promote_to_shienka_button = Button.new()
	promote_to_shienka_button.text = "支配下登録 ↑"
	promote_to_shienka_button.custom_minimum_size = Vector2(140, 32)
	promote_to_shienka_button.pressed.connect(_on_promote_to_shienka_pressed)
	panel.add_child(promote_to_shienka_button)
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

	# roadmap #3: 育成選手は live GameDb.players が正準 (新人は記録が未生成のことがある)。
	development_players = []
	for player_row in GameDb.players:
		var dev: PSPlayer = player_row as PSPlayer
		if dev == null or dev.team_id != team_id:
			continue
		if dev.is_retired():
			continue
		if dev.development_player:
			development_players.append(dev)
	development_players.sort_custom(func(a, b) -> bool:
		return Offseason.player_value_score(a as PSPlayer) > Offseason.player_value_score(b as PSPlayer)
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
		status_text = "保存されたロスターを表示しています (%s 更新)" % SeasonCalendar.day_status_label(season, int(saved.get("updated_at_day", 0)))

	for id_value in initial_ids:
		active_ids[int(id_value)] = true

	_render_lists()
	_set_status(status_text, false)


func _render_lists() -> void:
	var dev_id_set: Dictionary = {}
	for dev_row in development_players:
		dev_id_set[(dev_row as PSPlayer).id] = true

	var active_rows: Array = []
	var inactive_rows: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		# 育成選手は 1軍/2軍 ではなく育成リストへ (一軍登録不可)。
		if dev_id_set.has(record.player_id):
			continue
		if active_ids.has(record.player_id):
			active_rows.append(_player_row(record))
		else:
			inactive_rows.append(_player_row(record))

	var development_rows: Array = []
	for dev_row in development_players:
		development_rows.append(_development_row(dev_row as PSPlayer))

	active_list.set_rows(active_rows)
	inactive_list.set_rows(inactive_rows)
	development_list.set_rows(development_rows)

	_update_summary()


# 育成リストの行 (live PSPlayer から構築)。
func _development_row(player: PSPlayer) -> Dictionary:
	var role_label: String
	if player.is_pitcher():
		role_label = _pitcher_role_label(player.role)
	else:
		role_label = str(PSPlayer.POSITION_NAMES.get(player.position, "?"))
	var note_parts: Array = []
	if player.foreign_player:
		note_parts.append("外")
	if player.injury_days > 0:
		note_parts.append("怪我%d日" % player.injury_days)
	return {
		"role": role_label,
		"name": player.name,
		"age": player.age,
		"eval": Offseason.player_value_score(player),
		"note": " ".join(note_parts),
		"__meta": player.id,
	}


func _player_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var role_label: String
	if record.is_pitcher():
		role_label = _pitcher_role_label(record.role)
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

	var dev_count: int = development_players.size()
	var shienka_total: int = TeamFinance.shienka_count(GameDb.players, AppState.selected_team_id)
	# 2軍 = 育成でなく 1軍登録もされていない記録持ち選手 (育成は記録未生成のことがあるため引き算しない)。
	var dev_id_set: Dictionary = {}
	for dev_row in development_players:
		dev_id_set[(dev_row as PSPlayer).id] = true
	var inactive_count: int = 0
	for record_row in all_records:
		var rec: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if dev_id_set.has(rec.player_id):
			continue
		if not active_ids.has(rec.player_id):
			inactive_count += 1
	active_title.text = "1軍 (%d/%d)" % [total, ROSTER_MAX]
	inactive_title.text = "2軍 (%d人)" % inactive_count
	if development_title != null:
		development_title.text = "育成 (%d人) 支配下 %d/%d" % [dev_count, shienka_total, TeamFinance.SHIENKA_LIMIT]

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


func _pitcher_role_label(role: String) -> String:
	match role:
		"starter":
			return "先発"
		"reliever":
			return "中継"
		"closer":
			return "抑え"
		_:
			return "中継"


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


func _on_promote_to_shienka_pressed() -> void:
	var meta: Variant = development_list.get_selected_meta()
	if meta == null:
		_set_status("育成リストから選手を選択してください", true)
		return
	_promote_to_shienka(int(meta))


# roadmap #3: 育成 → 支配下 昇格。支配下枠 (70) を 1 消費する。即時保存。
func _promote_to_shienka(player_id: int) -> void:
	var team_id: int = AppState.selected_team_id
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null or not player.development_player or player.team_id != team_id:
		return
	if not TeamFinance.has_shienka_room(GameDb.players, team_id):
		_set_status("支配下枠が満杯です (最大%d人)。先に支配下選手を整理してください" % TeamFinance.SHIENKA_LIMIT, true)
		return
	player.development_player = false
	player.registered_roster = "支配下"
	# 記録スナップショットがあれば同期 (表示の整合)。
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
		if record != null:
			record.development_player = false
			record.registered_roster = "支配下"
	GameDb.rebuild_player_indices()
	SaveService.save_state(AppState)
	_load_initial_state()
	_set_status("%s を支配下登録しました" % player.name, false)


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
	_set_status("保存しました (%s)" % SeasonCalendar.day_status_label(season, season.current_day), false)


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	else:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))


func _is_catcher(record: PSPlayerSeasonRecord) -> bool:
	return record != null and not record.is_pitcher() and TeamSetupBuilder.position_aptitude(record, 2) > 0
