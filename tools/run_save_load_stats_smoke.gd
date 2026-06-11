extends Node

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")

const GAMES_TO_PLAY: int = 6
const SEED: int = 20260601


func _ready() -> void:
	var failures: Array = []
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_players: Array = _players_snapshot()
	var original_save: Dictionary = SaveService.load_state().duplicate(true)
	var original_app: Dictionary = _app_snapshot()

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	AppState.selected_team_id = 1
	AppState.current_screen = "home"
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026)
	AppState.offseason_step = 0
	AppState.offseason_results = {}
	AppState.draft_state = {}
	AppState.released_market_state = {}
	AppState.fa_state = {}
	AppState.foreign_state = {}
	AppState.offseason_active = false
	AppState.postseason_active = false
	AppState.current_postseason = null
	AppState.current_awards = null
	RecordStore.ensure_season_records(AppState.current_season, GameDb.teams, GameDb.players, true)

	var simulated: int = 0
	while simulated < GAMES_TO_PLAY:
		var sim_result: Dictionary = GameSimulator.simulate_next_unplayed_game(AppState.current_season, true)
		if not bool(sim_result.get("ok", false)):
			failures.append("simulation stopped after %d games: %s" % [simulated, str(sim_result.get("message", ""))])
			break
		simulated += 1
	if simulated != GAMES_TO_PLAY:
		failures.append("expected %d simulated games, got %d" % [GAMES_TO_PLAY, simulated])

	var before_totals: Dictionary = _season_totals(AppState.current_season)
	if SQLiteStoreService.is_available():
		var stale_payload: Dictionary = _doubled_current_season_payload(RecordStore.to_dict(), AppState.current_season)
		if not SQLiteStoreService.save_record_store_and_normalized(stale_payload):
			failures.append("failed to write intentionally stale record store")
	if not SaveService.save_state(AppState):
		failures.append("SaveService.save_state failed")

	var saved_payload: Dictionary = SaveService.load_state()
	RecordStore.clear_records()
	_clear_app_state_for_reload()
	if saved_payload.is_empty():
		failures.append("SaveService.load_state returned empty payload")
	else:
		var restored: bool = AppState.restore_from_save(saved_payload)
		if not restored:
			failures.append("AppState.restore_from_save failed")

	var after_totals: Dictionary = _season_totals(AppState.current_season)
	_compare_totals("first load", before_totals, after_totals, failures)

	var saved_payload_second: Dictionary = SaveService.load_state()
	RecordStore.clear_records()
	_clear_app_state_for_reload()
	if saved_payload_second.is_empty():
		failures.append("second SaveService.load_state returned empty payload")
	else:
		AppState.restore_from_save(saved_payload_second)
	var after_second_totals: Dictionary = _season_totals(AppState.current_season)
	_compare_totals("second load", before_totals, after_second_totals, failures)

	print("Before save: %s" % JSON.stringify(before_totals))
	print("After first load: %s" % JSON.stringify(after_totals))
	print("After second load: %s" % JSON.stringify(after_second_totals))

	_restore_environment(original_records, original_players, original_save, original_app)

	if failures.is_empty():
		print("Save/load stats smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Save/load stats smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _season_totals(season: PSSeason) -> Dictionary:
	var totals: Dictionary = {
		"standings_games": 0,
		"standings_wins": 0,
		"standings_losses": 0,
		"team_record_games": 0,
		"batter_games": 0,
		"plate_appearances": 0,
		"at_bats": 0,
		"hits": 0,
		"home_runs": 0,
		"runs_batted_in": 0,
		"pitcher_games": 0,
		"outs_pitched": 0,
		"batters_faced": 0,
		"strikeouts": 0,
		"walks": 0,
		"runs_allowed": 0,
		"advanced_plate_appearances": 0,
	}
	if season == null:
		return totals
	for stats_value in season.standings.values():
		var stats: PSStats = stats_value as PSStats
		totals["standings_games"] += stats.games
		totals["standings_wins"] += stats.wins
		totals["standings_losses"] += stats.losses
	for team_record_value in RecordStore.team_records.values():
		var team_record: PSTeamSeasonRecord = team_record_value as PSTeamSeasonRecord
		if team_record.year != season.year or team_record.season_number != season.season_number:
			continue
		totals["team_record_games"] += team_record.stats.games
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


func _players_snapshot() -> Array:
	var rows: Array = []
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player != null:
			rows.append(player.to_dict())
	return rows


func _doubled_current_season_payload(source: Dictionary, season: PSSeason) -> Dictionary:
	var payload: Dictionary = source.duplicate(true)
	if season == null:
		return payload
	var rows: Array = payload.get("player_records", []) as Array
	for i in range(rows.size()):
		var row: Dictionary = (rows[i] as Dictionary).duplicate(true)
		if int(row.get("year", 0)) != season.year or int(row.get("season_number", 0)) != season.season_number:
			continue
		row["batter_stats"] = _doubled_numeric_dict(row.get("batter_stats", {}) as Dictionary)
		row["pitcher_stats"] = _doubled_numeric_dict(row.get("pitcher_stats", {}) as Dictionary)
		row["advanced_stats"] = _doubled_numeric_dict(row.get("advanced_stats", {}) as Dictionary)
		rows[i] = row
	payload["player_records"] = rows
	return payload


func _doubled_numeric_dict(source: Dictionary) -> Dictionary:
	var out: Dictionary = source.duplicate(true)
	for key in out.keys():
		var value: Variant = out.get(key)
		match typeof(value):
			TYPE_INT:
				out[key] = int(value) * 2
			TYPE_FLOAT:
				out[key] = float(value) * 2.0
	return out


func _app_snapshot() -> Dictionary:
	return {
		"current_screen": AppState.current_screen,
		"selected_team_id": AppState.selected_team_id,
		"current_season": AppState.current_season.to_dict() if AppState.current_season != null else {},
		"current_player_id": AppState.current_player_id,
		"last_status_message": AppState.last_status_message,
		"offseason_step": AppState.offseason_step,
		"offseason_results": AppState.offseason_results.duplicate(true),
		"draft_state": AppState.draft_state.duplicate(true),
		"released_market_state": AppState.released_market_state.duplicate(true),
		"fa_state": AppState.fa_state.duplicate(true),
		"foreign_state": AppState.foreign_state.duplicate(true),
		"offseason_active": AppState.offseason_active,
		"postseason_active": AppState.postseason_active,
		"current_postseason": AppState.current_postseason.to_dict() if AppState.current_postseason != null else {},
		"current_awards": AppState.current_awards.to_dict() if AppState.current_awards != null else {},
		"auto_roster_swap_for_user_team": AppState.auto_roster_swap_for_user_team,
		"auto_roster_swap_during_skip": AppState.auto_roster_swap_during_skip,
		"auto_save_enabled": AppState.auto_save_enabled,
		"league_dh_enabled": AppState.dh_settings_for_schedule(),
	}


func _restore_app_snapshot(snapshot: Dictionary) -> void:
	AppState.current_screen = str(snapshot.get("current_screen", "start"))
	AppState.selected_team_id = int(snapshot.get("selected_team_id", 0))
	var season_data: Dictionary = snapshot.get("current_season", {}) as Dictionary
	AppState.current_season = PSSeason.from_dict(season_data) if not season_data.is_empty() else null
	AppState.current_player_id = int(snapshot.get("current_player_id", 0))
	AppState.last_status_message = str(snapshot.get("last_status_message", ""))
	AppState.offseason_step = int(snapshot.get("offseason_step", 0))
	AppState.offseason_results = (snapshot.get("offseason_results", {}) as Dictionary).duplicate(true)
	AppState.draft_state = (snapshot.get("draft_state", {}) as Dictionary).duplicate(true)
	AppState.released_market_state = (snapshot.get("released_market_state", {}) as Dictionary).duplicate(true)
	AppState.fa_state = (snapshot.get("fa_state", {}) as Dictionary).duplicate(true)
	AppState.foreign_state = (snapshot.get("foreign_state", {}) as Dictionary).duplicate(true)
	AppState.offseason_active = bool(snapshot.get("offseason_active", false))
	AppState.postseason_active = bool(snapshot.get("postseason_active", false))
	var post_data: Dictionary = snapshot.get("current_postseason", {}) as Dictionary
	AppState.current_postseason = PSPostseasonResult.from_dict(post_data) if not post_data.is_empty() else null
	var awards_data: Dictionary = snapshot.get("current_awards", {}) as Dictionary
	AppState.current_awards = PSAwards.from_dict(awards_data) if not awards_data.is_empty() else null
	AppState.auto_roster_swap_for_user_team = bool(snapshot.get("auto_roster_swap_for_user_team", false))
	AppState.auto_roster_swap_during_skip = bool(snapshot.get("auto_roster_swap_during_skip", true))
	AppState.auto_save_enabled = bool(snapshot.get("auto_save_enabled", false))
	var dh_settings: Dictionary = snapshot.get("league_dh_enabled", {}) as Dictionary
	AppState.league_dh_enabled = {
		"central": bool(dh_settings.get("central", true)),
		"pacific": bool(dh_settings.get("pacific", true)),
	}


func _clear_app_state_for_reload() -> void:
	AppState.current_screen = "start"
	AppState.selected_team_id = 0
	AppState.current_season = null
	AppState.current_player_id = 0
	AppState.offseason_step = 0
	AppState.offseason_results = {}
	AppState.draft_state = {}
	AppState.released_market_state = {}
	AppState.fa_state = {}
	AppState.foreign_state = {}
	AppState.offseason_active = false
	AppState.postseason_active = false
	AppState.current_postseason = null
	AppState.current_awards = null
	AppState.league_dh_enabled = {
		"central": true,
		"pacific": true,
	}


func _restore_environment(records_payload: Dictionary, player_rows: Array, save_payload: Dictionary, app_snapshot: Dictionary) -> void:
	if not player_rows.is_empty():
		GameDb.replace_players_from_rows(player_rows)
	_replace_persisted_records(records_payload)
	if SQLiteStoreService.is_available():
		SQLiteStoreService.save_game_state(save_payload)
	_restore_app_snapshot(app_snapshot)


func _replace_persisted_records(records_payload: Dictionary) -> void:
	if SQLiteStoreService.is_available():
		var db: Object = ClassDB.instantiate("SQLite") as Object
		if db != null:
			db.set("path", SQLiteStoreService.RUNTIME_DB_PATH)
			db.set("foreign_keys", true)
			db.set("verbosity_level", 0)
			if bool(db.call("open_db")):
				db.call("query", "DELETE FROM batter_stats")
				db.call("query", "DELETE FROM pitcher_stats")
				db.call("query", "DELETE FROM player_season_records")
				if db.has_method("close_db"):
					db.call("close_db")
	RecordStore.load_from_dict(records_payload)
	RecordStore.save_records()
