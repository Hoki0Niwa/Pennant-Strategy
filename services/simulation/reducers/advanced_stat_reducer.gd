extends RefCounted
class_name PSAdvancedStatReducer

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")

# play_event から高度指標の累積 Dictionary を更新する reducer。
# 打席結果は打者/投手の wOBA・xwOBA・RE24、走者イベントは BSR、守備イベントは OAA/UZR/DRS 系へ流す。
# advanced_stats は {"players": {id: dict}, "pitchers": {id: dict}} の形で in-place 更新される。
const BUCKET_PLAYERS: String = "players"
const BUCKET_PITCHERS: String = "pitchers"

const WOBA_WALK: float = 0.690
const WOBA_HBP: float = 0.720
const WOBA_SINGLE: float = 0.880
const WOBA_DOUBLE: float = 1.247
const WOBA_TRIPLE: float = 1.578
const WOBA_HOME_RUN: float = 2.031
const RUNNER_FIELDING_ERROR_OPPORTUNITY_SCALE: float = 0.35
const RUNNER_THROW_ERROR_DEFAULT_OUT_PROBABILITY: float = 0.82
const RUNNER_THROW_ERROR_MIN_OUT_PROBABILITY: float = 0.05
const RUNNER_THROW_ERROR_MAX_OUT_PROBABILITY: float = 0.95

const RE24_TABLE: Dictionary = {
	0: {0: 0.461, 1: 0.831, 2: 1.068, 3: 1.373, 4: 1.277, 5: 1.798, 6: 2.052, 7: 2.282},
	1: {0: 0.243, 1: 0.489, 2: 0.644, 3: 0.908, 4: 0.897, 5: 1.140, 6: 1.352, 7: 1.520},
	2: {0: 0.095, 1: 0.214, 2: 0.305, 3: 0.429, 4: 0.343, 5: 0.471, 6: 0.570, 7: 0.736},
}


# 空の累積コンテナ。保存時は AdvancedStatsRecord.to_dict() の集合として保持する。
static func empty_advanced_stats() -> Dictionary:
	return {
		BUCKET_PLAYERS: {},
		BUCKET_PITCHERS: {},
	}


static func to_dict_container(advanced_stats: Dictionary) -> Dictionary:
	var out: Dictionary = empty_advanced_stats()
	for bucket_name in [BUCKET_PLAYERS, BUCKET_PITCHERS]:
		var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		var out_bucket: Dictionary = {}
		for key_value in bucket.keys():
			var key: String = str(key_value)
			var value = bucket.get(key_value)
			if value is PSAdvancedStats:
				out_bucket[key] = (value as PSAdvancedStats).to_dict()
			elif value is Dictionary:
				out_bucket[key] = (value as Dictionary).duplicate(true)
		out[bucket_name] = out_bucket
	return out


# Dictionary 化済みの高度指標を、選手 ID ごとに加算する。
# target は保存可能な Dictionary のまま維持し、各レコードの加算規則は PSAdvancedStats に集約する。
static func merge_dict_container(target: Dictionary, source: Dictionary) -> void:
	_ensure_shape(target)
	for bucket_name in [BUCKET_PLAYERS, BUCKET_PITCHERS]:
		var target_bucket: Dictionary = target.get(bucket_name, {}) as Dictionary
		var source_bucket: Dictionary = source.get(bucket_name, {}) as Dictionary
		for key_value in source_bucket.keys():
			var key: String = str(key_value)
			var target_record = AdvancedStatsRecord.new()
			var target_value = target_bucket.get(key, null)
			if target_value is PSAdvancedStats:
				target_record.add_from(target_value as PSAdvancedStats)
			elif target_value is Dictionary:
				target_record.load_from_dict(target_value as Dictionary)

			var source_record = AdvancedStatsRecord.new()
			var source_value = source_bucket.get(key_value)
			if source_value is PSAdvancedStats:
				source_record.add_from(source_value as PSAdvancedStats)
				source_record.player_id = (source_value as PSAdvancedStats).player_id
			elif source_value is Dictionary:
				source_record.load_from_dict(source_value as Dictionary)
			if source_record.player_id == 0 and key.is_valid_int():
				source_record.player_id = int(key)
			if target_record.player_id == 0:
				target_record.player_id = source_record.player_id
			target_record.add_from(source_record)
			target_bucket[key] = target_record.to_dict()
		target[bucket_name] = target_bucket


