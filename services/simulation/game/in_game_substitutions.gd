extends RefCounted
class_name PSInGameSubstitutions

static func maybe_select_pinch_hitter(
	setup: Dictionary,
	batter: PSPlayerSeasonRecord,
	batting_slot: int,
	next_defensive_inning: int,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int
) -> PSPlayerSeasonRecord:
	if batter == null:
		return batter
	if is_pitcher_batting_spot(setup, batter):
		return maybe_select_pitcher_spot_pinch_hitter(
			setup,
			batter,
			next_defensive_inning,
			game_result,
			inning,
			half,
			bases,
			outs,
			current_half_runs
		)

	var pinch_hit_option: Dictionary = position_player_pinch_hit_option(
		setup,
		batter,
		batting_slot,
		game_result,
		inning,
		half,
		bases,
		outs,
		current_half_runs
	)
	if pinch_hit_option.is_empty():
		return batter
	var pinch_hitter: PSPlayerSeasonRecord = pinch_hit_option.get("pinch_hitter", null) as PSPlayerSeasonRecord
	var defensive_replacement: PSPlayerSeasonRecord = pinch_hit_option.get("defensive_replacement", null) as PSPlayerSeasonRecord
	if pinch_hitter == null:
		return batter
	if defensive_replacement == null:
		return batter
	apply_position_player_pinch_hitter(
		setup,
		batting_slot,
		batter,
		pinch_hitter,
		defensive_replacement,
		int(pinch_hit_option.get("position", 0))
	)
	return pinch_hitter


static func maybe_select_pitcher_spot_pinch_hitter(
	setup: Dictionary,
	batter: PSPlayerSeasonRecord,
	next_defensive_inning: int,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int
) -> PSPlayerSeasonRecord:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	if starter == null:
		return batter

	var already_relieved: bool = bool(setup.get("starter_relieved", false))
	var important_chance: bool = is_important_pinch_hit_chance(
		setup,
		game_result,
		inning,
		half,
		bases,
		outs,
		current_half_runs
	)
	var should_hit_for_pitcher: bool = already_relieved
	should_hit_for_pitcher = should_hit_for_pitcher or starter_should_be_relieved_for_next_defense(setup, next_defensive_inning)
	should_hit_for_pitcher = should_hit_for_pitcher or starter_should_be_hit_for_in_scoring_chance(
		setup,
		next_defensive_inning,
		game_result,
		inning,
		half,
		bases,
		outs,
		current_half_runs
	)
	if not should_hit_for_pitcher:
		return batter
	var prefer_long: bool = PSBullpenManager.should_prefer_long_relief_for_starter_exit(next_defensive_inning)
	if not already_relieved and PSBullpenManager.pick_reliever_for_context(setup, next_defensive_inning, {}, prefer_long) == null:
		return batter

	var minimum_score: int = pinch_hit_batting_score(batter) + 8
	var pinch_hitter: PSPlayerSeasonRecord = null
	if important_chance:
		pinch_hitter = select_best_pinch_hitter(setup, minimum_score)
	else:
		pinch_hitter = select_preserve_top_pinch_hitter(setup, minimum_score)
	if pinch_hitter == null:
		return batter
	mark_pinch_hitter_appeared(setup, pinch_hitter)
	if not already_relieved:
		PSBullpenManager.mark_starter_relieved(setup)
	return pinch_hitter


static func is_pitcher_batting_spot(setup: Dictionary, batter: PSPlayerSeasonRecord) -> bool:
	if batter == null or bool(setup.get("dh_enabled", false)):
		return false
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	return starter != null and batter.player_id == starter.player_id


static func starter_should_be_relieved_for_next_defense(setup: Dictionary, inning: int) -> bool:
	if bool(setup.get("starter_relieved", false)):
		return false
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if starter == null or current != starter:
		return false
	var usage: Dictionary = PSBullpenManager.pitcher_usage_for(setup, starter, PSPitcherUsageModel.ROLE_STARTER)
	return PSPitcherUsageModel.should_pull_when_pitcher_spot_bats(starter, usage, inning, int(setup.get("game_runs_allowed", 0)))


