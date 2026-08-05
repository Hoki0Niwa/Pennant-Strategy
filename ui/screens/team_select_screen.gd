extends "res://ui/components/dashboard_screen.gd"

# チーム選択画面。ゲーム開始前フローなのでサイドバーは出さず、全チームカードと開始ボタンだけを描く。
# 第1リーグ(league1)を左カラム、第2リーグ(league2)を右カラムに 2 列ずつ並べる。
# カードをクリックで選択し、ヘッダの「このチームで開始」ボタン 1 つで開始する。

const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")

const MARGIN: float = 48.0
const CENTER_GAP: float = 40.0
const LEAGUE_W: float = (BASE.x - 2.0 * MARGIN - CENTER_GAP) / 2.0
const LEFT_X: float = MARGIN
const RIGHT_X: float = MARGIN + LEAGUE_W + CENTER_GAP
const LEAGUE_HEADER_Y: float = 150.0
const CARD_TOP: float = 172.0
const COLS: int = 2
const GAP: float = 18.0

# 各リーグの {team, bat, pitch, controlled, dev} を _ready でキャッシュ (毎フレーム再計算しない)。
var _league1: Array = []
var _league2: Array = []
var _selected_team_id: int = 0


func _ready() -> void:
	_init_chrome()
	_build_infos()
	_build_buttons()
	queue_redraw()


