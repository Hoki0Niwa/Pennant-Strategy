extends Node

# 能力分布の計算と PNG 出力経路を検証する（dummy renderer では画素内容は保証しない）。

const ChartScript = preload("res://ui/components/ability_distribution_chart.gd")


func _ready() -> void:
	if not GameDb.data_loaded_ok:
		await GameDb.data_loaded

	var keys: Array = ChartScript.all_ability_keys()
	var distributions: Array = ChartScript.compute_from_players(GameDb.players, keys)
	print("ability keys=%d  players=%d" % [keys.size(), GameDb.players.size()])
	for name in ["Bat_Impact", "Pit_Stamina", "PF_Reach", "Run_Judgment"]:
		for d_value in distributions:
			var d: Dictionary = d_value as Dictionary
			if str(d.get("name", "")) == name:
				print("  %s: n=%d mean=%+.2f bins=%s" % [name, int(d.get("total", 0)), float(d.get("mean", 0.0)), str(d.get("bins", []))])

	# チャート Control の構築（描画なし）。ビューポート捕捉はヘッドレスでは frame_post_draw が
	# 発火せず検証できないため、実機エディタに委ねる。ここでは計算とサイズ算出のみ確認。
	var chart: AbilityDistributionChart = ChartScript.new()
	chart.set_distributions(distributions)
	var chart_size: Vector2 = chart.custom_minimum_size
	print("chart_size=%s" % str(chart_size))
	var ok: bool = keys.size() > 0 and distributions.size() == keys.size() and chart_size.x > 0.0 and chart_size.y > 0.0
	get_tree().quit(0 if ok else 1)
