extends Node


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	Rng.set_seed_value(20260605)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)

	failures.append_array(_test_actual_game_outings(season))
	failures.append_array(_test_mid_inning_reliever_trigger(season))
	failures.append_array(_test_outing_decisions())
	failures.append_array(_test_inherited_runner_charge())
	failures.append_array(_test_earned_run_reconstruction())
	failures.append_array(_test_pitcher_fatigue_availability())

	if failures.is_empty():
		print("Pitcher outings smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Pitcher outings smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_actual_game_outings(season: PSSeason) -> Array:
	var failures: Array = []
	var result_wrapper: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
	if not bool(result_wrapper.get("ok", false)):
		return ["simulate_next_unplayed_game failed: %s" % str(result_wrapper.get("message", ""))]
	var result: Dictionary = result_wrapper.get("result", {}) as Dictionary
	var outings: Array = result.get("pitcher_outings", []) as Array
	if outings.size() < 2:
		failures.append("actual game pitcher_outings too small: %d" % outings.size())
	var active_count: int = 0
	var outing_pitches: int = 0
	var outing_bf: int = 0
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		if bool(outing.get("active", false)):
			active_count += 1
		if int(outing.get("pitcher_id", 0)) <= 0:
			failures.append("outing missing pitcher_id")
		if int(outing.get("team_id", 0)) <= 0:
			failures.append("outing missing team_id")
		if int(outing.get("outs", 0)) < 0:
			failures.append("outing negative outs")
		outing_pitches += int(outing.get("pitches", 0))
		outing_bf += int(outing.get("batters_faced", 0))
	if active_count > 0:
		failures.append("active outings remained after game: %d" % active_count)

	var play_pitches: int = 0
	var plate_events: int = 0
	for event_value in (result.get("play_events", []) as Array):
		var event: Dictionary = event_value as Dictionary
		var plate: Dictionary = event.get("plate_event", {}) as Dictionary
		if not plate.is_empty():
			plate_events += 1
			play_pitches += int((event.get("pitch_summary", {}) as Dictionary).get("pitches", 0))
	if outing_pitches != play_pitches:
		failures.append("outing pitches=%d play pitches=%d" % [outing_pitches, play_pitches])
	if outing_bf != plate_events:
		failures.append("outing BF=%d plate events=%d" % [outing_bf, plate_events])
	print("[pitcher_outings] actual_game outings=%d pitches=%d BF=%d decisions=%s/%s/%s" % [
		outings.size(),
		outing_pitches,
		outing_bf,
		str(result.get("winning_pitcher_id", 0)),
		str(result.get("save_pitcher_id", 0)),
		JSON.stringify(result.get("hold_pitcher_ids", [])),
	])
	return failures


func _test_mid_inning_reliever_trigger(season: PSSeason) -> Array:
	var failures: Array = []
	var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, 1, true)
	if not bool(setup.get("ok", false)):
		return ["setup failed for mid-inning trigger: %s" % str(setup.get("message", ""))]
	var starter: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if starter == null:
		return ["setup missing starter"]
	PSBullpenManager.mark_pitcher_used(setup, starter)
	var usage: Dictionary = PSBullpenManager.pitcher_usage_for(setup, starter, PSPitcherUsageModel.ROLE_STARTER)
	usage["pitches"] = 118
	usage["batters_faced"] = 27
	usage["outs"] = 13
	usage["runs"] = 6
	usage["trouble_score"] = PSPitcherUsageModel.MELTDOWN_THRESHOLD + 1.5
	usage["consecutive_reached"] = 4
	var relievers: Array = setup.get("relievers", []) as Array
	if relievers.is_empty():
		return ["setup missing relievers"]
	var game_result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 2,
		"home_score": 4,
	}
	var bases: Array = [setup.get("batters", [])[0], null, setup.get("batters", [])[1]]
	var changed: bool = PSBullpenManager.substitute_reliever_mid_inning(setup, 5, 1, bases, 4, game_result)
	var new_pitcher: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if not changed:
		failures.append("mid-inning reliever trigger did not change pitcher")
	elif new_pitcher == null or new_pitcher.player_id == starter.player_id:
		failures.append("mid-inning reliever trigger kept starter")
	if int(setup.get("starter_outs", -1)) != 1:
		failures.append("starter_outs=%d expected 1" % int(setup.get("starter_outs", -1)))
	if int(setup.get("starter_runs", -1)) != 4:
		failures.append("starter_runs=%d expected 4" % int(setup.get("starter_runs", -1)))
	print("[pitcher_outings] mid_inning_trigger changed=%s new=%d" % [str(changed), 0 if new_pitcher == null else new_pitcher.player_id])
	return failures


