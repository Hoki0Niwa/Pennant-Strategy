extends RefCounted
class_name PSSeason

const MONTH_LENGTH_DAYS: int = 28
const MIN_MONTHLY_GAMES: int = 5
const SNAPSHOT_RETENTION_DAYS: int = 70

var year: int
var season_number: int
var selected_team_id: int
var current_day: int = 1
var schedule: Array = []
var standings: Dictionary = {}
var team_lineups: Dictionary = {}
var team_fielder_usages: Dictionary = {}
var team_rotations: Dictionary = {}
var team_active_rosters: Dictionary = {}
# { team_id_str: int }  各球団の最後に自動入替が走った current_day
var last_auto_swap_day: Dictionary = {}
# { player_id_str: Array of {"day": int, "batter": Dictionary, "pitcher": Dictionary} }
# 各選手の時系列スナップショット (day 昇順)。月別成績取得 / 月間MVP 等で利用。
var player_stat_history: Dictionary = {}


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
	var team_entry: Dictionary = team_lineups.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	return team_entry.get(key, {}) as Dictionary


func set_lineup(team_id: int, dh_enabled: bool, lineup: Dictionary) -> void:
	var team_entry: Dictionary = team_lineups.get(str(team_id), {}) as Dictionary
	var key: String = "dh" if dh_enabled else "non_dh"
	var stored: Dictionary = lineup.duplicate(true)
	stored["updated_at_day"] = current_day
	team_entry[key] = stored
	team_lineups[str(team_id)] = team_entry


func get_fielder_usage(team_id: int) -> Dictionary:
	return team_fielder_usages.get(str(team_id), {}) as Dictionary


func set_fielder_usage(team_id: int, usage: Dictionary) -> void:
	var stored: Dictionary = usage.duplicate(true)
	stored["updated_at_day"] = current_day
	team_fielder_usages[str(team_id)] = stored


func get_rotation(team_id: int) -> Dictionary:
	return team_rotations.get(str(team_id), {}) as Dictionary


func set_rotation(team_id: int, rotation: Dictionary) -> void:
	var stored: Dictionary = rotation.duplicate(true)
	stored["updated_at_day"] = current_day
	team_rotations[str(team_id)] = stored


func get_active_roster(team_id: int) -> Dictionary:
	return team_active_rosters.get(str(team_id), {}) as Dictionary


func set_active_roster(team_id: int, roster: Dictionary) -> void:
	accrue_active_roster_days(team_id, current_day)
	var previous: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var stored: Dictionary = roster.duplicate(true)
	if not stored.has("fa_active_days"):
		stored["fa_active_days"] = (previous.get("fa_active_days", {}) as Dictionary).duplicate(true)
	stored["updated_at_day"] = current_day
	team_active_rosters[str(team_id)] = stored


func clear_active_roster(team_id: int) -> void:
	accrue_active_roster_days(team_id, current_day)
	team_active_rosters.erase(str(team_id))


func accrue_active_roster_days(team_id: int, to_day: int) -> void:
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
	for team_id_value in team_ids:
		accrue_active_roster_days(int(team_id_value), to_day)


func get_active_roster_days(team_id: int, player_id: int) -> int:
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var days_by_player: Dictionary = roster.get("fa_active_days", {}) as Dictionary
	return int(days_by_player.get(str(player_id), 0))


# --- 一二軍 自動入替 用ヘルパ ------------------------------------------------

func get_demotion_days(team_id: int) -> Dictionary:
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	return roster.get("demotion_day", {}) as Dictionary


# 指定選手達を当日付で「降格」として記録する。
func record_demotions(team_id: int, demoted_player_ids: Array, day: int) -> void:
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	var demotion_day: Dictionary = (roster.get("demotion_day", {}) as Dictionary).duplicate(true)
	for id_value in demoted_player_ids:
		demotion_day[str(int(id_value))] = day
	roster["demotion_day"] = demotion_day
	team_active_rosters[str(team_id)] = roster


