extends Control

const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")
const TeamFinance = preload("res://services/season/team_finance.gd")
const DeveloperTools = preload("res://services/development/developer_tools.gd")

# オフシーズン処理の総ステップ数 (offseason_screen.gd の TOTAL_STEPS と一致させる)
const OFFSEASON_TOTAL_STEPS: int = 7

const LEAGUES: Array = [
	{"key": "central", "label": "第1リーグ"},
	{"key": "pacific", "label": "第2リーグ"},
]

const ROSTER_COLUMNS: Array = [
	{"title": "背", "key": "jersey", "width": 44, "type": "string", "format": "string"},
	{"title": "守備", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
]

const TODAY_GAME_COLUMNS: Array = [
	{"title": "", "key": "mark", "width": 30, "type": "string", "format": "string"},
	{"title": "ビジター", "key": "away", "width": 72, "type": "string", "format": "string"},
	{"title": "スコア", "key": "score", "width": 64, "type": "string", "format": "string"},
	{"title": "ホーム", "key": "home", "width": 84, "type": "string", "format": "string"},
	{"title": "結果", "key": "result", "width": 64, "type": "string", "format": "string"},
]

const UPCOMING_COLUMNS: Array = [
	{"title": "日", "key": "day", "width": 56, "type": "number", "format": "int"},
	{"title": "いつ", "key": "when", "width": 64, "type": "string", "format": "string"},
	{"title": "会場", "key": "venue", "width": 48, "type": "string", "format": "string"},
	{"title": "相手", "key": "opp", "width": 84, "type": "string", "format": "string"},
]

const INJURY_COLUMNS: Array = [
	{"title": "位置", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "残り日", "key": "days", "width": 64, "type": "number", "format": "int"},
]

const HOME_STANDINGS_COLUMNS: Array = [
	{"title": "順", "key": "rank", "width": 36, "type": "number", "format": "int"},
	{"title": "球団", "key": "team", "width": 56, "type": "string", "format": "string"},
	{"title": "勝", "key": "w", "width": 40, "type": "number", "format": "int"},
	{"title": "敗", "key": "l", "width": 40, "type": "number", "format": "int"},
	{"title": "分", "key": "d", "width": 36, "type": "number", "format": "int"},
	{"title": "勝率", "key": "pct", "width": 60, "type": "number", "format": "rate"},
	{"title": "GB", "key": "gb", "width": 48, "type": "number", "format": "float1"},
	{"title": "残", "key": "rem", "width": 40, "type": "number", "format": "int"},
	{"title": "打率", "key": "avg", "width": 60, "type": "number", "format": "rate"},
	{"title": "本", "key": "hr", "width": 40, "type": "number", "format": "int"},
	{"title": "防", "key": "era", "width": 56, "type": "number", "format": "float2"},
]

var status_label: Label
var sort_select: OptionButton
var player_list: Tree
var detail_text: RichTextLabel
var current_records: Array = []


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
	title.text = "メイン"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	if DeveloperTools.enabled():
		var report_button: Button = Button.new()
		report_button.text = "分析"
		report_button.custom_minimum_size = Vector2(68, 34)
		report_button.pressed.connect(func() -> void: AppState.request_screen("balance_report"))
		header.add_child(report_button)

		var probe_button: Button = Button.new()
		probe_button.text = "選手プローブ"
		probe_button.custom_minimum_size = Vector2(118, 34)
		probe_button.pressed.connect(func() -> void: AppState.request_screen("player_probe"))
		header.add_child(probe_button)

	var next_game_button: Button = Button.new()
	next_game_button.text = "次の試合"
	next_game_button.custom_minimum_size = Vector2(96, 34)
	next_game_button.pressed.connect(_simulate_next_game)
	header.add_child(next_game_button)

	var today_button: Button = Button.new()
	today_button.text = "本日全試合"
	today_button.custom_minimum_size = Vector2(104, 34)
	today_button.pressed.connect(_simulate_current_day)
	header.add_child(today_button)

	var skip_all_button: Button = Button.new()
	skip_all_button.text = "残り全試合"
	skip_all_button.custom_minimum_size = Vector2(104, 34)
	skip_all_button.pressed.connect(_simulate_remaining_season)
	header.add_child(skip_all_button)

	var save_button: Button = Button.new()
	save_button.text = "セーブ"
	save_button.custom_minimum_size = Vector2(78, 34)
	save_button.pressed.connect(_save_game)
	header.add_child(save_button)

	var offseason_button: Button = Button.new()
	offseason_button.custom_minimum_size = Vector2(120, 34)
	offseason_button.pressed.connect(_on_offseason_pressed)
	_configure_offseason_button(offseason_button)
	header.add_child(offseason_button)

	var team_button: Button = Button.new()
	team_button.text = "チーム選択"
	team_button.custom_minimum_size = Vector2(104, 34)
	team_button.pressed.connect(func() -> void: AppState.request_screen("team_select"))
	header.add_child(team_button)

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_empty_state(root)
		return

	var overview: GridContainer = GridContainer.new()
	overview.columns = 4
	overview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview.add_theme_constant_override("h_separation", 20)
	overview.add_theme_constant_override("v_separation", 4)
	root.add_child(overview)

	_add_fact(overview, "球団", team.name)
	_add_fact(overview, "年度", "%d年 / %d年目" % [season.year, season.season_number])
	_add_fact(overview, "現在日", "%d日目" % season.current_day)
	_add_fact(overview, "予定試合", "%d試合" % season.total_games())
	_add_fact(overview, "未消化", "%d試合" % season.games_remaining())
	_add_fact(overview, "自軍残り", "%d試合" % season.team_games_remaining(team.id))
	# R4 Step1: 予算 (funds) と年俸総額。
	var payroll: int = TeamFinance.team_payroll(GameDb.players, team.id)
	_add_fact(overview, "予算", "%d万円" % team.funds)
	_add_fact(overview, "年俸総額", "%d万円%s" % [payroll, "  (超過)" if TeamFinance.is_over_budget(team.funds, payroll) else ""])

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var roster_panel: Control = _build_roster_panel(team.id)
	split.add_child(roster_panel)

	var schedule_panel: Control = _build_schedule_panel()
	split.add_child(schedule_panel)

	status_label = Label.new()
	status_label.text = AppState.last_status_message
	root.add_child(status_label)


func _add_empty_state(parent: Control) -> void:
	var label: Label = Label.new()
	label.text = "新規シーズンが開始されていません"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(label)

	var button: Button = Button.new()
	button.text = "チーム選択へ"
	button.custom_minimum_size = Vector2(180, 44)
	button.pressed.connect(func() -> void: AppState.request_screen("team_select"))
	parent.add_child(button)


func _add_fact(parent: Control, label_text: String, value_text: String) -> void:
	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	parent.add_child(label)

	var value: Label = Label.new()
	value.text = value_text
	parent.add_child(value)


func _build_roster_panel(team_id: int) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	var title: Label = Label.new()
	title.text = "選手一覧"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	sort_select = OptionButton.new()
	sort_select.custom_minimum_size = Vector2(150, 34)
	sort_select.add_item("評価順")
	sort_select.add_item("年齢順")
	sort_select.add_item("守備位置順")
	sort_select.item_selected.connect(func(_index: int) -> void: _refresh_player_list(team_id))
	header.add_child(sort_select)

	var detail_button: Button = Button.new()
	detail_button.text = "詳細"
	detail_button.custom_minimum_size = Vector2(68, 34)
	detail_button.pressed.connect(_open_selected_player_detail)
	header.add_child(detail_button)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(split)

	player_list = SortableTable.new()
	split.add_child(player_list)
	player_list.configure(ROSTER_COLUMNS)
	player_list.item_selected.connect(_on_player_selected)
	player_list.row_activated.connect(func(meta: Variant) -> void: AppState.show_player_detail(int(meta)))

	detail_text = RichTextLabel.new()
	detail_text.bbcode_enabled = false
	detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(detail_text)

	_refresh_player_list(team_id)
	return box


func _build_schedule_panel() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)

	_add_today_games_section(box)
	_add_team_pulse_section(box)
	_add_standings_list(box)
	_add_upcoming_schedule_section(box)
	_add_injuries_section(box)

	return box


