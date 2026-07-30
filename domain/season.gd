extends RefCounted
class_name PSSeason

const AdvancedStatReducer = preload("res://services/simulation/reducers/advanced_stat_reducer.gd")

const MONTH_LENGTH_DAYS: int = 28
const MIN_MONTHLY_GAMES: int = 5
const SNAPSHOT_RETENTION_DAYS: int = 70
# 未保存の詳細ゲームログを一時保持する schedule game 内部キー。
# to_dict() には含めず、GameLogService がファイル書込成功後に削除する。
const TRANSIENT_GAME_LOG_KEY: String = "_pending_game_log"

var year: int
var season_number: int
var selected_team_id: int
var current_day: int = 1
var calendar_start_date: String = ""
var schedule_template_id: String = ""
var schedule_bucket_seed: int = 0
var schedule: Array = []
var standings: Dictionary = {}
var team_lineups: Dictionary = {}
var team_auto_batting_orders: Dictionary = {}
var team_fielder_usages: Dictionary = {}
var team_rotations: Dictionary = {}
var team_active_rosters: Dictionary = {}
# { team_id_str: int }  各球団の最後に自動入替が走った current_day
var last_auto_swap_day: Dictionary = {}
# { player_id_str: Array of {"day": int, "batter": Dictionary, "pitcher": Dictionary} }
# 各選手の時系列スナップショット (day 昇順)。月別成績取得 / 月間MVP 等で利用。
var player_stat_history: Dictionary = {}
# { player_id_str: Array of game rows }。各配列は day / game_index 昇順。
# 試合別の成績差分。PSSeason に属するため新シーズン作成時に自然にリセットされる。
var player_game_history: Dictionary = {}
# 試合ごとのスタメン (打順/守備位置) 記録。day / game_index 昇順の Dictionary 配列。
# 各行: {year, season_number, team_id, game_index, day, date, opponent_id, home_away,
#        result, score_for, score_against, starter_pitcher_id, dh,
#        slots: [{slot, pos, pid}, ...]}。SQLite load_team_lineup_history() の戻り値と
# 同じキー集合を持つ (PSLineupHistory が当季/過去季を分岐なしで扱えるようにするため)。
# player_game_history と異なり、SQLite の team_lineup_history テーブルは年度・シーズンを
# またいで永続する (season_history のような当季限定 DELETE は行わない)。
var team_lineup_history: Array = []
# シーズン中トレードの状態 (成立ログ / 自軍宛て提案 / 週次チェック日 / 球団別成立数)。
# スキーマと更新は TradeService に集約。新シーズン作成で自然にリセットされる。
var trade_state: Dictionary = {}
# 詳細な試合結果を破棄してもレポートを再構築できる、シーズン単位の軽量集計。
# 通常プレイでは不要な追加集計コストを避け、SimulationReporter が作る調査用seasonだけ有効化する。
var collect_simulation_report_data: bool = false
# 調査用seasonが大量の個別ログを作らないための実行時フラグ。保存データには含めず、
# ロードした通常seasonでは必ずtrueへ戻して詳細ログ欠落を防ぐ。
var generate_game_logs: bool = true
var simulation_report_data: Dictionary = {
	"advanced_stats": {"players": {}, "pitchers": {}},
	"advanced_record_counts": {"players": 0, "pitchers": 0},
	"batted_ball": {
		"batted_balls": 0,
		"barrels": 0,
		"hard_hits": 0,
		"home_run_batted_balls": 0,
		"home_run_barrels": 0,
		"exit_velocity_total": 0.0,
		"launch_angle_total": 0.0,
		"distance_total": 0.0,
	},
	"runner_event_counts": {},
}

# 1日分の試合を並列計算する際、team_setup_builder.gd が計算フェーズ内で
# lineup/fielder_usage/rotation/active_roster の各Dictionaryへ書き込みうる
# (初回アクセス時のデフォルト生成・ロースター再編成)。Mutexは再入可能なので、
# set_active_roster内部からaccrue_active_roster_daysを呼ぶような既存の入れ子呼び出しも安全。
var _mutex: Mutex = Mutex.new()


