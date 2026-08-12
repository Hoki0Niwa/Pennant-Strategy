extends RefCounted
class_name PSRotationPlanner

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

# 先発ローテは「月曜始まりの暦週」を単位に、序列 (rotation 配列の並び) 順で割り当てる。
# 週が変わると必ず1番手から始まり、かつ中6日が空くまで待つ (SELECTION_PASSES の段0) ので、
# 各投手が事実上「自分の曜日」を持つ形に落ち着く。結果として次が同時に成立する:
#   - エースをはじめ上位ほど毎週同じ曜日に回ってくる
#   - 試合が6に満たない週は序列下位が飛ぶ (翌週、空いた曜日に戻ってくる)
#   - 週7試合 (祝日月曜) や健康な先発が6人未満の週だけ中5日が発生する
# 判断材料は「その日の日付」と「各投手の最終登板日」だけで、日程配列 (season.schedule) は読まない。
# 将来の登板予定をどこにも保存しないので、雨天順延で試合が消えても振替が後日に生えても、
# 次の呼び出しがそのまま新しい日程に追随する (順延時に作り直すべき状態が存在しない)。
const ROTATION_SIZE_MAX: int = 6
const RELIEF_ROLE_SIZE_MAX: int = 6
const STARTER_DANGER_FATIGUE: int = 145

# 登板間隔は最終登板日との日数差で数える (差7 = 中6日)。
const STANDARD_REST_DAY_GAP: int = 7
const SHORT_REST_DAY_GAP: int = 6
const MIN_REST_DAY_GAP: int = 5
# 中5日を許す疲労の上限 (調整ノブ)。先発1試合の疲労増は約100、日次回復は12〜25なので、
# 回復力/スタミナが高い投手だけが5日でこの線を下回る。
const SHORT_REST_MAX_FATIGUE: int = 30

const WEEKDAY_MONDAY: int = 1
const DAYS_PER_WEEK: int = 7

# 開幕時に「序列 ↔ 登板曜日」の対応を球団ごとにずらす数。ずらさないと全球団が同じ日に1番手を立て、
# そのまま全員中6日で回るため、毎週その曜日は全カードがエース対決になる (2026-08-10 の実測で
# 1番手の82%が同一曜日、しかも全球団共通だった)。4 にすると開幕投手は序列1〜4番手に散り、
# エースの登板曜日も4通りに分かれる。6 まで広げると開幕投手が6番手になる球団が出るのでここで止める。
const ROTATION_PHASE_SPREAD: int = 4
# 仮想の最終登板日を与える期間。全員が実際の登板日を持つまでの繋ぎなので開幕2週間で足りる。
const PHASE_SEED_DAYS: int = 15

# 終盤 (9月以降) は序列上位を中5日で前倒しできる。疲労が十分に抜けている投手だけが対象なので、
# スタミナ/回復力の高いエースが数回前倒しになる程度に収まる。
const STRETCH_RUN_MONTH: int = 9
const STRETCH_RUN_ACE_SLOTS: int = 2
const STRETCH_RUN_MAX_FATIGUE: int = 15

# ローテが中6日で埋まらない日に立てるスポット先発 (ロングリリーフ) の条件。
# 抑え/セットアッパーは抜かない (ブルペンの軸を壊さない)。
const SPOT_STARTER_MAX_FATIGUE: int = 25
const BULLPEN_CORE_SIZE: int = 3

# ポストシーズンは短期決戦。序列上位だけで回し、中5日・中4日を通常運用として許す。
const POSTSEASON_ROTATION_SIZE: int = 4
const POSTSEASON_SHORT_REST_MAX_FATIGUE: int = 60

# 先発を選ぶ段。上から順に試し、埋まらなければ次の段へ緩める。
# [今週登板済みも許すか, 必要な登板間隔, 手動スキップを尊重するか, reason]
#   0: 通常運用。中6日が空くまで待つので、各投手の登板曜日が週をまたいで保たれる。
#      前の週が短くて飛ばされた投手は、ここで空いた曜日に戻ってくる。
#   1: 中6日が誰も空いていない日だけ中5日を許す (疲労が抜けている投手に限る)。
#   2: 今週登板済みからも中5日で立てる (週7試合や健康な先発が6人未満の週)。
#   3〜5: 順延などで日程が詰まったときの緩和。最後は手動スキップ指定も無視する。
const SELECTION_PASSES: Array = [
	[false, STANDARD_REST_DAY_GAP, true, "rotation"],
	[false, SHORT_REST_DAY_GAP, true, "short_rest"],
	[true, SHORT_REST_DAY_GAP, true, "short_rest"],
	[false, MIN_REST_DAY_GAP, true, "min_rest"],
	[true, MIN_REST_DAY_GAP, true, "min_rest"],
	[true, MIN_REST_DAY_GAP, false, "min_rest"],
]

