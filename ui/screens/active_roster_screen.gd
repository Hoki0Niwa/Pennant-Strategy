extends "res://ui/components/dashboard_screen.gd"

# 選手登録画面。dashboard_screen の chrome 上に、1軍/2軍/育成の3カラムとロスター集計を描く。
# 選手を選ぶと下段に能力・今季成績・登録制約を表示し、ドラッグ&ドロップまたは移動ボタンで入替する。
#
# 移動規則: 1軍↔2軍 はドラッグで昇格/降格。育成→(1軍/2軍 へドロップ)で支配下登録 (2軍へ着地)。
# 育成への降格は戦力外フェーズ専用なのでこの画面では行わない (project_development_player_system 参照)。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const ROSTER_MAX: int = 31
const FOREIGN_MAX: int = 4
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

# ポジション絞り込み: 0=全 / 1=投 / 2..9=守備位置 (サブポジ適性も含めて判定)。
const FILTER_DEFS: Array = [
	{"pos": 0, "label": "全"},
	{"pos": 1, "label": "投"},
	{"pos": 2, "label": "捕"},
	{"pos": 3, "label": "一"},
	{"pos": 4, "label": "二"},
	{"pos": 5, "label": "三"},
	{"pos": 6, "label": "遊"},
	{"pos": 7, "label": "左"},
	{"pos": 8, "label": "中"},
	{"pos": 9, "label": "右"},
]

const DETAIL: Rect2 = Rect2(262, 740, 700, 316)
# 今季16項目=4列 / 直近8項目=2列。両者のセル幅が揃うよう SEASON を広く RECENT を狭く取る。
const SEASON: Rect2 = Rect2(978, 740, 592, 316)
const RECENT: Rect2 = Rect2(1586, 740, 314, 316)
const RECENT_WINDOW_DAYS: int = 14

const ROW_H: float = 27.0

# 一覧の列レイアウト。左から 区分/選手、右側に 年齢/WAR/評価/備考 を等間隔で並べ全幅を使う。
# 数値列は panel 右端からのオフセットで定義 (右揃え・列内で一定間隔)。
const C_CHIP_X: float = 12.0      # 区分チップ左
const C_NAME_X: float = 62.0      # 選手名左
const C_AGE_ROFF: float = 252.0   # 年齢 右端 = x + w - C_AGE_ROFF
const C_WAR_ROFF: float = 192.0   # WAR 右端 (年齢から右端間隔 60)
const C_EVAL_ROFF: float = 132.0  # 評価 右端 (WAR から 60)
# 備考は左揃え。評価の数値末尾(右端)から見た目の間隔が数値間と揃うよう左端を置く。
const C_NOTE_ROFF: float = 96.0   # 備考 左 = x + w - C_NOTE_ROFF (幅 = C_NOTE_ROFF - 12)

var _team_id: int = 0
var _all_records: Array = []          # 育成を除く記録持ち選手 (PSPlayerSeasonRecord)
var _development_players: Array = []   # 当チーム育成選手 (PSPlayer)
var _active_ids: Dictionary = {}       # {player_id: true}
var _selected_id: int = 0
var _selected_list: String = ""        # "active" / "inactive" / "dev"
var _status_text: String = ""
var _status_is_error: bool = false

# 投手の区分 (先発/中継) を投手起用法と一致させるための分類元。
# _rotation_set = 先発ローテ入りの投手 id (保存ローテ or preview)。クローザーは中継の一種として扱う。
var _rotation_set: Dictionary = {}

# 育成→支配下登録は保存まで確定しない (リセットで取り消せる)。{player_id: true}。
var _pending_shienka: Dictionary = {}

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
	var hit: Dictionary = _row_at(base_pos)
	if hit.is_empty():
		return
	_selected_id = int(hit["id"])
	_selected_list = str(hit["list"])
	_pending = {"id": _selected_id, "list": _selected_list, "name": str(hit["name"]), "start": base_pos}
	_drag_pos = _p(base_pos)
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
		_promote_to_shienka(id)
	else:
		_set_status("この移動はできません (育成への降格は戦力外フェーズで行います)", true)


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
		_text("チームが選択されていません", Vector2(770, 496), 20, MUTED)
		return

	_draw_shell("選手登録", team, season)

	var summary: Dictionary = _compute_stats()
	_draw_stat_cards(summary)
	# ポジション絞り込みチップ列の補足ラベル (チップ本体はオーバーレイボタン)。
	_text("ポジション絞り込み (サブポジ含む)", Vector2(INNER_L + float(FILTER_DEFS.size()) * 50.0 + 8.0, FILTER_Y + 21), 12, FAINT)
	_draw_columns()
	_draw_detail_panels(summary)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1074), 13, RED if _status_is_error else MUTED)

	_draw_drag_ghost()


