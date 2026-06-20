extends "res://ui/components/dashboard_screen.gd"

# 投手起用法 画面 (2026-06-20 モック準拠で再構築 / 成績指標・D&D化 / 役割色・複数リリーフ /
# 高度指標(WAR/FIP/K9)追加・★削除・中5日削除・余白整理)。
# 共有基底 dashboard_screen の chrome の上に
#   - 一軍投手一覧 (役割/年齢/疲労/評価/WAR/全表示能力/成績指標 を自前描画)
#   - 先発ローテ (1〜6番手のドロップ枠)
#   - リリーフ起用法 (ロング/ミドル/セットアッパー=複数可, クローザー=1人 のレーン式ドロップゾーン)
# を構築する。配置操作は一覧/枠/チップ間の **ドラッグ&ドロップ**。
#
# 役割色: 先発=淡ピンク / 中継=赤 / 抑え=金。リリーフレーンは全て赤ベース (濃淡で区別)。
# リリーフ役割は season.get_rotation の relief_roles に保存 (long は複数=long_ids)。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const ROTATION_SIZE: int = 6

const PINK: Color = Color(0.94, 0.46, 0.66)        # 先発 (鮮やかなピンク)
const VIOLET: Color = Color(0.64, 0.52, 0.96)      # セットアッパー
const CLOSER_RED: Color = Color(0.92, 0.24, 0.30)  # 抑え/クローザー (赤系統)

# --- レイアウト (base 座標) ---
const TABLE_PANEL: Rect2 = Rect2(262, 104, 1638, 528)
const ROTATION_PANEL: Rect2 = Rect2(262, 648, 800, 408)
const RELIEF_PANEL: Rect2 = Rect2(1078, 648, 822, 408)

# 一覧の列 base x (R=右寄せ基準)。
const C_ROLE_X: float = 280.0
const C_JERSEY_X: float = 340.0
const C_NAME_X: float = 366.0
const C_AGE_R: float = 558.0
const C_FAT_DOT_X: float = 580.0
const C_FAT_TX: float = 594.0
const C_EVAL_R: float = 692.0
const C_WAR_R: float = 760.0
const C_VELO_R: float = 868.0
const C_STUFF_R: float = 926.0
const C_CTRL_R: float = 982.0
const C_STAM_R: float = 1038.0
const C_G_R: float = 1118.0
const C_W_R: float = 1170.0
const C_L_R: float = 1216.0
const C_SV_R: float = 1262.0
const C_HLD_R: float = 1308.0
const C_IP_R: float = 1396.0
const C_ERA_R: float = 1496.0
const C_FIP_R: float = 1596.0
const C_WHIP_R: float = 1700.0
const C_K9_R: float = 1804.0

# 先発ローテ列 (ROTATION_PANEL.x からの相対)。
const R_NUM_X: float = 16.0
const R_SLOT_X: float = 84.0
const R_SLOT_W: float = 320.0
const R_FAT_DOT_X: float = 432.0
const R_FAT_TX: float = 446.0
const R_ERA_R: float = 600.0
const R_WAR_R: float = 690.0
const R_EVAL_R: float = 770.0

# リリーフレーン定義 (上から: クローザー→セットアッパー→ミドル→ロング)。closer は max=1。
const RELIEF_LANES: Array = [
	{"key": "closer", "label": "クローザー", "desc": "9回接戦", "color": CLOSER_RED},
	{"key": "setup", "label": "セットアッパー", "desc": "接戦 7〜8回", "color": VIOLET},
	{"key": "middle", "label": "ミドルリリーフ", "desc": "同点〜ビハインド / 6〜8回", "color": RED},
	{"key": "long", "label": "ロングリリーフ", "desc": "大量リード時 / 6回以前", "color": BLUE},
]

var _team_id: int = 0
var _active_pitchers: Array = []
var _rotation_ids: Array = []
var _relief: Dictionary = {}                  # {long:[ids], middle:[ids], setup:[ids], closer:[id]}
var _war_by_id: Dictionary = {}               # player_id -> season_war 結果 dict
var _preview: Dictionary = {}
var _status_text: String = ""
var _status_is_error: bool = false

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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_update_transform()
		if event.pressed:
			_begin_drag(_to_base(event.position))
		elif _drag_active:
			_finish_drag(_to_base(event.position))
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
		_text("チームが選択されていません", Vector2(770, 496), 20, MUTED)
		return

	_draw_shell("投手起用法", team, season)
	_draw_pitcher_table()
	_draw_rotation_panel()
	_draw_relief_panel()

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1074), 13, RED if _status_is_error else MUTED)

	_draw_drag_ghost()


