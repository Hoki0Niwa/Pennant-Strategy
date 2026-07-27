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

	# 需要連動: 機械的に全球団が上限 (3) へ張り付かないこと。初期データの構成が均衡していて
	# 開幕時点の需要が無ければ全球団 0 もあり得る (2026-07-06 ポジション構成リバランス後は正常挙動)。
	assert_int(int(counts[counts.size() - 1])).is_less_equal(CampServiceRef.MAX_SPECIAL_TRAININGS_PER_TEAM)
	assert_int(int(counts[0])).is_less_equal(1)


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
	var all_pitchers: Array = starters.duplicate()
	all_pitchers.append_array(relievers)
	var pitcher_mean: float = _mean(all_pitchers)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	assert_int(starters.size()).is_greater(0)
	assert_int(relievers.size()).is_greater(0)
	# 先発は野手と同スケール (平均差 <= 5)。
	assert_float(absf(starter_mean - fielder_mean)).is_less_equal(5.0)
	# 中継は先発と同スケール (平均差 <= 5)。
	assert_float(absf(reliever_mean - starter_mean)).is_less_equal(5.0)
	# 投手全体と野手の平均評価は同一尺度。1点差でも境界層の編成判断が投手優遇へ偏るため厳しく監視する。
	assert_float(absf(pitcher_mean - fielder_mean)).is_less_equal(0.75)
	# 先発の上位帯が野手を大きく上回らない。
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


# 守備実績 (シーズン累積 OAA) が配置スコアへ反映され、崩壊水準では collapse 判定になる。
func test_starter_assignment_score_uses_realized_oaa() -> void:
	var apt_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS
	var mk: Callable = func(pid: int) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = 6
		r.position_aptitudes_snapshot = {str(apt_keys[6]): 100}
		return r
	var neutral: PSPlayerSeasonRecord = mk.call(1)
	var bad: PSPlayerSeasonRecord = mk.call(2)
	bad.advanced_stats.fielding_chances_by_position = {"6": 300}
	bad.advanced_stats.oaa_by_position = {"6": -15.0}
	var good: PSPlayerSeasonRecord = mk.call(3)
	good.advanced_stats.fielding_chances_by_position = {"6": 300}
	good.advanced_stats.oaa_by_position = {"6": 12.0}

	var neutral_score: int = PSPlayerValueEvaluator.starter_assignment_score(neutral, 6)
	assert_int(PSPlayerValueEvaluator.starter_assignment_score(bad, 6)).is_less(neutral_score)
	assert_int(PSPlayerValueEvaluator.starter_assignment_score(good, 6)).is_greater(neutral_score)
	# -15 OAA / 300 chances → rating -10 → 守備負荷の高い位置では崩壊扱い。
	assert_bool(PSPlayerValueEvaluator.fielding_collapsed_at_position(bad, 6)).is_true()
	assert_bool(PSPlayerValueEvaluator.fielding_collapsed_at_position(good, 6)).is_false()
	# 左翼 (低負荷) は崩壊対象外。
	assert_bool(PSPlayerValueEvaluator.fielding_collapsed_at_position(bad, 7)).is_false()
	# サンプル不足 (40 chances 未満) は無視。
	var tiny: PSPlayerSeasonRecord = mk.call(4)
	tiny.advanced_stats.fielding_chances_by_position = {"6": 20}
	tiny.advanced_stats.oaa_by_position = {"6": -10.0}
	assert_bool(PSPlayerValueEvaluator.fielding_collapsed_at_position(tiny, 6)).is_false()


# AI 管理チーム (usage.ai_generated) では、実績 OAA が崩壊した固定スタメンを外して
# 貪欲補充へ落とす。ユーザー設定 (ai_generated なし) はそのまま尊重する。
func test_ai_alignment_demotes_collapsed_premium_starter() -> void:
	var apt_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS
	var mk: Callable = func(pid: int, pos: int, aptitude: int) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = pos
		r.name = "P%d" % pid
		r.position_aptitudes_snapshot = {str(apt_keys.get(pos, "catcher")): aptitude}
		return r

	var positions: Array = [2, 6, 8, 4, 5, 3, 7, 9]
	var fielders: Array = []
	var template: Dictionary = {}
	var collapsed_ss: PSPlayerSeasonRecord = mk.call(400, 6, 100)
	collapsed_ss.advanced_stats.fielding_chances_by_position = {"6": 300}
	collapsed_ss.advanced_stats.oaa_by_position = {"6": -15.0}
	fielders.append(collapsed_ss)
	template[6] = collapsed_ss.player_id
	var next_id: int = 410
	for pos_row in positions:
		var pos: int = int(pos_row)
		if pos == 6:
			continue
		var rec: PSPlayerSeasonRecord = mk.call(next_id, pos, 100)
		fielders.append(rec)
		template[pos] = rec.player_id
		next_id += 1
	var spare_ss: PSPlayerSeasonRecord = mk.call(450, 6, 85)
	fielders.append(spare_ss)

	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.build_default(9998)
	profile.starting_positions = template.duplicate()
	var slot_six: Dictionary = {"starter_id": collapsed_ss.player_id, "sub_id": 0, "sub_start_interval": 0, "backup_ids": []}

	var ai_usage: Dictionary = {"position_slots": {"6": slot_six.duplicate(true)}, "ai_generated": true}
	var ai_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, ai_usage, 1)
	assert_int(_assigned_player_id(ai_slots, 6)).is_equal(spare_ss.player_id)

	var user_usage: Dictionary = {"position_slots": {"6": slot_six.duplicate(true)}}
	var user_slots: Array = PSDefenseAlignmentService.assign_defensive_starters(fielders, profile, user_usage, 1)
	assert_int(_assigned_player_id(user_slots, 6)).is_equal(collapsed_ss.player_id)


func _assigned_player_id(slots: Array, position: int) -> int:
	for slot_row in slots:
		var slot: Dictionary = slot_row as Dictionary
		if int(slot.get("position", 0)) == position:
			var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
			return 0 if record == null else record.player_id
	return 0


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


func _pitch_count_rate(counts: Dictionary, total: int, min_pitches: int, max_pitches: int) -> float:
	var count: int = 0
	for pitches in range(min_pitches, max_pitches + 1):
		count += int(counts.get(pitches, 0))
	return 0.0 if total <= 0 else float(count) / float(total)


func _max_pitch_count(counts: Dictionary) -> int:
	var best: int = 0
	for key in counts.keys():
		best = maxi(best, int(key))
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


func test_closer_role_is_preferred_in_ninth_four_run_lead() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(121, "Closer", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(122, "Middle", 0.8)
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
	var four_run_lead: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 6,
		"home_score": 2,
	}

	var lead_pick: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, four_run_lead, false)

	assert_object(lead_pick).is_not_null()
	assert_int(lead_pick.player_id).is_equal(closer.player_id)


# 4点差リードはクローザーが前日(直前のチーム試合)に登板していたら回避し、ミドルへ回す。
func test_closer_avoids_four_run_lead_when_pitched_previous_game() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(141, "Closer", 0.5)
	var middle: PSPlayerSeasonRecord = _pitcher(142, "Middle", 0.0)
	# 直前のチーム試合 (team_games_played_before=10) に登板済み = 今登板すると連投。
	closer.last_pitched_team_game = 10
	closer.consecutive_appearances = 1
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
	var four_run_lead: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 6,
		"home_score": 2,
	}

	# 連投回避でクローザーは使わず、ミドルが登板する (能力で勝っていても回避が優先)。
	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, four_run_lead, false)
	assert_int(picked.player_id).is_equal(middle.player_id)


# 5点差以上はどの回でもセット/クローザーを温存し、ミドルリリーフを登板させる。
func test_middle_reliever_covers_blowout_lead() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(161, "Closer", 0.9)
	var setup_pitcher: PSPlayerSeasonRecord = _pitcher(162, "Setup", 0.9)
	var middle: PSPlayerSeasonRecord = _pitcher(163, "Middle", 0.0)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [closer, setup_pitcher, middle],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			setup_pitcher.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var blowout_lead: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 7,
		"home_score": 2,
	}

	# 9回でも7回でも5点差ならミドル (セット/クローザーは能力で勝っていても温存)。
	var pick9: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, blowout_lead, false)
	var pick7: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 7, blowout_lead, false)
	assert_int(pick9.player_id).is_equal(middle.player_id)
	assert_int(pick7.player_id).is_equal(middle.player_id)


# 9回同点・ビジター: クローザーは12回(最終回)まで温存し、9〜11回は残りリリーフを
# 評価の高い順で最終回直前に最良が来るよう逆算配置する。
func test_closer_held_until_twelfth_in_tie_for_visitor() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(601, "Closer", 0.5)
	var best: PSPlayerSeasonRecord = _pitcher(602, "BestBridge", 0.9)
	var mid: PSPlayerSeasonRecord = _pitcher(603, "MidBridge", 0.4)
	var low: PSPlayerSeasonRecord = _pitcher(604, "LowBridge", 0.1)
	var setup: Dictionary = {
		"team_id": 1,  # away = ビジター
		"relievers": [closer, best, mid, low],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			best.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
			mid.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
			low.player_id: PSRotationPlanner.RELIEF_ROLE_LONG,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var tied: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 3,
		"home_score": 3,
	}

	# 逆算配置: 9回=3番手(最弱), 10回=2番手, 11回=最良, 12回=クローザー。
	var pick9: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, tied, false)
	var pick10: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 10, tied, false)
	var pick11: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 11, tied, false)
	var pick12: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 12, tied, false)

	assert_int(pick9.player_id).is_equal(low.player_id)
	assert_int(pick10.player_id).is_equal(mid.player_id)
	assert_int(pick11.player_id).is_equal(best.player_id)
	assert_int(pick12.player_id).is_equal(closer.player_id)


