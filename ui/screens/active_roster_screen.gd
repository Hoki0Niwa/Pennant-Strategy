extends "res://ui/components/dashboard_screen.gd"

# 選手登録画面。dashboard_screen の chrome 上に、1軍/2軍/育成の3カラムとロスター集計を描く。
# 選手を選ぶと下段に能力・今季成績・登録制約を表示し、ドラッグ&ドロップまたは移動ボタンで入替する。
#
# 移動規則: 1軍↔2軍 はドラッグで昇格/降格。育成→(1軍/2軍 へドロップ)で支配下登録 (2軍へ着地)。
# 育成への降格は戦力外フェーズ専用なのでこの画面では行わない (project_development_player_system 参照)。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const ROSTER_MAX: int = 31
const FOREIGN_MAX: int = ForeignActiveRosterRules.TOTAL_MAX
const FOREIGN_TYPE_MAX: int = ForeignActiveRosterRules.TYPE_MAX
const TARGET_PITCHERS_MIN: int = 14
const TARGET_PITCHERS_MAX: int = 15
const MIN_CATCHERS: int = 2

# 役割色 (rotation_editor と統一: 先発=ピンク=基底 PINK / 中継=赤)。捕=青 / 内野=黄(AMBER) / 外野=緑。
# 守備位置の色は共有基底 dashboard_screen._pos_color を使う。

# --- レイアウト (base 1920x1080 座標) ---
const CARD_Y: float = 104.0
const CARD_H: float = 80.0
const FILTER_Y: float = 192.0    # ポジション絞り込みチップ列
const COL_TOP: float = 230.0
const COL_H: float = 494.0
const COL1: Rect2 = Rect2(262, COL_TOP, 478, COL_H)
const COL2: Rect2 = Rect2(826, COL_TOP, 478, COL_H)
const COL3: Rect2 = Rect2(1390, COL_TOP, 510, COL_H)
# 育成カラム下部に支配下登録ボタンを置くため、育成リストはこの分だけ短くする。
const DEV_BUTTON_RESERVE: float = 48.0

# ポジション絞り込み: 0=全 / 1=投 / 2..9=守備位置 (サブポジ適性も含めて判定)。label は表示名のキー (Loc)。
const FILTER_DEFS: Array = [
	{"pos": 0, "label": "filter.all"},
	{"pos": 1, "label": "position_short.pitcher"},
	{"pos": 2, "label": "position_short.catcher"},
	{"pos": 3, "label": "position_short.first_base"},
	{"pos": 4, "label": "position_short.second_base"},
	{"pos": 5, "label": "position_short.third_base"},
	{"pos": 6, "label": "position_short.shortstop"},
	{"pos": 7, "label": "position_short.left_field"},
	{"pos": 8, "label": "position_short.center_field"},
	{"pos": 9, "label": "position_short.right_field"},
]

# 下段の選択選手サマリ。上 = プロフィール・評価・能力/適性の1行表、下 = 一軍/二軍/直近の3行比較表。
const DETAIL_TOP: Rect2 = Rect2(262, 740, 1638, 128)
const DETAIL_STATS: Rect2 = Rect2(262, 876, 1638, 180)
const DETAIL_TOP_ROW_H: float = 36.0
const DETAIL_STATS_ROW_H: float = 30.0
const RECENT_WINDOW_DAYS: int = 14

const ROW_H: float = 27.0
const LIST_CELL_SIZE: int = 13

# 並べ替え可能な一覧の列キー。
const SORT_KEYS: Array = ["role", "age", "war", "eval"]

# 投手の球種カラムの短縮ラベル (Loc キー)。
const PITCH_SHORT: Dictionary = {
	"four_seam": "pitch_short.four_seam", "two_seam": "pitch_short.two_seam", "sinker": "pitch_short.sinker",
	"cutter": "pitch_short.cutter", "slider": "pitch_short.slider", "curve": "pitch_short.curve",
	"fork": "pitch_short.fork", "changeup": "pitch_short.changeup",
}
# 野手の守備適性カラム (守備位置番号 -> 行キー)。
const APTITUDE_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9]

var _team_id: int = 0
var _all_records: Array = []          # 育成を除く記録持ち選手 (PSPlayerSeasonRecord)
var _development_players: Array = []   # 当チーム育成選手 (PSPlayer)
var _active_ids: Dictionary = {}       # {player_id: true}
var _selected_id: int = 0
var _selected_list: String = ""        # "active" / "inactive" / "dev"
var _status_text: String = ""
var _status_is_error: bool = false

# ソート状態 (区分 / 年齢 / WAR / 評価)
var _sort_key: String = "role"
var _sort_asc: bool = true
var _header_hits: Array = []

# 投手の区分 (先発/中継) を投手起用法と一致させるための分類元。
# _rotation_set = 先発ローテ入りの投手 id (保存ローテ or preview)。クローザーは中継の一種として扱う。
var _rotation_set: Dictionary = {}

# 育成→支配下登録は保存まで確定しない (リセットで取り消せる)。{player_id: true}。
var _pending_controlled: Dictionary = {}

# 列ごとのスクロールオフセット (行数)。
var _scroll: Dictionary = {"active": 0, "inactive": 0, "dev": 0}

# player_id -> season_war 結果 dict (シーズン文脈で1回計算しキャッシュ)。
var _war_by_id: Dictionary = {}

# ポジション絞り込み状態 (0=全) と チップボタン {pos: Button}。
var _filter_pos: int = 0
var _filter_buttons: Dictionary = {}

# 行ヒット (selection / drag 用)。{rect, id, list, name}
var _row_hits: Array = []
var _hover_id: int = 0

# ドラッグ状態
var _pending: Dictionary = {}          # 押下時の候補 {id, list, name, start}
var _drag_active: bool = false
var _drag_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	_init_chrome()
	_build_chrome_buttons()
	_load_initial_state()
	_layout_buttons()
	queue_redraw()


