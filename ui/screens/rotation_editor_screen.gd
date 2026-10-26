extends "res://ui/components/dashboard_screen.gd"

# 投手起用法画面。一軍投手一覧、先発ローテ、リリーフ役割レーンを同時に編集する。
# 一覧/ローテ枠/リリーフチップの間でドラッグ&ドロップし、保存値は season.get_rotation に反映する。
#
# 役割色: 先発=淡ピンク / 中継=赤 / 抑え=金。リリーフレーンは全て赤ベース (濃淡で区別)。
# リリーフ役割は season.get_rotation の relief_roles に保存 (long は複数=long_ids)。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const ROTATION_SIZE: int = 6

# 先発=PINK / セットアッパー=VIOLET は共有基底 dashboard_screen の const を使う。
const CLOSER_RED: Color = Color(0.92, 0.24, 0.30)  # 抑え/クローザー (赤系統)

# --- レイアウト (base 座標) ---
const TABLE_PANEL: Rect2 = Rect2(262, 104, 1638, 528)
const ROTATION_PANEL: Rect2 = Rect2(262, 648, 800, 408)
const RELIEF_PANEL: Rect2 = Rect2(1078, 648, 822, 408)

# 一軍投手一覧 (共通テーブル) の行高と下余白。1 画面に収まる行数は共通テーブルが決め、
# ホイールスクロールの上限は描画時のスクロール領域 (_table_max_scroll) から読む。
const TABLE_ROW_H: float = 27.0
const TABLE_BOTTOM_PAD: float = 12.0

# 先発ローテ表 (共通テーブル) の行高。1 行 = 1 つのドロップ先 (行全体が当たり判定)。
const ROTATION_ROW_H: float = 50.0
const ROTATION_BOTTOM_PAD: float = 8.0

# リリーフのチップ寸法。レーンのドロップ領域に 3 段まで収まる高さにしてある。
const CHIP_H: float = 22.0
const CHIP_GAP: float = 3.0

# リリーフレーン定義 (上から: クローザー→セットアッパー→ミドル→ロング)。closer は max=1。
# label / desc は表示文言のキー (Loc)。
const RELIEF_LANES: Array = [
	{"key": "closer", "label": "relief.closer", "desc": "relief.closer_desc", "color": CLOSER_RED},
	{"key": "setup", "label": "relief.setup", "desc": "relief.setup_desc", "color": VIOLET},
	{"key": "middle", "label": "relief.middle", "desc": "relief.middle_desc", "color": RED},
	{"key": "long", "label": "relief.long", "desc": "relief.long_desc", "color": BLUE},
]

var _team_id: int = 0
var _active_pitchers: Array = []
var _rotation_ids: Array = []
var _relief: Dictionary = {}                  # {long:[ids], middle:[ids], setup:[ids], closer:[id]}
var _war_by_id: Dictionary = {}               # player_id -> season_war 結果 dict
var _preview: Dictionary = {}
var _status_text: String = ""
var _status_is_error: bool = false

# 一覧ソートとスクロール
var _sort_key: String = "role"
var _sort_asc: bool = true
var _table_scroll: int = 0
var _table_max_scroll: int = 0
var _header_hits: Array = []

# ドラッグ状態
var _drag_active: bool = false
var _drag_record: PSPlayerSeasonRecord = null
var _drag_origin: Dictionary = {}
var _drag_pos: Vector2 = Vector2.ZERO
var _hover_record: PSPlayerSeasonRecord = null
var _row_hits: Array = []
var _chip_hits: Array = []


func _ready() -> void:
	_init_chrome()
	_rotation_ids.resize(ROTATION_SIZE)
	_rotation_ids.fill(0)
	_relief = {"long": [], "middle": [], "setup": [], "closer": []}
	_build_chrome_buttons()
	_load_initial_state()
	_layout_buttons()
	queue_redraw()


