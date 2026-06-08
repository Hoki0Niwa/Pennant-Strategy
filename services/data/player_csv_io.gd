extends RefCounted
class_name PSPlayerCsvIo

# 選手・球団データの CSV ↔ dict 変換（1 行 = 1 エンティティ、表計算ソフトで編集可能）。
#
# 設計方針:
# - z_abilities / raw_abilities / position_aptitudes / position_experience はドット記法の
#   個別列に平坦化（例 z_abilities.Bat_Impact）。能力値は編集しやすいよう列に展開する。
# - source_data は内部由来情報なので 1 セルに JSON 文字列で格納（source_data_json 列）。
# - 旧能力 (batting_abilities/fielding_abilities/legacy_abilities) は含めない（z が正準）。
# - クォート/エスケープは FileAccess.store_csv_line / get_csv_line に委譲（RFC 準拠）。
# - PSPlayer.to_dict() / PSTeam.to_dict() と 1 対 1 でラウンドトリップする。

const META_ORDER: Array = [
	"id", "name", "team_id", "position", "role", "age", "years", "bats", "throws",
	"height", "weight", "salary", "draft_round", "jersey_number", "sensyu_num",
	"development_player", "foreign_player", "hometown", "registered_roster",
	"contract_status", "fatigue", "injury_days", "condition", "fixed_slot",
]
const META_INT_FIELDS: Array = [
	"id", "team_id", "position", "age", "years", "height", "weight", "salary",
	"draft_round", "jersey_number", "sensyu_num", "fatigue", "injury_days",
	"condition", "fixed_slot",
]
const META_BOOL_FIELDS: Array = ["development_player", "foreign_player"]
const ARRAY_FIELDS: Array = ["allowed_slots", "preferred_slots"]
const FLAT_DICT_FIELDS: Array = [
	"z_abilities", "raw_abilities", "position_aptitudes", "position_experience",
]
const JSON_DICT_FIELDS: Array = ["source_data"]

const TEAM_META_ORDER: Array = [
	"id", "name", "short_name", "league", "color", "previous_rank", "funds", "auto_lineup",
]


# ---- Players ----

static func write_players(path: String, player_dicts: Array) -> bool:
	var flat_keys: Dictionary = _collect_flat_keys(player_dicts)
	var columns: Array = _player_columns(flat_keys)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSPlayerCsvIo.write_players: cannot open %s" % path)
		return false
	file.store_csv_line(PackedStringArray(columns))
	for row_value in player_dicts:
		var row: Dictionary = row_value as Dictionary
		file.store_csv_line(PackedStringArray(_player_row_cells(row, columns, flat_keys)))
	return true


