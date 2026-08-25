extends RefCounted
class_name PSPaProbabilityCalculator

# 打席結果カテゴリ (K/BB/HBP/BIP) の確率を作る。
# 入力 precomp は PSPlateAppearanceCoordinator が組み立てた、疲労・巡目・捕手影響を反映済みの能力辞書。
# 各カテゴリの logit を raw z 能力と調整係数からそのまま作り、softmax で相対確率へ変換する。
# K_LOGIT_BASE/BB_LOGIT_BASE/HBP_LOGIT_BASE は「能力差ゼロの平均的対戦」を基準にした
# LEAGUE_*_BASE の logit に、Bat_KAvoid/Bat_BBCreate/Pit_KCreate/Pit_BBPrevent の実測母平均分の
# 補正項を1回だけ畳み込んだ定数。おかげで実行時は「raw z に重みを掛けてベース定数へ足す」
# 1段階で済み、母平均を実行時に参照しない。


const OUTCOME_STRIKEOUT: String = "k"
const OUTCOME_WALK: String = "bb"
const OUTCOME_HIT_BY_PITCH: String = "hbp"
const OUTCOME_BIP: String = "bip"

const OUTCOMES: Array[String] = [OUTCOME_STRIKEOUT, OUTCOME_WALK, OUTCOME_HIT_BY_PITCH, OUTCOME_BIP]

# K/BB/HBP/BIP の調整係数。個々の raw z 能力で logit を動かす。
# リーグベースラインは softmax 前の初期値なので、1カテゴリを上げると他カテゴリは相対的に下がる。
# K_LOGIT_BASE/BB_LOGIT_BASE/HBP_LOGIT_BASE は元々「平均的な対戦での基準率」を確率で持ち、
# raw z から実測母平均を引いてから重みを掛けていたものを代数的に1つの logit 定数へ畳み込んだ値
# (K_LOGIT_BASE = logit(0.34) - Pit_KCreate母平均*K_CREATE_WEIGHT + Bat_KAvoid母平均*K_AVOID_WEIGHT 等)。
# BIP だけは能力補正を持たないため、確率のまま(較正で直接いじる基準率)。
const K_LOGIT_BASE: float = -0.54
const BB_LOGIT_BASE: float = -1.0
const HBP_LOGIT_BASE: float = -4.20058985013459
const LEAGUE_BIP_BASE: float = 0.72  # インプレー(打球)の基準率。上げると三振・四球が相対的に減る。
# K スコア係数: 個々の能力(z)が三振 logit を動かす強さ。
const K_CREATE_WEIGHT: float = 0.33       # 投手の奪三振力が三振を増やす強さ。
const K_AVOID_WEIGHT: float = 0.66        # 打者の三振回避力が三振を減らす強さ。
const ARSENAL_K_BONUS_WEIGHT: float = 0.2 # 投手の球威/制球の鋭さ(EdgeRate)による追加奪三振。
# 球種構成のK寄り傾向(集計済み・中心化済み)による追加奪三振。**微差**(K_CREATE_WEIGHT=0.60 比で十分小さい)。
# 球種差はわずかに留める方針。較正フェーズで強める前提。
const ARSENAL_TENDENCY_K_WEIGHT: float = 0.06
const FRAMING_K_COEF: float = 1.0         # 捕手フレーミングで得たストライクが三振を押し上げる係数。
const GAMECALL_K_COEF: float = 0.06       # 捕手の配球(リード)が三振に効く係数。
const TTO_K_DROP: float = 0.5             # 巡目ペナルティで奪三振が落ちる量。
# BB スコア係数: 個々の能力(z)が四球 logit を動かす強さ。
const BB_CREATE_WEIGHT: float = 0.5  # 打者の選球眼が四球を増やす強さ。
const BB_PREVENT_WEIGHT: float = 0.5 # 投手の制球が四球を減らす強さ。
const FRAMING_BB_COEF: float = 1.0    # フレーミングで得たストライクが四球を押し下げる係数。
const GAMECALL_BB_COEF: float = 0.03  # 捕手の配球が四球に効く係数。
const TTO_BB_DROP: float = 0.4        # 巡目ペナルティで四球が増える量。
# 左右(プラトーン)相性が三振 logit に効く強さ。
const PLATOON_WEIGHT: float = 0.3
# 能力差による logit の振れ幅の飽和点 (対戦優位の圧縮)。
# **能力ではなく「投手項 - 打者項」に掛ける**ので、両者が同じだけ弱くなっても結果は動かない
# (= リーグ水準が変わってもレベル不変) 一方、極端なミスマッチだけが飽和する。
# 圧縮の対象は raw z 由来の項だけで、フレーミング・配球・巡目・プラトーンといった状況項は含めない
# (状況項は対戦の能力差ではないため)。値の較正は tools/run_pa_response_surface の
# farm_club_win_pct で行う。詳細は docs/agent_memory/project_pa_talent_sensitivity_calibration.md。
# ⚠️ 圧縮の中心は 0 ではない。K_LOGIT_BASE が畳み込んでいるのは**全選手プールの平均**なので、
# 能力差項が 0 になるのはプール平均どうしの対戦であって、一軍どうしの対戦ではない。
# 一軍の標準的な対戦での能力差項を中心に据えないと、一軍の平常運転が圧縮側に入ってしまう。
# 値は contact_quality_model の *_CURVE_CENTER と同種のチューニング定数 (実行時に母集団を
# 追跡しない一度きりの実測値)。K は打者側の重みが2倍なので中心が負へ寄る。
const K_MATCHUP_CENTER: float = -0.32
const BB_MATCHUP_CENTER: float = -0.20
# K/BB は**両側同じ天井** (contact_quality 側だけ打者優位側を高くしている)。
# 天井 0.90 は奪三振王の水準で決めた — 0.70 だとエースの奪三振が頭打ちで K/9 のリーグ最高が
# 9 台に留まり、実 NPB (10-11.5) に届かない。緩めると規定 ERA 1点台の投手が増える方向だが、
# 3シード実測では 3-4 人 (帯は 3 人以下) に収まる。
# (K は「正 = 投手優位」で contact_quality と符号の意味が逆な点に注意。)
const MATCHUP_LOGIT_PIVOT: float = 0.55
const MATCHUP_LOGIT_SPAN: float = 0.35


