extends "res://ui/components/dashboard_screen.gd"

# 打順・守備位置画面。一軍野手一覧、打順ドロップ枠、守備図、出場配分を同時に編集する。
# 一覧/打順/守備図/出場配分の間でドラッグ&ドロップし、DH 使用時だけ打順枠の DH/守備切替を表示する。
#
# データ:
#   - 打順 = season.set_lineup(team_id, dh, {batting_order:[...]}, opponent_hand)
#     対右 ("") と対左 ("L") で別に保存でき、対左が未保存なら試合では対右が使われる。
#   - 出場配分 = season.fielder_usage.position_slots[pos]
#     = {candidates:[{player_id, share}], backup_ids:[...], share_locked:bool}
#     candidates[0] が定位置、[1] が併用相手 (=backup_ids[0])。backup_ids は補充優先リストで、
#     defense_alignment_service が最優先で使う。share_locked=false は「配分は AI に任せる」。
#   - 「自動編成」= AI 任せと同義 (preview_lineup で全自動埋め)。専用の常時 AI トグルは置かない。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")


# --- レイアウト (base 座標, rotation_editor と同一枠) ---
const TABLE_PANEL: Rect2 = Rect2(262, 104, 1638, 468)
const ORDER_PANEL: Rect2 = Rect2(262, 592, 800, 464)
const FIELD_PANEL: Rect2 = Rect2(1078, 592, 822, 464)

# 一軍登録野手表 (共通テーブルエンジン _draw_data_table)。見出しは 2 段 (header_top の幾何は
# エンジンの _effective_header_top に従う)、行は固定高でスクロールは画面側 (_table_scroll) が持つ。
const ROSTER_HEADER_TOP: float = 68.0
const ROSTER_ROW_H: float = 27.0
const ROSTER_BOTTOM_PAD: float = 12.0
const ROSTER_ABILITY_COLUMNS: Array = [
	["contact", "rating.contact"], ["power", "rating.power"], ["speed", "rating.speed"],
	["defense", "rating.defense"], ["arm", "rating.arm"], ["discipline", "rating.discipline"],
]
# 成績列: [key, title, fmt, w, muted]
const ROSTER_STAT_COLUMNS: Array = [
	["games", "col.games", "int", 40, false], ["avg", "col.avg", "rate", 52, false],
	["hr", "col.hr", "int", 40, false], ["rbi", "stat.rbi", "int", 40, true],
	["sb", "stat.stolen_bases", "int", 40, true], ["obp", "stat.obp", "rate", 52, true],
	["ops", "OPS", "rate", 52, false], ["woba", "wOBA", "rate", 52, true],
	["wrc", "wRC+", "int", 48, true], ["oaa", "OAA", "f1s", 52, true],
]

# スタメン/打順 列 (x は base 座標。*_R は右端、*_CX は中心)。
# 打順 | 守備 | 選手 | 打 | 総合 | 巧打 長打 走力 守備 | 打率 本 OPS WAR
const O_LEFT: float = 272.0
const O_NUM_CX: float = 292.0
const O_BADGE_X: float = 320.0
const O_NAME_X: float = 368.0
const O_BATS_CX: float = 506.0
const O_EVAL_R: float = 560.0
const O_MEET_R: float = 604.0
const O_POW_R: float = 652.0
const O_SPD_R: float = 700.0
const O_DEF_R: float = 748.0
const O_AVG_R: float = 810.0
const O_HR_R: float = 858.0
const O_OPS_R: float = 926.0
const O_WAR_R: float = 996.0
# 打順表の見出し帯 (上段グループ 18px + 下段列名 26px) と行の開始位置 (ORDER_PANEL 上端からの距離)。
const O_SUPER_TOP: float = 42.0
const O_ROW_TOP: float = 92.0
const O_ROW_H: float = 34.0

# 打順パネル下部のモード切替ボタン列 (base 座標)。
const ORDER_MODE_ROW_Y: float = 1006.0
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
const SHARE_LIST_TOP: float = 678.0
# 出場配分リストの 2 段見出し (上段グループ 18px の上端 / 下段列名 24px の上端)。
const SHARE_HEAD_TOP: float = 630.0
const SHARE_ROW_H: float = 41.0
const SHARE_BADGE_W: float = 28.0
const SHARE_NAME_W: float = 130.0
const SHARE_SLIDER_W: float = 118.0
const SHARE_VALUE_W: float = 48.0
const SHARE_AUTO_CHIP_W: float = 38.0
const CARD: Vector2 = Vector2(104, 34)

var _team_id: int = 0
var _dh_enabled: bool = false
# 編集中の打順が「対右 ("")」か「対左 ("L")」か。保存先が分かれ、対左を保存していない
# チームは試合時に基本打順 (対右) へフォールバックする。
var _hand_mode: String = ""
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
var _rotation_pitcher_name: String = Loc.t("postseason.undecided")
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
var _header_hits: Array = []              # {rect, key}
var _order_hits: Array = []               # {rect, index}
var _field_hits: Array = []               # {rect, pos, draggable}
var _bench_cell_hits: Array = []          # {rect, pos}
var _bench_chip_hits: Array = []          # {rect, pos, pid}
var _slider_hits: Array = []              # {rect, pos} 出場配分スライダー
var _share_value_hits: Array = []         # {rect, pos} % 表示 (クリックで数値入力)
var _auto_chip_hits: Array = []           # {rect, pos} 「自動」へ戻すチップ

# 一軍野手テーブルのソートとスクロール
var _sort_key: String = "pos"
var _sort_asc: bool = true
var _table_scroll: int = 0

# スライダー操作と数値直接入力。
var _slider_drag_pos: int = 0             # 0 = 非ドラッグ、それ以外は操作中の守備位置
var _share_edit: LineEdit = null
var _share_edit_pos: int = 0
var _share_edit_rect: Rect2 = Rect2()


