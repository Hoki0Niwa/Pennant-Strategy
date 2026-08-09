extends RefCounted
class_name TeamAutoAI

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")

# 一二軍入替の自動判定 + 戦力外候補スコアリング。

const SWAP_INTERVAL_DAYS: int = 7
const DEMOTION_COOLDOWN_DAYS: int = 10
const INJURY_SHORT_ABSENCE_STASH_DAYS: int = 3
const INJURY_MAINSTAY_STASH_MAX_DAYS: int = 5
# 怪我人を1軍に留め置く日数の判定ライン。**母集団相対** (perf_score は overall スケールなので、
# その年の支配下選手の overall 分布から mean + sigma*spread を引く)。絶対値で置くと
# リーグ全体の水準が動いただけで「主力」の範囲が一斉にズレる。
# 実測 (1シーズン): 野手 mean 68.96/spread 9.91、投手 mean 68.92/spread 7.70。
# MAINSTAY=+0.12σ は旧・絶対値 70.0 とほぼ一致。CORE=+1.4σ は旧 82.0 が野手 +1.32σ /
# 投手 +1.70σ と**side で厳しさがズレていた**のを、どちらも上位 8% 相当へ揃えた値。
const INJURY_MAINSTAY_STASH_SIGMA: float = 0.12
const INJURY_CORE_STASH_SIGMA: float = 1.4
# 母集団が取れないとき (合成データのテスト等) のフォールバック。
const INJURY_MAINSTAY_STASH_SCORE_MIN: float = 70.0
const INJURY_CORE_STASH_SCORE_MIN: float = 82.0
const MAX_SWAPS_PER_RUN: int = 4
# 降格判定 (B): 1軍の同バケット平均から何点下回ったら「働けていない」とみなすか。
# perf_score は overall (rating) スケール = 任意のゼロ点を持つので、**比率ではなく絶対差**で見る
# (比率にすると平均 ~70・幅 ~10 のスケールでは閾値が分布の外へ出て発火しなくなる)。
# 実測 (1シーズン): 1軍相当の分布は 野手 mean 78 / p10 72、先発 mean 70 / p10 59、
# 救援 mean 69 / p10 58。下位 1 割前後を拾う幅に設定してある。下げるほど降格が増える。
# 出場「量」の判定は (A) の MIN_APPEARANCE_RATIO_* が別に担当する。
const UNDERPERFORM_GAP: float = 10.0
const UNDERPERFORM_GAP_BATTER: float = 8.0
const UNDERPERFORM_GAP_STARTER: float = 14.0    # 先発は登板間隔が長いので閾値を緩める
const MIN_APPEARANCE_RATIO_BATTER: float = 0.3
const MIN_APPEARANCE_RATIO_PITCHER: float = 0.9
const MIN_APPEARANCE_RATIO_STARTER: float = 0.5  # 先発は中6日登板なので出場率は低くて当然
const DEMOTION_FATIGUE_PROTECT_THRESHOLD: int = 80

# スタメン/一二軍入替時の WAR ボーナス係数。perf_score へ war_value × この係数 × 信頼度 を加える。
# perf_score は overall (rating) スケールなので、WAR +2 で +6 点前後 = 主力とフリンジの差に相当する。
# **重要: cut_score (戦力外) では war_value=0.0 のまま呼ぶことで、WAR が低い
# レギュラー (試合に出続けた証拠でもある) を誤って切る挙動を防ぐ。**
const WAR_PERF_WEIGHT: float = 6.0

const TARGET_TOTAL: int = 31
const TARGET_STARTERS: int = 6
const TARGET_PITCHERS: int = 15
const MIN_ACTIVE_CATCHERS: int = 2
const PITCHER_ROLE_STARTER: String = "starter"
const PITCHER_ROLE_RELIEVER: String = "reliever"

# 守備位置 (捕→遊→中→二→三→一→左→右)。希少順。
const DEFENSIVE_POSITIONS: Array[int] = [2, 6, 8, 4, 5, 3, 7, 9]


# ---- 評価関数 ---------------------------------------------------------------

# 成績と能力値を総合した perf score。**overall_prior と同じ rating スケール**で返す。
#   perf = 能力 (overall_prior) + 成績の上振れ/下振れ (PSBatterForm / PSPitcherForm) + WAR 項
# monthly_batter / monthly_pitcher が渡されるとその月別 stats で今季ぶんを評価し、
# 渡されなければシーズン累積で評価する (オフシーズン release 等で使用)。
#
# 成績パートは率成績のみをリーグ実測分布で σ 化し、能力スケールへ揃えてから加算する
# (PSPerformanceReference の alignment)。出場「量」は成績側に持たせない — 出場量の判定は
# _is_underperforming の出場率ゲート (MIN_APPEARANCE_RATIO_*) が担当する。
#
# war_value: シーズン累積 WAR。守備・走塁を含む総合貢献なので率成績と別に加える。
#   打席/対戦打者数に応じた信頼度を掛けるので、出場が少ないうちは効かない。
#   cut_score (戦力外) は war_value=0.0 のまま呼び、低 WAR レギュラーの誤切断を防ぐ。
#   _swap_one_team (スタメン/一二軍入替) のみ実際の WAR を渡す。
static func perf_score(
	record: PSPlayerSeasonRecord,
	monthly_batter: PSBatterStats = null,
	monthly_pitcher: PSPitcherStats = null,
	war_value: float = 0.0
) -> float:
	if record == null:
		return 0.0
	var prior: float = overall_prior(record)
	if record.is_pitcher():
		var stats: PSPitcherStats = monthly_pitcher if monthly_pitcher != null else record.pitcher_stats
		var form: float = PSPitcherForm.rating_delta(record, monthly_pitcher)
		return prior + form + war_value * WAR_PERF_WEIGHT * _pitcher_reliability(stats)
	var stats_b: PSBatterStats = monthly_batter if monthly_batter != null else record.batter_stats
	var form_b: float = PSBatterForm.rating_delta(record, monthly_batter)
	return prior + form_b + war_value * WAR_PERF_WEIGHT * _batter_reliability(stats_b)


