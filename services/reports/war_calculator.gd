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
# 投手 replacement の役割比 (FanGraphs: 先発 0.12 / 救援 0.03 wins/9IP, 比 4:1)。
# 絶対値は build_league_context が pitching プールに合わせ pitcher_replacement_scale で正規化するので、
# ここは「先発:救援の相対比」を表す参照値(=救援は先発の 1/4 しか replacement クッションを得ない)。
const PITCHER_REPL_STARTER_PER_9: float = 0.12
const PITCHER_REPL_RELIEVER_PER_9: float = 0.03

# --- replacement 枠組み (現実準拠: 目標を決めて正規化) ---
# 現実の WAR(FanGraphs/B-Ref)は「replacement 勝率 .294 → リーグ総 WAR プール」を入力前提とし、
# 野手/投手の配分を正規化で強制する。ここでも同思想を採り、毎季リーグ実測(総投球回)から
# プールを算出し、野手 replacement_runs_per_pa と投手 replacement_factor を逆算して配分を合わせる。
# プール = (0.500 - REPLACEMENT_WIN_PCT) × リーグ総チーム試合数。総チーム試合数 = 総IP/9 なので
# num_teams/試合数の外部入力なしに league context だけで自動校正できる(分布ドリフトにも追従)。
const REPLACEMENT_WIN_PCT: float = 0.294    # replacement チームの勝率 (MLB/NPB 共通の標準)。
# 野手 : 投手 の WAR 配分。NPB は投手分業が濃いため MLB(57:43)より投手寄せの 54:46 を採用。
const BATTING_WAR_SHARE: float = 0.54
# 平均選手ベンチマーク表示用の参照稼働量(WAR 算出には使わない)。
const BENCHMARK_BATTER_PA: float = 600.0    # 「平均的フル稼働野手」の参照打席数。
const BENCHMARK_STARTER_IP: float = 162.0   # 「平均的フル稼働先発」の参照投球回。
const BENCHMARK_RELIEVER_IP: float = 60.0   # 「平均的フル稼働救援」の参照投球回。
# 当該シーズンのリーグ全体集計からリーグコンテキストを構築する。
# 戻り値は以下のキーを持つ Dictionary:
#   year, season_number
#   total_pa            (リーグ全打席)
#   total_woba_num      (野手のwOBA分子合計, 投手打撃は除外)
#   total_woba_denom    (野手のwOBA分母合計, 投手打撃は除外)
#   lg_woba             (打席加重リーグwOBA = 野手のみ。wRAA センタリングの基準)
#   lg_runs             (リーグ総得点)
#   lg_outs             (リーグ総アウト)
#   lg_ip               (リーグ総イニング)
#   lg_runs_per_inning, lg_runs_per_team_game
#   rpw                 (Runs Per Win)
#   lg_hr, lg_bb, lg_hbp, lg_k (FIP用、投手側集計)
#   lg_fip_raw          (FIP 式の右辺一次項 = (13HR+3(BB+HBP)-2K)/IP)
#   lg_era              (リーグERA)
#   lg_fip_constant     (cFIP = lgERA - lg_fip_raw)
#   replacement_runs_per_pa     (野手 replacement, batting_pool 逆算)
#   pitcher_replacement_scale   (投手 役割別 replacement の正規化スケール, pitching_pool 逆算)
#   lg_bsr_per_pa               (BsR ゼロセンタリング係数)
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
	# 役割按分した replacement クッションの正規化用: Σ (役割重み × IP)。役割重みは GS/G で
	# 先発(0.12)/救援(0.03)をブレンドした値。pitcher_replacement_scale の逆算に使う。
	var total_pitcher_role_ip: float = 0.0
	# 野手 WAR を受ける選手(=投手登板以外)の PA と BsR 合計。replacement_runs_per_pa の逆算と
	# BsR のゼロセンタリングに使う。投手の打撃は野手 WAR に混ぜないので除外する。
	var total_batter_pa: int = 0
	var total_batter_bsr: float = 0.0
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
			# 野手 WAR を受ける選手のみ(投手登板者は除外)を lg_wOBA / replacement / BsR の母集団とする。
			# 投手の打撃(no-DH)を lg_wOBA に混ぜると野手の wRAA が一律かさ上げされるため除外する。
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
			var p_ip: float = float(pitcher.outs_pitched) / 3.0
			var gss: float = clamp(float(pitcher.starts) / float(pitcher.games), 0.0, 1.0) if pitcher.games > 0 else 0.0
			total_pitcher_role_ip += (PITCHER_REPL_STARTER_PER_9 * gss + PITCHER_REPL_RELIEVER_PER_9 * (1.0 - gss)) * p_ip

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

	# --- replacement を「目標プールへ正規化」で逆算する (現実準拠) ---
	# プール = (0.500 - REPLACEMENT_WIN_PCT) × 総チーム試合数。総チーム試合数 = 総IP/9。
	var total_team_games: float = lg_ip / 9.0
	var war_pool: float = max(0.0, (0.5 - REPLACEMENT_WIN_PCT)) * total_team_games
	var batting_pool: float = war_pool * BATTING_WAR_SHARE
	var pitching_pool: float = war_pool * (1.0 - BATTING_WAR_SHARE)
	# 野手: wRAA/BsR(センタ後)/OAA/守備位置補正の総和は ≈0 なので、リーグ野手 WAR 総和は
	# replacement 成分のみで決まる。Σ(rppa × PA)/RPW = batting_pool となるよう rppa を逆算。
	var replacement_runs_per_pa: float = 0.0
	if total_batter_pa > 0 and rpw > 0.0:
		replacement_runs_per_pa = batting_pool * rpw / float(total_batter_pa)
	# BsR ゼロセンタリング係数 (リーグ平均走塁/PA)。各野手から PA 比例で引きリーグ合計を 0 にする。
	var lg_bsr_per_pa: float = 0.0
	if total_batter_pa > 0:
		lg_bsr_per_pa = total_batter_bsr / float(total_batter_pa)
	# 投手: 役割別 replacement(先発0.12:救援0.03)を pitching_pool に合わせ正規化する scale を逆算。
	# 平均比 (lgFIP-FIP) の総和は 0 なので、Σ投手WAR = (scale/9)×Σ(役割重み×IP) = pitching_pool。
	# → scale = 9 × pitching_pool / Σ(役割重み×IP)。これで投手プール総量は保ちつつ先発厚め/救援薄めに再配分。
	var pitcher_replacement_scale: float = 0.0
	if total_pitcher_role_ip > 0.0:
		pitcher_replacement_scale = pitching_pool * 9.0 / total_pitcher_role_ip

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
		"total_batter_pa": total_batter_pa,
		"lg_bsr_per_pa": lg_bsr_per_pa,
		"war_pool": war_pool,
		"batting_pool": batting_pool,
		"pitching_pool": pitching_pool,
		"replacement_runs_per_pa": replacement_runs_per_pa,
		"pitcher_replacement_scale": pitcher_replacement_scale,
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
	# BsR(走塁ラン)はリーグ平均をゼロセンタリングしてから WAR に使う(守備指標と同様、平均=0基準)。
	# 旧実装は ad.bsr_sum を素通しでリーグ合計が系統的に正となり野手 WAR を底上げしていた。
	var bsr: float = ad.bsr_sum - float(league_ctx.get("lg_bsr_per_pa", 0.0)) * float(pa)
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
	var lg_fip: float = lg_era  # cFIP の定義により lgFIP ≡ lgERA
	var rpw: float = float(league_ctx.get("rpw", 10.0))
	# 役割別 replacement: 先発と救援で replacement 水準が違う(FanGraphs: 先発0.12 / 救援0.03 wins/9IP)。
	# 比 0.12:0.03 を pitching プールに合わせて pitcher_replacement_scale で正規化した値を、
	# 平均比 (lgFIP-FIP) の勝利換算に足す。GS/G で先発寄り/救援寄りをブレンドする。
	var repl_scale: float = float(league_ctx.get("pitcher_replacement_scale", 0.0))
	var gs_share: float = clamp(float(ps.starts) / float(ps.games), 0.0, 1.0) if ps.games > 0 else 0.0
	var role_repl_per_9: float = repl_scale * (PITCHER_REPL_STARTER_PER_9 * gs_share + PITCHER_REPL_RELIEVER_PER_9 * (1.0 - gs_share))  # wins / 9IP
	var wins_above_avg_per_9: float = (lg_fip - fip) / rpw if rpw > 0.0 else 0.0
	var war_per_9: float = wins_above_avg_per_9 + role_repl_per_9
	var war: float = war_per_9 * ip / 9.0
	# レポート継続用に runs ベースの raa も残す (raa9 = replacement 超のラン/9)。
	var raa9: float = war_per_9 * rpw
	var raa: float = raa9 * ip / 9.0

	result["role"] = "pitcher"
	result["player_id"] = record.player_id
	result["name"] = record.name
	result["position"] = record.position
	result["ip"] = _round3(ip)
	result["fip"] = _round3(fip)
	result["era"] = _round3(ps.era())
	result["lg_fip"] = _round3(lg_fip)
	result["lg_fip_constant"] = _round3(lg_fip_constant)
	result["gs_share"] = _round3(gs_share)
	result["role_replacement_runs_per_9"] = _round3(role_repl_per_9 * rpw)
	# 旧フィールド互換: 実効 replacement 係数 (lgFIP 比)。役割で先発>救援 になる。
	result["replacement_factor"] = _round3(1.0 + (role_repl_per_9 * rpw) / lg_fip) if lg_fip > 0.0 else 0.0
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


