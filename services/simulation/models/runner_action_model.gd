extends RefCounted
class_name PSRunnerActionModel


const EVENT_TYPE_RUNNER_EVENT: String = "runner_event"
const EVENT_TYPE_RUNNER_INTENT: String = "runner_intent"

const VISIBILITY_OBSCURED_BY_BATTED_BALL: String = "obscured_by_batted_ball"
const VISIBILITY_VISIBLE: String = "visible_after_plate_result"

const CATEGORY_WALK: String = "walk"
const CATEGORY_HIT_BY_PITCH: String = "hit_by_pitch"
const CATEGORY_STRIKEOUT: String = "strikeout"
const CATCHER_METRIC_CACHE_KEY: String = "_runner_catcher_metric_cache"

# 成功した単独盗塁の一部で捕手送球が逸れ、走者が1つ余分に進む(記録は盗塁+捕手失策 E2)。
# 刺殺(caught_stealing)は常に刺殺として記録される(刺殺企図を失策でセーフに変換する処理はない)。
# error_position=2 を持つイベントは game_loop.credit_runner_event_errors が拾って捕手の errors に計上する。
const STEAL_THROW_ERROR_EXTRA_BASE: float = 0.045   # 成功盗塁あたり、捕手送球が逸れて+1進塁(盗塁+E2)になる基礎率
const STEAL_THROW_ERROR_ARM_WEIGHT: float = 0.008   # 捕手肩(steal_control) raw z 1σ あたりの減少
const STEAL_THROW_ERROR_MIN: float = 0.005
const STEAL_THROW_ERROR_MAX: float = 0.10
# 単独盗塁の企図確率スケール。最終球繰延べのうちBIP/四死球分は記録に残らない。
# 重盗を実勢比まで減らした分も単独盗塁で補い、リーグ企図数(NPB ~1100/季)を保つ。
const STEAL_INTENT_PROBABILITY_SCALE: float = 0.68
# エンドランは単独盗塁と別ノブにする。打球化した分は公式企図に残らないため、
# runner_in_motion 件数と三振球企図を合わせて頻度を調整する。
const HIT_AND_RUN_PROBABILITY_SCALE: float = 0.15
# 重盗は専用スケールで独立調整する。企図イベントの1〜3%(数プレー/球団/季)が目安。
const DOUBLE_STEAL_PROBABILITY_SCALE: float = 0.035
const STEAL_SUCCESS_BASE: float = 0.592
const STEAL_THIRD_SUCCESS_BONUS: float = 0.050
const BALK_PROBABILITY_BASE: float = 0.00215
const BALK_PROBABILITY_MAX: float = 0.002
# 企図が打席の最終球と重なる近似割合。記録に残る三振球企図が総企図の6〜9%になるよう調整する。
# 最終球企図は打席結果まで繰延べられ、
# 三振なら三振後にSB/CS解決、打球なら runner_in_motion へ変換、四死球なら企図を解除する。
const STEAL_FINAL_PITCH_RATIO: float = 0.42
const RUNNER_IN_MOTION_HIT_EXTRA_BASE: float = 0.62
const RUNNER_IN_MOTION_STEAL_EXTRA_BASE: float = 0.42
const RUNNER_IN_MOTION_DP_BREAK_HIT_AND_RUN: float = 0.72
const RUNNER_IN_MOTION_DP_BREAK_STEAL: float = 0.58
const BATTERY_MISPLAY_MAX_PITCHES: int = 8
const WILD_PITCH_PER_PITCH_BASE: float = 0.0158953
const WILD_PITCH_CONTROL_WEIGHT: float = 0.0026
const WILD_PITCH_STUFF_WEIGHT: float = 0.0009
const WILD_PITCH_BLOCKING_WEIGHT: float = 0.0009
const WILD_PITCH_GAME_CALL_WEIGHT: float = 0.0004
const WILD_PITCH_PER_PITCH_MIN: float = 0.0015
const WILD_PITCH_PER_PITCH_MAX: float = 0.030
const PASSED_BALL_PER_PITCH_BASE: float = 0.0071825
const PASSED_BALL_BLOCKING_WEIGHT: float = 0.0025
const PASSED_BALL_PER_PITCH_MIN: float = 0.00015
const PASSED_BALL_PER_PITCH_MAX: float = 0.008


# 後方互換の薄いラッパー。events のみを返す(繰延べ企図は捨てられる)。呼び出し側は
# pre_plate_runner_plan を使うこと(deferred_steal_intents を打席結果まで持ち越すため)。
static func pre_plate_runner_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	context: Dictionary = {}
) -> Array:
	var plan: Dictionary = pre_plate_runner_plan(event_index, batter, pitcher, defense, bases, outs, context)
	return plan.get("events", []) as Array


# 投球前フェーズの走者イベント計画。events は即時適用する投球前イベント(牽制/ボーク/途中決行の盗塁)、
# deferred_steal_intents は最終球扱いで打席結果まで繰延べる盗塁企図。
static func pre_plate_runner_plan(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	context: Dictionary = {}
) -> Dictionary:
	if outs >= 3:
		return {"events": [], "deferred_steal_intents": []}
	var material: Array = _pickoff_or_balk_events(event_index, batter, pitcher, defense, bases, context)
	if not material.is_empty():
		return {"events": _sort_lead_runner_first(material), "deferred_steal_intents": []}
	var plan: Dictionary = _steal_plan(event_index, batter, pitcher, defense, bases, outs, context)
	return {
		"events": _sort_lead_runner_first(plan.get("events", []) as Array),
		"deferred_steal_intents": plan.get("deferred", []) as Array,
	}


