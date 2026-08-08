extends RefCounted
class_name PSBattingOrderService

# 打順は「打順ごとに求める打者像 (SLOT_PROFILES)」への貪欲マッチングで組む。
# 基本打順を作る build_base_order と、試合ごとに基本打順を微調整する build_daily_batting_order の
# 2 経路があり、どちらも同じ SLOT_PROFILES / 打者指標を使うので役割の解釈がズレない。
# 日替わりの揺れは疲労減点と (day, team, player) シードの乱数ボーナスだけで、能力の序列は保たれる。
#
# 打者の評価には **監督が見られる情報だけ**を使う: 表示能力 (PSPlayerVisibleRatings, 1-100) と
# 今季・過去シーズンの打撃成績。raw z は直接参照しない (詳細は「打者指標」節)。

const SIGMA_SCALE: float = 10.0  # σ → int スコア換算。疲労減点/乱数ボーナスのノブが int 単位のため
const CATCHER_POSITION: int = 2
const DH_POSITION: int = 10

# 打順を埋める順序。重要な打順ほど先に取るので、実質 4番→3番→5番→1番→2番→下位打線 の優先度。
const SLOT_FILL_PRIORITY: Array[int] = [4, 3, 5, 1, 2, 6, 7, 8, 9]

# 基本打順を組み直すチーム試合数の間隔 (0 で無効)。短くするほど今季成績が打順へ速く反映され、
# 打順の入れ替わりも増える。間隔の合間はグループ内の並べ替えだけが動く。
const BASE_REBUILD_INTERVAL_GAMES: int = 10

# 捕手を上位打順に置きにくくする減点 (σ 単位)。上げるほど捕手が 1・2 番から遠ざかる。
# 1.5 は「打力が他の候補より 1.5σ (表示能力で 9-11) 以上優れた捕手だけが上位に来る」水準で、
# 12 球団の自動編成で捕手が 1・2 番に入るのは 0-1 球団に収まる。
const CATCHER_TOP_SLOT_PENALTY: float = 1.5
const CATCHER_TOP_SLOTS: Array[int] = [1, 2]

# 各打順が求める打者像。値は打者指標への重みで、同一打順内での候補比較にのみ使う。
# on_base=出塁、contact=当てる技術、power=長打、speed=機動力、total=打者としての総合力。
const SLOT_PROFILES: Dictionary = {
	1: {"on_base": 1.00, "contact": 0.55, "power": 0.05, "speed": 0.85, "total": 0.30},
	2: {"on_base": 0.70, "contact": 0.85, "power": 0.10, "speed": 0.55, "total": 0.35},
	3: {"on_base": 0.35, "contact": 0.75, "power": 0.60, "speed": 0.15, "total": 0.90},
	4: {"on_base": 0.15, "contact": 0.25, "power": 1.60, "speed": 0.00, "total": 0.60},
	5: {"on_base": 0.15, "contact": 0.30, "power": 0.95, "speed": 0.05, "total": 0.65},
	6: {"on_base": 0.20, "contact": 0.40, "power": 0.40, "speed": 0.15, "total": 0.60},
	7: {"on_base": 0.20, "contact": 0.40, "power": 0.40, "speed": 0.15, "total": 0.60},
	8: {"on_base": 0.20, "contact": 0.40, "power": 0.40, "speed": 0.15, "total": 0.60},
	9: {"on_base": 0.35, "contact": 0.30, "power": 0.10, "speed": 0.35, "total": 0.30},
}

