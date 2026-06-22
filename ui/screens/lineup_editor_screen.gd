extends "res://ui/components/dashboard_screen.gd"

# 打順・守備位置 画面 (2026-06-22 モック準拠でダッシュボード体裁へ刷新)。
# 枠サイズは投手起用法 (rotation_editor) と同一:
#   - 一軍登録野手 (TABLE_PANEL)          … 守備/選手/打/年齢/AVG/HR/OPS/主守備/サブ守備/評価 を自前描画
#   - スタメン / 打順 (ORDER_PANEL)        … 打順1〜9 のドロップ枠 (D&D で並べ替え)。DH 混在時のみ切替チップ
#   - 守備位置設定 (FIELD_PANEL)           … 守備図 (各ポジションへ D&D) + 控え守備配置 (補充優先リスト + 交代頻度)
# 配置操作は一覧/打順/守備図/控え 間の **ドラッグ&ドロップ**。
#
# データ:
#   - 打順 = season.set_lineup(team_id, dh, {batting_order:[{slot,position,player_id}]})
#   - 控え = season.fielder_usage.position_slots[pos] = {starter_id, sub_id(=控え1), sub_start_interval, backup_ids[]}
#     backup_ids が「控え=補充優先リスト」。defense_alignment_service が usage の backup_ids を最優先で使う。
#   - 「自動編成」= AI 任せと同義 (preview_lineup で全自動埋め)。専用の常時 AI トグルは置かない。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const VIOLET: Color = Color(0.64, 0.52, 0.96)
const PINK: Color = Color(0.94, 0.46, 0.66)

# --- レイアウト (base 座標, rotation_editor と同一枠) ---
const TABLE_PANEL: Rect2 = Rect2(262, 104, 1638, 528)
const ORDER_PANEL: Rect2 = Rect2(262, 648, 800, 408)
const FIELD_PANEL: Rect2 = Rect2(1078, 648, 822, 408)

# 一軍登録野手 列 (投手起用法の一覧を踏襲。R=右寄せ基準)。
# 守備badge(=役割chip) / 背番号 / 選手 / 年齢 / 疲労 / 評価 / WAR / 表示能力(巧打長打走守肩) / 成績(打撃)
const C_BADGE_X: float = 280.0
const C_JERSEY_X: float = 340.0
const C_NAME_X: float = 366.0
const C_AGE_R: float = 552.0
const C_FAT_DOT_X: float = 574.0
const C_FAT_TX: float = 588.0
const C_EVAL_R: float = 690.0
const C_WAR_R: float = 760.0
# 表示能力 (巧打/長打/走力/守備/肩力/選球)
const C_MEET_R: float = 884.0
const C_POW_R: float = 931.0
const C_SPD_R: float = 978.0
const C_DEF_R: float = 1025.0
const C_ARM_R: float = 1072.0
const C_EYE_R: float = 1119.0
# 成績 (打撃)
const C_G_R: float = 1190.0
const C_AVG_R: float = 1268.0
const C_HR_R: float = 1326.0
const C_RBI_R: float = 1390.0
const C_SB_R: float = 1450.0
const C_OBP_R: float = 1542.0
const C_OPS_R: float = 1630.0
const C_WOBA_R: float = 1718.0
const C_WRC_R: float = 1788.0
const C_OAA_R: float = 1864.0

# スタメン/打順 列
const O_NUM_CX: float = 292.0
const O_BADGE_X: float = 320.0
const O_NAME_X: float = 372.0
const O_BATS_CX: float = 566.0
const O_AVG_R: float = 678.0
const O_HR_R: float = 744.0
const O_RBI_R: float = 838.0
const O_OPS_R: float = 944.0

const PITCHER_SLOT_INDEX: int = 8
const DEF_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9]
const MAX_BENCH: int = 3
const SUB_INTERVAL_FATIGUE_EMERGENCY: int = -1
const SUB_INTERVAL_OPTIONS: Array = [SUB_INTERVAL_FATIGUE_EMERGENCY, 2, 3, 4, 5, 6, 7, 10]
const CARD: Vector2 = Vector2(104, 34)

var _team_id: int = 0
var _dh_enabled: bool = false
var _dh_available: bool = false
var _non_dh_available: bool = false
var _fielders: Array = []                 # PSPlayerSeasonRecord (1軍登録野手)
var _war_by_id: Dictionary = {}           # player_id -> season_war 結果 dict
var _slots: Array = []                    # size 9: {"pid": int, "pos": int} = 打順i (index 0..8)
var _backups: Dictionary = {}             # pos(2-9) -> Array[int]
var _intervals: Dictionary = {}           # pos(2-9) -> int (sub_start_interval)
var _rotation_pitcher_id: int = 0
var _rotation_pitcher_name: String = "(未定)"
var _status_text: String = ""
var _status_is_error: bool = false
var _field_centers: Dictionary = {}

# ドラッグ / クリック状態
var _pending: Dictionary = {}             # {record, origin}
var _press_screen: Vector2 = Vector2.ZERO
var _drag_active: bool = false
var _drag_record: PSPlayerSeasonRecord = null
var _drag_origin: Dictionary = {}
var _drag_pos: Vector2 = Vector2.ZERO
var _hover_record: PSPlayerSeasonRecord = null

# ヒット矩形 (_draw で確定)
var _table_hits: Array = []               # {rect, record}
var _order_hits: Array = []               # {rect, index}
var _field_hits: Array = []               # {rect, pos, draggable}
var _bench_cell_hits: Array = []          # {rect, pos}
var _bench_chip_hits: Array = []          # {rect, pos, pid}
var _freq_hits: Array = []                # {rect, pos}


func _ready() -> void:
	_init_chrome()
	_field_centers = {
		8: Vector2(1489, 712), 7: Vector2(1298, 736), 9: Vector2(1686, 736),
		6: Vector2(1404, 778), 4: Vector2(1566, 778),
		5: Vector2(1334, 816), 3: Vector2(1646, 816),
		2: Vector2(1489, 848),
	}
	for i in range(9):
		_slots.append({"pid": 0, "pos": 0})
	_build_chrome_buttons()
	_load_initial_state()
	_layout_buttons()
	queue_redraw()