# 1プレー分のイベントを高度指標へ反映する入口。
# plate_event / runner_events / fielding_events / defense_alignment が同じ play_event に同居している前提。
static func apply_play_event(advanced_stats: Dictionary, play_event: Dictionary) -> void:
	if play_event.is_empty():
		return
	_ensure_shape(advanced_stats)
	var plate_event: Dictionary = play_event.get("plate_event", {}) as Dictionary
	if not plate_event.is_empty():
		var batter_id: int = int(plate_event.get("batter_id", 0))
		var pitcher_id: int = int(plate_event.get("pitcher_id", 0))
		var woba_weight: float = _woba_weight(plate_event)
		var denominator_delta: int = _woba_denominator_delta(plate_event)
		var xwoba_weight: float = _xwoba_weight(plate_event, play_event.get("batted_ball_event", {}) as Dictionary)
		var re24_delta: float = re24_for_play(play_event)
		if batter_id != 0:
			var batter_stats = _record_for(advanced_stats, BUCKET_PLAYERS, batter_id)
			batter_stats.add_plate_result(woba_weight, denominator_delta, xwoba_weight, denominator_delta, re24_delta)
			_store_record(advanced_stats, BUCKET_PLAYERS, batter_stats)
		if pitcher_id != 0:
			var pitcher_stats = _record_for(advanced_stats, BUCKET_PITCHERS, pitcher_id)
			pitcher_stats.add_plate_result(woba_weight, denominator_delta, xwoba_weight, denominator_delta, re24_delta)
			_store_record(advanced_stats, BUCKET_PITCHERS, pitcher_stats)

	var runner_events: Array = play_event.get("runner_events", []) as Array
	for runner_event_value in runner_events:
		var runner_event: Dictionary = runner_event_value as Dictionary
		var runner_id: int = int(runner_event.get("runner_id", 0))
		if runner_id != 0:
			var bsr_value: float = _bsr_value(runner_event)
			if not is_zero_approx(bsr_value):
				var runner_stats = _record_for(advanced_stats, BUCKET_PLAYERS, runner_id)
				runner_stats.add_baserunning(bsr_value)
				_store_record(advanced_stats, BUCKET_PLAYERS, runner_stats)
		_apply_runner_fielding_error(advanced_stats, play_event, runner_event)

	_apply_defensive_alignment(advanced_stats, play_event)

	var fielding_events: Array = play_event.get("fielding_events", []) as Array
	for fielding_event_value in fielding_events:
		var fielding_event: Dictionary = fielding_event_value as Dictionary
		var fielder_id: int = int(fielding_event.get("fielder_id", 0))
		if fielder_id == 0:
			continue
		var fielder_stats = _record_for(advanced_stats, BUCKET_PLAYERS, fielder_id)
		fielder_stats.add_fielding(
			float(fielding_event.get("oaa", 0.0)),
			float(fielding_event.get("uzr", 0.0)),
			float(fielding_event.get("drs", 0.0)),
			float(fielding_event.get("rngr", 0.0)),
			float(fielding_event.get("errr", 0.0)),
			float(fielding_event.get("dpr", 0.0)),
			int(fielding_event.get("uzr_position", fielding_event.get("position", 0))),
			str(fielding_event.get("oaa_zone", "")),
			int(fielding_event.get("fielding_outs", 1 if bool(fielding_event.get("actual_out", false)) else 0))
		)
		_store_record(advanced_stats, BUCKET_PLAYERS, fielder_stats)


# RE24 = 得点 + プレイ後の得点期待値 - プレイ前の得点期待値。
# 走者状況は bases 配列を 1/2/3 塁の bit mask に落として RE24_TABLE を参照する。
static func re24_for_play(play_event: Dictionary) -> float:
	var outs_before: int = int(play_event.get("outs_before", 0))
	var outs_after: int = int(play_event.get("outs_after", 0))
	var bases_before: Array = play_event.get("bases_before", []) as Array
	var bases_after: Array = play_event.get("bases_after", []) as Array
	var runs_scored: int = int(play_event.get("runs_scored", 0))
	var before_expectancy: float = _run_expectancy(bases_before, outs_before)
	var after_expectancy: float = 0.0 if outs_after >= 3 else _run_expectancy(bases_after, outs_after)
	return float(runs_scored) + after_expectancy - before_expectancy


