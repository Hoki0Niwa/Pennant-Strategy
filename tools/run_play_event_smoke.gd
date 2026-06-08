extends Node

const AdvancedStatReducer = preload("res://services/simulation/reducers/advanced_stat_reducer.gd")
const BaseStateResolver = preload("res://services/simulation/reducers/base_state_resolver.gd")
const FieldingModel = preload("res://services/simulation/models/fielding_model.gd")
const PlateEventReducer = preload("res://services/simulation/reducers/plate_event_reducer.gd")
const PlayResolver = preload("res://services/simulation/pa/play_resolver.gd")
const MAX_GAMES: int = 120


func _ready() -> void:
	var seed: int = 12345
	Rng.set_seed_value(seed)
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var bench_start_msec: int = Time.get_ticks_msec()
	var games: int = 0
	var play_events: int = 0
	var batted_ball_events: int = 0
	var invalid_batted_ball_events: int = 0
	var barrels: int = 0
	var hard_hits: int = 0
	var home_run_batted_balls: int = 0
	var home_run_barrels: int = 0
	var advanced_player_records: int = 0
	var advanced_pitcher_records: int = 0
	var advanced_fielding_records: int = 0
	var invalid_advanced_fielding_records: int = 0
	var runner_intents: int = 0
	var runner_events: int = 0
	var fielding_events: int = 0
	var invalid_fielding_events: int = 0
	var recorded_steal_attempts: int = 0
	var obscured_steal_intents: int = 0
	var total_pitches: int = 0
	var pitch_mismatches: int = 0
	var woba_formula_ok: bool = AdvancedStatReducer.smoke_test_woba_formula()
	var fielding_gap: Dictionary = FieldingModel.smoke_test_fielding_ability_gap()
	var fielders_choice_home_throw: Dictionary = _smoke_test_fielders_choice_home_throw()
	var infield_throw_beat: Dictionary = PlayResolver.smoke_test_infield_throw_beat_probability()
	var groundout_advancement: Dictionary = PlayResolver.smoke_test_groundout_runner_advancement_probabilities()
	var groundout_advancement_plan: Dictionary = _smoke_test_groundout_advancement_plan()
	var fielding_event_metric_consistency: Dictionary = _smoke_test_fielding_event_metric_consistency()
	var runner_fielding_error_metrics_ok: bool = AdvancedStatReducer.smoke_test_runner_fielding_error_metrics()
	var runner_event_results: Dictionary = {}
	var runner_event_strategies: Dictionary = {}
	while games < MAX_GAMES:
		var simulation: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
		if not bool(simulation.get("ok", false)):
			break
		games += 1
		var game_result: Dictionary = simulation.get("result", {}) as Dictionary
		var events: Array = game_result.get("play_events", []) as Array
		var advanced_stats: Dictionary = game_result.get("advanced_stats", {}) as Dictionary
		advanced_player_records += (advanced_stats.get("players", {}) as Dictionary).size()
		advanced_pitcher_records += (advanced_stats.get("pitchers", {}) as Dictionary).size()
		for advanced_record_value in (advanced_stats.get("players", {}) as Dictionary).values():
			var advanced_record: Dictionary = advanced_record_value as Dictionary
			if int(advanced_record.get("fielding_chances", 0)) > 0:
				advanced_fielding_records += 1
				if not _advanced_fielding_record_is_valid(advanced_record):
					invalid_advanced_fielding_records += 1
		play_events += events.size()
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			var pitch_summary: Dictionary = event.get("pitch_summary", {}) as Dictionary
			var pitches: int = int(pitch_summary.get("pitches", 0))
			var plate_event: Dictionary = event.get("plate_event", {}) as Dictionary
			total_pitches += pitches
			if not plate_event.is_empty() and (pitches <= 0 or int(plate_event.get("pitches", 0)) != pitches):
				pitch_mismatches += 1
			if plate_event.is_empty() and not pitch_summary.is_empty():
				pitch_mismatches += 1
			var batted_ball_event: Dictionary = event.get("batted_ball_event", {}) as Dictionary
			if not batted_ball_event.is_empty():
				batted_ball_events += 1
				var exit_velocity: float = float(batted_ball_event.get("exit_velocity", 0.0))
				var actual_result: String = str(batted_ball_event.get("actual_result", ""))
				var requires_physics: bool = not actual_result.contains("bunt")
				if requires_physics and (exit_velocity <= 0.0 or not batted_ball_event.has("launch_angle")):
					invalid_batted_ball_events += 1
				if bool(batted_ball_event.get("is_barrel", false)):
					barrels += 1
				if bool(batted_ball_event.get("is_hard_hit", false)):
					hard_hits += 1
				if str(batted_ball_event.get("actual_result", "")).contains("home_run"):
					home_run_batted_balls += 1
					if bool(batted_ball_event.get("is_barrel", false)):
						home_run_barrels += 1
			var official_runner_events: Array = event.get("runner_events", []) as Array
			runner_events += official_runner_events.size()
			for runner_event_value in official_runner_events:
				var runner_event: Dictionary = runner_event_value as Dictionary
				var result_key: String = str(runner_event.get("result", ""))
				var strategy_key: String = str(runner_event.get("strategy", result_key))
				runner_event_results[result_key] = int(runner_event_results.get(result_key, 0)) + 1
				runner_event_strategies[strategy_key] = int(runner_event_strategies.get(strategy_key, 0)) + 1
				if bool(runner_event.get("is_steal_attempt", false)):
					recorded_steal_attempts += 1
			var intents: Array = event.get("runner_intents", []) as Array
			runner_intents += intents.size()
			for intent_value in intents:
				var intent: Dictionary = intent_value as Dictionary
				if bool(intent.get("obscured_by_batted_ball", false)):
					obscured_steal_intents += 1
			var official_fielding_events: Array = event.get("fielding_events", []) as Array
			fielding_events += official_fielding_events.size()
			for fielding_event_value in official_fielding_events:
				var fielding_event: Dictionary = fielding_event_value as Dictionary
				if int(fielding_event.get("fielder_id", 0)) == 0:
					invalid_fielding_events += 1
				if (
					not fielding_event.has("oaa")
					or not fielding_event.has("oaa_zone")
					or not fielding_event.has("rngr")
					or not fielding_event.has("errr")
					or not fielding_event.has("dpr")
					or not fielding_event.has("uzr")
					or not fielding_event.has("uzr_position")
					or not fielding_event.has("drs")
					or not fielding_event.has("fielding_outs")
					or not fielding_event.has("runner_outs")
					or not fielding_event.has("batter_out")
					or not fielding_event.has("fielding_result")
					or not fielding_event.has("play_kind")
				):
					invalid_fielding_events += 1
		if obscured_steal_intents > 0 and total_pitches > 0 and runner_events > 0 and recorded_steal_attempts > 0 and home_run_batted_balls > 0 and fielding_events > 0:
			break

	var stats_pitches_seen: int = 0
	var stats_pitches_thrown: int = 0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null or record.year != season.year or record.season_number != season.season_number:
			continue
		stats_pitches_seen += record.batter_stats.pitches_seen
		stats_pitches_thrown += record.pitcher_stats.pitches_thrown

	var bench_elapsed_msec: int = Time.get_ticks_msec() - bench_start_msec
	var msec_per_game: float = 0.0 if games == 0 else float(bench_elapsed_msec) / float(games)
	print("Play event smoke bench: games=%d elapsed_ms=%d msec_per_game=%.1f" % [
		games,
		bench_elapsed_msec,
		msec_per_game,
	])
	var pitches_per_play: float = 0.0 if play_events == 0 else float(total_pitches) / float(play_events)
	var barrel_rate: float = 0.0 if batted_ball_events == 0 else float(barrels) / float(batted_ball_events)
	var hard_hit_rate: float = 0.0 if batted_ball_events == 0 else float(hard_hits) / float(batted_ball_events)
	var home_run_barrel_rate: float = 0.0 if home_run_batted_balls == 0 else float(home_run_barrels) / float(home_run_batted_balls)
	print("Play event smoke: games=%d play_events=%d batted_balls=%d invalid_batted_balls=%d barrels=%d barrel_rate=%.3f hard_hits=%d hard_hit_rate=%.3f home_runs=%d home_run_barrel_rate=%.3f advanced_players=%d advanced_pitchers=%d advanced_fielders=%d invalid_advanced_fielders=%d runner_intents=%d runner_events=%d fielding_events=%d invalid_fielding_events=%d steal_attempts=%d obscured_steal_intents=%d total_pitches=%d pitches_seen=%d pitches_thrown=%d pitch_mismatches=%d pitches_per_play=%.2f woba_formula_ok=%s fielding_gap=%.3f" % [
		games,
		play_events,
		batted_ball_events,
		invalid_batted_ball_events,
		barrels,
		barrel_rate,
		hard_hits,
		hard_hit_rate,
		home_run_batted_balls,
		home_run_barrel_rate,
		advanced_player_records,
		advanced_pitcher_records,
		advanced_fielding_records,
		invalid_advanced_fielding_records,
		runner_intents,
		runner_events,
		fielding_events,
		invalid_fielding_events,
		recorded_steal_attempts,
		obscured_steal_intents,
		total_pitches,
		stats_pitches_seen,
		stats_pitches_thrown,
		pitch_mismatches,
		pitches_per_play,
		str(woba_formula_ok),
		float(fielding_gap.get("gap", 0.0)),
	])
	print("Runner event results: %s" % JSON.stringify(runner_event_results))
	print("Runner event strategies: %s" % JSON.stringify(runner_event_strategies))
	print("Fielders choice home throw smoke: %s" % JSON.stringify(fielders_choice_home_throw))
	print("Infield throw beat smoke: %s" % JSON.stringify(infield_throw_beat))
	print("Groundout advancement smoke: %s" % JSON.stringify(groundout_advancement))
	print("Groundout advancement plan smoke: %s" % JSON.stringify(groundout_advancement_plan))
	print("Fielding event metric consistency smoke: %s" % JSON.stringify(fielding_event_metric_consistency))
	print("Runner fielding error metrics smoke: %s" % str(runner_fielding_error_metrics_ok))
	var ok: bool = (
		games > 0
		and play_events > 0
		and batted_ball_events > 0
		and invalid_batted_ball_events == 0
		and home_run_batted_balls > 0
		and advanced_player_records > 0
		and advanced_pitcher_records > 0
		and advanced_fielding_records > 0
		and invalid_advanced_fielding_records == 0
		and runner_events > 0
		and fielding_events > 0
		and invalid_fielding_events == 0
		and recorded_steal_attempts > 0
		and obscured_steal_intents > 0
		and total_pitches > 0
		and pitch_mismatches == 0
		and woba_formula_ok
		and bool(fielding_gap.get("ok", false))
		and bool(fielders_choice_home_throw.get("ok", false))
		and bool(infield_throw_beat.get("ok", false))
		and bool(groundout_advancement.get("ok", false))
		and bool(groundout_advancement_plan.get("ok", false))
		and bool(fielding_event_metric_consistency.get("ok", false))
		and runner_fielding_error_metrics_ok
		and stats_pitches_seen == total_pitches
		and stats_pitches_thrown == total_pitches
	)
	get_tree().quit(0 if ok else 1)