# ============================================================ input (drag & drop)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_update_transform()
		var base_pos: Vector2 = _to_base(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				for hit_value in _header_hits:
					var hit: Dictionary = hit_value as Dictionary
					if (hit["rect"] as Rect2).has_point(base_pos):
						_on_header_clicked(str(hit["key"]))
						return
				_begin_drag(base_pos)
			elif _drag_active:
				_finish_drag(base_pos)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.pressed and TABLE_PANEL.has_point(base_pos):
				if _table_scroll > 0:
					_table_scroll = max(0, _table_scroll - 1)
					queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and TABLE_PANEL.has_point(base_pos):
				if _table_scroll < _table_max_scroll:
					_table_scroll = min(_table_max_scroll, _table_scroll + 1)
					queue_redraw()
	elif event is InputEventMouseMotion:
		if _drag_active:
			_drag_pos = event.position
			queue_redraw()
		else:
			_update_transform()
			var rec: PSPlayerSeasonRecord = _row_record_at(_to_base(event.position))
			if rec != _hover_record:
				_hover_record = rec
				queue_redraw()


func _on_header_clicked(key: String) -> void:
	if _sort_key == key:
		_sort_asc = not _sort_asc
	else:
		_sort_key = key
		_sort_asc = (key in ["role", "name", "hand", "age", "fatigue", "era", "fip", "whip"])
	queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


func _begin_drag(base_pos: Vector2) -> void:
	var rec: PSPlayerSeasonRecord = _row_record_at(base_pos)
	if rec != null:
		_start_drag(rec, {"type": "table"}, base_pos)
		return
	for hit_value in _chip_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			_start_drag(hit["record"] as PSPlayerSeasonRecord, {"type": "rel", "role": str(hit["role"])}, base_pos)
			return
	for i in range(ROTATION_SIZE):
		if _rotation_slot_rect(i).has_point(base_pos) and int(_rotation_ids[i]) > 0:
			_start_drag(_record_by_id(int(_rotation_ids[i])), {"type": "rot", "index": i}, base_pos)
			return


func _start_drag(rec: PSPlayerSeasonRecord, origin: Dictionary, base_pos: Vector2) -> void:
	if rec == null:
		return
	_drag_active = true
	_drag_record = rec
	_drag_origin = origin
	_drag_pos = _p(base_pos)
	queue_redraw()


func _finish_drag(base_pos: Vector2) -> void:
	var pid: int = _drag_record.player_id
	var target: Dictionary = _drop_target_at(base_pos)
	match str(target.get("type", "")):
		"rot":
			_remove_everywhere(pid)
			_rotation_ids[int(target["index"])] = pid
		"rel":
			_remove_everywhere(pid)
			var role: String = str(target["role"])
			if role == "closer":
				_relief["closer"] = [pid]
			else:
				(_relief[role] as Array).append(pid)
		"table":
			_remove_everywhere(pid)
		_:
			pass
	_drag_active = false
	_drag_record = null
	_drag_origin = {}
	queue_redraw()


func _drop_target_at(base_pos: Vector2) -> Dictionary:
	for i in range(ROTATION_SIZE):
		if _rotation_slot_rect(i).has_point(base_pos):
			return {"type": "rot", "index": i}
	for i in range(RELIEF_LANES.size()):
		if _relief_lane_rect(i).has_point(base_pos):
			return {"type": "rel", "role": str((RELIEF_LANES[i] as Dictionary)["key"])}
	if TABLE_PANEL.has_point(base_pos):
		return {"type": "table"}
	return {}


func _remove_everywhere(pid: int) -> void:
	for i in range(ROTATION_SIZE):
		if int(_rotation_ids[i]) == pid:
			_rotation_ids[i] = 0
	for key in _relief.keys():
		(_relief[key] as Array).erase(pid)


func _row_record_at(base_pos: Vector2) -> PSPlayerSeasonRecord:
	for hit_value in _row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit["record"] as PSPlayerSeasonRecord
	return null


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

	_draw_shell(Loc.t("screen.rotation_editor"), team, season)
	_draw_pitcher_table()
	_draw_rotation_panel()
	_draw_relief_panel()

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1074), 13, RED if _status_is_error else MUTED)

	_draw_drag_ghost()


# --- 一軍投手一覧 ---

func _pitcher_table_columns() -> Array:
	# 共通のプロフィール列 / 評価列を、この画面のソートキー名 (hand / eval) へ付け替えて使う。
	var cols: Array = []
	for col_value in _player_profile_columns(true, false, false, true):
		var col: Dictionary = (col_value as Dictionary).duplicate()
		if str(col["key"]) == "throws":
			col["key"] = "hand"
		cols.append(col)
	for col_value in _player_eval_columns(true, false, true):
		var col: Dictionary = (col_value as Dictionary).duplicate()
		if str(col["key"]) == "overall":
			col["key"] = "eval"
		cols.append(col)
	var ability_group: String = "group.pitcher_abilities"
	var record_group: String = "lineup.col.record_block"
	cols.append({"title": "rating.velocity", "key": "velo", "w": 52, "align": "r", "fmt": "str", "sep_before": true, "group": ability_group})
	cols.append({"title": "rating.stuff", "key": "stuff", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group})
	cols.append({"title": "rating.control", "key": "ctrl", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group})
	cols.append({"title": "col.stamina_short", "key": "stam", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group})
	cols.append({"title": "col.appearances", "key": "g", "w": 38, "align": "r", "fmt": "str", "sep_before": true, "group": record_group})
	cols.append({"title": "col.wins", "key": "w", "w": 34, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "col.losses", "key": "l", "w": 34, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "S", "key": "sv", "w": 34, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "H", "key": "hld", "w": 34, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "col.innings", "key": "ip", "w": 48, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "stat.era", "key": "era", "w": 50, "align": "r", "fmt": "str", "strong": true, "group": record_group})
	cols.append({"title": "FIP", "key": "fip", "w": 50, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "WHIP", "key": "whip", "w": 50, "align": "r", "fmt": "str", "group": record_group})
	cols.append({"title": "K/9", "key": "k9", "w": 46, "align": "r", "fmt": "str", "group": record_group})
	return cols