func _add_today_games_section(parent: Control) -> void:
	var season: PSSeason = AppState.current_season
	var title: Label = Label.new()
	title.text = "本日の試合 (Day %d)" % season.current_day
	title.add_theme_font_size_override("font_size", 18)
	parent.add_child(title)

	var table: Tree = SortableTable.new()
	table.custom_minimum_size = Vector2(500, 150)
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(table)
	table.configure(TODAY_GAME_COLUMNS, false)

	var rows: Array = []
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if int(game.get("day", 0)) == season.current_day:
			rows.append(_today_game_row(game))
	table.set_rows(rows)


func _today_game_row(game: Dictionary) -> Dictionary:
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return {"mark": "", "away": "-", "score": "", "home": "-", "result": ""}
	var dh_label: String = " DH" if bool(game.get("dh_enabled", false)) else ""
	var is_user_game: bool = (away.id == AppState.selected_team_id or home.id == AppState.selected_team_id)
	var mark: String = "★" if is_user_game else ""

	if bool(game.get("played", false)):
		var winner: int = int((game.get("result", {}) as Dictionary).get("winning_team_id", 0))
		var result_text: String = "引分"
		if winner == away.id:
			result_text = "%s 勝" % away.short_name
		elif winner == home.id:
			result_text = "%s 勝" % home.short_name
		return {
			"mark": mark,
			"away": away.short_name,
			"score": "%d-%d" % [int(game.get("away_score", 0)), int(game.get("home_score", 0))],
			"home": home.short_name + dh_label,
			"result": result_text,
		}
	return {
		"mark": mark,
		"away": away.short_name,
		"score": "-",
		"home": home.short_name + dh_label,
		"result": "予定",
	}


