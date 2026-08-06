extends RefCounted
class_name PSPitcherUsageModel

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

const ROLE_STARTER: String = "starter"
const ROLE_LONG_RELIEF: String = "long_relief"
const ROLE_SHORT_RELIEF: String = "short_relief"

const STARTER_FATIGUE_START_MIN: int = 52
const STARTER_FATIGUE_START_MAX: int = 88
const STARTER_STAMINA_LIMIT_MIN: int = 88
const STARTER_STAMINA_LIMIT_MAX: int = 145
const STARTER_COMPLETE_GAME_LIMIT_MIN: int = 104
const STARTER_COMPLETE_GAME_LIMIT_MAX: int = 145
const STARTER_COMPLETE_GAME_PITCHES_PER_OUT: float = 5.6
const STARTER_NEXT_INNING_BASE_PITCHES: float = 16.0
const STARTER_CURRENT_FATIGUE_FLOOR: float = 0.20
const STARTER_MID_INNING_FATIGUE_FLOOR: float = 0.16
const STARTER_COMPLETE_GAME_FATIGUE_FLOOR: float = 0.48
const SHORT_RELIEF_TARGET_MIN: int = 15
const SHORT_RELIEF_TARGET_MAX: int = 32
const LONG_RELIEF_TARGET_MIN: int = 32
const LONG_RELIEF_TARGET_MAX: int = 58
const STARTER_NEXT_INNING_PROJECTED_BATTERS: float = 4.0
const STARTER_TTO_HOOK_START_BF: float = 24.0
const STARTER_TTO_HOOK_RISK_PER_BF: float = 0.024
const STARTER_TTO_HOOK_RISK_MAX: float = 0.18

const TROUBLE_ALERT: float = 4.0
const MELTDOWN_THRESHOLD: float = 6.5
const TROUBLE_MAX: float = 10.0
const RELIEVER_FATIGUE_LIMIT: int = 145
const RELIEVER_EMERGENCY_FATIGUE_LIMIT: int = 188
const INJURY_RETURN_HARD_REST_DAYS: int = 1
const INJURY_RETURN_SOFT_REST_DAYS: int = 3
const USAGE_ARSENAL_CACHE_KEY: String = "_pa_arsenal_summary"
const USAGE_ARSENAL_BIASES_CACHE_KEY: String = "_pa_arsenal_biases"

# ピッチグレードは z スケール (リーグ平均 0)。display 45 相当 = z -0.4 を「実戦級」の閾値とする。
const EFFECTIVE_PITCH_Z: float = -0.4
# 第3球種が存在しないことを表すセンチネル (どの実 z より十分低い)。
const NO_THIRD_PITCH: float = -99.0

const PRIMARY_PITCH_WEIGHTS := {
	"Pit_KCreate": 0.44,
	"Pit_EdgeRate": 0.18,
	"Pit_ImpactLimit": 0.14,
	"Pit_BarrelDeny": 0.10,
	"Pit_BBPrevent": 0.08,
	"Pit_Efficiency": 0.06,
}

const SECONDARY_PITCH_WEIGHTS := {
	"Pit_ImpactLimit": 0.28,
	"Pit_BarrelDeny": 0.22,
	"Pit_LoftControl": 0.18,
	"Pit_KCreate": 0.14,
	"Pit_EdgeRate": 0.08,
	"Pit_BBPrevent": 0.06,
	"Pit_Efficiency": 0.04,
}

const COMMAND_PROFILE_WEIGHTS := {
	"Pit_BBPrevent": 0.42,
	"Pit_Efficiency": 0.20,
	"Pit_EdgeRate": 0.16,
	"Pit_HoldRunner": 0.08,
	"Pit_FatigueResist": 0.08,
	"Pit_KCreate": 0.06,
}

const MISS_BAT_PROFILE_WEIGHTS := {
	"Pit_KCreate": 0.56,
	"Pit_EdgeRate": 0.18,
	"Pit_BarrelDeny": 0.12,
	"Pit_ImpactLimit": 0.08,
	"Pit_Efficiency": 0.06,
}

const CONTACT_SUPPRESS_PROFILE_WEIGHTS := {
	"Pit_BarrelDeny": 0.30,
	"Pit_ImpactLimit": 0.26,
	"Pit_LoftControl": 0.22,
	"Pit_BBPrevent": 0.10,
	"Pit_Efficiency": 0.08,
	"Pit_KCreate": 0.04,
}

const STAMINA_PROFILE_WEIGHTS := {
	"Pit_Stamina": 0.44,
	"Pit_FatigueResist": 0.26,
	"Pit_Efficiency": 0.14,
	"Pit_HoldRunner": 0.08,
	"Pit_BBPrevent": 0.08,
}

const RECOVERY_PROFILE_WEIGHTS := {
	"Pit_FatigueResist": 0.44,
	"Pit_Stamina": 0.22,
	"Pit_Efficiency": 0.18,
	"Pit_BBPrevent": 0.10,
	"Pit_HoldRunner": 0.06,
}

const ARSENAL_DEPTH_WEIGHTS := {
	"Pit_Stamina": 0.28,
	"Pit_FatigueResist": 0.20,
	"Pit_Efficiency": 0.18,
	"Pit_BBPrevent": 0.12,
	"Pit_ImpactLimit": 0.10,
	"Pit_BarrelDeny": 0.08,
	"Pit_KCreate": 0.04,
}


