extends RefCounted
class_name PSPlayResolver


# 物理的な打球情報を野球のプレー結果へ変換する。
# 入力には EV/LA/spray/distance/hang time/trajectory が事前計算済みで入っている前提。

const CATEGORY_HIT: String = "hit"
const CATEGORY_OUT: String = "out"
const CATEGORY_DOUBLE_PLAY: String = "double_play"
const CATEGORY_SACRIFICE_FLY: String = "sacrifice_fly"
const CATEGORY_FIELDERS_CHOICE: String = "fielders_choice"
const CATEGORY_ERROR: String = "error"

const RESULT_FOUL_BACK: String = "_foul_back_to_sequence"
const FIELDER_ABILITY_CACHE_KEY: String = "_pa_fielder_ability_cache"

# 球場サイズの mod 用乗算(park factor)。**バランス調整ノブではない** — HR量の較正は
# 物理層の飛距離(batted_ball_physics_resolver の air_factor)と、パワー→EV の経路
# (contact_quality の ev_home_run_power_weight / power_ideal_*)で行う。
const PARK_DISTANCE_SCALE: float = 1.0

const FIELD_NAMES: Dictionary = {
	1: "pitcher",
	2: "catcher",
	3: "first_base",
	4: "second_base",
	5: "third_base",
	6: "shortstop",
	7: "left_field",
	8: "center_field",
	9: "right_field",
}

const FAIR_HALF_ANGLE_DEG: float = 45.0
const INFIELD_DISTANCE_THRESHOLD: float = 38.0
const NEAR_HOME_DISTANCE_THRESHOLD: float = 12.0

# 本塁打フェンス距離(m)。実在 NPB 球場準拠で固定(中堅 122m / 両翼 100m、膝点から線形補間)。
# HR 判定は「物理飛距離 >= フェンス距離 + 壁越えマージン」のみで、打者ごとにフェンスを動かす補正や
# 惜しい打球の昇格抽選は行わない(パワー差は EV/理想角経由で自然に飛距離へ反映される)。
const HR_LINE_CENTER: float = 122.0
const HR_LINE_LINE: float = 100.0
const HR_LINE_KNEE_SPRAY: float = 20.0
# 壁越えマージン(m)。飛距離=無障害の着地点換算なので、フェンス高(NPB 2.5-4.4m)を越えて入るには
# 着地距離がフェンスより数m先である必要がある。ちょうどフェンス付近の打球は壁直撃(長打)になる。
const HR_WALL_CLEARANCE: float = 6.0

# --- ゾーン内（横方向）難度 ---
# 1球ごとの2D座標は持たず、spray を横軸として「担当野手の定位置からの横ズレ」で難度を表す。
# 定位置(正面)は捕球率が高く(凡打・低レバレッジ)、ゾーン端=穴/ギャップは捕球率が下がる(高レバレッジ＝守備範囲で差が出る)。
# これで内野 OAA の幅が広がり(穴の高難度プレー)、外野ライナーが一律0.48でなく二極化してコインフリップが減る。
const FIELDER_SPRAY_NOMINAL: Dictionary = {
	3: 27.0,   # 1B
	4: 12.0,   # 2B
	5: -27.0,  # 3B
	6: -12.0,  # SS
	7: -28.0,  # LF
	8: 0.0,    # CF
	9: 28.0,   # RF
}
const LATERAL_RANGE_DEG: float = 20.0     # この横ズレ(度)で難度が最大になる。
const LATERAL_EASY_FRACTION: float = 0.40 # 横ズレがこの割合までは正面圏(難度0)。大半の打球は凡打のまま。

# 捕球確率の連続難度モデル。
# 2D 座標は持たず、spray=横ズレ、distance=深さ、EV=打球の強さ、hang_time=追いつく猶予として扱う。
# catch_prob_neutral は out/hit 判定、OAA 基準、失策 makeable の土台なので、守備者能力はここでは混ぜない。
const CATCH_PROB_MIN: float = 0.04
const CATCH_PROB_MAX: float = 0.985
const CATCH_PROB_CALIBRATION_BIAS: float = 0.035
const CATCH_EV_SOFT: float = 78.0
const CATCH_EV_HARD: float = 106.0
const INFIELD_GROUNDER_DEPTH_EASY: float = 18.0
const OUTFIELD_LINER_DISTANCE_DEEP: float = 58.0
const OUTFIELD_FLY_DISTANCE_EASY: float = 62.0
const OUTFIELD_FLY_DISTANCE_DEEP: float = 108.0

# 守備位置難易度 (= ポジション平均守備力 reference)。順位は SS>CF>2B>3B>RF>LF>1B
# (捕手は順位対象外)。野手7ポジ合計は再分配前と同じ 453.5 に保ち、リーグ全体の
# 被アウト率を不変に保ちつつポジ間難易度のみ現実準拠に並べ替えている。
# fielding_model.gd POSITION_AVG_ABILITY_SCORE と同値で同期させること。
const POSITION_AVG_DEFENSE_SCORE_Z: Dictionary = {
	1: 0.80,
	2: 1.44,
	3: 0.20,
	4: 1.60,
	5: 1.12,
	6: 2.16,
	7: 0.48,
	8: 1.92,
	9: 0.80,
}

# One z point above position average is worth this much catch probability.
# These are PA-level value levers, not lineup-selection ratios.
const POSITION_CATCH_CONVERSION_WEIGHT_Z: Dictionary = {
	1: 0.0175,
	2: 0.0275,
	3: 0.0670,
	4: 0.0980,
	5: 0.0980,
	6: 0.1260,
	7: 0.0200,
	8: 0.0380,
	9: 0.0250,
}

const TRAJECTORY_CATCH_CONVERSION_MULTIPLIER: Dictionary = {
	"grounder": {
		1: 0.95,
		2: 0.85,
		3: 0.90,
		4: 1.14,
		5: 1.05,
		6: 1.18,
		7: 0.35,
		8: 0.35,
		9: 0.35,
	},
	"liner": {
		1: 1.00,
		2: 0.85,
		3: 0.95,
		4: 1.08,
		5: 1.18,
		6: 1.12,
		7: 0.95,
		8: 1.08,
		9: 0.98,
	},
	"fly": {
		1: 0.55,
		2: 0.75,
		3: 0.75,
		4: 0.82,
		5: 0.82,
		6: 0.86,
		7: 0.96,
		8: 1.18,
		9: 1.02,
	},
	"popup": {
		1: 0.75,
		2: 1.08,
		3: 1.06,
		4: 1.02,
		5: 1.02,
		6: 1.00,
		7: 0.72,
		8: 0.76,
		9: 0.72,
	},
}

# 捕球そのものに効く能力軸。position assignment の総合 blend ではなく、プレー種類ごとに
# range/reaction/secure を使い分ける。送球と併殺は別ロジックで扱う。
const TRAJECTORY_CATCH_AXIS_WEIGHTS: Dictionary = {
	"grounder": {"range": 0.48, "reaction": 0.30, "secure": 0.22},
	"liner": {"reaction": 0.50, "range": 0.30, "secure": 0.20},
	"fly": {"range": 0.54, "reaction": 0.31, "secure": 0.15},
	"popup": {"secure": 0.45, "reaction": 0.35, "range": 0.20},
}

# ポジション別の必要守備能力ブレンド。reach=守備範囲, throw=肩, teamwork=併殺完成(IF_Exchange),
# secure=捕球, reaction=範囲+positioning。現実準拠: 2B=併殺(teamwork)重視・肩(throw)は低めだが残す,
# 3B=肩(throw)突出, SS=全 axis 高水準(all-around), CF=守備範囲(reach)突出。守備範囲は全ポジで重み有り。
const POSITION_AXIS_WEIGHTS: Dictionary = {
	1: {"reach": 0.35, "reaction": 0.30, "secure": 0.25, "throw": 0.10},
	2: {"secure": 0.34, "blocking": 0.22, "throw": 0.22, "framing": 0.10, "game_call": 0.12},
	3: {"secure": 0.42, "reach": 0.20, "reaction": 0.18, "throw": 0.08, "teamwork": 0.12},
	4: {"reach": 0.28, "reaction": 0.18, "secure": 0.16, "throw": 0.08, "teamwork": 0.30},
	5: {"throw": 0.38, "secure": 0.22, "reaction": 0.18, "reach": 0.16, "teamwork": 0.06},
	6: {"reach": 0.22, "reaction": 0.20, "secure": 0.20, "throw": 0.20, "teamwork": 0.18},
	7: {"reach": 0.32, "reaction": 0.22, "secure": 0.22, "throw": 0.14, "teamwork": 0.10},
	8: {"reach": 0.46, "reaction": 0.26, "secure": 0.14, "throw": 0.08, "teamwork": 0.06},
	9: {"throw": 0.34, "reach": 0.24, "reaction": 0.16, "secure": 0.16, "teamwork": 0.10},
}

const INFIELD_THROW_BEAT_BASE: float = 0.010
const INFIELD_THROW_BEAT_SPEED_WEIGHT_Z: float = 0.050
const INFIELD_THROW_BEAT_ARM_WEIGHT_Z: float = 0.052
const INFIELD_THROW_BEAT_TEAMWORK_WEIGHT_Z: float = 0.020
const INFIELD_THROW_BEAT_SOFT_CONTACT_WEIGHT: float = 0.070
const INFIELD_THROW_BEAT_DEPTH_WEIGHT: float = 0.050
const INFIELD_THROW_BEAT_LATERAL_WEIGHT: float = 0.060
const INFIELD_THROW_BEAT_HARD_CONTACT_PENALTY: float = 0.015
const INFIELD_THROW_BEAT_MAX: float = 0.34
const GROUNDOUT_THIRD_SCORE_BASE: float = 0.46
const GROUNDOUT_THIRD_SCORE_SPEED_WEIGHT_Z: float = 0.045
const GROUNDOUT_THIRD_SCORE_JUDGMENT_WEIGHT_Z: float = 0.045
const GROUNDOUT_THIRD_SCORE_SOFT_WEIGHT: float = 0.085
const GROUNDOUT_THIRD_SCORE_DEPTH_WEIGHT: float = 0.040
const GROUNDOUT_THIRD_SCORE_ARM_WEIGHT_Z: float = 0.045
const GROUNDOUT_SECOND_ADVANCE_BASE: float = 0.26
const GROUNDOUT_SECOND_ADVANCE_SPEED_WEIGHT_Z: float = 0.040
const GROUNDOUT_SECOND_ADVANCE_JUDGMENT_WEIGHT_Z: float = 0.045
const GROUNDOUT_SECOND_ADVANCE_SOFT_WEIGHT: float = 0.060
const GROUNDOUT_FIRST_ADVANCE_BASE: float = 0.66
const GROUNDOUT_FIRST_ADVANCE_SPEED_WEIGHT_Z: float = 0.035
const GROUNDOUT_FIRST_ADVANCE_JUDGMENT_WEIGHT_Z: float = 0.025

