extends RefCounted
class_name PSPlateAppearanceCoordinator

# 1打席の司令塔。打席結果カテゴリを softmax で1回抽選し、球数集計と打球処理を後段へ渡す。
# 処理順は 敬遠/バントの早期判定 → K/BB/HBP/BIP の抽選 → 球数 summary 生成 →
# BIP のみ ContactQualityModel/PhysicsResolver/PlayResolver へ接続。
# 戻り値は試合エンジンが読む {result, category, bases, pitch_summary, physical_traits, contact_quality}。

const RESULT_INTENTIONAL_WALK: String = "intentional_walk"
const RESULT_WALK: String = "walk"
const RESULT_STRIKEOUT: String = "strikeout"
const RESULT_HIT_BY_PITCH: String = "hit_by_pitch"

const CATEGORY_WALK: String = "walk"
const CATEGORY_HIT_BY_PITCH: String = "hit_by_pitch"
const CATEGORY_STRIKEOUT: String = "strikeout"
const CATEGORY_SACRIFICE: String = "sacrifice"

# 敬遠判定
const INTENTIONAL_WALK_BASE_DENOMINATOR: int = 1000

# 巡目・捕手影響・能力テール圧縮の調整係数。打席カテゴリ抽選と打球品質の両方へ効く。
# 巡目(times-through-order)ペナルティは 1巡目→2→3… の順で、3巡目以降にじわっと効く。
const TTO_PENALTY_PER_ROUND: Array = [0.0, 0.0, 0.05, 0.10, 0.15]
const TTO_PENALTY_Z_SCALE: float = 0.04 # PitcherUsageModel の display 点相当ペナルティをPAのlogit重みへ変換する。
const FRAMING_SCALE: float = 0.05         # 捕手フレーミング能力を「奪ったストライク数」へ変換する倍率。
const GAMECALL_CONTACT_COEF: float = 0.04 # 捕手の配球が打球の質(被コンタクト抑制)に効く係数。
# 救援は短い登板で最初から出力を上げられる。球数比率が上がるほど fade し、ロングは半分だけ効かせる。
const RELIEF_OUTPUT_BONUS_Z: float = 0.16
const RELIEF_OUTPUT_FADE_RATIO: float = 0.95
const LONG_RELIEF_OUTPUT_MULTIPLIER: float = 0.45
# テール圧縮の開始点(pivot)。母集団平均+0.5σ相当として一度実測した固定値であり、
# player_value_evaluator.gd の _ability_curve(center=0.4) と同種のただのチューニング定数
# (母集団を追跡・再計算する仕組みではない)。
const PITCHER_OUTPUT_TAIL_PIVOT: float = 1.7843
const PITCHER_OUTPUT_TAIL_SPAN: float = 100.0
const PITCHER_STUFF_TAIL_PIVOT: float = 2.0684
const PITCHER_STUFF_TAIL_SPAN: float = 100.0
const BATTER_HR_TAIL_PIVOT: float = 2.6190
const BATTER_HR_TAIL_SPAN: float = 1.20
const BATTER_AVOID_K_TAIL_PIVOT: float = 1.1550
const BATTER_AVOID_K_TAIL_SPAN: float = 0.80
const BATTER_CONTACT_TAIL_PIVOT: float = 1.4678
const BATTER_CONTACT_TAIL_SPAN: float = 0.85
const BATTER_GAP_TAIL_PIVOT: float = 1.7849
const BATTER_GAP_TAIL_SPAN: float = 1.20
const BATTER_PATIENCE_TAIL_PIVOT: float = 1.3089
const BATTER_PATIENCE_TAIL_SPAN: float = 1.50
# バント企図の確率は「バント機会(走者あり・2アウト未満)1回あたり」で、下の係数を掛け合わせて作る。
# BUNT_BASE_PROBABILITY は基準状況(0アウト・走者一塁・平均的な打順)の企図率で、全体量のノブ。
const BUNT_BASE_PROBABILITY: float = 0.215
# 塁状況の係数。添字は走者コード(bit0=一塁, bit1=二塁, bit2=三塁)で、走者なしは使わない。
# 送りバントは一塁/一二塁に集中し、三塁走者ありのスクイズは稀、満塁ではほぼ出ない。
const BUNT_STATE_FACTORS: Array[float] = [0.00, 0.98, 0.54, 2.02, 0.40, 0.95, 0.43, 0.05]
# 打順スロット(0始まり)の係数。監督が下位打線と2番に送らせる度合いで、上げるとその打順が多く送る。
const BUNT_SLOT_FACTORS: Array[float] = [1.16, 1.13, 0.27, 0.05, 0.39, 0.61, 1.48, 2.45, 2.45]
# 1アウトでのバントは0アウトに対してどれだけ出るか。上げると1アウトからの送りが増える。
const BUNT_ONE_OUT_FACTOR: float = 0.26
# バント技術 z が企図率をどれだけ動かすか(打順係数が主で、これは同じ打順内の差)。
const BUNT_SKILL_WEIGHT: float = 0.10
const BUNT_SKILL_FACTOR_MIN: float = 0.60
const BUNT_SKILL_FACTOR_MAX: float = 1.40
# 大差(この点差以上)ではバントの価値が無いので企図を抑える。
const BUNT_BLOWOUT_MARGIN: int = 4
const BUNT_BLOWOUT_FACTOR: float = 0.35
# 終盤の同点/1点差では1点を取りにいくので企図を増やす。
const BUNT_LATE_INNING: int = 7
const BUNT_LATE_CLOSE_FACTOR: float = 1.30
# 投手が打席に立つ(DH無し)ときの倍率。
const BUNT_PITCHER_FACTOR: float = 2.00
const BUNT_PROBABILITY_MAX: float = 0.85
# バント安打(内野安打)。送りの構えからでも打者が生きることがあり、走者も1つ進む。
# 企図全体から先に抽選し、生きなかったぶんを犠打成立/失敗へ振り分ける。
# 上げると犠打が減って安打が増えるので、BUNT_BASE_PROBABILITY と対で調整する。
const BUNT_HIT_BASE: float = 0.025
const BUNT_HIT_SPEED_WEIGHT: float = 0.020
const BUNT_HIT_SPRAY_WEIGHT: float = 0.010
# 打球方向による内野安打のしやすさ。三塁線は送球が長く、投手正面は最も生きにくい。
const BUNT_HIT_POSITION_BONUS: Dictionary = {1: -0.025, 3: 0.005, 5: 0.045}
const BUNT_HIT_MIN: float = 0.002
const BUNT_HIT_MAX: float = 0.250
# スクイズ失敗時に三塁走者が本塁で刺される確率。残りは打者のゴロアウトのみで走者は留まる。
const BUNT_SQUEEZE_FAILURE_RUNNER_OUT_PROBABILITY: float = 0.65
# バント成功率(打者が生きなかったとき、走者が進んで犠打が記録される確率)。
# 失敗はゴロアウトで走者は進まない。
const BUNT_SUCCESS_BASE: float = 0.760
const BUNT_SUCCESS_SKILL_WEIGHT: float = 0.050
const BUNT_SUCCESS_RUNNER_SPEED_WEIGHT: float = 0.020
const BUNT_SUCCESS_FIRST_AND_SECOND_PENALTY: float = 0.060
const BUNT_SUCCESS_SQUEEZE_PENALTY: float = 0.120
const BUNT_SUCCESS_SECOND_ONLY_BONUS: float = 0.030
const BUNT_SUCCESS_MIN: float = 0.300
const BUNT_SUCCESS_MAX: float = 0.950
const HIT_AND_RUN_BIP_LOGIT_BONUS: float = 0.16
const HIT_AND_RUN_K_LOGIT_PENALTY: float = 0.05
const HIT_AND_RUN_BB_LOGIT_PENALTY: float = 0.30
const CACHE_BATTER_Z_VIEWS: String = "batter_z_views"
const CACHE_PITCHER_Z_VIEWS: String = "pitcher_z_views"
const CACHE_CATCHER_Z_VIEWS: String = "catcher_z_views"
const CACHE_PLATE_RULES: String = "plate_appearance_rules"
const CACHE_PROBABILITY_RULES: String = "pa_probability_rules"
const CACHE_CONTACT_RULES: String = "contact_quality_rules"
const CACHE_PLAY_RULES: String = "play_resolver_rules"


