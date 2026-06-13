extends Control

const WarCalculator = preload("res://services/reports/war_calculator.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")

const LEAGUES: Array = [
	{"key": "central", "label": "第1リーグ"},
	{"key": "pacific", "label": "第2リーグ"},
]

const RANKING_TOP_COUNT: int = 7
const QUALIFIER_PA_PER_DAY: float = 3.1
const QUALIFIER_IP_PER_DAY: float = 1.0
const RANKING_COLUMNS: int = 3
const RANKING_LEAGUE_SEPARATION: int = 12
const RANKING_PANEL_H_SEPARATION: int = 10
const RANKING_PANEL_V_SEPARATION: int = 8

const BATTER_CATEGORIES: Array = [
	{"key": "war",       "label": "WAR",    "min_pa": false},
	{"key": "average",   "label": "打率",   "min_pa": true},
	{"key": "home_runs", "label": "本塁打", "min_pa": false},
	{"key": "rbi",       "label": "打点",   "min_pa": false},
	{"key": "ops",       "label": "OPS",    "min_pa": true},
	{"key": "hits",      "label": "安打",   "min_pa": false},
	{"key": "woba",      "label": "wOBA",   "min_pa": true},
	{"key": "wrc_plus",  "label": "wRC+",   "min_pa": true},
	{"key": "stolen",    "label": "盗塁",   "min_pa": false},
]

const PITCHER_CATEGORIES: Array = [
	{"key": "war",        "label": "WAR",    "min_ip": false},
	{"key": "wins",       "label": "勝利",   "min_ip": false},
	{"key": "era",        "label": "防御率", "min_ip": true,  "ascending": true},
	{"key": "strikeouts", "label": "奪三振", "min_ip": false},
	{"key": "fip",        "label": "FIP",    "min_ip": true,  "ascending": true},
	{"key": "saves",      "label": "セーブ", "min_ip": false},
	{"key": "holds",      "label": "ホールド", "min_ip": false},
	{"key": "k9",         "label": "K/9",    "min_ip": true},
	{"key": "woba_allowed", "label": "wOBAA", "min_ip": true, "ascending": true},
]

# WAR 集計は全選手集計のため refresh 単位で 1 度だけ実施。リーグ context を共有。
var _war_ctx_cache: Dictionary = {}

var status_label: Label
var tab_batter_button: Button
var tab_pitcher_button: Button
var batter_container: HBoxContainer
var pitcher_container: HBoxContainer
var show_batters: bool = true


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "成績ランキング"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	tab_batter_button = Button.new()
	tab_batter_button.text = "野手"
	tab_batter_button.toggle_mode = true
	tab_batter_button.custom_minimum_size = Vector2(96, 32)
	tab_batter_button.button_pressed = true
	tab_batter_button.pressed.connect(func() -> void: _on_tab_pressed(true))
	header.add_child(tab_batter_button)

	tab_pitcher_button = Button.new()
	tab_pitcher_button.text = "投手"
	tab_pitcher_button.toggle_mode = true
	tab_pitcher_button.custom_minimum_size = Vector2(96, 32)
	tab_pitcher_button.pressed.connect(func() -> void: _on_tab_pressed(false))
	header.add_child(tab_pitcher_button)

	var refresh_button: Button = Button.new()
	refresh_button.text = "再集計"
	refresh_button.custom_minimum_size = Vector2(80, 32)
	refresh_button.pressed.connect(_refresh)
	header.add_child(refresh_button)

	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	header.add_child(status_label)

	batter_container = HBoxContainer.new()
	batter_container.add_theme_constant_override("separation", RANKING_LEAGUE_SEPARATION)
	batter_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	batter_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(batter_container)

	pitcher_container = HBoxContainer.new()
	pitcher_container.add_theme_constant_override("separation", RANKING_LEAGUE_SEPARATION)
	pitcher_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pitcher_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(pitcher_container)

	_refresh()


