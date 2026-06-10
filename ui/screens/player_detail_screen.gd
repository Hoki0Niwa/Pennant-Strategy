extends Control

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")

const HISTORY_COLUMNS: Array = [
	{"title": "年", "key": "year", "width": 64, "type": "number", "format": "int"},
	{"title": "年目", "key": "season_number", "width": 56, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 64, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "成績", "key": "summary", "width": 220, "type": "string", "format": "string"},
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

var status_label: Label
var detail_text: RichTextLabel
var history_table: Tree
var team_select: OptionButton
var player_select: OptionButton
var team_options: Array = []
var player_options: Array = []


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
	title.text = "選手詳細"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	var team_label: Label = Label.new()
	team_label.text = "チーム"
	header.add_child(team_label)

	team_select = OptionButton.new()
	team_select.custom_minimum_size = Vector2(140, 32)
	team_select.item_selected.connect(func(_index: int) -> void: _on_team_changed())
	header.add_child(team_select)

	var player_label: Label = Label.new()
	player_label.text = "選手"
	header.add_child(player_label)

	player_select = OptionButton.new()
	player_select.custom_minimum_size = Vector2(220, 32)
	player_select.item_selected.connect(func(_index: int) -> void: _on_player_changed())
	header.add_child(player_select)

	header.add_child(Control.new())

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	var split: VSplitContainer = VSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	detail_text = RichTextLabel.new()
	detail_text.bbcode_enabled = false
	detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(detail_text)

	var history_panel: VBoxContainer = VBoxContainer.new()
	history_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_panel.add_theme_constant_override("separation", 4)
	history_panel.custom_minimum_size = Vector2(0, 180)
	split.add_child(history_panel)

	var history_title: Label = Label.new()
	history_title.text = "年度履歴 (列見出しクリックでソート)"
	history_title.add_theme_font_size_override("font_size", 16)
	history_panel.add_child(history_title)

	history_table = SortableTable.new()
	history_panel.add_child(history_table)
	history_table.configure(HISTORY_COLUMNS)
	history_table.set_default_sort(0, false)  # 年 降順

	_populate_team_select()
	_refresh_after_team_change(true)


func _populate_team_select() -> void:
	team_options.clear()
	team_select.clear()
	var default_team_id: int = _initial_team_id()
	var selected_index: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var index: int = team_select.item_count
		team_select.add_item(team.short_name, team.id)
		team_options.append(team.id)
		if team.id == default_team_id:
			selected_index = index
	if team_select.item_count > 0:
		team_select.select(selected_index)


func _initial_team_id() -> int:
	if AppState.current_player_id > 0:
		var season: PSSeason = AppState.current_season
		if season != null:
			var record: PSPlayerSeasonRecord = RecordStore.get_player_record(AppState.current_player_id, season.year, season.season_number)
			if record != null and record.team_id > 0:
				return record.team_id
	if AppState.selected_team_id > 0:
		return AppState.selected_team_id
	if not GameDb.teams.is_empty():
		return (GameDb.teams[0] as PSTeam).id
	return 0


func _on_team_changed() -> void:
	_refresh_after_team_change(false)


func _refresh_after_team_change(use_current_player: bool) -> void:
	player_options.clear()
	player_select.clear()
	var season: PSSeason = AppState.current_season
	if season == null:
		status_label.text = "シーズンが開始されていません"
		detail_text.text = ""
		history_table.set_rows([])
		return
	var team_id: int = _selected_team_id()
	if team_id <= 0:
		status_label.text = "チームを選択してください"
		detail_text.text = ""
		history_table.set_rows([])
		return

	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	var pitchers: Array = []
	var batters: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitchers.append(record)
		else:
			batters.append(record)
	var by_overall: Callable = func(a, b) -> bool:
		return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
	pitchers.sort_custom(by_overall)
	batters.sort_custom(by_overall)

	var target_player_id: int = AppState.current_player_id if use_current_player else 0
	var selected_index: int = -1
	for record_row in pitchers:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var index: int = player_select.item_count
		player_select.add_item("[投] %s" % record.name, record.player_id)
		player_options.append(record.player_id)
		if record.player_id == target_player_id:
			selected_index = index
	for record_row in batters:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var index: int = player_select.item_count
		player_select.add_item("[%s] %s" % [_short_position_name(record.position), record.name], record.player_id)
		player_options.append(record.player_id)
		if record.player_id == target_player_id:
			selected_index = index
	if player_select.item_count == 0:
		status_label.text = "選手記録がありません"
		detail_text.text = ""
		history_table.set_rows([])
		return

	player_select.select(max(selected_index, 0))
	_on_player_changed()


func _selected_team_id() -> int:
	if team_select.item_count == 0:
		return 0
	var idx: int = team_select.selected
	if idx < 0 or idx >= team_options.size():
		return 0
	return int(team_options[idx])


func _selected_player_id() -> int:
	if player_select.item_count == 0:
		return 0
	var idx: int = player_select.selected
	if idx < 0 or idx >= player_options.size():
		return 0
	return int(player_options[idx])


func _on_player_changed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var player_id: int = _selected_player_id()
	if player_id <= 0:
		detail_text.text = ""
		history_table.set_rows([])
		return
	AppState.current_player_id = player_id
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
	if record == null:
		detail_text.text = "選手記録が見つかりません"
		history_table.set_rows([])
		return
	status_label.text = ""
	detail_text.text = _format_detail(record)
	_populate_history(record)


func _populate_history(record: PSPlayerSeasonRecord) -> void:
	var rows: Array = []
	for past_row in RecordStore.get_player_records(record.player_id):
		var past: PSPlayerSeasonRecord = past_row as PSPlayerSeasonRecord
		var summary_line: String = ""
		if past.is_pitcher():
			summary_line = "%d-%d  防%s" % [
				past.pitcher_stats.wins,
				past.pitcher_stats.losses,
				_format_float(past.pitcher_stats.era(), 2) if past.pitcher_stats.outs_pitched > 0 else "--",
			]
		else:
			summary_line = "打 %s  本%d  点%d" % [
				_format_rate(past.batter_stats.batting_average()),
				past.batter_stats.home_runs,
				past.batter_stats.runs_batted_in,
			]
		rows.append({
			"year": past.year,
			"season_number": past.season_number,
			"team": _team_short(past.team_id),
			"age": past.age,
			"summary": summary_line,
		})
	history_table.set_rows(rows)


# 今期 WAR と内訳を1〜2行で追加する。野手は wRAA/BSR/OAA/Pos/Rep の内訳、
# 投手は FIP / IP を表示。advanced_stats が空 (= 出場なし) の場合は何も追加しない。
# WarCalculator.build_league_context は当該シーズン全選手集計のため呼び出しコストあり。
# 単発表示なので 100ms 程度。後で AppState などにキャッシュするなら最適化可能。
func _append_war_lines(lines: Array, record: PSPlayerSeasonRecord) -> void:
	var ctx: Dictionary = WarCalculator.build_league_context(record.year, record.season_number)
	var war_row: Dictionary = WarCalculator.season_war(record, ctx)
	if war_row.is_empty() or str(war_row.get("role", "")) == "":
		return
	if record.is_pitcher():
		if record.pitcher_stats.outs_pitched <= 0:
			return
		lines.append("WAR %+.2f  FIP %.2f  IP %.1f" % [
			float(war_row.get("war", 0.0)),
			float(war_row.get("fip", 0.0)),
			float(war_row.get("ip", 0.0)),
		])
	else:
		if record.advanced_stats == null or record.advanced_stats.plate_appearances <= 0:
			return
		lines.append("WAR %+.2f  PA %d" % [
			float(war_row.get("war", 0.0)),
			int(war_row.get("pa", 0)),
		])
		lines.append("内訳  打撃 %+.1f  走塁 %+.1f  守備 %+.1f  位置 %+.1f  リプ %+.1f" % [
			float(war_row.get("wraa", 0.0)),
			float(war_row.get("bsr", 0.0)),
			float(war_row.get("oaa_runs", 0.0)),
			float(war_row.get("pos_adj", 0.0)),
			float(war_row.get("replacement_runs", 0.0)),
		])


func _format_detail(record: PSPlayerSeasonRecord) -> String:
	var lines: Array = []
	var team_name: String = _team_short(record.team_id)
	var jersey: String = "#%d  " % record.jersey_number if record.jersey_number > 0 else ""
	lines.append("%s%s  %s  %s" % [jersey, record.name, str(PSPlayer.POSITION_NAMES.get(record.position, "?")), team_name])
	lines.append("%d年 / %d年目  %d歳  %d年目  %dcm %dkg  %s投%s打" % [
		record.year, record.season_number, record.age, record.years,
		record.height, record.weight, _hand_name(record.throwing_hand), _hand_name(record.batting_side),
	])
	lines.append("%s  %s" % [record.registered_roster, record.contract_status])
	lines.append(_contract_line(record))
	lines.append(_evaluation_line(record))
	lines.append("疲労 %d  怪我 %d日  評価 %d" % [record.fatigue, record.injury_days, PlayerValueEvaluator.overall_score(record)])
	if record.injury_days > 0:
		lines.append("故障: %s" % record.injury_display_label())
	lines.append("")

	lines.append("== 能力 ==")
	lines.append(PlayerVisibleRatings.summary_line(record))
	if record.is_pitcher():
		lines.append("球種: %s" % _arsenal_summary_line(record))
	else:
		lines.append("位置適性: %s" % _aptitude_summary(record))
	lines.append("")

	if record.is_pitcher():
		lines.append("== 今期投手成績 ==")
		lines.append("登板 %d  先発 %d  勝敗 %d-%d  H %d  S %d  回 %s" % [
			record.pitcher_stats.games, record.pitcher_stats.starts,
			record.pitcher_stats.wins, record.pitcher_stats.losses,
			record.pitcher_stats.holds, record.pitcher_stats.saves,
			_format_innings(record.pitcher_stats.outs_pitched),
		])
		lines.append("防御率 %s  WHIP %s  奪三振率 %s" % [
			_format_float(record.pitcher_stats.era(), 2),
			_format_float(record.pitcher_stats.whip(), 2),
			_format_float(record.pitcher_stats.strikeouts_per_nine(), 2),
		])
		_append_war_lines(lines, record)
		lines.append("")
		lines.append("== 通算投手成績 ==")
		var career_pitcher: PSPitcherStats = RecordStore.get_player_career_pitcher_stats(record.player_id)
		lines.append("登板 %d  先発 %d  勝敗 %d-%d  H %d  S %d  回 %s" % [
			career_pitcher.games, career_pitcher.starts,
			career_pitcher.wins, career_pitcher.losses,
			career_pitcher.holds, career_pitcher.saves,
			_format_innings(career_pitcher.outs_pitched),
		])
		lines.append("防御率 %s  WHIP %s  奪三振率 %s" % [
			_format_float(career_pitcher.era(), 2),
			_format_float(career_pitcher.whip(), 2),
			_format_float(career_pitcher.strikeouts_per_nine(), 2),
		])
	else:
		lines.append("== 今期野手成績 ==")
		lines.append("試合 %d  打席 %d  打数 %d  安打 %d  二塁 %d  三塁 %d  本塁打 %d  打点 %d" % [
			record.batter_stats.games, record.batter_stats.plate_appearances,
			record.batter_stats.at_bats, record.batter_stats.hits,
			record.batter_stats.doubles, record.batter_stats.triples,
			record.batter_stats.home_runs, record.batter_stats.runs_batted_in,
		])
		lines.append("打率 %s  出塁率 %s  OPS %s  失策 %d" % [
			_format_rate(record.batter_stats.batting_average()),
			_format_rate(record.batter_stats.on_base_percentage()),
			_format_rate(record.batter_stats.ops()),
			record.batter_stats.errors,
		])
		_append_war_lines(lines, record)
		lines.append("")
		lines.append("== 通算野手成績 ==")
		var career_batter: PSBatterStats = RecordStore.get_player_career_batter_stats(record.player_id)
		lines.append("試合 %d  打席 %d  打数 %d  安打 %d  二塁 %d  三塁 %d  本塁打 %d  打点 %d" % [
			career_batter.games, career_batter.plate_appearances,
			career_batter.at_bats, career_batter.hits,
			career_batter.doubles, career_batter.triples,
			career_batter.home_runs, career_batter.runs_batted_in,
		])
		lines.append("打率 %s  出塁率 %s  OPS %s  失策 %d" % [
			_format_rate(career_batter.batting_average()),
			_format_rate(career_batter.on_base_percentage()),
			_format_rate(career_batter.ops()),
			career_batter.errors,
		])

	return "\n".join(lines)


# R4 Step1: 契約 / FA権 / 年俸の行。
func _contract_line(record: PSPlayerSeasonRecord) -> String:
	var status: String
	if record.is_fa_eligible():
		status = "FA可能 (保有権消滅)"
	elif record.fa_remaining_years() == 1:
		status = "FA権間近 (あと1年)"
	else:
		status = "FA権まで%d年" % record.fa_remaining_years()
	return "契約: %s  年俸 %d万円" % [status, record.salary]


func _evaluation_line(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher():
		var pitcher_eval: int = PlayerValueEvaluator.pitching_score(record)
		var field_eval: int = PlayerValueEvaluator.defensive_score_for_position(record, 1)
		return "Eval  Pitch %d  Field %d" % [pitcher_eval, field_eval]
	var best: Dictionary = PlayerValueEvaluator.best_defensive_fit(record)
	var best_position: int = int(best.get("position", record.position))
	var best_defense: int = int(best.get("score", 0))
	return "Eval  Total %d  Bat %d  Def %s%d" % [
		PlayerValueEvaluator.overall_score(record),
		PlayerValueEvaluator.batting_score(record),
		_short_position_name(best_position),
		best_defense,
	]


func _aptitude_summary(record: PSPlayerSeasonRecord) -> String:
	var parts: Array = []
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var apt: int = _position_aptitude(record, position)
		if apt > 0:
			parts.append("%s%d" % [_short_position_name(position), apt])
	if parts.is_empty():
		return "適性なし"
	return " / ".join(parts)


# 投手の変化球アーセナルを「球種名 完成度(S〜D)」で mastery 降順に並べて返す。
func _arsenal_summary_line(record: PSPlayerSeasonRecord) -> String:
	var line: String = PSPitchTypes.arsenal_line(record.arsenal_or_derived())
	return line if not line.is_empty() else "データなし"


func _position_aptitude(record: PSPlayerSeasonRecord, position: int) -> int:
	var key: String = str(POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == position else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _hand_name(value: String) -> String:
	match value:
		"L": return "左"
		"S": return "両"
		_: return "右"


func _format_rate(value: float) -> String:
	return "%0.3f" % value


func _format_float(value: float, digits: int) -> String:
	if digits == 1:
		return "%0.1f" % value
	if digits == 2:
		return "%0.2f" % value
	return "%0.3f" % value


func _format_innings(outs: int) -> String:
	return "%d.%d" % [int(outs / 3), outs % 3]


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