# 9回同点・ホーム: クローザーを9回に投入し、以降は能力の高いリリーフ順。
func test_closer_used_in_ninth_tie_for_home() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(611, "Closer", 0.3)
	var middle: PSPlayerSeasonRecord = _pitcher(612, "Middle", 0.9)
	var setup: Dictionary = {
		"team_id": 2,  # home
		"relievers": [closer, middle],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var tied: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 3,
		"home_score": 3,
	}

	# 9回はクローザー (能力で劣ってもホーム同点は9回投入)。
	var pick9: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, tied, false)
	assert_int(pick9.player_id).is_equal(closer.player_id)

	# クローザーを使い切った10回は能力の高いリリーフを投入。
	setup["used_pitcher_ids"] = {closer.player_id: true}
	var pick10: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 10, tied, false)
	assert_int(pick10.player_id).is_equal(middle.player_id)


# セット/クローザーはビハインド時には登板させない。能力で勝ってもミドルへ回す。
func test_setup_and_closer_excluded_when_behind() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(621, "Closer", 0.8)
	var setup_pitcher: PSPlayerSeasonRecord = _pitcher(622, "Setup", 0.8)
	var middle: PSPlayerSeasonRecord = _pitcher(623, "Middle", 0.0)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [closer, setup_pitcher, middle],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			setup_pitcher.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var behind: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 2,
		"home_score": 4,
	}

	var pick8: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 8, behind, false)
	var pick9: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, behind, false)

	assert_int(pick8.player_id).is_equal(middle.player_id)
	assert_int(pick9.player_id).is_equal(middle.player_id)


# セットは7回以降・クローザーは9回以降に限定する。担当回より前はミドルへ回す。
func test_setup_before_seventh_and_closer_before_ninth_are_excluded() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(631, "Closer", 0.9)
	var setup_pitcher: PSPlayerSeasonRecord = _pitcher(632, "Setup", 0.9)
	var middle: PSPlayerSeasonRecord = _pitcher(633, "Middle", 0.0)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [closer, setup_pitcher, middle],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			setup_pitcher.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var lead: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 4,
		"home_score": 2,
	}

	# 6回リード: セット(7回以降)も抑え(9回以降)も使わずミドルへ。
	var pick6: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 6, lead, false)
	assert_int(pick6.player_id).is_equal(middle.player_id)

	# 8回リード: 抑えはまだ使わず、セットを投入。
	var pick8: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 8, lead, false)
	assert_int(pick8.player_id).is_equal(setup_pitcher.player_id)


func test_closer_role_can_take_third_straight_in_save_spot() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(131, "Closer", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(132, "Middle", 0.9)
	closer.last_pitched_team_game = 20
	closer.consecutive_appearances = 2
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [middle, closer],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 25,
		"team_games_played_before": 20,
	}
	var save_spot: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 4,
		"home_score": 2,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, save_spot, false)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(closer.player_id)


func test_setup_role_is_preferred_for_late_lead_and_tie() -> void:
	var setup_pitcher: PSPlayerSeasonRecord = _pitcher(151, "Setup", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(152, "Middle", 0.7)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [middle, setup_pitcher],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			setup_pitcher.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}

	var leading: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 6,
		"home_score": 2,
	}
	var tied: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 2,
		"home_score": 2,
	}

	var lead_pick: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 8, leading, false)
	var tie_pick: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 8, tied, false)

	assert_object(lead_pick).is_not_null()
	assert_int(lead_pick.player_id).is_equal(setup_pitcher.player_id)
	assert_object(tie_pick).is_not_null()
	assert_int(tie_pick.player_id).is_equal(setup_pitcher.player_id)


