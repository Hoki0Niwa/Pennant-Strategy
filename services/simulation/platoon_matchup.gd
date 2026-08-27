extends RefCounted
class_name PSPlatoonMatchup

# 打者と投手の左右 (プラトーン) の相性を扱う単一ソース。
# 打席シムの能力補正 (PSPlateAppearanceCoordinator) と、AI の起用判断 (スタメン/DH/打順/代打/継投)
# が同じ判定を共有する。
#
# 打者は**同じ利き腕の投手に不利、逆の利き腕に有利**。スイッチヒッターは常に逆の打席へ入るので
# 常に有利側として扱う。投手の利き腕が不明 ("") のときは補正しない。
#
# 補正量は全打者で一律で、打者ごとの左右への強さの違い (Bat_Platoon) はまだ持たない。

const HAND_RIGHT: String = "R"
const HAND_LEFT: String = "L"
const HAND_SWITCH: String = "S"

# 相手先発が未確定の段階で仮定する利き腕。実際に左と分かった時点で打線を組み直す前提の既定値で、
# NPB の先発の約 8 割が右投げなので外れる試合のほうが少ない (PSGameSimulator が組み直す)。
const DEFAULT_PITCHER_HAND: String = HAND_RIGHT

const ADVANTAGE: float = 1.0
const DISADVANTAGE: float = -1.0
const NEUTRAL: float = 0.0

# --- 打席シムの能力補正 ---
# 打者の質能力 z を σ 単位でどれだけずらすか (有利側 +、不利側 -)。
# 上げるほど左右の当たり外れが大きくなる。run_pa_response_surface の打者傾き (OPS +0.259/σ) から、
# 有利 - 不利の OPS 差は 2 × この値 × 0.259 ≒ .052。
const ABILITY_SHIFT_Z: float = 0.10
# 補正をかける打撃能力。run_pa_response_surface の BATTER_LEVEL_KEYS と同じ「質」の 5 本で、
# スタイル軸 (Bat_Spray/Bat_Aggression/Bat_Platoon) は動かさない。
const SHIFT_KEYS: Array[String] = [
	"Bat_Barrel", "Bat_Impact", "Bat_Loft", "Bat_BBCreate", "Bat_KAvoid",
]

# --- AI の起用判断 ---
# 監督が左右をどれだけ重視するかの主ノブ (σ 単位)。上げるほどプラトーン起用が増える。
# 実際の補正量 (ABILITY_SHIFT_Z) より強いのは、起用側が「相性の良い打者を当てにいく」ぶん
# 能力差以上に左右を見るため。ここを 0 にすると左右別の打線は組まれなくなる。
const MANAGER_SIGMA: float = 0.25
# 表示能力 1 点あたりの z (PSPlayerValueEvaluator の疲労減点と同じ 1σ = 12.5 点)。
const RATING_POINTS_PER_SIGMA: float = 12.5
# スタメン/DH/代打の比較に足す rating 点。定位置選手との評価差がこの値以内なら、相性の良い控えが
# その日の先発を取る。代打では「今の投手に対してどちらが良い打者か」の比較に同じ値を使う。
const RATING_BONUS: float = MANAGER_SIGMA * RATING_POINTS_PER_SIGMA

# --- 継投 ---
# 次に回ってくる打者に対する投手側の相性が、救援の選抜スコアを動かす幅 (投手の表示能力点)。
# 実際に足すのは「相性の平均符号 × この値」なので、次の打者が全員同じ左右のときだけ満額になり、
# 左右が混ざった並びではほとんど効かない。上げるとワンポイント的な継投が増える。
const RELIEF_MATCHUP_BONUS: float = 12.0
# 相性を見る打者数。実際の継投も「次の 3 人」を基準に考える。
const RELIEF_LOOKAHEAD_BATTERS: int = 3


# 打者の打席左右と投手の利き腕から相性の符号を返す (+1 有利 / -1 不利 / 0 判定不能)。
static func sign_for(batting_side: String, pitcher_hand: String) -> float:
	var hand: String = pitcher_hand.to_upper()
	if hand != HAND_RIGHT and hand != HAND_LEFT:
		return NEUTRAL
	var side: String = batting_side.to_upper()
	if side == HAND_SWITCH:
		return ADVANTAGE
	if side != HAND_RIGHT and side != HAND_LEFT:
		return NEUTRAL
	return DISADVANTAGE if side == hand else ADVANTAGE


static func sign_for_records(
	batter: PSPlayerSeasonRecord, pitcher: PSPlayerSeasonRecord
) -> float:
	if batter == null or pitcher == null:
		return NEUTRAL
	return sign_for(batter.batting_side, pitcher.throwing_hand)


static func has_advantage(batting_side: String, pitcher_hand: String) -> bool:
	return sign_for(batting_side, pitcher_hand) > 0.0


# 打者の z ビューへ相性ぶんのシフトを直接足す (呼び出し側が持つ dictionary を書き換える)。
# テール圧縮より前に呼ぶことで、補正後の能力にも同じ上限が掛かる。
static func apply_batter_shift(batter_z: Dictionary, sign: float, shift_z: float = ABILITY_SHIFT_Z) -> void:
	if is_zero_approx(sign) or is_zero_approx(shift_z):
		return
	var delta: float = sign * shift_z
	for key in SHIFT_KEYS:
		batter_z[key] = float(batter_z.get(key, 0.0)) + delta


# 起用判断のスコアへ足す rating 点。有利なら +、不利なら -。
static func rating_bonus(batting_side: String, pitcher_hand: String) -> float:
	return sign_for(batting_side, pitcher_hand) * RATING_BONUS


static func rating_bonus_for(record: PSPlayerSeasonRecord, pitcher_hand: String) -> float:
	if record == null:
		return 0.0
	return rating_bonus(record.batting_side, pitcher_hand)


# 打順評価 (σ 単位の打者指標) へ足す加減点。
static func order_bonus_for(record: PSPlayerSeasonRecord, pitcher_hand: String) -> float:
	if record == null:
		return 0.0
	return sign_for(record.batting_side, pitcher_hand) * MANAGER_SIGMA


# これから対戦する打者の並び (打席左右の配列) に対する**投手側**の相性を rating 点で返す。
# 打者側の符号を反転した平均なので、正 = その投手にとって有利な並び。
static func reliever_matchup_bonus(batting_sides: Array, throwing_hand: String) -> float:
	if batting_sides.is_empty() or throwing_hand.is_empty():
		return 0.0
	var total: float = 0.0
	for side_value in batting_sides:
		total += sign_for(str(side_value), throwing_hand)
	return -total / float(batting_sides.size()) * RELIEF_MATCHUP_BONUS
