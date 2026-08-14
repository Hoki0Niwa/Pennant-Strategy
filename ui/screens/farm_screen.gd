extends "res://ui/components/dashboard_screen.gd"

# ファーム情報画面。二軍 (ファーム) をまとめて見るための専用画面で、順位と成績をビュー切替で出す。
# 一軍側の画面 (順位表 / 能力・成績一覧) には二軍を混ぜず、二軍の閲覧はすべてここへ集約する。
#
# ビュー:
#   - 順位: 3地区 (東5 / 中5 / 西4 = 一軍12球団 + ファーム専用2球団) の順位表 + リーグ集計帯。
#     **地区で試合数が揃わない前提なので順位は勝率で決める** (実 NPB のファームも中止試合の
#     再試合を行わず勝率で順位を決める)。したがって「差」「残」列は置かない。
#   - 成績: 二軍成績の選手一覧 (絞り込み / 球団 / 規定到達 / 列ヘッダソート)。
#     **成績は farm_* コンテナからしか読まない** — 一軍成績と混ぜないのが二軍実装の防波堤。
#     入替判断に使う wOBA / xwOBA / wRAA / BSR / OAA / UZR も farm_advanced_stats から表示する。
#
# 集計は _refresh で1度だけ行い、_draw は描画専念 (順位ビューは14球団ぶん RecordStore を舐めるため、
# 開いているビューのぶんだけ集計する)。

const VIEW_STANDINGS: String = "standings"
const VIEW_STATS: String = "stats"
const VIEWS: Array = [
	{"id": VIEW_STANDINGS, "label": "順位"},
	{"id": VIEW_STATS, "label": "成績"},
]

const POS_SHORT: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "DH",
}

# 絞り込みチップ。mode で投手/野手の列セットが決まる (ability_stats と同じ構成)。
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

const ALL_TEAMS_ID: int = -1               # 内部: 全球団 (記録収集で全チームを走査)
# PopupMenu.add_item は **負の id を渡すと項目インデックスへ自動採番してしまう** (Godot 仕様)。
# 全球団は非負の専用 id で登録し、ハンドラで ALL_TEAMS_ID へ翻訳する (実球団 id は 1..14)。
const ALL_TEAMS_MENU_ID: int = 0

# --- レイアウト基準 (base 座標) ---
const INFO_Y: float = 112.0                # ステータス行のベースライン
const CHIP_Y: float = 138.0                # ビュー/絞り込みチップ行の上端
const VIEW_CHIP_W: float = 78.0

# 順位ビュー: 地区別テーブル3枚 + 最下段のリーグ集計帯。西地区だけ4球団なので少し低い。
const DISTRICT_RECTS: Array = [
	Rect2(262, 186, 1638, 250),
	Rect2(262, 448, 1638, 250),
	Rect2(262, 710, 1638, 228),
]
const SUMMARY_RECT: Rect2 = Rect2(262, 950, 1638, 108)

# 成績ビュー: 全幅の1枚表。
const TABLE_RECT: Rect2 = Rect2(262, 186, 1638, 872)

# 規定打席/規定投球回 (rankings_screen と同じ定義: 所属球団の試合数 * 係数)。
# 分母は二軍の消化数なので、地区で試合数が違っても球団ごとに正しい閾値になる。
const QUALIFIER_PA_PER_TEAM_GAME: float = 3.1
const QUALIFIER_OUTS_PER_TEAM_GAME: float = 3.0

var _view: String = VIEW_STANDINGS
var _filter_id: String = "b_all"
var _team_ids: Array = []                  # 二軍参加14球団 (一軍12 + 専用2)
var _view_team_id: int = ALL_TEAMS_ID
var _qualified_only: bool = false
var _sort_key: String = ""
var _sort_asc: bool = false

var _status_text: String = ""
var _rows_by_district: Dictionary = {}     # {district: Array of 行 Dictionary}
var _summary_cells: Array = []             # _stat_strip のセル配列 (リーグ全体)
var _filtered: Array = []                  # 絞り込み後の PSPlayerSeasonRecord 群
var _rows: Array = []                      # 成績ビューの行 Dictionary 群

