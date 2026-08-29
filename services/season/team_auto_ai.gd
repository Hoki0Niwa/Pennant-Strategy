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
# MAINSTAY=+0.12σ は「平均をわずかに上回る」水準、CORE=+1.4σ は投打どちらも上位 8% 相当。
# σ で置くのは、絶対値だと同じ点数が投手と野手で違う厳しさになるため。
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
# 通常の一軍先発は6人。谷間は二軍からのスポット昇格、ローテ下位の休養・再調整は
# 定期入替で補う。PSTeamSetupBuilder.preview_active_roster と同じ値に保つ。
const TARGET_STARTERS: int = 6
const TARGET_PITCHERS: int = 15
const MIN_ACTIVE_CATCHERS: int = 2
# ⚠️ **「守備固め用の守備要員を一軍へ確保する」枠は置かない。** 一軍の控えには既に
# 「その位置の先発より守備が 22点以上上」の選手が **8枠中 3.5枠 (44%)** 居るので、
# 守備固めが出ないときの原因は控えの顔ぶれではなく判定側のゲート
# (`PSInGameSubstitutions.defensive_replacement_option`) を疑うこと。
# 控えの守備力は `run_playing_time_probe` の `bench_defense` で測れる。
const PITCHER_ROLE_STARTER: String = "starter"
const PITCHER_ROLE_RELIEVER: String = "reliever"
# 下位ローテを二軍で再調整し、休養十分な二軍先発へ枠を渡す間隔。
# 週次フックで判定するため、実際の間隔はこの値以上の最初の判定日になる。
const STARTER_ADJUSTMENT_INTERVAL_DAYS: int = 21
const STARTER_ADJUSTMENT_FIRST_DAY: int = 21
const STARTER_ADJUSTMENT_MIN_STARTS: int = 2
# 現ローテ最下位との評価差がこの範囲なら、候補が少し劣っていても調整登板を任せる。
const STARTER_ADJUSTMENT_MAX_QUALITY_GAP: float = 10.0
# ベンチ野手と下位救援は、成績不振だけを条件にすると年間を通じて固定されやすい。
# 控えの実戦確認とブルペンの休養を兼ね、一定間隔で同等戦力の二軍選手へ枠を渡す。
const DEPTH_ADJUSTMENT_FIRST_DAY: int = 14
const FIELDER_ADJUSTMENT_INTERVAL_DAYS: int = 14
const RELIEVER_ADJUSTMENT_INTERVAL_DAYS: int = 14
const DEPTH_ADJUSTMENT_MAX_QUALITY_GAP: float = 10.0
const PROTECTED_RELIEF_ROLE_COUNT: int = 6
const ROSTER_GROUP_FIELDER: String = "fielder"
# 12球団二軍の使用投手を実 NPB の40人台へ近づけるため、週次入替で投手の動きが
# 1件も無かった週は「10日間の再調整」として1枠を循環させる。能力不振とは別の機構なので、
# 一軍主力も年1回程度は対象になり得るが、同役割・品質差内の代役とだけ交換する。
const PITCHER_CIRCULATION_FIRST_DAY: int = 14
const PITCHER_CIRCULATION_INTERVAL_DAYS: int = 7
const PITCHER_CIRCULATION_MAX_QUALITY_GAP: float = 22.0
const PITCHER_CIRCULATION_MIN_STARTS: int = 2
# 循環の降格候補から外すローテ上位の人数。**降格候補は二軍登板の少ない順に並ぶので、
# 二軍登板 0 のローテ中軸がまっ先に候補になる**。ここで守らないとエースが毎週の循環枠で
# 二軍へ落ち、リーグ最多先発が24試合・規定投球回到達が3〜6人まで落ちる (2026-08-28 実測)。
const PITCHER_CIRCULATION_PROTECTED_ROTATION_RANKS: int = 3
const PITCHER_CIRCULATION_MIN_RELIEF_GAMES: int = 3

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
		return prior + form + _farm_form_bonus(record) \
			+ war_value * WAR_PERF_WEIGHT * _pitcher_reliability(stats)
	var stats_b: PSBatterStats = monthly_batter if monthly_batter != null else record.batter_stats
	var form_b: float = PSBatterForm.rating_delta(record, monthly_batter)
	return prior + form_b + _farm_form_bonus(record) \
		+ war_value * WAR_PERF_WEIGHT * _batter_reliability(stats_b)


# 二軍成績が能力からどれだけ上振れ/下振れしているか。**一軍の form と同じ rating 点だが、
# 割引して足す。**
#
# なぜ割引が要るか: `PSBatterForm.farm_rating_delta` は二軍の成績分布で σ 化してあるので
# 「二軍で能力なりの成績」は 0 になる (リーグ難度差は alignment が吸収済み)。それでも
# 二軍の +1 と一軍の +1 を等価に扱うべきではない — 二軍は対戦相手の質のばらつきが大きく、
# 一軍で同じ成績を出せる保証にならないため。**FARM_FORM_WEIGHT は較正ノブ**で、
# 上げると二軍の好調が昇格へ強く効き、下げると能力評価 (prior) 主導に戻る。
#
# ⚠️ 一軍成績と二軍成績は**両方足す**。一軍で不振 → 降格 → 二軍で好調、という選手は
# 一軍の負の form と二軍の正の form を両方持つのが正しい (どちらかで上書きしない)。
const FARM_FORM_WEIGHT: float = 0.5
# 二軍成績を評価に使い始める最低出場量。少ない標本で昇格判断が暴れるのを防ぐ
# (一軍側の reliability 縮約と同じ趣旨だが、こちらは単純な足切り)。
const FARM_FORM_MIN_PLATE_APPEARANCES: int = 40
const FARM_FORM_MIN_BATTERS_FACED: int = 40


