extends "res://ui/components/dashboard_screen.gd"

# 能力・成績一覧画面。全選手の能力値・成績・高度な指標を1つの大きな表で横断表示する。
# 選手詳細 (player_detail) が「1 選手 × 全シーズン」で全項目を見せるのに対し、本画面は
# 「全選手 × 当該シーズン」へ組み替えたもの。データ抽出ロジックは player_detail と揃える
# (隠しパラメータ = z / raw 能力値を除く、現在ゲームに存在する全項目を網羅)。
#
# 操作:
#   - 絞り込みチップ (種別/守備位置): 投手 / 先発 / 中継 / 抑え ‖ 野手 / 捕一二三遊左中右。
#     選択した絞り込みの mode (pitcher / batter) で列セットが切り替わる。
#   - タブ: 能力値 / 成績 / 高度な指標。
#   - 球団プルダウン (全球団 + 各球団)。既定は全球団。
#   - 列ヘッダクリックで昇降ソート。行の左クリックで選手を選択 (Ctrl で複数トグル / Shift で範囲選択)、選手名を右クリックで選手詳細へ遷移。
# 高度な指標タブは WAR のリーグ文脈が必要なので、開いている間だけ集計し season ごとにキャッシュする。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const POS_SHORT: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "DH",
}

const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

# 投手能力タブの球種カラム見出し (密な表なので短縮名)。完全名は選手詳細で確認できる。
const PITCH_SHORT: Dictionary = {
	"four_seam": "直", "two_seam": "ツー", "sinker": "シ", "cutter": "カット",
	"slider": "スラ", "curve": "カーブ", "fork": "フォ", "changeup": "チェ",
}

# 絞り込みチップ。mode で投手/野手の列セットが決まる。pos は野手の守備位置。
const FILTERS: Array = [
	{"id": "p_all", "label": "投手", "mode": "pitcher"},
	{"id": "p_sp", "label": "先発", "mode": "pitcher"},
	{"id": "p_rp", "label": "中継", "mode": "pitcher"},
	{"id": "b_all", "label": "野手", "mode": "batter"},
	{"id": "b_2", "label": "捕", "mode": "batter", "pos": 2},
	{"id": "b_3", "label": "一", "mode": "batter", "pos": 3},
	{"id": "b_4", "label": "二", "mode": "batter", "pos": 4},
	{"id": "b_5", "label": "三", "mode": "batter", "pos": 5},
	{"id": "b_6", "label": "遊", "mode": "batter", "pos": 6},
	{"id": "b_7", "label": "左", "mode": "batter", "pos": 7},
	{"id": "b_8", "label": "中", "mode": "batter", "pos": 8},
	{"id": "b_9", "label": "右", "mode": "batter", "pos": 9},
]

const TABS: Array = [
	{"id": "abilities", "label": "能力値"},
	{"id": "stats", "label": "成績"},
	{"id": "advanced", "label": "高度な指標"},
]

const ALL_TEAMS_ID: int = -1               # 内部: 全球団 (記録収集で全チームを走査)
# PopupMenu.add_item は **負の id を渡すと項目インデックスへ自動採番してしまう** (Godot 仕様)。
# そのため全球団は非負の専用 id で登録し、ハンドラで ALL_TEAMS_ID へ翻訳する。実球団 id は 1..12 なので 0 は衝突しない。
const ALL_TEAMS_MENU_ID: int = 0
const CHIP_Y: float = 110.0                # 絞り込みチップ行の上端
const TABLE_RECT: Rect2 = Rect2(262, 164, 1638, 896)

# 規定打席/規定投球回 (rankings_screen と同じ定義: 所属球団の試合数 * 係数)。
const QUALIFIER_PA_PER_TEAM_GAME: float = 3.1
const QUALIFIER_OUTS_PER_TEAM_GAME: float = 3.0

var _team_ids: Array = []
var _view_team_id: int = ALL_TEAMS_ID
var _qualified_only: bool = false          # 規定打席/投球回到達者のみに絞り込むか
var _filter_id: String = "b_all"
var _active_tab: String = "abilities"
var _sort_key: String = ""
var _sort_asc: bool = false
var _selected_ids: Dictionary = {}         # 選択中の player_id 集合 (id -> true)。左クリックで選択(Ctrlで複数)
var _anchor_id: int = 0                     # 範囲選択 (Shift) の起点。単独/Ctrl クリックで更新

var _filtered: Array = []                  # 絞り込み後の PSPlayerSeasonRecord 群
var _rows: Array = []                      # 描画用の行 Dict 群
var _pitch_types: Array = []               # 投手能力タブの球種カラム順 (母集団の和集合)
var _war_ctx_cache: Dictionary = {}        # "year-sn" -> league_ctx

var _row_hits: Array = []                  # [{rect, kind, meta}] 行クリック判定
var _header_hits: Array = []               # [{rect, key}] ヘッダクリック (ソート) 判定
var _scroll_zones: Array = []              # [{rect, key, max}] ホイールスクロール領域
var _scroll: Dictionary = {}

var _team_menu_button: Button = null
var _sep_x: float = 0.0                     # 投手/野手 区切り線の x (絞り込み行)