func _refresh() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		status_label.text = "シーズンが開始されていません"
		_clear_container(batter_container)
		_clear_container(pitcher_container)
		return

	var qualifier_pa: int = int(max(1, ceil(QUALIFIER_PA_PER_DAY * float(season.current_day))))
	var qualifier_outs: int = int(max(1, ceil(QUALIFIER_IP_PER_DAY * 3.0 * float(season.current_day))))
	status_label.text = "各Top%d  規定打席≥%d  規定投球回≥%s回" % [
		RANKING_TOP_COUNT,
		qualifier_pa,
		_format_innings(qualifier_outs),
	]

	_war_ctx_cache = WarCalculator.build_league_context(season.year, season.season_number)
	var all_records: Array = _collect_records(season)

	_clear_container(batter_container)
	for league_row in LEAGUES:
		var league: Dictionary = league_row as Dictionary
		var key: String = str(league["key"])
		var group: VBoxContainer = _build_ranking_league_group(str(league["label"]))
		batter_container.add_child(group)
		var inner: GridContainer = group.get_meta("inner") as GridContainer
		for category_row in BATTER_CATEGORIES:
			var category: Dictionary = category_row as Dictionary
			inner.add_child(_build_batter_panel(all_records, category, qualifier_pa, key))

	_clear_container(pitcher_container)
	for league_row in LEAGUES:
		var league: Dictionary = league_row as Dictionary
		var key: String = str(league["key"])
		var group: VBoxContainer = _build_ranking_league_group(str(league["label"]))
		pitcher_container.add_child(group)
		var inner: GridContainer = group.get_meta("inner") as GridContainer
		for category_row in PITCHER_CATEGORIES:
			var category: Dictionary = category_row as Dictionary
			inner.add_child(_build_pitcher_panel(all_records, category, qualifier_outs, key))

	batter_container.visible = show_batters
	pitcher_container.visible = not show_batters


func _build_ranking_league_group(label_text: String) -> VBoxContainer:
	var group: VBoxContainer = VBoxContainer.new()
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.size_flags_vertical = Control.SIZE_EXPAND_FILL
	group.add_theme_constant_override("separation", 4)

	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.86))
	group.add_child(label)

	var inner: GridContainer = GridContainer.new()
	inner.columns = RANKING_COLUMNS
	inner.add_theme_constant_override("h_separation", RANKING_PANEL_H_SEPARATION)
	inner.add_theme_constant_override("v_separation", RANKING_PANEL_V_SEPARATION)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	group.add_child(inner)
	group.set_meta("inner", inner)
	return group


func _build_batter_panel(records: Array, category: Dictionary, qualifier_pa: int, league_key: String) -> VBoxContainer:
	var panel: VBoxContainer = _build_panel_shell(str(category["label"]))
	var table: Tree = _build_ranking_table(panel, str(category["label"]))

	var key: String = str(category["key"])
	var require_min_pa: bool = bool(category.get("min_pa", false))
	var entries: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var team: PSTeam = GameDb.get_team(record.team_id)
		if team == null or team.league != league_key:
			continue
		if record.is_pitcher() and record.batter_stats.plate_appearances < 5:
			continue
		if require_min_pa and record.batter_stats.plate_appearances < qualifier_pa:
			continue
		if _batter_metric_uses_record(key):
			if record.is_pitcher():
				continue
			if record.advanced_stats == null or record.advanced_stats.plate_appearances <= 0:
				continue
		var value: float = _record_metric_value(record, key) if _batter_metric_uses_record(key) else _batter_metric_value(record.batter_stats, key)
		entries.append({"record": record, "value": value})

	entries.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["value"]) > float((b as Dictionary)["value"])
	)

	var rows: Array = []
	var shown: int = 0
	for entry_row in entries:
		if shown >= RANKING_TOP_COUNT:
			break
		var entry: Dictionary = entry_row as Dictionary
		var record: PSPlayerSeasonRecord = entry["record"] as PSPlayerSeasonRecord
		var value: float = float(entry["value"])
		if value <= 0.0 and (key == "average" or key == "ops" or key == "woba" or key == "wrc_plus"):
			continue
		rows.append({
			"rank": shown + 1,
			"team": _team_short(record.team_id),
			"name": record.name,
			"val": _format_batter_value(key, value),
			"val_num": value,
			"__meta": record.player_id,
		})
		shown += 1
	table.set_rows(rows)
	return panel


func _build_pitcher_panel(records: Array, category: Dictionary, qualifier_outs: int, league_key: String) -> VBoxContainer:
	var panel: VBoxContainer = _build_panel_shell(str(category["label"]))
	var table: Tree = _build_ranking_table(panel, str(category["label"]))

	var key: String = str(category["key"])
	var require_min_ip: bool = bool(category.get("min_ip", false))
	var ascending: bool = bool(category.get("ascending", false))

	var entries: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var team: PSTeam = GameDb.get_team(record.team_id)
		if team == null or team.league != league_key:
			continue
		if not record.is_pitcher():
			continue
		if record.pitcher_stats.games == 0:
			continue
		if require_min_ip and record.pitcher_stats.outs_pitched < qualifier_outs:
			continue
		if key == "woba_allowed" and (record.advanced_stats == null or record.advanced_stats.woba_denominator <= 0):
			continue
		var value: float = _record_metric_value(record, key) if _pitcher_metric_uses_record(key) else _pitcher_metric_value(record.pitcher_stats, key)
		entries.append({"record": record, "value": value})

	entries.sort_custom(func(a, b) -> bool:
		var av: float = float((a as Dictionary)["value"])
		var bv: float = float((b as Dictionary)["value"])
		if ascending:
			return av < bv
		return av > bv
	)

	var rows: Array = []
	var shown: int = 0
	for entry_row in entries:
		if shown >= RANKING_TOP_COUNT:
			break
		var entry: Dictionary = entry_row as Dictionary
		var record: PSPlayerSeasonRecord = entry["record"] as PSPlayerSeasonRecord
		var value: float = float(entry["value"])
		rows.append({
			"rank": shown + 1,
			"team": _team_short(record.team_id),
			"name": record.name,
			"val": _format_pitcher_value(key, value, record.pitcher_stats),
			"val_num": value,
			"__meta": record.player_id,
		})
		shown += 1
	table.set_rows(rows)
	return panel


