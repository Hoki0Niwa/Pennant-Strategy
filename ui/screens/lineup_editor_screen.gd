extends "res://ui/components/dashboard_screen.gd"

# 打順・守備位置画面。一軍野手一覧、打順ドロップ枠、守備図、出場配分を同時に編集する。
# 一覧/打順/守備図/出場配分の間でドラッグ&ドロップし、DH 使用時だけ打順枠の DH/守備切替を表示する。
#
# データ:
#   - 打順 = season.set_lineup(team_id, dh, {batting_order:[{slot,position,player_id}]})
#   - 出場配分 = season.fielder_usage.position_slots[pos]
#     = {candidates:[{player_id, share}], backup_ids:[...], share_locked:bool}
#     candidates[0] が定位置、[1] が併用相手 (=backup_ids[0])。backup_ids は補充優先リストで、
#     defense_alignment_service が最優先で使う。share_locked=false は「配分は AI に任せる」。
#   - 「自動編成」= AI 任せと同義 (preview_lineup で全自動埋め)。専用の常時 AI トグルは置かない。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")


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
const C_OBP_R: float = 1520.0
const C_OPS_R: float = 1590.0
const C_WOBA_R: float = 1660.0
const C_WRC_R: float = 1730.0
const C_OAA_R: float = 1800.0
# 能力ブロック(巧打..選球)と成績ブロック(試合..OAA)の境界に引く縦ヘアラインの x 座標。
const C_BLOCK_SEP_X: float = 1152.0

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
# 定位置選手の出場シェア (その守備位置の先発を何割取るか)。0.0 = AI に任せる。
const SHARE_AUTO: float = 0.0
# スライダーの下限。これ未満は「定位置」と呼べないので、下げたいときは控えと入れ替える。
const SHARE_SLIDER_MIN: float = 0.30
# 「規定到達見込み」の表示に使う 先発1試合あたりの打席数の目安 (実測 4.2)。
# 規定打席 = 試合数 × QUALIFIER_PA_PER_TEAM_GAME なので、必要先発数はこの比で出る。
# 表示専用の概算で、実際の到達判定は成績側 (RecordStore の打席数) が正典。
const PA_PER_START_ESTIMATE: float = 4.2
const QUALIFIER_PA_PER_TEAM_GAME: float = 3.1

# 出場配分リストの座標 (FIELD_PANEL の右半分)。守備図が左、配分が右。
# 1行 = 1守備位置で、上段に 定位置 + スライダー + % + 自動チップ、下段に控え1..MAX_BENCH。
const SHARE_LIST_LEFT: float = 1502.0
const SHARE_LIST_RIGHT: float = 1884.0
const SHARE_LIST_TOP: float = 704.0
const SHARE_ROW_H: float = 42.0
const SHARE_BADGE_W: float = 26.0
const SHARE_NAME_W: float = 120.0
const SHARE_SLIDER_W: float = 130.0
const SHARE_VALUE_W: float = 46.0
const SHARE_AUTO_CHIP_W: float = 38.0
const CARD: Vector2 = Vector2(104, 34)

var _team_id: int = 0
var _dh_enabled: bool = false
var _dh_available: bool = false
var _non_dh_available: bool = false
var _fielders: Array = []                 # PSPlayerSeasonRecord (1軍登録野手)
var _war_by_id: Dictionary = {}           # player_id -> season_war 結果 dict
var _slots: Array = []                    # size 9: {"pid": int, "pos": int} = 打順i (index 0..8)
var _backups: Dictionary = {}             # pos(2-9) -> Array[int]
# 出場配分。ユーザー指定値 (_shares) と、エンジンが実際に使っている値 (_effective_shares) を
# 分けて持つ。_share_locked が false の枠は「AI に任せる」= 表示は _effective_shares 側。
var _shares: Dictionary = {}              # pos(2-9) -> float (ユーザー指定の出場シェア)
var _effective_shares: Dictionary = {}    # pos(2-9) -> float (保存済み candidates[0].share)
var _share_locked: Dictionary = {}        # pos(2-9) -> bool
# エンジンが実際に併用相手にしている選手 (保存済み candidates[1])。控えが未設定の枠でも
# AI は誰かに残りの先発を割り当てているので、それを薄く出さないと「74試合の残りは誰?」になる。
var _platoon_ids: Dictionary = {}         # pos(2-9) -> player_id
var _team_scheduled_games: int = 0        # 先発試合数の表示に使うシーズン試合数
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
var _slider_hits: Array = []              # {rect, pos} 出場配分スライダー
var _share_value_hits: Array = []         # {rect, pos} % 表示 (クリックで数値入力)
var _auto_chip_hits: Array = []           # {rect, pos} 「自動」へ戻すチップ

