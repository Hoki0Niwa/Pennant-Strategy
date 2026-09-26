extends RefCounted
class_name PSFatigueCalculator

# 球数ベースの試合内疲労モデル。
# 当試合中の球数 outing_pitches が疲労開始球数を超えるまでは 1.0 (元気)、超えたら疲労限界の球数で
# 0.0 (疲労飽和) になるまで落ちる factor を返す。先発も救援も同じ形で、開始と限界の球数だけが違う。
# pitcher.fatigue の累積値は起用可否側で別途使う。

# 先発/救援の疲労開始点と、疲労時に落とす各 z 能力の調整係数。
const ROLE_BASE_PITCH_LIMIT_STARTER: float = 95.0  # 先発が疲労し始める基準球数。
const ROLE_BASE_PITCH_LIMIT_RELIEVER: float = 25.0 # 救援が疲労し始める球数。1 イニング (15 球前後) では落ちない。
const RELIEVER_FATIGUE_SPAN: float = 40.0          # 救援が疲労し始めてから疲労飽和するまでの球数。
const RELIEVER_FATIGUE_RESIST_SPAN: float = 10.0   # 持久耐性 1σ あたりの上記球数の伸び。
const RELIEVER_FATIGUE_SPAN_MIN: float = 15.0      # 持久耐性がどれだけ低くても、この球数をかけて疲労飽和する。
const FATIGUE_CURVE_POWER: float = 1.55 # 大きいほど疲労限界の直前まで疲労が目立ちにくい。
const FATIGUE_K_DROP: float = 0.6          # 疲労で奪三振力が落ちる量。
const FATIGUE_CONTROL_DROP: float = 0.4    # 疲労で制球が落ちる量(四球増)。
const FATIGUE_IMPACT_DROP: float = 0.5     # 疲労で打球を抑える力が落ちる量(被安打増)。
const FATIGUE_BARREL_DROP: float = 0.4     # 疲労でバレル(芯食い)抑制が落ちる量(長打増)。
const FATIGUE_LOFT_DROP: float = 0.3       # 疲労で打球角度の抑制が落ちる量。
const FATIGUE_EFFICIENCY_DROP: float = 0.4 # 疲労で球数効率が落ちる量。


# 当該投手の疲労開始球数を返す。先発は持久値で変わり、救援は固定球数。
static func start_threshold(pitcher: PSPlayerSeasonRecord, is_reliever: bool) -> float:
	var role_base: float = ROLE_BASE_PITCH_LIMIT_RELIEVER if is_reliever else ROLE_BASE_PITCH_LIMIT_STARTER
	if pitcher == null or is_reliever:
		return role_base
	return float(PSPitcherUsageModel.starter_fatigue_start_pitches(pitcher))


# 救援が疲労飽和する球数。Pit_FatigueResist が高いほど疲労開始からの落ち方が緩やかになる。
static func reliever_limit_pitches(pitcher: PSPlayerSeasonRecord) -> float:
	var span: float = RELIEVER_FATIGUE_SPAN
	if pitcher != null:
		span += pitcher.z_ability("Pit_FatigueResist", 0.0) * RELIEVER_FATIGUE_RESIST_SPAN
	return ROLE_BASE_PITCH_LIMIT_RELIEVER + max(RELIEVER_FATIGUE_SPAN_MIN, span)


# 1.0 = 完全に元気、0.0 = 完全疲労（飽和）。
# outing_pitches に当試合のここまでの球数を渡す。pitcher.fatigue (累積) は使わない。
static func factor_for_pitcher(pitcher: PSPlayerSeasonRecord, is_reliever: bool, outing_pitches: int = 0) -> float:
	if pitcher == null:
		return 1.0
	if not is_reliever:
		return _starter_factor_for_pitcher(pitcher, outing_pitches)
	return _rolloff_factor(ROLE_BASE_PITCH_LIMIT_RELIEVER, reliever_limit_pitches(pitcher), outing_pitches)


# create_outing() が固定した閾値を使い、登板中は球数だけを変えて疲労係数を計算する。
static func factor_for_outing(
	pitcher: PSPlayerSeasonRecord,
	usage: Dictionary,
	outing_pitches: int = -1
) -> float:
	if pitcher == null:
		return 1.0
	if usage.is_empty() or not usage.has("fatigue_start_pitches"):
		var fallback_role: String = str(usage.get("role", PSPitcherUsageModel.ROLE_STARTER))
		var fallback_pitches: int = (
			int(usage.get("pitches", 0))
			if outing_pitches < 0
			else outing_pitches
		)
		return factor_for_pitcher(
			pitcher,
			fallback_role != PSPitcherUsageModel.ROLE_STARTER,
			max(0, fallback_pitches)
		)
	var pitches: int = int(usage.get("pitches", 0)) if outing_pitches < 0 else outing_pitches
	var start: float = float(usage.get("fatigue_start_pitches", 0.0))
	var limit: float = float(usage.get("fatigue_limit_pitches", start + 1.0))
	return _rolloff_factor(start, limit, pitches)


static func _starter_factor_for_pitcher(pitcher: PSPlayerSeasonRecord, outing_pitches: int) -> float:
	var start: float = float(max(1, PSPitcherUsageModel.starter_fatigue_start_pitches(pitcher)))
	var limit: float = float(max(int(start) + 1, PSPitcherUsageModel.starter_stamina_limit_pitches(pitcher)))
	return _rolloff_factor(start, limit, outing_pitches)


# start 球までは 1.0、そこから limit 球で 0.0 になるまで (進み具合)^FATIGUE_CURVE_POWER で落とす。
static func _rolloff_factor(start: float, limit: float, outing_pitches: int) -> float:
	var pitches: float = float(max(0, outing_pitches))
	if pitches <= start:
		return 1.0
	var progress: float = clamp((pitches - start) / max(1.0, limit - start), 0.0, 1.0)
	var drop_amount: float = pow(progress, FATIGUE_CURVE_POWER)
	return clamp(1.0 - drop_amount, 0.0, 1.0)


# 疲労を反映して pitcher_z を書き換える。
# (1 - fatigue_factor) * FATIGUE_*_DROP を該当 z-key から減算する。
# 呼び出し側が打席専用のコピーを所有しているので、追加の Dictionary 複製はしない。
static func apply_drops_in_place(adjusted: Dictionary, fatigue_factor: float) -> void:
	var drop_amount: float = 1.0 - clamp(fatigue_factor, 0.0, 1.0)
	if drop_amount <= 0.0:
		return
	_drop(adjusted, "Pit_KCreate", drop_amount * FATIGUE_K_DROP)
	_drop(adjusted, "Pit_BBPrevent", drop_amount * FATIGUE_CONTROL_DROP)
	_drop(adjusted, "Pit_ImpactLimit", drop_amount * FATIGUE_IMPACT_DROP)
	_drop(adjusted, "Pit_BarrelDeny", drop_amount * FATIGUE_BARREL_DROP)
	_drop(adjusted, "Pit_LoftControl", drop_amount * FATIGUE_LOFT_DROP)
	_drop(adjusted, "Pit_Efficiency", drop_amount * FATIGUE_EFFICIENCY_DROP)




static func _drop(target: Dictionary, key: String, delta: float) -> void:
	if not target.has(key):
		return
	target[key] = float(target[key]) - delta
