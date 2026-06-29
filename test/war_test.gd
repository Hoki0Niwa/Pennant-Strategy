extends GdUnitTestSuite

# WAR の配分・正規化・役割差・BsRセンタリングをガードする回帰スイート。
# WAR 改装(2026-06-29)で「目標(replacement勝率＋野手投手配分)を決めて正規化」方式へ作り替えた。
# 詳細は docs/agent_memory/project_war_redesign.md。
# 全試合シミュは重いので、合成のミニリーグ(year=TEST_YEAR)を RecordStore に注入して
# build_league_context / league_war_summary を直接検証する(高速・決定論)。

const WarCalculator = preload("res://services/reports/war_calculator.gd")
const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")

const TEST_YEAR: int = 9000
const TEST_SEASON: int = 0


func test_war_allocation_normalizes_to_pool_split_and_role_order() -> void:
	var store: Dictionary = RecordStore.player_records
	var added_keys: Array = []
	var pid: int = 90000
	# 野手は意図的に BsR を一律プラス(+5)にする。BsR センタリングが効いていないと
	# 野手 WAR 総和が batting_pool を超え、下の is_equal_approx が落ちる(= Phase 3 のガード)。
	var batter_wobas: Array = [0.290, 0.300, 0.310, 0.320, 0.330, 0.305, 0.295, 0.315]
	for team_id in [1, 2]:
		for woba_value in batter_wobas:
			pid += 1
			var key: String = "wartest_%d" % pid
			store[key] = _make_batter(team_id, pid, 600, float(woba_value), 5.0)
			added_keys.append(key)
		for _i in range(5):  # 先発: 160IP, 全登板が先発
			pid += 1
			var skey: String = "wartest_%d" % pid
			store[skey] = _make_pitcher(team_id, pid, 480, 20, 20, "starter")
			added_keys.append(skey)
		for _j in range(6):  # 救援: 60IP, 全登板が救援
			pid += 1
			var rkey: String = "wartest_%d" % pid
			store[rkey] = _make_pitcher(team_id, pid, 180, 0, 50, "reliever")
			added_keys.append(rkey)

	var ctx: Dictionary = WarCalculator.build_league_context(TEST_YEAR, TEST_SEASON)
	var summary: Dictionary = WarCalculator.league_war_summary(TEST_YEAR, TEST_SEASON, ctx)

	# 注入レコードは必ず後始末する(他スイートへ漏らさない)。
	for k in added_keys:
		store.erase(k)

	var batting_pool: float = float(ctx.get("batting_pool", 0.0))
	var pitching_pool: float = float(ctx.get("pitching_pool", 0.0))
	var batting_war: float = float(summary.get("batting_war_total", 0.0))
	var pitching_war: float = float(summary.get("pitching_war_total", 0.0))
	var batting_share: float = float(summary.get("batting_share", 0.0))
	var pitching_share: float = float(summary.get("pitching_share", 0.0))
	print("WARTEST pools bat=%.2f pit=%.2f | totals bat=%.2f pit=%.2f | share %.3f/%.3f" % [
		batting_pool, pitching_pool, batting_war, pitching_war, batting_share, pitching_share])

	assert_float(batting_pool).is_greater(0.0)
	assert_float(pitching_pool).is_greater(0.0)
	# Phase 1: 野手/投手 WAR 総和が各プールへ正規化される(上積み総和≈0 ＋ BsRセンタリング)。
	assert_float(batting_war).is_equal_approx(batting_pool, 0.3)
	assert_float(pitching_war).is_equal_approx(pitching_pool, 0.3)
	# 配分は BATTING_WAR_SHARE(=0.54) 近傍。
	assert_float(batting_share).is_between(0.52, 0.56)
	assert_float(pitching_share).is_between(0.44, 0.48)

	# Phase 2: 役割別 replacement。平均先発 > 平均救援。
	var benchmarks: Dictionary = summary.get("benchmarks", {}) as Dictionary
	var avg_starter: float = float(benchmarks.get("avg_starter_war_per_162_ip", 0.0))
	var avg_reliever: float = float(benchmarks.get("avg_reliever_war_per_60_ip", 0.0))
	print("WARTEST bench starter=%.2f reliever=%.2f" % [avg_starter, avg_reliever])
	assert_float(avg_starter).is_greater(avg_reliever)
	assert_float(avg_reliever).is_greater_equal(0.0)


# wRAA=0 の平均的な野手は WAR がプール由来の replacement 水準(>0)に乗ること。
func test_average_batter_is_above_replacement() -> void:
	var ctx: Dictionary = {
		"rpw": 8.3,
		"lg_woba": 0.310,
		"woba_scale": PSAdvancedStats.WOBA_SCALE,
		"replacement_runs_per_pa": 8.3 * 1.7 / 600.0,  # フル稼働平均 ≈ +1.7 WAR 相当
		"lg_bsr_per_pa": 0.0,
		"fielding_center": {},
	}
	var record: PSPlayerSeasonRecord = _make_batter(1, 91000, 600, 0.310, 0.0)
	var war_row: Dictionary = WarCalculator.calculate_batter_war(record, ctx)
	print("WARTEST avg_batter war=%.3f" % float(war_row.get("war", 0.0)))
	# wRAA=0(リーグ平均打撃)なので replacement 分だけ残り、+1.5〜+2.0 程度。
	assert_float(float(war_row.get("war", 0.0))).is_between(1.4, 2.0)


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
	record.pitcher_stats = ps
	return record
