extends RefCounted
class_name PSPitchTypes

# 変化球(球種)カタログと傾向テーブル。
# 設計方針 (docs/agent_memory 参照):
#  - mastery(完成度) は per-pitch の z スケール (平均0/σ≈1)。投手の10個の Pit_* z は不変・正準のまま。
#  - 球種 type は「傾向(K寄り/ゴロ寄り/被弾)」を *わずかに* 付与するラベル。傾向差は微差 (較正フェーズで強める前提)。
#  - arsenal データ = [{ "type": <String>, "mastery": <float z> }, ...]。ストレート(直球)を必ず1本含む。

# --- タクソノミ (NPB 準拠) ---
const FOUR_SEAM: String = "four_seam"
const TWO_SEAM: String = "two_seam"
const SINKER: String = "sinker"
const CUTTER: String = "cutter"
const SLIDER: String = "slider"
const CURVE: String = "curve"
const FORK: String = "fork"
const CHANGEUP: String = "changeup"

const ALL_TYPES: Array[String] = [
	FOUR_SEAM, TWO_SEAM, SINKER, CUTTER, SLIDER, CURVE, FORK, CHANGEUP,
]

# 直球(ストレート)系。最低1本はこのいずれかを持つ。
const FASTBALL_TYPES: Array[String] = [FOUR_SEAM, TWO_SEAM, SINKER]

# UI 表示用の日本語名。
const DISPLAY_NAMES := {
	FOUR_SEAM: "ストレート",
	TWO_SEAM: "ツーシーム",
	SINKER: "シンカー",
	CUTTER: "カットボール",
	SLIDER: "スライダー",
	CURVE: "カーブ",
	FORK: "フォーク",
	CHANGEUP: "チェンジアップ",
}

# 球種ごとの傾向(相対値)。k_bias: 三振寄り, gb_bias: ゴロ寄り(=フライ減), hr_bias: 被弾寄り。
# 値は控えめ。実際にシムへ効く重み (pa_probability_calculator / contact_quality_model 側) も小さく、
# 全体として「微差」に収める。較正フェーズで強める前提。
const TENDENCIES := {
	FOUR_SEAM: {"k_bias": 0.15, "gb_bias": -0.55, "hr_bias": 0.30},
	TWO_SEAM: {"k_bias": -0.10, "gb_bias": 0.60, "hr_bias": -0.20},
	SINKER: {"k_bias": -0.20, "gb_bias": 0.95, "hr_bias": -0.30},
	CUTTER: {"k_bias": 0.20, "gb_bias": 0.10, "hr_bias": -0.10},
	SLIDER: {"k_bias": 0.60, "gb_bias": 0.20, "hr_bias": -0.10},
	CURVE: {"k_bias": 0.35, "gb_bias": 0.30, "hr_bias": -0.10},
	FORK: {"k_bias": 0.55, "gb_bias": 0.50, "hr_bias": -0.20},
	CHANGEUP: {"k_bias": 0.30, "gb_bias": 0.40, "hr_bias": -0.15},
}

# 平均的アーセナル(直球+スライダー+変化球少々)で aggregate がほぼ0になるよう引くベースライン。
# これにより「平均的な球種構成では結果がほぼ変わらない」= 中心化。
# 基準は four_seam+slider+changeup+curve 程度の標準構成 (k がやや+、gb/hr ≈ 0)。
const K_BIAS_BASELINE: float = 0.30
const GB_BIAS_BASELINE: float = 0.0
const HR_BIAS_BASELINE: float = 0.0

# mastery を傾向の加重に使うときの下駄 (mastery が低い球種も少しは投げる)。
const AGGREGATE_MASTERY_FLOOR: float = 1.0


# arsenal を {k_bias, gb_bias, hr_bias} の集計スカラーへ変換する。
# 各球種の傾向を mastery で加重平均し、ベースラインを引いて中心化する。
static func aggregate_biases(arsenal: Array) -> Dictionary:
	var zero: Dictionary = {"k_bias": 0.0, "gb_bias": 0.0, "hr_bias": 0.0}
	if arsenal == null or arsenal.is_empty():
		return zero
	var total_weight: float = 0.0
	var k_sum: float = 0.0
	var gb_sum: float = 0.0
	var hr_sum: float = 0.0
	for entry_value in arsenal:
		var entry: Dictionary = entry_value as Dictionary
		if entry == null:
			continue
		var type_key: String = str(entry.get("type", FOUR_SEAM))
		var tendency: Dictionary = TENDENCIES.get(type_key, TENDENCIES[FOUR_SEAM]) as Dictionary
		var mastery: float = float(entry.get("mastery", 0.0))
		var weight: float = maxf(0.0, mastery + AGGREGATE_MASTERY_FLOOR)
		if weight <= 0.0:
			continue
		total_weight += weight
		k_sum += float(tendency.get("k_bias", 0.0)) * weight
		gb_sum += float(tendency.get("gb_bias", 0.0)) * weight
		hr_sum += float(tendency.get("hr_bias", 0.0)) * weight
	if total_weight <= 0.0:
		return zero
	return {
		"k_bias": k_sum / total_weight - K_BIAS_BASELINE,
		"gb_bias": gb_sum / total_weight - GB_BIAS_BASELINE,
		"hr_bias": hr_sum / total_weight - HR_BIAS_BASELINE,
	}