# ============================================================ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_update_transform()
		var base_pos: Vector2 = _to_base(event.position)
		if event.pressed:
			_press_screen = event.position
			_pending = _pick_draggable(base_pos)
		else:
			if _drag_active:
				_finish_drag(base_pos)
			else:
				_handle_click(base_pos)
			_pending = {}
	elif event is InputEventMouseMotion:
		if _drag_active:
			_drag_pos = event.position
			queue_redraw()
		elif not _pending.is_empty() and event.position.distance_to(_press_screen) > 6.0:
			_start_drag()
		else:
			_update_transform()
			var rec: PSPlayerSeasonRecord = _table_record_at(_to_base(event.position))
			if rec != _hover_record:
				_hover_record = rec
				queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


func _pick_draggable(base_pos: Vector2) -> Dictionary:
	var rec: PSPlayerSeasonRecord = _table_record_at(base_pos)
	if rec != null:
		return {"record": rec, "origin": {"type": "table"}}
	for hit_value in _bench_chip_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			var r: PSPlayerSeasonRecord = _record_by_id(int(hit["pid"]))
			if r != null:
				return {"record": r, "origin": {"type": "bench", "pos": int(hit["pos"])}}
	for hit_value in _order_hits:
		var hit: Dictionary = hit_value as Dictionary
		var i: int = int(hit["index"])
		if (hit["rect"] as Rect2).has_point(base_pos) and not _is_fixed_pitcher(i) and int(_slots[i]["pid"]) > 0:
			return {"record": _record_by_id(int(_slots[i]["pid"])), "origin": {"type": "order", "index": i}}
	for hit_value in _field_hits:
		var hit: Dictionary = hit_value as Dictionary
		if not bool(hit["draggable"]):
			continue
		if (hit["rect"] as Rect2).has_point(base_pos):
			var pos: int = int(hit["pos"])
			var pid: int = _player_at_position(pos)
			if pid > 0:
				return {"record": _record_by_id(pid), "origin": {"type": "field", "pos": pos}}
	return {}


func _start_drag() -> void:
	if _pending.is_empty():
		return
	_drag_record = _pending["record"] as PSPlayerSeasonRecord
	if _drag_record == null:
		_pending = {}
		return
	_drag_origin = _pending["origin"] as Dictionary
	_drag_active = true
	_drag_pos = _press_screen
	queue_redraw()


func _finish_drag(base_pos: Vector2) -> void:
	var pid: int = _drag_record.player_id
	var origin: Dictionary = _drag_origin
	var target: Dictionary = _drop_target_at(base_pos)
	match str(target.get("type", "")):
		"order":
			_place_in_order(int(target["index"]), pid)
		"field":
			_assign_position(int(target["pos"]), pid)
		"bench":
			_add_bench(int(target["pos"]), pid)
		"table":
			_remove_from_origin(origin, pid)
		_:
			pass
	_drag_active = false
	_drag_record = null
	_drag_origin = {}
	_refresh_status()
	queue_redraw()


func _drop_target_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _order_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos) and not _is_fixed_pitcher(int(hit["index"])):
			return {"type": "order", "index": int(hit["index"])}
	for hit_value in _field_hits:
		var hit: Dictionary = hit_value as Dictionary
		if bool(hit["draggable"]) and (hit["rect"] as Rect2).has_point(base_pos):
			return {"type": "field", "pos": int(hit["pos"])}
	for hit_value in _bench_cell_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return {"type": "bench", "pos": int(hit["pos"])}
	if TABLE_PANEL.has_point(base_pos):
		return {"type": "table"}
	return {}


func _handle_click(base_pos: Vector2) -> void:
	for hit_value in _freq_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			_cycle_interval(int(hit["pos"]))
			_refresh_status()
			queue_redraw()
			return


# ============================================================ lineup ops

func _is_fixed_pitcher(i: int) -> bool:
	return (not _dh_enabled) and i == PITCHER_SLOT_INDEX


func _slot_index_with_pid(pid: int) -> int:
	for i in range(_slots.size()):
		if int(_slots[i]["pid"]) == pid:
			return i
	return -1


func _slot_index_with_pos(pos: int) -> int:
	for i in range(_slots.size()):
		if int(_slots[i]["pos"]) == pos:
			return i
	return -1


func _player_at_position(pos: int) -> int:
	var idx: int = _slot_index_with_pos(pos)
	return int(_slots[idx]["pid"]) if idx >= 0 else 0


func _place_in_order(i: int, pid: int) -> void:
	if _is_fixed_pitcher(i):
		return
	var j: int = _slot_index_with_pid(pid)
	if j == i:
		return
	if j >= 0 and not _is_fixed_pitcher(j):
		# 既にスタメン → 打順入れ替え (打順位置を交換、守備位置は各選手に随伴)
		var tmp: Dictionary = _slots[i]
		_slots[i] = _slots[j]
		_slots[j] = tmp
	else:
		# 一覧からの投入 → その打順の選手を差し替え (守備位置は枠を継承)
		_slots[i] = {"pid": pid, "pos": int(_slots[i]["pos"])}


func _assign_position(pos: int, pid: int) -> void:
	var k: int = _slot_index_with_pos(pos)
	if k < 0:
		return
	var j: int = _slot_index_with_pid(pid)
	if j == k:
		return
	if j >= 0:
		# 既にスタメン → 守備位置だけ交換 (打順はそのまま)
		var tmp: int = int(_slots[j]["pos"])
		_slots[j]["pos"] = int(_slots[k]["pos"])
		_slots[k]["pos"] = tmp
	else:
		# 一覧から守備位置へ → その守備の選手を差し替え
		_slots[k]["pid"] = pid


func _add_bench(pos: int, pid: int) -> void:
	if not DEF_POSITIONS.has(pos):
		return
	if _player_at_position(pos) == pid:
		return
	var list: Array = _backups.get(pos, []) as Array
	list = list.duplicate()
	list.erase(pid)
	if list.size() >= MAX_BENCH:
		return
	list.append(pid)
	_backups[pos] = list
	if not _intervals.has(pos):
		_intervals[pos] = SUB_INTERVAL_FATIGUE_EMERGENCY


