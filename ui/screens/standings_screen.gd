extends Control

const SortableTable = preload("res://ui/components/sortable_table.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const LEAGUE_COLUMNS: Array = [
	{"title": "順", "key": "rank", "width": 40, "type": "number", "format": "int"},
	{"title": "球団", "key": "team", "width": 56, "type": "string", "format": "string"},
	{"title": "勝", "key": "w", "width": 44, "type": "number", "format": "int"},
	{"title": "敗", "key": "l", "width": 44, "type": "number", "format": "int"},
	{"title": "分", "key": "d", "width": 40, "type": "number", "format": "int"},
	{"title": "勝率", "key": "pct", "width": 64, "type": "number", "format": "rate"},
	{"title": "GB", "key": "gb", "width": 52, "type": "number", "format": "float1"},
	{"title": "残", "key": "rem", "width": 44, "type": "number", "format": "int"},
	{"title": "得", "key": "rs", "width": 48, "type": "number", "format": "int"},
	{"title": "失", "key": "ra", "width": 48, "type": "number", "format": "int"},
	{"title": "差", "key": "diff", "width": 52, "type": "number", "format": "int"},
	{"title": "打率", "key": "avg", "width": 64, "type": "number", "format": "rate"},
	{"title": "OBP", "key": "obp", "width": 64, "type": "number", "format": "rate"},
	{"title": "SLG", "key": "slg", "width": 64, "type": "number", "format": "rate"},
	{"title": "OPS", "key": "ops", "width": 64, "type": "number", "format": "rate"},
	{"title": "本", "key": "hr", "width": 44, "type": "number", "format": "int"},
	{"title": "盗", "key": "sb", "width": 44, "type": "number", "format": "int"},
	{"title": "三", "key": "so", "width": 48, "type": "number", "format": "int"},
	{"title": "防", "key": "era", "width": 56, "type": "number", "format": "float2"},
	{"title": "WHIP", "key": "whip", "width": 60, "type": "number", "format": "float2"},
	{"title": "K/9", "key": "k9", "width": 56, "type": "number", "format": "float2"},
	{"title": "S", "key": "sv", "width": 40, "type": "number", "format": "int"},
	{"title": "H", "key": "hld", "width": 40, "type": "number", "format": "int"},
	{"title": "QS", "key": "qs", "width": 44, "type": "number", "format": "int"},
]

const LEAGUES: Array = [
	{"key": "central", "label": "第1リーグ"},
	{"key": "pacific", "label": "第2リーグ"},
]

const LEAGUE_TABLE_HEIGHT: int = 220

var status_label: Label
var league_containers: Dictionary = {}


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
	title.text = "順位表"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	header.add_child(status_label)

	for league_row in LEAGUES:
		var league: Dictionary = league_row as Dictionary
		var key: String = str(league["key"])
		var panel: VBoxContainer = _build_league_panel(str(league["label"]))
		root.add_child(panel)
		league_containers[key] = panel

	_refresh()


func _build_league_panel(label_text: String) -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	panel.add_theme_constant_override("separation", 4)

	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)

	var table: Tree = SortableTable.new()
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	table.custom_minimum_size = Vector2(0, LEAGUE_TABLE_HEIGHT)
	panel.add_child(table)
	table.configure(LEAGUE_COLUMNS)
	table.set_default_sort(5, false)  # 勝率 降順
	panel.set_meta("table", table)
	return panel


func _refresh() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		status_label.text = "シーズンが開始されていません"
		for panel_value in league_containers.values():
			var panel: VBoxContainer = panel_value as VBoxContainer
			var table: Tree = panel.get_meta("table") as Tree
			table.set_rows([])
		return

	status_label.text = "%d年 / %d年目  %s  (残り%d試合)" % [
		season.year, season.season_number, SeasonCalendar.day_status_label(season, season.current_day), season.games_remaining(),
	]

	for league_row in LEAGUES:
		var league: Dictionary = league_row as Dictionary
		var key: String = str(league["key"])
		var panel: VBoxContainer = league_containers[key] as VBoxContainer
		var table: Tree = panel.get_meta("table") as Tree
		_populate_league_table(table, key)