# --- 一軍投手一覧 ---

func _draw_pitcher_table() -> void:
	_panel(TABLE_PANEL, "一軍投手一覧")
	_text("ドラッグして下の枠へ配置", Vector2(TABLE_PANEL.position.x + 178, TABLE_PANEL.position.y + 32), 12, FAINT)

	var hy: float = TABLE_PANEL.position.y + 60
	_text("役割", Vector2(C_ROLE_X, hy), 11, FAINT)
	_text("選手", Vector2(C_JERSEY_X, hy), 11, FAINT)
	_text_right("年齢", C_AGE_R, hy, 11, FAINT)
	_text("疲労", Vector2(C_FAT_DOT_X, hy), 11, FAINT)
	_text_right("評価", C_EVAL_R, hy, 11, FAINT)
	_text_right("WAR", C_WAR_R, hy, 11, FAINT)
	_text_right("球速", C_VELO_R, hy, 11, FAINT)
	_text_right("球質", C_STUFF_R, hy, 11, FAINT)
	_text_right("制球", C_CTRL_R, hy, 11, FAINT)
	_text_right("スタ", C_STAM_R, hy, 11, FAINT)
	_text_right("登板", C_G_R, hy, 11, FAINT)
	_text_right("勝", C_W_R, hy, 11, FAINT)
	_text_right("敗", C_L_R, hy, 11, FAINT)
	_text_right("S", C_SV_R, hy, 11, FAINT)
	_text_right("H", C_HLD_R, hy, 11, FAINT)
	_text_right("投球回", C_IP_R, hy, 11, FAINT)
	_text_right("防御率", C_ERA_R, hy, 11, FAINT)
	_text_right("FIP", C_FIP_R, hy, 11, FAINT)
	_text_right("WHIP", C_WHIP_R, hy, 11, FAINT)
	_text_right("K/9", C_K9_R, hy, 11, FAINT)
	_line(Vector2(C_ROLE_X, TABLE_PANEL.position.y + 70), Vector2(TABLE_PANEL.end.x - 18, TABLE_PANEL.position.y + 70), BORDER_SOFT, 1.0)

	var closer_id: int = _closer_id()
	var rotation_set: Dictionary = _rotation_id_set()
	var rows: Array = _sorted_table_rows(rotation_set, closer_id)

	_row_hits = []
	var y: float = TABLE_PANEL.position.y + 94
	var row_h: float = 27.0
	var max_rows: int = int((TABLE_PANEL.end.y - 12 - y) / row_h)
	var shown: int = 0
	for record_value in rows:
		if shown >= max_rows:
			break
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var row_rect: Rect2 = Rect2(C_ROLE_X - 8, y - 18, TABLE_PANEL.end.x - 18 - (C_ROLE_X - 8), row_h)
		if record == _hover_record or record == _drag_record:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.10), Color.TRANSPARENT, 5, 0)
		_draw_pitcher_row(record, y, rotation_set, closer_id)
		_row_hits.append({"rect": row_rect, "record": record})
		y += row_h
		shown += 1

	if rows.is_empty():
		_text("一軍に登録された投手がいません", Vector2(C_ROLE_X, y + 6), 13, MUTED)


