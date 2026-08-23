extends Node

# 野手の出場機会 (規定打席到達者数) を 1 シーズン実測して原因を切り分けるプローブ。
# health check の `qualified_batter_count` が目標帯 (両リーグ DH なので 52-65人/12球団) を
# 超えるとき、「どの入り口で出場が絞られていないか」を次の観点で出す:
#   - 規定到達者数と、到達者の先発試合数の分布 (何試合先発すると規定に届くのか)
#   - 守備位置ごとの「最多先発選手の先発シェア」と延べ先発人数 (ポジション争い・併用の有無)
#   - 出場シェア (candidates[0].share) が実際にどの水準で設定されているか
#   - 故障の発生量 — 件数・離脱日数の分布・同時離脱人数を spell 単位で (`injuries`)
# 実行: godot --headless res://tools/run_playing_time_probe.tscn -- --seasons=1 --no-farm

const QUALIFIED_PA_PER_TEAM_GAME: float = 3.1
const POSITION_LABELS: Array = ["", "投", "捕", "一", "二", "三", "遊", "左", "中", "右", "DH"]

# 故障の実測を実 NPB と比べるための参照値 (出典と導出は docs/agent_memory/project_injury_system.md)。
# 故障者リストを自前パースして数えた値。**軽傷 (数試合の欠場で登録抹消に至らないもの) は元データに
# 載らない**ため、比較対象は 15日以上 (中度以上) に限る。直接数えられるのは「ある日に離脱中だった
# 人数」だけなので、そこを主軸に見る。**完了したシーズンはオフ時点の形でしか残っていない**ので、
# 過去 4 シーズン (2022-2025) のオフ時点を正準とし、進行中の 2026 は参考扱い。
#   オフ時点 1球団あたり: 投手 3.6-5.0 (中央 4.2) / 野手 1.3-3.7 (中央 2.7)
#   2026年8月 (進行中): 投手 4.2-4.6 / 野手 2.83
# spell 件数は stock から Little の法則で推計した値 (平均離脱 45-55日 を仮定) なので幅が広い。
const NPB_BATTER_SPELLS_15PLUS_PER_TEAM: String = "8-12 (stock からの推計)"
const NPB_BATTER_SPELLS_30PLUS_PER_TEAM: String = "5-8 (stock からの推計)"
const NPB_BATTER_CONCURRENT_PER_TEAM: String = "オフ時点 2.7 (2022-2025) / 8月時点 2.83 (2026)"
const NPB_PITCHER_CONCURRENT_PER_TEAM: String = "オフ時点 4.2 (2022-2025) / 8月時点 4.2-4.6 (2026)"


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var season_rows: Array = []
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(
			GameDb.teams, 1, start_year + season_index, args.get("dh_by_league", {}) as Dictionary
		)
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# 実プレイと同じ日次フック (一軍入替・トレード・期限昇格) を通す。
		var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
		var injury_tracker: Dictionary = _new_injury_tracker()
		while _has_unplayed_game(season):
			var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, ctx)
			if not bool(day_result.get("ok", false)):
				errors.append({
					"season_index": season_index,
					"message": str(day_result.get("message", "day simulation failed")),
				})
				break
			_sample_injuries(season, injury_tracker)
		season_rows.append(_analyze_season(season, injury_tracker))

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = {
		"seed": seed_value,
		"seasons": seasons,
		"errors": errors,
		"season_reports": season_rows,
	}
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