func setup(team_ids: Array) -> void:
	standings.clear()
	for team_id in team_ids:
		standings[int(team_id)] = PSStats.new()


func games_remaining() -> int:
	var remaining: int = 0
	for game_row in schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)):
			remaining += 1
	return remaining


func is_finished() -> bool:
	return games_remaining() == 0


func team_games_remaining(team_id: int) -> int:
	var remaining: int = 0
	for game_row in schedule:
		var game: Dictionary = game_row as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id:
			remaining += 1
	return remaining


func total_games() -> int:
	return schedule.size()


func get_lineup(team_id: int, dh_enabled: bool) -> Dictionary:
	_mutex.lock()
	var team_entry: Dictionary = team_lineups.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	var out: Dictionary = team_entry.get(key, {}) as Dictionary
	_mutex.unlock()
	return out


func set_lineup(team_id: int, dh_enabled: bool, lineup: Dictionary) -> void:
	_mutex.lock()
	var team_entry: Dictionary = team_lineups.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	var stored: Dictionary = lineup.duplicate(true)
	stored["updated_at_day"] = current_day
	team_entry[key] = stored
	team_lineups[str(team_id)] = team_entry
	_mutex.unlock()


func get_auto_batting_order(team_id: int, dh_enabled: bool) -> Array:
	_mutex.lock()
	var team_entry: Dictionary = team_auto_batting_orders.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	var out: Array[int] = []
	for player_id_value in team_entry.get(key, []) as Array:
		var player_id: int = int(player_id_value)
		if player_id > 0 and not out.has(player_id):
			out.append(player_id)
	_mutex.unlock()
	return out


func set_auto_batting_order(team_id: int, dh_enabled: bool, player_ids: Array) -> void:
	_mutex.lock()
	var team_entry: Dictionary = team_auto_batting_orders.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	var stored: Array[int] = []
	for player_id_value in player_ids:
		var player_id: int = int(player_id_value)
		if player_id > 0 and not stored.has(player_id):
			stored.append(player_id)
	team_entry[key] = stored
	team_auto_batting_orders[str(team_id)] = team_entry
	_mutex.unlock()


func get_fielder_usage(team_id: int) -> Dictionary:
	_mutex.lock()
	var out: Dictionary = team_fielder_usages.get(str(team_id), {}) as Dictionary
	_mutex.unlock()
	return out


func set_fielder_usage(team_id: int, usage: Dictionary) -> void:
	_mutex.lock()
	var stored: Dictionary = usage.duplicate(true)
	stored["updated_at_day"] = current_day
	team_fielder_usages[str(team_id)] = stored
	_mutex.unlock()


func get_rotation(team_id: int) -> Dictionary:
	_mutex.lock()
	var out: Dictionary = team_rotations.get(str(team_id), {}) as Dictionary
	_mutex.unlock()
	return out


func set_rotation(team_id: int, rotation: Dictionary) -> void:
	_mutex.lock()
	var stored: Dictionary = rotation.duplicate(true)
	stored["updated_at_day"] = current_day
	team_rotations[str(team_id)] = stored
	_mutex.unlock()


func get_active_roster(team_id: int) -> Dictionary:
	_mutex.lock()
	var out: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	_mutex.unlock()
	return out


func set_active_roster(team_id: int, roster: Dictionary) -> void:
	_mutex.lock()
	_accrue_active_roster_days_locked(team_id, current_day)
	var previous: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var stored: Dictionary = roster.duplicate(true)
	# FA日数台帳はシーズン側の保持分 (直前の accrue 済み) が常に正。呼び出し側が
	# get_active_roster の複製 (古い台帳入り) を渡しても積算が巻き戻らないよう必ず上書きする。
	stored["fa_active_days"] = (previous.get("fa_active_days", {}) as Dictionary).duplicate(true)
	stored["updated_at_day"] = current_day
	team_active_rosters[str(team_id)] = stored
	_mutex.unlock()


