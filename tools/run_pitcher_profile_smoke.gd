extends Node


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)

	failures.append_array(_test_real_data_profiles(season))
	failures.append_array(_test_synthetic_profiles())

	if failures.is_empty():
		print("Pitcher profile smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Pitcher profile smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_real_data_profiles(season: PSSeason) -> Array:
	var failures: Array = []
	var pitchers: Array = _all_pitcher_records(season)
	if pitchers.is_empty():
		return ["no pitcher records found"]

	var fixed_single_values: int = 0
	var short_profiles: int = 0
	var ineffective_profiles: int = 0
	var signatures: Dictionary = {}
	var primary_min: int = 101
	var primary_max: int = 0
	var high_k_record: PSPlayerSeasonRecord = null
	var low_k_record: PSPlayerSeasonRecord = null
	var high_k: int = -999
	var low_k: int = 999

	for record_value in pitchers:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var profile: Dictionary = PSPitcherUsageModel.pitcher_profile(record)
		var summary: Dictionary = PSPitcherUsageModel.arsenal_summary(record)
		var values: Array = profile.get("pitch_values", []) as Array
		if values.size() < 2:
			short_profiles += 1
		if values.size() == 1 and int(values[0]) == 50:
			fixed_single_values += 1
		if int(summary.get("effective_pitch_count", 0)) <= 0:
			ineffective_profiles += 1
		var sorted_values: Array = values.duplicate()
		sorted_values.sort()
		sorted_values.reverse()
		signatures[JSON.stringify(sorted_values)] = true
		var primary: int = int(profile.get("primary_pitch", 0))
		primary_min = min(primary_min, primary)
		primary_max = max(primary_max, primary)
		var k_create: int = record.z_display("Pit_KCreate")
		if k_create > high_k:
			high_k = k_create
			high_k_record = record
		if k_create < low_k:
			low_k = k_create
			low_k_record = record

	if fixed_single_values > 0:
		failures.append("fixed [50] pitch_values remained: %d" % fixed_single_values)
	if short_profiles > 0:
		failures.append("pitchers with fewer than two profile pitches: %d" % short_profiles)
	if ineffective_profiles > 0:
		failures.append("pitchers with no effective profile pitches: %d" % ineffective_profiles)
	if signatures.size() < 8:
		failures.append("pitch profile signatures too narrow: %d" % signatures.size())
	if primary_max - primary_min < 8:
		failures.append("primary pitch range too narrow: %d..%d" % [primary_min, primary_max])

	if high_k_record != null and low_k_record != null:
		var high_profile: Dictionary = PSPitcherUsageModel.pitcher_profile(high_k_record)
		var low_profile: Dictionary = PSPitcherUsageModel.pitcher_profile(low_k_record)
		var high_primary: int = int(high_profile.get("primary_pitch", 0))
		var low_primary: int = int(low_profile.get("primary_pitch", 0))
		var high_miss: int = int(high_profile.get("miss_bat_profile", 0))
		var low_miss: int = int(low_profile.get("miss_bat_profile", 0))
		if high_primary <= low_primary + 5:
			failures.append("high-K primary=%d low-K primary=%d" % [high_primary, low_primary])
		if high_miss <= low_miss + 8:
			failures.append("high-K miss_bat=%d low-K miss_bat=%d" % [high_miss, low_miss])

	print("[pitcher_profile] real_data pitchers=%d signatures=%d primary=%d..%d highK=%d lowK=%d" % [
		pitchers.size(),
		signatures.size(),
		primary_min,
		primary_max,
		high_k,
		low_k,
	])
	return failures


func _test_synthetic_profiles() -> Array:
	var failures: Array = []
	var ace: PSPlayerSeasonRecord = _build_pitcher(-910001, {
		"Pit_KCreate": 82,
		"Pit_BBPrevent": 72,
		"Pit_ImpactLimit": 74,
		"Pit_LoftControl": 68,
		"Pit_BarrelDeny": 76,
		"Pit_Efficiency": 72,
		"Pit_Stamina": 78,
		"Pit_FatigueResist": 74,
		"Pit_HoldRunner": 60,
		"Pit_EdgeRate": 72,
	})
	var weak_starter: PSPlayerSeasonRecord = _build_pitcher(-910002, {
		"Pit_KCreate": 38,
		"Pit_BBPrevent": 42,
		"Pit_ImpactLimit": 40,
		"Pit_LoftControl": 42,
		"Pit_BarrelDeny": 38,
		"Pit_Efficiency": 44,
		"Pit_Stamina": 66,
		"Pit_FatigueResist": 48,
		"Pit_HoldRunner": 48,
		"Pit_EdgeRate": 42,
	})
	var short_power: PSPlayerSeasonRecord = _build_pitcher(-910003, {
		"Pit_KCreate": 84,
		"Pit_BBPrevent": 56,
		"Pit_ImpactLimit": 70,
		"Pit_LoftControl": 58,
		"Pit_BarrelDeny": 70,
		"Pit_Efficiency": 58,
		"Pit_Stamina": 35,
		"Pit_FatigueResist": 48,
		"Pit_HoldRunner": 50,
		"Pit_EdgeRate": 78,
	})

	var ace_profile: Dictionary = PSPitcherUsageModel.pitcher_profile(ace)
	var weak_profile: Dictionary = PSPitcherUsageModel.pitcher_profile(weak_starter)
	var short_profile: Dictionary = PSPitcherUsageModel.pitcher_profile(short_power)
	var ace_summary: Dictionary = PSPitcherUsageModel.arsenal_summary(ace)
	var weak_summary: Dictionary = PSPitcherUsageModel.arsenal_summary(weak_starter)
	var short_summary: Dictionary = PSPitcherUsageModel.arsenal_summary(short_power)
	var ace_depth: float = PSPitcherUsageModel.starter_depth_rating(ace_summary)
	var weak_depth: float = PSPitcherUsageModel.starter_depth_rating(weak_summary)
	var short_finish: float = PSPitcherUsageModel.reliever_finish_rating(short_summary)

	if (ace_profile.get("pitch_values", []) as Array).size() < 4:
		failures.append("ace profile should expose at least four pitches")
	if (weak_profile.get("pitch_values", []) as Array).size() < 3:
		failures.append("weak starter should still expose a starter mix")
	if (short_profile.get("pitch_values", []) as Array).size() > 3:
		failures.append("short power reliever should not gain starter depth")
	if int(ace_profile.get("primary_pitch", 0)) <= int(weak_profile.get("primary_pitch", 0)) + 15:
		failures.append("ace primary did not separate from weak starter")
	if ace_depth <= weak_depth + 10.0:
		failures.append("starter depth did not separate: ace=%.1f weak=%.1f" % [ace_depth, weak_depth])
	if short_finish <= float(int(weak_profile.get("primary_pitch", 0))) + 10.0:
		failures.append("short power reliever finish too low: %.1f" % short_finish)

	print("[pitcher_profile] synthetic ace=%s weak=%s short=%s depth=%.1f/%.1f finish=%.1f" % [
		JSON.stringify(ace_summary.get("pitch_values", [])),
		JSON.stringify(weak_summary.get("pitch_values", [])),
		JSON.stringify(short_summary.get("pitch_values", [])),
		ace_depth,
		weak_depth,
		short_finish,
	])
	return failures


func _all_pitcher_records(season: PSSeason) -> Array:
	var pitchers: Array = []
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		if team == null:
			continue
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_value in records:
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record != null and record.is_pitcher():
				pitchers.append(record)
	return pitchers


func _build_pitcher(player_id: int, displays: Dictionary) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = 1
	record.role = "starter"
	record.throwing_hand = "R"
	var z: Dictionary = {}
	for key_value in PSPlayer.Z_PITCHER_ABILITY_KEYS.keys():
		var key: String = str(key_value)
		z[key] = PSAbilityScale.display_to_z(int(displays.get(key, 50)))
	record.z_abilities_snapshot = z
	return record
