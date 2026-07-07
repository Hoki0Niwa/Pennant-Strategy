extends "res://ui/components/dashboard_screen.gd"

# シーズン履歴画面。3ビューを右上チップで切り替える (R7 記録・履歴基盤)。
# - 年度別: season_archives から過去年度を選び、最終順位・ポストシーズン・表彰を復元表示。
# - 歴代記録: 全選手の通算リーダーとシーズン最高記録 (RecordStore の全年度レコードを集計、
#   カウント系部門のみ。率系は規定の扱いが年度横断で曖昧なため対象外)。
# - タイトル履歴: 部門を選んで年度×両リーグの歴代受賞者を一覧。
# 重い集計は _refresh / _build_alltime で1度だけ行いキャッシュし、_draw は描画専念。

const STAGE_LABELS: Dictionary = {
	"cs1_central": "CS1 第1", "cs1_pacific": "CS1 第2",
	"cs2_central": "CS2 第1", "cs2_pacific": "CS2 第2",
	"japan_series": "日本シリーズ",
}
const BATTING_TITLE_LABELS: Dictionary = {
	"average": "首位打者", "home_runs": "本塁打王", "rbi": "打点王",
	"stolen_bases": "盗塁王", "hits": "最多安打",
}
const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "最多勝利", "era": "最優秀防御率", "strikeouts": "最多奪三振",
	"saves": "最多セーブ", "holds": "最多ホールド", "win_rate": "最高勝率",
}

const LEAGUES: Array = [
	{"key": "central", "label": "第1リーグ 最終順位"},
	{"key": "pacific", "label": "第2リーグ 最終順位"},
]

# --- レイアウト基準 (base 座標) ---
const NAV_PREV: Rect2 = Rect2(262, 98, 38, 30)
const NAV_NEXT: Rect2 = Rect2(560, 98, 38, 30)
const YEAR_LABEL_X: float = 306.0
const YEAR_LABEL_W: float = 248.0

const TABLE_A: Rect2 = Rect2(262, 144, 808, 280)
const TABLE_B: Rect2 = Rect2(1092, 144, 808, 280)
const POST_RECT: Rect2 = Rect2(262, 440, 808, 618)
const AWARD_RECT: Rect2 = Rect2(1092, 440, 808, 196)
const BAT_RECT: Rect2 = Rect2(1092, 652, 396, 406)
const PIT_RECT: Rect2 = Rect2(1504, 652, 396, 406)

# ポストシーズンのステージ並び: 同ステージを横並び (左=第1リーグ central / 右=第2リーグ pacific)。
# 日本シリーズは両リーグ代表の対戦なので全幅の統合カードで描く。
const POST_GROUPS: Array = [
	{"lines": ["CS", "ファースト"], "central": "cs1_central", "pacific": "cs1_pacific", "split": true},
	{"lines": ["CS", "ファイナル"], "central": "cs2_central", "pacific": "cs2_pacific", "split": true},
	{"lines": ["日本シリーズ"], "japan": "japan_series", "split": false},
]

const HIST_COLUMNS: Array = [
	{"title": "順",   "key": "rank", "w": 40,  "align": "l", "fmt": "rank"},
	{"title": "球団", "key": "team", "w": 180, "align": "l", "fmt": "team"},
	{"title": "試",   "key": "g",    "w": 58,  "align": "r", "fmt": "int"},
	{"title": "勝",   "key": "w",    "w": 56,  "align": "r", "fmt": "int"},
	{"title": "敗",   "key": "l",    "w": 56,  "align": "r", "fmt": "int"},
	{"title": "分",   "key": "d",    "w": 50,  "align": "r", "fmt": "int"},
	{"title": "勝率", "key": "pct",  "w": 78,  "align": "r", "fmt": "rate"},
	{"title": "差",   "key": "gb",   "w": 66,  "align": "r", "fmt": "gb"},
	{"title": "得",   "key": "rs",   "w": 62,  "align": "r", "fmt": "int"},
	{"title": "失",   "key": "ra",   "w": 62,  "align": "r", "fmt": "int"},
	{"title": "得失", "key": "diff", "w": 70,  "align": "r", "fmt": "diff"},
]

# --- 歴代記録 / タイトル履歴 ビュー ---
const VIEW_YEAR: String = "year"
const VIEW_ALLTIME: String = "alltime"
const VIEW_TITLES: String = "titles"
const VIEW_CHIPS: Array = [
	{"key": VIEW_YEAR, "label": "年度別"},
	{"key": VIEW_ALLTIME, "label": "歴代記録"},
	{"key": VIEW_TITLES, "label": "タイトル履歴"},
]

