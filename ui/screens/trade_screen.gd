extends "res://ui/components/dashboard_screen.gd"

# トレード画面 (シーズン中トレード v1)。
# - 左: 自軍の支配下選手、右: 相手球団 (◀▶で切替) の支配下選手。行クリックで各1〜2人選択。
# - 左下: 選択内容の提案パネル (CPU が future_value + 需要で受諾判定)。
# - 右下: CPU からの受信提案 (受諾/拒否、期限つき)。
# - 下段: リーグ全体の成立履歴。交換期限 (7/31) 後は提案・受諾とも閉鎖。

const TABLE_MINE: Rect2 = Rect2(262, 124, 800, 440)
const TABLE_THEIRS: Rect2 = Rect2(1078, 124, 822, 440)
const PROPOSAL_RECT: Rect2 = Rect2(262, 578, 800, 214)
const OFFERS_RECT: Rect2 = Rect2(1078, 578, 822, 214)
const LOG_RECT: Rect2 = Rect2(262, 806, 1638, 252)

const POS_LABELS: Dictionary = {1: "投", 2: "捕", 3: "一", 4: "二", 5: "三", 6: "遊", 7: "左", 8: "中", 9: "右"}

const PLAYER_COLUMNS: Array = [
	{"title": "選手", "key": "name",   "w": 168, "align": "l", "fmt": "str"},
	{"title": "守/役", "key": "pos",   "w": 60,  "align": "l", "fmt": "str"},
	{"title": "年齢", "key": "age",    "w": 50,  "align": "r", "fmt": "int"},
	{"title": "年数", "key": "years",  "w": 50,  "align": "r", "fmt": "int"},
	{"title": "総合", "key": "value",  "w": 54,  "align": "r", "fmt": "int"},
	{"title": "将来", "key": "future", "w": 56,  "align": "r", "fmt": "int"},
	{"title": "年俸", "key": "salary", "w": 110, "align": "r", "fmt": "str"},
	{"title": "備考", "key": "note",   "w": 96,  "align": "l", "fmt": "str"},
]

const LOG_COLUMNS: Array = [
	{"title": "日",     "key": "day",     "w": 56,  "align": "r", "fmt": "int"},
	{"title": "球団A",  "key": "team_a",  "w": 150, "align": "l", "fmt": "str"},
	{"title": "放出",   "key": "a_gives", "w": 300, "align": "l", "fmt": "str"},
	{"title": "球団B",  "key": "team_b",  "w": 150, "align": "l", "fmt": "str"},
	{"title": "放出",   "key": "b_gives", "w": 300, "align": "l", "fmt": "str"},
	{"title": "種別",   "key": "source",  "w": 90,  "align": "l", "fmt": "str"},
]

var _row_hits: Array = []      # [{rect, kind, meta}]
var _scroll_zones: Array = []
var _scroll: Dictionary = {}

var _view_team_id: int = 0     # 相手球団
var _give_ids: Array = []      # 自軍から出す選手 id (最大 MAX_PLAYERS_PER_SIDE)
var _receive_ids: Array = []   # 相手から受け取る選手 id
var _selected_offer_id: int = 0
var _message: String = ""
var _message_color: Color = MUTED


func _ready() -> void:
	_init_chrome()
	_view_team_id = _next_opponent_id(AppState.selected_team_id, 1)
	_build_buttons()
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
	var status: String = "交換期限: %d年7月31日まで" % season.year if window_open \
		else "交換期限 (7月31日) を過ぎたため、今季のトレードはできません"
	_text(status, Vector2(INNER_L, 112.0), 13, MUTED if window_open else AMBER)
	_text("行クリック=選択 (各球団1〜%d人)" % TradeService.MAX_PLAYERS_PER_SIDE,
		Vector2(INNER_L + 560.0, 112.0), 12, FAINT)

	_draw_player_table(TABLE_MINE, "自軍: %s" % team.name, AppState.selected_team_id, _give_ids, "mine")
	var opponent: PSTeam = GameDb.get_team(_view_team_id)
	_draw_player_table(TABLE_THEIRS, "相手: %s" % (opponent.name if opponent != null else "-"), _view_team_id, _receive_ids, "theirs")

	_draw_proposal_panel(PROPOSAL_RECT, season, window_open)
	_draw_offers_panel(OFFERS_RECT, season)
	_draw_log_table(LOG_RECT, season)