static func starter_fatigue_start_pitches(record: PSPlayerSeasonRecord) -> int:
	var stamina: float = _ability(record, "Pit_Stamina")
	var recovery: float = _ability(record, "Pit_FatigueResist")
	var start: float = 66.0
	start += stamina * 4.0
	start += recovery * 2.5
	return int(clamp(round(start), STARTER_FATIGUE_START_MIN, STARTER_FATIGUE_START_MAX))


static func starter_stamina_limit_pitches(record: PSPlayerSeasonRecord) -> int:
	var stamina: float = _ability(record, "Pit_Stamina")
	var recovery: float = _ability(record, "Pit_FatigueResist")
	var limit: float = 110.0
	limit += stamina * 9.0
	limit += recovery * 5.0
	return int(clamp(round(limit), STARTER_STAMINA_LIMIT_MIN, STARTER_STAMINA_LIMIT_MAX))


static func starter_complete_game_pitch_limit(record: PSPlayerSeasonRecord) -> int:
	var limit: float = float(starter_stamina_limit_pitches(record)) + 4.0
	return int(clamp(round(limit), STARTER_COMPLETE_GAME_LIMIT_MIN, STARTER_COMPLETE_GAME_LIMIT_MAX))


static func short_relief_target_pitches(_record: PSPlayerSeasonRecord) -> int:
	# 短い救援は1イニング前提。スタミナはロング/回跨ぎ適性で使い、短い救援の目標球数には使わない。
	var workload: float = 22.0
	return int(clamp(round(workload), SHORT_RELIEF_TARGET_MIN, SHORT_RELIEF_TARGET_MAX))


static func long_relief_target_pitches(record: PSPlayerSeasonRecord) -> int:
	var stamina: float = _ability(record, "Pit_Stamina")
	var recovery: float = _ability(record, "Pit_FatigueResist")
	var workload: float = 44.0
	workload += (stamina - 1.0) * 5.0
	workload += recovery * 0.8
	return int(clamp(round(workload), LONG_RELIEF_TARGET_MIN, LONG_RELIEF_TARGET_MAX))


static func create_outing(record: PSPlayerSeasonRecord, role: String) -> Dictionary:
	var resolved_role: String = _normalized_role(role)
	var workload_pitches: int = outing_workload_pitches(record, resolved_role)
	var fatigue_start_pitches: float = PSFatigueCalculator.start_threshold(
		record,
		resolved_role != ROLE_STARTER
	)
	var fatigue_limit_pitches: float = float(workload_pitches)
	if resolved_role == ROLE_STARTER:
		fatigue_limit_pitches = float(max(int(fatigue_start_pitches) + 1, workload_pitches))
	return {
		"record": record,
		"pitcher_id": 0 if record == null else record.player_id,
		"role": resolved_role,
		"workload_pitches": workload_pitches,
		"fatigue_start_pitches": fatigue_start_pitches,
		"fatigue_limit_pitches": fatigue_limit_pitches,
		"fatigue_width": PSFatigueCalculator.width(record),
		"pitches": 0,
		"batters_faced": 0,
		"outs": 0,
		"runs": 0,
		"stress_score": 0.0,
		"trouble_score": 0.0,
		"meltdown_active": false,
		"consecutive_reached": 0,
		"consecutive_count": 0,
	}


static func outing_workload_pitches(record: PSPlayerSeasonRecord, role: String) -> int:
	match _normalized_role(role):
		ROLE_STARTER:
			return starter_stamina_limit_pitches(record)
		ROLE_LONG_RELIEF:
			return long_relief_target_pitches(record)
		_:
			return short_relief_target_pitches(record)


static func plate_context(record: PSPlayerSeasonRecord, usage: Dictionary) -> Dictionary:
	if record == null or usage.is_empty():
		return {}
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	var arsenal: Dictionary = _arsenal_summary_for_usage(record, usage)
	var ratio: float = outing_ratio(record, usage)
	var outing_pitches: int = int(usage.get("pitches", 0))
	var fatigue_factor: float = PSFatigueCalculator.factor_for_outing(record, usage, outing_pitches)
	var fatigue_load: float = (
		1.0 - fatigue_factor
		if role == ROLE_STARTER
		else max(0.0, ratio - 0.82)
	)
	var trouble: float = float(usage.get("trouble_score", 0.0))
	var usage_penalty: int = _in_game_usage_penalty(role, ratio, trouble, fatigue_load)
	var tto_penalty: int = times_through_order_penalty(record, usage, arsenal)
	var arsenal_bonus: int = role_arsenal_bonus(role, arsenal)
	# 球種構成の傾向(微差)。type 別 K寄り/ゴロ寄り/被弾を mastery 加重で集計し中心化済み。
	var arsenal_biases: Dictionary = _arsenal_biases_for_usage(usage, arsenal)
	var stamina_pressure: float = fatigue_load if role == ROLE_STARTER else max(0.0, ratio - 0.92)
	var command_leak: float = clamp(max(0.0, trouble - 3.0) * 0.55 + stamina_pressure * 2.4, 0.0, 5.0)
	var contact_damage: float = clamp(max(0.0, trouble - 3.5) * 0.48 + max(0.0, stamina_pressure - 0.15) * 3.0, 0.0, 5.0)
	return {
		"pitcher_role": role,
		"pitcher_outing_pitches": outing_pitches,
		"pitcher_outing_workload": _usage_workload_pitches(record, usage, role),
		"pitcher_fatigue_ratio": ratio,
		"pitcher_fatigue_factor": fatigue_factor,
		"pitcher_usage_penalty": usage_penalty,
		"pitcher_tto_penalty": tto_penalty,
		"pitcher_arsenal_bonus": arsenal_bonus,
		"pitcher_command_leak": command_leak,
		"pitcher_contact_damage": contact_damage,
		"pitcher_trouble_score": trouble,
		"pitcher_meltdown": trouble >= MELTDOWN_THRESHOLD,
		"pitcher_arsenal_pitch_count": int(arsenal.get("pitch_count", 0)),
		"pitcher_arsenal_effective_count": int(arsenal.get("effective_pitch_count", 0)),
		"pitcher_arsenal_top_two": float(arsenal.get("top_two_average", 0.0)),
		"pitcher_arsenal_third": int(arsenal.get("third_pitch", 0)),
		"pitcher_arsenal_k_bias": float(arsenal_biases.get("k_bias", 0.0)),
		"pitcher_arsenal_gb_bias": float(arsenal_biases.get("gb_bias", 0.0)),
		"pitcher_arsenal_hr_bias": float(arsenal_biases.get("hr_bias", 0.0)),
	}