const RELIEF_ROLE_LONG: String = "long"
const RELIEF_ROLE_MIDDLE: String = "middle"
const RELIEF_ROLE_SETUP: String = "setup"
const RELIEF_ROLE_CLOSER: String = "closer"


# 二軍のローテ序列は `farm_pitcher_ids` に分けて持つ。**`last_start_day_by_pitcher`
# (登板間隔の台帳) と `manual_skip_pitcher_ids` は一軍と共有する** — 台帳を分けると
# 「二軍で投げた翌日に昇格して中0日で先発」が起きるため。疲労 (`record.fatigue`) も同様に共有。
const FARM_PITCHER_IDS_KEY: String = "farm_pitcher_ids"


# 指定レベルから見たローテ状態。序列キーだけ差し替えた view を返す
# (呼び出し側は `pitcher_ids` を読むだけでよく、レベルを意識しなくて済む)。
static func rotation_state_for_level(season: PSSeason, team_id: int, level: int) -> Dictionary:
	var saved: Dictionary = season.get_rotation(team_id) if season != null else {}
	if level == PSTeamSetupBuilder.LEVEL_FIRST:
		return saved
	var view: Dictionary = saved.duplicate()
	view["pitcher_ids"] = (saved.get(FARM_PITCHER_IDS_KEY, []) as Array).duplicate()
	# 二軍の序列は自動生成のみ (二軍用のローテ編集画面は持たない)。
	view["auto_generated"] = true
	return view


static func resolve_rotation_decision(
	season: PSSeason,
	team_id: int,
	starter_pitchers: Array,
	reliever_pool: Array = [],
	postseason: bool = false,
	saved_override: Dictionary = {}
) -> Dictionary:
	var saved: Dictionary = saved_override
	if saved.is_empty():
		saved = season.get_rotation(team_id) if season != null else {}
	var rotation: Array = resolve_rotation_order_from_saved(saved, starter_pitchers)
	if rotation.is_empty():
		return {
			"pitcher": null,
			"order": [],
			"order_ids": [],
			"selected_index": -1,
			"reason": "empty",
		}

	var current_day: int = 1 if season == null else season.current_day
	var last_starts: Dictionary = _seeded_last_starts(
		saved.get("last_start_day_by_pitcher", {}) as Dictionary, rotation, team_id, current_day
	)
	var manual_skips: Dictionary = _id_set(saved.get("manual_skip_pitcher_ids", []) as Array)

	var chosen: Dictionary = {}
	if postseason:
		chosen = _postseason_candidate(rotation, current_day, last_starts, manual_skips)
	if chosen.is_empty():
		chosen = select_starter_for_day(
			rotation, current_day, week_start_day(season, current_day), last_starts, manual_skips,
			0, _is_stretch_run(season, current_day),
			_spot_pool(rotation, starter_pitchers, reliever_pool), saved
		)
	if chosen.is_empty():
		chosen = _spot_starter_candidate(saved, starter_pitchers, current_day, last_starts)
	if chosen.is_empty():
		chosen = _best_emergency_starter(rotation, current_day, last_starts)

	var pitcher: PSPlayerSeasonRecord = chosen.get("pitcher", null) as PSPlayerSeasonRecord
	return {
		"pitcher": pitcher,
		"order": rotation,
		"order_ids": _record_ids(rotation),
		"selected_index": int(chosen.get("index", -1)),
		"reason": str(chosen.get("reason", "")),
	}


