extends RefCounted
class_name PSDefenseAlignmentService

# 守備配置テンプレートから当日の先発守備を決めるサービス。
# 保存済みのポジション別デプスチャート (candidates + 出場シェア) を優先し、
# 欠員や重複があればポジション順に最適候補を補充する。
# 不在判定は injury_days > 0 のみ。疲労は候補除外ではなくスコア減点として扱う。
# 初回などテンプレートが空のときは、健康な野手から greedy に標準配置を作って profile へ保存する。
#
# 守備実績による自動降格: AI 管理チーム (usage.ai_generated) では、守備負荷の高い位置
# (C/2B/SS/CF) でシーズン実績 OAA が崩壊した選手は starter/テンプレ/バックアップの固定を
# 無視して貪欲補充に落とす (現実のコンバート/スタメン剥奪に相当)。ユーザーが打順設定画面で
# 保存した usage には ai_generated が付かないため、手動配置は上書きしない。
#
# プラトーン起用: AI 管理チームでは、相手先発の利き腕 (opponent_hand) に対して相性の良い候補が
# 同じ枠に居て、評価差が PSPlatoonMatchup.RATING_BONUS 以内なら、その日の担当を入れ替える。
# 出場シェアが決める「何試合出るか」はそのままに、「どの試合で出るか」だけを相性で寄せる。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

# GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER と同一: 捕手 → 遊撃 → 中堅 → 二塁 → 三塁 → 一塁 → 左翼 → 右翼
const POSITIONS: Array[int] = [2, 6, 8, 4, 5, 3, 7, 9]

# --- 出場シェア (ポジション別デプスチャート) ---
# position_slots[str(pos)] = {
#     "candidates": [{"player_id": int, "share": float}, ...],  # share 降順・合計 1.0
#     "backup_ids": [int, ...],                                 # 補充優先リスト (ユーザー設定)
# }
# candidates[0] が定位置で、share は「その守備位置の先発をどれだけ取るか」。
# share の決め方 (リーグ相対) は PSTeamSetupBuilder 側、ここは「当日誰が出るか」への落とし込み。
# candidates を持たない usage は未設定として扱い、AI 既定生成へ落ちる
# ([[project_qualified_batter_count]])。