var _row_hits: Array = []                  # [{rect, kind, meta}] 行クリック判定
var _header_hits: Array = []               # [{rect, key}] ヘッダクリック (ソート) 判定
var _scroll_zones: Array = []              # [{rect, key, max}] ホイールスクロール領域
var _scroll: Dictionary = {}

var _team_menu_button: Button = null
var _sep_x: float = 0.0                    # 投手/野手 区切り線の x (絞り込み行)


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
	_draw_shell("ファーム情報", your_team, season)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, INFO_Y), 13, MUTED)

	if _view == VIEW_STATS:
		_draw_stats_subheader()
		_draw_stats_view()
	else:
		_draw_standings_view()


func _draw_standings_view() -> void:
	for i in range(PSFarmLeague.DISTRICT_ORDER.size()):
		var district: String = str(PSFarmLeague.DISTRICT_ORDER[i])
		var rows: Array = _rows_by_district.get(district, []) as Array
		_draw_data_table(DISTRICT_RECTS[i] as Rect2, _district_columns(), rows, {
			"title": PSFarmLeague.district_label(district),
			"right_label": ("%d球団 ・ 勝率順" % rows.size()) if not rows.is_empty() else "",
			"empty_text": "二軍の順位はまだ記録されていません",
		})
	if _summary_cells.is_empty():
		_panel(SUMMARY_RECT, "ファーム全体")
	else:
		_stat_strip(SUMMARY_RECT, _summary_cells)


func _draw_stats_view() -> void:
	# ソート中の列にだけ ▲/▼ を付けた描画用コピーを作る (キーは不変なのでヒット判定に影響しない)。
	var columns: Array = _stat_columns()
	var draw_cols: Array = []
	for col_value in columns:
		var col: Dictionary = (col_value as Dictionary).duplicate()
		if str(col.get("key", "")) == _sort_key:
			col["title"] = str(col.get("title", "")) + (" ▲" if _sort_asc else " ▼")
		draw_cols.append(col)

	var opts: Dictionary = {
		"title": "二軍成績", "header_top": 72.0, "inner_pad": 14.0, "header_size": 12, "cell_size": 13,
		"row_h": 30.0, "alt_rows": true,
		"empty_text": "該当する選手がいません",
		"scroll_key": "main", "scroll": _scroll, "scroll_zones": _scroll_zones,
		"sel_kind": "player", "hits": _row_hits,
	}
	_draw_data_table(TABLE_RECT, draw_cols, _rows, opts)
	_build_table_header_hits(_header_hits, TABLE_RECT, draw_cols, opts)

	_text("選手名を右クリックで選手詳細へ",
		Vector2(TABLE_RECT.position.x + 160.0, TABLE_RECT.position.y + 34.0), 11, FAINT, 420.0)
	_text_right("全%d人" % _rows.size(), TABLE_RECT.end.x - 18.0, TABLE_RECT.position.y + 34.0, 12, MUTED, 200.0)


# --- サブヘッダ (成績ビューの絞り込み + 球団プルダウン) ---

func _draw_stats_subheader() -> void:
	if _sep_x > 0.0:
		_line(Vector2(_sep_x, CHIP_Y - 2.0), Vector2(_sep_x, CHIP_Y + 30.0), BORDER, 1.0)

	# 球団プルダウン (右寄せ)。透明 nav ボタンがこの領域でクリックを拾う。
	var dx: float = 1648.0
	_text("表示", Vector2(dx, CHIP_Y + 6.0), 11, FAINT)
	var nx: float = dx + 34.0
	if _view_team_id != ALL_TEAMS_ID:
		# 専用球団は GameDb.teams に居ないので get_any_team で引く。
		var team: PSTeam = GameDb.get_any_team(_view_team_id)
		if team != null:
			_team_badge(Rect2(dx + 34.0, CHIP_Y + 1.0, 26, 26), team)
			nx = dx + 70.0
	var view_name: String = "全球団" if _view_team_id == ALL_TEAMS_ID else _team_name(_view_team_id)
	_text(view_name, Vector2(nx, CHIP_Y + 22.0), 17, TEXT)
	_text("▼", Vector2(nx + _measure(view_name, 17) + 8.0, CHIP_Y + 19.0), 12, MUTED)


