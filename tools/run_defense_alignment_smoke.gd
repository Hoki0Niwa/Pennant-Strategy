extends Node

const FieldingModel = preload("res://services/simulation/models/fielding_model.gd")

# Phase 4 スモーク: PSDefenseAlignmentService の挙動検証。
# 5 assertion: 基本ケース / 再現性 / 怪我による補充 / template 空 (lazy default) / 適性 0 除外


func _ready() -> void:
	Rng.set_seed_value(20260525)
	PSDefenseAlignmentProfile.reset_cache()
	var failures: Array = []

	failures.append_array(_test_basic_assignment())
	failures.append_array(_test_reproducibility())
	failures.append_array(_test_injury_substitution())
	failures.append_array(_test_lazy_default_template())
	failures.append_array(_test_aptitude_zero_excluded())
	failures.append_array(_test_aptitude_before_overall())
	failures.append_array(_test_sub_interval_starter())
	failures.append_array(_test_fatigue_emergency_sub())
	failures.append_array(_test_sub_interval_overall_gap())
	failures.append_array(_test_ai_usage_defaults())
	failures.append_array(_test_off_position_penalty())
	failures.append_array(_test_starter_score_considers_penalty())

	if failures.is_empty():
		print("Defense alignment smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Defense alignment smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


# --- Tests ---

func _test_basic_assignment() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(1000)
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(101)

	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)

	if slots.size() != 8:
		fails.append("basic: slots.size()=%d expected 8" % slots.size())
		_print_case("basic_assignment", "FAIL (size)", slots)
		return fails

	var positions: Dictionary = {}
	var player_ids: Dictionary = {}
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		var pos: int = int(slot["position"])
		var rec: PSPlayerSeasonRecord = slot["record"] as PSPlayerSeasonRecord
		if positions.has(pos):
			fails.append("basic: position %d assigned twice" % pos)
		positions[pos] = true
		if player_ids.has(rec.player_id):
			fails.append("basic: player_id %d assigned twice" % rec.player_id)
		player_ids[rec.player_id] = true

	for p in [2, 3, 4, 5, 6, 7, 8, 9]:
		if not positions.has(p):
			fails.append("basic: position %d not filled" % p)

	_print_case("basic_assignment", "OK" if fails.is_empty() else "FAIL", slots)
	return fails


func _test_reproducibility() -> Array:
	var fails: Array = []
	var fielders1: Array = _build_full_roster(2000)
	var fielders2: Array = _build_full_roster(2000)  # 同条件
	var profile1: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(102)
	var profile2: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(102)

	var slots1: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders1, profile1)
	var slots2: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders2, profile2)

	if slots1.size() != slots2.size():
		fails.append("reproducibility: size mismatch")
	else:
		for i in range(slots1.size()):
			var rec1: PSPlayerSeasonRecord = (slots1[i] as Dictionary)["record"] as PSPlayerSeasonRecord
			var rec2: PSPlayerSeasonRecord = (slots2[i] as Dictionary)["record"] as PSPlayerSeasonRecord
			var pos1: int = int((slots1[i] as Dictionary)["position"])
			var pos2: int = int((slots2[i] as Dictionary)["position"])
			if rec1.player_id != rec2.player_id or pos1 != pos2:
				fails.append("reproducibility: idx %d differs (%d@%d vs %d@%d)" % [i, rec1.player_id, pos1, rec2.player_id, pos2])
	_print_case("reproducibility", "OK" if fails.is_empty() else "FAIL", slots1)
	return fails


