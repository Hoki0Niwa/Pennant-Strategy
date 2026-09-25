extends RefCounted
class_name PSMlbSeasonSimulator

# 海外 (MLB) にいる選手の 1 シーズンぶんの成績と指標を、能力からの近似式で作る。打席の計算は回さない。
#
# ## 率の近似式
# 打者の K% / BB% / HR% / BABIP など、投手の被 K% / 被 BB% / 被 HR% / 被 BABIP を、能力 z の一次式を
# ロジットに通して出す (BATTER_RATE_MODELS / PITCHER_RATE_MODELS)。係数は NPB の試合エンジンが出した
# 年度成績 (初期世界の開始前の年、打者 200 打席以上・投手 150 打者以上) に当てはめた値で、
# 「この能力ならこの成績」という試合エンジンの傾向を写している。
#
# ## NPB → MLB の換算
# K% / BB% / HR% / BABIP は「NPB のリーグ平均に対する本人の差」を MLB のリーグ平均に乗せ、MLB の相手が強いぶん
# (BATTER_/PITCHER_TRANSLATION) だけずらす (ロジットで足し引き):
#   logit(MLB での率) = logit(MLB のリーグ平均) + [能力の式のロジット − NPB のリーグ平均のロジット] + 換算
# NPB のリーグ平均は今季の NPB 一軍の能力平均で式を評価したもの (build_league)。リーグ全体の打撃環境
# (MLB は三振と本塁打が多い) はリーグ平均の差として入り、換算は「同じ選手が移ったときの、環境の差を除いた変化」。
# 換算は実際に NPB と MLB を行き来した選手の前後の成績 (FanGraphs の NPB/MLB 成績、2018〜2026) で測った値で、
# 下の定数のコメントに由来と狙いがある。MLB 平均級の選手 (換算後にリーグ平均と同じ率) の wRC+ は 100 になる。
#
# ## 季の成績
# 出場機会 (試合 / 先発 / 登板) を MLB での見込み (率から出した wRC+ / FIP−) から決め、打席・対戦打者ごとに
# 率で結果を引いて数えるので季ごとにばらつく。得点・打点・自責点は結果の内訳から一次式で出す (NPB の年度成績に
# 当てはめた係数に、MLB の得点水準へ合わせる倍率 MLB_RUNS_SCALE / MLB_EARNED_RUNS_SCALE を掛ける)。
# 勝敗はピタゴラス勝率、セーブ・ホールドは登板のうちリード場面の割合で近似する。
#
# ## 指標
# 野手は wOBA / wRC+ / BsR / 守備 / 守備位置補正 / 代替水準から WAR、投手は FIP から WAR を、
# FanGraphs の式を簡略化して上の MLB リーグ平均に対して計算する。
#
# ## 乱数
# 選手・年ごとの専用ストリーム (Rng.begin_game_stream) で回し、共有の乱数列を消費しない。
# 同じ世界 seed・年・選手なら同じ成績になる。

# MLB のリーグ平均の率 (FanGraphs の MLB 2023〜2025 の平均。k / bb / hr は 1 打席あたり、babip はインプレー打球あたり)。
const MLB_LEAGUE_RATES: Dictionary = {"k": 0.225, "bb": 0.084, "hr": 0.031, "babip": 0.291}
# NPB → MLB の換算 (ロジット、リーグ平均の差を除いた本人の変化)。
# 元の実測: 2018〜2026 に NPB から MLB へ移った選手 (打者 8 / 投手 42) と MLB から NPB へ移った選手
# (打者 43 / 投手 67) の直前の季と直後の季を、打席/対戦打者の少ない方で重み付けして平均した値。
# 移る選手は直前の季が好調 (NPB→MLB) / 不調 (MLB→NPB) なことが多いので、両方向の平均 (NPB→MLB の値と
# MLB→NPB の値の符号反転の平均) を実力差の目安にする: 打者 K +0.15 / BB −0.24 / HR −0.61 / BABIP −0.07、
# 投手 K −0.26 / BB +0.11 / HR +0.31 / BABIP +0.02。
# 移籍組は NPB での成績も見て選ぶ (OverseasService) ので、NPB 最終季は好調に寄り、その揺り戻しは別に乗る。
# そのうえで内訳を実際の移籍組 (打者は四球と長打が減り BABIP はあまり変わらない、投手は奪三振が減り
# 与四球・被本塁打が増える) に合わせるため、打者の BB / HR と投手の K / BB / HR を NPB→MLB の値の側へ、
# 打者の BABIP を 0 の側へ寄せてある。
# NPB の成績上位 10 人を MLB に置いたとき: 打者 wRC+ −54 (実際の移籍組 −53〜−59)、K% +6.6pt、BB% −1.6pt、
# ISO −.052。投手 FIP− +44 (揺り戻し込み。能力上位 10 人では +29)、K% −2.4pt、BB% +2.4pt、
# 被本塁打 +2.6pt (実際の日本人投手の移籍組 FIP +2.2 / K% −2.5pt / BB% +2.8pt / 被本塁打 +2.2pt)。
# 大きくすると (打者は負へ、投手は正へ) MLB での成績が下がる。
const BATTER_TRANSLATION: Dictionary = {"k": 0.146, "bb": -0.4, "hr": -0.75, "babip": -0.02}
const PITCHER_TRANSLATION: Dictionary = {"k": -0.36, "bb": 0.22, "hr": 0.42, "babip": 0.04}

const MLB_GAMES: int = 162
const MLB_STARTS: int = 32
const MLB_RELIEF_APPEARANCES: int = 62

