extends RefCounted
class_name AwardsService

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const QUALIFIER_PA_PER_GAME: float = 3.1
const QUALIFIER_OUTS_PER_GAME: float = 3.0
const COUNTING_TITLE_MIN_PA: int = 50
const PITCHER_EXCLUDE_PA: int = 30
const WIN_RATE_MIN_DECISIONS: int = 8
# ゴールデングラブの守備資格: 1試合平均このイニング数以上を主守備位置で守った選手のみ候補。
# 満たす選手がいなければ守備機会のある選手へフォールバックしてスロットを埋める。
const GOLDEN_GLOVE_MIN_INNINGS_PER_GAME: float = 3.0
# ベストナイン投手枠の最低登板量 (規定投球回の半分)。規定に届かない好リリーフも WAR で拾う。
const BEST_NINE_PITCHER_MIN_OUTS_FACTOR: float = 0.5


static func calculate(season: PSSeason, teams: Array) -> PSAwards:
	var awards: PSAwards = PSAwards.new()
	awards.year = season.year
	awards.season_number = season.season_number

	var team_by_id: Dictionary = {}
	var team_ids_by_league: Dictionary = {"league1": [], "league2": []}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			team_by_id[team.id] = team
			if team_ids_by_league.has(team.league):
				(team_ids_by_league[team.league] as Array).append(team.id)

	var by_league: Dictionary = {"league1": [], "league2": []}
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
		if league_key == "league1":
			awards.mvp_league1_player_id = mvp_id
			awards.rookie_league1_player_id = rookie_id
		else:
			awards.mvp_league2_player_id = mvp_id
			awards.rookie_league2_player_id = rookie_id

		# ベストナイン (打撃ベース、DH はリーグ設定に従う) / ゴールデングラブ (守備ベース)。
		var dh_enabled: bool = AppState.is_dh_enabled_for_league(league_key)
		awards.best_nine[league_key] = _pick_best_nine(league_records, war_ctx, qualifier_pa, qualifier_outs, dh_enabled)
		awards.golden_glove[league_key] = _pick_golden_glove(league_records, war_ctx, qualifier_outs, max_games)

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
# 外国人選手は新人王の対象外 (海外プロ経験を持つため NPB でも資格がない扱い)。
static func _pick_rookie(records: Array, war_ctx: Dictionary) -> int:
	var best_score: float = -1e9
	var best_id: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.years != 1 or record.foreign_player:
			continue
		var score: float = _mvp_score(record, 100, 30, war_ctx)
		if score > best_score:
			best_score = score
			best_id = record.player_id
	return best_id


# ============================================================ ベストナイン / ゴールデングラブ

# ベストナイン: 各守備位置で OPS 最上位の野手を選ぶ (投手枠のみ WAR)。担当位置は主守備位置
# (advanced_stats.primary_uzr_position) で判定し、外野3枠は左中右を集約して上位3人、
# DH 枠は守備機会ゼロ (= 専任打者) の中から選ぶ。返り値は PSAwards.BEST_NINE_SLOT_POSITIONS 順の
# Array[{pid:int, value:String}] (10枠)。守備は問わない打撃タイトル的な選出。
static func _pick_best_nine(records: Array, war_ctx: Dictionary, qualifier_pa: int, qualifier_outs: int, dh_enabled: bool) -> Array:
	var batters_by_pos: Dictionary = {}   # position(1..7、外野は7へ集約) → Array[{pid, ops, pa}]
	var dh_pool: Array = []               # 専任打者 (守備機会ゼロ)
	var pitchers: Array = []              # {pid, war}
	var min_pitcher_outs: int = maxi(1, int(round(float(qualifier_outs) * BEST_NINE_PITCHER_MIN_OUTS_FACTOR)))
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher():
			var ps: PSPitcherStats = record.pitcher_stats
			if ps != null and ps.outs_pitched >= min_pitcher_outs:
				var war: float = float(WarCalculator.season_war(record, war_ctx).get("war", 0.0))
				pitchers.append({"pid": record.player_id, "war": war})
			continue
		var bs: PSBatterStats = record.batter_stats
		if bs == null or bs.at_bats <= 0:
			continue
		var pos: int = _primary_position(record)
		var entry: Dictionary = {"pid": record.player_id, "ops": bs.ops(), "pa": bs.plate_appearances}
		if pos >= 7 and pos <= 9:
			_append_to(batters_by_pos, 7, entry)
		elif pos >= 1 and pos <= 6:
			_append_to(batters_by_pos, pos, entry)
		else:
			# 守備機会ゼロ / DH(10) は専任打者として DH 枠候補にする。
			dh_pool.append(entry)

	var of_cells: Array = _best_nine_batter_cells(batters_by_pos.get(7, []) as Array, qualifier_pa, 3)
	var result: Array = []
	var of_index: int = 0
	for slot_value in PSAwards.BEST_NINE_SLOT_POSITIONS:
		var slot_pos: int = int(slot_value)
		match slot_pos:
			1:
				result.append(_best_nine_pitcher_cell(pitchers))
			7:
				result.append(of_cells[of_index] if of_index < of_cells.size() else _empty_award_cell())
				of_index += 1
			10:
				if dh_enabled:
					var dh_cells: Array = _best_nine_batter_cells(dh_pool, qualifier_pa, 1)
					result.append(dh_cells[0] if not dh_cells.is_empty() else _empty_award_cell())
				else:
					result.append(_empty_award_cell())
			_:
				var cells: Array = _best_nine_batter_cells(batters_by_pos.get(slot_pos, []) as Array, qualifier_pa, 1)
				result.append(cells[0] if not cells.is_empty() else _empty_award_cell())
	return result