func _test_injury_substitution() -> Array:
	var fails: Array = []
	# 通常配置を 1 回算出 (template キャッシュ)
	var fielders: Array = _build_full_roster(3000)
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(103)
	var initial_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)

	# template に登録された捕手 (position=2) を負傷させる
	var injured_catcher_id: int = -1
	for slot_row in initial_slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot["position"]) == 2:
			var rec: PSPlayerSeasonRecord = slot["record"] as PSPlayerSeasonRecord
			injured_catcher_id = rec.player_id
			break
	if injured_catcher_id < 0:
		fails.append("injury_sub: catcher not found in initial slots")
		_print_case("injury_substitution", "FAIL (no catcher)", initial_slots)
		return fails

	# 負傷フラグを立てて再配置
	for row in fielders:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec.player_id == injured_catcher_id:
			rec.injury_days = 5
			break

	var second_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)

	# 捕手スロットの player が変わっていることを確認
	var new_catcher_id: int = -1
	for slot_row in second_slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot["position"]) == 2:
			var rec: PSPlayerSeasonRecord = slot["record"] as PSPlayerSeasonRecord
			new_catcher_id = rec.player_id
			break

	if new_catcher_id == injured_catcher_id:
		fails.append("injury_sub: injured catcher (%d) still assigned" % injured_catcher_id)
	if new_catcher_id == -1:
		fails.append("injury_sub: catcher slot not filled after injury")
	_print_case("injury_substitution", "OK (catcher %d→%d)" % [injured_catcher_id, new_catcher_id] if fails.is_empty() else "FAIL", second_slots)
	return fails


func _test_lazy_default_template() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(4000)
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(104)

	# template が空であることを確認
	if not profile.starting_positions.is_empty():
		fails.append("lazy_default: profile.starting_positions should be empty initially")

	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)

	# 8 ポジション埋まることを確認
	if slots.size() != 8:
		fails.append("lazy_default: slots.size()=%d expected 8" % slots.size())

	# template がキャッシュされたことを確認
	if profile.starting_positions.size() != 8:
		fails.append("lazy_default: template not cached (size=%d)" % profile.starting_positions.size())

	_print_case("lazy_default_template", "OK" if fails.is_empty() else "FAIL", slots)
	return fails


func _test_aptitude_zero_excluded() -> Array:
	var fails: Array = []
	# 10 名: 全員 catcher 適性 0、それぞれ別ポジ適性のみ → catcher は適性 0 fallback で選ばれる想定
	var fielders: Array = []
	# position 2 (catcher) 適性を持つ選手を 1 名だけ用意
	fielders.append(_make_fielder(5001, 2, {"catcher": 80, "first": 30}))
	# 残り 7 名は内/外野のみ
	fielders.append(_make_fielder(5002, 3, {"first": 90}))
	fielders.append(_make_fielder(5003, 4, {"second": 85}))
	fielders.append(_make_fielder(5004, 5, {"third": 80}))
	fielders.append(_make_fielder(5005, 6, {"shortstop": 88}))
	fielders.append(_make_fielder(5006, 7, {"left": 70}))
	fielders.append(_make_fielder(5007, 8, {"center": 90}))
	fielders.append(_make_fielder(5008, 9, {"right": 75}))
	# 控え 2 名: catcher 適性 0、他位置適性のみ
	fielders.append(_make_fielder(5009, 7, {"left": 60, "right": 60}))
	fielders.append(_make_fielder(5010, 8, {"center": 65}))

	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(105)
	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)

	# catcher (position 2) は 5001 になるべき (唯一の catcher 適性者)
	var catcher_id: int = -1
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot["position"]) == 2:
			catcher_id = (slot["record"] as PSPlayerSeasonRecord).player_id
			break

	if catcher_id != 5001:
		fails.append("aptitude_zero: catcher assigned to %d, expected 5001" % catcher_id)
	_print_case("aptitude_zero_excluded", "OK" if fails.is_empty() else "FAIL", slots)
	return fails