# 表示用(play_event_builder が試合ログ生成に呼ぶ)。hit_and_run を含む企図一覧を返すが、
# 実際の盗塁企図の解決(成功/失敗の抽選)は pre_plate_runner_events / _pre_plate_steal_events 側で行う。
static func runner_intents_for_play(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	outcome: Dictionary,
	context: Dictionary = {}
) -> Array:
	var is_batted_ball: bool = _is_batted_ball_outcome(outcome)
	var intents: Array = []
	var used_runner_ids: Dictionary = {}

	var double_steal: Array = _double_steal_intents(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not double_steal.is_empty():
		for intent_value in double_steal:
			var intent: Dictionary = intent_value as Dictionary
			used_runner_ids[int(intent.get("runner_id", 0))] = true
			intents.append(intent)

	var hit_and_run: Dictionary = _hit_and_run_intent(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not hit_and_run.is_empty() and not used_runner_ids.has(int(hit_and_run.get("runner_id", 0))):
		used_runner_ids[int(hit_and_run.get("runner_id", 0))] = true
		intents.append(hit_and_run)

	for base_index in range(0, 2):
		var runner: PSPlayerSeasonRecord = bases_before[base_index] as PSPlayerSeasonRecord
		if runner == null or used_runner_ids.has(runner.player_id):
			continue
		if base_index + 1 < bases_before.size() and bases_before[base_index + 1] != null:
			continue
		var strategy: String = "delayed_steal" if base_index == 0 and _should_try_delayed_steal(event_index, runner, pitcher, defense, context) else "straight_steal"
		var intent: Dictionary = _steal_intent(
			event_index,
			base_index + 1,
			base_index + 2,
			runner,
			batter,
			pitcher,
			defense,
			outs_before,
			is_batted_ball,
			strategy
		)
		if not intent.is_empty():
			intents.append(intent)
	return intents


static func runner_events_for_play(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outs_before: int,
	outs_after_plate: int,
	outcome: Dictionary,
	context: Dictionary = {}
) -> Array:
	var is_batted_ball: bool = _is_batted_ball_outcome(outcome)
	var events: Array = []

	if is_batted_ball:
		var planned_runner_events: Array = outcome.get("runner_events", []) as Array
		if outcome.has("runner_advancements") or not planned_runner_events.is_empty():
			events.append_array(planned_runner_events)
			return _sort_lead_runner_first(events)
		events.append_array(_already_applied_advancement_events(
			event_index,
			batter,
			pitcher,
			defense,
			bases_before,
			bases_after_plate,
			outcome
		))
		if outs_after_plate < 3:
			events.append_array(_batted_ball_extra_base_events(
				event_index,
				batter,
				pitcher,
				defense,
				bases_before,
				bases_after_plate,
				outs_before,
				outs_after_plate,
				outcome
			))
		return _sort_lead_runner_first(events)

	if outs_after_plate >= 3:
		return []

	var category: String = str(outcome.get("category", "out"))
	if category == CATEGORY_STRIKEOUT:
		var deferred: Array = context.get("deferred_steal_intents", []) as Array
		if not deferred.is_empty():
			# 三振では塁状態が変わらないので bases_after_plate をそのまま渡してよい。
			events.append_array(_deferred_steal_events_after_strikeout(event_index, deferred, pitcher, defense, bases_after_plate))

	if events.is_empty():
		events.append_array(_battery_misplay_events(
			event_index,
			batter,
			pitcher,
			defense,
			bases_before,
			bases_after_plate,
			outcome
		))

	if events.is_empty():
		var indifference: Dictionary = _defensive_indifference_event(
			event_index,
			batter,
			pitcher,
			defense,
			bases_after_plate,
			context
		)
		if not indifference.is_empty():
			events.append(indifference)

	return _sort_lead_runner_first(events)


static func _pickoff_or_balk_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	context: Dictionary
) -> Array:
	var runner_entry: Dictionary = _pickoff_target(bases)
	if runner_entry.is_empty():
		return []
	var runner: PSPlayerSeasonRecord = runner_entry.get("runner", null) as PSPlayerSeasonRecord
	var from_base: int = int(runner_entry.get("base", 0))
	if runner == null or from_base <= 0:
		return []

	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var runner_speed: float = _ability(runner, "Run_Speed")
	var runner_stealing: float = _ability(runner, "Run_Steal")
	var control: float = _ability(pitcher, "Pit_BBPrevent")
	# 走者の脅威 z（走力と盗塁技術の平均）。投手の牽制 z が脅威を上回るほど牽制死がわずかに増える。
	var threat: float = (runner_speed + runner_stealing) * 0.5
	var pickoff_out_probability: float = clamp((hold_runners - threat) * 0.0015 + 0.002025, 0.0, 0.006)
	# 制球 z・牽制 z が低い投手ほどボークしやすい。raw z に重みを掛け畳み込み済みベース定数へ足す
	# (中立点・母平均の概念なし)。
	var balk_probability: float = clamp(BALK_PROBABILITY_BASE - control * 0.000625 - hold_runners * 0.000375, 0.0, BALK_PROBABILITY_MAX)
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if pitcher == null else pitcher.player_id,
		from_base,
		_hash_string(str(context.get("half", ""))),
		1103,
	])
	if roll < balk_probability:
		return _balk_events(event_index, batter, pitcher, defense, bases)
	if roll < balk_probability + pickoff_out_probability:
		return [_runner_event(
			"before_pitch",
			"pickoff",
			"pickoff",
			runner,
			batter,
			pitcher,
			defense,
			from_base,
			from_base,
			false,
			1
		)]
	return []


static func _balk_events(
	_event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array
) -> Array:
	var events: Array = []
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		events.append(_runner_event(
			"before_pitch",
			"balk",
			"balk",
			runner,
			batter,
			pitcher,
			defense,
			base_index + 1,
			base_index + 2,
			false,
			0
		))
	return events


