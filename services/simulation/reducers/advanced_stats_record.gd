extends RefCounted
class_name PSAdvancedStats

const LEAGUE_WOBA: float = 0.315
const WOBA_SCALE: float = 1.24
const LEAGUE_RUNS_PER_PA: float = 0.115
const POSITION_ADJUSTMENT_FULL_SEASON_OUTS: float = 162.0 * 27.0
const POSITION_ADJUSTMENT_RUNS_PER_162: Dictionary = {
	2: 12.5,
	3: -12.5,
	4: 2.5,
	5: 2.5,
	6: 7.5,
	7: -7.5,
	8: 2.5,
	9: -7.5,
	10: -17.5,
}
# OAA を Statcast Fielding Run Value に近いラン単位へ換算する係数。
const RUN_PER_OUT: float = 0.75
const INFIELD_OAA_RUNS_PER_OUT: float = 0.75
const OUTFIELD_OAA_RUNS_PER_OUT: float = 0.90

var player_id: int = 0
var plate_appearances: int = 0
var woba_denominator: int = 0
var xwoba_denominator: int = 0
var woba_numerator: float = 0.0
var xwoba_numerator: float = 0.0
var re24_sum: float = 0.0
var bsr_sum: float = 0.0
var fielding_chances: int = 0
var fielding_outs: int = 0
var fielding_chances_by_position: Dictionary = {}
var fielding_chances_by_oaa_zone: Dictionary = {}
var fielding_outs_by_position: Dictionary = {}
var fielding_outs_by_oaa_zone: Dictionary = {}
var defensive_outs_by_position: Dictionary = {}
var defensive_outs_by_oaa_zone: Dictionary = {}
var oaa_by_zone: Dictionary = {}
var oaa_by_position: Dictionary = {}
var rngr_by_position: Dictionary = {}
var errr_by_position: Dictionary = {}
var dpr_by_position: Dictionary = {}
var uzr_by_position: Dictionary = {}
var drs_by_position: Dictionary = {}


func load_from_dict(data: Dictionary) -> void:
	player_id = int(data.get("player_id", 0))
	plate_appearances = int(data.get("plate_appearances", 0))
	woba_denominator = int(data.get("woba_denominator", 0))
	xwoba_denominator = int(data.get("xwoba_denominator", 0))
	woba_numerator = float(data.get("woba_numerator", 0.0))
	xwoba_numerator = float(data.get("xwoba_numerator", 0.0))
	re24_sum = float(data.get("re24_sum", data.get("re24", 0.0)))
	bsr_sum = float(data.get("bsr_sum", data.get("bsr", 0.0)))
	fielding_chances = int(data.get("fielding_chances", 0))
	fielding_outs = int(data.get("fielding_outs", 0))
	fielding_chances_by_position = _int_map(data.get("fielding_chances_by_position", {}))
	fielding_chances_by_oaa_zone = _int_map(data.get("fielding_chances_by_oaa_zone", {}))
	fielding_outs_by_position = _int_map(data.get("fielding_outs_by_position", {}))
	fielding_outs_by_oaa_zone = _int_map(data.get("fielding_outs_by_oaa_zone", {}))
	defensive_outs_by_position = _int_map(data.get("defensive_outs_by_position", {}))
	defensive_outs_by_oaa_zone = _int_map(data.get("defensive_outs_by_oaa_zone", {}))
	oaa_by_zone = _float_map(data.get("oaa_by_zone", {}))
	oaa_by_position = _float_map(data.get("oaa_by_position", {}))
	rngr_by_position = _float_map(data.get("rngr_by_position", {}))
	errr_by_position = _float_map(data.get("errr_by_position", {}))
	dpr_by_position = _float_map(data.get("dpr_by_position", {}))
	uzr_by_position = _float_map(data.get("uzr_by_position", {}))
	drs_by_position = _float_map(data.get("drs_by_position", {}))

	if fielding_chances_by_position.is_empty() and fielding_chances > 0 and data.has("uzr"):
		var fallback_position: String = str(int(data.get("primary_uzr_position", data.get("uzr_position", 0))))
		if fallback_position != "0":
			fielding_chances_by_position[fallback_position] = fielding_chances
			rngr_by_position[fallback_position] = float(data.get("rngr", data.get("rngr_sum", 0.0)))
			errr_by_position[fallback_position] = float(data.get("errr", data.get("errr_sum", 0.0)))
			dpr_by_position[fallback_position] = float(data.get("dpr", data.get("dpr_sum", 0.0)))
			uzr_by_position[fallback_position] = float(data.get("uzr", data.get("uzr_sum", 0.0)))
			drs_by_position[fallback_position] = float(data.get("drs", data.get("drs_sum", 0.0)))
	if oaa_by_zone.is_empty() and data.has("oaa"):
		var fallback_oaa_zone: String = str(data.get("primary_oaa_zone", ""))
		if fallback_oaa_zone == "infield" or fallback_oaa_zone == "outfield":
			oaa_by_zone[fallback_oaa_zone] = float(data.get("oaa", data.get("oaa_sum", 0.0)))
			fielding_chances_by_oaa_zone[fallback_oaa_zone] = fielding_chances


