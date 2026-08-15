extends Node

# 二軍 (ファーム) の健全性を1シーズン通しで実測するレポート。
# 二軍成績の閲覧 UI は v1 対象外なので、**これが二軍を観測する唯一の手段**になる。
#
# 見るもの:
#   - 二軍リーグの成績水準 (一軍との対比。実 NPB のファームは一軍より **ERA が高い**)
#   - 引き分け率 (延長10回打ち切りの効果。実 NPB のファームは約10%)
#   - 出場分布 (何人が出たか / 育成選手が出ているか = v1 の目的の一つ)
#   - 守備イニング (オフの守備適性成長の入力になっているか)
#   - 昇降格 (日次の active_roster 差分で実測。谷間の先発が何回発火したか / 先発の顔ぶれ)
#   - 故障件数 (二軍戦を足すと曝露が増えるので、一軍だけの頃より必ず増える)
#   - 起用加重の能力水準 (一軍と二軍で打者・投手がそれぞれ何σ違うか = 得点環境のズレの切り分け)
#   - 専用球団の状態 (ロスターサイズ・出場)
#   - 地区別の消化と勝率 (試合数が揃わない前提なので順位は勝率)
#   - 中止試合 (人数不足で組めなかった数。0 であるべき)
#
# 実行: godot --headless res://tools/run_farm_report.tscn -- --seasons=1 --seed=12345
# 補足: `--days=N` で N 日だけ回す (速い確認用)。全季は一軍込みで数十秒〜数分かかる。

const HEALTH_FARM_AVG: Array = [0.200, 0.290]
const HEALTH_FARM_WALK_RATE: Array = [0.05, 0.13]
const HEALTH_FARM_STRIKEOUT_RATE: Array = [0.13, 0.30]
const HEALTH_FARM_DRAW_RATE: Array = [0.03, 0.20]
const HEALTH_CANCELLED_MAX: int = 0
const HEALTH_DEVELOPMENT_APPEARANCE_MIN: float = 0.5
# 実 NPB のファームは一軍より打低・投高 (=ERA が高い)。イースタン/ウエスタンとも
# リーグ防御率は 3.2〜3.7 で、一軍 (2.9〜3.4) を上回る。二軍の投手・守備が劣るぶんが出る。
# モデルが逆 (二軍の方が ERA が低い) になっていたら、投打どちらの質差が効きすぎているかを
# `usage_levels` の σ 差で切り分ける。
const HEALTH_FARM_ERA: Array = [2.80, 4.60]
# 一軍で1試合以上出場した選手数/球団。NPB は年間 55〜65人 (登録・抹消の往復で顔ぶれが増える)。
const HEALTH_FIRST_TEAM_PLAYERS_USED: Array = [55.0, 65.0]
# 故障者数/球団。曝露が控え・二軍まで広がったので一軍だけの頃より増えるのが正常。
# MLB の IL 入りは近年 30件/球団前後だが、こちらは軽傷 (3-15日) も1件と数えるので上限は広く取る。
const HEALTH_INJURED_PLAYERS_PER_TEAM: Array = [8.0, 45.0]

# 未達が判明していて一時的に warn 扱いにする項目。現在は空。
const HEALTH_KNOWN_OPEN_ISSUES: Dictionary = {}

# 起用加重の能力水準を測るキー。**質の軸だけ**を使う (スタイル軸を混ぜると水準がぼやける)。
# 投手側は `PSPitcherRoleModel.ROLE_QUALITY_KEYS` と同じ考え方 (Pit_EdgeRate は除外)。
const BATTER_QUALITY_KEYS: Array[String] = ["Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Barrel"]
const PITCHER_QUALITY_KEYS: Array[String] = ["Pit_KCreate", "Pit_BBPrevent", "Pit_Efficiency", "Pit_Stamina"]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var day_limit: int = int(args.get("days", 0))
	var output_path: String = str(args.get("output", ""))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var seasons_out: Array = []
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# 実プレイと同じ日次フック (谷間の先発・一軍入替・トレード) を通す。省くと
		# スポット昇格が発火せず、昇降格の観測が実際と食い違う。
		var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
		var days_done: int = 0
		# 昇降格は日次の active_roster 差分で数える。週次入替・谷間の先発・故障修復の
		# どれが動かしたかに依らず「一軍の顔ぶれが何回変わったか」を測れるのが利点で、
		# production 側に計測用の戻り値を足さずに済む。
		var roster_state: Dictionary = {}
		var moves: Dictionary = {"promotions": 0, "demotions": 0, "promoted_ids": {}}
		while _has_unplayed_game(season):
			if day_limit > 0 and days_done >= day_limit:
				break
			var day: int = season.current_day
			var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, ctx)
			if not bool(day_result.get("ok", false)):
				errors.append({
					"season_index": season_index,
					"day": day,
					"message": str(day_result.get("message", "day simulation failed")),
				})
				break
			_track_roster_moves(season, roster_state, moves)
			days_done += 1
		seasons_out.append(_season_summary(season, moves))

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _aggregate(seasons_out)
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["errors"] = errors
	report["health"] = _health(report)
	if not output_path.is_empty():
		var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print(JSON.stringify(report, "\t"))
	_print_digest(report)
	var health_ok: bool = str((report["health"] as Dictionary).get("status", "")) != "fail"
	get_tree().quit(0 if errors.is_empty() and health_ok else 1)


