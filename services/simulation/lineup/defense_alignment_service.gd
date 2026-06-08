extends RefCounted
class_name PSDefenseAlignmentService

# Phase 4: 守備配置テンプレート + 最小補充。
# 旧 best_fielding_assignment_dp (8! 全探索 DP) を置換し、計算量を O(9 × N) に圧縮。
# 不在判定は injury_days > 0 のみ (fatigue は score 計算で減点される既存挙動を維持)。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

# GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER と同一: 捕手 → 遊撃 → 中堅 → 二塁 → 三塁 → 一塁 → 左翼 → 右翼
const POSITIONS: Array[int] = [2, 6, 8, 4, 5, 3, 7, 9]
const SUB_INTERVAL_FATIGUE_EMERGENCY: int = -1
const FIELDER_FATIGUE_SUB_THRESHOLD: int = 80


static func assign_defensive_starters(
	available_fielders: Array,
	profile: PSDefenseAlignmentProfile,
	usage_settings: Dictionary = {},
	next_game_number: int = 1
) -> Array:
	if available_fielders.is_empty() or profile == null:
		return []

	# 1. record インデックスと healthy リストを構築
	var record_by_id: Dictionary = {}
	var healthy: Array = []
	for row in available_fielders:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null:
			continue
		record_by_id[rec.player_id] = rec
		if rec.injury_days <= 0:
			healthy.append(rec)

	if healthy.size() < POSITIONS.size():
		return []

	# 2. starter_assignment_score の batting_score 部分を 1 度だけ計算してキャッシュ。
	# 同じ候補が 8 ポジション × greedy fallback で何度も評価されるため、
	# キャッシュしないと batting_score の中の ability lookup / sigmoid が重複する。
	var batting_cache: Dictionary = {}
	for rec_row in healthy:
		var rec: PSPlayerSeasonRecord = rec_row as PSPlayerSeasonRecord
		if rec != null:
			batting_cache[rec.player_id] = PlayerValueEvaluator.batting_score(rec)

	# 3. starting_positions が空 (lazy default 初回) なら healthy から greedy で template 生成
	var template: Dictionary = profile.starting_positions.duplicate()
	if template.is_empty():
		template = _generate_greedy_template(healthy, batting_cache)
		profile.starting_positions = template.duplicate()

	# 4. 各 position に割当
	var assignments: Array = []
	var used_ids: Dictionary = {}

	for position_row in POSITIONS:
		var position: int = int(position_row)
		var chosen: PSPlayerSeasonRecord = null
		var slot_settings: Dictionary = _position_slot_settings(profile, usage_settings, position)
		if int(slot_settings.get("sub_id", 0)) > 0 and int(slot_settings.get("sub_id", 0)) == int(slot_settings.get("starter_id", 0)):
			slot_settings["sub_id"] = 0
		var should_start_sub: bool = _sub_should_start(slot_settings, record_by_id, next_game_number)

		if should_start_sub:
			chosen = _configured_record_for_position(record_by_id, used_ids, slot_settings, "sub_id", position)
			if chosen != null:
				var rested_starter_id: int = int(slot_settings.get("starter_id", 0))
				if rested_starter_id > 0 and rested_starter_id != chosen.player_id:
					used_ids[rested_starter_id] = true

		if chosen == null:
			chosen = _configured_record_for_position(record_by_id, used_ids, slot_settings, "starter_id", position)

		# a. template の指定選手 (健康かつ未使用)
		var tmpl_id: int = int(template.get(position, template.get(str(position), 0)))
		if chosen == null and tmpl_id > 0 and record_by_id.has(tmpl_id) and not used_ids.has(tmpl_id):
			var tmpl_rec: PSPlayerSeasonRecord = record_by_id[tmpl_id] as PSPlayerSeasonRecord
			if tmpl_rec.injury_days <= 0 and _can_play_position(tmpl_rec, position):
				chosen = tmpl_rec

		# b. backup_priority の優先順
		var backups: Array = []
		if profile.backup_priority.has(position):
			backups = profile.backup_priority[position] as Array
		elif profile.backup_priority.has(str(position)):
			backups = profile.backup_priority[str(position)] as Array
		if chosen == null and not backups.is_empty():
			for backup_id_row in backups:
				var backup_id: int = int(backup_id_row)
				if record_by_id.has(backup_id) and not used_ids.has(backup_id):
					var b_rec: PSPlayerSeasonRecord = record_by_id[backup_id] as PSPlayerSeasonRecord
					if b_rec.injury_days <= 0 and _can_play_position(b_rec, position):
						chosen = b_rec
						break

		if chosen == null and not should_start_sub:
			chosen = _configured_record_for_position(record_by_id, used_ids, slot_settings, "sub_id", position)

		# c. 残候補から starter_assignment_score 最高値で貪欲補充
		# (打撃/守備の position 別ブレンド。純守備版は defensive_assignment_score を参照)
		if chosen == null:
			chosen = _best_remaining_for_position(healthy, used_ids, position, true, batting_cache)

		# d. 守備不能 (適性保持者が 1 人も残っていない) のときだけ、任意の健康・未使用選手を
		# その守備位置に就ける。ただしポジション適性は 1 として扱う (record snapshot を 1 に
		# 設定 = defensive_score_for_position で適性ギャップ最大級のペナルティ)。
		if chosen == null:
			chosen = _emergency_fill_position(healthy, used_ids, position, batting_cache)

		if chosen == null:
			return []  # 健康な野手が 8 人未満のときのみ到達 (上で early return 済)。

		assignments.append({"record": chosen, "position": position})
		used_ids[chosen.player_id] = true

	return assignments


