extends RefCounted
class_name PSPitchAggregateSimulator

# 打席カテゴリと能力から、球数・ボール/ストライク・空振りなどの集計 PitchSummary を生成する。
# 出力スキーマ:
# {pitches, balls, strikes, final_count, swings, whiffs, called_strikes, fouls,
#  in_zone_pitches, out_zone_pitches, first_pitch_strike, csw}

const CATEGORY_K: String = "k"
const CATEGORY_BB: String = "bb"
const CATEGORY_HBP: String = "hbp"
# 球数生成の調整係数。THT/FanGraphs の 1988-2013 MLB 全PA球数分布を土台に、
# 三振/四球の最低球数制約を満たすカテゴリ別分布へ分解している。
# https://tht.fangraphs.com/tht-live/just-how-rare-is-a-14-pitch-plate-appearance/
const BIP_PITCH_WEIGHTS: Array = [
	0.1430, 0.2881, 0.1695, 0.1584, 0.1201,
	0.0829, 0.0280, 0.0077, 0.0020, 0.0001,
	0.0, 0.0, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0, 0.0,
]
const K_PITCH_WEIGHTS: Array = [
	0.0, 0.0, 0.2000, 0.2800, 0.2500,
	0.1500, 0.0700, 0.0300, 0.0120, 0.0050,
	0.0020, 0.0008, 0.0002, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0, 0.0,
]
const BB_PITCH_WEIGHTS: Array = [
	0.0, 0.0, 0.0, 0.2800, 0.3000,
	0.2000, 0.1100, 0.0550, 0.0250, 0.0120,
	0.0060, 0.0030, 0.0015, 0.0008, 0.0004,
	0.0002, 0.0001, 0.0, 0.0, 0.0,
]
const HBP_PITCH_WEIGHTS: Array = [
	0.5500, 0.2500, 0.1200, 0.0500, 0.0200,
	0.0070, 0.0030, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0, 0.0,
]
# 球数を増減させる能力係数。
const PATIENCE_COEF: float = 0.4            # 打者の選球眼が球数を増やす係数。
const AGGRESSION_COEF: float = 0.4          # 打者の積極性が球数を減らす係数。
const EFFICIENCY_COEF: float = 0.3          # 投手の効率(省エネ度)が球数を減らす係数。
const GAMECALL_EFFICIENCY_COEF: float = 0.2 # 捕手の配球が球数効率に効く係数。
const TTO_PITCH_COEF: float = 4.6           # 打順3巡目以降の粘られやすさを球数へ反映する係数。
# 球数デルタの基準値。raw z の各項 (bat_bb_create*PATIENCE_COEF 等) を中立点なしでそのまま
# 合算するための定数項 (旧: 各項を「実測母平均を引いてから係数を掛ける」形にしていたものを、
# 母平均*係数の合計として1回だけここに畳み込んだもの。数式は代数的に同一、平均の実行時参照は無い)。
const PITCH_DELTA_BASE: float = 0.57237
const FATIGUE_PITCH_COEF: float = 1.6       # 疲労が球数を増やす係数。
const MIN_PITCH_COUNT: int = 1              # 1打席あたり球数の下限クランプ。
const MAX_PITCH_COUNT: int = 20             # 1打席あたり球数の上限クランプ。