func _has_unplayed_game(season: PSSeason) -> bool:
	for game_value in season.schedule:
		if not bool((game_value as Dictionary).get("played", false)):
			return true
	return false


func _season_summary(season: PSSeason, moves: Dictionary) -> Dictionary:
	var farm: Dictionary = _level_batting_line(season, PSPerformanceReference.LEVEL_FARM)
	var first: Dictionary = _level_batting_line(season, PSPerformanceReference.LEVEL_FIRST)
	return {
		"schedule": _schedule_summary(season),
		"standings": _standings_summary(season),
		"farm_batting": farm,
		"first_team_batting": first,
		"farm_pitching": _level_pitching_line(season, PSPerformanceReference.LEVEL_FARM),
		"first_team_pitching": _level_pitching_line(season, PSPerformanceReference.LEVEL_FIRST),
		"usage_levels": _usage_level_summary(season),
		"appearances": _appearance_summary(season),
		"defense": _defensive_innings_summary(season),
		"farm_clubs": _farm_club_summary(season),
		"callups": _callup_summary(season),
		"roster_moves": _roster_move_summary(season, moves),
		"injuries": _injury_summary(season),
	}


# 一軍の active_roster を前日と比べ、増えた選手を昇格・消えた選手を降格として数える。
# season 側には「現在の顔ぶれ」しか残らないので、日ごとに差分を取らないと総量が測れない。
func _track_roster_moves(season: PSSeason, roster_state: Dictionary, moves: Dictionary) -> void:
	for team_row in GameDb.teams:
		var team_id: int = (team_row as PSTeam).id
		var current: Dictionary = {}
		for id_value in (season.get_active_roster(team_id).get("player_ids", []) as Array):
			current[int(id_value)] = true
		if roster_state.has(team_id):
			var previous: Dictionary = roster_state[team_id] as Dictionary
			for player_id in current.keys():
				if not previous.has(player_id):
					moves["promotions"] = int(moves["promotions"]) + 1
					(moves["promoted_ids"] as Dictionary)[player_id] = true
			for player_id in previous.keys():
				if not current.has(player_id):
					moves["demotions"] = int(moves["demotions"]) + 1
		roster_state[team_id] = current


func _schedule_summary(season: PSSeason) -> Dictionary:
	var played: int = 0
	var cancelled: int = 0
	var cancel_reasons: Dictionary = {}
	var by_district: Dictionary = {}
	for district in PSFarmLeague.DISTRICT_ORDER:
		by_district[district] = 0
	for game_row in season.farm_schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)):
			continue
		if bool(game.get("cancelled", false)):
			cancelled += 1
			var reason: String = str(game.get("cancel_reason", "(不明)"))
			cancel_reasons[reason] = int(cancel_reasons.get(reason, 0)) + 1
			continue
		played += 1
		for key in ["away_district", "home_district"]:
			var district: String = str(game.get(key, ""))
			if by_district.has(district):
				by_district[district] = int(by_district[district]) + 1
	return {
		"total": season.farm_schedule.size(),
		"played": played,
		"cancelled": cancelled,
		"cancel_reasons": cancel_reasons,
		"team_games_by_district": by_district,
	}


func _standings_summary(season: PSSeason) -> Dictionary:
	var rows: Array = []
	var draws: int = 0
	var games: int = 0
	for team_id in season.farm_standings.keys():
		var stats: PSStats = season.farm_standings[team_id] as PSStats
		draws += stats.draws
		games += stats.games
		var decided: int = stats.wins + stats.losses
		rows.append({
			"team_id": int(team_id),
			"district": PSFarmLeague.district_for_team(int(team_id)),
			"farm_club": PSFarmLeague.is_farm_club_id(int(team_id)),
			"games": stats.games,
			"wins": stats.wins,
			"losses": stats.losses,
			"draws": stats.draws,
			"win_rate": 0.0 if decided == 0 else _round3(float(stats.wins) / float(decided)),
		})
	# 試合数が球団間で揃わない前提なので勝率順 (実 NPB のファームも勝率で順位を決める)。
	rows.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["win_rate"]) > float((b as Dictionary)["win_rate"])
	)
	return {
		"rows": rows,
		"team_games": games,
		"draws": draws,
		"draw_rate": 0.0 if games == 0 else _round3(float(draws) / float(games)),
	}


