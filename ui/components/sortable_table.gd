extends Tree

# 汎用ソート可能テーブル部品。
#
# ゲーム内の一覧表示は従来 ItemList / RichTextLabel に半角スペースで整形した
# 1 本の文字列を入れていたため、列がずれて読みづらく、ソートもできなかった。
# 本部品は Godot の Tree ノードを使い、
#   - 列ごとに整列した表示
#   - 列ヘッダクリックでの昇順/降順ソート (balance_report_screen と同挙動)
#   - 行ダブルクリックでの遷移 (row_activated シグナル)
# を共通化する。
#
# 使い方:
#   var table := preload("res://ui/components/sortable_table.gd").new()
#   parent.add_child(table)
#   table.configure(COLUMNS)            # 列定義
#   table.set_default_sort(5, false)    # 既定ソート列/向き (任意)
#   table.set_rows(rows)                # 行データ
#   table.row_activated.connect(func(meta): ...)  # 行ダブルクリック (任意)
#
# 列定義 (Array[Dictionary]):
#   { "title": 表示名,
#     "key":   row dict のキー,
#     "width": 最小幅(px),
#     "type":  "number" | "string"  (ソート比較とセル整列に使用),
#     "format":"int"|"rate"|"float1"|"float2"|"float3"|"z"|"pct1"|"string",
#     "sort_key": (任意) ソート時に使う別キー (表示と数値ソートを分けたいとき) }
#
# 行データ (Array[Dictionary]):
#   key -> 値 を持つ Dictionary。表示は format、ソートは生値+type で行う。
#   特殊キー:
#     "__meta":  行ダブルクリック時に row_activated へ渡す値 (例 player_id)
#     "__color": 行全体の文字色 (Color)。見出し行などの強調に使う。

signal row_activated(meta)

var _columns: Array = []
var _rows: Array = []
var _sort_column: int = -1
var _sort_ascending: bool = true
var _ready_done: bool = false
var _sortable: bool = true


func _init() -> void:
	# プロパティ初期化は _init で行う。_ready で設定すると、生成直後に呼び出し側が
	# size_flags / custom_minimum_size を上書きした内容を _ready が再度クリアして
	# しまうため (画面が壊れて見える原因になっていた)。
	hide_root = true
	column_titles_visible = true
	select_mode = Tree.SELECT_ROW
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if not column_title_clicked.is_connected(_on_title_clicked):
		column_title_clicked.connect(_on_title_clicked)
	if not item_activated.is_connected(_on_item_activated):
		item_activated.connect(_on_item_activated)
	_ready_done = true
	if not _columns.is_empty():
		_apply_columns()
	_render()


func configure(column_defs: Array, sortable: bool = true) -> void:
	_columns = column_defs
	_sortable = sortable
	if _ready_done:
		_apply_columns()


func set_rows(rows: Array) -> void:
	_rows = rows
	_render()


func set_default_sort(column_index: int, ascending: bool) -> void:
	_sort_column = column_index
	_sort_ascending = ascending
	_render()


# 現在選択されている行の __meta を返す (未選択なら null)。
func get_selected_meta() -> Variant:
	var item: TreeItem = get_selected()
	if item == null:
		return null
	return item.get_metadata(0)


# 先頭行 (現在の表示順) の __meta を返す。空なら null。
func get_first_meta() -> Variant:
	var root: TreeItem = get_root()
	if root == null:
		return null
	var first: TreeItem = root.get_first_child()
	if first == null:
		return null
	return first.get_metadata(0)


# 現在の表示順での __meta 配列を返す。
func get_ordered_metas() -> Array:
	var metas: Array = []
	var root: TreeItem = get_root()
	if root == null:
		return metas
	var item: TreeItem = root.get_first_child()
	while item != null:
		metas.append(item.get_metadata(0))
		item = item.get_next()
	return metas


# 指定 __meta を持つ行を選択する。見つかれば true。
func select_meta(meta: Variant) -> bool:
	var root: TreeItem = get_root()
	if root == null:
		return false
	var item: TreeItem = root.get_first_child()
	while item != null:
		if item.get_metadata(0) == meta:
			item.select(0)
			scroll_to_item(item)
			return true
		item = item.get_next()
	return false