# アウトが増えたプレーでは、その時点の守備配置全員に守備イニング(outs)を加算する。
# fielding_events だけでは「守備についていたが打球処理に絡まない選手」の守備機会が残らないため。
static func _apply_defensive_alignment(advanced_stats: Dictionary, play_event: Dictionary) -> void:
	var outs_added: int = int(play_event.get("outs_after", 0)) - int(play_event.get("outs_before", 0))
	if outs_added <= 0:
		return
	var alignment: Array = play_event.get("defense_alignment", []) as Array
	for slot_value in alignment:
		var slot: Dictionary = slot_value as Dictionary
		var player_id: int = int(slot.get("player_id", 0))
		var position: int = int(slot.get("position", 0))
		if player_id == 0 or position <= 0:
			continue
		var fielder_stats = _record_for(advanced_stats, BUCKET_PLAYERS, player_id)
		fielder_stats.add_defensive_outs(position, outs_added, str(slot.get("oaa_zone", "")))
		_store_record(advanced_stats, BUCKET_PLAYERS, fielder_stats)


# 盗塁送球ミスなど runner_event 側にだけ出る失策を守備指標へ変換する。
# 打球失策は fielding_events で処理されるため、ここでは is_fielding_error 付きの走者イベントだけを見る。
static func _apply_runner_fielding_error(advanced_stats: Dictionary, play_event: Dictionary, runner_event: Dictionary) -> void:
	if not bool(runner_event.get("is_fielding_error", false)):
		return
	var position: int = int(runner_event.get("error_position", runner_event.get("fielder_position", 0)))
	if position <= 0:
		return
	var slot: Dictionary = _defensive_slot_for_position(play_event, position)
	var fielder_id: int = int(slot.get("player_id", 0))
	if fielder_id == 0:
		return
	var errr_value: float = _runner_fielding_error_run_value(runner_event)
	if is_zero_approx(errr_value):
		return
	var fielder_stats = _record_for(advanced_stats, BUCKET_PLAYERS, fielder_id)
	fielder_stats.add_fielding(
		0.0,
		errr_value,
		errr_value,
		0.0,
		errr_value,
		0.0,
		position,
		_oaa_zone_for_position(position, str(slot.get("oaa_zone", ""))),
		0
	)
	_store_record(advanced_stats, BUCKET_PLAYERS, fielder_stats)


static func _defensive_slot_for_position(play_event: Dictionary, position: int) -> Dictionary:
	var alignment: Array = play_event.get("defense_alignment", []) as Array
	for slot_value in alignment:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == position:
			return slot
	return {}


# 走者イベント失策の失点価値。刺殺期待が高い送球ミスほど大きく減点する。
# RUNNER_FIELDING_ERROR_OPPORTUNITY_SCALE で、打球失策より軽い機会価値へ抑えている。
static func _runner_fielding_error_run_value(runner_event: Dictionary) -> float:
	var expected_out_probability: float = RUNNER_THROW_ERROR_DEFAULT_OUT_PROBABILITY
	if runner_event.has("throw_out_probability"):
		expected_out_probability = float(runner_event.get("throw_out_probability", expected_out_probability))
	elif runner_event.has("success_probability"):
		expected_out_probability = 1.0 - float(runner_event.get("success_probability", 1.0 - expected_out_probability))
	expected_out_probability = clamp(
		expected_out_probability,
		RUNNER_THROW_ERROR_MIN_OUT_PROBABILITY,
		RUNNER_THROW_ERROR_MAX_OUT_PROBABILITY
	)
	return -expected_out_probability * AdvancedStatsRecord.RUN_PER_OUT * RUNNER_FIELDING_ERROR_OPPORTUNITY_SCALE


static func _oaa_zone_for_position(position: int, slot_zone: String = "") -> String:
	if slot_zone == "infield" or slot_zone == "outfield":
		return slot_zone
	if position >= 3 and position <= 6:
		return "infield"
	if position >= 7 and position <= 9:
		return "outfield"
	return ""