func _level_batting_line(season: PSSeason, level: int) -> Dictionary:
	var totals: PSBatterStats = PSBatterStats.new()
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		totals.add_from(PSPerformanceReference.batter_stats_for_level(record, level))
	var plate_appearances: int = totals.plate_appearances
	return {
		"plate_appearances": plate_appearances,
		"at_bats": totals.at_bats,
		"average": _round3(_safe_div(float(totals.hits), float(totals.at_bats))),
		"on_base": _round3(totals.on_base_percentage()),
		"slugging": _round3(totals.slugging_percentage()),
		"ops": _round3(totals.ops()),
		"home_runs": totals.home_runs,
		"walk_rate": _round3(_safe_div(float(totals.walks), float(plate_appearances))),
		"strikeout_rate": _round3(_safe_div(float(totals.strikeouts), float(plate_appearances))),
	}


func _level_pitching_line(season: PSSeason, level: int) -> Dictionary:
	var totals: PSPitcherStats = PSPitcherStats.new()
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		totals.add_from(PSPerformanceReference.pitcher_stats_for_level(record, level))
	return {
		"innings_pitched": _round1(totals.innings_pitched()),
		"era": _round2(totals.era()),
		"whip": _round2(totals.whip()),
		"strikeouts_per_nine": _round2(totals.strikeouts_per_nine()),
		"walks": totals.walks,
		"home_runs_allowed": totals.home_runs_allowed,
		"complete_games": totals.complete_games,
	}


# 一軍と二軍で「実際に出た選手」の能力水準が何σ違うか。出場機会 (PA / 対戦打者) で加重する。
# **得点環境のズレを投打どちらのせいか切り分けるための入力。** 二軍の ERA が一軍より低く出る
# ようなときは、打者側の落差が投手側より大きい (打線だけが薄い) ことを疑う。
func _usage_level_summary(season: PSSeason) -> Dictionary:
	var first_batter: Array = [0.0, 0.0]
	var farm_batter: Array = [0.0, 0.0]
	var first_pitcher: Array = [0.0, 0.0]
	var farm_pitcher: Array = [0.0, 0.0]
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		# 投手の打席は除く。z_abilities_snapshot に Bat_* を持たない (= 0 と読める) ため、
		# 混ぜると DH 無しの一軍だけが不当に低く出て、一軍と二軍の差を過小評価する。
		if not record.is_pitcher():
			var batter_level: float = _mean_z(record, BATTER_QUALITY_KEYS)
			_accumulate_level(first_batter, batter_level, float(record.batter_stats.plate_appearances))
			_accumulate_level(farm_batter, batter_level, float(record.farm_batter_stats.plate_appearances))
		else:
			var pitcher_level: float = _mean_z(record, PITCHER_QUALITY_KEYS)
			_accumulate_level(first_pitcher, pitcher_level, float(record.pitcher_stats.batters_faced))
			_accumulate_level(farm_pitcher, pitcher_level, float(record.farm_pitcher_stats.batters_faced))
	var batter_gap: float = _weighted_mean(farm_batter) - _weighted_mean(first_batter)
	var pitcher_gap: float = _weighted_mean(farm_pitcher) - _weighted_mean(first_pitcher)
	return {
		"first_batter_z": _round3(_weighted_mean(first_batter)),
		"farm_batter_z": _round3(_weighted_mean(farm_batter)),
		"batter_gap_z": _round3(batter_gap),
		"first_pitcher_z": _round3(_weighted_mean(first_pitcher)),
		"farm_pitcher_z": _round3(_weighted_mean(farm_pitcher)),
		"pitcher_gap_z": _round3(pitcher_gap),
		# 正なら「打線の方が余計に薄い」= 二軍が投高打低へ寄る。0 付近なら投打が同じだけ落ちている。
		"gap_asymmetry_z": _round3(pitcher_gap - batter_gap),
	}


func _mean_z(record: PSPlayerSeasonRecord, keys: Array[String]) -> float:
	var total: float = 0.0
	for key in keys:
		total += float(record.z_abilities_snapshot.get(key, 0.0))
	return total / float(keys.size())


func _accumulate_level(accumulator: Array, level: float, weight: float) -> void:
	if weight <= 0.0:
		return
	accumulator[0] = float(accumulator[0]) + level * weight
	accumulator[1] = float(accumulator[1]) + weight


func _weighted_mean(accumulator: Array) -> float:
	return _safe_div(float(accumulator[0]), float(accumulator[1]))