func _populate_league_table(table: Tree, league_key: String) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		table.set_rows([])
		return

	var entries: Array = []
	for team_id in season.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id))
		if team == null or team.league != league_key:
			continue
		var stats: PSStats = season.standings[team_id] as PSStats
		entries.append({
			"team": team,
			"stats": stats,
			"metrics": _team_metrics(int(team_id)),
			"remaining": season.team_games_remaining(int(team_id)),
		})

	entries.sort_custom(func(a, b) -> bool:
		var row_a: Dictionary = a as Dictionary
		var row_b: Dictionary = b as Dictionary
		var stats_a: PSStats = row_a["stats"] as PSStats
		var stats_b: PSStats = row_b["stats"] as PSStats
		if stats_a.win_rate() == stats_b.win_rate():
			return stats_a.wins > stats_b.wins
		return stats_a.win_rate() > stats_b.win_rate()
	)

	var leader_stats: PSStats = null
	if not entries.is_empty():
		leader_stats = (entries[0] as Dictionary)["stats"] as PSStats

	var rows: Array = []
	var rank: int = 1
	for row_data in entries:
		var row: Dictionary = row_data as Dictionary
		var team: PSTeam = row["team"] as PSTeam
		var stats: PSStats = row["stats"] as PSStats
		var metrics: Dictionary = row["metrics"] as Dictionary
		var has_pitching: bool = int(metrics.get("outs_pitched", 0)) > 0
		rows.append({
			"rank": rank,
			"team": team.short_name,
			"w": stats.wins,
			"l": stats.losses,
			"d": stats.draws,
			"pct": stats.win_rate(),
			"gb": 0.0 if (rank == 1 or leader_stats == null) else _game_back(leader_stats, stats),
			"rem": int(row["remaining"]),
			"rs": stats.runs_scored,
			"ra": stats.runs_allowed,
			"diff": stats.runs_scored - stats.runs_allowed,
			"avg": float(metrics.get("batting_average", 0.0)),
			"obp": float(metrics.get("on_base_percentage", 0.0)),
			"slg": float(metrics.get("slugging_percentage", 0.0)),
			"ops": float(metrics.get("ops", 0.0)),
			"hr": int(metrics.get("home_runs", 0)),
			"sb": int(metrics.get("stolen_bases", 0)),
			"so": int(metrics.get("batter_strikeouts", 0)),
			"era": float(metrics.get("earned_run_average", 0.0)) if has_pitching else 0.0,
			"whip": float(metrics.get("whip", 0.0)) if has_pitching else 0.0,
			"k9": float(metrics.get("strikeouts_per_nine", 0.0)) if has_pitching else 0.0,
			"sv": int(metrics.get("saves", 0)),
			"hld": int(metrics.get("holds", 0)),
			"qs": int(metrics.get("quality_starts", 0)),
		})
		rank += 1
	table.set_rows(rows)


func _team_metrics(team_id: int) -> Dictionary:
	var batter_stats: PSBatterStats = PSBatterStats.new()
	var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
	var season: PSSeason = AppState.current_season
	if season == null:
		return _empty_metrics()

	var records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter_stats.add_from(record.batter_stats)
		if record.is_pitcher():
			pitcher_stats.add_from(record.pitcher_stats)

	return {
		"batting_average": batter_stats.batting_average(),
		"on_base_percentage": batter_stats.on_base_percentage(),
		"slugging_percentage": batter_stats.slugging_percentage(),
		"ops": batter_stats.ops(),
		"home_runs": batter_stats.home_runs,
		"stolen_bases": batter_stats.stolen_bases,
		"batter_strikeouts": batter_stats.strikeouts,
		"earned_run_average": pitcher_stats.era(),
		"whip": pitcher_stats.whip(),
		"strikeouts_per_nine": pitcher_stats.strikeouts_per_nine(),
		"saves": pitcher_stats.saves,
		"holds": pitcher_stats.holds,
		"quality_starts": pitcher_stats.quality_starts,
		"outs_pitched": pitcher_stats.outs_pitched,
	}


func _empty_metrics() -> Dictionary:
	return {
		"batting_average": 0.0,
		"on_base_percentage": 0.0,
		"slugging_percentage": 0.0,
		"ops": 0.0,
		"home_runs": 0,
		"stolen_bases": 0,
		"batter_strikeouts": 0,
		"earned_run_average": 0.0,
		"whip": 0.0,
		"strikeouts_per_nine": 0.0,
		"saves": 0,
		"holds": 0,
		"quality_starts": 0,
		"outs_pitched": 0,
	}


func _game_back(leader: PSStats, stats: PSStats) -> float:
	return float((leader.wins - stats.wins) + (stats.losses - leader.losses)) / 2.0