const ALLTIME_TOP_N: int = 12
const ALLTIME_BAT_CATEGORIES: Array = [
	{"key": "hits", "label": "安打"},
	{"key": "home_runs", "label": "本塁打"},
	{"key": "runs_batted_in", "label": "打点"},
	{"key": "stolen_bases", "label": "盗塁"},
	{"key": "games", "label": "出場"},
]
const ALLTIME_PIT_CATEGORIES: Array = [
	{"key": "wins", "label": "勝利"},
	{"key": "saves", "label": "S"},
	{"key": "holds", "label": "H"},
	{"key": "strikeouts", "label": "奪三振"},
	{"key": "games", "label": "登板"},
]
const TITLE_HISTORY_CATEGORIES: Array = [
	{"key": "mvp", "label": "MVP"},
	{"key": "rookie", "label": "新人王"},
	{"key": "bat_average", "label": "首位打者"},
	{"key": "bat_home_runs", "label": "本塁打王"},
	{"key": "bat_rbi", "label": "打点王"},
	{"key": "bat_stolen_bases", "label": "盗塁王"},
	{"key": "bat_hits", "label": "最多安打"},
	{"key": "pit_wins", "label": "最多勝利"},
	{"key": "pit_era", "label": "最優秀防御率"},
	{"key": "pit_strikeouts", "label": "最多奪三振"},
	{"key": "pit_saves", "label": "最多セーブ"},
	{"key": "pit_holds", "label": "最多ホールド"},
	{"key": "pit_win_rate", "label": "最高勝率"},
]

const CAREER_BAT_RECT: Rect2 = Rect2(262, 150, 808, 448)
const CAREER_PIT_RECT: Rect2 = Rect2(1092, 150, 808, 448)
const SEASON_BAT_RECT: Rect2 = Rect2(262, 610, 808, 448)
const SEASON_PIT_RECT: Rect2 = Rect2(1092, 610, 808, 448)
const TITLE_TABLE_RECT: Rect2 = Rect2(262, 190, 1240, 868)

const ALLTIME_COLUMNS: Array = [
	{"title": "順",   "key": "rank",   "w": 44,  "align": "l", "fmt": "rank"},
	{"title": "選手", "key": "player", "w": 220, "align": "l", "fmt": "str"},
	{"title": "在籍", "key": "span",   "w": 120, "align": "l", "fmt": "str"},
	{"title": "記録", "key": "value",  "w": 90,  "align": "r", "fmt": "int"},
]
const TITLE_COLUMNS: Array = [
	{"title": "年度",       "key": "year",    "w": 120, "align": "l", "fmt": "str"},
	{"title": "第1リーグ", "key": "central", "w": 320, "align": "l", "fmt": "str"},
	{"title": "第2リーグ", "key": "pacific", "w": 320, "align": "l", "fmt": "str"},
]

# 集計キャッシュ
var _archives: Array = []                   # 古い順 (RecordStore 由来)
var _sel: int = 0                           # 0 = 最新。表示対象 = _archives[size-1-_sel]
var _has_data: bool = false
var _year_label: String = ""
var _rows_by_league: Dictionary = {}        # {league_key: Array of 表示用 Dictionary}
var _post_champion_id: int = 0
var _post_by_stage: Dictionary = {}         # stage_key → シリーズ行 Dictionary (完了分のみ)
var _award_cards: Array = []                # MVP/新人王 カード Dictionary
var _bat_rows: Array = []                   # 打撃タイトル行 {label, central, pacific}
var _pit_rows: Array = []                   # 投手タイトル行

var _view: String = VIEW_YEAR
var _alltime_bat_key: String = "hits"
var _alltime_pit_key: String = "wins"
var _title_key: String = "mvp"
var _alltime_built: bool = false
var _career_bat_by_key: Dictionary = {}     # category key → 行 Array
var _career_pit_by_key: Dictionary = {}
var _season_bat_by_key: Dictionary = {}
var _season_pit_by_key: Dictionary = {}
var _title_rows: Array = []                 # タイトル履歴 (選択部門の年度別行、新しい順)


func _ready() -> void:
	_init_chrome()
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	_draw_shell("シーズン履歴", team, season)

	match _view:
		VIEW_ALLTIME:
			_draw_alltime_view()
			return
		VIEW_TITLES:
			_draw_titles_view()
			return

	if not _has_data:
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ完了したシーズンがありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text("シーズンを最後までプレイすると、ここに順位表・ポストシーズン・タイトルが記録されます。",
			Vector2(560, 548), 14, MUTED, 800, HORIZONTAL_ALIGNMENT_CENTER)
		return

	# 年度ラベル (◀/▶ ボタンの間に描画)
	_round(Rect2(YEAR_LABEL_X, 96, YEAR_LABEL_W, 34), PANEL_2, BORDER, 8)
	_text(_year_label, Vector2(YEAR_LABEL_X, 119), 17, TEXT, YEAR_LABEL_W, HORIZONTAL_ALIGNMENT_CENTER, true)

	_draw_table(TABLE_A, str(LEAGUES[0]["label"]), HIST_COLUMNS, _rows_by_league.get("central", []) as Array)
	_draw_table(TABLE_B, str(LEAGUES[1]["label"]), HIST_COLUMNS, _rows_by_league.get("pacific", []) as Array)
	_draw_postseason(POST_RECT)
	_draw_awards(AWARD_RECT)
	_draw_titles(BAT_RECT, "打撃タイトル", _bat_rows)
	_draw_titles(PIT_RECT, "投手タイトル", _pit_rows)


# ============================================================ 歴代記録 / タイトル履歴 ビュー

