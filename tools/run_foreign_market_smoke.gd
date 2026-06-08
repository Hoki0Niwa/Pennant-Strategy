extends Node

# R4 Step3: 外国人選手雇用のスモークテスト。
#  - process_foreign_releases: 枠 (4) 超過と能力バー (FOREIGN_RELEASE_MIN_VALUE) 未満を放出。
#  - 低稼働の外国人 (野手PA<=150 / 先発<=10 / 救援<=20) を放出。
#  - process_foreign_market: 外国人0人の球団が1オフで4人まで獲得、保有 ≤4 / 総数 ≤70。
#  - state API: 自軍候補を手動で獲得できる。
#  - 二遊間と捕手は出づらく、生成能力中心も低くなる。
#  - 通常戦力外が外国人を保護しつつ総数に数える (外国人を残すほど日本人を多く切る)。

const Offseason = preload("res://services/season/offseason_service.gd")
const Foreign = preload("res://services/season/foreign_player_service.gd")

var _next_id: int = 1


func _ready() -> void:
	Rng.set_seed_value(20260605)
	var ok: bool = true

	ok = _test_foreign_release_over_slot() and ok
	ok = _test_foreign_release_bust() and ok
	ok = _test_foreign_release_low_usage() and ok
	ok = _test_weak_first_year_foreign_released_after_one_season() and ok
	ok = _test_user_auto_candidates_include_foreign_releases() and ok
	ok = _test_foreign_release_can_exclude_user_team() and ok
	ok = _test_foreign_market_fills_slots() and ok
	ok = _test_user_manual_foreign_signing() and ok
	ok = _test_foreign_candidate_contract_clock() and ok
	ok = _test_foreign_position_bias() and ok

	print("Foreign market smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


# 5人の外国人 → 上位4を残し、最下位 (枠超過) を放出。
func _test_foreign_release_over_slot() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1)]
	var players: Array = []
	# 高 center 4人 + やや低い1人 (枠超過で切られる)。全員 value >= バー。
	for c in [80, 76, 72, 70]:
		players.append(_foreign(1, _batter_pos(), c))
	var over_slot: PSPlayer = _foreign(1, _batter_pos(), 60)
	players.append(over_slot)

	var result: Dictionary = Offseason.process_foreign_releases(players, teams, null)
	ok = _expect(int(result.get("released_count", 0)) == 1, "exactly 1 over-slot foreign released (got %d)" % int(result.get("released_count", 0)), ok)
	ok = _expect(over_slot.is_retired() and over_slot.team_id == 0, "the lowest-value (5th) foreign was released", ok)
	ok = _expect(_active_foreign(players, 1) == 4, "4 foreign retained", ok)
	return ok


# 能力バー未満の外れ外国人は枠内でも放出。
func _test_foreign_release_bust() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1)]
	var players: Array = []
	var good1: PSPlayer = _foreign(1, _batter_pos(), 80)
	var good2: PSPlayer = _foreign(1, _batter_pos(), 76)
	var bust1: PSPlayer = _foreign(1, _batter_pos(), 40)
	var bust2: PSPlayer = _foreign(1, _batter_pos(), 38)
	players.append_array([good1, good2, bust1, bust2])

	var result: Dictionary = Offseason.process_foreign_releases(players, teams, null)
	ok = _expect(not good1.is_retired() and not good2.is_retired(), "good foreign kept", ok)
	ok = _expect(bust1.is_retired() and bust2.is_retired(), "bust foreign released (below value bar)", ok)
	ok = _expect(int(result.get("released_count", 0)) == 2, "2 busts released (got %d)" % int(result.get("released_count", 0)), ok)
	return ok


