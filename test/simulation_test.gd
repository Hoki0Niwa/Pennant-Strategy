extends GdUnitTestSuite

const SaveContext = preload("res://services/storage/save_context.gd")
const CampServiceRef = preload("res://services/season/camp_service.gd")


# CPU の特別練習件数は球団事情で変動し、必要なければ 0、上限は 3。一律 3 にならないこと。
func test_camp_training_count_varies_by_need() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	var result: Dictionary = CampServiceRef.process_camp(GameDb.players, GameDb.teams, season, 0)
	var per_team: Dictionary = {}
	for action_row in result.get("actions", []) as Array:
		var tid: int = int((action_row as Dictionary).get("team_id", 0))
		per_team[tid] = int(per_team.get(tid, 0)) + 1
	var counts: Array = []
	for team_row in GameDb.teams:
		counts.append(int(per_team.get((team_row as PSTeam).id, 0)))
	counts.sort()
	print("CAMPCOUNT per_team=%s" % str(counts))

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	# 需要連動: 一律にならず変動する (最少 < 最多)。需要の薄い球団は少なく (<=1)、需要のある球団は実施する。
	assert_int(int(counts[0])).is_less(int(counts[counts.size() - 1]))
	assert_int(int(counts[0])).is_less_equal(1)
	assert_int(int(counts[counts.size() - 1])).is_greater(0)


# 表示評価値 (overall_score) は 野手 / 先発 / 中継 で同スケールであること。
# 先発は係数圧縮で野手スケールへ、中継は relief 強調式で先発スケールへ較正済み。
func test_pitcher_eval_on_same_scale_as_fielders() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	var fielders: Array = []
	var starters: Array = []
	var relievers: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null:
			continue
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
		if record.is_pitcher():
			if PSPitcherRoleModel.is_starter_record(record):
				starters.append(PSPlayerValueEvaluator.overall_score(record))
			else:
				relievers.append(PSPlayerValueEvaluator.overall_score(record))
		else:
			fielders.append(PSPlayerValueEvaluator.overall_score(record))

	print("EVALSCALE fielders ", _dist(fielders))
	print("EVALSCALE starters ", _dist(starters))
	print("EVALSCALE relievers ", _dist(relievers))

	var fielder_mean: float = _mean(fielders)
	var starter_mean: float = _mean(starters)
	var reliever_mean: float = _mean(relievers)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	assert_int(starters.size()).is_greater(0)
	assert_int(relievers.size()).is_greater(0)
	# 先発は野手と同スケール (平均差 <= 5)。旧実装は +7 高かった。
	assert_float(absf(starter_mean - fielder_mean)).is_less_equal(5.0)
	# 中継は先発と同スケール (平均差 <= 5)。
	assert_float(absf(reliever_mean - starter_mean)).is_less_equal(5.0)
	# 先発の上位帯が野手を大きく上回らない (旧 p90 88 > 野手 80 / max 99 の是正)。
	assert_int(_pctl(starters, 0.90)).is_less_equal(_pctl(fielders, 0.90) + 4)
	assert_int(_max(starters)).is_less_equal(_max(fielders) + 2)


func test_overall_score_ignores_fatigue_with_explicit_fatigue_variant() -> void:
	var record: PSPlayerSeasonRecord = _fielder(901, "Everyday", 1.0)
	record.fatigue = 0
	var base_overall: int = PSPlayerValueEvaluator.overall_score(record)
	var fresh_with_fatigue: int = PSPlayerValueEvaluator.overall_score_with_fatigue(record)
	var base_display_bat: int = PSPlayerValueEvaluator.batting_score_without_fatigue(record)
	var fresh_batting: int = PSPlayerValueEvaluator.batting_score(record)

	record.fatigue = 160

	assert_int(PSPlayerValueEvaluator.overall_score(record)).is_equal(base_overall)
	assert_int(PSPlayerValueEvaluator.batting_score_without_fatigue(record)).is_equal(base_display_bat)
	assert_int(PSPlayerValueEvaluator.overall_score_with_fatigue(record)).is_less(fresh_with_fatigue)
	assert_int(PSPlayerValueEvaluator.batting_score(record)).is_less(fresh_batting)