# ============================================================ input (drag & drop)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_update_transform()
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_on_press(_to_base(event.position))
				else:
					_on_release(_to_base(event.position))
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_scroll_at(_to_base(event.position), -1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_scroll_at(_to_base(event.position), 1)
	elif event is InputEventMouseMotion:
		_update_transform()
		if not _pending.is_empty():
			if not _drag_active and event.position.distance_to(_p(_pending["start"] as Vector2)) > 8.0:
				_drag_active = true
			if _drag_active:
				_drag_pos = event.position
				queue_redraw()
		else:
			var hit: Dictionary = _row_at(_to_base(event.position))
			var id: int = int(hit.get("id", 0))
			if id != _hover_id:
				_hover_id = id
				queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


# リサイズ時のボタン再配置 (基底と同等) に加え、自動入替チップの状態色を再適用する。
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_buttons()
		_refresh_filter_buttons()
		queue_redraw()


func _on_press(base_pos: Vector2) -> void:
	for hit_value in _header_hits:
		var hit_h: Dictionary = hit_value as Dictionary
		if (hit_h["rect"] as Rect2).has_point(base_pos):
			_on_header_clicked(str(hit_h["key"]))
			return
	var hit: Dictionary = _row_at(base_pos)
	if hit.is_empty():
		return
	_selected_id = int(hit["id"])
	_selected_list = str(hit["list"])
	_pending = {"id": _selected_id, "list": _selected_list, "name": str(hit["name"]), "start": base_pos}
	_drag_pos = _p(base_pos)
	queue_redraw()


func _on_header_clicked(key: String) -> void:
	if _sort_key == key:
		_sort_asc = not _sort_asc
	else:
		_sort_key = key
		_sort_asc = (key in ["role", "age"])
	queue_redraw()


func _on_release(base_pos: Vector2) -> void:
	if _drag_active and not _pending.is_empty():
		_finish_drag(base_pos)
	_pending = {}
	_drag_active = false
	queue_redraw()


func _finish_drag(base_pos: Vector2) -> void:
	var src: String = str(_pending["list"])
	var id: int = int(_pending["id"])
	var dst: String = _drop_zone_at(base_pos)
	if dst.is_empty() or dst == src:
		return
	if src == "active" and dst == "inactive":
		_demote(id)
	elif src == "inactive" and dst == "active":
		_promote(id)
	elif src == "dev" and (dst == "active" or dst == "inactive"):
		_promote_to_controlled(id)
	else:
		_set_status(Loc.t("roster.invalid_move"), true)


func _drop_zone_at(base_pos: Vector2) -> String:
	if COL1.has_point(base_pos):
		return "active"
	if COL2.has_point(base_pos):
		return "inactive"
	if COL3.has_point(base_pos):
		return "dev"
	return ""


func _row_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit
	return {}


func _scroll_at(base_pos: Vector2, delta: int) -> void:
	var zone: String = _drop_zone_at(base_pos)
	if zone.is_empty():
		return
	_scroll[zone] = max(0, int(_scroll[zone]) + delta)
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var team: PSTeam = GameDb.get_team(_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text(Loc.t("sim.error.no_team"), Vector2(770, 496), 20, MUTED)
		return

	_draw_shell(Loc.t("screen.active_roster"), team, season)

	var summary: Dictionary = _compute_stats()
	_draw_stat_cards(summary)
	# ポジション絞り込みチップ列の補足ラベル (チップ本体はオーバーレイボタン)。
	_text(Loc.t("roster.filter_hint"), Vector2(INNER_L + float(FILTER_DEFS.size()) * 50.0 + 8.0, FILTER_Y + 21), 12, FAINT)
	_draw_columns()
	_draw_detail_panels(summary)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1074), 13, RED if _status_is_error else MUTED)

	_draw_drag_ghost()


# --- 集計帯 ---

func _draw_stat_cards(s: Dictionary) -> void:
	var total: int = int(s["total"])
	var pitchers: int = int(s["pitchers"])
	var fielders: int = int(s["fielders"])
	var catchers: int = int(s["catchers"])
	var foreigners: int = int(s["foreigners"])
	var foreign_pitchers: int = int(s["foreign_pitchers"])
	var foreign_fielders: int = int(s["foreign_fielders"])

	var total_color: Color = RED if total > ROSTER_MAX else (AMBER if total == ROSTER_MAX else GREEN)
	var pit_color: Color = AMBER if pitchers < TARGET_PITCHERS_MIN or pitchers > TARGET_PITCHERS_MAX else GREEN
	var c_color: Color = RED if catchers < MIN_CATCHERS else GREEN
	var foreign_counts: Dictionary = {
		"foreigners": foreigners,
		"foreign_pitchers": foreign_pitchers,
		"foreign_fielders": foreign_fielders,
	}
	var f_color: Color = RED if not ForeignActiveRosterRules.is_within_limits(foreign_counts) else TEXT

	var cells: Array = [
		{"label": Loc.t("roster.first_team"), "value": "%d/%d" % [total, ROSTER_MAX], "color": total_color},
		{"label": Loc.t("common.pitcher"), "value": str(pitchers), "color": pit_color,
			"note": Loc.t("roster.pitchers_note", {"starters": int(s["starters"]), "middle": int(s["middle"])})},
		{"label": Loc.t("common.fielder"), "value": str(fielders),
			"note": Loc.t("roster.fielders_note", {"c": catchers, "inf": int(s["infield"]), "of": int(s["outfield"])})},
		{"label": Loc.t("position.catcher"), "value": str(catchers), "color": c_color, "note": Loc.t("roster.catchers_note", {"min": MIN_CATCHERS})},
		{"label": Loc.t("roster.foreign"), "value": "%d/%d" % [foreigners, FOREIGN_MAX], "color": f_color,
			"note": Loc.t("roster.foreign_note", {"p": foreign_pitchers, "f": foreign_fielders, "max": FOREIGN_TYPE_MAX})},
		{"label": Loc.t("common.controlled"), "value": "%d/%d" % [int(s["controlled"]), TeamFinance.CONTROLLED_LIMIT]},
		{"label": Loc.t("common.development_chip"), "value": str(int(s["development"])), "color": GREEN},
	]
	_stat_strip(Rect2(INNER_L, CARD_Y, INNER_R - INNER_L, CARD_H), cells)


# --- 3 カラム ---