# --- 集計カード ---

func _draw_stat_cards(s: Dictionary) -> void:
	var total: int = int(s["total"])
	var pitchers: int = int(s["pitchers"])
	var fielders: int = int(s["fielders"])
	var catchers: int = int(s["catchers"])
	var foreigners: int = int(s["foreigners"])

	var total_color: Color = RED if total > ROSTER_MAX else (AMBER if total == ROSTER_MAX else GREEN)
	var pit_color: Color = AMBER if pitchers < TARGET_PITCHERS_MIN or pitchers > TARGET_PITCHERS_MAX else GREEN
	var c_color: Color = RED if catchers < MIN_CATCHERS else GREEN
	var f_color: Color = RED if foreigners > FOREIGN_MAX else TEXT

	var cards: Array = [
		{"label": "1軍", "big": "%d/%d" % [total, ROSTER_MAX], "color": total_color, "sub": ""},
		{"label": "投手", "big": str(pitchers), "color": pit_color,
			"sub": "先発%d 中継%d" % [int(s["starters"]), int(s["middle"])]},
		{"label": "野手", "big": str(fielders), "color": TEXT,
			"sub": "捕%d 内%d 外%d" % [catchers, int(s["infield"]), int(s["outfield"])]},
		{"label": "捕手", "big": str(catchers), "color": c_color, "sub": "最低%d" % MIN_CATCHERS},
		{"label": "外国人", "big": "%d/%d" % [foreigners, FOREIGN_MAX], "color": f_color, "sub": ""},
		{"label": "支配下", "big": "%d/%d" % [int(s["shienka"]), TeamFinance.SHIENKA_LIMIT], "color": TEXT, "sub": ""},
		{"label": "育成", "big": str(int(s["development"])), "color": GREEN, "sub": ""},
	]
	var n: int = cards.size()
	var gap: float = 14.0
	var w: float = (INNER_R - INNER_L - gap * float(n - 1)) / float(n)
	for i in range(n):
		var card: Dictionary = cards[i] as Dictionary
		var rect: Rect2 = Rect2(INNER_L + float(i) * (w + gap), CARD_Y, w, CARD_H)
		_round(rect, PANEL, BORDER, 10)
		_text(str(card["label"]), Vector2(rect.position.x + 16, rect.position.y + 26), 13, MUTED)
		_text(str(card["big"]), Vector2(rect.position.x + 16, rect.position.y + 62), 26, card["color"] as Color)
		var sub: String = str(card["sub"])
		if not sub.is_empty():
			_text_right(sub, rect.end.x - 14, rect.position.y + 62, 12, FAINT, rect.size.x - 24)


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

	# 既定ソート: 区分順 (先発→中継→捕→内野→外野 = ポジション番号順)、同順位は評価降順。
	var sort_by_position: Callable = func(a: Variant, b: Variant) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["order"]) != int(db["order"]):
			return int(da["order"]) < int(db["order"])
		return int(da["eval"]) > int(db["eval"])
	active_rows.sort_custom(sort_by_position)
	inactive_rows.sort_custom(sort_by_position)
	dev_rows.sort_custom(sort_by_position)

	_row_hits = []
	_draw_column(COL1, "1軍", "%d/%d" % [active_rows.size(), ROSTER_MAX], active_rows, "active", 0.0)
	_draw_column(COL2, "2軍", "%d人" % inactive_rows.size(), inactive_rows, "inactive", 0.0)
	_draw_column(COL3, "育成", "%d人" % dev_rows.size(), dev_rows, "dev", DEV_BUTTON_RESERVE)


