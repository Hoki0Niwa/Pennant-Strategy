extends "res://ui/components/dashboard_screen.gd"

# タイトル争い画面。2リーグ×各部門のランキングをパネルグリッドで描き、各パネル上位7名を表示する。
# 1位はアンバーで強調し、WAR や部門別ソートなどの重い集計は _refresh で1度だけ行う。
# _draw はキャッシュ済みランキングの描画に専念する。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const LEAGUES: Array = [
	{"key": "league1", "label": "第1リーグ"},
	{"key": "league2", "label": "第2リーグ"},
]

const RANKING_TOP_COUNT: int = 7
const QUALIFIER_PA_PER_TEAM_GAME: float = 3.1
const QUALIFIER_OUTS_PER_TEAM_GAME: float = 3.0

const BATTER_CATEGORIES: Array = [
	{"key": "war",       "label": "WAR",    "min_pa": false},
	{"key": "average",   "label": "打率",   "min_pa": true},
	{"key": "home_runs", "label": "本塁打", "min_pa": false},
	{"key": "rbi",       "label": "打点",   "min_pa": false},
	{"key": "ops",       "label": "OPS",    "min_pa": true},
	{"key": "hits",      "label": "安打",   "min_pa": false},
	{"key": "woba",      "label": "wOBA",   "min_pa": true},
	{"key": "wrc_plus",  "label": "wRC+",   "min_pa": true},
	{"key": "stolen",    "label": "盗塁",   "min_pa": false},
]

const PITCHER_CATEGORIES: Array = [
	{"key": "war",        "label": "WAR",    "min_ip": false},
	{"key": "wins",       "label": "勝利",   "min_ip": false},
	{"key": "era",        "label": "防御率", "min_ip": true,  "ascending": true},
	{"key": "strikeouts", "label": "奪三振", "min_ip": false},
	{"key": "fip",        "label": "FIP",    "min_ip": true,  "ascending": true},
	{"key": "saves",      "label": "セーブ", "min_ip": false},
	{"key": "holds",      "label": "ホールド", "min_ip": false},
	{"key": "k9",         "label": "K/9",    "min_ip": true},
	{"key": "woba_allowed", "label": "wOBAA", "min_ip": true, "ascending": true},
]

# --- レイアウト基準 (base 座標) ---
const INFO_Y: float = 116.0
const GRID_TOP: float = 134.0
const GRID_BOTTOM: float = 1058.0
const LEAGUE_GAP: float = 22.0
const PANEL_H_GAP: float = 12.0
const PANEL_V_GAP: float = 12.0
const GRID_COLS: int = 3
const GRID_ROWS: int = 3

# WAR 集計は全選手集計のため refresh 単位で 1 度だけ実施。リーグ context を共有。
var _war_ctx_cache: Dictionary = {}

# 集計済みデータ。{"batter": {league_key: [{label, rows}]}, "pitcher": {...}}
var _data: Dictionary = {}
var _info_text: String = ""
var _show_batters: bool = true

# 行ヒット (クリックで選手詳細へ)。{rect(base), pid}
var _row_hits: Array = []
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
			var hit: Dictionary = _row_at(_to_base(event.position))
			var pid: int = int(hit.get("pid", 0))
			if pid > 0:
				AppState.show_player_detail(pid)
	elif event is InputEventMouseMotion:
		_update_transform()
		var pid: int = int(_row_at(_to_base(event.position)).get("pid", 0))
		if pid != _hover_pid:
			_hover_pid = pid
			queue_redraw()


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


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_row_hits = []

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_draw_empty()
		return

	_draw_shell("タイトル争い", team, season)
	if not _info_text.is_empty():
		_text(_info_text, Vector2(INNER_L, INFO_Y), 13, MUTED)

	var tab_key: String = "batter" if _show_batters else "pitcher"
	var tab_data: Dictionary = _data.get(tab_key, {}) as Dictionary
	var league_w: float = (INNER_R - INNER_L - LEAGUE_GAP) / 2.0
	for li in range(LEAGUES.size()):
		var league: Dictionary = LEAGUES[li] as Dictionary
		var key: String = str(league["key"])
		var lx: float = INNER_L + float(li) * (league_w + LEAGUE_GAP)
		_draw_league_column(lx, league_w, str(league["label"]), tab_data.get(key, []) as Array)


func _draw_empty() -> void:
	_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
	_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)


