extends RefCounted
class_name PSGameDecisions

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")


static func apply_game_decisions(season: PSSeason, away_team_id: int, home_team_id: int, result: Dictionary) -> void:
	var away_score: int = int(result.get("away_score", 0))
	var home_score: int = int(result.get("home_score", 0))
	apply_team_result(season, away_team_id, away_score, home_score)
	apply_team_result(season, home_team_id, home_score, away_score)

	merge_game_advanced_stats(season, result)

	var away_starter_id: int = int(result.get("away_pitcher_id", 0))
	var home_starter_id: int = int(result.get("home_pitcher_id", 0))
	var decisions: Dictionary = compute_pitching_decisions(result, away_team_id, home_team_id, away_starter_id, home_starter_id)

	var winning_pitcher_id: int = int(decisions.get("winning_pitcher_id", 0))
	var losing_pitcher_id: int = int(decisions.get("losing_pitcher_id", 0))
	var save_pitcher_id: int = int(decisions.get("save_pitcher_id", 0))
	var hold_pitcher_ids: Array = decisions.get("hold_pitcher_ids", []) as Array

	result["winning_pitcher_id"] = winning_pitcher_id
	result["losing_pitcher_id"] = losing_pitcher_id
	result["save_pitcher_id"] = save_pitcher_id
	result["hold_pitcher_ids"] = hold_pitcher_ids

	if bool(result.get("draw", false)):
		for pid_value in hold_pitcher_ids:
			var draw_hold_pid: int = int(pid_value)
			if draw_hold_pid > 0:
				apply_pitcher_decision(season, draw_hold_pid, "hold")
		return

	if winning_pitcher_id > 0:
		apply_pitcher_decision(season, winning_pitcher_id, "win")
	if losing_pitcher_id > 0:
		apply_pitcher_decision(season, losing_pitcher_id, "loss")
	if save_pitcher_id > 0:
		apply_pitcher_decision(season, save_pitcher_id, "save")
	for pid_value in hold_pitcher_ids:
		var pid: int = int(pid_value)
		if pid > 0:
			apply_pitcher_decision(season, pid, "hold")


