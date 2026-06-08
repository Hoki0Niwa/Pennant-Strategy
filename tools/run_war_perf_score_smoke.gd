extends Node

# Phase D の検証: perf_score の war_value 引数が正しく機能し、
# - cut_score 経路 (戦力外) では WAR が考慮されない
# - 投手の cut_score では登板数ボーナスが反映される
# - _swap_one_team 経路 (スタメン/一二軍入替) では WAR が反映される
# ことを実測する軽量スモーク。
#
# 数試合シミュレーションして PA を貯め、代表的な記録の perf_score を
# war_value=0 (= cut_score 経路) と war_value=実WAR (= スタメン入替経路) で
# 比較する。負の WAR を持つ選手では war 経由で perf が下がること、cut_score 経路
# では下がらないことを確認する。
#
# 実行: godot --headless --path . tools/run_war_perf_score_smoke.tscn

const WarCalculator = preload("res://services/reports/war_calculator.gd")
const GAMES_TO_PLAY: int = 12  # PA を 30+ 程度まで貯める
const SEED: int = 20260606


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	var simulated: int = 0
	while simulated < GAMES_TO_PLAY:
		var sim: Dictionary = GameSimulator.simulate_next_unplayed_game(season, true)
		if not bool(sim.get("ok", false)):
			break
		simulated += 1
	print("Simulated %d games" % simulated)

	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)

	# 全レコードから WAR を計算し、PA>=10 で WAR の最高 / 最低を選ぶ。
	var best_record: PSPlayerSeasonRecord = null
	var worst_record: PSPlayerSeasonRecord = null
	var best_war: float = -INF
	var worst_war: float = INF
	for record_value in RecordStore.player_records.values():
		var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if rec == null:
			continue
		if rec.advanced_stats == null or rec.advanced_stats.plate_appearances < 10:
			continue
		var war_row: Dictionary = WarCalculator.season_war(rec, ctx)
		var war: float = float(war_row.get("war", 0.0))
		if war > best_war:
			best_war = war
			best_record = rec
		if war < worst_war:
			worst_war = war
			worst_record = rec
	if best_record == null or worst_record == null:
		print("No qualifying records (need PA>=10)")
		_restore(original_records)
		get_tree().quit(1)
		return

	# 各レコードについて 3 つのスコアを計算:
	# (a) perf_score(record)                        ← cut_score が呼ぶ形 (war_value=0)
	# (b) perf_score(record, monthly_b, monthly_p, 0)
	# (c) perf_score(record, monthly_b, monthly_p, war) ← _swap_one_team が呼ぶ形
	for rec in [best_record, worst_record]:
		var label: String = "BEST" if rec == best_record else "WORST"
		var war_row: Dictionary = WarCalculator.season_war(rec, ctx)
		var war: float = float(war_row.get("war", 0.0))
		var monthly: Dictionary = season.get_monthly_stats(rec.player_id, rec.batter_stats, rec.pitcher_stats)
		var monthly_b: PSBatterStats = monthly.get("batter") as PSBatterStats
		var monthly_p: PSPitcherStats = monthly.get("pitcher") as PSPitcherStats
		var score_cut: float = TeamAutoAI.perf_score(rec)  # cut_score 経路: war_value 省略 = 0
		var score_no_war: float = TeamAutoAI.perf_score(rec, monthly_b, monthly_p, 0.0)
		var score_with_war: float = TeamAutoAI.perf_score(rec, monthly_b, monthly_p, war)
		var cut: float = TeamAutoAI.cut_score(GameDb.get_player(rec.player_id), rec)
		print("--- %s (pid=%d %s pos=%d) ---" % [label, rec.player_id, rec.name, rec.position])
		print("  PA=%d  WAR=%+.2f" % [rec.advanced_stats.plate_appearances, war])
		print("  perf_score(no war, season stats)   = %.2f" % score_cut)
		print("  perf_score(no war, monthly stats)  = %.2f" % score_no_war)
		print("  perf_score(WAR=%+.2f, monthly)     = %.2f  (delta=%+.2f)" % [war, score_with_war, score_with_war - score_no_war])
		print("  cut_score (age-penalty applied)    = %.2f" % cut)

	# 検証:
	# (1) worst_record (低WAR) について perf_score の WAR 付きが WAR 無しより低い
	# (2) cut_score が perf_score (season累積、war無し) - age_penalty に一致 → WAR 非依存
	var failures: Array = []
	var worst_war_row: Dictionary = WarCalculator.season_war(worst_record, ctx)
	var worst_war_value: float = float(worst_war_row.get("war", 0.0))
	var worst_monthly: Dictionary = season.get_monthly_stats(worst_record.player_id, worst_record.batter_stats, worst_record.pitcher_stats)
	var worst_monthly_b: PSBatterStats = worst_monthly.get("batter") as PSBatterStats
	var worst_monthly_p: PSPitcherStats = worst_monthly.get("pitcher") as PSPitcherStats
	var worst_no_war: float = TeamAutoAI.perf_score(worst_record, worst_monthly_b, worst_monthly_p, 0.0)
	var worst_with_war: float = TeamAutoAI.perf_score(worst_record, worst_monthly_b, worst_monthly_p, worst_war_value)
	if worst_war_value < 0.0 and worst_with_war >= worst_no_war:
		failures.append("worst WAR < 0 but perf_score did not decrease (no_war=%.2f with_war=%.2f)" % [worst_no_war, worst_with_war])

	# cut_score の WAR 非依存性: cut_score(player) は成績/WAR ではなく能力 prior を使う。
	# 投手は登板数ボーナスも加算される。
	var worst_player: PSPlayer = GameDb.get_player(worst_record.player_id)
	if worst_player != null:
		var expected_cut: float = TeamAutoAI.overall_prior(worst_record)
		if worst_record.is_pitcher():
			expected_cut += TeamAutoAI._pitcher_usage_bonus(worst_record)
		expected_cut -= max(0.0, float(worst_player.age) - 30.0) * 8.0
		var actual_cut: float = TeamAutoAI.cut_score(worst_player, worst_record)
		if absf(expected_cut - actual_cut) > 0.001:
			failures.append("cut_score not equal to overall_prior(record) + usage_bonus - age_pen: expected=%.2f actual=%.2f" % [expected_cut, actual_cut])

	_restore(original_records)
	if failures.is_empty():
		print("WAR perf_score smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("WAR perf_score smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _restore(original_records: Dictionary) -> void:
	RecordStore.load_from_dict(original_records)
	RecordStore.save_records()
