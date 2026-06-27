extends GdUnitTestSuite

# roadmap #3 育成選手制度: 支配下/育成の計数、昇格/降格、一軍出場不可、永続化を検証する。

const Offseason = preload("res://services/season/offseason_service.gd")
const ReleasedMarket = preload("res://services/season/released_market_service.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const TeamAutoAIRef = preload("res://services/season/team_auto_ai.gd")

const ALL_Z_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Spray", "Bat_Aggression", "Bat_Platoon",
	"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
	"Run_Speed", "Run_Judgment", "Run_Steal",
]


# --- 計数 -------------------------------------------------------------------

func test_shienka_count_excludes_development() -> void:
	var players: Array = [
		_player({"id": 1, "team_id": 1}),
		_player({"id": 2, "team_id": 1}),
		_player({"id": 3, "team_id": 1, "development_player": true}),
		_player({"id": 4, "team_id": 2}),
	]
	assert_int(TeamFinance.shienka_count(players, 1)).is_equal(2)
	assert_int(TeamFinance.development_count(players, 1)).is_equal(1)
	assert_int(TeamFinance.shienka_count(players, 2)).is_equal(1)


func test_room_helpers_track_limits() -> void:
	var players: Array = _support_players(1, TeamFinance.SHIENKA_LIMIT)
	assert_bool(TeamFinance.has_shienka_room(players, 1)).is_false()
	players.append(_player({"id": 999, "team_id": 1, "development_player": true}))
	# 育成を足しても支配下枠には影響しない。
	assert_bool(TeamFinance.has_shienka_room(players, 1)).is_false()
	assert_bool(TeamFinance.has_development_room(players, 1)).is_true()


func test_released_market_respects_foreign_held_cap() -> void:
	var open_team_players: Array = _released_market_foreign_cap_players(3)
	var open_result: Dictionary = ReleasedMarket.process_released_market(
		open_team_players,
		[_team(1), _team(2)],
		null,
		{"released": [{"player_id": 9100, "team_id": 1}]},
		0
	)
	assert_int(int(open_result.get("signed_count", 0))).is_equal(1)
	assert_int((open_team_players[open_team_players.size() - 1] as PSPlayer).team_id).is_equal(2)

	var capped_team_players: Array = _released_market_foreign_cap_players(4)
	var capped_result: Dictionary = ReleasedMarket.process_released_market(
		capped_team_players,
		[_team(1), _team(2)],
		null,
		{"released": [{"player_id": 9100, "team_id": 1}]},
		0
	)
	assert_int(int(capped_result.get("signed_count", 0))).is_equal(0)
	assert_int((capped_team_players[capped_team_players.size() - 1] as PSPlayer).team_id).is_equal(0)


# --- 降格 (支配下 → 育成) ----------------------------------------------------

func test_process_demotion_marks_development_and_frees_slot() -> void:
	var players: Array = [
		_player({"id": 10, "team_id": 1}),
		_player({"id": 11, "team_id": 1}),
	]
	var before: int = TeamFinance.shienka_count(players, 1)
	var result: Dictionary = Offseason.process_demotion(players, 1, [10])
	assert_int(int(result.get("demoted_count", 0))).is_equal(1)
	var demoted: PSPlayer = players[0] as PSPlayer
	assert_bool(demoted.development_player).is_true()
	assert_str(demoted.registered_roster).is_equal("育成")
	assert_bool(demoted.is_retired()).is_false()  # release と違い org に残る
	assert_int(demoted.team_id).is_equal(1)
	assert_int(TeamFinance.shienka_count(players, 1)).is_equal(before - 1)


func test_demotion_not_blocked_by_development_count() -> void:
	# 育成は人数無制限: 既に多数の育成が居ても支配下→育成 降格は通る。
	var players: Array = _support_players(1, 3)
	for i in range(20):
		players.append(_player({"id": 5000 + i, "team_id": 1, "development_player": true}))
	var support_id: int = (players[0] as PSPlayer).id
	var result: Dictionary = Offseason.process_demotion(players, 1, [support_id])
	assert_int(int(result.get("demoted_count", 0))).is_equal(1)
	assert_bool((players[0] as PSPlayer).development_player).is_true()


# --- 昇格 (育成 → 支配下) ----------------------------------------------------

func test_promotion_moves_strong_dev_to_shienka() -> void:
	var strong_dev: PSPlayer = _player_with_z(20, 1, 3, true, 2.5)
	var players: Array = [strong_dev, _player({"id": 21, "team_id": 1})]
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(1)
	assert_bool(strong_dev.development_player).is_false()
	assert_str(strong_dev.registered_roster).is_equal("支配下")


