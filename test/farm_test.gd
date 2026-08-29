extends GdUnitTestSuite

# 二軍 (ファーム) のドメイン suite。地区構成・専用球団の隔離・二軍日程・成績の器・永続化を
# まとめて見る。新機能はこの suite に test_* を足す (1テスト1ファイルにしない)。

const SaveContext = preload("res://services/storage/save_context.gd")


func before() -> void:
	if GameDb.teams.is_empty():
		GameDb.load_initial_data()


func _first_team_ids() -> Array:
	var ids: Array = []
	for team_row in GameDb.teams:
		ids.append((team_row as PSTeam).id)
	return ids


func _farm_team_ids() -> Array:
	return PSFarmLeague.all_team_ids(_first_team_ids())


func _generate_schedule() -> Dictionary:
	var first_schedule: Array = PSSchedule.generate_pennant_schedule(
		GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1
	)
	var farm_team_ids: Array = _farm_team_ids()
	return {
		"first": first_schedule,
		"team_ids": farm_team_ids,
		"farm": PSFarmSchedule.generate(first_schedule, farm_team_ids),
	}


# ---- 地区構成 --------------------------------------------------------------

func test_farm_league_is_fourteen_teams_in_three_districts() -> void:
	var farm_team_ids: Array = _farm_team_ids()
	assert_int(farm_team_ids.size()).is_equal(14)

	var by_district: Dictionary = PSFarmLeague.team_ids_by_district(farm_team_ids)
	# 実 NPB の 2026 年構成に合わせた 東5 / 中5 / 西4。
	assert_int((by_district[PSFarmLeague.DISTRICT_EAST] as Array).size()).is_equal(5)
	assert_int((by_district[PSFarmLeague.DISTRICT_CENTRAL] as Array).size()).is_equal(5)
	assert_int((by_district[PSFarmLeague.DISTRICT_WEST] as Array).size()).is_equal(4)


func test_every_farm_team_belongs_to_exactly_one_district() -> void:
	var seen: Dictionary = {}
	for team_id in _farm_team_ids():
		var district: String = PSFarmLeague.district_for_team(int(team_id))
		assert_bool(PSFarmLeague.DISTRICT_ORDER.has(district)).is_true()
		assert_bool(seen.has(int(team_id))).is_false()
		seen[int(team_id)] = district
	assert_int(seen.size()).is_equal(14)


# ---- 専用球団の隔離 --------------------------------------------------------

func test_farm_clubs_stay_out_of_the_first_team_list() -> void:
	# ここが二軍実装の最重要の不変条件。GameDb.teams の参照は300箇所以上あり、
	# すべて12球団前提なので専用球団が紛れ込むと一軍系が静かに壊れる。
	assert_int(GameDb.teams.size()).is_equal(12)
	assert_int(GameDb.farm_clubs.size()).is_equal(2)
	for club_row in GameDb.farm_clubs:
		var club: PSTeam = club_row as PSTeam
		assert_bool(club.farm_only).is_true()
		# teams / teams_by_id のどちらからも見えない。
		assert_object(GameDb.get_team(club.id)).is_null()
		assert_bool(GameDb.is_farm_club(club.id)).is_true()
		# 専用の参照経路からだけ引ける。
		assert_object(GameDb.get_any_team(club.id)).is_not_null()


func test_farm_club_ids_do_not_collide_with_first_team_ids() -> void:
	var first_ids: Array = _first_team_ids()
	for club_id in PSFarmLeague.farm_club_ids():
		assert_bool(first_ids.has(int(club_id))).is_false()


func test_first_team_entries_are_not_marked_farm_only() -> void:
	for team_row in GameDb.teams:
		assert_bool((team_row as PSTeam).farm_only).is_false()
	assert_int(GameDb.farm_participating_teams().size()).is_equal(14)


# ---- 二軍日程 --------------------------------------------------------------

func test_farm_schedule_gives_every_team_the_target_game_count() -> void:
	var generated: Dictionary = _generate_schedule()
	var validation: Dictionary = PSFarmSchedule.validate(
		generated["farm"] as Array, generated["team_ids"] as Array
	)

	assert_bool(bool(validation.get("ok", false))).override_failure_message(
		"farm schedule invalid: %s" % str(validation.get("errors", []))
	).is_true()
	# 14球団 × 124試合 / 2 = 868試合。全球団が同数。
	assert_int(int(validation.get("min_games_per_team", 0))).is_equal(PSFarmSchedule.GAMES_PER_TEAM)
	assert_int(int(validation.get("max_games_per_team", 0))).is_equal(PSFarmSchedule.GAMES_PER_TEAM)
	assert_int((generated["farm"] as Array).size()).is_equal(PSFarmSchedule.GAMES_PER_TEAM * 14 / 2)


func test_farm_games_only_fall_on_first_team_game_days() -> void:
	# 二軍を一軍の試合日の部分集合に閉じ込めることで、advance_current_day を含む
	# 既存の日進行に一切手を入れずに済む。ここが崩れると二軍戦が飛ばされる。
	var generated: Dictionary = _generate_schedule()
	var first_days: Dictionary = {}
	for game_row in generated["first"] as Array:
		first_days[int((game_row as Dictionary).get("day", 0))] = true

	var farm_days: Dictionary = {}
	for game_row in generated["farm"] as Array:
		var day: int = int((game_row as Dictionary).get("day", 0))
		assert_bool(first_days.has(day)).override_failure_message(
			"farm game on day %d has no first-team game day" % day
		).is_true()
		farm_days[day] = true

	# 一軍の試合日 (約150) より少ない日数へ均等に散らす = ファームの休養日が混ざる。
	assert_int(farm_days.size()).is_less(first_days.size())


func test_farm_schedule_fills_every_team_on_each_farm_day() -> void:
	# 1ラウンド = 14球団の完全マッチング = 7試合。全球団が必ず出場する。
	var generated: Dictionary = _generate_schedule()
	var teams_by_day: Dictionary = {}
	for game_row in generated["farm"] as Array:
		var game: Dictionary = game_row as Dictionary
		var day: int = int(game.get("day", 0))
		if not teams_by_day.has(day):
			teams_by_day[day] = {}
		(teams_by_day[day] as Dictionary)[int(game.get("away_team_id", 0))] = true
		(teams_by_day[day] as Dictionary)[int(game.get("home_team_id", 0))] = true

	for day in teams_by_day.keys():
		assert_int((teams_by_day[day] as Dictionary).size()).override_failure_message(
			"day %d does not field all 14 farm teams" % int(day)
		).is_equal(14)


func test_west_district_plays_the_highest_share_of_intra_district_games() -> void:
	# 西は4球団しかないので地区内比率が最も高くなる (実 NPB も西の地区内が突出して多い)。
	# 地区割りの重み付けが効いているかの検査。
	var generated: Dictionary = _generate_schedule()
	var intra_by_district: Dictionary = {}
	var total_by_district: Dictionary = {}
	for district in PSFarmLeague.DISTRICT_ORDER:
		intra_by_district[district] = 0
		total_by_district[district] = 0

	for game_row in generated["farm"] as Array:
		var game: Dictionary = game_row as Dictionary
		var away_district: String = str(game.get("away_district", ""))
		var home_district: String = str(game.get("home_district", ""))
		var is_intra: bool = not bool(game.get("is_interdistrict", true))
		for district in [away_district, home_district]:
			total_by_district[district] = int(total_by_district[district]) + 1
			if is_intra:
				intra_by_district[district] = int(intra_by_district[district]) + 1

	var west_ratio: float = float(intra_by_district[PSFarmLeague.DISTRICT_WEST]) / float(total_by_district[PSFarmLeague.DISTRICT_WEST])
	var east_ratio: float = float(intra_by_district[PSFarmLeague.DISTRICT_EAST]) / float(total_by_district[PSFarmLeague.DISTRICT_EAST])
	var central_ratio: float = float(intra_by_district[PSFarmLeague.DISTRICT_CENTRAL]) / float(total_by_district[PSFarmLeague.DISTRICT_CENTRAL])
	assert_float(west_ratio).is_greater(east_ratio)
	assert_float(west_ratio).is_greater(central_ratio)


func test_farm_schedule_generation_is_deterministic() -> void:
	var first: Dictionary = _generate_schedule()
	var second: Dictionary = _generate_schedule()
	assert_str(JSON.stringify(first["farm"])).is_equal(JSON.stringify(second["farm"]))


# ---- シーズンへの組み込みと永続化 ------------------------------------------

func test_new_season_builds_farm_schedule_and_standings() -> void:
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	assert_int(season.farm_standings.size()).is_equal(14)
	assert_int(season.farm_schedule.size()).is_equal(PSFarmSchedule.GAMES_PER_TEAM * 14 / 2)
	assert_int(season.farm_games_remaining()).is_equal(season.farm_schedule.size())
	# 二軍が14球団でも、一軍の日程・順位は12球団のまま。
	assert_int(season.standings.size()).is_equal(12)
	assert_int(season.schedule.size()).is_equal(PSSchedule.EXPECTED_TOTAL_GAMES)


func test_farm_game_indices_on_day_matches_the_schedule() -> void:
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	var first_farm_day: int = int((season.farm_schedule[0] as Dictionary).get("day", 0))
	var indices: Array = season.farm_game_indices_on_day(first_farm_day)
	assert_int(indices.size()).is_equal(7)
	for index in indices:
		assert_int(int((season.farm_schedule[int(index)] as Dictionary).get("day", 0))).is_equal(first_farm_day)

	# 二軍の試合が無い日は空を返す (一軍だけが試合をする日)。
	var farm_days: Dictionary = {}
	for game_row in season.farm_schedule:
		farm_days[int((game_row as Dictionary).get("day", 0))] = true
	var idle_day: int = -1
	for game_row in season.schedule:
		var day: int = int((game_row as Dictionary).get("day", 0))
		if not farm_days.has(day):
			idle_day = day
			break
	assert_int(idle_day).is_greater(0)
	assert_array(season.farm_game_indices_on_day(idle_day)).is_empty()


# ---- 専用球団の選手供給 ----------------------------------------------------

func _reload_world() -> void:
	GameDb.load_initial_data()


func test_farm_clubs_start_with_a_full_roster() -> void:
	_reload_world()
	for club_id in PSFarmLeague.farm_club_ids():
		assert_int(FarmClubService.roster_count(GameDb.players, int(club_id))).is_equal(
			FarmClubService.ROSTER_TARGET
		)


func test_generated_roster_can_field_a_game() -> void:
	# 守備位置を quota で明示的に埋めているので、二軍戦を組むのに必要な頭数が必ず揃う。
	_reload_world()
	for club_id in PSFarmLeague.farm_club_ids():
		var by_position: Dictionary = {}
		var pitchers: int = 0
		var starters: int = 0
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id)):
			var player: PSPlayer = player_row as PSPlayer
			by_position[player.position] = int(by_position.get(player.position, 0)) + 1
			if player.position == 1:
				pitchers += 1
				if player.role == "starter":
					starters += 1
		assert_int(pitchers).is_greater_equal(15)
		assert_int(starters).is_equal(FarmClubService.STARTER_ROLE_TARGET)
		# 捕手2人以上 + 内外野の全ポジションに本職が居る。
		assert_int(int(by_position.get(2, 0))).is_greater_equal(2)
		for position in [3, 4, 5, 6, 7, 8, 9]:
			assert_int(int(by_position.get(position, 0))).override_failure_message(
				"club %d has no player at position %d" % [int(club_id), position]
			).is_greater(0)