static func _farm_form_bonus(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	if record.is_pitcher():
		if record.farm_pitcher_stats.batters_faced < FARM_FORM_MIN_BATTERS_FACED:
			return 0.0
		return PSPitcherForm.farm_rating_delta(record) * FARM_FORM_WEIGHT
	if record.farm_batter_stats.plate_appearances < FARM_FORM_MIN_PLATE_APPEARANCES:
		return 0.0
	return PSBatterForm.farm_rating_delta(record) * FARM_FORM_WEIGHT


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


# 1軍の先発 role だけを抜き出す (ローテ序列の組み替え候補)。故障中は除く。
static func _active_starter_records(active_records: Array) -> Array:
	var starters: Array = []
	for record_row in active_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if _is_starting_pitcher(record) and record.injury_days <= 0:
			starters.append(record)
	return starters


# 戦力外用: 能力(総合評価) + 出場数 - 年齢ペナルティ。低いほど切られやすい。
# **成績(ERA/勝敗等の実績)は使わない**。成績を混ぜると、能力が高く出場機会を得たが不振だった
# 選手を出場ゼロの格下選手より先に切ってしまうため、能力ベースに統一する。
# 出場数(登板数/試合数)は「起用されている=編成上の価値がある」として加点する
# (出場数であって成績ではない点に注意)。**投手と野手で同スケール (最大24点前後)** にすること —
# 片側だけ加点があると中間層がそちらに偏って先に切られ、戦力外の投手:野手が 1:2 に傾く。
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
		# 育成選手は一軍登録不可 (試合に出場できない)。
		if record.development_player:
			continue
		if record.is_pitcher():
			if _is_starting_pitcher(record):
				starters.append(record)
			else:
				relievers.append(record)
		else:
			fielders.append(record)

	# 選出スコアは perf_score (= overall_prior + form) で、1 人あたり守備 8 ポジション評価と
	# 過去数季ぶんの成績ブレンドを含む。comparator の中で引くと 1 回の sort で O(n log n) 回
	# 走るので、先に選手ごと 1 回だけ引く (比較結果は同じなので並び順も変わらない)。
	var score_by_id: Dictionary = _selection_scores_by_id([starters, relievers, fielders])
	var by_perf: Callable = func(a, b) -> bool:
		return _cached_selection_score(a, score_by_id) > _cached_selection_score(b, score_by_id)
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
	# 昇格候補は支配下から一軍を除いた ~40 人規模。comparator 内で perf_score を引くと
	# 1 回の修復で数百回走るため、先に 1 人 1 回だけ引く。
	var promote_scores: Dictionary = _selection_scores_by_id([promote_pool])
	promote_pool.sort_custom(func(a, b) -> bool:
		return (
			_cached_selection_score(a, promote_scores) > _cached_selection_score(b, promote_scores)
		)
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
	_record_callup_appearance_baselines(season, team_id, promotions, record_by_id)
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
	if record == null or record.injury_days <= INJURY_SHORT_ABSENCE_STASH_DAYS:
		return false
	if record.injury_days > INJURY_MAINSTAY_STASH_MAX_DAYS:
		return true
	return record.injury_days > _active_injury_stash_limit(record)


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


# 複数プールぶんの選出スコアを player_id → score でまとめて引く。sort の comparator へ渡して
# 「比較のたびに再計算」を防ぐためのもの。同じ選手が複数プールに居ても 1 回しか計算しない。
static func _selection_scores_by_id(pools: Array) -> Dictionary:
	var scores: Dictionary = {}
	for pool_row in pools:
		for record_row in (pool_row as Array):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and not scores.has(record.player_id):
				scores[record.player_id] = _active_roster_selection_score(record)
	return scores


# 事前計算済みスコアの参照。null は _active_roster_selection_score(null) と同値に揃える。
static func _cached_selection_score(row: Variant, scores: Dictionary) -> float:
	var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
	if record == null:
		return -999999.0
	return float(scores.get(record.player_id, -999999.0))


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
# ---- 谷間の先発 (スポット昇格) ---------------------------------------------
#
# NPB で1球団が1シーズンに使う先発が12〜16人になるのは、**登録抹消 → 10日 → 再登録**の
# 往復が生む数字であって、スコア比較の週次入替からは構造的に出ない
# (実測: 二軍成績を評価へ繋いでも distinct starters は 7.8 → 8.0 までしか動かなかった)。
#
# そこでローテに中6日の空きが作れない日 (= 谷間) には、二軍から**その試合限りで**先発を上げ、
# 登板翌日に抹消する。抹消は既存の `DEMOTION_COOLDOWN_DAYS`(10日ルール) に乗るので、
# **次の谷間は別の投手を上げるしかなくなる** — これが顔ぶれを増やす仕掛け。
#
# 実行は試合日の計算より前 (メインスレッド)。ロスターが確定していないと setup が組めないため。

# 昇格させる二軍投手に要求する休養日数。中6日で投げられる投手だけを呼ぶ
# (谷間を埋めるのが目的なのに、上げた投手が短い休みでは意味がない)。
const SPOT_CALLUP_MIN_REST_DAYS: int = 6
# 一軍先発の平均からこれ以上落ちる投手は上げない。谷間を埋めるためだけに極端な格下を
# 使わないための品質ゲート (緩め — ここを厳しくすると機構そのものが発火しなくなる)。
const SPOT_CALLUP_MAX_QUALITY_GAP: float = 22.0
# **この理由で埋まる日は谷間ではない。** 中6日 (`rotation`) はもちろん、中5日 (`short_rest`) や
# 終盤の前倒し (`stretch_run`) は NPB でも通常運用なので二軍から上げない。
# 二軍を呼ぶのは中4日以下 (`min_rest`) / ブルペンデー (`spot_relief`) / 非常時 (`emergency`) だけ。
# ⚠️ ここを「rotation 以外すべて」にすると年489先発 (全体の28%) がスポット昇格になり、
#    枠繰りでロースターが荒れて中0〜3日の先発まで発生した。実測で判明。
const ROTATION_REASONS_NO_GAP: Array[String] = ["rotation", "short_rest", "stretch_run", "postseason"]


static func run_spot_starter_callups(
	season: PSSeason, teams: Array, current_day: int, user_team_id: int, include_user_team: bool
) -> Dictionary:
	var callups: Array = []
	var returns: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if team.id == user_team_id and not include_user_team:
			continue
		# 1) 登板を終えたスポット昇格を先に戻す (今日の枠を空けるため順序が重要)。
		returns.append_array(_return_finished_spot_callups(season, team.id, current_day))
		# 2) 今日試合が無い球団は何もしない。
		if not _team_has_unplayed_game_on_day(season, team.id, current_day):
			continue
		var callup: Dictionary = _try_spot_callup(season, team.id, current_day)
		if not callup.is_empty():
			callups.append(callup)
	return {"callups": callups, "callup_count": callups.size(), "returns": returns, "return_count": returns.size()}


static func _team_has_unplayed_game_on_day(season: PSSeason, team_id: int, day: int) -> bool:
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if int(game.get("day", 0)) != day or bool(game.get("played", false)):
			continue
		if int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id:
			return true
	return false


# 前日までに登板を終えたスポット昇格を二軍へ戻す。`record_demotions` を通すので
# 10日ルールのクールダウンが付き、同じ投手が次の谷間で連続起用されない。
static func _return_finished_spot_callups(season: PSSeason, team_id: int, current_day: int) -> Array:
	var callups: Dictionary = season.get_spot_callups(team_id)
	if callups.is_empty():
		return []
	var roster: Dictionary = season.get_active_roster(team_id).duplicate(true)
	var active_ids: Array = (roster.get("player_ids", []) as Array).duplicate()
	var returned: Array = []
	for key_value in callups.keys():
		var player_id: int = int(str(key_value))
		if int(callups[key_value]) >= current_day:
			continue
		active_ids.erase(player_id)
		season.clear_spot_callup(team_id, player_id)
		returned.append({"team_id": team_id, "player_id": player_id})
	if returned.is_empty():
		return []
	var demoted_ids: Array = []
	for row in returned:
		demoted_ids.append(int((row as Dictionary).get("player_id", 0)))
	season.record_demotions(team_id, demoted_ids, current_day)
	# スポット先発を外すだけでは登録が30人へ縮む。枠を空けるため前日に抹消した救援は
	# 10日間再登録できないため、別の健康な救援を補充して31人を維持する。
	var refill: Dictionary = _refill_after_spot_return(
		season, team_id, active_ids, demoted_ids, current_day
	)
	active_ids = refill.get("player_ids", active_ids) as Array
	roster = season.get_active_roster(team_id).duplicate(true)
	roster["player_ids"] = active_ids
	roster["spot_callup"] = season.get_spot_callups(team_id)
	season.set_active_roster(team_id, roster)
	_record_callup_appearance_baselines(
		season,
		team_id,
		refill.get("promotions", []) as Array,
		refill.get("record_by_id", {}) as Dictionary
	)
	return returned


static func _refill_after_spot_return(
	season: PSSeason,
	team_id: int,
	active_id_list: Array,
	excluded_ids: Array,
	current_day: int
) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(
		team_id, season.year, season.season_number
	)
	var record_by_id: Dictionary = {}
	var active_set: Dictionary = {}
	var excluded: Dictionary = {}
	for id_value in active_id_list:
		active_set[int(id_value)] = true
	for id_value in excluded_ids:
		excluded[int(id_value)] = true
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record
	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var candidates: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not _is_healthy_active_roster_candidate(record) \
				or active_set.has(record.player_id) or excluded.has(record.player_id):
			continue
		var last_demote: int = int(demotion_days.get(str(record.player_id), 0))
		if last_demote > 0 and current_day - last_demote < DEMOTION_COOLDOWN_DAYS:
			continue
		candidates.append(record)
	var scores: Dictionary = _selection_scores_by_id([candidates])
	candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var relief_a: bool = record_a.is_pitcher() and not _is_starting_pitcher(record_a)
		var relief_b: bool = record_b.is_pitcher() and not _is_starting_pitcher(record_b)
		if relief_a != relief_b:
			return relief_a
		return _cached_selection_score(record_a, scores) > _cached_selection_score(record_b, scores)
	)
	var promotions: Array = []
	for record_row in candidates:
		if active_set.size() >= TARGET_TOTAL:
			break
		var candidate: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var proposed: Dictionary = active_set.duplicate()
		proposed[candidate.player_id] = true
		if not ForeignActiveRosterRules.is_within_limits(
			ForeignActiveRosterRules.counts_from_active_set(proposed, record_by_id)
		):
			continue
		active_set = proposed
		active_id_list.append(candidate.player_id)
		promotions.append(candidate.player_id)
	return {
		"player_ids": active_id_list,
		"promotions": promotions,
		"record_by_id": record_by_id,
	}


static func _try_spot_callup(season: PSSeason, team_id: int, current_day: int) -> Dictionary:
	var all_records: Array = RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	if all_records.is_empty():
		return {}
	var active_ids: Dictionary = {}
	for id_value in (season.get_active_roster(team_id).get("player_ids", []) as Array):
		active_ids[int(id_value)] = true
	if active_ids.is_empty():
		return {}

	var active_starters: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not active_ids.has(record.player_id) or record.injury_days > 0:
			continue
		if _is_starting_pitcher(record):
			active_starters.append(record)
	if active_starters.is_empty():
		return {}

	# 通常運用で埋まる日は谷間ではない。
	var decision: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, active_starters)
	if ROTATION_REASONS_NO_GAP.has(str(decision.get("reason", ""))):
		return {}

	var candidate: PSPlayerSeasonRecord = _best_farm_spot_starter(
		season, team_id, all_records, active_ids, current_day, _records_mean_perf(active_starters)
	)
	if candidate == null:
		return {}
	var released: PSPlayerSeasonRecord = _spot_callup_roster_slot(
		all_records, active_ids, decision.get("pitcher", null) as PSPlayerSeasonRecord
	)
	if released == null:
		return {}

	var roster: Dictionary = season.get_active_roster(team_id).duplicate(true)
	var ids: Array = (roster.get("player_ids", []) as Array).duplicate()
	ids.erase(released.player_id)
	if not ids.has(candidate.player_id):
		ids.append(candidate.player_id)
	roster["player_ids"] = ids
	season.set_active_roster(team_id, roster)
	# 枠を空けた側にも10日ルールを適用する (NPB の抹消と同じ扱い)。
	season.record_demotions(team_id, [released.player_id], current_day)
	season.record_spot_callup(team_id, candidate.player_id, current_day)
	return {
		"team_id": team_id,
		"player_id": candidate.player_id,
		"name": candidate.name,
		"replaced_player_id": released.player_id,
		"day": current_day,
	}


