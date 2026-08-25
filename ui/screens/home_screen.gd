extends "res://ui/components/dashboard_screen.gd"

# ホーム画面。サイドバーとヘッダは dashboard_screen に任せ、
# 本ファイルはチームサマリー、月間カレンダー、右カラムの進行アクションだけを描画・操作する。
# カレンダーは SeasonCalendar の日付情報と schedule を突き合わせ、試合状態ごとにフィルタ表示する。

const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")

# --- ホーム固有レイアウト基準 (base 座標) ---
const STAT_Y: float = 104.0
const STAT_H: float = 84.0
const CAL_RECT: Rect2 = Rect2(262, 206, 1020, 854)
const RIGHT_X: float = 1300.0
const RIGHT_W: float = 600.0

# カレンダー見出し ("YYYY年 M月") と月送り矢印の位置合わせ用。矢印は固定座標だと
# 2桁月 (10-12月) で見出しに衝突するため、‹ は固定・› は見出しの実測幅から算出する。
const CAL_TITLE_X: float = CAL_RECT.position.x + 60.0
const CAL_TITLE_SIZE: int = 23
const CAL_NAV_GAP: float = 12.0

const WEEKDAYS: Array = ["月", "火", "水", "木", "金", "土", "日"]

const FILTERS: Array = [
	{"id": "all", "label": "全試合"},
	{"id": "team", "label": "自軍のみ"},
	{"id": "unplayed", "label": "未消化"},
	{"id": "result", "label": "結果"},
]

# 勝敗は図形で描く (白星=○→白丸 / 黒星=●→黒丸+白縁)。mark は意味どおりの記号を持たせ、
# 見た目の塗り分けは _draw_result_mark に任せる。色は引分のみ使用 (○● は図形側で固定)。
const LEGEND: Array = [
	{"label": "勝利", "color": TEXT, "mark": "○"},
	{"label": "敗戦", "color": TEXT, "mark": "●"},
	{"label": "引分", "color": AMBER, "mark": "△"},
	{"label": "未消化", "color": BLUE, "mark": ""},
	{"label": "休養・移動日", "color": FAINT, "mark": ""},
]

var _calendar_year: int = 0
var _calendar_month: int = 0
var _calendar_filter: String = "team"
var _status_text: String = ""
var _era_by_team: Dictionary = {}
var _skip_button: Button = null
var _inline_skip_active: bool = false
var _inline_skip_days: int = 0


func _ready() -> void:
	_init_chrome()
	_status_text = AppState.last_status_message
	var season: PSSeason = AppState.current_season
	if season != null:
		var date_data: Dictionary = _parse_date(SeasonCalendar.current_date(season))
		_calendar_year = int(date_data.get("year", season.year))
		_calendar_month = int(date_data.get("month", 3))
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_draw_empty()
		return

	_era_by_team = _compute_team_era(season)

	_draw_shell("ホーム", team, season)
	_draw_statbar(team, season)
	_draw_calendar(team.id, season)
	_draw_right_column(team.id, season)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1076), 12, MUTED)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text("新規シーズンが開始されていません", Vector2(770, 496), 20, MUTED)


func _calendar_title_text() -> String:
	return "%d年 %d月" % [_calendar_year, _calendar_month]


# --- サマリー KPI 帯 ---

func _draw_statbar(team: PSTeam, season: PSSeason) -> void:
	var stats: PSStats = season.standings.get(team.id) as PSStats
	var standing: Dictionary = _standing_for_team(team.id)
	var payroll: int = TeamFinance.team_payroll(GameDb.players, team.id)
	var over: bool = TeamFinance.is_over_budget(team.funds, payroll)
	var wins: int = stats.wins if stats != null else 0
	var losses: int = stats.losses if stats != null else 0
	var draws: int = stats.draws if stats != null else 0
	var gb_value: float = float(standing.get("gb", 0.0))

	# 個別カード列ではなく1本の帯 (_stat_strip)。順位/勝率のみ色で強調し、
	# 予算超過は年俸総額セルの note で警告する。
	var cells: Array = [
		{"label": "順位", "value": "%s位" % str(standing.get("rank", "-")), "color": BLUE},
		{"label": "勝敗", "value": "%d勝 %d敗 %d分" % [wins, losses, draws]},
		{"label": "勝率", "value": _rate_short(stats.win_rate() if stats != null else 0.0), "color": GREEN},
		{"label": "ゲーム差", "value": ("-" if gb_value <= 0.0 else _float1(gb_value))},
		{"label": "残り試合", "value": "%d試合" % season.team_games_remaining(team.id)},
		{"label": "予算", "value": _format_money(team.funds)},
		{"label": "年俸総額", "value": _format_money(payroll), "color": AMBER if over else TEXT,
			"note": "予算超過" if over else "", "note_color": AMBER},
	]
	_stat_strip(Rect2(INNER_L, STAT_Y, INNER_R - INNER_L, STAT_H), cells)


# --- カレンダー ---