static func _in_game_usage_penalty(
	role: String,
	ratio: float,
	trouble: float,
	fatigue_load: float
) -> int:
	var penalty: float = 0.0
	if role == ROLE_STARTER:
		if fatigue_load > 0.25:
			penalty += (fatigue_load - 0.25) * 24.0
		if fatigue_load > 0.55:
			penalty += (fatigue_load - 0.55) * 34.0
		if trouble > TROUBLE_ALERT:
			penalty += (trouble - TROUBLE_ALERT) * 1.45
		return int(clamp(round(penalty), 0.0, 42.0))
	var early_line: float = 0.74
	if ratio > early_line:
		penalty += (ratio - early_line) * (18.0 if role == ROLE_STARTER else 24.0)
	if ratio > 1.0:
		penalty += (ratio - 1.0) * (30.0 if role == ROLE_STARTER else 38.0)
	if ratio > 1.15:
		penalty += (ratio - 1.15) * 42.0
	if trouble > TROUBLE_ALERT:
		penalty += (trouble - TROUBLE_ALERT) * 1.45
	return int(clamp(round(penalty), 0.0, 42.0))


static func times_through_order_penalty(
	record: PSPlayerSeasonRecord,
	usage: Dictionary,
	arsenal: Dictionary = {}
) -> int:
	if record == null or usage.is_empty():
		return 0
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	if role != ROLE_STARTER:
		return 0
	var times_seen: int = int(floor(float(usage.get("batters_faced", 0)) / 9.0))
	if times_seen <= 0:
		return 0
	var resolved_arsenal: Dictionary = arsenal if not arsenal.is_empty() else arsenal_summary(record)
	var depth_rating: float = starter_depth_rating(resolved_arsenal)
	var penalty: float = 0.0
	if times_seen >= 1:
		penalty += 1.0
	if times_seen >= 2:
		penalty += 5.5
	if times_seen >= 3:
		penalty += float(times_seen - 2) * 7.0
	penalty -= max(0.0, depth_rating - 1.2) * 1.7857
	penalty += max(0.0, 0.4 - depth_rating) * 1.5625
	return int(clamp(round(penalty), 0.0, 18.0))


static func record_plate_appearance(
	usage: Dictionary,
	_record: PSPlayerSeasonRecord,
	outcome: Dictionary,
	pitch_summary: Dictionary,
	applied: Dictionary,
	bases_before: Array,
	_outs_before: int
) -> void:
	if usage.is_empty():
		return
	var pitches: int = int(pitch_summary.get("pitches", applied.get("pitches", 0)))
	var outs_added: int = int(applied.get("outs", 0))
	var runs: int = int(applied.get("runs", 0))
	var category: String = str(outcome.get("category", "out"))
	var bases: int = int(outcome.get("bases", 0))
	var result: String = str(outcome.get("result", ""))
	var reached: bool = category == "hit" or category == "walk" or category == "hit_by_pitch" or category == "error"

	usage["pitches"] = int(usage.get("pitches", 0)) + pitches
	usage["batters_faced"] = int(usage.get("batters_faced", 0)) + 1
	usage["outs"] = int(usage.get("outs", 0)) + outs_added
	usage["runs"] = int(usage.get("runs", 0)) + runs

	# trouble_score は「今まさに失点が止まらないピンチ」を表す短期指標。1打席ごとの被安打は
	# 球数増(=ratio による降板判定)で既に表現されるので、ここの加点係数は低く抑え、
	# 満塁級の連続出塁が続いたときだけ MELTDOWN(6.5) に達するようにする (単発被弾や散発安打では降ろさない)。
	# 加点(出塁/失点)は控えめ・減点(アウト)は据置で、クリーンな1イニングで trouble がほぼ解消する。
	var trouble_delta: float = 0.0
	if category == "hit":
		trouble_delta += 0.6
		if bases >= 2:
			trouble_delta += 0.32
		if bases >= 4 or result.contains("home_run"):
			trouble_delta += 0.3
	elif category == "walk" or category == "hit_by_pitch":
		trouble_delta += 0.5
	elif category == "error":
		trouble_delta += 0.25
	elif category == "strikeout":
		trouble_delta -= 1.05
	elif category == "double_play":
		trouble_delta -= 1.85
	elif outs_added > 0:
		trouble_delta -= 0.75 * float(outs_added)

	if pitches >= 7:
		trouble_delta += 0.16
	if pitches >= 10:
		trouble_delta += 0.2
	if _has_runner_in_scoring_position(bases_before):
		trouble_delta += 0.22
	if runs > 0:
		trouble_delta += float(runs) * 0.5
	if reached:
		var streak: int = int(usage.get("consecutive_reached", 0)) + 1
		usage["consecutive_reached"] = streak
		if streak >= 2:
			trouble_delta += float(streak - 1) * 0.35
	else:
		usage["consecutive_reached"] = 0

	var quality: Dictionary = outcome.get("contact_quality", {}) as Dictionary
	var physical: Dictionary = outcome.get("physical_traits", {}) as Dictionary
	if bool(physical.get("is_hard_hit", false)):
		trouble_delta += 0.16
	if bool(physical.get("is_barrel", false)):
		trouble_delta += 0.28
	if float(quality.get("exit_velocity", 0.0)) >= 100.0:
		trouble_delta += 0.08

	var trouble: float = clamp(float(usage.get("trouble_score", 0.0)) + trouble_delta, 0.0, TROUBLE_MAX)
	usage["trouble_score"] = trouble
	usage["meltdown_active"] = trouble >= MELTDOWN_THRESHOLD
	usage["stress_score"] = float(usage.get("stress_score", 0.0)) + max(0.0, trouble_delta) + float(pitches) * 0.04