# 指定日に投げる先発を序列順で選ぶ。days_from_now に先の日数を渡せば疲労を回復見込みで
# 前倒し評価するので、予告先発の先読み表示でも同じ規則をそのまま使える。
static func select_starter_for_day(
	rotation: Array,
	day: int,
	week_start: int,
	last_starts: Dictionary,
	manual_skips: Dictionary,
	days_from_now: int = 0,
	stretch_run: bool = false,
	spot_pool: Array = [],
	saved: Dictionary = {}
) -> Dictionary:
	# 終盤は序列上位を中5日で前倒しする (十分に回復している投手だけ)。
	if stretch_run:
		var ace: Dictionary = _stretch_run_candidate(rotation, day, week_start, last_starts, manual_skips, days_from_now)
		if not ace.is_empty():
			return ace
	# 各段の中では序列順に見て、条件を満たす最初の1人を採る。
	for pass_index in range(SELECTION_PASSES.size()):
		var chosen: Dictionary = _pick_starter(
			rotation, day, week_start, last_starts, manual_skips, days_from_now, pass_index
		)
		if not chosen.is_empty():
			return chosen
		# 中6日 (段0) で埋まらなければ、ローテを短い間隔で使い回す前に代役を立てる。
		# NPB の「連戦の谷間は7人目の先発かロングリリーフ」に相当し、先発の顔ぶれも増える。
		if pass_index == 0:
			var spot: Dictionary = _spot_starter_from_pool(spot_pool, saved, days_from_now)
			if not spot.is_empty():
				return spot
	return {}


# 月曜始まりの週の初日 (season day)。週境界は暦だけで決まるので、日程が順延で動いても
# 「今週もう投げたか」の判定は影響を受けない。
static func week_start_day(season: PSSeason, day: int) -> int:
	if season == null:
		return day
	var date_text: String = SeasonCalendar.date_for_season_day(season, day)
	if date_text.is_empty():
		return day
	var weekday: int = SeasonCalendar.weekday_for_date(date_text)
	return day - posmod(weekday - WEEKDAY_MONDAY, DAYS_PER_WEEK)


# 開幕時、まだ実際の登板日を持たない投手へ球団ごとにずらした仮想の最終登板日を入れる。
# 球団 phase の分だけ「誰が開幕戦を投げるか」がずれ、以後の登板曜日も球団ごとに分かれる。
static func _seeded_last_starts(recorded: Dictionary, rotation: Array, team_id: int, day: int) -> Dictionary:
	if day > PHASE_SEED_DAYS or rotation.is_empty():
		return recorded
	var size: int = rotation.size()
	var phase: int = posmod(team_id, ROTATION_PHASE_SPREAD)
	var seeded: Dictionary = recorded.duplicate()
	for index in range(size):
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if pitcher == null or int(seeded.get(str(pitcher.player_id), 0)) > 0:
			continue
		# 序列 index の投手は開幕から posmod(index - phase, size) 日目に中6日で回ってくる。
		seeded[str(pitcher.player_id)] = 1 + posmod(index - phase, size) - STANDARD_REST_DAY_GAP
	return seeded


static func _is_stretch_run(season: PSSeason, day: int) -> bool:
	if season == null:
		return false
	var date_text: String = SeasonCalendar.date_for_season_day(season, day)
	if date_text.is_empty():
		return false
	return int(date_text.split("-")[1]) >= STRETCH_RUN_MONTH


# 終盤に序列上位を中5日で立てる。疲労が抜けきっている投手に限るので、
# スタミナ/回復力の高いエースだけが数回前倒しになる。
static func _stretch_run_candidate(
	rotation: Array,
	day: int,
	week_start: int,
	last_starts: Dictionary,
	manual_skips: Dictionary,
	days_from_now: int
) -> Dictionary:
	var limit: int = mini(STRETCH_RUN_ACE_SLOTS, rotation.size())
	for index in range(limit):
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if pitcher == null or pitcher.injury_days > 0 or manual_skips.has(pitcher.player_id):
			continue
		var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
		if last_day == 0 or last_day >= week_start:
			continue
		var gap: int = day - last_day
		if gap != SHORT_REST_DAY_GAP:
			continue
		if _projected_fatigue(pitcher, days_from_now) > STRETCH_RUN_MAX_FATIGUE:
			continue
		return {"pitcher": pitcher, "index": index, "reason": "stretch_run"}
	return {}


