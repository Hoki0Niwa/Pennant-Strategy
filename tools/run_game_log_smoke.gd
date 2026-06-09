extends Node

# 試合ログ(打席 play-by-play + 交代)の捕捉・書き出し・読み戻しを検証する。

const GameLogService = preload("res://services/storage/game_log_service.gd")
const BoxScoreBuilder = preload("res://services/reports/box_score_builder.gd")


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	Rng.set_seed_value(20260609)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	GameLogService.enabled = true

	var wrapper: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
	if not bool(wrapper.get("ok", false)):
		failures.append("simulate_next_unplayed_game failed: %s" % str(wrapper.get("message", "")))
		_finish(failures)
		return
	var result: Dictionary = wrapper.get("result", {}) as Dictionary

	var game_index: int = -1
	for i in range(season.schedule.size()):
		if bool((season.schedule[i] as Dictionary).get("played", false)):
			game_index = i
			break
	if game_index < 0:
		failures.append("no played game found")
		_finish(failures)
		return

	# --- in-memory pa_log ---
	var pa_log: Array = GameLogService.build_pa_log(result, season)
	if pa_log.size() < 30:
		failures.append("pa_log too small: %d" % pa_log.size())
	var rbi_sum: int = 0
	for row in pa_log:
		var r: Dictionary = row as Dictionary
		rbi_sum += int(r.get("rbi", 0))
		if int(r.get("batter_id", 0)) <= 0 or int(r.get("pitcher_id", 0)) <= 0:
			failures.append("pa_log row missing batter/pitcher id")
			break
	var total_runs: int = int(result.get("away_score", 0)) + int(result.get("home_score", 0))
	if rbi_sum > total_runs:
		failures.append("rbi_sum=%d exceeds total runs=%d" % [rbi_sum, total_runs])
	# 正確RBI: pa.rbi 合計 == 出場打者の season(=当試合, fresh season) runs_batted_in 合計。
	var batter_ids: Dictionary = {}
	for bid_row in pa_log:
		batter_ids[int((bid_row as Dictionary).get("batter_id", 0))] = true
	var stat_rbi_sum: int = 0
	for bid in batter_ids:
		var brec: PSPlayerSeasonRecord = RecordStore.get_player_record(int(bid), season.year, season.season_number)
		if brec != null:
			stat_rbi_sum += brec.batter_stats.runs_batted_in
	if rbi_sum != stat_rbi_sum:
		failures.append("pa rbi sum=%d != season rbi sum=%d (正確RBI不一致)" % [rbi_sum, stat_rbi_sum])
	# HR の号数/打点が妥当(>=1)。
	for hr_chk in pa_log:
		var hc: Dictionary = hr_chk as Dictionary
		if str(hc.get("category", "")) == "hit" and int(hc.get("bases", 0)) >= 4:
			if int(hc.get("hr_number", 0)) < 1 or int(hc.get("rbi", 0)) < 1:
				failures.append("HR hr_number/rbi invalid: %s" % JSON.stringify(hc))
				break

	# --- substitutions ---
	var subs: Array = result.get("substitutions", []) as Array
	for s_row in subs:
		var s: Dictionary = s_row as Dictionary
		if int(s.get("in_id", 0)) <= 0 or int(s.get("out_id", 0)) <= 0 or int(s.get("in_id", 0)) == int(s.get("out_id", 0)):
			failures.append("substitution bad in/out: %s" % JSON.stringify(s))
			break
		if not ["pitching", "pinch_hit", "defense"].has(str(s.get("kind", ""))):
			failures.append("substitution bad kind: %s" % str(s.get("kind", "")))
			break

	# --- file round-trip ---
	var log: Dictionary = GameLogService.read_game_log(season, game_index)
	if log.is_empty():
		failures.append("read_game_log empty for index %d" % game_index)
	else:
		var file_pa: Array = log.get("pa_log", []) as Array
		if file_pa.size() != pa_log.size():
			failures.append("file pa_log size %d != memory %d" % [file_pa.size(), pa_log.size()])
		var file_subs: Array = log.get("substitutions", []) as Array
		if file_subs.size() != subs.size():
			failures.append("file subs size %d != memory %d" % [file_subs.size(), subs.size()])

	# --- lineups + box score ---
	var lineups: Dictionary = log.get("lineups", {}) as Dictionary
	var away_slots: int = ((lineups.get("away", {}) as Dictionary).get("slots", []) as Array).size()
	var home_slots: int = ((lineups.get("home", {}) as Dictionary).get("slots", []) as Array).size()
	if away_slots < 9 or home_slots < 9:
		failures.append("lineup slots away=%d home=%d (expected >=9)" % [away_slots, home_slots])
	var team_hits: Dictionary = {}
	for row in (log.get("pa_log", []) as Array):
		var r: Dictionary = row as Dictionary
		if str(r.get("category", "")) == "hit":
			var tid: int = int(r.get("batting_team_id", 0))
			team_hits[tid] = int(team_hits.get(tid, 0)) + 1
	var box_rows_total: int = 0
	var box_cells_nonempty: int = 0
	for team_id in [int(result.get("away_team_id", 0)), int(result.get("home_team_id", 0))]:
		var box: Dictionary = BoxScoreBuilder.build(log, team_id, season)
		var rows: Array = box.get("rows", []) as Array
		box_rows_total += rows.size()
		if rows.size() < 9:
			failures.append("box rows <9 for team %d: %d" % [team_id, rows.size()])
		var totals: Dictionary = box.get("totals", {}) as Dictionary
		if int(totals.get("h", -1)) != int(team_hits.get(team_id, 0)):
			failures.append("box totals.h=%d != pa_log hits=%d (team %d)" % [int(totals.get("h", -1)), int(team_hits.get(team_id, 0)), team_id])
		for row_v in rows:
			for cell_v in ((row_v as Dictionary).get("cells", []) as Array):
				if not str((cell_v as Dictionary).get("text", "")).is_empty():
					box_cells_nonempty += 1
	if box_cells_nonempty < 10:
		failures.append("box cells mostly empty: %d" % box_cells_nonempty)

	# --- pitching + records ---
	var pitching: Dictionary = BoxScoreBuilder.build_pitching(log, season)
	var p_rows: Array = pitching.get("rows", []) as Array
	var outings: Array = log.get("pitcher_outings", []) as Array
	if p_rows.size() != outings.size():
		failures.append("pitching rows=%d != outings=%d" % [p_rows.size(), outings.size()])
	var sum_h: int = 0
	var sum_k: int = 0
	var sum_bb: int = 0
	var sum_er: int = 0
	for pr_v in p_rows:
		var pr: Dictionary = pr_v as Dictionary
		sum_h += int(pr.get("h", 0))
		sum_k += int(pr.get("k", 0))
		sum_bb += int(pr.get("bb", 0))
		sum_er += int(pr.get("er", 0))
	var tot_h: int = 0
	var tot_k: int = 0
	var tot_bb: int = 0
	for pa_v in (log.get("pa_log", []) as Array):
		match str((pa_v as Dictionary).get("category", "")):
			"hit":
				tot_h += 1
			"strikeout":
				tot_k += 1
			"walk":
				tot_bb += 1
	if sum_h != tot_h or sum_k != tot_k or sum_bb != tot_bb:
		failures.append("pitching h/k/bb=%d/%d/%d != pa_log %d/%d/%d" % [sum_h, sum_k, sum_bb, tot_h, tot_k, tot_bb])
	var outings_er: int = 0
	for o_v in outings:
		outings_er += int((o_v as Dictionary).get("earned_runs", 0))
	if sum_er != outings_er:
		failures.append("pitching er=%d != outings er=%d" % [sum_er, outings_er])
	var records: Dictionary = BoxScoreBuilder.build_records(log, season)
	var hr_count: int = 0
	for pa_v2 in (log.get("pa_log", []) as Array):
		var pr2: Dictionary = pa_v2 as Dictionary
		if str(pr2.get("category", "")) == "hit" and int(pr2.get("bases", 0)) >= 4:
			hr_count += 1
	if (records.get("hr", []) as Array).size() != hr_count:
		failures.append("records hr=%d != pa_log hr=%d" % [(records.get("hr", []) as Array).size(), hr_count])

	print("[game_log] pa=%d subs=%d box_rows=%d cells=%d pitchers=%d hr=%d errors=%d" % [pa_log.size(), subs.size(), box_rows_total, box_cells_nonempty, p_rows.size(), hr_count, (log.get("errors", []) as Array).size()])
	_finish(failures)


func _finish(failures: Array) -> void:
	if failures.is_empty():
		print("Game log smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Game log smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % str(f))
		get_tree().quit(1)