# スライダー操作と数値直接入力。
var _slider_drag_pos: int = 0             # 0 = 非ドラッグ、それ以外は操作中の守備位置
var _share_edit: LineEdit = null
var _share_edit_pos: int = 0
var _share_edit_rect: Rect2 = Rect2()


func _ready() -> void:
	_init_chrome()
	# 守備図は FIELD_PANEL の左半分 (x 1094-1478) に縦長で収める。右半分は出場配分リスト。
	_field_centers = {
		8: Vector2(1286, 726), 7: Vector2(1160, 772), 9: Vector2(1412, 772),
		6: Vector2(1222, 830), 4: Vector2(1350, 830),
		5: Vector2(1160, 888), 3: Vector2(1412, 888),
		2: Vector2(1286, 946),
	}
	for i in range(9):
		_slots.append({"pid": 0, "pos": 0})
	_build_chrome_buttons()
	_build_share_edit()
	_load_initial_state()
	_layout_buttons()
	queue_redraw()


# 出場配分の数値直接入力欄。1つを使い回し、編集中の枠へ重ねて表示する。
func _build_share_edit() -> void:
	_share_edit = LineEdit.new()
	_share_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_share_edit.max_length = 3
	_share_edit.context_menu_enabled = false
	_share_edit.visible = false
	_share_edit.text_submitted.connect(func(_t: String) -> void: _commit_share_edit())
	_share_edit.focus_exited.connect(_commit_share_edit)
	add_child(_share_edit)


func _layout_buttons() -> void:
	super._layout_buttons()
	if _share_edit != null and _share_edit.visible:
		_place_share_edit()


# ============================================================ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_update_transform()
		var base_pos: Vector2 = _to_base(event.position)
		if event.pressed:
			_press_screen = event.position
			# スライダーは選手カードのドラッグより先に拾う (同じ押下で両方は起きない)。
			var slider_pos: int = _slider_at(base_pos)
			if slider_pos > 0:
				_slider_drag_pos = slider_pos
				_apply_slider_value(slider_pos, base_pos.x)
				return
			_pending = _pick_draggable(base_pos)
		else:
			if _slider_drag_pos > 0:
				_slider_drag_pos = 0
			elif _drag_active:
				_finish_drag(base_pos)
			else:
				_handle_click(base_pos)
			_pending = {}
	elif event is InputEventMouseMotion:
		if _slider_drag_pos > 0:
			_update_transform()
			_apply_slider_value(_slider_drag_pos, _to_base(event.position).x)
		elif _drag_active:
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
	for hit_value in _auto_chip_hits:
		var auto_hit: Dictionary = hit_value as Dictionary
		if (auto_hit["rect"] as Rect2).has_point(base_pos):
			_set_share_auto(int(auto_hit["pos"]))
			return
	for hit_value in _share_value_hits:
		var value_hit: Dictionary = hit_value as Dictionary
		if (value_hit["rect"] as Rect2).has_point(base_pos):
			_open_share_edit(int(value_hit["pos"]), value_hit["rect"] as Rect2)
			return
	# 入力欄の外をクリックしたら確定して閉じる (focus_exited でも同じ処理が走る)。
	_commit_share_edit()


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


# --- 出場配分の操作 (スライダー / 数値入力 / 自動へ戻す) ---

# 当たり判定だけトラックより広く取る (トラックは高さ 6px で、そのままでは掴みにくい)。
# 保持する矩形はトラックそのもの — 値の写像に使うので広げた矩形を保存してはいけない。
func _slider_at(base_pos: Vector2) -> int:
	for hit_value in _slider_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).grow_individual(6.0, 9.0, 6.0, 9.0).has_point(base_pos):
			return int(hit["pos"])
	return 0