func _draw_columns() -> void:
	var active_rows: Array = []
	var inactive_rows: Array = []
	var dev_id_set: Dictionary = {}
	for dev_row in _development_players:
		dev_id_set[(dev_row as PSPlayer).id] = true

	for record_row in _all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if dev_id_set.has(record.player_id):
			continue
		if not _record_passes_filter(record):
			continue
		if _active_ids.has(record.player_id):
			active_rows.append(_record_row(record))
		else:
			inactive_rows.append(_record_row(record))

	var dev_rows: Array = []
	for dev_row in _development_players:
		var dev_player: PSPlayer = dev_row as PSPlayer
		if _player_passes_filter(dev_player):
			dev_rows.append(_dev_row(dev_player))

	_header_hits = []
	var sort_rows: Callable = func(a: Variant, b: Variant) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		match _sort_key:
			"role":
				if int(da["order"]) != int(db["order"]):
					return (int(da["order"]) < int(db["order"])) if _sort_asc else (int(da["order"]) > int(db["order"]))
				return int(da["eval"]) > int(db["eval"])
			"age":
				if int(da["age"]) != int(db["age"]):
					return (int(da["age"]) < int(db["age"])) if _sort_asc else (int(da["age"]) > int(db["age"]))
				return int(da["eval"]) > int(db["eval"])
			"war":
				var wa: float = float(da.get("war_sort", 0.0))
				var wb: float = float(db.get("war_sort", 0.0))
				if wa != wb:
					return (wa < wb) if _sort_asc else (wa > wb)
				return int(da["eval"]) > int(db["eval"])
			"eval":
				if int(da["eval"]) != int(db["eval"]):
					return (int(da["eval"]) < int(db["eval"])) if _sort_asc else (int(da["eval"]) > int(db["eval"]))
				return int(da["order"]) < int(db["order"])
			_:
				return int(da["order"]) < int(db["order"])
	active_rows.sort_custom(sort_rows)
	inactive_rows.sort_custom(sort_rows)
	dev_rows.sort_custom(sort_rows)

	_row_hits = []
	_draw_column(COL1, Loc.t("roster.first_team"), "%d/%d" % [active_rows.size(), ROSTER_MAX], active_rows, "active", 0.0)
	_draw_column(COL2, Loc.t("roster.second_team"), Loc.t("common.people_value", {"n": inactive_rows.size()}), inactive_rows, "inactive", 0.0)
	_draw_column(COL3, Loc.t("common.development_chip"), Loc.t("common.people_value", {"n": dev_rows.size()}), dev_rows, "dev", DEV_BUTTON_RESERVE)


func _draw_column(panel: Rect2, title: String, count_text: String, rows: Array, list_key: String, reserve_bottom: float) -> void:
	var is_target: bool = _drag_active and not _pending.is_empty() \
		and _drop_zone_at(_to_base(_drag_pos)) == list_key and _is_valid_drop(str(_pending["list"]), list_key)
	var cols: Array = _list_columns()
	var hits: Array = []
	var names_by_id: Dictionary = {}
	for row_value in rows:
		var list_row: Dictionary = row_value as Dictionary
		names_by_id[int(list_row["id"])] = str(list_row["name"])
	var opts: Dictionary = {
		"title": title,
		"right_label": count_text,
		"row_h": ROW_H,
		"cell_size": LIST_CELL_SIZE,
		"bottom_pad": 8.0 + reserve_bottom,
		"sort_key": _sort_key,
		"sort_asc": _sort_asc,
		"scroll_key": list_key,
		"scroll": _scroll,
		# 下端にボタンを置くカラム (育成) は件数表示がボタンに隠れるので出さない。
		"scroll_label": reserve_bottom <= 0.0,
		"sel_kind": "roster",
		"selected_id": _selected_id,
		"hover_id": _hover_id,
		"hits": hits,
		"empty_text": Loc.t("common.no_matching_players"),
	}
	_draw_data_table(panel, cols, rows, opts)
	# 枠線はドロップ先として有効な時だけ (通常時はフラット、意味のある時だけ縁取る)。
	if is_target:
		_round(panel, Color.TRANSPARENT, BLUE, 8, 2)

	# 当たり判定は表の描画と同一の幾何 (hits) をそのまま選択/ドラッグ用に写す。
	for hit_value in hits:
		var hit: Dictionary = hit_value as Dictionary
		var hit_id: int = int(hit["meta"])
		_row_hits.append({"rect": hit["rect"], "id": hit_id, "list": list_key, "name": str(names_by_id.get(hit_id, ""))})
	var header_hits: Array = []
	_build_table_header_hits(header_hits, panel, cols, opts)
	for header_value in header_hits:
		var header_hit: Dictionary = header_value as Dictionary
		if SORT_KEYS.has(str(header_hit["key"])):
			_header_hits.append(header_hit)


# 上段3カラム共通の列。プロフィール(区分/#背番号 選手名/齢/投打) | 状態・評価(疲労/備考/総合/WAR) | 主要成績(試・登/率・防)。
func _list_columns() -> Array:
	return [
		{"title": "roster.col.category", "key": "role", "w": 38, "align": "c", "fmt": "pos_badge", "group": "group.profile"},
		{"title": "col.player", "key": "name", "w": 110, "align": "l", "fmt": "player_name", "strong": true, "group": "group.profile"},
		{"title": "col.age", "key": "age", "w": 28, "align": "c", "fmt": "int", "group": "group.profile"},
		{"title": "roster.col.hand", "key": "hand", "w": 30, "align": "c", "fmt": "str", "group": "group.profile"},
		{"title": "col.fatigue", "key": "fatigue", "w": 46, "align": "c", "fmt": "fatigue_dot", "sep_before": true, "group": "roster.group.condition_eval"},
		{"title": "roster.col.note", "key": "note", "w": 60, "align": "l", "fmt": "str", "group": "roster.group.condition_eval"},
		{"title": "col.overall", "key": "eval", "w": 40, "align": "c", "fmt": "eval_badge", "group": "roster.group.condition_eval"},
		{"title": "WAR", "key": "war", "w": 42, "align": "r", "fmt": "f1s", "strong": true, "group": "roster.group.condition_eval"},
		{"title": "roster.col.games_app", "key": "games", "w": 40, "align": "r", "fmt": "int", "sep_before": true, "group": "roster.group.main_stats"},
		{"title": "roster.col.rate_era", "key": "rate", "w": 40, "align": "r", "fmt": "str", "group": "roster.group.main_stats"},
	]


# --- 下段パネル ---

func _draw_detail_panels(_summary: Dictionary) -> void:
	var player: PSPlayer = GameDb.get_player(_selected_id)
	if player == null:
		_draw_data_table(DETAIL_TOP, [], [], {"title": Loc.t("screen.player_detail"), "empty_text": Loc.t("roster.select_player")})
		return
	var record: PSPlayerSeasonRecord = _find_record(_selected_id)
	# 育成など今季の記録が無い選手も、能力表示は player から作った一時 record で同じ経路に流す。
	var view_record: PSPlayerSeasonRecord = record if record != null else PSPlayerSeasonRecord.from_player(player, 0, 0)
	_draw_player_summary_table(player, record, view_record)
	_draw_stat_compare_table(record)


