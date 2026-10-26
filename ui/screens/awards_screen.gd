extends "res://ui/components/dashboard_screen.gd"

# 年間表彰画面。AppState.current_awards と current_postseason を読み、
# 日本一、MVP、新人王、打撃タイトル、投手タイトル、ベストナイン、ゴールデン・グラブ賞を
# シーズン終了時の結果として表示する。ベストナイン/ゴールデン・グラブの選出は AwardsService。

# タイトル名のキー (Loc)。
const BATTING_TITLE_LABELS: Dictionary = {
	"average": "award.title.average",
	"home_runs": "award.title.home_runs",
	"rbi": "award.title.rbi",
	"stolen_bases": "award.title.stolen_bases",
	"hits": "award.title.hits",
}

const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "award.title.wins",
	"era": "award.title.era",
	"strikeouts": "award.title.strikeouts",
	"saves": "award.title.saves",
	"holds": "award.title.holds",
	"win_rate": "award.title.win_rate",
}

const LEAGUE_KEYS: Array = ["league1", "league2"]

# 受賞者表 (パネル内) の上端。2 段見出しが header_top 68 から始まるため、タイトル/アクセント線の下に収まる位置に置く。
const TABLE_TOP: float = 20.0

const CHAMP_RECT: Rect2 = Rect2(262, 112, 1068, 128)
const AWARDS_RECT: Rect2 = Rect2(262, 254, 1068, 178)
const BAT_RECT: Rect2 = Rect2(262, 446, 1068, 284)
const PIT_RECT: Rect2 = Rect2(262, 744, 1068, 314)
const BEST_NINE_RECT: Rect2 = Rect2(1350, 112, 550, 463)
const GOLDEN_GLOVE_RECT: Rect2 = Rect2(1350, 595, 550, 463)

# 各パネル内は幅が狭い (2リーグ並列) ため、スロット名は 1〜2 文字の短縮ラベルで描く。
# 並びは PSAwards.BEST_NINE_SLOT_POSITIONS / GOLDEN_GLOVE_SLOT_POSITIONS に一致させる。
# 値はスロット名のキー (Loc)。
const BEST_NINE_SLOT_LABELS: Array = [
	"position_short.pitcher", "position_short.catcher", "position_short.first_base", "position_short.second_base",
	"position_short.third_base", "position_short.shortstop", "award.slot.outfield", "award.slot.outfield", "award.slot.outfield",
	"position_short.dh",
]
const GOLDEN_GLOVE_SLOT_LABELS: Array = [
	"position_short.pitcher", "position_short.catcher", "position_short.first_base", "position_short.second_base",
	"position_short.third_base", "position_short.shortstop", "award.slot.outfield", "award.slot.outfield", "award.slot.outfield",
]

var _has_awards: bool = false
var _season_label: String = ""
var _status_text: String = ""
var _champion_id: int = 0
var _champion_series_text: String = ""
var _award_rows: Array = []
var _bat_rows: Array = []
var _pit_rows: Array = []
# {"league1": Array[cell], "league2": Array[cell]}。cell = {pid, name, team_id, value}。
var _best_nine: Dictionary = {"league1": [], "league2": []}
var _golden_glove: Dictionary = {"league1": [], "league2": []}
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

	_draw_shell(Loc.t("award.screen_title"), team, season)

	if not _has_awards:
		_draw_no_awards()
		return

	_text(_season_label, Vector2(INNER_L, 102), 13, MUTED)
	_draw_champion_panel(CHAMP_RECT)
	_draw_award_table(AWARDS_RECT, Loc.t("award.panel.mvp_rookie"), _award_rows, BLUE, Loc.t("award.header.award"))
	_draw_award_table(BAT_RECT, Loc.t("award.panel.batting"), _bat_rows, GREEN, Loc.t("award.header.category"))
	_draw_award_table(PIT_RECT, Loc.t("award.panel.pitching"), _pit_rows, PINK, Loc.t("award.header.category"))
	_draw_award_grid(BEST_NINE_RECT, Loc.t("award.best_nine"), BLUE, BEST_NINE_SLOT_LABELS, PSAwards.BEST_NINE_SLOT_POSITIONS, _best_nine)
	_draw_award_grid(GOLDEN_GLOVE_RECT, Loc.t("award.golden_glove"), AMBER, GOLDEN_GLOVE_SLOT_LABELS, PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS, _golden_glove)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1076), 12, RED)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text(Loc.t("flow.error.season_not_started"), Vector2(770, 496), 20, MUTED)