# スポット先発の候補: ローテ6人に入らなかった先発 (一軍の7人目) を先に、次にブルペン。
static func _spot_pool(rotation: Array, starter_pitchers: Array, reliever_pool: Array) -> Array:
	var in_rotation: Dictionary = _records_by_id(rotation)
	var pool: Array = []
	for pitcher_value in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_value as PSPlayerSeasonRecord
		if pitcher != null and not in_rotation.has(pitcher.player_id):
			pool.append(pitcher)
	pool.append_array(reliever_pool)
	return pool


# ローテが中6日で埋まらない日の代役。7人目の先発を優先し、いなければブルペンから。
# 抑え/セットアッパーはブルペンの軸なので外す。
static func _spot_starter_from_pool(spot_pool: Array, saved: Dictionary, days_from_now: int) -> Dictionary:
	if spot_pool.is_empty():
		return {}
	var excluded: Dictionary = _bullpen_core_ids(spot_pool, saved)
	var best: PSPlayerSeasonRecord = null
	var best_score: float = -999999.0
	var best_is_starter: bool = false
	for pitcher_value in spot_pool:
		var pitcher: PSPlayerSeasonRecord = pitcher_value as PSPlayerSeasonRecord
		if pitcher == null or pitcher.injury_days > 0:
			continue
		var is_starter: bool = pitcher.is_starter_pitcher()
		if not is_starter and excluded.has(pitcher.player_id):
			continue
		if _projected_fatigue(pitcher, days_from_now) > SPOT_STARTER_MAX_FATIGUE:
			continue
		var score: float = PSPitcherRoleModel.starter_order_score(pitcher)
		if best == null or (is_starter and not best_is_starter) \
				or (is_starter == best_is_starter and score > best_score):
			best = pitcher
			best_score = score
			best_is_starter = is_starter
	if best == null:
		return {}
	return {"pitcher": best, "index": -1, "reason": "spot_starter" if best_is_starter else "spot_relief"}


# スポット先発に回してはいけないブルペンの軸 (抑え + セットアッパー相当の上位3人)。
# 役割が明示保存されていればそれを、無ければ素の能力上位を軸とみなす。
static func _bullpen_core_ids(reliever_pool: Array, saved: Dictionary) -> Dictionary:
	var core: Dictionary = {}
	var role_ids: Array = relief_role_order_ids(saved)
	if not role_ids.is_empty():
		for index in range(mini(BULLPEN_CORE_SIZE, role_ids.size())):
			core[int(role_ids[index])] = true
		return core
	var ordered: Array = reliever_pool.duplicate()
	ordered.sort_custom(_by_pitching_score(_pitching_scores_by_id(ordered)))
	for index in range(mini(BULLPEN_CORE_SIZE, ordered.size())):
		var pitcher: PSPlayerSeasonRecord = ordered[index] as PSPlayerSeasonRecord
		if pitcher != null:
			core[pitcher.player_id] = true
	return core


# ポストシーズン専用。短期決戦なので序列上位だけで回し、中5日・中4日を通常運用として許す
# (週単位の割り当てはペナント用の規則なので使わない)。ここで埋まらなければ通常経路へ落ちる。
static func _postseason_candidate(
	rotation: Array,
	day: int,
	last_starts: Dictionary,
	manual_skips: Dictionary
) -> Dictionary:
	var limit: int = mini(POSTSEASON_ROTATION_SIZE, rotation.size())
	for min_gap in [SHORT_REST_DAY_GAP, MIN_REST_DAY_GAP]:
		for index in range(limit):
			var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
			if pitcher == null or pitcher.injury_days > 0 or manual_skips.has(pitcher.player_id):
				continue
			if pitcher.fatigue >= STARTER_DANGER_FATIGUE:
				continue
			var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
			var gap: int = 9999 if last_day == 0 else day - last_day
			if gap < int(min_gap):
				continue
			if gap < STANDARD_REST_DAY_GAP and pitcher.fatigue > POSTSEASON_SHORT_REST_MAX_FATIGUE:
				continue
			return {"pitcher": pitcher, "index": index, "reason": "postseason"}
	return {}