func clear_active_roster(team_id: int) -> void:
	_mutex.lock()
	_accrue_active_roster_days_locked(team_id, current_day)
	team_active_rosters.erase(str(team_id))
	_mutex.unlock()


func accrue_active_roster_days(team_id: int, to_day: int) -> void:
	_mutex.lock()
	_accrue_active_roster_days_locked(team_id, to_day)
	_mutex.unlock()


# _mutex を既にロックした状態でのみ呼ぶ内部実装 (Mutexは再入可能だが、ロック区間を
# 最小化するため set_active_roster/clear_active_roster からは直接この版を呼ぶ)。
func _accrue_active_roster_days_locked(team_id: int, to_day: int) -> void:
	var key: String = str(team_id)
	var roster: Dictionary = team_active_rosters.get(key, {}) as Dictionary
	if roster.is_empty():
		return
	var from_day: int = int(roster.get("updated_at_day", 1))
	var elapsed_days: int = max(0, to_day - from_day)
	if elapsed_days > 0:
		var days_by_player: Dictionary = (roster.get("fa_active_days", {}) as Dictionary).duplicate(true)
		for id_value in roster.get("player_ids", []) as Array:
			var player_key: String = str(int(id_value))
			days_by_player[player_key] = int(days_by_player.get(player_key, 0)) + elapsed_days
		roster["fa_active_days"] = days_by_player
	roster["updated_at_day"] = to_day
	team_active_rosters[key] = roster


func accrue_all_active_roster_days(team_ids: Array, to_day: int) -> void:
	_mutex.lock()
	for team_id_value in team_ids:
		_accrue_active_roster_days_locked(int(team_id_value), to_day)
	_mutex.unlock()


func get_active_roster_days(team_id: int, player_id: int) -> int:
	_mutex.lock()
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var days_by_player: Dictionary = roster.get("fa_active_days", {}) as Dictionary
	var out: int = int(days_by_player.get(str(player_id), 0))
	_mutex.unlock()
	return out


# シーズン中の球団間移籍 (トレード) 用: 移籍元で積算済みのFA日数を当日まで締めて
# 移籍先の台帳へ移す。契約更新 (_apply_fa_service_days) は record.team_id の1球団分しか
# 読まないため、移管しないと移籍元で積んだ当季日数が失われる。
func transfer_active_roster_days(from_team_id: int, to_team_id: int, player_id: int) -> void:
	_mutex.lock()
	_accrue_active_roster_days_locked(from_team_id, current_day)
	var player_key: String = str(player_id)
	var from_roster: Dictionary = team_active_rosters.get(str(from_team_id), {}) as Dictionary
	var from_days: Dictionary = (from_roster.get("fa_active_days", {}) as Dictionary).duplicate(true)
	var moved_days: int = int(from_days.get(player_key, 0))
	if moved_days > 0:
		from_days.erase(player_key)
		from_roster["fa_active_days"] = from_days
		team_active_rosters[str(from_team_id)] = from_roster
	# 移籍先も当日まで締めてから加算する (加算後に旧 updated_at_day 起点で accrue されると過大になる)。
	_accrue_active_roster_days_locked(to_team_id, current_day)
	var to_roster: Dictionary = team_active_rosters.get(str(to_team_id), {}) as Dictionary
	var to_days: Dictionary = (to_roster.get("fa_active_days", {}) as Dictionary).duplicate(true)
	to_days[player_key] = int(to_days.get(player_key, 0)) + moved_days
	to_roster["fa_active_days"] = to_days
	if not to_roster.has("updated_at_day"):
		to_roster["updated_at_day"] = current_day
	team_active_rosters[str(to_team_id)] = to_roster
	_mutex.unlock()