func _remove_from_origin(origin: Dictionary, pid: int) -> void:
	match str(origin.get("type", "")):
		"order":
			var i: int = int(origin["index"])
			if not _is_fixed_pitcher(i):
				_slots[i]["pid"] = 0
		"field":
			var idx: int = _slot_index_with_pos(int(origin["pos"]))
			if idx >= 0:
				_slots[idx]["pid"] = 0
		"bench":
			var list: Array = (_backups.get(int(origin["pos"]), []) as Array).duplicate()
			list.erase(pid)
			_backups[int(origin["pos"])] = list


func _cycle_interval(pos: int) -> void:
	var cur: int = int(_intervals.get(pos, SUB_INTERVAL_FATIGUE_EMERGENCY))
	var idx: int = SUB_INTERVAL_OPTIONS.find(cur)
	idx = (idx + 1) % SUB_INTERVAL_OPTIONS.size()
	_intervals[pos] = int(SUB_INTERVAL_OPTIONS[idx])


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

	_draw_shell("打順・守備位置", team, season)
	_draw_roster_table()
	_draw_order_panel()
	_draw_field_panel()
	_draw_status_bar()
	_draw_drag_ghost()


# --- 一軍登録野手 ---

func _draw_roster_table() -> void:
	_panel(TABLE_PANEL, "一軍登録野手")
	_text("下の打順・守備位置へドラッグ", Vector2(TABLE_PANEL.position.x + 196, TABLE_PANEL.position.y + 32), 12, FAINT)

	var hy: float = TABLE_PANEL.position.y + 60
	_text("守備", Vector2(C_BADGE_X, hy), 11, FAINT)
	_text("選手", Vector2(C_JERSEY_X, hy), 11, FAINT)
	_text_right("年齢", C_AGE_R, hy, 11, FAINT)
	_text("疲労", Vector2(C_FAT_DOT_X, hy), 11, FAINT)
	_text_right("評価", C_EVAL_R, hy, 11, FAINT)
	_text_right("WAR", C_WAR_R, hy, 11, FAINT)
	_text_right("巧打", C_MEET_R, hy, 11, FAINT)
	_text_right("長打", C_POW_R, hy, 11, FAINT)
	_text_right("走力", C_SPD_R, hy, 11, FAINT)
	_text_right("守備", C_DEF_R, hy, 11, FAINT)
	_text_right("肩力", C_ARM_R, hy, 11, FAINT)
	_text_right("選球", C_EYE_R, hy, 11, FAINT)
	_text_right("試合", C_G_R, hy, 11, FAINT)
	_text_right("打率", C_AVG_R, hy, 11, FAINT)
	_text_right("本", C_HR_R, hy, 11, FAINT)
	_text_right("打点", C_RBI_R, hy, 11, FAINT)
	_text_right("盗塁", C_SB_R, hy, 11, FAINT)
	_text_right("出塁率", C_OBP_R, hy, 11, FAINT)
	_text_right("OPS", C_OPS_R, hy, 11, FAINT)
	_text_right("wOBA", C_WOBA_R, hy, 11, FAINT)
	_text_right("wRC+", C_WRC_R, hy, 11, FAINT)
	_text_right("OAA", C_OAA_R, hy, 11, FAINT)
	_line(Vector2(C_BADGE_X, TABLE_PANEL.position.y + 70), Vector2(TABLE_PANEL.end.x - 18, TABLE_PANEL.position.y + 70), BORDER_SOFT, 1.0)

	_table_hits = []
	var y: float = TABLE_PANEL.position.y + 94
	var row_h: float = 27.0
	var max_rows: int = int((TABLE_PANEL.end.y - 12 - y) / row_h)
	var shown: int = 0
	for record_value in _fielders:
		if shown >= max_rows:
			break
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var row_rect: Rect2 = Rect2(C_BADGE_X - 8, y - 18, TABLE_PANEL.end.x - 18 - (C_BADGE_X - 8), row_h)
		var in_lineup: bool = _slot_index_with_pid(record.player_id) >= 0
		if record == _hover_record or record == _drag_record:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.10), Color.TRANSPARENT, 5, 0)
		if in_lineup:
			_round(Rect2(C_BADGE_X - 8, y - 16, 3, 20), GREEN, Color.TRANSPARENT, 1, 0)
		_draw_roster_row(record, y)
		_table_hits.append({"rect": row_rect, "record": record})
		y += row_h
		shown += 1

	if _fielders.is_empty():
		_text("一軍に登録された野手がいません", Vector2(C_BADGE_X, y + 6), 13, MUTED)