static func starter_should_be_hit_for_in_scoring_chance(
	setup: Dictionary,
	next_defensive_inning: int,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int
) -> bool:
	if bool(setup.get("starter_relieved", false)):
		return false
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if starter == null or current != starter:
		return false
	if next_defensive_inning < 5:
		return false
	var chance_score: int = offensive_chance_score(setup, game_result, inning, half, bases, outs, current_half_runs)
	if chance_score < 8:
		return false
	var usage: Dictionary = PSBullpenManager.pitcher_usage_for(setup, starter, PSPitcherUsageModel.ROLE_STARTER)
	var projected_factor: float = PSPitcherUsageModel.starter_projected_next_inning_effective_factor(starter, usage)
	var current_factor: float = PSFatigueCalculator.factor_for_outing(starter, usage)
	if projected_factor <= 0.28:
		return true
	if current_factor <= 0.30:
		return true
	return next_defensive_inning >= 7 and projected_factor <= 0.48


static func select_best_pinch_hitter(setup: Dictionary, minimum_score: int = -999999) -> PSPlayerSeasonRecord:
	var eligible: Array = sorted_pinch_hit_candidates(setup, minimum_score)
	if eligible.is_empty():
		return null
	var selected: PSPlayerSeasonRecord = eligible[0] as PSPlayerSeasonRecord
	remove_from_bench(setup, selected)
	return selected


static func select_preserve_top_pinch_hitter(setup: Dictionary, minimum_score: int = -999999) -> PSPlayerSeasonRecord:
	var ranked: Array = sorted_pinch_hit_candidates(setup)
	if ranked.size() < 3:
		return null
	var pool: Array = []
	for candidate_row in ranked.slice(2):
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		if pinch_hit_batting_score(candidate) > minimum_score:
			pool.append(candidate)
	if pool.is_empty():
		return null
	var selected: PSPlayerSeasonRecord = pool[Rng.range_int(0, pool.size() - 1)] as PSPlayerSeasonRecord
	remove_from_bench(setup, selected)
	return selected


static func sorted_pinch_hit_candidates(setup: Dictionary, minimum_score: int = -999999) -> Array:
	var bench: Array = setup.get("bench", []) as Array
	var eligible: Array = []
	for bench_row in bench:
		var candidate: PSPlayerSeasonRecord = bench_row as PSPlayerSeasonRecord
		if candidate == null or candidate.injury_days > 0:
			continue
		if candidate.is_pitcher():
			continue
		if is_reserved_fielder(setup, candidate):
			continue
		if pinch_hit_batting_score(candidate) <= minimum_score:
			continue
		eligible.append(candidate)
	eligible.sort_custom(func(a, b) -> bool:
		return PSInGameSubstitutions.pinch_hit_batting_score(a as PSPlayerSeasonRecord) > PSInGameSubstitutions.pinch_hit_batting_score(b as PSPlayerSeasonRecord)
	)
	return eligible


static func position_player_pinch_hit_option(
	setup: Dictionary,
	batter: PSPlayerSeasonRecord,
	batting_slot: int,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int
) -> Dictionary:
	if inning < GameSimulator.PINCH_HIT_START_INNING:
		return {}
	var score_context: Dictionary = offensive_score_context(setup, game_result, half, current_half_runs)
	var deficit: int = int(score_context.get("defense_score", 0)) - int(score_context.get("offense_score", 0))
	var chance_score: int = offensive_chance_score(setup, game_result, inning, half, bases, outs, current_half_runs)
	var important_chance: bool = is_important_pinch_hit_chance(setup, game_result, inning, half, bases, outs, current_half_runs)
	var final_chance: bool = is_final_low_bat_pinch_hit_chance(inning, deficit)
	if not important_chance and not final_chance:
		return {}
	if deficit < -1 or deficit > 5:
		return {}
	var batter_score: int = pinch_hit_batting_score(batter)
	var low_score_limit: int = batting_score_line(
		batter, GameSimulator.LOW_BATTER_SIGMA, GameSimulator.LOW_BATTER_SCORE
	)
	if inning >= 8:
		low_score_limit += GameSimulator.PINCH_HIT_LATE_SCORE_MARGIN
	if important_chance:
		low_score_limit += GameSimulator.PINCH_HIT_IMPORTANT_SCORE_MARGIN
	if batter_score > low_score_limit:
		return {}

	var position: int = fielding_position_for_player(setup, batter.player_id)
	if position == 0:
		return {}
	var reserve: int = 0 if important_chance or final_chance else pinch_hit_bench_reserve(inning, chance_score, outs)
	var available_count: int = available_bench_fielder_count(setup)
	if available_count < reserve + 1:
		return {}

	var best_candidate: PSPlayerSeasonRecord = null
	var defensive_replacement: PSPlayerSeasonRecord = null
	var candidates: Array = sorted_pinch_hit_candidates(setup, batter_score + GameSimulator.PINCH_HIT_MIN_GAIN)
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		if pinch_hitter_can_stay_on_defense(candidate, position):
			best_candidate = candidate
			defensive_replacement = candidate
			break
		if available_count < reserve + 2:
			continue
		var reserved_fielder: PSPlayerSeasonRecord = best_defensive_reservation_for_position(setup, position, candidate.player_id)
		if reserved_fielder == null:
			continue
		best_candidate = candidate
		defensive_replacement = reserved_fielder
		break
	if best_candidate == null:
		return {}
	if batting_slot < 0:
		return {}
	return {
		"pinch_hitter": best_candidate,
		"defensive_replacement": defensive_replacement,
		"position": position,
	}


