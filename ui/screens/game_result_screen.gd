extends "res://ui/components/dashboard_screen.gd"

# 試合結果画面。左で月別の試合一覧を選び、右で選択試合のスコア、打席結果、交代、投手成績を描く。
# 試合ログの読み込みと集計は _load_detail で一度だけ行い、_draw はキャッシュ済み detail の描画に専念する。
# _draw は hover やスクロールで頻繁に走るため、重い GameLogService/BoxScoreBuilder 呼び出しを入れない。

const GameLogService = preload("res://services/storage/game_log_service.gd")
const BoxScoreBuilder = preload("res://services/reports/box_score_builder.gd")

const POSITION_LABELS: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三", 6: "遊", 7: "左", 8: "中", 9: "右", 10: "指",
}

const SUB_KIND_LABELS: Dictionary = {
	"pitching": "投手交代", "pinch_hit": "代打", "defense": "守備固め",
}

# --- レイアウト基準 (base 座標) ---
const TABS_Y: float = 110.0
const TAB_ROW_H: float = 34.0       # チップ高 28 + 行間 6
const TAB_CHIP_H: float = 28.0
const LIST_X: float = 262.0
const LIST_W: float = 348.0
const LIST_BOTTOM: float = 1060.0
const LIST_GAP: float = 12.0        # タブ群下端から一覧パネル上端までの余白

const RIGHT_X: float = 622.0

# 上段: イニングスコア + サマリー
const TOP_Y: float = 104.0
const SCORE_RECT: Rect2 = Rect2(622, 104, 624, 190)
const SUMMARY_RECT: Rect2 = Rect2(1258, 104, 642, 190)

# 中段: 打席結果 + 交代
const BOX_RECT: Rect2 = Rect2(622, 306, 686, 402)
const SUB_RECT: Rect2 = Rect2(1320, 306, 580, 402)

# 下段: 投手成績
const PITCH_RECT: Rect2 = Rect2(622, 720, 1278, 340)