static func read_players(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("PSPlayerCsvIo.read_players: missing %s" % path)
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSPlayerCsvIo.read_players: cannot open %s" % path)
		return []
	var header: PackedStringArray = file.get_csv_line()
	var columns: Array = []
	for h in header:
		columns.append(str(h))
	var rows: Array = []
	while not file.eof_reached():
		var cells: PackedStringArray = file.get_csv_line()
		if cells.size() == 1 and str(cells[0]).is_empty():
			continue
		rows.append(_player_dict_from_cells(columns, cells))
	return rows


static func _collect_flat_keys(player_dicts: Array) -> Dictionary:
	var result: Dictionary = {}
	for field in FLAT_DICT_FIELDS:
		result[field] = {}
	for row_value in player_dicts:
		var row: Dictionary = row_value as Dictionary
		for field in FLAT_DICT_FIELDS:
			var d: Variant = row.get(field, {})
			if d is Dictionary:
				for key in (d as Dictionary).keys():
					(result[field] as Dictionary)[str(key)] = true
	return result


static func _player_columns(flat_keys: Dictionary) -> Array:
	var columns: Array = META_ORDER.duplicate()
	columns.append_array(ARRAY_FIELDS)
	for field in FLAT_DICT_FIELDS:
		var keys: Array = (flat_keys[field] as Dictionary).keys()
		keys.sort()
		for key in keys:
			columns.append("%s.%s" % [field, str(key)])
	for field in JSON_DICT_FIELDS:
		columns.append("%s_json" % field)
	return columns


static func _player_row_cells(row: Dictionary, columns: Array, _flat_keys: Dictionary) -> Array:
	var cells: Array = []
	for column_value in columns:
		var column: String = str(column_value)
		cells.append(_player_cell_value(row, column))
	return cells


static func _player_cell_value(row: Dictionary, column: String) -> String:
	if column.ends_with("_json"):
		var field: String = column.substr(0, column.length() - 5)
		var d: Variant = row.get(field, {})
		return JSON.stringify(d if d is Dictionary else {})
	var dot: int = column.find(".")
	if dot >= 0:
		var group: String = column.substr(0, dot)
		var key: String = column.substr(dot + 1)
		var gd: Variant = row.get(group, {})
		if gd is Dictionary and (gd as Dictionary).has(key):
			return _num_to_str((gd as Dictionary)[key])
		return ""
	if ARRAY_FIELDS.has(column):
		var arr: Variant = row.get(column, [])
		if arr is Array:
			var parts: Array = []
			for x in (arr as Array):
				parts.append(str(int(x)))
			return ";".join(parts)
		return ""
	if META_BOOL_FIELDS.has(column):
		return "true" if bool(row.get(column, false)) else "false"
	if META_INT_FIELDS.has(column):
		return str(int(row.get(column, 0)))
	return str(row.get(column, ""))


static func _player_dict_from_cells(columns: Array, cells: PackedStringArray) -> Dictionary:
	var data: Dictionary = {}
	for field in FLAT_DICT_FIELDS:
		data[field] = {}
	for i in range(columns.size()):
		if i >= cells.size():
			break
		var column: String = str(columns[i])
		var cell: String = str(cells[i])
		if column.ends_with("_json"):
			var field: String = column.substr(0, column.length() - 5)
			var parsed: Variant = JSON.parse_string(cell) if not cell.is_empty() else {}
			data[field] = parsed if parsed is Dictionary else {}
			continue
		var dot: int = column.find(".")
		if dot >= 0:
			if cell.is_empty():
				continue
			var group: String = column.substr(0, dot)
			var key: String = column.substr(dot + 1)
			if not data.has(group):
				data[group] = {}
			(data[group] as Dictionary)[key] = float(cell)
			continue
		if ARRAY_FIELDS.has(column):
			data[column] = _parse_int_array(cell)
			continue
		if META_BOOL_FIELDS.has(column):
			data[column] = cell == "true"
			continue
		if META_INT_FIELDS.has(column):
			data[column] = int(cell) if not cell.is_empty() else 0
			continue
		data[column] = cell
	return data


static func _parse_int_array(cell: String) -> Array:
	var result: Array = []
	if cell.is_empty():
		return result
	for part in cell.split(";", false):
		result.append(int(part))
	return result


static func _num_to_str(value: Variant) -> String:
	if value is float:
		var f: float = value as float
		if f == floor(f) and absf(f) < 1.0e15:
			return str(int(f))
		return str(f)
	if value is int:
		return str(value)
	return str(value)


# ---- Teams ----

static func write_teams(path: String, team_dicts: Array) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSPlayerCsvIo.write_teams: cannot open %s" % path)
		return false
	file.store_csv_line(PackedStringArray(TEAM_META_ORDER))
	for row_value in team_dicts:
		var row: Dictionary = row_value as Dictionary
		var cells: Array = []
		for column_value in TEAM_META_ORDER:
			var column: String = str(column_value)
			match column:
				"auto_lineup":
					cells.append("true" if bool(row.get(column, true)) else "false")
				"id", "previous_rank", "funds":
					cells.append(str(int(row.get(column, 0))))
				_:
					cells.append(str(row.get(column, "")))
		file.store_csv_line(PackedStringArray(cells))
	return true


static func read_teams(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("PSPlayerCsvIo.read_teams: missing %s" % path)
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSPlayerCsvIo.read_teams: cannot open %s" % path)
		return []
	var header: PackedStringArray = file.get_csv_line()
	var columns: Array = []
	for h in header:
		columns.append(str(h))
	var rows: Array = []
	while not file.eof_reached():
		var cells: PackedStringArray = file.get_csv_line()
		if cells.size() == 1 and str(cells[0]).is_empty():
			continue
		var data: Dictionary = {}
		for i in range(columns.size()):
			if i >= cells.size():
				break
			var column: String = str(columns[i])
			var cell: String = str(cells[i])
			match column:
				"auto_lineup":
					data[column] = cell == "true"
				"id", "previous_rank", "funds":
					data[column] = int(cell) if not cell.is_empty() else 0
				_:
					data[column] = cell
		rows.append(data)
	return rows