func _draw_league_column(lx: float, lw: float, label: String, cats: Array) -> void:
	# リーグ見出し (サイドバー見出しと同じ青アクセントバー付き)。
	_round(Rect2(lx, GRID_TOP + 4, 3, 17), BLUE, Color.TRANSPARENT, 2, 0)
	_text(label, Vector2(lx + 12, GRID_TOP + 21), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var gy0: float = GRID_TOP + 34.0
	var gh: float = GRID_BOTTOM - gy0
	var pw: float = (lw - PANEL_H_GAP * float(GRID_COLS - 1)) / float(GRID_COLS)
	var ph: float = (gh - PANEL_V_GAP * float(GRID_ROWS - 1)) / float(GRID_ROWS)
	for idx in range(cats.size()):
		var col: int = idx % GRID_COLS
		var row: int = floori(float(idx) / float(GRID_COLS))
		var px: float = lx + float(col) * (pw + PANEL_H_GAP)
		var py: float = gy0 + float(row) * (ph + PANEL_V_GAP)
		var cat: Dictionary = cats[idx] as Dictionary
		_draw_category_panel(Rect2(px, py, pw, ph), str(cat["label"]), cat["rows"] as Array)


func _draw_category_panel(rect: Rect2, label: String, rows: Array) -> void:
	# パネルは基盤 _panel のフラット化 (枠なし + bold タイトル + 青ティック) に乗る。
	_panel(rect, label)
	_line(Vector2(rect.position.x + 12, rect.position.y + 44), Vector2(rect.end.x - 12, rect.position.y + 44), BORDER, 1.5)

	if rows.is_empty():
		_text("データなし", Vector2(rect.position.x + 12, rect.position.y + 72), 12, FAINT)
		return

	var inner_x: float = rect.position.x + 12.0
	var top: float = rect.position.y + 52.0
	var row_h: float = (rect.end.y - top - 8.0) / float(RANKING_TOP_COUNT)
	var value_box: float = 56.0
	var value_right: float = rect.end.x - 10.0
	var name_x: float = inner_x + 56.0
	var name_w: float = value_right - value_box - 6.0 - name_x
	var muted_text: Color = MUTED.lerp(TEXT, 0.55)

	for i in range(rows.size()):
		var r: Dictionary = rows[i] as Dictionary
		var pid: int = int(r.get("pid", 0))
		var is_top: bool = int(r["rank"]) == 1
		var ry: float = top + float(i) * row_h
		var row_rect: Rect2 = Rect2(rect.position.x + 6.0, ry + 1.0, rect.size.x - 12.0, row_h - 2.0)
		if is_top:
			_round(row_rect, Color(AMBER.r, AMBER.g, AMBER.b, 0.13), Color(AMBER.r, AMBER.g, AMBER.b, 0.42), 6)
		elif pid > 0 and pid == _hover_pid:
			_round(row_rect, Color(1, 1, 1, 0.05), Color.TRANSPARENT, 6, 0)

		var ty: float = ry + row_h * 0.5 + 5.0
		var rank_color: Color = AMBER if is_top else MUTED
		var name_color: Color = TEXT if is_top else muted_text
		var value_color: Color = AMBER if is_top else TEXT
		_text(str(r["rank"]), Vector2(inner_x, ty), 13, rank_color, 18, HORIZONTAL_ALIGNMENT_LEFT, is_top)
		_text(str(r["team"]), Vector2(inner_x + 22.0, ty), 12, MUTED, 32)
		_text(str(r["name"]), Vector2(name_x, ty), 13, name_color, name_w, HORIZONTAL_ALIGNMENT_LEFT, is_top)
		_text_right(str(r["val"]), value_right, ty, 13, value_color, value_box, true)
		# 自前描画リストなので行区切りは手でヘアラインを引く (トップ行の強調背景の下にも重ねて描く)。
		_line(Vector2(rect.position.x + 6.0, ry + row_h), Vector2(rect.end.x - 6.0, ry + row_h), HAIRLINE, 1.0)

		if pid > 0:
			_row_hits.append({"rect": row_rect, "pid": pid})


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

	# ヘッダ右側に 野手/投手 タブ + 再集計。
	_add_button("tab_batter", "野手", Rect2(1486, 22, 92, 42),
		func() -> void: _set_tab(true), "chip_active" if _show_batters else "chip")
	_add_button("tab_pitcher", "投手", Rect2(1584, 22, 92, 42),
		func() -> void: _set_tab(false), "chip_active" if not _show_batters else "chip")
	_add_button("refresh", "再集計", Rect2(1682, 22, 110, 42), _on_refresh_pressed, "action")

	_layout_buttons()


func _set_tab(show_batters: bool) -> void:
	if _show_batters == show_batters:
		return
	_show_batters = show_batters
	_build_buttons()
	queue_redraw()


func _on_refresh_pressed() -> void:
	_refresh()
	queue_redraw()


# ============================================================ aggregation

func _refresh() -> void:
	_data = {}
	_info_text = ""
	var season: PSSeason = AppState.current_season
	if season == null:
		return

	var max_team_games: int = _max_team_games(season)
	var qualifier_pa: int = int(max(1, ceil(QUALIFIER_PA_PER_TEAM_GAME * float(max_team_games))))
	var qualifier_outs: int = int(max(1, ceil(QUALIFIER_OUTS_PER_TEAM_GAME * float(max_team_games))))
	_info_text = "各部門 Top%d    規定打席 ≥ %d    規定投球回 ≥ %s 回    ※所属球団試合数基準" % [
		RANKING_TOP_COUNT,
		qualifier_pa,
		_format_innings(qualifier_outs),
	]

	_war_ctx_cache = WarCalculator.build_league_context(season.year, season.season_number)
	var all_records: Array = _collect_records(season)

	var batter: Dictionary = {}
	var pitcher: Dictionary = {}
	for league_row in LEAGUES:
		var key: String = str((league_row as Dictionary)["key"])
		var bcats: Array = []
		for category_row in BATTER_CATEGORIES:
			var category: Dictionary = category_row as Dictionary
			bcats.append({
				"label": str(category["label"]),
				"rows": _batter_rows(all_records, category, season, key),
			})
		batter[key] = bcats
		var pcats: Array = []
		for category_row in PITCHER_CATEGORIES:
			var category: Dictionary = category_row as Dictionary
			pcats.append({
				"label": str(category["label"]),
				"rows": _pitcher_rows(all_records, category, season, key),
			})
		pitcher[key] = pcats
	_data = {"batter": batter, "pitcher": pitcher}


func _batter_rows(records: Array, category: Dictionary, season: PSSeason, league_key: String) -> Array:
	var key: String = str(category["key"])
	var require_min_pa: bool = bool(category.get("min_pa", false))
	var entries: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var team: PSTeam = GameDb.get_team(record.team_id)
		if team == null or team.league != league_key:
			continue
		if record.is_pitcher() and record.batter_stats.plate_appearances < 5:
			continue
		if require_min_pa and record.batter_stats.plate_appearances < _required_plate_appearances(record, season):
			continue
		if _batter_metric_uses_record(key):
			if record.is_pitcher():
				continue
			if record.advanced_stats == null or record.advanced_stats.plate_appearances <= 0:
				continue
		var value: float = _record_metric_value(record, key) if _batter_metric_uses_record(key) else _batter_metric_value(record.batter_stats, key)
		entries.append({"record": record, "value": value})

	entries.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["value"]) > float((b as Dictionary)["value"])
	)

	var rows: Array = []
	var shown: int = 0
	for entry_row in entries:
		if shown >= RANKING_TOP_COUNT:
			break
		var entry: Dictionary = entry_row as Dictionary
		var record: PSPlayerSeasonRecord = entry["record"] as PSPlayerSeasonRecord
		var value: float = float(entry["value"])
		if value <= 0.0 and (key == "average" or key == "ops" or key == "woba" or key == "wrc_plus"):
			continue
		rows.append({
			"rank": shown + 1,
			"team": _team_short(record.team_id),
			"name": record.name,
			"val": _format_batter_value(key, value),
			"pid": record.player_id,
		})
		shown += 1
	return rows


