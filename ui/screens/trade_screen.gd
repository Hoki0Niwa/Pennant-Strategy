extends "res://ui/components/dashboard_screen.gd"

# トレード画面 (シーズン中トレード)。
# - 上部帯: 交換期限の残日数 / 自軍の今季成立数 / 支配下枠 / 予算残。
# - 中段3カラム: 左=自軍ロスター(ポジション絞り込み+行クリックで「出す」選択)、
#   中央=トレードブロック(出す/貰うスロット+戦力価値差・年俸差+成立見込み+提案/クリア)、
#   右=相手ロスター(球団はプルダウンで切替、行クリックで「貰う」選択)。
# - 下段: 左=相手球団からの受信提案(カード+受諾/拒否)、右=今季の成立トレード。
# 選手名の右クリックで選手詳細へ遷移。業務ルール (各球団最大 MAX_PLAYERS_PER_SIDE 人・
# is_tradeable 判定・年間成立上限・予算/支配下枠ゲート) は trade_service.gd 側を変更せずそのまま使う。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

# --- レイアウト基準 (base 1920x1080 座標) ---
const TOP_STRIP: Rect2 = Rect2(262, 100, 1638, 76)
const FILTER_Y: float = 190.0
const LEFT_RECT: Rect2 = Rect2(262, 224, 610, 500)
const CENTER_RECT: Rect2 = Rect2(906, 224, 350, 500)
const RIGHT_RECT: Rect2 = Rect2(1290, 224, 610, 500)
const OFFERS_RECT: Rect2 = Rect2(262, 740, 806, 308)
const LOG_RECT: Rect2 = Rect2(1094, 740, 806, 308)

const SLOT_H: float = 34.0
const SLOT_GAP: float = 6.0
const HEADER_GAP: float = 10.0 # 見出しラベルからその直下の要素までの間隔 (同じ項目として近く保つ)
const SECTION_GAP: float = 28.0 # トレードブロック内の異なるセクション間の縦間隔 (見出し直下の要素より明確に広くする)
const OFFER_CARD_H: float = 130.0
const OFFER_CARD_GAP: float = 10.0

const POS_LABELS: Dictionary = {1: "投", 2: "捕", 3: "一", 4: "二", 5: "三", 6: "遊", 7: "左", 8: "中", 9: "右"}

# ポジション絞り込み (自軍ロスターのみ。相手球団はプルダウン切替のため対象外)。
const FILTER_DEFS: Array = [
	{"pos": 0, "label": "全"},
	{"pos": 1, "label": "投"},
	{"pos": 2, "label": "捕"},
	{"pos": 3, "label": "内野"},
	{"pos": 4, "label": "外野"},
]

const PLAYER_COLUMNS: Array = [
	{"title": "区分", "key": "role",   "w": 54,  "align": "c", "fmt": "pos_badge"},
	{"title": "選手", "key": "name",   "w": 178, "align": "l", "fmt": "str", "strong": true},
	{"title": "年齢", "key": "age",    "w": 48,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "評価", "key": "value",  "w": 56,  "align": "r", "fmt": "int"},
	{"title": "WAR",  "key": "war",    "w": 56,  "align": "r", "fmt": "str"},
	{"title": "年俸", "key": "salary", "w": 128, "align": "r", "fmt": "str", "sep_before": true},
]

const LOG_COLUMNS: Array = [
	{"title": "日",     "key": "day",     "w": 48,  "align": "r", "fmt": "int"},
	{"title": "球団A",  "key": "team_a",  "w": 130, "align": "l", "fmt": "str", "strong": true},
	{"title": "放出",   "key": "a_gives", "w": 220, "align": "l", "fmt": "str"},
	{"title": "球団B",  "key": "team_b",  "w": 130, "align": "l", "fmt": "str", "sep_before": true, "strong": true},
	{"title": "放出",   "key": "b_gives", "w": 220, "align": "l", "fmt": "str"},
	{"title": "種別",   "key": "source",  "w": 80,  "align": "l", "fmt": "str", "sep_before": true},
]