func _analyze_season(season: PSSeason, injury_tracker: Dictionary) -> Dictionary:
	var year: int = season.year
	var season_number: int = season.season_number

	# --- スタメン集計 (season.team_lineup_history) -------------------------------
	# starts_by_team_player[team_id][player_id] = 先発数 / starts_by_team_position[team_id][pos][player_id]
	var starts_by_team_player: Dictionary = {}
	var starts_by_team_position: Dictionary = {}
	for row_value in season.team_lineup_history:
		var row: Dictionary = row_value as Dictionary
		var team_id: int = int(row.get("team_id", 0))
		var player_counts: Dictionary = starts_by_team_player.get(team_id, {}) as Dictionary
		var position_counts: Dictionary = starts_by_team_position.get(team_id, {}) as Dictionary
		for slot_value in (row.get("slots", []) as Array):
			var slot: Dictionary = slot_value as Dictionary
			var position: int = int(slot.get("pos", 0))
			if position <= 1:
				continue  # 投手枠は野手の出場機会と無関係
			var player_id: int = int(slot.get("pid", 0))
			if player_id <= 0:
				continue
			player_counts[player_id] = int(player_counts.get(player_id, 0)) + 1
			var per_position: Dictionary = position_counts.get(position, {}) as Dictionary
			per_position[player_id] = int(per_position.get(player_id, 0)) + 1
			position_counts[position] = per_position
		starts_by_team_player[team_id] = player_counts
		starts_by_team_position[team_id] = position_counts

	# --- 選手成績 ---------------------------------------------------------------
	var team_rows: Array = []
	var league_qualified: int = 0
	var league_starts_of_qualified: Array = []
	var league_pa_per_start: Array = []
	var league_injury_days: int = 0
	var league_injured_fielders: int = 0
	var league_fielder_count: int = 0
	var starts_share_by_position: Dictionary = {}
	var starters_used_by_position: Dictionary = {}
	var interval_histogram: Dictionary = {}

	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team.id, year, season_number)
		var team_games: int = 0 if team_record == null else team_record.stats.games
		var required_pa: int = int(ceil(float(team_games) * QUALIFIED_PA_PER_TEAM_GAME))
		var player_counts: Dictionary = starts_by_team_player.get(team.id, {}) as Dictionary

		var fielders: Array = []
		var qualified: int = 0
		var team_pa: int = 0
		var team_injury_days: int = 0
		var injured_fielders: int = 0
		for record_value in RecordStore.get_team_player_records(team.id, year, season_number, true):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null or record.is_pitcher():
				continue
			league_fielder_count += 1
			var plate_appearances: int = record.batter_stats.plate_appearances
			var starts: int = int(player_counts.get(record.player_id, 0))
			team_pa += plate_appearances
			team_injury_days += record.season_injury_days
			if record.season_injury_days > 0:
				injured_fielders += 1
			var is_qualified: bool = required_pa > 0 and plate_appearances >= required_pa
			if is_qualified:
				qualified += 1
				league_starts_of_qualified.append(starts)
			if starts >= 20:
				league_pa_per_start.append(float(plate_appearances) / float(starts))
			if plate_appearances > 0 or starts > 0:
				fielders.append({
					"name": record.name,
					"player_id": record.player_id,
					"games": record.batter_stats.games,
					"starts": starts,
					"pa": plate_appearances,
					"farm_games": record.farm_batter_stats.games,
					"farm_pa": record.farm_batter_stats.plate_appearances,
					"injury_days": record.season_injury_days,
					"qualified": is_qualified,
				})
		fielders.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary).get("pa", 0)) > int((b as Dictionary).get("pa", 0))
		)

		# 守備位置別: 最多先発の先発シェアと、その位置で先発した延べ人数
		var position_rows: Array = []
		var position_counts: Dictionary = starts_by_team_position.get(team.id, {}) as Dictionary
		for position_value in position_counts.keys():
			var position: int = int(position_value)
			var per_position: Dictionary = position_counts[position_value] as Dictionary
			var total_starts: int = 0
			var top_starts: int = 0
			var starters_over_10: int = 0
			for count_value in per_position.values():
				var count: int = int(count_value)
				total_starts += count
				top_starts = max(top_starts, count)
				if count >= 10:
					starters_over_10 += 1
			var share: float = 0.0 if total_starts <= 0 else float(top_starts) / float(total_starts)
			position_rows.append({
				"pos": POSITION_LABELS[position] if position < POSITION_LABELS.size() else str(position),
				"top_starts": top_starts,
				"top_share": _round2(share),
				"players_used": per_position.size(),
				"players_over_10_starts": starters_over_10,
			})
			var share_list: Array = starts_share_by_position.get(position, []) as Array
			share_list.append(share)
			starts_share_by_position[position] = share_list
			var used_list: Array = starters_used_by_position.get(position, []) as Array
			used_list.append(per_position.size())
			starters_used_by_position[position] = used_list
		position_rows.sort_custom(func(a, b) -> bool:
			return str((a as Dictionary).get("pos", "")) < str((b as Dictionary).get("pos", ""))
		)

		# 出場シェアの実効値: シーズン終了時点の守備起用設定に入っている candidates[0].share と、
		# その選手のリーグ相対 z (シェア曲線の入力)。規定打席ラインは share 0.735 前後なので、
		# 「どの守備位置がどれだけラインを越えているか」をここで直接読み取れる。
		var usage_settings: Dictionary = season.get_fielder_usage(team.id)
		var share_rows: Array = []
		for position_key in (usage_settings.get("position_slots", {}) as Dictionary).keys():
			var slot: Dictionary = (usage_settings.get("position_slots", {}) as Dictionary)[position_key] as Dictionary
			var share: float = PSDefenseAlignmentService.slot_starter_share(slot)
			var starter: PSPlayerSeasonRecord = RecordStore.get_player_record(
				PSDefenseAlignmentService.slot_starter_id(slot), year, season_number
			)
			var position_id: int = int(str(position_key))
			share_rows.append({
				"pos": POSITION_LABELS[position_id] if position_id < POSITION_LABELS.size() else str(position_id),
				"share": _round2(share),
				"z": _round2(0.0 if starter == null else PSBatterForm.regular_z(starter, position_id)),
			})
			var share_key: String = "%.1f" % (floor(share * 10.0) / 10.0)
			interval_histogram[share_key] = int(interval_histogram.get(share_key, 0)) + 1

		league_qualified += qualified
		league_injury_days += team_injury_days
		league_injured_fielders += injured_fielders
		team_rows.append({
			"starter_shares": share_rows,
			"team": team.name,
			"team_games": team_games,
			"required_pa": required_pa,
			"qualified_batters": qualified,
			"team_pa": team_pa,
			"pa_per_team_game": _round2(float(team_pa) / float(max(1, team_games))),
			"fielder_injury_days": team_injury_days,
			"injured_fielders": injured_fielders,
			"positions": position_rows,
			"top_fielders": fielders.slice(0, 14),
		})

	var position_summary: Array = []
	for position_value in starts_share_by_position.keys():
		var position: int = int(position_value)
		position_summary.append({
			"pos": POSITION_LABELS[position] if position < POSITION_LABELS.size() else str(position),
			"mean_top_starter_share": _round2(_mean(starts_share_by_position[position_value] as Array)),
			"mean_players_used": _round2(_mean(starters_used_by_position[position_value] as Array)),
		})
	position_summary.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("pos", "")) < str((b as Dictionary).get("pos", ""))
	)

	return {
		"year": year,
		"injuries": _injury_report(injury_tracker),
		"league": {
			"qualified_batters": league_qualified,
			# 両リーグ DH (打席スロット 108) 換算の目標帯。片リーグ DH の NPB 実績 48-61 と等価。
			"npb_reference": "52-65",
			"fielder_records": league_fielder_count,
			"mean_starts_of_qualified": _round2(_mean(league_starts_of_qualified)),
			"min_starts_of_qualified": _min_value(league_starts_of_qualified),
			"mean_pa_per_start": _round2(_mean(league_pa_per_start)),
			"fielder_injury_days_total": league_injury_days,
			"fielder_injury_days_per_team": _round2(float(league_injury_days) / float(max(1, GameDb.teams.size()))),
			"injured_fielders": league_injured_fielders,
		},
		# share=s → 先発 143×s 試合。規定打席 (444) には先発 105 試合 ≒ share 0.735 で届くので、
		# 0.7 以下の帯が「規定を割る」設定。
		"starter_share_histogram": interval_histogram,
		"position_summary": position_summary,
		"teams": team_rows,
	}