# クローザー等の役割割り当ては疲労に依存せず固定する (ユーザ指摘の「日替わり抑え」防止)。
# エース救援を疲労させても、その投手が引き続きクローザーに割り当てられること。
func test_relief_role_assignment_is_stable_under_fatigue() -> void:
	var ace: PSPlayerSeasonRecord = _pitcher(701, "AceReliever", 1.2)
	var pool: Array = [ace]
	var z_values: Array = [0.9, 0.6, 0.3, 0.0, -0.3]
	for i in range(z_values.size()):
		pool.append(_pitcher(702 + i, "Relief %d" % i, float(z_values[i])))

	# 全員フレッシュ: 能力最上位の ace がクローザー。
	var fresh_roles: Dictionary = PSRotationPlanner.relief_role_by_pitcher(
		{}, PSRotationPlanner.select_relievers_for_innings(pool, [], 0, {})
	)
	assert_str(str(fresh_roles.get(ace.player_id, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_CLOSER)

	# ace を高疲労にしても、疲労を含まない能力で並べるのでクローザーは ace のまま。
	ace.fatigue = 150
	var tired_roles: Dictionary = PSRotationPlanner.relief_role_by_pitcher(
		{}, PSRotationPlanner.select_relievers_for_innings(pool, [], 0, {})
	)
	assert_str(str(tired_roles.get(ace.player_id, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_CLOSER)


# 球数モデルのカテゴリ別平均球数とファールが現実的なレンジに収まること。
# THT/FanGraphs 1988-2013 MLB 分布ベースで、BIPは早打ち寄り、K/BBは必要球数以降に厚くなる。
func test_pitch_model_per_category_counts_are_realistic() -> void:
	var bip_pitches: float = 0.0
	var bip_fouls: float = 0.0
	var k_pitches: float = 0.0
	var bb_pitches: float = 0.0
	var n: int = 4000
	for i in range(n):
		var precomp: Dictionary = {
			"event_index": i * 7 + 3,
			"batter_id": (i * 131) % 9000 + 1,
			"pitcher_id": (i * 977) % 9000 + 1,
			# 平均的な対戦の raw z (旧中立点定数と同じ実測値。中立点機構は廃止済みで
			# raw z をそのまま使うため、ここでは「平均的選手」を表す具体値を直接渡す)。
			"batter_z": {
				"Bat_BBCreate": 0.8291,
				"Bat_Aggression": 0.2957,
			},
			"pitcher_z": {"Pit_Efficiency": 1.0177},
			"catcher_z": {"C_GameCall": 2.4021},
			"fatigue_factor": 1.0,
		}
		var bip: Dictionary = PSPitchAggregateSimulator.simulate("bip", precomp)
		bip_pitches += float(int(bip.get("pitches", 0)))
		bip_fouls += float(int(bip.get("fouls", 0)))
		k_pitches += float(int(PSPitchAggregateSimulator.simulate("k", precomp).get("pitches", 0)))
		bb_pitches += float(int(PSPitchAggregateSimulator.simulate("bb", precomp).get("pitches", 0)))
	var bip_avg: float = bip_pitches / float(n)
	var k_avg: float = k_pitches / float(n)
	var bb_avg: float = bb_pitches / float(n)
	var bip_foul_avg: float = bip_fouls / float(n)

	assert_float(bip_avg).is_greater_equal(2.8)
	assert_float(bip_avg).is_less_equal(3.7)
	assert_float(k_avg).is_greater_equal(4.6)
	assert_float(k_avg).is_less_equal(6.0)
	assert_float(bb_avg).is_greater_equal(5.2)
	assert_float(bb_avg).is_less_equal(6.6)
	assert_float(bip_foul_avg).is_greater_equal(0.6)
	assert_float(bip_foul_avg).is_less_equal(1.6)


func test_pitch_model_distribution_matches_tht_shape() -> void:
	var counts: Dictionary = {}
	var total: int = 10000
	for i in range(total):
		var category: String = "bip"
		if i >= 6940 and i < 9120:
			category = "k"
		elif i >= 9120 and i < 9980:
			category = "bb"
		elif i >= 9980:
			category = "hbp"
		var precomp: Dictionary = {
			"event_index": i * 11 + 5,
			"batter_id": (i * 131) % 9000 + 1,
			"pitcher_id": (i * 977) % 9000 + 1,
			# 分布ガードは固定リファレンス中立値の平均的な対戦で見る。
			# 平均的な対戦の raw z (旧中立点定数と同じ実測値。中立点機構は廃止済みで
			# raw z をそのまま使うため、ここでは「平均的選手」を表す具体値を直接渡す)。
			"batter_z": {
				"Bat_BBCreate": 0.8291,
				"Bat_Aggression": 0.2957,
			},
			"pitcher_z": {"Pit_Efficiency": 1.0177},
			"catcher_z": {"C_GameCall": 2.4021},
			"fatigue_factor": 1.0,
		}
		var pitches: int = int(PSPitchAggregateSimulator.simulate(category, precomp).get("pitches", 0))
		counts[pitches] = int(counts.get(pitches, 0)) + 1

	var one_pitch_rate: float = _pitch_count_rate(counts, total, 1, 1)
	var two_pitch_rate: float = _pitch_count_rate(counts, total, 2, 2)
	var three_to_five_rate: float = _pitch_count_rate(counts, total, 3, 5)
	var eight_plus_rate: float = _pitch_count_rate(counts, total, 8, PSPitchAggregateSimulator.MAX_PITCH_COUNT)
	var ten_plus_rate: float = _pitch_count_rate(counts, total, 10, PSPitchAggregateSimulator.MAX_PITCH_COUNT)

	assert_float(one_pitch_rate).is_greater_equal(0.09)
	assert_float(one_pitch_rate).is_less_equal(0.14)
	assert_float(two_pitch_rate).is_greater_equal(0.14)
	assert_float(two_pitch_rate).is_less_equal(0.21)
	assert_float(three_to_five_rate).is_greater_equal(0.48)
	assert_float(three_to_five_rate).is_less_equal(0.56)
	assert_float(eight_plus_rate).is_greater_equal(0.020)
	assert_float(eight_plus_rate).is_less_equal(0.040)
	assert_float(ten_plus_rate).is_greater_equal(0.002)
	assert_float(ten_plus_rate).is_less_equal(0.008)
	assert_int(_max_pitch_count(counts)).is_less_equal(20)


# 中立点機構は撤去済み。pool_snapshot は balance_report 向けの observational な計測のみを
# 提供するスモークテスト(件数が妥当な範囲か・全キーが浮動小数として返るかだけを確認する)。
func test_ability_reference_snapshot_matches_initial_pool() -> void:
	GameDb.load_initial_data()
	var snapshot: Dictionary = PSAbilityReference.pool_snapshot(GameDb.players)
	var counts: Dictionary = snapshot.get("counts", {}) as Dictionary
	var observed: Dictionary = snapshot.get("observed", {}) as Dictionary

	assert_int(int(counts.get("batters", 0))).is_greater(400)
	assert_int(int(counts.get("pitchers", 0))).is_greater(400)
	assert_int(int(counts.get("catchers", 0))).is_greater(60)
	assert_bool(observed.is_empty()).is_false()
	for key_value in observed.keys():
		assert_bool(typeof(observed.get(key_value)) == TYPE_FLOAT or typeof(observed.get(key_value)) == TYPE_INT).is_true()


func test_pa_precomp_limits_pitcher_and_batter_tails() -> void:
	var pitcher: PSPlayerSeasonRecord = _pitcher(802, "Tail Pitcher", 4.0)
	var batter: PSPlayerSeasonRecord = _fielder(812, "Tail Batter", 4.0)
	var precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(batter, pitcher, {}, {}, false)
	var pitcher_z: Dictionary = precomp.get("pitcher_z", {}) as Dictionary
	var batter_z: Dictionary = precomp.get("batter_z", {}) as Dictionary
	var pitcher_output_span: float = ModManager.rule_float("simulation.plate_appearance.pitcher_output_tail_span", PSPlateAppearanceCoordinator.PITCHER_OUTPUT_TAIL_SPAN)
	var pitcher_stuff_span: float = ModManager.rule_float("simulation.plate_appearance.pitcher_stuff_tail_span", PSPlateAppearanceCoordinator.PITCHER_STUFF_TAIL_SPAN)
	var batter_avoid_k_span: float = ModManager.rule_float("simulation.plate_appearance.batter_avoid_k_tail_span", PSPlateAppearanceCoordinator.BATTER_AVOID_K_TAIL_SPAN)
	var batter_hr_span: float = ModManager.rule_float("simulation.plate_appearance.batter_hr_tail_span", PSPlateAppearanceCoordinator.BATTER_HR_TAIL_SPAN)
	var batter_contact_span: float = ModManager.rule_float("simulation.plate_appearance.batter_contact_tail_span", PSPlateAppearanceCoordinator.BATTER_CONTACT_TAIL_SPAN)
	var batter_gap_span: float = ModManager.rule_float("simulation.plate_appearance.batter_gap_tail_span", PSPlateAppearanceCoordinator.BATTER_GAP_TAIL_SPAN)
	var batter_patience_span: float = ModManager.rule_float("simulation.plate_appearance.batter_patience_tail_span", PSPlateAppearanceCoordinator.BATTER_PATIENCE_TAIL_SPAN)

	assert_float(float(pitcher_z.get("Pit_KCreate", 0.0))).is_less(4.0)
	assert_float(float(pitcher_z.get("Pit_KCreate", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.PITCHER_OUTPUT_TAIL_PIVOT + pitcher_output_span + 0.01)
	assert_float(float(pitcher_z.get("Pit_BBPrevent", 0.0))).is_less(4.0)
	assert_float(float(precomp.get("pitcher_stuff_z", 0.0))).is_less(6.0)
	assert_float(float(precomp.get("pitcher_stuff_z", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.PITCHER_STUFF_TAIL_PIVOT + pitcher_stuff_span + 0.01)
	assert_float(float(batter_z.get("Bat_KAvoid", 0.0))).is_less(4.0)
	assert_float(float(batter_z.get("Bat_KAvoid", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.BATTER_AVOID_K_TAIL_PIVOT + batter_avoid_k_span + 0.01)
	assert_float(float(batter_z.get("Bat_Barrel", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.BATTER_CONTACT_TAIL_PIVOT + batter_contact_span + 0.01)
	assert_float(float(batter_z.get("Bat_Impact", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.BATTER_GAP_TAIL_PIVOT + batter_gap_span + 0.01)
	assert_float(float(batter_z.get("Bat_BBCreate", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.BATTER_PATIENCE_TAIL_PIVOT + batter_patience_span + 0.01)
	assert_float(float(precomp.get("batter_hr_z", 0.0))).is_less(6.0)
	assert_float(float(precomp.get("batter_hr_z", 0.0))).is_less_equal(
		PSPlateAppearanceCoordinator.BATTER_HR_TAIL_PIVOT + batter_hr_span + 0.01)

	var average_precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(_fielder(813, "Average Batter", 0.0), _pitcher(803, "Average Pitcher", 0.0), {}, {}, false)
	var average_pitcher_z: Dictionary = average_precomp.get("pitcher_z", {}) as Dictionary
	var average_batter_z: Dictionary = average_precomp.get("batter_z", {}) as Dictionary
	assert_float(float(average_pitcher_z.get("Pit_KCreate", 0.0))).is_equal(0.0)
	assert_float(float(average_batter_z.get("Bat_KAvoid", 0.0))).is_equal(0.0)
	assert_float(float(average_precomp.get("batter_hr_z", 0.0))).is_equal(0.0)
	assert_float(float(average_precomp.get("pitcher_stuff_z", 0.0))).is_equal(0.0)


func test_pitcher_stuff_contact_quality_ev_effect_is_saturated() -> void:
	var old_seed: int = Rng.current_seed
	var old_state: int = Rng.generator.state
	var average_ev: float = _contact_quality_average_ev(PSContactQualityModel.PIT_STUFF_CURVE_CENTER)
	var ace_ev: float = _contact_quality_average_ev(3.0)
	var diff: float = average_ev - ace_ev
	Rng.current_seed = old_seed
	Rng.generator.seed = old_seed
	Rng.generator.state = old_state

	print("STUFFEV avg=%.2f ace=%.2f diff=%.2f" % [average_ev, ace_ev, diff])
	# 球威によるEV低下は小幅に飽和し、極端な投手でも過大にならない。
	assert_float(diff).is_greater_equal(0.1)
	assert_float(diff).is_less_equal(1.8)


func test_tto_penalty_flows_into_pa_weights() -> void:
	var starter: PSPlayerSeasonRecord = _pitcher(803, "TTO Starter", 0.4)
	starter.role = "starter"
	var fresh_usage: Dictionary = PSPitcherUsageModel.create_outing(starter, PSPitcherUsageModel.ROLE_STARTER)
	var tto_usage: Dictionary = PSPitcherUsageModel.create_outing(starter, PSPitcherUsageModel.ROLE_STARTER)
	tto_usage["batters_faced"] = 18
	var fresh_context: Dictionary = PSPitcherUsageModel.plate_context(starter, fresh_usage)
	var tto_context: Dictionary = PSPitcherUsageModel.plate_context(starter, tto_usage)
	assert_int(int(tto_context.get("pitcher_tto_penalty", 0))).is_greater(0)

	var fresh_precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(null, starter, {}, fresh_context, false)
	var tto_precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(null, starter, {}, tto_context, false)
	assert_float(float(tto_precomp.get("tto_round_weight", 0.0))).is_greater(0.0)

	var fresh_weights: Dictionary = PSPaProbabilityCalculator.build_weights(fresh_precomp)
	var tto_weights: Dictionary = PSPaProbabilityCalculator.build_weights(tto_precomp)
	assert_float(float(tto_weights.get(PSPaProbabilityCalculator.OUTCOME_STRIKEOUT, 0.0))).is_less(
		float(fresh_weights.get(PSPaProbabilityCalculator.OUTCOME_STRIKEOUT, 0.0)))
	assert_float(float(tto_weights.get(PSPaProbabilityCalculator.OUTCOME_WALK, 0.0))).is_greater(
		float(fresh_weights.get(PSPaProbabilityCalculator.OUTCOME_WALK, 0.0)))


func test_short_reliever_gets_initial_output_bonus() -> void:
	var pitcher: PSPlayerSeasonRecord = _pitcher(804, "Max Effort", 0.0)
	var direct_z: Dictionary = {
		"Pit_KCreate": 0.0,
		"Pit_BBPrevent": 0.0,
		"Pit_EdgeRate": 0.0,
		"Pit_ImpactLimit": 0.0,
		"Pit_BarrelDeny": 0.0,
	}
	PSPlateAppearanceCoordinator._apply_relief_output_bonus(
		direct_z, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 0.0)
	assert_float(float(direct_z.get("Pit_KCreate", 0.0))).is_greater(0.04)
	assert_float(float(direct_z.get("Pit_BBPrevent", 0.0))).is_greater(0.015)
	assert_float(float(direct_z.get("Pit_EdgeRate", 0.0))).is_greater(0.02)

	var starter_context: Dictionary = PSPitcherUsageModel.plate_context(
		pitcher,
		PSPitcherUsageModel.create_outing(pitcher, PSPitcherUsageModel.ROLE_STARTER)
	)
	var relief_context: Dictionary = PSPitcherUsageModel.plate_context(
		pitcher,
		PSPitcherUsageModel.create_outing(pitcher, PSPitcherUsageModel.ROLE_SHORT_RELIEF)
	)
	var starter_precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(null, pitcher, {}, starter_context, false)
	var relief_precomp: Dictionary = PSPlateAppearanceCoordinator._build_precomp(null, pitcher, {}, relief_context, true)
	var starter_z: Dictionary = starter_precomp.get("pitcher_z", {}) as Dictionary
	var relief_z: Dictionary = relief_precomp.get("pitcher_z", {}) as Dictionary

	assert_float(float(relief_z.get("Pit_KCreate", 0.0))).is_greater(
		float(starter_z.get("Pit_KCreate", 0.0)) + 0.005)
	assert_float(float(relief_z.get("Pit_EdgeRate", 0.0))).is_greater(
		float(starter_z.get("Pit_EdgeRate", 0.0)) + 0.005)


func test_pitcher_stamina_affects_starter_fatigue_and_long_relief_usage() -> void:
	var low_stamina: PSPlayerSeasonRecord = _pitcher(805, "Low Stamina", 0.0)
	var high_stamina: PSPlayerSeasonRecord = _pitcher(806, "High Stamina", 0.0)
	low_stamina.z_abilities_snapshot["Pit_Stamina"] = -1.0
	high_stamina.z_abilities_snapshot["Pit_Stamina"] = 2.0

	assert_float(PSFatigueCalculator.start_threshold(high_stamina, false)).is_greater(
		PSFatigueCalculator.start_threshold(low_stamina, false) + 5.0)
	assert_int(PSPitcherUsageModel.starter_stamina_limit_pitches(high_stamina)).is_greater(
		PSPitcherUsageModel.starter_stamina_limit_pitches(low_stamina) + 20)
	assert_float(PSFatigueCalculator.start_threshold(high_stamina, false)).is_less(
		float(PSPitcherUsageModel.starter_stamina_limit_pitches(high_stamina)))
	assert_float(PSFatigueCalculator.factor_for_pitcher(high_stamina, false, 50)).is_greater_equal(0.98)
	assert_float(PSFatigueCalculator.factor_for_pitcher(high_stamina, false, 95)).is_greater(0.70)
	assert_float(PSFatigueCalculator.factor_for_pitcher(high_stamina, false, 115)).is_less(0.45)
	assert_float(PSFatigueCalculator.factor_for_pitcher(high_stamina, false, 130)).is_equal(0.0)
	assert_float(PSFatigueCalculator.start_threshold(high_stamina, true)).is_equal(
		PSFatigueCalculator.start_threshold(low_stamina, true))
	assert_int(PSPitcherUsageModel.short_relief_target_pitches(high_stamina)).is_equal(
		PSPitcherUsageModel.short_relief_target_pitches(low_stamina))
	assert_int(PSPitcherUsageModel.long_relief_target_pitches(high_stamina)).is_greater(
		PSPitcherUsageModel.long_relief_target_pitches(low_stamina))


func _contact_quality_average_ev(pitcher_stuff_z: float) -> float:
	Rng.set_seed_value(24680)
	var total_ev: float = 0.0
	var n: int = 2400
	var pitch_outcome: Dictionary = {
		"pitch_velocity": 145,
		"in_zone": true,
		"location_height": "middle",
		"two_strike_protective": false,
		"protective_out": false,
	}
	for _i in range(n):
		var quality: Dictionary = PSContactQualityModel.generate(null, null, pitch_outcome, {}, {
			"batter_contact_z": PSContactQualityModel.BAT_CONTACT_CURVE_CENTER,
			"batter_gap_z": PSContactQualityModel.BAT_GAP_CURVE_CENTER,
			"batter_hr_z": PSContactQualityModel.BAT_HR_CURVE_CENTER,
			"batter_avoid_k_z": PSContactQualityModel.BAT_AVOID_K_CURVE_CENTER,
			"pitcher_stuff_z": pitcher_stuff_z,
			"batter_fatigue": 0,
			"batter_is_pitcher": false,
			"pitcher_contact_damage": 0.0,
			"pitcher_gb_bias": 0.0,
			"pitcher_hr_bias": 0.0,
		})
		total_ev += float(quality.get("exit_velocity", 0.0))
	return total_ev / float(n)


func test_starter_stamina_window_varies_by_pitcher() -> void:
	var avg: PSPlayerSeasonRecord = _pitcher(801, "Average", 0.0)
	assert_int(PSPitcherUsageModel.starter_fatigue_start_pitches(avg)).is_equal(66)
	assert_int(PSPitcherUsageModel.starter_stamina_limit_pitches(avg)).is_equal(110)

	var low: PSPlayerSeasonRecord = _pitcher(807, "Low Stamina", 0.0)
	low.z_abilities_snapshot["Pit_Stamina"] = -2.2
	low.z_abilities_snapshot["Pit_FatigueResist"] = -1.6
	assert_int(PSPitcherUsageModel.starter_fatigue_start_pitches(low)).is_equal(53)
	assert_int(PSPitcherUsageModel.starter_stamina_limit_pitches(low)).is_equal(88)

	var workhorse: PSPlayerSeasonRecord = _pitcher(808, "Workhorse", 0.0)
	workhorse.z_abilities_snapshot["Pit_Stamina"] = 3.1
	workhorse.z_abilities_snapshot["Pit_FatigueResist"] = 2.0
	assert_int(PSPitcherUsageModel.starter_fatigue_start_pitches(workhorse)).is_equal(83)
	assert_int(PSPitcherUsageModel.starter_stamina_limit_pitches(workhorse)).is_equal(145)
	assert_int(PSPitcherUsageModel.starter_complete_game_pitch_limit(workhorse)).is_equal(145)


func test_starter_complete_game_chase_is_late_low_run_only() -> void:
	var workhorse: PSPlayerSeasonRecord = _pitcher(809, "CG Workhorse", 0.0)
	workhorse.z_abilities_snapshot["Pit_Stamina"] = 3.1
	workhorse.z_abilities_snapshot["Pit_FatigueResist"] = 2.0
	var usage: Dictionary = PSPitcherUsageModel.create_outing(workhorse, PSPitcherUsageModel.ROLE_STARTER)

	usage["pitches"] = 58
	usage["outs"] = 15
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 6, 1)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 6, 2)).is_false()

	usage["pitches"] = 78
	usage["outs"] = 18
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 7, 1)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 7, 2)).is_false()

	usage["pitches"] = 84
	usage["outs"] = 21
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 1)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 2)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 3)).is_false()

	usage["batters_faced"] = 27
	usage["pitches"] = 94
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 1)).is_true()
	usage["batters_faced"] = 0

	usage["pitches"] = 103
	usage["outs"] = 21
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 1)).is_true()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 8, 2)).is_true()

	usage["pitches"] = 92
	usage["outs"] = 24
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 9, 1)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 9, 2)).is_false()

	usage["pitches"] = 114
	usage["outs"] = 24
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 9, 1)).is_true()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(workhorse, usage, 9, 2)).is_true()


