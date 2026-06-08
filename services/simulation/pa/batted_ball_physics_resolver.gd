extends RefCounted
class_name PSBattedBallPhysicsResolver

# EV (MPH) / LA (deg) / spray (deg) から、distance (m) / hang_time (s) /
# trajectory_bucket / is_barrel / is_hard_hit を確定的に計算する純物理層。
# outcome を見ない pure 関数化が要点。

const HARD_HIT_EXIT_VELOCITY: float = 95.0
const MIN_BARREL_EXIT_VELOCITY: float = 98.0
const METERS_PER_SECOND_PER_MPH: float = 0.44704
const GRAVITY: float = 9.81

const TRAJECTORY_GROUNDER: String = "grounder"
const TRAJECTORY_LINER: String = "liner"
const TRAJECTORY_FLY: String = "fly"
const TRAJECTORY_POPUP: String = "popup"


static func compute(quality: Dictionary) -> Dictionary:
	var ev: float = float(quality.get("exit_velocity", 80.0))
	var la: float = float(quality.get("launch_angle", 10.0))
	var spray: float = float(quality.get("spray_angle", 0.0))
	var carry_multiplier: float = clamp(float(quality.get("carry_multiplier", 1.0)), 0.70, 1.15)

	var trajectory: String = _trajectory(la)
	var distance: float = _distance(ev, la, trajectory) * carry_multiplier
	var hang_time: float = _hang_time(ev, la, distance, trajectory)
	var is_barrel: bool = _is_barrel(ev, la)
	var is_hard_hit: bool = ev >= HARD_HIT_EXIT_VELOCITY

	return {
		"exit_velocity": ev,
		"launch_angle": la,
		"spray_angle": spray,
		"trajectory_bucket": trajectory,
		"distance": _round_float(distance, 1),
		"hang_time": _round_float(hang_time, 2),
		"carry_multiplier": carry_multiplier,
		"is_barrel": is_barrel,
		"is_hard_hit": is_hard_hit,
	}


static func _trajectory(la: float) -> String:
	if la < 10.0:
		return TRAJECTORY_GROUNDER
	if la < 25.0:
		return TRAJECTORY_LINER
	if la <= 50.0:
		return TRAJECTORY_FLY
	return TRAJECTORY_POPUP


static func _distance(ev: float, la: float, trajectory: String) -> float:
	if trajectory == TRAJECTORY_GROUNDER:
		# ゴロは射出公式ではなく転がり近似 (内野〜外野前)
		return clamp(18.0 + (ev - 70.0) * 0.55, 5.0, 85.0)

	var clamped_la: float = clamp(la, 1.0, 55.0)
	var angle_radians: float = deg_to_rad(clamped_la)
	var speed_mps: float = ev * METERS_PER_SECOND_PER_MPH
	var raw_distance: float = speed_mps * speed_mps * sin(2.0 * angle_radians) / GRAVITY
	# air_factor は raw (空気抵抗なし) からの減衰係数。MLB / NPB のフェンス越え距離 (100mph 28° で 120m)
	# に合わせて 0.66 base、EV 100mph 付近で 0.68。
	var air_factor: float = 0.66 + clamp((ev - 90.0) * 0.0030, -0.06, 0.08)
	if trajectory == TRAJECTORY_LINER:
		air_factor += 0.05
	elif trajectory == TRAJECTORY_POPUP:
		air_factor -= 0.22
	return clamp(raw_distance * air_factor, 4.0, 150.0)


static func _hang_time(ev: float, la: float, distance: float, trajectory: String) -> float:
	if trajectory == TRAJECTORY_GROUNDER:
		return clamp(0.55 + distance / 70.0, 0.45, 1.45)
	var speed_mps: float = ev * METERS_PER_SECOND_PER_MPH
	var vertical_speed: float = max(0.0, speed_mps * sin(deg_to_rad(max(0.0, la))))
	var hang_time: float = (2.0 * vertical_speed / GRAVITY) * 0.78
	if trajectory == TRAJECTORY_POPUP:
		hang_time += 0.95
	elif trajectory == TRAJECTORY_LINER:
		hang_time -= 0.35
	return clamp(hang_time, 0.7, 7.5)


static func _is_barrel(ev: float, la: float) -> bool:
	if ev < MIN_BARREL_EXIT_VELOCITY:
		return false
	var extra_velocity: float = ev - MIN_BARREL_EXIT_VELOCITY
	var min_angle: float = max(8.0, 26.0 - extra_velocity * 1.45)
	var max_angle: float = min(50.0, 30.0 + extra_velocity * 2.0)
	return la >= min_angle and la <= max_angle


static func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
