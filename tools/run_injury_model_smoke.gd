extends Node

# 怪我システム (roadmap #6 / PSInjuryModel) の headless smoke。
# 検証: (1)ティア別の離脱日数レンジ・部位名・重症度  (2)軽傷は能力不変
#       (3)重大手術はまれに恒久能力低下 (player z + record snapshot + 球速)  (4)恒久損失の player 反映
#       (5)オフシーズン越冬同期 (長期離脱の翌季持ち越し)  (6)シーズン中の日次回復
# 実行: godot --headless --path . tools/run_injury_model_smoke.tscn

const Z_KEYS := ["Pit_KCreate", "Pit_BarrelDeny", "Pit_BBPrevent", "Pit_ImpactLimit",
	"Pit_Stamina", "Bat_Impact", "Bat_Barrel", "Bat_Loft",
	"Run_Speed", "Run_Steal", "Run_Judgment"]


func _ready() -> void:
	Rng.set_seed_value(20260610)
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	GameDb.rebuild_player_indices()
	RecordStore.clear_records()
	AppState.selected_team_id = 1
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026)
	RecordStore.ensure_season_records(AppState.current_season, GameDb.teams, GameDb.players, true)
	var season: PSSeason = AppState.current_season

	failures.append_array(_test_tier_days_and_labels())
	failures.append_array(_test_minor_no_permanent_loss())
	failures.append_array(_test_severe_permanent_loss_standalone())
	failures.append_array(_test_severe_permanent_loss_real_player(season))
	failures.append_array(_test_offseason_carryover(season))
	failures.append_array(_test_inseason_recovery(season))

	if failures.is_empty():
		print("Injury model smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Injury model smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % failure)
		get_tree().quit(1)


# (1) ティアごとの離脱日数レンジ・部位名・重症度・season_injury_days 加算。
func _test_tier_days_and_labels() -> Array:
	var failures: Array = []
	for tier in [PSInjuryModel.TIER_MINOR, PSInjuryModel.TIER_MODERATE, PSInjuryModel.TIER_MAJOR, PSInjuryModel.TIER_SEVERE]:
		var span: Array = PSInjuryModel.TIER_DAYS[tier] as Array
		for is_pitcher in [true, false]:
			for _i in range(8):
				var r: PSPlayerSeasonRecord = _make_record(is_pitcher)
				PSInjuryModel.apply_injury(r, is_pitcher, tier)
				if r.injury_days < int(span[0]) or r.injury_days > int(span[1]):
					failures.append("tier %d days %d out of range [%d,%d]" % [tier, r.injury_days, int(span[0]), int(span[1])])
				if r.injury_severity != tier:
					failures.append("tier %d severity not set (=%d)" % [tier, r.injury_severity])
				if r.injury_type.is_empty():
					failures.append("tier %d injury_type empty (is_pitcher=%s)" % [tier, str(is_pitcher)])
				if r.season_injury_days != r.injury_days:
					failures.append("tier %d season_injury_days %d != injury_days %d" % [tier, r.season_injury_days, r.injury_days])
	return failures


# (2) 軽傷は恒久能力低下なし (z 不変)。
func _test_minor_no_permanent_loss() -> Array:
	var failures: Array = []
	var r: PSPlayerSeasonRecord = _make_record(true)
	var before: float = float(r.z_abilities_snapshot["Pit_KCreate"])
	for _i in range(200):
		r.injury_days = 0
		PSInjuryModel.apply_injury(r, true, PSInjuryModel.TIER_MINOR)
	if not is_equal_approx(float(r.z_abilities_snapshot["Pit_KCreate"]), before):
		failures.append("minor injury changed z (%.3f -> %.3f)" % [before, float(r.z_abilities_snapshot["Pit_KCreate"])])
	if r.injury_severity != PSInjuryModel.TIER_MINOR:
		failures.append("minor severity wrong (=%d)" % r.injury_severity)
	return failures


# (3) 重大手術はまれに恒久損失。標準レコードで snapshot z と球速の減少を確認。
func _test_severe_permanent_loss_standalone() -> Array:
	var failures: Array = []
	var triggered: bool = false
	for _i in range(400):
		var r: PSPlayerSeasonRecord = _make_record(true)
		var info: Dictionary = PSInjuryModel.apply_injury(r, true, PSInjuryModel.TIER_SEVERE)
		var perm: Dictionary = info.get("permanent", {}) as Dictionary
		var keys: Dictionary = perm.get("keys", {}) as Dictionary
		if keys.is_empty():
			continue
		triggered = true
		for key in keys.keys():
			if float(r.z_abilities_snapshot[str(key)]) >= 1.0:
				failures.append("severe: snapshot z for %s not reduced (=%.3f)" % [str(key), float(r.z_abilities_snapshot[str(key)])])
		if int(perm.get("velocity_drop", 0)) > 0 and float(r.raw_abilities_snapshot["max_velocity"]) >= 150.0:
			failures.append("severe: max_velocity not reduced (=%.1f)" % float(r.raw_abilities_snapshot["max_velocity"]))
		break
	if not triggered:
		failures.append("severe never triggered permanent loss in 400 trials (seed)")
	return failures


# (4) 恒久損失が実 player の永続 z と当季 record snapshot 両方に反映されること。
func _test_severe_permanent_loss_real_player(season: PSSeason) -> Array:
	var failures: Array = []
	var rec: PSPlayerSeasonRecord = _find_pitcher_record(season)
	if rec == null:
		failures.append("no pitcher record with Pit_KCreate found")
		return failures
	var player: PSPlayer = GameDb.players_by_id.get(rec.player_id) as PSPlayer
	if player == null:
		failures.append("pitcher record %d has no persistent player" % rec.player_id)
		return failures
	var key: String = "Pit_KCreate"
	var p_before: float = float(player.z_abilities.get(key, 0.0))
	var r_before: float = float(rec.z_abilities_snapshot.get(key, 0.0))
	var triggered: bool = false
	for _i in range(800):
		rec.injury_days = 0
		var info: Dictionary = PSInjuryModel.apply_injury(rec, true, PSInjuryModel.TIER_SEVERE)
		var keys: Dictionary = (info.get("permanent", {}) as Dictionary).get("keys", {}) as Dictionary
		if keys.has(key):
			triggered = true
			break
	if not triggered:
		failures.append("could not trigger severe loss on real pitcher in 800 trials")
		return failures
	if float(player.z_abilities.get(key, 0.0)) >= p_before:
		failures.append("real player z not reduced (%.3f -> %.3f)" % [p_before, float(player.z_abilities.get(key, 0.0))])
	if float(rec.z_abilities_snapshot.get(key, 0.0)) >= r_before:
		failures.append("real record snapshot z not reduced (%.3f -> %.3f)" % [r_before, float(rec.z_abilities_snapshot.get(key, 0.0))])
	return failures


# (5) オフシーズン越冬同期: 長期離脱は持ち越し、短期は越冬で完治。from_player が翌季へシード。
func _test_offseason_carryover(season: PSSeason) -> Array:
	var failures: Array = []
	var records: Array = RecordStore.get_team_player_records(1, season.year, season.season_number)
	if records.size() < 3:
		failures.append("not enough records on team 1 for carryover test")
		return failures
	var rec_long: PSPlayerSeasonRecord = records[0] as PSPlayerSeasonRecord
	var rec_short: PSPlayerSeasonRecord = records[1] as PSPlayerSeasonRecord
	var player_long: PSPlayer = GameDb.players_by_id.get(rec_long.player_id) as PSPlayer
	var player_short: PSPlayer = GameDb.players_by_id.get(rec_short.player_id) as PSPlayer

	rec_long.injury_days = 400
	rec_long.injury_type = "右肘内側側副靭帯再建術(トミー・ジョン手術)"
	rec_long.injury_severity = PSInjuryModel.TIER_SEVERE
	rec_short.injury_days = 50
	rec_short.injury_type = "ハムストリング肉離れ"
	rec_short.injury_severity = PSInjuryModel.TIER_MODERATE

	OffseasonService.process_injury_carryover(GameDb.players, season)

	var expected_long: int = 400 - OffseasonService.OFFSEASON_RECOVERY_DAYS
	if player_long.injury_days != expected_long:
		failures.append("carryover long: player.injury_days %d != %d" % [player_long.injury_days, expected_long])
	if player_long.injury_severity != PSInjuryModel.TIER_SEVERE or player_long.injury_type.is_empty():
		failures.append("carryover long: type/severity not carried (type='%s' sev=%d)" % [player_long.injury_type, player_long.injury_severity])
	if player_short.injury_days != 0:
		failures.append("carryover short: player.injury_days %d != 0 (should heal over winter)" % player_short.injury_days)
	if player_short.injury_severity != 0 or not player_short.injury_type.is_empty():
		failures.append("carryover short: healed but type/severity not cleared (type='%s' sev=%d)" % [player_short.injury_type, player_short.injury_severity])

	var next_rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player_long, season.year + 1, season.season_number)
	if next_rec.injury_days != expected_long:
		failures.append("from_player next season: injury_days %d != %d" % [next_rec.injury_days, expected_long])
	if next_rec.injury_severity != PSInjuryModel.TIER_SEVERE or next_rec.injury_type.is_empty():
		failures.append("from_player next season: type/severity not seeded")
	return failures


