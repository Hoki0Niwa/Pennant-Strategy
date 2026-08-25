extends RefCounted
class_name GenekiDraftService

# 現役ドラフト (NPB 2022年導入・2024年改定ルール準拠)。オフシーズンの geneki_draft ステップ
# (戦力外獲得の後・FA市場の前) で実行する。
#
# ルールの骨子 (2024年改定):
# - 各球団は対象選手を2人以上リストアップする。対象は 支配下・非外国人・年俸5000万未満
#   (1人だけ5000万以上1億未満を含められるが、その場合5000万未満を追加し3人以上)。
#   FA権保有/行使経験者・複数年契約中・当年ドラフト新人・当年トレード獲得選手は対象外。
# - 1巡目: 各球団が欲しい選手1人に投票し、自球団リスト選手の得票数が最多の球団から指名開始。
#   指名された選手の所属球団に指名権が移るチェーン方式。各球団の獲得は必ず1人・放出も必ず1人
#   (= 既に放出済みの球団の選手は指名できないため、同一球団から1巡目に2人指名されることはない)。
#   チェーンが閉じたら (指名権が指名済み球団へ移ったら) 未指名球団の得票数上位から再開。
# - 2巡目: 参加任意。指名して参加 / 放出のみ参加 (2025年改定) / 不参加 を選び、
#   1巡目の指名順の逆順で指名する。不参加球団の選手は指名対象外。棄権可。
# - 金銭のやり取りはなく、年俸は据え置きで移籍する。
#
# state はセーブ互換のため JSON-safe (Dictionary/Array/int/float/String/bool) のみで構成する。
# phase: "submit" (ユーザーのリスト編集) → "round1" → "round2_entry" (ユーザーの参加形態選択)
#        → "round2" → "done" (complete=true)。移籍の実適用は finalize_geneki_draft で行う。

const STATE_VERSION: int = 1

const LIST_MIN: int = 2
# 年俸境界 (万円)。5000万未満が通常対象、5000万以上1億未満は例外枠1人まで。
const SALARY_STANDARD_MAX: int = 5000
const SALARY_EXCEPTION_MAX: int = 10000
const LIST_MIN_WITH_EXCEPTION: int = 3
# CPUのリスト人数 (最低限のみ提出。例外枠は eligible 不足時のフォールバックでしか使わない)。
const CPU_LIST_SIZE: int = 2

# --- リスト選定 (放出候補) の基準 ---
# NPB現役ドラフトで実際に晒され移籍するのは「能力はあるが出場機会に恵まれない中堅」(元上位指名の
# 伸び悩み投手・飼い殺しの野手など)で、実績は投手偏重(移籍 投:野 = 2022年7:5 / 2023年9:3 / 2024年9:4)。
# よってリストは surplus(枠余り)ではなく、**素の能力が高く出場が少ない(=blocked)若手中堅**を優先して晒す。
# 「一軍戦力」(規定近くの出場)と「主力級能力」は保護(晒さない)。指名側は伸びしろ(future_value)で評価する
# ため、新天地で開花する blocked talent が指名されやすくなる。
const EXPOSE_REGULAR_PITCHER_APP: int = 20    # 登板がこの水準なら一軍戦力=保護
const EXPOSE_REGULAR_BATTER_GAMES: int = 80   # 出場がこの水準なら一軍戦力=保護
const EXPOSE_REGULAR_RATIO: float = 0.75      # 出場率がこれ以上なら「主力」として保護ペナルティ
const EXPOSE_PROTECT_PERCENTILE: float = 0.85 # 役割内でこの percentile 以上 (上位15%) は主力として保護
const EXPOSE_BLOCKED_WEIGHT: float = 0.6      # 出場が少ないほど appeal を増やす係数
# 年齢係数: NPB現役ドラフトの対象は「数年やって伸び悩んだ中堅」。23歳以下の素材型は各球団が育成のため
# 抱えるので晒しにくく(保護)、24〜30歳を全開、31歳以降は伸びしろ減で逓減。若い順に晒す加点は不可
# (それだと19〜22歳の素材ばかり晒され非現実的な年齢分布になる)。
const EXPOSE_PRIME_MIN: int = 24
const EXPOSE_PRIME_MAX: int = 30
const EXPOSE_PROSPECT_FLOOR: float = 0.35     # 21歳以下の appeal 係数 (素材型を強く保護)
const EXPOSE_OLD_DECAY: float = 0.06          # 31歳以降 1歳ごとの逓減
const EXPOSE_OLD_FLOOR: float = 0.3
const EXPOSE_REGULAR_PENALTY: float = 0.25    # 主力(高出場)を晒し順位で大きく下げる
const EXPOSE_STAR_PENALTY: float = 0.25       # 主力級能力を晒し順位で大きく下げる
# 投手 appeal 補正。役割内 percentile で投打を対称にした上で NPB 実績の投手偏重 (移籍 ~67%) に寄せる。
# 感度が高い (実測 記録なし露出: 1.00→29%投手 / 1.05→46% / 1.10→71% / 1.20→88%)。1.10 で記録なし71%・
# 記録あり83% と、記録の有無に依らず投手偏重を保つ。投手が多すぎるなら下げ、野手が多いなら上げる主ノブ。
const EXPOSE_PITCHER_BIAS: float = 1.1