func _add_team_pulse_section(parent: Control) -> void:
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		return
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return

	var title: Label = Label.new()
	title.text = "%s 直近10試合" % team.short_name
	title.add_theme_font_size_override("font_size", 16)
	parent.add_child(title)

	var pulse_label: Label = Label.new()
	pulse_label.text = _build_recent_pulse(team_id)
	pulse_label.add_theme_font_size_override("font_size", 16)
	parent.add_child(pulse_label)


func _build_recent_pulse(team_id: int) -> String:
	var season: PSSeason = AppState.current_season
	if season == null:
		return ""
	var played: Array = []
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)):
			continue
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		if away_id != team_id and home_id != team_id:
			continue
		played.append(game)

	played.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("day", 0)) > int((b as Dictionary).get("day", 0))
	)

	if played.is_empty():
		return "(消化済みの試合がありません)"

	var recent: Array = played.slice(0, 10)
	recent.reverse()
	var parts: Array = []
	var wins: int = 0
	var losses: int = 0
	var draws: int = 0
	for game_row in recent:
		var game: Dictionary = game_row as Dictionary
		var result_dict: Dictionary = game.get("result", {}) as Dictionary
		if bool(result_dict.get("draw", false)):
			parts.append("△")
			draws += 1
		elif int(result_dict.get("winning_team_id", 0)) == team_id:
			parts.append("○")
			wins += 1
		else:
			parts.append("●")
			losses += 1
	return "%s   (%d勝 %d敗 %d分)" % [" ".join(parts), wins, losses, draws]


func _add_upcoming_schedule_section(parent: Control) -> void:
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		return
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return

	var title: Label = Label.new()
	title.text = "今後の自軍試合"
	title.add_theme_font_size_override("font_size", 16)
	parent.add_child(title)

	var table: Tree = SortableTable.new()
	table.custom_minimum_size = Vector2(500, 120)
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(table)
	table.configure(UPCOMING_COLUMNS, false)

	var season: PSSeason = AppState.current_season
	var rows: Array = []
	var shown: int = 0
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if bool(game.get("played", false)):
			continue
		if shown >= 10:
			break
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		if away_id != team_id and home_id != team_id:
			continue
		var venue: String = "@" if team_id == away_id else "vs"
		var opp_id: int = home_id if team_id == away_id else away_id
		var opp: PSTeam = GameDb.get_team(opp_id)
		var opp_name: String = opp.short_name if opp != null else "-"
		var dh_label: String = " DH" if bool(game.get("dh_enabled", false)) else ""
		var gap: int = int(game.get("day", 0)) - season.current_day
		var when_text: String = "本日" if gap == 0 else "%d日後" % gap
		rows.append({
			"day": int(game.get("day", 0)),
			"when": when_text,
			"venue": venue,
			"opp": opp_name + dh_label,
		})
		shown += 1
	table.set_rows(rows)


