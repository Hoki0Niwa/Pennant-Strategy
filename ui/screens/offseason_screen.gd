extends "res://ui/components/dashboard_screen.gd"

# オフシーズン画面。AppState の offseason_step と各 state 辞書を読み、
# 戦力外、ドラフト、戦力外獲得、FA、外国人、キャンプ、成長、契約更新を1画面内で切り替える。
# テーブル行は _row_hits に矩形を記録して _gui_input で選択し、操作ボタンは dashboard_screen の
# オーバーレイボタンとして生成する。ゲーム状態の更新は AppState/各 season service に委譲する。

const CampServiceRef = preload("res://services/season/camp_service.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

# ---------------------------------------------------------------------------
# 列定義 ({title, key, w, fmt, align})。描画は基底 _draw_data_table が w / fmt / align を参照する。
# ---------------------------------------------------------------------------

# ドラフト候補表のタブ。投手/野手に加え、先発・中継・各守備位置で絞り込む
# (戦力外選択と同じタブ切り替え)。pos2..pos9 は守備位置 (本職 or 守備適性 > 0)。
const DRAFT_TABS: Array = [
	{"id": "pitcher", "label": "投手"},
	{"id": "starter", "label": "先発"},
	{"id": "reliever", "label": "中継"},
	{"id": "fielder", "label": "野手"},
	{"id": "pos2", "label": "捕"},
	{"id": "pos3", "label": "一"},
	{"id": "pos4", "label": "二"},
	{"id": "pos5", "label": "三"},
	{"id": "pos6", "label": "遊"},
	{"id": "pos7", "label": "左"},
	{"id": "pos8", "label": "中"},
	{"id": "pos9", "label": "右"},
]

const PICK_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "w": 72, "fmt": "team", "align": "left"},
	{"title": "巡", "key": "round", "w": 48, "fmt": "string"},
	{"title": "選手", "key": "name", "w": 110, "fmt": "string", "strong": true},
	{"title": "守備", "key": "pos", "w": 52, "fmt": "pos_badge"},
	{"title": "年齢", "key": "age", "w": 56, "fmt": "int"},
	{"title": "出身", "key": "source", "w": 60, "fmt": "string", "sep_before": true},
	{"title": "総合", "key": "overall", "w": 52, "fmt": "int"},
	{"title": "競合", "key": "note", "w": 52, "fmt": "string"},
]

const LOTTERY_COLUMNS: Array = [
	{"title": "回", "key": "wave", "w": 40, "fmt": "int"},
	{"title": "選手", "key": "name", "w": 120, "fmt": "string", "strong": true},
	{"title": "競合", "key": "teams", "w": 200, "fmt": "string"},
	{"title": "当選", "key": "team", "w": 84, "fmt": "team", "align": "left", "sep_before": true},
]

const ROOKIE_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "w": 72, "fmt": "string"},
	{"title": "選手", "key": "name", "w": 120, "fmt": "string", "strong": true},
	{"title": "年齢", "key": "age", "w": 56, "fmt": "int"},
	{"title": "守備", "key": "pos", "w": 84, "fmt": "pos_badge"},
	{"title": "総合", "key": "overall", "w": 56, "fmt": "int", "sep_before": true},
]

const CAMP_PITCH_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "w": 72, "fmt": "team", "align": "left"},
	{"title": "選手", "key": "name", "w": 120, "fmt": "string", "strong": true},
	{"title": "年齢", "key": "age", "w": 60, "fmt": "int"},
	{"title": "習得球種", "key": "pitch", "w": 110, "fmt": "string", "sep_before": true},
	{"title": "完成度", "key": "grade", "w": 64, "fmt": "string"},
	{"title": "総合", "key": "overall_cell", "w": 60, "fmt": "growth", "sep_before": true},
	{"title": "球速", "key": "velocity", "w": 92, "fmt": "growth"},
	{"title": "球質", "key": "stuff", "w": 50, "fmt": "growth"},
	{"title": "制球", "key": "control", "w": 50, "fmt": "growth"},
	{"title": "持久", "key": "stamina", "w": 72, "fmt": "growth"},
]

# 基本能力(growth 書式=値+増減色分け)の列。成長 / キャンプ結果で共用。
func _ability_columns(pitcher: bool, compact: bool = false) -> Array:
	var cols: Array = []
	if pitcher:
		_append_growth_column(cols, "球速", "velocity", 74 if compact else 78, 30)
		_append_growth_column(cols, "球質", "stuff", 44 if compact else 48, 28)
		_append_growth_column(cols, "制球", "control", 44 if compact else 48, 28)
		_append_growth_column(cols, "持久", "stamina", 56 if compact else 62, 28)
	else:
		var value_w: int = 44 if compact else 48
		_append_growth_column(cols, "巧打", "contact", value_w, 28)
		_append_growth_column(cols, "長打", "power", value_w, 28)
		_append_growth_column(cols, "走力", "speed", value_w, 28)
		_append_growth_column(cols, "守備", "defense", value_w, 28)
		_append_growth_column(cols, "肩力", "arm", value_w, 28)
		_append_growth_column(cols, "選球", "discipline", value_w, 28)
	return cols


func _growth_detail_columns(pitcher: bool, compact: bool = false) -> Array:
	var cols: Array = []
	if pitcher:
		for i in range(PSPitchTypes.ALL_TYPES.size()):
			var pitch_type: String = str(PSPitchTypes.ALL_TYPES[i])
			_append_growth_column(cols, PSPitchTypes.display_name(pitch_type), "pitch_%d" % i, 36 if compact else 38, 24)
	else:
		for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
			_append_growth_column(cols, _position_char(pos), "apt_%d" % pos, 30 if compact else 32, 24)
	return cols


func _append_growth_column(cols: Array, title: String, key: String, value_w: int, delta_w: int) -> void:
	cols.append({"title": title, "key": key, "w": value_w + delta_w, "fmt": "growth", "delta_w": delta_w})


# 選手の成長 結果の列 (選手/年齢/結果 + 能力)。
func _growth_columns(pitcher: bool) -> Array:
	var cols: Array = [
		{"title": "守備", "key": "pos", "w": 46, "fmt": "pos_badge"},
		{"title": "選手", "key": "name", "w": 128, "fmt": "string", "strong": true},
		{"title": "年齢", "key": "age", "w": 76, "fmt": "int", "gap_after": 24},
		{"title": "結果", "key": "kind", "w": 104, "fmt": "string", "align": "right", "sep_before": true},
	]
	_append_growth_column(cols, "総合", "overall_cell", 58, 30)
	(cols.back() as Dictionary)["sep_before"] = true
	cols.append_array(_ability_columns(pitcher))
	cols.append_array(_growth_detail_columns(pitcher))
	return cols


# キャンプ結果の列 (球団/選手/練習/成否/変化 + 成長と同じ能力)。
func _camp_result_columns(pitcher: bool) -> Array:
	var cols: Array = [
		{"title": "球団", "key": "team", "w": 64, "fmt": "team", "align": "left"},
		{"title": "選手", "key": "name", "w": 118, "fmt": "string", "strong": true},
		{"title": "年齢", "key": "age", "w": 66, "fmt": "int", "gap_after": 20},
		{"title": "練習", "key": "training", "w": 104, "fmt": "string", "sep_before": true},
		{"title": "成否", "key": "result", "w": 52, "fmt": "string"},
		{"title": "変更前", "key": "before_state", "w": 64, "fmt": "pos_badge"},
		{"title": "変更後", "key": "after_state", "w": 64, "fmt": "pos_badge"},
	]
	_append_growth_column(cols, "総合", "overall_cell", 54, 28)
	(cols.back() as Dictionary)["sep_before"] = true
	cols.append_array(_ability_columns(pitcher, true))
	cols.append_array(_growth_detail_columns(pitcher, true))
	return cols

const DRAFT_RESULT_COLUMNS: Array = [
	{"title": "巡", "key": "round", "w": 36, "fmt": "string"},
	{"title": "選手", "key": "name", "w": 96, "fmt": "string", "strong": true},
	{"title": "守備", "key": "pos", "w": 46, "fmt": "pos_badge"},
	{"title": "年", "key": "age", "w": 42, "fmt": "int"},
	{"title": "総", "key": "overall", "w": 38, "fmt": "int", "sep_before": true},
]

# ドラフト進行中の表示切替チップ (指名画面=候補ボード+指名履歴/抽選、途中経過=結果画面風の全面ビュー)。
const DRAFT_HISTORY_MODES: Array = [
	{"id": "timeline", "label": "指名画面"},
	{"id": "by_team", "label": "途中経過"},
]

const POSITION_CHARS: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "指",
}

const FOREIGN_POSITION_OPTIONS: Array = [
	{"id": "any", "label": "おまかせ"}, {"id": "starter", "label": "先発"}, {"id": "reliever", "label": "救援"},
	{"id": "catcher", "label": "捕手"}, {"id": "first", "label": "一塁"}, {"id": "second", "label": "二塁"},
	{"id": "third", "label": "三塁"}, {"id": "shortstop", "label": "遊撃"}, {"id": "outfield", "label": "外野"}, {"id": "dh", "label": "DH"},
]
const FOREIGN_FIELDER_TYPES: Array = [
	{"id": "balanced", "label": "バランス"}, {"id": "power", "label": "パワー"}, {"id": "contact", "label": "巧打"},
	{"id": "discipline", "label": "選球眼"}, {"id": "speed_defense", "label": "走守"}, {"id": "defense", "label": "守備"},
]
const FOREIGN_PITCHER_TYPES: Array = [
	{"id": "balanced", "label": "バランス"}, {"id": "strikeout", "label": "奪三振"}, {"id": "control", "label": "制球"},
	{"id": "groundball", "label": "ゴロ"}, {"id": "stamina", "label": "持久力"},
]
const FOREIGN_BUDGET_OPTIONS: Array = [
	{"id": "bargain", "label": "格安 0.3〜0.6億・4名"}, {"id": "standard", "label": "標準 0.6〜1.2億・3名"},
	{"id": "core", "label": "主力 1.2〜2億・2名"}, {"id": "star", "label": "大物 2〜4億・1名"},
]

# --- レイアウト基準 (base 座標) ---
# 上から: ヘッダ(0..86) → ステップchip/status(y92) → ロスターサマリーパネル(SUMMARY) → 操作ボタン行(ACTION_Y) → 本文(BODY)。
const SUMMARY: Rect2 = Rect2(262, 122, 1638, 76)
const ACTION_Y: float = 208.0
const BODY: Rect2 = Rect2(262, 256, 1638, 804)
# 外国人契約市場: 上段=自軍の契約切れ (最大4人・1表) / 下段=他球団の契約切れ (投手/野手タブ)。
const FGC_HOME_RECT: Rect2 = Rect2(262, 284, 1638, 196)
const FGC_AWAY_RECT: Rect2 = Rect2(262, 492, 1638, 568)
# 契約年数: ステータス行のぶんだけ BODY を下げた1表。
const CY_BODY_RECT: Rect2 = Rect2(262, 284, 1638, 776)
# キャンプ: 上段=候補ボード(全幅) / 下段=特別練習メニュー・成功率・成功時獲得適性の3パネル。
const CAMP_BOARD: Rect2 = Rect2(262, 324, 1638, 512)
const CAMP_MENU: Rect2 = Rect2(262, 850, 654, 210)
const CAMP_RATE: Rect2 = Rect2(932, 850, 476, 210)
const CAMP_APT: Rect2 = Rect2(1424, 850, 476, 210)
# 予算改定サマリー (_draw_budget_recompute_summary、引退結果=step_0のみ) が BODY 上部に占める高さ。
# 投手/野手タブ (_build_result_people_tabs) をこの分だけ下へ逃がして重なりを防ぐ。
const BUDGET_SUMMARY_BLOCK_H: float = 66.0

# 行ハイライト/選択強調用の補助色。
const SEL_RELEASE: Color = Color(0.95, 0.6, 0.55)
const SEL_DEMOTE: Color = Color(0.6, 0.85, 0.65)
const CLOSER_RED: Color = Color(0.92, 0.24, 0.30)

const PLAYER_TAB_PITCHER: String = "pitcher"
const PLAYER_TAB_FIELDER: String = "fielder"

# ---------------------------------------------------------------------------
# 状態
# ---------------------------------------------------------------------------

var _view: Dictionary = {}
var _active_panel: String = "none"
var _status_text: String = ""
var _status_color: Color = MUTED

var _row_hits: Array = []          # [{rect, kind, meta}] base 座標の行当たり判定
var _scroll_zones: Array = []      # [{rect, key, max}] ホイールスクロール領域
var _scroll: Dictionary = {}       # key -> 先頭行オフセット
# 全ステップ共通の自軍ロスターサマリー (支配下/育成/外国人/ポジション別)。_refresh で1回計算。
var _roster_summary: Dictionary = {}

# 戦力外通告 (step1)
var team_roster_records: Array = []
var _release_pitcher_records: Array = []
var _release_fielder_records: Array = []
var _release_tab: String = PLAYER_TAB_PITCHER
var _result_people_tab: String = PLAYER_TAB_PITCHER
var selected_release_ids: Dictionary = {}
var selected_demote_ids: Dictionary = {}
var last_release_meta: int = 0
var release_war_by_id: Dictionary = {}
var _release_confirm_dialog: ConfirmationDialog = null
var _release_rows: Array = []
var _release_summary_text: String = ""
# 契約市場対象として戦力外編集の一覧から除外した自軍外国人の人数 (サマリー表示用)。
var _release_foreign_count: int = 0

# ドラフト (step3,4)
var selected_draft_candidate_id: int = 0
var _draft_tab: String = "pitcher"
var _draft_candidate_rows: Array = []   # [{candidate_id, candidate, name, is_pitcher, role, position, aptitudes, arsenal, ...}]
var _draft_record_cache: Dictionary = {} # candidate_id -> PSPlayerSeasonRecord (レーティング算出用に遅延生成)
var _draft_pick_rows: Array = []
var _draft_lottery_rows: Array = []
var _draft_status_text: String = ""
var _draft_submit_label: String = "指名する"
var _draft_show_skip: bool = false
var _draft_skip_label: String = "本指名終了"
var _draft_cand_by_id: Dictionary = {}
# 1巡目入札の対話フロー: ""=通常表示 / "reveal"=入札公開 / "result"=抽選結果。
var _draft_reveal_stage: String = ""
# 1巡目パネルの球団別カード (12球団=4列×3行、並び順は _draft_reveal_card_order)。
var _draft_reveal_cards: Array = []
var _draft_reveal_go_label: String = "抽選へ"
# 進行中パネルの表示切替: "timeline"=指名画面 (候補ボード+指名履歴/抽選) / "by_team"=途中経過ビュー。
var _draft_history_mode: String = "timeline"

# 戦力外獲得市場 (step5)
var selected_released_candidate_id: int = 0
var _released_rows: Array = []
var _released_player_rows: Array = []
var _released_tab: String = PLAYER_TAB_PITCHER
var _released_by_id: Dictionary = {}
var _released_status_text: String = ""
var _released_can_submit: bool = false
var _released_can_auto: bool = false

# 現役ドラフト。提出フェーズは自軍適格選手の複数選択トグル (リスト入り選手を戦力外と同じ
# 強調色で表示)、指名フェーズは指名可能候補の単一選択。表はいずれも選手レコード表。
var _geneki_tab: String = PLAYER_TAB_PITCHER
var _geneki_player_rows: Array = []
var _geneki_by_id: Dictionary = {}
var _geneki_status_text: String = ""
var _geneki_phase: String = ""
var selected_geneki_list_ids: Dictionary = {}
var selected_geneki_pick_id: int = 0
# AI推奨リストを初期選択として流し込んだ year (state 再生成/年替わりで再シード)。
var _geneki_list_seeded_year: int = 0

# FA 市場 (step6)。一覧は戦力外獲得と同じ選手レコード表 (投手/野手タブ)。
var selected_fa_candidate_id: int = 0
var _fa_tab: String = PLAYER_TAB_PITCHER
var _fa_player_rows: Array = []
var _fa_by_id: Dictionary = {}
var _fa_status_text: String = ""
var _fa_can_submit: bool = false
var _fa_can_auto: bool = false
# 交渉する契約年数。0 = 候補の既定値 (CPU提示年数) をそのまま使う。年齢上限は fa_offer_max_years。
var selected_fa_offer_years: int = 0

# 外国人契約市場 (step7 前段)。自軍・他球団とも選手レコード表 (投手/野手タブ、_fgc_tab共通) で
# 表示し、投手/野手タブは両表を同時に絞り込む。他球団のみ現球団列を持つ (team_mode "fgc_market_away")。
var selected_fgc_player_id: int = 0
var _fgc_tab: String = PLAYER_TAB_PITCHER
var _fgc_home_pitcher_rows: Array = []
var _fgc_home_fielder_rows: Array = []
var _fgc_away_pitcher_rows: Array = []
var _fgc_away_fielder_rows: Array = []
var _fgc_by_id: Dictionary = {}          # player_id -> contract_entries のエントリ
var _fgc_status_text: String = ""
# 提示する契約年数。0 = 未選択 (提示済みならその年数、なければ1年)。上限は entry.max_years。
var selected_fgc_offer_years: int = 0
var _fgc_confirm_dialog: ConfirmationDialog = null

# 外国人契約市場の結果パネル (step7、契約市場確定後〜スカウト開始前の専用フェーズ)。
var _fgc_contract_result_rows: Array = []
var _fgc_contract_result_heading: String = ""

# 外国人スカウトの結果パネル (step7、スカウト終了後〜次ステップへ進む前の専用フェーズ)。
var _fgc_scout_result_rows: Array = []
var _fgc_scout_result_heading: String = ""

# 外国人補強 (step7)。一覧はドラフトと同じ候補ボード (投手/野手/各守備位置タブ)。
var selected_foreign_candidate_id: int = 0
var _foreign_candidate_rows: Array = []
var _foreign_record_cache: Dictionary = {}
var _foreign_by_id: Dictionary = {}
var _foreign_status_text: String = ""
var _foreign_can_submit: bool = false
var _foreign_request_position: String = "any"
var _foreign_request_archetype: String = "balanced"
var _foreign_request_budget: String = "standard"

# キャンプ (step8)。選手一覧はドラフトと同じ候補ボード。下段に特別練習メニュー/成功率/獲得適性パネル。
var selected_camp_player_id: int = 0
var selected_camp_training_type: String = ""
var selected_camp_target_position: int = 0
var _camp_tab: String = "pitcher"
var _camp_candidate_rows: Array = []
var _camp_record_cache: Dictionary = {}
var _camp_status_text: String = ""
var _camp_options: Array = []
var _camp_types: Array = []        # [{type,label}]
var _camp_positions: Array = []    # [{pos,name}]
var _camp_detail_text: String = ""
var _camp_selected_option: Dictionary = {}
var _camp_can_submit: bool = false
var _camp_complete: bool = false
# キャンプ結果一覧も成長と同じ候補タブ (投手/先発/中継/野手/各守備位置) で切り替える。
var _camp_result_tab: String = "pitcher"

# 選手の成長 結果。一覧はドラフトと同じ候補タブで投手/野手/各守備位置を切り替える。
var _growth_tab: String = "pitcher"

# 契約更改 結果。自チームの選手一覧 (投手/野手タブ・昨シーズン成績付き)。
var _contract_tab: String = "pitcher"

# FA宣言 結果。FA権保有者一覧 (投手/野手タブ)。
var _fa_declaration_tab: String = PLAYER_TAB_PITCHER

# 契約年数の決定 (FA市場の直後)。自軍候補のみの1表 (投手/野手タブ)。
var selected_cy_player_id: int = 0
var _cy_tab: String = PLAYER_TAB_PITCHER
var _cy_pitcher_rows: Array = []
var _cy_fielder_rows: Array = []
var _cy_by_id: Dictionary = {}
var _cy_status_text: String = ""
# 選択中の契約年数。0 = 未選択 (決定済みならその年数、なければ単年)。上限は entry.max_years。
var selected_cy_years: int = 0
var _cy_confirm_dialog: ConfirmationDialog = null


func _ready() -> void:
	_init_chrome()
	_refresh()


# ============================================================ refresh (データ集約)

func _refresh() -> void:
	_view = AppState.get_offseason_view_state()
	_active_panel = str(_view.get("active_panel", AppState.OFFSEASON_PANEL_NONE))
	# 既定の見出しはヘッダのステップ名と重複するので出さない。サブヘッダは操作メッセージ専用。
	_status_text = ""
	_status_color = MUTED
	if bool(_view.get("active", false)):
		_compute_roster_summary()
		match _active_panel:
			AppState.OFFSEASON_PANEL_RELEASE:
				_populate_release()
			AppState.OFFSEASON_PANEL_DRAFT:
				_populate_draft()
			AppState.OFFSEASON_PANEL_RELEASED_MARKET:
				_populate_released()
			AppState.OFFSEASON_PANEL_GENEKI_DRAFT:
				_populate_geneki()
			AppState.OFFSEASON_PANEL_FA:
				_populate_fa()
			AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT:
				_populate_foreign_contract()
			AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT:
				_populate_foreign_contract_result()
			AppState.OFFSEASON_PANEL_FOREIGN_RESULT:
				_populate_foreign_scout_result()
			AppState.OFFSEASON_PANEL_FOREIGN:
				_populate_foreign()
			AppState.OFFSEASON_PANEL_CAMP:
				_populate_camp()
			AppState.OFFSEASON_PANEL_CONTRACT_YEARS:
				_populate_contract_years()
	_build_buttons()
	queue_redraw()


func _set_status(text: String, color: Color) -> void:
	_status_text = text
	_status_color = color
	queue_redraw()