func _draw_pitcher_row(record: PSPlayerSeasonRecord, y: float, rotation_set: Dictionary, closer_id: int) -> void:
	var ps: PSPitcherStats = record.pitcher_stats
	var role: Dictionary = _role_chip(record, rotation_set, closer_id)
	_chip(Rect2(C_ROLE_X, y - 16, 52, 22), str(role["text"]), role["color"] as Color)

	if record.jersey_number > 0:
		_text(str(record.jersey_number), Vector2(C_JERSEY_X, y), 12, FAINT)
	_text(record.name, Vector2(C_NAME_X, y), 14, TEXT, C_AGE_R - 46 - C_NAME_X)
	_text_right(str(record.age), C_AGE_R, y, 13, MUTED)

	var pct: int = _fatigue_pct(record)
	_dot(Vector2(C_FAT_DOT_X + 4, y - 4), 5, _fatigue_color(pct))
	_text("%d%%" % pct, Vector2(C_FAT_TX, y), 13, TEXT)

	_text_right(str(PlayerValueEvaluator.pitching_score(record)), C_EVAL_R, y, 14, TEXT)
	_text_right(_war_str(record), C_WAR_R, y, 13, _war_color(record))

	_text_right("%dkm/h" % PlayerVisibleRatings.pitcher_velocity(record), C_VELO_R, y, 12, TEXT)
	_draw_rating(PlayerVisibleRatings.pitcher_stuff(record), C_STUFF_R, y)
	_draw_rating(PlayerVisibleRatings.pitcher_control(record), C_CTRL_R, y)
	_draw_rating(PlayerVisibleRatings.pitcher_stamina(record), C_STAM_R, y)

	_text_right(str(ps.games), C_G_R, y, 13, MUTED)
	_text_right(str(ps.wins), C_W_R, y, 13, TEXT)
	_text_right(str(ps.losses), C_L_R, y, 13, MUTED)
	_text_right(str(ps.saves), C_SV_R, y, 13, MUTED)
	_text_right(str(ps.holds), C_HLD_R, y, 13, MUTED)
	_text_right(_ip_str(ps), C_IP_R, y, 13, TEXT)
	_text_right(_era_str(record), C_ERA_R, y, 13, TEXT)
	_text_right(_fip_str(record), C_FIP_R, y, 13, MUTED)
	_text_right(_whip_str(ps), C_WHIP_R, y, 13, MUTED)
	_text_right(_k9_str(ps), C_K9_R, y, 13, MUTED)


func _draw_rating(value: int, right_x: float, y: float) -> void:
	_text_right(str(value), right_x, y, 13, _grade_color(value))


# --- 先発ローテ ---

func _draw_rotation_panel() -> void:
	_panel(ROTATION_PANEL, "先発ローテ")
	var px: float = ROTATION_PANEL.position.x
	var hy: float = ROTATION_PANEL.position.y + 56
	_text("番手", Vector2(px + R_NUM_X, hy), 11, FAINT)
	_text("選手", Vector2(px + R_SLOT_X, hy), 11, FAINT)
	_text("疲労", Vector2(px + R_FAT_DOT_X, hy), 11, FAINT)
	_text_right("防御率", px + R_ERA_R, hy, 11, FAINT)
	_text_right("WAR", px + R_WAR_R, hy, 11, FAINT)
	_text_right("評価", px + R_EVAL_R, hy, 11, FAINT)
	_line(Vector2(px + R_NUM_X, ROTATION_PANEL.position.y + 66), Vector2(ROTATION_PANEL.end.x - 16, ROTATION_PANEL.position.y + 66), BORDER_SOFT, 1.0)

	for i in range(ROTATION_SIZE):
		var top: float = ROTATION_PANEL.position.y + 74 + float(i) * 52.0
		var cy: float = top + 32.0
		var record: PSPlayerSeasonRecord = _record_by_id(int(_rotation_ids[i]))
		_round(Rect2(px + R_NUM_X, top + 13, 50, 34), Color(PINK.r, PINK.g, PINK.b, 0.18), Color(PINK.r, PINK.g, PINK.b, 0.55), 7)
		_text("%d" % (i + 1), Vector2(px + R_NUM_X, top + 36), 19, PINK, 50, HORIZONTAL_ALIGNMENT_CENTER)
		_draw_slot_card(_rotation_slot_rect(i), record, {"type": "rot", "index": i})
		if record == null:
			continue
		var pct: int = _fatigue_pct(record)
		_dot(Vector2(px + R_FAT_DOT_X, cy - 4), 5, _fatigue_color(pct))
		_text("%d%%" % pct, Vector2(px + R_FAT_TX, cy), 13, TEXT)
		_text_right(_era_str(record), px + R_ERA_R, cy, 13, TEXT)
		_text_right(_war_str(record), px + R_WAR_R, cy, 13, _war_color(record))
		_text_right(str(PlayerValueEvaluator.pitching_score(record)), px + R_EVAL_R, cy, 13, TEXT)


func _rotation_slot_rect(i: int) -> Rect2:
	var top: float = ROTATION_PANEL.position.y + 74 + float(i) * 52.0
	return Rect2(ROTATION_PANEL.position.x + R_SLOT_X, top + 16, R_SLOT_W, 32)