func _draw_column(panel: Rect2, title: String, count_text: String, rows: Array, list_key: String, reserve_bottom: float) -> void:
	var is_target: bool = _drag_active and not _pending.is_empty() \
		and _drop_zone_at(_to_base(_drag_pos)) == list_key and _is_valid_drop(str(_pending["list"]), list_key)
	_round(panel, PANEL, BLUE if is_target else BORDER, 10, 2 if is_target else 1)
	_text(title, Vector2(panel.position.x + 18, panel.position.y + 32), 16, TEXT)
	_text_right(count_text, panel.end.x - 18, panel.position.y + 32, 14, MUTED, 120)

	var x: float = panel.position.x
	var w: float = panel.size.x
	var hy: float = panel.position.y + 58
	_text("区分▾", Vector2(x + C_CHIP_X, hy), 11, FAINT)
	_text("選手", Vector2(x + C_NAME_X, hy), 11, FAINT)
	_text_right("年齢", x + w - C_AGE_ROFF, hy, 11, FAINT, 40)
	_text_right("WAR", x + w - C_WAR_ROFF, hy, 11, FAINT, 40)
	_text_right("評価", x + w - C_EVAL_ROFF, hy, 11, FAINT, 44)
	_text("備考", Vector2(x + w - C_NOTE_ROFF, hy), 11, FAINT)
	_line(Vector2(x + C_CHIP_X, panel.position.y + 68), Vector2(x + w - 16, panel.position.y + 68), BORDER_SOFT, 1.0)

	var row0: float = panel.position.y + 88
	var bottom: float = panel.end.y - 12 - reserve_bottom
	var visible: int = int((bottom - row0) / ROW_H)
	var max_scroll: int = max(0, rows.size() - visible)
	if int(_scroll[list_key]) > max_scroll:
		_scroll[list_key] = max_scroll
	var start: int = int(_scroll[list_key])

	var y: float = row0
	for i in range(start, min(start + visible, rows.size())):
		var row: Dictionary = rows[i] as Dictionary
		var id: int = int(row["id"])
		var row_rect: Rect2 = Rect2(x + 12, y - 18, w - 24, ROW_H)
		if id == _selected_id:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.20), Color(BLUE.r, BLUE.g, BLUE.b, 0.55), 5, 1)
		elif id == _hover_id:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 5, 0)
		_draw_row(row, x, w, y)
		_row_hits.append({"rect": row_rect, "id": id, "list": list_key, "name": str(row["name"])})
		y += ROW_H

	if rows.is_empty():
		_text("該当する選手がいません", Vector2(x + 16, row0 + 6), 13, MUTED)
	elif max_scroll > 0:
		_text("▲▼ ホイールでスクロール (%d/%d)" % [min(start + visible, rows.size()), rows.size()],
			Vector2(x + 16, bottom + 6), 10, FAINT)


func _draw_row(row: Dictionary, x: float, w: float, y: float) -> void:
	_chip(Rect2(x + C_CHIP_X, y - 16, 44, 22), str(row["role"]), row["role_color"] as Color)
	_text(str(row["name"]), Vector2(x + C_NAME_X, y), 14, TEXT, w - C_AGE_ROFF - 50 - C_NAME_X)
	_text_right(str(int(row["age"])), x + w - C_AGE_ROFF, y, 13, MUTED, 40)
	if bool(row.get("has_war", false)):
		_text_right(str(row["war_str"]), x + w - C_WAR_ROFF, y, 13, _war_color(float(row["war"])), 40)
	else:
		_text_right("-", x + w - C_WAR_ROFF, y, 13, FAINT, 40)
	_text_right(str(int(row["eval"])), x + w - C_EVAL_ROFF, y, 14, _eval_color(int(row["eval"])), 44)
	var note: String = str(row["note"])
	if not note.is_empty():
		_text(note, Vector2(x + w - C_NOTE_ROFF, y), 11, AMBER if note.begins_with("怪我") else MUTED, C_NOTE_ROFF - 12)


# --- 下段パネル ---

func _draw_detail_panels(_summary: Dictionary) -> void:
	_draw_player_detail()
	_draw_season_stats()
	_draw_recent_stats()