func _test_aptitude_before_overall() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(6000)
	var high_overall_no_catcher: PSPlayerSeasonRecord = _find_record(fielders, 6006)
	_set_bat_z(high_overall_no_catcher, 3.0)
	high_overall_no_catcher.position_aptitudes_snapshot.erase("catcher")
	var catcher: PSPlayerSeasonRecord = _find_record(fielders, 6001)
	_set_bat_z(catcher, -2.0)

	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(106)
	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)
	var catcher_id: int = _player_id_for_position(slots, 2)
	if catcher_id == 6006:
		fails.append("aptitude_before_overall: high-overall non-catcher was assigned catcher")
	if catcher_id <= 0:
		fails.append("aptitude_before_overall: catcher was not assigned")
	_print_case("aptitude_before_overall", "OK" if fails.is_empty() else "FAIL", slots)
	return fails


func _test_sub_interval_starter() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(7000)
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(107)
	var usage: Dictionary = {
		"position_slots": {
			"2": {
				"starter_id": 7001,
				"sub_id": 7009,
				"sub_start_interval": 2,
			},
		},
	}
	var normal_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 1)
	var rest_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 2)
	var normal_catcher: int = _player_id_for_position(normal_slots, 2)
	var rest_catcher: int = _player_id_for_position(rest_slots, 2)
	if normal_catcher != 7001:
		fails.append("sub_interval: game1 catcher=%d expected 7001" % normal_catcher)
	if rest_catcher != 7009:
		fails.append("sub_interval: game2 catcher=%d expected 7009" % rest_catcher)
	_print_case("sub_interval_g1", "OK" if normal_catcher == 7001 else "FAIL", normal_slots)
	_print_case("sub_interval_g2", "OK" if rest_catcher == 7009 else "FAIL", rest_slots)
	return fails


func _test_fatigue_emergency_sub() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(9000)
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(109)
	var usage: Dictionary = {
		"position_slots": {
			"2": {
				"starter_id": 9001,
				"sub_id": 9009,
				"sub_start_interval": -1,
			},
		},
	}
	var normal_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 2)
	var normal_catcher: int = _player_id_for_position(normal_slots, 2)
	if normal_catcher != 9001:
		fails.append("fatigue_emergency: healthy catcher=%d expected 9001" % normal_catcher)
	var starter: PSPlayerSeasonRecord = _find_record(fielders, 9001)
	if starter != null:
		starter.fatigue = 90
	var fatigue_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 2)
	var fatigue_catcher: int = _player_id_for_position(fatigue_slots, 2)
	if fatigue_catcher != 9009:
		fails.append("fatigue_emergency: tired catcher=%d expected 9009" % fatigue_catcher)
	if starter != null:
		starter.injury_days = 5
		starter.fatigue = 0
	var emergency_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 2)
	var emergency_catcher: int = _player_id_for_position(emergency_slots, 2)
	if emergency_catcher != 9009:
		fails.append("fatigue_emergency: injured catcher=%d expected 9009" % emergency_catcher)
	_print_case("fatigue_emergency_healthy", "OK" if normal_catcher == 9001 else "FAIL", normal_slots)
	_print_case("fatigue_emergency_tired", "OK" if fatigue_catcher == 9009 else "FAIL", fatigue_slots)
	_print_case("fatigue_emergency_injury", "OK" if emergency_catcher == 9009 else "FAIL", emergency_slots)
	return fails


