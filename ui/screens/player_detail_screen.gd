extends "res://ui/components/dashboard_screen.gd"

# 選手詳細画面。選択中 player_id の現所属・契約・能力・年度別成績を1画面に集約する。
# 表示要素:
#   - 識別バー: 選手名 + ▼(選手プルダウン) + 守備位置/役割 chip + 背番号、その横にプロ年数/年齢/投打/総合評価を
#     インライン表示 (カードにするほどではない情報)。右端に閲覧球団プルダウン。
#   - ポジション絞り込み chip 行 (全 / 先発 / 中継 / 捕 / 一 / 二 / 三 / 遊 / 左 / 中 / 右)。
#     チーム選択後の選手一覧は長すぎるため、選手プルダウンはこの絞り込みで短縮した候補を出す。投手は先発/中継で分割。
#   - 能力パネル: 基本能力(野手6/投手4) + 守備適性(野手) or 変化球(投手) をすべてバーで表示。
#   - プロフィール・契約パネル: 登録区分 / 契約(FA) / 年俸 / 出身 / 疲労・怪我 / 評価内訳。
#   - 下部タブ表: 成績 / 指標 / 高度指標 / 能力の変遷 を切り替え (初期は成績)。隠しパラメータ(z/raw)以外の
#     ボックススコア項目をすべて網羅。各行=1シーズン、成績・指標は通算行つき。
# 高度指標の WAR リーグ文脈は重いため、該当タブを開いたとき1度だけ計算してキャッシュする。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

# ポジション絞り込み。id: all / starter / reliever / pos2..pos9。
const POS_FILTERS: Array = [
	{"id": "all", "label": "全"},
	{"id": "starter", "label": "先発"},
	{"id": "reliever", "label": "中継"},
	{"id": "pos2", "label": "捕"}, {"id": "pos3", "label": "一"}, {"id": "pos4", "label": "二"},
	{"id": "pos5", "label": "三"}, {"id": "pos6", "label": "遊"}, {"id": "pos7", "label": "左"},
	{"id": "pos8", "label": "中"}, {"id": "pos9", "label": "右"},
]

const POS_SHORT: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "DH",
}

const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

# --- レイアウト基準 (base 座標) ---
const ID_Y: float = 122.0                  # 識別バーの縦中心
const FILTER_Y: float = 166.0              # ポジション絞り込み chip 行の上端
const TEAM_SEL_X: float = 1594.0           # 閲覧球団プルダウンの左端

const ABILITY_RECT: Rect2 = Rect2(262, 206, 380, 338)
const APT_RECT: Rect2 = Rect2(658, 206, 380, 338)
const PROFILE_RECT: Rect2 = Rect2(1054, 206, 480, 338)
const EVAL_RECT: Rect2 = Rect2(1550, 206, 350, 338)
const TABLE_RECT: Rect2 = Rect2(262, 562, 1638, 494)

const TABS: Array = [
	{"id": "season", "label": "今季"},
	{"id": "stats", "label": "過去成績"},
	{"id": "advanced", "label": "過去指標"},
	{"id": "abilities", "label": "能力の変遷"},
]

# 能力バーは上から一定間隔で詰める (守備適性は最大7つ想定)。
const ABILITY_BAR_H: float = 36.0
const ABILITY_BAR_ROWS: int = 7

var _team_id: int = 0
var _team_ids: Array = []
var _filter_id: String = "all"
var _player_id: int = 0
var _active_tab: String = "season"

# 選択状態のキャッシュ
var _record: PSPlayerSeasonRecord = null
var _records: Array = []                   # 当該選手の全シーズン記録 (古い順)
var _ratings: Dictionary = {}              # 現在の表示レーティング (ratings_for_record)
var _candidates: Array = []                # 絞り込み後の選手候補 (records, overall 降順)
var _basic_rows: Array = []                # 過去成績タブ
var _ability_rows: Array = []
var _advanced_rows: Array = []             # 過去指標タブ (遅延計算)
var _advanced_built: bool = false
var _season_groups: Array = []             # 今季タブ (カテゴリ別カード, 遅延計算)
var _season_built: bool = false
var _arsenal_types: Array = []             # 投手: 能力変遷表の変化球カラム順 (全シーズンの和集合)
var _war_ctx_cache: Dictionary = {}        # "year-sn" -> league_ctx

var _team_menu_button: Button = null
var _player_menu_button: Button = null


func _ready() -> void:
	_init_chrome()
	_build_team_order()
	_resolve_initial()
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var your_team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if season == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)
		return
	if your_team == null:
		your_team = GameDb.get_team(_team_id)
	_draw_shell("選手詳細", your_team, season)

	_draw_filters()
	_draw_team_selector()

	if _record == null:
		_draw_identity_empty()
		return

	_draw_identity()
	_draw_ability(ABILITY_RECT)
	_draw_apt(APT_RECT)
	_draw_profile(PROFILE_RECT)
	_draw_eval(EVAL_RECT)
	if _active_tab == "season":
		_draw_season(TABLE_RECT)
	else:
		_draw_table(TABLE_RECT)


# --- 識別バー (名前 + 絞り込み chip + インライン メタ) ---

func _draw_identity() -> void:
	var x: float = INNER_L
	_text(_record.name, Vector2(x, ID_Y + 10), 28, TEXT)
	x += _measure(_record.name, 28) + 12.0
	_text("▼", Vector2(x, ID_Y + 6), 14, MUTED)
	x += 28.0
	_chip(Rect2(x, ID_Y - 13, 44, 26), _role_or_position_short(_record), _identity_color(_record))
	x += 54.0
	if _record.jersey_number > 0:
		var jersey: String = "#%d" % _record.jersey_number
		_text(jersey, Vector2(x, ID_Y + 8), 18, MUTED)
		x += _measure(jersey, 18) + 14.0
	if _record.foreign_player:
		_chip(Rect2(x, ID_Y - 11, 48, 22), "外国人", VIOLET)
		x += 58.0

	# 区切り + インライン メタ (プロ年数 / 年齢 / 投打)。
	_line(Vector2(x, ID_Y - 13), Vector2(x, ID_Y + 13), BORDER, 1.0)
	x += 18.0
	var meta: String = "%d年目    %d歳    %s投%s打" % [
		_record.years, _record.age, _hand_name(_record.throwing_hand), _hand_name(_record.batting_side),
	]
	_text(meta, Vector2(x, ID_Y + 7), 17, MUTED)


func _draw_identity_empty() -> void:
	_text("該当する選手がいません", Vector2(INNER_L, ID_Y + 9), 22, MUTED)
	_text("ポジション絞り込みや閲覧球団を変更してください", Vector2(INNER_L, 320), 16, FAINT)