# 一軍の顔ぶれがどれだけ動いたか。NPB は登録・抹消の往復で年間 55〜65人が一軍出場する。
# 二軍戦を作った当初の動機 (先発の顔ぶれを増やす) の到達度をここで見る。
func _roster_move_summary(season: PSSeason, moves: Dictionary) -> Dictionary:
	var teams: float = float(max(1, GameDb.teams.size()))
	var players_used: int = 0
	var starters_used: int = 0
	var pitchers_used: int = 0
	var fielders_used: int = 0
	var both_levels: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if PSFarmLeague.is_farm_club_id(record.team_id):
			continue
		var first_team: bool = record.batter_stats.plate_appearances > 0 \
			or record.pitcher_stats.batters_faced > 0
		var farm: bool = record.farm_batter_stats.plate_appearances > 0 \
			or record.farm_pitcher_stats.batters_faced > 0
		if first_team:
			players_used += 1
			if record.is_pitcher():
				pitchers_used += 1
			else:
				fielders_used += 1
			if record.pitcher_stats.starts > 0:
				starters_used += 1
			if farm:
				both_levels += 1
	var promoted_pitchers: int = 0
	var promoted_fielders: int = 0
	var promoted_starters: int = 0
	var promoted_appeared: int = 0
	for player_id_value in (moves.get("promoted_ids", {}) as Dictionary).keys():
		var promoted: PSPlayerSeasonRecord = RecordStore.get_player_record(
			int(player_id_value), season.year, season.season_number
		)
		if promoted == null:
			continue
		if promoted.is_pitcher():
			promoted_pitchers += 1
			if promoted.pitcher_stats.starts > 0:
				promoted_starters += 1
		else:
			promoted_fielders += 1
		if promoted.batter_stats.plate_appearances > 0 \
				or promoted.pitcher_stats.batters_faced > 0:
			promoted_appeared += 1
	return {
		"promotions": int(moves.get("promotions", 0)),
		"demotions": int(moves.get("demotions", 0)),
		"promotions_per_team": _round1(float(int(moves.get("promotions", 0))) / teams),
		"demotions_per_team": _round1(float(int(moves.get("demotions", 0))) / teams),
		"distinct_promoted_players": (moves.get("promoted_ids", {}) as Dictionary).size(),
		"distinct_promoted_pitchers": promoted_pitchers,
		"distinct_promoted_fielders": promoted_fielders,
		"promoted_starters_who_appeared": promoted_starters,
		"promoted_players_who_appeared": promoted_appeared,
		"first_team_players_used": players_used,
		"first_team_players_used_per_team": _round1(float(players_used) / teams),
		"first_team_pitchers_used_per_team": _round1(float(pitchers_used) / teams),
		"first_team_fielders_used_per_team": _round1(float(fielders_used) / teams),
		"first_team_starters_used_per_team": _round1(float(starters_used) / teams),
		"players_at_both_levels": both_levels,
	}


# 故障件数。二軍戦を足すまで控え・二軍は曝露ゼロだったので、リーグ全体の件数は必ず増える
# ([[project_injury_system]] の較正監視項目)。専用球団は NPB の仕組みの外なので分けて出す。
func _injury_summary(season: PSSeason) -> Dictionary:
	var npb_injured: int = 0
	var npb_days: int = 0
	var farm_club_injured: int = 0
	var development_injured: int = 0
	var max_days: int = 0
	var severity: Dictionary = {"minor": 0, "moderate": 0, "major": 0, "severe": 0}
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if record.season_injury_days <= 0:
			continue
		if PSFarmLeague.is_farm_club_id(record.team_id):
			farm_club_injured += 1
			continue
		npb_injured += 1
		npb_days += record.season_injury_days
		max_days = max(max_days, record.season_injury_days)
		if record.development_player:
			development_injured += 1
		var key: String = _severity_key(record.injury_severity)
		severity[key] = int(severity.get(key, 0)) + 1
	var teams: float = float(max(1, GameDb.teams.size()))
	return {
		"injured_players": npb_injured,
		"injured_players_per_team": _round1(float(npb_injured) / teams),
		"injury_days_total": npb_days,
		"injury_days_mean": _round1(_safe_div(float(npb_days), float(npb_injured))),
		"injury_days_max": max_days,
		"development_injured": development_injured,
		"farm_club_injured": farm_club_injured,
		"severity_counts": severity,
	}


func _severity_key(severity: int) -> String:
	match severity:
		PSInjuryModel.TIER_MODERATE:
			return "moderate"
		PSInjuryModel.TIER_MAJOR:
			return "major"
		PSInjuryModel.TIER_SEVERE:
			return "severe"
	return "minor"


