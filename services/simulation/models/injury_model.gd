extends RefCounted
class_name PSInjuryModel

# 怪我システム。発生判定 → 重症度ティア抽選 → 部位名カタログ選択 → 離脱日数 →
# (まれに) 恒久能力低下、までを担う。可用性ゲート (injury_days > 0) は既存のロスター/打順/
# ローテ/守備/代打が任意日数で参照するため、ここでは日数・種類・重症度・能力を設定するだけ。
#
# バランス係数はすべてこのファイル冒頭の const に置く (外部リソースや調整層は持たない)。
# 設計詳細: docs/agent_memory/project_injury_system.md。

# --- 重症度ティア ---
const TIER_MINOR: int = 0     # 軽傷 (day-to-day, 数日)
const TIER_MODERATE: int = 1  # 中度 (数週間)
const TIER_MAJOR: int = 2     # 重傷 (シーズン終了級)
const TIER_SEVERE: int = 3    # 重大手術 (トミー・ジョン等, シーズン跨ぎ)

const TIER_NAMES := {
	TIER_MINOR: "軽傷",
	TIER_MODERATE: "中度",
	TIER_MAJOR: "重傷",
	TIER_SEVERE: "重大手術",
}

# --- 発生頻度 (tunable) ---
# 1試合(野手スタメン) / 1登板(投手) あたりの基礎発生確率。
# **較正基準は実 NPB の故障者リスト** (集計は docs/agent_memory/project_injury_system.md)。
# 完了したシーズンはオフ時点の形でしか残らないので、**過去4シーズン (2022-2025) のオフ時点に
# 離脱中だった人数 = 投手 4.2人 / 野手 2.7人 per 球団**を正準とする。
# 計測は `tools/run_playing_time_probe.tscn` の `injuries` セクションで、比べる値は
# `season_end_concurrent_15plus_per_team` (軽傷は実データに載らないので 15日以上だけ)。
# 野手はこれに合わせると 15日以上の離脱が年 9件前後 / 30日超が 5件前後 / 一軍戦力野手の
# 30日超が 2.4人前後になる。
# 投手も同じ基準で較正済み (オフ時点に離脱中の投手 1球団 4.2人)。**投手のストックの 6-8 割は
# 手術**で、うち靭帯再建 (トミー・ジョン級) だけで 1球団 1.25-1.67 人を占める — つまり投手側は
# 「件数」より**長期離脱の比率**で決まる。頻度だけ上げても届かないので TIER_WEIGHTS_PITCHER と
# セットで動かすこと。
const BASE_CHANCE_PITCHER: float = 0.0095
const BASE_CHANCE_BATTER: float = 0.0075
# 疲労による上乗せ (fatigue × 係数)。base に対する比率が変わらないよう base と一緒に動かす。
const FATIGUE_MULT_PITCHER: float = 0.00016
const FATIGUE_MULT_BATTER: float = 0.00022
const EXPOSURE_MAX: float = 2.0

# --- ティア抽選の重み (内部で正規化)。大半は軽傷、長期離脱は希少。 ---
# **投手と野手で分ける。** 実 NPB の平均離脱期間は投手が肩 64日 / 肘 59日 と長く、野手は
# 太もも 39.8日 / ひざ 55.5日。野手の故障者リストは「数試合で戻る軽傷」を載せないので、
# 較正は 15日以上の spell だけで行い、軽傷の比率はシム内部の値として置く。
const TIER_WEIGHTS_BATTER := {
	TIER_MINOR: 0.55,
	TIER_MODERATE: 0.28,
	TIER_MAJOR: 0.16,
	TIER_SEVERE: 0.01,
}
# 投手は野手よりさらに長期側へ寄せる。**重大 (トミー・ジョン級) の目標は 1球団 年1件**で、
# オフ時点のストックに 1.25-1.67 人/球団 の靭帯再建術が居る実測から逆算した値
# (手術は 12-18 ヶ月残るので、年1件の発生で 1.4 人前後のストックになる)。
const TIER_WEIGHTS_PITCHER := {
	TIER_MINOR: 0.45,
	TIER_MODERATE: 0.35,
	TIER_MAJOR: 0.145,
	TIER_SEVERE: 0.055,
}

