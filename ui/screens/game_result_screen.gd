extends Control

const FILTER_ALL: int = 0
const FILTER_RECENT_10: int = 1
const FILTER_RECENT_30_DAYS: int = 2

const SortableTable = preload("res://ui/components/sortable_table.gd")

const GAME_LIST_COLUMNS: Array = [
	{"title": "日", "key": "day", "width": 56, "type": "number", "format": "int"},
	{"title": "勝敗", "key": "marker", "width": 48, "type": "string", "format": "string"},
	{"title": "会場", "key": "venue", "width": 48, "type": "string", "format": "string"},
	{"title": "相手", "key": "opp", "width": 80, "type": "string", "format": "string"},
	{"title": "得", "key": "rs", "width": 44, "type": "number", "format": "int"},
	{"title": "失", "key": "ra", "width": 44, "type": "number", "format": "int"},
	{"title": "スコア", "key": "score", "width": 130, "type": "string", "format": "string"},
]

var team_select: OptionButton
var filter_select: OptionButton
var game_list: Tree
var line_score_table: Tree
var detail_text: RichTextLabel
var status_label: Label
var team_options: Array = []


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
	title.text = "試合結果"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var team_label: Label = Label.new()
	team_label.text = "チーム"
	header.add_child(team_label)

	team_select = OptionButton.new()
	team_select.custom_minimum_size = Vector2(140, 32)
	header.add_child(team_select)
	_populate_team_options()
	team_select.item_selected.connect(func(_index: int) -> void: _refresh_games())

	var filter_label: Label = Label.new()
	filter_label.text = "期間"
	header.add_child(filter_label)

	filter_select = OptionButton.new()
	filter_select.custom_minimum_size = Vector2(140, 32)
	filter_select.add_item("全期間", FILTER_ALL)
	filter_select.add_item("直近10試合", FILTER_RECENT_10)
	filter_select.add_item("直近30日", FILTER_RECENT_30_DAYS)
	header.add_child(filter_select)
	filter_select.item_selected.connect(func(_index: int) -> void: _refresh_games())

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	game_list = SortableTable.new()
	game_list.custom_minimum_size = Vector2(460, 0)
	split.add_child(game_list)
	game_list.configure(GAME_LIST_COLUMNS)
	game_list.set_default_sort(0, false)  # 日付 降順
	game_list.item_selected.connect(_on_game_selected)

	var detail_panel: VBoxContainer = VBoxContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_constant_override("separation", 6)
	split.add_child(detail_panel)

	line_score_table = SortableTable.new()
	line_score_table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	line_score_table.custom_minimum_size = Vector2(0, 96)
	detail_panel.add_child(line_score_table)

	detail_text = RichTextLabel.new()
	detail_text.bbcode_enabled = false
	detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_child(detail_text)

	_refresh_games()


func _populate_team_options() -> void:
	team_options.clear()
	team_select.clear()
	var selected_index: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var index: int = team_select.item_count
		team_select.add_item(team.short_name, team.id)
		team_options.append(team.id)
		if team.id == AppState.selected_team_id:
			selected_index = index
	if team_select.item_count > 0:
		team_select.select(selected_index)


func _refresh_games() -> void:
	game_list.set_rows([])
	detail_text.text = ""
	line_score_table.set_rows([])

	var season: PSSeason = AppState.current_season
	if season == null:
		status_label.text = "シーズンが開始されていません"
		return

	var team_id: int = _selected_team_id()
	if team_id <= 0:
		status_label.text = "チームを選択してください"
		return

	var collected: Array = []
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			continue
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		if away_id != team_id and home_id != team_id:
			continue
		collected.append({"index": index, "game": game})

	collected.sort_custom(func(a, b) -> bool:
		var game_a: Dictionary = (a as Dictionary)["game"] as Dictionary
		var game_b: Dictionary = (b as Dictionary)["game"] as Dictionary
		return int(game_a.get("day", 0)) > int(game_b.get("day", 0))
	)

	var filter_mode: int = filter_select.get_selected_id()
	if filter_mode == FILTER_RECENT_10:
		collected = collected.slice(0, 10)
	elif filter_mode == FILTER_RECENT_30_DAYS:
		var current_day: int = season.current_day
		var filtered: Array = []
		for entry_row in collected:
			var entry: Dictionary = entry_row as Dictionary
			var game: Dictionary = entry["game"] as Dictionary
			if int(game.get("day", 0)) >= current_day - 30:
				filtered.append(entry)
		collected = filtered

	if collected.is_empty():
		status_label.text = "条件に一致する試合がありません"
		return

	status_label.text = "%d試合" % collected.size()

	var rows: Array = []
	for entry_row in collected:
		var entry: Dictionary = entry_row as Dictionary
		var index: int = int(entry["index"])
		var game: Dictionary = entry["game"] as Dictionary
		var row: Dictionary = _game_row(team_id, game)
		row["__meta"] = index
		rows.append(row)
	game_list.set_rows(rows)
	_select_first_game()