# --- 出場機会 ---
# MLB での見込み (打者は wRC+、投手は FIP−) が MLB 平均ちょうどの選手が試合/登板に出る割合と、
# 見込みが 1 ポイント上回る/下回るごとの増減。下限は控えとしてたまに出る程度、上限は故障や休養で出ない分。
const BASE_PLAY_SHARE: float = 0.85
const PLAY_SHARE_PER_WRC_PLUS: float = 0.012
const PLAY_SHARE_PER_FIP_MINUS: float = 0.008
const MIN_PLAY_SHARE: float = 0.15
const MAX_PLAY_SHARE: float = 0.95
# 1 試合あたりの打席。上位打線に入るほど多い (見込みの wRC+ 1 ポイントあたり)。
const PA_PER_GAME: float = 4.1
const PA_PER_GAME_PER_WRC_PLUS: float = 0.004
const MIN_PA_PER_GAME: float = 3.6
const MAX_PA_PER_GAME: float = 4.5
# 先発 1 試合あたりの投球回。Pit_Stamina が NPB 一軍平均より 1σ 高いごとに伸びる。
# NPB の投手は 1 回あたりの球数が少ないので、MLB の平均 (約 5 回 1/3) より長めに置いてある。
const INNINGS_PER_START: float = 5.6
const INNINGS_PER_START_PER_Z: float = 0.5
const MIN_INNINGS_PER_START: float = 4.3
const MAX_INNINGS_PER_START: float = 7.2
const RELIEF_OUTS_PER_APPEARANCE: int = 3

# --- 率の近似式 (ロジット = intercept + Σ 係数 × z) ---
# 打者: k / bb / hr は 1 打席あたり、babip はインプレー打球あたり、double_share / triple_share は
# 本塁打以外の安打に占める割合、steal_attempt は出塁 (単打・四球・死球) あたりの盗塁企図、
# steal_success は企図あたりの成功。
const BATTER_RATE_MODELS: Dictionary = {
	"k": {"intercept": -1.0771, "Bat_KAvoid": -0.3743, "Bat_Impact": 0.0649, "Bat_Aggression": -0.0346, "Run_Judgment": -0.0173},
	"bb": {"intercept": -3.1576, "Bat_BBCreate": 0.3732, "Bat_KAvoid": 0.0493, "Run_Judgment": 0.0206},
	"hr": {"intercept": -5.0526, "Bat_Impact": 0.3468, "Bat_Loft": 0.2347, "Bat_Barrel": 0.1163, "Bat_BBCreate": -0.0866},
	"babip": {"intercept": -1.262, "Bat_Impact": 0.1154, "Bat_Barrel": 0.0259, "Run_Speed": 0.0731},
	"double_share": {"intercept": -1.5411, "Bat_Impact": 0.0671},
	"triple_share": {"intercept": -4.6726, "Run_Speed": 0.3501, "Bat_Barrel": 0.0348, "Bat_Loft": 0.0507},
	"steal_attempt": {"intercept": -4.4045, "Run_Speed": 0.5124, "Run_Steal": 0.6417, "Bat_Impact": -0.0668, "Bat_BBCreate": -0.0955, "Bat_Aggression": 0.0801},
	"steal_success": {"intercept": -0.3142, "Run_Steal": 0.356, "Run_Speed": 0.2043, "Bat_Aggression": 0.0881},
}
# 打者の 1 打席あたりの死球・犠飛・併殺打・犠打 (能力でほとんど変わらないので定数)。犠打は MLB ではほぼ無い。
const BATTER_HIT_BY_PITCH_RATE: float = 0.0072
const BATTER_SAC_FLY_RATE: float = 0.005
const BATTER_DOUBLE_PLAY_RATE: float = 0.0149
const BATTER_SACRIFICE_RATE: float = 0.002
# 1 打席あたりの球数 (一次式、ロジットではない)。
const BATTER_PITCHES_PER_PA: Dictionary = {"intercept": 3.5955, "Bat_Aggression": -0.363, "Bat_BBCreate": 0.4135, "Bat_KAvoid": -0.0643}
# 得点・打点 (1 打席あたり) = intercept + Σ 係数 × 内訳の 1 打席あたり割合 (walk は四球 + 死球)。
const RUNS_MODEL: Dictionary = {"intercept": -0.0159, "single": 0.3173, "double": 0.3608, "triple": 0.6865, "home_run": 0.9898, "walk": 0.2924, "stolen_base": 0.3524}
const RBI_MODEL: Dictionary = {"intercept": -0.0005, "single": 0.1749, "double": 0.54, "triple": 0.8067, "home_run": 2.0621, "walk": 0.0378, "stolen_base": -0.1272}