# 中6日以上空いていて、クールダウン中でない二軍の先発から最良を選ぶ。
static func _best_farm_spot_starter(
	season: PSSeason,
	team_id: int,
	all_records: Array,
	active_ids: Dictionary,
	current_day: int,
	active_starter_mean: float
) -> PSPlayerSeasonRecord:
	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var last_starts: Dictionary = (season.get_rotation(team_id).get("last_start_day_by_pitcher", {}) as Dictionary)
	var best: PSPlayerSeasonRecord = null
	var best_score: float = -INF
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if active_ids.has(record.player_id) or record.injury_days > 0:
			continue
		# 育成選手は一軍登録不可 (支配下枠の外)。
		if record.development_player or not _is_starting_pitcher(record):
			continue
		# 10日ルール: 抹消から DEMOTION_COOLDOWN_DAYS 未満は再登録できない。
		var demoted_day: int = int(demotion_days.get(str(record.player_id), 0))
		if demoted_day > 0 and current_day - demoted_day < DEMOTION_COOLDOWN_DAYS:
			continue
		var last_start: int = int(last_starts.get(str(record.player_id), 0))
		if last_start > 0 and current_day - last_start < SPOT_CALLUP_MIN_REST_DAYS + 1:
			continue
		var score: float = perf_score(record)
		if active_starter_mean > 0.0 and score < active_starter_mean - SPOT_CALLUP_MAX_QUALITY_GAP:
			continue
		if score > best_score:
			best_score = score
			best = record
	return best