func _pitcher_table_row(record: PSPlayerSeasonRecord, rotation_set: Dictionary, closer_id: int) -> Dictionary:
	var ps: PSPitcherStats = record.pitcher_stats
	var role: Dictionary = _role_chip(record, rotation_set, closer_id)
	return {
		"__meta": record.player_id,
		"role": str(role["text"]),
		"role_color": role["color"],
		"name": record.name,
		"jersey": record.jersey_number,
		"age": record.age,
		"hand": Loc.t("hand.left") if record.throwing_hand == "L" else Loc.t("hand.right"),
		"fatigue": _fatigue_pct(record),
		"eval": PlayerValueEvaluator.overall_score(record),
		"war": float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0)) if ps.outs_pitched > 0 else 0.0,
		"velo": "%dkm/h" % PlayerVisibleRatings.pitcher_velocity(record),
		"stuff": PlayerVisibleRatings.pitcher_stuff(record),
		"ctrl": PlayerVisibleRatings.pitcher_control(record),
		"stam": PlayerVisibleRatings.pitcher_stamina(record),
		"g": str(ps.games),
		"w": str(ps.wins),
		"l": str(ps.losses),
		"sv": str(ps.saves),
		"hld": str(ps.holds),
		"ip": _ip_str(ps),
		"era": _era_str(record),
		"fip": _fip_str(record),
		"whip": _whip_str(ps),
		"k9": _k9_str(ps),
	}


func _draw_pitcher_table() -> void:
	var closer_id: int = _closer_id()
	var rotation_set: Dictionary = _rotation_id_set()
	var records: Array = _sorted_table_rows(rotation_set, closer_id)
	var rows: Array = []
	for record_value in records:
		var row: Dictionary = _pitcher_table_row(record_value as PSPlayerSeasonRecord, rotation_set, closer_id)
		var hover_record: PSPlayerSeasonRecord = _drag_record if _drag_record != null else _hover_record
		if hover_record != null and hover_record.player_id == int(row["__meta"]):
			row["is_hover"] = true
		rows.append(row)

	var columns: Array = _pitcher_table_columns()
	var scroll: Dictionary = {"pitchers": _table_scroll}
	var scroll_zones: Array = []
	var hits: Array = []
	var opts: Dictionary = {
		"title": Loc.t("rotation.pitcher_list"),
		"right_label": Loc.t("rotation.drag_hint"),
		"empty_text": Loc.t("rotation.no_active_pitchers"),
		"row_h": TABLE_ROW_H,
		"bottom_pad": TABLE_BOTTOM_PAD,
		"cell_size": 13,
		"sort_key": _sort_key,
		"sort_asc": _sort_asc,
		"sel_kind": "pitcher",
		"hits": hits,
		"scroll_key": "pitchers",
		"scroll": scroll,
		"scroll_zones": scroll_zones,
	}
	_draw_data_table(TABLE_PANEL, columns, rows, opts)
	_table_scroll = int(scroll.get("pitchers", 0))
	_table_max_scroll = int((scroll_zones[0] as Dictionary).get("max", 0)) if not scroll_zones.is_empty() else 0

	# ヘッダのソート当たり判定と行のドラッグ元判定は、表の描画と同じ幾何から作る。
	_header_hits = []
	_build_table_header_hits(_header_hits, TABLE_PANEL, columns, opts)
	_row_hits = []
	for hit_value in hits:
		var hit: Dictionary = hit_value as Dictionary
		var record: PSPlayerSeasonRecord = _record_by_id(int(hit["meta"]))
		if record != null:
			_row_hits.append({"rect": hit["rect"], "record": record})


# --- 先発ローテ ---

