extends RefCounted
class_name PSWarCalculator

# WAR (Wins Above Replacement) 算出モジュール。
#
# - 野手 WAR は wRAA、BsR、OAA ラン、守備位置補正、league adjustment、replacement を RPW で勝利換算する。
# - 投手 WAR は ifFIP 由来の FIPR9、投手別 RPW、役割別 replacement、救援 leverage、リーグ補正で求める。
# - WAR プールは .294 replacement、162試合30球団=1000 WAR、野手57%・投手43%を試合数で比例配分する。

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")

# wOBA scale はシーズン定数相当。シム内では固定し、リーグ平均との差だけを season context で再計算する。
const WOBA_SCALE: float = 1.24

# FanGraphs と Baseball-Reference が共有する replacement 枠組み。
const REPLACEMENT_WIN_PCT: float = 0.294
const FULL_MLB_GAMES: float = 2430.0
const TOTAL_WAR_POOL_FULL_SEASON: float = 1000.0
const POSITION_PLAYER_WAR_POOL_FULL_SEASON: float = 570.0
const PITCHER_WAR_POOL_FULL_SEASON: float = 430.0

# FanGraphs の投手 replacement は wins/game 単位で、先発と救援を GS/G で按分する。
const PITCHER_STARTER_REPLACEMENT_WPG: float = 0.12
const PITCHER_RELIEVER_REPLACEMENT_WPG: float = 0.03

# Statcast Fielding Run Value の OAA→runs 変換。捕手固有指標は未保持のため range 相当のみ扱う。
const OAA_INFIELD_RUNS_PER_OUT: float = 0.75
const OAA_OUTFIELD_RUNS_PER_OUT: float = 0.90

# 平均選手ベンチマーク表示用の参照稼働量(WAR 算出には使わない)。
const BENCHMARK_BATTER_PA: float = 600.0    # 「平均的フル稼働野手」の参照打席数。
const BENCHMARK_STARTER_IP: float = 162.0   # 「平均的フル稼働先発」の参照投球回。
const BENCHMARK_RELIEVER_IP: float = 60.0   # 「平均的フル稼働救援」の参照投球回。

