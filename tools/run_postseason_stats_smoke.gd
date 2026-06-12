extends Node

# ポストシーズン成績が通常シーズン成績に混ざらず、シリーズ内だけで集計されることを検証する。

const SEED: int = 20260612


func _ready() -> void:
	var failures: Array = []
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	var regular_result: Dictionary = GameSimulator.simulate_next_unplayed_game(season, true)
	if not bool(regular_result.get("ok", false)):
		failures.append("regular season warmup game failed: %s" % str(regular_result.get("message", "")))
		RecordStore.load_from_dict(original_records)
		_finish(failures)
		return

	var before_totals: Dictionary = _regular_totals(season)
	var series: Dictionary = PSPostseasonResult.make_pending_series(1, 2, 1, 0)
	var result: Dictionary = PostseasonService._simulate_series(season, series)
	var after_totals: Dictionary = _regular_totals(season)

	_compare_totals("regular totals", before_totals, after_totals, failures)

	var games: Array = result.get("games", []) as Array
	if games.is_empty():
		failures.append("postseason series produced no games")
	var postseason_stats: Dictionary = result.get("postseason_stats", {}) as Dictionary
	var players: Dictionary = postseason_stats.get("players", {}) as Dictionary
	if players.is_empty():
		failures.append("postseason_stats.players is empty")
	else:
		var postseason_pa: int = 0
		var postseason_outs: int = 0
		var pitcher_decisions: int = 0
		for value in players.values():
			var player: Dictionary = value as Dictionary
			var batter_stats: Dictionary = player.get("batter_stats", {}) as Dictionary
			var pitcher_stats: Dictionary = player.get("pitcher_stats", {}) as Dictionary
			postseason_pa += int(batter_stats.get("plate_appearances", 0))
			postseason_outs += int(pitcher_stats.get("outs_pitched", 0))
			pitcher_decisions += int(pitcher_stats.get("wins", 0))
			pitcher_decisions += int(pitcher_stats.get("losses", 0))
			pitcher_decisions += int(pitcher_stats.get("saves", 0))
			pitcher_decisions += int(pitcher_stats.get("holds", 0))
		if postseason_pa <= 0:
			failures.append("postseason plate appearances were not aggregated")
		if postseason_outs <= 0:
			failures.append("postseason pitcher outs were not aggregated")
		if pitcher_decisions <= 0 and not bool((games[0] as Dictionary).get("draw", false)):
			failures.append("postseason pitcher decisions were not aggregated")

	print("Postseason games: %d" % games.size())
	print("Regular totals before: %s" % JSON.stringify(before_totals))
	print("Regular totals after: %s" % JSON.stringify(after_totals))

	RecordStore.load_from_dict(original_records)
	_finish(failures)


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("Postseason stats smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Postseason stats smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _regular_totals(season: PSSeason) -> Dictionary:
	var totals: Dictionary = {
		"batter_games": 0,
		"plate_appearances": 0,
		"at_bats": 0,
		"hits": 0,
		"home_runs": 0,
		"runs_batted_in": 0,
		"pitcher_games": 0,
		"pitcher_wins": 0,
		"pitcher_losses": 0,
		"pitcher_saves": 0,
		"pitcher_holds": 0,
		"outs_pitched": 0,
		"batters_faced": 0,
		"strikeouts": 0,
		"walks": 0,
		"runs_allowed": 0,
		"advanced_plate_appearances": 0,
	}
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		totals["batter_games"] += record.batter_stats.games
		totals["plate_appearances"] += record.batter_stats.plate_appearances
		totals["at_bats"] += record.batter_stats.at_bats
		totals["hits"] += record.batter_stats.hits
		totals["home_runs"] += record.batter_stats.home_runs
		totals["runs_batted_in"] += record.batter_stats.runs_batted_in
		totals["pitcher_games"] += record.pitcher_stats.games
		totals["pitcher_wins"] += record.pitcher_stats.wins
		totals["pitcher_losses"] += record.pitcher_stats.losses
		totals["pitcher_saves"] += record.pitcher_stats.saves
		totals["pitcher_holds"] += record.pitcher_stats.holds
		totals["outs_pitched"] += record.pitcher_stats.outs_pitched
		totals["batters_faced"] += record.pitcher_stats.batters_faced
		totals["strikeouts"] += record.pitcher_stats.strikeouts
		totals["walks"] += record.pitcher_stats.walks
		totals["runs_allowed"] += record.pitcher_stats.runs_allowed
		if record.advanced_stats != null:
			totals["advanced_plate_appearances"] += record.advanced_stats.plate_appearances
	return totals


func _compare_totals(label: String, expected: Dictionary, actual: Dictionary, failures: Array) -> void:
	for key_value in expected.keys():
		var key: String = str(key_value)
		if int(expected.get(key, 0)) != int(actual.get(key, 0)):
			failures.append("%s %s mismatch: before=%d after=%d" % [
				label,
				key,
				int(expected.get(key, 0)),
				int(actual.get(key, 0)),
			])
