extends Node

# 二軍戦を日次並列グループへ相乗りさせたときの限界コストを測る。
#
# 測定には **影の世界** (14球団ぶんの、選手もレコードも完全に独立した複製) を作り、
# 「1日に何試合まで同時計算できるか」を見る。実在の試合を使い回すと同じ
# PSPlayerSeasonRecord へ複数ワーカーが書き込んでレースになるため、独立した複製であることが
# 測定の前提。試合内容の妥当性は問わない。
#
# モード:
#   first_only … 一軍6試合のみ。影の世界を作らない (ベースライン)
#   merged     … 一軍6 + 影7 = 13試合を 1 つの WorkerThreadPool グループで計算
#   split      … 一軍6 と 影7 を別グループで順に計算
#
# merged/split は影の選手ぶんレコードが増えるので、ensure_season_records / recover_after_day の
# 固定オーバーヘッドも delta に含まれる (= 二軍機能の総コストとして正しい比較になる)。
#
# 実行: godot --headless res://tools/run_farm_day_cost_benchmark.tscn
# 環境変数: PS_FARM_BENCH_DAYS (既定30) / PS_FARM_BENCH_TRIALS (既定1)

const DEFAULT_DAYS: int = 30
const SEED: int = 20260520
const SHADOW_TEAM_COUNT: int = 14
const SHADOW_TEAM_ID_BASE: int = 101
const SHADOW_PLAYER_ID_BASE: int = 900000
const SHADOW_GAMES_PER_DAY: int = SHADOW_TEAM_COUNT >> 1


func _ready() -> void:
	var days: int = _env_int("PS_FARM_BENCH_DAYS", DEFAULT_DAYS)
	var trials: int = _env_int("PS_FARM_BENCH_TRIALS", 1)
	print("=== Farm day-cost benchmark (days=%d trials=%d processors=%d) ===" % [
		days, trials, OS.get_processor_count(),
	])

	var totals: Dictionary = {}
	var ok: bool = true
	for trial in range(trials):
		for mode in ["first_only", "merged", "split"]:
			var run: Dictionary = _run_mode(mode, days)
			if int(run.get("days_simulated", 0)) != days:
				ok = false
			if not totals.has(mode):
				totals[mode] = []
			(totals[mode] as Array).append(run)

	print("")
	print("--- summary (median of %d trial(s)) ---" % trials)
	var baseline_ms: float = _median_of(totals, "first_only", "elapsed_ms")
	for mode in ["first_only", "merged", "split"]:
		var elapsed: float = _median_of(totals, mode, "elapsed_ms")
		var calc: float = _median_of(totals, mode, "calc_ms")
		var apply: float = _median_of(totals, mode, "apply_ms")
		var games: float = _median_of(totals, mode, "games_simulated")
		var delta: String = ""
		if baseline_ms > 0.0 and mode != "first_only":
			delta = "  delta_vs_baseline=%+.1f%%" % ((elapsed / baseline_ms - 1.0) * 100.0)
		print("%-11s elapsed_ms=%.0f  calc_ms=%.0f  apply_ms=%.0f  games=%.0f  ms_per_day=%.1f%s" % [
			mode, elapsed, calc, apply, games, elapsed / float(days), delta,
		])
	print("")
	print("NOTE: merged/split の apply は影の試合にも一軍と同じ完全な apply (game log / ロスター修復 /")
	print("      打順履歴) を通しているため、実際の二軍 (これらを省く) より重く出る = 保守的な見積もり。")

	get_tree().quit(0 if ok else 1)