func _draw_roster_row(record: PSPlayerSeasonRecord, y: float) -> void:
	var bs: PSBatterStats = record.batter_stats
	var ad: PSAdvancedStats = record.advanced_stats
	var played: bool = ad != null and ad.plate_appearances > 0
	_pos_badge(Rect2(C_BADGE_X, y - 16, 40, 21), record.position)

	if record.jersey_number > 0:
		_text(str(record.jersey_number), Vector2(C_JERSEY_X, y), 12, FAINT)
	_text(record.name, Vector2(C_NAME_X, y), 14, TEXT, C_AGE_R - 46 - C_NAME_X)
	_text_right(str(record.age), C_AGE_R, y, 13, MUTED)

	var pct: int = _fatigue_pct(record)
	_dot(Vector2(C_FAT_DOT_X + 4, y - 4), 5, _fatigue_color(pct))
	_text("%d%%" % pct, Vector2(C_FAT_TX, y), 13, TEXT)

	var ev: int = PlayerValueEvaluator.overall_score(record)
	_text_right(str(ev), C_EVAL_R, y, 14, _grade_color(ev))
	_text_right(_war_str(record), C_WAR_R, y, 13, _war_color(record))

	_draw_rating(PlayerVisibleRatings.fielder_contact(record), C_MEET_R, y)
	_draw_rating(PlayerVisibleRatings.fielder_power(record), C_POW_R, y)
	_draw_rating(PlayerVisibleRatings.fielder_speed(record), C_SPD_R, y)
	_draw_rating(PlayerVisibleRatings.fielder_defense(record), C_DEF_R, y)
	_draw_rating(PlayerVisibleRatings.fielder_arm(record), C_ARM_R, y)
	_draw_rating(PlayerVisibleRatings.fielder_discipline(record), C_EYE_R, y)

	_text_right(str(bs.games), C_G_R, y, 13, MUTED)
	_text_right(_rate_short(bs.batting_average()), C_AVG_R, y, 13, TEXT)
	_text_right(str(bs.home_runs), C_HR_R, y, 13, TEXT)
	_text_right(str(bs.runs_batted_in), C_RBI_R, y, 13, MUTED)
	_text_right(str(bs.stolen_bases), C_SB_R, y, 13, MUTED)
	_text_right(_rate_short(bs.on_base_percentage()), C_OBP_R, y, 13, MUTED)
	_text_right(_rate_short(bs.ops()), C_OPS_R, y, 13, TEXT)
	_text_right(_rate_short(ad.woba()) if played else "-", C_WOBA_R, y, 13, MUTED)
	_text_right(str(int(round(ad.wrc_plus()))) if played else "-", C_WRC_R, y, 13, MUTED)
	_text_right(_oaa_str(ad) if played else "-", C_OAA_R, y, 13, _oaa_color(ad) if played else MUTED)


func _draw_rating(value: int, right_x: float, y: float) -> void:
	_text_right(str(value), right_x, y, 13, _grade_color(value))


# --- スタメン / 打順 ---

func _draw_order_panel() -> void:
	_panel(ORDER_PANEL, "スタメン / 打順")
	_text("ドラッグ&ドロップで打順を変更できます", Vector2(ORDER_PANEL.position.x + 158, ORDER_PANEL.position.y + 32), 12, FAINT)

	var hy: float = ORDER_PANEL.position.y + 58
	_text("打順", Vector2(O_NUM_CX - 16, hy), 11, FAINT)
	_text("守備", Vector2(O_BADGE_X, hy), 11, FAINT)
	_text("選手", Vector2(O_NAME_X, hy), 11, FAINT)
	_text("打", Vector2(O_BATS_CX - 8, hy), 11, FAINT)
	_text_right("AVG", O_AVG_R, hy, 11, FAINT)
	_text_right("HR", O_HR_R, hy, 11, FAINT)
	_text_right("打点", O_RBI_R, hy, 11, FAINT)
	_text_right("OPS", O_OPS_R, hy, 11, FAINT)
	_line(Vector2(O_NUM_CX - 16, ORDER_PANEL.position.y + 66), Vector2(ORDER_PANEL.end.x - 16, ORDER_PANEL.position.y + 66), BORDER_SOFT, 1.0)

	_order_hits = []
	var row_h: float = 32.0
	for i in range(9):
		var top: float = ORDER_PANEL.position.y + 74 + float(i) * row_h
		var baseline: float = top + 21.0
		var row_rect: Rect2 = Rect2(O_NUM_CX - 20, top, ORDER_PANEL.end.x - 16 - (O_NUM_CX - 20), row_h - 2)
		var is_target: bool = _drag_active and _is_order_target(i)
		if is_target:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), BLUE, 6, 1)
		_text("%d" % (i + 1), Vector2(O_NUM_CX - 14, baseline), 15, TEXT, 28, HORIZONTAL_ALIGNMENT_CENTER)
		_draw_order_row(i, baseline)
		_order_hits.append({"rect": row_rect, "index": i})

	_text("DHは打順のどこでも設定できます", Vector2(ORDER_PANEL.position.x + 18, ORDER_PANEL.end.y - 16), 12, FAINT)


func _draw_order_row(i: int, baseline: float) -> void:
	var slot: Dictionary = _slots[i]
	var pos: int = int(slot["pos"])
	if _is_fixed_pitcher(i):
		_pos_badge(Rect2(O_BADGE_X, baseline - 16, 38, 21), 1)
		_text("%s (ローテ)" % _rotation_pitcher_name, Vector2(O_NAME_X, baseline), 14, MUTED, O_BATS_CX - 60 - O_NAME_X)
		return
	if pos > 0:
		_pos_badge(Rect2(O_BADGE_X, baseline - 16, 38, 21), pos)
	var pid: int = int(slot["pid"])
	if pid <= 0:
		_text("(未設定)", Vector2(O_NAME_X, baseline), 14, FAINT, O_BATS_CX - 60 - O_NAME_X)
		return
	var record: PSPlayerSeasonRecord = _record_by_id(pid)
	if record == null:
		_text("(未設定)", Vector2(O_NAME_X, baseline), 14, FAINT)
		return
	var bs: PSBatterStats = record.batter_stats
	_text(record.name, Vector2(O_NAME_X, baseline), 14, TEXT, O_BATS_CX - 60 - O_NAME_X)
	_text(_bats(record), Vector2(O_BATS_CX - 8, baseline), 13, MUTED, 24, HORIZONTAL_ALIGNMENT_CENTER)
	_text_right(_rate_short(bs.batting_average()), O_AVG_R, baseline, 13, TEXT)
	_text_right(str(bs.home_runs), O_HR_R, baseline, 13, TEXT)
	_text_right(str(bs.runs_batted_in), O_RBI_R, baseline, 13, MUTED)
	_text_right(_rate_short(bs.ops()), O_OPS_R, baseline, 13, TEXT)


# --- 守備位置設定 + 控え ---

func _draw_field_panel() -> void:
	_panel(FIELD_PANEL, "守備位置設定")
	_text("一軍登録野手から各枠へドラッグ", Vector2(FIELD_PANEL.position.x + 168, FIELD_PANEL.position.y + 32), 12, FAINT)

	_draw_field_backdrop()

	_field_hits = []
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		_draw_field_card(_field_centers[pos] as Vector2, pos, true)
	# 余剰枠: DH (打撃のみ・D&D可) もしくは 投 (ローテ・固定)。
	# 守備位置外なので右端、一塁〜捕手あたりの高さに置く。
	var extra_center: Vector2 = Vector2(1820, 824)
	if _dh_enabled:
		_draw_field_card(extra_center, 10, true)
	else:
		_draw_field_card(extra_center, 1, false)

	_draw_bench_grid()