func _smoke_test_groundout_advancement_plan() -> Dictionary:
	var batter: PSPlayerSeasonRecord = _smoke_record(-940010, 0)
	var runner_second: PSPlayerSeasonRecord = _smoke_record(-940011, 0)
	var runner_third: PSPlayerSeasonRecord = _smoke_record(-940012, 0)
	var bases: Array = [null, runner_second, runner_third]
	var outcome: Dictionary = {
		"result": "groundout_second_base",
		"category": "out",
		"bases": 0,
		"fielder_position": 4,
		"runner_strategy": "groundout_advance",
		"runner_advancements": [
			{
				"runner": runner_third,
				"runner_id": runner_third.player_id,
				"from_base": 3,
				"to_base": 4,
				"baseline_to": 3,
				"is_out": false,
				"is_extra": true,
			},
			{
				"runner": runner_second,
				"runner_id": runner_second.player_id,
				"from_base": 2,
				"to_base": 3,
				"baseline_to": 2,
				"is_out": false,
				"is_extra": true,
			},
		],
		"runner_events": [
			{
				"event_type": "runner_event",
				"phase": "after_batted_ball",
				"strategy": "groundout_advance",
				"result": "groundout_advance",
				"runner_id": runner_third.player_id,
				"from_base": 3,
				"to_base": 4,
				"state_already_applied": true,
				"batter_rbi": true,
			},
			{
				"event_type": "runner_event",
				"phase": "after_batted_ball",
				"strategy": "groundout_advance",
				"result": "groundout_advance",
				"runner_id": runner_second.player_id,
				"from_base": 2,
				"to_base": 3,
				"state_already_applied": true,
				"batter_rbi": false,
			},
		],
	}
	var applied: Dictionary = PlateEventReducer.apply_plate_outcome(batter, null, bases, 0, outcome)
	var events: Array = outcome.get("runner_events", []) as Array
	var ok: bool = (
		int(applied.get("runs", -1)) == 1
		and int(applied.get("outs", -1)) == 1
		and bases[0] == null
		and bases[1] == null
		and bases[2] == runner_second
		and batter.batter_stats.runs_batted_in == 1
		and events.size() == 2
	)
	return {
		"ok": ok,
		"runs": int(applied.get("runs", -1)),
		"outs": int(applied.get("outs", -1)),
		"runner_on_third": 0 if bases[2] == null else (bases[2] as PSPlayerSeasonRecord).player_id,
		"batter_rbi": batter.batter_stats.runs_batted_in,
		"events": events.size(),
	}