func _rotation_table_columns() -> Array:
	var profile_group: String = "group.profile"
	var ability_group: String = "group.pitcher_abilities"
	var record_group: String = "lineup.col.record_block"
	return [
		{"title": "No.", "key": "slot", "w": 44, "align": "c", "fmt": "pos_badge", "group": "rotation.slot_col"},
		{"title": "col.player", "key": "name", "w": 136, "align": "l", "fmt": "player_name", "strong": true, "sep_before": true, "group": profile_group},
		{"title": "col.throws_short", "key": "hand", "w": 28, "align": "c", "fmt": "str", "group": profile_group},
		{"title": "col.fatigue", "key": "fatigue", "w": 50, "align": "c", "fmt": "fatigue_dot", "group": profile_group},
		{"title": "col.overall", "key": "eval", "w": 44, "align": "c", "fmt": "eval_badge", "sep_before": true, "group": "group.eval"},
		{"title": "rating.velocity", "key": "velo", "w": 66, "align": "r", "fmt": "str", "sep_before": true, "group": ability_group},
		{"title": "rating.stuff", "key": "stuff", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group},
		{"title": "rating.control", "key": "ctrl", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group},
		{"title": "col.stamina_short", "key": "stam", "w": 42, "align": "c", "fmt": "ability_bar", "group": ability_group},
		{"title": "stat.era", "key": "era", "w": 50, "align": "r", "fmt": "str", "strong": true, "sep_before": true, "group": record_group},
		{"title": "col.innings", "key": "ip", "w": 48, "align": "r", "fmt": "str", "group": record_group},
		{"title": "WAR", "key": "war", "w": 44, "align": "r", "fmt": "f1s", "strong": true, "group": record_group},
	]


func _rotation_table_row(i: int, record: PSPlayerSeasonRecord) -> Dictionary:
	var row: Dictionary = {"slot": str(i + 1), "slot_color": PINK}
	if record == null:
		return row
	var ps: PSPitcherStats = record.pitcher_stats
	row["name"] = record.name
	row["jersey"] = record.jersey_number
	row["hand"] = Loc.t("hand.left") if record.throwing_hand == "L" else Loc.t("hand.right")
	row["fatigue"] = _fatigue_pct(record)
	row["eval"] = PlayerValueEvaluator.overall_score(record)
	row["velo"] = "%dkm/h" % PlayerVisibleRatings.pitcher_velocity(record)
	row["stuff"] = PlayerVisibleRatings.pitcher_stuff(record)
	row["ctrl"] = PlayerVisibleRatings.pitcher_control(record)
	row["stam"] = PlayerVisibleRatings.pitcher_stamina(record)
	row["era"] = _era_str(record)
	row["ip"] = _ip_str(ps)
	row["war"] = float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0)) if ps.outs_pitched > 0 else 0.0
	return row


func _draw_rotation_panel() -> void:
	var columns: Array = _rotation_table_columns()
	var rows: Array = []
	for i in range(ROTATION_SIZE):
		rows.append(_rotation_table_row(i, _record_by_id(int(_rotation_ids[i]))))
	_draw_data_table(ROTATION_PANEL, columns, rows, _rotation_table_opts())

	# ドロップ先の強調と空き枠の案内は、表の行と同じ矩形 (_rotation_slot_rect) に重ねる。
	var name_x: float = _table_column_rect(ROTATION_PANEL, columns, _rotation_table_opts(), "name").position.x
	for i in range(ROTATION_SIZE):
		var slot_rect: Rect2 = _rotation_slot_rect(i)
		if _drag_active and _drop_match({"type": "rot", "index": i}):
			_round(slot_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.16), BLUE, 7, 2)
		if int(_rotation_ids[i]) <= 0:
			_text(Loc.t("rotation.drop_here"), Vector2(name_x + 4.0, slot_rect.position.y + slot_rect.size.y * 0.5 + 5.0), 12, FAINT)


func _rotation_table_opts() -> Dictionary:
	return {
		"title": Loc.t("rotation.rotation_panel"),
		"row_h": ROTATION_ROW_H,
		"bottom_pad": ROTATION_BOTTOM_PAD,
		"cell_size": 13,
	}


# 先発ローテの 1 行 = 1 つのドロップ先。_draw_data_table の行幾何
# (1 行目の上端 = _table_row_top、行は ROTATION_ROW_H 刻み、左右 8px 内側) と一致させる。
func _rotation_slot_rect(i: int) -> Rect2:
	var row_top: float = _table_row_top(ROTATION_PANEL, _rotation_table_columns(), _rotation_table_opts())
	return Rect2(
		ROTATION_PANEL.position.x + 8.0,
		row_top + float(i) * ROTATION_ROW_H,
		ROTATION_PANEL.size.x - 16.0,
		ROTATION_ROW_H)


# --- リリーフ起用法 (レーン式・複数可) ---

