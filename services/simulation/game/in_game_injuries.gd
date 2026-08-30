extends RefCounted
class_name PSInGameInjuries

# 試合中の負傷交代。**故障の発生判定そのものは行わない** — 既存の1試合1回の判定
# (PSInjuryModel) が当たったとき、そのうち一定割合を「試合中に起きた」扱いにして、
# 途中交代させるところだけを担う。したがってシーズンの故障件数・離脱日数は不変。
#
# 予約は setup に置き、発生機序ごとに違う場面で発火させる:
#   投手 (投球中)     … 登板中の球数がしきい値を超えた打席の直後
#   野手 (走塁/打撃/死球) … その選手の打席が終わった直後 (死球ならその場で確定)
#   野手 (守備)       … その選手が打球を処理した直後
# 発火しないままイニングが進んだ場合は 8回終了時に打ち切って交代させる
# (故障自体は既に record へ適用済みなので、交代が起きなくても離脱日数は消えない)。
#
# 設計と実データの出典: docs/agent_memory/project_injury_system.md

const EXITS_KEY: String = "in_game_injury_exits"
# 予約が発火しないまま試合が進んだときに打ち切るイニング。
const FALLBACK_INNING: int = 8
# 投手が降板する球数の予約幅 (その登板の想定球数に対する割合)。
const PITCHER_EXIT_MIN_RATIO: float = 0.15
const PITCHER_EXIT_MAX_RATIO: float = 0.85


# --- 予約 ------------------------------------------------------------------

# 故障判定が当たった選手に対し、試合中に降板/交代させるかを引いて予約する。
# injury は PSInjuryModel.maybe_injure の戻り値 (空なら何もしない)。
static func schedule_if_in_game(
	setup: Dictionary,
	record: PSPlayerSeasonRecord,
	is_pitcher: bool,
	injury: Dictionary,
	usage: Dictionary = {}
) -> void:
	if record == null or injury.is_empty():
		return
	if not PSInjuryModel.rolls_in_game_exit(is_pitcher):
		return
	var cause: String = PSInjuryModel.roll_in_game_cause(is_pitcher)
	var exits: Dictionary = setup.get(EXITS_KEY, {}) as Dictionary
	var entry: Dictionary = {
		"cause": cause,
		"is_pitcher": is_pitcher,
		"label": str(injury.get("label", "")),
	}
	if is_pitcher:
		entry["at_pitches"] = _pitcher_exit_pitches(record, usage)
	exits[record.player_id] = entry
	setup[EXITS_KEY] = exits


# 降板する球数。登板の想定球数の 15〜85% の範囲に散らす (立ち上がりから終盤まで起こりうる)。
static func _pitcher_exit_pitches(record: PSPlayerSeasonRecord, usage: Dictionary) -> int:
	var workload: int = int(usage.get("workload_pitches", 0))
	if workload <= 0:
		workload = PSPitcherUsageModel.outing_workload_pitches(
			record, str(usage.get("role", PSPitcherUsageModel.ROLE_STARTER))
		)
	# 基準は workload (スタミナ限界) ではなく**実際に投げる見込みの球数**。限界球数を基準にすると
	# 予約が実際の降板より後ろに落ちて、予約の4割しか発火しなかった。
	var expected: float = float(workload) * PSPitcherUsageModel.EXPECTED_OUTING_PITCH_RATIO
	var ratio: float = lerp(PITCHER_EXIT_MIN_RATIO, PITCHER_EXIT_MAX_RATIO, Rng.roll_float())
	return int(max(1.0, round(expected * ratio)))


static func has_pending_exit(setup: Dictionary, player_id: int) -> bool:
	return (setup.get(EXITS_KEY, {}) as Dictionary).has(player_id)


static func _take_exit(setup: Dictionary, player_id: int) -> Dictionary:
	var exits: Dictionary = setup.get(EXITS_KEY, {}) as Dictionary
	if not exits.has(player_id):
		return {}
	var entry: Dictionary = exits[player_id] as Dictionary
	exits.erase(player_id)
	setup[EXITS_KEY] = exits
	return entry


# --- 投手 ------------------------------------------------------------------

# 予約した球数に達していれば true (呼び出し側が強制降板させる)。
static func pitcher_must_leave(setup: Dictionary, pitcher: PSPlayerSeasonRecord, usage: Dictionary) -> bool:
	if pitcher == null:
		return false
	var exits: Dictionary = setup.get(EXITS_KEY, {}) as Dictionary
	if not exits.has(pitcher.player_id):
		return false
	var entry: Dictionary = exits[pitcher.player_id] as Dictionary
	return int(usage.get("pitches", 0)) >= int(entry.get("at_pitches", 0))