func _draw_field_backdrop() -> void:
	# 内野ダイヤと2本のファウルラインを淡く描き、守備図だと一目で分かるようにする。
	var home: Vector2 = Vector2(1489, 866)
	var b1: Vector2 = Vector2(1582, 800)
	var b2: Vector2 = Vector2(1489, 736)
	var b3: Vector2 = Vector2(1396, 800)
	var grass: Color = Color(0.13, 0.22, 0.16, 0.55)
	_line(home, Vector2(1252, 700), grass, 1.5)
	_line(home, Vector2(1726, 700), grass, 1.5)
	_line(home, b1, BORDER_SOFT, 1.0)
	_line(b1, b2, BORDER_SOFT, 1.0)
	_line(b2, b3, BORDER_SOFT, 1.0)
	_line(b3, home, BORDER_SOFT, 1.0)


func _draw_field_card(center: Vector2, pos: int, draggable: bool) -> void:
	var rect: Rect2 = Rect2(center - CARD * 0.5, CARD)
	var is_target: bool = _drag_active and draggable and _is_field_target(pos)
	var border: Color = BLUE if is_target else BORDER
	var bg: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.16) if is_target else PANEL_2
	_round(rect, bg, border, 7, 2 if is_target else 1)
	_pos_badge(Rect2(rect.position.x + 5, rect.position.y + 7, 24, 20), pos)
	var name_x: float = rect.position.x + 34
	var name_w: float = rect.size.x - 40
	var baseline: float = rect.position.y + rect.size.y * 0.66
	var pid: int = 0
	if pos == 1:
		_text(_rotation_pitcher_name, Vector2(name_x, baseline), 12, MUTED, name_w)
	else:
		pid = _player_at_position(pos)
		if pid > 0:
			var record: PSPlayerSeasonRecord = _record_by_id(pid)
			_text(record.name if record != null else "?", Vector2(name_x, baseline), 12, TEXT, name_w)
		else:
			_text("未設定", Vector2(name_x, baseline), 12, FAINT, name_w)
	_field_hits.append({"rect": rect, "pos": pos, "draggable": draggable})


func _draw_bench_grid() -> void:
	_bench_cell_hits = []
	_bench_chip_hits = []
	_freq_hits = []
	var top: float = 868.0
	_text("控え守備配置  (上から補充優先 / 頻度クリックで変更)", Vector2(FIELD_PANEL.position.x + 18, top), 12, MUTED)
	var grid_left: float = 1094.0
	var grid_right: float = 1886.0
	var col_w: float = (grid_right - grid_left) / float(DEF_POSITIONS.size())
	var header_y: float = top + 26.0
	for c in range(DEF_POSITIONS.size()):
		var pos: int = int(DEF_POSITIONS[c])
		var cx: float = grid_left + float(c) * col_w
		var inner: float = col_w - 8.0
		_pos_badge(Rect2(cx + (inner - 34) * 0.5 + 4, header_y, 34, 19), pos)
		var list: Array = _backups.get(pos, []) as Array
		var cell_top: float = header_y + 26.0
		for r in range(MAX_BENCH):
			var cell_rect: Rect2 = Rect2(cx + 4, cell_top + float(r) * 27.0, inner, 24)
			var is_target: bool = _drag_active and _is_bench_target(pos)
			if r < list.size():
				var pid: int = int(list[r])
				var record: PSPlayerSeasonRecord = _record_by_id(pid)
				_round(cell_rect, PANEL_3, BORDER_SOFT, 5, 1)
				_text(record.name if record != null else "?", Vector2(cell_rect.position.x + 6, cell_rect.position.y + 17), 12, TEXT, cell_rect.size.x - 10)
				_bench_chip_hits.append({"rect": cell_rect, "pos": pos, "pid": pid})
			else:
				var bg: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if is_target else Color(0.07, 0.083, 0.10)
				_round(cell_rect, bg, BLUE if is_target else BORDER_SOFT, 5, 1)
				if r == list.size():
					_text("控え%d" % (r + 1), Vector2(cell_rect.position.x + 6, cell_rect.position.y + 17), 11, FAINT)
		var zone: Rect2 = Rect2(cx + 4, cell_top, inner, 27.0 * float(MAX_BENCH) - 3.0)
		_bench_cell_hits.append({"rect": zone, "pos": pos})
		# 頻度 (交代間隔) — クリックで循環
		var freq_rect: Rect2 = Rect2(cx + 4, cell_top + 27.0 * float(MAX_BENCH) + 2.0, inner, 20)
		_round(freq_rect, PANEL, BORDER_SOFT, 5, 1)
		_text(_interval_label(int(_intervals.get(pos, SUB_INTERVAL_FATIGUE_EMERGENCY))), Vector2(freq_rect.position.x, freq_rect.position.y + 15), 11, MUTED, freq_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		_freq_hits.append({"rect": freq_rect, "pos": pos})


func _draw_status_bar() -> void:
	var y: float = 1072.0
	var x: float = TABLE_PANEL.position.x
	x = _status_item(x, y, "打順", _order_ok())
	x = _status_item(x, y, "守備位置", _defense_ok())
	x = _status_item(x, y, "控え配置", true)
	var unset: int = _unset_count()
	if unset > 0:
		_dot(Vector2(x + 6, y - 4), 5, AMBER)
		_text("未設定: %d枠" % unset, Vector2(x + 18, y), 13, AMBER)
		x += 18 + _measure("未設定: %d枠" % unset, 13) + 26
	_dot(Vector2(x + 6, y - 4), 5, BLUE)
	_text("DH: %s" % ("使用" if _dh_enabled else "なし"), Vector2(x + 18, y), 13, MUTED)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(FIELD_PANEL.end.x - _measure(_status_text, 13) - 4, y), 13, RED if _status_is_error else MUTED)