# 選手名 + ▼ を覆う透明ボタン (プルダウンのヒット領域)。
func _player_hotspot_rect() -> Rect2:
	var name_w: float = _measure(_record.name, 28) if _record != null else 0.0
	return Rect2(INNER_L - 6.0, ID_Y - 22.0, name_w + 12.0 + 30.0, 46.0)


# --- 閲覧球団プルダウン (右端) ---

func _draw_team_selector() -> void:
	var team: PSTeam = GameDb.get_team(_team_id)
	if team == null:
		return
	_text("閲覧球団", Vector2(TEAM_SEL_X, ID_Y - 18), 11, FAINT)
	_team_badge(Rect2(TEAM_SEL_X, ID_Y - 4, 28, 28), team)
	_text(team.name, Vector2(TEAM_SEL_X + 38, ID_Y + 18), 18, TEXT)
	var nx: float = TEAM_SEL_X + 38 + _measure(team.name, 18) + 10.0
	_text("▼", Vector2(nx, ID_Y + 15), 13, MUTED)


func _team_hotspot_rect() -> Rect2:
	var team: PSTeam = GameDb.get_team(_team_id)
	var name_w: float = _measure(team.name, 18) if team != null else 0.0
	return Rect2(TEAM_SEL_X - 6.0, ID_Y - 6.0, 38.0 + name_w + 28.0, 36.0)


# --- ポジション絞り込み (chip 描画はボタン側に任せ、ここはラベルのみ) ---

func _draw_filters() -> void:
	_text("絞り込み", Vector2(INNER_L, FILTER_Y + 4), 12, FAINT)


# --- 能力パネル (基本能力 + 守備適性/変化球 をすべてバー表示) ---

func _draw_ability(rect: Rect2) -> void:
	_panel(rect, "能力")

	_panel(rect, "能力")
	var x: float = rect.position.x + 20.0
	var w: float = rect.size.x - 40.0
	var bar_top: float = rect.position.y + 64.0
	# 能力名の幅はラベルにぴったり合わせ、値をその右に詰める。
	var label_w: float = 62.0 if _record.is_pitcher() else 44.0
	var value_box: float = 64.0   # 球速 "150km/h" が入る幅

	var ratings: Array = _ratings.get("display_ratings", []) as Array
	if ratings.is_empty():
		_text("能力データがありません", Vector2(x, bar_top + 6.0), 14, MUTED)
		return
	for i in range(ratings.size()):
		var row: Dictionary = ratings[i] as Dictionary
		var suffix: String = str(row.get("suffix", ""))
		var value: int = int(row.get("display_value", row.get("value", 0)))
		var factor: float = clampf((float(value) - 120.0) / 45.0, 0.0, 1.0) if suffix == "km/h" else clampf(float(value) / 100.0, 0.0, 1.0)
		_draw_bar(x, bar_top + float(i) * ABILITY_BAR_H, w, label_w, value_box,
			str(row.get("label", "")), "%d%s" % [value, suffix], factor, _rating_color(value, suffix))


# 守備適性 (野手) / 変化球 (投手) は能力とは別パネルに分離する。
func _draw_apt(rect: Rect2) -> void:
	if _record.is_pitcher():
		_panel(rect, "変化球")
		_draw_arsenal_bars(rect)
	else:
		_panel(rect, "守備適性")
		_draw_aptitude_bars(rect)


func _draw_aptitude_bars(rect: Rect2) -> void:
	var x: float = rect.position.x + 20.0
	var w: float = rect.size.x - 40.0
	var bar_top: float = rect.position.y + 64.0
	var entries: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		var apt: int = _position_aptitude(_record, pos)
		if apt > 0:
			entries.append({"label": str(POS_SHORT.get(pos, "?")), "value": apt})
	if entries.is_empty():
		_text("守備適性なし", Vector2(x, bar_top + 6.0), 14, MUTED)
		return
	for i in range(entries.size()):
		var entry: Dictionary = entries[i] as Dictionary
		var value: int = int(entry["value"])
		_draw_bar(x, bar_top + float(i) * ABILITY_BAR_H, w, 30.0, 36.0,
			str(entry["label"]), str(value), clampf(float(value) / 100.0, 0.0, 1.0), _rating_color(value, ""))


func _draw_arsenal_bars(rect: Rect2) -> void:
	var x: float = rect.position.x + 20.0
	var w: float = rect.size.x - 40.0
	var bar_top: float = rect.position.y + 64.0
	var arsenal: Array = _record.arsenal_or_derived()
	if arsenal.is_empty():
		_text("変化球データなし", Vector2(x, bar_top + 6.0), 14, MUTED)
		return
	var entries: Array = arsenal.duplicate()
	entries.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary).get("mastery", 0.0)) > float((b as Dictionary).get("mastery", 0.0))
	)
	for i in range(entries.size()):
		var entry: Dictionary = entries[i] as Dictionary
		var mastery: float = float(entry.get("mastery", 0.0))
		var display: int = PSAbilityScale.z_to_display(mastery)
		var label: String = PSPitchTypes.display_name(str(entry.get("type", "")))
		_draw_bar(x, bar_top + float(i) * ABILITY_BAR_H, w, 100.0, 36.0,
			label, str(display), clampf(float(display) / 100.0, 0.0, 1.0), _rating_color(display, ""))


# ラベル + 値 + バー の1行。値は能力名のすぐ右(バーの左)に左寄せで詰める。x..x+w に収める。
# label_w はラベルにぴったりの幅にすると値が能力名のすぐ右に来る。
func _draw_bar(x: float, cy: float, w: float, label_w: float, value_box: float, label: String, value_text: String, factor: float, color: Color) -> void:
	var bar_x: float = x + label_w + value_box + 8.0
	var bar_w: float = w - label_w - value_box - 8.0
	_text(label, Vector2(x, cy + 5.0), 14, MUTED, label_w - 2.0)
	_text(value_text, Vector2(x + label_w, cy + 5.0), 14, TEXT, value_box)
	_round(Rect2(bar_x, cy - 5.0, bar_w, 10.0), PANEL_2, Color.TRANSPARENT, 5, 0)
	if factor > 0.0:
		_round(Rect2(bar_x, cy - 5.0, bar_w * factor, 10.0), color, Color.TRANSPARENT, 5, 0)


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


# --- プロフィール・契約パネル ---