# --- ティア別 離脱日数レンジ [min, max] (tunable) ---
const TIER_DAYS := {
	TIER_MINOR: [3, 15],
	TIER_MODERATE: [15, 45],
	TIER_MAJOR: [50, 150],
	TIER_SEVERE: [270, 540],
}

# --- 恒久能力低下: 発生確率は意図的に非常に低い (軽傷/中度は 0)。較正で調整可。 ---
# 「能力が戻らない」は例外的にまれな結果 (重大手術でも約9割は完全復帰)。
const PERMANENT_LOSS_CHANCE := {
	TIER_MINOR: 0.0,
	TIER_MODERATE: 0.0,
	TIER_MAJOR: 0.03,
	TIER_SEVERE: 0.12,
}
# 当たった場合の z 損失量レンジ [min, max] (該当キーごとに抽選)。
const PERMANENT_Z_LOSS := {
	TIER_MAJOR: [0.10, 0.30],
	TIER_SEVERE: [0.25, 0.55],
}
# arm(投手肘/肩)の恒久損失時は max_velocity も低下 (km/h)。
const VELOCITY_LOSS := {
	TIER_MAJOR: [1, 3],
	TIER_SEVERE: [3, 7],
}
const VELOCITY_FLOOR: float = 120.0
const Z_ABILITY_MIN: float = -4.0
const Z_ABILITY_MAX: float = 4.0

# --- 部位 (region)。恒久損失で劣化する能力グループを決める。 ---
const REGION_ARM: String = "arm"               # 投手の肘/肩
const REGION_LEG: String = "leg"               # 下半身 (走力)
const REGION_HAND: String = "hand"             # 手/手首 (打撃)
const REGION_BACK: String = "back"             # 腰/体幹
const REGION_SHOULDER: String = "throw_shoulder"  # 野手の送球肩 (中度のみ)
const REGION_GENERAL: String = "general"

# --- 部位名カタログ {tier: [{label, region}]} ---
# arm 部位は _decorate_label で投球腕の左右を冠する (例「右肘…」)。
const PITCHER_CATALOG := {
	TIER_MINOR: [
		{"label": "肩の張り", "region": REGION_ARM},
		{"label": "肘の張り", "region": REGION_ARM},
		{"label": "前腕の張り", "region": REGION_ARM},
		{"label": "腰の張り", "region": REGION_BACK},
		{"label": "ふくらはぎの張り", "region": REGION_LEG},
		{"label": "指のマメ", "region": REGION_HAND},
	],
	TIER_MODERATE: [
		{"label": "肩関節炎", "region": REGION_ARM},
		{"label": "肘内側の炎症", "region": REGION_ARM},
		{"label": "腰部捻挫", "region": REGION_BACK},
		{"label": "ハムストリング肉離れ", "region": REGION_LEG},
		{"label": "肋骨の疲労骨折", "region": REGION_BACK},
	],
	TIER_MAJOR: [
		{"label": "肩腱板損傷", "region": REGION_ARM},
		{"label": "肘内側側副靭帯損傷", "region": REGION_ARM},
		{"label": "腰椎椎間板ヘルニア", "region": REGION_BACK},
	],
	TIER_SEVERE: [
		{"label": "肘内側側副靭帯再建術(トミー・ジョン手術)", "region": REGION_ARM},
		{"label": "肩関節唇損傷(手術)", "region": REGION_ARM},
	],
}

const BATTER_CATALOG := {
	TIER_MINOR: [
		{"label": "ハムストリングの張り", "region": REGION_LEG},
		{"label": "腰の張り", "region": REGION_BACK},
		{"label": "手首の打撲", "region": REGION_HAND},
		{"label": "死球による打撲", "region": REGION_HAND},
		{"label": "ふくらはぎの張り", "region": REGION_LEG},
		{"label": "軽度の脳震盪", "region": REGION_GENERAL},
	],
	TIER_MODERATE: [
		{"label": "ハムストリング肉離れ", "region": REGION_LEG},
		{"label": "腹斜筋の肉離れ", "region": REGION_BACK},
		{"label": "手首の捻挫", "region": REGION_HAND},
		{"label": "足首の捻挫", "region": REGION_LEG},
		{"label": "送球肩の関節炎", "region": REGION_SHOULDER},
	],
	TIER_MAJOR: [
		{"label": "有鈎骨骨折", "region": REGION_HAND},
		{"label": "腰椎椎間板ヘルニア", "region": REGION_BACK},
		{"label": "膝半月板損傷", "region": REGION_LEG},
		{"label": "手首靭帯損傷(TFCC)", "region": REGION_HAND},
	],
	TIER_SEVERE: [
		{"label": "前十字靭帯断裂", "region": REGION_LEG},
		{"label": "アキレス腱断裂", "region": REGION_LEG},
		{"label": "膝蓋腱断裂", "region": REGION_LEG},
	],
}