# --- 一二軍 自動入替 用ヘルパ ------------------------------------------------

func get_demotion_days(team_id: int) -> Dictionary:
	_mutex.lock()
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var out: Dictionary = roster.get("demotion_day", {}) as Dictionary
	_mutex.unlock()
	return out


# 指定選手達を当日付で「降格」として記録する。
func record_demotions(team_id: int, demoted_player_ids: Array, day: int) -> void:
	_mutex.lock()
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var demotion_day: Dictionary = (roster.get("demotion_day", {}) as Dictionary).duplicate(true)
	for id_value in demoted_player_ids:
		demotion_day[str(int(id_value))] = day
	roster["demotion_day"] = demotion_day
	team_active_rosters[str(team_id)] = roster
	_mutex.unlock()


# 10日以上経過したクールダウンレコードを除去する。
func clear_stale_demotions(team_id: int, day: int) -> void:
	_mutex.lock()
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	if not roster.has("demotion_day"):
		_mutex.unlock()
		return
	var demotion_day: Dictionary = roster.get("demotion_day", {}) as Dictionary
	var fresh: Dictionary = {}
	for key in demotion_day.keys():
		var d: int = int(demotion_day[key])
		if day - d < TeamAutoAI.DEMOTION_COOLDOWN_DAYS:
			fresh[key] = d
	roster["demotion_day"] = fresh
	team_active_rosters[str(team_id)] = roster
	_mutex.unlock()


func get_last_auto_swap_day(team_id: int) -> int:
	return int(last_auto_swap_day.get(str(team_id), 0))


func set_last_auto_swap_day(team_id: int, day: int) -> void:
	last_auto_swap_day[str(team_id)] = day


# --- 選手 stats スナップショット履歴 (月別 stats / 月間MVP 等で流用) ---

# 指定 day に snapshot を追加。同じ day 既存なら上書き、SNAPSHOT_RETENTION_DAYS を超える古い分は自動 trim。
func append_player_stat_snapshot(player_id: int, day: int, batter: PSBatterStats, pitcher: PSPitcherStats) -> void:
	var key: String = str(player_id)
	var history: Array = (player_stat_history.get(key, []) as Array)
	# 同じ day を上書きするため除去
	var i: int = 0
	while i < history.size():
		if int((history[i] as Dictionary).get("day", 0)) == day:
			history.remove_at(i)
		else:
			i += 1
	history.append({
		"day": day,
		"batter": batter.to_dict(),
		"pitcher": pitcher.to_dict(),
	})
	# day 昇順を保つ (重複削除後の append 位置で順序維持されているはず)
	# 古いエントリ trim
	var cutoff: int = day - SNAPSHOT_RETENTION_DAYS
	while history.size() > 0 and int((history[0] as Dictionary).get("day", 0)) < cutoff:
		history.pop_front()
	player_stat_history[key] = history


# target_day 以前 (day <= target_day) で最も新しい snapshot を返す。無ければ {}。
func get_player_stat_snapshot_at_or_before(player_id: int, target_day: int) -> Dictionary:
	var history: Array = (player_stat_history.get(str(player_id), []) as Array)
	var best: Dictionary = {}
	for entry_row in history:
		var entry: Dictionary = entry_row as Dictionary
		if int(entry.get("day", 0)) <= target_day:
			best = entry
		else:
			break
	return best


