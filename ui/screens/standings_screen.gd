extends "res://ui/components/dashboard_screen.gd"

# 順位表画面。現在シーズンのリーグ順位、貯金推移、交流戦順位を同時に表示する。
# - 上段: 第1/第2リーグの順位表 (チーム成績の総合指標つき、全幅)。
# - 下段左: 貯金・借金の推移グラフ (各球団の wins-losses を試合数軸で折れ線描画)。
# - 下段右: 交流戦順位表 (is_interleague 試合のみ集計、全12球団の混合順位)。
# 重い集計 (チーム指標 / 貯金時系列 / 交流戦) は _refresh で1度だけ行いキャッシュ、_draw は描画専念。

const LEAGUES: Array = [
	{"key": "central", "label": "第1リーグ"},
	{"key": "pacific", "label": "第2リーグ"},
]

# --- レイアウト基準 (base 座標) ---
const INFO_Y: float = 112.0
const TABLE_A: Rect2 = Rect2(262, 124, 1638, 256)
const TABLE_B: Rect2 = Rect2(262, 394, 1638, 256)
const CHART_RECT: Rect2 = Rect2(262, 664, 956, 394)
const INTER_RECT: Rect2 = Rect2(1234, 664, 666, 394)

# 列幅は実データ幅基準で詰める (余白は球団名列へ寄せ、数値列が間延びしないように)。
# sep_before で「勝敗 / 勝率・差・残 / 得失点 / 打撃 / 投手」のブロック境界に縦ヘアラインを引く。
const LEAGUE_COLUMNS: Array = [
	{"title": "順",   "key": "rank", "w": 36,  "align": "l", "fmt": "rank"},
	{"title": "球団", "key": "team", "w": 280, "align": "l", "fmt": "team", "strong": true},
	{"title": "試合", "key": "g",    "w": 56,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "勝",   "key": "w",    "w": 50,  "align": "r", "fmt": "int"},
	{"title": "敗",   "key": "l",    "w": 50,  "align": "r", "fmt": "int"},
	{"title": "分",   "key": "d",    "w": 46,  "align": "r", "fmt": "int"},
	{"title": "勝率", "key": "pct",  "w": 70,  "align": "r", "fmt": "rate", "sep_before": true},
	{"title": "差",   "key": "gb",   "w": 60,  "align": "r", "fmt": "gb"},
	{"title": "残",   "key": "rem",  "w": 48,  "align": "r", "fmt": "int"},
	{"title": "得",   "key": "rs",   "w": 56,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "失",   "key": "ra",   "w": 56,  "align": "r", "fmt": "int"},
	{"title": "得失", "key": "diff", "w": 64,  "align": "r", "fmt": "diff"},
	{"title": "打率", "key": "avg",  "w": 70,  "align": "r", "fmt": "rate", "sep_before": true},
	{"title": "本",   "key": "hr",   "w": 48,  "align": "r", "fmt": "int"},
	{"title": "盗",   "key": "sb",   "w": 48,  "align": "r", "fmt": "int"},
	{"title": "防",   "key": "era",  "w": 64,  "align": "r", "fmt": "float2", "sep_before": true},
	{"title": "WHIP", "key": "whip", "w": 70,  "align": "r", "fmt": "float2"},
	{"title": "K/9",  "key": "k9",   "w": 62,  "align": "r", "fmt": "float2"},
	{"title": "S",    "key": "sv",   "w": 44,  "align": "r", "fmt": "int"},
	{"title": "H",    "key": "hld",  "w": 44,  "align": "r", "fmt": "int"},
]

const INTER_COLUMNS: Array = [
	{"title": "順",   "key": "rank", "w": 36,  "align": "l", "fmt": "rank"},
	{"title": "球団", "key": "team", "w": 210, "align": "l", "fmt": "team", "strong": true},
	{"title": "L",    "key": "lg",   "w": 42,  "align": "l", "fmt": "str"},
	{"title": "試",   "key": "g",    "w": 46,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "勝",   "key": "w",    "w": 48,  "align": "r", "fmt": "int"},
	{"title": "敗",   "key": "l",    "w": 48,  "align": "r", "fmt": "int"},
	{"title": "分",   "key": "d",    "w": 44,  "align": "r", "fmt": "int"},
	{"title": "勝率", "key": "pct",  "w": 66,  "align": "r", "fmt": "rate", "sep_before": true},
	{"title": "差",   "key": "gb",   "w": 56,  "align": "r", "fmt": "gb"},
]

# 集計キャッシュ
var _status_text: String = ""
var _entries_by_league: Dictionary = {}   # {league_key: Array of row 表示用 Dictionary}
var _interleague_rows: Array = []          # 交流戦 行 Dictionary (順位つき)
var _interleague_played: bool = false
var _balance_by_team: Dictionary = {}      # {team_id: PackedVector2Array(game_no, balance)}
var _chart_league: String = "central"


