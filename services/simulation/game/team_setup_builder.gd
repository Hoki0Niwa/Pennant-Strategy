extends RefCounted
class_name PSTeamSetupBuilder

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const BattingOrderProfile = preload("res://domain/batting_order_profile.gd")
const BattingOrderService = preload("res://services/simulation/lineup/batting_order_service.gd")
const DefenseAlignmentProfile = preload("res://domain/defense_alignment_profile.gd")
const DefenseAlignmentService = preload("res://services/simulation/lineup/defense_alignment_service.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")

const SUB_INTERVAL_FATIGUE_EMERGENCY: int = -1
const MIN_ACTIVE_CATCHERS: int = 2
# 先発候補は保存 role を正準にする。先発 role が1人でもいればリリーフをローテへ混ぜず、
# 先発ゼロの小規模/壊れたロスターだけ緊急補充を許す。その補充上限がこの定数。
const STARTER_POOL_MIN: int = 5


static func build_team_setup(season: PSSeason, team_id: int, dh_enabled: bool) -> Dictionary:
	var prepared: Dictionary = prepare_team_setup(season, team_id, dh_enabled)
	if not bool(prepared.get("ok", false)):
		return prepared

	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	var available_fielders: Array = prepared["available_fielders"] as Array
	var reliever_pool: Array = prepared.get("reliever_pool", []) as Array
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starter_pitchers, team_record)
	var rotation_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	if rotation_pitcher == null:
		return {"ok": false, "message": "%sの先発投手を決定できません" % GameSimulator._team_name(team_id)}
	var saved_rotation: Dictionary = season.get_rotation(team_id)
	var relievers: Array = PSRotationPlanner.select_relievers_for_innings(reliever_pool, starter_pitchers, rotation_pitcher.player_id, saved_rotation)
	var relief_role_by_pitcher: Dictionary = PSRotationPlanner.relief_role_by_pitcher(saved_rotation, relievers)
	var team_games_played_before: int = 0 if team_record == null else int(team_record.stats.games)

	# auto_lineup ON は保存済み打順を使わず、その日のロスターから打順と守備配置を毎試合作る。
	# OFF のチームは保存設定を優先し、欠員などで組めない場合だけ自動生成へフォールバックする。
	var setup: Dictionary = {}
	var team: PSTeam = GameDb.get_team(team_id)
	var use_saved: bool = team == null or not team.auto_lineup
	if use_saved:
		var saved: Dictionary = season.get_lineup(team_id, dh_enabled)
		if not saved.is_empty():
			var saved_setup: Dictionary = build_setup_from_saved(season, team_id, dh_enabled, available_fielders, rotation_pitcher, saved)
			if bool(saved_setup.get("ok", false)):
				setup = saved_setup

	if setup.is_empty():
		setup = build_setup_from_auto(season, team_id, dh_enabled, available_fielders, rotation_pitcher, team_games_played_before)

	if bool(setup.get("ok", false)):
		setup["starter_pitcher"] = rotation_pitcher
		setup["relievers"] = relievers
		setup["relief_role_by_pitcher"] = relief_role_by_pitcher
		setup["starter_outs"] = -1
		setup["starter_runs"] = -1
		setup["starter_relieved"] = false
		setup["team_games_played_before"] = team_games_played_before
		setup["game_day"] = season.current_day
		setup["rotation_order_ids"] = rotation_decision.get("order_ids", [])
		setup["rotation_selected_index"] = int(rotation_decision.get("selected_index", -1))
		setup["rotation_reason"] = str(rotation_decision.get("reason", ""))
	return setup


static func preview_lineup(season: PSSeason, team_id: int, dh_enabled: bool) -> Dictionary:
	var prepared: Dictionary = prepare_team_setup(season, team_id, dh_enabled)
	if not bool(prepared.get("ok", false)):
		return prepared

	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	var available_fielders: Array = prepared["available_fielders"] as Array
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starter_pitchers, team_record)
	var rotation_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	if rotation_pitcher == null:
		return {"ok": false, "message": "%sの先発投手を決定できません" % GameSimulator._team_name(team_id)}

	var team_games_played_before: int = 0 if team_record == null else int(team_record.stats.games)
	var setup: Dictionary = build_setup_from_auto(season, team_id, dh_enabled, available_fielders, rotation_pitcher, team_games_played_before)
	if not bool(setup.get("ok", false)):
		return setup

	var lineup: Dictionary = setup_to_lineup_dict(setup, dh_enabled, rotation_pitcher)
	lineup["ok"] = true
	lineup["pitcher_id"] = rotation_pitcher.player_id
	return lineup


static func preview_rotation(season: PSSeason, team_id: int) -> Dictionary:
	var prepared: Dictionary = prepare_team_setup(season, team_id)
	if not bool(prepared.get("ok", false)):
		return prepared

	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starter_pitchers, team_record)
	var pitcher_ids: Array = rotation_decision.get("order_ids", []) as Array
	var games_played: int = 0 if team_record == null else team_record.stats.games
	var next_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	var next_pitcher_id: int = 0 if next_pitcher == null else next_pitcher.player_id

	return {
		"ok": true,
		"pitcher_ids": pitcher_ids,
		"next_pitcher_id": next_pitcher_id,
		"games_played": games_played,
		"next_rotation_index": int(rotation_decision.get("next_rotation_index", 0)),
		"rotation_selected_index": int(rotation_decision.get("selected_index", -1)),
		"rotation_reason": str(rotation_decision.get("reason", "")),
	}