static func finish_half_inning(usage: Dictionary) -> void:
	if usage.is_empty():
		return
	usage["trouble_score"] = clamp(float(usage.get("trouble_score", 0.0)) - 1.25, 0.0, TROUBLE_MAX)
	usage["meltdown_active"] = float(usage.get("trouble_score", 0.0)) >= MELTDOWN_THRESHOLD
	usage["consecutive_reached"] = 0


static func should_pull_for_next_half(record: PSPlayerSeasonRecord, usage: Dictionary, inning: int, runs_allowed: int) -> bool:
	if record == null or usage.is_empty():
		return false
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	var ratio: float = outing_ratio(record, usage)
	var trouble: float = float(usage.get("trouble_score", 0.0))
	var pitches: int = int(usage.get("pitches", 0))
	if role == ROLE_STARTER:
		if inning <= 1:
			return false
		if inning >= 10:
			return true
		if inning >= 9:
			return not _starter_can_chase_complete_game(record, usage, inning, runs_allowed)
		var complete_game_chase: bool = _starter_can_chase_complete_game(record, usage, inning, runs_allowed)
		if _starter_stamina_is_spent(record, usage) and not complete_game_chase:
			return true
		if _starter_next_inning_would_exhaust(record, usage, inning, runs_allowed) and not complete_game_chase:
			return true
		if inning >= 5 and trouble >= MELTDOWN_THRESHOLD:
			return true
		# 失点による回またぎ降板。3失点では降ろさず、4回4失点や終盤4失点から段階的に替える。
		if runs_allowed >= 6:
			return true
		if inning >= 4 and runs_allowed >= 5:
			return true
		if inning == 5 and runs_allowed >= 4:
			return true
		if inning >= 7 and runs_allowed >= 4:
			return true
		return false
	if role == ROLE_LONG_RELIEF:
		var outs: int = int(usage.get("outs", 0))
		if outs >= 6:
			return true
		if outs >= 3 and inning >= 6:
			return true
		return ratio >= 1.0 or (pitches >= 30 and trouble >= MELTDOWN_THRESHOLD) or inning >= 9
	return int(usage.get("outs", 0)) >= 3 or ratio >= 0.95 or pitches >= 28 or trouble >= MELTDOWN_THRESHOLD


static func should_pull_after_plate_appearance(
	record: PSPlayerSeasonRecord,
	usage: Dictionary,
	inning: int,
	outs: int,
	bases: Array,
	runs_allowed: int,
	defense_lead: int
) -> bool:
	if record == null or usage.is_empty() or outs >= 3:
		return false
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	var ratio: float = outing_ratio(record, usage)
	var trouble: float = float(usage.get("trouble_score", 0.0))
	var pitches: int = int(usage.get("pitches", 0))
	var consecutive_reached: int = int(usage.get("consecutive_reached", 0))
	var runners_on: int = _runner_count(bases)
	var high_leverage: bool = inning >= 7 and abs(defense_lead) <= 3

	if role == ROLE_STARTER:
		# イニング途中の交代は「炎上が止まらない」緊急時のみ。通常の交代は回またぎ
		# (should_pull_for_next_half) で判断し、序盤の数失点では立て直しのチャンスを与える。
		var complete_game_chase: bool = _starter_can_chase_complete_game(record, usage, inning, runs_allowed)
		if PSFatigueCalculator.factor_for_outing(record, usage, pitches) <= STARTER_MID_INNING_FATIGUE_FLOOR and not complete_game_chase:
			return true
		if inning <= 4:
			# 序盤は5〜6失点級の炎上が続くときだけ即交代。2回3失点程度では降ろさない。
			if runs_allowed >= 6 and runners_on >= 1:
				return true
			return runs_allowed >= 5 and runners_on >= 2
		# 5回以降のイニング途中交代: 大量失点 / 球数限界+走者 / 満塁級の止まらない連打。
		if inning == 5 and runs_allowed >= 5 and runners_on >= 1:
			return true
		if inning == 5 and runs_allowed >= 4 and runners_on >= 2:
			return true
		if runs_allowed >= 6 and runners_on >= 1:
			return true
		if inning >= 6 and runs_allowed >= 5 and runners_on >= 1:
			return true
		if inning >= 6 and starter_projected_fatigue_factor(record, usage, 8.0) <= 0.20 and runners_on >= 1:
			return true
		if consecutive_reached >= 5 and runners_on >= 2:
			return true
		if trouble >= MELTDOWN_THRESHOLD + 1.5 and runners_on >= 2:
			return true
		return false

	if role == ROLE_LONG_RELIEF:
		if ratio >= 1.05:
			return true
		if pitches >= 42 and trouble >= TROUBLE_ALERT:
			return true
		return trouble >= MELTDOWN_THRESHOLD and runners_on >= 1

	if ratio >= 1.04 or pitches >= 30:
		return true
	if trouble >= MELTDOWN_THRESHOLD:
		return true
	if high_leverage and consecutive_reached >= 3:
		return true
	return false


