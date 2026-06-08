extends RefCounted
class_name PSWarCalculator

# WAR (Wins Above Replacement) 算出モジュール。
#
# 設計方針:
# - リーグ実測から定数を自動校正 (得点環境への自動追従)。固定の RPW やリプレイスメント
#   は持たない (野球シーズン長 = 143 試合, NPB 型)。
# - 野手 WAR = (wRAA + BSR + OAA_runs + 守備位置補正 + リプレイスメント) / RPW
#   - wRAA は当該シーズンの lg_woba をセンタリングに使用
#   - OAA_runs / 守備位置補正 は PSAdvancedStats.to_dict() の値を使用 (OAA × 0.83 + Pos)
# - 投手 WAR = ((lgFIP × replacement_factor - FIP) / 9 × IP) / RPW
#   - FIP = (13·HR + 3·(BB+HBP) - 2·K) / IP + cFIP
#   - cFIP は当該シーズンの lgERA から自動算出
# - RPW (Runs Per Win, 1 勝の限界得点) は Tom Tango 式の近似:
#   RPW = 1.5 + sqrt(((lg_runs_per_team_game × 2) / 9) × 18) を簡略化して
#   RPW ≈ 9 × √(R/G/inning × 2) + 0.5 のような形を取らず、より素直に
#   RPW = lg_runs_per_team_game + 3.0 で近似 (NPB 環境では ~7-10、検証で調整)。
# - リプレイスメント水準: 平均選手 ≈ +2 WAR / シーズン (600 PA) になるよう
#   replacement_runs_per_pa を逆算。
#
# 主要 API:
#   build_league_context(year, season_number) -> Dictionary
#   season_war(record, league_ctx)             -> Dictionary  (batter/pitcher dispatch)
#   calculate_batter_war(record, league_ctx)   -> Dictionary
#   calculate_pitcher_war(record, league_ctx)  -> Dictionary
#   team_position_war(team_id, year, season_number, league_ctx) -> Dictionary
#   season_war_table(year, season_number, league_ctx) -> Array

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")

