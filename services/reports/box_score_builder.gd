extends RefCounted
class_name PSBoxScoreBuilder

# 試合ログ(game_log_service の {meta, lineups, pa_log, substitutions})から、
# 1 チーム分の伝統的ボックススコア(選手×イニングのマトリクス)を組み立てる純関数群。
# UI(game_result_screen)が build() の戻り値をそのまま表に流す。

const POSITION_CHARS: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三", 6: "遊", 7: "左", 8: "中", 9: "右", 10: "指",
}


# 戻り値: {rows: Array[Dictionary], totals: Dictionary, inning_count: int, columns: Array}
# row: {pos, name, bats, ab, h, rbi, gidp, avg, hr, cells:[{text,is_hit}]}
# columns: Array[{inning, round}]。打者一巡で同一イニングに 2 打席立った場合は、その
# イニングに列 (round) を追加し、cells は columns と同じ並びで対応する (「・」連結はしない)。
static func build(log_data: Dictionary, team_id: int, season: PSSeason) -> Dictionary:
	var pa_log: Array = log_data.get("pa_log", []) as Array
	var subs: Array = log_data.get("substitutions", []) as Array
	var lineup: Dictionary = _lineup_for_team(log_data, team_id)
	var dh: bool = bool(lineup.get("dh", false))
	var inning_count: int = _inning_count(pa_log)

	var team_pas: Array = []
	for row_value in pa_log:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("batting_team_id", 0)) == team_id:
			team_pas.append(row)

	# 打順スロット -> 出場順の選手エントリ {player_id, position, kind}
	var slot_players: Dictionary = {}
	var slot_order: Array = []
	var pitcher_slot: int = -1
	for slot_row in (lineup.get("slots", []) as Array):
		var s: Dictionary = slot_row as Dictionary
		var slot: int = int(s.get("slot", 0))
		var pos: int = int(s.get("position", 0))
		slot_players[slot] = [{"player_id": int(s.get("player_id", 0)), "position": pos, "kind": "start"}]
		slot_order.append(slot)
		if pos == 1:
			pitcher_slot = slot
	var extra: Array = []  # 打順に入らない交代(DH時の救援投手など)

	for sub_row in subs:
		var sub: Dictionary = sub_row as Dictionary
		if int(sub.get("team_id", 0)) != team_id:
			continue
		var kind: String = str(sub.get("kind", ""))
		var entry: Dictionary = {"player_id": int(sub.get("in_id", 0)), "position": int(sub.get("position", 0)), "kind": kind}
		var slot: int = int(sub.get("slot", -1))
		if kind == "pitching":
			# DH 制では投手は打席に立たないため、救援投手も打席結果(ボックススコア)に含めない。
			if dh:
				continue
			if pitcher_slot > 0:
				(slot_players[pitcher_slot] as Array).append(entry)
			else:
				extra.append(entry)
		elif slot > 0 and slot_players.has(slot):
			(slot_players[slot] as Array).append(entry)
		else:
			extra.append(entry)

	# 列構成 (イニング x 打者一巡の round) と、inning -> 列index配列 の対応を作る。
	var columns: Array = _build_columns(team_pas, inning_count)
	var col_index: Dictionary = {}
	for ci in range(columns.size()):
		var inn: int = int((columns[ci] as Dictionary)["inning"])
		if not col_index.has(inn):
			col_index[inn] = []
		(col_index[inn] as Array).append(ci)

	var rows: Array = []
	for slot_num in slot_order:
		for entry_row in (slot_players[slot_num] as Array):
			rows.append(_player_row(entry_row as Dictionary, team_pas, columns.size(), col_index, season))
	for entry_row in extra:
		rows.append(_player_row(entry_row as Dictionary, team_pas, columns.size(), col_index, season))

	return {"rows": rows, "totals": _totals(team_pas), "inning_count": inning_count, "columns": columns}


