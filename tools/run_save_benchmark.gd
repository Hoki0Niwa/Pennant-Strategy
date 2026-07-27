extends Node

# アクティブセーブの save/load 所要時間を実測する調査ツール (headless 可)。
# 実行: godot --headless res://tools/run_save_benchmark.tscn
# 注意: アクティブセーブへ実際に書き込む。計測前にセーブフォルダのバックアップを取ること。


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var t0: int = Time.get_ticks_msec()
	var payload: Dictionary = SaveService.load_state()
	var t1: int = Time.get_ticks_msec()
	if payload.is_empty():
		print("save benchmark: no active save found")
		get_tree().quit(1)
		return
	var restored: bool = AppState.restore_from_save(payload)
	var t2: int = Time.get_ticks_msec()
	print("load_state_ms=%d restore_ms=%d ok=%s" % [t1 - t0, t2 - t1, str(restored)])
	if not restored:
		get_tree().quit(1)
		return
	_print_history_sizes()

	# 1回目はキャッシュ未シードの分だけ重い。2回目以降が定常コスト (日送りオートセーブ1回に相当)。
	for i in range(3):
		var s0: int = Time.get_ticks_msec()
		var ok: bool = SaveService.save_state(AppState)
		var s1: int = Time.get_ticks_msec()
		print("save_state[%d]_ms=%d ok=%s record_upserts=%d" % [
			i, s1 - s0, str(ok), SQLiteStore.last_record_upsert_count,
		])

	# 保存直後の再ロード時間
	var r0: int = Time.get_ticks_msec()
	var payload2: Dictionary = SaveService.load_state()
	var r1: int = Time.get_ticks_msec()
	var restored2: bool = AppState.restore_from_save(payload2)
	var r2: int = Time.get_ticks_msec()
	print("reload_state_ms=%d restore_ms=%d ok=%s" % [r1 - r0, r2 - r1, str(restored2)])
	_print_history_sizes()
	get_tree().quit(0)


func _print_history_sizes() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		print("history: no current season")
		return
	var game_entries: int = 0
	for entries_value in season.player_game_history.values():
		game_entries += (entries_value as Array).size()
	var stat_entries: int = 0
	for entries_value in season.player_stat_history.values():
		stat_entries += (entries_value as Array).size()
	print("history: day=%d game_history_entries=%d stat_history_entries=%d" % [
		season.current_day, game_entries, stat_entries,
	])
