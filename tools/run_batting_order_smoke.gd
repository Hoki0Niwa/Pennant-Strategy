extends Node

# 打順サービスのスモーク。
# 5 assertions: 基本ケース / 再現性 / 投手9番固定 / DH時投手除外 / グループ越え禁止。


func _ready() -> void:
	Rng.set_seed_value(20260525)
	var failures: Array = []

	failures.append_array(_test_basic_uniqueness())
	failures.append_array(_test_reproducibility())
	failures.append_array(_test_pitcher_locked_to_nine_non_dh())
	failures.append_array(_test_dh_excludes_pitcher())
	failures.append_array(_test_group_boundary_respected())

	if failures.is_empty():
		print("Batting order smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Batting order smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


# --- Tests ---

func _test_basic_uniqueness() -> Array:
	var fails: Array = []
	var entries: Array = _build_entries_with_dh()
	var profile: PSBattingOrderProfile = PSBattingOrderProfile.build_default(1, true)
	var ctx: Dictionary = _ctx(1, 1, true)

	var result: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile)

	if result.size() != 9:
		fails.append("basic: result.size()=%d expected 9" % result.size())
		_print_case("basic_uniqueness", "FAIL (size mismatch)", result)
		return fails

	var seen_ids: Dictionary = {}
	for i in range(result.size()):
		var rec: PSPlayerSeasonRecord = result[i] as PSPlayerSeasonRecord
		if seen_ids.has(rec.player_id):
			fails.append("basic: duplicate player_id=%d at slot %d" % [rec.player_id, i + 1])
		seen_ids[rec.player_id] = true
	_print_case("basic_uniqueness", "OK" if fails.is_empty() else "FAIL", result)
	return fails


func _test_reproducibility() -> Array:
	var fails: Array = []
	var entries: Array = _build_entries_with_dh()
	# 再現性検証では allow_random_bonus=true でも seed 一定なので同一結果になるはず
	var profile1: PSBattingOrderProfile = PSBattingOrderProfile.build_default(2, true)
	var profile2: PSBattingOrderProfile = PSBattingOrderProfile.build_default(2, true)
	# 同一 base_order を 2 つの profile に与える (1 回目で記録され、2 回目も同じ並びになる)
	# base が空の lazy fallback では entries 順に依存するため、両 profile に同じ base を明示注入
	var base: Array[int] = []
	for entry_row in entries:
		base.append((entry_row as PSPlayerSeasonRecord).player_id)
	profile1.base_order_player_ids = base.duplicate()
	profile2.base_order_player_ids = base.duplicate()

	var ctx: Dictionary = _ctx(42, 2, true)

	var result1: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile1)
	var result2: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile2)

	if result1.size() != result2.size():
		fails.append("reproducibility: size mismatch %d vs %d" % [result1.size(), result2.size()])
	else:
		for i in range(result1.size()):
			var pid1: int = (result1[i] as PSPlayerSeasonRecord).player_id
			var pid2: int = (result2[i] as PSPlayerSeasonRecord).player_id
			if pid1 != pid2:
				fails.append("reproducibility: slot %d differs (%d vs %d)" % [i + 1, pid1, pid2])
	_print_case("reproducibility", "OK" if fails.is_empty() else "FAIL", result1)
	return fails


func _test_pitcher_locked_to_nine_non_dh() -> Array:
	var fails: Array = []
	var entries: Array = _build_entries_non_dh()
	var profile: PSBattingOrderProfile = PSBattingOrderProfile.build_default(3, false)
	var ctx: Dictionary = _ctx(7, 3, false)

	var result: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile)

	if result.size() != 9:
		fails.append("pitcher_nine: result.size()=%d expected 9" % result.size())
	else:
		var slot9: PSPlayerSeasonRecord = result[8] as PSPlayerSeasonRecord
		if not slot9.is_pitcher():
			fails.append("pitcher_nine: slot 9 player_id=%d is not pitcher" % slot9.player_id)
	_print_case("pitcher_locked_nine_non_dh", "OK" if fails.is_empty() else "FAIL", result)
	return fails


func _test_dh_excludes_pitcher() -> Array:
	var fails: Array = []
	var entries: Array = _build_entries_with_dh()
	var profile: PSBattingOrderProfile = PSBattingOrderProfile.build_default(4, true)
	var ctx: Dictionary = _ctx(11, 4, true)

	var result: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile)

	for i in range(result.size()):
		var rec: PSPlayerSeasonRecord = result[i] as PSPlayerSeasonRecord
		if rec.is_pitcher():
			fails.append("dh_excludes_pitcher: pitcher found at slot %d (player_id=%d)" % [i + 1, rec.player_id])
	_print_case("dh_excludes_pitcher", "OK" if fails.is_empty() else "FAIL", result)
	return fails