# 当該シーズンのリーグ全体集計からリーグコンテキストを構築する。
static func build_league_context(year: int, season_number: int, meta: Dictionary = {}) -> Dictionary:
	var total_pa: int = 0
	var total_woba_num: float = 0.0
	var total_woba_denom: int = 0
	var total_batter_pa: int = 0
	var total_batter_bsr: float = 0.0
	var total_outs: int = 0
	var total_earned_runs: int = 0
	var total_runs_allowed: int = 0
	var total_hr_allowed: int = 0
	var total_bb_allowed: int = 0
	var total_hbp_allowed: int = 0
	var total_k_thrown: int = 0
	var total_batters_faced: int = 0
	var total_ground_balls_allowed: int = 0
	var total_line_drives_allowed: int = 0
	var total_infield_flies_allowed: int = 0
	var total_outfield_flies_allowed: int = 0
	var lg_oaa_by_pos: Dictionary = {}
	var lg_rngr_by_pos: Dictionary = {}
	var lg_errr_by_pos: Dictionary = {}
	var lg_dpr_by_pos: Dictionary = {}
	var lg_chances_by_pos: Dictionary = {}
	var player_team_ids: Dictionary = {}
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		if record.team_id > 0:
			player_team_ids[record.team_id] = true
		var pitcher: PSPitcherStats = record.pitcher_stats
		var is_pitcher_war: bool = record.is_pitcher() and pitcher != null and pitcher.outs_pitched > 0
		var ad: PSAdvancedStats = record.advanced_stats
		if ad != null:
			total_pa += ad.plate_appearances
			_accumulate_float_map(lg_oaa_by_pos, ad.oaa_by_position)
			_accumulate_float_map(lg_rngr_by_pos, ad.rngr_by_position)
			_accumulate_float_map(lg_errr_by_pos, ad.errr_by_position)
			_accumulate_float_map(lg_dpr_by_pos, ad.dpr_by_position)
			_accumulate_int_map(lg_chances_by_pos, ad.fielding_chances_by_position)
			if not is_pitcher_war:
				total_woba_num += ad.woba_numerator
				total_woba_denom += ad.woba_denominator
				total_batter_pa += ad.plate_appearances
				total_batter_bsr += ad.bsr_sum
		if pitcher != null and pitcher.outs_pitched > 0:
			total_outs += pitcher.outs_pitched
			total_earned_runs += pitcher.earned_runs
			total_runs_allowed += pitcher.runs_allowed
			total_hr_allowed += pitcher.home_runs_allowed
			total_bb_allowed += pitcher.walks
			total_hbp_allowed += pitcher.hit_batters
			total_k_thrown += pitcher.strikeouts
			total_batters_faced += pitcher.batters_faced
			total_ground_balls_allowed += pitcher.ground_balls_allowed
			total_line_drives_allowed += pitcher.line_drives_allowed
			total_infield_flies_allowed += pitcher.infield_flies_allowed
			total_outfield_flies_allowed += pitcher.outfield_flies_allowed

	var lg_woba: float = 0.0
	if total_woba_denom > 0:
		lg_woba = total_woba_num / float(total_woba_denom)

	var lg_ip: float = float(total_outs) / 3.0
	var lg_runs_per_inning: float = 0.0
	if total_outs > 0:
		lg_runs_per_inning = float(total_runs_allowed) * 3.0 / float(total_outs)
	var lg_runs_per_team_game: float = lg_runs_per_inning * 9.0
	# FanGraphs の野手 RPW: 9*(lgR/IP)*1.5 + 3。投手側 dRPW (平均投手で (lgFIPR9+2)*1.5) と
	# 同族の式で、投打の「runs→wins」換算が一致する。GUTS 実値 (1968: R/W 8.130) と一致を確認済み。
	var rpw: float = 9.0 * lg_runs_per_inning * 1.5 + 3.0
	rpw = clamp(rpw, 6.0, 14.0)

	var lg_era: float = 0.0
	if total_outs > 0:
		lg_era = float(total_earned_runs) * 27.0 / float(total_outs)
	var lg_ra9: float = 0.0
	if total_outs > 0:
		lg_ra9 = float(total_runs_allowed) * 27.0 / float(total_outs)
	var lg_fip_raw: float = 0.0
	if lg_ip > 0.0:
		lg_fip_raw = _fip_raw_from_counts(total_hr_allowed, total_bb_allowed, total_hbp_allowed, total_k_thrown, lg_ip)
	var lg_fip_era_constant: float = lg_era - lg_fip_raw
	var lg_fip: float = lg_fip_raw + lg_fip_era_constant

	var batted_ball_events: int = total_ground_balls_allowed + total_line_drives_allowed + total_infield_flies_allowed + total_outfield_flies_allowed
	var lg_iffip_raw: float = 0.0
	if lg_ip > 0.0:
		lg_iffip_raw = _iffip_raw_from_counts(total_hr_allowed, total_bb_allowed, total_hbp_allowed, total_k_thrown, total_infield_flies_allowed, lg_ip)
	var lg_iffip_constant: float = lg_era - lg_iffip_raw
	var fipr9_adjustment: float = lg_ra9 - lg_era
	var lg_fipr9: float = lg_ra9

	var season_meta: Dictionary = _season_meta(year, season_number, player_team_ids, meta)
	var num_teams: int = int(season_meta.get("num_teams", 0))
	var games_per_team: float = float(season_meta.get("games_per_team", 0.0))
	var league_games: float = float(num_teams) * games_per_team / 2.0
	var war_pool_scale: float = league_games / FULL_MLB_GAMES if FULL_MLB_GAMES > 0.0 else 0.0
	var position_player_war_pool: float = POSITION_PLAYER_WAR_POOL_FULL_SEASON * war_pool_scale
	var pitcher_war_pool: float = PITCHER_WAR_POOL_FULL_SEASON * war_pool_scale
	var total_war_pool: float = TOTAL_WAR_POOL_FULL_SEASON * war_pool_scale

	var replacement_runs_per_pa: float = 0.0
	if total_batter_pa > 0:
		replacement_runs_per_pa = position_player_war_pool * rpw / float(total_batter_pa)
	var lg_bsr_per_pa: float = 0.0
	if total_batter_pa > 0:
		lg_bsr_per_pa = total_batter_bsr / float(total_batter_pa)

	var fielding_center: Dictionary = {
		"oaa_per_chance_by_position": _per_chance_map(lg_oaa_by_pos, lg_chances_by_pos),
		"rngr_per_chance_by_position": _per_chance_map(lg_rngr_by_pos, lg_chances_by_pos),
		"errr_per_chance_by_position": _per_chance_map(lg_errr_by_pos, lg_chances_by_pos),
		"dpr_per_chance_by_position": _per_chance_map(lg_dpr_by_pos, lg_chances_by_pos),
	}
	var ctx: Dictionary = {
		"year": year,
		"season_number": season_number,
		"fielding_center": fielding_center,
		"total_pa": total_pa,
		"total_woba_num": total_woba_num,
		"total_woba_denom": total_woba_denom,
		"lg_woba": lg_woba,
		"woba_scale": WOBA_SCALE,
		"lg_runs": total_runs_allowed,
		"lg_earned_runs": total_earned_runs,
		"lg_outs": total_outs,
		"lg_ip": lg_ip,
		"lg_runs_per_inning": lg_runs_per_inning,
		"lg_runs_per_team_game": lg_runs_per_team_game,
		"rpw": rpw,
		"lg_hr": total_hr_allowed,
		"lg_bb": total_bb_allowed,
		"lg_hbp": total_hbp_allowed,
		"lg_k": total_k_thrown,
		"lg_batters_faced": total_batters_faced,
		"lg_era": lg_era,
		"lg_ra9": lg_ra9,
		"lg_fip_raw": lg_fip_raw,
		"lg_fip": lg_fip,
		"lg_fip_era_constant": lg_fip_era_constant,
		"lg_iffip_raw": lg_iffip_raw,
		"lg_iffip_constant": lg_iffip_constant,
		"fipr9_adjustment": fipr9_adjustment,
		"lg_fipr9": lg_fipr9,
		"lg_ground_balls_allowed": total_ground_balls_allowed,
		"lg_line_drives_allowed": total_line_drives_allowed,
		"lg_infield_flies_allowed": total_infield_flies_allowed,
		"lg_outfield_flies_allowed": total_outfield_flies_allowed,
		"batted_ball_events": batted_ball_events,
		"num_teams": num_teams,
		"games_per_team": games_per_team,
		"league_games": league_games,
		"war_pool_scale": war_pool_scale,
		"total_war_pool": total_war_pool,
		"position_player_war_pool": position_player_war_pool,
		"pitcher_war_pool": pitcher_war_pool,
		"total_batter_pa": total_batter_pa,
		"lg_bsr_per_pa": lg_bsr_per_pa,
		"replacement_runs_per_pa": replacement_runs_per_pa,
		"pitcher_war_ip_correction": 0.0,
		"batter_league_adjustment_runs_per_pa": 0.0,
	}
	ctx["batter_league_adjustment_runs_per_pa"] = _batter_league_adjustment_per_pa(year, season_number, ctx)
	ctx["pitcher_war_ip_correction"] = _pitcher_war_ip_correction(year, season_number, ctx)
	ctx["war_method"] = {
		"system": "FanGraphs fWAR adapted",
		"batter_run_metric": "wRAA",
		"batter_woba_scale": WOBA_SCALE,
		"batter_replacement_pool": position_player_war_pool,
		"batter_fielding_component": "OAA_runs",
		"pitcher_run_metric": "FIPR9",
		"pitcher_replacement_starter_wpg": PITCHER_STARTER_REPLACEMENT_WPG,
		"pitcher_replacement_reliever_wpg": PITCHER_RELIEVER_REPLACEMENT_WPG,
		"pitcher_war_ip_correction": ctx["pitcher_war_ip_correction"],
		"replacement_win_pct": REPLACEMENT_WIN_PCT,
		"full_mlb_games": FULL_MLB_GAMES,
		"position_player_war_share": POSITION_PLAYER_WAR_POOL_FULL_SEASON / TOTAL_WAR_POOL_FULL_SEASON,
		"pitcher_war_share": PITCHER_WAR_POOL_FULL_SEASON / TOTAL_WAR_POOL_FULL_SEASON,
	}
	return ctx