func _ready() -> void:
	_init_chrome()
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	_chart_league = team.league if team != null else "central"
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if team == null or season == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)
		return

	_draw_shell("順位表", team, season)
	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, INFO_Y), 13, MUTED)

	_draw_table(TABLE_A, str(LEAGUES[0]["label"]), "", LEAGUE_COLUMNS, _entries_by_league.get("central", []) as Array)
	_draw_table(TABLE_B, str(LEAGUES[1]["label"]), "", LEAGUE_COLUMNS, _entries_by_league.get("pacific", []) as Array)
	_draw_balance_chart(CHART_RECT)
	if _interleague_played:
		_draw_table(INTER_RECT, "交流戦順位表", "", INTER_COLUMNS, _interleague_rows)
	else:
		_panel(INTER_RECT, "交流戦順位表")
		_text("交流戦はまだ開幕していません", Vector2(INTER_RECT.position.x + 24, INTER_RECT.position.y + INTER_RECT.size.y * 0.5), 15, MUTED, INTER_RECT.size.x - 48, HORIZONTAL_ALIGNMENT_CENTER)


# 汎用テーブル描画 (リーグ順位表 / 交流戦で共用)。描画本体は基底 _draw_data_table に集約 (2026-06-24)。
func _draw_table(rect: Rect2, title: String, right_label: String, columns: Array, rows: Array) -> void:
	_draw_data_table(rect, columns, rows, {"title": title, "right_label": right_label})


# ============================================================ 貯金・借金グラフ

