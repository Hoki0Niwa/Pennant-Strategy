extends GdUnitTestSuite

const SaveContext = preload("res://services/storage/save_context.gd")
const CampServiceRef = preload("res://services/season/camp_service.gd")
const Offseason = preload("res://services/season/offseason_service.gd")


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
#
# **母集団は支配下のみ** (2026-08-04)。育成を混ぜると、比較しているのが「評価式のスケール」ではなく
# 「育成をどれだけ抱えているか」になってしまう。実測: 同一シードで支配下のみなら 投手68.92 /
# 野手68.98 (差 0.06) だが、育成込みだと 投手66.7 / 野手65.4 (差 1.29) へ跳ねる。育成は
# 野手平均48.9 / 投手平均52.3 と低評価かつ野手側の裾が長いため、保有数が増えるほど野手平均だけが
# 下がるためで、投打の評価スケール自体は動いていない。実際、育成保有数を増やす変更
# ([[project_released_market]] の育成無制限化) を入れただけでこのテストが落ちるようになった。
# 編成AI (デプスチャート等) も支配下だけを見るので、母集団を揃えるほうが本来の意図に合う。
# 役割の初期判定 (role="" の投手を先発/中継へ振る) は「先発向きか救援向きかの**形**」だけで
# 決まり、**その投手がどれだけ強いかには依らない**こと。
# 依存していた頃は、一律に弱い集団は全員が中継ぎ判定になり、ファーム専用球団は22人中0人が
# 先発 = 二軍戦がブルペンデー連発になっていた (2026-08-12 実測)。
func test_pitcher_role_decision_ignores_overall_ability_level() -> void:
	for shape in ["starter", "reliever"]:
		var decisions: Array = []
		var shape_advantages: Array = []
		var raw_advantages: Array = []
		# 水準の幅は ±1.6σ。補正が無いと 1.95 × 3.2σ ぶん判定がずれるので、
		# 「形は同じなのに役割が反転する」旧挙動をこの幅で捕まえられる。
		for level in [-1.6, -0.5, 0.5, 1.6]:
			var record: PSPlayerSeasonRecord = _shaped_pitcher_record(str(shape), float(level))
			decisions.append(PSPitcherRoleModel.is_starter_record(record))
			shape_advantages.append(PSPitcherRoleModel.starter_shape_advantage(record))
			raw_advantages.append(PSPitcherRoleModel.starter_advantage(record))
		# 判定に使う「先発向きさ」が水準 2.4σ の範囲でほとんど動かないこと。
		# これが本体の不変条件 — 形が同じなら水準が変わっても同じ役割になる。
		var shape_span: float = float(shape_advantages.max()) - float(shape_advantages.min())
		assert_float(shape_span).override_failure_message(
			"shape=%s: starter_shape_advantage が水準で %.2f も動いた (%s)" % [shape, shape_span, str(shape_advantages)]
		).is_less(0.35)
		# 補正前の生の差は水準に強く引きずられる (= 補正が必要だったことの裏取り)。
		# ここが小さくなったら重み構成が変わったということなので ROLE_LEVEL_WEIGHT_DELTA を見直す。
		var raw_span: float = float(raw_advantages.max()) - float(raw_advantages.min())
		assert_float(raw_span).override_failure_message(
			"starter_advantage が水準で動かない = 補正の前提が崩れている (%s)" % str(raw_advantages)
		).is_greater(2.0)
		# 4水準すべてで同じ判定になること。
		for i in range(1, decisions.size()):
			assert_bool(bool(decisions[i])).override_failure_message(
				"shape=%s の判定が水準で変わった: %s" % [shape, str(decisions)]
			).is_equal(bool(decisions[0]))
		# 形どおりの役割へ振り分けられていること (判定が常に片方へ倒れていないことの確認)。
		assert_bool(bool(decisions[0])).override_failure_message(
			"shape=%s が期待と逆の役割になった" % shape
		).is_equal(shape == "starter")


# 先発向き (スタミナ/回復/効率が自分の水準より上) / 救援向き (奪三振が上・スタミナが下) の
# 投手を、指定した能力水準 level で作る。
func _shaped_pitcher_record(shape: String, level: float) -> PSPlayerSeasonRecord:
	var starter_shaped: bool = shape == "starter"
	var z: Dictionary = {
		"Pit_KCreate": level + (-0.6 if starter_shaped else 0.8),
		"Pit_BBPrevent": level + (0.3 if starter_shaped else -0.2),
		"Pit_ImpactLimit": level,
		"Pit_LoftControl": level,
		"Pit_BarrelDeny": level,
		"Pit_Efficiency": level + (0.7 if starter_shaped else -0.5),
		"Pit_Stamina": level + (1.0 if starter_shaped else -1.0),
		"Pit_FatigueResist": level + (0.8 if starter_shaped else -0.6),
		"Pit_HoldRunner": level,
		"Pit_EdgeRate": 0.0,
	}
	var player: PSPlayer = PSPlayer.from_dict({
		"id": 990000 + int(level * 10.0) + (1 if starter_shaped else 0),
		"name": "shape_probe",
		"team_id": 0,
		"age": 24,
		"position": 1,
		"role": "",
		"z_abilities": z,
		# 球速は判定に効かないので固定 (生成関数を呼ぶと Rng を消費してしまうため)。
		"raw_abilities": {"max_velocity": 145},
		# 変化球の完成度は水準から切り離して固定する。ここを level に連動させると
		# 有効球数の閾値 (EFFECTIVE_PITCH_Z) をまたいで depth/finish が動き、
		# 「z 能力の水準依存だけ」を見たいこのテストの信号が濁る。
		"arsenal": [
			{"type": "four_seam", "mastery": 0.3},
			{"type": "slider", "mastery": -0.1},
			{"type": "curve", "mastery": -0.5},
		],
	})
	return PSPlayerSeasonRecord.from_player(player, 0, 0)


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
		if player == null or player.development_player:
			continue
		# ファーム専用球団の選手も母集団から外す。育成と同じ理由 — NPB 支配下ではない低評価層が
		# 混ざると、投打の評価スケールではなく「その層をどれだけ抱えているか」を測ってしまう。
		if PSFarmLeague.is_farm_club_id(player.team_id):
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


# 表示・査定に使う overall_score と batting_score_without_fatigue は疲労を無視し、
# 起用判断に使う batting_score だけが疲労で下がる。
func test_display_scores_ignore_fatigue_while_usage_score_applies_it() -> void:
	var record: PSPlayerSeasonRecord = _fielder(901, "Everyday", 1.0)
	record.fatigue = 0
	var base_overall: int = PSPlayerValueEvaluator.overall_score(record)
	var base_display_bat: int = PSPlayerValueEvaluator.batting_score_without_fatigue(record)
	var fresh_batting: int = PSPlayerValueEvaluator.batting_score(record)

	record.fatigue = 160

	assert_int(PSPlayerValueEvaluator.overall_score(record)).is_equal(base_overall)
	assert_int(PSPlayerValueEvaluator.batting_score_without_fatigue(record)).is_equal(base_display_bat)
	assert_int(PSPlayerValueEvaluator.batting_score(record)).is_less(fresh_batting)


# 基本打順は打者像へのマッチングで組まれる: 4番=最強の長打者、3番=総合力最上位、
# 1番=出塁と機動力、そして捕手は打力が上位打順向きでも 1・2 番へは入らない。
func test_base_batting_order_matches_roles_and_keeps_catcher_lower() -> void:
	var mk: Callable = func(pid: int, pos: int, z: Dictionary) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = pos
		r.name = "B%d" % pid
		r.z_abilities_snapshot = z
		return r

	var leadoff: PSPlayerSeasonRecord = mk.call(601, 8, {
		"Bat_BBCreate": 2.2, "Bat_KAvoid": 2.0, "Bat_Barrel": 1.0, "Bat_Impact": -0.7,
		"Bat_Loft": -0.7, "Run_Speed": 2.3, "Run_Steal": 2.0, "Run_Judgment": 1.8,
	})
	var slugger: PSPlayerSeasonRecord = mk.call(602, 3, {
		"Bat_Impact": 3.0, "Bat_Loft": 2.5, "Bat_Barrel": 0.8, "Bat_Aggression": 1.0,
		"Bat_BBCreate": 0.3, "Bat_KAvoid": -0.8, "Run_Speed": -1.0,
	})
	var all_round: PSPlayerSeasonRecord = mk.call(603, 9, {
		"Bat_Barrel": 2.2, "Bat_Impact": 1.8, "Bat_Loft": 1.2, "Bat_BBCreate": 1.4,
		"Bat_KAvoid": 1.4, "Bat_Spray": 1.0, "Run_Speed": 0.8,
	})
	var second_slugger: PSPlayerSeasonRecord = mk.call(604, 5, {
		"Bat_Impact": 2.2, "Bat_Loft": 1.8, "Bat_Barrel": 0.6, "Bat_BBCreate": 0.2,
		"Bat_KAvoid": -0.5, "Run_Speed": -0.3,
	})
	# 出塁も走力もチーム最良の捕手 = 減点が無ければ 1 番に入る打力。
	var catcher: PSPlayerSeasonRecord = mk.call(605, 2, {
		"Bat_BBCreate": 2.4, "Bat_KAvoid": 2.2, "Bat_Barrel": 0.7, "Bat_Spray": 0.4,
		"Bat_Impact": -0.6, "Bat_Loft": -0.6, "Run_Speed": 2.3, "Run_Steal": 2.1,
		"Run_Judgment": 1.9,
	})
	var contact_hitter: PSPlayerSeasonRecord = mk.call(606, 4, {
		"Bat_BBCreate": 1.8, "Bat_KAvoid": 2.0, "Bat_Barrel": 1.6, "Bat_Spray": 1.2,
		"Bat_Impact": -0.5, "Bat_Loft": -0.5, "Run_Speed": 1.8, "Run_Steal": 1.5,
		"Run_Judgment": 1.3,
	})
	var records: Array = [leadoff, slugger, all_round, second_slugger, catcher, contact_hitter]
	for filler_pid in [607, 608, 609]:
		records.append(mk.call(filler_pid, 6, {
			"Bat_Barrel": -0.8, "Bat_KAvoid": -0.8, "Bat_BBCreate": -0.8,
			"Bat_Impact": -0.8, "Bat_Loft": -0.8, "Run_Speed": -0.8,
		}))

	var ids_of: Callable = func(ordered: Array) -> Array:
		var ids: Array = []
		for record_row in ordered:
			ids.append((record_row as PSPlayerSeasonRecord).player_id)
		return ids

	var strict: PSBattingOrderProfile = PSBattingOrderProfile.build_default(0, true)
	var order_ids: Array = ids_of.call(PSBattingOrderService.build_base_order(records, strict))
	print("BASEORDER strict=%s" % str(order_ids))

	assert_int(int(order_ids[3])).is_equal(slugger.player_id)
	assert_int(int(order_ids[2])).is_equal(all_round.player_id)
	assert_int(int(order_ids[4])).is_equal(second_slugger.player_id)
	assert_int(int(order_ids[0])).is_equal(leadoff.player_id)
	# 捕手は上位打順 (1・2番) に入らない。
	assert_int(int(order_ids.find(catcher.player_id))).is_greater_equal(2)

	# keep_catcher_lower を切ると同じ打者陣でこの捕手は上位打順へ来る
	# (= 上の結果は「そもそも打力が足りない」ではなく捕手減点が効いている)。
	var lenient: PSBattingOrderProfile = PSBattingOrderProfile.build_default(0, true)
	lenient.keep_catcher_lower = false
	var lenient_ids: Array = ids_of.call(PSBattingOrderService.build_base_order(records, lenient))
	print("BASEORDER lenient=%s" % str(lenient_ids))
	assert_int(int(lenient_ids.find(catcher.player_id))).is_less(2)

	# 投手を混ぜると必ず最終打順。
	var pitcher: PSPlayerSeasonRecord = mk.call(610, 1, {"Bat_Barrel": -1.5, "Bat_Impact": -1.5})
	var with_pitcher: Array = records.duplicate()
	with_pitcher.insert(0, pitcher)
	var ordered_with_pitcher: Array = PSBattingOrderService.build_base_order(with_pitcher)
	var last: PSPlayerSeasonRecord = ordered_with_pitcher[ordered_with_pitcher.size() - 1] as PSPlayerSeasonRecord
	assert_int(last.player_id).is_equal(pitcher.player_id)


