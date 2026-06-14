extends Control

const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 14)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "チーム選択"
	title.add_theme_font_size_override("font_size", 28)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var back_button: Button = Button.new()
	back_button.text = "戻る"
	back_button.custom_minimum_size = Vector2(96, 36)
	back_button.pressed.connect(func() -> void: AppState.request_screen("start"))
	header.add_child(back_button)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	scroll.add_child(grid)

	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		grid.add_child(_create_team_card(team))


func _create_team_card(team: PSTeam) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(260, 210)

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.13)
	style.border_color = team.color
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var name_label: Label = Label.new()
	name_label.text = team.name
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(name_label)

	var league_label: Label = Label.new()
	league_label.text = "%s / 前年%d位" % [team.league_label(), team.previous_rank]
	box.add_child(league_label)

	var rating_label: Label = Label.new()
	rating_label.text = "Bat %d  Pitch %d" % [
		_team_batting_rating(team.id),
		_team_pitching_rating(team.id),
	]
	rating_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(rating_label)

	var roster_label: Label = Label.new()
	roster_label.text = "支配下 %d名 / 育成 %d名" % [
		TeamFinance.shienka_count(GameDb.players, team.id),
		TeamFinance.development_count(GameDb.players, team.id),
	]
	box.add_child(roster_label)

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	var start_button: Button = Button.new()
	start_button.text = "このチームで開始"
	start_button.custom_minimum_size = Vector2(0, 38)
	start_button.pressed.connect(_start_with_team.bind(team.id))
	box.add_child(start_button)

	return panel


func _start_with_team(team_id: int) -> void:
	AppState.select_team(team_id)
	AppState.start_new_season()


func _team_batting_rating(team_id: int) -> int:
	var scores: Array = []
	for player_row in GameDb.get_players_for_team(team_id):
		var player: PSPlayer = player_row as PSPlayer
		if player.is_pitcher():
			continue
		scores.append(_player_batting_rating(player))
	return _top_average(scores, 9)


func _team_pitching_rating(team_id: int) -> int:
	var scores: Array = []
	for player_row in GameDb.get_players_for_team(team_id):
		var player: PSPlayer = player_row as PSPlayer
		if not player.is_pitcher():
			continue
		scores.append(_player_pitching_rating(player))
	return _top_average(scores, 12)


func _player_batting_rating(player: PSPlayer) -> int:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	var total: int = PlayerVisibleRatings.fielder_contact(record)
	total += PlayerVisibleRatings.fielder_power(record)
	total += PlayerVisibleRatings.fielder_speed(record)
	total += PlayerVisibleRatings.fielder_defense(record)
	total += PlayerVisibleRatings.fielder_arm(record)
	total += PlayerVisibleRatings.fielder_discipline(record)
	return int(round(float(total) / 6.0))


func _player_pitching_rating(player: PSPlayer) -> int:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	var velocity_score: int = clampi(PlayerVisibleRatings.pitcher_velocity(record) - 70, 1, 100)
	var total: int = velocity_score
	total += PlayerVisibleRatings.pitcher_stuff(record)
	total += PlayerVisibleRatings.pitcher_control(record)
	total += PlayerVisibleRatings.pitcher_stamina(record)
	return int(round(float(total) / 4.0))


func _top_average(scores: Array, max_count: int) -> int:
	if scores.is_empty():
		return 0
	scores.sort()
	scores.reverse()
	var count: int = int(min(scores.size(), max_count))
	var total: int = 0
	for index in range(count):
		total += int(scores[index])
	return int(round(float(total) / float(count)))
