extends Control

const BATTING_TITLE_LABELS: Dictionary = {
	"average": "首位打者",
	"home_runs": "本塁打王",
	"rbi": "打点王",
	"stolen_bases": "盗塁王",
	"hits": "最多安打",
}

const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "最多勝利",
	"era": "最優秀防御率",
	"strikeouts": "最多奪三振",
	"saves": "最多セーブ",
	"holds": "最多ホールド",
	"win_rate": "最高勝率",
}

var content_box: VBoxContainer
var status_label: Label


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
	title.text = "年間表彰"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var offseason_button: Button = Button.new()
	offseason_button.text = "オフシーズンへ"
	offseason_button.custom_minimum_size = Vector2(140, 32)
	offseason_button.pressed.connect(_on_offseason_pressed)
	header.add_child(offseason_button)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	content_box = VBoxContainer.new()
	content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_box.add_theme_constant_override("separation", 12)
	scroll.add_child(content_box)

	_render()


func _render() -> void:
	for child in content_box.get_children():
		content_box.remove_child(child)
		child.queue_free()

	var awards: PSAwards = AppState.current_awards
	var postseason: PSPostseasonResult = AppState.current_postseason
	if awards == null:
		status_label.text = "表彰データがありません"
		return

	status_label.text = "%d年 / %d年目" % [awards.year, awards.season_number]

	# Champion section
	if postseason != null and postseason.champion_team_id > 0:
		content_box.add_child(_build_champion_section(postseason))

	# MVP / Rookie
	content_box.add_child(_build_mvp_section(awards))

	# Batting titles
	content_box.add_child(_build_title_section("打撃タイトル", awards.batting_titles, BATTING_TITLE_LABELS, false))

	# Pitching titles
	content_box.add_child(_build_title_section("投手タイトル", awards.pitching_titles, PITCHING_TITLE_LABELS, true))


func _build_champion_section(postseason: PSPostseasonResult) -> PanelContainer:
	var panel: PanelContainer = _make_panel(Color(0.25, 0.20, 0.10), Color(1.0, 0.85, 0.40))
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title: Label = Label.new()
	title.text = "★ 日本一 ★"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.40))
	box.add_child(title)

	var team_name: String = _team_full_name(postseason.champion_team_id)
	var champ_label: Label = Label.new()
	champ_label.text = team_name
	champ_label.add_theme_font_size_override("font_size", 28)
	box.add_child(champ_label)

	var js: Dictionary = postseason.japan_series
	if not js.is_empty():
		var top_wins: int = int(js.get("top_wins_final", 0))
		var chal_wins: int = int(js.get("challenger_wins_final", 0))
		var winner_is_top: bool = int(js.get("winner_id", 0)) == int(js.get("top_id", 0))
		var w: int = top_wins if winner_is_top else chal_wins
		var l: int = chal_wins if winner_is_top else top_wins
		var detail: Label = Label.new()
		detail.text = "日本シリーズ %d勝%d敗" % [w, l]
		box.add_child(detail)

	return panel


func _build_mvp_section(awards: PSAwards) -> PanelContainer:
	var panel: PanelContainer = _make_panel(Color(0.13, 0.18, 0.25), Color(0.50, 0.70, 0.95))
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title: Label = Label.new()
	title.text = "MVP / 新人王"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.50, 0.70, 0.95))
	box.add_child(title)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	grid.add_child(_award_header("賞"))
	grid.add_child(_award_header("セ・リーグ"))
	grid.add_child(_award_header("パ・リーグ"))

	grid.add_child(_award_text("MVP"))
	grid.add_child(_player_link(awards.mvp_central_player_id))
	grid.add_child(_player_link(awards.mvp_pacific_player_id))

	grid.add_child(_award_text("新人王"))
	grid.add_child(_player_link(awards.rookie_central_player_id))
	grid.add_child(_player_link(awards.rookie_pacific_player_id))

	return panel