static func _double_steal_intents(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	is_batted_ball: bool
) -> Array:
	if bases_before.size() < 3 or bases_before[0] == null or bases_before[1] == null or bases_before[2] != null:
		return []
	var runner_first: PSPlayerSeasonRecord = bases_before[0] as PSPlayerSeasonRecord
	var runner_second: PSPlayerSeasonRecord = bases_before[1] as PSPlayerSeasonRecord
	var catcher_arm: float = _catcher_steal_control(defense)
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	# スコア(z): 各走者の盗塁技術+走力で加点、投手牽制と捕手肩で減点。
	var score: float = (
		(_ability(runner_first, "Run_Steal") + _ability(runner_first, "Run_Speed")) * 0.24
		+ (_ability(runner_second, "Run_Steal") + _ability(runner_second, "Run_Speed")) * 0.34
		- catcher_arm * 0.34
		- hold_runners * 0.24
	)
	if outs_before == 2:
		score += 0.24
	# raw z に重みを掛け、畳み込み済みベース定数へ足して確率を決める(中立点・母平均の概念なし)。
	var probability: float = clamp(0.084875 + score * 0.075, 0.0, 0.260)
	probability = clamp(probability * DOUBLE_STEAL_PROBABILITY_SCALE, 0.0, 0.42)
	var roll: float = _deterministic_unit([
		event_index,
		runner_first.player_id,
		runner_second.player_id,
		0 if pitcher == null else pitcher.player_id,
		2203,
	])
	if roll >= probability:
		return []
	var group_id: String = "ds_%d_%d_%d" % [event_index, runner_second.player_id, runner_first.player_id]
	return [
		_make_intent(event_index, 2, 3, runner_second, batter, pitcher, defense, score, probability, is_batted_ball, "double_steal", group_id),
		_make_intent(event_index, 1, 2, runner_first, batter, pitcher, defense, score, probability, is_batted_ball, "double_steal", group_id),
	]


static func _hit_and_run_intent(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	is_batted_ball: bool
) -> Dictionary:
	if outs_before >= 2 or bases_before.is_empty() or bases_before[0] == null:
		return {}
	if bases_before.size() > 1 and bases_before[1] != null:
		return {}
	var runner: PSPlayerSeasonRecord = bases_before[0] as PSPlayerSeasonRecord
	var contact: float = _ability(batter, "Bat_Barrel")
	var avoid_k: float = _ability(batter, "Bat_KAvoid")
	var power: float = _ability(batter, "Bat_Impact")
	var runner_speed: float = _ability(runner, "Run_Speed")
	# スコア(z): 芯・三振回避・走者走力で加点、長打力で減点（強打者はエンドランしにくい）。
	var score: float = contact * 0.35 + avoid_k * 0.35 + runner_speed * 0.20 - power * 0.18
	# raw z に重みを掛け、畳み込み済みベース定数へ足して確率を決める(中立点・母平均の概念なし)。
	var probability: float = clamp(0.0197 + score * 0.05, 0.0, 0.150)
	probability = clamp(probability * HIT_AND_RUN_PROBABILITY_SCALE, 0.0, 0.27)
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if batter == null else batter.player_id,
		3307,
	])
	if roll >= probability:
		return {}
	return _make_intent(event_index, 1, 2, runner, batter, pitcher, defense, score, probability, is_batted_ball, "hit_and_run", "")


static func _should_try_delayed_steal(
	event_index: int,
	runner: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	context: Dictionary
) -> bool:
	var catcher_arm: float = _catcher_steal_control(defense)
	# スコア(z): 走力・盗塁技術で加点、投手牽制・捕手肩で減点。
	var score: float = (
		_ability(runner, "Run_Speed") * 0.45
		+ _ability(runner, "Run_Steal") * 0.35
		- _ability(pitcher, "Pit_HoldRunner") * 0.25
		- catcher_arm * 0.40
	)
	# raw z に重みを掛け、畳み込み済みベース定数へ足して確率を決める(中立点・母平均の概念なし)。
	var probability: float = clamp(-0.0013875 + score * 0.0375, 0.0, 0.120)
	probability = clamp(probability * STEAL_INTENT_PROBABILITY_SCALE, 0.0, 0.20)
	return _deterministic_unit([event_index, runner.player_id, catcher_arm, _hash_string(str(context.get("half", ""))), 4409]) < probability


static func _steal_intent(
	event_index: int,
	from_base: int,
	to_base: int,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	outs_before: int,
	is_batted_ball: bool,
	strategy: String
) -> Dictionary:
	var stealing: float = _ability(runner, "Run_Steal")
	var speed: float = _ability(runner, "Run_Speed")
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var catcher_arm: float = _catcher_steal_control(defense)
	var batter_power: float = _ability(batter, "Bat_Impact")
	# スコア(z): 盗塁技術・走力で加点、投手牽制・捕手肩で減点。
	var score: float = (
		stealing * 0.55
		+ speed * 0.45
		- hold_runners * 0.35
		- catcher_arm * 0.30
	)
	if outs_before == 2:
		score += 0.32
	if from_base == 2:
		# 三盗は二盗より決行条件を厳しくする。この抑制は成功判定には混ざらない。
		score -= 1.00
	if strategy == "delayed_steal":
		score -= 0.40
	if batter_power >= 2.0:
		score -= 0.40
	# raw z に重みを掛け、畳み込み済みベース定数へ足して確率を決める(中立点・母平均の概念なし)。
	var probability: float = clamp(0.087125 + score * 0.125, 0.0, 0.560)
	probability = clamp(probability * STEAL_INTENT_PROBABILITY_SCALE, 0.0, 0.72)
	var roll: float = _deterministic_unit([
		event_index,
		from_base,
		runner.player_id,
		0 if batter == null else batter.player_id,
		0 if pitcher == null else pitcher.player_id,
		_hash_string(strategy),
	])
	if roll >= probability:
		return {}
	return _make_intent(event_index, from_base, to_base, runner, batter, pitcher, defense, score, probability, is_batted_ball, strategy, "")


static func _make_intent(
	_event_index: int,
	from_base: int,
	to_base: int,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	score: float,
	probability: float,
	is_batted_ball: bool,
	strategy: String,
	group_id: String
) -> Dictionary:
	return {
		"event_type": EVENT_TYPE_RUNNER_INTENT,
		"intent_type": "steal" if strategy != "hit_and_run" else "hit_and_run",
		"strategy": strategy,
		"group_id": group_id,
		"phase": "on_pitch",
		"runner_id": runner.player_id,
		"batter_id": 0 if batter == null else batter.player_id,
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"catcher_id": _catcher_id(defense),
		"from_base": from_base,
		"to_base": to_base,
		"intent_score": round(score * 100.0) / 100.0,
		# 成功判定は企図判断の状況補正(アウト数・打者パワー・三盗抑制等)と分離する。
		"success_skill_score": round((_ability(runner, "Run_Steal") * 0.55 + _ability(runner, "Run_Speed") * 0.45) * 100.0) / 100.0,
		"attempt_probability": round(probability * 10000.0) / 10000.0,
		"visibility": VISIBILITY_OBSCURED_BY_BATTED_BALL if is_batted_ball else VISIBILITY_VISIBLE,
		"recorded_as_attempt": false,
		"obscured_by_batted_ball": is_batted_ball,
		"stage": 5,
	}


