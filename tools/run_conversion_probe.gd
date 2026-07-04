extends Node

# 走者→得点の変換率(単打での二塁走者生還、一塁→三塁、ゴロ生還、犠飛、残塁など)を
# play_events から実測する調査ツール。走塁・進塁まわりの較正時に回して実野球水準と比較する。

const GAMES: int = 150
const SEED: int = 20260704


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var c: Dictionary = {
		"games": 0, "runs": 0, "lob": 0,
		"single_r2": 0, "single_r2_scored": 0, "single_r2_out": 0,
		"single_r1": 0, "single_r1_third": 0, "single_r1_out": 0,
		"double_r1": 0, "double_r1_scored": 0, "double_r1_out": 0,
		"r3_lt2_bip_out": 0, "r3_lt2_bip_out_scored": 0,
		"r3_lt2_ground_out": 0, "r3_lt2_ground_out_scored": 0,
		"r3_lt2_of_fly_out": 0, "r3_lt2_of_fly_out_scored": 0,
		"r3_lt2_line_out": 0, "r3_lt2_if_fly_out": 0,
		"r3_lt2_dp": 0, "r3_lt2_fc": 0, "r3_lt2_other_out": 0,
		"sac_fly": 0, "sacrifice": 0, "double_play": 0,
		"r3_lt2_pa": 0, "r3_lt2_pa_scored": 0,
		"pa": 0, "k": 0, "bb": 0, "hbp": 0, "hits": 0, "hr": 0,
		"bip": 0, "la_sum": 0.0, "la2_sum": 0.0,
	}
	for traj in ["grounder", "liner", "fly", "popup"]:
		c["bip_%s" % traj] = 0
		c["hit_%s" % traj] = 0
		c["hr_%s" % traj] = 0

	while c["games"] < GAMES:
		var simulation: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
		if not bool(simulation.get("ok", false)):
			break
		c["games"] += 1
		var result: Dictionary = simulation.get("result", {}) as Dictionary
		c["runs"] += int(result.get("away_score", 0)) + int(result.get("home_score", 0))
		for ev_value in (result.get("play_events", []) as Array):
			_tally(c, ev_value as Dictionary)

	print("CONVPROBE games=%d runs=%d rpg_team=%.3f lob_team_game=%.2f" % [
		c["games"], c["runs"], float(c["runs"]) / max(1.0, float(c["games"]) * 2.0),
		float(c["lob"]) / max(1.0, float(c["games"]) * 2.0)])
	print("CONVPROBE single_r2 n=%d scored=%.3f out=%.3f" % [
		c["single_r2"], _rate(c, "single_r2_scored", "single_r2"), _rate(c, "single_r2_out", "single_r2")])
	print("CONVPROBE single_r1 n=%d to3rd=%.3f out=%.3f" % [
		c["single_r1"], _rate(c, "single_r1_third", "single_r1"), _rate(c, "single_r1_out", "single_r1")])
	print("CONVPROBE double_r1 n=%d scored=%.3f out=%.3f" % [
		c["double_r1"], _rate(c, "double_r1_scored", "double_r1"), _rate(c, "double_r1_out", "double_r1")])
	print("CONVPROBE r3_lt2_bip_out n=%d scored=%.3f (ground n=%d %.3f / of_fly n=%d %.3f)" % [
		c["r3_lt2_bip_out"], _rate(c, "r3_lt2_bip_out_scored", "r3_lt2_bip_out"),
		c["r3_lt2_ground_out"], _rate(c, "r3_lt2_ground_out_scored", "r3_lt2_ground_out"),
		c["r3_lt2_of_fly_out"], _rate(c, "r3_lt2_of_fly_out_scored", "r3_lt2_of_fly_out")])
	print("CONVPROBE r3_lt2 breakdown: line=%d if_fly=%d dp=%d fc=%d other=%d sf_conversion=%.3f" % [
		c["r3_lt2_line_out"], c["r3_lt2_if_fly_out"], c["r3_lt2_dp"], c["r3_lt2_fc"], c["r3_lt2_other_out"],
		float(c["r3_lt2_of_fly_out_scored"]) / max(1.0, float(c["r3_lt2_of_fly_out"]))])
	print("CONVPROBE r3_lt2_pa n=%d scored_in_pa=%.3f" % [
		c["r3_lt2_pa"], _rate(c, "r3_lt2_pa_scored", "r3_lt2_pa")])
	print("CONVPROBE per_team_game: sac_fly=%.3f sacrifice=%.3f double_play=%.3f" % [
		float(c["sac_fly"]) / max(1.0, float(c["games"]) * 2.0),
		float(c["sacrifice"]) / max(1.0, float(c["games"]) * 2.0),
		float(c["double_play"]) / max(1.0, float(c["games"]) * 2.0)])
	_print_batted_ball_summary(c)
	get_tree().quit(0)


