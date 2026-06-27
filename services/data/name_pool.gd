extends RefCounted
class_name NamePool

# 新規生成選手の名前プール。
# CSV は category,name の2列で、mod が player_names を差し替えれば同じ API で別名簿を使える。
const CSV_PATH: String = "res://data/player_names.csv"

static var _loaded: bool = false
static var _surnames: PackedStringArray = PackedStringArray()
static var _given_names: PackedStringArray = PackedStringArray()
static var _foreign_names: PackedStringArray = PackedStringArray()


# 初回だけ CSV を読み、カテゴリ別配列へ分ける。読み込み失敗時はフォールバック名で生成を継続する。
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


# 日本人名は surname + given_name を独立に抽選して組み合わせる。
static func pick_japanese_name() -> String:
	ensure_loaded()
	var surname: String = "佐藤"
	var given: String = "翔"
	if _surnames.size() > 0:
		surname = _surnames[Rng.range_int(0, _surnames.size() - 1)]
	if _given_names.size() > 0:
		given = _given_names[Rng.range_int(0, _given_names.size() - 1)]
	return "%s %s" % [surname, given]


# 外国人名は1セルに完成名を入れる。名簿が無い場合だけ Smith を返す。
static func pick_foreign_name() -> String:
	ensure_loaded()
	if _foreign_names.size() == 0:
		return "Smith"
	return _foreign_names[Rng.range_int(0, _foreign_names.size() - 1)]