func _team_hotspot_rect() -> Rect2:
	return Rect2(1640.0, CHIP_Y - 2.0, 258.0, 34.0)


# ============================================================ columns

# 地区順位表。**「差」「残」は置かない** — 地区で試合数が揃わずゲーム差が意味を持たないため。
func _district_columns() -> Array:
	return [
		{"title": "順",   "key": "rank", "w": 36,  "align": "l", "fmt": "rank"},
		{"title": "球団", "key": "team", "w": 300, "align": "l", "fmt": "team", "strong": true},
		{"title": "試合", "key": "g",    "w": 56,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "勝",   "key": "w",    "w": 50,  "align": "r", "fmt": "int"},
		{"title": "敗",   "key": "l",    "w": 50,  "align": "r", "fmt": "int"},
		{"title": "分",   "key": "d",    "w": 46,  "align": "r", "fmt": "int"},
		{"title": "勝率", "key": "pct",  "w": 70,  "align": "r", "fmt": "rate", "sep_before": true},
		{"title": "得",   "key": "rs",   "w": 56,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "失",   "key": "ra",   "w": 56,  "align": "r", "fmt": "int"},
		{"title": "得失", "key": "diff", "w": 64,  "align": "r", "fmt": "diff"},
		{"title": "打率", "key": "avg",  "w": 70,  "align": "r", "fmt": "rate", "sep_before": true},
		{"title": "本",   "key": "hr",   "w": 48,  "align": "r", "fmt": "int"},
		{"title": "盗",   "key": "sb",   "w": 48,  "align": "r", "fmt": "int"},
		{"title": "防",   "key": "era",  "w": 64,  "align": "r", "fmt": "float2", "sep_before": true},
		{"title": "WHIP", "key": "whip", "w": 70,  "align": "r", "fmt": "float2"},
		{"title": "K/9",  "key": "k9",   "w": 62,  "align": "r", "fmt": "float2"},
		{"title": "S",    "key": "sv",   "w": 44,  "align": "r", "fmt": "int"},
		{"title": "H",    "key": "hld",  "w": 44,  "align": "r", "fmt": "int"},
	]