func test_farm_club_roster_is_led_by_ex_npb_veterans() -> void:
	# **ロスター像**: 主力は NPB を戦力外になった中堅〜ベテラン、
	# その下に NPB 未経験の若手が付く。供給元が指名資格も決める (元NPB=指名不要 / 未経験=要指名)。
	_reload_world()
	for club_id in PSFarmLeague.farm_club_ids():
		var veterans: Array = []
		var prospects: Array = []
		var pitcher_anchors: Array = []
		var fielder_anchors: Array = []
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id)):
			var player: PSPlayer = player_row as PSPlayer
			assert_bool(FarmClubService.is_farm_club_player(player)).is_true()
			# NPB の支配下/育成の枠組みには乗らない。
			assert_bool(player.development_player).is_false()
			assert_str(player.registered_roster).is_equal(FarmClubService.REGISTERED_ROSTER)
			if FarmClubService.has_npb_experience(player):
				veterans.append(player)
				if bool(player.source_data.get("farm_club_pitcher_anchor", false)):
					pitcher_anchors.append(player)
				if bool(player.source_data.get("farm_club_fielder_anchor", false)):
					fielder_anchors.append(player)
			else:
				prospects.append(player)

		assert_int(veterans.size()).is_equal(FarmClubService.VETERAN_TARGET)
		assert_int(prospects.size()).is_equal(
			FarmClubService.ROSTER_TARGET - FarmClubService.VETERAN_TARGET
		)
		assert_int(pitcher_anchors.size()).is_equal(
			FarmClubService.VETERAN_PITCHER_ANCHOR_TARGET_PER_CLUB
		)
		for anchor_row in pitcher_anchors:
			assert_bool((anchor_row as PSPlayer).is_pitcher()).is_true()
		assert_int(fielder_anchors.size()).is_equal(
			FarmClubService.VETERAN_FIELDER_ANCHOR_TARGET_PER_CLUB
		)
		for anchor_row in fielder_anchors:
			assert_bool((anchor_row as PSPlayer).is_pitcher()).is_false()
		for veteran_row in veterans:
			assert_int((veteran_row as PSPlayer).age).is_between(
				FarmClubService.VETERAN_MIN_AGE, FarmClubService.VETERAN_MAX_AGE
			)
		for prospect_row in prospects:
			assert_int((prospect_row as PSPlayer).age).is_between(
				FarmClubService.GENERATED_MIN_AGE, FarmClubService.GENERATED_MAX_AGE
			)

		# **「主力」= 評価上位を占めること**。ここが崩れると二軍戦で若手だけが並ぶ。
		var ranked: Array = FarmClubService.roster_players(GameDb.players, int(club_id))
		ranked.sort_custom(func(a, b) -> bool:
			return OffseasonService.player_value_score(a as PSPlayer) > OffseasonService.player_value_score(b as PSPlayer)
		)
		var veterans_in_top: int = 0
		for i in range(10):
			if FarmClubService.has_npb_experience(ranked[i] as PSPlayer):
				veterans_in_top += 1
		assert_int(veterans_in_top).override_failure_message(
			"club %d: top10 に元NPBが %d 人しか居ない (主力はベテランのはず)" % [int(club_id), veterans_in_top]
		).is_greater_equal(8)


func test_farm_club_generation_uses_position_specific_ability_references() -> void:
	var reference: Dictionary = {
		0: [{"C_GameCall": -3.0, "Bat_Impact": -3.0}],
		2: [{"C_GameCall": 2.0, "Bat_Impact": 2.0}],
	}
	var catcher_z: Dictionary = FarmClubService._sample_z_abilities(reference, 2)
	assert_float(float(catcher_z.get("C_GameCall", -9.0))).override_failure_message(
		"捕手生成が捕手帯ではなく野手全体帯を参照している"
	).is_greater(1.7)
	assert_float(float(catcher_z.get("Bat_Impact", -9.0))).is_greater(1.7)


func test_farm_club_players_never_enter_npb_controlled_accounting() -> void:
	# 支配下枠 (70) は NPB 球団にだけ適用される概念。専用球団の選手が NPB 球団のロスターへ
	# 紛れ込まないこと、専用球団を足しても各球団の支配下人数が上限内に収まることを見る。
	# (`controlled_count` は team_id で数えるだけなので、専用球団 id を渡せば当然その人数を返す。
	#  production では NPB 球団 id 以外を渡さないので、そこは検査対象にしない。)
	_reload_world()
	var farm_player_ids: Dictionary = {}
	for club_id in PSFarmLeague.farm_club_ids():
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id)):
			farm_player_ids[(player_row as PSPlayer).id] = true
	assert_int(farm_player_ids.size()).is_equal(FarmClubService.ROSTER_TARGET * 2)

	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		assert_int(TeamFinance.controlled_count(GameDb.players, team.id)).is_less_equal(TeamFinance.CONTROLLED_LIMIT)
		for player_row in GameDb.get_players_for_team(team.id):
			assert_bool(farm_player_ids.has((player_row as PSPlayer).id)).override_failure_message(
				"farm club player appears on an NPB roster"
			).is_false()


func test_offseason_supply_signs_released_players_up_to_the_cap() -> void:
	# 上限 const が効いていないと、専用球団には枠制約が無いのでロスターが元NPB選手で埋まる。
	_reload_world()
	var club_ids: Array = PSFarmLeague.farm_club_ids()
	# 空きを作ったうえで、上限を大きく超える数の戦力外選手を用意する。
	var freed: int = 0
	for club_id in club_ids:
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id)):
			if freed >= 40:
				break
			(player_row as PSPlayer).team_id = 0
			(player_row as PSPlayer).source_data["retired"] = true
			freed += 1

	var released_pool: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired() or player.team_id == 0 or PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		if released_pool >= 30:
			break
		player.team_id = 0
		player.source_data["released"] = true
		player.age = 27
		released_pool += 1
	assert_int(released_pool).is_equal(30)

	var result: Dictionary = FarmClubService.process_offseason(GameDb.players, 2026)
	var signings: Array = result.get("signings", []) as Array
	var signed_by_club: Dictionary = {}
	for signing_row in signings:
		var club_id: int = int((signing_row as Dictionary).get("club_id", 0))
		signed_by_club[club_id] = int(signed_by_club.get(club_id, 0)) + 1
	for club_id in club_ids:
		assert_int(int(signed_by_club.get(int(club_id), 0))).is_less_equal(
			FarmClubService.MAX_RELEASED_SIGNINGS_PER_CLUB
		)
	assert_int(signings.size()).is_greater(0)

	# 獲得した選手は NPB 経験ありとして記録され、戦力外市場からは外れる。
	for signing_row in signings:
		var player: PSPlayer = GameDb.get_player(int((signing_row as Dictionary).get("player_id", 0)))
		assert_bool(FarmClubService.has_npb_experience(player)).is_true()
		assert_bool(bool(player.source_data.get("released", false))).is_false()

	# 不足分は生成で埋まり、ロスターは目標人数へ戻る。
	for club_id in club_ids:
		assert_int(FarmClubService.roster_count(GameDb.players, int(club_id))).is_equal(
			FarmClubService.ROSTER_TARGET
		)
	_reload_world()


func test_departed_foreign_players_can_join_farm_clubs_once() -> void:
	_reload_world()
	var club_ids: Array = PSFarmLeague.farm_club_ids()
	# 各球団に外国人上限ぶんの空きを作る。
	for club_id_value in club_ids:
		var removed: int = 0
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id_value)):
			var roster_player: PSPlayer = player_row as PSPlayer
			roster_player.team_id = 0
			roster_player.source_data["retired"] = true
			removed += 1
			if removed >= FarmClubService.FOREIGN_ROSTER_LIMIT_PER_CLUB:
				break

	var candidate_ids: Dictionary = {}
	var candidates_by_group: Dictionary = {"pitcher": 0, "fielder": 0}
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired() or not player.foreign_player or player.team_id <= 0:
			continue
		if PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		var group_key: String = "pitcher" if player.is_pitcher() else "fielder"
		if int(candidates_by_group[group_key]) >= club_ids.size():
			continue
		player.source_data["contract_end_year"] = 2027
		player.source_data["contract_total_years"] = 2
		player.source_data["contract_signed_year"] = 2025
		candidate_ids[player.id] = true
		candidates_by_group[group_key] = int(candidates_by_group[group_key]) + 1
		ForeignPlayerService._apply_contract_departure(player, player.team_id, 2026)
		if int(candidates_by_group["pitcher"]) >= club_ids.size() \
				and int(candidates_by_group["fielder"]) >= club_ids.size():
			break
	assert_int(candidate_ids.size()).is_equal(
		club_ids.size() * FarmClubService.FOREIGN_ROSTER_LIMIT_PER_CLUB
	)

	var signings: Array = FarmClubService._sign_departed_foreign_players(GameDb.players, 2026, 1.0)
	assert_int(signings.size()).is_equal(candidate_ids.size())
	var signed_by_club: Dictionary = {}
	var signed_group_by_club: Dictionary = {}
	for signing_row in signings:
		var signing: Dictionary = signing_row as Dictionary
		var player: PSPlayer = GameDb.get_player(int(signing.get("player_id", 0)))
		var club_id: int = int(signing.get("club_id", 0))
		assert_bool(candidate_ids.has(player.id)).is_true()
		assert_bool(player.foreign_player).is_true()
		assert_bool(player.is_retired()).is_false()
		assert_bool(FarmClubService.has_npb_experience(player)).is_true()
		assert_str(player.registered_roster).is_equal(FarmClubService.REGISTERED_ROSTER)
		assert_bool(player.source_data.has("contract_end_year")).is_false()
		assert_bool(player.source_data.has(PSFarmLeague.SOURCE_KEY_FOREIGN_CONTRACT_DEPARTED_YEAR)).is_false()
		signed_by_club[club_id] = int(signed_by_club.get(club_id, 0)) + 1
		var group_key: String = "pitcher" if player.is_pitcher() else "fielder"
		var club_groups: Dictionary = signed_group_by_club.get(club_id, {}) as Dictionary
		club_groups[group_key] = int(club_groups.get(group_key, 0)) + 1
		signed_group_by_club[club_id] = club_groups
	for club_id_value in club_ids:
		var club_id: int = int(club_id_value)
		assert_int(int(signed_by_club.get(club_id, 0))).is_equal(
			FarmClubService.FOREIGN_ROSTER_LIMIT_PER_CLUB
		)
		var club_groups: Dictionary = signed_group_by_club.get(club_id, {}) as Dictionary
		assert_int(int(club_groups.get("pitcher", 0))).is_equal(1)
		assert_int(int(club_groups.get("fielder", 0))).is_equal(1)
	# 同じ退団を二度抽選しない。
	assert_array(FarmClubService._sign_departed_foreign_players(GameDb.players, 2026, 1.0)).is_empty()
	_reload_world()


func test_unselected_departed_foreign_player_remains_retired() -> void:
	_reload_world()
	var candidate: PSPlayer = null
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.foreign_player and not player.is_retired() and player.team_id > 0 \
				and not PSFarmLeague.is_farm_club_id(player.team_id):
			candidate = player
			break
	assert_object(candidate).is_not_null()
	ForeignPlayerService._apply_contract_departure(candidate, candidate.team_id, 2026)
	assert_array(FarmClubService._sign_departed_foreign_players(GameDb.players, 2026, 0.0)).is_empty()
	assert_int(candidate.team_id).is_equal(0)
	assert_bool(candidate.is_retired()).is_true()
	assert_bool(candidate.source_data.has(PSFarmLeague.SOURCE_KEY_FOREIGN_CONTRACT_DEPARTED_YEAR)).is_false()
	_reload_world()