# 自軍ロスターの枠/ポジション別人数を1回集計 (描画は _draw_summary_panel)。
# ポジション別は支配下 (非育成) の主ポジションで数える。投手 (pos=1) は先発/中継 (抑えは中継に含む) で分ける。
func _compute_roster_summary() -> void:
	var team_id: int = AppState.selected_team_id
	var positions: Dictionary = {2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0}
	var starters: int = 0
	var relievers: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or player.development_player:
			continue
		var pos: int = player.position
		if pos == 1:
			if _resolved_pitcher_role(player.role, {}) == "starter":
				starters += 1
			else:
				relievers += 1
		elif positions.has(pos):
			positions[pos] = int(positions[pos]) + 1
	var team: PSTeam = GameDb.get_team(team_id)
	var payroll: int = TeamFinance.team_payroll(GameDb.players, team_id)
	_roster_summary = {
		"shienka": TeamFinance.shienka_count(GameDb.players, team_id),
		"development": TeamFinance.development_count(GameDb.players, team_id),
		"foreign": _active_foreign_count(team_id),
		"positions": positions,
		"starters": starters,
		"relievers": relievers,
		"funds": team.funds if team != null else 0,
		"payroll": payroll,
		"room": TeamFinance.budget_room(team.funds if team != null else 0, payroll),
	}


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("home_empty", "ホームへ", Rect2(860, 560, 200, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	if not bool(_view.get("active", false)):
		_layout_buttons()
		return

	# 上部右: セーブ / 次のステップへ / 翌年開始 (セーブは全ステップ共通)。
	_add_button("save", "セーブ", Rect2(1452, 22, 84, 42), _on_save_pressed, "action")
	var next_button: Button = _add_button("next", "次のステップへ", Rect2(1544, 22, 170, 42), _on_next_pressed, "primary")
	next_button.disabled = not bool(_view.get("can_advance", false))
	var finalize_button: Button = _add_button("finalize", "翌年開始", Rect2(1722, 22, 178, 42), _on_finalize_pressed, "primary")
	finalize_button.disabled = not bool(_view.get("can_finalize", false))

	match _active_panel:
		AppState.OFFSEASON_PANEL_RELEASE:
			_action_row([
				{"id": "rel_commit", "label": "戦力外を確定して次へ", "cb": _on_commit_release_pressed, "kind": "primary", "w": 220},
				{"id": "rel_auto", "label": "推奨選手を表示", "cb": _on_auto_select_release_pressed, "kind": "action", "w": 160},
				{"id": "rel_auto_commit", "label": "自動で決定して次へ", "cb": _on_auto_commit_release_pressed, "kind": "action", "w": 180},
			])
			_build_player_tabs("release", _release_tab, _release_pitcher_records.size(), _release_fielder_records.size(), _set_release_tab)
		AppState.OFFSEASON_PANEL_DRAFT:
			if _draft_reveal_stage == "reveal":
				_action_row([
					{"id": "draft_proceed", "label": _draft_reveal_go_label, "cb": _on_draft_proceed_pressed, "kind": "primary", "w": 140},
					{"id": "draft_auto_all", "label": "残りを自動進行", "cb": _on_draft_auto_all_pressed, "kind": "action", "w": 150},
				])
			elif _draft_reveal_stage == "result":
				_action_row([
					{"id": "draft_proceed", "label": "次へ", "cb": _on_draft_proceed_pressed, "kind": "primary", "w": 140},
					{"id": "draft_auto_all", "label": "残りを自動進行", "cb": _on_draft_auto_all_pressed, "kind": "action", "w": 150},
				])
			else:
				var specs: Array = [{"id": "draft_submit", "label": _draft_submit_label, "cb": _on_draft_submit_pressed, "kind": "primary", "w": 130}]
				if _draft_show_skip:
					specs.append({"id": "draft_skip", "label": _draft_skip_label, "cb": _on_draft_skip_pressed, "kind": "action", "w": 130})
				specs.append({"id": "draft_auto", "label": "この指名を自動", "cb": _on_draft_auto_pressed, "kind": "action", "w": 150})
				specs.append({"id": "draft_auto_all", "label": "残りを自動進行", "cb": _on_draft_auto_all_pressed, "kind": "action", "w": 150})
				_action_row(specs)
				# 「途中経過」ビュー中は候補ボードを描かないため、候補タブも出さない。
				if _draft_history_mode != "by_team":
					_build_candidate_tabs(_draft_candidate_rows, _draft_tab, _set_draft_tab, "draft")
				_build_draft_history_mode_chips()
		AppState.OFFSEASON_PANEL_RELEASED_MARKET:
			_action_row([
				{"id": "rm_submit", "label": "獲得する", "cb": _on_released_submit_pressed, "kind": "primary", "w": 110, "disabled": not _released_can_submit},
				{"id": "rm_skip", "label": "見送る", "cb": _on_released_skip_pressed, "kind": "action", "w": 100, "disabled": not _released_can_submit},
				{"id": "rm_auto", "label": "この判断を自動", "cb": _on_released_auto_pressed, "kind": "action", "w": 150, "disabled": not _released_can_auto},
				{"id": "rm_auto_all", "label": "残りを自動進行", "cb": _on_released_auto_all_pressed, "kind": "action", "w": 150},
			])
			var released_counts: Dictionary = _player_row_pitcher_fielder_counts(_released_player_rows)
			_build_player_tabs("released_market", _released_tab, int(released_counts.get(PLAYER_TAB_PITCHER, 0)), int(released_counts.get(PLAYER_TAB_FIELDER, 0)), _set_released_tab)
		AppState.OFFSEASON_PANEL_GENEKI_DRAFT:
			if _geneki_phase == "submit":
				_action_row([
					{"id": "gd_submit", "label": "リストを確定", "cb": _on_geneki_submit_list_pressed, "kind": "primary", "w": 150},
					{"id": "gd_reco", "label": "推奨リストに戻す", "cb": _on_geneki_reset_recommended_pressed, "kind": "action", "w": 170},
					{"id": "gd_ai", "label": "すべてAIに任せる", "cb": _on_geneki_ai_all_pressed, "kind": "action", "w": 170},
				])
			elif _geneki_phase == "round2_entry":
				_action_row([
					{"id": "gd_r2_pick", "label": "指名して参加", "cb": func() -> void: _on_geneki_round2_mode_pressed(GenekiDraftService.ROUND2_MODE_PICK), "kind": "primary", "w": 150},
					{"id": "gd_r2_offer", "label": "放出のみ参加", "cb": func() -> void: _on_geneki_round2_mode_pressed(GenekiDraftService.ROUND2_MODE_OFFER_ONLY), "kind": "action", "w": 150},
					{"id": "gd_r2_none", "label": "参加しない", "cb": func() -> void: _on_geneki_round2_mode_pressed(GenekiDraftService.ROUND2_MODE_NONE), "kind": "action", "w": 130},
					{"id": "gd_ai", "label": "すべてAIに任せる", "cb": _on_geneki_ai_all_pressed, "kind": "action", "w": 170},
				])
			else:
				var specs: Array = [
					{"id": "gd_pick", "label": "指名する", "cb": _on_geneki_pick_pressed, "kind": "primary", "w": 120, "disabled": selected_geneki_pick_id <= 0},
				]
				if _geneki_phase == "round2":
					specs.append({"id": "gd_pass", "label": "見送る", "cb": _on_geneki_pass_pressed, "kind": "action", "w": 100})
				specs.append({"id": "gd_ai", "label": "すべてAIに任せる", "cb": _on_geneki_ai_all_pressed, "kind": "action", "w": 170})
				_action_row(specs)
			var geneki_counts: Dictionary = _player_row_pitcher_fielder_counts(_geneki_player_rows)
			_build_player_tabs("geneki", _geneki_tab, int(geneki_counts.get(PLAYER_TAB_PITCHER, 0)), int(geneki_counts.get(PLAYER_TAB_FIELDER, 0)), _set_geneki_tab)
		AppState.OFFSEASON_PANEL_FA:
			_action_row([
				{"id": "fa_submit", "label": "交渉する", "cb": _on_fa_submit_pressed, "kind": "primary", "w": 110, "disabled": not _fa_can_submit},
				{"id": "fa_skip", "label": "見送る", "cb": _on_fa_skip_pressed, "kind": "action", "w": 100, "disabled": not _fa_can_submit},
				{"id": "fa_auto", "label": "この判断を自動", "cb": _on_fa_auto_pressed, "kind": "action", "w": 150, "disabled": not _fa_can_auto},
				{"id": "fa_auto_all", "label": "残りを自動進行", "cb": _on_fa_auto_all_pressed, "kind": "action", "w": 150},
			])
			var fa_counts: Dictionary = _player_row_pitcher_fielder_counts(_fa_player_rows)
			_build_player_tabs("fa_market", _fa_tab, int(fa_counts.get(PLAYER_TAB_PITCHER, 0)), int(fa_counts.get(PLAYER_TAB_FIELDER, 0)), _set_fa_tab)
			_build_fa_year_chips()
		AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT:
			var fgc_entry: Dictionary = _fgc_by_id.get(selected_fgc_player_id, {}) as Dictionary
			var fgc_has_offer: bool = not (fgc_entry.get("user_offer", {}) as Dictionary).is_empty()
			var fgc_submit_label: String = "提示する"
			if not fgc_entry.is_empty():
				fgc_submit_label = "残留を提示する" if int(fgc_entry.get("from_team_id", 0)) == AppState.selected_team_id else "引き抜きを提示する"
			_action_row([
				{"id": "fgc_submit", "label": fgc_submit_label, "cb": _on_fgc_submit_pressed, "kind": "primary", "w": 180, "disabled": fgc_entry.is_empty()},
				{"id": "fgc_withdraw", "label": "提示を取り下げる", "cb": _on_fgc_withdraw_pressed, "kind": "action", "w": 170, "disabled": not fgc_has_offer},
				{"id": "fgc_finalize", "label": "契約市場を確定して次へ", "cb": _on_foreign_contract_finalize_pressed, "kind": "primary", "w": 220},
				{"id": "fgc_ai_all", "label": "すべてAIに任せる", "cb": _on_foreign_contract_ai_all_pressed, "kind": "action", "w": 170},
			])
			_build_player_tabs("fgc_away", _fgc_tab, _fgc_away_pitcher_rows.size(), _fgc_away_fielder_rows.size(), _set_fgc_tab,
				FGC_AWAY_RECT.position.y + 14.0 - (BODY.position.y + 16.0))
			_build_fgc_year_chips()
		AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT:
			_action_row([
				{"id": "fgc_result_next", "label": "次へ", "cb": _on_foreign_contract_result_next_pressed, "kind": "primary", "w": 140},
			])
			var fgc_result_counts: Dictionary = _player_row_pitcher_fielder_counts(_fgc_contract_result_rows)
			_build_player_tabs("fgc_contract_result", _result_people_tab, int(fgc_result_counts.get(PLAYER_TAB_PITCHER, 0)), int(fgc_result_counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab)
		AppState.OFFSEASON_PANEL_FOREIGN_RESULT:
			_action_row([
				{"id": "fgc_scout_result_next", "label": "次へ", "cb": _on_foreign_scout_result_next_pressed, "kind": "primary", "w": 140},
			])
			var fgc_scout_counts: Dictionary = _player_row_pitcher_fielder_counts(_fgc_scout_result_rows)
			_build_player_tabs("fgc_scout_result", _result_people_tab, int(fgc_scout_counts.get(PLAYER_TAB_PITCHER, 0)), int(fgc_scout_counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab)
		AppState.OFFSEASON_PANEL_FOREIGN:
			_action_row([
				{"id": "fg_search", "label": "候補を検索", "cb": _on_foreign_search_pressed, "kind": "primary", "w": 120},
				{"id": "fg_submit", "label": "獲得する", "cb": _on_foreign_submit_pressed, "kind": "primary", "w": 110, "disabled": not _foreign_can_submit},
				{"id": "fg_skip", "label": "見送る", "cb": _on_foreign_skip_pressed, "kind": "action", "w": 100, "disabled": not _foreign_can_submit},
				{"id": "fg_auto_all", "label": "補強を終了", "cb": _on_foreign_auto_all_pressed, "kind": "action", "w": 130},
				{"id": "fg_ai_all", "label": "すべてAIに任せる", "cb": _on_foreign_ai_all_pressed, "kind": "action", "w": 170},
			])
			_build_foreign_scout_chips()
		AppState.OFFSEASON_PANEL_CAMP:
			_action_row([
				{"id": "camp_submit", "label": "実行", "cb": _on_camp_submit_pressed, "kind": "primary", "w": 100, "disabled": not _camp_can_submit},
				{"id": "camp_finish", "label": "キャンプ終了", "cb": _on_camp_finish_pressed, "kind": "action", "w": 140, "disabled": _camp_complete},
				{"id": "camp_auto", "label": "自軍をAIに任せる", "cb": _on_camp_auto_pressed, "kind": "action", "w": 180, "disabled": _camp_complete},
			])
			_build_candidate_tabs(_camp_candidate_rows, _camp_tab, _set_camp_tab, "camp")
			_build_camp_chips()
		AppState.OFFSEASON_PANEL_CONTRACT_YEARS:
			var cy_entry: Dictionary = _cy_by_id.get(selected_cy_player_id, {}) as Dictionary
			var cy_pending: int = AppState.pending_contract_years_count()
			_action_row([
				{"id": "cy_submit", "label": "年数を決定", "cb": _on_cy_submit_pressed, "kind": "primary", "w": 140, "disabled": cy_entry.is_empty()},
				{"id": "cy_withdraw", "label": "決定を取り消す", "cb": _on_cy_withdraw_pressed, "kind": "action", "w": 150, "disabled": not bool(cy_entry.get("decided", false))},
				{"id": "cy_finalize", "label": "確定して次へ", "cb": _on_cy_finalize_pressed, "kind": "primary", "w": 150, "disabled": cy_pending > 0},
				{"id": "cy_auto", "label": "自動で決めて次へ", "cb": _on_cy_auto_pressed, "kind": "action", "w": 180, "disabled": cy_pending <= 0},
			])
			_build_player_tabs("cy", _cy_tab, _cy_pitcher_rows.size(), _cy_fielder_rows.size(), _set_cy_tab)
			_build_cy_year_chips()
		_:
			_build_result_people_tabs()
			_build_step_result_tabs()

	_layout_buttons()


# 選手一覧タブ。投手/野手は別表なので「全選手」は作らない。
func _build_player_tabs(prefix: String, active_tab: String, pitcher_count: int, fielder_count: int, callback: Callable, y_offset: float = 0.0) -> void:
	var x: float = BODY.position.x + 16.0
	var y: float = BODY.position.y + 16.0 + y_offset
	var tabs: Array = [
		{"id": PLAYER_TAB_PITCHER, "label": "投手 %d" % pitcher_count, "w": 92.0},
		{"id": PLAYER_TAB_FIELDER, "label": "野手 %d" % fielder_count, "w": 92.0},
	]
	for tab_value in tabs:
		var tab: Dictionary = tab_value as Dictionary
		var tab_id: String = str(tab["id"])
		var active: bool = tab_id == active_tab
		_add_button("%s_tab_%s" % [prefix, tab_id], str(tab["label"]), Rect2(x, y, float(tab["w"]), 32.0),
			func(target: String = tab_id) -> void: callback.call(target),
			"chip_active" if active else "chip")
		x += float(tab["w"]) + 8.0


# 候補ボードのタブ (投手/先発/中継/野手/各守備位置)。ドラフト/外国人で共用。件数をラベルに付ける。
func _build_candidate_tabs(rows: Array, active_tab: String, callback: Callable, prefix: String) -> void:
	var x: float = BODY.position.x + 16.0
	var y: float = BODY.position.y + 30.0
	# 件数は3桁になり得るので、幅はラベル実測で確保する (固定幅だと件数が見切れる)。
	for tab_value in DRAFT_TABS:
		var tab: Dictionary = tab_value as Dictionary
		var tab_id: String = str(tab["id"])
		var label: String = "%s %d" % [str(tab["label"]), _candidate_tab_count(rows, tab_id)]
		var w: float = 14.0 + _measure(label, 13) + 14.0
		var active: bool = tab_id == active_tab
		_add_button("%s_tab_%s" % [prefix, tab_id], label, Rect2(x, y, w, 30.0),
			func(t: String = tab_id) -> void: callback.call(t),
			"chip_active" if active else "chip")
		x += w + 6.0


func _build_result_people_tabs() -> void:
	var step: String = str(_view.get("step", ""))
	if step != AppState.OFFSEASON_STEP_RETIREMENT and step != AppState.OFFSEASON_STEP_RELEASE_COMMIT:
		return
	var result: Dictionary = _view.get("result", {}) as Dictionary
	if result.is_empty():
		return
	var people: Array = result.get("retired", []) as Array
	if step == AppState.OFFSEASON_STEP_RELEASE_COMMIT:
		people = []
		people.append_array(result.get("released", []) as Array)
		people.append_array(result.get("demoted", []) as Array)
	var counts: Dictionary = _people_pitcher_fielder_counts(people)
	# budgets (予算改定サマリー) は step_0 のみ result に含まれ、その分タブを下へ逃がす
	# (_draw_budget_recompute_summary と同じ高さを共有、ずれるとタブと文字が重なる)。
	var y_offset: float = BUDGET_SUMMARY_BLOCK_H if result.has("budgets") else 0.0
	_build_player_tabs("result_people", _result_people_tab, int(counts.get(PLAYER_TAB_PITCHER, 0)), int(counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab, y_offset)


# 結果ステップ固有のタブ。成長=候補タブ / キャンプ=自軍・他球団タブ。
func _build_step_result_tabs() -> void:
	var step: String = str(_view.get("step", ""))
	if step == AppState.OFFSEASON_STEP_GROWTH:
		_build_candidate_tabs(_growth_board_entries(), _growth_tab, _set_growth_tab, "growth")
	elif step == AppState.OFFSEASON_STEP_CAMP:
		_build_candidate_tabs(_camp_result_entries(), _camp_result_tab, _set_camp_result_tab, "camp_res")
	elif step == AppState.OFFSEASON_STEP_CONTRACT_RENEWAL:
		var counts: Dictionary = _player_row_pitcher_fielder_counts(_contract_player_rows())
		_build_player_tabs("contract", _contract_tab, int(counts.get(PLAYER_TAB_PITCHER, 0)), int(counts.get(PLAYER_TAB_FIELDER, 0)), _set_contract_tab)
	elif step == AppState.OFFSEASON_STEP_FA_DECLARATION:
		var declaration_result: Dictionary = _view.get("result", {}) as Dictionary
		var declaration_counts: Dictionary = _entry_pitcher_fielder_counts(declaration_result.get("entries", []) as Array)
		_build_player_tabs("fa_decl", _fa_declaration_tab, int(declaration_counts.get(PLAYER_TAB_PITCHER, 0)), int(declaration_counts.get(PLAYER_TAB_FIELDER, 0)), _set_fa_declaration_tab)
	elif step == AppState.OFFSEASON_STEP_CONTRACT_YEARS:
		var years_result: Dictionary = _view.get("result", {}) as Dictionary
		var years_rows: Array = _result_signing_player_rows(years_result.get("multi_year_signings", []) as Array)
		var years_counts: Dictionary = _player_row_pitcher_fielder_counts(years_rows)
		_build_player_tabs("result_years", _result_people_tab, int(years_counts.get(PLAYER_TAB_PITCHER, 0)), int(years_counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab)
	elif step == AppState.OFFSEASON_STEP_GENEKI_DRAFT:
		var geneki_result: Dictionary = _view.get("result", {}) as Dictionary
		var move_rows: Array = _result_signing_player_rows(geneki_result.get("moves", []) as Array)
		var geneki_counts: Dictionary = _player_row_pitcher_fielder_counts(move_rows)
		_build_player_tabs("result_moves", _result_people_tab, int(geneki_counts.get(PLAYER_TAB_PITCHER, 0)), int(geneki_counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab)
	elif step == AppState.OFFSEASON_STEP_RELEASED_MARKET or step == AppState.OFFSEASON_STEP_FA_MARKET or step == AppState.OFFSEASON_STEP_FOREIGN_MARKET:
		var result: Dictionary = _view.get("result", {}) as Dictionary
		# 外国人ステップのレビューはスカウト獲得のみ表示するため (契約市場結果は専用フェーズで表示済み)、
		# タブ件数もスカウト署名だけで数える。
		var signing_rows: Array = _result_signing_player_rows(result.get("signings", []) as Array)
		var counts: Dictionary = _player_row_pitcher_fielder_counts(signing_rows)
		_build_player_tabs("result_signings", _result_people_tab, int(counts.get(PLAYER_TAB_PITCHER, 0)), int(counts.get(PLAYER_TAB_FIELDER, 0)), _set_result_people_tab)


func _set_growth_tab(tab_id: String) -> void:
	if _growth_tab == tab_id:
		return
	_growth_tab = tab_id
	_build_buttons()
	queue_redraw()


func _set_camp_result_tab(tab_id: String) -> void:
	if _camp_result_tab == tab_id:
		return
	_camp_result_tab = tab_id
	_build_buttons()
	queue_redraw()


func _set_contract_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _contract_tab == tab_id:
		return
	_contract_tab = tab_id
	_build_buttons()
	queue_redraw()


# 契約更新画面に出す自チームの選手レコード行 (昨シーズンの記録)。
func _contract_player_rows(_result: Dictionary = {}) -> Array:
	var season: PSSeason = AppState.current_season
	if season == null:
		return []
	var team_id: int = AppState.selected_team_id
	var rows: Array = []
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var player: PSPlayer = GameDb.get_player(record.player_id)
		var current_salary: int = player.salary if player != null else record.salary
		rows.append({
			"record": record,
			"player": player,
			"entry": {
				"player_id": record.player_id,
				"team_id": record.team_id,
				"position": record.position,
				"role": record.role,
				"old_salary": record.salary,
				"new_salary": current_salary,
				"salary_delta": current_salary - record.salary,
				"contract_years": _player_contract_years(player, season.year),
			},
		})
	return rows


# 契約更改表に出す契約年数。複数年契約の期間中はその総年数、FA権保有者が単年を選んだ場合は 1 (単年)。
# **FA権未取得の選手は 0 を返し "-" で描く** — 契約年数を決める場面が無く自動更新されるだけなので、
# 自分で単年を選んだ選手と同じ「単年」表記にすると区別がつかない (ユーザー指摘)。
func _player_contract_years(player: PSPlayer, offseason_year: int) -> int:
	if player == null:
		return 0
	if player.is_multi_year_locked_offseason(offseason_year):
		return maxi(1, int(player.source_data.get("contract_total_years", 1)))
	return 1 if player.is_fa_eligible() else 0


# キャンプ結果の特別練習アクションを候補タブで絞り込めるよう role/aptitudes を補う。
func _camp_result_entries() -> Array:
	var result: Dictionary = _view.get("result", {}) as Dictionary
	var entries: Array = []
	for action_row in result.get("actions", []) as Array:
		var entry: Dictionary = (action_row as Dictionary).duplicate()
		var player: PSPlayer = GameDb.get_player(int(entry.get("player_id", 0)))
		var is_pitcher: bool = player != null and player.is_pitcher()
		entry["is_pitcher"] = is_pitcher
		if is_pitcher:
			entry["role"] = _resolved_pitcher_role(player.role, {})
		else:
			entry["role"] = "fielder"
		entry["position"] = player.position if player != null else int(entry.get("new_position", 0))
		entry["aptitudes"] = player.position_aptitudes if player != null else {}
		entry["arsenal"] = player.arsenal if player != null else []
		entries.append(entry)
	return entries


# 成長結果の投手/野手エントリを候補タブで絞り込めるよう role/aptitudes を補って結合する。
func _growth_board_entries() -> Array:
	var result: Dictionary = _view.get("result", {}) as Dictionary
	var entries: Array = []
	for arr_key in ["pitchers", "fielders"]:
		for entry_row in result.get(arr_key, []) as Array:
			var entry: Dictionary = (entry_row as Dictionary).duplicate()
			var player: PSPlayer = GameDb.get_player(int(entry.get("player_id", 0)))
			var is_pitcher: bool = player.is_pitcher() if player != null else arr_key == "pitchers"
			entry["is_pitcher"] = is_pitcher
			if is_pitcher:
				var role_key: String = player.role if player != null else str(entry.get("role", "starter"))
				entry["role"] = _resolved_pitcher_role(role_key, {})
			else:
				entry["role"] = "fielder"
			entry["position"] = player.position if player != null else int(entry.get("position", 1 if is_pitcher else 0))
			entry["aptitudes"] = player.position_aptitudes if player != null else {}
			entry["arsenal"] = player.arsenal if player != null else []
			entries.append(entry)
	return entries


# 操作ボタンを ACTION_Y の行に右寄せで並べる。
func _action_row(specs: Array) -> void:
	var gap: float = 10.0
	var total: float = 0.0
	for spec_value in specs:
		total += float((spec_value as Dictionary).get("w", 120))
	total += gap * float(max(0, specs.size() - 1))
	var x: float = INNER_R - total
	for spec_value in specs:
		var spec: Dictionary = spec_value as Dictionary
		var w: float = float(spec.get("w", 120))
		var button: Button = _add_button(str(spec.get("id", "")), str(spec.get("label", "")), Rect2(x, ACTION_Y, w, 40), spec.get("cb") as Callable, str(spec.get("kind", "action")))
		if spec.has("disabled"):
			button.disabled = bool(spec["disabled"])
		x += w + gap


func _build_foreign_scout_chips() -> void:
	var rows: Array = [
		{"y": BODY.position.y + 36.0, "options": FOREIGN_POSITION_OPTIONS, "selected": _foreign_request_position, "prefix": "fg_pos", "callback": _select_foreign_position},
		{"y": BODY.position.y + 78.0, "options": _foreign_type_options(), "selected": _foreign_request_archetype, "prefix": "fg_type", "callback": _select_foreign_archetype},
		{"y": BODY.position.y + 120.0, "options": FOREIGN_BUDGET_OPTIONS, "selected": _foreign_request_budget, "prefix": "fg_budget", "callback": _select_foreign_budget},
	]
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var x: float = BODY.position.x + 116.0
		for option_value in row.get("options", []) as Array:
			var option: Dictionary = option_value as Dictionary
			var id: String = str(option.get("id", ""))
			var label: String = str(option.get("label", ""))
			var w: float = 22.0 + _measure(label, 13) + 22.0
			var callback: Callable = row.get("callback") as Callable
			_add_button("%s_%s" % [str(row.get("prefix", "fg")), id], label, Rect2(x, float(row.get("y", 0.0)), w, 30.0),
				func(value: String = id, cb: Callable = callback) -> void: cb.call(value),
				"chip_active" if id == str(row.get("selected", "")) else "chip")
			x += w + 8.0


func _foreign_type_options() -> Array:
	if _foreign_request_position == "any":
		return [FOREIGN_FIELDER_TYPES[0]]
	return FOREIGN_PITCHER_TYPES if _foreign_request_position == "starter" or _foreign_request_position == "reliever" else FOREIGN_FIELDER_TYPES


# キャンプの練習種別 / 対象位置をチップ (OptionButton 置換) で出す。
func _build_camp_chips() -> void:
	if selected_camp_player_id <= 0 or _camp_types.is_empty():
		return
	var x: float = CAMP_MENU.position.x + 16.0
	for type_value in _camp_types:
		var type_dict: Dictionary = type_value as Dictionary
		var label: String = str(type_dict.get("label", ""))
		var w: float = 18.0 + _measure(label, 13) + 18.0
		var active: bool = str(type_dict.get("type", "")) == selected_camp_training_type
		_add_button("camp_t_%s" % str(type_dict.get("type", "")), label, Rect2(x, CAMP_MENU.position.y + 68.0, w, 30.0),
			func(tt: String = str(type_dict.get("type", ""))) -> void: _select_camp_training(tt),
			"chip_active" if active else "chip")
		x += w + 8.0
	if _camp_positions.is_empty():
		return
	x = CAMP_MENU.position.x + 16.0
	for pos_value in _camp_positions:
		var pos_dict: Dictionary = pos_value as Dictionary
		var label: String = str(pos_dict.get("name", ""))
		var w: float = 18.0 + _measure(label, 13) + 18.0
		var active: bool = int(pos_dict.get("pos", 0)) == selected_camp_target_position
		_add_button("camp_p_%d" % int(pos_dict.get("pos", 0)), label, Rect2(x, CAMP_MENU.position.y + 138.0, w, 30.0),
			func(pp: int = int(pos_dict.get("pos", 0))) -> void: _select_camp_position(pp),
			"chip_active" if active else "chip")
		x += w + 8.0


func _set_camp_tab(tab_id: String) -> void:
	if _camp_tab == tab_id:
		return
	_camp_tab = tab_id
	var visible: Array = _candidate_rows_for_tab(_camp_candidate_rows, _camp_tab)
	var still_visible: bool = false
	for row_value in visible:
		if int((row_value as Dictionary).get("candidate_id", 0)) == selected_camp_player_id:
			still_visible = true
			break
	if not still_visible:
		selected_camp_player_id = int((visible[0] as Dictionary).get("candidate_id", 0)) if not visible.is_empty() else 0
		selected_camp_training_type = ""
		selected_camp_target_position = 0
	_refresh()


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
			var hit: Dictionary = _row_at(base_pos)
			if not hit.is_empty():
				_on_row_clicked(str(hit.get("kind", "")), int(hit.get("meta", 0)))
				accept_event()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


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


func _on_row_clicked(kind: String, meta: int) -> void:
	match kind:
		"release":
			_toggle_release(meta)
		"draft":
			selected_draft_candidate_id = meta
			queue_redraw()
		"released":
			selected_released_candidate_id = meta
			_released_can_submit = meta > 0
			_build_buttons()
			queue_redraw()
		"geneki_list":
			if selected_geneki_list_ids.has(meta):
				selected_geneki_list_ids.erase(meta)
			else:
				selected_geneki_list_ids[meta] = true
			_geneki_refresh_submit_status()
			queue_redraw()
		"geneki_pick":
			selected_geneki_pick_id = meta
			_build_buttons()
			queue_redraw()
		"fa":
			selected_fa_candidate_id = meta
			selected_fa_offer_years = 0
			_fa_can_submit = meta > 0
			_build_buttons()
			queue_redraw()
		"fgc":
			selected_fgc_player_id = meta
			selected_fgc_offer_years = 0
			_build_buttons()
			queue_redraw()
		"ext":
			selected_cy_player_id = meta
			selected_cy_years = 0
			_build_buttons()
			queue_redraw()
		"foreign":
			selected_foreign_candidate_id = meta
			_foreign_can_submit = meta > 0
			_build_buttons()
			queue_redraw()
		"camp":
			selected_camp_player_id = meta
			selected_camp_training_type = ""
			selected_camp_target_position = 0
			_refresh()


# 戦力外: 行クリックで 戦力外(✓) → 育成降格(育) → 解除 を巡回。Shift で範囲戦力外。
func _toggle_release(pid: int) -> void:
	var shift_held: bool = Input.is_key_pressed(KEY_SHIFT)
	if shift_held and last_release_meta > 0:
		var metas: Array = []
		for record_row in _release_visible_records():
			metas.append((record_row as PSPlayerSeasonRecord).player_id)
		var i1: int = metas.find(last_release_meta)
		var i2: int = metas.find(pid)
		if i1 >= 0 and i2 >= 0:
			for i in range(min(i1, i2), max(i1, i2) + 1):
				selected_release_ids[int(metas[i])] = true
				selected_demote_ids.erase(int(metas[i]))
	else:
		if selected_release_ids.has(pid):
			selected_release_ids.erase(pid)
			selected_demote_ids[pid] = true
		elif selected_demote_ids.has(pid):
			selected_demote_ids.erase(pid)
		else:
			selected_release_ids[pid] = true
		last_release_meta = pid
	_rebuild_release_rows()
	_refresh_release_summary()
	queue_redraw()


func _set_release_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _release_tab == tab_id:
		return
	_release_tab = tab_id
	_build_buttons()
	queue_redraw()


func _set_released_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _released_tab == tab_id:
		return
	_released_tab = tab_id
	_ensure_released_selection_for_tab()
	_build_buttons()
	queue_redraw()


func _set_result_people_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _result_people_tab == tab_id:
		return
	_result_people_tab = tab_id
	_build_buttons()
	queue_redraw()


func _set_draft_tab(tab_id: String) -> void:
	if _draft_tab == tab_id:
		return
	_draft_tab = tab_id
	# 選択中の候補が新タブで見えなければ、先頭の候補へ移す。
	var visible: Array = _candidate_rows_for_tab(_draft_candidate_rows, _draft_tab)
	var still_visible: bool = false
	for row_value in visible:
		if int((row_value as Dictionary).get("candidate_id", 0)) == selected_draft_candidate_id:
			still_visible = true
			break
	if not still_visible:
		selected_draft_candidate_id = int((visible[0] as Dictionary).get("candidate_id", 0)) if not visible.is_empty() else 0
	_build_buttons()
	queue_redraw()


# 表示切替チップ (指名画面/途中経過)。BODY 右上 (状況テキスト行と同じ高さ) に右寄せで置き、
# 両モードから常に見える。通常指名中 (reveal/result 以外) のみ生成される。
func _build_draft_history_mode_chips() -> void:
	var x: float = BODY.end.x - _draft_history_chips_total_width()
	for option_value in DRAFT_HISTORY_MODES:
		var option: Dictionary = option_value as Dictionary
		var id: String = str(option["id"])
		var w: float = 14.0 + _measure(str(option["label"]), 13) + 14.0
		var active: bool = id == _draft_history_mode
		_add_button("draft_hist_%s" % id, str(option["label"]), Rect2(x, BODY.position.y, w, 30.0),
			func(target: String = id) -> void: _set_draft_history_mode(target),
			"chip_active" if active else "chip")
		x += w + 8.0


# チップ2個の合計幅。途中経過ビューの右端テキスト (優先リーグ) がチップと重ならないよう共用する。
func _draft_history_chips_total_width() -> float:
	var total: float = 0.0
	for option_value in DRAFT_HISTORY_MODES:
		total += 14.0 + _measure(str((option_value as Dictionary)["label"]), 13) + 14.0
	return total + 8.0 * float(DRAFT_HISTORY_MODES.size() - 1)


func _set_draft_history_mode(mode: String) -> void:
	if _draft_history_mode == mode:
		return
	_draft_history_mode = mode
	_build_buttons()
	queue_redraw()


func _select_camp_training(training_type: String) -> void:
	selected_camp_training_type = training_type
	selected_camp_target_position = 0
	_refresh()


func _select_camp_position(pos: int) -> void:
	selected_camp_target_position = pos
	_refresh()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_row_hits = []
	_scroll_zones = []

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_draw_empty()
		return

	# ヘッダのタイトルは現在のステップ名 (大きく)。何ステップ目かはサブヘッダに控えめに置く。
	var header_title: String = "オフシーズン"
	if bool(_view.get("active", false)):
		header_title = _step_name(str(_view.get("step", "")))
	_draw_shell(header_title, team, season)

	if not bool(_view.get("active", false)):
		_text(str(_view.get("status", "オフシーズンが開始されていません")), Vector2(INNER_L, 200), 18, MUTED)
		return

	_draw_subheader()
	_draw_summary_panel()

	match _active_panel:
		AppState.OFFSEASON_PANEL_RELEASE:
			_draw_release_panel()
		AppState.OFFSEASON_PANEL_DRAFT:
			_draw_draft_panel()
		AppState.OFFSEASON_PANEL_RELEASED_MARKET:
			_draw_released_market_panel()
		AppState.OFFSEASON_PANEL_GENEKI_DRAFT:
			_draw_geneki_panel()
		AppState.OFFSEASON_PANEL_FA:
			# FA一覧は戦力外獲得と同じ選手レコード表 (投手/野手タブ・候補詳細なし) + 提示年数列。
			_draw_player_record_table(BODY, _fa_status_text, _fa_player_rows, _fa_tab == PLAYER_TAB_PITCHER,
				"fa", "fa_market_%s" % _fa_tab, "fa", selected_fa_candidate_id, "該当するFA候補がいません。", true, false, "", true, true)
		AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT:
			_draw_foreign_contract_panel()
		AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT:
			_draw_foreign_contract_result_panel()
		AppState.OFFSEASON_PANEL_FOREIGN_RESULT:
			_draw_foreign_scout_result_panel()
		AppState.OFFSEASON_PANEL_FOREIGN:
			_draw_foreign_panel()
		AppState.OFFSEASON_PANEL_CAMP:
			_draw_camp_panel()
		AppState.OFFSEASON_PANEL_CONTRACT_YEARS:
			_draw_contract_years_panel()
		_:
			_draw_results(BODY)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)


# ステップ名はヘッダ見出し。ステップ番号表示は廃止 (将来ステップ構成が変わるため)。ここは状況テキストのみ。
func _draw_subheader() -> void:
	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 111), 14, _status_color, 1620)


# 各ステップの正準名 (結果データの有無に依存しない)。ヘッダ見出しに使う。
func _step_name(step: String) -> String:
	match step:
		AppState.OFFSEASON_STEP_FA_DECLARATION:
			return "FA宣言"
		AppState.OFFSEASON_STEP_RETIREMENT:
			return "引退"
		AppState.OFFSEASON_STEP_RELEASE_EDIT:
			return "戦力外通告"
		AppState.OFFSEASON_STEP_RELEASE_COMMIT:
			return "戦力外通告 結果"
		AppState.OFFSEASON_STEP_DRAFT_MAIN:
			return "ドラフト本指名"
		AppState.OFFSEASON_STEP_DRAFT_DEVELOPMENT:
			return "育成ドラフト"
		AppState.OFFSEASON_STEP_RELEASED_MARKET:
			return "戦力外獲得"
		AppState.OFFSEASON_STEP_GENEKI_DRAFT:
			return "現役ドラフト"
		AppState.OFFSEASON_STEP_FA_MARKET:
			return "FA市場"
		AppState.OFFSEASON_STEP_CONTRACT_YEARS:
			return "契約年数"
		AppState.OFFSEASON_STEP_FOREIGN_MARKET:
			return "外国人補強"
		AppState.OFFSEASON_STEP_CAMP:
			return "キャンプ"
		AppState.OFFSEASON_STEP_GROWTH:
			return "選手の成長"
		AppState.OFFSEASON_STEP_CONTRACT_RENEWAL:
			return "契約更改"
		_:
			return "オフシーズン"


# 全ステップ共通の自軍ロスターサマリー: 支配下 / 育成 / 外国人枠 (_stat_strip) + ポジション別人数 (小型セル列)。
func _draw_summary_panel() -> void:
	# 全幅フラットパネル (枠なし)。_stat_strip も同色 PANEL の角丸を内側に重ねるだけなので継ぎ目は出ない。
	_round(SUMMARY, PANEL, Color.TRANSPARENT, 8, 0)
	var shienka: int = int(_roster_summary.get("shienka", 0))
	var dev: int = int(_roster_summary.get("development", 0))
	var foreign: int = int(_roster_summary.get("foreign", 0))
	var room: int = int(_roster_summary.get("room", 0))
	var positions: Dictionary = _roster_summary.get("positions", {}) as Dictionary

	# 予算残は概算 (億丸め) でなく正確な万円まで出すため、予算残セルを広めに取り (strip_w 拡大)、
	# その分ポジション別の枠を狭める (SUMMARY.end.x までを分割するため div_x が右へ寄る)。
	var strip_w: float = 560.0
	var cells: Array = [
		{"label": "支配下", "value": "%d/%d" % [shienka, TeamFinance.SHIENKA_LIMIT], "color": AMBER if shienka >= TeamFinance.SHIENKA_LIMIT else TEXT},
		{"label": "育成", "value": "%d" % dev},
		{"label": "外国人", "value": "%d/%d" % [foreign, ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM], "color": AMBER if foreign >= ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM else TEXT},
		{"label": "予算残", "value": ("-" + _format_money_exact(-room)) if room < 0 else _format_money_exact(room), "color": AMBER if room < 0 else TEXT},
	]
	_stat_strip(Rect2(SUMMARY.position.x, SUMMARY.position.y, strip_w, SUMMARY.size.y), cells)

	var div_x: float = SUMMARY.position.x + strip_w
	_line(Vector2(div_x, SUMMARY.position.y + 14.0), Vector2(div_x, SUMMARY.end.y - 14.0), HAIRLINE, 1.0)
	var label_y: float = SUMMARY.position.y + 28.0
	var value_y: float = SUMMARY.position.y + 58.0
	_text("ポジション別 (支配下)", Vector2(div_x + 20.0, label_y), FS_LABEL, MUTED)
	var px0: float = div_x + 20.0
	# 投手 (pos=1) は先発/中継 (抑えは中継に含む) で分けて表示するため、野手8ポジション+2で10枠。
	var slots: Array = [
		{"char": "先", "count": int(_roster_summary.get("starters", 0)), "color": _pos_color(1)},
		{"char": "継", "count": int(_roster_summary.get("relievers", 0)), "color": _pos_color(1)},
	]
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		slots.append({"char": _position_char(pos), "count": int(positions.get(pos, 0)), "color": _pos_color(pos)})
	var slot: float = (SUMMARY.end.x - 16.0 - px0) / float(slots.size())
	for i in range(slots.size()):
		var entry: Dictionary = slots[i] as Dictionary
		var cx: float = px0 + float(i) * slot
		_text(str(entry["char"]), Vector2(cx, value_y), 16, entry["color"] as Color, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
		_text(str(int(entry["count"])), Vector2(cx + 24.0, value_y), 18, TEXT, slot - 26.0)


# 予算残の正確表記 (万円単位を丸めず出す)。億と万に分けて読みやすくする (例: 40234万 → "4億234万")。
# _format_money_compact (概算・億丸め) と使い分ける。
func _format_money_exact(man_value: int) -> String:
	var a: int = absi(man_value)
	var oku: int = a / 10000
	var man: int = a % 10000
	if oku > 0 and man > 0:
		return "%d億%s万" % [oku, _comma(man)]
	elif oku > 0:
		return "%d億" % oku
	return "%s万" % _comma(man)


# --- 戦力外通告 ---

func _draw_release_panel() -> void:
	var records: Array = _release_visible_records()
	var pitcher_tab: bool = _release_tab == PLAYER_TAB_PITCHER
	_draw_player_record_table(BODY, _release_summary_text, records, pitcher_tab, "release", "release_%s" % _release_tab, "release", 0, "該当する選手がいません。", true, false, "", true)


# --- ドラフト ---

func _draw_draft_panel() -> void:
	if _draft_reveal_stage != "":
		_draw_draft_reveal_panel()
		return
	if _draft_history_mode == "by_team":
		# 「途中経過」は候補ボードを描かず、結果画面と同じ構成のビューを BODY 全面に描く。
		_draw_draft_progress_panel()
		return
	# 上: 状況テキスト → タブ行 (ボタン) → 候補表 (タブ切替・全幅)。
	# 下: 指名履歴 (左) / 抽選 (右) の 2 パネル。表示切替チップ (指名画面/途中経過) は BODY 右上。
	var status_y: float = BODY.position.y
	if not _draft_status_text.is_empty():
		_text(_draft_status_text, Vector2(INNER_L, status_y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)

	# タブ行は _build_candidate_tabs が status_y + 30 にボタンで重ねる。
	var table_top: float = status_y + 68.0
	var board_h: float = (BODY.end.y - table_top) * 0.62
	_draw_candidate_board(Rect2(INNER_L, table_top, BODY.size.x, board_h), _draft_candidate_rows, _draft_tab,
		selected_draft_candidate_id, "draft", _draft_record_cache, "出身", "成長")

	var lower_top: float = table_top + board_h + 14.0
	var lower_h: float = BODY.end.y - lower_top
	var gap: float = 16.0
	var half: float = (BODY.size.x - gap) / 2.0
	# 指名履歴 (左) / 抽選 (右) を他パネルと同じ表で描く。
	_draw_table_inner(Rect2(INNER_L, lower_top, half, lower_h), "指名履歴", PICK_COLUMNS, _draft_pick_rows, "draft_picks", "", 0, true)
	_draw_table_inner(Rect2(INNER_L + half + gap, lower_top, half, lower_h), "抽選", LOTTERY_COLUMNS, _draft_lottery_rows, "draft_lottery", "", 0, true)


# 「途中経過」モードのビュー。結果画面 (_draw_draft_result) と同じ構成で BODY 全面に
# 見出し → 1巡目 抽選 (log があれば) → 球団別グリッドを描く。球団列は順位順 (1位→6位)。
func _draw_draft_progress_panel() -> void:
	var state: Dictionary = AppState.draft_state
	var picks: Array = state.get("picks", []) as Array
	var phase_label: String = "育成ドラフト" if str(state.get("segment", "main")) == "development" else "本指名"
	_text("%s 途中経過 指名%d人" % [phase_label, picks.size()], Vector2(BODY.position.x, BODY.position.y + 26), 20, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	# 優先リーグ表示は右上のチップ (指名画面/途中経過) と重ならないよう、チップ幅ぶん左へ寄せる。
	_text_right("同順位優先リーグ: %s" % _league_label(str(state.get("priority_league", ""))),
		BODY.end.x - _draft_history_chips_total_width() - 16.0, BODY.position.y + 24, 14, MUTED, 320.0)

	var content_top: float = BODY.position.y + 52.0
	if not _draft_lottery_rows.is_empty():
		var lottery_h: float = min(64.0 + float(_draft_lottery_rows.size()) * 28.0, 220.0)
		_draw_table_inner(Rect2(BODY.position.x, content_top, BODY.size.x, lottery_h), "1巡目 抽選", LOTTERY_COLUMNS, _draft_lottery_rows, "draft_progress_lottery", "", 0, true, 15, 28.0)
		content_top += lottery_h + 14.0

	_draw_picks_team_grid(Rect2(BODY.position.x, content_top, BODY.size.x, BODY.end.y - content_top), picks, "rank")


# 1巡目入札公開 (reveal) / 抽選結果 (result) の静的表示パネル。候補ボードの代わりに
# 状況テキスト → 球団別カードグリッド (左2/3・4列×N行) + 抽選履歴 (右1/3・過去 wave 分も含む) を並べる。
# 選択操作は無い (カードクリック無効・アニメーション無し)。
func _draw_draft_reveal_panel() -> void:
	var status_y: float = BODY.position.y
	if not _draft_status_text.is_empty():
		_text(_draft_status_text, Vector2(INNER_L, status_y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)

	var table_top: float = status_y + 40.0
	var table_h: float = BODY.end.y - table_top
	var gap: float = 16.0
	var left_w: float = (BODY.size.x - gap) * (2.0 / 3.0)
	var right_w: float = BODY.size.x - gap - left_w
	var left_title: String = "抽選結果" if _draft_reveal_stage == "result" else "入札一覧"
	_draw_draft_reveal_cards_panel(Rect2(INNER_L, table_top, left_w, table_h), left_title)
	_draw_table_inner(Rect2(INNER_L + left_w + gap, table_top, right_w, table_h), "抽選", LOTTERY_COLUMNS, _draft_lottery_rows, "draft_lottery", "", 0, true)


# _panel と同じフラット枠+タイトルの下に、球団カード (_draft_reveal_cards) を4列×N行のグリッドで描く。
func _draw_draft_reveal_cards_panel(rect: Rect2, title: String) -> void:
	_panel(rect, title)
	var grid_top: float = rect.position.y + 50.0
	var grid_rect: Rect2 = Rect2(rect.position.x + 16.0, grid_top, rect.size.x - 32.0, rect.end.y - grid_top - 16.0)
	if _draft_reveal_cards.is_empty():
		_text("該当する球団がいません。", Vector2(grid_rect.position.x, grid_rect.position.y + 20.0), 14, MUTED)
		return
	var cols: int = 4
	var rows: int = int(ceil(float(_draft_reveal_cards.size()) / float(cols)))
	var gap: float = 12.0
	var card_w: float = (grid_rect.size.x - gap * float(cols - 1)) / float(cols)
	var card_h: float = (grid_rect.size.y - gap * float(max(1, rows - 1))) / float(rows)
	for i in range(_draft_reveal_cards.size()):
		var card: Dictionary = _draft_reveal_cards[i] as Dictionary
		var col: int = i % cols
		var row: int = int(i / cols)
		var cx: float = grid_rect.position.x + float(col) * (card_w + gap)
		var cy: float = grid_rect.position.y + float(row) * (card_h + gap)
		_draw_draft_reveal_card(Rect2(cx, cy, card_w, card_h), card)


# 球団1枚分のカード。ヘッダ=チーム色ドット+短縮名 (右上に状態チップ)、本文=選手名(強調)+
# 守備バッジ・年齢・出身・総合。muted=true (指名済/指名なし) は文字色を落として沈んだ見た目にする。
func _draw_draft_reveal_card(rect: Rect2, card: Dictionary) -> void:
	var muted: bool = bool(card.get("muted", false))
	_round(rect, PANEL_2 if not muted else PANEL, BORDER_SOFT, 8, 1)

	var pad: float = 14.0
	var note: String = str(card.get("note", ""))
	var note_w: float = (18.0 + _measure(note, 12) + 18.0) if not note.is_empty() else 0.0
	_dot(Vector2(rect.position.x + pad + 5.0, rect.position.y + pad + 6.0), 5.0, card.get("team_color", MUTED) as Color)
	_text(str(card.get("team", "")), Vector2(rect.position.x + pad + 16.0, rect.position.y + pad + 11.0), 14,
		TEXT if not muted else MUTED, rect.size.x - pad * 2.0 - 16.0 - note_w - 8.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	if not note.is_empty():
		_chip(Rect2(rect.end.x - pad - note_w, rect.position.y + pad - 3.0, note_w, 22.0), note, card.get("note_color", MUTED) as Color)

	var name_y: float = rect.position.y + pad + 46.0
	_text(str(card.get("name", "")), Vector2(rect.position.x + pad, name_y), 18, TEXT if not muted else MUTED, rect.size.x - pad * 2.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var detail_y: float = name_y + 26.0
	var dx: float = rect.position.x + pad
	var pos_text: String = str(card.get("pos", ""))
	if not pos_text.is_empty():
		var badge_w: float = 14.0 + _measure(pos_text, 12) + 14.0
		_chip(Rect2(dx, detail_y, badge_w, 20.0), pos_text, card.get("pos_color", MUTED) as Color)
		dx += badge_w + 8.0
	var detail_text: String = ""
	if int(card.get("age", 0)) > 0:
		detail_text = "%d歳" % int(card.get("age", 0))
	var source: String = str(card.get("source", ""))
	if not source.is_empty():
		detail_text += (" ・ " if not detail_text.is_empty() else "") + source
	if not detail_text.is_empty():
		_text(detail_text, Vector2(dx, detail_y + 15.0), 13, MUTED if not muted else FAINT, rect.end.x - pad - dx)

	if int(card.get("overall", 0)) > 0:
		_text("総合 %d" % int(card.get("overall", 0)), Vector2(rect.position.x + pad, detail_y + 42.0), 14, TEXT if not muted else MUTED, rect.size.x - pad * 2.0, HORIZONTAL_ALIGNMENT_LEFT, true)


# 候補ボード (ドラフト/外国人補強で共用)。戦力外選択と同じ行スタイルで、投手系タブは
# 球速/球質/制球/持久 + 変化球、野手系タブは巧打/長打/走力/守備/肩力/選球 + 守備適性を並べる。
# info1/info2 は中央2列の見出し (ドラフト=出身/成長, 外国人=評価/年俸)。値は row["info1"/"info2"]。
# cache は candidate_id -> PSPlayerSeasonRecord (レーティング遅延算出)。
func _draw_candidate_board(rect: Rect2, rows: Array, tab: String, selected_id: int, sel_kind: String, cache: Dictionary, info1_header: String, info2_header: String) -> void:
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	var pitcher_table: bool = _candidate_tab_is_pitcher(tab)
	var visible_rows: Array = _candidate_rows_for_tab(rows, tab)
	var hy: float = rect.position.y + 30.0
	if pitcher_table:
		_draw_candidate_pitcher_header(rect, hy, info1_header, info2_header)
	else:
		_draw_candidate_fielder_header(rect, hy, info1_header, info2_header)

	if visible_rows.is_empty():
		_text("該当する候補がいません。", Vector2(rect.position.x + 18.0, rect.position.y + 64.0), 14, MUTED)
		return

	var row_h: float = 27.0
	var row_top: float = rect.position.y + 50.0
	var bottom: float = rect.end.y - 12.0
	var visible: int = max(1, int((bottom - row_top) / row_h))
	var scroll_key: String = "%s_board_%s" % [sel_kind, tab]
	var max_scroll: int = max(0, visible_rows.size() - visible)
	var offset: int = clampi(int(_scroll.get(scroll_key, 0)), 0, max_scroll)
	_scroll[scroll_key] = offset
	if max_scroll > 0:
		_scroll_zones.append({"rect": rect, "key": scroll_key, "max": max_scroll})

	var y: float = row_top + 21.0
	var drawn: int = 0
	for i in range(offset, min(offset + visible, visible_rows.size())):
		var row: Dictionary = visible_rows[i] as Dictionary
		var cid: int = int(row.get("candidate_id", 0))
		var row_rect: Rect2 = Rect2(rect.position.x + 10.0, y - 19.0, rect.size.x - 20.0, row_h)
		if cid == selected_id:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), Color(BLUE.r, BLUE.g, BLUE.b, 0.45), 6, 1)
		if pitcher_table:
			_draw_candidate_pitcher_row(rect, row, y, cache)
		else:
			_draw_candidate_fielder_row(rect, row, y, cache)
		_row_hits.append({"rect": row_rect, "kind": sel_kind, "meta": cid})
		# 縞の代わりに全行の下へヘアライン区切り (基底 _draw_data_table と同じ表現)。
		_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), HAIRLINE, 1.0)
		drawn += 1
		y += row_h

	# 列グループ境界の縦ヘアライン (識別 / 評価 / 能力 / 変化球・守備適性グリッドの各ブロック境界)。
	var xs: Dictionary = _draft_table_x(rect, pitcher_table)
	var ability_r: float = float(xs["velo_r"]) if pitcher_table else float(xs["meet_r"])
	var sep_xs: Array = [float(xs["eval_r"]) - 44.0 - 10.0, ability_r - 56.0 - 10.0, float(xs["block_x"]) - 10.0]
	var band_top: float = hy - 18.0
	var rows_bottom: float = row_top + float(drawn) * row_h
	for sep_x in sep_xs:
		_line(Vector2(sep_x, band_top), Vector2(sep_x, rows_bottom), HAIRLINE, 1.0)

	if max_scroll > 0:
		_text_right("%d / %d" % [min(offset + visible, visible_rows.size()), visible_rows.size()], rect.end.x - 14.0, rect.end.y - 8.0, 10, FAINT, 120.0)


func _draft_table_x(rect: Rect2, pitcher: bool) -> Dictionary:
	var left: float = rect.position.x
	var xs: Dictionary = {
		"badge_x": left + 16.0,
		"rank_r": left + 108.0,
		"name_x": left + 118.0,
		"age_r": left + 270.0,
		"src_x": left + 306.0,
		"eval_r": left + 400.0,
		"grow_r": left + 470.0,
	}
	if pitcher:
		xs["velo_r"] = left + 560.0
		xs["stuff_r"] = left + 646.0
		xs["ctrl_r"] = left + 704.0
		xs["stam_r"] = left + 762.0
		xs["block_x"] = left + 800.0
	else:
		xs["meet_r"] = left + 540.0
		xs["pow_r"] = left + 586.0
		xs["spd_r"] = left + 632.0
		xs["def_r"] = left + 678.0
		xs["arm_r"] = left + 724.0
		xs["eye_r"] = left + 770.0
		xs["block_x"] = left + 810.0
	return xs


# 変化球(8球種) / 守備適性(8守備位置) を列ごとの数値で等幅に並べる
# (選手詳細「能力の変遷」タブと同じ列方式)。is_header=true なら見出し、false なら値。
# entries: 見出しは {label}、値は {value} (int >=0 を表示、負値は "-")。
func _draw_draft_grid_cells(block_x: float, end_x: float, y: float, entries: Array, is_header: bool) -> void:
	var count: int = entries.size()
	if count <= 0:
		return
	var col_w: float = (end_x - block_x) / float(count)
	for i in range(count):
		var entry: Dictionary = entries[i] as Dictionary
		var cx: float = block_x + float(i) * col_w
		if is_header:
			_text(str(entry.get("label", "")), Vector2(cx, y), 11, FAINT, col_w, HORIZONTAL_ALIGNMENT_CENTER)
		else:
			var value: int = int(entry.get("value", -1))
			if value < 0:
				_text("-", Vector2(cx, y), 13, FAINT, col_w, HORIZONTAL_ALIGNMENT_CENTER)
			else:
				_text(str(value), Vector2(cx, y), 13, _grade_color(value), col_w, HORIZONTAL_ALIGNMENT_CENTER)


func _draft_pitch_header_entries() -> Array:
	var entries: Array = []
	for type_value in PSPitchTypes.ALL_TYPES:
		entries.append({"label": PSPitchTypes.display_name(str(type_value))})
	return entries


# 候補の変化球を球種ごとの完成度(表示値)に変換。未習得の球種は -1 ("-")。
func _draft_pitch_value_entries(arsenal: Array) -> Array:
	var mastery_by_type: Dictionary = {}
	for entry_value in arsenal:
		var entry: Dictionary = entry_value as Dictionary
		mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
	var entries: Array = []
	for type_value in PSPitchTypes.ALL_TYPES:
		var type_key: String = str(type_value)
		if mastery_by_type.has(type_key):
			entries.append({"value": PSAbilityScale.z_to_display(float(mastery_by_type[type_key]))})
		else:
			entries.append({"value": -1})
	return entries


func _draft_apt_header_entries() -> Array:
	var entries: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		entries.append({"label": _position_char(pos)})
	return entries


# 守備位置ごとの適性値。未習得 (0) は -1 ("-")。
func _draft_apt_value_entries(aptitudes: Dictionary) -> Array:
	var entries: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		var key: String = str(PSPlayer.POSITION_EXPERIENCE_KEYS.get(pos, ""))
		var apt: int = int(aptitudes.get(key, 0))
		entries.append({"value": apt if apt > 0 else -1})
	return entries


func _draw_candidate_pitcher_header(rect: Rect2, y: float, info1_header: String, info2_header: String) -> void:
	var xs: Dictionary = _draft_table_x(rect, true)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_text("役割", Vector2(float(xs["badge_x"]), y), 11, FAINT, 50.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text("選手", Vector2(float(xs["name_x"]), y), 11, FAINT)
	_text_cell("年齢", float(xs["age_r"]), y, 11, FAINT, 40.0)
	_text(info1_header, Vector2(float(xs["src_x"]), y), 11, FAINT)
	_text_cell("総合", float(xs["eval_r"]), y, 11, FAINT, 44.0)
	_text_cell(info2_header, float(xs["grow_r"]), y, 11, FAINT, 52.0)
	_text_cell("球速", float(xs["velo_r"]), y, 11, FAINT, 56.0)
	_text_cell("球質", float(xs["stuff_r"]), y, 11, FAINT)
	_text_cell("制球", float(xs["ctrl_r"]), y, 11, FAINT)
	_text_cell("持久", float(xs["stam_r"]), y, 11, FAINT, 54.0)
	_draw_draft_grid_cells(float(xs["block_x"]), rect.end.x - 14.0, y, _draft_pitch_header_entries(), true)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


func _draw_candidate_fielder_header(rect: Rect2, y: float, info1_header: String, info2_header: String) -> void:
	var xs: Dictionary = _draft_table_x(rect, false)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_text("守備", Vector2(float(xs["badge_x"]), y), 11, FAINT, 40.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text("選手", Vector2(float(xs["name_x"]), y), 11, FAINT)
	_text_cell("年齢", float(xs["age_r"]), y, 11, FAINT, 40.0)
	_text(info1_header, Vector2(float(xs["src_x"]), y), 11, FAINT)
	_text_cell("総合", float(xs["eval_r"]), y, 11, FAINT, 44.0)
	_text_cell(info2_header, float(xs["grow_r"]), y, 11, FAINT, 52.0)
	_text_cell("巧打", float(xs["meet_r"]), y, 11, FAINT)
	_text_cell("長打", float(xs["pow_r"]), y, 11, FAINT)
	_text_cell("走力", float(xs["spd_r"]), y, 11, FAINT)
	_text_cell("守備", float(xs["def_r"]), y, 11, FAINT)
	_text_cell("肩力", float(xs["arm_r"]), y, 11, FAINT)
	_text_cell("選球", float(xs["eye_r"]), y, 11, FAINT)
	_draw_draft_grid_cells(float(xs["block_x"]), rect.end.x - 14.0, y, _draft_apt_header_entries(), true)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


func _draw_candidate_identity(rect: Rect2, xs: Dictionary, row: Dictionary, y: float) -> void:
	_text_cell("#%d" % int(row.get("rank", 0)), float(xs["rank_r"]), y, 12, FAINT, 40.0)
	_text(str(row.get("name", "")), Vector2(float(xs["name_x"]), y), 13, TEXT, float(xs["age_r"]) - 46.0 - float(xs["name_x"]), HORIZONTAL_ALIGNMENT_LEFT, true)
	_text_cell(str(int(row.get("age", 0))), float(xs["age_r"]), y, 13, MUTED, 40.0)
	_text(str(row.get("info1", "")), Vector2(float(xs["src_x"]), y), 12, MUTED, 80.0)
	var overall: int = int(row.get("overall", 0))
	_text_cell(str(overall), float(xs["eval_r"]), y, 13, _grade_color(overall), 44.0)
	_text_cell(str(row.get("info2", "")), float(xs["grow_r"]), y, 12, row.get("info2_color", MUTED) as Color, 48.0)


func _draw_candidate_pitcher_row(rect: Rect2, row: Dictionary, y: float, cache: Dictionary) -> void:
	var xs: Dictionary = _draft_table_x(rect, true)
	var role: String = str(row.get("role", "starter"))
	_chip(Rect2(float(xs["badge_x"]), y - 16.0, 50.0, 22.0), _role_label(role), _role_color(role), not bool(row.get("is_development", false)))
	_draw_candidate_identity(rect, xs, row, y)
	var record: PSPlayerSeasonRecord = _board_record(cache, int(row.get("candidate_id", 0)), row.get("template", {}) as Dictionary)
	if record != null:
		_draw_velocity_value(PlayerVisibleRatings.pitcher_velocity(record), float(xs["velo_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.pitcher_stuff(record), float(xs["stuff_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.pitcher_control(record), float(xs["ctrl_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.pitcher_stamina(record), float(xs["stam_r"]), y)
	_draw_draft_grid_cells(float(xs["block_x"]), rect.end.x - 14.0, y, _draft_pitch_value_entries(row.get("arsenal", []) as Array), false)


func _draw_candidate_fielder_row(rect: Rect2, row: Dictionary, y: float, cache: Dictionary) -> void:
	var xs: Dictionary = _draft_table_x(rect, false)
	_position_badge(Rect2(float(xs["badge_x"]), y - 16.0, 40.0, 22.0), int(row.get("position", 0)), bool(row.get("is_development", false)))
	_draw_candidate_identity(rect, xs, row, y)
	var record: PSPlayerSeasonRecord = _board_record(cache, int(row.get("candidate_id", 0)), row.get("template", {}) as Dictionary)
	if record != null:
		_draw_rating_value(PlayerVisibleRatings.fielder_contact(record), float(xs["meet_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_power(record), float(xs["pow_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_speed(record), float(xs["spd_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_defense(record), float(xs["def_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_arm(record), float(xs["arm_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_discipline(record), float(xs["eye_r"]), y)
	_draw_draft_grid_cells(float(xs["block_x"]), rect.end.x - 14.0, y, _draft_apt_value_entries(row.get("aptitudes", {}) as Dictionary), false)


# --- 戦力外獲得市場 (戦力外選択と同じ選手表) / FA・外国人 (左リスト + 右詳細) ---

func _draw_released_market_panel() -> void:
	var pitcher_tab: bool = _released_tab == PLAYER_TAB_PITCHER
	_draw_player_record_table(
		BODY,
		_released_status_text,
		_released_player_rows,
		pitcher_tab,
		"released",
		"released_market_%s" % _released_tab,
		"released",
		selected_released_candidate_id,
		"該当する自由契約候補がいません。",
		true,
		false,
		"",
		true
	)


# 外国人契約市場パネル: 自軍の契約切れ (上段・残留提示) と他球団の契約切れ (下段・引き抜き提示)。
# どちらも他画面と同じ選手レコード表 (_draw_player_record_table) を使い、投手/野手タブ (_fgc_tab) で
# 両表を同時に絞り込む (自軍は最大4人と少数だが、投手/野手で成績列が丸ごと変わるため表を分けずには
# 出せない — 契約情報 (現年俸/提示年俸/上限年数/提示状態) は team_mode "fgc_market"/"fgc_market_away"
# が成績列の一部を差し替えて表示する)。年数チップは右上 (_build_fgc_year_chips)、
# 提示/取り下げ/確定/AI一任ボタンは操作ボタン行 (_build_buttons)。
func _draw_foreign_contract_panel() -> void:
	if not _fgc_status_text.is_empty():
		_text(_fgc_status_text, Vector2(INNER_L, BODY.position.y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)
	var pitcher_tab: bool = _fgc_tab == PLAYER_TAB_PITCHER
	var tab_label: String = "投手" if pitcher_tab else "野手"
	var home_rows: Array = _fgc_home_pitcher_rows if pitcher_tab else _fgc_home_fielder_rows
	var away_rows: Array = _fgc_away_pitcher_rows if pitcher_tab else _fgc_away_fielder_rows
	_draw_player_record_table(FGC_HOME_RECT, "自軍の契約切れ外国人 %s %d人" % [tab_label, home_rows.size()], home_rows,
		pitcher_tab, "fgc", "fgc_home_%s" % _fgc_tab, "", selected_fgc_player_id,
		"自軍に契約切れの外国人はいません。", false, false, "fgc_market", true, true)
	_draw_player_record_table(FGC_AWAY_RECT, "他球団の契約切れ外国人 (引き抜き候補) %s %d人" % [tab_label, away_rows.size()], away_rows,
		pitcher_tab, "fgc", "fgc_away_%s" % _fgc_tab, "", selected_fgc_player_id,
		"該当する引き抜き候補がいません。", true, false, "fgc_market_away", true, true)


# 契約市場エントリ (未解決) を選手レコード表の行モデルへ変換する。契約情報 (現年俸/提示年俸/
# 上限年数/提示状態) を entry へ積み、team_mode "fgc_market"/"fgc_market_away" (_draw_pitcher_table_header
# 等) がこれらの値で FIP/盗塁・WHIP/OAA 相当の枠を差し替えて描画する。入力の並び順 (契約市場サービスの
# value 降順) をそのまま保つため、他の結果行生成関数と異なり再ソートしない。
func _fgc_market_player_rows(entries: Array) -> Array:
	var rows: Array = []
	for row in entries:
		var entry: Dictionary = row as Dictionary
		var pid: int = int(entry.get("player_id", 0))
		var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
		if record == null:
			continue
		var player: PSPlayer = GameDb.get_player(pid)
		# 列は [年数][提示年俸] を前方に隣接させ、現年俸は後方へ回す (現年俸×最長年数で契約する誤読を避ける)。
		# 年数/提示年俸は提示済みならその内容、未提示なら既定 (1年 × 市場価値) の提案プレビューを出す。
		var offer: Dictionary = entry.get("user_offer", {}) as Dictionary
		var has_offer: bool = not offer.is_empty()
		var years_display: int = int(offer.get("years", 1)) if has_offer else 1
		var offer_salary_value: int = int(offer.get("salary", 0)) if has_offer else int(entry.get("market_salary", 0))
		var current_salary: int = player.salary if player != null else 0
		var row_entry: Dictionary = {
			"player_id": pid,
			"team_id": int(entry.get("from_team_id", 0)),
			"position": int(entry.get("position", record.position)),
			"role": str(entry.get("role", record.role)),
			"salary": current_salary,
			"fgc_years": years_display,
			"market_salary_text": _format_money_compact(offer_salary_value),
			"fgc_current_salary_text": _format_money_compact(current_salary),
			"offer_text": "提示中" if has_offer else "未提示",
			"offer_color": BLUE if has_offer else FAINT,
		}
		rows.append({"record": record, "player": player, "entry": row_entry})
	return rows


# 契約年数の決定パネル。自軍候補のみの1表 (投手/野手タブ)。他画面と同じ選手レコード表を使い、
# 契約情報 (年数/基準年俸/区分/現年俸) は team_mode "contract_years" が成績列の一部を差し替えて出す。
# 年数チップは右上 (_build_cy_year_chips)。
func _draw_contract_years_panel() -> void:
	if not _cy_status_text.is_empty():
		_text(_cy_status_text, Vector2(INNER_L, BODY.position.y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)
	var pitcher_tab: bool = _cy_tab == PLAYER_TAB_PITCHER
	var rows: Array = _cy_pitcher_rows if pitcher_tab else _cy_fielder_rows
	var title: String = "契約年数の対象 %s %d人" % ["投手" if pitcher_tab else "野手", rows.size()]
	_draw_player_record_table(CY_BODY_RECT, title, rows, pitcher_tab, "cy", "cy_%s" % _cy_tab, "",
		selected_cy_player_id, "契約年数を決める選手がいません。", true, false, "contract_years", true, true)


# 外国人補強パネル: 条件指定3行とスカウト候補4人。能力値はスカウト推定値を表示する。
func _draw_foreign_panel() -> void:
	var status_y: float = BODY.position.y
	if not _foreign_status_text.is_empty():
		_text(_foreign_status_text, Vector2(INNER_L, status_y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("守備・役割", Vector2(INNER_L, status_y + 58.0), 13, MUTED, 100)
	_text("選手タイプ", Vector2(INNER_L, status_y + 100.0), 13, MUTED, 100)
	_text("予算帯", Vector2(INNER_L, status_y + 142.0), 13, MUTED, 100)
	var selected: Dictionary = _foreign_by_id.get(selected_foreign_candidate_id, {}) as Dictionary
	if not selected.is_empty():
		_text("推定総合 %d〜%d　%s" % [int(selected.get("estimate_min", 0)), int(selected.get("estimate_max", 0)), str(selected.get("scout_comment", ""))],
			Vector2(INNER_L, status_y + 182.0), 13, MUTED, 1420, HORIZONTAL_ALIGNMENT_LEFT, true)
		_text(_foreign_ability_range_text(selected), Vector2(INNER_L, status_y + 204.0), 13, MUTED, 1500, HORIZONTAL_ALIGNMENT_LEFT, true)
	var table_top: float = status_y + 224.0
	var board_tab: String = _foreign_board_tab()
	_draw_candidate_board(Rect2(INNER_L, table_top, BODY.size.x, BODY.end.y - table_top),
		_foreign_candidate_rows, board_tab, selected_foreign_candidate_id, "foreign", _foreign_record_cache, "タイプ", "年俸")


# --- キャンプ ---

func _draw_camp_panel() -> void:
	# 上段: ドラフトと同じ候補ボード (状況テキスト + タブ + ボード)。
	var status_y: float = BODY.position.y
	if not _camp_status_text.is_empty():
		_text(_camp_status_text, Vector2(INNER_L, status_y + 4.0), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)
	_draw_candidate_board(CAMP_BOARD, _camp_candidate_rows, _camp_tab, selected_camp_player_id, "camp", _camp_record_cache, "", "")
	# 下段: 特別練習メニュー / 成功率 / 成功時獲得適性値。
	_draw_camp_menu_panel()
	_draw_camp_rate_panel()
	_draw_camp_apt_panel()


# 特別練習メニュー (練習種別 / 対象位置のチップ)。チップ本体は _build_camp_chips がボタンで重ね描く。
func _draw_camp_menu_panel() -> void:
	_panel(CAMP_MENU, "特別練習メニュー")
	if selected_camp_player_id <= 0 or _camp_types.is_empty():
		_draw_text_lines(CAMP_MENU.position.x + 16, CAMP_MENU.position.y + 58, CAMP_MENU.size.x - 32, _camp_detail_text, 13, MUTED)
		return
	_text("練習種別", Vector2(CAMP_MENU.position.x + 16, CAMP_MENU.position.y + 60), 11, FAINT)
	if not _camp_positions.is_empty():
		_text("対象位置", Vector2(CAMP_MENU.position.x + 16, CAMP_MENU.position.y + 130), 11, FAINT)


# 成功率パネル。
func _draw_camp_rate_panel() -> void:
	_panel(CAMP_RATE, "成功率")
	if _camp_selected_option.is_empty():
		_text("選手と特別練習を選択してください。", Vector2(CAMP_RATE.position.x + 16, CAMP_RATE.position.y + 60), 13, MUTED, CAMP_RATE.size.x - 32)
		return
	var opt: Dictionary = _camp_selected_option
	var pct: float = float(opt.get("success_chance", 0.0)) * 100.0
	_text("%0.1f%%" % pct, Vector2(CAMP_RATE.position.x + 16, CAMP_RATE.position.y + 92), 38, _camp_rate_color(pct))
	_text("リスク %s" % str(opt.get("risk_label", "中")), Vector2(CAMP_RATE.position.x + 180, CAMP_RATE.position.y + 80), 14, MUTED)
	_text("練習: %s" % str(opt.get("training_label", "")), Vector2(CAMP_RATE.position.x + 16, CAMP_RATE.position.y + 126), 13, TEXT, CAMP_RATE.size.x - 32)
	_text("対象: %s" % _camp_training_target(opt), Vector2(CAMP_RATE.position.x + 16, CAMP_RATE.position.y + 148), 13, TEXT, CAMP_RATE.size.x - 32)
	_draw_text_lines(CAMP_RATE.position.x + 16, CAMP_RATE.position.y + 166, CAMP_RATE.size.x - 32, "理由: %s" % str(opt.get("reason", "")), 12, MUTED)


# 成功時獲得適性値パネル (守備適性が対象の練習のみ数値を出す)。
func _draw_camp_apt_panel() -> void:
	_panel(CAMP_APT, "成功時獲得適性値")
	if _camp_selected_option.is_empty():
		_text("選手と特別練習を選択してください。", Vector2(CAMP_APT.position.x + 16, CAMP_APT.position.y + 60), 13, MUTED, CAMP_APT.size.x - 32)
		return
	var opt: Dictionary = _camp_selected_option
	var target_position: int = int(opt.get("target_position", 0))
	if target_position <= 0:
		_text("この練習は守備適性の対象ではありません。", Vector2(CAMP_APT.position.x + 16, CAMP_APT.position.y + 60), 13, MUTED, CAMP_APT.size.x - 32)
		var tgt: String = _camp_training_target(opt)
		if not tgt.is_empty():
			_text("対象: %s" % tgt, Vector2(CAMP_APT.position.x + 16, CAMP_APT.position.y + 92), 14, TEXT)
		return
	var player: PSPlayer = GameDb.get_player(int(opt.get("player_id", 0)))
	var current: int = _player_position_aptitude_for_ui(player, target_position)
	var projected: int = int(opt.get("projected_aptitude", 0))
	var gain: int = projected - current
	var px: float = CAMP_APT.position.x + 16
	_text("対象守備位置: %s" % _position_name(target_position), Vector2(px, CAMP_APT.position.y + 58), 13, MUTED)
	_text("現在", Vector2(px, CAMP_APT.position.y + 92), 12, FAINT)
	_text(str(current), Vector2(px, CAMP_APT.position.y + 128), 30, TEXT)
	_text("成功時", Vector2(px + 190, CAMP_APT.position.y + 92), 12, FAINT)
	_text(str(projected), Vector2(px + 190, CAMP_APT.position.y + 128), 30, _grade_color(projected) if gain >= 0 else RED)
	if gain != 0:
		_text("(%+d)" % gain, Vector2(px + 300, CAMP_APT.position.y + 124), 18, GREEN if gain > 0 else RED)


func _camp_rate_color(pct: float) -> Color:
	if pct >= 70.0:
		return GREEN
	if pct >= 45.0:
		return AMBER
	return RED


# ============================================================ results draw

func _draw_results(rect: Rect2) -> void:
	var step: String = str(_view.get("step", ""))
	var result: Dictionary = _view.get("result", {}) as Dictionary
	if result.is_empty():
		_text(str(_view.get("status", "結果データがありません")), Vector2(rect.position.x, rect.position.y + 24), 16, MUTED)
		return
	match step:
		AppState.OFFSEASON_STEP_FA_DECLARATION:
			_draw_fa_declaration_result(rect, result)
		AppState.OFFSEASON_STEP_RETIREMENT:
			_draw_people_result(rect, "引退した選手", result, "retired", "今オフは引退者がいませんでした。")
		AppState.OFFSEASON_STEP_CONTRACT_YEARS:
			_draw_contract_years_result(rect, result)
		AppState.OFFSEASON_STEP_RELEASE_COMMIT:
			_draw_release_result(rect, result)
		AppState.OFFSEASON_STEP_DRAFT_MAIN:
			if result.has("draft_picks"):
				_draw_draft_result(rect, result)
			else:
				_draw_rookies_result(rect, result)
		AppState.OFFSEASON_STEP_DRAFT_DEVELOPMENT:
			_draw_draft_result(rect, result)
		AppState.OFFSEASON_STEP_RELEASED_MARKET:
			_draw_released_result(rect, result)
		AppState.OFFSEASON_STEP_GENEKI_DRAFT:
			_draw_geneki_result(rect, result)
		AppState.OFFSEASON_STEP_FA_MARKET:
			_draw_fa_result(rect, result)
		AppState.OFFSEASON_STEP_FOREIGN_MARKET:
			_draw_foreign_result(rect, result)
		AppState.OFFSEASON_STEP_CAMP:
			_draw_camp_result(rect, result)
		AppState.OFFSEASON_STEP_GROWTH:
			_draw_growth_result(rect, result)
		AppState.OFFSEASON_STEP_CONTRACT_RENEWAL:
			_draw_contract_result(rect, result)


func _draw_people_result(rect: Rect2, title_text: String, result: Dictionary, key: String, empty_text: String) -> void:
	var people: Array = result.get(key, []) as Array
	var table_rect: Rect2 = rect
	if result.has("budgets"):
		table_rect = _draw_budget_recompute_summary(rect, result.get("budgets", {}) as Dictionary)
	_draw_people_player_table(table_rect, "%s %d人" % [title_text, people.size()], people, _result_people_tab, key == "retired", empty_text, "result", true, true)


# 年次予算再計算の結果 (TeamFinance.recompute_annual_budgets の戻り値) を1行+12球団表で表示し、
# 残り高さを持つ縮小後の rect を返す (下段の表描画に使う)。消費高さは BUDGET_SUMMARY_BLOCK_H と
# 一致させること (_build_result_people_tabs がタブをこの分だけ下げて重なりを避ける)。
func _draw_budget_recompute_summary(rect: Rect2, budgets: Dictionary) -> Rect2:
	var rows: Array = budgets.get("team_budgets", []) as Array
	if rows.is_empty():
		return rect
	var user_team_id: int = AppState.selected_team_id
	var user_row: Dictionary = {}
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("team_id", 0)) == user_team_id:
			user_row = row
			break
	var y: float = rect.position.y
	if not user_row.is_empty():
		var bonus: int = int(user_row.get("rank_bonus", 0)) + int(user_row.get("league_champion_bonus", 0)) + int(user_row.get("japan_champion_bonus", 0))
		var line: String = "予算改定: ベース%s + 順位(%d位)ボーナス%s → 新予算 %s (年俸総額 %s / 残額 %s)" % [
			_format_money(int(user_row.get("base", 0))), int(user_row.get("rank", 0)), _format_money(bonus),
			_format_money(int(user_row.get("funds", 0))), _format_money(int(user_row.get("payroll", 0))),
			_format_money(int(user_row.get("room", 0))),
		]
		_text(line, Vector2(rect.position.x, y + 16.0), 14, AMBER if bool(user_row.get("over_budget", false)) else TEXT, rect.size.x, HORIZONTAL_ALIGNMENT_LEFT, true)
		y += 28.0

	rows = rows.duplicate()
	rows.sort_custom(func(a, b) -> bool: return int((a as Dictionary).get("team_id", 0)) < int((b as Dictionary).get("team_id", 0)))
	var col_w: float = rect.size.x / float(rows.size())
	var cy: float = y + 18.0
	for i in range(rows.size()):
		var row: Dictionary = rows[i] as Dictionary
		var cx: float = rect.position.x + float(i) * col_w
		var is_self: bool = int(row.get("team_id", 0)) == user_team_id
		var color: Color = BLUE if is_self else (AMBER if bool(row.get("over_budget", false)) else MUTED)
		var team: PSTeam = GameDb.get_team(int(row.get("team_id", 0)))
		var short_name: String = team.short_name if team != null else str(row.get("name", ""))
		_text("%s %d位 %s" % [short_name, int(row.get("rank", 0)), _format_money_compact(int(row.get("funds", 0)))], Vector2(cx, cy), 11, color, col_w - 6.0)
	y = cy + 20.0

	return Rect2(rect.position.x, y, rect.size.x, rect.end.y - y)


func _draw_release_result(rect: Rect2, result: Dictionary) -> void:
	var released: Array = result.get("released", []) as Array
	var user_n: int = int(result.get("user_released_count", -1))
	var cpu_n: int = int(result.get("cpu_released_count", -1))
	var foreign_n: int = int(result.get("foreign_released_count", 0))
	var heading: String = "戦力外通告: %d人" % released.size()
	if user_n >= 0 and cpu_n >= 0:
		heading = "戦力外通告: %d人 (自軍%d人 / 他球団 %d人 / 外国人 %d人)" % [released.size(), user_n, cpu_n, foreign_n]
	var demoted: Array = result.get("demoted", []) as Array
	if demoted.is_empty():
		_draw_people_player_table(rect, heading, released, _result_people_tab, false, "今オフは戦力外通告がありませんでした。", "result", true, true)
		return
	# 戦力外 + 育成降格 を上下2枚で。
	var half: float = (rect.size.y - 50.0) / 2.0
	_draw_people_player_table(Rect2(rect.position.x, rect.position.y, rect.size.x, half + 50.0), heading, released, _result_people_tab, false, "今オフは戦力外通告がありませんでした。", "result", true, true)
	var user_d: int = int(result.get("user_demoted_count", 0))
	var cpu_d: int = int(result.get("cpu_demoted_count", 0))
	var lower: Rect2 = Rect2(rect.position.x, rect.position.y + half + 56.0, rect.size.x, half - 6.0)
	_draw_people_player_table(lower, "育成降格: %d人 (自軍%d人 / 他球団 %d人)" % [demoted.size(), user_d, cpu_d], demoted, _result_people_tab, false, "", "result2", false, true)


func _draw_rookies_result(rect: Rect2, result: Dictionary) -> void:
	var rookies: Array = result.get("rookies", []) as Array
	var rows: Array = []
	for entry_row in rookies:
		var entry: Dictionary = entry_row as Dictionary
		var badge: Dictionary = _pick_pos_badge(entry)
		rows.append({
			"team": _team_short(int(entry.get("team_id", 0))),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"pos": str(badge.get("text", "")),
			"pos_color": badge.get("color", MUTED) as Color,
			"pos_dev": bool(entry.get("development_player", entry.get("development", false))),
			"overall": int(entry.get("overall", 0)),
		})
	_heading_table(rect, "新人補強: %d人" % rookies.size(), ROOKIE_COLUMNS, rows, "補強の候補がありませんでした。", "result")


func _draw_released_result(rect: Rect2, result: Dictionary) -> void:
	var heading: String = "戦力外獲得: 候補 %d人 / 獲得 %d人 / 未獲得 %d人" % [
		int(result.get("candidates_count", 0)), int(result.get("signed_count", 0)), int(result.get("remaining_count", 0)),
	]
	_draw_player_record_table(rect, heading, _result_signing_player_rows(result.get("signings", []) as Array),
		_result_people_tab == PLAYER_TAB_PITCHER, "", "released_result_%s" % _result_people_tab, "", 0,
		"今オフは戦力外からの獲得がありませんでした。", true, false, "move", true)


func _draw_geneki_result(rect: Rect2, result: Dictionary) -> void:
	var heading: String = "現役ドラフト: 移籍 %d人 (1巡目 %d / 2巡目 %d) — 自軍 獲得%d / 放出%d" % [
		int(result.get("moved_count", 0)), int(result.get("round1_count", 0)), int(result.get("round2_count", 0)),
		int(result.get("user_gained", 0)), int(result.get("user_lost", 0)),
	]
	_draw_player_record_table(rect, heading, _result_signing_player_rows(result.get("moves", []) as Array),
		_result_people_tab == PLAYER_TAB_PITCHER, "", "geneki_result_%s" % _result_people_tab, "", 0,
		"現役ドラフトでの移籍はありませんでした。", true, false, "move", true)


func _draw_fa_result(rect: Rect2, result: Dictionary) -> void:
	var heading: String = "FA市場: 宣言 %d人 / 移籍 %d人 / 残留 %d人" % [
		int(result.get("declared_count", 0)), int(result.get("moved_count", 0)), int(result.get("returned_count", 0)),
	]
	# team_mode "fa_result": "move" と同じ球団列レイアウト + 年俸の隣に契約年数列 (_has_contract_years_column)。
	_draw_player_record_table(rect, heading, _result_signing_player_rows(result.get("signings", []) as Array),
		_result_people_tab == PLAYER_TAB_PITCHER, "", "fa_result_%s" % _result_people_tab, "", 0,
		"今オフは FA 移籍が成立しませんでした。", true, false, "fa_result", true)


func _draw_foreign_result(rect: Rect2, result: Dictionary) -> void:
	# ステップ完了後のレビューはスカウト獲得 (新外国人) のみを出す。契約市場の結果 (残留/移籍/退団) は
	# 専用フェーズ (contract_result パネル) で表示済みなので、ここで合算して二重に見せない。
	var scout_rows: Array = _result_signing_player_rows(result.get("signings", []) as Array)
	var pitcher_table: bool = _result_people_tab == PLAYER_TAB_PITCHER
	var heading: String = "外国人スカウト獲得: 候補 %d人 / 獲得 %d人" % [int(result.get("candidates_count", 0)), int(result.get("signed_count", 0))]
	_draw_player_record_table(rect, heading, scout_rows, pitcher_table, "", "foreign_result_%s" % _result_people_tab, "", 0,
		"今オフはスカウトからの獲得がありませんでした。", true, false, "team")


# 契約市場結果 (contract_signings) を結果表の署名行モデルへ変換する。契約年数と去就ラベルを補う。
# 退団は to_team=0 (移籍先は "-" 表示) かつ契約年数なし。
func _fgc_result_entries(result: Dictionary) -> Array:
	var entries: Array = []
	for row in result.get("contract_signings", []) as Array:
		var entry: Dictionary = (row as Dictionary).duplicate(true)
		entry["contract_years"] = int(entry.get("years", 0))
		match str(entry.get("outcome", "")):
			"retained":
				entry["outcome_label"] = "残留"
				entry["outcome_color"] = TEXT
			"poached":
				entry["outcome_label"] = "移籍"
				entry["outcome_color"] = AMBER
			_:
				entry["outcome_label"] = "退団"
				entry["outcome_color"] = MUTED
		entries.append(entry)
	return entries


func _draw_camp_result(rect: Rect2, result: Dictionary) -> void:
	# 成長と同じ候補タブ (投手/先発/中継/野手/各守備位置) で絞り込む。タブ行は _build_step_result_tabs が rect.y+30 に描く。
	var pitcher_table: bool = _candidate_tab_is_pitcher(_camp_result_tab)
	var actions: Array = _candidate_rows_for_tab(_camp_result_entries(), _camp_result_tab)
	_text("キャンプ結果: 特別練習 %d件 / 通常球種習得 %d人" % [
		(result.get("actions", []) as Array).size(), int(result.get("normal_pitch_learning_count", 0)),
	], Vector2(rect.position.x, rect.position.y + 4), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)

	# 通常キャンプの球種習得は投手系タブのときだけ下段に出す。
	var pitch_rows: Array = []
	if pitcher_table:
		for pitch_row in result.get("normal_pitch_learning", []) as Array:
			var pitch: Dictionary = pitch_row as Dictionary
			var row: Dictionary = {
				"team": _team_short(int(pitch.get("team_id", 0))),
				"color": _team_color(int(pitch.get("team_id", 0))),
				"name": str(pitch.get("name", "")),
				"age": int(pitch.get("age", 0)),
				"pitch": str(pitch.get("pitch_name", "")),
				"grade": str(pitch.get("mastery_grade", "")),
			}
			_fill_result_ability_cells(row, pitch)
			pitch_rows.append(row)

	var content_top: float = rect.position.y + 68.0
	var content_h: float = rect.end.y - content_top
	var action_title: String = "%s の特別練習 %d件" % ["投手" if pitcher_table else "野手", actions.size()]
	if pitch_rows.is_empty():
		_draw_table_inner(Rect2(rect.position.x, content_top, rect.size.x, content_h), action_title, _camp_result_columns(pitcher_table), _camp_action_rows(actions), "camp_res_%s" % _camp_result_tab, "", 0, true)
		if actions.is_empty():
			_text("該当する特別練習がありません。", Vector2(rect.position.x + 18, content_top + 64), 14, MUTED)
		return
	var top_h: float = content_h * 0.66
	_draw_table_inner(Rect2(rect.position.x, content_top, rect.size.x, top_h), action_title, _camp_result_columns(pitcher_table), _camp_action_rows(actions), "camp_res_%s" % _camp_result_tab, "", 0, true)
	_draw_table_inner(Rect2(rect.position.x, content_top + top_h + 10.0, rect.size.x, content_h - top_h - 10.0), "通常キャンプ球種習得 %d人" % pitch_rows.size(), CAMP_PITCH_COLUMNS, pitch_rows, "camp_res_pitch", "", 0, true)


# キャンプ特別練習アクションを能力変動表の行に変換 (成長と同じ能力セル + キャンプ固有列)。
func _camp_action_rows(actions: Array) -> Array:
	var rows: Array = []
	for action_row in actions:
		var action: Dictionary = action_row as Dictionary
		var before: int = int(action.get("before", 0))
		var after: int = int(action.get("after", 0))
		var team_id: int = int(action.get("team_id", 0))
		var change_pair: Dictionary = _camp_action_change_pair(action)
		var row: Dictionary = {
			"team": _team_short(team_id),
			"color": _team_color(team_id),
			"name": str(action.get("name", "")),
			"age": int(action.get("age", 0)),
			"training": str(action.get("training_label", "")),
			"result": "成功" if bool(action.get("success", false)) else ("失敗*" if bool(action.get("penalty", false)) else "失敗"),
			"result_color": _camp_result_color(action),
			"before_state": str(change_pair.get("before", "")),
			"before_state_color": change_pair.get("before_color", MUTED) as Color,
			"after_state": str(change_pair.get("after", "")),
			"after_state_color": change_pair.get("after_color", MUTED) as Color,
		}
		_set_growth_cell(row, "overall_cell", {"after": after, "delta": after - before, "suffix": ""})
		for ability_row in action.get("abilities", []) as Array:
			var ability: Dictionary = ability_row as Dictionary
			_set_growth_cell(row, str(ability.get("key", "")), {
				"after": int(ability.get("after", 0)),
				"delta": int(ability.get("delta", 0)),
				"suffix": str(ability.get("suffix", "")),
			})
		_fill_growth_detail_cells(row, action)
		_fill_camp_aptitude_cells(row, action)
		rows.append(row)
	return rows


func _draw_growth_result(rect: Rect2, result: Dictionary) -> void:
	# 一覧はドラフトと同じ候補タブ (投手/先発/中継/野手/各守備位置) で切り替える1枚の表。
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var team_name: String = team.short_name if team != null else ""
	var heading: String = "%s の成長 %d人 / 衰え %d人" % [team_name, int(result.get("growers_count", 0)), int(result.get("decayers_count", 0))]
	_text(heading, Vector2(rect.position.x, rect.position.y + 4), 15, TEXT, 1240, HORIZONTAL_ALIGNMENT_LEFT, true)
	var kind_counts: Dictionary = result.get("growth_kind_counts", {}) as Dictionary
	if not kind_counts.is_empty():
		_text_right("覚醒 %d  成長 %d  停滞 %d  劣化 %d  大幅劣化 %d" % [
			int(kind_counts.get("awakening", 0)), int(kind_counts.get("growth", 0)), int(kind_counts.get("stagnation", 0)),
			int(kind_counts.get("decline", 0)), int(kind_counts.get("major_decline", 0)),
		], rect.end.x, rect.position.y + 6, 13, MUTED, 700.0)

	# タブ行は _build_step_result_tabs が rect.y + 30 にボタンで重ねる。
	var entries: Array = _candidate_rows_for_tab(_growth_board_entries(), _growth_tab)
	var pitcher_table: bool = _candidate_tab_is_pitcher(_growth_tab)
	var columns: Array = _growth_columns(pitcher_table)
	var title: String = "%s %d人" % ["投手" if pitcher_table else "野手", entries.size()]
	var table_top: float = rect.position.y + 68.0
	_draw_table_inner(Rect2(rect.position.x, table_top, rect.size.x, rect.end.y - table_top),
		title, columns, _growth_rows(entries), "growth_board_%s" % _growth_tab, "", 0, true)


# 契約更改: 自チームの全選手の新年俸一覧 (投手/野手タブ・今季成績付き)。戦力外/FA と同じレコード表を
# 全高で1表だけ描く (複数年契約の年数は直前の「契約年数」ステップが決めるので、ここは年俸だけ)。
func _draw_contract_result(rect: Rect2, result: Dictionary) -> void:
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var team_name: String = team.short_name if team != null else ""
	var heading: String = "%s 契約更改 (昇給 %d / 減給 %d / 予算超過球団 %d)" % [
		team_name, int(result.get("raises_count", 0)), int(result.get("cuts_count", 0)),
		int(result.get("over_budget_count", 0)),
	]
	# タブ行 (投手/野手) は _build_step_result_tabs が BODY 左上に重ねる。
	_draw_player_record_table(rect, heading, _contract_player_rows(result), _contract_tab == PLAYER_TAB_PITCHER,
		"", "contract_%s" % _contract_tab, "", 0, "自チームの選手記録がありません。", true, false, "contract")


# 契約年数: 成立した複数年契約の一覧 (全球団)。単年は一覧に出さない (件数のみ見出しに出す)。
func _draw_contract_years_result(rect: Rect2, result: Dictionary) -> void:
	var multi_year: Array = result.get("multi_year_signings", []) as Array
	var heading: String = "契約年数 (対象 %d人 / 複数年契約 %d件)" % [
		int(result.get("decided_count", 0)), int(result.get("multi_year_count", 0)),
	]
	_draw_player_record_table(rect, heading, _result_signing_player_rows(multi_year), _result_people_tab == PLAYER_TAB_PITCHER,
		"", "contract_years_result_%s" % _result_people_tab, "", 0, "今オフは複数年契約が成立しませんでした。",
		true, false, "contract_years_result", true)


# FA宣言: FA権保有者と、その選手が宣言したか残留したかの一覧 (全球団)。表示専用。
# 他画面と同じ選手レコード表を使い、権利/去就は team_mode "fa_declaration" が FIP(盗塁)/WHIP(OAA)
# 相当の枠を差し替えて出す。残留 (=今オフ動かない) 選手は行ごとグレーアウトする。
func _draw_fa_declaration_result(rect: Rect2, result: Dictionary) -> void:
	var pitcher_table: bool = _fa_declaration_tab == PLAYER_TAB_PITCHER
	var rows: Array = []
	for row_value in result.get("entries", []) as Array:
		var row: Dictionary = _fa_declaration_row(row_value as Dictionary)
		if not row.is_empty():
			rows.append(row)
	var heading: String = "FA権保有者 %d人 / 宣言 %d人 (うち今オフ新規取得 %d人)" % [
		int(result.get("holder_count", 0)), int(result.get("declared_count", 0)), int(result.get("new_fa_count", 0)),
	]
	_draw_player_record_table(rect, heading, rows, pitcher_table, "", "fa_decl_%s" % _fa_declaration_tab, "",
		0, "FA権を持つ選手がいません。", true, false, "fa_declaration", true)


func _fa_declaration_row(entry: Dictionary) -> Dictionary:
	var pid: int = int(entry.get("player_id", 0))
	var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
	if record == null:
		return {}
	var declared: bool = bool(entry.get("declared", false))
	var row_entry: Dictionary = {
		"player_id": pid,
		"team_id": int(entry.get("team_id", 0)),
		"position": int(entry.get("position", record.position)),
		"role": str(entry.get("role", record.role)),
		"salary": int(entry.get("salary", record.salary)),
		"offer_text": "新規取得" if bool(entry.get("is_new_fa", false)) else "保有%d年目" % (int(entry.get("fa_pass_count", 0)) + 1),
		"offer_color": BLUE if bool(entry.get("is_new_fa", false)) else MUTED,
		"outcome_label": "宣言" if declared else "残留",
		"outcome_color": AMBER if declared else MUTED,
	}
	return {"record": record, "player": GameDb.get_player(pid), "entry": row_entry, "__dim": not declared}


func _entry_pitcher_fielder_counts(entries: Array) -> Dictionary:
	var counts: Dictionary = {PLAYER_TAB_PITCHER: 0, PLAYER_TAB_FIELDER: 0}
	for row_value in entries:
		var key: String = PLAYER_TAB_PITCHER if int((row_value as Dictionary).get("position", 0)) == 1 else PLAYER_TAB_FIELDER
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


func _set_fa_declaration_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _fa_declaration_tab == tab_id:
		return
	_fa_declaration_tab = tab_id
	_build_buttons()
	queue_redraw()


func _draw_draft_result(rect: Rect2, result: Dictionary) -> void:
	var picks: Array = result.get("draft_picks", []) as Array
	var rookies: Array = result.get("rookies", []) as Array
	var title_text: String = str(result.get("title", "ドラフト"))
	_text("%s終了 指名%d人 / 入団%d人" % [title_text, picks.size(), rookies.size()], Vector2(rect.position.x, rect.position.y + 26), 20, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text_right("同順位優先リーグ: %s" % _league_label(str(result.get("priority_league", ""))), rect.end.x, rect.position.y + 24, 14, MUTED, 320.0)

	var content_top: float = rect.position.y + 52.0

	# 1巡目 抽選結果も表パネルに (テキスト羅列をやめる)。
	var lottery_rows: Array = []
	for log_row in result.get("logs", []) as Array:
		var log: Dictionary = log_row as Dictionary
		if str(log.get("type", "")) == "lottery":
			lottery_rows.append(_lottery_row(log))
	if not lottery_rows.is_empty():
		var lottery_h: float = min(64.0 + float(lottery_rows.size()) * 28.0, 220.0)
		_draw_table_inner(Rect2(rect.position.x, content_top, rect.size.x, lottery_h), "1巡目 抽選", LOTTERY_COLUMNS, lottery_rows, "draft_result_lottery", "", 0, true, 15, 28.0)
		content_top += lottery_h + 14.0

	_draw_picks_team_grid(Rect2(rect.position.x, content_top, rect.size.x, rect.end.y - content_top), picks, "alpha")


# 指名選手をセ/パ2段×球団別グリッドで描く (結果画面・進行中の途中経過ビューで共用)。
# order_mode で球団列の並びを選ぶ:
#   "alpha" = short_name 昇順 (結果画面)。
#   "rank"  = 今年度の順位順 1位→6位 (途中経過ビュー。_league_team_ids_draft_order が
#             下位→上位を返すので reverse する。draft_state が空なら team_id 降順に相当)。
func _draw_picks_team_grid(area: Rect2, picks: Array, order_mode: String = "alpha") -> void:
	var picks_by_team: Dictionary = {}
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		var team_id: int = int(pick.get("team_id", 0))
		if not picks_by_team.has(team_id):
			picks_by_team[team_id] = []
		(picks_by_team[team_id] as Array).append(pick)

	# チーム別 指名選手パネル (2 リーグ行 × 各球団列)。各球団を枠付きパネル + 大きめ行で描く。
	var leagues: Array = ["league1", "league2"]
	var gap: float = 12.0
	var row_h: float = (area.size.y - gap) / 2.0
	# 指名数が最多の球団でも全員が収まるよう行高を決める (18〜30px に収める)。
	var max_picks: int = 1
	for team_picks_value in picks_by_team.values():
		max_picks = max(max_picks, (team_picks_value as Array).size())
	var cell_row_h: float = clampf((row_h - 72.0) / float(max_picks), 18.0, 30.0)
	for li in range(leagues.size()):
		var league: String = str(leagues[li])
		var ids: Array
		if order_mode == "rank":
			ids = _league_team_ids_draft_order(league)
			ids.reverse()
		else:
			ids = _league_team_ids_alpha(league)
		var cell_w: float = (area.size.x - gap * float(max(1, ids.size() - 1))) / float(max(1, ids.size()))
		var ry: float = area.position.y + float(li) * (row_h + gap)
		var cx: float = area.position.x
		for team_id_value in ids:
			var team_id: int = int(team_id_value)
			var team_picks: Array = (picks_by_team.get(team_id, []) as Array).duplicate()
			team_picks.sort_custom(func(a: Variant, b: Variant) -> bool:
				return int((a as Dictionary).get("overall_pick", 0)) < int((b as Dictionary).get("overall_pick", 0))
			)
			var rows: Array = []
			for pick_row in team_picks:
				rows.append(_pick_row(pick_row as Dictionary))
			_draw_table_inner(Rect2(cx, ry, cell_w, row_h), "%s %d人" % [_team_short(team_id), team_picks.size()], DRAFT_RESULT_COLUMNS, rows, "", "", 0, true, 15, cell_row_h)
			cx += cell_w + gap


# 投手/野手を混在させない選手一覧。打順・投手起用法の上段表に寄せた自前描画。
func _draw_player_record_table(rect: Rect2, title: String, source_rows: Array, pitcher_table: bool, sel_kind: String, scroll_key: String, _selection_group: String, selected_id: int, empty_text: String, show_tab_space: bool, career_stats: bool, team_mode: String = "", show_salary: bool = false, show_offer_years: bool = false) -> void:
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	var title_x: float = rect.position.x + (222.0 if show_tab_space else 18.0)
	_round(Rect2(title_x, rect.position.y + 21.0, 3, 14), BLUE, Color.TRANSPARENT, 2, 0)
	_text(title, Vector2(title_x + 9.0, rect.position.y + 34.0), 15, TEXT, rect.end.x - title_x - 9.0 - 18.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var rows: Array = []
	for row_value in source_rows:
		var model: Dictionary = _player_row_model(row_value)
		var record: PSPlayerSeasonRecord = model.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher() == pitcher_table:
			rows.append(model)

	var effective_team_mode: String = team_mode
	if effective_team_mode.is_empty() and _rows_include_multiple_teams(rows):
		effective_team_mode = "team"
	var table_gap: float = 14.0 if show_tab_space else 0.0
	var hy: float = rect.position.y + 64.0 + table_gap
	if pitcher_table:
		_draw_pitcher_table_header(rect, hy, effective_team_mode, career_stats, show_salary, show_offer_years)
	else:
		_draw_fielder_table_header(rect, hy, effective_team_mode, career_stats, show_salary, show_offer_years)

	if rows.is_empty():
		if not empty_text.is_empty():
			_text(empty_text, Vector2(rect.position.x + 18.0, rect.position.y + 116.0 + table_gap), 14, MUTED)
		return

	var row_h: float = 27.0
	var row_top: float = rect.position.y + 94.0 + table_gap
	var bottom: float = rect.end.y - 12.0
	var visible: int = max(1, int((bottom - row_top) / row_h))
	var max_scroll: int = max(0, rows.size() - visible)
	var offset: int = clampi(int(_scroll.get(scroll_key, 0)), 0, max_scroll)
	_scroll[scroll_key] = offset
	if max_scroll > 0:
		_scroll_zones.append({"rect": rect, "key": scroll_key, "max": max_scroll})

	var y: float = row_top + 21.0
	var drawn: int = 0
	for i in range(offset, min(offset + visible, rows.size())):
		var row: Dictionary = rows[i] as Dictionary
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		var row_rect: Rect2 = Rect2(rect.position.x + 10.0, y - 19.0, rect.size.x - 20.0, row_h)
		var state: String = ""
		if sel_kind == "release":
			state = _release_state(record.player_id)
		elif sel_kind == "geneki_list" and selected_geneki_list_ids.has(record.player_id):
			# リスト入り選手は戦力外選択と同じ強調色で示す (放出候補という意味合いが同じ)。
			state = "release"
		var selected: bool = sel_kind != "release" and sel_kind != "geneki_list" and selected_id > 0 and record.player_id == selected_id
		if state == "release":
			_round(row_rect, Color(SEL_RELEASE.r, SEL_RELEASE.g, SEL_RELEASE.b, 0.14), Color(SEL_RELEASE.r, SEL_RELEASE.g, SEL_RELEASE.b, 0.45), 6, 1)
		elif state == "demote":
			_round(row_rect, Color(SEL_DEMOTE.r, SEL_DEMOTE.g, SEL_DEMOTE.b, 0.14), Color(SEL_DEMOTE.r, SEL_DEMOTE.g, SEL_DEMOTE.b, 0.45), 6, 1)
		elif selected:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), Color(BLUE.r, BLUE.g, BLUE.b, 0.45), 6, 1)

		if pitcher_table:
			_draw_pitcher_player_row(rect, row, y, effective_team_mode, career_stats, show_salary, show_offer_years)
		else:
			_draw_fielder_player_row(rect, row, y, effective_team_mode, career_stats, show_salary, show_offer_years)
		# 行モデルの `__dim` は「対象外/非該当」を表すグレーアウト (例: FA宣言しなかった選手)。
		# セルごとに色を持たせず、描画後に背景色の半透明を重ねて行全体を一様に沈める。
		if bool(row.get("__dim", false)):
			_round(row_rect, Color(PANEL.r, PANEL.g, PANEL.b, 0.62), Color.TRANSPARENT, 6, 0)
		if not sel_kind.is_empty():
			_row_hits.append({"rect": row_rect, "kind": sel_kind, "meta": record.player_id})
		# 縞の代わりに全行の下へヘアライン区切り (基底 _draw_data_table と同じ表現)。
		_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), HAIRLINE, 1.0)
		drawn += 1
		y += row_h

	# 列グループ境界の縦ヘアライン (識別 / 評価 / 能力 / 成績の各ブロック境界)。
	var sep_xs: Array = _player_table_sep_xs(_player_table_x(rect, effective_team_mode, show_salary, show_offer_years), pitcher_table)
	var band_top: float = hy - 18.0
	var rows_bottom: float = row_top + float(drawn) * row_h
	for sep_x in sep_xs:
		_line(Vector2(float(sep_x), band_top), Vector2(float(sep_x), rows_bottom), HAIRLINE, 1.0)

	if max_scroll > 0:
		_text_right("%d / %d" % [min(offset + visible, rows.size()), rows.size()], rect.end.x - 14.0, rect.end.y - 8.0, 10, FAINT, 120.0)


func _draw_people_player_table(rect: Rect2, title: String, people: Array, tab_id: String, career_stats: bool, empty_text: String, scroll_key: String, show_tab_space: bool, show_salary: bool = false) -> void:
	var rows: Array = _people_player_rows_for_tab(people, tab_id)
	var pitcher_table: bool = tab_id == PLAYER_TAB_PITCHER
	var scoped_empty: String = empty_text
	if scoped_empty.is_empty():
		scoped_empty = "該当する選手がいません。"
	_draw_player_record_table(rect, title, rows, pitcher_table, "", "%s_%s" % [scroll_key, tab_id], "", 0, scoped_empty, show_tab_space, career_stats, "", show_salary)


func _draw_pitcher_table_header(rect: Rect2, y: float, team_mode: String, career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	if team_mode == "move" or team_mode == "fa_result" or team_mode == "fgc_result":
		_text("移籍元球団", Vector2(float(xs["team_from_x"]), y), 11, FAINT, 56.0)
		_text("移籍先球団", Vector2(float(xs["team_to_x"]), y), 11, FAINT, 56.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text("現球団" if team_mode == "fgc_market_away" else "球団", Vector2(float(xs["team_x"]), y), 11, FAINT)
	_text("役割", Vector2(float(xs["role_x"]), y), 11, FAINT, 52.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text("選手", Vector2(float(xs["name_x"]), y), 11, FAINT)
	if xs.has("salary_r"):
		_text_cell("年数" if _is_contract_offer_mode(team_mode) else "年俸", float(xs["salary_r"]), y, 11, FAINT, 44.0 if _is_contract_offer_mode(team_mode) else 76.0)
	if xs.has("offer_years_r"):
		_text_cell(_offer_amount_label(team_mode), float(xs["offer_years_r"]), y, 11, FAINT, 66.0 if _is_contract_offer_mode(team_mode) else 46.0)
	if team_mode == "contract":
		_text_cell("年俸増減", float(xs["salary_delta_r"]), y, 11, FAINT, 80.0)
	if xs.has("contract_years_r"):
		_text_cell("契約年数", float(xs["contract_years_r"]), y, 11, FAINT, 52.0)
	_text_cell("年齢", float(xs["age_r"]), y, 11, FAINT, 40.0)
	_text_cell("在", float(xs["years_r"]), y, 11, FAINT, 30.0)
	_text_cell("怪", float(xs["inj_r"]), y, 11, FAINT, 30.0)
	_text_cell("評価", float(xs["eval_r"]), y, 11, FAINT, 44.0)
	_text_cell("WAR", float(xs["war_r"]), y, 11, FAINT, 46.0)
	_text_cell("球速", float(xs["velo_r"]), y, 11, FAINT, 58.0)
	_text_cell("球質", float(xs["stuff_r"]), y, 11, FAINT)
	_text_cell("制球", float(xs["ctrl_r"]), y, 11, FAINT)
	_text_cell("持久", float(xs["stam_r"]), y, 11, FAINT, 54.0)
	_text_cell("登板" if career_stats else "登板", float(xs["g_r"]), y, 11, FAINT, 44.0)
	_text_cell("勝", float(xs["w_r"]), y, 11, FAINT, 28.0)
	_text_cell("敗", float(xs["l_r"]), y, 11, FAINT, 28.0)
	_text_cell("S", float(xs["sv_r"]), y, 11, FAINT, 28.0)
	_text_cell("H", float(xs["hld_r"]), y, 11, FAINT, 28.0)
	_text_cell("投球回", float(xs["ip_r"]), y, 11, FAINT, 62.0)
	_text_cell("防御率", float(xs["era_r"]), y, 11, FAINT, 62.0)
	_text_cell(_contract_slot_label(team_mode, "FIP"), float(xs["fip_r"]), y, 11, FAINT, 54.0)
	_text_cell(_outcome_slot_label(team_mode, "WHIP"), float(xs["whip_r"]), y, 11, FAINT, 58.0)
	if not xs.has("salary_r"):
		_text_cell("K/9", float(xs["k9_r"]), y, 11, FAINT, 54.0)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


func _draw_fielder_table_header(rect: Rect2, y: float, team_mode: String, _career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	if team_mode == "move" or team_mode == "fa_result" or team_mode == "fgc_result":
		_text("移籍元球団", Vector2(float(xs["team_from_x"]), y), 11, FAINT, 56.0)
		_text("移籍先球団", Vector2(float(xs["team_to_x"]), y), 11, FAINT, 56.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text("現球団" if team_mode == "fgc_market_away" else "球団", Vector2(float(xs["team_x"]), y), 11, FAINT)
	_text("守備", Vector2(float(xs["role_x"]), y), 11, FAINT, 40.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text("選手", Vector2(float(xs["name_x"]), y), 11, FAINT)
	if xs.has("salary_r"):
		_text_cell("年数" if _is_contract_offer_mode(team_mode) else "年俸", float(xs["salary_r"]), y, 11, FAINT, 44.0 if _is_contract_offer_mode(team_mode) else 76.0)
	if xs.has("offer_years_r"):
		_text_cell(_offer_amount_label(team_mode), float(xs["offer_years_r"]), y, 11, FAINT, 66.0 if _is_contract_offer_mode(team_mode) else 46.0)
	if team_mode == "contract":
		_text_cell("年俸増減", float(xs["salary_delta_r"]), y, 11, FAINT, 80.0)
	if xs.has("contract_years_r"):
		_text_cell("契約年数", float(xs["contract_years_r"]), y, 11, FAINT, 52.0)
	_text_cell("年齢", float(xs["age_r"]), y, 11, FAINT, 40.0)
	_text_cell("在", float(xs["years_r"]), y, 11, FAINT, 30.0)
	_text_cell("怪", float(xs["inj_r"]), y, 11, FAINT, 30.0)
	_text_cell("評価", float(xs["eval_r"]), y, 11, FAINT, 44.0)
	_text_cell("WAR", float(xs["war_r"]), y, 11, FAINT, 46.0)
	_text_cell("巧打", float(xs["meet_r"]), y, 11, FAINT, 38.0)
	_text_cell("長打", float(xs["pow_r"]), y, 11, FAINT, 38.0)
	_text_cell("走力", float(xs["spd_r"]), y, 11, FAINT, 38.0)
	_text_cell("守備", float(xs["def_r"]), y, 11, FAINT, 38.0)
	_text_cell("肩力", float(xs["arm_r"]), y, 11, FAINT, 38.0)
	_text_cell("選球", float(xs["eye_r"]), y, 11, FAINT, 38.0)
	_text_cell("試合", float(xs["g_r"]), y, 11, FAINT, 42.0)
	_text_cell("打率", float(xs["avg_r"]), y, 11, FAINT, 52.0)
	_text_cell("本", float(xs["hr_r"]), y, 11, FAINT, 34.0)
	_text_cell("打点", float(xs["rbi_r"]), y, 11, FAINT, 44.0)
	_text_cell(_contract_slot_label(team_mode, "盗塁"), float(xs["sb_r"]), y, 11, FAINT, 44.0)
	if not xs.has("salary_r"):
		_text_cell("出塁率", float(xs["obp_r"]), y, 11, FAINT, 62.0)
	_text_cell("OPS", float(xs["ops_r"]), y, 11, FAINT, 54.0)
	if xs.has("salary_r"):
		_text_cell("wRC+", float(xs["woba_r"]), y, 11, FAINT, 60.0)
	else:
		_text_cell("wOBA", float(xs["woba_r"]), y, 11, FAINT, 60.0)
		_text_cell("wRC+", float(xs["wrc_r"]), y, 11, FAINT, 56.0)
	_text_cell(_outcome_slot_label(team_mode, "OAA"), float(xs["oaa_r"]), y, 11, FAINT, 54.0)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


func _draw_pitcher_player_row(rect: Rect2, row: Dictionary, y: float, team_mode: String, career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
	var player: PSPlayer = row.get("player", null) as PSPlayer
	var entry: Dictionary = row.get("entry", {}) as Dictionary
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years)
	if team_mode == "move" or team_mode == "fa_result" or team_mode == "fgc_result":
		_text(_team_short(int(entry.get("from_team", 0))), Vector2(float(xs["team_from_x"]), y), 12, MUTED, 52.0)
		_text(_team_short(int(entry.get("to_team", entry.get("team_id", record.team_id)))), Vector2(float(xs["team_to_x"]), y), 12, TEXT, 52.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text(_team_short(int(entry.get("team_id", record.team_id))), Vector2(float(xs["team_x"]), y), 12, MUTED, 52.0)
	_role_badge(Rect2(float(xs["role_x"]), y - 16.0, 52.0, 22.0), record)
	_draw_identity_cells(record, player, entry, xs, y, team_mode)

	var value: int = PlayerValueEvaluator.overall_score(record)
	_text_cell(str(value), float(xs["eval_r"]), y, 13, _grade_color(value), 44.0)
	_text_cell(_war_text(record, career_stats), float(xs["war_r"]), y, 13, _war_value_color(_war_value(record, career_stats)), 46.0)
	_draw_velocity_value(PlayerVisibleRatings.pitcher_velocity(record), float(xs["velo_r"]), y, 58.0)
	_draw_rating_value(PlayerVisibleRatings.pitcher_stuff(record), float(xs["stuff_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.pitcher_control(record), float(xs["ctrl_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.pitcher_stamina(record), float(xs["stam_r"]), y)

	var ps: PSPitcherStats = RecordStore.get_player_career_pitcher_stats(record.player_id) if career_stats else record.pitcher_stats
	_text_cell(str(ps.games), float(xs["g_r"]), y, 13, TEXT, 44.0)
	_text_cell(str(ps.wins), float(xs["w_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.losses), float(xs["l_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.saves), float(xs["sv_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.holds), float(xs["hld_r"]), y, 13, MUTED, 28.0)
	_text_cell(_ip_str(ps), float(xs["ip_r"]), y, 13, TEXT, 62.0)
	_text_cell(_era_str_from_stats(ps), float(xs["era_r"]), y, 13, TEXT, 62.0)
	# 契約系の team_mode は FIP/WHIP 枠を契約情報へ差し替える (見出しは _contract_slot_label /
	# _outcome_slot_label が単一ソース)。契約提示系 (fgc_market* / contract_years) は提示状態・現年俸、
	# fa_declaration は権利・去就。成立した契約年数は年俸の隣の専用列 (contract_years_r) が出す。
	if _is_contract_offer_mode(team_mode) or team_mode == "fa_declaration":
		_text_cell(str(entry.get("offer_text", "-")), float(xs["fip_r"]), y, 13, entry.get("offer_color", FAINT) as Color, 54.0)
	else:
		_text_cell(_fip_text(record, career_stats), float(xs["fip_r"]), y, 13, MUTED, 54.0)
	if team_mode == "fgc_result" or team_mode == "fa_declaration":
		_text_cell(str(entry.get("outcome_label", "")), float(xs["whip_r"]), y, 13, entry.get("outcome_color", TEXT) as Color, 58.0)
	elif _is_contract_offer_mode(team_mode):
		_text_cell(str(entry.get("fgc_current_salary_text", "-")), float(xs["whip_r"]), y, 13, MUTED, 58.0)
	else:
		_text_cell(_whip_str(ps), float(xs["whip_r"]), y, 13, MUTED, 58.0)
	if not xs.has("salary_r"):
		_text_cell(_k9_str(ps), float(xs["k9_r"]), y, 13, MUTED, 54.0)


func _draw_fielder_player_row(rect: Rect2, row: Dictionary, y: float, team_mode: String, career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
	var player: PSPlayer = row.get("player", null) as PSPlayer
	var entry: Dictionary = row.get("entry", {}) as Dictionary
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years)
	if team_mode == "move" or team_mode == "fa_result" or team_mode == "fgc_result":
		_text(_team_short(int(entry.get("from_team", 0))), Vector2(float(xs["team_from_x"]), y), 12, MUTED, 52.0)
		_text(_team_short(int(entry.get("to_team", entry.get("team_id", record.team_id)))), Vector2(float(xs["team_to_x"]), y), 12, TEXT, 52.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text(_team_short(int(entry.get("team_id", record.team_id))), Vector2(float(xs["team_x"]), y), 12, MUTED, 52.0)
	_position_badge(Rect2(float(xs["role_x"]), y - 16.0, 40.0, 22.0), record.position, record.development_player)
	_draw_identity_cells(record, player, entry, xs, y, team_mode)

	var value: int = PlayerValueEvaluator.overall_score(record)
	_text_cell(str(value), float(xs["eval_r"]), y, 13, _grade_color(value), 44.0)
	_text_cell(_war_text(record, career_stats), float(xs["war_r"]), y, 13, _war_value_color(_war_value(record, career_stats)), 46.0)
	_draw_rating_value(PlayerVisibleRatings.fielder_contact(record), float(xs["meet_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.fielder_power(record), float(xs["pow_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.fielder_speed(record), float(xs["spd_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.fielder_defense(record), float(xs["def_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.fielder_arm(record), float(xs["arm_r"]), y)
	_draw_rating_value(PlayerVisibleRatings.fielder_discipline(record), float(xs["eye_r"]), y)

	var bs: PSBatterStats = RecordStore.get_player_career_batter_stats(record.player_id) if career_stats else record.batter_stats
	var ad: PSAdvancedStats = _career_advanced_stats(record.player_id) if career_stats else record.advanced_stats
	var played: bool = ad != null and ad.plate_appearances > 0
	_text_cell(str(bs.games), float(xs["g_r"]), y, 13, TEXT, 42.0)
	_text_cell(_rate_short(bs.batting_average()), float(xs["avg_r"]), y, 13, TEXT, 52.0)
	_text_cell(str(bs.home_runs), float(xs["hr_r"]), y, 13, TEXT, 34.0)
	_text_cell(str(bs.runs_batted_in), float(xs["rbi_r"]), y, 13, MUTED, 44.0)
	# 契約系の team_mode は盗塁/OAA 枠を契約情報へ差し替える (投手表の FIP/WHIP 枠と対応、
	# 見出しは _contract_slot_label / _outcome_slot_label が単一ソース)。
	if _is_contract_offer_mode(team_mode) or team_mode == "fa_declaration":
		_text_cell(str(entry.get("offer_text", "-")), float(xs["sb_r"]), y, 13, entry.get("offer_color", FAINT) as Color, 44.0)
	else:
		_text_cell(str(bs.stolen_bases), float(xs["sb_r"]), y, 13, MUTED, 44.0)
	if not xs.has("salary_r"):
		_text_cell(_rate_short(bs.on_base_percentage()), float(xs["obp_r"]), y, 13, MUTED, 62.0)
	_text_cell(_rate_short(bs.ops()), float(xs["ops_r"]), y, 13, TEXT, 54.0)
	if xs.has("salary_r"):
		_text_cell(str(int(round(ad.wrc_plus()))) if played else "-", float(xs["woba_r"]), y, 13, MUTED, 60.0)
	else:
		_text_cell(_rate_short(ad.woba()) if played else "-", float(xs["woba_r"]), y, 13, MUTED, 60.0)
		_text_cell(str(int(round(ad.wrc_plus()))) if played else "-", float(xs["wrc_r"]), y, 13, MUTED, 56.0)
	if team_mode == "fgc_result" or team_mode == "fa_declaration":
		_text_cell(str(entry.get("outcome_label", "")), float(xs["oaa_r"]), y, 13, entry.get("outcome_color", TEXT) as Color, 54.0)
	elif _is_contract_offer_mode(team_mode):
		_text_cell(str(entry.get("fgc_current_salary_text", "-")), float(xs["oaa_r"]), y, 13, MUTED, 54.0)
	else:
		_text_cell(_oaa_str(ad) if played else "-", float(xs["oaa_r"]), y, 13, _oaa_color(ad) if played else MUTED, 54.0)


func _draw_identity_cells(record: PSPlayerSeasonRecord, player: PSPlayer, entry: Dictionary, xs: Dictionary, y: float, team_mode: String = "") -> void:
	if record.jersey_number > 0:
		_text(str(record.jersey_number), Vector2(float(xs["jersey_x"]), y), 12, FAINT)
	var name_limit_x: float = (float(xs["salary_r"]) - 88.0) if xs.has("salary_r") else (float(xs["age_r"]) - 46.0)
	_text(record.name, Vector2(float(xs["name_x"]), y), 13, TEXT, name_limit_x - float(xs["name_x"]), HORIZONTAL_ALIGNMENT_LEFT, true)
	# 契約市場 (fgc_market) は前方2列を [年数][提示年俸] にする。salary_r 枠に年数、offer_years_r 枠に
	# 提示年俸 (億表示・幅広) を描く。現年俸は後方 (whip_r/oaa_r 枠) へ回す (_draw_*_player_row 側)。
	var fgc_market: bool = _is_contract_offer_mode(team_mode)
	if xs.has("salary_r"):
		if fgc_market:
			# 年数は既定で "N年"。決定状態そのものを見せたい一覧 (契約年数) は fgc_years_text で上書きする。
			_text_cell(str(entry.get("fgc_years_text", "%d年" % int(entry.get("fgc_years", 1)))),
				float(xs["salary_r"]), y, 13, entry.get("fgc_years_color", TEXT) as Color, 44.0)
		else:
			_text_cell(_comma(_player_table_salary(entry, record)), float(xs["salary_r"]), y, 13, TEXT, 76.0)
	if xs.has("offer_years_r"):
		if fgc_market:
			_text_cell(str(entry.get("market_salary_text", "-")), float(xs["offer_years_r"]), y, 13, TEXT, 66.0)
		else:
			_text_cell("%d年" % int(entry.get("offer_years", 0)), float(xs["offer_years_r"]), y, 13, TEXT, 46.0)
	if xs.has("salary_delta_r"):
		var salary_delta: int = int(entry.get("salary_delta", 0))
		_text_cell(_salary_delta_text(salary_delta), float(xs["salary_delta_r"]), y, 13, _salary_delta_color(salary_delta), 80.0)
	if xs.has("contract_years_r"):
		# 契約年数は 1 を「単年」、2年以上を "N年" と出す。0 以下 (FA権未取得で年数を決める場面が無い、
		# 退団で契約自体が無い) は "-"。
		var contract_years: int = int(entry.get("contract_years", 1))
		var contract_years_text: String = "-"
		if contract_years == 1:
			contract_years_text = "単年"
		elif contract_years >= 2:
			contract_years_text = "%d年" % contract_years
		_text_cell(contract_years_text, float(xs["contract_years_r"]), y, 13,
			BLUE if contract_years >= 2 else (MUTED if contract_years == 1 else FAINT), 52.0)
	_text_cell(str(record.age), float(xs["age_r"]), y, 13, MUTED, 40.0)
	_text_cell(str(record.years), float(xs["years_r"]), y, 13, MUTED, 30.0)
	var injury: int = _record_injury_days(record, player, entry)
	_text_cell(str(injury) if injury > 0 else "-", float(xs["inj_r"]), y, 13, RED if injury > 0 else FAINT, 30.0)


func _player_table_salary(entry: Dictionary, record: PSPlayerSeasonRecord) -> int:
	for key in ["new_salary", "offer_salary", "salary"]:
		if entry.has(key):
			return int(entry.get(key, record.salary))
	var candidate: Dictionary = entry.get("candidate", {}) as Dictionary
	for key in ["offer_salary", "salary"]:
		if candidate.has(key):
			return int(candidate.get(key, record.salary))
	return record.salary


# 外国人契約市場 (未解決) の team_mode。"fgc_market" は自軍 (現球団列なし)、"fgc_market_away" は
# 他球団 (現球団列あり)。
func _is_fgc_market_mode(team_mode: String) -> bool:
	return team_mode == "fgc_market" or team_mode == "fgc_market_away"


# 「契約年数を決める」系の一覧 (外国人契約市場と国内の契約年数ステップ) の team_mode。
# 前方2列を [年数][金額] にし、FIP/盗塁・WHIP/OAA 相当の枠を契約情報へ差し替える点が共通。
func _is_contract_offer_mode(team_mode: String) -> bool:
	return _is_fgc_market_mode(team_mode) or team_mode == "contract_years"


# FIP (投手) / 盗塁 (野手) 枠の見出し。契約系の team_mode はここを契約情報へ差し替える。
func _contract_slot_label(team_mode: String, default_label: String) -> String:
	match team_mode:
		"fgc_market", "fgc_market_away":
			return "提示状態"
		"contract_years":
			return "区分"
		"fa_declaration":
			return "権利"
	return default_label


# WHIP (投手) / OAA (野手) 枠の見出し。契約系の team_mode はここを去就・現年俸へ差し替える。
func _outcome_slot_label(team_mode: String, default_label: String) -> String:
	match team_mode:
		"fgc_result", "fa_declaration":
			return "去就"
		"fgc_market", "fgc_market_away", "contract_years":
			return "現年俸"
	return default_label


# 前方2列目 (offer_years_r 枠) の見出し。契約提示系だけ金額を出すのでモードごとに呼び分ける。
func _offer_amount_label(team_mode: String) -> String:
	if team_mode == "contract_years":
		return "基準年俸"
	if _is_fgc_market_mode(team_mode):
		return "提示年俸"
	return "年数"


# 年俸の隣に「契約年数」列を出す team_mode。列の幅は選手名の余白から捻出するので、
# 右側の成績ブロックの位置は変わらない (レイアウト崩れを起こさずに1列足せる唯一の空き)。
func _has_contract_years_column(team_mode: String) -> bool:
	return team_mode == "contract" or team_mode == "fa_result" or team_mode == "fgc_result" or team_mode == "contract_years_result"


func _player_table_x(rect: Rect2, team_mode: String, show_salary: bool = false, show_offer_years: bool = false) -> Dictionary:
	if team_mode == "contract":
		var cleft: float = rect.position.x
		var cright: float = rect.end.x
		return {
			"team_x": cleft + 18.0,
			"team_from_x": cleft + 18.0,
			"team_to_x": cleft + 76.0,
			"role_x": cleft + 18.0,
			"jersey_x": cleft + 78.0,
			"name_x": cleft + 104.0,
			"salary_r": cleft + 286.0,
			"salary_delta_r": cleft + 366.0,
			"contract_years_r": cleft + 424.0,
			"age_r": cleft + 486.0,
			"years_r": cleft + 532.0,
			"inj_r": cleft + 578.0,
			"eval_r": cleft + 642.0,
			"war_r": cleft + 706.0,
			"velo_r": cleft + 790.0,
			"stuff_r": cleft + 872.0,
			"ctrl_r": cleft + 930.0,
			"stam_r": cleft + 988.0,
			"meet_r": cleft + 776.0,
			"pow_r": cleft + 822.0,
			"spd_r": cleft + 868.0,
			"def_r": cleft + 914.0,
			"arm_r": cleft + 960.0,
			"eye_r": cleft + 1006.0,
			"g_r": cright - 552.0,
			"w_r": cright - 500.0,
			"l_r": cright - 456.0,
			"sv_r": cright - 412.0,
			"hld_r": cright - 368.0,
			"ip_r": cright - 284.0,
			"era_r": cright - 196.0,
			"fip_r": cright - 108.0,
			"whip_r": cright - 28.0,
			"k9_r": cright - 28.0,
			"avg_r": cright - 486.0,
			"hr_r": cright - 426.0,
			"rbi_r": cright - 364.0,
			"sb_r": cright - 304.0,
			"obp_r": cright - 304.0,
			"ops_r": cright - 214.0,
			"woba_r": cright - 126.0,
			"wrc_r": cright - 126.0,
			"oaa_r": cright - 28.0,
		}
	var team_shift: float = 0.0
	if team_mode == "move" or team_mode == "fa_result" or team_mode == "fgc_result":
		team_shift = 120.0
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		team_shift = 68.0
	var left: float = rect.position.x
	var right: float = rect.end.x
	if show_salary:
		# 年俸列を持つ一覧は右側の成績を圧縮し、球団列の有無に応じて識別・能力ブロックを送る。
		# 限られた幅では K/9 (投手) または出塁率・wOBA (野手) を省き、契約更新表と同じ成績配置にする。
		# show_offer_years (FA候補一覧) は年俸の直後に提示年数を挿し込み、以降の左詰め列を後ろへ送る。
		# 右詰め列 (g_r 以降) は成績側の余白を消費するのみでここでは動かさない。
		var years_shift: float = 46.0 if show_offer_years else 0.0
		# 契約年数列は選手名の余白 (52px) を使うので、年俸列だけ左へ寄せて後続列は動かさない。
		var salary_shift: float = -52.0 if _has_contract_years_column(team_mode) else 0.0
		var salary_xs: Dictionary = {
			"team_x": left + 18.0,
			"team_from_x": left + 18.0,
			"team_to_x": left + 76.0,
			"role_x": left + 18.0 + team_shift,
			"jersey_x": left + 78.0 + team_shift,
			"name_x": left + 104.0 + team_shift,
			"salary_r": left + 338.0 + team_shift + salary_shift,
			"age_r": left + 406.0 + team_shift + years_shift,
			"years_r": left + 452.0 + team_shift + years_shift,
			"inj_r": left + 498.0 + team_shift + years_shift,
			"eval_r": left + 562.0 + team_shift + years_shift,
			"war_r": left + 626.0 + team_shift + years_shift,
			"velo_r": left + 710.0 + team_shift + years_shift,
			"stuff_r": left + 792.0 + team_shift + years_shift,
			"ctrl_r": left + 850.0 + team_shift + years_shift,
			"stam_r": left + 908.0 + team_shift + years_shift,
			"meet_r": left + 692.0 + team_shift + years_shift,
			"pow_r": left + 738.0 + team_shift + years_shift,
			"spd_r": left + 784.0 + team_shift + years_shift,
			"def_r": left + 830.0 + team_shift + years_shift,
			"arm_r": left + 876.0 + team_shift + years_shift,
			"eye_r": left + 922.0 + team_shift + years_shift,
			"g_r": right - 552.0,
			"w_r": right - 500.0,
			"l_r": right - 456.0,
			"sv_r": right - 412.0,
			"hld_r": right - 368.0,
			"ip_r": right - 284.0,
			"era_r": right - 196.0,
			"fip_r": right - 108.0,
			"whip_r": right - 28.0,
			"k9_r": right - 28.0,
			"avg_r": right - 486.0,
			"hr_r": right - 426.0,
			"rbi_r": right - 364.0,
			"sb_r": right - 304.0,
			"obp_r": right - 304.0,
			"ops_r": right - 214.0,
			"woba_r": right - 126.0,
			"wrc_r": right - 126.0,
			"oaa_r": right - 28.0,
		}
		if show_offer_years:
			# 契約市場は offer_years_r 枠に提示年俸 (億表示・66px) を描くため右へ広げる (年数列と衝突させない)。
			salary_xs["offer_years_r"] = (left + 408.0 + team_shift) if _is_contract_offer_mode(team_mode) else (left + 384.0 + team_shift)
		if _has_contract_years_column(team_mode):
			salary_xs["contract_years_r"] = left + 338.0 + team_shift
		return salary_xs
	var rating_shift: float = min(team_shift, 68.0)
	return {
		"team_x": left + 18.0,
		"team_from_x": left + 18.0,
		"team_to_x": left + 76.0,
		"role_x": left + 18.0 + team_shift,
		"jersey_x": left + 78.0 + team_shift,
		"name_x": left + 104.0 + team_shift,
		"age_r": left + 290.0 + team_shift,
		"years_r": left + 338.0 + team_shift,
		"inj_r": left + 388.0 + team_shift,
		"eval_r": left + 458.0 + team_shift,
		"war_r": left + 526.0 + team_shift,
		"velo_r": left + 626.0 + rating_shift,
		"stuff_r": left + 708.0 + rating_shift,
		"ctrl_r": left + 766.0 + rating_shift,
		"stam_r": left + 824.0 + rating_shift,
		"meet_r": left + 612.0 + rating_shift,
		"pow_r": left + 654.0 + rating_shift,
		"spd_r": left + 696.0 + rating_shift,
		"def_r": left + 738.0 + rating_shift,
		"arm_r": left + 780.0 + rating_shift,
		"eye_r": left + 822.0 + rating_shift,
		"g_r": right - 704.0,
		"w_r": right - 648.0,
		"l_r": right - 602.0,
		"sv_r": right - 556.0,
		"hld_r": right - 510.0,
		"ip_r": right - 426.0,
		"era_r": right - 326.0,
		"fip_r": right - 226.0,
		"whip_r": right - 122.0,
		"k9_r": right - 18.0,
		"avg_r": right - 626.0,
		"hr_r": right - 568.0,
		"rbi_r": right - 504.0,
		"sb_r": right - 444.0,
		"obp_r": right - 352.0,
		"ops_r": right - 264.0,
		"woba_r": right - 176.0,
		"wrc_r": right - 106.0,
		"oaa_r": right - 18.0,
	}


# _player_table_x の列 x から「識別 / 評価 / 能力 / 成績」ブロック境界の縦ヘアライン位置を出す。
# team_mode ごとに絶対値は変わるが eval_r/velo_r(or meet_r)/g_r は全モード共通キーなので分岐不要。
func _player_table_sep_xs(xs: Dictionary, pitcher: bool) -> Array:
	var eval_r: float = float(xs["eval_r"])
	var ability_r: float = float(xs["velo_r"]) if pitcher else float(xs["meet_r"])
	var ability_box: float = 58.0 if pitcher else 38.0
	var g_r: float = float(xs["g_r"])
	var g_box: float = 44.0 if pitcher else 42.0
	return [eval_r - 44.0 - 10.0, ability_r - ability_box - 10.0, g_r - g_box - 10.0]


# 見出し + テーブル1枚のシンプルな結果レイアウト。
func _heading_table(rect: Rect2, heading: String, columns: Array, rows: Array, empty_text: String, scroll_key: String) -> void:
	_text(heading, Vector2(rect.position.x, rect.position.y + 22), 18, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	var tr: Rect2 = Rect2(rect.position.x, rect.position.y + 40.0, rect.size.x, rect.size.y - 40.0)
	if rows.is_empty():
		if not empty_text.is_empty():
			_text(empty_text, Vector2(rect.position.x + 4, rect.position.y + 72), 14, MUTED)
		return
	_draw_table(tr, "", columns, rows, scroll_key, "", 0)


# ============================================================ table primitives
# 描画本体は基底 dashboard_screen._draw_data_table に集約 (2026-06-24)。ここは offseason 既定値
# (見出し15px / 本文13px / 文字列左寄せ・数値右寄せ / 固定行高28 + スクロール・選択) を opts へ橋渡しする薄いラッパ。

func _draw_table(rect: Rect2, title: String, columns: Array, rows: Array, scroll_key: String, sel_kind: String, selected_id: int) -> void:
	_draw_table_inner(rect, title, columns, rows, scroll_key, sel_kind, selected_id, true)


func _draw_table_inner(rect: Rect2, title: String, columns: Array, rows: Array, scroll_key: String, sel_kind: String, selected_id: int, panel: bool, header_size: int = 15, row_h: float = 28.0) -> void:
	_draw_data_table(rect, columns, rows, {
		"panel": panel,
		"title": title, "title_size": header_size, "title_pad": 16.0, "title_y": 28.0, "title_width": rect.size.x - 32.0,
		"header_top": 50.0 if not title.is_empty() else 24.0,
		"default_align": "", "cell_size": 13, "header_size": 12, "row_h": row_h,
		"scroll_key": scroll_key, "sel_kind": sel_kind, "selected_id": selected_id,
		"hits": _row_hits, "scroll": _scroll, "scroll_zones": _scroll_zones,
		"alt_rows": true,
	})


# 改行区切りテキストを描き、最終 y を返す。空行は半行ぶん送る。
func _draw_text_lines(x: float, y: float, w: float, text: String, size: int, color: Color) -> float:
	var line_h: float = float(size) + 9.0
	var cy: float = y
	for line in text.split("\n"):
		if line == "":
			cy += line_h * 0.5
			continue
		_text(line, Vector2(x, cy + float(size)), size, color, w)
		cy += line_h
	return cy


# ============================================================ populate: 戦力外通告

func _populate_release() -> void:
	team_roster_records = []
	_release_pitcher_records = []
	_release_fielder_records = []
	selected_release_ids = {}
	selected_demote_ids = {}
	last_release_meta = 0
	release_war_by_id = _build_release_war_map()
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		_release_rows = []
		_release_summary_text = ""
		return
	var pitchers: Array = []
	var batters: Array = []
	_release_foreign_count = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id or player.is_retired():
			continue
		# 外国人の去就 (残留/引き抜き/退団) は外国人契約市場で決まるため、戦力外編集の対象外にする。
		if player.foreign_player:
			_release_foreign_count += 1
			continue
		var record: PSPlayerSeasonRecord = _current_record_for_player(player)
		if record == null:
			continue
		if record.is_pitcher():
			pitchers.append(record)
		else:
			batters.append(record)
	var sort_fn: Callable = func(a: Variant, b: Variant) -> bool:
		var pa: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var pb: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		if pa.age == pb.age:
			return PlayerValueEvaluator.overall_score(pa) < PlayerValueEvaluator.overall_score(pb)
		return pa.age > pb.age
	pitchers.sort_custom(sort_fn)
	batters.sort_custom(sort_fn)
	_release_pitcher_records = pitchers
	_release_fielder_records = batters
	team_roster_records = []
	team_roster_records.append_array(pitchers)
	team_roster_records.append_array(batters)
	_rebuild_release_rows()
	_refresh_release_summary()


func _rebuild_release_rows() -> void:
	_release_rows = []
	for record_row in team_roster_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var player: PSPlayer = GameDb.get_player(record.player_id)
		if player != null:
			_release_rows.append(_release_row(player))


func _release_row(player: PSPlayer) -> Dictionary:
	var is_release: bool = selected_release_ids.has(player.id)
	var is_demote: bool = selected_demote_ids.has(player.id)
	var note_parts: Array = []
	if player.foreign_player:
		note_parts.append("外")
	var check_text: String = ""
	if is_release:
		check_text = "✓"
	elif is_demote:
		check_text = "育"
	var war_entry: Variant = release_war_by_id.get(player.id, {})
	var war_value: float = float(war_entry.get("war", 0.0)) if war_entry is Dictionary else float(war_entry)
	var row: Dictionary = {
		"check": check_text,
		"pos": _player_role_or_position(player),
		"name": player.name,
		"age": player.age,
		"years": player.years,
		"eval": Offseason.player_value_score(player),
		"war": war_value,
		"injury": _release_injury_days(player),
		"note": " ".join(note_parts),
		"stat": _release_stat_text(player),
		"__meta": player.id,
	}
	if is_release:
		row["__color"] = SEL_RELEASE
	elif is_demote:
		row["__color"] = SEL_DEMOTE
	return row


func _release_injury_days(player: PSPlayer) -> int:
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			return record.season_injury_days
	return player.injury_days


func _build_release_war_map() -> Dictionary:
	var map: Dictionary = {}
	var season: PSSeason = AppState.current_season
	if season == null:
		return map
	var war_rows: Array = PSWarCalculator.season_war_table(season.year, season.season_number)
	for row_value in war_rows:
		var row: Dictionary = row_value as Dictionary
		map[int(row.get("player_id", 0))] = row
	return map


func _release_stat_text(player: PSPlayer) -> String:
	var season: PSSeason = AppState.current_season
	if season == null:
		return ""
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
	if record == null:
		return ""
	if player.is_pitcher():
		var ps: PSPitcherStats = record.pitcher_stats
		if ps.games <= 0:
			return "登板なし"
		var era_str: String = "--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()
		return "登%d 先%d %d勝%d敗S%d H%d 防%s 奪%d" % [
			ps.games, ps.starts, ps.wins, ps.losses, ps.saves, ps.holds, era_str, ps.strikeouts,
		]
	var bs: PSBatterStats = record.batter_stats
	if bs.plate_appearances <= 0:
		return "出場なし"
	return "試%d 打席%d 率%0.3f 本%d 点%d 盗%d OPS%0.3f" % [
		bs.games, bs.plate_appearances, bs.batting_average(),
		bs.home_runs, bs.runs_batted_in, bs.stolen_bases, bs.ops(),
	]


func _refresh_release_summary() -> void:
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var team_name: String = team.short_name if team != null else ""
	_release_summary_text = "[%s] 戦力外 %d人 / 育成降格 %d人 / 自軍%d人" % [
		team_name, selected_release_ids.size(), selected_demote_ids.size(), team_roster_records.size(),
	]
	if _release_foreign_count > 0:
		_release_summary_text += " / 外国人%d人は契約市場で扱う" % _release_foreign_count


func _on_auto_select_release_pressed() -> void:
	var recommendation: Dictionary = _build_release_recommendation()
	if not bool(recommendation.get("ok", false)):
		_set_status(str(recommendation.get("message", "")), RED)
		return
	selected_release_ids = {}
	selected_demote_ids = {}
	for pid_value in recommendation.get("release_ids", []) as Array:
		selected_release_ids[int(pid_value)] = true
	for pid_value in recommendation.get("demote_ids", []) as Array:
		selected_demote_ids[int(pid_value)] = true
	_rebuild_release_rows()
	_refresh_release_summary()
	_set_status("推奨選手を表示しました (戦力外%d / 育成降格%d)。確定前に編集できます。" % [selected_release_ids.size(), selected_demote_ids.size()], MUTED)


func _on_auto_commit_release_pressed() -> void:
	var recommendation: Dictionary = _build_release_recommendation()
	if not bool(recommendation.get("ok", false)):
		_set_status(str(recommendation.get("message", "")), RED)
		return
	var result: Dictionary = _commit_release_lists(recommendation.get("release_ids", []) as Array, recommendation.get("demote_ids", []) as Array)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "")), RED)
		return
	_refresh()


func _on_commit_release_pressed() -> void:
	_show_release_confirm_dialog()


func _on_release_confirmed() -> void:
	var selected_ids: Array = _selected_release_id_list()
	var demote_ids: Array = _selected_demote_id_list()
	var result: Dictionary = _commit_release_lists(selected_ids, demote_ids)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "")), RED)
		return
	_refresh()


func _selected_release_id_list() -> Array:
	var ids: Array = []
	for pid in selected_release_ids.keys():
		ids.append(int(pid))
	return ids


func _selected_demote_id_list() -> Array:
	var ids: Array = []
	for pid in selected_demote_ids.keys():
		ids.append(int(pid))
	return ids


func _commit_release_lists(release_ids: Array, demote_ids: Array) -> Dictionary:
	return AppState.commit_release(release_ids, demote_ids)


func _build_release_recommendation() -> Dictionary:
	var team_id: int = AppState.selected_team_id
	var season: PSSeason = AppState.current_season
	if team_id <= 0 or season == null:
		return {"ok": false, "message": "戦力外候補を計算できません。"}
	var release_ids: Array = []
	var demote_ids: Array = []
	# 長期故障の育成降格は戦力外候補とは独立に拾う (怪我人は候補側で保護されるため、
	# 候補リストからの振り分けだけでは発火しない。CPU 側 process_cpu_releases と同じ入口)。
	for pid_value in OffseasonService.compute_long_injury_demotion_candidates_for_team(GameDb.players, team_id, season.year):
		demote_ids.append(int(pid_value))
	for pid_value in OffseasonService.compute_release_candidates_for_team(GameDb.players, team_id, season):
		var pid: int = int(pid_value)
		if demote_ids.has(pid):
			continue
		release_ids.append(pid)
	# 自軍の育成整理 (CPU は成長ステップの process_development_releases で自動、自軍はここで推奨)。
	# 中堅は「育成1年で昇格なし」、素材年齢は成長予測ベース。候補は支配下と重複しない。
	for pid_value in OffseasonService.compute_development_release_candidates_for_team(GameDb.players, team_id):
		release_ids.append(int(pid_value))
	return {"ok": true, "release_ids": release_ids, "demote_ids": demote_ids}


func _show_release_confirm_dialog() -> void:
	var dialog: ConfirmationDialog = _ensure_release_confirm_dialog()
	dialog.dialog_text = "現在の選択で戦力外通告を確定します。\n戦力外 %d人 / 育成降格 %d人\nよろしいですか？" % [
		selected_release_ids.size(), selected_demote_ids.size(),
	]
	dialog.popup_centered(Vector2i(480, 210))


func _ensure_release_confirm_dialog() -> ConfirmationDialog:
	if _release_confirm_dialog != null and is_instance_valid(_release_confirm_dialog):
		return _release_confirm_dialog
	_release_confirm_dialog = ConfirmationDialog.new()
	_release_confirm_dialog.title = "戦力外通告の確認"
	_release_confirm_dialog.ok_button_text = "確定する"
	_release_confirm_dialog.cancel_button_text = "キャンセル"
	_release_confirm_dialog.confirmed.connect(_on_release_confirmed)
	add_child(_release_confirm_dialog)
	_style_confirmation_dialog(_release_confirm_dialog)
	return _release_confirm_dialog


# ============================================================ populate: ドラフト

func _populate_draft() -> void:
	var state: Dictionary = AppState.draft_state
	var stage: String = str(state.get("stage", ""))
	var round_no: int = int(state.get("round", 1))
	var first_round_wave: int = int(state.get("first_round_wave", 1))
	var current_team_id: int = int(state.get("current_team_id", AppState.selected_team_id))
	var is_dev_segment: bool = str(state.get("segment", "main")) == "development"
	var phase_label: String = "育成ドラフト" if is_dev_segment else "本指名"
	var reveal: Dictionary = state.get("first_round_reveal", {}) as Dictionary
	var reveal_wave: int = int(reveal.get("wave", 1))
	if stage == "first_round_bid":
		var bid_label: String = "1巡目 入札" if first_round_wave <= 1 else "1巡目 再入札%d回目" % first_round_wave
		_draft_status_text = "%s %s: %s" % [phase_label, bid_label, _team_short(AppState.selected_team_id)]
		_draft_submit_label = "入札する"
		_draft_reveal_stage = ""
	elif stage == "user_pick":
		_draft_status_text = "%s %d巡目 指名: %s" % [phase_label, round_no, _team_short(current_team_id)]
		_draft_submit_label = "指名する"
		_draft_reveal_stage = ""
	elif stage == "first_round_reveal":
		_draft_status_text = "本指名 1巡目 入札公開" if reveal_wave <= 1 else "本指名 1巡目 再入札%d回目 入札公開" % reveal_wave
		_draft_submit_label = "指名する"
		_draft_reveal_stage = "reveal"
	elif stage == "first_round_result":
		_draft_status_text = "本指名 1巡目 抽選結果"
		_draft_submit_label = "指名する"
		_draft_reveal_stage = "result"
	else:
		_draft_status_text = phase_label
		_draft_submit_label = "指名する"
		_draft_reveal_stage = ""
	_draft_show_skip = stage == "user_pick"
	_draft_skip_label = "育成指名終了" if is_dev_segment else "本指名終了"

	_draft_record_cache = {}
	_draft_cand_by_id = {}
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if not bool(candidate.get("picked", false)):
			_draft_cand_by_id[int(candidate.get("candidate_id", 0))] = candidate

	# 投手/野手を1つの候補リストに統合 (bucket_rank 昇順)。表示はタブで絞り込む。
	_draft_candidate_rows = []
	for candidate_row in DraftService.available_candidates(state, 0):
		_draft_candidate_rows.append(_draft_candidate_row(candidate_row as Dictionary))

	if selected_draft_candidate_id > 0 and not _draft_cand_by_id.has(selected_draft_candidate_id):
		selected_draft_candidate_id = 0
	if selected_draft_candidate_id <= 0:
		var visible: Array = _candidate_rows_for_tab(_draft_candidate_rows, _draft_tab)
		if not visible.is_empty():
			selected_draft_candidate_id = int((visible[0] as Dictionary).get("candidate_id", 0))

	_draft_lottery_rows = []
	for log_row in state.get("logs", []) as Array:
		var log: Dictionary = log_row as Dictionary
		if str(log.get("type", "")) == "lottery":
			_draft_lottery_rows.append(_lottery_row(log))

	_draft_pick_rows = []
	for pick_row in state.get("picks", []) as Array:
		_draft_pick_rows.append(_pick_row(pick_row as Dictionary))

	_draft_reveal_cards = []
	_draft_reveal_go_label = "抽選へ"
	if _draft_reveal_stage != "":
		var reveal_bids: Dictionary = reveal.get("bids", {}) as Dictionary
		var reveal_winners: Dictionary = reveal.get("winners", {}) as Dictionary
		var reveal_loser_ids: Dictionary = {}
		for team_id_value in reveal.get("loser_team_ids", []) as Array:
			reveal_loser_ids[int(team_id_value)] = true
		# 候補ごとの入札球団数 (2以上=競合)。
		var counts_by_candidate: Dictionary = {}
		for team_key in reveal_bids.keys():
			var cid: int = int(reveal_bids[team_key])
			counts_by_candidate[cid] = int(counts_by_candidate.get(cid, 0)) + 1
		var any_contested: bool = false
		for cid_key in counts_by_candidate.keys():
			if int(counts_by_candidate[cid_key]) >= 2:
				any_contested = true
				break
		_draft_reveal_go_label = "抽選へ" if any_contested else "指名確定へ"
		# result 段階では当選候補が picked=true になり _draft_cand_by_id (未 picked のみ) から
		# 引けないため、候補プール全量から id -> candidate の対応をここで作る。
		var cand_by_id_full: Dictionary = {}
		for candidate_row in state.get("candidate_pool", []) as Array:
			var candidate: Dictionary = candidate_row as Dictionary
			cand_by_id_full[int(candidate.get("candidate_id", 0))] = candidate
		# 再入札 wave で既に確定済みの球団 (bids に含まれない) を round1 pick から拾うための索引。
		var round1_picks: Dictionary = _round1_picks_by_team(state)
		for team_id_value in _draft_reveal_card_order():
			var team_id: int = int(team_id_value)
			var team_key: String = str(team_id)
			if reveal_bids.has(team_key):
				var candidate_id: int = int(reveal_bids[team_key])
				var candidate: Dictionary = cand_by_id_full.get(candidate_id, {}) as Dictionary
				_draft_reveal_cards.append(_draft_reveal_card(team_id, candidate_id, candidate, int(counts_by_candidate.get(candidate_id, 0)), reveal_winners, reveal_loser_ids))
			elif round1_picks.has(team_id):
				_draft_reveal_cards.append(_draft_reveal_card_picked(team_id, round1_picks[team_id] as Dictionary))
			else:
				_draft_reveal_cards.append(_draft_reveal_card_empty(team_id))


# ドラフト候補1件を候補ボード用モデルに変換。中央2列 (出身/成長) は info1/info2 に入れる。
func _draft_candidate_row(candidate: Dictionary) -> Dictionary:
	var template: Dictionary = candidate.get("player_template", {}) as Dictionary
	var position: int = int(candidate.get("position", 0))
	var growth: float = float(candidate.get("growth_expectation", 0.0))
	return {
		"candidate_id": int(candidate.get("candidate_id", 0)),
		"name": str(candidate.get("name", "")),
		"age": int(candidate.get("age", 0)),
		"overall": int(candidate.get("overall", 0)),
		"rank": int(candidate.get("bucket_rank", 0)),
		"info1": _source_label(str(candidate.get("source_type", ""))),
		"info2": "%+0.1f" % growth,
		"info2_color": _draft_growth_color(growth),
		"is_pitcher": position == 1,
		"position": position,
		"role": str(template.get("role", "starter")),
		"aptitudes": template.get("position_aptitudes", {}) as Dictionary,
		"arsenal": template.get("arsenal", []) as Array,
		"template": template,
	}


func _candidate_tab_is_pitcher(tab: String) -> bool:
	return tab == "pitcher" or tab == "starter" or tab == "reliever"


func _candidate_row_matches_tab(row: Dictionary, tab: String) -> bool:
	var is_pitcher: bool = bool(row.get("is_pitcher", false))
	match tab:
		"all":
			return true
		"pitcher":
			return is_pitcher
		"starter":
			return is_pitcher and str(row.get("role", "")) == "starter"
		"reliever":
			return is_pitcher and (str(row.get("role", "")) == "reliever" or str(row.get("role", "")) == "closer")
		"fielder":
			return not is_pitcher
		_:
			if is_pitcher:
				return false
			var pos: int = int(tab.trim_prefix("pos"))
			if int(row.get("position", 0)) == pos:
				return true
			var key: String = str(PSPlayer.POSITION_EXPERIENCE_KEYS.get(pos, ""))
			return not key.is_empty() and int((row.get("aptitudes", {}) as Dictionary).get(key, 0)) > 0


func _candidate_rows_for_tab(rows: Array, tab: String) -> Array:
	var out: Array = []
	for row_value in rows:
		if _candidate_row_matches_tab(row_value as Dictionary, tab):
			out.append(row_value)
	return out


func _candidate_tab_count(rows: Array, tab: String) -> int:
	var count: int = 0
	for row_value in rows:
		if _candidate_row_matches_tab(row_value as Dictionary, tab):
			count += 1
	return count


# 候補テンプレートからレーティング算出用の record を遅延生成しキャッシュ (表示中の候補のみ)。
func _board_record(cache: Dictionary, candidate_id: int, template: Dictionary) -> PSPlayerSeasonRecord:
	if cache.has(candidate_id):
		return cache[candidate_id] as PSPlayerSeasonRecord
	if template.is_empty():
		return null
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(PSPlayer.from_dict(template), 0, 0)
	cache[candidate_id] = record
	return record


func _draft_growth_color(value: float) -> Color:
	if value >= 8.0:
		return GREEN
	if value >= 3.0:
		return TEXT
	return MUTED


func _pick_row(pick: Dictionary) -> Dictionary:
	var round_no: int = int(pick.get("round", 0))
	# 育成指名は巡目欄に "育" を冠して区別する (競合欄には出さない)。
	var round_text: String = ("育%d" % round_no) if bool(pick.get("development", false)) else str(round_no)
	var badge: Dictionary = _pick_pos_badge(pick)
	return {
		"round": round_text,
		"team": _team_short(int(pick.get("team_id", 0))),
		"color": _team_color(int(pick.get("team_id", 0))),
		"name": str(pick.get("name", "")),
		"age": int(pick.get("age", 0)),
		"pos": str(badge.get("text", "")),
		"pos_color": badge.get("color", MUTED) as Color,
		"pos_dev": bool(pick.get("development", false)),
		"overall": int(pick.get("overall", 0)),
		"source": _source_label(str(pick.get("source_type", ""))),
		"note": _pick_note(pick),
	}


# 競合カラム: 抽選 (1巡目重複) を経た指名は "○"、それ以外は空。
func _pick_note(pick: Dictionary) -> String:
	return "○" if bool(pick.get("lottery", false)) else ""


# 守備位置/役割バッジの表示文字と色。投手は役割色 (先発=PINK / 中継=RED)、野手は守備位置色。
func _pick_pos_badge(pick: Dictionary) -> Dictionary:
	var position: int = int(pick.get("position", 0))
	if position == 1:
		var role: String = _resolved_pitcher_role(str(pick.get("role", "")), pick)
		return {"text": _role_char(role), "color": _role_color(role)}
	return {"text": _position_char(position), "color": _pos_color(position)}


# チームカラー (テーブルのカラーアイコン用)。不明チームは MUTED。
func _team_color(team_id: int) -> Color:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.color if team != null else MUTED


func _source_label(source_type: String) -> String:
	match source_type:
		"high_school":
			return "高校"
		"university":
			return "大学"
		"industrial":
			return "社会人"
		"independent":
			return "独立"
		"overseas_school":
			return "海外"
		_:
			return source_type


func _lottery_row(log: Dictionary) -> Dictionary:
	var teams: PackedStringArray = PackedStringArray()
	for team_id_value in log.get("teams", []) as Array:
		teams.append(_team_short(int(team_id_value)))
	var winner_id: int = int(log.get("winner_team_id", 0))
	return {
		"wave": int(log.get("wave", 0)),
		"name": str(log.get("candidate_name", "")),
		"teams": ", ".join(teams),
		"team": _team_short(winner_id),
		"color": _team_color(winner_id),
	}


# 1巡目カードの並び順: 先行リーグ1位→他リーグ1位→先行2位→他2位→…(リーグ内は1位→6位)。
# セル i (0始まり) は「i偶数=先行リーグ / i奇数=他リーグ」「リーグ内順位=i/2+1番目」に対応する。
# _league_team_ids_draft_order は teams_order_reverse をリーグでフィルタした「下位→上位」の並びを
# 返すため reverse して「1位→6位」にする。片リーグが先に尽きたら残りのリーグだけを詰めて続ける
# (12球団以外の構成でも破綻しない)。
func _draft_reveal_card_order() -> Array:
	var priority_league: String = str(AppState.draft_state.get("priority_league", "league1"))
	var other_league: String = "league2" if priority_league == "league1" else "league1"
	var priority_ids: Array = _league_team_ids_draft_order(priority_league)
	priority_ids.reverse()
	var other_ids: Array = _league_team_ids_draft_order(other_league)
	other_ids.reverse()
	var order: Array = []
	for i in range(max(priority_ids.size(), other_ids.size())):
		if i < priority_ids.size():
			order.append(int(priority_ids[i]))
		if i < other_ids.size():
			order.append(int(other_ids[i]))
	return order


# team_id -> 1巡目 (development=false) の確定済み pick。再入札 wave の bids に含まれない
# (=既に決着済みの) 球団のカードを "指名済" として描くための索引。
func _round1_picks_by_team(state: Dictionary) -> Dictionary:
	var map: Dictionary = {}
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if int(pick.get("round", 0)) == 1 and not bool(pick.get("development", false)):
			map[int(pick.get("team_id", 0))] = pick
	return map


# 入札公開 (reveal) / 抽選結果 (result) カード1件分 (当該 wave の bids に含まれる球団)。
# note は reveal 段階=競合数、result 段階=当落 (競合経由の当選/単独確定/外れ) を表す。
func _draft_reveal_card(team_id: int, candidate_id: int, candidate: Dictionary, contest_count: int, winners: Dictionary, loser_ids: Dictionary) -> Dictionary:
	var template: Dictionary = candidate.get("player_template", {}) as Dictionary
	var badge: Dictionary = _pick_pos_badge({"position": int(candidate.get("position", 0)), "role": str(template.get("role", ""))})
	var note: String = ""
	var note_color: Color = TEXT
	if _draft_reveal_stage == "reveal":
		if contest_count >= 2:
			note = "競合%d球団" % contest_count
			note_color = AMBER
		else:
			note = "単独"
			note_color = TEXT
	elif int(winners.get(str(candidate_id), 0)) == team_id:
		note = "当選" if contest_count >= 2 else "確定"
		note_color = GREEN if contest_count >= 2 else TEXT
	elif loser_ids.has(team_id):
		note = "外れ"
		note_color = MUTED
	return {
		"team_id": team_id,
		"team": _team_short(team_id),
		"team_color": _team_color(team_id),
		"name": str(candidate.get("name", "")),
		"pos": str(badge.get("text", "")),
		"pos_color": badge.get("color", MUTED) as Color,
		"age": int(candidate.get("age", 0)),
		"source": _source_label(str(candidate.get("source_type", ""))),
		"overall": int(candidate.get("overall", 0)),
		"note": note,
		"note_color": note_color,
		"muted": false,
	}


# 既に1巡目の指名が確定済みの球団 (この wave の bids に含まれない)。指名内容を薄い表示で見せる。
func _draft_reveal_card_picked(team_id: int, pick: Dictionary) -> Dictionary:
	var badge: Dictionary = _pick_pos_badge(pick)
	return {
		"team_id": team_id,
		"team": _team_short(team_id),
		"team_color": _team_color(team_id),
		"name": str(pick.get("name", "")),
		"pos": str(badge.get("text", "")),
		"pos_color": badge.get("color", MUTED) as Color,
		"age": int(pick.get("age", 0)),
		"source": _source_label(str(pick.get("source_type", ""))),
		"overall": int(pick.get("overall", 0)),
		"note": "指名済",
		"note_color": MUTED,
		"muted": true,
	}


# round1 の指名も bids も無い球団 (通常は発生しないが、表に穴を空けないための保険)。
func _draft_reveal_card_empty(team_id: int) -> Dictionary:
	return {
		"team_id": team_id,
		"team": _team_short(team_id),
		"team_color": _team_color(team_id),
		"name": "—",
		"pos": "",
		"pos_color": MUTED,
		"age": 0,
		"source": "",
		"overall": 0,
		"note": "指名なし",
		"note_color": FAINT,
		"muted": true,
	}


func _on_draft_submit_pressed() -> void:
	if selected_draft_candidate_id <= 0:
		_set_status("ドラフト候補を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_draft_candidate(selected_draft_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "指名に失敗しました。")), RED)
		return
	_refresh()


func _on_draft_skip_pressed() -> void:
	var result: Dictionary = AppState.skip_draft_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "見送りに失敗しました。")), RED)
		return
	_refresh()


func _on_draft_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_draft_user_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "自動指名に失敗しました。")), RED)
		return
	_refresh()


func _on_draft_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_draft_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "自動進行に失敗しました。")), RED)
		return
	_refresh()


# 1巡目入札公開/抽選結果パネルの「抽選へ/指名確定へ」「次へ」ボタン共通ハンドラ。
# stage に応じて resolve_first_round_reveal / continue_first_round のどちらかを1ステップ進める。
func _on_draft_proceed_pressed() -> void:
	var result: Dictionary = AppState.proceed_draft_first_round()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "進行に失敗しました。")), RED)
		return
	_refresh()


# ============================================================ populate: 戦力外獲得市場

func _populate_released() -> void:
	var state: Dictionary = AppState.released_market_state
	var candidates: Array = ReleasedMarketService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var user_signings: int = 0
	for row in state.get("signings", []) as Array:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	_released_status_text = "戦力外獲得: 候補%d人 / 自軍獲得%d人 / 残り候補%d人" % [
		(state.get("candidates", []) as Array).size(), user_signings, candidates.size(),
	]
	_released_rows = []
	_released_player_rows = []
	_released_by_id = {}
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		var pid: int = int(c.get("player_id", 0))
		_released_by_id[pid] = c
		_released_rows.append({
			"name": str(c.get("name", "")),
			"from": _team_short(int(c.get("from_team", 0))),
			"age": int(c.get("age", 0)),
			"pos": _dict_role_or_position(c),
			"value": int(c.get("value", 0)),
			"war": float(c.get("war", 0.0)),
			"need": float(c.get("need", 0.0)),
			"salary": int(c.get("salary", 0)),
			"__meta": pid,
		})
		var record: PSPlayerSeasonRecord = _record_for_market_candidate(c)
		if record != null:
			_released_player_rows.append({
				"record": record,
				"player": GameDb.get_player(pid),
				"entry": {
					"player_id": pid,
					"team_id": int(c.get("from_team", 0)),
					"position": int(c.get("position", record.position)),
					"role": str(c.get("role", record.role)),
					"new_salary": int(c.get("salary", record.salary)),
					"candidate": c,
				},
			})
	if selected_released_candidate_id > 0 and not _released_by_id.has(selected_released_candidate_id):
		selected_released_candidate_id = 0
	_normalize_released_tab()
	_ensure_released_selection_for_tab()
	_released_can_submit = selected_released_candidate_id > 0
	_released_can_auto = not candidates.is_empty()


func _on_released_submit_pressed() -> void:
	if selected_released_candidate_id <= 0:
		_set_status("自由契約候補を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_released_candidate(selected_released_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "戦力外獲得に失敗しました。")), RED)
		return
	selected_released_candidate_id = 0
	_refresh()


func _on_released_skip_pressed() -> void:
	if selected_released_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_released_candidate(selected_released_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "自由契約候補の見送りに失敗しました。")), RED)
		return
	selected_released_candidate_id = 0
	_refresh()


func _on_released_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_released_user_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "戦力外獲得の自動判断に失敗しました。")), RED)
		return
	selected_released_candidate_id = 0
	_refresh()


func _on_released_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_released_market_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "戦力外獲得市場の自動進行に失敗しました。")), RED)
		return
	selected_released_candidate_id = 0
	_refresh()


# ============================================================ populate: 現役ドラフト

func _populate_geneki() -> void:
	var state: Dictionary = AppState.geneki_draft_state
	_geneki_phase = str(state.get("phase", ""))
	_geneki_player_rows = []
	_geneki_by_id = {}
	match _geneki_phase:
		"submit":
			# state 生成直後の初回だけAI推奨を初期選択にする (リロードや再入場では手動選択を保持)。
			var year: int = int(state.get("year", 0))
			if _geneki_list_seeded_year != year:
				selected_geneki_list_ids = {}
				for pid_value in state.get("user_recommended_ids", []) as Array:
					selected_geneki_list_ids[int(pid_value)] = true
				_geneki_list_seeded_year = year
			for pid_value in state.get("user_eligible_ids", []) as Array:
				_append_geneki_row(int(pid_value), AppState.selected_team_id, {})
			_geneki_refresh_submit_status()
		"round1":
			for entry_row in GenekiDraftService.round1_targets(state, AppState.selected_team_id):
				var entry: Dictionary = entry_row as Dictionary
				_append_geneki_row(int(entry.get("player_id", 0)), int(entry.get("from_team_id", 0)), entry)
			_geneki_status_text = "現役ドラフト 1巡目: 自軍の指名手番です。他球団のリスト選手から1人を指名してください (指名は義務)。"
		"round2":
			for entry_row in GenekiDraftService.round2_targets(state, AppState.selected_team_id):
				var entry: Dictionary = entry_row as Dictionary
				_append_geneki_row(int(entry.get("player_id", 0)), int(entry.get("from_team_id", 0)), entry)
			_geneki_status_text = "現役ドラフト 2巡目: 自軍の指名手番です。指名するか見送ってください。"
		"round2_entry":
			for entry_row in GenekiDraftService.round2_candidate_pool_preview(state, AppState.selected_team_id):
				var entry: Dictionary = entry_row as Dictionary
				_append_geneki_row(int(entry.get("player_id", 0)), int(entry.get("from_team_id", 0)), entry)
			_geneki_status_text = "現役ドラフト 2巡目: 参加形態を選んでください。「参加しない」を選ぶと自軍リスト選手は2巡目で指名されません。"
		_:
			_geneki_status_text = "現役ドラフトの進行を待っています。"
	if selected_geneki_pick_id > 0 and not _geneki_by_id.has(selected_geneki_pick_id):
		selected_geneki_pick_id = 0


func _append_geneki_row(pid: int, team_id: int, candidate: Dictionary) -> void:
	if pid <= 0:
		return
	var record: PSPlayerSeasonRecord = _record_for_market_candidate({"player_id": pid})
	if record == null:
		return
	_geneki_by_id[pid] = candidate
	_geneki_player_rows.append({
		"record": record,
		"player": GameDb.get_player(pid),
		"entry": {
			"player_id": pid,
			"team_id": team_id,
			"position": record.position,
			"role": record.role,
			"candidate": candidate,
		},
	})


func _geneki_refresh_submit_status() -> void:
	var state: Dictionary = AppState.geneki_draft_state
	var eligible_count: int = (state.get("user_eligible_ids", []) as Array).size()
	_geneki_status_text = "現役ドラフト: 対象リスト提出 — 対象%d人 / 選択中%d人 (2人以上。年俸5000万円以上は1人まで、含める場合は3人以上)" % [
		eligible_count, selected_geneki_list_ids.size(),
	]


func _draw_geneki_panel() -> void:
	var pitcher_tab: bool = _geneki_tab == PLAYER_TAB_PITCHER
	match _geneki_phase:
		"submit":
			_draw_player_record_table(BODY, _geneki_status_text, _geneki_player_rows, pitcher_tab,
				"geneki_list", "geneki_list_%s" % _geneki_tab, "", 0,
				"リストに載せられる対象選手がいません。", true, false, "", true)
		"round1", "round2":
			_draw_player_record_table(BODY, _geneki_status_text, _geneki_player_rows, pitcher_tab,
				"geneki_pick", "geneki_pick_%s" % _geneki_tab, "", selected_geneki_pick_id,
				"指名できる選手がいません。", true, false, "team", true)
		"round2_entry":
			_draw_player_record_table(BODY, _geneki_status_text, _geneki_player_rows, pitcher_tab,
				"", "geneki_pool_%s" % _geneki_tab, "", 0,
				"2巡目に残っている選手はいません。", true, false, "team", true)
		_:
			_text(_geneki_status_text, Vector2(INNER_L, BODY.position.y + 24.0), 15, MUTED)


func _set_geneki_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _geneki_tab == tab_id:
		return
	_geneki_tab = tab_id
	_build_buttons()
	queue_redraw()


func _on_geneki_submit_list_pressed() -> void:
	var ids: Array = []
	for pid in selected_geneki_list_ids.keys():
		ids.append(int(pid))
	var result: Dictionary = AppState.submit_geneki_list(ids)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "リストの提出に失敗しました。")), RED)
		return
	_refresh()


func _on_geneki_reset_recommended_pressed() -> void:
	selected_geneki_list_ids = {}
	for pid_value in AppState.geneki_draft_state.get("user_recommended_ids", []) as Array:
		selected_geneki_list_ids[int(pid_value)] = true
	_geneki_refresh_submit_status()
	queue_redraw()


func _on_geneki_pick_pressed() -> void:
	if selected_geneki_pick_id <= 0:
		_set_status("指名する選手を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_geneki_pick(selected_geneki_pick_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "指名に失敗しました。")), RED)
		return
	selected_geneki_pick_id = 0
	_refresh()


func _on_geneki_pass_pressed() -> void:
	var result: Dictionary = AppState.pass_geneki_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "見送りに失敗しました。")), RED)
		return
	selected_geneki_pick_id = 0
	_refresh()


func _on_geneki_round2_mode_pressed(mode: String) -> void:
	var result: Dictionary = AppState.set_geneki_round2_mode(mode)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "2巡目参加の選択に失敗しました。")), RED)
		return
	_refresh()


func _on_geneki_ai_all_pressed() -> void:
	var result: Dictionary = AppState.complete_geneki_draft_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "現役ドラフトの自動進行に失敗しました。")), RED)
		return
	selected_geneki_pick_id = 0
	_refresh()


# ============================================================ populate: FA 市場

func _populate_fa() -> void:
	var state: Dictionary = AppState.fa_state
	var candidates: Array = FaMarketService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var user_signings: int = 0
	for row in state.get("signings", []) as Array:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	_fa_status_text = "FA市場: 宣言%d人 / 自軍獲得%d人 / 候補%d人" % [
		(state.get("declared", []) as Array).size(), user_signings, candidates.size(),
	]
	# 一覧は戦力外獲得と同じ選手レコード表。候補を record 化して投手/野手タブで出す。
	_fa_player_rows = []
	_fa_by_id = {}
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		var pid: int = int(c.get("player_id", 0))
		_fa_by_id[pid] = c
		var record: PSPlayerSeasonRecord = _record_for_market_candidate(c)
		if record != null:
			_fa_player_rows.append({
				"record": record,
				"player": GameDb.get_player(pid),
				"entry": {
					"player_id": pid,
					"team_id": int(c.get("from_team", 0)),
					"position": int(c.get("position", record.position)),
					"role": str(c.get("role", record.role)),
					"new_salary": int(c.get("offer_salary", c.get("salary", record.salary))),
					"offer_years": int(c.get("offer_years", 1)),
					"candidate": c,
				},
			})
	if selected_fa_candidate_id > 0 and not _fa_by_id.has(selected_fa_candidate_id):
		selected_fa_candidate_id = 0
	_fa_tab = _player_tab_with_rows(_fa_player_rows, _fa_tab)
	selected_fa_candidate_id = _player_first_visible_id(_fa_player_rows, _fa_tab, selected_fa_candidate_id)
	if selected_fa_candidate_id <= 0:
		selected_fa_offer_years = 0
	_fa_can_submit = selected_fa_candidate_id > 0
	_fa_can_auto = not candidates.is_empty()


func _set_fa_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _fa_tab == tab_id:
		return
	_fa_tab = tab_id
	selected_fa_candidate_id = _player_first_visible_id(_fa_player_rows, _fa_tab, selected_fa_candidate_id)
	selected_fa_offer_years = 0
	_fa_can_submit = selected_fa_candidate_id > 0
	_build_buttons()
	queue_redraw()


# 交渉年数チップ (キャンプの練習種別チップと同じ idiom)。選択中候補の年齢上限までを選ばせる。
func _build_fa_year_chips() -> void:
	if selected_fa_candidate_id <= 0:
		return
	var candidate: Dictionary = _fa_by_id.get(selected_fa_candidate_id, {}) as Dictionary
	if candidate.is_empty():
		return
	var max_years: int = FaMarketService.fa_offer_max_years(int(candidate.get("age", 0)))
	var current_years: int = selected_fa_offer_years if selected_fa_offer_years > 0 else int(candidate.get("offer_years", 1))
	var y: float = BODY.position.y + 16.0
	var x: float = BODY.end.x
	var widths: Array = []
	for n in range(1, max_years + 1):
		var w: float = 14.0 + _measure("%d年" % n, 13) + 14.0
		widths.append(w)
		x -= w + 8.0
	x += 8.0
	for n in range(1, max_years + 1):
		var label: String = "%d年" % n
		var w: float = float(widths[n - 1])
		_add_button("fa_years_%d" % n, label, Rect2(x, y, w, 32.0),
			func(years: int = n) -> void: _select_fa_offer_years(years),
			"chip_active" if n == current_years else "chip")
		x += w + 8.0


func _select_fa_offer_years(years: int) -> void:
	selected_fa_offer_years = years
	_build_buttons()
	queue_redraw()


func _on_fa_submit_pressed() -> void:
	if selected_fa_candidate_id <= 0:
		_set_status("FA候補を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_fa_candidate(selected_fa_candidate_id, selected_fa_offer_years)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "FA獲得に失敗しました。")), RED)
		return
	var message: String = str(result.get("message", ""))
	var acquired: bool = bool(result.get("acquired", true))
	selected_fa_candidate_id = 0
	selected_fa_offer_years = 0
	_refresh()
	if not acquired:
		_set_status(message if not message.is_empty() else "交渉はまとまりませんでした。", AMBER)


func _on_fa_skip_pressed() -> void:
	if selected_fa_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_fa_candidate(selected_fa_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "FA見送りに失敗しました。")), RED)
		return
	selected_fa_candidate_id = 0
	selected_fa_offer_years = 0
	_refresh()


func _on_fa_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_fa_user_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "FA自動判断に失敗しました。")), RED)
		return
	selected_fa_candidate_id = 0
	selected_fa_offer_years = 0
	_refresh()


func _on_fa_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_fa_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "FA自動進行に失敗しました。")), RED)
		return
	selected_fa_candidate_id = 0
	selected_fa_offer_years = 0
	_refresh()