# 控え (打順設定の補充優先リスト) は usage.position_slots[pos].backup_ids として保存され、
# 守備配置で profile.backup_priority より優先される。スタメンが故障で抜けた枠を埋める。
func test_usage_backup_ids_take_priority_over_profile() -> void:
	var apt_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS
	var mk: Callable = func(pid: int, pos: int, injured: bool) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = pos
		r.name = "P%d" % pid
		r.injury_days = 5 if injured else 0
		var snap: Dictionary = {}
		snap[str(apt_keys.get(pos, "catcher"))] = 80
		r.position_aptitudes_snapshot = snap
		return r

	# 守備位置 [捕2, 遊6, 中8, 二4, 三5, 一3, 左7, 右9] をテンプレートで埋める。捕手の正は故障。
	var positions: Array = [2, 6, 8, 4, 5, 3, 7, 9]
	var fielders: Array = []
	var template: Dictionary = {}
	var injured_catcher: PSPlayerSeasonRecord = mk.call(200, 2, true)
	fielders.append(injured_catcher)
	template[2] = injured_catcher.player_id
	var next_id: int = 300
	for pos_row in positions:
		var pos: int = int(pos_row)
		if pos == 2:
			continue
		var rec: PSPlayerSeasonRecord = mk.call(next_id, pos, false)
		fielders.append(rec)
		template[pos] = rec.player_id
		next_id += 1
	# 捕手を守れる控え2人 (B=usage, X=profile)。
	var usage_backup: PSPlayerSeasonRecord = mk.call(501, 2, false)
	var profile_backup: PSPlayerSeasonRecord = mk.call(502, 2, false)
	fielders.append(usage_backup)
	fielders.append(profile_backup)

	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(9999)
	profile.starting_positions = template.duplicate()
	profile.backup_priority = {2: [profile_backup.player_id]}

	var usage: Dictionary = {"position_slots": {"2": {
		"starter_id": injured_catcher.player_id,
		"sub_id": 0,
		"sub_start_interval": 0,
		"backup_ids": [usage_backup.player_id],
	}}}

	var slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, usage, 1)
	var catcher_id: int = 0
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot.get("position", 0)) == 2:
			catcher_id = (slot.get("record", null) as PSPlayerSeasonRecord).player_id
	# usage の backup_ids (B) が profile.backup_priority (X) より優先される。
	assert_int(catcher_id).is_equal(usage_backup.player_id)


func _dist(values: Array) -> String:
	if values.is_empty():
		return "n=0"
	values.sort()
	var n: int = values.size()
	var pct: Callable = func(p: float) -> int:
		return int(values[clampi(int(round(p * float(n - 1))), 0, n - 1)])
	return "n=%d mean=%.1f min=%d p25=%d p50=%d p75=%d p90=%d max=%d" % [
		n, _mean(values), int(values[0]), pct.call(0.25), pct.call(0.50), pct.call(0.75), pct.call(0.90), int(values[n - 1])]


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sum: float = 0.0
	for v in values:
		sum += float(v)
	return sum / float(values.size())


func _pctl(values: Array, p: float) -> int:
	if values.is_empty():
		return 0
	var sorted: Array = values.duplicate()
	sorted.sort()
	return int(sorted[clampi(int(round(p * float(sorted.size() - 1))), 0, sorted.size() - 1)])


func _max(values: Array) -> int:
	var best: int = -2147483647
	for v in values:
		best = maxi(best, int(v))
	return best


func test_closer_role_is_preferred_in_ninth_close_game() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(101, "Closer", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(102, "Middle", 0.6)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [middle, closer],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var game_result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 3,
		"home_score": 2,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, game_result, false)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(closer.player_id)