# --- 打者指標 (SLOT_PROFILES の入力) の作り方 ---
#
# 5 指標それぞれを「表示能力から作った値」と「成績から作った値」の信頼度加重平均にする:
#   index = (ability * ABILITY_PRIOR_WEIGHT + Σ_k stat_k * w_k) / (ABILITY_PRIOR_WEIGHT + Σ_k w_k)
#   w_k   = PAST_SEASON_DECAY^k * pa_k / (pa_k + PA_RELIABILITY_ANCHOR)   (k=0 が今季)
# 打席が無ければ w=0 なので、開幕直後や新人は表示能力そのもの。今季 pa が増えるほど w_0 が上がって
# 今季成績の比重が徐々に増し、過去シーズンは古いほど PAST_SEASON_DECAY で軽くなる。
# 走力 (speed) だけは成績に素直に現れないため表示能力のみ。
#
# ability を下げると成績追随が速くなり、上げると能力どおりの打順を維持しやすくなる。
const ABILITY_PRIOR_WEIGHT: float = 1.0
# 成績の信頼度が 0.5 になる打席数。小さくすると少ない打席でも成績を信用する。
const PA_RELIABILITY_ANCHOR: float = 200.0
# 1 年古くなるごとに掛かる係数と、遡る年数。
const PAST_SEASON_DECAY: float = 0.5
const PAST_SEASON_LOOKBACK: int = 3

# 表示能力と成績を同じ σ スケールへ載せる基準分布は `PSBattingReference` がその時点の母集団から
# 実測する。固定値を置かないので、バランス較正や長期セーブのリーグ環境ドリフトで基準が古びない。

# total (打者総合) を表示能力側から作るときの内訳。
const TOTAL_ABILITY_WEIGHTS: Dictionary = {
	"contact": 0.34,
	"power": 0.34,
	"on_base": 0.22,
	"speed": 0.10,
}


# 打者記録の配列を打順順 (index 0 = 1番) に並べ替えて返す。投手は必ず最終打順。
# position_by_player_id は当日の守備位置 (player_id → position)。捕手判定に使い、
# 未指定の選手は登録ポジションで判定する。
static func build_base_order(
	entries: Array,
	profile: PSBattingOrderProfile = null,
	position_by_player_id: Dictionary = {}
) -> Array:
	if entries.size() <= 1:
		return entries.duplicate()
	var evaluation: Dictionary = build_evaluation(entries, profile, position_by_player_id)
	return _base_order_from_evaluation(entries, evaluation)


static func _base_order_from_evaluation(entries: Array, evaluation: Dictionary) -> Array:
	var batters: Array = []
	var pitchers: Array = []
	for entry_row in entries:
		var record: PSPlayerSeasonRecord = entry_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher():
			pitchers.append(record)
		else:
			batters.append(record)

	var total_slots: int = batters.size() + pitchers.size()
	var batter_slots: Array[int] = []
	for slot in range(1, batters.size() + 1):
		batter_slots.append(slot)

	var assigned: Dictionary = _assign_slots(batters, batter_slots, {}, evaluation)

	var ordered: Array = []
	for slot in range(1, total_slots + 1):
		if assigned.has(slot):
			ordered.append(assigned[slot])
	for pitcher_row in pitchers:
		ordered.append(pitcher_row)
	return ordered


static func build_daily_batting_order(
	entries: Array,
	context: Dictionary,
	profile: PSBattingOrderProfile
) -> Array:
	if entries.is_empty():
		return entries.duplicate()

	var position_by_player_id: Dictionary = context.get("position_by_player_id", {}) as Dictionary
	# 打者指標は 1 試合につき 1 回だけ作り、base の組み直しとグループ内再割当で使い回す。
	var evaluation: Dictionary = build_evaluation(entries, profile, position_by_player_id)
	var order: Array = _copy_entries(entries, profile, evaluation, _base_refresh_due(context))
	_apply_forced_locks(order, profile)
	_reorder_group(order, profile.top_group, context, profile, evaluation)
	_reorder_group(order, profile.middle_group, context, profile, evaluation)
	_reorder_group(order, profile.lower_group, context, profile, evaluation)
	_enforce_final_constraints(order)

	var result: Array = []
	for slot_entry in order:
		result.append(slot_entry["record"])
	return result


# --- 打順割当のコア ---

