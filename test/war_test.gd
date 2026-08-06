extends GdUnitTestSuite

# WAR の代替水準・役割差・基礎指標をガードする回帰スイート。
# 合成のミニリーグを RecordStore に注入し、build_league_context / league_war_summary を
# 高速かつ決定論的に検証する。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const TEST_YEAR: int = 9000
const TEST_SEASON: int = 0


func test_war_allocation_uses_fangraphs_pools_and_role_order() -> void:
	var added_keys: Array = []
	var pid: int = 90000
	var batter_wobas: Array = [0.290, 0.300, 0.310, 0.320, 0.330, 0.305, 0.295, 0.315]
	for team_id in [1, 2]:
		for woba_value in batter_wobas:
			pid += 1
			var key: String = "wartest_%d" % pid
			RecordStore.set_player_record(
				_make_batter(team_id, pid, 600, float(woba_value), 5.0),
				key
			)
			added_keys.append(key)
		for _i in range(5):  # 先発: 160IP, 全登板が先発
			pid += 1
			var skey: String = "wartest_%d" % pid
			RecordStore.set_player_record(
				_make_pitcher(team_id, pid, 480, 20, 20, "starter"),
				skey
			)
			added_keys.append(skey)
		for _j in range(6):  # 救援: 60IP, 全登板が救援
			pid += 1
			var rkey: String = "wartest_%d" % pid
			RecordStore.set_player_record(
				_make_pitcher(team_id, pid, 180, 0, 50, "reliever"),
				rkey
			)
			added_keys.append(rkey)

	var meta: Dictionary = {"num_teams": 2, "games_per_team": 162.0}
	var ctx: Dictionary = WarCalculator.build_league_context(TEST_YEAR, TEST_SEASON, meta)
	var summary: Dictionary = WarCalculator.league_war_summary(TEST_YEAR, TEST_SEASON, ctx, meta)

	for k in added_keys:
		RecordStore.erase_player_record_by_key(k)

	var repl_per_pa: float = float(ctx.get("replacement_runs_per_pa", 0.0))
	var expected_batter_pool: float = WarCalculator.POSITION_PLAYER_WAR_POOL_FULL_SEASON * (162.0 / WarCalculator.FULL_MLB_GAMES)
	var expected_pitcher_pool: float = WarCalculator.PITCHER_WAR_POOL_FULL_SEASON * (162.0 / WarCalculator.FULL_MLB_GAMES)
	var expected_repl_per_pa: float = expected_batter_pool * float(ctx.get("rpw", 0.0)) / float(ctx.get("total_batter_pa", 1))
	var batting_war: float = float(summary.get("batting_war_total", 0.0))
	var pitching_war: float = float(summary.get("pitching_war_total", 0.0))
	var batting_share: float = float(summary.get("batting_share", 0.0))
	var pitching_share: float = float(summary.get("pitching_share", 0.0))
	var method: Dictionary = summary.get("method", {}) as Dictionary
	print("WARTEST repl_pa=%.4f expected=%.4f | totals bat=%.2f pit=%.2f | share %.3f/%.3f" % [
		repl_per_pa, expected_repl_per_pa, batting_war, pitching_war, batting_share, pitching_share])

	assert_float(repl_per_pa).is_equal_approx(expected_repl_per_pa, 0.0001)
	assert_str(str(method.get("system", ""))).is_equal("FanGraphs fWAR adapted")
	assert_str(str(method.get("pitcher_run_metric", ""))).is_equal("FIPR9")
	assert_float(batting_war).is_equal_approx(expected_batter_pool, 0.05)
	assert_float(pitching_war).is_equal_approx(expected_pitcher_pool, 0.05)
	assert_float(batting_share).is_equal_approx(0.57, 0.01)
	assert_float(pitching_share).is_equal_approx(0.43, 0.01)

	var benchmarks: Dictionary = summary.get("benchmarks", {}) as Dictionary
	var avg_starter: float = float(benchmarks.get("avg_starter_war_per_162_ip", 0.0))
	var avg_reliever: float = float(benchmarks.get("avg_reliever_war_per_60_ip", 0.0))
	print("WARTEST bench starter=%.2f reliever=%.2f" % [avg_starter, avg_reliever])
	assert_float(avg_starter).is_greater(avg_reliever)
	assert_float(avg_reliever).is_greater_equal(0.0)