# 打順評価の基準分布は固定値ではなく母集団の実測。能力側はそのシーズンの支配下野手から測り、
# 成績側はリーグ環境が動けば追随する (= バランス較正や長期セーブのドリフトで基準が古びない)。
func test_batting_reference_is_measured_from_population() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	# 1) 能力の基準は当該シーズンの支配下野手から実測されていること。
	var measured_sum: float = 0.0
	var measured_count: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number, true):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null or record.is_pitcher() or record.development_player:
				continue
			measured_sum += float(PSPlayerVisibleRatings.fielder_contact(record))
			measured_count += 1
	var population_mean: float = measured_sum / float(maxi(measured_count, 1))

	var reference: Dictionary = PSPerformanceReference.for_season(season.year, season.season_number)
	var contact_reference: Dictionary = (reference["ratings"] as Dictionary)["contact"] as Dictionary
	assert_int(measured_count).is_greater(PSPerformanceReference.MIN_RATING_SAMPLE)
	assert_float(float(contact_reference["mean"])).is_equal_approx(population_mean, 0.001)

	# 2) 成績の基準は「直近の完了シーズン」を見る。打高な過去シーズンを差し込むと基準も上がること。
	#    (進行中のシーズンは規定到達打者が居ないので既定値ではなくここへフォールバックする)
	var probe_year: int = season.year + 50
	var probe_season_number: int = season.season_number + 50
	var inserted: Array = []
	var sample_size: int = PSPerformanceReference.MIN_STAT_SAMPLE + 5
	for i in range(sample_size):
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		record.player_id = 900000 + i
		record.team_id = (GameDb.teams[0] as PSTeam).id
		record.position = 7
		record.name = "REF%d" % i
		record.year = probe_year
		record.season_number = probe_season_number
		var stats: PSBatterStats = record.batter_stats
		stats.games = 140
		stats.plate_appearances = 600
		stats.at_bats = 540
		# 打率 .300 前後・長打も多い「打高シーズン」を作る。i で少しばらつかせて spread を持たせる。
		stats.hits = 162 + (i % 9) - 4
		stats.doubles = 30
		stats.home_runs = 25
		stats.walks = 60
		RecordStore.set_player_record(record)
		inserted.append(record)

	PSPerformanceReference.reset_cache()
	var probe_reference: Dictionary = PSPerformanceReference.for_season(probe_year + 1, probe_season_number + 1)
	var ops_reference: Dictionary = (probe_reference["stats"] as Dictionary)["ops"] as Dictionary
	var default_ops: Dictionary = PSPerformanceReference.DEFAULT_STAT_REFERENCE["ops"] as Dictionary

	for record_row in inserted:
		var inserted_record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		RecordStore.erase_player_record(inserted_record.player_id, probe_year, probe_season_number)
	PSPerformanceReference.reset_cache()

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	print("REFERENCE contact_mean=%.2f (population %.2f, default %.2f) | probe_ops_mean=%.3f (default %.3f)" % [
		float(contact_reference["mean"]), population_mean,
		float((PSPerformanceReference.DEFAULT_RATING_REFERENCE["contact"] as Dictionary)["mean"]),
		float(ops_reference["mean"]), float(default_ops["mean"]),
	])
	# 打高シーズンを挟んだので、既定値より明確に高い OPS 基準になる。
	assert_float(float(ops_reference["mean"])).is_greater(float(default_ops["mean"]) + 0.05)
	# 成績スケールは alignment で能力スケールへ平行移動されている。成績母集団 (規定到達打者/
	# 能力上位) は支配下野手平均より上なので、正の値でなければゼロ点が揃っていない。
	var current_stats: Dictionary = (reference["stats"] as Dictionary)["ops"] as Dictionary
	print("ALIGNMENT ops=%.3f" % float(current_stats.get("alignment", 0.0)))
	assert_float(float(current_stats.get("alignment", 0.0))).is_greater(0.2)


# 「他の選択肢より良いか」を問う判定ラインは絶対値ではなく母集団相対 (mean + sigma*spread)。
# 絶対値だとリーグ全体の水準が動いただけで判定が一斉にズレる
# (前例: 旧 RELEASE_REPLACEMENT_VALUE を 4 点動かすだけで放出が 75.5→83.75 人/年)。
# ここでは (1) ラインが実測母集団に一致すること (2) sigma 定数が現行ワールドで
# 旧・絶対値を再現すること (= 相対化が挙動保存であること) を固定する。
func test_decision_lines_track_population_not_absolute_constants() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	# (1) overall_batter のラインが、支配下野手の実測 mean/spread と一致する。
	var samples: Array = []
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number, true):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null or record.is_pitcher() or record.development_player:
				continue
			samples.append(float(PSPlayerValueEvaluator.overall_score(record)))
	var mean: float = 0.0
	for value in samples:
		mean += float(value)
	mean /= float(maxi(samples.size(), 1))
	var variance: float = 0.0
	for value in samples:
		variance += pow(float(value) - mean, 2.0)
	variance /= float(maxi(samples.size(), 1))
	var spread: float = sqrt(variance)

	var distribution: Dictionary = PSPerformanceReference.score_distribution(
		season.year, season.season_number, "overall_batter"
	)
	assert_int(samples.size()).is_greater(PSPerformanceReference.MIN_SCORE_SAMPLE)
	assert_float(float(distribution["mean"])).is_equal_approx(mean, 0.001)
	assert_float(float(distribution["spread"])).is_equal_approx(spread, 0.001)
	assert_float(
		PSPerformanceReference.score_threshold(season.year, season.season_number, "overall_batter", 1.5)
	).is_equal_approx(mean + 1.5 * spread, 0.001)

	# (2) 各 sigma が現行ワールドで旧・絶対値を再現する (相対化で挙動が飛んでいない)。
	var line_of: Callable = func(key: String, sigma: float) -> float:
		return PSPerformanceReference.score_threshold(season.year, season.season_number, key, sigma)
	var lines: Dictionary = {
		"REGULAR_OVERALL": [line_of.call("overall_batter", FaMarketService.REGULAR_OVERALL_SIGMA),
			float(FaMarketService.REGULAR_OVERALL), 2.0],
		"INJURY_MAINSTAY": [line_of.call("overall_batter", TeamAutoAI.INJURY_MAINSTAY_STASH_SIGMA),
			TeamAutoAI.INJURY_MAINSTAY_STASH_SCORE_MIN, 2.0],
		"INJURY_CORE": [line_of.call("overall_batter", TeamAutoAI.INJURY_CORE_STASH_SIGMA),
			TeamAutoAI.INJURY_CORE_STASH_SCORE_MIN, 3.0],
		"LOW_BATTER": [line_of.call("batting", GameSimulator.LOW_BATTER_SIGMA),
			float(GameSimulator.LOW_BATTER_SCORE), 2.0],
		"SOLID_BATTER": [line_of.call("batting", GameSimulator.SOLID_BATTER_SIGMA),
			float(GameSimulator.SOLID_BATTER_SCORE), 2.0],
	}
	var report: Array = []
	for key in lines.keys():
		var row: Array = lines[key] as Array
		report.append("%s=%.1f(旧%.0f)" % [str(key), float(row[0]), float(row[1])])
	print("DECISIONLINE %s" % " ".join(PackedStringArray(report)))

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	for key in lines.keys():
		var row: Array = lines[key] as Array
		assert_float(absf(float(row[0]) - float(row[1]))).is_less(float(row[2]))


# 打者指標は表示能力と成績のブレンド。同一能力なら成績で差が付き、今季成績の重みは打席数とともに
# 増し、過去シーズンは古いほど軽くなる。
func test_batting_order_metrics_blend_ability_and_recent_performance() -> void:
	const PROBE_YEAR: int = 3000
	const PROBE_SEASON: int = 10

	var fill_stats: Callable = func(
		stats: PSBatterStats, plate_appearances: int, average: float, walk_rate: float, isolated_power: float
	) -> void:
		var walks: int = int(round(float(plate_appearances) * walk_rate))
		var at_bats: int = plate_appearances - walks
		var hits: int = int(round(float(at_bats) * average))
		var home_runs: int = int(round(float(at_bats) * isolated_power * 0.5))
		stats.games = maxi(1, plate_appearances / 4)
		stats.plate_appearances = plate_appearances
		stats.at_bats = at_bats
		stats.hits = hits
		stats.doubles = 0
		stats.triples = 0
		stats.home_runs = mini(home_runs, hits)
		stats.walks = walks
		stats.strikeouts = int(round(float(plate_appearances) * 0.20))

	var mk: Callable = func(pid: int, year: int, season_number: int) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = 7
		r.name = "M%d" % pid
		r.year = year
		r.season_number = season_number
		# 全員同一能力にして、指標の差が成績だけから来るようにする。
		r.z_abilities_snapshot = {
			"Bat_Barrel": 0.5, "Bat_KAvoid": 0.5, "Bat_BBCreate": 0.5,
			"Bat_Impact": 0.5, "Bat_Loft": 0.5, "Run_Speed": 0.5,
		}
		return r

	var total_of: Callable = func(records: Array, pid: int) -> float:
		var evaluation: Dictionary = PSBattingOrderService.build_evaluation(records, null, {})
		var metrics: Dictionary = (evaluation["metrics"] as Dictionary)[pid] as Dictionary
		return float(metrics["total"])

	# 1) 今季の成績で差が付く: 好調 > 不振。
	var hot: PSPlayerSeasonRecord = mk.call(701, PROBE_YEAR, PROBE_SEASON)
	fill_stats.call(hot.batter_stats, 500, 0.330, 0.11, 0.230)
	var cold: PSPlayerSeasonRecord = mk.call(702, PROBE_YEAR, PROBE_SEASON)
	fill_stats.call(cold.batter_stats, 500, 0.205, 0.05, 0.060)
	var neutral: PSPlayerSeasonRecord = mk.call(703, PROBE_YEAR, PROBE_SEASON)
	var pair: Array = [hot, cold, neutral]
	var hot_total: float = total_of.call(pair, hot.player_id)
	var cold_total: float = total_of.call(pair, cold.player_id)
	var neutral_total: float = total_of.call(pair, neutral.player_id)
	assert_float(hot_total).is_greater(neutral_total)
	assert_float(neutral_total).is_greater(cold_total)

	# 2) 今季の重みは打席数とともに増す: 同じ好成績でも 40 打席なら、
	#    平凡な成績を 500 打席続けた選手を上回らない。500 打席なら上回る。
	var steady: PSPlayerSeasonRecord = mk.call(704, PROBE_YEAR, PROBE_SEASON)
	fill_stats.call(steady.batter_stats, 500, 0.290, 0.09, 0.150)
	var early: PSPlayerSeasonRecord = mk.call(705, PROBE_YEAR, PROBE_SEASON)
	fill_stats.call(early.batter_stats, 40, 0.330, 0.11, 0.230)
	var steady_total: float = total_of.call([steady, early], steady.player_id)
	var early_total: float = total_of.call([steady, early], early.player_id)
	assert_float(early_total).is_less(steady_total)

	var late: PSPlayerSeasonRecord = mk.call(705, PROBE_YEAR, PROBE_SEASON)
	fill_stats.call(late.batter_stats, 500, 0.330, 0.11, 0.230)
	var late_total: float = total_of.call([steady, late], late.player_id)
	assert_float(late_total).is_greater(steady_total)

	# 3) 過去シーズンは古いほど軽い: 同じ好成績でも 1 年前 > 3 年前。
	var recent_star: PSPlayerSeasonRecord = mk.call(706, PROBE_YEAR, PROBE_SEASON)
	var old_star: PSPlayerSeasonRecord = mk.call(707, PROBE_YEAR, PROBE_SEASON)
	var recent_past: PSPlayerSeasonRecord = mk.call(706, PROBE_YEAR - 1, PROBE_SEASON - 1)
	fill_stats.call(recent_past.batter_stats, 500, 0.330, 0.11, 0.230)
	var old_past: PSPlayerSeasonRecord = mk.call(707, PROBE_YEAR - 3, PROBE_SEASON - 3)
	fill_stats.call(old_past.batter_stats, 500, 0.330, 0.11, 0.230)
	RecordStore.set_player_record(recent_past)
	RecordStore.set_player_record(old_past)

	var star_pair: Array = [recent_star, old_star]
	var recent_total: float = total_of.call(star_pair, recent_star.player_id)
	var old_total: float = total_of.call(star_pair, old_star.player_id)

	RecordStore.erase_player_record(706, PROBE_YEAR - 1, PROBE_SEASON - 1)
	RecordStore.erase_player_record(707, PROBE_YEAR - 3, PROBE_SEASON - 3)

	print("BLEND hot=%.3f neutral=%.3f cold=%.3f | early=%.3f steady=%.3f late=%.3f | recent=%.3f old=%.3f" % [
		hot_total, neutral_total, cold_total, early_total, steady_total, late_total, recent_total, old_total
	])
	assert_float(recent_total).is_greater(old_total)
	# どちらも能力より上振れした成績なので、能力だけの選手 (成績なし) は下回る。
	assert_float(old_total).is_greater(neutral_total)


