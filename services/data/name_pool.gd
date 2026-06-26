extends RefCounted
class_name NamePool

const CSV_PATH: String = "res://data/player_names.csv"

static var _loaded: bool = false
static var _surnames: PackedStringArray = PackedStringArray()
static var _given_names: PackedStringArray = PackedStringArray()
static var _foreign_names: PackedStringArray = PackedStringArray()


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_surnames.clear()
	_given_names.clear()
	_foreign_names.clear()

	var csv_path: String = ModManager.resolve_data_path("player_names", CSV_PATH)
	if not FileAccess.file_exists(csv_path):
		push_error("Name CSV not found: %s" % csv_path)
		return

	var file: FileAccess = FileAccess.open(csv_path, FileAccess.READ)
	if file == null:
		push_error("Could not open name CSV: %s" % csv_path)
		return

	while not file.eof_reached():
		var line: String = file.get_line()
		if line.is_empty():
			continue
		var parts: PackedStringArray = line.split(",", false, 2)
		if parts.size() < 2:
			continue
		var category: String = parts[0].strip_edges()
		var name_text: String = parts[1].strip_edges()
		if name_text.is_empty():
			continue
		match category:
			"surname": _surnames.append(name_text)
			"given_name": _given_names.append(name_text)
			"foreign": _foreign_names.append(name_text)


static func pick_japanese_name() -> String:
	ensure_loaded()
	var surname: String = "佐藤"
	var given: String = "翔"
	if _surnames.size() > 0:
		surname = _surnames[Rng.range_int(0, _surnames.size() - 1)]
	if _given_names.size() > 0:
		given = _given_names[Rng.range_int(0, _given_names.size() - 1)]
	return "%s %s" % [surname, given]


static func pick_foreign_name() -> String:
	ensure_loaded()
	if _foreign_names.size() == 0:
		return "Smith"
	return _foreign_names[Rng.range_int(0, _foreign_names.size() - 1)]