func _draw_slot_card(rect: Rect2, record: PSPlayerSeasonRecord, target: Dictionary) -> void:
	var is_target: bool = _drag_active and _drop_match(target)
	var border: Color = BLUE if is_target else BORDER_SOFT
	var bg: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.16) if is_target else PANEL_2
	_round(rect, bg, border, 7, 2 if is_target else 1)
	var ty: float = rect.position.y + rect.size.y * 0.68
	if record == null:
		_text("ここにドラッグ", Vector2(rect.position.x + 12, ty), 12, FAINT)
		return
	var label: String = record.name
	if record.jersey_number > 0:
		label = "%d  %s" % [record.jersey_number, record.name]
	_text(label, Vector2(rect.position.x + 12, ty), 14, TEXT, rect.size.x - 70)
	_text_right("評%d" % PlayerValueEvaluator.pitching_score(record), rect.end.x - 12, ty, 12, MUTED, 56)


# --- リリーフ起用法 (レーン式・複数可) ---

func _draw_relief_panel() -> void:
	_panel(RELIEF_PANEL, "リリーフ起用法")
	_chip_hits = []
	var px: float = RELIEF_PANEL.position.x
	for i in range(RELIEF_LANES.size()):
		var lane: Dictionary = RELIEF_LANES[i] as Dictionary
		var lane_y: float = _relief_lane_top(i)
		var lane_h: float = _relief_lane_h()
		if i > 0:
			_line(Vector2(px + 16, lane_y), Vector2(RELIEF_PANEL.end.x - 16, lane_y), BORDER_SOFT, 1.0)
		var color: Color = lane["color"] as Color
		_round(Rect2(px + 16, lane_y + (lane_h - 28) * 0.5 - 12, 124, 28), Color(color.r, color.g, color.b, 0.18), Color(color.r, color.g, color.b, 0.55), 7)
		_text(str(lane["label"]), Vector2(px + 16, lane_y + (lane_h - 28) * 0.5 + 7), 13, color, 124, HORIZONTAL_ALIGNMENT_CENTER)
		_text(str(lane["desc"]), Vector2(px + 16, lane_y + (lane_h - 28) * 0.5 + 34), 11, FAINT, 150)
		_draw_relief_lane(i, str(lane["key"]))


func _relief_lane_top(i: int) -> float:
	return RELIEF_PANEL.position.y + 56.0 + float(i) * _relief_lane_h()


func _relief_lane_h() -> float:
	return (RELIEF_PANEL.size.y - 64.0) / float(RELIEF_LANES.size())


func _relief_lane_rect(i: int) -> Rect2:
	var lane_y: float = _relief_lane_top(i)
	var lane_h: float = _relief_lane_h()
	var zx: float = RELIEF_PANEL.position.x + 168.0
	var zh: float = 50.0
	return Rect2(zx, lane_y + (lane_h - zh) * 0.5, RELIEF_PANEL.end.x - 16 - zx, zh)


func _draw_relief_lane(i: int, role: String) -> void:
	var zone: Rect2 = _relief_lane_rect(i)
	var is_target: bool = _drag_active and _drop_match({"type": "rel", "role": role})
	var border: Color = BLUE if is_target else BORDER_SOFT
	_round(zone, Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if is_target else Color(0.07, 0.083, 0.10), border, 7, 2 if is_target else 1)

	var ids: Array = _relief[role] as Array
	if ids.is_empty():
		_text("ここにドラッグ" + ("で追加" if role != "closer" else ""), Vector2(zone.position.x + 12, zone.position.y + zone.size.y * 0.62), 12, FAINT)
		return
	var cx: float = zone.position.x + 10.0
	var cy: float = zone.position.y + 6.0
	var chip_h: float = 28.0
	for id_value in ids:
		var record: PSPlayerSeasonRecord = _record_by_id(int(id_value))
		if record == null:
			continue
		var label: String = record.name if record.jersey_number <= 0 else "%d %s" % [record.jersey_number, record.name]
		var w: float = _measure(label, 12) + 26.0
		if cx + w > zone.end.x - 8.0 and cx > zone.position.x + 10.0:
			cx = zone.position.x + 10.0
			cy += chip_h + 4.0
		var chip_rect: Rect2 = Rect2(cx, cy, w, chip_h)
		_draw_chip_player(chip_rect, label)
		_chip_hits.append({"rect": chip_rect, "role": role, "record": record})
		cx += w + 6.0