func _status_item(x: float, y: float, label: String, ok: bool) -> float:
	_dot(Vector2(x + 6, y - 4), 5, GREEN if ok else RED)
	var text: String = "%s: %s" % [label, "OK" if ok else "要確認"]
	_text(text, Vector2(x + 18, y), 13, TEXT if ok else RED)
	return x + 18 + _measure(text, 13) + 26


func _draw_drag_ghost() -> void:
	if not _drag_active or _drag_record == null:
		return
	var w: float = 200.0 * _scale_f
	var h: float = 28.0 * _scale_f
	var pos: Vector2 = _drag_pos + Vector2(14.0 * _scale_f, -h * 0.5)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.92)
	style.set_corner_radius_all(int(7.0 * _scale_f))
	draw_style_box(style, Rect2(pos, Vector2(w, h)))
	draw_string(_font, pos + Vector2(12.0 * _scale_f, h * 0.66), _drag_record.name, HORIZONTAL_ALIGNMENT_LEFT, w - 20.0 * _scale_f, max(9, int(round(13.0 * _scale_f))), TEXT)


# --- ドラッグ強調判定 ---

func _is_order_target(i: int) -> bool:
	var t: Dictionary = _drop_target_at(_to_base(_drag_pos))
	return str(t.get("type", "")) == "order" and int(t.get("index", -1)) == i


func _is_field_target(pos: int) -> bool:
	var t: Dictionary = _drop_target_at(_to_base(_drag_pos))
	return str(t.get("type", "")) == "field" and int(t.get("pos", -1)) == pos


func _is_bench_target(pos: int) -> bool:
	var t: Dictionary = _drop_target_at(_to_base(_drag_pos))
	return str(t.get("type", "")) == "bench" and int(t.get("pos", -1)) == pos


# ============================================================ chrome buttons

func _build_chrome_buttons() -> void:
	_clear_buttons()
	_build_nav_buttons()
	_add_button("auto", "自動編成", Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", "リセット", Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", "保存", Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")
	if _dh_available and _non_dh_available:
		_add_button("mode_non_dh", "非DH", Rect2(854, 662, 86, 30),
			func() -> void: _on_mode_pressed(false), "chip_active" if not _dh_enabled else "chip")
		_add_button("mode_dh", "DH", Rect2(946, 662, 74, 30),
			func() -> void: _on_mode_pressed(true), "chip_active" if _dh_enabled else "chip")


func _on_mode_pressed(dh: bool) -> void:
	if dh == _dh_enabled:
		return
	_dh_enabled = dh
	_build_chrome_buttons()
	_load_lineup_for_mode()
	_layout_buttons()
	queue_redraw()


# ============================================================ data load / save

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

	_dh_available = AppState.is_dh_enabled_for_league("central") or AppState.is_dh_enabled_for_league("pacific")
	_non_dh_available = not AppState.is_dh_enabled_for_league("central") or not AppState.is_dh_enabled_for_league("pacific")
	if not _dh_available:
		_dh_enabled = false
	elif not _non_dh_available:
		_dh_enabled = true
	else:
		_dh_enabled = AppState.is_dh_enabled_for_league(team.league)

	_load_fielders(season)
	_load_backups(season)
	_build_chrome_buttons()
	_load_lineup_for_mode()
	# ボタンを作り直したので必ず再配置する (リセットボタンから直接呼ばれた時に
	# _layout_buttons が走らず全ボタンが原点に積み上がって崩れるのを防ぐ)。
	_layout_buttons()


func _load_fielders(season: PSSeason) -> void:
	var records: Array = _active_roster_records(season, RecordStore.get_team_player_records(_team_id, season.year, season.season_number))
	_fielders = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and not record.is_pitcher():
			_fielders.append(record)
	_fielders.sort_custom(func(a, b) -> bool:
		return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
	)

	# WAR はリーグ文脈が要るので season ごとに 1 回計算してキャッシュ (投手起用法と同型)。
	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	_war_by_id = {}
	for record_row in _fielders:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		_war_by_id[record.player_id] = WarCalculator.season_war(record, ctx)

	var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, false)
	if bool(preview.get("ok", false)):
		_rotation_pitcher_id = int(preview.get("pitcher_id", 0))
		var pitcher: PSPlayerSeasonRecord = _record_by_id_in(RecordStore.get_team_player_records(_team_id, season.year, season.season_number), _rotation_pitcher_id)
		_rotation_pitcher_name = pitcher.name if pitcher != null else "(未定)"
	else:
		_rotation_pitcher_id = 0
		_rotation_pitcher_name = "(未定)"


func _load_backups(season: PSSeason) -> void:
	_backups = {}
	_intervals = {}
	var usage: Dictionary = season.get_fielder_usage(_team_id)
	var slots: Dictionary = usage.get("position_slots", {}) as Dictionary
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		var slot: Dictionary = _usage_slot(slots, pos)
		var list: Array = []
		for id_value in slot.get("backup_ids", []) as Array:
			var pid: int = int(id_value)
			if pid > 0 and _is_fielder(pid):
				list.append(pid)
		# 旧セーブ後方互換: backup_ids 無し・sub_id ありなら控え1扱い。
		if list.is_empty() and int(slot.get("sub_id", 0)) > 0 and _is_fielder(int(slot.get("sub_id", 0))):
			list.append(int(slot.get("sub_id", 0)))
		if not list.is_empty():
			_backups[pos] = list
		var interval: int = int(slot.get("sub_start_interval", 0))
		if interval != 0:
			_intervals[pos] = interval