func test_promotion_skips_weak_dev() -> void:
	var weak_dev: PSPlayer = _player_with_z(30, 1, 3, true, -3.0)
	var players: Array = [weak_dev]
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(weak_dev.development_player).is_true()


func test_promotion_blocked_when_no_shienka_room() -> void:
	var players: Array = _support_players(1, TeamFinance.SHIENKA_LIMIT)
	var strong_dev: PSPlayer = _player_with_z(40, 1, 3, true, 2.5)
	players.append(strong_dev)
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(strong_dev.development_player).is_true()


func test_promotion_excludes_user_team() -> void:
	var strong_dev: PSPlayer = _player_with_z(50, 1, 3, true, 2.5)
	var result: Dictionary = Offseason.process_development_promotions([strong_dev], [_team(1)], 1)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(strong_dev.development_player).is_true()


# --- 即戦力基準は球団相対 --------------------------------------------------

func test_first_team_ready_threshold_is_relative() -> void:
	# 弱い一軍 (低能力支配下31人) は基準が floor、強い一軍 (高能力31人) は ceiling。
	var weak: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		weak.append(_player_with_z(3000 + i, 1, 3, false, -2.0))
	var strong: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		strong.append(_player_with_z(4000 + i, 2, 3, false, 2.5))
	var weak_threshold: float = Offseason.first_team_ready_threshold(weak, 1)
	var strong_threshold: float = Offseason.first_team_ready_threshold(strong, 2)
	assert_float(weak_threshold).is_less(strong_threshold)
	assert_float(weak_threshold).is_equal(Offseason.PROMOTE_READY_FLOOR)
	assert_float(strong_threshold).is_equal(Offseason.PROMOTE_READY_CEILING)


func test_promotion_respects_relative_threshold() -> void:
	# 同能力の中堅育成が、弱い一軍の球団では即戦力(昇格)、強い一軍の球団では基準未満(据え置き)。
	var players: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		players.append(_player_with_z(5000 + i, 1, 3, false, -2.0))  # team1: 弱い支配下
	for i in range(Offseason.FIRST_TEAM_SIZE):
		players.append(_player_with_z(6000 + i, 2, 3, false, 2.5))   # team2: 強い支配下
	var dev_weak_team: PSPlayer = _player_with_z(7001, 1, 3, true, 0.4)
	var dev_strong_team: PSPlayer = _player_with_z(7002, 2, 3, true, 0.4)
	players.append(dev_weak_team)
	players.append(dev_strong_team)
	Offseason.process_development_promotions(players, [_team(1), _team(2)], 0)
	assert_bool(dev_weak_team.development_player).is_false()  # 弱い球団 → 昇格
	assert_bool(dev_strong_team.development_player).is_true()  # 強い球団 → 据え置き


# --- 育成整理 (pipeline 循環) ------------------------------------------------

func test_development_release_cuts_failed_prospect_keeps_viable_young() -> void:
	# 若く将来価値のある素材 (viable) は猶予を過ぎても保持。
	var young_viable: PSPlayer = _player_with_z(80, 1, 3, true, 0.6)
	young_viable.age = 20
	young_viable.years = 5
	# 在籍年数が出身別猶予を超え、昇格見込みも無い (非 viable) 失敗プロスペクトは放出。
	var aged_weak: PSPlayer = _player_with_z(81, 1, 3, true, -2.0)
	aged_weak.age = 30
	aged_weak.years = 3
	var players: Array = [young_viable, aged_weak]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(young_viable.is_retired()).is_false()
	assert_bool(young_viable.development_player).is_true()
	assert_bool(aged_weak.is_retired()).is_true()


func test_development_release_keeps_first_year() -> void:
	# 1年目 (years<=1) の育成は将来価値が低くても原則保持。
	var first_year: PSPlayer = _player_with_z(82, 1, 3, true, -2.0)
	first_year.age = 24
	first_year.years = 1
	var tenured: PSPlayer = _player_with_z(83, 1, 3, true, -2.0)
	tenured.age = 24
	tenured.years = 5  # 猶予 (大社3) を超え昇格見込み無し → 放出
	var players: Array = [first_year, tenured]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_bool(first_year.is_retired()).is_false()
	assert_bool(tenured.is_retired()).is_true()