# 打者の評価をまとめて作る。打順割当はここで作った指標だけを見る。
# 戻り値: {metrics: {player_id: 指標5種}, catchers: {player_id: true}, keep_catcher_lower: bool}
static func build_evaluation(
	entries: Array,
	profile: PSBattingOrderProfile,
	position_by_player_id: Dictionary
) -> Dictionary:
	var metrics_by_player_id: Dictionary = {}
	var catcher_ids: Dictionary = {}
	for entry_row in entries:
		var record: PSPlayerSeasonRecord = entry_row as PSPlayerSeasonRecord
		if record == null:
			continue
		metrics_by_player_id[record.player_id] = _metrics(record)
		if _is_catcher(record, position_by_player_id):
			catcher_ids[record.player_id] = true
	return {
		"metrics": metrics_by_player_id,
		"catchers": catcher_ids,
		"keep_catcher_lower": true if profile == null else profile.keep_catcher_lower,
	}


# candidates を slots へ 1 対 1 で割り当て、{slot: record} を返す。
# 各打順は SLOT_FILL_PRIORITY の順に「その打順のスコアが最大の残り候補」を取る。
# bonus_by_player_id は疲労・調子・日替わり乱数などの選手単位の加減点 (σ 単位、打順に依らない)。
static func _assign_slots(
	candidates: Array,
	slots: Array,
	bonus_by_player_id: Dictionary,
	evaluation: Dictionary
) -> Dictionary:
	var metrics_by_player_id: Dictionary = evaluation["metrics"] as Dictionary
	var catcher_ids: Dictionary = evaluation["catchers"] as Dictionary
	var keep_catcher_lower: bool = bool(evaluation["keep_catcher_lower"])

	var fill_order: Array[int] = []
	for slot in SLOT_FILL_PRIORITY:
		if slots.has(slot):
			fill_order.append(slot)
	# SLOT_PROFILES に無い打順 (9 人を超える異常系) は末尾で昇順に埋める。
	var leftovers: Array[int] = []
	for slot_value in slots:
		var slot_int: int = int(slot_value)
		if not fill_order.has(slot_int):
			leftovers.append(slot_int)
	leftovers.sort()
	fill_order.append_array(leftovers)

	var remaining: Array = candidates.duplicate()
	var assigned: Dictionary = {}
	for slot in fill_order:
		if remaining.is_empty():
			break
		var best_index: int = 0
		var best_score: float = -INF
		for i in range(remaining.size()):
			var record_i: PSPlayerSeasonRecord = remaining[i] as PSPlayerSeasonRecord
			var score: float = _slot_score(
				slot,
				metrics_by_player_id.get(record_i.player_id, {}) as Dictionary,
				catcher_ids.has(record_i.player_id) and keep_catcher_lower
			)
			score += float(bonus_by_player_id.get(record_i.player_id, 0.0))
			if score > best_score:
				best_score = score
				best_index = i
		assigned[slot] = remaining[best_index]
		remaining.remove_at(best_index)
	return assigned


static func _slot_score(slot: int, metrics: Dictionary, apply_catcher_penalty: bool) -> float:
	var slot_profile: Dictionary = SLOT_PROFILES.get(slot, SLOT_PROFILES[8]) as Dictionary
	var score: float = 0.0
	for key in slot_profile.keys():
		score += float(slot_profile[key]) * float(metrics.get(key, 0.0))
	if apply_catcher_penalty and CATCHER_TOP_SLOTS.has(slot):
		score -= CATCHER_TOP_SLOT_PENALTY
	return score


# 表示能力と成績をブレンドした打者指標 5 種 (すべて σ 単位)。
# 基準分布は選手が属するシーズンのものを使うので、リーグ環境が動いても位置付けがズレない。
static func _metrics(record: PSPlayerSeasonRecord) -> Dictionary:
	var season_reference: Dictionary = PSBattingReference.for_season(record.year, record.season_number)
	var ability: Dictionary = _ability_index(record, season_reference["ratings"] as Dictionary)
	var samples: Array = _stat_samples(record, season_reference["stats"] as Dictionary)
	return {
		"on_base": _blend(float(ability["on_base"]), samples, "on_base"),
		"contact": _blend(float(ability["contact"]), samples, "average"),
		"power": _blend(float(ability["power"]), samples, "isolated_power"),
		"speed": float(ability["speed"]),
		"total": _blend(float(ability["total"]), samples, "ops"),
	}