func _test_foreign_release_low_usage() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1)]
	var season: PSSeason = _season(2026)
	var players: Array = []
	RecordStore.player_records.clear()

	var low_pa: PSPlayer = _foreign(1, 7, 80)
	var low_starter: PSPlayer = _foreign(1, 1, 84)
	low_starter.role = "starter"
	var low_reliever: PSPlayer = _foreign(1, 1, 82)
	low_reliever.role = "reliever"
	var active_batter: PSPlayer = _foreign(1, 9, 80)
	players.append_array([low_pa, low_starter, low_reliever, active_batter])

	var low_pa_rec: PSPlayerSeasonRecord = _seed_record(low_pa, season)
	low_pa_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA
	low_pa_rec.batter_stats.games = 60

	var low_starter_rec: PSPlayerSeasonRecord = _seed_record(low_starter, season)
	low_starter_rec.role = "starter"
	low_starter_rec.pitcher_stats.starts = Offseason.FOREIGN_RELEASE_STARTER_MAX_STARTS
	low_starter_rec.pitcher_stats.games = Offseason.FOREIGN_RELEASE_STARTER_MAX_STARTS

	var low_reliever_rec: PSPlayerSeasonRecord = _seed_record(low_reliever, season)
	low_reliever_rec.role = "reliever"
	low_reliever_rec.pitcher_stats.starts = 0
	low_reliever_rec.pitcher_stats.relief_appearances = Offseason.FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES
	low_reliever_rec.pitcher_stats.games = Offseason.FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES

	var active_rec: PSPlayerSeasonRecord = _seed_record(active_batter, season)
	active_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA + 1
	active_rec.batter_stats.games = 80

	var result: Dictionary = Offseason.process_foreign_releases(players, teams, season)
	ok = _expect(int(result.get("released_count", 0)) == 3, "3 low-usage foreign players released (got %d)" % int(result.get("released_count", 0)), ok)
	ok = _expect(low_pa.is_retired() and low_starter.is_retired() and low_reliever.is_retired(), "low-usage foreign players retired", ok)
	ok = _expect(not active_batter.is_retired(), "foreign just above usage threshold kept", ok)
	for row in result.get("released", []) as Array:
		ok = _expect(str((row as Dictionary).get("reason", "")) == "低稼働", "low-usage release reason recorded", ok)

	RecordStore.player_records.clear()
	return ok


func _test_weak_first_year_foreign_released_after_one_season() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1)]
	var season: PSSeason = _season(2026)
	var players: Array = []
	RecordStore.player_records.clear()

	var weak: PSPlayer = _foreign(1, 7, 50)
	weak.years = 1
	var regular: PSPlayer = _foreign(1, 9, 74)
	regular.years = 1
	players.append_array([weak, regular])

	var weak_rec: PSPlayerSeasonRecord = _seed_record(weak, season)
	weak_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA + 30
	weak_rec.batter_stats.games = 70
	var regular_rec: PSPlayerSeasonRecord = _seed_record(regular, season)
	regular_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA + 30
	regular_rec.batter_stats.games = 70

	var result: Dictionary = Offseason.process_foreign_releases(players, teams, season)
	ok = _expect(Offseason.player_value_score(weak) < Offseason.FOREIGN_RELEASE_MIN_VALUE, "weak foreign is below release value bar", ok)
	ok = _expect(weak.is_retired(), "weak first-year foreign released after one season", ok)
	ok = _expect(not regular.is_retired(), "regular first-year foreign kept", ok)
	ok = _expect(int(result.get("released_count", 0)) == 1, "exactly weak first-year foreign released (got %d)" % int(result.get("released_count", 0)), ok)
	for row in result.get("released", []) as Array:
		ok = _expect(str((row as Dictionary).get("reason", "")) == "能力不足", "weak foreign release reason recorded", ok)

	RecordStore.player_records.clear()
	return ok


func _test_user_auto_candidates_include_foreign_releases() -> bool:
	var ok: bool = true
	var team_id: int = 1
	var season: PSSeason = _season(2026)
	var players: Array = []
	RecordStore.player_records.clear()

	var weak: PSPlayer = _foreign(team_id, 7, 40)
	var low_usage: PSPlayer = _foreign(team_id, 9, 80)
	var active: PSPlayer = _foreign(team_id, 3, 80)
	players.append_array([weak, low_usage, active])

	var weak_rec: PSPlayerSeasonRecord = _seed_record(weak, season)
	weak_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA + 40
	weak_rec.batter_stats.games = 70
	var low_usage_rec: PSPlayerSeasonRecord = _seed_record(low_usage, season)
	low_usage_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA
	low_usage_rec.batter_stats.games = 60
	var active_rec: PSPlayerSeasonRecord = _seed_record(active, season)
	active_rec.batter_stats.plate_appearances = Offseason.FOREIGN_RELEASE_FIELDER_MAX_PA + 40
	active_rec.batter_stats.games = 80

	var normal_ids: Array = Offseason.compute_release_candidates_for_team(players, team_id, season)
	var with_foreign_ids: Array = Offseason.compute_release_candidates_for_team(players, team_id, season, true)
	ok = _expect(not normal_ids.has(weak.id) and not normal_ids.has(low_usage.id), "normal release auto keeps foreign out", ok)
	ok = _expect(with_foreign_ids.has(weak.id), "user auto release includes weak foreign", ok)
	ok = _expect(with_foreign_ids.has(low_usage.id), "user auto release includes low-usage foreign", ok)
	ok = _expect(not with_foreign_ids.has(active.id), "user auto release keeps active foreign", ok)

	RecordStore.player_records.clear()
	return ok


