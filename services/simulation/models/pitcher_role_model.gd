extends RefCounted
class_name PSPitcherRoleModel

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

const ROLE_STARTER: String = "starter"
const ROLE_RELIEVER: String = "reliever"

# Role strings are treated as a preference/training signal, not an absolute lock.
const STARTER_ROLE_BIAS: float = 0.55
const RELIEVER_ROLE_BIAS: float = 0.55
const OFF_ROLE_PENALTY: float = -0.25
# 役割未設定 (role="") の能力判定で「先発 >= 中継 + margin」を要求する閾値。生成時のみ効く
# (保存 role がある投手は is_starter_record が role を直に見るため無関係)。正の値ほど中継寄りに生成。
# 実野球は中継ぎの方が多く、二軍の先発過多も避けたいので先発 ~45% 程度に寄せる。
const STARTER_DECISION_MARGIN: float = 0.3


static func is_starter_record(record) -> bool:
	if record == null or not record.is_pitcher():
		return false
	# 保存役割 (role) を正準とする。守備位置適性と同様、能力からの再分類はしない。
	# 変更はキャンプの役割転向 (camp_service が player.role を書き換える) でのみ行う。
	# role 未設定 ("") のときだけ能力比較で初期判定する (生成時の初期 role 決定に使用)。
	match record.role:
		ROLE_STARTER:
			return true
		ROLE_RELIEVER, "closer":
			return false
	return starter_score(record) >= reliever_score(record) + STARTER_DECISION_MARGIN


static func is_starter_player(player) -> bool:
	if player == null or not player.is_pitcher():
		return false
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	return is_starter_record(record)


static func role_for_record(record) -> String:
	return ROLE_STARTER if is_starter_record(record) else ROLE_RELIEVER


static func role_for_player(player) -> String:
	return ROLE_STARTER if is_starter_player(player) else ROLE_RELIEVER


static func starter_score(record) -> float:
	if record == null or not record.is_pitcher():
		return -999999.0
	var arsenal: Dictionary = _role_arsenal_summary(record)
	var depth: float = PSPitcherUsageModel.starter_depth_rating(arsenal)
	var score: float = 0.0
	score += record.z_ability("Pit_Stamina", 0.0) * 1.35
	score += record.z_ability("Pit_FatigueResist", 0.0) * 0.90
	score += record.z_ability("Pit_Efficiency", 0.0) * 0.65
	score += record.z_ability("Pit_BBPrevent", 0.0) * 0.25
	score += depth * 0.90
	score += _role_bias(record.role, ROLE_STARTER)
	return score


static func reliever_score(record) -> float:
	if record == null or not record.is_pitcher():
		return -999999.0
	var arsenal: Dictionary = _role_arsenal_summary(record)
	var finish: float = PSPitcherUsageModel.reliever_finish_rating(arsenal)
	var score: float = 0.0
	score += record.z_ability("Pit_KCreate", 0.0) * 0.75
	score += record.z_ability("Pit_EdgeRate", 0.0) * 0.55
	score += record.z_ability("Pit_FatigueResist", 0.0) * 0.55
	score += record.z_ability("Pit_BBPrevent", 0.0) * 0.15
	score += finish * 0.90
	score -= record.z_ability("Pit_Stamina", 0.0) * 0.25
	score += _role_bias(record.role, ROLE_RELIEVER)
	return score


static func starter_advantage(record) -> float:
	return starter_score(record) - reliever_score(record)


static func reliever_advantage(record) -> float:
	return reliever_score(record) - starter_score(record)


static func starter_order_score(record) -> float:
	if record == null:
		return -999999.0
	return float(PlayerValueEvaluator.pitching_score_without_fatigue(record)) + starter_score(record) * 6.0


static func reliever_order_score(record) -> float:
	if record == null:
		return -999999.0
	return float(PlayerValueEvaluator.pitching_score_without_fatigue(record)) + reliever_score(record) * 5.0


static func _role_bias(role: String, target: String) -> float:
	if target == ROLE_STARTER:
		if role == "starter":
			return STARTER_ROLE_BIAS
		if role == "reliever" or role == "closer":
			return OFF_ROLE_PENALTY
		return 0.0
	if role == "reliever" or role == "closer":
		return RELIEVER_ROLE_BIAS
	if role == "starter":
		return OFF_ROLE_PENALTY
	return 0.0


static func _role_arsenal_summary(record) -> Dictionary:
	var values: Array = []
	if record != null:
		var arsenal_entries: Array = record.arsenal_snapshot if not record.arsenal_snapshot.is_empty() else []
		for entry_value in arsenal_entries:
			var entry: Dictionary = entry_value as Dictionary
			values.append(float(entry.get("mastery", 0.0)))
		if values.is_empty():
			values = _fallback_pitch_values_from_z(record)
	values.sort()
	values.reverse()
	var effective_count: int = 0
	for value in values:
		if float(value) >= PSPitcherUsageModel.EFFECTIVE_PITCH_Z:
			effective_count += 1
	var top_pitch: float = float(values[0]) if values.size() >= 1 else 0.0
	var second_pitch: float = float(values[1]) if values.size() >= 2 else maxf(-1.2, top_pitch - 1.2)
	var third_pitch: float = float(values[2]) if values.size() >= 3 else PSPitcherUsageModel.NO_THIRD_PITCH
	return {
		"pitch_count": values.size(),
		"effective_pitch_count": effective_count,
		"top_pitch": top_pitch,
		"second_pitch": second_pitch,
		"third_pitch": third_pitch,
		"top_two_average": (top_pitch + second_pitch) / 2.0,
		"pitch_values": values,
	}


static func _fallback_pitch_values_from_z(record) -> Array:
	if record == null:
		return []
	var stamina: float = record.z_ability("Pit_Stamina", 0.0)
	var fatigue: float = record.z_ability("Pit_FatigueResist", 0.0)
	var efficiency: float = record.z_ability("Pit_Efficiency", 0.0)
	var k_create: float = record.z_ability("Pit_KCreate", 0.0)
	var edge: float = record.z_ability("Pit_EdgeRate", 0.0)
	var impact: float = record.z_ability("Pit_ImpactLimit", 0.0)
	var barrel: float = record.z_ability("Pit_BarrelDeny", 0.0)
	var command: float = record.z_ability("Pit_BBPrevent", 0.0)
	var depth_signal: float = stamina * 0.46 + fatigue * 0.24 + efficiency * 0.20 + command * 0.10
	var pitch_count: int = clampi(3 + int(round(depth_signal * 0.75)), 2, 6)
	var values: Array = [
		clampf(k_create * 0.42 + edge * 0.18 + impact * 0.16 + barrel * 0.12 + command * 0.12, -2.0, 2.8),
		clampf(impact * 0.30 + barrel * 0.24 + command * 0.18 + k_create * 0.16 + efficiency * 0.12 - 0.16, -2.0, 2.8),
		clampf(command * 0.30 + efficiency * 0.22 + fatigue * 0.18 + impact * 0.18 + stamina * 0.12 - 0.32, -2.0, 2.8),
		clampf(efficiency * 0.26 + command * 0.22 + barrel * 0.18 + fatigue * 0.14 + stamina * 0.10 - 0.54, -2.0, 2.8),
		clampf(command * 0.24 + impact * 0.20 + efficiency * 0.18 + stamina * 0.16 - 0.76, -2.0, 2.8),
		clampf(efficiency * 0.22 + fatigue * 0.20 + command * 0.18 + stamina * 0.18 - 0.98, -2.0, 2.8),
	]
	return values.slice(0, pitch_count)