func _draw_profile(rect: Rect2) -> void:
	_panel(rect, "プロフィール・契約")

	var pairs: Array = [
		{"label": "登録区分", "value": ("育成" if _record.development_player else _record.registered_roster) + "  " + _record.contract_status},
		{"label": "契約", "value": _contract_status_text(_record)},
		{"label": "年俸", "value": _format_money(_record.salary)},
		{"label": "出身", "value": _record.hometown if not _record.hometown.is_empty() else "—"},
		{"label": "疲労・怪我", "value": _condition_text(_record)},
	]
	var label_x: float = rect.position.x + 22.0
	var value_x: float = rect.position.x + 170.0
	var top: float = rect.position.y + 58.0
	var row_h: float = (rect.end.y - top - 14.0) / float(pairs.size())
	for i in range(pairs.size()):
		var pair: Dictionary = pairs[i] as Dictionary
		var ry: float = top + float(i) * row_h
		var ty: float = ry + row_h * 0.5 + 5.0
		if i % 2 == 1:
			_round(Rect2(rect.position.x + 12, ry, rect.size.x - 24, row_h), Color(1, 1, 1, 0.018), Color.TRANSPARENT, 4, 0)
		_text(str(pair["label"]), Vector2(label_x, ty), 13, MUTED, value_x - label_x - 8.0)
		var color: Color = AMBER if str(pair["label"]) == "疲労・怪我" and _record.injury_days > 0 else TEXT
		_text(str(pair["value"]), Vector2(value_x, ty), 14, color, rect.end.x - 22.0 - value_x)


func _contract_status_text(record: PSPlayerSeasonRecord) -> String:
	if record.is_fa_eligible():
		return "FA可能 (保有権消滅)"
	var remaining_days: int = record.fa_service_days_required() - record.fa_service_days()
	return "FA権まであと%d日 (%d/%d日)" % [remaining_days, record.fa_service_days(), record.fa_service_days_required()]


func _condition_text(record: PSPlayerSeasonRecord) -> String:
	if record.injury_days > 0:
		return "疲労%d / 故障 %s (%d日)" % [record.fatigue, record.injury_display_label(), record.injury_days]
	return "疲労%d / 健康" % record.fatigue


# --- 総合評価パネル (大きな文字で総合評価 + 内訳) ---

