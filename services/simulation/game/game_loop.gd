extends RefCounted
class_name PSGameLoop


# max_innings は延長の上限。既定は一軍の 12 回で、二軍 (ファーム) だけ 10 回で打ち切る。
# lightweight は成績・投手責任・怪我・高度指標を維持し、表示用の詳細プレーだけを保持しない。
# 各 play_event は生成直後に reducer へ流して破棄するため、OAA / wRAA 等を残したまま
# play_events・lineups・substitutions のメモリ/シリアライズ負荷を避けられる。
static func simulate_game(
	away_setup: Dictionary,
	home_setup: Dictionary,
	rule_groups: Array[Dictionary] = [],
	max_innings: int = GameSimulator.MAX_INNINGS,
	lightweight: bool = false
) -> Dictionary:
	var away_pitcher: PSPlayerSeasonRecord = away_setup["pitcher"] as PSPlayerSeasonRecord
	var home_pitcher: PSPlayerSeasonRecord = home_setup["pitcher"] as PSPlayerSeasonRecord
	var pa_cache: Dictionary = PSPlateAppearanceCoordinator.create_game_cache(rule_groups)
	var result: Dictionary = {
		"away_team_id": int(away_setup.get("team_id", 0)),
		"home_team_id": int(home_setup.get("team_id", 0)),
		"away_score": 0,
		"home_score": 0,
		"innings": [],
		"draw": false,
		"winning_team_id": 0,
		"losing_team_id": 0,
		"away_pitcher_id": away_pitcher.player_id,
		"home_pitcher_id": home_pitcher.player_id,
		"pitcher_outings": [],
		"injury_events": [],
		"next_play_event_index": 0,
		"walkoff": false,
		"advanced_stats": PSAdvancedStatReducer.empty_advanced_stats(),
	}
	if lightweight:
		result["_lightweight"] = true
	else:
		result["play_events"] = []
		result["substitutions"] = []

	PSBullpenManager.mark_games_started(away_setup)
	PSBullpenManager.mark_games_started(home_setup)
	if not lightweight:
		result["lineups"] = {
			"away": _capture_lineup(away_setup),
			"home": _capture_lineup(home_setup),
		}

	var inning: int = 1
	while inning <= max_innings:
		var home_team_id: int = int(home_setup.get("team_id", 0))
		_log_defensive_subs(result, PSInGameSubstitutions.apply_pending_defensive_subs(home_setup), inning, "top", home_team_id)
		_log_defensive_subs(result, PSInGameSubstitutions.maybe_apply_defensive_replacements(home_setup, inning, "top", result), inning, "top", home_team_id)
		var home_prev_pitcher_id: int = int((home_setup["pitcher"] as PSPlayerSeasonRecord).player_id)
		PSBullpenManager.substitute_reliever(home_setup, inning, result)
		var home_inning_pitcher_id: int = int((home_setup["pitcher"] as PSPlayerSeasonRecord).player_id)
		_record_substitution(result, inning, "top", home_team_id, "pitching", home_prev_pitcher_id, home_inning_pitcher_id, 1, -1)
		var away_runs: int = simulate_half_inning(away_setup, home_setup, inning, result, inning, "top", 0, pa_cache)
		result["away_score"] = int(result["away_score"]) + away_runs

		var home_runs: int = 0
		var away_inning_pitcher_id: int = 0
		var skip_home_half: bool = inning >= GameSimulator.REGULATION_INNINGS and int(result["home_score"]) > int(result["away_score"])
		if not skip_home_half:
			var away_team_id_sub: int = int(away_setup.get("team_id", 0))
			_log_defensive_subs(result, PSInGameSubstitutions.apply_pending_defensive_subs(away_setup), inning, "bottom", away_team_id_sub)
			_log_defensive_subs(result, PSInGameSubstitutions.maybe_apply_defensive_replacements(away_setup, inning, "bottom", result), inning, "bottom", away_team_id_sub)
			var away_prev_pitcher_id: int = int((away_setup["pitcher"] as PSPlayerSeasonRecord).player_id)
			PSBullpenManager.substitute_reliever(away_setup, inning, result)
			away_inning_pitcher_id = int((away_setup["pitcher"] as PSPlayerSeasonRecord).player_id)
			_record_substitution(result, inning, "bottom", away_team_id_sub, "pitching", away_prev_pitcher_id, away_inning_pitcher_id, 1, -1)
			var home_run_limit: int = bottom_half_walkoff_run_limit(result, inning)
			home_runs = simulate_half_inning(
				home_setup,
				away_setup,
				inning + 1,
				result,
				inning,
				"bottom",
				home_run_limit,
				pa_cache
			)
			result["home_score"] = int(result["home_score"]) + home_runs
			if inning >= GameSimulator.REGULATION_INNINGS and int(result["home_score"]) > int(result["away_score"]):
				result["walkoff"] = true

		var innings: Array = result["innings"] as Array
		innings.append({
			"inning": inning,
			"away": away_runs,
			"home": home_runs,
			"home_half_played": not skip_home_half,
			"home_team_pitcher_id": home_inning_pitcher_id,
			"away_team_pitcher_id": away_inning_pitcher_id,
		})

		if inning >= GameSimulator.REGULATION_INNINGS and int(result["away_score"]) != int(result["home_score"]):
			break
		inning += 1

	if int(result["away_score"]) == int(result["home_score"]):
		result["draw"] = true
	else:
		var away_team_id: int = int(away_setup.get("team_id", 0))
		var home_team_id: int = int(home_setup.get("team_id", 0))
		if int(result["away_score"]) > int(result["home_score"]):
			result["winning_team_id"] = away_team_id
			result["losing_team_id"] = home_team_id
		else:
			result["winning_team_id"] = home_team_id
			result["losing_team_id"] = away_team_id

	finish_active_pitcher_outing(away_setup, result, inning, "game_end", 0)
	finish_active_pitcher_outing(home_setup, result, inning, "game_end", 0)
	PSGameDecisions.finalize_pitcher_stats(away_setup, result)
	PSGameDecisions.finalize_pitcher_stats(home_setup, result)
	PSBullpenManager.finalize_pitcher_usage(away_setup)
	PSBullpenManager.finalize_pitcher_usage(home_setup)
	_collect_injury_events(result, away_setup)
	_collect_injury_events(result, home_setup)
	result["advanced_stats"] = PSAdvancedStatReducer.to_dict_container(result.get("advanced_stats", {}) as Dictionary)
	if lightweight:
		result.erase("_lightweight")
	return result


# 試合開始時の先発オーダー(打順スロット+守備位置)を捕捉。ボックススコアの行構成に使う。
static func _capture_lineup(setup: Dictionary) -> Dictionary:
	var pitcher: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	var dh: bool = bool(setup.get("dh_enabled", false))
	var lineup: Dictionary = PSTeamSetupBuilder.setup_to_lineup_dict(setup, dh, pitcher)
	return {
		"team_id": int(setup.get("team_id", 0)),
		"dh": dh,
		"slots": lineup.get("batting_order", []),
	}