# wOBA 重みは PSAdvancedStats と同期。リーグ平均 wOBA は実測から算出するので
# WOBA_SCALE のみここに置く (= 1 標準偏差 wOBA = 1.20 runs/PA というFanGraphs定数)。
const WOBA_SCALE: float = 1.20
# 投手 FIP の repl 係数 (FanGraphs: 先発 1.10 / 中継ぎ 1.07)。今は単一値で運用。
const REPLACEMENT_FACTOR_PITCHER: float = 1.10
# 平均選手 ≈ +2 WAR となるよう逆算 (600 PA を 1 シーズンの主力打席数とする)。
const REPLACEMENT_WAR_PER_FULL_SEASON: float = 2.0
const FULL_SEASON_PA: float = 600.0
# 当該シーズンのリーグ全体集計からリーグコンテキストを構築する。
# 戻り値は以下のキーを持つ Dictionary:
#   year, season_number
#   total_pa            (リーグ全打席)
#   total_woba_num      (wOBA分子合計)
#   total_woba_denom    (wOBA分母合計)
#   lg_woba             (打席加重リーグwOBA)
#   lg_runs             (リーグ総得点)
#   lg_outs             (リーグ総アウト)
#   lg_ip               (リーグ総イニング)
#   lg_runs_per_inning, lg_runs_per_team_game
#   rpw                 (Runs Per Win)
#   lg_hr, lg_bb, lg_hbp, lg_k (FIP用、投手側集計)
#   lg_fip_raw          (FIP 式の右辺一次項 = (13HR+3(BB+HBP)-2K)/IP)
#   lg_era              (リーグERA)
#   lg_fip_constant     (cFIP = lgERA - lg_fip_raw)
#   replacement_runs_per_pa
#   replacement_factor_pitcher
static func build_league_context(year: int, season_number: int) -> Dictionary:
	var total_pa: int = 0
	var total_woba_num: float = 0.0
	var total_woba_denom: int = 0
	# 投手側集計 (FIP / ERA の母集団)
	var total_outs: int = 0
	var total_earned_runs: int = 0
	var total_runs_allowed: int = 0
	var total_hr_allowed: int = 0
	var total_bb_allowed: int = 0
	var total_hbp_allowed: int = 0
	var total_k_thrown: int = 0
	var total_batters_faced: int = 0
	# 守備指標センタリング用: ポジション別のリーグ合計（OAA/RngR/ErrR/DPR と守備機会）。
	var lg_oaa_by_pos: Dictionary = {}
	var lg_rngr_by_pos: Dictionary = {}
	var lg_errr_by_pos: Dictionary = {}
	var lg_dpr_by_pos: Dictionary = {}
	var lg_chances_by_pos: Dictionary = {}
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != year or record.season_number != season_number:
			continue
		var ad: PSAdvancedStats = record.advanced_stats
		if ad != null:
			total_pa += ad.plate_appearances
			total_woba_num += ad.woba_numerator
			total_woba_denom += ad.woba_denominator
			_accumulate_float_map(lg_oaa_by_pos, ad.oaa_by_position)
			_accumulate_float_map(lg_rngr_by_pos, ad.rngr_by_position)
			_accumulate_float_map(lg_errr_by_pos, ad.errr_by_position)
			_accumulate_float_map(lg_dpr_by_pos, ad.dpr_by_position)
			_accumulate_int_map(lg_chances_by_pos, ad.fielding_chances_by_position)
		var pitcher: PSPitcherStats = record.pitcher_stats
		if pitcher != null and pitcher.outs_pitched > 0:
			total_outs += pitcher.outs_pitched
			total_earned_runs += pitcher.earned_runs
			total_runs_allowed += pitcher.runs_allowed
			total_hr_allowed += pitcher.home_runs_allowed
			total_bb_allowed += pitcher.walks
			total_hbp_allowed += pitcher.hit_batters
			total_k_thrown += pitcher.strikeouts
			total_batters_faced += pitcher.batters_faced

	var lg_woba: float = 0.0
	if total_woba_denom > 0:
		lg_woba = total_woba_num / float(total_woba_denom)

	var lg_ip: float = float(total_outs) / 3.0
	var lg_runs_per_inning: float = 0.0
	if total_outs > 0:
		lg_runs_per_inning = float(total_runs_allowed) * 3.0 / float(total_outs)
	# 1 試合 = 9 イニングで両軍合計 = lg_runs_per_inning × 9 × 2、
	# 1 チーム 1 試合あたり = lg_runs_per_inning × 9
	var lg_runs_per_team_game: float = lg_runs_per_inning * 9.0
	# Tom Tango 近似: RPW = 9 × √(2 × R/I + 0.06) を素直に。
	# 得点環境 R/G/team ≈ 4.5 (MLB) なら RPW ≈ 9.6、
	# R/G/team ≈ 3.5 なら RPW ≈ 8.3。
	var rpw: float = 9.0 * sqrt(max(0.001, 2.0 * lg_runs_per_inning + 0.06))
	rpw = clamp(rpw, 6.0, 14.0)

	var lg_era: float = 0.0
	if total_outs > 0:
		lg_era = float(total_earned_runs) * 27.0 / float(total_outs)
	var lg_fip_raw: float = 0.0
	if lg_ip > 0.0:
		lg_fip_raw = (13.0 * float(total_hr_allowed) + 3.0 * float(total_bb_allowed + total_hbp_allowed) - 2.0 * float(total_k_thrown)) / lg_ip
	# cFIP: リーグ平均 FIP が リーグ ERA に一致するようにオフセット。
	var lg_fip_constant: float = lg_era - lg_fip_raw

	# 平均選手 ≈ +2 WAR / 600 PA となるリプレイスメント加算 (野手用)。
	# WAR = (... + replacement_runs_per_pa × PA) / RPW = +2 のとき、
	# replacement_runs_per_pa = 2 × RPW / 600。
	var replacement_runs_per_pa: float = REPLACEMENT_WAR_PER_FULL_SEASON * rpw / FULL_SEASON_PA

	# ポジション別「守備機会あたり平均」= センタリング係数。これを機会数倍して各選手から引くと
	# リーグ合計が各ポジションで 0 になる（実 UZR/OAA のゼロセンタリングと同義）。
	return {
		"year": year,
		"season_number": season_number,
		"fielding_center": {
			"oaa_per_chance_by_position": _per_chance_map(lg_oaa_by_pos, lg_chances_by_pos),
			"rngr_per_chance_by_position": _per_chance_map(lg_rngr_by_pos, lg_chances_by_pos),
			"errr_per_chance_by_position": _per_chance_map(lg_errr_by_pos, lg_chances_by_pos),
			"dpr_per_chance_by_position": _per_chance_map(lg_dpr_by_pos, lg_chances_by_pos),
		},
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
		"lg_fip_raw": lg_fip_raw,
		"lg_fip_constant": lg_fip_constant,
		"replacement_runs_per_pa": replacement_runs_per_pa,
		"replacement_factor_pitcher": REPLACEMENT_FACTOR_PITCHER,
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


# 野手 WAR を算出。advanced_stats の wraa / bsr / oaa_runs / positional_adjustment_runs と
# リプレイスメントを合計して RPW で除す。
static func calculate_batter_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	var result: Dictionary = _empty_war_result()
	result["role"] = "batter"
	if record == null or record.advanced_stats == null:
		return result
	var ad: PSAdvancedStats = record.advanced_stats
	var pa: int = ad.plate_appearances
	if pa <= 0:
		return result
	var lg_woba: float = float(league_ctx.get("lg_woba", 0.315))
	var woba_denom: int = ad.woba_denominator
	var woba: float = ad.woba()
	# wRAA はリーグ平均 wOBA をセンタリングに使う (PSAdvancedStats の固定 LEAGUE_WOBA ではなく
	# 当該シーズンの実測値を使うことで「リーグ合計 wRAA ≈ 0」を担保する)。
	var wraa: float = 0.0
	if woba_denom > 0:
		wraa = ((woba - lg_woba) / WOBA_SCALE) * float(woba_denom)
	var bsr: float = ad.bsr_sum
	var ad_dict: Dictionary = ad.to_dict()
	# 守備指標はポジション別にゼロセンタリングしてから WAR に使う（リーグ平均0基準＝実 UZR/OAA 準拠）。
	var centered_fielding: Dictionary = recenter_fielding(ad_dict, league_ctx)
	var oaa_runs: float = float(centered_fielding.get("oaa_runs", ad_dict.get("oaa_runs", 0.0)))
	var pos_adj: float = float(ad_dict.get("positional_adjustment_runs", 0.0))
	var replacement_runs: float = float(league_ctx.get("replacement_runs_per_pa", 0.0)) * float(pa)
	var rpw: float = float(league_ctx.get("rpw", 10.0))
	var total_runs: float = wraa + bsr + oaa_runs + pos_adj + replacement_runs
	var war: float = total_runs / rpw if rpw > 0.0 else 0.0

	result["role"] = "batter"
	result["player_id"] = record.player_id
	result["name"] = record.name
	result["position"] = record.position
	result["primary_uzr_position"] = int(ad_dict.get("primary_uzr_position", record.position))
	result["pa"] = pa
	result["wraa"] = _round3(wraa)
	result["bsr"] = _round3(bsr)
	result["oaa_runs"] = _round3(oaa_runs)
	result["pos_adj"] = _round3(pos_adj)
	result["replacement_runs"] = _round3(replacement_runs)
	result["total_runs"] = _round3(total_runs)
	result["rpw"] = _round3(rpw)
	result["war"] = _round3(war)
	return result


# 投手 WAR を算出。FIP を当該シーズン cFIP で組み立て、
# RAA9 = (lgFIP × replacement_factor - FIP) を 9 イニング当たりとして
# (RAA9 / 9) × IP / RPW で WAR を求める。
static func calculate_pitcher_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> Dictionary:
	var result: Dictionary = _empty_war_result()
	result["role"] = "pitcher"
	if record == null or record.pitcher_stats == null:
		return result
	var ps: PSPitcherStats = record.pitcher_stats
	if ps.outs_pitched <= 0:
		return result
	var ip: float = ps.innings_pitched()
	var lg_fip_constant: float = float(league_ctx.get("lg_fip_constant", 0.0))
	var fip: float = (13.0 * float(ps.home_runs_allowed) + 3.0 * float(ps.walks + ps.hit_batters) - 2.0 * float(ps.strikeouts)) / ip + lg_fip_constant
	var lg_era: float = float(league_ctx.get("lg_era", 0.0))
	# FanGraphs 流: pitcher_FIP_R9 = FIP、replacement_FIP_R9 = lgFIP × repl_factor
	# RAA9 = replacement_FIP_R9 - FIP、RAA = RAA9 × IP / 9
	var repl_factor: float = float(league_ctx.get("replacement_factor_pitcher", REPLACEMENT_FACTOR_PITCHER))
	var lg_fip: float = lg_era  # cFIP の定義により lgFIP ≡ lgERA
	var raa9: float = lg_fip * repl_factor - fip
	var raa: float = raa9 * ip / 9.0
	var rpw: float = float(league_ctx.get("rpw", 10.0))
	var war: float = raa / rpw if rpw > 0.0 else 0.0

	result["role"] = "pitcher"
	result["player_id"] = record.player_id
	result["name"] = record.name
	result["position"] = record.position
	result["ip"] = _round3(ip)
	result["fip"] = _round3(fip)
	result["era"] = _round3(ps.era())
	result["lg_fip"] = _round3(lg_fip)
	result["lg_fip_constant"] = _round3(lg_fip_constant)
	result["replacement_factor"] = _round3(repl_factor)
	result["raa9"] = _round3(raa9)
	result["raa"] = _round3(raa)
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


# 指定チームのポジション別 WAR を集計する。「戦力の穴」分析の中核。
# - 各選手の WAR を主守備位置 (advanced_stats.primary_uzr_position が >0 ならそれ、
#   なければ record.position) に帰属させる。
# - position 別に war_total / starter_war (= 主力 1 名分) / depth_war / players 配列を返す。
# - 投手は position=1 にまとめる (役割別の分割は Phase D 以降で詳細化)。
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
# 返す dict は ad_dict にマージして表示/WAR に使う（oaa_runs / uzr / def_runs などを上書き）。
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
	for key_value in chances_by_pos.keys():
		var key: String = str(key_value)
		var position: int = int(key)
		var c: float = float(int(chances_by_pos[key_value]))
		var oaa_c: float = float(oaa_by_pos.get(key, 0.0)) - float(oaa_center.get(key, 0.0)) * c
		var rngr_c: float = float(rngr_by_pos.get(key, 0.0)) - float(rngr_center.get(key, 0.0)) * c
		var errr_c: float = float(errr_by_pos.get(key, 0.0)) - float(errr_center.get(key, 0.0)) * c
		var dpr_c: float = float(dpr_by_pos.get(key, 0.0)) - float(dpr_center.get(key, 0.0)) * c
		oaa_total += oaa_c
		rngr_total += rngr_c
		errr_total += errr_c
		dpr_total += dpr_c
		if position >= 3 and position <= 6:
			oaa_infield += oaa_c
		elif position >= 7 and position <= 9:
			oaa_outfield += oaa_c

	var oaa_runs: float = oaa_total * PSAdvancedStats.RUN_PER_OUT
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
		"fielding_runs": _round3(uzr),
		"def_runs": _round3(oaa_runs + pos_adj),
	}
