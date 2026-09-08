extends RefCounted
class_name PSPlatoonMatchup

# 打者と投手の左右 (プラトーン) の相性を扱う単一ソース。
# 打席シムの能力補正 (PSPlateAppearanceCoordinator) と、AI の起用判断 (スタメン/DH/打順/代打/継投)
# が同じ判定を共有する。
#
# 打者は**同じ利き腕の投手に不利、逆の利き腕に有利**。スイッチヒッターは常に逆の打席へ入るので
# 常に有利側として扱う。投手の利き腕が不明 ("") のときは補正しない。
#
# 補正量は打者ごとに違う。大きさを決めるのは打席左右 (左打者のほうが左右差が大きい) と
# Bat_Platoon (表示名「左右対応」。高いほど左右差が小さい) で、どちらも batter_shift_z に集約する。
# 起用 AI の加減点も同じ倍率で伸縮するので、「左右差の小さい打者は併用されにくい」が自動的に成り立つ。
#
# ⚠️ 投手側には相性能力が無い。対左に極端に強い投手は作れない (打者側のシフトだけで表現している)。

const HAND_RIGHT: String = "R"
const HAND_LEFT: String = "L"
const HAND_SWITCH: String = "S"

# 相手先発が未確定の段階で仮定する利き腕。実際に左と分かった時点で打線を組み直す前提の既定値で、
# NPB の先発の約 8 割が右投げなので外れる試合のほうが少ない (PSGameSimulator が組み直す)。
const DEFAULT_PITCHER_HAND: String = HAND_RIGHT

# 対戦する投手のうち右投げの割合。**MLB 実測 (2018-2025 / 128万打席) では右打者が 0.699 /
# 左打者が 0.766** で、左打者ほど右投手に当たりやすい (相手が左をぶつけてくるため)。
# NPB 2026 は 0.638 / 0.687 とさらに低い。ここでは打者共通の 1 本にして 0.70 を使う。
# 「シーズンを通して見ると左右差がその打者の価値をどちらへ動かすか」の計算に使う。
const RIGHT_HANDED_PITCHER_SHARE: float = 0.70

const ADVANTAGE: float = 1.0
const DISADVANTAGE: float = -1.0
const NEUTRAL: float = 0.0