# 「2回3失点程度で降板」を避ける: 序盤の数失点では立て直しを待ち、イニング途中交代は
# 炎上が止まらない緊急時のみ。通常の降板判断は回またぎで行う。
func test_starter_not_pulled_on_minor_damage_but_pulled_in_real_blowup() -> void:
	var starter: PSPlayerSeasonRecord = _pitcher(802, "Starter", 0.5)
	var usage: Dictionary = PSPitcherUsageModel.create_outing(starter, PSPitcherUsageModel.ROLE_STARTER)
	usage["pitches"] = 70
	var two_on: Array = [_pitcher(901, "R1", 0.0), _pitcher(902, "R2", 0.0), null]

	# 2回3失点(走者あり): イニング途中では降ろさない。
	assert_bool(PSPitcherUsageModel.should_pull_after_plate_appearance(starter, usage, 2, 1, two_on, 3, 1)).is_false()
	# 5回3失点(走者2人)でもイニング途中では降ろさない(回またぎで判断)。
	assert_bool(PSPitcherUsageModel.should_pull_after_plate_appearance(starter, usage, 5, 1, two_on, 3, 1)).is_false()
	# 6失点が止まらない本物の炎上(走者あり)では即交代。
	assert_bool(PSPitcherUsageModel.should_pull_after_plate_appearance(starter, usage, 5, 1, two_on, 6, 1)).is_true()

	# 回またぎ: 序盤3失点では続投、5失点(4回以降)では交代。
	usage["pitches"] = 38
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(starter, usage, 3, 3)).is_false()
	assert_bool(PSPitcherUsageModel.should_pull_for_next_half(starter, usage, 5, 5)).is_true()


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
	assert_bool(PSBullpenManager.should_prefer_long_relief_for_starter_exit(5)).is_true()
	assert_bool(PSBullpenManager.should_prefer_long_relief_for_starter_exit(6)).is_false()


func test_long_role_is_preferred_for_mop_up() -> void:
	var long_reliever: PSPlayerSeasonRecord = _pitcher(251, "Long", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(252, "Middle", 0.7)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [middle, long_reliever],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			long_reliever.player_id: PSRotationPlanner.RELIEF_ROLE_LONG,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var trailing: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 1,
		"home_score": 6,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 7, trailing, false)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(long_reliever.player_id)


func test_save_and_hold_conditions_use_official_situations() -> void:
	var result: Dictionary = {
		"draw": false,
		"winning_team_id": 1,
		"last_lead_change": {"winning_team_id": 1, "event_index": 5, "losing_pitcher_id": 22},
		"pitcher_outings": [
			_outing(10, 1, PSPitcherUsageModel.ROLE_STARTER, 0, 4, 18, 0, 0, 0, 0),
			_outing(11, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 10, 12, 1, 2, 2, 2, 0),
			_outing(13, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 20, 22, 3, 3, 3, 3, 0),
			_outing(20, 2, PSPitcherUsageModel.ROLE_STARTER, 0, 4, 12, 0, 0, 0, 0),
			_outing(21, 2, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 10, 12, 3, 1, 1, 3, 0),
			_outing(22, 2, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 30, 32, 3, 1, -1, 3, 0),
		],
	}

	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 10, 20)
	var holds: Array = decisions.get("hold_pitcher_ids", []) as Array

	assert_int(int(decisions.get("winning_pitcher_id", 0))).is_equal(10)
	assert_int(int(decisions.get("losing_pitcher_id", 0))).is_equal(22)
	assert_int(int(decisions.get("save_pitcher_id", 0))).is_equal(13)
	assert_array(holds).contains(11)
	assert_array(holds).contains(21)
	assert_array(holds).not_contains(13)
	assert_array(holds).not_contains(22)