# 投票/指名スコア = 能力 value(player_value_score) + ノイズ。ポジション需要も投手 parity も足さない。
# 素の value+ノイズ指名なら、自軍獲得は多seed平均で投手~59% (NPB 58〜75% 帯) の投打ミックスになる。
# ここに投手 parity を足すと全球団が毎年ほぼ投手 (~92%) に振れて野手が取れなくなる (value 差が小さく
# 僅かな加点で接戦が全部投手に倒れるため。parity0→投手59% / parity1.5→88%)。ポジション需要も不可
# (投手 need が構造的~0 で野手だけ加点され自軍が野手ばかりになる)。加点なしが最も NPB 的。
const VOTE_NOISE: float = 2.0
# 2巡目でCPUが「指名して参加」するスコア下限。value を素の能力 (player_value_score) にした scale に合わせ、
# 晒される blocked talent (能力〜55-65) の上澄みだけが残っている場合のみ動く水準 (実際の2巡目指名が
# 年0〜3人と少ないことに対応)。1巡目は各球団必ず1人指名 (=12人)、2巡目でこの閾値超えが数人。
const ROUND2_PICK_MIN_SCORE: float = 70.0

const ROUND2_MODE_PICK: String = "pick"
const ROUND2_MODE_OFFER_ONLY: String = "offer_only"
const ROUND2_MODE_NONE: String = "none"