static func compute_pitching_decisions(result: Dictionary, away_team_id: int, home_team_id: int, away_starter_id: int, home_starter_id: int) -> Dictionary:
	var empty: Dictionary = {
		"winning_pitcher_id": 0,
		"losing_pitcher_id": 0,
		"save_pitcher_id": 0,
		"hold_pitcher_ids": [],
	}
	if bool(result.get("draw", false)):
		empty["hold_pitcher_ids"] = hold_pitchers_from_outings(result.get("pitcher_outings", []) as Array, 0, 0, 0)
		return empty
	var outing_decisions: Dictionary = compute_pitching_decisions_from_outings(result, away_team_id, home_team_id, away_starter_id, home_starter_id)
	if not outing_decisions.is_empty():
		return outing_decisions
	var innings: Array = result.get("innings", []) as Array
	if innings.is_empty():
		return empty

	var winning_team_id: int = int(result.get("winning_team_id", 0))
	var winning_is_home: bool = (winning_team_id == home_team_id)

	var away_cum: int = 0
	var home_cum: int = 0
	var winning_was_leading: bool = false
	var last_lead_take_inning_index: int = -1
	var last_lead_take_half: String = ""

	for i in range(innings.size()):
		var entry: Dictionary = innings[i] as Dictionary
		away_cum += int(entry.get("away", 0))
		var winning_score: int = home_cum if winning_is_home else away_cum
		var losing_score: int = away_cum if winning_is_home else home_cum
		var is_leading_now: bool = winning_score > losing_score
		if is_leading_now and not winning_was_leading:
			last_lead_take_inning_index = i
			last_lead_take_half = "top"
		winning_was_leading = is_leading_now

		if bool(entry.get("home_half_played", true)):
			home_cum += int(entry.get("home", 0))
			winning_score = home_cum if winning_is_home else away_cum
			losing_score = away_cum if winning_is_home else home_cum
			is_leading_now = winning_score > losing_score
			if is_leading_now and not winning_was_leading:
				last_lead_take_inning_index = i
				last_lead_take_half = "bot"
			winning_was_leading = is_leading_now

	if last_lead_take_inning_index < 0:
		return empty

	var lead_entry: Dictionary = innings[last_lead_take_inning_index] as Dictionary
	var home_pitcher_in_half: int = int(lead_entry.get("home_team_pitcher_id", home_starter_id))
	var away_pitcher_in_half: int = int(lead_entry.get("away_team_pitcher_id", away_starter_id))

	var winning_pitcher_id: int = 0
	var losing_pitcher_id: int = 0

	if winning_is_home:
		if last_lead_take_half == "bot":
			winning_pitcher_id = home_pitcher_in_half
			losing_pitcher_id = away_pitcher_in_half
		else:
			winning_pitcher_id = home_starter_id
			losing_pitcher_id = home_pitcher_in_half
	else:
		if last_lead_take_half == "top":
			losing_pitcher_id = home_pitcher_in_half
			if last_lead_take_inning_index == 0:
				winning_pitcher_id = away_starter_id
			else:
				var prev_entry: Dictionary = innings[last_lead_take_inning_index - 1] as Dictionary
				var prev_away_pid: int = int(prev_entry.get("away_team_pitcher_id", 0))
				if prev_away_pid <= 0:
					prev_away_pid = away_starter_id
				winning_pitcher_id = prev_away_pid
		else:
			winning_pitcher_id = away_starter_id
			losing_pitcher_id = away_pitcher_in_half

	var winning_pitcher_sequence: Array = []
	for entry_row in innings:
		var entry: Dictionary = entry_row as Dictionary
		var pid: int
		if winning_is_home:
			pid = int(entry.get("home_team_pitcher_id", 0))
		else:
			if not bool(entry.get("home_half_played", true)):
				continue
			pid = int(entry.get("away_team_pitcher_id", 0))
		if pid <= 0:
			continue
		if winning_pitcher_sequence.is_empty() or int(winning_pitcher_sequence[-1]) != pid:
			winning_pitcher_sequence.append(pid)

	var save_pitcher_id: int = 0
	var hold_pitcher_ids: Array = []

	if not winning_pitcher_sequence.is_empty():
		var last_pitcher_id: int = int(winning_pitcher_sequence[-1])
		if last_pitcher_id != winning_pitcher_id:
			var entry_lead: int = lead_at_pitcher_entry(innings, winning_is_home, last_pitcher_id)
			var outs_recorded: int = outs_for_pitcher_in_innings(innings, winning_is_home, last_pitcher_id)
			if entry_lead >= 1 and (outs_recorded >= 9 or (entry_lead <= 3 and outs_recorded >= 3)):
				save_pitcher_id = last_pitcher_id

		for i in range(winning_pitcher_sequence.size()):
			var pid: int = int(winning_pitcher_sequence[i])
			if i == 0:
				continue
			if pid == winning_pitcher_id or pid == save_pitcher_id:
				continue
			var entry_lead: int = lead_at_pitcher_entry(innings, winning_is_home, pid)
			var exit_lead: int = lead_at_pitcher_exit(innings, winning_is_home, pid)
			var outs_recorded: int = outs_for_pitcher_in_innings(innings, winning_is_home, pid)
			if entry_lead >= 1 and exit_lead >= 1 and (outs_recorded >= 9 or (entry_lead <= 3 and outs_recorded >= 3)):
				hold_pitcher_ids.append(pid)

	return {
		"winning_pitcher_id": winning_pitcher_id,
		"losing_pitcher_id": losing_pitcher_id,
		"save_pitcher_id": save_pitcher_id,
		"hold_pitcher_ids": hold_pitcher_ids,
	}


static func compute_pitching_decisions_from_outings(
	result: Dictionary,
	away_team_id: int,
	home_team_id: int,
	away_starter_id: int,
	home_starter_id: int
) -> Dictionary:
	var outings: Array = result.get("pitcher_outings", []) as Array
	if outings.is_empty():
		return {}
	var winning_team_id: int = int(result.get("winning_team_id", 0))
	if winning_team_id <= 0:
		return {}
	var losing_team_id: int = home_team_id if winning_team_id == away_team_id else away_team_id
	var winning_starter_id: int = away_starter_id if winning_team_id == away_team_id else home_starter_id
	var winning_outings: Array = outings_for_team(outings, winning_team_id)
	var losing_outings: Array = outings_for_team(outings, losing_team_id)
	if winning_outings.is_empty() or losing_outings.is_empty():
		return {}

	var lead_change: Dictionary = result.get("last_lead_change", {}) as Dictionary
	var winning_pitcher_id: int = 0
	var losing_pitcher_id: int = 0
	if int(lead_change.get("winning_team_id", 0)) == winning_team_id:
		var lead_event_index: int = int(lead_change.get("event_index", 0))
		losing_pitcher_id = int(lead_change.get("losing_pitcher_id", 0))
		winning_pitcher_id = latest_pitcher_before_event(winning_outings, lead_event_index, winning_starter_id)
	if winning_pitcher_id <= 0:
		winning_pitcher_id = winning_starter_id
	if losing_pitcher_id <= 0:
		losing_pitcher_id = int((losing_outings[0] as Dictionary).get("pitcher_id", 0))

	var save_pitcher_id: int = save_pitcher_from_outings(winning_outings, winning_pitcher_id)
	var hold_pitcher_ids: Array = hold_pitchers_from_outings(outings, winning_pitcher_id, losing_pitcher_id, save_pitcher_id)
	return {
		"winning_pitcher_id": winning_pitcher_id,
		"losing_pitcher_id": losing_pitcher_id,
		"save_pitcher_id": save_pitcher_id,
		"hold_pitcher_ids": hold_pitcher_ids,
	}