var _row_hits: Array = []      # [{rect, kind, meta}]
var _scroll_zones: Array = []
var _scroll: Dictionary = {}

var _view_team_id: int = 0     # 相手球団
var _give_ids: Array = []      # 自軍から出す選手 id (最大 MAX_PLAYERS_PER_SIDE)
var _receive_ids: Array = []   # 相手から受け取る選手 id
var _message: String = ""
var _message_color: Color = MUTED

var _filter_pos: int = 0
var _filter_buttons: Dictionary = {}
var _team_menu_button: Button = null

# 集計キャッシュ (_refresh_all で1回構築、_draw は描画専念)。
var _war_ctx: Dictionary = {}
var _mine_all_rows: Array = []
var _theirs_rows: Array = []
# evaluate_user_proposal の結果キャッシュ。選択が変わるたび _refresh_proposal_eval で更新する
# (毎フレーム呼ぶと重いので _draw では参照するだけ)。
var _eval: Dictionary = {}


func _ready() -> void:
	_init_chrome()
	var opp_ids: Array = _opponent_team_ids()
	_view_team_id = int(opp_ids[0]) if not opp_ids.is_empty() else 0
	_refresh_all()
	_build_buttons()
	queue_redraw()


# リサイズ時のボタン再配置に加え、絞り込みチップの状態色を再適用する。
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_buttons()
		_refresh_filter_buttons()
		queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_row_hits = []
	_scroll_zones = []

	var season: PSSeason = AppState.current_season
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	if season == null or team == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)
		return

	_draw_shell("トレード", team, season)

	var window_open: bool = TradeService.is_trade_window_open(season)
	# 操作ヒントは絞り込みチップ行の右に置く (ヘッダ直下だと帯・ヘッダ境界と重なって欠ける)。
	_text("行クリック=選択（各球団最大%d人） / 選手名を右クリックで選手詳細" % TradeService.MAX_PLAYERS_PER_SIDE,
		Vector2(INNER_L + 290.0, FILTER_Y + 19.0), 12, FAINT)
	if AppState.auto_trade_for_user_team:
		_chip(Rect2(INNER_R - 200.0, FILTER_Y + 1.0, 200.0, 24.0), "自動トレード: AI委任中", BLUE)

	_draw_stat_strip(TOP_STRIP, season, team, window_open)

	_draw_player_table(LEFT_RECT, "自軍: %s" % team.name, _mine_rows_filtered(), _give_ids, "mine")
	_draw_center_block(CENTER_RECT, season, window_open)
	var opponent: PSTeam = GameDb.get_team(_view_team_id)
	_draw_player_table(RIGHT_RECT, "相手: %s ▾" % (opponent.name if opponent != null else "-"), _theirs_rows, _receive_ids, "theirs")

	_draw_offers_panel(OFFERS_RECT, season)
	_draw_log_table(LOG_RECT, season)

	if not _message.is_empty():
		_text(_message, Vector2(INNER_L, 1064.0), 13, _message_color, 1200.0)


func _draw_stat_strip(rect: Rect2, season: PSSeason, team: PSTeam, window_open: bool) -> void:
	var days_left: int = _days_left(season)
	var trades_count: int = TradeService.trades_count_for_team(season, team.id)
	var controlled: int = TeamFinance.controlled_count(GameDb.players, team.id)
	var payroll: int = TeamFinance.team_payroll(GameDb.players, team.id)
	var room: int = TeamFinance.budget_room(team.funds, payroll)
	var cells: Array = [
		{"label": "交換期限", "value": ("残り%d日" % days_left) if window_open else "期限終了",
			"color": TEXT if window_open else AMBER, "note": "7/31まで" if window_open else ""},
		{"label": "自軍の今季成立数", "value": "%d/%d" % [trades_count, TradeService.MAX_TRADES_PER_TEAM],
			"color": RED if trades_count >= TradeService.MAX_TRADES_PER_TEAM else TEXT},
		{"label": "支配下枠", "value": "%d/%d" % [controlled, TeamFinance.CONTROLLED_LIMIT],
			"color": RED if controlled >= TeamFinance.CONTROLLED_LIMIT else (AMBER if controlled >= TeamFinance.CONTROLLED_LIMIT - 2 else TEXT)},
		{"label": "予算残", "value": "%s%s" % ["-" if room < 0 else "", _format_money_compact(absi(room))],
			"color": GREEN if room >= 0 else RED},
	]
	_stat_strip(rect, cells)