# ============================================================ populate: 外国人契約市場

# AppState.foreign_state.contract_entries (value降順) を自軍/他球団の一覧行へ変換する。
# 支配下枠/外国人枠/予算のヘッダ表示は全ステップ共通の _draw_summary_panel が担う。
func _populate_foreign_contract() -> void:
	var state: Dictionary = AppState.foreign_state
	var user_team_id: int = AppState.selected_team_id
	_fgc_by_id = {}
	var offer_count: int = 0
	var home_entries: Array = []
	var away_entries: Array = []
	for row in state.get("contract_entries", []) as Array:
		var entry: Dictionary = row as Dictionary
		if bool(entry.get("resolved", false)):
			continue
		var pid: int = int(entry.get("player_id", 0))
		_fgc_by_id[pid] = entry
		if not (entry.get("user_offer", {}) as Dictionary).is_empty():
			offer_count += 1
		if int(entry.get("from_team_id", 0)) == user_team_id:
			home_entries.append(entry)
		else:
			away_entries.append(entry)
	_fgc_home_pitcher_rows = []
	_fgc_home_fielder_rows = []
	for row_value in _fgc_market_player_rows(home_entries):
		var record: PSPlayerSeasonRecord = (row_value as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if record != null and record.is_pitcher():
			_fgc_home_pitcher_rows.append(row_value)
		else:
			_fgc_home_fielder_rows.append(row_value)
	_fgc_away_pitcher_rows = []
	_fgc_away_fielder_rows = []
	for row_value in _fgc_market_player_rows(away_entries):
		var record: PSPlayerSeasonRecord = (row_value as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if record != null and record.is_pitcher():
			_fgc_away_pitcher_rows.append(row_value)
		else:
			_fgc_away_fielder_rows.append(row_value)
	var home_total: int = _fgc_home_pitcher_rows.size() + _fgc_home_fielder_rows.size()
	var away_total: int = _fgc_away_pitcher_rows.size() + _fgc_away_fielder_rows.size()
	_fgc_status_text = "外国人契約市場: 契約切れ 自軍%d人 / 他球団%d人 (提示中%d件)。残留を提示しない自軍選手は退団します (引き抜き時は移籍)。" % [
		home_total, away_total, offer_count,
	]
	_ensure_fgc_selection()


func _fgc_row_player_id(row_value: Variant) -> int:
	var record: PSPlayerSeasonRecord = (row_value as Dictionary).get("record", null) as PSPlayerSeasonRecord
	return record.player_id if record != null else 0


# 選択中の選手が表示中の表 (現在タブの自軍/他球団) に無ければ、自軍→他球団の順で先頭を選ぶ。
func _ensure_fgc_selection() -> void:
	var home_rows: Array = _fgc_home_pitcher_rows if _fgc_tab == PLAYER_TAB_PITCHER else _fgc_home_fielder_rows
	var away_rows: Array = _fgc_away_pitcher_rows if _fgc_tab == PLAYER_TAB_PITCHER else _fgc_away_fielder_rows
	var visible_ids: Dictionary = {}
	for row_value in home_rows:
		visible_ids[_fgc_row_player_id(row_value)] = true
	for row_value in away_rows:
		visible_ids[_fgc_row_player_id(row_value)] = true
	if selected_fgc_player_id > 0 and visible_ids.has(selected_fgc_player_id):
		return
	selected_fgc_player_id = 0
	selected_fgc_offer_years = 0
	if not home_rows.is_empty():
		selected_fgc_player_id = _fgc_row_player_id(home_rows[0])
	elif not away_rows.is_empty():
		selected_fgc_player_id = _fgc_row_player_id(away_rows[0])


func _set_fgc_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _fgc_tab == tab_id:
		return
	_fgc_tab = tab_id
	_ensure_fgc_selection()
	_build_buttons()
	queue_redraw()


# 提示年数チップ (FA の _build_fa_year_chips と同じ idiom)。1年〜entry.max_years を BODY 右上に並べる。
func _build_fgc_year_chips() -> void:
	if selected_fgc_player_id <= 0:
		return
	var entry: Dictionary = _fgc_by_id.get(selected_fgc_player_id, {}) as Dictionary
	if entry.is_empty():
		return
	var max_years: int = maxi(1, int(entry.get("max_years", 1)))
	var current_years: int = selected_fgc_offer_years if selected_fgc_offer_years > 0 else _fgc_default_offer_years(entry)
	var y: float = BODY.position.y + 16.0
	var x: float = BODY.end.x
	var widths: Array = []
	for n in range(1, max_years + 1):
		var w: float = 14.0 + _measure("%d年" % n, 13) + 14.0
		widths.append(w)
		x -= w + 8.0
	x += 8.0
	for n in range(1, max_years + 1):
		var label: String = "%d年" % n
		var w: float = float(widths[n - 1])
		_add_button("fgc_years_%d" % n, label, Rect2(x, y, w, 32.0),
			func(years: int = n) -> void: _select_fgc_offer_years(years),
			"chip_active" if n == current_years else "chip")
		x += w + 8.0


# 年数チップ未選択時の既定年数: 提示済みならその年数、なければ1年。
func _fgc_default_offer_years(entry: Dictionary) -> int:
	var offer: Dictionary = entry.get("user_offer", {}) as Dictionary
	return int(offer.get("years", 1)) if not offer.is_empty() else 1


func _select_fgc_offer_years(years: int) -> void:
	selected_fgc_offer_years = years
	_build_buttons()
	queue_redraw()


func _on_fgc_submit_pressed() -> void:
	if selected_fgc_player_id <= 0:
		_set_status("提示する選手を選択してください。", RED)
		return
	var entry: Dictionary = _fgc_by_id.get(selected_fgc_player_id, {}) as Dictionary
	var years: int = selected_fgc_offer_years if selected_fgc_offer_years > 0 else _fgc_default_offer_years(entry)
	var result: Dictionary = AppState.submit_foreign_contract_offer(selected_fgc_player_id, years)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "契約提示に失敗しました。")), RED)
		return
	_refresh()