func _draw_calendar(team_id: int, season: PSSeason) -> void:
	_round(CAL_RECT, PANEL, Color.TRANSPARENT, 8, 0)
	_text(_calendar_title_text(), Vector2(CAL_TITLE_X, CAL_RECT.position.y + 34), CAL_TITLE_SIZE, TEXT)

	var inner_x: float = CAL_RECT.position.x + 16
	var inner_w: float = CAL_RECT.size.x - 32
	var cell_gap: float = 6.0
	var cell_w: float = (inner_w - cell_gap * 6.0) / 7.0
	var week_y: float = CAL_RECT.position.y + 84
	for i in range(7):
		var wcolor: Color = MUTED
		if i == 6:
			wcolor = Color(RED.r, RED.g, RED.b, 0.85)
		elif i == 5:
			wcolor = Color(BLUE.r, BLUE.g, BLUE.b, 0.9)
		_text(str(WEEKDAYS[i]), Vector2(inner_x + i * (cell_w + cell_gap), week_y), 13, wcolor, cell_w, HORIZONTAL_ALIGNMENT_CENTER)

	var first_date: String = _date_string(_calendar_year, _calendar_month, 1)
	var offset: int = (SeasonCalendar.weekday_for_date(first_date) + 6) % 7
	var days: int = _days_in_month(_calendar_year, _calendar_month)
	var grid_y: float = CAL_RECT.position.y + 100
	var grid_bottom: float = CAL_RECT.end.y - 40
	var cell_h: float = (grid_bottom - grid_y - cell_gap * 5.0) / 6.0
	var n: int = 1 - offset
	for row in range(6):
		for col in range(7):
			var cell_rect: Rect2 = Rect2(inner_x + col * (cell_w + cell_gap), grid_y + row * (cell_h + cell_gap), cell_w, cell_h)
			if n >= 1 and n <= days:
				_draw_day_cell(cell_rect, _date_string(_calendar_year, _calendar_month, n), n, col, team_id, season)
			else:
				# 月外セルは背景よりわずかに暗い面のみ (枠線なし)。
				_round(cell_rect, Color(0.056, 0.066, 0.080), Color.TRANSPARENT, 7, 0)
			n += 1

	_draw_legend(Rect2(CAL_RECT.position.x + 16, grid_bottom + 8, inner_w, 26))


func _draw_day_cell(rect: Rect2, date_text: String, day_number: int, col: int, team_id: int, season: PSSeason) -> void:
	var is_today: bool = date_text == SeasonCalendar.current_date(season)
	var games: Array = _filtered_games_on_date(date_text, season, team_id)
	var has_team_game: bool = false
	var has_dh: bool = false
	for game_value in games:
		var g: Dictionary = game_value as Dictionary
		if _is_team_game(g, team_id):
			has_team_game = true
			if bool(g.get("dh_enabled", false)):
				has_dh = true

	# 枠線は使わず bg の明度差だけで面を作る: 通常 < 自軍試合日 < 今日 (今日はわずかに青みも足す)。
	# 今日/DH は既存のバッジ (本日/DH チップ) が引き続き目印になる。
	var bg: Color = PANEL_2
	if is_today:
		bg = PANEL_3.lerp(BLUE, 0.10)
	elif has_team_game:
		bg = PANEL_2.lerp(PANEL_3, 0.55)
	_round(rect, bg, Color.TRANSPARENT, 7, 0)

	var num_color: Color = TEXT if is_today else MUTED
	if not is_today:
		if col == 6:
			num_color = Color(RED.r, RED.g, RED.b, 0.8)
		elif col == 5:
			num_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.85)
	_text(str(day_number), Vector2(rect.position.x + 9, rect.position.y + 21), 14, num_color)

	# バッジは上段に置き、セル本文 (対戦カード) と重ねない。
	var badge_x: float = rect.end.x - 44
	if is_today:
		_chip(Rect2(badge_x, rect.position.y + 7, 36, 18), "本日", BLUE)
		badge_x -= 38
	if has_dh:
		_chip(Rect2(badge_x, rect.position.y + 7, 30, 18), "DH", BLUE_SOFT)

	if games.is_empty():
		if _calendar_filter == "team" or _calendar_filter == "all":
			var label: String = "休養" if _is_within_season_schedule_range(date_text, season) else "オフシーズン"
			_text(label, Vector2(rect.position.x + 10, rect.position.y + 54), 12, FAINT)
		return

	# 自軍1試合は添付画像どおり大きく (対戦カード+スコア+白星/黒星/三角)、
	# 「全試合」のリーグ複数試合だけコンパクトな複数ピルにする。
	if games.size() == 1 and _is_team_game(games[0] as Dictionary, team_id):
		_draw_cell_self_game(rect, games[0] as Dictionary, team_id)
		return

	games.sort_custom(func(a: Variant, b: Variant) -> bool:
		var au: bool = _is_team_game(a as Dictionary, team_id)
		var bu: bool = _is_team_game(b as Dictionary, team_id)
		return au if au != bu else _game_title(a as Dictionary) < _game_title(b as Dictionary)
	)
	var shown: Array = games.slice(0, 2)
	var y: float = rect.position.y + 34
	var slot_h: float = 30.0
	for game_value in shown:
		_draw_cell_game(Rect2(rect.position.x + 7, y, rect.size.x - 14, slot_h - 4), game_value as Dictionary, team_id)
		y += slot_h
	if games.size() > shown.size():
		_text("+%d試合" % (games.size() - shown.size()), Vector2(rect.position.x + 10, y + 12), 10, MUTED)


func _draw_cell_game(rect: Rect2, game: Dictionary, team_id: int) -> void:
	var is_team: bool = _is_team_game(game, team_id)
	var played: bool = bool(game.get("played", false))
	var color: Color = _game_color(game, team_id)
	_round(rect, Color(color.r, color.g, color.b, 0.14), Color(color.r, color.g, color.b, 0.34), 5)
	var label: String = ""
	if is_team:
		label = _short_matchup(game, team_id)
	else:
		label = _game_title(game)
		if played:
			label += "  %s" % _score(game)
	_text(label, Vector2(rect.position.x + 8, rect.position.y + 16), 11, TEXT if is_team else MUTED, rect.size.x - 40)
	if played:
		if is_team:
			_draw_result_mark(Vector2(rect.end.x - 18, rect.position.y + 12), 5.0, _result_symbol(game, team_id), color)
		else:
			_text(_winner_short(game), Vector2(rect.end.x - 26, rect.position.y + 16), 12, color)
	elif is_team:
		_text("予定", Vector2(rect.end.x - 34, rect.position.y + 16), 10, MUTED)