static func resolve_rotation_order(season: PSSeason, team_id: int) -> Array:
	var prepared: Dictionary = prepare_team_setup(season, team_id)
	if not bool(prepared.get("ok", false)):
		return []
	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	return PSRotationPlanner.resolve_rotation_order_from_saved(season.get_rotation(team_id), starter_pitchers)


static func preview_active_roster(season: PSSeason, team_id: int, dh_enabled: bool = true) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	if all_records.is_empty():
		return {"ok": false, "message": "%sの選手データがありません" % GameSimulator._team_name(team_id)}

	const TARGET_TOTAL: int = 31
	const TARGET_STARTERS: int = 6
	const TARGET_PITCHERS: int = 15
	var starters: Array = []
	var relievers: Array = []
	var fielders: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		# roadmap #3: 育成選手は一軍登録不可 (試合に出場できない)。
		if record.development_player:
			continue
		if record.is_pitcher():
			if _is_starter_role(record):
				starters.append(record)
			else:
				relievers.append(record)
		else:
			fielders.append(record)

	var by_overall: Callable = func(a, b) -> bool:
		return _active_roster_selection_score(a as PSPlayerSeasonRecord) > _active_roster_selection_score(b as PSPlayerSeasonRecord)
	starters.sort_custom(by_overall)
	relievers.sort_custom(by_overall)
	fielders.sort_custom(by_overall)

	var selected: Array = []
	var foreign_counts: Dictionary = ForeignActiveRosterRules.empty_counts()
	var add_player: Callable = func(record: PSPlayerSeasonRecord) -> bool:
		if record == null or record.injury_days > 0:
			return false
		if selected.size() >= TARGET_TOTAL:
			return false
		for selected_row in selected:
			if (selected_row as PSPlayerSeasonRecord).player_id == record.player_id:
				return false
		if not ForeignActiveRosterRules.can_add_record(foreign_counts, record):
			return false
		selected.append(record)
		ForeignActiveRosterRules.add_record(foreign_counts, record)
		return true

	for record_row in starters:
		if selected.size() >= TARGET_STARTERS:
			break
		add_player.call(record_row as PSPlayerSeasonRecord)

	var pitcher_count: int = selected.size()
	for record_row in relievers:
		if pitcher_count >= TARGET_PITCHERS:
			break
		if add_player.call(record_row as PSPlayerSeasonRecord):
			pitcher_count += 1

	_ensure_minimum_catchers(selected, fielders, add_player, MIN_ACTIVE_CATCHERS)
	_ensure_defensive_position_coverage(selected, fielders, add_player)

	for record_row in fielders:
		if selected.size() >= TARGET_TOTAL:
			break
		add_player.call(record_row as PSPlayerSeasonRecord)

	if selected.size() < TARGET_TOTAL:
		var remaining_pool: Array = []
		var selected_ids: Dictionary = {}
		for record_row in selected:
			selected_ids[(record_row as PSPlayerSeasonRecord).player_id] = true
		for record_row in relievers:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not selected_ids.has(record.player_id):
				remaining_pool.append(record)
		for record_row in starters:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not selected_ids.has(record.player_id):
				remaining_pool.append(record)
		remaining_pool.sort_custom(by_overall)
		for record_row in remaining_pool:
			if selected.size() >= TARGET_TOTAL:
				break
			add_player.call(record_row as PSPlayerSeasonRecord)

	var player_ids: Array = []
	for record_row in selected:
		player_ids.append((record_row as PSPlayerSeasonRecord).player_id)

	var required_catchers: int = _required_active_catcher_count(all_records)
	if _healthy_catcher_count_in_records(selected) < required_catchers:
		return {
			"ok": false,
			"message": "%sは健康な捕手を%d人そろえられません" % [GameSimulator._team_name(team_id), required_catchers],
			"player_ids": player_ids,
			"summary": summarize_active_roster_ids(player_ids, all_records),
		}

	if not _records_can_field_game(season, team_id, selected, dh_enabled):
		return {
			"ok": false,
			"message": "%sは健康な支配下選手だけでは試合可能な1軍を組めません" % GameSimulator._team_name(team_id),
			"player_ids": player_ids,
			"summary": summarize_active_roster_ids(player_ids, all_records),
		}

	return {
		"ok": true,
		"player_ids": player_ids,
		"summary": summarize_active_roster_ids(player_ids, all_records),
	}


