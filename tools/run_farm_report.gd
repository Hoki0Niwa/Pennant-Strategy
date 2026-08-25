extends Node

# 二軍 (ファーム) の健全性を1シーズン通しで実測するレポート。
# 二軍成績を一覧できる画面は無いので、**これが二軍を観測する唯一の手段**になる。
#
# 見るもの:
#   - 二軍リーグの成績水準 (一軍との対比。実 NPB のファームは一軍より **ERA が高い**)
#   - 引き分け率 (延長10回打ち切りの効果。実 NPB のファームは約10%)
#   - 出場分布 (何人が出たか / 育成選手が出ているか)
#   - 守備イニング (オフの守備適性成長の入力になっているか)
#   - 昇降格 (日次の active_roster 差分で実測。谷間の先発が何回発火したか / 先発の顔ぶれ)
#   - 故障件数 (控え・二軍の曝露ぶんが乗る)
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
const HEALTH_FIRST_TEAM_STARTERS_USED: Array = [12.0, 16.0]
# 故障者数/球団。曝露が控え・二軍まで広がったので一軍だけの頃より増えるのが正常。
# MLB の IL 入りは近年 30件/球団前後だが、こちらは軽傷 (3-15日) も1件と数えるので上限は広く取る。
const HEALTH_INJURED_PLAYERS_PER_TEAM: Array = [8.0, 45.0]

# 未達が判明していて一時的に warn 扱いにする項目。現在は空。
# ファーム専用球団の勝率。**実クラブの実測が基準** (ハヤテ静岡2024 .315 / オイシックス新潟2024 .358)。
# ⚠️ これは「PA モデルの能力差感度」の唯一の実測ゲート。`run_pa_response_surface` の
# 「両側 -0.8σ の Pythagorean 勝率」では代用しない — **ゲーム内の 0.8σ が実クラブの実力差と
# 等しいという根拠が無い**ため、実シーズンの実勝率で測る
# ([[project_pa_talent_sensitivity_calibration]])。
# 2球団×1シーズンでは振れるので、**3シーズン以上の平均で判断する**
# ([[project_farm_system_design]] の「2球団 × 1シーズンでは測れない」)。
const HEALTH_FARM_CLUB_WIN_RATE: Array = [0.270, 0.420]
# 実 NPB 二軍は 1球団あたり使用47人・最多93.1回 (オリックス2025) 規模。使用人数が少なく
# 1人あたりの回数が多いときは一軍との往復が成立していないので、専用球団の勝率とは別に直接測る。
const HEALTH_AFFILIATED_FARM_PITCHERS_USED: Array = [40.0, 49.0]
const HEALTH_AFFILIATED_FARM_MAX_INNINGS: Array = [80.0, 110.0]

const HEALTH_KNOWN_OPEN_ISSUES: Dictionary = {}

# 起用加重の能力水準を測るキー。**質の軸だけ**を使う (スタイル軸を混ぜると水準がぼやける)。
# **試合結果へ直接入る**打席能力だけを測る。役割判定用の Stamina/Efficiency で代用すると、
# ImpactLimit/BarrelDeny/LoftControl が低い投手を「品質は同等」と誤診するため分離する。
const BATTER_QUALITY_KEYS: Array[String] = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Barrel", "Bat_Loft",
]
const PITCHER_QUALITY_KEYS: Array[String] = [
	"Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_BarrelDeny", "Pit_LoftControl",
]


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
		"ability_distribution": _ability_distribution_summary(season),
		"appearances": _appearance_summary(season),
		"defense": _defensive_innings_summary(season),
		"farm_clubs": _farm_club_summary(season),
		"farm_pitcher_usage": _farm_pitcher_usage_summary(season),
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
			"runs_scored": stats.runs_scored,
			"runs_allowed": stats.runs_allowed,
			"run_diff": stats.runs_scored - stats.runs_allowed,
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