# 実行対象の走者作戦を収集する。重盗→エンドラン→単独/ディレード盗塁の順で
# 同じ走者を排他する。エンドランも表示用 intent だけでなくこの実行計画に入る。
static func _run_intents_for_execution(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	is_batted_ball: bool,
	context: Dictionary
) -> Array:
	var intents: Array = []
	var used_runner_ids: Dictionary = {}

	var double_steal: Array = _double_steal_intents(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not double_steal.is_empty():
		for intent_value in double_steal:
			var intent: Dictionary = intent_value as Dictionary
			used_runner_ids[int(intent.get("runner_id", 0))] = true
			intents.append(intent)

	var hit_and_run: Dictionary = _hit_and_run_intent(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not hit_and_run.is_empty() and not used_runner_ids.has(int(hit_and_run.get("runner_id", 0))):
		used_runner_ids[int(hit_and_run.get("runner_id", 0))] = true
		intents.append(hit_and_run)

	for base_index in range(0, 2):
		var runner: PSPlayerSeasonRecord = bases_before[base_index] as PSPlayerSeasonRecord
		if runner == null or used_runner_ids.has(runner.player_id):
			continue
		if base_index + 1 < bases_before.size() and bases_before[base_index + 1] != null:
			continue
		var strategy: String = "delayed_steal" if base_index == 0 and _should_try_delayed_steal(event_index, runner, pitcher, defense, context) else "straight_steal"
		var intent: Dictionary = _steal_intent(
			event_index,
			base_index + 1,
			base_index + 2,
			runner,
			batter,
			pitcher,
			defense,
			outs_before,
			is_batted_ball,
			strategy
		)
		if not intent.is_empty():
			intents.append(intent)
	return intents


# 盗塁類(ダブルスチール・ディレード・ストレート)とエンドランを投球前に計画する。
# 盗塁は STEAL_FINAL_PITCH_RATIO で途中決行と最終球を分け、重盗はグループ単位で同じ側へ振る。
# エンドランは必ず打者のスイング球と同時なので deferred へ積む。
# ダブルスチールで片方が刺されたらもう片方は stolen_base でなく advance_on_double_steal_caught
# として記録する(_apply_double_steal_caught_conversion で共通処理)。
static func _steal_plan(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	context: Dictionary
) -> Dictionary:
	var intents: Array = _run_intents_for_execution(event_index, batter, pitcher, defense, bases, outs, false, context)
	if intents.is_empty():
		return {"events": [], "deferred": []}
	var events: Array = []
	var deferred: Array = []
	var group_deferred: Dictionary = {}
	for intent_value in intents:
		var intent: Dictionary = intent_value as Dictionary
		var group_id: String = str(intent.get("group_id", ""))
		var is_deferred: bool
		if str(intent.get("strategy", "")) == "hit_and_run":
			# エンドランは打者がスイングする投球と同時にスタートするため必ず打席結果まで持ち越す。
			is_deferred = true
		elif not group_id.is_empty() and group_deferred.has(group_id):
			is_deferred = bool(group_deferred[group_id])
		else:
			# group の場合はグループ先頭(リード走者、intents 内で最初に登場する塁の走者)の
			# runner_id で1回だけロールし、グループ全員を同じ側に振り分ける。
			var timing_roll: float = _deterministic_unit([event_index, int(intent.get("runner_id", 0)), 7717])
			is_deferred = timing_roll < STEAL_FINAL_PITCH_RATIO
			if not group_id.is_empty():
				group_deferred[group_id] = is_deferred
		if is_deferred:
			deferred.append(intent)
		else:
			events.append(_runner_event_from_intent(event_index, intent, pitcher, defense, bases, "before_pitch"))
	events = _apply_double_steal_caught_conversion(events)
	return {"events": events, "deferred": deferred}


# 最終球で走者がスタートした打席がインプレーになった場合の補正。
# これは公式記録上の盗塁企図ではないため SB/CS には計上せず、併殺回避と安打時の追加進塁にだけ反映する。
static func apply_runner_in_motion_to_outcome(
	event_index: int,
	outcome: Dictionary,
	deferred_intents: Array,
	bases_before: Array,
	outs_before: int
) -> Dictionary:
	if deferred_intents.is_empty() or not _is_batted_ball_outcome(outcome):
		return outcome
	var result: Dictionary = outcome.duplicate(true)
	var motion_intents: Array = []
	for intent_value in deferred_intents:
		var intent: Dictionary = intent_value as Dictionary
		if str(intent.get("intent_type", "")) in ["steal", "hit_and_run"]:
			motion_intents.append(intent)
	if motion_intents.is_empty():
		return result

	result["runner_in_motion"] = true
	result["runner_in_motion_intents"] = motion_intents.duplicate(true)
	var trajectory: String = str((result.get("physical_traits", {}) as Dictionary).get("trajectory_bucket", ""))
	var category: String = str(result.get("category", ""))
	var lead_intent: Dictionary = motion_intents[0] as Dictionary
	var lead_from_base: int = int(lead_intent.get("from_base", 0))

	# 一塁走者がスタート済みの内野ゴロでは、二塁送球より一塁の打者走者を取るプレーが増える。
	if trajectory == "grounder" and lead_from_base == 1 and outs_before < 2 and category in ["double_play", "fielders_choice"]:
		var force_at_second: bool = category == "double_play" or int(result.get("force_out_to_base", 0)) == 2
		if force_at_second:
			var strategy: String = str(lead_intent.get("strategy", "straight_steal"))
			var break_probability: float = RUNNER_IN_MOTION_DP_BREAK_HIT_AND_RUN if strategy == "hit_and_run" else RUNNER_IN_MOTION_DP_BREAK_STEAL
			var runner: PSPlayerSeasonRecord = _runner_for_intent(bases_before, lead_intent)
			if runner != null:
				break_probability = clamp(break_probability + _ability(runner, "Run_Speed") * 0.035, 0.25, 0.90)
			if _deterministic_unit([event_index, int(lead_intent.get("runner_id", 0)), 8811]) < break_probability:
				result["category"] = "out"
				result["result"] = "groundout_runner_in_motion"
				result["bases"] = 0
				result["runner_advancements"] = [_motion_advancement(lead_intent, bases_before, 2)]
				result["runner_events"] = []
				result["double_play_avoided_by_runner_motion"] = true
				result["runner_motion_break_probability"] = break_probability
				category = "out"

	if category == "hit":
		_apply_motion_hit_advancements(event_index, result, motion_intents, bases_before)
	elif trajectory == "grounder" and category == "out":
		_ensure_motion_groundout_advancements(result, motion_intents, bases_before)

	var marker_events: Array = result.get("runner_events", []) as Array
	for intent_value in motion_intents:
		var intent: Dictionary = intent_value as Dictionary
		marker_events.append(_runner_in_motion_marker(intent, result))
	result["runner_events"] = marker_events
	return result


static func _apply_motion_hit_advancements(
	event_index: int,
	outcome: Dictionary,
	motion_intents: Array,
	bases_before: Array
) -> void:
	var advancements: Array = outcome.get("runner_advancements", []) as Array
	if advancements.is_empty():
		return
	# 先の塁の走者から処理し、同じ塁への衝突を避ける。
	var sorted_intents: Array = motion_intents.duplicate()
	sorted_intents.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("from_base", 0)) > int(b.get("from_base", 0)))
	for intent_value in sorted_intents:
		var intent: Dictionary = intent_value as Dictionary
		var runner_id: int = int(intent.get("runner_id", 0))
		for advancement_value in advancements:
			var advancement: Dictionary = advancement_value as Dictionary
			if int(advancement.get("runner_id", 0)) != runner_id or bool(advancement.get("is_out", false)):
				continue
			var current_to: int = int(advancement.get("to_base", 0))
			var extra_to: int = current_to + 1
			if current_to >= 4 or _advancement_target_occupied(advancements, extra_to, runner_id):
				break
			var runner: PSPlayerSeasonRecord = _runner_for_intent(bases_before, intent)
			var strategy: String = str(intent.get("strategy", "straight_steal"))
			var probability: float = RUNNER_IN_MOTION_HIT_EXTRA_BASE if strategy == "hit_and_run" else RUNNER_IN_MOTION_STEAL_EXTRA_BASE
			if runner != null:
				probability += _ability(runner, "Run_Speed") * 0.035 + _ability(runner, "Run_Judgment") * 0.020
			probability = clamp(probability, 0.12, 0.86)
			advancement["runner_in_motion"] = true
			advancement["runner_motion_extra_probability"] = probability
			if _deterministic_unit([event_index, runner_id, current_to, 8821]) < probability:
				advancement["to_base"] = extra_to
				advancement["is_extra"] = true
				advancement["runner_motion_extra_base"] = true
			break
	outcome["runner_advancements"] = advancements