# --- 故障の実測 (spell 単位) -------------------------------------------------
# `record.season_injury_days` は発生時にその離脱日数ぶんだけ加算される累計値なので、日次で差分を
# 見れば「いつ・誰が・何日の故障をしたか」が spell 単位で復元できる (record 側に履歴は残らない)。
# 併せて「その日離脱中だった人数」を数える — 実 NPB の故障者リストは同時離脱人数の形で読めるため。
func _new_injury_tracker() -> Dictionary:
	return {
		"seen_days": {},   # player_id -> それまでに観測した season_injury_days の累計
		"spells": [],      # {days, severity, is_pitcher}
		# 日ごとの離脱中人数。`_15plus` は中度以上 (= 実 NPB の故障者リストに載る水準) だけを数える。
		"daily_batter": [],
		"daily_batter_15plus": [],
		"daily_pitcher": [],
		"daily_pitcher_15plus": [],
	}


func _sample_injuries(season: PSSeason, tracker: Dictionary) -> void:
	var seen_days: Dictionary = tracker["seen_days"] as Dictionary
	var spells: Array = tracker["spells"] as Array
	var out_batter: int = 0
	var out_batter_15plus: int = 0
	var out_pitcher: int = 0
	var out_pitcher_15plus: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		for record_value in RecordStore.get_team_player_records(team.id, season.year, season.season_number, true):
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if record == null:
				continue
			var is_pitcher: bool = record.is_pitcher()
			if record.injury_days > 0:
				var is_15plus: bool = record.injury_severity >= PSInjuryModel.TIER_MODERATE
				if is_pitcher:
					out_pitcher += 1
					out_pitcher_15plus += 1 if is_15plus else 0
				else:
					out_batter += 1
					out_batter_15plus += 1 if is_15plus else 0
			var previous: int = int(seen_days.get(record.player_id, 0))
			var current: int = record.season_injury_days
			if current > previous:
				seen_days[record.player_id] = current
				spells.append({
					"days": current - previous,
					"severity": record.injury_severity,
					"is_pitcher": is_pitcher,
				})
	(tracker["daily_batter"] as Array).append(out_batter)
	(tracker["daily_batter_15plus"] as Array).append(out_batter_15plus)
	(tracker["daily_pitcher"] as Array).append(out_pitcher)
	(tracker["daily_pitcher_15plus"] as Array).append(out_pitcher_15plus)