# 昇格ぶんの枠を空ける相手。**救援投手からしか選ばない。**
# ⚠️ 先発を落とすとローテの頭数が減り、`resolve_rotation_decision` が中4日→非常時フォールバックへ
#    落ちて**中0〜3日の先発が発生した** (実測: 1人の最多先発が27→40へ膨張)。
#    谷間を埋めるための昇格が、別の谷間を作ってしまう自己矛盾になる。
# 疲労の溜まった救援を落として二軍の先発を上げる、というのは NPB の実際の運用そのもの。
static func _spot_callup_roster_slot(
	all_records: Array, active_ids: Dictionary, _todays_starter: PSPlayerSeasonRecord
) -> PSPlayerSeasonRecord:
	var worst: PSPlayerSeasonRecord = null
	var worst_score: float = INF
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not active_ids.has(record.player_id) or not record.is_pitcher():
			continue
		if _is_starting_pitcher(record):
			continue
		var score: float = _active_roster_selection_score(record)
		if score < worst_score:
			worst_score = score
			worst = record
	return worst


static func _records_mean_perf(records: Array) -> float:
	if records.is_empty():
		return 0.0
	var total: float = 0.0
	for record_row in records:
		total += perf_score(record_row as PSPlayerSeasonRecord)
	return total / float(records.size())


static func run_periodic_roster_swaps(season: PSSeason, teams: Array, current_day: int, user_team_id: int, include_user_team: bool) -> Dictionary:
	# 入替対象がある日にだけリーグ集計を作り、対象チーム間では同じ結果を使い回す。
	var war_ctx: Dictionary = {}
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
		# (入替判定はしない)。CPU 球団・自動入替ONの自軍は _swap_one_team が入替と記録を行う。
		if is_user and not include_user_team:
			_append_snapshots(season, RecordStore.get_team_player_records(team.id, season.year, season.season_number), current_day)
			season.set_last_auto_swap_day(team.id, current_day)
			continue
		if war_ctx.is_empty():
			war_ctx = WarCalculator.build_league_context(season.year, season.season_number)
		var summary: Dictionary = _swap_one_team(season, team.id, current_day, war_ctx)
		var pairs: Array = (summary.get("swapped_pairs", []) as Array).duplicate(true)
		var adjustment: Dictionary = _try_starter_rotation_adjustment(
			season, team.id, current_day, pairs
		)
		if not adjustment.is_empty():
			pairs.append(adjustment)
			summary["swapped_pairs"] = pairs
		var relief_adjustment: Dictionary = _try_depth_roster_adjustment(
			season, team.id, current_day, PITCHER_ROLE_RELIEVER
		)
		if not relief_adjustment.is_empty():
			pairs.append(relief_adjustment)
			summary["swapped_pairs"] = pairs
		# 成績入替とは目的が違う独立の週次再調整枠。通常入替が投手を動かした週に止めると、
		# 通季の使用投手が30人台前半で頭打ちになったため、品質・同役割ゲートの範囲で毎週試す。
		var circulation: Dictionary = _try_pitcher_circulation_adjustment(
			season, team.id, current_day
		)
		if not circulation.is_empty():
			pairs.append(circulation)
			summary["swapped_pairs"] = pairs
		var fielding_adjustment: Dictionary = _try_depth_roster_adjustment(
			season, team.id, current_day, ROSTER_GROUP_FIELDER
		)
		if not fielding_adjustment.is_empty():
			pairs.append(fielding_adjustment)
			summary["swapped_pairs"] = pairs
		season.set_last_auto_swap_day(team.id, current_day)
		season.clear_stale_demotions(team.id, current_day)
		if not (summary.get("swapped_pairs", []) as Array).is_empty():
			summary["team_id"] = team.id
			executed.append(summary)
	return {
		"ok": true,
		"executed": executed,
	}