# スライダーの x 座標から出場シェアを決める。触った時点で「指定」になる。
# 下限は SHARE_SLIDER_MIN — それ未満にしたいなら定位置と控えを入れ替えるのが本筋。
func _apply_slider_value(pos: int, base_x: float) -> void:
	var rect: Rect2 = _slider_rect_for(pos)
	if rect.size.x <= 0.0:
		return
	var t: float = clampf((base_x - rect.position.x) / rect.size.x, 0.0, 1.0)
	_set_share(pos, SHARE_SLIDER_MIN + t * (1.0 - SHARE_SLIDER_MIN))


# シェアを 1% 刻みに丸めて「指定」として保持する。
func _set_share(pos: int, share: float) -> void:
	_shares[pos] = clampf(round(share * 100.0) / 100.0, SHARE_SLIDER_MIN, 1.0)
	_share_locked[pos] = true
	_refresh_status()
	queue_redraw()


func _set_share_auto(pos: int) -> void:
	_share_locked[pos] = false
	_shares.erase(pos)
	_refresh_status()
	queue_redraw()


func _slider_rect_for(pos: int) -> Rect2:
	for hit_value in _slider_hits:
		var hit: Dictionary = hit_value as Dictionary
		if int(hit["pos"]) == pos:
			return hit["rect"] as Rect2
	return Rect2()


# % 表示をクリックしたときの数値直接入力。空欄か 0 で「自動」へ戻す。
func _open_share_edit(pos: int, rect: Rect2) -> void:
	if _share_edit == null:
		return
	_commit_share_edit()
	_share_edit_pos = pos
	_share_edit_rect = rect
	var share: float = _effective_share(pos)
	_share_edit.text = "" if share <= 0.0 else str(int(round(share * 100.0)))
	_share_edit.visible = true
	_place_share_edit()
	_share_edit.grab_focus()
	_share_edit.select_all()


func _place_share_edit() -> void:
	var r: Rect2 = _r(_share_edit_rect)
	_share_edit.position = r.position
	_share_edit.size = r.size
	if _font != null:
		_share_edit.add_theme_font_override("font", _font)
	_share_edit.add_theme_font_size_override("font_size", max(9, int(round(13.0 * _scale_f))))
	_share_edit.add_theme_color_override("font_color", TEXT)
	_share_edit.add_theme_color_override("caret_color", TEXT)
	_share_edit.add_theme_stylebox_override("normal", _box(PANEL_2, BLUE, 4))
	_share_edit.add_theme_stylebox_override("focus", _box(PANEL_2, BLUE, 4))


func _commit_share_edit() -> void:
	if _share_edit == null or not _share_edit.visible:
		return
	var pos: int = _share_edit_pos
	var text: String = _share_edit.text.strip_edges()
	_share_edit.visible = false
	_share_edit_pos = 0
	if pos <= 0:
		return
	if text.is_empty() or not text.is_valid_int() or int(text) <= 0:
		_set_share_auto(pos)
		return
	_set_share(pos, float(int(text)) / 100.0)


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
	var header_rule_y: float = TABLE_PANEL.position.y + 70
	_line(Vector2(C_BADGE_X, header_rule_y), Vector2(TABLE_PANEL.end.x - 18, header_rule_y), BORDER, 1.5)

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
		# 全行の下にヘアライン区切り (基底テーブルの罫線と同じ言語で行を刻む)。
		_line(Vector2(C_BADGE_X - 8, y + 9), Vector2(TABLE_PANEL.end.x - 18, y + 9), HAIRLINE, 1.0)
		_table_hits.append({"rect": row_rect, "record": record})
		y += row_h
		shown += 1

	if _fielders.is_empty():
		_text("一軍に登録された野手がいません", Vector2(C_BADGE_X, y + 6), 13, MUTED)
	elif shown > 0:
		# 能力ブロック(巧打..選球)と成績ブロック(試合..OAA)の境界を縦ヘアラインで区切る。
		var rows_bottom: float = y - 18.0
		_line(Vector2(C_BLOCK_SEP_X, header_rule_y), Vector2(C_BLOCK_SEP_X, rows_bottom), HAIRLINE, 1.0)