func _draw_balance_chart(rect: Rect2) -> void:
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	_round(Rect2(rect.position.x + 18, rect.position.y + 19, 3, 14), BLUE, Color.TRANSPARENT, 2, 0)
	_text("貯金・借金の推移", Vector2(rect.position.x + 27, rect.position.y + 32), 17, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var teams: Array = _league_team_order(_chart_league)

	# 凡例 (球団色ドット + 略称)
	var lx: float = rect.position.x + 18.0
	var ly: float = rect.position.y + 56.0
	for team_value in teams:
		var team: PSTeam = team_value as PSTeam
		_dot(Vector2(lx + 5.0, ly - 4.0), 5.0, _chart_color(team.color))
		_text(team.short_name, Vector2(lx + 14.0, ly), 11, MUTED)
		lx += 14.0 + _measure(team.short_name, 11) + 18.0

	# プロット領域
	var plot: Rect2 = Rect2(rect.position.x + 48.0, rect.position.y + 74.0, rect.size.x - 48.0 - 18.0, rect.size.y - 74.0 - 28.0)

	var max_games: int = 6
	var max_abs: int = 5
	for team_value in teams:
		var series: PackedVector2Array = _balance_by_team.get((team_value as PSTeam).id, PackedVector2Array()) as PackedVector2Array
		for p in series:
			max_games = max(max_games, int(p.x))
			max_abs = max(max_abs, int(ceil(abs(p.y))))

	var y0: float = plot.position.y + plot.size.y * 0.5
	# 横グリッド + y ラベル (+N / +N/2 / 0 / -N/2 / -N)
	for frac in [1.0, 0.5, 0.0, -0.5, -1.0]:
		var yy: float = y0 - float(frac) * (plot.size.y * 0.5)
		_line(Vector2(plot.position.x, yy), Vector2(plot.end.x, yy), BORDER if frac == 0.0 else BORDER_SOFT, 1.2 if frac == 0.0 else 1.0)
		var n: int = int(round(float(frac) * float(max_abs)))
		_text_right("0" if n == 0 else "%+d" % n, plot.position.x - 6.0, yy + 4.0, 10, FAINT, 42)

	# x 軸ラベル (試合数)
	for gx in [0.0, 0.5, 1.0]:
		var px: float = plot.position.x + float(gx) * plot.size.x
		var gnum: int = int(round(float(gx) * float(max_games)))
		_text(str(gnum), Vector2(px - 8.0, plot.end.y + 18.0), 10, FAINT)
	_text_right("試合数", plot.end.x, plot.end.y + 18.0, 10, FAINT, 60)

	# 折れ線 (自軍は最後に太線で重ねる)
	var self_id: int = AppState.selected_team_id
	for pass_self in [false, true]:
		for team_value in teams:
			var team: PSTeam = team_value as PSTeam
			if (team.id == self_id) != pass_self:
				continue
			var series: PackedVector2Array = _balance_by_team.get(team.id, PackedVector2Array()) as PackedVector2Array
			if series.size() < 2:
				continue
			var pts: PackedVector2Array = PackedVector2Array()
			for p in series:
				var bx: float = plot.position.x + (p.x / float(max_games)) * plot.size.x
				var by: float = y0 - (p.y / float(max_abs)) * (plot.size.y * 0.5)
				pts.append(_p(Vector2(bx, by)))
			var width: float = max(1.5, (3.4 if team.id == self_id else 2.0) * _scale_f)
			draw_polyline(pts, _chart_color(team.color), width, true)
			# 終端マーカー + 自軍は略称ラベル
			draw_circle(pts[pts.size() - 1], max(2.0, width * 0.9), _chart_color(team.color))


# 暗背景でも見えるよう球団色を少し明るくする。
func _chart_color(c: Color) -> Color:
	return c.lerp(Color(1, 1, 1), 0.12)


func _league_team_order(league_key: String) -> Array:
	var teams: Array = []
	for row_value in _entries_by_league.get(league_key, []) as Array:
		var team: PSTeam = GameDb.get_team(int((row_value as Dictionary).get("team_id", 0)))
		if team != null:
			teams.append(team)
	return teams


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

	# 貯金グラフのリーグ切替チップ (グラフパネル右上)。
	_add_button("chart_central", "第1", Rect2(CHART_RECT.end.x - 142, CHART_RECT.position.y + 14, 64, 28),
		func() -> void: _set_chart_league("central"), "chip_active" if _chart_league == "central" else "chip")
	_add_button("chart_pacific", "第2", Rect2(CHART_RECT.end.x - 72, CHART_RECT.position.y + 14, 64, 28),
		func() -> void: _set_chart_league("pacific"), "chip_active" if _chart_league == "pacific" else "chip")

	_layout_buttons()


func _set_chart_league(league_key: String) -> void:
	if _chart_league == league_key:
		return
	_chart_league = league_key
	_build_buttons()
	queue_redraw()


# ============================================================ aggregation

func _refresh() -> void:
	_status_text = ""
	_entries_by_league = {}
	_interleague_rows = []
	_interleague_played = false
	_balance_by_team = {}

	var season: PSSeason = AppState.current_season
	if season == null:
		return

	_status_text = "%d年 / %d年目  %s  (残り%d試合)" % [
		season.year, season.season_number,
		SeasonCalendar.day_status_label(season, season.current_day), season.games_remaining(),
	]

	for league_row in LEAGUES:
		var key: String = str((league_row as Dictionary)["key"])
		_entries_by_league[key] = _build_league_rows(key, season)

	_build_balance_series(season)
	_build_interleague_rows(season)


func _build_league_rows(league_key: String, season: PSSeason) -> Array:
	var entries: Array = []
	for team_id in season.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id))
		if team == null or team.league != league_key:
			continue
		entries.append({
			"team": team,
			"stats": season.standings[team_id] as PSStats,
			"metrics": _team_metrics(int(team_id), season),
			"remaining": season.team_games_remaining(int(team_id)),
		})

	entries.sort_custom(func(a, b) -> bool:
		var sa: PSStats = (a as Dictionary)["stats"] as PSStats
		var sb: PSStats = (b as Dictionary)["stats"] as PSStats
		if is_equal_approx(sa.win_rate(), sb.win_rate()):
			return sa.wins > sb.wins
		return sa.win_rate() > sb.win_rate()
	)

	var leader: PSStats = ((entries[0] as Dictionary)["stats"] as PSStats) if not entries.is_empty() else null
	var self_id: int = AppState.selected_team_id
	var rows: Array = []
	var rank: int = 1
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var team: PSTeam = entry["team"] as PSTeam
		var stats: PSStats = entry["stats"] as PSStats
		var metrics: Dictionary = entry["metrics"] as Dictionary
		var has_pitch: bool = int(metrics.get("outs_pitched", 0)) > 0
		rows.append({
			"rank": rank, "team": team.name, "team_id": team.id, "color": team.color,
			"is_self": team.id == self_id, "is_leader": rank == 1,
			"g": stats.games, "w": stats.wins, "l": stats.losses, "d": stats.draws,
			"pct": stats.win_rate(),
			"gb": 0.0 if (rank == 1 or leader == null) else _game_back(leader, stats),
			"rem": int(entry["remaining"]),
			"rs": stats.runs_scored, "ra": stats.runs_allowed, "diff": stats.runs_scored - stats.runs_allowed,
			"avg": float(metrics.get("batting_average", 0.0)),
			"hr": int(metrics.get("home_runs", 0)), "sb": int(metrics.get("stolen_bases", 0)),
			"era": float(metrics.get("earned_run_average", 0.0)) if has_pitch else -1.0,
			"whip": float(metrics.get("whip", 0.0)) if has_pitch else -1.0,
			"k9": float(metrics.get("strikeouts_per_nine", 0.0)) if has_pitch else -1.0,
			"sv": int(metrics.get("saves", 0)), "hld": int(metrics.get("holds", 0)),
		})
		rank += 1
	return rows