func _test_outing_decisions() -> Array:
	var failures: Array = []
	var result: Dictionary = {
		"winning_team_id": 1,
		"draw": false,
		"last_lead_change": {
			"event_index": 12,
			"winning_team_id": 1,
			"losing_team_id": 2,
			"losing_pitcher_id": 2201,
		},
		"pitcher_outings": [
			{"team_id": 1, "pitcher_id": 1101, "role": PSPitcherUsageModel.ROLE_STARTER, "start_event_index": 0, "end_event_index": 10, "outs": 18, "entry_lead": 0, "exit_lead": 0},
			{"team_id": 1, "pitcher_id": 1102, "role": PSPitcherUsageModel.ROLE_SHORT_RELIEF, "start_event_index": 11, "end_event_index": 18, "outs": 3, "entry_lead": 2, "exit_lead": 2},
			{"team_id": 1, "pitcher_id": 1103, "role": PSPitcherUsageModel.ROLE_SHORT_RELIEF, "start_event_index": 19, "end_event_index": 24, "outs": 3, "entry_lead": 2, "exit_lead": 2},
			{"team_id": 2, "pitcher_id": 2201, "role": PSPitcherUsageModel.ROLE_STARTER, "start_event_index": 0, "end_event_index": 14, "outs": 15, "entry_lead": 0, "exit_lead": -2},
		],
	}
	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 1101, 2201)
	if int(decisions.get("winning_pitcher_id", 0)) != 1101:
		failures.append("outing decision win=%d expected 1101" % int(decisions.get("winning_pitcher_id", 0)))
	if int(decisions.get("losing_pitcher_id", 0)) != 2201:
		failures.append("outing decision loss=%d expected 2201" % int(decisions.get("losing_pitcher_id", 0)))
	if int(decisions.get("save_pitcher_id", 0)) != 1103:
		failures.append("outing decision save=%d expected 1103" % int(decisions.get("save_pitcher_id", 0)))
	var holds: Array = decisions.get("hold_pitcher_ids", []) as Array
	if not holds.has(1102):
		failures.append("outing decision missing hold 1102: %s" % JSON.stringify(holds))
	print("[pitcher_outings] decisions=%s" % JSON.stringify(decisions))
	return failures


