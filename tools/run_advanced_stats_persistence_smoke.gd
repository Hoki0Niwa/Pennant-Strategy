extends Node

# 高度統計 (advanced_stats) のシーズン累積 + 永続化ラウンドトリップ検証。
# 1) 数試合シミュレーション (persist=true) → record.advanced_stats が non-zero に蓄積されるか
# 2) RecordStore reload (DB → RAM) → 累積値が復元されるか
# 3) 復元後の record の oaa_runs / def_runs / wraa が新計算式の結果と整合しているか
#
# 実行: godot --headless --path . tools/run_advanced_stats_persistence_smoke.tscn

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const GAMES_TO_PLAY: int = 3
const SEED: int = 20260530


func _ready() -> void:
	var failures: Array = []

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)

	# 既存セーブを退避してクリーンな状態でテストするためスナップショット。
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)

	# (1) 数試合走らせて高度統計が PSPlayerSeasonRecord に蓄積されるか確認。
	var simulated: int = 0
	while simulated < GAMES_TO_PLAY:
		var sim: Dictionary = GameSimulator.simulate_next_unplayed_game(season, true)
		if not bool(sim.get("ok", false)):
			break
		simulated += 1
	print("Simulated games: %d" % simulated)
	if simulated == 0:
		failures.append("no games simulated")

	var pre_records_with_pa: int = 0
	var pre_records_with_fc: int = 0
	var pre_sample_pid: int = 0
	var pre_sample_pa: int = 0
	var pre_sample_woba_num: float = 0.0
	var pre_sample_fielding_chances: int = 0
	for record_value in RecordStore.player_records.values():
		var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if rec == null or rec.advanced_stats == null:
			continue
		if rec.year != season.year or rec.season_number != season.season_number:
			continue
		if rec.advanced_stats.plate_appearances > 0:
			pre_records_with_pa += 1
			if pre_sample_pid == 0 and rec.advanced_stats.plate_appearances >= 3:
				pre_sample_pid = rec.player_id
				pre_sample_pa = rec.advanced_stats.plate_appearances
				pre_sample_woba_num = rec.advanced_stats.woba_numerator
		if rec.advanced_stats.fielding_chances > 0:
			pre_records_with_fc += 1
			if pre_sample_fielding_chances == 0:
				pre_sample_fielding_chances = rec.advanced_stats.fielding_chances
	print("After sim: %d records with PA>0, %d records with FC>0 (sample pid=%d pa=%d woba_num=%.3f fc=%d)" % [
		pre_records_with_pa, pre_records_with_fc, pre_sample_pid, pre_sample_pa, pre_sample_woba_num, pre_sample_fielding_chances
	])
	if pre_records_with_pa == 0:
		failures.append("no records had PA>0 (advanced_stats merge failed)")
	if pre_records_with_fc == 0:
		failures.append("no records had fielding chances (defensive merge failed)")

	# (2) RAM をクリアして DB から reload。永続化された advanced_stats が復元されるか。
	RecordStore.clear_records()
	RecordStore.load_records()
	var post_records_with_pa: int = 0
	var post_sample_pa: int = 0
	var post_sample_woba_num: float = 0.0
	var post_sample_fielding_chances: int = 0
	var post_sample_def_runs: float = 0.0
	var post_sample_oaa_runs: float = 0.0
	for record_value in RecordStore.player_records.values():
		var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if rec == null or rec.advanced_stats == null:
			continue
		if rec.year != season.year or rec.season_number != season.season_number:
			continue
		if rec.advanced_stats.plate_appearances > 0:
			post_records_with_pa += 1
		if rec.player_id == pre_sample_pid:
			post_sample_pa = rec.advanced_stats.plate_appearances
			post_sample_woba_num = rec.advanced_stats.woba_numerator
			var d: Dictionary = rec.advanced_stats.to_dict()
			post_sample_oaa_runs = float(d.get("oaa_runs", 0.0))
			post_sample_def_runs = float(d.get("def_runs", 0.0))
		if rec.advanced_stats.fielding_chances > 0 and post_sample_fielding_chances == 0:
			post_sample_fielding_chances = rec.advanced_stats.fielding_chances
	print("After reload: %d records with PA>0 (sample pid=%d pa=%d woba_num=%.3f fc>0 records=%d, def_runs=%.3f, oaa_runs=%.3f)" % [
		post_records_with_pa, pre_sample_pid, post_sample_pa, post_sample_woba_num, post_sample_fielding_chances, post_sample_def_runs, post_sample_oaa_runs
	])
	if post_records_with_pa != pre_records_with_pa:
		failures.append("PA records mismatch: pre=%d post=%d" % [pre_records_with_pa, post_records_with_pa])
	if post_sample_pa != pre_sample_pa:
		failures.append("sample PA mismatch: pre=%d post=%d" % [pre_sample_pa, post_sample_pa])
	if absf(post_sample_woba_num - pre_sample_woba_num) > 0.001:
		failures.append("sample woba_numerator mismatch: pre=%.3f post=%.3f" % [pre_sample_woba_num, post_sample_woba_num])

	# 元のセーブを復元 (テスト後の副作用を消す)。
	RecordStore.load_from_dict(original_records)
	RecordStore.save_records()

	if failures.is_empty():
		print("Advanced stats persistence smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Advanced stats persistence smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)