static func take_pitcher_exit(setup: Dictionary, pitcher: PSPlayerSeasonRecord) -> Dictionary:
	if pitcher == null:
		return {}
	return _take_exit(setup, pitcher.player_id)


# --- 野手 ------------------------------------------------------------------

# 打席が終わった直後の判定。死球を受けた打者は、予約の発生機序に関係なくその場で交代する
# (実データでも死球は手・指と頭部が中心で、そのまま退く場面が多い)。
static func maybe_replace_after_plate_appearance(
	offense: Dictionary, batter: PSPlayerSeasonRecord, hit_by_pitch: bool
) -> Dictionary:
	if batter == null or not has_pending_exit(offense, batter.player_id):
		return {}
	var entry: Dictionary = (offense.get(EXITS_KEY, {}) as Dictionary)[batter.player_id] as Dictionary
	var cause: String = str(entry.get("cause", ""))
	if not hit_by_pitch and cause != PSInjuryModel.CAUSE_RUNNING and cause != PSInjuryModel.CAUSE_BATTING:
		return {}
	if hit_by_pitch:
		entry["cause"] = PSInjuryModel.CAUSE_HIT_BY_PITCH
	return _replace_now(offense, batter, entry)


# 打球を処理した直後の判定 (打球直撃・送球)。
static func maybe_replace_fielder_after_play(defense: Dictionary, fielder_position: int) -> Dictionary:
	if fielder_position < 2 or fielder_position > 9:
		return {}
	var fielder: PSPlayerSeasonRecord = _fielder_at(defense, fielder_position)
	if fielder == null or not has_pending_exit(defense, fielder.player_id):
		return {}
	var entry: Dictionary = (defense.get(EXITS_KEY, {}) as Dictionary)[fielder.player_id] as Dictionary
	if str(entry.get("cause", "")) != PSInjuryModel.CAUSE_FIELDING:
		return {}
	return _replace_now(defense, fielder, entry)


# 発火しないまま終盤まで来た予約を打ち切る (守備側の回の切れ目で呼ぶ)。
static func flush_pending_exits(setup: Dictionary, inning: int) -> Array:
	if inning < FALLBACK_INNING:
		return []
	var exits: Dictionary = setup.get(EXITS_KEY, {}) as Dictionary
	if exits.is_empty():
		return []
	var applied: Array = []
	for player_id in exits.keys().duplicate():
		var entry: Dictionary = exits[player_id] as Dictionary
		if bool(entry.get("is_pitcher", false)):
			continue
		var fielder: PSPlayerSeasonRecord = _lineup_player(setup, int(player_id))
		if fielder == null:
			_take_exit(setup, int(player_id))
			continue
		var option: Dictionary = _replace_now(setup, fielder, entry)
		if not option.is_empty():
			applied.append(option)
	return applied


# 実際に控えと入れ替える。控えが居ない (ベンチが尽きた/守れる選手が居ない) ときは
# 予約だけ消してそのまま出場を続けさせる — 実際の試合でも交代要員が無ければ続行する。
static func _replace_now(
	setup: Dictionary, record: PSPlayerSeasonRecord, entry: Dictionary
) -> Dictionary:
	var option: Dictionary = PSInGameSubstitutions.injury_replacement_option(setup, record)
	_take_exit(setup, record.player_id)
	if option.is_empty():
		return {}
	PSInGameSubstitutions.apply_defensive_replacement(setup, option)
	option["injury_cause"] = str(entry.get("cause", ""))
	option["injury_label"] = str(entry.get("label", ""))
	return option


static func _fielder_at(setup: Dictionary, position: int) -> PSPlayerSeasonRecord:
	for assignment_row in (setup.get("fielders", []) as Array):
		var assignment: Dictionary = assignment_row as Dictionary
		if int(assignment.get("position", 0)) == position:
			return assignment.get("record", null) as PSPlayerSeasonRecord
	return null


static func _lineup_player(setup: Dictionary, player_id: int) -> PSPlayerSeasonRecord:
	for batter_row in (setup.get("batters", []) as Array):
		var batter: PSPlayerSeasonRecord = batter_row as PSPlayerSeasonRecord
		if batter != null and batter.player_id == player_id:
			return batter
	return null
