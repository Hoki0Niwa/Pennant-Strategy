extends Tree

# ボックススコア専用グリッド。SortableTable と違い per-cell 背景色(安打=赤)に対応。
# 列 = [守備, 選手名, (利), 打数, 安打, 打点, 通算率, HR, 1..inning_count]
# set_box_score(PSBoxScoreBuilder.build(...)) で {rows, totals, inning_count} を受ける。

const HIT_BG: Color = Color(0.86, 0.20, 0.18, 0.90)
const HIT_FG: Color = Color(1, 1, 1)
const TOTAL_FG: Color = Color(0.74, 0.79, 0.85)

const FIXED_TITLES: Array = ["守備", "選手名", "", "打数", "安打", "打点", "通算率", "HR"]
const FIXED_WIDTHS: Array = [64, 110, 36, 48, 48, 48, 60, 40]

var _inning_count: int = 9
var _rows: Array = []
var _totals: Dictionary = {}
var _ready_done: bool = false


func _init() -> void:
	hide_root = true
	column_titles_visible = true
	select_mode = Tree.SELECT_ROW
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_ready_done = true
	_render()


func set_box_score(data: Dictionary) -> void:
	_inning_count = max(9, int(data.get("inning_count", 9)))
	_rows = data.get("rows", []) as Array
	_totals = data.get("totals", {}) as Dictionary
	_render()


func clear_box_score() -> void:
	_rows = []
	_totals = {}
	_render()


func _configure_columns() -> void:
	columns = FIXED_TITLES.size() + _inning_count
	for i in range(FIXED_TITLES.size()):
		set_column_title(i, str(FIXED_TITLES[i]))
		set_column_expand(i, false)
		set_column_custom_minimum_width(i, int(FIXED_WIDTHS[i]))
		set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_CENTER)
	for n in range(_inning_count):
		var col: int = FIXED_TITLES.size() + n
		set_column_title(col, str(n + 1))
		set_column_expand(col, true)
		set_column_custom_minimum_width(col, 44)
		set_column_title_alignment(col, HORIZONTAL_ALIGNMENT_CENTER)


func _render() -> void:
	if not _ready_done:
		return
	clear()
	_configure_columns()
	var root: TreeItem = create_item()
	var fixed: int = FIXED_TITLES.size()
	for row_value in _rows:
		var row: Dictionary = row_value as Dictionary
		var item: TreeItem = create_item(root)
		item.set_text(0, str(row.get("pos", "")))
		item.set_text(1, str(row.get("name", "")))
		var bats: String = str(row.get("bats", ""))
		item.set_text(2, "(%s)" % bats if not bats.is_empty() else "")
		item.set_text(3, str(int(row.get("ab", 0))))
		item.set_text(4, str(int(row.get("h", 0))))
		item.set_text(5, str(int(row.get("rbi", 0))))
		item.set_text(6, _fmt_avg(float(row.get("avg", 0.0))))
		item.set_text(7, str(int(row.get("hr", 0))))
		for i in range(3, 8):
			item.set_text_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)
		var cells: Array = row.get("cells", []) as Array
		for n in range(_inning_count):
			var col: int = fixed + n
			item.set_text_alignment(col, HORIZONTAL_ALIGNMENT_CENTER)
			if n < cells.size():
				var cell: Dictionary = cells[n] as Dictionary
				item.set_text(col, str(cell.get("text", "")))
				if bool(cell.get("is_hit", false)):
					item.set_custom_bg_color(col, HIT_BG)
					item.set_custom_color(col, HIT_FG)
	if not _totals.is_empty():
		var t: TreeItem = create_item(root)
		t.set_text(0, "計")
		t.set_text(1, "併殺%d" % int(_totals.get("gidp", 0)))
		t.set_text(3, str(int(_totals.get("ab", 0))))
		t.set_text(4, str(int(_totals.get("h", 0))))
		t.set_text(5, str(int(_totals.get("rbi", 0))))
		t.set_text(6, _fmt_avg(float(_totals.get("avg", 0.0))))
		t.set_text(7, str(int(_totals.get("hr", 0))))
		for i in range(3, 8):
			t.set_text_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)
		for i in range(fixed + _inning_count):
			t.set_custom_color(i, TOTAL_FG)


func _fmt_avg(value: float) -> String:
	var s: String = "%0.3f" % value
	if s.begins_with("0"):
		s = s.substr(1)
	return s