static func summarize_active_roster_ids(player_ids: Array, records: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		by_id[record.player_id] = record

	var total: int = 0
	var pitchers: int = 0
	var starters: int = 0
	var fielders: int = 0
	var catchers: int = 0
	var foreign_counts: Dictionary = ForeignActiveRosterRules.empty_counts()
	for id_value in player_ids:
		var pid: int = int(id_value)
		if not by_id.has(pid):
			continue
		var record: PSPlayerSeasonRecord = by_id[pid] as PSPlayerSeasonRecord
		total += 1
		ForeignActiveRosterRules.add_record(foreign_counts, record)
		if record.is_pitcher():
			pitchers += 1
			if _is_starter_role(record):
				starters += 1
		else:
			fielders += 1
			if _is_active_roster_catcher(record):
				catchers += 1

	return {
		"total": total,
		"pitchers": pitchers,
		"starters": starters,
		"fielders": fielders,
		"catchers": catchers,
		"foreigners": int(foreign_counts["foreigners"]),
		"foreign_pitchers": int(foreign_counts["foreign_pitchers"]),
		"foreign_fielders": int(foreign_counts["foreign_fielders"]),
	}


static func _ensure_minimum_catchers(selected: Array, fielders: Array, add_player: Callable, minimum: int) -> void:
	var catcher_count: int = _catcher_count_in_records(selected)
	if catcher_count >= minimum:
		return
	for record_row in fielders:
		if catcher_count >= minimum:
			break
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or _record_array_has_player(selected, record.player_id):
			continue
		if not _is_active_roster_catcher(record):
			continue
		if bool(add_player.call(record)):
			catcher_count += 1


static func _ensure_defensive_position_coverage(selected: Array, fielders: Array, add_player: Callable) -> void:
	for position_row in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var position: int = int(position_row)
		var cover_count: int = _records_cover_position_count(selected, position)
		for record_row in fielders:
			if cover_count >= 2:
				break
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record == null or _record_array_has_player(selected, record.player_id):
				continue
			if position_aptitude(record, position) <= 0:
				continue
			if bool(add_player.call(record)):
				cover_count += 1


static func _records_cover_position_count(records: Array, position: int) -> int:
	var count: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and position_aptitude(record, position) > 0:
			count += 1
	return count


static func _catcher_count_in_records(records: Array) -> int:
	var count: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if _is_active_roster_catcher(record):
			count += 1
	return count


static func _healthy_catcher_count_in_records(records: Array) -> int:
	var count: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.injury_days <= 0 and _is_active_roster_catcher(record):
			count += 1
	return count


static func _required_active_catcher_count(records: Array) -> int:
	return int(min(MIN_ACTIVE_CATCHERS, _healthy_catcher_count_in_records(records)))


static func _record_array_has_player(records: Array, player_id: int) -> bool:
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return true
	return false


static func _is_active_roster_catcher(record: PSPlayerSeasonRecord) -> bool:
	return record != null and not record.is_pitcher() and position_aptitude(record, 2) > 0


static func filter_by_active_roster(season: PSSeason, team_id: int, records: Array) -> Array:
	var roster: Dictionary = season.get_active_roster(team_id)
	if roster.is_empty():
		return []
	var ids_array: Array = roster.get("player_ids", []) as Array
	if ids_array.is_empty():
		return []
	var allowed: Dictionary = {}
	for id_value in ids_array:
		allowed[int(id_value)] = true
	var filtered: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.development_player:
			continue
		if allowed.has(record.player_id):
			filtered.append(record)
	return filtered


static func _records_for_ids(records: Array, ids_array: Array) -> Array:
	var allowed: Dictionary = {}
	for id_value in ids_array:
		allowed[int(id_value)] = true
	var filtered: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and allowed.has(record.player_id):
			filtered.append(record)
	return filtered


static func _record_ids(records: Array) -> Array:
	var ids: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			ids.append(record.player_id)
	return ids


static func _minimum_fielders_for_game(dh_enabled: bool) -> int:
	return GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size() + (1 if dh_enabled else 0)


static func _records_can_field_game(season: PSSeason, team_id: int, records: Array, dh_enabled: bool = true) -> bool:
	var pitchers: Array = []
	var fielders: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher():
			pitchers.append(record)
		else:
			fielders.append(record)
	var starter_pitchers: Array = eligible_or_fallback(starter_pitcher_candidates(pitchers), 1)
	if starter_pitchers.is_empty():
		return false
	var required_fielders: int = _minimum_fielders_for_game(dh_enabled)
	var available_fielders: Array = eligible_or_fallback(fielders, required_fielders)
	if available_fielders.size() < required_fielders:
		return false
	var profile: PSDefenseAlignmentProfile = DefenseAlignmentProfile.load_for_team(team_id)
	var usage_settings: Dictionary = season.get_fielder_usage(team_id) if season != null else {}
	var slots: Array = DefenseAlignmentService.assign_defensive_starters(available_fielders, profile, usage_settings, 1)
	if slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
		return true
	slots = DefenseAlignmentService.assign_defensive_starters(available_fielders, profile, {}, 1)
	return slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size()


static func prepare_team_setup(season: PSSeason, team_id: int, dh_enabled: bool = true) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	var active_records: Array = filter_by_active_roster(season, team_id, all_records)
	var active_needs_repair: bool = active_records.is_empty()
	if not active_needs_repair:
		active_needs_repair = not ForeignActiveRosterRules.is_within_limits(
			ForeignActiveRosterRules.counts_from_records(active_records)
		)
	if not active_needs_repair:
		var required_catchers: int = _required_active_catcher_count(all_records)
		active_needs_repair = _healthy_catcher_count_in_records(active_records) < required_catchers
	if not active_needs_repair:
		active_needs_repair = not _records_can_field_game(season, team_id, active_records, dh_enabled)
	if active_needs_repair:
		var preview: Dictionary = preview_active_roster(season, team_id, dh_enabled)
		if bool(preview.get("ok", false)):
			var preview_records: Array = _records_for_ids(all_records, preview.get("player_ids", []) as Array)
			if not preview_records.is_empty() and _records_can_field_game(season, team_id, preview_records, dh_enabled):
				active_records = preview_records
				season.set_active_roster(team_id, {"player_ids": _record_ids(active_records)})
			else:
				active_records = []
	var records: Array = active_records if not active_records.is_empty() else all_records

	var pitchers: Array = []
	var fielders: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitchers.append(record)
		else:
			fielders.append(record)

	var starter_pitchers: Array = starter_pitcher_candidates(pitchers)
	starter_pitchers = eligible_or_fallback(starter_pitchers, 1)
	var required_fielders: int = _minimum_fielders_for_game(dh_enabled)
	var available_fielders: Array = eligible_or_fallback(fielders, required_fielders)

	if (starter_pitchers.is_empty() or available_fielders.size() < required_fielders) and not active_records.is_empty():
		pitchers = []
		fielders = []
		for record_row in all_records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record.is_pitcher():
				pitchers.append(record)
			else:
				fielders.append(record)
		starter_pitchers = starter_pitcher_candidates(pitchers)
		starter_pitchers = eligible_or_fallback(starter_pitchers, 1)
		available_fielders = eligible_or_fallback(fielders, required_fielders)

	if starter_pitchers.is_empty():
		return {"ok": false, "message": "%sに先発適正が中継適正を上回る投手がいません" % GameSimulator._team_name(team_id)}
	if available_fielders.size() < required_fielders:
		return {"ok": false, "message": "%sの野手が%d人未満です" % [GameSimulator._team_name(team_id), required_fielders]}

	starter_pitchers.sort_custom(func(a, b) -> bool:
		var pitcher_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var pitcher_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return PSPitcherRoleModel.starter_order_score(pitcher_a) > PSPitcherRoleModel.starter_order_score(pitcher_b)
	)

	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
	var reliever_pool: Array = reliever_pool_candidates(pitchers)

	return {
		"ok": true,
		"starter_pitchers": starter_pitchers,
		"available_fielders": available_fielders,
		"reliever_pool": reliever_pool,
		"team_record": team_record,
	}


static func build_setup_from_auto(
	season: PSSeason,
	team_id: int,
	dh_enabled: bool,
	available_fielders: Array,
	rotation_pitcher: PSPlayerSeasonRecord,
	team_games_played_before: int = -1
) -> Dictionary:
	if team_games_played_before < 0:
		var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
		team_games_played_before = 0 if team_record == null else int(team_record.stats.games)
	var usage_settings: Dictionary = season.get_fielder_usage(team_id)
	if _usage_needs_ai_defaults(usage_settings, available_fielders):
		var base_slots: Array = select_defensive_starters_with_usage(team_id, available_fielders, usage_settings, 1)
		if base_slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
			usage_settings = build_ai_fielder_usage(available_fielders, base_slots, usage_settings)
			season.set_fielder_usage(team_id, usage_settings)
	var fielding_slots: Array = select_defensive_starters(season, team_id, available_fielders, team_games_played_before + 1)
	if fielding_slots.size() < GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
		return {"ok": false, "message": "%sの守備位置を埋められません" % GameSimulator._team_name(team_id)}
	var rested_fielder_ids: Dictionary = rested_starter_ids_for_game(usage_settings, team_games_played_before + 1)

	var batting_order: Array = records_from_fielding_slots(fielding_slots)
	var position_by_player_id: Dictionary = position_map_from_fielding_slots(fielding_slots)
	if dh_enabled:
		var designated_hitter: PSPlayerSeasonRecord = select_designated_hitter(available_fielders, fielding_slots, rested_fielder_ids)
		if designated_hitter == null and not rested_fielder_ids.is_empty():
			designated_hitter = select_designated_hitter(available_fielders, fielding_slots)
		if designated_hitter == null:
			return {"ok": false, "message": "%sにDH候補がいません" % GameSimulator._team_name(team_id)}
		batting_order.append(designated_hitter)
		position_by_player_id[designated_hitter.player_id] = BattingOrderService.DH_POSITION

	# auto_lineup ON なら日替わり打順サービス、OFF なら基本打順のみ。
	var team: PSTeam = GameDb.get_team(team_id)
	if team != null and team.auto_lineup:
		if not dh_enabled:
			batting_order.append(rotation_pitcher)
		var profile: PSBattingOrderProfile = BattingOrderProfile.load_for_team(team_id, dh_enabled)
		if profile.base_order_player_ids.is_empty():
			var saved_base_order: Array = season.get_auto_batting_order(team_id, dh_enabled)
			if not saved_base_order.is_empty():
				for player_id_value in saved_base_order:
					profile.base_order_player_ids.append(int(player_id_value))
		var ctx: Dictionary = {
			"game_day": season.current_day,
			"team_id": team_id,
			"dh_enabled": dh_enabled,
			"opp_pitcher_hand": "",
			"position_by_player_id": position_by_player_id,
			"team_games_played": team_games_played_before,
		}
		batting_order = BattingOrderService.build_daily_batting_order(batting_order, ctx, profile)
		# 基本打順は初回と定期リフレッシュで profile 側が差し替わる。セーブへはそれをそのまま写す。
		season.set_auto_batting_order(team_id, dh_enabled, profile.base_order_player_ids)
	else:
		sort_batting_order(batting_order, position_by_player_id)
		if not dh_enabled:
			batting_order.append(rotation_pitcher)
	var bench: Array = bench_fielders(available_fielders, batting_order)

	return {
		"ok": true,
		"team_id": team_id,
		"dh_enabled": dh_enabled,
		"pitcher": rotation_pitcher,
		"batters": batting_order,
		"bench": bench,
		"fielders": fielding_slots,
		"batting_index": 0,
		"game_outs": 0,
		"game_runs_allowed": 0,
		"pitcher_usage": {},
		"used_pitcher_ids": {},
		"pending_defensive_subs": [],
		"reserved_fielder_ids": {},
	}


static func build_setup_from_saved(_season: PSSeason, team_id: int, dh_enabled: bool, available_fielders: Array, rotation_pitcher: PSPlayerSeasonRecord, saved: Dictionary) -> Dictionary:
	var saved_orders: Array = (saved.get("batting_order", []) as Array)
	if saved_orders.is_empty():
		return {}

	var fielders_by_id: Dictionary = {}
	for fielder_row in available_fielders:
		var fielder_record: PSPlayerSeasonRecord = fielder_row as PSPlayerSeasonRecord
		fielders_by_id[fielder_record.player_id] = fielder_record

	var batting_records: Array = []
	var slot_positions: Array = []
	for _i in range(9):
		batting_records.append(null)
		slot_positions.append(0)

	var used_ids: Dictionary = {}
	var fielding_assignments: Array = []
	var has_pitcher_slot: bool = false
	var has_dh_slot: bool = false

	for entry_row in saved_orders:
		var entry: Dictionary = entry_row as Dictionary
		var slot_index: int = int(entry.get("slot", 0)) - 1
		if slot_index < 0 or slot_index >= 9:
			continue
		if slot_positions[slot_index] != 0:
			continue
		var position: int = int(entry.get("position", 0))
		var player_id: int = int(entry.get("player_id", 0))
		slot_positions[slot_index] = position

		if position == 1:
			if dh_enabled or has_pitcher_slot:
				continue
			batting_records[slot_index] = rotation_pitcher
			has_pitcher_slot = true
			continue

		if position == 10:
			if not dh_enabled or has_dh_slot:
				continue
			has_dh_slot = true
			if player_id > 0 and fielders_by_id.has(player_id) and not used_ids.has(player_id):
				var dh_record: PSPlayerSeasonRecord = fielders_by_id[player_id] as PSPlayerSeasonRecord
				if dh_record.injury_days <= 0:
					batting_records[slot_index] = dh_record
					used_ids[player_id] = true
			continue

		if position < 2 or position > 9:
			continue

		if player_id <= 0 or not fielders_by_id.has(player_id) or used_ids.has(player_id):
			continue
		var record: PSPlayerSeasonRecord = fielders_by_id[player_id] as PSPlayerSeasonRecord
		if record.injury_days > 0 or position_aptitude(record, position) <= 0:
			continue

		var position_already_used: bool = false
		for assignment_row in fielding_assignments:
			var assignment: Dictionary = assignment_row as Dictionary
			if int(assignment.get("position", 0)) == position:
				position_already_used = true
				break
		if position_already_used:
			continue

		batting_records[slot_index] = record
		used_ids[player_id] = true
		fielding_assignments.append({"record": record, "position": position})

	var covered_positions: Dictionary = {}
	for assignment_row in fielding_assignments:
		var assignment: Dictionary = assignment_row as Dictionary
		covered_positions[int(assignment.get("position", 0))] = true
	var needed_positions: Array = []
	for position_row in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var position: int = int(position_row)
		if not covered_positions.has(position):
			needed_positions.append(position)

	if not dh_enabled and not has_pitcher_slot:
		var pitcher_slot: int = find_unfilled_slot(batting_records, slot_positions, [0, 1])
		if pitcher_slot < 0:
			return {}
		batting_records[pitcher_slot] = rotation_pitcher
		slot_positions[pitcher_slot] = 1
		has_pitcher_slot = true

	if dh_enabled and not has_dh_slot:
		var dh_slot: int = find_unfilled_slot(batting_records, slot_positions, [0])
		if dh_slot < 0:
			return {}
		slot_positions[dh_slot] = 10
		has_dh_slot = true

	var remaining: Array = []
	for fielder_row in available_fielders:
		var fielder_record: PSPlayerSeasonRecord = fielder_row as PSPlayerSeasonRecord
		if not used_ids.has(fielder_record.player_id):
			remaining.append(fielder_record)

	for position_row in needed_positions:
		var position: int = int(position_row)
		var target_slot: int = find_unfilled_slot(batting_records, slot_positions, [position])
		if target_slot < 0:
			target_slot = find_unfilled_slot(batting_records, slot_positions, [0])
		if target_slot < 0:
			return {}
		var fielder: PSPlayerSeasonRecord = best_fielder_for_position(remaining, position, true)
		if fielder == null:
			fielder = best_fielder_for_position(remaining, position, false)
		if fielder == null:
			return {}
		batting_records[target_slot] = fielder
		slot_positions[target_slot] = position
		used_ids[fielder.player_id] = true
		remaining.erase(fielder)
		fielding_assignments.append({"record": fielder, "position": position})

	if dh_enabled:
		for i in range(9):
			if slot_positions[i] == 10 and batting_records[i] == null:
				var dh: PSPlayerSeasonRecord = select_designated_hitter(remaining, fielding_assignments)
				if dh == null:
					if remaining.is_empty():
						return {}
					remaining.sort_custom(func(a, b) -> bool:
						return PSScoringHelpers.batter_order_score(a as PSPlayerSeasonRecord) > PSScoringHelpers.batter_order_score(b as PSPlayerSeasonRecord)
					)
					dh = remaining[0] as PSPlayerSeasonRecord
				batting_records[i] = dh
				used_ids[dh.player_id] = true
				remaining.erase(dh)
				break

	for i in range(9):
		if batting_records[i] != null:
			continue
		if remaining.is_empty():
			return {}
		remaining.sort_custom(func(a, b) -> bool:
			return PSScoringHelpers.batter_order_score(a as PSPlayerSeasonRecord) > PSScoringHelpers.batter_order_score(b as PSPlayerSeasonRecord)
		)
		batting_records[i] = remaining[0]
		used_ids[remaining[0].player_id] = true
		remaining.pop_front()

	return {
		"ok": true,
		"team_id": team_id,
		"dh_enabled": dh_enabled,
		"pitcher": rotation_pitcher,
		"batters": batting_records,
		"bench": remaining,
		"fielders": fielding_assignments,
		"batting_index": 0,
		"game_outs": 0,
		"game_runs_allowed": 0,
		"pitcher_usage": {},
		"used_pitcher_ids": {},
		"pending_defensive_subs": [],
		"reserved_fielder_ids": {},
	}


static func find_unfilled_slot(batting_records: Array, slot_positions: Array, allowed_positions: Array) -> int:
	for i in range(batting_records.size()):
		if batting_records[i] != null:
			continue
		if allowed_positions.has(int(slot_positions[i])):
			return i
	return -1


static func bench_fielders(available_fielders: Array, batting_order: Array) -> Array:
	var used_ids: Dictionary = {}
	for batter_row in batting_order:
		var batter: PSPlayerSeasonRecord = batter_row as PSPlayerSeasonRecord
		if batter != null:
			used_ids[batter.player_id] = true

	var bench: Array = []
	for fielder_row in available_fielders:
		var fielder: PSPlayerSeasonRecord = fielder_row as PSPlayerSeasonRecord
		if fielder == null or used_ids.has(fielder.player_id):
			continue
		bench.append(fielder)
	return bench


static func setup_to_lineup_dict(setup: Dictionary, dh_enabled: bool, rotation_pitcher: PSPlayerSeasonRecord) -> Dictionary:
	var batters: Array = setup.get("batters", []) as Array
	var fielders: Array = setup.get("fielders", []) as Array
	var fielder_position_by_id: Dictionary = {}
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			fielder_position_by_id[record.player_id] = int(assignment.get("position", 0))

	var batting_order: Array = []
	for i in range(batters.size()):
		var batter: PSPlayerSeasonRecord = batters[i] as PSPlayerSeasonRecord
		if batter == null:
			continue
		var position: int = 0
		if batter.player_id == rotation_pitcher.player_id and not dh_enabled:
			position = 1
		elif fielder_position_by_id.has(batter.player_id):
			position = int(fielder_position_by_id[batter.player_id])
		else:
			position = 10
		batting_order.append({
			"slot": i + 1,
			"position": position,
			"player_id": batter.player_id,
		})

	return {
		"batting_order": batting_order,
	}


# Phase 4: 旧 DP (best_fielding_assignment_dp) と周辺 fallback (repair_starter_selection_for_coverage,
# greedy_defensive_starters, starter_candidate_pool, initial_starter_selection 等 14 関数) を
# PSDefenseAlignmentService に置換。lazy default で初回は greedy template を算出してキャッシュし、
# 以後の試合は不在選手のみ backup_priority 経由で補充する。
static func select_defensive_starters(season: PSSeason, team_id: int, candidates: Array, next_game_number: int = 1) -> Array:
	var profile: PSDefenseAlignmentProfile = DefenseAlignmentProfile.load_for_team(team_id)
	var usage_settings: Dictionary = season.get_fielder_usage(team_id) if season != null else {}
	return DefenseAlignmentService.assign_defensive_starters(candidates, profile, usage_settings, next_game_number)


static func select_defensive_starters_with_usage(team_id: int, candidates: Array, usage_settings: Dictionary, next_game_number: int = 1) -> Array:
	var profile: PSDefenseAlignmentProfile = DefenseAlignmentProfile.load_for_team(team_id)
	return DefenseAlignmentService.assign_defensive_starters(candidates, profile, usage_settings, next_game_number)


static func _usage_needs_ai_defaults(usage_settings: Dictionary, available_fielders: Array = []) -> bool:
	var position_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	if position_slots.is_empty():
		return true
	var record_by_id: Dictionary = {}
	for record_row in available_fielders:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record
	var starter_ids: Dictionary = {}
	for position in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var slot: Dictionary = _usage_slot_for_position(position_slots, int(position))
		var starter_id: int = int(slot.get("starter_id", 0))
		var sub_id: int = int(slot.get("sub_id", 0))
		if sub_id <= 0 or int(slot.get("sub_start_interval", 0)) == 0 or sub_id == starter_id:
			return true
		starter_ids[starter_id] = true
		if not record_by_id.is_empty():
			if starter_id <= 0 or not record_by_id.has(starter_id) or not record_by_id.has(sub_id):
				return true
			var starter: PSPlayerSeasonRecord = record_by_id[starter_id] as PSPlayerSeasonRecord
			var sub: PSPlayerSeasonRecord = record_by_id[sub_id] as PSPlayerSeasonRecord
			var position_id: int = int(position)
			if starter == null or position_aptitude(starter, position_id) <= 0:
				return true
			if sub == null or sub.injury_days > 0 or position_aptitude(sub, position_id) <= 0:
				return true
	for position in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var slot: Dictionary = _usage_slot_for_position(position_slots, int(position))
		var sub_id: int = int(slot.get("sub_id", 0))
		if starter_ids.has(sub_id):
			return true
	return false


static func build_ai_fielder_usage(available_fielders: Array, base_fielding_slots: Array, existing_usage: Dictionary = {}) -> Dictionary:
	var existing_slots: Dictionary = existing_usage.get("position_slots", {}) as Dictionary
	var position_slots: Dictionary = existing_slots.duplicate(true)
	var starter_ids: Dictionary = {}
	var assigned_sub_ids: Dictionary = {}
	for slot_row in base_fielding_slots:
		var assignment: Dictionary = slot_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			starter_ids[record.player_id] = true
	for slot_row in base_fielding_slots:
		var assignment: Dictionary = slot_row as Dictionary
		var position: int = int(assignment.get("position", 0))
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record == null or position < 2 or position > 9:
			continue
		var existing_slot: Dictionary = _usage_slot_for_position(position_slots, position)
		var starter_id: int = int(existing_slot.get("starter_id", 0))
		var starter: PSPlayerSeasonRecord = _record_by_id(available_fielders, starter_id)
		if starter_id <= 0 or starter == null or position_aptitude(starter, position) <= 0:
			starter_id = record.player_id
		starter_ids[starter_id] = true
		var sub_id: int = int(existing_slot.get("sub_id", 0))
		if starter_ids.has(sub_id) or assigned_sub_ids.has(sub_id):
			sub_id = 0
		var interval: int = int(existing_slot.get("sub_start_interval", 0))
		var sub: PSPlayerSeasonRecord = null
		if sub_id > 0:
			sub = _record_by_id(available_fielders, sub_id)
			if sub == null or sub.injury_days > 0 or position_aptitude(sub, position) <= 0:
				sub = null
				sub_id = 0
		if sub == null:
			sub = _best_sub_for_position(available_fielders, starter_ids, assigned_sub_ids, position)
			sub_id = 0 if sub == null else sub.player_id
		if sub_id > 0:
			assigned_sub_ids[sub_id] = true
		if interval == 0 and sub != null:
			interval = _sub_interval_for(record, sub, position)
		# ユーザが「控え」で設定した補充優先リストは AI 既定生成でも保持する。
		var backup_ids: Array = (existing_slot.get("backup_ids", []) as Array).duplicate()
		position_slots[str(position)] = {
			"starter_id": starter_id,
			"sub_id": sub_id,
			"sub_start_interval": interval,
			"backup_ids": backup_ids,
		}

	var result: Dictionary = existing_usage.duplicate(true)
	result["position_slots"] = position_slots
	result.erase("bench_roles")
	result["ai_generated"] = true
	return result


static func _usage_slot_for_position(position_slots: Dictionary, position: int) -> Dictionary:
	var key: String = str(position)
	if position_slots.has(key):
		return position_slots.get(key, {}) as Dictionary
	if position_slots.has(position):
		return position_slots.get(position, {}) as Dictionary
	return {}


static func _best_sub_for_position(
	available_fielders: Array,
	starter_ids: Dictionary,
	assigned_sub_ids: Dictionary,
	position: int
) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -2147483647
	for row in available_fielders:
		var candidate: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if candidate == null or candidate.injury_days > 0 \
				or starter_ids.has(candidate.player_id) or assigned_sub_ids.has(candidate.player_id):
			continue
		if position_aptitude(candidate, position) <= 0:
			continue
		var score: int = PlayerValueEvaluator.starter_assignment_score(candidate, position, true)
		if score <= PlayerValueEvaluator.ZERO_APTITUDE_SCORE:
			continue
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


# 正捕手でも守備負荷ゆえ定期休養させる上限間隔。7 試合に 1 度の控え先発で
# 143 試合中の先発は約 122 試合 (MLB のフル稼働正捕手 ~120-130 先発と同水準) になる。
const CATCHER_SUB_INTERVAL_MAX: int = 7


static func _sub_interval_for(starter: PSPlayerSeasonRecord, sub: PSPlayerSeasonRecord, position: int) -> int:
	if starter == null or sub == null:
		return 0
	var gap: int = max(0, PlayerValueEvaluator.overall_score(starter) - PlayerValueEvaluator.overall_score(sub))
	# 能力差(gap)に応じた控えの定期スタメン間隔。差が小さいほど頻繁に起用する。
	var interval: int = SUB_INTERVAL_FATIGUE_EMERGENCY  # 5 点差以上 → 疲労/緊急時のみ
	if gap <= 1:
		interval = 2  # ほぼ互角 → 2 試合に 1 度
	elif gap <= 2:
		interval = 3
	elif gap <= 3:
		interval = 4
	elif gap <= 4:
		interval = 6
	# 捕手は能力差が大きくても「休養なし」にはしない (現実の正捕手は年 120 先発前後が上限)。
	if position == 2 and (interval <= 0 or interval > CATCHER_SUB_INTERVAL_MAX):
		interval = CATCHER_SUB_INTERVAL_MAX
	return interval


static func _record_by_id(records: Array, player_id: int) -> PSPlayerSeasonRecord:
	for row in records:
		var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return record
	return null


static func rested_starter_ids_for_game(usage_settings: Dictionary, next_game_number: int) -> Dictionary:
	var rested: Dictionary = {}
	var position_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	for slot_value in position_slots.values():
		var slot: Dictionary = slot_value as Dictionary
		var interval: int = int(slot.get("sub_start_interval", 0))
		if interval <= 0 or next_game_number <= 0 or next_game_number % interval != 0:
			continue
		var starter_id: int = int(slot.get("starter_id", 0))
		var sub_id: int = int(slot.get("sub_id", 0))
		if starter_id > 0 and sub_id > 0 and starter_id != sub_id:
			rested[starter_id] = true
	return rested


static func best_fielder_for_position(candidates: Array, position: int, require_aptitude: bool) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -999999
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		var aptitude: int = position_aptitude(candidate, position)
		if require_aptitude and aptitude <= 0:
			continue
		var score: int = defensive_position_score(candidate, position)
		if score <= PlayerValueEvaluator.ZERO_APTITUDE_SCORE:
			continue
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


static func defensive_position_score(record: PSPlayerSeasonRecord, position: int) -> int:
	# スタメン候補スコア (打撃/守備の position 別ブレンド)。saved-lineup fallback で使う。
	# 純守備版が必要な場合は PlayerValueEvaluator.defensive_assignment_score を直接呼ぶ。
	return PlayerValueEvaluator.starter_assignment_score(record, position, false)


static func position_aptitude(record: PSPlayerSeasonRecord, position: int) -> int:
	var key: String = str(GameSimulator.POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == position else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


# 守備スロットから player_id → 守備位置の対応表を作る。打順評価の捕手判定に使う。
static func position_map_from_fielding_slots(fielding_slots: Array) -> Dictionary:
	var position_by_player_id: Dictionary = {}
	for slot_row in fielding_slots:
		var slot: Dictionary = slot_row as Dictionary
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			position_by_player_id[record.player_id] = int(slot.get("position", record.position))
	return position_by_player_id


static func records_from_fielding_slots(fielding_slots: Array) -> Array:
	var records: Array = []
	for slot_row in fielding_slots:
		var slot: Dictionary = slot_row as Dictionary
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			records.append(record)
	return records


static func select_designated_hitter(candidates: Array, fielding_slots: Array, excluded_ids: Dictionary = {}) -> PSPlayerSeasonRecord:
	var used_ids: Dictionary = {}
	for slot_row in fielding_slots:
		var slot: Dictionary = slot_row as Dictionary
		var fielder: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			used_ids[fielder.player_id] = true

	var best: PSPlayerSeasonRecord = null
	var best_score: int = -999999
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		if used_ids.has(candidate.player_id) or excluded_ids.has(candidate.player_id):
			continue
		# DH は守備が要らないぶん打撃だけで決まる。好不調 (成績の上振れ/下振れ) も込みで見る。
		var score: int = PlayerValueEvaluator.batting_score_with_form(candidate)
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


# 打順を役割マッチング (1-2番=出塁と機動力、3-5番=中軸、6番以降=打力順、捕手は上位を避ける) で
# 並べ替える。position_by_player_id はその日の守備位置で、捕手判定に使う (省略時は登録ポジション)。
static func sort_batting_order(batting_order: Array, position_by_player_id: Dictionary = {}) -> void:
	batting_order.assign(BattingOrderService.build_base_order(batting_order, null, position_by_player_id))


static func starter_pitcher_candidates(pitchers: Array) -> Array:
	var candidates: Array = []
	var rest: Array = []
	for pitcher_row in pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if pitcher == null:
			continue
		if _is_starter_role(pitcher):
			candidates.append(pitcher)
		else:
			rest.append(pitcher)
	# stored-starter が1人でもいればそのまま使う = リリーフ (クローザー含む) は先発ローテに混入しない。
	# stored-starter がゼロのチーム (ドリフト/小ロスター) のときだけ緊急的に先発適性順で補う。
	if candidates.is_empty() and not rest.is_empty():
		rest.sort_custom(func(a, b) -> bool:
			return PSPitcherRoleModel.starter_order_score(a) > PSPitcherRoleModel.starter_order_score(b)
		)
		for pitcher_row in rest:
			if candidates.size() >= STARTER_POOL_MIN:
				break
			candidates.append(pitcher_row)
	return candidates


static func reliever_pool_candidates(pitchers: Array) -> Array:
	var candidates: Array = []
	for pitcher_row in pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if not _is_starter_role(pitcher):
			candidates.append(pitcher)
	return candidates


static func _is_starter_role(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return false
	return record.is_starter_pitcher()


static func _active_roster_selection_score(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return -2147483647
	var score: int = PlayerValueEvaluator.overall_score(record)
	if record.injury_days > 0:
		score -= 100000
	return score


static func eligible_or_fallback(records: Array, _min_size: int) -> Array:
	var eligible: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.injury_days <= 0 and not record.development_player:
			eligible.append(record)
	return eligible
