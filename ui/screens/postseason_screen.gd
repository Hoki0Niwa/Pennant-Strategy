extends "res://ui/screens/home_screen.gd"

# ポストシーズン用ダッシュボード。home_screen を継承し、通常ホームのサマリーや右パネル基盤を流用する。
# ホームと違う点は:
#   - 中央のカレンダーを「ポストシーズン対戦票 (ブラケット)」へ置き換える。
#   - 右カラムをポストシーズン文脈 (本日の対戦 / 直近結果 / 自軍の状況) へ差し替える。
#   - 上部アクションを 本日を終了 (1日 = 第1/第2リーグ同時に1試合ずつ) / スキップ▾ / セーブ / 表彰へ にする。
# main.gd は postseason_active の間 "home" をこの画面へルーティングする
# (current_screen は "home" のままなのでサイドバーの「ホーム」がハイライトされる)。
# 詳細な試合結果はこの画面には出さず、試合結果画面のポストシーズンタブで参照する。

# title / sub / short は表示文言のキー (Loc)。league は sub・short の {league} に入れるリーグ。
const STAGE_CARD_LABELS: Dictionary = {
	"cs1_league1": {"title": "postseason.stage.cs1", "sub": "postseason.stage.cs1_sub", "short": "postseason.stage.cs1_short", "league": "league1"},
	"cs1_league2": {"title": "postseason.stage.cs1", "sub": "postseason.stage.cs1_sub", "short": "postseason.stage.cs1_short", "league": "league2"},
	"cs2_league1": {"title": "postseason.stage.cs2", "sub": "postseason.stage.cs2_sub", "short": "postseason.stage.cs2_short", "league": "league1"},
	"cs2_league2": {"title": "postseason.stage.cs2", "sub": "postseason.stage.cs2_sub", "short": "postseason.stage.cs2_short", "league": "league2"},
	"japan_series": {"title": "postseason.stage.japan_series", "sub": "postseason.stage.japan_series_sub", "short": "postseason.stage.japan_series", "league": ""},
}

# スキップ先 (ステージグループ index) の表示名キー。index は PSPostseasonResult.STAGE_GROUPS に対応。
const SKIP_TARGET_LABELS: Dictionary = {
	1: "postseason.skip_target.cs2",
	2: "postseason.skip_target.japan_series",
	3: "postseason.skip_target.end",
}

var _ps_skip_ui_active: bool = false
var _ps_skip_ui_cancel_pending: bool = false


func _ready() -> void:
	_init_chrome()
	AppState.postseason_skip_progress.connect(_on_ps_skip_progress)
	AppState.postseason_skip_finished.connect(_on_ps_skip_finished)
	_ps_skip_ui_active = AppState.postseason_skip_active
	_ps_skip_ui_cancel_pending = AppState.postseason_skip_cancel_pending
	_status_text = _ps_skip_status() if AppState.postseason_skip_active else AppState.last_status_message
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	var post: PSPostseasonResult = AppState.current_postseason
	if team == null or season == null or post == null:
		_draw_empty()
		return

	_era_by_team = _compute_team_era(season)

	_draw_shell(Loc.t("postseason.title"), team, season)
	_draw_statbar(team, season)
	_draw_bracket(post)
	_draw_right_column_ps(team.id, season, post)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1076), 12, MUTED)


# --- 中央: ポストシーズン対戦票 (ブラケット) ---