func _ready() -> void:
	_init_chrome()
	# 守備図は FIELD_PANEL の左半分 (x 1094-1478) に縦長で収める。右半分は出場配分リスト。
	_field_centers = {
		8: Vector2(1286, 690), 7: Vector2(1160, 742), 9: Vector2(1412, 742),
		6: Vector2(1222, 806), 4: Vector2(1350, 806),
		5: Vector2(1160, 870), 3: Vector2(1412, 870),
		2: Vector2(1286, 934),
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
	if event is InputEventMouseButton:
		_update_transform()
		var base_pos: Vector2 = _to_base(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
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
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.pressed and TABLE_PANEL.has_point(base_pos):
				if _table_scroll > 0:
					_table_scroll = max(0, _table_scroll - 1)
					queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and TABLE_PANEL.has_point(base_pos):
				var max_scroll: int = max(0, _fielders.size() - _roster_max_rows())
				if _table_scroll < max_scroll:
					_table_scroll = min(max_scroll, _table_scroll + 1)
					queue_redraw()
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
	for hit_value in _header_hits:
		var header_hit: Dictionary = hit_value as Dictionary
		if (header_hit["rect"] as Rect2).has_point(base_pos):
			_on_header_clicked(str(header_hit["key"]))
			return
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


func _on_header_clicked(key: String) -> void:
	if _sort_key == key:
		_sort_asc = not _sort_asc
	else:
		_sort_key = key
		_sort_asc = (key in ["pos", "name", "age", "fatigue", "bats"])
	_sort_fielders()
	queue_redraw()


func _sort_fielders() -> void:
	_fielders.sort_custom(func(a: PSPlayerSeasonRecord, b: PSPlayerSeasonRecord) -> bool:
		var va = _fielder_sort_val(a, _sort_key)
		var vb = _fielder_sort_val(b, _sort_key)
		if va != vb:
			return (va < vb) if _sort_asc else (va > vb)
		return a.player_id < b.player_id
	)


func _fielder_sort_val(rec: PSPlayerSeasonRecord, key: String) -> Variant:
	match key:
		"pos":
			return rec.position
		"name":
			return rec.name
		"bats":
			return _bats(rec)
		"age":
			return rec.age
		"fatigue":
			return _fatigue_pct(rec)
		"eval":
			return PlayerValueEvaluator.overall_score(rec)
		"war":
			return float((_war_by_id.get(rec.player_id, {}) as Dictionary).get("war", 0.0))
		"contact":
			return PlayerVisibleRatings.fielder_contact(rec)
		"power":
			return PlayerVisibleRatings.fielder_power(rec)
		"speed":
			return PlayerVisibleRatings.fielder_speed(rec)
		"defense":
			return PlayerVisibleRatings.fielder_defense(rec)
		"arm":
			return PlayerVisibleRatings.fielder_arm(rec)
		"discipline":
			return PlayerVisibleRatings.fielder_discipline(rec)
		"games":
			return rec.batter_stats.games
		"avg":
			return rec.batter_stats.batting_average()
		"hr":
			return rec.batter_stats.home_runs
		"rbi":
			return rec.batter_stats.runs_batted_in
		"sb":
			return rec.batter_stats.stolen_bases
		"obp":
			return rec.batter_stats.on_base_percentage()
		"ops":
			return rec.batter_stats.ops()
		"woba":
			return rec.advanced_stats.woba() if (rec.advanced_stats != null and rec.advanced_stats.plate_appearances > 0) else -999.0
		"wrc":
			return rec.advanced_stats.wrc_plus if (rec.advanced_stats != null and rec.advanced_stats.plate_appearances > 0) else -999.0
		"oaa":
			return rec.advanced_stats.outs_above_average if (rec.advanced_stats != null and rec.advanced_stats.plate_appearances > 0) else -999.0
		_:
			return rec.position


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


# 出場配分リストに並べる枠。DH 制のときだけ打撃専任枠 (10) が最後に付く。
# DH 行は「自動 = その日守備を外れた選手のうち打撃最良」と「専任DHを指定」の 2 モードで、
# 指定した (share_locked) ときだけ usage へ枠が保存される ([[project_qualified_batter_count]])。
func _share_positions() -> Array:
	if not _dh_enabled:
		return DEF_POSITIONS
	var positions: Array = DEF_POSITIONS.duplicate()
	positions.append(PSBattingOrderService.DH_POSITION)
	return positions


func _add_bench(pos: int, pid: int) -> void:
	if not _share_positions().has(pos):
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
		_text(Loc.t("sim.error.no_team"), Vector2(770, 496), 20, MUTED)
		return

	_draw_shell(Loc.t("screen.lineup_editor"), team, season)
	_draw_roster_table()
	_draw_order_panel()
	_draw_field_panel()
	_draw_status_bar()
	_draw_drag_ghost()


# --- 一軍登録野手 ---

func _draw_roster_table() -> void:
	_panel(TABLE_PANEL, Loc.t("lineup.roster_panel"))
	_text(Loc.t("lineup.roster_hint"), Vector2(TABLE_PANEL.position.x + 196, TABLE_PANEL.position.y + 30), 12, FAINT)

	var columns: Array = _roster_columns()
	var max_rows: int = _roster_max_rows()
	var max_scroll: int = max(0, _fielders.size() - max_rows)
	_table_scroll = clampi(_table_scroll, 0, max_scroll)

	# 表示窓ぶんの行だけをエンジンへ渡す (スクロール位置は画面側が持つ)。
	var rows: Array = []
	for idx in range(_table_scroll, min(_fielders.size(), _table_scroll + max_rows)):
		rows.append(_roster_row(_fielders[idx] as PSPlayerSeasonRecord))
	var row_hits: Array = []
	var opts: Dictionary = {
		"panel": false, "header_top": ROSTER_HEADER_TOP, "row_h": ROSTER_ROW_H,
		"bottom_pad": ROSTER_BOTTOM_PAD, "sort_key": _sort_key, "sort_asc": _sort_asc,
		"sel_kind": "lineup_roster", "hits": row_hits,
		"empty_text": Loc.t("lineup.no_active_fielders"),
	}
	_draw_data_table(TABLE_PANEL, columns, rows, opts)

	# ヘッダ/行の当たり判定はエンジンと同一の幾何から作る。
	_header_hits = []
	_build_table_header_hits(_header_hits, TABLE_PANEL, columns, opts)
	_table_hits = []
	for hit_value in row_hits:
		var hit: Dictionary = hit_value as Dictionary
		var record: PSPlayerSeasonRecord = _record_by_id(int(hit["meta"]))
		if record == null:
			continue
		var row_rect: Rect2 = hit["rect"] as Rect2
		_table_hits.append({"rect": row_rect, "record": record})
		# スタメン入りしている選手は行の左端に緑のバー。
		if _slot_index_with_pid(record.player_id) >= 0:
			_round(Rect2(row_rect.position.x - 4.0, row_rect.position.y + 4.0, 3.0, row_rect.size.y - 8.0), GREEN, Color.TRANSPARENT, 1, 0)

	# 行数が表示枠を超える場合はスリムなスクロールバーを描画
	if _fielders.size() > max_rows:
		var bar_x: float = TABLE_PANEL.end.x - 12.0
		var bar_top: float = _roster_row_top()
		var bar_h: float = float(max_rows) * ROSTER_ROW_H
		_round(Rect2(bar_x, bar_top, 4.0, bar_h), PANEL_2, Color.TRANSPARENT, 2, 0)
		var thumb_ratio: float = float(max_rows) / float(_fielders.size())
		var thumb_h: float = maxf(18.0, bar_h * thumb_ratio)
		var thumb_y: float = bar_top + (bar_h - thumb_h) * (float(_table_scroll) / float(max_scroll))
		_round(Rect2(bar_x, thumb_y, 4.0, thumb_h), BORDER, Color.TRANSPARENT, 2, 0)


# 先頭行の上端 y。エンジンは ヘッダ線 (header_top + 8) の 6px 下から行を並べる。
func _roster_row_top() -> float:
	return TABLE_PANEL.position.y + ROSTER_HEADER_TOP + 8.0 + 6.0


# 固定行高で表示窓に入る行数 (エンジンの visible_count と同じ式)。
func _roster_max_rows() -> int:
	return max(1, int((TABLE_PANEL.end.y - _roster_row_top() - ROSTER_BOTTOM_PAD) / ROSTER_ROW_H))


# 列定義。キーは _fielder_sort_val / _on_header_clicked のキーと同一にする。
# プロフィールと評価は共通ヘルパ (総合のキーだけ eval に付け替える)、能力と成績は 2 段目のグループ。
func _roster_columns() -> Array:
	var cols: Array = _player_profile_columns(false, false, false, true)
	for col_value in _player_eval_columns(false, false, true):
		var eval_col: Dictionary = col_value as Dictionary
		if str(eval_col["key"]) == "overall":
			eval_col["key"] = "eval"
		cols.append(eval_col)
	for i in range(ROSTER_ABILITY_COLUMNS.size()):
		var spec: Array = ROSTER_ABILITY_COLUMNS[i] as Array
		var ability_col: Dictionary = {
			"key": spec[0], "title": spec[1], "w": 46, "align": "c", "fmt": "ability_bar",
			"group": "lineup.col.ability_block",
		}
		if i == 0:
			ability_col["sep_before"] = true
		cols.append(ability_col)
	for i in range(ROSTER_STAT_COLUMNS.size()):
		var stat_spec: Array = ROSTER_STAT_COLUMNS[i] as Array
		var stat_col: Dictionary = {
			"key": stat_spec[0], "title": stat_spec[1], "fmt": stat_spec[2], "w": stat_spec[3],
			"align": "r", "group": "lineup.col.record_block",
		}
		if i == 0:
			stat_col["sep_before"] = true
		cols.append(stat_col)
	return cols


func _roster_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var bs: PSBatterStats = record.batter_stats
	var ad: PSAdvancedStats = record.advanced_stats
	var played: bool = ad != null and ad.plate_appearances > 0
	var war_info: Dictionary = _war_by_id.get(record.player_id, {}) as Dictionary
	var row: Dictionary = {
		"__meta": record.player_id,
		"is_hover": record == _hover_record or record == _drag_record,
		"pos": _short_pos(record.position), "pos_color": _pos_color(record.position),
		"name": record.name, "jersey": record.jersey_number,
		"age": record.age, "bats": _bats(record), "fatigue": _fatigue_pct(record),
		"eval": PlayerValueEvaluator.overall_score(record),
		"war": float(war_info.get("war", 0.0)) if played else 0.0,
		"contact": PlayerVisibleRatings.fielder_contact(record),
		"power": PlayerVisibleRatings.fielder_power(record),
		"speed": PlayerVisibleRatings.fielder_speed(record),
		"defense": PlayerVisibleRatings.fielder_defense(record),
		"arm": PlayerVisibleRatings.fielder_arm(record),
		"discipline": PlayerVisibleRatings.fielder_discipline(record),
		"games": bs.games, "avg": bs.batting_average(), "hr": bs.home_runs,
		"rbi": bs.runs_batted_in, "sb": bs.stolen_bases, "obp": bs.on_base_percentage(),
		"ops": bs.ops(),
		"woba": ad.woba() if played else "-",
		"wrc": int(round(float(war_info.get("wrc_plus", 0.0)))) if played else "-",
		"oaa": _oaa_value(ad) if played else "-",
	}
	# 補助指標は MUTED、欠損は FAINT (数値文字には段階色を付けない)。
	for spec_value in ROSTER_STAT_COLUMNS:
		var spec: Array = spec_value as Array
		if bool(spec[4]):
			var key: String = str(spec[0])
			row[key + "_color"] = FAINT if row[key] is String else MUTED
	return row


# --- スタメン / 打順 ---

func _draw_order_panel() -> void:
	_panel(ORDER_PANEL, Loc.t("lineup.order_panel"))
	_text(Loc.t("lineup.order_hint"), Vector2(ORDER_PANEL.position.x + 158, ORDER_PANEL.position.y + 30), 12, FAINT)

	_draw_order_header()

	# 下部のモード切替 (DH有無 / 対戦投手の左右)。ボタン自体は _build_chrome_buttons が置く。
	_line(
		Vector2(O_NUM_CX - 16, ORDER_MODE_ROW_Y - 16), Vector2(ORDER_PANEL.end.x - 16, ORDER_MODE_ROW_Y - 16),
		HAIRLINE, 1.0
	)
	_text(Loc.t("lineup.editing_order"), Vector2(ORDER_PANEL.position.x + 18, ORDER_MODE_ROW_Y + 20), 12, MUTED)
	# DH 切替は両リーグ混在時のみ意味がある。出ないときは現在の状態だけ静的に見せる。
	if not (_dh_available and _non_dh_available):
		_text(
			_dh_status_text(),
			Vector2(ORDER_PANEL.position.x + 118, ORDER_MODE_ROW_Y + 20), 12, FAINT
		)
	if not _hand_mode.is_empty() and not _has_saved_hand_lineup():
		var warning: String = Loc.t("lineup.vs_left_unsaved")
		_text(
			warning, Vector2(ORDER_PANEL.end.x - 18 - _measure(warning, 11), ORDER_MODE_ROW_Y + 20),
			11, AMBER
		)

	_order_hits = []
	var rows_bottom: float = ORDER_PANEL.position.y + O_ROW_TOP + 9.0 * O_ROW_H
	for i in range(9):
		var top: float = ORDER_PANEL.position.y + O_ROW_TOP + float(i) * O_ROW_H
		var row_rect: Rect2 = Rect2(O_LEFT, top, ORDER_PANEL.end.x - 16.0 - O_LEFT, O_ROW_H - 2.0)
		var is_target: bool = _drag_active and _is_order_target(i)
		if is_target:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.16), BLUE, 4, 1)
		_draw_order_row(i, row_rect)
		# 行ヘアライン
		_line(Vector2(O_LEFT, row_rect.end.y), Vector2(row_rect.end.x, row_rect.end.y), HAIRLINE, 1.0)
		_order_hits.append({"rect": row_rect, "index": i})
	# 列グループ境界の縦ヘアライン (見出し上段の上端から最終行の下端まで)。
	for sep_x in _order_group_seps():
		_line(Vector2(sep_x, ORDER_PANEL.position.y + O_SUPER_TOP), Vector2(sep_x, rows_bottom), HAIRLINE, 1.0)


