extends RefCounted
class_name AwardsService

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const QUALIFIER_PA_PER_GAME: float = 3.1
const QUALIFIER_OUTS_PER_GAME: float = 3.0
const COUNTING_TITLE_MIN_PA: int = 50
const PITCHER_EXCLUDE_PA: int = 30
const WIN_RATE_MIN_DECISIONS: int = 8


static func calculate(season: PSSeason, teams: Array) -> PSAwards:
	var awards: PSAwards = PSAwards.new()
	awards.year = season.year
	awards.season_number = season.season_number

	var team_by_id: Dictionary = {}
	var team_ids_by_league: Dictionary = {"central": [], "pacific": []}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			team_by_id[team.id] = team
			if team_ids_by_league.has(team.league):
				(team_ids_by_league[team.league] as Array).append(team.id)

	var by_league: Dictionary = {"central": [], "pacific": []}
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if record.team_id <= 0:
			continue
		var team: PSTeam = team_by_id.get(record.team_id, null) as PSTeam
		if team == null:
			continue
		if not by_league.has(team.league):
			continue
		by_league[team.league].append(record)

	var max_games: int = 0
	for stats_team_id in season.standings.keys():
		var stats: PSStats = season.standings[stats_team_id] as PSStats
		if stats.games > max_games:
			max_games = stats.games

	var qualifier_pa: int = int(max(1.0, ceil(QUALIFIER_PA_PER_GAME * float(max_games))))
	var qualifier_outs: int = int(max(1.0, ceil(QUALIFIER_OUTS_PER_GAME * float(max_games))))

	for league_key in by_league.keys():
		var league_records: Array = by_league[league_key] as Array
		var team_ids: Array = team_ids_by_league.get(league_key, []) as Array
		var batting_titles: Dictionary = _calculate_batting_titles(league_records, team_ids, season.year, season.season_number, qualifier_pa)
		var pitching_titles: Dictionary = _calculate_pitching_titles(league_records, team_ids, season.year, season.season_number, qualifier_outs)
		awards.batting_titles[league_key] = batting_titles
		awards.pitching_titles[league_key] = pitching_titles

		# MVP / Rookie はクロステーブル + スコア計算が必要なのでメモリループ継続。
		# 1 リーグあたり最大 ~150 records なのでパフォーマンス上の懸念は無い。
		# WAR ベース選出: リーグ実測から WAR context を 1 度作って使い回す。
		var war_ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
		var mvp_id: int = _pick_mvp(league_records, qualifier_pa, qualifier_outs, war_ctx)
		var rookie_id: int = _pick_rookie(league_records, war_ctx)
		if league_key == "central":
			awards.mvp_central_player_id = mvp_id
			awards.rookie_central_player_id = rookie_id
		else:
			awards.mvp_pacific_player_id = mvp_id
			awards.rookie_pacific_player_id = rookie_id

	return awards


# 打撃タイトル算出: team_ids 指定時は SQL ORDER BY DESC LIMIT 1、未指定時はメモリループ。
static func _calculate_batting_titles(records: Array, team_ids: Array, year: int, season_number: int, qualifier_pa: int) -> Dictionary:
	if not team_ids.is_empty():
		return {
			"average": SQLiteStoreService.query_batter_average_leader(year, season_number, team_ids, qualifier_pa),
			"home_runs": SQLiteStoreService.query_batter_title_leader(
				year, season_number, team_ids, "home_runs", 0, PITCHER_EXCLUDE_PA, 0
			),
			"rbi": SQLiteStoreService.query_batter_title_leader(
				year, season_number, team_ids, "runs_batted_in", 0, PITCHER_EXCLUDE_PA, 0
			),
			"stolen_bases": SQLiteStoreService.query_batter_title_leader(
				year, season_number, team_ids, "stolen_bases", 0, PITCHER_EXCLUDE_PA, 0
			),
			"hits": SQLiteStoreService.query_batter_title_leader(
				year, season_number, team_ids, "hits", 0, PITCHER_EXCLUDE_PA, 0
			),
		}
	return _calculate_batting_titles_memory(records, qualifier_pa)


# 投手タイトル算出: 同上。
static func _calculate_pitching_titles(records: Array, team_ids: Array, year: int, season_number: int, qualifier_outs: int) -> Dictionary:
	if not team_ids.is_empty():
		return {
			"wins": SQLiteStoreService.query_pitcher_title_leader(
				year, season_number, team_ids, "wins", 0, false
			),
			"era": SQLiteStoreService.query_pitcher_era_leader(year, season_number, team_ids, qualifier_outs),
			"strikeouts": SQLiteStoreService.query_pitcher_title_leader(
				year, season_number, team_ids, "strikeouts", 0, false
			),
			"saves": SQLiteStoreService.query_pitcher_title_leader(
				year, season_number, team_ids, "saves", 0, false
			),
			"holds": SQLiteStoreService.query_pitcher_title_leader(
				year, season_number, team_ids, "holds", 0, false
			),
			"win_rate": SQLiteStoreService.query_pitcher_win_rate_leader(
				year, season_number, team_ids, qualifier_outs, WIN_RATE_MIN_DECISIONS
			),
		}
	return _calculate_pitching_titles_memory(records, qualifier_outs)


