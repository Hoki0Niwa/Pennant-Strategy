extends RefCounted

# balance_report / long_autoplay_report の数値を分布と health check に整形する。
# health は pass/warn/fail の閾値付きチェック配列で、バランス調整中の異常検知を機械的に行う。

const STATUS_PASS: String = "pass"
const STATUS_WARN: String = "warn"
const STATUS_FAIL: String = "fail"


# 単年/短期バランスレポートから、主要な個人・チーム指標の min/p10/p50/p90/p99/max/mean を作る。
static func balance_distributions(report: Dictionary) -> Dictionary:
	var player_stats: Dictionary = report.get("player_stats", {}) as Dictionary
	var batters: Array = player_stats.get("batters", []) as Array
	var pitchers: Array = player_stats.get("pitchers", []) as Array
	var team_rows: Array = report.get("team_seasons", []) as Array
	var pitcher_era_dist: Dictionary = _distribution(_positive_float_values(pitchers, "era"), 2)
	var era_tail: Dictionary = _era_tail_summary(pitchers)
	return {
		"batters": {
			"qualified_count": batters.size(),
			"batting_average": _distribution(_float_values(batters, "batting_average"), 3),
			"ops": _distribution(_float_values(batters, "ops"), 3),
			"home_runs": _distribution(_float_values(batters, "home_runs"), 0),
			"walks": _distribution(_float_values(batters, "walks"), 0),
			"strikeouts": _distribution(_float_values(batters, "strikeouts"), 0),
			"war": _distribution(_float_values(batters, "war"), 2),
			"strikeout_rate": _distribution(_float_values(batters, "strikeout_rate"), 3),
			"walk_rate": _distribution(_float_values(batters, "walk_rate"), 3),
		},
		"pitchers": {
			"qualified_count": pitchers.size(),
			"era": pitcher_era_dist,
			"innings_pitched": _distribution(_float_values(pitchers, "innings_pitched"), 1),
			"qualified_pitcher_era_p10": float(pitcher_era_dist.get("p10", 0.0)),
			"era_under_2_count": int(era_tail.get("era_under_2_count", 0)),
			"era_under_2_by_team_max": int(era_tail.get("era_under_2_by_team_max", 0)),
			"era_under_2_team_multi_count": int(era_tail.get("era_under_2_team_multi_count", 0)),
			"walks": _distribution(_float_values(pitchers, "walks"), 0),
			"strikeouts": _distribution(_float_values(pitchers, "strikeouts"), 0),
			"strikeouts_per_nine": _distribution(_float_values(pitchers, "strikeouts_per_nine"), 2),
			"walks_per_nine": _distribution(_float_values(pitchers, "walks_per_nine"), 2),
			"home_runs_per_nine": _distribution(_float_values(pitchers, "home_runs_per_nine"), 2),
			"war": _distribution(_float_values(pitchers, "war"), 2),
			"complete_games": _distribution(_float_values(pitchers, "complete_games"), 0),
		},
		"teams": {
			"win_rate": _distribution(_float_values(team_rows, "win_rate"), 3),
			"runs_per_game": _distribution(_float_values(team_rows, "runs_per_game"), 3),
			"runs_allowed_per_game": _distribution(_float_values(team_rows, "runs_allowed_per_game"), 3),
			"ops": _distribution(_float_values(team_rows, "ops"), 3),
			"era": _distribution(_positive_float_values(team_rows, "era"), 2),
		},
	}


