extends Control
class_name PlayerProbeChart

# player_probe_screen の簡易折れ線グラフ。
# points は {x, y} の配列で、能力値スイープなどの単純な関係を見るために使う。
var points: Array = []
var x_label: String = ""
var y_label: String = ""


# データを差し替えて再描画する。描画時に min/max を毎回求めるので、ここでは整形しない。
func set_data(new_points: Array, new_x_label: String, new_y_label: String) -> void:
	points = new_points.duplicate(true)
	x_label = new_x_label
	y_label = new_y_label
	queue_redraw()


# 背景、軸、グリッド、折れ線、端点ラベルを直接描画する。
# 同一 x/y だけのデータでも 0 除算しないよう、範囲が潰れた軸は +1 して広げる。
func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.07, 0.08, 0.10), true)
	if points.size() < 2:
		_draw_empty_state(rect)
		return

	var left: float = 56.0
	var right: float = 18.0
	var top: float = 28.0
	var bottom: float = 48.0
	var plot: Rect2 = Rect2(left, top, max(1.0, size.x - left - right), max(1.0, size.y - top - bottom))

	var min_x: float = float((points[0] as Dictionary).get("x", 0.0))
	var max_x: float = min_x
	var min_y: float = float((points[0] as Dictionary).get("y", 0.0))
	var max_y: float = min_y
	for point_value in points:
		var point: Dictionary = point_value as Dictionary
		var x: float = float(point.get("x", 0.0))
		var y: float = float(point.get("y", 0.0))
		min_x = min(min_x, x)
		max_x = max(max_x, x)
		min_y = min(min_y, y)
		max_y = max(max_y, y)
	if is_equal_approx(max_x, min_x):
		max_x += 1.0
	if is_equal_approx(max_y, min_y):
		max_y += 1.0

	var axis_color: Color = Color(0.50, 0.55, 0.64)
	var grid_color: Color = Color(0.18, 0.20, 0.24)
	var line_color: Color = Color(0.28, 0.55, 1.0)
	for index in range(5):
		var t: float = float(index) / 4.0
		var y_line: float = plot.position.y + plot.size.y * t
		draw_line(Vector2(plot.position.x, y_line), Vector2(plot.position.x + plot.size.x, y_line), grid_color, 1.0)
	draw_line(Vector2(plot.position.x, plot.position.y + plot.size.y), Vector2(plot.position.x + plot.size.x, plot.position.y + plot.size.y), axis_color, 1.0)
	draw_line(plot.position, Vector2(plot.position.x, plot.position.y + plot.size.y), axis_color, 1.0)

	var polyline: PackedVector2Array = PackedVector2Array()
	for point_value in points:
		var point: Dictionary = point_value as Dictionary
		var px: float = plot.position.x + (float(point.get("x", 0.0)) - min_x) / (max_x - min_x) * plot.size.x
		var py: float = plot.position.y + plot.size.y - (float(point.get("y", 0.0)) - min_y) / (max_y - min_y) * plot.size.y
		polyline.append(Vector2(px, py))
	if polyline.size() >= 2:
		draw_polyline(polyline, line_color, 2.5)
	for point in polyline:
		draw_circle(point, 4.0, Color(0.52, 0.72, 1.0))

	var font: Font = ThemeDB.fallback_font
	var font_size: int = 13
	draw_string(font, Vector2(plot.position.x, size.y - 14.0), _format_axis_value(min_x), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(plot.position.x + plot.size.x - 42.0, size.y - 14.0), _format_axis_value(max_x), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(8.0, plot.position.y + plot.size.y), _format_axis_value(min_y), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(8.0, plot.position.y + 10.0), _format_axis_value(max_y), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(plot.position.x + plot.size.x * 0.5 - 52.0, size.y - 14.0), x_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.75, 0.79, 0.86))
	draw_string(font, Vector2(8.0, 18.0), y_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.75, 0.79, 0.86))


func _draw_empty_state(rect: Rect2) -> void:
	var font: Font = ThemeDB.fallback_font
	draw_string(font, rect.position + Vector2(18.0, 34.0), "能力値を複数指定して実行するとグラフを表示します", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color(0.70, 0.74, 0.80))


# 軸ラベルは大きい値なら整数、小さい値なら小数3桁で出す。
func _format_axis_value(value: float) -> String:
	if abs(value) >= 10.0:
		return "%0.0f" % value
	return "%0.3f" % value
