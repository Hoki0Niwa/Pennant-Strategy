extends "res://ui/components/dashboard_screen.gd"

# 年間表彰画面。AppState.current_awards と current_postseason を読み、
# 日本一、MVP、新人王、打撃タイトル、投手タイトル、ベストナイン、ゴールデン・グラブ賞を
# シーズン終了時の結果として表示する。ベストナイン/ゴールデン・グラブの選出は AwardsService。

const BATTING_TITLE_LABELS: Dictionary = {
	"average": "首位打者",
	"home_runs": "本塁打王",
	"rbi": "打点王",
	"stolen_bases": "盗塁王",
	"hits": "最多安打",
}

const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "最多勝利",
	"era": "最優秀防御率",
	"strikeouts": "最多奪三振",
	"saves": "最多セーブ",
	"holds": "最多ホールド",
	"win_rate": "最高勝率",
}

const CHAMP_RECT: Rect2 = Rect2(262, 112, 1068, 128)
const AWARDS_RECT: Rect2 = Rect2(262, 254, 1068, 178)
const BAT_RECT: Rect2 = Rect2(262, 446, 1068, 284)
const PIT_RECT: Rect2 = Rect2(262, 744, 1068, 314)
const BEST_NINE_RECT: Rect2 = Rect2(1350, 112, 550, 463)
const GOLDEN_GLOVE_RECT: Rect2 = Rect2(1350, 595, 550, 463)

# 各パネル内は幅が狭い (2リーグ並列) ため、スロット名は 1〜2 文字の短縮ラベルで描く。
# 並びは PSAwards.BEST_NINE_SLOT_POSITIONS / GOLDEN_GLOVE_SLOT_POSITIONS に一致させる。
const BEST_NINE_SLOT_LABELS: Array = ["投", "捕", "一", "二", "三", "遊", "外", "外", "外", "DH"]
const GOLDEN_GLOVE_SLOT_LABELS: Array = ["投", "捕", "一", "二", "三", "遊", "外", "外", "外"]

var _has_awards: bool = false
var _season_label: String = ""
var _status_text: String = ""
var _champion_id: int = 0
var _champion_series_text: String = ""
var _award_rows: Array = []
var _bat_rows: Array = []
var _pit_rows: Array = []
# {"central": Array[cell], "pacific": Array[cell]}。cell = {pid, name, team_id, value}。
var _best_nine: Dictionary = {"central": [], "pacific": []}
var _golden_glove: Dictionary = {"central": [], "pacific": []}
var _player_hits: Array = []
var _hover_pid: int = 0


func _ready() -> void:
	_init_chrome()
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_update_transform()
			var hit: Dictionary = _player_at(_to_base(event.position))
			var pid: int = int(hit.get("pid", 0))
			if pid > 0:
				AppState.show_player_detail(pid)
	elif event is InputEventMouseMotion:
		_update_transform()
		var pid: int = int(_player_at(_to_base(event.position)).get("pid", 0))
		if pid != _hover_pid:
			_hover_pid = pid
			queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


func _player_at(base_pos: Vector2) -> Dictionary:
	for hit_value in _player_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return hit
	return {}


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_player_hits = []

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_draw_empty()
		return

	_draw_shell("年間表彰", team, season)

	if not _has_awards:
		_draw_no_awards()
		return

	_text(_season_label, Vector2(INNER_L, 102), 13, MUTED)
	_draw_champion_panel(CHAMP_RECT)
	_draw_award_table(AWARDS_RECT, "最優秀選手・新人王", _award_rows, BLUE, "賞")
	_draw_award_table(BAT_RECT, "打撃タイトル", _bat_rows, GREEN, "部門")
	_draw_award_table(PIT_RECT, "投手タイトル", _pit_rows, PINK, "部門")
	_draw_award_grid(BEST_NINE_RECT, "ベストナイン", BLUE, BEST_NINE_SLOT_LABELS, PSAwards.BEST_NINE_SLOT_POSITIONS, _best_nine)
	_draw_award_grid(GOLDEN_GLOVE_RECT, "ゴールデン・グラブ賞", AMBER, GOLDEN_GLOVE_SLOT_LABELS, PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS, _golden_glove)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1076), 12, RED)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)