func _draw_player_table(rect: Rect2, title: String, team_id: int, selected_ids: Array, sel_kind: String) -> void:
	var rows: Array = _player_rows(team_id)
	var opts: Dictionary = {
		"title": title, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
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


func _player_rows(team_id: int) -> Array:
	var rows: Array = []
	var entries: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or player.development_player:
			continue
		entries.append(player)
	entries.sort_custom(func(a, b) -> bool:
		return OffseasonService.player_value_score(a as PSPlayer) > OffseasonService.player_value_score(b as PSPlayer))
	for entry in entries:
		var player: PSPlayer = entry as PSPlayer
		var tradeable: bool = TradeService.is_tradeable(player)
		var row: Dictionary = {
			"__meta": player.id,
			"name": player.name,
			"pos": _pos_label(player),
			"age": player.age,
			"years": player.years,
			"value": OffseasonService.player_value_score(player),
			"future": int(round(TradeService.trade_value(player))),
			"salary": _format_money(player.salary),
			"note": _note_for(player, tradeable),
		}
		if not tradeable:
			row["__color"] = FAINT
		rows.append(row)
	return rows


func _pos_label(player: PSPlayer) -> String:
	if player.is_pitcher():
		return "先発" if player.is_starter_pitcher() else "中継"
	return str(POS_LABELS.get(player.position, "?"))


func _note_for(player: PSPlayer, tradeable: bool) -> String:
	if tradeable:
		return ""
	if player.foreign_player:
		return "外国人"
	if player.injury_days > 0:
		return "怪我 %d日" % player.injury_days
	if bool(player.source_data.get("free_agent", false)):
		return "FA宣言中"
	if bool(player.source_data.get("rookie_year", false)) and player.years <= 1:
		return "新人"
	return "対象外"


func _draw_proposal_panel(rect: Rect2, _season: PSSeason, window_open: bool) -> void:
	_round(rect, PANEL, BORDER, 10)
	_text("トレード提案", Vector2(rect.position.x + 18, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var y: float = rect.position.y + 64.0
	_text("出す:", Vector2(rect.position.x + 18, y), 13, MUTED)
	_text(_names_line(_give_ids), Vector2(rect.position.x + 70, y), 13, TEXT, rect.size.x - 90.0)
	y += 28.0
	_text("貰う:", Vector2(rect.position.x + 18, y), 13, MUTED)
	_text(_names_line(_receive_ids), Vector2(rect.position.x + 70, y), 13, TEXT, rect.size.x - 90.0)

	if not window_open:
		_text("交換期限を過ぎています", Vector2(rect.position.x + 18, rect.end.y - 58.0), 13, AMBER)
	elif not _message.is_empty():
		_text(_message, Vector2(rect.position.x + 18, rect.end.y - 58.0), 13, _message_color, rect.size.x - 220.0)


func _draw_offers_panel(rect: Rect2, season: PSSeason) -> void:
	_round(rect, PANEL, BORDER, 10)
	_text("相手球団からの提案", Vector2(rect.position.x + 18, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var offers: Array = TradeService.pending_user_offers(season)
	if offers.is_empty():
		_text("現在、届いている提案はありません", Vector2(rect.position.x + 18, rect.position.y + 78.0), 13, MUTED)
		return

	var y: float = rect.position.y + 58.0
	for offer_value in offers:
		var offer: Dictionary = offer_value as Dictionary
		var offer_id: int = int(offer.get("id", 0))
		var cpu_team: PSTeam = GameDb.get_team(int(offer.get("cpu_team_id", 0)))
		var line: String = "%s: %s ⇄ 自軍 %s (期限 day%d)" % [
			cpu_team.name if cpu_team != null else "?",
			_offer_names(offer, "cpu_player_ids"),
			_offer_names(offer, "user_player_ids"),
			int(offer.get("expires_day", 0)),
		]
		var row_rect: Rect2 = Rect2(rect.position.x + 12.0, y - 16.0, rect.size.x - 24.0, 26.0)
		if offer_id == _selected_offer_id:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), Color(BLUE.r, BLUE.g, BLUE.b, 0.75), 6, 2)
		_row_hits.append({"rect": row_rect, "kind": "offer", "meta": offer_id})
		_text(line, Vector2(rect.position.x + 18, y), 13, TEXT, rect.size.x - 200.0)
		y += 30.0
		if y > rect.end.y - 60.0:
			break
	_text("提案を選んで受諾/拒否", Vector2(rect.position.x + 18, rect.end.y - 16.0), 11, FAINT)


func _offer_names(offer: Dictionary, key: String) -> String:
	var names: Array = []
	for id_value in offer.get(key, []) as Array:
		var player: PSPlayer = GameDb.get_player(int(id_value))
		names.append(player.name if player != null else "?")
	return "、".join(PackedStringArray(names))


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
		"title": "今季の成立トレード", "header_top": 58.0, "row_h": 26.0, "alt_rows": true,
		"cell_size": 12, "empty_text": "今季の成立トレードはまだありません",
		"scroll_key": "log", "scroll": _scroll, "scroll_zones": _scroll_zones,
	})


func _source_label(source: String) -> String:
	match source:
		"cpu": return "球団間"
		"user_offer": return "受諾"
		"user_proposal": return "自軍提案"
		_: return source


func _names_line(ids: Array) -> String:
	if ids.is_empty():
		return "(未選択)"
	var names: Array = []
	for id_value in ids:
		var player: PSPlayer = GameDb.get_player(int(id_value))
		names.append("%s (%s)" % [player.name, _pos_label(player)] if player != null else "?")
	return "、".join(PackedStringArray(names))


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	if season == null or GameDb.get_team(AppState.selected_team_id) == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# 相手球団切替 (テーブル右肩)。
	_add_button("prev_team", "◀", Rect2(TABLE_THEIRS.end.x - 96, TABLE_THEIRS.position.y + 12, 36, 28),
		func() -> void: _cycle_opponent(-1), "chip")
	_add_button("next_team", "▶", Rect2(TABLE_THEIRS.end.x - 52, TABLE_THEIRS.position.y + 12, 36, 28),
		func() -> void: _cycle_opponent(1), "chip")

	_add_button("propose", "この内容で提案する", Rect2(PROPOSAL_RECT.end.x - 232, PROPOSAL_RECT.end.y - 60, 210, 40),
		func() -> void: _submit_proposal(), "primary")
	_add_button("clear_sel", "選択をクリア", Rect2(PROPOSAL_RECT.end.x - 380, PROPOSAL_RECT.end.y - 60, 130, 40),
		func() -> void: _clear_selection(), "chip")

	_add_button("offer_accept", "受諾", Rect2(OFFERS_RECT.end.x - 200, OFFERS_RECT.end.y - 60, 84, 40),
		func() -> void: _accept_selected_offer(), "primary")
	_add_button("offer_decline", "拒否", Rect2(OFFERS_RECT.end.x - 104, OFFERS_RECT.end.y - 60, 84, 40),
		func() -> void: _decline_selected_offer(), "chip")

	_layout_buttons()


func _cycle_opponent(step: int) -> void:
	_view_team_id = _next_opponent_id(_view_team_id, step)
	_receive_ids = []
	queue_redraw()


func _next_opponent_id(from_id: int, step: int) -> int:
	var ids: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id != AppState.selected_team_id:
			ids.append(team.id)
	if ids.is_empty():
		return 0
	var index: int = ids.find(from_id)
	if index < 0:
		return int(ids[0])
	return int(ids[posmod(index + step, ids.size())])


# ============================================================ actions

func _submit_proposal() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	if _give_ids.is_empty() or _receive_ids.is_empty():
		_set_message("出す選手と貰う選手を選んでください。", AMBER)
		return
	var result: Dictionary = TradeService.submit_user_proposal(
		season, GameDb.players, GameDb.teams, AppState.selected_team_id, _give_ids.duplicate(), _receive_ids.duplicate())
	if bool(result.get("accepted", false)):
		GameDb.rebuild_player_indices()
		_clear_selection()
		_set_message("トレードが成立しました!", GREEN)
	else:
		_set_message(str(result.get("message", "交渉はまとまりませんでした。")), AMBER)
	queue_redraw()


func _accept_selected_offer() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _selected_offer_id <= 0:
		_set_message("受諾する提案を選んでください。", AMBER)
		queue_redraw()
		return
	var result: Dictionary = TradeService.accept_user_offer(season, GameDb.players, GameDb.teams, _selected_offer_id, AppState.selected_team_id)
	if bool(result.get("ok", false)):
		GameDb.rebuild_player_indices()
		_set_message("提案を受諾し、トレードが成立しました!", GREEN)
	else:
		_set_message(str(result.get("message", "受諾できませんでした。")), AMBER)
	_selected_offer_id = 0
	queue_redraw()


func _decline_selected_offer() -> void:
	var season: PSSeason = AppState.current_season
	if season == null or _selected_offer_id <= 0:
		_set_message("拒否する提案を選んでください。", AMBER)
		queue_redraw()
		return
	TradeService.decline_user_offer(season, _selected_offer_id)
	_selected_offer_id = 0
	_set_message("提案を拒否しました。", MUTED)
	queue_redraw()


func _clear_selection() -> void:
	_give_ids = []
	_receive_ids = []
	_message = ""
	queue_redraw()


func _set_message(text: String, color: Color) -> void:
	_message = text
	_message_color = color


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
				"mine":
					_toggle_selection(_give_ids, int(hit.get("meta", 0)))
				"theirs":
					_toggle_selection(_receive_ids, int(hit.get("meta", 0)))
				"offer":
					_selected_offer_id = int(hit.get("meta", 0))
			queue_redraw()
			accept_event()
		MOUSE_BUTTON_RIGHT:
			var hit2: Dictionary = _row_at(base_pos)
			if not hit2.is_empty() and str(hit2.get("kind", "")) in ["mine", "theirs"]:
				AppState.show_player_detail(int(hit2.get("meta", 0)))
				accept_event()


func _toggle_selection(ids: Array, player_id: int) -> void:
	if ids.has(player_id):
		ids.erase(player_id)
		_message = ""
		return
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null or not TradeService.is_tradeable(player):
		_set_message("%s はトレード対象にできません。" % (player.name if player != null else "その選手"), AMBER)
		return
	if ids.size() >= TradeService.MAX_PLAYERS_PER_SIDE:
		_set_message("選択できるのは各球団%d人までです。" % TradeService.MAX_PLAYERS_PER_SIDE, AMBER)
		return
	ids.append(player_id)
	_message = ""


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
