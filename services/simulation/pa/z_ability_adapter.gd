extends RefCounted
class_name PSZAbilityAdapter

# File 2 §5: z-score 能力値を PSPlayerSeasonRecord から取り出すアダプタ。
# precomp / softmax の入力源を z_abilities_snapshot に集約するための薄いラッパー。
# 欠落キーは 0.0 (リーグ平均) で穴埋め、null record は all-zero dict を返す。


static func batter_view(record: PSPlayerSeasonRecord) -> Dictionary:
	return _view_for_keys(record, PSPlayer.Z_BATTER_ABILITY_KEYS)


static func pitcher_view(record: PSPlayerSeasonRecord) -> Dictionary:
	return _view_for_keys(record, PSPlayer.Z_PITCHER_ABILITY_KEYS)


static func catcher_view(record: PSPlayerSeasonRecord) -> Dictionary:
	return _view_for_keys(record, PSPlayer.Z_CATCHER_ABILITY_KEYS)


# z_abilities_snapshot 欠落キーの early-warn。
# RecordStore.ensure_season_records 等のロード時に 1 度だけ呼ぶ。
# 戻り値は欠落キー一覧 {player_id -> Array[String]}（呼び出し側でログ出力する）。
static func collect_missing_z_keys(records: Array) -> Dictionary:
	var missing_by_player: Dictionary = {}
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record == null:
			continue
		var missing: Array[String] = []
		_collect_group_missing(record, PSPlayer.Z_BATTER_ABILITY_KEYS, missing)
		if record.is_pitcher():
			_collect_group_missing(record, PSPlayer.Z_PITCHER_ABILITY_KEYS, missing)
		else:
			var category: String = record.fielding_ability_category()
			match category:
				"catcher":
					_collect_group_missing(record, PSPlayer.Z_CATCHER_ABILITY_KEYS, missing)
				"infield":
					_collect_group_missing(record, PSPlayer.Z_INFIELD_ABILITY_KEYS, missing)
				"outfield":
					_collect_group_missing(record, PSPlayer.Z_OUTFIELD_ABILITY_KEYS, missing)
			_collect_group_missing(record, PSPlayer.Z_RUNNING_ABILITY_KEYS, missing)
		if not missing.is_empty():
			missing_by_player[record.player_id] = missing
	return missing_by_player


static func _view_for_keys(record: PSPlayerSeasonRecord, keys: Dictionary) -> Dictionary:
	var view: Dictionary = {}
	for key_value in keys.keys():
		var key: String = str(key_value)
		if record == null:
			view[key] = 0.0
		else:
			view[key] = record.z_ability(key, 0.0)
	return view


static func _collect_group_missing(record: PSPlayerSeasonRecord, keys: Dictionary, out_missing: Array[String]) -> void:
	for key_value in keys.keys():
		var key: String = str(key_value)
		if not record.z_abilities_snapshot.has(key):
			out_missing.append(key)