# 各球団の貯金(=勝-敗)を試合消化順に積み上げた時系列を作る。schedule は day 昇順前提。
func _build_balance_series(season: PSSeason) -> void:
	var counters: Dictionary = {}   # team_id: {bal, g}
	for team_id in season.standings.keys():
		_balance_by_team[int(team_id)] = PackedVector2Array([Vector2(0, 0)])
		counters[int(team_id)] = {"bal": 0, "g": 0}

	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("played", false)):
			continue
		var result: Dictionary = game.get("result", {}) as Dictionary
		var draw_game: bool = bool(result.get("draw", false))
		var winner: int = int(result.get("winning_team_id", 0))
		for tid in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			if not counters.has(tid):
				continue
			var c: Dictionary = counters[tid] as Dictionary
			c["g"] = int(c["g"]) + 1
			if not draw_game:
				c["bal"] = int(c["bal"]) + (1 if winner == tid else -1)
			counters[tid] = c
			# PackedVector2Array は CoW なのでローカルへ取り出して append し書き戻す。
			var series: PackedVector2Array = _balance_by_team[tid] as PackedVector2Array
			series.append(Vector2(float(c["g"]), float(c["bal"])))
			_balance_by_team[tid] = series


func _build_interleague_rows(season: PSSeason) -> void:
	var acc: Dictionary = {}   # team_id: {w,l,d}
	for team_id in season.standings.keys():
		acc[int(team_id)] = {"w": 0, "l": 0, "d": 0}

	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("is_interleague", false)) or not bool(game.get("played", false)):
			continue
		_interleague_played = true
		var result: Dictionary = game.get("result", {}) as Dictionary
		var draw_game: bool = bool(result.get("draw", false))
		var winner: int = int(result.get("winning_team_id", 0))
		for tid in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			if not acc.has(tid):
				continue
			var c: Dictionary = acc[tid] as Dictionary
			if draw_game:
				c["d"] = int(c["d"]) + 1
			elif winner == tid:
				c["w"] = int(c["w"]) + 1
			else:
				c["l"] = int(c["l"]) + 1
			acc[tid] = c

	# 交流戦開幕前は順位表を作らず空にする (パネルには案内文のみ表示)。
	if not _interleague_played:
		return

	var entries: Array = []
	for team_id in acc.keys():
		var team: PSTeam = GameDb.get_team(int(team_id))
		if team == null:
			continue
		var c: Dictionary = acc[team_id] as Dictionary
		var w: int = int(c["w"])
		var l: int = int(c["l"])
		var decisions: int = w + l
		entries.append({
			"team": team, "w": w, "l": l, "d": int(c["d"]),
			"pct": (float(w) / float(decisions)) if decisions > 0 else 0.0,
		})

	entries.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if is_equal_approx(float(da["pct"]), float(db["pct"])):
			return int(da["w"]) > int(db["w"])
		return float(da["pct"]) > float(db["pct"])
	)

	var self_id: int = AppState.selected_team_id
	var leader_w: int = int((entries[0] as Dictionary)["w"]) if not entries.is_empty() else 0
	var leader_l: int = int((entries[0] as Dictionary)["l"]) if not entries.is_empty() else 0
	var rank: int = 1
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var team: PSTeam = entry["team"] as PSTeam
		var gb: float = 0.0 if rank == 1 else float((leader_w - int(entry["w"])) + (int(entry["l"]) - leader_l)) / 2.0
		_interleague_rows.append({
			"rank": rank, "team": team.name, "team_id": team.id, "color": team.color,
			"lg": "第1" if team.league == "central" else "第2",
			"is_self": team.id == self_id, "is_leader": rank == 1,
			"g": int(entry["w"]) + int(entry["l"]) + int(entry["d"]),
			"w": int(entry["w"]), "l": int(entry["l"]), "d": int(entry["d"]),
			"pct": float(entry["pct"]), "gb": gb,
		})
		rank += 1


func _team_metrics(team_id: int, season: PSSeason) -> Dictionary:
	var batter_stats: PSBatterStats = PSBatterStats.new()
	var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
	var records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter_stats.add_from(record.batter_stats)
		if record.is_pitcher():
			pitcher_stats.add_from(record.pitcher_stats)
	return {
		"batting_average": batter_stats.batting_average(),
		"home_runs": batter_stats.home_runs,
		"stolen_bases": batter_stats.stolen_bases,
		"earned_run_average": pitcher_stats.era(),
		"whip": pitcher_stats.whip(),
		"strikeouts_per_nine": pitcher_stats.strikeouts_per_nine(),
		"saves": pitcher_stats.saves,
		"holds": pitcher_stats.holds,
		"outs_pitched": pitcher_stats.outs_pitched,
	}


func _game_back(leader: PSStats, stats: PSStats) -> float:
	return float((leader.wins - stats.wins) + (stats.losses - leader.losses)) / 2.0