# 自軍1試合セル: 対戦カード + スコア + 白星/黒星/三角 を添付画像どおり大きめに描く。
func _draw_cell_self_game(rect: Rect2, game: Dictionary, team_id: int) -> void:
	var played: bool = bool(game.get("played", false))
	var color: Color = _game_color(game, team_id)
	var pill: Rect2 = Rect2(rect.position.x + 7, rect.position.y + 34, rect.size.x - 14, rect.size.y - 44)
	_round(pill, Color(color.r, color.g, color.b, 0.13), Color(color.r, color.g, color.b, 0.36), 6)
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return
	var opponent: PSTeam = home if away.id == team_id else away
	var venue: String = "@" if away.id == team_id else "vs"
	_text("%s %s" % [venue, opponent.short_name], Vector2(pill.position.x + 10, pill.position.y + 24), 14, TEXT, pill.size.x - 20)
	if played:
		_text(_self_score(game, team_id), Vector2(pill.position.x + 10, pill.position.y + 50), 14, TEXT)
		_draw_result_mark(Vector2(pill.end.x - 22, pill.position.y + 45), 6.5, _result_symbol(game, team_id), color)
	else:
		_text("予定", Vector2(pill.position.x + 10, pill.position.y + 50), 13, MUTED)


# 自軍視点のスコア (自軍得点 - 相手得点)。勝てば大きい方が先に出る。
func _self_score(game: Dictionary, team_id: int) -> String:
	var user_home: bool = int(game.get("home_team_id", 0)) == team_id
	var us: int = int(game.get("home_score", 0)) if user_home else int(game.get("away_score", 0))
	var them: int = int(game.get("away_score", 0)) if user_home else int(game.get("home_score", 0))
	return "%d - %d" % [us, them]


func _draw_legend(rect: Rect2) -> void:
	var x: float = rect.position.x
	var y: float = rect.position.y + 17
	for item_value in LEGEND:
		var item: Dictionary = item_value as Dictionary
		var mark: String = str(item.get("mark", ""))
		if mark.is_empty():
			_dot(Vector2(x + 6, y - 4), 5, item["color"] as Color)
		else:
			_draw_result_mark(Vector2(x + 6, y - 4), 5.0, mark, item["color"] as Color)
		_text(str(item["label"]), Vector2(x + 18, y), 11, MUTED)
		x += 20 + _measure(str(item["label"]), 11) + 18
	_chip(Rect2(x, y - 15, 30, 18), "DH", BLUE_SOFT)
	_text("DH試合", Vector2(x + 38, y), 11, MUTED)


# --- 右カラム ---

func _draw_right_column(team_id: int, season: PSSeason) -> void:
	_draw_today_card(Rect2(RIGHT_X, 206, RIGHT_W, 214), team_id, season)
	_draw_yesterday(Rect2(RIGHT_X, 432, RIGHT_W, 208), team_id, season)
	_draw_standings(Rect2(RIGHT_X, 652, RIGHT_W, 214), team_id, season)
	_draw_upcoming(Rect2(RIGHT_X, 878, 294, 182), team_id, season)
	_draw_injuries(Rect2(RIGHT_X + 306, 878, 294, 182), team_id)


func _draw_today_card(rect: Rect2, team_id: int, season: PSSeason) -> void:
	_panel(rect, "今日のカード")
	var game: Dictionary = _team_game_on_day(team_id, season.current_day)
	var ox: float = rect.position.x + 18
	if game.is_empty():
		_text("本日は自軍の試合はありません", Vector2(ox, rect.position.y + 78), 16, TEXT)
		var next_game: Dictionary = _next_team_game(team_id, season.current_day)
		if not next_game.is_empty():
			_text("次戦  %s   %s" % [
				SeasonCalendar.compact_label_for_game(next_game, season),
				_matchup_for_team(next_game, team_id),
			], Vector2(ox, rect.position.y + 112), 14, MUTED)
		return

	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return
	# 対戦カード行
	var row_y: float = rect.position.y + 50
	_team_badge(Rect2(ox, row_y, 34, 34), away)
	_text(away.name, Vector2(ox + 44, row_y + 23), 16, TEXT, 180)
	_text("VS", Vector2(rect.position.x + rect.size.x * 0.5 - 14, row_y + 23), 15, MUTED)
	var hx: float = rect.end.x - 18 - 220
	_team_badge(Rect2(hx, row_y, 34, 34), home)
	_text(home.name, Vector2(hx + 44, row_y + 23), 16, TEXT, 176)

	# 会場 (球場データは無いため主催チームで代替) + DH
	var host_label: String = "%s 主催（%s）" % [home.name, "ホーム" if home.id == team_id else "ビジター"]
	_text(host_label, Vector2(ox, rect.position.y + 110), 13, MUTED)
	if bool(game.get("dh_enabled", false)):
		_chip(Rect2(rect.end.x - 52, rect.position.y + 98, 34, 18), "DH", BLUE_SOFT)

	# 予告先発
	_text("予告先発  %s  %s" % [away.short_name, _pitcher_line(_probable_pitcher(away.id, season))], Vector2(ox, rect.position.y + 138), 13, TEXT)
	_text("予告先発  %s  %s" % [home.short_name, _pitcher_line(_probable_pitcher(home.id, season))], Vector2(ox, rect.position.y + 160), 13, TEXT)

	if bool(game.get("played", false)):
		# スコアは試合結果色、白星/黒星 (○●) の字色は白にする。
		var gc: Color = _game_color(game, team_id)
		var prefix: String = "終了  %s  " % _score(game)
		_text(prefix, Vector2(ox, rect.position.y + 192), 15, gc)
		_draw_result_mark(Vector2(ox + _measure(prefix, 15) + 7, rect.position.y + 187), 6.0, _result_symbol(game, team_id), gc)