# 各イニングの列数 = そのイニングで「同一打者が立った最大打席数」(=打者一巡の周回数)。
# 通常は全イニング 1 列。打者一巡したイニングだけ列が増える。打席ゼロのイニングも 1 列確保。
static func _build_columns(team_pas: Array, inning_count: int) -> Array:
	var counts: Dictionary = {}   # "inning_batter" -> その打者の当該イニング打席数
	var rounds: Dictionary = {}   # inning -> 最大周回数
	for pa_row in team_pas:
		var pa: Dictionary = pa_row as Dictionary
		var inn: int = int(pa.get("inning", 0))
		if inn < 1:
			continue
		var key: String = "%d_%d" % [inn, int(pa.get("batter_id", 0))]
		var c: int = int(counts.get(key, 0)) + 1
		counts[key] = c
		rounds[inn] = max(int(rounds.get(inn, 0)), c)
	var columns: Array = []
	for inn in range(1, inning_count + 1):
		var rc: int = max(1, int(rounds.get(inn, 0)))
		for r in range(rc):
			columns.append({"inning": inn, "round": r})
	return columns


static func _lineup_for_team(log_data: Dictionary, team_id: int) -> Dictionary:
	var lineups: Dictionary = log_data.get("lineups", {}) as Dictionary
	for key in ["away", "home"]:
		var l: Dictionary = lineups.get(key, {}) as Dictionary
		if int(l.get("team_id", -1)) == team_id:
			return l
	return {}


static func _inning_count(pa_log: Array) -> int:
	var mx: int = 9
	for row_value in pa_log:
		mx = max(mx, int((row_value as Dictionary).get("inning", 0)))
	return mx


static func _player_row(entry: Dictionary, team_pas: Array, column_count: int, col_index: Dictionary, season: PSSeason) -> Dictionary:
	var player_id: int = int(entry.get("player_id", 0))
	var record: PSPlayerSeasonRecord = null
	if season != null:
		record = RecordStore.get_player_record(player_id, season.year, season.season_number)
	var cells: Array = []
	for _i in range(column_count):
		cells.append({"text": "", "is_hit": false})

	var ab: int = 0
	var h: int = 0
	var rbi: int = 0
	var gidp: int = 0
	var round_by_inning: Dictionary = {}  # この選手の各イニングの打席周回 (0,1,...)
	for pa_row in team_pas:
		var pa: Dictionary = pa_row as Dictionary
		if int(pa.get("batter_id", 0)) != player_id:
			continue
		var cat: String = str(pa.get("category", ""))
		if bool(pa.get("ab_charged", false)):
			ab += 1
		if cat == "hit":
			h += 1
		if cat == "double_play":
			gidp += 1
		rbi += int(pa.get("rbi", 0))
		var inn: int = int(pa.get("inning", 0))
		if not col_index.has(inn):
			continue
		# 同一イニング2打席目以降は「・」連結せず、その周回に対応する列へ書く。
		var r: int = int(round_by_inning.get(inn, 0))
		round_by_inning[inn] = r + 1
		var inning_cols: Array = col_index[inn] as Array
		if r < inning_cols.size():
			var cidx: int = int(inning_cols[r])
			var cell: Dictionary = cells[cidx] as Dictionary
			cell["text"] = _pa_abbrev(pa)
			if cat == "hit":
				cell["is_hit"] = true
			cells[cidx] = cell

	return {
		"pos": _position_label(entry),
		"name": record.name if record != null else "#%d" % player_id,
		"bats": _bats_label(record),
		"ab": ab, "h": h, "rbi": rbi, "gidp": gidp,
		"avg": record.batter_stats.batting_average() if record != null else 0.0,
		"hr": record.batter_stats.home_runs if record != null else 0,
		"cells": cells,
	}


static func _position_label(entry: Dictionary) -> String:
	match str(entry.get("kind", "")):
		"pinch_hit":
			return "打"
		"pinch_run":
			return "走"
		"pitching":
			return "投"
		"start":
			# スタメンの守備位置はカッコで囲み、途中出場 (守備固め等) と区別する。
			return "(%s)" % str(POSITION_CHARS.get(int(entry.get("position", 0)), ""))
	return str(POSITION_CHARS.get(int(entry.get("position", 0)), ""))