# 短期バランスの健全性チェック。得点環境、OPS/ERA、球数、盗塁、完投率、チーム勝率などを監視する。
# warn は要確認、fail は明らかな壊れ方として扱う。
static func balance_health(report: Dictionary) -> Dictionary:
	var checks: Array = []
	var completed: int = int(report.get("seasons_completed", 0))
	var requested: int = int(report.get("seasons_requested", 0))
	var run_env: Dictionary = report.get("run_environment", {}) as Dictionary
	var batting: Dictionary = report.get("batting", {}) as Dictionary
	var pitching: Dictionary = report.get("pitching", {}) as Dictionary
	var batted_ball: Dictionary = report.get("batted_ball", {}) as Dictionary
	var distributions: Dictionary = report.get("distributions", {}) as Dictionary
	var batter_dist: Dictionary = distributions.get("batters", {}) as Dictionary
	var pitcher_dist: Dictionary = distributions.get("pitchers", {}) as Dictionary
	var team_dist: Dictionary = distributions.get("teams", {}) as Dictionary
	var team_games: int = int(run_env.get("team_games", 0))
	var seasons: int = max(1, completed)
	var starts: int = int(pitching.get("starts", 0))
	var complete_game_rate: float = _safe_div(float(pitching.get("complete_games", 0)), float(starts))
	var shutout_cg_ratio: float = _safe_div(float(pitching.get("shutouts", 0)), float(max(1, int(pitching.get("complete_games", 0)))))
	var relief_per_team_game: float = _safe_div(float(pitching.get("relief_appearances", 0)), float(team_games))
	var holds_per_year: float = _safe_div(float(pitching.get("holds", 0)), float(seasons))
	var era_under_2_count: int = int(pitcher_dist.get("era_under_2_count", 0))
	var era_under_2_by_team_max: int = int(pitcher_dist.get("era_under_2_by_team_max", 0))
	var qualified_batters: int = int(batter_dist.get("qualified_count", 0))
	var qualified_pitchers: int = int(pitcher_dist.get("qualified_count", 0))
	var errors: Array = report.get("errors", []) as Array

	_add_equal_check(checks, "completed_seasons", completed, requested, "all requested seasons completed")
	_add_max_check(checks, "simulation_errors", errors.size(), 0.0, 0.0, "simulation errors should be absent")
	_add_range_check(checks, "runs_per_team_game", float(run_env.get("runs_per_team_game", 0.0)), 2.8, 5.2, 2.2, 6.2, "league scoring environment")
	_add_range_check(checks, "league_ops", float(batting.get("ops", 0.0)), 0.620, 0.760, 0.560, 0.840, "league OPS")
	_add_range_check(checks, "league_era", float(pitching.get("era", 0.0)), 2.70, 4.60, 2.20, 5.40, "league ERA")
	_add_range_check(checks, "league_batter_walk_rate", _safe_div(float(batting.get("walks", 0)), float(batting.get("plate_appearances", 0))), 0.072, 0.095, 0.060, 0.110, "league batter BB% (NPB 2015-23 mean 8.30%)")
	_add_range_check(checks, "league_batter_strikeout_rate", _safe_div(float(batting.get("strikeouts", 0)), float(batting.get("plate_appearances", 0))), 0.175, 0.210, 0.150, 0.235, "league batter K% (NPB 2015-23 mean 19.31%)")
	_add_range_check(checks, "league_pitcher_walks_per_nine", float(pitching.get("walks_per_nine", 0.0)), 2.70, 3.60, 2.30, 4.00, "league pitcher BB/9 (NPB 2015-23 mean 3.17)")
	_add_range_check(checks, "league_pitcher_strikeouts_per_nine", float(pitching.get("strikeouts_per_nine", 0.0)), 6.80, 8.00, 6.20, 8.60, "league pitcher K/9 (NPB 2015-23 mean 7.37)")
	_add_range_check(checks, "pitches_per_batter_faced", float(pitching.get("pitches_per_batter_faced", 0.0)), 3.45, 4.10, 3.25, 4.35, "pitch count environment")
	_add_range_check(checks, "stolen_base_attempts_per_game", float(batting.get("stolen_base_attempts_per_game", 0.0)), 0.35, 1.40, 0.15, 2.20, "stolen base attempt volume")
	# 走塁・守備イベントの頻度 (チーム試合あたり)。基準は NPB 2023 実測:
	# 盗塁0.46/成功率~67%/犠打0.71/犠飛0.22/併殺打0.68/失策0.47/暴投0.20/捕逸0.03-0.05。
	var running: Dictionary = report.get("running_defense", {}) as Dictionary
	if not running.is_empty():
		_add_range_check(checks, "stolen_bases_per_team_game", float(running.get("stolen_bases_per_team_game", 0.0)), 0.30, 0.65, 0.10, 1.00, "stolen bases per team game (NPB ~0.46)")
		_add_range_check(checks, "stolen_base_success_rate", float(running.get("stolen_base_success_rate", 0.0)), 0.58, 0.78, 0.45, 0.90, "stolen base success rate (NPB ~0.67)")
		_add_range_check(checks, "sacrifices_per_team_game", float(running.get("sacrifices_per_team_game", 0.0)), 0.40, 1.00, 0.10, 1.60, "sacrifice bunts per team game (NPB ~0.71)")
		_add_range_check(checks, "sacrifice_flies_per_team_game", float(running.get("sacrifice_flies_per_team_game", 0.0)), 0.12, 0.35, 0.04, 0.60, "sacrifice flies per team game (NPB ~0.22)")
		_add_range_check(checks, "double_plays_per_team_game", float(running.get("double_plays_per_team_game", 0.0)), 0.45, 0.95, 0.25, 1.40, "GDP per team game (NPB ~0.68)")
		_add_range_check(checks, "errors_per_team_game", float(running.get("errors_per_team_game", 0.0)), 0.30, 0.70, 0.12, 1.10, "errors per team game (NPB ~0.47)")
		_add_range_check(checks, "wild_pitches_per_team_game", float(running.get("wild_pitches_per_team_game", 0.0)), 0.10, 0.35, 0.02, 0.60, "wild pitches per team game (NPB ~0.20)")
		_add_range_check(checks, "passed_balls_per_team_game", float(running.get("passed_balls_per_team_game", 0.0)), 0.010, 0.100, 0.0, 0.250, "passed balls per team game (NPB ~0.03-0.05)")
	_add_min_check(checks, "hard_hit_rate", float(batted_ball.get("hard_hit_rate", 0.0)), 0.20, 0.10, "hard-hit rate should not collapse")
	# NPB 2015-23 は 48-61 人だが、それは片リーグのみ DH (打席スロット 9×6 + 8×6 = 102) の値。
	# 本作の既定は両リーグ DH (108 スロット) なので、スロットあたりの到達率 (約 0.51) を保った
	# 等価目標は 52-65 人。warn 帯はそれに少し余裕を持たせてある ([[project_qualified_batter_count]])。
	_add_range_check(checks, "qualified_batter_count", qualified_batters, 50.0, 68.0, 36.0, 82.0, "qualified batter count (NPB 48-61 を両リーグDHへ換算して 52-65)")
	_add_range_check(checks, "qualified_pitcher_count", qualified_pitchers, 14.0, 28.0, 6.0, 38.0, "qualified pitcher count (NPB 2015-23: 14-26)")
	_add_range_check(checks, "qualified_batter_average_p10", _dist_value(batter_dist, "batting_average", "p10"), 0.225, 0.255, 0.200, 0.275, "qualified batter AVG p10")
	_add_range_check(checks, "qualified_batter_average_p50", _dist_value(batter_dist, "batting_average", "p50"), 0.255, 0.290, 0.235, 0.310, "qualified batter AVG median")
	_add_range_check(checks, "qualified_batter_average_p90", _dist_value(batter_dist, "batting_average", "p90"), 0.295, 0.330, 0.275, 0.350, "qualified batter AVG p90")
	_add_range_check(checks, "qualified_batter_ops_p10", _dist_value(batter_dist, "ops", "p10"), 0.600, 0.710, 0.500, 0.760, "qualified batter OPS p10")
	_add_range_check(checks, "qualified_batter_ops_p50", _dist_value(batter_dist, "ops", "p50"), 0.700, 0.820, 0.640, 0.880, "qualified batter OPS median")
	_add_range_check(checks, "qualified_batter_ops_p90", _dist_value(batter_dist, "ops", "p90"), 0.860, 0.980, 0.800, 1.040, "qualified batter OPS p90")
	_add_range_check(checks, "qualified_batter_walks_p50", _dist_value(batter_dist, "walks", "p50"), 38.0, 60.0, 28.0, 75.0, "qualified batter BB median (143-game season)")
	_add_range_check(checks, "qualified_batter_strikeouts_p50", _dist_value(batter_dist, "strikeouts", "p50"), 70.0, 110.0, 55.0, 130.0, "qualified batter SO median (143-game season)")
	_add_range_check(checks, "qualified_batter_walk_rate_p10", _dist_value(batter_dist, "walk_rate", "p10"), 0.045, 0.070, 0.025, 0.085, "qualified batter BB% p10")
	_add_range_check(checks, "qualified_batter_walk_rate_p50", _dist_value(batter_dist, "walk_rate", "p50"), 0.075, 0.105, 0.055, 0.125, "qualified batter BB% median")
	_add_range_check(checks, "qualified_batter_walk_rate_p90", _dist_value(batter_dist, "walk_rate", "p90"), 0.115, 0.165, 0.090, 0.200, "qualified batter BB% p90")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p10", _dist_value(batter_dist, "strikeout_rate", "p10"), 0.090, 0.125, 0.070, 0.150, "qualified batter K% p10")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p50", _dist_value(batter_dist, "strikeout_rate", "p50"), 0.145, 0.180, 0.120, 0.210, "qualified batter K% median")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p90", _dist_value(batter_dist, "strikeout_rate", "p90"), 0.210, 0.255, 0.180, 0.300, "qualified batter K% p90")
	_add_range_check(checks, "qualified_pitcher_era_p10", _dist_value(pitcher_dist, "era", "p10"), 1.70, 2.60, 1.20, 3.10, "qualified pitcher ERA p10")
	_add_range_check(checks, "qualified_pitcher_era_p50", _dist_value(pitcher_dist, "era", "p50"), 2.50, 3.50, 2.10, 3.90, "qualified pitcher ERA median")
	_add_range_check(checks, "qualified_pitcher_walks_p50", _dist_value(pitcher_dist, "walks", "p50"), 32.0, 58.0, 22.0, 72.0, "qualified pitcher BB median (143-game season)")
	_add_range_check(checks, "qualified_pitcher_strikeouts_p50", _dist_value(pitcher_dist, "strikeouts", "p50"), 105.0, 155.0, 80.0, 180.0, "qualified pitcher SO median (143-game season)")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p10", _dist_value(pitcher_dist, "walks_per_nine", "p10"), 0.90, 2.20, 0.50, 2.80, "qualified pitcher BB/9 p10")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p50", _dist_value(pitcher_dist, "walks_per_nine", "p50"), 2.00, 2.90, 1.50, 3.50, "qualified pitcher BB/9 median")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p90", _dist_value(pitcher_dist, "walks_per_nine", "p90"), 2.80, 3.80, 2.20, 4.50, "qualified pitcher BB/9 p90")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p10", _dist_value(pitcher_dist, "strikeouts_per_nine", "p10"), 5.10, 6.60, 4.20, 7.20, "qualified pitcher K/9 p10")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p50", _dist_value(pitcher_dist, "strikeouts_per_nine", "p50"), 6.50, 8.00, 5.50, 8.80, "qualified pitcher K/9 median")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p90", _dist_value(pitcher_dist, "strikeouts_per_nine", "p90"), 8.60, 10.70, 7.50, 12.00, "qualified pitcher K/9 p90")
	_add_range_check(checks, "qualified_pitcher_ip_p10", _dist_value(pitcher_dist, "innings_pitched", "p10"), 143.0, 153.0, 143.0, 165.0, "qualified pitcher innings p10")
	_add_range_check(checks, "qualified_pitcher_ip_p50", _dist_value(pitcher_dist, "innings_pitched", "p50"), 148.0, 172.0, 143.0, 185.0, "qualified pitcher innings median")
	_add_max_check(checks, "batter_ops_max", _dist_value(batter_dist, "ops", "max"), 1.20, 1.35, "qualified batter OPS max")
	_add_max_check(checks, "batter_hr_max", _dist_value(batter_dist, "home_runs", "max"), 60.0, 75.0, "single-season HR leader")
	# MLB fWAR 実測 (2015-24): 年間最高は通常 8.5-9.5、10 超は Judge/Witt 級で10年に4回
	# (最大 11.33)。143試合換算 (x143/162) でリーダー帯 ~7.5-10.0。
	_add_range_check(checks, "batter_war_max", _dist_value(batter_dist, "war", "max"), 5.5, 10.2, 4.0, 12.0, "qualified batter WAR leader")
	_add_min_check(checks, "pitcher_era_min", _dist_value(pitcher_dist, "era", "min"), 0.90, 0.50, "qualified pitcher ERA floor")
	_add_max_check(checks, "pitcher_era_under_2_count", era_under_2_count, 5.0, 7.0, "qualified pitchers with ERA under 2.00")
	_add_manual_check(checks, "pitcher_era_under_2_by_team_max", STATUS_FAIL if era_under_2_by_team_max >= 3 else STATUS_PASS, era_under_2_by_team_max, "no team should usually have three qualified sub-2 ERA pitchers")
	_add_max_check(checks, "pitcher_k9_max", _dist_value(pitcher_dist, "strikeouts_per_nine", "max"), 14.0, 17.0, "qualified pitcher K/9 max")
	# MLB fWAR 実測 (2015-24): 投手の年間最高は通常 6.5-7.5、10年最大 9.04 (deGrom 2018, 217IP)。
	# 本リーグのエースは 6 人ローテで ~165IP のため IP 比 (~0.79) で換算しリーダー帯 ~4.5-7.1。
	_add_range_check(checks, "pitcher_war_max", _dist_value(pitcher_dist, "war", "max"), 4.0, 7.5, 2.8, 9.0, "qualified pitcher WAR leader")
	_add_max_check(checks, "complete_game_rate", complete_game_rate, 0.12, 0.22, "complete games per start")
	_add_max_check(checks, "shutout_complete_game_ratio", shutout_cg_ratio, 0.75, 0.90, "shutout share of complete games")
	_add_range_check(checks, "relief_appearances_per_team_game", relief_per_team_game, 2.4, 4.2, 1.8, 5.2, "bullpen usage volume")
	_add_min_check(checks, "holds_per_year", holds_per_year, 800.0, 250.0, "hold volume is intentionally watched")
	_add_max_check(checks, "team_win_rate_max", _dist_value(team_dist, "win_rate", "max"), 0.750, 0.820, "team win-rate ceiling")
	_add_min_check(checks, "team_win_rate_min", _dist_value(team_dist, "win_rate", "min"), 0.250, 0.180, "team win-rate floor")
	return _health_result(checks)