func _test_inherited_runner_charge() -> Array:
	var failures: Array = []
	var starter: PSPlayerSeasonRecord = _make_pitcher(9101)
	var reliever: PSPlayerSeasonRecord = _make_pitcher(9102)
	var runner: PSPlayerSeasonRecord = _make_runner(9201)
	var batter: PSPlayerSeasonRecord = _make_runner(9202)
	var defense: Dictionary = {
		"team_id": 1,
		"pitcher": reliever,
		"active_pitcher_outing_index": 1,
	}
	var result: Dictionary = {
		"pitcher_outings": [
			{"team_id": 1, "pitcher_id": starter.player_id, "role": PSPitcherUsageModel.ROLE_STARTER, "start_event_index": 0, "end_event_index": 4, "outs": 0, "runs": 0, "earned_runs": 0, "active": false},
			{"team_id": 1, "pitcher_id": reliever.player_id, "role": PSPitcherUsageModel.ROLE_SHORT_RELIEF, "start_event_index": 5, "end_event_index": 4, "outs": 0, "runs": 0, "earned_runs": 0, "inherited_runner_ids": [runner.player_id], "inherited_runners_scored": 0, "active": true},
		],
		"next_play_event_index": 6,
	}
	var responsibility: Dictionary = {
		str(runner.player_id): {
			"pitcher": starter,
			"pitcher_id": starter.player_id,
			"earned": true,
		},
	}
	var bases_before: Array = [null, null, runner]
	var earned_outcome: Dictionary = {"category": "hit", "bases": 1}
	var earned_charges: Array = PSGameLoop.run_charges_for_plate(batter, reliever, earned_outcome, bases_before, 1, responsibility)
	var earned_totals: Dictionary = PSGameLoop.charge_pitcher_run_charges(earned_charges, reliever, defense, result, 7, "top", 1)
	if starter.pitcher_stats.runs_allowed != 1 or starter.pitcher_stats.earned_runs != 1:
		failures.append("inherited earned charge starter RA/ER=%d/%d expected 1/1" % [starter.pitcher_stats.runs_allowed, starter.pitcher_stats.earned_runs])
	if reliever.pitcher_stats.runs_allowed != 0 or int(earned_totals.get("current_runs", -1)) != 0:
		failures.append("inherited earned charge reliever RA/current=%d/%d expected 0/0" % [reliever.pitcher_stats.runs_allowed, int(earned_totals.get("current_runs", -1))])
	var starter_outing: Dictionary = (result.get("pitcher_outings", []) as Array)[0] as Dictionary
	if int(starter_outing.get("runs", 0)) != 1 or int(starter_outing.get("earned_runs", 0)) != 1:
		failures.append("inherited earned outing=%s expected runs/ER 1/1" % JSON.stringify(starter_outing))

	var error_pitcher: PSPlayerSeasonRecord = _make_pitcher(9103)
	var error_runner: PSPlayerSeasonRecord = _make_runner(9203)
	var error_resp: Dictionary = {
		str(error_runner.player_id): {
			"pitcher": error_pitcher,
			"pitcher_id": error_pitcher.player_id,
			"earned": true,
		},
	}
	var error_result: Dictionary = {
		"pitcher_outings": [
			{"team_id": 1, "pitcher_id": error_pitcher.player_id, "role": PSPitcherUsageModel.ROLE_STARTER, "start_event_index": 0, "end_event_index": 0, "outs": 0, "runs": 0, "earned_runs": 0, "active": true},
		],
		"next_play_event_index": 1,
	}
	var error_defense: Dictionary = {
		"team_id": 1,
		"pitcher": error_pitcher,
		"active_pitcher_outing_index": 0,
	}
	var error_charges: Array = PSGameLoop.run_charges_for_plate(batter, error_pitcher, {"category": "error", "bases": 1}, [null, null, error_runner], 1, error_resp)
	var error_totals: Dictionary = PSGameLoop.charge_pitcher_run_charges(error_charges, error_pitcher, error_defense, error_result, 8, "bottom", 1)
	if error_pitcher.pitcher_stats.runs_allowed != 1 or error_pitcher.pitcher_stats.earned_runs != 0:
		failures.append("error charge pitcher RA/ER=%d/%d expected 1/0" % [error_pitcher.pitcher_stats.runs_allowed, error_pitcher.pitcher_stats.earned_runs])
	if int(error_totals.get("current_runs", 0)) != 1 or int(error_totals.get("current_earned_runs", -1)) != 0:
		failures.append("error charge totals=%s expected current 1/0" % JSON.stringify(error_totals))
	var go_ahead_pitcher_id: int = PSGameLoop.go_ahead_pitcher_id_for_charges(
		[
			{"pitcher": reliever, "earned": true},
			{"pitcher": starter, "earned": true},
		],
		{"away_score": 0, "home_score": 1},
		"top",
		0,
		2
	)
	if go_ahead_pitcher_id != starter.player_id:
		failures.append("go-ahead responsibility=%d expected %d" % [go_ahead_pitcher_id, starter.player_id])
	print("[pitcher_outings] inherited_runner_charge OK")
	return failures


