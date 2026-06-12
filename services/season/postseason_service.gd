extends RefCounted
class_name PostseasonService

const CS1_WIN_TARGET: int = 2  # 3戦先勝(2勝)
const CS2_WIN_TARGET: int = 4  # 6戦中4勝(1位は1勝アドバンテージ)
const CS2_ADVANTAGE: int = 1
const JS_WIN_TARGET: int = 4   # BO7
const MAX_SAFETY_GAMES: int = 15  # 引き分け連続でも無限ループ防止
const POSTSEASON_STATS_VERSION: int = 1


static func build_initial_state(season: PSSeason, teams: Array) -> PSPostseasonResult:
	var result: PSPostseasonResult = PSPostseasonResult.new()
	result.year = season.year
	result.season_number = season.season_number

	var by_league: Dictionary = _league_standings(season, teams)
	var central_ranked: Array = by_league.get("central", []) as Array
	var pacific_ranked: Array = by_league.get("pacific", []) as Array

	if central_ranked.size() >= 3:
		var c2: PSTeam = central_ranked[1] as PSTeam
		var c3: PSTeam = central_ranked[2] as PSTeam
		result.cs1_central = PSPostseasonResult.make_pending_series(c2.id, c3.id, CS1_WIN_TARGET, 0)
	if pacific_ranked.size() >= 3:
		var p2: PSTeam = pacific_ranked[1] as PSTeam
		var p3: PSTeam = pacific_ranked[2] as PSTeam
		result.cs1_pacific = PSPostseasonResult.make_pending_series(p2.id, p3.id, CS1_WIN_TARGET, 0)
	if central_ranked.size() >= 1:
		var c1: PSTeam = central_ranked[0] as PSTeam
		result.cs2_central = PSPostseasonResult.make_pending_series(c1.id, 0, CS2_WIN_TARGET, CS2_ADVANTAGE)
	if pacific_ranked.size() >= 1:
		var p1: PSTeam = pacific_ranked[0] as PSTeam
		result.cs2_pacific = PSPostseasonResult.make_pending_series(p1.id, 0, CS2_WIN_TARGET, CS2_ADVANTAGE)
	result.japan_series = PSPostseasonResult.make_pending_series(0, 0, JS_WIN_TARGET, 0)
	return result


static func advance_stage(postseason: PSPostseasonResult, stage_key: String, season: PSSeason) -> Dictionary:
	var s: Dictionary = postseason.stage_dict(stage_key)
	if s.is_empty():
		return {"ok": false, "message": "ステージが存在しません"}
	if bool(s.get("completed", false)):
		return {"ok": false, "message": "既に完了しています"}

	# CS2 / JS は前段の勝者を充填
	if stage_key == "cs2_central":
		var w: int = int(postseason.cs1_central.get("winner_id", 0))
		if w == 0:
			return {"ok": false, "message": "CS1セ・リーグが未消化です"}
		s["challenger_id"] = w
	elif stage_key == "cs2_pacific":
		var w2: int = int(postseason.cs1_pacific.get("winner_id", 0))
		if w2 == 0:
			return {"ok": false, "message": "CS1パ・リーグが未消化です"}
		s["challenger_id"] = w2
	elif stage_key == "japan_series":
		var c: int = int(postseason.cs2_central.get("winner_id", 0))
		var p: int = int(postseason.cs2_pacific.get("winner_id", 0))
		if c == 0 or p == 0:
			return {"ok": false, "message": "CS2が未消化です"}
		# パ代表をホーム扱い(慣例的に交互だがここは固定)
		s["top_id"] = p
		s["challenger_id"] = c

	var sim: Dictionary = _simulate_series(season, s)
	for key in sim.keys():
		s[key] = sim[key]
	s["completed"] = true
	postseason.set_stage(stage_key, s)

	if stage_key == "japan_series":
		postseason.champion_team_id = int(s.get("winner_id", 0))

	return {"ok": true, "stage": stage_key, "series": s}


static func is_complete(postseason: PSPostseasonResult) -> bool:
	if postseason == null:
		return false
	return postseason.is_complete()


static func _league_standings(season: PSSeason, teams: Array) -> Dictionary:
	var by_league: Dictionary = {"central": [], "pacific": []}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if not by_league.has(team.league):
			continue
		if not season.standings.has(team.id):
			continue
		by_league[team.league].append({"team": team, "stats": season.standings[team.id]})

	for key in by_league.keys():
		var rows: Array = by_league[key] as Array
		rows.sort_custom(func(a, b) -> bool:
			var stats_a: PSStats = (a as Dictionary)["stats"] as PSStats
			var stats_b: PSStats = (b as Dictionary)["stats"] as PSStats
			if stats_a.win_rate() == stats_b.win_rate():
				return stats_a.wins > stats_b.wins
			return stats_a.win_rate() > stats_b.win_rate()
		)
		var team_list: Array = []
		for row in rows:
			team_list.append((row as Dictionary)["team"])
		by_league[key] = team_list
	return by_league