func _ready() -> void:
	_init_chrome()
	_build_team_order()
	_reset_sort()
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_row_hits = []
	_header_hits = []
	_scroll_zones = []

	var season: PSSeason = AppState.current_season
	if season == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)
		return

	var your_team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	if your_team == null and not GameDb.teams.is_empty():
		your_team = GameDb.teams[0] as PSTeam
	_draw_shell("能力・成績一覧", your_team, season)

	_draw_subheader()

	# ソート中の列にだけ ▲/▼ を付けた描画用コピーを作る (キーは不変なのでヒット判定に影響しない)。
	var columns: Array = _columns_for_current()
	var draw_cols: Array = []
	for col_value in columns:
		var col: Dictionary = (col_value as Dictionary).duplicate()
		if str(col.get("key", "")) == _sort_key:
			col["title"] = str(col.get("title", "")) + (" ▲" if _sort_asc else " ▼")
		draw_cols.append(col)

	# header_top はタブ (rect 上端 +14〜+50) と列ヘッダの間に余白を取るため広めに置く。
	var opts: Dictionary = {
		"header_top": 90.0, "inner_pad": 14.0, "header_size": 12, "cell_size": 13,
		"row_h": 30.0, "alt_rows": true,
		"empty_text": "該当する選手がいません",
		"scroll_key": "main", "scroll": _scroll, "scroll_zones": _scroll_zones,
		"sel_kind": "player", "hits": _row_hits,
	}
	_draw_data_table(TABLE_RECT, draw_cols, _rows, opts)
	_build_header_hits(TABLE_RECT, draw_cols, opts)

	# 選択中の行をハイライト (複数可)。基底テーブルの selected_id は単一なので自前で重ねる。
	for hit_value in _row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if _selected_ids.has(int(hit.get("meta", 0))):
			_round(hit["rect"] as Rect2, Color(BLUE.r, BLUE.g, BLUE.b, 0.10), Color(BLUE.r, BLUE.g, BLUE.b, 0.75), 6, 2)

	# 操作ヒント (タブの右) と件数・選択数 (右肩)。
	_text("クリック=選択 / Ctrl=追加 / Shift=範囲 / 選手名を右クリックで詳細",
		Vector2(TABLE_RECT.position.x + 460.0, TABLE_RECT.position.y + 34.0), 11, FAINT, 660.0)
	var sel_count: int = _selected_ids.size()
	var count_right: float = TABLE_RECT.end.x - 18.0 - (124.0 if sel_count > 0 else 0.0)
	var count_text: String = "選択 %d人 ・ 全%d人" % [sel_count, _rows.size()] if sel_count > 0 else "全%d人" % _rows.size()
	_text_right(count_text, count_right, TABLE_RECT.position.y + 34.0, 12, BLUE if sel_count > 0 else MUTED, 280.0)


# --- サブヘッダ (絞り込みラベル + 区切り線 + 球団プルダウン + 下端の仕切り) ---
func _draw_subheader() -> void:
	_text("絞り込み", Vector2(INNER_L, CHIP_Y + 20.0), 12, FAINT)
	if _sep_x > 0.0:
		_line(Vector2(_sep_x, CHIP_Y - 2.0), Vector2(_sep_x, CHIP_Y + 30.0), BORDER, 1.0)

	# 球団プルダウン (右寄せ)。透明 nav ボタンがこの領域でクリックを拾う。
	var dx: float = 1648.0
	_text("表示", Vector2(dx, CHIP_Y + 6.0), 11, FAINT)
	var nx: float = dx + 34.0
	if _view_team_id != ALL_TEAMS_ID:
		var team: PSTeam = GameDb.get_team(_view_team_id)
		if team != null:
			_team_badge(Rect2(dx + 34.0, CHIP_Y + 1.0, 26, 26), team)
			nx = dx + 70.0
	var view_name: String = "全球団" if _view_team_id == ALL_TEAMS_ID else _team_name(_view_team_id)
	_text(view_name, Vector2(nx, CHIP_Y + 22.0), 17, TEXT)
	_text("▼", Vector2(nx + _measure(view_name, 17) + 8.0, CHIP_Y + 19.0), 12, MUTED)

	_line(Vector2(INNER_L, 152.0), Vector2(INNER_R, 152.0), BORDER_SOFT, 1.0)


func _team_hotspot_rect() -> Rect2:
	return Rect2(1640.0, CHIP_Y - 2.0, 258.0, 34.0)


# ヘッダのクリック可能矩形の構築は基底 _build_table_header_hits に集約 (farm_screen と共用)。
func _build_header_hits(rect: Rect2, columns: Array, opts: Dictionary) -> void:
	_build_table_header_hits(_header_hits, rect, columns, opts)


# ============================================================ columns

