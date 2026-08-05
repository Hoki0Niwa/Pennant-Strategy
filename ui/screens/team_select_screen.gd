extends "res://ui/components/dashboard_screen.gd"

# チーム選択画面。ゲーム開始前フローなのでサイドバーは出さず、全チームカードと開始ボタンだけを描く。
# 第1リーグ(league1)を左カラム、第2リーグ(league2)を右カラムに 2 列ずつ並べる。
# カードをクリックで選択し、ヘッダの「このチームで開始」ボタン 1 つで開始する。
#
# 各カードは球団の戦力を6項目 (先発 / 中継 / 控え / 打撃 / 守備 / 将来性) の S〜E グレードで示す。
# **数値やバーは出さない** — 12球団の生の評価値は数点差に収まり、数字でもバー長でも差が読めない
# ([[project_strength_grade]])。グレードはいずれも全12球団を母集団にした相対評価。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

const MARGIN: float = 48.0
const CENTER_GAP: float = 40.0
const LEAGUE_W: float = (BASE.x - 2.0 * MARGIN - CENTER_GAP) / 2.0
const LEFT_X: float = MARGIN
const RIGHT_X: float = MARGIN + LEAGUE_W + CENTER_GAP
const LEAGUE_HEADER_Y: float = 150.0
const CARD_TOP: float = 172.0
const COLS: int = 2
const GAP: float = 18.0

# 打撃の母数 = スタメン9人。控えの母数 = **そのスタメンから漏れた一軍の野手**。
# 一軍31人 ≒ 投手15 + 野手16 なので、スタメン9人を除いた 7 人が控え野手にあたる
# (投手の層は先発/中継で見ているので控えには混ぜない)。
const LINEUP_COUNT: int = 9
const BENCH_COUNT: int = 7

# カード内のグレード表示: 横3項目 × 縦2段。GRADE_ROWS の並び順のまま左→右→次段へ流す
# (上段=投手系+控え / 下段=野手系+将来性)。
# 項目名とグレードは GRADE_LABEL_W だけ離した**近接した1組**として置く — 列いっぱいに離すと
# どのグレードがどの項目か読み取れない。
const GRADE_COLS: int = 3
const GRADE_ROWS: Array = [
	{"key": "starter", "label": "先発"},
	{"key": "relief", "label": "中継"},
	{"key": "bench", "label": "控え"},
	{"key": "batting", "label": "打撃"},
	{"key": "defense", "label": "守備"},
	{"key": "future", "label": "若手"},
]
const GRADE_ROW_H: float = 50.0
const GRADE_TOP: float = 132.0
# グレードは GRADE_FS、項目名はそれより一段小さい GRADE_LABEL_FS。同サイズにすると
# 和文の項目名のほうが字面が大きく見えて主役のグレードが埋もれる。
# GRADE_LABEL_W はラベル2文字ぶん + グレードとの間隔。
const GRADE_FS: int = 19
const GRADE_LABEL_FS: int = 16
const GRADE_LABEL_W: float = 48.0
const GRADE_VALUE_W: float = 28.0

# 各リーグの {team, controlled, dev, <key>, <key>_grade …} を _ready でキャッシュ
# (毎フレーム再計算しない)。
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
	# 先発 / 中継 / 控え / 将来性 は [[TeamDepthChart]] の役割スロットをそのまま使う
	# (一軍で実際に使う枠数と将来予測の定義をデプスチャート画面と共有するため)。
	var charts: Dictionary = TeamDepthChart.build_league(GameDb.players, GameDb.teams)
	var infos: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var chart: Dictionary = charts.get(team.id, {}) as Dictionary
		infos.append({
			"team": team,
			"starter": _slot_metric(chart, TeamDepthChart.SLOT_STARTER, "first_team_value"),
			"relief": _slot_metric(chart, TeamDepthChart.SLOT_RELIEVER, "first_team_value"),
			"bench": _team_bench_score(team.id),
			"batting": _team_batting_score(team.id),
			"defense": _team_defense_score(team.id),
			"future": _team_future_score(chart),
			"controlled": TeamFinance.controlled_count(GameDb.players, team.id),
			"dev": TeamFinance.development_count(GameDb.players, team.id),
		})
	for row_value in GRADE_ROWS:
		_assign_grades(infos, str((row_value as Dictionary)["key"]))
	for info_value in infos:
		var info: Dictionary = info_value as Dictionary
		if (info["team"] as PSTeam).league == "league1":
			_league1.append(info)
		else:
			_league2.append(info)
	if _selected_team_id <= 0:
		var first: Array = _league1 if not _league1.is_empty() else _league2
		if not first.is_empty():
			_selected_team_id = ((first[0] as Dictionary)["team"] as PSTeam).id


# infos の value_key を母集団として S〜E を求め、<value_key>_grade へ書き戻す。
func _assign_grades(infos: Array, value_key: String) -> void:
	var sample: Array = []
	for info_value in infos:
		sample.append(float((info_value as Dictionary).get(value_key, 0.0)))
	for info_value in infos:
		var info: Dictionary = info_value as Dictionary
		info["%s_grade" % value_key] = StrengthGrade.from_sample(float(info.get(value_key, 0.0)), sample)


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
	_text(team.name, Vector2(rect.position.x + 80.0, rect.position.y + 44.0), 23, TEXT, rect.size.x - 96.0)
	_text("前年 %d位" % team.previous_rank, Vector2(rect.position.x + 80.0, rect.position.y + 70.0), 14, MUTED, rect.size.x - 96.0)
	if selected:
		_chip(Rect2(rect.end.x - 82.0, rect.position.y + 18.0, 64.0, 24.0), "選択中", BLUE)

	_line(Vector2(rect.position.x + 18.0, rect.position.y + 92.0), Vector2(rect.end.x - 18.0, rect.position.y + 92.0), BORDER_SOFT, 1.0)

	_draw_grades(rect, info)

	_text("支配下 %d名 ・ 育成 %d名" % [int(info["controlled"]), int(info["dev"])],
		Vector2(rect.position.x + 18.0, rect.position.y + 246.0), 14, MUTED, rect.size.x - 36.0)