# 発生判定の本体。発生しなければ {} を返す。発生したら怪我情報の Dictionary を返す
# (呼び出し元は戻り値を無視してよい。smoke / 将来の通知用)。
static func maybe_injure(record: PSPlayerSeasonRecord, is_pitcher: bool, exposure: float = 1.0) -> Dictionary:
	if record == null or record.injury_days > 0:
		return {}
	var base_chance: float = BASE_CHANCE_PITCHER if is_pitcher else BASE_CHANCE_BATTER
	var fatigue_mult: float = FATIGUE_MULT_PITCHER if is_pitcher else FATIGUE_MULT_BATTER
	var fatigue_chance: float = float(record.fatigue) * fatigue_mult
	var exposure_scale: float = clampf(exposure, 0.0, EXPOSURE_MAX)
	if Rng.roll_float() >= (base_chance + fatigue_chance) * exposure_scale:
		return {}
	return apply_injury(record, is_pitcher, _roll_tier(is_pitcher))


# 指定ティアの怪我を record に適用する (smoke からも直接呼べるよう public)。
static func apply_injury(record: PSPlayerSeasonRecord, is_pitcher: bool, tier: int) -> Dictionary:
	var days: int = _roll_days(tier)
	var entry: Dictionary = _pick_catalog_entry(is_pitcher, tier)
	var region: String = str(entry.get("region", REGION_GENERAL))
	var label: String = _decorate_label(str(entry.get("label", "故障")), region, record.throwing_hand)

	record.injury_days = days
	record.injury_return_day = 0
	record.season_injury_days += days
	record.injury_type = label
	record.injury_severity = tier

	var permanent: Dictionary = _maybe_apply_permanent_loss(record, is_pitcher, tier, region)
	return {
		"tier": tier,
		"tier_name": tier_name(tier),
		"days": days,
		"label": label,
		"region": region,
		"permanent": permanent,
	}


static func _roll_tier(is_pitcher: bool) -> int:
	var weights: Dictionary = TIER_WEIGHTS_PITCHER if is_pitcher else TIER_WEIGHTS_BATTER
	var total: float = 0.0
	for w in weights.values():
		total += float(w)
	var r: float = Rng.roll_float() * total
	var acc: float = 0.0
	for tier in [TIER_MINOR, TIER_MODERATE, TIER_MAJOR, TIER_SEVERE]:
		acc += float(weights[tier])
		if r < acc:
			return tier
	return TIER_MINOR


static func _roll_days(tier: int) -> int:
	var span: Array = TIER_DAYS.get(tier, [3, 15]) as Array
	return Rng.range_int(int(span[0]), int(span[1]))


static func _pick_catalog_entry(is_pitcher: bool, tier: int) -> Dictionary:
	var catalog: Dictionary = PITCHER_CATALOG if is_pitcher else BATTER_CATALOG
	var entries: Array = catalog.get(tier, []) as Array
	if entries.is_empty():
		return {"label": "故障", "region": REGION_GENERAL}
	return entries[Rng.range_int(0, entries.size() - 1)] as Dictionary


# arm(投球腕)の怪我には左右を冠する。それ以外はそのまま。
static func _decorate_label(base: String, region: String, throwing_hand: String) -> String:
	if region == REGION_ARM:
		var side: String = "左" if throwing_hand == "L" else "右"
		return side + base
	return base