func _smoke_test_fielders_choice_home_throw() -> Dictionary:
	var batter_safe: PSPlayerSeasonRecord = _smoke_record(-920001, 0)
	var runner_safe: PSPlayerSeasonRecord = _smoke_record(-920002, 0)
	var bases_safe: Array = [null, null, runner_safe]
	var safe_outcome: Dictionary = {
		"result": "ground_home_throw_third_base_safe",
		"category": "fielders_choice",
		"bases": 1,
		"fielder_position": 5,
		"catch_attempt_position": 5,
		"fielders_choice_outs": 0,
		"runner_advancements": [{
			"runner": runner_safe,
			"runner_id": runner_safe.player_id,
			"from_base": 3,
			"to_base": 4,
			"baseline_to": 3,
			"is_out": false,
			"is_extra": true,
		}],
	}
	var safe_result: Dictionary = BaseStateResolver.advance_fielders_choice(batter_safe, bases_safe, safe_outcome)

	var batter_out: PSPlayerSeasonRecord = _smoke_record(-920003, 0)
	var runner_out: PSPlayerSeasonRecord = _smoke_record(-920004, 0)
	var bases_out: Array = [null, null, runner_out]
	var out_outcome: Dictionary = safe_outcome.duplicate(true)
	out_outcome["result"] = "ground_home_throw_third_base_out"
	out_outcome["fielders_choice_outs"] = 1
	out_outcome["runner_advancements"] = [{
		"runner": runner_out,
		"runner_id": runner_out.player_id,
		"from_base": 3,
		"to_base": 4,
		"baseline_to": 3,
		"is_out": true,
		"is_extra": true,
	}]
	var out_result: Dictionary = BaseStateResolver.advance_fielders_choice(batter_out, bases_out, out_outcome)

	var fielder: PSPlayerSeasonRecord = _smoke_record(-920005, 5)
	var batted_ball_event: Dictionary = {
		"fielder_position": 5,
		"field_zone": "infield",
		"zone_bucket": "pos_5_ground",
		"batted_ball_type": "grounder",
		"trajectory_bucket": "medium_grounder",
		"exit_velocity": 88.0,
		"launch_angle": -10.0,
		"distance": 28.0,
		"actual_result": "ground_home_throw_third_base_safe",
	}
	safe_outcome["catch_probability_neutral"] = 0.60
	out_outcome["catch_probability_neutral"] = 0.60
	var defense: Dictionary = {"fielders": [{"record": fielder, "position": 5}]}
	var safe_fielding_events: Array = FieldingModel.fielding_events_for_play(1, defense, safe_outcome, batted_ball_event)
	batted_ball_event["actual_result"] = "ground_home_throw_third_base_out"
	var out_fielding_events: Array = FieldingModel.fielding_events_for_play(2, defense, out_outcome, batted_ball_event)
	var safe_actual_out: bool = true
	if not safe_fielding_events.is_empty():
		safe_actual_out = bool((safe_fielding_events[0] as Dictionary).get("actual_out", true))
	var out_actual_out: bool = false
	if not out_fielding_events.is_empty():
		out_actual_out = bool((out_fielding_events[0] as Dictionary).get("actual_out", false))

	var ok: bool = (
		int(safe_result.get("runs", 0)) == 1
		and int(safe_result.get("outs", -1)) == 0
		and bases_safe[0] == batter_safe
		and bases_safe[2] == null
		and int(out_result.get("runs", -1)) == 0
		and int(out_result.get("outs", 0)) == 1
		and bases_out[0] == batter_out
		and not safe_fielding_events.is_empty()
		and not out_fielding_events.is_empty()
		and not safe_actual_out
		and out_actual_out
	)
	return {
		"ok": ok,
		"safe_runs": int(safe_result.get("runs", -1)),
		"safe_outs": int(safe_result.get("outs", -1)),
		"out_runs": int(out_result.get("runs", -1)),
		"out_outs": int(out_result.get("outs", -1)),
		"safe_actual_out": safe_actual_out,
		"out_actual_out": out_actual_out,
	}