func _draw_player_detail() -> void:
	_panel(DETAIL, "選手詳細")
	var player: PSPlayer = GameDb.get_player(_selected_id)
	if player == null:
		_text("選手を選択してください", Vector2(DETAIL.position.x + 18, DETAIL.position.y + 70), 14, MUTED)
		return
	var record: PSPlayerSeasonRecord = _find_record(_selected_id)

	var px: float = DETAIL.position.x + 18
	var top: float = DETAIL.position.y + 64
	if player.jersey_number > 0:
		_text("#%d" % player.jersey_number, Vector2(px, top), 16, MUTED)
	_text(player.name, Vector2(px + 56, top), 22, TEXT)
	var role_chip: Dictionary = _classify(player.id, player.is_pitcher(), player.role, player.position, _active_ids.has(player.id))
	_chip(Rect2(px + 56 + _measure(player.name, 22) + 16, top - 20, 48, 24), str(role_chip["text"]), role_chip["color"] as Color)

	var eval: int = PlayerValueEvaluator.overall_score(record) if record != null else int(Offseason.player_value_score(player))
	_text_right("総合", DETAIL.end.x - 84, top - 18, 12, FAINT, 60)
	_text_right(str(eval), DETAIL.end.x - 18, top + 4, 26, _eval_color(eval), 90)

	# 能力レーティング (PlayerVisibleRatings)。投手/野手で項目が変わる。
	var ratings: Array = (PlayerVisibleRatings.ratings_for_record(record) if record != null \
		else PlayerVisibleRatings.ratings_for_player(player)).get("display_ratings", []) as Array
	var ry: float = top + 56
	# セル幅は項目数に合わせる (投手4 / 野手6) → 余白セルを作らず全幅を使う。
	var cell_w: float = (DETAIL.size.x - 36) / float(max(ratings.size(), 1))
	for i in range(ratings.size()):
		var rr: Dictionary = ratings[i] as Dictionary
		var cx: float = px + float(i) * cell_w
		var val: int = int(rr.get("display_value", 0))
		var suffix: String = str(rr.get("suffix", ""))
		_text(str(rr.get("label", "")), Vector2(cx, ry), 12, FAINT)
		_text("%d%s" % [val, suffix], Vector2(cx, ry + 30), 20, _eval_color(val) if suffix.is_empty() else TEXT)

	# プロフィール行 (捕手能力など z しか持たない内部値は UI に出さない)。
	var by: float = ry + 78
	_text(_bio_line(player), Vector2(px, by), 13, MUTED, DETAIL.size.x - 36)
	_text(_contract_line(player), Vector2(px, by + 28), 13, MUTED, DETAIL.size.x - 36)

	# コンディション (疲労度 / 怪我) を選手詳細に統合。
	_line(Vector2(px, by + 48), Vector2(DETAIL.end.x - 18, by + 48), BORDER_SOFT, 1.0)
	var cy: float = by + 76
	var fatigue_pct: int = clampi(int(round(float(player.fatigue) * 100.0 / float(GameSimulator.FATIGUE_MAX))), 0, 100)
	_text("疲労度", Vector2(px, cy - 18), 11, FAINT)
	_text("%d%%" % fatigue_pct, Vector2(px, cy + 4), 18, _fatigue_color(fatigue_pct))
	_text("怪我", Vector2(px + 150, cy - 18), 11, FAINT)
	if player.injury_days > 0:
		_text("%d日  %s" % [player.injury_days, PSInjuryModel.display_label(player.injury_type, player.injury_severity, player.injury_days)],
			Vector2(px + 150, cy + 4), 16, RED, DETAIL.size.x - 186)
	else:
		_text("なし", Vector2(px + 150, cy + 4), 18, GREEN)


func _draw_season_stats() -> void:
	_panel(SEASON, "今季成績")
	var record: PSPlayerSeasonRecord = _find_record(_selected_id)
	if record == null:
		_text("出場記録がありません", Vector2(SEASON.position.x + 18, SEASON.position.y + 70), 14, MUTED)
		return
	var war: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	var cells: Array = _pitcher_season_cells(record, war) if record.is_pitcher() else _batter_season_cells(record, war)
	_draw_stat_grid(SEASON, cells, 4)


# 直近 RECENT_WINDOW_DAYS 日のスナップショット差分。高度指標は窓別に持てないので基本+派生率のみ。
func _draw_recent_stats() -> void:
	_panel(RECENT, "直近2週間")
	var record: PSPlayerSeasonRecord = _find_record(_selected_id)
	if record == null:
		_text("出場記録がありません", Vector2(RECENT.position.x + 18, RECENT.position.y + 70), 14, MUTED)
		return
	var snap: Dictionary = {}
	var season: PSSeason = AppState.current_season
	if season != null:
		snap = season.get_player_stat_snapshot_at_or_before(record.player_id, season.current_day - RECENT_WINDOW_DAYS)
	# ベースライン無し (序盤等) はシーズン頭からの累計を窓とみなす。
	var base_b: PSBatterStats = PSBatterStats.from_dict(snap.get("batter", {}) as Dictionary) if not snap.is_empty() else PSBatterStats.new()
	var base_p: PSPitcherStats = PSPitcherStats.from_dict(snap.get("pitcher", {}) as Dictionary) if not snap.is_empty() else PSPitcherStats.new()
	var cells: Array
	if record.is_pitcher():
		cells = _pitcher_basic_cells(record.pitcher_stats.subtract_from(base_p))
	else:
		cells = _batter_basic_cells(record.batter_stats.subtract_from(base_b))
	_draw_stat_grid(RECENT, cells, 2)


