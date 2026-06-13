extends Control
class_name AbilityDistributionChart

# z 能力値の分布(ヒストグラム)をグリッド描画する。画面表示と PNG 出力の両方に使う。
# 各セル = 1 能力。z 範囲 [Z_MIN, Z_MAX] を BINS 個に区切った度数を棒で描く。

const COLS: int = 6
const CELL_W: float = 152.0
const CELL_H: float = 108.0
const PAD: float = 10.0
const Z_MIN: float = -3.5
const Z_MAX: float = 3.5
const BINS: int = 14

var distributions: Array = []  # [{name, bins:Array[int], total:int, mean:float}]


func set_distributions(values: Array) -> void:
	distributions = values
	var rows: int = int(ceil(float(max(1, distributions.size())) / float(COLS)))
	custom_minimum_size = Vector2(float(COLS) * CELL_W + PAD * 2.0, float(rows) * CELL_H + PAD * 2.0)
	size = custom_minimum_size
	queue_redraw()


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.10, 0.13))
	for i in range(distributions.size()):
		var col: int = i % COLS
		@warning_ignore("integer_division")
		var row: int = int(i / COLS)
		var ox: float = PAD + float(col) * CELL_W
		var oy: float = PAD + float(row) * CELL_H
		_draw_cell(font, ox, oy, distributions[i] as Dictionary)


func _draw_cell(font: Font, ox: float, oy: float, d: Dictionary) -> void:
	var ability_name: String = str(d.get("name", ""))
	var bins: Array = d.get("bins", []) as Array
	var total: int = int(d.get("total", 0))
	var mean: float = float(d.get("mean", 0.0))

	var chart_x: float = ox + 4.0
	var chart_y: float = oy + 18.0
	var chart_w: float = CELL_W - 12.0
	var chart_h: float = CELL_H - 38.0

	draw_rect(Rect2(ox + 2.0, oy + 16.0, CELL_W - 8.0, CELL_H - 32.0), Color(0.14, 0.15, 0.18))
	draw_string(font, Vector2(ox + 4.0, oy + 12.0), ability_name, HORIZONTAL_ALIGNMENT_LEFT, CELL_W - 8.0, 11, Color(0.86, 0.90, 0.94))

	var max_count: int = 1
	for c in bins:
		max_count = max(max_count, int(c))

	# z=0 の基準線
	var zero_ratio: float = (0.0 - Z_MIN) / (Z_MAX - Z_MIN)
	var zero_x: float = chart_x + chart_w * zero_ratio
	draw_line(Vector2(zero_x, chart_y), Vector2(zero_x, chart_y + chart_h), Color(0.45, 0.47, 0.52), 1.0)

	var bar_w: float = chart_w / float(bins.size())
	for bi in range(bins.size()):
		var h: float = chart_h * float(int(bins[bi])) / float(max_count)
		var x: float = chart_x + float(bi) * bar_w
		var y: float = chart_y + (chart_h - h)
		draw_rect(Rect2(x, y, max(1.0, bar_w - 1.0), h), Color(0.36, 0.62, 0.92))

	draw_string(font, Vector2(ox + 4.0, oy + CELL_H - 6.0), "μ=%+.2f  n=%d" % [mean, total], HORIZONTAL_ALIGNMENT_LEFT, CELL_W - 8.0, 9, Color(0.66, 0.70, 0.74))


# GameDb.players(PSPlayer 配列)から、指定 z キー群の分布を計算する。
# 各キーは「その能力を持つ選手」のみ集計する。
static func compute_from_players(players: Array, keys: Array) -> Array:
	var result: Array = []
	var bin_width: float = (Z_MAX - Z_MIN) / float(BINS)
	for key_value in keys:
		var key: String = str(key_value)
		var bins: Array = []
		bins.resize(BINS)
		bins.fill(0)
		var total: int = 0
		var sum: float = 0.0
		for player_value in players:
			var player: PSPlayer = player_value as PSPlayer
			if player == null or not player.z_abilities.has(key):
				continue
			var z: float = player.z_ability(key, 0.0)
			total += 1
			sum += z
			var idx: int = int(floor((z - Z_MIN) / bin_width))
			idx = clampi(idx, 0, BINS - 1)
			bins[idx] = int(bins[idx]) + 1
		result.append({
			"name": key,
			"bins": bins,
			"total": total,
			"mean": (sum / float(total)) if total > 0 else 0.0,
		})
	return result


# Z_ABILITY_GROUPS をフラット化した全 z キー(描画順)を返す。
static func all_ability_keys() -> Array:
	var keys: Array = []
	for group_value in PSPlayer.Z_ABILITY_GROUPS.values():
		var group: Dictionary = group_value as Dictionary
		for key_value in group.keys():
			keys.append(str(key_value))
	return keys