# 誰が二軍戦に出たか。**育成選手の出場率が v1 の目的の一つ** (二軍戦の追加で初めて
# 育成制度が機能する) なので、支配下と分けて出す。
func _appearance_summary(season: PSSeason) -> Dictionary:
	var controlled_total: int = 0
	var controlled_played: int = 0
	var development_total: int = 0
	var development_played: int = 0
	var development_plate_appearances: int = 0
	var development_pitcher_total: int = 0
	var development_pitcher_played: int = 0
	var development_batter_total: int = 0
	var development_batter_played: int = 0
	var qualified_batters: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if PSFarmLeague.is_farm_club_id(record.team_id):
			continue
		var appeared: bool = record.farm_batter_stats.plate_appearances > 0 \
			or record.farm_pitcher_stats.batters_faced > 0
		if record.development_player:
			development_total += 1
			if record.is_pitcher():
				development_pitcher_total += 1
				if appeared:
					development_pitcher_played += 1
			else:
				development_batter_total += 1
				if appeared:
					development_batter_played += 1
			if appeared:
				development_played += 1
				development_plate_appearances += record.farm_batter_stats.plate_appearances
		else:
			controlled_total += 1
			if appeared:
				controlled_played += 1
		if record.farm_batter_stats.plate_appearances >= PSPerformanceReference.MIN_REFERENCE_PLATE_APPEARANCES:
			qualified_batters += 1
	return {
		"controlled_total": controlled_total,
		"controlled_played": controlled_played,
		"controlled_rate": _round3(_safe_div(float(controlled_played), float(controlled_total))),
		"development_total": development_total,
		"development_played": development_played,
		"development_rate": _round3(_safe_div(float(development_played), float(development_total))),
		"development_plate_appearances": development_plate_appearances,
		"development_pitcher_total": development_pitcher_total,
		"development_pitcher_played": development_pitcher_played,
		"development_pitcher_rate": _round3(_safe_div(float(development_pitcher_played), float(development_pitcher_total))),
		"development_batter_total": development_batter_total,
		"development_batter_played": development_batter_played,
		"development_batter_rate": _round3(_safe_div(float(development_batter_played), float(development_batter_total))),
		"qualified_farm_batters": qualified_batters,
	}


# 二軍の守備イニング。オフの `apply_position_aptitude_growth` の入力なので、
# ここが 0 だと「二軍でコンバートを試しても適性が伸びない」状態になっている。
func _defensive_innings_summary(season: PSSeason) -> Dictionary:
	var total: float = 0.0
	var players_with_innings: int = 0
	var converted: int = 0
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		var own: float = 0.0
		var off_position: float = 0.0
		for position in [2, 3, 4, 5, 6, 7, 8, 9]:
			var innings: float = record.farm_defensive_innings_at(position)
			own += innings
			if position != record.position:
				off_position += innings
		if own > 0.0:
			players_with_innings += 1
		if off_position >= 9.0:
			converted += 1
		total += own
	return {
		"total_innings": _round1(total),
		"players_with_innings": players_with_innings,
		"players_with_off_position_innings": converted,
	}