func _on_fgc_withdraw_pressed() -> void:
	if selected_fgc_player_id <= 0:
		return
	var result: Dictionary = AppState.withdraw_foreign_contract_offer(selected_fgc_player_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "提示の取り下げに失敗しました。")), RED)
		return
	selected_fgc_offer_years = 0
	_refresh()


# 確定 = 自分の明示提示 + 他球団のCPU自動判断 (残留/引き抜き) で全エントリを解決する。
# 提示の無い自軍選手には残留提示を作らないため、他球団に引き抜かれなければ退団する。
func _on_foreign_contract_finalize_pressed() -> void:
	var offer_count: int = 0
	for entry_value in _fgc_by_id.values():
		if not ((entry_value as Dictionary).get("user_offer", {}) as Dictionary).is_empty():
			offer_count += 1
	var dialog: ConfirmationDialog = _ensure_fgc_confirm_dialog()
	dialog.dialog_text = "外国人契約市場を確定します。\n自分の提示 %d件を解決します。残留を提示しない自軍選手は退団します (他球団に引き抜かれた場合のみ移籍)。\n他球団はCPUが自動で残留/引き抜きを判断します。\nよろしいですか？" % offer_count
	dialog.popup_centered(Vector2i(560, 220))


func _ensure_fgc_confirm_dialog() -> ConfirmationDialog:
	if _fgc_confirm_dialog != null and is_instance_valid(_fgc_confirm_dialog):
		return _fgc_confirm_dialog
	_fgc_confirm_dialog = ConfirmationDialog.new()
	_fgc_confirm_dialog.title = "外国人契約市場の確認"
	_fgc_confirm_dialog.ok_button_text = "確定する"
	_fgc_confirm_dialog.cancel_button_text = "キャンセル"
	_fgc_confirm_dialog.confirmed.connect(_on_fgc_finalize_confirmed)
	add_child(_fgc_confirm_dialog)
	_style_confirmation_dialog(_fgc_confirm_dialog)
	return _fgc_confirm_dialog


