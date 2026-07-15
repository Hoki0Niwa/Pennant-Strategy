extends RefCounted

# 一軍の外国人登録枠。合計枠に加え、投手・野手の一方だけで全枠を占めることはできない。
const TOTAL_MAX: int = 4
const TYPE_MAX: int = TOTAL_MAX - 1


static func empty_counts() -> Dictionary:
	return {
		"foreigners": 0,
		"foreign_pitchers": 0,
		"foreign_fielders": 0,
	}


static func add_record(counts: Dictionary, record: PSPlayerSeasonRecord) -> void:
	if record == null or not record.foreign_player:
		return
	counts["foreigners"] = int(counts.get("foreigners", 0)) + 1
	var key: String = "foreign_pitchers" if record.is_pitcher() else "foreign_fielders"
	counts[key] = int(counts.get(key, 0)) + 1


static func counts_from_records(records: Array) -> Dictionary:
	var counts: Dictionary = empty_counts()
	for record_row in records:
		add_record(counts, record_row as PSPlayerSeasonRecord)
	return counts


static func counts_from_active_set(active_set: Dictionary, record_by_id: Dictionary) -> Dictionary:
	var counts: Dictionary = empty_counts()
	for player_id_value in active_set.keys():
		var record: PSPlayerSeasonRecord = record_by_id.get(int(player_id_value), null) as PSPlayerSeasonRecord
		add_record(counts, record)
	return counts


static func can_add_record(counts: Dictionary, record: PSPlayerSeasonRecord) -> bool:
	if record == null or not record.foreign_player:
		return true
	if int(counts.get("foreigners", 0)) >= TOTAL_MAX:
		return false
	var type_key: String = "foreign_pitchers" if record.is_pitcher() else "foreign_fielders"
	return int(counts.get(type_key, 0)) < TYPE_MAX


static func is_within_limits(counts: Dictionary) -> bool:
	return int(counts.get("foreigners", 0)) <= TOTAL_MAX \
		and int(counts.get("foreign_pitchers", 0)) <= TYPE_MAX \
		and int(counts.get("foreign_fielders", 0)) <= TYPE_MAX


static func violation_message(counts: Dictionary) -> String:
	var total: int = int(counts.get("foreigners", 0))
	if total > TOTAL_MAX:
		return "外国人枠は最大%d人です（現在%d人）" % [TOTAL_MAX, total]
	var pitchers: int = int(counts.get("foreign_pitchers", 0))
	if pitchers > TYPE_MAX:
		return "外国人投手は最大%d人です（現在%d人）" % [TYPE_MAX, pitchers]
	var fielders: int = int(counts.get("foreign_fielders", 0))
	if fielders > TYPE_MAX:
		return "外国人野手は最大%d人です（現在%d人）" % [TYPE_MAX, fielders]
	return ""


static func add_block_message(counts: Dictionary, record: PSPlayerSeasonRecord) -> String:
	if record == null or not record.foreign_player:
		return ""
	if int(counts.get("foreigners", 0)) >= TOTAL_MAX:
		return "外国人枠は最大%d人です" % TOTAL_MAX
	var type_count: int = int(counts.get("foreign_pitchers" if record.is_pitcher() else "foreign_fielders", 0))
	if type_count >= TYPE_MAX:
		return "外国人%sは最大%d人です" % ["投手" if record.is_pitcher() else "野手", TYPE_MAX]
	return ""