# 月別成績取得 (一二軍入替 / 月間MVP 共通 API)。
# 戻り値: {"batter": PSBatterStats, "pitcher": PSPitcherStats, "source": String}
#   source = "current_month" / "previous_month" / "first_month_partial"
func get_monthly_stats(player_id: int, current_batter: PSBatterStats, current_pitcher: PSPitcherStats) -> Dictionary:
	var day: int = current_day
	@warning_ignore("integer_division")
	var current_month_index: int = max(0, (day - 1) / MONTH_LENGTH_DAYS)
	# 今月の開始前日 (= 先月最終日)
	var prev_month_end_day: int = current_month_index * MONTH_LENGTH_DAYS
	var current_snap: Dictionary = {}
	if prev_month_end_day > 0:
		current_snap = get_player_stat_snapshot_at_or_before(player_id, prev_month_end_day)

	var current_month_batter: PSBatterStats
	var current_month_pitcher: PSPitcherStats
	if current_snap.is_empty():
		current_month_batter = PSBatterStats.from_dict(current_batter.to_dict())
		current_month_pitcher = PSPitcherStats.from_dict(current_pitcher.to_dict())
	else:
		current_month_batter = current_batter.subtract_from(PSBatterStats.from_dict(current_snap.get("batter", {}) as Dictionary))
		current_month_pitcher = current_pitcher.subtract_from(PSPitcherStats.from_dict(current_snap.get("pitcher", {}) as Dictionary))

	# 今月の試合数が十分か (打者 or 投手の games で判定)
	var month_games: int = max(current_month_batter.games, current_month_pitcher.games)
	if month_games >= MIN_MONTHLY_GAMES:
		return {"batter": current_month_batter, "pitcher": current_month_pitcher, "source": "current_month"}

	# 不十分 → 先月にフォールバック
	if current_month_index <= 0 or current_snap.is_empty():
		return {"batter": current_month_batter, "pitcher": current_month_pitcher, "source": "first_month_partial"}

	var prev_prev_month_end_day: int = (current_month_index - 1) * MONTH_LENGTH_DAYS
	var prev_snap: Dictionary = {}
	if prev_prev_month_end_day > 0:
		prev_snap = get_player_stat_snapshot_at_or_before(player_id, prev_prev_month_end_day)

	var current_snap_batter: PSBatterStats = PSBatterStats.from_dict(current_snap.get("batter", {}) as Dictionary)
	var current_snap_pitcher: PSPitcherStats = PSPitcherStats.from_dict(current_snap.get("pitcher", {}) as Dictionary)
	var prev_month_batter: PSBatterStats
	var prev_month_pitcher: PSPitcherStats
	if prev_snap.is_empty():
		# 先月の開始前日 (= 月0 や snap 無し) → 先月 stats = current_snap (シーズン頭からの累積)
		prev_month_batter = current_snap_batter
		prev_month_pitcher = current_snap_pitcher
	else:
		prev_month_batter = current_snap_batter.subtract_from(PSBatterStats.from_dict(prev_snap.get("batter", {}) as Dictionary))
		prev_month_pitcher = current_snap_pitcher.subtract_from(PSPitcherStats.from_dict(prev_snap.get("pitcher", {}) as Dictionary))

	return {"batter": prev_month_batter, "pitcher": prev_month_pitcher, "source": "previous_month"}


# --- 選手別 試合履歴 ----------------------------------------------------------

func append_player_game_log(player_id: int, row: Dictionary) -> void:
	if player_id <= 0:
		return
	var key: String = str(player_id)
	var history: Array = player_game_history.get(key, []) as Array
	var stored_row: Dictionary = row.duplicate(true)
	var game_index: int = int(row.get("game_index", -1))
	if history.is_empty():
		history.append(stored_row)
		player_game_history[key] = history
		return

	var last_row: Dictionary = history[history.size() - 1] as Dictionary
	var last_game_index: int = int(last_row.get("game_index", -2))
	var row_day: int = int(row.get("day", 0))
	var last_day: int = int(last_row.get("day", 0))
	if game_index == last_game_index and row_day == last_day:
		history[history.size() - 1] = stored_row
		player_game_history[key] = history
		return
	if game_index > last_game_index and _player_game_log_precedes(last_row, stored_row):
		history.append(stored_row)
		player_game_history[key] = history
		return

	var existing_index: int = -1
	for i in range(history.size()):
		var existing: Dictionary = history[i] as Dictionary
		if int(existing.get("game_index", -2)) == game_index:
			if int(existing.get("day", 0)) == row_day:
				history[i] = stored_row
				player_game_history[key] = history
				return
			existing_index = i
			break
	if existing_index >= 0:
		history.remove_at(existing_index)
	history.insert(_player_game_log_insertion_index(history, stored_row), stored_row)
	player_game_history[key] = history