# WAR 項に掛ける信頼度 (0..1)。form 側と同じ縮約を使い、少ない出場で WAR が暴れるのを抑える。
static func _batter_reliability(stats: PSBatterStats) -> float:
	if stats == null or stats.plate_appearances <= 0:
		return 0.0
	var plate_appearances: float = float(stats.plate_appearances)
	return plate_appearances / (plate_appearances + PSBatterForm.PA_RELIABILITY_ANCHOR)


static func _pitcher_reliability(stats: PSPitcherStats) -> float:
	if stats == null or stats.batters_faced <= 0:
		return 0.0
	var batters_faced: float = float(stats.batters_faced)
	return batters_faced / (batters_faced + PSPitcherForm.BATTERS_FACED_RELIABILITY_ANCHOR)


# 一二軍入替の方針として疲労ペナルティは査定に含めない (apply_fatigue_penalty=false を明示)。
static func overall_prior(record: PSPlayerSeasonRecord) -> float:
	return float(PlayerValueEvaluator.overall_score(record))


static func _is_starting_pitcher(record: PSPlayerSeasonRecord) -> bool:
	return record != null and record.is_starter_pitcher()


# 戦力外用: 能力(総合評価) + 出場数 - 年齢ペナルティ。低いほど切られやすい。
# **成績(ERA/勝敗等の実績)は使わない**。能力が高く出場機会を得たが成績不振だった選手を、
# 出場ゼロの格下選手より先に切ってしまう問題があったため、能力ベースに統一する。
# 出場数(登板数/試合数)は「起用されている=編成上の価値がある」として加点する
# (出場数であって成績ではない点に注意)。旧実装は投手だけ加点があり、中間層の野手が
# 構造的に先へ切られて戦力外の投手:野手が約1:2に偏っていたため、野手にも同スケール
# (最大24点前後) の加点を追加した (2026-07-03)。
# (一二軍入替の _swap_one_team は引き続き perf_score=成績ベースで判断する)
const PITCHER_USAGE_STARTER_WEIGHT: float = 3.0
const PITCHER_USAGE_RELIEVER_WEIGHT: float = 1.5
const PITCHER_USAGE_STARTER_CAP: int = 8
const PITCHER_USAGE_RELIEVER_CAP: int = 15
const FIELDER_USAGE_WEIGHT: float = 0.4
const FIELDER_USAGE_CAP: int = 60

static func cut_score(player: PSPlayer, record: PSPlayerSeasonRecord) -> float:
	var base: float = 0.0
	if record != null:
		# 疲労ペナルティ抜きの能力スナップショット (overall_prior と同じ)。
		base = overall_prior(record)
		if record.is_pitcher():
			base += _pitcher_usage_bonus(record)
		else:
			base += float(mini(record.batter_stats.games, FIELDER_USAGE_CAP)) * FIELDER_USAGE_WEIGHT
	else:
		base = float(PlayerValueEvaluator.overall_score(PSPlayerSeasonRecord.from_player(player, 0, 0)))
	var age_pen: float = max(0.0, float(player.age) - 30.0) * 8.0
	return base - age_pen


# 投手の出場数(登板数)ボーナス。先発登板/救援登板のうち貢献の大きい方を採用し、
# cap で頭打ちにする。登板が多い投手ほど cut_score が上がり切られにくい。
static func _pitcher_usage_bonus(record: PSPlayerSeasonRecord) -> float:
	var starter_bonus: float = float(min(record.pitcher_stats.starts, PITCHER_USAGE_STARTER_CAP)) * PITCHER_USAGE_STARTER_WEIGHT
	var reliever_bonus: float = float(min(record.pitcher_stats.relief_appearances, PITCHER_USAGE_RELIEVER_CAP)) * PITCHER_USAGE_RELIEVER_WEIGHT
	return max(starter_bonus, reliever_bonus)


# ---- 成績ベース1軍編成プレビュー -------------------------------------------