# batting_memo: 呼び出し元が同じ試合内で複数回この関数を通すとき (検証 → AI既定生成 → 本番) に
# 打撃スコアを共有するための memo。同一試合中は成績も疲労も動かないので、渡しても値は変わらない。
# 空を渡す/省略すると関数内で作る (UI プレビュー等の単発呼び出し)。
static func assign_defensive_starters(
	available_fielders: Array,
	profile: PSDefenseAlignmentProfile,
	usage_settings: Dictionary = {},
	next_game_number: int = 1,
	batting_memo: Dictionary = {},
	opponent_hand: String = ""
) -> Array:
	if available_fielders.is_empty() or profile == null:
		return []

	# player_id 参照用の索引と、当日出場可能な健康野手リストを作る。
	var record_by_id: Dictionary = {}
	var healthy: Array = []
	for row in available_fielders:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null:
			continue
		record_by_id[rec.player_id] = rec
		if rec.injury_days <= 0:
			healthy.append(rec)

	if healthy.size() < POSITIONS.size():
		return []

	var batting_cache: Dictionary = batting_memo

	# 保存テンプレートがまだ無いチームは、現在の健康野手から初期テンプレートを自動生成する。
	var template: Dictionary = profile.starting_positions.duplicate()
	if template.is_empty():
		template = _generate_greedy_template(healthy, batting_cache)
		profile.starting_positions = template.duplicate()

	# 守備負荷の高い順に、デプスチャート・補充候補を解決していく。
	var assignments: Array = []
	var used_ids: Dictionary = {}
	# AI 管理チームだけ、実績崩壊選手の固定 (候補列/テンプレ/バックアップ) を外す。
	var ai_managed: bool = bool(usage_settings.get("ai_generated", false))

	for position_row in POSITIONS:
		var position: int = int(position_row)
		var chosen: PSPlayerSeasonRecord = null
		var slot_settings: Dictionary = _position_slot_settings(profile, usage_settings, position)
		# 出場シェアで決まる当日の担当 → 使えなければ同じ枠の残り候補 (定位置・併用者) の順。
		var candidate_ids: Array = ordered_candidate_ids_for_game(slot_settings, next_game_number)
		if ai_managed:
			candidate_ids = _platoon_ordered_candidate_ids(
				candidate_ids, record_by_id, used_ids, position, opponent_hand, batting_cache
			)
		var starter_id: int = slot_starter_id(slot_settings)
		for candidate_index in range(candidate_ids.size()):
			chosen = _configured_record_by_id(
				record_by_id, used_ids, int(candidate_ids[candidate_index]), position, ai_managed
			)
			if chosen == null:
				continue
			# 休養日の定位置選手は他の守備位置や DH へ回さない (「今日は休み」を守る)。
			if starter_id > 0 and starter_id != chosen.player_id:
				used_ids[starter_id] = true
			break

		# a. template の指定選手 (健康かつ未使用)
		var tmpl_id: int = int(template.get(position, template.get(str(position), 0)))
		if chosen == null and tmpl_id > 0 and record_by_id.has(tmpl_id) and not used_ids.has(tmpl_id):
			var tmpl_rec: PSPlayerSeasonRecord = record_by_id[tmpl_id] as PSPlayerSeasonRecord
			if tmpl_rec.injury_days <= 0 and _can_play_position(tmpl_rec, position) \
					and not (ai_managed and PlayerValueEvaluator.fielding_collapsed_at_position(tmpl_rec, position)):
				chosen = tmpl_rec

		# b. 補充優先順。ユーザが「控え」画面で設定した backup_ids (usage 経由) を最優先し、
		# 無ければチーム既定の profile.backup_priority に落とす。
		var backups: Array = (slot_settings.get("backup_ids", []) as Array)
		if backups.is_empty():
			if profile.backup_priority.has(position):
				backups = profile.backup_priority[position] as Array
			elif profile.backup_priority.has(str(position)):
				backups = profile.backup_priority[str(position)] as Array
		if chosen == null and not backups.is_empty():
			for backup_id_row in backups:
				var backup_id: int = int(backup_id_row)
				if record_by_id.has(backup_id) and not used_ids.has(backup_id):
					var b_rec: PSPlayerSeasonRecord = record_by_id[backup_id] as PSPlayerSeasonRecord
					if b_rec.injury_days <= 0 and _can_play_position(b_rec, position) \
							and not (ai_managed and PlayerValueEvaluator.fielding_collapsed_at_position(b_rec, position)):
						chosen = b_rec
						break

		# c. 残候補から starter_assignment_score 最高値で貪欲補充
		# (打撃/守備の position 別ブレンド。純守備版は defensive_assignment_score を参照)
		if chosen == null:
			chosen = _best_remaining_for_position(healthy, used_ids, position, true, batting_cache, ai_managed)

		# d. 守備不能 (適性保持者が 1 人も残っていない) のときだけ、任意の健康・未使用選手を
		# その守備位置に就ける。ただしポジション適性は 1 として扱う (record snapshot を 1 に
		# 設定 = defensive_score_for_position で適性ギャップ最大級のペナルティ)。
		if chosen == null:
			chosen = _emergency_fill_position(healthy, used_ids, position, batting_cache)

		if chosen == null:
			return []  # 健康な野手が 8 人未満のときのみ到達 (上で early return 済)。

		assignments.append({"record": chosen, "position": position})
		used_ids[chosen.player_id] = true

	return assignments