func _load_lineup_for_mode() -> void:
	var season: PSSeason = AppState.current_season
	for i in range(9):
		_slots[i] = {"pid": 0, "pos": 0}
	var lineup: Dictionary = season.get_lineup(_team_id, _dh_enabled)
	if lineup.is_empty() or (lineup.get("batting_order", []) as Array).is_empty():
		var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, _dh_enabled)
		if bool(preview.get("ok", false)):
			_apply_lineup(preview)
			_set_status("保存された打順がありません。自動編成を表示しています。", false)
		else:
			_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
	else:
		_apply_lineup(lineup)
		_set_status("保存された打順を表示しています (%s 更新)" % SeasonCalendar.day_status_label(season, int(lineup.get("updated_at_day", 0))), false)
	# 控え野手全員がどこかのポジションに所属するよう、保存済みに無い控えを補完する。
	_assign_all_reserves(false)
	_refresh_status()
	queue_redraw()


func _apply_lineup(lineup: Dictionary) -> void:
	for i in range(9):
		_slots[i] = {"pid": 0, "pos": 0}
	for entry_row in lineup.get("batting_order", []) as Array:
		var entry: Dictionary = entry_row as Dictionary
		var idx: int = int(entry.get("slot", 0)) - 1
		if idx < 0 or idx >= 9:
			continue
		_slots[idx] = {"pid": int(entry.get("player_id", 0)), "pos": int(entry.get("position", 0))}
	_normalize_slots()


func _normalize_slots() -> void:
	if _dh_enabled:
		return
	# 非DH: 投手 (pos==1) を必ず PITCHER_SLOT_INDEX に置く。
	var p: int = _slot_index_with_pos(1)
	if p < 0:
		_slots[PITCHER_SLOT_INDEX] = {"pid": 0, "pos": 1}
	elif p != PITCHER_SLOT_INDEX:
		var tmp: Dictionary = _slots[PITCHER_SLOT_INDEX]
		_slots[PITCHER_SLOT_INDEX] = _slots[p]
		_slots[p] = tmp
	_slots[PITCHER_SLOT_INDEX] = {"pid": 0, "pos": 1}


func _on_auto_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		return
	var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, _dh_enabled)
	if not bool(preview.get("ok", false)):
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		queue_redraw()
		return
	_apply_lineup(preview)
	_assign_all_reserves(true)
	_set_status("自動編成を表示中 (未保存)", false)
	_refresh_status()
	queue_redraw()


# 控え野手全員がどこかの守備位置に所属するよう割り当てる (重複可)。
# clear=true なら控えを作り直す (自動編成)。clear=false なら既存の控えを保持し、
# まだどこにも入っていない控え野手だけを補完する (読み込み時のギャップ埋め)。
# 各選手は適性のある守備位置のうち最も適性が高い枠へ。同枠が MAX_BENCH 埋まっていれば
# 次に適性が高い空き枠へ流す (どこも満杯なら主適性へ重複追加して必ず所属させる)。
func _assign_all_reserves(clear: bool) -> void:
	if clear:
		_backups = {}
	var starter_ids: Dictionary = {}
	for i in range(9):
		if int(_slots[i]["pid"]) > 0:
			starter_ids[int(_slots[i]["pid"])] = true

	# 既に控え入りしている選手は二重登録しない。
	var assigned: Dictionary = {}
	for list_value in _backups.values():
		for id_value in list_value as Array:
			assigned[int(id_value)] = true

	# 良い選手から先に主適性ポジションを確保できるよう overall_score 降順で処理。
	var reserves: Array = []
	for record_row in _fielders:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not starter_ids.has(record.player_id) and not assigned.has(record.player_id):
			reserves.append(record)
	reserves.sort_custom(func(a, b) -> bool:
		return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
	)

	for record_row in reserves:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var apt_positions: Array = _apt_positions_sorted(record)
		if apt_positions.is_empty():
			continue
		var target: int = int(apt_positions[0])
		for pos_value in apt_positions:
			if (_backups.get(int(pos_value), []) as Array).size() < MAX_BENCH:
				target = int(pos_value)
				break
		var list: Array = (_backups.get(target, []) as Array).duplicate()
		list.append(record.player_id)
		_backups[target] = list
		if not _intervals.has(target):
			_intervals[target] = SUB_INTERVAL_FATIGUE_EMERGENCY


# 適性 (>0) のある守備位置を適性降順で返す。
func _apt_positions_sorted(record: PSPlayerSeasonRecord) -> Array:
	var rows: Array = []
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		var apt: int = _position_aptitude(record, pos)
		if apt > 0:
			rows.append({"pos": pos, "apt": apt})
	rows.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["apt"]) > int((b as Dictionary)["apt"])
	)
	var out: Array = []
	for row_value in rows:
		out.append(int((row_value as Dictionary)["pos"]))
	return out


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
		queue_redraw()
		return
	var errors: Array = _validate()
	if not errors.is_empty():
		_set_status("保存失敗: %s" % " / ".join(errors), true)
		queue_redraw()
		return

	# 打順
	var batting_order: Array = []
	for i in range(9):
		var pos: int = int(_slots[i]["pos"])
		var pid: int = int(_slots[i]["pid"])
		if _is_fixed_pitcher(i):
			pos = 1
			pid = 0
		batting_order.append({"slot": i + 1, "position": pos, "player_id": pid})
	season.set_lineup(_team_id, _dh_enabled, {"batting_order": batting_order})

	# 守備起用 (スタメン守備 + 控え=backup_ids + 交代頻度)
	var position_slots: Dictionary = {}
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		var starter_id: int = _player_at_position(pos)
		var backup_ids: Array = (_backups.get(pos, []) as Array).duplicate()
		var interval: int = int(_intervals.get(pos, 0))
		if starter_id <= 0 and backup_ids.is_empty() and interval == 0:
			continue
		position_slots[str(pos)] = {
			"starter_id": starter_id,
			"sub_id": int(backup_ids[0]) if backup_ids.size() > 0 else 0,
			"sub_start_interval": interval,
			"backup_ids": backup_ids,
		}
	season.set_fielder_usage(_team_id, {"position_slots": position_slots})

	# 「保存=この編成を使う」。常時 AI 任せフラグは立てない。
	var team: PSTeam = GameDb.get_team(_team_id)
	if team != null and team.auto_lineup:
		team.auto_lineup = false
	SaveService.save_state(AppState)
	_set_status("保存しました (%s)" % SeasonCalendar.day_status_label(season, season.current_day), false)
	queue_redraw()