# --- Phase 0 計測: リーグ WAR 配分サマリ ---
# 「野手は出やすく投手は伸びない/負が多い」を実数で確認するための計測。WAR 算出は変更しない。
# 当該シーズンの全選手 WAR を野手/投手で合計し、配分・per-team・負WAR率・参照目標(57:43)・
# ベンチマーク選手WAR を返す。RecordStore に当該シーズンの記録が存在する間に呼ぶこと。
#   meta: {num_teams: int, games_per_team: float} を渡すと参照プール(.294基準)も計算する。
static func league_war_summary(year: int, season_number: int, league_ctx: Dictionary = {}, meta: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = league_ctx if not league_ctx.is_empty() else build_league_context(year, season_number)
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
	var num_teams: int = int(meta.get("num_teams", team_ids.size()))
	var games_per_team: float = float(meta.get("games_per_team", 0.0))
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
	}


# 計測: 「平均的な選手」の WAR をリーグ context から解析的に求める。平均投手(FIP=lgFIP)は
# 平均比が 0 なので役割別 replacement クッションだけが残る。先発(GS/G=1)と救援(GS/G=0)で
# 値が分かれ、野手(600PA)との釣り合いを可視化する。
static func average_player_war_benchmarks(league_ctx: Dictionary) -> Dictionary:
	var rpw: float = float(league_ctx.get("rpw", 0.0))
	var replacement_runs_per_pa: float = float(league_ctx.get("replacement_runs_per_pa", 0.0))
	var repl_scale: float = float(league_ctx.get("pitcher_replacement_scale", 0.0))
	var batter_war_per_600: float = 0.0
	if rpw > 0.0:
		batter_war_per_600 = replacement_runs_per_pa * BENCHMARK_BATTER_PA / rpw
	# 平均投手は wins/9IP = 役割別 replacement のみ。先発=scale×0.12 / 救援=scale×0.03。
	var starter_war_per_9: float = repl_scale * PITCHER_REPL_STARTER_PER_9
	var reliever_war_per_9: float = repl_scale * PITCHER_REPL_RELIEVER_PER_9
	return {
		"avg_batter_war_per_600_pa": _round3(batter_war_per_600),
		"avg_starter_war_per_162_ip": _round3(starter_war_per_9 * BENCHMARK_STARTER_IP / 9.0),
		"avg_reliever_war_per_60_ip": _round3(reliever_war_per_9 * BENCHMARK_RELIEVER_IP / 9.0),
	}


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
