extends Node

# R4 調整: 年俸モデルの分布検証。1シーズンを実シミュ → 契約更新 (process_contract_update) →
# 支配下選手の年俸分布を NPB 実データの目安と比較する。
#   目安 (NPB 2024-25): 平均≈4700万 / 中央値≈1900万 / 最低420万 / 1億超≈17% / 上限7-8億。
# 厳密一致ではなく桁・分布が現実的かを確認する (調整ノブは offseason_service.gd 冒頭 const)。

const Offseason = preload("res://services/season/offseason_service.gd")


func _ready() -> void:
	Rng.set_seed_value(20260605)
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		push_error("[salary] GameDb not loaded")
		get_tree().quit(1)
		return

	# 複数シーズン回して年俸が現実的な定常分布に収束するか見る (毎年 シミュ → 契約更新 → 加齢)。
	var dh: Dictionary = {"central": true, "pacific": true}
	var seasons: int = 6
	print("=== Salary distribution (万円) over %d seasons ===" % seasons)
	var last_season: PSSeason = null
	for i in range(seasons):
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, SeasonService.DEFAULT_START_YEAR + i, dh)
		last_season = season
		RecordStore.clear_records()
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		var sim: Dictionary = GameSimulator.simulate_remaining_season(season, false)
		if not bool(sim.get("ok", false)):
			push_error("[salary] season sim failed: %s" % str(sim.get("message", "")))
			get_tree().quit(1)
			return
		OffseasonService.process_contract_update(GameDb.players, GameDb.teams, season)
		_print_stats("year %d" % (i + 1), _salaries(GameDb.players))
		GameDb.advance_players_one_year()
		GameDb.rebuild_player_indices()

	var after: Array = _salaries(GameDb.players)
	_print_examples(GameDb.players, last_season)

	# サニティ: 値が桁違いに壊れていないこと (旧モデルは全員 ~50000=5億 だった)。
	var stats_after: Dictionary = _stats(after)
	var ok: bool = true
	ok = _expect(int(stats_after["median"]) >= 600 and int(stats_after["median"]) <= 6000, "median in 600-6000 (got %d)" % int(stats_after["median"]), ok)
	ok = _expect(int(stats_after["mean"]) >= 1500 and int(stats_after["mean"]) <= 12000, "mean in 1500-12000 (got %d)" % int(stats_after["mean"]), ok)
	ok = _expect(int(stats_after["min"]) >= 440, "min >= 440 (got %d)" % int(stats_after["min"]), ok)
	ok = _expect(int(stats_after["max"]) <= 80000, "max <= 80000 (got %d)" % int(stats_after["max"]), ok)
	print("Salary distribution smoke: %s" % ["OK" if ok else "CHECK"])
	get_tree().quit(0 if ok else 1)


func _salaries(players: Array) -> Array:
	var out: Array = []
	for p_row in players:
		var p: PSPlayer = p_row as PSPlayer
		if p.is_retired() or p.is_manager_candidate() or p.team_id <= 0:
			continue
		out.append(p.salary)
	out.sort()
	return out


func _stats(sorted_salaries: Array) -> Dictionary:
	var n: int = sorted_salaries.size()
	if n == 0:
		return {"n": 0, "min": 0, "median": 0, "mean": 0, "p90": 0, "max": 0, "over_oku": 0}
	var total: int = 0
	for s in sorted_salaries:
		total += int(s)
	var over_oku: int = 0
	for s in sorted_salaries:
		if int(s) >= 10000:
			over_oku += 1
	return {
		"n": n,
		"min": int(sorted_salaries[0]),
		"median": int(sorted_salaries[n / 2]),
		"mean": int(round(float(total) / float(n))),
		"p90": int(sorted_salaries[int(n * 0.9)]),
		"max": int(sorted_salaries[n - 1]),
		"over_oku": over_oku,
	}


func _print_stats(label: String, sorted_salaries: Array) -> void:
	var s: Dictionary = _stats(sorted_salaries)
	print("%s: n=%d min=%d median=%d mean=%d p90=%d max=%d 1億超=%d(%.1f%%)" % [
		label, int(s["n"]), int(s["min"]), int(s["median"]), int(s["mean"]),
		int(s["p90"]), int(s["max"]), int(s["over_oku"]),
		100.0 * float(s["over_oku"]) / float(max(1, int(s["n"]))),
	])


# 上位年俸とWARの例をいくつか表示。
func _print_examples(players: Array, season: PSSeason) -> void:
	var rows: Array = []
	for p_row in players:
		var p: PSPlayer = p_row as PSPlayer
		if p.is_retired() or p.is_manager_candidate() or p.team_id <= 0:
			continue
		rows.append(p)
	rows.sort_custom(func(a, b): return (a as PSPlayer).salary > (b as PSPlayer).salary)
	print("--- top 8 salaries ---")
	for i in range(min(8, rows.size())):
		var p: PSPlayer = rows[i] as PSPlayer
		print("  %s (%s) age%d 年俸%d万 %s" % [p.name, PSPlayer.POSITION_NAMES.get(p.position, "?"), p.age, p.salary, "外" if p.foreign_player else ""])


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_warning("[salary] CHECK: %s" % label)
		return false
	return running_ok