func _injury_report(tracker: Dictionary) -> Dictionary:
	var team_count: int = max(1, GameDb.teams.size())
	var batter_days: Array = []
	var pitcher_days: Array = []
	var batter_tiers: Dictionary = {}
	var pitcher_tiers: Dictionary = {}
	for spell_value in (tracker["spells"] as Array):
		var spell: Dictionary = spell_value as Dictionary
		var days: int = int(spell.get("days", 0))
		var severity: int = int(spell.get("severity", 0))
		if bool(spell.get("is_pitcher", false)):
			pitcher_days.append(days)
			pitcher_tiers[severity] = int(pitcher_tiers.get(severity, 0)) + 1
		else:
			batter_days.append(days)
			batter_tiers[severity] = int(batter_tiers.get(severity, 0)) + 1
	return {
		"note": "軽傷は実 NPB の故障者リストに載らないので、比較は 15日以上 (_15plus) の値で行う",
		"batter": _injury_side_report(
			batter_days, batter_tiers, team_count,
			tracker["daily_batter"] as Array, tracker["daily_batter_15plus"] as Array
		),
		"pitcher": _injury_side_report(
			pitcher_days, pitcher_tiers, team_count,
			tracker["daily_pitcher"] as Array, tracker["daily_pitcher_15plus"] as Array
		),
		"npb_reference_batter": {
			"spells_15plus_per_team": NPB_BATTER_SPELLS_15PLUS_PER_TEAM,
			"spells_30plus_per_team": NPB_BATTER_SPELLS_30PLUS_PER_TEAM,
			"season_end_concurrent_15plus_per_team": NPB_BATTER_CONCURRENT_PER_TEAM,
		},
		"npb_reference_pitcher": {
			"season_end_concurrent_15plus_per_team": NPB_PITCHER_CONCURRENT_PER_TEAM,
		},
	}