# メモリループ版打撃タイトル算出 (team_ids 未指定時のフォールバック)。
static func _calculate_batting_titles_memory(records: Array, qualifier_pa: int) -> Dictionary:
	var titles: Dictionary = {"average": 0, "home_runs": 0, "rbi": 0, "stolen_bases": 0, "hits": 0}

	var best_avg_pid: int = 0
	var best_avg_value: float = -1.0
	var best_hr_pid: int = 0
	var best_hr_value: int = -1
	var best_rbi_pid: int = 0
	var best_rbi_value: int = -1
	var best_sb_pid: int = 0
	var best_sb_value: int = -1
	var best_hits_pid: int = 0
	var best_hits_value: int = -1

	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher() and record.batter_stats.plate_appearances < 30:
			continue
		var bs: PSBatterStats = record.batter_stats
		# 規定打席タイトル(打率)
		if bs.plate_appearances >= qualifier_pa and bs.at_bats > 0:
			var avg: float = bs.batting_average()
			if avg > best_avg_value:
				best_avg_value = avg
				best_avg_pid = record.player_id
		# カウンティングタイトル(打席数下限のみ)
		if bs.plate_appearances >= 50:
			if bs.home_runs > best_hr_value:
				best_hr_value = bs.home_runs
				best_hr_pid = record.player_id
			if bs.runs_batted_in > best_rbi_value:
				best_rbi_value = bs.runs_batted_in
				best_rbi_pid = record.player_id
			if bs.stolen_bases > best_sb_value:
				best_sb_value = bs.stolen_bases
				best_sb_pid = record.player_id
			if bs.hits > best_hits_value:
				best_hits_value = bs.hits
				best_hits_pid = record.player_id

	titles["average"] = best_avg_pid
	titles["home_runs"] = best_hr_pid
	titles["rbi"] = best_rbi_pid
	titles["stolen_bases"] = best_sb_pid
	titles["hits"] = best_hits_pid
	return titles


static func _calculate_pitching_titles_memory(records: Array, qualifier_outs: int) -> Dictionary:
	var titles: Dictionary = {"wins": 0, "era": 0, "strikeouts": 0, "saves": 0, "holds": 0, "win_rate": 0}

	var best_wins_pid: int = 0
	var best_wins_value: int = -1
	var best_era_pid: int = 0
	var best_era_value: float = 999.99
	var best_k_pid: int = 0
	var best_k_value: int = -1
	var best_saves_pid: int = 0
	var best_saves_value: int = -1
	var best_holds_pid: int = 0
	var best_holds_value: int = -1
	var best_wr_pid: int = 0
	var best_wr_value: float = -1.0

	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher():
			continue
		var ps: PSPitcherStats = record.pitcher_stats
		if ps.games <= 0:
			continue
		# 規定投球回タイトル
		if ps.outs_pitched >= qualifier_outs:
			var era: float = ps.era()
			if era < best_era_value:
				best_era_value = era
				best_era_pid = record.player_id
			# 勝率(13勝以上が日本では条件だが緩めに 8勝以上)
			if ps.wins + ps.losses >= 8:
				var decisions: int = ps.wins + ps.losses
				var wr: float = float(ps.wins) / float(decisions) if decisions > 0 else 0.0
				if wr > best_wr_value:
					best_wr_value = wr
					best_wr_pid = record.player_id
		# カウンティング
		if ps.wins > best_wins_value:
			best_wins_value = ps.wins
			best_wins_pid = record.player_id
		if ps.strikeouts > best_k_value:
			best_k_value = ps.strikeouts
			best_k_pid = record.player_id
		if ps.saves > best_saves_value:
			best_saves_value = ps.saves
			best_saves_pid = record.player_id
		if ps.holds > best_holds_value:
			best_holds_value = ps.holds
			best_holds_pid = record.player_id

	titles["wins"] = best_wins_pid
	titles["era"] = best_era_pid
	titles["strikeouts"] = best_k_pid
	titles["saves"] = best_saves_pid
	titles["holds"] = best_holds_pid
	titles["win_rate"] = best_wr_pid
	return titles


static func _pick_mvp(records: Array, qualifier_pa: int, qualifier_outs: int, war_ctx: Dictionary) -> int:
	var best_score: float = -1e9
	var best_id: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var score: float = _mvp_score(record, qualifier_pa, qualifier_outs, war_ctx)
		if score > best_score:
			best_score = score
			best_id = record.player_id
	return best_id


# MVP スコア = WAR (シーズン累積)。qualifier 未満は失格扱い。
# WAR で評価することで投打を統一スケール (= 勝利貢献度) で比較できる。
static func _mvp_score(record: PSPlayerSeasonRecord, qualifier_pa: int, qualifier_outs: int, war_ctx: Dictionary) -> float:
	if record.is_pitcher():
		var ps: PSPitcherStats = record.pitcher_stats
		@warning_ignore("integer_division")
		if ps.outs_pitched < qualifier_outs / 2:
			return -1e8
		var war_row: Dictionary = WarCalculator.season_war(record, war_ctx)
		return float(war_row.get("war", 0.0))
	var bs: PSBatterStats = record.batter_stats
	@warning_ignore("integer_division")
	if bs.plate_appearances < qualifier_pa / 2:
		return -1e8
	var war_row_b: Dictionary = WarCalculator.season_war(record, war_ctx)
	return float(war_row_b.get("war", 0.0))


# 新人王 (years == 1) も WAR ベースで選出。MVP より緩めの qualifier (PA 100 / outs 30)。
static func _pick_rookie(records: Array, war_ctx: Dictionary) -> int:
	var best_score: float = -1e9
	var best_id: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.years != 1:
			continue
		var score: float = _mvp_score(record, 100, 30, war_ctx)
		if score > best_score:
			best_score = score
			best_id = record.player_id
	return best_id