# プール (打者候補) から OPS 上位 count 人を {pid, value} で返す。規定打席到達者を優先し、
# いなければ 50 打席以上へフォールバックしてスロットを埋める。
static func _best_nine_batter_cells(pool: Array, qualifier_pa: int, count: int) -> Array:
	var qualified: Array = pool.filter(func(e: Dictionary) -> bool: return int(e.get("pa", 0)) >= qualifier_pa)
	if qualified.is_empty():
		qualified = pool.filter(func(e: Dictionary) -> bool: return int(e.get("pa", 0)) >= COUNTING_TITLE_MIN_PA)
	qualified.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("ops", 0.0)) > float(b.get("ops", 0.0)))
	var out: Array = []
	for i in range(mini(count, qualified.size())):
		var e: Dictionary = qualified[i] as Dictionary
		out.append({"pid": int(e.get("pid", 0)), "value": _ops_text(float(e.get("ops", 0.0)))})
	return out


static func _best_nine_pitcher_cell(pitchers: Array) -> Dictionary:
	if pitchers.is_empty():
		return _empty_award_cell()
	pitchers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("war", 0.0)) > float(b.get("war", 0.0)))
	var top: Dictionary = pitchers[0] as Dictionary
	return {"pid": int(top.get("pid", 0)), "value": "%.1f WAR" % float(top.get("war", 0.0))}


# ゴールデングラブ: 各守備位置で守備ラン (ポジション別センタリング UZR) 最上位の選手。
# 外野3枠は左中右を集約して上位3人。主守備位置での守備イニングが基準未満の選手は原則除外し、
# 該当者がいなければ守備機会のある選手へフォールバックする。返り値は
# PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS 順の Array[{pid:int, value:String}] (9枠)。
static func _pick_golden_glove(records: Array, war_ctx: Dictionary, qualifier_outs: int, max_games: int) -> Array:
	var min_innings: float = float(max_games) * GOLDEN_GLOVE_MIN_INNINGS_PER_GAME
	var fielders_by_pos: Dictionary = {}   # pos(2..7、外野は7へ集約) → Array[{pid, value, innings}]
	var pitchers: Array = []               # {pid, value, outs}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		var ad: PSAdvancedStats = record.advanced_stats
		if ad == null:
			continue
		if record.is_pitcher():
			var ps: PSPitcherStats = record.pitcher_stats
			if ps == null or ps.outs_pitched <= 0:
				continue
			var pd: Dictionary = _centered_defense(ad, war_ctx, 1)
			if int(pd.get("chances", 0)) <= 0:
				continue
			pitchers.append({"pid": record.player_id, "value": float(pd.get("value", 0.0)), "outs": ps.outs_pitched})
			continue
		var pos: int = ad.primary_uzr_position()
		if pos < 2 or pos > 9:
			continue
		var fd: Dictionary = _centered_defense(ad, war_ctx, pos)
		if int(fd.get("chances", 0)) <= 0:
			continue
		var bucket_pos: int = 7 if pos >= 7 else pos
		_append_to(fielders_by_pos, bucket_pos, {"pid": record.player_id, "value": float(fd.get("value", 0.0)), "innings": record.defensive_innings_at(pos)})

	var of_cells: Array = _golden_glove_cells(fielders_by_pos.get(7, []) as Array, min_innings, 3)
	var result: Array = []
	var of_index: int = 0
	for slot_value in PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS:
		var slot_pos: int = int(slot_value)
		match slot_pos:
			1:
				result.append(_golden_glove_pitcher_cell(pitchers, qualifier_outs))
			7:
				result.append(of_cells[of_index] if of_index < of_cells.size() else _empty_award_cell())
				of_index += 1
			_:
				var cells: Array = _golden_glove_cells(fielders_by_pos.get(slot_pos, []) as Array, min_innings, 1)
				result.append(cells[0] if not cells.is_empty() else _empty_award_cell())
	return result