# 上段: 選択選手のプロフィール・評価ピル・能力 3px バー・守備適性/球種バーを 1 行で。
@warning_ignore("incompatible_ternary")
func _draw_player_summary_table(player: PSPlayer, record: PSPlayerSeasonRecord, view_record: PSPlayerSeasonRecord) -> void:
	var pitcher: bool = player.is_pitcher()
	var chip: Dictionary = _classify(player.id, pitcher, player.role, player.position, _active_ids.has(player.id))
	var roster_text: String = Loc.t("common.development_chip") if player.development_player \
		else (Loc.t("roster.first_team") if _active_ids.has(player.id) else Loc.t("roster.second_team"))
	var fatigue_pct: int = _fatigue_pct(player.fatigue)
	var row: Dictionary = {
		"role": chip["text"], "role_color": chip["color"], "role_dev": player.development_player,
		"roster": roster_text,
		"name": player.name, "jersey": player.jersey_number,
		"age": player.age,
		"hand": _hand_name(player.throwing_hand) + _hand_name(player.batting_side),
		"bio": Loc.t("player.height_weight", {"height": player.height, "weight": player.weight}),
		"salary": _format_money(player.salary),
		"overall": PlayerValueEvaluator.overall_score(record) if record != null else int(Offseason.player_value_score(player)),
		"fatigue": fatigue_pct,
		"injury": "",
	}
	if player.injury_days > 0:
		row["injury"] = Loc.t("roster.injury_detail", {"days": player.injury_days, "label": PSInjuryModel.display_label(player.injury_type, player.injury_severity, player.injury_days)})
		row["injury_color"] = RED
	else:
		row["injury"] = Loc.t("common.none")
		row["injury_color"] = MUTED

	var cols: Array = [
		{"title": "roster.col.category", "key": "role", "w": 44, "align": "c", "fmt": "pos_badge", "group": "group.profile"},
		{"title": "col.roster_status", "key": "roster", "w": 48, "align": "c", "fmt": "roster_chip", "group": "group.profile"},
		{"title": "col.player", "key": "name", "w": 150, "align": "l", "fmt": "player_name", "strong": true, "group": "group.profile"},
		{"title": "col.age", "key": "age", "w": 40, "align": "c", "fmt": "int", "group": "group.profile"},
		{"title": "roster.col.hand", "key": "hand", "w": 44, "align": "c", "fmt": "str", "group": "group.profile"},
		{"title": "roster.col.body", "key": "bio", "w": 120, "align": "l", "fmt": "str", "group": "group.profile"},
		{"title": "col.salary", "key": "salary", "w": 90, "align": "r", "fmt": "str", "group": "group.profile"},
		{"title": "col.overall", "key": "overall", "w": 50, "align": "c", "fmt": "eval_badge", "sep_before": true, "group": "roster.group.condition_eval"},
		{"title": "col.fatigue", "key": "fatigue", "w": 64, "align": "c", "fmt": "fatigue_dot", "group": "roster.group.condition_eval"},
		{"title": "roster.injury", "key": "injury", "w": 130, "align": "l", "fmt": "str", "group": "roster.group.condition_eval"},
	]
	var ratings: Array = PlayerVisibleRatings.ratings_for_record(view_record).get("display_ratings", []) as Array
	var ability_group: String = "group.pitcher_abilities" if pitcher else "group.fielder_abilities"
	var first_ability: bool = true
	for rating_value in ratings:
		var rating: Dictionary = rating_value as Dictionary
		# 倍率表示 (対逆) は 1-100 の能力値ではないのでバーを持たない。整形済み text の行は表に出さない。
		if rating.has("text"):
			continue
		var rating_key: String = str(rating.get("key", ""))
		var is_velocity: bool = rating_key == "velocity"
		if is_velocity:
			row[rating_key] = "%d%s" % [int(rating.get("display_value", 0)), str(rating.get("suffix", ""))]
		else:
			row[rating_key] = int(rating.get("display_value", 0))
		cols.append({"title": str(rating.get("label", "")), "key": rating_key, "w": 62 if is_velocity else 52, "align": "c",
			"fmt": "str" if is_velocity else "ability_bar", "sep_before": first_ability, "group": ability_group})
		first_ability = false
	if pitcher:
		var mastery_by_type: Dictionary = {}
		for entry_value in view_record.arsenal_or_derived():
			var entry: Dictionary = entry_value as Dictionary
			mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
		var first_pitch: bool = true
		for type_key in PSPitchTypes.ALL_TYPES:
			if not mastery_by_type.has(type_key):
				continue
			row["pitch_%s" % type_key] = PSAbilityScale.z_to_display(float(mastery_by_type[type_key]))
			cols.append({"title": str(PITCH_SHORT.get(type_key, type_key)), "key": "pitch_%s" % type_key, "w": 52, "align": "c",
				"fmt": "ability_bar", "sep_before": first_pitch, "group": ability_group})
			first_pitch = false
	else:
		for pos in APTITUDE_POSITIONS:
			var apt: int = TeamSetupBuilder.position_aptitude(view_record, pos)
			row["apt_%d" % pos] = apt if apt > 0 else "-"
			cols.append({"title": str(PSPlayer.POSITION_SHORT_KEYS[pos]), "key": "apt_%d" % pos, "w": 40, "align": "c",
				"fmt": "ability_bar", "sep_before": pos == APTITUDE_POSITIONS[0], "group": "group.aptitudes"})

	_draw_data_table(DETAIL_TOP, cols, [row], {
		"title": Loc.t("screen.player_detail"),
		"row_h": DETAIL_TOP_ROW_H,
		"cell_size": LIST_CELL_SIZE,
		"bottom_pad": 4.0,
	})


