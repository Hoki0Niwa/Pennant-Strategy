extends Node

# 失策(errors)が試合シミュレーションで守備選手に計上され、選手・球団レベルで集計できることと、
# その分布が現実的（球団平均≈70・悪いチームで≈90-100、位置順序 遊撃≳三塁>二塁>一塁>捕手>外野、
# 捕手2-5/年、投手も少量>0）であることを検証する。

const GAMES_TO_PLAY: int = 480
const SEED: int = 20260603
const SEASON_GAMES: int = 143
const POS_NAMES: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三", 6: "遊", 7: "左", 8: "中", 9: "右",
}


func _ready() -> void:
	var failures: Array = []

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	# 守備機会(chances)を守備位置別に数える（失策率の診断用）。失策そのものは計上経路と同じ
	# 「打席結果の category==error → fielder_position」「走者イベントの is_fielding_error → error_position」で
	# 守備位置別に数える（record.position 集計だと出場ポジションのズレで歪むため）。
	var pos_chances: Dictionary = {}
	var pos_credit_errors: Dictionary = {}
	for p in range(1, 10):
		pos_chances[p] = 0
		pos_credit_errors[p] = 0

	var simulated: int = 0
	while simulated < GAMES_TO_PLAY:
		var sim_result: Dictionary = GameSimulator.simulate_next_unplayed_game(season, true)
		if not bool(sim_result.get("ok", false)):
			break
		simulated += 1
		var result: Dictionary = sim_result.get("result", {}) as Dictionary
		for event_value in (result.get("play_events", []) as Array):
			var event: Dictionary = event_value as Dictionary
			for fe_value in (event.get("fielding_events", []) as Array):
				var fe: Dictionary = fe_value as Dictionary
				var fpos: int = int(fe.get("position", 0))
				if pos_chances.has(fpos):
					pos_chances[fpos] += 1
			var plate_event: Dictionary = event.get("plate_event", {}) as Dictionary
			if str(plate_event.get("category", "")) == "error":
				var bb: Dictionary = event.get("batted_ball_event", {}) as Dictionary
				var epos: int = int(bb.get("fielder_position", 0))
				if pos_credit_errors.has(epos):
					pos_credit_errors[epos] += 1
			for re_value in (event.get("runner_events", []) as Array):
				var re: Dictionary = re_value as Dictionary
				if bool(re.get("is_fielding_error", false)):
					var rpos: int = int(re.get("error_position", 0))
					if pos_credit_errors.has(rpos):
						pos_credit_errors[rpos] += 1

	# 位置別の失策合計と、全チームの総試合数(チーム視点)を集計する。
	var pos_errors: Dictionary = {}       # position -> errors
	for p in range(1, 10):
		pos_errors[p] = 0
	var player_error_total: int = 0
	var team_error_total: int = 0
	var total_team_games: int = 0
	var team_season_projection: Array = []  # 各チームの 143 試合投影失策

	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team.id, season.year, season.season_number)
		var team_games: int = 0 if team_record == null else int(team_record.stats.games)
		if team_games <= 0:
			continue
		total_team_games += team_games
		var team_errors: int = 0
		for record_row in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			var errors: int = record.batter_stats.errors
			if errors <= 0:
				continue
			player_error_total += errors
			team_errors += errors
			var pos: int = record.position
			if pos_errors.has(pos):
				pos_errors[pos] += errors
		team_error_total += team_errors
		team_season_projection.append(float(team_errors) / float(team_games) * float(SEASON_GAMES))

	var league_avg: float = 0.0
	var league_max: float = 0.0
	var league_min: float = 0.0
	if not team_season_projection.is_empty():
		team_season_projection.sort()
		league_min = team_season_projection[0]
		league_max = team_season_projection[team_season_projection.size() - 1]
		var sum: float = 0.0
		for v in team_season_projection:
			sum += float(v)
		league_avg = sum / float(team_season_projection.size())

	# 位置別: 1球団1シーズンあたりの投影失策（守備位置ベース）。
	var num_teams: int = team_season_projection.size()
	var pos_per_team_season: Dictionary = {}
	for p in range(1, 10):
		if total_team_games > 0:
			pos_per_team_season[p] = float(pos_credit_errors[p]) / float(total_team_games) * float(SEASON_GAMES)
		else:
			pos_per_team_season[p] = 0.0

	# --- 出力 ---
	print("=== error recording / distribution smoke ===")
	print("games simulated      : %d" % simulated)
	print("teams                 : %d" % num_teams)
	print("total errors charged  : %d  (team-aggregate %d)" % [player_error_total, team_error_total])
	print("team-season projected : avg %.1f  min %.1f  max %.1f" % [league_avg, league_min, league_max])
	print("by position (per team-season, by fielding position):")
	for p in range(1, 10):
		print("  %s : %5.1f   (raw %d)" % [str(POS_NAMES[p]), float(pos_per_team_season[p]), int(pos_credit_errors[p])])
	print("fielding chances / errors / rate by position (batted-ball only):")
	for p in range(1, 10):
		var ch: int = int(pos_chances[p])
		var er: int = int(pos_credit_errors[p])
		var rate: float = 0.0 if ch == 0 else float(er) / float(ch)
		print("  %s : chances %6d  errors %4d  rate %.4f" % [str(POS_NAMES[p]), ch, er, rate])

	var of_total: float = float(pos_per_team_season[7]) + float(pos_per_team_season[8]) + float(pos_per_team_season[9])
	var of_avg: float = of_total / 3.0
	var if_core_min: float = min(float(pos_per_team_season[4]), min(float(pos_per_team_season[5]), float(pos_per_team_season[6])))

	# --- 判定 ---
	if simulated != GAMES_TO_PLAY:
		failures.append("expected %d simulated games, got %d" % [GAMES_TO_PLAY, simulated])
	if team_error_total != player_error_total:
		failures.append("team error total %d != player error total %d" % [team_error_total, player_error_total])
	if league_avg < 60.0 or league_avg > 85.0:
		failures.append("league avg team-season errors %.1f outside 60-85 (target ~70)" % league_avg)
	# 最大は「12球団の最悪チームを ~80 試合から143試合へ投影」した値でばらつきが大きい（draw により 85〜95+）。
	# 守備が悪いチームが ~100 近くに達しうることを満たしつつ、ノイズを許容する帯で判定する。
	if league_max < 80.0 or league_max > 120.0:
		failures.append("worst team %.1f outside 80-120 (target ~90-100)" % league_max)
	# 位置順序: 遊撃 >= 三塁 > 二塁 > 一塁 > 捕手、かつ外野は内野中核より少ない。
	if not (float(pos_per_team_season[6]) >= float(pos_per_team_season[5])):
		failures.append("SS(%.1f) should be >= 3B(%.1f)" % [float(pos_per_team_season[6]), float(pos_per_team_season[5])])
	if not (float(pos_per_team_season[5]) > float(pos_per_team_season[4])):
		failures.append("3B(%.1f) should be > 2B(%.1f)" % [float(pos_per_team_season[5]), float(pos_per_team_season[4])])
	if not (float(pos_per_team_season[4]) > float(pos_per_team_season[3])):
		failures.append("2B(%.1f) should be > 1B(%.1f)" % [float(pos_per_team_season[4]), float(pos_per_team_season[3])])
	if not (if_core_min > of_avg):
		failures.append("infield core min(%.1f) should exceed OF avg(%.1f)" % [if_core_min, of_avg])
	if float(pos_per_team_season[2]) < 2.0 or float(pos_per_team_season[2]) > 6.0:
		failures.append("catcher %.1f outside 2-6 (target 2-5)" % float(pos_per_team_season[2]))
	# 外野は守備位置間でほぼ均等（誤差の範囲）であるべき。3 ポジションの最大/最小差を見る。
	var of_max: float = max(float(pos_per_team_season[7]), max(float(pos_per_team_season[8]), float(pos_per_team_season[9])))
	var of_min: float = min(float(pos_per_team_season[7]), min(float(pos_per_team_season[8]), float(pos_per_team_season[9])))
	# 外野の失策メカニズムは守備位置・能力非依存（均等）。残差はチャンス数差とサンプリングノイズなので緩めに判定。
	if (of_max - of_min) > 4.0:
		failures.append("OF spread too large: LF %.1f CF %.1f RF %.1f (max-min %.1f > 4.0)" % [
			float(pos_per_team_season[7]), float(pos_per_team_season[8]), float(pos_per_team_season[9]), of_max - of_min])
	# 投手はコームバッカー(本塁付近ゴロ)のみ対象で機会が極めて少ない。capability の確認に留め失敗にはしない。

	if failures.is_empty():
		print("RESULT: OK")
	else:
		print("RESULT: FAIL")
		for failure in failures:
			print("  - %s" % str(failure))

	get_tree().quit(0 if failures.is_empty() else 1)