# 能力母集団の裾と、各球団が実際に使った主力層を分けて測る。個別能力が正規的でも、
# 複数能力の組み合わせで決まる総合値の上端には別の形が現れうる。
func _ability_distribution_summary(season: PSSeason) -> Dictionary:
	var npb_fielder_overall: Array = []
	var npb_pitcher_overall: Array = []
	var npb_fielder_quality: Array = []
	var npb_pitcher_quality: Array = []
	var team_buckets: Dictionary = {}
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		var team_id: int = record.team_id
		if team_id <= 0:
			continue
		if not team_buckets.has(team_id):
			team_buckets[team_id] = {
				"fielders": [], "pitchers": [],
				"fielder_usage": [0.0, 0.0], "pitcher_usage": [0.0, 0.0],
				"fielder_quality_usage": [0.0, 0.0],
				"pitcher_quality_usage": [0.0, 0.0],
			}
		var bucket: Dictionary = team_buckets[team_id] as Dictionary
		var overall: float = float(PSPlayerValueEvaluator.overall_score(record))
		if record.is_pitcher():
			(bucket["pitchers"] as Array).append(overall)
			var pitcher_weight: float = float(record.farm_pitcher_stats.outs_pitched)
			_accumulate_level(
				bucket["pitcher_usage"] as Array, overall, pitcher_weight
			)
			_accumulate_level(
				bucket["pitcher_quality_usage"] as Array,
				_mean_z(record, PITCHER_QUALITY_KEYS), pitcher_weight
			)
			if not PSFarmLeague.is_farm_club_id(team_id):
				npb_pitcher_overall.append(overall)
				npb_pitcher_quality.append(_mean_z(record, PITCHER_QUALITY_KEYS))
		else:
			(bucket["fielders"] as Array).append(overall)
			var fielder_weight: float = float(record.farm_batter_stats.plate_appearances)
			_accumulate_level(
				bucket["fielder_usage"] as Array, overall, fielder_weight
			)
			_accumulate_level(
				bucket["fielder_quality_usage"] as Array,
				_mean_z(record, BATTER_QUALITY_KEYS), fielder_weight
			)
			if not PSFarmLeague.is_farm_club_id(team_id):
				npb_fielder_overall.append(overall)
				npb_fielder_quality.append(_mean_z(record, BATTER_QUALITY_KEYS))

	var rows: Array = []
	var affiliated_fielder_core: Array = []
	var affiliated_pitcher_core: Array = []
	var affiliated_fielder_used: Array = []
	var affiliated_pitcher_used: Array = []
	var dedicated_fielder_core: Array = []
	var dedicated_pitcher_core: Array = []
	var dedicated_fielder_used: Array = []
	var dedicated_pitcher_used: Array = []
	var affiliated_fielder_quality_used: Array = []
	var affiliated_pitcher_quality_used: Array = []
	var dedicated_fielder_quality_used: Array = []
	var dedicated_pitcher_quality_used: Array = []
	var team_ids: Array = team_buckets.keys()
	team_ids.sort()
	for team_id_value in team_ids:
		var team_id: int = int(team_id_value)
		var bucket: Dictionary = team_buckets[team_id] as Dictionary
		var fielders: Array = bucket["fielders"] as Array
		var pitchers: Array = bucket["pitchers"] as Array
		var fielder_core: float = _top_mean(fielders, 9)
		var pitcher_core: float = _top_mean(pitchers, 6)
		var fielder_used: float = _weighted_mean(bucket["fielder_usage"] as Array)
		var pitcher_used: float = _weighted_mean(bucket["pitcher_usage"] as Array)
		var fielder_quality_used: float = _weighted_mean(bucket["fielder_quality_usage"] as Array)
		var pitcher_quality_used: float = _weighted_mean(bucket["pitcher_quality_usage"] as Array)
		var dedicated: bool = PSFarmLeague.is_farm_club_id(team_id)
		rows.append({
			"team_id": team_id,
			"farm_club": dedicated,
			"fielder_count": fielders.size(),
			"pitcher_count": pitchers.size(),
			"fielder_p50": _round2(_percentile(fielders, 0.50)),
			"fielder_p90": _round2(_percentile(fielders, 0.90)),
			"pitcher_p50": _round2(_percentile(pitchers, 0.50)),
			"pitcher_p90": _round2(_percentile(pitchers, 0.90)),
			"fielder_top9_mean": _round2(fielder_core),
			"pitcher_top6_mean": _round2(pitcher_core),
			"fielder_farm_usage_weighted": _round2(fielder_used),
			"pitcher_farm_usage_weighted": _round2(pitcher_used),
			"fielder_farm_quality_weighted_z": _round3(fielder_quality_used),
			"pitcher_farm_quality_weighted_z": _round3(pitcher_quality_used),
		})
		if dedicated:
			dedicated_fielder_core.append(fielder_core)
			dedicated_pitcher_core.append(pitcher_core)
			dedicated_fielder_used.append(fielder_used)
			dedicated_pitcher_used.append(pitcher_used)
			dedicated_fielder_quality_used.append(fielder_quality_used)
			dedicated_pitcher_quality_used.append(pitcher_quality_used)
		else:
			affiliated_fielder_core.append(fielder_core)
			affiliated_pitcher_core.append(pitcher_core)
			affiliated_fielder_used.append(fielder_used)
			affiliated_pitcher_used.append(pitcher_used)
			affiliated_fielder_quality_used.append(fielder_quality_used)
			affiliated_pitcher_quality_used.append(pitcher_quality_used)

	var comparison: Dictionary = {
		"affiliated_fielder_top9_mean": _round2(_mean_values(affiliated_fielder_core)),
		"dedicated_fielder_top9_mean": _round2(_mean_values(dedicated_fielder_core)),
		"affiliated_pitcher_top6_mean": _round2(_mean_values(affiliated_pitcher_core)),
		"dedicated_pitcher_top6_mean": _round2(_mean_values(dedicated_pitcher_core)),
		"affiliated_fielder_usage_weighted": _round2(_mean_values(affiliated_fielder_used)),
		"dedicated_fielder_usage_weighted": _round2(_mean_values(dedicated_fielder_used)),
		"affiliated_pitcher_usage_weighted": _round2(_mean_values(affiliated_pitcher_used)),
		"dedicated_pitcher_usage_weighted": _round2(_mean_values(dedicated_pitcher_used)),
		"affiliated_fielder_quality_weighted_z": _round3(_mean_values(affiliated_fielder_quality_used)),
		"dedicated_fielder_quality_weighted_z": _round3(_mean_values(dedicated_fielder_quality_used)),
		"affiliated_pitcher_quality_weighted_z": _round3(_mean_values(affiliated_pitcher_quality_used)),
		"dedicated_pitcher_quality_weighted_z": _round3(_mean_values(dedicated_pitcher_quality_used)),
	}
	comparison["fielder_core_gap"] = _round2(
		float(comparison["dedicated_fielder_top9_mean"]) - float(comparison["affiliated_fielder_top9_mean"])
	)
	comparison["pitcher_core_gap"] = _round2(
		float(comparison["dedicated_pitcher_top6_mean"]) - float(comparison["affiliated_pitcher_top6_mean"])
	)
	comparison["fielder_usage_gap"] = _round2(
		float(comparison["dedicated_fielder_usage_weighted"]) - float(comparison["affiliated_fielder_usage_weighted"])
	)
	comparison["pitcher_usage_gap"] = _round2(
		float(comparison["dedicated_pitcher_usage_weighted"]) - float(comparison["affiliated_pitcher_usage_weighted"])
	)
	comparison["fielder_quality_usage_gap_z"] = _round3(
		float(comparison["dedicated_fielder_quality_weighted_z"])
			- float(comparison["affiliated_fielder_quality_weighted_z"])
	)
	comparison["pitcher_quality_usage_gap_z"] = _round3(
		float(comparison["dedicated_pitcher_quality_weighted_z"])
			- float(comparison["affiliated_pitcher_quality_weighted_z"])
	)
	return {
		"npb_population": {
			"fielder_overall": _distribution_shape(npb_fielder_overall),
			"pitcher_overall": _distribution_shape(npb_pitcher_overall),
			"fielder_quality_z": _distribution_shape(npb_fielder_quality),
			"pitcher_quality_z": _distribution_shape(npb_pitcher_quality),
		},
		"teams": rows,
		"comparison": comparison,
	}