# 表示能力 (巧打/長打/走力/選球) を σ 単位の指標へ。total は 4 指標の重み付き和。
static func _ability_index(record: PSPlayerSeasonRecord, ratings_reference: Dictionary) -> Dictionary:
	var index: Dictionary = {
		"contact": _normalized(
			float(PSPlayerVisibleRatings.fielder_contact(record)), ratings_reference, "contact"
		),
		"power": _normalized(
			float(PSPlayerVisibleRatings.fielder_power(record)), ratings_reference, "power"
		),
		"speed": _normalized(
			float(PSPlayerVisibleRatings.fielder_speed(record)), ratings_reference, "speed"
		),
		"on_base": _normalized(
			float(PSPlayerVisibleRatings.fielder_discipline(record)), ratings_reference, "discipline"
		),
	}
	var total: float = 0.0
	for key in TOTAL_ABILITY_WEIGHTS.keys():
		total += float(TOTAL_ABILITY_WEIGHTS[key]) * float(index[key])
	index["total"] = total
	return index


static func _normalized(value: float, distributions: Dictionary, key: String) -> float:
	var distribution: Dictionary = distributions[key] as Dictionary
	return (value - float(distribution["mean"])) / float(distribution["spread"])


# 今季 + 直近 PAST_SEASON_LOOKBACK 年の打撃成績を、信頼度と古さで重み付けして返す。
# 過去シーズンは (year-k, season_number-k) で 1 件ずつ引き、**そのシーズンの基準分布**で正規化する
# (シーズンは年と同時に繰り上がる)。年ごとにリーグ環境が動いても成績の位置付けが保たれる。
static func _stat_samples(record: PSPlayerSeasonRecord, stat_reference: Dictionary) -> Array:
	var samples: Array = []
	_append_stat_sample(samples, record.batter_stats, 1.0, stat_reference)
	if record.year <= 0:
		return samples
	for k in range(1, PAST_SEASON_LOOKBACK + 1):
		var past_year: int = record.year - k
		var past_season_number: int = record.season_number - k
		var past: PSPlayerSeasonRecord = RecordStore.get_player_record(
			record.player_id, past_year, past_season_number
		)
		if past == null:
			continue
		var past_reference: Dictionary = PSBattingReference.for_season(past_year, past_season_number)
		_append_stat_sample(
			samples,
			past.batter_stats,
			pow(PAST_SEASON_DECAY, float(k)),
			past_reference["stats"] as Dictionary
		)
	return samples


static func _append_stat_sample(
	samples: Array, stats: PSBatterStats, decay: float, distributions: Dictionary
) -> void:
	if stats == null or stats.plate_appearances <= 0:
		return
	var plate_appearances: float = float(stats.plate_appearances)
	var weight: float = decay * plate_appearances / (plate_appearances + PA_RELIABILITY_ANCHOR)
	if weight <= 0.0:
		return
	var average: float = stats.batting_average()
	samples.append({
		"weight": weight,
		"average": _normalized(average, distributions, "average"),
		"on_base": _normalized(stats.on_base_percentage(), distributions, "on_base"),
		"isolated_power": _normalized(
			stats.slugging_percentage() - average, distributions, "isolated_power"
		),
		"ops": _normalized(stats.ops(), distributions, "ops"),
	})


static func _blend(ability_index: float, samples: Array, stat_key: String) -> float:
	var numerator: float = ability_index * ABILITY_PRIOR_WEIGHT
	var denominator: float = ABILITY_PRIOR_WEIGHT
	for sample_row in samples:
		var sample: Dictionary = sample_row as Dictionary
		var weight: float = float(sample["weight"])
		numerator += float(sample[stat_key]) * weight
		denominator += weight
	return numerator / denominator


static func _is_catcher(record: PSPlayerSeasonRecord, position_by_player_id: Dictionary) -> bool:
	# 当日の守備位置が分かればそちらを優先する (DH で出る捕手は上位打順の減点対象にしない)。
	return int(position_by_player_id.get(record.player_id, record.position)) == CATCHER_POSITION


# --- 内部ヘルパー ---