func _add_injuries_section(parent: Control) -> void:
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		return
	var injured: Array = []
	for record_row in RecordStore.get_current_player_records_for_team(team_id):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.injury_days > 0:
			injured.append(record)
	if injured.is_empty():
		return

	var title: Label = Label.new()
	title.text = "怪我選手 (%d人)" % injured.size()
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
	parent.add_child(title)

	injured.sort_custom(func(a, b) -> bool:
		return (a as PSPlayerSeasonRecord).injury_days > (b as PSPlayerSeasonRecord).injury_days
	)

	var table: Tree = SortableTable.new()
	table.custom_minimum_size = Vector2(500, 100)
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(table)
	table.configure(INJURY_COLUMNS)
	table.set_default_sort(2, false)  # 残り日 降順
	var rows: Array = []
	for record_row in injured:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		rows.append({
			"pos": str(PSPlayer.POSITION_NAMES.get(record.position, "?")),
			"name": record.name,
			"days": record.injury_days,
		})
	table.set_rows(rows)


func _add_standings_list(parent: Control) -> void:
	var title: Label = Label.new()
	title.text = "順位 / チーム指標"
	title.add_theme_font_size_override("font_size", 18)
	parent.add_child(title)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.custom_minimum_size = Vector2(0, 300)
	parent.add_child(split)

	for league_row in LEAGUES:
		var league: Dictionary = league_row as Dictionary
		var key: String = str(league["key"])
		var label_text: String = str(league["label"])
		_add_home_league_panel(split, label_text, key)