# 実データでの自動編成: 上位打順 (1-5番) の平均打力が下位 (6-9番) を上回り、
# 捕手が 1・2 番に置かれるチームがほとんど無いこと。
func test_auto_lineup_puts_better_hitters_higher_in_order() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	var top_total: int = 0
	var top_count: int = 0
	var bottom_total: int = 0
	var bottom_count: int = 0
	var catcher_in_top_teams: int = 0
	var teams_checked: int = 0

	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		var records_by_id: Dictionary = {}
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record != null:
				records_by_id[record.player_id] = record

		var preview: Dictionary = GameSimulator.preview_lineup(season, team.id, true)
		assert_bool(bool(preview.get("ok", false))).is_true()
		teams_checked += 1
		for entry_row in preview.get("batting_order", []) as Array:
			var entry: Dictionary = entry_row as Dictionary
			var slot: int = int(entry.get("slot", 0))
			var batter: PSPlayerSeasonRecord = records_by_id.get(int(entry.get("player_id", 0)), null) as PSPlayerSeasonRecord
			if batter == null or batter.is_pitcher():
				continue
			if int(entry.get("position", 0)) == 2 and slot <= 2:
				catcher_in_top_teams += 1
			var score: int = PSPlayerValueEvaluator.batting_score_without_fatigue(batter)
			if slot <= 5:
				top_total += score
				top_count += 1
			else:
				bottom_total += score
				bottom_count += 1

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	assert_int(teams_checked).is_greater(0)
	assert_int(top_count).is_greater(0)
	assert_int(bottom_count).is_greater(0)
	var top_avg: float = float(top_total) / float(top_count)
	var bottom_avg: float = float(bottom_total) / float(bottom_count)
	print("LINEUPORDER top_avg=%.2f bottom_avg=%.2f catcher_in_top=%d/%d" % [
		top_avg, bottom_avg, catcher_in_top_teams, teams_checked
	])
	assert_float(top_avg).is_greater(bottom_avg + 2.0)
	# 捕手の上位打順は「例外的に打てる捕手だけ」。減点そのものの検証は
	# test_base_batting_order_matches_roles_and_keeps_catcher_lower 側 (母集団に依存しない) が担う。
	assert_int(catcher_in_top_teams).is_less_equal(2)


# 出場判断 (スタメン/DH/代打) は成績の上振れ/下振れを rating 点として加える。
# 能力が同じなら好調な選手がスタメンを取り、成績が無ければ能力どおり (デルタ 0) に戻る。
func test_batting_form_moves_starter_selection() -> void:
	const PROBE_YEAR: int = 3100
	const PROBE_SEASON: int = 20
	var apt_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS

	var mk: Callable = func(pid: int, position: int) -> PSPlayerSeasonRecord:
		var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		r.player_id = pid
		r.position = position
		r.name = "F%d" % pid
		r.year = PROBE_YEAR
		r.season_number = PROBE_SEASON
		r.z_abilities_snapshot = {
			"Bat_Barrel": 0.6, "Bat_KAvoid": 0.6, "Bat_BBCreate": 0.6,
			"Bat_Impact": 0.6, "Bat_Loft": 0.6, "Run_Speed": 0.6,
		}
		var aptitudes: Dictionary = {}
		aptitudes[str(apt_keys.get(position, "left_field"))] = 85
		r.position_aptitudes_snapshot = aptitudes
		return r

	var fill_stats: Callable = func(
		stats: PSBatterStats, plate_appearances: int, average: float, isolated_power: float
	) -> void:
		var walks: int = int(round(float(plate_appearances) * 0.09))
		var at_bats: int = plate_appearances - walks
		stats.games = maxi(1, plate_appearances / 4)
		stats.plate_appearances = plate_appearances
		stats.at_bats = at_bats
		stats.hits = int(round(float(at_bats) * average))
		stats.home_runs = mini(int(round(float(at_bats) * isolated_power * 0.5)), stats.hits)
		stats.walks = walks
		stats.strikeouts = int(round(float(plate_appearances) * 0.20))

	# 成績が無ければデルタは 0 = 能力どおり。
	var fresh: PSPlayerSeasonRecord = mk.call(801, 7)
	assert_float(PSBatterForm.rating_delta(fresh)).is_equal_approx(0.0, 0.0001)

	var cold_regular: PSPlayerSeasonRecord = mk.call(802, 7)
	fill_stats.call(cold_regular.batter_stats, 500, 0.205, 0.060)
	var hot_reserve: PSPlayerSeasonRecord = mk.call(803, 7)
	fill_stats.call(hot_reserve.batter_stats, 500, 0.330, 0.230)
	var hot_but_early: PSPlayerSeasonRecord = mk.call(804, 7)
	fill_stats.call(hot_but_early.batter_stats, 40, 0.330, 0.230)

	var cold_delta: float = PSBatterForm.rating_delta(cold_regular)
	var hot_delta: float = PSBatterForm.rating_delta(hot_reserve)
	var early_delta: float = PSBatterForm.rating_delta(hot_but_early)
	print("FORMDELTA cold=%.2f hot=%.2f early=%.2f" % [cold_delta, hot_delta, early_delta])

	assert_float(cold_delta).is_less(0.0)
	assert_float(hot_delta).is_greater(0.0)
	# 打席が少ないうちは同じ好成績でも効きが小さい。
	assert_float(early_delta).is_greater(0.0)
	assert_float(early_delta).is_less(hot_delta)
	# クリップの範囲に収まる。
	assert_float(hot_delta).is_less_equal(PSBatterForm.FORM_RATING_MAX)
	assert_float(cold_delta).is_greater_equal(PSBatterForm.FORM_RATING_MIN)

	# 能力・適性が同一でも、好調な控えが不振のレギュラーより高いスタメン評価になる。
	var cold_score: int = PSPlayerValueEvaluator.starter_assignment_score(cold_regular, 7)
	var hot_score: int = PSPlayerValueEvaluator.starter_assignment_score(hot_reserve, 7)
	assert_int(hot_score).is_greater(cold_score)
	# 能力ベースの batting_score は成績で動かない (表示・査定用は据え置き)。
	assert_int(PSPlayerValueEvaluator.batting_score(hot_reserve)).is_equal(
		PSPlayerValueEvaluator.batting_score(cold_regular)
	)


# 基本打順は BASE_REBUILD_INTERVAL_GAMES ごとに組み直され、今季成績が溜まるほど打順へ反映される。
# 開幕直後の基本打順と、間隔を跨いだ後の基本打順が同じままではないこと。
func test_auto_batting_order_base_refreshes_during_season() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	Rng.set_seed_value(20260808)
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	var interval: int = PSBattingOrderService.BASE_REBUILD_INTERVAL_GAMES
	GameSimulator.simulate_current_day(season, false)
	var opening_bases: Dictionary = {}
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for dh in [true, false]:
			var base: Array = season.get_auto_batting_order(team.id, dh)
			if not base.is_empty():
				opening_bases["%d_%s" % [team.id, str(dh)]] = base.duplicate()

	for _day in range(interval + 2):
		GameSimulator.simulate_current_day(season, false)

	var changed_teams: int = 0
	for key in opening_bases.keys():
		var parts: PackedStringArray = str(key).split("_")
		var team_id: int = int(parts[0])
		var dh_enabled: bool = str(parts[1]) == "true"
		if season.get_auto_batting_order(team_id, dh_enabled) != (opening_bases[key] as Array):
			changed_teams += 1

	# 能力スケールと成績スケールのゼロ点が揃っていること (PSPerformanceReference の alignment)。
	# 揃っていないと「出場するほど下振れ扱い」になり、レギュラーだけが系統的に減点されて
	# スタメン選定が壊れる。実測では平均 -2.4 点まで偏っていた。
	var form_sum: float = 0.0
	var form_count: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null or record.is_pitcher() or record.batter_stats.plate_appearances < 30:
				continue
			form_sum += PSBatterForm.rating_delta(record)
			form_count += 1
	var form_mean: float = form_sum / float(maxi(form_count, 1))

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()

	print("BASEREFRESH tracked=%d changed=%d | form_mean=%.2f (n=%d)" % [
		opening_bases.size(), changed_teams, form_mean, form_count
	])
	assert_int(opening_bases.size()).is_greater(0)
	assert_int(changed_teams).is_greater(0)
	assert_int(form_count).is_greater(50)
	assert_float(absf(form_mean)).is_less(0.5)


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

	var usage: Dictionary = {"position_slots": {"2": PSDefenseAlignmentService.make_slot(
		[{"player_id": injured_catcher.player_id, "share": 1.0}], [usage_backup.player_id]
	)}}

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
	var slot_six: Dictionary = PSDefenseAlignmentService.make_slot(
		[{"player_id": collapsed_ss.player_id, "share": 1.0}]
	)

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


# 当日のブルペンが全員疲労で登板不可でも、**継投先が必ず見つかること**。
# ここが null を返すと呼び出し側は継投を諦め、先発が投げ続ける。実際に当日ブルペンは
# 疲労を見ない能力上位6人固定なので、6人が全員 RELIEVER_EMERGENCY_FATIGUE_LIMIT を超えると
# 「健康な救援がロスターに残っているのに誰も投げられない」状態になり、
# **1試合370球を投げる先発**が発生していた (2026-08-12、二軍のファーム専用球団で実測)。
func test_exhausted_bullpen_still_yields_an_emergency_reliever() -> void:
	var bullpen: Array = []
	for i in range(6):
		var tired: PSPlayerSeasonRecord = _pitcher(801 + i, "Tired %d" % i, 1.0)
		# 緊急上限 (188) 超え = allow_tired でも登板不可。
		tired.fatigue = PSPitcherUsageModel.RELIEVER_EMERGENCY_FATIGUE_LIMIT + 10
		bullpen.append(tired)
	var reserve_fresh: PSPlayerSeasonRecord = _pitcher(820, "ReserveFresh", 0.2)
	reserve_fresh.fatigue = 20
	var reserve_hurt: PSPlayerSeasonRecord = _pitcher(821, "ReserveHurt", 0.9)
	reserve_hurt.injury_days = 12

	var setup: Dictionary = {
		"team_id": 1,
		"relievers": bullpen,
		"relief_reserve": [reserve_hurt, reserve_fresh],
		"used_pitcher_ids": {},
		"game_day": 60,
		"team_games_played_before": 50,
	}
	# 控えの健康な投手が上がる (怪我人は選ばない)。
	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 6, {})
	assert_object(picked).override_failure_message("継投先が見つからず null が返った").is_not_null()
	assert_int(picked.player_id).is_equal(reserve_fresh.player_id)

	# 控えが尽きたら、疲労上限を超えていてもブルペンから最も疲労の少ない投手を上げる
	# (実野球では誰かが必ず投げる。ここで null を返すのが 370球の原因だった)。
	setup["relief_reserve"] = []
	(bullpen[3] as PSPlayerSeasonRecord).fatigue = PSPitcherUsageModel.RELIEVER_EMERGENCY_FATIGUE_LIMIT + 1
	var fallback: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 6, {})
	assert_object(fallback).override_failure_message("ブルペン全滅時に null が返った").is_not_null()
	assert_int(fallback.player_id).is_equal((bullpen[3] as PSPlayerSeasonRecord).player_id)

	# 既に登板済みの投手は再登板させない。
	setup["used_pitcher_ids"] = {(bullpen[3] as PSPlayerSeasonRecord).player_id: true}
	var third: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 6, {})
	assert_object(third).is_not_null()
	assert_int(third.player_id).is_not_equal((bullpen[3] as PSPlayerSeasonRecord).player_id)


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