# 下段: 一軍成績 / 二軍成績 / 直近 RECENT_WINDOW_DAYS 日 の 3 行比較表。
# 二軍成績は farm_* コンテナからのみ読み、一軍成績とは混ぜない。
@warning_ignore("incompatible_ternary")
func _draw_stat_compare_table(record: PSPlayerSeasonRecord) -> void:
	var title: String = Loc.t("roster.season_stats")
	if record == null:
		_draw_data_table(DETAIL_STATS, [], [], {"title": title, "empty_text": Loc.t("roster.no_appearances")})
		return
	var pitcher: bool = record.is_pitcher()
	var war: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	var recent: Dictionary = _recent_window_stats(record)
	var rows: Array
	if pitcher:
		var played: bool = record.pitcher_stats.outs_pitched > 0
		rows = [
			_pitcher_compare_row(Loc.t("roster.compare.first_team"), record.pitcher_stats, ("%0.2f" % float(war.get("fip", 0.0))) if played and war.has("fip") else "-", float(war.get("war", 0.0)) if played else "-"),
			_pitcher_compare_row(Loc.t("roster.compare.second_team"), record.farm_pitcher_stats, "-", "-"),
			_pitcher_compare_row(Loc.t("roster.compare.recent", {"days": RECENT_WINDOW_DAYS}), recent["pitcher"] as PSPitcherStats, "-", "-"),
		]
	else:
		var ad: PSAdvancedStats = record.advanced_stats
		var played_b: bool = ad != null and ad.plate_appearances > 0
		var farm_ad: PSAdvancedStats = record.farm_advanced_stats
		var farm_played: bool = farm_ad != null and farm_ad.plate_appearances > 0
		rows = [
			_batter_compare_row(Loc.t("roster.compare.first_team"), record.batter_stats, ad.woba() if played_b else "-", float(war.get("war", 0.0)) if played_b else "-"),
			_batter_compare_row(Loc.t("roster.compare.second_team"), record.farm_batter_stats, farm_ad.woba() if farm_played else "-", "-"),
			_batter_compare_row(Loc.t("roster.compare.recent", {"days": RECENT_WINDOW_DAYS}), recent["batter"] as PSBatterStats, "-", "-"),
		]
	_draw_data_table(DETAIL_STATS, _compare_columns(pitcher), rows, {
		"title": title,
		"row_h": DETAIL_STATS_ROW_H,
		"cell_size": LIST_CELL_SIZE,
		"bottom_pad": 4.0,
	})