static func _ensure_motion_groundout_advancements(outcome: Dictionary, motion_intents: Array, bases_before: Array) -> void:
	var advancements: Array = outcome.get("runner_advancements", []) as Array
	for intent_value in motion_intents:
		var intent: Dictionary = intent_value as Dictionary
		var from_base: int = int(intent.get("from_base", 0))
		if from_base < 1 or from_base >= 3:
			continue
		var runner_id: int = int(intent.get("runner_id", 0))
		var found: bool = false
		for advancement_value in advancements:
			if int((advancement_value as Dictionary).get("runner_id", 0)) == runner_id:
				found = true
				break
		if not found:
			advancements.append(_motion_advancement(intent, bases_before, from_base + 1))
	outcome["runner_advancements"] = advancements


static func _motion_advancement(intent: Dictionary, bases_before: Array, to_base: int) -> Dictionary:
	var runner: PSPlayerSeasonRecord = _runner_for_intent(bases_before, intent)
	return {
		"runner": runner,
		"runner_id": int(intent.get("runner_id", 0)),
		"from_base": int(intent.get("from_base", 0)),
		"to_base": to_base,
		"baseline_to": int(intent.get("from_base", 0)),
		"is_out": false,
		"is_extra": true,
		"runner_in_motion": true,
	}


static func _advancement_target_occupied(advancements: Array, target: int, ignored_runner_id: int) -> bool:
	if target >= 4:
		return false
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		if int(advancement.get("runner_id", 0)) == ignored_runner_id or bool(advancement.get("is_out", false)):
			continue
		if int(advancement.get("to_base", 0)) == target:
			return true
	return false


static func _runner_for_intent(bases_before: Array, intent: Dictionary) -> PSPlayerSeasonRecord:
	var from_base: int = int(intent.get("from_base", 0))
	var runner_id: int = int(intent.get("runner_id", 0))
	if from_base >= 1 and from_base <= bases_before.size():
		var direct: PSPlayerSeasonRecord = bases_before[from_base - 1] as PSPlayerSeasonRecord
		if direct != null and direct.player_id == runner_id:
			return direct
	for base_value in bases_before:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		if runner != null and runner.player_id == runner_id:
			return runner
	return null


static func _runner_in_motion_marker(intent: Dictionary, outcome: Dictionary) -> Dictionary:
	var to_base: int = int(intent.get("from_base", 0))
	for advancement_value in outcome.get("runner_advancements", []) as Array:
		var advancement: Dictionary = advancement_value as Dictionary
		if int(advancement.get("runner_id", 0)) == int(intent.get("runner_id", 0)):
			to_base = int(advancement.get("to_base", to_base))
			break
	return {
		"event_type": EVENT_TYPE_RUNNER_EVENT,
		"phase": "after_batted_ball",
		"strategy": str(intent.get("strategy", "straight_steal")),
		"result": "runner_in_motion_batted_ball",
		"runner_id": int(intent.get("runner_id", 0)),
		"batter_id": int(intent.get("batter_id", 0)),
		"from_base": int(intent.get("from_base", 0)),
		"to_base": to_base,
		"is_steal_attempt": false,
		"is_stolen_base": false,
		"is_caught_stealing": false,
		"recorded_as_attempt": false,
		"state_already_applied": true,
		"outs_added": 0,
		"runner_in_motion": true,
		"double_play_avoided_by_runner_motion": bool(outcome.get("double_play_avoided_by_runner_motion", false)),
	}