func _player_game_log_insertion_index(history: Array, row: Dictionary) -> int:
	var low: int = 0
	var high: int = history.size()
	while low < high:
		@warning_ignore("integer_division")
		var middle: int = (low + high) / 2
		var existing: Dictionary = history[middle] as Dictionary
		if _player_game_log_precedes(existing, row):
			low = middle + 1
		else:
			high = middle
	return low


func _player_game_log_precedes(a: Variant, b: Variant) -> bool:
	var row_a: Dictionary = a as Dictionary
	var row_b: Dictionary = b as Dictionary
	var day_a: int = int(row_a.get("day", 0))
	var day_b: int = int(row_b.get("day", 0))
	if day_a == day_b:
		return int(row_a.get("game_index", 0)) < int(row_b.get("game_index", 0))
	return day_a < day_b


func get_player_game_logs(player_id: int) -> Array:
	var history: Array = (player_game_history.get(str(player_id), []) as Array).duplicate(true)
	history.sort_custom(_player_game_log_precedes)
	return history


# 同じ (team_id, game_index) の行は上書きし、day → game_index 昇順を維持したまま挿入する。
func append_team_lineup(row: Dictionary) -> void:
	var team_id: int = int(row.get("team_id", 0))
	var game_index: int = int(row.get("game_index", -1))
	var stored_row: Dictionary = row.duplicate(true)
	for i in range(team_lineup_history.size()):
		var existing: Dictionary = team_lineup_history[i] as Dictionary
		if int(existing.get("team_id", 0)) == team_id and int(existing.get("game_index", -1)) == game_index:
			team_lineup_history[i] = stored_row
			return
	team_lineup_history.insert(_team_lineup_insertion_index(stored_row), stored_row)


func _team_lineup_insertion_index(row: Dictionary) -> int:
	var low: int = 0
	var high: int = team_lineup_history.size()
	while low < high:
		@warning_ignore("integer_division")
		var middle: int = (low + high) / 2
		var existing: Dictionary = team_lineup_history[middle] as Dictionary
		if _team_lineup_precedes(existing, row):
			low = middle + 1
		else:
			high = middle
	return low


func _team_lineup_precedes(a: Dictionary, b: Dictionary) -> bool:
	var day_a: int = int(a.get("day", 0))
	var day_b: int = int(b.get("day", 0))
	if day_a == day_b:
		return int(a.get("game_index", 0)) < int(b.get("game_index", 0))
	return day_a < day_b