static func _collect_injury_events(result: Dictionary, setup: Dictionary) -> void:
	var collected: Array = PSScoringHelpers.drain_injury_events(setup)
	if collected.is_empty():
		return
	var events: Array = result.get("injury_events", []) as Array
	for event_value in collected:
		events.append(event_value)
	result["injury_events"] = events


# 交代ログ。result["substitutions"] に 1 件追記する (out_id==in_id は無視)。
static func _record_substitution(result: Dictionary, inning: int, half: String, team_id: int, kind: String, out_id: int, in_id: int, position: int, slot: int) -> void:
	if _is_lightweight_result(result) or out_id == in_id or in_id <= 0:
		return
	var subs: Array = result.get("substitutions", []) as Array
	subs.append({
		"inning": inning,
		"half": half,
		"team_id": team_id,
		"kind": kind,
		"out_id": out_id,
		"in_id": in_id,
		"position": position,
		"slot": slot,
	})
	result["substitutions"] = subs


# apply_pending_defensive_subs / maybe_apply_defensive_replacements が返す option 配列を交代ログ化。
# option の形が 2 種あるため両対応 (outgoing record か outgoing_player_id)。
static func _log_defensive_subs(result: Dictionary, applied: Array, inning: int, half: String, team_id: int) -> void:
	for option_row in applied:
		var option: Dictionary = option_row as Dictionary
		var out_id: int = 0
		if option.has("outgoing"):
			var outgoing: PSPlayerSeasonRecord = option.get("outgoing", null) as PSPlayerSeasonRecord
			out_id = 0 if outgoing == null else outgoing.player_id
		else:
			out_id = int(option.get("outgoing_player_id", 0))
		var replacement: PSPlayerSeasonRecord = option.get("replacement", null) as PSPlayerSeasonRecord
		var in_id: int = 0 if replacement == null else replacement.player_id
		_record_substitution(result, inning, half, team_id, "defense", out_id, in_id, int(option.get("position", 0)), int(option.get("lineup_slot", -1)))


