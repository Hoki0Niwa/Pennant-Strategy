extends Node

# 犠打(バント)の企図・成功を1シーズン実測するレポート。
# バント総数だけでなく「どの塁状況・アウトカウント・イニング・点差で企図しているか」を出すので、
# 総数を合わせつつ配分が現実離れしていないか (0アウト偏重か / スクイズが稀か) を確認できる。
# 見るべき数値:
#   - sacrifice_hits_per_team_game … 犠打の成立数 (NPB 2023 は 0.71)
#   - bunt_attempts_per_team_game / bunt_success_rate … 企図と成功率 (現実の成功率は ~0.8)
#   - by_state … 塁状況×アウト別の機会数・企図率・成功率と、犠打全体に占める割合
#   - by_inning / by_margin … 終盤・僅差に寄っているか (大差でバントしていないか)
# 実行: godot --headless res://tools/run_bunt_probe.tscn -- --seasons=1

const BASE_LABELS: Array = ["empty", "1B", "2B", "1B2B", "3B", "1B3B", "2B3B", "loaded"]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))
	if args.has("no-farm"):
		PSFarmGameRunner.enabled = false

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var tally: Dictionary = _empty_tally()
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
		while _has_unplayed_game(season):
			var day: int = season.current_day
			var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, ctx)
			if not bool(day_result.get("ok", false)):
				errors.append({
					"season_index": season_index,
					"day": day,
					"message": str(day_result.get("message", "day simulation failed")),
				})
				break
			for result_value in day_result.get("results", []) as Array:
				var game_result: Dictionary = result_value as Dictionary
				_collect_game(season, game_result.get("result", {}) as Dictionary, tally)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _summary(tally)
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["errors"] = errors
	if not output_path.is_empty():
		var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print(JSON.stringify(report, "\t"))
	get_tree().quit(0 if errors.is_empty() else 1)


func _has_unplayed_game(season: PSSeason) -> bool:
	for game_value in season.schedule:
		if not bool((game_value as Dictionary).get("played", false)):
			return true
	return false


func _empty_tally() -> Dictionary:
	return {
		"team_games": 0,
		"plate_appearances": 0,
		"by_state": {},
		"by_inning": {},
		"by_margin": {},
		"by_batter": {},
		"by_slot": {},
		"state_all_outs": {},
		"squeeze_attempts": 0,
		"failed_squeeze_runner_outs": 0,
	}


# 1試合分の play_events を走査し、バント機会 (走者あり・2アウト未満) と企図の結末を数える。
# バント結果は plate_event.result が "bunt_single_*"(安打) / "sacrifice_bunt_*" /
# "squeeze_bunt_*"(犠打成立) / "failed_squeeze_bunt_*"(三塁走者が本塁で憤死) /
# "failed_bunt_groundout_*"(失敗) の5系統で、犠打成立は category=="sacrifice"。
func _collect_game(season: PSSeason, result: Dictionary, tally: Dictionary) -> void:
	var play_events: Array = result.get("play_events", []) as Array
	if play_events.is_empty():
		return
	tally["team_games"] = int(tally["team_games"]) + 2
	var away_team_id: int = int(result.get("away_team_id", 0))
	for event_value in play_events:
		var event: Dictionary = event_value as Dictionary
		if str(event.get("event_type", "")) != PSPlayEventBuilder.EVENT_TYPE_PLAY:
			continue
		var plate_event: Dictionary = event.get("plate_event", {}) as Dictionary
		if plate_event.is_empty():
			continue
		tally["plate_appearances"] = int(tally["plate_appearances"]) + 1

		var outs: int = int(event.get("outs_before", 0))
		var base_code: int = _base_code(event.get("bases_before", []) as Array)
		var play_result: String = str(plate_event.get("result", ""))
		var attempted: bool = play_result.contains("bunt")
		var succeeded: bool = str(plate_event.get("category", "")) == "sacrifice"
		var bunt_hit: bool = attempted and play_result.begins_with("bunt_single")

		# NPB 公表値と同じ分母(その塁状況の全打席、2アウトを含む)でも見られるようにする。
		_bump(tally["state_all_outs"] as Dictionary, BASE_LABELS[base_code], attempted, succeeded, bunt_hit)

		if base_code == 0 or outs >= 2:
			continue
		if attempted and _has_third_base_runner(base_code):
			tally["squeeze_attempts"] = int(tally["squeeze_attempts"]) + 1
			if play_result.begins_with("failed_squeeze"):
				tally["failed_squeeze_runner_outs"] = int(tally["failed_squeeze_runner_outs"]) + 1

		_bump(tally["by_state"] as Dictionary, "%s_%dout" % [BASE_LABELS[base_code], outs], attempted, succeeded, bunt_hit)
		_bump(tally["by_inning"] as Dictionary, _inning_key(int(event.get("inning", 1))), attempted, succeeded, bunt_hit)
		_bump(tally["by_margin"] as Dictionary, _margin_key(event, away_team_id), attempted, succeeded, bunt_hit)
		_bump(tally["by_batter"] as Dictionary, _batter_key(season, int(plate_event.get("batter_id", 0))), attempted, succeeded, bunt_hit)
		_bump(tally["by_slot"] as Dictionary, _slot_key(int(plate_event.get("batting_slot", -1))), attempted, succeeded, bunt_hit)


