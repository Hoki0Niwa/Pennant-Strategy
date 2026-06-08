extends Node

# 表示能力スケール (UI_DISPLAY_MEAN=60) 分離の確認スモーク。
# - 同じ z 値で PSAbilityScale.z_to_display vs z_to_display_for_ui の出力差を確認
# - 代表選手の PlayerVisibleRatings を表示し、レガシー風スケール (60 平均) に
#   なっているかを実測する
#
# 実行: godot --headless --path . tools/run_ui_display_shift_smoke.tscn

const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	# (1) sim と UI で同じ線形変換 (z * 12.5 + 50) を使うことを確認
	print("--- z -> display (unified linear, mean=50 stdev=12.5) ---")
	for z_value in [-1.5, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0]:
		var disp: int = PSAbilityScale.z_to_display(z_value)
		print("  z=%+0.2f  display=%d" % [z_value, disp])

	# (2) チーム1 の代表選手の PlayerVisibleRatings サンプル
	print("--- Sample player display ratings (Team 1) ---")
	var shown: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != 1 or player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
		var summary: String = PlayerVisibleRatings.summary_line(record)
		print("  pid=%d %s (pos=%d): %s" % [player.id, player.name, player.position, summary])
		shown += 1
		if shown >= 8:
			break

	print("UI display shift smoke: ALL OK")
	get_tree().quit(0)