static func outings_for_team(outings: Array, team_id: int) -> Array:
	var rows: Array = []
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		if int(outing.get("team_id", 0)) == team_id:
			rows.append(outing)
	rows.sort_custom(func(a, b) -> bool:
		var outing_a: Dictionary = a as Dictionary
		var outing_b: Dictionary = b as Dictionary
		return int(outing_a.get("start_event_index", 0)) < int(outing_b.get("start_event_index", 0))
	)
	return rows


static func latest_pitcher_before_event(outings: Array, event_index: int, fallback_pitcher_id: int) -> int:
	var selected_id: int = 0
	var selected_end: int = -999999
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		var end_index: int = int(outing.get("end_event_index", -1))
		if end_index < event_index and end_index >= selected_end:
			selected_id = int(outing.get("pitcher_id", 0))
			selected_end = end_index
	if selected_id > 0:
		return selected_id
	return fallback_pitcher_id


static func save_pitcher_from_outings(winning_outings: Array, winning_pitcher_id: int) -> int:
	if winning_outings.is_empty():
		return 0
	var last: Dictionary = winning_outings[winning_outings.size() - 1] as Dictionary
	var pitcher_id: int = int(last.get("pitcher_id", 0))
	if pitcher_id <= 0 or pitcher_id == winning_pitcher_id:
		return 0
	if str(last.get("role", "")) == PSPitcherUsageModel.ROLE_STARTER:
		return 0
	var outs_recorded: int = int(last.get("outs", 0))
	var entry_lead: int = int(last.get("entry_lead", 0))
	var exit_lead: int = int(last.get("exit_lead", 0))
	if outs_recorded <= 0 or entry_lead <= 0 or exit_lead <= 0:
		return 0
	if save_situation_from_outing(last):
		return pitcher_id
	return 0


static func hold_pitchers_from_outings(outings: Array, winning_pitcher_id: int, losing_pitcher_id: int, save_pitcher_id: int) -> Array:
	var ids: Array = []
	var seen: Dictionary = {}
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		var pitcher_id: int = int(outing.get("pitcher_id", 0))
		if pitcher_id <= 0 or pitcher_id == winning_pitcher_id or pitcher_id == losing_pitcher_id or pitcher_id == save_pitcher_id:
			continue
		if seen.has(pitcher_id):
			continue
		if str(outing.get("role", "")) == PSPitcherUsageModel.ROLE_STARTER:
			continue
		var outs_recorded: int = int(outing.get("outs", 0))
		var entry_lead: int = int(outing.get("entry_lead", 0))
		var exit_lead: int = int(outing.get("exit_lead", 0))
		if outs_recorded < 1:
			continue
		if entry_lead > 0 and exit_lead > 0 and save_situation_from_outing(outing):
			ids.append(pitcher_id)
			seen[pitcher_id] = true
		elif entry_lead == 0 and exit_lead >= 0 and int(outing.get("runs", 0)) == 0:
			ids.append(pitcher_id)
			seen[pitcher_id] = true
	return ids


static func save_situation_from_outing(outing: Dictionary) -> bool:
	var outs_recorded: int = int(outing.get("outs", 0))
	var entry_lead: int = int(outing.get("entry_lead", 0))
	if entry_lead <= 0:
		return false
	if outs_recorded >= 9:
		return true
	if entry_lead <= 3 and outs_recorded >= 3:
		return true
	var base_runners: int = int(outing.get("entry_base_runners", int(outing.get("inherited_runners", 0))))
	return entry_lead <= base_runners + 2