# precomp は以下を期待:
#   batter_z: Dictionary{Bat_BBCreate, Bat_Aggression, ...}
#   pitcher_z: Dictionary{Pit_Efficiency, ...}
#   catcher_z: Dictionary{C_GameCall, ...}
#   fatigue_factor: float (1.0 = 元気)
# 戻り値: 既存 PitchSummary 完全互換 Dictionary。
static func simulate(category: String, precomp: Dictionary) -> Dictionary:
	var batter_z: Dictionary = precomp.get("batter_z", {}) as Dictionary
	var pitcher_z: Dictionary = precomp.get("pitcher_z", {}) as Dictionary
	var catcher_z: Dictionary = precomp.get("catcher_z", {}) as Dictionary
	var fatigue_factor: float = float(precomp.get("fatigue_factor", 1.0))

	var bat_bb_create: float = float(batter_z.get("Bat_BBCreate", 0.0))
	var bat_aggression: float = float(batter_z.get("Bat_Aggression", 0.0))
	var pit_efficiency: float = float(pitcher_z.get("Pit_Efficiency", 0.0))
	var c_game_call: float = float(catcher_z.get("C_GameCall", 0.0))
	var tto_round_weight: float = float(precomp.get("tto_round_weight", 0.0))

	var pitch_delta: float = PITCH_DELTA_BASE
	pitch_delta += bat_bb_create * PATIENCE_COEF
	pitch_delta -= bat_aggression * AGGRESSION_COEF
	pitch_delta -= pit_efficiency * EFFICIENCY_COEF
	pitch_delta -= c_game_call * GAMECALL_EFFICIENCY_COEF
	pitch_delta += (1.0 - fatigue_factor) * FATIGUE_PITCH_COEF
	pitch_delta += tto_round_weight * TTO_PITCH_COEF

	var min_p: int = max(MIN_PITCH_COUNT, _category_min_pitches(category))
	var max_p: int = MAX_PITCH_COUNT
	var pitches: int = _apply_pitch_delta(_roll_base_pitch_count(category, precomp), pitch_delta, precomp, min_p, max_p)

	var balls: int
	var strikes: int
	match category:
		CATEGORY_K:
			strikes = 3
			balls = int(clamp(pitches - 3 - _foul_count_for(category, pitches), 0, 3))
		CATEGORY_BB:
			balls = 4
			strikes = int(clamp(pitches - 4 - _foul_count_for(category, pitches), 0, 2))
		CATEGORY_HBP:
			balls = int(clamp(pitches - 1, 0, 3))
			strikes = max(0, pitches - 1 - balls)
		_:
			# BIP: 最後の1球で打って終了。前球までで balls/strikes 任意（max 2 strikes）。
			strikes = int(clamp(_deterministic_int(precomp, "bip_strikes", 0, min(2, pitches - 1)), 0, 2))
			balls = int(clamp(pitches - 1 - strikes - _foul_count_for(category, pitches), 0, 3))

	var fouls: int = _foul_count_for(category, pitches)
	var called_strikes: int
	var whiffs: int
	var swings: int
	match category:
		CATEGORY_K:
			whiffs = int(clamp(_deterministic_int(precomp, "k_whiffs", 1, 3), 1, max(1, strikes)))
			called_strikes = max(0, strikes - whiffs)
			swings = whiffs + fouls
		CATEGORY_BB:
			whiffs = int(clamp(_deterministic_int(precomp, "bb_whiffs", 0, 1), 0, max(0, strikes))) if strikes > 0 else 0
			called_strikes = max(0, strikes - whiffs)
			swings = whiffs + fouls
		CATEGORY_HBP:
			whiffs = 0
			called_strikes = strikes
			swings = fouls
		_:  # BIP
			whiffs = int(clamp(_deterministic_int(precomp, "bip_whiffs", 0, 1), 0, max(0, strikes))) if strikes > 0 else 0
			called_strikes = max(0, strikes - whiffs)
			# BIP の最後の球は contact (swing カウント) なので +1
			swings = whiffs + fouls + 1

	var in_zone: int = _deterministic_int(precomp, "in_zone", int(ceil(float(pitches) * 0.38)), int(ceil(float(pitches) * 0.68)))
	in_zone = int(clamp(in_zone, 0, pitches))
	var out_zone: int = pitches - in_zone

	var first_pitch_strike: bool = _deterministic_unit(precomp, "fps") < clamp(0.58 + pit_efficiency * 0.02, 0.30, 0.85)

	return {
		"pitches": pitches,
		"balls": balls,
		"strikes": strikes,
		"final_count": "%d-%d" % [balls, strikes],
		"swings": swings,
		"whiffs": whiffs,
		"called_strikes": called_strikes,
		"fouls": fouls,
		"in_zone_pitches": in_zone,
		"out_zone_pitches": out_zone,
		"first_pitch_strike": first_pitch_strike,
		"csw": whiffs + called_strikes,
	}


static func _pitch_weights_for_category(category: String) -> Array:
	match category:
		CATEGORY_K:
			return K_PITCH_WEIGHTS
		CATEGORY_BB:
			return BB_PITCH_WEIGHTS
		CATEGORY_HBP:
			return HBP_PITCH_WEIGHTS
	return BIP_PITCH_WEIGHTS


static func _roll_base_pitch_count(category: String, precomp: Dictionary) -> int:
	var weights: Array = _pitch_weights_for_category(category)
	var total: float = 0.0
	for value in weights:
		total += max(0.0, float(value))
	if total <= 0.0:
		return _category_min_pitches(category)
	var roll: float = _deterministic_unit(precomp, "pitch_count_dist") * total
	var cumulative: float = 0.0
	for index in range(weights.size()):
		cumulative += max(0.0, float(weights[index]))
		if roll <= cumulative:
			return index + 1
	return min(weights.size(), MAX_PITCH_COUNT)


static func _apply_pitch_delta(
	base_pitches: int,
	pitch_delta: float,
	precomp: Dictionary,
	min_pitches: int,
	max_pitches: int
) -> int:
	var whole: int = int(floor(abs(pitch_delta)))
	var fraction: float = abs(pitch_delta) - float(whole)
	var movement: int = whole
	if _deterministic_unit(precomp, "pitch_delta_fraction") < fraction:
		movement += 1
	if pitch_delta < 0.0:
		movement = -movement
	return int(clamp(base_pitches + movement, min_pitches, max_pitches))


# カテゴリごとに最低限必要な球数。HBP=1, BB=4, K=3, BIP=1。
static func _category_min_pitches(category: String) -> int:
	match category:
		CATEGORY_K:
			return 3
		CATEGORY_BB:
			return 4
		CATEGORY_HBP:
			return 1
	return 1


# シンプルな foul count: 余剰球数の半分程度。
static func _foul_count_for(category: String, pitches: int) -> int:
	var slack: int = 0
	match category:
		CATEGORY_K:
			slack = pitches - 3
		CATEGORY_BB:
			slack = pitches - 4
		CATEGORY_HBP:
			slack = 0
		_:
			slack = pitches - 1
	@warning_ignore("integer_division")
	return int(clamp(slack / 2, 0, 10))


static func _deterministic_unit(precomp: Dictionary, salt: String) -> float:
	# precomp 内に毎回 seed が混ざるよう PA 識別を入れる。Rng は呼ばずに hash で純粋関数化。
	var key: int = hash(salt) ^ hash(precomp.get("event_index", 0)) ^ hash(precomp.get("batter_id", 0)) ^ hash(precomp.get("pitcher_id", 0))
	# 32-bit unsigned 範囲に正規化
	var v: int = int(abs(key) % 1000000)
	return float(v) / 1000000.0


static func _deterministic_int(precomp: Dictionary, salt: String, min_val: int, max_val: int) -> int:
	if max_val <= min_val:
		return min_val
	var unit: float = _deterministic_unit(precomp, salt)
	return min_val + int(unit * float(max_val - min_val + 1))