# 成績ビューの列。高度指標も必ず farm_advanced_stats から読み、一軍成績とは混ぜない。
func _stat_columns() -> Array:
	var cols: Array = [
		{"title": "球団", "key": "team", "w": 56, "align": "l", "fmt": "team"},
		{"title": "選手", "key": "name", "w": 132, "align": "l", "fmt": "str", "strong": true},
	]
	if _current_mode() == "pitcher":
		cols.append({"title": "役", "key": "role", "w": 40, "align": "c", "fmt": "pos_badge", "sort_key": "role_sort"})
		cols.append({"title": "年齢", "key": "age", "w": 44, "align": "c", "fmt": "int"})
		cols.append_array([
			{"title": "登板", "key": "g", "w": 46, "align": "r", "fmt": "int", "sep_before": true},
			{"title": "先発", "key": "gs", "w": 46, "align": "r", "fmt": "int"},
			{"title": "完投", "key": "cg", "w": 46, "align": "r", "fmt": "int"},
			{"title": "勝", "key": "w", "w": 38, "align": "r", "fmt": "int"},
			{"title": "敗", "key": "l", "w": 38, "align": "r", "fmt": "int"},
			{"title": "H", "key": "hld", "w": 38, "align": "r", "fmt": "int"},
			{"title": "S", "key": "sv", "w": 38, "align": "r", "fmt": "int"},
			{"title": "QS", "key": "qs", "w": 42, "align": "r", "fmt": "int"},
			{"title": "投球回", "key": "ip", "w": 64, "align": "r", "fmt": "f1", "sep_before": true},
			{"title": "防御率", "key": "era", "w": 62, "align": "r", "fmt": "f2"},
			{"title": "WHIP", "key": "whip", "w": 60, "align": "r", "fmt": "f2"},
			{"title": "K/9", "key": "k9", "w": 56, "align": "r", "fmt": "f2"},
			{"title": "wOBAA", "key": "wobaa", "w": 64, "align": "r", "fmt": "rate"},
			{"title": "xwOBAA", "key": "xwobaa", "w": 68, "align": "r", "fmt": "rate"},
			{"title": "RE24A", "key": "re24a", "w": 62, "align": "r", "fmt": "f1s"},
			{"title": "奪三振", "key": "so", "w": 58, "align": "r", "fmt": "int", "sep_before": true},
			{"title": "与四球", "key": "bb", "w": 58, "align": "r", "fmt": "int"},
			{"title": "与死球", "key": "hbp", "w": 58, "align": "r", "fmt": "int"},
			{"title": "被安打", "key": "h", "w": 58, "align": "r", "fmt": "int"},
			{"title": "被本", "key": "hra", "w": 48, "align": "r", "fmt": "int"},
			{"title": "失点", "key": "ra", "w": 48, "align": "r", "fmt": "int"},
			{"title": "自責", "key": "er", "w": 48, "align": "r", "fmt": "int"},
		])
		return cols
	cols.append({"title": "守", "key": "pos", "w": 40, "align": "c", "fmt": "pos_badge", "sort_key": "pos_sort"})
	cols.append({"title": "年齢", "key": "age", "w": 44, "align": "c", "fmt": "int"})
	cols.append_array([
		{"title": "試合", "key": "g", "w": 44, "align": "r", "fmt": "int", "sep_before": true},
		{"title": "打席", "key": "pa", "w": 46, "align": "r", "fmt": "int"},
		{"title": "打数", "key": "ab", "w": 44, "align": "r", "fmt": "int"},
		{"title": "得点", "key": "r", "w": 44, "align": "r", "fmt": "int"},
		{"title": "安打", "key": "h", "w": 44, "align": "r", "fmt": "int"},
		{"title": "二塁", "key": "d", "w": 42, "align": "r", "fmt": "int"},
		{"title": "三塁", "key": "t", "w": 42, "align": "r", "fmt": "int"},
		{"title": "本", "key": "hr", "w": 38, "align": "r", "fmt": "int"},
		{"title": "打点", "key": "rbi", "w": 44, "align": "r", "fmt": "int"},
		{"title": "盗塁", "key": "sb", "w": 44, "align": "r", "fmt": "int"},
		{"title": "打率", "key": "avg", "w": 54, "align": "r", "fmt": "rate", "sep_before": true},
		{"title": "出塁", "key": "obp", "w": 54, "align": "r", "fmt": "rate"},
		{"title": "長打", "key": "slg", "w": 54, "align": "r", "fmt": "rate"},
		{"title": "OPS", "key": "ops", "w": 54, "align": "r", "fmt": "rate"},
		{"title": "四球", "key": "bb", "w": 44, "align": "r", "fmt": "int", "sep_before": true},
		{"title": "死球", "key": "hbp", "w": 44, "align": "r", "fmt": "int"},
		{"title": "三振", "key": "so", "w": 44, "align": "r", "fmt": "int"},
		{"title": "wOBA", "key": "woba", "w": 60, "align": "r", "fmt": "rate", "sep_before": true},
		{"title": "xwOBA", "key": "xwoba", "w": 64, "align": "r", "fmt": "rate"},
		{"title": "wRAA", "key": "wraa", "w": 60, "align": "r", "fmt": "f1s"},
		{"title": "BSR", "key": "bsr", "w": 54, "align": "r", "fmt": "f1s"},
		{"title": "OAA", "key": "oaa", "w": 54, "align": "r", "fmt": "f1s", "sep_before": true},
		{"title": "UZR", "key": "uzr", "w": 54, "align": "r", "fmt": "f1s"},
	])
	return cols


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	_team_menu_button = null
	var season: PSSeason = AppState.current_season
	if season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# ビュー切替 (順位 / 成績)。画面内の一次ナビなので行の左端に置く。
	var x: float = INNER_L
	for view_value in VIEWS:
		var view: Dictionary = view_value as Dictionary
		var vid: String = str(view["id"])
		_add_button("view_%s" % vid, str(view["label"]), Rect2(x, CHIP_Y, VIEW_CHIP_W, 30.0),
			func(target: String = vid) -> void: _on_view_pressed(target), "chip_active" if vid == _view else "chip")
		x += VIEW_CHIP_W + 8.0

	_sep_x = 0.0
	if _view == VIEW_STATS:
		# 絞り込みチップ (投手群 ‖ 野手群) + 規定到達トグル + 球団プルダウン。
		_sep_x = x + 8.0
		x += 26.0
		for filter_value in FILTERS:
			var filter: Dictionary = filter_value as Dictionary
			var fid: String = str(filter["id"])
			if fid == "b_all":
				x += 14.0
			var label: String = str(filter["label"])
			var w: float = 38.0 if label.length() <= 1 else 52.0
			_add_button("flt_%s" % fid, label, Rect2(x, CHIP_Y, w, 30.0),
				func(target: String = fid) -> void: _on_filter_pressed(target), "chip_active" if fid == _filter_id else "chip")
			x += w + 8.0
		x += 14.0
		var qual_label: String = "規定到達のみ"
		_add_button("flt_qualified", qual_label, Rect2(x, CHIP_Y, _measure(qual_label, 13) + 24.0, 30.0),
			func() -> void: _on_qualified_toggle(), "chip_active" if _qualified_only else "chip")
		_team_menu_button = _add_button("team_menu", "", _team_hotspot_rect(), _on_team_menu_pressed, "nav")

	_layout_buttons()