# 三振打席まで繰延べられた盗塁企図(最終球扱い)を三振確定後に解決する。三振では塁状態が
# 変わらないので、呼び出し側は塁状態を bases_after_plate のまま渡してよい。ダブルスチールの
# 片方刺殺変換は _steal_plan の即時解決側と共通のヘルパで処理する(ロジックの複製を避ける)。
static func _deferred_steal_events_after_strikeout(
	event_index: int,
	deferred_intents: Array,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array
) -> Array:
	var events: Array = []
	for intent_value in deferred_intents:
		var intent: Dictionary = intent_value as Dictionary
		events.append(_runner_event_from_intent(event_index, intent, pitcher, defense, bases, "after_plate_result", {"on_strikeout_pitch": true}))
	return _apply_double_steal_caught_conversion(events)


# ダブルスチールで片方が刺された(caught_stealing)場合、もう片方の stolen_base を
# advance_on_double_steal_caught に変換する(記録上の盗塁成功扱いをしない)。
static func _apply_double_steal_caught_conversion(events: Array) -> Array:
	var any_caught: bool = false
	for event_value in events:
		var event: Dictionary = event_value as Dictionary
		if bool(event.get("is_caught_stealing", false)):
			any_caught = true
			break
	if events.size() > 1 and any_caught:
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if bool(event.get("is_stolen_base", false)):
				event["result"] = "advance_on_double_steal_caught"
				event["is_stolen_base"] = false
	return events


static func _runner_event_from_intent(
	event_index: int,
	intent: Dictionary,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	phase: String = "before_pitch",
	extra_fields: Dictionary = {}
) -> Dictionary:
	var runner_id: int = int(intent.get("runner_id", 0))
	var from_base: int = int(intent.get("from_base", 0))
	var to_base: int = int(intent.get("to_base", 0))
	var stealing_skill: float = float(intent.get("success_skill_score", 0.0))
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var catcher_arm: float = _catcher_steal_control(defense)
	var strategy: String = str(intent.get("strategy", "straight_steal"))
	var success_probability: float = STEAL_SUCCESS_BASE
	# 走者の能力と守備だけで成功率を決める。企図判断の状況補正を混ぜない。
	success_probability += stealing_skill * 0.1
	success_probability -= hold_runners * 0.015
	success_probability -= catcher_arm * 0.035
	if from_base == 2:
		# 三盗は企図時点で強く選別されるため、二盗より成功率が高い実勢に合わせる。
		success_probability += STEAL_THIRD_SUCCESS_BONUS
	success_probability = clamp(success_probability, 0.45, 0.88)
	var roll: float = _deterministic_unit([
		event_index,
		from_base,
		to_base,
		runner_id,
		int(success_probability * 10000.0),
		_hash_string(strategy),
		5501,
	])
	var success: bool = roll < success_probability
	var final_to_base: int = to_base
	var throwing_error: bool = false
	# 成功した単独盗塁の一部で捕手送球が逸れ、走者が1つ余分に進む(記録は盗塁+捕手失策 E2)。
	# ダブルスチール(group_id あり)は対象外。刺殺(caught_stealing)は常に刺殺として記録される。
	if success and str(intent.get("group_id", "")).is_empty():
		var extra_target: int = to_base + 1
		var target_open: bool = extra_target >= 4 or (extra_target >= 1 and extra_target <= 3 and bases[extra_target - 1] == null)
		if target_open:
			var error_chance: float = clamp(
				STEAL_THROW_ERROR_EXTRA_BASE - catcher_arm * STEAL_THROW_ERROR_ARM_WEIGHT,
				STEAL_THROW_ERROR_MIN,
				STEAL_THROW_ERROR_MAX
			)
			throwing_error = _deterministic_unit([event_index, from_base, to_base, runner_id, 9901]) < error_chance
			if throwing_error:
				final_to_base = extra_target
	var result_label: String = "stolen_base" if success else "caught_stealing"
	var runner_stub: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_stub.player_id = runner_id
	var extra: Dictionary = {
		"batter_id": int(intent.get("batter_id", 0)),
		"group_id": str(intent.get("group_id", "")),
		"is_stolen_base": success,
		"is_caught_stealing": not success,
		"is_fielding_error": throwing_error,
		"error_position": 2 if throwing_error else 0,
		"success_probability": round(success_probability * 10000.0) / 10000.0,
		"recorded_as_attempt": true,
	}
	if throwing_error:
		extra["fielding_error_type"] = "throwing"
	for key_value in extra_fields.keys():
		extra[key_value] = extra_fields[key_value]
	return _runner_event(
		phase,
		strategy,
		result_label,
		runner_stub,
		null,
		pitcher,
		defense,
		from_base,
		final_to_base,
		true,
		0 if success else 1,
		extra
	)