func _test_sub_interval_overall_gap() -> Array:
	var fails: Array = []
	var starter: PSPlayerSeasonRecord = _make_fielder(9101, 7, {"left": 80})
	_set_bat_z(starter, 0.0)
	var starter_overall: int = PSPlayerValueEvaluator.overall_score(starter)
	# 各能力差帯をサンプルし、_sub_interval_for が想定マッピングと一致するか検証。
	# 想定: gap<=1→2, <=2→3, <=3→4, <=4→6, >=5→-1 (疲労/緊急時のみ)。
	var sample_index: int = 0
	for target_delta in [0, -2, -3, -4, -6, -10]:
		sample_index += 1
		var sub: PSPlayerSeasonRecord = _make_fielder(9110 + sample_index, 7, {"left": 80})
		_set_record_near_overall(sub, starter_overall + target_delta)
		var gap: int = max(0, starter_overall - PSPlayerValueEvaluator.overall_score(sub))
		var interval: int = PSTeamSetupBuilder._sub_interval_for(starter, sub, 7)
		var expected: int = _expected_sub_interval(gap)
		if interval != expected:
			fails.append("sub_interval_gap: gap=%d interval=%d expected=%d" % [gap, interval, expected])
	# 明示境界: ほぼ互角 (gap<=1) は 2 試合に 1 度起用。
	var equal_sub: PSPlayerSeasonRecord = _make_fielder(9120, 7, {"left": 80})
	_set_bat_z(equal_sub, 0.0)
	var equal_interval: int = PSTeamSetupBuilder._sub_interval_for(starter, equal_sub, 7)
	if equal_interval != 2:
		fails.append("sub_interval_gap: equal-ability sub interval=%d expected 2" % equal_interval)
	print("[sub_interval_gap] %s equal_interval=%d" % ["OK" if fails.is_empty() else "FAIL", equal_interval])
	return fails


func _expected_sub_interval(gap: int) -> int:
	if gap <= 1:
		return 2
	if gap <= 2:
		return 3
	if gap <= 3:
		return 4
	if gap <= 4:
		return 6
	return -1


func _test_ai_usage_defaults() -> Array:
	var fails: Array = []
	var fielders: Array = _build_full_roster(8000)
	fielders.append(_make_fielder(8011, 4, {"second": 72, "shortstop": 60}))
	fielders.append(_make_fielder(8012, 5, {"third": 72, "first": 60}))
	fielders.append(_make_fielder(8013, 6, {"shortstop": 72, "second": 62}))
	fielders.append(_make_fielder(8014, 7, {"left": 62, "right": 55}))
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(108)
	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile)
	var usage: Dictionary = PSTeamSetupBuilder.build_ai_fielder_usage(fielders, slots)
	var position_slots: Dictionary = usage.get("position_slots", {}) as Dictionary
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var slot: Dictionary = position_slots.get(str(position), {}) as Dictionary
		if int(slot.get("starter_id", 0)) <= 0:
			fails.append("ai_usage: position %d starter missing" % position)
		if int(slot.get("sub_id", 0)) <= 0:
			fails.append("ai_usage: position %d sub missing" % position)
		var interval: int = int(slot.get("sub_start_interval", 0))
		if interval == 0:
			fails.append("ai_usage: position %d interval missing" % position)
	if usage.has("bench_roles"):
		fails.append("ai_usage: bench_roles should not be generated")
	_print_case("ai_usage_defaults", "OK" if fails.is_empty() else "FAIL", slots)
	return fails