# 成績不振ではなく「二軍で一度も投げていない投手へ再調整機会を作る」ための循環。
# 降格者は二軍登板数の少ない順、昇格者は既に一軍登板歴がある順なので、
# 一軍の年間使用人数を際限なく増やさずに一二軍の重なりを広げる。
static func _try_pitcher_circulation_adjustment(
	season: PSSeason, team_id: int, current_day: int
) -> Dictionary:
	if current_day < PITCHER_CIRCULATION_FIRST_DAY:
		return {}
	var roster: Dictionary = season.get_active_roster(team_id).duplicate(true)
	var last_day: int = int(roster.get("last_pitcher_circulation_day", 0))
	if last_day > 0 and current_day - last_day < PITCHER_CIRCULATION_INTERVAL_DAYS:
		return {}
	var all_records: Array = RecordStore.get_team_player_records(
		team_id, season.year, season.season_number
	)
	var record_by_id: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record
	var active_id_list: Array = (roster.get("player_ids", []) as Array).duplicate()
	var active_ids: Dictionary = {}
	for id_value in active_id_list:
		active_ids[int(id_value)] = true
	if active_ids.is_empty():
		return {}

	var spot_callups: Dictionary = season.get_spot_callups(team_id)
	var baselines: Dictionary = season.get_callup_appearance_baselines(team_id)
	var protected_ids: Dictionary = _protected_rotation_ids(season, team_id)
	var down_candidates: Array = []
	for id_value in active_id_list:
		var record: PSPlayerSeasonRecord = record_by_id.get(int(id_value), null) as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher() or record.injury_days > 0 \
				or record.development_player or spot_callups.has(str(record.player_id)):
			continue
		if protected_ids.has(record.player_id):
			continue
		var appearances: int = record.pitcher_stats.games
		if _is_starting_pitcher(record):
			if record.pitcher_stats.starts < PITCHER_CIRCULATION_MIN_STARTS:
				continue
		elif appearances < PITCHER_CIRCULATION_MIN_RELIEF_GAMES:
			continue
		var baseline_key: String = str(record.player_id)
		if baselines.has(baseline_key) and appearances <= int(baselines[baseline_key]):
			continue
		down_candidates.append(record)
	if down_candidates.is_empty():
		return {}
	var down_scores: Dictionary = _selection_scores_by_id([down_candidates])
	down_candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		if record_a.farm_pitcher_stats.games != record_b.farm_pitcher_stats.games:
			return record_a.farm_pitcher_stats.games < record_b.farm_pitcher_stats.games
		var score_a: float = _cached_selection_score(record_a, down_scores)
		var score_b: float = _cached_selection_score(record_b, down_scores)
		if not is_equal_approx(score_a, score_b):
			return score_a < score_b
		return record_a.player_id < record_b.player_id
	)

	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var up_candidates: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or not record.is_pitcher() or active_ids.has(record.player_id) \
				or record.injury_days > 0 or record.development_player:
			continue
		var demoted_day: int = int(demotion_days.get(str(record.player_id), 0))
		if demoted_day > 0 and current_day - demoted_day < DEMOTION_COOLDOWN_DAYS:
			continue
		up_candidates.append(record)
	if up_candidates.is_empty():
		return {}
	var up_scores: Dictionary = _selection_scores_by_id([up_candidates])
	up_candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var used_a: bool = record_a.pitcher_stats.games > 0
		var used_b: bool = record_b.pitcher_stats.games > 0
		if used_a != used_b:
			return used_a
		var demoted_a: int = int(demotion_days.get(str(record_a.player_id), 0))
		var demoted_b: int = int(demotion_days.get(str(record_b.player_id), 0))
		if demoted_a != demoted_b:
			return demoted_a > demoted_b
		var score_a: float = _cached_selection_score(record_a, up_scores)
		var score_b: float = _cached_selection_score(record_b, up_scores)
		if not is_equal_approx(score_a, score_b):
			return score_a > score_b
		return record_a.player_id < record_b.player_id
	)

	var down: PSPlayerSeasonRecord = null
	var up: PSPlayerSeasonRecord = null
	for down_row in down_candidates:
		var down_candidate: PSPlayerSeasonRecord = down_row as PSPlayerSeasonRecord
		var down_starter: bool = _is_starting_pitcher(down_candidate)
		var down_score: float = _cached_selection_score(down_candidate, down_scores)
		for up_row in up_candidates:
			var up_candidate: PSPlayerSeasonRecord = up_row as PSPlayerSeasonRecord
			if _is_starting_pitcher(up_candidate) != down_starter:
				continue
			if _cached_selection_score(up_candidate, up_scores) \
					< down_score - PITCHER_CIRCULATION_MAX_QUALITY_GAP:
				continue
			var proposed: Dictionary = active_ids.duplicate()
			proposed.erase(down_candidate.player_id)
			proposed[up_candidate.player_id] = true
			if not ForeignActiveRosterRules.is_within_limits(
				ForeignActiveRosterRules.counts_from_active_set(proposed, record_by_id)
			):
				continue
			down = down_candidate
			up = up_candidate
			break
		if up != null:
			break
	if down == null or up == null:
		return {}

	var down_index: int = active_id_list.find(down.player_id)
	if down_index < 0:
		return {}
	active_id_list[down_index] = up.player_id
	roster["player_ids"] = active_id_list
	roster["last_pitcher_circulation_day"] = current_day
	season.set_active_roster(team_id, roster)
	season.record_demotions(team_id, [down.player_id], current_day)
	_record_callup_appearance_baselines(season, team_id, [up.player_id], record_by_id)
	if _is_starting_pitcher(down):
		_replace_rotation_pitcher(season, team_id, down.player_id, up.player_id)
	else:
		_replace_relief_role_pitcher(season, team_id, down.player_id, up.player_id)
	return {
		"down": down.player_id,
		"up": up.player_id,
		"reason": "pitcher_circulation",
	}


# 週次の循環枠で動かさないローテ中軸の id セット。順序は保存されたローテ序列
# (`reorder_auto_rotation` が成績順に組み替える) なので、不振で序列が下がれば守られなくなる。
static func _protected_rotation_ids(season: PSSeason, team_id: int) -> Dictionary:
	var protected_ids: Dictionary = {}
	var rotation: Array = season.get_rotation(team_id).get("pitcher_ids", []) as Array
	for index in range(min(rotation.size(), PITCHER_CIRCULATION_PROTECTED_ROTATION_RANKS)):
		protected_ids[int(rotation[index])] = true
	return protected_ids