func _run_mode(mode: String, days: int) -> Dictionary:
	var build_shadow: bool = mode != "first_only"

	Rng.set_seed_value(SEED)
	GameDb.load_initial_data()
	RecordStore.clear_records()

	var real_teams: Array = GameDb.teams.duplicate()
	var real_season: PSSeason = SeasonService.create_new_season(real_teams, 1, 2026)

	var shadow_season: PSSeason = null
	if build_shadow:
		var shadow_teams: Array = _build_shadow_world(real_teams)
		shadow_season = _build_shadow_season(shadow_teams, real_season, days)

	RecordStore.ensure_season_records(real_season, GameDb.teams, GameDb.players, false)

	var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()
	var days_simulated: int = 0
	var games_simulated: int = 0
	var calc_usec: int = 0
	var apply_usec: int = 0

	var start_ms: int = Time.get_ticks_msec()
	while days_simulated < days:
		var real_indices: Array = _unplayed_indices_on_day(real_season, real_season.current_day)
		if real_indices.is_empty():
			break
		var shadow_indices: Array = []
		if shadow_season != null:
			shadow_indices = _unplayed_indices_on_day(shadow_season, shadow_season.current_day)

		if not GameSimulator._prewarm_day_profiles(real_season, real_indices):
			break
		if shadow_season != null and not shadow_indices.is_empty():
			if not GameSimulator._prewarm_day_profiles(shadow_season, shadow_indices):
				break

		var calc_start: int = Time.get_ticks_usec()
		var batches: Array = []
		if mode == "split":
			batches.append(_batch(real_season, real_indices))
			if not shadow_indices.is_empty():
				batches.append(_batch(shadow_season, shadow_indices))
		else:
			var merged_seasons: Array = []
			var merged_indices: Array = []
			for index_value in real_indices:
				merged_seasons.append(real_season)
				merged_indices.append(int(index_value))
			for index_value in shadow_indices:
				merged_seasons.append(shadow_season)
				merged_indices.append(int(index_value))
			batches.append({"seasons": merged_seasons, "indices": merged_indices})

		var calc_batches: Array = []
		for batch_value in batches:
			calc_batches.append(_run_calc_group(batch_value as Dictionary, rule_groups))
		calc_usec += Time.get_ticks_usec() - calc_start

		var apply_start: int = Time.get_ticks_usec()
		var applied: int = 0
		for batch_index in range(batches.size()):
			var batch: Dictionary = batches[batch_index] as Dictionary
			var results: Array = calc_batches[batch_index] as Array
			var seasons: Array = batch["seasons"] as Array
			for local_index in range(results.size()):
				var calc: Dictionary = results[local_index] as Dictionary
				if not bool(calc.get("ok", false)):
					printerr("[%s] calc failed: %s" % [mode, str(calc.get("message", ""))])
					continue
				GameSimulator._apply_game_result(seasons[local_index] as PSSeason, calc, false)
				applied += 1
		apply_usec += Time.get_ticks_usec() - apply_start

		if applied == 0:
			break
		games_simulated += applied
		days_simulated += 1

	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	print("[%-11s] days=%d games=%d elapsed_ms=%d calc_ms=%.0f apply_ms=%.0f ms_per_day=%.1f" % [
		mode,
		days_simulated,
		games_simulated,
		elapsed_ms,
		float(calc_usec) / 1000.0,
		float(apply_usec) / 1000.0,
		0.0 if days_simulated == 0 else float(elapsed_ms) / float(days_simulated),
	])
	return {
		"days_simulated": days_simulated,
		"games_simulated": games_simulated,
		"elapsed_ms": elapsed_ms,
		"calc_ms": float(calc_usec) / 1000.0,
		"apply_ms": float(apply_usec) / 1000.0,
	}


func _batch(season: PSSeason, indices: Array) -> Dictionary:
	var seasons: Array = []
	var out_indices: Array = []
	for index_value in indices:
		seasons.append(season)
		out_indices.append(int(index_value))
	return {"seasons": seasons, "indices": out_indices}


# 1グループぶんの計算フェーズ。local_index をそのままレーンIDにするのは GameSimulator と同じ。
func _run_calc_group(batch: Dictionary, rule_groups: Array[Dictionary]) -> Array:
	var seasons: Array = batch["seasons"] as Array
	var indices: Array = batch["indices"] as Array
	var out: Array = []
	out.resize(seasons.size())
	if seasons.is_empty():
		return out
	var task: Callable = _calc_task_body.bind(seasons, indices, out, rule_groups)
	var group_id: int = WorkerThreadPool.add_group_task(task, seasons.size())
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	return out


func _calc_task_body(
	local_index: int,
	seasons: Array,
	indices: Array,
	out: Array,
	rule_groups: Array[Dictionary]
) -> void:
	out[local_index] = GameSimulator._simulate_game_calculation(
		seasons[local_index] as PSSeason,
		int(indices[local_index]),
		local_index,
		rule_groups
	)


func _unplayed_indices_on_day(season: PSSeason, day: int) -> Array:
	var indices: Array = []
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != day:
			continue
		indices.append(index)
	return indices