func test_long_role_is_preferred_when_starter_exits_early() -> void:
	var long_reliever: PSPlayerSeasonRecord = _pitcher(201, "Long", 0.0)
	var short_reliever: PSPlayerSeasonRecord = _pitcher(202, "Short", 0.6)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [short_reliever, long_reliever],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			long_reliever.player_id: PSRotationPlanner.RELIEF_ROLE_LONG,
			short_reliever.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 4, {}, true)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(long_reliever.player_id)


func test_saved_relief_roles_are_kept_in_reliever_pool() -> void:
	var top: PSPlayerSeasonRecord = _pitcher(301, "Top", 1.2)
	var role_pick: PSPlayerSeasonRecord = _pitcher(302, "Role Pick", -0.4)
	var others: Array = []
	for i in range(6):
		others.append(_pitcher(310 + i, "Other %d" % i, 0.8 - float(i) * 0.05))
	var pool: Array = [top]
	pool.append_array(others)
	pool.append(role_pick)
	var saved: Dictionary = {
		"relief_roles": {
			"closer_id": role_pick.player_id,
			"setup_ids": [],
			"middle_ids": [],
			"long_id": 0,
		},
	}

	var selected: Array = PSRotationPlanner.select_relievers_for_innings(pool, [], 0, saved)
	var ids: Array = []
	for record_value in selected:
		ids.append((record_value as PSPlayerSeasonRecord).player_id)

	assert_array(ids).contains(role_pick.player_id)
	assert_int(int(ids[0])).is_equal(role_pick.player_id)


func test_is_starter_pitcher_honors_stored_role_over_ability() -> void:
	# 先発寄りの能力 (高持久) を持つ投手。
	var p: PSPlayerSeasonRecord = _pitcher(401, "Swing", 0.5)
	p.z_abilities_snapshot["Pit_Stamina"] = 2.0
	p.z_abilities_snapshot["Pit_FatigueResist"] = 1.5

	# role="starter" → 能力に関わらず先発。
	p.role = "starter"
	assert_bool(p.is_starter_pitcher()).is_true()

	# role="reliever" → 能力が先発寄りでも保存 role が正準なのでリリーフ。
	p.role = "reliever"
	assert_bool(p.is_starter_pitcher()).is_false()

	# role="closer" → リリーフ扱い。
	p.role = "closer"
	assert_bool(p.is_starter_pitcher()).is_false()

	# role 未設定 ("") のときだけ能力で初期判定 (高持久なので先発)。
	p.role = ""
	assert_bool(p.is_starter_pitcher()).is_true()


func test_starter_candidates_use_stored_role_and_keep_reliever_out() -> void:
	var pitchers: Array = []
	for i in range(6):
		var s: PSPlayerSeasonRecord = _pitcher(440 + i, "Start %d" % i, 0.5)
		s.role = "starter"
		pitchers.append(s)
	var rel: PSPlayerSeasonRecord = _pitcher(450, "Ace Reliever", 1.8)
	rel.role = "reliever"
	pitchers.append(rel)

	var starters: Array = PSTeamSetupBuilder.starter_pitcher_candidates(pitchers)
	# stored-starter が十分いれば補充は発火しない。
	assert_int(starters.size()).is_equal(6)
	var ids: Array = []
	for s in starters:
		ids.append((s as PSPlayerSeasonRecord).player_id)
	# 能力の高いリリーフでも保存 role が reliever ならローテに入らない。
	assert_array(ids).not_contains(450)


func test_starter_candidates_backfill_only_when_no_stored_starter() -> void:
	var pitchers: Array = []
	for i in range(6):
		var r: PSPlayerSeasonRecord = _pitcher(420 + i, "Relief %d" % i, 0.6 - float(i) * 0.05)
		r.role = "reliever"
		pitchers.append(r)

	var starters: Array = PSTeamSetupBuilder.starter_pitcher_candidates(pitchers)
	# stored-starter ゼロのときだけ先発適性順で STARTER_POOL_MIN 人まで緊急補充される。
	assert_int(starters.size()).is_equal(PSTeamSetupBuilder.STARTER_POOL_MIN)