static func _try_starter_rotation_adjustment(
	season: PSSeason,
	team_id: int,
	current_day: int,
	existing_pairs: Array
) -> Dictionary:
	if current_day < STARTER_ADJUSTMENT_FIRST_DAY:
		return {}
	var roster: Dictionary = season.get_active_roster(team_id).duplicate(true)
	var last_day: int = int(roster.get("last_starter_adjustment_day", 0))
	if last_day > 0 and current_day - last_day < STARTER_ADJUSTMENT_INTERVAL_DAYS:
		return {}
	var all_records: Array = RecordStore.get_team_player_records(
		team_id, season.year, season.season_number
	)
	var record_by_id: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record
	for pair_row in existing_pairs:
		var down_record: PSPlayerSeasonRecord = record_by_id.get(
			int((pair_row as Dictionary).get("down", 0)), null
		) as PSPlayerSeasonRecord
		if _is_starting_pitcher(down_record):
			return {}

	var active_ids: Dictionary = {}
	var active_id_list: Array = (roster.get("player_ids", []) as Array).duplicate()
	for id_value in active_id_list:
		active_ids[int(id_value)] = true
	var spot_callups: Dictionary = season.get_spot_callups(team_id)
	var active_starters: Array = []
	for id_value in active_id_list:
		var record: PSPlayerSeasonRecord = record_by_id.get(int(id_value), null) as PSPlayerSeasonRecord
		if not _is_starting_pitcher(record) or record.injury_days > 0 \
				or spot_callups.has(str(record.player_id)):
			continue
		if record.pitcher_stats.starts < STARTER_ADJUSTMENT_MIN_STARTS:
			continue
		active_starters.append(record)
	if active_starters.is_empty():
		return {}
	var active_scores: Dictionary = _selection_scores_by_id([active_starters])
	active_starters.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var score_a: float = _cached_selection_score(record_a, active_scores)
		var score_b: float = _cached_selection_score(record_b, active_scores)
		if is_equal_approx(score_a, score_b):
			return record_a.pitcher_stats.starts < record_b.pitcher_stats.starts
		return score_a < score_b
	)
	var down: PSPlayerSeasonRecord = active_starters[0] as PSPlayerSeasonRecord
	var down_score: float = _cached_selection_score(down, active_scores)

	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var last_starts: Dictionary = (
		season.get_rotation(team_id).get("last_start_day_by_pitcher", {}) as Dictionary
	)
	var candidates: Array = []
	for record_row in all_records:
		var candidate: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if candidate == null or active_ids.has(candidate.player_id) \
				or candidate.injury_days > 0 or candidate.development_player \
				or not _is_starting_pitcher(candidate):
			continue
		var demoted_day: int = int(demotion_days.get(str(candidate.player_id), 0))
		if demoted_day > 0 and current_day - demoted_day < DEMOTION_COOLDOWN_DAYS:
			continue
		var last_start: int = int(last_starts.get(str(candidate.player_id), 0))
		if last_start > 0 and current_day - last_start < SPOT_CALLUP_MIN_REST_DAYS + 1:
			continue
		var score: float = _active_roster_selection_score(candidate)
		if score < down_score - STARTER_ADJUSTMENT_MAX_QUALITY_GAP:
			continue
		candidates.append(candidate)
	if candidates.is_empty():
		return {}
	var candidate_scores: Dictionary = _selection_scores_by_id([candidates])
	candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		if record_a.pitcher_stats.starts != record_b.pitcher_stats.starts:
			return record_a.pitcher_stats.starts < record_b.pitcher_stats.starts
		var score_a: float = _cached_selection_score(record_a, candidate_scores)
		var score_b: float = _cached_selection_score(record_b, candidate_scores)
		if is_equal_approx(score_a, score_b):
			return record_a.player_id < record_b.player_id
		return score_a > score_b
	)
	var up: PSPlayerSeasonRecord = null
	for candidate_row in candidates:
		var candidate: PSPlayerSeasonRecord = candidate_row as PSPlayerSeasonRecord
		var proposed: Dictionary = active_ids.duplicate()
		proposed.erase(down.player_id)
		proposed[candidate.player_id] = true
		if ForeignActiveRosterRules.is_within_limits(
			ForeignActiveRosterRules.counts_from_active_set(proposed, record_by_id)
		):
			up = candidate
			break
	if up == null:
		return {}

	var down_index: int = active_id_list.find(down.player_id)
	if down_index < 0:
		return {}
	active_id_list[down_index] = up.player_id
	roster["player_ids"] = active_id_list
	roster["last_starter_adjustment_day"] = current_day
	season.set_active_roster(team_id, roster)
	season.record_demotions(team_id, [down.player_id], current_day)
	_record_callup_appearance_baselines(season, team_id, [up.player_id], record_by_id)
	_replace_rotation_pitcher(season, team_id, down.player_id, up.player_id)
	return {
		"down": down.player_id,
		"up": up.player_id,
		"reason": "starter_adjustment",
	}


