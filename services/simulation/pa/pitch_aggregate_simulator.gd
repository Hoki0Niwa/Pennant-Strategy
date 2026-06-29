extends RefCounted
class_name PSPitchAggregateSimulator

# 打席カテゴリと能力から、球数・ボール/ストライク・空振りなどの集計 PitchSummary を生成する。
# 出力スキーマ:
# {pitches, balls, strikes, final_count, swings, whiffs, called_strikes, fouls,
#  in_zone_pitches, out_zone_pitches, first_pitch_strike, csw}

const CATEGORY_K: String = "k"
const CATEGORY_BB: String = "bb"
const CATEGORY_HBP: String = "hbp"
# 球数生成の調整係数。カテゴリごとの基本球数に、打者/投手/捕手能力と疲労の補正を足し引きする。
# カテゴリ別の基本球数。リーグ平均でおよそ 3.9 球/打席(NPB 実水準)になるよう設定。
const BASE_PITCHES_K: float = 4.9    # 三振で終わる打席の基本球数。
const BASE_PITCHES_BB: float = 5.6   # 四球で終わる打席の基本球数。
const BASE_PITCHES_HBP: float = 3.0  # 死球で終わる打席の基本球数。
const BASE_PITCHES_BIP: float = 3.45 # インプレーで終わる打席の基本球数。
# 球数を増減させる能力係数。
const PATIENCE_COEF: float = 0.4            # 打者の選球眼が球数を増やす係数。
const AGGRESSION_COEF: float = 0.4          # 打者の積極性が球数を減らす係数。
const EFFICIENCY_COEF: float = 0.3          # 投手の効率(省エネ度)が球数を減らす係数。
const GAMECALL_EFFICIENCY_COEF: float = 0.2 # 捕手の配球が球数効率に効く係数。
# 能力 z は集団平均が0とは限らないため、平均的な選手で補正ゼロになる中立点を引いてから係数を適用する。
const PATIENCE_Z_NEUTRAL: float = 0.95   # Bat_BBCreate の野手平均。
const AGGRESSION_Z_NEUTRAL: float = 0.3  # Bat_Aggression の野手平均。
const EFFICIENCY_Z_NEUTRAL: float = 1.0  # Pit_Efficiency の投手平均。
const GAMECALL_Z_NEUTRAL: float = 0.75   # C_GameCall の捕手平均。
const FATIGUE_PITCH_COEF: float = 0.4       # 疲労が球数を増やす係数。
# リーグ一律の球数補正。カテゴリ別 base は neutral 能力で現実的(K4.9/BB5.6/BIP3.45)だが、能力項の
# 中立点(*_Z_NEUTRAL)が「実際に打席に立つ/登板する稼働選手」の母平均をやや下回るため、シーズン平均
# p/PA が約0.27 押し下げられていた(実測 3.62 → 目標 3.85-3.90, MLB/NPB 現代水準)。母平均との差を一律で戻す。
const LEAGUE_PITCH_CALIBRATION: float = 0.27
const PITCH_SIGMA: float = 1.0              # 球数の乱数ばらつき(正規分布の標準偏差)。
const MIN_PITCH_COUNT: int = 1              # 1打席あたり球数の下限クランプ。
const MAX_PITCH_COUNT: int = 14             # 1打席あたり球数の上限クランプ。


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

	var base_pitches: float = _base_pitches_for_category(category)
	var pitches_f: float = base_pitches
	pitches_f += (bat_bb_create - PATIENCE_Z_NEUTRAL) * PATIENCE_COEF
	pitches_f -= (bat_aggression - AGGRESSION_Z_NEUTRAL) * AGGRESSION_COEF
	pitches_f -= (pit_efficiency - EFFICIENCY_Z_NEUTRAL) * EFFICIENCY_COEF
	pitches_f -= (c_game_call - GAMECALL_Z_NEUTRAL) * GAMECALL_EFFICIENCY_COEF
	pitches_f += (1.0 - fatigue_factor) * FATIGUE_PITCH_COEF
	pitches_f += LEAGUE_PITCH_CALIBRATION
	pitches_f += _gauss(precomp) * PITCH_SIGMA

	var min_p: int = max(MIN_PITCH_COUNT, _category_min_pitches(category))
	var max_p: int = MAX_PITCH_COUNT
	var pitches: int = int(clamp(round(pitches_f), float(min_p), float(max_p)))

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


static func _base_pitches_for_category(category: String) -> float:
	match category:
		CATEGORY_K:
			return BASE_PITCHES_K
		CATEGORY_BB:
			return BASE_PITCHES_BB
		CATEGORY_HBP:
			return BASE_PITCHES_HBP
	return BASE_PITCHES_BIP


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
	return int(clamp(slack / 2, 0, 4))


static func _gauss(precomp: Dictionary) -> float:
	# 4 個の deterministic ロールから 0..1 → 中心化して [-2, 2]
	var total: float = 0.0
	for i in range(4):
		total += _deterministic_unit(precomp, "gauss_%d" % i)
	return total - 2.0


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