static func _golden_glove_cells(pool: Array, min_innings: float, count: int) -> Array:
	var qualified: Array = pool.filter(func(e: Dictionary) -> bool: return float(e.get("innings", 0.0)) >= min_innings)
	if qualified.is_empty():
		qualified = pool.duplicate()
	qualified.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("value", 0.0)) > float(b.get("value", 0.0)))
	var out: Array = []
	for i in range(mini(count, qualified.size())):
		var e: Dictionary = qualified[i] as Dictionary
		out.append({"pid": int(e.get("pid", 0)), "value": _defense_text(float(e.get("value", 0.0)))})
	return out


static func _golden_glove_pitcher_cell(pitchers: Array, qualifier_outs: int) -> Dictionary:
	if pitchers.is_empty():
		return _empty_award_cell()
	var qualified: Array = pitchers.filter(func(e: Dictionary) -> bool: return int(e.get("outs", 0)) >= qualifier_outs)
	if qualified.is_empty():
		qualified = pitchers
	qualified.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("value", 0.0)) > float(b.get("value", 0.0)))
	var top: Dictionary = qualified[0] as Dictionary
	return {"pid": int(top.get("pid", 0)), "value": _defense_text(float(top.get("value", 0.0)))}


# 指定守備位置での守備ラン (rngr+errr+dpr) を war_ctx のポジション別センタリングで求める。
# 戻り値 {value:float, chances:int}。守備機会ゼロなら chances=0。
static func _centered_defense(ad: PSAdvancedStats, war_ctx: Dictionary, pos: int) -> Dictionary:
	var key: String = str(pos)
	var chances: float = float(int(ad.fielding_chances_by_position.get(key, 0)))
	if chances <= 0.0:
		return {"value": -1e9, "chances": 0}
	var center: Dictionary = war_ctx.get("fielding_center", {}) as Dictionary
	var rngr_pc: float = float((center.get("rngr_per_chance_by_position", {}) as Dictionary).get(key, 0.0))
	var errr_pc: float = float((center.get("errr_per_chance_by_position", {}) as Dictionary).get(key, 0.0))
	var dpr_pc: float = float((center.get("dpr_per_chance_by_position", {}) as Dictionary).get(key, 0.0))
	var rngr: float = float(ad.rngr_by_position.get(key, 0.0)) - rngr_pc * chances
	var errr: float = float(ad.errr_by_position.get(key, 0.0)) - errr_pc * chances
	var dpr: float = float(ad.dpr_by_position.get(key, 0.0)) - dpr_pc * chances
	return {"value": rngr + errr + dpr, "chances": int(chances)}


static func _primary_position(record: PSPlayerSeasonRecord) -> int:
	if record.advanced_stats != null:
		return record.advanced_stats.primary_uzr_position()
	return record.position


static func _append_to(dict: Dictionary, key: int, entry: Dictionary) -> void:
	if not dict.has(key):
		dict[key] = []
	(dict[key] as Array).append(entry)


static func _empty_award_cell() -> Dictionary:
	return {"pid": 0, "value": ""}


# OPS 表示 (".912" / "1.023")。先頭 0 を省いて打率系の並びに寄せる。
static func _ops_text(value: float) -> String:
	var s: String = "%.3f" % value
	if s.begins_with("0."):
		return s.substr(1)
	return s


static func _defense_text(value: float) -> String:
	return "%+.1f" % value