func test_development_release_high_school_longer_grace() -> void:
	# 同条件 (非 viable・在籍3年) でも高卒は猶予4年で保持、大社は猶予3年で放出。
	var hs: PSPlayer = _player_with_z(84, 1, 3, true, -2.0)
	hs.age = 21
	hs.years = 3
	hs.source_data = {"draft_source": "high_school"}
	var college: PSPlayer = _player_with_z(85, 1, 3, true, -2.0)
	college.age = 21
	college.years = 3
	college.source_data = {"draft_source": "university"}
	var players: Array = [hs, college]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(hs.is_retired()).is_false()
	assert_bool(college.is_retired()).is_true()


# --- 統一スコア future_value_score / 故障リスク -------------------------------

func test_future_value_score_rewards_youth() -> void:
	var young: PSPlayer = _player_with_z(90, 1, 3, false, 0.0)
	young.age = 20
	var old: PSPlayer = _player_with_z(91, 1, 3, false, 0.0)
	old.age = 31
	assert_float(Offseason.future_value_score(young)).is_greater(Offseason.future_value_score(old))


func test_injury_value_penalty_scales_and_caps() -> void:
	var healthy: PSPlayer = _player({"id": 92, "team_id": 1})
	var hurt: PSPlayer = _player({"id": 93, "team_id": 1, "injury_days": 60})
	var wrecked: PSPlayer = _player({"id": 94, "team_id": 1, "injury_days": 300})
	assert_float(Offseason.injury_value_penalty(healthy)).is_equal(0.0)
	assert_float(Offseason.injury_value_penalty(hurt)).is_equal(2.0)
	assert_float(Offseason.injury_value_penalty(wrecked)).is_equal(Offseason.INJURY_PENALTY_CAP)


# --- 支配下→育成 降格の3類型 -------------------------------------------------

func test_should_demote_prospect_injured_not_veteran() -> void:
	# 素材保持型: 若く将来価値が残る → 降格
	var prospect: PSPlayer = _player_with_z(95, 1, 3, false, 0.5)
	prospect.age = 22
	assert_bool(Offseason._should_demote_to_development(prospect)).is_true()
	# 低価値ベテラン (故障なし) → 降格せず (= 戦力外側)
	var veteran: PSPlayer = _player_with_z(96, 1, 3, false, -0.5)
	veteran.age = 33
	assert_bool(Offseason._should_demote_to_development(veteran)).is_false()
	# 長期故障/再調整型: 復帰すれば戦力 → 降格
	var injured: PSPlayer = _player_with_z(97, 1, 3, false, 0.5)
	injured.age = 29
	injured.injury_days = 150
	assert_bool(Offseason._should_demote_to_development(injured)).is_true()
	# 同じ故障でも高齢すぎる (>31) → 降格対象外
	var injured_old: PSPlayer = _player_with_z(98, 1, 3, false, 0.5)
	injured_old.age = 34
	injured_old.injury_days = 150
	assert_bool(Offseason._should_demote_to_development(injured_old)).is_false()


func test_demotion_age30_requires_serious_injury() -> void:
	# 30歳・大怪我 (重傷) → 降格可
	var serious: PSPlayer = _player_with_z(100, 1, 3, false, 0.5)
	serious.age = 30
	serious.injury_days = 150
	serious.injury_severity = PSInjuryModel.TIER_MAJOR
	assert_bool(Offseason._should_demote_to_development(serious)).is_true()
	# 30歳・大怪我でない (中度) → 降格しない (長期離脱日数でも severity で弾く)
	var minor: PSPlayer = _player_with_z(101, 1, 3, false, 0.5)
	minor.age = 30
	minor.injury_days = 150
	minor.injury_severity = PSInjuryModel.TIER_MODERATE
	assert_bool(Offseason._should_demote_to_development(minor)).is_false()
	# 29歳は長期故障なら大怪我でなくても降格可 (30歳境界の確認)
	var young: PSPlayer = _player_with_z(102, 1, 3, false, 0.5)
	young.age = 29
	young.injury_days = 150
	young.injury_severity = PSInjuryModel.TIER_MODERATE
	assert_bool(Offseason._should_demote_to_development(young)).is_true()


func test_development_release_cuts_aged_out_26plus() -> void:
	# 26歳以上・健康・昇格水準未満 (failed) → 優先放出
	var aged_failed: PSPlayer = _player_with_z(103, 1, 3, true, -1.0)
	aged_failed.age = 27
	aged_failed.years = 3
	# 26歳以上でも昇格水準 (value≥48) の即戦力は保持 (満枠で昇格できなかっただけ)
	var aged_ready: PSPlayer = _player_with_z(105, 1, 3, true, 2.5)
	aged_ready.age = 27
	aged_ready.years = 3
	# 故障リハビリ中の26+は保持 (故障回復待ち)
	var rehab: PSPlayer = _player_with_z(104, 1, 3, true, 0.6)
	rehab.age = 27
	rehab.years = 3
	rehab.injury_days = 150
	var players: Array = [aged_failed, aged_ready, rehab]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(aged_failed.is_retired()).is_true()
	assert_bool(aged_ready.is_retired()).is_false()
	assert_bool(rehab.is_retired()).is_false()
	assert_bool(rehab.development_player).is_true()