# 長期オートプレイの年度別行から、リーグ環境・ロスター規模・タイトルリーダーの分布を作る。
static func long_distributions(report: Dictionary) -> Dictionary:
	var rows: Array = report.get("yearly", []) as Array
	var leader_ops: Array = []
	var leader_era: Array = []
	var leader_k: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var leaderboards: Dictionary = row.get("leaderboards", {}) as Dictionary
		leader_ops.append(_leader_value(leaderboards, "batting", "ops"))
		leader_era.append(_leader_value(leaderboards, "pitching", "era"))
		leader_k.append(_leader_value(leaderboards, "pitching", "strikeouts"))
	return {
		"year_count": rows.size(),
		"league": {
			"ops": _distribution(_nested_values(rows, ["season", "batting", "ops"]), 3),
			"era": _distribution(_nested_values(rows, ["season", "pitching", "era"]), 2),
			"runs_per_team_game": _distribution(_nested_values(rows, ["season", "runs_per_team_game"]), 3),
		},
		"roster": {
			"active_players": _distribution(_nested_values(rows, ["roster_before_season", "active_players"]), 0),
			"controlled_players": _distribution(_nested_values(rows, ["roster_before_season", "controlled_players"]), 0),
			"development_players": _distribution(_nested_values(rows, ["roster_before_season", "development_players"]), 0),
			"average_age": _distribution(_nested_values(rows, ["roster_before_season", "average_age"]), 2),
			"average_overall": _distribution(_nested_values(rows, ["roster_before_season", "average_overall"]), 2),
			"team_roster_max": _distribution(_nested_values(rows, ["roster_before_season", "team_roster_max"]), 0),
			"team_controlled_max": _distribution(_nested_values(rows, ["roster_before_season", "team_controlled_max"]), 0),
			"team_development_max": _distribution(_nested_values(rows, ["roster_before_season", "team_development_max"]), 0),
			"team_foreign_max": _distribution(_nested_values(rows, ["roster_before_season", "team_foreign_max"]), 0),
		},
		"post_roster": {
			"team_controlled_min": _distribution(_nested_values(rows, ["roster_after_offseason_next_year", "team_controlled_min"]), 0),
			"team_controlled_max": _distribution(_nested_values(rows, ["roster_after_offseason_next_year", "team_controlled_max"]), 0),
		},
		"leaders": {
			"ops": _distribution(leader_ops, 3),
			"era": _distribution(leader_era, 2),
			"strikeouts": _distribution(leader_k, 0),
		},
		"players": {
			"qualified_batters": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "qualified_count"]), 1),
			"batter_average_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "average", "p10"]), 3),
			"batter_average_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "average", "p50"]), 3),
			"batter_average_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "average", "p90"]), 3),
			"batter_ops_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "ops", "p10"]), 3),
			"batter_ops_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "ops", "p50"]), 3),
			"batter_ops_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "ops", "p90"]), 3),
			"batter_walks_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "walks", "p50"]), 1),
			"batter_strikeouts_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "strikeouts", "p50"]), 1),
			"batter_walk_rate_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "walk_rate", "p10"]), 4),
			"batter_walk_rate_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "walk_rate", "p50"]), 4),
			"batter_walk_rate_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "walk_rate", "p90"]), 4),
			"batter_strikeout_rate_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "strikeout_rate", "p10"]), 4),
			"batter_strikeout_rate_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "strikeout_rate", "p50"]), 4),
			"batter_strikeout_rate_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "strikeout_rate", "p90"]), 4),
			"batter_ops_900_count": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "ops_900_count"]), 1),
			"batter_ops_950_count": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "batters", "ops_950_count"]), 1),
			"qualified_pitchers": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "qualified_count"]), 1),
			"pitcher_era_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "era", "p10"]), 2),
			"pitcher_era_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "era", "p50"]), 2),
			"pitcher_era_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "era", "p90"]), 2),
			"pitcher_walks_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "walks", "p50"]), 1),
			"pitcher_strikeouts_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "strikeouts", "p50"]), 1),
			"pitcher_walks_per_nine_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "walks_per_nine", "p10"]), 2),
			"pitcher_walks_per_nine_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "walks_per_nine", "p50"]), 2),
			"pitcher_walks_per_nine_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "walks_per_nine", "p90"]), 2),
			"pitcher_strikeouts_per_nine_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "strikeouts_per_nine", "p10"]), 2),
			"pitcher_strikeouts_per_nine_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "strikeouts_per_nine", "p50"]), 2),
			"pitcher_strikeouts_per_nine_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "strikeouts_per_nine", "p90"]), 2),
			"pitcher_ip_p10": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "innings_pitched", "p10"]), 1),
			"pitcher_ip_p50": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "innings_pitched", "p50"]), 1),
			"pitcher_ip_p90": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "innings_pitched", "p90"]), 1),
			"pitcher_ip_max": _distribution(_nested_values(rows, ["leaderboards", "player_distributions", "pitchers", "innings_pitched", "max"]), 1),
		},
		"flows": {
			"trades": _distribution(_nested_values(rows, ["trades", "count"]), 1),
			"fa_declared": _distribution(_nested_values(rows, ["offseason", "fa_declared_count"]), 1),
			"released": _distribution(_nested_values(rows, ["offseason", "controlled_removed_count"]), 1),
		},
	}


