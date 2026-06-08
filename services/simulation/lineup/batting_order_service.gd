extends RefCounted
class_name PSBattingOrderService

# 基本打順をコピー → 固定 lock → グループ内でスコア順に並べ替え → 制約チェック。
# Phase 3 v1 では condition (調子) と Bat_Platoon (対左右) は未対応。
# 計算量は entries=9 + グループ最大4のソートのみで実質固定。

const Z_SCALE: float = 10.0  # z-score (σ=1) × 10 → int 化、グループ内比較用


static func build_daily_batting_order(
	entries: Array,
	context: Dictionary,
	profile: PSBattingOrderProfile
) -> Array:
	if entries.is_empty():
		return entries.duplicate()

	var order: Array = _copy_entries(entries, profile)
	_apply_forced_locks(order, profile)
	_reorder_group(order, profile.top_group, "top", context, profile)
	_reorder_group(order, profile.middle_group, "middle", context, profile)
	_reorder_group(order, profile.lower_group, "lower", context, profile)
	_enforce_final_constraints(order)

	# base_order が空 (lazy default 初回) なら、今回の結果をメモリ profile に書き戻す。
	# 次試合からは同じ base を起点に日替わり並べ替えが走る。
	if profile.base_order_player_ids.is_empty():
		var ids: Array[int] = []
		for slot_entry in order:
			ids.append((slot_entry["record"] as PSPlayerSeasonRecord).player_id)
		profile.base_order_player_ids = ids

	var result: Array = []
	for slot_entry in order:
		result.append(slot_entry["record"])
	return result


# --- 内部ヘルパー ---

static func _copy_entries(entries: Array, profile: PSBattingOrderProfile) -> Array:
	var copied: Array = []
	var base_ids: Array[int] = profile.base_order_player_ids

	if base_ids.is_empty():
		var i: int = 0
		for entry in entries:
			i += 1
			copied.append({"record": entry, "slot": i, "score": 0, "locked": false})
		return copied

	# base_order の player_id → slot マップで配置。base に無い選手は空きスロット詰め。
	var slot_by_pid: Dictionary = {}
	for idx in range(base_ids.size()):
		slot_by_pid[base_ids[idx]] = idx + 1

	var assigned_slots: Dictionary = {}
	var unassigned: Array = []
	for entry_row in entries:
		var rec: PSPlayerSeasonRecord = entry_row as PSPlayerSeasonRecord
		if slot_by_pid.has(rec.player_id) and not assigned_slots.has(slot_by_pid[rec.player_id]):
			var slot: int = int(slot_by_pid[rec.player_id])
			copied.append({"record": rec, "slot": slot, "score": 0, "locked": false})
			assigned_slots[slot] = true
		else:
			unassigned.append(rec)

	var next_slot: int = 1
	for rec_row in unassigned:
		while assigned_slots.has(next_slot) and next_slot <= entries.size():
			next_slot += 1
		if next_slot > entries.size():
			break
		copied.append({"record": rec_row, "slot": next_slot, "score": 0, "locked": false})
		assigned_slots[next_slot] = true
		next_slot += 1

	return copied


static func _apply_forced_locks(order: Array, profile: PSBattingOrderProfile) -> void:
	# 投手 9 番固定 (DH OFF 時のみ entries に含まれる)
	for slot_entry in order:
		var rec: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
		if rec.is_pitcher():
			slot_entry["slot"] = 9
			slot_entry["locked"] = true

	# profile.fixed_slot_by_player に該当
	for slot_entry in order:
		var rec_p: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
		var key: String = str(rec_p.player_id)
		if profile.fixed_slot_by_player.has(key):
			slot_entry["slot"] = int(profile.fixed_slot_by_player[key])
			slot_entry["locked"] = true

	# keep_cleanup_fixed
	if profile.keep_cleanup_fixed:
		for slot_entry in order:
			if int(slot_entry["slot"]) == 4:
				slot_entry["locked"] = true