func _batter_season_cells(record: PSPlayerSeasonRecord, war: Dictionary) -> Array:
	var bs: PSBatterStats = record.batter_stats
	var ad: PSAdvancedStats = record.advanced_stats
	var played: bool = ad != null and ad.plate_appearances > 0
	var oaa_total: float = 0.0
	if ad != null:
		oaa_total = float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))
	return [
		{"label": "試合", "value": str(bs.games)},
		{"label": "打席", "value": str(bs.plate_appearances)},
		{"label": "安打", "value": str(bs.hits)},
		{"label": "本塁打", "value": str(bs.home_runs)},
		{"label": "打点", "value": str(bs.runs_batted_in)},
		{"label": "二塁打", "value": str(bs.doubles)},
		{"label": "盗塁", "value": str(bs.stolen_bases)},
		{"label": "四球", "value": str(bs.walks)},
		{"label": "三振", "value": str(bs.strikeouts)},
		{"label": "打率", "value": _rate_short(bs.batting_average())},
		{"label": "出塁率", "value": _rate_short(bs.on_base_percentage())},
		{"label": "OPS", "value": _rate_short(bs.ops())},
		{"label": "wOBA", "value": _rate_short(ad.woba()) if played else "-"},
		{"label": "wRC+", "value": str(int(round(ad.wrc_plus()))) if played else "-"},
		{"label": "OAA", "value": _signed1(oaa_total) if played else "-", "color": _pm_color(oaa_total)},
		{"label": "WAR", "value": _signed1(float(war.get("war", 0.0))) if played else "-", "color": _war_color(float(war.get("war", 0.0)))},
	]


# 直近窓用の基本成績 (今季成績の項目から派生率/カウントのみを抜粋。高度指標は窓別に持てない)。
func _batter_basic_cells(bs: PSBatterStats) -> Array:
	return [
		{"label": "試合", "value": str(bs.games)},
		{"label": "打席", "value": str(bs.plate_appearances)},
		{"label": "安打", "value": str(bs.hits)},
		{"label": "本塁打", "value": str(bs.home_runs)},
		{"label": "打点", "value": str(bs.runs_batted_in)},
		{"label": "打率", "value": _rate_short(bs.batting_average())},
		{"label": "出塁率", "value": _rate_short(bs.on_base_percentage())},
		{"label": "OPS", "value": _rate_short(bs.ops())},
	]


func _pitcher_basic_cells(ps: PSPitcherStats) -> Array:
	var thrown: bool = ps.outs_pitched > 0
	return [
		{"label": "登板", "value": str(ps.games)},
		{"label": "投球回", "value": _ip_str(ps)},
		{"label": "勝", "value": str(ps.wins)},
		{"label": "敗", "value": str(ps.losses)},
		{"label": "セーブ", "value": str(ps.saves)},
		{"label": "防御率", "value": ("%0.2f" % ps.era()) if thrown else "-.--"},
		{"label": "WHIP", "value": ("%0.2f" % ps.whip()) if thrown else "-.--"},
		{"label": "K/9", "value": ("%0.2f" % ps.strikeouts_per_nine()) if thrown else "-"},
	]