# 10日以上経過したクールダウンレコードを除去する。
func clear_stale_demotions(team_id: int, day: int) -> void:
	var roster: Dictionary = team_active_rosters.get(str(team_id), {}) as Dictionary
	if not roster.has("demotion_day"):
		return
	var demotion_day: Dictionary = roster.get("demotion_day", {}) as Dictionary
	var fresh: Dictionary = {}
	for key in demotion_day.keys():
		var d: int = int(demotion_day[key])
		if day - d < TeamAutoAI.DEMOTION_COOLDOWN_DAYS:
			fresh[key] = d
	roster["demotion_day"] = fresh
	team_active_rosters[str(team_id)] = roster


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


# 消化済み試合の result から、セーブに残す軽量サマリ列だけを抜き出す。
# 詳細な box score / play-by-play (1 試合 ~166KB) はセーブ後に読み戻されることが無く
# (game_result_screen / home_screen は下記スカラーしか参照しない)、保存すると season blob が
# 1 シーズン 858 試合 × ~166KB ≈ 142MB に肥大化して save/load を極端に重くしていた。
const PERSISTED_RESULT_KEYS: Array = [
	"winning_team_id", "draw",
	"winning_pitcher_id", "losing_pitcher_id", "save_pitcher_id", "hold_pitcher_ids",
	"away_pitcher_id", "home_pitcher_id",
	"pitcher_outings", "last_lead_change",
]


func to_dict() -> Dictionary:
	var standings_data: Dictionary = {}
	for team_id in standings.keys():
		var stats: PSStats = standings[team_id] as PSStats
		standings_data[str(team_id)] = stats.to_dict()

	return {
		"year": year,
		"season_number": season_number,
		"selected_team_id": selected_team_id,
		"current_day": current_day,
		"schedule": _schedule_for_save(),
		"standings": standings_data,
		"team_lineups": team_lineups,
		"team_fielder_usages": team_fielder_usages,
		"team_rotations": team_rotations,
		"team_active_rosters": team_active_rosters,
		"last_auto_swap_day": last_auto_swap_day,
		"player_stat_history": player_stat_history,
	}


# schedule をセーブ用に複製し、消化済み試合の重い result を軽量サマリへ差し替える。
# メモリ上の schedule はそのまま (セッション中の詳細表示には影響しない)。
func _schedule_for_save() -> Array:
	var out: Array = []
	for game_row in schedule:
		var game: Dictionary = game_row as Dictionary
		if not bool(game.get("played", false)) or not game.has("result"):
			out.append(game)
			continue
		var slim_game: Dictionary = game.duplicate()
		var full_result: Dictionary = game.get("result", {}) as Dictionary
		var slim_result: Dictionary = {}
		for key in PERSISTED_RESULT_KEYS:
			if full_result.has(key):
				slim_result[key] = full_result[key]
		slim_game["result"] = slim_result
		out.append(slim_game)
	return out


static func from_dict(data: Dictionary) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = int(data.get("year", 2026))
	season.season_number = int(data.get("season_number", 1))
	season.selected_team_id = int(data.get("selected_team_id", 0))
	season.current_day = int(data.get("current_day", 1))
	season.schedule = data.get("schedule", []) as Array

	var standings_data: Dictionary = data.get("standings", {}) as Dictionary
	for key in standings_data.keys():
		season.standings[int(key)] = PSStats.from_dict(standings_data[key] as Dictionary)

	season.team_lineups = (data.get("team_lineups", {}) as Dictionary).duplicate(true)
	season.team_fielder_usages = (data.get("team_fielder_usages", {}) as Dictionary).duplicate(true)
	season.team_rotations = (data.get("team_rotations", {}) as Dictionary).duplicate(true)
	season.team_active_rosters = (data.get("team_active_rosters", {}) as Dictionary).duplicate(true)
	season.last_auto_swap_day = (data.get("last_auto_swap_day", {}) as Dictionary).duplicate(true)
	season.player_stat_history = (data.get("player_stat_history", {}) as Dictionary).duplicate(true)

	return season