static func apply_position_player_pinch_hitter(
	setup: Dictionary,
	batting_slot: int,
	outgoing: PSPlayerSeasonRecord,
	pinch_hitter: PSPlayerSeasonRecord,
	defensive_replacement: PSPlayerSeasonRecord,
	position: int
) -> void:
	remove_from_bench(setup, pinch_hitter)
	var batters: Array = setup.get("batters", []) as Array
	if batting_slot >= 0 and batting_slot < batters.size():
		batters[batting_slot] = pinch_hitter
		setup["batters"] = batters
	if position >= 2 and position <= 9:
		reserve_defensive_substitution(setup, batting_slot, outgoing, pinch_hitter, defensive_replacement, position)
	mark_pinch_hitter_appeared(setup, pinch_hitter)


static func reserve_defensive_substitution(
	setup: Dictionary,
	batting_slot: int,
	outgoing: PSPlayerSeasonRecord,
	pinch_hitter: PSPlayerSeasonRecord,
	defensive_replacement: PSPlayerSeasonRecord,
	position: int
) -> void:
	if outgoing == null or pinch_hitter == null or defensive_replacement == null:
		return
	var pending: Array = setup.get("pending_defensive_subs", []) as Array
	pending.append({
		"lineup_slot": batting_slot,
		"outgoing_player_id": outgoing.player_id,
		"pinch_hitter_id": pinch_hitter.player_id,
		"replacement": defensive_replacement,
		"replacement_id": defensive_replacement.player_id,
		"position": position,
	})
	setup["pending_defensive_subs"] = pending
	var reserved_ids: Dictionary = setup.get("reserved_fielder_ids", {}) as Dictionary
	reserved_ids[defensive_replacement.player_id] = true
	setup["reserved_fielder_ids"] = reserved_ids


# 適用した(代打に伴う繰越)守備交代の配列を返す (呼び出し側が交代ログに使う)。
static func apply_pending_defensive_subs(setup: Dictionary) -> Array:
	var pending: Array = setup.get("pending_defensive_subs", []) as Array
	if pending.is_empty():
		return []
	var applied: Array = []
	for row in pending:
		var substitution: Dictionary = row as Dictionary
		var replacement: PSPlayerSeasonRecord = substitution.get("replacement", null) as PSPlayerSeasonRecord
		if replacement == null:
			continue
		var position: int = int(substitution.get("position", 0))
		var lineup_slot: int = int(substitution.get("lineup_slot", -1))
		remove_from_bench(setup, replacement)
		var batters: Array = setup.get("batters", []) as Array
		if lineup_slot >= 0 and lineup_slot < batters.size():
			batters[lineup_slot] = replacement
			setup["batters"] = batters
		replace_fielder(setup, int(substitution.get("outgoing_player_id", 0)), replacement, position)
		mark_substitute_appeared(setup, replacement)
		applied.append(substitution)
	setup["pending_defensive_subs"] = []
	setup["reserved_fielder_ids"] = {}
	return applied