func _draw_bracket(post: PSPostseasonResult) -> void:
	# home のカレンダーパネルと同じくフラット (枠線なし)。
	_round(CAL_RECT, PANEL, Color.TRANSPARENT, 8, 0)
	_text(Loc.t("postseason.bracket_title"), Vector2(CAL_RECT.position.x + 24, CAL_RECT.position.y + 42), 22, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	var stage_label: String = _current_stage_headline(post)
	_text(stage_label, Vector2(CAL_RECT.end.x - 16 - 360, CAL_RECT.position.y + 40), 14, MUTED, 360, HORIZONTAL_ALIGNMENT_RIGHT)

	var pad: float = 24.0
	var gap: float = 28.0
	var col_w: float = (CAL_RECT.size.x - pad * 2.0 - gap * 2.0) / 3.0
	var col0_x: float = CAL_RECT.position.x + pad
	var col1_x: float = col0_x + col_w + gap
	var col2_x: float = col1_x + col_w + gap

	var region_top: float = CAL_RECT.position.y + 96.0
	var region_bottom: float = CAL_RECT.end.y - 30.0
	var region_h: float = region_bottom - region_top
	var card_gap: float = 24.0
	var card_h: float = (region_h - card_gap) / 2.0

	var top_y: float = region_top
	var bottom_y: float = region_top + card_h + card_gap
	var mid_y: float = region_top + (region_h - card_h) / 2.0

	# コネクタ (ブラケットの流れ): CS1 → CS2 → 日本シリーズ。
	_draw_bracket_connectors(col0_x + col_w, col1_x, col2_x, top_y, bottom_y, mid_y, card_h, col_w)

	_draw_series_card(Rect2(col0_x, top_y, col_w, card_h), "cs1_league1", post)
	_draw_series_card(Rect2(col0_x, bottom_y, col_w, card_h), "cs1_league2", post)
	_draw_series_card(Rect2(col1_x, top_y, col_w, card_h), "cs2_league1", post)
	_draw_series_card(Rect2(col1_x, bottom_y, col_w, card_h), "cs2_league2", post)
	_draw_series_card(Rect2(col2_x, mid_y, col_w, card_h), "japan_series", post)


func _draw_bracket_connectors(x0_end: float, x1: float, x2: float, top_y: float, bottom_y: float, mid_y: float, card_h: float, col_w: float) -> void:
	var col: Color = BORDER_SOFT
	var midline_top: float = top_y + card_h * 0.5
	var midline_bottom: float = bottom_y + card_h * 0.5
	var half0: float = (x0_end + x1) * 0.5
	# CS1 → CS2 (各リーグ横に渡す)
	_line(Vector2(x0_end, midline_top), Vector2(half0, midline_top), col, 1.5)
	_line(Vector2(half0, midline_top), Vector2(x1, midline_top), col, 1.5)
	_line(Vector2(x0_end, midline_bottom), Vector2(x1, midline_bottom), col, 1.5)
	# CS2 → 日本シリーズ (上下から中央へ収束)
	var x1_end: float = x1 + col_w
	var half1: float = (x1_end + x2) * 0.5
	var js_mid: float = mid_y + card_h * 0.5
	_line(Vector2(x1_end, midline_top), Vector2(half1, midline_top), col, 1.5)
	_line(Vector2(x1_end, midline_bottom), Vector2(half1, midline_bottom), col, 1.5)
	_line(Vector2(half1, midline_top), Vector2(half1, midline_bottom), col, 1.5)
	_line(Vector2(half1, js_mid), Vector2(x2, js_mid), col, 1.5)


func _draw_series_card(rect: Rect2, stage_key: String, post: PSPostseasonResult) -> void:
	var series: Dictionary = post.stage_dict(stage_key)
	var completed: bool = bool(series.get("completed", false))
	var active: bool = _is_active_stage(post, stage_key) and not completed

	# 枠線は完了/進行中など意味がある状態の時だけ描く (待機中カードはフラット)。
	var border: Color = Color.TRANSPARENT
	var border_w: int = 0
	if completed:
		border = Color(GREEN.r, GREEN.g, GREEN.b, 0.55)
		border_w = 2
	elif active:
		border = BLUE
		border_w = 2
	_round(rect, PANEL_2, border, 9, border_w)

	_text(_stage_label(stage_key, "title"), Vector2(rect.position.x + 14, rect.position.y + 26), 15, TEXT, rect.size.x - 92, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_stage_label(stage_key, "sub"), Vector2(rect.position.x + 14, rect.position.y + 46), 11, MUTED, rect.size.x - 24)

	# ステータスチップ
	var st_text: String = Loc.t("postseason.status.waiting")
	var st_color: Color = FAINT
	if completed:
		st_text = Loc.t("postseason.status.completed")
		st_color = GREEN
	elif active:
		st_text = Loc.t("postseason.status.in_progress")
		st_color = BLUE
	_chip(Rect2(rect.end.x - 76, rect.position.y + 12, 64, 20), st_text, st_color)

	if series.is_empty():
		_text(Loc.t("postseason.teams_undecided"), Vector2(rect.position.x + 16, rect.position.y + 92), 13, MUTED)
		return

	var top_id: int = _display_top_id(post, stage_key, series)
	var chal_id: int = _display_challenger_id(post, stage_key, series)
	var win_target: int = int(series.get("win_target", 4))
	var advantage: int = int(series.get("advantage_wins", 0))
	var top_wins: int = int(series.get("top_wins", advantage))
	var chal_wins: int = int(series.get("challenger_wins", 0))
	var winner: int = int(series.get("winner_id", 0))

	var ty: float = rect.position.y + 84.0
	_draw_team_line(rect, ty, top_id, top_wins, win_target, completed and winner == top_id, active and not completed)
	_draw_team_line(rect, ty + 46.0, chal_id, chal_wins, win_target, completed and winner == chal_id, active and not completed)

	var note: String = Loc.t("postseason.win_target", {"n": win_target})
	if advantage > 0:
		note += Loc.t("postseason.advantage_note", {"n": advantage})
	# 2026年規定で2勝アドバンテージへ引き上げられた場合は、その条件 (ゲーム差/勝率) を添える。
	var advantage_reason: String = str(series.get("advantage_reason", ""))
	if bool(series.get("advantage_extended", false)) and not advantage_reason.is_empty():
		note += Loc.t("postseason.advantage_reason", {"reason": advantage_reason})
	_text(note, Vector2(rect.position.x + 16, ty + 84.0), 11, FAINT, rect.size.x - 28)

	_draw_series_game_chips(rect, series, top_id)


func _draw_team_line(rect: Rect2, y: float, team_id: int, wins: int, win_target: int, is_winner: bool, active: bool) -> void:
	if team_id <= 0:
		_text(Loc.t("postseason.awaiting_winner"), Vector2(rect.position.x + 16, y + 6), 13, FAINT, rect.size.x - 28)
		return
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return
	var at_match_point: bool = active and wins == win_target - 1
	_team_badge(Rect2(rect.position.x + 14, y - 14, 28, 28), team)
	var name_col: Color = AMBER if is_winner else TEXT
	_text(team.name, Vector2(rect.position.x + 50, y + 6), 14, name_col, rect.size.x - 110)
	if at_match_point:
		_text(Loc.t("postseason.match_point"), Vector2(rect.end.x - 96, y + 5), 11, AMBER, 40)
	var wins_col: Color = AMBER if is_winner else (TEXT if wins > 0 else MUTED)
	_text(str(wins), Vector2(rect.end.x - 50, y + 11), 22, wins_col, 38, HORIZONTAL_ALIGNMENT_CENTER)


# 試合ごとのスコアチップ (上位チーム視点)。勝=緑 / 敗=赤 / 分=黄。
func _draw_series_game_chips(rect: Rect2, series: Dictionary, top_id: int) -> void:
	var games: Array = series.get("games", []) as Array
	var advantage: int = int(series.get("advantage_wins", 0))
	var gy: float = rect.end.y - 34.0
	var gx: float = rect.position.x + 14.0
	var avail: float = rect.size.x - 28.0
	# アドバンテージは 1勝 = 1チップ (2026年規定では最大2勝ぶん並ぶ)。
	var count: int = games.size() + advantage
	if count <= 0:
		_text(Loc.t("postseason.unplayed"), Vector2(gx, gy + 18.0), 11, MUTED)
		return
	var chip_w: float = clampf(avail / float(count) - 3.0, 28.0, 44.0)
	var cx: float = gx
	for _i in range(advantage):
		_round(Rect2(cx, gy, chip_w, 24.0), Color(BLUE.r, BLUE.g, BLUE.b, 0.16), Color(BLUE.r, BLUE.g, BLUE.b, 0.4), 5)
		_text(Loc.t("postseason.advantage_chip"), Vector2(cx, gy + 17.0), 11, BLUE, chip_w, HORIZONTAL_ALIGNMENT_CENTER)
		cx += chip_w + 3.0
	for game_value in games:
		var game: Dictionary = game_value as Dictionary
		var top_is_home: bool = int(game.get("home_id", 0)) == top_id
		var top_score: int = int(game.get("home_score", 0)) if top_is_home else int(game.get("away_score", 0))
		var opp_score: int = int(game.get("away_score", 0)) if top_is_home else int(game.get("home_score", 0))
		var col: Color = MUTED
		if bool(game.get("draw", false)):
			col = AMBER
		elif int(game.get("winner_id", 0)) == top_id:
			col = GREEN
		else:
			col = RED
		_round(Rect2(cx, gy, chip_w, 24.0), Color(col.r, col.g, col.b, 0.16), Color(col.r, col.g, col.b, 0.42), 5)
		_text("%d-%d" % [top_score, opp_score], Vector2(cx, gy + 17.0), 11, col, chip_w, HORIZONTAL_ALIGNMENT_CENTER)
		cx += chip_w + 3.0


# --- 右カラム (ポストシーズン文脈) ---

func _draw_right_column_ps(team_id: int, season: PSSeason, post: PSPostseasonResult) -> void:
	_draw_ps_today(Rect2(RIGHT_X, 206, RIGHT_W, 214), post)
	_draw_ps_recent(Rect2(RIGHT_X, 432, RIGHT_W, 208), post)
	_draw_standings(Rect2(RIGHT_X, 652, RIGHT_W, 214), team_id, season)
	_draw_ps_team_status(Rect2(RIGHT_X, 878, 294, 182), team_id, post)
	_draw_injuries(Rect2(RIGHT_X + 306, 878, 294, 182), team_id)


func _draw_ps_today(rect: Rect2, post: PSPostseasonResult) -> void:
	_panel(rect, Loc.t("postseason.today_games"))
	var rows: Array = []
	for key_value in PostseasonService.active_group_keys(post):
		var stage_key: String = str(key_value)
		var series: Dictionary = post.stage_dict(stage_key)
		if series.is_empty() or bool(series.get("completed", false)):
			continue
		rows.append({"key": stage_key, "series": series})
	if rows.is_empty():
		_text(Loc.t("postseason.all_done"), Vector2(rect.position.x + 18, rect.position.y + 78), 16, TEXT)
		_text(Loc.t("postseason.to_awards_hint"), Vector2(rect.position.x + 18, rect.position.y + 112), 13, MUTED)
		return
	var y: float = rect.position.y + 48.0
	var row_h: float = (rect.size.y - 58.0) / float(rows.size())
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		_draw_ps_today_row(Rect2(rect.position.x + 18, y, rect.size.x - 36, row_h), str(row["key"]), row["series"] as Dictionary, post)
		y += row_h


# レギュラーの「今日のカード」同様に球団バッジ + 名前で対戦カードを描く (枠サイズのみ変更)。
func _draw_ps_today_row(row: Rect2, stage_key: String, series: Dictionary, post: PSPostseasonResult) -> void:
	var top_id: int = _display_top_id(post, stage_key, series)
	var chal_id: int = _display_challenger_id(post, stage_key, series)
	var game_no: int = (series.get("games", []) as Array).size() + 1
	var home_is_top: bool = PostseasonService.next_home_side_for_series(series, game_no) != PostseasonService.HOME_SIDE_CHALLENGER
	var home_id: int = top_id if home_is_top else chal_id
	var away_id: int = chal_id if home_is_top else top_id

	_text(_stage_label(stage_key, "short"), Vector2(row.position.x, row.position.y + 14), 12, BLUE)
	_text(Loc.t("postseason.game_number", {"n": game_no}), Vector2(row.end.x - 60, row.position.y + 14), 12, MUTED, 56, HORIZONTAL_ALIGNMENT_RIGHT)
	var win_target: int = int(series.get("win_target", 4))
	var top_wins: int = int(series.get("top_wins", int(series.get("advantage_wins", 0))))
	var chal_wins: int = int(series.get("challenger_wins", 0))
	if top_wins == win_target - 1 or chal_wins == win_target - 1:
		_chip(Rect2(row.end.x - 130, row.position.y + 2, 44, 18), Loc.t("postseason.match_point"), AMBER)

	var away: PSTeam = GameDb.get_team(away_id)
	var home: PSTeam = GameDb.get_team(home_id)
	if away == null or home == null:
		return
	var by: float = row.position.y + 30.0
	_team_badge(Rect2(row.position.x, by, 30, 30), away)
	_text(away.name, Vector2(row.position.x + 38, by + 21.0), 14, TEXT, 170)
	_text("VS", Vector2(row.position.x + row.size.x * 0.5 - 12, by + 21.0), 13, MUTED)
	var hx: float = row.end.x - 30.0 - 178.0
	_team_badge(Rect2(hx, by, 30, 30), home)
	_text(home.name, Vector2(hx + 38, by + 21.0), 14, TEXT, 150)


func _draw_ps_recent(rect: Rect2, post: PSPostseasonResult) -> void:
	_panel(rect, Loc.t("postseason.recent_results"))
	var games: Array = _ps_games_on_day(post, post.current_day)
	if games.is_empty():
		_text(Loc.t("postseason.no_games_yet"), Vector2(rect.position.x + 18, rect.position.y + 92), 14, MUTED)
		return
	var first_game: Dictionary = (games[0] as Dictionary).get("game", {}) as Dictionary
	var date_label: String = SeasonCalendar.label_for_date(str(first_game.get("date", "")))
	_text_right(Loc.t("postseason.day_label_with_date", {"date": date_label, "day": post.current_day}), rect.end.x - 18, rect.position.y + 30, 12, MUTED, 150)
	# レギュラーの「前日の試合結果」のミニカード (球団バッジ + スコア) をそのまま流用し、枠サイズだけ変える。
	var shown: Array = games.slice(0, min(games.size(), 2))
	var normalized: Array = []
	for entry_value in shown:
		normalized.append(_normalize_ps_game((entry_value as Dictionary)["game"] as Dictionary))
	# 一桁/二桁が混在してもセル間でフォントサイズが揃うよう、home_screen と同じく
	# 表示する試合全体で共通のフォントサイズを1回だけ求める。
	var font_size: int = 18
	for game_value in normalized:
		var g: Dictionary = game_value as Dictionary
		if bool(g.get("played", false)):
			var away_text: String = str(int(g.get("away_score", 0)))
			var home_text: String = str(int(g.get("home_score", 0)))
			font_size = min(font_size, _fit_score_font_size(away_text, home_text, YESTERDAY_SCORE_MAX_W))

	var gap: float = 10.0
	var gx: float = rect.position.x + 14.0
	var gy: float = rect.position.y + 50.0
	var cols: int = max(1, normalized.size())
	var cw: float = (rect.size.x - 28.0 - gap * float(cols - 1)) / float(cols)
	var ch: float = rect.size.y - 62.0
	for i in range(normalized.size()):
		var cell: Rect2 = Rect2(gx + i * (cw + gap), gy, cw, ch)
		_draw_yesterday_game(cell, normalized[i] as Dictionary, AppState.selected_team_id, font_size)


# ポストシーズン試合を home._draw_yesterday_game が読める形へ正規化する。
func _normalize_ps_game(game: Dictionary) -> Dictionary:
	return {
		"day": int(game.get("season_day", game.get("day", 1))),
		"date": str(game.get("date", "")),
		"away_team_id": int(game.get("away_id", 0)),
		"home_team_id": int(game.get("home_id", 0)),
		"away_score": int(game.get("away_score", 0)),
		"home_score": int(game.get("home_score", 0)),
		"played": true,
		"result": {
			"winning_team_id": int(game.get("winner_id", 0)),
			"draw": bool(game.get("draw", false)),
		},
	}


func _draw_ps_team_status(rect: Rect2, team_id: int, post: PSPostseasonResult) -> void:
	_panel(rect, Loc.t("postseason.team_status"))
	var stage_key: String = _team_current_stage(post, team_id)
	if stage_key.is_empty():
		# どのシリーズにも関与していない = 進出していない or 既に敗退/勝ち抜け。
		if post.champion_team_id == team_id:
			_text(Loc.t("postseason.team_champion"), Vector2(rect.position.x + 18, rect.position.y + 72), 18, AMBER)
			return
		if _team_was_in_postseason(post, team_id):
			_text(Loc.t("postseason.team_eliminated"), Vector2(rect.position.x + 18, rect.position.y + 72), 15, MUTED)
		else:
			_text(Loc.t("postseason.title"), Vector2(rect.position.x + 18, rect.position.y + 64), 14, MUTED)
			_text(Loc.t("postseason.team_not_qualified"), Vector2(rect.position.x + 18, rect.position.y + 90), 14, MUTED)
		return
	var series: Dictionary = post.stage_dict(stage_key)
	var top_id: int = _display_top_id(post, stage_key, series)
	var is_top: bool = top_id == team_id
	var my_wins: int = int(series.get("top_wins", int(series.get("advantage_wins", 0)))) if is_top else int(series.get("challenger_wins", 0))
	var opp_id: int = _display_challenger_id(post, stage_key, series) if is_top else top_id
	var opp_wins: int = int(series.get("challenger_wins", 0)) if is_top else int(series.get("top_wins", int(series.get("advantage_wins", 0))))
	_text(_stage_label(stage_key, "title"), Vector2(rect.position.x + 18, rect.position.y + 58), 13, BLUE)
	_text(Loc.t("postseason.versus", {"team": _team_name(opp_id)}), Vector2(rect.position.x + 18, rect.position.y + 86), 15, TEXT, rect.size.x - 36)
	_text(Loc.t("postseason.series_score", {"mine": my_wins, "theirs": opp_wins}), Vector2(rect.position.x + 18, rect.position.y + 118), 18, TEXT)
	var win_target: int = int(series.get("win_target", 4))
	if my_wins == win_target - 1:
		_chip(Rect2(rect.position.x + 18, rect.position.y + 134, 64, 22), Loc.t("postseason.match_point"), AMBER)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	var post: PSPostseasonResult = AppState.current_postseason
	if team == null or season == null or post == null:
		_add_button("home_empty", Loc.t("common.to_home"), Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	# スキップ中は順位表のシーズンスキップと同じく操作を停止ボタンだけに絞り、
	# 画面はそのまま (対戦票・結果が 1 日ごとに更新される)。
	if AppState.postseason_skip_active:
		_add_button(
			"cancel_ps_skip",
			Loc.t("skip.stopping") if AppState.postseason_skip_cancel_pending else Loc.t("skip.stop"),
			Rect2(1730, 22, 150, 42),
			AppState.cancel_postseason_skip,
			"action"
		).disabled = AppState.postseason_skip_cancel_pending
		_layout_buttons()
		return

	var complete: bool = PostseasonService.is_complete(post)
	var today_button: Button = _add_button("ps_today", Loc.t("home.end_today"), Rect2(1384, 22, 128, 42), _advance_day, "primary")
	today_button.disabled = complete
	_skip_button = _add_button("ps_skip", Loc.t("home.skip_menu"), Rect2(1522, 22, 120, 42), _on_ps_skip_pressed, "action")
	_skip_button.disabled = complete
	_add_button("save", Loc.t("home.save"), Rect2(1652, 22, 88, 42), _save_game, "action")
	var awards_button: Button = _add_button("awards", Loc.t("postseason.to_awards"), Rect2(1750, 22, 150, 42), _on_awards_pressed, "action")
	awards_button.disabled = not complete

	_build_nav_buttons()
	_layout_buttons()


# ============================================================ actions

func _advance_day() -> void:
	var post: PSPostseasonResult = AppState.current_postseason
	if post == null or PostseasonService.is_complete(post):
		return
	var result: Dictionary = AppState.advance_postseason_day()
	_status_text = _day_status_message(result)
	_build_buttons()
	queue_redraw()


func _on_ps_skip_pressed() -> void:
	var post: PSPostseasonResult = AppState.current_postseason
	if post == null:
		return
	var gi: int = PostseasonService.active_group_index(post)
	var menu: PopupMenu = PopupMenu.new()
	# それぞれのステージまで + 最後まで。すでに通過済みのステージは出さない。
	if gi <= 0:
		menu.add_item(Loc.t("postseason.skip_menu.cs2"), 1)
	if gi <= 1:
		menu.add_item(Loc.t("postseason.skip_menu.japan_series"), 2)
	menu.add_item(Loc.t("postseason.skip_menu.end"), 3)
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_ps_skip_selected)
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


# 消化本体は AppState 側の coroutine が持ち、この画面は進捗シグナルを受けて描き直すだけ
# (レギュラーの月末/残り全試合スキップと同じ形。違いは表示する画面が順位表ではなくこのダッシュボード)。
func _on_ps_skip_selected(target_group: int) -> void:
	AppState.start_postseason_skip(get_tree(), target_group)
	_ps_skip_ui_active = AppState.postseason_skip_active
	_ps_skip_ui_cancel_pending = AppState.postseason_skip_cancel_pending
	_status_text = _ps_skip_status()
	_build_buttons()
	queue_redraw()


func _on_ps_skip_progress(_days: int, _games: int, _label: String) -> void:
	var controls_changed: bool = (
		_ps_skip_ui_active != AppState.postseason_skip_active
		or _ps_skip_ui_cancel_pending != AppState.postseason_skip_cancel_pending
	)
	_ps_skip_ui_active = AppState.postseason_skip_active
	_ps_skip_ui_cancel_pending = AppState.postseason_skip_cancel_pending
	if controls_changed:
		_build_buttons()
	_status_text = _ps_skip_status()
	# 対戦票・本日のカード・直近結果はすべて _draw が現在の状態から描き直すので、再描画だけで足りる。
	queue_redraw()


func _on_ps_skip_finished(result: Dictionary) -> void:
	_ps_skip_ui_active = AppState.postseason_skip_active
	_ps_skip_ui_cancel_pending = AppState.postseason_skip_cancel_pending
	# _day_status_message は手掛かりが無いとき現在の _status_text を返すため、先にスキップ全体の
	# 要約を入れておく (最終日の結果や日本一メッセージがあればそちらで上書きされる)。
	_status_text = Loc.t("postseason.skip_done", {"days": AppState.postseason_skip_days, "games": AppState.postseason_skip_games})
	_status_text = _day_status_message(result)
	_build_buttons()
	queue_redraw()


func _ps_skip_status() -> String:
	var target: String = Loc.t(str(SKIP_TARGET_LABELS.get(AppState.postseason_skip_target_group, "postseason.skip_target.end")))
	var state: String = Loc.t("postseason.skip_stopping") if AppState.postseason_skip_cancel_pending else Loc.t("postseason.skip_running", {"target": target})
	return Loc.t("postseason.skip_progress", {
		"state": state, "days": AppState.postseason_skip_days, "games": AppState.postseason_skip_games, "day": AppState.postseason_skip_label,
	})


func _on_awards_pressed() -> void:
	var result: Dictionary = AppState.finalize_postseason_to_awards()
	if not bool(result.get("ok", false)):
		_status_text = str(result.get("message", ""))
		queue_redraw()


# ============================================================ helpers

func _day_status_message(result: Dictionary) -> String:
	var post: PSPostseasonResult = AppState.current_postseason
	if post != null and bool(result.get("completed", PostseasonService.is_complete(post))):
		var champ: PSTeam = GameDb.get_team(post.champion_team_id)
		if champ != null:
			return Loc.t("postseason.finished_with_champion", {"team": champ.name})
		return Loc.t("postseason.finished")
	var played: Array = result.get("played", []) as Array
	if played.is_empty():
		return _status_text
	var date_label: String = SeasonCalendar.label_for_date(str(result.get("date", "")))
	return Loc.t("postseason.day_done", {
		"date": date_label,
		"day": int(result.get("day", post.current_day if post != null else 0)),
		"games": played.size(),
	})


func _is_active_stage(post: PSPostseasonResult, stage_key: String) -> bool:
	return PostseasonService.active_group_keys(post).has(stage_key)


# シリーズの top_id を、未確定なら前段勝者から推測して返す (表示用)。
func _display_top_id(post: PSPostseasonResult, stage_key: String, series: Dictionary) -> int:
	var t: int = int(series.get("top_id", 0))
	if t > 0:
		return t
	if stage_key == "japan_series":
		var first_home_league: String = str(series.get("first_home_league", PostseasonService.FIRST_LEAGUE))
		if first_home_league == PostseasonService.FIRST_LEAGUE:
			return int(post.cs2_league1.get("winner_id", 0))
		return int(post.cs2_league2.get("winner_id", 0))
	return 0


func _display_challenger_id(post: PSPostseasonResult, stage_key: String, series: Dictionary) -> int:
	var c: int = int(series.get("challenger_id", 0))
	if c > 0:
		return c
	match stage_key:
		"cs2_league1":
			return int(post.cs1_league1.get("winner_id", 0))
		"cs2_league2":
			return int(post.cs1_league2.get("winner_id", 0))
		"japan_series":
			var first_home_league: String = str(series.get("first_home_league", PostseasonService.FIRST_LEAGUE))
			if first_home_league == PostseasonService.FIRST_LEAGUE:
				return int(post.cs2_league2.get("winner_id", 0))
			return int(post.cs2_league1.get("winner_id", 0))
	return 0


# 指定日に消化された全試合を [{stage, game}] で返す。
func _ps_games_on_day(post: PSPostseasonResult, day: int) -> Array:
	var out: Array = []
	if day <= 0:
		return out
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var series: Dictionary = post.stage_dict(str(stage_key))
		for game_value in (series.get("games", []) as Array):
			var game: Dictionary = game_value as Dictionary
			if int(game.get("day", 0)) == day:
				out.append({"stage": str(stage_key), "game": game})
	return out


# 自軍が現在関与している (進行中の) シリーズ。無ければ "".
func _team_current_stage(post: PSPostseasonResult, team_id: int) -> String:
	for key_value in PostseasonService.active_group_keys(post):
		var stage_key: String = str(key_value)
		var series: Dictionary = post.stage_dict(stage_key)
		if _display_top_id(post, stage_key, series) == team_id or _display_challenger_id(post, stage_key, series) == team_id:
			return stage_key
	return ""


func _team_was_in_postseason(post: PSPostseasonResult, team_id: int) -> bool:
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var series: Dictionary = post.stage_dict(str(stage_key))
		if int(series.get("top_id", 0)) == team_id or int(series.get("challenger_id", 0)) == team_id:
			return true
	return false


func _current_stage_headline(post: PSPostseasonResult) -> String:
	if PostseasonService.is_complete(post):
		var champ: PSTeam = GameDb.get_team(post.champion_team_id)
		return Loc.t("postseason.champion_headline", {"team": champ.name}) if champ != null else Loc.t("postseason.all_done")
	var keys: Array = PostseasonService.active_group_keys(post)
	if keys.is_empty():
		return ""
	var first: String = str(keys[0])
	return Loc.t("postseason.stage_in_progress", {"stage": _stage_label(first, "title")})


# STAGE_CARD_LABELS の field (title/sub/short) を、リーグ名を差し込んで表示文言にする。
func _stage_label(stage_key: String, field: String) -> String:
	var label: Dictionary = STAGE_CARD_LABELS.get(stage_key, {}) as Dictionary
	if label.is_empty():
		return stage_key if field == "title" else ""
	var league: String = str(label.get("league", ""))
	return Loc.t(str(label.get(field, "")), {
		"league": PSTeam.league_label_for(league) if not league.is_empty() else "",
		"league_short": _league_short(league),
	})


func _league_short(league: String) -> String:
	if league == "league1":
		return Loc.t("league.league1_short")
	if league == "league2":
		return Loc.t("league.league2_short")
	return ""


func _team_name(team_id: int) -> String:
	if team_id <= 0:
		return Loc.t("postseason.undecided")
	var team: PSTeam = GameDb.get_team(team_id)
	return team.name if team != null else "-"
