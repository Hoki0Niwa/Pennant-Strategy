extends Node

const Offseason = preload("res://services/season/offseason_service.gd")
const DraftService = preload("res://services/season/draft_service.gd")


func _ready() -> void:
	Rng.set_seed_value(20260527)
	var ok: bool = true

	var exp18: float = Offseason.expected_development_score_bonus(18, 6)
	var exp23: float = Offseason.expected_development_score_bonus(23, 6)
	var exp26: float = Offseason.expected_development_score_bonus(26, 6)
	var exp35: float = Offseason.expected_development_score_bonus(35, 6)
	if not (exp18 > exp23 and exp23 > exp26 and exp26 > exp35):
		push_error("Development expectation curve is not ordered: 18=%f 23=%f 26=%f 35=%f" % [exp18, exp23, exp26, exp35])
		ok = false
	if not _test_growth_curve():
		ok = false

	var player: PSPlayer = _make_player(900001, 19, 3)
	var before: int = Offseason.player_value_score(player)
	var result: Dictionary = Offseason.process_growth_decay([player])
	var after: int = Offseason.player_value_score(player)
	var kind_counts: Dictionary = result.get("growth_kind_counts", {}) as Dictionary
	if kind_counts.is_empty():
		push_error("Growth result did not include kind counts")
		ok = false
	if before <= 0 or after <= 0:
		push_error("Value score did not evaluate: before=%d after=%d" % [before, after])
		ok = false

	if not _test_aptitude_growth():
		ok = false

	var pool: Array = DraftService._generate_candidate_pool(400)
	if pool.is_empty():
		push_error("Draft candidate pool was empty")
		ok = false
	for row in pool:
		var candidate: Dictionary = row as Dictionary
		var template: Dictionary = candidate.get("player_template", {}) as Dictionary
		if (template.get("z_abilities", {}) as Dictionary).is_empty():
			push_error("Draft candidate missing z_abilities")
			ok = false
			break
		if template.has("batting_abilities") or template.has("pitching_abilities") or template.has("fielding_abilities"):
			push_error("Draft candidate still carries legacy ability dictionaries")
			ok = false
			break
		if not candidate.has("growth_expectation") or not candidate.has("future_value"):
			push_error("Draft candidate missing growth-aware draft fields")
			ok = false
			break
		if str(candidate.get("source_type", "")) == "overseas_school":
			push_error("Draft candidate should not use overseas_school source_type")
			ok = false
			break
		if bool(candidate.get("foreign_player", false)) or bool(template.get("foreign_player", false)):
			push_error("Draft candidate should not be marked as foreign_player")
			ok = false
			break

	print("Offseason development smoke: %s exp18=%.2f exp23=%.2f exp26=%.2f exp35=%.2f score=%d->%d candidates=%d" % [
		"OK" if ok else "FAILED",
		exp18,
		exp23,
		exp26,
		exp35,
		before,
		after,
		pool.size(),
	])
	get_tree().quit(0 if ok else 1)


func _test_growth_curve() -> bool:
	var ok: bool = true
	var age_18: Dictionary = Offseason._growth_kind_probabilities(18)
	var age_23: Dictionary = Offseason._growth_kind_probabilities(23)
	var age_35: Dictionary = Offseason._growth_kind_probabilities(35)
	var age_40: Dictionary = Offseason._growth_kind_probabilities(40)
	if not _probabilities_match(age_18, {"major_decline": 0.0, "decline": 0.0, "stagnation": 40.0, "growth": 59.0, "awakening": 1.0}):
		push_error("Growth age 18 curve mismatch: %s" % str(age_18))
		ok = false
	if not _probabilities_match(age_23, {"major_decline": 0.0, "decline": 0.0, "stagnation": 39.0, "growth": 60.0, "awakening": 1.0}):
		push_error("Growth age 23 curve mismatch: %s" % str(age_23))
		ok = false
	if not _probabilities_match(age_35, {"major_decline": 18.0, "decline": 50.0, "stagnation": 30.0, "growth": 2.0, "awakening": 0.0}):
		push_error("Growth age 35 curve mismatch: %s" % str(age_35))
		ok = false
	if not _probabilities_match(age_40, {"major_decline": 35.0, "decline": 60.0, "stagnation": 5.0, "growth": 0.0, "awakening": 0.0}):
		push_error("Growth age 40 curve mismatch: %s" % str(age_40))
		ok = false
	return ok


func _probabilities_match(actual: Dictionary, expected: Dictionary) -> bool:
	for key in expected.keys():
		if not is_equal_approx(float(actual.get(key, -1.0)), float(expected[key])):
			return false
	return true


# 守備適性のオフ成長: 本職 +CAMP_PRIMARY_APTITUDE_GAIN、別ポジは守備イニング比例。上限 100。
func _test_aptitude_growth() -> bool:
	var ok: bool = true

	# 本職 first=85、second は未経験(0)。second を 1287 イニング(=3861 outs/3 ≒ フル1年)守った record。
	var player: PSPlayer = _make_player_with_aptitudes(900101, 24, 3, {"first": 85, "second": 0})
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	record.advanced_stats.defensive_outs_by_position = {"4": 3861}
	Offseason.apply_position_aptitude_growth(player, record)
	var first_after: int = int(player.position_aptitudes.get("first", 0))
	var second_after: int = int(player.position_aptitudes.get("second", 0))
	if first_after != 90:
		push_error("Aptitude camp growth: expected first 85->90, got %d" % first_after)
		ok = false
	if second_after < 13 or second_after > 17:
		push_error("Aptitude innings growth: expected second ~15, got %d" % second_after)
		ok = false

	# 本職が既に 100 なら据え置き (上限)。record 無しなら本職キャンプ分のみ。
	var capped: PSPlayer = _make_player_with_aptitudes(900102, 28, 6, {"shortstop": 100})
	Offseason.apply_position_aptitude_growth(capped, null)
	if int(capped.position_aptitudes.get("shortstop", 0)) != 100:
		push_error("Aptitude cap: expected shortstop to stay 100, got %d" % int(capped.position_aptitudes.get("shortstop", 0)))
		ok = false

	# 投手 (pos 1) は対象外。
	var pitcher: PSPlayer = _make_player_with_aptitudes(900103, 24, 1, {})
	Offseason.apply_position_aptitude_growth(pitcher, null)
	if not pitcher.position_aptitudes.is_empty():
		push_error("Aptitude growth should skip pitchers, got %s" % str(pitcher.position_aptitudes))
		ok = false

	return ok


func _make_player_with_aptitudes(player_id: int, age: int, position: int, aptitudes: Dictionary) -> PSPlayer:
	var player: PSPlayer = _make_player(player_id, age, position)
	player.position_aptitudes = aptitudes.duplicate(true)
	return player


func _make_player(player_id: int, age: int, position: int) -> PSPlayer:
	return PSPlayer.from_dict({
		"id": player_id,
		"sensyu_num": player_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": 1,
		"name": "Smoke",
		"age": age,
		"years": 1,
		"height": 180,
		"weight": 80,
		"position": position,
		"role": "starter" if position == 1 else "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 1000,
		"draft_round": 1,
		"hometown": "",
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"position_aptitudes": {"first": 100},
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, 55, 88),
		"fatigue": 0,
		"injury_days": 0,
	})
