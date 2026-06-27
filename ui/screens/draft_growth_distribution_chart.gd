extends Control
class_name DraftGrowthDistributionChart

# ドラフト成長曲線画面の overall 分布グラフ。
# bins は {overall, count} の配列で、p10/p50/p90/mean などの stats があれば縦マーカーを描く。
var bins: Array = []
var title_text: String = ""
var subtitle_text: String = ""
var empty_message: String = "年齢セルを選択すると分布グラフを表示します"
var stats: Dictionary = {}


# 新しい分布をセットし、overall 昇順に並べてから再描画する。
func set_distribution(new_bins: Array, new_title: String, new_subtitle: String, new_stats: Dictionary = {}) -> void:
	bins = new_bins.duplicate(true)
	bins.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("overall", 0)) < int((b as Dictionary).get("overall", 0))
	)
	title_text = new_title
	subtitle_text = new_subtitle
	stats = new_stats.duplicate(true)
	queue_redraw()


# データが無い状態のメッセージへ戻す。
func clear_message(message: String) -> void:
	bins = []
	title_text = ""
	subtitle_text = ""
	stats = {}
	empty_message = message
	queue_redraw()


# 棒グラフ本体。横軸は overall、縦軸は人数。中央値の棒だけ色を少し変える。
func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.07, 0.08, 0.10), true)
	if bins.is_empty():
		_draw_empty_state(rect)
		return

	var left: float = 62.0
	var right: float = 24.0
	var top: float = 54.0
	var bottom: float = 50.0
	var plot: Rect2 = Rect2(left, top, max(1.0, size.x - left - right), max(1.0, size.y - top - bottom))

	var min_overall: int = int((bins[0] as Dictionary).get("overall", 0))
	var max_overall: int = min_overall
	var max_count: int = 1
	for bin_value in bins:
		var bin: Dictionary = bin_value as Dictionary
		min_overall = min(min_overall, int(bin.get("overall", 0)))
		max_overall = max(max_overall, int(bin.get("overall", 0)))
		max_count = max(max_count, int(bin.get("count", 0)))
	var domain_count: int = max(1, max_overall - min_overall + 1)
	var step_x: float = plot.size.x / float(domain_count)
	var bar_width: float = max(2.0, step_x - 1.0)

	var axis_color: Color = Color(0.50, 0.55, 0.64)
	var grid_color: Color = Color(0.18, 0.20, 0.24)
	var bar_color: Color = Color(0.30, 0.58, 1.0)
	var bar_highlight: Color = Color(0.42, 0.70, 1.0)
	var font: Font = ThemeDB.fallback_font
	var font_size: int = 13

	for index in range(5):
		var t: float = float(index) / 4.0
		var y_line: float = plot.position.y + plot.size.y * t
		draw_line(Vector2(plot.position.x, y_line), Vector2(plot.position.x + plot.size.x, y_line), grid_color, 1.0)
		var label_value: int = int(round(float(max_count) * (1.0 - t)))
		draw_string(font, Vector2(8.0, y_line + 4.0), str(label_value), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_line(Vector2(plot.position.x, plot.position.y + plot.size.y), Vector2(plot.position.x + plot.size.x, plot.position.y + plot.size.y), axis_color, 1.0)
	draw_line(plot.position, Vector2(plot.position.x, plot.position.y + plot.size.y), axis_color, 1.0)

	for bin_value in bins:
		var bin: Dictionary = bin_value as Dictionary
		var overall: int = int(bin.get("overall", 0))
		var count: int = int(bin.get("count", 0))
		if count <= 0:
			continue
		var x: float = plot.position.x + float(overall - min_overall) * step_x + max(0.0, (step_x - bar_width) * 0.5)
		var h: float = float(count) / float(max_count) * plot.size.y
		var bar_rect: Rect2 = Rect2(Vector2(x, plot.position.y + plot.size.y - h), Vector2(bar_width, h))
		draw_rect(bar_rect, bar_highlight if overall == int(round(float(stats.get("p50", -9999.0)))) else bar_color, true)

	_draw_marker(plot, min_overall, max_overall, float(stats.get("mean", NAN)), Color(0.98, 0.78, 0.25), "AVG")
	_draw_marker(plot, min_overall, max_overall, float(stats.get("p10", NAN)), Color(0.43, 0.86, 0.62), "P10")
	_draw_marker(plot, min_overall, max_overall, float(stats.get("p50", NAN)), Color(0.93, 0.42, 0.42), "P50")
	_draw_marker(plot, min_overall, max_overall, float(stats.get("p90", NAN)), Color(0.43, 0.86, 0.62), "P90")

	draw_string(font, Vector2(16.0, 22.0), title_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(0.88, 0.91, 0.96))
	draw_string(font, Vector2(16.0, 42.0), subtitle_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.68, 0.73, 0.80))
	draw_string(font, Vector2(plot.position.x, size.y - 16.0), "%d" % min_overall, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(plot.position.x + plot.size.x - 36.0, size.y - 16.0), "%d" % max_overall, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, axis_color)
	draw_string(font, Vector2(plot.position.x + plot.size.x * 0.5 - 42.0, size.y - 16.0), "overall", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.75, 0.79, 0.86))
	draw_string(font, Vector2(8.0, plot.position.y - 8.0), "count", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.75, 0.79, 0.86))


# 平均や分位点を縦線で表示する。表示範囲外や NAN は描かない。
func _draw_marker(plot: Rect2, min_overall: int, max_overall: int, value: float, color: Color, label: String) -> void:
	if is_nan(value):
		return
	if value < float(min_overall) or value > float(max_overall):
		return
	var domain_count: float = max(1.0, float(max_overall - min_overall + 1))
	var x: float = plot.position.x + (value - float(min_overall) + 0.5) / domain_count * plot.size.x
	draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), color, 2.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(x + 4.0, plot.position.y + 14.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, color)


func _draw_empty_state(rect: Rect2) -> void:
	var font: Font = ThemeDB.fallback_font
	draw_string(font, rect.position + Vector2(18.0, 34.0), empty_message, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color(0.70, 0.74, 0.80))