func _columns_for_current() -> Array:
	var mode: String = _current_mode()
	var cols: Array = _identity_columns(_active_tab == "abilities")
	match _active_tab:
		"abilities":
			# 疲労 (現在のコンディション) は能力の手前に置く。0〜100% (高いほど疲労)。
			cols.append({"title": "疲労", "key": "fatigue", "w": 46, "align": "c", "fmt": "int"})
			if mode == "pitcher":
				cols.append_array([
					{"title": "球速", "key": "velocity", "w": 54, "align": "c", "fmt": "int"},
					{"title": "球質", "key": "stuff", "w": 50, "align": "c", "fmt": "int"},
					{"title": "制球", "key": "control", "w": 50, "align": "c", "fmt": "int"},
					{"title": "持久", "key": "stamina", "w": 50, "align": "c", "fmt": "int"},
				])
				for type_value in _pitch_types:
					cols.append({"title": str(PITCH_SHORT.get(str(type_value), str(type_value))), "key": "pitch_%s" % str(type_value), "w": 54, "align": "c", "fmt": "int"})
				cols.append_array([
					{"title": "総合", "key": "overall", "w": 50, "align": "r", "fmt": "int"},
					{"title": "守備評", "key": "def_eval", "w": 54, "align": "r", "fmt": "int"},
					{"title": "年俸(万円)", "key": "salary", "w": 82, "align": "r", "fmt": "comma"},
				])
			else:
				cols.append_array([
					{"title": "巧打", "key": "contact", "w": 50, "align": "c", "fmt": "int"},
					{"title": "長打", "key": "power", "w": 50, "align": "c", "fmt": "int"},
					{"title": "走力", "key": "speed", "w": 50, "align": "c", "fmt": "int"},
					{"title": "守備", "key": "defense", "w": 50, "align": "c", "fmt": "int"},
					{"title": "肩力", "key": "arm", "w": 50, "align": "c", "fmt": "int"},
					{"title": "選球", "key": "discipline", "w": 50, "align": "c", "fmt": "int"},
				])
				for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
					cols.append({"title": str(POS_SHORT.get(pos, "?")), "key": "apt_%d" % pos, "w": 36, "align": "c", "fmt": "int"})
				cols.append_array([
					{"title": "総合", "key": "overall", "w": 50, "align": "r", "fmt": "int"},
					{"title": "打撃", "key": "bat_eval", "w": 50, "align": "r", "fmt": "int"},
					{"title": "守備評", "key": "def_eval", "w": 54, "align": "r", "fmt": "int"},
					{"title": "年俸(万円)", "key": "salary", "w": 82, "align": "r", "fmt": "comma"},
				])
		"advanced":
			if mode == "pitcher":
				cols.append_array([
					{"title": "投球回", "key": "ip", "w": 64, "align": "r", "fmt": "f1"},
					{"title": "FIP", "key": "fip", "w": 60, "align": "r", "fmt": "f2"},
					{"title": "WAR", "key": "war", "w": 60, "align": "r", "fmt": "f1s"},
					{"title": "K/9", "key": "k9", "w": 56, "align": "r", "fmt": "f2"},
					{"title": "BB/9", "key": "bb9", "w": 60, "align": "r", "fmt": "f2"},
					{"title": "HR/9", "key": "hr9", "w": 60, "align": "r", "fmt": "f2"},
					{"title": "球/打者", "key": "ppbf", "w": 70, "align": "r", "fmt": "f2"},
					{"title": "球/回", "key": "ppi", "w": 62, "align": "r", "fmt": "f1"},
					{"title": "対戦打者", "key": "bf", "w": 72, "align": "r", "fmt": "int"},
					{"title": "投球数", "key": "pit", "w": 68, "align": "r", "fmt": "int"},
					{"title": "救援", "key": "rel", "w": 56, "align": "r", "fmt": "int"},
				])
			else:
				cols.append_array([
					{"title": "打席", "key": "pa", "w": 52, "align": "r", "fmt": "int"},
					{"title": "球/打席", "key": "ppa", "w": 64, "align": "r", "fmt": "f2"},
					{"title": "wOBA", "key": "woba", "w": 60, "align": "r", "fmt": "rate"},
					{"title": "xwOBA", "key": "xwoba", "w": 64, "align": "r", "fmt": "rate"},
					{"title": "wRC+", "key": "wrcplus", "w": 58, "align": "r", "fmt": "f1"},
					{"title": "RE24", "key": "re24", "w": 62, "align": "r", "fmt": "f1s"},
					{"title": "BSR", "key": "bsr", "w": 58, "align": "r", "fmt": "f1s"},
					{"title": "WAR", "key": "war", "w": 60, "align": "r", "fmt": "f1s"},
					{"title": "OAA", "key": "oaa", "w": 58, "align": "r", "fmt": "f1s"},
					{"title": "OAA内", "key": "oaa_if", "w": 64, "align": "r", "fmt": "f1s"},
					{"title": "OAA外", "key": "oaa_of", "w": 64, "align": "r", "fmt": "f1s"},
					{"title": "RngR", "key": "rngr", "w": 60, "align": "r", "fmt": "f1s"},
					{"title": "ErrR", "key": "errr", "w": 60, "align": "r", "fmt": "f1s"},
					{"title": "DPR", "key": "dpr", "w": 56, "align": "r", "fmt": "f1s"},
					{"title": "UZR", "key": "uzr", "w": 58, "align": "r", "fmt": "f1s"},
					{"title": "DRS", "key": "drs", "w": 58, "align": "r", "fmt": "f1s"},
				])
		_:  # stats (成績 = 基本成績 + 率指標)
			if mode == "pitcher":
				cols.append_array([
					{"title": "登板", "key": "g", "w": 46, "align": "r", "fmt": "int"},
					{"title": "先発", "key": "gs", "w": 46, "align": "r", "fmt": "int"},
					{"title": "完投", "key": "cg", "w": 46, "align": "r", "fmt": "int"},
					{"title": "完封", "key": "sho", "w": 46, "align": "r", "fmt": "int"},
					{"title": "勝", "key": "w", "w": 38, "align": "r", "fmt": "int"},
					{"title": "敗", "key": "l", "w": 38, "align": "r", "fmt": "int"},
					{"title": "H", "key": "hld", "w": 38, "align": "r", "fmt": "int"},
					{"title": "S", "key": "sv", "w": 38, "align": "r", "fmt": "int"},
					{"title": "QS", "key": "qs", "w": 42, "align": "r", "fmt": "int"},
					{"title": "投球回", "key": "ip", "w": 62, "align": "r", "fmt": "f1"},
					{"title": "防御率", "key": "era", "w": 60, "align": "r", "fmt": "f2"},
					{"title": "WHIP", "key": "whip", "w": 58, "align": "r", "fmt": "f2"},
					{"title": "奪三振", "key": "so", "w": 58, "align": "r", "fmt": "int"},
					{"title": "与四球", "key": "bb", "w": 58, "align": "r", "fmt": "int"},
					{"title": "与死球", "key": "hbp", "w": 58, "align": "r", "fmt": "int"},
					{"title": "被安打", "key": "h", "w": 58, "align": "r", "fmt": "int"},
					{"title": "被本", "key": "hra", "w": 48, "align": "r", "fmt": "int"},
					{"title": "失点", "key": "ra", "w": 48, "align": "r", "fmt": "int"},
					{"title": "自責", "key": "er", "w": 48, "align": "r", "fmt": "int"},
				])
			else:
				cols.append_array([
					{"title": "試合", "key": "g", "w": 44, "align": "r", "fmt": "int"},
					{"title": "打席", "key": "pa", "w": 46, "align": "r", "fmt": "int"},
					{"title": "打数", "key": "ab", "w": 44, "align": "r", "fmt": "int"},
					{"title": "得点", "key": "r", "w": 44, "align": "r", "fmt": "int"},
					{"title": "安打", "key": "h", "w": 44, "align": "r", "fmt": "int"},
					{"title": "二塁", "key": "d", "w": 42, "align": "r", "fmt": "int"},
					{"title": "三塁", "key": "t", "w": 42, "align": "r", "fmt": "int"},
					{"title": "本", "key": "hr", "w": 38, "align": "r", "fmt": "int"},
					{"title": "打点", "key": "rbi", "w": 44, "align": "r", "fmt": "int"},
					{"title": "盗塁", "key": "sb", "w": 44, "align": "r", "fmt": "int"},
					{"title": "打率", "key": "avg", "w": 54, "align": "r", "fmt": "rate"},
					{"title": "出塁", "key": "obp", "w": 54, "align": "r", "fmt": "rate"},
					{"title": "長打", "key": "slg", "w": 54, "align": "r", "fmt": "rate"},
					{"title": "OPS", "key": "ops", "w": 54, "align": "r", "fmt": "rate"},
					{"title": "四球", "key": "bb", "w": 44, "align": "r", "fmt": "int"},
					{"title": "死球", "key": "hbp", "w": 44, "align": "r", "fmt": "int"},
					{"title": "三振", "key": "so", "w": 44, "align": "r", "fmt": "int"},
					{"title": "犠打", "key": "sac", "w": 44, "align": "r", "fmt": "int"},
					{"title": "犠飛", "key": "sf", "w": 44, "align": "r", "fmt": "int"},
					{"title": "併殺", "key": "gdp", "w": 44, "align": "r", "fmt": "int"},
					{"title": "失策", "key": "err", "w": 44, "align": "r", "fmt": "int"},
				])
	return cols