func _draw_no_awards() -> void:
	_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
	_text(Loc.t("award.none"), Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(Loc.t("award.none_hint"),
		Vector2(560, 548), 14, MUTED, 800, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_champion_panel(rect: Rect2) -> void:
	# 枠は使わず、日本一決定時はアンバーの地色だけで強調する。
	if _champion_id > 0:
		_round(rect, Color(AMBER.r, AMBER.g, AMBER.b, 0.10), Color.TRANSPARENT, 10, 0)
	else:
		_round(rect, PANEL, Color.TRANSPARENT, 10, 0)
	_text(Loc.t("award.champion"), Vector2(rect.position.x + 24, rect.position.y + 36), 18, AMBER, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_season_label, Vector2(rect.end.x - 260, rect.position.y + 34), 13, MUTED, 240, HORIZONTAL_ALIGNMENT_RIGHT)

	if _champion_id <= 0:
		_text(Loc.t("award.no_postseason"), Vector2(rect.position.x + 24, rect.position.y + 86), 18, MUTED)
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

	if rows.is_empty():
		_text(Loc.t("common.no_records"), Vector2(rect.position.x + 22.0, rect.position.y + 110.0), 13, MUTED)
		return

	var label_columns: Array = [
		{"title": label_header, "key": "label", "w": 150, "align": "l", "strong": true, "group": "award.group.category"},
	]
	var label_rows: Array = []
	var league_rows: Dictionary = {"league1": [], "league2": []}
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		label_rows.append({"label": str(row.get("label", ""))})
		for key in LEAGUE_KEYS:
			(league_rows[key] as Array).append(_league_row(row.get(key, {}) as Dictionary))
	_draw_league_split_table(rect, label_columns, label_rows, league_rows, 150.0, [70, 250, 121])


# 受賞者セル → 共通表の行。受賞者なしは球団ドットを消して "該当なし" を FAINT で出す。
func _league_row(cell: Dictionary) -> Dictionary:
	var pid: int = int(cell.get("pid", 0))
	if pid <= 0:
		return {"team": "", "color": Color.TRANSPARENT, "name": Loc.t("common.none_applicable"), "val": "", "__color": FAINT}
	var team: PSTeam = GameDb.get_team(int(cell.get("team_id", 0)))
	var player: PSPlayer = GameDb.get_player(pid)
	return {
		"team": team.short_name if team != null else "-",
		"color": team.color if team != null else MUTED,
		"name": str(cell.get("name", "")),
		"jersey": player.jersey_number if player != null else 0,
		"val": str(cell.get("value", "")),
		"__meta": pid,
	}


# 左=ラベル列 (部門 / 守備位置)、中央=第1リーグ受賞者、右=第2リーグ受賞者の 3 表を同じ幾何で横に並べる。
# 2 段見出しの上段にリーグ名を置き、リーグ表の行 (球団・選手・成績) だけをクリックで選手詳細へ。
# label_cols は幅 label_w に収まる列、league_ws は [球団, 選手, 成績] の列幅。
func _draw_league_split_table(rect: Rect2, label_cols: Array, label_rows: Array, league_rows: Dictionary, label_w: float, league_ws: Array) -> void:
	var area: Rect2 = Rect2(rect.position.x + 18.0, rect.position.y + TABLE_TOP, rect.size.x - 36.0, rect.size.y - TABLE_TOP - 8.0)
	var league_w: float = (area.size.x - label_w) * 0.5
	var base_opts: Dictionary = {"panel": false, "inner_pad": 0.0, "header_top": 68.0, "bottom_pad": 8.0}

	var label_rect: Rect2 = Rect2(area.position.x, area.position.y, label_w, area.size.y)
	_draw_data_table(label_rect, label_cols, label_rows, base_opts.duplicate())

	for li in range(LEAGUE_KEYS.size()):
		var key: String = str(LEAGUE_KEYS[li])
		var group_text: String = Loc.t("award.group.league_winners", {"league": PSTeam.league_label_for(key)})
		var columns: Array = [
			{"title": "col.team", "key": "team", "w": league_ws[0], "fmt": "team", "group": group_text},
			{"title": "col.player", "key": "name", "w": league_ws[1], "fmt": "player_name", "strong": true, "group": group_text},
			{"title": "history.col.record", "key": "val", "w": league_ws[2], "align": "r", "group": group_text},
		]
		var opts: Dictionary = base_opts.duplicate()
		opts["sel_kind"] = "player"
		opts["hover_id"] = _hover_pid
		var hits: Array = []
		opts["hits"] = hits
		var league_rect: Rect2 = Rect2(area.position.x + label_w + league_w * float(li), area.position.y, league_w, area.size.y)
		_draw_data_table(league_rect, columns, league_rows.get(key, []) as Array, opts)
		for hit_value in hits:
			var hit: Dictionary = hit_value as Dictionary
			_player_hits.append({"rect": hit["rect"], "pid": int(hit["meta"])})

	# リーグ境界 (ラベル | 第1 | 第2) の縦ヘアライン。2 段見出しの上端から最終行の下端まで。
	var row_top: float = _table_row_top(label_rect, label_cols, base_opts)
	var area_h: float = label_rect.end.y - row_top - float(base_opts["bottom_pad"])
	var row_h: float = minf(34.0, area_h / float(maxi(1, label_rows.size())))
	var line_top: float = label_rect.position.y + 68.0 - 36.0
	var line_bottom: float = row_top + row_h * float(label_rows.size())
	for bi in range(2):
		var bx: float = area.position.x + label_w + league_w * float(bi)
		_line(Vector2(bx, line_top), Vector2(bx, line_bottom), HAIRLINE, 1.0)


# ベストナイン / ゴールデン・グラブ賞の 2 リーグ並列グリッド。左半分=第1リーグ、右半分=第2リーグ。
# 各行はスロット短縮ラベル (守備位置色) + 選手 (球団色ドット + 名前) + 選定指標値。
# slot_labels / slot_positions は同じ長さで、値は _best_nine / _golden_glove の列と対応する。
func _draw_award_grid(rect: Rect2, title: String, accent: Color, slot_labels: Array, slot_positions: Array, columns: Dictionary) -> void:
	_panel(rect, title)
	_round(Rect2(rect.position.x + 18, rect.position.y + 44, 54, 3), accent, Color.TRANSPARENT, 1, 0)

	var label_columns: Array = [
		{"title": "box.col.pos", "key": "pos", "w": 60, "fmt": "pos_badge", "group": "award.group.pos_category"},
	]
	var label_rows: Array = []
	var league_rows: Dictionary = {"league1": [], "league2": []}
	for i in range(slot_labels.size()):
		label_rows.append({"pos": Loc.t(str(slot_labels[i])), "pos_color": _pos_color(int(slot_positions[i]))})
		for key in LEAGUE_KEYS:
			var cells: Array = columns.get(key, []) as Array
			var cell: Dictionary = cells[i] as Dictionary if i < cells.size() else {}
			(league_rows[key] as Array).append(_league_row(cell))
	_draw_league_split_table(rect, label_columns, label_rows, league_rows, 60.0, [52, 107, 68])


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_add_button("home_empty", Loc.t("common.to_home"), Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()
	var review_button: Button = _add_button("season_review", Loc.t("season_review.open"), Rect2(1560, 22, 162, 42),
		func() -> void: AppState.show_season_review(season.year, season.season_number, AppState.selected_team_id), "chip")
	review_button.disabled = RecordStore.get_season_review(season.year, season.season_number) == null
	_add_button("offseason", Loc.t("award.to_offseason"), Rect2(1738, 22, 162, 42), _on_offseason_pressed, "primary")
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
	_best_nine = {"league1": [], "league2": []}
	_golden_glove = {"league1": [], "league2": []}

	var awards: PSAwards = AppState.current_awards
	if awards == null:
		return
	_has_awards = true
	_season_label = Loc.t("common.year_and_season", {"year": awards.year, "n": awards.season_number})

	var postseason: PSPostseasonResult = AppState.current_postseason
	if postseason != null and postseason.champion_team_id > 0:
		_champion_id = postseason.champion_team_id
		_champion_series_text = _japan_series_record(postseason)

	_award_rows = [
		{"label": Loc.t("award.mvp"), "league1": _player_cell(awards.mvp_league1_player_id), "league2": _player_cell(awards.mvp_league2_player_id)},
		{"label": Loc.t("award.rookie"), "league1": _player_cell(awards.rookie_league1_player_id), "league2": _player_cell(awards.rookie_league2_player_id)},
	]
	_bat_rows = _build_title_rows(awards.batting_titles, BATTING_TITLE_LABELS, PSAwards.BATTING_CATEGORIES, false)
	_pit_rows = _build_title_rows(awards.pitching_titles, PITCHING_TITLE_LABELS, PSAwards.PITCHING_CATEGORIES, true)
	_best_nine = _build_award_columns(awards.best_nine)
	_golden_glove = _build_award_columns(awards.golden_glove)


func _build_title_rows(titles: Dictionary, label_map: Dictionary, keys_order: Array, is_pitcher: bool) -> Array:
	var league1: Dictionary = titles.get("league1", {}) as Dictionary
	var league2: Dictionary = titles.get("league2", {}) as Dictionary
	var rows: Array = []
	for key in keys_order:
		rows.append({
			"label": Loc.t(str(label_map.get(key, key))),
			"league1": _player_cell(int(league1.get(key, 0)), str(key), is_pitcher),
			"league2": _player_cell(int(league2.get(key, 0)), str(key), is_pitcher),
		})
	return rows


# awards.best_nine / golden_glove (league → Array[{pid, value}]) を表示用に解決する。
# 返り値 {"league1": Array[cell], "league2": Array[cell]}、cell = {pid, name, team_id, value}。
func _build_award_columns(data: Dictionary) -> Dictionary:
	return {
		"league1": _resolve_award_slots(data.get("league1", []) as Array),
		"league2": _resolve_award_slots(data.get("league2", []) as Array),
	}


func _resolve_award_slots(entries: Array) -> Array:
	var out: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var pid: int = int(entry.get("pid", 0))
		var cell: Dictionary = {"pid": pid, "name": Loc.t("common.none_applicable"), "team_id": 0, "value": str(entry.get("value", ""))}
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
	var cell: Dictionary = {"pid": player_id, "name": Loc.t("common.none_applicable"), "team_id": 0, "value": ""}
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
	return Loc.t("common.wins_losses", {"w": w, "l": l})


func _title_value(record: PSPlayerSeasonRecord, title_key: String, is_pitcher: bool) -> String:
	if is_pitcher:
		var ps: PSPitcherStats = record.pitcher_stats
		match title_key:
			"wins":
				return Loc.t("award.value.wins", {"n": ps.wins})
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
			return Loc.t("award.value.home_runs", {"n": bs.home_runs})
		"rbi":
			return Loc.t("award.value.rbi", {"n": bs.runs_batted_in})
		"stolen_bases":
			return Loc.t("award.value.stolen_bases", {"n": bs.stolen_bases})
		"hits":
			return Loc.t("award.value.hits", {"n": bs.hits})
		_:
			return ""


func _player_record(player_id: int) -> PSPlayerSeasonRecord:
	var season: PSSeason = AppState.current_season
	if season == null:
		return null
	return RecordStore.get_player_record(player_id, season.year, season.season_number)