func _build_panel_shell(label_text: String) -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 3)

	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 15)
	panel.add_child(label)
	return panel


func _build_ranking_table(parent: Control, value_label: String) -> Tree:
	var table: Tree = SortableTable.new()
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(table)
	table.configure(_ranking_columns(value_label))
	table.set_default_sort(0, true)  # 順位 昇順 (リーダーボード順を維持)
	table.row_activated.connect(func(meta: Variant) -> void:
		if int(meta) > 0:
			AppState.show_player_detail(int(meta))
	)
	return table


func _ranking_columns(value_label: String) -> Array:
	return [
		{"title": "順", "key": "rank", "width": 36, "type": "number", "format": "int"},
		{"title": "球団", "key": "team", "width": 44, "type": "string", "format": "string"},
		{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
		{"title": value_label, "key": "val", "sort_key": "val_num", "width": 68, "type": "number", "format": "string"},
	]


func _on_tab_pressed(new_show_batters: bool) -> void:
	show_batters = new_show_batters
	tab_batter_button.button_pressed = show_batters
	tab_pitcher_button.button_pressed = not show_batters
	batter_container.visible = show_batters
	pitcher_container.visible = not show_batters


func _collect_records(season: PSSeason) -> Array:
	var records: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var team_records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_row in team_records:
			records.append(record_row as PSPlayerSeasonRecord)
	return records


func _batter_metric_value(stats: PSBatterStats, key: String) -> float:
	match key:
		"average": return stats.batting_average()
		"ops": return stats.ops()
		"home_runs": return float(stats.home_runs)
		"rbi": return float(stats.runs_batted_in)
		"hits": return float(stats.hits)
		"stolen": return float(stats.stolen_bases)
		_: return 0.0


func _record_metric_value(record: PSPlayerSeasonRecord, key: String) -> float:
	if key == "war":
		var war_row: Dictionary = WarCalculator.season_war(record, _war_ctx_cache)
		return float(war_row.get("war", 0.0))
	if key == "fip":
		var war_row: Dictionary = WarCalculator.season_war(record, _war_ctx_cache)
		return float(war_row.get("fip", 999.99))
	if record == null or record.advanced_stats == null:
		return 0.0
	match key:
		"woba": return record.advanced_stats.woba()
		"wrc_plus": return record.advanced_stats.wrc_plus()
		"woba_allowed": return record.advanced_stats.woba()
	return 0.0


func _pitcher_metric_value(stats: PSPitcherStats, key: String) -> float:
	match key:
		"wins": return float(stats.wins)
		"era":
			if stats.outs_pitched == 0:
				return 999.99
			return stats.era()
		"strikeouts": return float(stats.strikeouts)
		"saves": return float(stats.saves)
		"holds": return float(stats.holds)
		"k9": return stats.strikeouts_per_nine()
		_: return 0.0


func _format_batter_value(key: String, value: float) -> String:
	match key:
		"average", "ops", "woba":
			return "%0.3f" % value
		"wrc_plus":
			return "%0.1f" % value
		"war":
			return "%+0.2f" % value
		_:
			return "%d" % int(value)


func _format_pitcher_value(key: String, value: float, stats: PSPitcherStats) -> String:
	match key:
		"era", "fip", "k9":
			if stats.outs_pitched == 0:
				return "--"
			return "%0.2f" % value
		"woba_allowed":
			if stats.outs_pitched == 0:
				return "--"
			return "%0.3f" % value
		"war":
			return "%+0.2f" % value
		_:
			return "%d" % int(value)


func _batter_metric_uses_record(key: String) -> bool:
	return key == "war" or key == "woba" or key == "wrc_plus"


func _pitcher_metric_uses_record(key: String) -> bool:
	return key == "war" or key == "fip" or key == "woba_allowed"


func _clear_container(container: Control) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _format_innings(outs: int) -> String:
	@warning_ignore("integer_division")
	return "%d.%d" % [int(outs / 3), outs % 3]