# 6試合を 2行x3列 のミニカードで表示。各カードは「[Aバッジ] 2-4 [Bバッジ]」の横並び。
# 強調はスコアのみ (勝者のスコアを明色、敗者を淡色)。バッジは減光しない。
func _draw_yesterday(rect: Rect2, team_id: int, season: PSSeason) -> void:
	_panel(rect, "前日の試合結果")
	var day: int = max(1, season.current_day - 1)
	_text(SeasonCalendar.label_for_date(SeasonCalendar.date_for_season_day(season, day)), Vector2(rect.end.x - 90, rect.position.y + 30), 12, MUTED)
	var rows: Array = _games_on_day(day, season)
	if rows.is_empty():
		_text("試合はありません", Vector2(rect.position.x + 18, rect.position.y + 92), 14, MUTED)
		return
	# 自軍の試合を先頭(左上)へ、続けて自軍と同じリーグの試合を上段へまとめる。
	# 6試合を 2行x3列 で描くため、リーグでまとめないと相手リーグの試合が上段と下段に割れて読みづらい。
	# sort_custom は安定ソートではないので、同順位は元の並び (schedule 順) を保つよう index を併用する。
	var user_team: PSTeam = GameDb.get_team(team_id)
	var own_league: String = user_team.league if user_team != null else ""
	var ordered: Array = []
	for i in range(rows.size()):
		var game_row: Dictionary = rows[i] as Dictionary
		ordered.append({
			"rank": _yesterday_group_rank(game_row, team_id, own_league),
			"index": i,
			"game": game_row,
		})
	ordered.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ra: Dictionary = a as Dictionary
		var rb: Dictionary = b as Dictionary
		if int(ra.get("rank", 0)) != int(rb.get("rank", 0)):
			return int(ra.get("rank", 0)) < int(rb.get("rank", 0))
		return int(ra.get("index", 0)) < int(rb.get("index", 0))
	)
	var shown: Array = []
	for entry_value in ordered.slice(0, min(ordered.size(), 6)):
		shown.append((entry_value as Dictionary).get("game", {}))
	# セルごとに桁数でフォントサイズを変えると、一桁と二桁の試合が混在したときに
	# セル間で文字の大きさが揃わず不揃いに見える。表示する試合全体で最も窮屈な組み合わせに
	# 合わせて1回だけフォントサイズを求め、全セル共通で使うことで見た目を揃える。
	var font_size: int = 18
	for row_value in shown:
		var g: Dictionary = row_value as Dictionary
		if bool(g.get("played", false)):
			var away_text: String = str(int(g.get("away_score", 0)))
			var home_text: String = str(int(g.get("home_score", 0)))
			font_size = min(font_size, _fit_score_font_size(away_text, home_text, YESTERDAY_SCORE_MAX_W))

	var gap: float = 8.0
	var gx: float = rect.position.x + 14.0
	var gy: float = rect.position.y + 50.0
	var cw: float = (rect.size.x - 28.0 - gap * 2.0) / 3.0
	var ch: float = (rect.size.y - 62.0 - gap) / 2.0
	for i in range(shown.size()):
		var col: int = i % 3
		var row: int = 0 if i < 3 else 1
		var cell: Rect2 = Rect2(gx + col * (cw + gap), gy + row * (ch + gap), cw, ch)
		_draw_yesterday_game(cell, shown[i] as Dictionary, team_id, font_size)


# 「前日の試合結果」1試合セルのバッジ/スコアレイアウト基準 (base 座標)。
# HALF_GAP = 中心からバッジ内側の縁までの距離。SCORE_MAX_W = バッジ間でスコア全体
# (アウェイ+ダッシュ+ホーム) が使える幅の予算 (両端に少し余白を残す)。
const YESTERDAY_BADGE_W: float = 30.0
const YESTERDAY_BADGE_HALF_GAP: float = 36.0
const YESTERDAY_SCORE_PAD: float = 3.0
const YESTERDAY_SCORE_MAX_W: float = YESTERDAY_BADGE_HALF_GAP * 2.0 - 4.0


func _draw_yesterday_game(cell: Rect2, game: Dictionary, team_id: int, font_size: int) -> void:
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return
	var played: bool = bool(game.get("played", false))
	var result: Dictionary = game.get("result", {}) as Dictionary
	var draw_game: bool = bool(result.get("draw", false))
	var winner_id: int = int(result.get("winning_team_id", 0))
	var away_won: bool = played and not draw_game and winner_id == away.id
	var home_won: bool = played and not draw_game and winner_id == home.id
	var is_self: bool = _is_team_game(game, team_id)

	_round(cell, PANEL_2, Color(BLUE.r, BLUE.g, BLUE.b, 0.55) if is_self else BORDER_SOFT, 7)

	# [away] スコア [home] を中央寄せで横並び。バッジ位置は固定し、スコアは
	# バッジ内側の余白に収まるフォントサイズ (呼び出し元で全セル共通に決定済み) で描く
	# (二桁得点でバッジに衝突しないように)。
	var center: float = cell.position.x + cell.size.x * 0.5
	var by: float = cell.position.y + (cell.size.y - YESTERDAY_BADGE_W) * 0.5
	var sy: float = cell.position.y + cell.size.y * 0.5 + 6.0
	_team_badge(Rect2(center - YESTERDAY_BADGE_HALF_GAP - YESTERDAY_BADGE_W, by, YESTERDAY_BADGE_W, YESTERDAY_BADGE_W), away)
	_team_badge(Rect2(center + YESTERDAY_BADGE_HALF_GAP, by, YESTERDAY_BADGE_W, YESTERDAY_BADGE_W), home)
	if played:
		var away_text: String = str(int(game.get("away_score", 0)))
		var home_text: String = str(int(game.get("home_score", 0)))
		# 「アウェイ - ホーム」を1つのブロックとして中心に配置する。ダッシュ位置を固定して
		# 両側を個別に右/左寄せすると、一桁/二桁が混在したときに数字の見た目の重心が
		# 二桁側へ寄って非対称に見えるため、ブロック全体の幅を測って中心から等距離に置く。
		var away_w: float = _measure(away_text, font_size)
		var dash_w: float = _measure("-", font_size)
		var home_w: float = _measure(home_text, font_size)
		var total_w: float = away_w + YESTERDAY_SCORE_PAD + dash_w + YESTERDAY_SCORE_PAD + home_w
		var start_x: float = center - total_w * 0.5
		_text(away_text, Vector2(start_x, sy), font_size, TEXT if (away_won or draw_game) else FAINT)
		_text("-", Vector2(start_x + away_w + YESTERDAY_SCORE_PAD, sy), 16, MUTED)
		_text(home_text, Vector2(start_x + away_w + YESTERDAY_SCORE_PAD + dash_w + YESTERDAY_SCORE_PAD, sy), font_size, TEXT if (home_won or draw_game) else FAINT)
	else:
		_text("-", Vector2(center - 3.0, sy), 14, MUTED)


