extends Node


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	RecordStore.clear_records()
	AppState.selected_team_id = 1
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026)
	RecordStore.ensure_season_records(AppState.current_season, GameDb.teams, GameDb.players, true)
	failures.append_array(_test_invalid_active_roster_repairs(AppState.current_season))
	failures.append_array(_test_injured_active_roster_repairs(AppState.current_season))

	if failures.is_empty():
		print("Active roster repair smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Active roster repair smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % failure)
		get_tree().quit(1)


func _test_invalid_active_roster_repairs(season: PSSeason) -> Array:
	var failures: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		var bad_ids: Array = _non_catcher_active_ids(records)
		if bad_ids.size() < 20:
			continue
		var original_roster: Dictionary = season.get_active_roster(team.id).duplicate(true)
		season.set_active_roster(team.id, {"player_ids": bad_ids})
		var prepared: Dictionary = PSTeamSetupBuilder.prepare_team_setup(season, team.id)
		if not bool(prepared.get("ok", false)):
			failures.append("team %s repair failed: %s" % [team.short_name, str(prepared.get("message", ""))])
		else:
			var repaired_records: Array = PSTeamSetupBuilder.filter_by_active_roster(season, team.id, records)
			var summary: Dictionary = PSTeamSetupBuilder.summarize_active_roster_ids(_ids_for_records(repaired_records), records)
			var expected_catchers: int = min(2, _healthy_catcher_count(records))
			if int(summary.get("catchers", 0)) < expected_catchers:
				failures.append("team %s repaired catchers=%d expected >=%d healthy catchers" % [team.short_name, int(summary.get("catchers", 0)), expected_catchers])
			if not PSTeamSetupBuilder._records_can_field_game(season, team.id, repaired_records):
				failures.append("team %s repaired roster still cannot field" % team.short_name)
		if original_roster.is_empty():
			season.clear_active_roster(team.id)
		else:
			season.set_active_roster(team.id, original_roster)
		print("[active_roster_repair] %s %s" % [team.short_name, "OK" if failures.is_empty() else "CHECKED"])
		return failures
	failures.append("no suitable team found")
	return failures


func _test_injured_active_roster_repairs(season: PSSeason) -> Array:
	var failures: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team.id)
		if not bool(preview.get("ok", false)):
			continue
		var active_ids: Array = preview.get("player_ids", []) as Array
		if active_ids.size() < 20:
			continue

		var original_roster: Dictionary = season.get_active_roster(team.id).duplicate(true)
		var original_injuries: Dictionary = _injury_days_by_id(records)
		season.set_active_roster(team.id, {"player_ids": active_ids.duplicate()})
		var active_lookup: Dictionary = {}
		for id_value in active_ids:
			active_lookup[int(id_value)] = true
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and active_lookup.has(record.player_id):
				record.injury_days = 14

		var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, team.id, true)
		if not bool(setup.get("ok", false)):
			failures.append("team %s injured repair failed: %s" % [team.short_name, str(setup.get("message", ""))])
		else:
			failures.append_array(_injured_setup_failures(team.short_name, setup))
			var repaired_records: Array = PSTeamSetupBuilder.filter_by_active_roster(season, team.id, records)
			for repaired_row in repaired_records:
				var repaired: PSPlayerSeasonRecord = repaired_row as PSPlayerSeasonRecord
				if repaired != null and repaired.injury_days > 0:
					failures.append("team %s repaired active roster still includes injured player %d" % [team.short_name, repaired.player_id])
					break

		_restore_injury_days(records, original_injuries)
		if original_roster.is_empty():
			season.clear_active_roster(team.id)
		else:
			season.set_active_roster(team.id, original_roster)
		print("[active_roster_injury_repair] %s %s" % [team.short_name, "OK" if failures.is_empty() else "CHECKED"])
		return failures
	failures.append("no suitable team found for injured roster repair")
	return failures


func _non_catcher_active_ids(records: Array) -> Array:
	var ids: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if not record.is_pitcher() and PSTeamSetupBuilder.position_aptitude(record, 2) > 0:
			continue
		ids.append(record.player_id)
		if ids.size() >= 31:
			break
	return ids


func _healthy_catcher_count(records: Array) -> int:
	var count: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or record.injury_days > 0:
			continue
		if not record.is_pitcher() and PSTeamSetupBuilder.position_aptitude(record, 2) > 0:
			count += 1
	return count


func _ids_for_records(records: Array) -> Array:
	var ids: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			ids.append(record.player_id)
	return ids


func _injury_days_by_id(records: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			by_id[record.player_id] = record.injury_days
	return by_id


func _restore_injury_days(records: Array, by_id: Dictionary) -> void:
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and by_id.has(record.player_id):
			record.injury_days = int(by_id[record.player_id])


func _injured_setup_failures(team_name: String, setup: Dictionary) -> Array:
	var failures: Array = []
	for key in ["pitcher", "starter_pitcher"]:
		var pitcher: PSPlayerSeasonRecord = setup.get(key, null) as PSPlayerSeasonRecord
		if pitcher != null and pitcher.injury_days > 0:
			failures.append("team %s setup %s is injured player %d" % [team_name, key, pitcher.player_id])
	for list_key in ["batters", "bench", "relievers"]:
		var records: Array = setup.get(list_key, []) as Array
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and record.injury_days > 0:
				failures.append("team %s setup %s includes injured player %d" % [team_name, list_key, record.player_id])
				break
	var fielders: Array = setup.get("fielders", []) as Array
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var fielder: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if fielder != null and fielder.injury_days > 0:
			failures.append("team %s setup fielders includes injured player %d" % [team_name, fielder.player_id])
			break
	return failures