# 投手: k / bb / hr は対戦打者あたり、babip はインプレー打球あたり。
const PITCHER_RATE_MODELS: Dictionary = {
	"k": {"intercept": -2.151, "Pit_KCreate": 0.2883, "Pit_EdgeRate": 0.1725, "Pit_BBPrevent": 0.0262},
	"bb": {"intercept": -1.5315, "Pit_BBPrevent": -0.4398, "Pit_KCreate": -0.0736, "Pit_EdgeRate": -0.0407, "Pit_LoftControl": -0.0253},
	"hr": {"intercept": -2.9985, "Pit_BarrelDeny": -0.43, "Pit_ImpactLimit": -0.1972, "Pit_BBPrevent": 0.0866, "Pit_KCreate": -0.0899, "Pit_EdgeRate": 0.0687},
	"babip": {"intercept": -0.7233, "Pit_BarrelDeny": -0.0972, "Pit_ImpactLimit": -0.0279},
}
const PITCHER_HIT_BY_PITCH_RATE: float = 0.0068
# 対戦打者あたりの併殺 (アウトが 1 つ余分に増える)。
const PITCHER_DOUBLE_PLAY_RATE: float = 0.015
const PITCHES_PER_BATTER_FACED: Dictionary = {"intercept": 4.3604, "Pit_Efficiency": -0.2679, "Pit_EdgeRate": 0.0504, "Pit_BBPrevent": -0.0422}
# 自責点 (対戦打者あたり) = intercept + Σ 係数 × 内訳の対戦打者あたり割合 (walk は四球 + 死球)。
# 失点は自責点 × RUNS_PER_EARNED_RUN。
const EARNED_RUN_MODEL: Dictionary = {"intercept": -0.0824, "non_home_run_hit": 0.5504, "home_run": 1.499, "walk": 0.3943, "strikeout": -0.0024}
const RUNS_PER_EARNED_RUN: float = 1.08
# 得点・打点・自責点の式は NPB の成績に当てはめたもので、MLB の平均的な内訳に掛けると実際の MLB より
# 点が入りにくい (1 打席あたり得点 0.107 / 防御率 3.99)。MLB の 2023〜2025 の実績 (0.118 / 4.19) に合わせる倍率。
const MLB_RUNS_SCALE: float = 1.1
const MLB_EARNED_RUNS_SCALE: float = 1.05

# --- リーグ平均の基準 (build_league) ---
# NPB のリーグ平均は、今季の NPB 一軍に出た全選手 (控えも含む。実測のリーグ平均と同じ母集団) の能力を
# 打席/対戦打者で重み付けした平均で式を評価する。標本が BASELINE_MIN_SAMPLE 人に満たないとき
# (新規ゲーム開始前・テスト) は、初期世界の開始前 2 季 (2024〜2025) で測った平均 (下の定数) を使う。
const BASELINE_MIN_SAMPLE: int = 40
const BATTER_LEAGUE_Z: Dictionary = {
	"Bat_KAvoid": 1.372, "Bat_Impact": 1.931, "Bat_Aggression": 0.462, "Run_Judgment": 1.384, "Bat_BBCreate": 1.411,
	"Bat_Loft": 1.774, "Bat_Barrel": 1.666, "Run_Speed": 1.689, "Run_Steal": 1.392,
}
const PITCHER_LEAGUE_Z: Dictionary = {
	"Pit_KCreate": 1.861, "Pit_EdgeRate": 0.579, "Pit_BBPrevent": 1.907, "Pit_LoftControl": 1.762, "Pit_BarrelDeny": 1.68,
	"Pit_ImpactLimit": 1.451, "Pit_Efficiency": 1.614, "Pit_Stamina": 1.675,
}
# 先発の投球回と守備得点の基準は一軍の主力 (投手 150 打者以上 / 野手 200 打席以上) の平均。
const REGULAR_MIN_BATTERS_FACED: int = 150
const REGULAR_MIN_PLATE_APPEARANCES: int = 200
const NPB_STAMINA_BASELINE: float = 1.808
# 守備の表示能力 (PSPlayerVisibleRatings.fielder_defense) の一軍平均。守備得点の基準点。
const DEFENSE_BASELINE: float = 64.0

# --- 指標 (FanGraphs の式の簡略版) ---
const WOBA_WEIGHTS: Dictionary = {"walk": 0.696, "hit_by_pitch": 0.726, "single": 0.883, "double": 1.244, "triple": 1.569, "home_run": 2.004}
const WOBA_SCALE: float = 1.2
const RUN_STOLEN_BASE: float = 0.2
const RUN_CAUGHT_STEALING: float = -0.42
# 代替水準 (600 打席で 20 点)。
const REPLACEMENT_RUNS_PER_PA: float = 20.0 / 600.0
# 守備の表示能力が平均より 10 点高いごとの守備得点 (162 試合あたり)。
const FIELDING_RUNS_PER_10_POINTS: float = 4.0
# 守備位置補正 (162 試合あたりの得点、守備位置番号 2〜9)。
const POSITIONAL_RUNS: Dictionary = {2: 12.5, 3: -12.5, 4: 2.5, 5: 2.5, 6: 7.5, 7: -7.5, 8: 2.5, 9: -7.5}
# 投手の代替水準 (9 回あたりの勝利)。先発と救援を先発比率で按分する。
const STARTER_REPLACEMENT_WINS_PER_9: float = 0.12
const RELIEVER_REPLACEMENT_WINS_PER_9: float = 0.03
# 救援の起用場面の重さ (gmLI)。WAR は (1 + gmLI) / 2 倍になる。
const CLOSER_LEVERAGE: float = 1.8
const RELIEVER_LEVERAGE: float = 1.2

# --- 勝敗・QS・完投・セーブ・ホールドの近似 ---
const DECISIONS_PER_START: float = 0.72
const PYTHAGOREAN_EXPONENT: float = 1.83
# QS の割合 = 基準 + 係数 × (先発 1 試合の投球回 − 6) − 係数 × (本人の ERA − リーグ ERA)。
const QUALITY_START_BASE: float = 0.55
const QUALITY_START_PER_INNING: float = 0.25
const QUALITY_START_PER_ERA: float = 0.12
# 完投の割合 = 係数 × (先発 1 試合の投球回 − 基準)。
const COMPLETE_GAME_PER_EXTRA_INNING: float = 0.03
const COMPLETE_GAME_INNINGS_PIVOT: float = 6.3
const SHUTOUT_PER_COMPLETE_GAME: float = 0.3
# 救援の登板がリード場面 (抑えはセーブ機会、それ以外はホールド機会) である割合。
const CLOSER_SAVE_SITUATION_RATE: float = 0.6
const SETUP_HOLD_SITUATION_RATE: float = 0.35
# リード場面で追いつかれる割合 = 基準 + 係数 × (本人の ERA − リーグ ERA)。追いつかれたら一定の割合で負けが付く。
const BLOWN_LEAD_BASE: float = 0.1
const BLOWN_LEAD_PER_ERA: float = 0.04
const BLOWN_LEAD_LOSS_RATE: float = 0.45
const RELIEF_WIN_RATE: float = 0.05