func _injury_side_report(
	days_list: Array, tier_counts: Dictionary, team_count: int,
	daily_out: Array, daily_out_15plus: Array
) -> Dictionary:
	var total_days: int = 0
	var count_15plus: int = 0
	var count_30plus: int = 0
	var count_60plus: int = 0
	var days_15plus: Array = []
	for value in days_list:
		var days: int = int(value)
		total_days += days
		if days >= 15:
			count_15plus += 1
			days_15plus.append(days)
		if days >= 30:
			count_30plus += 1
		if days >= 60:
			count_60plus += 1
	var teams: float = float(team_count)
	return {
		"spells": days_list.size(),
		"spells_per_team": _round2(float(days_list.size()) / teams),
		"spells_15plus_per_team": _round2(float(count_15plus) / teams),
		"spells_30plus_per_team": _round2(float(count_30plus) / teams),
		"spells_60plus_per_team": _round2(float(count_60plus) / teams),
		"days_total": total_days,
		"days_per_team": _round2(float(total_days) / teams),
		"mean_days": _round2(_mean(days_list)),
		"median_days": _median(days_list),
		"mean_days_15plus": _round2(_mean(days_15plus)),
		"tier_counts": tier_counts,
		"mean_concurrent_per_team": _round2(_mean(daily_out) / teams),
		"mean_concurrent_15plus_per_team": _round2(_mean(daily_out_15plus) / teams),
		# 実 NPB の故障者リストは特定日のスナップショット。同じ土俵で比べるための値を 2 つ出す:
		#   late_season … 終盤30日平均。進行中シーズン (8月時点) のリストと比べる用。
		#   season_end  … 最終日の実数。**過去シーズンのオフ時点スナップショットと比べる用**で、
		#                 完了した年のデータはこの形でしか残っていないため、こちらが主。
		"late_season_concurrent_15plus_per_team": _round2(_mean(_tail(daily_out_15plus, 30)) / teams),
		"season_end_concurrent_15plus_per_team": _round2(
			float(int(daily_out_15plus[daily_out_15plus.size() - 1])) / teams
			if not daily_out_15plus.is_empty() else 0.0
		),
	}


# 配列の末尾 count 件 (足りなければ全部)。
func _tail(values: Array, count: int) -> Array:
	if values.size() <= count:
		return values
	return values.slice(values.size() - count, values.size())


func _median(values: Array) -> int:
	if values.is_empty():
		return 0
	var sorted_values: Array = values.duplicate()
	sorted_values.sort()
	return int(sorted_values[sorted_values.size() / 2])


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _min_value(values: Array) -> int:
	if values.is_empty():
		return 0
	var best: int = int(values[0])
	for value in values:
		best = min(best, int(value))
	return best


func _round2(value: float) -> float:
	return round(value * 100.0) / 100.0


func _parse_args() -> Dictionary:
	var options: Dictionary = {}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg_value in args:
		var arg: String = str(arg_value)
		if arg == "--no-farm":
			PSFarmGameRunner.enabled = false
		elif arg == "--single-dh-league":
			# 既定は両リーグ DH (AppState.league_dh_enabled の既定と同じ)。NPB は片方だけなので、
			# 「打席スロットが 1 球団あたり 9 か 8 か」が到達者数に効く量を測るときにこれを付ける。
			options["dh_by_league"] = {"league1": true, "league2": false}
		elif arg.begins_with("--seasons="):
			options["seasons"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--start-year="):
			options["start_year"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
	return options