static func simulate_half_inning(
	offense: Dictionary,
	defense: Dictionary,
	next_defensive_inning: int,
	game_result: Dictionary = {},
	inning: int = 0,
	half: String = "",
	run_limit: int = 0,
	pa_cache: Dictionary = {}
) -> int:
	var bases: Array = [null, null, null]
	var outs: int = 0
	var runs: int = 0
	var _earned_runs: int = 0
	var earned_outs: int = 0
	var runner_responsibility: Dictionary = {}
	var pitcher: PSPlayerSeasonRecord = defense["pitcher"] as PSPlayerSeasonRecord
	var pitcher_usage: Dictionary = PSBullpenManager.pitcher_usage_for(defense, pitcher)
	var half_start_event_index: int = next_play_event_index(game_result)
	ensure_pitcher_outing(defense, game_result, inning, half, bases, runs, outs)

	while outs < 3:
		pitcher = defense["pitcher"] as PSPlayerSeasonRecord
		pitcher_usage = PSBullpenManager.pitcher_usage_for(defense, pitcher)
		var batting_order: Array = offense["batters"] as Array
		var batting_index: int = int(offense.get("batting_index", 0))
		var batting_slot: int = batting_index % batting_order.size()
		var scheduled_batter: PSPlayerSeasonRecord = batting_order[batting_slot] as PSPlayerSeasonRecord
		var runner_context: Dictionary = runner_event_context(game_result, inning, half, runs)
		var pre_event_index: int = next_play_event_index(game_result)
		var pre_bases_before: Array = bases.duplicate()
		var pre_outs_before: int = outs
		var pre_runs_before: int = runs
		var pre_plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(
			pre_event_index,
			scheduled_batter,
			pitcher,
			defense,
			bases,
			outs,
			runner_context
		)
		var pre_runner_events: Array = pre_plan.get("events", []) as Array
		var deferred_steal_intents: Array = pre_plan.get("deferred_steal_intents", []) as Array
		var pre_applied: Dictionary = apply_runner_events(pre_runner_events, bases, outs, pre_bases_before)
		credit_runner_event_errors(defense, pre_runner_events)
		tally_runner_events(game_result, pre_runner_events)
		if not pre_runner_events.is_empty():
			outs += int(pre_applied.get("outs", 0))
			runs += int(pre_applied.get("runs", 0))
			var pre_charges: Array = run_charges_for_runner_events(pre_runner_events, runner_responsibility, pitcher, earned_outs)
			var pre_charge_totals: Dictionary = charge_pitcher_run_charges(pre_charges, pitcher, defense, game_result, half, runs)
			_earned_runs += int(pre_charge_totals.get("total_earned_runs", 0))
			earned_outs = advance_earned_outs_for_runner_events(earned_outs, pre_runner_events, int(pre_applied.get("outs", 0)))
			apply_pitcher_outs(pitcher, int(pre_applied.get("outs", 0)))
			PSPitcherUsageModel.record_runner_event_result(pitcher_usage, int(pre_applied.get("outs", 0)), int(pre_applied.get("runs", 0)), int(pre_charge_totals.get("current_earned_runs", 0)))
			record_pitcher_outing_activity(
				defense,
				game_result,
				pitcher,
				inning,
				half,
				int(pre_applied.get("outs", 0)),
				0,
				0,
				int(pre_charge_totals.get("current_runs", 0)),
				int(pre_charge_totals.get("current_earned_runs", 0)),
				pre_bases_before,
				bases,
				runs
			)
			mark_unearned_runner_event_advances(runner_responsibility, pre_runner_events)
			sync_runner_responsibility_to_bases(runner_responsibility, bases)
			var pre_go_ahead_pitcher_id: int = go_ahead_pitcher_id_for_charges(pre_charges, game_result, half, pre_runs_before, runs)
			append_runner_event_play(
				game_result,
				inning,
				half,
				offense,
				defense,
				scheduled_batter,
				pitcher,
				pre_bases_before,
				pre_outs_before,
				bases,
				outs,
				runs - pre_runs_before,
				pre_runner_events,
				"before_pitch"
			)
			set_last_play_score_and_lead(game_result, inning, half, offense, defense, pre_runs_before, runs, pitcher, pre_go_ahead_pitcher_id)
			if half_inning_run_limit_reached(runs, run_limit):
				break
			if outs >= 3:
				continue

		var batter: PSPlayerSeasonRecord = PSInGameSubstitutions.maybe_select_pinch_hitter(
			offense,
			scheduled_batter,
			batting_slot,
			next_defensive_inning,
			game_result,
			inning,
			half,
			bases,
			outs,
			runs
		)
		offense["batting_index"] = batting_index + 1
		# 打者が入れ替わったら代打として記録する。ただし投手の打順で代打を立てられず現在の投手が
		# 打つ場合は代打ではない (投手交代は "pitching" で記録済み)。
		var pinch_hit_applied: bool = (
			batter != null
			and scheduled_batter != null
			and batter.player_id != scheduled_batter.player_id
			and batter != (offense.get("pitcher", null) as PSPlayerSeasonRecord)
		)
		if pinch_hit_applied:
			_record_substitution(game_result, inning, half, int(offense.get("team_id", 0)), "pinch_hit", scheduled_batter.player_id, batter.player_id, 0, batting_slot)

		var bases_before: Array = bases.duplicate()
		var outs_before: int = outs
		var runs_before: int = runs
		var outcome: Dictionary = resolve_plate_outcome(
			batter,
			pitcher,
			defense,
			bases,
			outs,
			{"runner_intents": deferred_steal_intents},
			pa_cache
		)
		var event_index: int = next_play_event_index(game_result)
		outcome = PSRunnerActionModel.apply_runner_in_motion_to_outcome(
			event_index,
			outcome,
			deferred_steal_intents,
			bases_before,
			outs_before
		)
		outcome["runner_intents"] = deferred_steal_intents.duplicate(true)
		var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
		if pitch_summary.is_empty():
			pitch_summary = PSPlayEventBuilder.pitch_summary_for_play(event_index, batter, pitcher, outcome)
		var batter_rbi_before: int = 0 if batter == null else batter.batter_stats.runs_batted_in
		var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, pitcher, bases, outs, outcome, {
			PSPlateEventReducer.OPTION_PITCH_SUMMARY: pitch_summary,
		})
		credit_fielding_error(defense, outcome)
		PSPitcherUsageModel.record_plate_appearance(pitcher_usage, pitcher, outcome, pitch_summary, applied, bases_before, outs_before)
		outs += int(applied.get("outs", 0))
		runs += int(applied.get("runs", 0))
		var plate_charges: Array = run_charges_for_plate(
			batter,
			pitcher,
			outcome,
			bases_before,
			int(applied.get("runs", 0)),
			runner_responsibility,
			earned_outs,
			int(applied.get("outs", 0))
		)
		var plate_charge_totals: Dictionary = charge_pitcher_run_charges(plate_charges, pitcher, defense, game_result, half, runs)
		_earned_runs += int(plate_charge_totals.get("total_earned_runs", 0))
		assign_batter_responsibility_after_plate(runner_responsibility, batter, pitcher, outcome, bases, earned_outs, int(applied.get("outs", 0)))
		mark_unearned_plate_error_advances(runner_responsibility, outcome, bases_before, bases)
		earned_outs = advance_earned_outs_for_plate(earned_outs, outcome, int(applied.get("outs", 0)))
		var plate_reached_run_limit: bool = half_inning_run_limit_reached(runs, run_limit)
		var runner_events: Array = []
		var post_runner_current_runs: int = 0
		var post_runner_current_earned_runs: int = 0
		var post_runner_charges: Array = []
		if not plate_reached_run_limit or is_batted_ball_outcome(outcome):
			var post_runner_context: Dictionary = runner_event_context(game_result, inning, half, runs)
			post_runner_context["deferred_steal_intents"] = deferred_steal_intents
			runner_events = PSPlayEventBuilder.runner_events_for_play(
				event_index,
				batter,
				pitcher,
				defense,
				bases_before,
				bases,
				outs_before,
				outs,
				outcome,
				post_runner_context
			)
		if not plate_reached_run_limit:
			var runner_applied: Dictionary = apply_runner_events(runner_events, bases, outs, bases_before)
			credit_runner_event_errors(defense, runner_events)
			tally_runner_events(game_result, runner_events)
			outs += int(runner_applied.get("outs", 0))
			runs += int(runner_applied.get("runs", 0))
			post_runner_charges = run_charges_for_runner_events(runner_events, runner_responsibility, pitcher, earned_outs)
			var runner_charge_totals: Dictionary = charge_pitcher_run_charges(post_runner_charges, pitcher, defense, game_result, half, runs)
			_earned_runs += int(runner_charge_totals.get("total_earned_runs", 0))
			earned_outs = advance_earned_outs_for_runner_events(earned_outs, runner_events, int(runner_applied.get("outs", 0)))
			post_runner_current_runs = int(runner_charge_totals.get("current_runs", 0))
			post_runner_current_earned_runs = int(runner_charge_totals.get("current_earned_runs", 0))
			apply_pitcher_outs(pitcher, int(runner_applied.get("outs", 0)))
			PSPitcherUsageModel.record_runner_event_result(pitcher_usage, int(runner_applied.get("outs", 0)), int(runner_applied.get("runs", 0)), int(runner_charge_totals.get("current_earned_runs", 0)))
			mark_unearned_runner_event_advances(runner_responsibility, runner_events)
			sync_runner_responsibility_to_bases(runner_responsibility, bases)
			var runner_rbi: int = int(runner_applied.get("rbi", 0))
			if runner_rbi > 0:
				batter.batter_stats.runs_batted_in += runner_rbi

		# この打席で打者に計上された打点(正確値) = 打席処理前後の runs_batted_in 差分。
		# 失策得点や走者の自力得点(盗塁本盗等)は打点に入らない。
		if batter != null:
			outcome["rbi"] = batter.batter_stats.runs_batted_in - batter_rbi_before
		append_play_event(
			game_result,
			inning,
			half,
			offense,
			defense,
			batter,
			pitcher,
			bases_before,
			outs_before,
			outcome,
			bases,
			outs,
			runs - runs_before,
			runner_events,
			pitch_summary
		)
		var all_run_charges: Array = plate_charges.duplicate()
		all_run_charges.append_array(post_runner_charges)
		var go_ahead_pitcher_id: int = go_ahead_pitcher_id_for_charges(all_run_charges, game_result, half, runs_before, runs)
		record_pitcher_outing_activity(
			defense,
			game_result,
			pitcher,
			inning,
			half,
			outs - outs_before,
			int(pitch_summary.get("pitches", 0)),
			1,
			int(plate_charge_totals.get("current_runs", 0)) + post_runner_current_runs,
			int(plate_charge_totals.get("current_earned_runs", 0)) + post_runner_current_earned_runs,
			bases_before,
			bases,
			runs
		)
		set_last_play_score_and_lead(game_result, inning, half, offense, defense, runs_before, runs, pitcher, go_ahead_pitcher_id)
		if half_inning_run_limit_reached(runs, run_limit):
			break
		maybe_change_pitcher_after_pa(defense, game_result, inning, half, outs, bases, runs)

	apply_advanced_stats_for_event_range(game_result, half_start_event_index)
	pitcher = defense["pitcher"] as PSPlayerSeasonRecord
	pitcher_usage = PSBullpenManager.pitcher_usage_for(defense, pitcher)
	update_active_pitcher_outing_end(defense, game_result, inning, half, runs)
	PSPitcherUsageModel.finish_half_inning(pitcher_usage)
	defense["game_outs"] = int(defense.get("game_outs", 0)) + outs
	defense["game_runs_allowed"] = int(defense.get("game_runs_allowed", 0)) + runs
	return runs


static func bottom_half_walkoff_run_limit(game_result: Dictionary, inning: int) -> int:
	if inning < GameSimulator.REGULATION_INNINGS:
		return 0
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	return int(max(1, away_score - home_score + 1))