# 守備不能時の緊急起用。健康・未使用の中で打撃最良の選手を選び、その守備位置の適性を
# 1 として扱う (snapshot を 1 に上書き)。適性 0 は各所のゲートで弾かれるため 1 にする。
static func _emergency_fill_position(healthy: Array, used_ids: Dictionary, position: int, batting_cache: Dictionary) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = _best_unused_healthy(healthy, used_ids, batting_cache)
	if rec == null:
		return null
	_force_emergency_aptitude(rec, position)
	return rec


# 未使用の健康な選手のうち打撃が最も高い者 (緊急起用でも攻撃力を活かす)。
static func _best_unused_healthy(healthy: Array, used_ids: Dictionary, batting_cache: Dictionary) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_bat: int = -2147483647
	for row in healthy:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null or used_ids.has(rec.player_id):
			continue
		var bat: int = int(batting_cache.get(rec.player_id, 0))
		if best == null or bat > best_bat:
			best = rec
			best_bat = bat
	return best


# record の守備位置 position の適性を最低 1 にする。snapshot が空 (本職 100 暗黙) の場合は
# 本職 100 を明示化してから上書きし、本職適性を失わないようにする。
static func _force_emergency_aptitude(record: PSPlayerSeasonRecord, position: int) -> void:
	if record == null or position < 2 or position > 9:
		return
	var key: String = str(PlayerValueEvaluator.POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return
	var snapshot: Dictionary = record.position_aptitudes_snapshot
	if snapshot.is_empty():
		for p in range(2, 10):
			var p_key: String = str(PlayerValueEvaluator.POSITION_APTITUDE_KEYS.get(p, ""))
			if not p_key.is_empty():
				snapshot[p_key] = 100 if record.position == p else 0
	if int(snapshot.get(key, 0)) < 1:
		snapshot[key] = 1


# --- 内部ヘルパー ---

static func _generate_greedy_template(healthy: Array, batting_cache: Dictionary = {}) -> Dictionary:
	# 初回起動時のみ走る。POSITIONS の希少順 (捕手・遊撃を先) に最適選手を貪欲確保。
	var template: Dictionary = {}
	var used_ids: Dictionary = {}
	for position_row in POSITIONS:
		var position: int = int(position_row)
		var chosen: PSPlayerSeasonRecord = _best_remaining_for_position(healthy, used_ids, position, true, batting_cache)
		if chosen != null:
			template[position] = chosen.player_id
			used_ids[chosen.player_id] = true
	return template


static func _best_remaining_for_position(
	healthy: Array,
	used_ids: Dictionary,
	position: int,
	require_aptitude: bool,
	batting_cache: Dictionary = {}
) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -2147483647
	for row in healthy:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null or used_ids.has(rec.player_id):
			continue
		if not _can_play_position(rec, position):
			continue
		var bat_override: int = int(batting_cache.get(rec.player_id, -1))
		var score: int = PlayerValueEvaluator.starter_assignment_score(rec, position, require_aptitude, bat_override)
		if score <= PlayerValueEvaluator.ZERO_APTITUDE_SCORE:
			continue
		if best == null or score > best_score:
			best = rec
			best_score = score
	return best


static func _position_slot_settings(profile: PSDefenseAlignmentProfile, usage_settings: Dictionary, position: int) -> Dictionary:
	var profile_slots: Dictionary = {}
	if profile != null:
		profile_slots = profile.position_slots
	var usage_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	var key: String = str(position)
	if usage_slots.has(key):
		return (usage_slots.get(key, {}) as Dictionary).duplicate(true)
	if usage_slots.has(position):
		return (usage_slots.get(position, {}) as Dictionary).duplicate(true)
	if profile_slots.has(key):
		return (profile_slots.get(key, {}) as Dictionary).duplicate(true)
	if profile_slots.has(position):
		return (profile_slots.get(position, {}) as Dictionary).duplicate(true)
	return {}


static func _sub_is_due(slot_settings: Dictionary, next_game_number: int) -> bool:
	var interval: int = int(slot_settings.get("sub_start_interval", 0))
	return interval > 0 and next_game_number > 0 and next_game_number % interval == 0


static func _sub_should_start(slot_settings: Dictionary, record_by_id: Dictionary, next_game_number: int) -> bool:
	if _sub_is_due(slot_settings, next_game_number):
		return true
	var interval: int = int(slot_settings.get("sub_start_interval", 0))
	if interval != SUB_INTERVAL_FATIGUE_EMERGENCY:
		return false
	var starter_id: int = int(slot_settings.get("starter_id", 0))
	if starter_id <= 0 or not record_by_id.has(starter_id):
		return false
	var starter: PSPlayerSeasonRecord = record_by_id[starter_id] as PSPlayerSeasonRecord
	return starter != null and starter.injury_days <= 0 and starter.fatigue >= FIELDER_FATIGUE_SUB_THRESHOLD


static func _configured_record_for_position(
	record_by_id: Dictionary,
	used_ids: Dictionary,
	slot_settings: Dictionary,
	key: String,
	position: int
) -> PSPlayerSeasonRecord:
	var player_id: int = int(slot_settings.get(key, 0))
	if player_id <= 0 or used_ids.has(player_id) or not record_by_id.has(player_id):
		return null
	var record: PSPlayerSeasonRecord = record_by_id[player_id] as PSPlayerSeasonRecord
	if record == null or record.injury_days > 0:
		return null
	if not _can_play_position(record, position):
		return null
	return record


static func _can_play_position(record: PSPlayerSeasonRecord, position: int) -> bool:
	if record == null or position < 2 or position > 9:
		return false
	return PlayerValueEvaluator.position_aptitude(record, position) > 0
