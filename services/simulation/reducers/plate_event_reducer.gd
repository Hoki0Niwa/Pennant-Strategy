extends RefCounted
class_name PSPlateEventReducer

const BaseStateResolver = preload("res://services/simulation/reducers/base_state_resolver.gd")

const OPTION_TRACK_BATTER: String = "track_batter"
const OPTION_TRACK_PITCHER: String = "track_pitcher"
const OPTION_CHARGE_PITCHER_RUNS: String = "charge_pitcher_runs"
const OPTION_PITCH_SUMMARY: String = "pitch_summary"


static func apply_plate_outcome(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	outcome: Dictionary,
	options: Dictionary = {}
) -> Dictionary:
	var track_batter: bool = bool(options.get(OPTION_TRACK_BATTER, true))
	var track_pitcher: bool = bool(options.get(OPTION_TRACK_PITCHER, true))
	var charge_pitcher_runs: bool = bool(options.get(OPTION_CHARGE_PITCHER_RUNS, false))
	var pitch_summary: Dictionary = options.get(OPTION_PITCH_SUMMARY, {}) as Dictionary
	var pitches: int = int(pitch_summary.get("pitches", 0))
	var category: String = str(outcome.get("category", "out"))
	var runs: int = 0
	var earned_runs: int = 0
	var outs_added: int = 0

	if track_batter and batter != null:
		batter.batter_stats.plate_appearances += 1
		batter.batter_stats.pitches_seen += pitches
	if track_pitcher and pitcher != null:
		pitcher.pitcher_stats.batters_faced += 1
		pitcher.pitcher_stats.pitches_thrown += pitches

	match category:
		"hit_by_pitch":
			if track_batter and batter != null:
				batter.batter_stats.hit_by_pitches += 1
			if track_pitcher and pitcher != null:
				pitcher.pitcher_stats.hit_batters += 1
			runs = BaseStateResolver.advance_hit_by_pitch(batter, bases)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
		"walk":
			if track_batter and batter != null:
				batter.batter_stats.walks += 1
			if track_pitcher and pitcher != null:
				pitcher.pitcher_stats.walks += 1
			runs = BaseStateResolver.advance_walk(batter, bases)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
		"strikeout":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
				batter.batter_stats.strikeouts += 1
			if track_pitcher and pitcher != null:
				pitcher.pitcher_stats.strikeouts += 1
			outs_added = 1
		"sacrifice":
			if track_batter and batter != null:
				batter.batter_stats.sacrifices += 1
			runs = BaseStateResolver.advance_sacrifice(bases)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
			outs_added = 1
		"sacrifice_fly":
			if track_batter and batter != null:
				batter.batter_stats.sacrifice_flies += 1
			runs = BaseStateResolver.advance_sacrifice_fly(bases, outcome)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
			outs_added = 1
		"productive_out":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
			runs = BaseStateResolver.advance_productive_out(bases)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
			outs_added = 1
		"double_play":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
				batter.batter_stats.double_plays += 1
			outs_added = BaseStateResolver.apply_double_play(bases, outs)
		"fielders_choice":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
			var fielders_choice: Dictionary = BaseStateResolver.advance_fielders_choice(batter, bases, outcome)
			runs = int(fielders_choice.get("runs", 0))
			earned_runs = runs
			outs_added = int(fielders_choice.get("outs", 1))
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
		"error":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
			runs = BaseStateResolver.advance_error(batter, bases, int(outcome.get("bases", 1)))
		"out":
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
			runs = BaseStateResolver.advance_out_with_plan(bases, outcome)
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs
			outs_added = 1
		_:
			var bases_taken: int = int(outcome.get("bases", 0))
			if track_batter and batter != null:
				batter.batter_stats.at_bats += 1
				batter.batter_stats.hits += 1
			if track_pitcher and pitcher != null:
				pitcher.pitcher_stats.hits_allowed += 1
			match bases_taken:
				2:
					if track_batter and batter != null:
						batter.batter_stats.doubles += 1
				3:
					if track_batter and batter != null:
						batter.batter_stats.triples += 1
				4:
					if track_batter and batter != null:
						batter.batter_stats.home_runs += 1
					if track_pitcher and pitcher != null:
						pitcher.pitcher_stats.home_runs_allowed += 1
			var runner_advancements: Array = outcome.get("runner_advancements", []) as Array
			if runner_advancements.is_empty():
				runs = BaseStateResolver.advance_hit(batter, bases, bases_taken)
			else:
				var hit_advance: Dictionary = BaseStateResolver.advance_hit_with_plan(
					batter,
					bases,
					bases_taken,
					runner_advancements
				)
				runs = int(hit_advance.get("runs", 0))
				outs_added += int(hit_advance.get("outs", 0))
			earned_runs = runs
			if track_batter and batter != null:
				batter.batter_stats.runs_batted_in += runs

	if track_pitcher and pitcher != null:
		pitcher.pitcher_stats.outs_pitched += outs_added
		if charge_pitcher_runs:
			pitcher.pitcher_stats.runs_allowed += runs
			pitcher.pitcher_stats.earned_runs += earned_runs

	return {
		"category": category,
		"outs": outs_added,
		"runs": runs,
		"earned_runs": earned_runs,
		"pitches": pitches,
	}