# BASE_REBUILD_INTERVAL_GAMES ごとに基本打順を作り直すタイミングか。
static func _base_refresh_due(context: Dictionary) -> bool:
	if BASE_REBUILD_INTERVAL_GAMES <= 0:
		return false
	var games_played: int = int(context.get("team_games_played", 0))
	return games_played > 0 and games_played % BASE_REBUILD_INTERVAL_GAMES == 0


static func _copy_entries(
	entries: Array,
	profile: PSBattingOrderProfile,
	evaluation: Dictionary,
	refresh_base: bool
) -> Array:
	var base_ids: Array[int] = profile.base_order_player_ids
	var missing_base: bool = base_ids.is_empty()

	# 組み直す条件は 3 つ: 基本打順がまだ無い / 当日の野手陣が base に載っていない (故障・休養・入替) /
	# 定期リフレッシュのタイミング。定期リフレッシュと初回だけ結果を base として保存し、
	# 顔ぶれ違いによる組み直しはメモリ上だけに留めるので、レギュラーが戻れば元の base に復帰する。
	if refresh_base or missing_base or not _base_covers_fielders(entries, base_ids):
		var rebuilt: Array = _base_order_from_evaluation(entries, evaluation)
		var fresh: Array = []
		for i in range(rebuilt.size()):
			fresh.append({"record": rebuilt[i], "slot": i + 1, "score": 0, "locked": false})
		if refresh_base or missing_base:
			var ids: Array[int] = []
			for record_row in rebuilt:
				ids.append((record_row as PSPlayerSeasonRecord).player_id)
			profile.base_order_player_ids = ids
		return fresh

	# base_order の player_id → slot マップで配置。base に無い選手 (投手) は空きスロット詰め。
	var copied: Array = []
	var slot_by_pid: Dictionary = {}
	for idx in range(base_ids.size()):
		slot_by_pid[base_ids[idx]] = idx + 1

	var assigned_slots: Dictionary = {}
	var unassigned: Array = []
	for entry_row in entries:
		var rec: PSPlayerSeasonRecord = entry_row as PSPlayerSeasonRecord
		if slot_by_pid.has(rec.player_id) and not assigned_slots.has(slot_by_pid[rec.player_id]):
			var slot: int = int(slot_by_pid[rec.player_id])
			copied.append({"record": rec, "slot": slot, "score": 0, "locked": false})
			assigned_slots[slot] = true
		else:
			unassigned.append(rec)

	var next_slot: int = 1
	for rec_row in unassigned:
		while assigned_slots.has(next_slot) and next_slot <= entries.size():
			next_slot += 1
		if next_slot > entries.size():
			break
		copied.append({"record": rec_row, "slot": next_slot, "score": 0, "locked": false})
		assigned_slots[next_slot] = true
		next_slot += 1

	return copied


# 当日の野手が全員 base_order に載っているか。投手は毎試合替わるうえ打順 9 番へ固定されるので除外する。
static func _base_covers_fielders(entries: Array, base_ids: Array[int]) -> bool:
	var base_lookup: Dictionary = {}
	for id_value in base_ids:
		base_lookup[int(id_value)] = true
	for entry_row in entries:
		var record: PSPlayerSeasonRecord = entry_row as PSPlayerSeasonRecord
		if record == null or record.is_pitcher():
			continue
		if not base_lookup.has(record.player_id):
			return false
	return true


static func _apply_forced_locks(order: Array, profile: PSBattingOrderProfile) -> void:
	# 投手は最終打順に固定 (DH OFF 時のみ entries に含まれる)
	for slot_entry in order:
		var rec: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
		if rec.is_pitcher():
			slot_entry["slot"] = order.size()
			slot_entry["locked"] = true

	# profile.fixed_slot_by_player に該当
	for slot_entry in order:
		var rec_p: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
		var key: String = str(rec_p.player_id)
		if profile.fixed_slot_by_player.has(key):
			slot_entry["slot"] = int(profile.fixed_slot_by_player[key])
			slot_entry["locked"] = true

	# keep_cleanup_fixed
	if profile.keep_cleanup_fixed:
		for slot_entry in order:
			if int(slot_entry["slot"]) == 4:
				slot_entry["locked"] = true