func _pitcher_rows(records: Array, category: Dictionary, season: PSSeason, league_key: String) -> Array:
	var key: String = str(category["key"])
	var require_min_ip: bool = bool(category.get("min_ip", false))
	var ascending: bool = bool(category.get("ascending", false))

	var entries: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var team: PSTeam = GameDb.get_team(record.team_id)
		if team == null or team.league != league_key:
			continue
		if not record.is_pitcher():
			continue
		if record.pitcher_stats.games == 0:
			continue
		if require_min_ip and record.pitcher_stats.outs_pitched < _required_pitcher_outs(record, season):
			continue
		if key == "woba_allowed" and (record.advanced_stats == null or record.advanced_stats.woba_denominator <= 0):
			continue
		var value: float = _record_metric_value(record, key) if _pitcher_metric_uses_record(key) else _pitcher_metric_value(record.pitcher_stats, key)
		entries.append({"record": record, "value": value})

	entries.sort_custom(func(a, b) -> bool:
		var av: float = float((a as Dictionary)["value"])
		var bv: float = float((b as Dictionary)["value"])
		if ascending:
			return av < bv
		return av > bv
	)

	var rows: Array = []
	var shown: int = 0
	for entry_row in entries:
		if shown >= RANKING_TOP_COUNT:
			break
		var entry: Dictionary = entry_row as Dictionary
		var record: PSPlayerSeasonRecord = entry["record"] as PSPlayerSeasonRecord
		var value: float = float(entry["value"])
		rows.append({
			"rank": shown + 1,
			"team": _team_short(record.team_id),
			"name": record.name,
			"val": _format_pitcher_value(key, value, record.pitcher_stats),
			"pid": record.player_id,
		})
		shown += 1
	return rows