# ============================================================ validation / status

func _validate() -> Array:
	var errors: Array = []
	var positions_seen: Dictionary = {}
	var players_seen: Dictionary = {}
	var dh_count: int = 0
	for i in range(9):
		var pos: int = int(_slots[i]["pos"])
		var pid: int = int(_slots[i]["pid"])
		if _is_fixed_pitcher(i):
			continue
		if pos == 1:
			continue
		if pos == 10:
			dh_count += 1
		if pos >= 2 and pos <= 9:
			if positions_seen.has(pos):
				errors.append("%sが重複" % _short_pos(pos))
			positions_seen[pos] = true
		if pid > 0:
			if players_seen.has(pid):
				errors.append("%sが重複起用" % _player_name(pid))
			players_seen[pid] = true
	for pos_value in DEF_POSITIONS:
		if not positions_seen.has(int(pos_value)):
			errors.append("%s未設定" % _short_pos(int(pos_value)))
	if _dh_enabled and dh_count != 1:
		errors.append("DH枠が%d個" % dh_count)
	return errors


func _refresh_status() -> void:
	pass


func _order_ok() -> bool:
	for i in range(9):
		if _is_fixed_pitcher(i):
			continue
		if int(_slots[i]["pid"]) <= 0:
			return false
	if _dh_enabled:
		return _slot_index_with_pos(10) >= 0
	return true


func _defense_ok() -> bool:
	for pos_value in DEF_POSITIONS:
		if _player_at_position(int(pos_value)) <= 0:
			return false
	return true


func _unset_count() -> int:
	var n: int = 0
	for i in range(9):
		if _is_fixed_pitcher(i):
			continue
		if int(_slots[i]["pid"]) <= 0:
			n += 1
	return n


# ============================================================ helpers

func _active_roster_records(season: PSSeason, records: Array) -> Array:
	var active_ids: Dictionary = {}
	var roster: Dictionary = season.get_active_roster(_team_id)
	var ids: Array = roster.get("player_ids", []) as Array
	if ids.is_empty():
		var preview: Dictionary = GameSimulator.preview_active_roster(season, _team_id)
		if bool(preview.get("ok", false)):
			ids = preview.get("player_ids", []) as Array
	for id_value in ids:
		active_ids[int(id_value)] = true
	if active_ids.is_empty():
		return records
	var filtered: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_ids.has(record.player_id):
			filtered.append(record)
	return filtered


func _record_by_id(pid: int) -> PSPlayerSeasonRecord:
	if pid <= 0:
		return null
	for record_row in _fielders:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == pid:
			return record
	return null


func _record_by_id_in(records: Array, pid: int) -> PSPlayerSeasonRecord:
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.player_id == pid:
			return record
	return null


func _is_fielder(pid: int) -> bool:
	return _record_by_id(pid) != null


func _table_record_at(base_pos: Vector2) -> PSPlayerSeasonRecord:
	for hit_value in _table_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit["record"] as PSPlayerSeasonRecord
	return null


func _usage_slot(slots: Dictionary, pos: int) -> Dictionary:
	if slots.has(str(pos)):
		return slots.get(str(pos), {}) as Dictionary
	if slots.has(pos):
		return slots.get(pos, {}) as Dictionary
	return {}


func _player_name(pid: int) -> String:
	var record: PSPlayerSeasonRecord = _record_by_id(pid)
	return record.name if record != null else "ID %d" % pid


func _position_aptitude(record: PSPlayerSeasonRecord, pos: int) -> int:
	return PlayerValueEvaluator.position_aptitude(record, pos)


func _fatigue_pct(record: PSPlayerSeasonRecord) -> int:
	return clampi(int(round(float(record.fatigue) * 100.0 / float(GameSimulator.FATIGUE_MAX))), 0, 100)


func _fatigue_color(pct: int) -> Color:
	if pct < 25:
		return GREEN
	if pct < 50:
		return AMBER
	return RED


func _war_str(record: PSPlayerSeasonRecord) -> String:
	if record.advanced_stats == null or record.advanced_stats.plate_appearances <= 0:
		return "0.0"
	var w: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	return "%0.1f" % float(w.get("war", 0.0))


func _war_color(record: PSPlayerSeasonRecord) -> Color:
	if record.advanced_stats == null or record.advanced_stats.plate_appearances <= 0:
		return MUTED
	var war: float = float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0))
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	return TEXT


func _oaa_str(ad: PSAdvancedStats) -> String:
	var total: float = float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))
	return "%+0.1f" % total


func _oaa_color(ad: PSAdvancedStats) -> Color:
	var total: float = float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))
	if total > 0.5:
		return GREEN
	if total < -0.5:
		return RED
	return MUTED


func _bats(record: PSPlayerSeasonRecord) -> String:
	match record.batting_side:
		"L": return "左"
		"S": return "両"
		_: return "右"


func _interval_label(interval: int) -> String:
	if interval == SUB_INTERVAL_FATIGUE_EMERGENCY:
		return "頻度:疲労時"
	if interval <= 0:
		return "頻度:自動"
	return "頻度:%d戦" % interval


func _short_pos(pos: int) -> String:
	match pos:
		1: return "投"
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


# 守備位置の色は選手登録 (active_roster の _classify) と完全一致:
# 捕=BLUE / 内野(一二三遊)=AMBER / 外野(左中右)=GREEN。投=PINK / DH=VIOLET は守備位置外。
func _pos_color(pos: int) -> Color:
	match pos:
		1: return PINK
		2: return BLUE
		3, 4, 5, 6: return AMBER
		7, 8, 9: return GREEN
		10: return VIOLET
		_: return MUTED


# 選手登録と同一の見た目にするため基底の _chip (淡い塗り+色文字) を使う。
func _pos_badge(rect: Rect2, pos: int) -> void:
	_chip(rect, _short_pos(pos), _pos_color(pos))


func _grade_color(value: int) -> Color:
	if value >= 75:
		return BLUE
	if value >= 66:
		return GREEN
	if value >= 52:
		return TEXT
	return MUTED


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error