# 打席結果グリッドの固定列 (守備/選手/利/打数/安打/打点/通算率/HR)。残りをイニングへ割る。
const BOX_FIXED: Array = [
	{"key": "pos",  "label": "守",   "w": 46.0,  "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"key": "name", "label": "選手", "w": 94.0,  "align": HORIZONTAL_ALIGNMENT_LEFT},
	{"key": "bats", "label": "",     "w": 26.0,  "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"key": "ab",   "label": "打",   "w": 30.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "h",    "label": "安",   "w": 30.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "rbi",  "label": "点",   "w": 30.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "avg",  "label": "率",   "w": 48.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "hr",   "label": "HR",   "w": 30.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
]

# 投手成績の列 (両チーム1表)。
const PITCH_COLS: Array = [
	{"key": "team",    "label": "チーム", "w": 64.0,  "align": HORIZONTAL_ALIGNMENT_LEFT},
	{"key": "mark",    "label": "",       "w": 28.0,  "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"key": "name",    "label": "投手",   "w": 150.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
	{"key": "throws",  "label": "",       "w": 30.0,  "align": HORIZONTAL_ALIGNMENT_CENTER},
	{"key": "w",       "label": "勝",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "l",       "label": "敗",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "s",       "label": "S",      "w": 36.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "g",       "label": "試",     "w": 44.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "ip",      "label": "回数",   "w": 56.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "bf",      "label": "打者",   "w": 48.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "pitches", "label": "球数",   "w": 52.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "h",       "label": "安",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "k",       "label": "三",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "bb",      "label": "四",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "hbp",     "label": "死",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "r",       "label": "失",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "er",      "label": "自",     "w": 40.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
	{"key": "era",     "label": "防御率", "w": 60.0,  "align": HORIZONTAL_ALIGNMENT_RIGHT},
]

const LIST_ROW_H: float = 40.0
const HIT_BG: Color = Color(0.86, 0.20, 0.18, 0.92)

var _view_team_id: int = 0
var _team_games: Array = []          # [{index, game, day}]
# ポストシーズン: 閲覧チームが関与した試合 [{stage_key, game_num, game(正規化), result}]。
# 月タブの末尾に「ポストシーズン」タブとして並べ、選択時はこちらから一覧/詳細を引く。
var _ps_games_for_view: Array = []
var _months: Array = []              # [{year, month, label}]
var _sel_month: int = 0
var _selected_index: int = -1
var _list_scroll: int = 0
var _team_button: Button = null

# 選択試合の詳細キャッシュ (_load_detail で構築)
var _cur_game: Dictionary = {}
var _cur_log: Dictionary = {}
var _box_home: bool = false
var _box_data: Dictionary = {}
var _pitching: Dictionary = {}
var _records: Dictionary = {}
var _subs: Array = []
var _line_hits: Dictionary = {}
var _line_errors: Dictionary = {}

# クリック / hover 当たり判定
var _list_row_hits: Array = []       # [{rect, index}]
var _hover_index: int = -1


func _ready() -> void:
	_init_chrome()
	_view_team_id = AppState.selected_team_id
	_reload_for_team()
	_build_buttons()
	queue_redraw()


# ============================================================ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_update_transform()
			var hit: Dictionary = _list_row_at(_to_base(event.position))
			if not hit.is_empty():
				_select_game(int(hit["index"]))
				_build_buttons()
				queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_list(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_list(-1)
	elif event is InputEventMouseMotion:
		_update_transform()
		var hit: Dictionary = _list_row_at(_to_base(event.position))
		var idx: int = int(hit.get("index", -1)) if not hit.is_empty() else -1
		if idx != _hover_index:
			_hover_index = idx
			queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


func _list_row_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _list_row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit
	return {}


func _scroll_list(delta: int) -> void:
	var games: Array = _month_games()
	var visible: int = _list_visible_rows()
	var max_scroll: int = max(0, games.size() - visible)
	var next: int = clampi(_list_scroll + delta, 0, max_scroll)
	if next != _list_scroll:
		_list_scroll = next
		queue_redraw()


func _list_visible_rows() -> int:
	return int(floor((_list_rect().size.y - 56.0) / LIST_ROW_H))


# 月タブのレイアウト。チップは LIST_W 内で横並びし、はみ出したら次行へ折り返す。
# タブ行数は月数で変わる (将来 10月・ポストシーズン追加で増える) ため動的に算出し、
# 一覧パネルは常にタブ群の下端から始める (タブと一覧パネルの重なりを防ぐ)。
func _tab_layout() -> Dictionary:
	var rects: Array = []
	var tx: float = LIST_X
	var ty: float = TABS_Y
	for mi in range(_months.size()):
		var lbl: String = str((_months[mi] as Dictionary)["label"])
		var w: float = 20.0 + _measure(lbl, 13) + 20.0
		if tx > LIST_X and tx + w > LIST_X + LIST_W:
			tx = LIST_X
			ty += TAB_ROW_H
		rects.append({"index": mi, "label": lbl, "rect": Rect2(tx, ty, w, TAB_CHIP_H)})
		tx += w + 6.0
	return {"rects": rects, "bottom": ty + TAB_CHIP_H}


func _list_rect() -> Rect2:
	var top: float = TABS_Y + TAB_CHIP_H + LIST_GAP
	if not _months.is_empty():
		top = float(_tab_layout()["bottom"]) + LIST_GAP
	return Rect2(LIST_X, top, LIST_W, LIST_BOTTOM - top)


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_list_row_hits = []

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_draw_empty()
		return

	_draw_shell("試合結果", team, season)
	_draw_game_list(season)

	if _selected_index < 0 or _cur_game.is_empty():
		_round(Rect2(RIGHT_X, TOP_Y, INNER_R - RIGHT_X, 956), PANEL, BORDER, 10)
		_text("試合を選択してください", Vector2(RIGHT_X + 40, TOP_Y + 80), 18, MUTED)
		return

	_draw_line_score(SCORE_RECT)
	_draw_summary(SUMMARY_RECT)
	_draw_box_score(BOX_RECT)
	_draw_subs(SUB_RECT)
	_draw_pitching(PITCH_RECT)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)


# --- 左カラム: 月別タブ + 試合一覧 ---

func _draw_game_list(_season: PSSeason) -> void:
	# 月タブはボタン (_build_buttons) で描く。ここでは一覧パネルを描く。
	var rect: Rect2 = _list_rect()
	_round(rect, PANEL, BORDER, 10)
	var games: Array = _month_games()
	var header_y: float = rect.position.y + 30
	if _months.is_empty():
		_text("試合がありません", Vector2(rect.position.x + 16, header_y + 30), 14, MUTED)
		return
	var month: Dictionary = _months[_sel_month] as Dictionary
	_text("%d年 %s" % [int(month["year"]), str(month["label"])], Vector2(rect.position.x + 16, header_y), 15, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text_right("%d試合" % games.size(), rect.end.x - 16, header_y, 12, MUTED, 80)
	_line(Vector2(rect.position.x + 14, header_y + 12), Vector2(rect.end.x - 14, header_y + 12), BORDER_SOFT, 1.0)

	if games.is_empty():
		_text("この月の試合はありません", Vector2(rect.position.x + 16, header_y + 44), 13, MUTED)
		return

	var visible: int = _list_visible_rows()
	var top: float = header_y + 26.0
	var ix: float = rect.position.x + 14.0
	var iw: float = rect.size.x - 28.0
	for i in range(visible):
		var gi: int = _list_scroll + i
		if gi >= games.size():
			break
		var entry: Dictionary = games[gi] as Dictionary
		var index: int = int(entry["index"])
		var game: Dictionary = entry["game"] as Dictionary
		var ry: float = top + float(i) * LIST_ROW_H
		var row_rect: Rect2 = Rect2(ix, ry, iw, LIST_ROW_H - 4.0)
		var selected: bool = index == _selected_index
		if selected:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.16), Color(BLUE.r, BLUE.g, BLUE.b, 0.5), 6)
		elif index == _hover_index:
			_round(row_rect, Color(1, 1, 1, 0.05), Color.TRANSPARENT, 6, 0)
		_draw_list_row(row_rect, game)
		_list_row_hits.append({"rect": row_rect, "index": index})

	# スクロールインジケータ
	if games.size() > visible:
		_text_right("%d–%d / %d" % [_list_scroll + 1, min(_list_scroll + visible, games.size()), games.size()],
			rect.end.x - 16, rect.end.y - 14, 11, FAINT, 120)


func _draw_list_row(rect: Rect2, game: Dictionary) -> void:
	var color: Color = _game_color(game)
	var symbol: String = _result_symbol(game)
	var cy: float = rect.position.y + rect.size.y * 0.5 + 5.0
	# 勝敗マーク: 白星=白丸 / 黒星=黒丸+白縁 / 引分=△(試合結果色)。
	_draw_result_mark(Vector2(rect.position.x + 17, rect.position.y + rect.size.y * 0.5), 6.0, symbol, color)
	# 日付 (ポストシーズンはステージ+第N戦ラベル)
	var date_label: String = str(game.get("ps_label", "")) if game.has("ps_label") else SeasonCalendar.compact_label_for_game(game, AppState.current_season)
	_text(date_label, Vector2(rect.position.x + 30, cy), 12, MUTED, 76)
	# 対戦
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var is_home: bool = home_id == _view_team_id
	var opp_id: int = away_id if is_home else home_id
	var venue: String = "vs" if is_home else "@"
	_text("%s %s" % [venue, _team_short(opp_id)], Vector2(rect.position.x + 108, cy), 13, TEXT, 110)
	# スコア (自軍 - 相手)
	var us: int = int(game.get("home_score", 0)) if is_home else int(game.get("away_score", 0))
	var them: int = int(game.get("away_score", 0)) if is_home else int(game.get("home_score", 0))
	_text_right("%d - %d" % [us, them], rect.end.x - 10, cy, 13, TEXT, 70)


# --- 上段: イニングスコア ---

func _draw_line_score(rect: Rect2) -> void:
	_panel(rect, "イニングスコア")
	var game: Dictionary = _cur_game
	var innings: Array = _line_score_innings(game, _cur_log)
	var inning_count: int = max(9, innings.size())
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))

	var label_w: float = 74.0
	var totals_w: float = 132.0  # R H E
	var grid_x: float = rect.position.x + 16.0 + label_w
	var grid_w: float = rect.size.x - 32.0 - label_w - totals_w
	var cell_w: float = grid_w / float(inning_count)
	var hy: float = rect.position.y + 76.0
	var r1: float = rect.position.y + 110.0
	var r2: float = rect.position.y + 144.0

	# ヘッダ (イニング番号 + R/H/E)
	for i in range(inning_count):
		_text(str(i + 1), Vector2(grid_x + float(i) * cell_w, hy), 12, FAINT, cell_w, HORIZONTAL_ALIGNMENT_CENTER)
	var tx: float = grid_x + grid_w
	var tcol_w: float = totals_w / 3.0
	for j in range(3):
		_text(["R", "H", "E"][j], Vector2(tx + float(j) * tcol_w, hy), 12, FAINT, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)
	_line(Vector2(rect.position.x + 16, hy + 8), Vector2(rect.end.x - 16, hy + 8), BORDER_SOFT, 1.0)

	_draw_line_row(rect, away_id, false, innings, inning_count, grid_x, cell_w, tx, tcol_w, r1)
	_draw_line_row(rect, home_id, true, innings, inning_count, grid_x, cell_w, tx, tcol_w, r2)


func _draw_line_row(rect: Rect2, team_id: int, is_home: bool, innings: Array, inning_count: int, grid_x: float, cell_w: float, tx: float, tcol_w: float, y: float) -> void:
	var team: PSTeam = GameDb.get_team(team_id)
	if team != null:
		# バッジに略称が入るため、重複する短縮名テキストは描かない。
		_team_badge(Rect2(rect.position.x + 16, y - 18, 24, 24), team)
	for i in range(inning_count):
		var txt: String = ""
		if i < innings.size():
			var entry: Dictionary = innings[i] as Dictionary
			if is_home and not bool(entry.get("home_half_played", true)):
				txt = "X"
			else:
				txt = str(int(entry.get("home" if is_home else "away", 0)))
		_text(txt, Vector2(grid_x + float(i) * cell_w, y), 13, TEXT, cell_w, HORIZONTAL_ALIGNMENT_CENTER)
	var runs: int = int(_cur_game.get("home_score" if is_home else "away_score", 0))
	var hits: int = int(_line_hits.get(team_id, 0))
	var errs: int = int(_line_errors.get(team_id, 0))
	_text(str(runs), Vector2(tx, y), 14, TEXT, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text(str(hits), Vector2(tx + tcol_w, y), 13, MUTED, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text(str(errs), Vector2(tx + tcol_w * 2.0, y), 13, MUTED, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)


func _line_score_innings(game: Dictionary, log: Dictionary = {}) -> Array:
	var innings: Array = _array_value(game.get("innings", []))
	if not innings.is_empty():
		return innings
	var result: Dictionary = game.get("result", {}) as Dictionary
	innings = _array_value(result.get("innings", []))
	if not innings.is_empty():
		return innings
	return _array_value(log.get("innings", []))


func _array_value(value: Variant) -> Array:
	if value is Array:
		return value as Array
	return []


# --- 上段: サマリー (勝敗投手 + 記録) ---

func _draw_summary(rect: Rect2) -> void:
	_panel(rect, "サマリー")
	var result: Dictionary = _cur_game.get("result", {}) as Dictionary
	var ox: float = rect.position.x + 18.0
	var y: float = rect.position.y + 70.0

	if bool(result.get("draw", false)):
		_text("引き分け", Vector2(ox, y), 16, AMBER)
	else:
		var win_id: int = int(result.get("winning_pitcher_id", 0))
		var loss_id: int = int(result.get("losing_pitcher_id", 0))
		var save_id: int = int(result.get("save_pitcher_id", 0))
		var holds: Array = result.get("hold_pitcher_ids", []) as Array
		# 勝/敗/S を横並びチップ風に
		_text("勝", Vector2(ox, y), 13, GREEN, 22)
		_text(_pitcher_label(win_id), Vector2(ox + 26, y), 14, TEXT, 240)
		_text("敗", Vector2(ox + 320, y), 13, RED, 22)
		_text(_pitcher_label(loss_id), Vector2(ox + 346, y), 14, TEXT, 280)
		y += 30
		if save_id > 0:
			_text("S", Vector2(ox, y), 13, AMBER, 22)
			_text(_pitcher_label(save_id), Vector2(ox + 26, y), 14, TEXT, 240)
		if not holds.is_empty():
			var labels: Array = []
			for pid in holds:
				labels.append(_player_name(int(pid)))
			_text("H", Vector2(ox + 320, y), 13, BLUE, 22)
			_text("、".join(labels), Vector2(ox + 346, y), 13, MUTED, 280)
		y += 30

	_line(Vector2(ox, y - 6), Vector2(rect.end.x - 18, y - 6), BORDER_SOFT, 1.0)

	var hr: Array = _records.get("hr", []) as Array
	var errors: Array = _records.get("errors", []) as Array
	_text("◇本塁打", Vector2(ox, y + 18), 12, MUTED, 70)
	_text("　".join(hr) if not hr.is_empty() else "なし", Vector2(ox + 76, y + 18), 12, TEXT, rect.size.x - 110)
	_text("◇失策", Vector2(ox, y + 44), 12, MUTED, 70)
	_text("　".join(errors) if not errors.is_empty() else "なし", Vector2(ox + 76, y + 44), 12, TEXT, rect.size.x - 110)


# --- 中段: 打席結果 (ボックススコア) ---

func _draw_box_score(rect: Rect2) -> void:
	_round(rect, PANEL, BORDER, 10)
	var label: String = "打席結果（%s）" % ("ホーム" if _box_home else "ビジター")
	_text(label, Vector2(rect.position.x + 18, rect.position.y + 32), 16, TEXT)
	# ビジター/ホーム切替チップは _build_buttons で配置。

	var rows: Array = _box_data.get("rows", []) as Array
	var totals: Dictionary = _box_data.get("totals", {}) as Dictionary
	var inning_count: int = max(9, int(_box_data.get("inning_count", 9)))
	# 列構成 (打者一巡で同一イニングに複数列)。古いデータ等で無ければイニング単列にフォールバック。
	var columns: Array = _box_data.get("columns", []) as Array
	if columns.is_empty():
		for inn in range(1, inning_count + 1):
			columns.append({"inning": inn, "round": 0})
	var col_count: int = columns.size()
	var expanded: bool = col_count > inning_count  # 打者一巡で列が増えている

	var ix: float = rect.position.x + 16.0
	var iw: float = rect.size.x - 32.0
	# 固定列幅合計
	var fixed_w: float = 0.0
	for c_value in BOX_FIXED:
		fixed_w += float((c_value as Dictionary)["w"])
	var inn_w: float = (iw - fixed_w) / float(col_count)

	var hy: float = rect.position.y + 64.0
	# 固定列ヘッダ
	var cx: float = ix
	for c_value in BOX_FIXED:
		var c: Dictionary = c_value as Dictionary
		_text(str(c["label"]), Vector2(cx, hy), 11, FAINT, float(c["w"]), c["align"] as int)
		cx += float(c["w"])
	var grid_x: float = cx

	# 行高は行数 (選手 + 計) に合わせてフィット
	var line_count: int = rows.size() + 1
	var avail: float = rect.end.y - (hy + 16.0)
	var row_h: float = clampf(avail / float(max(1, line_count)), 18.0, 26.0)
	var top: float = hy + 16.0
	var grid_bottom: float = top + float(line_count) * row_h

	# イニングヘッダ: 同一イニングの列をまとめ、番号をグループ中央に置く。
	var gi: int = 0
	while gi < col_count:
		var inn: int = int((columns[gi] as Dictionary)["inning"])
		var span: int = 1
		while gi + span < col_count and int((columns[gi + span] as Dictionary)["inning"]) == inn:
			span += 1
		_text(str(inn), Vector2(grid_x + float(gi) * inn_w, hy), 11, FAINT, inn_w * float(span), HORIZONTAL_ALIGNMENT_CENTER)
		# 列が増えているイニングがあるときだけ、グループ境界に薄い区切り線を引いて見やすくする。
		if expanded and gi > 0:
			_line(Vector2(grid_x + float(gi) * inn_w, hy + 4), Vector2(grid_x + float(gi) * inn_w, grid_bottom), BORDER_SOFT, 1.0)
		gi += span
	_line(Vector2(ix, hy + 8), Vector2(rect.end.x - 16, hy + 8), BORDER_SOFT, 1.0)

	for ri in range(rows.size()):
		var row: Dictionary = rows[ri] as Dictionary
		var ry: float = top + float(ri) * row_h
		var ty: float = ry + row_h * 0.5 + 4.0
		_draw_box_row(row, ix, fixed_w, inn_w, col_count, ty, ry, row_h, false)

	# 計 (合計) 行
	if not totals.is_empty():
		var ry: float = top + float(rows.size()) * row_h
		var ty: float = ry + row_h * 0.5 + 4.0
		var total_row: Dictionary = {
			"pos": "計",
			"name": "併殺 %d" % int(totals.get("gidp", 0)),
			"bats": "",
			"ab": int(totals.get("ab", 0)),
			"h": int(totals.get("h", 0)),
			"rbi": int(totals.get("rbi", 0)),
			"avg": float(totals.get("avg", 0.0)),
			"hr": int(totals.get("hr", 0)),
			"cells": [],
		}
		_draw_box_row(total_row, ix, fixed_w, inn_w, col_count, ty, ry, row_h, true)


func _draw_box_row(row: Dictionary, ix: float, fixed_w: float, inn_w: float, col_count: int, ty: float, ry: float, row_h: float, is_total: bool) -> void:
	var col: Color = MUTED.lerp(TEXT, 0.6) if is_total else TEXT
	var cx: float = ix
	for c_value in BOX_FIXED:
		var c: Dictionary = c_value as Dictionary
		var key: String = str(c["key"])
		var w: float = float(c["w"])
		var txt: String = ""
		match key:
			"avg":
				txt = _fmt_avg(float(row.get("avg", 0.0)))
			"bats":
				var b: String = str(row.get("bats", ""))
				txt = "(%s)" % b if not b.is_empty() else ""
			"ab", "h", "rbi", "hr":
				txt = str(int(row.get(key, 0)))
			_:
				txt = str(row.get(key, ""))
		_text(txt, Vector2(cx, ty), 12, col, w, c["align"] as int)
		cx += w
	# イニングセル (列ごと)
	var cells: Array = row.get("cells", []) as Array
	for i in range(col_count):
		var cell_x: float = cx + float(i) * inn_w
		if i < cells.size():
			var cell: Dictionary = cells[i] as Dictionary
			var text: String = str(cell.get("text", ""))
			if text.is_empty():
				continue
			if bool(cell.get("is_hit", false)):
				_round(Rect2(cell_x + 1.0, ry + 2.0, inn_w - 2.0, row_h - 4.0), HIT_BG, Color.TRANSPARENT, 4)
				_text(text, Vector2(cell_x, ty), 11, Color.WHITE, inn_w, HORIZONTAL_ALIGNMENT_CENTER)
			else:
				_text(text, Vector2(cell_x, ty), 11, col, inn_w, HORIZONTAL_ALIGNMENT_CENTER)


# --- 中段: 交代 ---

func _draw_subs(rect: Rect2) -> void:
	_panel(rect, "交代")
	var ox: float = rect.position.x + 16.0
	var hy: float = rect.position.y + 60.0
	var cols: Array = [
		{"label": "回", "x": ox, "w": 52.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "種別", "x": ox + 56.0, "w": 74.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "OUT", "x": ox + 134.0, "w": 130.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "→ IN", "x": ox + 270.0, "w": 150.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "守", "x": rect.end.x - 50.0, "w": 34.0, "align": HORIZONTAL_ALIGNMENT_CENTER},
	]
	for c_value in cols:
		var c: Dictionary = c_value as Dictionary
		_text(str(c["label"]), Vector2(float(c["x"]), hy), 11, FAINT, float(c["w"]), c["align"] as int)
	_line(Vector2(ox, hy + 8), Vector2(rect.end.x - 16, hy + 8), BORDER_SOFT, 1.0)

	if _subs.is_empty():
		_text("交代はありませんでした", Vector2(ox, hy + 40), 13, MUTED)
		return

	var top: float = hy + 18.0
	var row_h: float = clampf((rect.end.y - top - 8.0) / float(_subs.size()), 18.0, 28.0)
	for si in range(_subs.size()):
		var entry: Dictionary = _subs[si] as Dictionary
		var ty: float = top + float(si) * row_h + row_h * 0.5 + 4.0
		var pos: int = int(entry.get("position", 0))
		var team: PSTeam = GameDb.get_team(int(entry.get("team_id", 0)))
		var team_dot: Color = team.color if team != null else MUTED
		_dot(Vector2(ox + 4, ty - 4), 3, team_dot)
		_text(_half_label(int(entry.get("inning", 0)), str(entry.get("half", ""))), Vector2(ox + 12, ty), 12, MUTED, 44)
		_text(str(SUB_KIND_LABELS.get(str(entry.get("kind", "")), "")), Vector2(ox + 56.0, ty), 12, TEXT, 74)
		_text(_player_name(int(entry.get("out_id", 0))), Vector2(ox + 134.0, ty), 12, MUTED, 130)
		_text("→ %s" % _player_name(int(entry.get("in_id", 0))), Vector2(ox + 270.0, ty), 12, TEXT, 150)
		_text(str(POSITION_LABELS.get(pos, "")) if pos > 0 else "", Vector2(rect.end.x - 50.0, ty), 12, MUTED, 34, HORIZONTAL_ALIGNMENT_CENTER)


# --- 下段: 投手成績 ---

func _draw_pitching(rect: Rect2) -> void:
	_panel(rect, "投手成績")
	var rows: Array = _pitching.get("rows", []) as Array
	var ix: float = rect.position.x + 18.0
	var hy: float = rect.position.y + 60.0

	var cx: float = ix
	for c_value in PITCH_COLS:
		var c: Dictionary = c_value as Dictionary
		_text(str(c["label"]), Vector2(cx, hy), 11, FAINT, float(c["w"]), c["align"] as int)
		cx += float(c["w"])
	_line(Vector2(ix, hy + 8), Vector2(rect.end.x - 18, hy + 8), BORDER_SOFT, 1.0)

	if rows.is_empty():
		_text("投手成績がありません", Vector2(ix, hy + 40), 13, MUTED)
		return

	var top: float = hy + 16.0
	var row_h: float = clampf((rect.end.y - top - 8.0) / float(rows.size()), 18.0, 28.0)
	var prev_team: int = -999
	for ri in range(rows.size()):
		var row: Dictionary = rows[ri] as Dictionary
		var ry: float = top + float(ri) * row_h
		var ty: float = ry + row_h * 0.5 + 4.0
		var tid: int = int(row.get("team_id", 0))
		if tid != prev_team and ri > 0:
			_line(Vector2(ix, ry), Vector2(rect.end.x - 18, ry), BORDER_SOFT, 1.0)
		prev_team = tid
		var cx2: float = ix
		for c_value in PITCH_COLS:
			var c: Dictionary = c_value as Dictionary
			var key: String = str(c["key"])
			var w: float = float(c["w"])
			var txt: String = ""
			var col: Color = TEXT
			match key:
				"team":
					txt = _team_short(tid)
					col = MUTED
				"mark":
					var raw: String = str(row.get("mark", ""))
					if raw == "○" or raw == "●":
						# 勝利投手=白丸 / 敗戦投手=黒丸+白縁。テキストは描かない。
						_draw_result_mark(Vector2(cx2 + w * 0.5, ty - 4), 5.0, raw, TEXT)
						txt = ""
					else:
						txt = raw  # Ｓ / Ｈ / なし
						col = _mark_color(raw)
				"throws":
					var th: String = str(row.get("throws", ""))
					txt = "(%s)" % th if not th.is_empty() else ""
					col = FAINT
				"era":
					txt = "%0.2f" % float(row.get("era", 0.0))
				"ip", "name":
					txt = str(row.get(key, ""))
				_:
					txt = str(int(row.get(key, 0)))
			_text(txt, Vector2(cx2, ty), 12, col, w, c["align"] as int)
			cx2 += w


# 白星 (○) / 黒星 (●) は白字。引分 (△) は fallback (試合結果色)。投手の S/H はアンバー/青。
func _mark_color(mark: String, fallback: Color = TEXT) -> Color:
	match mark:
		"○", "●": return TEXT
		"Ｓ": return AMBER
		"Ｈ": return BLUE
	return fallback


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# ヘッダ右: 表示チーム切替
	var view_team: PSTeam = GameDb.get_team(_view_team_id)
	var team_label: String = "表示: %s ▾" % (view_team.short_name if view_team != null else "-")
	_team_button = _add_button("view_team", team_label, Rect2(1660, 22, 240, 42), _on_team_button_pressed, "action")

	# 月タブ (左カラム上部に横並び、はみ出したら折り返す。一覧パネルはタブ下端から始まる)
	for tab_value in (_tab_layout()["rects"] as Array):
		var tab: Dictionary = tab_value as Dictionary
		var mi: int = int(tab["index"])
		_add_button("month_%d" % mi, str(tab["label"]), tab["rect"] as Rect2,
			func(target: int = mi) -> void: _set_month(target),
			"chip_active" if mi == _sel_month else "chip")

	# 打席結果: ビジター/ホーム切替チップ (パネルヘッダ右)
	if _selected_index >= 0 and not _cur_game.is_empty():
		var away_id: int = int(_cur_game.get("away_team_id", 0))
		var home_id: int = int(_cur_game.get("home_team_id", 0))
		var aw: float = 18.0 + _measure(_team_short(away_id), 13) + 18.0
		var hw: float = 18.0 + _measure(_team_short(home_id), 13) + 18.0
		var hx: float = BOX_RECT.end.x - 12.0 - hw
		var ax: float = hx - 6.0 - aw
		_add_button("box_away", _team_short(away_id), Rect2(ax, BOX_RECT.position.y + 14, aw, 28),
			func() -> void: _set_box_team(false), "chip_active" if not _box_home else "chip")
		_add_button("box_home", _team_short(home_id), Rect2(hx, BOX_RECT.position.y + 14, hw, 28),
			func() -> void: _set_box_team(true), "chip_active" if _box_home else "chip")

	_layout_buttons()


func _on_team_button_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	for ti in range(GameDb.teams.size()):
		var t: PSTeam = GameDb.teams[ti] as PSTeam
		if t == null:
			continue
		menu.add_item(t.name, t.id)
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(func(id: int) -> void: _on_team_selected(id))
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = Vector2(1660, 64)
	if _team_button != null:
		anchor = _team_button.global_position + Vector2(0.0, _team_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_team_selected(team_id: int) -> void:
	if team_id == _view_team_id:
		return
	_view_team_id = team_id
	_reload_for_team()
	_build_buttons()
	queue_redraw()


func _set_month(index: int) -> void:
	if index < 0 or index >= _months.size():
		return
	_sel_month = index
	_list_scroll = 0
	_select_latest_in_month()
	_build_buttons()
	queue_redraw()


func _set_box_team(is_home: bool) -> void:
	if _box_home == is_home:
		return
	_box_home = is_home
	_box_data = BoxScoreBuilder.build(_cur_log, int(_cur_game.get("home_team_id" if _box_home else "away_team_id", 0)), AppState.current_season)
	_build_buttons()
	queue_redraw()


# ダッシュボードのダーク配色に合わせて PopupMenu をテーマ上書きする (home_screen から移植)。
func _style_popup(menu: PopupMenu) -> void:
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = PANEL_2
	panel.border_color = BORDER
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(8)
	panel.content_margin_left = 6
	panel.content_margin_right = 6
	panel.content_margin_top = 6
	panel.content_margin_bottom = 6
	menu.add_theme_stylebox_override("panel", panel)

	var hover: StyleBoxFlat = StyleBoxFlat.new()
	hover.bg_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.18)
	hover.border_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.55)
	hover.set_border_width_all(1)
	hover.set_corner_radius_all(6)
	menu.add_theme_stylebox_override("hover", hover)

	menu.add_theme_color_override("font_color", TEXT)
	menu.add_theme_color_override("font_hover_color", TEXT)
	menu.add_theme_constant_override("v_separation", 6)
	menu.add_theme_font_size_override("font_size", max(11, int(round(14.0 * _scale_f))))


# ============================================================ data / selection

func _reload_for_team() -> void:
	_team_games = _collect_team_games(_view_team_id)
	_months = _build_months(_team_games)
	_ps_games_for_view = _collect_ps_games(_view_team_id)
	if not _ps_games_for_view.is_empty():
		var season: PSSeason = AppState.current_season
		_months.append({"year": season.year if season != null else 0, "key": "postseason", "label": "ポストシーズン"})
	_list_scroll = 0
	if _months.is_empty():
		_sel_month = 0
		_clear_selection()
		return
	_sel_month = _months.size() - 1  # 既定は最新の月 (ポストシーズン進行中ならポストシーズン)
	_select_latest_in_month()


func _selected_is_ps() -> bool:
	if _months.is_empty() or _sel_month < 0 or _sel_month >= _months.size():
		return false
	return str((_months[_sel_month] as Dictionary).get("key", "")) == "postseason"


# 閲覧チームが関与したポストシーズン試合を日順に集める。
func _collect_ps_games(team_id: int) -> Array:
	var out: Array = []
	var post: PSPostseasonResult = AppState.current_postseason
	if post == null or team_id <= 0:
		return out
	var rows: Array = []
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var series: Dictionary = post.stage_dict(str(stage_key))
		for game_value in (series.get("games", []) as Array):
			var game: Dictionary = game_value as Dictionary
			if int(game.get("away_id", 0)) != team_id and int(game.get("home_id", 0)) != team_id:
				continue
			rows.append({"stage_key": str(stage_key), "game": game})
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ga: Dictionary = (a as Dictionary)["game"] as Dictionary
		var gb: Dictionary = (b as Dictionary)["game"] as Dictionary
		if int(ga.get("day", 0)) == int(gb.get("day", 0)):
			return int(ga.get("game_num", 0)) < int(gb.get("game_num", 0))
		return int(ga.get("day", 0)) < int(gb.get("day", 0))
	)
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		out.append(_build_ps_entry(str(row["stage_key"]), row["game"] as Dictionary))
	return out


# ポストシーズン試合を、詳細描画系が読める正規化 game へ変換した entry を作る。
func _build_ps_entry(stage_key: String, game: Dictionary) -> Dictionary:
	var result: Dictionary = game.get("result", {}) as Dictionary
	var normalized: Dictionary = {
		"away_team_id": int(game.get("away_id", 0)),
		"home_team_id": int(game.get("home_id", 0)),
		"away_score": int(game.get("away_score", 0)),
		"home_score": int(game.get("home_score", 0)),
		"innings": result.get("innings", []) as Array,
		"result": result,
		"played": true,
		"ps_label": "%s 第%d戦" % [_ps_stage_short(stage_key), int(game.get("game_num", 0))],
	}
	return {
		"stage_key": stage_key,
		"game_num": int(game.get("game_num", 0)),
		"game": normalized,
		"result": result,
	}


func _ps_stage_short(stage_key: String) -> String:
	match stage_key:
		"cs1_central": return "CS1 第1L"
		"cs1_pacific": return "CS1 第2L"
		"cs2_central": return "CSF 第1L"
		"cs2_pacific": return "CSF 第2L"
		"japan_series": return "日本S"
	return stage_key


func _collect_team_games(team_id: int) -> Array:
	var out: Array = []
	var season: PSSeason = AppState.current_season
	if season == null or team_id <= 0:
		return out
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			continue
		if int(game.get("away_team_id", 0)) != team_id and int(game.get("home_team_id", 0)) != team_id:
			continue
		out.append({"index": index, "game": game, "day": int(game.get("day", 0))})
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int((a as Dictionary)["day"]) < int((b as Dictionary)["day"])
	)
	return out