# 打球の EV/LA から簡易 xwOBA を推定する。
# hard/liner/barrel の3要素を合成し、極端なゴロや高すぎるフライは下げる。
static func expected_woba_for_batted_ball(batted_ball_event: Dictionary) -> float:
	var exit_velocity: float = float(batted_ball_event.get("exit_velocity", 0.0))
	var launch_angle: float = float(batted_ball_event.get("launch_angle", 0.0))
	if exit_velocity <= 0.0:
		return 0.0
	var hard_score: float = clamp((exit_velocity - 82.0) / 22.0, 0.0, 1.0)
	var liner_score: float = exp(-pow((launch_angle - 14.0) / 18.0, 2.0))
	var barrel_score: float = clamp((exit_velocity - 95.0) / 16.0, 0.0, 1.0) * exp(-pow((launch_angle - 27.0) / 11.0, 2.0))
	var xwoba: float = 0.070 + hard_score * 0.360 + liner_score * 0.280 + barrel_score * 1.140
	if launch_angle < -10.0:
		xwoba *= 0.72
	elif launch_angle > 50.0:
		xwoba *= 0.42
	return clamp(xwoba, 0.020, 2.100)


static func smoke_test_woba_formula() -> bool:
	var stats: Dictionary = empty_advanced_stats()
	apply_play_event(stats, {
		"outs_before": 0,
		"outs_after": 0,
		"bases_before": [0, 0, 0],
		"bases_after": [10, 0, 0],
		"runs_scored": 0,
		"plate_event": {
			"batter_id": 10,
			"pitcher_id": 20,
			"category": "walk",
			"result": "walk",
			"bases": 0,
		},
		"batted_ball_event": {},
		"runner_events": [],
	})
	stats = to_dict_container(stats)
	var players: Dictionary = stats.get(BUCKET_PLAYERS, {}) as Dictionary
	var batter: Dictionary = players.get("10", {}) as Dictionary
	return is_equal_approx(float(batter.get("woba_numerator", 0.0)), WOBA_WALK) and int(batter.get("woba_denominator", 0)) == 1


static func smoke_test_runner_fielding_error_metrics() -> bool:
	var stats: Dictionary = empty_advanced_stats()
	apply_play_event(stats, {
		"runner_events": [{
			"event_type": "runner_event",
			"runner_id": 101,
			"result": "caught_stealing_throwing_error",
			"is_fielding_error": true,
			"fielding_error_type": "throwing",
			"error_position": 2,
			"success_probability": 0.25,
		}],
		"defense_alignment": [{"player_id": 202, "position": 2, "oaa_zone": "catcher"}],
	})
	apply_play_event(stats, {
		"runner_events": [{
			"event_type": "runner_event",
			"runner_id": 102,
			"result": "advance_on_throw",
			"is_fielding_error": true,
			"fielding_error_type": "throwing",
			"error_position": 9,
			"throw_out_probability": 0.30,
		}],
		"defense_alignment": [{"player_id": 303, "position": 9, "oaa_zone": "outfield"}],
	})
	stats = to_dict_container(stats)
	var players: Dictionary = stats.get(BUCKET_PLAYERS, {}) as Dictionary
	var catcher: Dictionary = players.get("202", {}) as Dictionary
	var right_fielder: Dictionary = players.get("303", {}) as Dictionary
	var catcher_chances: Dictionary = catcher.get("fielding_chances_by_position", {}) as Dictionary
	var rf_chances: Dictionary = right_fielder.get("fielding_chances_by_position", {}) as Dictionary
	var rf_zone_chances: Dictionary = right_fielder.get("fielding_chances_by_oaa_zone", {}) as Dictionary
	return (
		int(catcher.get("fielding_chances", 0)) == 1
		and int(catcher.get("fielding_outs", -1)) == 0
		and int(catcher.get("primary_uzr_position", 0)) == 2
		and int(catcher_chances.get("2", 0)) == 1
		and float(catcher.get("errr", 0.0)) < 0.0
		and is_equal_approx(float(catcher.get("uzr", 0.0)), float(catcher.get("errr", 0.0)))
		and is_equal_approx(float(catcher.get("drs", 0.0)), float(catcher.get("errr", 0.0)))
		and int(right_fielder.get("fielding_chances", 0)) == 1
		and int(right_fielder.get("fielding_outs", -1)) == 0
		and int(right_fielder.get("primary_uzr_position", 0)) == 9
		and int(rf_chances.get("9", 0)) == 1
		and int(rf_zone_chances.get("outfield", 0)) == 1
		and float(right_fielder.get("errr", 0.0)) < 0.0
		and is_equal_approx(float(right_fielder.get("uzr", 0.0)), float(right_fielder.get("errr", 0.0)))
	)


static func _ensure_shape(advanced_stats: Dictionary) -> void:
	if not advanced_stats.has(BUCKET_PLAYERS):
		advanced_stats[BUCKET_PLAYERS] = {}
	if not advanced_stats.has(BUCKET_PITCHERS):
		advanced_stats[BUCKET_PITCHERS] = {}