func _build_title_section(title_text: String, titles: Dictionary, label_map: Dictionary, is_pitcher: bool) -> PanelContainer:
	var panel: PanelContainer = _make_panel(Color(0.13, 0.18, 0.25), Color(0.50, 0.80, 0.55))
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title: Label = Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.50, 0.80, 0.55))
	box.add_child(title)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	grid.add_child(_award_header("部門"))
	grid.add_child(_award_header("セ・リーグ"))
	grid.add_child(_award_header("パ・リーグ"))

	var central: Dictionary = titles.get("central", {}) as Dictionary
	var pacific: Dictionary = titles.get("pacific", {}) as Dictionary

	var keys_order: Array
	if is_pitcher:
		keys_order = PSAwards.PITCHING_CATEGORIES
	else:
		keys_order = PSAwards.BATTING_CATEGORIES

	for key in keys_order:
		grid.add_child(_award_text(str(label_map.get(key, key))))
		grid.add_child(_player_title_link(int(central.get(key, 0)), key, is_pitcher))
		grid.add_child(_player_title_link(int(pacific.get(key, 0)), key, is_pitcher))

	return panel


func _make_panel(bg_color: Color, border_color: Color) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.border_color = border_color
	style.set_border_width_all(1)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _award_header(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	label.custom_minimum_size = Vector2(140, 22)
	return label


func _award_text(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(140, 22)
	return label


func _player_link(player_id: int) -> Button:
	var button: Button = Button.new()
	button.custom_minimum_size = Vector2(220, 26)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if player_id <= 0:
		button.text = "(該当なし)"
		button.disabled = true
		return button
	var record: PSPlayerSeasonRecord = _player_record(player_id)
	if record == null:
		button.text = "ID %d" % player_id
	else:
		button.text = "%s (%s)" % [record.name, _team_short(record.team_id)]
	button.pressed.connect(func() -> void: AppState.show_player_detail(player_id))
	return button


func _player_title_link(player_id: int, title_key: String, is_pitcher: bool) -> Button:
	var button: Button = Button.new()
	button.custom_minimum_size = Vector2(220, 26)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if player_id <= 0:
		button.text = "(該当なし)"
		button.disabled = true
		return button
	var record: PSPlayerSeasonRecord = _player_record(player_id)
	if record == null:
		button.text = "ID %d" % player_id
	else:
		var value_text: String = _title_value(record, title_key, is_pitcher)
		button.text = "%s (%s)  %s" % [record.name, _team_short(record.team_id), value_text]
	button.pressed.connect(func() -> void: AppState.show_player_detail(player_id))
	return button


func _title_value(record: PSPlayerSeasonRecord, title_key: String, is_pitcher: bool) -> String:
	if is_pitcher:
		var ps: PSPitcherStats = record.pitcher_stats
		match title_key:
			"wins": return "%d勝" % ps.wins
			"era":
				if ps.outs_pitched <= 0: return "--"
				return "%0.2f" % ps.era()
			"strikeouts": return "%d奪三振" % ps.strikeouts
			"saves": return "%dS" % ps.saves
			"holds": return "%dH" % ps.holds
			"win_rate":
				var dec: int = ps.wins + ps.losses
				if dec <= 0: return "--"
				return ".%03d" % int(round(float(ps.wins) / float(dec) * 1000))
			_: return ""
	var bs: PSBatterStats = record.batter_stats
	match title_key:
		"average": return ".%03d" % int(round(bs.batting_average() * 1000))
		"home_runs": return "%d本" % bs.home_runs
		"rbi": return "%d点" % bs.runs_batted_in
		"stolen_bases": return "%d盗塁" % bs.stolen_bases
		"hits": return "%d安打" % bs.hits
		_: return ""


func _player_record(player_id: int) -> PSPlayerSeasonRecord:
	var season: PSSeason = AppState.current_season
	if season == null:
		return null
	return RecordStore.get_player_record(player_id, season.year, season.season_number)


func _team_short(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _team_full_name(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.name


func _on_offseason_pressed() -> void:
	var result: Dictionary = AppState.start_offseason()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", ""))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