# (6) シーズン中の日次回復で長期日数が減算され 0 に到達する。
func _test_inseason_recovery(season: PSSeason) -> Array:
	var failures: Array = []
	var records: Array = RecordStore.get_team_player_records(1, season.year, season.season_number)
	if records.size() < 3:
		failures.append("not enough records for recovery test")
		return failures
	var rec: PSPlayerSeasonRecord = records[2] as PSPlayerSeasonRecord
	rec.injury_days = 300
	rec.injury_severity = PSInjuryModel.TIER_SEVERE
	PSGameDecisions.recover_after_day(season, 100)
	if rec.injury_days != 200:
		failures.append("recovery step1: %d != 200" % rec.injury_days)
	PSGameDecisions.recover_after_day(season, 100)
	if rec.injury_days != 100:
		failures.append("recovery step2: %d != 100" % rec.injury_days)
	PSGameDecisions.recover_after_day(season, 100)
	if rec.injury_days != 0:
		failures.append("recovery step3: %d != 0" % rec.injury_days)
	return failures


# --- helpers ---

func _make_record(is_pitcher: bool) -> PSPlayerSeasonRecord:
	var r: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	r.player_id = 0
	r.name = "テスト選手"
	r.throwing_hand = "R"
	r.position = 1 if is_pitcher else 7
	r.role = "starter" if is_pitcher else "fielder"
	r.injury_days = 0
	r.season_injury_days = 0
	var z: Dictionary = {}
	for key in Z_KEYS:
		z[key] = 1.0
	r.z_abilities_snapshot = z
	r.raw_abilities_snapshot = {"max_velocity": 150.0}
	return r


func _find_pitcher_record(season: PSSeason) -> PSPlayerSeasonRecord:
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and record.is_pitcher() and record.z_abilities_snapshot.has("Pit_KCreate"):
				var player: PSPlayer = GameDb.players_by_id.get(record.player_id) as PSPlayer
				if player != null and player.z_abilities.has("Pit_KCreate"):
					return record
	return null