func _build_infos() -> void:
	_league1.clear()
	_league2.clear()
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var info: Dictionary = {
			"team": team,
			"bat": _team_batting_rating(team.id),
			"pitch": _team_pitching_rating(team.id),
			"controlled": TeamFinance.controlled_count(GameDb.players, team.id),
			"dev": TeamFinance.development_count(GameDb.players, team.id),
		}
		if team.league == "league1":
			_league1.append(info)
		else:
			_league2.append(info)
	if _selected_team_id <= 0:
		var first: Array = _league1 if not _league1.is_empty() else _league2
		if not first.is_empty():
			_selected_team_id = ((first[0] as Dictionary)["team"] as PSTeam).id


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_round(Rect2(0, 0, BASE.x, 4), Color(BLUE.r, BLUE.g, BLUE.b, 0.85), Color.TRANSPARENT, 0, 0)

	_text("チーム選択", Vector2(MARGIN, 66), 30, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	var selected: PSTeam = _selected_team()
	var sub: String = "選択中: %s" % selected.name if selected != null else "操作する球団を選んでください"
	_text(sub, Vector2(MARGIN + 2, 96), 15, MUTED if selected == null else BLUE)

	_draw_league(LEFT_X, _league1, _league_label(_league1, "第1リーグ"))
	_draw_league(RIGHT_X, _league2, _league_label(_league2, "第2リーグ"))


func _draw_league(area_x: float, infos: Array, label: String) -> void:
	_round(Rect2(area_x, LEAGUE_HEADER_Y - 16.0, 4.0, 18.0), BLUE, Color.TRANSPARENT, 2, 0)
	_text(label, Vector2(area_x + 14.0, LEAGUE_HEADER_Y), 18, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	for i in range(infos.size()):
		_draw_card(_league_card_rect(area_x, i, infos.size()), infos[i] as Dictionary)


func _league_card_rect(area_x: float, idx: int, n: int) -> Rect2:
	var rows: int = int(ceil(float(n) / float(COLS)))
	var area_h: float = BASE.y - CARD_TOP - 48.0
	var cw: float = (LEAGUE_W - float(COLS - 1) * GAP) / float(COLS)
	var ch: float = (area_h - float(rows - 1) * GAP) / float(max(rows, 1))
	var col: int = idx % COLS
	var row: int = idx / COLS
	return Rect2(area_x + float(col) * (cw + GAP), CARD_TOP + float(row) * (ch + GAP), cw, ch)


func _draw_card(rect: Rect2, info: Dictionary) -> void:
	var team: PSTeam = info["team"] as PSTeam
	var selected: bool = team.id == _selected_team_id
	_round(rect, PANEL_2 if selected else PANEL, BLUE if selected else BORDER, 12, 2 if selected else 1)
	# チームカラーの左アクセントバー
	_round(Rect2(rect.position.x, rect.position.y + 12.0, 5.0, rect.size.y - 24.0), team.color, Color.TRANSPARENT, 3, 0)

	_team_badge(Rect2(rect.position.x + 22.0, rect.position.y + 20.0, 46.0, 46.0), team)
	_text(team.name, Vector2(rect.position.x + 80.0, rect.position.y + 44.0), 20, TEXT, rect.size.x - 96.0)
	_text("前年 %d位" % team.previous_rank, Vector2(rect.position.x + 80.0, rect.position.y + 68.0), 12, MUTED, rect.size.x - 96.0)
	if selected:
		_chip(Rect2(rect.end.x - 76.0, rect.position.y + 18.0, 58.0, 22.0), "選択中", BLUE)

	_line(Vector2(rect.position.x + 18.0, rect.position.y + 92.0), Vector2(rect.end.x - 18.0, rect.position.y + 92.0), BORDER_SOFT, 1.0)

	_draw_bar(rect.position.x + 18.0, rect.position.y + 112.0, rect.size.x - 36.0, "打撃", int(info["bat"]), BLUE)
	_draw_bar(rect.position.x + 18.0, rect.position.y + 146.0, rect.size.x - 36.0, "投手", int(info["pitch"]), RED)

	_text("支配下 %d名 ・ 育成 %d名" % [int(info["controlled"]), int(info["dev"])],
		Vector2(rect.position.x + 18.0, rect.position.y + 194.0), 12, MUTED, rect.size.x - 36.0)


func _draw_bar(x: float, y: float, w: float, label: String, value: int, color: Color) -> void:
	_text(label, Vector2(x, y + 13.0), 12, MUTED)
	var bx: float = x + 50.0
	var bw: float = w - 50.0 - 42.0
	_round(Rect2(bx, y + 2.0, bw, 12.0), PANEL_3, Color.TRANSPARENT, 6, 0)
	var frac: float = clampf(float(value) / 100.0, 0.0, 1.0)
	if frac > 0.0:
		_round(Rect2(bx, y + 2.0, bw * frac, 12.0), color, Color.TRANSPARENT, 6, 0)
	_text_right(str(value), x + w, y + 13.0, 13, TEXT, 40.0)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	var back_rect: Rect2 = Rect2(BASE.x - MARGIN - 110.0, 40.0, 110.0, 42.0)
	var start_rect: Rect2 = Rect2(back_rect.position.x - 16.0 - 230.0, 40.0, 230.0, 42.0)
	var start_button: Button = _add_button("start", "このチームで開始", start_rect, _start_selected, "primary")
	start_button.disabled = _selected_team_id <= 0
	_add_button("back", "戻る", back_rect, func() -> void: AppState.request_screen("start"), "action")

	# カード全体を透明ボタンで覆い、クリックで選択する。
	_add_select_buttons(LEFT_X, _league1)
	_add_select_buttons(RIGHT_X, _league2)

	_layout_buttons()


func _add_select_buttons(area_x: float, infos: Array) -> void:
	for i in range(infos.size()):
		var team: PSTeam = (infos[i] as Dictionary)["team"] as PSTeam
		_add_button("sel_%d" % team.id, "", _league_card_rect(area_x, i, infos.size()),
			func(tid: int = team.id) -> void: _on_select(tid), "select")


# ============================================================ actions

func _on_select(team_id: int) -> void:
	_selected_team_id = team_id
	_build_buttons()
	queue_redraw()


func _start_selected() -> void:
	if _selected_team_id <= 0:
		return
	AppState.select_team(_selected_team_id)
	AppState.start_new_season()


func _selected_team() -> PSTeam:
	for info_value in _league1 + _league2:
		var team: PSTeam = (info_value as Dictionary)["team"] as PSTeam
		if team.id == _selected_team_id:
			return team
	return null


func _league_label(infos: Array, fallback: String) -> String:
	if infos.is_empty():
		return fallback
	var label: String = ((infos[0] as Dictionary)["team"] as PSTeam).league_label()
	return label if not label.is_empty() else fallback


# ============================================================ rating helpers

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