static func half_inning_run_limit_reached(runs: int, run_limit: int) -> bool:
	return run_limit > 0 and runs >= run_limit


static func is_batted_ball_outcome(outcome: Dictionary) -> bool:
	var category: String = str(outcome.get("category", "out"))
	return category != "walk" and category != "hit_by_pitch" and category != "strikeout"


static func next_play_event_index(game_result: Dictionary) -> int:
	if game_result.is_empty():
		return 0
	if game_result.has("next_play_event_index"):
		return int(game_result.get("next_play_event_index", 0))
	var play_events: Array = game_result.get("play_events", []) as Array
	return play_events.size()


static func consume_play_event_index(game_result: Dictionary) -> int:
	var event_index: int = next_play_event_index(game_result)
	game_result["next_play_event_index"] = event_index + 1
	return event_index


static func ensure_pitcher_outing(
	defense: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	current_half_runs: int,
	current_outs: int = 0
) -> void:
	if game_result.is_empty():
		return
	var pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
	if pitcher == null:
		return
	var active_index: int = int(defense.get("active_pitcher_outing_index", -1))
	var outings: Array = game_result.get("pitcher_outings", []) as Array
	if active_index >= 0 and active_index < outings.size():
		var active: Dictionary = outings[active_index] as Dictionary
		if bool(active.get("active", false)) and int(active.get("pitcher_id", 0)) == pitcher.player_id:
			return
		finish_active_pitcher_outing(defense, game_result, inning, half, current_half_runs)

	var usage: Dictionary = PSBullpenManager.pitcher_usage_for(defense, pitcher)
	var role: String = str(usage.get("role", PSPitcherUsageModel.ROLE_SHORT_RELIEF))
	var score: Dictionary = defensive_score_state(defense, game_result, half, current_half_runs)
	var inherited_ids: Array = runner_ids_on_bases(bases)
	var new_outing: Dictionary = {
		"pitcher_id": pitcher.player_id,
		"team_id": int(defense.get("team_id", 0)),
		"role": role,
		"start_inning": inning,
		"start_half": half,
		"end_inning": inning,
		"end_half": half,
		"start_event_index": next_play_event_index(game_result),
		"end_event_index": next_play_event_index(game_result) - 1,
		"outs": 0,
		"pitches": 0,
		"batters_faced": 0,
		"runs": 0,
		"earned_runs": 0,
		"inherited_runners": inherited_ids.size(),
		"inherited_runners_scored": 0,
		"inherited_runner_ids": inherited_ids,
		"entry_base_runners": inherited_ids.size(),
		"entry_outs": current_outs,
		"entry_lead": int(score.get("lead", 0)),
		"exit_lead": int(score.get("lead", 0)),
		"entry_score_for": int(score.get("score_for", 0)),
		"entry_score_against": int(score.get("score_against", 0)),
		"exit_score_for": int(score.get("score_for", 0)),
		"exit_score_against": int(score.get("score_against", 0)),
		"active": true,
	}
	outings.append(new_outing)
	game_result["pitcher_outings"] = outings
	defense["active_pitcher_outing_index"] = outings.size() - 1


static func record_pitcher_outing_activity(
	defense: Dictionary,
	game_result: Dictionary,
	pitcher: PSPlayerSeasonRecord,
	inning: int,
	half: String,
	outs_added: int,
	pitches: int,
	batters_faced: int,
	runs: int,
	earned_runs: int,
	bases_before: Array,
	bases_after: Array,
	current_half_runs: int
) -> void:
	if game_result.is_empty() or pitcher == null:
		return
	ensure_pitcher_outing(defense, game_result, inning, half, bases_before, current_half_runs)
	var active_index: int = int(defense.get("active_pitcher_outing_index", -1))
	var outings: Array = game_result.get("pitcher_outings", []) as Array
	if active_index < 0 or active_index >= outings.size():
		return
	var outing: Dictionary = outings[active_index] as Dictionary
	if int(outing.get("pitcher_id", 0)) != pitcher.player_id:
		return
	outing["outs"] = int(outing.get("outs", 0)) + max(0, outs_added)
	outing["pitches"] = int(outing.get("pitches", 0)) + max(0, pitches)
	outing["batters_faced"] = int(outing.get("batters_faced", 0)) + max(0, batters_faced)
	outing["runs"] = int(outing.get("runs", 0)) + max(0, runs)
	outing["earned_runs"] = int(outing.get("earned_runs", 0)) + max(0, earned_runs)
	outing["inherited_runners_scored"] = int(outing.get("inherited_runners_scored", 0)) + inherited_runners_scored(outing, bases_before, bases_after, runs)
	outing["end_inning"] = inning
	outing["end_half"] = half
	outing["end_event_index"] = max(int(outing.get("end_event_index", -1)), next_play_event_index(game_result) - 1)
	update_outing_exit_score(outing, defense, game_result, half, current_half_runs)
	outings[active_index] = outing
	game_result["pitcher_outings"] = outings


static func update_active_pitcher_outing_end(
	defense: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	current_half_runs: int
) -> void:
	if game_result.is_empty():
		return
	var active_index: int = int(defense.get("active_pitcher_outing_index", -1))
	var outings: Array = game_result.get("pitcher_outings", []) as Array
	if active_index < 0 or active_index >= outings.size():
		return
	var outing: Dictionary = outings[active_index] as Dictionary
	outing["end_inning"] = inning
	outing["end_half"] = half
	outing["end_event_index"] = max(int(outing.get("end_event_index", -1)), next_play_event_index(game_result) - 1)
	update_outing_exit_score(outing, defense, game_result, half, current_half_runs)
	outings[active_index] = outing
	game_result["pitcher_outings"] = outings


static func finish_active_pitcher_outing(
	defense: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	current_half_runs: int
) -> void:
	update_active_pitcher_outing_end(defense, game_result, inning, half, current_half_runs)
	var active_index: int = int(defense.get("active_pitcher_outing_index", -1))
	var outings: Array = game_result.get("pitcher_outings", []) as Array
	if active_index >= 0 and active_index < outings.size():
		var outing: Dictionary = outings[active_index] as Dictionary
		outing["active"] = false
		outings[active_index] = outing
		game_result["pitcher_outings"] = outings
	defense["active_pitcher_outing_index"] = -1


static func maybe_change_pitcher_after_pa(
	defense: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	outs: int,
	bases: Array,
	current_half_runs: int
) -> void:
	if outs >= 3:
		return
	var old_pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
	if old_pitcher == null:
		return
	var changed: bool = PSBullpenManager.substitute_reliever_mid_inning(
		defense,
		inning,
		outs,
		bases,
		current_half_runs,
		game_result
	)
	if not changed:
		return
	finish_active_pitcher_outing(defense, game_result, inning, half, current_half_runs)
	ensure_pitcher_outing(defense, game_result, inning, half, bases, current_half_runs, outs)
	_record_substitution(game_result, inning, half, int(defense.get("team_id", 0)), "pitching", old_pitcher.player_id, int((defense.get("pitcher", null) as PSPlayerSeasonRecord).player_id), 1, -1)