func _test_foreign_release_can_exclude_user_team() -> bool:
	var ok: bool = true
	var season: PSSeason = _season(2026)
	var teams: Array = [_team(1), _team(2)]
	var user_weak: PSPlayer = _foreign(1, 7, 40)
	var cpu_weak: PSPlayer = _foreign(2, 7, 40)
	var players: Array = [user_weak, cpu_weak]

	var result: Dictionary = Offseason.process_foreign_releases(players, teams, season, 1)
	ok = _expect(not user_weak.is_retired(), "excluded user foreign is not auto-released", ok)
	ok = _expect(cpu_weak.is_retired(), "CPU foreign is still auto-released", ok)
	ok = _expect(int(result.get("released_count", 0)) == 1, "only CPU foreign released when user team excluded", ok)
	return ok


# 外国人 0 の球団が1オフで4枠まで埋める。保有 ≤4 / 総数 ≤70。
func _test_foreign_market_fills_slots() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1), _team(2)]
	var players: Array = []
	# 各チーム少数の日本人 (枠は十分空き)。外国人ゼロ。
	for t in [1, 2]:
		for pos in [2, 3, 4, 5, 6, 7, 8, 9, 1, 1]:
			players.append(_jp(t, pos, 55))

	var before_total: int = players.size()
	var result: Dictionary = Foreign.process_foreign_market(players, teams, _season(2026), 0)

	ok = _expect(int(result.get("signed_count", 0)) == 8, "two empty teams signed 8 foreign total (got %d)" % int(result.get("signed_count", 0)), ok)
	# 保有上限 4、総数 70 を超えない。新規署名ぶん players が増える。
	ok = _expect(_active_foreign(players, 1) == 4 and _active_foreign(players, 2) == 4, "foreign held filled to 4 per team", ok)
	ok = _expect(_active_count(players, 1) <= 70 and _active_count(players, 2) <= 70, "roster <= 70", ok)
	ok = _expect(players.size() == before_total + int(result.get("signed_count", 0)), "signed foreigners appended to players", ok)
	# 署名された外国人は foreign_player フラグと team_id を持つ。
	for s_row in result.get("signings", []) as Array:
		var s: Dictionary = s_row as Dictionary
		var pid: int = int(s.get("player_id", 0))
		var found: PSPlayer = null
		for p_row in players:
			if (p_row as PSPlayer).id == pid:
				found = p_row as PSPlayer
		ok = _expect(found != null and found.foreign_player and found.team_id == int(s.get("to_team", 0)), "signed foreign on acquiring team", ok)
	return ok


# 自軍は候補表から任意の外国人を手動で獲得できる。
func _test_user_manual_foreign_signing() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1), _team(2)]
	var players: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9, 1, 1]:
		players.append(_jp(1, pos, 55))
		players.append(_jp(2, pos, 55))

	var state: Dictionary = Foreign.create_foreign_market_state(players, teams, _season(2026), 1)
	var candidates: Array = Foreign.available_user_candidates(state, players, teams)
	ok = _expect(not candidates.is_empty(), "user foreign candidates exist", ok)
	if candidates.is_empty():
		return ok

	var candidate: Dictionary = candidates[0] as Dictionary
	var candidate_id: int = int(candidate.get("candidate_id", 0))
	var before_count: int = players.size()
	var result: Dictionary = Foreign.submit_user_foreign_decision(state, players, teams, _season(2026), candidate_id, "sign")
	ok = _expect(bool(result.get("ok", false)), "manual foreign signing accepted", ok)
	ok = _expect(players.size() == before_count + 1, "manual signing appended one player", ok)
	ok = _expect(_active_foreign(players, 1) == 1, "manual signing belongs to user team", ok)
	var signings: Array = state.get("signings", []) as Array
	ok = _expect(not signings.is_empty() and str((signings[0] as Dictionary).get("method", "")) == "user", "manual signing records user method", ok)
	var state_candidate: Dictionary = _candidate_by_id(state, candidate_id)
	ok = _expect(not bool(state_candidate.get("available", true)), "signed candidate is no longer available", ok)
	return ok


