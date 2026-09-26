extends Node

# 救援の登板場面 (Leverage Index) を 1 軍戦の全登板で集計し、NPB 2025 の実測と並べて出す。
# 救援の起用 (役割レーン・場面の担当・イニング途中の継投) を触る前後で回す。
#
#   godot --headless --path . --scene res://tools/run_relief_leverage_probe.tscn -- --seasons=1 --seed=12345
#     [--output=res://reports/relief_leverage.json] [--no-farm]
#
# LI は登板記録の entry_leverage (シムの全打席平均 = 1.0 に正規化した表)。NPB 側は NPB 公式の試合経過を
# 同じ表で引き、NPB の全打席平均で割った値 (docs/scripts/npb_relief/)。
# gmli_ip_weighted は登板ごとの LI をその登板のアウト数で加重、gmli_pitcher_ip_weighted は投手ごとの gmLI を
# その投手のアウト数で加重 (balance report の relief.gmli_ip_weighted と同じ定義)。長い登板が軽い場面に
# 偏るほど前者が低く出る。
# 投手の順位は「季ごと・球団ごとに 20 登板以上の救援を gmLI の高い順」に並べたもの。

const MIN_ENTRIES_FOR_RANK: int = 20

# NPB 2025 レギュラーシーズン全 858 試合の実測。
const NPB_2025: Dictionary = {
	"entries_per_team_game": 3.13,
	"relief_ip_per_team_game": 3.16,
	"gmli_ip_weighted": 0.927,
	"gmli_pitcher_ip_weighted": 0.984,
	"entry_mean_li": 1.020,
	"mid_inning_share": 0.150,
	"mid_inning_li": 1.67,
	"mid_inning_outs_per_app": 2.35,
	"starter_exit_mid_inning_share": 0.25,
	"mid_inning_after_reliever_share": 0.075,
	"mid_inning_after_reliever_li": 1.78,
	"mid_inning_after_reliever_outs": 1.99,
	"blowout_share": 0.243,
	"final_margin_4plus_share": 0.301,
	"rank_gmli": {"rank1": 1.56, "rank2-3": 1.39, "rank4-6": 1.08, "rank7+": 0.66},
	"score_state_share": {"lead1-3": 0.280, "tie": 0.208, "behind1-3": 0.269, "lead4+": 0.119, "behind4+": 0.124},
	"score_state_outs_per_app": {"lead1-3": 2.80, "tie": 2.88, "behind1-3": 3.12, "lead4+": 2.84, "behind4+": 3.81},
	"spot_rank_share": {
		"lead1-3 6-8": {"rank1": 0.08, "rank2-3": 0.41, "rank4-6": 0.34, "rank7+": 0.11, "few": 0.06},
		"tie 6-8": {"rank1": 0.07, "rank2-3": 0.35, "rank4-6": 0.35, "rank7+": 0.15, "few": 0.08},
		"behind1-3 6-8": {"rank1": 0.03, "rank2-3": 0.12, "rank4-6": 0.30, "rank7+": 0.29, "few": 0.27},
		"lead1-3 9": {"rank1": 0.54, "rank2-3": 0.29, "rank4-6": 0.13, "rank7+": 0.04, "few": 0.01},
	},
}
const RANK_KEYS: Array[String] = ["rank1", "rank2-3", "rank4-6", "rank7+", "few"]
const STATE_KEYS: Array[String] = ["lead1-3", "tie", "behind1-3", "lead4+", "behind4+"]
const SPOT_KEYS: Array[String] = ["lead1-3 6-8", "tie 6-8", "behind1-3 6-8", "lead1-3 9", "tie 9", "behind1-3 9", "blowout 6-9", "early", "extra"]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = maxi(1, int(args.get("seasons", 1)))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))
	if bool(args.get("no_farm", false)):
		PSFarmGameRunner.enabled = false

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var season_rows: Array = []
	var team_games: int = 0
	var blowout_finals: int = 0
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# 実プレイと同じ日次フック (谷間昇格・週次入替・二軍戦) を通す。
		var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
		var rows: Array = []
		while _has_unplayed_game(season):
			var day: int = season.current_day
			var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, ctx)
			if not bool(day_result.get("ok", false)):
				errors.append({"season_index": season_index, "day": day, "message": str(day_result.get("message", ""))})
				break
			for result_value in day_result.get("results", []) as Array:
				var result: Dictionary = (result_value as Dictionary).get("result", {}) as Dictionary
				team_games += _collect_relief_outings(result, rows)
				if absi(int(result.get("away_score", 0)) - int(result.get("home_score", 0))) >= 4:
					blowout_finals += 1
		season_rows.append(rows)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _summary(season_rows, team_games)
	report["final_margin_4plus_share"] = _round(float(blowout_finals) * 2.0 / float(maxi(1, team_games)))
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["errors"] = errors
	report["npb_2025"] = NPB_2025
	if not output_path.is_empty():
		var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	_print_summary(report)
	get_tree().quit(0 if errors.is_empty() else 1)