func _print_batted_ball_summary(c: Dictionary) -> void:
	var team_games: float = max(1.0, float(c["games"]) * 2.0)
	var at_bats: int = c["pa"] - c["bb"] - c["hbp"] - c["sacrifice"] - c["sac_fly"]
	var n_la: float = max(1.0, float(c["bip"]))
	var la_mean: float = float(c["la_sum"]) / n_la
	var la_std: float = sqrt(max(0.0, float(c["la2_sum"]) / n_la - la_mean * la_mean))
	print("CONVPROBE league: AVG=%.3f K%%=%.3f BB%%=%.3f HR/tg=%.3f | LA mean=%.1f std=%.1f" % [
		float(c["hits"]) / max(1.0, float(at_bats)),
		float(c["k"]) / max(1.0, float(c["pa"])),
		float(c["bb"]) / max(1.0, float(c["pa"])),
		float(c["hr"]) / team_games, la_mean, la_std])
	for traj in ["grounder", "liner", "fly", "popup"]:
		var bip_t: int = int(c["bip_%s" % traj])
		var hit_t: int = int(c["hit_%s" % traj])
		var hr_t: int = int(c["hr_%s" % traj])
		var babip_denominator: float = max(1.0, float(bip_t - hr_t))
		print("CONVPROBE traj %-8s share=%.3f babip_ex_hr=%.3f hr=%d" % [
			traj, float(bip_t) / n_la, float(hit_t - hr_t) / babip_denominator, hr_t])


func _rate(c: Dictionary, num_key: String, den_key: String) -> float:
	return float(c[num_key]) / max(1.0, float(c[den_key]))