# その日の担当 (candidate_ids[0]) が相手先発と相性が悪いとき、同じ枠の相性の良い候補へ入れ替える。
# 入れ替えるのは評価差が RATING_BONUS 以内のときだけなので、控えより明確に優れた定位置選手は
# 相性に関係なく出続ける (= 併用枠だけがプラトーンになる)。
static func _platoon_ordered_candidate_ids(
	candidate_ids: Array,
	record_by_id: Dictionary,
	used_ids: Dictionary,
	position: int,
	opponent_hand: String,
	batting_cache: Dictionary
) -> Array:
	if opponent_hand.is_empty() or candidate_ids.size() < 2:
		return candidate_ids
	var due: PSPlayerSeasonRecord = _configured_record_by_id(
		record_by_id, used_ids, int(candidate_ids[0]), position, true
	)
	if due == null or PSPlatoonMatchup.has_advantage(due.batting_side, opponent_hand):
		return candidate_ids
	var due_score: int = _platoon_candidate_score(due, position, batting_cache)
	var best_index: int = -1
	var best_score: int = 0
	for index in range(1, candidate_ids.size()):
		var candidate: PSPlayerSeasonRecord = _configured_record_by_id(
			record_by_id, used_ids, int(candidate_ids[index]), position, true
		)
		if candidate == null or not PSPlatoonMatchup.has_advantage(candidate.batting_side, opponent_hand):
			continue
		var score: int = _platoon_candidate_score(candidate, position, batting_cache)
		if float(score) + PSPlatoonMatchup.RATING_BONUS <= float(due_score):
			continue
		if best_index < 0 or score > best_score:
			best_index = index
			best_score = score
	if best_index < 0:
		return candidate_ids
	var reordered: Array = candidate_ids.duplicate()
	var promoted: Variant = reordered[best_index]
	reordered.remove_at(best_index)
	reordered.insert(0, promoted)
	return reordered


static func _platoon_candidate_score(
	record: PSPlayerSeasonRecord, position: int, batting_cache: Dictionary
) -> int:
	return PlayerValueEvaluator.starter_assignment_score(
		record, position, true, _cached_batting_score(record, batting_cache)
	)


# 守備不能時の緊急起用。健康・未使用の中で打撃最良の選手を選び、その守備位置の適性を
# 1 として扱う (snapshot を 1 に上書き)。適性 0 は各所のゲートで弾かれるため 1 にする。
static func _emergency_fill_position(healthy: Array, used_ids: Dictionary, position: int, batting_cache: Dictionary) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = _best_unused_healthy(healthy, used_ids, batting_cache)
	if rec == null:
		return null
	_force_emergency_aptitude(rec, position)
	return rec


# 未使用の健康な選手のうち打撃が最も高い者 (緊急起用でも攻撃力を活かす)。
static func _best_unused_healthy(healthy: Array, used_ids: Dictionary, batting_cache: Dictionary) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_bat: int = -2147483647
	for row in healthy:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null or used_ids.has(rec.player_id):
			continue
		var bat: int = _cached_batting_score(rec, batting_cache)
		if best == null or bat > best_bat:
			best = rec
			best_bat = bat
	return best


