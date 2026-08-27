extends RefCounted
class_name PSTeamSetupBuilder

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const BattingOrderProfile = preload("res://domain/batting_order_profile.gd")
const BattingOrderService = preload("res://services/simulation/lineup/batting_order_service.gd")
const DefenseAlignmentProfile = preload("res://domain/defense_alignment_profile.gd")
const DefenseAlignmentService = preload("res://services/simulation/lineup/defense_alignment_service.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")

# 自動編成チームの守備起用設定を組み直す間隔 (チーム試合数)。143 試合で約10回。
const AI_USAGE_REBUILD_INTERVAL: int = 14
const MIN_ACTIVE_CATCHERS: int = 2
# 先発候補は保存 role を正準にする。先発 role が1人でもいればリリーフをローテへ混ぜず、
# 先発ゼロの小規模/壊れたロスターだけ緊急補充を許す。その補充上限がこの定数。
const STARTER_POOL_MIN: int = 5


static func build_team_setup(
	season: PSSeason,
	team_id: int,
	dh_enabled: bool,
	postseason: bool = false,
	level: int = LEVEL_FIRST,
	opponent_hand: String = ""
) -> Dictionary:
	# 1試合1チームぶんの打撃スコア memo。ロスター検証 → AI既定配置の生成 → 本番配置で
	# PSDefenseAlignmentService を最大3回通すため、共有しないと同じ選手の
	# batting_score_with_form (= 能力 + 今季/過去成績ブレンド) を毎回作り直すことになる。
	# 試合が始まる前なので成績も疲労もまだ動かず、共有しても値は変わらない。
	var batting_memo: Dictionary = {}
	var prepared: Dictionary = prepare_team_setup(season, team_id, dh_enabled, batting_memo, level)
	if not bool(prepared.get("ok", false)):
		return prepared

	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	var available_fielders: Array = prepared["available_fielders"] as Array
	var reliever_pool: Array = prepared.get("reliever_pool", []) as Array
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	# 二軍は序列 (pitcher_ids) だけ別キーで持ち、**登板間隔の台帳 (last_start_day_by_pitcher) は
	# 一軍と共有する**。これで「二軍で投げた翌日に昇格して中0日で先発」を構造的に防げる。
	var saved_rotation: Dictionary = PSRotationPlanner.rotation_state_for_level(season, team_id, level)
	# 消化試合数はレベルごとに数える。守備の出場シェア (`share_index_for_game`) と
	# 日替わり打順がこの値を使うので、二軍で一軍の試合数を渡すと休養サイクルがずれる。
	# **二軍の出場輪番 (farm_usage_priority) の分母**でもあるのでローテ決定より前に出す。
	var team_games_played_before: int = 0
	if team_record != null:
		team_games_played_before = int(
			team_record.farm_stats.games if level == LEVEL_FARM else team_record.stats.games
		)
	# 二軍は投手の序列付けも**二軍の出場方針**で行う (打撃側の `_prime_farm_batting_memo` と対)。
	# これが無いと能力上位のローテ6人+ブルペン6人で固定され、**育成投手が年間ほぼ登板しない**。
	var farm_priority: bool = level == LEVEL_FARM
	var farm_games: int = team_games_played_before if farm_priority else 0
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(
		season, team_id, starter_pitchers, reliever_pool, postseason, saved_rotation, farm_priority, farm_games
	)
	var rotation_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	if rotation_pitcher == null:
		return {"ok": false, "message": "%sの先発投手を決定できません" % GameSimulator._team_name(team_id)}
	var relievers: Array = PSRotationPlanner.select_relievers_for_innings(
		reliever_pool, starter_pitchers, rotation_pitcher.player_id, saved_rotation, farm_priority, farm_games
	)
	var relief_role_by_pitcher: Dictionary = PSRotationPlanner.relief_role_by_pitcher(saved_rotation, relievers)

	# auto_lineup ON は保存済み打順を使わず、その日のロスターから打順と守備配置を毎試合作る。
	# OFF のチームは保存設定を優先し、欠員などで組めない場合だけ自動生成へフォールバックする。
	var setup: Dictionary = {}
	var team: PSTeam = GameDb.get_team(team_id)
	# 二軍の打順・守備配置は保存設定を使わず必ず自動生成する (二軍用の打順エディタは持たない)。
	var use_saved: bool = level == LEVEL_FIRST and (team == null or not team.auto_lineup)
	if use_saved:
		# 相手先発の左右で打順を切り替える。対左を保存していないチームは基本打順へ落ちる。
		var saved: Dictionary = season.get_lineup(team_id, dh_enabled, opponent_hand)
		if not saved.is_empty():
			var saved_setup: Dictionary = build_setup_from_saved(
				season, team_id, dh_enabled, available_fielders, rotation_pitcher, saved, batting_memo
			)
			if bool(saved_setup.get("ok", false)):
				setup = saved_setup

	if setup.is_empty():
		setup = build_setup_from_auto(
			season, team_id, dh_enabled, available_fielders, rotation_pitcher,
			team_games_played_before, batting_memo, level, opponent_hand
		)

	if bool(setup.get("ok", false)):
		setup["level"] = level
		setup["starter_pitcher"] = rotation_pitcher
		setup["relievers"] = relievers
		# ブルペンから漏れた残りの投手。**継投先が1人も見つからない非常時にだけ**使う
		# (PSBullpenManager.pick_reliever_for_context の最終段)。役割 (抑え/セット) は
		# あくまで上の `relievers` で決まるので、ここに入れても日替わり抑えにはならない。
		setup["relief_reserve"] = _relief_reserve(reliever_pool, relievers, rotation_pitcher)
		setup["relief_role_by_pitcher"] = relief_role_by_pitcher
		setup["starter_outs"] = -1
		setup["starter_runs"] = -1
		setup["starter_relieved"] = false
		setup["team_games_played_before"] = team_games_played_before
		setup["game_day"] = season.current_day
		setup["rotation_order_ids"] = rotation_decision.get("order_ids", [])
		setup["rotation_selected_index"] = int(rotation_decision.get("selected_index", -1))
		setup["rotation_reason"] = str(rotation_decision.get("reason", ""))
		setup["callup_appearance_baseline"] = season.get_callup_appearance_baselines(team_id)
	return setup