func _has_unplayed_game(season: PSSeason) -> bool:
	for game_value in season.schedule:
		if not bool((game_value as Dictionary).get("played", false)):
			return true
	return false


# 1 試合の救援登板を rows へ足し、その試合のチーム試合数 (2) を返す。
func _collect_relief_outings(result: Dictionary, rows: Array) -> int:
	if result.is_empty():
		return 0
	var first_relief_seen: Dictionary = {}
	for outing_value in result.get("pitcher_outings", []) as Array:
		var outing: Dictionary = outing_value as Dictionary
		if str(outing.get("role", "")) == PSPitcherUsageModel.ROLE_STARTER or not outing.has("entry_leverage"):
			continue
		var team_id: int = int(outing.get("team_id", 0))
		var replaced_starter: bool = not first_relief_seen.has(team_id)
		first_relief_seen[team_id] = true
		rows.append({
			"team_id": team_id,
			"pitcher_id": int(outing.get("pitcher_id", 0)),
			"inning": int(outing.get("start_inning", 0)),
			"lead": int(outing.get("entry_lead", 0)),
			"mid_inning": int(outing.get("entry_outs", 0)) > 0 or int(outing.get("entry_base_runners", 0)) > 0,
			"leverage": float(outing.get("entry_leverage", 1.0)),
			"outs": int(outing.get("outs", 0)),
			"lane": str(outing.get("relief_lane", "")),
			"replaced_starter": replaced_starter,
		})
	return 2


func _score_state(lead: int) -> String:
	if lead >= 4:
		return "lead4+"
	if lead >= 1:
		return "lead1-3"
	if lead == 0:
		return "tie"
	if lead >= -3:
		return "behind1-3"
	return "behind4+"


func _spot(row: Dictionary) -> String:
	var inning: int = int(row["inning"])
	if inning <= 5:
		return "early"
	if inning >= 10:
		return "extra"
	var state: String = _score_state(int(row["lead"]))
	if state == "lead4+" or state == "behind4+":
		return "blowout 6-9"
	return "%s %s" % [state, "9" if inning == 9 else "6-8"]


