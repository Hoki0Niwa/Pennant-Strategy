extends RefCounted
class_name PSPitchTypes

# 変化球(球種)カタログと傾向テーブル。
# 設計方針 (docs/agent_memory 参照):
#  - mastery(完成度) は per-pitch の z スケール (平均0/σ≈1)。投手の10個の Pit_* z は不変・正準のまま。
#  - 球種 type は「傾向(K寄り/ゴロ寄り/被弾)」を *わずかに* 付与するラベル。傾向差は微差 (較正フェーズで強める前提)。
#  - arsenal データ = [{ "type": <String>, "mastery": <float z> }, ...]。ストレート(four_seam)は全投手が必ず1本持つ。

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

# 速球系。このうち FOUR_SEAM(ストレート) は全投手が必ず持ち、ツーシーム/シンカーは
# 「動く速球」として変化球枠から追加で持ちうる (assign_types を参照)。
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


# z 能力から妥当な arsenal を *決定論的* に合成する (derive-on-read と生成の単一ソース)。
# mastery は PSPitcherUsageModel の既存合成 (synth_mastery_values) をそのまま採用するため、
# 役割適性 (starter_depth_rating 等) と値が揃う。type のみ z リーンと player_id ハッシュで割当。
# 注: derive-on-read で繰り返し呼ばれるため Rng を使わず player_id ハッシュで決定論にする。
static func derive_from_z(
	record: PSPlayerSeasonRecord,
	precomputed_masteries: Array = []
) -> Array:
	if record == null:
		return []
	var masteries: Array = (
		precomputed_masteries
		if not precomputed_masteries.is_empty()
		else PSPitcherUsageModel.synth_mastery_values(record)
	)
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


# --- 生成 (実データとしてのアーセナルを作る) ---
# 球種数: 持久(=先発度)が高いほど多い。mastery は stuff 系 z にアンカーし、出し球(0本目)を最良に逓減。
const GENERATED_COUNT_BASE: float = 4.0
const GENERATED_COUNT_STAMINA_WEIGHT: float = 0.7
const GENERATED_COUNT_MIN: int = 3
const GENERATED_COUNT_MAX: int = 6
const GENERATED_TOP_MASTERY_BONUS: float = 0.35
const GENERATED_MASTERY_STEP: float = 0.5
const GENERATED_MASTERY_NOISE: float = 0.9
const MASTERY_MIN: float = -2.0
const MASTERY_MAX: float = 2.8


# z 能力 + seed から arsenal を生成する (ドラフト/外国人/初期シード投手の単一ソース)。
#  - 直球を必ず1本含み、残りは投手リーン(K vs ムーブ)に応じた変化球から割当 (assign_types)。
#  - mastery は stuff 系 z (KCreate/BarrelDeny/EdgeRate) にアンカーしノイズを足す
#    (→ エースは良い球種を持ちやすく z と矛盾しない)。スケールは synth mastery と同じ [-2.0, 2.8]。
# derive_from_z との違い: あちらは z から一意に決まる「派生表示」で個性が無い。こちらは seed_value で
# 球種数・構成・完成度が散るので、**保存される実データ**を作るときはこちらを使う。
# 乱数はローカル RandomNumberGenerator に閉じるため、同じ seed_value なら常に同じアーセナルになる
# (初期シードの読み込み時 backfill が起動ごとにブレないための要件)。
static func generate_arsenal(z_abilities: Dictionary, seed_value: int) -> Array:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(seed_value)
	var k: float = float(z_abilities.get("Pit_KCreate", 0.0))
	var move: float = float(z_abilities.get("Pit_LoftControl", 0.0))
	var barrel_deny: float = float(z_abilities.get("Pit_BarrelDeny", 0.0))
	var edge: float = float(z_abilities.get("Pit_EdgeRate", 0.0))
	var stamina: float = float(z_abilities.get("Pit_Stamina", 0.0))
	var pitch_count: int = clampi(
		int(round(GENERATED_COUNT_BASE + stamina * GENERATED_COUNT_STAMINA_WEIGHT + float(rng.randi_range(-1, 1)))),
		GENERATED_COUNT_MIN,
		GENERATED_COUNT_MAX
	)
	var types: Array = assign_types(pitch_count, k - move, rng.randi_range(0, 1000000))
	var anchor: float = k * 0.5 + barrel_deny * 0.3 + edge * 0.2
	var arsenal: Array = []
	for i in range(pitch_count):
		var noise: float = (rng.randf() - 0.5) * GENERATED_MASTERY_NOISE
		var mastery: float = anchor + GENERATED_TOP_MASTERY_BONUS - float(i) * GENERATED_MASTERY_STEP + noise
		arsenal.append({
			"type": str(types[i]) if i < types.size() else FOUR_SEAM,
			"mastery": clampf(mastery, MASTERY_MIN, MASTERY_MAX),
		})
	return arsenal