func _on_view_pressed(view_id: String) -> void:
	if _view == view_id:
		return
	_view = view_id
	_refresh()
	_build_buttons()
	queue_redraw()


func _on_filter_pressed(filter_id: String) -> void:
	if _filter_id == filter_id:
		return
	_filter_id = filter_id
	_reset_sort()
	_refresh()
	_build_buttons()
	queue_redraw()


# 列セット (投手/野手) は変わらず母集団だけが変わるので、ソートはリセットせずそのまま集計し直す。
func _on_qualified_toggle() -> void:
	_qualified_only = not _qualified_only
	_refresh()
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


func _on_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	menu.add_item("全球団", ALL_TEAMS_MENU_ID)
	for i in range(_team_ids.size()):
		var team: PSTeam = GameDb.get_any_team(int(_team_ids[i]))
		if team == null:
			continue
		if i == 0:
			menu.add_separator(_team_group_label(team))
		else:
			var prev: PSTeam = GameDb.get_any_team(int(_team_ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(_team_group_label(team))
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
		MOUSE_BUTTON_RIGHT:
			# 選手名の項目を右クリックすると選手詳細へ (ability_stats と同じ流儀)。
			var row: Dictionary = _row_at(base_pos)
			if not row.is_empty() and _is_in_name_column(base_pos):
				AppState.show_player_detail(int(row.get("meta", 0)))
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


# base_pos が「選手」列の x 範囲内か (右クリックでの選手詳細遷移用)。
func _is_in_name_column(base_pos: Vector2) -> bool:
	for hit_value in _header_hits:
		var hit: Dictionary = hit_value as Dictionary
		if str(hit.get("key", "")) == "name":
			var r: Rect2 = hit["rect"] as Rect2
			return base_pos.x >= r.position.x and base_pos.x <= r.position.x + r.size.x
	return false


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

# 二軍参加球団の並び (一軍12球団をリーグ順 → ファーム専用2球団)。
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
	for club_row in GameDb.farm_clubs:
		var club: PSTeam = club_row as PSTeam
		if club != null and not _team_ids.has(club.id):
			_team_ids.append(club.id)


func _refresh() -> void:
	_status_text = ""
	_rows_by_district = {}
	_summary_cells = []
	_filtered = []
	_rows = []

	var season: PSSeason = AppState.current_season
	if season == null:
		return

	_status_text = "%d年 / %d年目  %s  (二軍 残り%d試合)" % [
		season.year, season.season_number,
		SeasonCalendar.day_status_label(season, season.current_day), season.farm_games_remaining(),
	]

	if _view == VIEW_STATS:
		_collect_records(season)
		_build_stat_rows()
		_sort_rows()
		_scroll["main"] = 0
	else:
		_build_district_rows(season)


# --- 順位ビュー ---

# 地区別の順位と、リーグ全体の集計帯を作る。**順位は勝率降順** — 地区ごとに試合数が違ううえ、
# 中止試合の再試合も行わないのでゲーム差では並べられない。
func _build_district_rows(season: PSSeason) -> void:
	for district in PSFarmLeague.DISTRICT_ORDER:
		_rows_by_district[district] = []
	if season.farm_standings.is_empty():
		return

	var league_batter: PSBatterStats = PSBatterStats.new()
	var league_pitcher: PSPitcherStats = PSPitcherStats.new()
	var entries_by_district: Dictionary = {}
	for team_id_value in season.farm_standings.keys():
		var team_id: int = int(team_id_value)
		var team: PSTeam = GameDb.get_any_team(team_id)
		if team == null:
			continue
		var totals: Dictionary = _farm_team_totals(team_id, season)
		var batter: PSBatterStats = totals["batter"] as PSBatterStats
		var pitcher: PSPitcherStats = totals["pitcher"] as PSPitcherStats
		league_batter.add_from(batter)
		league_pitcher.add_from(pitcher)
		var district: String = PSFarmLeague.district_for_team(team_id)
		if not entries_by_district.has(district):
			entries_by_district[district] = []
		(entries_by_district[district] as Array).append({
			"team": team,
			"stats": season.farm_standings[team_id_value] as PSStats,
			"batter": batter,
			"pitcher": pitcher,
		})

	var self_id: int = AppState.selected_team_id
	for district in entries_by_district.keys():
		var entries: Array = entries_by_district[district] as Array
		entries.sort_custom(func(a, b) -> bool:
			var sa: PSStats = (a as Dictionary)["stats"] as PSStats
			var sb: PSStats = (b as Dictionary)["stats"] as PSStats
			if is_equal_approx(sa.win_rate(), sb.win_rate()):
				return sa.wins > sb.wins
			return sa.win_rate() > sb.win_rate()
		)
		var rows: Array = []
		var rank: int = 1
		for entry_value in entries:
			var entry: Dictionary = entry_value as Dictionary
			var team: PSTeam = entry["team"] as PSTeam
			var stats: PSStats = entry["stats"] as PSStats
			var bs: PSBatterStats = entry["batter"] as PSBatterStats
			var ps: PSPitcherStats = entry["pitcher"] as PSPitcherStats
			var has_pitch: bool = ps.outs_pitched > 0
			rows.append({
				"rank": rank, "team": team.name, "team_id": team.id, "color": team.color,
				"is_self": team.id == self_id, "is_leader": rank == 1,
				"g": stats.games, "w": stats.wins, "l": stats.losses, "d": stats.draws,
				"pct": stats.win_rate(),
				"rs": stats.runs_scored, "ra": stats.runs_allowed, "diff": stats.runs_scored - stats.runs_allowed,
				"avg": bs.batting_average(), "hr": bs.home_runs, "sb": bs.stolen_bases,
				"era": ps.era() if has_pitch else -1.0,
				"whip": ps.whip() if has_pitch else -1.0,
				"k9": ps.strikeouts_per_nine() if has_pitch else -1.0,
				"sv": ps.saves, "hld": ps.holds,
			})
			rank += 1
		_rows_by_district[district] = rows

	_summary_cells = _build_summary_cells(season, league_batter, league_pitcher)


# 二軍リーグ全体の状況 (消化・引き分け率・成績水準・自軍の地区順位) を _stat_strip のセル配列にする。
func _build_summary_cells(season: PSSeason, batter: PSBatterStats, pitcher: PSPitcherStats) -> Array:
	var played: int = 0
	var cancelled: int = 0
	for game_value in season.farm_schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("played", false)):
			continue
		if bool(game.get("cancelled", false)):
			cancelled += 1
		else:
			played += 1

	var team_games: int = 0
	var draws: int = 0
	for stats_value in season.farm_standings.values():
		var stats: PSStats = stats_value as PSStats
		team_games += stats.games
		draws += stats.draws
	var draw_rate: float = (float(draws) / float(team_games)) if team_games > 0 else 0.0

	var cells: Array = [
		{
			"label": "消化試合",
			"value": "%d / %d" % [played, season.farm_schedule.size()],
			"note": ("中止%d" % cancelled) if cancelled > 0 else "",
			"note_color": AMBER,
		},
		{"label": "引き分け率", "value": "%.1f%%" % (draw_rate * 100.0)},
		{"label": "リーグ打率", "value": _rate_short(batter.batting_average())},
		{"label": "リーグ防御率", "value": ("%.2f" % pitcher.era()) if pitcher.outs_pitched > 0 else "-"},
	]
	var self_id: int = AppState.selected_team_id
	var self_district: String = PSFarmLeague.district_for_team(self_id)
	var self_rank: int = _rank_of(self_district, self_id)
	if self_rank > 0:
		cells.append({
			"label": "自軍 (%s)" % PSFarmLeague.district_label(self_district),
			"value": "%d位" % self_rank,
			"color": BLUE,
		})
	return cells


func _rank_of(district: String, team_id: int) -> int:
	for row_value in _rows_by_district.get(district, []) as Array:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("team_id", 0)) == team_id:
			return int(row.get("rank", 0))
	return 0