func _summary(season_rows: Array, team_games: int) -> Dictionary:
	var all_rows: Array = []
	var rank_of: Dictionary = {}  # "season:team:pitcher" -> rank key
	# 投手ごとの gmLI をその投手の投球回で加重した値 (WAR の balance report / FanGraphs と同じ定義)。
	var pitcher_gmli_outs_sum: float = 0.0
	var pitcher_outs_sum: int = 0
	for season_index in range(season_rows.size()):
		var rows: Array = season_rows[season_index] as Array
		all_rows.append_array(rows)
		var per_pitcher: Dictionary = {}
		for row_value in rows:
			var row: Dictionary = row_value as Dictionary
			var key: String = "%d:%d" % [int(row["team_id"]), int(row["pitcher_id"])]
			var entry: Array = per_pitcher.get(key, [0, 0.0, 0]) as Array
			per_pitcher[key] = [int(entry[0]) + 1, float(entry[1]) + float(row["leverage"]), int(entry[2]) + int(row["outs"])]
		var by_team: Dictionary = {}
		for key in per_pitcher.keys():
			var entry: Array = per_pitcher[key] as Array
			pitcher_gmli_outs_sum += float(entry[1]) / float(entry[0]) * float(entry[2])
			pitcher_outs_sum += int(entry[2])
			if int(entry[0]) < MIN_ENTRIES_FOR_RANK:
				continue
			var team_key: String = str(key).get_slice(":", 0)
			var list: Array = by_team.get(team_key, []) as Array
			list.append([float(entry[1]) / float(entry[0]), key])
			by_team[team_key] = list
		for team_key in by_team.keys():
			var list: Array = by_team[team_key] as Array
			list.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
			for index in range(list.size()):
				rank_of["%d:%s" % [season_index, str(list[index][1])]] = _rank_key(index)
	var season_index_by_row: Array = []
	for season_index in range(season_rows.size()):
		for _row in season_rows[season_index] as Array:
			season_index_by_row.append(season_index)

	var n: int = all_rows.size()
	var total_outs: int = 0
	var leverage_sum: float = 0.0
	var leverage_outs_sum: float = 0.0
	var mid: Array = [0, 0.0, 0]
	var mid_after_reliever: Array = [0, 0.0, 0]
	var starter_exits: Array = [0, 0]
	var state_counts: Dictionary = {}
	var state_outs: Dictionary = {}
	var rank_stats: Dictionary = {}
	var spot_rank: Dictionary = {}
	var lane_stats: Dictionary = {}
	for index in range(n):
		var row: Dictionary = all_rows[index] as Dictionary
		var leverage: float = float(row["leverage"])
		var outs: int = int(row["outs"])
		total_outs += outs
		leverage_sum += leverage
		leverage_outs_sum += leverage * float(outs)
		if bool(row["mid_inning"]):
			mid[0] = int(mid[0]) + 1
			mid[1] = float(mid[1]) + leverage
			mid[2] = int(mid[2]) + outs
			if not bool(row["replaced_starter"]):
				mid_after_reliever[0] = int(mid_after_reliever[0]) + 1
				mid_after_reliever[1] = float(mid_after_reliever[1]) + leverage
				mid_after_reliever[2] = int(mid_after_reliever[2]) + outs
		if bool(row["replaced_starter"]):
			starter_exits[0] = int(starter_exits[0]) + 1
			if bool(row["mid_inning"]):
				starter_exits[1] = int(starter_exits[1]) + 1
		var state: String = _score_state(int(row["lead"]))
		state_counts[state] = int(state_counts.get(state, 0)) + 1
		state_outs[state] = int(state_outs.get(state, 0)) + outs
		var rank: String = str(rank_of.get("%d:%d:%d" % [int(season_index_by_row[index]), int(row["team_id"]), int(row["pitcher_id"])], "few"))
		var stats: Array = rank_stats.get(rank, [0, 0.0, 0]) as Array
		rank_stats[rank] = [int(stats[0]) + 1, float(stats[1]) + leverage, int(stats[2]) + outs]
		var spot: String = _spot(row)
		var spot_counts: Dictionary = spot_rank.get(spot, {}) as Dictionary
		spot_counts[rank] = int(spot_counts.get(rank, 0)) + 1
		spot_rank[spot] = spot_counts
		var lane: String = str(row["lane"]) if not str(row["lane"]).is_empty() else "(none)"
		var lane_row: Array = lane_stats.get(lane, [0, 0.0, 0]) as Array
		lane_stats[lane] = [int(lane_row[0]) + 1, float(lane_row[1]) + leverage, int(lane_row[2]) + outs]

	var rank_gmli: Dictionary = {}
	var rank_outs_share: Dictionary = {}
	for rank in RANK_KEYS:
		var stats: Array = rank_stats.get(rank, [0, 0.0, 0]) as Array
		rank_gmli[rank] = _round(float(stats[1]) / float(maxi(1, int(stats[0]))))
		rank_outs_share[rank] = _round(float(stats[2]) / float(maxi(1, total_outs)))
	var spot_rank_share: Dictionary = {}
	for spot in SPOT_KEYS:
		var counts: Dictionary = spot_rank.get(spot, {}) as Dictionary
		var spot_total: int = 0
		for value in counts.values():
			spot_total += int(value)
		var shares: Dictionary = {"entries_per_season": _round(float(spot_total) / float(maxi(1, season_rows.size())))}
		for rank in RANK_KEYS:
			shares[rank] = _round(float(counts.get(rank, 0)) / float(maxi(1, spot_total)))
		spot_rank_share[spot] = shares
	var state_share: Dictionary = {}
	var state_outs_per_app: Dictionary = {}
	for state in STATE_KEYS:
		state_share[state] = _round(float(state_counts.get(state, 0)) / float(maxi(1, n)))
		state_outs_per_app[state] = _round(float(state_outs.get(state, 0)) / float(maxi(1, int(state_counts.get(state, 0)))))
	var lanes: Dictionary = {}
	for lane in lane_stats.keys():
		var lane_row: Array = lane_stats[lane] as Array
		lanes[lane] = {
			"share": _round(float(lane_row[0]) / float(maxi(1, n))),
			"mean_li": _round(float(lane_row[1]) / float(maxi(1, int(lane_row[0])))),
			"outs_per_app": _round(float(lane_row[2]) / float(maxi(1, int(lane_row[0])))),
		}
	return {
		"entries": n,
		"team_games": team_games,
		"entries_per_team_game": _round(float(n) / float(maxi(1, team_games))),
		"relief_ip_per_team_game": _round(float(total_outs) / 3.0 / float(maxi(1, team_games))),
		"gmli_ip_weighted": _round(leverage_outs_sum / float(maxi(1, total_outs))),
		"gmli_pitcher_ip_weighted": _round(pitcher_gmli_outs_sum / float(maxi(1, pitcher_outs_sum))),
		"entry_mean_li": _round(leverage_sum / float(maxi(1, n))),
		"mid_inning_share": _round(float(mid[0]) / float(maxi(1, n))),
		"mid_inning_li": _round(float(mid[1]) / float(maxi(1, int(mid[0])))),
		"mid_inning_outs_per_app": _round(float(mid[2]) / float(maxi(1, int(mid[0])))),
		"starter_exit_mid_inning_share": _round(float(starter_exits[1]) / float(maxi(1, int(starter_exits[0])))),
		"mid_inning_after_reliever_share": _round(float(mid_after_reliever[0]) / float(maxi(1, n))),
		"mid_inning_after_reliever_li": _round(float(mid_after_reliever[1]) / float(maxi(1, int(mid_after_reliever[0])))),
		"mid_inning_after_reliever_outs": _round(float(mid_after_reliever[2]) / float(maxi(1, int(mid_after_reliever[0])))),
		"blowout_share": _round(float(state_share["lead4+"]) + float(state_share["behind4+"])),
		"score_state_share": state_share,
		"score_state_outs_per_app": state_outs_per_app,
		"rank_gmli": rank_gmli,
		"rank_outs_share": rank_outs_share,
		"spot_rank_share": spot_rank_share,
		"lanes": lanes,
	}