static func _season_meta(year: int, season_number: int, player_team_ids: Dictionary, meta: Dictionary) -> Dictionary:
	var team_ids: Dictionary = {}
	var team_games_sum: int = 0
	for record_value in RecordStore.team_records.values():
		var record: PSTeamSeasonRecord = record_value as PSTeamSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		if record.team_id > 0:
			team_ids[record.team_id] = true
			team_games_sum += record.stats.games
	var num_teams: int = int(meta.get("num_teams", 0))
	if num_teams <= 0:
		num_teams = team_ids.size()
	if num_teams <= 0:
		num_teams = player_team_ids.size()
	var games_per_team: float = float(meta.get("games_per_team", 0.0))
	if games_per_team <= 0.0 and num_teams > 0 and team_games_sum > 0:
		games_per_team = float(team_games_sum) / float(num_teams)
	if games_per_team <= 0.0:
		games_per_team = 162.0
	return {
		"num_teams": max(1, num_teams),
		"games_per_team": games_per_team,
	}


static func _batter_league_adjustment_per_pa(year: int, season_number: int, league_ctx: Dictionary) -> float:
	var total_runs: float = 0.0
	var total_pa: int = 0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		var pitcher: PSPitcherStats = record.pitcher_stats
		var is_pitcher_war: bool = record.is_pitcher() and pitcher != null and pitcher.outs_pitched > 0
		if is_pitcher_war:
			continue
		var components: Dictionary = _batter_war_components(record, league_ctx)
		var pa: int = int(components.get("pa", 0))
		if pa <= 0:
			continue
		total_pa += pa
		total_runs += float(components.get("performance_runs_no_league_adjustment", 0.0))
	if total_pa <= 0:
		return 0.0
	return -total_runs / float(total_pa)