func _required_plate_appearances(record: PSPlayerSeasonRecord, season: PSSeason) -> int:
	var team_games: int = _team_games_for_record(record, season)
	return int(max(1, ceil(QUALIFIER_PA_PER_TEAM_GAME * float(team_games))))


func _required_pitcher_outs(record: PSPlayerSeasonRecord, season: PSSeason) -> int:
	var team_games: int = _team_games_for_record(record, season)
	return int(max(1, ceil(QUALIFIER_OUTS_PER_TEAM_GAME * float(team_games))))


func _team_games_for_record(record: PSPlayerSeasonRecord, season: PSSeason) -> int:
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(record.team_id, record.year, record.season_number)
	if team_record != null:
		return int(team_record.stats.games)
	if season != null and season.standings.has(record.team_id):
		var stats: PSStats = season.standings[record.team_id] as PSStats
		if stats != null:
			return int(stats.games)
	return 0


func _max_team_games(season: PSSeason) -> int:
	var result: int = 0
	if season == null:
		return result
	for stats_value in season.standings.values():
		var stats: PSStats = stats_value as PSStats
		if stats != null:
			result = max(result, int(stats.games))
	return result


func _collect_records(season: PSSeason) -> Array:
	var records: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var team_records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_row in team_records:
			records.append(record_row as PSPlayerSeasonRecord)
	return records


# ============================================================ metrics

func _batter_metric_value(stats: PSBatterStats, key: String) -> float:
	match key:
		"average": return stats.batting_average()
		"ops": return stats.ops()
		"home_runs": return float(stats.home_runs)
		"rbi": return float(stats.runs_batted_in)
		"hits": return float(stats.hits)
		"stolen": return float(stats.stolen_bases)
		_: return 0.0


func _record_metric_value(record: PSPlayerSeasonRecord, key: String) -> float:
	if key == "war":
		var war_row: Dictionary = WarCalculator.season_war(record, _war_ctx_cache)
		return float(war_row.get("war", 0.0))
	if key == "fip":
		var war_row: Dictionary = WarCalculator.season_war(record, _war_ctx_cache)
		return float(war_row.get("fip", 999.99))
	if record == null or record.advanced_stats == null:
		return 0.0
	match key:
		"woba": return record.advanced_stats.woba()
		"wrc_plus": return record.advanced_stats.wrc_plus()
		"woba_allowed": return record.advanced_stats.woba()
	return 0.0


func _pitcher_metric_value(stats: PSPitcherStats, key: String) -> float:
	match key:
		"wins": return float(stats.wins)
		"era":
			if stats.outs_pitched == 0:
				return 999.99
			return stats.era()
		"strikeouts": return float(stats.strikeouts)
		"saves": return float(stats.saves)
		"holds": return float(stats.holds)
		"k9": return stats.strikeouts_per_nine()
		_: return 0.0


func _format_batter_value(key: String, value: float) -> String:
	match key:
		"average", "ops", "woba":
			return "%0.3f" % value
		"wrc_plus":
			return "%0.1f" % value
		"war":
			return "%+0.2f" % value
		_:
			return "%d" % int(value)


func _format_pitcher_value(key: String, value: float, stats: PSPitcherStats) -> String:
	match key:
		"era", "fip", "k9":
			if stats.outs_pitched == 0:
				return "--"
			return "%0.2f" % value
		"woba_allowed":
			if stats.outs_pitched == 0:
				return "--"
			return "%0.3f" % value
		"war":
			return "%+0.2f" % value
		_:
			return "%d" % int(value)


func _batter_metric_uses_record(key: String) -> bool:
	return key == "war" or key == "woba" or key == "wrc_plus"


func _pitcher_metric_uses_record(key: String) -> bool:
	return key == "war" or key == "fip" or key == "woba_allowed"


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _format_innings(outs: int) -> String:
	@warning_ignore("integer_division")
	return "%d.%d" % [int(outs / 3), outs % 3]