func _add_home_league_panel(split_parent: Control, label_text: String, league_key: String) -> void:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)
	split_parent.add_child(panel)

	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.86))
	panel.add_child(label)

	var table: Tree = SortableTable.new()
	table.custom_minimum_size = Vector2(360, 280)
	panel.add_child(table)
	table.configure(HOME_STANDINGS_COLUMNS)
	table.set_default_sort(5, false)  # 勝率 降順

	var entries: Array = []
	for team_id in AppState.current_season.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id))
		if team == null or team.league != league_key:
			continue
		entries.append({
			"team": team,
			"stats": AppState.current_season.standings[team_id],
			"remaining": AppState.current_season.team_games_remaining(int(team_id)),
			"metrics": _team_metrics(int(team_id)),
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
		var metrics: Dictionary = row.get("metrics", {}) as Dictionary
		var has_pitching: bool = int(metrics.get("outs_pitched", 0)) > 0
		rows.append({
			"rank": rank,
			"team": team.short_name,
			"w": stats.wins,
			"l": stats.losses,
			"d": stats.draws,
			"pct": stats.win_rate(),
			"gb": 0.0 if (rank == 1 or leader_stats == null) else _game_back(leader_stats, stats),
			"rem": int(row.get("remaining", 0)),
			"avg": float(metrics.get("batting_average", 0.0)),
			"hr": int(metrics.get("home_runs", 0)),
			"era": float(metrics.get("earned_run_average", 0.0)) if has_pitching else 0.0,
		})
		rank += 1
	table.set_rows(rows)


func _team_metrics(team_id: int) -> Dictionary:
	var batter_stats: PSBatterStats = PSBatterStats.new()
	var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
	var season: PSSeason = AppState.current_season
	if season == null:
		return {
			"batting_average": 0.0,
			"home_runs": 0,
			"earned_run_average": 0.0,
			"outs_pitched": 0,
		}

	var records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter_stats.add_from(record.batter_stats)
		if record.is_pitcher():
			pitcher_stats.add_from(record.pitcher_stats)

	return {
		"batting_average": batter_stats.batting_average(),
		"home_runs": batter_stats.home_runs,
		"earned_run_average": pitcher_stats.era(),
		"outs_pitched": pitcher_stats.outs_pitched,
	}


func _simulate_next_game() -> void:
	# 1 試合だけなので同期で十分 (~100-300ms)
	var result: Dictionary = AppState.simulate_next_game()
	if status_label != null:
		status_label.text = str(result.get("message", ""))


func _simulate_current_day() -> void:
	var ov: Dictionary = _show_progress_overlay("本日の試合を消化中…")
	var result: Dictionary = await AppState.simulate_current_day_async(
		get_tree(), ov["callback"], ov["cancel_token"], false
	)
	_hide_progress_overlay(ov)
	if status_label != null:
		status_label.text = str(result.get("message", ""))


func _simulate_remaining_season() -> void:
	var ov: Dictionary = _show_progress_overlay("残り全試合を消化中…")
	var result: Dictionary = await AppState.simulate_remaining_season_async(
		get_tree(), ov["callback"], ov["cancel_token"], false
	)
	_hide_progress_overlay(ov)
	if status_label != null:
		status_label.text = str(result.get("message", ""))


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


func _save_game() -> void:
	var ok: bool = SaveService.save_state(AppState)
	if status_label != null:
		status_label.text = "保存しました" if ok else "保存に失敗しました"


func _configure_offseason_button(button: Button) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		button.text = "翌年へ"
		button.disabled = true
		return
	if AppState.offseason_active:
		# step 4 まで処理済みの場合は finalize 直結ボタンに切り替える
		if AppState.offseason_step >= OFFSEASON_TOTAL_STEPS:
			button.text = "翌年開始"
		else:
			button.text = "オフシーズン続行"
		button.disabled = false
		return
	if AppState.postseason_active:
		# ポストシーズン進行中またはJS完了で表彰待ち
		if AppState.current_postseason != null and PostseasonService.is_complete(AppState.current_postseason):
			button.text = "表彰へ"
		else:
			button.text = "ポストシーズン続行"
		button.disabled = false
		return
	if season.is_finished():
		# 表彰未了ならポストシーズン開始
		if AppState.current_postseason == null or not PostseasonService.is_complete(AppState.current_postseason):
			button.text = "ポストシーズン開始"
		else:
			button.text = "オフシーズン開始"
		button.disabled = false
		return
	button.text = "翌年へ"
	button.disabled = true


func _on_offseason_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	if AppState.offseason_active:
		# step 4 まで処理済みなら直接 finalize へ (home → 翌年開始)。
		# 途中ステップなら従来通り offseason 画面で続行。
		if AppState.offseason_step >= OFFSEASON_TOTAL_STEPS:
			var ok: bool = AppState.finalize_offseason()
			if not ok and status_label != null:
				status_label.text = "翌年開始に失敗しました"
		else:
			AppState.request_screen("offseason")
		return
	if AppState.postseason_active:
		if AppState.current_postseason != null and PostseasonService.is_complete(AppState.current_postseason):
			var fin: Dictionary = AppState.finalize_postseason_to_awards()
			if not bool(fin.get("ok", false)) and status_label != null:
				status_label.text = str(fin.get("message", ""))
		else:
			AppState.request_screen("postseason")
		return
	if not season.is_finished():
		if status_label != null:
			status_label.text = "シーズン完了後にオフシーズンを開始できます(残り%d試合)" % season.games_remaining()
		return
	# ポストシーズン未開始 → 開始する
	if AppState.current_postseason == null or not PostseasonService.is_complete(AppState.current_postseason):
		var ps: Dictionary = AppState.start_postseason()
		if not bool(ps.get("ok", false)) and status_label != null:
			status_label.text = str(ps.get("message", ""))
		return
	# ポストシーズン完了済み → オフシーズン
	var result: Dictionary = AppState.start_offseason()
	if not bool(result.get("ok", false)) and status_label != null:
		status_label.text = str(result.get("message", ""))


func _refresh_player_list(team_id: int) -> void:
	if player_list == null:
		return

	current_records = RecordStore.get_current_player_records_for_team(team_id)
	var rows: Array = []
	for record_row in current_records:
		rows.append(_roster_row(record_row as PSPlayerSeasonRecord))
	player_list.set_rows(rows)
	_apply_roster_sort()
	_select_first_roster()


func _roster_row(record: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"jersey": _jersey_text(record),
		"pos": _position_name(record.position),
		"name": record.name,
		"age": record.age,
		"eval": PlayerValueEvaluator.overall_score(record),
		"__meta": record.player_id,
	}


# sort_select (評価順/年齢順/守備位置順) を SortableTable の既定ソートにマップする。
# 列見出しクリックでも個別にソートできる。
func _apply_roster_sort() -> void:
	var selected: int = 0 if sort_select == null else sort_select.selected
	match selected:
		1:
			player_list.set_default_sort(3, true)   # 年齢 昇順
		2:
			player_list.set_default_sort(1, true)   # 守備位置 昇順
		_:
			player_list.set_default_sort(4, false)  # 評価 降順


func _select_first_roster() -> void:
	if player_list == null:
		return
	var root: TreeItem = player_list.get_root()
	var first: TreeItem = root.get_first_child() if root != null else null
	if first == null:
		detail_text.text = "選手記録がありません"
		return
	first.select(0)
	_show_detail_for_player(int(first.get_metadata(0)))


func _show_detail_for_player(player_id: int) -> void:
	for record_row in current_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			_show_player_detail(record)
			return


func _on_player_selected() -> void:
	var meta: Variant = player_list.get_selected_meta()
	if meta == null:
		return
	AppState.current_player_id = int(meta)
	_show_detail_for_player(int(meta))


func _open_selected_player_detail() -> void:
	if player_list == null:
		return
	var meta: Variant = player_list.get_selected_meta()
	if meta == null:
		return
	AppState.show_player_detail(int(meta))


func _show_player_detail(record: PSPlayerSeasonRecord) -> void:
	if detail_text == null:
		return

	var history: Array = RecordStore.get_player_records(record.player_id)
	var lines: Array = []
	var jersey_text: String = _jersey_text(record)
	var jersey: String = "" if jersey_text == "-" else "#%s  " % jersey_text
	lines.append("%s%s  %s" % [jersey, record.name, _position_name(record.position)])
	lines.append("%d年 / %d年目  %d歳  %d年目  %dcm %dkg  %s投%s打" % [
		record.year,
		record.season_number,
		record.age,
		record.years,
		record.height,
		record.weight,
		_hand_name(record.throwing_hand),
		_hand_name(record.batting_side),
	])
	lines.append("%s  %s" % [record.registered_roster, record.contract_status])
	lines.append("疲労 %d  怪我 %d日" % [record.fatigue, record.injury_days])
	lines.append("")
	lines.append("能力")
	lines.append(_ability_line(record))
	lines.append("")
	if record.is_pitcher():
		lines.append("投手成績")
		lines.append("登板 %d  先発 %d  勝敗 %d-%d  H %d  S %d" % [
			record.pitcher_stats.games,
			record.pitcher_stats.starts,
			record.pitcher_stats.wins,
			record.pitcher_stats.losses,
			record.pitcher_stats.holds,
			record.pitcher_stats.saves,
		])
		lines.append("防御率 %s  WHIP %s  奪三振率 %s" % [
			_format_float(record.pitcher_stats.era(), 2),
			_format_float(record.pitcher_stats.whip(), 2),
			_format_float(record.pitcher_stats.strikeouts_per_nine(), 2),
		])
	else:
		lines.append("野手成績")
		lines.append("試合 %d  打席 %d  打数 %d  安打 %d  本塁打 %d  打点 %d" % [
			record.batter_stats.games,
			record.batter_stats.plate_appearances,
			record.batter_stats.at_bats,
			record.batter_stats.hits,
			record.batter_stats.home_runs,
			record.batter_stats.runs_batted_in,
		])
		lines.append("打率 %s  出塁率 %s  OPS %s" % [
			_format_rate(record.batter_stats.batting_average()),
			_format_rate(record.batter_stats.on_base_percentage()),
			_format_rate(record.batter_stats.ops()),
		])

	lines.append("")
	lines.append("年度履歴")
	for past_row in history:
		var past: PSPlayerSeasonRecord = past_row as PSPlayerSeasonRecord
		lines.append("%d年 %d年目  %s  %d歳  %s" % [
			past.year,
			past.season_number,
			_team_short_name(past.team_id),
			past.age,
			_player_rating_label(past),
		])

	lines.append("")
	if record.is_pitcher():
		lines.append("今期投手成績")
		lines.append(_pitcher_stats_basic_line(record.pitcher_stats))
		lines.append(_pitcher_stats_rate_line(record.pitcher_stats))
		lines.append("")
		var career_pitcher_stats: PSPitcherStats = RecordStore.get_player_career_pitcher_stats(record.player_id)
		lines.append("通算投手成績")
		lines.append(_pitcher_stats_basic_line(career_pitcher_stats))
		lines.append(_pitcher_stats_rate_line(career_pitcher_stats))
	else:
		lines.append("今期野手成績")
		lines.append(_batter_stats_basic_line(record.batter_stats))
		lines.append(_batter_stats_rate_line(record.batter_stats))
		lines.append("")
		var career_batter_stats: PSBatterStats = RecordStore.get_player_career_batter_stats(record.player_id)
		lines.append("通算野手成績")
		lines.append(_batter_stats_basic_line(career_batter_stats))
		lines.append(_batter_stats_rate_line(career_batter_stats))

	detail_text.text = "\n".join(lines)


func _pitcher_stats_basic_line(stats: PSPitcherStats) -> String:
	return "登板 %d  先発 %d  勝敗 %d-%d  H %d  S %d  回 %s" % [
		stats.games,
		stats.starts,
		stats.wins,
		stats.losses,
		stats.holds,
		stats.saves,
		_format_innings(stats.outs_pitched),
	]


func _pitcher_stats_rate_line(stats: PSPitcherStats) -> String:
	return "防御率 %s  WHIP %s  奪三振率 %s" % [
		_format_float(stats.era(), 2),
		_format_float(stats.whip(), 2),
		_format_float(stats.strikeouts_per_nine(), 2),
	]


func _batter_stats_basic_line(stats: PSBatterStats) -> String:
	return "試合 %d  打席 %d  打数 %d  安打 %d  二塁打 %d  三塁打 %d  本塁打 %d  打点 %d" % [
		stats.games,
		stats.plate_appearances,
		stats.at_bats,
		stats.hits,
		stats.doubles,
		stats.triples,
		stats.home_runs,
		stats.runs_batted_in,
	]


func _batter_stats_rate_line(stats: PSBatterStats) -> String:
	return "打率 %s  出塁率 %s  OPS %s" % [
		_format_rate(stats.batting_average()),
		_format_rate(stats.on_base_percentage()),
		_format_rate(stats.ops()),
	]


func _format_innings(outs: int) -> String:
	return "%d.%d" % [int(outs / 3), outs % 3]


func _ability_line(record: PSPlayerSeasonRecord) -> String:
	return PlayerVisibleRatings.summary_line(record)


func _player_rating_label(record: PSPlayerSeasonRecord) -> String:
	return "Eval %d" % PlayerValueEvaluator.overall_score(record)


func _position_name(position: int) -> String:
	return str(PSPlayer.POSITION_NAMES.get(position, "不明"))


func _team_short_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _jersey_text(record: PSPlayerSeasonRecord) -> String:
	if record.jersey_number > 0:
		return str(record.jersey_number)
	if record.team_id > 0 or record.sensyu_num > 0:
		return "0"
	return "-"


func _hand_name(value: String) -> String:
	match value:
		"L":
			return "左"
		"S":
			return "両"
		_:
			return "右"


func _format_rate(value: float) -> String:
	return "%0.3f" % value


func _game_back(leader: PSStats, stats: PSStats) -> float:
	return float((leader.wins - stats.wins) + (stats.losses - leader.losses)) / 2.0


func _format_float(value: float, digits: int) -> String:
	if digits == 1:
		return "%0.1f" % value
	if digits == 2:
		return "%0.2f" % value
	return "%0.3f" % value