# 全タブ共通の先頭列 (球団 / 選手 / 守備位置or役割 / 年齢)。
func _identity_columns(include_age: bool) -> Array:
	var cols: Array = [
		{"title": "球団", "key": "team", "w": 56, "align": "l", "fmt": "team"},
		{"title": "選手", "key": "name", "w": 118, "align": "l", "fmt": "str", "strong": true},
	]
	if _current_mode() == "pitcher":
		cols.append({"title": "役", "key": "role", "w": 40, "align": "c", "fmt": "pos_badge", "sort_key": "role_sort"})
	else:
		cols.append({"title": "守", "key": "pos", "w": 40, "align": "c", "fmt": "pos_badge", "sort_key": "pos_sort"})
	if include_age:
		cols.append({"title": "年齢", "key": "age", "w": 42, "align": "c", "fmt": "int"})
	return cols


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	if season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()
	_team_menu_button = _add_button("team_menu", "", _team_hotspot_rect(), _on_team_menu_pressed, "nav")

	# 絞り込みチップ (投手群 ‖ 野手群)。
	var x: float = INNER_L + 70.0
	_sep_x = 0.0
	for filter_value in FILTERS:
		var filter: Dictionary = filter_value as Dictionary
		var fid: String = str(filter["id"])
		if fid == "b_all":
			_sep_x = x + 2.0
			x += 18.0
		var label: String = str(filter["label"])
		var w: float = 38.0 if label.length() <= 1 else 52.0
		var active: bool = fid == _filter_id
		_add_button("flt_%s" % fid, label, Rect2(x, CHIP_Y, w, 30.0),
			func(target: String = fid) -> void: _on_filter_pressed(target), "chip_active" if active else "chip")
		x += w + 8.0

	# 規定打席/投球回到達者のみ (絞り込みチップ群の右にトグルとして置く)。
	x += 14.0
	var qual_label: String = "規定到達のみ"
	var qual_w: float = _measure(qual_label, 13) + 24.0
	_add_button("flt_qualified", qual_label, Rect2(x, CHIP_Y, qual_w, 30.0),
		func() -> void: _on_qualified_toggle(), "chip_active" if _qualified_only else "chip")

	# タブ (能力値 / 成績 / 高度な指標)。
	var tx: float = TABLE_RECT.position.x + 16.0
	for tab_value in TABS:
		var tab: Dictionary = tab_value as Dictionary
		var tid: String = str(tab["id"])
		var act: bool = tid == _active_tab
		_add_button("tab_%s" % tid, str(tab["label"]), Rect2(tx, TABLE_RECT.position.y + 14.0, 134.0, 36.0),
			func(target: String = tid) -> void: _on_tab_pressed(target), "chip_active" if act else "chip")
		tx += 144.0

	# 選択解除ボタン (選択がある時だけ、テーブル右肩に)。
	if not _selected_ids.is_empty():
		_add_button("clear_sel", "選択解除 (%d)" % _selected_ids.size(),
			Rect2(TABLE_RECT.end.x - 16.0 - 104.0, TABLE_RECT.position.y + 15.0, 104.0, 30.0),
			func() -> void: _on_clear_selection(), "action")

	_layout_buttons()


