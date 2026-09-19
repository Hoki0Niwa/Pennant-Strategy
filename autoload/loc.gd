extends Node

# 表示文言の辞書。コード中の文言はキー ("options.title" 等) で引き、実文は言語ごとの
# data/strings/<locale>.json (キー → 文言のフラットな object) に置く。
# mod は manifest の "strings": {"<locale>": "<path>"} で同じ形式の JSON を重ね、同じキーを後勝ちで上書きする。
# 現在の言語に無いキーは BASE_LOCALE の文言、それも無ければキー文字列そのものを返す (画面上で欠落が見える)。
const BASE_LOCALE: String = "ja"
const STRINGS_DIR: String = "res://data/strings"

var _locale: String = BASE_LOCALE
var _table: Dictionary = {}


func _ready() -> void:
	ModManager.mods_reloaded.connect(reload)
	reload()


func locale() -> String:
	return _locale


# 言語を切り替えて辞書を組み直す。再描画は呼び出し側の責任。
func set_locale(new_locale: String) -> void:
	_locale = new_locale if not new_locale.is_empty() else BASE_LOCALE
	reload()


# 基底言語 → 現在言語の順に、それぞれ本体 → mod (load order 順) を重ねる。
# シミュレーション中のワーカースレッドからも t() が読まれるので、完成した辞書を一度だけ差し替える。
func reload() -> void:
	var table: Dictionary = _locale_table(BASE_LOCALE)
	if _locale != BASE_LOCALE:
		table.merge(_locale_table(_locale), true)
	_table = table


# key の文言を返す。params を渡すと文言中の {name} を params["name"] で置き換える。
func t(key: String, params: Dictionary = {}) -> String:
	var text: String = str(_table.get(key, key))
	return text if params.is_empty() else text.format(params)


func has_key(key: String) -> bool:
	return _table.has(key)


func _locale_table(target_locale: String) -> Dictionary:
	var table: Dictionary = {}
	var paths: Array[String] = ["%s/%s.json" % [STRINGS_DIR, target_locale]]
	paths.append_array(ModManager.string_table_paths(target_locale))
	for path in paths:
		table.merge(_read_string_table(path), true)
	return table


# 値が文字列でないエントリは捨てて警告する (数値や入れ子の object はキーとして引けないため)。
func _read_string_table(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("String table must be a JSON object: %s" % path)
		return {}
	var table: Dictionary = {}
	var source: Dictionary = parsed as Dictionary
	for key_value in source.keys():
		var value: Variant = source[key_value]
		if value is String:
			table[str(key_value)] = value
		else:
			push_warning("String table entry '%s' is not a string: %s" % [key_value, path])
	return table