func _draw_roster_row(record: PSPlayerSeasonRecord, y: float) -> void:
	var bs: PSBatterStats = record.batter_stats
	var ad: PSAdvancedStats = record.advanced_stats
	var played: bool = ad != null and ad.plate_appearances > 0
	_pos_badge(Rect2(C_BADGE_X, y - 16, 40, 21), record.position)

	if record.jersey_number > 0:
		_text(str(record.jersey_number), Vector2(C_JERSEY_X, y), 12, FAINT)
	_text(record.name, Vector2(C_NAME_X, y), 14, TEXT, C_AGE_R - 46 - C_NAME_X, HORIZONTAL_ALIGNMENT_LEFT, true)
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

	_text_right(str(bs.games), C_G_R, y, 13, TEXT)
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
	_line(Vector2(O_NUM_CX - 16, ORDER_PANEL.position.y + 66), Vector2(ORDER_PANEL.end.x - 16, ORDER_PANEL.position.y + 66), BORDER, 1.5)

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
		# 行ヘアライン (打順枠が縦に並ぶだけの一覧なので視線誘導の罫線を足す)。
		_line(Vector2(O_NUM_CX - 16, row_rect.end.y), Vector2(ORDER_PANEL.end.x - 16, row_rect.end.y), HAIRLINE, 1.0)
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
	_text(record.name, Vector2(O_NAME_X, baseline), 14, TEXT, O_BATS_CX - 60 - O_NAME_X, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_bats(record), Vector2(O_BATS_CX - 8, baseline), 13, MUTED, 24, HORIZONTAL_ALIGNMENT_CENTER)
	_text_right(_rate_short(bs.batting_average()), O_AVG_R, baseline, 13, TEXT)
	_text_right(str(bs.home_runs), O_HR_R, baseline, 13, TEXT)
	_text_right(str(bs.runs_batted_in), O_RBI_R, baseline, 13, MUTED)
	_text_right(_rate_short(bs.ops()), O_OPS_R, baseline, 13, TEXT)


# --- 守備位置設定 + 控え ---

# 左に守備図、右に出場配分リスト。1つのパネルを縦のヘアラインで区切る。
func _draw_field_panel() -> void:
	_panel(FIELD_PANEL, "守備位置設定")
	_text("一軍登録野手から各枠へドラッグ", Vector2(FIELD_PANEL.position.x + 168, FIELD_PANEL.position.y + 32), 12, FAINT)
	_line(Vector2(1486, FIELD_PANEL.position.y + 56), Vector2(1486, FIELD_PANEL.end.y - 20), HAIRLINE, 1.0)

	_draw_field_backdrop()

	_field_hits = []
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		_draw_field_card(_field_centers[pos] as Vector2, pos, true)
	# 余剰枠: DH (打撃のみ・D&D可) もしくは 投 (ローテ・固定)。守備図の最下段に置く。
	var extra_center: Vector2 = Vector2(1286, 1004)
	if _dh_enabled:
		_draw_field_card(extra_center, 10, true)
	else:
		_draw_field_card(extra_center, 1, false)

	_draw_share_list()


func _draw_field_backdrop() -> void:
	# 内野ダイヤと2本のファウルラインを淡く描き、守備図だと一目で分かるようにする。
	var home: Vector2 = Vector2(1286, 964)
	var b1: Vector2 = Vector2(1372, 902)
	var b2: Vector2 = Vector2(1286, 840)
	var b3: Vector2 = Vector2(1200, 902)
	var grass: Color = Color(0.13, 0.22, 0.16, 0.55)
	_line(home, Vector2(1112, 716), grass, 1.5)
	_line(home, Vector2(1460, 716), grass, 1.5)
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