func _draw_no_awards() -> void:
	_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
	_text("表彰データがありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text("ポストシーズン終了後、またはシーズン終了後に表彰が計算されます。",
		Vector2(560, 548), 14, MUTED, 800, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_champion_panel(rect: Rect2) -> void:
	# 枠は使わず、日本一決定時はアンバーの地色だけで強調する。
	if _champion_id > 0:
		_round(rect, Color(AMBER.r, AMBER.g, AMBER.b, 0.10), Color.TRANSPARENT, 10, 0)
	else:
		_round(rect, PANEL, Color.TRANSPARENT, 10, 0)
	_text("日本一", Vector2(rect.position.x + 24, rect.position.y + 36), 18, AMBER, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_season_label, Vector2(rect.end.x - 260, rect.position.y + 34), 13, MUTED, 240, HORIZONTAL_ALIGNMENT_RIGHT)

	if _champion_id <= 0:
		_text("ポストシーズンの記録がありません", Vector2(rect.position.x + 24, rect.position.y + 86), 18, MUTED)
		return

	var team: PSTeam = GameDb.get_team(_champion_id)
	if team == null:
		_text("ID %d" % _champion_id, Vector2(rect.position.x + 24, rect.position.y + 88), 24, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
		return

	_team_badge(Rect2(rect.position.x + 24, rect.position.y + 58, 44, 44), team)
	_text(team.name, Vector2(rect.position.x + 82, rect.position.y + 91), 28, TEXT, rect.size.x - 360, HORIZONTAL_ALIGNMENT_LEFT, true)
	if not _champion_series_text.is_empty():
		_chip(Rect2(rect.end.x - 194, rect.position.y + 64, 156, 28), _champion_series_text, AMBER)


func _draw_award_table(rect: Rect2, title: String, rows: Array, accent: Color, label_header: String) -> void:
	_panel(rect, title)
	_round(Rect2(rect.position.x + 18, rect.position.y + 44, 54, 3), accent, Color.TRANSPARENT, 1, 0)

	var inner_x: float = rect.position.x + 18.0
	var usable: float = rect.size.x - 36.0
	var label_w: float = 150.0
	var gap: float = 14.0
	var league_w: float = (usable - label_w - gap * 2.0) / 2.0
	var c1_x: float = inner_x + label_w + gap
	var c2_x: float = c1_x + league_w + gap

	var hy: float = rect.position.y + 64.0
	_round(Rect2(inner_x, hy - 18.0, usable, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_text(label_header, Vector2(inner_x + 2.0, hy), 11, MUTED, label_w - 4.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("第1リーグ", Vector2(c1_x + 4.0, hy), 11, MUTED, league_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("第2リーグ", Vector2(c2_x + 4.0, hy), 11, MUTED, league_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_line(Vector2(inner_x, rect.position.y + 72.0), Vector2(rect.end.x - 18.0, rect.position.y + 72.0), BORDER, 1.5)

	if rows.is_empty():
		_text("記録がありません", Vector2(inner_x + 4.0, rect.position.y + 110.0), 13, MUTED)
		return

	var row_top: float = rect.position.y + 82.0
	var row_h: float = (rect.end.y - row_top - 14.0) / float(rows.size())
	for i in range(rows.size()):
		var row: Dictionary = rows[i] as Dictionary
		var ry: float = row_top + float(i) * row_h
		var ty: float = ry + row_h * 0.5 + 5.0
		_text(str(row.get("label", "")), Vector2(inner_x + 2.0, ty), 14, MUTED, label_w - 4.0, HORIZONTAL_ALIGNMENT_LEFT, true)
		_draw_player_cell(Rect2(c1_x, ry + 3.0, league_w, row_h - 6.0), row.get("central", {}) as Dictionary)
		_draw_player_cell(Rect2(c2_x, ry + 3.0, league_w, row_h - 6.0), row.get("pacific", {}) as Dictionary)
		_line(Vector2(inner_x, ry + row_h), Vector2(rect.end.x - 18.0, ry + row_h), HAIRLINE, 1.0)


func _draw_player_cell(rect: Rect2, cell: Dictionary) -> void:
	var pid: int = int(cell.get("pid", 0))
	var ty: float = rect.position.y + rect.size.y * 0.5 + 5.0
	if pid <= 0:
		_text("(該当なし)", Vector2(rect.position.x + 4.0, ty), 13, FAINT, rect.size.x - 8.0)
		return

	var hover: bool = pid == _hover_pid
	if hover:
		_round(rect, Color(1, 1, 1, 0.055), Color.TRANSPARENT, 6, 0)

	var team_id: int = int(cell.get("team_id", 0))
	var team: PSTeam = GameDb.get_team(team_id)
	var dot_col: Color = team.color if team != null else MUTED
	var team_text: String = team.short_name if team != null else "-"
	_dot(Vector2(rect.position.x + 8.0, rect.position.y + rect.size.y * 0.5), 5.0, dot_col)
	_text(team_text, Vector2(rect.position.x + 20.0, ty), 12, MUTED, 44.0)

	var value_text: String = str(cell.get("value", ""))
	var value_w: float = 86.0 if not value_text.is_empty() else 0.0
	var name_x: float = rect.position.x + 68.0
	var name_w: float = rect.size.x - 72.0 - value_w
	# 選手名は常時 bold (strong)。hover は背景の淡いハイライトで示す。
	_text(str(cell.get("name", "")), Vector2(name_x, ty), 14, TEXT, name_w, HORIZONTAL_ALIGNMENT_LEFT, true)
	if not value_text.is_empty():
		_text_right(value_text, rect.end.x - 4.0, ty, 13, AMBER, value_w)

	_player_hits.append({"rect": rect, "pid": pid})


# ベストナイン / ゴールデン・グラブ賞の 2 リーグ並列グリッド。左半分=第1リーグ、右半分=第2リーグ。
# 各行はスロット短縮ラベル (守備位置色) + 選手 (球団色ドット + 名前) + 選定指標値。
# slot_labels / slot_positions は同じ長さで、値は _best_nine / _golden_glove の列と対応する。
func _draw_award_grid(rect: Rect2, title: String, accent: Color, slot_labels: Array, slot_positions: Array, columns: Dictionary) -> void:
	_panel(rect, title)
	_round(Rect2(rect.position.x + 18, rect.position.y + 44, 54, 3), accent, Color.TRANSPARENT, 1, 0)

	var inner: Rect2 = Rect2(rect.position.x + 18, rect.position.y + 70, rect.size.x - 36, rect.size.y - 92)
	_round(inner, PANEL_2, Color.TRANSPARENT, 8, 0)

	var col_w: float = inner.size.x * 0.5
	var league_keys: Array = ["central", "pacific"]
	var league_labels: Array = ["第1リーグ", "第2リーグ"]

	# 列見出し + 中央の縦区切り。
	var hy: float = inner.position.y + 28.0
	for li in range(2):
		_text(str(league_labels[li]), Vector2(inner.position.x + col_w * float(li) + 16.0, hy), 12, MUTED, col_w - 24.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_line(Vector2(inner.position.x + 14, inner.position.y + 40), Vector2(inner.end.x - 14, inner.position.y + 40), BORDER, 1.5)
	_line(Vector2(inner.position.x + col_w, inner.position.y + 14), Vector2(inner.position.x + col_w, inner.end.y - 14), BORDER_SOFT, 1.0)

	var row_top: float = inner.position.y + 52.0
	var row_h: float = (inner.end.y - row_top - 12.0) / float(slot_labels.size())
	for i in range(slot_labels.size()):
		var y: float = row_top + float(i) * row_h
		var pos: int = int(slot_positions[i])
		for li in range(2):
			var cx: float = inner.position.x + col_w * float(li)
			var cells: Array = columns.get(league_keys[li], []) as Array
			var cell: Dictionary = cells[i] as Dictionary if i < cells.size() else {}
			_draw_award_cell(Rect2(cx + 8.0, y + 2.0, col_w - 16.0, row_h - 4.0), str(slot_labels[i]), pos, cell)
		if i < slot_labels.size() - 1:
			_line(Vector2(inner.position.x + 12, y + row_h), Vector2(inner.end.x - 12, y + row_h), HAIRLINE, 1.0)


func _draw_award_cell(rect: Rect2, slot_label: String, slot_pos: int, cell: Dictionary) -> void:
	var ty: float = rect.position.y + rect.size.y * 0.5 + 5.0
	# スロットラベルは守備位置色 (投=PINK / 捕=BLUE / 内野=AMBER / 外野=GREEN / DH=VIOLET) で描く。
	_text(slot_label, Vector2(rect.position.x + 2.0, ty), 13, _pos_color(slot_pos), 26.0, HORIZONTAL_ALIGNMENT_CENTER, true)

	var body_x: float = rect.position.x + 32.0
	var body_w: float = rect.end.x - body_x
	var pid: int = int(cell.get("pid", 0))
	if pid <= 0:
		_text("(該当なし)", Vector2(body_x + 4.0, ty), 12, FAINT, body_w - 8.0)
		return

	if pid == _hover_pid:
		_round(Rect2(body_x - 2.0, rect.position.y, body_w, rect.size.y), Color(1, 1, 1, 0.055), Color.TRANSPARENT, 6, 0)

	var team: PSTeam = GameDb.get_team(int(cell.get("team_id", 0)))
	var dot_col: Color = team.color if team != null else MUTED
	_dot(Vector2(body_x + 6.0, rect.position.y + rect.size.y * 0.5), 4.5, dot_col)

	var value_text: String = str(cell.get("value", ""))
	var value_w: float = 62.0 if not value_text.is_empty() else 0.0
	var name_x: float = body_x + 18.0
	var name_w: float = body_w - 22.0 - value_w
	_text(str(cell.get("name", "")), Vector2(name_x, ty), 13, TEXT, name_w, HORIZONTAL_ALIGNMENT_LEFT, true)
	if not value_text.is_empty():
		_text_right(value_text, rect.end.x - 2.0, ty, 12, AMBER, value_w)

	_player_hits.append({"rect": Rect2(body_x - 2.0, rect.position.y, body_w, rect.size.y), "pid": pid})


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()
	_add_button("offseason", "オフシーズンへ", Rect2(1738, 22, 162, 42), _on_offseason_pressed, "primary")
	_layout_buttons()


func _on_offseason_pressed() -> void:
	var result: Dictionary = AppState.start_offseason()
	if not bool(result.get("ok", false)):
		_status_text = str(result.get("message", ""))
		queue_redraw()


# ============================================================ aggregation

func _refresh() -> void:
	_has_awards = false
	_season_label = ""
	_status_text = ""
	_champion_id = 0
	_champion_series_text = ""
	_award_rows = []
	_bat_rows = []
	_pit_rows = []
	_best_nine = {"central": [], "pacific": []}
	_golden_glove = {"central": [], "pacific": []}

	var awards: PSAwards = AppState.current_awards
	if awards == null:
		return
	_has_awards = true
	_season_label = "%d年 / %d年目" % [awards.year, awards.season_number]

	var postseason: PSPostseasonResult = AppState.current_postseason
	if postseason != null and postseason.champion_team_id > 0:
		_champion_id = postseason.champion_team_id
		_champion_series_text = _japan_series_record(postseason)

	_award_rows = [
		{"label": "MVP", "central": _player_cell(awards.mvp_central_player_id), "pacific": _player_cell(awards.mvp_pacific_player_id)},
		{"label": "新人王", "central": _player_cell(awards.rookie_central_player_id), "pacific": _player_cell(awards.rookie_pacific_player_id)},
	]
	_bat_rows = _build_title_rows(awards.batting_titles, BATTING_TITLE_LABELS, PSAwards.BATTING_CATEGORIES, false)
	_pit_rows = _build_title_rows(awards.pitching_titles, PITCHING_TITLE_LABELS, PSAwards.PITCHING_CATEGORIES, true)
	_best_nine = _build_award_columns(awards.best_nine)
	_golden_glove = _build_award_columns(awards.golden_glove)


func _build_title_rows(titles: Dictionary, label_map: Dictionary, keys_order: Array, is_pitcher: bool) -> Array:
	var central: Dictionary = titles.get("central", {}) as Dictionary
	var pacific: Dictionary = titles.get("pacific", {}) as Dictionary
	var rows: Array = []
	for key in keys_order:
		rows.append({
			"label": str(label_map.get(key, key)),
			"central": _player_cell(int(central.get(key, 0)), str(key), is_pitcher),
			"pacific": _player_cell(int(pacific.get(key, 0)), str(key), is_pitcher),
		})
	return rows


# awards.best_nine / golden_glove (league → Array[{pid, value}]) を表示用に解決する。
# 返り値 {"central": Array[cell], "pacific": Array[cell]}、cell = {pid, name, team_id, value}。
func _build_award_columns(data: Dictionary) -> Dictionary:
	return {
		"central": _resolve_award_slots(data.get("central", []) as Array),
		"pacific": _resolve_award_slots(data.get("pacific", []) as Array),
	}


func _resolve_award_slots(entries: Array) -> Array:
	var out: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var pid: int = int(entry.get("pid", 0))
		var cell: Dictionary = {"pid": pid, "name": "(該当なし)", "team_id": 0, "value": str(entry.get("value", ""))}
		if pid > 0:
			var record: PSPlayerSeasonRecord = _player_record(pid)
			if record != null:
				cell["name"] = record.name
				cell["team_id"] = record.team_id
			else:
				var player: PSPlayer = GameDb.get_player(pid)
				cell["name"] = player.name if player != null else "ID %d" % pid
				cell["team_id"] = player.team_id if player != null else 0
		else:
			cell["value"] = ""
		out.append(cell)
	return out


func _player_cell(player_id: int, title_key: String = "", is_pitcher: bool = false) -> Dictionary:
	var cell: Dictionary = {"pid": player_id, "name": "(該当なし)", "team_id": 0, "value": ""}
	if player_id <= 0:
		return cell
	var record: PSPlayerSeasonRecord = _player_record(player_id)
	if record == null:
		var player: PSPlayer = GameDb.get_player(player_id)
		cell["name"] = player.name if player != null else "ID %d" % player_id
		cell["team_id"] = player.team_id if player != null else 0
	else:
		cell["name"] = record.name
		cell["team_id"] = record.team_id
		if not title_key.is_empty():
			cell["value"] = _title_value(record, title_key, is_pitcher)
	return cell


func _japan_series_record(postseason: PSPostseasonResult) -> String:
	var js: Dictionary = postseason.japan_series
	if js.is_empty():
		return ""
	var top_wins: int = int(js.get("top_wins_final", 0))
	var chal_wins: int = int(js.get("challenger_wins_final", 0))
	var winner_is_top: bool = int(js.get("winner_id", 0)) == int(js.get("top_id", 0))
	var w: int = top_wins if winner_is_top else chal_wins
	var l: int = chal_wins if winner_is_top else top_wins
	return "%d勝%d敗" % [w, l]


func _title_value(record: PSPlayerSeasonRecord, title_key: String, is_pitcher: bool) -> String:
	if is_pitcher:
		var ps: PSPitcherStats = record.pitcher_stats
		match title_key:
			"wins":
				return "%d勝" % ps.wins
			"era":
				if ps.outs_pitched <= 0:
					return "--"
				return "%0.2f" % ps.era()
			"strikeouts":
				return "%dK" % ps.strikeouts
			"saves":
				return "%dS" % ps.saves
			"holds":
				return "%dH" % ps.holds
			"win_rate":
				var dec: int = ps.wins + ps.losses
				if dec <= 0:
					return "--"
				return ".%03d" % int(round(float(ps.wins) / float(dec) * 1000))
			_:
				return ""
	var bs: PSBatterStats = record.batter_stats
	match title_key:
		"average":
			return ".%03d" % int(round(bs.batting_average() * 1000))
		"home_runs":
			return "%d本" % bs.home_runs
		"rbi":
			return "%d点" % bs.runs_batted_in
		"stolen_bases":
			return "%d盗" % bs.stolen_bases
		"hits":
			return "%d安" % bs.hits
		_:
			return ""


func _player_record(player_id: int) -> PSPlayerSeasonRecord:
	var season: PSSeason = AppState.current_season
	if season == null:
		return null
	return RecordStore.get_player_record(player_id, season.year, season.season_number)