# 守備適性 100 でないポジションのペナルティ: 100 で無、低いほど・難しいポジほど大きく減点。
func _test_off_position_penalty() -> Array:
	var fails: Array = []

	# 1) 適性が下がるほど守備値が下がる (CF, neutral skill)。
	var cf100: int = _def_score(8, "center", 100)
	var cf85: int = _def_score(8, "center", 85)
	var cf60: int = _def_score(8, "center", 60)
	var cf0: int = _def_score(8, "center", 0)
	if not (cf100 > cf85 and cf85 > cf60 and cf60 > cf0):
		fails.append("penalty: CF not monotonic by aptitude: %d/%d/%d/%d" % [cf100, cf85, cf60, cf0])

	# 2) 同じ適性差 (100→60) でも難しいポジ(CF)の方が易しいポジ(1B)より大きく減点。
	var fb100: int = _def_score(3, "first", 100)
	var fb60: int = _def_score(3, "first", 60)
	var drop_cf: int = cf100 - cf60
	var drop_fb: int = fb100 - fb60
	if not (drop_cf > drop_fb and drop_fb > 0):
		fails.append("penalty: difficulty scaling wrong: CF drop=%d 1B drop=%d" % [drop_cf, drop_fb])

	# 2b) 難易度順位 SS > CF > 2B > 3B (現実準拠)。同一適性差での減点幅で検証。
	var drop_ss: int = _def_score(6, "shortstop", 100) - _def_score(6, "shortstop", 60)
	var drop_2b: int = _def_score(4, "second", 100) - _def_score(4, "second", 60)
	var drop_3b: int = _def_score(5, "third", 100) - _def_score(5, "third", 60)
	if not (drop_ss > drop_cf and drop_cf > drop_2b and drop_2b > drop_3b and drop_3b > 0):
		fails.append("penalty: difficulty order should be SS>CF>2B>3B, got SS=%d CF=%d 2B=%d 3B=%d" % [drop_ss, drop_cf, drop_2b, drop_3b])

	# 3) 適性 100 では全ポジ無ペナルティ (= base skill のみ)。
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		var key: String = str(PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS.get(pos, ""))
		var actual: int = _def_score(pos, key, 100)
		# neutral skill = 空 z = LEAGUE_AVERAGE_FIELDING(0.0)。z スケール係数は 10.625 (旧 0.85×12.5)。
		var expected: int = clampi(int(round(50.0 + (FieldingModel.LEAGUE_AVERAGE_FIELDING - FieldingModel.position_average_ability_score(pos)) * 10.625)), 1, 99)
		if actual != expected:
			fails.append("penalty: aptitude 100 should be unpenalized at pos %d (got %d expected %d)" % [pos, actual, expected])

	print("[off_position_penalty] %s CF=%d/%d/%d/%d 1B100=%d 1B60=%d" % [
		"OK" if fails.is_empty() else "FAIL", cf100, cf85, cf60, cf0, fb100, fb60])
	return fails


# スタメン選出スコアが「単純な総合値」でなく割り当てポジの守備ペナルティを core(×100) に
# 織り込むこと。同一打撃・同一ポジで適性 100 vs 60 を比較し、差が aptitude tiebreak(≈40)
# だけでは説明できない大きさ (守備ペナルティが総合力ブレンドに乗っている) であることを確認。
func _test_starter_score_considers_penalty() -> Array:
	var fails: Array = []
	var apt100: PSPlayerSeasonRecord = _make_fielder(9201, 6, {"shortstop": 100})
	var apt60: PSPlayerSeasonRecord = _make_fielder(9202, 6, {"shortstop": 60})
	_set_bat_z(apt100, 0.5)
	_set_bat_z(apt60, 0.5)
	var s100: int = PSPlayerValueEvaluator.starter_assignment_score(apt100, 6, true)
	var s60: int = PSPlayerValueEvaluator.starter_assignment_score(apt60, 6, true)
	var gap: int = s100 - s60
	if gap <= 120:
		fails.append("starter_penalty: SS apt100 vs 60 gap=%d too small (penalty not in core?)" % gap)
	# 守備ペナルティはポジ難易度に比例 → 難しい SS の gap は易しい 1B の gap より大きい。
	var fb100: PSPlayerSeasonRecord = _make_fielder(9203, 3, {"first": 100})
	var fb60: PSPlayerSeasonRecord = _make_fielder(9204, 3, {"first": 60})
	_set_bat_z(fb100, 0.5)
	_set_bat_z(fb60, 0.5)
	var fb_gap: int = PSPlayerValueEvaluator.starter_assignment_score(fb100, 3, true) - PSPlayerValueEvaluator.starter_assignment_score(fb60, 3, true)
	if not (gap > fb_gap):
		fails.append("starter_penalty: SS gap=%d should exceed 1B gap=%d (difficulty-scaled)" % [gap, fb_gap])
	print("[starter_score_penalty] %s SS gap=%d 1B gap=%d" % ["OK" if fails.is_empty() else "FAIL", gap, fb_gap])
	return fails