func _draw_relief_panel() -> void:
	_panel(RELIEF_PANEL, Loc.t("rotation.relief_panel"))
	_chip_hits = []
	var px: float = RELIEF_PANEL.position.x
	for i in range(RELIEF_LANES.size()):
		var lane: Dictionary = RELIEF_LANES[i] as Dictionary
		var lane_y: float = _relief_lane_top(i)
		var lane_h: float = _relief_lane_h()
		if i > 0:
			_line(Vector2(px + 16, lane_y), Vector2(RELIEF_PANEL.end.x - 16, lane_y), HAIRLINE, 1.0)
		var color: Color = lane["color"] as Color
		_round(Rect2(px + 16, lane_y + (lane_h - 28) * 0.5 - 12, 124, 28), Color(color.r, color.g, color.b, 0.18), Color(color.r, color.g, color.b, 0.65), 6, 1)
		_text(Loc.t(str(lane["label"])), Vector2(px + 16, lane_y + (lane_h - 28) * 0.5 + 7), 13, color, 124, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text(Loc.t(str(lane["desc"])), Vector2(px + 16, lane_y + (lane_h - 28) * 0.5 + 34), 11, FAINT, 150)
		_draw_relief_lane(i, str(lane["key"]))


func _relief_lane_top(i: int) -> float:
	return RELIEF_PANEL.position.y + 56.0 + float(i) * _relief_lane_h()


func _relief_lane_h() -> float:
	return (RELIEF_PANEL.size.y - 64.0) / float(RELIEF_LANES.size())


func _relief_lane_rect(i: int) -> Rect2:
	var lane_y: float = _relief_lane_top(i)
	var lane_h: float = _relief_lane_h()
	var zx: float = RELIEF_PANEL.position.x + 168.0
	var zh: float = lane_h - 8.0
	return Rect2(zx, lane_y + (lane_h - zh) * 0.5, RELIEF_PANEL.end.x - 16 - zx, zh)


func _draw_relief_lane(i: int, role: String) -> void:
	var zone: Rect2 = _relief_lane_rect(i)
	var is_target: bool = _drag_active and _drop_match({"type": "rel", "role": role})
	# 枠線はドロップ先として有効な時だけ (通常時はフラット)。
	var border: Color = BLUE if is_target else Color.TRANSPARENT
	_round(zone, Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if is_target else Color(0.07, 0.083, 0.10), border, 7, 2 if is_target else 0)

	var ids: Array = _relief[role] as Array
	if ids.is_empty():
		_text(Loc.t("rotation.drop_here_to_add") if role != "closer" else Loc.t("rotation.drop_here"), Vector2(zone.position.x + 12, zone.position.y + zone.size.y * 0.62), 12, FAINT)
		return
	var cx: float = zone.position.x + 10.0
	var cy: float = zone.position.y + 4.0
	for id_value in ids:
		var record: PSPlayerSeasonRecord = _record_by_id(int(id_value))
		if record == null:
			continue
		var w: float = _chip_width(record)
		if cx + w > zone.end.x - 8.0 and cx > zone.position.x + 10.0:
			cx = zone.position.x + 10.0
			cy += CHIP_H + CHIP_GAP
		var chip_rect: Rect2 = Rect2(cx, cy, w, CHIP_H)
		_draw_chip_player(chip_rect, record)
		_chip_hits.append({"rect": chip_rect, "role": role, "record": record})
		cx += w + 6.0


# チップ内の文字列。#背番号 (無ければ空) と 防/登板 の補足。
func _chip_jersey_text(record: PSPlayerSeasonRecord) -> String:
	return "#%d" % record.jersey_number if record.jersey_number > 0 else ""


func _chip_stat_text(record: PSPlayerSeasonRecord) -> String:
	return Loc.t("rotation.chip_stat", {"era": _era_str(record), "games": record.pitcher_stats.games})


# チップ幅: 疲労ドット + #背番号 + 名前 + 総合ピル + 防/登板 を順に並べた長さ。
func _chip_width(record: PSPlayerSeasonRecord) -> float:
	var jersey: String = _chip_jersey_text(record)
	var w: float = 8.0 + 10.0
	if not jersey.is_empty():
		w += _measure(jersey, 10) + 4.0
	w += _measure(record.name, 11) + 8.0
	w += 26.0 + 6.0
	w += _measure(_chip_stat_text(record), 10) + 8.0
	return w


# リリーフ投手チップ: [疲労ドット] #背番号 名前 [総合ピル] 防/登板。
func _draw_chip_player(rect: Rect2, record: PSPlayerSeasonRecord) -> void:
	_round(rect, PANEL_3, BORDER_SOFT, 6, 1)
	var base_y: float = rect.position.y + rect.size.y * 0.7
	var tx: float = rect.position.x + 8.0
	var pct: int = _fatigue_pct(record)
	_dot(Vector2(tx + 2.0, rect.position.y + rect.size.y * 0.5), 3.5, _fatigue_dot_color(pct))
	tx += 10.0
	var jersey: String = _chip_jersey_text(record)
	if not jersey.is_empty():
		var jersey_w: float = _measure(jersey, 10)
		_text(jersey, Vector2(tx, base_y), 10, FAINT, jersey_w + 2.0)
		tx += jersey_w + 4.0
	var name_w: float = _measure(record.name, 11)
	_text(record.name, Vector2(tx, base_y), 11, TEXT, name_w + 2.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	tx += name_w + 8.0
	var ev: int = PlayerValueEvaluator.overall_score(record)
	_round(Rect2(tx, rect.position.y + 3.0, 26.0, rect.size.y - 6.0), PANEL_2, _tier_color(float(ev)), 4, 1)
	_text(str(ev), Vector2(tx, base_y - 0.5), 10, TEXT, 26.0, HORIZONTAL_ALIGNMENT_CENTER, true)
	tx += 26.0 + 6.0
	var stat_text: String = _chip_stat_text(record)
	_text(stat_text, Vector2(tx, base_y), 10, MUTED, _measure(stat_text, 10) + 2.0)


func _draw_drag_ghost() -> void:
	if not _drag_active or _drag_record == null:
		return
	var w: float = 220.0 * _scale_f
	var h: float = 30.0 * _scale_f
	var pos: Vector2 = _drag_pos + Vector2(14.0 * _scale_f, -h * 0.5)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.92)
	style.set_corner_radius_all(int(7.0 * _scale_f))
	draw_style_box(style, Rect2(pos, Vector2(w, h)))
	draw_string(_font, pos + Vector2(12.0 * _scale_f, h * 0.66), _drag_record.name, HORIZONTAL_ALIGNMENT_LEFT, w - 20.0 * _scale_f, max(9, int(round(13.0 * _scale_f))), TEXT)


func _drop_match(target: Dictionary) -> bool:
	var cur: Dictionary = _drop_target_at(_to_base(_drag_pos))
	if str(cur.get("type", "")) != str(target.get("type", "")):
		return false
	if target.has("index"):
		return int(cur.get("index", -1)) == int(target["index"])
	if target.has("role"):
		return str(cur.get("role", "")) == str(target["role"])
	return true


# ============================================================ chrome buttons

func _build_chrome_buttons() -> void:
	_build_nav_buttons()
	_add_button("auto", Loc.t("common.auto_arrange"), Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", Loc.t("common.reset"), Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", Loc.t("common.save"), Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")


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

	_load_pitcher_pool(season)
	_preview = GameSimulator.preview_rotation(season, _team_id)
	var saved: Dictionary = season.get_rotation(_team_id)

	var rotation_ids: Array = []
	if saved.is_empty() or (saved.get("pitcher_ids", []) as Array).is_empty():
		if bool(_preview.get("ok", false)):
			rotation_ids = (_preview.get("pitcher_ids", []) as Array).duplicate()
	else:
		rotation_ids = (saved.get("pitcher_ids", []) as Array).duplicate()
	_apply_rotation_ids(rotation_ids)

	var relief_roles: Dictionary = saved.get("relief_roles", {}) as Dictionary
	if relief_roles.is_empty():
		_relief = _auto_relief()
	else:
		_relief = _relief_from_roles(relief_roles)

	if saved.is_empty():
		_set_status(Loc.t("rotation.status.no_saved"), false)
	else:
		_set_status(Loc.t("rotation.status.showing_saved", {"day": SeasonCalendar.day_status_label(season, int(saved.get("updated_at_day", 0)))}), false)
	queue_redraw()


func _load_pitcher_pool(season: PSSeason) -> void:
	var records: Array = RecordStore.get_team_player_records(_team_id, season.year, season.season_number)
	var active: Array = TeamSetupBuilder.filter_by_active_roster(season, _team_id, records)
	if active.is_empty():
		active = records
	_active_pitchers = []
	for record_row in active:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.is_pitcher():
			_active_pitchers.append(record)
	# WAR / FIP はリーグ文脈が要るので season ごとに 1 回計算してキャッシュ。
	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	_war_by_id = {}
	for record_row in _active_pitchers:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		_war_by_id[record.player_id] = WarCalculator.season_war(record, ctx)


# ============================================================ rotation / relief model

func _apply_rotation_ids(ids: Array) -> void:
	for i in range(ROTATION_SIZE):
		_rotation_ids[i] = int(ids[i]) if i < ids.size() else 0


func _reliever_pool_sorted() -> Array:
	var pool: Array = []
	for record_row in _active_pitchers:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and not record.is_starter_pitcher():
			pool.append(record)
	pool.sort_custom(func(a, b) -> bool:
		return PitcherRoleModel.reliever_order_score(a) > PitcherRoleModel.reliever_order_score(b)
	)
	return pool


func _auto_relief() -> Dictionary:
	# 全リリーフを必ずいずれかの役割へ割り当てる (役割なしを作らない)。
	# クローザー=最良1人、セットアッパー=次2人、最下位1人をロング、残りをミドル。
	var pool: Array = _reliever_pool_sorted()
	var ids: Array = []
	for record_row in pool:
		ids.append((record_row as PSPlayerSeasonRecord).player_id)
	var out: Dictionary = {"long": [], "middle": [], "setup": [], "closer": []}
	var n: int = ids.size()
	if n >= 1:
		out["closer"] = [ids[0]]
	if n >= 2:
		out["setup"].append(ids[1])
	if n >= 3:
		out["setup"].append(ids[2])
	# 残り (index 3..n-1) のうち下位 2〜3人をロング、それ以外をミドルへ。
	if n >= 4:
		var remaining: Array = ids.slice(3, n)
		var long_n: int = min(3, remaining.size())
		for i in range(remaining.size()):
			if i >= remaining.size() - long_n:
				out["long"].append(remaining[i])
			else:
				out["middle"].append(remaining[i])
	return out


func _relief_from_roles(roles: Dictionary) -> Dictionary:
	var long_ids: Array = []
	for id_value in roles.get("long_ids", []) as Array:
		long_ids.append(int(id_value))
	var middle: Array = []
	for id_value in roles.get("middle_ids", []) as Array:
		middle.append(int(id_value))
	var setup: Array = []
	for id_value in roles.get("setup_ids", []) as Array:
		setup.append(int(id_value))
	var closer: Array = []
	if int(roles.get("closer_id", 0)) > 0:
		closer = [int(roles.get("closer_id", 0))]
	return {"long": long_ids, "middle": middle, "setup": setup, "closer": closer}


func _collect_relief_roles() -> Dictionary:
	var closer: Array = _relief["closer"] as Array
	return {
		"long_ids": (_relief["long"] as Array).duplicate(),
		"middle_ids": (_relief["middle"] as Array).duplicate(),
		"setup_ids": (_relief["setup"] as Array).duplicate(),
		"closer_id": int(closer[0]) if closer.size() > 0 else 0,
	}


func _closer_id() -> int:
	var closer: Array = _relief.get("closer", []) as Array
	return int(closer[0]) if closer.size() > 0 else 0


# ============================================================ auto / save

func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_rotation(season, _team_id)
	if not bool(preview.get("ok", false)):
		_set_status(Loc.t("common.auto_arrange_failed", {"reason": str(preview.get("message", ""))}), true)
		queue_redraw()
		return
	_preview = preview
	_apply_rotation_ids((preview.get("pitcher_ids", []) as Array).duplicate())
	_relief = _auto_relief()
	_set_status(Loc.t("common.auto_arrange_unsaved"), false)
	queue_redraw()


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		_set_status(Loc.t("common.cannot_save_before_season"), true)
		queue_redraw()
		return
	var stored: Dictionary = season.get_rotation(_team_id).duplicate(true)
	var ids: Array = []
	for value in _rotation_ids:
		ids.append(int(value))
	stored["pitcher_ids"] = ids
	stored["relief_roles"] = _collect_relief_roles()
	stored["auto_generated"] = false
	season.set_rotation(_team_id, stored)
	SaveService.save_state(AppState)
	_preview = GameSimulator.preview_rotation(season, _team_id)
	_set_status(Loc.t("common.saved_at", {"day": SeasonCalendar.day_status_label(season, season.current_day)}), false)
	queue_redraw()


# ============================================================ table helpers

func _sorted_table_rows(rotation_set: Dictionary, closer_id: int) -> Array:
	var rows: Array = _active_pitchers.duplicate()
	rows.sort_custom(func(a: PSPlayerSeasonRecord, b: PSPlayerSeasonRecord) -> bool:
		if _sort_key == "role":
			var ga: int = _role_group(a, rotation_set, closer_id)
			var gb: int = _role_group(b, rotation_set, closer_id)
			if ga != gb:
				return (ga < gb) if _sort_asc else (ga > gb)
			if ga == 0:
				var ia: int = _rotation_index(a.player_id)
				var ib: int = _rotation_index(b.player_id)
				return (ia < ib) if _sort_asc else (ia > ib)
			var eva: int = PlayerValueEvaluator.overall_score(a)
			var evb: int = PlayerValueEvaluator.overall_score(b)
			return (eva > evb) if _sort_asc else (eva < evb)
		var va = _pitcher_sort_val(a)
		var vb = _pitcher_sort_val(b)
		if va != vb:
			return (va < vb) if _sort_asc else (va > vb)
		return a.player_id < b.player_id
	)
	return rows


func _pitcher_sort_val(rec: PSPlayerSeasonRecord) -> Variant:
	match _sort_key:
		"name":
			return rec.name
		"hand":
			return rec.throwing_hand
		"age":
			return rec.age
		"fatigue":
			return _fatigue_pct(rec)
		"eval":
			return PlayerValueEvaluator.overall_score(rec)
		"war":
			return float((_war_by_id.get(rec.player_id, {}) as Dictionary).get("war", 0.0))
		"velo":
			return PlayerVisibleRatings.pitcher_velocity(rec)
		"stuff":
			return PlayerVisibleRatings.pitcher_stuff(rec)
		"ctrl":
			return PlayerVisibleRatings.pitcher_control(rec)
		"stam":
			return PlayerVisibleRatings.pitcher_stamina(rec)
		"g":
			return rec.pitcher_stats.games
		"w":
			return rec.pitcher_stats.wins
		"l":
			return rec.pitcher_stats.losses
		"sv":
			return rec.pitcher_stats.saves
		"hld":
			return rec.pitcher_stats.holds
		"ip":
			return rec.pitcher_stats.outs_pitched
		"era":
			return rec.pitcher_stats.era() if rec.pitcher_stats.outs_pitched > 0 else 99.0
		"fip":
			return float((_war_by_id.get(rec.player_id, {}) as Dictionary).get("fip", 99.0))
		"whip":
			return rec.pitcher_stats.whip() if rec.pitcher_stats.outs_pitched > 0 else 99.0
		"k9":
			return rec.pitcher_stats.strikeouts_per_nine() if rec.pitcher_stats.outs_pitched > 0 else 0.0
		_:
			return rec.player_id


func _role_group(record: PSPlayerSeasonRecord, rotation_set: Dictionary, closer_id: int) -> int:
	if record.player_id == closer_id:
		return 2
	if rotation_set.has(record.player_id) or (rotation_set.is_empty() and record.is_starter_pitcher()):
		return 0
	return 1


func _role_chip(record: PSPlayerSeasonRecord, rotation_set: Dictionary, closer_id: int) -> Dictionary:
	match _role_group(record, rotation_set, closer_id):
		0:
			return {"text": Loc.t("role.starter"), "color": PINK}
		2:
			return {"text": Loc.t("role.closer_short"), "color": CLOSER_RED}
		_:
			return {"text": Loc.t("role.middle_short"), "color": RED}


func _rotation_index(player_id: int) -> int:
	var idx: int = _rotation_ids.find(player_id)
	return idx if idx >= 0 else 999


func _rotation_id_set() -> Dictionary:
	var id_set: Dictionary = {}
	for value in _rotation_ids:
		if int(value) > 0:
			id_set[int(value)] = true
	return id_set


func _record_by_id(player_id: int) -> PSPlayerSeasonRecord:
	if player_id <= 0:
		return null
	for record_row in _active_pitchers:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return record
	return null


func _fatigue_pct(record: PSPlayerSeasonRecord) -> int:
	return clampi(int(round(float(record.fatigue) * 100.0 / float(GameSimulator.FATIGUE_MAX))), 0, 100)


func _era_str(record: PSPlayerSeasonRecord) -> String:
	var ps: PSPitcherStats = record.pitcher_stats
	return "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()


func _ip_str(ps: PSPitcherStats) -> String:
	if ps.outs_pitched <= 0:
		return "0"
	@warning_ignore("integer_division")
	return "%d.%d" % [ps.outs_pitched / 3, ps.outs_pitched % 3]


func _whip_str(ps: PSPitcherStats) -> String:
	return "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.whip()


func _k9_str(ps: PSPitcherStats) -> String:
	return "-.-" if ps.outs_pitched <= 0 else "%0.1f" % ps.strikeouts_per_nine()


func _fip_str(record: PSPlayerSeasonRecord) -> String:
	if record.pitcher_stats.outs_pitched <= 0:
		return "-.--"
	var w: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	return "%0.2f" % float(w.get("fip", 0.0)) if w.has("fip") else "-.--"


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error