func test_offseason_supply_releases_aged_players_and_refills() -> void:
	_reload_world()
	var club_id: int = int(PSFarmLeague.farm_club_ids()[0])
	for player_row in FarmClubService.roster_players(GameDb.players, club_id):
		(player_row as PSPlayer).age = FarmClubService.ATTRITION_CERTAIN_AGE

	var result: Dictionary = FarmClubService.process_offseason(GameDb.players, 2026)
	# 全員が確実整理の年齢なので、その球団のロスターは一度空になってから生成で埋め直される。
	assert_int(int(result.get("attrition_count", 0))).is_greater_equal(FarmClubService.ROSTER_TARGET)
	assert_int(FarmClubService.roster_count(GameDb.players, club_id)).is_equal(FarmClubService.ROSTER_TARGET)
	_reload_world()


func test_farm_club_departures_happen_without_any_age_factor() -> void:
	# 退団は年齢だけでは決まらない。専用球団は NPB の契約の枠組みの外なので、
	# 若い選手も毎オフ一定確率で抜ける (引退・独立/社会人への移籍・自己都合)。
	_reload_world()
	var club_id: int = int(PSFarmLeague.farm_club_ids()[0])
	# 高齢引退が一切効かない年齢に揃える = 残るのはランダム離脱だけ。
	for player_row in FarmClubService.roster_players(GameDb.players, club_id):
		(player_row as PSPlayer).age = 22

	Rng.set_seed_value(20260816)
	var result: Dictionary = FarmClubService.process_offseason(GameDb.players, 2026)
	var departures: Array = []
	for entry_row in result.get("attrition", []) as Array:
		var entry: Dictionary = entry_row as Dictionary
		if int(entry.get("club_id", 0)) == club_id:
			departures.append(entry)

	assert_int(departures.size()).override_failure_message(
		"年齢要因がゼロの球団から誰も退団していない (ランダム離脱が効いていない)"
	).is_greater(0)
	assert_int(departures.size()).is_less(FarmClubService.ROSTER_TARGET)
	for entry_row in departures:
		assert_str(str((entry_row as Dictionary).get("reason", ""))).is_equal("random")
	# 抜けた分は補充され、ロスターは目標人数に戻る。
	assert_int(FarmClubService.roster_count(GameDb.players, club_id)).is_equal(
		FarmClubService.ROSTER_TARGET
	)
	_reload_world()


func test_undrafted_prospects_are_not_forced_out_by_age() -> void:
	# **在籍は指名の有無と無関係**。NPB 未経験者にだけ年齢の強制退団 (27歳から整理・32歳で消滅)
	# を掛けない = 指名されなくても専用球団でプレーを続けられる。
	_reload_world()
	var club_id: int = int(PSFarmLeague.farm_club_ids()[0])
	var prospects: Array = []
	for player_row in FarmClubService.roster_players(GameDb.players, club_id):
		var player: PSPlayer = player_row as PSPlayer
		if not FarmClubService.has_npb_experience(player):
			# 年齢で一掃する実装なら確実に消える年齢。高齢引退 (33〜) にはまだ届かない。
			player.age = 30
			prospects.append(player)
	assert_int(prospects.size()).is_greater(0)

	Rng.set_seed_value(20260816)
	FarmClubService.process_offseason(GameDb.players, 2026)
	var survivors: int = 0
	for player_row in prospects:
		if (player_row as PSPlayer).team_id == club_id:
			survivors += 1
	# ランダム離脱で何人かは抜けるが、大半は残る (年齢で一掃する実装なら 0 人になる)。
	assert_int(survivors).override_failure_message(
		"指名されなかった未経験者が年齢だけで一掃されている"
	).is_greater(int(float(prospects.size()) * 0.5))
	_reload_world()


func test_farm_club_players_are_excluded_from_npb_retirement() -> void:
	# NPB の引退判定は一軍成績を見るので、専用球団の選手は全員「低出場」に見えてしまう。
	# 除外していないとここで大量引退する。
	_reload_world()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.clear_records()
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if PSFarmLeague.is_farm_club_id(player.team_id):
			player.age = OffseasonService.FORCED_RETIREMENT_CERTAIN_AGE

	OffseasonService.process_retirement(GameDb.players, season)
	for club_id in PSFarmLeague.farm_club_ids():
		assert_int(FarmClubService.roster_count(GameDb.players, int(club_id))).is_equal(
			FarmClubService.ROSTER_TARGET
		)
	_reload_world()


func test_farm_club_players_get_season_records_without_polluting_league_reference() -> void:
	# 専用球団の選手にも当季レコードは作られる (二軍戦で成績を付けるため) が、
	# リーグ基準の母集団は GameDb.teams を舐めるので専用球団は構造的に混ざらない。
	_reload_world()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.clear_records()
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	for club_id in PSFarmLeague.farm_club_ids():
		var records: Array = RecordStore.get_team_player_records(int(club_id), season.year, season.season_number)
		assert_int(records.size()).is_equal(FarmClubService.ROSTER_TARGET)

	var reference_ids: Dictionary = {}
	for team_row in GameDb.teams:
		for record_row in RecordStore.get_team_player_records((team_row as PSTeam).id, season.year, season.season_number, true):
			reference_ids[(record_row as PSPlayerSeasonRecord).player_id] = true
	for club_id in PSFarmLeague.farm_club_ids():
		for player_row in FarmClubService.roster_players(GameDb.players, int(club_id)):
			assert_bool(reference_ids.has((player_row as PSPlayer).id)).override_failure_message(
				"farm club player leaked into the first-team reference population"
			).is_false()


func test_farm_club_players_recover_fatigue_and_injuries_each_day() -> void:
	# 日次回復が GameDb.teams (一軍12球団) だけを舐めると、専用球団の選手は疲労も故障も
	# 抜けないまま積み上がり、野手が9人を割って二軍戦が中止になる。
	_reload_world()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.clear_records()
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var targets: Array = []
	for club_id in PSFarmLeague.farm_club_ids():
		var club_records: Array = RecordStore.get_team_player_records(
			int(club_id), season.year, season.season_number
		)
		assert_array(club_records).is_not_empty()
		targets.append(club_records[0] as PSPlayerSeasonRecord)
	var first_team_records: Array = RecordStore.get_team_player_records(
		(GameDb.teams[0] as PSTeam).id, season.year, season.season_number
	)
	targets.append(first_team_records[0] as PSPlayerSeasonRecord)

	for record_row in targets:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		record.fatigue = 100
		record.injury_days = 10

	PSGameDecisions.recover_after_day(season, 1)

	for record_row in targets:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		assert_int(record.injury_days).override_failure_message(
			"team %d player did not serve an injury day" % record.team_id
		).is_equal(9)
		assert_int(record.fatigue).override_failure_message(
			"team %d player did not recover fatigue" % record.team_id
		).is_less(100)


# ---- 専用球団からのドラフト指名 (6c) ---------------------------------------

func _farm_draft_candidates(pool: Array) -> Array:
	var rows: Array = []
	for candidate_row in pool:
		var candidate: Dictionary = candidate_row as Dictionary
		if str(candidate.get("source_type", "")) == DraftService.FARM_CLUB_SOURCE_TYPE:
			rows.append(candidate)
	return rows


func test_farm_club_prospects_appear_on_the_draft_board() -> void:
	# 専用球団の選手は**生成候補ではなく実在の選手**としてボードに載る = 実際の二軍成績で判断できる
	# 唯一のドラフト候補。上限を超えて載ると生成候補を押しのけて指名の性格が変わる。
	_reload_world()
	Rng.set_seed_value(20260815)
	var state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, null, 0, false)
	var farm_candidates: Array = _farm_draft_candidates(state.get("candidate_pool", []) as Array)

	assert_int(farm_candidates.size()).is_greater(0)
	assert_int(farm_candidates.size()).is_less_equal(DraftService.FARM_CLUB_CANDIDATE_POOL_SIZE)

	var seen_player_ids: Dictionary = {}
	for candidate_row in farm_candidates:
		var candidate: Dictionary = candidate_row as Dictionary
		var player: PSPlayer = GameDb.get_player(int(candidate.get("farm_club_player_id", 0)))
		assert_object(player).is_not_null()
		assert_bool(PSFarmLeague.is_draft_eligible_farm_club_player(player)).is_true()
		assert_int(player.age).is_less_equal(DraftService.FARM_CLUB_CANDIDATE_MAX_AGE)
		# 同じ選手が2枚ボードに並ばない。候補 ID も生成候補と衝突しない。
		assert_bool(seen_player_ids.has(player.id)).is_false()
		seen_player_ids[player.id] = true
		assert_int(int(candidate.get("candidate_id", 0))).is_greater(DraftService.CANDIDATE_POOL_SIZE)


func test_draft_board_only_takes_farm_club_players_without_npb_experience() -> void:
	# 実ルール: 戦力外から拾った (= 指名歴のある) 選手はドラフトを経ずに移籍できる側なので
	# 指名対象にならない。外国人も同じ理由で対象外。
	_reload_world()
	var club_id: int = int(PSFarmLeague.farm_club_ids()[0])
	# 元NPB組は元から対象外なので、**指名対象である生成組**を3人選んで各条件を付ける
	# (そうしないと「除外されたのは条件のおかげ」と言えない)。
	var roster: Array = []
	for player_row in FarmClubService.roster_players(GameDb.players, club_id):
		if not FarmClubService.has_npb_experience(player_row as PSPlayer):
			roster.append(player_row)
	assert_int(roster.size()).is_greater_equal(3)
	var experienced: PSPlayer = roster[0] as PSPlayer
	var foreign: PSPlayer = roster[1] as PSPlayer
	var aged: PSPlayer = roster[2] as PSPlayer
	experienced.source_data[PSFarmLeague.SOURCE_KEY_NPB_EXPERIENCED] = true
	foreign.foreign_player = true
	aged.age = DraftService.FARM_CLUB_CANDIDATE_MAX_AGE + 1

	Rng.set_seed_value(20260815)
	var state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, null, 0, false)
	var excluded: Dictionary = {experienced.id: true, foreign.id: true, aged.id: true}
	for candidate_row in _farm_draft_candidates(state.get("candidate_pool", []) as Array):
		var pid: int = int((candidate_row as Dictionary).get("farm_club_player_id", 0))
		assert_bool(excluded.has(pid)).override_failure_message(
			"ineligible farm club player %d reached the draft board" % pid
		).is_false()
	_reload_world()


