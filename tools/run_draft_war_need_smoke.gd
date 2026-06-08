extends Node

# ドラフトの「ポジション別 WAR 不足」反映を検証するスモーク (Phase C)。
#
# シーズンを 1 つ回した後ドラフト state を生成し、
# - state.team_position_need が全12チーム分作られていること
# - リーグ平均 starter_war と各チーム deficit が現実的な値で出ること
# - 各チームの「最も不足しているポジション」が抽出できること
# - complete_automatically 経由のCPUドラフトでチームが穴ポジを優先指名する傾向があるか
#   (確率なので断定はせず統計的傾向を表示する)
#
# 実行: godot --headless --path . tools/run_draft_war_need_smoke.tscn

const SEED: int = 20260605


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	Rng.set_seed_value(SEED)

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	print("Simulating 1 season for WAR baseline...")
	var start_ms: int = Time.get_ticks_msec()
	var sim: Dictionary = GameSimulator.simulate_remaining_season(season, true)
	if not bool(sim.get("ok", false)):
		print("Season sim failed: %s" % str(sim.get("message", "")))
		_restore(original_records)
		get_tree().quit(1)
		return
	print("Sim done in %.1fs" % (float(Time.get_ticks_msec() - start_ms) / 1000.0))

	# Phase C 改修後の create_draft_state を呼ぶ
	var draft_state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, season, 1)
	var team_position_need: Dictionary = draft_state.get("team_position_need", {}) as Dictionary

	# (1) リーグ平均 starter_war を表示
	var league_avg: Dictionary = team_position_need.get("__league_average", {}) as Dictionary
	print("--- League average starter_war by position ---")
	for pos in [1, 2, 3, 4, 5, 6, 7, 8, 9]:
		print("  %s: %.2f" % [_pos_label(pos), float(league_avg.get(pos, 0.0))])

	# (2) 各チームの最大 deficit ポジション (= 補強最優先ポジション) を抽出
	print("--- Top-deficit position by team ---")
	var failures: Array = []
	var teams_with_need: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var team_need: Dictionary = team_position_need.get(str(team.id), {}) as Dictionary
		if team_need.is_empty():
			failures.append("team %d had no need data" % team.id)
			continue
		var best_pos: int = 0
		var best_def: float = 0.0
		for pos_key in team_need.keys():
			var d: float = float(team_need[pos_key])
			if d > best_def:
				best_def = d
				best_pos = int(pos_key)
		if best_def > 0.0:
			teams_with_need += 1
		print("  Team %2d %s : top deficit = %s (%.2f WAR)" % [
			team.id, team.short_name, _pos_label(best_pos), best_def
		])
	if teams_with_need == 0:
		failures.append("no team had any position deficit (need scoring inactive)")

	# (3) ドラフト complete_automatically を回し、各チームの指名ポジションを集計
	print("--- Auto-running CPU draft ---")
	var done_state: Dictionary = DraftService.complete_automatically(draft_state)
	var final_state: Dictionary = done_state.get("state", done_state) as Dictionary
	var picks: Array = final_state.get("picks", []) as Array
	print("Total picks: %d" % picks.size())
	var by_team_position: Dictionary = {}
	for pick_value in picks:
		var pick: Dictionary = pick_value as Dictionary
		var tid: int = int(pick.get("team_id", 0))
		var pos: int = int(pick.get("position", 0))
		var key: String = "%d:%d" % [tid, pos]
		by_team_position[key] = int(by_team_position.get(key, 0)) + 1

	# (4) チーム別: 最大 deficit ポジションを「何回指名したか」をサンプル表示
	print("--- Did teams target their top-deficit positions? ---")
	var matched_count: int = 0
	var total_teams_checked: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var team_need: Dictionary = team_position_need.get(str(team.id), {}) as Dictionary
		if team_need.is_empty():
			continue
		var best_pos: int = 0
		var best_def: float = 0.0
		for pos_key in team_need.keys():
			var d: float = float(team_need[pos_key])
			if d > best_def:
				best_def = d
				best_pos = int(pos_key)
		if best_def <= 0.0:
			continue
		total_teams_checked += 1
		var key: String = "%d:%d" % [team.id, best_pos]
		var picked_count: int = int(by_team_position.get(key, 0))
		if picked_count > 0:
			matched_count += 1
		print("  Team %2d %s top-deficit %s (def=%.2f) -> picked there %d times" % [
			team.id, team.short_name, _pos_label(best_pos), best_def, picked_count
		])
	print("Teams that drafted at top-deficit position: %d / %d" % [matched_count, total_teams_checked])

	_restore(original_records)
	if failures.is_empty():
		print("Draft WAR need smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Draft WAR need smoke: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _pos_label(p: int) -> String:
	match p:
		1: return "P"
		2: return "C"
		3: return "1B"
		4: return "2B"
		5: return "3B"
		6: return "SS"
		7: return "LF"
		8: return "CF"
		9: return "RF"
		_: return "?"


func _restore(original_records: Dictionary) -> void:
	RecordStore.load_from_dict(original_records)
	RecordStore.save_records()