func test_pa_game_cache_reuses_static_views_and_keeps_pitcher_adjustment_local() -> void:
	var batter: PSPlayerSeasonRecord = _fielder(814, "Cached Batter", 0.8)
	var pitcher: PSPlayerSeasonRecord = _pitcher(804, "Cached Pitcher", 0.6)
	var catcher: PSPlayerSeasonRecord = _fielder(815, "Cached Catcher", 0.4)
	catcher.position = 2
	catcher.z_abilities_snapshot["C_Framing"] = 0.7
	catcher.z_abilities_snapshot["C_GameCall"] = 0.5
	var defense: Dictionary = {
		"fielders": [{"record": catcher, "position": 2}],
	}
	var cache: Dictionary = PSPlateAppearanceCoordinator.create_game_cache()
	var first: Dictionary = PSPlateAppearanceCoordinator._build_precomp(
		batter,
		pitcher,
		defense,
		{},
		false,
		cache
	)
	var first_pitcher_z: Dictionary = first.get("pitcher_z", {}) as Dictionary
	first_pitcher_z["Pit_KCreate"] = -999.0
	var second: Dictionary = PSPlateAppearanceCoordinator._build_precomp(
		batter,
		pitcher,
		defense,
		{},
		false,
		cache
	)

	assert_bool(is_same(first.get("batter_z"), second.get("batter_z"))).is_true()
	assert_bool(is_same(first.get("catcher_z"), second.get("catcher_z"))).is_true()
	assert_bool(is_same(first.get("pitcher_z"), second.get("pitcher_z"))).is_false()
	assert_float(float((second.get("pitcher_z", {}) as Dictionary).get("Pit_KCreate", 0.0))).is_greater(-10.0)
	assert_int((cache.get(PSPlateAppearanceCoordinator.CACHE_BATTER_Z_VIEWS, {}) as Dictionary).size()).is_equal(1)
	assert_int((cache.get(PSPlateAppearanceCoordinator.CACHE_PITCHER_Z_VIEWS, {}) as Dictionary).size()).is_equal(1)
	assert_int((cache.get(PSPlateAppearanceCoordinator.CACHE_CATCHER_Z_VIEWS, {}) as Dictionary).size()).is_equal(1)
	assert_bool(is_same(defense.get("catcher", null), catcher)).is_true()


func test_contact_quality_preserves_matchup_balance_when_both_levels_drop() -> void:
	var old_seed: int = Rng.current_seed
	var old_state: int = Rng.generator.state
	var baseline_ev: float = _contact_quality_average_ev(0.0, 0.0)
	var weak_batter_ev: float = _contact_quality_average_ev(-0.8, 0.0)
	var weak_pitcher_ev: float = _contact_quality_average_ev(0.0, -0.8)
	var lower_level_ev: float = _contact_quality_average_ev(-0.8, -0.8)
	Rng.current_seed = old_seed
	Rng.generator.seed = old_seed
	Rng.generator.state = old_state

	print("LEVEL_EV base=%.2f weak_bat=%.2f weak_pit=%.2f both=%.2f" % [
		baseline_ev, weak_batter_ev, weak_pitcher_ev, lower_level_ev,
	])
	# 向きは保つ (弱い打者は打球が弱く、弱い投手は打たれる)。
	assert_float(weak_batter_ev).is_less(baseline_ev - 0.5)
	assert_float(weak_pitcher_ev).is_greater(baseline_ev + 0.5)
	# ⚠️ **片側応答には上限がある** (2026-08-17 の対戦優位圧縮)。以前はここが「2.0 mph 超」の
	# 下限だったが、能力差が結果へ効きすぎる問題を直すために上限側の不変条件へ置き換えた。
	# 極端なミスマッチでも打球品質が青天井にならないことを固定する。
	assert_float(weak_batter_ev).override_failure_message(
		"打者が弱いときの打球品質の落ち込みが飽和していない"
	).is_greater(baseline_ev - 3.2)
	assert_float(weak_pitcher_ev).override_failure_message(
		"投手が弱いときの打球品質の伸びが飽和していない"
	).is_less(baseline_ev + 3.2)
	# レベル不変性は圧縮を差分に掛けたことで構造的に成立するので、許容を 1.5 → 0.6 へ詰める。
	assert_float(absf(lower_level_ev - baseline_ev)).override_failure_message(
		"投打が同じだけ弱くなったときに打球品質の基準が移動している"
	).is_less(0.6)
	# 片側項を contact_delta 基準にしたぶん対称性も改善するので 1.5 → 1.0 へ詰める。
	assert_float(absf(
		(baseline_ev - weak_batter_ev) - (weak_pitcher_ev - baseline_ev)
	)).override_failure_message(
		"打者低下と投手低下の打球品質への寄与が非対称"
	).is_less(1.0)


# 対戦優位の天井は**投打で非対称** (打者優位側 0.80 / 投手優位側 0.40)。
# 大きなミスマッチでだけ差が出て、±0.8σ 程度の通常域では対称のまま
# (test_contact_quality_preserves_matchup_balance_when_both_levels_drop が固定している)。
# 同じ天井に戻すと、本塁打王を実勢へ戻したときに規定 ERA 1点台の投手が増えすぎる。
func test_contact_quality_matchup_ceiling_is_asymmetric_for_large_mismatches() -> void:
	var old_seed: int = Rng.current_seed
	var old_state: int = Rng.generator.state
	var baseline_ev: float = _contact_quality_average_ev(0.0, 0.0)
	var batter_edge_ev: float = _contact_quality_average_ev(0.0, -2.5)
	var pitcher_edge_ev: float = _contact_quality_average_ev(-2.5, 0.0)
	Rng.current_seed = old_seed
	Rng.generator.seed = old_seed
	Rng.generator.state = old_state

	var batter_swing: float = batter_edge_ev - baseline_ev
	var pitcher_swing: float = baseline_ev - pitcher_edge_ev
	print("ASYM_EV base=%.2f batter_swing=%.2f pitcher_swing=%.2f" % [
		baseline_ev, batter_swing, pitcher_swing,
	])
	assert_float(batter_swing).override_failure_message(
		"大きなミスマッチで打者優位側の天井が投手優位側より高くなっていない"
	).is_greater(pitcher_swing + 1.0)
	# 打者優位側にも天井はある (青天井にしない)。
	assert_float(batter_swing).is_less(8.0)


func test_contact_quality_caps_elite_matchup_tails() -> void:
	var old_seed: int = Rng.current_seed
	var old_state: int = Rng.generator.state
	var baseline_ev: float = _contact_quality_average_ev(0.0, 0.0)
	var elite_batter_ev: float = _contact_quality_average_ev(3.0, 0.0)
	var elite_pitcher_ev: float = _contact_quality_average_ev(0.0, 3.0)
	Rng.current_seed = old_seed
	Rng.generator.seed = old_seed
	Rng.generator.state = old_state

	var batter_gain: float = elite_batter_ev - baseline_ev
	var pitcher_reduction: float = baseline_ev - elite_pitcher_ev
	print("ELITE_EV base=%.2f batter=%.2f pitcher=%.2f gain=%.2f reduction=%.2f" % [
		baseline_ev, elite_batter_ev, elite_pitcher_ev, batter_gain, pitcher_reduction,
	])
	assert_float(batter_gain).is_greater(2.0)
	assert_float(batter_gain).override_failure_message(
		"最上位打者の打球品質差が飽和せず拡大している"
	).is_less(7.0)
	assert_float(pitcher_reduction).is_greater(2.0)
	assert_float(pitcher_reduction).override_failure_message(
		"球威にK/BB差が重なるエース帯の打球抑制が過大"
	).is_less(5.0)


func test_tto_penalty_flows_into_pa_weights() -> void:
	var starter: PSPlayerSeasonRecord = _pitcher(803, "TTO Starter", 0.4)
	starter.role = "starter"
	var fresh_usage: Dictionary = PSPitcherUsageModel.create_outing(starter, PSPitcherUsageModel.ROLE_STARTER)
	var tto_usage: Dictionary = PSPitcherUsageModel.create_outing(starter, PSPitcherUsageModel.ROLE_STARTER)
	tto_usage["batters_faced"] = 18
	var fresh_context: Dictionary = PSPitcherUsageModel.plate_context(starter, fresh_usage)
	var tto_context: Dictionary = PSPitcherUsageModel.plate_context(starter, tto_usage)
	assert_int(int(tto_context.get("pitcher_tto_penalty", 0))).is_greater(0)
	var cached_arsenal: Dictionary = fresh_usage.get(
		PSPitcherUsageModel.USAGE_ARSENAL_CACHE_KEY,
		{}
	) as Dictionary
	PSPitcherUsageModel.plate_context(starter, fresh_usage)
	assert_bool(is_same(
		cached_arsenal,
		fresh_usage.get(PSPitcherUsageModel.USAGE_ARSENAL_CACHE_KEY, {})
	)).is_true()

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
	var cached_usage: Dictionary = PSPitcherUsageModel.create_outing(
		high_stamina,
		PSPitcherUsageModel.ROLE_STARTER
	)
	for pitches in [50, 95, 115]:
		assert_float(
			PSFatigueCalculator.factor_for_outing(high_stamina, cached_usage, pitches)
		).is_equal_approx(
			PSFatigueCalculator.factor_for_pitcher(high_stamina, false, pitches),
			0.000001
		)
	assert_float(PSFatigueCalculator.factor_for_pitcher(high_stamina, false, 130)).is_equal(0.0)
	assert_float(PSFatigueCalculator.start_threshold(high_stamina, true)).is_equal(
		PSFatigueCalculator.start_threshold(low_stamina, true))
	assert_int(PSPitcherUsageModel.short_relief_target_pitches(high_stamina)).is_equal(
		PSPitcherUsageModel.short_relief_target_pitches(low_stamina))
	assert_int(PSPitcherUsageModel.long_relief_target_pitches(high_stamina)).is_greater(
		PSPitcherUsageModel.long_relief_target_pitches(low_stamina))


func _contact_quality_average_ev(batter_delta: float, pitcher_delta: float) -> float:
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
			"batter_contact_z": PSContactQualityModel.BAT_CONTACT_CURVE_CENTER + batter_delta,
			"batter_gap_z": PSContactQualityModel.BAT_GAP_CURVE_CENTER + batter_delta,
			"batter_hr_z": PSContactQualityModel.BAT_HR_CURVE_CENTER + batter_delta,
			"batter_avoid_k_z": PSContactQualityModel.BAT_AVOID_K_CURVE_CENTER + batter_delta,
			"pitcher_stuff_z": PSContactQualityModel.PIT_STUFF_CURVE_CENTER + pitcher_delta,
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