# --- 失策モデル（難易度ベース）---
# 失策 = 「本来アウトにできた打球(makeable = catch_prob_neutral)を捌き損ねる」事象。
# makeable を掛けることでヒット性の打球(catch_prob 小)にはほぼ課されない。
# 捕球(bobble)失策の弾道別 base は「打球の捌きにくさ」（ゴロ=悪バウンド多 > ライナー > フライ）であり
# 守備位置の固定倍率ではない。内野偏重は「ゴロの makeable が高い」ことから自然に出る。
# makeable は線形(一乗)で掛ける。二乗にすると隅(三塁/遊撃)への強襲ゴロ等「本来アウトにできる難しめの打球」の
# 失策まで過小評価されるため。ヒット性打球(makeable小)の偽失策は、外野ゴロを失策機会から外すこと＋makeable で抑える。
const FIELD_ERROR_BASE_GROUNDER: float = 0.017
const FIELD_ERROR_BASE_LINER: float = 0.0022
const FIELD_ERROR_BASE_FLY: float = 0.0013   # 内野フライ/ポップ共通
const FIELD_ERROR_HARDNESS_WEIGHT: float = 0.9   # 強い打球(EV)ほど捕球失策増
const FIELD_ERROR_SECURE_WEIGHT: float = 0.011   # 捕球(secure) z 欠損あたりの増分（守備力差＝チーム間ばらつき）
# 内野/投手/捕手の「ゴロ捕球の難しさ」係数。一塁の正面ゴロは易しく、遊撃・三塁の範囲/強襲打球は難しい、という
# ボールハンドリング難度を表す（捕球確率=安打率には掛けず、失策確率にのみ作用させる）。捕球失策の偏りはここで決まる。
const FIELD_ERROR_POSITION_DIFFICULTY: Dictionary = {
	1: 0.60,
	2: 0.60,
	3: 0.26,
	4: 0.80,
	5: 1.15,
	6: 1.10,
}
# 外野(7-9): 捕れる打球(makeable>=閾値)に限り低率で失策。守備能力には依存させず、
# spray 分布と担当機会の偏りだけを倍率でならし、3 ポジションの記録上の偏りを抑える。
const OF_CATCHABLE_THRESHOLD: float = 0.42
const OF_FIELD_ERROR_RATE: float = 0.0105
const OF_GROUNDER_MISPLAY_RATE: float = 0.0035  # 外野へ抜けたゴロの後逸率（単打→二塁打相当の外野失策）。
const OF_ERROR_OPPORTUNITY_MULTIPLIER: Dictionary = {
	7: 0.78,
	8: 1.65,
	9: 0.90,
}
const FIELD_ERROR_HARDNESS_EV_FLOOR: float = 88.0
const FIELD_ERROR_HARDNESS_EV_RANGE: float = 30.0
# 失策後の余分進塁・一塁手スクープ救済。
const THROW_ERROR_EXTRA_BASE_CHANCE: float = 0.35   # 送球失策で打者が二塁まで進む確率。
const FIRST_BASE_SCOOP_BASE: float = 0.25           # 平均的一塁手が悪送球を捕球(スクープ)してアウトにする確率。
const FIRST_BASE_SCOOP_REFERENCE_Z: float = 1.6     # 一塁手 IF_Secure z の基準。
const FIRST_BASE_SCOOP_WEIGHT: float = 0.14         # IF_Secure z が基準を超える分の救済率増分。
const FIRST_BASE_SCOOP_MIN: float = 0.05
const FIRST_BASE_SCOOP_MAX: float = 0.55
# 送球失策（ゴロを捌いた後の一塁送球）。対象は投手(1)・捕手(2)・内野(3-6)。外野は通常プレーで送球失策ほぼ無し。
# base は送球難易度（物理）: 三塁=強い送球・遊撃=長い/逆シングル送球が最多で高、二塁=中、一塁≈小、投手/捕手=本塁付近の慌てた送球で小。
# 内野の失策順序(遊撃≳三塁>二塁>一塁)は、位置別の固定倍率ではなくこの送球難易度差から生まれる。
const THROW_ERROR_BASE_BY_POSITION: Dictionary = {
	1: 0.013,
	2: 0.013,
	3: 0.0055,
	4: 0.022,
	5: 0.070,
	6: 0.024,
}
const THROW_ERROR_REFERENCE_Z: float = 1.4   # 送球(throw) z の基準。これ未満で送球失策増。
const THROW_ERROR_WEIGHT: float = 0.039      # 送球 z 欠損あたりの増分（大きいほどチーム間ばらつき拡大）
const ERROR_CHANCE_CAP: float = 0.20

const DOUBLE_PLAY_BASE: float = 0.36              # 併殺機会での併殺成立の基準確率。
const DOUBLE_PLAY_COMPLETION_WEIGHT_Z: float = 0.04375 # 守備側の併殺完成力(z 1.0)あたり併殺確率の増分。
const DOUBLE_PLAY_SPEED_WEIGHT: float = 0.03125   # 打者走力 z 1.0 あたり併殺確率を下げる量（速いほど併殺回避）。
const FIELDERS_CHOICE_SECOND_BASE: float = 0.34
const FIELDERS_CHOICE_THIRD_BASE: float = 0.16
const FIELDERS_CHOICE_HOME_BASE: float = 0.14
const FIELDERS_CHOICE_ARM_WEIGHT_Z: float = 0.035
const FIELDERS_CHOICE_TEAMWORK_WEIGHT_Z: float = 0.030
const FIELDERS_CHOICE_BATTER_SPEED_WEIGHT_Z: float = 0.035
const FIELDERS_CHOICE_HARD_CONTACT_WEIGHT: float = 0.055
const FIELDERS_CHOICE_MAX: float = 0.72
const HOME_THROW_ATTEMPT_BASE: float = 0.18
const HOME_THROW_ATTEMPT_CLOSE_PLAY_WEIGHT: float = 0.30
const HOME_THROW_ATTEMPT_CONTACT_WEIGHT: float = 0.08
const HOME_THROW_ATTEMPT_ARM_WEIGHT_Z: float = 0.045
const HOME_THROW_OUT_BASE: float = 0.44
const HOME_THROW_OUT_RUNNER_SPEED_WEIGHT_Z: float = 0.090
const HOME_THROW_OUT_RUNNER_JUDGMENT_WEIGHT_Z: float = 0.045
const HOME_THROW_OUT_FIELDER_ARM_WEIGHT_Z: float = 0.075
const HOME_THROW_TRAIL_ADVANCE_BASE: float = 0.28
const SACRIFICE_FLY_DISTANCE_MIN: float = 54.0    # これ未満の浅い飛球はタグアップ生還がほぼ発生しない。
const SACRIFICE_FLY_DISTANCE_FULL: float = 96.0   # この深さ付近で距離要因が最大化する。
const SACRIFICE_FLY_HANG_MIN: float = 2.0         # 最低限の滞空時間。短すぎる飛球では帰塁・スタートが間に合わない。
const SACRIFICE_FLY_HANG_FULL: float = 4.4        # 十分な滞空時間。深いフライでタッチアップ準備が整う。
const SACRIFICE_FLY_BASE: float = 0.30
const SACRIFICE_FLY_DEPTH_WEIGHT: float = 0.60
const SACRIFICE_FLY_HANG_WEIGHT: float = 0.13
const SACRIFICE_FLY_SPEED_WEIGHT_Z: float = 0.055
const SACRIFICE_FLY_JUDGMENT_WEIGHT_Z: float = 0.040
const SACRIFICE_FLY_ARM_REFERENCE_Z: float = 0.8
const SACRIFICE_FLY_ARM_WEIGHT_Z: float = 0.065
const SACRIFICE_FLY_INFIELD_MAX: float = 0.05
const SACRIFICE_FLY_MAX: float = 0.96
const SACRIFICE_FLY_SECOND_BASE_BASE: float = 0.07
const SACRIFICE_FLY_SECOND_BASE_DEPTH_WEIGHT: float = 0.24
const SACRIFICE_FLY_SECOND_BASE_HANG_WEIGHT: float = 0.08
const SACRIFICE_FLY_SECOND_BASE_SPEED_WEIGHT_Z: float = 0.040
const SACRIFICE_FLY_SECOND_BASE_JUDGMENT_WEIGHT_Z: float = 0.035
const SACRIFICE_FLY_SECOND_BASE_ARM_WEIGHT_Z: float = 0.050
const SACRIFICE_FLY_SECOND_BASE_MAX: float = 0.58
const DEFAULT_FIELDING_AXIS_Z: float = 0.8
const ERROR_SECURE_REFERENCE_Z: float = 1.6   # 捕球(secure) z の基準。これ未満で捕球失策増。
const DOUBLE_PLAY_TEAMWORK_REFERENCE_Z: float = 0.8