# 控え野手または役割枠外の救援を、同等戦力の二軍選手と定期的に入れ替える。
# 既に一軍で出場した選手だけを降格対象にするため、登録されただけで未出場のまま
# 次の選手へ枠が移ることはない。昇格側は未出場・出場少の順で実戦確認する。
static func _try_depth_roster_adjustment(
	season: PSSeason,
	team_id: int,
	current_day: int,
	roster_group: String
) -> Dictionary:
	if current_day < DEPTH_ADJUSTMENT_FIRST_DAY:
		return {}
	if roster_group != ROSTER_GROUP_FIELDER and roster_group != PITCHER_ROLE_RELIEVER:
		return {}
	var interval_days: int = (
		FIELDER_ADJUSTMENT_INTERVAL_DAYS
		if roster_group == ROSTER_GROUP_FIELDER
		else RELIEVER_ADJUSTMENT_INTERVAL_DAYS
	)
	var last_day_key: String = "last_%s_adjustment_day" % roster_group
	var roster: Dictionary = season.get_active_roster(team_id).duplicate(true)
	var last_day: int = int(roster.get(last_day_key, 0))
	if last_day > 0 and current_day - last_day < interval_days:
		return {}

	var all_records: Array = RecordStore.get_team_player_records(
		team_id, season.year, season.season_number
	)
	var record_by_id: Dictionary = {}
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			record_by_id[record.player_id] = record
	var active_id_list: Array = (roster.get("player_ids", []) as Array).duplicate()
	var active_ids: Dictionary = {}
	for id_value in active_id_list:
		active_ids[int(id_value)] = true
	if active_ids.is_empty():
		return {}

	var protected_relievers: Dictionary = {}
	if roster_group == PITCHER_ROLE_RELIEVER:
		var active_relievers: Array = []
		for id_value in active_id_list:
			var record: PSPlayerSeasonRecord = record_by_id.get(int(id_value), null) as PSPlayerSeasonRecord
			if record != null and record.is_pitcher() and not _is_starting_pitcher(record):
				active_relievers.append(record)
		for id_value in PSRotationPlanner.relief_role_order_ids(season.get_rotation(team_id)):
			var player_id: int = int(id_value)
			if active_ids.has(player_id) and not protected_relievers.has(player_id):
				protected_relievers[player_id] = true
				if protected_relievers.size() >= PROTECTED_RELIEF_ROLE_COUNT:
					break
		var relief_scores: Dictionary = _selection_scores_by_id([active_relievers])
		active_relievers.sort_custom(func(a, b) -> bool:
			return _cached_selection_score(a, relief_scores) > _cached_selection_score(b, relief_scores)
		)
		for record_row in active_relievers:
			if protected_relievers.size() >= PROTECTED_RELIEF_ROLE_COUNT:
				break
			protected_relievers[(record_row as PSPlayerSeasonRecord).player_id] = true

	var baselines: Dictionary = season.get_callup_appearance_baselines(team_id)
	var down_candidates: Array = []
	for id_value in active_id_list:
		var record: PSPlayerSeasonRecord = record_by_id.get(int(id_value), null) as PSPlayerSeasonRecord
		if record == null or record.injury_days > 0 or record.development_player:
			continue
		if not _matches_roster_group(record, roster_group):
			continue
		if protected_relievers.has(record.player_id):
			continue
		var appearances: int = _first_team_appearances(record)
		if appearances <= 0:
			continue
		var baseline_key: String = str(record.player_id)
		if baselines.has(baseline_key) and appearances <= int(baselines[baseline_key]):
			continue
		down_candidates.append(record)
	if down_candidates.is_empty():
		return {}
	var down_scores: Dictionary = _selection_scores_by_id([down_candidates])
	down_candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var games_a: int = _first_team_appearances(record_a)
		var games_b: int = _first_team_appearances(record_b)
		if games_a != games_b:
			return games_a < games_b
		return _cached_selection_score(record_a, down_scores) \
			< _cached_selection_score(record_b, down_scores)
	)

	var demotion_days: Dictionary = season.get_demotion_days(team_id)
	var up_candidates: Array = []
	for record_row in all_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or active_ids.has(record.player_id) or record.injury_days > 0 \
				or record.development_player or not _matches_roster_group(record, roster_group):
			continue
		var demoted_day: int = int(demotion_days.get(str(record.player_id), 0))
		if demoted_day > 0 and current_day - demoted_day < DEMOTION_COOLDOWN_DAYS:
			continue
		up_candidates.append(record)
	if up_candidates.is_empty():
		return {}
	var up_scores: Dictionary = _selection_scores_by_id([up_candidates])
	up_candidates.sort_custom(func(a, b) -> bool:
		var record_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var record_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		var games_a: int = _first_team_appearances(record_a)
		var games_b: int = _first_team_appearances(record_b)
		if games_a != games_b:
			return games_a < games_b
		return _cached_selection_score(record_a, up_scores) \
			> _cached_selection_score(record_b, up_scores)
	)

	var position_holder_lookup: Dictionary = _build_position_holder_lookup(all_records)
	var position_floor: Dictionary = {}
	for position in DEFENSIVE_POSITIONS:
		var holders: Dictionary = position_holder_lookup[position] as Dictionary
		position_floor[position] = min(
			min(2, holders.size()), _count_active_holders(active_ids, holders)
		)
	var down: PSPlayerSeasonRecord = null
	var up: PSPlayerSeasonRecord = null
	for down_row in down_candidates:
		var down_candidate: PSPlayerSeasonRecord = down_row as PSPlayerSeasonRecord
		var down_score: float = _cached_selection_score(down_candidate, down_scores)
		for up_row in up_candidates:
			var up_candidate: PSPlayerSeasonRecord = up_row as PSPlayerSeasonRecord
			if _cached_selection_score(up_candidate, up_scores) \
					< down_score - DEPTH_ADJUSTMENT_MAX_QUALITY_GAP:
				continue
			var proposed: Dictionary = active_ids.duplicate()
			proposed.erase(down_candidate.player_id)
			proposed[up_candidate.player_id] = true
			if not ForeignActiveRosterRules.is_within_limits(
				ForeignActiveRosterRules.counts_from_active_set(proposed, record_by_id)
			):
				continue
			if roster_group == ROSTER_GROUP_FIELDER:
				var catcher_count: int = 0
				for player_id_value in proposed.keys():
					if _is_catcher(record_by_id.get(int(player_id_value), null) as PSPlayerSeasonRecord):
						catcher_count += 1
				if catcher_count < MIN_ACTIVE_CATCHERS or not _position_coverage_ok(
					proposed, position_holder_lookup, position_floor
				):
					continue
			down = down_candidate
			up = up_candidate
			break
		if up != null:
			break
	if down == null or up == null:
		return {}

	var down_index: int = active_id_list.find(down.player_id)
	if down_index < 0:
		return {}
	active_id_list[down_index] = up.player_id
	roster["player_ids"] = active_id_list
	roster[last_day_key] = current_day
	season.set_active_roster(team_id, roster)
	season.record_demotions(team_id, [down.player_id], current_day)
	_record_callup_appearance_baselines(season, team_id, [up.player_id], record_by_id)
	return {
		"down": down.player_id,
		"up": up.player_id,
		"reason": "%s_adjustment" % roster_group,
	}