func _days_left(season: PSSeason) -> int:
	if str(season.calendar_start_date).is_empty():
		return max(0, TradeService.TRADE_WINDOW_FALLBACK_LAST_DAY - season.current_day)
	var current: String = SeasonCalendar.current_date(season)
	var deadline: String = "%04d-%02d-%02d" % [season.year, TradeService.TRADE_DEADLINE_MONTH, TradeService.TRADE_DEADLINE_DAY]
	return max(0, SeasonCalendar.days_between(current, deadline))


# --- 自軍/相手ロスター テーブル ---

func _draw_player_table(rect: Rect2, title: String, rows: Array, selected_ids: Array, sel_kind: String) -> void:
	var opts: Dictionary = {
		"title": title, "header_top": 58.0, "row_h": 30.0,
		"cell_size": 12, "empty_text": "選手がいません",
		"scroll_key": sel_kind, "scroll": _scroll, "scroll_zones": _scroll_zones,
		"sel_kind": sel_kind, "hits": _row_hits,
	}
	_draw_data_table(rect, PLAYER_COLUMNS, rows, opts)
	# 複数選択のハイライトは自前で重ねる (基底 selected_id は単一)。
	for hit_value in _row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if str(hit.get("kind", "")) != sel_kind:
			continue
		if selected_ids.has(int(hit.get("meta", 0))):
			_round(hit["rect"] as Rect2, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), Color(BLUE.r, BLUE.g, BLUE.b, 0.75), 6, 2)


# --- トレードブロック (中央) ---