func _select_first_game() -> void:
	var root: TreeItem = game_list.get_root()
	if root == null:
		return
	var first: TreeItem = root.get_first_child()
	if first == null:
		detail_text.text = ""
		line_score_table.set_rows([])
		return
	first.select(0)
	_show_game_detail(int(first.get_metadata(0)))


func _selected_team_id() -> int:
	if team_select.item_count == 0:
		return 0
	var idx: int = team_select.selected
	if idx < 0 or idx >= team_options.size():
		return 0
	return int(team_options[idx])


func _on_game_selected() -> void:
	var meta: Variant = game_list.get_selected_meta()
	if meta == null:
		return
	_show_game_detail(int(meta))


func _show_game_detail(schedule_index: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	if schedule_index < 0 or schedule_index >= season.schedule.size():
		return
	var game: Dictionary = season.schedule[schedule_index] as Dictionary
	_populate_line_score(game)
	detail_text.text = _format_game_detail(game)


func _game_row(team_id: int, game: Dictionary) -> Dictionary:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var away_score: int = int(game.get("away_score", 0))
	var home_score: int = int(game.get("home_score", 0))
	var away_name: String = _team_short(away_id)
	var home_name: String = _team_short(home_id)
	var result_dict: Dictionary = game.get("result", {}) as Dictionary
	var winning_team_id: int = int(result_dict.get("winning_team_id", 0))
	var draw: bool = bool(result_dict.get("draw", false))

	var marker: String = "△"
	if not draw:
		marker = "○" if winning_team_id == team_id else "●"

	var dh_label: String = "  DH" if bool(game.get("dh_enabled", false)) else ""
	return {
		"day": int(game.get("day", 0)),
		"marker": marker,
		"venue": "@" if team_id == away_id else "vs",
		"opp": home_name if team_id == away_id else away_name,
		"rs": away_score if team_id == away_id else home_score,
		"ra": home_score if team_id == away_id else away_score,
		"score": "%s %d-%d %s%s" % [away_name, away_score, home_score, home_name, dh_label],
	}


func _format_game_detail(game: Dictionary) -> String:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var away_name: String = _team_short(away_id)
	var home_name: String = _team_short(home_id)
	var away_score: int = int(game.get("away_score", 0))
	var home_score: int = int(game.get("home_score", 0))
	var innings: Array = game.get("innings", []) as Array
	var result_dict: Dictionary = game.get("result", {}) as Dictionary
	var lines: Array = []

	lines.append("%d日目  %s @ %s  %s" % [
		int(game.get("day", 0)),
		away_name,
		home_name,
		"DHリーグ" if bool(game.get("dh_enabled", false)) else "非DHリーグ",
	])
	lines.append("")

	if bool(result_dict.get("draw", false)):
		lines.append("結果: 引き分け")
	else:
		var winning_team_id: int = int(result_dict.get("winning_team_id", 0))
		var winner_name: String = _team_short(winning_team_id)
		lines.append("勝利: %s" % winner_name)
		lines.append("")
		lines.append("勝敗投手")
		var win_id: int = int(result_dict.get("winning_pitcher_id", 0))
		var loss_id: int = int(result_dict.get("losing_pitcher_id", 0))
		var save_id: int = int(result_dict.get("save_pitcher_id", 0))
		var hold_ids: Array = result_dict.get("hold_pitcher_ids", []) as Array
		if win_id <= 0:
			win_id = int(result_dict.get("away_pitcher_id", 0)) if winning_team_id == away_id else int(result_dict.get("home_pitcher_id", 0))
		if loss_id <= 0:
			loss_id = int(result_dict.get("away_pitcher_id", 0)) if winning_team_id == home_id else int(result_dict.get("home_pitcher_id", 0))
		lines.append("勝: %s" % _pitcher_label(win_id))
		lines.append("敗: %s" % _pitcher_label(loss_id))
		if save_id > 0:
			lines.append("S: %s" % _pitcher_label(save_id))
		if not hold_ids.is_empty():
			var hold_labels: Array = []
			for pid in hold_ids:
				hold_labels.append(_pitcher_name(int(pid)))
			lines.append("H: %s" % ", ".join(hold_labels))

	var has_pitcher_logs: bool = false
	for entry_row in innings:
		var entry: Dictionary = entry_row as Dictionary
		if int(entry.get("home_team_pitcher_id", 0)) > 0 or int(entry.get("away_team_pitcher_id", 0)) > 0:
			has_pitcher_logs = true
			break
	if has_pitcher_logs:
		lines.append("")
		lines.append(_format_pitcher_lineup(away_name, "away_team_pitcher_id", innings))
		lines.append(_format_pitcher_lineup(home_name, "home_team_pitcher_id", innings))

	return "\n".join(lines)


func _format_pitcher_lineup(team_short_name: String, key: String, innings: Array) -> String:
	var segments: Array = []
	for i in range(innings.size()):
		var entry: Dictionary = innings[i] as Dictionary
		if key == "away_team_pitcher_id" and not bool(entry.get("home_half_played", true)):
			continue
		var pid: int = int(entry.get(key, 0))
		if pid <= 0:
			continue
		var inning_num: int = int(entry.get("inning", i + 1))
		if not segments.is_empty() and int(segments[-1]["pid"]) == pid:
			segments[-1]["to"] = inning_num
		else:
			segments.append({"from": inning_num, "to": inning_num, "pid": pid})
	if segments.is_empty():
		return "投手起用 (%s) なし" % team_short_name
	var parts: Array = []
	for seg in segments:
		var range_str: String
		if int(seg["from"]) == int(seg["to"]):
			range_str = "%d回" % int(seg["from"])
		else:
			range_str = "%d-%d回" % [int(seg["from"]), int(seg["to"])]
		parts.append("%s %s" % [range_str, _pitcher_name(int(seg["pid"]))])
	return "投手起用 (%s)\n  %s" % [team_short_name, "  ".join(parts)]


func _pitcher_name(pitcher_id: int) -> String:
	if pitcher_id <= 0:
		return "不明"
	var season: PSSeason = AppState.current_season
	if season == null:
		return "不明"
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pitcher_id, season.year, season.season_number)
	if record == null:
		return "不明"
	return record.name