static func lead_at_pitcher_entry(innings: Array, winning_is_home: bool, pitcher_id: int) -> int:
	var away_cum: int = 0
	var home_cum: int = 0
	for i in range(innings.size()):
		var entry: Dictionary = innings[i] as Dictionary
		if winning_is_home:
			if int(entry.get("home_team_pitcher_id", 0)) == pitcher_id:
				var is_first: bool = true
				if i > 0:
					var prev: Dictionary = innings[i - 1] as Dictionary
					if int(prev.get("home_team_pitcher_id", 0)) == pitcher_id:
						is_first = false
				if is_first:
					return home_cum - away_cum
			away_cum += int(entry.get("away", 0))
			if bool(entry.get("home_half_played", true)):
				home_cum += int(entry.get("home", 0))
		else:
			away_cum += int(entry.get("away", 0))
			if bool(entry.get("home_half_played", true)):
				if int(entry.get("away_team_pitcher_id", 0)) == pitcher_id:
					var is_first: bool = true
					if i > 0:
						var prev: Dictionary = innings[i - 1] as Dictionary
						if int(prev.get("away_team_pitcher_id", 0)) == pitcher_id and bool(prev.get("home_half_played", true)):
							is_first = false
					if is_first:
						return away_cum - home_cum
				home_cum += int(entry.get("home", 0))
	return 0


static func lead_at_pitcher_exit(innings: Array, winning_is_home: bool, pitcher_id: int) -> int:
	var away_cum: int = 0
	var home_cum: int = 0
	var last_lead: int = 0
	var found: bool = false
	for i in range(innings.size()):
		var entry: Dictionary = innings[i] as Dictionary
		if winning_is_home:
			away_cum += int(entry.get("away", 0))
			if int(entry.get("home_team_pitcher_id", 0)) == pitcher_id:
				last_lead = home_cum - away_cum
				found = true
			if bool(entry.get("home_half_played", true)):
				home_cum += int(entry.get("home", 0))
		else:
			away_cum += int(entry.get("away", 0))
			if bool(entry.get("home_half_played", true)):
				home_cum += int(entry.get("home", 0))
				if int(entry.get("away_team_pitcher_id", 0)) == pitcher_id:
					last_lead = away_cum - home_cum
					found = true
	return last_lead if found else 0


static func outs_for_pitcher_in_innings(innings: Array, winning_is_home: bool, pitcher_id: int) -> int:
	var halves: int = 0
	for entry_row in innings:
		var entry: Dictionary = entry_row as Dictionary
		if winning_is_home:
			if int(entry.get("home_team_pitcher_id", 0)) == pitcher_id:
				halves += 1
		else:
			if int(entry.get("away_team_pitcher_id", 0)) == pitcher_id and bool(entry.get("home_half_played", true)):
				halves += 1
	return halves * 3


# 試合結果の advanced_stats を選手の PSPlayerSeasonRecord.advanced_stats へ累積する。
# players バケット (野手 + 守備 + 走塁) と pitchers バケット (投手の被打席) の両方を扱う。
# 同一 player_id が両方に出る (大谷型二刀流) ケースは現状想定外だが、両方とも record に
# add_from されるので結果として打撃面 / 投手面の両方が累積される。
static func merge_game_advanced_stats(season: PSSeason, result: Dictionary) -> void:
	var advanced_stats: Dictionary = result.get("advanced_stats", {}) as Dictionary
	if advanced_stats.is_empty():
		return
	for bucket_name in ["players", "pitchers"]:
		var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		for key_value in bucket.keys():
			var key: String = str(key_value)
			var entry: Dictionary = bucket.get(key_value, {}) as Dictionary
			var player_id: int = int(entry.get("player_id", 0))
			if player_id == 0 and key.is_valid_int():
				player_id = int(key)
			if player_id == 0:
				continue
			var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
			if record == null:
				continue
			var delta = AdvancedStatsRecord.new()
			delta.load_from_dict(entry)
			if delta.player_id == 0:
				delta.player_id = player_id
			if record.advanced_stats == null:
				record.advanced_stats = AdvancedStatsRecord.new()
			if record.advanced_stats.player_id == 0:
				record.advanced_stats.player_id = player_id
			record.advanced_stats.add_from(delta)


static func apply_team_result(season: PSSeason, team_id: int, runs_scored: int, runs_allowed: int) -> void:
	if not season.standings.has(team_id):
		season.standings[team_id] = PSStats.new()
	var stats: PSStats = season.standings[team_id] as PSStats
	add_team_stats(stats, runs_scored, runs_allowed)

	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
	if team_record != null:
		add_team_stats(team_record.stats, runs_scored, runs_allowed)