func _draw_chip_player(rect: Rect2, label: String) -> void:
	_round(rect, PANEL_3, BORDER, 7)
	_text(label, Vector2(rect.position.x + 10, rect.position.y + rect.size.y * 0.68), 12, TEXT, rect.size.x - 16)


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
	_add_button("auto", "自動編成", Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", "リセット", Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", "保存", Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")


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
		_set_status("保存された設定がありません。自動編成を表示しています。", false)
	else:
		_set_status("保存された投手起用を表示しています (%s 更新)" % SeasonCalendar.day_status_label(season, int(saved.get("updated_at_day", 0))), false)
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
	if int(roles.get("long_id", 0)) > 0 and not long_ids.has(int(roles.get("long_id", 0))):
		long_ids.append(int(roles.get("long_id", 0)))
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
		_set_status("自動編成に失敗しました: %s" % str(preview.get("message", "")), true)
		queue_redraw()
		return
	_preview = preview
	_apply_rotation_ids((preview.get("pitcher_ids", []) as Array).duplicate())
	_relief = _auto_relief()
	_set_status("自動編成を表示中 (未保存)", false)
	queue_redraw()


func _on_save_pressed() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _team_id <= 0:
		_set_status("シーズン未開始のため保存できません", true)
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
	_set_status("保存しました (%s)" % SeasonCalendar.day_status_label(season, season.current_day), false)
	queue_redraw()


# ============================================================ table helpers

func _sorted_table_rows(rotation_set: Dictionary, closer_id: int) -> Array:
	var rows: Array = _active_pitchers.duplicate()
	rows.sort_custom(func(a, b) -> bool:
		var ra: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var rb: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var ga: int = _role_group(ra, rotation_set, closer_id)
		var gb: int = _role_group(rb, rotation_set, closer_id)
		if ga != gb:
			return ga < gb
		if ga == 0:
			return _rotation_index(ra.player_id) < _rotation_index(rb.player_id)
		return PlayerValueEvaluator.pitching_score(ra) > PlayerValueEvaluator.pitching_score(rb)
	)
	return rows


func _role_group(record: PSPlayerSeasonRecord, rotation_set: Dictionary, closer_id: int) -> int:
	if record.player_id == closer_id:
		return 2
	if rotation_set.has(record.player_id) or (rotation_set.is_empty() and record.is_starter_pitcher()):
		return 0
	return 1


func _role_chip(record: PSPlayerSeasonRecord, rotation_set: Dictionary, closer_id: int) -> Dictionary:
	match _role_group(record, rotation_set, closer_id):
		0:
			return {"text": "先発", "color": PINK}
		2:
			return {"text": "抑え", "color": CLOSER_RED}
		_:
			return {"text": "中継", "color": RED}


func _rotation_index(player_id: int) -> int:
	var idx: int = _rotation_ids.find(player_id)
	return idx if idx >= 0 else 999


func _rotation_id_set() -> Dictionary:
	var set: Dictionary = {}
	for value in _rotation_ids:
		if int(value) > 0:
			set[int(value)] = true
	return set


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


func _fatigue_color(pct: int) -> Color:
	if pct < 25:
		return GREEN
	if pct < 50:
		return AMBER
	return RED


func _era_str(record: PSPlayerSeasonRecord) -> String:
	var ps: PSPitcherStats = record.pitcher_stats
	return "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()


func _ip_str(ps: PSPitcherStats) -> String:
	if ps.outs_pitched <= 0:
		return "0"
	return "%d.%d" % [ps.outs_pitched / 3, ps.outs_pitched % 3]


func _whip_str(ps: PSPitcherStats) -> String:
	return "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.whip()


func _k9_str(ps: PSPitcherStats) -> String:
	return "-.-" if ps.outs_pitched <= 0 else "%0.1f" % ps.strikeouts_per_nine()


func _war_str(record: PSPlayerSeasonRecord) -> String:
	if record.pitcher_stats.outs_pitched <= 0:
		return "0.0"
	var w: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	return "%0.1f" % float(w.get("war", 0.0))


func _war_color(record: PSPlayerSeasonRecord) -> Color:
	if record.pitcher_stats.outs_pitched <= 0:
		return MUTED
	var war: float = float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0))
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	return TEXT


func _fip_str(record: PSPlayerSeasonRecord) -> String:
	if record.pitcher_stats.outs_pitched <= 0:
		return "-.--"
	var w: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	return "%0.2f" % float(w.get("fip", 0.0)) if w.has("fip") else "-.--"


func _grade_color(value: int) -> Color:
	if value >= 75:
		return GREEN
	if value >= 66:
		return BLUE
	if value >= 52:
		return TEXT
	return MUTED


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error