static func preview_perf_based_active_roster(season: PSSeason, team_id: int) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	if all_records.is_empty():
		return {"ok": false, "message": "選手データがありません"}

	var starters: Array = []
	var relievers: Array = []
	var fielders: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		# roadmap #3: 育成選手は一軍登録不可 (試合に出場できない)。
		if record.development_player:
			continue
		if record.is_pitcher():
			if _is_starting_pitcher(record):
				starters.append(record)
			else:
				relievers.append(record)
		else:
			fielders.append(record)

	var by_perf: Callable = func(a, b) -> bool:
		return _active_roster_selection_score(a as PSPlayerSeasonRecord) > _active_roster_selection_score(b as PSPlayerSeasonRecord)
	starters.sort_custom(by_perf)
	relievers.sort_custom(by_perf)
	fielders.sort_custom(by_perf)

	var selected: Array = []
	var foreign_counts: Dictionary = ForeignActiveRosterRules.empty_counts()
	var add_player: Callable = func(record: PSPlayerSeasonRecord) -> bool:
		if record == null or record.injury_days > 0:
			return false
		if selected.size() >= TARGET_TOTAL:
			return false
		for selected_row in selected:
			if (selected_row as PSPlayerSeasonRecord).player_id == record.player_id:
				return false
		if not ForeignActiveRosterRules.can_add_record(foreign_counts, record):
			return false
		selected.append(record)
		ForeignActiveRosterRules.add_record(foreign_counts, record)
		return true

	for record_row in starters:
		if selected.size() >= TARGET_STARTERS:
			break
		add_player.call(record_row as PSPlayerSeasonRecord)

	var pitcher_count: int = selected.size()
	for record_row in relievers:
		if pitcher_count >= TARGET_PITCHERS:
			break
		if add_player.call(record_row as PSPlayerSeasonRecord):
			pitcher_count += 1

	_ensure_minimum_catchers(selected, fielders, add_player, MIN_ACTIVE_CATCHERS)
	_ensure_defensive_position_coverage(selected, fielders, add_player)

	for record_row in fielders:
		if selected.size() >= TARGET_TOTAL:
			break
		add_player.call(record_row as PSPlayerSeasonRecord)

	# 余り枠を残り投手から
	if selected.size() < TARGET_TOTAL:
		var remaining_pool: Array = []
		var selected_ids: Dictionary = {}
		for record_row in selected:
			selected_ids[(record_row as PSPlayerSeasonRecord).player_id] = true
		for record_row in relievers:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not selected_ids.has(record.player_id):
				remaining_pool.append(record)
		for record_row in starters:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if not selected_ids.has(record.player_id):
				remaining_pool.append(record)
		remaining_pool.sort_custom(by_perf)
		for record_row in remaining_pool:
			if selected.size() >= TARGET_TOTAL:
				break
			add_player.call(record_row as PSPlayerSeasonRecord)

	var player_ids: Array = []
	for record_row in selected:
		player_ids.append((record_row as PSPlayerSeasonRecord).player_id)

	return {
		"ok": true,
		"player_ids": player_ids,
	}


# ---- 故障者の即時一軍枠修復 -------------------------------------------------

# 試合中に発生した故障者が一軍31枠を長期占有し続けないよう、離脱見込みが長い故障者を
# 当日降格扱いで外し、健康な支配下候補を補充する。3日程度の離脱は出場不可のまま一軍に置き、
# 主力級ほど最大5日まで保持する。成績不振による週次入替とは別物なので、成績比較や最大4人制限は使わない。
static func repair_active_roster_injuries(season: PSSeason, team_id: int, current_day: int = -1) -> Dictionary:
	if season == null:
		return {"ok": false, "message": "season is null", "changed": false}

	var roster: Dictionary = season.get_active_roster(team_id)
	var active_id_list: Array = (roster.get("player_ids", []) as Array).duplicate()
	var all_records: Array = []
	if active_id_list.is_empty():
		all_records = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
		if all_records.is_empty():
			return {"ok": false, "message": "選手データがありません", "changed": false}
		var preview: Dictionary = preview_perf_based_active_roster(season, team_id)
		if not bool(preview.get("ok", false)):
			return {"ok": false, "message": str(preview.get("message", "一軍ロスターを作成できません")), "changed": false}
		active_id_list = (preview.get("player_ids", []) as Array).duplicate()
		season.set_active_roster(team_id, {"player_ids": active_id_list.duplicate()})
		roster = season.get_active_roster(team_id)

	var record_by_id: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record

	var active_set: Dictionary = {}
	var injured_demotions: Array = []
	var short_injury_stashes: Array = []
	var removed_role_counts: Dictionary = {
		"starter": 0,
		"reliever": 0,
		"fielder": 0,
	}
	for id_value in active_id_list:
		var player_id: int = int(id_value)
		if active_set.has(player_id):
			continue
		var active_record: PSPlayerSeasonRecord = record_by_id.get(player_id, null) as PSPlayerSeasonRecord
		if active_record == null:
			active_record = RecordStore.get_player_record(player_id, season.year, season.season_number)
			if active_record != null:
				record_by_id[player_id] = active_record
		if active_record != null and active_record.injury_days > 0:
			if not _should_demote_active_injury(active_record):
				short_injury_stashes.append(player_id)
				active_set[player_id] = true
				continue
			injured_demotions.append(player_id)
			var role_key: String = _active_roster_role_key(active_record)
			removed_role_counts[role_key] = int(removed_role_counts.get(role_key, 0)) + 1
			continue
		active_set[player_id] = true

	if injured_demotions.is_empty():
		return {
			"ok": true,
			"team_id": team_id,
			"changed": false,
			"injured_demotions": [],
			"short_injury_stashes": short_injury_stashes,
			"promotions": [],
		}

	if all_records.is_empty():
		all_records = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
		if all_records.is_empty():
			return {"ok": false, "message": "選手データがありません", "changed": false}
		for record_row in all_records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null:
				record_by_id[record.player_id] = record

	var healthy_roster_records: Array = []
	var promote_pool: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not _is_healthy_active_roster_candidate(record):
			continue
		healthy_roster_records.append(record)
		if not active_set.has(record.player_id):
			promote_pool.append(record)
	promote_pool.sort_custom(func(a, b) -> bool:
		return _active_roster_selection_score(a as PSPlayerSeasonRecord) > _active_roster_selection_score(b as PSPlayerSeasonRecord)
	)

	var target_size: int = mini(TARGET_TOTAL, healthy_roster_records.size())
	var required_catchers: int = mini(MIN_ACTIVE_CATCHERS, _catcher_count_in_records(healthy_roster_records))
	var promotions: Array = []

	_repair_fill_required_catchers(promote_pool, active_set, record_by_id, promotions, target_size, required_catchers)
	_repair_fill_position_coverage(promote_pool, active_set, record_by_id, promotions, target_size, required_catchers, healthy_roster_records)
	for role_key in ["starter", "reliever", "fielder"]:
		_repair_fill_role(promote_pool, active_set, record_by_id, promotions, target_size, required_catchers, role_key, int(removed_role_counts.get(role_key, 0)))
	_repair_fill_best(promote_pool, active_set, record_by_id, promotions, target_size, required_catchers)

	var new_roster: Dictionary = roster.duplicate(true)
	new_roster["player_ids"] = _ordered_active_ids_after_repair(active_id_list, active_set, promotions)
	season.set_active_roster(team_id, new_roster)
	var day: int = season.current_day if current_day < 0 else current_day
	season.record_demotions(team_id, injured_demotions, day)

	return {
		"ok": true,
		"team_id": team_id,
		"changed": true,
		"injured_demotions": injured_demotions,
		"short_injury_stashes": short_injury_stashes,
		"promotions": promotions,
		"active_count": (new_roster["player_ids"] as Array).size(),
	}


