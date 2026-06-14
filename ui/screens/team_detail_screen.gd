extends Control

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const POSITION_LABELS_WAR: Dictionary = {
	1: "投手", 2: "捕手", 3: "一塁", 4: "二塁", 5: "三塁",
	6: "遊撃", 7: "左翼", 8: "中堅", 9: "右翼",
}

const SortableTable = preload("res://ui/components/sortable_table.gd")

const PITCHER_ROSTER_COLUMNS: Array = [
	{"title": "位置", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 130, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
	{"title": "防", "key": "era", "width": 60, "type": "number", "format": "float2"},
	{"title": "勝", "key": "w", "width": 44, "type": "number", "format": "int"},
	{"title": "敗", "key": "l", "width": 44, "type": "number", "format": "int"},
	{"title": "備考", "key": "note", "width": 96, "type": "string", "format": "string"},
]

const BATTER_ROSTER_COLUMNS: Array = [
	{"title": "位置", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 130, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
	{"title": "打率", "key": "avg", "width": 64, "type": "number", "format": "rate"},
	{"title": "本", "key": "hr", "width": 44, "type": "number", "format": "int"},
	{"title": "点", "key": "rbi", "width": 48, "type": "number", "format": "int"},
	{"title": "備考", "key": "note", "width": 96, "type": "string", "format": "string"},
]

var team_select: OptionButton
var info_label: RichTextLabel
var ratings_label: RichTextLabel
var pitcher_table: Tree
var batter_table: Tree
var team_options: Array = []
var current_team_id: int = 0


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
	title.text = "チーム詳細"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	var team_label: Label = Label.new()
	team_label.text = "チーム"
	header.add_child(team_label)

	team_select = OptionButton.new()
	team_select.custom_minimum_size = Vector2(180, 32)
	team_select.item_selected.connect(func(_index: int) -> void: _refresh())
	header.add_child(team_select)
	header.add_child(Control.new())

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_theme_constant_override("separation", 16)
	root.add_child(top_row)

	info_label = RichTextLabel.new()
	info_label.bbcode_enabled = false
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_label.custom_minimum_size = Vector2(0, 140)
	top_row.add_child(info_label)

	ratings_label = RichTextLabel.new()
	ratings_label.bbcode_enabled = false
	ratings_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ratings_label.custom_minimum_size = Vector2(0, 140)
	top_row.add_child(ratings_label)

	var roster_title: Label = Label.new()
	roster_title.text = "選手一覧 (列見出しクリックでソート / ダブルクリックで詳細)"
	roster_title.add_theme_font_size_override("font_size", 16)
	root.add_child(roster_title)

	var roster_split: HSplitContainer = HSplitContainer.new()
	roster_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(roster_split)

	roster_split.add_child(_build_roster_panel("投手", PITCHER_ROSTER_COLUMNS))
	roster_split.add_child(_build_roster_panel("野手", BATTER_ROSTER_COLUMNS))

	_populate_team_options()
	_refresh()


func _build_roster_panel(title_text: String, columns: Array) -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	var label: Label = Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	panel.add_child(label)
	panel.set_meta("title_label", label)

	var table: Tree = SortableTable.new()
	panel.add_child(table)
	table.configure(columns)
	table.set_default_sort(3, false)  # 評価 降順
	table.row_activated.connect(func(meta: Variant) -> void:
		if int(meta) > 0:
			AppState.show_player_detail(int(meta))
	)
	panel.set_meta("table", table)

	if title_text == "投手":
		pitcher_table = table
	else:
		batter_table = table
	return panel


func _populate_team_options() -> void:
	team_options.clear()
	team_select.clear()
	var default_id: int = AppState.selected_team_id
	var selected_index: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var index: int = team_select.item_count
		team_select.add_item("%s (%s)" % [team.name, team.league_label()], team.id)
		team_options.append(team.id)
		if team.id == default_id:
			selected_index = index
	if team_select.item_count > 0:
		team_select.select(selected_index)


func _refresh() -> void:
	current_team_id = _selected_team_id()
	if current_team_id <= 0:
		info_label.text = ""
		ratings_label.text = ""
		pitcher_table.set_rows([])
		batter_table.set_rows([])
		return

	var team: PSTeam = GameDb.get_team(current_team_id)
	if team == null:
		return
	info_label.text = _format_team_info(team)
	ratings_label.text = _format_team_ratings(team)
	_populate_roster(team.id)


func _selected_team_id() -> int:
	if team_select.item_count == 0:
		return 0
	var idx: int = team_select.selected
	if idx < 0 or idx >= team_options.size():
		return 0
	return int(team_options[idx])


func _format_team_info(team: PSTeam) -> String:
	var lines: Array = []
	lines.append("%s (%s)" % [team.name, team.short_name])
	lines.append("リーグ: %s" % team.league_label())
	lines.append("前年順位: %d位" % team.previous_rank)
	# R4 Step1: 予算 (funds) に対する年俸総額と残枠。超過はソフト警告のみ。
	var payroll: int = TeamFinance.team_payroll(GameDb.players, team.id)
	var over_note: String = "  (予算超過)" if TeamFinance.is_over_budget(team.funds, payroll) else ""
	lines.append("予算: %d万円  年俸総額: %d万円  残枠: %d万円%s" % [
		team.funds, payroll, TeamFinance.budget_room(team.funds, payroll), over_note,
	])
	lines.append("総合評価: %d" % team.overall())

	var season: PSSeason = AppState.current_season
	if season != null and season.standings.has(team.id):
		var stats: PSStats = season.standings[team.id] as PSStats
		lines.append("")
		lines.append("== 今期成績 ==")
		lines.append("試合 %d  %d勝 %d敗 %d分  勝率 %0.3f" % [
			stats.games, stats.wins, stats.losses, stats.draws, stats.win_rate(),
		])
		lines.append("得点 %d  失点 %d  得失点差 %+d" % [
			stats.runs_scored, stats.runs_allowed, stats.runs_scored - stats.runs_allowed,
		])
		lines.append("残り試合: %d" % season.team_games_remaining(team.id))
	return "\n".join(lines)


func _format_team_ratings(team: PSTeam) -> String:
	var lines: Array = []
	lines.append("== チーム評価 ==")
	if team.ratings.is_empty():
		lines.append("評価データなし")
	else:
		var keys: Array = team.ratings.keys()
		keys.sort()
		for key in keys:
			lines.append("%s: %d" % [str(key), int(team.ratings.get(key, 0))])

	var season: PSSeason = AppState.current_season
	if season != null:
		lines.append("")
		lines.append("== 集計指標 ==")
		var metrics: Dictionary = _team_metrics(team.id)
		lines.append("チーム打率: %0.3f" % float(metrics.get("batting_average", 0.0)))
		lines.append("チームOPS: %0.3f" % float(metrics.get("ops", 0.0)))
		lines.append("本塁打: %d  打点: %d" % [int(metrics.get("home_runs", 0)), int(metrics.get("runs_batted_in", 0))])
		var era_str: String = "--"
		if int(metrics.get("outs_pitched", 0)) > 0:
			era_str = "%0.2f" % float(metrics.get("era", 0.0))
		lines.append("防御率: %s  WHIP: %s" % [era_str, _whip_text(metrics)])
		lines.append("奪三振: %d  与四球: %d" % [int(metrics.get("strikeouts", 0)), int(metrics.get("walks_pitched", 0))])

		# ポジション別 WAR (戦力分析) — リーグ平均との差で「穴 / 強み」を可視化
		var war_block: String = _format_team_war_position(team.id)
		if not war_block.is_empty():
			lines.append("")
			lines.append(war_block)
	return "\n".join(lines)


# ポジション別 WAR を「主力 / 合計 / リーグ平均との差 / 穴強み記号」で表示する。
# 全12チームを集計するため初回ロードに数百msかかる。AppState にキャッシュするなら最適化可能。
func _format_team_war_position(team_id: int) -> String:
	var season: PSSeason = AppState.current_season
	if season == null:
		return ""
	var landscape: Dictionary = WarCalculator.build_position_war_landscape(season.year, season.season_number, GameDb.teams)
	var teams_data: Dictionary = landscape.get("teams", {}) as Dictionary
	var my_team: Dictionary = teams_data.get(team_id, {}) as Dictionary
	if my_team.is_empty():
		return ""
	var league_average: Dictionary = landscape.get("league_average", {}) as Dictionary
	var positions: Dictionary = my_team.get("positions", {}) as Dictionary

	var lines: Array = []
	lines.append("== ポジション別WAR (戦力分析) ==")
	lines.append("チーム合計: %+.2f WAR" % float(my_team.get("team_war", 0.0)))
	# 表示順: 投手→捕手→内野→外野
	for pos in [1, 2, 3, 4, 5, 6, 7, 8, 9]:
		var label: String = str(POSITION_LABELS_WAR.get(pos, "?"))
		var bucket: Dictionary = positions.get(pos, {}) as Dictionary
		var avg_bucket: Dictionary = league_average.get(pos, {}) as Dictionary
		var starter: float = float(bucket.get("starter_war", 0.0))
		var total: float = float(bucket.get("war_total", 0.0))
		var league_avg_starter: float = float(avg_bucket.get("starter_war", 0.0))
		var diff: float = starter - league_avg_starter
		var indicator: String = ""
		if diff <= -1.5:
			indicator = "  ★穴"
		elif diff >= 1.5:
			indicator = "  ◎強"
		var n: int = (bucket.get("players", []) as Array).size()
		lines.append("  %s 主力%+5.2f 合計%+5.2f 平均%+5.2f 差%+5.2f (n=%d)%s" % [
			label, starter, total, league_avg_starter, diff, n, indicator,
		])
	return "\n".join(lines)


func _whip_text(metrics: Dictionary) -> String:
	if int(metrics.get("outs_pitched", 0)) <= 0:
		return "--"
	return "%0.2f" % float(metrics.get("whip", 0.0))


func _team_metrics(team_id: int) -> Dictionary:
	var season: PSSeason = AppState.current_season
	if season == null:
		return {}
	var batter_stats: PSBatterStats = PSBatterStats.new()
	var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
	var records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter_stats.add_from(record.batter_stats)
		if record.is_pitcher():
			pitcher_stats.add_from(record.pitcher_stats)
	return {
		"batting_average": batter_stats.batting_average(),
		"ops": batter_stats.ops(),
		"home_runs": batter_stats.home_runs,
		"runs_batted_in": batter_stats.runs_batted_in,
		"era": pitcher_stats.era(),
		"whip": pitcher_stats.whip(),
		"outs_pitched": pitcher_stats.outs_pitched,
		"strikeouts": pitcher_stats.strikeouts,
		"walks_pitched": pitcher_stats.walks,
	}


func _populate_roster(team_id: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		pitcher_table.set_rows([])
		batter_table.set_rows([])
		return
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	var pitcher_rows: Array = []
	var batter_rows: Array = []
	var pitcher_dev: int = 0
	var batter_dev: int = 0
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitcher_rows.append(_pitcher_row(record))
			if record.development_player:
				pitcher_dev += 1
		else:
			batter_rows.append(_batter_row(record))
			if record.development_player:
				batter_dev += 1

	_set_panel_title(pitcher_table, "投手", pitcher_rows.size() - pitcher_dev, pitcher_dev)
	_set_panel_title(batter_table, "野手", batter_rows.size() - batter_dev, batter_dev)
	pitcher_table.set_rows(pitcher_rows)
	batter_table.set_rows(batter_rows)


func _pitcher_row(record: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"pos": str(PSPlayer.POSITION_NAMES.get(record.position, "?")),
		"name": record.name,
		"age": record.age,
		"eval": PlayerValueEvaluator.overall_score(record),
		"era": record.pitcher_stats.era() if record.pitcher_stats.outs_pitched > 0 else 0.0,
		"w": record.pitcher_stats.wins,
		"l": record.pitcher_stats.losses,
		"note": _roster_note(record),
		"__meta": record.player_id,
	}


func _batter_row(record: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"pos": str(PSPlayer.POSITION_NAMES.get(record.position, "?")),
		"name": record.name,
		"age": record.age,
		"eval": PlayerValueEvaluator.overall_score(record),
		"avg": record.batter_stats.batting_average(),
		"hr": record.batter_stats.home_runs,
		"rbi": record.batter_stats.runs_batted_in,
		"note": _roster_note(record),
		"__meta": record.player_id,
	}


func _roster_note(record: PSPlayerSeasonRecord) -> String:
	var parts: Array = []
	if record.development_player:
		parts.append("育成")
	if record.foreign_player:
		parts.append("外")
	if record.injury_days > 0:
		parts.append("怪我%d日" % record.injury_days)
	return " ".join(parts)


func _set_panel_title(table: Tree, base_text: String, shienka: int, development: int) -> void:
	var panel: Node = table.get_parent()
	if panel == null or not panel.has_meta("title_label"):
		return
	var label: Label = panel.get_meta("title_label") as Label
	if label != null:
		label.text = "%s (支配下%d / 育成%d)" % [base_text, shienka, development]