# グループ内の空き打順を、同グループの可動選手で組み直す。グループをまたぐ移動は起きないので
# 基本打順で決まった「上位/中軸/下位」の役割は保たれ、日々の入れ替えはグループ内に閉じる。
static func _reorder_group(
	order: Array,
	slots: Array[int],
	context: Dictionary,
	profile: PSBattingOrderProfile,
	evaluation: Dictionary
) -> void:
	var movable: Array = []
	var locked_slots: Dictionary = {}
	var bonus_by_player_id: Dictionary = {}
	for slot_entry in order:
		var slot: int = int(slot_entry["slot"])
		if not slots.has(slot):
			continue
		if bool(slot_entry["locked"]):
			locked_slots[slot] = true
			continue
		var rec: PSPlayerSeasonRecord = slot_entry["record"] as PSPlayerSeasonRecord
		var bonus: int = _condition_bonus(rec) - _fatigue_penalty(rec)
		if profile.allow_random_bonus:
			bonus += _seeded_random_bonus(context, rec.player_id, profile.random_bonus_range)
		bonus_by_player_id[rec.player_id] = float(bonus) / SIGMA_SCALE
		movable.append(slot_entry)

	if movable.is_empty():
		return

	var available: Array[int] = []
	for s in slots:
		if not locked_slots.has(s):
			available.append(s)
	available.sort()

	var candidates: Array = []
	for slot_entry in movable:
		candidates.append(slot_entry["record"])
	var assigned: Dictionary = _assign_slots(candidates, available, bonus_by_player_id, evaluation)

	for slot in assigned.keys():
		var record: PSPlayerSeasonRecord = assigned[slot] as PSPlayerSeasonRecord
		for slot_entry in movable:
			if (slot_entry["record"] as PSPlayerSeasonRecord).player_id == record.player_id:
				slot_entry["slot"] = int(slot)
				break


static func _condition_bonus(_record: PSPlayerSeasonRecord) -> int:
	# PSPlayerSeasonRecord に condition フィールドが無いため常に 0。
	# condition (-2..+2) を追加したらここで段階制 (±3, ±6) を返す。
	return 0


static func _fatigue_penalty(record: PSPlayerSeasonRecord) -> int:
	# 疲労による打順降格。内部 fatigue は 0-200 なので 0-100 へスケールしてから段階判定する。
	@warning_ignore("integer_division")
	var f: int = clampi(record.fatigue / 2, 0, 100)
	if f <= 30:
		return 0
	if f <= 60:
		return 3
	if f <= 80:
		return 8
	return 15


static func _seeded_random_bonus(context: Dictionary, player_id: int, range_max: int) -> int:
	# 同じ (day, team, player) で同じ値 → 再 sim 時の打順再現性を保証。
	var rng := RandomNumberGenerator.new()
	var game_day: int = int(context.get("game_day", 0))
	var team_id: int = int(context.get("team_id", 0))
	rng.seed = hash("%d_%d_%d" % [game_day, team_id, player_id])
	return rng.randi_range(-range_max, range_max)


static func _enforce_final_constraints(order: Array) -> void:
	_resolve_duplicate_slots(order)
	_sort_by_slot(order)


static func _resolve_duplicate_slots(order: Array) -> void:
	var by_slot: Dictionary = {}
	var duplicates: Array = []
	for slot_entry in order:
		var slot: int = int(slot_entry["slot"])
		if not by_slot.has(slot):
			by_slot[slot] = slot_entry
		else:
			# locked 優先、movable は空きへ
			if bool(slot_entry["locked"]):
				duplicates.append(by_slot[slot])
				by_slot[slot] = slot_entry
			else:
				duplicates.append(slot_entry)

	var max_slot: int = order.size()
	var empties: Array[int] = []
	for s in range(1, max_slot + 1):
		if not by_slot.has(s):
			empties.append(s)

	for i in range(min(duplicates.size(), empties.size())):
		duplicates[i]["slot"] = empties[i]
		by_slot[empties[i]] = duplicates[i]


static func _sort_by_slot(order: Array) -> void:
	order.sort_custom(func(a, b) -> bool:
		return int(a["slot"]) < int(b["slot"])
	)