func test_few_starters_do_not_pull_reliever_or_closer_into_rotation() -> void:
	var pitchers: Array = []
	# stored-starter は 2 人だけ (ローテ最小未満) だが、補充はしない。
	for i in range(2):
		var s: PSPlayerSeasonRecord = _pitcher(460 + i, "Start %d" % i, 0.4)
		s.role = "starter"
		pitchers.append(s)
	# 能力の高いクローザー/中継 (起用法でクローザー指定されるような投手) も混ざる。
	var closer: PSPlayerSeasonRecord = _pitcher(470, "Ace Closer", 2.0)
	closer.role = "closer"
	pitchers.append(closer)
	for i in range(4):
		var r: PSPlayerSeasonRecord = _pitcher(471 + i, "Relief %d" % i, 1.0)
		r.role = "reliever"
		pitchers.append(r)

	var starters: Array = PSTeamSetupBuilder.starter_pitcher_candidates(pitchers)
	var ids: Array = []
	for s in starters:
		ids.append((s as PSPlayerSeasonRecord).player_id)
	# starter が 1 人でもいれば補充は発火せず、リリーフ/クローザーはローテに入らない。
	assert_int(starters.size()).is_equal(2)
	assert_array(ids).not_contains(470)


# 統合: 保存 role 正準 (B) でも実シードの全チームが先発を立て、ブルペンを編成できること。
# autoload (GameDb/AppState) が必要なので GdUnit 文脈で実行する。
func test_all_teams_field_rotation_and_bullpen_with_stored_roles() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	for team_row in GameDb.teams:
		var tid: int = (team_row as PSTeam).id
		var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, tid, true)
		assert_bool(bool(setup.get("ok", false))) \
			.override_failure_message("team %d setup failed: %s" % [tid, str(setup.get("message", ""))]) \
			.is_true()
		assert_object(setup.get("starter_pitcher", null)).is_not_null()
		assert_int((setup.get("relievers", []) as Array).size()).is_greater(0)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()