func _on_filter_pressed(filter_id: String) -> void:
	if _filter_id == filter_id:
		return
	_filter_id = filter_id
	_reset_sort()
	_refresh()
	_build_buttons()
	queue_redraw()


# 規定打席/投球回のトグル。列セット (タブ/mode) は変わらず母集団だけが変わるので、
# 球団プルダウン (_on_team_selected) と同様にソートはリセットせずそのまま _refresh する。
func _on_qualified_toggle() -> void:
	_qualified_only = not _qualified_only
	_refresh()
	_build_buttons()
	queue_redraw()


func _on_tab_pressed(tab_id: String) -> void:
	if _active_tab == tab_id:
		return
	_active_tab = tab_id
	# タブ切替は列セットが変わるだけなので、ソートをやり直さず現在の並び順を維持する
	# (絞り込み変更 _on_filter_pressed は母集団自体が変わるのでソートし直す)。
	_refresh(true)
	_build_buttons()
	queue_redraw()


func _on_header_clicked(key: String) -> void:
	if key.is_empty():
		return
	if _sort_key == key:
		_sort_asc = not _sort_asc
	else:
		_sort_key = key
		_sort_asc = false
	_sort_rows()
	queue_redraw()


# 行の左クリック:
#   通常        = その選手のみ単独選択 (アンカー更新)
#   Ctrl (additive)      = トグル追加/解除 (アンカー更新)
#   Shift (range_select) = アンカー〜クリック行を表示順で範囲選択 (Ctrl 併用なら既存選択へ追加・アンカーは保持)
# まとめて解除したいときは右肩の「選択解除」ボタンを使う。
func _on_row_selected(player_id: int, additive: bool, range_select: bool) -> void:
	if player_id <= 0:
		return
	var anchor_index: int = _row_index_of(_anchor_id)
	var click_index: int = _row_index_of(player_id)
	if range_select and anchor_index >= 0 and click_index >= 0:
		if not additive:
			_selected_ids.clear()
		for i in range(min(anchor_index, click_index), max(anchor_index, click_index) + 1):
			_selected_ids[int((_rows[i] as Dictionary).get("__meta", 0))] = true
		# アンカーは保持 (連続 Shift クリックで範囲を伸縮できる)。
	elif additive:
		if _selected_ids.has(player_id):
			_selected_ids.erase(player_id)
		else:
			_selected_ids[player_id] = true
		_anchor_id = player_id
	else:
		_selected_ids = {player_id: true}
		_anchor_id = player_id
	_build_buttons()  # 選択解除ボタンの有無/件数が変わる
	queue_redraw()


# 表示順 (_rows) における player_id の行インデックス。範囲選択の境界に使う。
func _row_index_of(player_id: int) -> int:
	if player_id <= 0:
		return -1
	for i in range(_rows.size()):
		if int((_rows[i] as Dictionary).get("__meta", 0)) == player_id:
			return i
	return -1


func _on_clear_selection() -> void:
	if _selected_ids.is_empty():
		return
	_selected_ids.clear()
	_anchor_id = 0
	_build_buttons()
	queue_redraw()


# base_pos が「選手」列の x 範囲内か (右クリックでの選手詳細遷移用)。列の x 幅はヘッダ判定と同一。
func _is_in_name_column(base_pos: Vector2) -> bool:
	for hit_value in _header_hits:
		var hit: Dictionary = hit_value as Dictionary
		if str(hit.get("key", "")) == "name":
			var r: Rect2 = hit["rect"] as Rect2
			return base_pos.x >= r.position.x and base_pos.x <= r.position.x + r.size.x
	return false