# {k: logit, bb: logit, hbp: logit, bip: logit} を返す。
# precomp は以下のキーを持つ想定（PlateAppearanceCoordinator が組み立てる）:
#   batter_z: Dictionary{Bat_KAvoid, Bat_BBCreate, Bat_Platoon, ...}
#   pitcher_z: Dictionary{Pit_KCreate, Pit_BBPrevent, Pit_EdgeRate, ...} (fatigue/TTO 後)
#   catcher_z: Dictionary{C_Framing, ...}
#   platoon_sign: float (+1 同利き腕 / -1 逆利き腕)
#   tto_round_weight: float (coordinator の TTO_PENALTY_PER_ROUND[round])
#   framing_strikes: float (C_Framing * coordinator の FRAMING_SCALE)
static func build_weights(precomp: Dictionary) -> Dictionary:
	var rules: Dictionary = precomp.get("_pa_probability_rules", {}) as Dictionary
	var batter_z: Dictionary = precomp.get("batter_z", {}) as Dictionary
	var pitcher_z: Dictionary = precomp.get("pitcher_z", {}) as Dictionary
	var platoon_sign: float = float(precomp.get("platoon_sign", 0.0))
	var tto_round_weight: float = float(precomp.get("tto_round_weight", 0.0))
	var framing_strikes: float = float(precomp.get("framing_strikes", 0.0))
	var command_leak: float = float(precomp.get("pitcher_command_leak", 0.0))
	var arsenal_k_bias: float = float(precomp.get("arsenal_k_bias", 0.0))
	var catcher_z: Dictionary = precomp.get("catcher_z", {}) as Dictionary
	var platoon_weight: float = _rule_float(rules, "platoon_weight", PLATOON_WEIGHT)

	var bat_k_avoid: float = float(batter_z.get("Bat_KAvoid", 0.0))
	var bat_bb_create: float = float(batter_z.get("Bat_BBCreate", 0.0))
	var bat_platoon: float = float(batter_z.get("Bat_Platoon", 0.0))
	var pit_k_create: float = float(pitcher_z.get("Pit_KCreate", 0.0))
	var pit_bb_prevent: float = float(pitcher_z.get("Pit_BBPrevent", 0.0))
	var pit_edge_rate: float = float(pitcher_z.get("Pit_EdgeRate", 0.0))
	var c_game_call: float = float(catcher_z.get("C_GameCall", 0.0))

	var platoon_term: float = bat_platoon * platoon_sign * platoon_weight

	var matchup_pivot: float = _rule_float(rules, "matchup_logit_pivot", MATCHUP_LOGIT_PIVOT)
	var matchup_span: float = _rule_float(rules, "matchup_logit_span", MATCHUP_LOGIT_SPAN)

	# 能力差由来の項だけを先に積んでから飽和させ、そのあとで状況項 (フレーミング/配球/巡目/
	# プラトーン) を足す。状況項は対戦の能力差ではないので圧縮の対象にしない。
	var k_ability: float = pit_k_create * _rule_float(rules, "k_create_weight", K_CREATE_WEIGHT)
	k_ability -= bat_k_avoid * _rule_float(rules, "k_avoid_weight", K_AVOID_WEIGHT)
	k_ability += pit_edge_rate * _rule_float(rules, "arsenal_k_bonus_weight", ARSENAL_K_BONUS_WEIGHT)
	k_ability += arsenal_k_bias * _rule_float(rules, "arsenal_tendency_k_weight", ARSENAL_TENDENCY_K_WEIGHT)  # 球種構成のK寄り傾向(微差)。
	var k_center: float = _rule_float(rules, "k_matchup_center", K_MATCHUP_CENTER)
	k_ability = k_center + PSBalanceProfile.compress_matchup_advantage(k_ability - k_center, matchup_pivot, matchup_span)

	var k_logit: float = _rule_float(rules, "k_logit_base", K_LOGIT_BASE) + k_ability
	k_logit += framing_strikes * _rule_float(rules, "framing_k_coef", FRAMING_K_COEF)
	k_logit += c_game_call * _rule_float(rules, "gamecall_k_coef", GAMECALL_K_COEF)
	k_logit -= tto_round_weight * _rule_float(rules, "tto_k_drop", TTO_K_DROP)
	k_logit -= platoon_term

	var bb_ability: float = bat_bb_create * _rule_float(rules, "bb_create_weight", BB_CREATE_WEIGHT)
	bb_ability -= pit_bb_prevent * _rule_float(rules, "bb_prevent_weight", BB_PREVENT_WEIGHT)
	var bb_center: float = _rule_float(rules, "bb_matchup_center", BB_MATCHUP_CENTER)
	bb_ability = bb_center + PSBalanceProfile.compress_matchup_advantage(bb_ability - bb_center, matchup_pivot, matchup_span)

	var bb_logit: float = _rule_float(rules, "bb_logit_base", BB_LOGIT_BASE) + bb_ability
	bb_logit -= framing_strikes * _rule_float(rules, "framing_bb_coef", FRAMING_BB_COEF)
	bb_logit -= c_game_call * _rule_float(rules, "gamecall_bb_coef", GAMECALL_BB_COEF)
	bb_logit += tto_round_weight * _rule_float(rules, "tto_bb_drop", TTO_BB_DROP)
	bb_logit += command_leak * _rule_float(rules, "command_leak_bb_weight", 0.10)

	var hbp_logit: float = _rule_float(rules, "hbp_logit_base", HBP_LOGIT_BASE)
	hbp_logit -= pit_bb_prevent * _rule_float(rules, "hbp_bb_prevent_weight", 0.30)
	hbp_logit += command_leak * _rule_float(rules, "command_leak_hbp_weight", 0.06)

	var bip_logit: float = PSBalanceProfile.logit(_rule_float(rules, "league_bip_base", LEAGUE_BIP_BASE))

	return {
		OUTCOME_STRIKEOUT: k_logit,
		OUTCOME_WALK: bb_logit,
		OUTCOME_HIT_BY_PITCH: hbp_logit,
		OUTCOME_BIP: bip_logit,
	}