static func _pick_starter(
	rotation: Array,
	day: int,
	week_start: int,
	last_starts: Dictionary,
	manual_skips: Dictionary,
	days_from_now: int,
	pass_index: int
) -> Dictionary:
	var spec: Array = SELECTION_PASSES[pass_index] as Array
	var allow_used_this_week: bool = bool(spec[0])
	var min_gap: int = int(spec[1])
	var honor_manual_skip: bool = bool(spec[2])
	var reason: String = str(spec[3])
	# 中5日を許す段でだけ疲労を見る。中4日まで緩めた段は「他に立てる者がいない」状況なので、
	# 危険域 (STARTER_DANGER_FATIGUE) だけを見て通す。
	var gate_short_rest: bool = min_gap > MIN_REST_DAY_GAP

	for index in range(rotation.size()):
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if pitcher == null or pitcher.injury_days > 0:
			continue
		if honor_manual_skip and manual_skips.has(pitcher.player_id):
			continue
		# last_day は 0 = 未登板。開幕直後は _seeded_last_starts が球団ごとにずらした
		# 仮想値 (負値もありうる) を入れるので、0 かどうかだけで未登板を判定する。
		var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
		if not allow_used_this_week and last_day != 0 and last_day >= week_start:
			continue
		var gap: int = day - last_day if last_day != 0 else 9999
		if gap < min_gap:
			continue
		var fatigue: int = _projected_fatigue(pitcher, days_from_now)
		if fatigue >= STARTER_DANGER_FATIGUE:
			continue
		# 中5日は疲労が十分に抜けている投手にだけ許す。
		if gate_short_rest and gap < STANDARD_REST_DAY_GAP and fatigue > SHORT_REST_MAX_FATIGUE:
			continue
		return {"pitcher": pitcher, "index": index, "reason": reason}
	return {}


# days_from_now 日後の疲労見込み。日次回復量は確定値なので先読みでも正確に出せる。
static func _projected_fatigue(pitcher: PSPlayerSeasonRecord, days_from_now: int) -> int:
	if pitcher == null:
		return 0
	if days_from_now <= 0:
		return pitcher.fatigue
	var recovery: int = PSPitcherUsageModel.daily_recovery_amount(pitcher) * days_from_now
	return int(max(0, pitcher.fatigue - recovery))


static func record_rotation_start(
	season: PSSeason, team_id: int, setup: Dictionary, day: int, level: int = PSTeamSetupBuilder.LEVEL_FIRST
) -> void:
	if season == null or team_id <= 0:
		return
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", setup.get("pitcher", null)) as PSPlayerSeasonRecord
	if starter == null:
		return
	var stored: Dictionary = season.get_rotation(team_id).duplicate(true)
	# 序列はレベルごとのキーへ書く。台帳 (last_start_day_by_pitcher) は下で共有のまま更新する。
	var order_key: String = "pitcher_ids" if level == PSTeamSetupBuilder.LEVEL_FIRST else FARM_PITCHER_IDS_KEY
	var order_ids: Array = (setup.get("rotation_order_ids", []) as Array).duplicate()
	if order_ids.is_empty():
		order_ids = (stored.get(order_key, []) as Array).duplicate()
	if (stored.get(order_key, []) as Array).is_empty() and not order_ids.is_empty():
		stored[order_key] = order_ids
		if level == PSTeamSetupBuilder.LEVEL_FIRST:
			stored["auto_generated"] = true

	# 次に誰が投げるかは保存せず、毎回 last_start_day_by_pitcher から導出する
	# (順延で日程が動いても作り直す状態が無いのが狙い)。
	var last_starts: Dictionary = (stored.get("last_start_day_by_pitcher", {}) as Dictionary).duplicate(true)
	last_starts[str(starter.player_id)] = day
	stored["last_start_day_by_pitcher"] = last_starts
	stored["last_start_pitcher_id"] = starter.player_id
	stored["last_start_day"] = day

	var manual_skips: Array = (stored.get("manual_skip_pitcher_ids", []) as Array).duplicate()
	if manual_skips.has(starter.player_id):
		manual_skips.erase(starter.player_id)
		stored["manual_skip_pitcher_ids"] = manual_skips

	season.set_rotation(team_id, stored)