# 出場配分リスト (FIELD_PANEL 右半分)。1行 = 1守備位置で 2 段:
#   上段 = 定位置 + 出場シェアのスライダー + % + 「自動」チップ
#   下段 = 控え1..MAX_BENCH (上から補充優先。控え1 は併用相手として残りのシェアを取る)
# 定位置セルは守備図と同じドロップ先で、控えセルは D&D で入れ替えられる。
func _draw_share_list() -> void:
	_bench_cell_hits = []
	_bench_chip_hits = []
	_slider_hits = []
	_share_value_hits = []
	_auto_chip_hits = []

	_text("出場配分", Vector2(SHARE_LIST_LEFT, SHARE_LIST_TOP - 26.0), 13, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(
		"スライダーか%%をクリックして数値入力 (0=自動) ・ 全%d試合" % _team_scheduled_games,
		Vector2(SHARE_LIST_LEFT + 62.0, SHARE_LIST_TOP - 26.0), 11, FAINT
	)

	# 定位置セルは守備図と同じドロップ先。ドラッグ中の強調判定 (_is_field_target) が自分のセルを
	# 見られるよう、描画ループより先に全行ぶんのヒット矩形を登録しておく。
	for i in range(DEF_POSITIONS.size()):
		_field_hits.append({
			"rect": _share_starter_rect(i), "pos": int(DEF_POSITIONS[i]), "draggable": true,
		})

	for i in range(DEF_POSITIONS.size()):
		_draw_share_row(i, int(DEF_POSITIONS[i]))


func _draw_share_row(index: int, pos: int) -> void:
	var top: float = SHARE_LIST_TOP + float(index) * SHARE_ROW_H
	var locked: bool = bool(_share_locked.get(pos, false))
	var share: float = _effective_share(pos)

	# --- 上段: 定位置セル + スライダー + % + 自動チップ ---
	_pos_badge(Rect2(SHARE_LIST_LEFT, top + 2.0, SHARE_BADGE_W, 17.0), pos)
	var starter_rect: Rect2 = _share_starter_rect(index)
	var starter_target: bool = _drag_active and _is_field_target(pos)
	_round(
		starter_rect,
		Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if starter_target else PANEL_2,
		BLUE if starter_target else Color.TRANSPARENT, 5, 1 if starter_target else 0
	)
	var starter: PSPlayerSeasonRecord = _record_by_id(_player_at_position(pos))
	_text(
		starter.name if starter != null else "未設定",
		Vector2(starter_rect.position.x + 6.0, starter_rect.position.y + 15.0), 12,
		TEXT if starter != null else FAINT, starter_rect.size.x - 10.0
	)

	var slider_rect: Rect2 = _share_slider_rect(index)
	_draw_share_slider(slider_rect, share, locked)
	_slider_hits.append({"rect": slider_rect, "pos": pos})

	var value_rect: Rect2 = Rect2(
		slider_rect.end.x + 6.0, top + 1.0, SHARE_VALUE_W, 19.0
	)
	if _share_edit_pos != pos:
		_text(
			"自動" if share <= 0.0 else "%d%%" % int(round(share * 100.0)),
			Vector2(value_rect.position.x, value_rect.position.y + 14.0), 13,
			TEXT if locked else FAINT, value_rect.size.x, HORIZONTAL_ALIGNMENT_RIGHT
		)
	_share_value_hits.append({"rect": value_rect, "pos": pos})

	var auto_rect: Rect2 = Rect2(SHARE_LIST_RIGHT - SHARE_AUTO_CHIP_W, top + 2.0, SHARE_AUTO_CHIP_W, 17.0)
	_chip(auto_rect, "自動", MUTED if locked else BLUE, not locked)
	_auto_chip_hits.append({"rect": auto_rect, "pos": pos})

	# --- 下段: 控え (上から補充優先)。控え1 は併用相手として残りのシェアを取る ---
	var list: Array = _backups.get(pos, []) as Array
	var is_target: bool = _drag_active and _is_bench_target(pos)
	var cell_w: float = (SHARE_LIST_RIGHT - starter_rect.position.x - 8.0) / float(MAX_BENCH)
	for r in range(MAX_BENCH):
		var cell_rect: Rect2 = Rect2(
			starter_rect.position.x + float(r) * cell_w, top + 22.0, cell_w - 4.0, 18.0
		)
		if r < list.size():
			var record: PSPlayerSeasonRecord = _record_by_id(int(list[r]))
			_round(cell_rect, PANEL_3, Color.TRANSPARENT, 4, 0)
			_share_cell_text(
				cell_rect, record.name if record != null else "?", TEXT,
				_platoon_share_label(pos) if r == 0 else "補", MUTED if r == 0 else FAINT
			)
			_bench_chip_hits.append({"rect": cell_rect, "pos": pos, "pid": int(list[r])})
			continue
		var bg: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if is_target else Color(0.07, 0.083, 0.10)
		_round(cell_rect, bg, BLUE if is_target else Color.TRANSPARENT, 4, 1 if is_target else 0)
		# 控え未設定でも AI が併用相手を決めているので、その枠には相手を薄く出す
		# (出さないと「定位置が 51%、残りは誰?」が読めない)。
		var platoon: PSPlayerSeasonRecord = (
			_record_by_id(int(_platoon_ids.get(pos, 0))) if r == 0 and list.is_empty() else null
		)
		if platoon != null:
			_share_cell_text(cell_rect, platoon.name, MUTED, _platoon_share_label(pos), FAINT)
		elif r == list.size():
			_text("控え%d" % (r + 1), Vector2(cell_rect.position.x + 5.0, cell_rect.position.y + 13.0), 10, FAINT)
	_bench_cell_hits.append({
		"rect": Rect2(starter_rect.position.x, top + 22.0, SHARE_LIST_RIGHT - starter_rect.position.x, 18.0),
		"pos": pos,
	})


# シェアのスライダー。指定済みは青、自動は灰で塗る (数値側の色分けと揃える)。
func _draw_share_slider(rect: Rect2, share: float, locked: bool) -> void:
	_round(rect, PANEL_3, Color.TRANSPARENT, 3, 0)
	if share <= 0.0:
		return
	var t: float = clampf((share - SHARE_SLIDER_MIN) / (1.0 - SHARE_SLIDER_MIN), 0.0, 1.0)
	var fill: Color = BLUE if locked else Color(MUTED.r, MUTED.g, MUTED.b, 0.55)
	_round(Rect2(rect.position, Vector2(maxf(rect.size.x * t, 3.0), rect.size.y)), fill, Color.TRANSPARENT, 3, 0)
	var knob_x: float = rect.position.x + rect.size.x * t
	_round(Rect2(knob_x - 3.0, rect.position.y - 3.0, 6.0, rect.size.y + 6.0), fill, Color.TRANSPARENT, 3, 0)


func _share_starter_rect(index: int) -> Rect2:
	return Rect2(
		SHARE_LIST_LEFT + SHARE_BADGE_W + 6.0,
		SHARE_LIST_TOP + float(index) * SHARE_ROW_H,
		SHARE_NAME_W, 20.0
	)


func _share_slider_rect(index: int) -> Rect2:
	var starter_rect: Rect2 = _share_starter_rect(index)
	return Rect2(starter_rect.end.x + 8.0, starter_rect.position.y + 7.0, SHARE_SLIDER_W, 6.0)


# 控えセルの 1 行 = 左に選手名 (省略あり)、右に短いラベル (シェア/「補」)。
func _share_cell_text(
	rect: Rect2, name_text: String, name_color: Color, right_text: String, right_color: Color
) -> void:
	var baseline: float = rect.position.y + 13.0
	var right_width: float = _measure(right_text, 10) + 4.0
	_text(name_text, Vector2(rect.position.x + 5.0, baseline), 11, name_color, rect.size.x - 8.0 - right_width)
	_text_right(right_text, rect.end.x - 4.0, baseline, 10, right_color, right_width)


func _draw_status_bar() -> void:
	var y: float = 1072.0
	var x: float = TABLE_PANEL.position.x
	x = _status_item(x, y, "打順", _order_ok())
	x = _status_item(x, y, "守備位置", _defense_ok())
	x = _status_item(x, y, "控え配置", true)
	# 出場配分の結果を数で見せる。実 NPB は 1 球団あたり 4-5 人 ([[project_qualified_batter_count]])。
	var projected: String = "規定到達見込み: %d人" % _projected_qualified_count()
	_dot(Vector2(x + 6, y - 4), 5, BLUE)
	_text(projected, Vector2(x + 18, y), 13, MUTED)
	x += 18 + _measure(projected, 13) + 26
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

	_dh_available = AppState.is_dh_enabled_for_league("league1") or AppState.is_dh_enabled_for_league("league2")
	_non_dh_available = not AppState.is_dh_enabled_for_league("league1") or not AppState.is_dh_enabled_for_league("league2")
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
	_shares = {}
	_effective_shares = {}
	_share_locked = {}
	_platoon_ids = {}
	_team_scheduled_games = _count_scheduled_games(season)
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
		if not list.is_empty():
			_backups[pos] = list
		var share: float = PSDefenseAlignmentService.slot_starter_share(slot)
		var locked: bool = PSDefenseAlignmentService.slot_share_locked(slot)
		_effective_shares[pos] = share
		_share_locked[pos] = locked
		if locked:
			_shares[pos] = share
		var candidates: Array = PSDefenseAlignmentService.slot_candidates(slot)
		if candidates.size() > 1:
			_platoon_ids[pos] = int((candidates[1] as Dictionary).get("player_id", 0))


func _count_scheduled_games(season: PSSeason) -> int:
	var games: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("home_team_id", 0)) == _team_id or int(game.get("away_team_id", 0)) == _team_id:
			games += 1
	return games if games > 0 else PSSchedule.PENNANT_GAMES_PER_TEAM


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

	# 守備起用 (スタメン守備 + 控え=backup_ids + 出場配分)
	# 「自動」(share_locked=false) の枠は share 0.0 で保存し、PSTeamSetupBuilder 側の
	# AI 既定生成がシェアと併用相手を埋める。指定済みの枠は定期組み直しでも測り直されない。
	var position_slots: Dictionary = {}
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		var starter_id: int = _player_at_position(pos)
		var backup_ids: Array = (_backups.get(pos, []) as Array).duplicate()
		var locked: bool = bool(_share_locked.get(pos, false))
		var share: float = float(_shares.get(pos, SHARE_AUTO)) if locked else SHARE_AUTO
		if starter_id <= 0 and backup_ids.is_empty() and not locked:
			continue
		var candidates: Array = [{"player_id": starter_id, "share": share}]
		if backup_ids.size() > 0 and share > 0.0 and share < 1.0:
			candidates.append({"player_id": int(backup_ids[0]), "share": 1.0 - share})
		position_slots[str(pos)] = PSDefenseAlignmentService.make_slot(candidates, backup_ids, locked)
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