static func _batter_war_components(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	if record == null or record.advanced_stats == null:
		return {}
	var ad: PSAdvancedStats = record.advanced_stats
	var pa: int = ad.plate_appearances
	if pa <= 0:
		return {}
	var lg_woba: float = float(league_ctx.get("lg_woba", 0.315))
	var woba_denom: int = ad.woba_denominator
	var woba: float = ad.woba()
	var wraa: float = 0.0
	if woba_denom > 0:
		wraa = ((woba - lg_woba) / WOBA_SCALE) * float(pa)
	var bsr: float = ad.bsr_sum - float(league_ctx.get("lg_bsr_per_pa", 0.0)) * float(pa)
	var ad_dict: Dictionary = ad.to_dict()
	var centered_fielding: Dictionary = recenter_fielding(ad_dict, league_ctx)
	var fielding_runs: float = float(centered_fielding.get("fielding_runs", ad_dict.get("fielding_runs", 0.0)))
	var oaa_runs: float = float(centered_fielding.get("oaa_runs", ad_dict.get("oaa_runs", 0.0)))
	var pos_adj: float = float(ad_dict.get("positional_adjustment_runs", 0.0))
	var league_adjustment_runs: float = float(league_ctx.get("batter_league_adjustment_runs_per_pa", 0.0)) * float(pa)
	var performance_runs_no_league_adjustment: float = wraa + bsr + fielding_runs + pos_adj
	return {
		"pa": pa,
		"wraa": wraa,
		"bsr": bsr,
		"fielding_runs": fielding_runs,
		"oaa_runs": oaa_runs,
		"pos_adj": pos_adj,
		"league_adjustment_runs": league_adjustment_runs,
		"performance_runs_no_league_adjustment": performance_runs_no_league_adjustment,
		"performance_runs": performance_runs_no_league_adjustment + league_adjustment_runs,
		"primary_uzr_position": int(ad_dict.get("primary_uzr_position", record.position)),
	}


static func _fip_raw_from_counts(hr: int, bb: int, hbp: int, k: int, ip: float) -> float:
	if ip <= 0.0:
		return 0.0
	return (13.0 * float(hr) + 3.0 * float(bb + hbp) - 2.0 * float(k)) / ip


static func _iffip_raw_from_counts(hr: int, bb: int, hbp: int, k: int, iffb: int, ip: float) -> float:
	if ip <= 0.0:
		return 0.0
	return (13.0 * float(hr) + 3.0 * float(bb + hbp) - 2.0 * float(k + iffb)) / ip


static func _pitcher_fip(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	var ps: PSPitcherStats = record.pitcher_stats
	var ip: float = ps.innings_pitched()
	return _fip_raw_from_counts(ps.home_runs_allowed, ps.walks, ps.hit_batters, ps.strikeouts, ip) \
		+ float(league_ctx.get("lg_fip_era_constant", 0.0))


static func _pitcher_iffip(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	var ps: PSPitcherStats = record.pitcher_stats
	var ip: float = ps.innings_pitched()
	return _iffip_raw_from_counts(ps.home_runs_allowed, ps.walks, ps.hit_batters, ps.strikeouts, ps.infield_flies_allowed, ip) \
		+ float(league_ctx.get("lg_iffip_constant", 0.0))


static func _pitcher_fipr9(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	return _pitcher_iffip(record, league_ctx) + float(league_ctx.get("fipr9_adjustment", 0.0))


static func _pitcher_dynamic_rpw(fipr9: float, lg_fipr9: float, ip_per_game: float) -> float:
	var pitcher_ip_share: float = clamp(ip_per_game, 0.0, 9.0)
	return max(1.0, ((((18.0 - pitcher_ip_share) * lg_fipr9) + (pitcher_ip_share * fipr9)) / 18.0 + 2.0) * 1.5)


static func _pitcher_replacement_wpg(starter_share: float) -> float:
	return PITCHER_STARTER_REPLACEMENT_WPG * starter_share + PITCHER_RELIEVER_REPLACEMENT_WPG * (1.0 - starter_share)


static func _estimated_pitcher_gmli(record: PSPlayerSeasonRecord) -> float:
	var ps: PSPitcherStats = record.pitcher_stats
	if ps == null:
		return 1.0
	var relief_games: int = max(0, ps.games - ps.starts)
	if relief_games <= 0:
		return 1.0
	var save_share: float = clamp(float(ps.saves) / float(relief_games), 0.0, 1.0)
	var hold_share: float = clamp(float(ps.holds) / float(relief_games), 0.0, 1.0)
	var role_base: float = 1.05
	if record.role == "closer":
		role_base = 1.55
	return clamp(role_base + 0.25 * hold_share + 0.35 * save_share, 0.85, 1.90)


static func _pitcher_leverage_multiplier(record: PSPlayerSeasonRecord, starter_share: float) -> float:
	var reliever_share: float = 1.0 - starter_share
	if reliever_share <= 0.0:
		return 1.0
	var reliever_multiplier: float = (1.0 + _estimated_pitcher_gmli(record)) / 2.0
	return starter_share + reliever_share * reliever_multiplier


static func _pitcher_war_ip_correction(year: int, season_number: int, league_ctx: Dictionary) -> float:
	var target_pool: float = float(league_ctx.get("pitcher_war_pool", 0.0))
	var raw_war: float = 0.0
	var total_ip: float = 0.0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		if not record.is_pitcher() or record.pitcher_stats == null or record.pitcher_stats.outs_pitched <= 0:
			continue
		var components: Dictionary = _pitcher_war_components(record, league_ctx, false)
		raw_war += float(components.get("war_before_correction", 0.0))
		total_ip += float(components.get("ip", 0.0))
	if total_ip <= 0.0:
		return 0.0
	return (target_pool - raw_war) / total_ip


static func _pitcher_war_components(record: PSPlayerSeasonRecord, league_ctx: Dictionary, include_correction: bool = true) -> Dictionary:
	if record == null or record.pitcher_stats == null:
		return {}
	var ps: PSPitcherStats = record.pitcher_stats
	if ps.outs_pitched <= 0:
		return {}
	var ip: float = ps.innings_pitched()
	var fip: float = _pitcher_fip(record, league_ctx)
	var iffip: float = _pitcher_iffip(record, league_ctx)
	var fipr9: float = _pitcher_fipr9(record, league_ctx)
	var lg_fipr9: float = float(league_ctx.get("lg_fipr9", league_ctx.get("lg_ra9", 0.0)))
	var games: int = max(1, ps.games)
	var gs_share: float = clamp(float(ps.starts) / float(games), 0.0, 1.0)
	var ip_per_game: float = ip / float(games)
	var dynamic_rpw: float = _pitcher_dynamic_rpw(fipr9, lg_fipr9, ip_per_game)
	var wins_above_avg_per_game: float = (lg_fipr9 - fipr9) / dynamic_rpw if dynamic_rpw > 0.0 else 0.0
	var replacement_wpg: float = _pitcher_replacement_wpg(gs_share)
	var pre_leverage_war: float = (wins_above_avg_per_game + replacement_wpg) * (ip / 9.0)
	var leverage_multiplier: float = _pitcher_leverage_multiplier(record, gs_share)
	var war_before_correction: float = pre_leverage_war * leverage_multiplier
	var correction_per_ip: float = float(league_ctx.get("pitcher_war_ip_correction", 0.0)) if include_correction else 0.0
	var correction: float = correction_per_ip * ip
	var war: float = war_before_correction + correction
	var raa_runs: float = (lg_fipr9 - fipr9) / 9.0 * ip
	var replacement_runs: float = replacement_wpg * dynamic_rpw * (ip / 9.0)
	return {
		"ip": ip,
		"fip": fip,
		"iffip": iffip,
		"fipr9": fipr9,
		"run_metric": fipr9,
		"run_metric_name": "FIPR9",
		"lg_run_metric": lg_fipr9,
		"gs_share": gs_share,
		"ip_per_game": ip_per_game,
		"dynamic_rpw": dynamic_rpw,
		"wins_above_avg_per_game": wins_above_avg_per_game,
		"replacement_wpg": replacement_wpg,
		"role_replacement_runs_per_9": replacement_wpg * dynamic_rpw,
		"leverage_multiplier": leverage_multiplier,
		"war_before_correction": war_before_correction,
		"war_correction": correction,
		"raa_runs": raa_runs,
		"replacement_runs": replacement_runs,
		"rar_runs": raa_runs + replacement_runs,
		"war": war,
	}


# 単一選手の WAR を算出。野手 or 投手で内訳が変わる。
# - 投手として ip>0 なら投手 WAR を、それ以外なら野手 WAR を返す。
# - 二刀流 (PA も IP も持つ) は将来対応。現状は投手枠 (役割) を優先。
static func season_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	if record == null:
		return _empty_war_result()
	if record.is_pitcher() and record.pitcher_stats != null and record.pitcher_stats.outs_pitched > 0:
		return calculate_pitcher_war(record, league_ctx)
	return calculate_batter_war(record, league_ctx)


# 野手 WAR を算出。wRAA / BsR / UZR 系守備ラン / 守備位置補正 / リプレイスメントを RPW で勝利換算する。
static func calculate_batter_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	var result: Dictionary = _empty_war_result()
	result["role"] = "batter"
	if record == null or record.advanced_stats == null:
		return result
	var components: Dictionary = _batter_war_components(record, league_ctx)
	var pa: int = int(components.get("pa", 0))
	if pa <= 0:
		return result
	var wraa: float = float(components.get("wraa", 0.0))
	var bsr: float = float(components.get("bsr", 0.0))
	var fielding_runs: float = float(components.get("fielding_runs", 0.0))
	var oaa_runs: float = float(components.get("oaa_runs", 0.0))
	var pos_adj: float = float(components.get("pos_adj", 0.0))
	var league_adjustment_runs: float = float(components.get("league_adjustment_runs", 0.0))
	var performance_runs: float = float(components.get("performance_runs", 0.0))
	var replacement_runs: float = float(league_ctx.get("replacement_runs_per_pa", 0.0)) * float(pa)
	var rpw: float = float(league_ctx.get("rpw", 10.0))
	var total_runs: float = performance_runs + replacement_runs
	var war: float = total_runs / rpw if rpw > 0.0 else 0.0

	result["role"] = "batter"
	result["player_id"] = record.player_id
	result["name"] = record.name
	result["position"] = record.position
	result["primary_uzr_position"] = int(components.get("primary_uzr_position", record.position))
	result["pa"] = pa
	result["wraa"] = _round3(wraa)
	result["bsr"] = _round3(bsr)
	result["fielding_runs"] = _round3(fielding_runs)
	result["oaa_runs"] = _round3(oaa_runs)
	result["pos_adj"] = _round3(pos_adj)
	result["league_adjustment_runs"] = _round3(league_adjustment_runs)
	result["performance_runs"] = _round3(performance_runs)
	result["replacement_runs"] = _round3(replacement_runs)
	result["total_runs"] = _round3(total_runs)
	result["rpw"] = _round3(rpw)
	result["war"] = _round3(war)
	return result


# 投手 WAR を算出。ifFIP/FIPR9 と役割別 replacement を勝利単位で合算する。
static func calculate_pitcher_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	var result: Dictionary = _empty_war_result()
	result["role"] = "pitcher"
	if record == null or record.pitcher_stats == null:
		return result
	var ps: PSPitcherStats = record.pitcher_stats
	if ps.outs_pitched <= 0:
		return result
	var components: Dictionary = _pitcher_war_components(record, league_ctx)
	var ip: float = float(components.get("ip", 0.0))
	var fipr9: float = float(components.get("fipr9", 0.0))
	var lg_metric: float = float(components.get("lg_run_metric", 0.0))
	var rpw: float = float(league_ctx.get("rpw", 10.0))
	var war: float = float(components.get("war", 0.0))
	var raw_runs_above_avg_per_9: float = lg_metric - fipr9
	var dynamic_rpw: float = float(components.get("dynamic_rpw", rpw))
	var wins_above_avg_per_9: float = raw_runs_above_avg_per_9 / dynamic_rpw if dynamic_rpw > 0.0 else 0.0
	var role_replacement_runs_per_9: float = float(components.get("role_replacement_runs_per_9", 0.0))
	var rar: float = float(components.get("rar_runs", 0.0)) + float(components.get("war_correction", 0.0)) * rpw

	result["role"] = "pitcher"
	result["player_id"] = record.player_id
	result["name"] = record.name
	result["position"] = record.position
	result["ip"] = _round3(ip)
	result["metric_ip"] = _round3(ip)
	result["fip"] = _round3(float(components.get("fip", 0.0)))
	result["iffip"] = _round3(float(components.get("iffip", 0.0)))
	result["fipr9"] = _round3(fipr9)
	result["run_metric"] = _round3(fipr9)
	result["run_metric_name"] = "FIPR9"
	result["era"] = _round3(ps.era())
	result["lg_fip"] = _round3(float(league_ctx.get("lg_fip", 0.0)))
	result["lg_fip_constant"] = _round3(float(league_ctx.get("lg_fip_era_constant", 0.0)))
	result["lg_iffip_constant"] = _round3(float(league_ctx.get("lg_iffip_constant", 0.0)))
	result["lg_fipr9"] = _round3(float(league_ctx.get("lg_fipr9", 0.0)))
	result["lg_run_metric"] = _round3(lg_metric)
	result["gs_share"] = _round3(float(components.get("gs_share", 0.0)))
	result["ip_per_game"] = _round3(float(components.get("ip_per_game", 0.0)))
	result["dynamic_rpw"] = _round3(dynamic_rpw)
	result["role_replacement_runs_per_9"] = _round3(role_replacement_runs_per_9)
	result["replacement_wpg"] = _round3(float(components.get("replacement_wpg", 0.0)))
	result["leverage_multiplier"] = _round3(float(components.get("leverage_multiplier", 1.0)))
	result["war_before_correction"] = _round3(float(components.get("war_before_correction", 0.0)))
	result["war_correction"] = _round3(float(components.get("war_correction", 0.0)))
	result["raw_runs_above_avg_per_9"] = _round3(raw_runs_above_avg_per_9)
	result["wins_above_avg_per_9"] = _round3(wins_above_avg_per_9)
	result["replacement_factor"] = _round3((lg_metric + role_replacement_runs_per_9) / lg_metric) if lg_metric > 0.0 else 0.0
	result["raa9"] = _round3(raw_runs_above_avg_per_9)
	result["raa"] = _round3(float(components.get("raa_runs", 0.0)))
	result["rar"] = _round3(rar)
	result["rpw"] = _round3(rpw)
	result["war"] = _round3(war)
	return result


# 1 シーズン × リーグ全選手の WAR テーブルを返す。
# 出力: [{role, player_id, name, position, war, ...}, ...]
# 主に MVP / 順位表 / バランス検証で使う。
static func season_war_table(year: int, season_number: int, league_ctx: Dictionary = {}) -> Array:
	var ctx: Dictionary = league_ctx if not league_ctx.is_empty() else build_league_context(year, season_number)
	var rows: Array = []
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		var war_row: Dictionary = season_war(record, ctx)
		if war_row.is_empty():
			continue
		war_row["team_id"] = record.team_id
		rows.append(war_row)
	rows.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary).get("war", 0.0)) > float((b as Dictionary).get("war", 0.0))
	)
	return rows


# 当該シーズンの全選手 WAR を野手/投手で合計し、配分・per-team・負WAR率・参照目標・
# ベンチマーク選手WARを返す。RecordStore に当該シーズンの記録が存在する間に呼ぶこと。
#   meta: {num_teams: int, games_per_team: float} を渡すと参照プール(.294基準)も計算する。
static func league_war_summary(year: int, season_number: int, league_ctx: Dictionary = {}, meta: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = league_ctx if not league_ctx.is_empty() else build_league_context(year, season_number, meta)
	var batting_war_total: float = 0.0
	var pitching_war_total: float = 0.0
	var batter_count: int = 0
	var pitcher_count: int = 0
	var negative_batters: int = 0
	var negative_pitchers: int = 0
	var batting_pa_total: int = 0
	var pitching_ip_total: float = 0.0
	var team_ids: Dictionary = {}
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		var war_row: Dictionary = season_war(record, ctx)
		if war_row.is_empty():
			continue
		var role: String = str(war_row.get("role", ""))
		var war: float = float(war_row.get("war", 0.0))
		if record.team_id > 0:
			team_ids[record.team_id] = true
		if role == "pitcher":
			var ip: float = float(war_row.get("ip", 0.0))
			if ip <= 0.0:
				continue
			pitching_war_total += war
			pitcher_count += 1
			pitching_ip_total += ip
			if war < 0.0:
				negative_pitchers += 1
		else:
			var pa: int = int(war_row.get("pa", 0))
			if pa <= 0:
				continue
			batting_war_total += war
			batter_count += 1
			batting_pa_total += pa
			if war < 0.0:
				negative_batters += 1

	var total_war: float = batting_war_total + pitching_war_total
	var num_teams: int = int(meta.get("num_teams", ctx.get("num_teams", team_ids.size())))
	var games_per_team: float = float(meta.get("games_per_team", ctx.get("games_per_team", 0.0)))
	var team_divisor: float = float(max(1, num_teams))
	return {
		"year": year,
		"season_number": season_number,
		"num_teams": num_teams,
		"games_per_team": games_per_team,
		"rpw": _round3(float(ctx.get("rpw", 0.0))),
		"batting_war_total": _round3(batting_war_total),
		"pitching_war_total": _round3(pitching_war_total),
		"total_war": _round3(total_war),
		"batting_share": _round3(batting_war_total / total_war) if total_war > 0.0 else 0.0,
		"pitching_share": _round3(pitching_war_total / total_war) if total_war > 0.0 else 0.0,
		"batting_war_per_team": _round3(batting_war_total / team_divisor),
		"pitching_war_per_team": _round3(pitching_war_total / team_divisor),
		"batter_count": batter_count,
		"pitcher_count": pitcher_count,
		"batting_pa_total": batting_pa_total,
		"pitching_ip_total": _round3(pitching_ip_total),
		"negative_batters": negative_batters,
		"negative_pitchers": negative_pitchers,
		"benchmarks": average_player_war_benchmarks(ctx),
		"method": ctx.get("war_method", {}) as Dictionary,
	}


# 計測: 平均的な選手の参照 WAR をリーグ context から解析的に求める。
static func average_player_war_benchmarks(league_ctx: Dictionary) -> Dictionary:
	var rpw: float = float(league_ctx.get("rpw", 0.0))
	var replacement_runs_per_pa: float = float(league_ctx.get("replacement_runs_per_pa", 0.0))
	var batter_war_per_600: float = 0.0
	var starter_war_per_162: float = 0.0
	var reliever_war_per_60: float = 0.0
	if rpw > 0.0:
		batter_war_per_600 = replacement_runs_per_pa * BENCHMARK_BATTER_PA / rpw
		starter_war_per_162 = PITCHER_STARTER_REPLACEMENT_WPG * (BENCHMARK_STARTER_IP / 9.0)
		reliever_war_per_60 = PITCHER_RELIEVER_REPLACEMENT_WPG * (BENCHMARK_RELIEVER_IP / 9.0)
	return {
		"avg_batter_war_per_600_pa": _round3(batter_war_per_600),
		"avg_starter_war_per_162_ip": _round3(starter_war_per_162),
		"avg_reliever_war_per_60_ip": _round3(reliever_war_per_60),
	}


# 指定チームのポジション別 WAR を集計する。「戦力の穴」分析の中核。
# - 各選手の WAR を主守備位置 (advanced_stats.primary_uzr_position が >0 ならそれ、
#   なければ record.position) に帰属させる。
# - position 別に war_total / starter_war (= 主力 1 名分) / depth_war / players 配列を返す。
# - 投手は position=1 にまとめる。
#
# 戻り値:
#   {
#     year, season_number, team_id,
#     positions: {
#       2: {position: 2, label: "C",  war_total: 1.8, starter_war: 1.5, depth_war: 0.3, players: [...]},
#       ...
#       1: { ... pitchers aggregate ... }
#     },
#     team_war: float (全選手 WAR 合計)
#   }
static func team_position_war(team_id: int, year: int, season_number: int, league_ctx: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = league_ctx if not league_ctx.is_empty() else build_league_context(year, season_number)
	var by_position: Dictionary = {}
	var team_war: float = 0.0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		if record.team_id != team_id:
			continue
		var war_row: Dictionary = season_war(record, ctx)
		if war_row.is_empty():
			continue
		# 帰属ポジション: 投手 1 / それ以外は primary_uzr_position 優先、無ければ record.position
		var attribution_position: int = 0
		if str(war_row.get("role", "")) == "pitcher":
			attribution_position = 1
		else:
			attribution_position = int(war_row.get("primary_uzr_position", 0))
			if attribution_position <= 0:
				attribution_position = record.position
		if attribution_position <= 0:
			continue
		if not by_position.has(attribution_position):
			by_position[attribution_position] = {
				"position": attribution_position,
				"label": _position_label(attribution_position),
				"war_total": 0.0,
				"starter_war": 0.0,
				"depth_war": 0.0,
				"players": [],
			}
		var bucket: Dictionary = by_position[attribution_position] as Dictionary
		var entry: Dictionary = {
			"player_id": int(war_row.get("player_id", 0)),
			"name": str(war_row.get("name", "")),
			"war": float(war_row.get("war", 0.0)),
			"role": str(war_row.get("role", "")),
		}
		(bucket["players"] as Array).append(entry)
		bucket["war_total"] = float(bucket["war_total"]) + float(war_row.get("war", 0.0))
		team_war += float(war_row.get("war", 0.0))
		by_position[attribution_position] = bucket

	# 各ポジションで starter_war (=最大 WAR の選手 1 名分) / depth_war を確定。
	for key in by_position.keys():
		var bucket: Dictionary = by_position[key] as Dictionary
		var players: Array = bucket["players"] as Array
		players.sort_custom(func(a, b) -> bool:
			return float((a as Dictionary).get("war", 0.0)) > float((b as Dictionary).get("war", 0.0))
		)
		var starter_war: float = 0.0
		if not players.is_empty():
			starter_war = float((players[0] as Dictionary).get("war", 0.0))
		bucket["players"] = players
		bucket["starter_war"] = _round3(starter_war)
		bucket["war_total"] = _round3(float(bucket["war_total"]))
		bucket["depth_war"] = _round3(float(bucket["war_total"]) - starter_war)
		by_position[key] = bucket

	return {
		"year": year,
		"season_number": season_number,
		"team_id": team_id,
		"positions": by_position,
		"team_war": _round3(team_war),
	}


# リーグ全チームのポジション別 WAR ランドスケープ。「戦力分析ビュー」「ドラフト戦略」が共用する。
# 戻り値:
#   {
#     year, season_number,
#     league_average: {position: {starter_war: float, war_total: float}},
#     teams: {team_id: {team_id, positions: {pos: {starter_war, war_total, depth_war, deficit, players}}, team_war}}
#   }
#   deficit = max(0, league_average.starter_war - team.starter_war) で、各チーム × ポジションの
#   「穴の深さ」を表す。
static func build_position_war_landscape(year: int, season_number: int, teams: Array, league_ctx: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = league_ctx if not league_ctx.is_empty() else build_league_context(year, season_number)
	var teams_out: Dictionary = {}
	var league_starter_by_pos: Dictionary = {}
	var league_total_by_pos: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var tw: Dictionary = team_position_war(team.id, year, season_number, ctx)
		teams_out[team.id] = tw
		var positions: Dictionary = tw.get("positions", {}) as Dictionary
		for pos_key in positions.keys():
			var pos: int = int(pos_key)
			var bucket: Dictionary = positions[pos_key] as Dictionary
			if not league_starter_by_pos.has(pos):
				league_starter_by_pos[pos] = []
			if not league_total_by_pos.has(pos):
				league_total_by_pos[pos] = []
			(league_starter_by_pos[pos] as Array).append(float(bucket.get("starter_war", 0.0)))
			(league_total_by_pos[pos] as Array).append(float(bucket.get("war_total", 0.0)))

	var league_average: Dictionary = {}
	for pos_key in league_starter_by_pos.keys():
		var starter_vals: Array = league_starter_by_pos[pos_key] as Array
		var total_vals: Array = league_total_by_pos[pos_key] as Array
		var s_sum: float = 0.0
		var t_sum: float = 0.0
		for v in starter_vals:
			s_sum += float(v)
		for v in total_vals:
			t_sum += float(v)
		var divisor: float = float(max(1, starter_vals.size()))
		league_average[int(pos_key)] = {
			"starter_war": _round3(s_sum / divisor),
			"war_total": _round3(t_sum / divisor),
		}

	# 各チームに deficit を埋め込む
	for team_id_key in teams_out.keys():
		var tw: Dictionary = teams_out[team_id_key] as Dictionary
		var positions: Dictionary = tw.get("positions", {}) as Dictionary
		for pos_key in positions.keys():
			var bucket: Dictionary = positions[pos_key] as Dictionary
			var avg_starter: float = float((league_average.get(int(pos_key), {}) as Dictionary).get("starter_war", 0.0))
			var team_starter: float = float(bucket.get("starter_war", 0.0))
			bucket["deficit"] = _round3(max(0.0, avg_starter - team_starter))
			bucket["surplus"] = _round3(max(0.0, team_starter - avg_starter))
			positions[pos_key] = bucket
		tw["positions"] = positions
		teams_out[team_id_key] = tw

	return {
		"year": year,
		"season_number": season_number,
		"league_average": league_average,
		"teams": teams_out,
	}


static func _empty_war_result() -> Dictionary:
	return {
		"role": "",
		"player_id": 0,
		"name": "",
		"position": 0,
		"war": 0.0,
	}


static func _position_label(position: int) -> String:
	match position:
		1: return "P"
		2: return "C"
		3: return "1B"
		4: return "2B"
		5: return "3B"
		6: return "SS"
		7: return "LF"
		8: return "CF"
		9: return "RF"
		_: return "P%d" % position


static func _round3(value: float) -> float:
	return round(value * 1000.0) / 1000.0


# --- 守備指標(OAA/UZR)のポジション別ゼロセンタリング ---

static func _accumulate_float_map(target: Dictionary, source: Dictionary) -> void:
	for key_value in source.keys():
		var key: String = str(key_value)
		target[key] = float(target.get(key, 0.0)) + float(source[key_value])


static func _accumulate_int_map(target: Dictionary, source: Dictionary) -> void:
	for key_value in source.keys():
		var key: String = str(key_value)
		target[key] = int(target.get(key, 0)) + int(source[key_value])


# ポジション別の「守備機会あたり平均値」を返す（センタリング係数）。
static func _per_chance_map(totals: Dictionary, chances: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key_value in totals.keys():
		var key: String = str(key_value)
		var c: int = int(chances.get(key, 0))
		result[key] = float(totals[key_value]) / float(c) if c > 0 else 0.0
	return result


# 1選手の守備指標を、ctx の fielding_center を使ってポジション別にゼロセンタリングする。
# 各ポジションで「値 − 平均/機会 × 当該選手の機会数」を引き、リーグ合計が 0 になるようにする。
# 返す dict は ad_dict にマージして表示/WAR に使う。
static func recenter_fielding(ad_dict: Dictionary, league_ctx: Dictionary) -> Dictionary:
	var center: Dictionary = league_ctx.get("fielding_center", {}) as Dictionary
	var chances_by_pos: Dictionary = ad_dict.get("fielding_chances_by_position", {}) as Dictionary
	var oaa_by_pos: Dictionary = ad_dict.get("oaa_by_position", {}) as Dictionary
	var rngr_by_pos: Dictionary = ad_dict.get("rngr_by_position", {}) as Dictionary
	var errr_by_pos: Dictionary = ad_dict.get("errr_by_position", {}) as Dictionary
	var dpr_by_pos: Dictionary = ad_dict.get("dpr_by_position", {}) as Dictionary

	var oaa_center: Dictionary = center.get("oaa_per_chance_by_position", {}) as Dictionary
	var rngr_center: Dictionary = center.get("rngr_per_chance_by_position", {}) as Dictionary
	var errr_center: Dictionary = center.get("errr_per_chance_by_position", {}) as Dictionary
	var dpr_center: Dictionary = center.get("dpr_per_chance_by_position", {}) as Dictionary

	var oaa_total: float = 0.0
	var rngr_total: float = 0.0
	var errr_total: float = 0.0
	var dpr_total: float = 0.0
	var oaa_infield: float = 0.0
	var oaa_outfield: float = 0.0
	var oaa_runs: float = 0.0
	for key_value in chances_by_pos.keys():
		var key: String = str(key_value)
		var position: int = int(key)
		var c: float = float(int(chances_by_pos[key_value]))
		var oaa_c: float = float(oaa_by_pos.get(key, 0.0)) - float(oaa_center.get(key, 0.0)) * c
		var rngr_c: float = float(rngr_by_pos.get(key, 0.0)) - float(rngr_center.get(key, 0.0)) * c
		var errr_c: float = float(errr_by_pos.get(key, 0.0)) - float(errr_center.get(key, 0.0)) * c
		var dpr_c: float = float(dpr_by_pos.get(key, 0.0)) - float(dpr_center.get(key, 0.0)) * c
		oaa_total += oaa_c
		oaa_runs += oaa_c * _oaa_run_value_for_position(position)
		rngr_total += rngr_c
		errr_total += errr_c
		dpr_total += dpr_c
		if position >= 2 and position <= 6:
			oaa_infield += oaa_c
		elif position >= 7 and position <= 9:
			oaa_outfield += oaa_c

	var uzr: float = rngr_total + errr_total + dpr_total
	var pos_adj: float = float(ad_dict.get("positional_adjustment_runs", 0.0))
	return {
		"oaa": _round3(oaa_total),
		"oaa_total": _round3(oaa_total),
		"oaa_infield": _round3(oaa_infield),
		"oaa_outfield": _round3(oaa_outfield),
		"oaa_runs": _round3(oaa_runs),
		"rngr": _round3(rngr_total),
		"errr": _round3(errr_total),
		"dpr": _round3(dpr_total),
		"uzr": _round3(uzr),
		"drs": _round3(uzr),
		"fielding_runs": _round3(oaa_runs),
		"def_runs": _round3(oaa_runs + pos_adj),
	}


static func _oaa_run_value_for_position(position: int) -> float:
	if position >= 7 and position <= 9:
		return OAA_OUTFIELD_RUNS_PER_OUT
	return OAA_INFIELD_RUNS_PER_OUT
