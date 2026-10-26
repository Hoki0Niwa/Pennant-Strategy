extends "res://ui/components/dashboard_screen.gd"

# 試合結果画面。左で月別の試合一覧を選び、右で選択試合のスコア、打席結果、交代、投手成績を描く。
# 試合ログの読み込みと集計は _load_detail で一度だけ行い、_draw はキャッシュ済み detail の描画に専念する。
# _draw は hover やスクロールで頻繁に走るため、重い GameLogService/BoxScoreBuilder 呼び出しを入れない。

const GameLogService = preload("res://services/storage/game_log_service.gd")
const BoxScoreBuilder = preload("res://services/reports/box_score_builder.gd")

# 交代種別の表示名キー (Loc)。
const SUB_KIND_LABELS: Dictionary = {
	"pitching": "game_result.sub.pitching", "pinch_hit": "game_log.appearance.pinch_hit",
	"pinch_run": "game_log.appearance.pinch_run", "defense": "game_result.sub.defense",
	"position_change": "game_result.sub.position_change",
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

# 月間試合リストの列 (日付 | 対戦相手 | 勝敗・スコア)。w は usable 幅 (LIST_W - 24) と同じ合計にして倍率 1.0 で描く。
const LIST_COLUMNS: Array = [
	{"key": "date",  "title": "col.date",              "w": 78,  "align": "l", "fmt": "str", "muted": true, "group": "game_result.group.list_date"},
	{"key": "opp",   "title": "col.opponent",          "w": 132, "align": "l", "fmt": "str", "group": "game_result.group.list_opponent", "sep_before": true},
	{"key": "mark",  "title": "game_result.col.result", "w": 36,  "align": "c", "fmt": "str", "group": "game_result.group.list_result", "sep_before": true},
	{"key": "score", "title": "game_result.col.score", "w": 78,  "align": "r", "fmt": "str", "strong": true, "group": "game_result.group.list_result"},
]

# 打席結果表の固定列 (守備 | 選手・打 | 本日打撃 | 通算)。イニング列は _box_columns が末尾に足す。
# 守備位置バッジとイニングセルは表の上に重ね描きするので、その列の行値は空にしておく。
const BOX_PRE_COLUMNS: Array = [
	{"key": "pos",  "title": "box.col.pos",    "w": 46, "align": "c", "fmt": "str", "group": "game_result.group.box_pos"},
	{"key": "name", "title": "col.player",     "w": 98, "align": "l", "fmt": "player_name", "strong": true, "sep_before": true, "group": "game_result.group.box_player"},
	{"key": "bats", "title": "lineup.col.bats", "w": 28, "align": "c", "fmt": "str", "muted": true, "group": "game_result.group.box_player"},
	{"key": "ab",   "title": "box.col.ab",     "w": 30, "align": "r", "fmt": "int", "sep_before": true, "group": "game_result.group.box_today"},
	{"key": "h",    "title": "box.col.h",      "w": 30, "align": "r", "fmt": "int", "group": "game_result.group.box_today"},
	{"key": "rbi",  "title": "box.col.rbi",    "w": 30, "align": "r", "fmt": "int", "group": "game_result.group.box_today"},
	{"key": "avg",  "title": "box.col.avg",    "w": 48, "align": "r", "fmt": "str", "muted": true, "sep_before": true, "group": "game_result.group.box_total"},
	{"key": "hr",   "title": "HR",             "w": 30, "align": "r", "fmt": "int", "muted": true, "group": "game_result.group.box_total"},
]

# 投手成績の列 (両チーム1表)。勝敗マークは表の上に重ね描きする。
const PITCH_COLUMNS: Array = [
	{"key": "team",    "title": "box.col.team",     "w": 64,  "align": "l", "fmt": "team", "group": "game_result.group.team_decision"},
	{"key": "mark",    "title": "",                 "w": 28,  "align": "c", "fmt": "str", "group": "game_result.group.team_decision"},
	{"key": "name",    "title": "common.pitcher",   "w": 150, "align": "l", "fmt": "player_name", "strong": true, "sep_before": true, "group": "game_result.group.pitcher_profile"},
	{"key": "throws",  "title": "col.throws_short", "w": 30,  "align": "c", "fmt": "str", "muted": true, "group": "game_result.group.pitcher_profile"},
	{"key": "w",       "title": "col.wins",         "w": 40,  "align": "r", "fmt": "int", "sep_before": true, "group": "game_result.group.season_total"},
	{"key": "l",       "title": "col.losses",       "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.season_total"},
	{"key": "s",       "title": "S",                "w": 36,  "align": "r", "fmt": "int", "group": "game_result.group.season_total"},
	{"key": "g",       "title": "col.games_short",  "w": 44,  "align": "r", "fmt": "int", "group": "game_result.group.season_total"},
	{"key": "ip",      "title": "box.col.ip",       "w": 56,  "align": "r", "fmt": "str", "strong": true, "sep_before": true, "group": "game_result.group.today_pitching"},
	{"key": "bf",      "title": "box.col.bf",       "w": 48,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "pitches", "title": "box.col.pitches",  "w": 52,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "h",       "title": "box.col.h",        "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "k",       "title": "box.col.k",        "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "bb",      "title": "box.col.bb",       "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "hbp",     "title": "box.col.hbp",      "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "r",       "title": "col.runs_allowed", "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "er",      "title": "box.col.er",       "w": 40,  "align": "r", "fmt": "int", "group": "game_result.group.today_pitching"},
	{"key": "era",     "title": "stat.era",         "w": 60,  "align": "r", "fmt": "f2", "strong": true, "sep_before": true, "group": "stat.era"},
]

const LIST_ROW_H: float = 40.0
const PITCH_ROW_H: float = 25.0
const TABLE_INNER_PAD: float = 12.0
# 表の見出し帯 (2段) の下端から 1 行目までの距離は _draw_data_table が持つ: header_top 68 + 8 + 6。
const TABLE_ROWS_OFFSET: float = 82.0

var _view_team_id: int = 0
var _team_games: Array = []          # [{index, game, day}]
# ポストシーズン: 閲覧チームが関与した試合 [{stage_key, game_num, game(正規化), result}]。
# 月タブの末尾に「ポストシーズン」タブとして並べ、選択時はこちらから一覧/詳細を引く。
var _ps_games_for_view: Array = []
var _months: Array = []              # [{year, month, label}]
var _sel_month: int = 0
var _selected_index: int = -1
var _list_scroll: int = 0
var _pitch_scroll: int = 0
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
			var mpos: Vector2 = _to_base(event.position)
			if PITCH_RECT.has_point(mpos):
				_scroll_pitch(1)
			else:
				_scroll_list(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var mpos: Vector2 = _to_base(event.position)
			if PITCH_RECT.has_point(mpos):
				_scroll_pitch(-1)
			else:
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
	var visible_count: int = _list_visible_rows()
	var max_scroll: int = max(0, games.size() - visible_count)
	var next: int = clampi(_list_scroll + delta, 0, max_scroll)
	if next != _list_scroll:
		_list_scroll = next
		queue_redraw()


func _scroll_pitch(delta: int) -> void:
	var rows: Array = _pitching.get("rows", []) as Array
	var visible_rows: int = _pitch_visible_rows()
	var max_scroll: int = max(0, rows.size() - visible_rows)
	var next: int = clampi(_pitch_scroll + delta, 0, max_scroll)
	if next != _pitch_scroll:
		_pitch_scroll = next
		queue_redraw()


func _list_visible_rows() -> int:
	return maxi(1, int(floor((_list_rect().size.y - TABLE_ROWS_OFFSET - 8.0) / LIST_ROW_H)))


# 投手成績表に収まる行数 (行の開始位置は _draw_data_table の 1 行目と同じ式)。
func _pitch_visible_rows() -> int:
	return maxi(1, int(floor((PITCH_RECT.size.y - TABLE_ROWS_OFFSET - 12.0) / PITCH_ROW_H)))


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

	_draw_shell(Loc.t("screen.game_results"), team, season)
	_draw_game_list(season)

	if _selected_index < 0 or _cur_game.is_empty():
		_round(Rect2(RIGHT_X, TOP_Y, INNER_R - RIGHT_X, 956), PANEL, BORDER, 10)
		_text(Loc.t("game_result.select_game"), Vector2(RIGHT_X + 40, TOP_Y + 80), 18, MUTED)
		return

	_draw_line_score(SCORE_RECT)
	_draw_summary(SUMMARY_RECT)
	_draw_box_score(BOX_RECT)
	_draw_subs(SUB_RECT)
	_draw_pitching(PITCH_RECT)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text(Loc.t("flow.error.season_not_started"), Vector2(770, 496), 20, MUTED)


# --- 左カラム: 月別タブ + 試合一覧 ---

func _draw_game_list(_season: PSSeason) -> void:
	# 月タブはボタン (_build_buttons) で描く。ここでは一覧パネルを共通テーブルで描く。
	# 見えている行だけを渡し (スクロールは _list_scroll)、当たり判定は表が積む hits を _list_row_hits へ移す。
	var rect: Rect2 = _list_rect()
	var games: Array = _month_games()
	var opts: Dictionary = {
		"inner_pad": TABLE_INNER_PAD, "row_h": LIST_ROW_H, "cell_size": 13, "bottom_pad": 8.0,
		"empty_text": Loc.t("game_result.no_games"),
	}
	if _months.is_empty():
		_draw_data_table(rect, LIST_COLUMNS, [], opts)
		return
	var month: Dictionary = _months[_sel_month] as Dictionary
	opts["title"] = Loc.t("game_result.month_header", {"year": int(month["year"]), "month": str(month["label"])})
	opts["title_size"] = 15
	opts["right_label"] = Loc.t("common.games_value", {"n": games.size()})
	opts["empty_text"] = Loc.t("game_result.no_games_in_month")

	var visible_count: int = _list_visible_rows()
	var rows: Array = []
	for i in range(visible_count):
		var gi: int = _list_scroll + i
		if gi >= games.size():
			break
		var entry: Dictionary = games[gi] as Dictionary
		rows.append(_list_row(int(entry["index"]), entry["game"] as Dictionary))
	# __meta は index + 1 (0 は「未選択」と区別できないため)。
	opts["sel_kind"] = "game"
	opts["selected_id"] = _selected_index + 1
	opts["hover_id"] = _hover_index + 1 if _hover_index >= 0 else 0
	var hits: Array = []
	opts["hits"] = hits
	_draw_data_table(rect, LIST_COLUMNS, rows, opts)
	for hit_value in hits:
		var hit: Dictionary = hit_value as Dictionary
		_list_row_hits.append({"rect": hit["rect"], "index": int(hit["meta"]) - 1})

	# 勝敗マークは列の上に図形で重ね描きする。
	var mark_rect: Rect2 = _table_column_rect(rect, LIST_COLUMNS, opts, "mark")
	var row_top: float = _table_row_top(rect, LIST_COLUMNS, opts)
	for i in range(rows.size()):
		var game: Dictionary = (games[_list_scroll + i] as Dictionary)["game"] as Dictionary
		_draw_result_mark(Vector2(mark_rect.position.x + mark_rect.size.x * 0.5, row_top + (float(i) + 0.5) * LIST_ROW_H),
			6.0, _result_symbol(game), _game_color(game))

	# スクロールインジケータ
	if games.size() > visible_count:
		_text_right("%d–%d / %d" % [_list_scroll + 1, min(_list_scroll + visible_count, games.size()), games.size()],
			rect.end.x - 16, rect.end.y - 14, 11, FAINT, 120)


# 月間試合リストの 1 行 (日付 / 対戦相手 / スコア)。勝敗マーク列は空にして図形を重ねる。
func _list_row(index: int, game: Dictionary) -> Dictionary:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var is_home: bool = home_id == _view_team_id
	var opp_id: int = away_id if is_home else home_id
	var matchup_label: String = "%s %s" % ["vs" if is_home else "@", _team_short(opp_id)]
	if game.has("ps_label"):
		matchup_label = "%s  %s" % [str(game.get("ps_label", "")), matchup_label]
	# スコアは自軍 - 相手。
	var us: int = int(game.get("home_score", 0)) if is_home else int(game.get("away_score", 0))
	var them: int = int(game.get("away_score", 0)) if is_home else int(game.get("home_score", 0))
	return {
		"__meta": index + 1,
		"date": SeasonCalendar.compact_label_for_game(game, AppState.current_season),
		"opp": matchup_label,
		"mark": "",
		"score": "%d - %d" % [us, them],
	}


# --- 上段: イニングスコア ---

func _draw_line_score(rect: Rect2) -> void:
	_panel(rect, Loc.t("game_result.line_score"))
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

	# 2段ヘッダ: 上段 SUPER_HEADER_BG (球団 | イニング | 計)、下段 PANEL_2 (イニング番号 + R/H/E)。
	var band_x: float = rect.position.x + 16.0
	var band_w: float = rect.size.x - 32.0
	var tx: float = grid_x + grid_w
	var tier1_top: float = hy - 36.0
	_round(Rect2(band_x, tier1_top, band_w, 18.0), SUPER_HEADER_BG, Color.TRANSPARENT, 0, 0)
	_round(Rect2(band_x, hy - 18.0, band_w, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_line(Vector2(band_x, hy - 18.0), Vector2(band_x + band_w, hy - 18.0), HAIRLINE, 1.0)
	_text(Loc.t("col.team"), Vector2(band_x, tier1_top + 13.0), 10, MUTED, grid_x - band_x, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(Loc.t("game_result.group.innings"), Vector2(grid_x, tier1_top + 13.0), 10, MUTED, grid_w, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(Loc.t("box.total"), Vector2(tx, tier1_top + 13.0), 10, MUTED, totals_w, HORIZONTAL_ALIGNMENT_CENTER, true)
	_line(Vector2(grid_x, tier1_top + 2.0), Vector2(grid_x, hy - 20.0), HAIRLINE, 1.0)
	_line(Vector2(tx, tier1_top + 2.0), Vector2(tx, hy - 20.0), HAIRLINE, 1.0)
	for i in range(inning_count):
		_text(str(i + 1), Vector2(grid_x + float(i) * cell_w, hy), 12, MUTED, cell_w, HORIZONTAL_ALIGNMENT_CENTER, true)
	var tcol_w: float = totals_w / 3.0
	_line(Vector2(tx, hy - 18.0), Vector2(tx, r2 + 20.0), HAIRLINE, 1.0)
	_line(Vector2(grid_x, hy - 18.0), Vector2(grid_x, r2 + 20.0), HAIRLINE, 1.0)
	for j in range(3):
		_text(["R", "H", "E"][j], Vector2(tx + float(j) * tcol_w, hy), 12, TEXT if j == 0 else MUTED, tcol_w, HORIZONTAL_ALIGNMENT_CENTER, true)
	_line(Vector2(rect.position.x + 16, hy + 8), Vector2(rect.end.x - 16, hy + 8), BORDER, 1.5)

	_draw_line_row(rect, away_id, false, innings, inning_count, grid_x, cell_w, tx, tcol_w, r1)
	_line(Vector2(rect.position.x + 16, r1 + 18.0), Vector2(rect.end.x - 16, r1 + 18.0), HAIRLINE, 1.0)
	_draw_line_row(rect, home_id, true, innings, inning_count, grid_x, cell_w, tx, tcol_w, r2)


func _draw_line_row(rect: Rect2, team_id: int, is_home: bool, innings: Array, inning_count: int, grid_x: float, cell_w: float, tx: float, tcol_w: float, y: float) -> void:
	var team: PSTeam = GameDb.get_team(team_id)
	if team != null:
		_team_badge(Rect2(rect.position.x + 16, y - 18, 24, 24), team)
		# スコアボードらしくバッジの右にチーム名も添える (bold)。
		_text(team.short_name, Vector2(rect.position.x + 44, y - 2), 12, TEXT, grid_x - (rect.position.x + 44) - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
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
	_text(str(runs), Vector2(tx, y), 15, TEXT, tcol_w, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(str(hits), Vector2(tx + tcol_w, y), 13, TEXT, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text(str(errs), Vector2(tx + tcol_w * 2.0, y), 13, TEXT if errs > 0 else MUTED, tcol_w, HORIZONTAL_ALIGNMENT_CENTER)


func _line_score_innings(game: Dictionary, game_log: Dictionary = {}) -> Array:
	var innings: Array = _array_value(game.get("innings", []))
	if not innings.is_empty():
		return innings
	var result: Dictionary = game.get("result", {}) as Dictionary
	innings = _array_value(result.get("innings", []))
	if not innings.is_empty():
		return innings
	return _array_value(game_log.get("innings", []))


func _array_value(value: Variant) -> Array:
	if value is Array:
		return value as Array
	return []


# --- 上段: サマリー (勝敗投手 + 記録) ---

func _draw_summary(rect: Rect2) -> void:
	_panel(rect, Loc.t("game_result.summary"))
	var result: Dictionary = _cur_game.get("result", {}) as Dictionary
	var ox: float = rect.position.x + 18.0
	var y: float = rect.position.y + 70.0

	if bool(result.get("draw", false)):
		_text(Loc.t("game_result.draw"), Vector2(ox, y), 16, AMBER)
	else:
		var win_id: int = int(result.get("winning_pitcher_id", 0))
		var loss_id: int = int(result.get("losing_pitcher_id", 0))
		var save_id: int = int(result.get("save_pitcher_id", 0))
		var holds: Array = result.get("hold_pitcher_ids", []) as Array
		# 勝/敗/S を横並びチップ風に
		_text(Loc.t("col.wins"), Vector2(ox, y), 13, GREEN, 22)
		_text(_pitcher_label(win_id), Vector2(ox + 26, y), 14, TEXT, 240)
		_text(Loc.t("col.losses"), Vector2(ox + 320, y), 13, RED, 22)
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
			_text(Loc.t("common.list_separator").join(PackedStringArray(labels)), Vector2(ox + 346, y), 13, MUTED, 280)
		y += 30

	_line(Vector2(ox, y - 6), Vector2(rect.end.x - 18, y - 6), BORDER_SOFT, 1.0)

	var hr: Array = _records.get("hr", []) as Array
	var errors: Array = _records.get("errors", []) as Array
	var record_separator: String = Loc.t("game_result.record_separator")
	_text(Loc.t("game_result.home_runs"), Vector2(ox, y + 18), 12, MUTED, 70)
	_text(record_separator.join(PackedStringArray(hr)) if not hr.is_empty() else Loc.t("common.none"), Vector2(ox + 76, y + 18), 12, TEXT, rect.size.x - 110)
	_text(Loc.t("game_result.errors"), Vector2(ox, y + 44), 12, MUTED, 70)
	_text(record_separator.join(PackedStringArray(errors)) if not errors.is_empty() else Loc.t("common.none"), Vector2(ox + 76, y + 44), 12, TEXT, rect.size.x - 110)


# --- 中段: 打席結果 (ボックススコア) ---

func _draw_box_score(rect: Rect2) -> void:
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	# ビジター/ホーム切替チップは _build_buttons で配置。

	var rows: Array = _box_data.get("rows", []) as Array
	var totals: Dictionary = _box_data.get("totals", {}) as Dictionary
	var inning_count: int = max(9, int(_box_data.get("inning_count", 9)))
	# 列構成 (打者一巡で同一イニングに複数列)。古いデータ等で無ければイニング単列にフォールバック。
	var inn_columns: Array = _box_data.get("columns", []) as Array
	if inn_columns.is_empty():
		for inn in range(1, inning_count + 1):
			inn_columns.append({"inning": inn, "round": 0})
	var col_count: int = inn_columns.size()
	var expanded: bool = col_count > inning_count  # 打者一巡で列が増えている
	var inn_font_size: int = 11 if col_count <= 9 else (10 if col_count <= 12 else 9)

	# 固定列 + イニング列。イニング列は残り幅を等分し、表の倍率が 1.0 になるようにする。
	var columns: Array = BOX_PRE_COLUMNS.duplicate(true)
	var fixed_w: float = 0.0
	for c_value in columns:
		fixed_w += float((c_value as Dictionary)["w"])
	var inn_w: float = (rect.size.x - TABLE_INNER_PAD * 2.0 - fixed_w) / float(col_count)
	for ci in range(col_count):
		columns.append({"key": "i%d" % ci, "title": "", "w": inn_w, "align": "c", "fmt": "str",
			"group": "game_result.group.box_innings", "sep_before": ci == 0})

	# 行高は行数 (選手 + 計) に合わせてフィット。
	var line_count: int = rows.size() + (1 if not totals.is_empty() else 0)
	var area_h: float = rect.size.y - TABLE_ROWS_OFFSET - 8.0
	# 表は int(area / row_h) 行までしか描かないので、浮動小数の丸めで最終行が落ちない程度に縮める。
	var row_h: float = clampf(area_h / float(maxi(1, line_count)) - 0.01, 16.0, 26.0)
	var table_rows: Array = []
	for row_value in rows:
		table_rows.append(_box_table_row(row_value as Dictionary))
	if not totals.is_empty():
		table_rows.append({
			"is_total": true,
			"pos": Loc.t("box.total"),
			"name": Loc.t("box.double_plays", {"n": int(totals.get("gidp", 0))}),
			"ab": int(totals.get("ab", 0)),
			"h": int(totals.get("h", 0)),
			"rbi": int(totals.get("rbi", 0)),
			"avg": _fmt_avg(float(totals.get("avg", 0.0))),
			"hr": int(totals.get("hr", 0)),
		})
	var opts: Dictionary = {
		"title": Loc.t("game_result.box_score", {"side": Loc.t("home.side_home") if _box_home else Loc.t("home.side_visitor")}),
		"title_size": 16, "panel": false, "inner_pad": TABLE_INNER_PAD, "row_h": row_h, "cell_size": 12, "bottom_pad": 8.0,
	}
	_draw_data_table(rect, columns, table_rows, opts)

	# 守備位置バッジとイニング別の打席結果は、表と同じ幾何で上から重ね描きする。
	var row_top: float = _table_row_top(rect, columns, opts)
	var header_y: float = rect.position.y + _effective_header_top(columns, opts)
	var pos_rect: Rect2 = _table_column_rect(rect, columns, opts, "pos")
	var grid_rect: Rect2 = _table_column_rect(rect, columns, opts, "i0")
	var grid_x: float = grid_rect.position.x
	inn_w = grid_rect.size.x
	var grid_bottom: float = row_top + row_h * float(table_rows.size())

	# イニングヘッダ: 同一イニングの列をまとめ、番号をグループ中央に置く。
	var gi: int = 0
	while gi < col_count:
		var inn: int = int((inn_columns[gi] as Dictionary)["inning"])
		var span: int = 1
		while gi + span < col_count and int((inn_columns[gi + span] as Dictionary)["inning"]) == inn:
			span += 1
		_text(str(inn), Vector2(grid_x + float(gi) * inn_w, header_y), 12, MUTED, inn_w * float(span), HORIZONTAL_ALIGNMENT_CENTER, true)
		# 列が増えているイニングがあるときだけ、グループ境界に薄い区切り線を引いて見やすくする。
		if expanded and gi > 0:
			_line(Vector2(grid_x + float(gi) * inn_w, header_y - 18.0), Vector2(grid_x + float(gi) * inn_w, grid_bottom), HAIRLINE, 1.0)
		gi += span

	for ri in range(rows.size()):
		_draw_box_overlay(rows[ri] as Dictionary, pos_rect, grid_x, inn_w, col_count, row_top + float(ri) * row_h, row_h, inn_font_size)


# 打席結果表 1 行分の表データ。守備位置とイニングセルは重ね描きなので空にする。
# 背番号は行に player_id があるときだけ引ける (無ければ #背番号は出さない)。
func _box_table_row(row: Dictionary) -> Dictionary:
	var bats: String = str(row.get("bats", ""))
	var out: Dictionary = {
		"pos": "",
		"name": str(row.get("name", "")),
		"bats": "(%s)" % bats if not bats.is_empty() else "",
		"ab": int(row.get("ab", 0)),
		"h": int(row.get("h", 0)),
		"rbi": int(row.get("rbi", 0)),
		"avg": _fmt_avg(float(row.get("avg", 0.0))),
		"hr": int(row.get("hr", 0)),
	}
	var pid: int = int(row.get("player_id", 0))
	var player: PSPlayer = GameDb.get_player(pid) if pid > 0 else null
	if player != null and player.jersey_number > 0:
		out["jersey"] = player.jersey_number
	return out


# 守備位置ラベル ("(中)" = スタメン / "中" = 途中出場 / 打・走 = 代打・代走) から、バッジの文字・色・塗りを決める。
# スタメンは塗り、途中出場は枠のみ。色は守備位置の役割色 (_pos_color)、位置に紐づかない代打/代走は MUTED。
func _box_pos_style(label: String) -> Dictionary:
	var is_start: bool = label.begins_with("(")
	var text: String = label.replace("(", "").replace(")", "")
	var color: Color = MUTED
	for pos in range(1, 11):
		if BoxScoreBuilder.position_char(pos) == text:
			color = _pos_color(pos)
			break
	return {"text": text, "color": color, "filled": is_start}


func _draw_box_overlay(row: Dictionary, pos_rect: Rect2, grid_x: float, inn_w: float, col_count: int, ry: float, row_h: float, inn_font_size: int) -> void:
	var ty: float = ry + row_h * 0.5 + 4.0
	var pos_label: String = str(row.get("pos", ""))
	if not pos_label.is_empty():
		var style: Dictionary = _box_pos_style(pos_label)
		var bw: float = minf(pos_rect.size.x - 6.0, 34.0)
		var bh: float = minf(18.0, row_h - 3.0)
		_chip(Rect2(pos_rect.position.x + (pos_rect.size.x - bw) * 0.5, ry + (row_h - bh) * 0.5, bw, bh),
			str(style["text"]), style["color"] as Color, bool(style["filled"]))
	var hr_mark: String = Loc.t("box.pa.home_run", {"dir": ""})
	var on_base: Array = [Loc.t("box.pa.walk"), Loc.t("box.pa.intentional_walk"), Loc.t("box.pa.hit_by_pitch")]
	var cells: Array = row.get("cells", []) as Array
	for i in range(mini(col_count, cells.size())):
		var cell: Dictionary = cells[i] as Dictionary
		var text: String = str(cell.get("text", ""))
		if text.is_empty():
			continue
		var cell_x: float = grid_x + float(i) * inn_w
		var pill: Rect2 = Rect2(cell_x + 1.0, ry + 2.0, inn_w - 2.0, row_h - 4.0)
		if bool(cell.get("is_hit", false)):
			# 安打は緑ピル、本塁打はアンバーのピル。
			var hit_color: Color = AMBER if text.find(hr_mark) >= 0 else GREEN
			_round(pill, Color(hit_color.r, hit_color.g, hit_color.b, 0.18), Color(hit_color.r, hit_color.g, hit_color.b, 0.55), 4)
			_text(text, Vector2(cell_x, ty), inn_font_size, hit_color, inn_w, HORIZONTAL_ALIGNMENT_CENTER, true)
		else:
			# 凡退は MUTED。四球・死球など出塁は通常文字色。
			_text(text, Vector2(cell_x, ty), inn_font_size, TEXT if on_base.has(text) else MUTED, inn_w, HORIZONTAL_ALIGNMENT_CENTER)


# --- 中段: 交代 ---

func _draw_subs(rect: Rect2) -> void:
	_panel(rect, Loc.t("game_result.substitutions"))
	var ox: float = rect.position.x + 16.0
	var hy: float = rect.position.y + 60.0
	var cols: Array = [
		{"label": Loc.t("game_result.sub_col.inning"), "x": ox, "w": 52.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": Loc.t("game_result.sub_col.kind"), "x": ox + 56.0, "w": 74.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "OUT", "x": ox + 134.0, "w": 130.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": "→ IN", "x": ox + 270.0, "w": 150.0, "align": HORIZONTAL_ALIGNMENT_LEFT},
		{"label": Loc.t("box.col.pos"), "x": rect.end.x - 50.0, "w": 34.0, "align": HORIZONTAL_ALIGNMENT_CENTER},
	]
	for c_value in cols:
		var c: Dictionary = c_value as Dictionary
		_text(str(c["label"]), Vector2(float(c["x"]), hy), 11, FAINT, float(c["w"]), c["align"] as int)
	_line(Vector2(ox, hy + 8), Vector2(rect.end.x - 16, hy + 8), BORDER_SOFT, 1.0)

	if _subs.is_empty():
		_text(Loc.t("game_result.no_substitutions"), Vector2(ox, hy + 40), 13, MUTED)
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
		_text(Loc.t(str(SUB_KIND_LABELS.get(str(entry.get("kind", "")), ""))), Vector2(ox + 56.0, ty), 12, TEXT, 74)
		_text(_player_name(int(entry.get("out_id", 0))), Vector2(ox + 134.0, ty), 12, MUTED, 130)
		_text("→ %s" % _player_name(int(entry.get("in_id", 0))), Vector2(ox + 270.0, ty), 12, TEXT, 150)
		_text(BoxScoreBuilder.position_char(pos) if pos > 0 else "", Vector2(rect.end.x - 50.0, ty), 12, MUTED, 34, HORIZONTAL_ALIGNMENT_CENTER)


# --- 下段: 投手成績 ---

func _draw_pitching(rect: Rect2) -> void:
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	var rows: Array = _pitching.get("rows", []) as Array
	var visible_rows: int = _pitch_visible_rows()
	var start_idx: int = 0
	if rows.size() > visible_rows:
		_pitch_scroll = clampi(_pitch_scroll, 0, rows.size() - visible_rows)
		start_idx = _pitch_scroll
	else:
		_pitch_scroll = 0
	var table_rows: Array = []
	for i in range(mini(visible_rows, rows.size() - start_idx)):
		table_rows.append(_pitch_table_row(rows[start_idx + i] as Dictionary))
	var opts: Dictionary = {
		"title": Loc.t("game_result.pitching"), "title_size": 16, "panel": false, "inner_pad": 18.0,
		"row_h": PITCH_ROW_H, "cell_size": 12, "bottom_pad": 12.0,
		"empty_text": Loc.t("game_result.no_pitching"),
	}
	_draw_data_table(rect, PITCH_COLUMNS, table_rows, opts)
	if table_rows.is_empty():
		return

	# 勝敗マーク (勝利投手=白丸 / 敗戦投手=黒丸+白縁) は列の上に図形で重ね、球団が替わる行の上に区切り線を引く。
	var mark_rect: Rect2 = _table_column_rect(rect, PITCH_COLUMNS, opts, "mark")
	var row_top: float = _table_row_top(rect, PITCH_COLUMNS, opts)
	var prev_team: int = -999
	for i in range(table_rows.size()):
		var row: Dictionary = rows[start_idx + i] as Dictionary
		var ry: float = row_top + float(i) * PITCH_ROW_H
		var tid: int = int(row.get("team_id", 0))
		if tid != prev_team and start_idx + i > 0:
			_line(Vector2(rect.position.x + 18.0, ry), Vector2(rect.end.x - 18.0, ry), BORDER_SOFT, 1.0)
		prev_team = tid
		var mark_id: String = str(row.get("mark", ""))
		if mark_id == BoxScoreBuilder.MARK_WIN or mark_id == BoxScoreBuilder.MARK_LOSS:
			_draw_result_mark(Vector2(mark_rect.position.x + mark_rect.size.x * 0.5, ry + PITCH_ROW_H * 0.5),
				5.0, "○" if mark_id == BoxScoreBuilder.MARK_WIN else "●", TEXT)

	# スクロールバー
	if rows.size() > visible_rows:
		var avail: float = float(visible_rows) * PITCH_ROW_H
		var max_scroll: int = rows.size() - visible_rows
		_round(Rect2(rect.end.x - 12.0, row_top, 4.0, avail), PANEL_3, BORDER_SOFT, 2)
		var thumb_h: float = maxf(20.0, avail * (float(visible_rows) / float(rows.size())))
		var thumb_y: float = row_top + (avail - thumb_h) * (float(_pitch_scroll) / float(max_scroll))
		_round(Rect2(rect.end.x - 12.0, thumb_y, 4.0, thumb_h), MUTED, Color.TRANSPARENT, 2)


# 投手成績表 1 行分の表データ。勝敗マークの図形は重ね描きなので、その列は救援のセーブ/ホールド文字だけ入れる。
func _pitch_table_row(row: Dictionary) -> Dictionary:
	var tid: int = int(row.get("team_id", 0))
	var team: PSTeam = GameDb.get_team(tid)
	var out: Dictionary = row.duplicate()
	out["team"] = _team_short(tid)
	out["team_color"] = team.color if team != null else MUTED
	out["mark"] = ""
	var mark_id: String = str(row.get("mark", ""))
	if mark_id == BoxScoreBuilder.MARK_SAVE:
		out["mark"] = Loc.t("box.mark.save")
		out["mark_color"] = AMBER
	elif mark_id == BoxScoreBuilder.MARK_HOLD:
		out["mark"] = Loc.t("box.mark.hold")
		out["mark_color"] = BLUE
	var throws: String = str(row.get("throws", ""))
	out["throws"] = "(%s)" % throws if not throws.is_empty() else ""
	var pid: int = int(row.get("pitcher_id", 0))
	var pitcher: PSPlayer = GameDb.get_player(pid) if pid > 0 else null
	if pitcher != null and pitcher.jersey_number > 0:
		out["jersey"] = pitcher.jersey_number
	return out


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("home_empty", Loc.t("common.to_home"), Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# ヘッダ右: 表示チーム切替
	var view_team: PSTeam = GameDb.get_team(_view_team_id)
	var team_label: String = Loc.t("game_result.view_team", {"team": view_team.short_name if view_team != null else "-"})
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


# ============================================================ data / selection

func _reload_for_team() -> void:
	_team_games = _collect_team_games(_view_team_id)
	_months = _build_months(_team_games)
	_ps_games_for_view = _collect_ps_games(_view_team_id)
	if not _ps_games_for_view.is_empty():
		var season: PSSeason = AppState.current_season
		_months.append({"year": season.year if season != null else 0, "key": "postseason", "label": Loc.t("postseason.title")})
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
		"day": int(game.get("season_day", game.get("day", 1))),
		"date": str(game.get("date", "")),
		"away_team_id": int(game.get("away_id", 0)),
		"home_team_id": int(game.get("home_id", 0)),
		"away_score": int(game.get("away_score", 0)),
		"home_score": int(game.get("home_score", 0)),
		"innings": result.get("innings", []) as Array,
		"result": result,
		"played": true,
		"ps_label": Loc.t("game_result.ps_game_label", {"stage": _ps_stage_short(stage_key), "n": int(game.get("game_num", 0))}),
	}
	return {
		"stage_key": stage_key,
		"game_num": int(game.get("game_num", 0)),
		"game": normalized,
		"result": result,
	}


func _ps_stage_short(stage_key: String) -> String:
	match stage_key:
		"cs1_league1": return Loc.t("game_result.ps_stage.cs1_league1")
		"cs1_league2": return Loc.t("game_result.ps_stage.cs1_league2")
		"cs2_league1": return Loc.t("game_result.ps_stage.cs2_league1")
		"cs2_league2": return Loc.t("game_result.ps_stage.cs2_league2")
		"japan_series": return Loc.t("game_result.ps_stage.japan_series")
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
		return {"year": year, "key": "%d-0304" % year, "label": Loc.t("date.march_april")}
	return {"year": year, "key": "%d-%02d" % [year, month], "label": Loc.t("date.month", {"month": month})}


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
	var visible_count: int = _list_visible_rows()
	_list_scroll = max(0, games.size() - visible_count)
	_select_game(int((games[games.size() - 1] as Dictionary)["index"]))


func _select_game(index: int) -> void:
	_pitch_scroll = 0
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
	_pitch_scroll = 0
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


# メモリ上の完全結果を優先し、無ければ未保存の compact log → 年別ログファイルの順に読む。
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
	return GameLogService.read_available_game_log(season, schedule_index)


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
	return Loc.t("game_result.inning_top" if half == "top" else "game_result.inning_bottom", {"n": inning})


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
		return Loc.t("common.unknown")
	var season: PSSeason = AppState.current_season
	if season == null:
		return Loc.t("common.unknown")
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pitcher_id, season.year, season.season_number)
	if record == null:
		return Loc.t("common.unknown")
	return "%s (%d-%d)" % [record.name, record.pitcher_stats.wins, record.pitcher_stats.losses]


func _fmt_avg(value: float) -> String:
	var s: String = "%0.3f" % value
	if s.begins_with("0"):
		s = s.substr(1)
	return s