# 自動生成ローテの序列を成績込みの評価 (TeamAutoAI.perf_score) で組み替える。一二軍入替と同じ
# 週次フックから呼ばれる。手動編成 (auto_generated=false) は利用者の意図なので触らない。
# 序列は「試合の少ない週に誰が飛ぶか」と「同じ日に複数人が投げられるときの優先順」を決めるので、
# 不振の投手は下位へ落ちて登板数が減り、好調な投手や昇格してきた投手が上がる。
static func reorder_auto_rotation(season: PSSeason, team_id: int, starter_pitchers: Array, score_by_id: Dictionary) -> bool:
	if season == null or team_id <= 0:
		return false
	var saved: Dictionary = season.get_rotation(team_id)
	if saved.is_empty() or not bool(saved.get("auto_generated", false)):
		return false
	var current_ids: Array = saved.get("pitcher_ids", []) as Array
	if current_ids.size() <= 1:
		return false

	# 現ローテ + 一軍の先発 role を候補にして、評価上位から ROTATION_SIZE_MAX 人を採る。
	var candidates: Array = []
	var seen: Dictionary = {}
	var by_id: Dictionary = _records_by_id(starter_pitchers)
	for id_value in current_ids:
		var pid: int = int(id_value)
		if pid <= 0 or seen.has(pid) or not by_id.has(pid):
			continue
		candidates.append(pid)
		seen[pid] = true
	for pitcher_value in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_value as PSPlayerSeasonRecord
		if pitcher == null or seen.has(pitcher.player_id):
			continue
		candidates.append(pitcher.player_id)
		seen[pitcher.player_id] = true
	if candidates.is_empty():
		return false

	candidates.sort_custom(func(a, b) -> bool:
		return float(score_by_id.get(int(a), 0.0)) > float(score_by_id.get(int(b), 0.0))
	)
	var next_ids: Array = candidates.slice(0, mini(ROTATION_SIZE_MAX, candidates.size()))
	if next_ids == current_ids:
		return false
	var stored: Dictionary = saved.duplicate(true)
	stored["pitcher_ids"] = next_ids
	season.set_rotation(team_id, stored)
	return true


static func resolve_rotation_order_from_saved(saved: Dictionary, starter_pitchers: Array) -> Array:
	if starter_pitchers.is_empty():
		return []
	var by_id: Dictionary = {}
	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		by_id[pitcher.player_id] = pitcher

	var rotation: Array = []
	var used: Dictionary = {}
	var saved_ids: Array = saved.get("pitcher_ids", []) as Array
	for id_value in saved_ids:
		var pid: int = int(id_value)
		if pid <= 0 or not by_id.has(pid) or used.has(pid):
			continue
		var pitcher: PSPlayerSeasonRecord = by_id[pid] as PSPlayerSeasonRecord
		if pitcher.injury_days > 0:
			continue
		rotation.append(pitcher)
		used[pid] = true

	# 保存順に無い先発は疲労を含まない素の評価順 (= 序列) で後ろへ足す。疲労込みで並べると
	# 序列が日替わりで入れ替わり、週単位で固定したい登板曜日が乱れる。
	var rest: Array = []
	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if used.has(pitcher.player_id):
			continue
		rest.append(pitcher)
	rest.sort_custom(_by_pitching_score(_pitching_scores_by_id(rest)))
	for pitcher_row in rest:
		if rotation.size() >= ROTATION_SIZE_MAX:
			break
		rotation.append(pitcher_row)

	return rotation


static func _spot_starter_candidate(saved: Dictionary, starter_pitchers: Array, current_day: int, last_starts: Dictionary) -> Dictionary:
	var spot_id: int = int(saved.get("spot_starter_id", 0))
	if spot_id <= 0:
		return {}
	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if pitcher == null or pitcher.player_id != spot_id:
			continue
		if _can_start_pitcher(pitcher, current_day, last_starts, true, true):
			return {"pitcher": pitcher, "index": -1, "reason": "spot"}
	return {}


static func _best_emergency_starter(rotation: Array, current_day: int, last_starts: Dictionary) -> Dictionary:
	var best: PSPlayerSeasonRecord = null
	var best_index: int = -1
	var best_score: float = -999999.0
	for index in range(rotation.size()):
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if pitcher == null or pitcher.injury_days > 0:
			continue
		var score: float = _emergency_start_score(pitcher, current_day, last_starts)
		if best == null or score > best_score:
			best = pitcher
			best_index = index
			best_score = score
	if best == null:
		return {}
	return {"pitcher": best, "index": best_index, "reason": "emergency"}