func _on_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	menu.add_item("全球団", ALL_TEAMS_MENU_ID)
	for i in range(_team_ids.size()):
		var team: PSTeam = GameDb.get_team(int(_team_ids[i]))
		if team == null:
			continue
		if i == 0:
			menu.add_separator(team.league_label())
		else:
			var prev: PSTeam = GameDb.get_team(int(_team_ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(team.league_label())
		menu.add_item("%s (%s)" % [team.name, team.short_name], int(_team_ids[i]))
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_team_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(_team_hotspot_rect().position.x, CHIP_Y + 30.0))
	if _team_menu_button != null:
		anchor = _team_menu_button.global_position + Vector2(0.0, _team_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_team_selected(menu_id: int) -> void:
	var team_id: int = ALL_TEAMS_ID if menu_id == ALL_TEAMS_MENU_ID else menu_id
	if team_id == _view_team_id:
		return
	if team_id != ALL_TEAMS_ID and not _team_ids.has(team_id):
		return
	_view_team_id = team_id
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ input

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	_update_transform()
	var base_pos: Vector2 = _to_base(event.position)
	match event.button_index:
		MOUSE_BUTTON_WHEEL_DOWN:
			if _scroll_at(base_pos, 1):
				accept_event()
		MOUSE_BUTTON_WHEEL_UP:
			if _scroll_at(base_pos, -1):
				accept_event()
		MOUSE_BUTTON_LEFT:
			var header: Dictionary = _header_at(base_pos)
			if not header.is_empty():
				_on_header_clicked(str(header.get("key", "")))
				accept_event()
				return
			var row: Dictionary = _row_at(base_pos)
			if not row.is_empty():
				_on_row_selected(int(row.get("meta", 0)), event.ctrl_pressed, event.shift_pressed)
				accept_event()
		MOUSE_BUTTON_RIGHT:
			# 選手名の項目を右クリックすると選手詳細へ。
			var row2: Dictionary = _row_at(base_pos)
			if not row2.is_empty() and _is_in_name_column(base_pos):
				AppState.show_player_detail(int(row2.get("meta", 0)))
				accept_event()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


func _header_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _header_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit
	return {}


func _row_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit
	return {}


func _scroll_at(base_pos: Vector2, direction: int) -> bool:
	for zone_value in _scroll_zones:
		var zone: Dictionary = zone_value as Dictionary
		if not (zone["rect"] as Rect2).has_point(base_pos):
			continue
		var key: String = str(zone.get("key", ""))
		var max_off: int = int(zone.get("max", 0))
		var current: int = clampi(int(_scroll.get(key, 0)) + direction, 0, max_off)
		if current != int(_scroll.get(key, 0)):
			_scroll[key] = current
			queue_redraw()
		return true
	return false


# ============================================================ data

func _build_team_order() -> void:
	_team_ids = []
	for league_key in ["league1", "league2"]:
		var ids: Array = []
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team.league == league_key:
				ids.append(team.id)
		ids.sort()
		for id_value in ids:
			_team_ids.append(int(id_value))


func _refresh(preserve_order: bool = false) -> void:
	var prev_order: Array = _row_meta_order() if preserve_order else []
	_collect_records()
	_build_rows()
	if preserve_order:
		_apply_meta_order(prev_order)
	else:
		_sort_rows()
	# 母集団が変わったらスクロール位置を先頭へ戻す。
	_scroll["main"] = 0


# 現在の表示順 (__meta = player_id) を配列で返す。タブ切替時の並び順維持に使う。
func _row_meta_order() -> Array:
	var metas: Array = []
	for row_value in _rows:
		metas.append((row_value as Dictionary).get("__meta"))
	return metas


# _rows を given の __meta 順に並べ替える (タブ切替でソートをやり直さず並び順を保つ)。
# order に無い行 (母集団が変わった場合) は元の相対順のまま末尾へ送る。
func _apply_meta_order(order: Array) -> void:
	if order.is_empty() or _rows.is_empty():
		return
	var index_by_meta: Dictionary = {}
	for i in range(order.size()):
		index_by_meta[order[i]] = i
	var fallback: int = order.size()
	_rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ia: int = int(index_by_meta.get((a as Dictionary).get("__meta"), fallback))
		var ib: int = int(index_by_meta.get((b as Dictionary).get("__meta"), fallback))
		return ia < ib
	)


func _collect_records() -> void:
	_filtered = []
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var fdef: Dictionary = _filter_def(_filter_id)
	var team_list: Array = _team_ids if _view_team_id == ALL_TEAMS_ID else [_view_team_id]
	for tid_value in team_list:
		for record_row in RecordStore.get_team_player_records(int(tid_value), season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not _filter_match(record, fdef):
				continue
			if _qualified_only and not _is_qualified(record):
				continue
			_filtered.append(record)


func _build_rows() -> void:
	_rows = []
	_pitch_types = []
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var mode: String = _current_mode()
	var ctx: Dictionary = {}
	if _active_tab == "advanced":
		ctx = _league_ctx(season.year, season.season_number)
	if _active_tab == "abilities" and mode == "pitcher":
		_pitch_types = _compute_pitch_union()
	for record_row in _filtered:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		match _active_tab:
			"abilities":
				_rows.append(_ability_row(record))
			"advanced":
				_rows.append(_advanced_row(record, ctx))
			_:
				_rows.append(_stat_row(record))


# 母集団の投手が持つ球種の和集合を ALL_TYPES 順で返す (能力タブの球種カラム順)。
func _compute_pitch_union() -> Array:
	var present: Dictionary = {}
	for record_row in _filtered:
		for entry_value in (record_row as PSPlayerSeasonRecord).arsenal_or_derived():
			present[str((entry_value as Dictionary).get("type", ""))] = true
	var out: Array = []
	for type_key in PSPitchTypes.ALL_TYPES:
		if present.has(type_key):
			out.append(type_key)
	return out


func _league_ctx(year: int, season_number: int) -> Dictionary:
	var key: String = "%d-%d" % [year, season_number]
	if not _war_ctx_cache.has(key):
		_war_ctx_cache[key] = WarCalculator.build_league_context(year, season_number)
	return _war_ctx_cache[key] as Dictionary


# 全行共通の識別フィールド (球団色ドット / 選手名 / 守備位置or役割バッジ / 年齢 / 行メタ)。
func _identity_fields(record: PSPlayerSeasonRecord) -> Dictionary:
	var team: PSTeam = GameDb.get_team(record.team_id)
	var row: Dictionary = {
		"team": team.short_name if team != null else "-",
		"color": team.color if team != null else MUTED,
		"name": record.name,
		"age": record.age,
		"__meta": record.player_id,
	}
	if record.is_pitcher():
		var badge: Dictionary = _role_badge(record.role)
		row["role"] = badge["text"]
		row["role_color"] = badge["color"]
		row["role_sort"] = badge["sort"]
		row["role_dev"] = record.development_player
	else:
		row["pos"] = str(POS_SHORT.get(record.position, "?"))
		row["pos_color"] = _pos_color(record.position)
		row["pos_sort"] = record.position
		row["pos_dev"] = record.development_player
	return row


func _ability_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	var fatigue_pct: int = _fatigue_pct(record)
	row["fatigue"] = fatigue_pct
	row["fatigue_color"] = _fatigue_color(fatigue_pct)
	var ratings: Array = PSPlayerVisibleRatings.ratings_for_record(record).get("display_ratings", []) as Array
	for rating_value in ratings:
		var rating: Dictionary = rating_value as Dictionary
		var key: String = str(rating.get("key", ""))
		var value: int = int(rating.get("display_value", rating.get("value", 0)))
		var suffix: String = str(rating.get("suffix", ""))
		row[key] = value
		row["%s_color" % key] = _rating_color(value, suffix)
	var overall: int = PlayerValueEvaluator.overall_score(record)
	row["overall"] = overall
	row["overall_color"] = _eval_color(overall)
	row["salary"] = record.salary
	if record.is_pitcher():
		var def_eval: int = PlayerValueEvaluator.defensive_score_for_position(record, 1)
		row["def_eval"] = def_eval
		row["def_eval_color"] = _eval_color(def_eval)
		var mastery_by_type: Dictionary = {}
		for entry_value in record.arsenal_or_derived():
			var entry: Dictionary = entry_value as Dictionary
			mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
		for type_value in _pitch_types:
			var type_key: String = str(type_value)
			if mastery_by_type.has(type_key):
				var display_value: int = PSAbilityScale.z_to_display(float(mastery_by_type[type_key]))
				row["pitch_%s" % type_key] = display_value
				row["pitch_%s_color" % type_key] = _rating_color(display_value, "")
			else:
				row["pitch_%s" % type_key] = "-"
	else:
		var bat_eval: int = PlayerValueEvaluator.batting_score_without_fatigue(record)
		row["bat_eval"] = bat_eval
		row["bat_eval_color"] = _eval_color(bat_eval)
		if record.position >= 2 and record.position <= 9:
			var def_eval2: int = PlayerValueEvaluator.defensive_score_for_position(record, record.position)
			row["def_eval"] = def_eval2
			row["def_eval_color"] = _eval_color(def_eval2)
		else:
			row["def_eval"] = "-"
		for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
			var apt: int = _position_aptitude(record, pos)
			if apt > 0:
				row["apt_%d" % pos] = apt
				row["apt_%d_color" % pos] = _rating_color(apt, "")
			else:
				row["apt_%d" % pos] = "-"
	return row


func _stat_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	if record.is_pitcher():
		row.merge(_pitcher_basic_dict(record), true)
	else:
		row.merge(_batter_basic_dict(record), true)
	return row


func _advanced_row(record: PSPlayerSeasonRecord, ctx: Dictionary) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	var war: Dictionary = WarCalculator.season_war(record, ctx)
	var pm_keys: Array
	if record.is_pitcher():
		row.merge(_pitcher_advanced_dict(record, war), true)
		pm_keys = ["war"]
	else:
		row.merge(_batter_advanced_dict(record, war), true)
		pm_keys = ["war", "oaa", "oaa_if", "oaa_of", "rngr", "errr", "dpr", "uzr", "drs", "re24", "bsr"]
	for key in pm_keys:
		var value: Variant = row.get(key, "-")
		if value is int or value is float:
			row["%s_color" % key] = _pm_color(float(value))
	return row


func _batter_basic_dict(record: PSPlayerSeasonRecord) -> Dictionary:
	var s: PSBatterStats = record.batter_stats
	return {
		"g": s.games, "pa": s.plate_appearances, "ab": s.at_bats, "r": s.runs, "h": s.hits,
		"d": s.doubles, "t": s.triples, "hr": s.home_runs, "rbi": s.runs_batted_in, "sb": s.stolen_bases,
		"avg": s.batting_average(), "obp": s.on_base_percentage(), "slg": s.slugging_percentage(), "ops": s.ops(),
		"bb": s.walks, "hbp": s.hit_by_pitches, "so": s.strikeouts,
		"sac": s.sacrifices, "sf": s.sacrifice_flies, "gdp": s.double_plays, "err": s.errors,
	}


func _pitcher_basic_dict(record: PSPlayerSeasonRecord) -> Dictionary:
	var s: PSPitcherStats = record.pitcher_stats
	return {
		"g": s.games, "gs": s.starts, "cg": s.complete_games, "sho": s.shutouts,
		"w": s.wins, "l": s.losses, "hld": s.holds, "sv": s.saves, "qs": s.quality_starts,
		"ip": s.innings_pitched(), "era": s.era(), "whip": s.whip(),
		"so": s.strikeouts, "bb": s.walks, "hbp": s.hit_batters, "h": s.hits_allowed, "hra": s.home_runs_allowed,
		"ra": s.runs_allowed, "er": s.earned_runs,
	}


func _batter_advanced_dict(record: PSPlayerSeasonRecord, war: Dictionary) -> Dictionary:
	var ad: PSAdvancedStats = record.advanced_stats
	var bs: PSBatterStats = record.batter_stats
	var has_pa: bool = ad != null and ad.plate_appearances > 0
	var ad_dict: Dictionary = ad.to_dict() if ad != null else {}
	var chances: int = int(ad_dict.get("fielding_chances", 0))
	var has_field: bool = chances > 0
	var field_val: Callable = func(key: String) -> Variant:
		return float(ad_dict.get(key, 0.0)) if has_field else "-"
	return {
		"pa": ad.plate_appearances if ad != null else 0,
		"ppa": (float(bs.pitches_seen) / float(bs.plate_appearances)) if bs.plate_appearances > 0 else "-",
		"woba": ad.woba() if has_pa else "-",
		"xwoba": ad.xwoba() if has_pa else "-",
		"wrcplus": ad.wrc_plus() if has_pa else "-",
		"re24": ad.re24_sum if has_pa else "-",
		"bsr": ad.bsr_sum if has_pa else "-",
		"war": float(war.get("war", 0.0)) if has_pa else "-",
		"oaa": field_val.call("oaa_total"),
		"oaa_if": field_val.call("oaa_infield"),
		"oaa_of": field_val.call("oaa_outfield"),
		"rngr": field_val.call("rngr"),
		"errr": field_val.call("errr"),
		"dpr": field_val.call("dpr"),
		"uzr": field_val.call("uzr"),
		"drs": field_val.call("drs"),
	}


func _pitcher_advanced_dict(record: PSPlayerSeasonRecord, war: Dictionary) -> Dictionary:
	var ps: PSPitcherStats = record.pitcher_stats
	var has_ip: bool = ps.outs_pitched > 0
	var ip: float = ps.innings_pitched()
	return {
		"ip": ip,
		"fip": float(war.get("fip", 0.0)) if has_ip else "-",
		"war": float(war.get("war", 0.0)) if has_ip else "-",
		"k9": ps.strikeouts_per_nine() if has_ip else "-",
		"bb9": (float(ps.walks) * 9.0 / ip) if has_ip else "-",
		"hr9": (float(ps.home_runs_allowed) * 9.0 / ip) if has_ip else "-",
		"ppbf": (float(ps.pitches_thrown) / float(ps.batters_faced)) if ps.batters_faced > 0 else "-",
		"ppi": (float(ps.pitches_thrown) / ip) if has_ip else "-",
		"bf": ps.batters_faced, "pit": ps.pitches_thrown, "rel": ps.relief_appearances,
	}


# ============================================================ sort

func _reset_sort() -> void:
	var sort: Dictionary = _default_sort_for(_active_tab, _current_mode())
	_sort_key = str(sort["key"])
	_sort_asc = bool(sort["asc"])


func _default_sort_for(tab: String, mode: String) -> Dictionary:
	match tab:
		"stats":
			return {"key": ("ip" if mode == "pitcher" else "pa"), "asc": false}
		"advanced":
			return {"key": "war", "asc": false}
		_:
			return {"key": "overall", "asc": false}


# 並べ替え本体は基底 _sort_table_rows に集約 (farm_screen と共用)。
# 主キーが同値のとき (例: 本塁打0の選手同士) に今季出場なしの選手が挟まらないよう、
# 出場量 (打者は打席数、投手は投球回) を第2キーにする。
func _sort_rows() -> void:
	var tiebreak_key: String = "ip" if _current_mode() == "pitcher" else "pa"
	_sort_table_rows(_rows, _columns_for_current(), _sort_key, _sort_asc, tiebreak_key)


# ============================================================ helpers

func _current_mode() -> String:
	return str(_filter_def(_filter_id).get("mode", "batter"))


func _filter_def(filter_id: String) -> Dictionary:
	for filter_value in FILTERS:
		if str((filter_value as Dictionary).get("id", "")) == filter_id:
			return filter_value as Dictionary
	return FILTERS[0] as Dictionary


func _filter_match(record: PSPlayerSeasonRecord, fdef: Dictionary) -> bool:
	if str(fdef.get("mode", "")) == "pitcher":
		if not record.is_pitcher():
			return false
		match str(fdef.get("id", "")):
			"p_sp":
				return record.is_starter_pitcher()
			"p_rp":
				return not record.is_starter_pitcher()
			_:  # p_all
				return true
	if record.is_pitcher():
		return false
	if str(fdef.get("id", "")) == "b_all":
		return true
	return record.position == int(fdef.get("pos", 0))


# 規定打席/規定投球回 = 所属球団の(その時点の)試合数 * 係数 (rankings_screen と同じ定義)。
func _is_qualified(record: PSPlayerSeasonRecord) -> bool:
	var team_games: int = _team_games_for_record(record)
	if record.is_pitcher():
		var required_outs: int = int(max(1, ceil(QUALIFIER_OUTS_PER_TEAM_GAME * float(team_games))))
		return record.pitcher_stats.outs_pitched >= required_outs
	var required_pa: int = int(max(1, ceil(QUALIFIER_PA_PER_TEAM_GAME * float(team_games))))
	return record.batter_stats.plate_appearances >= required_pa


func _team_games_for_record(record: PSPlayerSeasonRecord) -> int:
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(record.team_id, record.year, record.season_number)
	if team_record != null:
		return int(team_record.stats.games)
	var season: PSSeason = AppState.current_season
	if season != null and season.standings.has(record.team_id):
		var stats: PSStats = season.standings[record.team_id] as PSStats
		if stats != null:
			return int(stats.games)
	return 0


func _role_badge(role: String) -> Dictionary:
	if role == "starter":
		return {"text": "先", "color": PINK, "sort": 0}
	return {"text": "中", "color": RED, "sort": 1}


func _position_aptitude(record: PSPlayerSeasonRecord, pos: int) -> int:
	var key: String = str(POSITION_APTITUDE_KEYS.get(pos, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == pos else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.name if team != null else "?"


# 疲労を 0〜100% へ正規化 (active_roster と同じ FATIGUE_MAX 基準)。
func _fatigue_pct(record: PSPlayerSeasonRecord) -> int:
	return clampi(int(round(float(record.fatigue) * 100.0 / float(GameSimulator.FATIGUE_MAX))), 0, 100)


# 疲労は高いほど悪い (能力段階色とは逆)。低い間は控えめ、高くなると警告色。
func _fatigue_color(pct: int) -> Color:
	if pct >= 70:
		return RED
	if pct >= 40:
		return AMBER
	return MUTED


# 配色規約: 優秀=青 / 次点=緑 / 平均=黄 / 低=赤 ([[feedback_ui_color_conventions]])。
func _rating_color(value: int, suffix: String) -> Color:
	if suffix == "km/h":
		return BLUE
	if value >= 75:
		return BLUE
	if value >= 55:
		return GREEN
	if value >= 40:
		return AMBER
	return RED


func _eval_color(score: int) -> Color:
	if score >= 75:
		return BLUE
	if score >= 60:
		return GREEN
	if score >= 45:
		return AMBER
	return RED