# 14球団ぶんの複製世界を GameDb へ足す。選手・能力辞書は apply_dict が deep duplicate するので
# 実世界とはオブジェクトを一切共有しない (= ワーカー間で排反)。
func _build_shadow_world(real_teams: Array) -> Array:
	var shadow_teams: Array = []
	var next_player_id: int = SHADOW_PLAYER_ID_BASE
	for slot in range(SHADOW_TEAM_COUNT):
		var source: PSTeam = real_teams[slot % real_teams.size()] as PSTeam
		var team_data: Dictionary = source.to_dict()
		team_data["id"] = SHADOW_TEAM_ID_BASE + slot
		team_data["name"] = "シャドウ%02d" % slot
		team_data["short_name"] = "S%02d" % slot
		var shadow_team: PSTeam = PSTeam.from_dict(team_data)
		shadow_team.set_meta("source_team_id", source.id)
		shadow_teams.append(shadow_team)

		for player_row in GameDb.get_players_for_team(source.id):
			var player: PSPlayer = player_row as PSPlayer
			var player_data: Dictionary = player.to_dict()
			player_data["id"] = next_player_id
			player_data["team_id"] = shadow_team.id
			next_player_id += 1
			GameDb.players.append(PSPlayer.from_dict(player_data))

		GameDb.teams.append(shadow_team)
		GameDb.teams_by_id[shadow_team.id] = shadow_team
	GameDb.rebuild_player_indices()
	return shadow_teams


# 影の世界の日程。ペナントの制約 (交流戦・週次カード) は測定に関係ないので、
# 円卓法で毎日 7 試合ぶんの排反な組み合わせを作るだけにする。
func _build_shadow_season(shadow_teams: Array, real_season: PSSeason, days: int) -> PSSeason:
	var dh_by_source_team: Dictionary = {}
	for game_row in real_season.schedule:
		var game: Dictionary = game_row as Dictionary
		var home_id: int = int(game.get("home_team_id", 0))
		if not dh_by_source_team.has(home_id):
			dh_by_source_team[home_id] = bool(game.get("dh_enabled", true))

	var season: PSSeason = PSSeason.new()
	season.year = real_season.year
	season.season_number = real_season.season_number
	season.selected_team_id = 0
	season.current_day = 1
	season.calendar_start_date = real_season.calendar_start_date
	season.generate_game_logs = real_season.generate_game_logs

	var team_ids: Array = []
	for team_row in shadow_teams:
		team_ids.append((team_row as PSTeam).id)
	season.setup(team_ids)

	var date_by_day: Dictionary = {}
	for game_row in real_season.schedule:
		var game: Dictionary = game_row as Dictionary
		var day_value: int = int(game.get("day", 0))
		if not date_by_day.has(day_value):
			date_by_day[day_value] = str(game.get("date", ""))

	var count: int = shadow_teams.size()
	var order: Array = []
	for i in range(count):
		order.append(i)

	var schedule: Array = []
	var series_id: int = 0
	for day in range(1, days + 1):
		for i in range(count >> 1):
			var slot_a: int = int(order[i])
			var slot_b: int = int(order[count - 1 - i])
			var home_slot: int = slot_b if day % 2 == 0 else slot_a
			var away_slot: int = slot_a if day % 2 == 0 else slot_b
			var home_team: PSTeam = shadow_teams[home_slot] as PSTeam
			series_id += 1
			schedule.append({
				"day": day,
				"date": str(date_by_day.get(day, "")),
				"away_team_id": (shadow_teams[away_slot] as PSTeam).id,
				"home_team_id": home_team.id,
				"away_score": 0,
				"home_score": 0,
				"played": false,
				"dh_enabled": bool(dh_by_source_team.get(int(home_team.get_meta("source_team_id", 0)), true)),
				"innings": [],
				"result": {},
				"is_interleague": false,
				"series_id": series_id,
				"series_game_no": 1,
				"cycle_number": 1,
			})
		var last_slot: Variant = order[count - 1]
		for i in range(count - 1, 1, -1):
			order[i] = order[i - 1]
		order[1] = last_slot

	season.schedule = schedule
	return season


func _median_of(totals: Dictionary, mode: String, key: String) -> float:
	var runs: Array = totals.get(mode, []) as Array
	if runs.is_empty():
		return 0.0
	var values: Array = []
	for run_value in runs:
		values.append(float((run_value as Dictionary).get(key, 0)))
	values.sort()
	return float(values[values.size() >> 1])


func _env_int(name: String, fallback: int) -> int:
	var raw: String = OS.get_environment(name)
	if raw.is_valid_int():
		return max(1, int(raw))
	return fallback
