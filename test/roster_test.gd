extends GdUnitTestSuite

# roadmap #3 育成選手制度: 支配下/育成の計数、昇格/降格、一軍出場不可、永続化を検証する。

const Offseason = preload("res://services/season/offseason_service.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")

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


func test_process_demotion_respects_development_cap() -> void:
	var players: Array = _support_players(1, 3)
	# 育成枠を満杯にする。
	for i in range(TeamFinance.DEVELOPMENT_LIMIT):
		players.append(_player({"id": 5000 + i, "team_id": 1, "development_player": true}))
	var support_id: int = (players[0] as PSPlayer).id
	var result: Dictionary = Offseason.process_demotion(players, 1, [support_id])
	assert_int(int(result.get("demoted_count", 0))).is_equal(0)
	assert_bool((players[0] as PSPlayer).development_player).is_false()


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


func test_development_release_trims_over_cap_excess() -> void:
	var players: Array = []
	# 上限+3 人の若い育成 (全員 keep 条件だが上限超過分は放出)。
	for i in range(TeamFinance.DEVELOPMENT_LIMIT + 3):
		var dev: PSPlayer = _player_with_z(2000 + i, 1, 3, true, 0.5)
		dev.age = 20
		players.append(dev)
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(3)
	assert_int(TeamFinance.development_count(players, 1)).is_equal(TeamFinance.DEVELOPMENT_LIMIT)


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


func _team(team_id: int) -> PSTeam:
	return PSTeam.from_dict({
		"id": team_id,
		"name": "Team %d" % team_id,
		"short_name": "T%d" % team_id,
		"league": "central",
	})