func _has_third_base_runner(base_code: int) -> bool:
	return (base_code & 4) != 0


func _bump(bucket: Dictionary, key: String, attempted: bool, succeeded: bool, bunt_hit: bool) -> void:
	var row: Dictionary = bucket.get(key, {"opportunities": 0, "attempts": 0, "successes": 0, "bunt_hits": 0}) as Dictionary
	row["opportunities"] = int(row["opportunities"]) + 1
	if attempted:
		row["attempts"] = int(row["attempts"]) + 1
		if succeeded:
			row["successes"] = int(row["successes"]) + 1
		if bunt_hit:
			row["bunt_hits"] = int(row["bunt_hits"]) + 1
	bucket[key] = row


# 走者コード: bit0=一塁, bit1=二塁, bit2=三塁。
func _base_code(bases: Array) -> int:
	var code: int = 0
	for index in range(min(3, bases.size())):
		if int(bases[index]) > 0:
			code |= 1 << index
	return code


func _inning_key(inning: int) -> String:
	if inning <= 3:
		return "inning1_3"
	if inning <= 6:
		return "inning4_6"
	if inning <= 8:
		return "inning7_8"
	return "inning9plus"


# 攻撃側から見た点差を階級化する。大量リード/大量ビハインドでのバントを見るための軸。
func _margin_key(event: Dictionary, away_team_id: int) -> String:
	var score: Dictionary = event.get("score_before", {}) as Dictionary
	if score.is_empty():
		return "unknown"
	var batting_team_id: int = int(event.get("batting_team_id", 0))
	var offense_runs: int = int(score.get("away" if batting_team_id == away_team_id else "home", 0))
	var defense_runs: int = int(score.get("home" if batting_team_id == away_team_id else "away", 0))
	var margin: int = offense_runs - defense_runs
	if margin <= -4:
		return "down4plus"
	if margin < 0:
		return "down1_3"
	if margin == 0:
		return "tied"
	if margin <= 3:
		return "up1_3"
	return "up4plus"


func _slot_key(batting_slot: int) -> String:
	return "unknown" if batting_slot < 0 else "slot%d" % (batting_slot + 1)


func _batter_key(season: PSSeason, batter_id: int) -> String:
	if batter_id <= 0:
		return "unknown"
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(batter_id, season.year, season.season_number)
	if record == null:
		return "unknown"
	if record.is_pitcher():
		return "pitcher"
	var power: float = max(record.z_ability("Bat_Impact", 0.0), record.z_ability("Bat_Barrel", 0.0))
	if power >= 1.5:
		return "power_z1.5plus"
	if power >= 0.5:
		return "power_z0.5_1.5"
	if power >= -0.5:
		return "power_zminus0.5_0.5"
	return "power_zminus0.5below"