func add_plate_result(
	woba_weight: float,
	woba_denominator_delta: int,
	xwoba_weight: float,
	xwoba_denominator_delta: int,
	re24_delta: float
) -> void:
	plate_appearances += 1
	woba_numerator += woba_weight
	woba_denominator += woba_denominator_delta
	xwoba_numerator += xwoba_weight
	xwoba_denominator += xwoba_denominator_delta
	re24_sum += re24_delta


func add_baserunning(value: float) -> void:
	bsr_sum += value


func add_fielding(
	oaa_value: float,
	uzr_value: float,
	drs_value: float,
	rngr_value: float = 0.0,
	errr_value: float = 0.0,
	dpr_value: float = 0.0,
	position: int = 0,
	oaa_zone: String = "",
	fielding_outs_value: int = 0
) -> void:
	fielding_chances += 1
	var credited_outs: int = max(0, fielding_outs_value)
	fielding_outs += credited_outs
	var position_key: String = str(position)
	if position > 0:
		fielding_chances_by_position[position_key] = int(fielding_chances_by_position.get(position_key, 0)) + 1
		if credited_outs > 0:
			fielding_outs_by_position[position_key] = int(fielding_outs_by_position.get(position_key, 0)) + credited_outs
		oaa_by_position[position_key] = float(oaa_by_position.get(position_key, 0.0)) + oaa_value
		rngr_by_position[position_key] = float(rngr_by_position.get(position_key, 0.0)) + rngr_value
		errr_by_position[position_key] = float(errr_by_position.get(position_key, 0.0)) + errr_value
		dpr_by_position[position_key] = float(dpr_by_position.get(position_key, 0.0)) + dpr_value
		uzr_by_position[position_key] = float(uzr_by_position.get(position_key, 0.0)) + uzr_value
		drs_by_position[position_key] = float(drs_by_position.get(position_key, 0.0)) + drs_value
	var zone_key: String = oaa_zone
	if zone_key.is_empty():
		zone_key = _oaa_zone_for_position(position)
	if zone_key == "infield" or zone_key == "outfield":
		fielding_chances_by_oaa_zone[zone_key] = int(fielding_chances_by_oaa_zone.get(zone_key, 0)) + 1
		if credited_outs > 0:
			fielding_outs_by_oaa_zone[zone_key] = int(fielding_outs_by_oaa_zone.get(zone_key, 0)) + credited_outs
		oaa_by_zone[zone_key] = float(oaa_by_zone.get(zone_key, 0.0)) + oaa_value


func add_defensive_outs(position: int, outs: int, oaa_zone: String = "") -> void:
	if position <= 0 or outs <= 0:
		return
	var position_key: String = str(position)
	defensive_outs_by_position[position_key] = int(defensive_outs_by_position.get(position_key, 0)) + outs
	var zone_key: String = oaa_zone
	if zone_key.is_empty():
		zone_key = _oaa_zone_for_position(position)
	if zone_key == "infield" or zone_key == "outfield":
		defensive_outs_by_oaa_zone[zone_key] = int(defensive_outs_by_oaa_zone.get(zone_key, 0)) + outs


func add_from(other) -> void:
	if other == null:
		return
	plate_appearances += other.plate_appearances
	woba_denominator += other.woba_denominator
	xwoba_denominator += other.xwoba_denominator
	woba_numerator += other.woba_numerator
	xwoba_numerator += other.xwoba_numerator
	re24_sum += other.re24_sum
	bsr_sum += other.bsr_sum
	fielding_chances += other.fielding_chances
	fielding_outs += other.fielding_outs
	_merge_int_map(fielding_chances_by_position, other.fielding_chances_by_position)
	_merge_int_map(fielding_chances_by_oaa_zone, other.fielding_chances_by_oaa_zone)
	_merge_int_map(fielding_outs_by_position, other.fielding_outs_by_position)
	_merge_int_map(fielding_outs_by_oaa_zone, other.fielding_outs_by_oaa_zone)
	_merge_int_map(defensive_outs_by_position, other.defensive_outs_by_position)
	_merge_int_map(defensive_outs_by_oaa_zone, other.defensive_outs_by_oaa_zone)
	_merge_float_map(oaa_by_zone, other.oaa_by_zone)
	_merge_float_map(oaa_by_position, other.oaa_by_position)
	_merge_float_map(rngr_by_position, other.rngr_by_position)
	_merge_float_map(errr_by_position, other.errr_by_position)
	_merge_float_map(dpr_by_position, other.dpr_by_position)
	_merge_float_map(uzr_by_position, other.uzr_by_position)
	_merge_float_map(drs_by_position, other.drs_by_position)