# 既存 arsenal に直球(ストレート)が無ければ1本ぶんを直球へ読み替えて返す (本数は変えない)。
# 直球を持たない投手を「全投手が直球を持つ」ルールへ揃えるための正規化。
# 読み替え先は速球系 (シンカー/ツーシーム等) のうち最良のものを優先し、無ければ最良球。
static func ensure_straight(arsenal: Array) -> Array:
	if arsenal == null or arsenal.is_empty():
		return arsenal
	var fastball_index: int = -1
	var best_index: int = -1
	var fastball_mastery: float = -INF
	var best_mastery: float = -INF
	for i in range(arsenal.size()):
		var entry: Dictionary = arsenal[i] as Dictionary
		if entry == null:
			continue
		var type_key: String = str(entry.get("type", ""))
		if type_key == FOUR_SEAM:
			return arsenal
		var mastery: float = float(entry.get("mastery", 0.0))
		if mastery > best_mastery:
			best_mastery = mastery
			best_index = i
		if FASTBALL_TYPES.has(type_key) and mastery > fastball_mastery:
			fastball_mastery = mastery
			fastball_index = i
	var target: int = fastball_index if fastball_index >= 0 else best_index
	if target < 0:
		return arsenal
	var converted: Dictionary = (arsenal[target] as Dictionary).duplicate(true)
	converted["type"] = FOUR_SEAM
	arsenal[target] = converted
	return arsenal


# 球種数・投手リーン・seed_value から、降順 mastery に対応する type 列を返す。
# **直球(ストレート=four_seam)は全投手が必ず1本持つ。** ツーシーム/シンカーは「動く速球」として
# 変化球側の候補に置き、直球の代わりにはしない (実際の投手も直球は全員が持つ球種のため)。
# lean>0: 奪三振タイプ(power)。lean<0: ゴロ/ムーブ系(movement)。derive_from_z と生成の双方が使う。
static func assign_types(count: int, lean: float, seed_value: int) -> Array:
	if count <= 0:
		return []
	var breaking: Array
	if lean >= 0.2:
		breaking = [SLIDER, FORK, CURVE, CUTTER, CHANGEUP, TWO_SEAM]
	elif lean <= -0.2:
		# ゴロ/ムーブ系は動く速球 (ツーシーム/シンカー) を優先候補にして持ち味を残す。
		breaking = [TWO_SEAM, SINKER, CHANGEUP, CURVE, SLIDER, CUTTER]
	else:
		breaking = [SLIDER, CHANGEUP, CURVE, CUTTER, FORK, TWO_SEAM]
	# seed_value で先頭を回転させ、投手ごとに球種構成を散らす。
	var rot: int = seed_value % maxi(1, breaking.size())
	breaking = breaking.slice(rot) + breaking.slice(0, rot)
	# 直球が変化球候補に混じっていたら除く (同じ球種が2本並ぶのを防ぐ保険)。
	var filtered: Array = []
	for t in breaking:
		if t != FOUR_SEAM:
			filtered.append(t)
	breaking = filtered
	# 直球スロット: 最良球は変化球 (決め球) で直球は2番手。球種が1本しかないときだけ直球そのもの。
	var fastball_slot: int = 0 if count == 1 else 1
	var types: Array = []
	var bi: int = 0
	for i in range(count):
		if i == fastball_slot:
			types.append(FOUR_SEAM)
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