func test_drafting_a_farm_club_player_moves_him_instead_of_creating_a_new_one() -> void:
	# 6c の中核。指名は **team_id の移動**であって新規生成ではない — 能力・二軍成績・
	# 選手 ID がそのまま NPB 球団へ引き継がれる。
	_reload_world()
	Rng.set_seed_value(20260815)
	var pool: Array = DraftService._generate_candidate_pool(4, GameDb.players)
	var farm_candidates: Array = _farm_draft_candidates(pool)
	assert_int(farm_candidates.size()).is_greater(0)

	var candidate: Dictionary = farm_candidates[0] as Dictionary
	var player_id: int = int(candidate.get("farm_club_player_id", 0))
	var club_id: int = int(candidate.get("farm_club_id", 0))
	var player: PSPlayer = GameDb.get_player(player_id)
	var z_before: Dictionary = player.z_abilities.duplicate(true)
	var roster_before: int = FarmClubService.roster_count(GameDb.players, club_id)
	var players_before: int = GameDb.players.size()

	var state: Dictionary = {
		"year": 2026,
		"candidate_pool": pool,
		"logs": [],
		"picks": [{
			"team_id": 1,
			"candidate_id": int(candidate.get("candidate_id", 0)),
			"round": 3,
			"overall_pick": 27,
			"method": "waiver",
			"lottery": false,
			"development": true,
		}],
	}
	var result: Dictionary = DraftService.finalize_draft(state, GameDb.players)
	var rookies: Array = result.get("rookies", []) as Array
	assert_int(rookies.size()).is_equal(1)
	assert_int(int((rookies[0] as Dictionary).get("player_id", 0))).is_equal(player_id)

	# 新規選手は増えず、専用球団のロスターがその1人ぶん減る。
	assert_int(GameDb.players.size()).is_equal(players_before)
	assert_int(FarmClubService.roster_count(GameDb.players, club_id)).is_equal(roster_before - 1)

	# 実体はそのまま移った。能力は不変、NPB の枠組みへ乗り換える。
	assert_int(player.team_id).is_equal(1)
	assert_dict(player.z_abilities).is_equal(z_before)
	assert_bool(player.development_player).is_true()
	assert_str(player.registered_roster).is_equal("育成")
	assert_int(player.years).is_equal(0)
	# 以後は NPB 経験者 = 二重に指名対象へ戻らない。
	assert_bool(FarmClubService.has_npb_experience(player)).is_true()
	assert_bool(PSFarmLeague.is_draft_eligible_farm_club_player(player)).is_false()
	# 経歴ログにドラフト入団が残る。
	assert_int(PSCareerLog.entries(player).size()).is_greater(0)
	_reload_world()


func test_farm_clubs_never_take_part_in_the_draft_as_selectors() -> void:
	# 実ルールで専用球団はドラフト会議に指名する側として参加できない。指名順は GameDb.teams
	# (12球団) から作るので構造的に混ざらないが、その不変条件を明示的に張る。
	_reload_world()
	Rng.set_seed_value(20260815)
	var state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, null, 0)
	for order_key in ["teams_order_reverse", "teams_order_forward"]:
		for team_id in state.get(order_key, []) as Array:
			assert_bool(PSFarmLeague.is_farm_club_id(int(team_id))).is_false()

	DraftService.complete_automatically(state)
	var result: Dictionary = DraftService.finalize_draft(state, GameDb.players)
	var farm_rookies: int = 0
	for rookie_row in result.get("rookies", []) as Array:
		var rookie: Dictionary = rookie_row as Dictionary
		assert_bool(PSFarmLeague.is_farm_club_id(int(rookie.get("team_id", 0)))).is_false()
		if str(rookie.get("source_type", "")) == DraftService.FARM_CLUB_SOURCE_TYPE:
			farm_rookies += 1
			# 指名された専用球団の選手は既存 ID のまま NPB 球団へ移っている。
			var player: PSPlayer = GameDb.get_player(int(rookie.get("player_id", 0)))
			assert_bool(PSFarmLeague.is_farm_club_id(player.team_id)).is_false()
			assert_bool(FarmClubService.has_npb_experience(player)).is_true()
	print("FARMDRAFT picked=%d of %d on board" % [
		farm_rookies, DraftService.FARM_CLUB_CANDIDATE_POOL_SIZE
	])
	_reload_world()


func test_farm_club_prospects_never_top_the_draft_board() -> void:
	# 生成組は**育成指名レベルが上限**で、ボードの目玉にはならない。生成水準がインフレすると
	# 専用球団の10人が生成候補の **99〜100 パーセンタイル**に並び、割引 const は順位しか下げないので
	# 「表示総合が全体最高の選手がボード40位に沈む」という表示と並び順の矛盾が起きる。
	_reload_world()
	Rng.set_seed_value(20260815)
	var state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, null, 1, false)
	var generated: Array = []
	var farm_best: int = 0
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		var overall: int = int(candidate.get("overall", 0))
		if str(candidate.get("source_type", "")) == DraftService.FARM_CLUB_SOURCE_TYPE:
			farm_best = max(farm_best, overall)
		else:
			generated.append(overall)
	assert_int(farm_best).is_greater(0)
	generated.sort()

	# ドラフトの目玉は必ず生成候補側から出る。
	assert_int(farm_best).override_failure_message(
		"専用球団の最上位 (%d) がボード全体の最上位 (%d) を超えている" % [
			farm_best, int(generated[generated.size() - 1])
		]
	).is_less(int(generated[generated.size() - 1]))

	# **ボードの上位10人には入らない。** 専用球団の生成組は入団までの育成ぶんだけ伸びるので
	# (`PROSPECT_DEVELOPMENT_RATE`)、上位帯へある程度は近づくのが正しい。禁じたいのは
	# 「ボードの目玉が専用球団から出る」ことなので、上限ではなくこの順位で張る。
	# 実測: 育成なし → 26〜29人が上 / 現行 (率0.5) → 12人 / 満額(1.0) → **0人 = 目玉になる**。
	var better: int = 0
	for value in generated:
		if int(value) >= farm_best:
			better += 1
	assert_int(better).override_failure_message(
		"専用球団の最上位より上の生成候補が %d 人しか居ない (ボードの目玉になっている)" % better
	).is_greater_equal(10)
	_reload_world()


func test_farm_club_prospects_are_drafted_at_a_realistic_rate() -> void:
	# `FARM_CLUB_DRAFT_GRADE_SCALE` の較正ガード。実 NPB の指名は年1〜3人で、大半が育成指名。
	# 割引が効かなくなると専用球団の候補がボード上位を占め、10人中10人が指名される
	# (割引 1.00 での実測)。**この帯は「野球として成立するか」ではなく較正の再現性を張っている。**
	_reload_world()
	Rng.set_seed_value(20260815)
	var state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, null, 0)
	DraftService.complete_automatically(state)
	var result: Dictionary = DraftService.finalize_draft(state, GameDb.players)

	var picked: int = 0
	var development_picked: int = 0
	for rookie_row in result.get("rookies", []) as Array:
		var rookie: Dictionary = rookie_row as Dictionary
		if str(rookie.get("source_type", "")) != DraftService.FARM_CLUB_SOURCE_TYPE:
			continue
		picked += 1
		if bool(rookie.get("development_player", false)):
			development_picked += 1
	assert_int(picked).override_failure_message(
		"farm club picks = %d (expected 1..3; check FARM_CLUB_DRAFT_GRADE_SCALE)" % picked
	).is_between(1, 3)
	assert_int(development_picked).is_greater(0)
	_reload_world()


# ---- 二軍戦の実行 ----------------------------------------------------------

# 二軍戦を実際に動かすためのシーズンを用意する (レコードは persist しない)。
func _fresh_season_with_records() -> PSSeason:
	GameDb.load_initial_data()
	Rng.set_seed_value(20260811)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
	return season


func _first_farm_day(season: PSSeason) -> int:
	return int((season.farm_schedule[0] as Dictionary).get("day", 0))


func test_farm_day_plays_every_scheduled_game() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var day: int = _first_farm_day(season)
	var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()

	var outcome: Dictionary = PSFarmGameRunner.simulate_day(season, day, rule_groups, true)
	assert_bool(bool(outcome.get("ok", false))).is_true()
	# 1ラウンド = 7試合。人数不足での中止は起きない想定 (専用球団も48人揃っている)。
	assert_int(int(outcome.get("played_count", 0))).is_equal(7)
	assert_int(int(outcome.get("cancelled_count", 0))).is_equal(0)
	assert_array(season.farm_game_indices_on_day(day)).is_empty()


func test_farm_games_write_farm_stats_and_leave_first_team_stats_untouched() -> void:
	# 二軍実装の最重要の不変条件。一軍成績へ1つでも漏れると
	# タイトル・WAR・年俸・引退判定が全部汚染される。
	var season: PSSeason = _fresh_season_with_records()
	var before_first_team: Dictionary = {}
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		before_first_team[record.player_id] = [
			record.batter_stats.plate_appearances, record.pitcher_stats.batters_faced
		]

	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)

	var farm_pa_total: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var before: Array = before_first_team[record.player_id] as Array
		assert_int(record.batter_stats.plate_appearances).override_failure_message(
			"player %d の一軍打席数が二軍戦で動いた" % record.player_id
		).is_equal(int(before[0]))
		assert_int(record.pitcher_stats.batters_faced).override_failure_message(
			"player %d の一軍対戦打者数が二軍戦で動いた" % record.player_id
		).is_equal(int(before[1]))
		farm_pa_total += record.farm_batter_stats.plate_appearances
	# 7試合ぶんの打席が二軍側へ積まれている。
	assert_int(farm_pa_total).is_greater(300)


func test_farm_games_record_standings_and_decisions() -> void:
	var season: PSSeason = _fresh_season_with_records()
	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)

	var total_games: int = 0
	for team_id in season.farm_standings.keys():
		total_games += (season.farm_standings[team_id] as PSStats).games
	# 7試合 × 2球団。
	assert_int(total_games).is_equal(14)
	# 一軍の順位表は動かない。
	for team_id in season.standings.keys():
		assert_int((season.standings[team_id] as PSStats).games).is_equal(0)

	# 勝敗投手が二軍成績側へ付いている。
	var farm_decisions: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		farm_decisions += record.farm_pitcher_stats.wins + record.farm_pitcher_stats.losses
		assert_int(record.pitcher_stats.wins).is_equal(0)
		assert_int(record.pitcher_stats.losses).is_equal(0)
	assert_int(farm_decisions).is_greater(0)


func test_development_players_appear_in_farm_games() -> void:
	# 育成選手は一軍に登録できないので、出場機会は二軍戦だけ。
	# ここが 0 試合になると育成制度そのものが機能しない。
	var season: PSSeason = _fresh_season_with_records()
	var development_ids: Dictionary = {}
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.development_player:
			development_ids[record.player_id] = true
	assert_int(development_ids.size()).is_greater(0)

	# 育成選手が出場するまで数日消化する (1日で全球団の育成が出るとは限らない)。
	var played_days: int = 0
	var appeared: int = 0
	for game_row in season.farm_schedule:
		var day: int = int((game_row as Dictionary).get("day", 0))
		if played_days >= 6:
			break
		if season.farm_game_indices_on_day(day).is_empty():
			continue
		PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
		played_days += 1
		appeared = 0
		for player_id in development_ids.keys():
			var record: PSPlayerSeasonRecord = RecordStore.get_player_record(int(player_id), season.year, season.season_number)
			if record != null and (record.farm_batter_stats.plate_appearances > 0 or record.farm_pitcher_stats.batters_faced > 0):
				appeared += 1
		if appeared > 0:
			break
	assert_int(appeared).override_failure_message(
		"育成選手が二軍戦に一人も出場していない"
	).is_greater(0)