func _tally(c: Dictionary, ev: Dictionary) -> void:
	var plate: Dictionary = ev.get("plate_event", {}) as Dictionary
	if plate.is_empty():
		return
	var category: String = str(plate.get("category", ""))
	var hit_bases: int = int(plate.get("bases", 0))
	var result_name: String = str(plate.get("result", ""))
	var bases_before: Array = ev.get("bases_before", []) as Array
	var bases_after: Array = ev.get("bases_after", []) as Array
	var outs_before: int = int(ev.get("outs_before", 0))
	var outs_after: int = int(ev.get("outs_after", 0))
	var runs_scored: int = int(ev.get("runs_scored", 0))
	var runner_events: Array = ev.get("runner_events", []) as Array
	if bases_before.size() < 3 or bases_after.size() < 3:
		return

	# イニング終了時の残塁
	if outs_after >= 3:
		for base_id in bases_after:
			if int(base_id) > 0:
				c["lob"] += 1

	match category:
		"sacrifice_fly":
			c["sac_fly"] += 1
		"sacrifice":
			c["sacrifice"] += 1
		"double_play":
			c["double_play"] += 1
		"strikeout":
			c["k"] += 1
		"walk":
			c["bb"] += 1
		"hit_by_pitch":
			c["hbp"] += 1
	c["pa"] += 1
	if category == "hit":
		c["hits"] += 1
		if hit_bases >= 4:
			c["hr"] += 1
	var batted_ball: Dictionary = ev.get("batted_ball_event", {}) as Dictionary
	var trajectory: String = str(batted_ball.get("trajectory_bucket", ""))
	if trajectory in ["grounder", "liner", "fly", "popup"] and category != "sacrifice":
		c["bip"] += 1
		c["bip_%s" % trajectory] += 1
		var la: float = float(batted_ball.get("launch_angle", 0.0))
		c["la_sum"] = float(c["la_sum"]) + la
		c["la2_sum"] = float(c["la2_sum"]) + la * la
		if category == "hit":
			c["hit_%s" % trajectory] += 1
			if hit_bases >= 4:
				c["hr_%s" % trajectory] += 1

	var r1: int = int(bases_before[0])
	var r2: int = int(bases_before[1])
	var r3: int = int(bases_before[2])

	if category == "hit" and hit_bases == 1 and r2 > 0:
		c["single_r2"] += 1
		if _runner_out(runner_events, r2):
			c["single_r2_out"] += 1
		elif not _on_bases(bases_after, r2):
			c["single_r2_scored"] += 1
	if category == "hit" and hit_bases == 1 and r1 > 0:
		c["single_r1"] += 1
		if _runner_out(runner_events, r1):
			c["single_r1_out"] += 1
		elif int(bases_after[2]) == r1:
			c["single_r1_third"] += 1
	if category == "hit" and hit_bases == 2 and r1 > 0:
		c["double_r1"] += 1
		if _runner_out(runner_events, r1):
			c["double_r1_out"] += 1
		elif not _on_bases(bases_after, r1):
			c["double_r1_scored"] += 1

	# 三塁走者・2アウト未満での打球アウト(三振以外のアウト系)からの生還率
	if r3 > 0 and outs_before < 2:
		c["r3_lt2_pa"] += 1
		if runs_scored > 0 and not _on_bases(bases_after, r3) and not _runner_out(runner_events, r3):
			c["r3_lt2_pa_scored"] += 1
		var is_out_type: bool = category in ["out", "sacrifice_fly", "double_play", "fielders_choice"]
		if is_out_type:
			c["r3_lt2_bip_out"] += 1
			var scored: bool = not _on_bases(bases_after, r3) and not _runner_out(runner_events, r3) and runs_scored > 0
			if scored:
				c["r3_lt2_bip_out_scored"] += 1
			if result_name.begins_with("groundout") or result_name.begins_with("failed_bunt"):
				c["r3_lt2_ground_out"] += 1
				if scored:
					c["r3_lt2_ground_out_scored"] += 1
			elif result_name.begins_with("outfield_fly") or category == "sacrifice_fly":
				c["r3_lt2_of_fly_out"] += 1
				if scored:
					c["r3_lt2_of_fly_out_scored"] += 1
			elif result_name.begins_with("lineout"):
				c["r3_lt2_line_out"] += 1
			elif result_name.begins_with("infield_fly"):
				c["r3_lt2_if_fly_out"] += 1
			elif category == "double_play":
				c["r3_lt2_dp"] += 1
			elif category == "fielders_choice":
				c["r3_lt2_fc"] += 1
			else:
				c["r3_lt2_other_out"] += 1


func _on_bases(bases: Array, runner_id: int) -> bool:
	for base_id in bases:
		if int(base_id) == runner_id:
			return true
	return false


func _runner_out(runner_events: Array, runner_id: int) -> bool:
	for event_value in runner_events:
		var event: Dictionary = event_value as Dictionary
		if int(event.get("runner_id", 0)) != runner_id:
			continue
		if bool(event.get("is_baserunning_out", false)) or bool(event.get("is_out", false)):
			return true
		if str(event.get("result", "")) == "runner_out_advancing":
			return true
	return false