static func create_geneki_draft_state(players: Array, teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var state: Dictionary = {
		"version": STATE_VERSION,
		"year": year,
		"user_team_id": user_team_id,
		"phase": "submit",
		"complete": false,
		"finalized": false,
		"waiting_user": false,
		"user_submitted": false,
		"current_team_id": 0,
		# team_id_str -> [entry]。entry は {player_id, from_team_id, salary, exception}。
		"team_lists": {},
		# ユーザーのリスト編集用: 適格候補とAI推奨 (player_id 配列)。
		"user_eligible_ids": [],
		"user_recommended_ids": [],
		# 1巡目投票: votes = team_id_str -> player_id / vote_counts = team_id_str -> 得票数。
		"votes": {},
		"vote_counts": {},
		"round": 1,
		"picks": [],
		"pick_order_log": [],
		# チェーンの次の指名権保持球団 (直前に選手を指名された球団)。0 = チェーン切れ (得票順で再開)。
		"chain_next": 0,
		"picked_round1": {},
		"lost_round1": {},
		"round2_participation": {},
		"round2_order": [],
		"round2_index": 0,
		"lost_round2": {},
		"waiver_order": DraftService._draft_reverse_order(teams, season),
		"seed": year * 7919 + user_team_id * 131,
		"logs": [],
	}

	var team_lists: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var eligible: Array = _eligible_entries_for_team(players, team.id, season)
		if team.id == user_team_id:
			var recommended: Array = _cpu_select_list(eligible)
			var eligible_ids: Array = []
			for entry_row in eligible:
				eligible_ids.append(int((entry_row as Dictionary).get("player_id", 0)))
			state["user_eligible_ids"] = eligible_ids
			var recommended_ids: Array = []
			for entry_row in recommended:
				recommended_ids.append(int((entry_row as Dictionary).get("player_id", 0)))
			state["user_recommended_ids"] = recommended_ids
			team_lists[str(team.id)] = []
		else:
			team_lists[str(team.id)] = _cpu_select_list(eligible)
	state["team_lists"] = team_lists

	# ユーザー球団が存在しない (レポート/テストの全CPU進行) 場合は提出も含めて自動で完了させる。
	if user_team_id <= 0 or not team_lists.has(str(user_team_id)):
		state["user_submitted"] = true
		return _advance_until_user_or_complete(state, players, teams, season, true)
	return _advance_until_user_or_complete(state, players, teams, season, false)


# ============================================================ 適格判定・リスト選定

# 現役ドラフトの指名対象になれるか (リスト全体の人数/例外枠ルールは _validate_list 側)。
static func is_eligible(player: PSPlayer, year: int) -> bool:
	if player == null or player.team_id <= 0 or player.is_retired():
		return false
	if player.development_player or player.foreign_player:
		return false
	if player.salary >= SALARY_EXCEPTION_MAX:
		return false
	# 複数年契約中は対象外 (契約最終年のオフは満了扱い、FA/戦力外と同じ境界)。
	if player.is_multi_year_locked_offseason(year):
		return false
	# FA権保有者・FA権行使経験者 (fa_signed_year = 宣言してFA契約/残留した履歴) は対象外。
	if player.is_fa_eligible() or player.source_data.has("fa_signed_year"):
		return false
	# 当年ドラフト入団の新人 (オフの本指名/育成指名は現役ドラフトより前のステップ) は対象外。
	# 判定は当年との「一致」に限る: 初期シードは進化後ワールド由来の未来年 draft_year を
	# 持ち込むことがあり (rookie_year も生涯 true のまま)、>= 比較だとドラフト出身のほぼ
	# 全選手が新人扱いになって対象者ゼロになる。念のため在籍0年 (今オフ入団) も新人扱い。
	if year > 0 and int(player.source_data.get("draft_year", 0)) == year:
		return false
	if player.years <= 0 and bool(player.source_data.get("rookie_year", false)):
		return false
	# 当年 (今季) トレードで獲得した選手は対象外。
	if int(player.source_data.get("traded_year", 0)) == year and year > 0:
		return false
	return true


static func _eligible_entries_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var year: int = season.year if season != null else 0
	var evaluations: Dictionary = OffseasonService.release_depth_chart_evaluations(players, team_id, season)
	# 役割別の value 分布 (リーグ全体)。appeal は raw value でなく「役割内での相対順位 (percentile)」で
	# 測る。野手は systematically 高 value (実測 avg 69 vs 68、p90 82 vs 78) なので raw だと露出が
	# 野手に偏る (特に記録が乏しく能力だけで選ぶ状況)。役割内 percentile なら投打が対称になる。
	var pit_sorted: Array = []
	var fld_sorted: Array = []
	for player_row in players:
		var lp: PSPlayer = player_row as PSPlayer
		if lp == null or lp.team_id <= 0 or lp.is_retired() or lp.development_player:
			continue
		var lv: int = OffseasonService.player_value_score(lp)
		if lp.is_pitcher():
			pit_sorted.append(lv)
		else:
			fld_sorted.append(lv)
	pit_sorted.sort()
	fld_sorted.sort()
	var entries: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if not is_eligible(player, year):
			continue
		var evaluation: Dictionary = evaluations.get(player.id, {}) as Dictionary
		var record: PSPlayerSeasonRecord = evaluation.get("record", null) as PSPlayerSeasonRecord
		if record == null and season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var v: int = OffseasonService.player_value_score(player)
		var is_pit: bool = player.is_pitcher()
		entries.append({
			"player_id": player.id,
			"name": player.name,
			"from_team_id": team_id,
			"salary": player.salary,
			"exception": player.salary >= SALARY_STANDARD_MAX,
			"age": player.age,
			"is_pitcher": is_pit,
			"playing_time_ratio": _playing_time_ratio(player, record),
			# 指名評価は raw value (投打を跨いで best available を選ぶため)。露出 appeal は役割内 percentile。
			# projected_value/future_value は使わない (前者は blocked talent を出場割引で過小評価、後者は成長で過大)。
			"value": v,
			"role_pct": _value_percentile(pit_sorted if is_pit else fld_sorted, v),
		})
	return entries


# 当季の出場率 (0〜1)。投手は登板数、野手は試合数を規定近い水準で正規化。record 無し=0 (blocked扱い)。
static func _playing_time_ratio(player: PSPlayer, record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	if player.is_pitcher():
		var appearances: int = record.pitcher_stats.starts + record.pitcher_stats.relief_appearances
		return clampf(float(appearances) / float(EXPOSE_REGULAR_PITCHER_APP), 0.0, 1.0)
	return clampf(float(record.batter_stats.games) / float(EXPOSE_REGULAR_BATTER_GAMES), 0.0, 1.0)


# 放出候補としての appeal。役割内での相対的な高能力・出場少 (blocked)・若さ で高くなる。
# 能力は raw value でなく **役割内 percentile** (`role_pct` 0〜1) を使う → 投手/野手が対称になり、
# 野手が raw で高い分の露出偏りを排除 (記録が乏しく能力だけで選ぶ状況でも投打が偏らない)。
# ability_score = 40 + role_pct×60 で 40〜100 の役割中立な能力値に写像。主力(高出場)と役割内トップ層は保護。
static func _exposure_appeal(entry: Dictionary) -> float:
	var role_pct: float = float(entry.get("role_pct", 0.5))
	var ability: float = 40.0 + role_pct * 60.0
	var ratio: float = float(entry.get("playing_time_ratio", 0.0))
	var blocked: float = 1.0 - ratio
	var appeal: float = ability * (1.0 + EXPOSE_BLOCKED_WEIGHT * blocked) * _age_factor(int(entry.get("age", 25)))
	if ratio >= EXPOSE_REGULAR_RATIO:
		appeal *= EXPOSE_REGULAR_PENALTY
	if role_pct >= EXPOSE_PROTECT_PERCENTILE:
		appeal *= EXPOSE_STAR_PENALTY
	if bool(entry.get("is_pitcher", false)):
		appeal *= EXPOSE_PITCHER_BIAS
	return appeal


# sorted_vals (昇順) の中で v が下から何割の位置か (0〜1)。役割内 percentile。
static func _value_percentile(sorted_vals: Array, v: int) -> float:
	var n: int = sorted_vals.size()
	if n == 0:
		return 0.5
	var below: int = 0
	for x in sorted_vals:
		if int(x) < v:
			below += 1
		else:
			break
	return float(below) / float(n)


# 年齢係数: 24〜30歳=1.0、23歳以下は素材保護で逓減 (21歳以下 EXPOSE_PROSPECT_FLOOR)、31歳以降も逓減。
static func _age_factor(age: int) -> float:
	if age < EXPOSE_PRIME_MIN:
		var t: float = clampf(float(age - 21) / float(EXPOSE_PRIME_MIN - 21), 0.0, 1.0)
		return lerpf(EXPOSE_PROSPECT_FLOOR, 1.0, t)
	if age <= EXPOSE_PRIME_MAX:
		return 1.0
	return maxf(EXPOSE_OLD_FLOOR, 1.0 - float(age - EXPOSE_PRIME_MAX) * EXPOSE_OLD_DECAY)


# CPUのリスト選定: 「能力はあるが出場機会に恵まれない中堅」を appeal 順に晒す (NPB実績準拠)。
# 5000万未満 (standard) を appeal 降順で優先し、不足分だけ例外枠 (5000万以上) を使う。
static func _cpu_select_list(eligible: Array) -> Array:
	var standard: Array = []
	var exception: Array = []
	for entry_row in eligible:
		var entry: Dictionary = (entry_row as Dictionary).duplicate(true)
		entry["appeal"] = _exposure_appeal(entry)
		if bool(entry.get("exception", false)):
			exception.append(entry)
		else:
			standard.append(entry)
	standard.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary).get("appeal", 0.0)) > float((b as Dictionary).get("appeal", 0.0))
	)
	var selected: Array = []
	for entry_row in standard:
		if selected.size() >= CPU_LIST_SIZE:
			break
		selected.append(entry_row)
	if selected.size() < CPU_LIST_SIZE and not exception.is_empty():
		# 5000万未満が足りない球団のみ例外枠を appeal 上位1人で補う (最低保証を優先)。
		exception.sort_custom(func(a, b) -> bool:
			return float((a as Dictionary).get("appeal", 0.0)) > float((b as Dictionary).get("appeal", 0.0))
		)
		selected.append(exception[0])
	return selected