# 詳細結果を schedule から破棄する前に、レポートで必要な加算可能データだけを保持する。
func accumulate_game_report_data(result: Dictionary) -> void:
	if not collect_simulation_report_data:
		return
	var advanced_stats: Dictionary = result.get("advanced_stats", {}) as Dictionary
	var accumulated_advanced: Dictionary = simulation_report_data.get("advanced_stats", {}) as Dictionary
	AdvancedStatReducer.merge_dict_container(accumulated_advanced, advanced_stats)
	simulation_report_data["advanced_stats"] = accumulated_advanced

	var advanced_counts: Dictionary = simulation_report_data.get("advanced_record_counts", {}) as Dictionary
	for bucket_name in [AdvancedStatReducer.BUCKET_PLAYERS, AdvancedStatReducer.BUCKET_PITCHERS]:
		var source_bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		advanced_counts[bucket_name] = int(advanced_counts.get(bucket_name, 0)) + source_bucket.size()
	simulation_report_data["advanced_record_counts"] = advanced_counts

	var batted_ball: Dictionary = simulation_report_data.get("batted_ball", {}) as Dictionary
	for event_value in result.get("play_events", []) as Array:
		var event: Dictionary = event_value as Dictionary
		var batted_ball_event: Dictionary = event.get("batted_ball_event", {}) as Dictionary
		if batted_ball_event.is_empty():
			continue
		batted_ball["batted_balls"] = int(batted_ball.get("batted_balls", 0)) + 1
		batted_ball["exit_velocity_total"] = float(batted_ball.get("exit_velocity_total", 0.0)) + float(batted_ball_event.get("exit_velocity", 0.0))
		batted_ball["launch_angle_total"] = float(batted_ball.get("launch_angle_total", 0.0)) + float(batted_ball_event.get("launch_angle", 0.0))
		batted_ball["distance_total"] = float(batted_ball.get("distance_total", 0.0)) + float(batted_ball_event.get("distance", 0.0))
		if bool(batted_ball_event.get("is_barrel", false)):
			batted_ball["barrels"] = int(batted_ball.get("barrels", 0)) + 1
		if bool(batted_ball_event.get("is_hard_hit", false)):
			batted_ball["hard_hits"] = int(batted_ball.get("hard_hits", 0)) + 1
		if str(batted_ball_event.get("actual_result", "")).contains("home_run"):
			batted_ball["home_run_batted_balls"] = int(batted_ball.get("home_run_batted_balls", 0)) + 1
			if bool(batted_ball_event.get("is_barrel", false)):
				batted_ball["home_run_barrels"] = int(batted_ball.get("home_run_barrels", 0)) + 1
	simulation_report_data["batted_ball"] = batted_ball

	var runner_counts: Dictionary = simulation_report_data.get("runner_event_counts", {}) as Dictionary
	var game_runner_counts: Dictionary = result.get("runner_event_counts", {}) as Dictionary
	for key in game_runner_counts.keys():
		runner_counts[key] = int(runner_counts.get(key, 0)) + int(game_runner_counts[key])
	simulation_report_data["runner_event_counts"] = runner_counts


# 消化済み試合の result から、schedule とセーブ本体に残す軽量サマリ列だけを抜き出す。
# 詳細な box score / play-by-play は GameLogService の別ファイル（保存前は transient log）から
# 必要時に読み、season blob と常駐メモリを試合数に比例して肥大化させない。
const PERSISTED_RESULT_KEYS: Array = [
	"winning_team_id", "draw",
	"winning_pitcher_id", "losing_pitcher_id", "save_pitcher_id", "hold_pitcher_ids",
]


# 消化後の schedule が保持する軽量結果。詳細な play_events / lineups / advanced_stats は
# 試合直後の集計とゲームログ化を終えた時点で破棄し、シーズン進行に比例するメモリ増加を防ぐ。
func compact_game_result(result: Dictionary) -> Dictionary:
	var compact: Dictionary = {}
	for key in PERSISTED_RESULT_KEYS:
		if result.has(key):
			compact[key] = result[key]
	return compact


# include_history=false は SQLite の season_history テーブルへ増分永続化するセーブ経路用。
# player_stat_history / player_game_history (シーズン後半で数十MB) を blob から外し、
# 毎セーブの全量再シリアライズを避ける。それ以外の呼び出しは完全な dict を返す既定のまま。
func to_dict(include_history: bool = true) -> Dictionary:
	var standings_data: Dictionary = {}
	for team_id in standings.keys():
		var stats: PSStats = standings[team_id] as PSStats
		standings_data[str(team_id)] = stats.to_dict()

	var out: Dictionary = {
		"year": year,
		"season_number": season_number,
		"selected_team_id": selected_team_id,
		"current_day": current_day,
		"calendar_start_date": calendar_start_date,
		"schedule_template_id": schedule_template_id,
		"schedule_bucket_seed": schedule_bucket_seed,
		"schedule": _schedule_for_save(),
		"standings": standings_data,
		"team_lineups": team_lineups,
		"team_auto_batting_orders": team_auto_batting_orders,
		"team_fielder_usages": team_fielder_usages,
		"team_rotations": team_rotations,
		"team_active_rosters": team_active_rosters,
		"last_auto_swap_day": last_auto_swap_day,
		"trade_state": trade_state,
		"collect_simulation_report_data": collect_simulation_report_data,
		"simulation_report_data": simulation_report_data,
	}
	if include_history:
		out["player_stat_history"] = player_stat_history
		out["player_game_history"] = player_game_history
		out["team_lineup_history"] = team_lineup_history
	return out