func test_development_release_keeps_many_viable_young() -> void:
	# 育成は人数無制限: 大量の若い viable 育成は全員保持 (枠超過放出は無し)。
	var players: Array = []
	for i in range(20):
		var dev: PSPlayer = _player_with_z(2000 + i, 1, 3, true, 0.5)
		dev.age = 20
		players.append(dev)
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(0)
	assert_int(TeamFinance.development_count(players, 1)).is_equal(20)


# --- 一軍出場不可 ------------------------------------------------------------

func test_eligible_or_fallback_excludes_development() -> void:
	var support: PSPlayer = _player({"id": 60, "team_id": 1})
	var dev: PSPlayer = _player({"id": 61, "team_id": 1, "development_player": true})
	var records: Array = [
		PSPlayerSeasonRecord.from_player(support, 0, 0),
		PSPlayerSeasonRecord.from_player(dev, 0, 0),
	]
	var eligible: Array = TeamSetupBuilder.eligible_or_fallback(records, 1)
	var ids: Array = []
	for row in eligible:
		ids.append((row as PSPlayerSeasonRecord).player_id)
	assert_array(ids).contains(60)
	assert_array(ids).not_contains(61)


func test_high_fatigue_record_is_not_auto_demotion_candidate() -> void:
	var player: PSPlayer = _player_with_z(62, 1, 3, false, 0.4)
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	record.fatigue = TeamAutoAIRef.DEMOTION_FATIGUE_PROTECT_THRESHOLD
	record.batter_stats.plate_appearances = 0

	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 1.0, 100, 70.0, 70.0, 70.0)).is_false()

	record.fatigue = TeamAutoAIRef.DEMOTION_FATIGUE_PROTECT_THRESHOLD - 1
	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 1.0, 100, 70.0, 70.0, 70.0)).is_true()


# --- 永続化 ------------------------------------------------------------------

func test_development_fields_round_trip() -> void:
	var player: PSPlayer = _player({"id": 70, "team_id": 1, "development_player": true, "registered_roster": "育成"})
	var restored: PSPlayer = PSPlayer.from_dict(player.to_dict())
	assert_bool(restored.development_player).is_true()
	assert_str(restored.registered_roster).is_equal("育成")


# --- helpers -----------------------------------------------------------------

func _player(data: Dictionary) -> PSPlayer:
	var payload: Dictionary = {
		"age": 24,
		"years": 3,
		"position": 3,
		"role": "fielder",
		"throws": "R",
		"bats": "R",
		"z_abilities": {},
		"raw_abilities": {},
	}
	for key in data.keys():
		payload[key] = data[key]
	return PSPlayer.from_dict(payload)


func _player_with_z(id: int, team_id: int, position: int, dev: bool, z_value: float) -> PSPlayer:
	var z: Dictionary = {}
	for key in ALL_Z_KEYS:
		z[key] = z_value
	return _player({
		"id": id,
		"team_id": team_id,
		"position": position,
		"role": "fielder",
		"development_player": dev,
		"z_abilities": z,
	})


# team_id の支配下選手を count 人作る (id は 1000 番台)。
func _support_players(team_id: int, count: int) -> Array:
	var players: Array = []
	for i in range(count):
		players.append(_player({"id": 1000 + i, "team_id": team_id}))
	return players


func _released_market_foreign_cap_players(team2_foreign_count: int) -> Array:
	var players: Array = []
	# team1 の強い一塁手で team2 に明確な補強ニーズを作る。
	players.append(_player_with_z(9001, 1, 3, false, 2.5))
	players.append(_player_with_z(9002, 2, 3, false, -2.0))
	for i in range(team2_foreign_count):
		players.append(_player({
			"id": 9050 + i,
			"team_id": 2,
			"position": 1 + (i % 9),
			"foreign_player": true,
		}))
	var released_foreign: PSPlayer = _player_with_z(9100, 0, 3, false, 2.5)
	released_foreign.foreign_player = true
	released_foreign.source_data = {"released": true}
	players.append(released_foreign)
	return players


func _team(team_id: int) -> PSTeam:
	return PSTeam.from_dict({
		"id": team_id,
		"name": "Team %d" % team_id,
		"short_name": "T%d" % team_id,
		"league": "central",
	})