# 長期オートプレイの健全性チェック。ロスター上限、孤立選手、長期平均の攻守環境、
# タイトルリーダーの極端値を監視する。
static func long_health(report: Dictionary) -> Dictionary:
	var checks: Array = []
	var completed: int = int(report.get("seasons_completed", 0))
	var requested: int = int(report.get("seasons_requested", 0))
	var errors: Array = report.get("errors", []) as Array
	var final_roster: Dictionary = report.get("final_roster_after_last_offseason", {}) as Dictionary
	var windows: Dictionary = report.get("window_summaries", {}) as Dictionary
	var last_10: Dictionary = windows.get("last_10_years", {}) as Dictionary
	var distributions: Dictionary = report.get("distributions", {}) as Dictionary
	var roster_dist: Dictionary = distributions.get("roster", {}) as Dictionary
	var post_roster_dist: Dictionary = distributions.get("post_roster", {}) as Dictionary
	var leader_dist: Dictionary = distributions.get("leaders", {}) as Dictionary
	var player_dist: Dictionary = distributions.get("players", {}) as Dictionary
	var milestones: Dictionary = report.get("milestones", {}) as Dictionary

	_add_equal_check(checks, "completed_seasons", completed, requested, "all requested seasons completed")
	_add_max_check(checks, "simulation_errors", errors.size(), 0.0, 0.0, "simulation errors should be absent")
	_add_max_check(checks, "team_controlled_max", _max_nested(roster_dist, "team_controlled_max", final_roster.get("team_controlled_max", 0)), 70.0, 70.0, "hard 70-man controlled cap")
	_add_max_check(checks, "team_roster_max", _max_nested(roster_dist, "team_roster_max", final_roster.get("team_roster_max", 0)), 90.0, 110.0, "total roster including development")
	_add_max_check(checks, "team_development_max", _max_nested(roster_dist, "team_development_max", final_roster.get("team_development_max", 0)), 20.0, 35.0, "development roster growth")
	_add_max_check(checks, "team_foreign_max", _max_nested(roster_dist, "team_foreign_max", final_roster.get("team_foreign_max", 0)), 4.0, 4.0, "foreign player held cap")
	_add_max_check(checks, "teamless_active_players", int(final_roster.get("teamless_active_players", 0)), 0.0, 0.0, "teamless active players")
	_add_max_check(checks, "free_agent_orphans", int(final_roster.get("free_agent_orphans", 0)), 0.0, 0.0, "unresolved FA pool players")
	_add_max_check(checks, "released_orphans", int(final_roster.get("released_orphans", 0)), 0.0, 0.0, "unresolved released players outside retirement")
	# 測るのは「戦力外フェーズで支配下枠から外れた人数」(戦力外通告 + 育成降格)で、
	# 戦力外通告だけを数えると育成降格の分だけ実際の枠の空き方より過少に見えるため合算で持つ。
	# 帯の根拠 (NPB 実測): 12月頭に一括公示される支配下選手の自由契約 (= 戦力外通告 + 支配下→育成再契約 +
	# 外国人退団) から外国人を除いた日本人の人数は
	#   2021年 126-22=104 / 2022年 141-33=108 / 2023年 171-42=129 / 2024年 143-31=112 (平均 113.3)。
	# NPB はこの中に引退者も含む (任意引退公示は年2名程度で、引退選手もほぼ自由契約公示に載る) 一方、
	# ゲームは引退ステップが先に数名抜くので、戦力外フェーズの担当分はこれよりやや少なくてよい。
	# → 平均 100〜125 を目標帯、単年は 95〜135 を目標帯とする。
	# 総数は年度別レンジも見て、平均だけ合って末期に減衰する状態を通さない。
	var flow_dist: Dictionary = distributions.get("flows", {}) as Dictionary
	var released_dist: Dictionary = flow_dist.get("released", {}) as Dictionary
	_add_range_check(checks, "released_per_year", float(last_10.get("released_per_year", 0.0)), 100.0, 125.0, 88.0, 140.0, "controlled-roster removals in the release phase per year (release notices + demotions; NPB Japanese-player equivalent 104-129)")
	_add_min_check(checks, "released_yearly_min", float(released_dist.get("min", 0.0)), 95.0, 80.0, "controlled-roster removals should not decay below the target band")
	_add_max_check(checks, "released_yearly_max", float(released_dist.get("max", 0.0)), 135.0, 150.0, "controlled-roster removals should not spike above the target band")
	# 以下2つの母集団は内訳の取れる戦力外通告のみ (育成降格を含まない)。released_per_year とは母数が違う。
	_add_range_check(checks, "released_fielders_per_pitcher", float(last_10.get("released_fielders_per_pitcher", 0.0)), 0.8, 1.3, 0.5, 1.8, "release-notice pitcher-to-fielder composition (fielder count per pitcher)")
	_add_range_check(checks, "released_average_age", float(last_10.get("released_average_age", 0.0)), 26.0, 31.0, 23.0, 35.0, "weighted average age of domestic release notices")
	_add_max_check(checks, "noshow_thirties_survivors_per_year", float(last_10.get("noshow_thirties_survivors_per_year", 0.0)), 1.0, 4.0, "zero-appearance 30+ players surviving the release phase")
	_add_min_check(checks, "post_team_controlled_min", _dist_value(post_roster_dist, "team_controlled_min", "min"), 66.0, 64.0, "every team should finish the offseason with at least 66 controlled players")
	_add_max_check(checks, "post_team_controlled_max", _dist_value(post_roster_dist, "team_controlled_max", "max"), 68.0, 70.0, "every team should finish the offseason with at most 68 controlled players")
	# 選手流動の沈黙/過熱検知。これが無いと「FA宣言が15年間全ゼロ」でも health が pass になる。
	# 平均0 (完全停止) は warn 側に倒して可視化する (初期データのFA日数過少による立ち上がり遅れは許容)。
	_add_range_check(checks, "trades_per_year", _dist_value(flow_dist, "trades", "mean"), 1.0, 8.0, 0.0, 15.0, "in-season trades per year")
	_add_range_check(checks, "fa_declared_per_year", _dist_value(flow_dist, "fa_declared", "mean"), 1.0, 10.0, 0.0, 20.0, "FA declarations per year")
	_add_range_check(checks, "last10_ops", float(last_10.get("ops", 0.0)), 0.620, 0.760, 0.560, 0.840, "last-10-year OPS")
	_add_range_check(checks, "last10_era", float(last_10.get("era", 0.0)), 2.70, 4.60, 2.20, 5.40, "last-10-year ERA")
	_add_range_check(checks, "last10_batter_walk_rate", float(last_10.get("walk_rate", 0.0)), 0.072, 0.095, 0.060, 0.110, "last-10-year batter BB%")
	_add_range_check(checks, "last10_batter_strikeout_rate", float(last_10.get("strikeout_rate", 0.0)), 0.175, 0.210, 0.150, 0.235, "last-10-year batter K%")
	_add_range_check(checks, "last10_pitcher_walks_per_nine", float(last_10.get("walks_per_nine", 0.0)), 2.70, 3.60, 2.30, 4.00, "last-10-year pitcher BB/9")
	_add_range_check(checks, "last10_pitcher_strikeouts_per_nine", float(last_10.get("strikeouts_per_nine", 0.0)), 6.80, 8.00, 6.20, 8.60, "last-10-year pitcher K/9")
	_add_range_check(checks, "last10_average_age", float(last_10.get("average_age", 0.0)), 25.0, 30.0, 23.0, 32.0, "last-10-year average age")
	_add_range_check(checks, "last10_average_overall", float(last_10.get("average_overall", 0.0)), 66.0, 75.0, 62.0, 80.0, "last-10-year average overall")
	_add_range_check(checks, "qualified_batters_mean", _dist_value(player_dist, "qualified_batters", "mean"), 48.0, 70.0, 36.0, 82.0, "qualified batters per year (NPB 2015-23: 48-61)")
	_add_range_check(checks, "qualified_batter_average_p10_mean", _dist_value(player_dist, "batter_average_p10", "mean"), 0.225, 0.255, 0.200, 0.275, "yearly qualified-batter AVG p10")
	_add_range_check(checks, "qualified_batter_average_p50_mean", _dist_value(player_dist, "batter_average_p50", "mean"), 0.255, 0.290, 0.235, 0.310, "yearly qualified-batter AVG median")
	_add_range_check(checks, "qualified_batter_average_p90_mean", _dist_value(player_dist, "batter_average_p90", "mean"), 0.295, 0.330, 0.275, 0.350, "yearly qualified-batter AVG p90")
	_add_range_check(checks, "qualified_batter_ops_p10_mean", _dist_value(player_dist, "batter_ops_p10", "mean"), 0.600, 0.710, 0.500, 0.760, "yearly qualified-batter OPS p10")
	_add_range_check(checks, "qualified_batter_ops_p50_mean", _dist_value(player_dist, "batter_ops_p50", "mean"), 0.700, 0.820, 0.640, 0.880, "yearly qualified-batter OPS median")
	_add_range_check(checks, "qualified_batter_ops_p90_mean", _dist_value(player_dist, "batter_ops_p90", "mean"), 0.860, 0.980, 0.800, 1.040, "yearly qualified-batter OPS p90")
	_add_range_check(checks, "qualified_batter_walks_p50_mean", _dist_value(player_dist, "batter_walks_p50", "mean"), 38.0, 60.0, 28.0, 75.0, "yearly qualified-batter BB median")
	_add_range_check(checks, "qualified_batter_strikeouts_p50_mean", _dist_value(player_dist, "batter_strikeouts_p50", "mean"), 70.0, 110.0, 55.0, 130.0, "yearly qualified-batter SO median")
	_add_range_check(checks, "qualified_batter_walk_rate_p10_mean", _dist_value(player_dist, "batter_walk_rate_p10", "mean"), 0.045, 0.070, 0.025, 0.085, "yearly qualified-batter BB% p10")
	_add_range_check(checks, "qualified_batter_walk_rate_p50_mean", _dist_value(player_dist, "batter_walk_rate_p50", "mean"), 0.075, 0.105, 0.055, 0.125, "yearly qualified-batter BB% median")
	_add_range_check(checks, "qualified_batter_walk_rate_p90_mean", _dist_value(player_dist, "batter_walk_rate_p90", "mean"), 0.115, 0.165, 0.090, 0.200, "yearly qualified-batter BB% p90")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p10_mean", _dist_value(player_dist, "batter_strikeout_rate_p10", "mean"), 0.090, 0.125, 0.070, 0.150, "yearly qualified-batter K% p10")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p50_mean", _dist_value(player_dist, "batter_strikeout_rate_p50", "mean"), 0.145, 0.180, 0.120, 0.210, "yearly qualified-batter K% median")
	_add_range_check(checks, "qualified_batter_strikeout_rate_p90_mean", _dist_value(player_dist, "batter_strikeout_rate_p90", "mean"), 0.210, 0.255, 0.180, 0.300, "yearly qualified-batter K% p90")
	_add_range_check(checks, "qualified_batter_ops_900_mean", _dist_value(player_dist, "batter_ops_900_count", "mean"), 2.0, 12.0, 0.0, 18.0, "qualified batters with OPS .900 or higher")
	_add_range_check(checks, "qualified_batter_ops_950_mean", _dist_value(player_dist, "batter_ops_950_count", "mean"), 1.0, 8.0, 0.0, 12.0, "qualified batters with OPS .950 or higher")
	_add_range_check(checks, "qualified_pitchers_mean", _dist_value(player_dist, "qualified_pitchers", "mean"), 14.0, 28.0, 6.0, 38.0, "qualified pitchers per year (NPB 2015-23: 14-26)")
	_add_range_check(checks, "qualified_pitcher_era_p10_mean", _dist_value(player_dist, "pitcher_era_p10", "mean"), 1.70, 2.60, 1.20, 3.10, "yearly qualified-pitcher ERA p10")
	_add_range_check(checks, "qualified_pitcher_era_p50_mean", _dist_value(player_dist, "pitcher_era_p50", "mean"), 2.50, 3.50, 2.10, 3.90, "yearly qualified-pitcher ERA median")
	_add_range_check(checks, "qualified_pitcher_era_p90_mean", _dist_value(player_dist, "pitcher_era_p90", "mean"), 3.20, 4.30, 2.70, 4.80, "yearly qualified-pitcher ERA p90")
	_add_range_check(checks, "qualified_pitcher_walks_p50_mean", _dist_value(player_dist, "pitcher_walks_p50", "mean"), 32.0, 58.0, 22.0, 72.0, "yearly qualified-pitcher BB median")
	_add_range_check(checks, "qualified_pitcher_strikeouts_p50_mean", _dist_value(player_dist, "pitcher_strikeouts_p50", "mean"), 105.0, 155.0, 80.0, 180.0, "yearly qualified-pitcher SO median")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p10_mean", _dist_value(player_dist, "pitcher_walks_per_nine_p10", "mean"), 0.90, 2.20, 0.50, 2.80, "yearly qualified-pitcher BB/9 p10")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p50_mean", _dist_value(player_dist, "pitcher_walks_per_nine_p50", "mean"), 2.00, 2.90, 1.50, 3.50, "yearly qualified-pitcher BB/9 median")
	_add_range_check(checks, "qualified_pitcher_walks_per_nine_p90_mean", _dist_value(player_dist, "pitcher_walks_per_nine_p90", "mean"), 2.80, 3.80, 2.20, 4.50, "yearly qualified-pitcher BB/9 p90")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p10_mean", _dist_value(player_dist, "pitcher_strikeouts_per_nine_p10", "mean"), 5.10, 6.60, 4.20, 7.20, "yearly qualified-pitcher K/9 p10")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p50_mean", _dist_value(player_dist, "pitcher_strikeouts_per_nine_p50", "mean"), 6.50, 8.00, 5.50, 8.80, "yearly qualified-pitcher K/9 median")
	_add_range_check(checks, "qualified_pitcher_strikeouts_per_nine_p90_mean", _dist_value(player_dist, "pitcher_strikeouts_per_nine_p90", "mean"), 8.60, 10.70, 7.50, 12.00, "yearly qualified-pitcher K/9 p90")
	_add_range_check(checks, "qualified_pitcher_ip_p10_mean", _dist_value(player_dist, "pitcher_ip_p10", "mean"), 143.0, 153.0, 143.0, 165.0, "yearly qualified-pitcher innings p10")
	_add_range_check(checks, "qualified_pitcher_ip_p50_mean", _dist_value(player_dist, "pitcher_ip_p50", "mean"), 148.0, 172.0, 143.0, 185.0, "yearly qualified-pitcher innings median")
	_add_range_check(checks, "qualified_pitcher_ip_p90_mean", _dist_value(player_dist, "pitcher_ip_p90", "mean"), 165.0, 195.0, 150.0, 210.0, "yearly qualified-pitcher innings p90")
	_add_range_check(checks, "qualified_pitcher_ip_max_mean", _dist_value(player_dist, "pitcher_ip_max", "mean"), 175.0, 210.0, 160.0, 225.0, "yearly qualified-pitcher innings maximum")
	_add_max_check(checks, "leader_ops_max", _dist_value(leader_dist, "ops", "max"), 1.20, 1.35, "yearly OPS leader max")
	_add_min_check(checks, "leader_era_min", _dist_value(leader_dist, "era", "min"), 0.90, 0.50, "yearly ERA leader floor")
	_add_max_check(checks, "leader_strikeouts_max", _dist_value(leader_dist, "strikeouts", "max"), 360.0, 430.0, "yearly strikeout leader max")
	if int(milestones.get("draft_only_year", 0)) > 0:
		_add_manual_check(checks, "draft_only_year", STATUS_WARN, int(milestones.get("draft_only_year", 0)), "roster became entirely generated by draft pipeline")
	return _health_result(checks)