# ユーザー提出リストの検証。ok=false 時は message を返す。
# 人数下限は「適格プールで物理的に揃えられる最大数」まで緩和する (縮小ワールド防御。
# 例外枠1人までのルール自体は緩和しない)。
static func _validate_list(entries: Array, eligible: Array) -> Dictionary:
	var exception_count: int = 0
	for entry_row in entries:
		if bool((entry_row as Dictionary).get("exception", false)):
			exception_count += 1
	if exception_count > 1:
		return {"ok": false, "message": "年俸5000万円以上の選手は1人までしかリストに入れられません"}
	var required: int = LIST_MIN
	if exception_count > 0:
		required = LIST_MIN_WITH_EXCEPTION
	var eligible_standard: int = 0
	var eligible_exception: int = 0
	for entry_row in eligible:
		if bool((entry_row as Dictionary).get("exception", false)):
			eligible_exception += 1
		else:
			eligible_standard += 1
	required = mini(required, eligible_standard + mini(1, eligible_exception))
	if entries.size() < required:
		return {"ok": false, "message": "リストは%d人以上必要です (年俸5000万円以上を含む場合は%d人以上)" % [LIST_MIN, LIST_MIN_WITH_EXCEPTION]}
	return {"ok": true}


# ============================================================ ユーザー操作