# 打順設定画面の「自動編成」。opponent_hand を渡すとその利き腕の先発を想定した打線を返す
# (対左タブの自動編成)。
static func preview_lineup(
	season: PSSeason, team_id: int, dh_enabled: bool, opponent_hand: String = ""
) -> Dictionary:
	var prepared: Dictionary = prepare_team_setup(season, team_id, dh_enabled)
	if not bool(prepared.get("ok", false)):
		return prepared

	var starter_pitchers: Array = prepared["starter_pitchers"] as Array
	var available_fielders: Array = prepared["available_fielders"] as Array
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starter_pitchers)
	var rotation_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	if rotation_pitcher == null:
		return {"ok": false, "message": "%sの先発投手を決定できません" % GameSimulator._team_name(team_id)}

	var team_games_played_before: int = 0 if team_record == null else int(team_record.stats.games)
	var setup: Dictionary = build_setup_from_auto(
		season, team_id, dh_enabled, available_fielders, rotation_pitcher, team_games_played_before,
		{}, LEVEL_FIRST, opponent_hand
	)
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
	var rotation_decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starter_pitchers)
	var pitcher_ids: Array = rotation_decision.get("order_ids", []) as Array
	var games_played: int = 0 if team_record == null else team_record.stats.games
	var next_pitcher: PSPlayerSeasonRecord = rotation_decision.get("pitcher", null) as PSPlayerSeasonRecord
	var next_pitcher_id: int = 0 if next_pitcher == null else next_pitcher.player_id

	return {
		"ok": true,
		"pitcher_ids": pitcher_ids,
		"next_pitcher_id": next_pitcher_id,
		"games_played": games_played,
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
	# 通常の一軍先発は6人。谷間は二軍からのスポット昇格、ローテ下位の休養・再調整は
	# TeamAutoAI の定期入替で補う。同名定数と同じ値に保つ。
	const TARGET_STARTERS: int = 6
	const TARGET_PITCHERS: int = 15
	var starters: Array = []
	var relievers: Array = []
	var fielders: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		# 育成選手は一軍登録不可 (試合に出場できない)。
		if record.development_player:
			continue
		if record.is_pitcher():
			if _is_starter_role(record):
				starters.append(record)
			else:
				relievers.append(record)
		else:
			fielders.append(record)

	# 選出スコアは overall_score (野手なら 8 ポジションぶんの守備評価を含む) なので、
	# comparator の中で引くと 1 回の sort で O(n log n) 回計算することになる。
	# 先に選手ごと 1 回だけ引いてから比較する (比較結果は同じなので並び順も変わらない)。
	var score_by_id: Dictionary = {}
	for pool in [starters, relievers, fielders]:
		for record_row in pool:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and not score_by_id.has(record.player_id):
				score_by_id[record.player_id] = _active_roster_selection_score(record)
	# 既定値は _active_roster_selection_score(null) と同じ値にしておく (並びを元と一致させる)。
	var by_overall: Callable = func(a, b) -> bool:
		return (
			_cached_selection_score(a, score_by_id) > _cached_selection_score(b, score_by_id)
		)
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


static func _records_can_field_game(
	season: PSSeason, team_id: int, records: Array, dh_enabled: bool = true, batting_memo: Dictionary = {}
) -> bool:
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
	var slots: Array = DefenseAlignmentService.assign_defensive_starters(
		available_fielders, profile, usage_settings, 1, batting_memo
	)
	if slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
		return true
	slots = DefenseAlignmentService.assign_defensive_starters(
		available_fielders, profile, {}, 1, batting_memo
	)
	return slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size()


const LEVEL_FIRST: int = 0
const LEVEL_FARM: int = 1

# ============================================================ 二軍の出場方針
#
# **二軍は一軍とは別の基準で出場を決める**。一軍は「勝つために強い順」だが、
# 二軍は育てる場なので、出場機会の配り方そのものが違う。3本柱:
#
#   1. **トッププロスペクトは優先して出す。** チーム内の若手のうち評価上位 FARM_PROSPECT_SLOTS 人を
#      プロスペクトとみなし、大きな加点 + 高い目標出場率を与える (ほぼ毎日出る)。
#   2. **それ以外は能力だけで機会を決めない。** 能力の寄与を FARM_ABILITY_WEIGHT で弱め、
#      代わりに**出場が少ない選手ほど優先度が上がる輪番**を効かせる。
#      同程度の控え同士なら、昨日出た選手より出ていない選手が先に出る。
#   3. 育成・若手を底上げし、ベテランは控えめにする。
#
# ⚠️ 単純な能力順だと二軍は「一軍に上がれなかった上位から順に9人」を毎日並べ、
#    **育成選手の出場率が5% (125人中6人) にしかならなかった** (実測)。
# 単位は表示能力スケール (batting_score_with_form と同じ)。すべて較正ノブ。
const FARM_DEVELOPMENT_PRIORITY_BONUS: float = 10.0
const FARM_YOUTH_PRIORITY_AGE: int = 24
const FARM_YOUTH_PRIORITY_BONUS: float = 6.0
const FARM_VETERAN_PRIORITY_AGE: int = 30
const FARM_VETERAN_PRIORITY_PENALTY: float = 6.0

# 能力の重み。1.0 なら一軍と同じく能力が支配的になる。下げるほど「誰に経験を積ませるか」で決まる。
const FARM_ABILITY_WEIGHT: float = 0.55
# トッププロスペクト = 24歳以下でチーム内評価上位 N 人。**チーム相対**で決めるので、
# 絶対閾値が母集団の変化で陳腐化しない ([[project_player_form_evaluation]] と同じ考え方)。
const FARM_PROSPECT_MAX_AGE: int = 24
const FARM_PROSPECT_SLOTS: int = 5
const FARM_PROSPECT_BONUS: float = 16.0
# 輪番の強さ。「その集団の平均出場率」を基準に、少ない選手を持ち上げ多い選手を下げる。
# プロスペクトだけは平均の FARM_PROSPECT_SHARE_MULT 倍を目標にするので、輪番に沈まない。
const FARM_OPPORTUNITY_WEIGHT: float = 30.0
const FARM_PROSPECT_SHARE_MULT: float = 2.0

# ⚠️ **ファーム専用球団も同じ3本柱で組む。** 専用球団だけ素の能力順で組ませると、
# 元NPBの主力を毎日並べられるぶん相手 (12球団の二軍) より起用が最適化され、勝率が跳ね上がる。
# 二軍リーグの起用ルールは全14球団で共通にする。


# 二軍用の打撃評価を memo へ**先に**入れておく。以降の選考 (守備配置・DH・控え) は
# `_batting_memo_score` が memo にある値をそのまま使うので、選考ロジック側は無改修で済む。
static func _prime_farm_batting_memo(batting_memo: Dictionary, candidates: Array, team_farm_games: int) -> void:
	var prospects: Dictionary = farm_prospect_ids(candidates)
	var mean_share: float = _farm_mean_appearance_share(candidates, team_farm_games, false)
	for record_row in candidates:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or batting_memo.has(record.player_id):
			continue
		var score: float = float(PlayerValueEvaluator.batting_score_with_form(record)) * FARM_ABILITY_WEIGHT
		score += farm_usage_priority(
			record, prospects.has(record.player_id),
			float(record.farm_batter_stats.games), team_farm_games, mean_share
		)
		batting_memo[record.player_id] = int(round(score))


# 二軍での起用優先度の加点。育成/若手/プロスペクトの底上げ + 出場機会の輪番。
# mean_share は同じ母集団 (その日の候補) の平均出場率。0 未満を渡すと輪番は効かない。
static func farm_usage_priority(
	record: PSPlayerSeasonRecord,
	is_prospect: bool,
	played_games: float,
	team_farm_games: int,
	mean_share: float
) -> float:
	if record == null:
		return 0.0
	var bonus: float = farm_development_priority(record)
	if is_prospect:
		bonus += FARM_PROSPECT_BONUS
	bonus += _farm_opportunity_bonus(is_prospect, played_games, team_farm_games, mean_share)
	return bonus


# 出場機会の輪番。**能力ではなく「これまでどれだけ出たか」だけで決まる項**。
# 目標 (プロスペクトは平均の倍、それ以外は平均) との差を評価点へ換算する。
# 開幕直後 (team_farm_games=0) は実績が無いので効かせない。
static func _farm_opportunity_bonus(
	is_prospect: bool, played_games: float, team_farm_games: int, mean_share: float
) -> float:
	if team_farm_games <= 0 or mean_share < 0.0:
		return 0.0
	var share: float = played_games / float(team_farm_games)
	var target: float = mean_share * (FARM_PROSPECT_SHARE_MULT if is_prospect else 1.0)
	return clampf(target - share, -1.0, 1.0) * FARM_OPPORTUNITY_WEIGHT


# 候補集団の平均出場率。輪番の基準点。**集団自身から測る**ので、野手 (毎日9枠) と
# 投手 (数日に1度) で別の定数を持たなくて済む。
static func _farm_mean_appearance_share(candidates: Array, team_farm_games: int, pitchers: bool) -> float:
	if team_farm_games <= 0:
		return -1.0
	var total: float = 0.0
	var count: int = 0
	for record_row in candidates:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		count += 1
		total += float(record.farm_pitcher_stats.games if pitchers else record.farm_batter_stats.games)
	if count == 0:
		return -1.0
	return total / float(count) / float(team_farm_games)


# トッププロスペクト (チーム内の若手で評価上位)。同点は player_id で決めて決定性を保つ。
static func farm_prospect_ids(candidates: Array) -> Dictionary:
	var young: Array = []
	for record_row in candidates:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.age <= FARM_PROSPECT_MAX_AGE:
			young.append(record)
	if young.is_empty():
		return {}
	var scores: Dictionary = {}
	for record_row in young:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		scores[record.player_id] = PlayerValueEvaluator.overall_score(record)
	young.sort_custom(func(a, b) -> bool:
		var ra: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var rb: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var sa: int = int(scores.get(ra.player_id, 0))
		var sb: int = int(scores.get(rb.player_id, 0))
		if sa == sb:
			return ra.player_id < rb.player_id
		return sa > sb
	)
	var ids: Dictionary = {}
	for i in range(min(FARM_PROSPECT_SLOTS, young.size())):
		ids[(young[i] as PSPlayerSeasonRecord).player_id] = true
	return ids


# 育成 > 若手 > 中堅 > ベテラン の素の加点 (出場実績に依らない部分)。
# 二軍リーグの全14球団に効く — 専用球団だけ外すと主力の元NPBベテランを毎日並べられ、
# 相手より起用が最適化される。
static func farm_development_priority(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	var bonus: float = 0.0
	if record.development_player:
		bonus += FARM_DEVELOPMENT_PRIORITY_BONUS
	if record.age <= FARM_YOUTH_PRIORITY_AGE:
		bonus += FARM_YOUTH_PRIORITY_BONUS
	elif record.age >= FARM_VETERAN_PRIORITY_AGE:
		bonus -= FARM_VETERAN_PRIORITY_PENALTY
	return bonus


# 二軍戦に出られる選手。**一軍登録 (active_roster) の裏返し + 育成選手**。
# ファーム専用球団は一軍を持たないので在籍者全員が対象。
# 故障者の除外は後段の eligible_or_fallback が行う。
#
# ⚠️ `season.get_active_roster` は**一軍の試合準備で初めて作られる**ため、二軍を先に回す
# 日次順序では開幕日に空になる。空のまま裏返すと全員 (= 一軍の主力を含む) が二軍戦に出てしまうので、
# その場合は `preview_active_roster` で一軍登録を導出して除外に使う。
# **保存はしない** — dh 条件が一軍の試合と異なり得るため、保存すると一軍の編成を変えてしまう。
static func farm_eligible_records(season: PSSeason, team_id: int, all_records: Array) -> Array:
	if PSFarmLeague.is_farm_club_id(team_id):
		return all_records.duplicate()
	var active_id_list: Array = season.get_active_roster(team_id).get("player_ids", []) as Array
	if active_id_list.is_empty():
		var preview: Dictionary = preview_active_roster(season, team_id)
		if bool(preview.get("ok", false)):
			active_id_list = preview.get("player_ids", []) as Array
	var active_ids: Dictionary = {}
	for id_value in active_id_list:
		active_ids[int(id_value)] = true
	var farm_records: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or active_ids.has(record.player_id):
			continue
		farm_records.append(record)
	return farm_records


static func prepare_team_setup(
	season: PSSeason,
	team_id: int,
	dh_enabled: bool = true,
	batting_memo: Dictionary = {},
	level: int = LEVEL_FIRST
) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	if level == LEVEL_FARM:
		return _prepare_farm_setup(season, team_id, dh_enabled, batting_memo, all_records)
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
		active_needs_repair = not _records_can_field_game(season, team_id, active_records, dh_enabled, batting_memo)
	if active_needs_repair:
		var preview: Dictionary = preview_active_roster(season, team_id, dh_enabled)
		if bool(preview.get("ok", false)):
			var preview_records: Array = _records_for_ids(all_records, preview.get("player_ids", []) as Array)
			if not preview_records.is_empty() and _records_can_field_game(season, team_id, preview_records, dh_enabled, batting_memo):
				active_records = preview_records
				season.set_active_roster(team_id, {"player_ids": _record_ids(active_records)})
				_record_initial_active_appearance_baselines(season, team_id, active_records)
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

	_sort_by_starter_order(starter_pitchers)

	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
	var reliever_pool: Array = reliever_pool_candidates(pitchers)

	return {
		"ok": true,
		"starter_pitchers": starter_pitchers,
		"available_fielders": available_fielders,
		"reliever_pool": reliever_pool,
		"team_record": team_record,
	}


static func _record_initial_active_appearance_baselines(
	season: PSSeason, team_id: int, active_records: Array
) -> void:
	for record_row in active_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		var appearances: int = (
			record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games
		)
		season.record_callup_appearance_baseline(team_id, record.player_id, appearances)


# 二軍用のロスター準備。一軍のような active_roster の修復機構は持たない
# (二軍は「一軍に上がらなかった全員」なので、選ぶ余地がそもそも無い)。
# 育成選手を出場可能として扱うのがここの要点。
static func _prepare_farm_setup(
	season: PSSeason,
	team_id: int,
	dh_enabled: bool,
	_batting_memo: Dictionary,
	all_records: Array
) -> Dictionary:
	var records: Array = farm_eligible_records(season, team_id, all_records)
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

	var starter_pitchers: Array = eligible_or_fallback(starter_pitcher_candidates(pitchers), 1, true)
	var required_fielders: int = _minimum_fielders_for_game(dh_enabled)
	var available_fielders: Array = eligible_or_fallback(fielders, required_fielders, true)

	# 一軍が上位を抜いた残りなので、故障が重なると人数が足りないことが実際に起こり得る。
	# その場合はエラーを返し、呼び出し側 (PSFarmGameRunner) が試合を中止扱いにする。
	if starter_pitchers.is_empty():
		return {"ok": false, "message": "%sの二軍に先発できる投手がいません" % GameSimulator._team_name(team_id)}
	if available_fielders.size() < required_fielders:
		return {"ok": false, "message": "%sの二軍の野手が%d人未満です" % [GameSimulator._team_name(team_id), required_fielders]}

	_sort_by_starter_order(starter_pitchers)
	return {
		"ok": true,
		"starter_pitchers": starter_pitchers,
		"available_fielders": available_fielders,
		"reliever_pool": eligible_or_fallback(reliever_pool_candidates(pitchers), 1, true),
		"team_record": RecordStore.get_team_record(team_id, season.year, season.season_number),
	}


static func build_setup_from_auto(
	season: PSSeason,
	team_id: int,
	dh_enabled: bool,
	available_fielders: Array,
	rotation_pitcher: PSPlayerSeasonRecord,
	team_games_played_before: int = -1,
	batting_memo: Dictionary = {},
	level: int = LEVEL_FIRST,
	opponent_hand: String = ""
) -> Dictionary:
	if team_games_played_before < 0:
		var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
		team_games_played_before = 0 if team_record == null else int(team_record.stats.games)
	# ⚠️ 守備起用設定 (fielder_usage) と自動打順は**一軍専用の保存状態**。二軍がこれを読むと
	# 一軍のスタメン計画で二軍の配置が決まり、書き戻すと一軍側が二軍の顔ぶれで上書きされる。
	# 二軍は保存設定を一切参照せず、その日のロスターから毎試合作る。
	var is_farm: bool = level == LEVEL_FARM
	if is_farm:
		_prime_farm_batting_memo(batting_memo, available_fielders, team_games_played_before)
	var usage_settings: Dictionary = {} if is_farm else season.get_fielder_usage(team_id)
	var team: PSTeam = GameDb.get_team(team_id)
	var needs_ai_defaults: bool = (
		not is_farm and _usage_needs_ai_defaults(usage_settings, available_fielders)
	)
	# 自動編成チームの守備起用設定は AI_USAGE_REBUILD_INTERVAL 試合ごとに組み直す。
	# 定位置を一度決めたきり動かさないと、不振のレギュラーが一年間同じ出場シェアで出続ける。
	# スタメン選出 (`starter_assignment_score`) は今季成績込み (`batting_score_with_form` +
	# 実測 OAA) なので、組み直せば不振の選手は定位置を失い、好調な控えが取る。
	# 組み直しでは出場シェア自体も測り直す (refresh_shares) — シェアはリーグ相対の位置で
	# 決まるため、保存値を持ち回すと不振の主力が高いシェアのまま残る。
	# 毎試合やると日替わりスタメンになるので間隔を空け、選出側の在籍ボーナスがヒステリシスになる。
	var periodic_rebuild: bool = (
		not is_farm
		and not needs_ai_defaults
		and team != null
		and team.auto_lineup
		and team_games_played_before > 0
		and team_games_played_before % AI_USAGE_REBUILD_INTERVAL == 0
	)
	if needs_ai_defaults or periodic_rebuild:
		# 組み直しでは保存設定を渡さない — 渡すと現レギュラーがそのまま選ばれ、評価し直す意味が無い。
		var evaluation_usage: Dictionary = {} if periodic_rebuild else usage_settings
		var base_slots: Array = select_defensive_starters_with_usage(
			team_id, available_fielders, evaluation_usage, 1, batting_memo
		)
		if base_slots.size() >= GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
			usage_settings = build_ai_fielder_usage(
				available_fielders, base_slots, usage_settings, periodic_rebuild
			)
			season.set_fielder_usage(team_id, usage_settings)
	if not is_farm and team != null and team.auto_lineup:
		usage_settings = _usage_with_callup_start(
			usage_settings,
			available_fielders,
			season.get_callup_appearance_baselines(team_id)
		)
	# 当日の守備は相手先発の利き腕込みで決める (プラトーン起用)。デプスチャート自体を組み直す
	# 上の評価呼び出しは左右を渡さない — 定位置とシェアは特定の1試合の相手で決めるものではない。
	var fielding_slots: Array = (
		select_defensive_starters_with_usage(team_id, available_fielders, {}, team_games_played_before + 1, batting_memo)
		if is_farm
		else select_defensive_starters_with_usage(
			team_id, available_fielders, usage_settings, team_games_played_before + 1, batting_memo, opponent_hand
		)
	)
	if fielding_slots.size() < GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER.size():
		return {"ok": false, "message": "%sの守備位置を埋められません" % GameSimulator._team_name(team_id)}
	var batting_order: Array = records_from_fielding_slots(fielding_slots)
	var position_by_player_id: Dictionary = position_map_from_fielding_slots(fielding_slots)
	if dh_enabled:
		# **DH は独立した守備位置ではなく、守備枠から溢れた選手の受け皿。**
		# 2026 パ・リーグの実測では DH 先発の 2/3 を守備もする選手が取っている
		# (守備レギュラーの半休 39% / 守備と半々 27%)。「その日守備で先発しない中の打撃最良」で
		# 埋めるだけで、併用型 (DeNA 佐野/宮﨑/筒香 のように 3 人で 2 枠) も半休型
		# (ソフトバンク 柳田 DH64・左翼24 / 近藤 DH32・守備75) も同じ機構から出る。
		# **休養日の選手を除外しない**のが要点 — 守備を外れた日に DH へ回るのが実際の起用。
		# 詳細と実データは [[project_qualified_batter_count]]。
		# ユーザーが専任DHを指定していればその選手を優先する (シェアで休養日も入る)。
		var designated_hitter: PSPlayerSeasonRecord = _dedicated_dh_for_game(
			usage_settings, available_fielders, fielding_slots, team_games_played_before + 1
		)
		if designated_hitter == null:
			designated_hitter = select_designated_hitter(
				available_fielders, fielding_slots, {}, batting_memo, opponent_hand
			)
		if designated_hitter == null:
			return {"ok": false, "message": "%sにDH候補がいません" % GameSimulator._team_name(team_id)}
		batting_order.append(designated_hitter)
		position_by_player_id[designated_hitter.player_id] = BattingOrderService.DH_POSITION

	# auto_lineup ON なら日替わり打順サービス、OFF なら基本打順のみ。
	# 二軍は日替わり打順サービスを使わない。`PSBattingOrderProfile` はチーム単位の静的キャッシュで、
	# `season.set_auto_batting_order` と合わせて**一軍の基本打順を保持する共有状態**なので、
	# 二軍の顔ぶれで踏むと一軍の打順が壊れる。二軍は能力順の単純な打順で組む。
	if not is_farm and team != null and team.auto_lineup:
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
			"opp_pitcher_hand": opponent_hand,
			"position_by_player_id": position_by_player_id,
			"team_games_played": team_games_played_before,
		}
		batting_order = BattingOrderService.build_daily_batting_order(batting_order, ctx, profile)
		# 基本打順は初回と定期リフレッシュで profile 側が差し替わる。セーブへはそれをそのまま写す。
		season.set_auto_batting_order(team_id, dh_enabled, profile.base_order_player_ids)
	else:
		sort_batting_order(batting_order, position_by_player_id, opponent_hand)
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


static func build_setup_from_saved(
	_season: PSSeason,
	team_id: int,
	dh_enabled: bool,
	available_fielders: Array,
	rotation_pitcher: PSPlayerSeasonRecord,
	saved: Dictionary,
	batting_memo: Dictionary = {}
) -> Dictionary:
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
		var fielder: PSPlayerSeasonRecord = best_fielder_for_position(
			remaining, position, true, batting_memo
		)
		if fielder == null:
			fielder = best_fielder_for_position(remaining, position, false, batting_memo)
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
				var dh: PSPlayerSeasonRecord = select_designated_hitter(
					remaining, fielding_assignments, {}, batting_memo
				)
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


# 当日の先発守備を `PSDefenseAlignmentService` に解かせる。初回はチームの greedy template を
# 算出して profile へキャッシュし、以後の試合は不在選手だけを backup_priority 経由で補充する。
static func select_defensive_starters(
	season: PSSeason,
	team_id: int,
	candidates: Array,
	next_game_number: int = 1,
	batting_memo: Dictionary = {}
) -> Array:
	var profile: PSDefenseAlignmentProfile = DefenseAlignmentProfile.load_for_team(team_id)
	var usage_settings: Dictionary = season.get_fielder_usage(team_id) if season != null else {}
	return DefenseAlignmentService.assign_defensive_starters(
		candidates, profile, usage_settings, next_game_number, batting_memo
	)


static func select_defensive_starters_with_usage(
	team_id: int,
	candidates: Array,
	usage_settings: Dictionary,
	next_game_number: int = 1,
	batting_memo: Dictionary = {},
	opponent_hand: String = ""
) -> Array:
	var profile: PSDefenseAlignmentProfile = DefenseAlignmentProfile.load_for_team(team_id)
	return DefenseAlignmentService.assign_defensive_starters(
		candidates, profile, usage_settings, next_game_number, batting_memo, opponent_hand
	)


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
	var sub_ids: Array = []
	for position in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var slot: Dictionary = _usage_slot_for_position(position_slots, int(position))
		var candidates: Array = DefenseAlignmentService.slot_candidates(slot)
		if candidates.is_empty():
			return true
		var starter_share: float = DefenseAlignmentService.slot_starter_share(slot)
		var starter_id: int = int((candidates[0] as Dictionary).get("player_id", 0))
		starter_ids[starter_id] = true
		# シェア未設定 (0.0 = 「自動」) は AI に決めさせる。
		if starter_share <= 0.0:
			return true
		# シェアが 1.0 未満なのに併用相手が居ない枠は、残りを取る候補を AI に埋めさせる。
		if candidates.size() < 2:
			if starter_share >= 1.0:
				continue
			return true
		var sub_id: int = int((candidates[1] as Dictionary).get("player_id", 0))
		if sub_id <= 0 or sub_id == starter_id:
			return true
		sub_ids.append(sub_id)
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
	for sub_id_value in sub_ids:
		if starter_ids.has(int(sub_id_value)):
			return true
	return false


# refresh_shares: 定期組み直しでは出場シェアも測り直す。シェアはリーグ相対の位置 (今季成績込み)
# で変わるので、保存値を持ち回すと不振になった主力がそのまま同じ出場割合を保ってしまう。
# ユーザーが手で設定したシェアを壊さないよう、既定生成時 (false) は保存値を優先する。
static func build_ai_fielder_usage(
	available_fielders: Array,
	base_fielding_slots: Array,
	existing_usage: Dictionary = {},
	refresh_shares: bool = false
) -> Dictionary:
	var existing_slots: Dictionary = existing_usage.get("position_slots", {}) as Dictionary
	var position_slots: Dictionary = existing_slots.duplicate(true)
	var starter_ids: Dictionary = {}
	var assigned_sub_ids: Dictionary = {}
	for slot_row in base_fielding_slots:
		var assignment: Dictionary = slot_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			starter_ids[record.player_id] = true
	# DH は既定ではデプスチャートを持たない (下の DH 選出の注記を参照)。例外はユーザーが
	# 打順設定画面で**専任DHを指定した**枠だけで、それは share_locked で残す。
	# **守備枠のループより前に**専任DHを確保しないと `_best_sub_for_position` に取られる。
	var dh_slot: Dictionary = _usage_slot_for_position(position_slots, BattingOrderService.DH_POSITION)
	if DefenseAlignmentService.slot_share_locked(dh_slot):
		assigned_sub_ids[DefenseAlignmentService.slot_starter_id(dh_slot)] = true
	else:
		position_slots.erase(str(BattingOrderService.DH_POSITION))
	for slot_row in base_fielding_slots:
		var assignment: Dictionary = slot_row as Dictionary
		var position: int = int(assignment.get("position", 0))
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record == null or position < 2 or position > 9:
			continue
		var existing_slot: Dictionary = _usage_slot_for_position(position_slots, position)
		var existing_candidates: Array = DefenseAlignmentService.slot_candidates(existing_slot)
		var starter_id: int = DefenseAlignmentService.slot_starter_id(existing_slot)
		var starter: PSPlayerSeasonRecord = _record_by_id(available_fielders, starter_id)
		# base_fielding_slots は今季成績込みの選出結果なので、その位置の最良をそのまま定位置にする。
		# 僅差では選出側の在籍ボーナスで現レギュラーが残るため、ここで別途ヒステリシスは持たない。
		if starter_id <= 0 or starter == null or position_aptitude(starter, position) <= 0 \
				or record.player_id != starter_id:
			starter_id = record.player_id
		starter_ids[starter_id] = true
		var sub_id: int = 0
		if existing_candidates.size() > 1:
			sub_id = int((existing_candidates[1] as Dictionary).get("player_id", 0))
		elif not (existing_slot.get("backup_ids", []) as Array).is_empty():
			# ユーザーが「控え」に置いた先頭を併用相手として優先する。
			sub_id = int((existing_slot.get("backup_ids", []) as Array)[0])
		if starter_ids.has(sub_id) or assigned_sub_ids.has(sub_id):
			sub_id = 0
		var share: float = 0.0
		if not existing_candidates.is_empty():
			share = float((existing_candidates[0] as Dictionary).get("share", 0.0))
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
		# ユーザーが打順設定画面で明示指定したシェアは定期組み直しでも測り直さない。
		var share_locked: bool = DefenseAlignmentService.slot_share_locked(existing_slot)
		if share <= 0.0 or (refresh_shares and not share_locked):
			share = _starter_share_for(record, sub, position)
		# 併用相手を確保できなかった枠は全試合出場に倒す。1.0 未満のまま相手なしで残すと
		# `_usage_needs_ai_defaults` が毎試合 true を返し、AI 既定生成が毎試合走ってしまう
		# (DH の定位置を先に確保するぶんベンチが 1 人減るので、実際に起きる)。
		if sub_id <= 0:
			share = 1.0
		# ユーザが「控え」で設定した補充優先リストは AI 既定生成でも保持する。
		# AI 既定は 2 人までのデプス。3 人以上の併用はユーザーが手で組む枠。
		var candidates: Array = [{"player_id": starter_id, "share": share}]
		if sub_id > 0 and share < 1.0:
			candidates.append({"player_id": sub_id, "share": 1.0 - share})
		position_slots[str(position)] = DefenseAlignmentService.make_slot(
			candidates, (existing_slot.get("backup_ids", []) as Array), share_locked
		)

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


# --- 出場シェア (定位置がその守備位置の先発を何割取るか) ---
#
# **シェアはリーグの先発級の中での相対位置だけで決める。控えとの能力差では決めない。**
# 控えとの rating 差から休養間隔を決める形にすると、控えは定義上ベンチ級で差がほぼ常に大きく、
# 96 枠中 82 枠が上限へ張り付く。その上限 (10 試合に 1 度の休養 = 129 先発) は規定打席ライン
# (105 先発) より上なので、**どう設定しても全枠が規定に届いてしまう**
# ([[project_qualified_batter_count]] に実測)。
#
# `PSBatterForm.regular_z` は「能力だけで測った先発級分布」に「今季成績込みの総合指標」を
# 当てた σ 値なので、次の 2 つが自動的に入る ([[project_player_form_evaluation]] の作法):
#   - リーグ内で突出していない選手は、控えとの差が大きくても全試合出場にならない
#   - 能力はあっても今季打てていなければ位置が下がり、出場が減る (打席が増えるほど成績の比重が上がる)
#
# アンカーは (z, share)。z は守備位置別にゼロ点を合わせてあるので、
# **その守備位置の平均的な定位置選手 (z=0) が share 0.85 ≒ 122 先発**。
# **シェアは「怪我をしなければ何試合先発するか」の設定値**であって実際の先発数ではない。
# 故障や途中交代で平均 15 試合前後が落ちるので、z=0 の実測先発数は 100 前後 = 規定打席の前後。
# → **故障や途中出場の量を変えたらここを動かして総量を戻す**。
#
# 曲線は帯によって効く指標が違うので、ズレている方だけを動かす:
#   - z ≒ -0.3〜+0.4 (規定打席ラインの前後) … **規定到達者数** (目標 52-65人)
#   - z ≧ +0.6 (準全試合出場の層) … **先発130試合以上の人数** (実 NPB は 17人 = 1球団 1.4人)
# 上端の値は実行時間に影響しない (0.99 でも `run_balance_report` の所要時間は変わらない)。
const SHARE_CURVE: Array = [
	[-1.50, 0.48],
	[-1.00, 0.55],
	[-0.50, 0.72],
	[0.00, 0.85],
	[0.60, 0.92],
	[1.30, 0.97],
	[2.20, 1.00],
]
# 控えとの差による副次補正。主役はあくまでリーグ相対だが、これが無いと
# 「代役がベンチ級しか居ないのに定位置選手が休む」「控えが定位置級でも出番が増えない」が起きる。
# TYPICAL は「ふつうの定位置 vs 控え」の z 差で、そこからのズレだけを ±で効かせる。
const SHARE_GAP_TYPICAL_Z: float = 1.0
const SHARE_GAP_WEIGHT: float = 0.08
const SHARE_GAP_MIN: float = -0.10
const SHARE_GAP_MAX: float = 0.08
# **守備位置ごとのシェア上限。** リーグ相対の位置がどれだけ高くてもここを超えない。
# 上限を置くのは「その枠は 1 人では回せない」という身体的な理由がある位置だけ
# (載せない位置は SHARE_MAX = 1.0)。遊撃・二塁・中堅は実 NPB でも全試合出場の主力がいるので
# 上限を持たない。**DH も不要**: DH の定位置は構造上「守備スタメン 9 人目の打者」= リーグ相対 z が
# 低く、曲線の出力が 0.78 を超えないため上限が発火しない (0.62 / 0.80 / 1.00 の 3 通りで実測しても
# 到達者数・DH 枠の延べ起用人数とも有意差なし)。
#   - 捕手: 守備負荷。143×0.86 ≒ 123 先発。
#     現行の較正では捕手の曲線出力が 0.63 前後なので、実際に効くのは打撃が突出した正捕手だけ。
const POSITION_SHARE_MAX: Dictionary = {
	2: 0.86,
}
const SHARE_MIN: float = 0.40
const SHARE_MAX: float = 1.00


# 定位置選手がその守備位置の先発を取る割合。控えが居なければ休ませようがないので 1.0。
static func _starter_share_for(
	starter: PSPlayerSeasonRecord, sub: PSPlayerSeasonRecord, position: int
) -> float:
	if starter == null or sub == null:
		return 1.0
	var starter_z: float = PSBatterForm.regular_z(starter, position)
	var gap: float = starter_z - PSBatterForm.regular_z(sub, position)
	var gap_bonus: float = clampf(
		(gap - SHARE_GAP_TYPICAL_Z) * SHARE_GAP_WEIGHT, SHARE_GAP_MIN, SHARE_GAP_MAX
	)
	return _clamped_share(_share_from_curve(starter_z) + gap_bonus, position)


static func _clamped_share(share: float, position: int) -> float:
	return clampf(
		minf(share, float(POSITION_SHARE_MAX.get(position, SHARE_MAX))), SHARE_MIN, SHARE_MAX
	)


# SHARE_CURVE の線形補間 (両端はクランプ)。
static func _share_from_curve(z: float) -> float:
	var first: Array = SHARE_CURVE[0] as Array
	if z <= float(first[0]):
		return float(first[1])
	for index in range(1, SHARE_CURVE.size()):
		var high: Array = SHARE_CURVE[index] as Array
		if z > float(high[0]):
			continue
		var low: Array = SHARE_CURVE[index - 1] as Array
		var span: float = float(high[0]) - float(low[0])
		if span <= 0.0:
			return float(high[1])
		var t: float = (z - float(low[0])) / span
		return float(low[1]) + (float(high[1]) - float(low[1])) * t
	return float((SHARE_CURVE[SHARE_CURVE.size() - 1] as Array)[1])


static func _record_by_id(records: Array, player_id: int) -> PSPlayerSeasonRecord:
	for row in records:
		var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return record
	return null


# 自動管理チームは、昇格させた野手へ少なくとも1試合の先発機会を与える。
# 保存済みの守備起用設定は変えず、この試合だけ候補1人を定期休養の控え枠へ差し込む。
# baseline は昇格時点の一軍出場数なので、1試合出れば次戦から通常起用へ戻る。
static func _usage_with_callup_start(
	usage_settings: Dictionary,
	available_fielders: Array,
	baselines: Dictionary
) -> Dictionary:
	var pending_callups: Array = []
	var pending_debuts: Array = []
	var starter_ids: Dictionary = {}
	var position_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	for slot_value in position_slots.values():
		var slot: Dictionary = slot_value as Dictionary
		starter_ids[DefenseAlignmentService.slot_starter_id(slot)] = true
	for row in available_fielders:
		var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if record == null or record.injury_days > 0 or record.is_pitcher():
			continue
		var key: String = str(record.player_id)
		var awaiting_callup_appearance: bool = (
			baselines.has(key) and record.batter_stats.games <= int(baselines[key])
		)
		if awaiting_callup_appearance:
			# 既に基本スタメンなら、この試合で自然に機会を得る。
			if starter_ids.has(record.player_id):
				return usage_settings
			pending_callups.append(record)
			continue
		# 開幕時の控えも一度は起用する。基本スタメンの未出場者は自然に出るため候補外。
		if record.batter_stats.games <= 0 and not starter_ids.has(record.player_id):
			pending_debuts.append(record)
	var pending: Array = pending_callups if not pending_callups.is_empty() else pending_debuts
	if pending.is_empty():
		return usage_settings
	pending.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var score_a: int = PlayerValueEvaluator.overall_score(record_a)
		var score_b: int = PlayerValueEvaluator.overall_score(record_b)
		if score_a == score_b:
			return record_a.player_id < record_b.player_id
		return score_a > score_b
	)
	var candidate: PSPlayerSeasonRecord = pending[0] as PSPlayerSeasonRecord
	var best_position: int = 0
	var best_aptitude: int = 0
	for position_row in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var position: int = int(position_row)
		var aptitude: int = position_aptitude(candidate, position)
		if aptitude > best_aptitude:
			best_aptitude = aptitude
			best_position = position
	if best_position <= 0:
		return usage_settings
	var out: Dictionary = usage_settings.duplicate(true)
	var out_slots: Dictionary = (out.get("position_slots", {}) as Dictionary).duplicate(true)
	var callup_slot: Dictionary = _usage_slot_for_position(out_slots, best_position).duplicate(true)
	# この試合だけ候補列を差し替える。定位置選手を share 0 で先頭に残すのは、
	# 「この枠の定位置は本来この選手」という情報を落とさないため (make_slot は share 0 を
	# 落とすので、ここは正規化せず直接組む)。押し出された選手は守備には就かないが、
	# その日の DH 候補には入る (実際の起用でも「守備を外れて DH」は普通)。
	var displaced_starter_id: int = DefenseAlignmentService.slot_starter_id(callup_slot)
	var callup_candidates: Array = []
	if displaced_starter_id > 0 and displaced_starter_id != candidate.player_id:
		callup_candidates.append({"player_id": displaced_starter_id, "share": 0.0})
	callup_candidates.append({"player_id": candidate.player_id, "share": 1.0})
	callup_slot["candidates"] = callup_candidates
	out_slots[str(best_position)] = callup_slot
	out["position_slots"] = out_slots
	return out