# MLB のリーグ平均と、換算の基準にする NPB のリーグ平均。records は今季の NPB の年度レコード。空なら既定値。
static func build_league(records: Array = []) -> Dictionary:
	var batter_z: Dictionary = _league_z(records, false)
	var pitcher_z: Dictionary = _league_z(records, true)
	var league: Dictionary = {
		"npb_batting_logits": _model_logits(BATTER_RATE_MODELS, batter_z),
		"npb_pitching_logits": _model_logits(PITCHER_RATE_MODELS, pitcher_z),
		"npb_stamina": _regular_stamina(records),
		"defense": _baseline_defense(records),
	}
	# MLB 平均の打者: 換算後の率がちょうどリーグ平均。二塁打/三塁打の割合と盗塁は NPB の平均のまま。
	var batting: Dictionary = MLB_LEAGUE_RATES.duplicate()
	batting.merge(_batter_fixed_rates(batter_z), true)
	var line: Dictionary = _expected_batting_line(batting)
	var lg_woba: float = _woba_numerator(line) / (1.0 - BATTER_SACRIFICE_RATE)
	var lg_runs_per_pa: float = _linear_on(RUNS_MODEL, line) * MLB_RUNS_SCALE
	var lg_steal_runs_per_opportunity: float = float(batting["steal_attempt"]) * (
		float(batting["steal_success"]) * RUN_STOLEN_BASE + (1.0 - float(batting["steal_success"])) * RUN_CAUGHT_STEALING
	)

	var pitching: Dictionary = MLB_LEAGUE_RATES.duplicate()
	pitching["hit_by_pitch"] = PITCHER_HIT_BY_PITCH_RATE
	var outs_per_bf: float = _outs_per_batter_faced(pitching)
	var pitching_line: Dictionary = _expected_pitching_line(pitching)
	var lg_era: float = maxf(0.001, _linear_on(EARNED_RUN_MODEL, pitching_line)) * MLB_EARNED_RUNS_SCALE * 27.0 / outs_per_bf
	var lg_ra9: float = lg_era * RUNS_PER_EARNED_RUN
	league.merge({
		"lg_woba": lg_woba,
		"lg_runs_per_pa": lg_runs_per_pa,
		"lg_steal_runs_per_opportunity": lg_steal_runs_per_opportunity,
		"lg_era": lg_era,
		"lg_ra9": lg_ra9,
		"fip_constant": lg_era - _fip_raw(pitching_line, outs_per_bf),
		# FanGraphs の RPW = 9 × (lgR/IP) × 1.5 + 3。
		"runs_per_win": lg_ra9 * 1.5 + 3.0,
	}, true)
	return league