# 球団の二軍成績。**farm_* コンテナからのみ**積む (一軍成績と混ぜない)。
func _farm_team_totals(team_id: int, season: PSSeason) -> Dictionary:
	var batter_stats: PSBatterStats = PSBatterStats.new()
	var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter_stats.add_from(record.farm_batter_stats)
		if record.is_pitcher():
			pitcher_stats.add_from(record.farm_pitcher_stats)
	return {"batter": batter_stats, "pitcher": pitcher_stats}


# --- 成績ビュー ---

func _collect_records(season: PSSeason) -> void:
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


func _build_stat_rows() -> void:
	for record_row in _filtered:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var row: Dictionary = _identity_fields(record)
		if record.is_pitcher():
			row.merge(_pitcher_stat_dict(record.farm_pitcher_stats, record.farm_advanced_stats), true)
		else:
			row.merge(_batter_stat_dict(record.farm_batter_stats, record.farm_advanced_stats), true)
		_rows.append(row)


# 識別フィールド (球団色ドット / 選手名 / 守備位置or役割バッジ / 年齢 / 行メタ)。
func _identity_fields(record: PSPlayerSeasonRecord) -> Dictionary:
	var team: PSTeam = GameDb.get_any_team(record.team_id)
	var row: Dictionary = {
		"team": team.short_name if team != null else "-",
		"color": team.color if team != null else MUTED,
		"name": record.name,
		"age": record.age,
		"__meta": record.player_id,
	}
	if record.is_pitcher():
		var starter: bool = record.is_starter_pitcher()
		row["role"] = "先" if starter else "中"
		row["role_color"] = PINK if starter else RED
		row["role_sort"] = 0 if starter else 1
		row["role_dev"] = record.development_player
	else:
		row["pos"] = str(POS_SHORT.get(record.position, "?"))
		row["pos_color"] = _pos_color(record.position)
		row["pos_sort"] = record.position
		row["pos_dev"] = record.development_player
	return row