func test_save_situation_counts_tying_run_on_deck() -> void:
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 0, 0, 1, 4, 4, 2, 0))).is_true()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 0, 0, 1, 3, 3, 0, 0))).is_false()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 0, 0, 3, 3, 3, 0, 0))).is_true()


# セーブ条件【B】(2者連続HRで追いつかれる点差) のランナー別境界を公式表どおり判定する。
# ランナーなし=2点差/1人=3点差/2人=4点差/満塁=5点差まで。outs<3 で【A】を外し【B】単独を検証。
func test_save_situation_tying_run_table_by_base_runners() -> void:
	var SHORT: String = PSPitcherUsageModel.ROLE_SHORT_RELIEF
	# ランナーなし: 2点差まで可、3点差は不可。
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 2, 2, 0, 0))).is_true()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 3, 3, 0, 0))).is_false()
	# ランナー1人: 3点差まで可、4点差は不可。
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 3, 3, 1, 0))).is_true()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 4, 4, 1, 0))).is_false()
	# 満塁(3人): 5点差まで可、6点差は不可。
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 5, 5, 3, 0))).is_true()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 1, 6, 6, 3, 0))).is_false()
	# 【A】3点以内で1イニング以上は可、4点差(ランナーなし)は不可。【C】3イニング以上は点差不問で可。
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 3, 4, 4, 0, 0))).is_false()
	assert_bool(PSGameDecisions.save_situation_from_outing(_outing(1, 1, SHORT, 0, 0, 9, 10, 10, 0, 0))).is_true()


# ホールド: 同点で登板し無失点降板はホールド (NPB特有)。リード時は自分の残した走者で
# 同点にされたら (exit_lead が 0 以下に更新される) 大前提4によりホールド不成立。
func test_hold_tie_entry_and_inherited_runner_disqualification() -> void:
	var STARTER: String = PSPitcherUsageModel.ROLE_STARTER
	var SHORT: String = PSPitcherUsageModel.ROLE_SHORT_RELIEF
	var result: Dictionary = {
		"draw": false,
		"winning_team_id": 1,
		"last_lead_change": {"winning_team_id": 1, "event_index": 5, "losing_pitcher_id": 99},
		"pitcher_outings": [
			_outing(10, 1, STARTER, 0, 4, 18, 0, 0, 0, 0),
			# 同点で登板し無失点で降板 → ホールド。
			_outing(11, 1, SHORT, 10, 12, 3, 0, 0, 0, 0),
			# +1リードで登板したが残した走者が生還し同点 (exit_lead 0・1失点) → ホールド不成立。
			_outing(12, 1, SHORT, 20, 22, 3, 1, 0, 2, 1),
			# +2リードを守って試合終了 → セーブ。
			_outing(13, 1, SHORT, 30, 32, 3, 2, 2, 0, 0),
			_outing(99, 2, STARTER, 0, 40, 30, 0, 0, 0, 0),
		],
	}

	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 10, 99)
	var holds: Array = decisions.get("hold_pitcher_ids", []) as Array

	assert_int(int(decisions.get("winning_pitcher_id", 0))).is_equal(10)
	assert_int(int(decisions.get("save_pitcher_id", 0))).is_equal(13)
	assert_array(holds).contains(11)
	assert_array(holds).not_contains(12)
	assert_array(holds).not_contains(13)


# サヨナラ勝ち: 最終回の表に登板していたリリーフが勝ち投手 (規則9.17 / NPB特例)。
# 最終回表の投手は outing が試合終了まで延長されるが、start 基準で pitcher of record になること。
func test_walkoff_winning_pitcher_is_top_inning_reliever() -> void:
	var STARTER: String = PSPitcherUsageModel.ROLE_STARTER
	var SHORT: String = PSPitcherUsageModel.ROLE_SHORT_RELIEF
	var result: Dictionary = {
		"draw": false,
		"walkoff": true,
		"winning_team_id": 2,
		"innings": [1, 2, 3, 4, 5, 6, 7, 8, 9],
		"last_lead_change": {"winning_team_id": 2, "event_index": 88, "losing_pitcher_id": 30},
		"pitcher_outings": [
			_outing(20, 2, STARTER, 0, 40, 21, 0, 0, 0, 3),   # ホーム先発 7回で降板
			_outing(21, 2, SHORT, 50, 90, 9, 0, 0, 0, 0),     # ホーム救援 (最終回表まで)、outing は試合終了=90まで延長
			_outing(30, 1, STARTER, 0, 95, 24, 0, -1, 0, 4),  # ビジター先発 完投負け
		],
	}

	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 30, 20)
	assert_int(int(decisions.get("winning_pitcher_id", 0))).is_equal(21)
	assert_int(int(decisions.get("losing_pitcher_id", 0))).is_equal(30)
	assert_int(int(decisions.get("save_pitcher_id", 0))).is_equal(0)


# 先発5回条件 (規則9.17b): 先発が5回未満で降りたら勝ち投手になれず、最も効果的な救援へ勝ちが移る。
func test_winning_pitcher_passes_to_reliever_when_starter_under_five_innings() -> void:
	var STARTER: String = PSPitcherUsageModel.ROLE_STARTER
	var SHORT: String = PSPitcherUsageModel.ROLE_SHORT_RELIEF
	var result: Dictionary = {
		"draw": false,
		"winning_team_id": 2,
		"innings": [1, 2, 3, 4, 5, 6, 7, 8, 9],
		"last_lead_change": {"winning_team_id": 2, "event_index": 20, "losing_pitcher_id": 30},
		"pitcher_outings": [
			_outing(20, 2, STARTER, 0, 25, 12, 1, 1, 0, 2),   # ホーム先発 4回(12アウト)=資格なし
			_outing(21, 2, SHORT, 30, 50, 6, 1, 1, 0, 0),     # 中継ぎ 2回無失点=最効果
			_outing(23, 2, SHORT, 75, 90, 3, 2, 2, 0, 0),     # 抑え 1回
			_outing(30, 1, STARTER, 0, 95, 24, 0, -1, 0, 4),
		],
	}

	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 30, 20)
	# 先発(20)ではなく最も効果的な救援(21)に勝ちがつく。
	assert_int(int(decisions.get("winning_pitcher_id", 0))).is_equal(21)


# QS (規則9.19) は自責点3以下が条件。失点(自責+非自責)で判定すると味方失策等の非自責点で
# 誤って逃す/満たすため、outing の earned_runs を使うこと (2026-07-10 修正)。
# 6回(18アウト)・失点4・自責2 のケースは失点基準なら QS を逃すが、自責基準では成立する。
func test_quality_start_uses_earned_runs_not_total_runs() -> void:
	var starter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	starter.player_id = 10
	var outing: Dictionary = _outing(10, 1, PSPitcherUsageModel.ROLE_STARTER, 0, 18, 18, 0, 0, 0, 4)
	outing["earned_runs"] = 2
	var setup: Dictionary = {
		"starter_pitcher": starter,
		"pitcher": starter,
		"team_id": 1,
	}
	var result: Dictionary = {"pitcher_outings": [outing]}

	PSGameDecisions.finalize_pitcher_stats(setup, result)

	assert_int(starter.pitcher_stats.quality_starts).is_equal(1)


func test_draw_game_can_record_holds_without_win_loss_save() -> void:
	var result: Dictionary = {
		"draw": true,
		"winning_team_id": 0,
		"pitcher_outings": [
			_outing(31, 1, PSPitcherUsageModel.ROLE_STARTER, 0, 4, 18, 0, 0, 0, 0),
			_outing(32, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 10, 12, 3, 0, 0, 0, 0),
			_outing(41, 2, PSPitcherUsageModel.ROLE_STARTER, 0, 4, 18, 0, 0, 0, 0),
		],
	}

	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, 1, 2, 31, 41)

	assert_int(int(decisions.get("winning_pitcher_id", 0))).is_equal(0)
	assert_int(int(decisions.get("losing_pitcher_id", 0))).is_equal(0)
	assert_int(int(decisions.get("save_pitcher_id", 0))).is_equal(0)
	assert_array(decisions.get("hold_pitcher_ids", []) as Array).contains(32)


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
			"long_ids": [],
		},
	}

	var selected: Array = PSRotationPlanner.select_relievers_for_innings(pool, [], 0, saved)
	var ids: Array = []
	for record_value in selected:
		ids.append((record_value as PSPlayerSeasonRecord).player_id)

	assert_array(ids).contains(role_pick.player_id)
	assert_int(int(ids[0])).is_equal(role_pick.player_id)