func _on_fgc_finalize_confirmed() -> void:
	var result: Dictionary = AppState.finalize_foreign_contract_market()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人契約市場の確定に失敗しました。")), RED)
		return
	selected_fgc_player_id = 0
	selected_fgc_offer_years = 0
	_refresh()


# 「すべてAIに任せる」: 自軍もCPUと同じ基準 (_cpu_retain_offer) で自動残留判断させて確定する。
# 結果パネルには止まらず直接スカウトフェーズへ進む。
func _on_foreign_contract_ai_all_pressed() -> void:
	var result: Dictionary = AppState.auto_complete_foreign_contract_market()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人契約市場の自動判断に失敗しました。")), RED)
		return
	selected_fgc_player_id = 0
	selected_fgc_offer_years = 0
	_refresh()


# ============================================================ populate: 外国人契約市場・結果パネル

# 契約市場の結果パネル (phase="contract_result")。まだ offseason_results には入らないため
# AppState.foreign_state (contract_signings) を直接読む。
func _populate_foreign_contract_result() -> void:
	var state: Dictionary = AppState.foreign_state
	_fgc_contract_result_rows = _result_signing_player_rows(_fgc_result_entries(state))
	var retained: int = 0
	var poached: int = 0
	var departed: int = 0
	var multi_year: int = 0
	for row in state.get("contract_signings", []) as Array:
		var entry: Dictionary = row as Dictionary
		match str(entry.get("outcome", "")):
			"retained":
				retained += 1
			"poached":
				poached += 1
			_:
				departed += 1
		if int(entry.get("years", 0)) > 1:
			multi_year += 1
	_fgc_contract_result_heading = "外国人契約市場: 残留 %d人 / 移籍 %d人 / 退団 %d人 (複数年契約 %d件)" % [retained, poached, departed, multi_year]
	_result_people_tab = _player_tab_with_rows(_fgc_contract_result_rows, _result_people_tab)