func _pitcher_season_cells(record: PSPlayerSeasonRecord, war: Dictionary) -> Array:
	var ps: PSPitcherStats = record.pitcher_stats
	var thrown: bool = ps.outs_pitched > 0
	return [
		{"label": "登板", "value": str(ps.games)},
		{"label": "先発", "value": str(ps.starts)},
		{"label": "勝", "value": str(ps.wins)},
		{"label": "敗", "value": str(ps.losses)},
		{"label": "セーブ", "value": str(ps.saves)},
		{"label": "ホールド", "value": str(ps.holds)},
		{"label": "投球回", "value": _ip_str(ps)},
		{"label": "被安打", "value": str(ps.hits_allowed)},
		{"label": "被本塁打", "value": str(ps.home_runs_allowed)},
		{"label": "与四球", "value": str(ps.walks)},
		{"label": "奪三振", "value": str(ps.strikeouts)},
		{"label": "防御率", "value": ("%0.2f" % ps.era()) if thrown else "-.--"},
		{"label": "FIP", "value": ("%0.2f" % float(war.get("fip", 0.0))) if thrown and war.has("fip") else "-.--"},
		{"label": "WHIP", "value": ("%0.2f" % ps.whip()) if thrown else "-.--"},
		{"label": "K/9", "value": ("%0.2f" % ps.strikeouts_per_nine()) if thrown else "-"},
		{"label": "WAR", "value": _signed1(float(war.get("war", 0.0))) if thrown else "-", "color": _war_color(float(war.get("war", 0.0)))},
	]


# パネルを埋めるラベル/値カードグリッド。cols 列・行数は件数から算出し、行高は余白なく全高に伸ばす。
func _draw_stat_grid(panel: Rect2, cells: Array, cols: int) -> void:
	if cells.is_empty():
		return
	var px: float = panel.position.x + 18
	var top_y: float = panel.position.y + 56
	var avail_w: float = panel.size.x - 36
	var avail_h: float = panel.end.y - 14 - top_y
	var rows: int = ceili(float(cells.size()) / float(cols))
	var cell_w: float = avail_w / float(cols)
	var row_h: float = avail_h / float(rows)
	for i in range(cells.size()):
		var cell: Dictionary = cells[i] as Dictionary
		var col: int = i % cols
		var row: int = floori(float(i) / float(cols))
		var cx: float = px + float(col) * cell_w
		var cy: float = top_y + float(row) * row_h
		_round(Rect2(cx + 3, cy + 3, cell_w - 6, row_h - 6), PANEL_2, BORDER_SOFT, 7)
		var color: Color = cell.get("color", TEXT) as Color
		_text(str(cell["label"]), Vector2(cx + 12, cy + row_h * 0.42), 11, MUTED, cell_w - 22)
		_text_right(str(cell["value"]), cx + cell_w - 12, cy + row_h * 0.80, 17, color, cell_w - 22)


func _signed1(value: float) -> String:
	return "%+.1f" % value