func _batter_stat_dict(s: PSBatterStats, ad: PSAdvancedStats = null) -> Dictionary:
	var row: Dictionary = {
		"g": s.games, "pa": s.plate_appearances, "ab": s.at_bats, "r": s.runs, "h": s.hits,
		"d": s.doubles, "t": s.triples, "hr": s.home_runs, "rbi": s.runs_batted_in, "sb": s.stolen_bases,
		"avg": s.batting_average(), "obp": s.on_base_percentage(), "slg": s.slugging_percentage(), "ops": s.ops(),
		"bb": s.walks, "hbp": s.hit_by_pitches, "so": s.strikeouts,
		"sac": s.sacrifices, "sf": s.sacrifice_flies, "gdp": s.double_plays, "err": s.errors,
	}
	var has_pa: bool = ad != null and ad.plate_appearances > 0
	var ad_dict: Dictionary = ad.to_dict() if ad != null else {}
	var has_field: bool = int(ad_dict.get("fielding_chances", 0)) > 0
	row.merge({
		"woba": ad.woba() if has_pa else "-",
		"xwoba": ad.xwoba() if has_pa else "-",
		"wraa": ad.wraa() if has_pa else "-",
		"bsr": ad.bsr_sum if has_pa else "-",
		"oaa": float(ad_dict.get("oaa_total", 0.0)) if has_field else "-",
		"uzr": float(ad_dict.get("uzr", 0.0)) if has_field else "-",
	}, true)
	return row