# 投手の打順で代打を立てられないとき、打席に立つのは**現在マウンドにいる投手**。
# 代打は打順スロットを置き換えず先発のレコードが残るので、ここを取り違えると
# 既に降板した先発が打席に立つ。先発がまだ投げているなら従来どおり先発が打つ。
func test_pitcher_spot_batter_is_the_current_pitcher_after_the_starter_left() -> void:
	var starter: PSPlayerSeasonRecord = _pitcher(301, "Starter", 0.4)
	var reliever: PSPlayerSeasonRecord = _pitcher(302, "Reliever", 0.2)
	var bases: Array = [null, null, null]
	var setup: Dictionary = {
		"team_id": 1,
		"dh_enabled": false,
		"starter_pitcher": starter,
		"pitcher": reliever,
		"starter_relieved": true,
		"batters": [starter],
		"bench": [],  # 代打候補なし
		"relievers": [],
	}

	var batter: PSPlayerSeasonRecord = PSInGameSubstitutions.maybe_select_pinch_hitter(
		setup, starter, 0, 8, {}, 7, "top", bases, 1, 0
	)

	assert_object(batter).is_not_null()
	assert_int(batter.player_id).is_equal(reliever.player_id)

	# 先発が降板していなければ打者は先発のまま (代打不成立時の従来挙動)。
	setup["pitcher"] = starter
	setup["starter_relieved"] = false
	var still_pitching: PSPlayerSeasonRecord = PSInGameSubstitutions.maybe_select_pinch_hitter(
		setup, starter, 0, 8, {}, 7, "top", bases, 1, 0
	)
	assert_int(still_pitching.player_id).is_equal(starter.player_id)


# 代走は「終盤 × 僅差 × 足の遅い走者 × 明確に速い控え」の全部が揃ったときだけ出す。
# 打順スロットは代走が引き継ぎ、控えからは外れる。どれか 1 つでもゲートが外れると
# 「毎回代走」か「一度も代走が出ない」のどちらかになる (実装前は後者だった)。
func test_pinch_runner_replaces_a_slow_runner_only_in_a_close_late_game() -> void:
	var slow: PSPlayerSeasonRecord = _fielder(901, "Slow", -0.6)
	var fast: PSPlayerSeasonRecord = _fielder(902, "Fast", 0.9)
	var spare: PSPlayerSeasonRecord = _fielder(903, "Spare", -0.2)
	var close_game: Dictionary = {
		"away_team_id": 1, "home_team_id": 2, "away_score": 3, "home_score": 4,
	}
	var make_setup: Callable = func(runner: PSPlayerSeasonRecord) -> Dictionary:
		return {
			"team_id": 1,
			"batters": [runner, spare],
			"bench": [fast, spare],
			"fielders": [{"record": runner, "position": 3}],
		}

	var setup: Dictionary = make_setup.call(slow)
	var bases: Array = [slow, null, null]
	var applied: Dictionary = PSInGameSubstitutions.maybe_apply_pinch_runner(setup, bases, 8, close_game)

	assert_bool(applied.is_empty()).is_false()
	assert_int((applied["runner"] as PSPlayerSeasonRecord).player_id).is_equal(fast.player_id)
	assert_int(int(applied["base_index"])).is_equal(0)
	assert_int(((setup["batters"] as Array)[0] as PSPlayerSeasonRecord).player_id).is_equal(fast.player_id)
	assert_bool((setup["bench"] as Array).has(fast)).is_false()

	# 序盤は出さない。
	var early: Dictionary = make_setup.call(slow)
	assert_bool(PSInGameSubstitutions.maybe_apply_pinch_runner(early, [slow, null, null], 5, close_game).is_empty()).is_true()

	# 点差が開いていたら出さない。
	var blowout: Dictionary = make_setup.call(slow)
	var blowout_game: Dictionary = {
		"away_team_id": 1, "home_team_id": 2, "away_score": 1, "home_score": 9,
	}
	assert_bool(PSInGameSubstitutions.maybe_apply_pinch_runner(blowout, [slow, null, null], 8, blowout_game).is_empty()).is_true()

	# もともと速い走者には代走を出さない。
	var quick: PSPlayerSeasonRecord = _fielder(904, "Quick", 0.8)
	var quick_setup: Dictionary = make_setup.call(quick)
	assert_bool(PSInGameSubstitutions.maybe_apply_pinch_runner(quick_setup, [quick, null, null], 8, close_game).is_empty()).is_true()


# 継承走者の生還は降板済み投手の失点として付き、ホールド判定に使う exit_lead も動く。
# 一方で登板範囲 (end_inning / end_half / end_event_index) は降板時点のまま。
# ここを伸ばすと試合ログ上の登板イニングが実際より長く見える。
func test_inherited_run_charges_departed_pitcher_without_extending_the_outing() -> void:
	var outing: Dictionary = _outing(11, 1, PSPitcherUsageModel.ROLE_SHORT_RELIEF, 10, 12, 3, 2, 2, 1, 0)
	outing["end_inning"] = 7
	outing["end_half"] = "top"
	var game_result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 4,
		"home_score": 2,
		"next_play_event_index": 40,
		"pitcher_outings": [outing],
	}

	PSGameLoop.add_run_to_pitcher_outing(game_result, 1, 11, 1, "bottom", 1)

	var updated: Dictionary = (game_result.get("pitcher_outings", []) as Array)[0] as Dictionary
	assert_int(int(updated.get("runs", 0))).is_equal(1)
	assert_int(int(updated.get("earned_runs", 0))).is_equal(1)
	assert_int(int(updated.get("end_inning", 0))).is_equal(7)
	assert_str(str(updated.get("end_half", ""))).is_equal("top")
	assert_int(int(updated.get("end_event_index", 0))).is_equal(12)
	assert_int(int(updated.get("exit_lead", 0))).is_equal(1)


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


func test_all_active_relievers_are_available_beyond_six_role_slots() -> void:
	var pool: Array = []
	for i in range(9):
		pool.append(_pitcher(330 + i, "Relief %d" % i, 0.9 - float(i) * 0.1))

	var selected: Array = PSRotationPlanner.select_relievers_for_innings(pool, [], 0, {})
	var ids: Dictionary = {}
	for record_value in selected:
		ids[(record_value as PSPlayerSeasonRecord).player_id] = true

	assert_int(selected.size()).is_equal(9)
	for pitcher_value in pool:
		assert_bool(ids.has((pitcher_value as PSPlayerSeasonRecord).player_id)).is_true()


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


func test_promoted_reliever_gets_first_low_leverage_opportunity() -> void:
	var established: PSPlayerSeasonRecord = _pitcher(370, "Established", 1.0)
	var callup: PSPlayerSeasonRecord = _pitcher(371, "Callup", 0.0)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [established, callup],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {},
		"callup_appearance_baseline": {str(callup.player_id): 0},
		"game_day": 30,
		"team_games_played_before": 20,
	}
	var game_result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 1,
		"home_score": 7,
	}

	var selected: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(
		setup, 6, game_result, false
	)
	assert_object(selected).is_not_null()
	assert_int(selected.player_id).is_equal(callup.player_id)


# 出場シェアが「シェアどおりの先発数」と「均等に散った休養日」の両方を満たすか。
# 規定打席ラインが share 0.735 (先発 105 試合) なので、ここがズレると到達者数が動く。
func test_starter_share_produces_proportional_and_evenly_spread_starts() -> void:
	for share_value in [1.0, 0.9, 0.72, 0.5]:
		var share: float = float(share_value)
		var starts: int = 0
		var longest_rest_streak: int = 0
		var rest_streak: int = 0
		for game_number in range(1, 144):
			if PSDefenseAlignmentService.share_index_for_game([share, 1.0 - share], game_number) == 0:
				starts += 1
				rest_streak = 0
			else:
				rest_streak += 1
				longest_rest_streak = maxi(longest_rest_streak, rest_streak)
		assert_int(starts).override_failure_message(
			"share %.2f should produce round(143*share) starts, got %d" % [share, starts]
		).is_equal(int(round(143.0 * share)))
		# シェアどおりに散っていれば連続休養は最大 1 試合 (share >= 0.5 の範囲)。
		assert_int(longest_rest_streak).is_less_equal(1)

	# 3 人併用でもシェアの比どおりに配分される (最大剰余法の一般形)。
	var counts: Array = [0, 0, 0]
	for game_number in range(1, 144):
		var index: int = PSDefenseAlignmentService.share_index_for_game([0.6, 0.25, 0.15], game_number)
		counts[index] = int(counts[index]) + 1
	assert_int(int(counts[0])).is_between(84, 88)
	assert_int(int(counts[1])).is_between(34, 38)
	assert_int(int(counts[2])).is_between(19, 23)


# 打順は DH の有無 × 相手先発の左右 で保存され、対左を保存していないチームは基本打順へ落ちる。
# 「対左を作ったのに使われない」「対左を作っていないのに空の打順が使われる」の両方を防ぐ。
func test_lineup_is_stored_per_opponent_hand_with_fallback() -> void:
	var season: PSSeason = PSSeason.new()
	var team_id: int = 4242
	var base_order: Array = [{"slot": 1, "position": 3, "player_id": 11}]
	var versus_left: Array = [{"slot": 1, "position": 3, "player_id": 22}]

	season.set_lineup(team_id, true, {"batting_order": base_order})
	# 対左が未保存なら基本打順へフォールバックする。
	assert_bool(season.has_lineup(team_id, true, "L")).is_false()
	var fallback: Array = season.get_lineup(team_id, true, "L").get("batting_order", []) as Array
	assert_int(int((fallback[0] as Dictionary).get("player_id", 0))).is_equal(11)

	season.set_lineup(team_id, true, {"batting_order": versus_left}, "L")
	assert_bool(season.has_lineup(team_id, true, "L")).is_true()
	var left_order: Array = season.get_lineup(team_id, true, "L").get("batting_order", []) as Array
	assert_int(int((left_order[0] as Dictionary).get("player_id", 0))).is_equal(22)
	# 右投手 (既定) と DH 無しは別枠のまま。
	var right_order: Array = season.get_lineup(team_id, true, "R").get("batting_order", []) as Array
	assert_int(int((right_order[0] as Dictionary).get("player_id", 0))).is_equal(11)
	assert_bool(season.has_lineup(team_id, false, "L")).is_false()