static func defensive_score_state(defense: Dictionary, game_result: Dictionary, half: String, current_half_runs: int) -> Dictionary:
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var _home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if half == "top":
		away_score += current_half_runs
	elif half == "bottom":
		home_score += current_half_runs
	var team_id: int = int(defense.get("team_id", 0))
	var score_for: int = away_score if team_id == away_team_id else home_score
	var score_against: int = home_score if team_id == away_team_id else away_score
	return {
		"score_for": score_for,
		"score_against": score_against,
		"lead": score_for - score_against,
	}


static func update_outing_exit_score(
	outing: Dictionary,
	defense: Dictionary,
	game_result: Dictionary,
	half: String,
	current_half_runs: int
) -> void:
	var score: Dictionary = defensive_score_state(defense, game_result, half, current_half_runs)
	outing["exit_lead"] = int(score.get("lead", 0))
	outing["exit_score_for"] = int(score.get("score_for", 0))
	outing["exit_score_against"] = int(score.get("score_against", 0))


static func set_last_play_score_and_lead(
	game_result: Dictionary,
	inning: int,
	half: String,
	offense: Dictionary,
	defense: Dictionary,
	before_half_runs: int,
	after_half_runs: int,
	pitcher: PSPlayerSeasonRecord,
	charged_losing_pitcher_id: int = 0
) -> void:
	if game_result.is_empty():
		return
	var before_score: Dictionary = score_pair_for_half(game_result, half, before_half_runs)
	var after_score: Dictionary = score_pair_for_half(game_result, half, after_half_runs)
	var lead_event_index: int = max(0, next_play_event_index(game_result) - 1)
	var play_events: Array = game_result.get("play_events", []) as Array
	if not play_events.is_empty():
		var last_index: int = play_events.size() - 1
		var event: Dictionary = play_events[last_index] as Dictionary
		event["score_before"] = before_score
		event["score_after"] = after_score
		play_events[last_index] = event
		game_result["play_events"] = play_events
		lead_event_index = int(event.get("event_index", last_index))

	var before_leader: int = leading_team_id(game_result, before_score)
	var after_leader: int = leading_team_id(game_result, after_score)
	if after_leader > 0 and after_leader != before_leader:
		game_result["last_lead_change"] = {
			"event_index": lead_event_index,
			"inning": inning,
			"half": half,
			"winning_team_id": after_leader,
			"losing_team_id": int(defense.get("team_id", 0)),
			"losing_pitcher_id": charged_losing_pitcher_id if charged_losing_pitcher_id > 0 else (0 if pitcher == null else pitcher.player_id),
			"batting_team_id": int(offense.get("team_id", 0)),
			"fielding_team_id": int(defense.get("team_id", 0)),
			"score_before": before_score,
			"score_after": after_score,
		}


static func score_pair_for_half(game_result: Dictionary, half: String, current_half_runs: int) -> Dictionary:
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if half == "top":
		away_score += current_half_runs
	elif half == "bottom":
		home_score += current_half_runs
	return {
		"away": away_score,
		"home": home_score,
	}


static func leading_team_id(game_result: Dictionary, score: Dictionary) -> int:
	var away_score: int = int(score.get("away", 0))
	var home_score: int = int(score.get("home", 0))
	if away_score == home_score:
		return 0
	return int(game_result.get("away_team_id", 0)) if away_score > home_score else int(game_result.get("home_team_id", 0))


static func runner_ids_on_bases(bases: Array) -> Array:
	var ids: Array = []
	for base_value in bases:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		if runner != null:
			ids.append(runner.player_id)
	return ids


static func inherited_runners_scored(outing: Dictionary, bases_before: Array, bases_after: Array, runs: int) -> int:
	if runs <= 0:
		return 0
	var inherited_ids: Array = outing.get("inherited_runner_ids", []) as Array
	if inherited_ids.is_empty():
		return 0
	var before_ids: Array = runner_ids_on_bases(bases_before)
	var after_ids: Array = runner_ids_on_bases(bases_after)
	var disappeared: int = 0
	for id_value in inherited_ids:
		var runner_id: int = int(id_value)
		if before_ids.has(runner_id) and not after_ids.has(runner_id):
			disappeared += 1
	return min(runs, disappeared)


static func run_charges_for_plate(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	outcome: Dictionary,
	bases_before: Array,
	runs: int,
	runner_responsibility: Dictionary,
	earned_outs_before: int = 0,
	outs_added: int = 0
) -> Array:
	if runs <= 0:
		return []
	var category: String = str(outcome.get("category", "out"))
	var scored_ids: Array = scored_runner_ids_for_plate(batter, outcome, bases_before, runs)
	var charges: Array = []
	for runner_id_value in scored_ids:
		var runner_id: int = int(runner_id_value)
		var responsibility: Dictionary = runner_responsibility.get(str(runner_id), {}) as Dictionary
		var responsible_pitcher: PSPlayerSeasonRecord = responsibility.get("pitcher", null) as PSPlayerSeasonRecord
		if responsible_pitcher == null:
			responsible_pitcher = pitcher
		var earned: bool = bool(responsibility.get("earned", true)) and plate_run_can_be_earned(category, earned_outs_before, outs_added)
		charges.append({
			"runner_id": runner_id,
			"pitcher": responsible_pitcher,
			"earned": earned,
		})
	while charges.size() < runs:
		charges.append({
			"runner_id": 0,
			"pitcher": pitcher,
			"earned": plate_run_can_be_earned(category, earned_outs_before, outs_added),
		})
	return charges


static func scored_runner_ids_for_plate(
	batter: PSPlayerSeasonRecord,
	outcome: Dictionary,
	bases_before: Array,
	runs: int
) -> Array:
	var category: String = str(outcome.get("category", "out"))
	var ids: Array = []
	match category:
		"walk", "hit_by_pitch":
			if runs > 0:
				append_base_runner_id(ids, bases_before, 2)
		"sacrifice", "productive_out":
			append_base_runner_id(ids, bases_before, 2)
		"sacrifice_fly", "out", "fielders_choice":
			append_scored_ids_from_advancements(ids, outcome.get("runner_advancements", []) as Array)
			if ids.is_empty() and runs > 0 and category == "sacrifice_fly":
				append_base_runner_id(ids, bases_before, 2)
		"double_play":
			# 無死からの併殺で生還できるのは三塁走者だけ (base_state_resolver.apply_double_play)。
			if runs > 0:
				append_base_runner_id(ids, bases_before, 2)
		"strikeout":
			pass
		_:
			var bases_taken: int = int(outcome.get("bases", 0))
			var advancements: Array = outcome.get("runner_advancements", []) as Array
			if not advancements.is_empty():
				append_scored_ids_from_advancements(ids, advancements)
			else:
				for base_index in range(2, -1, -1):
					var runner: PSPlayerSeasonRecord = bases_before[base_index] as PSPlayerSeasonRecord
					if runner != null and base_index + bases_taken >= 3:
						ids.append(runner.player_id)
			if bases_taken >= 4 and batter != null:
				ids.append(batter.player_id)
	while ids.size() > runs:
		ids.pop_back()
	return ids


static func append_scored_ids_from_advancements(ids: Array, advancements: Array) -> void:
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		if bool(advancement.get("is_out", false)):
			continue
		if int(advancement.get("to_base", 0)) < 4:
			continue
		var runner_id: int = int(advancement.get("runner_id", 0))
		if runner_id <= 0:
			var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
			runner_id = 0 if runner == null else runner.player_id
		if runner_id > 0:
			ids.append(runner_id)


static func append_base_runner_id(ids: Array, bases: Array, base_index: int) -> void:
	if base_index < 0 or base_index >= bases.size():
		return
	var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
	if runner != null:
		ids.append(runner.player_id)


static func plate_run_can_be_earned(category: String, earned_outs_before: int = 0, outs_added: int = 0) -> bool:
	if category == "error":
		return false
	if earned_outs_before >= 3:
		return false
	if category in ["out", "sacrifice", "sacrifice_fly", "productive_out", "fielders_choice", "double_play", "strikeout"]:
		return earned_outs_before + max(0, outs_added) < 3
	return true


static func run_charges_for_runner_events(
	runner_events: Array,
	runner_responsibility: Dictionary,
	pitcher: PSPlayerSeasonRecord,
	earned_outs_before: int = 0
) -> Array:
	var charges: Array = []
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		# state_already_applied の生還イベントは打席処理で得点計上済みの描写用で、
		# 失点チャージも run_charges_for_plate 側で完了している。ここで再チャージすると
		# 投手の失点/自責だけが二重計上される(チーム得点は apply_runner_events が
		# 同フラグでスキップするため正しく、投手側だけずれる)。
		if bool(event.get("state_already_applied", false)):
			continue
		if bool(event.get("is_out", false)):
			continue
		if int(event.get("to_base", 0)) < 4:
			continue
		var runner_id: int = int(event.get("runner_id", 0))
		var responsibility: Dictionary = runner_responsibility.get(str(runner_id), {}) as Dictionary
		var responsible_pitcher: PSPlayerSeasonRecord = responsibility.get("pitcher", null) as PSPlayerSeasonRecord
		if responsible_pitcher == null:
			responsible_pitcher = pitcher
		var earned: bool = bool(responsibility.get("earned", true)) and runner_event_run_can_be_earned(event, earned_outs_before)
		charges.append({
			"runner_id": runner_id,
			"pitcher": responsible_pitcher,
			"earned": earned,
		})
	return charges


static func runner_event_run_can_be_earned(event: Dictionary, earned_outs_before: int = 0) -> bool:
	if earned_outs_before >= 3:
		return false
	if bool(event.get("is_fielding_error", false)):
		return false
	return str(event.get("result", "")) != "passed_ball"


static func advance_earned_outs_for_plate(earned_outs_before: int, outcome: Dictionary, outs_added: int) -> int:
	var category: String = str(outcome.get("category", "out"))
	var virtual_outs: int = max(0, outs_added)
	if category == "error":
		virtual_outs = max(1, virtual_outs)
	return min(3, max(0, earned_outs_before) + virtual_outs)


static func advance_earned_outs_for_runner_events(earned_outs_before: int, runner_events: Array, outs_added: int) -> int:
	var virtual_outs: int = max(0, outs_added)
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		if bool(event.get("is_out", false)):
			continue
		if bool(event.get("is_fielding_error", false)):
			virtual_outs += 1
	return min(3, max(0, earned_outs_before) + virtual_outs)


static func mark_unearned_runner_event_advances(runner_responsibility: Dictionary, runner_events: Array) -> void:
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		if not runner_event_marks_runner_unearned(event):
			continue
		var runner_id: int = int(event.get("runner_id", 0))
		if runner_id <= 0:
			continue
		var responsibility: Dictionary = runner_responsibility.get(str(runner_id), {}) as Dictionary
		if responsibility.is_empty():
			continue
		responsibility["earned"] = false
		runner_responsibility[str(runner_id)] = responsibility


static func runner_event_marks_runner_unearned(event: Dictionary) -> bool:
	if bool(event.get("is_out", false)):
		return false
	if int(event.get("to_base", 0)) >= 4:
		return false
	if bool(event.get("is_fielding_error", false)):
		return true
	return str(event.get("result", "")) == "passed_ball"


static func mark_unearned_plate_error_advances(
	runner_responsibility: Dictionary,
	outcome: Dictionary,
	bases_before: Array,
	bases_after: Array
) -> void:
	if str(outcome.get("category", "")) != "error":
		return
	var before_ids: Array = runner_ids_on_bases(bases_before)
	for base_value in bases_after:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		if runner == null:
			continue
		if not before_ids.has(runner.player_id):
			continue
		var responsibility: Dictionary = runner_responsibility.get(str(runner.player_id), {}) as Dictionary
		if responsibility.is_empty():
			continue
		responsibility["earned"] = false
		runner_responsibility[str(runner.player_id)] = responsibility


static func charge_pitcher_run_charges(
	charges: Array,
	current_pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	game_result: Dictionary,
	half: String,
	current_half_runs: int
) -> Dictionary:
	var current_runs: int = 0
	var current_earned_runs: int = 0
	var total_earned_runs: int = 0
	for charge_value in charges:
		var charge: Dictionary = charge_value as Dictionary
		var responsible_pitcher: PSPlayerSeasonRecord = charge.get("pitcher", null) as PSPlayerSeasonRecord
		if responsible_pitcher == null:
			responsible_pitcher = current_pitcher
		var earned_runs: int = 1 if bool(charge.get("earned", true)) else 0
		charge_pitcher_runs(responsible_pitcher, 1, earned_runs)
		total_earned_runs += earned_runs
		if current_pitcher != null and responsible_pitcher.player_id == current_pitcher.player_id:
			current_runs += 1
			current_earned_runs += earned_runs
		else:
			add_run_to_pitcher_outing(
				game_result,
				int(defense.get("team_id", 0)),
				0 if responsible_pitcher == null else responsible_pitcher.player_id,
				earned_runs,
				half,
				current_half_runs
			)
	return {
		"current_runs": current_runs,
		"current_earned_runs": current_earned_runs,
		"total_earned_runs": total_earned_runs,
	}


static func go_ahead_pitcher_id_for_charges(
	charges: Array,
	game_result: Dictionary,
	half: String,
	before_half_runs: int,
	after_half_runs: int
) -> int:
	if charges.is_empty() or after_half_runs <= before_half_runs:
		return 0
	var before_score: Dictionary = score_pair_for_half(game_result, half, before_half_runs)
	var offense_before: int = int(before_score.get("away", 0)) if half == "top" else int(before_score.get("home", 0))
	var defense_before: int = int(before_score.get("home", 0)) if half == "top" else int(before_score.get("away", 0))
	if offense_before > defense_before:
		return 0
	var needed_run_index: int = defense_before - offense_before
	if needed_run_index < 0 or needed_run_index >= charges.size():
		return 0
	var charge: Dictionary = charges[needed_run_index] as Dictionary
	var pitcher: PSPlayerSeasonRecord = charge.get("pitcher", null) as PSPlayerSeasonRecord
	if pitcher != null:
		return pitcher.player_id
	return int(charge.get("pitcher_id", 0))