func _draw_alltime_view() -> void:
	_build_alltime()
	if (_career_bat_by_key.get(_alltime_bat_key, []) as Array).is_empty() \
			and (_career_pit_by_key.get(_alltime_pit_key, []) as Array).is_empty():
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ成績の記録がありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		return
	var bat_label: String = _category_label(ALLTIME_BAT_CATEGORIES, _alltime_bat_key)
	var pit_label: String = _category_label(ALLTIME_PIT_CATEGORIES, _alltime_pit_key)
	_draw_alltime_table(CAREER_BAT_RECT, "通算打撃リーダー: %s" % bat_label, _career_bat_by_key.get(_alltime_bat_key, []) as Array)
	_draw_alltime_table(CAREER_PIT_RECT, "通算投手リーダー: %s" % pit_label, _career_pit_by_key.get(_alltime_pit_key, []) as Array)
	_draw_alltime_table(SEASON_BAT_RECT, "シーズン打撃記録: %s" % bat_label, _season_bat_by_key.get(_alltime_bat_key, []) as Array)
	_draw_alltime_table(SEASON_PIT_RECT, "シーズン投手記録: %s" % pit_label, _season_pit_by_key.get(_alltime_pit_key, []) as Array)


func _draw_alltime_table(rect: Rect2, title: String, rows: Array) -> void:
	_draw_data_table(rect, ALLTIME_COLUMNS, rows, {
		"title": title, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
		"cell_size": 13, "empty_text": "記録がありません",
	})


func _draw_titles_view() -> void:
	var label: String = _category_label(TITLE_HISTORY_CATEGORIES, _title_key)
	if _title_rows.is_empty():
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ完了したシーズンがありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		return
	_draw_data_table(TITLE_TABLE_RECT, TITLE_COLUMNS, _title_rows, {
		"title": "タイトル履歴: %s" % label, "header_top": 58.0, "row_h": 30.0, "alt_rows": true,
		"cell_size": 14, "empty_text": "記録がありません",
	})


func _category_label(categories: Array, key: String) -> String:
	for category_value in categories:
		var category: Dictionary = category_value as Dictionary
		if str(category.get("key", "")) == key:
			return str(category.get("label", key))
	return key


# ============================================================ 順位表 (順位表画面から流用)

# 描画本体は基底 _draw_data_table に集約 (2026-06-24)。
func _draw_table(rect: Rect2, title: String, columns: Array, rows: Array) -> void:
	_draw_data_table(rect, columns, rows, {"title": title, "empty_text": "記録がありません"})


# ============================================================ ポストシーズン