static func _battery_misplay_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outcome: Dictionary
) -> Array:
	var runner_entry: Dictionary = _highest_original_runner_on_base(bases_before, bases_after_plate)
	if runner_entry.is_empty():
		return []
	var runner: PSPlayerSeasonRecord = runner_entry.get("runner", null) as PSPlayerSeasonRecord
	var from_base: int = int(runner_entry.get("base", 0))
	if runner == null or from_base <= 0:
		return []
	var control: float = _ability(pitcher, "Pit_BBPrevent")
	var stuff: float = _ability(pitcher, "Pit_KCreate")
	var catcher_blocking: float = _catcher_blocking(defense)
	var catcher_game_call: float = _catcher_game_call(defense)
	var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
	var pitch_count: int = int(clamp(int(pitch_summary.get("pitches", 1)), 1, BATTERY_MISPLAY_MAX_PITCHES))
	# 暴投/捕逸は本来1球ごとの事象なので、打席1回ではなく球数分の機会へ変換する。
	# raw z に重みを掛け畳み込み済みベース定数へ足す(中立点・母平均の概念なし)。
	var wild_per_pitch: float = clamp(
		WILD_PITCH_PER_PITCH_BASE
		- control * WILD_PITCH_CONTROL_WEIGHT
		+ stuff * WILD_PITCH_STUFF_WEIGHT
		- catcher_blocking * WILD_PITCH_BLOCKING_WEIGHT
		- catcher_game_call * WILD_PITCH_GAME_CALL_WEIGHT,
		WILD_PITCH_PER_PITCH_MIN,
		WILD_PITCH_PER_PITCH_MAX
	)
	var passed_per_pitch: float = clamp(
		PASSED_BALL_PER_PITCH_BASE - catcher_blocking * PASSED_BALL_BLOCKING_WEIGHT,
		PASSED_BALL_PER_PITCH_MIN,
		PASSED_BALL_PER_PITCH_MAX
	)
	var wild_probability: float = 1.0 - pow(1.0 - wild_per_pitch, float(pitch_count))
	var passed_probability: float = 1.0 - pow(1.0 - passed_per_pitch, float(pitch_count))
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if pitcher == null else pitcher.player_id,
		_hash_string(str(outcome.get("category", ""))),
		pitch_count,
		6607,
	])
	if roll >= wild_probability + passed_probability:
		return []
	var result: String = "wild_pitch" if roll < wild_probability else "passed_ball"
	return [_runner_event(
		"after_plate_result",
		result,
		result,
		runner,
		batter,
		pitcher,
		defense,
		from_base,
		from_base + 1,
		false,
		0,
		{
			"is_wild_pitch": result == "wild_pitch",
			"is_passed_ball": result == "passed_ball",
		}
	)]


static func _defensive_indifference_event(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_after_plate: Array,
	context: Dictionary
) -> Dictionary:
	var inning: int = int(context.get("inning", 0))
	var defense_lead: int = int(context.get("defense_score", 0)) - int(context.get("offense_score", 0))
	if inning < 8 or defense_lead < 2:
		return {}
	for base_index in range(0, 2):
		var runner: PSPlayerSeasonRecord = bases_after_plate[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		if bases_after_plate[base_index + 1] != null:
			continue
		var probability: float = clamp(0.015 + float(defense_lead - 1) * 0.01, 0.0, 0.12)
		if _deterministic_unit([event_index, runner.player_id, defense_lead, 7703]) >= probability:
			return {}
		return _runner_event(
			"after_plate_result",
			"defensive_indifference",
			"defensive_indifference",
			runner,
			batter,
			pitcher,
			defense,
			base_index + 1,
			base_index + 2,
			false,
			0,
			{"is_defensive_indifference": true}
		)
	return {}


static func _batted_ball_extra_base_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outs_before: int,
	outs_after_plate: int,
	outcome: Dictionary
) -> Array:
	var category: String = str(outcome.get("category", "out"))
	if category != "hit" and int(outcome.get("bases", 0)) <= 0:
		return []
	if outs_after_plate >= 3:
		return []
	var events: Array = []
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var current_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		if current_base <= before_index + 1 or current_base <= 0:
			continue
		var to_base: int = current_base + 1
		if to_base <= 3 and bases_after_plate[to_base - 1] != null:
			continue
		var speed: float = _ability(runner, "Run_Speed")
		var outfield_arm: float = _fielder_throwing_for_outcome(defense, outcome)
		# 走力 z が高いほど追加進塁、外野肩 z が高いほど抑制(raw z に重みを掛け畳み込み済みベース定数へ足す。
		# 中立点・母平均の概念なし)。
		var probability: float = clamp(0.000725 + speed * 0.03125 - outfield_arm * 0.01875, 0.0, 0.28)
		if outs_before == 2:
			probability += 0.08
		if to_base >= 4:
			probability -= 0.02
		var roll: float = _deterministic_unit([
			event_index,
			runner.player_id,
			current_base,
			to_base,
			_hash_string(str(outcome.get("result", ""))),
			8807,
		])
		if roll >= probability:
			continue
		# 外野肩 z が走者走力 z を上回るほど走塁死。
		var out_probability: float = clamp(0.06 + (outfield_arm - speed) * 0.025, 0.02, 0.22)
		var out_roll: float = _deterministic_unit([event_index, runner.player_id, current_base, to_base, 8819])
		var runner_out: bool = out_roll < out_probability
		events.append(_runner_event(
			"after_batted_ball",
			"runner_out_advancing" if runner_out else "extra_base_on_hit",
			"runner_out_advancing" if runner_out else "extra_base_on_hit",
			runner,
			batter,
			pitcher,
			defense,
			current_base,
			to_base,
			false,
			1 if runner_out else 0,
			{
				"is_baserunning_out": runner_out,
				"batter_rbi": not runner_out and to_base >= 4,
			}
		))
		break
	return events


static func _already_applied_advancement_events(
	_event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outcome: Dictionary
) -> Array:
	var category: String = str(outcome.get("category", "out"))
	if category != "sacrifice_fly" and category != "sacrifice" and category != "productive_out":
		return []
	var events: Array = []
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var after_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		var from_base: int = before_index + 1
		var to_base: int = after_base if after_base > 0 else 4
		if to_base <= from_base:
			continue
		var strategy: String = "tag_up" if category == "sacrifice_fly" else "sacrifice_advance"
		if str(outcome.get("runner_strategy", "")) == "squeeze" and from_base == 3 and to_base >= 4:
			strategy = "squeeze"
		events.append(_runner_event(
			"after_batted_ball",
			strategy,
			strategy,
			runner,
			batter,
			pitcher,
			defense,
			from_base,
			to_base,
			false,
			0,
			{"state_already_applied": true}
		))
	return events