func _draw_foreign_contract_result_panel() -> void:
	_draw_player_record_table(BODY, _fgc_contract_result_heading, _fgc_contract_result_rows,
		_result_people_tab == PLAYER_TAB_PITCHER, "", "foreign_contract_result_panel_%s" % _result_people_tab, "", 0,
		"該当する契約市場の結果がありません。", true, false, "fgc_result", true)


func _on_foreign_contract_result_next_pressed() -> void:
	var result: Dictionary = AppState.advance_foreign_contract_result()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "進行に失敗しました。")), RED)
		return
	_refresh()


# スカウトの結果パネル (phase="scout_result")。同じく AppState.foreign_state を直接読む
# (candidates/signings は finalize 前でも state 直下に既にある)。
func _populate_foreign_scout_result() -> void:
	var state: Dictionary = AppState.foreign_state
	_fgc_scout_result_rows = _result_signing_player_rows(state.get("signings", []) as Array)
	_fgc_scout_result_heading = "外国人スカウト獲得: 候補 %d人 / 獲得 %d人" % [
		(state.get("candidates", []) as Array).size(), _fgc_scout_result_rows.size(),
	]
	_result_people_tab = _player_tab_with_rows(_fgc_scout_result_rows, _result_people_tab)


func _draw_foreign_scout_result_panel() -> void:
	_draw_player_record_table(BODY, _fgc_scout_result_heading, _fgc_scout_result_rows,
		_result_people_tab == PLAYER_TAB_PITCHER, "", "foreign_scout_result_panel_%s" % _result_people_tab, "", 0,
		"今オフは外国人の獲得がありませんでした。", true, false, "team")