static func _reorder_group(
	order: Array,
	slots: Array[int],
	role: String,
	context: Dictionary,
	profile: PSBattingOrderProfile
) -> void:
	var movable: Array = []
	var locked_slots: Dictionary = {}
	for slot_entry in order:
		var slot: int = int(slot_entry["slot"])
		if not slots.has(slot):
			continue
		if bool(slot_entry["locked"]):
			locked_slots[slot] = true
		else:
			var rec: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
			var score: int = _role_score(rec, role) + _condition_bonus(rec) - _fatigue_penalty(rec)
			if profile.allow_random_bonus:
				score += _seeded_random_bonus(context, rec.player_id, profile.random_bonus_range)
			slot_entry["score"] = score
			movable.append(slot_entry)

	movable.sort_custom(func(a, b) -> bool:
		return int(a["score"]) > int(b["score"])
	)

	var available: Array[int] = []
	for s in slots:
		if not locked_slots.has(s):
			available.append(s)
	available.sort()

	for i in range(min(movable.size(), available.size())):
		movable[i]["slot"] = available[i]


static func _role_score(record: PSPlayerSeasonRecord, role: String) -> int:
	var z: Dictionary = record.z_abilities_snapshot
	var k_avoid: float = float(z.get("Bat_KAvoid", 0.0))
	var bb_create: float = float(z.get("Bat_BBCreate", 0.0))
	var impact: float = float(z.get("Bat_Impact", 0.0))
	var loft: float = float(z.get("Bat_Loft", 0.0))
	var barrel: float = float(z.get("Bat_Barrel", 0.0))
	var speed: float = float(z.get("Run_Speed", 0.0))
	var pitcher_penalty: float = 1.0 if record.is_pitcher() else 0.0

	var raw: float = 0.0
	match role:
		"top":
			raw = 2.0 * k_avoid + 2.0 * bb_create + 1.2 * speed + 0.8 * barrel
		"middle":
			# slot 4 は keep_cleanup_fixed=true なら locked、そうでなければ middle 一般式で順位決定。
			raw = 1.5 * barrel + 1.0 * impact + 0.8 * bb_create
		_:
			raw = 0.7 * barrel + 0.5 * k_avoid + 0.3 * speed - 1.0 * pitcher_penalty

	return int(round(raw * Z_SCALE))


static func _condition_bonus(_record: PSPlayerSeasonRecord) -> int:
	# PSPlayerSeasonRecord に condition フィールドが無いため Phase 3 v1 は 0。
	# 将来 condition (-2..+2) を追加したらここで段階制 (±3, ±6) を返す。
	return 0


static func _fatigue_penalty(record: PSPlayerSeasonRecord) -> int:
	# 仕様書 §6.6 のテーブルは fatigue 0-100 想定。内部 fatigue は 0-200 なので半分にスケール。
	var f: int = clampi(record.fatigue / 2, 0, 100)
	if f <= 30:
		return 0
	if f <= 60:
		return 3
	if f <= 80:
		return 8
	return 15


static func _seeded_random_bonus(context: Dictionary, player_id: int, range_max: int) -> int:
	# 同じ (day, team, player) で同じ値 → 再 sim 時の打順再現性を保証。
	var rng := RandomNumberGenerator.new()
	var game_day: int = int(context.get("game_day", 0))
	var team_id: int = int(context.get("team_id", 0))
	rng.seed = hash("%d_%d_%d" % [game_day, team_id, player_id])
	return rng.randi_range(-range_max, range_max)


static func _enforce_final_constraints(order: Array) -> void:
	_resolve_duplicate_slots(order)
	_sort_by_slot(order)


static func _resolve_duplicate_slots(order: Array) -> void:
	var by_slot: Dictionary = {}
	var duplicates: Array = []
	for slot_entry in order:
		var slot: int = int(slot_entry["slot"])
		if not by_slot.has(slot):
			by_slot[slot] = slot_entry
		else:
			# locked 優先、movable は空きへ
			if bool(slot_entry["locked"]):
				duplicates.append(by_slot[slot])
				by_slot[slot] = slot_entry
			else:
				duplicates.append(slot_entry)

	var max_slot: int = order.size()
	var empties: Array[int] = []
	for s in range(1, max_slot + 1):
		if not by_slot.has(s):
			empties.append(s)

	for i in range(min(duplicates.size(), empties.size())):
		duplicates[i]["slot"] = empties[i]
		by_slot[empties[i]] = duplicates[i]


static func _sort_by_slot(order: Array) -> void:
	order.sort_custom(func(a, b) -> bool:
		return int(a["slot"]) < int(b["slot"])
	)