# record の守備位置 position の適性を最低 1 にする。snapshot が空 (本職 100 暗黙) の場合は
# 本職 100 を明示化してから上書きし、本職適性を失わないようにする。
static func _force_emergency_aptitude(record: PSPlayerSeasonRecord, position: int) -> void:
	if record == null or position < 2 or position > 9:
		return
	var key: String = str(PlayerValueEvaluator.POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return
	var snapshot: Dictionary = record.position_aptitudes_snapshot
	if snapshot.is_empty():
		for p in range(2, 10):
			var p_key: String = str(PlayerValueEvaluator.POSITION_APTITUDE_KEYS.get(p, ""))
			if not p_key.is_empty():
				snapshot[p_key] = 100 if record.position == p else 0
	if int(snapshot.get(key, 0)) < 1:
		snapshot[key] = 1


# --- 内部ヘルパー ---

static func _generate_greedy_template(healthy: Array, batting_cache: Dictionary = {}) -> Dictionary:
	# 初回起動時のみ走る。POSITIONS の希少順 (捕手・遊撃を先) に最適選手を貪欲確保。
	var template: Dictionary = {}
	var used_ids: Dictionary = {}
	for position_row in POSITIONS:
		var position: int = int(position_row)
		var chosen: PSPlayerSeasonRecord = _best_remaining_for_position(healthy, used_ids, position, true, batting_cache)
		if chosen != null:
			template[position] = chosen.player_id
			used_ids[chosen.player_id] = true
	return template


static func _best_remaining_for_position(
	healthy: Array,
	used_ids: Dictionary,
	position: int,
	require_aptitude: bool,
	batting_cache: Dictionary = {},
	block_collapsed: bool = false
) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: int = -2147483647
	for row in healthy:
		var rec: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if rec == null or used_ids.has(rec.player_id):
			continue
		if not _can_play_position(rec, position):
			continue
		if block_collapsed and PlayerValueEvaluator.fielding_collapsed_at_position(rec, position):
			continue
		var bat_override: int = _cached_batting_score(rec, batting_cache)
		var score: int = PlayerValueEvaluator.starter_assignment_score(rec, position, require_aptitude, bat_override)
		if score <= PlayerValueEvaluator.ZERO_APTITUDE_SCORE:
			continue
		if best == null or score > best_score:
			best = rec
			best_score = score
	return best


static func _cached_batting_score(
	record: PSPlayerSeasonRecord,
	batting_cache: Dictionary
) -> int:
	if record == null:
		return 0
	if not batting_cache.has(record.player_id):
		batting_cache[record.player_id] = PlayerValueEvaluator.batting_score_with_form(record)
	return int(batting_cache[record.player_id])


static func _position_slot_settings(profile: PSDefenseAlignmentProfile, usage_settings: Dictionary, position: int) -> Dictionary:
	var profile_slots: Dictionary = {}
	if profile != null:
		profile_slots = profile.position_slots
	var usage_slots: Dictionary = usage_settings.get("position_slots", {}) as Dictionary
	var key: String = str(position)
	if usage_slots.has(key):
		return (usage_slots.get(key, {}) as Dictionary).duplicate(true)
	if usage_slots.has(position):
		return (usage_slots.get(position, {}) as Dictionary).duplicate(true)
	if profile_slots.has(key):
		return (profile_slots.get(key, {}) as Dictionary).duplicate(true)
	if profile_slots.has(position):
		return (profile_slots.get(position, {}) as Dictionary).duplicate(true)
	return {}


# --- 出場シェアのヘルパー (書き手は PSTeamSetupBuilder / 打順設定画面) ---

static func slot_candidates(slot_settings: Dictionary) -> Array:
	return slot_settings.get("candidates", []) as Array


# 定位置 = candidates[0]。休養日の判定 (誰が「今日は休み」か) はこの id を基準にする。
static func slot_starter_id(slot_settings: Dictionary) -> int:
	var candidates: Array = slot_candidates(slot_settings)
	if candidates.is_empty():
		return 0
	return int((candidates[0] as Dictionary).get("player_id", 0))


# candidates から slot を組む。player_id <= 0 と重複は落とす。
# 併用相手が居る (2 人以上) 枠だけ share 降順・合計 1.0 へ正規化する。
# 1 人だけの枠は share をそのまま残す — 0.0 は「未設定 (AI が決める)」、1.0 は「全試合」、
# その中間は「相方を AI が埋める」を意味し、正規化するとこの区別が消えるため。
static func make_slot(
	candidates: Array, backup_ids: Array = [], share_locked: bool = false
) -> Dictionary:
	var cleaned: Array = []
	var total: float = 0.0
	var seen: Dictionary = {}
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value as Dictionary
		var player_id: int = int(candidate.get("player_id", 0))
		if player_id <= 0 or seen.has(player_id):
			continue
		seen[player_id] = true
		var share: float = clampf(float(candidate.get("share", 0.0)), 0.0, 1.0)
		cleaned.append({"player_id": player_id, "share": share})
		total += share
	if cleaned.size() >= 2 and total > 0.0:
		cleaned.sort_custom(func(a, b) -> bool:
			var share_a: float = float((a as Dictionary).get("share", 0.0))
			var share_b: float = float((b as Dictionary).get("share", 0.0))
			if is_equal_approx(share_a, share_b):
				return int((a as Dictionary).get("player_id", 0)) < int((b as Dictionary).get("player_id", 0))
			return share_a > share_b
		)
		for candidate_value in cleaned:
			var candidate: Dictionary = candidate_value as Dictionary
			candidate["share"] = float(candidate["share"]) / total
	return {
		"candidates": cleaned,
		"backup_ids": backup_ids.duplicate(),
		"share_locked": share_locked,
	}


# candidates[0] のシェア。0.0 は「未設定」= AI 既定生成でシェアを決めさせる印。
static func slot_starter_share(slot_settings: Dictionary) -> float:
	var candidates: Array = slot_candidates(slot_settings)
	if candidates.is_empty():
		return 0.0
	return float((candidates[0] as Dictionary).get("share", 0.0))


# ユーザーが打順設定画面で明示指定したシェアか。true の枠は定期組み直しでも測り直さない
# (指定が 14 試合ごとに AI の値へ戻ると「設定したのに効かない」になるため)。
static func slot_share_locked(slot_settings: Dictionary) -> bool:
	return bool(slot_settings.get("share_locked", false))


# 当日の担当を先頭に、残りの候補を続けた player_id の並び。
# 担当が故障などで使えないとき、呼び出し側はこの順に降りていく。
static func ordered_candidate_ids_for_game(slot_settings: Dictionary, next_game_number: int) -> Array:
	var candidates: Array = slot_candidates(slot_settings)
	if candidates.is_empty():
		return []
	# シェアが未設定 (合計 0) の枠は定位置選手がそのまま出る。AI 既定生成が入るまでの過渡状態で、
	# `select_defensive_starters_with_usage` による評価呼び出しがここを通る。
	var shares: Array = []
	var total: float = 0.0
	for candidate_value in candidates:
		var share: float = float((candidate_value as Dictionary).get("share", 0.0))
		shares.append(share)
		total += share
	if total <= 0.0:
		shares[0] = 1.0
		total = 1.0
	for index in range(shares.size()):
		shares[index] = float(shares[index]) / total
	var due: int = share_index_for_game(shares, next_game_number)
	var ids: Array = [int((candidates[due] as Dictionary).get("player_id", 0))]
	for index in range(candidates.size()):
		if index == due:
			continue
		ids.append(int((candidates[index] as Dictionary).get("player_id", 0)))
	return ids


# 出場シェアを「試合 g の担当」へ落とす。目標消化 (share×g) と実消化の差が最大の候補を
# 選ぶ最大剰余法で、シェアどおりの試合数になりつつ休養日が均等に散る。
#
# 候補 2 人なら閉じた形になる: 貪欲則を展開すると「定位置の消化数 a(g) = floor(share×g + 0.5)」
# (Webster 丸め) と一致するので、g を回さずに O(1) で解ける。3 人以上は素直に回す
# (AI 既定生成は 2 人までなので、ここへ来るのはユーザーが手で 3 人以上を設定した枠だけ)。
static func share_index_for_game(shares: Array, next_game_number: int) -> int:
	if shares.size() <= 1 or next_game_number <= 0:
		return 0
	if shares.size() == 2:
		var share: float = float(shares[0])
		var before: int = int(floor(share * float(next_game_number - 1) + 0.5))
		var now: int = int(floor(share * float(next_game_number) + 0.5))
		return 0 if now > before else 1
	var counts: PackedInt32Array = PackedInt32Array()
	counts.resize(shares.size())
	var picked: int = 0
	for game_number in range(1, next_game_number + 1):
		var best: int = 0
		var best_debt: float = -INF
		for index in range(shares.size()):
			var debt: float = float(shares[index]) * float(game_number) - float(counts[index])
			if debt > best_debt:
				best_debt = debt
				best = index
		counts[best] += 1
		picked = best
	return picked


static func _configured_record_by_id(
	record_by_id: Dictionary,
	used_ids: Dictionary,
	player_id: int,
	position: int,
	block_collapsed: bool = false
) -> PSPlayerSeasonRecord:
	if player_id <= 0 or used_ids.has(player_id) or not record_by_id.has(player_id):
		return null
	var record: PSPlayerSeasonRecord = record_by_id[player_id] as PSPlayerSeasonRecord
	if record == null or record.injury_days > 0:
		return null
	if not _can_play_position(record, position):
		return null
	if block_collapsed and PlayerValueEvaluator.fielding_collapsed_at_position(record, position):
		return null
	return record


static func _can_play_position(record: PSPlayerSeasonRecord, position: int) -> bool:
	if record == null or position < 2 or position > 9:
		return false
	return PlayerValueEvaluator.position_aptitude(record, position) > 0