static func _bats_label(record: PSPlayerSeasonRecord) -> String:
	if record == null:
		return ""
	match str(record.batting_side):
		"L":
			return "左"
		"S", "B", "両":
			return "両"
	return "右"


static func _pa_abbrev(pa: Dictionary) -> String:
	var cat: String = str(pa.get("category", "out"))
	var bases: int = int(pa.get("bases", 0))
	var dir: String = str(POSITION_CHARS.get(int(pa.get("fielder_position", 0)), ""))
	var result: String = str(pa.get("result", ""))
	match cat:
		"walk":
			return "敬遠" if result == "intentional_walk" else "四球"
		"hit_by_pitch":
			return "死球"
		"strikeout":
			return "三振"
		"hit":
			var suf: String = "安" if bases <= 1 else ("2" if bases == 2 else ("3" if bases == 3 else "本"))
			return dir + suf
		"double_play":
			return dir + "併"
		"sacrifice_fly":
			return "犠飛"
		"sacrifice":
			return "犠打"
		"fielders_choice":
			return "野選"
		"error":
			return dir + "失"
	# 通常アウト: 打球種別で ゴ/直/飛
	var rc: String = "ゴ"
	match str(pa.get("batted_ball_type", "")):
		"liner":
			rc = "直"
		"fly", "popup":
			rc = "飛"
		"grounder":
			rc = "ゴ"
		_:
			rc = "直" if result.contains("line") else ("飛" if (result.contains("fly") or result.contains("pop")) else "ゴ")
	if dir.is_empty():
		return rc
	return dir + rc


static func _totals(team_pas: Array) -> Dictionary:
	var ab: int = 0
	var h: int = 0
	var rbi: int = 0
	var hr: int = 0
	var gidp: int = 0
	for pa_row in team_pas:
		var pa: Dictionary = pa_row as Dictionary
		var cat: String = str(pa.get("category", ""))
		if bool(pa.get("ab_charged", false)):
			ab += 1
		if cat == "hit":
			h += 1
			if int(pa.get("bases", 0)) >= 4:
				hr += 1
		if cat == "double_play":
			gidp += 1
		rbi += int(pa.get("rbi", 0))
	return {
		"ab": ab, "h": h, "rbi": rbi, "hr": hr, "gidp": gidp,
		"avg": (float(h) / float(ab)) if ab > 0 else 0.0,
	}


# 投手成績(両チームを1表)。log_data の pitcher_outings/decisions/pa_log を使う。
# 戻り値 {rows:[{mark,name,throws,w,l,s,g,ip,bf,pitches,h,k,bb,hbp,r,er,era}]}
static func build_pitching(log_data: Dictionary, season: PSSeason) -> Dictionary:
	var decisions: Dictionary = log_data.get("decisions", {}) as Dictionary
	var win_id: int = int(decisions.get("winning_pitcher_id", 0))
	var loss_id: int = int(decisions.get("losing_pitcher_id", 0))
	var save_id: int = int(decisions.get("save_pitcher_id", 0))
	var holds: Array = decisions.get("hold_pitcher_ids", []) as Array
	var tallies: Dictionary = _pitcher_pa_tallies(log_data.get("pa_log", []) as Array)

	# チーム別グループ(配列の出現順=away→home, 各チーム内は登板順)
	var by_team: Dictionary = {}
	var team_order: Array = []
	for outing_row in (log_data.get("pitcher_outings", []) as Array):
		var outing: Dictionary = outing_row as Dictionary
		var tid: int = int(outing.get("team_id", 0))
		if not by_team.has(tid):
			by_team[tid] = []
			team_order.append(tid)
		(by_team[tid] as Array).append(outing)

	var rows: Array = []
	for tid in team_order:
		for outing_row in (by_team[tid] as Array):
			var outing: Dictionary = outing_row as Dictionary
			var pid: int = int(outing.get("pitcher_id", 0))
			var record: PSPlayerSeasonRecord = _record(pid, season)
			var tally: Dictionary = tallies.get(pid, {}) as Dictionary
			var mark: String = ""
			if pid == win_id:
				mark = "○"
			elif pid == loss_id:
				mark = "●"
			elif pid == save_id:
				mark = "Ｓ"
			elif holds.has(pid):
				mark = "Ｈ"
			rows.append({
				"team_id": tid,
				"mark": mark,
				"name": record.name if record != null else "#%d" % pid,
				"throws": _throws_label(record),
				"w": record.pitcher_stats.wins if record != null else 0,
				"l": record.pitcher_stats.losses if record != null else 0,
				"s": record.pitcher_stats.saves if record != null else 0,
				"g": record.pitcher_stats.games if record != null else 0,
				"ip": _ip_str(int(outing.get("outs", 0))),
				"bf": int(outing.get("batters_faced", 0)),
				"pitches": int(outing.get("pitches", 0)),
				"h": int(tally.get("h", 0)),
				"k": int(tally.get("k", 0)),
				"bb": int(tally.get("bb", 0)),
				"hbp": int(tally.get("hbp", 0)),
				"r": int(outing.get("runs", 0)),
				"er": int(outing.get("earned_runs", 0)),
				"era": record.pitcher_stats.era() if record != null else 0.0,
			})
	return {"rows": rows}