func _pitcher_stat_dict(s: PSPitcherStats, ad: PSAdvancedStats = null) -> Dictionary:
	var has_ip: bool = s.outs_pitched > 0
	var has_bf: bool = ad != null and ad.plate_appearances > 0
	return {
		"g": s.games, "gs": s.starts, "cg": s.complete_games,
		"w": s.wins, "l": s.losses, "hld": s.holds, "sv": s.saves, "qs": s.quality_starts,
		"ip": s.innings_pitched(),
		"era": s.era() if has_ip else "-",
		"whip": s.whip() if has_ip else "-",
		"k9": s.strikeouts_per_nine() if has_ip else "-",
		"wobaa": ad.woba() if has_bf else "-",
		"xwobaa": ad.xwoba() if has_bf else "-",
		"re24a": ad.re24_sum if has_bf else "-",
		"so": s.strikeouts, "bb": s.walks, "hbp": s.hit_batters, "h": s.hits_allowed,
		"hra": s.home_runs_allowed, "ra": s.runs_allowed, "er": s.earned_runs,
	}


# ============================================================ sort / filter helpers

func _reset_sort() -> void:
	_sort_key = "ip" if _current_mode() == "pitcher" else "pa"
	_sort_asc = false


# 主キー同値時は出場量 (打者は打席数、投手は投球回) の多い方を先に出す (未出場が間に挟まらないように)。
func _sort_rows() -> void:
	var tiebreak_key: String = "ip" if _current_mode() == "pitcher" else "pa"
	_sort_table_rows(_rows, _stat_columns(), _sort_key, _sort_asc, tiebreak_key)


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
			_:
				return true
	if record.is_pitcher():
		return false
	if str(fdef.get("id", "")) == "b_all":
		return true
	return record.position == int(fdef.get("pos", 0))


# 規定打席/規定投球回 = 所属球団の**二軍の**消化試合数 * 係数。
func _is_qualified(record: PSPlayerSeasonRecord) -> bool:
	var team_games: int = _farm_team_games(record)
	if record.is_pitcher():
		var required_outs: int = int(max(1, ceil(QUALIFIER_OUTS_PER_TEAM_GAME * float(team_games))))
		return record.farm_pitcher_stats.outs_pitched >= required_outs
	var required_pa: int = int(max(1, ceil(QUALIFIER_PA_PER_TEAM_GAME * float(team_games))))
	return record.farm_batter_stats.plate_appearances >= required_pa


func _farm_team_games(record: PSPlayerSeasonRecord) -> int:
	var season: PSSeason = AppState.current_season
	if season != null and season.farm_standings.has(record.team_id):
		var stats: PSStats = season.farm_standings[record.team_id] as PSStats
		if stats != null:
			return int(stats.games)
	# アーカイブ側 (過去年) は team record の farm_stats が正。
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(record.team_id, record.year, record.season_number)
	return int(team_record.farm_stats.games) if team_record != null else 0


func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_any_team(team_id)
	return team.name if team != null else "?"


# 球団プルダウンの区切り見出し。専用球団は一軍リーグに属さないので専用の見出しを出す。
func _team_group_label(team: PSTeam) -> String:
	return "ファーム専用球団" if team.farm_only else team.league_label()