static func _can_start_pitcher(
	pitcher: PSPlayerSeasonRecord,
	current_day: int,
	last_starts: Dictionary,
	require_rest: bool,
	require_fatigue: bool
) -> bool:
	if pitcher == null or pitcher.injury_days > 0:
		return false
	if require_fatigue and pitcher.fatigue >= STARTER_DANGER_FATIGUE:
		return false
	if require_rest and not _has_minimum_rest(pitcher, current_day, last_starts):
		return false
	return true


static func _has_minimum_rest(pitcher: PSPlayerSeasonRecord, current_day: int, last_starts: Dictionary) -> bool:
	if pitcher == null:
		return false
	var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
	if last_day <= 0:
		return true
	return current_day - last_day >= MIN_REST_DAY_GAP


static func _emergency_start_score(pitcher: PSPlayerSeasonRecord, current_day: int, last_starts: Dictionary) -> float:
	var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
	var rest_days: int = 999 if last_day <= 0 else max(0, current_day - last_day - 1)
	var rest_score: float = float(min(rest_days, 10)) * 18.0
	return rest_score + float(PlayerValueEvaluator.pitching_score_without_fatigue(pitcher)) - float(pitcher.fatigue) * 1.7


static func _record_ids(records: Array) -> Array:
	var ids: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			ids.append(record.player_id)
	return ids