func woba() -> float:
	if woba_denominator <= 0:
		return 0.0
	return woba_numerator / float(woba_denominator)


func xwoba() -> float:
	if xwoba_denominator <= 0:
		return 0.0
	return xwoba_numerator / float(xwoba_denominator)


func wraa() -> float:
	if woba_denominator <= 0:
		return 0.0
	return ((woba() - LEAGUE_WOBA) / WOBA_SCALE) * float(woba_denominator)


func wrc_plus() -> float:
	if woba_denominator <= 0 or LEAGUE_RUNS_PER_PA <= 0.0:
		return 0.0
	var runs_per_pa: float = ((woba() - LEAGUE_WOBA) / WOBA_SCALE) + LEAGUE_RUNS_PER_PA
	return runs_per_pa / LEAGUE_RUNS_PER_PA * 100.0


func primary_uzr_position() -> int:
	# 「出場の多い方」= 守備機会 (fielding_chances_by_position) を優先。
	# defensive_outs_by_position は全ポジションに同じ outs が記録されがちで、特に集計時には
	# タイブレイクで position 番号最小 (=1, 投手) が選ばれてしまう問題があるため避ける。
	var source: Dictionary = fielding_chances_by_position if not fielding_chances_by_position.is_empty() else defensive_outs_by_position
	return _primary_position_from_counts(source)


func _primary_position_from_counts(source: Dictionary) -> int:
	var best_position: int = 0
	var best_chances: int = -1
	for key_value in source.keys():
		var position: int = int(str(key_value))
		var chances: int = int(source.get(str(key_value), 0))
		if chances > best_chances or (chances == best_chances and position < best_position):
			best_position = position
			best_chances = chances
	return best_position


func to_dict() -> Dictionary:
	var primary_position: int = primary_uzr_position()
	var position_key: String = str(primary_position)
	var primary_oaa_zone: String = _primary_oaa_zone()
	var oaa_display: float = float(oaa_by_zone.get(primary_oaa_zone, 0.0))
	var rngr_display: float = float(rngr_by_position.get(position_key, 0.0))
	var errr_display: float = float(errr_by_position.get(position_key, 0.0))
	var dpr_display: float = float(dpr_by_position.get(position_key, 0.0))
	var uzr_display: float = rngr_display + errr_display + dpr_display
	var oaa_total: float = float(oaa_by_zone.get("infield", 0.0)) + float(oaa_by_zone.get("outfield", 0.0))
	var oaa_runs: float = _oaa_runs_from_zones(oaa_by_zone)
	var fielding_runs: float = oaa_runs
	var positional_adjustment: float = _position_adjustment_from_outs(defensive_outs_by_position)
	return {
		"player_id": player_id,
		"plate_appearances": plate_appearances,
		"woba_denominator": woba_denominator,
		"xwoba_denominator": xwoba_denominator,
		"woba_numerator": _round_float(woba_numerator, 3),
		"xwoba_numerator": _round_float(xwoba_numerator, 3),
		"woba": _round_float(woba(), 3),
		"xwoba": _round_float(xwoba(), 3),
		"wraa": _round_float(wraa(), 3),
		"wrc_plus": _round_float(wrc_plus(), 1),
		"re24": _round_float(re24_sum, 3),
		"bsr": _round_float(bsr_sum, 3),
		"fielding_chances": fielding_chances,
		"fielding_outs": fielding_outs,
		"fielding_chances_by_position": fielding_chances_by_position.duplicate(true),
		"fielding_chances_by_oaa_zone": fielding_chances_by_oaa_zone.duplicate(true),
		"fielding_outs_by_position": fielding_outs_by_position.duplicate(true),
		"fielding_outs_by_oaa_zone": fielding_outs_by_oaa_zone.duplicate(true),
		"defensive_outs_by_position": defensive_outs_by_position.duplicate(true),
		"defensive_outs_by_oaa_zone": defensive_outs_by_oaa_zone.duplicate(true),
		"primary_uzr_position": primary_position,
		"primary_oaa_zone": primary_oaa_zone,
		"oaa_by_zone": _rounded_float_map(oaa_by_zone, 3),
		"oaa_by_position": _rounded_float_map(oaa_by_position, 3),
		"oaa_infield": _round_float(float(oaa_by_zone.get("infield", 0.0)), 3),
		"oaa_outfield": _round_float(float(oaa_by_zone.get("outfield", 0.0)), 3),
		"oaa": _round_float(oaa_display, 3),
		"oaa_total": _round_float(oaa_total, 3),
		"oaa_runs": _round_float(oaa_runs, 3),
		"rngr_by_position": _rounded_float_map(rngr_by_position, 3),
		"errr_by_position": _rounded_float_map(errr_by_position, 3),
		"dpr_by_position": _rounded_float_map(dpr_by_position, 3),
		"uzr_by_position": _rounded_float_map(uzr_by_position, 3),
		"drs_by_position": _rounded_float_map(drs_by_position, 3),
		"rngr": _round_float(rngr_display, 3),
		"errr": _round_float(errr_display, 3),
		"dpr": _round_float(dpr_display, 3),
		"uzr": _round_float(uzr_display, 3),
		"drs": _round_float(uzr_display, 3),
		"fielding_runs": _round_float(fielding_runs, 3),
		"positional_adjustment_runs": _round_float(positional_adjustment, 3),
		"def_runs": _round_float(fielding_runs + positional_adjustment, 3),
	}