# --- 打席シムの能力補正 ---
# 打者の質能力 z を σ 単位でどれだけずらすか (有利側 +、不利側 -)。上げるほど左右の当たり外れが
# 大きくなる。**右打者・Bat_Platoon が母集団平均の打者**の値で、実際の量は batter_shift_z が決める。
#
# 名目の OPS 差は 2 × shift × 0.2587 (run_pa_response_surface の打者傾き)。
# **この 0.116 は MLB 実測の右打者の平均スプリット .060 に一致する値**
# (MLB 2018-2025・通算300打席以上の371人)。
#
# ⚠️ **実効はこの 8 割 (.047)。** 名目を上げても出力は飽和する — 0.117 → 0.155 (+33%) で
# 実効は +0.5% しか動かなかった。原因は PA モデルが投打の優位差そのものを tanh で飽和させる
# ところ (`PSBalanceProfile.compress_matchup_advantage`) で、左右差の係数では越えられない。
# **だからここは実効に合わせて水増しせず、現実の値そのものを置く。**
# 不足ぶんは [[project_pa_talent_sensitivity_calibration]] Lv.2 の課題
# (水増しすると Lv.2 の後に強すぎる状態が残る → [[feedback_cap_saturation_pattern]])。
#
# ⚠️ **シフトはテール圧縮の後に足す** (`_build_batter_z_view`)。圧縮の前に足していた頃は
# 実効が 6 割まで落ち、しかも能力の高い打者ほど左右差が小さくなっていた (MLB 実測は逆)。
const ABILITY_SHIFT_Z: float = 0.116
# 左打者の倍率。**MLB 実測の平均スプリット 右 .060 / 左 .096 の比**。
# 左打者のほうが左右差が大きいのは実測でも明確 (リーグ集計でも .045 対 .081)。
const LEFT_BATTER_SHIFT_RATIO: float = 1.59
# Bat_Platoon 1σ あたりシフト量を何割減らすか。**打者間のばらつきの主ノブ。**
# MLB 実測の 打者間 SD / 平均 は**右打者 0.472 / 左打者 0.356**。
# 0.82 は一軍スタメンの Bat_Platoon の SD (0.59σ) との積が右打者の 0.47 になる値で、
# 実測でも打者間の真の SD .035 = MLB の .035 に一致した。
# **0 にすると全打者一律 (2026-08-27〜2026-09-07 の仕様) に戻る。**
const PLATOON_SHIFT_PER_Z: float = 0.82
# 左打者のばらつきだけを縮める係数。左打者は平均が 1.59 倍なのに SD は 1.20 倍しか無い
# (MLB 実測 SD .0284 → .0341) ので、**相対ばらつきは右打者の 0.75 倍**。
# これを入れないと左打者の SD が 3 割ほど広くなる。
const LEFT_BATTER_SPREAD_RATIO: float = 0.75
# ちょうど ABILITY_SHIFT_Z になる Bat_Platoon の z。**一軍スタメンの実測平均**に合わせてある
# (初期ワールド +0.46)。生成側 (OffseasonService.PLATOON_GEN_CENTER = 56 = z+0.48) を同じ値に
# してあるので、世代交代してもリーグ平均の左右差は動かない。
# ※ 母集団全体の平均 (初期データの野手 +0.28) ではない。初期データは Bat_Platoon と打撃の質に
# 相関があり (r=+0.23)、一軍に残る打者だけ高く出るため。生成側にこの相関は無い。
const PLATOON_Z_CENTER: float = 0.48
# 倍率の下限・上限。**MLB の実測分布 (右打者 平均 .060 / SD .028) の ±3σ 相当**に置いてある。
# 下限が負なので、左右対応が極端に高い打者は逆スプリットになる (MLB 実測で右打者の約 1%)。
# 上限を 2.0 にすると MLB に 2% ほど居る「極端に左右差が大きい打者」が作れないので 2.6。
const SHIFT_SCALE_MIN: float = -0.60
const SHIFT_SCALE_MAX: float = 2.60
# 補正をかける打撃能力。run_pa_response_surface の BATTER_LEVEL_KEYS と同じ「質」の 5 本で、
# スタイル軸 (Bat_Spray/Bat_Aggression/Bat_Platoon) は動かさない。
const SHIFT_KEYS: Array[String] = [
	"Bat_Barrel", "Bat_Impact", "Bat_Loft", "Bat_BBCreate", "Bat_KAvoid",
]

# --- AI の起用判断 ---
# 監督が左右をどれだけ重視するかの主ノブ (σ 単位)。上げるほどプラトーン起用が増える。
# 実際の補正量 (ABILITY_SHIFT_Z) より強いのは、起用側が「相性の良い打者を当てにいく」ぶん
# 能力差以上に左右を見るため。ここを 0 にすると左右別の打線は組まれなくなる。
# 打者ごとの加減点は usage_scale_for 倍されるので、左右対応の高い打者は併用されにくくなる。
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


# 打者ごとのシフト量 (σ)。打席左右と Bat_Platoon で決まり、シムも起用 AI もここを見る。
# Bat_Platoon を持たない記録 (テスト用のダミー等) は倍率 1.0 = 母集団平均の打者として扱う。
static func batter_shift_z(record: PSPlayerSeasonRecord, base_shift_z: float = ABILITY_SHIFT_Z) -> float:
	if record == null:
		return base_shift_z
	var base: float = base_shift_z
	if record.batting_side.to_upper() == HAND_LEFT:
		base *= LEFT_BATTER_SHIFT_RATIO
	return base * batter_shift_scale(record)