static func _should_demote_active_injury(record: PSPlayerSeasonRecord) -> bool:
	return record != null and record.injury_days > _active_injury_stash_limit(record)


static func _active_injury_stash_limit(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	var mainstay_score: float = perf_score(record)
	if mainstay_score >= _stash_line(record, INJURY_CORE_STASH_SIGMA, INJURY_CORE_STASH_SCORE_MIN):
		return INJURY_MAINSTAY_STASH_MAX_DAYS
	if mainstay_score >= _stash_line(record, INJURY_MAINSTAY_STASH_SIGMA, INJURY_MAINSTAY_STASH_SCORE_MIN):
		return INJURY_SHORT_ABSENCE_STASH_DAYS + 1
	return INJURY_SHORT_ABSENCE_STASH_DAYS


# その選手のシーズン・side の overall 分布から判定ラインを引く。
# 母集団が無い (year 未設定の合成レコード等) 場合は fallback の絶対値へ落ちる。
static func _stash_line(record: PSPlayerSeasonRecord, sigma: float, fallback: float) -> float:
	if record.year <= 0:
		return fallback
	var key: String = "overall_pitcher" if record.is_pitcher() else "overall_batter"
	return PSPerformanceReference.score_threshold(record.year, record.season_number, key, sigma)


static func _is_healthy_active_roster_candidate(record: PSPlayerSeasonRecord) -> bool:
	return record != null and record.player_id > 0 and record.injury_days <= 0 and not record.development_player


static func _active_roster_role_key(record: PSPlayerSeasonRecord) -> String:
	if record == null or not record.is_pitcher():
		return "fielder"
	return "starter" if _is_starting_pitcher(record) else "reliever"


static func _repair_fill_required_catchers(
	promote_pool: Array,
	active_set: Dictionary,
	record_by_id: Dictionary,
	promotions: Array,
	target_size: int,
	required_catchers: int
) -> void:
	while _active_catcher_count(active_set, record_by_id) < required_catchers and active_set.size() < target_size:
		var added: bool = false
		for record_row in promote_pool:
			var candidate: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if candidate == null or not _is_catcher(candidate):
				continue
			if _repair_try_promote(candidate, active_set, record_by_id, promotions, target_size, required_catchers, false):
				added = true
				break
		if not added:
			break


static func _repair_fill_position_coverage(
	promote_pool: Array,
	active_set: Dictionary,
	record_by_id: Dictionary,
	promotions: Array,
	target_size: int,
	required_catchers: int,
	healthy_roster_records: Array
) -> void:
	for position in DEFENSIVE_POSITIONS:
		if active_set.size() >= target_size:
			return
		var required_holders: int = mini(2, _records_cover_position_count(healthy_roster_records, int(position)))
		while _active_position_count(active_set, record_by_id, int(position)) < required_holders and active_set.size() < target_size:
			var added: bool = false
			for record_row in promote_pool:
				var candidate: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
				if candidate == null or _position_aptitude(candidate, int(position)) <= 0:
					continue
				if _repair_try_promote(candidate, active_set, record_by_id, promotions, target_size, required_catchers):
					added = true
					break
			if not added:
				break


static func _repair_fill_role(
	promote_pool: Array,
	active_set: Dictionary,
	record_by_id: Dictionary,
	promotions: Array,
	target_size: int,
	required_catchers: int,
	role_key: String,
	needed: int
) -> void:
	if needed <= 0:
		return
	var added_count: int = 0
	for record_row in promote_pool:
		if added_count >= needed or active_set.size() >= target_size:
			break
		var candidate: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if _active_roster_role_key(candidate) != role_key:
			continue
		if _repair_try_promote(candidate, active_set, record_by_id, promotions, target_size, required_catchers):
			added_count += 1


static func _repair_fill_best(
	promote_pool: Array,
	active_set: Dictionary,
	record_by_id: Dictionary,
	promotions: Array,
	target_size: int,
	required_catchers: int
) -> void:
	for record_row in promote_pool:
		if active_set.size() >= target_size:
			break
		_repair_try_promote(record_row as PSPlayerSeasonRecord, active_set, record_by_id, promotions, target_size, required_catchers)


static func _repair_try_promote(
	candidate: PSPlayerSeasonRecord,
	active_set: Dictionary,
	record_by_id: Dictionary,
	promotions: Array,
	target_size: int,
	required_catchers: int,
	enforce_catcher_min: bool = true
) -> bool:
	if not _is_healthy_active_roster_candidate(candidate):
		return false
	if active_set.size() >= target_size or active_set.has(candidate.player_id):
		return false
	var candidate_set: Dictionary = active_set.duplicate()
	candidate_set[candidate.player_id] = true
	if not ForeignActiveRosterRules.is_within_limits(
		ForeignActiveRosterRules.counts_from_active_set(candidate_set, record_by_id)
	):
		return false
	if enforce_catcher_min and _active_catcher_count(candidate_set, record_by_id) < required_catchers:
		return false
	active_set[candidate.player_id] = true
	promotions.append(candidate.player_id)
	return true


static func _active_catcher_count(active_set: Dictionary, record_by_id: Dictionary) -> int:
	var count: int = 0
	for pid_value in active_set.keys():
		var record: PSPlayerSeasonRecord = record_by_id.get(int(pid_value), null) as PSPlayerSeasonRecord
		if _is_catcher(record):
			count += 1
	return count


static func _active_position_count(active_set: Dictionary, record_by_id: Dictionary, position: int) -> int:
	var count: int = 0
	for pid_value in active_set.keys():
		var record: PSPlayerSeasonRecord = record_by_id.get(int(pid_value), null) as PSPlayerSeasonRecord
		if _position_aptitude(record, position) > 0:
			count += 1
	return count


static func _ordered_active_ids_after_repair(previous_ids: Array, active_set: Dictionary, promotions: Array) -> Array:
	var out: Array = []
	var written: Dictionary = {}
	for id_value in previous_ids:
		var player_id: int = int(id_value)
		if written.has(player_id) or not active_set.has(player_id):
			continue
		out.append(player_id)
		written[player_id] = true
	for id_value in promotions:
		var player_id: int = int(id_value)
		if written.has(player_id) or not active_set.has(player_id):
			continue
		out.append(player_id)
		written[player_id] = true
	return out


static func _ensure_minimum_catchers(selected: Array, fielders: Array, add_player: Callable, minimum: int) -> void:
	var catcher_count: int = _catcher_count_in_records(selected)
	if catcher_count >= minimum:
		return
	for record_row in fielders:
		if catcher_count >= minimum:
			break
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or _record_array_has_player(selected, record.player_id):
			continue
		if not _is_catcher(record):
			continue
		if bool(add_player.call(record)):
			catcher_count += 1


static func _ensure_defensive_position_coverage(selected: Array, fielders: Array, add_player: Callable) -> void:
	for position in [2, 6, 8, 4, 5, 3, 7, 9]:
		var cover_count: int = _records_cover_position_count(selected, int(position))
		for record_row in fielders:
			if cover_count >= 2:
				break
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record == null or _record_array_has_player(selected, record.player_id):
				continue
			if _position_aptitude(record, int(position)) <= 0:
				continue
			if bool(add_player.call(record)):
				cover_count += 1


# 守備位置別の適性保持者ルックアップ {position(2-9): {player_id: true}} を構築 (投手除く)。
static func _build_position_holder_lookup(records: Array) -> Dictionary:
	var lookup: Dictionary = {}
	for position in DEFENSIVE_POSITIONS:
		lookup[position] = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or record.is_pitcher():
			continue
		for position in DEFENSIVE_POSITIONS:
			if _position_aptitude(record, position) > 0:
				(lookup[position] as Dictionary)[record.player_id] = true
	return lookup


# active_set (player_id->true) のうち holders に含まれる人数。
static func _count_active_holders(active_set: Dictionary, holders: Dictionary) -> int:
	var count: int = 0
	for pid_v in active_set.keys():
		if holders.has(int(pid_v)):
			count += 1
	return count


# 候補 1軍集合 active が、各守備位置で floor 人以上の適性保持者を満たすか。
static func _position_coverage_ok(active: Dictionary, holder_lookup: Dictionary, floor_by_position: Dictionary) -> bool:
	for position in DEFENSIVE_POSITIONS:
		var floor_n: int = int(floor_by_position.get(position, 0))
		if floor_n <= 0:
			continue
		var holders: Dictionary = holder_lookup.get(position, {}) as Dictionary
		if _count_active_holders(active, holders) < floor_n:
			return false
	return true


static func _records_cover_position_count(records: Array, position: int) -> int:
	var count: int = 0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and _position_aptitude(record, position) > 0:
			count += 1
	return count


static func _catcher_count_in_records(records: Array) -> int:
	var count: int = 0
	for record_row in records:
		if _is_catcher(record_row as PSPlayerSeasonRecord):
			count += 1
	return count


static func _record_array_has_player(records: Array, player_id: int) -> bool:
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null and record.player_id == player_id:
			return true
	return false


static func _active_roster_selection_score(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return -999999.0
	var score: float = perf_score(record)
	if record.injury_days > 0:
		score -= 100000.0
	return score


static func _is_catcher(record: PSPlayerSeasonRecord) -> bool:
	return _position_aptitude(record, 2) > 0


static func _position_aptitude(record: PSPlayerSeasonRecord, position: int) -> int:
	if record == null or record.is_pitcher():
		return 0
	var key_by_position: Dictionary = {
		2: "catcher",
		3: "first",
		4: "second",
		5: "third",
		6: "shortstop",
		7: "left",
		8: "center",
		9: "right",
	}
	var key: String = str(key_by_position.get(position, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == position else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


# ---- 週次入替のメインエントリ ------------------------------------------------

# 各CPU球団 + (include_user_team_id > 0 ならその自軍) に対し、
# 最終入替から SWAP_INTERVAL_DAYS 以上経過していれば入替判定を実行。
static func run_periodic_roster_swaps(season: PSSeason, teams: Array, current_day: int, user_team_id: int, include_user_team: bool) -> Dictionary:
	# 全チームに共通の WAR league context を 1 度だけ構築して使い回す
	# (12 チーム × 全選手の集計は重いので 1 ループ分の使い回しが必須)。
	var war_ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	var executed: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var is_user: bool = (team.id == user_team_id)
		var last_day: int = season.get_last_auto_swap_day(team.id)
		# 初回(last_day == 0)も実行する。前回から SWAP_INTERVAL_DAYS 以上経過していれば実行。
		if last_day > 0 and current_day - last_day < SWAP_INTERVAL_DAYS:
			continue
		# 自軍の自動入替が無効でも、ロスター画面の「直近2週間」表示用にスナップショットだけは残す
		# (入替判定はしない)。CPU 球団・自動入替ONの自軍は従来通り _swap_one_team で入替+記録。
		if is_user and not include_user_team:
			_append_snapshots(season, RecordStore.get_team_player_records(team.id, season.year, season.season_number), current_day)
			season.set_last_auto_swap_day(team.id, current_day)
			continue
		var summary: Dictionary = _swap_one_team(season, team.id, current_day, war_ctx)
		season.set_last_auto_swap_day(team.id, current_day)
		season.clear_stale_demotions(team.id, current_day)
		if not (summary.get("swapped_pairs", []) as Array).is_empty():
			summary["team_id"] = team.id
			executed.append(summary)
	return {
		"ok": true,
		"executed": executed,
	}


# 1球団分の入替処理。
# 1. 月別 stats を事前計算して score_by_id を構築
# 2. 1軍取得(無ければ初期化) → 平均perf_scoreを算出
# 3. 降格候補プール(出場率不足 OR 1軍同バケット平均から UNDERPERFORM_GAP_* 以上下)
# 4. 昇格候補プール(クールダウン明け、2軍内のperf_score上位)
# 5. ペアリング(先発↔先発、リリーフ↔リリーフ、野手↔野手)で最大MAX_SWAPS_PER_RUN
# 6. demotion_dayに記録、active_rosterを書き換え
# 7. 全選手 (1軍/2軍問わず) の current_day snapshot を保存 (次回月別 stats 算出用)
static func _swap_one_team(season: PSSeason, team_id: int, current_day: int, war_ctx: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = {"swapped_pairs": []}
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	if all_records.is_empty():
		return summary

	# 単体呼び出しの後方互換: war_ctx 未指定なら ここで一度だけ作る。
	var ctx: Dictionary = war_ctx if not war_ctx.is_empty() else WarCalculator.build_league_context(season.year, season.season_number)

	# (1) 月別 stats 取得 + score 事前計算 (score_by_id にキャッシュ)
	# WAR は当該シーズン累積を使う (月別 advanced_stats の差分は持っていない)。
	var score_by_id: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var monthly: Dictionary = season.get_monthly_stats(record.player_id, record.batter_stats, record.pitcher_stats)
		var monthly_batter: PSBatterStats = monthly.get("batter") as PSBatterStats
		var monthly_pitcher: PSPitcherStats = monthly.get("pitcher") as PSPitcherStats
		var war_row: Dictionary = WarCalculator.season_war(record, ctx)
		var war_value: float = float(war_row.get("war", 0.0))
		score_by_id[record.player_id] = perf_score(record, monthly_batter, monthly_pitcher, war_value)

	# 1軍ID集合を取得 (無ければ成績ベースで初期生成)
	var roster: Dictionary = season.get_active_roster(team_id)
	var active_id_list: Array = roster.get("player_ids", []) as Array
	if active_id_list.is_empty():
		var preview: Dictionary = preview_perf_based_active_roster(season, team_id)
		if not bool(preview.get("ok", false)):
			_append_snapshots(season, all_records, current_day)
			return summary
		active_id_list = preview.get("player_ids", []) as Array
		season.set_active_roster(team_id, {"player_ids": active_id_list.duplicate()})
		roster = season.get_active_roster(team_id)

	var active_set: Dictionary = {}
	for id_value in active_id_list:
		active_set[int(id_value)] = true

	var active_records: Array = []
	var inactive_records: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_set.has(record.player_id):
			active_records.append(record)
		else:
			inactive_records.append(record)

	if active_records.is_empty():
		_append_snapshots(season, all_records, current_day)
		return summary

	# (2) 1軍平均 perf を計算 (先発/リリーフ/野手 別、事前計算スコア使用)
	var starter_active: Array = []
	var reliever_active: Array = []
	var batter_active: Array = []
	for record_row in active_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			if _is_starting_pitcher(record):
				starter_active.append(record)
			else:
				reliever_active.append(record)
		else:
			batter_active.append(record)
	var starter_mean: float = _records_mean_perf_with_scores(starter_active, score_by_id)
	var reliever_mean: float = _records_mean_perf_with_scores(reliever_active, score_by_id)
	var batter_mean: float = _records_mean_perf_with_scores(batter_active, score_by_id)

	# (3) 降格候補プール
	var demote_candidates: Array = []
	for record_row in active_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var perf: float = float(score_by_id.get(record.player_id, 0.0))
		if _is_demotion_candidate(record, perf, current_day, starter_mean, reliever_mean, batter_mean):
			demote_candidates.append(record)
	if demote_candidates.is_empty():
		_append_snapshots(season, all_records, current_day)
		return summary

	# (4) 昇格候補プール: クールダウン明け、現1軍外
	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var promote_pool: Array = []
	for record_row in inactive_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.injury_days > 0:
			continue
		# roadmap #3: 育成選手は一軍へ昇格できない (支配下登録が必要)。
		if record.development_player:
			continue
		var pid_key: String = str(record.player_id)
		var last_demote: int = int(demotion_days.get(pid_key, 0))
		if last_demote > 0 and current_day - last_demote < DEMOTION_COOLDOWN_DAYS:
			continue
		promote_pool.append(record)
	if promote_pool.is_empty():
		_append_snapshots(season, all_records, current_day)
		return summary

	# 降格を低 perf 順、昇格を高 perf 順にソート (事前計算スコア)
	demote_candidates.sort_custom(func(a, b) -> bool:
		return float(score_by_id.get((a as PSPlayerSeasonRecord).player_id, 0.0)) < float(score_by_id.get((b as PSPlayerSeasonRecord).player_id, 0.0))
	)
	promote_pool.sort_custom(func(a, b) -> bool:
		return float(score_by_id.get((a as PSPlayerSeasonRecord).player_id, 0.0)) > float(score_by_id.get((b as PSPlayerSeasonRecord).player_id, 0.0))
	)

	# (5) ペアリング (先発↔先発、リリーフ↔リリーフ、野手↔野手)
	var demote_starters: Array = []
	var demote_relievers: Array = []
	var demote_batters: Array = []
	for record_row in demote_candidates:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			if _is_starting_pitcher(record):
				demote_starters.append(record)
			else:
				demote_relievers.append(record)
		else:
			demote_batters.append(record)
	var promote_starters: Array = []
	var promote_relievers: Array = []
	var promote_batters: Array = []
	for record_row in promote_pool:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			if _is_starting_pitcher(record):
				promote_starters.append(record)
			else:
				promote_relievers.append(record)
		else:
			promote_batters.append(record)

	var pairs: Array = []
	# 投手ペア
	var p_count: int = min(demote_starters.size(), promote_starters.size())
	for pi in range(p_count):
		if pairs.size() >= MAX_SWAPS_PER_RUN:
			break
		var pd_rec: PSPlayerSeasonRecord = demote_starters[pi] as PSPlayerSeasonRecord
		var pu_rec: PSPlayerSeasonRecord = promote_starters[pi] as PSPlayerSeasonRecord
		var pd_score: float = float(score_by_id.get(pd_rec.player_id, 0.0))
		var pu_score: float = float(score_by_id.get(pu_rec.player_id, 0.0))
		# 上がってくる選手のスコアが下がる選手より高くなければスキップ
		if pu_score <= pd_score:
			continue
		pairs.append({"down": pd_rec.player_id, "up": pu_rec.player_id})
	var r_count: int = min(demote_relievers.size(), promote_relievers.size())
	for ri in range(r_count):
		if pairs.size() >= MAX_SWAPS_PER_RUN:
			break
		var rd_rec: PSPlayerSeasonRecord = demote_relievers[ri] as PSPlayerSeasonRecord
		var ru_rec: PSPlayerSeasonRecord = promote_relievers[ri] as PSPlayerSeasonRecord
		var rd_score: float = float(score_by_id.get(rd_rec.player_id, 0.0))
		var ru_score: float = float(score_by_id.get(ru_rec.player_id, 0.0))
		if ru_score <= rd_score:
			continue
		pairs.append({"down": rd_rec.player_id, "up": ru_rec.player_id})
	# 野手ペア
	var b_count: int = min(demote_batters.size(), promote_batters.size())
	for bi in range(b_count):
		if pairs.size() >= MAX_SWAPS_PER_RUN:
			break
		var bd_rec: PSPlayerSeasonRecord = demote_batters[bi] as PSPlayerSeasonRecord
		var bu_rec: PSPlayerSeasonRecord = promote_batters[bi] as PSPlayerSeasonRecord
		var bd_score: float = float(score_by_id.get(bd_rec.player_id, 0.0))
		var bu_score: float = float(score_by_id.get(bu_rec.player_id, 0.0))
		if bu_score <= bd_score:
			continue
		pairs.append({"down": bd_rec.player_id, "up": bu_rec.player_id})

	if pairs.is_empty():
		_append_snapshots(season, all_records, current_day)
		return summary

	# (6) 外国人枠と捕手数のチェック。
	var record_by_id: Dictionary = {}
	var catcher_lookup: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		record_by_id[record.player_id] = record
		catcher_lookup[record.player_id] = _is_catcher(record)

	# 守備位置別の適性保持者ルックアップ (チーム全体) と、1軍で割り込んではいけない
	# 最低保持者数 floor を構築。floor = min(2, 全体保持者数, 現1軍保持者数)。
	# 入替でいずれかの守備位置が floor を下回る場合はそのペアを見送り、
	# 「可能な限り全ポジション 2 人以上の保持者」を維持する (主力欠場時の守備不能を防ぐ)。
	var position_holder_lookup: Dictionary = _build_position_holder_lookup(all_records)
	var position_floor: Dictionary = {}
	for floor_position in DEFENSIVE_POSITIONS:
		var floor_holders: Dictionary = position_holder_lookup[floor_position] as Dictionary
		var current_active_holders: int = _count_active_holders(active_set, floor_holders)
		position_floor[floor_position] = min(min(2, floor_holders.size()), current_active_holders)

	var new_active: Dictionary = active_set.duplicate()
	var applied_pairs: Array = []
	for pair_row in pairs:
		var pair: Dictionary = pair_row as Dictionary
		var down_id: int = int(pair["down"])
		var up_id: int = int(pair["up"])
		var tmp: Dictionary = new_active.duplicate()
		tmp.erase(down_id)
		tmp[up_id] = true
		var catcher_n: int = 0
		for pid_v in tmp.keys():
			var pid: int = int(pid_v)
			if bool(catcher_lookup.get(pid, false)):
				catcher_n += 1
		if not ForeignActiveRosterRules.is_within_limits(
			ForeignActiveRosterRules.counts_from_active_set(tmp, record_by_id)
		):
			continue
		if catcher_n < MIN_ACTIVE_CATCHERS:
			continue
		if not _position_coverage_ok(tmp, position_holder_lookup, position_floor):
			continue
		new_active = tmp
		applied_pairs.append(pair)

	if applied_pairs.is_empty():
		_append_snapshots(season, all_records, current_day)
		return summary

	# 適用: 新ロスター保存 + demotion_day 記録
	var new_ids: Array = []
	for pid_v in new_active.keys():
		new_ids.append(int(pid_v))
	var new_roster: Dictionary = roster.duplicate(true)
	new_roster["player_ids"] = new_ids
	season.set_active_roster(team_id, new_roster)
	var demoted_ids: Array = []
	for pair_row in applied_pairs:
		demoted_ids.append(int((pair_row as Dictionary)["down"]))
	season.record_demotions(team_id, demoted_ids, current_day)

	# (7) 月別差分用のスナップショットを保存
	_append_snapshots(season, all_records, current_day)

	summary["swapped_pairs"] = applied_pairs
	return summary


# 全 record の current_day snapshot を保存する。月別 stats の差分計算で次回以降使う。
static func _append_snapshots(season: PSSeason, all_records: Array, current_day: int) -> void:
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		season.append_player_stat_snapshot(record.player_id, current_day, record.batter_stats, record.pitcher_stats)


# 事前計算された score_by_id を使った 1軍平均算出。
static func _records_mean_perf_with_scores(records: Array, score_by_id: Dictionary) -> float:
	if records.is_empty():
		return 0.0
	var total: float = 0.0
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		total += float(score_by_id.get(record.player_id, 0.0))
	return total / float(records.size())


# perf は事前計算された値 (score_by_id から取得済み)。
static func _is_demotion_candidate(
	record: PSPlayerSeasonRecord,
	perf: float,
	current_day: int,
	starter_mean: float,
	reliever_mean: float,
	batter_mean: float
) -> bool:
	if record.fatigue >= DEMOTION_FATIGUE_PROTECT_THRESHOLD:
		return false
	var day_denom: int = max(current_day, 1)
	var is_starter: bool = _is_starting_pitcher(record)
	# (A) 未出場判定
	if record.is_pitcher():
		var outs_rate: float = float(record.pitcher_stats.outs_pitched) / float(day_denom)
		var min_ratio: float = MIN_APPEARANCE_RATIO_STARTER if is_starter else MIN_APPEARANCE_RATIO_PITCHER
		if outs_rate < min_ratio:
			return true
	else:
		var pa_rate: float = float(record.batter_stats.plate_appearances) / float(day_denom)
		if pa_rate < MIN_APPEARANCE_RATIO_BATTER:
			return true
	# (B) 1軍平均比 (先発は緩い閾値)
	var mean: float = batter_mean
	if record.is_pitcher():
		mean = starter_mean if is_starter else reliever_mean
	if mean <= 0.0:
		return false
	var under_gap: float = UNDERPERFORM_GAP
	if is_starter:
		under_gap = UNDERPERFORM_GAP_STARTER
	elif not record.is_pitcher():
		under_gap = UNDERPERFORM_GAP_BATTER
	return perf < mean - under_gap