# 1試合の全打席で共有する読み取り専用データと、選手ID別の能力ビューを保持する。
# GameSimulator はmain threadで取得したrule_groupsをworkerへ渡し、試合別の可変cacheだけを
# worker内で作る。直接呼び出す経路では現在のrule snapshotをここで補う。
static func create_game_cache(rule_groups: Array[Dictionary] = []) -> Dictionary:
	var resolved_rule_groups: Array[Dictionary] = rule_groups
	if resolved_rule_groups.is_empty():
		resolved_rule_groups = ModManager.hot_rule_groups_snapshot()
	return {
		CACHE_BATTER_Z_VIEWS: {},
		CACHE_PITCHER_Z_VIEWS: {},
		CACHE_CATCHER_Z_VIEWS: {},
		CACHE_PLATE_RULES: _rule_group_view(resolved_rule_groups, ModManager.RULE_GROUP_PLATE_APPEARANCE),
		CACHE_PROBABILITY_RULES: _rule_group_view(resolved_rule_groups, ModManager.RULE_GROUP_PA_PROBABILITY),
		CACHE_CONTACT_RULES: _rule_group_view(resolved_rule_groups, ModManager.RULE_GROUP_CONTACT_QUALITY),
		CACHE_PLAY_RULES: _rule_group_view(resolved_rule_groups, ModManager.RULE_GROUP_PLAY_RESOLVER),
	}


static func _rule_group_view(rule_groups: Array[Dictionary], index: int) -> Dictionary:
	if index < 0 or index >= rule_groups.size():
		return {}
	return rule_groups[index]


static func resolve(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	is_reliever: bool = false,
	pitching_context: Dictionary = {},
	batting_context: Dictionary = {},
	game_cache: Dictionary = {}
) -> Dictionary:
	var hit_and_run: bool = _has_hit_and_run_intent(batting_context)
	var plate_rules: Dictionary = game_cache.get(CACHE_PLATE_RULES, {}) as Dictionary
	# 敬遠とバントは打席シーケンスに入らず早期判定する
	if _should_intentionally_walk(batter, pitcher, bases, outs):
		return _terminal_walk_outcome(RESULT_INTENTIONAL_WALK, _intentional_walk_pitch_summary())
	if not hit_and_run and _should_bunt(batter, bases, outs, plate_rules, batting_context):
		return _resolve_bunt(batter, bases)

	var precomp: Dictionary = _build_precomp(
		batter,
		pitcher,
		defense,
		pitching_context,
		is_reliever,
		game_cache,
		plate_rules
	)

	# 1) K/BB/HBP/BIP softmax 抽選
	var weights: Dictionary = PSPaProbabilityCalculator.build_weights(precomp)
	if hit_and_run:
		_apply_hit_and_run_weights(weights)
	var category_key: String = PSPaProbabilityCalculator.pick(weights)

	# 2) 球数 summary 生成 (1球ずつは回さず、打席ぶんをまとめて作る)
	var pitch_summary: Dictionary = PSPitchAggregateSimulator.simulate(category_key, precomp)

	# 3) カテゴリ別に terminal/BIP を分岐
	match category_key:
		PSPaProbabilityCalculator.OUTCOME_STRIKEOUT:
			return _terminal_strikeout_outcome(pitch_summary)
		PSPaProbabilityCalculator.OUTCOME_WALK:
			return _terminal_walk_outcome(RESULT_WALK, pitch_summary)
		PSPaProbabilityCalculator.OUTCOME_HIT_BY_PITCH:
			return _terminal_hbp_outcome(pitch_summary)
		_:  # BIP: 既存 ContactQualityModel → PhysicsResolver → PlayResolver を流用
			var bip_outcome: Dictionary = _resolve_bip(batter, pitcher, defense, bases, outs, precomp, pitch_summary)
			if hit_and_run:
				bip_outcome["batting_strategy"] = "hit_and_run"
			return bip_outcome


static func _has_hit_and_run_intent(context: Dictionary) -> bool:
	for intent_value in context.get("runner_intents", []) as Array:
		if str((intent_value as Dictionary).get("strategy", "")) == "hit_and_run":
			return true
	return false


# エンドランは四球待ちよりスイング/コンタクトを優先する。集約PAモデルでは
# BIP logit を少し上げ、BB/K logit を下げることでその方針を近似する。
static func _apply_hit_and_run_weights(weights: Dictionary) -> void:
	weights[PSPaProbabilityCalculator.OUTCOME_BIP] = float(weights.get(PSPaProbabilityCalculator.OUTCOME_BIP, 0.0)) + HIT_AND_RUN_BIP_LOGIT_BONUS
	weights[PSPaProbabilityCalculator.OUTCOME_STRIKEOUT] = float(weights.get(PSPaProbabilityCalculator.OUTCOME_STRIKEOUT, 0.0)) - HIT_AND_RUN_K_LOGIT_PENALTY
	weights[PSPaProbabilityCalculator.OUTCOME_WALK] = float(weights.get(PSPaProbabilityCalculator.OUTCOME_WALK, 0.0)) - HIT_AND_RUN_BB_LOGIT_PENALTY


static func _resolve_bip(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	precomp: Dictionary,
	pitch_summary: Dictionary
) -> Dictionary:
	# pitch_outcome は ContactQualityModel が in_zone/location_height/two_strike を読むので
	# 集計から spawn する代替値を渡す。
	var pitch_outcome: Dictionary = _synthesize_contact_pitch_outcome(precomp, pitch_summary)
	var state: Dictionary = {}
	var quality: Dictionary = PSContactQualityModel.generate(batter, pitcher, pitch_outcome, state, precomp)
	var physics: Dictionary = PSBattedBallPhysicsResolver.compute(quality)
	var play_rules: Dictionary = precomp.get("_play_resolver_rules", {}) as Dictionary
	var result: Dictionary = PSPlayResolver.resolve(
		batter,
		pitcher,
		defense,
		bases,
		outs,
		physics,
		quality,
		play_rules
	)
	if str(result.get("result", "")) == PSPlayResolver.RESULT_FOUL_BACK:
		# Aggregate モデルでは foul → 再投球の概念がない。
		# foul_back が出た場合は強制的に out 判定へ落とす（極めて稀）。
		result["result"] = "groundout_pitcher"
		result["category"] = "out"
		result["bases"] = 0
	result["pitch_summary"] = pitch_summary
	result["physical_traits"] = _physical_traits_from_physics(physics)
	result["contact_quality"] = quality
	return result


# ContactQualityModel が読む in_zone/location_height/two_strike/protective_out/pitch_velocity を、
# 集計値から決定論的に合成する。pitch_velocity は precomp の proxy を使う。
static func _synthesize_contact_pitch_outcome(precomp: Dictionary, pitch_summary: Dictionary) -> Dictionary:
	var pitches: int = int(pitch_summary.get("pitches", 1))
	var _balls: int = int(pitch_summary.get("balls", 0))
	var strikes: int = int(pitch_summary.get("strikes", 0))
	var in_zone_pitches: int = int(pitch_summary.get("in_zone_pitches", 0))
	var in_zone: bool = in_zone_pitches >= (pitches - in_zone_pitches)  # 多数派ゾーン
	var two_strike: bool = strikes >= 2
	var location_seed: int = hash("loc") ^ hash(precomp.get("event_index", 0)) ^ hash(precomp.get("batter_id", 0)) ^ hash(precomp.get("pitcher_id", 0))
	var loc_roll: float = float(abs(location_seed) % 1000) / 1000.0
	var location_height: String
	if in_zone:
		location_height = "high" if loc_roll < 0.30 else ("middle" if loc_roll < 0.70 else "low")
	else:
		location_height = "high" if loc_roll < 0.40 else ("middle" if loc_roll < 0.55 else "low")
	return {
		"outcome": "contact",
		"in_zone": in_zone,
		"swing": true,
		"whiff": false,
		"contact": true,
		"location_height": location_height,
		"two_strike_protective": two_strike,
		"protective_out": false,
		"pitch_velocity": int(precomp.get("pitch_velocity_proxy", 142)),
	}


static func _physical_traits_from_physics(physics: Dictionary) -> Dictionary:
	return {
		"exit_velocity": float(physics.get("exit_velocity", 0.0)),
		"launch_angle": float(physics.get("launch_angle", 0.0)),
		"distance": float(physics.get("distance", 0.0)),
		"hang_time": float(physics.get("hang_time", 0.0)),
		"carry_multiplier": float(physics.get("carry_multiplier", 1.0)),
		"is_barrel": bool(physics.get("is_barrel", false)),
		"is_hard_hit": bool(physics.get("is_hard_hit", false)),
		"spray_angle": float(physics.get("spray_angle", 0.0)),
		"trajectory_bucket": str(physics.get("trajectory_bucket", "")),
	}


static func _terminal_walk_outcome(result: String, pitch_summary: Dictionary) -> Dictionary:
	return {
		"result": result,
		"category": CATEGORY_WALK,
		"bases": 0,
		"pitch_summary": pitch_summary,
	}


static func _terminal_strikeout_outcome(pitch_summary: Dictionary) -> Dictionary:
	return {
		"result": RESULT_STRIKEOUT,
		"category": CATEGORY_STRIKEOUT,
		"bases": 0,
		"pitch_summary": pitch_summary,
	}


static func _terminal_hbp_outcome(pitch_summary: Dictionary) -> Dictionary:
	return {
		"result": RESULT_HIT_BY_PITCH,
		"category": CATEGORY_HIT_BY_PITCH,
		"bases": 0,
		"pitch_summary": pitch_summary,
	}


# 敬遠は便宜的に 4 球すべてボール扱いで集計する。
static func _intentional_walk_pitch_summary() -> Dictionary:
	return {
		"pitches": 4,
		"balls": 4,
		"strikes": 0,
		"final_count": "4-0",
		"swings": 0,
		"whiffs": 0,
		"called_strikes": 0,
		"fouls": 0,
		"in_zone_pitches": 0,
		"out_zone_pitches": 4,
		"first_pitch_strike": false,
		"csw": 0,
	}


# バント関係は 1 球で打ったものとして集計する。
static func _bunt_pitch_summary(was_strike_thrown: bool) -> Dictionary:
	return {
		"pitches": 1,
		"balls": 0,
		"strikes": 1 if was_strike_thrown else 0,
		"final_count": "0-1" if was_strike_thrown else "0-0",
		"swings": 1,
		"whiffs": 0,
		"called_strikes": 0,
		"fouls": 0,
		"in_zone_pitches": 1 if was_strike_thrown else 0,
		"out_zone_pitches": 0 if was_strike_thrown else 1,
		"first_pitch_strike": was_strike_thrown,
		"csw": 0,
	}


# 敬遠判定。
# 強打者 = Bat_Impact + Bat_Barrel + Bat_BBCreate の合算。
# 投手の自信 = Pit_BBPrevent + Pit_LoftControl。
static func _should_intentionally_walk(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases: Array,
	outs: int
) -> bool:
	if outs < 2:
		return false
	if _has_runner(bases, 0):
		return false
	if not (_has_runner(bases, 1) or _has_runner(bases, 2)):
		return false
	if batter == null or pitcher == null:
		return false
	# z 値合算: 強打者ほど + 投手自信ほど -
	var batter_threat_z: float = batter.z_ability("Bat_Impact", 0.0) * 2.0 + batter.z_ability("Bat_Barrel", 0.0) + batter.z_ability("Bat_BBCreate", 0.0) * 0.5
	var pitcher_confidence_z: float = pitcher.z_ability("Pit_BBPrevent", 0.0) + pitcher.z_ability("Pit_LoftControl", 0.0) * 0.5
	# z 1σ あたりの影響を整数確率スケールへ変換する。
	var chance_f: float = (batter_threat_z - pitcher_confidence_z - 0.5) * 8.0
	if _has_runner(bases, 1) and _has_runner(bases, 2):
		chance_f += 8.0
	var chance: int = int(clamp(round(chance_f), 0.0, 35.0))
	return Rng.range_int(0, INTENTIONAL_WALK_BASE_DENOMINATOR - 1) < chance


# バント判定。監督判断なので「その打者を何番に置いたか」を主軸に置き、塁状況・アウト・
# 試合状況(イニングと点差)で増減させる。各係数を掛け合わせた値がバント機会1回あたりの企図率。
# batting_context に batting_slot / inning / score_margin が無い呼び出し(単体テストや probe)では
# 該当する係数を 1.0 として扱うので、打者と塁状況だけでも判定できる。
static func _should_bunt(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	rules: Dictionary = {},
	context: Dictionary = {}
) -> bool:
	if outs >= 2 or batter == null:
		return false
	var base_code: int = _base_code(bases)
	if base_code == 0:
		return false
	var probability: float = _rule_float(rules, "bunt_base_probability", BUNT_BASE_PROBABILITY)
	probability *= BUNT_STATE_FACTORS[base_code]
	probability *= _bunt_slot_factor(int(context.get("batting_slot", -1)))
	if outs >= 1:
		probability *= _rule_float(rules, "bunt_one_out_factor", BUNT_ONE_OUT_FACTOR)
	probability *= _bunt_game_state_factor(context, rules)
	probability *= clamp(
		1.0 + _bunt_skill_z(batter) * _rule_float(rules, "bunt_skill_weight", BUNT_SKILL_WEIGHT),
		BUNT_SKILL_FACTOR_MIN,
		BUNT_SKILL_FACTOR_MAX
	)
	if batter.is_pitcher():
		probability *= _rule_float(rules, "bunt_pitcher_factor", BUNT_PITCHER_FACTOR)
	return Rng.roll_float() < clamp(probability, 0.0, BUNT_PROBABILITY_MAX)


# 打順スロット(0始まり)の係数。スロットが不明な呼び出しでは打順による差を付けない。
static func _bunt_slot_factor(batting_slot: int) -> float:
	if batting_slot < 0 or batting_slot >= BUNT_SLOT_FACTORS.size():
		return 1.0
	return BUNT_SLOT_FACTORS[batting_slot]


# イニングと点差による係数。大差では抑え、終盤の同点/1点差では増やす。
# score_margin は攻撃側から見た点差(正ならリード)。イニングが不明なら係数を掛けない。
static func _bunt_game_state_factor(context: Dictionary, rules: Dictionary) -> float:
	var inning: int = int(context.get("inning", 0))
	if inning <= 0:
		return 1.0
	var margin: int = absi(int(context.get("score_margin", 0)))
	if margin >= int(_rule_float(rules, "bunt_blowout_margin", float(BUNT_BLOWOUT_MARGIN))):
		return _rule_float(rules, "bunt_blowout_factor", BUNT_BLOWOUT_FACTOR)
	if inning >= BUNT_LATE_INNING and margin <= 1:
		return _rule_float(rules, "bunt_late_close_factor", BUNT_LATE_CLOSE_FACTOR)
	return 1.0


# z 近似 bunt skill: Spray(方向制御) と KAvoid(コンタクト) が +、Impact/Barrel が -。
static func _bunt_skill_z(batter: PSPlayerSeasonRecord) -> float:
	if batter == null:
		return 0.0
	return 0.5 * batter.z_ability("Bat_Spray", 0.0) \
		+ 0.3 * batter.z_ability("Bat_KAvoid", 0.0) \
		- 0.4 * batter.z_ability("Bat_Impact", 0.0) \
		- 0.2 * batter.z_ability("Bat_Barrel", 0.0)


# バント処理。企図の結末は3通り:
#   バント安打 = 打者が一塁で生き、走者も1つ進む (内野安打として記録)
#   犠打成立   = 打者アウトで走者が1つ進む
#   失敗       = 走者は進まない。三塁走者がいるスクイズ崩れでは本塁で刺されることがあり、
#                それ以外は打者のゴロアウトのみ
static func _resolve_bunt(batter: PSPlayerSeasonRecord, bases: Array) -> Dictionary:
	var position: int = _roll_bunt_position()
	var squeeze: bool = _has_runner(bases, 2)
	if Rng.roll_float() < _bunt_hit_probability(batter, position):
		return {
			"result": "bunt_single_%s" % PSPlayResolver.FIELD_NAMES.get(position, "unknown"),
			"category": "hit",
			"bases": 1,
			"fielder_position": position,
			"pitch_summary": _bunt_pitch_summary(true),
		}
	if Rng.roll_float() < _bunt_success_probability(batter, bases):
		return {
			"result": "%s_%s" % [
				"squeeze_bunt" if squeeze else "sacrifice_bunt",
				PSPlayResolver.FIELD_NAMES.get(position, "unknown"),
			],
			"category": CATEGORY_SACRIFICE,
			"bases": 0,
			"fielder_position": position,
			"runner_strategy": "squeeze" if squeeze else "sacrifice_bunt",
			"pitch_summary": _bunt_pitch_summary(true),
		}
	# スクイズ崩れ: 本塁へ突っ込んだ三塁走者が刺され、打者は野選で一塁へ生きる。
	if squeeze and Rng.roll_float() < BUNT_SQUEEZE_FAILURE_RUNNER_OUT_PROBABILITY:
		var outcome: Dictionary = PSPlayResolver.fielders_choice_outcome(bases, position, 3, 4)
		outcome["result"] = "failed_squeeze_bunt_%s" % PSPlayResolver.FIELD_NAMES.get(position, "unknown")
		outcome["pitch_summary"] = _bunt_pitch_summary(true)
		return outcome
	# バント失敗: ゴロアウトとして処理
	return {
		"result": "failed_bunt_groundout_%s" % PSPlayResolver.FIELD_NAMES.get(position, "unknown"),
		"category": "out",
		"bases": 0,
		"fielder_position": position,
		"pitch_summary": _bunt_pitch_summary(true),
	}


# バント安打になる確率。走力と方向制御が高いほど、また三塁線へ転がすほど生きやすい。
# 能力 z の母集団平均は 0 ではないので、BUNT_HIT_BASE がそのぶんを畳み込んだ基準値になる。
static func _bunt_hit_probability(batter: PSPlayerSeasonRecord, position: int) -> float:
	if batter == null:
		return 0.0
	var probability: float = BUNT_HIT_BASE \
		+ batter.z_ability("Run_Speed", 0.0) * BUNT_HIT_SPEED_WEIGHT \
		+ batter.z_ability("Bat_Spray", 0.0) * BUNT_HIT_SPRAY_WEIGHT \
		+ float(BUNT_HIT_POSITION_BONUS.get(position, 0.0))
	return clamp(probability, BUNT_HIT_MIN, BUNT_HIT_MAX)


# 打者が生きなかったとき、走者が進んで犠打が記録される確率。
# バント技術 z と最速走者の走力で上がり、走者状況で増減する。
static func _bunt_success_probability(batter: PSPlayerSeasonRecord, bases: Array) -> float:
	var runner_plus: float = 0.0
	for index in range(3):
		if _has_runner(bases, index):
			runner_plus = max(runner_plus, _runner_speed(bases, index) * BUNT_SUCCESS_RUNNER_SPEED_WEIGHT)
	var success_prob: float = BUNT_SUCCESS_BASE + _bunt_skill_z(batter) * BUNT_SUCCESS_SKILL_WEIGHT + runner_plus
	if _has_runner(bases, 2):
		success_prob -= BUNT_SUCCESS_SQUEEZE_PENALTY
	elif _has_runner(bases, 0) and _has_runner(bases, 1):
		success_prob -= BUNT_SUCCESS_FIRST_AND_SECOND_PENALTY
	elif _has_runner(bases, 1) and not _has_runner(bases, 0):
		success_prob += BUNT_SUCCESS_SECOND_ONLY_BONUS
	return clamp(success_prob, BUNT_SUCCESS_MIN, BUNT_SUCCESS_MAX)


static func _roll_bunt_position() -> int:
	var roll: int = Rng.range_int(0, 99)
	if roll <= 40:
		return 1   # pitcher
	if roll <= 70:
		return 3   # first base
	return 5       # third base


static func _has_runner(bases: Array, base_index: int) -> bool:
	return base_index >= 0 and base_index < bases.size() and bases[base_index] != null


# 走者コード: bit0=一塁, bit1=二塁, bit2=三塁。BUNT_STATE_FACTORS の添字。
static func _base_code(bases: Array) -> int:
	var code: int = 0
	for index in range(3):
		if _has_runner(bases, index):
			code |= 1 << index
	return code


# 指定塁の走者の走力を z で返す（0.0 が全体平均）。
static func _runner_speed(bases: Array, base_index: int) -> float:
	if not _has_runner(bases, base_index):
		return 0.0
	var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
	return runner.z_ability("Run_Speed", 0.0)


# z_abilities ソースの precomp を構築する。
# ContactQualityModel へは z 値 (batter_contact_z/gap_z/hr_z/avoid_k_z, pitcher_stuff_z) を
# 直接渡し、curve はモデル内で ability_curve_z が算出する（表示 1-100 点は経由しない）。
static func _build_precomp(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	pitching_context: Dictionary,
	is_reliever: bool,
	game_cache: Dictionary = {},
	plate_rules: Dictionary = {}
) -> Dictionary:
	if plate_rules.is_empty() and game_cache.has(CACHE_PLATE_RULES):
		plate_rules = game_cache.get(CACHE_PLATE_RULES, {}) as Dictionary
	# z 視点ビュー
	var batter_z: Dictionary = _batter_z_view(batter, game_cache, plate_rules)
	var pitcher_z_raw: Dictionary = _pitcher_z_view(pitcher, game_cache)
	var catcher_z: Dictionary = _catcher_z_view(_catcher_record(defense), game_cache)

	# pitching_context を z 空間へ翻訳
	var usage_penalty: int = int(pitching_context.get("pitcher_usage_penalty", 0))
	var tto_round: int = int(pitching_context.get("pitcher_tto_round", 0))
	var tto_penalty: int = int(pitching_context.get("pitcher_tto_penalty", 0))
	var arsenal_bonus: int = int(pitching_context.get("pitcher_arsenal_bonus", 0))
	var command_leak: float = float(pitching_context.get("pitcher_command_leak", 0.0)) * 0.60
	var contact_damage: float = float(pitching_context.get("pitcher_contact_damage", 0.0)) * 0.55
	var pitcher_role: String = str(pitching_context.get("pitcher_role", ""))
	var outing_ratio: float = float(pitching_context.get("pitcher_fatigue_ratio", 0.0))
	# 球種傾向(微差): K寄り/ゴロ寄り/被弾の集計スカラー。
	var arsenal_k_bias: float = float(pitching_context.get("pitcher_arsenal_k_bias", 0.0))
	var arsenal_gb_bias: float = float(pitching_context.get("pitcher_arsenal_gb_bias", 0.0))
	var arsenal_hr_bias: float = float(pitching_context.get("pitcher_arsenal_hr_bias", 0.0))
	var tto_array: Array = TTO_PENALTY_PER_ROUND
	var tto_round_weight: float = 0.0
	if tto_penalty > 0:
		tto_round_weight = float(tto_penalty) * TTO_PENALTY_Z_SCALE
	elif tto_round >= 0 and tto_round < tto_array.size():
		tto_round_weight = float(tto_array[tto_round])
	# z 空間 delta (1 display point ≈ 0.08σ)
	var pitcher_z: Dictionary = pitcher_z_raw.duplicate()
	pitcher_z["Pit_KCreate"] = float(pitcher_z.get("Pit_KCreate", 0.0)) - float(usage_penalty) * 0.04
	pitcher_z["Pit_BBPrevent"] = float(pitcher_z.get("Pit_BBPrevent", 0.0)) - float(usage_penalty) * 0.04 - command_leak * 0.10
	pitcher_z["Pit_EdgeRate"] = float(pitcher_z.get("Pit_EdgeRate", 0.0)) + float(arsenal_bonus) * 0.08

	# 疲労 (球数ベース): 当試合の outing pitches を pitching_context から取り出す。
	var outing_pitches: int = int(pitching_context.get("pitcher_outing_pitches", 0))
	var fatigue_factor: float
	if pitching_context.has("pitcher_fatigue_factor"):
		fatigue_factor = float(pitching_context.get("pitcher_fatigue_factor", 1.0))
	else:
		fatigue_factor = PSFatigueCalculator.factor_for_pitcher(pitcher, is_reliever, outing_pitches)
	PSFatigueCalculator.apply_drops_in_place(pitcher_z, fatigue_factor)
	if is_reliever:
		_apply_relief_output_bonus(pitcher_z, pitcher_role, outing_ratio, plate_rules)

	# 利き腕プラトーン: 同利き腕なら -1（不利）、逆なら +1
	var platoon_sign: float = _platoon_sign(batter, pitcher)
	var framing_strikes: float = float(catcher_z.get("C_Framing", 0.0)) * FRAMING_SCALE
	var game_call_z: float = float(catcher_z.get("C_GameCall", 0.0))
	pitcher_z["Pit_ImpactLimit"] = float(pitcher_z.get("Pit_ImpactLimit", 0.0)) + game_call_z * GAMECALL_CONTACT_COEF
	pitcher_z["Pit_BarrelDeny"] = float(pitcher_z.get("Pit_BarrelDeny", 0.0)) + game_call_z * GAMECALL_CONTACT_COEF

	_apply_pitcher_tail_limits(pitcher_z, plate_rules)

	# ContactQualityModel 用の z 派生。
	var batter_contact_z: float = float(batter_z.get("Bat_Barrel", 0.0))
	var batter_gap_z: float = float(batter_z.get("Bat_Impact", 0.0))
	var batter_hr_z: float = _limited_batter_hr_z(batter_z, plate_rules)
	var batter_avoid_k_z: float = float(batter_z.get("Bat_KAvoid", 0.0))
	var pitcher_stuff_z: float = _limited_pitcher_stuff_z(pitcher_z, plate_rules)

	# pitcher 派生情報。pitch_velocity は ContactQualityModel の EV 補正で使う球速 proxy(km/h)。
	var pitch_velocity_proxy: int = 142 + int(round(float(pitcher_z.get("Pit_EdgeRate", 0.0)) * 4.0))

	return {
		# 新 z 視点ビュー
		"batter_z": batter_z,
		"pitcher_z": pitcher_z,
		"catcher_z": catcher_z,
		# softmax / aggregate 用の派生
		"fatigue_factor": fatigue_factor,
		"tto_round": tto_round,
		"tto_round_weight": tto_round_weight,
		"platoon_sign": platoon_sign,
		"framing_strikes": framing_strikes,
		"pitcher_command_leak": command_leak,
		# 球種傾向(微差) — pa_probability_calculator(K) / contact_quality_model(LA,被弾) が読む。
		"arsenal_k_bias": arsenal_k_bias,
		"pitcher_gb_bias": arsenal_gb_bias,
		"pitcher_hr_bias": arsenal_hr_bias,
		# pitcher 派生（合成 pitch_outcome / ContactQualityModel が読む）
		"pitch_velocity_proxy": pitch_velocity_proxy,
		"pitcher_contact_damage": contact_damage,
		"pitcher_trouble_score": float(pitching_context.get("pitcher_trouble_score", 0.0)),
		"pitcher_meltdown": bool(pitching_context.get("pitcher_meltdown", false)),
		# 識別子（aggregate simulator の決定論ロールで使う）
		"event_index": int(pitching_context.get("event_index", 0)),
		"batter_id": 0 if batter == null else batter.player_id,
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		# ContactQualityModel が読む z 値（curve は ContactQualityModel 内で ability_curve_z 算出）
		"batter_contact_z": batter_contact_z,
		"batter_gap_z": batter_gap_z,
		"batter_hr_z": batter_hr_z,
		"batter_avoid_k_z": batter_avoid_k_z,
		"batter_fatigue": 0 if batter == null else batter.fatigue,
		"batter_is_pitcher": batter != null and batter.is_pitcher(),
		"pitcher_stuff_z": pitcher_stuff_z,
		"_pa_probability_rules": game_cache.get(CACHE_PROBABILITY_RULES, {}),
		"_contact_quality_rules": game_cache.get(CACHE_CONTACT_RULES, {}),
		"_play_resolver_rules": game_cache.get(CACHE_PLAY_RULES, {}),
	}


static func _apply_relief_output_bonus(
	pitcher_z: Dictionary,
	role: String,
	outing_ratio: float,
	rules: Dictionary = {}
) -> void:
	var fade: float = clamp(1.0 - max(0.0, outing_ratio) / RELIEF_OUTPUT_FADE_RATIO, 0.0, 1.0)
	if fade <= 0.0:
		return
	var multiplier: float = LONG_RELIEF_OUTPUT_MULTIPLIER if role == PSPitcherUsageModel.ROLE_LONG_RELIEF else 1.0
	var bonus: float = _rule_float(rules, "relief_output_bonus_z", RELIEF_OUTPUT_BONUS_Z) * fade * multiplier
	pitcher_z["Pit_KCreate"] = float(pitcher_z.get("Pit_KCreate", 0.0)) + bonus
	pitcher_z["Pit_BBPrevent"] = float(pitcher_z.get("Pit_BBPrevent", 0.0)) + bonus * 0.5
	pitcher_z["Pit_EdgeRate"] = float(pitcher_z.get("Pit_EdgeRate", 0.0)) + bonus * 0.625
	pitcher_z["Pit_ImpactLimit"] = float(pitcher_z.get("Pit_ImpactLimit", 0.0)) + bonus * 0.5
	pitcher_z["Pit_BarrelDeny"] = float(pitcher_z.get("Pit_BarrelDeny", 0.0)) + bonus * 0.5


static func _apply_batter_tail_limits(batter_z: Dictionary, rules: Dictionary) -> void:
	batter_z["Bat_Barrel"] = PSBalanceProfile.compress_z_tail(
		float(batter_z.get("Bat_Barrel", 0.0)),
		_rule_float(rules, "batter_contact_tail_pivot", BATTER_CONTACT_TAIL_PIVOT),
		_rule_float(rules, "batter_contact_tail_span", BATTER_CONTACT_TAIL_SPAN)
	)
	batter_z["Bat_Impact"] = PSBalanceProfile.compress_z_tail(
		float(batter_z.get("Bat_Impact", 0.0)),
		_rule_float(rules, "batter_gap_tail_pivot", BATTER_GAP_TAIL_PIVOT),
		_rule_float(rules, "batter_gap_tail_span", BATTER_GAP_TAIL_SPAN)
	)
	batter_z["Bat_BBCreate"] = PSBalanceProfile.compress_z_tail(
		float(batter_z.get("Bat_BBCreate", 0.0)),
		_rule_float(rules, "batter_patience_tail_pivot", BATTER_PATIENCE_TAIL_PIVOT),
		_rule_float(rules, "batter_patience_tail_span", BATTER_PATIENCE_TAIL_SPAN)
	)
	batter_z["Bat_KAvoid"] = PSBalanceProfile.compress_z_tail(
		float(batter_z.get("Bat_KAvoid", 0.0)),
		_rule_float(rules, "batter_avoid_k_tail_pivot", BATTER_AVOID_K_TAIL_PIVOT),
		_rule_float(rules, "batter_avoid_k_tail_span", BATTER_AVOID_K_TAIL_SPAN)
	)


static func _apply_pitcher_tail_limits(pitcher_z: Dictionary, rules: Dictionary) -> void:
	pitcher_z["Pit_KCreate"] = PSBalanceProfile.compress_z_tail(
		float(pitcher_z.get("Pit_KCreate", 0.0)),
		_rule_float(rules, "pitcher_output_tail_pivot", PITCHER_OUTPUT_TAIL_PIVOT),
		_rule_float(rules, "pitcher_output_tail_span", PITCHER_OUTPUT_TAIL_SPAN)
	)
	pitcher_z["Pit_BBPrevent"] = PSBalanceProfile.compress_z_tail(
		float(pitcher_z.get("Pit_BBPrevent", 0.0)),
		_rule_float(rules, "pitcher_output_tail_pivot", PITCHER_OUTPUT_TAIL_PIVOT),
		_rule_float(rules, "pitcher_output_tail_span", PITCHER_OUTPUT_TAIL_SPAN)
	)


static func _limited_batter_hr_z(batter_z: Dictionary, rules: Dictionary = {}) -> float:
	var raw: float = float(batter_z.get("Bat_Impact", 0.0)) + 0.5 * float(batter_z.get("Bat_Loft", 0.0))
	return PSBalanceProfile.compress_z_tail(
		raw,
		_rule_float(rules, "batter_hr_tail_pivot", BATTER_HR_TAIL_PIVOT),
		_rule_float(rules, "batter_hr_tail_span", BATTER_HR_TAIL_SPAN)
	)


static func _limited_pitcher_stuff_z(pitcher_z: Dictionary, rules: Dictionary = {}) -> float:
	var raw: float = float(pitcher_z.get("Pit_BarrelDeny", 0.0)) + 0.5 * float(pitcher_z.get("Pit_ImpactLimit", 0.0))
	return PSBalanceProfile.compress_z_tail(
		raw,
		_rule_float(rules, "pitcher_stuff_tail_pivot", PITCHER_STUFF_TAIL_PIVOT),
		_rule_float(rules, "pitcher_stuff_tail_span", PITCHER_STUFF_TAIL_SPAN)
	)


static func _platoon_sign(batter: PSPlayerSeasonRecord, pitcher: PSPlayerSeasonRecord) -> float:
	if batter == null or pitcher == null:
		return 0.0
	var bat_hand: String = batter.batting_side
	var pit_hand: String = pitcher.throwing_hand
	# Switch hitter は逆向きに設定するとして +1 を返す（仮）
	if bat_hand == "S":
		return 1.0
	# 同利き腕 → 打者不利（-1）。逆 → +1。
	if bat_hand == pit_hand:
		return -1.0
	return 1.0


static func _catcher_record(defense: Dictionary) -> PSPlayerSeasonRecord:
	var direct: PSPlayerSeasonRecord = defense.get("catcher", null) as PSPlayerSeasonRecord
	if direct != null:
		return direct
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == 2:
			var catcher: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
			defense["catcher"] = catcher
			return catcher
	return null


static func _batter_z_view(
	record: PSPlayerSeasonRecord,
	game_cache: Dictionary,
	rules: Dictionary
) -> Dictionary:
	if game_cache.is_empty():
		var direct_view: Dictionary = PSZAbilityAdapter.batter_view(record)
		_apply_batter_tail_limits(direct_view, rules)
		return direct_view
	var views: Dictionary = game_cache.get(CACHE_BATTER_Z_VIEWS, {}) as Dictionary
	var key: int = 0 if record == null else int(record.get_instance_id())
	if not views.has(key):
		var view: Dictionary = PSZAbilityAdapter.batter_view(record)
		_apply_batter_tail_limits(view, rules)
		views[key] = view
		game_cache[CACHE_BATTER_Z_VIEWS] = views
	return views[key] as Dictionary


static func _pitcher_z_view(record: PSPlayerSeasonRecord, game_cache: Dictionary) -> Dictionary:
	if game_cache.is_empty():
		return PSZAbilityAdapter.pitcher_view(record)
	var views: Dictionary = game_cache.get(CACHE_PITCHER_Z_VIEWS, {}) as Dictionary
	var key: int = 0 if record == null else int(record.get_instance_id())
	if not views.has(key):
		views[key] = PSZAbilityAdapter.pitcher_view(record)
		game_cache[CACHE_PITCHER_Z_VIEWS] = views
	return views[key] as Dictionary


static func _catcher_z_view(record: PSPlayerSeasonRecord, game_cache: Dictionary) -> Dictionary:
	if game_cache.is_empty():
		return PSZAbilityAdapter.catcher_view(record)
	var views: Dictionary = game_cache.get(CACHE_CATCHER_Z_VIEWS, {}) as Dictionary
	var key: int = 0 if record == null else int(record.get_instance_id())
	if not views.has(key):
		views[key] = PSZAbilityAdapter.catcher_view(record)
		game_cache[CACHE_CATCHER_Z_VIEWS] = views
	return views[key] as Dictionary


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
	return ModManager.rule_group_float(ModManager.RULE_GROUP_PLATE_APPEARANCE, name, fallback)