static func submit_user_list(state: Dictionary, players: Array, teams: Array, season: PSSeason, player_ids: Array) -> Dictionary:
	if str(state.get("phase", "")) != "submit":
		return {"ok": false, "message": "リスト提出の段階ではありません", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	var eligible: Array = _eligible_entries_for_team(players, user_team_id, season)
	var entries: Array = []
	for id_value in player_ids:
		var player_id: int = int(id_value)
		var found: Dictionary = {}
		for entry_row in eligible:
			if int((entry_row as Dictionary).get("player_id", 0)) == player_id:
				found = (entry_row as Dictionary).duplicate(true)
				break
		if found.is_empty():
			return {"ok": false, "message": "対象外の選手が含まれています (id=%d)" % player_id, "state": state}
		entries.append(found)
	var validation: Dictionary = _validate_list(entries, eligible)
	if not bool(validation.get("ok", false)):
		validation["state"] = state
		return validation
	(state["team_lists"] as Dictionary)[str(user_team_id)] = entries
	state["user_submitted"] = true
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# ユーザーの手番での指名 (1巡目・2巡目共通)。
static func submit_user_pick(state: Dictionary, players: Array, teams: Array, season: PSSeason, player_id: int) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if not bool(state.get("waiting_user", false)) or int(state.get("current_team_id", 0)) != user_team_id:
		return {"ok": false, "message": "自軍の指名の手番ではありません", "state": state}
	var phase: String = str(state.get("phase", ""))
	var targets: Array = []
	if phase == "round1":
		targets = round1_targets(state, user_team_id)
	elif phase == "round2":
		targets = round2_targets(state, user_team_id)
	else:
		return {"ok": false, "message": "指名の段階ではありません", "state": state}
	var entry: Dictionary = _find_entry(targets, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は指名できません", "state": state}
	_apply_pick(state, teams, user_team_id, entry)
	if phase == "round2":
		state["round2_index"] = int(state.get("round2_index", 0)) + 1
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# 2巡目での棄権 (1巡目の指名は義務なので棄権できない)。
static func pass_user_pick(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if not bool(state.get("waiting_user", false)) or int(state.get("current_team_id", 0)) != user_team_id:
		return {"ok": false, "message": "自軍の指名の手番ではありません", "state": state}
	if str(state.get("phase", "")) != "round2":
		return {"ok": false, "message": "1巡目の指名は棄権できません", "state": state}
	_log(state, teams, "2巡目: %s は指名を見送り" % _team_name(teams, user_team_id))
	state["round2_index"] = int(state.get("round2_index", 0)) + 1
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# 2巡目の参加形態 (pick / offer_only / none) の選択。
static func set_user_round2_mode(state: Dictionary, players: Array, teams: Array, season: PSSeason, mode: String) -> Dictionary:
	if str(state.get("phase", "")) != "round2_entry":
		return {"ok": false, "message": "2巡目の参加選択の段階ではありません", "state": state}
	if not [ROUND2_MODE_PICK, ROUND2_MODE_OFFER_ONLY, ROUND2_MODE_NONE].has(mode):
		return {"ok": false, "message": "不正な参加形態です", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	(state["round2_participation"] as Dictionary)[str(user_team_id)] = mode
	_begin_round2(state, teams)
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# ユーザー操作を全てAIに任せて完了まで進める (UIの「AIに任せる」/ ツールの自動消化用)。
static func complete_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, true)}


# ============================================================ 進行

static func _advance_until_user_or_complete(state: Dictionary, players: Array, teams: Array, season: PSSeason, auto_user: bool) -> Dictionary:
	state["waiting_user"] = false
	var user_team_id: int = int(state.get("user_team_id", 0))
	var guard: int = 0
	while not bool(state.get("complete", false)) and guard < 200:
		guard += 1
		var phase: String = str(state.get("phase", ""))
		if phase == "submit":
			if not bool(state.get("user_submitted", false)):
				if not auto_user:
					state["waiting_user"] = true
					state["current_team_id"] = user_team_id
					return state
				var user_entries: Array = _cpu_select_list(_eligible_entries_for_team(players, user_team_id, season))
				(state["team_lists"] as Dictionary)[str(user_team_id)] = user_entries
				state["user_submitted"] = true
			_begin_round1(state, players, teams)
		elif phase == "round1":
			var picker: int = _next_round1_picker(state)
			if picker <= 0:
				_prepare_round2_entry(state, players, teams, auto_user)
				continue
			state["current_team_id"] = picker
			if picker == user_team_id and not auto_user:
				state["waiting_user"] = true
				return state
			_cpu_pick_round1(state, teams, picker)
		elif phase == "round2_entry":
			if not auto_user:
				state["waiting_user"] = true
				state["current_team_id"] = user_team_id
				return state
			(state["round2_participation"] as Dictionary)[str(user_team_id)] = _cpu_round2_mode(state, players, user_team_id)
			_begin_round2(state, teams)
		elif phase == "round2":
			var order: Array = state.get("round2_order", []) as Array
			var index: int = int(state.get("round2_index", 0))
			if index >= order.size():
				_finish_event(state)
				continue
			var picker2: int = int(order[index])
			state["current_team_id"] = picker2
			if picker2 == user_team_id and not auto_user:
				state["waiting_user"] = true
				return state
			_cpu_pick_round2(state, players, teams, picker2)
			state["round2_index"] = int(state.get("round2_index", 0)) + 1
		else:
			break
	return state


# 参加球団 = リストに1人以上載せた球団。11球団以下でも同じチェーン方式で回す
# (テスト/縮小ワールド向けの防御。実NPBは常に12球団)。
static func _participants(state: Dictionary) -> Array:
	var result: Array = []
	var team_lists: Dictionary = state.get("team_lists", {}) as Dictionary
	for team_key in team_lists.keys():
		if not (team_lists[team_key] as Array).is_empty():
			result.append(int(str(team_key)))
	return result


static func _begin_round1(state: Dictionary, players: Array, teams: Array) -> void:
	var participants: Array = _participants(state)
	if participants.size() < 2:
		_log(state, teams, "参加球団が不足しているため現役ドラフトは実施されませんでした")
		_finish_event(state)
		return

	# 投票: 各球団が「最も欲しい他球団リスト選手」(スコア最大) に1票。
	var votes: Dictionary = {}
	var vote_counts: Dictionary = {}
	for team_id_value in participants:
		vote_counts[str(int(team_id_value))] = 0
	for team_id_value in participants:
		var voter_id: int = int(team_id_value)
		var best_entry: Dictionary = _best_entry_for_team(state, voter_id, _all_listed_entries_except(state, voter_id))
		if best_entry.is_empty():
			continue
		var voted_player: int = int(best_entry.get("player_id", 0))
		votes[str(voter_id)] = voted_player
		var owner_key: String = str(int(best_entry.get("from_team_id", 0)))
		vote_counts[owner_key] = int(vote_counts.get(owner_key, 0)) + 1
	state["votes"] = votes
	state["vote_counts"] = vote_counts
	state["phase"] = "round1"
	_log(state, teams, "1巡目: 投票の結果、%s が最初の指名権を獲得" % _team_name(teams, _top_vote_team(state, participants)))


static func _all_listed_entries_except(state: Dictionary, team_id: int) -> Array:
	var result: Array = []
	var team_lists: Dictionary = state.get("team_lists", {}) as Dictionary
	for team_key in team_lists.keys():
		if int(str(team_key)) == team_id:
			continue
		for entry_row in team_lists[team_key] as Array:
			result.append(entry_row)
	return result


# 指名/投票スコア: 能力 value + 決定論ノイズ (state.seed 起点なのでリロードでも不変)。
# ポジション需要は使わない: 投手のリーグ相対 need は構造的に~0 で、需要を足すと「投手には加点0・
# 野手にだけ加点」となり、どの球団も僅差では必ず野手を選ぶ (=自軍が野手ばかり指名する) ため
# ([[project_offseason_roster_mechanics]])。現役ドラフトの指名は blocked talent の能力/伸びしろ勝負にする。
static func _entry_score_for_team(state: Dictionary, team_id: int, entry: Dictionary) -> float:
	var player_id: int = int(entry.get("player_id", 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(state.get("seed", 0)) + team_id * 92821 + player_id * 68927
	return float(entry.get("value", 0.0)) + rng.randf() * VOTE_NOISE


static func _best_entry_for_team(state: Dictionary, team_id: int, entries: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -INF
	for entry_row in entries:
		var entry: Dictionary = entry_row as Dictionary
		var score: float = _entry_score_for_team(state, team_id, entry)
		if score > best_score:
			best_score = score
			best = entry
	return best


static func _top_vote_team(state: Dictionary, candidates: Array) -> int:
	var vote_counts: Dictionary = state.get("vote_counts", {}) as Dictionary
	var waiver: Array = state.get("waiver_order", []) as Array
	var best_team: int = 0
	var best_votes: int = -1
	var best_waiver: int = waiver.size() + 1
	for team_id_value in candidates:
		var team_id: int = int(team_id_value)
		var votes: int = int(vote_counts.get(str(team_id), 0))
		var waiver_pos: int = waiver.find(team_id)
		if waiver_pos < 0:
			waiver_pos = waiver.size()
		# 最多得票優先、同数は前年下位球団 (waiver_order の前方) 優先。
		if votes > best_votes or (votes == best_votes and waiver_pos < best_waiver):
			best_votes = votes
			best_waiver = waiver_pos
			best_team = team_id
	return best_team


# 1巡目の次の指名球団。0 = 全参加球団が指名済み (1巡目終了)。
# チェーン方式: 直前に選手を指名された球団が未指名ならその球団、指名済み (=チェーンが閉じた)
# なら未指名球団の得票数上位から再開する。
static func _next_round1_picker(state: Dictionary) -> int:
	var participants: Array = _participants(state)
	var picked: Dictionary = state.get("picked_round1", {}) as Dictionary
	var unpicked: Array = []
	for team_id_value in participants:
		if not picked.has(str(int(team_id_value))):
			unpicked.append(int(team_id_value))
	if unpicked.is_empty():
		return 0
	var chained: int = int(state.get("chain_next", 0))
	if chained > 0 and unpicked.has(chained):
		return chained
	return _top_vote_team(state, unpicked)


# 1巡目で指名可能な相手リスト選手。自球団以外・放出済みでない球団・未指名の選手のうち、
# 「指名すると最後の1球団が自球団の選手しか指名できなくなる」手 (孤立詰み) を除外する。
static func round1_targets(state: Dictionary, picker_id: int) -> Array:
	var participants: Array = _participants(state)
	var picked: Dictionary = state.get("picked_round1", {}) as Dictionary
	var lost: Dictionary = state.get("lost_round1", {}) as Dictionary
	var picked_player_ids: Dictionary = _picked_player_ids(state)
	var targets: Array = []
	var team_lists: Dictionary = state.get("team_lists", {}) as Dictionary
	for team_id_value in participants:
		var owner_id: int = int(team_id_value)
		if owner_id == picker_id or lost.has(str(owner_id)):
			continue
		for entry_row in team_lists[str(owner_id)] as Array:
			var entry: Dictionary = entry_row as Dictionary
			if picked_player_ids.has(int(entry.get("player_id", 0))):
				continue
			if _pick_strands_last_team(participants, picked, lost, picker_id, owner_id):
				continue
			targets.append(entry)
	return targets


# picker が owner の選手を指名した後、未指名球団がちょうど1つ残り、かつ放出可能な球団も
# その1球団だけになる (= 自球団しか指名できず詰む) 場合 true。
static func _pick_strands_last_team(participants: Array, picked: Dictionary, lost: Dictionary, picker_id: int, owner_id: int) -> bool:
	var unpicked_after: Array = []
	for team_id_value in participants:
		var team_id: int = int(team_id_value)
		if team_id != picker_id and not picked.has(str(team_id)):
			unpicked_after.append(team_id)
	if unpicked_after.size() != 1:
		return false
	var unlost_after: Array = []
	for team_id_value in participants:
		var team_id: int = int(team_id_value)
		if team_id != owner_id and not lost.has(str(team_id)):
			unlost_after.append(team_id)
	return unlost_after.size() == 1 and int(unlost_after[0]) == int(unpicked_after[0])


static func _picked_player_ids(state: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for pick_row in state.get("picks", []) as Array:
		result[int((pick_row as Dictionary).get("player_id", 0))] = true
	return result


static func _cpu_pick_round1(state: Dictionary, teams: Array, picker_id: int) -> void:
	var targets: Array = round1_targets(state, picker_id)
	if targets.is_empty():
		# 防御: 孤立ガードにより通常到達しない。リスト全消化などの異常時はチェーンから外す。
		(state["picked_round1"] as Dictionary)[str(picker_id)] = 0
		(state["pick_order_log"] as Array).append(picker_id)
		state["chain_next"] = 0
		_log(state, teams, "1巡目: %s は指名できる選手がいませんでした" % _team_name(teams, picker_id))
		return
	_apply_pick(state, teams, picker_id, _best_entry_for_team(state, picker_id, targets))


static func _apply_pick(state: Dictionary, teams: Array, picker_id: int, entry: Dictionary) -> void:
	var round_no: int = 1 if str(state.get("phase", "")) == "round1" else 2
	var from_team_id: int = int(entry.get("from_team_id", 0))
	var pick: Dictionary = {
		"round": round_no,
		"order": (state.get("picks", []) as Array).size() + 1,
		"team_id": picker_id,
		"from_team_id": from_team_id,
		"player_id": int(entry.get("player_id", 0)),
		"salary": int(entry.get("salary", 0)),
	}
	(state["picks"] as Array).append(pick)
	if round_no == 1:
		(state["picked_round1"] as Dictionary)[str(picker_id)] = int(entry.get("player_id", 0))
		(state["lost_round1"] as Dictionary)[str(from_team_id)] = int(entry.get("player_id", 0))
		(state["pick_order_log"] as Array).append(picker_id)
		state["chain_next"] = from_team_id
	else:
		(state["lost_round2"] as Dictionary)[str(from_team_id)] = int(entry.get("player_id", 0))
	_log(state, teams, "%d巡目: %s が %s の %s を指名" % [round_no, _team_name(teams, picker_id), _team_name(teams, from_team_id), str(entry.get("name", ""))])


# ============================================================ 2巡目

static func _prepare_round2_entry(state: Dictionary, players: Array, teams: Array, auto_user: bool) -> void:
	var participants: Array = _participants(state)
	var user_team_id: int = int(state.get("user_team_id", 0))
	var participation: Dictionary = state.get("round2_participation", {}) as Dictionary
	for team_id_value in participants:
		var team_id: int = int(team_id_value)
		if team_id == user_team_id and not auto_user:
			continue
		participation[str(team_id)] = _cpu_round2_mode(state, players, team_id)
	state["round2_participation"] = participation
	if participants.has(user_team_id) and not auto_user:
		state["phase"] = "round2_entry"
		return
	_begin_round2(state, teams)


# CPUの2巡目参加形態: 支配下枠に収まり、明確に有用な選手が残っていれば「指名して参加」。
# それ以外は「放出のみ参加」(リスト提出済みで追加コストが無く、余剰を引き取ってもらえる余地を残す)。
static func _cpu_round2_mode(state: Dictionary, players: Array, team_id: int) -> String:
	var best: Dictionary = _best_entry_for_team(state, team_id, round2_candidate_pool_preview(state, team_id))
	if best.is_empty():
		return ROUND2_MODE_OFFER_ONLY
	var best_score: float = _entry_score_for_team(state, team_id, best)
	if best_score < ROUND2_PICK_MIN_SCORE:
		return ROUND2_MODE_OFFER_ONLY
	var count: int = TeamFinance.controlled_count(players, team_id)
	if count + 1 > TeamFinance.CONTROLLED_LIMIT:
		return ROUND2_MODE_OFFER_ONLY
	return ROUND2_MODE_PICK


# 参加形態の決定前に使う「2巡目に残っていそうな選手」のプレビュー (全球団の残りリスト選手)。
# 実際の指名時は round2_targets が参加形態を反映して絞り直す。
static func round2_candidate_pool_preview(state: Dictionary, team_id: int) -> Array:
	var picked_player_ids: Dictionary = _picked_player_ids(state)
	var result: Array = []
	var team_lists: Dictionary = state.get("team_lists", {}) as Dictionary
	for team_key in team_lists.keys():
		if int(str(team_key)) == team_id:
			continue
		for entry_row in team_lists[team_key] as Array:
			if not picked_player_ids.has(int((entry_row as Dictionary).get("player_id", 0))):
				result.append(entry_row)
	return result


static func _begin_round2(state: Dictionary, teams: Array) -> void:
	var participation: Dictionary = state.get("round2_participation", {}) as Dictionary
	# 2巡目の指名順は1巡目の指名順の逆 (指名希望球団のみ)。
	var order: Array = []
	var order_log: Array = (state.get("pick_order_log", []) as Array).duplicate()
	order_log.reverse()
	for team_id_value in order_log:
		var team_id: int = int(team_id_value)
		if str(participation.get(str(team_id), ROUND2_MODE_NONE)) == ROUND2_MODE_PICK:
			order.append(team_id)
	state["round2_order"] = order
	state["round2_index"] = 0
	state["phase"] = "round2"
	if order.is_empty():
		_log(state, teams, "2巡目: 指名を希望する球団がなく終了")
		_finish_event(state)


# 2巡目で指名可能な選手: 参加球団 (pick / offer_only) の残りリスト選手のうち、自球団以外・
# 2巡目でまだ放出していない球団の選手。各球団の放出は巡ごとに1人まで。
static func round2_targets(state: Dictionary, picker_id: int) -> Array:
	var participation: Dictionary = state.get("round2_participation", {}) as Dictionary
	var lost2: Dictionary = state.get("lost_round2", {}) as Dictionary
	var picked_player_ids: Dictionary = _picked_player_ids(state)
	var targets: Array = []
	var team_lists: Dictionary = state.get("team_lists", {}) as Dictionary
	for team_key in team_lists.keys():
		var owner_id: int = int(str(team_key))
		if owner_id == picker_id or lost2.has(str(owner_id)):
			continue
		var mode: String = str(participation.get(str(owner_id), ROUND2_MODE_NONE))
		if mode != ROUND2_MODE_PICK and mode != ROUND2_MODE_OFFER_ONLY:
			continue
		for entry_row in team_lists[str(owner_id)] as Array:
			if not picked_player_ids.has(int((entry_row as Dictionary).get("player_id", 0))):
				targets.append(entry_row)
	return targets


static func _cpu_pick_round2(state: Dictionary, players: Array, teams: Array, picker_id: int) -> void:
	var targets: Array = round2_targets(state, picker_id)
	var best: Dictionary = _best_entry_for_team(state, picker_id, targets)
	if best.is_empty() or _entry_score_for_team(state, picker_id, best) < ROUND2_PICK_MIN_SCORE:
		_log(state, teams, "2巡目: %s は指名を見送り" % _team_name(teams, picker_id))
		return
	# 支配下枠の再確認 (2巡目の獲得は純増。同巡で放出済みなら差し引きゼロ)。
	var net_gain: int = 1
	if (state.get("lost_round2", {}) as Dictionary).has(str(picker_id)):
		net_gain = 0
	if TeamFinance.controlled_count(players, picker_id) + net_gain > TeamFinance.CONTROLLED_LIMIT:
		_log(state, teams, "2巡目: %s は支配下枠が埋まっているため見送り" % _team_name(teams, picker_id))
		return
	_apply_pick(state, teams, picker_id, best)


static func _finish_event(state: Dictionary) -> void:
	state["phase"] = "done"
	state["complete"] = true
	state["waiting_user"] = false
	state["current_team_id"] = 0


# ============================================================ 確定 (移籍の実適用)

static func finalize_geneki_draft(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {"title": "現役ドラフト", "moves": []}) as Dictionary
	var year: int = season.year if season != null else int(state.get("year", 0))
	var moves: Array = []
	var round1_count: int = 0
	var round2_count: int = 0
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		var player: PSPlayer = _find_player(players, int(pick.get("player_id", 0)))
		if player == null:
			continue
		var from_team_id: int = int(pick.get("from_team_id", 0))
		var to_team_id: int = int(pick.get("team_id", 0))
		if player.team_id != from_team_id:
			# 状態と選手の所属がずれている場合は移籍させない (二重適用や外部変更への防御)。
			continue
		if season != null:
			season.transfer_active_roster_days(from_team_id, to_team_id, player.id)
		player.team_id = to_team_id
		player.source_data["geneki_draft_year"] = year
		PSCareerLog.log_geneki_draft(player, year, from_team_id, to_team_id)
		if int(pick.get("round", 1)) == 1:
			round1_count += 1
		else:
			round2_count += 1
		# from_team/to_team は結果表 (team_mode "move") の慣習に合わせ球団id。
		moves.append({
			"player_id": player.id,
			"name": player.name,
			"position": player.position,
			"role": player.role,
			"age": player.age,
			"salary": player.salary,
			"round": int(pick.get("round", 1)),
			"order": int(pick.get("order", 0)),
			"from_team": from_team_id,
			"to_team": to_team_id,
		})
	var user_team_id: int = int(state.get("user_team_id", 0))
	var user_gained: int = 0
	var user_lost: int = 0
	for move_row in moves:
		var move: Dictionary = move_row as Dictionary
		if int(move.get("to_team", 0)) == user_team_id:
			user_gained += 1
		if int(move.get("from_team", 0)) == user_team_id:
			user_lost += 1
	var result: Dictionary = {
		"title": "現役ドラフト",
		"moves": moves,
		"moved_count": moves.size(),
		"round1_count": round1_count,
		"round2_count": round2_count,
		"user_gained": user_gained,
		"user_lost": user_lost,
		"logs": (state.get("logs", []) as Array).duplicate(true),
	}
	state["finalized"] = true
	state["final_result"] = result
	return result


# ============================================================ 共通ヘルパー

static func _find_entry(entries: Array, player_id: int) -> Dictionary:
	for entry_row in entries:
		if int((entry_row as Dictionary).get("player_id", 0)) == player_id:
			return entry_row as Dictionary
	return {}


static func _find_player(players: Array, player_id: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


static func _team_name(teams: Array, team_id: int) -> String:
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id == team_id:
			return team.name
	return "球団%d" % team_id


static func _log(state: Dictionary, _teams: Array, text: String) -> void:
	(state["logs"] as Array).append(text)