# wRAA=0 の平均的な野手は replacement 水準の上積みを得ること。
func test_average_batter_is_above_replacement() -> void:
	var ctx: Dictionary = {
		"rpw": 8.3,
		"lg_woba": 0.310,
		"woba_scale": PSAdvancedStats.WOBA_SCALE,
		"replacement_runs_per_pa": 20.7 / 600.0,
		"lg_bsr_per_pa": 0.0,
		"batter_league_adjustment_runs_per_pa": 0.0,
		"fielding_center": {},
	}
	var record: PSPlayerSeasonRecord = _make_batter(1, 91000, 600, 0.310, 0.0)
	var war_row: Dictionary = WarCalculator.calculate_batter_war(record, ctx)
	print("WARTEST avg_batter war=%.3f" % float(war_row.get("war", 0.0)))
	assert_float(float(war_row.get("war", 0.0))).is_between(2.1, 2.6)


func test_pitcher_fangraphs_replacement_is_role_sensitive() -> void:
	var ctx: Dictionary = {
		"rpw": 8.0,
		"lg_era": 3.7,
		"lg_ra9": 4.0,
		"lg_fip": 3.7,
		"lg_fip_era_constant": 2.9,
		"lg_iffip_constant": 2.9,
		"fipr9_adjustment": 0.3,
		"lg_fipr9": 4.0,
		"pitcher_war_ip_correction": 0.0,
	}
	var starter_record: PSPlayerSeasonRecord = _make_pitcher(1, 92001, 180, 5, 5, "starter")
	var reliever_record: PSPlayerSeasonRecord = _make_pitcher(1, 92002, 180, 0, 50, "reliever")
	var starter_war: Dictionary = WarCalculator.calculate_pitcher_war(starter_record, ctx)
	var reliever_war: Dictionary = WarCalculator.calculate_pitcher_war(reliever_record, ctx)
	assert_str(str(starter_war.get("run_metric_name", ""))).is_equal("FIPR9")
	assert_float(float(starter_war.get("role_replacement_runs_per_9", 0.0))).is_greater(
		float(reliever_war.get("role_replacement_runs_per_9", 0.0))
	)
	assert_float(float(starter_war.get("war", 0.0))).is_greater(float(reliever_war.get("war", 0.0)))


func _make_batter(team_id: int, p_id: int, pa: int, woba: float, bsr: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.year = TEST_YEAR
	record.season_number = TEST_SEASON
	record.team_id = team_id
	record.player_id = p_id
	record.name = "B%d" % p_id
	record.position = 7  # 外野手(投手以外)
	record.role = ""
	var advanced: PSAdvancedStats = PSAdvancedStats.new()
	advanced.player_id = p_id
	advanced.plate_appearances = pa
	advanced.woba_denominator = pa
	advanced.woba_numerator = woba * float(pa)
	advanced.bsr_sum = bsr
	record.advanced_stats = advanced
	return record


# outs と starts/games から比例配分で投手成績を作る(ERA≈3.5 / 全員 FIP≈lgFIP)。
func _make_pitcher(team_id: int, p_id: int, outs: int, starts: int, games: int, role: String) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.year = TEST_YEAR
	record.season_number = TEST_SEASON
	record.team_id = team_id
	record.player_id = p_id
	record.name = "P%d" % p_id
	record.position = 1
	record.role = role
	var ip: float = float(outs) / 3.0
	var ps: PSPitcherStats = PSPitcherStats.new()
	ps.outs_pitched = outs
	ps.games = games
	ps.starts = starts
	ps.relief_appearances = games - starts
	ps.home_runs_allowed = int(round(1.0 * ip / 9.0))
	ps.walks = int(round(2.8 * ip / 9.0))
	ps.hit_batters = int(round(0.3 * ip / 9.0))
	ps.strikeouts = int(round(7.5 * ip / 9.0))
	ps.earned_runs = int(round(3.5 * ip / 9.0))
	ps.runs_allowed = int(round(3.8 * ip / 9.0))
	ps.batters_faced = int(round(4.2 * ip))
	var balls_in_play: int = max(0, ps.batters_faced - ps.strikeouts - ps.walks - ps.hit_batters - ps.home_runs_allowed)
	ps.ground_balls_allowed = int(round(float(balls_in_play) * 0.45))
	ps.line_drives_allowed = int(round(float(balls_in_play) * 0.20))
	ps.infield_flies_allowed = int(round(float(balls_in_play) * 0.08))
	ps.outfield_flies_allowed = max(0, balls_in_play - ps.ground_balls_allowed - ps.line_drives_allowed - ps.infield_flies_allowed)
	record.pitcher_stats = ps
	return record