func _test_group_boundary_respected() -> Array:
	var fails: Array = []
	var entries: Array = _build_entries_with_dh()
	# base_order を明示注入: 1-2 が top, 3-5 が middle, 6-9 が lower
	var base: Array[int] = []
	for entry_row in entries:
		base.append((entry_row as PSPlayerSeasonRecord).player_id)
	# 元 slot 1 の選手は top グループに留まるべき
	var top_ids: Dictionary = {base[0]: true, base[1]: true}
	var middle_ids: Dictionary = {base[2]: true, base[3]: true, base[4]: true}
	var lower_ids: Dictionary = {base[5]: true, base[6]: true, base[7]: true, base[8]: true}

	# 大きめ random_bonus_range で揺れても境界を越えないことを確認
	var profile: PSBattingOrderProfile = PSBattingOrderProfile.build_default(5, true)
	profile.base_order_player_ids = base
	profile.random_bonus_range = 50  # 故意に大きく
	var ctx: Dictionary = _ctx(99, 5, true)

	var result: Array = PSBattingOrderService.build_daily_batting_order(entries, ctx, profile)

	for i in range(result.size()):
		var rec: PSPlayerSeasonRecord = result[i] as PSPlayerSeasonRecord
		var slot: int = i + 1
		if slot <= 2 and not top_ids.has(rec.player_id):
			fails.append("group_boundary: slot %d has non-top player %d" % [slot, rec.player_id])
		elif slot >= 3 and slot <= 5 and not middle_ids.has(rec.player_id):
			fails.append("group_boundary: slot %d has non-middle player %d" % [slot, rec.player_id])
		elif slot >= 6 and not lower_ids.has(rec.player_id):
			fails.append("group_boundary: slot %d has non-lower player %d" % [slot, rec.player_id])
	_print_case("group_boundary_respected", "OK" if fails.is_empty() else "FAIL", result)
	return fails


# --- Helpers ---

func _ctx(game_day: int, team_id: int, dh: bool) -> Dictionary:
	return {
		"game_day": game_day,
		"team_id": team_id,
		"dh_enabled": dh,
		"opp_pitcher_hand": "",
	}


func _build_entries_with_dh() -> Array:
	# 9 名 (野手 8 + DH 1)。役割別に z 能力を変えてグループ判別がはっきり出るようにする。
	var entries: Array = []
	# top 候補 (走攻バランス)
	entries.append(_make_record(1001, 8, "fielder", {"Run_Speed": 1.5, "Bat_KAvoid": 1.2, "Bat_BBCreate": 1.0, "Bat_Barrel": 0.3}))
	entries.append(_make_record(1002, 4, "fielder", {"Run_Speed": 1.2, "Bat_KAvoid": 1.0, "Bat_BBCreate": 1.3, "Bat_Barrel": 0.2}))
	# middle 候補 (中軸)
	entries.append(_make_record(1003, 9, "fielder", {"Bat_Barrel": 1.5, "Bat_Impact": 1.2, "Bat_BBCreate": 0.5}))
	entries.append(_make_record(1004, 3, "fielder", {"Bat_Barrel": 1.8, "Bat_Impact": 1.5, "Bat_Loft": 1.0}))
	entries.append(_make_record(1005, 7, "fielder", {"Bat_Barrel": 1.3, "Bat_Impact": 1.1, "Bat_BBCreate": 0.4}))
	# lower 候補
	entries.append(_make_record(1006, 5, "fielder", {"Bat_Barrel": 0.3, "Bat_KAvoid": 0.2, "Run_Speed": -0.5}))
	entries.append(_make_record(1007, 6, "fielder", {"Bat_Barrel": 0.2, "Bat_KAvoid": -0.2, "Run_Speed": 0.0}))
	entries.append(_make_record(1008, 2, "fielder", {"Bat_Barrel": -0.5, "Bat_KAvoid": -0.8, "Run_Speed": -1.0}))  # catcher
	entries.append(_make_record(1009, 10, "fielder", {"Bat_Barrel": 0.5, "Bat_Impact": 0.4}))  # DH
	return entries


func _build_entries_non_dh() -> Array:
	# 9 名 (野手 8 + 投手 1)。投手は最後に append (team_setup_builder と同じ順序)
	var entries: Array = []
	entries.append(_make_record(2001, 8, "fielder", {"Run_Speed": 1.5, "Bat_KAvoid": 1.2, "Bat_BBCreate": 1.0}))
	entries.append(_make_record(2002, 4, "fielder", {"Run_Speed": 1.2, "Bat_KAvoid": 1.0, "Bat_BBCreate": 1.3}))
	entries.append(_make_record(2003, 9, "fielder", {"Bat_Barrel": 1.5, "Bat_Impact": 1.2}))
	entries.append(_make_record(2004, 3, "fielder", {"Bat_Barrel": 1.8, "Bat_Impact": 1.5}))
	entries.append(_make_record(2005, 7, "fielder", {"Bat_Barrel": 1.3, "Bat_Impact": 1.1}))
	entries.append(_make_record(2006, 5, "fielder", {"Bat_Barrel": 0.3, "Bat_KAvoid": 0.2}))
	entries.append(_make_record(2007, 6, "fielder", {"Bat_Barrel": 0.2, "Bat_KAvoid": -0.2}))
	entries.append(_make_record(2008, 2, "fielder", {"Bat_Barrel": -0.5, "Bat_KAvoid": -0.8}))
	entries.append(_make_record(2999, 1, "starter", {"Pit_KCreate": 1.0, "Bat_Barrel": -2.0, "Bat_KAvoid": -2.0}))  # pitcher
	return entries


func _make_record(player_id: int, position: int, role: String, z: Dictionary) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	rec.player_id = player_id
	rec.position = position
	rec.role = role
	rec.batting_side = "R"
	rec.throwing_hand = "R"
	rec.fatigue = 0
	rec.z_abilities_snapshot = z
	return rec


func _print_case(label: String, status: String, result: Array) -> void:
	var slots: Array = []
	for i in range(result.size()):
		var rec: PSPlayerSeasonRecord = result[i] as PSPlayerSeasonRecord
		slots.append("%d:%d" % [i + 1, rec.player_id])
	print("[%s] %s order=[%s]" % [label, status, ", ".join(slots)])
