extends RefCounted

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")

# 年度一覧だけを常駐させ、本文は閲覧した年と未保存の年だけ保持する。
var _table: String
var _index: Dictionary = {}
var _cache: Dictionary = {}
var _dirty: Dictionary = {}
var _replace_all: bool = false


func _init(table: String) -> void:
	_table = table


func reset(from_disk: bool = false) -> bool:
	_index.clear()
	_cache.clear()
	_dirty.clear()
	_replace_all = not from_disk
	if from_disk and SQLiteStoreService.is_available() and not SQLiteStoreService.runtime_db_path().is_empty():
		var result: Dictionary = SQLiteStoreService.try_load_annual_history_index(_table)
		if not bool(result["ok"]):
			return false
		for row in result["rows"]:
			_index[_key(int(row.year), int(row.season_number))] = row.duplicate(true)
	return true


func add(payload: Dictionary) -> bool:
	var key: String = _key(int(payload.year), int(payload.season_number))
	if _index.has(key):
		return false
	_cache[key] = payload.duplicate(true)
	_index[key] = {
		"year": int(payload.year), "season_number": int(payload.season_number),
		"format_version": int(payload.get("format_version", 1)),
	}
	_dirty[key] = true
	return true


func entries() -> Array:
	var result: Array = _index.values().duplicate(true)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.year) < int(b.year) if int(a.year) != int(b.year) else int(a.season_number) < int(b.season_number))
	return result


func get_snapshot(year: int, season_number: int) -> Dictionary:
	var key: String = _key(year, season_number)
	if not _index.has(key):
		return {}
	if not _cache.has(key):
		var payload: Dictionary = SQLiteStoreService.load_annual_history(_table, year, season_number)
		if payload.is_empty():
			return {}
		_cache[key] = payload
	return (_cache[key] as Dictionary).duplicate(true)


# 明示的なシミュレーションの退避・復元だけが全年度の本文を必要とする。
func snapshot() -> Array:
	var result: Array = []
	for entry in entries():
		result.append(get_snapshot(int(entry.year), int(entry.season_number)))
	return result


func restore(rows: Array) -> void:
	reset()
	for row in rows:
		add(row as Dictionary)


func pending_changes() -> Dictionary:
	if not is_dirty():
		return {}
	var rows: Array = []
	for key in _dirty:
		rows.append((_cache[key] as Dictionary).duplicate(true))
	return {"rows": rows, "replace_all": _replace_all}


func is_dirty() -> bool:
	return _replace_all or not _dirty.is_empty()


func acknowledge() -> void:
	_dirty.clear()
	_replace_all = false


func _key(year: int, season_number: int) -> String:
	return "%d:%d" % [year, season_number]