func _pm_color(value: float) -> Color:
	if value > 0.05:
		return GREEN
	if value < -0.05:
		return RED
	return TEXT


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
	_add_button("auto", "自動編成", Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", "リセット", Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", "保存", Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")

	# ポジション絞り込みチップ列。
	_filter_buttons = {}
	var fx: float = INNER_L
	for def_value in FILTER_DEFS:
		var def: Dictionary = def_value as Dictionary
		var pos: int = int(def["pos"])
		var btn: Button = _add_button("filter_%d" % pos, str(def["label"]), Rect2(fx, FILTER_Y, 44, 30),
			func(p: int = pos) -> void: _set_filter(p),
			"chip_active" if pos == _filter_pos else "chip")
		_filter_buttons[pos] = btn
		fx += 50.0

	# 1軍↔2軍 の移動ボタン (ガター中央)。
	var g1: float = (COL1.end.x + COL2.position.x) * 0.5
	_add_button("demote", "2軍へ →", Rect2(g1 - 40, COL_TOP + COL_H * 0.5 - 40, 80, 36), _on_demote_pressed, "action")
	_add_button("promote", "← 1軍へ", Rect2(g1 - 40, COL_TOP + COL_H * 0.5 + 4, 80, 36), _on_promote_pressed, "action")
	# 支配下登録は育成カラム枠内の下部に置く。
	_add_button("register", "支配下登録 ↑", Rect2(COL3.position.x + 16, COL3.end.y - 40, COL3.size.x - 32, 32), _on_register_pressed, "primary")


# ============================================================ data load

func _load_initial_state() -> void:
	var season: PSSeason = AppState.current_season
	_team_id = AppState.selected_team_id
	if season == null or _team_id <= 0:
		_set_status("チームが選択されていません", true)
		queue_redraw()
		return
	var team: PSTeam = GameDb.get_team(_team_id)
	if team == null:
		_set_status("チーム情報が取得できません", true)
		queue_redraw()
		return

	_pending_shienka = {}
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
			_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
			queue_redraw()
			return
		initial_ids = preview.get("player_ids", []) as Array
		_set_status("保存されたロスターがありません。自動編成を表示しています。", false)
	else:
		initial_ids = saved.get("player_ids", []) as Array
		_set_status("保存されたロスターを表示しています (%s 更新)" % SeasonCalendar.day_status_label(season, int(saved.get("updated_at_day", 0))), false)
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
		_set_status("捕手は1軍に最低%d人必要です" % MIN_CATCHERS, true)
		return
	_active_ids.erase(player_id)
	_set_status("%s を2軍に移しました" % (record.name if record != null else ""), false)
	queue_redraw()


func _promote(player_id: int) -> void:
	if _active_ids.has(player_id):
		return
	var record: PSPlayerSeasonRecord = _find_record(player_id)
	if record == null:
		return
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	if int(summary.get("total", 0)) >= ROSTER_MAX:
		_set_status("1軍は最大%d人です" % ROSTER_MAX, true)
		return
	if record.foreign_player and int(summary.get("foreigners", 0)) >= FOREIGN_MAX:
		_set_status("外国人枠は最大%d人です" % FOREIGN_MAX, true)
		return
	_active_ids[player_id] = true
	_set_status("%s を1軍に上げました" % record.name, false)
	queue_redraw()


# 育成 → 支配下 登録 (2軍へ着地)。**保存まで確定しない** (リセットで取り消せる)。
# 即時には live player を変えず、表示上だけ育成リストから 2軍へ移す。確定は _on_save_pressed。
func _promote_to_shienka(player_id: int) -> void:
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null or not player.development_player or player.team_id != _team_id:
		return
	if _pending_shienka.has(player_id):
		return
	if _effective_shienka_count() >= TeamFinance.SHIENKA_LIMIT:
		_set_status("支配下枠が満杯です (最大%d人)。先に支配下選手を整理してください" % TeamFinance.SHIENKA_LIMIT, true)
		return
	_pending_shienka[player_id] = true
	_development_players.erase(player)
	# 2軍に表示するため記録を確保 (新人で記録未生成なら player から生成)。
	var season: PSSeason = AppState.current_season
	if _find_record(player_id) == null and season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
		_all_records.append(record if record != null else PSPlayerSeasonRecord.from_player(player, season.year, season.season_number))
	_selected_id = player_id
	_selected_list = "inactive"
	_set_status("%s を支配下登録します (保存で確定)" % player.name, false)
	queue_redraw()


# live 支配下数 + 保存待ちの登録予定数。
func _effective_shienka_count() -> int:
	return TeamFinance.shienka_count(GameDb.players, _team_id) + _pending_shienka.size()


func _on_demote_pressed() -> void:
	if _selected_list == "active" and _active_ids.has(_selected_id):
		_demote(_selected_id)
	else:
		_set_status("1軍の選手を選択してください", true)


func _on_promote_pressed() -> void:
	if _selected_list == "inactive" and not _active_ids.has(_selected_id):
		_promote(_selected_id)
	else:
		_set_status("2軍の選手を選択してください", true)


func _on_register_pressed() -> void:
	if _selected_list == "dev":
		_promote_to_shienka(_selected_id)
	else:
		_set_status("育成選手を選択してください", true)


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_active_roster(season, _team_id)
	if not bool(preview.get("ok", false)):
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		queue_redraw()
		return
	_active_ids = {}
	for id_value in (preview.get("player_ids", []) as Array):
		_active_ids[int(id_value)] = true
	_set_status("自動編成を表示中 (未保存)", false)
	queue_redraw()


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
		queue_redraw()
		return
	var summary: Dictionary = GameSimulator.summarize_active_roster_ids(_active_ids.keys(), _all_records)
	var total: int = int(summary.get("total", 0))
	if total > ROSTER_MAX:
		_set_status("保存失敗: 1軍は最大%d人です(%d人)" % [ROSTER_MAX, total], true)
		return
	if int(summary.get("foreigners", 0)) > FOREIGN_MAX:
		_set_status("保存失敗: 外国人枠は最大%d人です(%d人)" % [FOREIGN_MAX, int(summary.get("foreigners", 0))], true)
		return
	if int(summary.get("catchers", 0)) < MIN_CATCHERS:
		_set_status("保存失敗: 捕手は1軍に最低%d人必要です (%d人)" % [MIN_CATCHERS, int(summary.get("catchers", 0))], true)
		return

	# 保存待ちの育成→支配下登録をここで確定する (リセットなら _load_initial_state でクリアされ未確定のまま)。
	_commit_pending_shienka(season)

	var player_ids: Array = []
	for id_value in _active_ids.keys():
		player_ids.append(int(id_value))
	season.set_active_roster(_team_id, {"player_ids": player_ids})
	GameSimulator.preview_lineup(season, _team_id, false)
	SaveService.save_state(AppState)
	_set_status("保存しました (%s)" % SeasonCalendar.day_status_label(season, season.current_day), false)
	queue_redraw()


func _commit_pending_shienka(season: PSSeason) -> void:
	if _pending_shienka.is_empty():
		return
	for pid_value in _pending_shienka.keys():
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
	_pending_shienka = {}


# ============================================================ row builders / helpers

func _record_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var chip: Dictionary = _classify(record.player_id, record.is_pitcher(), record.role, record.position, _active_ids.has(record.player_id))
	var war: float = float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0))
	return {
		"id": record.player_id,
		"role": chip["text"],
		"role_color": chip["color"],
		"order": int(chip["order"]),
		"name": record.name,
		"age": record.age,
		"war": war,
		"war_str": "%0.1f" % war,
		"has_war": true,
		"eval": PlayerValueEvaluator.overall_score(record),
		"note": _note_for(record.foreign_player, record.injury_days),
	}