# 6項目のグレードを 横 GRADE_COLS 項目 × 縦2段 で置く。値は S〜E の1文字だけ。
# 項目名とグレードは近接した1組として置く — 列幅いっぱいに離すと対応が読めない。
func _draw_grades(rect: Rect2, info: Dictionary) -> void:
	var inner_x: float = rect.position.x + 18.0
	var col_w: float = (rect.size.x - 36.0) / float(GRADE_COLS)
	for i in range(GRADE_ROWS.size()):
		var row: Dictionary = GRADE_ROWS[i] as Dictionary
		var x: float = inner_x + float(i % GRADE_COLS) * col_w
		@warning_ignore("integer_division")
		var y: float = rect.position.y + GRADE_TOP + GRADE_ROW_H * float(i / GRADE_COLS)
		var grade: String = str(info.get("%s_grade" % str(row["key"]), "-"))
		_text(str(row["label"]), Vector2(x, y), GRADE_LABEL_FS, MUTED, GRADE_LABEL_W)
		_text(grade, Vector2(x + GRADE_LABEL_W, y), GRADE_FS, _strength_grade_color(grade),
			GRADE_VALUE_W, HORIZONTAL_ALIGNMENT_LEFT, true)


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


# ============================================================ 戦力指標
# いずれも「グレード化する前の生値」。母集団 (全12球団) 内での相対位置しか使わないので、
# 指標どうしで尺度が揃っている必要はない (先発と打撃を直接比べることはない)。

# デプスチャートのスロット指標をそのまま読む (先発/中継の一軍枠の質)。
func _slot_metric(chart: Dictionary, slot_key: String, metric_key: String) -> float:
	var slots: Dictionary = chart.get("slots", {}) as Dictionary
	return float((slots.get(slot_key, {}) as Dictionary).get(metric_key, 0.0))


# 控え = **スタメンから漏れた一軍の野手**の評価平均。総合評価順に並べてスタメン相当の
# LINEUP_COUNT 人を除き、続く BENCH_COUNT 人 (= 一軍が抱える控え野手) を数える。
# ⚠️ 二軍相当まで含めると「層の厚さ」になってしまい、代打・守備固めの質を表さない。
func _team_bench_score(team_id: int) -> float:
	var scores: Array = _controlled_fielder_scores(team_id,
		func(player: PSPlayer) -> float: return float(OffseasonService.player_value_score(player)))
	scores.sort()
	scores.reverse()
	var total: float = 0.0
	var used: int = 0
	for index in range(LINEUP_COUNT, mini(LINEUP_COUNT + BENCH_COUNT, scores.size())):
		total += float(scores[index])
		used += 1
	return total / float(maxi(1, used))


# 打撃 = 打力上位 LINEUP_COUNT 人 (≒スタメン) の打撃スコア平均。守備は含めない。
func _team_batting_score(team_id: int) -> float:
	var scores: Array = _controlled_fielder_scores(team_id,
		func(player: PSPlayer) -> float:
			return float(PlayerValueEvaluator.batting_score(PSPlayerSeasonRecord.from_player(player, 0, 0)))
	)
	return _top_average(scores, LINEUP_COUNT)


# 守備 = **各守備位置で最良の選手の守備スコア**の平均 = 「組める守備陣の質」。
# 全野手の平均にすると層の厚い球団が有利になりすぎるため、ポジションごとに1人だけ数える。
func _team_defense_score(team_id: int) -> float:
	var best_by_position: Dictionary = {}
	for player_row in GameDb.get_players_for_team(team_id):
		var player: PSPlayer = player_row as PSPlayer
		if not _is_controlled_fielder(player):
			continue
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
		for position in range(2, 10):
			var score: float = float(PlayerValueEvaluator.defensive_score_for_position(record, position))
			if score > float(best_by_position.get(position, 0.0)):
				best_by_position[position] = score
	var total: float = 0.0
	for position in range(2, 10):
		total += float(best_by_position.get(position, 0.0))
	return total / 8.0


# 一軍に出せる野手 = 支配下の現役野手 (育成は一軍登録できないので除く)。
func _is_controlled_fielder(player: PSPlayer) -> bool:
	return player != null and not player.is_pitcher() and not player.is_retired() and not player.development_player


func _controlled_fielder_scores(team_id: int, score_of: Callable) -> Array:
	var scores: Array = []
	for player_row in GameDb.get_players_for_team(team_id):
		var player: PSPlayer = player_row as PSPlayer
		if _is_controlled_fielder(player):
			scores.append(float(score_of.call(player)))
	return scores


# 将来性 = 全スロットの将来値 (数年後の一軍枠の質) の合計。デプスチャート画面の
# 「将来性」と同じ定義 ([[project_team_depth_chart]])。
func _team_future_score(chart: Dictionary) -> float:
	var total: float = 0.0
	for slot_key in TeamDepthChart.all_slot_keys():
		total += _slot_metric(chart, str(slot_key), "future_value")
	return total


func _top_average(scores: Array, max_count: int) -> float:
	if scores.is_empty():
		return 0.0
	scores.sort()
	scores.reverse()
	var count: int = int(min(scores.size(), max_count))
	var total: float = 0.0
	for index in range(count):
		total += float(scores[index])
	return total / float(count)