# schedule をセーブ用に複製し、消化済み試合の result を正規の軽量サマリへ揃える。
# 未保存詳細用の transient log は必ず除外する。
func _schedule_for_save() -> Array:
	var out: Array = []
	for game_row in schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)) or not game.has("result"):
			out.append(game)
			continue
		var slim_game: Dictionary = game.duplicate()
		slim_game.erase(TRANSIENT_GAME_LOG_KEY)
		var full_result: Dictionary = game.get("result", {}) as Dictionary
		slim_game["result"] = compact_game_result(full_result)
		out.append(slim_game)
	return out


static func from_dict(data: Dictionary) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = int(data.get("year", 2026))
	season.season_number = int(data.get("season_number", 1))
	season.selected_team_id = int(data.get("selected_team_id", 0))
	season.current_day = int(data.get("current_day", 1))
	season.calendar_start_date = str(data.get("calendar_start_date", ""))
	season.schedule_template_id = str(data.get("schedule_template_id", ""))
	season.schedule_bucket_seed = int(data.get("schedule_bucket_seed", 0))
	season.schedule = data.get("schedule", []) as Array
	# 旧バージョンは交流戦ブロックを配列末尾に append しており、day 順でない日程は
	# シミュレータに飛ばされてしまう。読込時に day 順へ整列して復旧する。
	PSSchedule.sort_by_day(season.schedule)
	# 整列の結果、current_day より前に未消化試合(飛ばされた交流戦)が残っていれば
	# そこまで巻き戻して取りこぼしを消化できるようにする。
	var earliest_unplayed_day: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("played", false)):
			earliest_unplayed_day = int(game.get("day", 0))
			break
	if earliest_unplayed_day > 0 and earliest_unplayed_day < season.current_day:
		season.current_day = earliest_unplayed_day

	var standings_data: Dictionary = data.get("standings", {}) as Dictionary
	for key in standings_data.keys():
		season.standings[int(key)] = PSStats.from_dict(standings_data[key] as Dictionary)

	season.team_lineups = (data.get("team_lineups", {}) as Dictionary).duplicate(true)
	season.team_auto_batting_orders = (data.get("team_auto_batting_orders", {}) as Dictionary).duplicate(true)
	season.team_fielder_usages = (data.get("team_fielder_usages", {}) as Dictionary).duplicate(true)
	season.team_rotations = (data.get("team_rotations", {}) as Dictionary).duplicate(true)
	season.team_active_rosters = (data.get("team_active_rosters", {}) as Dictionary).duplicate(true)
	season.last_auto_swap_day = (data.get("last_auto_swap_day", {}) as Dictionary).duplicate(true)
	season.player_stat_history = (data.get("player_stat_history", {}) as Dictionary).duplicate(true)
	season.player_game_history = (data.get("player_game_history", {}) as Dictionary).duplicate(true)
	season.team_lineup_history = (data.get("team_lineup_history", []) as Array).duplicate(true)
	season.trade_state = (data.get("trade_state", {}) as Dictionary).duplicate(true)
	season.collect_simulation_report_data = bool(data["collect_simulation_report_data"])
	season.simulation_report_data = (data["simulation_report_data"] as Dictionary).duplicate(true)

	return season