static func _matches_roster_group(record: PSPlayerSeasonRecord, roster_group: String) -> bool:
	if record == null:
		return false
	if roster_group == ROSTER_GROUP_FIELDER:
		return not record.is_pitcher()
	return record.is_pitcher() and not _is_starting_pitcher(record)


static func _first_team_appearances(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	return record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games


static func _replace_rotation_pitcher(
	season: PSSeason, team_id: int, down_id: int, up_id: int
) -> void:
	var rotation: Dictionary = season.get_rotation(team_id).duplicate(true)
	var order: Array = (rotation.get("pitcher_ids", []) as Array).duplicate()
	var down_index: int = order.find(down_id)
	order.erase(down_id)
	order.erase(up_id)
	if down_index >= 0:
		down_index = mini(down_index, order.size())
		order.insert(down_index, up_id)
	else:
		order.append(up_id)
	rotation["pitcher_ids"] = order
	season.set_rotation(team_id, rotation)


static func _replace_relief_role_pitcher(
	season: PSSeason, team_id: int, down_id: int, up_id: int
) -> void:
	var rotation: Dictionary = season.get_rotation(team_id).duplicate(true)
	var relief_roles: Dictionary = (rotation.get("relief_roles", {}) as Dictionary).duplicate(true)
	if relief_roles.is_empty():
		return
	for key in ["long_ids", "middle_ids", "setup_ids"]:
		var ids: Array = (relief_roles.get(key, []) as Array).duplicate()
		var index: int = ids.find(down_id)
		if index < 0:
			continue
		ids.erase(up_id)
		index = mini(index, ids.size())
		ids.insert(index, up_id)
		relief_roles[key] = ids
	if int(relief_roles.get("closer_id", 0)) == down_id:
		relief_roles["closer_id"] = up_id
	rotation["relief_roles"] = relief_roles
	season.set_rotation(team_id, rotation)


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
		var initial_record_by_id: Dictionary = {}
		for record_row in all_records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null:
				initial_record_by_id[record.player_id] = record
		_record_callup_appearance_baselines(
			season, team_id, active_id_list, initial_record_by_id
		)

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

	# WAR は当該シーズン累積を使う。まず一軍だけ評価し、降格候補が生じたときだけ
	# 昇格可能な二軍候補を追加評価する。
	var ctx: Dictionary = war_ctx if not war_ctx.is_empty() else WarCalculator.build_league_context(
		season.year, season.season_number
	)
	var score_by_id: Dictionary = {}
	_populate_swap_scores(season, active_records, ctx, score_by_id)

	# 自動生成ローテの序列を最新の成績評価で組み替える (入替の有無に関わらず毎回)。
	# 不振の先発が下位へ落ちて登板数が減り、好調な投手が上位の登板日を取る。
	PSRotationPlanner.reorder_auto_rotation(
		season, team_id, _active_starter_records(active_records), score_by_id
	)

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
	var appearance_baselines: Dictionary = season.get_callup_appearance_baselines(team_id)
	for record_row in active_records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var baseline_key: String = str(record.player_id)
		if appearance_baselines.has(baseline_key) \
				and _first_team_appearances(record) <= int(appearance_baselines[baseline_key]):
			continue
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
		# 育成選手は一軍へ昇格できない (支配下登録が必要)。
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
	_populate_swap_scores(season, promote_pool, ctx, score_by_id)

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
	_record_callup_appearance_baselines(season, team_id, _promoted_ids_from_pairs(applied_pairs), record_by_id)
	var demoted_ids: Array = []
	for pair_row in applied_pairs:
		var pair: Dictionary = pair_row as Dictionary
		var down_id: int = int(pair["down"])
		var up_id: int = int(pair["up"])
		demoted_ids.append(down_id)
		var down_record: PSPlayerSeasonRecord = record_by_id.get(down_id, null) as PSPlayerSeasonRecord
		var up_record: PSPlayerSeasonRecord = record_by_id.get(up_id, null) as PSPlayerSeasonRecord
		if _is_starting_pitcher(down_record) and _is_starting_pitcher(up_record):
			_replace_rotation_pitcher(season, team_id, down_id, up_id)
	season.record_demotions(team_id, demoted_ids, current_day)

	# (7) 月別差分用のスナップショットを保存
	_append_snapshots(season, all_records, current_day)

	summary["swapped_pairs"] = applied_pairs
	return summary


static func _promoted_ids_from_pairs(pairs: Array) -> Array:
	var ids: Array = []
	for pair_row in pairs:
		ids.append(int((pair_row as Dictionary).get("up", 0)))
	return ids


static func _record_callup_appearance_baselines(
	season: PSSeason,
	team_id: int,
	player_ids: Array,
	record_by_id: Dictionary
) -> void:
	for id_value in player_ids:
		var player_id: int = int(id_value)
		var record: PSPlayerSeasonRecord = record_by_id.get(player_id, null) as PSPlayerSeasonRecord
		if record == null:
			continue
		var appearances: int = (
			record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games
		)
		season.record_callup_appearance_baseline(team_id, player_id, appearances)


static func _populate_swap_scores(
	season: PSSeason,
	records: Array,
	war_ctx: Dictionary,
	score_by_id: Dictionary
) -> void:
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or score_by_id.has(record.player_id):
			continue
		var monthly: Dictionary = season.get_monthly_stats(
			record.player_id, record.batter_stats, record.pitcher_stats
		)
		var monthly_batter: PSBatterStats = monthly.get("batter") as PSBatterStats
		var monthly_pitcher: PSPitcherStats = monthly.get("pitcher") as PSPitcherStats
		var war_row: Dictionary = WarCalculator.season_war(record, war_ctx)
		var war_value: float = float(war_row.get("war", 0.0))
		score_by_id[record.player_id] = perf_score(
			record,
			monthly_batter,
			monthly_pitcher,
			war_value
		)


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