static func _id_set(ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for id_value in ids:
		out[int(id_value)] = true
	return out


static func select_relievers_for_innings(
	reliever_pool: Array,
	starter_pool_fallback: Array,
	exclude_pitcher_id: int,
	saved: Dictionary = {}
) -> Array:
	var eligible: Array = []
	for r in reliever_pool:
		var pitcher: PSPlayerSeasonRecord = r as PSPlayerSeasonRecord
		if pitcher.player_id == exclude_pitcher_id or pitcher.injury_days > 0:
			continue
		eligible.append(pitcher)
	# ブルペン編成と役割割り当ては疲労を含まない素の能力で並べる。fatigue 込みの評価値で並べると、
	# エース救援が疲れた日に評価が下がってクローザーの座が日替わりで入れ替わり、現実離れした「日替わり抑え」と
	# セーブ数の分散を招く。疲労は登板可否 (is_reliever_available) と試合中の選抜スコア側で別途効くので、
	# 「誰が抑えか」は能力で固定し、疲れた日は控えが代役を務める形にする。
	eligible.sort_custom(_by_pitching_score(_pitching_scores_by_id(eligible)))
	var top6: Array = []
	var used_ids: Dictionary = {}
	var eligible_by_id: Dictionary = _records_by_id(eligible)
	for id_value in relief_role_order_ids(saved):
		if top6.size() >= RELIEF_ROLE_SIZE_MAX:
			break
		var pid: int = int(id_value)
		if pid <= 0 or used_ids.has(pid) or not eligible_by_id.has(pid):
			continue
		top6.append(eligible_by_id[pid])
		used_ids[pid] = true
	for pitcher_value in eligible:
		if top6.size() >= RELIEF_ROLE_SIZE_MAX:
			break
		var pitcher: PSPlayerSeasonRecord = pitcher_value as PSPlayerSeasonRecord
		if used_ids.has(pitcher.player_id):
			continue
		top6.append(pitcher)
		used_ids[pitcher.player_id] = true
	if top6.size() < RELIEF_ROLE_SIZE_MAX:
		used_ids[exclude_pitcher_id] = true
		var fallback: Array = []
		for p in starter_pool_fallback:
			var pitcher: PSPlayerSeasonRecord = p as PSPlayerSeasonRecord
			if used_ids.has(pitcher.player_id) or pitcher.injury_days > 0:
				continue
			fallback.append(pitcher)
		fallback.sort_custom(_by_pitching_score(_pitching_scores_by_id(fallback)))
		for p in fallback:
			if top6.size() >= RELIEF_ROLE_SIZE_MAX:
				break
			top6.append(p)
			used_ids[(p as PSPlayerSeasonRecord).player_id] = true
	# top6 は overall 降順 [最強, 2番手, 3番手, 4番手, 5番手, 6番手]。
	# 出力順: [7回, 8回, 9回, 10回, 11回, 12回] = [3番手, 2番手, 最強, 4番手, 5番手, 6番手]
	if not relief_role_order_ids(saved).is_empty():
		return top6
	var ordered: Array = []
	var top3: Array = top6.slice(0, int(min(3, top6.size())))
	top3.reverse()
	ordered.append_array(top3)
	if top6.size() > 3:
		ordered.append_array(top6.slice(3))
	return ordered


static func relief_role_by_pitcher(saved: Dictionary, available_relievers: Array = []) -> Dictionary:
	var allowed: Dictionary = _records_by_id(available_relievers)
	var restrict: bool = not allowed.is_empty()
	var roles: Dictionary = {}
	var relief_roles: Dictionary = saved.get("relief_roles", {}) as Dictionary
	if relief_roles.is_empty():
		return default_relief_role_by_pitcher(available_relievers)
	# long は複数可 (long_ids 配列)。
	for id_value in relief_roles.get("long_ids", []) as Array:
		_add_role_id(roles, int(id_value), RELIEF_ROLE_LONG, allowed, restrict)
	for id_value in relief_roles.get("middle_ids", []) as Array:
		_add_role_id(roles, int(id_value), RELIEF_ROLE_MIDDLE, allowed, restrict)
	for id_value in relief_roles.get("setup_ids", []) as Array:
		_add_role_id(roles, int(id_value), RELIEF_ROLE_SETUP, allowed, restrict)
	_add_role_id(roles, int(relief_roles.get("closer_id", 0)), RELIEF_ROLE_CLOSER, allowed, restrict)
	return roles


static func default_relief_role_by_pitcher(available_relievers: Array) -> Dictionary:
	var roles: Dictionary = {}
	for i in range(available_relievers.size()):
		var record: PSPlayerSeasonRecord = available_relievers[i] as PSPlayerSeasonRecord
		if record == null:
			continue
		if i == 2:
			roles[record.player_id] = RELIEF_ROLE_CLOSER
		elif i <= 1:
			roles[record.player_id] = RELIEF_ROLE_SETUP
		elif i == 3:
			roles[record.player_id] = RELIEF_ROLE_MIDDLE
		else:
			roles[record.player_id] = RELIEF_ROLE_LONG
	return roles


static func relief_role_order_ids(saved: Dictionary) -> Array:
	var relief_roles: Dictionary = saved.get("relief_roles", {}) as Dictionary
	if relief_roles.is_empty():
		return []
	var ids: Array = []
	_append_unique_id(ids, int(relief_roles.get("closer_id", 0)))
	for id_value in relief_roles.get("setup_ids", []) as Array:
		_append_unique_id(ids, int(id_value))
	for id_value in relief_roles.get("middle_ids", []) as Array:
		_append_unique_id(ids, int(id_value))
	for id_value in relief_roles.get("long_ids", []) as Array:
		_append_unique_id(ids, int(id_value))
	return ids


static func _records_by_id(records: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null:
			by_id[record.player_id] = record
	return by_id


# 疲労抜きの投手評価を player_id → score で先に引いておく。comparator の中で計算すると
# 1 回の sort で O(n log n) 回走るため (評価は球速・変化球・能力カーブを含む)。
# 比較結果は同じなので並び順は変わらない。
static func _pitching_scores_by_id(records: Array) -> Dictionary:
	var scores: Dictionary = {}
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null and not scores.has(record.player_id):
			scores[record.player_id] = PlayerValueEvaluator.pitching_score_without_fatigue(record)
	return scores


# _pitching_scores_by_id の結果で降順に並べる comparator。
static func _by_pitching_score(scores: Dictionary) -> Callable:
	return func(a, b) -> bool:
		return _cached_pitching_score(a, scores) > _cached_pitching_score(b, scores)


# null は元の comparator と同じ 0 として扱う (reliever_pool_candidates は null を落とさないため
# プールに混じり得る)。非 null は必ず scores に入っているので既定値は null 用。
static func _cached_pitching_score(row: Variant, scores: Dictionary) -> int:
	var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
	if record == null:
		return 0
	return int(scores.get(record.player_id, 0))


static func _add_role_id(roles: Dictionary, player_id: int, role: String, allowed: Dictionary, restrict: bool) -> void:
	if player_id <= 0 or roles.has(player_id):
		return
	if restrict and not allowed.has(player_id):
		return
	roles[player_id] = role


static func _append_unique_id(ids: Array, player_id: int) -> void:
	if player_id <= 0 or ids.has(player_id):
		return
	ids.append(player_id)