func _draw_eval(rect: Rect2) -> void:
	_panel(rect, "総合評価")
	var score: int = PlayerValueEvaluator.overall_score(_record)
	# 総合評価を大きな数値で。
	_text(str(score), Vector2(rect.position.x, rect.position.y + 142.0), 64, _eval_color(score), rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_line(Vector2(rect.position.x + 26, rect.position.y + 172.0), Vector2(rect.end.x - 26, rect.position.y + 172.0), BORDER_SOFT, 1.0)

	# 内訳 (打撃 / 守備) も大きめの文字で。行数に応じて間隔を詰める。
	var items: Array = _eval_items(_record)
	var top: float = rect.position.y + 190.0
	var avail: float = rect.end.y - 18.0 - top
	var row_h: float = avail / float(max(1, items.size()))
	for i in range(items.size()):
		var item: Dictionary = items[i] as Dictionary
		var cy: float = top + float(i) * row_h + row_h * 0.5
		var value: int = int(item["value"])
		_text(str(item["label"]), Vector2(rect.position.x + 26, cy + 6.0), 18, MUTED, rect.size.x - 162.0)
		_text_right(str(value), rect.end.x - 26, cy + 9.0, 30, _eval_color(value), 110)


# 守備内訳は「本職(登録ポジション)」と「最多出場ポジション」の守備評価を出す
# (best_defensive_fit だと本職でない位置が選ばれがちなため要望で変更)。
func _eval_items(record: PSPlayerSeasonRecord) -> Array:
	if record.is_pitcher():
		return [{"label": "守備", "value": PlayerValueEvaluator.defensive_score_for_position(record, 1)}]
	var items: Array = [{"label": "打撃", "value": PlayerValueEvaluator.batting_score_without_fatigue(record)}]
	var primary: int = record.position
	if primary >= 2 and primary <= 9:
		items.append({
			"label": "守備 本職(%s)" % str(POS_SHORT.get(primary, "?")),
			"value": PlayerValueEvaluator.defensive_score_for_position(record, primary),
		})
	var most: int = record.advanced_stats.primary_uzr_position() if record.advanced_stats != null else 0
	if most >= 2 and most <= 9 and most != primary:
		items.append({
			"label": "守備 最多(%s)" % str(POS_SHORT.get(most, "?")),
			"value": PlayerValueEvaluator.defensive_score_for_position(record, most),
		})
	return items


# --- 下部タブ表 ---

# 今季タブ: 成績+高度指標をカテゴリ別の段落 + 大きなカードで全部見せる (表ではない)。
func _draw_season(rect: Rect2) -> void:
	_round(rect, PANEL, BORDER, 10)
	_ensure_season_cards()
	_text_right("%d年 (%d年目) の全成績" % [_record.year, _record.years], rect.end.x - 18.0, rect.position.y + 44.0, 14, MUTED, 360)
	if _season_groups.is_empty():
		_text("今季の記録がありません", Vector2(rect.position.x + 24.0, rect.position.y + rect.size.y * 0.5), 16, MUTED)
		return

	var cols: int = 9
	var gap: float = 8.0
	var header_h: float = 28.0
	var section_gap: float = 12.0
	var inner_x: float = rect.position.x + 16.0
	var top: float = rect.position.y + 72.0
	var card_w: float = (rect.size.x - 32.0 - gap * float(cols - 1)) / float(cols)

	# カテゴリごとの行数からカード高さを一定に揃える。
	var n_sections: int = _season_groups.size()
	var total_rows: int = 0
	for group_value in _season_groups:
		total_rows += int(ceil(float((group_value as Dictionary).get("cards", []).size()) / float(cols)))
	var avail_h: float = rect.end.y - 16.0 - top
	var card_h: float = (avail_h - header_h * float(n_sections) - section_gap * float(n_sections - 1) - gap * float(total_rows - n_sections)) / float(max(1, total_rows))

	var y: float = top
	for group_value in _season_groups:
		var group: Dictionary = group_value as Dictionary
		_text(str(group.get("title", "")), Vector2(inner_x, y + 19.0), 15, TEXT, 300.0, HORIZONTAL_ALIGNMENT_LEFT, true)
		_line(Vector2(inner_x, y + 26.0), Vector2(rect.end.x - 16.0, y + 26.0), BORDER_SOFT, 1.0)
		y += header_h
		var cards: Array = group.get("cards", []) as Array
		var grows: int = int(ceil(float(cards.size()) / float(cols)))
		var idx: int = 0
		for r in range(grows):
			for c in range(cols):
				if idx >= cards.size():
					break
				var card: Dictionary = cards[idx] as Dictionary
				var cx: float = inner_x + float(c) * (card_w + gap)
				var cy: float = y + float(r) * (card_h + gap)
				_round(Rect2(cx, cy, card_w, card_h), PANEL_2, BORDER_SOFT, 8)
				_text(str(card["label"]), Vector2(cx + 10.0, cy + 20.0), 12, MUTED, card_w - 14.0)
				_text(str(card["value"]), Vector2(cx, cy + card_h - 14.0), 24, TEXT, card_w, HORIZONTAL_ALIGNMENT_CENTER)
				idx += 1
		y += float(grows) * card_h + float(grows - 1) * gap + section_gap


# 描画本体は基底 _draw_data_table に集約 (2026-06-24)。タブボタンはヘッダ帯に重なるため見出しは描かず
# header_top=84 から始める。通算行 (is_total) 強調 + 奇数行縞 (alt_rows) + 行高上限40 は opts で指定。
func _draw_table(rect: Rect2) -> void:
	_draw_data_table(rect, _columns_for_tab(), _rows_for_tab(), {
		"header_top": 84.0, "inner_pad": 16.0, "header_size": 12,
		"row_h_max": 40.0, "alt_rows": true, "empty_text": "記録がありません",
	})


# 表のカラム定義。タブ + 投手/野手で切り替える。
func _columns_for_tab() -> Array:
	var pitcher: bool = _record != null and _record.is_pitcher()
	match _active_tab:
		"advanced":
			if pitcher:
				return [
					{"title": "年", "key": "year", "w": 64, "align": "l", "fmt": "str"},
					{"title": "チーム", "key": "team", "w": 70, "align": "l", "fmt": "str"},
					{"title": "投球回", "key": "ip", "w": 76, "align": "r", "fmt": "f1"},
					{"title": "FIP", "key": "fip", "w": 70, "align": "r", "fmt": "f2"},
					{"title": "WAR", "key": "war", "w": 70, "align": "r", "fmt": "f1s"},
					{"title": "K/9", "key": "k9", "w": 60, "align": "r", "fmt": "f2"},
					{"title": "BB/9", "key": "bb9", "w": 64, "align": "r", "fmt": "f2"},
					{"title": "HR/9", "key": "hr9", "w": 64, "align": "r", "fmt": "f2"},
					{"title": "球/打者", "key": "ppbf", "w": 72, "align": "r", "fmt": "f2"},
					{"title": "球/回", "key": "ppi", "w": 66, "align": "r", "fmt": "f1"},
					{"title": "対戦打者", "key": "bf", "w": 78, "align": "r", "fmt": "int"},
					{"title": "投球数", "key": "pit", "w": 74, "align": "r", "fmt": "int"},
					{"title": "救援", "key": "rel", "w": 60, "align": "r", "fmt": "int"},
				]
			return [
				{"title": "年", "key": "year", "w": 54, "align": "l", "fmt": "str"},
				{"title": "チーム", "key": "team", "w": 56, "align": "l", "fmt": "str"},
				{"title": "打席", "key": "pa", "w": 50, "align": "r", "fmt": "int"},
				{"title": "球/打席", "key": "ppa", "w": 64, "align": "r", "fmt": "f2"},
				{"title": "wOBA", "key": "woba", "w": 62, "align": "r", "fmt": "rate"},
				{"title": "xwOBA", "key": "xwoba", "w": 66, "align": "r", "fmt": "rate"},
				{"title": "wRC+", "key": "wrcplus", "w": 60, "align": "r", "fmt": "f1"},
				{"title": "RE24", "key": "re24", "w": 64, "align": "r", "fmt": "f1s"},
				{"title": "BSR", "key": "bsr", "w": 60, "align": "r", "fmt": "f1s"},
				{"title": "WAR", "key": "war", "w": 62, "align": "r", "fmt": "f1s"},
				{"title": "OAA", "key": "oaa", "w": 60, "align": "r", "fmt": "f1s"},
				{"title": "OAA内", "key": "oaa_if", "w": 66, "align": "r", "fmt": "f1s"},
				{"title": "OAA外", "key": "oaa_of", "w": 66, "align": "r", "fmt": "f1s"},
				{"title": "RngR", "key": "rngr", "w": 62, "align": "r", "fmt": "f1s"},
				{"title": "ErrR", "key": "errr", "w": 62, "align": "r", "fmt": "f1s"},
				{"title": "DPR", "key": "dpr", "w": 58, "align": "r", "fmt": "f1s"},
				{"title": "UZR", "key": "uzr", "w": 60, "align": "r", "fmt": "f1s"},
				{"title": "DRS", "key": "drs", "w": 60, "align": "r", "fmt": "f1s"},
			]
		"abilities":
			# 能力レーティング + 変化球(投手)/守備適性(野手) + 各種評価 + 年俸。変化球/適性カラムは動的。
			# 年齢〜能力(変化球/守備適性)は値が短いので中央寄せ("c")。評価/年俸は右寄せ。
			var cols: Array = [
				{"title": "年", "key": "year", "w": 50, "align": "l", "fmt": "str"},
				{"title": "年齢", "key": "age", "w": 44, "align": "c", "fmt": "int"},
			]
			if pitcher:
				cols.append({"title": "球速", "key": "velocity", "w": 56, "align": "c", "fmt": "int"})
				cols.append({"title": "球質", "key": "stuff", "w": 52, "align": "c", "fmt": "int"})
				cols.append({"title": "制球", "key": "control", "w": 52, "align": "c", "fmt": "int"})
				cols.append({"title": "持久", "key": "stamina", "w": 60, "align": "c", "fmt": "int"})
				for type_value in _arsenal_types:
					cols.append({"title": PSPitchTypes.display_name(str(type_value)), "key": "pitch_%s" % str(type_value), "w": 66, "align": "c", "fmt": "int"})
				cols.append({"title": "総合評価", "key": "overall", "w": 60, "align": "r", "fmt": "int"})
				cols.append({"title": "守備評価", "key": "def_eval", "w": 58, "align": "r", "fmt": "int"})
				cols.append({"title": "年俸(万円)", "key": "salary", "w": 84, "align": "r", "fmt": "comma"})
			else:
				cols.append({"title": "巧打", "key": "contact", "w": 50, "align": "c", "fmt": "int"})
				cols.append({"title": "長打", "key": "power", "w": 50, "align": "c", "fmt": "int"})
				cols.append({"title": "走力", "key": "speed", "w": 50, "align": "c", "fmt": "int"})
				cols.append({"title": "守備", "key": "defense", "w": 50, "align": "c", "fmt": "int"})
				cols.append({"title": "肩力", "key": "arm", "w": 50, "align": "c", "fmt": "int"})
				cols.append({"title": "選球", "key": "discipline", "w": 50, "align": "c", "fmt": "int"})
				for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
					cols.append({"title": str(POS_SHORT.get(pos, "?")), "key": "apt_%d" % pos, "w": 38, "align": "c", "fmt": "int"})
				cols.append({"title": "総合評価", "key": "overall", "w": 58, "align": "r", "fmt": "int"})
				cols.append({"title": "打撃評価", "key": "bat_eval", "w": 58, "align": "r", "fmt": "int"})
				cols.append({"title": "守備評価", "key": "def_eval", "w": 58, "align": "r", "fmt": "int"})
				cols.append({"title": "年俸(万円)", "key": "salary", "w": 82, "align": "r", "fmt": "comma"})
			return cols
		_:  # stats (成績 = 基本成績 + 率指標を統合)
			if pitcher:
				return [
					{"title": "年", "key": "year", "w": 52, "align": "l", "fmt": "str"},
					{"title": "チーム", "key": "team", "w": 54, "align": "l", "fmt": "str"},
					{"title": "登板", "key": "g", "w": 46, "align": "r", "fmt": "int"},
					{"title": "先発", "key": "gs", "w": 46, "align": "r", "fmt": "int"},
					{"title": "完投", "key": "cg", "w": 46, "align": "r", "fmt": "int"},
					{"title": "完封", "key": "sho", "w": 46, "align": "r", "fmt": "int"},
					{"title": "勝", "key": "w", "w": 38, "align": "r", "fmt": "int"},
					{"title": "敗", "key": "l", "w": 38, "align": "r", "fmt": "int"},
					{"title": "H", "key": "hld", "w": 38, "align": "r", "fmt": "int"},
					{"title": "S", "key": "sv", "w": 38, "align": "r", "fmt": "int"},
					{"title": "QS", "key": "qs", "w": 42, "align": "r", "fmt": "int"},
					{"title": "投球回", "key": "ip", "w": 60, "align": "r", "fmt": "f1"},
					{"title": "防御率", "key": "era", "w": 58, "align": "r", "fmt": "f2"},
					{"title": "WHIP", "key": "whip", "w": 56, "align": "r", "fmt": "f2"},
					{"title": "奪三振", "key": "so", "w": 56, "align": "r", "fmt": "int"},
					{"title": "与四球", "key": "bb", "w": 56, "align": "r", "fmt": "int"},
					{"title": "与死球", "key": "hbp", "w": 56, "align": "r", "fmt": "int"},
					{"title": "被安打", "key": "h", "w": 56, "align": "r", "fmt": "int"},
					{"title": "被本", "key": "hra", "w": 48, "align": "r", "fmt": "int"},
					{"title": "失点", "key": "ra", "w": 48, "align": "r", "fmt": "int"},
					{"title": "自責", "key": "er", "w": 48, "align": "r", "fmt": "int"},
				]
			return [
				{"title": "年", "key": "year", "w": 50, "align": "l", "fmt": "str"},
				{"title": "チーム", "key": "team", "w": 52, "align": "l", "fmt": "str"},
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
			]


func _rows_for_tab() -> Array:
	match _active_tab:
		"advanced":
			_ensure_advanced()
			return _advanced_rows
		"abilities":
			return _ability_rows
		_:  # stats / rates は同じ行データ (列違い)
			return _basic_rows


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	if season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# 閲覧球団プルダウン (右端の透明ボタン)。
	_team_menu_button = _add_button("team_menu", "", _team_hotspot_rect(), _on_team_menu_pressed, "nav")

	# ポジション絞り込み chip 行。
	var x: float = INNER_L + 78.0
	for filter_value in POS_FILTERS:
		var filter: Dictionary = filter_value as Dictionary
		var fid: String = str(filter["id"])
		var active: bool = fid == _filter_id
		var w: float = 46.0 if str(filter["label"]).length() <= 1 else 56.0
		_add_button("pf_%s" % fid, str(filter["label"]), Rect2(x, FILTER_Y - 4.0, w, 30.0),
			func(target: String = fid) -> void: _on_filter_pressed(target), "chip_active" if active else "chip")
		x += w + 8.0

	# 選手プルダウン (名前を覆う透明ボタン)。
	if _record != null:
		_player_menu_button = _add_button("player_menu", "", _player_hotspot_rect(), _on_player_menu_pressed, "nav")

	# 下部タブ。
	var tx: float = TABLE_RECT.position.x + 18.0
	for tab_value in TABS:
		var tab: Dictionary = tab_value as Dictionary
		var tab_id: String = str(tab["id"])
		var active_tab: bool = tab_id == _active_tab
		_add_button("tab_%s" % tab_id, str(tab["label"]), Rect2(tx, TABLE_RECT.position.y + 18.0, 132.0, 38.0),
			func(target: String = tab_id) -> void: _on_tab_pressed(target), "chip_active" if active_tab else "chip")
		tx += 142.0

	_layout_buttons()


func _on_filter_pressed(filter_id: String) -> void:
	if _filter_id == filter_id:
		return
	_filter_id = filter_id
	_rebuild_candidates()
	if not _candidate_has(_player_id):
		_player_id = _first_candidate_id()
	_refresh()
	_build_buttons()
	queue_redraw()


func _on_tab_pressed(tab_id: String) -> void:
	if _active_tab == tab_id:
		return
	_active_tab = tab_id
	_build_buttons()
	queue_redraw()


func _on_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	for i in range(_team_ids.size()):
		var team: PSTeam = GameDb.get_team(int(_team_ids[i]))
		if team == null:
			continue
		if i > 0:
			var prev: PSTeam = GameDb.get_team(int(_team_ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(team.league_label())
		elif team != null:
			menu.add_separator(team.league_label())
		menu.add_item("%s (%s)" % [team.name, team.short_name], int(_team_ids[i]))
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_team_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(TEAM_SEL_X, ID_Y + 24.0))
	if _team_menu_button != null:
		anchor = _team_menu_button.global_position + Vector2(0.0, _team_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_team_selected(team_id: int) -> void:
	if team_id == _team_id or not _team_ids.has(team_id):
		return
	_team_id = team_id
	_rebuild_candidates()
	_player_id = _first_candidate_id()
	_refresh()
	_build_buttons()
	queue_redraw()


func _on_player_menu_pressed() -> void:
	if _candidates.is_empty():
		return
	var menu: PopupMenu = PopupMenu.new()
	for record_value in _candidates:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		menu.add_item("[%s] %s" % [_role_or_position_short(record), record.name], record.player_id)
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_player_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(INNER_L, ID_Y + 24.0))
	if _player_menu_button != null:
		anchor = _player_menu_button.global_position + Vector2(0.0, _player_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_player_selected(player_id: int) -> void:
	if player_id == _player_id:
		return
	_player_id = player_id
	_refresh()
	_build_buttons()
	queue_redraw()


# ダッシュボードのダーク配色に合わせて PopupMenu をテーマ上書きする (team_detail から移植)。
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
	menu.add_theme_color_override("font_separator_color", MUTED)
	menu.add_theme_constant_override("v_separation", 6)
	if _font != null:
		menu.add_theme_font_override("font", _font)
	menu.add_theme_font_size_override("font_size", max(11, int(round(14.0 * _scale_f))))


# ============================================================ data

func _build_team_order() -> void:
	_team_ids = []
	for league_key in ["central", "pacific"]:
		var ids: Array = []
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team.league == league_key:
				ids.append(team.id)
		ids.sort()
		for id_value in ids:
			_team_ids.append(int(id_value))


# 初期表示: 直近に見ていた選手があればその選手・球団・絞り込みへ合わせる。
func _resolve_initial() -> void:
	var season: PSSeason = AppState.current_season
	_team_id = AppState.selected_team_id
	if _team_id <= 0 and not _team_ids.is_empty():
		_team_id = int(_team_ids[0])

	if season != null and AppState.current_player_id > 0:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(AppState.current_player_id, season.year, season.season_number)
		if record != null:
			_team_id = record.team_id
			_filter_id = _filter_id_for_record(record)
			_player_id = record.player_id

	if not _team_ids.has(_team_id) and not _team_ids.is_empty():
		_team_id = int(_team_ids[0])
	_rebuild_candidates()
	if not _candidate_has(_player_id):
		_player_id = _first_candidate_id()


# 選手の主ポジション/役割に対応する絞り込み id。
func _filter_id_for_record(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher():
		return "starter" if record.is_starter_pitcher() else "reliever"
	if record.position >= 2 and record.position <= 9:
		return "pos%d" % record.position
	return "all"


# 閲覧球団 + ポジション絞り込みで選手候補を作る (overall 降順)。
func _rebuild_candidates() -> void:
	_candidates = []
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		return
	for record_row in RecordStore.get_team_player_records(_team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if _filter_match(record):
			_candidates.append(record)
	_candidates.sort_custom(func(a: Variant, b: Variant) -> bool:
		return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
	)


func _filter_match(record: PSPlayerSeasonRecord) -> bool:
	match _filter_id:
		"all":
			return true
		"starter":
			return record.is_pitcher() and record.is_starter_pitcher()
		"reliever":
			return record.is_pitcher() and not record.is_starter_pitcher()
		_:
			# pos2..pos9
			if record.is_pitcher():
				return false
			return record.position == int(_filter_id.trim_prefix("pos"))


func _candidate_has(player_id: int) -> bool:
	for record_value in _candidates:
		if (record_value as PSPlayerSeasonRecord).player_id == player_id:
			return true
	return false


func _first_candidate_id() -> int:
	if _candidates.is_empty():
		return 0
	return (_candidates[0] as PSPlayerSeasonRecord).player_id


# 選択選手のすべての派生データを作り直す。
func _refresh() -> void:
	_record = null
	_records = []
	_ratings = {}
	_basic_rows = []
	_ability_rows = []
	_advanced_rows = []
	_advanced_built = false
	_season_groups = []
	_season_built = false
	_arsenal_types = []

	var season: PSSeason = AppState.current_season
	if season == null or _player_id <= 0:
		return
	_record = RecordStore.get_player_record(_player_id, season.year, season.season_number)
	if _record == null:
		return
	AppState.current_player_id = _player_id
	_records = RecordStore.get_player_records(_player_id)
	_ratings = PSPlayerVisibleRatings.ratings_for_record(_record)
	_compute_arsenal_types()
	_build_basic_rows()
	_build_ability_rows()


# 成績/指標タブ共用の行データ (1シーズン分の全ボックススコア項目) + 通算行。
func _build_basic_rows() -> void:
	var pitcher: bool = _record.is_pitcher()
	for record_value in _records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var team: String = _team_short(record.team_id)
		var row: Dictionary
		if pitcher:
			row = _pitcher_basic_dict("%d年" % record.year, team, record.pitcher_stats, false)
		else:
			row = _batter_basic_dict("%d年" % record.year, team, record.batter_stats, false)
		_basic_rows.append(row)
	if pitcher:
		_basic_rows.append(_pitcher_basic_dict("通算", "", RecordStore.get_player_career_pitcher_stats(_player_id), true))
	else:
		_basic_rows.append(_batter_basic_dict("通算", "", RecordStore.get_player_career_batter_stats(_player_id), true))


func _batter_basic_dict(year_label: String, team: String, s: PSBatterStats, is_total: bool) -> Dictionary:
	return {
		"year": year_label, "team": team, "is_total": is_total,
		"g": s.games, "pa": s.plate_appearances, "ab": s.at_bats, "r": s.runs, "h": s.hits,
		"d": s.doubles, "t": s.triples, "hr": s.home_runs, "rbi": s.runs_batted_in, "sb": s.stolen_bases,
		"avg": s.batting_average(), "obp": s.on_base_percentage(), "slg": s.slugging_percentage(), "ops": s.ops(),
		"bb": s.walks, "hbp": s.hit_by_pitches, "so": s.strikeouts, "sba": s.stolen_base_attempts,
		"sac": s.sacrifices, "sf": s.sacrifice_flies, "gdp": s.double_plays, "err": s.errors,
	}


func _pitcher_basic_dict(year_label: String, team: String, s: PSPitcherStats, is_total: bool) -> Dictionary:
	return {
		"year": year_label, "team": team, "is_total": is_total,
		"g": s.games, "gs": s.starts, "rel": s.relief_appearances, "cg": s.complete_games, "sho": s.shutouts,
		"w": s.wins, "l": s.losses, "hld": s.holds, "sv": s.saves, "qs": s.quality_starts,
		"ip": s.innings_pitched(), "era": s.era(), "whip": s.whip(), "k9": s.strikeouts_per_nine(),
		"so": s.strikeouts, "bb": s.walks, "hbp": s.hit_batters, "h": s.hits_allowed, "hra": s.home_runs_allowed,
		"ra": s.runs_allowed, "er": s.earned_runs, "bf": s.batters_faced, "pit": s.pitches_thrown,
	}


func _build_ability_rows() -> void:
	for record_value in _records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var result: Dictionary = PSPlayerVisibleRatings.ratings_for_record(record)
		var row: Dictionary = {"year": "%d年" % record.year, "age": record.age}
		for rating_value in (result.get("display_ratings", []) as Array):
			var rating: Dictionary = rating_value as Dictionary
			row[str(rating.get("key", ""))] = int(rating.get("display_value", rating.get("value", 0)))
		# 各種評価 + 年俸の推移も載せる。
		row["overall"] = PlayerValueEvaluator.overall_score(record)
		row["salary"] = record.salary
		if record.is_pitcher():
			row["def_eval"] = PlayerValueEvaluator.defensive_score_for_position(record, 1)
			# 変化球: 全季の和集合カラムに対し、その季に持っていれば完成度、無ければ "-"。
			var mastery_by_type: Dictionary = {}
			for entry_value in record.arsenal_or_derived():
				var entry: Dictionary = entry_value as Dictionary
				mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
			for type_value in _arsenal_types:
				var type_key: String = str(type_value)
				row["pitch_%s" % type_key] = PSAbilityScale.z_to_display(float(mastery_by_type[type_key])) if mastery_by_type.has(type_key) else "-"
		else:
			row["bat_eval"] = PlayerValueEvaluator.batting_score_without_fatigue(record)
			row["def_eval"] = PlayerValueEvaluator.defensive_score_for_position(record, record.position) if (record.position >= 2 and record.position <= 9) else "-"
			# 守備適性: 全8守備位置。未習得(0)は "-"。
			for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
				var apt: int = _position_aptitude(record, pos)
				row["apt_%d" % pos] = apt if apt > 0 else "-"
		_ability_rows.append(row)


# 変遷表の変化球カラム順 = 現在のアーセナルを完成度降順 → 過去季にしか無い球種を後ろに追加 (和集合)。
func _compute_arsenal_types() -> void:
	_arsenal_types = []
	if _record == null or not _record.is_pitcher():
		return
	var seen: Dictionary = {}
	var current: Array = _record.arsenal_or_derived().duplicate()
	current.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float((a as Dictionary).get("mastery", 0.0)) > float((b as Dictionary).get("mastery", 0.0))
	)
	for entry_value in current:
		var t: String = str((entry_value as Dictionary).get("type", ""))
		if not t.is_empty() and not seen.has(t):
			seen[t] = true
			_arsenal_types.append(t)
	for record_value in _records:
		for entry_value in (record_value as PSPlayerSeasonRecord).arsenal_or_derived():
			var t2: String = str((entry_value as Dictionary).get("type", ""))
			if not t2.is_empty() and not seen.has(t2):
				seen[t2] = true
				_arsenal_types.append(t2)


# 高度指標タブ (計測レポートの z 能力値以外の指標を網羅) はリーグ文脈が要るので開いたときに 1 度だけ計算する。
func _ensure_advanced() -> void:
	if _advanced_built:
		return
	_advanced_built = true
	_advanced_rows = []
	var pitcher: bool = _record.is_pitcher()
	var war_sum: float = 0.0
	var ad_career: PSAdvancedStats = PSAdvancedStats.new()
	var bat_career: PSBatterStats = PSBatterStats.new()
	var pit_career: PSPitcherStats = PSPitcherStats.new()
	var fip_weighted: float = 0.0
	var fip_weight: float = 0.0
	for record_value in _records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var ctx: Dictionary = _league_ctx_for(record.year, record.season_number)
		var war: Dictionary = WarCalculator.season_war(record, ctx)
		var team: String = _team_short(record.team_id)
		var row: Dictionary
		if pitcher:
			row = _pitcher_advanced_dict(record, war, team)
			pit_career.add_from(record.pitcher_stats)
			if record.pitcher_stats.outs_pitched > 0:
				var ip: float = record.pitcher_stats.innings_pitched()
				war_sum += float(war.get("war", 0.0))
				fip_weighted += float(war.get("fip", 0.0)) * ip
				fip_weight += ip
		else:
			row = _batter_advanced_dict(record, war, team)
			if record.advanced_stats != null:
				ad_career.add_from(record.advanced_stats)
				bat_career.add_from(record.batter_stats)
				if record.advanced_stats.plate_appearances > 0:
					war_sum += float(war.get("war", 0.0))
		_advanced_rows.append(row)
	# 通算行は一番下。
	if _records.is_empty():
		return
	if pitcher:
		_advanced_rows.append(_pitcher_advanced_career(pit_career, war_sum, fip_weighted, fip_weight))
	else:
		_advanced_rows.append(_batter_advanced_career(ad_career, bat_career, war_sum))


func _batter_advanced_career(ad: PSAdvancedStats, bat: PSBatterStats, war_sum: float) -> Dictionary:
	var has_pa: bool = ad.plate_appearances > 0
	var ad_dict: Dictionary = ad.to_dict()
	var chances: int = int(ad_dict.get("fielding_chances", 0))
	var has_field: bool = chances > 0
	var fv: Callable = func(key: String) -> Variant:
		return float(ad_dict.get(key, 0.0)) if has_field else "-"
	return {
		"year": "通算", "team": "", "is_total": true,
		"pa": ad.plate_appearances,
		"ppa": (float(bat.pitches_seen) / float(bat.plate_appearances)) if bat.plate_appearances > 0 else "-",
		"woba": ad.woba() if has_pa else "-",
		"xwoba": ad.xwoba() if has_pa else "-",
		"wrcplus": ad.wrc_plus() if has_pa else "-",
		"re24": ad.re24_sum if has_pa else "-",
		"bsr": ad.bsr_sum if has_pa else "-",
		"war": war_sum,
		"chances": chances if has_field else "-",
		"oaa": fv.call("oaa_total"), "oaa_if": fv.call("oaa_infield"), "oaa_of": fv.call("oaa_outfield"),
		"rngr": fv.call("rngr"), "errr": fv.call("errr"), "dpr": fv.call("dpr"),
		"uzr": fv.call("uzr"), "drs": fv.call("drs"), "def_runs": fv.call("def_runs"), "pos_adj": fv.call("positional_adjustment_runs"),
	}


func _pitcher_advanced_career(pit: PSPitcherStats, war_sum: float, fip_weighted: float, fip_weight: float) -> Dictionary:
	var has_ip: bool = pit.outs_pitched > 0
	var ip: float = pit.innings_pitched()
	return {
		"year": "通算", "team": "", "is_total": true,
		"ip": ip,
		"fip": (fip_weighted / fip_weight) if fip_weight > 0.0 else "-",
		"war": war_sum,
		"k9": pit.strikeouts_per_nine() if has_ip else "-",
		"bb9": (float(pit.walks) * 9.0 / ip) if has_ip else "-",
		"hr9": (float(pit.home_runs_allowed) * 9.0 / ip) if has_ip else "-",
		"ppbf": (float(pit.pitches_thrown) / float(pit.batters_faced)) if pit.batters_faced > 0 else "-",
		"ppi": (float(pit.pitches_thrown) / ip) if has_ip else "-",
		"bf": pit.batters_faced, "pit": pit.pitches_thrown, "rel": pit.relief_appearances,
	}


# --- 今季タブ用カード ---

func _ensure_season_cards() -> void:
	if _season_built:
		return
	_season_built = true
	_season_groups = []
	if _record == null:
		return
	var ctx: Dictionary = _league_ctx_for(_record.year, _record.season_number)
	var war: Dictionary = WarCalculator.season_war(_record, ctx)
	var team: String = _team_short(_record.team_id)
	if _record.is_pitcher():
		_season_groups = _pitcher_season_groups(
			_pitcher_basic_dict("", team, _record.pitcher_stats, false),
			_pitcher_advanced_dict(_record, war, team))
	else:
		_season_groups = _batter_season_groups(
			_batter_basic_dict("", team, _record.batter_stats, false),
			_batter_advanced_dict(_record, war, team))


func _card(label: String, fmt: String, value: Variant) -> Dictionary:
	return {"label": label, "value": _fmt_cell(fmt, value)}


func _batter_season_groups(b: Dictionary, a: Dictionary) -> Array:
	return [
		{"title": "打撃成績", "cards": [
			_card("試合", "int", b["g"]), _card("打席", "int", b["pa"]), _card("打数", "int", b["ab"]),
			_card("得点", "int", b["r"]), _card("安打", "int", b["h"]), _card("二塁打", "int", b["d"]),
			_card("三塁打", "int", b["t"]), _card("本塁打", "int", b["hr"]), _card("打点", "int", b["rbi"]),
			_card("盗塁", "int", b["sb"]), _card("四球", "int", b["bb"]), _card("死球", "int", b["hbp"]),
			_card("三振", "int", b["so"]), _card("犠打", "int", b["sac"]), _card("犠飛", "int", b["sf"]),
			_card("併殺", "int", b["gdp"]), _card("失策", "int", b["err"]),
		]},
		{"title": "打撃指標", "cards": [
			_card("打率", "rate", b["avg"]), _card("出塁率", "rate", b["obp"]), _card("長打率", "rate", b["slg"]), _card("OPS", "rate", b["ops"]),
			_card("球/打席", "f2", a["ppa"]), _card("wOBA", "rate", a["woba"]), _card("xwOBA", "rate", a["xwoba"]),
			_card("wRC+", "f1", a["wrcplus"]), _card("RE24", "f1s", a["re24"]), _card("BSR", "f1s", a["bsr"]), _card("WAR", "f1s", a["war"]),
		]},
		{"title": "守備指標", "cards": [
			_card("OAA", "f1s", a["oaa"]), _card("OAA内", "f1s", a["oaa_if"]), _card("OAA外", "f1s", a["oaa_of"]),
			_card("RngR", "f1s", a["rngr"]), _card("ErrR", "f1s", a["errr"]), _card("DPR", "f1s", a["dpr"]),
			_card("UZR", "f1s", a["uzr"]), _card("DRS", "f1s", a["drs"]),
		]},
	]


func _pitcher_season_groups(b: Dictionary, a: Dictionary) -> Array:
	return [
		{"title": "投手成績", "cards": [
			_card("登板", "int", b["g"]), _card("先発", "int", b["gs"]), _card("救援", "int", b["rel"]),
			_card("投球回", "f1", b["ip"]), _card("防御率", "f2", b["era"]), _card("勝", "int", b["w"]),
			_card("敗", "int", b["l"]), _card("ホールド", "int", b["hld"]), _card("セーブ", "int", b["sv"]), _card("QS", "int", b["qs"]),
			_card("完投", "int", b["cg"]), _card("完封", "int", b["sho"]),
		]},
		{"title": "投手指標", "cards": [
			_card("WHIP", "f2", b["whip"]),
			_card("K/9", "f2", a["k9"]), _card("BB/9", "f2", a["bb9"]), _card("HR/9", "f2", a["hr9"]),
			_card("FIP", "f2", a["fip"]), _card("WAR", "f1s", a["war"]),
		]},
		{"title": "投球内容", "cards": [
			_card("奪三振", "int", b["so"]), _card("与四球", "int", b["bb"]), _card("与死球", "int", b["hbp"]),
			_card("被安打", "int", b["h"]), _card("被本塁打", "int", b["hra"]), _card("失点", "int", b["ra"]), _card("自責点", "int", b["er"]),
			_card("対戦打者", "int", a["bf"]), _card("投球数", "int", a["pit"]),
			_card("球/打者", "f2", a["ppbf"]), _card("球/回", "f1", a["ppi"]),
		]},
	]


func _pitcher_advanced_dict(record: PSPlayerSeasonRecord, war: Dictionary, team: String) -> Dictionary:
	var ps: PSPitcherStats = record.pitcher_stats
	var has_ip: bool = ps.outs_pitched > 0
	var ip: float = ps.innings_pitched()
	return {
		"year": "%d年" % record.year, "team": team,
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


func _batter_advanced_dict(record: PSPlayerSeasonRecord, war: Dictionary, team: String) -> Dictionary:
	var ad: PSAdvancedStats = record.advanced_stats
	var bs: PSBatterStats = record.batter_stats
	var has_pa: bool = ad != null and ad.plate_appearances > 0
	var ad_dict: Dictionary = ad.to_dict() if ad != null else {}
	var chances: int = int(ad_dict.get("fielding_chances", 0))
	var has_field: bool = chances > 0
	var field_val: Callable = func(key: String) -> Variant:
		return float(ad_dict.get(key, 0.0)) if has_field else "-"
	return {
		"year": "%d年" % record.year, "team": team,
		"pa": ad.plate_appearances if ad != null else 0,
		"ppa": (float(bs.pitches_seen) / float(bs.plate_appearances)) if bs.plate_appearances > 0 else "-",
		"woba": ad.woba() if has_pa else "-",
		"xwoba": ad.xwoba() if has_pa else "-",
		"wrcplus": ad.wrc_plus() if has_pa else "-",
		"re24": ad.re24_sum if has_pa else "-",
		"bsr": ad.bsr_sum if has_pa else "-",
		"war": float(war.get("war", 0.0)) if has_pa else "-",
		"chances": chances if has_field else "-",
		"oaa": field_val.call("oaa_total"),
		"oaa_if": field_val.call("oaa_infield"),
		"oaa_of": field_val.call("oaa_outfield"),
		"rngr": field_val.call("rngr"),
		"errr": field_val.call("errr"),
		"dpr": field_val.call("dpr"),
		"uzr": field_val.call("uzr"),
		"drs": field_val.call("drs"),
		"def_runs": field_val.call("def_runs"),
		"pos_adj": field_val.call("positional_adjustment_runs"),
	}


func _league_ctx_for(year: int, season_number: int) -> Dictionary:
	var key: String = "%d-%d" % [year, season_number]
	if not _war_ctx_cache.has(key):
		_war_ctx_cache[key] = WarCalculator.build_league_context(year, season_number)
	return _war_ctx_cache[key] as Dictionary


# ============================================================ helpers

func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.short_name if team != null else "-"


func _hand_name(value: String) -> String:
	match value:
		"L": return "左"
		"S": return "両"
		_: return "右"


func _role_or_position_short(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher():
		return _pitcher_role_label(record.role)
	return str(POS_SHORT.get(record.position, "?"))


func _identity_color(record: PSPlayerSeasonRecord) -> Color:
	return _pos_color(record.position if not record.is_pitcher() else 1)


func _pitcher_role_label(role: String) -> String:
	match role:
		"starter": return "先発"
		"reliever": return "中継"
		"closer": return "抑え"
		_: return "中継"


func _position_aptitude(record: PSPlayerSeasonRecord, pos: int) -> int:
	var key: String = str(POSITION_APTITUDE_KEYS.get(pos, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == pos else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))