func _smoke_test_fielding_event_metric_consistency() -> Dictionary:
	var fielder: PSPlayerSeasonRecord = _smoke_record(-950001, 6)
	var defense: Dictionary = {"fielders": [{"record": fielder, "position": 6}]}
	var batted_ball_event: Dictionary = {
		"fielder_position": 6,
		"field_zone": "infield",
		"zone_bucket": "pos_6_ground",
		"batted_ball_type": "grounder",
		"trajectory_bucket": "medium_grounder",
		"exit_velocity": 86.0,
		"launch_angle": -12.0,
		"distance": 32.0,
		"actual_result": "groundout_shortstop",
	}
	var force_outcome: Dictionary = {
		"result": "ground_fielders_choice_shortstop",
		"category": "fielders_choice",
		"bases": 1,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.62,
		"force_out_from_base": 1,
		"force_out_to_base": 2,
		"runner_advancements": [{
			"from_base": 1,
			"to_base": 2,
			"is_out": true,
		}],
	}
	var safe_home_outcome: Dictionary = {
		"result": "ground_home_throw_shortstop_safe",
		"category": "fielders_choice",
		"bases": 1,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.62,
		"fielders_choice_outs": 0,
		"runner_advancements": [{
			"from_base": 3,
			"to_base": 4,
			"is_out": false,
			"is_extra": true,
		}],
	}
	var double_play_outcome: Dictionary = {
		"result": "double_play_shortstop",
		"category": "double_play",
		"bases": 0,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.62,
		"double_play_opportunity": true,
		"double_play_probability": 0.40,
	}
	var groundout_advance_outcome: Dictionary = {
		"result": "groundout_shortstop",
		"category": "out",
		"bases": 0,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.62,
		"runner_strategy": "groundout_advance",
		"runner_advancements": [{
			"from_base": 2,
			"to_base": 3,
			"is_out": false,
			"is_extra": true,
		}],
	}
	var force_event: Dictionary = _first_fielding_event(defense, force_outcome, batted_ball_event)
	batted_ball_event["actual_result"] = "ground_home_throw_shortstop_safe"
	var safe_home_event: Dictionary = _first_fielding_event(defense, safe_home_outcome, batted_ball_event)
	batted_ball_event["actual_result"] = "double_play_shortstop"
	var double_play_event: Dictionary = _first_fielding_event(defense, double_play_outcome, batted_ball_event)
	batted_ball_event["actual_result"] = "groundout_shortstop"
	var groundout_event: Dictionary = _first_fielding_event(defense, groundout_advance_outcome, batted_ball_event)

	var stats: Dictionary = AdvancedStatReducer.empty_advanced_stats()
	AdvancedStatReducer.apply_play_event(stats, {
		"fielding_events": [double_play_event],
		"runner_events": [],
	})
	var player_records: Dictionary = stats.get("players", {}) as Dictionary
	var advanced_record: Dictionary = player_records.get(str(fielder.player_id), {}) as Dictionary
	var outs_by_position: Dictionary = advanced_record.get("fielding_outs_by_position", {}) as Dictionary
	var outs_by_zone: Dictionary = advanced_record.get("fielding_outs_by_oaa_zone", {}) as Dictionary

	var ok: bool = (
		not force_event.is_empty()
		and int(force_event.get("fielding_outs", -1)) == 1
		and int(force_event.get("runner_outs", -1)) == 1
		and not bool(force_event.get("batter_out", true))
		and str(force_event.get("fielding_result", "")) == "force_out"
		and str(force_event.get("play_kind", "")) == "fielders_choice"
		and not safe_home_event.is_empty()
		and int(safe_home_event.get("fielding_outs", -1)) == 0
		and not bool(safe_home_event.get("actual_out", true))
		and str(safe_home_event.get("fielding_result", "")) == "home_throw_safe"
		and str(safe_home_event.get("play_kind", "")) == "home_throw"
		and not double_play_event.is_empty()
		and int(double_play_event.get("fielding_outs", -1)) == 2
		and int(double_play_event.get("runner_outs", -1)) == 1
		and bool(double_play_event.get("batter_out", false))
		and str(double_play_event.get("fielding_result", "")) == "double_play"
		and float(double_play_event.get("dpr", 0.0)) > 0.0
		and not groundout_event.is_empty()
		and int(groundout_event.get("fielding_outs", -1)) == 1
		and int(groundout_event.get("runner_outs", -1)) == 0
		and bool(groundout_event.get("batter_out", false))
		and str(groundout_event.get("fielding_result", "")) == "groundout_advance"
		and str(groundout_event.get("play_kind", "")) == "groundout_advance"
		and int(advanced_record.get("fielding_chances", 0)) == 1
		and int(advanced_record.get("fielding_outs", 0)) == 2
		and int(outs_by_position.get("6", 0)) == 2
		and int(outs_by_zone.get("infield", 0)) == 2
	)
	return {
		"ok": ok,
		"force_outs": int(force_event.get("fielding_outs", -1)),
		"safe_home_outs": int(safe_home_event.get("fielding_outs", -1)),
		"double_play_outs": int(double_play_event.get("fielding_outs", -1)),
		"groundout_outs": int(groundout_event.get("fielding_outs", -1)),
		"advanced_fielding_outs": int(advanced_record.get("fielding_outs", -1)),
	}


