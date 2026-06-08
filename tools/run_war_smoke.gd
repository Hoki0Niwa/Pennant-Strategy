extends Node

# WAR 算出モジュール (PSWarCalculator) のスモークテスト。
# 1 シーズン (143試合 / チーム) を回してリーグ実測ベースの定数 + 個別 WAR + ポジション別 WAR
# が妥当な値で出るか確認する。
#
# 実行: godot --headless --path . tools/run_war_smoke.tscn

const WarCalculator = preload("res://services/reports/war_calculator.gd")
const SEED: int = 20260601


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)

	# 既存セーブを破壊しないためスナップショット保管。
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	# 通常プレイ経路でテストするためペナルティ無しでセーブ抑制せず走らせる。
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	print("Simulating 1 season (143 games/team)...")
	var start_ms: int = Time.get_ticks_msec()
	var result: Dictionary = GameSimulator.simulate_remaining_season(season, true)
	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	if not bool(result.get("ok", false)):
		print("Season sim failed: %s" % str(result.get("message", "")))
		_restore(original_records)
		get_tree().quit(1)
		return
	print("Simulated season in %.1fs" % (float(elapsed_ms) / 1000.0))

	# (1) リーグコンテキスト確認
	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	print("--- League context ---")
	print("lg_woba: %.3f  PA: %d" % [float(ctx.get("lg_woba", 0.0)), int(ctx.get("total_pa", 0))])
	print("lg_ip: %.1f  lg_runs/team-game: %.3f  lg_era: %.3f" % [
		float(ctx.get("lg_ip", 0.0)),
		float(ctx.get("lg_runs_per_team_game", 0.0)),
		float(ctx.get("lg_era", 0.0)),
	])
	print("lg_fip_raw: %.3f  cFIP: %.3f  rpw: %.3f" % [
		float(ctx.get("lg_fip_raw", 0.0)),
		float(ctx.get("lg_fip_constant", 0.0)),
		float(ctx.get("rpw", 0.0)),
	])
	print("replacement_runs_per_pa: %.4f (= %.2f WAR / %.0f PA)" % [
		float(ctx.get("replacement_runs_per_pa", 0.0)),
		float(ctx.get("replacement_runs_per_pa", 0.0)) * 600.0 / max(0.001, float(ctx.get("rpw", 10.0))),
		600.0,
	])

	# (2) WAR テーブル top 10 / bottom 5
	var table: Array = WarCalculator.season_war_table(season.year, season.season_number, ctx)
	print("--- Top 10 WAR ---")
	for i in range(min(10, table.size())):
		var row: Dictionary = table[i] as Dictionary
		_print_war_row(row)
	print("--- Bottom 5 WAR ---")
	for i in range(max(0, table.size() - 5), table.size()):
		var row: Dictionary = table[i] as Dictionary
		_print_war_row(row)

	# (3) リーグ合計 WAR を集計 (リプレイスメント込みなので合計はおよそ
	#     チーム数 × +平均値 のオーダーになる)
	var total_war_pos: float = 0.0
	var total_war_pit: float = 0.0
	var batters_qualified: int = 0
	var pitchers_qualified: int = 0
	for row_value in table:
		var row: Dictionary = row_value as Dictionary
		var role: String = str(row.get("role", ""))
		var war: float = float(row.get("war", 0.0))
		if role == "pitcher":
			total_war_pit += war
			if float(row.get("ip", 0.0)) >= 60.0:
				pitchers_qualified += 1
		else:
			total_war_pos += war
			if int(row.get("pa", 0)) >= 300:
				batters_qualified += 1
	print("--- League total WAR ---")
	print("Position players: %.1f WAR (%d qualified PA>=300)" % [total_war_pos, batters_qualified])
	print("Pitchers: %.1f WAR (%d qualified IP>=60)" % [total_war_pit, pitchers_qualified])
	print("Combined: %.1f WAR" % (total_war_pos + total_war_pit))

	# (4) チーム 1 のポジション別 WAR (戦力の穴分析)
	var team_war: Dictionary = WarCalculator.team_position_war(1, season.year, season.season_number, ctx)
	print("--- Team 1 position WAR ---")
	print("Total team WAR: %.2f" % float(team_war.get("team_war", 0.0)))
	var positions: Dictionary = team_war.get("positions", {}) as Dictionary
	var ordered_keys: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9]
	for key in ordered_keys:
		if not positions.has(key):
			continue
		var bucket: Dictionary = positions[key] as Dictionary
		var players: Array = bucket.get("players", []) as Array
		var top_name: String = "(none)"
		if not players.is_empty():
			top_name = str((players[0] as Dictionary).get("name", ""))
		print("  %2s  total=%6.2f  starter=%6.2f  depth=%6.2f  players=%d  top=%s" % [
			str(bucket.get("label", "")),
			float(bucket.get("war_total", 0.0)),
			float(bucket.get("starter_war", 0.0)),
			float(bucket.get("depth_war", 0.0)),
			players.size(),
			top_name,
		])

	_restore(original_records)
	# 妥当性最低限チェック: lg_woba > 0, rpw > 5, top 1 の WAR > 0
	var failures: Array = []
	if float(ctx.get("lg_woba", 0.0)) <= 0.0:
		failures.append("lg_woba <= 0")
	if float(ctx.get("rpw", 0.0)) < 5.0:
		failures.append("rpw too low: %.2f" % float(ctx.get("rpw", 0.0)))
	if not table.is_empty() and float((table[0] as Dictionary).get("war", 0.0)) <= 0.0:
		failures.append("top WAR <= 0")

	if failures.is_empty():
		print("WAR smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("WAR smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _print_war_row(row: Dictionary) -> void:
	var role: String = str(row.get("role", ""))
	if role == "pitcher":
		print("  P  pid=%4d  %s  IP=%.1f FIP=%.2f WAR=%+.2f" % [
			int(row.get("player_id", 0)),
			str(row.get("name", "")),
			float(row.get("ip", 0.0)),
			float(row.get("fip", 0.0)),
			float(row.get("war", 0.0)),
		])
	else:
		print("  B  pid=%4d  %s  PA=%d wRAA=%+.1f BSR=%+.1f OAA=%+.1f Pos=%+.1f Rep=%+.1f WAR=%+.2f" % [
			int(row.get("player_id", 0)),
			str(row.get("name", "")),
			int(row.get("pa", 0)),
			float(row.get("wraa", 0.0)),
			float(row.get("bsr", 0.0)),
			float(row.get("oaa_runs", 0.0)),
			float(row.get("pos_adj", 0.0)),
			float(row.get("replacement_runs", 0.0)),
			float(row.get("war", 0.0)),
		])


func _restore(original_records: Dictionary) -> void:
	RecordStore.load_from_dict(original_records)
	RecordStore.save_records()