# 複数 seed 実行の結果を、health status 件数と指定 metric path の分布へまとめる。
# metric_paths は {"name": ["nested", "path"]} の形で渡す。
static func multi_seed_summary(reports: Array, metric_paths: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = {
		"runs": reports.size(),
		"statuses": {},
		"metrics": {},
	}
	var status_counts: Dictionary = summary["statuses"] as Dictionary
	for report_value in reports:
		var report: Dictionary = report_value as Dictionary
		var health: Dictionary = report.get("health", {}) as Dictionary
		var status: String = str(health.get("status", STATUS_PASS))
		status_counts[status] = int(status_counts.get(status, 0)) + 1
	var metrics: Dictionary = summary["metrics"] as Dictionary
	for metric_name_value in metric_paths.keys():
		var metric_name: String = str(metric_name_value)
		var path: Array = metric_paths[metric_name_value] as Array
		metrics[metric_name] = _distribution(_report_path_values(reports, path), 3)
	return summary


static func multi_seed_health(reports: Array) -> Dictionary:
	var checks: Array = []
	var total_under_2: int = 0
	var max_team_under_2: int = 0
	for report_value in reports:
		var report: Dictionary = report_value as Dictionary
		var pitcher_dist: Dictionary = ((report.get("distributions", {}) as Dictionary).get("pitchers", {}) as Dictionary)
		total_under_2 += int(pitcher_dist.get("era_under_2_count", 0))
		max_team_under_2 = maxi(max_team_under_2, int(pitcher_dist.get("era_under_2_by_team_max", 0)))
	var runs: int = reports.size()
	var avg_under_2: float = _safe_div(float(total_under_2), float(runs))
	var avg_status: String = STATUS_PASS
	if avg_under_2 > 5.0:
		avg_status = STATUS_FAIL
	elif avg_under_2 > 3.0:
		avg_status = STATUS_WARN
	_add_manual_check(checks, "multi_seed_pitcher_era_under_2_average", avg_status, _round_float(avg_under_2, 3), "3-seed average should stay within 0-3 qualified sub-2 ERA pitchers")
	_add_manual_check(checks, "multi_seed_pitcher_era_under_2_by_team_max", STATUS_FAIL if max_team_under_2 >= 3 else STATUS_PASS, max_team_under_2, "no single seed should have three qualified sub-2 ERA pitchers on one team")
	return _health_result(checks)


# check 配列全体の代表 status を決める。fail が1つでもあれば fail、fail なし warn ありなら warn。
static func _health_result(checks: Array) -> Dictionary:
	var status: String = STATUS_PASS
	var fail_count: int = 0
	var warn_count: int = 0
	for check_value in checks:
		var check: Dictionary = check_value as Dictionary
		var check_status: String = str(check.get("status", STATUS_PASS))
		if check_status == STATUS_FAIL:
			fail_count += 1
			status = STATUS_FAIL
		elif check_status == STATUS_WARN:
			warn_count += 1
			if status != STATUS_FAIL:
				status = STATUS_WARN
	return {
		"status": status,
		"fail_count": fail_count,
		"warn_count": warn_count,
		"checks": checks,
	}


# 値が warn 範囲外なら warn、fail 範囲外なら fail。
static func _add_range_check(checks: Array, id: String, value: float, warn_min: float, warn_max: float, fail_min: float, fail_max: float, message: String) -> void:
	var status: String = STATUS_PASS
	if value < fail_min or value > fail_max:
		status = STATUS_FAIL
	elif value < warn_min or value > warn_max:
		status = STATUS_WARN
	checks.append({
		"id": id,
		"status": status,
		"value": _round_float(value, 4),
		"warn_range": [warn_min, warn_max],
		"fail_range": [fail_min, fail_max],
		"message": message,
	})


# 下限だけを見るチェック。値が小さすぎる崩壊を検知する。
static func _add_min_check(checks: Array, id: String, value: float, warn_min: float, fail_min: float, message: String) -> void:
	var status: String = STATUS_PASS
	if value < fail_min:
		status = STATUS_FAIL
	elif value < warn_min:
		status = STATUS_WARN
	checks.append({
		"id": id,
		"status": status,
		"value": _round_float(value, 4),
		"warn_min": warn_min,
		"fail_min": fail_min,
		"message": message,
	})


# 上限だけを見るチェック。完投率やロスター数など増えすぎが問題になる指標に使う。
static func _add_max_check(checks: Array, id: String, value: float, warn_max: float, fail_max: float, message: String) -> void:
	var status: String = STATUS_PASS
	if value > fail_max:
		status = STATUS_FAIL
	elif value > warn_max:
		status = STATUS_WARN
	checks.append({
		"id": id,
		"status": status,
		"value": _round_float(value, 4),
		"warn_max": warn_max,
		"fail_max": fail_max,
		"message": message,
	})


static func _add_equal_check(checks: Array, id: String, value: int, expected: int, message: String) -> void:
	checks.append({
		"id": id,
		"status": STATUS_PASS if value == expected else STATUS_FAIL,
		"value": value,
		"expected": expected,
		"message": message,
	})


static func _add_manual_check(checks: Array, id: String, status: String, value: Variant, message: String) -> void:
	checks.append({
		"id": id,
		"status": status,
		"value": value,
		"message": message,
	})


# 数値配列を丸め済みの代表分布へ変換する。入力が空なら count だけ返す。
static func _distribution(values: Array, digits: int) -> Dictionary:
	var clean: Array = []
	for value in values:
		clean.append(float(value))
	clean.sort()
	if clean.is_empty():
		return {"count": 0}
	return {
		"count": clean.size(),
		"min": _round_float(float(clean[0]), digits),
		"p10": _round_float(_percentile_sorted(clean, 0.10), digits),
		"p50": _round_float(_percentile_sorted(clean, 0.50), digits),
		"p90": _round_float(_percentile_sorted(clean, 0.90), digits),
		"p99": _round_float(_percentile_sorted(clean, 0.99), digits),
		"max": _round_float(float(clean[clean.size() - 1]), digits),
		"mean": _round_float(_mean(clean), digits),
	}


static func _float_values(rows: Array, key: String) -> Array:
	var values: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if not row.has(key):
			continue
		values.append(float(row.get(key, 0.0)))
	return values


static func _positive_float_values(rows: Array, key: String) -> Array:
	var values: Array = []
	for value in _float_values(rows, key):
		if float(value) > 0.0:
			values.append(float(value))
	return values


static func _era_tail_summary(pitchers: Array) -> Dictionary:
	var under_2_count: int = 0
	var by_team: Dictionary = {}
	for row_value in pitchers:
		var row: Dictionary = row_value as Dictionary
		var era: float = float(row.get("era", 0.0))
		if era <= 0.0 or era >= 2.0:
			continue
		under_2_count += 1
		var team_key: String = str(row.get("team_id", 0))
		by_team[team_key] = int(by_team.get(team_key, 0)) + 1
	var by_team_max: int = 0
	var multi_team_count: int = 0
	for count_value in by_team.values():
		var count: int = int(count_value)
		by_team_max = maxi(by_team_max, count)
		if count >= 2:
			multi_team_count += 1
	return {
		"era_under_2_count": under_2_count,
		"era_under_2_by_team_max": by_team_max,
		"era_under_2_team_multi_count": multi_team_count,
	}


# ネストした Dictionary path から値を集める。欠損行はスキップする。
static func _nested_values(rows: Array, keys: Array) -> Array:
	var values: Array = []
	for row_value in rows:
		var current: Variant = row_value
		for key_value in keys:
			if not (current is Dictionary):
				current = null
				break
			current = (current as Dictionary).get(str(key_value), null)
		if current != null:
			values.append(float(current))
	return values


static func _report_path_values(reports: Array, keys: Array) -> Array:
	var values: Array = []
	for report_value in reports:
		var current: Variant = report_value
		for key_value in keys:
			if not (current is Dictionary):
				current = null
				break
			current = (current as Dictionary).get(str(key_value), null)
		if current != null:
			values.append(float(current))
	return values


static func _leader_value(leaderboards: Dictionary, group: String, metric: String) -> float:
	var rows: Array = ((leaderboards.get(group, {}) as Dictionary).get(metric, []) as Array)
	if rows.is_empty():
		return 0.0
	return float((rows[0] as Dictionary).get("value", 0.0))


static func _dist_value(root: Dictionary, metric: String, field: String) -> float:
	var dist: Dictionary = root.get(metric, {}) as Dictionary
	return float(dist.get(field, 0.0))


static func _max_nested(root: Dictionary, metric: String, fallback: Variant) -> float:
	var dist: Dictionary = root.get(metric, {}) as Dictionary
	if dist.is_empty():
		return float(fallback)
	return float(dist.get("max", fallback))


static func _percentile_sorted(sorted: Array, percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index: int = int(round(clamp(percentile, 0.0, 1.0) * float(sorted.size() - 1)))
	return float(sorted[index])


static func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


static func _safe_div(numerator: float, denominator: float) -> float:
	if absf(denominator) < 0.000001:
		return 0.0
	return numerator / denominator


static func _round_float(value: float, digits: int) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor
