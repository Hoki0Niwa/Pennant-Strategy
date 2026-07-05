extends RefCounted
class_name PSPlateEventReducer

const BaseStateResolver = preload("res://services/simulation/reducers/base_state_resolver.gd")

# 打席 outcome を公式記録と塁状況へ反映する reducer。
# batter/pitcher の stats を必要に応じて更新し、bases は in-place で進塁後の状態へ変わる。
# GameLoop は戻り値の outs/runs/earned_runs/pitches を使って試合スコアと投手責任を更新する。
const OPTION_TRACK_BATTER: String = "track_batter"
const OPTION_TRACK_PITCHER: String = "track_pitcher"
const OPTION_CHARGE_PITCHER_RUNS: String = "charge_pitcher_runs"
const OPTION_PITCH_SUMMARY: String = "pitch_summary"


# options:
# - track_batter / track_pitcher: テストや仮想処理で個人成績更新を止めたいとき false
# - charge_pitcher_runs: inning 側で責任投手へ失点を付けるタイミングだけ true
# - pitch_summary: 球数を打者 pitches_seen / 投手 pitches_thrown へ加算するための集計
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
		_record_pitcher_batted_ball(pitcher.pitcher_stats, outcome)
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


static func _record_pitcher_batted_ball(stats: PSPitcherStats, outcome: Dictionary) -> void:
	if stats == null:
		return
	if not _is_batted_ball_outcome(outcome):
		return
	if _is_home_run_outcome(outcome):
		return
	match _batted_ball_type(outcome):
		"grounder":
			stats.ground_balls_allowed += 1
		"liner":
			stats.line_drives_allowed += 1
		"popup":
			stats.infield_flies_allowed += 1
		"fly":
			stats.outfield_flies_allowed += 1


static func _is_batted_ball_outcome(outcome: Dictionary) -> bool:
	var category: String = str(outcome.get("category", "out"))
	return category != "strikeout" and category != "walk" and category != "hit_by_pitch"


static func _is_home_run_outcome(outcome: Dictionary) -> bool:
	return int(outcome.get("bases", 0)) >= 4 or str(outcome.get("result", "")).contains("home_run")


static func _batted_ball_type(outcome: Dictionary) -> String:
	var physical_traits: Dictionary = outcome.get("physical_traits", {}) as Dictionary
	var trajectory: String = str(physical_traits.get("trajectory_bucket", ""))
	match trajectory:
		"grounder", "liner", "fly", "popup":
			return trajectory
	var result: String = str(outcome.get("result", ""))
	var category: String = str(outcome.get("category", ""))
	if category == "sacrifice":
		return "grounder"
	if category == "sacrifice_fly":
		return "fly"
	if result.contains("ground") or result.contains("bunt") or result.contains("infield_single"):
		return "grounder"
	if result.contains("line"):
		return "liner"
	if result.contains("infield_fly") or result.contains("popup"):
		return "popup"
	if result.contains("fly"):
		return "fly"
	if result.contains("double") or result.contains("triple"):
		return "liner"
	return ""
