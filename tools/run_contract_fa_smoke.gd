extends Node

# R4 Step1: 契約残年数・FA権・チーム予算のスモークテスト。
#  - FA閾値の推定 (高卒8 / その他7 / draft_source / 外国人 / デビュー年齢推定)。
#  - 保有残年数 = max(0, 閾値 - years) と FA権取得境界。
#  - process_contract_update の年俸更新・contract_status 遷移・new_fa 検出・予算会計。
#  - fa_eligible_years の to_dict/from_dict 往復 (PSPlayer / PSPlayerSeasonRecord)。

const Offseason = preload("res://services/season/offseason_service.gd")
const TeamFinance = preload("res://services/season/team_finance.gd")


func _ready() -> void:
	Rng.set_seed_value(20260605)
	var ok: bool = true

	ok = _test_fa_threshold() and ok
	ok = _test_retention_boundary() and ok
	ok = _test_contract_update() and ok
	ok = _test_roundtrip() and ok

	print("Contract/FA smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


# --- FA閾値の推定 ---
func _test_fa_threshold() -> bool:
	var ok: bool = true

	# デビュー18歳 (age=18, years=1) → 高卒推定 → 8
	var hs: PSPlayer = _make_player(1, 18, 1, 5, {})
	ok = _expect(hs.fa_eligible_years == 8, "debut18 → 8 (got %d)" % hs.fa_eligible_years, ok)

	# デビュー22歳 (age=22, years=1) → 大社推定 → 7
	var uni: PSPlayer = _make_player(2, 22, 1, 5, {})
	ok = _expect(uni.fa_eligible_years == 7, "debut22 → 7 (got %d)" % uni.fa_eligible_years, ok)

	# 古参でも debut 推定: age=30, years=13 → debut 18 → 8
	var vet: PSPlayer = _make_player(3, 30, 13, 5, {})
	ok = _expect(vet.fa_eligible_years == 8, "age30 years13 debut18 → 8 (got %d)" % vet.fa_eligible_years, ok)

	# draft_source 明示: high_school → 8 (デビュー年齢に関係なく)
	var hs_src: PSPlayer = _make_player(4, 25, 1, 5, {"draft_source": "high_school"})
	ok = _expect(hs_src.fa_eligible_years == 8, "draft_source high_school → 8 (got %d)" % hs_src.fa_eligible_years, ok)

	# draft_source university → 7
	var uni_src: PSPlayer = _make_player(5, 19, 1, 5, {"draft_source": "university"})
	ok = _expect(uni_src.fa_eligible_years == 7, "draft_source university → 7 (got %d)" % uni_src.fa_eligible_years, ok)

	# 外国人 → 7 (デビュー18でも)
	var foreign: PSPlayer = _make_player_foreign(6, 18, 1, 5)
	ok = _expect(foreign.fa_eligible_years == 7, "foreign → 7 (got %d)" % foreign.fa_eligible_years, ok)

	# 明示保存値は尊重される
	var explicit: PSPlayer = PSPlayer.from_dict(_player_data(7, 18, 1, 5, {}, false, {"fa_eligible_years": 6}))
	ok = _expect(explicit.fa_eligible_years == 6, "explicit fa_eligible_years=6 respected (got %d)" % explicit.fa_eligible_years, ok)

	return ok


# --- 保有残年数と FA権取得境界 ---
func _test_retention_boundary() -> bool:
	var ok: bool = true

	# 高卒 (閾値8): years=6 → 残2, 非FA; years=7 → 残1 (FA権間近), 非FA; years=8 → 残0, FA可能
	var y6: PSPlayer = _make_player(10, 24, 6, 5, {"draft_source": "high_school"})
	ok = _expect(y6.fa_remaining_years() == 2 and not y6.is_fa_eligible(), "HS years6 → 残2 非FA", ok)
	ok = _expect(Offseason._contract_status_for(y6) == "通常", "HS years6 → 通常", ok)

	var y7: PSPlayer = _make_player(11, 25, 7, 5, {"draft_source": "high_school"})
	ok = _expect(y7.fa_remaining_years() == 1 and not y7.is_fa_eligible(), "HS years7 → 残1 非FA", ok)
	ok = _expect(Offseason._contract_status_for(y7) == "FA権間近", "HS years7 → FA権間近", ok)

	var y8: PSPlayer = _make_player(12, 26, 8, 5, {"draft_source": "high_school"})
	ok = _expect(y8.fa_remaining_years() == 0 and y8.is_fa_eligible(), "HS years8 → 残0 FA可能", ok)
	ok = _expect(Offseason._contract_status_for(y8) == "FA可能", "HS years8 → FA可能", ok)

	# その他 (閾値7): years=7 → FA可能
	var u7: PSPlayer = _make_player(13, 29, 7, 5, {"draft_source": "university"})
	ok = _expect(u7.is_fa_eligible(), "univ years7 → FA可能", ok)

	return ok


# --- process_contract_update: 年俸 / FA遷移 / new_fa / 予算 ---
func _test_contract_update() -> bool:
	var ok: bool = true
	RecordStore.player_records.clear()

	var team: PSTeam = PSTeam.from_dict({"id": 77, "name": "Smoke", "short_name": "SMK", "league": "central", "funds": 120000})
	var teams: Array = [team]

	var players: Array = []
	# 通常選手 (HS years5) / FA権間近 (HS years7) / FA可能 (HS years8)
	players.append(_make_player(20, 23, 5, 5, {"draft_source": "high_school"}))
	players.append(_make_player(21, 25, 7, 5, {"draft_source": "high_school"}))
	var fa_player: PSPlayer = _make_player(22, 26, 8, 5, {"draft_source": "high_school"})
	players.append(fa_player)

	# 初期 salary を意図的に低くして昇給を検出させる
	for p_row in players:
		(p_row as PSPlayer).salary = 500

	var result: Dictionary = Offseason.process_contract_update(players, teams, null)

	# 年俸が再査定で上がっている (overall*1000 ベース、500 より大)
	ok = _expect(int(result.get("raises_count", 0)) >= 1, "raises detected (got %d)" % int(result.get("raises_count", 0)), ok)
	ok = _expect(fa_player.salary > 500, "fa_player salary recomputed (got %d)" % fa_player.salary, ok)

	# contract_status 遷移
	ok = _expect((players[0] as PSPlayer).contract_status == "通常", "player20 → 通常", ok)
	ok = _expect((players[1] as PSPlayer).contract_status == "FA権間近", "player21 → FA権間近", ok)
	ok = _expect(fa_player.contract_status == "FA可能", "player22 → FA可能", ok)

	# new_fa は years==閾値 で初めて FA可能になった選手のみ (player22)
	ok = _expect(int(result.get("new_fa_count", 0)) == 1, "new_fa_count == 1 (got %d)" % int(result.get("new_fa_count", 0)), ok)

	# 予算会計: payroll == 3選手の salary 合計
	var expected_payroll: int = 0
	for p_row in players:
		expected_payroll += (p_row as PSPlayer).salary
	var budgets: Array = result.get("team_budgets", []) as Array
	ok = _expect(budgets.size() == 1, "one team budget row", ok)
	if budgets.size() == 1:
		var b: Dictionary = budgets[0] as Dictionary
		ok = _expect(int(b.get("payroll", -1)) == expected_payroll, "payroll matches sum (%d vs %d)" % [int(b.get("payroll", -1)), expected_payroll], ok)
		ok = _expect(int(b.get("room", 0)) == 120000 - expected_payroll, "room = funds - payroll", ok)
	# TeamFinance 直接呼びも一致
	ok = _expect(TeamFinance.team_payroll(players, 77) == expected_payroll, "TeamFinance.team_payroll matches", ok)

	# 2回目実行では new_fa は出ない (既に FA可能)
	var result2: Dictionary = Offseason.process_contract_update(players, teams, null)
	ok = _expect(int(result2.get("new_fa_count", 0)) == 0, "second run new_fa_count == 0 (got %d)" % int(result2.get("new_fa_count", 0)), ok)

	RecordStore.player_records.clear()
	return ok


# --- 往復 ---
func _test_roundtrip() -> bool:
	var ok: bool = true

	var p: PSPlayer = _make_player(30, 26, 8, 5, {"draft_source": "high_school"})
	var p2: PSPlayer = PSPlayer.from_dict(p.to_dict())
	ok = _expect(p2.fa_eligible_years == 8, "PSPlayer roundtrip fa_eligible_years (got %d)" % p2.fa_eligible_years, ok)

	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(p, 2099, 1)
	ok = _expect(rec.fa_eligible_years == 8, "record from_player copies fa_eligible_years (got %d)" % rec.fa_eligible_years, ok)
	ok = _expect(rec.is_fa_eligible() and rec.fa_remaining_years() == 0, "record FA helpers", ok)
	var rec2: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(rec.to_dict())
	ok = _expect(rec2.fa_eligible_years == 8, "record roundtrip fa_eligible_years (got %d)" % rec2.fa_eligible_years, ok)

	# 旧データ (fa_eligible_years 欠落) は出身から既定計算される
	var legacy_data: Dictionary = p.to_dict()
	legacy_data.erase("fa_eligible_years")
	var p3: PSPlayer = PSPlayer.from_dict(legacy_data)
	ok = _expect(p3.fa_eligible_years == 8, "legacy player without column → recomputed 8 (got %d)" % p3.fa_eligible_years, ok)

	return ok


# --- helpers ---
func _player_data(player_id: int, age: int, position: int, years: int, source_extra: Dictionary, foreign: bool, extra: Dictionary) -> Dictionary:
	var src: Dictionary = {}
	for k in source_extra.keys():
		src[k] = source_extra[k]
	var data: Dictionary = {
		"id": player_id,
		"sensyu_num": player_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": 77,
		"name": "Smoke%d" % player_id,
		"age": age,
		"years": years,
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
		"foreign_player": foreign,
		"position_aptitudes": {Offseason.POSITION_NAME_BY_ID.get(position, "first"): 100},
		"source_data": src,
		"z_abilities": Offseason.generated_z_abilities(position, 55, 80),
		"fatigue": 0,
		"injury_days": 0,
	}
	for k in extra.keys():
		data[k] = extra[k]
	return data


func _make_player(player_id: int, age: int, years: int, position: int, source_extra: Dictionary) -> PSPlayer:
	return PSPlayer.from_dict(_player_data(player_id, age, position, years, source_extra, false, {}))


func _make_player_foreign(player_id: int, age: int, years: int, position: int) -> PSPlayer:
	return PSPlayer.from_dict(_player_data(player_id, age, position, years, {}, true, {}))


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[contract_fa] FAIL: %s" % label)
		return false
	return running_ok