static func _runner_event(
	phase: String,
	strategy: String,
	result: String,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	from_base: int,
	to_base: int,
	is_steal_attempt: bool,
	outs_added: int,
	extra: Dictionary = {}
) -> Dictionary:
	var event: Dictionary = {
		"event_type": EVENT_TYPE_RUNNER_EVENT,
		"phase": phase,
		"strategy": strategy,
		"runner_id": 0 if runner == null else runner.player_id,
		"batter_id": int(extra.get("batter_id", 0 if batter == null else batter.player_id)),
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"catcher_id": _catcher_id(defense),
		"from_base": from_base,
		"to_base": to_base,
		"result": result,
		"is_steal_attempt": is_steal_attempt,
		"is_stolen_base": bool(extra.get("is_stolen_base", result == "stolen_base")),
		"is_caught_stealing": bool(extra.get("is_caught_stealing", result == "caught_stealing")),
		"is_pickoff": result == "pickoff",
		"is_wild_pitch": bool(extra.get("is_wild_pitch", false)),
		"is_passed_ball": bool(extra.get("is_passed_ball", false)),
		"is_balk": result == "balk",
		"is_defensive_indifference": bool(extra.get("is_defensive_indifference", false)),
		"is_baserunning_out": bool(extra.get("is_baserunning_out", false)),
		"recorded_as_attempt": bool(extra.get("recorded_as_attempt", is_steal_attempt)),
		"state_already_applied": bool(extra.get("state_already_applied", false)),
		"outs_added": outs_added,
		"run_value": 0.0,
	}
	for key_value in extra.keys():
		event[key_value] = extra[key_value]
	return event


static func _is_batted_ball_outcome(outcome: Dictionary) -> bool:
	var category: String = str(outcome.get("category", "out"))
	return category != CATEGORY_WALK and category != CATEGORY_HIT_BY_PITCH and category != CATEGORY_STRIKEOUT


static func _pickoff_target(bases: Array) -> Dictionary:
	for base_index in [0, 1]:
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner != null:
			return {"base": base_index + 1, "runner": runner}
	return {}


static func _highest_original_runner_on_base(bases_before: Array, bases_after_plate: Array) -> Dictionary:
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var current_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		if current_base > 0 and current_base < 4:
			return {"base": current_base, "runner": runner}
	return {}


static func _base_for_runner_id(bases: Array, runner_id: int) -> int:
	if runner_id <= 0:
		return 0
	for index in range(bases.size()):
		var runner: PSPlayerSeasonRecord = bases[index] as PSPlayerSeasonRecord
		if runner != null and runner.player_id == runner_id:
			return index + 1
	return 0


static func _sort_lead_runner_first(events: Array) -> Array:
	events.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("from_base", 0)) > int((b as Dictionary).get("from_base", 0))
	)
	return events


static func _catcher_id(defense: Dictionary) -> int:
	return int(_catcher_metrics(defense).get("id", 0))


# 捕手の盗塁抑止力を z で返す（0.0 が全体平均）。
static func _catcher_steal_control(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("steal_control", 0.0))


# 捕手の捕逸抑止力を z で返す。
static func _catcher_blocking(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("blocking", 0.0))


# 捕手の配球(ゲームコール)を z で返す。
static func _catcher_game_call(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("game_call", 0.0))


static func _catcher_metrics(defense: Dictionary) -> Dictionary:
	var cache: Dictionary = defense.get(CATCHER_METRIC_CACHE_KEY, {}) as Dictionary
	if not defense.has(CATCHER_METRIC_CACHE_KEY):
		defense[CATCHER_METRIC_CACHE_KEY] = cache
	var catcher: PSPlayerSeasonRecord = _catcher_record(defense)
	if catcher == null:
		if not cache.has("0"):
			cache["0"] = {
				"id": 0,
				"steal_control": 0.0,
				"blocking": 0.0,
				"game_call": 0.0,
			}
		return cache["0"] as Dictionary
	var cache_key: String = str(catcher.player_id)
	if cache.has(cache_key):
		return cache[cache_key] as Dictionary
	# 守備の安定(C_FieldSecure)と配球(C_GameCall)。盗塁抑止/捕逸抑止はこれらと肩/ブロックの z 加重平均。
	var field_secure: float = _ability(catcher, "C_FieldSecure")
	var game_call: float = _ability(catcher, "C_GameCall")
	var metrics: Dictionary = {
		"id": catcher.player_id,
		"steal_control": _weighted_z([
			_ability(catcher, "C_Throw"),
			field_secure,
			game_call,
		], [0.65, 0.18, 0.17]),
		"blocking": _weighted_z([
			_ability(catcher, "C_Blocking"),
			field_secure,
			game_call,
		], [0.75, 0.15, 0.10]),
		"game_call": game_call,
	}
	cache[cache_key] = metrics
	return metrics


static func _catcher_record(defense: Dictionary) -> PSPlayerSeasonRecord:
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == 2:
			return slot.get("record", null) as PSPlayerSeasonRecord
	var batters: Array = defense.get("batters", []) as Array
	for record_value in batters:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null and record.position == 2:
			return record
	return null


# 打球を処理した野手の送球力(肩)を z で返す。外野=OF_ArmPower / 内野=IF_ThrowPower。投手/捕手は中立。
static func _fielder_throwing_for_outcome(defense: Dictionary, outcome: Dictionary) -> float:
	var position: int = int(outcome.get("fielder_position", 0))
	if position <= 0:
		return 0.0
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) != position:
			continue
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			return 0.0
		if position >= 7:
			return _ability(record, "OF_ArmPower")
		if position >= 3:
			return _ability(record, "IF_ThrowPower")
		return 0.0
	return 0.0


# 能力を z-score で返す（0.0 が全体平均）。display 1-100 ではなく z のまま走塁計算に使う。
static func _ability(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	return record.z_ability(key, default_value)


# z 値の加重平均を返す（重みの和で正規化）。捕手能力の合成に使う。
static func _weighted_z(values: Array, weights: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	var n: int = min(values.size(), weights.size())
	for i in range(n):
		var weight: float = float(weights[i])
		total += float(values[i]) * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return total / weight_total


static func _deterministic_unit(values: Array) -> float:
	var seed_value: int = 811
	for value in values:
		seed_value = int(abs((seed_value * 1103515245 + int(value) * 12345 + 1013904223) % 2147483647))
	return float(seed_value % 10000) / 10000.0


static func _hash_string(value: String) -> int:
	var hash_value: int = 0
	for index in range(value.length()):
		hash_value = int(abs((hash_value * 31 + value.unicode_at(index)) % 2147483647))
	return hash_value