static func add_team_stats(stats: PSStats, runs_scored: int, runs_allowed: int) -> void:
	stats.games += 1
	stats.runs_scored += runs_scored
	stats.runs_allowed += runs_allowed
	if runs_scored > runs_allowed:
		stats.wins += 1
	elif runs_scored < runs_allowed:
		stats.losses += 1
	else:
		stats.draws += 1


static func apply_pitcher_decision(season: PSSeason, pitcher_id: int, kind: String) -> void:
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pitcher_id, season.year, season.season_number)
	if record == null:
		return
	match kind:
		"win":
			record.pitcher_stats.wins += 1
		"loss":
			record.pitcher_stats.losses += 1
		"save":
			record.pitcher_stats.saves += 1
		"hold":
			record.pitcher_stats.holds += 1


static func finalize_pitcher_stats(setup: Dictionary, _result: Dictionary) -> void:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", setup.get("pitcher", null)) as PSPlayerSeasonRecord
	if starter == null:
		return
	var starter_outing: Dictionary = starter_outing_for_setup(setup, _result)
	var starter_outs_raw: int = int(setup.get("starter_outs", -1))
	var starter_runs_raw: int = int(setup.get("starter_runs", -1))
	var starter_outs: int = int(starter_outing.get("outs", -1))
	var starter_runs: int = int(starter_outing.get("runs", -1))
	if starter_outs < 0:
		starter_outs = int(setup.get("game_outs", 0)) if starter_outs_raw < 0 else starter_outs_raw
	if starter_runs < 0:
		starter_runs = int(setup.get("game_runs_allowed", 0)) if starter_runs_raw < 0 else starter_runs_raw
	# 完投 = 一度も救援を仰がず試合を終えたこと。アウト数だけで判定すると
	# 「8回を投げ切って9回頭に降板した先発」(24アウト)が全て完投扱いになり完投率が桁違いに膨らむ。
	# 24アウト下限は、ビジター先発が8回完了で終わる完投負け(本物の完投)を含めるための保険。
	var starter_finished: bool = not bool(setup.get("starter_relieved", false))
	if starter_finished and starter_outs >= 24:
		starter.pitcher_stats.complete_games += 1
		if starter_runs == 0:
			starter.pitcher_stats.shutouts += 1
	if starter_outs >= 18 and starter_runs <= 3:
		starter.pitcher_stats.quality_starts += 1


static func starter_outing_for_setup(setup: Dictionary, result: Dictionary) -> Dictionary:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", setup.get("pitcher", null)) as PSPlayerSeasonRecord
	if starter == null:
		return {}
	var team_id: int = int(setup.get("team_id", 0))
	var outings: Array = result.get("pitcher_outings", []) as Array
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		if int(outing.get("team_id", 0)) == team_id and int(outing.get("pitcher_id", 0)) == starter.player_id:
			return outing
	return {}


static func advance_current_day(season: PSSeason) -> void:
	var previous_day: int = season.current_day
	var next_day: int = 0
	var last_day: int = season.current_day
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		last_day = max(last_day, int(game.get("day", 0)))
		if bool(game.get("played", false)):
			continue
		next_day = int(game.get("day", 0))
		break
	season.current_day = last_day + 1 if next_day == 0 else next_day
	if season.current_day != previous_day:
		var elapsed_days: int = max(1, season.current_day - previous_day)
		recover_after_day(season, elapsed_days)


static func recover_after_day(season: PSSeason, elapsed_days: int = 1) -> void:
	var days: int = max(1, elapsed_days)
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			var recovery: int = daily_recovery_amount(record) * days
			record.fatigue = int(max(0, record.fatigue - recovery))
			if record.injury_days > 0:
				var previous_injury_days: int = record.injury_days
				record.injury_days = int(max(0, record.injury_days - days))
				if record.injury_days == 0:
					record.injury_return_day = season.current_day - max(0, days - previous_injury_days)


static func daily_recovery_amount(record: PSPlayerSeasonRecord) -> int:
	if record.is_pitcher():
		return PSPitcherUsageModel.daily_recovery_amount(record)
	return fielder_daily_recovery_amount(record)


static func fielder_daily_recovery_amount(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	var recovery: float = 5.0
	recovery += clamp(float(30 - record.age) * 0.12, -1.5, 1.0)
	if record.injury_days > 0:
		recovery += 1.5
	if record.fatigue >= 120:
		recovery += 1.0
	return int(clamp(round(recovery), 3.0, 8.0))


static func persist_records() -> void:
	RecordStore.save_records()
	RecordStore.records_changed.emit()