func _draw_postseason(rect: Rect2) -> void:
	_round(rect, PANEL, BORDER, 10)
	_text("ポストシーズン", Vector2(rect.position.x + 18, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	# 日本一バナー
	var banner: Rect2 = Rect2(rect.position.x + 18, rect.position.y + 52, rect.size.x - 36, 88)
	if _post_champion_id > 0:
		_round(banner, Color(AMBER.r, AMBER.g, AMBER.b, 0.14), Color(AMBER.r, AMBER.g, AMBER.b, 0.55), 10)
		var champ: PSTeam = GameDb.get_team(_post_champion_id)
		_text("★ 日本一 ★", Vector2(banner.position.x + 24, banner.position.y + 34), 16, AMBER, 200, HORIZONTAL_ALIGNMENT_LEFT, true)
		if champ != null:
			_team_badge(Rect2(banner.position.x + 24, banner.position.y + 42, 34, 34), champ)
			_text(champ.name, Vector2(banner.position.x + 68, banner.position.y + 66), 22, TEXT, banner.size.x - 90, HORIZONTAL_ALIGNMENT_LEFT, true)
	else:
		_round(banner, PANEL_2, BORDER_SOFT, 10)
		_text("日本一未決定", Vector2(banner.position.x, banner.position.y + 50), 16, MUTED, banner.size.x, HORIZONTAL_ALIGNMENT_CENTER)

	if _post_by_stage.is_empty():
		_text("ポストシーズンの記録がありません", Vector2(rect.position.x + 24, rect.position.y + 200), 14, MUTED)
		return

	# レイアウト: 左に細いガター(ステージ名)、その右を2カラム(第1/第2リーグ)に分割。
	var inner_x: float = rect.position.x + 18.0
	var gutter_w: float = 86.0
	var cards_x: float = inner_x + gutter_w
	var cards_w: float = rect.end.x - 18.0 - cards_x
	var gap: float = 14.0
	var col_w: float = (cards_w - gap) / 2.0
	var left_x: float = cards_x
	var right_x: float = cards_x + col_w + gap
	var lay: Dictionary = {
		"inner_x": inner_x, "gutter_w": gutter_w, "left_x": left_x,
		"right_x": right_x, "col_w": col_w, "cards_x": cards_x, "cards_w": cards_w,
	}

	# 列見出し (第1リーグ / 第2リーグ) — バナーから離し、試合結果カードの直上へ寄せる。
	var head_y: float = banner.end.y + 32.0
	_text("第1リーグ", Vector2(left_x, head_y), 14, MUTED, col_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text("第2リーグ", Vector2(right_x, head_y), 14, MUTED, col_w, HORIZONTAL_ALIGNMENT_CENTER)

	# 完了シリーズを1つでも持つステージグループだけ描画する。
	var groups: Array = []
	for group_value in POST_GROUPS:
		if _group_has_data(group_value as Dictionary):
			groups.append(group_value)
	if groups.is_empty():
		return

	var area_top: float = head_y + 16.0
	var area_bottom: float = rect.end.y - 14.0
	var gh: float = (area_bottom - area_top) / float(groups.size())
	for i in range(groups.size()):
		_draw_stage_group(groups[i] as Dictionary, lay, area_top + float(i) * gh, gh)


func _group_has_data(group: Dictionary) -> bool:
	for key in ["central", "pacific", "japan"]:
		if group.has(key) and _post_by_stage.has(str(group[key])):
			return true
	return false


func _draw_stage_group(group: Dictionary, lay: Dictionary, y: float, gh: float) -> void:
	# ガターのステージ名 (複数行は縦中央寄せ)。
	var lines: Array = group.get("lines", []) as Array
	var n: int = lines.size()
	var ly0: float = y + gh * 0.5 - float(n - 1) * 9.0 + 5.0
	for j in range(n):
		_text(str(lines[j]), Vector2(float(lay["inner_x"]), ly0 + float(j) * 18.0), 12, MUTED, float(lay["gutter_w"]) - 6.0, HORIZONTAL_ALIGNMENT_LEFT, j == n - 1)

	var card_y: float = y + 6.0
	var card_h: float = gh - 12.0
	if bool(group.get("split", false)):
		_draw_post_card(Rect2(float(lay["left_x"]), card_y, float(lay["col_w"]), card_h), _post_by_stage.get(str(group["central"])))
		_draw_post_card(Rect2(float(lay["right_x"]), card_y, float(lay["col_w"]), card_h), _post_by_stage.get(str(group["pacific"])))
	else:
		_draw_post_card(Rect2(float(lay["cards_x"]), card_y, float(lay["cards_w"]), card_h), _post_by_stage.get(str(group["japan"])))


# 1シリーズ分のカード。row が null のステージは「未実施」と表示する。
func _draw_post_card(card: Rect2, row: Variant) -> void:
	_round(card, PANEL_2, BORDER_SOFT, 8)
	if row == null:
		_text("未実施", Vector2(card.position.x, card.position.y + card.size.y * 0.5 + 5.0), 13, FAINT, card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		return

	var r: Dictionary = row as Dictionary
	var top_id: int = int(r.get("top_id", 0))
	var chal_id: int = int(r.get("chal_id", 0))
	var win_id: int = int(r.get("winner_id", 0))
	var games: Array = r.get("games", []) as Array
	var has_breakdown: bool = not games.is_empty()

	# --- 対戦カード ---
	# スコアをカード中央のボックスに固定し、両チーム名をその両脇へ寄せて左右間隔を対称にする。
	var line1_y: float = card.position.y + (card.size.y * 0.40 if has_breakdown else card.size.y * 0.5)
	var cxs: float = card.position.x + card.size.x * 0.5
	var score: String = "%d勝%d敗" % [int(r.get("top_wins", 0)), int(r.get("chal_wins", 0))]
	_text(score, Vector2(cxs - 54.0, line1_y + 6.0), 18, TEXT, 108, HORIZONTAL_ALIGNMENT_CENTER, true)

	# 勝者は AMBER 強調、敗退チームはグレーアウト、未決着は通常色。
	var decided: bool = win_id != 0
	var top_col: Color = AMBER if win_id == top_id else (MUTED if decided else TEXT)
	var chal_col: Color = AMBER if win_id == chal_id else (MUTED if decided else TEXT)

	var top_dot_x: float = cxs - 54.0 - 12.0
	_dot(Vector2(top_dot_x, line1_y), 5.0, _team_color(top_id))
	_text_right(_team_short(top_id), top_dot_x - 10.0, line1_y + 6.0, 17, top_col, 96)

	var chal_dot_x: float = cxs + 54.0 + 12.0
	_dot(Vector2(chal_dot_x, line1_y), 5.0, _team_color(chal_id))
	_text(_team_short(chal_id), Vector2(chal_dot_x + 10.0, line1_y + 6.0), 17, chal_col, 96)

	# --- 勝敗の内訳 (各試合のスコアを top チーム視点で) ---
	if has_breakdown:
		_draw_breakdown(card, top_id, games, int(r.get("advantage", 0)))


# カード下部に各試合のスコアチップを中央寄せで並べる (top 視点、勝=緑/敗=赤/分=灰)。
func _draw_breakdown(card: Rect2, top_id: int, games: Array, advantage: int) -> void:
	var chips: Array = []
	if advantage > 0:
		chips.append({"label": "AD", "col": AMBER})
	for game_value in games:
		var g: Dictionary = game_value as Dictionary
		var top_is_home: bool = int(g.get("home_id", 0)) == top_id
		var top_score: int = int(g.get("home_score", 0)) if top_is_home else int(g.get("away_score", 0))
		var opp_score: int = int(g.get("away_score", 0)) if top_is_home else int(g.get("home_score", 0))
		var col: Color = MUTED
		if not bool(g.get("draw", false)):
			col = GREEN if int(g.get("winner_id", 0)) == top_id else RED
		chips.append({"label": "%d-%d" % [top_score, opp_score], "col": col})

	var widths: Array = []
	var total: float = 0.0
	for chip_value in chips:
		var w: float = max(40.0, _measure(str((chip_value as Dictionary)["label"]), 11) + 14.0)
		widths.append(w)
		total += w + 6.0
	if not chips.is_empty():
		total -= 6.0

	var cy: float = card.position.y + card.size.y - 18.0
	var sx: float = card.position.x + max(10.0, (card.size.x - total) * 0.5)
	for i in range(chips.size()):
		var w: float = float(widths[i])
		if sx + w > card.end.x - 8.0:
			break
		var chip: Dictionary = chips[i] as Dictionary
		_draw_game_chip(sx, cy, w, str(chip["label"]), chip["col"] as Color)
		sx += w + 6.0


# 内訳の1試合分チップ。色で勝(緑)/敗(赤)/分(灰)を示す。
func _draw_game_chip(x: float, center_y: float, w: float, label: String, col: Color) -> void:
	_round(Rect2(x, center_y - 11.0, w, 22.0), Color(col.r, col.g, col.b, 0.16), Color(col.r, col.g, col.b, 0.5), 6)
	var tcol: Color = TEXT if col == MUTED else col
	_text(label, Vector2(x, center_y + 4.0), 11, tcol, w, HORIZONTAL_ALIGNMENT_CENTER, true)


# ============================================================ 最優秀選手・新人王

func _draw_awards(rect: Rect2) -> void:
	_round(rect, PANEL, BORDER, 10)
	_text("最優秀選手・新人王", Vector2(rect.position.x + 18, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	if _award_cards.is_empty():
		_text("表彰の記録がありません", Vector2(rect.position.x + 24, rect.position.y + rect.size.y * 0.6), 14, MUTED)
		return

	var n: int = _award_cards.size()
	var inner_x: float = rect.position.x + 18.0
	var usable: float = rect.size.x - 36.0
	var gap: float = 14.0
	var card_w: float = (usable - gap * float(n - 1)) / float(n)
	var card_y: float = rect.position.y + 64.0
	var card_h: float = rect.size.y - 64.0 - 18.0
	for i in range(n):
		var c: Dictionary = _award_cards[i] as Dictionary
		var cr: Rect2 = Rect2(inner_x + float(i) * (card_w + gap), card_y, card_w, card_h)
		var accent: Color = c.get("accent", BLUE) as Color
		_round(cr, PANEL_2, Color(accent.r, accent.g, accent.b, 0.5), 9)
		_round(Rect2(cr.position.x, cr.position.y, cr.size.x, 4.0), accent, Color.TRANSPARENT, 0, 0)
		_text(str(c.get("title", "")), Vector2(cr.position.x, cr.position.y + 32.0), 16, accent, cr.size.x, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text(str(c.get("league", "")), Vector2(cr.position.x, cr.position.y + 54.0), 12, MUTED, cr.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		_text(str(c.get("player", "")), Vector2(cr.position.x + 6.0, cr.position.y + cr.size.y - 22.0), 17, TEXT, cr.size.x - 12.0, HORIZONTAL_ALIGNMENT_CENTER, true)


# ============================================================ 打撃/投手タイトル

func _draw_titles(rect: Rect2, title: String, rows: Array) -> void:
	_round(rect, PANEL, BORDER, 10)
	_text(title, Vector2(rect.position.x + 18, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var inner_x: float = rect.position.x + 16.0
	var label_w: float = 104.0
	var col_w: float = (rect.size.x - 32.0 - label_w) / 2.0
	var c1_x: float = inner_x + label_w
	var c2_x: float = c1_x + col_w

	# ヘッダ
	var hy: float = rect.position.y + 60.0
	_text("部門", Vector2(inner_x + 2.0, hy), 11, FAINT, label_w)
	_text("第1リーグ", Vector2(c1_x + 4.0, hy), 11, FAINT, col_w - 6.0)
	_text("第2リーグ", Vector2(c2_x + 4.0, hy), 11, FAINT, col_w - 6.0)
	_line(Vector2(inner_x, rect.position.y + 68.0), Vector2(rect.end.x - 16.0, rect.position.y + 68.0), BORDER_SOFT, 1.0)

	if rows.is_empty():
		_text("記録がありません", Vector2(inner_x + 4.0, rect.position.y + 100.0), 13, MUTED)
		return

	var row_top: float = rect.position.y + 76.0
	var row_h: float = (rect.end.y - row_top - 10.0) / float(rows.size())
	for i in range(rows.size()):
		var r: Dictionary = rows[i] as Dictionary
		var ty: float = row_top + float(i) * row_h + row_h * 0.5 + 5.0
		if i % 2 == 1:
			_round(Rect2(inner_x, row_top + float(i) * row_h, rect.size.x - 32.0, row_h), Color(1, 1, 1, 0.018), Color.TRANSPARENT, 4, 0)
		_text(str(r.get("label", "")), Vector2(inner_x + 2.0, ty), 13, MUTED, label_w - 4.0)
		_text(str(r.get("central", "")), Vector2(c1_x + 4.0, ty), 13, TEXT, col_w - 8.0)
		_text(str(r.get("pacific", "")), Vector2(c2_x + 4.0, ty), 13, TEXT, col_w - 8.0)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	_build_nav_buttons()

	# ビュー切替チップ (右上、全ビュー共通)。
	var vx: float = 1900.0 - 116.0 * VIEW_CHIPS.size()
	for chip_value in VIEW_CHIPS:
		var chip: Dictionary = chip_value as Dictionary
		var key: String = str(chip.get("key", ""))
		_add_button("view_%s" % key, str(chip.get("label", "")), Rect2(vx, 96, 108, 30),
			func() -> void: _set_view(key), "chip_active" if _view == key else "chip")
		vx += 116.0

	match _view:
		VIEW_YEAR:
			if _has_data and _archives.size() > 1:
				var at_newest: bool = _sel <= 0
				var at_oldest: bool = _sel >= _archives.size() - 1
				_add_button("year_prev", "◀", NAV_PREV,
					func() -> void: _step_year(1), "chip" if not at_oldest else "nav")
				_add_button("year_next", "▶", NAV_NEXT,
					func() -> void: _step_year(-1), "chip" if not at_newest else "nav")
		VIEW_ALLTIME:
			_build_category_chips("bat", ALLTIME_BAT_CATEGORIES, _alltime_bat_key, CAREER_BAT_RECT.position.x, 108.0,
				func(key: String) -> void: _set_alltime_key(true, key))
			_build_category_chips("pit", ALLTIME_PIT_CATEGORIES, _alltime_pit_key, CAREER_PIT_RECT.position.x, 108.0,
				func(key: String) -> void: _set_alltime_key(false, key))
		VIEW_TITLES:
			var tx: float = TITLE_TABLE_RECT.position.x
			var ty: float = 96.0
			for category_value in TITLE_HISTORY_CATEGORIES:
				var category: Dictionary = category_value as Dictionary
				var t_key: String = str(category.get("key", ""))
				var t_label: String = str(category.get("label", ""))
				var w: float = max(76.0, _measure(t_label, 12) + 30.0)
				if tx + w > 1560.0:
					tx = TITLE_TABLE_RECT.position.x
					ty += 38.0
				_add_button("title_%s" % t_key, t_label, Rect2(tx, ty, w, 30),
					func() -> void: _set_title_key(t_key), "chip_active" if _title_key == t_key else "chip")
				tx += w + 8.0

	_layout_buttons()


# 歴代記録ビューの部門チップ (打者/投手テーブルの上に横並び)。
func _build_category_chips(prefix: String, categories: Array, active_key: String, x: float, y: float, on_pick: Callable) -> void:
	var cx: float = x
	for category_value in categories:
		var category: Dictionary = category_value as Dictionary
		var key: String = str(category.get("key", ""))
		var label: String = str(category.get("label", ""))
		var w: float = max(64.0, _measure(label, 12) + 28.0)
		_add_button("%s_%s" % [prefix, key], label, Rect2(cx, y, w, 30),
			func() -> void: on_pick.call(key), "chip_active" if active_key == key else "chip")
		cx += w + 8.0


func _set_view(view: String) -> void:
	if _view == view:
		return
	_view = view
	if view == VIEW_TITLES:
		_build_title_history_rows()
	_build_buttons()
	queue_redraw()


func _set_alltime_key(batting: bool, key: String) -> void:
	if batting:
		_alltime_bat_key = key
	else:
		_alltime_pit_key = key
	_build_buttons()
	queue_redraw()


func _set_title_key(key: String) -> void:
	if _title_key == key:
		return
	_title_key = key
	_build_title_history_rows()
	_build_buttons()
	queue_redraw()


func _step_year(delta: int) -> void:
	var next_sel: int = clampi(_sel + delta, 0, max(0, _archives.size() - 1))
	if next_sel == _sel:
		return
	_sel = next_sel
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ aggregation

func _refresh() -> void:
	_archives = RecordStore.get_season_archives()
	_has_data = not _archives.is_empty()
	_rows_by_league = {}
	_post_champion_id = 0
	_post_by_stage = {}
	_award_cards = []
	_bat_rows = []
	_pit_rows = []
	_year_label = ""
	if not _has_data:
		return

	_sel = clampi(_sel, 0, _archives.size() - 1)
	var archive: PSSeasonArchive = _archives[_archives.size() - 1 - _sel] as PSSeasonArchive
	_year_label = "%d年 (第%d年目)" % [archive.year, archive.season_number]

	for league_row in LEAGUES:
		var key: String = str((league_row as Dictionary)["key"])
		_rows_by_league[key] = _build_league_rows(archive, key)

	_build_postseason(archive)
	_build_awards(archive)
	_build_title_history_rows()


# 全年度の選手レコードから通算リーダーとシーズン最高記録を部門別に構築する。
# 画面インスタンス生成ごとに1回だけ (10年×~900レコードで数ms、初回は RecordStore の
# 全履歴 hydrate が乗るため歴代記録ビューを開いたときに限り実行する)。
func _build_alltime() -> void:
	if _alltime_built:
		return
	_alltime_built = true
	var career: Dictionary = {}          # player_id → {name, first, last, bat, pit}
	var season_bat: Dictionary = {}      # category key → Array[{value, name, year}]
	var season_pit: Dictionary = {}
	for category_value in ALLTIME_BAT_CATEGORIES:
		season_bat[str((category_value as Dictionary)["key"])] = []
	for category_value in ALLTIME_PIT_CATEGORIES:
		season_pit[str((category_value as Dictionary)["key"])] = []

	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		var entry: Dictionary = career.get(record.player_id, {}) as Dictionary
		if entry.is_empty():
			entry = {"name": record.name, "first": record.year, "last": record.year,
				"bat": PSBatterStats.new(), "pit": PSPitcherStats.new()}
		entry["first"] = mini(int(entry["first"]), record.year)
		if record.year >= int(entry["last"]):
			entry["last"] = record.year
			entry["name"] = record.name
		(entry["bat"] as PSBatterStats).add_from(record.batter_stats)
		(entry["pit"] as PSPitcherStats).add_from(record.pitcher_stats)
		career[record.player_id] = entry

		for category_value in ALLTIME_BAT_CATEGORIES:
			var key: String = str((category_value as Dictionary)["key"])
			var value: int = int(record.batter_stats.get(key))
			if value > 0:
				(season_bat[key] as Array).append({"value": value, "name": record.name, "year": record.year})
		for category_value in ALLTIME_PIT_CATEGORIES:
			var key: String = str((category_value as Dictionary)["key"])
			var value: int = int(record.pitcher_stats.get(key))
			if value > 0:
				(season_pit[key] as Array).append({"value": value, "name": record.name, "year": record.year})

	for category_value in ALLTIME_BAT_CATEGORIES:
		var key: String = str((category_value as Dictionary)["key"])
		_career_bat_by_key[key] = _career_leader_rows(career, "bat", key)
		_season_bat_by_key[key] = _season_best_rows(season_bat[key] as Array)
	for category_value in ALLTIME_PIT_CATEGORIES:
		var key: String = str((category_value as Dictionary)["key"])
		_career_pit_by_key[key] = _career_leader_rows(career, "pit", key)
		_season_pit_by_key[key] = _season_best_rows(season_pit[key] as Array)


func _career_leader_rows(career: Dictionary, stats_key: String, category_key: String) -> Array:
	var entries: Array = []
	for player_id in career.keys():
		var entry: Dictionary = career[player_id] as Dictionary
		var value: int = int((entry[stats_key] as Object).get(category_key))
		if value <= 0:
			continue
		entries.append({"value": value, "name": str(entry["name"]), "first": int(entry["first"]), "last": int(entry["last"])})
	entries.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["value"]) > int((b as Dictionary)["value"]))
	var rows: Array = []
	for i in range(mini(ALLTIME_TOP_N, entries.size())):
		var entry: Dictionary = entries[i] as Dictionary
		rows.append({
			"rank": i + 1,
			"player": str(entry["name"]),
			"span": "%d-%d" % [int(entry["first"]), int(entry["last"])],
			"value": int(entry["value"]),
		})
	return rows


func _season_best_rows(entries: Array) -> Array:
	entries.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["value"]) > int((b as Dictionary)["value"]))
	var rows: Array = []
	for i in range(mini(ALLTIME_TOP_N, entries.size())):
		var entry: Dictionary = entries[i] as Dictionary
		rows.append({
			"rank": i + 1,
			"player": str(entry["name"]),
			"span": "%d年" % int(entry["year"]),
			"value": int(entry["value"]),
		})
	return rows


# 選択中のタイトル部門について、年度×両リーグの受賞者一覧を作る (新しい順)。
func _build_title_history_rows() -> void:
	_title_rows = []
	var archives: Array = RecordStore.get_season_archives()
	for i in range(archives.size() - 1, -1, -1):
		var archive: PSSeasonArchive = archives[i] as PSSeasonArchive
		var central_id: int = 0
		var pacific_id: int = 0
		if archive.awards != null:
			var a: PSAwards = archive.awards
			if _title_key == "mvp":
				central_id = a.mvp_central_player_id
				pacific_id = a.mvp_pacific_player_id
			elif _title_key == "rookie":
				central_id = a.rookie_central_player_id
				pacific_id = a.rookie_pacific_player_id
			elif _title_key.begins_with("bat_"):
				var bat_key: String = _title_key.substr(4)
				central_id = int((a.batting_titles.get("central", {}) as Dictionary).get(bat_key, 0))
				pacific_id = int((a.batting_titles.get("pacific", {}) as Dictionary).get(bat_key, 0))
			elif _title_key.begins_with("pit_"):
				var pit_key: String = _title_key.substr(4)
				central_id = int((a.pitching_titles.get("central", {}) as Dictionary).get(pit_key, 0))
				pacific_id = int((a.pitching_titles.get("pacific", {}) as Dictionary).get(pit_key, 0))
		_title_rows.append({
			"year": "%d年" % archive.year,
			"central": _player_label(central_id),
			"pacific": _player_label(pacific_id),
		})


func _build_league_rows(archive: PSSeasonArchive, league_key: String) -> Array:
	var entries: Array = []
	for team_id_str in archive.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id_str))
		if team == null or team.league != league_key:
			continue
		entries.append({"team": team, "entry": archive.standings[team_id_str] as Dictionary})

	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ea: Dictionary = (a as Dictionary)["entry"] as Dictionary
		var eb: Dictionary = (b as Dictionary)["entry"] as Dictionary
		var pa: float = _pct(ea)
		var pb: float = _pct(eb)
		if is_equal_approx(pa, pb):
			return int(ea.get("wins", 0)) > int(eb.get("wins", 0))
		return pa > pb
	)

	var self_id: int = AppState.selected_team_id
	var leader: Dictionary = ((entries[0] as Dictionary)["entry"] as Dictionary) if not entries.is_empty() else {}
	var rows: Array = []
	var rank: int = 1
	for entry_value in entries:
		var ev: Dictionary = entry_value as Dictionary
		var team: PSTeam = ev["team"] as PSTeam
		var e: Dictionary = ev["entry"] as Dictionary
		var w: int = int(e.get("wins", 0))
		var l: int = int(e.get("losses", 0))
		var d: int = int(e.get("draws", 0))
		var rs: int = int(e.get("runs_scored", 0))
		var ra: int = int(e.get("runs_allowed", 0))
		rows.append({
			"rank": rank, "team": team.name, "color": team.color,
			"is_self": team.id == self_id, "is_leader": rank == 1,
			"g": w + l + d, "w": w, "l": l, "d": d, "pct": _pct(e),
			"gb": 0.0 if (rank == 1 or leader.is_empty()) else _game_back(leader, e),
			"rs": rs, "ra": ra, "diff": rs - ra,
		})
		rank += 1
	return rows


func _build_postseason(archive: PSSeasonArchive) -> void:
	if archive.postseason == null:
		return
	var post: PSPostseasonResult = archive.postseason
	_post_champion_id = post.champion_team_id
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var s: Dictionary = post.stage_dict(stage_key)
		if s.is_empty() or not bool(s.get("completed", false)):
			continue
		_post_by_stage[stage_key] = {
			"top_id": int(s.get("top_id", 0)),
			"chal_id": int(s.get("challenger_id", 0)),
			"winner_id": int(s.get("winner_id", 0)),
			"top_wins": int(s.get("top_wins_final", 0)),
			"chal_wins": int(s.get("challenger_wins_final", 0)),
			"advantage": int(s.get("advantage_wins", 0)),
			"games": s.get("games", []) as Array,
		}


func _build_awards(archive: PSSeasonArchive) -> void:
	if archive.awards == null:
		return
	var a: PSAwards = archive.awards
	_award_cards = [
		{"title": "MVP", "league": "第1リーグ", "accent": AMBER, "player": _player_label(a.mvp_central_player_id)},
		{"title": "MVP", "league": "第2リーグ", "accent": AMBER, "player": _player_label(a.mvp_pacific_player_id)},
		{"title": "新人王", "league": "第1リーグ", "accent": BLUE, "player": _player_label(a.rookie_central_player_id)},
		{"title": "新人王", "league": "第2リーグ", "accent": BLUE, "player": _player_label(a.rookie_pacific_player_id)},
	]
	_bat_rows = _build_title_rows(a.batting_titles, BATTING_TITLE_LABELS, PSAwards.BATTING_CATEGORIES)
	_pit_rows = _build_title_rows(a.pitching_titles, PITCHING_TITLE_LABELS, PSAwards.PITCHING_CATEGORIES)


func _build_title_rows(titles_by_league: Dictionary, label_map: Dictionary, order: Array) -> Array:
	var central: Dictionary = titles_by_league.get("central", {}) as Dictionary
	var pacific: Dictionary = titles_by_league.get("pacific", {}) as Dictionary
	var rows: Array = []
	for key in order:
		rows.append({
			"label": str(label_map.get(key, key)),
			"central": _player_label(int(central.get(key, 0))),
			"pacific": _player_label(int(pacific.get(key, 0))),
		})
	return rows


# ============================================================ helpers

func _pct(entry: Dictionary) -> float:
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	return float(w) / float(max(1, w + l))


func _game_back(leader: Dictionary, entry: Dictionary) -> float:
	var lw: int = int(leader.get("wins", 0))
	var ll: int = int(leader.get("losses", 0))
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	return float((lw - w) + (l - ll)) / 2.0


func _player_label(player_id: int) -> String:
	if player_id <= 0:
		return "(該当なし)"
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record.name
	var player: PSPlayer = GameDb.get_player(player_id)
	if player != null:
		return player.name
	return "ID %d" % player_id


func _team_short(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	return team.short_name if team != null else "-"


func _team_color(team_id: int) -> Color:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.color if team != null else MUTED