static func should_pull_when_pitcher_spot_bats(record: PSPlayerSeasonRecord, usage: Dictionary, next_defensive_inning: int, runs_allowed: int) -> bool:
	if record == null or usage.is_empty():
		return false
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	if role != ROLE_STARTER:
		return true
	if next_defensive_inning < 5:
		return should_pull_for_next_half(record, usage, next_defensive_inning, runs_allowed) and float(usage.get("trouble_score", 0.0)) >= MELTDOWN_THRESHOLD
	return should_pull_for_next_half(record, usage, next_defensive_inning, runs_allowed)


static func starter_projected_fatigue_factor(record: PSPlayerSeasonRecord, usage: Dictionary, extra_pitches: float) -> float:
	if record == null or usage.is_empty():
		return 1.0
	var projected_pitches: int = int(round(float(int(usage.get("pitches", 0))) + max(0.0, extra_pitches)))
	return PSFatigueCalculator.factor_for_outing(record, usage, projected_pitches)


static func starter_projected_next_inning_effective_factor(record: PSPlayerSeasonRecord, usage: Dictionary) -> float:
	if record == null or usage.is_empty():
		return 1.0
	var projected: float = starter_projected_fatigue_factor(record, usage, starter_expected_next_inning_pitches(usage))
	return clamp(projected - _starter_next_inning_tto_risk(usage), 0.0, 1.0)


static func starter_expected_next_inning_pitches(usage: Dictionary) -> float:
	if usage.is_empty():
		return STARTER_NEXT_INNING_BASE_PITCHES
	var pitches: int = int(usage.get("pitches", 0))
	var outs: int = int(usage.get("outs", 0))
	var expected: float = STARTER_NEXT_INNING_BASE_PITCHES
	if outs > 0:
		var outing_pitches_per_inning: float = float(pitches) / max(1.0, float(outs)) * 3.0
		expected = lerp(expected, clamp(outing_pitches_per_inning, 12.0, 27.0), 0.35)
	var trouble: float = float(usage.get("trouble_score", 0.0))
	var reached: int = int(usage.get("consecutive_reached", 0))
	expected += max(0.0, trouble - 2.0) * 1.6
	expected += max(0.0, float(reached - 1)) * 1.8
	return clamp(expected, 12.0, 30.0)


static func _starter_stamina_is_spent(record: PSPlayerSeasonRecord, usage: Dictionary) -> bool:
	return PSFatigueCalculator.factor_for_outing(record, usage) <= STARTER_CURRENT_FATIGUE_FLOOR


static func _starter_next_inning_would_exhaust(record: PSPlayerSeasonRecord, usage: Dictionary, inning: int, runs_allowed: int) -> bool:
	if inning <= 4:
		return false
	var projected: float = starter_projected_next_inning_effective_factor(record, usage)
	return projected <= _starter_projected_fatigue_floor(inning, runs_allowed)


static func _starter_projected_fatigue_floor(inning: int, runs_allowed: int) -> float:
	var floor_value: float = 0.30
	if inning >= 6:
		floor_value = 0.74
	if inning >= 7:
		floor_value = 0.58
	if inning >= 8:
		floor_value = 0.62
	if runs_allowed >= 3:
		floor_value += 0.08
	return floor_value


static func _starter_next_inning_tto_risk(usage: Dictionary) -> float:
	if usage.is_empty():
		return 0.0
	var projected_batters: float = float(int(usage.get("batters_faced", 0))) + STARTER_NEXT_INNING_PROJECTED_BATTERS
	var risk: float = max(0.0, projected_batters - STARTER_TTO_HOOK_START_BF) * STARTER_TTO_HOOK_RISK_PER_BF
	return clamp(risk, 0.0, STARTER_TTO_HOOK_RISK_MAX)


static func _starter_can_chase_complete_game(record: PSPlayerSeasonRecord, usage: Dictionary, inning: int, runs_allowed: int) -> bool:
	if record == null or usage.is_empty():
		return false
	if inning < 8 or inning >= 10:
		return false
	var max_runs: int = 1
	if inning >= 9:
		max_runs = 2
	if runs_allowed > max_runs:
		return false
	if float(usage.get("trouble_score", 0.0)) >= TROUBLE_ALERT:
		return false
	var outs_recorded: int = int(usage.get("outs", 0))
	var remaining_outs: int = max(0, 27 - outs_recorded)
	if inning >= 9:
		remaining_outs = min(remaining_outs, 3)
	elif inning == 8:
		remaining_outs = min(remaining_outs, 6)
	elif inning == 7:
		remaining_outs = min(remaining_outs, 9)
	else:
		remaining_outs = min(remaining_outs, 12)
	var projected_pitches: float = float(int(usage.get("pitches", 0))) + float(remaining_outs) * STARTER_COMPLETE_GAME_PITCHES_PER_OUT
	if projected_pitches > float(starter_complete_game_pitch_limit(record)):
		return false
	return PSFatigueCalculator.factor_for_outing(record, usage, int(round(projected_pitches))) >= STARTER_COMPLETE_GAME_FATIGUE_FLOOR


static func post_game_fatigue_gain(record: PSPlayerSeasonRecord, usage: Dictionary) -> int:
	if record == null or usage.is_empty():
		return 0
	var pitches: int = int(usage.get("pitches", 0))
	if pitches <= 0:
		return 0
	var role: String = _normalized_role(str(usage.get("role", _role_from_record(record))))
	var workload: float = float(max(1, _usage_workload_pitches(record, usage, role)))
	var stress: float = float(usage.get("stress_score", 0.0))
	var consecutive_count: int = int(usage.get("consecutive_count", 0))
	var outs: int = int(usage.get("outs", 0))
	var extra_inning_segments: int = max(0, int(ceil(float(max(0, outs)) / 3.0)) - 1)
	var gain: float
	if role == ROLE_STARTER:
		gain = float(pitches) * (100.0 / workload)
		gain += stress * 0.38
		gain += max(0.0, float(pitches) / workload - 1.0) * 24.0
		return int(clamp(round(gain), 18.0, 165.0))
	if role == ROLE_LONG_RELIEF:
		gain = float(pitches) * (60.0 / workload) * 1.04
		gain += stress * 0.44
		gain += consecutive_appearance_fatigue(consecutive_count)
		gain += float(extra_inning_segments) * 7.0
		return int(clamp(round(gain), 12.0, 100.0))
	gain = float(pitches) * (22.0 / workload) * 0.96
	gain += stress * 0.36
	gain += consecutive_appearance_fatigue(consecutive_count)
	gain += float(extra_inning_segments) * 14.0
	return int(clamp(round(gain), 6.0, 52.0))


static func daily_recovery_amount(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	var recovery: float = _ability(record, "Pit_FatigueResist")
	var stamina: float = _ability(record, "Pit_Stamina")
	if _role_from_record(record) == ROLE_STARTER:
		var starter_recovery: float = 17.0 + recovery * 1.6 + stamina * 0.5
		return int(clamp(round(starter_recovery), 12.0, 25.0))
	var reliever_recovery: float = 16.0 + recovery * 2.25 + stamina * 0.6
	return int(clamp(round(reliever_recovery), 10.0, 29.0))


static func reliever_selection_score(
	record: PSPlayerSeasonRecord,
	prefer_long: bool,
	inning: int,
	close_game: bool,
	current_day: int = 0,
	team_games_played_before: int = 0
) -> float:
	if record == null:
		return -999999.0
	var fatigue_penalty: float = float(record.fatigue) * 1.15
	var score: float = float(PlayerValueEvaluator.pitching_score_without_fatigue(record)) - fatigue_penalty
	var arsenal: Dictionary = arsenal_summary(record)
	var next_streak: int = next_consecutive_appearance_count(record, team_games_played_before)
	if next_streak >= 3:
		score -= 120.0 + float(next_streak - 3) * 70.0
	if recently_returned_from_injury(record, current_day, INJURY_RETURN_SOFT_REST_DAYS):
		score -= 90.0
	if prefer_long:
		score += _ability(record, "Pit_Stamina") * 25.0
		score += _ability(record, "Pit_FatigueResist") * 8.0
		score += starter_depth_rating(arsenal) * 13.0
		score += float(arsenal.get("effective_pitch_count", 0)) * 18.0
		if record.role == "closer":
			score -= 125.0
	else:
		score += reliever_finish_rating(arsenal) * 15.0
		if close_game:
			score += _ability(record, "Pit_BBPrevent") * 4.4
		if inning >= 9 and record.role == "closer":
			score += 55.0
	return score


static func is_reliever_available(
	record: PSPlayerSeasonRecord,
	allow_tired: bool = false,
	current_day: int = 0,
	team_games_played_before: int = 0
) -> bool:
	if record == null or record.injury_days > 0:
		return false
	if record.fatigue >= RELIEVER_EMERGENCY_FATIGUE_LIMIT:
		return false
	if recently_returned_from_injury(record, current_day, INJURY_RETURN_HARD_REST_DAYS):
		return false
	if allow_tired:
		return true
	if record.fatigue >= RELIEVER_FATIGUE_LIMIT:
		return false
	if recently_returned_from_injury(record, current_day, INJURY_RETURN_SOFT_REST_DAYS):
		return false
	if next_consecutive_appearance_count(record, team_games_played_before) >= 3:
		return false
	return true


static func outing_ratio(record: PSPlayerSeasonRecord, usage: Dictionary) -> float:
	if record == null or usage.is_empty():
		return 0.0
	var workload: int = _usage_workload_pitches(record, usage, str(usage.get("role", "")))
	return float(usage.get("pitches", 0)) / float(max(1, workload))


static func _usage_workload_pitches(record: PSPlayerSeasonRecord, usage: Dictionary, role: String) -> int:
	if usage.has("workload_pitches"):
		return int(usage.get("workload_pitches", 0))
	return outing_workload_pitches(record, role)


static func record_runner_event_result(usage: Dictionary, outs_added: int, runs: int, earned_runs: int) -> void:
	if usage.is_empty():
		return
	if outs_added > 0:
		usage["outs"] = int(usage.get("outs", 0)) + outs_added
	if runs > 0:
		usage["runs"] = int(usage.get("runs", 0)) + runs
		usage["stress_score"] = float(usage.get("stress_score", 0.0)) + float(runs) * 0.85
		usage["trouble_score"] = clamp(float(usage.get("trouble_score", 0.0)) + float(runs) * 0.45, 0.0, TROUBLE_MAX)
	if earned_runs > 0:
		usage["earned_runs"] = int(usage.get("earned_runs", 0)) + earned_runs


static func consecutive_appearance_fatigue(previous_consecutive_count: int) -> float:
	var count: int = max(0, previous_consecutive_count)
	var gain: float = float(count) * 7.0
	if count >= 2:
		gain += float(count - 1) * 14.0
	if count >= 3:
		gain += float(count - 2) * 18.0
	return gain


static func next_consecutive_appearance_count(record: PSPlayerSeasonRecord, team_games_played_before: int) -> int:
	if record == null:
		return 1
	if team_games_played_before > 0 and record.last_pitched_team_game == team_games_played_before:
		return max(1, record.consecutive_appearances + 1)
	return 1


static func recently_returned_from_injury(record: PSPlayerSeasonRecord, current_day: int, rest_days: int) -> bool:
	if record == null or current_day <= 0 or record.injury_return_day <= 0:
		return false
	var days_since_return: int = current_day - record.injury_return_day
	return days_since_return >= 0 and days_since_return <= rest_days


# z から合成した mastery 値 (降順前のプロファイル順) を返す。PSPitchTypes.derive_from_z が
# arsenal 未保持の投手のアーセナルを派生するときの単一ソース。従来の _pitch_values_from_profile を踏襲。
static func synth_mastery_values(record: PSPlayerSeasonRecord) -> Array:
	if record == null:
		return []
	return (pitcher_profile(record).get("pitch_values", []) as Array).duplicate()


static func _arsenal_summary_for_usage(
	record: PSPlayerSeasonRecord,
	usage: Dictionary
) -> Dictionary:
	if usage.has(USAGE_ARSENAL_CACHE_KEY):
		return usage[USAGE_ARSENAL_CACHE_KEY] as Dictionary
	var summary: Dictionary = arsenal_summary(record)
	usage[USAGE_ARSENAL_CACHE_KEY] = summary
	return summary


static func _arsenal_biases_for_usage(
	usage: Dictionary,
	arsenal: Dictionary
) -> Dictionary:
	if usage.has(USAGE_ARSENAL_BIASES_CACHE_KEY):
		return usage[USAGE_ARSENAL_BIASES_CACHE_KEY] as Dictionary
	var biases: Dictionary = PSPitchTypes.aggregate_biases(arsenal.get("arsenal", []) as Array)
	usage[USAGE_ARSENAL_BIASES_CACHE_KEY] = biases
	return biases


static func arsenal_summary(record: PSPlayerSeasonRecord) -> Dictionary:
	if record == null:
		return {
			"pitch_count": 0,
			"effective_pitch_count": 0,
			"top_pitch": 0.0,
			"second_pitch": -0.4,
			"third_pitch": NO_THIRD_PITCH,
			"top_two_average": -0.2,
			"pitch_values": [],
		}
	var profile: Dictionary = pitcher_profile(record)
	# 実 arsenal (保存済み or z 派生) の mastery を pitch_values として採用する。
	# derive-on-read は synth_mastery_values と同値なので、従来の役割適性挙動を保つ。
	var arsenal_entries: Array = (
		record.arsenal_snapshot
		if not record.arsenal_snapshot.is_empty()
		else PSPitchTypes.derive_from_z(record, profile.get("pitch_values", []) as Array)
	)
	var values: Array = []
	for entry_value in arsenal_entries:
		var entry: Dictionary = entry_value as Dictionary
		if entry != null:
			values.append(float(entry.get("mastery", 0.0)))
	values.sort()
	values.reverse()
	var pitch_count: int = values.size()
	var effective_count: int = 0
	for value in values:
		if float(value) >= EFFECTIVE_PITCH_Z:
			effective_count += 1
	var top_pitch: float = float(values[0]) if values.size() >= 1 else 0.0
	var second_pitch: float = float(values[1]) if values.size() >= 2 else maxf(-1.2, top_pitch - 1.2)
	var third_pitch: float = float(values[2]) if values.size() >= 3 else NO_THIRD_PITCH
	var result: Dictionary = {
		"pitch_count": pitch_count,
		"effective_pitch_count": effective_count,
		"top_pitch": top_pitch,
		"second_pitch": second_pitch,
		"third_pitch": third_pitch,
		"top_two_average": (top_pitch + second_pitch) / 2.0,
		"pitch_values": values,
		"arsenal": arsenal_entries,
	}
	for key_value in profile.keys():
		var key: String = str(key_value)
		if not result.has(key):
			result[key] = profile[key_value]
	return result


static func pitcher_profile(record: PSPlayerSeasonRecord) -> Dictionary:
	if record == null:
		return {
			"arsenal_depth": 0.0,
			"primary_pitch": 0.0,
			"secondary_pitch": -0.4,
			"command_profile": 0.0,
			"miss_bat_profile": 0.0,
			"contact_suppress_profile": 0.0,
			"stamina_profile": 0.0,
			"recovery_profile": 0.0,
			"pitch_values": [],
		}
	var primary: float = _profile_grade(record, PRIMARY_PITCH_WEIGHTS)
	var secondary: float = _profile_grade(record, SECONDARY_PITCH_WEIGHTS)
	var command: float = _profile_grade(record, COMMAND_PROFILE_WEIGHTS)
	var miss_bat: float = _profile_grade(record, MISS_BAT_PROFILE_WEIGHTS)
	var contact_suppress: float = _profile_grade(record, CONTACT_SUPPRESS_PROFILE_WEIGHTS)
	var stamina: float = _profile_grade(record, STAMINA_PROFILE_WEIGHTS)
	var recovery: float = _profile_grade(record, RECOVERY_PROFILE_WEIGHTS)
	var depth: float = _profile_grade(record, ARSENAL_DEPTH_WEIGHTS)
	var profile: Dictionary = {
		"arsenal_depth": depth,
		"primary_pitch": primary,
		"secondary_pitch": secondary,
		"command_profile": command,
		"miss_bat_profile": miss_bat,
		"contact_suppress_profile": contact_suppress,
		"stamina_profile": stamina,
		"recovery_profile": recovery,
	}
	profile["pitch_values"] = _pitch_values_from_profile(record, profile)
	return profile


static func starter_depth_rating(arsenal: Dictionary) -> float:
	var effective_count: int = int(arsenal.get("effective_pitch_count", 0))
	var top_pitch: float = float(arsenal.get("top_pitch", 0.0))
	var second_pitch: float = float(arsenal.get("second_pitch", -0.4))
	var third_pitch: float = float(arsenal.get("third_pitch", NO_THIRD_PITCH))
	if third_pitch <= NO_THIRD_PITCH + 1.0:
		return minf(top_pitch, second_pitch) - 0.96
	var top_three_average: float = (top_pitch + second_pitch + third_pitch) / 3.0
	return top_three_average + float(max(0, effective_count - 3)) * 0.4


static func reliever_finish_rating(arsenal: Dictionary) -> float:
	var top_two: float = float(arsenal.get("top_two_average", 0.0))
	var top_pitch: float = float(arsenal.get("top_pitch", 0.0))
	return top_two * 0.75 + top_pitch * 0.25


static func role_arsenal_bonus(role: String, arsenal: Dictionary) -> int:
	if _normalized_role(role) == ROLE_STARTER:
		var depth: float = starter_depth_rating(arsenal)
		return int(clamp(round((depth - 0.64) * 1.6667), -5.0, 7.0))
	var finish: float = reliever_finish_rating(arsenal)
	return int(clamp(round((finish - 0.64) * 1.9231), -5.0, 8.0))


static func _pitch_values_from_profile(record: PSPlayerSeasonRecord, profile: Dictionary) -> Array:
	var primary: float = float(profile.get("primary_pitch", 0.0))
	var secondary: float = float(profile.get("secondary_pitch", 0.0))
	var command: float = float(profile.get("command_profile", 0.0))
	var miss_bat: float = float(profile.get("miss_bat_profile", 0.0))
	var contact_suppress: float = float(profile.get("contact_suppress_profile", 0.0))
	var stamina: float = float(profile.get("stamina_profile", 0.0))
	var recovery: float = float(profile.get("recovery_profile", 0.0))
	var depth: float = float(profile.get("arsenal_depth", 0.0))
	var is_starter: bool = _role_from_record(record) == ROLE_STARTER

	var values: Array = []
	values.append(_pitch_grade(primary * 0.54 + miss_bat * 0.24 + command * 0.12 + contact_suppress * 0.10 + (0.12 if not is_starter else 0.0)))
	values.append(_pitch_grade(secondary * 0.48 + contact_suppress * 0.24 + command * 0.16 + miss_bat * 0.12 - 0.16))

	if is_starter or depth >= 0.56:
		values.append(_pitch_grade(command * 0.34 + contact_suppress * 0.22 + stamina * 0.18 + secondary * 0.16 + recovery * 0.10 - 0.32))
	if is_starter and depth >= 0.8:
		values.append(_pitch_grade(depth * 0.32 + recovery * 0.22 + stamina * 0.20 + command * 0.14 + contact_suppress * 0.12 - 0.56))
	if is_starter and depth >= 2.08:
		values.append(_pitch_grade(depth * 0.34 + stamina * 0.24 + recovery * 0.18 + secondary * 0.14 + command * 0.10 - 0.80))
	return values


static func _profile_grade(record: PSPlayerSeasonRecord, weights: Dictionary) -> float:
	return clampf(_weighted_z(record, weights), -4.0, 4.0)


static func _weighted_z(record: PSPlayerSeasonRecord, weights: Dictionary) -> float:
	if record == null:
		return 0.0
	var weighted_sum: float = 0.0
	var total_weight: float = 0.0
	for key_value in weights.keys():
		var key: String = str(key_value)
		var weight: float = float(weights.get(key_value, 0.0))
		weighted_sum += record.z_ability(key, 0.0) * weight
		total_weight += absf(weight)
	if total_weight <= 0.0:
		return 0.0
	return weighted_sum / total_weight


static func _pitch_grade(value: float) -> float:
	return clampf(value, -2.0, 2.8)


static func _role_from_record(record: PSPlayerSeasonRecord) -> String:
	if record != null and record.is_starter_pitcher():
		return ROLE_STARTER
	return ROLE_SHORT_RELIEF


static func _normalized_role(role: String) -> String:
	match role:
		ROLE_STARTER:
			return ROLE_STARTER
		ROLE_LONG_RELIEF:
			return ROLE_LONG_RELIEF
		_:
			return ROLE_SHORT_RELIEF


static func _has_runner_in_scoring_position(bases: Array) -> bool:
	return bases.size() >= 3 and (bases[1] != null or bases[2] != null)


static func _runner_count(bases: Array) -> int:
	var count: int = 0
	for base_value in bases:
		if base_value != null:
			count += 1
	return count


static func _ability(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	return record.z_ability(key, default_value)