func test_farm_playing_time_prioritizes_prospects_and_is_not_decided_by_ability_alone() -> void:
	# **二軍は一軍とは別の基準で出場を決める**。
	#   1. トッププロスペクトは優先して出す
	#   2. それ以外は能力だけで機会を決めない (出ていない選手ほど優先度が上がる輪番)
	# 一軍の「強い順に9人」との違いがここに集約されるので、方針が消えたら落ちるようにしておく。
	var team_games: int = 40
	var mean_share: float = 0.5

	# --- 1. トッププロスペクトは、能力で上回るベテランより優先される ---
	var prospect: PSPlayerSeasonRecord = _usage_probe_record(9101, 22, false)
	var veteran: PSPlayerSeasonRecord = _usage_probe_record(9102, 33, false)
	# 出場実績は同じ (輪番の効果を排除して、プロスペクト加点だけを見る)。
	var prospect_score: float = PSTeamSetupBuilder.farm_usage_priority(prospect, true, 20.0, team_games, mean_share)
	var veteran_score: float = PSTeamSetupBuilder.farm_usage_priority(veteran, false, 20.0, team_games, mean_share)
	assert_float(prospect_score).override_failure_message(
		"プロスペクトの優先度がベテランを上回っていない"
	).is_greater(veteran_score)

	# --- 2. 同じ選手像なら、出場が少ない方が優先される (能力に依らない輪番) ---
	var rested: float = PSTeamSetupBuilder.farm_usage_priority(veteran, false, 4.0, team_games, mean_share)
	var overused: float = PSTeamSetupBuilder.farm_usage_priority(veteran, false, 36.0, team_games, mean_share)
	assert_float(rested).override_failure_message(
		"出場の少ない選手が優先されていない (輪番が効いていない)"
	).is_greater(overused)

	# --- 3. 能力差が輪番で覆ること = 「能力で機会をすべて決めない」 ---
	# 表示能力で 12 点ぶん劣る控えが、ほとんど出ていなければ出ずっぱりの選手を上回る。
	var ability_gap: float = 12.0 * PSTeamSetupBuilder.FARM_ABILITY_WEIGHT
	assert_float(rested - overused).override_failure_message(
		"輪番の効きが弱く、結局は能力順のままになっている"
	).is_greater(ability_gap)

	# --- 4. 開幕直後 (消化0試合) は実績が無いので輪番を効かせない ---
	var opening_a: float = PSTeamSetupBuilder.farm_usage_priority(veteran, false, 0.0, 0, -1.0)
	var opening_b: float = PSTeamSetupBuilder.farm_usage_priority(veteran, false, 8.0, 0, -1.0)
	assert_float(opening_a).is_equal_approx(opening_b, 0.001)


func test_farm_club_usage_follows_the_same_rules_as_affiliated_farm_teams() -> void:
	# 二軍リーグの出場方針は全14球団で共通。専用球団だけ能力順で組ませると、元NPBの主力を
	# 毎日並べられるぶん相手より起用が最適化され、勝率がゲート (.270〜.420) を超えて跳ねる。
	var team_games: int = 40
	var mean_share: float = 0.5
	var farm_club_veteran: PSPlayerSeasonRecord = _usage_probe_record(9201, 33, false)
	farm_club_veteran.team_id = int(PSFarmLeague.farm_club_ids()[0])
	var npb_veteran: PSPlayerSeasonRecord = _usage_probe_record(9202, 33, false)
	npb_veteran.team_id = 1

	# 1. ベテラン減点・若手加点は専用球団にも同じだけ効く。
	var farm_club_priority: float = PSTeamSetupBuilder.farm_development_priority(farm_club_veteran)
	assert_float(farm_club_priority).override_failure_message(
		"専用球団のベテランが育成方針の減点を免れている"
	).is_less(0.0)
	assert_float(farm_club_priority).is_equal_approx(
		PSTeamSetupBuilder.farm_development_priority(npb_veteran), 0.001
	)

	# 2. プロスペクト加点も効く。
	var as_prospect: float = PSTeamSetupBuilder.farm_usage_priority(
		farm_club_veteran, true, 20.0, team_games, mean_share
	)
	var as_regular: float = PSTeamSetupBuilder.farm_usage_priority(
		farm_club_veteran, false, 20.0, team_games, mean_share
	)
	assert_float(as_prospect).is_greater(as_regular)

	# 3. 出場機会の輪番も効く (出ていない選手が先に出る)。
	var rested: float = PSTeamSetupBuilder.farm_usage_priority(farm_club_veteran, false, 4.0, team_games, mean_share)
	var overused: float = PSTeamSetupBuilder.farm_usage_priority(farm_club_veteran, false, 36.0, team_games, mean_share)
	assert_float(rested).override_failure_message(
		"専用球団に出場機会の輪番が効いていない"
	).is_greater(overused)


# 出場方針の検証用の最小レコード (能力は farm_usage_priority が見ないので設定しない)。
func _usage_probe_record(player_id: int, age: int, development: bool) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.name = "usage_probe_%d" % player_id
	record.position = 3
	record.age = age
	record.development_player = development
	return record


func test_farm_pool_excludes_the_active_roster_even_before_the_first_team_plays() -> void:
	# 二軍は一軍より先に回すため、`season.get_active_roster` がまだ空の状態で
	# 二軍のロスターを決めることになる。裏返しが効いていないと**一軍の主力が二軍戦に出る**
	# (実際にこのバグを踏んだ)。preview からの導出で常に除外されること。
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	assert_array(season.get_active_roster(team_id).get("player_ids", []) as Array).is_empty()

	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	var farm_pool: Array = PSTeamSetupBuilder.farm_eligible_records(season, team_id, all_records)
	assert_int(farm_pool.size()).is_less(all_records.size())

	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_ids: Dictionary = {}
	for id_value in (preview.get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	assert_int(active_ids.size()).is_greater(0)
	for record_row in farm_pool:
		assert_bool(active_ids.has((record_row as PSPlayerSeasonRecord).player_id)).override_failure_message(
			"一軍登録の選手が二軍のロスターに残っている"
		).is_false()
	# 導出に使っただけで保存はしない (保存すると一軍側の編成を変えてしまう)。
	assert_array(season.get_active_roster(team_id).get("player_ids", []) as Array).is_empty()


func test_farm_games_do_not_touch_first_team_lineup_settings() -> void:
	# 守備起用設定・自動打順はチーム単位の共有保存状態。二軍が踏むと一軍の編成が壊れる。
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var usage_before: Dictionary = season.get_fielder_usage(team_id).duplicate(true)
	var order_before: Array = (season.get_auto_batting_order(team_id, true) as Array).duplicate()

	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)

	assert_int(season.get_fielder_usage(team_id).size()).override_failure_message(
		"二軍戦が一軍の守備起用設定を書き換えた"
	).is_equal(usage_before.size())
	assert_array(season.get_auto_batting_order(team_id, true) as Array).override_failure_message(
		"二軍戦が一軍の自動打順を書き換えた"
	).is_equal(order_before)


func test_farm_club_players_actually_play() -> void:
	var season: PSSeason = _fresh_season_with_records()
	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)
	for club_id in PSFarmLeague.farm_club_ids():
		var appearances: int = 0
		for record_row in RecordStore.get_team_player_records(int(club_id), season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			appearances += record.farm_batter_stats.plate_appearances + record.farm_pitcher_stats.batters_faced
		assert_int(appearances).override_failure_message(
			"farm club %d が二軍戦に出場していない" % int(club_id)
		).is_greater(0)


func test_farm_games_use_the_shorter_extra_inning_limit() -> void:
	# ファーム公式戦は延長が制限され引き分けが多い (実測でウエスタンは10%超)。
	# 一軍の12回のままだと引き分けがほぼ出ない。
	var season: PSSeason = _fresh_season_with_records()
	var max_innings_seen: int = 0
	var played_days: int = 0
	for game_row in season.farm_schedule:
		if played_days >= 12:
			break
		var day: int = int((game_row as Dictionary).get("day", 0))
		if season.farm_game_indices_on_day(day).is_empty():
			continue
		PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
		played_days += 1
	for game_row in season.farm_schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)) or bool(game.get("cancelled", false)):
			continue
		var innings: int = int((game.get("result", {}) as Dictionary).get("innings_played", 0))
		max_innings_seen = max(max_innings_seen, innings)
	assert_int(max_innings_seen).is_less_equal(PSFarmSchedule.MAX_INNINGS)


func test_farm_rotation_shares_the_rest_ledger_with_the_first_team() -> void:
	# 二軍で投げた投手の登板日が共有台帳へ入ること = 翌日昇格しても中0日で先発しない。
	# 二軍の自動序列は登板機会を再配分するため毎試合作り直し、一軍の序列を壊さない。
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var before: Dictionary = season.get_rotation(team_id).duplicate(true)
	var first_team_order: Array = (before.get("pitcher_ids", []) as Array).duplicate()

	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)

	var after: Dictionary = season.get_rotation(team_id)
	assert_array(after.get("pitcher_ids", []) as Array).override_failure_message(
		"二軍戦が一軍のローテ序列を書き換えた"
	).is_equal(first_team_order)
	var farm_view: Dictionary = PSRotationPlanner.rotation_state_for_level(
		season, team_id, PSTeamSetupBuilder.LEVEL_FARM
	)
	assert_array(farm_view.get("pitcher_ids", []) as Array).is_empty()
	# 台帳は共有 = 二軍の先発が登録されている。
	var last_starts: Dictionary = after.get("last_start_day_by_pitcher", {}) as Dictionary
	assert_int(last_starts.size()).is_greater((before.get("last_start_day_by_pitcher", {}) as Dictionary).size())


func test_farm_relief_streak_uses_its_own_team_game_ledger() -> void:
	var reliever: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	reliever.player_id = 990001
	reliever.position = 1
	reliever.role = "reliever"
	reliever.last_pitched_team_game = 40
	reliever.consecutive_appearances = 2
	var setup: Dictionary = {
		"level": PSTeamSetupBuilder.LEVEL_FARM,
		"pitcher_usage": {},
		"used_pitcher_ids": {},
	}

	PSBullpenManager.mark_reliever_appeared(
		setup, reliever, 12, PSPitcherUsageModel.ROLE_SHORT_RELIEF
	)

	assert_int(reliever.farm_last_pitched_team_game).is_equal(13)
	assert_int(reliever.farm_consecutive_appearances).is_equal(1)
	assert_int(reliever.last_pitched_team_game).is_equal(40)
	assert_int(reliever.consecutive_appearances).is_equal(2)
	assert_int(PSPitcherUsageModel.next_consecutive_appearance_count(reliever, 13, true)).is_equal(2)
	assert_int(PSPitcherUsageModel.next_consecutive_appearance_count(reliever, 40, false)).is_equal(3)


func test_farm_defensive_innings_accumulate_for_aptitude_growth() -> void:
	var season: PSSeason = _fresh_season_with_records()
	PSFarmGameRunner.simulate_day(season, _first_farm_day(season), ModManager.hot_rule_groups_snapshot(), true)
	var total_farm_innings: float = 0.0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		for position in [2, 3, 4, 5, 6, 7, 8, 9]:
			total_farm_innings += record.farm_defensive_innings_at(position)
			# 一軍の守備イニングは動かない。
			assert_float(record.defensive_innings_at(position)).is_equal_approx(0.0, 0.001)
	assert_float(total_farm_innings).override_failure_message(
		"二軍の守備イニングが記録されていない (守備適性成長の入力が空になる)"
	).is_greater(0.0)


func test_farm_game_loop_uses_lightweight_output() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var day: int = _first_farm_day(season)
	var indices: Array = season.farm_game_indices_on_day(day)
	assert_bool(indices.is_empty()).is_false()
	var calc: Dictionary = PSFarmGameRunner.calculate(
		season, int(indices[0]), -1, ModManager.hot_rule_groups_snapshot()
	)
	assert_bool(bool(calc.get("ok", false))).is_true()
	var result: Dictionary = calc.get("result", {}) as Dictionary
	assert_bool(result.has("play_events")).override_failure_message(
		"二軍戦が詳細プレーを生成している"
	).is_false()
	assert_bool(result.has("advanced_stats")).override_failure_message(
		"軽量出力で入替判断に必要な高度指標が失われている"
	).is_true()
	var advanced: Dictionary = result.get("advanced_stats", {}) as Dictionary
	assert_int((advanced.get("players", {}) as Dictionary).size()).override_failure_message(
		"軽量出力で打撃・走塁・守備指標が集計されていない"
	).is_greater(0)
	assert_int((advanced.get("pitchers", {}) as Dictionary).size()).override_failure_message(
		"軽量出力で投手の被打席指標が集計されていない"
	).is_greater(0)
	assert_int(int(result.get("next_play_event_index", 0))).is_greater(0)

	PSFarmGameRunner.apply(season, calc)
	var total_outs: int = 0
	var total_advanced_pa: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		for outs_value in record.farm_advanced_stats.defensive_outs_by_position.values():
			total_outs += int(outs_value)
		total_advanced_pa += record.farm_advanced_stats.plate_appearances
		assert_int(record.advanced_stats.plate_appearances).override_failure_message(
			"二軍の高度指標が一軍コンテナへ混入した"
		).is_equal(0)
	assert_int(total_outs).is_greater(0)
	assert_int(total_advanced_pa).is_greater(0)