func _apply_columns() -> void:
	columns = max(1, _columns.size())
	for i in range(_columns.size()):
		var col: Dictionary = _columns[i] as Dictionary
		set_column_title(i, str(col.get("title", "")))
		# 見出しとセルの寄せは必ず一致させる (数字と文字で寄せが食い違わないように)。
		# 既定は全列左寄せ。列定義で "align" を指定すれば上書きできる。
		set_column_title_alignment(i, _align_of(col))
		set_column_expand(i, true)
		set_column_custom_minimum_width(i, int(col.get("width", 72)))


func _align_of(col: Dictionary) -> int:
	match str(col.get("align", "left")):
		"right":
			return HORIZONTAL_ALIGNMENT_RIGHT
		"center":
			return HORIZONTAL_ALIGNMENT_CENTER
		_:
			return HORIZONTAL_ALIGNMENT_LEFT


func _render() -> void:
	if not _ready_done:
		return
	clear()
	var root: TreeItem = create_item()
	if _columns.is_empty():
		return
	var rows: Array = _sorted_rows(_rows)
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var item: TreeItem = create_item(root)
		for i in range(_columns.size()):
			var col: Dictionary = _columns[i] as Dictionary
			item.set_text(i, _format_cell(row, col))
			item.set_text_alignment(i, _align_of(col))
		if row.has("__meta"):
			item.set_metadata(0, row["__meta"])
		if row.has("__color"):
			var color: Color = row["__color"] as Color
			for i in range(_columns.size()):
				item.set_custom_color(i, color)


func _on_title_clicked(column: int, mouse_button_index: int) -> void:
	if not _sortable:
		return
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if column < 0 or column >= _columns.size():
		return
	if _sort_column == column:
		_sort_ascending = not _sort_ascending
	else:
		# 別の列を初めてクリックしたときは、まず降順で並べる。
		_sort_column = column
		_sort_ascending = false
	_render()


func _on_item_activated() -> void:
	var item: TreeItem = get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta != null:
		row_activated.emit(meta)


func _sorted_rows(rows: Array) -> Array:
	var out: Array = rows.duplicate()
	if _sort_column < 0 or _sort_column >= _columns.size():
		return out
	var col: Dictionary = _columns[_sort_column] as Dictionary
	var key: String = str(col.get("sort_key", col.get("key", "")))
	var type: String = str(col.get("type", "string"))
	var ascending: bool = _sort_ascending
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		var comparison: int = _compare(a as Dictionary, b as Dictionary, key, type)
		if comparison == 0:
			comparison = _compare_tiebreak(a as Dictionary, b as Dictionary)
		if ascending:
			return comparison < 0
		return comparison > 0
	)
	return out


func _compare(left: Dictionary, right: Dictionary, key: String, type: String) -> int:
	if type == "number":
		var left_number: float = float(left.get(key, 0.0))
		var right_number: float = float(right.get(key, 0.0))
		if is_equal_approx(left_number, right_number):
			return 0
		return -1 if left_number < right_number else 1
	var left_text: String = str(left.get(key, "")).to_lower()
	var right_text: String = str(right.get(key, "")).to_lower()
	if left_text == right_text:
		return 0
	return -1 if left_text < right_text else 1


# 安定したタイブレーク。先頭列の値で二次ソートする。
func _compare_tiebreak(left: Dictionary, right: Dictionary) -> int:
	if _columns.is_empty():
		return 0
	var first_key: String = str((_columns[0] as Dictionary).get("key", ""))
	var left_text: String = str(left.get(first_key, ""))
	var right_text: String = str(right.get(first_key, ""))
	if left_text == right_text:
		return 0
	return -1 if left_text < right_text else 1


func _format_cell(row: Dictionary, col: Dictionary) -> String:
	var key: String = str(col.get("key", ""))
	var value: Variant = row.get(key, "")
	match str(col.get("format", "string")):
		"int":
			return str(int(value))
		"rate":
			return "%0.3f" % float(value)
		"float1":
			return "%0.1f" % float(value)
		"float2":
			return "%0.2f" % float(value)
		"float3":
			return "%0.3f" % float(value)
		"z":
			return "%+.2f" % float(value)
		"pct1":
			return "%0.1f%%" % (float(value) * 100.0)
		_:
			return str(value)