# 月バケット。開幕月の3月は試合数が少ないため4月とまとめて 1 タブにする。
func _bucket_for_date(date_text: String) -> Dictionary:
	var parts: PackedStringArray = date_text.split("-")
	if parts.size() < 2:
		return {}
	var year: int = int(parts[0])
	var month: int = int(parts[1])
	if month == 3 or month == 4:
		return {"year": year, "key": "%d-0304" % year, "label": "3・4月"}
	return {"year": year, "key": "%d-%02d" % [year, month], "label": "%d月" % month}


func _build_months(games: Array) -> Array:
	var months: Array = []
	var seen: Dictionary = {}
	var season: PSSeason = AppState.current_season
	for entry_value in games:
		var entry: Dictionary = entry_value as Dictionary
		var bucket: Dictionary = _bucket_for_date(_date_for_game(entry["game"] as Dictionary, season))
		if bucket.is_empty():
			continue
		var key: String = str(bucket["key"])
		if seen.has(key):
			continue
		seen[key] = true
		months.append(bucket)
	return months


func _month_games() -> Array:
	if _months.is_empty():
		return []
	if _selected_is_ps():
		var ps_out: Array = []
		for i in range(_ps_games_for_view.size()):
			var e: Dictionary = _ps_games_for_view[i] as Dictionary
			ps_out.append({"index": i, "game": e["game"], "day": i})
		return ps_out
	var key: String = str((_months[_sel_month] as Dictionary)["key"])
	var season: PSSeason = AppState.current_season
	var out: Array = []
	for entry_value in _team_games:
		var entry: Dictionary = entry_value as Dictionary
		var bucket: Dictionary = _bucket_for_date(_date_for_game(entry["game"] as Dictionary, season))
		if not bucket.is_empty() and str(bucket["key"]) == key:
			out.append(entry)
	return out