func test_farm_league_produces_a_plausible_stat_line() -> void:
	# 二軍成績は「一軍と同じ PA シムを素通しで使えば、投打の質差から自然に一軍より低く出る」
	# という前提で作っている。別式を持たない代わりに、その前提が崩れていないかを見る。
	var season: PSSeason = _fresh_season_with_records()
	var played_days: int = 0
	for game_row in season.farm_schedule:
		if played_days >= 10:
			break
		var day: int = int((game_row as Dictionary).get("day", 0))
		if season.farm_game_indices_on_day(day).is_empty():
			continue
		PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
		played_days += 1

	var at_bats: int = 0
	var hits: int = 0
	var walks: int = 0
	var plate_appearances: int = 0
	var strikeouts: int = 0
	for record_row in RecordStore.player_records.values():
		var stats: PSBatterStats = (record_row as PSPlayerSeasonRecord).farm_batter_stats
		at_bats += stats.at_bats
		hits += stats.hits
		walks += stats.walks
		plate_appearances += stats.plate_appearances
		strikeouts += stats.strikeouts
	assert_int(at_bats).is_greater(1500)
	var average: float = float(hits) / float(at_bats)
	var walk_rate: float = float(walks) / float(plate_appearances)
	var strikeout_rate: float = float(strikeouts) / float(plate_appearances)
	# 較正フェーズの入力用に実測値を出す (simulation_test の EVALSCALE と同じ運用)。
	print("FARMLINE AVG=%.3f BB%%=%.3f K%%=%.3f PA=%d" % [average, walk_rate, strikeout_rate, plate_appearances])
	# ここは**較正のゲートではなく「野球として成立しているか」の回帰ガード**なので帯は広く取る。
	# 数値較正は [[feedback_working_conventions]] のとおり後でまとめて行う。
	assert_float(average).override_failure_message("farm AVG=%f" % average).is_between(0.180, 0.310)
	assert_float(walk_rate).override_failure_message("farm BB%%=%f" % walk_rate).is_between(0.02, 0.20)
	assert_float(strikeout_rate).override_failure_message("farm K%%=%f" % strikeout_rate).is_between(0.10, 0.35)


func test_farm_games_produce_draws_from_the_shorter_extra_inning_limit() -> void:
	# 延長10回打ち切りの効果。一軍の12回のままだと引き分けはほとんど出ない。
	var season: PSSeason = _fresh_season_with_records()
	var played_days: int = 0
	for game_row in season.farm_schedule:
		if played_days >= 20:
			break
		var day: int = int((game_row as Dictionary).get("day", 0))
		if season.farm_game_indices_on_day(day).is_empty():
			continue
		PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
		played_days += 1

	var draws: int = 0
	for team_id in season.farm_standings.keys():
		draws += (season.farm_standings[team_id] as PSStats).draws
	assert_int(draws).override_failure_message(
		"140試合で引き分けが1つも出ていない (延長制限が効いていない可能性)"
	).is_greater(0)


func test_farm_can_be_disabled_for_calibration_runs() -> void:
	# 較正ツール用のスイッチ。切ると二軍戦が一切消化されない。
	var season: PSSeason = _fresh_season_with_records()
	var day: int = _first_farm_day(season)
	PSFarmGameRunner.enabled = false
	var outcome: Dictionary = PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
	PSFarmGameRunner.enabled = true

	assert_int(int(outcome.get("played_count", 0))).is_equal(0)
	assert_int(season.farm_game_indices_on_day(day).size()).is_equal(7)


# ---- 起用への接続 (二軍成績の評価) ------------------------------------------

func _play_farm_days(season: PSSeason, count: int) -> int:
	var played: int = 0
	for game_row in season.farm_schedule:
		if played >= count:
			break
		var day: int = int((game_row as Dictionary).get("day", 0))
		if season.farm_game_indices_on_day(day).is_empty():
			continue
		PSFarmGameRunner.simulate_day(season, day, ModManager.hot_rule_groups_snapshot(), true)
		played += 1
	return played


func test_farm_reference_measures_farm_stats_not_first_team_stats() -> void:
	# 二軍の成績分布は二軍の母集団 (専用球団を含む14球団) から測る。
	# 能力分布 (ratings) は一軍のまま共有する = 一軍選手と二軍選手を同じ物差しで比べられる。
	var season: PSSeason = _fresh_season_with_records()
	_play_farm_days(season, 12)

	var first: Dictionary = PSPerformanceReference.for_season(season.year, season.season_number)
	var farm: Dictionary = PSPerformanceReference.for_season(
		season.year, season.season_number, PSPerformanceReference.LEVEL_FARM
	)
	# 能力スケールは共通。
	assert_str(JSON.stringify(first["ratings"])).is_equal(JSON.stringify(farm["ratings"]))
	# 成績分布は別物 (別のキャッシュキーで別に測られている)。
	assert_bool(first.has("stats")).is_true()
	assert_bool(farm.has("stats")).is_true()


func test_farm_form_moves_perf_score_only_with_enough_playing_time() -> void:
	# 二軍成績が perf_score に効くこと、少ない標本では効かないこと。
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = 9001
	record.year = 2026
	record.season_number = 1
	record.team_id = (GameDb.teams[0] as PSTeam).id
	record.name = "二軍好調"
	record.position = 8
	record.z_abilities_snapshot = {"Bat_Barrel": 0.0, "Bat_Impact": 0.0, "Bat_Loft": 0.0, "Bat_KAvoid": 0.0, "Bat_BBCreate": 0.0, "Run_Speed": 0.0}

	var baseline: float = TeamAutoAI.perf_score(record)

	# 足切り未満: 効かない。
	record.farm_batter_stats.plate_appearances = TeamAutoAI.FARM_FORM_MIN_PLATE_APPEARANCES - 1
	record.farm_batter_stats.at_bats = record.farm_batter_stats.plate_appearances
	record.farm_batter_stats.hits = record.farm_batter_stats.at_bats
	record.farm_batter_stats.home_runs = 15
	assert_float(TeamAutoAI.perf_score(record)).is_equal_approx(baseline, 0.001)

	# 足切り以上で猛打: perf_score が上がる。
	record.farm_batter_stats.plate_appearances = 300
	record.farm_batter_stats.at_bats = 280
	record.farm_batter_stats.hits = 120
	record.farm_batter_stats.doubles = 30
	record.farm_batter_stats.home_runs = 25
	record.farm_batter_stats.walks = 20
	var hot: float = TeamAutoAI.perf_score(record)
	assert_float(hot).override_failure_message(
		"二軍で猛打しても perf_score が動かない (昇格判断の材料にならない)"
	).is_greater(baseline)

	# 二軍で全く打てない場合は下がる。
	record.farm_batter_stats.hits = 40
	record.farm_batter_stats.doubles = 4
	record.farm_batter_stats.home_runs = 0
	record.farm_batter_stats.walks = 5
	assert_float(TeamAutoAI.perf_score(record)).is_less(hot)


func test_farm_form_is_discounted_relative_to_first_team_form() -> void:
	# 二軍の +1 と一軍の +1 を等価に扱わない。FARM_FORM_WEIGHT が較正ノブ。
	assert_float(TeamAutoAI.FARM_FORM_WEIGHT).is_less(1.0)
	assert_float(TeamAutoAI.FARM_FORM_WEIGHT).is_greater(0.0)


func test_first_team_and_farm_form_are_both_counted() -> void:
	# 一軍で不振 → 降格 → 二軍で好調、という選手は両方の form を持つのが正しい。
	# 片方で上書きしていないことを、二軍成績を足したときの差分が一軍成績の有無に依らないことで見る。
	var base: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	base.player_id = 9002
	base.year = 2026
	base.season_number = 1
	base.team_id = (GameDb.teams[0] as PSTeam).id
	base.position = 8
	base.z_abilities_snapshot = {"Bat_Barrel": 0.0, "Bat_Impact": 0.0, "Bat_Loft": 0.0, "Bat_KAvoid": 0.0, "Bat_BBCreate": 0.0, "Run_Speed": 0.0}
	base.batter_stats.plate_appearances = 200
	base.batter_stats.at_bats = 190
	base.batter_stats.hits = 30
	base.batter_stats.strikeouts = 70

	var slumping_only: float = TeamAutoAI.perf_score(base)
	base.farm_batter_stats.plate_appearances = 200
	base.farm_batter_stats.at_bats = 180
	base.farm_batter_stats.hits = 70
	base.farm_batter_stats.doubles = 18
	base.farm_batter_stats.home_runs = 12
	base.farm_batter_stats.walks = 18
	var with_farm: float = TeamAutoAI.perf_score(base)
	assert_float(with_farm).override_failure_message(
		"一軍成績を持つ選手の二軍成績が評価に乗っていない"
	).is_greater(slumping_only)


# ---- 谷間の先発 (スポット昇格) ----------------------------------------------

func test_active_roster_target_matches_between_both_definitions() -> void:
	# TARGET_STARTERS は team_auto_ai と team_setup_builder の2箇所にあり、
	# ずれると「一軍の先発人数」と「入替が目指す人数」が食い違って谷間の発生頻度が変わる。
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(
		SeasonService.create_new_season(GameDb.teams, 1, 2026), (GameDb.teams[0] as PSTeam).id
	)
	assert_bool(bool(preview.get("ok", false))).is_true()
	assert_int(TeamAutoAI.TARGET_STARTERS).is_equal(6)


# 一軍の先発全員が「昨日投げた」状態を作って谷間を強制する。
# ⚠️ 開幕15日間は `PSRotationPlanner._seeded_last_starts` が仮の最終登板日を配るので、
#    それを抜けた日を使う。また last_start=0 は「未登板」扱いなので day は2以上が必要。
func _force_rotation_gap(season: PSSeason, team_id: int, active_ids: Dictionary) -> int:
	var day: int = 0
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		var game_day: int = int(game.get("day", 0))
		if game_day <= 20:
			continue
		if int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id:
			day = game_day
			break
	season.current_day = day
	var rotation: Dictionary = season.get_rotation(team_id).duplicate(true)
	var last_starts: Dictionary = {}
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_ids.has(record.player_id) and record.is_starter_pitcher():
			last_starts[str(record.player_id)] = day - 1
	rotation["last_start_day_by_pitcher"] = last_starts
	season.set_rotation(team_id, rotation)
	return day