func _test_foreign_candidate_contract_clock() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1)]
	var players: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9, 1, 1]:
		players.append(_jp(1, pos, 55))

	var state: Dictionary = Foreign.create_foreign_market_state(players, teams, _season(2026), 1)
	var candidates: Array = Foreign.available_user_candidates(state, players, teams)
	ok = _expect(not candidates.is_empty(), "foreign candidates exist for contract clock", ok)
	if candidates.is_empty():
		return ok

	var candidate: Dictionary = candidates[0] as Dictionary
	var data: Dictionary = candidate.get("player_data", {}) as Dictionary
	ok = _expect(int(data.get("years", -1)) == 0, "foreign candidate starts at offseason years=0", ok)
	var before_count: int = players.size()
	var result: Dictionary = Foreign.submit_user_foreign_decision(state, players, teams, _season(2026), int(candidate.get("candidate_id", 0)), "sign")
	ok = _expect(bool(result.get("ok", false)), "contract clock signing accepted", ok)
	ok = _expect(players.size() == before_count + 1, "contract clock signing appended player", ok)
	if players.size() > before_count:
		var signed: PSPlayer = players[players.size() - 1] as PSPlayer
		ok = _expect(signed.foreign_player and signed.years == 0, "signed foreign remains years=0 until next season starts", ok)
		signed.years += 1
		ok = _expect(signed.years == 1, "signed foreign becomes first-year player after season-start increment", ok)
	return ok


func _test_foreign_position_bias() -> bool:
	var ok: bool = true
	Rng.set_seed_value(20260606)
	var counts: Dictionary = {}
	for i in range(600):
		var pos: int = Foreign._candidate_position()
		counts[pos] = int(counts.get(pos, 0)) + 1
	var catcher_count: int = int(counts.get(2, 0))
	var middle_count: int = int(counts.get(4, 0)) + int(counts.get(6, 0))
	var corner_outfield_count: int = int(counts.get(3, 0)) + int(counts.get(5, 0)) + int(counts.get(7, 0)) + int(counts.get(9, 0))
	ok = _expect(catcher_count < middle_count, "catcher rarer than middle infield (C=%d MI=%d)" % [catcher_count, middle_count], ok)
	ok = _expect(middle_count < corner_outfield_count, "middle infield rarer than corner/OF bats (MI=%d bats=%d)" % [middle_count, corner_outfield_count], ok)
	var base_center: int = 68
	var catcher_center: int = Foreign._adjusted_center_for_position(base_center, 2)
	var second_center: int = Foreign._adjusted_center_for_position(base_center, 4)
	var first_center: int = Foreign._adjusted_center_for_position(base_center, 3)
	ok = _expect(catcher_center < second_center and second_center < first_center, "C penalty > MI penalty > bat positions", ok)
	ok = _expect(int((Foreign.QUALITY_TIERS[0] as Dictionary).get("center", 0)) <= 72, "foreign top tier center is capped lower", ok)
	return ok


# --- helpers ---
func _id() -> int:
	var v: int = _next_id
	_next_id += 1
	return v


func _batter_pos() -> int:
	return Rng.range_int(2, 9)


func _active_foreign(players: Array, team_id: int) -> int:
	var c: int = 0
	for p_row in players:
		var p: PSPlayer = p_row as PSPlayer
		if p.team_id == team_id and p.foreign_player and not p.is_retired():
			c += 1
	return c


func _active_count(players: Array, team_id: int) -> int:
	var c: int = 0
	for p_row in players:
		var p: PSPlayer = p_row as PSPlayer
		if p.team_id == team_id and not p.is_retired():
			c += 1
	return c


func _candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if int(candidate.get("candidate_id", 0)) == candidate_id:
			return candidate
	return {}


func _team(id: int) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "short_name": "T%d" % id, "league": "central", "funds": 200000})


func _season(year: int) -> PSSeason:
	var s: PSSeason = PSSeason.new()
	s.year = year
	s.season_number = 1
	return s


func _seed_record(player: PSPlayer, season: PSSeason) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, season.year, season.season_number)
	RecordStore.player_records["%d:%d:%d" % [player.id, season.year, season.season_number]] = rec
	return rec


func _foreign(team_id: int, position: int, center: int) -> PSPlayer:
	return _make(team_id, position, center, true)


func _jp(team_id: int, position: int, center: int) -> PSPlayer:
	return _make(team_id, position, center, false)


func _make(team_id: int, position: int, center: int, foreign: bool) -> PSPlayer:
	return PSPlayer.from_dict({
		"id": _id(),
		"team_id": team_id,
		"name": ("F" if foreign else "J") + str(_next_id),
		"age": 28,
		"years": 3,
		"position": position,
		"role": "starter" if position == 1 else "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 5000,
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": foreign,
		"position_aptitudes": {Offseason.POSITION_NAME_BY_ID.get(position, "first"): 100},
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, center, min(center + 8, 99)),
		"fatigue": 0,
		"injury_days": 0,
	})


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[foreign_market] FAIL: %s" % label)
		return false
	return running_ok