static func best_fielder_for_position(
	candidates: Array,
	position: int,
	require_aptitude: bool,
	batting_memo: Dictionary = {}
) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -999999
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		var aptitude: int = position_aptitude(candidate, position)
		if require_aptitude and aptitude <= 0:
			continue
		var score: int = defensive_position_score(candidate, position, batting_memo)
		if score <= PlayerValueEvaluator.ZERO_APTITUDE_SCORE:
			continue
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


static func defensive_position_score(
	record: PSPlayerSeasonRecord,
	position: int,
	batting_memo: Dictionary = {}
) -> int:
	# スタメン候補スコア (打撃/守備の position 別ブレンド)。saved-lineup fallback で使う。
	# 純守備版が必要な場合は PlayerValueEvaluator.defensive_assignment_score を直接呼ぶ。
	return PlayerValueEvaluator.starter_assignment_score(
		record, position, false, _cached_batting_score(record, batting_memo)
	)


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


static func _cached_batting_score(
	record: PSPlayerSeasonRecord,
	batting_memo: Dictionary
) -> int:
	if record == null:
		return 0
	if not batting_memo.has(record.player_id):
		batting_memo[record.player_id] = PlayerValueEvaluator.batting_score_with_form(record)
	return int(batting_memo[record.player_id])


# ユーザー指定の専任DH枠から当日の担当を返す。指定が無い/休養日/故障/その日守備に就いている
# ときは null (呼び出し側が「守備を外れた選手の打撃最良」へ落ちる)。
static func _dedicated_dh_for_game(
	usage_settings: Dictionary,
	available_fielders: Array,
	fielding_slots: Array,
	next_game_number: int
) -> PSPlayerSeasonRecord:
	var position_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	var slot: Dictionary = _usage_slot_for_position(position_slots, BattingOrderService.DH_POSITION)
	if not DefenseAlignmentService.slot_share_locked(slot):
		return null
	var due_ids: Array = DefenseAlignmentService.ordered_candidate_ids_for_game(slot, next_game_number)
	if due_ids.is_empty() or int(due_ids[0]) != DefenseAlignmentService.slot_starter_id(slot):
		return null  # シェア上の休養日
	var fielding_ids: Dictionary = {}
	for slot_row in fielding_slots:
		var fielder: PSPlayerSeasonRecord = (slot_row as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			fielding_ids[fielder.player_id] = true
	var starter_id: int = DefenseAlignmentService.slot_starter_id(slot)
	if fielding_ids.has(starter_id):
		return null
	var record: PSPlayerSeasonRecord = _record_by_id(available_fielders, starter_id)
	if record == null or record.is_pitcher() or record.injury_days > 0:
		return null
	return record


static func select_designated_hitter(
	candidates: Array,
	fielding_slots: Array,
	excluded_ids: Dictionary = {},
	batting_memo: Dictionary = {},
	opponent_hand: String = ""
) -> PSPlayerSeasonRecord:
	var used_ids: Dictionary = {}
	for slot_row in fielding_slots:
		var slot: Dictionary = slot_row as Dictionary
		var fielder: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			used_ids[fielder.player_id] = true

	var best: PSPlayerSeasonRecord = null
	var best_score: float = -999999.0
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		if used_ids.has(candidate.player_id) or excluded_ids.has(candidate.player_id):
			continue
		# DH は守備が要らないぶん打撃だけで決まる。好不調 (成績の上振れ/下振れ) と、
		# 相手先発との左右の相性も込みで見る。
		var score: float = float(_cached_batting_score(candidate, batting_memo))
		score += PSPlatoonMatchup.rating_bonus_for(candidate, opponent_hand)
		if best == null or score > best_score:
			best = candidate
			best_score = score
	return best


# 打順を役割マッチング (1-2番=出塁と機動力、3-5番=中軸、6番以降=打力順、捕手は上位を避ける) で
# 並べ替える。position_by_player_id はその日の守備位置で、捕手判定に使う (省略時は登録ポジション)。
# opponent_hand を渡すと相手先発との左右の相性ぶんを加減点する。
static func sort_batting_order(
	batting_order: Array, position_by_player_id: Dictionary = {}, opponent_hand: String = ""
) -> void:
	batting_order.assign(BattingOrderService.build_base_order(
		batting_order, null, position_by_player_id,
		BattingOrderService.platoon_bonuses(batting_order, opponent_hand)
	))


static func _sort_by_starter_order(pitchers: Array) -> void:
	var score_by_id: Dictionary = {}
	for pitcher_row in pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if pitcher != null:
			score_by_id[pitcher.player_id] = PSPitcherRoleModel.starter_order_score(pitcher)
	pitchers.sort_custom(func(a, b) -> bool:
		var pitcher_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var pitcher_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return float(score_by_id.get(pitcher_a.player_id, 0.0)) \
			> float(score_by_id.get(pitcher_b.player_id, 0.0))
	)


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
		_sort_by_starter_order(rest)
		for pitcher_row in rest:
			if candidates.size() >= STARTER_POOL_MIN:
				break
			candidates.append(pitcher_row)
	return candidates


# 当日のブルペン (上位6人) に選ばれなかった健康な救援投手。非常時の継投先。
# 当日の先発とブルペン入りした投手は除く。
static func _relief_reserve(reliever_pool: Array, nominated: Array, starter: PSPlayerSeasonRecord) -> Array:
	var excluded: Dictionary = {}
	if starter != null:
		excluded[starter.player_id] = true
	for row in nominated:
		var pitcher: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if pitcher != null:
			excluded[pitcher.player_id] = true
	var reserve: Array = []
	for row in reliever_pool:
		var pitcher: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if pitcher == null or excluded.has(pitcher.player_id) or pitcher.injury_days > 0:
			continue
		reserve.append(pitcher)
	return reserve


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


# 事前計算済みスコアの参照。null は _active_roster_selection_score(null) と同値に揃える。
static func _cached_selection_score(row: Variant, scores: Dictionary) -> int:
	var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
	if record == null:
		return -2147483647
	return int(scores.get(record.player_id, -2147483647))


static func _active_roster_selection_score(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return -2147483647
	var score: int = PlayerValueEvaluator.overall_score(record)
	if record.injury_days > 0:
		score -= 100000
	return score


# 出場可能な選手だけに絞る。**育成選手は一軍では除外、二軍では出場可**
# (NPB の育成制度は「二軍で出場して支配下を狙う」制度なので、二軍戦こそが育成の主戦場)。
static func eligible_or_fallback(records: Array, _min_size: int, allow_development: bool = false) -> Array:
	var eligible: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or record.injury_days > 0:
			continue
		if record.development_player and not allow_development:
			continue
		eligible.append(record)
	return eligible