static func resolve(
	batter: PSPlayerSeasonRecord,
	_pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	physics: Dictionary,
	contact_quality: Dictionary
) -> Dictionary:
	var spray: float = float(physics.get("spray_angle", 0.0))
	var distance: float = float(physics.get("distance", 0.0))
	var hang_time: float = float(physics.get("hang_time", 0.0))
	var trajectory: String = str(physics.get("trajectory_bucket", "liner"))
	var ev: float = float(physics.get("exit_velocity", 80.0))

	if absf(spray) > FAIR_HALF_ANGLE_DEG:
		return {"result": RESULT_FOUL_BACK, "category": RESULT_FOUL_BACK, "bases": 0}

	var hr_line: float = _hr_line(spray) * _rule_float("park_distance_scale", PARK_DISTANCE_SCALE)
	hr_line += _rule_float("hr_wall_clearance", HR_WALL_CLEARANCE)
	if distance >= hr_line and trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
		var hr_field: int = _outfield_position_for_spray(spray, distance, trajectory)
		var hr_field_name: String = "left" if hr_field == 7 else ("right" if hr_field == 9 else "center")
		return {
			"result": "home_run_%s" % hr_field_name,
			"category": CATEGORY_HIT,
			"bases": 4,
			"fielder_position": hr_field,
		}

	var position: int = _assign_fielder(spray, distance, trajectory)
	var fielder: PSPlayerSeasonRecord = _fielder_record(defense, position)
	var ability_profile: Dictionary = _fielder_ability_profile(defense, fielder, position)
	var ability_range: float = float(ability_profile.get("range", DEFAULT_FIELDING_AXIS_Z))
	var ability_accuracy: float = float(ability_profile.get("secure", DEFAULT_FIELDING_AXIS_Z))
	var ability_arm: float = float(ability_profile.get("arm", DEFAULT_FIELDING_AXIS_Z))
	var ability_teamwork: float = float(ability_profile.get("teamwork", DEFAULT_FIELDING_AXIS_Z))
	var batter_contact: float = _batter_contact(batter)

	var catch_prob_neutral: float = _catch_probability_neutral(trajectory, position, distance, hang_time, ev, batter_contact, spray)
	var catch_prob_used: float = _catch_probability_used(catch_prob_neutral, ability_profile, position, trajectory)

	if bool(contact_quality.get("protective_out", false)):
		return _enrich(_out_outcome(trajectory, position), catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)

	var first_baseman: PSPlayerSeasonRecord = _fielder_record(defense, 3)
	var error_type: String = _roll_error_type(trajectory, position, catch_prob_neutral, ev, ability_accuracy, ability_arm, first_baseman)
	if error_type != "":
		var error_bases: int = _error_advance_bases(error_type)
		return _enrich(_error_outcome(position, error_type, error_bases), catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)

	# 併殺機会フラグ（内野ゴロ・一塁走者・2アウト未満）。DPR 評価用に立て、判定は捕球成功後に行う。
	# これにより「外野へ抜けるゴロでの併殺」「捕れなかった打球での併殺」を排除する。
	var double_play_opportunity: bool = (
		trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER
		and position >= 3 and position <= 6
		and _has_runner(bases, 0) and outs < 2
	)
	var double_play_probability: float = _double_play_probability(batter, ability_teamwork, position, ev) if double_play_opportunity else 0.0

	if Rng.roll_float() < catch_prob_used:
		# 捕球成功。併殺機会なら併殺を試みる（捕球できた後に二つ目のアウトを狙う）。
		if double_play_opportunity and Rng.roll_float() < double_play_probability:
			var double_play_outcome: Dictionary = _double_play_outcome(position)
			_apply_double_play_context(double_play_outcome, double_play_opportunity, double_play_probability)
			return _enrich(double_play_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var fielders_choice_outcome: Dictionary = _maybe_fielders_choice_outcome(
			batter,
			bases,
			outs,
			trajectory,
			position,
			ev,
			ability_arm,
			ability_teamwork
		)
		if not fielders_choice_outcome.is_empty():
			_apply_double_play_context(fielders_choice_outcome, double_play_opportunity, double_play_probability)
			return _enrich(fielders_choice_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var home_throw_outcome: Dictionary = _maybe_nonforce_home_throw_outcome(
			batter,
			bases,
			outs,
			trajectory,
			position,
			ev,
			ability_arm,
			ability_teamwork
		)
		if not home_throw_outcome.is_empty():
			_apply_double_play_context(home_throw_outcome, double_play_opportunity, double_play_probability)
			return _enrich(home_throw_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var infield_hit_outcome: Dictionary = _maybe_batter_beats_grounder_throw(
			batter,
			bases,
			outs,
			physics,
			trajectory,
			position,
			ev,
			spray,
			distance,
			ability_arm,
			ability_teamwork
		)
		if not infield_hit_outcome.is_empty():
			_apply_double_play_context(infield_hit_outcome, double_play_opportunity, double_play_probability)
			return _enrich(infield_hit_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var groundout_advance_outcome: Dictionary = _groundout_runner_advancement_outcome(
			bases,
			outs,
			trajectory,
			position,
			ev,
			spray,
			distance,
			ability_arm
		)
		if not groundout_advance_outcome.is_empty():
			_apply_double_play_context(groundout_advance_outcome, double_play_opportunity, double_play_probability)
			return _enrich(groundout_advance_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var sacrifice_fly_probability: float = _sacrifice_fly_probability(
			bases,
			outs,
			trajectory,
			distance,
			hang_time,
			position,
			ability_arm
		)
		if sacrifice_fly_probability > 0.0 and Rng.roll_float() < sacrifice_fly_probability:
			var sacrifice_fly_outcome: Dictionary = _sacrifice_fly_outcome(position)
			_apply_sacrifice_fly_context(sacrifice_fly_outcome, sacrifice_fly_probability, distance, hang_time, ability_arm)
			_apply_sacrifice_fly_advancements(sacrifice_fly_outcome, bases, distance, hang_time, position, ability_arm)
			return _enrich(sacrifice_fly_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
		var fielded_outcome: Dictionary = _out_outcome(trajectory, position)
		_apply_double_play_context(fielded_outcome, double_play_opportunity, double_play_probability)
		return _enrich(fielded_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)

	if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
		var grounder_hit: Dictionary = _grounder_hit_outcome(batter, bases, outs, physics, position, ability_arm)
		_apply_double_play_context(grounder_hit, double_play_opportunity, double_play_probability)
		return _enrich(grounder_hit, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)
	var hit_outcome: Dictionary = _airball_hit_outcome(batter, bases, outs, physics, ability_arm, position)
	return _enrich(hit_outcome, catch_prob_used, catch_prob_neutral, ability_range, ability_accuracy, position)


static func _enrich(
	outcome: Dictionary,
	catch_prob_used: float,
	catch_prob_neutral: float,
	ability_range: float,
	ability_accuracy: float,
	catch_attempt_position: int
) -> Dictionary:
	outcome["catch_probability_used"] = catch_prob_used
	outcome["catch_probability_neutral"] = catch_prob_neutral
	outcome["fielder_range_z_used"] = ability_range
	outcome["fielder_accuracy_z_used"] = ability_accuracy
	outcome["catch_attempt_position"] = catch_attempt_position
	return outcome


# 打者の芯で捉える力(Bat_Barrel)を z で返す。0.0 が平均、正で巧打。
static func _batter_contact(batter: PSPlayerSeasonRecord) -> float:
	if batter == null:
		return 0.0
	return batter.z_ability("Bat_Barrel", 0.0)


static func _hr_line(spray: float) -> float:
	var abs_spray: float = absf(spray)
	if abs_spray <= HR_LINE_KNEE_SPRAY:
		return HR_LINE_CENTER
	var t: float = clamp((abs_spray - HR_LINE_KNEE_SPRAY) / (FAIR_HALF_ANGLE_DEG - HR_LINE_KNEE_SPRAY), 0.0, 1.0)
	return lerp(HR_LINE_CENTER, HR_LINE_LINE, t)


static func _assign_fielder(spray: float, distance: float, trajectory: String) -> int:
	if distance < NEAR_HOME_DISTANCE_THRESHOLD:
		if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
			return 1 if absf(spray) < 8.0 else 2
		return 2
	if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_POPUP:
		if distance < 45.0:
			return _infield_position_for_spray(spray)
		return _outfield_position_for_spray(spray, distance, trajectory)
	if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
		if distance < INFIELD_DISTANCE_THRESHOLD:
			return _infield_position_for_spray(spray)
		return _outfield_position_for_spray(spray, distance, trajectory)
	if distance < INFIELD_DISTANCE_THRESHOLD and trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_LINER:
		return _infield_position_for_spray(spray)
	return _outfield_position_for_spray(spray, distance, trajectory)


static func _infield_position_for_spray(spray: float) -> int:
	# ゴロの担当内野手。境界は守備範囲の現実的な分担に合わせる（三塁線〜遊撃〜二塁〜一塁）。
	# 捕球確率は担当野手の定位置からの横ズレで変わるため、境界は安打率・OAA・併殺帰属に影響する。
	# 3B(<-22)と1B(>=18)の境界は併殺多発の二遊間(1.25倍)と分けるため従来値を維持し、
	# 失策分布のための再配分は SS/2B 間（どちらも DP 1.25倍）でのみ行う＝得点環境(併殺率)に影響しない。
	if spray < -22.0:
		return 5
	if spray < 10.0:
		return 6
	if spray < 18.0:
		return 4
	return 3


static func _outfield_position_for_spray(spray: float, distance: float = 0.0, trajectory: String = "") -> int:
	var center_left: float = -15.0
	var center_right: float = 15.0
	match trajectory:
		PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
			center_left = -12.0
			center_right = 12.0
		PSBattedBallPhysicsResolver.TRAJECTORY_LINER:
			center_left = -14.0
			center_right = 14.0
			if distance >= 70.0:
				center_left = -18.0
				center_right = 18.0
		PSBattedBallPhysicsResolver.TRAJECTORY_FLY:
			center_left = -18.0
			center_right = 18.0
			if distance >= OUTFIELD_FLY_DISTANCE_EASY:
				center_left = -22.0
				center_right = 22.0
			if distance >= OUTFIELD_FLY_DISTANCE_DEEP:
				center_left = -24.0
				center_right = 24.0
		PSBattedBallPhysicsResolver.TRAJECTORY_POPUP:
			center_left = -16.0
			center_right = 16.0

	if spray < center_left:
		return 7
	if spray < center_right:
		return 8
	return 9


static func _catch_probability_neutral(
	trajectory: String,
	position: int,
	distance: float,
	hang_time: float,
	ev: float,
	batter_contact: float,
	spray: float = 0.0
) -> float:
	var _unused_contact: float = batter_contact
	var lateral: float = _lateral_difficulty(position, spray)
	var hard: float = _hard_contact_factor(ev)
	var soft: float = _soft_contact_factor(ev)
	var base: float = 0.50
	match trajectory:
		PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
			base = _grounder_catch_probability(position, distance, spray, hard, soft)
		PSBattedBallPhysicsResolver.TRAJECTORY_LINER:
			base = _liner_catch_probability(position, distance, hang_time, lateral, hard)
		PSBattedBallPhysicsResolver.TRAJECTORY_FLY:
			base = _fly_catch_probability(position, distance, hang_time, lateral, hard)
		PSBattedBallPhysicsResolver.TRAJECTORY_POPUP:
			base = _popup_catch_probability(position, hang_time, lateral, hard)

	return clamp(base + CATCH_PROB_CALIBRATION_BIAS, CATCH_PROB_MIN, CATCH_PROB_MAX)


static func _grounder_catch_probability(
	position: int,
	distance: float,
	spray: float,
	hard: float,
	soft: float
) -> float:
	if position >= 7:
		# 外野まで抜けたゴロは基本的にヒット。弱い打球だけわずかに処理アウトを残す。
		return clamp(0.12 + soft * 0.04 - hard * 0.03, CATCH_PROB_MIN, 0.22)

	if position == 1 or position == 2:
		var near_home_depth: float = clamp((distance - 6.0) / 18.0, 0.0, 1.0)
		return 0.980 - hard * 0.075 - near_home_depth * 0.035

	var depth: float = clamp(
		(distance - INFIELD_GROUNDER_DEPTH_EASY)
		/ max(1.0, INFIELD_DISTANCE_THRESHOLD - INFIELD_GROUNDER_DEPTH_EASY),
		0.0,
		1.0
	)
	# ゴロの「穴」は共通 _lateral_difficulty(40%緩衝)を使わず生の横ズレから計算する。
	# 担当割付の都合で横ズレが最大でも半区画(≈0.5)しか出ず、緩衝40%だとほぼ常に0になり
	# 三遊間・一二塁間を抜ける安打が構造的に消えるため。実測ゴロ BABIP ≈ .236 の再現ノブ。
	var raw_offset: float = clamp(
		absf(spray - float(FIELDER_SPRAY_NOMINAL.get(position, 0.0))) / LATERAL_RANGE_DEG,
		0.0,
		1.0
	)
	var hole_factor: float = clamp((raw_offset - 0.12) / 0.60, 0.0, 1.0)
	var hole_penalty: float = hole_factor * (0.55 + hard * 0.10 + depth * 0.05)
	return 0.955 + soft * 0.020 - hard * 0.125 - depth * 0.050 - hole_penalty


static func _liner_catch_probability(
	position: int,
	distance: float,
	hang_time: float,
	lateral: float,
	hard: float
) -> float:
	var hang_ease: float = clamp((hang_time - 0.85) / 1.65, 0.0, 1.0)
	var sinker: float = clamp((1.10 - hang_time) / 0.45, 0.0, 1.0)
	if position >= 7:
		var deep: float = clamp((distance - OUTFIELD_LINER_DISTANCE_DEEP) / 44.0, 0.0, 1.0)
		return (
			0.26
			+ hang_ease * 0.28
			- sinker * 0.10
			- hard * 0.075
			- deep * 0.080
			- lateral * (0.30 + hard * 0.06)
		)

	var infield_depth: float = clamp(distance / INFIELD_DISTANCE_THRESHOLD, 0.0, 1.0)
	return 0.22 + hang_ease * 0.13 - hard * 0.080 - infield_depth * 0.045 - lateral * 0.18


static func _fly_catch_probability(
	position: int,
	distance: float,
	hang_time: float,
	lateral: float,
	hard: float
) -> float:
	var hang_ease: float = clamp((hang_time - 2.10) / 2.40, 0.0, 1.0)
	var low_hang: float = clamp((2.15 - hang_time) / 0.95, 0.0, 1.0)
	if position >= 7:
		var range_depth: float = clamp(
			(distance - OUTFIELD_FLY_DISTANCE_EASY)
			/ max(1.0, OUTFIELD_FLY_DISTANCE_DEEP - OUTFIELD_FLY_DISTANCE_EASY),
			0.0,
			1.0
		)
		var wall_depth: float = clamp((distance - OUTFIELD_FLY_DISTANCE_DEEP) / 28.0, 0.0, 1.0)
		return (
			0.850
			+ hang_ease * 0.205
			- low_hang * 0.120
			- range_depth * 0.060
			- wall_depth * 0.030
			- hard * 0.030
			- lateral * (0.200 + low_hang * 0.120)
		)

	return 0.780 + hang_ease * 0.120 - low_hang * 0.080 - hard * 0.040 - lateral * 0.120


static func _popup_catch_probability(position: int, hang_time: float, lateral: float, hard: float) -> float:
	var hang_ease: float = clamp((hang_time - 1.20) / 2.20, 0.0, 1.0)
	if position <= 6:
		return 0.955 + hang_ease * 0.045 - hard * 0.020 - lateral * 0.090
	return 0.895 + hang_ease * 0.060 - hard * 0.020 - lateral * 0.120


static func _lateral_difficulty(position: int, spray: float) -> float:
	if not FIELDER_SPRAY_NOMINAL.has(position):
		return 0.0
	var lateral_offset: float = clamp(
		absf(spray - float(FIELDER_SPRAY_NOMINAL[position])) / LATERAL_RANGE_DEG,
		0.0,
		1.0
	)
	return clamp((lateral_offset - LATERAL_EASY_FRACTION) / (1.0 - LATERAL_EASY_FRACTION), 0.0, 1.0)


static func _hard_contact_factor(ev: float) -> float:
	return clamp((ev - CATCH_EV_SOFT) / max(1.0, CATCH_EV_HARD - CATCH_EV_SOFT), 0.0, 1.0)


static func _soft_contact_factor(ev: float) -> float:
	return clamp((CATCH_EV_SOFT - ev) / 18.0, 0.0, 1.0)


static func _catch_probability_used(
	neutral: float,
	ability_profile: Dictionary,
	position: int,
	trajectory: String
) -> float:
	var baseline: float = float(POSITION_AVG_DEFENSE_SCORE_Z.get(position, DEFAULT_FIELDING_AXIS_Z))
	var weight: float = float(POSITION_CATCH_CONVERSION_WEIGHT_Z.get(position, 0.035))
	var trajectory_multiplier: float = _trajectory_position_multiplier(trajectory, position)
	var catch_score: float = _catch_axis_score(ability_profile, trajectory)
	var adjustment: float = (catch_score - baseline) * weight * trajectory_multiplier
	return clamp(neutral + adjustment, 0.04, 0.985)


static func _catch_axis_score(ability_profile: Dictionary, trajectory: String) -> float:
	var weights: Dictionary = TRAJECTORY_CATCH_AXIS_WEIGHTS.get(trajectory, {}) as Dictionary
	if weights.is_empty():
		return float(ability_profile.get("blend", DEFAULT_FIELDING_AXIS_Z))

	var total: float = 0.0
	var weight_total: float = 0.0
	for axis_value in weights.keys():
		var axis: String = str(axis_value)
		var weight: float = float(weights[axis_value])
		total += float(ability_profile.get(axis, DEFAULT_FIELDING_AXIS_Z)) * weight
		weight_total += weight
	if weight_total <= 0.0:
		return float(ability_profile.get("blend", DEFAULT_FIELDING_AXIS_Z))
	return total / weight_total


# 失策の種別を返す（"" = 失策なし）。捕球(fielding)/送球(throwing)/外野後逸(outfield_misplay) を
# 内部的に区別し、進塁(_error_advance_bases)を変える。失策の計上数は種別に依存しない。
# いずれも makeable(本来アウトにできる確率)に比例させ、ヒット性の打球には課さない。
static func _roll_error_type(
	trajectory: String,
	position: int,
	catch_prob_neutral: float,
	ev: float,
	ability_secure: float,
	ability_throw: float,
	first_baseman: PSPlayerSeasonRecord
) -> String:
	var makeable: float = clamp(catch_prob_neutral, 0.0, 1.0)
	var hardness: float = clamp((ev - FIELD_ERROR_HARDNESS_EV_FLOOR) / FIELD_ERROR_HARDNESS_EV_RANGE, 0.0, 1.0)

	# 外野(7-9)
	if position >= 7:
		var of_error_multiplier: float = float(OF_ERROR_OPPORTUNITY_MULTIPLIER.get(position, 1.0))
		# 外野へ抜けたゴロの後逸（単打を二塁打相当にする外野失策）。
		if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
			return "outfield_misplay" if Rng.roll_float() < OF_GROUNDER_MISPLAY_RATE * of_error_multiplier else ""
		# フライ/ライナーの落球。捕れる打球(makeable>=閾値)のみ対象で、能力差は入れない。
		if makeable < OF_CATCHABLE_THRESHOLD:
			return ""
		return "fielding" if Rng.roll_float() < OF_FIELD_ERROR_RATE * of_error_multiplier else ""

	# 内野・投手・捕手の捕球失策。弾道の捌きにくさ + 打球の強さ + 守備(secure)能力 + 位置別捕球難度。
	var field_base: float = _rule_float("field_error_base_liner", FIELD_ERROR_BASE_LINER)
	match trajectory:
		PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
			field_base = _rule_float("field_error_base_grounder", FIELD_ERROR_BASE_GROUNDER)
		PSBattedBallPhysicsResolver.TRAJECTORY_FLY, PSBattedBallPhysicsResolver.TRAJECTORY_POPUP:
			field_base = _rule_float("field_error_base_fly", FIELD_ERROR_BASE_FLY)
	var secure_deficiency: float = max(0.0, ERROR_SECURE_REFERENCE_Z - ability_secure)
	var position_difficulty: float = float(FIELD_ERROR_POSITION_DIFFICULTY.get(position, 1.0))
	var field_chance: float = makeable * position_difficulty * (
		field_base * (1.0 + hardness * FIELD_ERROR_HARDNESS_WEIGHT)
		+ secure_deficiency * FIELD_ERROR_SECURE_WEIGHT
	)
	if Rng.roll_float() < clamp(field_chance, 0.0, ERROR_CHANCE_CAP):
		return "fielding"

	# 送球失策（ゴロ捌き後の一塁送球）。内野の失策順序は主にこの送球難易度(位置)で決まる。
	# 悪送球でも一塁手の捕球(IF_Secure)が上手ければアウトに救済される。
	if trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER and THROW_ERROR_BASE_BY_POSITION.has(position):
		var throw_deficiency: float = max(0.0, THROW_ERROR_REFERENCE_Z - ability_throw)
		# position_difficulty を送球にも掛ける: 一塁の短い送球は弱肩でも失策になりにくく、
		# 三塁・遊撃の強い/長い送球は難しい。これで内野の失策順序(遊撃≳三塁>二塁>一塁)が難度から出る。
		var throw_chance: float = makeable * position_difficulty * (
			float(THROW_ERROR_BASE_BY_POSITION[position])
			+ throw_deficiency * THROW_ERROR_WEIGHT
		)
		if Rng.roll_float() < clamp(throw_chance, 0.0, ERROR_CHANCE_CAP):
			# 一塁手(position 3 は自送球なので除く)の捕球救済。
			if position != 3 and _first_base_scoops(first_baseman):
				return ""
			return "throwing"

	return ""


# 悪送球を一塁手が捕球(スクープ)してアウトにできたか。一塁手の IF_Secure z が高いほど救済率が上がる。
static func _first_base_scoops(first_baseman: PSPlayerSeasonRecord) -> bool:
	if first_baseman == null:
		return false
	var secure: float = first_baseman.z_ability("IF_Secure", DEFAULT_FIELDING_AXIS_Z)
	var save_prob: float = clamp(
		FIRST_BASE_SCOOP_BASE + (secure - FIRST_BASE_SCOOP_REFERENCE_Z) * FIRST_BASE_SCOOP_WEIGHT,
		FIRST_BASE_SCOOP_MIN,
		FIRST_BASE_SCOOP_MAX
	)
	return Rng.roll_float() < save_prob


# 失策種別ごとの打者進塁。送球失策・外野後逸は余分進塁(二塁)が起こりうる。
static func _error_advance_bases(error_type: String) -> int:
	match error_type:
		"throwing":
			return 2 if Rng.roll_float() < THROW_ERROR_EXTRA_BASE_CHANCE else 1
		"outfield_misplay":
			return 2
	return 1


# 併殺成立確率。守備側の併殺完成力(z)と打者走力(z)、打球の強さで増減する。
static func _double_play_probability(batter: PSPlayerSeasonRecord, completion: float, position: int, ev: float) -> float:
	# 打者の走力 z。0.0 が平均、速いほど一塁到達が早く併殺を崩す。
	var batter_speed: float = 0.0 if batter == null else batter.z_ability("Run_Speed", 0.0)
	var chance: float = _rule_float("double_play_base", DOUBLE_PLAY_BASE)
	# 二遊間(2B/SS)は併殺機会が多く、三塁は中程度に補正する。
	var position_multiplier: float = 1.0
	match position:
		4, 6:
			position_multiplier = 1.25
		5:
			position_multiplier = 1.05
	# 守備側の併殺完成力 z が基準を超える分だけ併殺を増やす。
	chance += (completion - DOUBLE_PLAY_TEAMWORK_REFERENCE_Z) * DOUBLE_PLAY_COMPLETION_WEIGHT_Z * position_multiplier
	# 打者が速いほど併殺を減らす。
	chance -= batter_speed * DOUBLE_PLAY_SPEED_WEIGHT
	# 強い打球(EV>95)は併殺が崩れやすい。
	if ev > 95.0:
		chance -= 0.08
	return clamp(chance, 0.04, 0.65)


static func _apply_double_play_context(outcome: Dictionary, opportunity: bool, probability: float) -> void:
	if not opportunity:
		return
	outcome["double_play_opportunity"] = true
	outcome["double_play_probability"] = clamp(probability, 0.0, 1.0)


static func smoke_test_infield_throw_beat_probability() -> Dictionary:
	var fast_batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	fast_batter.player_id = -930001
	fast_batter.z_abilities_snapshot = {"Run_Speed": 2.2}
	var slow_batter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	slow_batter.player_id = -930002
	slow_batter.z_abilities_snapshot = {"Run_Speed": -1.4}
	var fast_probability: float = _batter_beats_grounder_throw_probability(
		fast_batter,
		6,
		72.0,
		-23.0,
		34.0,
		0.4,
		0.4
	)
	var slow_probability: float = _batter_beats_grounder_throw_probability(
		slow_batter,
		3,
		96.0,
		27.0,
		18.0,
		2.1,
		1.6
	)
	return {
		"ok": fast_probability > slow_probability and fast_probability > 0.12 and slow_probability < 0.06,
		"fast_probability": _round_float(fast_probability, 3),
		"slow_probability": _round_float(slow_probability, 3),
	}


static func smoke_test_groundout_runner_advancement_probabilities() -> Dictionary:
	var fast_runner: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	fast_runner.player_id = -940001
	fast_runner.z_abilities_snapshot = {"Run_Speed": 2.0, "Run_Judgment": 1.6}
	var slow_runner: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	slow_runner.player_id = -940002
	slow_runner.z_abilities_snapshot = {"Run_Speed": -1.5, "Run_Judgment": -1.2}
	var third_score_fast: float = _groundout_third_score_probability(fast_runner, 4, 74.0, 12.0, 34.0, 0.4)
	var third_score_slow: float = _groundout_third_score_probability(slow_runner, 1, 104.0, 2.0, 12.0, 2.1)
	var second_right_side: float = _groundout_second_to_third_probability(fast_runner, 4, 78.0, 13.0, 32.0)
	var second_left_side: float = _groundout_second_to_third_probability(slow_runner, 5, 98.0, -27.0, 20.0)
	var first_advance: float = _groundout_first_to_second_probability(fast_runner, 6, 86.0, -12.0, 28.0)
	return {
		"ok": (
			third_score_fast > third_score_slow
			and third_score_fast > 0.22
			and third_score_slow < 0.08
			and second_right_side > second_left_side
			and first_advance > 0.58
		),
		"third_score_fast": _round_float(third_score_fast, 3),
		"third_score_slow": _round_float(third_score_slow, 3),
		"second_right_side": _round_float(second_right_side, 3),
		"second_left_side": _round_float(second_left_side, 3),
		"first_advance": _round_float(first_advance, 3),
	}


static func _maybe_batter_beats_grounder_throw(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	physics: Dictionary,
	trajectory: String,
	position: int,
	ev: float,
	spray: float,
	distance: float,
	fielder_arm: float,
	teamwork: float
) -> Dictionary:
	if trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
		return {}
	if position < 1 or position > 6:
		return {}

	var probability: float = _batter_beats_grounder_throw_probability(
		batter,
		position,
		ev,
		spray,
		distance,
		fielder_arm,
		teamwork
	)
	if Rng.roll_float() >= probability:
		return {}

	var outcome: Dictionary = _forced_single_outcome(batter, bases, outs, physics, position, fielder_arm, trajectory)
	outcome["infield_throw_beat"] = true
	outcome["infield_throw_beat_probability"] = clamp(probability, 0.0, 1.0)
	outcome["throw_target_base"] = 1
	outcome["fielder_throw_arm_z"] = fielder_arm
	return outcome


static func _batter_beats_grounder_throw_probability(
	batter: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	spray: float,
	distance: float,
	fielder_arm: float,
	teamwork: float
) -> float:
	var batter_speed: float = 0.0 if batter == null else batter.z_ability("Run_Speed", 0.0)
	var soft: float = _soft_contact_factor(ev)
	var hard: float = _hard_contact_factor(ev)
	var depth: float = clamp(distance / INFIELD_DISTANCE_THRESHOLD, 0.0, 1.0)
	var lateral: float = _lateral_difficulty(position, spray)
	var probability: float = INFIELD_THROW_BEAT_BASE
	probability += batter_speed * INFIELD_THROW_BEAT_SPEED_WEIGHT_Z
	probability += soft * INFIELD_THROW_BEAT_SOFT_CONTACT_WEIGHT
	probability += depth * INFIELD_THROW_BEAT_DEPTH_WEIGHT
	probability += lateral * INFIELD_THROW_BEAT_LATERAL_WEIGHT
	probability -= hard * INFIELD_THROW_BEAT_HARD_CONTACT_PENALTY
	probability -= (fielder_arm - DEFAULT_FIELDING_AXIS_Z) * INFIELD_THROW_BEAT_ARM_WEIGHT_Z
	probability -= (teamwork - DOUBLE_PLAY_TEAMWORK_REFERENCE_Z) * INFIELD_THROW_BEAT_TEAMWORK_WEIGHT_Z
	match position:
		1, 2:
			probability += 0.025 + soft * 0.020
		3:
			probability -= 0.030
			if distance <= INFIELD_GROUNDER_DEPTH_EASY:
				probability -= 0.020
		4:
			probability += 0.005
		5:
			probability += 0.030
		6:
			probability += 0.040
	return clamp(probability, 0.0, INFIELD_THROW_BEAT_MAX)


static func _groundout_runner_advancement_outcome(
	bases: Array,
	outs: int,
	trajectory: String,
	position: int,
	ev: float,
	spray: float,
	distance: float,
	fielder_arm: float
) -> Dictionary:
	if outs >= 2:
		return {}
	if trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER:
		return {}
	if position < 1 or position > 6:
		return {}

	var advancements: Array = _groundout_runner_advancements(bases, position, ev, spray, distance, fielder_arm)
	if advancements.is_empty():
		return {}

	var outcome: Dictionary = _out_outcome(trajectory, position)
	outcome["runner_strategy"] = "groundout_advance"
	outcome["runner_advancements"] = advancements
	outcome["runner_events"] = _groundout_runner_events(advancements, position)
	return outcome


static func _groundout_runner_advancements(
	bases: Array,
	position: int,
	ev: float,
	spray: float,
	distance: float,
	fielder_arm: float
) -> Array:
	var advancements: Array = []
	var third_moved: bool = false
	var runner_on_third: PSPlayerSeasonRecord = bases[2] as PSPlayerSeasonRecord
	if runner_on_third != null:
		var third_probability: float = _groundout_third_score_probability(
			runner_on_third,
			position,
			ev,
			spray,
			distance,
			fielder_arm
		)
		if Rng.roll_float() < third_probability:
			var third_advancement: Dictionary = _runner_advancement(runner_on_third, 3, 4, true)
			third_advancement["advance_probability"] = third_probability
			advancements.append(third_advancement)
			third_moved = true

	var third_open: bool = runner_on_third == null or third_moved
	var second_moved: bool = false
	var runner_on_second: PSPlayerSeasonRecord = bases[1] as PSPlayerSeasonRecord
	if runner_on_second != null and third_open:
		var second_probability: float = _groundout_second_to_third_probability(
			runner_on_second,
			position,
			ev,
			spray,
			distance
		)
		if Rng.roll_float() < second_probability:
			var second_advancement: Dictionary = _runner_advancement(runner_on_second, 2, 3, true)
			second_advancement["advance_probability"] = second_probability
			advancements.append(second_advancement)
			second_moved = true

	var second_open: bool = runner_on_second == null or second_moved
	var runner_on_first: PSPlayerSeasonRecord = bases[0] as PSPlayerSeasonRecord
	if runner_on_first != null and second_open:
		var first_probability: float = _groundout_first_to_second_probability(
			runner_on_first,
			position,
			ev,
			spray,
			distance
		)
		if Rng.roll_float() < first_probability:
			var first_advancement: Dictionary = _runner_advancement(runner_on_first, 1, 2, true)
			first_advancement["advance_probability"] = first_probability
			advancements.append(first_advancement)
	return advancements


static func _groundout_third_score_probability(
	runner: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	spray: float,
	distance: float,
	fielder_arm: float
) -> float:
	if runner == null:
		return 0.0
	var speed: float = runner.z_ability("Run_Speed", 0.0)
	var judgment: float = runner.z_ability("Run_Judgment", 0.0)
	var soft: float = _soft_contact_factor(ev)
	var hard: float = _hard_contact_factor(ev)
	var depth: float = clamp(distance / INFIELD_DISTANCE_THRESHOLD, 0.0, 1.0)
	var lateral: float = _lateral_difficulty(position, spray)
	var chance: float = GROUNDOUT_THIRD_SCORE_BASE
	chance += speed * GROUNDOUT_THIRD_SCORE_SPEED_WEIGHT_Z
	chance += judgment * GROUNDOUT_THIRD_SCORE_JUDGMENT_WEIGHT_Z
	chance += soft * GROUNDOUT_THIRD_SCORE_SOFT_WEIGHT
	chance += depth * GROUNDOUT_THIRD_SCORE_DEPTH_WEIGHT
	chance += lateral * 0.040
	chance -= hard * 0.070
	chance -= (fielder_arm - DEFAULT_FIELDING_AXIS_Z) * GROUNDOUT_THIRD_SCORE_ARM_WEIGHT_Z
	match position:
		1, 2:
			chance -= 0.12
		3:
			chance -= 0.08
		5:
			chance -= 0.05
		4:
			chance += 0.05
		6:
			chance += 0.02
	return clamp(chance, 0.0, 0.80)


static func _groundout_second_to_third_probability(
	runner: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	spray: float,
	distance: float
) -> float:
	if runner == null:
		return 0.0
	var speed: float = runner.z_ability("Run_Speed", 0.0)
	var judgment: float = runner.z_ability("Run_Judgment", 0.0)
	var soft: float = _soft_contact_factor(ev)
	var depth: float = clamp(distance / INFIELD_DISTANCE_THRESHOLD, 0.0, 1.0)
	var lateral: float = _lateral_difficulty(position, spray)
	var chance: float = GROUNDOUT_SECOND_ADVANCE_BASE
	chance += speed * GROUNDOUT_SECOND_ADVANCE_SPEED_WEIGHT_Z
	chance += judgment * GROUNDOUT_SECOND_ADVANCE_JUDGMENT_WEIGHT_Z
	chance += soft * GROUNDOUT_SECOND_ADVANCE_SOFT_WEIGHT
	chance += depth * 0.045
	chance += lateral * 0.030
	match position:
		3:
			chance += 0.26
		4:
			chance += 0.30
		1:
			chance += 0.06
		2:
			chance -= 0.12
		5:
			chance -= 0.09
		6:
			chance -= 0.04
	return clamp(chance, 0.0, 0.70)


static func _groundout_first_to_second_probability(
	runner: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	_spray: float,
	distance: float
) -> float:
	if runner == null:
		return 0.0
	var speed: float = runner.z_ability("Run_Speed", 0.0)
	var judgment: float = runner.z_ability("Run_Judgment", 0.0)
	var soft: float = _soft_contact_factor(ev)
	var hard: float = _hard_contact_factor(ev)
	var depth: float = clamp(distance / INFIELD_DISTANCE_THRESHOLD, 0.0, 1.0)
	var chance: float = GROUNDOUT_FIRST_ADVANCE_BASE
	chance += speed * GROUNDOUT_FIRST_ADVANCE_SPEED_WEIGHT_Z
	chance += judgment * GROUNDOUT_FIRST_ADVANCE_JUDGMENT_WEIGHT_Z
	chance += soft * 0.045
	chance += depth * 0.030
	chance -= hard * 0.040
	match position:
		1, 2:
			chance -= 0.10
		3:
			chance -= 0.12
		5:
			chance -= 0.04
		4, 6:
			chance += 0.04
	return clamp(chance, 0.22, 0.94)


static func _groundout_runner_events(advancements: Array, position: int) -> Array:
	var events: Array = []
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		var from_base: int = int(advancement.get("from_base", 0))
		var to_base: int = int(advancement.get("to_base", 0))
		events.append({
			"event_type": "runner_event",
			"phase": "after_batted_ball",
			"strategy": "groundout_advance",
			"result": "groundout_advance",
			"runner_id": 0 if runner == null else runner.player_id,
			"batter_id": 0,
			"pitcher_id": 0,
			"catcher_id": 0,
			"from_base": from_base,
			"to_base": to_base,
			"is_steal_attempt": false,
			"is_stolen_base": false,
			"is_caught_stealing": false,
			"is_pickoff": false,
			"is_wild_pitch": false,
			"is_passed_ball": false,
			"is_balk": false,
			"is_defensive_indifference": false,
			"is_baserunning_out": false,
			"recorded_as_attempt": false,
			"state_already_applied": true,
			"outs_added": 0,
			"run_value": 0.0,
			"batter_rbi": from_base == 3 and to_base >= 4,
			"fielder_position": position,
			"advance_probability": float(advancement.get("advance_probability", 0.0)),
		})
	return events


static func _maybe_fielders_choice_outcome(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	trajectory: String,
	position: int,
	ev: float,
	fielder_arm: float,
	teamwork: float
) -> Dictionary:
	if trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER or outs >= 2:
		return {}
	if position < 1 or position > 6:
		return {}

	var home_probability: float = _fielders_choice_probability(
		batter,
		position,
		ev,
		fielder_arm,
		teamwork,
		3,
		4
	)
	if _has_runner(bases, 0) and _has_runner(bases, 1) and _has_runner(bases, 2):
		if Rng.roll_float() < home_probability:
			return _fielders_choice_outcome(bases, position, 3, 4, home_probability)

	var third_probability: float = _fielders_choice_probability(
		batter,
		position,
		ev,
		fielder_arm,
		teamwork,
		2,
		3
	)
	if _has_runner(bases, 0) and _has_runner(bases, 1):
		if Rng.roll_float() < third_probability:
			return _fielders_choice_outcome(bases, position, 2, 3, third_probability)

	var second_probability: float = _fielders_choice_probability(
		batter,
		position,
		ev,
		fielder_arm,
		teamwork,
		1,
		2
	)
	if _has_runner(bases, 0):
		if Rng.roll_float() < second_probability:
			return _fielders_choice_outcome(bases, position, 1, 2, second_probability)
	return {}


static func _fielders_choice_probability(
	batter: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	fielder_arm: float,
	teamwork: float,
	force_from_base: int,
	force_to_base: int
) -> float:
	var probability: float = FIELDERS_CHOICE_SECOND_BASE
	match force_to_base:
		4:
			probability = FIELDERS_CHOICE_HOME_BASE
		3:
			probability = FIELDERS_CHOICE_THIRD_BASE
		2:
			probability = FIELDERS_CHOICE_SECOND_BASE

	match force_to_base:
		4:
			match position:
				1, 2, 3, 5:
					probability += 0.12
				4, 6:
					probability -= 0.08
		3:
			match position:
				5:
					probability += 0.22
				1, 6:
					probability += 0.06
				3, 4:
					probability -= 0.04
		2:
			match position:
				4, 6:
					probability += 0.16
				5:
					probability += 0.06
				1, 3:
					probability -= 0.04
				2:
					probability -= 0.10

	var batter_speed: float = 0.0 if batter == null else batter.z_ability("Run_Speed", 0.0)
	probability += batter_speed * FIELDERS_CHOICE_BATTER_SPEED_WEIGHT_Z
	probability += (fielder_arm - DEFAULT_FIELDING_AXIS_Z) * FIELDERS_CHOICE_ARM_WEIGHT_Z
	probability += (teamwork - DOUBLE_PLAY_TEAMWORK_REFERENCE_Z) * FIELDERS_CHOICE_TEAMWORK_WEIGHT_Z
	probability += clamp((ev - 88.0) / 22.0, -0.5, 1.0) * FIELDERS_CHOICE_HARD_CONTACT_WEIGHT
	if force_from_base == 3:
		probability -= batter_speed * 0.020
	return clamp(probability, 0.0, FIELDERS_CHOICE_MAX)


static func _fielders_choice_outcome(
	bases: Array,
	position: int,
	force_from_base: int,
	force_to_base: int,
	probability: float
) -> Dictionary:
	var advancements: Array = _fielders_choice_advancements(bases, force_from_base, force_to_base)
	return {
		"result": "ground_fielders_choice_%s_to_%s" % [FIELD_NAMES.get(position, "unknown"), _base_label(force_to_base)],
		"category": CATEGORY_FIELDERS_CHOICE,
		"bases": 1,
		"fielder_position": position,
		"fielders_choice_probability": clamp(probability, 0.0, 1.0),
		"force_out_from_base": force_from_base,
		"force_out_to_base": force_to_base,
		"runner_advancements": advancements,
		"runner_events": _fielders_choice_runner_events(advancements, position),
	}


static func _fielders_choice_advancements(bases: Array, force_from_base: int, force_to_base: int) -> Array:
	var advancements: Array = []
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var from_base: int = base_index + 1
		var to_base: int = from_base
		var is_out: bool = from_base == force_from_base
		if is_out:
			to_base = force_to_base
		elif from_base < force_from_base:
			to_base = from_base + 1
		advancements.append(_runner_advancement(runner, from_base, to_base, to_base > from_base, is_out))
	return advancements


static func _fielders_choice_runner_events(advancements: Array, position: int) -> Array:
	var events: Array = []
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		if not bool(advancement.get("is_out", false)):
			continue
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		events.append({
			"event_type": "runner_event",
			"phase": "after_batted_ball",
			"strategy": "fielders_choice",
			"result": "force_out",
			"runner_id": 0 if runner == null else runner.player_id,
			"batter_id": 0,
			"pitcher_id": 0,
			"catcher_id": 0,
			"from_base": int(advancement.get("from_base", 0)),
			"to_base": int(advancement.get("to_base", 0)),
			"is_steal_attempt": false,
			"is_stolen_base": false,
			"is_caught_stealing": false,
			"is_pickoff": false,
			"is_wild_pitch": false,
			"is_passed_ball": false,
			"is_balk": false,
			"is_defensive_indifference": false,
			"is_baserunning_out": false,
			"recorded_as_attempt": false,
			"state_already_applied": true,
			"outs_added": 0,
			"run_value": 0.0,
			"fielder_position": position,
		})
	return events


static func _maybe_nonforce_home_throw_outcome(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	trajectory: String,
	position: int,
	ev: float,
	fielder_arm: float,
	teamwork: float
) -> Dictionary:
	if trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER or outs >= 2:
		return {}
	if position < 1 or position > 6:
		return {}
	if not _has_runner(bases, 2):
		return {}
	# 満塁時は本塁フォースとして _maybe_fielders_choice_outcome 側で扱う。
	if _has_runner(bases, 0) and _has_runner(bases, 1):
		return {}

	var runner_on_third: PSPlayerSeasonRecord = bases[2] as PSPlayerSeasonRecord
	var attempt_probability: float = _nonforce_home_throw_attempt_probability(
		runner_on_third,
		batter,
		position,
		ev,
		fielder_arm,
		teamwork
	)
	if Rng.roll_float() >= attempt_probability:
		return {}

	var out_probability: float = _nonforce_home_throw_out_probability(
		runner_on_third,
		position,
		ev,
		fielder_arm,
		teamwork
	)
	var runner_out: bool = Rng.roll_float() < out_probability
	return _nonforce_home_throw_outcome(bases, position, attempt_probability, out_probability, runner_out)


static func _nonforce_home_throw_attempt_probability(
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	fielder_arm: float,
	teamwork: float
) -> float:
	var runner_speed: float = 0.0 if runner == null else runner.z_ability("Run_Speed", 0.0)
	var runner_judgment: float = 0.0 if runner == null else runner.z_ability("Run_Judgment", 0.0)
	var batter_speed: float = 0.0 if batter == null else batter.z_ability("Run_Speed", 0.0)
	var hard_contact: float = clamp((ev - 84.0) / 24.0, -0.4, 1.0)
	var close_play: float = clamp(1.0 - runner_speed * 0.24 - runner_judgment * 0.12 + batter_speed * 0.14, 0.0, 1.2)
	var probability: float = HOME_THROW_ATTEMPT_BASE
	probability += close_play * HOME_THROW_ATTEMPT_CLOSE_PLAY_WEIGHT
	probability += hard_contact * HOME_THROW_ATTEMPT_CONTACT_WEIGHT
	probability += (fielder_arm - DEFAULT_FIELDING_AXIS_Z) * HOME_THROW_ATTEMPT_ARM_WEIGHT_Z
	probability += (teamwork - DOUBLE_PLAY_TEAMWORK_REFERENCE_Z) * 0.025
	match position:
		1, 2, 3, 5:
			probability += 0.10
		4, 6:
			probability -= 0.06
	return clamp(probability, 0.0, 0.76)


static func _nonforce_home_throw_out_probability(
	runner: PSPlayerSeasonRecord,
	position: int,
	ev: float,
	fielder_arm: float,
	teamwork: float
) -> float:
	var runner_speed: float = 0.0 if runner == null else runner.z_ability("Run_Speed", 0.0)
	var runner_judgment: float = 0.0 if runner == null else runner.z_ability("Run_Judgment", 0.0)
	var hard_contact: float = clamp((ev - 86.0) / 24.0, -0.4, 1.0)
	var probability: float = HOME_THROW_OUT_BASE
	probability -= runner_speed * HOME_THROW_OUT_RUNNER_SPEED_WEIGHT_Z
	probability -= runner_judgment * HOME_THROW_OUT_RUNNER_JUDGMENT_WEIGHT_Z
	probability += (fielder_arm - DEFAULT_FIELDING_AXIS_Z) * HOME_THROW_OUT_FIELDER_ARM_WEIGHT_Z
	probability += (teamwork - DOUBLE_PLAY_TEAMWORK_REFERENCE_Z) * 0.030
	probability += hard_contact * 0.060
	match position:
		1, 2, 3, 5:
			probability += 0.08
		4, 6:
			probability -= 0.05
	return clamp(probability, 0.08, 0.86)


static func _nonforce_home_throw_outcome(
	bases: Array,
	position: int,
	attempt_probability: float,
	out_probability: float,
	runner_out: bool
) -> Dictionary:
	var advancements: Array = _nonforce_home_throw_advancements(bases, runner_out)
	var result_suffix: String = "out" if runner_out else "safe"
	return {
		"result": "ground_home_throw_%s_%s" % [FIELD_NAMES.get(position, "unknown"), result_suffix],
		"category": CATEGORY_FIELDERS_CHOICE,
		"bases": 1,
		"fielder_position": position,
		"fielders_choice_probability": clamp(attempt_probability, 0.0, 1.0),
		"fielders_choice_outs": 1 if runner_out else 0,
		"home_throw_attempt_probability": clamp(attempt_probability, 0.0, 1.0),
		"home_throw_out_probability": clamp(out_probability, 0.0, 1.0),
		"home_throw_runner_out": runner_out,
		"runner_advancements": advancements,
		"runner_events": _nonforce_home_throw_runner_events(advancements, position, runner_out),
	}


static func _nonforce_home_throw_advancements(bases: Array, runner_out: bool) -> Array:
	var advancements: Array = []
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var from_base: int = base_index + 1
		var to_base: int = from_base
		var is_out: bool = false
		if from_base == 3:
			to_base = 4
			is_out = runner_out
		elif from_base == 1:
			to_base = 2
		elif from_base == 2 and Rng.roll_float() < _home_throw_trail_advance_probability(runner):
			to_base = 3
		advancements.append(_runner_advancement(runner, from_base, to_base, to_base > from_base, is_out))
	return advancements


static func _home_throw_trail_advance_probability(runner: PSPlayerSeasonRecord) -> float:
	if runner == null:
		return 0.0
	var speed: float = runner.z_ability("Run_Speed", 0.0)
	var judgment: float = runner.z_ability("Run_Judgment", 0.0)
	return clamp(HOME_THROW_TRAIL_ADVANCE_BASE + speed * 0.040 + judgment * 0.035, 0.04, 0.64)


static func _nonforce_home_throw_runner_events(advancements: Array, position: int, runner_out: bool) -> Array:
	var events: Array = []
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var from_base: int = int(advancement.get("from_base", 0))
		var to_base: int = int(advancement.get("to_base", 0))
		if from_base != 3 and to_base <= from_base:
			continue
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		var is_out: bool = bool(advancement.get("is_out", false))
		var result: String = "runner_out_advancing" if is_out else "advance_on_throw"
		events.append({
			"event_type": "runner_event",
			"phase": "after_batted_ball",
			"strategy": "home_throw",
			"result": result,
			"runner_id": 0 if runner == null else runner.player_id,
			"batter_id": 0,
			"pitcher_id": 0,
			"catcher_id": 0,
			"from_base": from_base,
			"to_base": to_base,
			"is_steal_attempt": false,
			"is_stolen_base": false,
			"is_caught_stealing": false,
			"is_pickoff": false,
			"is_wild_pitch": false,
			"is_passed_ball": false,
			"is_balk": false,
			"is_defensive_indifference": false,
			"is_baserunning_out": is_out,
			"recorded_as_attempt": false,
			"state_already_applied": true,
			"outs_added": 0,
			"run_value": 0.0,
			"batter_rbi": from_base == 3 and to_base >= 4 and not is_out,
			"fielder_position": position,
			"home_throw_runner_out": runner_out,
		})
	return events


static func _base_label(base: int) -> String:
	match base:
		1:
			return "first"
		2:
			return "second"
		3:
			return "third"
		4:
			return "home"
	return "base_%d" % base


static func _sacrifice_fly_probability(
	bases: Array,
	outs: int,
	trajectory: String,
	distance: float,
	hang_time: float,
	position: int,
	fielder_arm: float
) -> float:
	if trajectory != PSBattedBallPhysicsResolver.TRAJECTORY_FLY or outs > 1:
		return 0.0
	if not _has_runner(bases, 2):
		return 0.0
	var runner: PSPlayerSeasonRecord = bases[2] as PSPlayerSeasonRecord
	if runner == null:
		return 0.0
	if hang_time < SACRIFICE_FLY_HANG_MIN:
		return 0.0

	var depth_factor: float = clamp(
		(distance - SACRIFICE_FLY_DISTANCE_MIN) / (SACRIFICE_FLY_DISTANCE_FULL - SACRIFICE_FLY_DISTANCE_MIN),
		0.0,
		1.0
	)
	var hang_factor: float = clamp(
		(hang_time - SACRIFICE_FLY_HANG_MIN) / (SACRIFICE_FLY_HANG_FULL - SACRIFICE_FLY_HANG_MIN),
		0.0,
		1.0
	)
	var runner_speed: float = runner.z_ability("Run_Speed", 0.0)
	var runner_judgment: float = runner.z_ability("Run_Judgment", 0.0)
	var position_bonus: float = 0.0
	match position:
		7, 9:
			position_bonus = 0.04
		8:
			position_bonus = 0.01
		3, 4, 5, 6:
			position_bonus = -0.12
		1, 2:
			position_bonus = -0.22

	var chance: float = (
		_rule_float("sacrifice_fly_base", SACRIFICE_FLY_BASE)
		+ depth_factor * SACRIFICE_FLY_DEPTH_WEIGHT
		+ hang_factor * SACRIFICE_FLY_HANG_WEIGHT
		+ runner_speed * SACRIFICE_FLY_SPEED_WEIGHT_Z
		+ runner_judgment * SACRIFICE_FLY_JUDGMENT_WEIGHT_Z
		+ position_bonus
		- (fielder_arm - SACRIFICE_FLY_ARM_REFERENCE_Z) * SACRIFICE_FLY_ARM_WEIGHT_Z
	)
	if depth_factor < 0.18 and runner_speed + runner_judgment * 0.5 < 0.5:
		chance *= 0.25
	var maximum: float = SACRIFICE_FLY_INFIELD_MAX if position < 7 else SACRIFICE_FLY_MAX
	return clamp(chance, 0.0, maximum)


static func _apply_sacrifice_fly_context(
	outcome: Dictionary,
	probability: float,
	distance: float,
	hang_time: float,
	fielder_arm: float
) -> void:
	outcome["sacrifice_fly_probability"] = clamp(probability, 0.0, 1.0)
	outcome["sacrifice_fly_distance"] = distance
	outcome["sacrifice_fly_hang_time"] = hang_time
	outcome["sacrifice_fly_fielder_arm_z"] = fielder_arm


static func _apply_sacrifice_fly_advancements(
	outcome: Dictionary,
	bases: Array,
	distance: float,
	hang_time: float,
	position: int,
	fielder_arm: float
) -> void:
	var advancements: Array = []
	var runner_on_third: PSPlayerSeasonRecord = bases[2] as PSPlayerSeasonRecord
	if runner_on_third != null:
		advancements.append(_runner_advancement(runner_on_third, 3, 4, false))

	var runner_on_second: PSPlayerSeasonRecord = bases[1] as PSPlayerSeasonRecord
	var second_base_probability: float = 0.0
	if runner_on_second != null:
		second_base_probability = _sacrifice_fly_second_base_probability(
			runner_on_second,
			distance,
			hang_time,
			position,
			fielder_arm
		)
		if Rng.roll_float() < second_base_probability:
			advancements.append(_runner_advancement(runner_on_second, 2, 3, true))

	outcome["runner_strategy"] = "tag_up"
	outcome["runner_advancements"] = advancements
	outcome["runner_events"] = _sacrifice_fly_runner_events(advancements, position, fielder_arm)
	outcome["sacrifice_fly_second_base_probability"] = second_base_probability


static func _sacrifice_fly_second_base_probability(
	runner: PSPlayerSeasonRecord,
	distance: float,
	hang_time: float,
	position: int,
	fielder_arm: float
) -> float:
	if runner == null or position < 7:
		return 0.0
	var depth_factor: float = clamp(
		(distance - SACRIFICE_FLY_DISTANCE_MIN) / (SACRIFICE_FLY_DISTANCE_FULL - SACRIFICE_FLY_DISTANCE_MIN),
		0.0,
		1.0
	)
	var hang_factor: float = clamp(
		(hang_time - SACRIFICE_FLY_HANG_MIN) / (SACRIFICE_FLY_HANG_FULL - SACRIFICE_FLY_HANG_MIN),
		0.0,
		1.0
	)
	var runner_speed: float = runner.z_ability("Run_Speed", 0.0)
	var runner_judgment: float = runner.z_ability("Run_Judgment", 0.0)
	var position_adjustment: float = -0.03 if position == 8 else 0.02
	var chance: float = (
		SACRIFICE_FLY_SECOND_BASE_BASE
		+ depth_factor * SACRIFICE_FLY_SECOND_BASE_DEPTH_WEIGHT
		+ hang_factor * SACRIFICE_FLY_SECOND_BASE_HANG_WEIGHT
		+ runner_speed * SACRIFICE_FLY_SECOND_BASE_SPEED_WEIGHT_Z
		+ runner_judgment * SACRIFICE_FLY_SECOND_BASE_JUDGMENT_WEIGHT_Z
		+ position_adjustment
		- (fielder_arm - SACRIFICE_FLY_ARM_REFERENCE_Z) * SACRIFICE_FLY_SECOND_BASE_ARM_WEIGHT_Z
	)
	return clamp(chance, 0.0, SACRIFICE_FLY_SECOND_BASE_MAX)


static func _runner_advancement(
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	is_extra: bool,
	is_out: bool = false
) -> Dictionary:
	return {
		"runner": runner,
		"runner_id": 0 if runner == null else runner.player_id,
		"from_base": from_base,
		"to_base": to_base,
		"baseline_to": from_base,
		"is_out": is_out,
		"is_extra": is_extra,
	}


static func _sacrifice_fly_runner_events(advancements: Array, position: int, fielder_arm: float) -> Array:
	var events: Array = []
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		var to_base: int = int(advancement.get("to_base", 0))
		events.append({
			"event_type": "runner_event",
			"phase": "after_batted_ball",
			"strategy": "tag_up",
			"result": "tag_up",
			"runner_id": 0 if runner == null else runner.player_id,
			"batter_id": 0,
			"pitcher_id": 0,
			"catcher_id": 0,
			"from_base": int(advancement.get("from_base", 0)),
			"to_base": to_base,
			"is_steal_attempt": false,
			"is_stolen_base": false,
			"is_caught_stealing": false,
			"is_pickoff": false,
			"is_wild_pitch": false,
			"is_passed_ball": false,
			"is_balk": false,
			"is_defensive_indifference": false,
			"is_baserunning_out": false,
			"recorded_as_attempt": false,
			"state_already_applied": true,
			"outs_added": 0,
			"run_value": 0.0,
			"batter_rbi": to_base >= 4,
			"fielder_position": position,
			"fielder_arm": fielder_arm,
		})
	return events


static func _sacrifice_fly_outcome(position: int) -> Dictionary:
	return {
		"result": "sacrifice_fly_%s" % FIELD_NAMES.get(position, "unknown"),
		"category": CATEGORY_SACRIFICE_FLY,
		"bases": 0,
		"fielder_position": position,
	}


static func _double_play_outcome(position: int) -> Dictionary:
	return {
		"result": "double_play_%s" % FIELD_NAMES.get(position, "unknown"),
		"category": CATEGORY_DOUBLE_PLAY,
		"bases": 0,
		"fielder_position": position,
	}


static func _error_outcome(position: int, error_type: String = "fielding", bases: int = 1) -> Dictionary:
	return {
		"result": "%s_error_%s" % [error_type, FIELD_NAMES.get(position, "unknown")],
		"category": CATEGORY_ERROR,
		"bases": bases,
		"fielder_position": position,
		"error_type": error_type,
	}


static func _out_outcome(trajectory: String, position: int) -> Dictionary:
	var prefix: String = "groundout"
	match trajectory:
		PSBattedBallPhysicsResolver.TRAJECTORY_LINER:
			prefix = "lineout"
		PSBattedBallPhysicsResolver.TRAJECTORY_FLY:
			prefix = "outfield_fly" if position >= 7 else "infield_fly"
		PSBattedBallPhysicsResolver.TRAJECTORY_POPUP:
			prefix = "infield_fly"
	return {
		"result": "%s_%s" % [prefix, FIELD_NAMES.get(position, "unknown")],
		"category": CATEGORY_OUT,
		"bases": 0,
		"fielder_position": position,
	}


static func _forced_single_outcome(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	physics: Dictionary,
	position: int,
	fielder_arm: float,
	trajectory: String
) -> Dictionary:
	var plan: Dictionary = PSRunnerAdvanceResolver.resolve_hit(batter, bases, outs, physics, position, fielder_arm, 1)
	var infield_single: bool = position < 7 and trajectory == PSBattedBallPhysicsResolver.TRAJECTORY_GROUNDER
	var outcome: Dictionary = {
		"result": _hit_result_name(1, position, infield_single),
		"category": CATEGORY_HIT,
		"bases": 1,
		"fielder_position": position,
		"forced_single": true,
	}
	outcome.merge(plan, true)
	outcome["bases"] = 1
	return outcome


static func _grounder_hit_outcome(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	physics: Dictionary,
	position: int,
	fielder_arm: float
) -> Dictionary:
	var plan: Dictionary = PSRunnerAdvanceResolver.resolve_hit(batter, bases, outs, physics, position, fielder_arm, 1)
	var bases_taken: int = int(plan.get("bases", 1))
	var result: String = _hit_result_name(bases_taken, position, position < 7)
	var outcome: Dictionary = {
		"result": result,
		"category": CATEGORY_HIT,
		"bases": bases_taken,
		"fielder_position": position,
	}
	outcome.merge(plan, true)
	return outcome


static func _airball_hit_outcome(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	physics: Dictionary,
	outfielder_arm: float,
	position: int
) -> Dictionary:
	var spray: float = float(physics.get("spray_angle", 0.0))
	var distance: float = float(physics.get("distance", 0.0))
	var trajectory: String = str(physics.get("trajectory_bucket", "liner"))
	var hit_field: int = position if position >= 7 else _outfield_position_for_spray(spray, distance, trajectory)
	var plan: Dictionary = PSRunnerAdvanceResolver.resolve_hit(batter, bases, outs, physics, hit_field, outfielder_arm, 1)
	var bases_taken: int = int(plan.get("bases", 1))
	var outcome: Dictionary = {
		"result": _hit_result_name(bases_taken, hit_field, false),
		"category": CATEGORY_HIT,
		"bases": bases_taken,
		"fielder_position": hit_field,
	}
	outcome.merge(plan, true)
	return outcome


static func _hit_result_name(bases_taken: int, position: int, infield_single: bool = false) -> String:
	var field_name: String = _hit_field_name(position)
	match bases_taken:
		3:
			return "triple_%s" % field_name
		2:
			return "double_%s" % field_name
		_:
			if infield_single:
				return "infield_single_%s" % FIELD_NAMES.get(position, "unknown")
			return "single_%s" % field_name


static func _hit_field_name(position: int) -> String:
	if position == 7:
		return "left"
	if position == 8:
		return "center"
	if position == 9:
		return "right"
	return str(FIELD_NAMES.get(position, "unknown"))


static func _has_runner(bases: Array, base_index: int) -> bool:
	return base_index >= 0 and base_index < bases.size() and bases[base_index] != null


static func _fielder_record(defense: Dictionary, position: int) -> PSPlayerSeasonRecord:
	if position == 1:
		return defense.get("pitcher", null) as PSPlayerSeasonRecord
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == position:
			return slot.get("record", null) as PSPlayerSeasonRecord

	var batters: Array = defense.get("batters", []) as Array
	for batter_value in batters:
		var batter: PSPlayerSeasonRecord = batter_value as PSPlayerSeasonRecord
		if batter != null and batter.position == position:
			return batter
	return null


static func _fielder_ability_profile(defense: Dictionary, fielder: PSPlayerSeasonRecord, position: int) -> Dictionary:
	if fielder == null:
		return {
			"range": DEFAULT_FIELDING_AXIS_Z,
			"reaction": DEFAULT_FIELDING_AXIS_Z,
			"secure": DEFAULT_FIELDING_AXIS_Z,
			"arm": DEFAULT_FIELDING_AXIS_Z,
			"teamwork": DEFAULT_FIELDING_AXIS_Z,
			"blend": DEFAULT_FIELDING_AXIS_Z,
		}
	var cache: Dictionary = defense.get(FIELDER_ABILITY_CACHE_KEY, {}) as Dictionary
	if not defense.has(FIELDER_ABILITY_CACHE_KEY):
		defense[FIELDER_ABILITY_CACHE_KEY] = cache
	var cache_key: String = "%d:%d" % [position, fielder.player_id]
	if cache.has(cache_key):
		return cache[cache_key] as Dictionary

	var axis_values: Dictionary = {
		"reach": _axis_z(fielder, position, "reach"),
		"reaction": _axis_z(fielder, position, "reaction"),
		"secure": _axis_z(fielder, position, "secure"),
		"throw": _axis_z(fielder, position, "throw"),
		"teamwork": _axis_z(fielder, position, "teamwork"),
	}
	var weights: Dictionary = POSITION_AXIS_WEIGHTS.get(position, {}) as Dictionary
	var total: float = 0.0
	var weight_total: float = 0.0
	for axis_value in weights.keys():
		var axis: String = str(axis_value)
		if not axis_values.has(axis):
			axis_values[axis] = _axis_z(fielder, position, axis)
		var weight: float = float(weights[axis_value])
		total += float(axis_values[axis]) * weight
		weight_total += weight
	var blend: float = DEFAULT_FIELDING_AXIS_Z if weight_total <= 0.0 else total / weight_total
	var profile: Dictionary = {
		"range": float(axis_values.get("reach", DEFAULT_FIELDING_AXIS_Z)),
		"reaction": float(axis_values.get("reaction", DEFAULT_FIELDING_AXIS_Z)),
		"secure": float(axis_values.get("secure", DEFAULT_FIELDING_AXIS_Z)),
		"arm": float(axis_values.get("throw", DEFAULT_FIELDING_AXIS_Z)),
		"teamwork": float(axis_values.get("teamwork", DEFAULT_FIELDING_AXIS_Z)),
		"blend": blend,
	}
	cache[cache_key] = profile
	return profile


static func _trajectory_position_multiplier(trajectory: String, position: int) -> float:
	var row: Dictionary = TRAJECTORY_CATCH_CONVERSION_MULTIPLIER.get(trajectory, {}) as Dictionary
	return float(row.get(position, 1.0))


static func _axis_z(fielder: PSPlayerSeasonRecord, position: int, axis: String) -> float:
	if fielder == null:
		return DEFAULT_FIELDING_AXIS_Z
	match position:
		1:
			match axis:
				"reach", "reaction":
					return _z_or_default(fielder, "PF_Reach")
				"secure", "teamwork":
					return _z_or_default(fielder, "PF_Secure")
				"throw":
					return _z_or_default(fielder, "PF_Throw")
		2:
			match axis:
				"reach", "reaction", "secure":
					return _z_or_default(fielder, "C_FieldSecure")
				"blocking":
					return _z_or_default(fielder, "C_Blocking")
				"throw":
					return _weighted_z([
						_z_or_default(fielder, "C_Throw"),
						_z_or_default(fielder, "C_FieldSecure"),
					], [0.78, 0.22])
				"framing":
					return _z_or_default(fielder, "C_Framing")
				"game_call", "teamwork":
					return _z_or_default(fielder, "C_GameCall")
		3, 4, 5, 6:
			match axis:
				"reach":
					return _z_or_default(fielder, "IF_Reach")
				"reaction":
					return _weighted_z([
						_z_or_default(fielder, "IF_Reach"),
						_z_or_default(fielder, "IF_PositionFit"),
					], [0.68, 0.32])
				"secure":
					return _z_or_default(fielder, "IF_Secure")
				"throw":
					return _weighted_z([
						_z_or_default(fielder, "IF_ThrowPower"),
						_z_or_default(fielder, "IF_ThrowAccuracy"),
					], [0.55, 0.45])
				"teamwork":
					return _weighted_z([
						_z_or_default(fielder, "IF_Exchange"),
						_z_or_default(fielder, "IF_PositionFit"),
					], [0.70, 0.30])
		7, 8, 9:
			match axis:
				"reach":
					return _z_or_default(fielder, "OF_Reach")
				"reaction":
					return _z_or_default(fielder, "OF_Route")
				"secure":
					return _z_or_default(fielder, "OF_Secure")
				"throw":
					return _weighted_z([
						_z_or_default(fielder, "OF_ArmPower"),
						_z_or_default(fielder, "OF_ArmAccuracy"),
						_z_or_default(fielder, "OF_Release"),
					], [0.48, 0.34, 0.18])
				"teamwork":
					return _weighted_z([
						_z_or_default(fielder, "OF_Route"),
						_z_or_default(fielder, "OF_PositionFit"),
					], [0.65, 0.35])
	return DEFAULT_FIELDING_AXIS_Z


static func _z_or_default(record: PSPlayerSeasonRecord, z_key: String, default_value: float = DEFAULT_FIELDING_AXIS_Z) -> float:
	if record != null and record.z_abilities_snapshot.has(z_key):
		return record.z_ability(z_key, default_value)
	return default_value


static func _weighted_z(values: Array, weights: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	var n: int = min(values.size(), weights.size())
	for i in range(n):
		var weight: float = float(weights[i])
		total += float(values[i]) * weight
		weight_total += weight
	if weight_total <= 0.0:
		return DEFAULT_FIELDING_AXIS_Z
	return total / weight_total


static func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale


static func _rule_float(name: String, fallback: float) -> float:
	return ModManager.rule_float("simulation.play_resolver.%s" % name, fallback)