func test_default_relief_roles_are_assigned_without_saved_usage() -> void:
	var relievers: Array = []
	for i in range(6):
		relievers.append(_pitcher(360 + i, "Relief %d" % i, 0.5))

	var roles: Dictionary = PSRotationPlanner.relief_role_by_pitcher({}, relievers)

	assert_str(str(roles.get(360, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_SETUP)
	assert_str(str(roles.get(361, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_SETUP)
	assert_str(str(roles.get(362, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_CLOSER)
	assert_str(str(roles.get(363, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_MIDDLE)
	assert_str(str(roles.get(364, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_LONG)
	assert_str(str(roles.get(365, ""))).is_equal(PSRotationPlanner.RELIEF_ROLE_LONG)


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


func test_auto_rotation_periodically_skips_sixth_slot_for_rested_ace() -> void:
	var season: PSSeason = PSSeason.new()
	season.current_day = 30
	var pitchers: Array = []
	for i in range(6):
		var starter: PSPlayerSeasonRecord = _pitcher(480 + i, "Starter %d" % i, 1.2 - float(i) * 0.1)
		starter.role = "starter"
		pitchers.append(starter)
	season.set_rotation(1, {
		"pitcher_ids": [480, 481, 482, 483, 484, 485],
		"next_rotation_index": 5,
		"auto_generated": true,
		"last_start_day_by_pitcher": {"480": 23, "481": 24, "482": 25, "483": 26, "484": 27, "485": 22},
	})
	var team_record: PSTeamSeasonRecord = PSTeamSeasonRecord.new()
	team_record.stats.games = 23

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers, team_record)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(480)
	assert_str(str(decision.get("reason", ""))).is_equal("ace_skip")


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


func _outing(
	pitcher_id: int,
	team_id: int,
	role: String,
	start_event: int,
	end_event: int,
	outs: int,
	entry_lead: int,
	exit_lead: int,
	entry_base_runners: int,
	runs: int
) -> Dictionary:
	return {
		"pitcher_id": pitcher_id,
		"team_id": team_id,
		"role": role,
		"start_event_index": start_event,
		"end_event_index": end_event,
		"outs": outs,
		"entry_lead": entry_lead,
		"exit_lead": exit_lead,
		"entry_base_runners": entry_base_runners,
		"inherited_runners": entry_base_runners,
		"runs": runs,
	}


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


# 投手へチャージされた失点/自責の合計は、実際の試合得点合計と一致すること。
# 回帰: state_already_applied の生還イベント(安打進塁プラン・ゴロ進塁・犠飛等)が
# run_charges_for_runner_events で再チャージされ、投手RAだけ約2割過大になっていた。
func test_pitcher_run_charges_match_actual_scores() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	Rng.set_seed_value(20260703)
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	var total_score: int = 0
	for _index in range(12):
		var simulation: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
		assert_bool(bool(simulation.get("ok", false))).is_true()
		var result: Dictionary = simulation.get("result", {}) as Dictionary
		total_score += int(result.get("away_score", 0)) + int(result.get("home_score", 0))

	var runs_allowed_total: int = 0
	var earned_runs_total: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null:
				continue
			runs_allowed_total += record.pitcher_stats.runs_allowed
			earned_runs_total += record.pitcher_stats.earned_runs

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	assert_int(total_score).is_greater(0)
	assert_int(runs_allowed_total).is_equal(total_score)
	assert_int(earned_runs_total).is_less_equal(runs_allowed_total)


# 無死一・三塁の併殺: 一塁走者は封殺、三塁走者は生還する(打点は付かない: 規則9.04)。
func test_double_play_scores_third_runner_with_no_rbi_when_no_outs() -> void:
	var batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	batter.player_id = 501
	var pitcher: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	pitcher.player_id = 601
	var runner_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_first.player_id = 701
	var runner_third: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_third.player_id = 703

	var bases: Array = [runner_first, null, runner_third]
	var outcome: Dictionary = {"category": "double_play", "result": "double_play_shortstop", "bases": 0}
	var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, pitcher, bases, 0, outcome)

	assert_int(int(applied.get("outs", 0))).is_equal(2)
	assert_int(int(applied.get("runs", 0))).is_equal(1)
	assert_int(runner_third.batter_stats.runs).is_equal(1)
	assert_int(batter.batter_stats.runs_batted_in).is_equal(0)
	assert_int(batter.batter_stats.double_plays).is_equal(1)
	assert_object(bases[0]).is_null()
	assert_object(bases[1]).is_null()
	assert_object(bases[2]).is_null()


# 無死一・二塁の併殺: 一塁走者は封殺、二塁走者はプレー間に三塁へ進む(得点はまだ無い)。
func test_double_play_advances_second_runner_to_third_when_no_outs() -> void:
	var batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	batter.player_id = 502
	var pitcher: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	pitcher.player_id = 602
	var runner_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_first.player_id = 711
	var runner_second: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_second.player_id = 712

	var bases: Array = [runner_first, runner_second, null]
	var outcome: Dictionary = {"category": "double_play", "result": "double_play_shortstop", "bases": 0}
	var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, pitcher, bases, 0, outcome)

	assert_int(int(applied.get("outs", 0))).is_equal(2)
	assert_int(int(applied.get("runs", 0))).is_equal(0)
	assert_object(bases[2]).is_equal(runner_second)
	assert_object(bases[0]).is_null()
	assert_object(bases[1]).is_null()


# 1死一・三塁の併殺: 併殺の第3アウトが打者走者の一塁封殺相当のため、どの走者も生還しない。
func test_double_play_with_one_out_ends_inning_without_run() -> void:
	var batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	batter.player_id = 503
	var pitcher: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	pitcher.player_id = 603
	var runner_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_first.player_id = 721
	var runner_third: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_third.player_id = 723

	var bases: Array = [runner_first, null, runner_third]
	var outcome: Dictionary = {"category": "double_play", "result": "double_play_shortstop", "bases": 0}
	var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, pitcher, bases, 1, outcome)

	assert_int(int(applied.get("outs", 0))).is_equal(2)
	assert_int(int(applied.get("runs", 0))).is_equal(0)
	assert_int(runner_third.batter_stats.runs).is_equal(0)
	assert_object(bases[2]).is_equal(runner_third)


# 無死満塁で二塁封殺を選ぶフォースアウト: 三塁走者は後方フォースのため生還し(打点あり)、
# 二塁走者は三塁へ進む。
func test_fielders_choice_force_at_second_scores_third_on_bases_loaded() -> void:
	var runner_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_first.player_id = 731
	var runner_second: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_second.player_id = 732
	var runner_third: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_third.player_id = 733

	var bases: Array = [runner_first, runner_second, runner_third]
	var plan: Array = PSPlayResolver._fielders_choice_advancements(bases, 1, 2)
	assert_int(plan.size()).is_equal(3)

	var by_from_base: Dictionary = {}
	for advancement_value in plan:
		var advancement: Dictionary = advancement_value as Dictionary
		by_from_base[int(advancement.get("from_base", 0))] = advancement

	var third_plan: Dictionary = by_from_base[3] as Dictionary
	assert_int(int(third_plan.get("to_base", 0))).is_equal(4)
	assert_bool(bool(third_plan.get("is_out", false))).is_false()

	var second_plan: Dictionary = by_from_base[2] as Dictionary
	assert_int(int(second_plan.get("to_base", 0))).is_equal(3)
	assert_bool(bool(second_plan.get("is_out", false))).is_false()

	var first_plan: Dictionary = by_from_base[1] as Dictionary
	assert_bool(bool(first_plan.get("is_out", false))).is_true()
	assert_int(int(first_plan.get("to_base", 0))).is_equal(2)

	var batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	batter.player_id = 504
	var pitcher: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	pitcher.player_id = 604
	var outcome: Dictionary = {
		"category": "fielders_choice",
		"result": "ground_fielders_choice_shortstop_to_second",
		"bases": 1,
		"force_out_from_base": 1,
		"force_out_to_base": 2,
		"runner_advancements": plan,
	}
	var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, pitcher, bases, 0, outcome)

	assert_int(int(applied.get("runs", 0))).is_equal(1)
	assert_int(batter.batter_stats.runs_batted_in).is_equal(1)
	assert_object(bases[0]).is_equal(batter)
	assert_object(bases[2]).is_equal(runner_second)
	assert_object(bases[1]).is_null()


# 無死一・三塁(二塁空)で二塁封殺を選ぶフォースアウト: 三塁走者は非フォースのため動かない。
# 同じ force(1,2) でも塁が満塁なら base_state_resolver のフォールバック計画で三塁走者は生還する。
func test_fielders_choice_force_at_second_holds_unforced_third_runner() -> void:
	var runner_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_first.player_id = 741
	var runner_third: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_third.player_id = 743

	var bases: Array = [runner_first, null, runner_third]
	var plan: Array = PSPlayResolver._fielders_choice_advancements(bases, 1, 2)
	var third_plan: Dictionary = _advancement_from_base(plan, 3)
	assert_bool(third_plan.is_empty()).is_false()
	assert_int(int(third_plan.get("to_base", 0))).is_equal(3)
	assert_bool(bool(third_plan.get("is_out", false))).is_false()

	var loaded_first: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	loaded_first.player_id = 751
	var loaded_second: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	loaded_second.player_id = 752
	var loaded_third: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	loaded_third.player_id = 753
	var loaded_bases: Array = [loaded_first, loaded_second, loaded_third]
	var fallback_plan: Array = PSBaseStateResolver._default_fielders_choice_advancements(loaded_bases, 1, 2)
	var fallback_third_plan: Dictionary = _advancement_from_base(fallback_plan, 3)
	assert_bool(fallback_third_plan.is_empty()).is_false()
	assert_int(int(fallback_third_plan.get("to_base", 0))).is_equal(4)


func _advancement_from_base(plan: Array, from_base: int) -> Dictionary:
	for advancement_value in plan:
		var advancement: Dictionary = advancement_value as Dictionary
		if int(advancement.get("from_base", 0)) == from_base:
			return advancement
	return {}


func _catcher(player_id: int, player_name: String, z: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.name = player_name
	record.position = 2
	record.role = "fielder"
	record.age = 27
	record.fatigue = 0
	record.injury_days = 0
	record.z_abilities_snapshot = {
		"C_Throw": z,
		"C_Blocking": z,
		"C_FieldSecure": z,
		"C_GameCall": z,
	}
	return record


# 盗塁企図は投球前フェーズで計画される(pre_plate_runner_plan)。大半は途中決行として即座に
# events 側で解決され(phase=="before_pitch")、旧仕様の "caught_stealing_throwing_error"
# (刺殺→失策セーフ変換)は出現しないこと、成功盗塁の一部が捕手送球エラーで進塁先++1
# (記録は盗塁+E2)になることを確認する。
func test_pre_plate_steal_events_resolve_without_strikeout() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9001, "Speedster", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9002, "Avg Batter", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9003, "Avg Pitcher", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9004, "Avg Catcher", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases: Array = [runner, null, null]

	var steal_events: Array = []
	for i in range(400):
		var plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(i, batter, pitcher, defense, bases, 0, {})
		var events: Array = plan.get("events", []) as Array
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if bool(event.get("is_steal_attempt", false)):
				steal_events.append(event)

	assert_int(steal_events.size()).is_greater(0)
	for event_value in steal_events:
		var event: Dictionary = event_value as Dictionary
		var result: String = str(event.get("result", ""))
		assert_bool(result == "stolen_base" or result == "caught_stealing").is_true()
		assert_str(str(event.get("phase", ""))).is_equal("before_pitch")
		if bool(event.get("is_fielding_error", false)):
			assert_bool(bool(event.get("is_stolen_base", false))).is_true()
			assert_int(int(event.get("to_base", 0))).is_equal(3)
			assert_int(int(event.get("error_position", 0))).is_equal(2)


# context に deferred_steal_intents が無ければ、三振打席で runner_events_for_play が盗塁イベントを
# 解決することはない(盗塁は pre_plate_runner_plan で管理され、三振打席では繰延べ企図のみが
# 解決対象になる)。WP/PB は別枠なので出てもよい。
func test_strikeout_pa_no_longer_resolves_steals() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9011, "Speedster2", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9012, "Avg Batter2", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9013, "Avg Pitcher2", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9014, "Avg Catcher2", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases: Array = [runner, null, null]
	var outcome: Dictionary = {"category": "strikeout", "result": "strikeout", "bases": 0}

	for i in range(200):
		var events: Array = PSRunnerActionModel.runner_events_for_play(i, batter, pitcher, defense, bases, bases, 0, 1, outcome, {})
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			assert_bool(bool(event.get("is_steal_attempt", false))).is_false()


# 捕手肩(steal_control)が高いほど盗塁成功率(SB/(SB+CS))が下がること。
func test_steal_success_rate_responds_to_catcher_arm() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9021, "Speedster3", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9022, "Avg Batter3", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9023, "Avg Pitcher3", 0.0)
	var strong_catcher: PSPlayerSeasonRecord = _catcher(9024, "Strong Arm", 4.0)
	var weak_catcher: PSPlayerSeasonRecord = _catcher(9025, "Weak Arm", -2.0)
	var strong_defense: Dictionary = {"fielders": [{"position": 2, "record": strong_catcher}]}
	var weak_defense: Dictionary = {"fielders": [{"position": 2, "record": weak_catcher}]}
	var bases: Array = [runner, null, null]

	var strong_rate: float = _steal_success_rate(batter, pitcher, strong_defense, bases)
	var weak_rate: float = _steal_success_rate(batter, pitcher, weak_defense, bases)
	assert_float(strong_rate).is_less(weak_rate)


func _steal_success_rate(batter: PSPlayerSeasonRecord, pitcher: PSPlayerSeasonRecord, defense: Dictionary, bases: Array) -> float:
	var sb: int = 0
	var cs: int = 0
	# 決定論的ハッシュ由来の乱数なので、少ないサンプルだと稀に強肩/弱肩の順序が逆転しうる。
	# 十分な試行数(3000)を回して統計的に安定させる。
	for i in range(3000):
		var plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(i, batter, pitcher, defense, bases, 0, {})
		var events: Array = plan.get("events", []) as Array
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if not bool(event.get("is_steal_attempt", false)):
				continue
			if bool(event.get("is_stolen_base", false)):
				sb += 1
			elif bool(event.get("is_caught_stealing", false)):
				cs += 1
	var total: int = sb + cs
	if total == 0:
		return 0.0
	return float(sb) / float(total)


# pre_plate_runner_plan を event_index=0..range_size-1 で回し、deferred_steal_intents が非空になった
# index とその deferred 企図を収集する(繰延べ盗塁テスト群で共有するヘルパー)。
func _collect_deferred_steal_indices(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	range_size: int
) -> Array:
	var found: Array = []
	for i in range(range_size):
		var plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(i, batter, pitcher, defense, bases, outs, {})
		var deferred: Array = plan.get("deferred_steal_intents", []) as Array
		if not deferred.is_empty():
			found.append({"index": i, "deferred": deferred})
	return found


# 最終球扱いで繰延べられた盗塁企図(deferred_steal_intents)は、打席結果が三振(かつ三振で3アウトに
# ならない)なら三振の後に解決される(三振ゲッツー)。イベントの phase は "after_plate_result"、
# on_strikeout_pitch==true になり、result は通常の盗塁と同じ stolen_base/caught_stealing を使う。
func test_deferred_steal_resolves_after_strikeout() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9031, "Speedster4", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9032, "Avg Batter4", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9033, "Avg Pitcher4", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9034, "Avg Catcher4", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases: Array = [runner, null, null]

	var found: Array = _collect_deferred_steal_indices(batter, pitcher, defense, bases, 0, 600)
	assert_int(found.size()).is_greater(0)

	var resolved_count: int = 0
	for entry_value in found:
		var entry: Dictionary = entry_value as Dictionary
		var i: int = int(entry.get("index", 0))
		var deferred: Array = entry.get("deferred", []) as Array
		var outcome: Dictionary = {"category": "strikeout", "result": "strikeout", "bases": 0}
		var context: Dictionary = {"deferred_steal_intents": deferred}
		var events: Array = PSRunnerActionModel.runner_events_for_play(i, batter, pitcher, defense, bases, bases, 0, 1, outcome, context)
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if not bool(event.get("is_steal_attempt", false)):
				continue
			resolved_count += 1
			assert_bool(bool(event.get("on_strikeout_pitch", false))).is_true()
			assert_str(str(event.get("phase", ""))).is_equal("after_plate_result")
			var result: String = str(event.get("result", ""))
			assert_bool(result == "stolen_base" or result == "caught_stealing").is_true()
	assert_int(resolved_count).is_greater(0)


# 繰延べられた盗塁企図は、打球(BIP)ならSB/CSとしては解決しない。
# runner_in_motion の進塁補正は game_loop が打席 outcome 適用前に別途行う。
func test_deferred_steal_not_scored_as_steal_on_batted_ball() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9031, "Speedster4", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9032, "Avg Batter4", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9033, "Avg Pitcher4", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9034, "Avg Catcher4", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases_before: Array = [runner, null, null]
	var bases_after: Array = [null, runner, null]

	var found: Array = _collect_deferred_steal_indices(batter, pitcher, defense, bases_before, 0, 600)
	assert_int(found.size()).is_greater(0)

	for entry_value in found:
		var entry: Dictionary = entry_value as Dictionary
		var i: int = int(entry.get("index", 0))
		var deferred: Array = entry.get("deferred", []) as Array
		var outcome: Dictionary = {"category": "hit", "result": "single_center", "bases": 1}
		var context: Dictionary = {"deferred_steal_intents": deferred}
		var events: Array = PSRunnerActionModel.runner_events_for_play(i, batter, pitcher, defense, bases_before, bases_after, 0, 0, outcome, context)
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			assert_bool(bool(event.get("is_steal_attempt", false))).is_false()


# 盗塁企図のタイミング分割: 途中決行(events側)と最終球繰延べ(deferred_steal_intents)の
# 両方が実際に発生すること(現行ノブはおおよそ58:42だが、件数の大小までは断定しない)。
func test_steal_events_split_between_early_and_deferred() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9041, "Speedster5", 3.0)
	var batter: PSPlayerSeasonRecord = _fielder(9042, "Avg Batter5", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9043, "Avg Pitcher5", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9044, "Avg Catcher5", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases: Array = [runner, null, null]

	var early_count: int = 0
	var deferred_count: int = 0
	for i in range(600):
		var plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(i, batter, pitcher, defense, bases, 0, {})
		var events: Array = plan.get("events", []) as Array
		var deferred: Array = plan.get("deferred_steal_intents", []) as Array
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if bool(event.get("is_steal_attempt", false)):
				early_count += 1
		deferred_count += deferred.size()

	assert_int(early_count).is_greater(0)
	assert_int(deferred_count).is_greater(0)


# 成功率は企図判断用 intent_score に依存せず、同じ走者・投手・捕手なら
# 三盗のほうが二盗より高い。
func test_steal_success_separates_attempt_context_and_favors_third() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9051, "Selective Runner", 1.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9052, "Avg Pitcher5", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9053, "Avg Catcher5", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var bases: Array = [runner, null, null]
	var low_context: Dictionary = {
		"runner_id": runner.player_id, "batter_id": 0, "from_base": 1, "to_base": 2,
		"strategy": "straight_steal", "group_id": "", "intent_score": -2.0,
		"success_skill_score": 1.0,
	}
	var high_context: Dictionary = low_context.duplicate(true)
	high_context["intent_score"] = 3.0
	var second_low: Dictionary = PSRunnerActionModel._runner_event_from_intent(10, low_context, pitcher, defense, bases)
	var second_high: Dictionary = PSRunnerActionModel._runner_event_from_intent(10, high_context, pitcher, defense, bases)
	assert_float(float(second_low.get("success_probability", 0.0))).is_equal(float(second_high.get("success_probability", -1.0)))

	var third_intent: Dictionary = low_context.duplicate(true)
	third_intent["from_base"] = 2
	third_intent["to_base"] = 3
	var third: Dictionary = PSRunnerActionModel._runner_event_from_intent(10, third_intent, pitcher, defense, [null, runner, null])
	assert_float(float(third.get("success_probability", 0.0))).is_greater(float(second_low.get("success_probability", 0.0)))


# 重盗は単独盗塁と別の低い倍率を使い、企図内訳を実勢帯へ近づける。
func test_double_steal_attempts_are_rare_relative_to_straight_steals() -> void:
	var runner_first: PSPlayerSeasonRecord = _fielder(9061, "Runner First", 2.0)
	var runner_second: PSPlayerSeasonRecord = _fielder(9062, "Runner Second", 2.0)
	var batter: PSPlayerSeasonRecord = _fielder(9063, "Avg Batter6", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9064, "Avg Pitcher6", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9065, "Avg Catcher6", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var double_plays: int = 0
	var straight_attempts: int = 0
	for i in range(5000):
		if not PSRunnerActionModel._double_steal_intents(i, batter, pitcher, defense, [runner_first, runner_second, null], 0, false).is_empty():
			double_plays += 1
		if not PSRunnerActionModel._steal_intent(i, 1, 2, runner_first, batter, pitcher, defense, 0, false, "straight_steal").is_empty():
			straight_attempts += 1
	assert_int(double_plays).is_greater(0)
	assert_int(straight_attempts).is_greater(double_plays * 10)


# 平均的な投手でもボーク確率が0にクランプされず、走者がいる機会で実際に発生する。
func test_balk_probability_is_live_for_average_pitcher() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9071, "Runner", 0.0)
	var batter: PSPlayerSeasonRecord = _fielder(9072, "Batter", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9073, "Pitcher", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9074, "Catcher", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var balk_plays: int = 0
	for i in range(10000):
		var events: Array = PSRunnerActionModel._pickoff_or_balk_events(i, batter, pitcher, defense, [runner, null, null], {})
		if not events.is_empty() and str((events[0] as Dictionary).get("result", "")) == "balk":
			balk_plays += 1
	assert_int(balk_plays).is_greater(0)


func _runner_intent(runner: PSPlayerSeasonRecord, strategy: String = "straight_steal") -> Dictionary:
	return {
		"event_type": "runner_intent",
		"intent_type": "hit_and_run" if strategy == "hit_and_run" else "steal",
		"strategy": strategy,
		"group_id": "",
		"runner_id": runner.player_id,
		"batter_id": 0,
		"pitcher_id": 0,
		"catcher_id": 0,
		"from_base": 1,
		"to_base": 2,
		"intent_score": 1.0,
		"success_skill_score": 1.0,
	}


# エンドランは表示用だけでなく実行計画に入り、打席結果まで必ず繰延べられる。
func test_hit_and_run_is_deferred_execution_intent() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9081, "Hit Run Runner", 2.0)
	var batter: PSPlayerSeasonRecord = _fielder(9082, "Contact Batter", 0.0)
	batter.z_abilities_snapshot["Bat_Barrel"] = 3.0
	batter.z_abilities_snapshot["Bat_KAvoid"] = 3.0
	batter.z_abilities_snapshot["Bat_Impact"] = -2.0
	var pitcher: PSPlayerSeasonRecord = _pitcher(9083, "Pitcher", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9084, "Catcher", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var found: bool = false
	for i in range(10000):
		var plan: Dictionary = PSRunnerActionModel.pre_plate_runner_plan(i, batter, pitcher, defense, [runner, null, null], 0, {})
		for intent_value in plan.get("deferred_steal_intents", []) as Array:
			if str((intent_value as Dictionary).get("strategy", "")) == "hit_and_run":
				found = true
				for event_value in plan.get("events", []) as Array:
					assert_bool(bool((event_value as Dictionary).get("is_steal_attempt", false))).is_false()
				break
		if found:
			break
	assert_bool(found).is_true()


# エンドランで打者が三振した場合は、同じ投球上の通常のSB/CS企図として解決する。
func test_hit_and_run_on_strikeout_becomes_steal_attempt() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9091, "Hit Run Runner K", 1.0)
	var batter: PSPlayerSeasonRecord = _fielder(9092, "Batter K", 0.0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(9093, "Pitcher K", 0.0)
	var catcher: PSPlayerSeasonRecord = _catcher(9094, "Catcher K", 0.0)
	var defense: Dictionary = {"fielders": [{"position": 2, "record": catcher}]}
	var intent: Dictionary = _runner_intent(runner, "hit_and_run")
	var events: Array = PSRunnerActionModel.runner_events_for_play(
		15, batter, pitcher, defense, [runner, null, null], [runner, null, null], 0, 1,
		{"category": "strikeout", "result": "strikeout", "bases": 0},
		{"deferred_steal_intents": [intent]}
	)
	assert_int(events.size()).is_equal(1)
	assert_bool(bool((events[0] as Dictionary).get("is_steal_attempt", false))).is_true()
	assert_str(str((events[0] as Dictionary).get("strategy", ""))).is_equal("hit_and_run")


# スタート済み走者がいる内野ゴロでは併殺の一部が一塁アウト+走者二塁進塁に変わり、
# その進塁は公式盗塁には数えない。
func test_runner_in_motion_can_break_double_play_without_steal_credit() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9101, "Moving Runner", 2.0)
	var batter: PSPlayerSeasonRecord = _fielder(9102, "Batter Ground", 0.0)
	var intent: Dictionary = _runner_intent(runner, "hit_and_run")
	var original: Dictionary = {
		"category": "double_play", "result": "double_play_shortstop", "bases": 0,
		"physical_traits": {"trajectory_bucket": "grounder"},
	}
	var transformed: Dictionary = {}
	for i in range(100):
		var candidate: Dictionary = PSRunnerActionModel.apply_runner_in_motion_to_outcome(i, original, [intent], [runner, null, null], 0)
		if bool(candidate.get("double_play_avoided_by_runner_motion", false)):
			transformed = candidate
			break
	assert_bool(transformed.is_empty()).is_false()
	assert_str(str(transformed.get("category", ""))).is_equal("out")
	var marker: Dictionary = (transformed.get("runner_events", []) as Array)[0] as Dictionary
	assert_bool(bool(marker.get("is_steal_attempt", true))).is_false()
	assert_str(str(marker.get("result", ""))).is_equal("runner_in_motion_batted_ball")
	var bases: Array = [runner, null, null]
	var applied: Dictionary = PSPlateEventReducer.apply_plate_outcome(batter, null, bases, 0, transformed)
	assert_int(int(applied.get("outs", 0))).is_equal(1)
	assert_object(bases[1]).is_equal(runner)


# 安打ではスタート済み走者の追加進塁が起こり得るが、SBには計上しない。
func test_runner_in_motion_can_take_extra_base_on_hit() -> void:
	var runner: PSPlayerSeasonRecord = _fielder(9111, "Moving Runner Hit", 2.0)
	var intent: Dictionary = _runner_intent(runner, "hit_and_run")
	var original: Dictionary = {
		"category": "hit", "result": "single_center", "bases": 1,
		"physical_traits": {"trajectory_bucket": "liner"},
		"runner_advancements": [{
			"runner": runner, "runner_id": runner.player_id, "from_base": 1, "to_base": 2,
			"baseline_to": 2, "is_out": false, "is_extra": false,
		}],
		"runner_events": [],
	}
	var transformed: Dictionary = {}
	for i in range(100):
		var candidate: Dictionary = PSRunnerActionModel.apply_runner_in_motion_to_outcome(i, original, [intent], [runner, null, null], 0)
		var advancement: Dictionary = (candidate.get("runner_advancements", []) as Array)[0] as Dictionary
		if int(advancement.get("to_base", 0)) == 3:
			transformed = candidate
			break
	assert_bool(transformed.is_empty()).is_false()
	var marker: Dictionary = (transformed.get("runner_events", []) as Array)[0] as Dictionary
	assert_bool(bool(marker.get("is_steal_attempt", true))).is_false()
	assert_int(int(marker.get("to_base", 0))).is_equal(3)


# 集約PAモデルでもエンドランはBIPを増やし、四球待ちを減らす。
func test_hit_and_run_weights_favor_contact_over_walk() -> void:
	var weights: Dictionary = {"k": -1.0, "bb": -1.0, "hbp": -4.0, "bip": 1.0}
	PSPlateAppearanceCoordinator._apply_hit_and_run_weights(weights)
	assert_float(float(weights.get("bip", 0.0))).is_greater(1.0)
	assert_float(float(weights.get("bb", 0.0))).is_less(-1.0)
	assert_float(float(weights.get("k", 0.0))).is_less(-1.0)


# CF は両翼の約 2 倍の打球を担当するため、1 機会あたりの失策率でさらに増幅しない。
# 内野も 3B の正面ゴロ難度が SS を大幅に上回らないことを調整ノブの不変条件とする。
func test_error_difficulty_compensates_for_position_opportunities() -> void:
	var left_multiplier: float = float(PSPlayResolver.OF_ERROR_OPPORTUNITY_MULTIPLIER[7])
	var center_multiplier: float = float(PSPlayResolver.OF_ERROR_OPPORTUNITY_MULTIPLIER[8])
	var right_multiplier: float = float(PSPlayResolver.OF_ERROR_OPPORTUNITY_MULTIPLIER[9])
	assert_float(center_multiplier * 2.0).is_less_equal((left_multiplier + right_multiplier) * 0.5)

	var third_nominal: float = float(PSPlayResolver.FIELD_ERROR_POSITION_DIFFICULTY[5]) * (
		PSPlayResolver.FIELD_ERROR_BASE_GROUNDER
		+ float(PSPlayResolver.THROW_ERROR_BASE_BY_POSITION[5])
	)
	var short_nominal: float = float(PSPlayResolver.FIELD_ERROR_POSITION_DIFFICULTY[6]) * (
		PSPlayResolver.FIELD_ERROR_BASE_GROUNDER
		+ float(PSPlayResolver.THROW_ERROR_BASE_BY_POSITION[6])
	)
	assert_float(third_nominal).is_less_equal(short_nominal * 1.4)