func _primary_oaa_zone() -> String:
	# 「出場の多い方」= 守備機会 (fielding_chances) を優先。
	# defensive_outs は全選手にチーム outs が按分されがちで、特に集計時にゾーン内のポジション数で
	# 大小が決まってしまうため、ボールの飛んだ量を直接表す chances を一次基準にする。
	var source: Dictionary = fielding_chances_by_oaa_zone if not fielding_chances_by_oaa_zone.is_empty() else defensive_outs_by_oaa_zone
	var infield_chances: int = int(source.get("infield", 0))
	var outfield_chances: int = int(source.get("outfield", 0))
	if infield_chances <= 0 and outfield_chances <= 0:
		return ""
	return "outfield" if outfield_chances > infield_chances else "infield"


func _oaa_zone_for_position(position: int) -> String:
	if position >= 3 and position <= 6:
		return "infield"
	if position >= 7 and position <= 9:
		return "outfield"
	return ""


func _int_map(value: Variant) -> Dictionary:
	var source: Dictionary = value as Dictionary
	var result: Dictionary = {}
	for key_value in source.keys():
		result[str(key_value)] = int(source[key_value])
	return result


func _float_map(value: Variant) -> Dictionary:
	var source: Dictionary = value as Dictionary
	var result: Dictionary = {}
	for key_value in source.keys():
		result[str(key_value)] = float(source[key_value])
	return result


func _merge_int_map(target: Dictionary, source: Dictionary) -> void:
	for key_value in source.keys():
		var key: String = str(key_value)
		target[key] = int(target.get(key, 0)) + int(source[key_value])


func _merge_float_map(target: Dictionary, source: Dictionary) -> void:
	for key_value in source.keys():
		var key: String = str(key_value)
		target[key] = float(target.get(key, 0.0)) + float(source[key_value])


func _rounded_float_map(source: Dictionary, digits: int) -> Dictionary:
	var result: Dictionary = {}
	for key_value in source.keys():
		var key: String = str(key_value)
		result[key] = _round_float(float(source[key_value]), digits)
	return result


func _sum_float_map(source: Dictionary) -> float:
	var total: float = 0.0
	for key_value in source.keys():
		total += float(source[key_value])
	return total


func _oaa_runs_from_zones(source: Dictionary) -> float:
	return float(source.get("infield", 0.0)) * INFIELD_OAA_RUNS_PER_OUT \
		+ float(source.get("outfield", 0.0)) * OUTFIELD_OAA_RUNS_PER_OUT


func _position_adjustment_from_outs(source: Dictionary) -> float:
	if POSITION_ADJUSTMENT_FULL_SEASON_OUTS <= 0.0:
		return 0.0
	var adjustment: float = 0.0
	for key_value in source.keys():
		var position: int = int(str(key_value))
		var outs: int = int(source[key_value])
		var full_season_runs: float = float(POSITION_ADJUSTMENT_RUNS_PER_162.get(position, 0.0))
		adjustment += full_season_runs * float(outs) / POSITION_ADJUSTMENT_FULL_SEASON_OUTS
	return adjustment


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