func test_spot_callup_promotes_a_rested_farm_starter_and_returns_him_next_day() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	season.set_active_roster(team_id, {"player_ids": preview.get("player_ids", [])})
	var active_ids: Dictionary = {}
	for id_value in (preview.get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	var day: int = _force_rotation_gap(season, team_id, active_ids)
	assert_int(day).is_greater(20)

	var result: Dictionary = TeamAutoAI.run_spot_starter_callups(season, GameDb.teams, day, 0, true)
	var callups: Array = result.get("callups", []) as Array
	var mine: Dictionary = {}
	for row in callups:
		if int((row as Dictionary).get("team_id", 0)) == team_id:
			mine = row as Dictionary
			break
	assert_bool(mine.is_empty()).override_failure_message(
		"谷間なのに二軍から先発が上がってこない"
	).is_false()

	var promoted_id: int = int(mine.get("player_id", 0))
	assert_bool((season.get_active_roster(team_id).get("player_ids", []) as Array).has(promoted_id)).is_true()
	assert_bool(season.get_spot_callups(team_id).has(str(promoted_id))).is_true()
	# 枠を空けた相手は救援 (先発を落とすとローテが崩れる)。
	var replaced: PSPlayerSeasonRecord = RecordStore.get_player_record(
		int(mine.get("replaced_player_id", 0)), season.year, season.season_number
	)
	assert_bool(replaced.is_starter_pitcher()).override_failure_message(
		"スポット昇格の枠を空けるために先発を落としている"
	).is_false()

	# 翌日に抹消され、10日ルールのクールダウンが付く。
	TeamAutoAI.run_spot_starter_callups(season, GameDb.teams, day + 1, 0, true)
	assert_bool((season.get_active_roster(team_id).get("player_ids", []) as Array).has(promoted_id)).override_failure_message(
		"登板を終えたスポット昇格が翌日に抹消されていない"
	).is_false()
	assert_bool(season.get_spot_callups(team_id).has(str(promoted_id))).is_false()
	assert_int(int(season.get_demotion_days(team_id).get(str(promoted_id), 0))).is_equal(day + 1)
	assert_int((season.get_active_roster(team_id).get("player_ids", []) as Array).size()).is_equal(
		TeamAutoAI.TARGET_TOTAL
	)


func test_spot_callup_does_not_fire_when_the_rotation_is_rested() -> void:
	# 通常運用 (中6日・中5日) で埋まる日は谷間ではない。ここを緩めると年489先発が
	# スポット昇格になり、枠繰りでロスターが荒れて中0〜3日の先発まで出る (実測)。
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	season.set_active_roster(team_id, {"player_ids": preview.get("player_ids", [])})

	# 開幕直後 = 全員が十分に休んでいる。
	var result: Dictionary = TeamAutoAI.run_spot_starter_callups(season, GameDb.teams, season.current_day, 0, true)
	for row in (result.get("callups", []) as Array):
		assert_int(int((row as Dictionary).get("team_id", 0))).is_not_equal(team_id)


func test_spot_callup_respects_the_ten_day_cooldown() -> void:
	# 抹消から10日未満の投手は再登録できない。これが「次の谷間は別の投手になる」=
	# 先発の顔ぶれが増える仕掛けの本体。
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_ids: Dictionary = {}
	for id_value in (preview.get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	season.set_active_roster(team_id, {"player_ids": preview.get("player_ids", [])})

	# 二軍の先発を全員クールダウン中にする。
	var farm_starter_ids: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not active_ids.has(record.player_id) and record.is_starter_pitcher() and not record.development_player:
			farm_starter_ids.append(record.player_id)
	assert_int(farm_starter_ids.size()).is_greater(0)
	var day: int = _force_rotation_gap(season, team_id, active_ids)
	season.record_demotions(team_id, farm_starter_ids, day)

	var result: Dictionary = TeamAutoAI.run_spot_starter_callups(season, GameDb.teams, day, 0, true)
	for row in (result.get("callups", []) as Array):
		var callup: Dictionary = row as Dictionary
		if int(callup.get("team_id", 0)) == team_id:
			assert_bool(farm_starter_ids.has(int(callup.get("player_id", 0)))).override_failure_message(
				"10日ルールのクールダウン中の投手が再登録された"
			).is_false()


func test_periodic_starter_adjustment_gives_a_farm_starter_the_rotation_slot() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	assert_bool(bool(preview.get("ok", false))).is_true()
	var active_list: Array = (preview.get("player_ids", []) as Array).duplicate()
	season.set_active_roster(team_id, {"player_ids": active_list})
	season.current_day = 40

	var active_set: Dictionary = {}
	for id_value in active_list:
		active_set[int(id_value)] = true
	var active_starters: Array = []
	var farm_candidate: PSPlayerSeasonRecord = null
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or not record.is_starter_pitcher():
			continue
		if active_set.has(record.player_id):
			record.pitcher_stats.starts = 3
			active_starters.append(record)
		elif farm_candidate == null and not record.development_player:
			farm_candidate = record
	assert_int(active_starters.size()).is_equal(TeamAutoAI.TARGET_STARTERS)
	assert_object(farm_candidate).is_not_null()
	# 品質ゲートだけでテストが母集団依存にならないよう、候補を現ローテと同じ能力へそろえる。
	var template: PSPlayerSeasonRecord = active_starters[0] as PSPlayerSeasonRecord
	farm_candidate.z_abilities_snapshot = template.z_abilities_snapshot.duplicate(true)
	farm_candidate.raw_abilities_snapshot = template.raw_abilities_snapshot.duplicate(true)
	farm_candidate.arsenal_snapshot = template.arsenal_snapshot.duplicate(true)
	farm_candidate.role = "starter"

	var rotation_ids: Array = []
	for record_row in active_starters:
		rotation_ids.append((record_row as PSPlayerSeasonRecord).player_id)
	season.set_rotation(team_id, {
		"pitcher_ids": rotation_ids.duplicate(),
		"last_start_day_by_pitcher": {},
		"auto_generated": true,
	})
	var result: Dictionary = TeamAutoAI._try_starter_rotation_adjustment(
		season, team_id, season.current_day, []
	)

	assert_bool(result.is_empty()).is_false()
	var down_id: int = int(result.get("down", 0))
	var up_id: int = int(result.get("up", 0))
	assert_int(down_id).is_greater(0)
	assert_int(up_id).is_greater(0)
	var roster_ids: Array = season.get_active_roster(team_id).get("player_ids", []) as Array
	assert_int(roster_ids.size()).is_equal(TeamAutoAI.TARGET_TOTAL)
	assert_bool(roster_ids.has(down_id)).is_false()
	assert_bool(roster_ids.has(up_id)).is_true()
	var new_rotation: Array = season.get_rotation(team_id).get("pitcher_ids", []) as Array
	assert_int(new_rotation.find(up_id)).is_equal(rotation_ids.find(down_id))
	assert_bool(season.get_demotion_days(team_id).has(str(down_id))).is_true()
	assert_bool(season.get_callup_appearance_baselines(team_id).has(str(up_id))).is_true()


func test_periodic_swap_keeps_new_active_players_until_their_first_appearance() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_list: Array = (preview.get("player_ids", []) as Array).duplicate()
	season.set_active_roster(team_id, {"player_ids": active_list})
	for id_value in active_list:
		season.record_callup_appearance_baseline(team_id, int(id_value), 0)

	var result: Dictionary = TeamAutoAI._swap_one_team(season, team_id, 1)

	assert_array(result.get("swapped_pairs", []) as Array).is_empty()
	assert_int((season.get_active_roster(team_id).get("player_ids", []) as Array).size()).is_equal(
		TeamAutoAI.TARGET_TOTAL
	)


func test_periodic_depth_adjustment_cycles_an_appeared_bottom_reliever() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_list: Array = (preview.get("player_ids", []) as Array).duplicate()
	season.set_active_roster(team_id, {"player_ids": active_list})
	season.current_day = 40
	var active_set: Dictionary = {}
	for id_value in active_list:
		active_set[int(id_value)] = true
	var active_reliever: PSPlayerSeasonRecord = null
	var farm_reliever: PSPlayerSeasonRecord = null
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher() or record.is_starter_pitcher():
			continue
		if active_set.has(record.player_id):
			record.pitcher_stats.games = 1
			if active_reliever == null:
				active_reliever = record
		elif farm_reliever == null and not record.development_player:
			farm_reliever = record
	assert_object(active_reliever).is_not_null()
	assert_object(farm_reliever).is_not_null()
	farm_reliever.z_abilities_snapshot = active_reliever.z_abilities_snapshot.duplicate(true)
	farm_reliever.raw_abilities_snapshot = active_reliever.raw_abilities_snapshot.duplicate(true)
	farm_reliever.arsenal_snapshot = active_reliever.arsenal_snapshot.duplicate(true)
	farm_reliever.role = "reliever"

	var result: Dictionary = TeamAutoAI._try_depth_roster_adjustment(
		season, team_id, season.current_day, TeamAutoAI.PITCHER_ROLE_RELIEVER
	)

	assert_bool(result.is_empty()).is_false()
	assert_str(str(result.get("reason", ""))).is_equal("reliever_adjustment")
	var roster_ids: Array = season.get_active_roster(team_id).get("player_ids", []) as Array
	assert_int(roster_ids.size()).is_equal(TeamAutoAI.TARGET_TOTAL)
	assert_bool(roster_ids.has(int(result.get("up", 0)))).is_true()
	assert_bool(season.get_callup_appearance_baselines(team_id).has(
		str(int(result.get("up", 0)))
	)).is_true()


# 週次の循環枠はローテ中軸を動かさない。降格候補は「二軍登板の少ない順」に並ぶので、
# 二軍登板 0 のエースがまっ先に候補になる。守らないとエースが毎週落とされ、リーグ最多先発が
# 24試合・規定投球回到達が3〜6人まで落ちる (2026-08-28 実測)。
func test_pitcher_circulation_keeps_the_rotation_core_on_the_active_roster() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_list: Array = (preview.get("player_ids", []) as Array).duplicate()
	season.set_active_roster(team_id, {"player_ids": active_list})
	season.current_day = 40
	var active_set: Dictionary = {}
	for id_value in active_list:
		active_set[int(id_value)] = true
	var active_starter_ids: Array = []
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher() or not active_set.has(record.player_id):
			continue
		record.pitcher_stats.games = 5
		record.pitcher_stats.starts = 2 if record.is_starter_pitcher() else 0
		record.farm_pitcher_stats.games = 0
		if record.is_starter_pitcher():
			active_starter_ids.append(record.player_id)
	assert_bool(active_starter_ids.size() >= TeamAutoAI.PITCHER_CIRCULATION_PROTECTED_ROTATION_RANKS).is_true()
	season.set_rotation(team_id, {"pitcher_ids": active_starter_ids})

	var protected_ids: Array = active_starter_ids.slice(
		0, TeamAutoAI.PITCHER_CIRCULATION_PROTECTED_ROTATION_RANKS
	)
	for _week in range(6):
		var result: Dictionary = TeamAutoAI._try_pitcher_circulation_adjustment(
			season, team_id, season.current_day
		)
		if not result.is_empty():
			assert_bool(protected_ids.has(int(result.get("down", 0)))).is_false()
		season.current_day += TeamAutoAI.PITCHER_CIRCULATION_INTERVAL_DAYS

	var roster_ids: Array = season.get_active_roster(team_id).get("player_ids", []) as Array
	for protected_id in protected_ids:
		assert_bool(roster_ids.has(int(protected_id))).is_true()


func test_pitcher_circulation_sends_an_untried_active_pitcher_to_farm() -> void:
	var season: PSSeason = _fresh_season_with_records()
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var preview: Dictionary = PSTeamSetupBuilder.preview_active_roster(season, team_id)
	var active_list: Array = (preview.get("player_ids", []) as Array).duplicate()
	season.set_active_roster(team_id, {"player_ids": active_list})
	season.current_day = 40
	var active_set: Dictionary = {}
	for id_value in active_list:
		active_set[int(id_value)] = true
	var active_pitchers: Array = []
	var inactive_by_role: Dictionary = {"starter": [], "reliever": []}
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher():
			continue
		var role_key: String = "starter" if record.is_starter_pitcher() else "reliever"
		if active_set.has(record.player_id):
			record.pitcher_stats.games = 5
			record.pitcher_stats.starts = 2 if record.is_starter_pitcher() else 0
			record.farm_pitcher_stats.games = 0
			active_pitchers.append(record)
		elif not record.development_player:
			(inactive_by_role[role_key] as Array).append(record)
	assert_int(active_pitchers.size()).is_equal(TeamAutoAI.TARGET_PITCHERS)
	# 母集団差で品質ゲートだけがテストを止めないよう、両役割に同等の代役を1人作る。
	for role_key in inactive_by_role.keys():
		var inactive: Array = inactive_by_role[role_key] as Array
		if inactive.is_empty():
			continue
		var template: PSPlayerSeasonRecord = null
		for active_row in active_pitchers:
			var active: PSPlayerSeasonRecord = active_row as PSPlayerSeasonRecord
			if ("starter" if active.is_starter_pitcher() else "reliever") == str(role_key):
				template = active
				break
		if template == null:
			continue
		var candidate: PSPlayerSeasonRecord = inactive[0] as PSPlayerSeasonRecord
		candidate.z_abilities_snapshot = template.z_abilities_snapshot.duplicate(true)
		candidate.raw_abilities_snapshot = template.raw_abilities_snapshot.duplicate(true)
		candidate.arsenal_snapshot = template.arsenal_snapshot.duplicate(true)
		candidate.role = str(role_key)

	var result: Dictionary = TeamAutoAI._try_pitcher_circulation_adjustment(
		season, team_id, season.current_day
	)

	assert_bool(result.is_empty()).is_false()
	assert_str(str(result.get("reason", ""))).is_equal("pitcher_circulation")
	var down: PSPlayerSeasonRecord = RecordStore.get_player_record(
		int(result.get("down", 0)), season.year, season.season_number
	)
	var up: PSPlayerSeasonRecord = RecordStore.get_player_record(
		int(result.get("up", 0)), season.year, season.season_number
	)
	assert_int(down.farm_pitcher_stats.games).is_equal(0)
	assert_bool(down.is_starter_pitcher()).is_equal(up.is_starter_pitcher())
	var roster_ids: Array = season.get_active_roster(team_id).get("player_ids", []) as Array
	assert_int(roster_ids.size()).is_equal(TeamAutoAI.TARGET_TOTAL)
	assert_bool(roster_ids.has(down.player_id)).is_false()
	assert_bool(roster_ids.has(up.player_id)).is_true()


# ---- 成績の器 --------------------------------------------------------------

func _record_with_farm_stats() -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = 4242
	record.year = 2026
	record.season_number = 1
	record.team_id = 1
	record.name = "テスト太郎"
	record.position = 8
	record.batter_stats.games = 100
	record.batter_stats.hits = 130
	record.batter_stats.home_runs = 20
	record.farm_batter_stats.games = 20
	record.farm_batter_stats.hits = 25
	record.farm_batter_stats.home_runs = 4
	record.pitcher_stats.strikeouts = 90
	record.farm_pitcher_stats.strikeouts = 15
	record.farm_consecutive_appearances = 2
	record.farm_last_pitched_team_game = 41
	record.farm_advanced_stats.player_id = record.player_id
	record.farm_advanced_stats.plate_appearances = 100
	record.farm_advanced_stats.woba_denominator = 100
	record.farm_advanced_stats.xwoba_denominator = 100
	record.farm_advanced_stats.woba_numerator = 37.2
	record.farm_advanced_stats.xwoba_numerator = 35.0
	record.farm_advanced_stats.defensive_outs_by_position = {"8": 270, "9": 90}
	record.farm_advanced_stats.fielding_chances = 30
	record.farm_advanced_stats.fielding_chances_by_position = {"8": 24, "9": 6}
	record.farm_advanced_stats.oaa_by_zone = {"outfield": 2.5}
	record.farm_advanced_stats.oaa_by_position = {"8": 2.0, "9": 0.5}
	record.farm_advanced_stats.uzr_by_position = {"8": 1.8, "9": 0.4}
	return record


func test_farm_stats_are_a_separate_container_from_first_team_stats() -> void:
	var record: PSPlayerSeasonRecord = _record_with_farm_stats()
	# 同じ器を別インスタンスで持つ = 片方を足しても他方は動かない。
	assert_int(record.batter_stats.hits).is_equal(130)
	assert_int(record.farm_batter_stats.hits).is_equal(25)
	record.farm_batter_stats.hits += 10
	assert_int(record.batter_stats.hits).is_equal(130)
	assert_int(record.pitcher_stats.strikeouts).is_equal(90)
	assert_int(record.farm_pitcher_stats.strikeouts).is_equal(15)
	record.farm_advanced_stats.woba_numerator += 1.0
	assert_float(record.advanced_stats.woba_numerator).is_equal_approx(0.0, 0.001)


func test_defensive_innings_default_stays_first_team_only() -> void:
	# 既定を一軍のみに保つのが要 — ゴールデングラブ等「一軍の表彰」が二軍の
	# 守備イニングを数えてしまう事故を防ぐ。成長だけが合算版を使う。
	var record: PSPlayerSeasonRecord = _record_with_farm_stats()
	record.advanced_stats.defensive_outs_by_position = {"8": 900}

	assert_float(record.defensive_innings_at(8)).is_equal_approx(300.0, 0.001)
	assert_float(record.farm_defensive_innings_at(8)).is_equal_approx(90.0, 0.001)
	assert_float(record.total_defensive_innings_at(8)).is_equal_approx(390.0, 0.001)
	# 一軍で守っていないポジションでも二軍の分は合算に出る (コンバート練習の反映)。
	assert_float(record.defensive_innings_at(9)).is_equal_approx(0.0, 0.001)
	assert_float(record.total_defensive_innings_at(9)).is_equal_approx(30.0, 0.001)


func test_position_aptitude_growth_counts_farm_innings() -> void:
	# 二軍でコンバートを試した分が適性に乗ること (ブロック2 を入れた主目的の一つ)。
	var player: PSPlayer = PSPlayer.from_dict({
		"id": 4242, "name": "テスト太郎", "age": 22, "position": 8,
		"position_aptitudes": {"center": 80, "right": 0},
	})
	var record: PSPlayerSeasonRecord = _record_with_farm_stats()
	record.advanced_stats.defensive_outs_by_position = {}
	record.farm_advanced_stats.defensive_outs_by_position = {"9": 900}

	OffseasonService.apply_position_aptitude_growth(player, record)
	assert_int(int(player.position_aptitudes.get("right", 0))).override_failure_message(
		"farm defensive innings did not feed position aptitude growth"
	).is_greater(0)


func test_player_record_round_trip_keeps_farm_stats() -> void:
	var record: PSPlayerSeasonRecord = _record_with_farm_stats()
	var restored: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(record.to_dict())

	assert_int(restored.batter_stats.hits).is_equal(130)
	assert_int(restored.farm_batter_stats.hits).is_equal(25)
	assert_int(restored.farm_batter_stats.home_runs).is_equal(4)
	assert_int(restored.farm_pitcher_stats.strikeouts).is_equal(15)
	assert_int(restored.farm_consecutive_appearances).is_equal(2)
	assert_int(restored.farm_last_pitched_team_game).is_equal(41)
	assert_float(restored.farm_defensive_innings_at(8)).is_equal_approx(90.0, 0.001)
	assert_float(restored.farm_advanced_stats.woba()).is_equal_approx(0.372, 0.001)
	assert_float(restored.farm_advanced_stats.wraa()).is_equal_approx(4.596, 0.001)
	assert_float(float(restored.farm_advanced_stats.to_dict().get("oaa_total", 0.0))).is_equal_approx(2.5, 0.001)


func test_team_record_round_trip_keeps_farm_standings() -> void:
	var team_record: PSTeamSeasonRecord = PSTeamSeasonRecord.from_team(GameDb.teams[0] as PSTeam, 2026, 1)
	team_record.stats.wins = 80
	team_record.stats.losses = 60
	team_record.farm_stats.wins = 70
	team_record.farm_stats.losses = 50
	team_record.farm_stats.draws = 4

	var restored: PSTeamSeasonRecord = PSTeamSeasonRecord.from_dict(team_record.to_dict())
	assert_int(restored.stats.wins).is_equal(80)
	assert_int(restored.farm_stats.wins).is_equal(70)
	assert_int(restored.farm_stats.losses).is_equal(50)
	assert_int(restored.farm_stats.draws).is_equal(4)


func test_farm_stats_survive_a_sqlite_round_trip() -> void:
	if not SQLiteStore.is_available():
		return
	# SQLite はセーブフォルダごとの DB なので、テスト専用のセーブを作ってから書き込む。
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	var record: PSPlayerSeasonRecord = _record_with_farm_stats()
	var payload: Dictionary = {
		"version": 2,
		"player_records": [record.to_dict()],
		"team_records": [],
		"season_archives": [],
	}
	SQLiteStore.reset_record_fingerprints()
	var saved: bool = SQLiteStore.save_record_store_and_normalized(payload)

	var found: PSPlayerSeasonRecord = null
	if saved:
		for row_value in SQLiteStore.load_all_player_season_record_dicts():
			var row: Dictionary = row_value as Dictionary
			if int(row.get("player_id", 0)) == record.player_id:
				found = PSPlayerSeasonRecord.from_dict(row)
				break

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	SQLiteStore.reset_record_fingerprints()

	assert_bool(saved).is_true()
	assert_object(found).is_not_null()
	# 一軍成績と二軍成績が別テーブルへ往復し、混ざっていない。
	assert_int(found.batter_stats.hits).is_equal(130)
	assert_int(found.farm_batter_stats.hits).is_equal(25)
	assert_int(found.farm_batter_stats.home_runs).is_equal(4)
	assert_int(found.farm_pitcher_stats.strikeouts).is_equal(15)
	assert_int(found.pitcher_stats.strikeouts).is_equal(90)
	assert_int(found.farm_consecutive_appearances).is_equal(2)
	assert_int(found.farm_last_pitched_team_game).is_equal(41)
	assert_float(found.farm_defensive_innings_at(8)).is_equal_approx(90.0, 0.001)
	assert_float(found.farm_advanced_stats.woba()).is_equal_approx(0.372, 0.001)
	assert_float(found.farm_advanced_stats.wraa()).is_equal_approx(4.596, 0.001)
	assert_float(float(found.farm_advanced_stats.to_dict().get("oaa_total", 0.0))).is_equal_approx(2.5, 0.001)


func test_season_round_trip_keeps_farm_schedule_and_standings() -> void:
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	(season.farm_standings[13] as PSStats).wins = 7
	(season.farm_standings[13] as PSStats).losses = 3

	var restored: PSSeason = PSSeason.from_dict(season.to_dict())
	assert_int(restored.farm_schedule.size()).is_equal(season.farm_schedule.size())
	assert_int(restored.farm_standings.size()).is_equal(14)
	assert_int((restored.farm_standings[13] as PSStats).wins).is_equal(7)
	assert_int((restored.farm_standings[13] as PSStats).losses).is_equal(3)
	# 専用球団も順位表に載る。
	for club_id in PSFarmLeague.farm_club_ids():
		assert_bool(restored.farm_standings.has(int(club_id))).is_true()