# **DH は既定では枠を持たない。** 2026 パ・リーグの実測では DH 先発の 2/3 を守備もする選手が
# 取っており、「その日守備で先発しない中の打撃最良」が入るのが実際の埋まり方
# ([[project_qualified_batter_count]])。AI が勝手に DH 定位置を作る実装へ戻る退行と、
# ユーザーが指定した専任DH が組み直しで消える退行の両方を検出する。
func test_dh_is_automatic_unless_the_user_designates_one() -> void:
	var aptitude_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS
	var fielders: Array = []
	var base_slots: Array = []
	var next_id: int = 600
	for position_row in [2, 6, 8, 4, 5, 3, 7, 9]:
		var position: int = int(position_row)
		var starter: PSPlayerSeasonRecord = _fielder(next_id, "Starter %d" % position, 1.0)
		next_id += 1
		starter.position = position
		starter.position_aptitudes_snapshot = {str(aptitude_keys.get(position, "catcher")): 100}
		var sub: PSPlayerSeasonRecord = _fielder(next_id, "Sub %d" % position, -0.5)
		next_id += 1
		sub.position = position
		sub.position_aptitudes_snapshot = {str(aptitude_keys.get(position, "catcher")): 90}
		fielders.append(starter)
		fielders.append(sub)
		base_slots.append({"record": starter, "position": position})
	# 守備スタメンから溢れた打撃最良の選手。守備適性は普通にあるが、この日は守らない。
	var surplus: PSPlayerSeasonRecord = _fielder(next_id, "Surplus Bat", 2.5)
	surplus.position = 3
	surplus.position_aptitudes_snapshot = {"first": 100}
	fielders.append(surplus)

	var usage: Dictionary = PSTeamSetupBuilder.build_ai_fielder_usage(fielders, base_slots, {}, true)
	assert_bool((usage.get("position_slots", {}) as Dictionary).has("10")).override_failure_message(
		"DH must not get a persisted depth chart"
	).is_false()

	# その日守備で先発しない中の打撃最良が DH に入る。
	var designated: PSPlayerSeasonRecord = PSTeamSetupBuilder.select_designated_hitter(
		fielders, base_slots, {}, {}
	)
	assert_int(designated.player_id).is_equal(surplus.player_id)

	# ユーザーが専任DHを指定した (share_locked) 枠だけは AI 既定生成でも残り、
	# その選手は守備枠の併用相手に取られない。
	var locked_usage: Dictionary = {"position_slots": {"10": PSDefenseAlignmentService.make_slot(
		[{"player_id": surplus.player_id, "share": 0.9}], [], true
	)}}
	var kept: Dictionary = PSTeamSetupBuilder.build_ai_fielder_usage(
		fielders, base_slots, locked_usage, true
	)
	var kept_slots: Dictionary = kept.get("position_slots", {}) as Dictionary
	assert_int(PSDefenseAlignmentService.slot_starter_id(kept_slots.get("10", {}) as Dictionary)) 		.override_failure_message("a user-designated DH must survive the AI rebuild") 		.is_equal(surplus.player_id)
	for position_row in [2, 6, 8, 4, 5, 3, 7, 9]:
		var slot: Dictionary = kept_slots.get(str(int(position_row)), {}) as Dictionary
		for candidate_value in PSDefenseAlignmentService.slot_candidates(slot):
			assert_int(int((candidate_value as Dictionary).get("player_id", 0))).override_failure_message(
				"the designated DH must not be reused as a fielding platoon partner"
			).is_not_equal(surplus.player_id)


# シェアは**リーグ相対**で決まり、控えの質は副次補正 (SHARE_GAP_*) の幅しか動かさない。
# 旧方式 (控えとの能力差が主役) に戻ると全枠が上限へ張り付いて規定到達者が膨らむ。
func test_starter_share_is_league_relative_not_bench_relative() -> void:
	var starter: PSPlayerSeasonRecord = _fielder(520, "Starter", 1.0)
	var weak_sub: PSPlayerSeasonRecord = _fielder(521, "Weak Sub", -1.5)
	var strong_sub: PSPlayerSeasonRecord = _fielder(522, "Strong Sub", 0.9)
	var better_starter: PSPlayerSeasonRecord = _fielder(523, "Better Starter", 2.2)

	var share_with_weak_sub: float = PSTeamSetupBuilder._starter_share_for(starter, weak_sub, 3)
	var share_with_strong_sub: float = PSTeamSetupBuilder._starter_share_for(starter, strong_sub, 3)
	var gap_band: float = PSTeamSetupBuilder.SHARE_GAP_MAX - PSTeamSetupBuilder.SHARE_GAP_MIN
	assert_float(share_with_weak_sub - share_with_strong_sub).override_failure_message(
		"bench quality must not move the share by more than the gap correction band"
	).is_between(0.0, gap_band + 0.001)

	# 同じ控えなら、リーグ相対で上の打者ほどシェアが高い。
	assert_float(
		PSTeamSetupBuilder._starter_share_for(better_starter, weak_sub, 3)
	).is_greater(share_with_weak_sub)
	# 控えが居ない枠は休ませようがないので全試合。
	assert_float(PSTeamSetupBuilder._starter_share_for(starter, null, 3)).is_equal(1.0)


func test_promoted_fielder_gets_one_automatic_start_without_rewriting_usage() -> void:
	var starter: PSPlayerSeasonRecord = _fielder(380, "Starter", 1.0)
	var callup: PSPlayerSeasonRecord = _fielder(381, "Callup", 0.0)
	var usage: Dictionary = {"position_slots": {"3": PSDefenseAlignmentService.make_slot(
		[{"player_id": starter.player_id, "share": 1.0}]
	)}, "ai_generated": true}

	var game_usage: Dictionary = PSTeamSetupBuilder._usage_with_callup_start(
		usage, [starter, callup], {str(callup.player_id): 0}
	)
	var slot: Dictionary = (game_usage.get("position_slots", {}) as Dictionary).get("3", {}) as Dictionary
	var saved_slot: Dictionary = (usage.get("position_slots", {}) as Dictionary).get("3", {}) as Dictionary

	# その試合だけ昇格選手が先発し、定位置選手は share 0 の先頭に残る (保存側は無改変)。
	assert_int(int(PSDefenseAlignmentService.ordered_candidate_ids_for_game(slot, 1)[0])).is_equal(callup.player_id)
	assert_int(PSDefenseAlignmentService.slot_starter_id(slot)).is_equal(starter.player_id)
	assert_int(PSDefenseAlignmentService.slot_candidates(saved_slot).size()).is_equal(1)
	callup.batter_stats.games = 1
	var after_appearance: Dictionary = PSTeamSetupBuilder._usage_with_callup_start(
		usage, [starter, callup], {str(callup.player_id): 0}
	)
	assert_bool(after_appearance == usage).is_true()


func test_callup_start_override_reaches_the_final_defensive_alignment() -> void:
	var season: PSSeason = PSSeason.new()
	var team: PSTeam = GameDb.teams[0] as PSTeam
	var old_auto_lineup: bool = team.auto_lineup
	team.auto_lineup = true
	var aptitude_keys: Dictionary = PSPlayerValueEvaluator.POSITION_APTITUDE_KEYS
	var fielders: Array = []
	var position_slots: Dictionary = {}
	var callup: PSPlayerSeasonRecord = null
	var next_id: int = 390
	for position_row in [2, 6, 8, 4, 5, 3, 7, 9]:
		var position: int = int(position_row)
		var starter: PSPlayerSeasonRecord = _fielder(next_id, "Starter %d" % position, 0.5)
		next_id += 1
		starter.position = position
		starter.position_aptitudes_snapshot = {
			str(aptitude_keys.get(position, "catcher")): 100,
		}
		var sub: PSPlayerSeasonRecord = _fielder(next_id, "Sub %d" % position, 0.0)
		next_id += 1
		sub.position = position
		sub.position_aptitudes_snapshot = {
			str(aptitude_keys.get(position, "catcher")): 90,
		}
		fielders.append(starter)
		fielders.append(sub)
		# share 1.0 = 定位置選手が全試合。昇格選手の 1 試合だけがこれを上書きできるかを見る。
		position_slots[str(position)] = PSDefenseAlignmentService.make_slot([
			{"player_id": starter.player_id, "share": 1.0},
			{"player_id": sub.player_id, "share": 0.0},
		])
		if position == 3:
			callup = sub
	season.set_fielder_usage(team.id, {
		"position_slots": position_slots,
		"ai_generated": true,
	})
	season.record_callup_appearance_baseline(team.id, callup.player_id, 0)
	var pitcher: PSPlayerSeasonRecord = _pitcher(499, "Starter Pitcher", 0.5)
	pitcher.role = "starter"
	var setup: Dictionary = PSTeamSetupBuilder.build_setup_from_auto(
		season, team.id, true, fielders, pitcher, 0
	)
	team.auto_lineup = old_auto_lineup

	assert_bool(bool(setup.get("ok", false))).is_true()
	var selected_ids: Array = []
	for slot_row in setup.get("fielders", []) as Array:
		var selected: PSPlayerSeasonRecord = (slot_row as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if selected != null:
			selected_ids.append(selected.player_id)
	assert_bool(selected_ids.has(callup.player_id)).is_true()


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


# --- 先発ローテ (月曜始まりの週で序列順に回す) -------------------------------
# カレンダーは day 1 = 2026-03-31 (火) 固定。day 6 が日曜、day 7 が翌週の月曜になる。

func _rotation_pitchers(count: int) -> Array:
	var pitchers: Array = []
	for i in range(count):
		var starter: PSPlayerSeasonRecord = _pitcher(480 + i, "Starter %d" % i, 1.2 - float(i) * 0.1)
		starter.role = "starter"
		pitchers.append(starter)
	return pitchers


func _rotation_season(day: int, last_starts: Dictionary, team_id: int = 1) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.calendar_start_date = "2026-03-31"
	season.current_day = day
	season.set_rotation(team_id, {
		"pitcher_ids": [480, 481, 482, 483, 484, 485],
		"auto_generated": true,
		"last_start_day_by_pitcher": last_starts,
	})
	return season


func _relievers(count: int) -> Array:
	var relievers: Array = []
	for i in range(count):
		var reliever: PSPlayerSeasonRecord = _pitcher(560 + i, "Relief %d" % i, 0.9 - float(i) * 0.1)
		reliever.role = "reliever"
		relievers.append(reliever)
	return relievers


func test_rotation_follows_order_within_the_week() -> void:
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(3, {"480": 1, "481": 2})

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(482)
	assert_str(str(decision.get("reason", ""))).is_equal("rotation")


func test_short_week_skips_lowest_ranked_and_next_week_restarts_from_ace() -> void:
	# 週5試合 (木が休み) の週は序列1〜5だけが投げ、6番手は登板しないまま週が終わる。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(8, {"480": 1, "481": 2, "482": 3, "483": 5, "484": 6})

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	# 翌週の火曜はまた序列1番手から。6番手を待って全体がずれない = エースの曜日が固定される。
	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(480)
	assert_str(str(decision.get("reason", ""))).is_equal("rotation")


func test_skipped_starter_returns_on_the_day_freed_by_the_short_week() -> void:
	# 前週が5試合 (木が休み) で6番手 (485) が飛んだ状態。今週は火水を1・2番手が投げ、
	# 木曜は中6日が空いていないので、飛ばされていた6番手がその枠に戻る。
	# = 他の投手の登板曜日を崩さずに埋まる。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(
		10, {"480": 8, "481": 9, "482": 4, "483": 5, "484": 6}
	)

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(485)
	assert_str(str(decision.get("reason", ""))).is_equal("rotation")


func test_seventh_game_of_week_uses_recovered_ace_on_short_rest() -> void:
	# 祝日月曜を含む週7試合: 6人を使い切った日曜は、疲労が抜けたエースを中5日で立てる。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(
		13, {"480": 7, "481": 8, "482": 9, "483": 10, "484": 11, "485": 12}
	)
	(pitchers[0] as PSPlayerSeasonRecord).fatigue = 20

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(480)
	assert_str(str(decision.get("reason", ""))).is_equal("short_rest")

	# 疲労が残っていれば中5日は通常運用では選ばれず、他に立てる者がいない緩和パス送りになる。
	(pitchers[0] as PSPlayerSeasonRecord).fatigue = 100
	var tired: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)
	assert_str(str(tired.get("reason", ""))).is_equal("min_rest")