# 打順表の上段グループ境界 (選手 / 評価・能力 / 今季成績 の各先頭 x)。
func _order_group_seps() -> Array:
	return [O_NAME_X - 6.0, O_BATS_CX + 14.0, O_DEF_R + 12.0]


# 2 段見出し: 上段 (SUPER_HEADER_BG, 18px, グループ名) + 下段 (PANEL_2, 26px, 列名)。
# 共通テーブルと同じ配色・文字サイズ。当たり判定は持たない (並べ替えなし)。
func _draw_order_header() -> void:
	var top: float = ORDER_PANEL.position.y + O_SUPER_TOP
	var right: float = ORDER_PANEL.end.x - 16.0
	var seps: Array = _order_group_seps()
	_round(Rect2(O_LEFT, top, right - O_LEFT, 18.0), SUPER_HEADER_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(O_LEFT, top + 18.0), Vector2(right, top + 18.0), HAIRLINE, 1.0)
	var bounds: Array = [O_LEFT, float(seps[0]), float(seps[1]), float(seps[2]), right]
	var groups: Array = ["lineup.group.order_pos", "group.profile", "lineup.group.eval_ability", "lineup.col.record_block"]
	for g in range(groups.size()):
		var gx: float = float(bounds[g])
		_text(Loc.t(str(groups[g])), Vector2(gx, top + 13.0), 10, MUTED, float(bounds[g + 1]) - gx, HORIZONTAL_ALIGNMENT_CENTER, true)

	var band_top: float = top + 18.0
	_round(Rect2(O_LEFT, band_top, right - O_LEFT, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	var hy: float = band_top + 18.0
	_order_head_center(Loc.t("lineup.col.order"), O_NUM_CX, 30.0, hy)
	_order_head_center(Loc.t("rating.defense"), O_BADGE_X + 19.0, 40.0, hy)
	_text(Loc.t("col.player"), Vector2(O_NAME_X, hy), 12, MUTED, O_BATS_CX - 14.0 - O_NAME_X, HORIZONTAL_ALIGNMENT_LEFT, true)
	_order_head_center(Loc.t("lineup.col.bats"), O_BATS_CX, 24.0, hy)
	_order_head_center(Loc.t("col.overall"), O_EVAL_R - 18.0, 40.0, hy)
	_order_head_center(Loc.t("rating.contact"), O_MEET_R - 14.0, 46.0, hy)
	_order_head_center(Loc.t("rating.power"), O_POW_R - 14.0, 46.0, hy)
	_order_head_center(Loc.t("rating.speed"), O_SPD_R - 14.0, 46.0, hy)
	_order_head_center(Loc.t("rating.defense"), O_DEF_R - 14.0, 46.0, hy)
	_text_right(Loc.t("col.avg"), O_AVG_R, hy, 12, MUTED, 46.0, true)
	_text_right(Loc.t("col.hr"), O_HR_R, hy, 12, MUTED, 40.0, true)
	_text_right("OPS", O_OPS_R, hy, 12, MUTED, 52.0, true)
	_text_right("WAR", O_WAR_R, hy, 12, MUTED, 46.0, true)
	_line(Vector2(O_LEFT, band_top + 26.0), Vector2(right, band_top + 26.0), BORDER, 1.5)


func _order_head_center(label: String, center_x: float, width: float, baseline: float) -> void:
	_text(label, Vector2(center_x - width * 0.5, baseline), 12, MUTED, width, HORIZONTAL_ALIGNMENT_CENTER, true)


# 打順 1 行。行共通の高さ中心 (center_y) から各セルの縦位置を決める (共通テーブルの行と同じ)。
func _draw_order_row(i: int, row_rect: Rect2) -> void:
	var slot: Dictionary = _slots[i]
	var pos: int = int(slot["pos"])
	var center_y: float = row_rect.position.y + row_rect.size.y * 0.5
	var baseline: float = center_y + 5.0
	# 打順バッジ (1-9)
	_round(Rect2(O_NUM_CX - 10.0, center_y - 10.0, 20.0, 20.0), PANEL_2, BORDER_SOFT, 4, 1)
	_text("%d" % (i + 1), Vector2(O_NUM_CX - 10.0, baseline), 13, TEXT, 20.0, HORIZONTAL_ALIGNMENT_CENTER, true)
	var name_w: float = O_BATS_CX - 14.0 - O_NAME_X
	if _is_fixed_pitcher(i):
		_pos_badge(Rect2(O_BADGE_X, center_y - 11.0, 38, 22), 1)
		_text(Loc.t("lineup.rotation_pitcher", {"name": _rotation_pitcher_name}), Vector2(O_NAME_X, baseline), 14, MUTED, name_w)
		return
	if pos > 0:
		_pos_badge(Rect2(O_BADGE_X, center_y - 11.0, 38, 22), pos)
	var pid: int = int(slot["pid"])
	if pid <= 0:
		_text(Loc.t("lineup.unset_paren"), Vector2(O_NAME_X, baseline), 14, FAINT, name_w)
		return
	var record: PSPlayerSeasonRecord = _record_by_id(pid)
	if record == null:
		_text(Loc.t("lineup.unset_paren"), Vector2(O_NAME_X, baseline), 14, FAINT)
		return
	var bs: PSBatterStats = record.batter_stats
	# 共通テーブルの player_name と同じく、背番号を FAINT で名前の前に置く。
	var name_x: float = O_NAME_X
	if record.jersey_number > 0:
		var num_text: String = "#%d " % record.jersey_number
		var num_w: float = _measure(num_text, 13)
		_text(num_text, Vector2(name_x, baseline), 13, FAINT, num_w + 2.0)
		name_x += num_w
	_text(record.name, Vector2(name_x, baseline), 14, TEXT, O_NAME_X + name_w - name_x, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_bats(record), Vector2(O_BATS_CX - 12.0, baseline), 12, MUTED, 24, HORIZONTAL_ALIGNMENT_CENTER)
	_order_eval_badge(PlayerValueEvaluator.overall_score(record), O_EVAL_R - 18.0, center_y)
	var bar_y: float = row_rect.end.y - 6.0
	_draw_rating(PlayerVisibleRatings.fielder_contact(record), O_MEET_R, baseline, bar_y)
	_draw_rating(PlayerVisibleRatings.fielder_power(record), O_POW_R, baseline, bar_y)
	_draw_rating(PlayerVisibleRatings.fielder_speed(record), O_SPD_R, baseline, bar_y)
	_draw_rating(PlayerVisibleRatings.fielder_defense(record), O_DEF_R, baseline, bar_y)
	_text_right(_rate_short(bs.batting_average()), O_AVG_R, baseline, 13, TEXT, 46.0)
	_text_right(str(bs.home_runs), O_HR_R, baseline, 13, TEXT, 40.0)
	_text_right(_rate_short(bs.ops()), O_OPS_R, baseline, 13, TEXT, 52.0)
	_text_right(_war_str(record), O_WAR_R, baseline, 13, TEXT, 46.0)


# 総合評価ピル: 背景 PANEL_2、外枠だけ段階色、数字は TEXT (共通テーブルの eval_badge と同じ)。
func _order_eval_badge(value: int, center_x: float, center_y: float) -> void:
	_round(Rect2(center_x - 17.0, center_y - 10.0, 34.0, 20.0), PANEL_2, _tier_color(float(value)), 4, 1)
	_text(str(value), Vector2(center_x - 17.0, center_y + 5.0), 13, TEXT, 34.0, HORIZONTAL_ALIGNMENT_CENTER, true)


# 能力値: 数字は TEXT、セル下端の 3px バーだけ段階色 (共通テーブルの ability_bar と同じ)。
func _draw_rating(value: int, right_x: float, baseline: float, bar_y: float) -> void:
	if value <= 0:
		_text_right("-", right_x, baseline - 1.0, 13, FAINT, 28.0)
		return
	var track_w: float = 28.0
	_text_right(str(value), right_x, baseline - 1.0, 13, TEXT, track_w)
	_round(Rect2(right_x - track_w, bar_y, track_w, 3.0), PANEL_3, Color.TRANSPARENT, 1, 0)
	var fill_w: float = track_w * clampf(float(value) / 100.0, 0.08, 1.0)
	_round(Rect2(right_x - track_w, bar_y, fill_w, 3.0), _tier_color(float(value)), Color.TRANSPARENT, 1, 0)


# --- 守備位置設定 + 控え ---

# 左に守備図、右に出場配分リスト。1つのパネルを縦のヘアラインで区切る。
func _draw_field_panel() -> void:
	_panel(FIELD_PANEL, Loc.t("lineup.field_panel"))
	_text(Loc.t("lineup.field_hint"), Vector2(FIELD_PANEL.position.x + 168, FIELD_PANEL.position.y + 32), 12, FAINT)
	_line(Vector2(1486, FIELD_PANEL.position.y + 56), Vector2(1486, FIELD_PANEL.end.y - 20), HAIRLINE, 1.0)

	_draw_field_backdrop()

	_field_hits = []
	for pos_value in DEF_POSITIONS:
		var pos: int = int(pos_value)
		_draw_field_card(_field_centers[pos] as Vector2, pos, true)
	# 余剰枠: DH (打撃のみ・D&D可) もしくは 投 (ローテ・固定)。守備図の最下段に置く。
	var extra_center: Vector2 = Vector2(1286, 998)
	if _dh_enabled:
		_draw_field_card(extra_center, 10, true)
	else:
		_draw_field_card(extra_center, 1, false)

	_draw_share_list()


func _draw_field_backdrop() -> void:
	# 内野ダイヤ・マウンド・外野アーク・ファウルラインを描き、守備図だと一目で分かるようにする。
	var home: Vector2 = Vector2(1286, 952)
	var b1: Vector2 = Vector2(1372, 886)
	var b2: Vector2 = Vector2(1286, 820)
	var b3: Vector2 = Vector2(1200, 886)
	var mound: Vector2 = Vector2(1286, 886)
	var grass: Color = Color(0.12, 0.22, 0.16, 0.6)
	var arc_color: Color = Color(0.15, 0.26, 0.19, 0.4)

	# 外野芝生ゾーンの扇形アーク
	var center: Vector2 = home
	var radius: float = 290.0
	var prev_pt: Vector2 = Vector2.ZERO
	for step in range(17):
		var ang: float = deg_to_rad(-135.0 + float(step) * (90.0 / 16.0))
		var pt: Vector2 = center + Vector2(cos(ang), sin(ang)) * radius
		if step > 0:
			_line(prev_pt, pt, arc_color, 2.0)
		prev_pt = pt

	# ファウルライン (ホームから両翼へ)
	_line(home, Vector2(1112, 678), grass, 1.5)
	_line(home, Vector2(1460, 678), grass, 1.5)

	# 内野ダイヤモンド
	_line(home, b1, BORDER_SOFT, 1.2)
	_line(b1, b2, BORDER_SOFT, 1.2)
	_line(b2, b3, BORDER_SOFT, 1.2)
	_line(b3, home, BORDER_SOFT, 1.2)

	# ピッチャーズマウンド
	_dot(mound, 6.0, Color(0.18, 0.22, 0.26, 0.6))
	_dot(mound, 2.5, MUTED)


func _draw_field_card(center: Vector2, pos: int, draggable: bool) -> void:
	var rect: Rect2 = Rect2(center - CARD * 0.5, CARD)
	var is_target: bool = _drag_active and draggable and _is_field_target(pos)
	var border: Color = BLUE if is_target else BORDER
	var bg: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.16) if is_target else PANEL_2
	_round(rect, bg, border, 6, 2 if is_target else 1)
	_pos_badge(Rect2(rect.position.x + 4, rect.position.y + 4, 26, 18), pos)
	var name_x: float = rect.position.x + 34
	var name_w: float = rect.size.x - 40
	var pid: int = 0
	if pos == 1:
		_text(_rotation_pitcher_name, Vector2(name_x, rect.position.y + 21.0), 12, MUTED, name_w)
	else:
		pid = _player_at_position(pos)
		if pid > 0:
			var record: PSPlayerSeasonRecord = _record_by_id(pid)
			var pname: String = record.name if record != null else "?"
			_text(pname, Vector2(name_x, rect.position.y + 16.0), 12, TEXT, name_w - 12.0)
			if record != null:
				var def_val: int = PlayerVisibleRatings.fielder_defense(record)
				_text(Loc.t("lineup.def_val", {"val": def_val}), Vector2(name_x, rect.position.y + 28.0), 10, MUTED)
				var fat: int = _fatigue_pct(record)
				_dot(Vector2(rect.end.x - 10.0, rect.position.y + 23.0), 3.5, _fatigue_color(fat))
		else:
			_text(Loc.t("lineup.unset"), Vector2(name_x, rect.position.y + 21.0), 12, FAINT, name_w)
	_field_hits.append({"rect": rect, "pos": pos, "draggable": draggable})


# 出場配分リスト (FIELD_PANEL 右半分)。
func _draw_share_list() -> void:
	_bench_cell_hits = []
	_bench_chip_hits = []
	_slider_hits = []
	_share_value_hits = []
	_auto_chip_hits = []

	_text(Loc.t("lineup.share_title"), Vector2(SHARE_LIST_LEFT, SHARE_HEAD_TOP - 8.0), 13, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(
		Loc.t("lineup.share_hint", {"games": _team_scheduled_games}),
		Vector2(SHARE_LIST_LEFT + 62.0, SHARE_HEAD_TOP - 4.0), 11, FAINT
	)

	# 2 段見出し: 上段 (SUPER_HEADER_BG, 18px) にグループ名、下段 (PANEL_2, 24px) に列名。
	var head_left: float = SHARE_LIST_LEFT - 4.0
	var head_w: float = SHARE_LIST_RIGHT - SHARE_LIST_LEFT + 8.0
	var split_x: float = _share_slider_left() - 4.0
	_round(Rect2(head_left, SHARE_HEAD_TOP, head_w, 18.0), SUPER_HEADER_BG, Color.TRANSPARENT, 0, 0)
	_text(Loc.t("lineup.group.share_starter"), Vector2(head_left, SHARE_HEAD_TOP + 13.0), 10, MUTED, split_x - head_left, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(Loc.t("lineup.group.share_alloc"), Vector2(split_x, SHARE_HEAD_TOP + 13.0), 10, MUTED, head_left + head_w - split_x, HORIZONTAL_ALIGNMENT_CENTER, true)
	var band_top: float = SHARE_HEAD_TOP + 18.0
	_round(Rect2(head_left, band_top, head_w, 24.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	var hy: float = band_top + 17.0
	_text(Loc.t("lineup.share_col.pos"), Vector2(SHARE_LIST_LEFT, hy), 12, MUTED, SHARE_BADGE_W, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(Loc.t("lineup.share_col.starter"), Vector2(SHARE_LIST_LEFT + SHARE_BADGE_W + 12.0, hy), 12, MUTED, SHARE_NAME_W, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(Loc.t("lineup.share_col.ratio"), Vector2(_share_slider_left(), hy), 12, MUTED, SHARE_SLIDER_W + SHARE_VALUE_W, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(Loc.t("lineup.share_col.setting"), Vector2(SHARE_LIST_RIGHT - SHARE_AUTO_CHIP_W - 4.0, hy), 12, MUTED, SHARE_AUTO_CHIP_W + 4.0, HORIZONTAL_ALIGNMENT_CENTER, true)
	_line(Vector2(head_left, band_top + 24.0), Vector2(head_left + head_w, band_top + 24.0), BORDER, 1.5)
	_line(Vector2(split_x, SHARE_HEAD_TOP), Vector2(split_x, band_top + 24.0), HAIRLINE, 1.0)

	var positions: Array = _share_positions()
	for i in range(positions.size()):
		_field_hits.append({
			"rect": _share_starter_rect(i), "pos": int(positions[i]), "draggable": true,
		})

	for i in range(positions.size()):
		_draw_share_row(i, int(positions[i]))


func _draw_share_row(index: int, pos: int) -> void:
	var top: float = SHARE_LIST_TOP + float(index) * SHARE_ROW_H
	var locked: bool = bool(_share_locked.get(pos, false))
	var share: float = _effective_share(pos)

	# --- 上段: 定位置セル + スライダー + % + 自動チップ ---
	_pos_badge(Rect2(SHARE_LIST_LEFT, top + 1.0, SHARE_BADGE_W, 19.0), pos)
	var starter_rect: Rect2 = _share_starter_rect(index)
	var starter_target: bool = _drag_active and _is_field_target(pos)
	var is_dh: bool = pos == PSBattingOrderService.DH_POSITION
	_round(
		starter_rect,
		Color(BLUE.r, BLUE.g, BLUE.b, 0.10) if starter_target else PANEL_2,
		BLUE if starter_target else Color.TRANSPARENT, 5, 1 if starter_target else 0
	)
	var starter: PSPlayerSeasonRecord = _record_by_id(_player_at_position(pos))
	_text(
		starter.name if starter != null else Loc.t("lineup.unset"),
		Vector2(starter_rect.position.x + 7.0, starter_rect.position.y + 15.0), 14,
		TEXT if starter != null else FAINT, starter_rect.size.x - 12.0
	)

	var slider_rect: Rect2 = _share_slider_rect(index)
	_draw_share_slider(slider_rect, share, locked)
	_slider_hits.append({"rect": slider_rect, "pos": pos})

	var value_rect: Rect2 = Rect2(
		slider_rect.end.x + 6.0, top + 1.0, SHARE_VALUE_W, 20.0
	)
	if _share_edit_pos != pos:
		_text(
			Loc.t("lineup.auto") if share <= 0.0 else "%d%%" % int(round(share * 100.0)),
			Vector2(value_rect.position.x, value_rect.position.y + 15.0), 15,
			TEXT if locked else FAINT, value_rect.size.x, HORIZONTAL_ALIGNMENT_RIGHT
		)
	_share_value_hits.append({"rect": value_rect, "pos": pos})

	var auto_rect: Rect2 = Rect2(SHARE_LIST_RIGHT - SHARE_AUTO_CHIP_W, top + 2.0, SHARE_AUTO_CHIP_W, 18.0)
	_chip(auto_rect, Loc.t("lineup.auto"), MUTED if locked else BLUE, not locked)
	_auto_chip_hits.append({"rect": auto_rect, "pos": pos})

	# --- 下段 ---
	if is_dh:
		# DH は「専任を指定する」か「守備を外れた選手から自動」かの 2 モード。
		# 指定モード (locked) の残りシェアも自動選出で埋まる。
		_text(
			Loc.t("lineup.dh_locked_note", {"pct": int(round((1.0 - share) * 100.0))})
			if locked else Loc.t("lineup.dh_auto_note"),
			Vector2(starter_rect.position.x + 2.0, top + 34.0), 11, FAINT,
			SHARE_LIST_RIGHT - starter_rect.position.x
		)
		return

	var list: Array = _backups.get(pos, []) as Array
	var is_target: bool = _drag_active and _is_bench_target(pos)
	var cell_w: float = (SHARE_LIST_RIGHT - starter_rect.position.x - 8.0) / float(MAX_BENCH)
	for r in range(MAX_BENCH):
		var cell_rect: Rect2 = Rect2(
			starter_rect.position.x + float(r) * cell_w, top + 22.0, cell_w - 4.0, 17.0
		)
		if r < list.size():
			var record: PSPlayerSeasonRecord = _record_by_id(int(list[r]))
			_round(cell_rect, PANEL_3, Color.TRANSPARENT, 4, 0)
			_share_cell_text(
				cell_rect, record.name if record != null else "?", TEXT,
				_platoon_share_label(pos) if r == 0 else Loc.t("lineup.backup_short"), MUTED if r == 0 else FAINT
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
		# 今日その枠に出ているのが併用相手本人なら、上段と同じ名前を二度出さない
		# (DH は定位置が守備に回る日があるので、この重複が起きやすい)。
		if platoon != null and platoon.player_id == _player_at_position(pos):
			platoon = null
		if platoon != null:
			_share_cell_text(cell_rect, platoon.name, MUTED, _platoon_share_label(pos), FAINT)
		elif r == list.size():
			_text(Loc.t("lineup.bench_n", {"n": r + 1}), Vector2(cell_rect.position.x + 5.0, cell_rect.position.y + 13.0), 11, FAINT)
	_bench_cell_hits.append({
		"rect": Rect2(starter_rect.position.x, top + 22.0, SHARE_LIST_RIGHT - starter_rect.position.x, 17.0),
		"pos": pos,
	})


# シェアのスライダー。指定済みは青、自動は灰で塗る (数値側の色分けと揃える)。
func _draw_share_slider(rect: Rect2, share: float, locked: bool) -> void:
	_round(rect, PANEL_3, BORDER_SOFT, 3, 1)
	if share <= 0.0:
		return
	var t: float = clampf((share - SHARE_SLIDER_MIN) / (1.0 - SHARE_SLIDER_MIN), 0.0, 1.0)
	var fill: Color = BLUE if locked else Color(MUTED.r, MUTED.g, MUTED.b, 0.55)
	_round(Rect2(rect.position, Vector2(maxf(rect.size.x * t, 3.0), rect.size.y)), fill, Color.TRANSPARENT, 3, 0)
	var knob_x: float = rect.position.x + rect.size.x * t
	_round(Rect2(knob_x - 3.5, rect.position.y - 3.0, 7.0, rect.size.y + 6.0), TEXT if locked else MUTED, BLUE if locked else BORDER, 3, 1)


func _share_starter_rect(index: int) -> Rect2:
	return Rect2(
		SHARE_LIST_LEFT + SHARE_BADGE_W + 6.0,
		SHARE_LIST_TOP + float(index) * SHARE_ROW_H,
		SHARE_NAME_W, 21.0
	)


# スライダー列の左端 x (定位置セルの右 8px)。
func _share_slider_left() -> float:
	return SHARE_LIST_LEFT + SHARE_BADGE_W + 6.0 + SHARE_NAME_W + 8.0


func _share_slider_rect(index: int) -> Rect2:
	var starter_rect: Rect2 = _share_starter_rect(index)
	return Rect2(starter_rect.end.x + 8.0, starter_rect.position.y + 8.0, SHARE_SLIDER_W, 7.0)


# 控えセルの 1 行 = 左に選手名 (省略あり)、右に短いラベル (シェア/「補」)。
func _share_cell_text(
	rect: Rect2, name_text: String, name_color: Color, right_text: String, right_color: Color
) -> void:
	var baseline: float = rect.position.y + 13.0
	var right_width: float = _measure(right_text, 11) + 4.0
	_text(name_text, Vector2(rect.position.x + 5.0, baseline), 12, name_color, rect.size.x - 8.0 - right_width)
	_text_right(right_text, rect.end.x - 4.0, baseline, 11, right_color, right_width)


func _draw_status_bar() -> void:
	var y: float = 1072.0
	var x: float = TABLE_PANEL.position.x
	x = _status_item(x, y, Loc.t("lineup.col.order"), _order_ok())
	x = _status_item(x, y, Loc.t("lineup.status.positions"), _defense_ok())
	x = _status_item(x, y, Loc.t("lineup.status.bench"), true)
	# 出場配分の結果を数で見せる。実 NPB は 1 球団あたり 4-5 人 ([[project_qualified_batter_count]])。
	var projected: String = Loc.t("lineup.status.projected_qualified", {"n": _projected_qualified_count()})
	_dot(Vector2(x + 6, y - 4), 5, BLUE)
	_text(projected, Vector2(x + 18, y), 13, MUTED)
	x += 18 + _measure(projected, 13) + 26
	var unset: int = _unset_count()
	if unset > 0:
		var unset_text: String = Loc.t("lineup.status.unset_slots", {"n": unset})
		_dot(Vector2(x + 6, y - 4), 5, AMBER)
		_text(unset_text, Vector2(x + 18, y), 13, AMBER)
		x += 18 + _measure(unset_text, 13) + 26
	_dot(Vector2(x + 6, y - 4), 5, BLUE)
	_text(_dh_status_text(), Vector2(x + 18, y), 13, MUTED)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(FIELD_PANEL.end.x - _measure(_status_text, 13) - 4, y), 13, RED if _status_is_error else MUTED)


func _dh_status_text() -> String:
	return Loc.t("lineup.dh_status", {"state": Loc.t("lineup.dh_used") if _dh_enabled else Loc.t("common.none")})


func _status_item(x: float, y: float, label: String, ok: bool) -> float:
	_dot(Vector2(x + 6, y - 4), 5, GREEN if ok else RED)
	var text: String = Loc.t("lineup.status.item", {"label": label, "state": "OK" if ok else Loc.t("lineup.status.needs_check")})
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
	_add_button("auto", Loc.t("common.auto_arrange"), Rect2(1486, 22, 132, 42), _on_auto_pressed, "action")
	_add_button("reset", Loc.t("common.reset"), Rect2(1628, 22, 112, 42), _load_initial_state, "action")
	_add_button("save", Loc.t("common.save"), Rect2(1750, 22, 132, 42), _on_save_pressed, "primary")
	# 打順パネル下部: 編集中の打順の切替。DH 有無は両リーグ混在時のみ意味がある。
	var mode_x: float = ORDER_PANEL.position.x + 118.0
	if not (_dh_available and _non_dh_available):
		mode_x += 74.0  # 静的な「DH: 使用」表示のぶん
	if _dh_available and _non_dh_available:
		_add_button("mode_non_dh", Loc.t("lineup.mode_non_dh"), Rect2(mode_x, ORDER_MODE_ROW_Y, 76, 30),
			func() -> void: _on_mode_pressed(false), "chip_active" if not _dh_enabled else "chip")
		_add_button("mode_dh", "DH", Rect2(mode_x + 82.0, ORDER_MODE_ROW_Y, 64, 30),
			func() -> void: _on_mode_pressed(true), "chip_active" if _dh_enabled else "chip")
		mode_x += 170.0
	_add_button("hand_r", Loc.t("lineup.vs_right"), Rect2(mode_x, ORDER_MODE_ROW_Y, 106, 30),
		func() -> void: _on_hand_pressed(""), "chip_active" if _hand_mode.is_empty() else "chip")
	_add_button("hand_l", Loc.t("lineup.vs_left"), Rect2(mode_x + 112.0, ORDER_MODE_ROW_Y, 106, 30),
		func() -> void: _on_hand_pressed("L"), "chip_active" if _hand_mode == "L" else "chip")


# 対右/対左の切替。編集内容は打順パネルだけが変わる (守備配置・出場配分は左右で共通)。
func _on_hand_pressed(hand: String) -> void:
	if hand == _hand_mode:
		return
	_hand_mode = hand
	_build_chrome_buttons()
	_load_lineup_for_mode()
	_layout_buttons()
	queue_redraw()


# 現在のモードの打順が実際に保存されているか (対左が未保存なら試合では対右が使われる)。
func _has_saved_hand_lineup() -> bool:
	var season: PSSeason = AppState.current_season
	return season != null and season.has_lineup(_team_id, _dh_enabled, _hand_mode)


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
		_set_status(Loc.t("sim.error.no_team"), true)
		queue_redraw()
		return
	var team: PSTeam = GameDb.get_team(_team_id)
	if team == null:
		_set_status(Loc.t("error.team_not_found"), true)
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
	_sort_fielders()

	var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, false)
	if bool(preview.get("ok", false)):
		_rotation_pitcher_id = int(preview.get("pitcher_id", 0))
		var pitcher: PSPlayerSeasonRecord = _record_by_id_in(RecordStore.get_team_player_records(_team_id, season.year, season.season_number), _rotation_pitcher_id)
		_rotation_pitcher_name = pitcher.name if pitcher != null else Loc.t("postseason.undecided")
	else:
		_rotation_pitcher_id = 0
		_rotation_pitcher_name = Loc.t("postseason.undecided")


func _load_backups(season: PSSeason) -> void:
	_backups = {}
	_shares = {}
	_effective_shares = {}
	_share_locked = {}
	_platoon_ids = {}
	_team_scheduled_games = _count_scheduled_games(season)
	var usage: Dictionary = season.get_fielder_usage(_team_id)
	var slots: Dictionary = usage.get("position_slots", {}) as Dictionary
	for pos_value in _share_positions():
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
	var lineup: Dictionary = season.get_lineup(_team_id, _dh_enabled, _hand_mode)
	if lineup.is_empty() or (lineup.get("batting_order", []) as Array).is_empty():
		var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, _dh_enabled, _hand_mode)
		if bool(preview.get("ok", false)):
			_apply_lineup(preview)
			_set_status(Loc.t("lineup.status.no_saved"), false)
		else:
			_set_status(Loc.t("common.auto_arrange_failed", {"reason": str(preview.get("message", ""))}), true)
	else:
		_apply_lineup(lineup)
		_set_status(Loc.t("lineup.status.showing_saved", {"day": SeasonCalendar.day_status_label(season, int(lineup.get("updated_at_day", 0)))}), false)
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
	var preview: Dictionary = GameSimulator.preview_lineup(season, _team_id, _dh_enabled, _hand_mode)
	if not bool(preview.get("ok", false)):
		_set_status(Loc.t("common.auto_arrange_failed", {"reason": str(preview.get("message", ""))}), true)
		queue_redraw()
		return
	_apply_lineup(preview)
	_assign_all_reserves(true)
	_set_status(Loc.t("common.auto_arrange_unsaved"), false)
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
		_set_status(Loc.t("common.cannot_save_before_season"), true)
		queue_redraw()
		return
	var errors: Array = _validate()
	if not errors.is_empty():
		_set_status(Loc.t("lineup.status.save_failed", {"errors": " / ".join(PackedStringArray(errors))}), true)
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
	season.set_lineup(_team_id, _dh_enabled, {"batting_order": batting_order}, _hand_mode)

	# 守備起用 (スタメン守備 + 控え=backup_ids + 出場配分)
	# 「自動」(share_locked=false) の枠は share 0.0 で保存し、PSTeamSetupBuilder 側の
	# AI 既定生成がシェアと併用相手を埋める。指定済みの枠は定期組み直しでも測り直されない。
	var position_slots: Dictionary = {}
	for pos_value in _share_positions():
		var pos: int = int(pos_value)
		var starter_id: int = _player_at_position(pos)
		var backup_ids: Array = (_backups.get(pos, []) as Array).duplicate()
		var locked: bool = bool(_share_locked.get(pos, false))
		var share: float = float(_shares.get(pos, SHARE_AUTO)) if locked else SHARE_AUTO
		# DH は「専任を指定した」ときだけ枠を保存する。未指定なら枠を持たせず、
		# エンジン側が毎試合「守備を外れた選手のうち打撃最良」を選ぶ。
		if pos == PSBattingOrderService.DH_POSITION and (not locked or starter_id <= 0):
			continue
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
	_set_status(Loc.t("common.saved_at", {"day": SeasonCalendar.day_status_label(season, season.current_day)}), false)
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
				errors.append(Loc.t("lineup.error.duplicate_position", {"pos": _short_pos(pos)}))
			positions_seen[pos] = true
		if pid > 0:
			if players_seen.has(pid):
				errors.append(Loc.t("lineup.error.duplicate_player", {"player": _player_name(pid)}))
			players_seen[pid] = true
	for pos_value in DEF_POSITIONS:
		if not positions_seen.has(int(pos_value)):
			errors.append(Loc.t("lineup.error.position_unset", {"pos": _short_pos(int(pos_value))}))
	if _dh_enabled and dh_count != 1:
		errors.append(Loc.t("lineup.error.dh_count", {"n": dh_count}))
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
	return TEXT


func _oaa_value(ad: PSAdvancedStats) -> float:
	return float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))


func _oaa_color(_ad: PSAdvancedStats) -> Color:
	return MUTED


func _bats(record: PSPlayerSeasonRecord) -> String:
	match record.batting_side:
		"L": return Loc.t("hand.left")
		"S": return Loc.t("hand.switch")
		_: return Loc.t("hand.right")


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
		return Loc.t("lineup.backup_short")
	return "%d%%" % int(round((1.0 - share) * 100.0))


# 規定打席に届く見込みの定位置選手数 (先発 = 規定打席 ÷ 打席/先発 を満たす枠の数)。
# 出場配分を触ったときに「何人が規定に届く編成なのか」をその場で見せるための概算。
func _projected_qualified_count() -> int:
	var required_starts: float = (
		float(_team_scheduled_games) * QUALIFIER_PA_PER_TEAM_GAME / PA_PER_START_ESTIMATE
	)
	var count: int = 0
	for pos_value in _share_positions():
		var pos: int = int(pos_value)
		if _player_at_position(pos) <= 0:
			continue
		if float(_share_games(_effective_share(pos))) >= required_starts:
			count += 1
	return count


func _short_pos(pos: int) -> String:
	return PSPlayer.position_short_name(pos)


# 守備位置の色は共有基底 dashboard_screen._pos_color を使う (全画面共通)。
# 選手登録と同一の見た目にするため基底の _chip (淡い塗り+色文字) を使う。
func _pos_badge(rect: Rect2, pos: int) -> void:
	_chip(rect, _short_pos(pos), _pos_color(pos))


func _grade_color(_value: int) -> Color:
	return TEXT


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error