func _distribution_shape(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var mean: float = _mean_values(values)
	var variance: float = 0.0
	for value in values:
		var delta: float = float(value) - mean
		variance += delta * delta
	variance /= float(values.size())
	var spread: float = sqrt(variance)
	var skewness: float = 0.0
	var excess_kurtosis: float = 0.0
	var above_three_sigma: int = 0
	if spread > 0.0:
		for value in values:
			var standardized: float = (float(value) - mean) / spread
			skewness += pow(standardized, 3.0)
			excess_kurtosis += pow(standardized, 4.0)
			if standardized > 3.0:
				above_three_sigma += 1
		skewness /= float(values.size())
		excess_kurtosis = excess_kurtosis / float(values.size()) - 3.0
	var p95: float = _percentile(values, 0.95)
	var p99: float = _percentile(values, 0.99)
	var maximum: float = _percentile(values, 1.0)
	var normal_p99: float = mean + spread * 2.32635
	return {
		"count": values.size(),
		"mean": _round3(mean),
		"stdev": _round3(spread),
		"skewness": _round3(skewness),
		"excess_kurtosis": _round3(excess_kurtosis),
		"p50": _round3(_percentile(values, 0.50)),
		"p90": _round3(_percentile(values, 0.90)),
		"p95": _round3(p95),
		"p99": _round3(p99),
		"max": _round3(maximum),
		"normal_expected_p99": _round3(normal_p99),
		"p99_minus_normal": _round3(p99 - normal_p99),
		"max_sigma": _round3(_safe_div(maximum - mean, spread)),
		"above_3sigma_count": above_three_sigma,
	}


func _percentile(values: Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var position: float = clampf(percentile, 0.0, 1.0) * float(sorted.size() - 1)
	var lower: int = floori(position)
	var upper: int = ceili(position)
	if lower == upper:
		return float(sorted[lower])
	return lerpf(float(sorted[lower]), float(sorted[upper]), position - float(lower))


func _top_mean(values: Array, count: int) -> float:
	if values.is_empty() or count <= 0:
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var take: int = mini(count, sorted.size())
	var total: float = 0.0
	for i in range(take):
		total += float(sorted[sorted.size() - 1 - i])
	return total / float(take)


# 一軍の顔ぶれがどれだけ動いたか。NPB は登録・抹消の往復で年間 55〜65人が一軍出場する。
# 一軍と二軍の往復が機能しているかをこの人数で見る。
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


# 故障件数。控え・二軍は二軍戦でのみ曝露するので、その分がリーグ全体の件数に乗る
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


# 誰が二軍戦に出たか。**育成選手の出場機会は二軍戦だけ**なので、支配下と分けて出す。
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
	var win_rate_sum: float = 0.0
	var win_rate_count: int = 0
	for club_id_value in PSFarmLeague.farm_club_ids():
		var club_id: int = int(club_id_value)
		var roster: int = 0
		var appeared: int = 0
		var npb_experienced: int = 0
		var batting: PSBatterStats = PSBatterStats.new()
		var pitching: PSPitcherStats = PSPitcherStats.new()
		for record_row in RecordStore.get_team_player_records(club_id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			roster += 1
			batting.add_from(record.farm_batter_stats)
			pitching.add_from(record.farm_pitcher_stats)
			if record.farm_batter_stats.plate_appearances > 0 or record.farm_pitcher_stats.batters_faced > 0:
				appeared += 1
			if bool(record.source_data.get("npb_experienced", false)):
				npb_experienced += 1
		var stats: PSStats = season.farm_standings.get(club_id, null) as PSStats
		var decided: int = 0 if stats == null else stats.wins + stats.losses
		var games: int = decided if stats == null else decided + stats.draws
		var win_rate: float = 0.0 if decided == 0 else float(stats.wins) / float(decided)
		if decided > 0:
			win_rate_sum += win_rate
			win_rate_count += 1
		rows.append({
			"club_id": club_id,
			"roster": roster,
			"appeared": appeared,
			"npb_experienced": npb_experienced,
			"wins": 0 if stats == null else stats.wins,
			"losses": 0 if stats == null else stats.losses,
			"draws": 0 if stats == null else stats.draws,
			"win_rate": _round3(win_rate),
			"runs_scored": 0 if stats == null else stats.runs_scored,
			"runs_allowed": 0 if stats == null else stats.runs_allowed,
			"runs_scored_per_game": _round3(_safe_div(float(0 if stats == null else stats.runs_scored), float(games))),
			"runs_allowed_per_game": _round3(_safe_div(float(0 if stats == null else stats.runs_allowed), float(games))),
			"batting_average": _round3(batting.batting_average()),
			"ops": _round3(batting.ops()),
			"era": _round3(_safe_div(float(pitching.earned_runs) * 27.0, float(pitching.outs_pitched))),
		})
	return {
		"rows": rows,
		# 専用球団の平均勝率。感度較正の主ゲート (実クラブ .315 / .358 が基準)。
		"mean_win_rate": _round3(0.0 if win_rate_count == 0 else win_rate_sum / float(win_rate_count)),
	}


# 球団ごとの二軍使用投手数と最多投球回。一軍傘下12球団と専用球団は構造が違うため、
# 判定に使う集計は affiliated に限定し、専用球団は観測値としてだけ残す。
func _farm_pitcher_usage_summary(season: PSSeason) -> Dictionary:
	var rows: Array = []
	var affiliated_used: Array = []
	var affiliated_max_innings: Array = []
	var affiliated_fifty_innings: Array = []
	var affiliated_top_six_share: Array = []
	var team_ids: Array = []
	for team_row in GameDb.teams:
		team_ids.append((team_row as PSTeam).id)
	team_ids.append_array(PSFarmLeague.farm_club_ids())
	for team_id_value in team_ids:
		var team_id: int = int(team_id_value)
		var roster_pitchers: int = 0
		var used_pitchers: int = 0
		var max_outs: int = 0
		var max_pitcher_id: int = 0
		var max_pitcher_games: int = 0
		var max_pitcher_starts: int = 0
		var max_pitcher_role: String = ""
		var pitcher_outs: Array = []
		for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not record.is_pitcher():
				continue
			roster_pitchers += 1
			if record.farm_pitcher_stats.games <= 0:
				continue
			used_pitchers += 1
			if record.farm_pitcher_stats.outs_pitched > max_outs:
				max_outs = record.farm_pitcher_stats.outs_pitched
				max_pitcher_id = record.player_id
				max_pitcher_games = record.farm_pitcher_stats.games
				max_pitcher_starts = record.farm_pitcher_stats.starts
				max_pitcher_role = record.role
			pitcher_outs.append(float(record.farm_pitcher_stats.outs_pitched))
		var farm_club: bool = PSFarmLeague.is_farm_club_id(team_id)
		var max_innings: float = float(max_outs) / 3.0
		pitcher_outs.sort_custom(func(a, b) -> bool: return float(a) > float(b))
		var fifty_innings: int = 0
		var total_outs: float = 0.0
		var top_six_outs: float = 0.0
		for index in range(pitcher_outs.size()):
			var outs: float = float(pitcher_outs[index])
			total_outs += outs
			if outs >= 150.0:
				fifty_innings += 1
			if index < 6:
				top_six_outs += outs
		var top_six_share: float = _safe_div(top_six_outs, total_outs)
		rows.append({
			"team_id": team_id,
			"farm_club": farm_club,
			"roster_pitchers": roster_pitchers,
			"used_pitchers": used_pitchers,
			"max_innings": _round1(max_innings),
			"max_pitcher_id": max_pitcher_id,
			"max_pitcher_games": max_pitcher_games,
			"max_pitcher_starts": max_pitcher_starts,
			"max_pitcher_role": max_pitcher_role,
			"pitchers_at_least_50_innings": fifty_innings,
			"top_six_innings_share": _round3(top_six_share),
		})
		if not farm_club:
			affiliated_used.append(float(used_pitchers))
			affiliated_max_innings.append(max_innings)
			affiliated_fifty_innings.append(float(fifty_innings))
			affiliated_top_six_share.append(top_six_share)
	return {
		"rows": rows,
		"affiliated_team_count": affiliated_used.size(),
		"affiliated_mean_used_pitchers": _round1(_mean_values(affiliated_used)),
		"affiliated_min_used_pitchers": int(_min_value(affiliated_used)),
		"affiliated_max_used_pitchers": int(_max_value(affiliated_used)),
		"affiliated_mean_max_innings": _round1(_mean_values(affiliated_max_innings)),
		"affiliated_min_max_innings": _round1(_min_value(affiliated_max_innings)),
		"affiliated_max_max_innings": _round1(_max_value(affiliated_max_innings)),
		"affiliated_mean_pitchers_at_least_50_innings": _round1(_mean_values(affiliated_fifty_innings)),
		"affiliated_mean_top_six_innings_share": _round3(_mean_values(affiliated_top_six_share)),
	}


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
	var club_win_rates: Array = []
	var used_pitchers: Array = []
	var max_innings: Array = []
	var first_team_players_used: Array = []
	var first_team_starters_used: Array = []
	var fielder_core_gaps: Array = []
	var pitcher_core_gaps: Array = []
	var fielder_usage_gaps: Array = []
	var pitcher_usage_gaps: Array = []
	var fielder_quality_usage_gaps: Array = []
	var pitcher_quality_usage_gaps: Array = []
	var full_season_count: int = 0
	for season_value in seasons_out:
		var season_report: Dictionary = season_value as Dictionary
		var schedule: Dictionary = season_report.get("schedule", {}) as Dictionary
		if int(schedule.get("played", 0)) + int(schedule.get("cancelled", 0)) >= int(schedule.get("total", 0)):
			full_season_count += 1
		club_win_rates.append(float((season_report.get("farm_clubs", {}) as Dictionary).get("mean_win_rate", 0.0)))
		var usage: Dictionary = season_report.get("farm_pitcher_usage", {}) as Dictionary
		used_pitchers.append(float(usage.get("affiliated_mean_used_pitchers", 0.0)))
		max_innings.append(float(usage.get("affiliated_mean_max_innings", 0.0)))
		var roster_moves: Dictionary = season_report.get("roster_moves", {}) as Dictionary
		first_team_players_used.append(float(roster_moves.get("first_team_players_used_per_team", 0.0)))
		first_team_starters_used.append(float(roster_moves.get("first_team_starters_used_per_team", 0.0)))
		var ability: Dictionary = season_report.get("ability_distribution", {}) as Dictionary
		var comparison: Dictionary = ability.get("comparison", {}) as Dictionary
		fielder_core_gaps.append(float(comparison.get("fielder_core_gap", 0.0)))
		pitcher_core_gaps.append(float(comparison.get("pitcher_core_gap", 0.0)))
		fielder_usage_gaps.append(float(comparison.get("fielder_usage_gap", 0.0)))
		pitcher_usage_gaps.append(float(comparison.get("pitcher_usage_gap", 0.0)))
		fielder_quality_usage_gaps.append(float(comparison.get("fielder_quality_usage_gap_z", 0.0)))
		pitcher_quality_usage_gaps.append(float(comparison.get("pitcher_quality_usage_gap_z", 0.0)))
	return {
		"per_season": seasons_out,
		"farm_clubs": {
			"mean_win_rate": _round3(_mean_values(club_win_rates)),
			"season_count": club_win_rates.size(),
		},
		"farm_pitcher_usage": {
			"affiliated_mean_used_pitchers": _round1(_mean_values(used_pitchers)),
			"affiliated_mean_max_innings": _round1(_mean_values(max_innings)),
			"season_count": used_pitchers.size(),
		},
		"full_season_count": full_season_count,
		"roster_moves": {
			"first_team_players_used_per_team": _round1(_mean_values(first_team_players_used)),
			"first_team_starters_used_per_team": _round1(_mean_values(first_team_starters_used)),
			"season_count": first_team_players_used.size(),
		},
		"ability_distribution": {
			"npb_population": ((seasons_out[0] as Dictionary).get("ability_distribution", {}) as Dictionary).get("npb_population", {}),
			"comparison": {
				"fielder_core_gap": _round2(_mean_values(fielder_core_gaps)),
				"pitcher_core_gap": _round2(_mean_values(pitcher_core_gaps)),
				"fielder_usage_gap": _round2(_mean_values(fielder_usage_gaps)),
				"pitcher_usage_gap": _round2(_mean_values(pitcher_usage_gaps)),
				"fielder_quality_usage_gap_z": _round3(_mean_values(fielder_quality_usage_gaps)),
				"pitcher_quality_usage_gap_z": _round3(_mean_values(pitcher_quality_usage_gaps)),
			},
		},
	}


func _health(report: Dictionary) -> Dictionary:
	var checks: Array = []
	# 専用球団の勝率は2球団×1季では振れすぎるため、複数季の平均を正式ゲートにする
	# (単季の値は参考表示にとどめ、判定には使わない)。
	if report.has("per_season"):
		var multi_clubs: Dictionary = report.get("farm_clubs", {}) as Dictionary
		var multi_usage: Dictionary = report.get("farm_pitcher_usage", {}) as Dictionary
		var season_count: int = (report.get("per_season", []) as Array).size()
		var multi_roster_moves: Dictionary = report.get("roster_moves", {}) as Dictionary
		if season_count >= 3:
			_add_range_check(checks, "farm_club_win_rate", float(multi_clubs.get("mean_win_rate", 0.0)), HEALTH_FARM_CLUB_WIN_RATE, "ファーム専用球団の3シーズン以上の平均勝率")
		else:
			_add_skipped_check_with_reason(checks, "farm_club_win_rate", "ファーム専用球団の平均勝率", "3シーズン以上で評価する項目")
		if int(report.get("full_season_count", 0)) == season_count:
			_add_range_check(checks, "affiliated_farm_pitchers_used", float(multi_usage.get("affiliated_mean_used_pitchers", 0.0)), HEALTH_AFFILIATED_FARM_PITCHERS_USED, "12球団二軍の使用投手数/球団 (複数季平均)")
			_add_range_check(checks, "affiliated_farm_max_innings", float(multi_usage.get("affiliated_mean_max_innings", 0.0)), HEALTH_AFFILIATED_FARM_MAX_INNINGS, "12球団二軍の球団内最多投球回 (複数季平均)")
			_add_range_check(checks, "first_team_players_used_per_team", float(multi_roster_moves.get("first_team_players_used_per_team", 0.0)), HEALTH_FIRST_TEAM_PLAYERS_USED, "一軍で1試合以上出場した選手数/球団 (複数季平均)")
			_add_range_check(checks, "first_team_starters_used_per_team", float(multi_roster_moves.get("first_team_starters_used_per_team", 0.0)), HEALTH_FIRST_TEAM_STARTERS_USED, "一軍で先発した投手数/球団 (複数季平均)")
		else:
			_add_skipped_check(checks, "affiliated_farm_pitchers_used", "12球団二軍の使用投手数/球団")
			_add_skipped_check(checks, "affiliated_farm_max_innings", "12球団二軍の球団内最多投球回")
			_add_skipped_check(checks, "first_team_players_used_per_team", "一軍で1試合以上出場した選手数/球団")
			_add_skipped_check(checks, "first_team_starters_used_per_team", "一軍で先発した投手数/球団")
		return {"status": _health_status(checks), "checks": checks}

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
	var farm_pitcher_usage: Dictionary = report.get("farm_pitcher_usage", {}) as Dictionary

	_add_range_check(checks, "farm_batting_average", float(batting.get("average", 0.0)), HEALTH_FARM_AVG, "二軍リーグの打率")
	_add_range_check(checks, "farm_walk_rate", float(batting.get("walk_rate", 0.0)), HEALTH_FARM_WALK_RATE, "二軍リーグの BB% (実 NPB ファームは9〜10%)")
	_add_range_check(checks, "farm_strikeout_rate", float(batting.get("strikeout_rate", 0.0)), HEALTH_FARM_STRIKEOUT_RATE, "二軍リーグの K%")
	_add_range_check(checks, "farm_draw_rate", float(standings.get("draw_rate", 0.0)), HEALTH_FARM_DRAW_RATE, "引き分け率 (延長10回打ち切り。実 NPB は約10%)")
	_add_max_check(checks, "farm_cancelled_games", float(schedule.get("cancelled", 0)), float(HEALTH_CANCELLED_MAX), "人数不足で組めなかった二軍戦")
	_add_min_check(checks, "development_appearance_rate", float(appearances.get("development_rate", 0.0)), HEALTH_DEVELOPMENT_APPEARANCE_MIN, "育成選手の二軍出場率 (二軍戦を作った目的の一つ)")
	_add_min_check(checks, "farm_defensive_innings", float(defense.get("total_innings", 0.0)), 1.0, "二軍の守備イニング (守備適性成長の入力)")

	_add_range_check(checks, "farm_era", float(farm_pitching.get("era", 0.0)), HEALTH_FARM_ERA, "二軍リーグの防御率 (実 NPB ファームは3.2〜3.7)")
	# **能力差感度の主ゲート**。低い = 能力差が勝敗へ効きすぎている。
	_add_skipped_check_with_reason(checks, "farm_club_win_rate", "ファーム専用球団の平均勝率", "3シーズン以上で評価する項目")
	# 顔ぶれと故障は**通季でしか意味を持たない累積量**なので、`--days=N` の短縮実行では
	# 判定せず skipped にする (でないと短い確認実行が必ず fail して exit code が使えなくなる)。
	var full_season: bool = int(schedule.get("played", 0)) + int(schedule.get("cancelled", 0)) >= int(schedule.get("total", 0))
	if full_season:
		_add_range_check(checks, "affiliated_farm_pitchers_used", float(farm_pitcher_usage.get("affiliated_mean_used_pitchers", 0.0)), HEALTH_AFFILIATED_FARM_PITCHERS_USED, "12球団二軍の使用投手数/球団")
		_add_range_check(checks, "affiliated_farm_max_innings", float(farm_pitcher_usage.get("affiliated_mean_max_innings", 0.0)), HEALTH_AFFILIATED_FARM_MAX_INNINGS, "12球団二軍の球団内最多投球回")
		_add_range_check(checks, "first_team_players_used_per_team", float(roster_moves.get("first_team_players_used_per_team", 0.0)), HEALTH_FIRST_TEAM_PLAYERS_USED, "一軍で1試合以上出場した選手数/球団 (NPB 55〜65人)")
		_add_range_check(checks, "first_team_starters_used_per_team", float(roster_moves.get("first_team_starters_used_per_team", 0.0)), HEALTH_FIRST_TEAM_STARTERS_USED, "一軍で先発した投手数/球団 (NPB 12〜16人)")
		_add_range_check(checks, "injured_players_per_team", float(injuries.get("injured_players_per_team", 0.0)), HEALTH_INJURED_PLAYERS_PER_TEAM, "故障者数/球団 (二軍戦のぶん曝露が増えている)")
	else:
		_add_skipped_check(checks, "affiliated_farm_pitchers_used", "12球団二軍の使用投手数/球団")
		_add_skipped_check(checks, "affiliated_farm_max_innings", "12球団二軍の球団内最多投球回")
		_add_skipped_check(checks, "first_team_players_used_per_team", "一軍で1試合以上出場した選手数/球団")
		_add_skipped_check(checks, "first_team_starters_used_per_team", "一軍で先発した投手数/球団")
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

	# 実 NPB のファームは一軍より ERA が **高い** (投手と守備が劣るぶん)。逆転していれば
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

	return {"status": _health_status(checks), "checks": checks}


func _health_status(checks: Array) -> String:
	var status: String = "pass"
	for check_row in checks:
		var check_status: String = str((check_row as Dictionary).get("status", "pass"))
		if check_status == "fail":
			status = "fail"
		elif check_status == "warn" and status == "pass":
			status = "warn"
	return status


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


func _add_skipped_check_with_reason(checks: Array, id: String, message: String, reason: String) -> void:
	checks.append({"id": id, "message": message, "status": "skipped", "reason": reason})


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
		var multi_clubs: Dictionary = report.get("farm_clubs", {}) as Dictionary
		var multi_usage: Dictionary = report.get("farm_pitcher_usage", {}) as Dictionary
		var multi_moves: Dictionary = report.get("roster_moves", {}) as Dictionary
		print("FARM REPORT: %d seasons / clubs %.3f / affiliated pitchers %.1f / max IP %.1f / first used %.1f / starters %.1f / health %s" % [
			(report["per_season"] as Array).size(), float(multi_clubs.get("mean_win_rate", 0.0)),
			float(multi_usage.get("affiliated_mean_used_pitchers", 0.0)),
			float(multi_usage.get("affiliated_mean_max_innings", 0.0)),
			float(multi_moves.get("first_team_players_used_per_team", 0.0)),
			float(multi_moves.get("first_team_starters_used_per_team", 0.0)),
			str((report.get("health", {}) as Dictionary).get("status", "")),
		])
		return
	var batting: Dictionary = report.get("farm_batting", {}) as Dictionary
	var first: Dictionary = report.get("first_team_batting", {}) as Dictionary
	var pitching: Dictionary = report.get("farm_pitching", {}) as Dictionary
	var standings: Dictionary = report.get("standings", {}) as Dictionary
	var schedule: Dictionary = report.get("schedule", {}) as Dictionary
	var appearances: Dictionary = report.get("appearances", {}) as Dictionary
	var defense: Dictionary = report.get("defense", {}) as Dictionary
	var callups: Dictionary = report.get("callups", {}) as Dictionary
	var pitcher_usage: Dictionary = report.get("farm_pitcher_usage", {}) as Dictionary
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
	print("Farm use : 12球団 使用投手 %.1f人 (範囲 %d〜%d) / 最多IP平均 %.1f (範囲 %.1f〜%.1f)" % [
		float(pitcher_usage.get("affiliated_mean_used_pitchers", 0.0)),
		int(pitcher_usage.get("affiliated_min_used_pitchers", 0)), int(pitcher_usage.get("affiliated_max_used_pitchers", 0)),
		float(pitcher_usage.get("affiliated_mean_max_innings", 0.0)),
		float(pitcher_usage.get("affiliated_min_max_innings", 0.0)), float(pitcher_usage.get("affiliated_max_max_innings", 0.0)),
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


func _mean_values(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _min_value(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = float(values[0])
	for value in values:
		result = min(result, float(value))
	return result


func _max_value(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = float(values[0])
	for value in values:
		result = max(result, float(value))
	return result


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