static func best_defensive_reservation_for_position(setup: Dictionary, position: int, excluded_player_id: int = 0) -> PSPlayerSeasonRecord:
	var bench: Array = setup.get("bench", []) as Array
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -999999
	for bench_row in bench:
		var candidate: PSPlayerSeasonRecord = bench_row as PSPlayerSeasonRecord
		if candidate == null or candidate.injury_days > 0 or candidate.is_pitcher():
			continue
		if candidate.player_id == excluded_player_id:
			continue
		if is_reserved_fielder(setup, candidate):
			continue
		if not can_trust_fielder_for_position(candidate, position):
			continue
		var score: int = defense_only_score(candidate, position)
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


static func pinch_hitter_can_stay_on_defense(record: PSPlayerSeasonRecord, position: int) -> bool:
	if record == null or record.injury_days > 0 or record.is_pitcher():
		return false
	if record.position == position:
		return true
	return PSTeamSetupBuilder.position_aptitude(record, position) >= 90


static func available_bench_fielder_count(setup: Dictionary) -> int:
	var count: int = 0
	var bench: Array = setup.get("bench", []) as Array
	for bench_row in bench:
		var candidate: PSPlayerSeasonRecord = bench_row as PSPlayerSeasonRecord
		if candidate == null or candidate.injury_days > 0 or candidate.is_pitcher():
			continue
		if is_reserved_fielder(setup, candidate):
			continue
		count += 1
	return count