func _compare_columns(pitcher: bool) -> Array:
	var cols: Array = [
		{"title": "roster.col.category", "key": "label", "w": 120, "align": "l", "fmt": "str", "strong": true, "group": "roster.group.compare"},
	]
	if pitcher:
		cols.append_array([
			{"title": "col.appearances", "key": "g", "w": 56, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_app"},
			{"title": "col.games_started", "key": "gs", "w": 56, "align": "r", "fmt": "int", "group": "group.pitching_app"},
			{"title": "col.innings", "key": "ip", "w": 66, "align": "r", "fmt": "str", "group": "group.pitching_app"},
			{"title": "col.wins", "key": "w", "w": 50, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_dec"},
			{"title": "col.losses", "key": "l", "w": 50, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
			{"title": "stat.saves", "key": "sv", "w": 56, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
			{"title": "stat.holds", "key": "hld", "w": 56, "align": "r", "fmt": "int", "group": "group.pitching_dec"},
			{"title": "stat.era", "key": "era", "w": 62, "align": "r", "fmt": "f2", "strong": true, "sep_before": true, "group": "group.pitching_rates"},
			{"title": "WHIP", "key": "whip", "w": 56, "align": "r", "fmt": "f2", "group": "group.pitching_rates"},
			{"title": "K/9", "key": "k9", "w": 56, "align": "r", "fmt": "f2", "group": "group.pitching_rates"},
			{"title": "stat.strikeouts", "key": "so", "w": 56, "align": "r", "fmt": "int", "sep_before": true, "group": "group.pitching_detail"},
			{"title": "col.walks_allowed", "key": "bb", "w": 56, "align": "r", "fmt": "int", "group": "group.pitching_detail"},
			{"title": "FIP", "key": "fip", "w": 56, "align": "r", "fmt": "str", "sep_before": true, "group": "group.eval"},
			{"title": "WAR", "key": "war", "w": 56, "align": "r", "fmt": "f1s", "strong": true, "group": "group.eval"},
		])
	else:
		cols.append_array([
			{"title": "col.games", "key": "g", "w": 56, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_counting1"},
			{"title": "col.pa", "key": "pa", "w": 56, "align": "r", "fmt": "int", "group": "group.batting_counting1"},
			{"title": "stat.hits", "key": "h", "w": 52, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_counting2"},
			{"title": "stat.home_runs", "key": "hr", "w": 56, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
			{"title": "stat.rbi", "key": "rbi", "w": 52, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
			{"title": "stat.stolen_bases", "key": "sb", "w": 52, "align": "r", "fmt": "int", "group": "group.batting_counting2"},
			{"title": "stat.avg", "key": "avg", "w": 62, "align": "r", "fmt": "rate", "strong": true, "sep_before": true, "group": "group.batting_rates"},
			{"title": "stat.obp", "key": "obp", "w": 62, "align": "r", "fmt": "rate", "group": "group.batting_rates"},
			{"title": "OPS", "key": "ops", "w": 62, "align": "r", "fmt": "rate", "strong": true, "group": "group.batting_rates"},
			{"title": "wOBA", "key": "woba", "w": 62, "align": "r", "fmt": "rate", "group": "group.batting_rates"},
			{"title": "col.walks", "key": "bb", "w": 52, "align": "r", "fmt": "int", "sep_before": true, "group": "group.batting_discipline"},
			{"title": "col.strikeouts_batter", "key": "so", "w": 52, "align": "r", "fmt": "int", "group": "group.batting_discipline"},
			{"title": "WAR", "key": "war", "w": 56, "align": "r", "fmt": "f1s", "strong": true, "sep_before": true, "group": "group.eval"},
		])
	return cols


@warning_ignore("incompatible_ternary")
func _batter_compare_row(label: String, bs: PSBatterStats, woba: Variant, war_value: Variant) -> Dictionary:
	var has_ab: bool = bs.at_bats > 0
	return {
		"label": label,
		"g": bs.games, "pa": bs.plate_appearances, "h": bs.hits, "hr": bs.home_runs,
		"rbi": bs.runs_batted_in, "sb": bs.stolen_bases,
		"avg": bs.batting_average() if has_ab else "-",
		"obp": bs.on_base_percentage() if bs.plate_appearances > 0 else "-",
		"ops": bs.ops() if has_ab else "-",
		"woba": woba,
		"bb": bs.walks, "so": bs.strikeouts,
		"war": war_value,
	}


@warning_ignore("incompatible_ternary")
func _pitcher_compare_row(label: String, ps: PSPitcherStats, fip: Variant, war_value: Variant) -> Dictionary:
	var thrown: bool = ps.outs_pitched > 0
	return {
		"label": label,
		"g": ps.games, "gs": ps.starts, "ip": _ip_str(ps),
		"w": ps.wins, "l": ps.losses, "sv": ps.saves, "hld": ps.holds,
		"era": ps.era() if thrown else "-",
		"whip": ps.whip() if thrown else "-",
		"k9": ps.strikeouts_per_nine() if thrown else "-",
		"so": ps.strikeouts, "bb": ps.walks,
		"fip": fip,
		"war": war_value,
	}


# 直近 RECENT_WINDOW_DAYS 日のスナップショット差分 ({batter, pitcher})。高度指標は窓別に持てないので基本成績のみ。
func _recent_window_stats(record: PSPlayerSeasonRecord) -> Dictionary:
	var snap: Dictionary = {}
	var season: PSSeason = AppState.current_season
	if season != null:
		snap = season.get_player_stat_snapshot_at_or_before(record.player_id, season.current_day - RECENT_WINDOW_DAYS)
	# ベースライン無し (序盤等) はシーズン頭からの累計を窓とみなす。
	var base_b: PSBatterStats = PSBatterStats.from_dict(snap.get("batter", {}) as Dictionary) if not snap.is_empty() else PSBatterStats.new()
	var base_p: PSPitcherStats = PSPitcherStats.from_dict(snap.get("pitcher", {}) as Dictionary) if not snap.is_empty() else PSPitcherStats.new()
	return {
		"batter": record.batter_stats.subtract_from(base_b),
		"pitcher": record.pitcher_stats.subtract_from(base_p),
	}


func _draw_drag_ghost() -> void:
	if not _drag_active or _pending.is_empty():
		return
	var w: float = 200.0 * _scale_f
	var h: float = 28.0 * _scale_f
	var pos: Vector2 = _drag_pos + Vector2(14.0 * _scale_f, -h * 0.5)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.92)
	style.set_corner_radius_all(int(7.0 * _scale_f))
	draw_style_box(style, Rect2(pos, Vector2(w, h)))
	draw_string(_font, pos + Vector2(12.0 * _scale_f, h * 0.66), str(_pending["name"]),
		HORIZONTAL_ALIGNMENT_LEFT, w - 20.0 * _scale_f, max(9, int(round(13.0 * _scale_f))), TEXT)


# ============================================================ chrome buttons

func _build_chrome_buttons() -> void:
	_build_nav_buttons()
	# 右上ボタンは投手起用法 (rotation_editor) と同一構成・同位置。
	_add_button("auto", Loc.t("common.auto_arrange"), Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", Loc.t("common.reset"), Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", Loc.t("common.save"), Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")

	# ポジション絞り込みチップ列。
	_filter_buttons = {}
	var fx: float = INNER_L
	for def_value in FILTER_DEFS:
		var def: Dictionary = def_value as Dictionary
		var pos: int = int(def["pos"])
		var btn: Button = _add_button("filter_%d" % pos, Loc.t(str(def["label"])), Rect2(fx, FILTER_Y, 44, 30),
			func(p: int = pos) -> void: _set_filter(p),
			"chip_active" if pos == _filter_pos else "chip")
		_filter_buttons[pos] = btn
		fx += 50.0

	# 1軍↔2軍 の移動ボタン (ガター中央)。
	var g1: float = (COL1.end.x + COL2.position.x) * 0.5
	_add_button("demote", Loc.t("roster.demote_button"), Rect2(g1 - 40, COL_TOP + COL_H * 0.5 - 40, 80, 36), _on_demote_pressed, "action")
	_add_button("promote", Loc.t("roster.promote_button"), Rect2(g1 - 40, COL_TOP + COL_H * 0.5 + 4, 80, 36), _on_promote_pressed, "action")
	# 支配下登録は育成カラム枠内の下部に置く。
	_add_button("register", Loc.t("roster.register_button"), Rect2(COL3.position.x + 16, COL3.end.y - 40, COL3.size.x - 32, 32), _on_register_pressed, "primary")


# ============================================================ data load

func _load_initial_state() -> void:
	var season: PSSeason = AppState.current_season
	_team_id = AppState.selected_team_id
	if season == null or _team_id <= 0:
		_set_status(Loc.t("sim.error.no_team"), true)
		queue_redraw()
		return
	var team: PSTeam = GameDb.get_team(_team_id)
	if team == null:
		_set_status(Loc.t("error.team_not_found"), true)
		queue_redraw()
		return

	_pending_controlled = {}
	_all_records = RecordStore.get_team_player_records(_team_id, season.year, season.season_number)

	# WAR はリーグ文脈が要るので season ごとに1回計算してキャッシュ (rotation_editor と同方式)。
	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	_war_by_id = {}
	for record_row in _all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		_war_by_id[record.player_id] = WarCalculator.season_war(record, ctx)

	_load_rotation_classification(season)

	_development_players = []
	for player_row in GameDb.players:
		var dev: PSPlayer = player_row as PSPlayer
		if dev == null or dev.team_id != _team_id or dev.is_retired():
			continue
		if dev.development_player:
			_development_players.append(dev)

	_active_ids = {}
	var saved: Dictionary = season.get_active_roster(_team_id)
	var initial_ids: Array = []
	if saved.is_empty():
		var preview: Dictionary = GameSimulator.preview_active_roster(season, _team_id)
		if not bool(preview.get("ok", false)):
			_set_status(Loc.t("common.auto_arrange_failed", {"reason": str(preview.get("message", ""))}), true)
			queue_redraw()
			return
		initial_ids = preview.get("player_ids", []) as Array
		_set_status(Loc.t("roster.status.no_saved"), false)
	else:
		initial_ids = saved.get("player_ids", []) as Array
		_set_status(Loc.t("roster.status.showing_saved", {"day": SeasonCalendar.day_status_label(season, int(saved.get("updated_at_day", 0)))}), false)
	for id_value in initial_ids:
		_active_ids[int(id_value)] = true

	if _selected_id <= 0 or _find_record(_selected_id) == null:
		_selected_id = int(initial_ids[0]) if not initial_ids.is_empty() else 0
		_selected_list = "active"
	queue_redraw()


# ============================================================ operations

func _demote(player_id: int) -> void:
	if not _active_ids.has(player_id):
		return
	var record: PSPlayerSeasonRecord = _find_record(player_id)
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	if _is_catcher(record) and int(summary.get("catchers", 0)) <= MIN_CATCHERS:
		_set_status(Loc.t("roster.error.min_catchers", {"min": MIN_CATCHERS}), true)
		return
	_active_ids.erase(player_id)
	_set_status(Loc.t("roster.status.demoted", {"player": record.name if record != null else ""}), false)
	queue_redraw()


func _promote(player_id: int) -> void:
	if _active_ids.has(player_id):
		return
	var record: PSPlayerSeasonRecord = _find_record(player_id)
	if record == null:
		return
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	if int(summary.get("total", 0)) >= ROSTER_MAX:
		_set_status(Loc.t("roster.error.max_active", {"max": ROSTER_MAX}), true)
		return
	var foreign_block: String = ForeignActiveRosterRules.add_block_message(summary, record)
	if not foreign_block.is_empty():
		_set_status(foreign_block, true)
		return
	_active_ids[player_id] = true
	_set_status(Loc.t("roster.status.promoted", {"player": record.name}), false)
	queue_redraw()


# 育成 → 支配下 登録 (2軍へ着地)。**保存まで確定しない** (リセットで取り消せる)。
# 即時には live player を変えず、表示上だけ育成リストから 2軍へ移す。確定は _on_save_pressed。
func _promote_to_controlled(player_id: int) -> void:
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null or not player.development_player or player.team_id != _team_id:
		return
	if _pending_controlled.has(player_id):
		return
	if _effective_controlled_count() >= TeamFinance.CONTROLLED_LIMIT:
		_set_status(Loc.t("roster.error.controlled_full", {"max": TeamFinance.CONTROLLED_LIMIT}), true)
		return
	_pending_controlled[player_id] = true
	_development_players.erase(player)
	# 2軍に表示するため記録を確保 (新人で記録未生成なら player から生成)。
	var season: PSSeason = AppState.current_season
	if _find_record(player_id) == null and season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
		_all_records.append(record if record != null else PSPlayerSeasonRecord.from_player(player, season.year, season.season_number))
	_selected_id = player_id
	_selected_list = "inactive"
	_set_status(Loc.t("roster.status.register_pending", {"player": player.name}), false)
	queue_redraw()


# live 支配下数 + 保存待ちの登録予定数。
func _effective_controlled_count() -> int:
	return TeamFinance.controlled_count(GameDb.players, _team_id) + _pending_controlled.size()


func _on_demote_pressed() -> void:
	if _selected_list == "active" and _active_ids.has(_selected_id):
		_demote(_selected_id)
	else:
		_set_status(Loc.t("roster.error.select_active"), true)


func _on_promote_pressed() -> void:
	if _selected_list == "inactive" and not _active_ids.has(_selected_id):
		_promote(_selected_id)
	else:
		_set_status(Loc.t("roster.error.select_inactive"), true)


func _on_register_pressed() -> void:
	if _selected_list == "dev":
		_promote_to_controlled(_selected_id)
	else:
		_set_status(Loc.t("roster.error.select_development"), true)


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_active_roster(season, _team_id)
	if not bool(preview.get("ok", false)):
		_set_status(Loc.t("common.auto_arrange_failed", {"reason": str(preview.get("message", ""))}), true)
		queue_redraw()
		return
	_active_ids = {}
	for id_value in (preview.get("player_ids", []) as Array):
		_active_ids[int(id_value)] = true
	_set_status(Loc.t("common.auto_arrange_unsaved"), false)
	queue_redraw()


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		_set_status(Loc.t("common.cannot_save_before_season"), true)
		queue_redraw()
		return
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	var total: int = int(summary.get("total", 0))
	if total > ROSTER_MAX:
		_set_status(Loc.t("lineup.status.save_failed", {"errors": Loc.t("roster.error.max_active_count", {"max": ROSTER_MAX, "n": total})}), true)
		return
	var foreign_violation: String = ForeignActiveRosterRules.violation_message(summary)
	if not foreign_violation.is_empty():
		_set_status(Loc.t("lineup.status.save_failed", {"errors": foreign_violation}), true)
		return
	if int(summary.get("catchers", 0)) < MIN_CATCHERS:
		_set_status(Loc.t("lineup.status.save_failed", {"errors": Loc.t("roster.error.min_catchers_count", {"min": MIN_CATCHERS, "n": int(summary.get("catchers", 0))})}), true)
		return

	# 保存待ちの育成→支配下登録をここで確定する (リセットなら _load_initial_state でクリアされ未確定のまま)。
	_commit_pending_controlled(season)

	var player_ids: Array = []
	for id_value in _active_ids.keys():
		player_ids.append(int(id_value))
	season.set_active_roster(_team_id, {"player_ids": player_ids})
	GameSimulator.preview_lineup(season, _team_id, false)
	SaveService.save_state(AppState)
	_set_status(Loc.t("common.saved_at", {"day": SeasonCalendar.day_status_label(season, season.current_day)}), false)
	queue_redraw()


func _commit_pending_controlled(season: PSSeason) -> void:
	if _pending_controlled.is_empty():
		return
	for pid_value in _pending_controlled.keys():
		var pid: int = int(pid_value)
		var player: PSPlayer = GameDb.get_player(pid)
		if player == null:
			continue
		PSCareerLog.log_dev_promote(player, season.year, player.team_id)
		player.development_player = false
		player.registered_roster = "支配下"
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, season.year, season.season_number)
		if record != null:
			record.development_player = false
			record.registered_roster = "支配下"
	GameDb.rebuild_player_indices()
	_pending_controlled = {}


# ============================================================ row builders / helpers

func _record_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var chip: Dictionary = _classify(record.player_id, record.is_pitcher(), record.role, record.position, _active_ids.has(record.player_id))
	var war: float = float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0))
	var games: int = record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games
	return {
		"id": record.player_id,
		"__meta": record.player_id,
		"role": chip["text"],
		"role_color": chip["color"],
		"role_dev": false,
		"order": int(chip["order"]),
		"name": record.name,
		"jersey": record.jersey_number,
		"age": record.age,
		"hand": _hand_name(record.throwing_hand) + _hand_name(record.batting_side),
		"fatigue": _fatigue_pct(record.fatigue),
		"note": _note_for(record.foreign_player, record.injury_days, record.counts_toward_foreign_slot()),
		"note_color": RED if record.injury_days > 0 else MUTED,
		"war": war,
		"war_sort": war,
		"eval": PlayerValueEvaluator.overall_score(record),
		"games": games,
		"rate": _rate_text(record),
	}


func _dev_row(player: PSPlayer) -> Dictionary:
	var chip: Dictionary = _classify(player.id, player.is_pitcher(), player.role, player.position, false)
	# 育成は出場記録が無い (= WAR 算出不可) ので "-" 表示。
	return {
		"id": player.id,
		"__meta": player.id,
		"role": chip["text"],
		"role_color": chip["color"],
		"role_dev": true,
		"order": int(chip["order"]),
		"name": player.name,
		"jersey": player.jersey_number,
		"age": player.age,
		"hand": _hand_name(player.throwing_hand) + _hand_name(player.batting_side),
		"fatigue": _fatigue_pct(player.fatigue),
		"note": _note_for(player.foreign_player, player.injury_days, player.counts_toward_foreign_slot()),
		"note_color": RED if player.injury_days > 0 else MUTED,
		"war": "-",
		"war_sort": 0.0,
		"eval": int(Offseason.player_value_score(player)),
		"games": "-",
		"rate": "-",
	}


# 一覧の「率/防」。野手は打率、投手は防御率。打数/投球回が無ければ "-"。
func _rate_text(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher():
		return ("%0.2f" % record.pitcher_stats.era()) if record.pitcher_stats.outs_pitched > 0 else "-"
	return _rate_short(record.batter_stats.batting_average()) if record.batter_stats.at_bats > 0 else "-"


# 疲労を 0〜100% へ正規化 (FATIGUE_MAX 基準)。
func _fatigue_pct(fatigue: int) -> int:
	return clampi(int(round(float(fatigue) * 100.0 / float(GameSimulator.FATIGUE_MAX))), 0, 100)


func _note_for(foreign: bool, injury_days: int, foreign_slot: bool = true) -> String:
	if injury_days > 0:
		return Loc.t("roster.note.injury", {"days": injury_days})
	if foreign:
		# 日本人扱い (外国人枠を消費しない) の外国人は、枠の計数と表示を分けて示す。
		return Loc.t("roster.note.foreign") if foreign_slot else Loc.t("roster.note.foreign_exempt")
	return ""


# 投手起用法 (rotation_editor) の保存ローテを読み、先発/中継の判定元にする。
func _load_rotation_classification(season: PSSeason) -> void:
	_rotation_set = {}
	var saved: Dictionary = season.get_rotation(_team_id)
	var rotation_ids: Array = []
	if saved.is_empty() or (saved.get("pitcher_ids", []) as Array).is_empty():
		var preview: Dictionary = GameSimulator.preview_rotation(season, _team_id)
		if bool(preview.get("ok", false)):
			rotation_ids = preview.get("pitcher_ids", []) as Array
	else:
		rotation_ids = saved.get("pitcher_ids", []) as Array
	for id_value in rotation_ids:
		_rotation_set[int(id_value)] = true


# 区分チップ + ソート順を一括算出。投手は 先発/中継 の2区分のみ (クローザーは中継扱い)。
# order: 先発0→中継1→捕3→一4→…→右10 (= ポジション番号順)。
func _classify(pid: int, is_pitcher: bool, role: String, pos: int, is_active: bool) -> Dictionary:
	if is_pitcher:
		if _pitcher_group(pid, role, is_active) == 0:
			return {"text": Loc.t("role.starter"), "color": PINK, "order": 0}
		return {"text": Loc.t("role.middle_short"), "color": RED, "order": 1}
	var order: int = pos + 1 if pos >= 2 and pos <= 9 else 11
	# 守備位置の色は共有基底 _pos_color に統一 (捕=BLUE / 内野=AMBER / 外野=GREEN)。
	return {"text": _pos_short(pos), "color": _pos_color(pos), "order": order}


# 0=先発 / 1=中継。1軍は保存ローテ入り=先発・それ以外=中継 (クローザーも中継)。
# 2軍/育成 やローテ未設定時は保存役割 (role) を正準とする (能力からの再分類はしない)。
func _pitcher_group(pid: int, role: String, is_active: bool) -> int:
	if _rotation_set.has(pid):
		return 0
	if is_active and not _rotation_set.is_empty():
		return 1
	if role == "reliever" or role == "closer":
		return 1
	return 0


func _pos_short(pos: int) -> String:
	return PSPlayer.position_short_name(pos) if pos >= 2 else "?"


# ============================================================ ポジション絞り込み

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


func _record_passes_filter(record: PSPlayerSeasonRecord) -> bool:
	if _filter_pos == 0:
		return true
	if _filter_pos == 1:
		return record.is_pitcher()
	if record.is_pitcher():
		return false
	# サブポジ含む: 本職一致 or 守備適性 > 0。
	return record.position == _filter_pos or TeamSetupBuilder.position_aptitude(record, _filter_pos) > 0


func _player_passes_filter(player: PSPlayer) -> bool:
	if _filter_pos == 0:
		return true
	if _filter_pos == 1:
		return player.is_pitcher()
	if player.is_pitcher():
		return false
	if player.position == _filter_pos:
		return true
	var key: String = str(PSPlayer.POSITION_EXPERIENCE_KEYS.get(_filter_pos, ""))
	return not key.is_empty() and int(player.position_aptitudes.get(key, 0)) > 0


func _compute_stats() -> Dictionary:
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	# 先発/中継 は投手起用法と一致する分類で数える (summary の starters は使わない)。
	var starters: int = 0
	var middle: int = 0
	var infield: int = 0
	var outfield: int = 0
	for record_row in _all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not _active_ids.has(record.player_id):
			continue
		if record.is_pitcher():
			if _pitcher_group(record.player_id, record.role, true) == 0:
				starters += 1
			else:
				middle += 1
		elif _is_catcher(record):
			pass
		elif record.position >= 7 and record.position <= 9:
			outfield += 1
		else:
			infield += 1
	return {
		"total": int(summary.get("total", 0)),
		"pitchers": int(summary.get("pitchers", 0)),
		"starters": starters,
		"middle": middle,
		"fielders": int(summary.get("fielders", 0)),
		"catchers": int(summary.get("catchers", 0)),
		"infield": infield,
		"outfield": outfield,
		"foreigners": int(summary.get("foreigners", 0)),
		"foreign_pitchers": int(summary.get("foreign_pitchers", 0)),
		"foreign_fielders": int(summary.get("foreign_fielders", 0)),
		"controlled": _effective_controlled_count(),
		"development": _development_players.size(),
	}


func _is_valid_drop(src: String, dst: String) -> bool:
	if src == "active" and dst == "inactive":
		return true
	if src == "inactive" and dst == "active":
		return true
	if src == "dev" and (dst == "active" or dst == "inactive"):
		return true
	return false


func _eval_color(_value: int) -> Color:
	return TEXT


func _war_color(_war: float) -> Color:
	return TEXT


func _fatigue_color(pct: int) -> Color:
	if pct < 25:
		return GREEN
	if pct < 50:
		return AMBER
	return RED


func _ip_str(ps: PSPitcherStats) -> String:
	if ps.outs_pitched <= 0:
		return "0"
	@warning_ignore("integer_division")
	return "%d.%d" % [ps.outs_pitched / 3, ps.outs_pitched % 3]


func _hand_name(value: String) -> String:
	match value:
		"L": return Loc.t("hand.left")
		"S": return Loc.t("hand.switch")
		_: return Loc.t("hand.right")


func _find_record(player_id: int) -> PSPlayerSeasonRecord:
	for record_row in _all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record
	return null


func _is_catcher(record: PSPlayerSeasonRecord) -> bool:
	return record != null and not record.is_pitcher() and TeamSetupBuilder.position_aptitude(record, 2) > 0


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error
	queue_redraw()