func _pitcher(player_id: int, player_name: String, z: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.name = player_name
	record.position = 1
	record.role = "reliever"
	record.age = 27
	record.fatigue = 0
	record.injury_days = 0
	record.z_abilities_snapshot = {
		"Pit_KCreate": z,
		"Pit_EdgeRate": z,
		"Pit_BBPrevent": z,
		"Pit_BarrelDeny": z,
		"Pit_ImpactLimit": z,
		"Pit_LoftControl": z,
		"Pit_Efficiency": z,
		"Pit_FatigueResist": z,
		"Pit_Stamina": z,
		"Pit_HoldRunner": z,
	}
	record.raw_abilities_snapshot = {"max_velocity": 150 + int(round(z * 3.0))}
	record.arsenal_snapshot = [
		{"type": "four_seam", "mastery": z},
		{"type": "slider", "mastery": z - 0.1},
	]
	return record


func _fielder(player_id: int, player_name: String, z: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.name = player_name
	record.position = 3
	record.role = "fielder"
	record.age = 27
	record.fatigue = 0
	record.injury_days = 0
	record.position_aptitudes_snapshot = {"first": 100}
	record.z_abilities_snapshot = {
		"Bat_KAvoid": z,
		"Bat_BBCreate": z,
		"Bat_Impact": z,
		"Bat_Loft": z,
		"Bat_Barrel": z,
		"Bat_Spray": z,
		"Bat_Aggression": z,
		"Bat_Platoon": z,
		"IF_Reach": z,
		"IF_Secure": z,
		"IF_ThrowPower": z,
		"IF_ThrowAccuracy": z,
		"IF_Exchange": z,
		"IF_PositionFit": z,
		"Run_Speed": z,
		"Run_Judgment": z,
		"Run_Steal": z,
	}
	return record


# DH 制の打席結果には投手 (救援含む) を含めず、非 DH では投手が打席に並ぶこと。
func test_box_score_excludes_pitchers_under_dh() -> void:
	var BoxScore = load("res://services/reports/box_score_builder.gd")

	# DH: 打順9枠に投手 (守備位置1) は無く、DH は位置10。救援投手の交代を1件含める。
	var dh_slots: Array = []
	for i in range(9):
		dh_slots.append({"slot": i + 1, "position": [2, 3, 4, 5, 6, 7, 8, 9, 10][i], "player_id": 101 + i})
	var dh_log: Dictionary = {
		"pa_log": [],
		"lineups": {"away": {"team_id": 1, "dh": true, "slots": dh_slots}},
		"substitutions": [{"team_id": 1, "kind": "pitching", "out_id": 200, "in_id": 201, "position": 1, "slot": -1}],
	}
	var dh_rows: Array = BoxScore.build(dh_log, 1, null).get("rows", []) as Array
	assert_int(dh_rows.size()).is_equal(9)
	for row_value in dh_rows:
		var row: Dictionary = row_value as Dictionary
		assert_str(str(row.get("pos", ""))).is_not_equal("投")
		assert_str(str(row.get("name", ""))).is_not_equal("#201")

	# 非 DH: 打順9枠目を投手 (守備位置1) にし、同じ救援交代を投手スロットへ連ねる。
	var nodh_slots: Array = []
	for i in range(9):
		nodh_slots.append({"slot": i + 1, "position": [2, 3, 4, 5, 6, 7, 8, 9, 1][i], "player_id": 101 + i})
	var nodh_log: Dictionary = {
		"pa_log": [],
		"lineups": {"away": {"team_id": 1, "dh": false, "slots": nodh_slots}},
		"substitutions": [{"team_id": 1, "kind": "pitching", "out_id": 109, "in_id": 201, "position": 1, "slot": -1}],
	}
	var nodh_rows: Array = BoxScore.build(nodh_log, 1, null).get("rows", []) as Array
	assert_int(nodh_rows.size()).is_equal(10)  # 先発9 + 救援1
	var has_relief: bool = false
	for row_value in nodh_rows:
		var row: Dictionary = row_value as Dictionary
		if str(row.get("name", "")) == "#201":
			has_relief = true
			assert_str(str(row.get("pos", ""))).is_equal("投")
	assert_bool(has_relief).is_true()


# 打者一巡で同一イニングに2打席立った場合、「・」連結ではなく新しい列に書く。
func test_box_score_adds_column_when_batting_around() -> void:
	var BoxScore = load("res://services/reports/box_score_builder.gd")
	var log: Dictionary = {
		"lineups": {"away": {"team_id": 1, "dh": false, "slots": [
			{"slot": 1, "position": 8, "player_id": 101},
		]}},
		"substitutions": [],
		"pa_log": [
			{"batting_team_id": 1, "batter_id": 101, "inning": 1, "category": "hit", "bases": 1, "ab_charged": true, "rbi": 0, "fielder_position": 8},
			{"batting_team_id": 1, "batter_id": 101, "inning": 1, "category": "strikeout", "ab_charged": true, "rbi": 0},
		],
	}
	var data: Dictionary = BoxScore.build(log, 1, null)

	# 1回の列が2列に増えている。
	var inning1_cols: int = 0
	for col_value in (data.get("columns", []) as Array):
		if int((col_value as Dictionary).get("inning", 0)) == 1:
			inning1_cols += 1
	assert_int(inning1_cols).is_equal(2)

	# 101 の行: 1回の2列がそれぞれ非空で、「・」連結されていない。
	var rows: Array = data.get("rows", []) as Array
	assert_int(rows.size()).is_greater(0)
	var cells: Array = (rows[0] as Dictionary).get("cells", []) as Array
	var c0: String = str((cells[0] as Dictionary).get("text", ""))
	var c1: String = str((cells[1] as Dictionary).get("text", ""))
	assert_str(c0).is_not_empty()
	assert_str(c1).is_not_empty()
	assert_bool(c0.contains("・")).is_false()
	assert_bool(c1.contains("・")).is_false()
	# 打数2 / 安打1。
	assert_int(int((rows[0] as Dictionary).get("ab", 0))).is_equal(2)
	assert_int(int((rows[0] as Dictionary).get("h", 0))).is_equal(1)