# z 能力から妥当な arsenal を *決定論的* に合成する (後方互換 derive-on-read と生成の単一ソース)。
# mastery は PSPitcherUsageModel の既存合成 (synth_mastery_values) をそのまま採用するため、
# 役割適性 (starter_depth_rating 等) は従来挙動を保つ。type のみ z リーンと player_id ハッシュで割当。
# 注: derive-on-read で繰り返し呼ばれるため Rng を使わず player_id ハッシュで決定論にする。
static func derive_from_z(record: PSPlayerSeasonRecord) -> Array:
	if record == null:
		return []
	var masteries: Array = PSPitcherUsageModel.synth_mastery_values(record)
	if masteries.is_empty():
		return []
	var sorted_masteries: Array = masteries.duplicate()
	sorted_masteries.sort()
	sorted_masteries.reverse()
	var lean: float = record.z_ability("Pit_KCreate", 0.0) - record.z_ability("Pit_LoftControl", 0.0)
	var seed_value: int = absi(hash(record.player_id))
	var types: Array = assign_types(sorted_masteries.size(), lean, seed_value)
	var arsenal: Array = []
	for i in range(sorted_masteries.size()):
		arsenal.append({
			"type": types[i] if i < types.size() else FOUR_SEAM,
			"mastery": float(sorted_masteries[i]),
		})
	return arsenal


# 球種数・投手リーン・seed_value から、降順 mastery に対応する type 列を返す。直球を必ず1本含む。
# lean>0: 奪三振タイプ(power)。lean<0: ゴロ/ムーブ系(movement)。derive_from_z と生成の双方が使う。
static func assign_types(count: int, lean: float, seed_value: int) -> Array:
	if count <= 0:
		return []
	var fastball: String = SINKER if lean <= -0.45 else FOUR_SEAM
	var breaking: Array
	if lean >= 0.2:
		breaking = [SLIDER, FORK, CURVE, CUTTER, CHANGEUP, TWO_SEAM]
	elif lean <= -0.2:
		breaking = [TWO_SEAM, CHANGEUP, CURVE, SINKER, SLIDER, CUTTER]
	else:
		breaking = [SLIDER, CHANGEUP, CURVE, CUTTER, FORK, TWO_SEAM]
	# seed_value で先頭を回転させ、投手ごとに球種構成を散らす。
	var rot: int = seed_value % maxi(1, breaking.size())
	breaking = breaking.slice(rot) + breaking.slice(0, rot)
	# 直球と重複する候補は除く (シンカー直球のとき breaking のシンカーを除外など)。
	var filtered: Array = []
	for t in breaking:
		if t != fastball:
			filtered.append(t)
	breaking = filtered
	# 直球スロット: ゴロ系投手は最良球が直球(シンカー)、それ以外は最良球は変化球で直球は2番手。
	var fastball_slot: int = 0 if (lean <= -0.2 or count == 1) else 1
	if fastball_slot >= count:
		fastball_slot = 0
	var types: Array = []
	var bi: int = 0
	for i in range(count):
		if i == fastball_slot:
			types.append(fastball)
		else:
			types.append(breaking[bi % breaking.size()] if not breaking.is_empty() else FOUR_SEAM)
			bi += 1
	return types


# 表示名 (未知 type はキーをそのまま返す)。
static func display_name(type_key: String) -> String:
	return str(DISPLAY_NAMES.get(type_key, type_key))


# 完成度(mastery z) を S〜D の5段階へ変換する (UI 表示用)。
# mastery は概ね [-2.0, 2.8]、実戦級閾値は EFFECTIVE_PITCH_Z(=-0.4)。
const MASTERY_GRADE_S_MIN: float = 1.6   # 決め球級 (display ≈70+)
const MASTERY_GRADE_A_MIN: float = 0.8   # 武器になる (display ≈60+)
const MASTERY_GRADE_B_MIN: float = 0.0   # 平均 (display ≈50+)
const MASTERY_GRADE_C_MIN: float = -0.8  # 実戦で使える下限付近 (display ≈40+)。これ未満は D。

static func mastery_grade(mastery: float) -> String:
	if mastery >= MASTERY_GRADE_S_MIN:
		return "S"
	if mastery >= MASTERY_GRADE_A_MIN:
		return "A"
	if mastery >= MASTERY_GRADE_B_MIN:
		return "B"
	if mastery >= MASTERY_GRADE_C_MIN:
		return "C"
	return "D"


# arsenal を「球種名グレード」を mastery 降順に並べた1行文字列にする (例: "フォークS / ストレートA / カーブC")。
# 空なら "" を返す (呼び出し側でフォールバック表示)。
static func arsenal_line(arsenal: Array) -> String:
	if arsenal == null or arsenal.is_empty():
		return ""
	var entries: Array = arsenal.duplicate()
	entries.sort_custom(func(a, b): return float((a as Dictionary).get("mastery", 0.0)) > float((b as Dictionary).get("mastery", 0.0)))
	var parts: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		if entry == null:
			continue
		parts.append("%s%s" % [display_name(str(entry.get("type", ""))), mastery_grade(float(entry.get("mastery", 0.0)))])
	return " / ".join(parts)