func _on_foreign_scout_result_next_pressed() -> void:
	var result: Dictionary = AppState.advance_foreign_scout_result()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "進行に失敗しました。")), RED)
		return
	_refresh()


# ============================================================ populate: 契約年数の決定

# AppState.contract_years_state.candidates (value降順) から自軍分を投手/野手タブの一覧行へ変換する。
# 他球団の候補は確定時にCPU基準で決まるので表示しない。
func _populate_contract_years() -> void:
	var state: Dictionary = AppState.contract_years_state
	_cy_pitcher_rows = []
	_cy_fielder_rows = []
	_cy_by_id = {}
	var decided_count: int = 0
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("team_id", 0)) != AppState.selected_team_id:
			continue
		var pid: int = int(entry.get("player_id", 0))
		_cy_by_id[pid] = entry
		if bool(entry.get("decided", false)):
			decided_count += 1
		var table_row: Dictionary = _cy_entry_row(entry)
		if table_row.is_empty():
			continue
		if int(entry.get("position", 0)) == 1:
			_cy_pitcher_rows.append(table_row)
		else:
			_cy_fielder_rows.append(table_row)
	var total: int = _cy_pitcher_rows.size() + _cy_fielder_rows.size()
	_cy_status_text = "契約年数の決定: 対象 %d人 / 決定済み %d人。全員決めるまで次へ進めません (「自動で決める」で残りを一括決定)。" % [total, decided_count]
	_ensure_cy_selection()


# 対象区分の表示ラベル。_build_contract_years_pool の reason と対応する。
const CONTRACT_YEARS_REASON_LABELS: Dictionary = {
	"new_fa": "FA権取得",
	"contract_end": "契約満了",
	"fa_returned": "FA残留",
}


# 候補1件を選手レコード表の行モデルへ変換する。契約情報 (決定年数/基準年俸/区分/現年俸) を entry へ積み、
# team_mode "contract_years" がこれらの値で 年俸/年数・FIP(盗塁)/WHIP(OAA) 相当の枠を差し替えて描画する。
# 契約市場の `_fgc_market_player_rows` と同じ形。
func _cy_entry_row(entry: Dictionary) -> Dictionary:
	var pid: int = int(entry.get("player_id", 0))
	var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
	if record == null:
		return {}
	var player: PSPlayer = GameDb.get_player(pid)
	var decided: bool = bool(entry.get("decided", false))
	var years: int = maxi(1, int(entry.get("years", 1)))
	var decided_salary: int = int(entry.get("salary", 0))
	var current_salary: int = player.salary if player != null else int(entry.get("current_salary", 0))
	var row_entry: Dictionary = {
		"player_id": pid,
		"team_id": int(entry.get("team_id", 0)),
		"position": int(entry.get("position", record.position)),
		"role": str(entry.get("role", record.role)),
		"salary": current_salary,
		# 年数枠に決定状態そのものを出す (未決定は AMBER で目立たせる)。
		"fgc_years_text": ("単年" if years <= 1 else "%d年" % years) if decided else "未決定",
		"fgc_years_color": (TEXT if years <= 1 else BLUE) if decided else AMBER,
		# 基準年俸は決定済みならその年数での年俸、未決定なら単年ベースの査定額
		# (entry.salary は未決定のとき 0 なので base_salary へフォールバックする)。
		"market_salary_text": _format_money_compact(decided_salary if decided_salary > 0 else int(entry.get("base_salary", 0))),
		"fgc_current_salary_text": _format_money_compact(current_salary),
		"offer_text": str(CONTRACT_YEARS_REASON_LABELS.get(str(entry.get("reason", "")), "")),
		"offer_color": MUTED,
	}
	return {"record": record, "player": player, "entry": row_entry}


# 選択中の選手が現在タブに無ければ、そのタブの先頭候補を選ぶ。
func _ensure_cy_selection() -> void:
	var rows: Array = _cy_pitcher_rows if _cy_tab == PLAYER_TAB_PITCHER else _cy_fielder_rows
	var ids: Array = []
	for row_value in rows:
		var record: PSPlayerSeasonRecord = (row_value as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if record != null:
			ids.append(record.player_id)
	if selected_cy_player_id > 0 and ids.has(selected_cy_player_id):
		return
	selected_cy_player_id = 0
	selected_cy_years = 0
	if not ids.is_empty():
		selected_cy_player_id = int(ids[0])


func _set_cy_tab(tab_id: String) -> void:
	if tab_id != PLAYER_TAB_PITCHER and tab_id != PLAYER_TAB_FIELDER:
		return
	if _cy_tab == tab_id:
		return
	_cy_tab = tab_id
	_ensure_cy_selection()
	_build_buttons()
	queue_redraw()


# 契約年数チップ (_build_fgc_year_chips と同じ idiom)。単年も明示的な選択肢なので range は 1〜max_years。
func _build_cy_year_chips() -> void:
	if selected_cy_player_id <= 0:
		return
	var entry: Dictionary = _cy_by_id.get(selected_cy_player_id, {}) as Dictionary
	if entry.is_empty():
		return
	var max_years: int = maxi(1, int(entry.get("max_years", 1)))
	var current_years: int = selected_cy_years if selected_cy_years > 0 else _cy_default_years(entry)
	var y: float = BODY.position.y + 16.0
	var x: float = BODY.end.x
	var widths: Array = []
	for n in range(1, max_years + 1):
		var w: float = 14.0 + _measure(_cy_year_label(n), 13) + 14.0
		widths.append(w)
		x -= w + 8.0
	x += 8.0
	for i in range(widths.size()):
		var n: int = i + 1
		var w: float = float(widths[i])
		_add_button("cy_years_%d" % n, _cy_year_label(n), Rect2(x, y, w, 32.0),
			func(years: int = n) -> void: _select_cy_years(years),
			"chip_active" if n == current_years else "chip")
		x += w + 8.0


func _cy_year_label(years: int) -> String:
	return "単年" if years <= 1 else "%d年" % years


# 年数チップ未選択時の既定年数: 決定済みならその年数、なければ単年。
func _cy_default_years(entry: Dictionary) -> int:
	return maxi(1, int(entry.get("years", 1))) if bool(entry.get("decided", false)) else 1


func _select_cy_years(years: int) -> void:
	selected_cy_years = years
	_build_buttons()
	queue_redraw()


func _on_cy_submit_pressed() -> void:
	if selected_cy_player_id <= 0:
		_set_status("契約年数を決める選手を選択してください。", RED)
		return
	var entry: Dictionary = _cy_by_id.get(selected_cy_player_id, {}) as Dictionary
	var years: int = selected_cy_years if selected_cy_years > 0 else _cy_default_years(entry)
	var result: Dictionary = AppState.submit_contract_years(selected_cy_player_id, years)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "契約年数の決定に失敗しました。")), RED)
		return
	_refresh()


func _on_cy_withdraw_pressed() -> void:
	if selected_cy_player_id <= 0:
		return
	var result: Dictionary = AppState.withdraw_contract_years(selected_cy_player_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "決定の取り消しに失敗しました。")), RED)
		return
	selected_cy_years = 0
	_refresh()


# 自軍の未決定分をCPUと同じ基準 (価値/年齢/予算) で決め、そのまま確定まで進める
# (決めてから確定ボタンを押させるのは二度手間なので、戦力外編集の「自動で決定して次へ」と同じ扱い)。
func _on_cy_auto_pressed() -> void:
	var auto_result: Dictionary = AppState.auto_decide_contract_years()
	if not bool(auto_result.get("ok", false)):
		_set_status(str(auto_result.get("message", "自動決定に失敗しました。")), RED)
		return
	var result: Dictionary = AppState.finalize_contract_years()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "契約年数の確定に失敗しました。")), RED)
		return
	selected_cy_player_id = 0
	selected_cy_years = 0
	_refresh()


# 確定 = 自軍の決定内容を適用し、他球団の候補をCPU基準で一括決定する。
func _on_cy_finalize_pressed() -> void:
	var pending: int = AppState.pending_contract_years_count()
	if pending > 0:
		_set_status("契約年数が未決定の選手が %d 人います。" % pending, RED)
		return
	var multi_year: int = 0
	for entry_value in _cy_by_id.values():
		if int((entry_value as Dictionary).get("years", 1)) >= 2:
			multi_year += 1
	var dialog: ConfirmationDialog = _ensure_cy_confirm_dialog()
	dialog.dialog_text = "決めた契約年数で確定します。\n自軍 %d人 (うち複数年 %d人)。\nよろしいですか？" % [_cy_by_id.size(), multi_year]
	dialog.popup_centered(Vector2i(520, 210))


func _ensure_cy_confirm_dialog() -> ConfirmationDialog:
	if _cy_confirm_dialog != null and is_instance_valid(_cy_confirm_dialog):
		return _cy_confirm_dialog
	_cy_confirm_dialog = ConfirmationDialog.new()
	_cy_confirm_dialog.title = "契約年数の確認"
	_cy_confirm_dialog.ok_button_text = "確定する"
	_cy_confirm_dialog.cancel_button_text = "キャンセル"
	_cy_confirm_dialog.confirmed.connect(_on_cy_finalize_confirmed)
	add_child(_cy_confirm_dialog)
	_style_confirmation_dialog(_cy_confirm_dialog)
	return _cy_confirm_dialog


func _on_cy_finalize_confirmed() -> void:
	var result: Dictionary = AppState.finalize_contract_years()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "契約年数の確定に失敗しました。")), RED)
		return
	selected_cy_player_id = 0
	selected_cy_years = 0
	_refresh()


# ============================================================ populate: 外国人補強

func _populate_foreign() -> void:
	var state: Dictionary = AppState.foreign_state
	var candidates: Array = ForeignPlayerService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var current_foreign: int = _active_foreign_count(AppState.selected_team_id)
	var user_signings: int = 0
	for row in state.get("signings", []) as Array:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	var request_ready: bool = not (state.get("user_request", {}) as Dictionary).is_empty()
	_foreign_status_text = "外国人補強: 現在%d人 / 今オフ獲得%d人 / 上限4 / %s" % [
		current_foreign, user_signings, "候補%d人" % candidates.size() if request_ready else "条件を選んで候補を検索してください",
	]
	# 一覧はドラフトと同じ候補ボード。中央2列は 評価(tier) / 年俸。
	_foreign_record_cache = {}
	_foreign_candidate_rows = []
	_foreign_by_id = {}
	var rank: int = 0
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		var cid: int = int(c.get("candidate_id", 0))
		_foreign_by_id[cid] = c
		rank += 1
		_foreign_candidate_rows.append(_foreign_candidate_row(c, rank))
	if selected_foreign_candidate_id > 0 and not _foreign_by_id.has(selected_foreign_candidate_id):
		selected_foreign_candidate_id = 0
	if selected_foreign_candidate_id <= 0:
		var visible: Array = _candidate_rows_for_tab(_foreign_candidate_rows, "all")
		if not visible.is_empty():
			selected_foreign_candidate_id = int((visible[0] as Dictionary).get("candidate_id", 0))
	_foreign_can_submit = selected_foreign_candidate_id > 0


# 外国人候補1件を候補ボード用モデルに変換。中央2列は 評価(tier短縮) / 年俸(万)。
func _foreign_candidate_row(c: Dictionary, rank: int) -> Dictionary:
	var template: Dictionary = c.get("display_player_data", c.get("player_data", {})) as Dictionary
	var position: int = int(c.get("position", 0))
	return {
		"candidate_id": int(c.get("candidate_id", 0)),
		"name": str(c.get("name", "")),
		"age": int(c.get("age", 0)),
		"overall": int(c.get("estimated_value", c.get("value", 0))),
		"rank": rank,
		"info1": _foreign_archetype_short(str(c.get("archetype", "balanced"))),
		"info2": str(int(c.get("salary", 0))),
		"info2_color": TEXT,
		"is_pitcher": position == 1,
		"position": position,
		"role": str(template.get("role", "starter")),
		"aptitudes": template.get("position_aptitudes", {}) as Dictionary,
		"arsenal": template.get("arsenal", []) as Array,
		"template": template,
	}


func _foreign_board_tab() -> String:
	if not _foreign_candidate_rows.is_empty():
		return "pitcher" if bool((_foreign_candidate_rows[0] as Dictionary).get("is_pitcher", false)) else "fielder"
	return "pitcher" if _foreign_request_position == "starter" or _foreign_request_position == "reliever" else "fielder"


func _foreign_ability_range_text(candidate: Dictionary) -> String:
	var template: Dictionary = candidate.get("display_player_data", candidate.get("player_data", {})) as Dictionary
	var result: Dictionary = PlayerVisibleRatings.ratings_for_player_data(template)
	var estimate_downside: int = maxi(0, int(candidate.get("estimate_downside", candidate.get("uncertainty", 4))))
	var estimate_upside: int = maxi(0, int(candidate.get("estimate_upside", candidate.get("uncertainty", 4))))
	var parts: Array = []
	for rating_value in result.get("display_ratings", []) as Array:
		var rating: Dictionary = rating_value as Dictionary
		var value: int = int(rating.get("display_value", 0))
		var suffix: String = str(rating.get("suffix", ""))
		var downside: int = int(ceil(float(estimate_downside) / 2.0)) if suffix == "km/h" else estimate_downside
		var upside: int = int(ceil(float(estimate_upside) / 2.0)) if suffix == "km/h" else estimate_upside
		var low: int = maxi(1, value - downside)
		var high: int = value + upside if suffix == "km/h" else mini(100, value + upside)
		parts.append("%s %d〜%d%s" % [str(rating.get("label", "")), low, high, suffix])
	return "能力推定: %s" % " / ".join(parts)


func _foreign_archetype_short(archetype: String) -> String:
	var labels: Dictionary = {
		"balanced": "万能", "power": "長打", "contact": "巧打", "discipline": "選球",
		"speed_defense": "走守", "defense": "守備", "strikeout": "奪三振", "control": "制球",
		"groundball": "ゴロ", "stamina": "持久",
	}
	return str(labels.get(archetype, archetype))


func _select_foreign_position(position: String) -> void:
	_foreign_request_position = position
	var pitcher_request: bool = position == "starter" or position == "reliever"
	var allowed: Array = FOREIGN_PITCHER_TYPES if pitcher_request else FOREIGN_FIELDER_TYPES
	var allowed_ids: Array = []
	for option_value in allowed:
		allowed_ids.append(str((option_value as Dictionary).get("id", "")))
	if not allowed_ids.has(_foreign_request_archetype) or position == "any":
		_foreign_request_archetype = "balanced"
	_build_buttons()
	queue_redraw()


func _select_foreign_archetype(archetype: String) -> void:
	_foreign_request_archetype = archetype
	_build_buttons()
	queue_redraw()


func _select_foreign_budget(budget: String) -> void:
	_foreign_request_budget = budget
	_build_buttons()
	queue_redraw()


func _on_foreign_search_pressed() -> void:
	var result: Dictionary = AppState.configure_foreign_scout_request(
		_foreign_request_position, _foreign_request_archetype, _foreign_request_budget
	)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人候補の検索に失敗しました。")), RED)
		return
	selected_foreign_candidate_id = 0
	_refresh()


func _on_foreign_submit_pressed() -> void:
	if selected_foreign_candidate_id <= 0:
		_set_status("外国人候補を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_foreign_candidate(selected_foreign_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人獲得に失敗しました。")), RED)
		return
	selected_foreign_candidate_id = 0
	_refresh()


func _on_foreign_skip_pressed() -> void:
	if selected_foreign_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_foreign_candidate(selected_foreign_candidate_id)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人見送りに失敗しました。")), RED)
		return
	selected_foreign_candidate_id = 0
	_refresh()


func _on_foreign_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_foreign_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人自動進行に失敗しました。")), RED)
		return
	selected_foreign_candidate_id = 0
	_refresh()


func _on_foreign_ai_all_pressed() -> void:
	var result: Dictionary = AppState.complete_all_foreign_automatically()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "外国人補強のAI進行に失敗しました。")), RED)
		return
	selected_foreign_candidate_id = 0
	_refresh()


# ============================================================ populate: キャンプ

func _populate_camp() -> void:
	var state: Dictionary = AppState.camp_state
	_camp_complete = bool(state.get("complete", false))
	var user_actions: int = 0
	for row in state.get("actions", []) as Array:
		if int((row as Dictionary).get("team_id", 0)) == AppState.selected_team_id:
			user_actions += 1
	var roster_players: Array = _camp_roster_players()
	_camp_status_text = "キャンプ: 自軍特別練習 %d/%d件 / 選手%d人" % [
		user_actions, CampServiceRef.MAX_SPECIAL_TRAININGS_PER_TEAM, roster_players.size(),
	]
	var trained: Dictionary = _camp_trained_player_set(state)
	var roster_ids: Dictionary = {}
	# 総合降順にソートして候補ボード用の行を作る (# は総合順位)。レーティング用 record はここで cache へ。
	_camp_record_cache = {}
	var ranked: Array = []
	for player_row in roster_players:
		var roster_player: PSPlayer = player_row as PSPlayer
		roster_ids[roster_player.id] = true
		var record: PSPlayerSeasonRecord = _current_record_for_player(roster_player)
		_camp_record_cache[roster_player.id] = record
		ranked.append({"player": roster_player, "overall": PlayerValueEvaluator.overall_score(record)})
	ranked.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)
	_camp_candidate_rows = []
	var rank: int = 0
	for entry_value in ranked:
		var entry: Dictionary = entry_value as Dictionary
		rank += 1
		_camp_candidate_rows.append(_camp_candidate_row(entry["player"] as PSPlayer, int(entry["overall"]), rank, trained))
	if selected_camp_player_id > 0 and not roster_ids.has(selected_camp_player_id):
		selected_camp_player_id = 0
	if selected_camp_player_id <= 0:
		var visible: Array = _candidate_rows_for_tab(_camp_candidate_rows, _camp_tab)
		if not visible.is_empty():
			selected_camp_player_id = int((visible[0] as Dictionary).get("candidate_id", 0))

	_camp_options = []
	_camp_types = []
	_camp_positions = []
	_camp_selected_option = {}
	_camp_can_submit = false
	_camp_detail_text = "選手を選択してください。"
	if selected_camp_player_id <= 0:
		return
	_camp_options = CampServiceRef.user_training_options_for_player(state, GameDb.players, AppState.current_season, selected_camp_player_id)
	if _camp_options.is_empty():
		selected_camp_training_type = ""
		selected_camp_target_position = 0
		_camp_detail_text = _format_camp_unavailable_player(selected_camp_player_id)
		return

	var seen_types: Dictionary = {}
	for option_row in _camp_options:
		var option: Dictionary = option_row as Dictionary
		var training_type: String = str(option.get("training_type", ""))
		if seen_types.has(training_type):
			continue
		seen_types[training_type] = true
		_camp_types.append({"type": training_type, "label": str(option.get("training_label", ""))})
	if not seen_types.has(selected_camp_training_type):
		selected_camp_training_type = str((_camp_types[0] as Dictionary).get("type", ""))

	for option_row in _camp_options:
		var option: Dictionary = option_row as Dictionary
		if str(option.get("training_type", "")) != selected_camp_training_type:
			continue
		var pos: int = int(option.get("target_position", 0))
		if pos > 0:
			_camp_positions.append({"pos": pos, "name": str(option.get("target_position_name", _position_name(pos)))})
	if not _camp_positions.is_empty():
		var pos_set: Dictionary = {}
		for p in _camp_positions:
			pos_set[int((p as Dictionary).get("pos", 0))] = true
		if not pos_set.has(selected_camp_target_position):
			selected_camp_target_position = int((_camp_positions[0] as Dictionary).get("pos", 0))
	else:
		selected_camp_target_position = 0

	var selected_option: Dictionary = _selected_camp_option(_camp_options)
	_camp_selected_option = selected_option
	_camp_can_submit = not selected_option.is_empty()
	_camp_detail_text = _format_camp_details(selected_option)