func _first_fielding_event(defense: Dictionary, outcome: Dictionary, batted_ball_event: Dictionary) -> Dictionary:
	var events: Array = FieldingModel.fielding_events_for_play(990001, defense, outcome, batted_ball_event)
	if events.is_empty():
		return {}
	return events[0] as Dictionary


func _smoke_record(player_id: int, position: int) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = position
	record.role = "fielder"
	return record


func _advanced_fielding_record_is_valid(record: Dictionary) -> bool:
	var required_keys: Array = [
		"fielding_outs",
		"fielding_chances_by_position",
		"fielding_chances_by_oaa_zone",
		"fielding_outs_by_position",
		"fielding_outs_by_oaa_zone",
		"defensive_outs_by_position",
		"defensive_outs_by_oaa_zone",
		"primary_uzr_position",
		"primary_oaa_zone",
		"oaa_by_zone",
		"oaa_infield",
		"oaa_outfield",
		"rngr_by_position",
		"errr_by_position",
		"dpr_by_position",
		"uzr_by_position",
		"drs_by_position",
		"fielding_runs",
		"positional_adjustment_runs",
		"def_runs",
	]
	for key in required_keys:
		if not record.has(key):
			return false

	var oaa_by_zone: Dictionary = record.get("oaa_by_zone", {}) as Dictionary
	for key_value in oaa_by_zone.keys():
		var zone_key: String = str(key_value)
		if zone_key != "infield" and zone_key != "outfield":
			return false

	var primary_oaa_zone: String = str(record.get("primary_oaa_zone", ""))
	if not primary_oaa_zone.is_empty():
		if primary_oaa_zone != "infield" and primary_oaa_zone != "outfield":
			return false
		if not _float_close(float(record.get("oaa", 0.0)), float(oaa_by_zone.get(primary_oaa_zone, 0.0)), 0.01):
			return false

	var primary_position: int = int(record.get("primary_uzr_position", 0))
	if primary_position <= 0:
		return false
	var position_key: String = str(primary_position)
	var rngr_by_position: Dictionary = record.get("rngr_by_position", {}) as Dictionary
	var errr_by_position: Dictionary = record.get("errr_by_position", {}) as Dictionary
	var dpr_by_position: Dictionary = record.get("dpr_by_position", {}) as Dictionary
	var uzr_by_position: Dictionary = record.get("uzr_by_position", {}) as Dictionary
	var component_uzr: float = (
		float(rngr_by_position.get(position_key, 0.0))
		+ float(errr_by_position.get(position_key, 0.0))
		+ float(dpr_by_position.get(position_key, 0.0))
	)
	if not _float_close(float(record.get("uzr", 0.0)), component_uzr, 0.01):
		return false
	if uzr_by_position.has(position_key) and not _float_close(float(uzr_by_position.get(position_key, 0.0)), component_uzr, 0.01):
		return false

	return true


func _float_close(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance
