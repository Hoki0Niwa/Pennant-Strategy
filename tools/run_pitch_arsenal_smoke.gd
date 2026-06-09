extends Node

# 変化球(アーセナル)システムの headless smoke。
#  1) 生成: スタミナが高いほど球種数が多い / 直球を必ず含む / mastery が stuff z にアンカー。
#  2) derive-on-read: arsenal 未保持の record でも z から *決定論的* に派生 (2本以上 + 直球)。
#  3) 集計傾向: type 偏りで k/gb/hr bias が正しい向きに動く + 標準構成は中心化(≈0)。
#  4) K logit 配線が「微差」: arsenal_k_bias で K 確率が *わずかに* 上がる。
#  5) 打球角度(LA) 配線が「微差」: ゴロ寄り傾向で平均 LA がわずかに下がる。

const PSPaProbabilityCalculator = preload("res://services/simulation/pa/pa_probability_calculator.gd")
const PSContactQualityModel = preload("res://services/simulation/pa/contact_quality_model.gd")


func _ready() -> void:
	var failures: Array = []
	failures.append_array(_test_generation())
	failures.append_array(_test_derive_on_read())
	failures.append_array(_test_aggregate_direction())
	failures.append_array(_test_k_logit_wiring())
	failures.append_array(_test_la_wiring())
	failures.append_array(_test_grades())

	if failures.is_empty():
		print("Pitch arsenal smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Pitch arsenal smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_generation() -> Array:
	var failures: Array = []
	var ace_z: Dictionary = _pitcher_z({"Pit_KCreate": 80, "Pit_BarrelDeny": 76, "Pit_EdgeRate": 70, "Pit_Stamina": 82, "Pit_LoftControl": 60})
	var relief_z: Dictionary = _pitcher_z({"Pit_KCreate": 72, "Pit_BarrelDeny": 66, "Pit_EdgeRate": 74, "Pit_Stamina": 30, "Pit_LoftControl": 55})
	var weak_z: Dictionary = _pitcher_z({"Pit_KCreate": 38, "Pit_BarrelDeny": 38, "Pit_EdgeRate": 40, "Pit_Stamina": 50, "Pit_LoftControl": 42})
	var samples: int = 200
	var ace_size_sum: float = 0.0
	var relief_size_sum: float = 0.0
	var ace_top_sum: float = 0.0
	var weak_top_sum: float = 0.0
	var no_fastball: int = 0
	var out_of_range: int = 0
	for _i in range(samples):
		var ace: Array = OffseasonService.generated_arsenal(1, ace_z)
		var relief: Array = OffseasonService.generated_arsenal(1, relief_z)
		var weak: Array = OffseasonService.generated_arsenal(1, weak_z)
		ace_size_sum += float(ace.size())
		relief_size_sum += float(relief.size())
		ace_top_sum += _top_mastery(ace)
		weak_top_sum += _top_mastery(weak)
		for arsenal in [ace, relief, weak]:
			if not _has_fastball(arsenal):
				no_fastball += 1
			for entry_value in arsenal:
				var mastery: float = float((entry_value as Dictionary).get("mastery", 0.0))
				if mastery < -2.001 or mastery > 2.801:
					out_of_range += 1
	var ace_size: float = ace_size_sum / float(samples)
	var relief_size: float = relief_size_sum / float(samples)
	var ace_top: float = ace_top_sum / float(samples)
	var weak_top: float = weak_top_sum / float(samples)

	if ace_size <= relief_size + 0.5:
		failures.append("arsenal size not stamina-correlated: ace=%.2f relief=%.2f" % [ace_size, relief_size])
	if no_fastball > 0:
		failures.append("generated arsenals missing a fastball: %d" % no_fastball)
	if out_of_range > 0:
		failures.append("generated mastery out of [-2,2.8]: %d" % out_of_range)
	if ace_top <= weak_top + 0.3:
		failures.append("top mastery not stuff-anchored: ace=%.2f weak=%.2f" % [ace_top, weak_top])
	if not OffseasonService.generated_arsenal(3, {}).is_empty():
		failures.append("fielder should generate no arsenal")

	print("[arsenal] gen ace_size=%.2f relief_size=%.2f ace_top=%.2f weak_top=%.2f" % [ace_size, relief_size, ace_top, weak_top])
	return failures


func _test_derive_on_read() -> Array:
	var failures: Array = []
	var record: PSPlayerSeasonRecord = _build_pitcher(-810001, {
		"Pit_KCreate": 70, "Pit_BBPrevent": 60, "Pit_ImpactLimit": 64, "Pit_LoftControl": 58,
		"Pit_BarrelDeny": 66, "Pit_Efficiency": 60, "Pit_Stamina": 72, "Pit_FatigueResist": 64,
		"Pit_HoldRunner": 50, "Pit_EdgeRate": 62,
	})
	var derived_a: Array = record.arsenal_or_derived()
	var derived_b: Array = record.arsenal_or_derived()
	if derived_a.size() < 2:
		failures.append("derive-on-read returned fewer than 2 pitches: %d" % derived_a.size())
	if not _has_fastball(derived_a):
		failures.append("derived arsenal missing a fastball")
	if JSON.stringify(derived_a) != JSON.stringify(derived_b):
		failures.append("derive-on-read is not deterministic")

	print("[arsenal] derived=%s" % JSON.stringify(derived_a))
	return failures


func _test_aggregate_direction() -> Array:
	var failures: Array = []
	var slider_heavy: Array = [
		{"type": PSPitchTypes.SLIDER, "mastery": 1.6},
		{"type": PSPitchTypes.FORK, "mastery": 1.0},
		{"type": PSPitchTypes.FOUR_SEAM, "mastery": 0.6},
	]
	var sinker_heavy: Array = [
		{"type": PSPitchTypes.SINKER, "mastery": 1.6},
		{"type": PSPitchTypes.TWO_SEAM, "mastery": 1.0},
		{"type": PSPitchTypes.SLIDER, "mastery": 0.4},
	]
	var four_seam_heavy: Array = [
		{"type": PSPitchTypes.FOUR_SEAM, "mastery": 1.6},
		{"type": PSPitchTypes.SLIDER, "mastery": 0.6},
		{"type": PSPitchTypes.CUTTER, "mastery": 0.2},
	]
	var balanced: Array = [
		{"type": PSPitchTypes.FOUR_SEAM, "mastery": 1.2},
		{"type": PSPitchTypes.SLIDER, "mastery": 0.6},
		{"type": PSPitchTypes.CHANGEUP, "mastery": 0.1},
		{"type": PSPitchTypes.CURVE, "mastery": -0.2},
	]
	var sb: Dictionary = PSPitchTypes.aggregate_biases(slider_heavy)
	var kb: Dictionary = PSPitchTypes.aggregate_biases(sinker_heavy)
	var fb: Dictionary = PSPitchTypes.aggregate_biases(four_seam_heavy)
	var bb: Dictionary = PSPitchTypes.aggregate_biases(balanced)

	if float(sb.get("k_bias", 0.0)) <= float(kb.get("k_bias", 0.0)):
		failures.append("slider/fork not more K-leaning than sinker")
	if float(kb.get("gb_bias", 0.0)) <= float(fb.get("gb_bias", 0.0)):
		failures.append("sinker not more GB-leaning than four-seam")
	if float(fb.get("hr_bias", 0.0)) <= float(kb.get("hr_bias", 0.0)):
		failures.append("four-seam not more HR-leaning than sinker")
	# 標準構成は中心化されほぼ0。
	if absf(float(bb.get("k_bias", 0.0))) > 0.15 or absf(float(bb.get("gb_bias", 0.0))) > 0.15 or absf(float(bb.get("hr_bias", 0.0))) > 0.15:
		failures.append("balanced arsenal not centered: %s" % JSON.stringify(bb))

	print("[arsenal] bias slider=%s sinker=%s four_seam=%s balanced=%s" % [
		JSON.stringify(sb), JSON.stringify(kb), JSON.stringify(fb), JSON.stringify(bb),
	])
	return failures


func _test_k_logit_wiring() -> Array:
	var failures: Array = []
	var hi: Dictionary = {"batter_z": {}, "pitcher_z": {}, "catcher_z": {}, "arsenal_k_bias": 0.6}
	var lo: Dictionary = {"batter_z": {}, "pitcher_z": {}, "catcher_z": {}, "arsenal_k_bias": -0.2}
	var p_hi: float = float(PSPaProbabilityCalculator.probabilities(PSPaProbabilityCalculator.build_weights(hi)).get(PSPaProbabilityCalculator.OUTCOME_STRIKEOUT, 0.0))
	var p_lo: float = float(PSPaProbabilityCalculator.probabilities(PSPaProbabilityCalculator.build_weights(lo)).get(PSPaProbabilityCalculator.OUTCOME_STRIKEOUT, 0.0))
	if p_hi <= p_lo:
		failures.append("arsenal_k_bias did not raise K probability: hi=%.4f lo=%.4f" % [p_hi, p_lo])
	if p_hi - p_lo > 0.05:
		failures.append("K tendency effect too large (should be 微差): dP=%.4f" % (p_hi - p_lo))

	print("[arsenal] K wiring p_hi=%.4f p_lo=%.4f dP=%.4f" % [p_hi, p_lo, p_hi - p_lo])
	return failures


func _test_la_wiring() -> Array:
	var failures: Array = []
	var batter: PSPlayerSeasonRecord = _build_batter(-820001)
	var pitcher: PSPlayerSeasonRecord = _build_pitcher(-820002, {})
	var pitch_outcome: Dictionary = {
		"in_zone": true, "location_height": "middle", "two_strike_protective": false,
		"protective_out": false, "pitch_velocity": 142,
	}
	var precomp_base: Dictionary = {
		"batter_hr_z": 0.0, "pitcher_stuff_z": 0.0, "batter_contact_z": 0.0, "batter_gap_z": 0.0,
		"batter_avoid_k_z": 0.0, "batter_fatigue": 0, "batter_is_pitcher": false, "pitcher_contact_damage": 0.0,
	}
	var hi: Dictionary = precomp_base.duplicate(true)
	hi["pitcher_gb_bias"] = 1.0
	var lo: Dictionary = precomp_base.duplicate(true)
	lo["pitcher_gb_bias"] = -1.0
	var n: int = 3000
	var sum_hi: float = 0.0
	var sum_lo: float = 0.0
	for _i in range(n):
		sum_hi += float(PSContactQualityModel.generate(batter, pitcher, pitch_outcome, {}, hi).get("launch_angle", 0.0))
		sum_lo += float(PSContactQualityModel.generate(batter, pitcher, pitch_outcome, {}, lo).get("launch_angle", 0.0))
	var mean_hi: float = sum_hi / float(n)
	var mean_lo: float = sum_lo / float(n)
	var diff: float = mean_lo - mean_hi
	if mean_hi >= mean_lo:
		failures.append("GB bias did not lower LA: hi=%.2f lo=%.2f" % [mean_hi, mean_lo])
	if diff < 1.0 or diff > 5.0:
		failures.append("LA shift outside expected 微差 band: %.2f" % diff)

	print("[arsenal] LA wiring mean_hi=%.2f mean_lo=%.2f diff=%.2f" % [mean_hi, mean_lo, diff])
	return failures


func _test_grades() -> Array:
	var failures: Array = []
	var cases: Array = [[2.0, "S"], [1.6, "S"], [1.5, "A"], [0.8, "A"], [0.7, "B"], [0.0, "B"], [-0.1, "C"], [-0.8, "C"], [-0.9, "D"]]
	for case_value in cases:
		var case_row: Array = case_value as Array
		var got: String = PSPitchTypes.mastery_grade(float(case_row[0]))
		if got != str(case_row[1]):
			failures.append("grade(%.2f)=%s expected %s" % [float(case_row[0]), got, str(case_row[1])])
	# arsenal_line: mastery 降順 + グレード付き。
	var line: String = PSPitchTypes.arsenal_line([
		{"type": PSPitchTypes.SLIDER, "mastery": 0.2},
		{"type": PSPitchTypes.FORK, "mastery": 1.8},
	])
	if not line.begins_with("フォークS"):
		failures.append("arsenal_line not desc/graded: %s" % line)
	if PSPitchTypes.arsenal_line([]) != "":
		failures.append("empty arsenal_line should be blank")

	print("[arsenal] grades line=%s" % line)
	return failures


# --- helpers ---

func _pitcher_z(displays: Dictionary) -> Dictionary:
	var z: Dictionary = {}
	for key_value in PSPlayer.Z_PITCHER_ABILITY_KEYS.keys():
		var key: String = str(key_value)
		z[key] = PSAbilityScale.display_to_z(int(displays.get(key, 50)))
	return z


func _build_pitcher(player_id: int, displays: Dictionary) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = 1
	record.role = "starter"
	record.throwing_hand = "R"
	record.batting_side = "R"
	record.z_abilities_snapshot = _pitcher_z(displays)
	return record


func _build_batter(player_id: int) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = 7
	record.role = "fielder"
	record.throwing_hand = "R"
	record.batting_side = "R"
	record.z_abilities_snapshot = {}
	return record


func _top_mastery(arsenal: Array) -> float:
	var top: float = -99.0
	for entry_value in arsenal:
		top = maxf(top, float((entry_value as Dictionary).get("mastery", -99.0)))
	return top


func _has_fastball(arsenal: Array) -> bool:
	for entry_value in arsenal:
		if PSPitchTypes.FASTBALL_TYPES.has(str((entry_value as Dictionary).get("type", ""))):
			return true
	return false