# 定位置選手が実際に取る出場シェア。指定済みならその値、未指定なら AI の実効配分。
# どちらも無い枠 (まだ生成されていない) は 0.0 = 「自動」。
func _effective_share(pos: int) -> float:
	if bool(_share_locked.get(pos, false)):
		return float(_shares.get(pos, SHARE_AUTO))
	return float(_effective_shares.get(pos, SHARE_AUTO))


func _share_games(share: float) -> int:
	return int(round(clampf(share, 0.0, 1.0) * float(_team_scheduled_games)))


# 併用相手 (控え1) が取るシェア。定位置が全試合なら出番は補充だけ。
# 配分がまだ決まっていない枠は空欄 (「自動」は上段に出ているので繰り返さない)。
func _platoon_share_label(pos: int) -> String:
	var share: float = _effective_share(pos)
	if share <= 0.0:
		return ""
	if share >= 1.0:
		return "補"
	return "%d%%" % int(round((1.0 - share) * 100.0))


# 規定打席に届く見込みの定位置選手数 (先発 = 規定打席 ÷ 打席/先発 を満たす枠の数)。
# 出場配分を触ったときに「何人が規定に届く編成なのか」をその場で見せるための概算。
func _projected_qualified_count() -> int:
	var required_starts: float = (
		float(_team_scheduled_games) * QUALIFIER_PA_PER_TEAM_GAME / PA_PER_START_ESTIMATE
	)
	var count: int = 0
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		if _player_at_position(pos) <= 0:
			continue
		if float(_share_games(_effective_share(pos))) >= required_starts:
			count += 1
	return count


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


# 守備位置の色は共有基底 dashboard_screen._pos_color を使う (全画面共通)。
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