func _farm_club_summary(season: PSSeason) -> Dictionary:
	var rows: Array = []
	for club_id_value in PSFarmLeague.farm_club_ids():
		var club_id: int = int(club_id_value)
		var roster: int = 0
		var appeared: int = 0
		var npb_experienced: int = 0
		for record_row in RecordStore.get_team_player_records(club_id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			roster += 1
			if record.farm_batter_stats.plate_appearances > 0 or record.farm_pitcher_stats.batters_faced > 0:
				appeared += 1
			if bool(record.source_data.get("npb_experienced", false)):
				npb_experienced += 1
		rows.append({
			"club_id": club_id,
			"roster": roster,
			"appeared": appeared,
			"npb_experienced": npb_experienced,
		})
	return {"rows": rows}


# 谷間の先発 (スポット昇格) がどれだけ発火したか。season 側には登板中のものしか残らないので、
# 抹消台帳 (demotion_day) の件数で往復の総量を測る。
func _callup_summary(season: PSSeason) -> Dictionary:
	var demotions: int = 0
	var pending: int = 0
	var distinct_farm_starters: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		demotions += season.get_demotion_days(team.id).size()
		pending += season.get_spot_callups(team.id).size()
		var farm_ids: Dictionary = {}
		var active_ids: Dictionary = {}
		for id_value in (season.get_active_roster(team.id).get("player_ids", []) as Array):
			active_ids[int(id_value)] = true
		for record_row in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			# 一軍で先発した経験があり、かつ二軍でも投げている = 往復した投手。
			if record.pitcher_stats.starts > 0 and record.farm_pitcher_stats.batters_faced > 0:
				farm_ids[record.player_id] = true
		distinct_farm_starters += farm_ids.size()
	return {
		"demotion_ledger_entries": demotions,
		"pending_spot_callups": pending,
		"shuttled_starters": distinct_farm_starters,
	}


func _aggregate(seasons_out: Array) -> Dictionary:
	if seasons_out.size() == 1:
		return (seasons_out[0] as Dictionary).duplicate(true)
	return {"per_season": seasons_out}


func _health(report: Dictionary) -> Dictionary:
	var checks: Array = []
	# 複数シーズンは per_season なので health は単季のときだけ評価する。
	if report.has("per_season"):
		return {"status": "skipped", "checks": checks, "message": "health は単季レポートでのみ評価する"}

	var batting: Dictionary = report.get("farm_batting", {}) as Dictionary
	var first: Dictionary = report.get("first_team_batting", {}) as Dictionary
	var standings: Dictionary = report.get("standings", {}) as Dictionary
	var schedule: Dictionary = report.get("schedule", {}) as Dictionary
	var appearances: Dictionary = report.get("appearances", {}) as Dictionary
	var defense: Dictionary = report.get("defense", {}) as Dictionary
	var farm_pitching: Dictionary = report.get("farm_pitching", {}) as Dictionary
	var first_pitching: Dictionary = report.get("first_team_pitching", {}) as Dictionary
	var roster_moves: Dictionary = report.get("roster_moves", {}) as Dictionary
	var injuries: Dictionary = report.get("injuries", {}) as Dictionary

	_add_range_check(checks, "farm_batting_average", float(batting.get("average", 0.0)), HEALTH_FARM_AVG, "二軍リーグの打率")
	_add_range_check(checks, "farm_walk_rate", float(batting.get("walk_rate", 0.0)), HEALTH_FARM_WALK_RATE, "二軍リーグの BB% (実 NPB ファームは9〜10%)")
	_add_range_check(checks, "farm_strikeout_rate", float(batting.get("strikeout_rate", 0.0)), HEALTH_FARM_STRIKEOUT_RATE, "二軍リーグの K%")
	_add_range_check(checks, "farm_draw_rate", float(standings.get("draw_rate", 0.0)), HEALTH_FARM_DRAW_RATE, "引き分け率 (延長10回打ち切り。実 NPB は約10%)")
	_add_max_check(checks, "farm_cancelled_games", float(schedule.get("cancelled", 0)), float(HEALTH_CANCELLED_MAX), "人数不足で組めなかった二軍戦")
	_add_min_check(checks, "development_appearance_rate", float(appearances.get("development_rate", 0.0)), HEALTH_DEVELOPMENT_APPEARANCE_MIN, "育成選手の二軍出場率 (二軍戦を作った目的の一つ)")
	_add_min_check(checks, "farm_defensive_innings", float(defense.get("total_innings", 0.0)), 1.0, "二軍の守備イニング (守備適性成長の入力)")

	_add_range_check(checks, "farm_era", float(farm_pitching.get("era", 0.0)), HEALTH_FARM_ERA, "二軍リーグの防御率 (実 NPB ファームは3.2〜3.7)")
	# 顔ぶれと故障は**通季でしか意味を持たない累積量**なので、`--days=N` の短縮実行では
	# 判定せず skipped にする (でないと短い確認実行が必ず fail して exit code が使えなくなる)。
	var full_season: bool = int(schedule.get("played", 0)) + int(schedule.get("cancelled", 0)) >= int(schedule.get("total", 0))
	if full_season:
		_add_range_check(checks, "first_team_players_used_per_team", float(roster_moves.get("first_team_players_used_per_team", 0.0)), HEALTH_FIRST_TEAM_PLAYERS_USED, "一軍で1試合以上出場した選手数/球団 (NPB 55〜65人)")
		_add_range_check(checks, "injured_players_per_team", float(injuries.get("injured_players_per_team", 0.0)), HEALTH_INJURED_PLAYERS_PER_TEAM, "故障者数/球団 (二軍戦のぶん曝露が増えている)")
	else:
		_add_skipped_check(checks, "first_team_players_used_per_team", "一軍で1試合以上出場した選手数/球団")
		_add_skipped_check(checks, "injured_players_per_team", "故障者数/球団")

	# 二軍の打撃水準は一軍より低いのが正常 (投打の質差が自然に出るのが設計の前提)。
	var farm_ops: float = float(batting.get("ops", 0.0))
	var first_ops: float = float(first.get("ops", 0.0))
	checks.append({
		"id": "farm_ops_below_first_team",
		"message": "二軍 OPS は一軍 OPS を下回るはず",
		"value": _round3(farm_ops),
		"reference": _round3(first_ops),
		"status": "pass" if farm_ops < first_ops else "warn",
	})

	# 実 NPB のファームは一軍より ERA が **高い** (投手と守備が劣るぶん)。逆転していたら
	# 「打線だけが薄い」= 投打の質差の効き方が非対称になっているサイン。
	var farm_era: float = float(farm_pitching.get("era", 0.0))
	var first_era: float = float(first_pitching.get("era", 0.0))
	checks.append({
		"id": "farm_era_above_first_team",
		"message": "二軍 ERA は一軍 ERA を上回るはず (実 NPB ファームがそうなっている)",
		"value": _round2(farm_era),
		"reference": _round2(first_era),
		"status": "pass" if farm_era > first_era else "warn",
	})

	var status: String = "pass"
	for check_row in checks:
		var check_status: String = str((check_row as Dictionary).get("status", "pass"))
		if check_status == "fail":
			status = "fail"
		elif check_status == "warn" and status == "pass":
			status = "warn"
	return {"status": status, "checks": checks}


func _add_range_check(checks: Array, id: String, value: float, range_values: Array, message: String) -> void:
	var low: float = float(range_values[0])
	var high: float = float(range_values[1])
	var check: Dictionary = {
		"id": id,
		"message": message,
		"value": _round3(value),
		"range": [low, high],
		"status": "pass" if value >= low and value <= high else "fail",
	}
	_mark_known_open_issue(check)
	checks.append(check)


# 既知の未達項目は fail ではなく warn にする。**帯そのものは動かさない** —
# 帯を緩めて pass にすると「直った」と「元から測っていない」が区別できなくなる。
func _mark_known_open_issue(check: Dictionary) -> void:
	var id: String = str(check.get("id", ""))
	if str(check.get("status", "")) != "fail" or not HEALTH_KNOWN_OPEN_ISSUES.has(id):
		return
	check["status"] = "warn"
	check["known_open_issue"] = str(HEALTH_KNOWN_OPEN_ISSUES[id])


func _add_skipped_check(checks: Array, id: String, message: String) -> void:
	checks.append({
		"id": id, "message": message, "status": "skipped",
		"reason": "通季でのみ評価する項目 (--days=N の短縮実行)",
	})


func _add_min_check(checks: Array, id: String, value: float, minimum: float, message: String) -> void:
	checks.append({
		"id": id, "message": message, "value": _round3(value), "min": minimum,
		"status": "pass" if value >= minimum else "fail",
	})


func _add_max_check(checks: Array, id: String, value: float, maximum: float, message: String) -> void:
	checks.append({
		"id": id, "message": message, "value": _round3(value), "max": maximum,
		"status": "pass" if value <= maximum else "fail",
	})


# JSON 全文はレビューしづらいので、判断に使う行だけ最後にまとめて出す。
func _print_digest(report: Dictionary) -> void:
	if report.has("per_season"):
		print("FARM REPORT: %d seasons (health は単季のみ)" % (report["per_season"] as Array).size())
		return
	var batting: Dictionary = report.get("farm_batting", {}) as Dictionary
	var first: Dictionary = report.get("first_team_batting", {}) as Dictionary
	var pitching: Dictionary = report.get("farm_pitching", {}) as Dictionary
	var standings: Dictionary = report.get("standings", {}) as Dictionary
	var schedule: Dictionary = report.get("schedule", {}) as Dictionary
	var appearances: Dictionary = report.get("appearances", {}) as Dictionary
	var defense: Dictionary = report.get("defense", {}) as Dictionary
	var callups: Dictionary = report.get("callups", {}) as Dictionary
	print("")
	print("=== FARM REPORT (seed %d) ===" % int(report.get("seed", 0)))
	print("Schedule : played %d / %d (cancelled %d)" % [
		int(schedule.get("played", 0)), int(schedule.get("total", 0)), int(schedule.get("cancelled", 0)),
	])
	for reason_key in (schedule.get("cancel_reasons", {}) as Dictionary).keys():
		print("           中止 %3d件: %s" % [
			int((schedule.get("cancel_reasons", {}) as Dictionary)[reason_key]), str(reason_key),
		])
	print("Farm bat : AVG %.3f OBP %.3f SLG %.3f OPS %.3f BB%% %.3f K%% %.3f HR %d" % [
		batting.get("average", 0.0), batting.get("on_base", 0.0), batting.get("slugging", 0.0),
		batting.get("ops", 0.0), batting.get("walk_rate", 0.0), batting.get("strikeout_rate", 0.0),
		int(batting.get("home_runs", 0)),
	])
	print("1st  bat : AVG %.3f OPS %.3f BB%% %.3f K%% %.3f  (二軍が下回るのが正常)" % [
		first.get("average", 0.0), first.get("ops", 0.0),
		first.get("walk_rate", 0.0), first.get("strikeout_rate", 0.0),
	])
	print("Farm pit : ERA %.2f WHIP %.2f K/9 %.2f IP %.1f" % [
		pitching.get("era", 0.0), pitching.get("whip", 0.0),
		pitching.get("strikeouts_per_nine", 0.0), pitching.get("innings_pitched", 0.0),
	])
	var first_pitching: Dictionary = report.get("first_team_pitching", {}) as Dictionary
	print("1st  pit : ERA %.2f WHIP %.2f K/9 %.2f  (二軍が上回るのが正常)" % [
		first_pitching.get("era", 0.0), first_pitching.get("whip", 0.0),
		first_pitching.get("strikeouts_per_nine", 0.0),
	])
	var levels: Dictionary = report.get("usage_levels", {}) as Dictionary
	print("Level    : 打者 z %+.2f → %+.2f (差 %+.2f) / 投手 z %+.2f → %+.2f (差 %+.2f) / 非対称 %+.2f" % [
		levels.get("first_batter_z", 0.0), levels.get("farm_batter_z", 0.0), levels.get("batter_gap_z", 0.0),
		levels.get("first_pitcher_z", 0.0), levels.get("farm_pitcher_z", 0.0), levels.get("pitcher_gap_z", 0.0),
		levels.get("gap_asymmetry_z", 0.0),
	])
	print("Draws    : %d / %d team-games (%.1f%%)" % [
		int(standings.get("draws", 0)), int(standings.get("team_games", 0)),
		float(standings.get("draw_rate", 0.0)) * 100.0,
	])
	print("Appear   : 支配下 %d/%d (%.0f%%) / 育成 %d/%d (%.0f%%, %dPA) / 規定到達 %d人" % [
		int(appearances.get("controlled_played", 0)), int(appearances.get("controlled_total", 0)),
		float(appearances.get("controlled_rate", 0.0)) * 100.0,
		int(appearances.get("development_played", 0)), int(appearances.get("development_total", 0)),
		float(appearances.get("development_rate", 0.0)) * 100.0,
		int(appearances.get("development_plate_appearances", 0)),
		int(appearances.get("qualified_farm_batters", 0)),
	])
	print("  育成内訳 : 野手 %d/%d (%.0f%%) / 投手 %d/%d (%.0f%%)" % [
		int(appearances.get("development_batter_played", 0)), int(appearances.get("development_batter_total", 0)),
		float(appearances.get("development_batter_rate", 0.0)) * 100.0,
		int(appearances.get("development_pitcher_played", 0)), int(appearances.get("development_pitcher_total", 0)),
		float(appearances.get("development_pitcher_rate", 0.0)) * 100.0,
	])
	print("Defense  : %.1f innings / %d players (本職外 %d人)" % [
		float(defense.get("total_innings", 0.0)), int(defense.get("players_with_innings", 0)),
		int(defense.get("players_with_off_position_innings", 0)),
	])
	print("Callups  : 抹消台帳 %d / 往復した先発 %d / 未消化のスポット昇格 %d" % [
		int(callups.get("demotion_ledger_entries", 0)), int(callups.get("shuttled_starters", 0)),
		int(callups.get("pending_spot_callups", 0)),
	])
	var moves: Dictionary = report.get("roster_moves", {}) as Dictionary
	print("Moves    : 昇格 %d (%.1f/球団) / 降格 %d (%.1f/球団) / 一軍出場 %.1f人 (投手 %.1f・野手 %.1f)・先発 %.1f人/球団 / 両リーグ出場 %d人" % [
		int(moves.get("promotions", 0)), float(moves.get("promotions_per_team", 0.0)),
		int(moves.get("demotions", 0)), float(moves.get("demotions_per_team", 0.0)),
		float(moves.get("first_team_players_used_per_team", 0.0)),
		float(moves.get("first_team_pitchers_used_per_team", 0.0)),
		float(moves.get("first_team_fielders_used_per_team", 0.0)),
		float(moves.get("first_team_starters_used_per_team", 0.0)),
		int(moves.get("players_at_both_levels", 0)),
	])
	var injuries: Dictionary = report.get("injuries", {}) as Dictionary
	var severity: Dictionary = injuries.get("severity_counts", {}) as Dictionary
	print("Injury   : %d人 (%.1f/球団) / 延べ %d日 (平均 %.1f・最長 %d) / 育成 %d人・専用球団 %d人" % [
		int(injuries.get("injured_players", 0)), float(injuries.get("injured_players_per_team", 0.0)),
		int(injuries.get("injury_days_total", 0)), float(injuries.get("injury_days_mean", 0.0)),
		int(injuries.get("injury_days_max", 0)),
		int(injuries.get("development_injured", 0)), int(injuries.get("farm_club_injured", 0)),
	])
	print("  重症度 : 軽傷 %d / 中度 %d / 重傷 %d / 重大手術 %d" % [
		int(severity.get("minor", 0)), int(severity.get("moderate", 0)),
		int(severity.get("major", 0)), int(severity.get("severe", 0)),
	])
	for club_row in ((report.get("farm_clubs", {}) as Dictionary).get("rows", []) as Array):
		var club: Dictionary = club_row as Dictionary
		print("Club %d   : roster %d / appeared %d / NPB経験者 %d" % [
			int(club.get("club_id", 0)), int(club.get("roster", 0)),
			int(club.get("appeared", 0)), int(club.get("npb_experienced", 0)),
		])
	var health: Dictionary = report.get("health", {}) as Dictionary
	print("Health   : %s" % str(health.get("status", "")))
	for check_row in (health.get("checks", []) as Array):
		var check: Dictionary = check_row as Dictionary
		if str(check.get("status", "pass")) == "pass":
			continue
		var known: String = str(check.get("known_open_issue", ""))
		print("  [%s] %s = %s (%s)%s" % [
			str(check.get("status", "")), str(check.get("id", "")),
			str(check.get("value", "")), str(check.get("message", "")),
			"" if known.is_empty() else "  ← 既知: " + known,
		])


func _safe_div(numerator: float, denominator: float) -> float:
	return 0.0 if denominator <= 0.0 else numerator / denominator


func _round1(value: float) -> float:
	return round(value * 10.0) / 10.0


func _round2(value: float) -> float:
	return round(value * 100.0) / 100.0


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