func _camp_roster_players() -> Array:
	var rows: Array = []
	var team_id: int = AppState.selected_team_id
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired():
			continue
		rows.append(player)
	return rows


# キャンプ選手1人を候補ボード用モデルに変換。中央2列 (info1/info2) は使わない (空欄)。
func _camp_candidate_row(player: PSPlayer, overall: int, rank: int, _trained: Dictionary) -> Dictionary:
	return {
		"candidate_id": player.id,
		"name": player.name,
		"age": player.age,
		"overall": overall,
		"rank": rank,
		"info1": "",
		"info2": "",
		"info2_color": MUTED,
		"is_pitcher": player.is_pitcher(),
		"is_development": player.development_player,
		"position": player.position,
		"role": _resolved_pitcher_role(player.role, {}) if player.is_pitcher() else "fielder",
		"aptitudes": player.position_aptitudes,
		"arsenal": player.arsenal,
		"template": player.to_dict(),
	}


func _camp_trained_player_set(state: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for id_value in state.get("trained_player_ids", []) as Array:
		out[int(id_value)] = true
	return out


func _selected_camp_option(options: Array) -> Dictionary:
	for option_row in options:
		var option: Dictionary = option_row as Dictionary
		if str(option.get("training_type", "")) != selected_camp_training_type:
			continue
		if int(option.get("target_position", 0)) == selected_camp_target_position:
			return option
	return {}


func _format_camp_unavailable_player(player_id: int) -> String:
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null:
		return "選手を選択してください。"
	var lines: Array = []
	lines.append("%s  %s" % [player.name, _player_role_or_position(player)])
	if _camp_trained_player_set(AppState.camp_state).has(player.id):
		lines.append("この選手は今オフに特別練習済みです。")
	elif player.injury_days > 0:
		lines.append("怪我のため今オフの特別練習は選択できません。")
	else:
		lines.append("選択できる特別練習がありません。")
	lines.append("")
	lines.append("能力")
	lines.append(PlayerVisibleRatings.summary_line_for_player_data(player.to_dict()))
	return "\n".join(lines)


func _camp_training_target(candidate: Dictionary) -> String:
	var target_position: int = int(candidate.get("target_position", 0))
	if target_position > 0:
		return _position_name(target_position)
	var training_type: String = str(candidate.get("training_type", ""))
	if training_type == CampServiceRef.TRAIN_STARTER:
		return "先発"
	if training_type == CampServiceRef.TRAIN_RELIEVER:
		return "中継"
	return ""


func _format_camp_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "選手を選択し、特別練習を指定してください。"
	var player: PSPlayer = GameDb.get_player(int(candidate.get("player_id", 0)))
	var target_position: int = int(candidate.get("target_position", 0))
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _dict_role_or_position(candidate)])
	lines.append("%d歳  練習 %s  対象 %s" % [int(candidate.get("age", 0)), str(candidate.get("training_label", "")), _camp_training_target(candidate)])
	lines.append("成功率 %0.1f%%  リスク %s" % [float(candidate.get("success_chance", 0.0)) * 100.0, str(candidate.get("risk_label", "中"))])
	lines.append("理由: %s" % str(candidate.get("reason", "")))
	if target_position > 0:
		var current: int = _player_position_aptitude_for_ui(player, target_position)
		lines.append("対象適性: %s  現在 %d  成功時 %d" % [_position_name(target_position), current, int(candidate.get("projected_aptitude", 0))])
	if player != null:
		lines.append("")
		lines.append("能力")
		lines.append(PlayerVisibleRatings.summary_line_for_player_data(player.to_dict()))
		if player.is_pitcher():
			var arsenal_text: String = PSPitchTypes.arsenal_line(player.arsenal)
			if not arsenal_text.is_empty():
				lines.append("")
				lines.append("球種")
				lines.append(arsenal_text)
	return "\n".join(lines)


func _player_position_aptitude_for_ui(player: PSPlayer, pos: int) -> int:
	if player == null or pos < 3 or pos > 9:
		return 0
	var key: String = PSPlayer.position_experience_key(pos)
	if key.is_empty():
		return 0
	if player.position_aptitudes.is_empty():
		return 100 if player.position == pos else 0
	return int(player.position_aptitudes.get(key, 0))


func _on_camp_submit_pressed() -> void:
	if selected_camp_player_id <= 0 or selected_camp_training_type.is_empty():
		_set_status("選手と特別練習を選択してください。", RED)
		return
	var result: Dictionary = AppState.submit_camp_player_training(selected_camp_player_id, selected_camp_training_type, selected_camp_target_position)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "特別練習の実行に失敗しました。")), RED)
		return
	_refresh()


func _on_camp_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_camp_user_pick()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "キャンプ自動判断に失敗しました。")), RED)
		return
	selected_camp_player_id = 0
	selected_camp_training_type = ""
	selected_camp_target_position = 0
	_refresh()


func _on_camp_finish_pressed() -> void:
	var result: Dictionary = AppState.finish_camp()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "キャンプ終了に失敗しました。")), RED)
		return
	selected_camp_player_id = 0
	selected_camp_training_type = ""
	selected_camp_target_position = 0
	_refresh()


func _camp_action_change_pair(action: Dictionary) -> Dictionary:
	if not bool(action.get("success", false)):
		return {"before": "", "after": ""}
	var target_position: int = int(action.get("target_position", 0))
	if target_position > 0:
		var old_pos: int = int(action.get("old_position", 0))
		var new_pos: int = int(action.get("new_position", 0))
		if old_pos != new_pos:
			return {
				"before": _position_char(old_pos),
				"before_color": _pos_color(old_pos),
				"after": _position_char(new_pos),
				"after_color": _pos_color(new_pos),
			}
		return {"before": "", "after": ""}
	var old_role: String = str(action.get("old_role", ""))
	var new_role: String = str(action.get("new_role", ""))
	if old_role != new_role:
		return {
			"before": _role_char(old_role),
			"before_color": _role_color(old_role),
			"after": _role_char(new_role),
			"after_color": _role_color(new_role),
		}
	return {"before": "", "after": ""}


func _camp_result_color(action: Dictionary) -> Color:
	if bool(action.get("success", false)):
		return GREEN
	if bool(action.get("penalty", false)):
		return RED
	return AMBER


func _growth_result_color(entry: Dictionary) -> Color:
	match str(entry.get("growth_kind", "")):
		"awakening":
			return BLUE
		"growth":
			return GREEN
		"stagnation":
			return TEXT
		"decline":
			return AMBER
		"major_decline":
			return RED
		_:
			var delta: int = int(entry.get("delta", 0))
			if delta > 0:
				return GREEN
			if delta < 0:
				return AMBER
			return TEXT


# ============================================================ 成長 / 人物 行整形

func _ability_cell(value: int, suffix: String = "") -> Dictionary:
	return {"after": value, "delta": 0, "suffix": suffix}


func _set_growth_cell(row: Dictionary, key: String, cell: Dictionary) -> void:
	if key.is_empty():
		return
	row[key] = {
		"after": int(cell.get("after", 0)),
		"delta": int(cell.get("delta", 0)),
		"suffix": str(cell.get("suffix", "")),
	}


func _fill_result_ability_cells(row: Dictionary, entry: Dictionary) -> void:
	var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
	if record == null:
		var fallback: int = int(entry.get("value", entry.get("overall", 0)))
		if fallback > 0:
			row["overall_cell"] = _ability_cell(fallback)
		return
	var overall: int = PlayerValueEvaluator.overall_score(record)
	row["overall_cell"] = _ability_cell(overall)
	if record.is_pitcher():
		row["velocity"] = _ability_cell(PlayerVisibleRatings.pitcher_velocity(record), "km/h")
		row["stuff"] = _ability_cell(PlayerVisibleRatings.pitcher_stuff(record))
		row["control"] = _ability_cell(PlayerVisibleRatings.pitcher_control(record))
		row["stamina"] = _ability_cell(PlayerVisibleRatings.pitcher_stamina(record))
	else:
		row["contact"] = _ability_cell(PlayerVisibleRatings.fielder_contact(record))
		row["power"] = _ability_cell(PlayerVisibleRatings.fielder_power(record))
		row["speed"] = _ability_cell(PlayerVisibleRatings.fielder_speed(record))
		row["defense"] = _ability_cell(PlayerVisibleRatings.fielder_defense(record))
		row["arm"] = _ability_cell(PlayerVisibleRatings.fielder_arm(record))
		row["discipline"] = _ability_cell(PlayerVisibleRatings.fielder_discipline(record))


func _fill_growth_detail_cells(row: Dictionary, entry: Dictionary) -> void:
	if bool(entry.get("is_pitcher", false)):
		var pitch_changes: Array = entry.get("pitch_changes", []) as Array
		if not pitch_changes.is_empty():
			for i in range(min(pitch_changes.size(), PSPitchTypes.ALL_TYPES.size())):
				var detail: Dictionary = pitch_changes[i] as Dictionary
				var value: int = int(detail.get("after", -1))
				if value >= 0:
					_set_growth_cell(row, "pitch_%d" % i, {"after": value, "delta": int(detail.get("delta", 0)), "suffix": ""})
		else:
			var pitch_entries: Array = _draft_pitch_value_entries(entry.get("arsenal", []) as Array)
			for i in range(pitch_entries.size()):
				var detail: Dictionary = pitch_entries[i] as Dictionary
				var value: int = int(detail.get("value", -1))
				if value >= 0:
					_set_growth_cell(row, "pitch_%d" % i, _ability_cell(value))
	else:
		var aptitude_changes: Dictionary = entry.get("aptitude_changes", {}) as Dictionary
		if not aptitude_changes.is_empty():
			for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
				var cell: Dictionary = aptitude_changes.get(pos, aptitude_changes.get(str(pos), {})) as Dictionary
				if cell.is_empty():
					continue
				var after: int = int(cell.get("after", -1))
				if after >= 0:
					_set_growth_cell(row, "apt_%d" % pos, {"after": after, "delta": int(cell.get("delta", 0)), "suffix": ""})
		else:
			var aptitudes: Dictionary = entry.get("aptitudes", {}) as Dictionary
			for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
				var key: String = str(PSPlayer.POSITION_EXPERIENCE_KEYS.get(pos, ""))
				var apt: int = int(aptitudes.get(key, 0))
				if apt > 0:
					_set_growth_cell(row, "apt_%d" % pos, _ability_cell(apt))


func _fill_camp_aptitude_cells(row: Dictionary, action: Dictionary) -> void:
	var aptitudes: Dictionary = action.get("aptitudes", {}) as Dictionary
	var target_position: int = int(action.get("target_position", 0))
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		var key: String = str(PSPlayer.POSITION_EXPERIENCE_KEYS.get(pos, ""))
		var after: int = int(aptitudes.get(key, 0))
		var before: int = after
		if pos == target_position:
			before = int(action.get("aptitude_before", after))
			after = int(action.get("aptitude_after", after))
		var delta: int = after - before
		if after > 0 or delta != 0:
			_set_growth_cell(row, "apt_%d" % pos, {"after": after, "delta": delta, "suffix": ""})


func _people_rows(people: Array) -> Array:
	var rows: Array = []
	for entry_row in people:
		var entry: Dictionary = entry_row as Dictionary
		var badge: Dictionary = _pick_pos_badge(entry)
		rows.append({
			"team": _team_short(int(entry.get("team_id", 0))),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"pos": str(badge.get("text", "")),
			"pos_color": badge.get("color", MUTED) as Color,
			"years": int(entry.get("years", 0)),
			"overall": int(entry.get("overall", 0)),
		})
	return rows


func _growth_rows(entries: Array) -> Array:
	var rows: Array = []
	for entry_row in entries:
		var entry: Dictionary = entry_row as Dictionary
		var after: int = int(entry.get("after", 0))
		var delta: int = int(entry.get("delta", 0))
		var badge: Dictionary = _pick_pos_badge(entry)
		var gp: PSPlayer = GameDb.get_player(int(entry.get("player_id", 0)))
		var row: Dictionary = {
			"pos": str(badge.get("text", "")),
			"pos_color": badge.get("color", MUTED) as Color,
			"pos_dev": gp != null and gp.development_player,
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"kind": str(entry.get("growth_label", entry.get("result_label", ""))),
			"kind_color": _growth_result_color(entry),
			"delta": delta,
		}
		_set_growth_cell(row, "overall_cell", {"after": after, "delta": delta, "suffix": ""})
		for ability_row in entry.get("abilities", []) as Array:
			var ability: Dictionary = ability_row as Dictionary
			_set_growth_cell(row, str(ability.get("key", "")), {
				"after": int(ability.get("after", 0)),
				"delta": int(ability.get("delta", 0)),
				"suffix": str(ability.get("suffix", "")),
			})
		_fill_growth_detail_cells(row, entry)
		rows.append(row)
	return rows


func _release_visible_records() -> Array:
	if _release_tab == PLAYER_TAB_FIELDER:
		return _release_fielder_records
	return _release_pitcher_records


func _released_visible_player_rows() -> Array:
	var visible: Array = []
	for row_value in _released_player_rows:
		var row: Dictionary = _player_row_model(row_value)
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		if (record.is_pitcher() and _released_tab == PLAYER_TAB_PITCHER) or (not record.is_pitcher() and _released_tab == PLAYER_TAB_FIELDER):
			visible.append(row)
	return visible


func _player_row_pitcher_fielder_counts(rows: Array) -> Dictionary:
	var counts: Dictionary = {PLAYER_TAB_PITCHER: 0, PLAYER_TAB_FIELDER: 0}
	for row_value in rows:
		var row: Dictionary = _player_row_model(row_value)
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		var key: String = PLAYER_TAB_PITCHER if record.is_pitcher() else PLAYER_TAB_FIELDER
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


# 選手レコード表 (戦力外獲得 / FA) 共通のタブ補助。指定タブで見える行のみを返す。
func _player_visible_rows_for_tab(rows: Array, tab: String) -> Array:
	var visible: Array = []
	for row_value in rows:
		var row: Dictionary = _player_row_model(row_value)
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		if (record.is_pitcher() and tab == PLAYER_TAB_PITCHER) or (not record.is_pitcher() and tab == PLAYER_TAB_FIELDER):
			visible.append(row)
	return visible


# 現タブが空なら、行のある反対タブへ切り替えた結果のタブ id を返す。
func _player_tab_with_rows(rows: Array, tab: String) -> String:
	var counts: Dictionary = _player_row_pitcher_fielder_counts(rows)
	if int(counts.get(tab, 0)) > 0:
		return tab
	var other: String = PLAYER_TAB_FIELDER if tab == PLAYER_TAB_PITCHER else PLAYER_TAB_PITCHER
	return other if int(counts.get(other, 0)) > 0 else tab


# 選択中 id が現タブで見えるなら維持、見えなければ先頭行の player_id (なければ 0)。
func _player_first_visible_id(rows: Array, tab: String, selected_id: int) -> int:
	var visible: Array = _player_visible_rows_for_tab(rows, tab)
	for row_value in visible:
		var record: PSPlayerSeasonRecord = (row_value as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if record != null and record.player_id == selected_id:
			return selected_id
	if visible.is_empty():
		return 0
	var first: PSPlayerSeasonRecord = (visible[0] as Dictionary).get("record", null) as PSPlayerSeasonRecord
	return first.player_id if first != null else 0


func _normalize_released_tab() -> void:
	var counts: Dictionary = _player_row_pitcher_fielder_counts(_released_player_rows)
	if int(counts.get(_released_tab, 0)) > 0:
		return
	var other: String = PLAYER_TAB_FIELDER if _released_tab == PLAYER_TAB_PITCHER else PLAYER_TAB_PITCHER
	if int(counts.get(other, 0)) > 0:
		_released_tab = other


func _ensure_released_selection_for_tab() -> void:
	var visible: Array = _released_visible_player_rows()
	if visible.is_empty():
		selected_released_candidate_id = 0
		_released_can_submit = false
		return
	for row_value in visible:
		var row: Dictionary = row_value as Dictionary
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		if record != null and record.player_id == selected_released_candidate_id:
			_released_can_submit = selected_released_candidate_id > 0
			return
	var first: Dictionary = visible[0] as Dictionary
	var first_record: PSPlayerSeasonRecord = first.get("record", null) as PSPlayerSeasonRecord
	selected_released_candidate_id = first_record.player_id if first_record != null else 0
	_released_can_submit = selected_released_candidate_id > 0


func _player_row_model(row_value: Variant) -> Dictionary:
	if row_value is Dictionary:
		return row_value as Dictionary
	var record: PSPlayerSeasonRecord = row_value as PSPlayerSeasonRecord
	if record == null:
		return {}
	var player: PSPlayer = GameDb.get_player(record.player_id)
	return {
		"record": record,
		"player": player,
		"entry": {
			"player_id": record.player_id,
			"team_id": record.team_id,
			"position": record.position,
			"role": record.role,
		},
	}


func _people_player_rows_for_tab(people: Array, tab_id: String) -> Array:
	var rows: Array = []
	for entry_row in people:
		var entry: Dictionary = entry_row as Dictionary
		var is_pitcher: bool = _entry_is_pitcher(entry)
		if (tab_id == PLAYER_TAB_PITCHER) != is_pitcher:
			continue
		var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
		if record == null:
			continue
		rows.append({
			"record": record,
			"player": GameDb.get_player(record.player_id),
			"entry": entry,
		})
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ra: PSPlayerSeasonRecord = (a as Dictionary).get("record", null) as PSPlayerSeasonRecord
		var rb: PSPlayerSeasonRecord = (b as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if ra == null or rb == null:
			return false
		var ea: Dictionary = (a as Dictionary).get("entry", {}) as Dictionary
		var eb: Dictionary = (b as Dictionary).get("entry", {}) as Dictionary
		if int(ea.get("team_id", 0)) != int(eb.get("team_id", 0)):
			return int(ea.get("team_id", 0)) < int(eb.get("team_id", 0))
		return PlayerValueEvaluator.overall_score(ra) > PlayerValueEvaluator.overall_score(rb)
	)
	return rows


func _result_signing_player_rows(signings: Array) -> Array:
	var rows: Array = []
	for entry_row in signings:
		var entry: Dictionary = entry_row as Dictionary
		var record: PSPlayerSeasonRecord = _record_for_people_entry(entry)
		if record == null:
			continue
		var pid: int = int(entry.get("player_id", record.player_id))
		var row_entry: Dictionary = entry.duplicate(true)
		row_entry["player_id"] = pid
		row_entry["team_id"] = int(entry.get("to_team", entry.get("team_id", record.team_id)))
		row_entry["position"] = int(entry.get("position", record.position))
		row_entry["role"] = str(entry.get("role", record.role))
		rows.append({
			"record": record,
			"player": GameDb.get_player(pid),
			"entry": row_entry,
		})
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ea: Dictionary = (a as Dictionary).get("entry", {}) as Dictionary
		var eb: Dictionary = (b as Dictionary).get("entry", {}) as Dictionary
		if int(ea.get("to_team", ea.get("team_id", 0))) != int(eb.get("to_team", eb.get("team_id", 0))):
			return int(ea.get("to_team", ea.get("team_id", 0))) < int(eb.get("to_team", eb.get("team_id", 0)))
		if int(ea.get("from_team", 0)) != int(eb.get("from_team", 0)):
			return int(ea.get("from_team", 0)) < int(eb.get("from_team", 0))
		var ra: PSPlayerSeasonRecord = (a as Dictionary).get("record", null) as PSPlayerSeasonRecord
		var rb: PSPlayerSeasonRecord = (b as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if ra == null or rb == null:
			return false
		return PlayerValueEvaluator.overall_score(ra) > PlayerValueEvaluator.overall_score(rb)
	)
	return rows


func _people_pitcher_fielder_counts(people: Array) -> Dictionary:
	var counts: Dictionary = {PLAYER_TAB_PITCHER: 0, PLAYER_TAB_FIELDER: 0}
	for entry_row in people:
		var entry: Dictionary = entry_row as Dictionary
		var key: String = PLAYER_TAB_PITCHER if _entry_is_pitcher(entry) else PLAYER_TAB_FIELDER
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


func _entry_is_pitcher(entry: Dictionary) -> bool:
	var position: int = int(entry.get("position", 0))
	if position == 1:
		return true
	var player: PSPlayer = GameDb.get_player(int(entry.get("player_id", 0)))
	return player != null and player.is_pitcher()


func _record_for_people_entry(entry: Dictionary) -> PSPlayerSeasonRecord:
	var pid: int = int(entry.get("player_id", 0))
	if pid <= 0:
		return null
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, season.year, season.season_number)
		if record != null:
			return record
	var records: Array = RecordStore.get_player_records(pid)
	if not records.is_empty():
		return records[records.size() - 1] as PSPlayerSeasonRecord
	var player: PSPlayer = GameDb.get_player(pid)
	if player == null:
		return null
	return PSPlayerSeasonRecord.from_player(
		player,
		season.year if season != null else 0,
		season.season_number if season != null else 0
	)


func _record_for_market_candidate(candidate: Dictionary) -> PSPlayerSeasonRecord:
	var pid: int = int(candidate.get("player_id", 0))
	if pid <= 0:
		return null
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, season.year, season.season_number)
		if record != null:
			return record
	var records: Array = RecordStore.get_player_records(pid)
	if not records.is_empty():
		return records[records.size() - 1] as PSPlayerSeasonRecord
	var player: PSPlayer = GameDb.get_player(pid)
	if player == null:
		return null
	return PSPlayerSeasonRecord.from_player(
		player,
		season.year if season != null else int(candidate.get("year", 0)),
		season.season_number if season != null else int(candidate.get("season_number", 0))
	)


func _current_record_for_player(player: PSPlayer) -> PSPlayerSeasonRecord:
	if player == null:
		return null
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			return record
	return PSPlayerSeasonRecord.from_player(
		player,
		season.year if season != null else 0,
		season.season_number if season != null else 0
	)


func _rows_include_multiple_teams(rows: Array) -> bool:
	var first_team: int = -999
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var entry: Dictionary = row.get("entry", {}) as Dictionary
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		var team_id: int = int(entry.get("team_id", record.team_id if record != null else 0))
		if first_team == -999:
			first_team = team_id
		elif team_id != first_team:
			return true
	return first_team != AppState.selected_team_id


func _release_state(player_id: int) -> String:
	if selected_release_ids.has(player_id):
		return "release"
	if selected_demote_ids.has(player_id):
		return "demote"
	return ""


# 支配下=塗り / 育成=アウトライン (枠のみ) で描き分ける。バッジ列を持つ全テーブルで共通。
func _role_badge(rect: Rect2, record: PSPlayerSeasonRecord) -> void:
	var role: String = _resolved_pitcher_role(record.role, {"starts": record.pitcher_stats.starts, "relief_appearances": record.pitcher_stats.relief_appearances})
	_chip(rect, _role_label(role), _role_color(role), not record.development_player)


func _position_badge(rect: Rect2, pos: int, development: bool = false) -> void:
	_chip(rect, _position_char(pos), _pos_color(pos), not development)


func _role_color(role: String) -> Color:
	match role:
		"starter":
			return PINK
		"closer":
			return CLOSER_RED
		_:
			return RED


func _text_cell(text: String, right_x: float, y: float, size: int, color: Color, box: float = 44.0) -> void:
	_text_right(text, right_x, y, size, color, box)


func _salary_delta_text(delta: int) -> String:
	if delta > 0:
		return "+%d" % delta
	return str(delta)


func _salary_delta_color(delta: int) -> Color:
	if delta > 0:
		return GREEN
	if delta < 0:
		return RED
	return FAINT


func _draw_velocity_value(value: int, right_x: float, y: float, box: float = 56.0) -> void:
	_text_cell("%dkm/h" % value, right_x, y, 12, TEXT, box)


func _draw_rating_value(value: int, right_x: float, y: float) -> void:
	_text_cell(str(value), right_x, y, 13, _grade_color(value))


func _grade_color(value: int) -> Color:
	return _table_rating_color(value)


func _record_injury_days(record: PSPlayerSeasonRecord, player: PSPlayer, _entry: Dictionary) -> int:
	if record != null and record.season_injury_days > 0:
		return record.season_injury_days
	return player.injury_days if player != null else 0


func _ip_str(ps: PSPitcherStats) -> String:
	if ps == null or ps.outs_pitched <= 0:
		return "0"
	return "%d.%d" % [ps.outs_pitched / 3, ps.outs_pitched % 3]


func _era_str_from_stats(ps: PSPitcherStats) -> String:
	return "-.--" if ps == null or ps.outs_pitched <= 0 else "%0.2f" % ps.era()


func _whip_str(ps: PSPitcherStats) -> String:
	return "-.--" if ps == null or ps.outs_pitched <= 0 else "%0.2f" % ps.whip()


func _k9_str(ps: PSPitcherStats) -> String:
	return "-.-" if ps == null or ps.outs_pitched <= 0 else "%0.1f" % ps.strikeouts_per_nine()


func _war_text(record: PSPlayerSeasonRecord, career_stats: bool) -> String:
	return "%0.1f" % _war_value(record, career_stats)


func _war_value(record: PSPlayerSeasonRecord, career_stats: bool) -> float:
	if record == null:
		return 0.0
	if career_stats:
		return _career_war_value(record.player_id)
	return float(_season_war_dict(record).get("war", 0.0))


func _war_value_color(war: float) -> Color:
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	return TEXT


func _fip_text(record: PSPlayerSeasonRecord, career_stats: bool) -> String:
	if record == null:
		return "-.--"
	if career_stats:
		var career: Dictionary = _career_pitcher_fip(record.player_id)
		return "%0.2f" % float(career.get("fip", 0.0)) if bool(career.get("has_fip", false)) else "-.--"
	var fip: Variant = _season_war_dict(record).get("fip", null)
	return "%0.2f" % float(fip) if fip != null and record.pitcher_stats.outs_pitched > 0 else "-.--"


func _season_war_dict(record: PSPlayerSeasonRecord) -> Dictionary:
	if record == null:
		return {}
	if release_war_by_id.is_empty():
		release_war_by_id = _build_release_war_map()
	var entry: Variant = release_war_by_id.get(record.player_id, {})
	if entry is Dictionary:
		return entry as Dictionary
	if entry is float or entry is int:
		return {"war": float(entry)}
	return {}


func _career_war_value(player_id: int) -> float:
	var total: float = 0.0
	for record_value in RecordStore.get_player_records(player_id):
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var ctx: Dictionary = PSWarCalculator.build_league_context(record.year, record.season_number)
		total += float(PSWarCalculator.season_war(record, ctx).get("war", 0.0))
	return total


func _career_pitcher_fip(player_id: int) -> Dictionary:
	var weighted: float = 0.0
	var weight: float = 0.0
	for record_value in RecordStore.get_player_records(player_id):
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.pitcher_stats == null or record.pitcher_stats.outs_pitched <= 0:
			continue
		var ctx: Dictionary = PSWarCalculator.build_league_context(record.year, record.season_number)
		var war: Dictionary = PSWarCalculator.season_war(record, ctx)
		if not war.has("fip"):
			continue
		var ip: float = record.pitcher_stats.innings_pitched()
		weighted += float(war["fip"]) * ip
		weight += ip
	return {"has_fip": weight > 0.0, "fip": weighted / weight if weight > 0.0 else 0.0}


func _career_advanced_stats(player_id: int) -> PSAdvancedStats:
	var total: PSAdvancedStats = PSAdvancedStats.new()
	for record_value in RecordStore.get_player_records(player_id):
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.advanced_stats != null:
			total.add_from(record.advanced_stats)
	return total


func _oaa_str(ad: PSAdvancedStats) -> String:
	if ad == null:
		return "-"
	var total: float = float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))
	return "%+0.1f" % total


func _oaa_color(ad: PSAdvancedStats) -> Color:
	if ad == null:
		return MUTED
	var total: float = float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))
	if total > 0.5:
		return GREEN
	if total < -0.5:
		return RED
	return MUTED


func _league_team_ids(league: String) -> Array:
	var ids: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.league == league:
			ids.append(team.id)
	ids.sort()
	return ids


# リーグ内球団を short_name 昇順 (アルファベット順) で列挙する。指名結果画面のグリッド列用。
func _league_team_ids_alpha(league: String) -> Array:
	var teams: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.league == league:
			teams.append(team)
	teams.sort_custom(func(a: Variant, b: Variant) -> bool:
		return (a as PSTeam).short_name < (b as PSTeam).short_name
	)
	var ids: Array = []
	for team_value in teams:
		ids.append((team_value as PSTeam).id)
	return ids


# リーグ内球団を「指名順」(AppState.draft_state.teams_order_reverse=今年度の下位球団が先頭) で
# 列挙する。draft_state が空、または teams_order_reverse が空の場合は team_id 昇順にフォールバック。
func _league_team_ids_draft_order(league: String) -> Array:
	var order: Array = AppState.draft_state.get("teams_order_reverse", []) as Array
	if order.is_empty():
		return _league_team_ids(league)
	var ids: Array = []
	for team_id_value in order:
		var team_id: int = int(team_id_value)
		var team: PSTeam = GameDb.get_team(team_id)
		if team != null and team.league == league:
			ids.append(team_id)
	return ids


# ============================================================ 共通ヘルパ

func _role_label(role: String) -> String:
	match role:
		"starter":
			return "先発"
		"reliever":
			return "中継"
		"closer":
			return "抑え"
		_:
			return role


func _league_label(league: String) -> String:
	if league == "league1":
		return "第1"
	if league == "league2":
		return "第2"
	return league


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _position_name(pos: int) -> String:
	return str(PSPlayer.POSITION_NAMES.get(pos, "?"))


func _position_char(pos: int) -> String:
	return str(POSITION_CHARS.get(pos, "?"))


func _dict_role_or_position(data: Dictionary) -> String:
	return _role_or_position_name(int(data.get("position", 0)), str(data.get("role", "")), data)


func _player_role_or_position(player: PSPlayer) -> String:
	if player != null and player.is_pitcher():
		return _role_label(_resolved_pitcher_role(player.role, {}))
	return _position_name(player.position if player != null else 0)


func _role_or_position_name(position: int, role: String, data: Dictionary = {}) -> String:
	if position == 1:
		return _role_label(_resolved_pitcher_role(role, data))
	return _position_name(position)


func _resolved_pitcher_role(role: String, data: Dictionary) -> String:
	if role == "starter" or role == "reliever" or role == "closer":
		return role
	if int(data.get("starts", 0)) > int(data.get("relief_appearances", 0)):
		return "starter"
	return "reliever"


func _role_char(role: String) -> String:
	match role:
		"starter":
			return "先"
		"reliever":
			return "継"
		"closer":
			return "抑"
		_:
			return "継"


func _active_foreign_count(team_id: int) -> int:
	var count: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.team_id == team_id and player.foreign_player and not player.is_retired():
			count += 1
	return count




# ============================================================ ボタンハンドラ (進行)

func _on_next_pressed() -> void:
	var result: Dictionary = AppState.advance_offseason()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "")), RED)
		return
	_refresh()


func _on_finalize_pressed() -> void:
	if not AppState.finalize_offseason():
		_set_status("翌年開始に失敗しました", RED)


func _on_save_pressed() -> void:
	var ok: bool = SaveService.save_state(AppState)
	_set_status("保存しました" if ok else "保存に失敗しました", MUTED if ok else RED)