# 「アウェイ-ホーム」ブロック全体がバッジ間の幅予算に収まるフォントサイズを返す (18→最小12)。
func _fit_score_font_size(away_text: String, home_text: String, max_w: float) -> int:
	var size: int = 18
	while size > 12 and _score_block_width(away_text, home_text, size) > max_w:
		size -= 2
	return size


func _score_block_width(away_text: String, home_text: String, size: int) -> float:
	return _measure(away_text, size) + YESTERDAY_SCORE_PAD + _measure("-", size) + YESTERDAY_SCORE_PAD + _measure(home_text, size)


func _draw_standings(rect: Rect2, team_id: int, season: PSSeason) -> void:
	var team: PSTeam = GameDb.get_team(team_id)
	var league_key: String = team.league if team != null else "league1"
	_panel(rect, "順位 / チーム指標")
	_text(team.league_label() if team != null else "", Vector2(rect.end.x - 90, rect.position.y + 30), 12, MUTED)

	# ミニ順位表も共通テーブルの体裁 (bold ヘッダ + 太めルール + 行ヘアライン + 自軍のアクセントバー)。
	var hy: float = rect.position.y + 56
	_text("順", Vector2(rect.position.x + 18, hy), 11, MUTED, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("チーム", Vector2(rect.position.x + 50, hy), 11, MUTED, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text_right("勝", rect.position.x + 268, hy, 11, MUTED, 80.0, true)
	_text_right("敗", rect.position.x + 318, hy, 11, MUTED, 80.0, true)
	_text_right("分", rect.position.x + 366, hy, 11, MUTED, 80.0, true)
	_text_right("勝率", rect.position.x + 446, hy, 11, MUTED, 80.0, true)
	_text_right("GB", rect.position.x + 512, hy, 11, MUTED, 80.0, true)
	_text_right("防御率", rect.end.x - 18, hy, 11, MUTED, 80.0, true)
	_line(Vector2(rect.position.x + 14, hy + 8), Vector2(rect.end.x - 14, hy + 8), BORDER, 1.5)

	var entries: Array = _league_entries(league_key, season)
	var leader: PSStats = (entries[0] as Dictionary).get("stats") as PSStats if not entries.is_empty() else null
	var y: float = rect.position.y + 80
	var rank: int = 1
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var row_team: PSTeam = entry["team"] as PSTeam
		var stats: PSStats = entry["stats"] as PSStats
		var is_self: bool = row_team.id == team_id
		if is_self:
			_round(Rect2(rect.position.x + 8, y - 17, rect.size.x - 16, 24), Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 0, 0)
			_round(Rect2(rect.position.x + 8, y - 17, 3, 24), BLUE, Color.TRANSPARENT, 0, 0)
		var color: Color = TEXT
		_text(str(rank), Vector2(rect.position.x + 18, y), 13, color)
		_text(row_team.short_name, Vector2(rect.position.x + 50, y), 13, color, -1.0, HORIZONTAL_ALIGNMENT_LEFT, is_self)
		_text_right(str(stats.wins), rect.position.x + 268, y, 13, color)
		_text_right(str(stats.losses), rect.position.x + 318, y, 13, color)
		_text_right(str(stats.draws), rect.position.x + 366, y, 13, color)
		_text_right(_rate_short(stats.win_rate()), rect.position.x + 446, y, 13, color)
		_text_right("-" if leader == null or rank == 1 else _float1(_game_back(leader, stats)), rect.position.x + 512, y, 13, color)
		_text_right(_era_str_for(row_team.id), rect.end.x - 18, y, 13, color)
		_line(Vector2(rect.position.x + 14, y + 7), Vector2(rect.end.x - 14, y + 7), HAIRLINE, 1.0)
		y += 25
		rank += 1


func _draw_upcoming(rect: Rect2, team_id: int, season: PSSeason) -> void:
	_panel(rect, "今後の自軍試合")
	var y: float = rect.position.y + 58
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if count >= 4:
			break
		if bool(game.get("played", false)) or not _is_team_game(game, team_id):
			continue
		_text(SeasonCalendar.compact_label_for_game(game, season), Vector2(rect.position.x + 18, y), 13, TEXT if count == 0 else MUTED)
		_text(_matchup_for_team(game, team_id), Vector2(rect.position.x + 110, y), 13, TEXT if count == 0 else MUTED, rect.size.x - 124)
		y += 30
		count += 1
	if count == 0:
		_text("未消化の自軍試合はありません", Vector2(rect.position.x + 18, rect.position.y + 64), 13, MUTED)


func _draw_injuries(rect: Rect2, team_id: int) -> void:
	var injured: Array = _injured_records(team_id)
	_panel(rect, "怪我選手", AMBER if not injured.is_empty() else TEXT)
	var hy: float = rect.position.y + 50
	_text("選手", Vector2(rect.position.x + 18, hy), 11, FAINT)
	_text_right("離脱", rect.end.x - 70, hy, 11, FAINT)
	_text_right("復帰", rect.end.x - 14, hy, 11, FAINT)
	if injured.is_empty():
		_text("離脱者はいません", Vector2(rect.position.x + 18, rect.position.y + 78), 13, MUTED)
		return
	var y: float = rect.position.y + 74
	for record_value in injured.slice(0, 4):
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		_text(record.name, Vector2(rect.position.x + 18, y), 13, TEXT, 150)
		_text_right("%d日" % record.injury_days, rect.end.x - 70, y, 13, AMBER)
		_text_right(_return_label(record.injury_days), rect.end.x - 14, y, 12, MUTED)
		y += 28


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("team_select_empty", "チーム選択へ", Rect2(810, 560, 160, 46), func() -> void: AppState.request_screen("team_select"), "primary")
		_add_button("options_empty", "オプション", Rect2(982, 560, 140, 46), func() -> void: AppState.request_screen("options"), "action")
		_layout_buttons()
		return

	# 上部アクション。進行は日単位で、1試合だけ消化する操作は持たない。
	_add_button("today", "本日を終了", Rect2(1384, 22, 128, 42), _simulate_current_day, "primary")
	_skip_button = _add_button("skip", "スキップ ▾", Rect2(1522, 22, 120, 42), _on_skip_pressed, "action")
	_add_button("save", "セーブ", Rect2(1652, 22, 88, 42), _save_game, "action")
	var season_button: Button = _add_button("offseason", "翌年へ", Rect2(1750, 22, 150, 42), _on_offseason_pressed, "action")
	_configure_offseason_button(season_button)

	# サイドバー
	_build_nav_buttons()

	# カレンダーのフィルタ (パネル右端から右寄せ配置)
	var fwidths: Array = []
	var total_fw: float = 0.0
	for filter_value in FILTERS:
		var fw: float = 26.0 + _measure(str((filter_value as Dictionary)["label"]), 13) + 20.0
		fwidths.append(fw)
		total_fw += fw
	total_fw += 8.0 * float(FILTERS.size() - 1)
	var fx: float = CAL_RECT.end.x - 16.0 - total_fw
	for idx in range(FILTERS.size()):
		var filter: Dictionary = FILTERS[idx] as Dictionary
		var fid: String = str(filter["id"])
		_add_button("filter_%s" % fid, str(filter["label"]), Rect2(fx, 218, float(fwidths[idx]), 30),
			func(target: String = fid) -> void: _set_calendar_filter(target),
			"chip_active" if _calendar_filter == fid else "chip")
		fx += float(fwidths[idx]) + 8.0

	# 月送り (› は見出し文字列の実測幅から算出し、2桁月 (10-12月) で見出しと衝突しないようにする)
	var title_w: float = _measure(_calendar_title_text(), CAL_TITLE_SIZE)
	_add_button("prev_month", "‹", Rect2(CAL_RECT.position.x + 18, 216, 30, 30), func() -> void: _shift_month(-1), "chip")
	_add_button("next_month", "›", Rect2(CAL_TITLE_X + title_w + CAL_NAV_GAP, 216, 30, 30), func() -> void: _shift_month(1), "chip")

	# この試合を消化 (本日を終了と同じく日単位で消化する)
	var today_game: Dictionary = _team_game_on_day(team.id, season.current_day)
	if not today_game.is_empty() and not bool(today_game.get("played", false)):
		_add_button("play_today", "この試合を消化", Rect2(RIGHT_X + RIGHT_W - 196, 372, 180, 36), _simulate_current_day, "primary")

	_layout_buttons()
	if _inline_skip_active:
		for button_spec_value in _buttons:
			var button: Button = (button_spec_value as Dictionary).get("button") as Button
			if button != null:
				button.disabled = true


# ============================================================ actions

func _simulate_current_day() -> void:
	var ov: Dictionary = _show_progress_overlay("本日の試合を消化中…")
	var result: Dictionary = await AppState.simulate_current_day_async(get_tree(), ov["callback"], ov["cancel_token"], false)
	_hide_progress_overlay(ov)
	_status_text = str(result.get("message", ""))
	_sync_calendar_to_current()
	queue_redraw()


# スキップボタンの派生メニュー。日数/月末/自軍次戦/残り全試合をその場で選んで進める。
func _on_skip_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	menu.add_item("7日進める", 0)
	menu.add_item("月末まで進める", 1)
	menu.add_item("残り全試合", 2)
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_skip_menu_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = Vector2(1522, 64)
	if _skip_button != null:
		anchor = _skip_button.global_position + Vector2(0.0, _skip_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_skip_menu_selected(id: int) -> void:
	match id:
		0:
			await _simulate_days(7)
		1:
			_simulate_to_month_end()
		2:
			_simulate_remaining_season()


func _simulate_days(days: int) -> void:
	if days <= 0:
		return
	_inline_skip_active = true
	AppState.short_skip_active = true
	_inline_skip_days = days
	_status_text = "%d日スキップを開始しています…" % days
	_build_buttons()
	queue_redraw()
	var result: Dictionary = await AppState.simulate_days_async(
		days,
		get_tree(),
		_on_inline_skip_progress,
		{"cancelled": false},
		true
	)
	_inline_skip_active = false
	AppState.short_skip_active = false
	_status_text = str(result.get("message", ""))
	_sync_calendar_to_current()
	queue_redraw()


func _simulate_to_month_end() -> void:
	AppState.start_month_end_skip(get_tree())


func _on_inline_skip_progress(done: int, total: int, label: String) -> void:
	var percent: float = float(done) / float(total) * 100.0 if total > 0 else 0.0
	_status_text = "%d日スキップ中  %d / %d試合 (%0.1f%%)  %s" % [
		_inline_skip_days, done, total, percent, label,
	]
	queue_redraw()


func _simulate_remaining_season() -> void:
	AppState.start_remaining_season_skip(get_tree())


# スキップ後に月をまたいだら、カレンダー表示をスキップ終了時点の月へ追従させる。
# 見出し文字列が変わると月送り矢印の位置も変わるため _build_buttons() で再配置する。
func _sync_calendar_to_current() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var d: Dictionary = _parse_date(SeasonCalendar.current_date(season))
	_calendar_year = int(d.get("year", _calendar_year))
	_calendar_month = int(d.get("month", _calendar_month))
	_build_buttons()


func _save_game() -> void:
	var ok: bool = SaveService.save_state(AppState)
	_status_text = "保存しました" if ok else "保存に失敗しました"
	queue_redraw()


func _set_calendar_filter(mode: String) -> void:
	_calendar_filter = mode
	_build_buttons()
	queue_redraw()


func _shift_month(delta: int) -> void:
	_calendar_month += delta
	while _calendar_month < 1:
		_calendar_month += 12
		_calendar_year -= 1
	while _calendar_month > 12:
		_calendar_month -= 12
		_calendar_year += 1
	_build_buttons()
	queue_redraw()


func _configure_offseason_button(button: Button) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		button.text = "翌年へ"
		button.disabled = true
		return
	if AppState.offseason_active:
		button.text = "翌年開始" if AppState.offseason_steps_complete() else "オフ続行"
		button.disabled = false
		return
	if AppState.postseason_active:
		button.text = "表彰へ" if (AppState.current_postseason != null and PostseasonService.is_complete(AppState.current_postseason)) else "PS続行"
		button.disabled = false
		return
	if season.is_finished():
		button.text = "ポストシーズン" if (AppState.current_postseason == null or not PostseasonService.is_complete(AppState.current_postseason)) else "オフシーズン"
		button.disabled = false
		return
	button.text = "翌年へ"
	button.disabled = true


func _on_offseason_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	if AppState.offseason_active:
		if AppState.offseason_steps_complete():
			if not AppState.finalize_offseason():
				_status_text = "翌年開始に失敗しました"
		else:
			AppState.request_screen("home")
		return
	if AppState.postseason_active:
		if AppState.current_postseason != null and PostseasonService.is_complete(AppState.current_postseason):
			var fin: Dictionary = AppState.finalize_postseason_to_awards()
			if not bool(fin.get("ok", false)):
				_status_text = str(fin.get("message", ""))
		else:
			# ポストシーズン中はホームがポストシーズン用ダッシュボードへ差し替わる (main.gd)。
			AppState.request_screen("home")
		return
	if not season.is_finished():
		_status_text = "シーズン完了後にオフシーズンを開始できます(残り%d試合)" % season.games_remaining()
		queue_redraw()
		return
	if AppState.current_postseason == null or not PostseasonService.is_complete(AppState.current_postseason):
		var ps: Dictionary = AppState.start_postseason()
		if not bool(ps.get("ok", false)):
			_status_text = str(ps.get("message", ""))
		return
	var result: Dictionary = AppState.start_offseason()
	if not bool(result.get("ok", false)):
		_status_text = str(result.get("message", ""))
	queue_redraw()


func _show_progress_overlay(title: String) -> Dictionary:
	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress(title)
	var update_cb: Callable = func(done: int, total: int, sub: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, sub)
	return {"overlay": overlay, "cancel_token": cancel_token, "callback": update_cb}


func _hide_progress_overlay(ov: Dictionary) -> void:
	var overlay: ProgressOverlay = ov.get("overlay") as ProgressOverlay
	if overlay != null:
		overlay.hide_progress()
		overlay.queue_free()


# ============================================================ data helpers

func _team_game_on_day(team_id: int, day: int) -> Dictionary:
	var season: PSSeason = AppState.current_season
	if season == null:
		return {}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) == day and _is_team_game(game, team_id):
			return game
	return {}


func _next_team_game(team_id: int, from_day: int) -> Dictionary:
	var season: PSSeason = AppState.current_season
	if season == null:
		return {}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) >= from_day and not bool(game.get("played", false)) and _is_team_game(game, team_id):
			return game
	return {}


func _games_on_day(day: int, season: PSSeason) -> Array:
	var games: Array = []
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) == day:
			games.append(game)
	return games