func _select_latest_in_month() -> void:
	var games: Array = _month_games()
	if games.is_empty():
		_clear_selection()
		return
	# 月内の最新試合を選ぶ。スクロールも末尾へ寄せる。
	var visible: int = _list_visible_rows()
	_list_scroll = max(0, games.size() - visible)
	_select_game(int((games[games.size() - 1] as Dictionary)["index"]))


func _select_game(index: int) -> void:
	_selected_index = index
	if _selected_is_ps():
		_load_ps_detail(index)
	else:
		_load_detail()


func _load_ps_detail(index: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null or index < 0 or index >= _ps_games_for_view.size():
		_clear_selection()
		return
	var entry: Dictionary = _ps_games_for_view[index] as Dictionary
	_cur_game = entry["game"] as Dictionary
	_cur_log = _ps_game_log(season, str(entry["stage_key"]), int(entry["game_num"]), entry["result"] as Dictionary)
	_box_home = int(_cur_game.get("home_team_id", 0)) == _view_team_id
	_box_data = BoxScoreBuilder.build(_cur_log, int(_cur_game.get("home_team_id" if _box_home else "away_team_id", 0)), season)
	_pitching = BoxScoreBuilder.build_pitching(_cur_log, season)
	_records = BoxScoreBuilder.build_records(_cur_log, season)
	_subs = _cur_log.get("substitutions", []) as Array
	_compute_line_aux()


# メモリ上の完全結果 (今セッション分) を優先、無ければポストシーズンログファイルから読む。
func _ps_game_log(season: PSSeason, stage_key: String, game_num: int, result: Dictionary) -> Dictionary:
	var play_events: Array = result.get("play_events", []) as Array
	if not play_events.is_empty():
		return {
			"pa_log": GameLogService.build_pa_log(result, season),
			"substitutions": result.get("substitutions", []) as Array,
			"lineups": result.get("lineups", {}) as Dictionary,
			"pitcher_outings": result.get("pitcher_outings", []) as Array,
			"errors": GameLogService.build_error_log(result),
			"decisions": {
				"winning_pitcher_id": int(result.get("winning_pitcher_id", 0)),
				"losing_pitcher_id": int(result.get("losing_pitcher_id", 0)),
				"save_pitcher_id": int(result.get("save_pitcher_id", 0)),
				"hold_pitcher_ids": result.get("hold_pitcher_ids", []) as Array,
			},
		}
	return GameLogService.read_postseason_game_log(season, stage_key, game_num)


func _clear_selection() -> void:
	_selected_index = -1
	_cur_game = {}
	_cur_log = {}
	_box_data = {}
	_pitching = {}
	_records = {}
	_subs = []
	_line_hits = {}
	_line_errors = {}


func _load_detail() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _selected_index < 0 or _selected_index >= season.schedule.size():
		_clear_selection()
		return
	_cur_game = season.schedule[_selected_index] as Dictionary
	_cur_log = _game_log_for(season, _selected_index, _cur_game)
	# 打席結果の既定チーム = 表示チーム (出場していれば)、それ以外はビジター。
	_box_home = int(_cur_game.get("home_team_id", 0)) == _view_team_id
	_box_data = BoxScoreBuilder.build(_cur_log, int(_cur_game.get("home_team_id" if _box_home else "away_team_id", 0)), season)
	_pitching = BoxScoreBuilder.build_pitching(_cur_log, season)
	_records = BoxScoreBuilder.build_records(_cur_log, season)
	_subs = _cur_log.get("substitutions", []) as Array
	_compute_line_aux()


# イニングスコアの H (安打) / E (失策) をログから集計。
func _compute_line_aux() -> void:
	_line_hits = {}
	_line_errors = {}
	for row_value in (_cur_log.get("pa_log", []) as Array):
		var pa: Dictionary = row_value as Dictionary
		if str(pa.get("category", "")) == "hit":
			var tid: int = int(pa.get("batting_team_id", 0))
			_line_hits[tid] = int(_line_hits.get(tid, 0)) + 1
	for e_value in (_cur_log.get("errors", []) as Array):
		var e: Dictionary = e_value as Dictionary
		var ftid: int = int(e.get("fielding_team_id", 0))
		_line_errors[ftid] = int(_line_errors.get(ftid, 0)) + 1


# メモリ上の完全結果 (今セッション分) を優先、無ければ年別ログファイルから読む。
func _game_log_for(season: PSSeason, schedule_index: int, game: Dictionary) -> Dictionary:
	var result: Dictionary = game.get("result", {}) as Dictionary
	var play_events: Array = result.get("play_events", []) as Array
	if not play_events.is_empty():
		return {
			"pa_log": GameLogService.build_pa_log(result, season),
			"substitutions": result.get("substitutions", []) as Array,
			"lineups": result.get("lineups", {}) as Dictionary,
			"pitcher_outings": result.get("pitcher_outings", []) as Array,
			"errors": GameLogService.build_error_log(result),
			"decisions": {
				"winning_pitcher_id": int(result.get("winning_pitcher_id", 0)),
				"losing_pitcher_id": int(result.get("losing_pitcher_id", 0)),
				"save_pitcher_id": int(result.get("save_pitcher_id", 0)),
				"hold_pitcher_ids": result.get("hold_pitcher_ids", []) as Array,
			},
		}
	return GameLogService.read_game_log(season, schedule_index)


# ============================================================ helpers

func _date_for_game(game: Dictionary, season: PSSeason) -> String:
	var date_text: String = str(game.get("date", ""))
	if not date_text.is_empty():
		return date_text
	return SeasonCalendar.date_for_season_day(season, int(game.get("day", 1)))


func _result_symbol(game: Dictionary) -> String:
	var result: Dictionary = game.get("result", {}) as Dictionary
	if bool(result.get("draw", false)):
		return "△"
	return "○" if int(result.get("winning_team_id", 0)) == _view_team_id else "●"


func _game_color(game: Dictionary) -> Color:
	var result: Dictionary = game.get("result", {}) as Dictionary
	if bool(result.get("draw", false)):
		return AMBER
	return GREEN if int(result.get("winning_team_id", 0)) == _view_team_id else RED


func _half_label(inning: int, half: String) -> String:
	return "%d%s" % [inning, "表" if half == "top" else "裏"]


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.short_name if team != null else "-"


func _player_name(player_id: int) -> String:
	if player_id <= 0:
		return "-"
	var season: PSSeason = AppState.current_season
	if season == null:
		return "-"
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
	return record.name if record != null else "#%d" % player_id


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


func _fmt_avg(value: float) -> String:
	var s: String = "%0.3f" % value
	if s.begins_with("0"):
		s = s.substr(1)
	return s