static func _simulate_series(season: PSSeason, series: Dictionary) -> Dictionary:
	var top_id: int = int(series.get("top_id", 0))
	var challenger_id: int = int(series.get("challenger_id", 0))
	var win_target: int = int(series.get("win_target", 4))
	var advantage: int = int(series.get("advantage_wins", 0))
	var top_wins: int = advantage
	var challenger_wins: int = 0
	var games: Array = []
	var postseason_stats: Dictionary = _normalized_postseason_stats(series.get("postseason_stats", {}) as Dictionary)

	while top_wins < win_target and challenger_wins < win_target:
		if games.size() >= MAX_SAFETY_GAMES:
			break
		var game_num: int = games.size() + 1
		# 2-3-2 風の単純な交替(top=ホームを多めに)
		var home_is_top: bool = (game_num <= 2 or game_num >= 6)
		var home_id: int = top_id if home_is_top else challenger_id
		var away_id: int = challenger_id if home_is_top else top_id

		var game_outcome: Dictionary = _simulate_one_postseason_game(season, away_id, home_id, postseason_stats)
		var winner_id: int = int(game_outcome.get("winning_team_id", 0))
		var is_draw: bool = bool(game_outcome.get("draw", false))
		games.append({
			"game_num": game_num,
			"away_id": away_id,
			"home_id": home_id,
			"away_score": int(game_outcome.get("away_score", 0)),
			"home_score": int(game_outcome.get("home_score", 0)),
			"winner_id": winner_id,
			"draw": is_draw,
		})
		if is_draw:
			continue
		if winner_id == top_id:
			top_wins += 1
		elif winner_id == challenger_id:
			challenger_wins += 1

	var final_winner: int = 0
	if top_wins >= win_target:
		final_winner = top_id
	elif challenger_wins >= win_target:
		final_winner = challenger_id

	return {
		"games": games,
		"winner_id": final_winner,
		"top_wins_final": top_wins,
		"challenger_wins_final": challenger_wins,
		"postseason_stats": postseason_stats,
	}


static func _simulate_one_postseason_game(season: PSSeason, away_id: int, home_id: int, postseason_stats: Dictionary = {}) -> Dictionary:
	var away_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, away_id, true)
	var home_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, home_id, true)
	if not bool(away_setup.get("ok", false)) or not bool(home_setup.get("ok", false)):
		return {"away_score": 0, "home_score": 0, "draw": true, "winning_team_id": 0}
	var snapshots: Dictionary = _snapshot_setup_records(away_setup, home_setup)
	var result: Dictionary = PSGameLoop.simulate_game(away_setup, home_setup)
	if postseason_stats.is_empty():
		postseason_stats.merge(_empty_postseason_stats(), true)
	_apply_postseason_pitching_decisions(season, result, away_id, home_id, away_setup, home_setup)
	_collect_postseason_stat_deltas(snapshots, postseason_stats)
	return result


static func _empty_postseason_stats() -> Dictionary:
	return {
		"version": POSTSEASON_STATS_VERSION,
		"players": {},
	}


static func _normalized_postseason_stats(data: Dictionary) -> Dictionary:
	var out: Dictionary = data.duplicate(true)
	out["version"] = int(out.get("version", POSTSEASON_STATS_VERSION))
	if not out.has("players") or typeof(out.get("players")) != TYPE_DICTIONARY:
		out["players"] = {}
	return out


static func _snapshot_setup_records(away_setup: Dictionary, home_setup: Dictionary) -> Dictionary:
	var records: Array = []
	_append_setup_records(records, away_setup)
	_append_setup_records(records, home_setup)
	var snapshots: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or snapshots.has(record.player_id):
			continue
		snapshots[record.player_id] = {
			"record": record,
			"batter_stats": record.batter_stats.to_dict(),
			"pitcher_stats": record.pitcher_stats.to_dict(),
			"advanced_stats": record.advanced_stats.to_dict() if record.advanced_stats != null else {},
		}
	return snapshots


static func _append_setup_records(records: Array, setup: Dictionary) -> void:
	for key in ["pitcher", "starter_pitcher"]:
		var pitcher: PSPlayerSeasonRecord = setup.get(key, null) as PSPlayerSeasonRecord
		if pitcher != null:
			records.append(pitcher)
	for key in ["batters", "bench", "relievers"]:
		for row in (setup.get(key, []) as Array):
			var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
			if record != null:
				records.append(record)
	for row in (setup.get("fielders", []) as Array):
		var assignment: Dictionary = row as Dictionary
		var fielder: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			records.append(fielder)