func _rank_key(index: int) -> String:
	if index == 0:
		return "rank1"
	if index <= 2:
		return "rank2-3"
	if index <= 5:
		return "rank4-6"
	return "rank7+"


func _print_summary(report: Dictionary) -> void:
	var npb: Dictionary = NPB_2025
	print("Relief leverage probe: seed %d x %d seasons (%d relief entries)" % [int(report["seed"]), int(report["seasons"]), int(report["entries"])])
	for key in ["entries_per_team_game", "relief_ip_per_team_game", "gmli_ip_weighted", "gmli_pitcher_ip_weighted", "entry_mean_li", "mid_inning_share", "mid_inning_li", "mid_inning_outs_per_app", "starter_exit_mid_inning_share", "mid_inning_after_reliever_share", "mid_inning_after_reliever_li", "mid_inning_after_reliever_outs", "blowout_share", "final_margin_4plus_share"]:
		print("  %-30s sim %6.3f | NPB2025 %6.3f" % [key, float(report[key]), float(npb.get(key, 0.0))])
	var rank_line: String = "  rank gmLI (1 / 2-3 / 4-6 / 7+):  sim"
	var npb_line: String = "  NPB2025"
	for rank in ["rank1", "rank2-3", "rank4-6", "rank7+"]:
		rank_line += " %.2f" % float((report["rank_gmli"] as Dictionary)[rank])
		npb_line += " %.2f" % float((npb["rank_gmli"] as Dictionary)[rank])
	print(rank_line + " |" + npb_line)
	for spot in SPOT_KEYS:
		var shares: Dictionary = (report["spot_rank_share"] as Dictionary)[spot] as Dictionary
		var line: String = "  %-14s %5.0f/season " % [spot, float(shares["entries_per_season"])]
		for rank in RANK_KEYS:
			line += " %s %3.0f%%" % [rank, float(shares[rank]) * 100.0]
		var npb_shares: Dictionary = (npb["spot_rank_share"] as Dictionary).get(spot, {}) as Dictionary
		if not npb_shares.is_empty():
			line += "  | NPB"
			for rank in RANK_KEYS:
				line += " %3.0f%%" % (float(npb_shares.get(rank, 0.0)) * 100.0)
		print(line)
	var state_line: String = "  score state share / outs per app:"
	for state in STATE_KEYS:
		state_line += " %s %.0f%% %.2f (NPB %.0f%% %.2f)" % [
			state,
			float((report["score_state_share"] as Dictionary)[state]) * 100.0,
			float((report["score_state_outs_per_app"] as Dictionary)[state]),
			float((npb["score_state_share"] as Dictionary)[state]) * 100.0,
			float((npb["score_state_outs_per_app"] as Dictionary)[state]),
		]
	print(state_line)
	var lanes: Dictionary = report["lanes"] as Dictionary
	var lane_line: String = "  lanes:"
	for lane in lanes.keys():
		var lane_row: Dictionary = lanes[lane] as Dictionary
		lane_line += " %s %.0f%% (LI %.2f, %.1f outs)" % [lane, float(lane_row["share"]) * 100.0, float(lane_row["mean_li"]), float(lane_row["outs_per_app"])]
	print(lane_line)


func _round(value: float) -> float:
	return snappedf(value, 0.001)


func _parse_args() -> Dictionary:
	var args: Dictionary = {}
	for raw_value in OS.get_cmdline_user_args():
		var raw: String = str(raw_value)
		if raw == "--no-farm":
			args["no_farm"] = true
			continue
		if not raw.begins_with("--") or not raw.contains("="):
			continue
		var key: String = raw.substr(2, raw.find("=") - 2).replace("-", "_")
		args[key] = raw.substr(raw.find("=") + 1)
	return args