static func _rule_float(rules: Dictionary, name: String, fallback: float) -> float:
	if rules.has(name):
		var value: Variant = rules[name]
		if value is int or value is float:
			return float(value)
		if value is String and str(value).is_valid_float():
			return float(value)
		return fallback
	if not rules.is_empty():
		return fallback
	return ModManager.rule_group_float(ModManager.RULE_GROUP_PA_PROBABILITY, name, fallback)


# softmax で 1 カテゴリを抽選する。
static func pick(weights: Dictionary) -> String:
	var k_logit: float = float(weights.get(OUTCOME_STRIKEOUT, 0.0))
	var bb_logit: float = float(weights.get(OUTCOME_WALK, 0.0))
	var hbp_logit: float = float(weights.get(OUTCOME_HIT_BY_PITCH, 0.0))
	var bip_logit: float = float(weights.get(OUTCOME_BIP, 0.0))
	var max_logit: float = max(max(k_logit, bb_logit), max(hbp_logit, bip_logit))
	var k_weight: float = exp(clamp(k_logit - max_logit, -30.0, 30.0))
	var bb_weight: float = exp(clamp(bb_logit - max_logit, -30.0, 30.0))
	var hbp_weight: float = exp(clamp(hbp_logit - max_logit, -30.0, 30.0))
	var bip_weight: float = exp(clamp(bip_logit - max_logit, -30.0, 30.0))
	var total: float = k_weight + bb_weight + hbp_weight + bip_weight
	if total <= 0.0:
		return OUTCOME_BIP
	var roll: float = Rng.roll_float() * total
	if roll <= k_weight:
		return OUTCOME_STRIKEOUT
	roll -= k_weight
	if roll <= bb_weight:
		return OUTCOME_WALK
	roll -= bb_weight
	if roll <= hbp_weight:
		return OUTCOME_HIT_BY_PITCH
	return OUTCOME_BIP


# weights を確率分布に正規化したコピーを返す（テスト/レポート用）。
static func probabilities(weights: Dictionary) -> Dictionary:
	var max_logit: float = -INF
	for outcome in OUTCOMES:
		max_logit = max(max_logit, float(weights.get(outcome, 0.0)))
	var exp_values: Dictionary = {}
	var total: float = 0.0
	for outcome in OUTCOMES:
		var v: float = exp(clamp(float(weights.get(outcome, 0.0)) - max_logit, -30.0, 30.0))
		exp_values[outcome] = v
		total += v
	if total <= 0.0:
		return {OUTCOME_BIP: 1.0}
	var probs: Dictionary = {}
	for outcome in OUTCOMES:
		probs[outcome] = float(exp_values[outcome]) / total
	return probs