func _filtered_games_on_date(date_text: String, season: PSSeason, team_id: int) -> Array:
	# 既定は自軍の試合のみ表示 (添付画像どおり)。フィルタ:
	#   team=自軍全試合 / unplayed=自軍の未消化 / result=自軍の結果 / all=自軍リーグ全試合。
	var user_team: PSTeam = GameDb.get_team(team_id)
	var league: String = user_team.league if user_team != null else ""
	var games: Array = []
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if _date_for_game(game, season) != date_text:
			continue
		match _calendar_filter:
			"team":
				if not _is_team_game(game, team_id):
					continue
			"unplayed":
				if not _is_team_game(game, team_id) or bool(game.get("played", false)):
					continue
			"result":
				if not _is_team_game(game, team_id) or not bool(game.get("played", false)):
					continue
			_:
				if not _game_in_league(game, league):
					continue
		games.append(game)
	return games


func _game_in_league(game: Dictionary, league: String) -> bool:
	if league.is_empty():
		return true
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	return (away != null and away.league == league) or (home != null and home.league == league)


func _date_for_game(game: Dictionary, season: PSSeason) -> String:
	var date_text: String = str(game.get("date", ""))
	if not date_text.is_empty():
		return date_text
	return SeasonCalendar.date_for_season_day(season, int(game.get("day", 1)))


func _is_team_game(game: Dictionary, team_id: int) -> bool:
	return int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id


# 「前日の試合結果」の並び順グループ。0=自軍の試合, 1=自軍と同じリーグ, 2=それ以外。
# 交流戦の日は全試合が両リーグにまたがるため 1 に寄り、実質 schedule 順のままになる。
func _yesterday_group_rank(game: Dictionary, team_id: int, own_league: String) -> int:
	if _is_team_game(game, team_id):
		return 0
	if own_league.is_empty():
		return 1
	return 1 if _game_in_league(game, own_league) else 2


# schedule は day 昇順で保持される (PSSchedule.sort_by_day) ため、先頭/末尾の date が
# シーズンの開幕日/最終戦日になる。この範囲外の空セルは月内休養日ではなくオフシーズン。
func _is_within_season_schedule_range(date_text: String, season: PSSeason) -> bool:
	if season.schedule.is_empty():
		return false
	var first_date: String = str((season.schedule[0] as Dictionary).get("date", ""))
	var last_date: String = str((season.schedule[season.schedule.size() - 1] as Dictionary).get("date", ""))
	if first_date.is_empty() or last_date.is_empty():
		return true
	return date_text >= first_date and date_text <= last_date


func _matchup_for_team(game: Dictionary, team_id: int) -> String:
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return "-"
	var opponent: PSTeam = home if away.id == team_id else away
	var venue: String = "@" if away.id == team_id else "vs"
	return "%s %s" % [venue, opponent.name]