func test_opening_rotation_phase_differs_by_team() -> void:
	# 全球団が開幕から一斉に序列順で回すと、エースの登板曜日が全球団で揃って
	# 「毎週その曜日は全カードがエース対決」になる。球団ごとの phase でこれをずらす。
	var first_by_phase: Dictionary = {}
	for team_id in [1, 2, 3, 4]:
		var pitchers: Array = _rotation_pitchers(6)
		var season: PSSeason = _rotation_season(1, {}, team_id)
		var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, pitchers)
		first_by_phase[team_id] = (decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id
	# ROTATION_PHASE_SPREAD=4 なので開幕投手は序列1〜4番手の4通りに分かれる。
	var distinct: Dictionary = {}
	for value in first_by_phase.values():
		distinct[value] = true
	assert_int(distinct.size()).is_equal(PSRotationPlanner.ROTATION_PHASE_SPREAD)


func test_spot_relief_starter_covers_a_day_the_rotation_cannot() -> void:
	# 週7試合で6人を使い切った日。ローテを中5日で使い回す前に、ブルペンの軸以外から代役を立てる。
	var pitchers: Array = _rotation_pitchers(6)
	var relievers: Array = _relievers(6)
	var season: PSSeason = _rotation_season(
		20, {"480": 14, "481": 15, "482": 16, "483": 17, "484": 18, "485": 19}
	)

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers, relievers)

	assert_str(str(decision.get("reason", ""))).is_equal("spot_relief")
	# 抑え/セットアッパー相当 (能力上位3人) は抜かない。
	var picked: int = (decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id
	assert_array([560, 561, 562]).not_contains(picked)

	# 一軍に7人目の先発がいれば、ブルペンより先にそちらを使う。
	var with_seventh: Array = _rotation_pitchers(7)
	var seventh: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, with_seventh, relievers)
	assert_int((seventh.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(486)
	assert_str(str(seventh.get("reason", ""))).is_equal("spot_starter")

	# 谷間候補も先発台帳に従う。前日に先発した7番手を疲労値だけで再登板させない。
	var stored: Dictionary = season.get_rotation(1).duplicate(true)
	var last_starts: Dictionary = (stored.get("last_start_day_by_pitcher", {}) as Dictionary).duplicate(true)
	last_starts["486"] = 19
	stored["last_start_day_by_pitcher"] = last_starts
	season.set_rotation(1, stored)
	var recent_seventh: Dictionary = PSRotationPlanner.resolve_rotation_decision(
		season, 1, with_seventh, relievers
	)
	assert_str(str(recent_seventh.get("reason", ""))).is_equal("spot_relief")
	assert_int((recent_seventh.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_not_equal(486)


func test_stretch_run_advances_the_ace_on_short_rest() -> void:
	# 9月以降は、疲労が抜けているエースを中5日で前倒しする (day 159 = 2026-09-05)。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(159, {"480": 153, "481": 152})
	(pitchers[0] as PSPlayerSeasonRecord).fatigue = 10

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(480)
	assert_str(str(decision.get("reason", ""))).is_equal("stretch_run")

	# 疲労が残っていれば前倒ししない (中6日空けている 481 が通常どおり投げる)。
	(pitchers[0] as PSPlayerSeasonRecord).fatigue = 60
	var rested: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)
	assert_int((rested.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(481)


func test_postseason_keeps_the_short_rotation_on_short_rest() -> void:
	# 短期決戦は序列上位だけで回す。中4日のエースを、休養十分の6番手より優先する。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(
		20, {"480": 15, "481": 16, "482": 17, "483": 18, "484": 19, "485": 5}
	)

	var postseason: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers, [], true)
	assert_int((postseason.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(480)
	assert_str(str(postseason.get("reason", ""))).is_equal("postseason")

	# ペナントでは同じ状況でも休養十分の6番手を立てる。
	var pennant: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)
	assert_int((pennant.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(485)


func test_reorder_auto_rotation_follows_performance_but_not_manual_order() -> void:
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(30, {})
	# 1番手が不振、6番手が好調という評価。
	var scores: Dictionary = {480: 50.0, 481: 80.0, 482: 78.0, 483: 76.0, 484: 74.0, 485: 82.0}

	assert_bool(PSRotationPlanner.reorder_auto_rotation(season, 1, pitchers, scores)).is_true()
	assert_array(season.get_rotation(1).get("pitcher_ids", [])).is_equal([485, 481, 482, 483, 484, 480])

	# 手動編成は利用者の意図なので組み替えない。
	var manual: PSSeason = _rotation_season(30, {})
	var stored: Dictionary = manual.get_rotation(1).duplicate(true)
	stored["auto_generated"] = false
	manual.set_rotation(1, stored)
	assert_bool(PSRotationPlanner.reorder_auto_rotation(manual, 1, pitchers, scores)).is_false()


func test_rotation_is_unaffected_by_a_postponed_game() -> void:
	# 雨天順延を想定: 週の途中の試合が消えて間が空いても、次の試合日は序列の続きから始まる。
	# 将来の登板予定を保存しない設計なので、順延時に作り直すべき状態が存在しない。
	var pitchers: Array = _rotation_pitchers(6)
	var season: PSSeason = _rotation_season(4, {"480": 1, "481": 2})

	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, 1, pitchers)

	assert_int((decision.get("pitcher", null) as PSPlayerSeasonRecord).player_id).is_equal(482)


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


# 直球(ストレート)は投手リーン・球種数・seed に関わらず全投手がちょうど1本持つ。
# ゴロ/ムーブ系はかつて直球そのものがシンカーに差し替わっていたため、その回帰も兼ねる。
func test_assign_types_always_includes_exactly_one_straight() -> void:
	for lean in [-1.5, -0.5, -0.3, 0.0, 0.3, 1.5]:
		for count in range(1, PSPitchTypes.GENERATED_COUNT_MAX + 1):
			for seed_value in [0, 1, 2, 3, 4, 5, 12345]:
				var types: Array = PSPitchTypes.assign_types(count, float(lean), seed_value)
				assert_int(types.size()).is_equal(count)
				var straight: int = 0
				var seen: Dictionary = {}
				for type_value in types:
					if str(type_value) == PSPitchTypes.FOUR_SEAM:
						straight += 1
					seen[str(type_value)] = true
				assert_int(straight).override_failure_message(
					"lean=%s count=%d seed=%d の直球が %d 本" % [str(lean), count, seed_value, straight]
				).is_equal(1)
				# 同じ球種が2本並ばないこと (直球が変化球候補にも入っていた場合の重複検出)。
				assert_int(seen.size()).is_equal(count)


# 直球が無い旧データは「代役だった速球系の最良球」を直球へ読み替えて揃える (本数は変えない)。
func test_ensure_straight_retypes_substitute_fastball() -> void:
	var legacy: Array = [
		{"type": PSPitchTypes.CHANGEUP, "mastery": 1.4},
		{"type": PSPitchTypes.SINKER, "mastery": 0.9},
		{"type": PSPitchTypes.TWO_SEAM, "mastery": 0.2},
	]
	var fixed: Array = PSPitchTypes.ensure_straight(legacy)
	assert_int(fixed.size()).is_equal(3)
	assert_str(str((fixed[1] as Dictionary).get("type", ""))).is_equal(PSPitchTypes.FOUR_SEAM)
	assert_float(float((fixed[1] as Dictionary).get("mastery", 0.0))).is_equal_approx(0.9, 0.0001)
	assert_str(str((fixed[0] as Dictionary).get("type", ""))).is_equal(PSPitchTypes.CHANGEUP)
	# 速球系が1本も無ければ最良球を直球にする。
	var no_fastball: Array = PSPitchTypes.ensure_straight([
		{"type": PSPitchTypes.SLIDER, "mastery": 0.3},
		{"type": PSPitchTypes.CURVE, "mastery": 1.1},
	])
	assert_str(str((no_fastball[1] as Dictionary).get("type", ""))).is_equal(PSPitchTypes.FOUR_SEAM)
	# 既に直球があれば何も変えない (冪等)。
	var already: Array = [
		{"type": PSPitchTypes.FOUR_SEAM, "mastery": 0.5},
		{"type": PSPitchTypes.SINKER, "mastery": 1.2},
	]
	assert_array(PSPitchTypes.ensure_straight(already)).is_equal(already)


# ゴロ/ムーブ系は直球に加えて動く速球 (ツーシーム/シンカー) を持ちやすい。
func test_assign_types_movement_lean_keeps_moving_fastball() -> void:
	var with_moving: int = 0
	for seed_value in range(0, 12):
		var types: Array = PSPitchTypes.assign_types(4, -0.8, seed_value)
		if types.has(PSPitchTypes.TWO_SEAM) or types.has(PSPitchTypes.SINKER):
			with_moving += 1
	assert_int(with_moving).is_greater(6)


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


# 試合消化後、両チーム分のスタメン行が season.team_lineup_history へ記録されること
# (9枠・starter_pitcher_id が入っていること)。UI の「スタメン履歴」機能のデータ元。
func test_game_simulation_records_team_lineup_history_for_both_teams() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_save_id: String = SaveContext.active_save_id()

	Rng.set_seed_value(20260729)
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var season: PSSeason = AppState.current_season
	var test_save_id: String = SaveContext.active_save_id()

	var simulation: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
	assert_bool(bool(simulation.get("ok", false))).is_true()
	var result: Dictionary = simulation.get("result", {}) as Dictionary
	var away_team_id: int = int(result.get("away_team_id", 0))
	var home_team_id: int = int(result.get("home_team_id", 0))

	assert_int(season.team_lineup_history.size()).is_equal(2)
	var away_row: Dictionary = {}
	var home_row: Dictionary = {}
	for row_value in season.team_lineup_history:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("team_id", 0)) == away_team_id:
			away_row = row
		elif int(row.get("team_id", 0)) == home_team_id:
			home_row = row

	for row in [away_row, home_row]:
		assert_bool(row.is_empty()).is_false()
		assert_int((row.get("slots", []) as Array).size()).is_equal(9)
		assert_int(int(row.get("starter_pitcher_id", 0))).is_greater(0)
		assert_int(int(row.get("game_index", -1))).is_equal(0)
		assert_int(int(row.get("year", 0))).is_equal(season.year)
		assert_int(int(row.get("season_number", 0))).is_equal(season.season_number)

	assert_int(int(away_row.get("starter_pitcher_id", 0))).is_equal(int(result.get("away_pitcher_id", 0)))
	assert_int(int(home_row.get("starter_pitcher_id", 0))).is_equal(int(result.get("home_pitcher_id", 0)))
	assert_str(str(away_row.get("home_away", ""))).is_equal("away")
	assert_str(str(home_row.get("home_away", ""))).is_equal("home")
	assert_int(int(away_row.get("opponent_id", 0))).is_equal(home_team_id)
	assert_int(int(home_row.get("opponent_id", 0))).is_equal(away_team_id)

	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()


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


# S〜E グレードは**母集団内の相対位置**で決まる。同じ値でも周りが強ければ落ちる、が要件
# (12球団の生レーティングが数点差に収まるため、絶対値の閾値では全球団同じ表示になる)。
func test_strength_grade_is_relative_to_sample() -> void:
	var tight: Array = [68.0, 69.0, 70.0, 71.0, 72.0, 74.0]
	# 数点差しかない母集団でも最上位/最下位はきちんと割れる。
	assert_str(StrengthGrade.from_sample(74.0, tight)).is_equal("S")
	assert_str(StrengthGrade.from_sample(68.0, tight)).is_equal("E")
	assert_str(StrengthGrade.from_sample(70.0, tight)).is_equal("C")
	# 同じ 70 でも、母集団が弱ければ最上位になる。
	assert_str(StrengthGrade.from_sample(70.0, [60.0, 62.0, 64.0, 66.0, 70.0])).is_equal("S")
	# 全球団横並び (ばらつき無し) は無理に段階を付けず中央。
	assert_str(StrengthGrade.from_sample(70.0, [70.0, 70.0, 70.0])).is_equal("C")
	assert_str(StrengthGrade.from_sample(70.0, [])).is_equal("C")


# 将来予測: 成長/衰えの期待値と引退見込みが年齢で単調に効く。
func test_projected_value_falls_with_age() -> void:
	assert_float(Offseason.projected_score_delta(22, 3)).is_greater(0.0)
	assert_float(Offseason.projected_score_delta(30, 3)).is_less(Offseason.projected_score_delta(24, 3))
	assert_float(Offseason.projected_score_delta(38, 3)).is_less(0.0)
	# 引退見込み: 40歳未満は3年後も確実に現役、40代は減っていく。
	assert_float(Offseason.active_survival_chance(30, 3)).is_equal_approx(1.0, 0.001)
	assert_float(Offseason.active_survival_chance(39, 3)).is_less(1.0)
	assert_float(Offseason.active_survival_chance(45, 3)).is_less(Offseason.active_survival_chance(41, 3))
	assert_float(Offseason.active_survival_chance(48, 1)).is_equal_approx(0.0, 0.001)


func test_season_report_data_accumulates_and_survives_serialization() -> void:
	var season: PSSeason = PSSeason.new()
	season.collect_simulation_report_data = true
	season.accumulate_game_report_data({
		"advanced_stats": {
			"players": {
				"10": _report_advanced_record(10, 2, 1.1, 0.4, 0.2, 6),
				"11": _report_advanced_record(11, 1, 0.4, -0.1, -0.2, 8),
			},
			"pitchers": {
				"20": _report_advanced_record(20, 3, 1.5, 0.3, 0.0, 1),
			},
		},
		"play_events": [
			{"batted_ball_event": {
				"exit_velocity": 100.0,
				"launch_angle": 30.0,
				"distance": 400.0,
				"is_barrel": true,
				"is_hard_hit": true,
				"actual_result": "home_run_center",
			}},
			{"batted_ball_event": {}},
		],
		"runner_event_counts": {"wild_pitch": 2, "balk": 1},
	})
	season.accumulate_game_report_data({
		"advanced_stats": {
			"players": {
				"10": _report_advanced_record(10, 1, 0.7, 0.2, 0.1, 6),
			},
			"pitchers": {
				"20": _report_advanced_record(20, 1, 0.7, -0.2, 0.0, 1),
				"21": _report_advanced_record(21, 1, 0.2, 0.1, 0.0, 1),
			},
		},
		"play_events": [
			{"batted_ball_event": {
				"exit_velocity": 95.0,
				"launch_angle": 10.0,
				"distance": 280.0,
				"is_barrel": false,
				"is_hard_hit": true,
				"actual_result": "double_left",
			}},
		],
		"runner_event_counts": {"wild_pitch": 1, "passed_ball": 1},
	})

	var reporter: SimulationReporter = SimulationReporter.new()
	var records: Dictionary = reporter._advanced_records_for_season(season)
	var player_10: Dictionary = (records.get("players", {}) as Dictionary).get("10", {}) as Dictionary
	assert_int(int(player_10.get("plate_appearances", 0))).is_equal(3)
	assert_float(float(player_10.get("woba_numerator", 0.0))).is_equal_approx(1.8, 0.000001)
	assert_int(int(player_10.get("fielding_chances", 0))).is_equal(2)
	assert_int(int((player_10.get("fielding_chances_by_position", {}) as Dictionary).get("6", 0))).is_equal(2)

	var advanced: Dictionary = reporter._advanced_aggregate_for_season(season)
	var player_aggregate: Dictionary = advanced.get("players", {}) as Dictionary
	var pitcher_aggregate: Dictionary = advanced.get("pitchers", {}) as Dictionary
	assert_int(int(player_aggregate.get("records", 0))).is_equal(3)
	assert_int(int(player_aggregate.get("plate_appearances", 0))).is_equal(4)
	assert_float(float(player_aggregate.get("woba_numerator", 0.0))).is_equal_approx(2.2, 0.000001)
	assert_int(int(pitcher_aggregate.get("records", 0))).is_equal(3)
	assert_int(int(pitcher_aggregate.get("plate_appearances", 0))).is_equal(5)

	var batted_ball: Dictionary = reporter._batted_ball_aggregate_for_season(season)
	assert_int(int(batted_ball.get("batted_balls", 0))).is_equal(2)
	assert_int(int(batted_ball.get("barrels", 0))).is_equal(1)
	assert_int(int(batted_ball.get("hard_hits", 0))).is_equal(2)
	assert_int(int(batted_ball.get("home_run_batted_balls", 0))).is_equal(1)
	assert_int(int(batted_ball.get("home_run_barrels", 0))).is_equal(1)
	assert_float(float(batted_ball.get("exit_velocity_total", 0.0))).is_equal(195.0)
	assert_float(float(batted_ball.get("launch_angle_total", 0.0))).is_equal(40.0)
	assert_float(float(batted_ball.get("distance_total", 0.0))).is_equal(680.0)

	var runner_counts: Dictionary = reporter._runner_event_counts_for_season(season)
	assert_int(int(runner_counts.get("wild_pitch", 0))).is_equal(3)
	assert_int(int(runner_counts.get("balk", 0))).is_equal(1)
	assert_int(int(runner_counts.get("passed_ball", 0))).is_equal(1)

	var restored: PSSeason = PSSeason.from_dict(season.to_dict())
	var restored_player_10: Dictionary = (
		(reporter._advanced_records_for_season(restored).get("players", {}) as Dictionary)
		.get("10", {}) as Dictionary
	)
	assert_int(int(restored_player_10.get("plate_appearances", 0))).is_equal(3)
	assert_float(float(restored_player_10.get("woba_numerator", 0.0))).is_equal_approx(1.8, 0.000001)
	assert_int(int(reporter._batted_ball_aggregate_for_season(restored).get("batted_balls", 0))).is_equal(2)
	assert_int(int(reporter._runner_event_counts_for_season(restored).get("wild_pitch", 0))).is_equal(3)
	assert_bool(restored.collect_simulation_report_data).is_true()
	restored.accumulate_game_report_data({
		"advanced_stats": {"players": {}, "pitchers": {}},
		"play_events": [],
		"runner_event_counts": {"wild_pitch": 2},
	})
	assert_int(int(reporter._runner_event_counts_for_season(restored).get("wild_pitch", 0))).is_equal(5)


func test_long_autoplay_prepares_every_season_for_streaming_report_aggregation() -> void:
	var season: PSSeason = PSSeason.new()
	assert_bool(season.collect_simulation_report_data).is_false()
	assert_bool(season.generate_game_logs).is_true()

	var reporter: PSLongAutoplayReporter = PSLongAutoplayReporter.new()
	reporter._prepare_report_season(season)

	assert_bool(season.collect_simulation_report_data).is_true()
	assert_bool(season.generate_game_logs).is_false()


# 故障のティア抽選は投手と野手で別テーブル。どちらも実 NPB の故障者リスト基準で、
# **投手の方が長期側へ寄っている** (オフ時点に離脱中の投手の 6-8 割が手術)。
# 特に投手の「重大手術」= トミー・ジョン級は 1球団 年1件が目標で、ここが薄くなると
# オフの故障者が実勢の 1/3 になる (2026-08-23 の較正前がその状態)。
func test_injury_tiers_are_weighted_separately_for_batters_and_pitchers() -> void:
	var previous_seed: int = Rng.current_seed
	var previous_state: int = Rng.generator.state
	Rng.set_seed_value(4242)

	var samples: int = 4000
	var batter_15plus: int = 0
	var pitcher_15plus: int = 0
	var pitcher_severe: int = 0
	for _i in range(samples):
		if PSInjuryModel._roll_tier(false) >= PSInjuryModel.TIER_MODERATE:
			batter_15plus += 1
		var pitcher_tier: int = PSInjuryModel._roll_tier(true)
		if pitcher_tier >= PSInjuryModel.TIER_MODERATE:
			pitcher_15plus += 1
		if pitcher_tier == PSInjuryModel.TIER_SEVERE:
			pitcher_severe += 1

	Rng.current_seed = previous_seed
	Rng.generator.seed = previous_seed
	Rng.generator.state = previous_state

	assert_float(float(batter_15plus) / float(samples)).is_between(0.40, 0.50)
	assert_float(float(pitcher_15plus) / float(samples)).is_between(0.50, 0.60)
	assert_float(float(pitcher_severe) / float(samples)).is_between(0.04, 0.07)


# 野手の故障頻度は実 NPB 準拠 (2026-08-22 時点で離脱中の野手 34人/12球団 = 2.83人)。
# 先発ぶんの判定だけを 1球団1シーズン (143試合 × 野手 9人) 回すと、15日以上の離脱が
# 3-6 件出る水準。実際のシムはこれに代打/守備交代と二軍戦、疲労の上乗せが乗る。
# 頻度を半分に戻すと下限を、倍にすると上限を割る。
func test_batter_injury_frequency_matches_npb_absence_volume() -> void:
	var previous_seed: int = Rng.current_seed
	var previous_state: int = Rng.generator.state
	Rng.set_seed_value(20260823)

	var teams: int = 12
	var starts_per_team: int = 143 * 9
	var long_absences: int = 0
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	# 実在しない player_id にする — 重傷の恒久能力低下は GameDb の持続 player まで書き換えるので、
	# 実在 id を使うと後続テストの選手能力が削れる。
	record.player_id = -1
	record.position = 8
	for _team in range(teams):
		for _start in range(starts_per_team):
			# 実際の判定は「離脱中の選手は再抽選しない」ので、毎回健康な状態から回す。
			record.injury_days = 0
			var injury: Dictionary = PSInjuryModel.maybe_injure(record, false)
			if not injury.is_empty() and int(injury.get("days", 0)) >= 15:
				long_absences += 1

	Rng.current_seed = previous_seed
	Rng.generator.seed = previous_seed
	Rng.generator.state = previous_state

	assert_float(float(long_absences) / float(teams)).is_between(3.0, 6.0)


# 投手の故障頻度も実 NPB 準拠 (オフ時点に離脱中の投手が 1球団 4.2人)。1球団1シーズンぶんの
# 登板判定 (143試合 × 1試合あたり投手 4人) を回すと、15日以上が 2-4.5 件 / 重大手術が 0.15-0.6 件。
# **重大手術の下限が要**で、ここが薄いとオフの故障者リストが実勢の 1/3 になる。
func test_pitcher_injury_frequency_matches_npb_absence_volume() -> void:
	var previous_seed: int = Rng.current_seed
	var previous_state: int = Rng.generator.state
	Rng.set_seed_value(20260824)

	var teams: int = 12
	var appearances_per_team: int = 143 * 4
	var long_absences: int = 0
	var severe: int = 0
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = -1  # 恒久能力低下が実在 player を削らないよう存在しない id にする
	record.position = 1
	for _team in range(teams):
		for _appearance in range(appearances_per_team):
			record.injury_days = 0
			var injury: Dictionary = PSInjuryModel.maybe_injure(record, true)
			if injury.is_empty():
				continue
			if int(injury.get("days", 0)) >= 15:
				long_absences += 1
			if int(injury.get("tier", 0)) == PSInjuryModel.TIER_SEVERE:
				severe += 1

	Rng.current_seed = previous_seed
	Rng.generator.seed = previous_seed
	Rng.generator.state = previous_state

	assert_float(float(long_absences) / float(teams)).is_between(2.0, 4.5)
	assert_float(float(severe) / float(teams)).is_between(0.15, 0.6)


func _report_advanced_record(
	player_id: int,
	plate_appearances: int,
	woba_numerator: float,
	re24: float,
	bsr: float,
	position: int
) -> Dictionary:
	var position_key: String = str(position)
	var zone: String = "outfield" if position >= 7 else "infield"
	return {
		"player_id": player_id,
		"plate_appearances": plate_appearances,
		"woba_denominator": plate_appearances,
		"xwoba_denominator": plate_appearances,
		"woba_numerator": woba_numerator,
		"xwoba_numerator": woba_numerator + 0.05,
		"re24_sum": re24,
		"bsr_sum": bsr,
		"fielding_chances": 1,
		"fielding_outs": 1,
		"fielding_chances_by_position": {position_key: 1},
		"fielding_chances_by_oaa_zone": {zone: 1},
		"fielding_outs_by_position": {position_key: 1},
		"fielding_outs_by_oaa_zone": {zone: 1},
		"defensive_outs_by_position": {position_key: 3},
		"defensive_outs_by_oaa_zone": {zone: 3},
		"oaa_by_zone": {zone: 0.1},
		"oaa_by_position": {position_key: 0.1},
		"rngr_by_position": {position_key: 0.05},
		"errr_by_position": {position_key: 0.01},
		"dpr_by_position": {position_key: 0.02},
		"uzr_by_position": {position_key: 0.08},
		"drs_by_position": {position_key: 0.08},
	}