func _populate_line_score(game: Dictionary) -> void:
	var innings: Array = game.get("innings", []) as Array
	var away_name: String = _team_short(int(game.get("away_team_id", 0)))
	var home_name: String = _team_short(int(game.get("home_team_id", 0)))
	var inning_count: int = innings.size()

	var columns: Array = [{"title": "", "key": "team", "width": 80, "type": "string", "format": "string"}]
	for i in range(inning_count):
		columns.append({"title": str(i + 1), "key": "i%d" % i, "width": 34, "type": "string", "format": "string"})
	columns.append({"title": "R", "key": "r", "width": 44, "type": "number", "format": "int"})
	line_score_table.configure(columns, false)

	var away_row: Dictionary = {"team": away_name, "r": int(game.get("away_score", 0))}
	var home_row: Dictionary = {"team": home_name, "r": int(game.get("home_score", 0))}
	for i in range(inning_count):
		var entry: Dictionary = innings[i] as Dictionary
		away_row["i%d" % i] = str(int(entry.get("away", 0)))
		if bool(entry.get("home_half_played", true)):
			home_row["i%d" % i] = str(int(entry.get("home", 0)))
		else:
			home_row["i%d" % i] = "X"
	line_score_table.set_rows([away_row, home_row])


func _pitcher_label(pitcher_id: int) -> String:
	if pitcher_id <= 0:
		return "不明"
	var season: PSSeason = AppState.current_season
	if season == null:
		return "不明"
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pitcher_id, season.year, season.season_number)
	if record == null:
		return "不明"
	return "%s (%d-%d)" % [record.name, record.pitcher_stats.wins, record.pitcher_stats.losses]


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name
