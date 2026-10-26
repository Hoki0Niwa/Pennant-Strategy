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

const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

# 投手能力タブの球種カラム見出しキー (密な表なので短縮名)。完全名は選手詳細で確認できる。
const PITCH_SHORT: Dictionary = {
	"four_seam": "pitch_short.four_seam", "two_seam": "pitch_short.two_seam", "sinker": "pitch_short.sinker",
	"cutter": "pitch_short.cutter", "slider": "pitch_short.slider", "curve": "pitch_short.curve",
	"fork": "pitch_short.fork", "changeup": "pitch_short.changeup",
}

# 絞り込みチップ。mode で投手/野手の列セットが決まる。pos は野手の守備位置。label は表示名のキー (Loc)。
const FILTERS: Array = [
	{"id": "p_all", "label": "common.pitcher", "mode": "pitcher"},
	{"id": "p_sp", "label": "role.starter", "mode": "pitcher"},
	{"id": "p_rp", "label": "role.middle_short", "mode": "pitcher"},
	{"id": "b_all", "label": "common.fielder", "mode": "batter"},
	{"id": "b_2", "label": "position_short.catcher", "mode": "batter", "pos": 2},
	{"id": "b_3", "label": "position_short.first_base", "mode": "batter", "pos": 3},
	{"id": "b_4", "label": "position_short.second_base", "mode": "batter", "pos": 4},
	{"id": "b_5", "label": "position_short.third_base", "mode": "batter", "pos": 5},
	{"id": "b_6", "label": "position_short.shortstop", "mode": "batter", "pos": 6},
	{"id": "b_7", "label": "position_short.left_field", "mode": "batter", "pos": 7},
	{"id": "b_8", "label": "position_short.center_field", "mode": "batter", "pos": 8},
	{"id": "b_9", "label": "position_short.right_field", "mode": "batter", "pos": 9},
]

