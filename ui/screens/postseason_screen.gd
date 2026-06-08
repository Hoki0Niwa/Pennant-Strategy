extends Control

const STAGE_LABELS: Dictionary = {
	"cs1_central": "CS1 セ・リーグ (2位 vs 3位)",
	"cs1_pacific": "CS1 パ・リーグ (2位 vs 3位)",
	"cs2_central": "CS2 セ・リーグ (1位 vs CS1勝者)",
	"cs2_pacific": "CS2 パ・リーグ (1位 vs CS1勝者)",
	"japan_series": "日本シリーズ",
}

const SortableTable = preload("res://ui/components/sortable_table.gd")

const GAME_COLUMNS: Array = [
	{"title": "戦", "key": "num", "width": 48, "type": "number", "format": "int"},
	{"title": "ビジター", "key": "away", "width": 72, "type": "string", "format": "string"},
	{"title": "スコア", "key": "score", "width": 64, "type": "string", "format": "string"},
	{"title": "ホーム", "key": "home", "width": 72, "type": "string", "format": "string"},
	{"title": "", "key": "note", "width": 32, "type": "string", "format": "string"},
]

var status_label: Label
var advance_button: Button
var awards_button: Button
var stage_container: VBoxContainer


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
	title.text = "ポストシーズン"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	advance_button = Button.new()
	advance_button.text = "次のシリーズを消化"
	advance_button.custom_minimum_size = Vector2(180, 32)
	advance_button.pressed.connect(_on_advance_pressed)
	header.add_child(advance_button)

	awards_button = Button.new()
	awards_button.text = "表彰へ進む"
	awards_button.custom_minimum_size = Vector2(140, 32)
	awards_button.pressed.connect(_on_awards_pressed)
	header.add_child(awards_button)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	stage_container = VBoxContainer.new()
	stage_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_container.add_theme_constant_override("separation", 10)
	scroll.add_child(stage_container)

	_refresh()


func _refresh() -> void:
	var postseason: PSPostseasonResult = AppState.current_postseason
	for child in stage_container.get_children():
		stage_container.remove_child(child)
		child.queue_free()

	if postseason == null:
		status_label.text = "ポストシーズンが開始されていません"
		advance_button.disabled = true
		awards_button.disabled = true
		return

	var pending: String = postseason.next_pending_stage()
	advance_button.disabled = pending.is_empty()
	awards_button.disabled = not PostseasonService.is_complete(postseason)

	if pending.is_empty():
		status_label.text = "全シリーズ消化済み。表彰画面へ進めます。"
	else:
		status_label.text = "次に消化するシリーズ: %s" % STAGE_LABELS.get(pending, pending)

	for stage_key in PSPostseasonResult.STAGE_KEYS:
		stage_container.add_child(_build_stage_panel(stage_key, postseason.stage_dict(stage_key)))


func _build_stage_panel(stage_key: String, series: Dictionary) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	var completed: bool = bool(series.get("completed", false))
	if completed:
		style.bg_color = Color(0.18, 0.25, 0.32)
		style.border_color = Color(0.40, 0.60, 0.80)
	else:
		style.bg_color = Color(0.13, 0.15, 0.18)
		style.border_color = Color(0.35, 0.38, 0.42)
	style.set_border_width_all(1)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title: Label = Label.new()
	title.text = str(STAGE_LABELS.get(stage_key, stage_key))
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	if series.is_empty():
		var msg: Label = Label.new()
		msg.text = "(対象チームが揃いません)"
		msg.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		box.add_child(msg)
		return panel

	var top_id: int = int(series.get("top_id", 0))
	var chal_id: int = int(series.get("challenger_id", 0))
	var matchup: Label = Label.new()
	matchup.text = "%s (上位) vs %s (挑戦者)" % [_team_short(top_id), _team_short(chal_id)]
	matchup.add_theme_font_size_override("font_size", 14)
	box.add_child(matchup)

	if completed:
		var winner_id: int = int(series.get("winner_id", 0))
		var top_wins: int = int(series.get("top_wins_final", 0))
		var chal_wins: int = int(series.get("challenger_wins_final", 0))
		var result_label: Label = Label.new()
		result_label.text = "勝者: %s   (%d勝-%d敗)" % [_team_short(winner_id), top_wins if winner_id == top_id else chal_wins, chal_wins if winner_id == top_id else top_wins]
		result_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.50))
		result_label.add_theme_font_size_override("font_size", 16)
		box.add_child(result_label)

		var games: Array = series.get("games", []) as Array
		if not games.is_empty():
			var table: Tree = SortableTable.new()
			table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			table.custom_minimum_size = Vector2(0, (games.size() + 2) * 26)
			box.add_child(table)
			table.configure(GAME_COLUMNS, false)
			var rows: Array = []
			for game_row in games:
				var game: Dictionary = game_row as Dictionary
				rows.append({
					"num": int(game.get("game_num", 0)),
					"away": _team_short(int(game.get("away_id", 0))),
					"score": "%d-%d" % [int(game.get("away_score", 0)), int(game.get("home_score", 0))],
					"home": _team_short(int(game.get("home_id", 0))),
					"note": "△" if bool(game.get("draw", false)) else "",
				})
			table.set_rows(rows)
	else:
		var advantage: int = int(series.get("advantage_wins", 0))
		var target: int = int(series.get("win_target", 4))
		var pending_msg: Label = Label.new()
		var advantage_text: String = "  (1位 +%d勝アドバンテージ)" % advantage if advantage > 0 else ""
		if chal_id == 0:
			pending_msg.text = "%d戦先勝制%s  ※ 挑戦者は前シリーズ勝者で決定" % [target - advantage, advantage_text]
		else:
			pending_msg.text = "%d戦先勝制%s  待機中" % [target - advantage, advantage_text]
		pending_msg.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		box.add_child(pending_msg)

	return panel


func _on_advance_pressed() -> void:
	var result: Dictionary = AppState.advance_next_postseason_stage()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", ""))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	_refresh()


func _on_awards_pressed() -> void:
	var result: Dictionary = AppState.finalize_postseason_to_awards()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", ""))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))


func _team_short(team_id: int) -> String:
	if team_id <= 0:
		return "(未定)"
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name