static func _pitcher_pa_tallies(pa_log: Array) -> Dictionary:
	var out: Dictionary = {}
	for row_value in pa_log:
		var pa: Dictionary = row_value as Dictionary
		var pid: int = int(pa.get("pitcher_id", 0))
		if pid <= 0:
			continue
		if not out.has(pid):
			out[pid] = {"h": 0, "k": 0, "bb": 0, "hbp": 0}
		var t: Dictionary = out[pid]
		match str(pa.get("category", "")):
			"hit":
				t["h"] = int(t["h"]) + 1
			"strikeout":
				t["k"] = int(t["k"]) + 1
			"walk":
				t["bb"] = int(t["bb"]) + 1
			"hit_by_pitch":
				t["hbp"] = int(t["hbp"]) + 1
		out[pid] = t
	return out


static func _throws_label(record: PSPlayerSeasonRecord) -> String:
	if record == null:
		return ""
	return "左" if str(record.throwing_hand) == "L" else "右"


static func _ip_str(outs: int) -> String:
	@warning_ignore("integer_division")
	var full: int = outs / 3
	var rem: int = outs % 3
	return str(full) if rem == 0 else "%d.%d" % [full, rem]


# 各種記録。{hr: Array[String], errors: Array[String]}
static func build_records(log_data: Dictionary, season: PSSeason) -> Dictionary:
	var hr: Array = []
	for row_value in (log_data.get("pa_log", []) as Array):
		var pa: Dictionary = row_value as Dictionary
		if str(pa.get("category", "")) != "hit" or int(pa.get("bases", 0)) < 4:
			continue
		var batter: PSPlayerSeasonRecord = _record(int(pa.get("batter_id", 0)), season)
		var pitcher: PSPlayerSeasonRecord = _record(int(pa.get("pitcher_id", 0)), season)
		hr.append("%s %d号 (%s = %s)" % [
			batter.name if batter != null else "?",
			int(pa.get("hr_number", 0)),
			_hr_run_label(int(pa.get("rbi", 1))),
			pitcher.name if pitcher != null else "?",
		])
	var errors: Array = []
	for e_row in (log_data.get("errors", []) as Array):
		var e: Dictionary = e_row as Dictionary
		var fielder: PSPlayerSeasonRecord = _record(int(e.get("fielder_id", 0)), season)
		errors.append("%s(%d回)" % [fielder.name if fielder != null else "-", int(e.get("inning", 0))])
	return {"hr": hr, "errors": errors}


static func _hr_run_label(rbi: int) -> String:
	match rbi:
		4:
			return "満塁"
		3:
			return "3ラン"
		2:
			return "2ラン"
	return "ソロ"


static func _record(player_id: int, season: PSSeason) -> PSPlayerSeasonRecord:
	if player_id <= 0 or season == null:
		return null
	return RecordStore.get_player_record(player_id, season.year, season.season_number)