func _short_matchup(game: Dictionary, team_id: int) -> String:
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	if away == null or home == null:
		return "-"
	var opponent: PSTeam = home if away.id == team_id else away
	var venue: String = "@" if away.id == team_id else "vs"
	if bool(game.get("played", false)):
		return "%s %s %s" % [venue, opponent.short_name, _score(game)]
	return "%s %s" % [venue, opponent.short_name]


func _game_title(game: Dictionary) -> String:
	var away: PSTeam = GameDb.get_team(int(game.get("away_team_id", 0)))
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	return "%s-%s" % [away.short_name if away != null else "-", home.short_name if home != null else "-"]


func _score(game: Dictionary) -> String:
	return "%d-%d" % [int(game.get("away_score", 0)), int(game.get("home_score", 0))]


func _result_symbol(game: Dictionary, team_id: int) -> String:
	if not bool(game.get("played", false)):
		return ""
	var result: Dictionary = game.get("result", {}) as Dictionary
	if bool(result.get("draw", false)):
		return "△"
	return "○" if int(result.get("winning_team_id", 0)) == team_id else "●"


func _winner_short(game: Dictionary) -> String:
	if not bool(game.get("played", false)):
		return "予定"
	var result: Dictionary = game.get("result", {}) as Dictionary
	if bool(result.get("draw", false)):
		return "△"
	var team: PSTeam = GameDb.get_team(int(result.get("winning_team_id", 0)))
	return team.short_name if team != null else "-"


func _game_color(game: Dictionary, team_id: int) -> Color:
	if not bool(game.get("played", false)):
		return BLUE
	var symbol: String = _result_symbol(game, team_id)
	if symbol == "○":
		return GREEN
	if symbol == "●":
		return RED
	if symbol == "△":
		return AMBER
	# 自軍以外の消化済み: 中立色
	return MUTED


func _standing_for_team(team_id: int) -> Dictionary:
	var season: PSSeason = AppState.current_season
	var team: PSTeam = GameDb.get_team(team_id)
	if season == null or team == null:
		return {}
	var entries: Array = _league_entries(team.league, season)
	var leader: PSStats = (entries[0] as Dictionary).get("stats") as PSStats if not entries.is_empty() else null
	var rank: int = 1
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		if (entry["team"] as PSTeam).id == team_id:
			var stats: PSStats = entry["stats"] as PSStats
			return {"rank": rank, "gb": 0.0 if leader == null or rank == 1 else _game_back(leader, stats)}
		rank += 1
	return {}


func _league_entries(league_key: String, season: PSSeason) -> Array:
	var entries: Array = []
	for team_id in season.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id))
		if team == null or team.league != league_key:
			continue
		entries.append({"team": team, "stats": season.standings[team_id]})
	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		var sa: PSStats = (a as Dictionary)["stats"] as PSStats
		var sb: PSStats = (b as Dictionary)["stats"] as PSStats
		return sa.wins > sb.wins if is_equal_approx(sa.win_rate(), sb.win_rate()) else sa.win_rate() > sb.win_rate()
	)
	return entries


func _injured_records(team_id: int) -> Array:
	var injured: Array = []
	for record_value in RecordStore.get_current_player_records_for_team(team_id):
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.injury_days > 0:
			injured.append(record)
	injured.sort_custom(func(a: Variant, b: Variant) -> bool:
		return (a as PSPlayerSeasonRecord).injury_days > (b as PSPlayerSeasonRecord).injury_days
	)
	return injured


func _compute_team_era(season: PSSeason) -> Dictionary:
	var acc: Dictionary = {}
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null or record.year != season.year or record.season_number != season.season_number:
			continue
		var ps: PSPitcherStats = record.pitcher_stats
		if ps == null or ps.outs_pitched <= 0:
			continue
		var bucket: Dictionary = acc.get(record.team_id, {"er": 0, "outs": 0}) as Dictionary
		bucket["er"] = int(bucket["er"]) + ps.earned_runs
		bucket["outs"] = int(bucket["outs"]) + ps.outs_pitched
		acc[record.team_id] = bucket
	var out: Dictionary = {}
	for team_id in acc.keys():
		var bucket: Dictionary = acc[team_id] as Dictionary
		var outs: int = int(bucket["outs"])
		out[team_id] = (float(bucket["er"]) * 27.0 / float(outs)) if outs > 0 else -1.0
	return out


func _era_str_for(team_id: int) -> String:
	var era: float = float(_era_by_team.get(team_id, -1.0))
	return "-" if era < 0.0 else "%0.2f" % era


func _probable_pitcher(team_id: int, season: PSSeason) -> PSPlayerSeasonRecord:
	var preview: Dictionary = PSTeamSetupBuilder.preview_rotation(season, team_id)
	if not bool(preview.get("ok", false)):
		return null
	var pid: int = int(preview.get("next_pitcher_id", 0))
	if pid <= 0:
		return null
	return RecordStore.get_player_record(pid, season.year, season.season_number)


func _pitcher_line(record: PSPlayerSeasonRecord) -> String:
	if record == null:
		return "未定"
	var ps: PSPitcherStats = record.pitcher_stats
	var era: String = "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()
	return "%s  %d勝%d敗 防%s" % [record.name, ps.wins, ps.losses, era]


func _return_label(days: int) -> String:
	if days <= 0:
		return "-"
	if days >= 40:
		return "未定"
	var target_date: String = SeasonCalendar.add_days(SeasonCalendar.current_date(AppState.current_season), days)
	var parts: PackedStringArray = target_date.split("-")
	if parts.size() != 3:
		return "%d日後" % days
	return "%d/%d頃" % [int(parts[1]), int(parts[2])]


# ============================================================ home 固有の日付/順位ヘルパ

func _date_string(year: int, month: int, day: int) -> String:
	return "%04d-%02d-%02d" % [year, month, day]


func _days_in_month(year: int, month: int) -> int:
	match month:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		_:
			var leap: bool = (year % 400 == 0) or (year % 4 == 0 and year % 100 != 0)
			return 29 if leap else 28


func _game_back(leader: PSStats, stats: PSStats) -> float:
	return float((leader.wins - stats.wins) + (stats.losses - leader.losses)) / 2.0
