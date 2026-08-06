extends RefCounted
class_name PSFatigueCalculator

# 球数ベースの試合内疲労モデル。
# 当試合中の球数 outing_pitches を start_threshold と width に通し、
# 1.0=元気、0.0=疲労飽和の factor を返す。pitcher.fatigue の累積値は起用可否側で別途使う。

# 先発/救援の疲労開始点と、疲労時に落とす各 z 能力の調整係数。
const ROLE_BASE_PITCH_LIMIT_STARTER: float = 95.0  # 先発が疲労し始める基準球数。
const ROLE_BASE_PITCH_LIMIT_RELIEVER: float = 30.0 # 救援が疲労し始める基準球数。
const STARTER_FATIGUE_CURVE_POWER: float = 1.55 # 大きいほどスタミナ限界直前まで疲労が目立ちにくい。
const FATIGUE_BASE_WIDTH: float = 15.0     # 疲労カーブの幅(大きいほど緩やかに悪化)。
const FATIGUE_RESIST_SCALE: float = 4.0    # 持久耐性による疲労カーブ幅の伸び。
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
	if not is_reliever:
		return _starter_factor_for_pitcher(pitcher, outing_pitches)
	var start: float = start_threshold(pitcher, is_reliever)
	var w: float = width(pitcher)
	var x: float = (float(outing_pitches) - start) / w
	return clamp(1.0 - PSBalanceProfile.sigmoid(x), 0.0, 1.0)


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
	var role: String = str(usage.get("role", PSPitcherUsageModel.ROLE_STARTER))
	var start: float = float(usage.get("fatigue_start_pitches", 0.0))
	if role == PSPitcherUsageModel.ROLE_STARTER:
		var limit: float = float(usage.get("fatigue_limit_pitches", start + 1.0))
		return _starter_factor(start, limit, pitches)
	var fatigue_width: float = max(1.0, float(usage.get("fatigue_width", FATIGUE_BASE_WIDTH)))
	var x: float = (float(pitches) - start) / fatigue_width
	return clamp(1.0 - PSBalanceProfile.sigmoid(x), 0.0, 1.0)


static func _starter_factor_for_pitcher(pitcher: PSPlayerSeasonRecord, outing_pitches: int) -> float:
	var start: float = float(max(1, PSPitcherUsageModel.starter_fatigue_start_pitches(pitcher)))
	var limit: float = float(max(int(start) + 1, PSPitcherUsageModel.starter_stamina_limit_pitches(pitcher)))
	return _starter_factor(start, limit, outing_pitches)


static func _starter_factor(start: float, limit: float, outing_pitches: int) -> float:
	var pitches: float = float(max(0, outing_pitches))
	if pitches <= start:
		return 1.0
	var progress: float = clamp((pitches - start) / max(1.0, limit - start), 0.0, 1.0)
	var drop_amount: float = pow(progress, STARTER_FATIGUE_CURVE_POWER)
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