# 恒久能力低下を確率判定し、当たれば z (および arm 投手は球速) を持続 player と当季 record 両方から減算。
# 発生時点で確定適用するため、リハビリ中の pending 状態管理が不要。
static func _maybe_apply_permanent_loss(record: PSPlayerSeasonRecord, is_pitcher: bool, tier: int, region: String) -> Dictionary:
	var chance: float = float(PERMANENT_LOSS_CHANCE.get(tier, 0.0))
	if chance <= 0.0 or Rng.roll_float() >= chance:
		return {}
	var loss_span: Array = PERMANENT_Z_LOSS.get(tier, []) as Array
	if loss_span.is_empty():
		return {}
	var player: PSPlayer = GameDb.players_by_id.get(record.player_id) as PSPlayer
	var applied: Dictionary = {}
	for key_value in affected_keys(region, is_pitcher):
		var key: String = str(key_value)
		var amount: float = _rand_range(float(loss_span[0]), float(loss_span[1]))
		if _reduce_z(record, player, key, amount):
			applied[key] = -amount
	var velocity_drop: int = 0
	if region == REGION_ARM and is_pitcher:
		var v_span: Array = VELOCITY_LOSS.get(tier, []) as Array
		if not v_span.is_empty():
			velocity_drop = Rng.range_int(int(v_span[0]), int(v_span[1]))
			_reduce_velocity(record, player, float(velocity_drop))
	return {"keys": applied, "velocity_drop": velocity_drop}


# 部位 → 劣化させる z 能力キー群。役割で打撃系/投球系を出し分ける。
static func affected_keys(region: String, is_pitcher: bool) -> Array:
	match region:
		REGION_ARM:
			return ["Pit_KCreate", "Pit_BarrelDeny", "Pit_BBPrevent", "Pit_ImpactLimit"] if is_pitcher else ["Bat_Impact", "Bat_Barrel"]
		REGION_LEG:
			return ["Pit_Stamina"] if is_pitcher else ["Run_Speed", "Run_Steal", "Run_Judgment"]
		REGION_HAND:
			return ["Pit_KCreate"] if is_pitcher else ["Bat_Impact", "Bat_Barrel", "Bat_Loft"]
		REGION_BACK:
			return ["Pit_Stamina", "Pit_KCreate"] if is_pitcher else ["Bat_Impact", "Bat_Barrel"]
		_:
			return ["Pit_KCreate"] if is_pitcher else ["Bat_Impact"]


# 既存キーのみ減算する (役割不一致のキーを新設しない)。減算したら true。
static func _reduce_z(record: PSPlayerSeasonRecord, player: PSPlayer, key: String, amount: float) -> bool:
	var touched: bool = false
	if player != null and player.z_abilities.has(key):
		player.z_abilities[key] = clampf(float(player.z_abilities[key]) - amount, Z_ABILITY_MIN, Z_ABILITY_MAX)
		touched = true
	if record.z_abilities_snapshot.has(key):
		record.z_abilities_snapshot[key] = clampf(float(record.z_abilities_snapshot[key]) - amount, Z_ABILITY_MIN, Z_ABILITY_MAX)
		touched = true
	return touched


static func _reduce_velocity(record: PSPlayerSeasonRecord, player: PSPlayer, drop_kmh: float) -> void:
	if player != null and player.raw_abilities.has("max_velocity"):
		player.raw_abilities["max_velocity"] = maxf(VELOCITY_FLOOR, float(player.raw_abilities["max_velocity"]) - drop_kmh)
	if record.raw_abilities_snapshot.has("max_velocity"):
		record.raw_abilities_snapshot["max_velocity"] = maxf(VELOCITY_FLOOR, float(record.raw_abilities_snapshot["max_velocity"]) - drop_kmh)


static func _rand_range(lo: float, hi: float) -> float:
	return lo + Rng.roll_float() * (hi - lo)


static func tier_name(severity: int) -> String:
	return str(TIER_NAMES.get(severity, "軽傷"))


# UI 表示ラベル "部位名(重症度)"。健康(injury_days<=0)なら空文字。
static func display_label(injury_type: String, injury_severity: int, injury_days: int) -> String:
	if injury_days <= 0:
		return ""
	var type_label: String = injury_type if not injury_type.is_empty() else "故障"
	return "%s(%s)" % [type_label, tier_name(injury_severity)]