# 既存 dict から AdvancedStatsRecord を復元し、呼び出し側が加算してから _store_record で戻す。
static func _record_for(advanced_stats: Dictionary, bucket_name: String, player_id: int):
	var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
	var key: String = _player_key(player_id)
	var value = bucket.get(key, null)
	if value is PSAdvancedStats:
		var existing: PSAdvancedStats = value as PSAdvancedStats
		if existing.player_id == 0:
			existing.player_id = player_id
		return existing
	var stats = AdvancedStatsRecord.new()
	if value is Dictionary:
		stats.load_from_dict(value as Dictionary)
	stats.player_id = player_id
	bucket[key] = stats
	advanced_stats[bucket_name] = bucket
	return stats


# AdvancedStatsRecord は試合中だけ object のまま bucket へ戻し、試合終了時にまとめて Dictionary 化する。
static func _store_record(advanced_stats: Dictionary, bucket_name: String, stats) -> void:
	var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
	bucket[_player_key(stats.player_id)] = stats
	advanced_stats[bucket_name] = bucket


static func _player_key(player_id: int) -> String:
	return str(player_id)


# wOBA の分子重み。category を優先し、古い/簡略イベントでは result や bases からフォールバックする。
static func _woba_weight(plate_event: Dictionary) -> float:
	var category: String = str(plate_event.get("category", "out"))
	var result: String = str(plate_event.get("result", "out"))
	var bases: int = int(plate_event.get("bases", 0))
	match category:
		"walk":
			return WOBA_WALK
		"hit_by_pitch":
			return WOBA_HBP
		"hit":
			match bases:
				2:
					return WOBA_DOUBLE
				3:
					return WOBA_TRIPLE
				4:
					return WOBA_HOME_RUN
				_:
					return WOBA_SINGLE
		"error", "fielders_choice":
			return 0.0
		_:
			if result.contains("home_run") or bases >= 4:
				return WOBA_HOME_RUN
			if bases == 3:
				return WOBA_TRIPLE
			if bases == 2:
				return WOBA_DOUBLE
			if bases == 1:
				return WOBA_SINGLE
	return 0.0


# 犠打は wOBA 分母から除外し、それ以外の打席完了イベントは1打席分として数える。
static func _woba_denominator_delta(plate_event: Dictionary) -> int:
	var category: String = str(plate_event.get("category", "out"))
	if category == "sacrifice":
		return 0
	return 1


# xwOBA は打球情報があれば EV/LA 由来、四死球は実 wOBA 重み、それ以外は0として扱う。
static func _xwoba_weight(plate_event: Dictionary, batted_ball_event: Dictionary) -> float:
	var category: String = str(plate_event.get("category", "out"))
	if not batted_ball_event.is_empty():
		return expected_woba_for_batted_ball(batted_ball_event)
	if category == "walk" or category == "hit_by_pitch":
		return _woba_weight(plate_event)
	return 0.0


static func _run_expectancy(bases: Array, outs: int) -> float:
	if outs < 0 or outs > 2:
		return 0.0
	var mask: int = _base_mask(bases)
	var row: Dictionary = RE24_TABLE.get(outs, {}) as Dictionary
	return float(row.get(mask, 0.0))


static func _base_mask(bases: Array) -> int:
	var mask: int = 0
	for index in range(min(3, bases.size())):
		if int(bases[index]) != 0:
			mask |= 1 << index
	return mask


# 走塁イベントの簡易 run value。盗塁/走塁死/暴投進塁などを BSR に加算する。
static func _bsr_value(runner_event: Dictionary) -> float:
	var result: String = str(runner_event.get("result", ""))
	if bool(runner_event.get("is_stolen_base", false)) or result == "stolen_base":
		return 0.20
	if bool(runner_event.get("is_caught_stealing", false)) or result == "caught_stealing":
		return -0.45
	match result:
		"pickoff":
			return -0.35
		"extra_base_on_hit":
			return 0.18
		"advance_on_throw":
			return 0.10
		"tag_up":
			return 0.08
		"sacrifice_advance":
			return 0.04
		"squeeze":
			return 0.12
		"runner_out", "runner_out_advancing":
			return -0.42
		"wild_pitch", "passed_ball", "balk":
			return 0.05
	return 0.0