func _draw_center_block(rect: Rect2, season: PSSeason, window_open: bool) -> void:
	_panel(rect, "トレードブロック")
	var px: float = rect.position.x + 18.0
	var card_w: float = rect.size.x - 36.0
	var y: float = rect.position.y + 50.0

	_text("出す（自軍 → 相手）", Vector2(px, y), 12, MUTED, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	y += HEADER_GAP
	for i in range(TradeService.MAX_PLAYERS_PER_SIDE):
		_draw_trade_slot(Rect2(px, y, card_w, SLOT_H), _give_ids[i] if i < _give_ids.size() else 0, "give_slot", season)
		y += SLOT_H + SLOT_GAP

	y += SECTION_GAP
	_text("貰う（相手 → 自軍）", Vector2(px, y), 12, MUTED, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	y += HEADER_GAP
	for i in range(TradeService.MAX_PLAYERS_PER_SIDE):
		_draw_trade_slot(Rect2(px, y, card_w, SLOT_H), _receive_ids[i] if i < _receive_ids.size() else 0, "receive_slot", season)
		y += SLOT_H + SLOT_GAP

	y += SECTION_GAP
	y = _draw_trade_balance(rect, y, card_w)
	y += 16.0
	_draw_trade_verdict(rect, y, window_open)


func _draw_trade_slot(rect: Rect2, player_id: int, kind: String, season: PSSeason) -> void:
	var mid_y: float = rect.position.y + rect.size.y * 0.5 + 4.0
	if player_id <= 0:
		_round(rect, Color.TRANSPARENT, BORDER_SOFT, 6, 1)
		_text("（空き）", Vector2(rect.position.x + 12.0, mid_y), 12, FAINT)
		return
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null:
		return
	_round(rect, PANEL_2, Color.TRANSPARENT, 6, 0)
	var role: Dictionary = _role_chip(player)
	_chip(Rect2(rect.position.x + 8.0, rect.position.y + rect.size.y * 0.5 - 9.0, 40.0, 18.0), str(role["text"]), role["color"] as Color)
	# 選手一覧パネル (自軍/相手ロースター) と同じ並び (年齢・評価・年俸を名前と横並び) に揃える。
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
	var eval: int = PlayerValueEvaluator.overall_score(record) if record != null else int(OffseasonService.player_value_score(player))
	_text_right(_format_money_compact(player.salary), rect.end.x - 8.0, mid_y, 12, MUTED, 76.0)
	_text_right(str(eval), rect.end.x - 8.0 - 76.0 - 6.0, mid_y, 12, _table_rating_color(eval), 34.0)
	_text_right("%d歳" % player.age, rect.end.x - 8.0 - 76.0 - 6.0 - 34.0 - 6.0, mid_y, 12, MUTED, 40.0)
	_text(player.name, Vector2(rect.position.x + 56.0, mid_y), 13, TEXT, rect.size.x - 56.0 - 76.0 - 34.0 - 40.0 - 30.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_row_hits.append({"rect": rect, "kind": kind, "meta": player.id})


# 左右バー + 戦力価値差 (trade_value 合計差, 自軍有利=GREEN/不利=RED) + 年俸差。戻り値は次の描画 y。
func _draw_trade_balance(rect: Rect2, y: float, w: float) -> float:
	var give_value: float = _sum_trade_value(_give_ids)
	var receive_value: float = _sum_trade_value(_receive_ids)
	var max_v: float = max(1.0, max(give_value, receive_value))
	var bar_w: float = (w - 8.0) * 0.5
	var give_w: float = bar_w * clampf(give_value / max_v, 0.0, 1.0)
	var recv_w: float = bar_w * clampf(receive_value / max_v, 0.0, 1.0)
	_round(Rect2(rect.position.x + 18.0, y, bar_w, 7.0), PANEL_3, Color.TRANSPARENT, 4, 0)
	_round(Rect2(rect.position.x + 18.0 + bar_w - give_w, y, give_w, 7.0), RED, Color.TRANSPARENT, 4, 0)
	_round(Rect2(rect.position.x + 18.0 + bar_w + 8.0, y, bar_w, 7.0), PANEL_3, Color.TRANSPARENT, 4, 0)
	_round(Rect2(rect.position.x + 18.0 + bar_w + 8.0, y, recv_w, 7.0), GREEN, Color.TRANSPARENT, 4, 0)
	y += 30.0
	var diff: float = receive_value - give_value
	var diff_color: Color = GREEN if diff > 0.05 else (RED if diff < -0.05 else MUTED)
	_text("戦力価値差", Vector2(rect.position.x + 18.0, y), 11, MUTED)
	_text_right(("%+.1f" % diff), rect.end.x - 18.0, y, 15, diff_color, 100.0, true)
	y += 22.0
	var salary_diff: int = _sum_salary(_receive_ids) - _sum_salary(_give_ids)
	_text("年俸差", Vector2(rect.position.x + 18.0, y), 11, MUTED)
	_text_right("%s%s" % ["+" if salary_diff > 0 else ("-" if salary_diff < 0 else ""), _format_money_compact(absi(salary_diff))],
		rect.end.x - 18.0, y, 13, TEXT, 120.0)
	return y + SECTION_GAP


func _draw_trade_verdict(rect: Rect2, y: float, window_open: bool) -> void:
	var text: String
	var color: Color
	if _give_ids.is_empty() or _receive_ids.is_empty():
		text = "出す/貰う選手を選んでください"
		color = MUTED
	elif not window_open:
		text = "交換期限を過ぎています"
		color = AMBER
	elif not bool(_eval.get("ok", false)):
		text = str(_eval.get("message", "この組み合わせは提案できません"))
		color = AMBER
	elif bool(_eval.get("accepted", false)):
		text = "受諾見込み"
		color = GREEN
	else:
		text = str(_eval.get("message", "交渉はまとまりません"))
		color = RED
	_text("成立見込み", Vector2(rect.position.x + 18.0, y), 11, MUTED)
	_text(text, Vector2(rect.position.x + 18.0, y + 22.0), 14, color, rect.size.x - 36.0, HORIZONTAL_ALIGNMENT_LEFT, true)


# --- 相手球団からの提案 (下段左) ---

func _draw_offers_panel(rect: Rect2, season: PSSeason) -> void:
	_panel(rect, "相手球団からの提案")
	var offers: Array = TradeService.pending_user_offers(season)
	if offers.is_empty():
		_text("現在、届いている提案はありません", Vector2(rect.position.x + 18.0, rect.position.y + 78.0), 13, MUTED)
		return
	for i in range(min(offers.size(), TradeService.MAX_PENDING_USER_OFFERS)):
		_draw_offer_card(_offer_card_rect(rect, i), offers[i] as Dictionary, season)


func _offer_card_rect(rect: Rect2, index: int) -> Rect2:
	var top: float = rect.position.y + 52.0 + float(index) * (OFFER_CARD_H + OFFER_CARD_GAP)
	return Rect2(rect.position.x + 16.0, top, rect.size.x - 32.0, OFFER_CARD_H)


func _draw_offer_card(rect: Rect2, offer: Dictionary, season: PSSeason) -> void:
	_round(rect, PANEL_2, Color.TRANSPARENT, 8, 0)
	var cpu_team: PSTeam = GameDb.get_team(int(offer.get("cpu_team_id", 0)))
	_text(cpu_team.name if cpu_team != null else "?", Vector2(rect.position.x + 16.0, rect.position.y + 24.0), 15, TEXT, rect.size.x - 220.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text_right("期限 day%d" % int(offer.get("expires_day", 0)), rect.end.x - 16.0, rect.position.y + 20.0, 11, FAINT, 140.0)
	_line(Vector2(rect.position.x + 16.0, rect.position.y + 32.0), Vector2(rect.end.x - 16.0, rect.position.y + 32.0), HAIRLINE, 1.0)
	_text("受取: " + _offer_players_text(offer.get("cpu_player_ids", []) as Array, season), Vector2(rect.position.x + 16.0, rect.position.y + 56.0), 13, GREEN, rect.size.x - 32.0)
	_text("放出: " + _offer_players_text(offer.get("user_player_ids", []) as Array, season), Vector2(rect.position.x + 16.0, rect.position.y + 80.0), 13, RED, rect.size.x - 32.0)


func _offer_players_text(ids: Array, season: PSSeason) -> String:
	var parts: Array = []
	for id_value in ids:
		var player: PSPlayer = GameDb.get_player(int(id_value))
		if player == null:
			parts.append("?")
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var eval: int = PlayerValueEvaluator.overall_score(record) if record != null else int(OffseasonService.player_value_score(player))
		parts.append("%s (評価%d, %s)" % [player.name, eval, _format_money_compact(player.salary)])
	return "、".join(PackedStringArray(parts))


# --- 今季の成立トレード (下段右) ---

func _draw_log_table(rect: Rect2, season: PSSeason) -> void:
	var rows: Array = []
	var executed: Array = TradeService.executed_trades(season).duplicate()
	executed.reverse()
	for entry_value in executed:
		var entry: Dictionary = entry_value as Dictionary
		var team_a: PSTeam = GameDb.get_team(int(entry.get("team_a", 0)))
		var team_b: PSTeam = GameDb.get_team(int(entry.get("team_b", 0)))
		rows.append({
			"day": int(entry.get("day", 0)),
			"team_a": team_a.name if team_a != null else "?",
			"a_gives": "、".join(PackedStringArray(entry.get("a_player_names", []) as Array)),
			"team_b": team_b.name if team_b != null else "?",
			"b_gives": "、".join(PackedStringArray(entry.get("b_player_names", []) as Array)),
			"source": _source_label(str(entry.get("source", ""))),
		})
	_draw_data_table(rect, LOG_COLUMNS, rows, {
		"title": "今季の成立トレード", "header_top": 58.0, "row_h": 28.0,
		"cell_size": 12, "empty_text": "今季の成立トレードはまだありません",
		"scroll_key": "log", "scroll": _scroll, "scroll_zones": _scroll_zones,
	})


func _source_label(source: String) -> String:
	match source:
		"cpu": return "球団間"
		"user_offer": return "受諾"
		"user_proposal": return "自軍提案"
		_: return source


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	if season == null or team == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# ポジション絞り込みチップ (自軍ロスターのみ)。
	_filter_buttons = {}
	var fx: float = INNER_L
	for def_value in FILTER_DEFS:
		var def: Dictionary = def_value as Dictionary
		var pos: int = int(def["pos"])
		var btn: Button = _add_button("filter_%d" % pos, str(def["label"]), Rect2(fx, FILTER_Y, 46.0, 26.0),
			func(p: int = pos) -> void: _set_filter(p),
			"chip_active" if pos == _filter_pos else "chip")
		_filter_buttons[pos] = btn
		fx += 52.0

	# 相手球団の切替 (テーブルタイトル自体がプルダウン)。
	var opponent: PSTeam = GameDb.get_team(_view_team_id)
	var theirs_title: String = "相手: %s ▾" % (opponent.name if opponent != null else "-")
	_team_menu_button = _add_button("team_menu", "", _theirs_title_hotspot(RIGHT_RECT, theirs_title), _on_team_menu_pressed, "nav")

	var propose_btn: Button = _add_button("propose", "この内容で提案する",
		Rect2(CENTER_RECT.position.x + 18.0, CENTER_RECT.end.y - 46.0, 176.0, 36.0), _submit_proposal, "primary")
	propose_btn.disabled = not _can_submit()
	_add_button("clear_sel", "クリア",
		Rect2(CENTER_RECT.position.x + 202.0, CENTER_RECT.end.y - 46.0, 112.0, 36.0), func() -> void: _clear_selection(), "chip")

	_build_offer_buttons(OFFERS_RECT, TradeService.pending_user_offers(season))

	_layout_buttons()


func _build_offer_buttons(rect: Rect2, offers: Array) -> void:
	for i in range(min(offers.size(), TradeService.MAX_PENDING_USER_OFFERS)):
		var offer: Dictionary = offers[i] as Dictionary
		var card: Rect2 = _offer_card_rect(rect, i)
		var offer_id: int = int(offer.get("id", 0))
		_add_button("offer_accept_%d" % offer_id, "受諾", Rect2(card.end.x - 176.0, card.end.y - 34.0, 76.0, 28.0),
			func() -> void: _accept_offer(offer_id), "primary")
		_add_button("offer_decline_%d" % offer_id, "拒否", Rect2(card.end.x - 92.0, card.end.y - 34.0, 76.0, 28.0),
			func() -> void: _decline_offer(offer_id), "chip")


# 「相手: 球団名 ▾」タイトルの見た目 (BLUEティック+テキスト) をおおむね覆う透明ボタン矩形。
func _theirs_title_hotspot(rect: Rect2, title: String) -> Rect2:
	var w: float = _measure(title, FS_SECTION) + 30.0
	return Rect2(rect.position.x + 14.0, rect.position.y + 16.0, w, 28.0)


func _on_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	var ids: Array = _opponent_team_ids()
	for i in range(ids.size()):
		var team: PSTeam = GameDb.get_team(int(ids[i]))
		if team == null:
			continue
		if i > 0:
			var prev: PSTeam = GameDb.get_team(int(ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(team.league_label())
		else:
			menu.add_separator(team.league_label())
		menu.add_item("%s (%s)" % [team.name, team.short_name], int(ids[i]))
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_team_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(RIGHT_RECT.position.x + 14.0, RIGHT_RECT.position.y + 44.0))
	if _team_menu_button != null:
		anchor = _team_menu_button.global_position + Vector2(0.0, _team_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_team_selected(team_id: int) -> void:
	if team_id == _view_team_id or team_id == AppState.selected_team_id:
		return
	_view_team_id = team_id
	_receive_ids = []
	var season: PSSeason = AppState.current_season
	if season != null:
		_load_theirs(season)
	_refresh_proposal_eval()
	_build_buttons()
	queue_redraw()


func _set_filter(pos: int) -> void:
	if pos == _filter_pos:
		return
	_filter_pos = pos
	_refresh_filter_buttons()
	queue_redraw()


func _refresh_filter_buttons() -> void:
	for key in _filter_buttons.keys():
		var btn: Button = _filter_buttons[key] as Button
		if btn != null:
			_apply_button_style(btn, "chip_active" if int(key) == _filter_pos else "chip")


# ============================================================ actions

func _submit_proposal() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or not _can_submit():
		return
	var result: Dictionary = TradeService.submit_user_proposal(
		season, GameDb.players, GameDb.teams, AppState.selected_team_id, _give_ids.duplicate(), _receive_ids.duplicate())
	if bool(result.get("accepted", false)):
		GameDb.rebuild_player_indices()
		_give_ids = []
		_receive_ids = []
		_eval = {}
		_refresh_all()
		_message_color = GREEN
		_message = "トレードが成立しました。"
	else:
		_message_color = AMBER
		_message = str(result.get("message", "交渉はまとまりませんでした。"))
	_build_buttons()
	queue_redraw()


func _accept_offer(offer_id: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var result: Dictionary = TradeService.accept_user_offer(season, GameDb.players, GameDb.teams, offer_id, AppState.selected_team_id)
	if bool(result.get("ok", false)):
		GameDb.rebuild_player_indices()
		_refresh_all()
		_message_color = GREEN
		_message = "提案を受諾し、トレードが成立しました。"
	else:
		_message_color = AMBER
		_message = str(result.get("message", "受諾できませんでした。"))
	_build_buttons()
	queue_redraw()


func _decline_offer(offer_id: int) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	TradeService.decline_user_offer(season, offer_id)
	_message_color = MUTED
	_message = "提案を拒否しました。"
	_build_buttons()
	queue_redraw()


func _clear_selection() -> void:
	_give_ids = []
	_receive_ids = []
	_message = ""
	_eval = {}
	_build_buttons()
	queue_redraw()


func _can_submit() -> bool:
	var season: PSSeason = AppState.current_season
	if season == null or not TradeService.is_trade_window_open(season):
		return false
	if _give_ids.is_empty() or _receive_ids.is_empty():
		return false
	return bool(_eval.get("ok", false)) and bool(_eval.get("accepted", false))


func _toggle_selection(ids: Array, player_id: int) -> void:
	if ids.has(player_id):
		ids.erase(player_id)
	else:
		var player: PSPlayer = GameDb.get_player(player_id)
		var lock_season: PSSeason = AppState.current_season
		var lock_year: int = lock_season.year if lock_season != null else 0
		if player == null or not TradeService.is_tradeable(player, lock_year):
			_message_color = AMBER
			_message = "%s はトレード対象にできません。" % (player.name if player != null else "その選手")
			_build_buttons()
			return
		if ids.size() >= TradeService.MAX_PLAYERS_PER_SIDE:
			_message_color = AMBER
			_message = "選択できるのは各球団%d人までです。" % TradeService.MAX_PLAYERS_PER_SIDE
			_build_buttons()
			return
		ids.append(player_id)
	_message = ""
	_refresh_proposal_eval()
	_build_buttons()


func _refresh_proposal_eval() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _give_ids.is_empty() or _receive_ids.is_empty():
		_eval = {}
		return
	_eval = TradeService.evaluate_user_proposal(season, GameDb.players, GameDb.teams, AppState.selected_team_id, _give_ids.duplicate(), _receive_ids.duplicate())


# ============================================================ aggregation

func _refresh_all() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	_war_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	_load_mine(season)
	_load_theirs(season)
	_refresh_proposal_eval()


func _load_mine(season: PSSeason) -> void:
	_mine_all_rows = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != AppState.selected_team_id or player.is_retired() or player.development_player:
			continue
		_mine_all_rows.append(_player_row(player, season))
	_mine_all_rows.sort_custom(_by_value_desc)


func _load_theirs(season: PSSeason) -> void:
	_theirs_rows = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != _view_team_id or player.is_retired() or player.development_player:
			continue
		_theirs_rows.append(_player_row(player, season))
	_theirs_rows.sort_custom(_by_value_desc)


func _by_value_desc(a: Variant, b: Variant) -> bool:
	return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))


func _player_row(player: PSPlayer, season: PSSeason) -> Dictionary:
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
	var tradeable: bool = TradeService.is_tradeable(player, season.year)
	var role: Dictionary = _role_chip(player)
	var eval: int = PlayerValueEvaluator.overall_score(record) if record != null else int(OffseasonService.player_value_score(player))
	var has_war: bool = false
	var war: float = 0.0
	if record != null:
		has_war = (record.is_pitcher() and record.pitcher_stats.outs_pitched > 0) \
			or (not record.is_pitcher() and record.batter_stats.plate_appearances > 0)
		if has_war:
			war = float(WarCalculator.season_war(record, _war_ctx).get("war", 0.0))
	var row: Dictionary = {
		"__meta": player.id,
		"role": role["text"], "role_color": role["color"], "role_dev": not tradeable,
		"name": player.name,
		"age": player.age,
		"value": eval,
		"war": ("%0.1f" % war) if has_war else "-",
		"salary": _format_money(player.salary),
		"is_pitcher": player.is_pitcher(),
		"position": player.position,
	}
	if tradeable:
		row["value_color"] = _table_rating_color(eval)
		if has_war:
			row["war_color"] = _war_color(war)
	else:
		row["__color"] = FAINT
	return row


func _role_chip(player: PSPlayer) -> Dictionary:
	if player.is_pitcher():
		if player.is_starter_pitcher():
			return {"text": "先発", "color": PINK}
		return {"text": "中継", "color": RED}
	return {"text": str(POS_LABELS.get(player.position, "?")), "color": _pos_color(player.position)}


func _war_color(war: float) -> Color:
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	if war <= 0.0:
		return FAINT
	return TEXT


func _mine_rows_filtered() -> Array:
	if _filter_pos == 0:
		return _mine_all_rows
	var out: Array = []
	for row_value in _mine_all_rows:
		if _filter_pass(row_value as Dictionary):
			out.append(row_value)
	return out


func _filter_pass(row: Dictionary) -> bool:
	var is_pitcher: bool = bool(row.get("is_pitcher", false))
	var position: int = int(row.get("position", 0))
	match _filter_pos:
		1: return is_pitcher
		2: return not is_pitcher and position == 2
		3: return not is_pitcher and position >= 3 and position <= 6
		4: return not is_pitcher and position >= 7 and position <= 9
	return true


func _opponent_team_ids() -> Array:
	var ids: Array = []
	for league_key in ["league1", "league2"]:
		var league_ids: Array = []
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team.league == league_key and team.id != AppState.selected_team_id:
				league_ids.append(team.id)
		league_ids.sort()
		ids.append_array(league_ids)
	return ids


func _sum_trade_value(ids: Array) -> float:
	var total: float = 0.0
	for id_value in ids:
		var player: PSPlayer = GameDb.get_player(int(id_value))
		if player != null:
			total += TradeService.trade_value(player)
	return total


func _sum_salary(ids: Array) -> int:
	var total: int = 0
	for id_value in ids:
		var player: PSPlayer = GameDb.get_player(int(id_value))
		if player != null:
			total += player.salary
	return total


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
			if hit.is_empty():
				return
			match str(hit.get("kind", "")):
				"mine", "give_slot":
					_toggle_selection(_give_ids, int(hit.get("meta", 0)))
				"theirs", "receive_slot":
					_toggle_selection(_receive_ids, int(hit.get("meta", 0)))
			queue_redraw()
			accept_event()
		MOUSE_BUTTON_RIGHT:
			var hit2: Dictionary = _row_at(base_pos)
			if not hit2.is_empty() and str(hit2.get("kind", "")) in ["mine", "theirs"]:
				AppState.show_player_detail(int(hit2.get("meta", 0)))
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