static func is_reserved_fielder(setup: Dictionary, record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return false
	var reserved_ids: Dictionary = setup.get("reserved_fielder_ids", {}) as Dictionary
	return reserved_ids.has(record.player_id)


static func mark_pinch_hitter_appeared(setup: Dictionary, pinch_hitter: PSPlayerSeasonRecord) -> void:
	mark_substitute_appeared(setup, pinch_hitter)


static func mark_substitute_appeared(setup: Dictionary, substitute: PSPlayerSeasonRecord) -> void:
	if substitute == null:
		return
	var appeared: Dictionary = setup.get("substitute_ids", {}) as Dictionary
	if appeared.has(substitute.player_id):
		return
	if substitute.is_pitcher():
		return
	substitute.batter_stats.games += 1
	var took_field: bool = fielding_position_for_player(setup, substitute.player_id) > 0
	var fatigue_gain: int = GameSimulator.DEFENSIVE_SUB_FATIGUE_GAIN if took_field else GameSimulator.PINCH_HITTER_FATIGUE_GAIN
	var exposure: float = 0.45 if took_field else 0.25
	substitute.fatigue = int(min(GameSimulator.FATIGUE_MAX, substitute.fatigue + fatigue_gain))
	PSScoringHelpers.maybe_injure_for_setup(setup, substitute, false, exposure)
	appeared[substitute.player_id] = true
	setup["substitute_ids"] = appeared


# 適用した守備固めの option 配列を返す (呼び出し側が交代ログに使う)。
static func maybe_apply_defensive_replacements(setup: Dictionary, inning: int, half: String, game_result: Dictionary) -> Array:
	if inning < GameSimulator.DEFENSIVE_REPLACEMENT_START_INNING:
		return []
	var margin: int = score_margin_for_setup(setup, game_result)
	if margin <= 0 or margin > GameSimulator.FINAL_DEFENSE_MAX_LEAD:
		return []
	var expected_plate_appearances: int = expected_remaining_plate_appearances_for_defensive_team(setup, inning, half, game_result)
	if expected_plate_appearances >= 9:
		return []
	var reserve: int = 0 if expected_plate_appearances == 0 or inning >= GameSimulator.REGULATION_INNINGS else 1
	var max_replacements: int = 2 if expected_plate_appearances == 0 else 1
	var applied: Array = []
	var made: int = 0
	while made < max_replacements:
		if available_bench_fielder_count(setup) <= reserve:
			break
		var option: Dictionary = defensive_replacement_option(setup, expected_plate_appearances)
		if option.is_empty():
			break
		apply_defensive_replacement(setup, option)
		applied.append(option)
		made += 1
	return applied


static func defensive_replacement_option(setup: Dictionary, expected_plate_appearances: int) -> Dictionary:
	var fielders: Array = setup.get("fielders", []) as Array
	var bench: Array = setup.get("bench", []) as Array
	var best_option: Dictionary = {}
	var best_value: float = -999999.0
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var outgoing: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		var position: int = int(assignment.get("position", 0))
		if outgoing == null or position < 2 or position > 9:
			continue
		if outgoing.age < 30 and outgoing.years < 8:
			continue
		var batting_score: int = pinch_hit_batting_score(outgoing)
		if batting_score < batting_score_line(
			outgoing, GameSimulator.SOLID_BATTER_SIGMA, GameSimulator.SOLID_BATTER_SCORE
		):
			continue
		var lineup_slot: int = lineup_slot_for_player(setup, outgoing.player_id)
		if lineup_slot < 0:
			continue
		if plate_appearance_distance_to_slot(setup, lineup_slot) <= expected_plate_appearances:
			continue
		var outgoing_defense: int = defense_only_score(outgoing, position)
		if outgoing_defense >= minimum_trusted_defense_score(position) + 20:
			continue
		for bench_row in bench:
			var candidate: PSPlayerSeasonRecord = bench_row as PSPlayerSeasonRecord
			if candidate == null or candidate.injury_days > 0 or candidate.is_pitcher():
				continue
			if is_reserved_fielder(setup, candidate):
				continue
			if not can_trust_fielder_for_position(candidate, position):
				continue
			var defense_gain: int = defense_only_score(candidate, position) - outgoing_defense
			if defense_gain < GameSimulator.DEFENSIVE_REPLACEMENT_MIN_GAIN:
				continue
			@warning_ignore("integer_division")
			var candidate_value: float = float(defense_gain * 3 + batting_score - pinch_hit_batting_score(candidate) / 2)
			if best_option.is_empty() or candidate_value > best_value:
				best_value = candidate_value
				best_option = {
					"outgoing": outgoing,
					"replacement": candidate,
					"position": position,
					"lineup_slot": lineup_slot,
				}
	return best_option


static func apply_defensive_replacement(setup: Dictionary, option: Dictionary) -> void:
	var outgoing: PSPlayerSeasonRecord = option.get("outgoing", null) as PSPlayerSeasonRecord
	var replacement: PSPlayerSeasonRecord = option.get("replacement", null) as PSPlayerSeasonRecord
	var position: int = int(option.get("position", 0))
	var lineup_slot: int = int(option.get("lineup_slot", -1))
	if outgoing == null or replacement == null or position < 2 or position > 9:
		return
	remove_from_bench(setup, replacement)
	var batters: Array = setup.get("batters", []) as Array
	if lineup_slot >= 0 and lineup_slot < batters.size():
		batters[lineup_slot] = replacement
		setup["batters"] = batters
	replace_fielder(setup, outgoing.player_id, replacement, position)
	mark_substitute_appeared(setup, replacement)


static func offensive_score_context(setup: Dictionary, game_result: Dictionary, half: String, current_half_runs: int = 0) -> Dictionary:
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var offense_score: int
	var defense_score: int
	if team_id == away_team_id or (away_team_id == 0 and half == "top"):
		offense_score = away_score + current_half_runs
		defense_score = home_score
	elif team_id == home_team_id or (home_team_id == 0 and half == "bottom"):
		offense_score = home_score + current_half_runs
		defense_score = away_score
	else:
		offense_score = away_score + current_half_runs if half == "top" else home_score + current_half_runs
		defense_score = home_score if half == "top" else away_score
	return {
		"offense_score": offense_score,
		"defense_score": defense_score,
	}


static func offensive_chance_score(
	setup: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int = 0
) -> int:
	var score_context: Dictionary = offensive_score_context(setup, game_result, half, current_half_runs)
	var offense_score: int = int(score_context.get("offense_score", 0))
	var defense_score: int = int(score_context.get("defense_score", 0))
	var deficit: int = defense_score - offense_score
	var chance_score: int = 0
	if inning >= 7:
		chance_score += 2
	if inning >= 8:
		chance_score += 1
	if inning >= 9:
		chance_score += 1
	if deficit > 0 and deficit <= 3:
		chance_score += 4 - deficit
	elif deficit == 0:
		chance_score += 2
	elif deficit < 0 and abs(deficit) <= 2:
		chance_score += 1
	chance_score += base_opportunity_score(bases)
	if outs == 0:
		chance_score += 2
	elif outs == 1:
		chance_score += 1
	else:
		chance_score -= 1
	return chance_score


static func base_opportunity_score(bases: Array) -> int:
	if bases.size() < 3:
		return 0
	var on_first: bool = bases[0] != null
	var on_second: bool = bases[1] != null
	var on_third: bool = bases[2] != null
	if on_first and on_second and on_third:
		return 5
	if on_second and on_third:
		return 4
	if on_third:
		return 3
	if on_second:
		return 3
	if on_first:
		return 1
	return 0


# 打撃スコアの判定ラインを、その選手のシーズンの母集団分布から引く。
# 母集団が無い (year 未設定の合成レコード等) 場合は fallback の絶対値へ落ちる。
# 基準分布は PSPerformanceReference のキャッシュ (シーズン開始時にプリウォーム済み) を読むだけなので、
# 試合日の並列実行から呼んでも書き込みは発生しない。
static func batting_score_line(record: PSPlayerSeasonRecord, sigma: float, fallback: int) -> int:
	if record == null or record.year <= 0:
		return fallback
	return int(round(PSPerformanceReference.score_threshold(
		record.year, record.season_number, "batting", sigma
	)))


static func pinch_hit_batting_score(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return -999999
	var score: int = PSScoringHelpers.batter_order_score(record)
	if record.is_pitcher():
		return int(round(float(score) * 0.58))
	return score


static func is_important_pinch_hit_chance(
	setup: Dictionary,
	game_result: Dictionary,
	inning: int,
	half: String,
	bases: Array,
	outs: int,
	current_half_runs: int = 0
) -> bool:
	var score_context: Dictionary = offensive_score_context(setup, game_result, half, current_half_runs)
	var deficit: int = int(score_context.get("defense_score", 0)) - int(score_context.get("offense_score", 0))
	if deficit < -1 or deficit > 4:
		return false
	return offensive_chance_score(setup, game_result, inning, half, bases, outs, current_half_runs) >= GameSimulator.IMPORTANT_PINCH_HIT_CHANCE_SCORE


static func is_final_low_bat_pinch_hit_chance(inning: int, deficit: int) -> bool:
	return inning >= 9 and deficit >= 0 and deficit <= 4


static func pinch_hit_bench_reserve(inning: int, chance_score: int, outs: int) -> int:
	if inning <= GameSimulator.PINCH_HIT_START_INNING:
		return 2
	if inning == 8:
		return 1
	if chance_score >= 9 and outs <= 1:
		return 0
	return 1


static func fielding_position_for_player(setup: Dictionary, player_id: int) -> int:
	var fielders: Array = setup.get("fielders", []) as Array
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return int(assignment.get("position", 0))
	var batters: Array = setup.get("batters", []) as Array
	for batter_row in batters:
		var batter: PSPlayerSeasonRecord = batter_row as PSPlayerSeasonRecord
		if batter != null and batter.player_id == player_id:
			return 10 if bool(setup.get("dh_enabled", false)) else 0
	return 0


static func can_trust_fielder_for_position(record: PSPlayerSeasonRecord, position: int) -> bool:
	if record == null or record.injury_days > 0:
		return false
	var aptitude: int = PSTeamSetupBuilder.position_aptitude(record, position)
	if aptitude <= 0:
		return false
	if (position == 2 or position == 6 or position == 8) and aptitude < 40:
		return false
	return defense_only_score(record, position) >= minimum_trusted_defense_score(position)


static func defense_only_score(record: PSPlayerSeasonRecord, position: int) -> int:
	if record == null:
		return -999999
	var aptitude: int = PSTeamSetupBuilder.position_aptitude(record, position)
	if aptitude <= 0:
		return -999999
	match position:
		2:
			return int(round(
				record.z_ability("C_FieldSecure", 0.0) * 17.5
				+ record.z_ability("C_Throw", 0.0) * 15.0
				+ record.z_ability("C_Blocking", 0.0) * 12.5
				+ record.z_ability("C_Framing", 0.0) * 10.0
				+ float(aptitude) * 1.1
			))
		3:
			return int(round(
				record.z_ability("IF_Secure", 0.0) * 20.0
				+ record.z_ability("IF_Reach", 0.0) * 10.0
				+ record.z_ability("IF_ThrowPower", 0.0) * 6.25
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 1.875
			))
		4:
			return int(round(
				record.z_ability("IF_Secure", 0.0) * 18.75
				+ record.z_ability("IF_Reach", 0.0) * 16.25
				+ record.z_ability("IF_ThrowPower", 0.0) * 8.75
				+ record.z_ability("IF_Exchange", 0.0) * 12.5
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 3.125
			))
		5:
			return int(round(
				record.z_ability("IF_Secure", 0.0) * 17.5
				+ record.z_ability("IF_Reach", 0.0) * 12.5
				+ record.z_ability("IF_ThrowPower", 0.0) * 15.0
				+ record.z_ability("IF_Exchange", 0.0) * 5.0
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 2.5
			))
		6:
			return int(round(
				record.z_ability("IF_Secure", 0.0) * 18.75
				+ record.z_ability("IF_Reach", 0.0) * 18.75
				+ record.z_ability("IF_ThrowPower", 0.0) * 12.5
				+ record.z_ability("IF_Exchange", 0.0) * 10.0
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 3.75
			))
		7, 9:
			return int(round(
				record.z_ability("OF_Secure", 0.0) * 15.0
				+ record.z_ability("OF_Reach", 0.0) * 16.875
				+ record.z_ability("OF_ArmPower", 0.0) * 11.25
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 3.125
			))
		8:
			return int(round(
				record.z_ability("OF_Secure", 0.0) * 15.0
				+ record.z_ability("OF_Reach", 0.0) * 20.625
				+ record.z_ability("OF_ArmPower", 0.0) * 11.25
				+ float(aptitude) * 1.2
				+ record.z_ability("Run_Speed", 0.0) * 4.375
			))
	return 0


# 閾値は z 化後の守備スコア。各ポジションの守備固め候補として信頼できる下限を表す。
static func minimum_trusted_defense_score(position: int) -> int:
	match position:
		2:
			return 145
		3:
			return 188
		4:
			return 118
		5:
			return 145
		6:
			return 125
		7:
			return 155
		8:
			return 175
		9:
			return 170
		_:
			return 145


static func remove_from_bench(setup: Dictionary, record: PSPlayerSeasonRecord) -> void:
	if record == null:
		return
	var bench: Array = setup.get("bench", []) as Array
	bench.erase(record)
	setup["bench"] = bench


static func replace_fielder(setup: Dictionary, outgoing_player_id: int, replacement: PSPlayerSeasonRecord, position: int) -> void:
	if replacement == null:
		return
	var fielders: Array = setup.get("fielders", []) as Array
	for i in range(fielders.size()):
		var assignment: Dictionary = fielders[i] as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if int(assignment.get("position", 0)) == position and (record == null or record.player_id == outgoing_player_id):
			fielders[i] = {
				"record": replacement,
				"position": position,
			}
			setup["fielders"] = fielders
			if position == 2:
				setup["catcher"] = replacement
			return


static func score_margin_for_setup(setup: Dictionary, game_result: Dictionary) -> int:
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if team_id == away_team_id:
		return away_score - home_score
	if team_id == home_team_id:
		return home_score - away_score
	return 0


static func expected_remaining_plate_appearances_for_defensive_team(
	setup: Dictionary,
	inning: int,
	half: String,
	game_result: Dictionary
) -> int:
	var team_id: int = int(setup.get("team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var margin: int = score_margin_for_setup(setup, game_result)
	var is_home: bool = team_id == home_team_id
	var is_away: bool = team_id == away_team_id
	if half == "top" and is_home:
		if inning >= GameSimulator.REGULATION_INNINGS and margin > 0:
			return 0
		return 4 if inning >= GameSimulator.DEFENSIVE_REPLACEMENT_START_INNING else 9
	if half == "bottom" and is_away:
		if inning >= GameSimulator.REGULATION_INNINGS and margin > 0:
			return 0
		return 4 if inning >= GameSimulator.DEFENSIVE_REPLACEMENT_START_INNING else 9
	return 9


static func lineup_slot_for_player(setup: Dictionary, player_id: int) -> int:
	var batters: Array = setup.get("batters", []) as Array
	for i in range(batters.size()):
		var batter: PSPlayerSeasonRecord = batters[i] as PSPlayerSeasonRecord
		if batter != null and batter.player_id == player_id:
			return i
	return -1


static func plate_appearance_distance_to_slot(setup: Dictionary, slot: int) -> int:
	var batters: Array = setup.get("batters", []) as Array
	var size: int = batters.size()
	if size <= 0 or slot < 0:
		return 999
	var next_slot: int = int(setup.get("batting_index", 0)) % size
	return ((slot - next_slot + size) % size) + 1