func _summary(tally: Dictionary) -> Dictionary:
	var team_games: int = int(tally.get("team_games", 0))
	var by_state: Dictionary = tally.get("by_state", {}) as Dictionary
	var attempts: int = 0
	var successes: int = 0
	var opportunities: int = 0
	var bunt_hits: int = 0
	for row_value in by_state.values():
		var row: Dictionary = row_value as Dictionary
		attempts += int(row.get("attempts", 0))
		successes += int(row.get("successes", 0))
		opportunities += int(row.get("opportunities", 0))
		bunt_hits += int(row.get("bunt_hits", 0))
	var squeeze_attempts: int = int(tally.get("squeeze_attempts", 0))
	return {
		"team_games": team_games,
		"plate_appearances": int(tally.get("plate_appearances", 0)),
		"totals": {
			"bunt_opportunities_per_team_game": _round3(_safe_div(opportunities, team_games)),
			"bunt_attempts_per_team_game": _round3(_safe_div(attempts, team_games)),
			"sacrifice_hits_per_team_game": _round3(_safe_div(successes, team_games)),
			"bunt_hits_per_team_game": _round3(_safe_div(bunt_hits, team_games)),
			"squeeze_attempts_per_team_game": _round3(_safe_div(squeeze_attempts, team_games)),
			"attempt_rate_per_opportunity": _round3(_safe_div(attempts, opportunities)),
			"bunt_success_rate": _round3(_safe_div(successes, attempts)),
			"bunt_hit_rate": _round3(_safe_div(bunt_hits, attempts)),
			"failed_squeeze_runner_outs_per_squeeze_attempt": _round3(
				_safe_div(int(tally.get("failed_squeeze_runner_outs", 0)), squeeze_attempts)
			),
		},
		"by_state": _decorate(by_state, successes),
		"by_state_all_outs": _decorate(tally.get("state_all_outs", {}) as Dictionary, successes),
		"by_slot": _decorate(tally.get("by_slot", {}) as Dictionary, successes),
		"by_inning": _decorate(tally.get("by_inning", {}) as Dictionary, successes),
		"by_margin": _decorate(tally.get("by_margin", {}) as Dictionary, successes),
		"by_batter": _decorate(tally.get("by_batter", {}) as Dictionary, successes),
	}


func _decorate(bucket: Dictionary, total_successes: int) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = bucket.keys()
	keys.sort()
	for key in keys:
		var row: Dictionary = bucket[key] as Dictionary
		var opportunities: int = int(row.get("opportunities", 0))
		var attempts: int = int(row.get("attempts", 0))
		var successes: int = int(row.get("successes", 0))
		var bunt_hits: int = int(row.get("bunt_hits", 0))
		out[key] = {
			"opportunities": opportunities,
			"attempts": attempts,
			"successes": successes,
			"bunt_hits": bunt_hits,
			"attempt_rate": _round3(_safe_div(attempts, opportunities)),
			"success_rate": _round3(_safe_div(successes, attempts)),
			"bunt_hit_rate": _round3(_safe_div(bunt_hits, attempts)),
			"share_of_sacrifice_hits": _round3(_safe_div(successes, total_successes)),
		}
	return out


func _safe_div(numerator: int, denominator: int) -> float:
	return 0.0 if denominator == 0 else float(numerator) / float(denominator)


func _round3(value: float) -> float:
	return round(value * 1000.0) / 1000.0


func _parse_args() -> Dictionary:
	var parsed: Dictionary = {}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg in args:
		var text: String = str(arg)
		if not text.begins_with("--"):
			continue
		var body: String = text.substr(2)
		var eq: int = body.find("=")
		if eq >= 0:
			parsed[body.substr(0, eq)] = body.substr(eq + 1)
		else:
			parsed[body] = true
	return parsed
