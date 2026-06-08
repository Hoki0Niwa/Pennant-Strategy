extends Node

# SortableTable 共通部品 + 変換した一覧画面のスモークテスト。
# .tscn 経由でシーンとして起動するため autoload (AppState/GameDb/RecordStore) が読まれる。
#
# 実行: godot --headless --path . tools/run_sortable_table_smoke.tscn

const SortableTable = preload("res://ui/components/sortable_table.gd")

const SCREEN_PATHS: Array = [
	"res://ui/screens/home_screen.gd",
	"res://ui/screens/standings_screen.gd",
	"res://ui/screens/rankings_screen.gd",
	"res://ui/screens/team_detail_screen.gd",
	"res://ui/screens/active_roster_screen.gd",
	"res://ui/screens/lineup_editor_screen.gd",
	"res://ui/screens/rotation_editor_screen.gd",
	"res://ui/screens/player_detail_screen.gd",
	"res://ui/screens/history_screen.gd",
	"res://ui/screens/game_result_screen.gd",
	"res://ui/screens/postseason_screen.gd",
	"res://ui/screens/offseason_screen.gd",
]


func _ready() -> void:
	var failures: Array = []
	print("=== sortable_table smoke ===")

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	failures.append_array(_test_component())
	failures.append_array(_test_screens_build())

	if failures.is_empty():
		print("RESULT: OK")
		get_tree().quit(0)
	else:
		for f in failures:
			print("FAIL: %s" % f)
		print("RESULT: FAIL (%d)" % failures.size())
		get_tree().quit(1)


func _test_component() -> Array:
	var failures: Array = []
	var table: Tree = SortableTable.new()
	add_child(table)

	table.configure([
		{"title": "順", "key": "rank", "width": 40, "type": "number", "format": "int"},
		{"title": "名", "key": "name", "width": 80, "type": "string", "format": "string"},
		{"title": "率", "key": "avg", "width": 60, "type": "number", "format": "rate"},
	])
	table.set_rows([
		{"rank": 2, "name": "B", "avg": 0.300, "__meta": 11},
		{"rank": 1, "name": "A", "avg": 0.250, "__meta": 22},
		{"rank": 3, "name": "C", "avg": 0.275, "__meta": 33},
	])

	if table.columns != 3:
		failures.append("columns count wrong: %d" % table.columns)

	table.set_default_sort(2, false)  # avg 降順 → B(.300)
	var first: TreeItem = _first_row(table)
	if first == null:
		failures.append("no rows rendered")
	else:
		if first.get_text(1) != "B":
			failures.append("avg desc sort failed: first=%s" % first.get_text(1))
		if first.get_text(2) != "0.300":
			failures.append("rate format failed: %s" % first.get_text(2))
		if int(first.get_metadata(0)) != 11:
			failures.append("meta on row failed")

	table.set_default_sort(0, true)  # rank 昇順 → A
	first = _first_row(table)
	if first != null and first.get_text(1) != "A":
		failures.append("rank asc sort failed: first=%s" % first.get_text(1))

	if first != null:
		first.select(0)
		var meta: Variant = table.get_selected_meta()
		if meta == null or int(meta) != 22:
			failures.append("get_selected_meta failed: %s" % str(meta))

	# sortable=false での再 configure (game_result/postseason が使う経路)
	table.configure([
		{"title": "x", "key": "x", "width": 40, "type": "string", "format": "string"},
	], false)
	table.set_rows([{"x": "a"}, {"x": "b"}])
	if table.columns != 1:
		failures.append("re-configure column count wrong: %d" % table.columns)

	table.queue_free()
	return failures


func _test_screens_build() -> Array:
	var failures: Array = []
	for path in SCREEN_PATHS:
		var script: GDScript = load(path) as GDScript
		if script == null:
			failures.append("load failed: %s" % path)
			continue
		var screen: Node = script.new() as Node
		if screen == null:
			failures.append("instantiate failed: %s" % path)
			continue
		# add_child で _ready/_build が走り、SortableTable の configure 等を実行する。
		add_child(screen)
		print("  built: %s" % path.get_file())
		screen.queue_free()
	return failures


func _first_row(table: Tree) -> TreeItem:
	var root: TreeItem = table.get_root()
	if root == null:
		return null
	return root.get_first_child()