func _def_score(position: int, aptitude_key: String, aptitude: int) -> int:
	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	rec.player_id = 1
	rec.position = position
	rec.position_aptitudes_snapshot = {aptitude_key: aptitude}
	rec.z_abilities_snapshot = {}
	return PSPlayerValueEvaluator.defensive_score_for_position(rec, position)


# --- Helpers ---

func _build_full_roster(id_base: int) -> Array:
	# 10 名 (スタメン 8 + 控え 2)、各々別ポジション適性
	var fielders: Array = []
	fielders.append(_make_fielder(id_base + 1, 2, {"catcher": 90, "first": 40}))
	fielders.append(_make_fielder(id_base + 2, 3, {"first": 92, "left": 50}))
	fielders.append(_make_fielder(id_base + 3, 4, {"second": 88, "shortstop": 60}))
	fielders.append(_make_fielder(id_base + 4, 5, {"third": 85, "first": 50}))
	fielders.append(_make_fielder(id_base + 5, 6, {"shortstop": 92, "second": 70}))
	fielders.append(_make_fielder(id_base + 6, 7, {"left": 78, "center": 60}))
	fielders.append(_make_fielder(id_base + 7, 8, {"center": 90, "right": 70}))
	fielders.append(_make_fielder(id_base + 8, 9, {"right": 82, "left": 65}))
	# 控え
	fielders.append(_make_fielder(id_base + 9, 2, {"catcher": 75, "first": 40}))  # backup catcher
	fielders.append(_make_fielder(id_base + 10, 7, {"left": 65, "right": 60, "center": 55}))  # backup outfield
	return fielders


func _make_fielder(player_id: int, primary_position: int, aptitudes: Dictionary) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	rec.player_id = player_id
	rec.position = primary_position
	rec.role = "fielder"
	rec.batting_side = "R"
	rec.throwing_hand = "R"
	rec.fatigue = 0
	rec.injury_days = 0
	rec.position_aptitudes_snapshot = aptitudes
	# z_abilities はデフォルト 0 のまま (定数項のみで score 計算される)
	rec.z_abilities_snapshot = {}
	return rec


func _find_record(fielders: Array, player_id: int) -> PSPlayerSeasonRecord:
	for row in fielders:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec != null and rec.player_id == player_id:
			return rec
	return null


func _set_bat_z(record: PSPlayerSeasonRecord, z_value: float) -> void:
	if record == null:
		return
	record.z_abilities_snapshot = {
		"Bat_KAvoid": z_value,
		"Bat_BBCreate": z_value,
		"Bat_Impact": z_value,
		"Bat_Loft": z_value,
		"Bat_Barrel": z_value,
		"Bat_Spray": z_value,
		"Run_Speed": z_value,
		"Run_Judgment": z_value,
		"Run_Steal": z_value,
	}


func _set_record_near_overall(record: PSPlayerSeasonRecord, target_overall: int) -> void:
	var best_z: float = 0.0
	var best_delta: int = 999999
	for step in range(-60, 61):
		var z_value: float = float(step) / 10.0
		_set_bat_z(record, z_value)
		var delta: int = abs(PSPlayerValueEvaluator.overall_score(record) - target_overall)
		if delta < best_delta:
			best_delta = delta
			best_z = z_value
	_set_bat_z(record, best_z)


func _player_id_for_position(slots: Array, position: int) -> int:
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot.get("position", 0)) == position:
			var rec: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
			return 0 if rec == null else rec.player_id
	return 0


func _print_case(label: String, status: String, slots: Array) -> void:
	var parts: Array = []
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		var pos: int = int(slot["position"])
		var pid: int = (slot["record"] as PSPlayerSeasonRecord).player_id
		parts.append("%d@%d" % [pid, pos])
	print("[%s] %s slots=[%s]" % [label, status, ", ".join(parts)])