func _dev_row(player: PSPlayer) -> Dictionary:
	var chip: Dictionary = _classify(player.id, player.is_pitcher(), player.role, player.position, false)
	# 育成は出場記録が無い (= WAR 算出不可) ので "-" 表示。
	return {
		"id": player.id,
		"role": chip["text"],
		"role_color": chip["color"],
		"order": int(chip["order"]),
		"name": player.name,
		"age": player.age,
		"war": 0.0,
		"war_str": "-",
		"has_war": false,
		"eval": int(Offseason.player_value_score(player)),
		"note": _note_for(player.foreign_player, player.injury_days),
	}


func _note_for(foreign: bool, injury_days: int) -> String:
	if injury_days > 0:
		return "怪我%d日" % injury_days
	if foreign:
		return "外"
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
func _classify(pid: int, is_pitcher: bool, role: String, position: int, is_active: bool) -> Dictionary:
	if is_pitcher:
		if _pitcher_group(pid, role, is_active) == 0:
			return {"text": "先発", "color": PINK, "order": 0}
		return {"text": "中継", "color": RED, "order": 1}
	var order: int = position + 1 if position >= 2 and position <= 9 else 11
	# 守備位置の色は共有基底 _pos_color に統一 (捕=BLUE / 内野=AMBER / 外野=GREEN)。
	return {"text": _pos_short(position), "color": _pos_color(position), "order": order}


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


func _pos_short(position: int) -> String:
	match position:
		2: return "捕"
		3: return "一"
		4: return "二"
		5: return "三"
		6: return "遊"
		7: return "左"
		8: return "中"
		9: return "右"
		10: return "DH"
		_: return "?"


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
		"shienka": _effective_shienka_count(),
		"development": _development_players.size(),
	}


func _bio_line(player: PSPlayer) -> String:
	var parts: Array = []
	parts.append("%d歳 (%d年目)" % [player.age, player.years])
	parts.append("%dcm %dkg" % [player.height, player.weight])
	parts.append("%s投%s打" % [_hand_name(player.throwing_hand), _hand_name(player.batting_side)])
	if not player.hometown.is_empty():
		parts.append(player.hometown)
	return "  ".join(parts)


func _contract_line(player: PSPlayer) -> String:
	var roster: String = "育成" if player.development_player else player.registered_roster
	return "%s  年俸 %s" % [roster, _format_money(player.salary)]


func _is_valid_drop(src: String, dst: String) -> bool:
	if src == "active" and dst == "inactive":
		return true
	if src == "inactive" and dst == "active":
		return true
	if src == "dev" and (dst == "active" or dst == "inactive"):
		return true
	return false


func _eval_color(value: int) -> Color:
	if value >= 75:
		return BLUE
	if value >= 66:
		return GREEN
	if value >= 52:
		return TEXT
	return MUTED


func _war_color(war: float) -> Color:
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	if war <= 0.0:
		return FAINT
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
		"L": return "左"
		"S": return "両"
		_: return "右"


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
