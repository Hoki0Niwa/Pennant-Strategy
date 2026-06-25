extends RefCounted
class_name PSFatigueCalculator

# File 2 §10: 球数ベース疲労モデル。
# 当試合中の球数 (outing_pitches; PSPitcherUsageModel.usage["pitches"] が source) を起点に
# sigmoid((pitches - start_threshold) / width) で fatigue_factor を算出する。
# pitcher.fatigue (累積疲労) は ranking / availability 判定で別途使われる。

# --- 調整係数（旧 simulation_tuning.tres から移設。先発の粘り/疲労落差をここで直接調整する） ---
const ROLE_BASE_PITCH_LIMIT_STARTER: float = 95.0  # 先発が疲労し始める基準球数。
const ROLE_BASE_PITCH_LIMIT_RELIEVER: float = 30.0 # 救援が疲労し始める基準球数。
const STAMINA_SCALE: float = 7.0           # 持久能力1ポイントあたりの基準球数の伸び。
const FATIGUE_BASE_WIDTH: float = 15.0     # 疲労カーブの幅(大きいほど緩やかに悪化)。
const FATIGUE_RESIST_SCALE: float = 4.0    # 持久耐性による疲労カーブ幅の伸び。
const FATIGUE_K_DROP: float = 0.6          # 疲労で奪三振力が落ちる量。
const FATIGUE_CONTROL_DROP: float = 0.4    # 疲労で制球が落ちる量(四球増)。
const FATIGUE_IMPACT_DROP: float = 0.5     # 疲労で打球を抑える力が落ちる量(被安打増)。
const FATIGUE_BARREL_DROP: float = 0.4     # 疲労でバレル(芯食い)抑制が落ちる量(長打増)。
const FATIGUE_LOFT_DROP: float = 0.3       # 疲労で打球角度の抑制が落ちる量。
const FATIGUE_EFFICIENCY_DROP: float = 0.4 # 疲労で球数効率が落ちる量。


# 当該投手の疲労開始球数を返す。Pit_Stamina の正は耐久力 +。
static func start_threshold(pitcher: PSPlayerSeasonRecord, is_reliever: bool) -> float:
	if pitcher == null:
		return ROLE_BASE_PITCH_LIMIT_STARTER
	var role_base: float = ROLE_BASE_PITCH_LIMIT_RELIEVER if is_reliever else ROLE_BASE_PITCH_LIMIT_STARTER
	var stamina: float = pitcher.z_ability("Pit_Stamina", 0.0)
	return role_base + stamina * STAMINA_SCALE


# 疲労ロールオフ幅（球数）。Pit_FatigueResist 大 → 緩やかに減衰。
static func width(pitcher: PSPlayerSeasonRecord) -> float:
	var base_width: float = FATIGUE_BASE_WIDTH
	if pitcher == null:
		return base_width
	var fatigue_resist: float = pitcher.z_ability("Pit_FatigueResist", 0.0)
	return max(1.0, base_width + fatigue_resist * FATIGUE_RESIST_SCALE)


# 1.0 = 完全に元気、0.0 = 完全疲労（飽和）。
# factor = 1.0 - sigmoid((outing_pitches - start) / width)
# outing_pitches に当試合のここまでの球数を渡す。pitcher.fatigue (累積) は使わない。
static func factor_for_pitcher(pitcher: PSPlayerSeasonRecord, is_reliever: bool, outing_pitches: int = 0) -> float:
	if pitcher == null:
		return 1.0
	var start: float = start_threshold(pitcher, is_reliever)
	var w: float = width(pitcher)
	var x: float = (float(outing_pitches) - start) / w
	return clamp(1.0 - PSBalanceProfile.sigmoid(x), 0.0, 1.0)


# 疲労を反映した pitcher_z のコピーを返す（破壊的でない）。
# (1 - fatigue_factor) * FATIGUE_*_DROP を該当 z-key から減算する。
static func apply_drops(pitcher_z: Dictionary, fatigue_factor: float) -> Dictionary:
	var adjusted: Dictionary = pitcher_z.duplicate(true)
	var drop_amount: float = 1.0 - clamp(fatigue_factor, 0.0, 1.0)
	if drop_amount <= 0.0:
		return adjusted
	_drop(adjusted, "Pit_KCreate", drop_amount * FATIGUE_K_DROP)
	_drop(adjusted, "Pit_BBPrevent", drop_amount * FATIGUE_CONTROL_DROP)
	_drop(adjusted, "Pit_ImpactLimit", drop_amount * FATIGUE_IMPACT_DROP)
	_drop(adjusted, "Pit_BarrelDeny", drop_amount * FATIGUE_BARREL_DROP)
	_drop(adjusted, "Pit_LoftControl", drop_amount * FATIGUE_LOFT_DROP)
	_drop(adjusted, "Pit_Efficiency", drop_amount * FATIGUE_EFFICIENCY_DROP)
	return adjusted




static func _drop(target: Dictionary, key: String, delta: float) -> void:
	if not target.has(key):
		return
	target[key] = float(target[key]) - delta