static func _collect_postseason_stat_deltas(snapshots: Dictionary, postseason_stats: Dictionary) -> void:
	if not postseason_stats.has("players"):
		postseason_stats["players"] = {}
	for snapshot_value in snapshots.values():
		var snapshot: Dictionary = snapshot_value as Dictionary
		var record: PSPlayerSeasonRecord = snapshot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		var before_batter: PSBatterStats = PSBatterStats.from_dict(snapshot.get("batter_stats", {}) as Dictionary)
		var before_pitcher: PSPitcherStats = PSPitcherStats.from_dict(snapshot.get("pitcher_stats", {}) as Dictionary)
		var batter_delta: PSBatterStats = record.batter_stats.subtract_from(before_batter)
		var pitcher_delta: PSPitcherStats = record.pitcher_stats.subtract_from(before_pitcher)
		if _batter_stats_nonzero(batter_delta) or _pitcher_stats_nonzero(pitcher_delta):
			_merge_postseason_player_delta(postseason_stats, record, batter_delta, pitcher_delta)
		record.batter_stats = before_batter
		record.pitcher_stats = before_pitcher
		var advanced_payload: Dictionary = snapshot.get("advanced_stats", {}) as Dictionary
		var restored_advanced: PSAdvancedStats = PSAdvancedStats.new()
		restored_advanced.load_from_dict(advanced_payload)
		if restored_advanced.player_id == 0:
			restored_advanced.player_id = record.player_id
		record.advanced_stats = restored_advanced


static func _merge_postseason_player_delta(
	postseason_stats: Dictionary,
	record: PSPlayerSeasonRecord,
	batter_delta: PSBatterStats,
	pitcher_delta: PSPitcherStats
) -> void:
	var players: Dictionary = postseason_stats.get("players", {}) as Dictionary
	var key: String = str(record.player_id)
	var row: Dictionary = (players.get(key, {}) as Dictionary).duplicate(true)
	if row.is_empty():
		row = {
			"player_id": record.player_id,
			"name": record.name,
			"team_id": record.team_id,
			"position": record.position,
			"batter_stats": {},
			"pitcher_stats": {},
		}
	var batter_total: PSBatterStats = PSBatterStats.from_dict(row.get("batter_stats", {}) as Dictionary)
	var pitcher_total: PSPitcherStats = PSPitcherStats.from_dict(row.get("pitcher_stats", {}) as Dictionary)
	batter_total.add_from(batter_delta)
	pitcher_total.add_from(pitcher_delta)
	row["team_id"] = record.team_id
	row["batter_stats"] = batter_total.to_dict()
	row["pitcher_stats"] = pitcher_total.to_dict()
	players[key] = row
	postseason_stats["players"] = players


static func _apply_postseason_pitching_decisions(
	season: PSSeason,
	result: Dictionary,
	away_id: int,
	home_id: int,
	away_setup: Dictionary,
	home_setup: Dictionary
) -> void:
	if bool(result.get("draw", false)):
		return
	var away_starter: PSPlayerSeasonRecord = away_setup.get("starter_pitcher", away_setup.get("pitcher", null)) as PSPlayerSeasonRecord
	var home_starter: PSPlayerSeasonRecord = home_setup.get("starter_pitcher", home_setup.get("pitcher", null)) as PSPlayerSeasonRecord
	var away_starter_id: int = away_starter.player_id if away_starter != null else int(result.get("away_pitcher_id", 0))
	var home_starter_id: int = home_starter.player_id if home_starter != null else int(result.get("home_pitcher_id", 0))
	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, away_id, home_id, away_starter_id, home_starter_id)
	result["winning_pitcher_id"] = int(decisions.get("winning_pitcher_id", 0))
	result["losing_pitcher_id"] = int(decisions.get("losing_pitcher_id", 0))
	result["save_pitcher_id"] = int(decisions.get("save_pitcher_id", 0))
	result["hold_pitcher_ids"] = decisions.get("hold_pitcher_ids", []) as Array
	if result["winning_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["winning_pitcher_id"], "win")
	if result["losing_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["losing_pitcher_id"], "loss")
	if result["save_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["save_pitcher_id"], "save")
	for pid_value in (result.get("hold_pitcher_ids", []) as Array):
		var pid: int = int(pid_value)
		if pid > 0:
			_apply_postseason_pitcher_decision(season, pid, "hold")


static func _apply_postseason_pitcher_decision(season: PSSeason, player_id: int, kind: String) -> void:
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
	if record == null:
		return
	match kind:
		"win":
			record.pitcher_stats.wins += 1
		"loss":
			record.pitcher_stats.losses += 1
		"save":
			record.pitcher_stats.saves += 1
		"hold":
			record.pitcher_stats.holds += 1


static func _batter_stats_nonzero(stats: PSBatterStats) -> bool:
	for value in stats.to_dict().values():
		if int(value) != 0:
			return true
	return false


static func _pitcher_stats_nonzero(stats: PSPitcherStats) -> bool:
	for value in stats.to_dict().values():
		if int(value) != 0:
			return true
	return false