# 継承走者の生還など、降板済みの投手へ後から失点を付ける (呼び出しは責任投手 != 現在の投手のときだけ)。
# 失点と exit_lead は動かす — その走者はこの投手の責任で、ホールド判定は「リードを渡さずに降りたか」を
# 見るため。一方 **end_inning / end_half / end_event_index は動かさない**: これは登板範囲 (いつ降りたか)
# であって、降板後のイベントまで伸ばすと試合ログ上の登板が実際より長く見える。
static func add_run_to_pitcher_outing(
	game_result: Dictionary,
	team_id: int,
	pitcher_id: int,
	earned_runs: int,
	half: String,
	current_half_runs: int
) -> void:
	if game_result.is_empty() or pitcher_id <= 0:
		return
	var outings: Array = game_result.get("pitcher_outings", []) as Array
	for index in range(outings.size() - 1, -1, -1):
		var outing: Dictionary = outings[index] as Dictionary
		if int(outing.get("team_id", 0)) != team_id or int(outing.get("pitcher_id", 0)) != pitcher_id:
			continue
		outing["runs"] = int(outing.get("runs", 0)) + 1
		outing["earned_runs"] = int(outing.get("earned_runs", 0)) + max(0, earned_runs)
		update_outing_exit_score_for_team(outing, team_id, game_result, half, current_half_runs)
		outings[index] = outing
		game_result["pitcher_outings"] = outings
		return


static func update_outing_exit_score_for_team(
	outing: Dictionary,
	team_id: int,
	game_result: Dictionary,
	half: String,
	current_half_runs: int
) -> void:
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if half == "top":
		away_score += current_half_runs
	elif half == "bottom":
		home_score += current_half_runs
	var score_for: int = away_score if team_id == away_team_id else home_score
	var score_against: int = home_score if team_id == away_team_id else away_score
	if team_id != away_team_id and team_id != home_team_id:
		return
	outing["exit_lead"] = score_for - score_against
	outing["exit_score_for"] = score_for
	outing["exit_score_against"] = score_against


static func assign_batter_responsibility_after_plate(
	runner_responsibility: Dictionary,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	outcome: Dictionary,
	bases: Array,
	earned_outs_before: int = 0,
	outs_added: int = 0
) -> void:
	sync_runner_responsibility_to_bases(runner_responsibility, bases)
	if batter == null or pitcher == null:
		return
	if not runner_ids_on_bases(bases).has(batter.player_id):
		return
	runner_responsibility[str(batter.player_id)] = {
		"pitcher": pitcher,
		"pitcher_id": pitcher.player_id,
		"earned": plate_run_can_be_earned(str(outcome.get("category", "out")), earned_outs_before, outs_added),
	}


static func sync_runner_responsibility_to_bases(runner_responsibility: Dictionary, bases: Array) -> void:
	var ids_on_bases: Array = runner_ids_on_bases(bases)
	for key_value in runner_responsibility.keys():
		if not ids_on_bases.has(int(key_value)):
			runner_responsibility.erase(key_value)


static func charge_pitcher_runs(pitcher: PSPlayerSeasonRecord, runs: int, earned_runs: int) -> void:
	if pitcher == null:
		return
	if runs > 0:
		pitcher.pitcher_stats.runs_allowed += runs
	if earned_runs > 0:
		pitcher.pitcher_stats.earned_runs += earned_runs


static func apply_pitcher_outs(pitcher: PSPlayerSeasonRecord, outs_added: int) -> void:
	if pitcher == null:
		return
	if outs_added > 0:
		pitcher.pitcher_stats.outs_pitched += outs_added


static func apply_advanced_stats_for_event_range(game_result: Dictionary, start_index: int) -> void:
	if game_result.is_empty() or _is_lightweight_result(game_result):
		return
	var play_events: Array = game_result.get("play_events", []) as Array
	if start_index < 0 or start_index >= play_events.size():
		return
	var advanced_stats: Dictionary = game_result.get("advanced_stats", {}) as Dictionary
	for index in range(start_index, play_events.size()):
		PSAdvancedStatReducer.apply_play_event(advanced_stats, play_events[index] as Dictionary)
	game_result["advanced_stats"] = advanced_stats


static func runner_event_context(game_result: Dictionary, inning: int, half: String, current_half_runs: int = 0) -> Dictionary:
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	var offense_score: int = away_score if half == "top" else home_score
	var defense_score: int = home_score if half == "top" else away_score
	offense_score += current_half_runs
	return {
		"inning": inning,
		"half": half,
		"offense_score": offense_score,
		"defense_score": defense_score,
		"defense_lead": defense_score - offense_score,
	}


# 走塁・守備イベントのリーグ頻度検証用に、result 種別ごとの件数を試合結果へ集計する。
# 適用済みイベント (apply_runner_events を通ったもの) だけを数える。集計は
# balance_report の running_defense セクション (simulation_reporter) が読む。
# 盗塁企図は内訳 (対象塁 second/third・戦術 delayed/double・三振ゲッツー) も別キーで数え、
# NPB実勢 (二盗:三盗比・塁別成功率等) との突き合わせに使う。
static func tally_runner_events(game_result: Dictionary, runner_events: Array) -> void:
	if game_result.is_empty() or _is_lightweight_result(game_result) or runner_events.is_empty():
		return
	var counts: Dictionary = game_result.get("runner_event_counts", {}) as Dictionary
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		var key: String = str(event.get("result", ""))
		if key.is_empty():
			continue
		counts[key] = int(counts.get(key, 0)) + 1
		if key == "runner_in_motion_batted_ball":
			var motion_strategy: String = str(event.get("strategy", "straight_steal"))
			counts["runner_in_motion_%s" % motion_strategy] = int(counts.get("runner_in_motion_%s" % motion_strategy, 0)) + 1
			if bool(event.get("double_play_avoided_by_runner_motion", false)):
				counts["runner_in_motion_double_play_avoided"] = int(counts.get("runner_in_motion_double_play_avoided", 0)) + 1
		if bool(event.get("is_steal_attempt", false)):
			counts["steal_attempt"] = int(counts.get("steal_attempt", 0)) + 1
			var target_label: String = "second" if int(event.get("from_base", 0)) == 1 else "third"
			counts["steal_attempt_%s" % target_label] = int(counts.get("steal_attempt_%s" % target_label, 0)) + 1
			if bool(event.get("is_stolen_base", false)):
				counts["stolen_base_%s" % target_label] = int(counts.get("stolen_base_%s" % target_label, 0)) + 1
			var strategy: String = str(event.get("strategy", ""))
			if strategy in ["delayed_steal", "double_steal", "hit_and_run"]:
				counts["steal_attempt_%s" % strategy] = int(counts.get("steal_attempt_%s" % strategy, 0)) + 1
			if bool(event.get("on_strikeout_pitch", false)):
				counts["steal_attempt_on_strikeout"] = int(counts.get("steal_attempt_on_strikeout", 0)) + 1
				if bool(event.get("is_caught_stealing", false)):
					counts["strikeout_caught_stealing"] = int(counts.get("strikeout_caught_stealing", 0)) + 1
	game_result["runner_event_counts"] = counts