# 海外にいる選手全員の 1 シーズン。
# {player_id: {"batting": PSBatterStats, "pitching": PSPitcherStats, "metrics": Dictionary}}。
# 投手は pitching だけ、野手は batting だけを持つ。metrics は野手 {woba, wrc_plus, bsr, fielding, war}、
# 投手 {fip, war}。
static func simulate_season(players: Array, year: int, league: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null:
			continue
		Rng.begin_game_stream(-1, hash([Rng.current_seed, year, "mlb", player.id]))
		results[player.id] = simulate_pitcher(player, league) if player.is_pitcher() else simulate_batter(player, year, league)
		Rng.end_game_stream()
	return results


# MLB での見込みで決まる出場の割合。quality は MLB 平均との差 (打者は見込みの wRC+ − 100、
# 投手は 100 − 見込みの FIP−)、per_point はその 1 ポイントあたりの増減。
static func play_share(quality: float, per_point: float) -> float:
	return clampf(BASE_PLAY_SHARE + quality * per_point, MIN_PLAY_SHARE, MAX_PLAY_SHARE)


# 打者の MLB での率。K / BB / HR / BABIP は NPB → MLB の換算 (冒頭)、二塁打/三塁打の割合と盗塁は NPB の式のまま。
static func batting_rates(z: Dictionary, league: Dictionary) -> Dictionary:
	var rates: Dictionary = _translated_rates(BATTER_RATE_MODELS, z, league["npb_batting_logits"] as Dictionary, BATTER_TRANSLATION)
	rates.merge(_batter_fixed_rates(z), true)
	return rates


# 投手の MLB での被打率系の率 (NPB → MLB の換算込み)。
static func pitching_rates(z: Dictionary, league: Dictionary) -> Dictionary:
	var rates: Dictionary = _translated_rates(PITCHER_RATE_MODELS, z, league["npb_pitching_logits"] as Dictionary, PITCHER_TRANSLATION)
	rates["hit_by_pitch"] = PITCHER_HIT_BY_PITCH_RATE
	rates["pitches_per_bf"] = _linear(PITCHES_PER_BATTER_FACED, z)
	return rates


# 率から見込んだ MLB での wRC+ / FIP− (MLB のリーグ平均に対して)。出場機会の決定に使う。
static func expected_wrc_plus(rates: Dictionary, league: Dictionary) -> float:
	var woba: float = _woba_numerator(_expected_batting_line(rates)) / (1.0 - BATTER_SACRIFICE_RATE)
	var lg_runs_per_pa: float = float(league["lg_runs_per_pa"])
	return ((woba - float(league["lg_woba"])) / WOBA_SCALE + lg_runs_per_pa) / lg_runs_per_pa * 100.0


static func expected_fip_minus(rates: Dictionary, league: Dictionary) -> float:
	var outs_per_bf: float = _outs_per_batter_faced(rates)
	var fip: float = _fip_raw(_expected_pitching_line(rates), outs_per_bf) + float(league["fip_constant"])
	return fip / float(league["lg_era"]) * 100.0


# --- 打者 ---

static func simulate_batter(player: PSPlayer, year: int, league: Dictionary) -> Dictionary:
	var z: Dictionary = player.z_abilities
	var rates: Dictionary = batting_rates(z, league)
	var quality: float = expected_wrc_plus(rates, league) - 100.0
	var stats: PSBatterStats = PSBatterStats.new()
	stats.games = _binomial(MLB_GAMES, play_share(quality, PLAY_SHARE_PER_WRC_PLUS))
	var pa_per_game: float = clampf(PA_PER_GAME + quality * PA_PER_GAME_PER_WRC_PLUS, MIN_PA_PER_GAME, MAX_PA_PER_GAME)
	stats.plate_appearances = int(round(float(stats.games) * pa_per_game))

	var k: float = float(rates["k"])
	var bb: float = k + float(rates["bb"])
	var hbp: float = bb + float(rates["hit_by_pitch"])
	var hr: float = hbp + float(rates["hr"])
	var sf: float = hr + float(rates["sac_fly"])
	var sh: float = sf + float(rates["sacrifice"])
	var singles: int = 0
	for _pa in range(stats.plate_appearances):
		var roll: float = Rng.roll_float()
		if roll < k:
			stats.strikeouts += 1
		elif roll < bb:
			stats.walks += 1
		elif roll < hbp:
			stats.hit_by_pitches += 1
		elif roll < hr:
			stats.home_runs += 1
		elif roll < sf:
			stats.sacrifice_flies += 1
		elif roll < sh:
			stats.sacrifices += 1
		elif Rng.roll_float() < float(rates["babip"]):
			var hit_roll: float = Rng.roll_float()
			if hit_roll < float(rates["triple_share"]):
				stats.triples += 1
			elif hit_roll < float(rates["triple_share"]) + float(rates["double_share"]):
				stats.doubles += 1
			else:
				singles += 1
	stats.hits = singles + stats.doubles + stats.triples + stats.home_runs
	stats.at_bats = stats.plate_appearances - stats.walks - stats.hit_by_pitches - stats.sacrifice_flies - stats.sacrifices
	stats.double_plays = _binomial(stats.plate_appearances, float(rates["double_play"]))
	var opportunities: int = singles + stats.walks + stats.hit_by_pitches
	stats.stolen_base_attempts = _binomial(opportunities, float(rates["steal_attempt"]))
	stats.stolen_bases = _binomial(stats.stolen_base_attempts, float(rates["steal_success"]))
	var line: Dictionary = _batting_line_per_pa(stats, singles)
	stats.runs = _noisy_count(_linear_on(RUNS_MODEL, line) * MLB_RUNS_SCALE * float(stats.plate_appearances))
	stats.runs_batted_in = _noisy_count(_linear_on(RBI_MODEL, line) * MLB_RUNS_SCALE * float(stats.plate_appearances))
	stats.pitches_seen = int(round(float(stats.plate_appearances) * float(rates["pitches_per_pa"])))
	return {"batting": stats, "metrics": _batter_metrics(player, year, stats, singles, opportunities, league)}


static func _batter_metrics(player: PSPlayer, year: int, stats: PSBatterStats, singles: int, opportunities: int, league: Dictionary) -> Dictionary:
	var pa: int = stats.plate_appearances
	if pa <= 0:
		return {}
	var woba_denominator: int = stats.at_bats + stats.walks + stats.sacrifice_flies + stats.hit_by_pitches
	var woba: float = _woba_numerator({
		"walk": float(stats.walks), "hit_by_pitch": float(stats.hit_by_pitches), "single": float(singles),
		"double": float(stats.doubles), "triple": float(stats.triples), "home_run": float(stats.home_runs),
	}) / float(maxi(1, woba_denominator))
	var lg_runs_per_pa: float = float(league["lg_runs_per_pa"])
	var batting_runs: float = (woba - float(league["lg_woba"])) / WOBA_SCALE * float(pa)
	var caught: int = stats.stolen_base_attempts - stats.stolen_bases
	var baserunning: float = float(stats.stolen_bases) * RUN_STOLEN_BASE + float(caught) * RUN_CAUGHT_STEALING \
		- float(league["lg_steal_runs_per_opportunity"]) * float(opportunities)
	var season_share: float = float(stats.games) / float(MLB_GAMES)
	var defense: float = float(PSPlayerVisibleRatings.fielder_defense(PSPlayerSeasonRecord.from_player(player, year, 0)))
	var fielding: float = (defense - float(league["defense"])) / 10.0 * FIELDING_RUNS_PER_10_POINTS * season_share
	var positional: float = float(POSITIONAL_RUNS.get(player.position, 0.0)) * season_share
	var replacement: float = REPLACEMENT_RUNS_PER_PA * float(pa)
	var war: float = (batting_runs + baserunning + fielding + positional + replacement) / float(league["runs_per_win"])
	return {
		"woba": _round(woba, 3),
		"wrc_plus": _round((batting_runs / float(pa) + lg_runs_per_pa) / lg_runs_per_pa * 100.0, 1),
		"bsr": _round(baserunning, 1),
		"fielding": _round(fielding, 1),
		"war": _round(war, 1),
	}


# --- 投手 ---

static func simulate_pitcher(player: PSPlayer, league: Dictionary) -> Dictionary:
	var z: Dictionary = player.z_abilities
	var rates: Dictionary = pitching_rates(z, league)
	var share: float = play_share(100.0 - expected_fip_minus(rates, league), PLAY_SHARE_PER_FIP_MINUS)
	var stats: PSPitcherStats = PSPitcherStats.new()
	var starter: bool = player.role == "starter"
	var innings_per_start: float = 0.0
	if starter:
		stats.starts = _binomial(MLB_STARTS, share)
		stats.games = stats.starts
		innings_per_start = clampf(
			INNINGS_PER_START + (float(z.get("Pit_Stamina", 0.0)) - float(league["npb_stamina"])) * INNINGS_PER_START_PER_Z,
			MIN_INNINGS_PER_START, MAX_INNINGS_PER_START
		)
		stats.outs_pitched = int(round(float(stats.starts) * innings_per_start * 3.0))
	else:
		stats.relief_appearances = _binomial(MLB_RELIEF_APPEARANCES, share)
		stats.games = stats.relief_appearances
		stats.outs_pitched = stats.relief_appearances * RELIEF_OUTS_PER_APPEARANCE
	if stats.games <= 0:
		return {"pitching": stats, "metrics": {}}

	stats.batters_faced = int(round(float(stats.outs_pitched) / _outs_per_batter_faced(rates)))
	var k: float = float(rates["k"])
	var bb: float = k + float(rates["bb"])
	var hbp: float = bb + float(rates["hit_by_pitch"])
	var hr: float = hbp + float(rates["hr"])
	for _bf in range(stats.batters_faced):
		var roll: float = Rng.roll_float()
		if roll < k:
			stats.strikeouts += 1
		elif roll < bb:
			stats.walks += 1
		elif roll < hbp:
			stats.hit_batters += 1
		elif roll < hr:
			stats.home_runs_allowed += 1
			stats.hits_allowed += 1
		elif Rng.roll_float() < float(rates["babip"]):
			stats.hits_allowed += 1
	var bf: float = float(maxi(1, stats.batters_faced))
	var line: Dictionary = {
		"non_home_run_hit": float(stats.hits_allowed - stats.home_runs_allowed) / bf,
		"home_run": float(stats.home_runs_allowed) / bf,
		"walk": float(stats.walks + stats.hit_batters) / bf,
		"strikeout": float(stats.strikeouts) / bf,
	}
	stats.earned_runs = _noisy_count(maxf(0.0, _linear_on(EARNED_RUN_MODEL, line)) * MLB_EARNED_RUNS_SCALE * bf)
	stats.runs_allowed = stats.earned_runs + _noisy_count(float(stats.earned_runs) * (RUNS_PER_EARNED_RUN - 1.0))
	stats.pitches_thrown = int(round(bf * float(rates["pitches_per_bf"])))
	var era: float = float(stats.earned_runs) * 27.0 / float(maxi(1, stats.outs_pitched))
	if starter:
		_assign_starter_decisions(stats, innings_per_start, era, league)
	else:
		_assign_relief_decisions(stats, player.role == "closer", era, league)
	return {"pitching": stats, "metrics": _pitcher_metrics(stats, player.role, league)}


static func _assign_starter_decisions(stats: PSPitcherStats, innings_per_start: float, era: float, league: Dictionary) -> void:
	var lg_ra9: float = float(league["lg_ra9"])
	var ra9: float = era * RUNS_PER_EARNED_RUN
	# 本人が投げる回は本人の失点率、残りはリーグ平均。味方の得点はリーグ平均。
	var game_runs_allowed: float = maxf(0.1, (ra9 * innings_per_start + lg_ra9 * (9.0 - innings_per_start)) / 9.0)
	var scored: float = pow(lg_ra9, PYTHAGOREAN_EXPONENT)
	var win_pct: float = scored / (scored + pow(game_runs_allowed, PYTHAGOREAN_EXPONENT))
	var decisions: int = _binomial(stats.starts, DECISIONS_PER_START)
	stats.wins = _binomial(decisions, win_pct)
	stats.losses = decisions - stats.wins
	var quality_rate: float = clampf(
		QUALITY_START_BASE + QUALITY_START_PER_INNING * (innings_per_start - 6.0) - QUALITY_START_PER_ERA * (era - float(league["lg_era"])),
		0.05, 0.9
	)
	stats.quality_starts = _binomial(stats.starts, quality_rate)
	stats.complete_games = _binomial(stats.starts, clampf(COMPLETE_GAME_PER_EXTRA_INNING * (innings_per_start - COMPLETE_GAME_INNINGS_PIVOT), 0.0, 0.1))
	stats.shutouts = _binomial(stats.complete_games, SHUTOUT_PER_COMPLETE_GAME)


static func _assign_relief_decisions(stats: PSPitcherStats, closer: bool, era: float, league: Dictionary) -> void:
	var blown_rate: float = clampf(BLOWN_LEAD_BASE + BLOWN_LEAD_PER_ERA * (era - float(league["lg_era"])), 0.04, 0.35)
	var situations: int = _binomial(stats.relief_appearances, CLOSER_SAVE_SITUATION_RATE if closer else SETUP_HOLD_SITUATION_RATE)
	var converted: int = _binomial(situations, 1.0 - blown_rate)
	if closer:
		stats.saves = converted
	else:
		stats.holds = converted
	stats.losses = _binomial(situations - converted, BLOWN_LEAD_LOSS_RATE)
	stats.wins = _binomial(stats.relief_appearances, RELIEF_WIN_RATE)


static func _pitcher_metrics(stats: PSPitcherStats, role: String, league: Dictionary) -> Dictionary:
	if stats.outs_pitched <= 0:
		return {}
	var innings: float = float(stats.outs_pitched) / 3.0
	var fip: float = (13.0 * float(stats.home_runs_allowed) + 3.0 * float(stats.walks + stats.hit_batters) - 2.0 * float(stats.strikeouts)) / innings \
		+ float(league["fip_constant"])
	var lg_ra9: float = float(league["lg_ra9"])
	var fip_r9: float = fip + (lg_ra9 - float(league["lg_era"]))
	var innings_per_game: float = innings / float(maxi(1, stats.games))
	var dynamic_rpw: float = (((18.0 - innings_per_game) * lg_ra9 + innings_per_game * fip_r9) / 18.0 + 2.0) * 1.5
	var starter_share: float = float(stats.starts) / float(maxi(1, stats.games))
	var replacement: float = RELIEVER_REPLACEMENT_WINS_PER_9 * (1.0 - starter_share) + STARTER_REPLACEMENT_WINS_PER_9 * starter_share
	var leverage: float = 1.0
	if role == "closer":
		leverage = (1.0 + CLOSER_LEVERAGE) / 2.0
	elif role != "starter":
		leverage = (1.0 + RELIEVER_LEVERAGE) / 2.0
	var war: float = ((lg_ra9 - fip_r9) / dynamic_rpw + replacement) * innings / 9.0 * leverage
	return {"fip": _round(fip, 2), "war": _round(war, 1)}


# --- リーグ平均の材料 ---

# 1 打席あたりの内訳の期待値。walk は四球 + 死球 (RUNS_MODEL 用)、walk_only は四球だけ (wOBA 用)。
static func _expected_batting_line(rates: Dictionary) -> Dictionary:
	var in_play: float = 1.0 - float(rates["k"]) - float(rates["bb"]) - float(rates["hit_by_pitch"]) - float(rates["hr"]) \
		- float(rates["sac_fly"]) - float(rates["sacrifice"])
	var hits_in_play: float = in_play * float(rates["babip"])
	var triple: float = hits_in_play * float(rates["triple_share"])
	var double: float = hits_in_play * float(rates["double_share"])
	var single: float = hits_in_play - triple - double
	var walk: float = float(rates["bb"])
	var hit_by_pitch: float = float(rates["hit_by_pitch"])
	var stolen_base: float = (single + walk + hit_by_pitch) * float(rates["steal_attempt"]) * float(rates["steal_success"])
	return {
		"single": single, "double": double, "triple": triple, "home_run": float(rates["hr"]),
		"walk": walk + hit_by_pitch, "walk_only": walk, "hit_by_pitch": hit_by_pitch, "stolen_base": stolen_base,
	}


static func _expected_pitching_line(rates: Dictionary) -> Dictionary:
	var in_play: float = 1.0 - float(rates["k"]) - float(rates["bb"]) - float(rates["hit_by_pitch"]) - float(rates["hr"])
	return {
		"non_home_run_hit": in_play * float(rates["babip"]),
		"home_run": float(rates["hr"]),
		"walk": float(rates["bb"]) + float(rates["hit_by_pitch"]),
		"strikeout": float(rates["k"]),
	}


# 対戦打者 1 人あたりのアウト (三振 + インプレーのアウト + 併殺の余分な 1 つ)。
static func _outs_per_batter_faced(rates: Dictionary) -> float:
	var in_play: float = 1.0 - float(rates["k"]) - float(rates["bb"]) - float(rates["hit_by_pitch"]) - float(rates["hr"])
	return maxf(0.3, float(rates["k"]) + in_play * (1.0 - float(rates["babip"])) + PITCHER_DOUBLE_PLAY_RATE)


static func _batting_line_per_pa(stats: PSBatterStats, singles: int) -> Dictionary:
	var pa: float = float(maxi(1, stats.plate_appearances))
	return {
		"single": float(singles) / pa, "double": float(stats.doubles) / pa, "triple": float(stats.triples) / pa,
		"home_run": float(stats.home_runs) / pa, "walk": float(stats.walks + stats.hit_by_pitches) / pa,
		"stolen_base": float(stats.stolen_bases) / pa,
	}


# wOBA の分子。四球は walk_only があればそれ (walk が四球 + 死球の内訳のとき)、無ければ walk。
static func _woba_numerator(line: Dictionary) -> float:
	var walk: float = float(line.get("walk_only", line.get("walk", 0.0)))
	return float(WOBA_WEIGHTS["walk"]) * walk \
		+ float(WOBA_WEIGHTS["hit_by_pitch"]) * float(line.get("hit_by_pitch", 0.0)) \
		+ float(WOBA_WEIGHTS["single"]) * float(line.get("single", 0.0)) \
		+ float(WOBA_WEIGHTS["double"]) * float(line.get("double", 0.0)) \
		+ float(WOBA_WEIGHTS["triple"]) * float(line.get("triple", 0.0)) \
		+ float(WOBA_WEIGHTS["home_run"]) * float(line.get("home_run", 0.0))


# 今季の NPB 一軍に出た全選手の能力平均 (打席/対戦打者で重み付け)。標本が足りなければ既定値。
static func _league_z(records: Array, pitchers: bool) -> Dictionary:
	var defaults: Dictionary = PITCHER_LEAGUE_Z if pitchers else BATTER_LEAGUE_Z
	var totals: Dictionary = {}
	var weight_total: float = 0.0
	var sample: int = 0
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null or record.is_pitcher() != pitchers:
			continue
		var weight: int = record.pitcher_stats.batters_faced if pitchers else record.batter_stats.plate_appearances
		if weight <= 0:
			continue
		sample += 1
		weight_total += float(weight)
		for key in defaults.keys():
			totals[key] = float(totals.get(key, 0.0)) + record.z_ability(key, 0.0) * float(weight)
	if sample < BASELINE_MIN_SAMPLE:
		return defaults.duplicate()
	var means: Dictionary = {}
	for key in defaults.keys():
		means[key] = float(totals[key]) / weight_total
	return means


# 一軍の主力投手 (150 打者以上) の Pit_Stamina の平均。先発の投球回の基準。
static func _regular_stamina(records: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	var sample: int = 0
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher() or record.pitcher_stats.batters_faced < REGULAR_MIN_BATTERS_FACED:
			continue
		sample += 1
		total += record.z_ability("Pit_Stamina", 0.0) * float(record.pitcher_stats.batters_faced)
		weight_total += float(record.pitcher_stats.batters_faced)
	return total / weight_total if sample >= BASELINE_MIN_SAMPLE else NPB_STAMINA_BASELINE


static func _baseline_defense(records: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	var sample: int = 0
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null or record.is_pitcher() or record.batter_stats.plate_appearances < REGULAR_MIN_PLATE_APPEARANCES:
			continue
		sample += 1
		total += float(PSPlayerVisibleRatings.fielder_defense(record)) * float(record.batter_stats.plate_appearances)
		weight_total += float(record.batter_stats.plate_appearances)
	return total / weight_total if sample >= BASELINE_MIN_SAMPLE else DEFENSE_BASELINE


# --- 小道具 ---

# 換算する率 (MLB_LEAGUE_RATES のキー) の、能力の式が出す NPB でのロジット。
static func _model_logits(models: Dictionary, z: Dictionary) -> Dictionary:
	var logits: Dictionary = {}
	for name in MLB_LEAGUE_RATES.keys():
		logits[name] = _linear(models[name] as Dictionary, z)
	return logits


# logit(MLB のリーグ平均) + (本人の NPB でのロジット − NPB のリーグ平均のロジット) + 換算。
static func _translated_rates(models: Dictionary, z: Dictionary, npb_league_logits: Dictionary, translation: Dictionary) -> Dictionary:
	var rates: Dictionary = {}
	for name in MLB_LEAGUE_RATES.keys():
		var advantage: float = _linear(models[name] as Dictionary, z) - float(npb_league_logits[name])
		rates[name] = _sigmoid(_logit(float(MLB_LEAGUE_RATES[name])) + advantage + float(translation.get(name, 0.0)))
	return rates


# 打者の率のうち換算しないもの (NPB の式のまま、または定数)。
static func _batter_fixed_rates(z: Dictionary) -> Dictionary:
	var rates: Dictionary = {}
	for name in BATTER_RATE_MODELS.keys():
		if not MLB_LEAGUE_RATES.has(name):
			rates[name] = _sigmoid(_linear(BATTER_RATE_MODELS[name] as Dictionary, z))
	rates["hit_by_pitch"] = BATTER_HIT_BY_PITCH_RATE
	rates["sac_fly"] = BATTER_SAC_FLY_RATE
	rates["double_play"] = BATTER_DOUBLE_PLAY_RATE
	rates["sacrifice"] = BATTER_SACRIFICE_RATE
	rates["pitches_per_pa"] = _linear(BATTER_PITCHES_PER_PA, z)
	return rates


# FIP の定数を足す前の値 (line は対戦打者あたりの内訳)。
static func _fip_raw(line: Dictionary, outs_per_bf: float) -> float:
	return (13.0 * float(line["home_run"]) + 3.0 * float(line["walk"]) - 2.0 * float(line["strikeout"])) / (outs_per_bf / 3.0)


static func _linear(model: Dictionary, z: Dictionary) -> float:
	var total: float = float(model.get("intercept", 0.0))
	for key in model.keys():
		if key != "intercept":
			total += float(model[key]) * float(z.get(key, 0.0))
	return total


static func _linear_on(model: Dictionary, line: Dictionary) -> float:
	var total: float = float(model.get("intercept", 0.0))
	for key in model.keys():
		if key != "intercept":
			total += float(model[key]) * float(line.get(key, 0.0))
	return total


static func _sigmoid(value: float) -> float:
	return 1.0 / (1.0 + exp(-value))


static func _logit(probability: float) -> float:
	return log(probability / (1.0 - probability))


static func _binomial(trials: int, probability: float) -> int:
	var count: int = 0
	for _trial in range(maxi(0, trials)):
		if Rng.roll_float() < probability:
			count += 1
	return count


# 期待値のまわりに標本誤差ぶんばらつかせた回数 (正規近似)。
static func _noisy_count(mean: float) -> int:
	if mean <= 0.0:
		return 0
	var u1: float = maxf(1.0e-9, Rng.roll_float())
	var gaussian: float = sqrt(-2.0 * log(u1)) * cos(TAU * Rng.roll_float())
	return maxi(0, int(round(mean + sqrt(mean) * gaussian)))


static func _round(value: float, digits: int) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor
