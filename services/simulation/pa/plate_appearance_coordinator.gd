extends RefCounted
class_name PSPlateAppearanceCoordinator

# Phase 2 §7-10: PA 駆動部を softmax + 球数集計モデルへ刷新。
# 旧 pitch-by-pitch ループ (MAX_PITCHES_PER_PA=16) を廃止し、PSPaProbabilityCalculator で K/BB/HBP/BIP を
# 1 度抽選 → PSPitchAggregateSimulator で球数 summary を生成 → BIP は既存 ContactQualityModel に流す。
# 戻り値 schema は変更なし: {result, category, bases, pitch_summary, physical_traits, contact_quality}。

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

# --- 調整係数（旧 simulation_tuning.tres から移設。巡目・捕手まわりをここで直接調整する） ---
# 巡目(times-through-order)ペナルティ重み。1巡目→2→3…。3巡目以降にじわっと効く。
const TTO_PENALTY_PER_ROUND: Array = [0.0, 0.0, 0.05, 0.10, 0.15]
const FRAMING_SCALE: float = 0.05         # 捕手フレーミング能力を「奪ったストライク数」へ変換する倍率。
const GAMECALL_CONTACT_COEF: float = 0.04 # 捕手の配球が打球の質(被コンタクト抑制)に効く係数。


static func resolve(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	is_reliever: bool = false,
	pitching_context: Dictionary = {}
) -> Dictionary:
	# 敬遠とバントは打席シーケンスに入らず早期判定する
	if _should_intentionally_walk(batter, pitcher, bases, outs):
		return _terminal_walk_outcome(RESULT_INTENTIONAL_WALK, _intentional_walk_pitch_summary())
	if _should_bunt(batter, bases, outs):
		return _resolve_bunt(batter, bases)

	var precomp: Dictionary = _build_precomp(batter, pitcher, defense, pitching_context, is_reliever)

	# 1) K/BB/HBP/BIP softmax 抽選
	var weights: Dictionary = PSPaProbabilityCalculator.build_weights(precomp)
	var category_key: String = PSPaProbabilityCalculator.pick(weights)

	# 2) 球数 summary 生成 (pitch-by-pitch 廃止)
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
			return _resolve_bip(batter, pitcher, defense, bases, outs, precomp, pitch_summary)


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
	var result: Dictionary = PSPlayResolver.resolve(batter, pitcher, defense, bases, outs, physics, quality)
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
	var balls: int = int(pitch_summary.get("balls", 0))
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


# 敬遠判定 (z_abilities 評価へ移行)。
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
	# z 1σ ≒ display 12.5pt ≒ 旧 chance 4 相当の影響度
	var chance_f: float = (batter_threat_z - pitcher_confidence_z - 0.5) * 8.0
	if _has_runner(bases, 1) and _has_runner(bases, 2):
		chance_f += 8.0
	var chance: int = int(clamp(round(chance_f), 0.0, 35.0))
	return Rng.range_int(0, INTENTIONAL_WALK_BASE_DENOMINATOR - 1) < chance


# バント判定 (z_abilities 評価へ移行)。
# bunt_z = 0.5*Bat_Spray + 0.3*Bat_KAvoid - 0.4*Bat_Impact - 0.2*Bat_Barrel
# 投手バンド (+220 バイアス) は維持。
static func _should_bunt(batter: PSPlayerSeasonRecord, bases: Array, outs: int) -> bool:
	if outs >= 2:
		return false
	if not (_has_runner(bases, 0) or _has_runner(bases, 1) or _has_runner(bases, 2)):
		return false
	if batter == null:
		return false
	var bat_impact: float = batter.z_ability("Bat_Impact", 0.0)
	var bat_barrel: float = batter.z_ability("Bat_Barrel", 0.0)
	# 強打者は通常稀にしかバントしない
	if bat_impact > 1.5 or bat_barrel > 1.5:
		return Rng.range_int(0, 99) < 6
	var bunt_z: float = _bunt_skill_z(batter)
	# バント確率(0..1)。バント技術 z が高いほど上げ、長打力(Impact)・芯(Barrel) z が高いほど下げる。
	# アウトが増えるほど下げ、走者状況で増減し、投手打者は大きく上げる。
	var bunt_prob: float = 0.05 + bunt_z * 0.0125 - bat_impact * 0.008 - bat_barrel * 0.006 - float(outs) * 0.055
	if _has_runner(bases, 2):
		bunt_prob -= 0.07
	elif _has_runner(bases, 1) and not _has_runner(bases, 0):
		bunt_prob += 0.04
	if batter.is_pitcher():
		bunt_prob += 0.22
	return Rng.roll_float() < clamp(bunt_prob, 0.001, 1.0)


# z 近似 bunt skill: Spray(方向制御) と KAvoid(コンタクト) が +、Impact/Barrel が -。
static func _bunt_skill_z(batter: PSPlayerSeasonRecord) -> float:
	if batter == null:
		return 0.0
	return 0.5 * batter.z_ability("Bat_Spray", 0.0) \
		+ 0.3 * batter.z_ability("Bat_KAvoid", 0.0) \
		- 0.4 * batter.z_ability("Bat_Impact", 0.0) \
		- 0.2 * batter.z_ability("Bat_Barrel", 0.0)


# バント処理。
static func _resolve_bunt(batter: PSPlayerSeasonRecord, bases: Array) -> Dictionary:
	# 走者が速いほど成功率を上げる（最速走者の走力 z で加点）。
	var runner_plus: float = 0.0
	for index in range(3):
		if _has_runner(bases, index):
			runner_plus = max(runner_plus, 0.10 + _runner_speed(bases, index) * 0.025)
	# 成功確率(0..1)。バント技術 z が高いほど上げ、走者状況で増減。
	var bunt_z: float = _bunt_skill_z(batter)
	var success_prob: float = 0.50 + bunt_z * 0.125 + runner_plus
	if _has_runner(bases, 2):
		success_prob -= 0.30
	elif _has_runner(bases, 0) and _has_runner(bases, 1):
		success_prob -= 0.20
	elif _has_runner(bases, 1) and not _has_runner(bases, 0):
		success_prob += 0.10
	success_prob = max(0.05, success_prob)
	if Rng.roll_float() < success_prob:
		var position: int = _roll_bunt_position()
		var result_prefix: String = "squeeze_bunt" if _has_runner(bases, 2) else "sacrifice_bunt"
		return {
			"result": "%s_%s" % [result_prefix, PSPlayResolver.FIELD_NAMES.get(position, "unknown")],
			"category": CATEGORY_SACRIFICE,
			"bases": 0,
			"fielder_position": position,
			"runner_strategy": "squeeze" if _has_runner(bases, 2) else "sacrifice_bunt",
			"pitch_summary": _bunt_pitch_summary(true),
		}
	# バント失敗: ゴロアウトとして処理
	var fail_position: int = _roll_bunt_position()
	return {
		"result": "failed_bunt_groundout_%s" % PSPlayResolver.FIELD_NAMES.get(fail_position, "unknown"),
		"category": "out",
		"bases": 0,
		"fielder_position": fail_position,
		"pitch_summary": _bunt_pitch_summary(true),
	}


static func _roll_bunt_position() -> int:
	var roll: int = Rng.range_int(0, 99)
	if roll <= 40:
		return 1   # pitcher
	if roll <= 70:
		return 3   # first base
	return 5       # third base


static func _has_runner(bases: Array, base_index: int) -> bool:
	return base_index >= 0 and base_index < bases.size() and bases[base_index] != null


# 指定塁の走者の走力を z で返す（0.0 が全体平均）。
static func _runner_speed(bases: Array, base_index: int) -> float:
	if not _has_runner(bases, base_index):
		return 0.0
	var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
	return runner.z_ability("Run_Speed", 0.0)


# z_abilities ソースの precomp を構築する。
# ContactQualityModel へは z 値 (batter_contact_z/gap_z/hr_z/avoid_k_z, pitcher_stuff_z) を
# 直接渡し、curve はモデル内で ability_curve_z により算出する（display 往復は廃止）。
static func _build_precomp(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	pitching_context: Dictionary,
	is_reliever: bool
) -> Dictionary:
	# z 視点ビュー
	var batter_z: Dictionary = PSZAbilityAdapter.batter_view(batter)
	var pitcher_z_raw: Dictionary = PSZAbilityAdapter.pitcher_view(pitcher)
	var catcher_z: Dictionary = PSZAbilityAdapter.catcher_view(_catcher_record(defense))

	# pitching_context を z 空間へ翻訳
	var usage_penalty: int = int(pitching_context.get("pitcher_usage_penalty", 0))
	var tto_round: int = int(pitching_context.get("pitcher_tto_round", 0))
	var arsenal_bonus: int = int(pitching_context.get("pitcher_arsenal_bonus", 0))
	var command_leak: float = float(pitching_context.get("pitcher_command_leak", 0.0))
	var contact_damage: float = float(pitching_context.get("pitcher_contact_damage", 0.0))
	# 球種傾向(微差): K寄り/ゴロ寄り/被弾の集計スカラー。
	var arsenal_k_bias: float = float(pitching_context.get("pitcher_arsenal_k_bias", 0.0))
	var arsenal_gb_bias: float = float(pitching_context.get("pitcher_arsenal_gb_bias", 0.0))
	var arsenal_hr_bias: float = float(pitching_context.get("pitcher_arsenal_hr_bias", 0.0))
	var tto_array: Array = TTO_PENALTY_PER_ROUND
	var tto_round_weight: float = 0.0
	if tto_round >= 0 and tto_round < tto_array.size():
		tto_round_weight = float(tto_array[tto_round])
	# z 空間 delta (1 display point ≈ 0.08σ)
	var pitcher_z: Dictionary = pitcher_z_raw.duplicate(true)
	pitcher_z["Pit_KCreate"] = float(pitcher_z.get("Pit_KCreate", 0.0)) - float(usage_penalty) * 0.04
	pitcher_z["Pit_BBPrevent"] = float(pitcher_z.get("Pit_BBPrevent", 0.0)) - float(usage_penalty) * 0.04 - command_leak * 0.10
	pitcher_z["Pit_EdgeRate"] = float(pitcher_z.get("Pit_EdgeRate", 0.0)) + float(arsenal_bonus) * 0.08

	# 疲労 (球数ベース): 当試合の outing pitches を pitching_context から取り出す。
	var outing_pitches: int = int(pitching_context.get("pitcher_outing_pitches", 0))
	var fatigue_factor: float = PSFatigueCalculator.factor_for_pitcher(pitcher, is_reliever, outing_pitches)
	pitcher_z = PSFatigueCalculator.apply_drops(pitcher_z, fatigue_factor)

	# 利き腕プラトーン: 同利き腕なら -1（不利）、逆なら +1
	var platoon_sign: float = _platoon_sign(batter, pitcher)
	var framing_strikes: float = float(catcher_z.get("C_Framing", 0.0)) * FRAMING_SCALE
	var game_call_z: float = float(catcher_z.get("C_GameCall", 0.0))
	pitcher_z["Pit_ImpactLimit"] = float(pitcher_z.get("Pit_ImpactLimit", 0.0)) + game_call_z * GAMECALL_CONTACT_COEF
	pitcher_z["Pit_BarrelDeny"] = float(pitcher_z.get("Pit_BarrelDeny", 0.0)) + game_call_z * GAMECALL_CONTACT_COEF

	# ContactQualityModel 用の z 派生（Phase B: display への往復変換を廃止し z を直接渡す）。
	var batter_contact_z: float = float(batter_z.get("Bat_Barrel", 0.0))
	var batter_gap_z: float = float(batter_z.get("Bat_Impact", 0.0))
	var batter_hr_z: float = float(batter_z.get("Bat_Impact", 0.0)) + 0.5 * float(batter_z.get("Bat_Loft", 0.0))
	var batter_avoid_k_z: float = float(batter_z.get("Bat_KAvoid", 0.0))
	var pitcher_stuff_z: float = float(pitcher_z.get("Pit_BarrelDeny", 0.0)) + 0.5 * float(pitcher_z.get("Pit_ImpactLimit", 0.0))

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
	}


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
			return slot.get("record", null) as PSPlayerSeasonRecord
	return null
