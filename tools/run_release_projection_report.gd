extends Node

# 戦力外選定刷新の比較レポート。1シーズン自動進行後、全12球団の支配下・非引退・非育成選手について
# 現行 TeamAutoAI.cut_score と新規 ReleaseValueProjector.projected_value_components を並べ、
# 序列相関・仮想放出セットの重複・不一致選手を出す。**ゲーム挙動には一切介入しない** (読み取り専用)。

const OffseasonService = preload("res://services/season/offseason_service.gd")
const TeamAutoAI = preload("res://services/season/team_auto_ai.gd")
const ReleaseValueProjector = preload("res://services/season/release_value_projector.gd")
const SeasonService = preload("res://services/season/season_service.gd")
const GameSimulator = preload("res://services/simulation/game_simulator.gd")

const DEFAULT_SEED: int = 20260714
const DEFAULT_START_YEAR: int = 2026
const DEFAULT_OUTPUT_MD: String = "res://reports/release_projection_report_latest.md"
const DEFAULT_OUTPUT_JSON: String = "res://reports/release_projection_report_latest.json"
const DISAGREEMENT_TOP_N: int = 20
const AGE_BANDS: Array = [
	{"label": "18-22", "min": 18, "max": 22},
	{"label": "23-26", "min": 23, "max": 26},
	{"label": "27-30", "min": 27, "max": 30},
	{"label": "31-34", "min": 31, "max": 34},
	{"label": "35+", "min": 35, "max": 999},
]


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var seed_value: int = int(options.get("seed", DEFAULT_SEED))
	var start_year: int = int(options.get("start_year", DEFAULT_START_YEAR))
	var selected_team_id: int = 1
	if not GameDb.teams.is_empty():
		selected_team_id = (GameDb.teams[0] as PSTeam).id

	# balance_report / long_autoplay と同じ退避パターン: レポート実行の中間状態を
	# 通常プレイの RecordStore/Rng に漏らさない。
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)
	RecordStore.clear_records()

	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, selected_team_id, start_year, {"league1": true, "league2": true})
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
	var sim_result: Dictionary = GameSimulator.simulate_remaining_season(season, false)
	var ok: bool = bool(sim_result.get("ok", false))
	var report: Dictionary = _build_report(season, seed_value, start_year) if ok else {
		"ok": false,
		"message": str(sim_result.get("message", "")),
	}

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	var md_path: String = str(options.get("output", DEFAULT_OUTPUT_MD))
	var json_path: String = str(options.get("json", DEFAULT_OUTPUT_JSON))
	var md_ok: bool = false
	var json_ok: bool = false
	if ok:
		md_ok = _write_text(md_path, _render_markdown(report))
		json_ok = _write_text(json_path, JSON.stringify(report, "\t"))
		_print_summary(report, md_path if md_ok else "", json_path if json_ok else "")
	else:
		print("Simulation failed: %s" % str(report.get("message", "")))

	get_tree().quit(0 if (ok and md_ok and json_ok) else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seed": DEFAULT_SEED,
		"start_year": DEFAULT_START_YEAR,
		"output": DEFAULT_OUTPUT_MD,
		"json": DEFAULT_OUTPUT_JSON,
	}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg_value in args:
		var arg: String = str(arg_value)
		if arg == "--help" or arg == "-h":
			options["help"] = true
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--start-year="):
			options["start_year"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--json="):
			options["json"] = arg.get_slice("=", 1)
	return options


func _print_usage() -> void:
	print("Usage:")
	print("  godot --headless --path . --scene res://tools/run_release_projection_report.tscn -- --seed=20260714")
	print("Options:")
	print("  --seed=N            (default 20260714)")
	print("  --start-year=YYYY   (default 2026)")
	print("  --output=res://reports/release_projection_report_latest.md")
	print("  --json=res://reports/release_projection_report_latest.json")


# --- レポート構築 -------------------------------------------------------------

func _build_report(season: PSSeason, seed_value: int, start_year: int) -> Dictionary:
	var team_reports: Array = []
	var league_disagreements: Array = []
	var actual_release_rows: Array = []
	var projected_release_rows: Array = []
	var all_player_rows: Array = []
	var age_band_totals: Dictionary = {}
	for band_v in AGE_BANDS:
		var band: Dictionary = band_v as Dictionary
		age_band_totals[str(band["label"])] = {"sum": 0.0, "count": 0}

	var spearman_values: Array = []
	var total_release_n: int = 0
	var total_overlap: int = 0

	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var roster: Array = _team_roster_rows(team.id, season)
		if roster.size() < 2:
			continue
		all_player_rows.append_array(roster)

		for row_v in roster:
			var row: Dictionary = row_v as Dictionary
			var age: int = int(row["age"])
			for band_v in AGE_BANDS:
				var band: Dictionary = band_v as Dictionary
				if age >= int(band["min"]) and age <= int(band["max"]):
					var acc: Dictionary = age_band_totals[str(band["label"])]
					acc["sum"] = float(acc["sum"]) + float(row["new_total"])
					acc["count"] = int(acc["count"]) + 1
					break

		var spearman: float = _spearman_correlation(roster, "old_score", "new_total")
		spearman_values.append(spearman)

		var actual_ids: Array = OffseasonService.compute_release_candidates_for_team(GameDb.players, team.id, season)
		var actual_set: Dictionary = {}
		for pid_v in actual_ids:
			actual_set[int(pid_v)] = true

		var by_new_asc: Array = roster.duplicate()
		by_new_asc.sort_custom(func(a, b) -> bool: return float((a as Dictionary)["new_total"]) < float((b as Dictionary)["new_total"]))
		var n: int = actual_ids.size()
		var projected_ids: Array = []
		var projected_set: Dictionary = {}
		for i in range(min(n, by_new_asc.size())):
			var pid: int = int((by_new_asc[i] as Dictionary)["id"])
			projected_ids.append(pid)
			projected_set[pid] = true

		var overlap: int = 0
		for pid_v in actual_ids:
			if projected_set.has(int(pid_v)):
				overlap += 1
		var overlap_ratio: float = (float(overlap) / float(n)) if n > 0 else 0.0
		total_release_n += n
		total_overlap += overlap

		var by_id: Dictionary = {}
		for row_v in roster:
			var row: Dictionary = row_v as Dictionary
			by_id[int(row["id"])] = row
		for pid_v in actual_ids:
			if by_id.has(int(pid_v)):
				actual_release_rows.append(by_id[int(pid_v)])
		for pid in projected_ids:
			if by_id.has(pid):
				projected_release_rows.append(by_id[pid])

		var rank_old: Dictionary = _normalized_ranks(roster, "old_score")
		var rank_new: Dictionary = _normalized_ranks(roster, "new_total")
		var sym_diff: Dictionary = {}
		for pid_v in actual_ids:
			var pid: int = int(pid_v)
			if not projected_set.has(pid):
				sym_diff[pid] = "actual_only"
		for pid in projected_ids:
			if not actual_set.has(pid):
				sym_diff[pid] = "projected_only"
		for pid in sym_diff.keys():
			if not by_id.has(pid):
				continue
			var row: Dictionary = by_id[pid]
			var diff: float = float(rank_old.get(pid, 0.0)) - float(rank_new.get(pid, 0.0))
			league_disagreements.append({
				"team": team.name,
				"which": sym_diff[pid],
				"abs_diff": absf(diff),
				"row": row,
			})

		# 較正時の突き合わせ用に、両セットの中身 (名前+年齢) も JSON へ残す。
		var actual_names: Array = []
		for pid_v in actual_ids:
			if by_id.has(int(pid_v)):
				var name_row: Dictionary = by_id[int(pid_v)]
				actual_names.append("%s(%d)" % [str(name_row["name"]), int(name_row["age"])])
		var projected_names: Array = []
		for pid in projected_ids:
			if by_id.has(pid):
				var name_row: Dictionary = by_id[pid]
				projected_names.append("%s(%d)" % [str(name_row["name"]), int(name_row["age"])])

		team_reports.append({
			"team_id": team.id,
			"team": team.name,
			"roster_size": roster.size(),
			"spearman": _round_float(spearman, 3),
			"release_count": n,
			"overlap": overlap,
			"overlap_ratio": _round_float(overlap_ratio, 3),
			"actual_release": actual_names,
			"projected_release": projected_names,
		})

	league_disagreements.sort_custom(func(a, b) -> bool: return float((a as Dictionary)["abs_diff"]) > float((b as Dictionary)["abs_diff"]))
	var top_disagreements: Array = []
	for i in range(min(DISAGREEMENT_TOP_N, league_disagreements.size())):
		var entry: Dictionary = league_disagreements[i] as Dictionary
		var row: Dictionary = entry["row"] as Dictionary
		top_disagreements.append({
			"team": entry["team"],
			"which": entry["which"],
			"rank_gap": _round_float(float(entry["abs_diff"]), 3),
			"name": row["name"],
			"age": row["age"],
			"position_label": row["position_label"],
			"overall": row["overall"],
			"usage": row["usage_label"],
			"salary": row["salary"],
			"old_score": _round_float(float(row["old_score"]), 2),
			"new_total": _round_float(float(row["new_total"]), 2),
			"components": row["new_components"],
		})

	var age_band_rows: Array = []
	for band_v in AGE_BANDS:
		var band: Dictionary = band_v as Dictionary
		var acc: Dictionary = age_band_totals[str(band["label"])]
		var count: int = int(acc["count"])
		age_band_rows.append({
			"label": str(band["label"]),
			"count": count,
			"average_projected_value": _round_float(_safe_div(float(acc["sum"]), count), 2),
		})

	var avg_spearman: float = _average(spearman_values)
	var league_overlap_ratio: float = _safe_div(float(total_overlap), float(total_release_n))

	return {
		"ok": true,
		"seed": seed_value,
		"start_year": start_year,
		"season_year": season.year,
		"team_count": GameDb.teams.size(),
		"league_summary": {
			"average_spearman": _round_float(avg_spearman, 3),
			"total_release_n": total_release_n,
			"total_overlap": total_overlap,
			"overlap_ratio": _round_float(league_overlap_ratio, 3),
			"actual_release_set": _composition_stats(actual_release_rows),
			"projected_release_set": _composition_stats(projected_release_rows),
		},
		"age_band_averages": age_band_rows,
		"players": all_player_rows,
		"teams": team_reports,
		"top_disagreements": top_disagreements,
	}


# team_id の支配下 (非引退・非育成) 選手を、旧 cut_score と新 projected_value 両方を添えて集める。
func _team_roster_rows(team_id: int, season: PSSeason) -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.development_player:
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var is_pitcher: bool = record.is_pitcher() if record != null else player.position == 1
		var old_score: float = TeamAutoAI.cut_score(player, record)
		var new_components: Dictionary = ReleaseValueProjector.projected_value_components(player, record)
		var usage_label: String = _usage_label(record, is_pitcher)
		rows.append({
			"id": player.id,
			"name": player.name,
			"age": player.age,
			"years": player.years,
			"foreign_player": player.foreign_player,
			"position": player.position,
			"position_label": str(PSPlayer.POSITION_NAMES.get(player.position, "-")) + ("/" + player.role if is_pitcher and player.role != "" else ""),
			"is_pitcher": is_pitcher,
			"salary": player.salary,
			"overall": int(new_components.get("current", 0.0)),
			"usage_label": usage_label,
			"old_score": old_score,
			"new_total": float(new_components.get("total", 0.0)),
			"new_components": {
				"current": _round_float(float(new_components.get("current", 0.0)), 2),
				"growth": _round_float(float(new_components.get("growth", 0.0)), 2),
				"usage_evidence": _round_float(float(new_components.get("usage_evidence", 0.0)), 2),
				"injury_penalty": _round_float(float(new_components.get("injury_penalty", 0.0)), 2),
				"salary_penalty": _round_float(float(new_components.get("salary_penalty", 0.0)), 2),
			},
		})
	return rows


func _usage_label(record: PSPlayerSeasonRecord, is_pitcher: bool) -> String:
	if record == null:
		return "-"
	if is_pitcher:
		return "GS%d/GR%d" % [record.pitcher_stats.starts, record.pitcher_stats.relief_appearances]
	return "G%d" % record.batter_stats.games


func _composition_stats(rows: Array) -> Dictionary:
	var pitchers: int = 0
	var fielders: int = 0
	var age_sum: int = 0
	var age_min: int = 999
	var age_max: int = 0
	for row_v in rows:
		var row: Dictionary = row_v as Dictionary
		if bool(row.get("is_pitcher", false)):
			pitchers += 1
		else:
			fielders += 1
		var age: int = int(row.get("age", 0))
		age_sum += age
		age_min = mini(age_min, age)
		age_max = maxi(age_max, age)
	var n: int = rows.size()
	return {
		"count": n,
		"pitchers": pitchers,
		"fielders": fielders,
		"pitcher_fielder_ratio_text": "1:%.2f" % (_safe_div(float(fielders), float(pitchers))) if pitchers > 0 else "-",
		"age_average": _round_float(_safe_div(float(age_sum), float(n)), 2),
		"age_min": age_min if n > 0 else 0,
		"age_max": age_max,
	}


# rows を key 昇順 (0=最も放出寄り) に並べたときの正規化順位 (0..1) を player id ごとに返す。
func _normalized_ranks(rows: Array, key: String) -> Dictionary:
	var n: int = rows.size()
	var sorted_rows: Array = rows.duplicate()
	sorted_rows.sort_custom(func(a, b) -> bool: return float((a as Dictionary)[key]) < float((b as Dictionary)[key]))
	var ranks: Dictionary = {}
	for i in range(n):
		var row: Dictionary = sorted_rows[i] as Dictionary
		ranks[int(row["id"])] = (float(i) / float(n - 1)) if n > 1 else 0.0
	return ranks


# 順位相関 (タイは考慮しない単純順位、較正フェーズの目安として十分な精度)。
func _spearman_correlation(rows: Array, key_a: String, key_b: String) -> float:
	var n: int = rows.size()
	if n < 2:
		return 0.0
	var idx_a: Array = range(n)
	idx_a.sort_custom(func(i, j) -> bool: return float((rows[i] as Dictionary)[key_a]) < float((rows[j] as Dictionary)[key_a]))
	var rank_a: Array = []
	rank_a.resize(n)
	for r in range(n):
		rank_a[int(idx_a[r])] = r
	var idx_b: Array = range(n)
	idx_b.sort_custom(func(i, j) -> bool: return float((rows[i] as Dictionary)[key_b]) < float((rows[j] as Dictionary)[key_b]))
	var rank_b: Array = []
	rank_b.resize(n)
	for r in range(n):
		rank_b[int(idx_b[r])] = r
	var sum_d2: float = 0.0
	for i in range(n):
		var d: float = float(int(rank_a[i]) - int(rank_b[i]))
		sum_d2 += d * d
	var n_f: float = float(n)
	return 1.0 - (6.0 * sum_d2) / (n_f * (n_f * n_f - 1.0))


# --- 出力 ----------------------------------------------------------------

func _render_markdown(report: Dictionary) -> String:
	var lines: Array = []
	lines.append("# 戦力外 projection 比較レポート")
	lines.append("")
	lines.append("seed=%d start_year=%d season_year=%d team_count=%d" % [
		int(report.get("seed", 0)), int(report.get("start_year", 0)),
		int(report.get("season_year", 0)), int(report.get("team_count", 0)),
	])
	lines.append("")

	var summary: Dictionary = report.get("league_summary", {}) as Dictionary
	lines.append("## リーグサマリー")
	lines.append("")
	lines.append("- 球団平均 Spearman 順位相関 (cut_score vs projected_value): **%.3f**" % float(summary.get("average_spearman", 0.0)))
	lines.append("- 仮想放出セット重複率 (同じ N 人で比較): **%.1f%%** (%d/%d)" % [
		float(summary.get("overlap_ratio", 0.0)) * 100.0,
		int(summary.get("total_overlap", 0)), int(summary.get("total_release_n", 0)),
	])
	lines.append("")
	var actual_set: Dictionary = summary.get("actual_release_set", {}) as Dictionary
	var projected_set: Dictionary = summary.get("projected_release_set", {}) as Dictionary
	lines.append("| 放出セット | 人数 | 投手 | 野手 | 投:野 | 平均年齢 | 最小 | 最大 |")
	lines.append("|---|---|---|---|---|---|---|---|")
	lines.append("| 現行 (compute_release_candidates_for_team) | %d | %d | %d | %s | %.2f | %d | %d |" % [
		int(actual_set.get("count", 0)), int(actual_set.get("pitchers", 0)), int(actual_set.get("fielders", 0)),
		str(actual_set.get("pitcher_fielder_ratio_text", "-")), float(actual_set.get("age_average", 0.0)),
		int(actual_set.get("age_min", 0)), int(actual_set.get("age_max", 0)),
	])
	lines.append("| 新方式 (projected_value 下位 N 人) | %d | %d | %d | %s | %.2f | %d | %d |" % [
		int(projected_set.get("count", 0)), int(projected_set.get("pitchers", 0)), int(projected_set.get("fielders", 0)),
		str(projected_set.get("pitcher_fielder_ratio_text", "-")), float(projected_set.get("age_average", 0.0)),
		int(projected_set.get("age_min", 0)), int(projected_set.get("age_max", 0)),
	])
	lines.append("")

	lines.append("## projected_value 年齢帯別平均")
	lines.append("")
	lines.append("| 年齢帯 | 対象人数 | 平均 projected_value |")
	lines.append("|---|---|---|")
	for row_v in report.get("age_band_averages", []) as Array:
		var row: Dictionary = row_v as Dictionary
		lines.append("| %s | %d | %.2f |" % [str(row["label"]), int(row["count"]), float(row["average_projected_value"])])
	lines.append("")

	lines.append("## 球団別詳細")
	lines.append("")
	lines.append("| 球団 | 在籍 | Spearman | 放出N | 重複 | 重複率 |")
	lines.append("|---|---|---|---|---|---|")
	for row_v in report.get("teams", []) as Array:
		var row: Dictionary = row_v as Dictionary
		lines.append("| %s | %d | %.3f | %d | %d | %.1f%% |" % [
			str(row["team"]), int(row["roster_size"]), float(row["spearman"]),
			int(row["release_count"]), int(row["overlap"]), float(row["overlap_ratio"]) * 100.0,
		])
	lines.append("")

	lines.append("## 不一致トップ%d (片方だけが放出対象にする選手)" % DISAGREEMENT_TOP_N)
	lines.append("")
	lines.append("`which` = actual_only: 現行方式だけが放出対象 / projected_only: 新方式だけが放出対象。")
	lines.append("")
	lines.append("| 球団 | 選手 | 年齢 | 位置 | overall | 出場 | 年俸 | which | old cut_score | new total | current | growth | usage | injury | salary |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for row_v in report.get("top_disagreements", []) as Array:
		var row: Dictionary = row_v as Dictionary
		var comp: Dictionary = row["components"] as Dictionary
		lines.append("| %s | %s | %d | %s | %d | %s | %d | %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |" % [
			str(row["team"]), str(row["name"]), int(row["age"]), str(row["position_label"]), int(row["overall"]),
			str(row["usage"]), int(row["salary"]), str(row["which"]),
			float(row["old_score"]), float(row["new_total"]),
			float(comp["current"]), float(comp["growth"]), float(comp["usage_evidence"]),
			float(comp["injury_penalty"]), float(comp["salary_penalty"]),
		])
	lines.append("")

	return "\n".join(lines)


func _print_summary(report: Dictionary, md_path: String, json_path: String) -> void:
	var summary: Dictionary = report.get("league_summary", {}) as Dictionary
	print("Release projection report: seed=%d season_year=%d teams=%d" % [
		int(report.get("seed", 0)), int(report.get("season_year", 0)), int(report.get("team_count", 0)),
	])
	print("Average Spearman (cut_score vs projected_value): %.3f" % float(summary.get("average_spearman", 0.0)))
	print("Release set overlap: %.1f%% (%d/%d)" % [
		float(summary.get("overlap_ratio", 0.0)) * 100.0,
		int(summary.get("total_overlap", 0)), int(summary.get("total_release_n", 0)),
	])
	var actual_set: Dictionary = summary.get("actual_release_set", {}) as Dictionary
	var projected_set: Dictionary = summary.get("projected_release_set", {}) as Dictionary
	print("Actual release set:    n=%d P:F=%s avg_age=%.2f (min %d / max %d)" % [
		int(actual_set.get("count", 0)), str(actual_set.get("pitcher_fielder_ratio_text", "-")),
		float(actual_set.get("age_average", 0.0)), int(actual_set.get("age_min", 0)), int(actual_set.get("age_max", 0)),
	])
	print("Projected release set: n=%d P:F=%s avg_age=%.2f (min %d / max %d)" % [
		int(projected_set.get("count", 0)), str(projected_set.get("pitcher_fielder_ratio_text", "-")),
		float(projected_set.get("age_average", 0.0)), int(projected_set.get("age_min", 0)), int(projected_set.get("age_max", 0)),
	])
	if md_path != "":
		print("Markdown: %s" % ProjectSettings.globalize_path(md_path))
	if json_path != "":
		print("JSON: %s" % ProjectSettings.globalize_path(json_path))


func _write_text(path: String, text: String) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(parent_dir)
	if make_dir_error != OK:
		print("Output directory error: %s" % error_string(make_dir_error))
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Output write error: %s" % path)
		return false
	file.store_string(text)
	return true


func _round_float(value: float, decimals: int) -> float:
	var factor: float = pow(10.0, decimals)
	return round(value * factor) / factor


func _safe_div(numerator: float, denominator: float) -> float:
	return numerator / denominator if denominator != 0.0 else 0.0


func _average(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value_v in values:
		total += float(value_v)
	return total / float(values.size())