const TABS: Array = [
	{"id": "abilities", "label": "ability_stats.tab.abilities"},
	{"id": "stats", "label": "farm.view.stats"},
	{"id": "advanced", "label": "ability_stats.tab.advanced"},
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
var _active_ids_cache: Dictionary = {}     # team_id -> {player_id: true}

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
		_text(Loc.t("flow.error.season_not_started"), Vector2(770, 496), 20, MUTED)
		return

	var your_team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	if your_team == null and not GameDb.teams.is_empty():
		your_team = GameDb.teams[0] as PSTeam
	_draw_shell(Loc.t("screen.ability_stats"), your_team, season)

	_draw_subheader()

	var draw_cols: Array = _columns_for_current()
	# header_top はタブ (rect 上端 +14〜+50) と列ヘッダの間に余白を取るため広めに置く。
	var opts: Dictionary = {
		"header_top": 90.0, "inner_pad": 14.0, "header_size": 12, "cell_size": 13,
		"row_h": 30.0, "alt_rows": true, "sort_key": _sort_key, "sort_asc": _sort_asc,
		"empty_text": Loc.t("common.no_matching_players"),
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
	_text(Loc.t("ability_stats.hint"),
		Vector2(TABLE_RECT.position.x + 460.0, TABLE_RECT.position.y + 34.0), 11, FAINT, 660.0)
	var sel_count: int = _selected_ids.size()
	var count_right: float = TABLE_RECT.end.x - 18.0 - (124.0 if sel_count > 0 else 0.0)
	var count_text: String = Loc.t("ability_stats.selected_count", {"n": sel_count, "total": _rows.size()}) if sel_count > 0 else Loc.t("common.total_players", {"n": _rows.size()})
	_text_right(count_text, count_right, TABLE_RECT.position.y + 34.0, 12, BLUE if sel_count > 0 else MUTED, 280.0)


# --- サブヘッダ (絞り込みラベル + 区切り線 + 球団プルダウン + 下端の仕切り) ---
func _draw_subheader() -> void:
	_text(Loc.t("ability_stats.filter_label"), Vector2(INNER_L, CHIP_Y + 20.0), 12, FAINT)
	if _sep_x > 0.0:
		_line(Vector2(_sep_x, CHIP_Y - 2.0), Vector2(_sep_x, CHIP_Y + 30.0), BORDER, 1.0)

	# 球団プルダウン (右寄せ)。透明 nav ボタンがこの領域でクリックを拾う。
	var dx: float = 1648.0
	_text(Loc.t("common.view_label"), Vector2(dx, CHIP_Y + 6.0), 11, FAINT)
	var nx: float = dx + 34.0
	if _view_team_id != ALL_TEAMS_ID:
		var team: PSTeam = GameDb.get_team(_view_team_id)
		if team != null:
			_team_badge(Rect2(dx + 34.0, CHIP_Y + 1.0, 26, 26), team)
			nx = dx + 70.0
	var view_name: String = Loc.t("common.all_teams") if _view_team_id == ALL_TEAMS_ID else _team_name(_view_team_id)
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
	var pitcher: bool = mode == "pitcher"
	# 3 タブとも先頭はプロフィール + 評価で固定し、タブ切替で左端の列が動かないようにする。
	var cols: Array = _identity_columns()
	match _active_tab:
		"abilities":
			cols.append_array(_player_eval_columns(pitcher, true, false))
			if pitcher:
				cols.append_array([
					{"title": "rating.velocity", "key": "velocity", "w": 52, "align": "c", "fmt": "str", "sep_before": true, "group": "group.pitcher_abilities"},
					{"title": "rating.stuff", "key": "stuff", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.pitcher_abilities"},
					{"title": "rating.control", "key": "control", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.pitcher_abilities"},
					{"title": "rating.stamina", "key": "stamina", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.pitcher_abilities"},
				])
				for i in range(_pitch_types.size()):
					var type_value: Variant = _pitch_types[i]
					cols.append({"title": str(PITCH_SHORT.get(str(type_value), str(type_value))), "key": "pitch_%s" % str(type_value), "w": 48, "align": "c", "fmt": "ability_bar", "sep_before": i == 0, "group": "group.pitcher_abilities"})
				cols.append_array([
					{"title": "col.appearances", "key": "g", "w": 42, "align": "r", "fmt": "int", "sep_before": true, "group": "group.key_stats"},
					{"title": "col.innings", "key": "ip", "w": 52, "align": "r", "fmt": "f1", "group": "group.key_stats"},
					{"title": "stat.era", "key": "era", "w": 52, "align": "r", "fmt": "f2", "strong": true, "group": "group.key_stats"},
					{"title": "FIP", "key": "fip", "w": 48, "align": "r", "fmt": "f2", "group": "group.key_stats"},
					{"title": "WAR", "key": "war", "w": 48, "align": "r", "fmt": "f1s", "strong": true, "group": "group.key_stats"},
					{"title": "col.salary_man", "key": "salary", "w": 76, "align": "r", "fmt": "comma", "sep_before": true, "group": "group.contract"},
				])
			else:
				cols.append_array([
					{"title": "rating.contact", "key": "contact", "w": 46, "align": "c", "fmt": "ability_bar", "sep_before": true, "group": "group.fielder_abilities"},
					{"title": "rating.power", "key": "power", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.fielder_abilities"},
					{"title": "rating.speed", "key": "speed", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.fielder_abilities"},
					{"title": "rating.defense", "key": "defense", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.fielder_abilities"},
					{"title": "rating.arm", "key": "arm", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.fielder_abilities"},
					{"title": "rating.discipline", "key": "discipline", "w": 46, "align": "c", "fmt": "ability_bar", "group": "group.fielder_abilities"},
					# 対逆 = 逆の利き腕に対する OPS の上がり幅 (リーグ平均の左右差 = 1.0 / 変動幅は 値×0.05)。
					# どちらの左右が有利側かはプロフィールの打 列で読む。
					{"title": "rating.vs_opposite", "key": "vs_opposite", "w": 46, "align": "c", "fmt": "f1", "group": "group.fielder_abilities"},
				])
				for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
					cols.append({"title": str(PSPlayer.POSITION_SHORT_KEYS[pos]), "key": "apt_%d" % pos, "w": 34, "align": "c", "fmt": "ability_bar", "sep_before": pos == 2, "group": "group.aptitudes"})
				cols.append_array([
					{"title": "col.avg", "key": "avg", "w": 50, "align": "r", "fmt": "rate", "sep_before": true, "strong": true, "group": "group.key_stats"},
					{"title": "col.hr", "key": "hr", "w": 36, "align": "r", "fmt": "int", "group": "group.key_stats"},
					{"title": "stat.rbi", "key": "rbi", "w": 40, "align": "r", "fmt": "int", "group": "group.key_stats"},
					{"title": "stat.stolen_bases", "key": "sb", "w": 40, "align": "r", "fmt": "int", "group": "group.key_stats"},
					{"title": "OPS", "key": "ops", "w": 50, "align": "r", "fmt": "rate", "strong": true, "group": "group.key_stats"},
					{"title": "WAR", "key": "war", "w": 48, "align": "r", "fmt": "f1s", "strong": true, "group": "group.key_stats"},
					{"title": "col.salary_man", "key": "salary", "w": 76, "align": "r", "fmt": "comma", "sep_before": true, "group": "group.contract"},
				])
		"advanced":
			cols.append_array(_player_eval_columns(pitcher, false, true))
			if pitcher:
				cols.append_array([
					{"title": "col.innings", "key": "ip", "w": 64, "align": "r", "fmt": "f1", "sep_before": true, "group": "group.adv_workload"},
					{"title": "col.batters_faced", "key": "bf", "w": 72, "align": "r", "fmt": "int", "group": "group.adv_workload"},
					{"title": "col.pitches", "key": "pit", "w": 68, "align": "r", "fmt": "int", "group": "group.adv_workload"},
					{"title": "col.pitches_per_bf", "key": "ppbf", "w": 70, "align": "r", "fmt": "f2", "group": "group.adv_workload"},
					{"title": "col.pitches_per_inning", "key": "ppi", "w": 62, "align": "r", "fmt": "f1", "group": "group.adv_workload"},
					{"title": "role.reliever", "key": "rel", "w": 56, "align": "r", "fmt": "int", "group": "group.adv_workload"},
					{"title": "K/9", "key": "k9", "w": 56, "align": "r", "fmt": "f2", "sep_before": true, "group": "group.adv_rates"},
					{"title": "BB/9", "key": "bb9", "w": 60, "align": "r", "fmt": "f2", "group": "group.adv_rates"},
					{"title": "HR/9", "key": "hr9", "w": 60, "align": "r", "fmt": "f2", "group": "group.adv_rates"},
					{"title": "FIP", "key": "fip", "w": 60, "align": "r", "fmt": "f2", "sep_before": true, "strong": true, "group": "group.adv_value"},
				])
			else:
				cols.append_array([
					{"title": "col.pa", "key": "pa", "w": 52, "align": "r", "fmt": "int", "sep_before": true, "group": "group.adv_pa"},
					{"title": "col.pitches_per_pa", "key": "ppa", "w": 64, "align": "r", "fmt": "f2", "group": "group.adv_pa"},
					{"title": "wOBA", "key": "woba", "w": 60, "align": "r", "fmt": "rate", "sep_before": true, "strong": true, "group": "group.adv_batting"},
					{"title": "xwOBA", "key": "xwoba", "w": 64, "align": "r", "fmt": "rate", "group": "group.adv_batting"},
					{"title": "wRC+", "key": "wrcplus", "w": 58, "align": "r", "fmt": "f1", "strong": true, "group": "group.adv_batting"},
					{"title": "RE24", "key": "re24", "w": 62, "align": "r", "fmt": "f1s", "group": "group.adv_batting"},
					{"title": "BSR", "key": "bsr", "w": 58, "align": "r", "fmt": "f1s", "sep_before": true, "group": "group.adv_baserunning"},
					{"title": "OAA", "key": "oaa", "w": 58, "align": "r", "fmt": "f1s", "sep_before": true, "group": "group.adv_fielding"},
					{"title": "col.oaa_if", "key": "oaa_if", "w": 64, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "col.oaa_of", "key": "oaa_of", "w": 64, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "RngR", "key": "rngr", "w": 60, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "ErrR", "key": "errr", "w": 60, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "DPR", "key": "dpr", "w": 56, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "UZR", "key": "uzr", "w": 58, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
					{"title": "DRS", "key": "drs", "w": 58, "align": "r", "fmt": "f1s", "group": "group.adv_fielding"},
				])
		_:  # stats (成績 = 基本成績 + 率指標)
			cols.append_array(_player_eval_columns(pitcher, false, true))
			if pitcher:
				cols.append_array([
					{"title": "col.appearances", "key": "g", "w": 46, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_app"},
					{"title": "col.games_started", "key": "gs", "w": 46, "align": "r", "fmt": "int", "group": "group.pitching_app"},
					{"title": "col.complete_games", "key": "cg", "w": 46, "align": "r", "fmt": "int", "group": "group.pitching_app"},
					{"title": "col.shutouts", "key": "sho", "w": 46, "align": "r", "fmt": "int", "group": "group.pitching_app"},
					{"title": "col.innings", "key": "ip", "w": 62, "align": "r", "fmt": "f1", "group": "group.pitching_app"},
					{"title": "col.wins", "key": "w", "w": 38, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_dec"},
					{"title": "col.losses", "key": "l", "w": 38, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
					{"title": "H", "key": "hld", "w": 38, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
					{"title": "S", "key": "sv", "w": 38, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
					{"title": "QS", "key": "qs", "w": 42, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
					{"title": "stat.era", "key": "era", "w": 60, "align": "r", "fmt": "f2", "sep_before": true, "strong": true, "group": "group.pitching_rates"},
					{"title": "WHIP", "key": "whip", "w": 58, "align": "r", "fmt": "f2", "group": "group.pitching_rates"},
					{"title": "stat.strikeouts", "key": "so", "w": 58, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_detail"},
					{"title": "col.walks_allowed", "key": "bb", "w": 58, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
					{"title": "col.hbp_allowed", "key": "hbp", "w": 58, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
					{"title": "col.hits_allowed", "key": "h", "w": 58, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
					{"title": "col.hr_allowed", "key": "hra", "w": 48, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
					{"title": "col.runs_allowed_full", "key": "ra", "w": 48, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
					{"title": "col.earned_runs", "key": "er", "w": 48, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
				])
			else:
				cols.append_array([
					{"title": "col.games", "key": "g", "w": 44, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_counting1"},
					{"title": "col.pa", "key": "pa", "w": 46, "align": "r", "fmt": "int", "group": "group.batting_counting1"},
					{"title": "col.ab", "key": "ab", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_counting1"},
					{"title": "col.runs", "key": "r", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_counting1"},
					{"title": "stat.hits", "key": "h", "w": 44, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_counting2"},
					{"title": "col.doubles", "key": "d", "w": 42, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
					{"title": "col.triples", "key": "t", "w": 42, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
					{"title": "col.hr", "key": "hr", "w": 38, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
					{"title": "stat.rbi", "key": "rbi", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
					{"title": "stat.stolen_bases", "key": "sb", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
					{"title": "col.avg", "key": "avg", "w": 54, "align": "r", "fmt": "rate", "sep_before": true, "strong": true, "group": "group.batting_rates"},
					{"title": "col.obp_short", "key": "obp", "w": 54, "align": "r", "fmt": "rate", "group": "group.batting_rates"},
					{"title": "col.slg_short", "key": "slg", "w": 54, "align": "r", "fmt": "rate", "group": "group.batting_rates"},
					{"title": "OPS", "key": "ops", "w": 54, "align": "r", "fmt": "rate", "strong": true, "group": "group.batting_rates"},
					{"title": "col.walks", "key": "bb", "w": 44, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_discipline"},
					{"title": "col.hbp", "key": "hbp", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
					{"title": "col.strikeouts_batter", "key": "so", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
					{"title": "box.pa.sacrifice", "key": "sac", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
					{"title": "box.pa.sacrifice_fly", "key": "sf", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
					{"title": "col.gidp", "key": "gdp", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
					{"title": "stat.errors", "key": "err", "w": 44, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
				])
	return cols


# 全タブ共通の先頭列 (球団 / 守備位置or役割 / 登録 / 選手 / 年齢 / 投or打 / 疲労)。並びは基底の共通プロフィール列。
func _identity_columns() -> Array:
	return _player_profile_columns(_current_mode() == "pitcher")


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	if season == null:
		_add_button("home_empty", Loc.t("common.to_home"), Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
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
		var label: String = Loc.t(str(filter["label"]))
		var w: float = 38.0 if label.length() <= 1 else 52.0
		var active: bool = fid == _filter_id
		_add_button("flt_%s" % fid, label, Rect2(x, CHIP_Y, w, 30.0),
			func(target: String = fid) -> void: _on_filter_pressed(target), "chip_active" if active else "chip")
		x += w + 8.0

	# 規定打席/投球回到達者のみ (絞り込みチップ群の右にトグルとして置く)。
	x += 14.0
	var qual_label: String = Loc.t("common.qualified_only")
	var qual_w: float = _measure(qual_label, 13) + 24.0
	_add_button("flt_qualified", qual_label, Rect2(x, CHIP_Y, qual_w, 30.0),
		func() -> void: _on_qualified_toggle(), "chip_active" if _qualified_only else "chip")

	# タブ (能力値 / 成績 / 高度な指標)。
	var tx: float = TABLE_RECT.position.x + 16.0
	for tab_value in TABS:
		var tab: Dictionary = tab_value as Dictionary
		var tid: String = str(tab["id"])
		var act: bool = tid == _active_tab
		_add_button("tab_%s" % tid, Loc.t(str(tab["label"])), Rect2(tx, TABLE_RECT.position.y + 14.0, 134.0, 36.0),
			func(target: String = tid) -> void: _on_tab_pressed(target), "chip_active" if act else "chip")
		tx += 144.0

	# 選択解除ボタン (選択がある時だけ、テーブル右肩に)。
	if not _selected_ids.is_empty():
		_add_button("clear_sel", Loc.t("ability_stats.clear_selection", {"n": _selected_ids.size()}),
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
	menu.add_item(Loc.t("common.all_teams"), ALL_TEAMS_MENU_ID)
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
	_active_ids_cache = {}
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var mode: String = _current_mode()
	# WAR は 3 タブとも評価列に出すので、どのタブでもリーグ文脈を引く (season ごとにキャッシュ)。
	var ctx: Dictionary = _league_ctx(season.year, season.season_number)
	if _active_tab == "abilities" and mode == "pitcher":
		_pitch_types = _compute_pitch_union()
	for record_row in _filtered:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		match _active_tab:
			"abilities":
				_rows.append(_ability_row(record, ctx))
			"advanced":
				_rows.append(_advanced_row(record, ctx))
			_:
				_rows.append(_stat_row(record, ctx))


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


# 全行共通の識別フィールド (プロフィール列 + 総合評価 + 行メタ)。3 タブで同じ値を出す。
func _identity_fields(record: PSPlayerSeasonRecord) -> Dictionary:
	var team: PSTeam = GameDb.get_team(record.team_id)
	var row: Dictionary = {
		"team": team.short_name if team != null else "-",
		"color": team.color if team != null else MUTED,
		"name": record.name,
		"jersey": record.jersey_number,
		"roster": _roster_status_label(record),
		"age": record.age,
		"throws": _batting_side_short(record.throwing_hand),
		"bats": _batting_side_short(record.batting_side),
		"fatigue": _fatigue_pct(record),
		"overall": PlayerValueEvaluator.overall_score(record),
		"pa": record.batter_stats.plate_appearances,
		"ip": record.pitcher_stats.innings_pitched(),
		"__meta": record.player_id,
	}
	if record.is_pitcher():
		var badge: Dictionary = _role_badge(record.role)
		row["role"] = badge["text"]
		row["role_color"] = badge["color"]
		row["role_sort"] = badge["sort"]
		row["role_dev"] = record.development_player
	else:
		row["pos"] = PSPlayer.position_short_name(record.position)
		row["pos_color"] = _pos_color(record.position)
		row["pos_sort"] = record.position
		row["pos_dev"] = record.development_player
	return row


func _roster_status_label(record: PSPlayerSeasonRecord) -> String:
	if record.development_player:
		return Loc.t("common.development_chip")
	var season: PSSeason = AppState.current_season
	if season == null:
		return Loc.t("roster.first_team")
	if not _active_ids_cache.has(record.team_id):
		var map: Dictionary = {}
		var saved: Dictionary = season.get_active_roster(record.team_id)
		var ids: Array = saved.get("player_ids", []) as Array
		if ids.is_empty():
			var preview: Dictionary = GameSimulator.preview_active_roster(season, record.team_id)
			ids = preview.get("player_ids", []) as Array
		for id_val in ids:
			map[int(id_val)] = true
		_active_ids_cache[record.team_id] = map
	var team_map: Dictionary = _active_ids_cache[record.team_id] as Dictionary
	return Loc.t("roster.first_team") if team_map.has(record.player_id) else Loc.t("roster.second_team")


@warning_ignore("incompatible_ternary")
func _ability_row(record: PSPlayerSeasonRecord, ctx: Dictionary) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	var ratings: Array = PSPlayerVisibleRatings.ratings_for_record(record).get("display_ratings", []) as Array
	for rating_value in ratings:
		var rating: Dictionary = rating_value as Dictionary
		var key: String = str(rating.get("key", ""))
		if rating.has("text"):
			row[key] = snappedf(float(rating.get("value", 0.0)), 0.1) + 0.0
			continue
		var value: int = int(rating.get("display_value", rating.get("value", 0)))
		row[key] = value
	row["salary"] = record.salary
	var war: Dictionary = WarCalculator.season_war(record, ctx)
	if record.is_pitcher():
		var def_eval: int = PlayerValueEvaluator.defensive_score_for_position(record, 1)
		row["def_eval"] = def_eval
		var mastery_by_type: Dictionary = {}
		for entry_value in record.arsenal_or_derived():
			var entry: Dictionary = entry_value as Dictionary
			mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
		for type_value in _pitch_types:
			var type_key: String = str(type_value)
			if mastery_by_type.has(type_key):
				var display_value: int = PSAbilityScale.z_to_display(float(mastery_by_type[type_key]))
				row["pitch_%s" % type_key] = display_value
			else:
				row["pitch_%s" % type_key] = "-"
		var ps: PSPitcherStats = record.pitcher_stats
		var has_ip: bool = ps.outs_pitched > 0
		row["g"] = ps.games
		row["ip"] = ps.innings_pitched()
		row["era"] = ps.era() if has_ip else "-"
		row["fip"] = float(war.get("fip", 0.0)) if has_ip else "-"
		row["war"] = float(war.get("war", 0.0)) if has_ip else "-"
	else:
		var bat_eval: int = PlayerValueEvaluator.batting_score_without_fatigue(record)
		row["bat_eval"] = bat_eval
		if record.position >= 2 and record.position <= 9:
			var def_eval2: int = PlayerValueEvaluator.defensive_score_for_position(record, record.position)
			row["def_eval"] = def_eval2
		else:
			row["def_eval"] = "-"
		for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
			var apt: int = _position_aptitude(record, pos)
			if apt > 0:
				row["apt_%d" % pos] = apt
			else:
				row["apt_%d" % pos] = "-"
		var bs: PSBatterStats = record.batter_stats
		var ad: PSAdvancedStats = record.advanced_stats
		var has_pa: bool = ad != null and ad.plate_appearances > 0
		row["pa"] = bs.plate_appearances
		row["avg"] = bs.batting_average() if bs.at_bats > 0 else "-"
		row["hr"] = bs.home_runs
		row["rbi"] = bs.runs_batted_in
		row["sb"] = bs.stolen_bases
		row["ops"] = bs.ops() if has_pa else "-"
		row["wrcplus"] = float(war.get("wrc_plus", 0.0)) if has_pa else "-"
		row["war"] = float(war.get("war", 0.0)) if has_pa else "-"
	return row


@warning_ignore("incompatible_ternary")
func _stat_row(record: PSPlayerSeasonRecord, ctx: Dictionary) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	var war: Dictionary = WarCalculator.season_war(record, ctx)
	if record.is_pitcher():
		row.merge(_pitcher_basic_dict(record), true)
		row["war"] = float(war.get("war", 0.0)) if record.pitcher_stats.outs_pitched > 0 else "-"
	else:
		row.merge(_batter_basic_dict(record), true)
		row["war"] = float(war.get("war", 0.0)) if record.batter_stats.plate_appearances > 0 else "-"
	return row


func _advanced_row(record: PSPlayerSeasonRecord, ctx: Dictionary) -> Dictionary:
	var row: Dictionary = _identity_fields(record)
	var war: Dictionary = WarCalculator.season_war(record, ctx)
	if record.is_pitcher():
		row.merge(_pitcher_advanced_dict(record, war), true)
	else:
		row.merge(_batter_advanced_dict(record, war), true)
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
		@warning_ignore("incompatible_ternary")
		return float(ad_dict.get(key, 0.0)) if has_field else "-"
	@warning_ignore("incompatible_ternary")
	return {
		"pa": ad.plate_appearances if ad != null else 0,
		"ppa": (float(bs.pitches_seen) / float(bs.plate_appearances)) if bs.plate_appearances > 0 else "-",
		"woba": ad.woba() if has_pa else "-",
		"xwoba": ad.xwoba() if has_pa else "-",
		"wrcplus": float(war.get("wrc_plus", 0.0)) if has_pa else "-",
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
	@warning_ignore("incompatible_ternary")
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
		return {"text": Loc.t("role.starter_short"), "color": PINK, "sort": 0}
	return {"text": Loc.t("role.middle_char"), "color": RED, "sort": 1}


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


# 打席左右の 1 文字表示。対逆がどちらの利き腕を見た値かを読むための添え字。
func _batting_side_short(batting_side: String) -> String:
	match batting_side.to_upper():
		PSPlatoonMatchup.HAND_RIGHT:
			return Loc.t("hand.right")
		PSPlatoonMatchup.HAND_LEFT:
			return Loc.t("hand.left")
		PSPlatoonMatchup.HAND_SWITCH:
			return Loc.t("hand.switch")
	return "-"