# 母集団平均の打者を 1.0 とした倍率。起用 AI の加減点もこれで伸縮させる。
static func batter_shift_scale(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 1.0
	var platoon_z: float = record.z_ability("Bat_Platoon", PLATOON_Z_CENTER)
	var spread: float = PLATOON_SHIFT_PER_Z
	if record.batting_side.to_upper() == HAND_LEFT:
		spread *= LEFT_BATTER_SPREAD_RATIO
	return clampf(
		1.0 - spread * (platoon_z - PLATOON_Z_CENTER),
		SHIFT_SCALE_MIN,
		SHIFT_SCALE_MAX
	)


# 打者の z ビューへ相性ぶんのシフトを直接足す (呼び出し側が持つ dictionary を書き換える)。
# ⚠️ **テール圧縮の後に呼ぶ。** 前に呼ぶと名目の 2 割が圧縮に食われ、しかも能力の高い打者ほど
# 左右差が小さくなる (MLB 実測は逆) — 理由は `_build_batter_z_view` のコメント。
static func apply_batter_shift(
	batter_z: Dictionary, record: PSPlayerSeasonRecord, sign: float, base_shift_z: float = ABILITY_SHIFT_Z
) -> void:
	if is_zero_approx(sign):
		return
	var delta: float = sign * batter_shift_z(record, base_shift_z)
	if is_zero_approx(delta):
		return
	for key in SHIFT_KEYS:
		batter_z[key] = float(batter_z.get(key, 0.0)) + delta


# --- 実効スプリット (表示・見積り用) ---
# 能力 1σ あたりの OPS (run_pa_response_surface の打者傾き)。
const OPS_PER_SIGMA: float = 0.2587
# 名目 → 実効 の伝達率 (run_platoon_probe の compression_ratio の実測値)。
# 1 未満なのは、応答曲面の傾き 0.2587/σ が広い δ 帯の回帰値で、動作点近傍の微小シフトに
# 対する実効傾きはそれより少し鈍いため (打席左右別では右 0.75 / 左 0.86)。
# **PA モデルの重み・カーブ・圧縮を触ったら測り直してここを更新する。**
const EFFECTIVE_TRANSFER: float = 0.81


# その打者の 有利側 - 不利側 の OPS 差 (実効の見込み値)。
# 名目 2 × shift × OPS_PER_SIGMA に伝達率を掛けたもので、run_platoon_probe の実測と揃う。
static func expected_split_ops(record: PSPlayerSeasonRecord) -> float:
	return 2.0 * batter_shift_z(record) * OPS_PER_SIGMA * EFFECTIVE_TRANSFER


# シーズンを通した対戦相手の内訳から見た、相性の期待符号 (+ 有利寄り / - 不利寄り)。
# 右打者は約 8 割が同じ利き腕 = 不利側なので負、左打者は逆に正。スイッチは常に有利側なので +1。
static func expected_sign_for(batting_side: String) -> float:
	var side: String = batting_side.to_upper()
	if side == HAND_SWITCH:
		return ADVANTAGE
	if side == HAND_RIGHT:
		return 1.0 - 2.0 * RIGHT_HANDED_PITCHER_SHARE
	if side == HAND_LEFT:
		return 2.0 * RIGHT_HANDED_PITCHER_SHARE - 1.0
	return NEUTRAL


# **左右差がその打者のシーズン通算の打力へ与える期待値 (σ)。** 相手の左右が決まっていない場面
# (スタメン枠の評価・DH 選び・代打の下限判定・査定) はこれを打力へ足す。
# 右打者は左右差が大きいほど損 (対戦の 8 割が不利側)、左打者は逆に得 = 現実で左打者が
# 重宝される理由そのもの。1 試合単位の加減点 (rating_bonus_for) とは役割が違うので両方要る。
static func season_value_shift_z(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	return expected_sign_for(record.batting_side) * batter_shift_z(record)


# 起用判断の加減点に掛ける倍率。母集団平均の右打者が 1.0 で、左打者と左右対応の低い打者ほど大きい。
# シムの補正量と同じ比なので、「実際に左右差の大きい打者ほど強くプラトーン起用される」が保たれる。
static func usage_scale_for(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	return batter_shift_z(record) / ABILITY_SHIFT_Z


# 起用判断のスコアへ足す rating 点。有利なら +、不利なら -。
static func rating_bonus_for(record: PSPlayerSeasonRecord, pitcher_hand: String) -> float:
	if record == null:
		return 0.0
	return sign_for(record.batting_side, pitcher_hand) * RATING_BONUS * usage_scale_for(record)


# 打順評価 (σ 単位の打者指標) へ足す加減点。
static func order_bonus_for(record: PSPlayerSeasonRecord, pitcher_hand: String) -> float:
	if record == null:
		return 0.0
	return sign_for(record.batting_side, pitcher_hand) * MANAGER_SIGMA * usage_scale_for(record)


# これから対戦する打者の並び (打席左右の配列) に対する**投手側**の相性を rating 点で返す。
# 打者側の符号を反転した平均なので、正 = その投手にとって有利な並び。
static func reliever_matchup_bonus(batting_sides: Array, throwing_hand: String) -> float:
	if batting_sides.is_empty() or throwing_hand.is_empty():
		return 0.0
	var total: float = 0.0
	for side_value in batting_sides:
		total += sign_for(str(side_value), throwing_hand)
	return -total / float(batting_sides.size()) * RELIEF_MATCHUP_BONUS