static func apply_runner_events(
	runner_events: Array,
	bases: Array,
	outs: int,
	bases_for_stats: Array
) -> Dictionary:
	var outs_added_total: int = 0
	var runs_total: int = 0
	var rbi_total: int = 0
	var current_outs: int = outs
	for runner_event_value in runner_events:
		if current_outs >= 3:
			break
		var runner_event: Dictionary = runner_event_value as Dictionary
		var runner_outs: int = 0
		var runner_runs: int = 0
		if not bool(runner_event.get("state_already_applied", false)):
			var runner_applied: Dictionary = PSBaseStateResolver.apply_runner_event(bases, current_outs, runner_event)
			runner_outs = int(runner_applied.get("outs", 0))
			runner_runs = int(runner_applied.get("runs", 0))
			current_outs += runner_outs
		if runner_outs > 0 or runner_runs > 0 or bool(runner_event.get("is_steal_attempt", false)):
			apply_runner_event_stats(runner_event, bases_for_stats)
		if runner_runs > 0 and bool(runner_event.get("batter_rbi", false)):
			rbi_total += runner_runs
		outs_added_total += runner_outs
		runs_total += runner_runs
	return {
		"outs": outs_added_total,
		"runs": runs_total,
		"rbi": rbi_total,
	}


static func apply_runner_event_stats(runner_event: Dictionary, bases_before: Array) -> void:
	if not bool(runner_event.get("is_steal_attempt", false)):
		return
	var runner_id: int = int(runner_event.get("runner_id", 0))
	var runner: PSPlayerSeasonRecord = runner_from_bases(bases_before, runner_id)
	if runner == null:
		return
	runner.batter_stats.stolen_base_attempts += 1
	if bool(runner_event.get("is_stolen_base", false)):
		runner.batter_stats.stolen_bases += 1


static func runner_from_bases(bases: Array, runner_id: int) -> PSPlayerSeasonRecord:
	if runner_id <= 0:
		return null
	for base_value in bases:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		if runner != null and runner.player_id == runner_id:
			return runner
	return null


static func append_runner_event_play(
	game_result: Dictionary,
	inning: int,
	half: String,
	offense: Dictionary,
	defense: Dictionary,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	bases_after: Array,
	outs_after: int,
	runs_scored: int,
	runner_events: Array = [],
	play_phase: String = "before_pitch"
) -> void:
	if game_result.is_empty():
		return
	if runner_events.is_empty():
		return
	var event_index: int = consume_play_event_index(game_result)
	var play_event: Dictionary = PSPlayEventBuilder.build_runner_event_play(
		event_index,
		inning,
		half,
		offense,
		defense,
		batter,
		pitcher,
		bases_before,
		outs_before,
		bases_after,
		outs_after,
		runs_scored,
		runner_events,
		play_phase
	)
	if _is_lightweight_result(game_result):
		PSAdvancedStatReducer.apply_play_event(game_result["advanced_stats"] as Dictionary, play_event)
		return
	var play_events: Array = game_result.get("play_events", []) as Array
	play_events.append(play_event)
	game_result["play_events"] = play_events


static func append_play_event(
	game_result: Dictionary,
	inning: int,
	half: String,
	offense: Dictionary,
	defense: Dictionary,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	outcome: Dictionary,
	bases_after: Array,
	outs_after: int,
	runs_scored: int,
	runner_events: Array = [],
	pitch_summary: Dictionary = {}
) -> void:
	if game_result.is_empty():
		return
	var event_index: int = consume_play_event_index(game_result)
	var play_event: Dictionary = PSPlayEventBuilder.build_play_event(
		event_index,
		inning,
		half,
		offense,
		defense,
		batter,
		pitcher,
		bases_before,
		outs_before,
		outcome,
		bases_after,
		outs_after,
		runs_scored,
		runner_events,
		pitch_summary
	)
	if _is_lightweight_result(game_result):
		PSAdvancedStatReducer.apply_play_event(game_result["advanced_stats"] as Dictionary, play_event)
		return
	var play_events: Array = game_result.get("play_events", []) as Array
	play_events.append(play_event)
	game_result["play_events"] = play_events


static func _is_lightweight_result(game_result: Dictionary) -> bool:
	return bool(game_result.get("_lightweight", false))


static func resolve_plate_outcome(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	batting_context: Dictionary = {},
	pa_cache: Dictionary = {}
) -> Dictionary:
	var usage: Dictionary = PSBullpenManager.pitcher_usage_for(defense, pitcher)
	var pitching_context: Dictionary = PSPitcherUsageModel.plate_context(pitcher, usage)
	var is_reliever: bool = str(pitching_context.get("pitcher_role", PSPitcherUsageModel.ROLE_SHORT_RELIEF)) != PSPitcherUsageModel.ROLE_STARTER
	return PSPlateAppearanceCoordinator.resolve(
		batter,
		pitcher,
		defense,
		bases,
		outs,
		is_reliever,
		pitching_context,
		batting_context,
		pa_cache
	)


# 打席結果が失策のとき、その打球を扱った守備選手に失策を1つ計上する。
# 失策を帰属させる選手は play_event_builder._fielder_id と同じ規則 (fielders スロット、
# 投手は position 1) で特定し、fielding_event の fielder_id と一致させる。
static func credit_fielding_error(defense: Dictionary, outcome: Dictionary) -> void:
	if str(outcome.get("category", "")) != "error":
		return
	var position: int = int(outcome.get("fielder_position", 0))
	if position <= 0:
		return
	var fielder: PSPlayerSeasonRecord = fielder_record_for_position(defense, position)
	if fielder != null:
		fielder.batter_stats.errors += 1


# 走者イベント由来の失策（捕手の盗塁送球ミス等、is_fielding_error=true）を該当守備位置に計上する。
static func credit_runner_event_errors(defense: Dictionary, runner_events: Array) -> void:
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		if not bool(event.get("is_fielding_error", false)):
			continue
		var position: int = int(event.get("error_position", 0))
		if position <= 0:
			continue
		var fielder: PSPlayerSeasonRecord = fielder_record_for_position(defense, position)
		if fielder != null:
			fielder.batter_stats.errors += 1


static func fielder_record_for_position(defense: Dictionary, position: int) -> PSPlayerSeasonRecord:
	if position == 1:
		return defense.get("pitcher", null) as PSPlayerSeasonRecord
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == position:
			return slot.get("record", null) as PSPlayerSeasonRecord
	return null