func _test_earned_run_reconstruction() -> Array:
	var failures: Array = []
	var pitcher: PSPlayerSeasonRecord = _make_pitcher(9401)
	var runner: PSPlayerSeasonRecord = _make_runner(9402)
	var batter: PSPlayerSeasonRecord = _make_runner(9403)
	var defense: Dictionary = {
		"team_id": 1,
		"pitcher": pitcher,
		"active_pitcher_outing_index": 0,
	}
	var result: Dictionary = {
		"pitcher_outings": [
			{"team_id": 1, "pitcher_id": pitcher.player_id, "role": PSPitcherUsageModel.ROLE_STARTER, "start_event_index": 0, "end_event_index": 0, "outs": 0, "runs": 0, "earned_runs": 0, "active": true},
		],
		"next_play_event_index": 1,
	}

	var virtual_outs_after_error: int = PSGameLoop.advance_earned_outs_for_plate(2, {"category": "error", "bases": 1}, 0)
	if virtual_outs_after_error != 3:
		failures.append("earned virtual outs after error=%d expected 3" % virtual_outs_after_error)
	var post_error_hr_charges: Array = PSGameLoop.run_charges_for_plate(
		batter,
		pitcher,
		{"category": "hit", "bases": 4},
		[null, null, null],
		1,
		{},
		virtual_outs_after_error,
		0
	)
	var post_error_totals: Dictionary = PSGameLoop.charge_pitcher_run_charges(post_error_hr_charges, pitcher, defense, result, 8, "top", 1)
	if pitcher.pitcher_stats.runs_allowed != 1 or pitcher.pitcher_stats.earned_runs != 0:
		failures.append("post-error virtual-third HR RA/ER=%d/%d expected 1/0" % [pitcher.pitcher_stats.runs_allowed, pitcher.pitcher_stats.earned_runs])
	if int(post_error_totals.get("current_earned_runs", -1)) != 0:
		failures.append("post-error virtual-third totals=%s expected ER 0" % JSON.stringify(post_error_totals))

	var sac_pitcher: PSPlayerSeasonRecord = _make_pitcher(9404)
	var sac_runner: PSPlayerSeasonRecord = _make_runner(9405)
	var sac_resp: Dictionary = {
		str(sac_runner.player_id): {
			"pitcher": sac_pitcher,
			"pitcher_id": sac_pitcher.player_id,
			"earned": true,
		},
	}
	var sac_charges: Array = PSGameLoop.run_charges_for_plate(
		batter,
		sac_pitcher,
		{"category": "sacrifice_fly"},
		[null, null, sac_runner],
		1,
		sac_resp,
		2,
		1
	)
	var sac_totals: Dictionary = PSGameLoop.charge_pitcher_run_charges(sac_charges, sac_pitcher, defense, result, 8, "top", 2)
	if sac_pitcher.pitcher_stats.runs_allowed != 1 or sac_pitcher.pitcher_stats.earned_runs != 0:
		failures.append("virtual-third sacrifice RA/ER=%d/%d expected 1/0" % [sac_pitcher.pitcher_stats.runs_allowed, sac_pitcher.pitcher_stats.earned_runs])
	if int(sac_totals.get("total_earned_runs", -1)) != 0:
		failures.append("virtual-third sacrifice totals=%s expected ER 0" % JSON.stringify(sac_totals))

	var pb_pitcher: PSPlayerSeasonRecord = _make_pitcher(9406)
	var pb_runner: PSPlayerSeasonRecord = _make_runner(9407)
	var pb_resp: Dictionary = {
		str(pb_runner.player_id): {
			"pitcher": pb_pitcher,
			"pitcher_id": pb_pitcher.player_id,
			"earned": true,
		},
	}
	PSGameLoop.mark_unearned_runner_event_advances(pb_resp, [{
		"runner_id": pb_runner.player_id,
		"from_base": 2,
		"to_base": 3,
		"result": "passed_ball",
		"is_passed_ball": true,
		"outs_added": 0,
	}])
	var pb_charges: Array = PSGameLoop.run_charges_for_plate(
		batter,
		pb_pitcher,
		{"category": "hit", "bases": 1},
		[null, null, pb_runner],
		1,
		pb_resp,
		0,
		0
	)
	var pb_totals: Dictionary = PSGameLoop.charge_pitcher_run_charges(pb_charges, pb_pitcher, defense, result, 8, "top", 3)
	if pb_pitcher.pitcher_stats.runs_allowed != 1 or pb_pitcher.pitcher_stats.earned_runs != 0:
		failures.append("passed-ball advanced runner RA/ER=%d/%d expected 1/0" % [pb_pitcher.pitcher_stats.runs_allowed, pb_pitcher.pitcher_stats.earned_runs])
	if int(pb_totals.get("total_earned_runs", -1)) != 0:
		failures.append("passed-ball advanced runner totals=%s expected ER 0" % JSON.stringify(pb_totals))

	print("[pitcher_outings] earned_run_reconstruction OK")
	return failures


func _test_pitcher_fatigue_availability() -> Array:
	var failures: Array = []
	var reliever: PSPlayerSeasonRecord = _make_pitcher(9301)
	reliever.role = "reliever"
	reliever.last_pitched_team_game = 10
	reliever.consecutive_appearances = 2
	if PSPitcherUsageModel.is_reliever_available(reliever, false, 20, 10):
		failures.append("third straight reliever available in normal tier")
	if not PSPitcherUsageModel.is_reliever_available(reliever, true, 20, 10):
		failures.append("third straight reliever unavailable in emergency tier")
	var rested_score: float = PSPitcherUsageModel.reliever_selection_score(reliever, false, 8, true, 20, 12)
	var third_straight_score: float = PSPitcherUsageModel.reliever_selection_score(reliever, false, 8, true, 20, 10)
	if third_straight_score > rested_score - 100.0:
		failures.append("third straight penalty too small: rested=%.1f third=%.1f" % [rested_score, third_straight_score])

	var returning: PSPlayerSeasonRecord = _make_pitcher(9302)
	returning.role = "reliever"
	returning.injury_return_day = 20
	if PSPitcherUsageModel.is_reliever_available(returning, true, 21, 10):
		failures.append("injury return hard rest pitcher available")
	if PSPitcherUsageModel.is_reliever_available(returning, false, 23, 10):
		failures.append("injury return soft rest pitcher available in normal tier")
	if not PSPitcherUsageModel.is_reliever_available(returning, true, 23, 10):
		failures.append("injury return soft rest pitcher unavailable in emergency tier")
	if not PSPitcherUsageModel.is_reliever_available(returning, false, 24, 10):
		failures.append("injury return pitcher unavailable after soft rest")

	var exhausted: PSPlayerSeasonRecord = _make_pitcher(9303)
	exhausted.role = "reliever"
	exhausted.fatigue = PSPitcherUsageModel.RELIEVER_EMERGENCY_FATIGUE_LIMIT
	if PSPitcherUsageModel.is_reliever_available(exhausted, true, 24, 10):
		failures.append("emergency fatigue limit pitcher available")

	var usage: Dictionary = PSPitcherUsageModel.create_outing(reliever, PSPitcherUsageModel.ROLE_SHORT_RELIEF)
	usage["pitches"] = 30
	usage["outs"] = 6
	usage["consecutive_count"] = 2
	var gain: int = PSPitcherUsageModel.post_game_fatigue_gain(reliever, usage)
	if gain < 50:
		failures.append("short relief fatigue gain too low for third-straight multi-inning: %d" % gain)
	print("[pitcher_outings] fatigue_availability OK gain=%d" % gain)
	return failures


func _make_pitcher(player_id: int) -> PSPlayerSeasonRecord:
	var record := PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = 1
	record.role = "starter"
	return record


func _make_runner(player_id: int) -> PSPlayerSeasonRecord:
	var record := PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = 7
	record.role = "fielder"
	return record
