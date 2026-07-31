extends RefCounted
class_name OffseasonService

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const ReleaseValueProjector = preload("res://services/season/release_value_projector.gd")

# 引退は「年齢による自然減」と「高齢かつ低稼働」を併用する。
# 出場機会を維持している選手でも40歳以降は毎年確率が上がり、48歳で必ず引退する。
# 38歳以上で役割別の少試合基準を満たす選手は、強制年齢に達する前でも引退候補になる。
const RETIREMENT_AGE_THRESHOLD: int = 38
const FORCED_RETIREMENT_RAMP_START_AGE: int = 40
const FORCED_RETIREMENT_CERTAIN_AGE: int = 48

# 自動戦力外通告は、来季の役割スロットから溢れ、かつ将来価値が代替水準を下回る選手だけを対象にする。
# 開幕支配下目標から逆算する編成計画は人数目標ではなく、候補数の上限としてのみ使う。
# 見込みドラフト人数 (draft_service の目標と桁を合わせる。厳密一致は不要で、実際の指名数は
# ドラフト時点の在籍から自動で再計算されるため誤差は自己補正される)。
const RELEASE_PLAN_DRAFT_ESTIMATE: int = 7
# FA/戦力外獲得など後段補強の見込み (draft_service.DRAFT_SIGNING_RESERVE と同じ桁)。
const RELEASE_PLAN_SIGNING_RESERVE: int = 2
# 育成昇格見込みとして計画に足す上限 (昇格はオフの後段で起こり支配下を増やす)。
const RELEASE_PLAN_PROMO_CAP: int = 2
# 1球団が1オフに放出できる上限 (計画暴走の安全弁)。
const RELEASE_PLAN_MAX_PER_TEAM: int = 15
# 編成計画に対して許容する上振れ。下限は設けず、該当者が少なければその人数で止める。
const RECONCILE_UPPER_SLACK: int = 2
# 入団1年目のみ rookie 保護する。
const CPU_RELEASE_ROOKIE_PROTECTION_YEARS: int = 1
# 同一CSV・seed=20260714 の比較レポートで、日本人 years<=2 の projected_value 中央値は60.34。
# 長期較正で新人中央値より約8点低い52に置き、上げるほど戦力外候補が増える。
const RELEASE_REPLACEMENT_VALUE: float = 52.0

# 補強需要 (position_need) で投手戦力を測る際に平均する上位投手の枚数。野手は各ポジション
# 「最良1人」で先発1枠を代表できるが、投手は全員 position=1 に集約されるため「エース1枚」だと
# どの球団も同水準になり需要がほぼゼロになる。上位 K 枚の平均でロスターの投手 depth を測り、
# 手薄な球団に投手需要が立つようにする。先発6+中継7 程度を見込む。
const NEED_PITCHER_DEPTH_SLOTS: int = 12

# 少出場引退に使う役割別上限。戦力外選定には使わない。
const RETIREMENT_LOW_STARTER_MAX: int = 3
const RETIREMENT_LOW_RELIEVER_MAX: int = 10
const RETIREMENT_LOW_FIELDER_MAX: int = 20

# roadmap #3 育成制度に合わせたロスター判定 (支配下→育成 / 育成→戦力外 / 育成→支配下)。
# 「今後2〜3年の期待価値」を future_value_score に一本化し、相対値・代替差で段階判定する。
#
# 統一スコア future_value_score = 現在能力 (player_value_score)
#   + 成長期待 (expected_development_score_bonus * FUTURE_GROWTH_WEIGHT) − 故障リスク (injury_value_penalty)。
# 希少性・編成適合は戦力外の役割スロット / draft の need で構造的に担保し、
# 育成用スコアには混ぜない。
const FUTURE_GROWTH_WEIGHT: float = 1.0
# 故障リスク減点: injury_days 30日ごとに ~1 点、上限 INJURY_PENALTY_CAP。恒久能力低下は既に z へ
# 反映済みなので二重減点しない (残存離脱日数の機会損失だけを軽く引く)。
const INJURY_PENALTY_PER_30D: float = 1.0
const INJURY_PENALTY_CAP: float = 6.0

# --- 支配下→育成 降格 (CPU 自動戦力外で release の代わりに振り分け) ---
# **長期故障のリハビリ型のみ** (2026-07-03 ユーザー方針「怪我以外での育成落ちはなくす」):
# 越冬で治らない長期故障 (injury_days≥DEMOTE_INJURY_DAYS_LONG) で future_value が残るなら
# 年齢を問わず release でなく育成へ (2026-07-02、年齢上限撤廃)。
# 旧・類型1 素材保持型 (24-26歳の将来性) と旧・類型3 ベテラン確率降格は 2026-07-03 撤廃
# (CPU の育成落ちが多すぎた)。手動の育成降格 (戦力外エディタ) と育成ドラフトは従来どおり。
# DEMOTE_PROSPECT_MAX_AGE は育成整理 (_should_release_development_player) の素材年齢境界として存続。
const DEMOTE_PROSPECT_MAX_AGE: int = 26
const DEMOTE_INJURY_DAYS_LONG: int = 120
const DEMOTE_INJURY_MIN_FUTURE_VALUE: float = 40.0
# 判定のゆらぎ (5〜10%)。future_value 閾値を ±DEMOTE_JITTER 揺らし全球団が同一評価にならないように。
# marginal 層のみに効くため主力の突発降格は起きない。
const DEMOTE_JITTER: float = 0.07

# 育成→支配下 昇格 (CPU 自動): 「現在能力」value が即戦力水準に達した育成を支配下に空きがある範囲で昇格。
# 昇格は将来性ではなく「支配下で通用する準備度」= 現在能力で判断する。
# 即戦力水準は **絶対値ではなく球団ごとの相対値** (first_team_ready_threshold): 自軍の一軍相当
# (支配下を value 降順で並べた FIRST_TEAM_SIZE 番目=一軍下位レベル) と比較し、強豪は基準↑/再建は基準↓。
# PROMOTE_TO_SHIENKA_MIN_VALUE は支配下が居ない時のフォールバック基準値。
const PROMOTE_TO_SHIENKA_MIN_VALUE: int = 48
const FIRST_TEAM_SIZE: int = 31   # 一軍登録上限 (active_roster_screen ROSTER_MAX と一致)
# 相対基準のクランプ (極端化防止)。再建球団でも最低限の質を要求し、強豪でも青天井にしない。
const PROMOTE_READY_FLOOR: float = 42.0
const PROMOTE_READY_CEILING: float = 56.0

# --- 育成→戦力外 整理 (CPU 自動): 育成は「一軍に上がれる見込み」の成長予測で判定する ---
# (2026-07-02 projection 方式に刷新。旧「26歳以上 aged_out + future_value 段階閾値」を撤廃)
# projected_ceiling = 現在能力 + 残り成長期待 (expected_development_score_bonus) × 上振れマージン。
# これが球団の即戦力基準 (first_team_ready_threshold、一軍下位レベルの相対値) を下回ったら
# 「どれだけ上振れしても一軍に届く見込みがほぼ無い」として放出する。若い選手は成長期待が
# 大きく projected_ceiling が高く出るため自然に保持され、25歳前後で成長期待が萎むと
# 届かなくなり放出される (= 年齢の固定上限ではなく見込みで決まる)。
# 保持の例外: 入団/降格1年目 (years<=1)・降格/育成track獲得の同オフ (dev_demote_hold)・
# 故障リハビリ中 (injury_days>=DEMOTE_INJURY_DAYS_LONG)。加えて素材年齢 (<=DEMOTE_PROSPECT_MAX_AGE)
# のみ、即戦力 (現在能力>=相対基準、満枠待ち) と出身別猶予 (高卒4年/大社3年) でも保持する。
# **中堅以上 (素材年齢超) は「育成での再調整は1年」**: 昇格ステップで支配下に戻れなければ
# 即戦力水準や成長予測を問わずその年のオフに放出する (ベテラン育成降格・戦力外獲得育成track含む)。
const DEV_RELEASE_GRACE_HS: int = 4
const DEV_RELEASE_GRACE_OTHER: int = 3
# 成長期待の上振れマージン。期待値ちょうどではなく「覚醒が続いた楽観ケース」まで見込む倍率。
# 大きいほど放出が遅く (甘く) なる。
const DEV_PROJECTION_OPTIMISM: float = 2.0

const POSITION_NAME_BY_ID: Dictionary = {
	1: "pitcher", 2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

const GROWTH_KIND_AWAKENING: String = "awakening"
const GROWTH_KIND_GROWTH: String = "growth"
const GROWTH_KIND_STAGNATION: String = "stagnation"
const GROWTH_KIND_DECLINE: String = "decline"
const GROWTH_KIND_MAJOR_DECLINE: String = "major_decline"
const GROWTH_KIND_ORDER: Array = [
	GROWTH_KIND_AWAKENING,
	GROWTH_KIND_GROWTH,
	GROWTH_KIND_STAGNATION,
	GROWTH_KIND_DECLINE,
	GROWTH_KIND_MAJOR_DECLINE,
]
const GROWTH_KIND_LABELS: Dictionary = {
	"awakening": "覚醒",
	"growth": "成長",
	"stagnation": "停滞",
	"decline": "劣化",
	"major_decline": "大幅劣化",
}
# 成長/衰え時の 1 キーあたり z 変化量の一律スケール。値を上げるほどオフごとの能力の振れが大きくなる。
# z は Z_ABILITY_MIN/MAX (±4) でクランプされるため暴走しない。年齢別の成長/劣化バランス
# (_growth_kind_probabilities) は確率側で決まり、このスケールには線形なので交差年齢は変わらない。
const GROWTH_DELTA_SCALE: float = 1.8
const Z_ABILITY_MIN: float = -4.0
const Z_ABILITY_MAX: float = 4.0

# 越冬 (シーズン終了〜翌春キャンプ) で回復する怪我日数。長期離脱 (トミー・ジョン等) を
# 翌季へ正しく持ち越すための減算量。tunable (較正フェーズで調整)。詳細 [[project_injury_system]]。
const OFFSEASON_RECOVERY_DAYS: int = 120

# 守備適性のオフシーズン成長 (apply_position_aptitude_growth)。上限 100。
# 本職: 毎オフ一定値だけ習熟 (70→100 ≒6年, 85→100 ≒3年)。
# 別ポジ: そのシーズンに守った守備イニングに比例 (フル1シーズン専念 ≒ +15)。
const CAMP_PRIMARY_APTITUDE_GAIN: int = 5
const FULL_SEASON_DEF_INNINGS: float = 1287.0   # 143 試合 * 9 回
const FULL_SEASON_SECONDARY_GAIN: float = 15.0
const APTITUDE_GAIN_PER_INNING: float = FULL_SEASON_SECONDARY_GAIN / FULL_SEASON_DEF_INNINGS  # ≒0.01166
const APTITUDE_MAX: int = 100
const RAW_MAX_VELOCITY_MIN: int = 128
const RAW_MAX_VELOCITY_MAX: int = 165
# 新規生成時の球速レンジ。大半が 140〜150、155 はかなり少なく、160 は非常に稀。
# 成長による上振れは RAW_MAX_VELOCITY_MAX (=165) まで許容するが、初期生成はここに収める。
const GEN_MAX_VELOCITY_MIN: int = 140
const GEN_MAX_VELOCITY_MAX: int = 160


# 複数年契約中(契約満了年のオフを除く)の選手が release_ids / demote_ids に含まれていたら
# 拒否する。ユーザーの手動選択 (戦力外エディタ) は compute_release_candidates_for_team を
# 経由しないため、確定時点でここを単独のガード地点にする。
static func reject_locked_release_or_demote(players: Array, release_ids: Array, demote_ids: Array, offseason_year: int) -> Dictionary:
	for id_value in release_ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		if player != null and player.is_multi_year_locked_offseason(offseason_year):
			return {"ok": false, "message": "%s は複数年契約中のため戦力外にできません(残%d年)" % [player.name, player.contract_years_remaining(offseason_year)]}
	for id_value in demote_ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		if player != null and player.is_multi_year_locked_offseason(offseason_year):
			return {"ok": false, "message": "%s は複数年契約中のため育成降格にできません(残%d年)" % [player.name, player.contract_years_remaining(offseason_year)]}
	return {"ok": true}


# --- STEP 1 (user-driven): Release ---

static func process_release(players: Array, team_id: int, player_ids: Array, year: int = 0) -> Dictionary:
	var release_set: Dictionary = {}
	for id_value in player_ids:
		release_set[int(id_value)] = true

	var released: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not release_set.has(player.id):
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		var original_team_id: int = player.team_id
		_apply_release_mutation(player, year)
		released.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": original_team_id,
			"position": player.position,
			"role": player.role,
			"overall": player_value_score(player),
			"years": player.years,
			"salary": player.salary,
		})

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)

	return {
		"released": released,
		"released_count": released.size(),
	}


# --- 自動戦力外通告: CPU球団一括 ---

# CPU球団全部に対し、cut_score の低い順に target_size を超えた分を release。
# 既存の process_release と同じ mutation を適用し、結果配列を返す(同じ shape)。
static func process_cpu_releases(players: Array, teams: Array, user_team_id: int, season: PSSeason) -> Dictionary:
	var released: Array = []
	var demoted: Array = []
	var by_team_counts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if team.id == user_team_id:
			continue
		var cut_ids: Array = compute_release_candidates_for_team(players, team.id, season)
		var team_released_count: int = 0
		for pid_v in cut_ids:
			var pid: int = int(pid_v)
			var player: PSPlayer = _find_player_by_id(players, pid)
			if player == null:
				continue
			if player.team_id != team.id:
				continue
			if player.is_retired():
				continue
			var entry: Dictionary = {
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": team.id,
				"position": player.position,
				"role": player.role,
				"overall": player_value_score(player),
				"years": player.years,
				"salary": player.salary,
			}
			# roadmap #3: 若く価値の残る選手は release ではなく育成降格 (育成枠に空きがある間)。
			if _should_demote_to_development(player) and TeamFinance.has_development_room(players, team.id):
				_apply_demotion_to_development(player, season.year if season != null else 0)
				demoted.append(entry)
			else:
				_apply_release_mutation(player, season.year if season != null else 0)
				team_released_count += 1
				released.append(entry)
		if team_released_count > 0:
			by_team_counts[team.id] = team_released_count

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)

	return {
		"released": released,
		"released_count": released.size(),
		"demoted": demoted,
		"demoted_count": demoted.size(),
		"by_team": by_team_counts,
	}


# 外国人の去就 (残留/引き抜き/退団) は ForeignPlayerService の外国人契約市場が一括で決める。
# 結果の適用経路は別だが、判断は release_depth_chart_evaluations / would_release_player_for_team を共有する。
# compute_release_candidates_for_team 自体は国内選手だけを戦力外通告の対象にする。
# ドラフトの外国人枠予約に使う目標保有数だけ、release計画側の見込み流入計算 (_release_expected_inflow)
# が独立に参照する。
const FOREIGN_ROSTER_LIMIT: int = TeamFinance.FOREIGN_HELD_TARGET

# 指定球団について戦力外候補を選んで player_ids[] を返す。
# 自軍「自動で決める」ボタンと CPU 自動戦力外の共通アルゴリズム。
# 国内選手は「役割スロット外」かつ「projected_value が代替水準未満」の場合だけ候補にする。
# 編成計画は候補数の上限にのみ使い、人数不足を埋める強制カットは行わない。
static func release_depth_chart_evaluations(players: Array, team_id: int, season: PSSeason) -> Dictionary:
	var roster_records_all: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.development_player:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		roster_records_all.append({
			"player": player,
			"record": record,
			"projected_value": ReleaseValueProjector.projected_value(player, record),
		})
	if roster_records_all.is_empty():
		return {}

	var grouped_rows: Dictionary = {}
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		var role_key: String = _release_role_key(player)
		if not grouped_rows.has(role_key):
			grouped_rows[role_key] = []
		(grouped_rows[role_key] as Array).append(data)

	var slot_budgets: Dictionary = _release_slot_budgets(players, team_id)
	var surplus_ids: Dictionary = {}
	for role_key_v in grouped_rows.keys():
		var role_key: String = str(role_key_v)
		var role_rows: Array = grouped_rows[role_key] as Array
		role_rows.sort_custom(func(a, b) -> bool:
			var value_a: float = float((a as Dictionary)["projected_value"])
			var value_b: float = float((b as Dictionary)["projected_value"])
			if not is_equal_approx(value_a, value_b):
				return value_a > value_b
			return int(((a as Dictionary)["player"] as PSPlayer).id) < int(((b as Dictionary)["player"] as PSPlayer).id)
		)
		var budget: int = int(slot_budgets.get(role_key, 1))
		var claimed_slots: int = 0
		for role_row in role_rows:
			var role_data: Dictionary = role_row as Dictionary
			var role_player: PSPlayer = role_data["player"] as PSPlayer
			if _can_claim_release_slot(role_player, role_data.get("record", null) as PSPlayerSeasonRecord) \
					and claimed_slots < budget:
				claimed_slots += 1
			else:
				surplus_ids[role_player.id] = true

	var evaluations: Dictionary = {}
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		data["surplus"] = surplus_ids.has(player.id)
		evaluations[player.id] = data
	return evaluations


# 仮に candidate が team_id に在籍した場合の depth-chart 評価 (surplus/projected_value)。
# candidate が別球団/引退中なら仮想クローンを足して評価する。見つからなければ {}。
static func candidate_depth_evaluation_for_team(players: Array, team_id: int, candidate: PSPlayer, season: PSSeason) -> Dictionary:
	if candidate == null or team_id <= 0:
		return {}
	var evaluation_players: Array = players
	if candidate.team_id != team_id or candidate.is_retired():
		evaluation_players = players.duplicate()
		var hypothetical: PSPlayer = PSPlayer.from_dict(candidate.to_dict())
		hypothetical.team_id = team_id
		hypothetical.source_data.erase("retired")
		evaluation_players.append(hypothetical)
	var evaluations: Dictionary = release_depth_chart_evaluations(evaluation_players, team_id, season)
	return evaluations.get(candidate.id, {}) as Dictionary


# 仮に candidate が team_id に在籍した場合、通常戦力外と同じAND条件で放出対象になるかを返す。
# 外国人契約市場・新規スカウトもこの入口を使い、獲得判断と翌年の放出判断を同じ尺度に揃える。
static func would_release_player_for_team(players: Array, team_id: int, candidate: PSPlayer, season: PSSeason) -> bool:
	var evaluation: Dictionary = candidate_depth_evaluation_for_team(players, team_id, candidate, season)
	if evaluation.is_empty():
		return true
	return bool(evaluation.get("surplus", false)) \
		and float(evaluation.get("projected_value", 0.0)) < RELEASE_REPLACEMENT_VALUE


static func compute_release_candidates_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var offseason_year: int = season.year if season != null else 0
	var evaluations: Dictionary = release_depth_chart_evaluations(players, team_id, season)
	if evaluations.is_empty():
		return []

	var domestic_candidates: Array = []
	var selected_rows: Array = []
	for row in evaluations.values():
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if player.foreign_player:
			# 外国人の去就は戦力外通告ではなく外国人契約市場が決める ([[foreign_player_service.gd]])。
			continue
		if _has_rookie_release_protection(player):
			continue
		# 複数年契約中(契約満了年のオフを除く)は常時カット・計画カットどちらの候補にもしない。
		# これは _should_demote_to_development 経由の育成降格保護も兼ねる (呼び出し元
		# process_cpu_releases がこの関数の返す cut_ids からしか降格判定を行わないため)。
		if player.is_multi_year_locked_offseason(offseason_year):
			continue
		if not bool(data.get("surplus", false)):
			continue
		if float(data["projected_value"]) >= RELEASE_REPLACEMENT_VALUE:
			continue
		domestic_candidates.append(data)

	domestic_candidates.sort_custom(func(a, b) -> bool:
		var value_a: float = float((a as Dictionary)["projected_value"])
		var value_b: float = float((b as Dictionary)["projected_value"])
		if not is_equal_approx(value_a, value_b):
			return value_a < value_b
		return int(((a as Dictionary)["player"] as PSPlayer).id) < int(((b as Dictionary)["player"] as PSPlayer).id)
	)
	var plan_count: int = _release_plan_count(players, team_id, evaluations.size())
	var max_cuts: int = mini(RELEASE_PLAN_MAX_PER_TEAM, plan_count + RECONCILE_UPPER_SLACK)
	for i in range(mini(domestic_candidates.size(), max_cuts)):
		selected_rows.append(domestic_candidates[i])

	selected_rows.sort_custom(func(a, b) -> bool:
		var value_a: float = float((a as Dictionary)["projected_value"])
		var value_b: float = float((b as Dictionary)["projected_value"])
		if not is_equal_approx(value_a, value_b):
			return value_a < value_b
		return int(((a as Dictionary)["player"] as PSPlayer).id) < int(((b as Dictionary)["player"] as PSPlayer).id)
	)
	var result_ids: Array = []
	for row in selected_rows:
		result_ids.append(int(((row as Dictionary)["player"] as PSPlayer).id))
	return result_ids


# 役割別スロット予算。長期診断でゼロ出場30代の残留が捕手/外野へ集中したため、
# 初期快適水準 (C6/1B3/他4、先発13/救援20) から捕手・外野・救援を計5枠だけ縮める。
const RELEASE_POSITION_COMFORT: Dictionary = {2: 5, 3: 3, 4: 4, 5: 4, 6: 4, 7: 3, 8: 3, 9: 3}
const RELEASE_PITCHER_ROLE_COMFORT: Dictionary = {"starter": 13, "reliever": 19}
# 初期快適水準66の固定基準。較正分を総枠縮小として効かせるため、調整後comfortの合計では割り直さない。
const RELEASE_COMFORT_TOTAL: float = 66.0


static func _release_role_key(player: PSPlayer) -> String:
	if player != null and player.is_pitcher():
		return "pitcher:starter" if player.role == "starter" else "pitcher:reliever"
	return "fielder:%d" % (player.position if player != null else 0)


# 役割スロットは来季も実際に担える根拠のある選手だけが占有する。30歳以上で当季出場ゼロなら
# projected_value の高低にかかわらず depth chart 上は surplus とするが、放出には代替水準未満も必要。
# シーズンの過半を怪我で欠場した場合と成績レコード欠損時は、誤判定を避けてスロット資格を残す。
static func _can_claim_release_slot(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player == null or player.age < 30 or record == null:
		return true
	if record.season_injury_days >= ReleaseValueProjector.INJURY_EXCUSE_FULL_DAYS:
		return true
	var games: int = record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games
	return games > 0


# 見込み流入はドラフト、外国人不足、後段補強予約、即戦力の育成昇格で構成する。
static func _release_expected_inflow(players: Array, team_id: int) -> int:
	var foreign_count: int = 0
	var promo_ready: int = 0
	var ready_threshold: float = first_team_ready_threshold(players, team_id)
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired():
			continue
		if player.development_player:
			if float(player_value_score(player)) >= ready_threshold:
				promo_ready += 1
		elif player.foreign_player:
			foreign_count += 1
	var foreign_shortfall: int = maxi(0, FOREIGN_ROSTER_LIMIT - foreign_count)
	return RELEASE_PLAN_DRAFT_ESTIMATE + foreign_shortfall + RELEASE_PLAN_SIGNING_RESERVE \
			+ mini(promo_ready, RELEASE_PLAN_PROMO_CAP)


# 開幕目標から見込み流入を引いた放出後ロスターへ、快適水準の比率を比例縮小して割り当てる。
static func _release_slot_budgets(players: Array, team_id: int) -> Dictionary:
	var post_target: int = maxi(1, TeamFinance.OPENING_ROSTER_TARGET - _release_expected_inflow(players, team_id))
	var scale: float = float(post_target) / RELEASE_COMFORT_TOTAL
	var budgets: Dictionary = {}
	for position_v in RELEASE_POSITION_COMFORT.keys():
		var position: int = int(position_v)
		budgets["fielder:%d" % position] = maxi(1, roundi(float(RELEASE_POSITION_COMFORT[position]) * scale))
	for role_v in RELEASE_PITCHER_ROLE_COMFORT.keys():
		var role: String = str(role_v)
		budgets["pitcher:%s" % role] = maxi(1, roundi(float(RELEASE_PITCHER_ROLE_COMFORT[role]) * scale))
	return budgets


# 編成計画はガードレール用であり、実際の放出数を強制しない。
static func _release_plan_count(players: Array, team_id: int, roster_count: int) -> int:
	var inflow: int = _release_expected_inflow(players, team_id)
	return clampi(roster_count + inflow - TeamFinance.OPENING_ROSTER_TARGET, 0, RELEASE_PLAN_MAX_PER_TEAM)


static func _has_rookie_release_protection(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.years > CPU_RELEASE_ROOKIE_PROTECTION_YEARS:
		return false
	if player.foreign_player:
		return false
	var source: Dictionary = player.source_data
	if bool(source.get("draft_candidate", false)):
		return true
	if source.has("draft_year") or source.has("draft_year_round") or source.has("draft_overall_pick"):
		return true
	return player.draft_round > 0 and not bool(source.get("foreign_scout", false)) and not bool(source.get("fa_signed_year", false))


static func _find_player_by_id(players: Array, pid: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.id == pid:
			return player
	return null


static func _find_team_by_id(teams: Array, team_id: int) -> PSTeam:
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null


static func _apply_release_mutation(player: PSPlayer, year: int = 0) -> void:
	PSCareerLog.log_released(player, year, player.team_id)
	player.source_data["released"] = true
	player.source_data["retired"] = true
	player.source_data["retired_age"] = player.age
	player.team_id = 0


# roadmap #3: 育成降格。release せず育成選手化し、支配下枠を空けつつ org に残す。
# team_id は維持 (引退/release と異なる)。一軍登録不可・成長/怪我は通常どおり。
# dev_demote_hold は「降格した同オフに育成整理で即放出されない」保証。
# process_development_releases が1回読んで消費する (=1オフ分の保持)。
# 同じフラグを ReleasedMarketService._apply_signing (育成track獲得) も設定する。
static func _apply_demotion_to_development(player: PSPlayer, year: int = 0) -> void:
	PSCareerLog.log_dev_demote(player, year, player.team_id)
	player.development_player = true
	player.registered_roster = "育成"
	player.salary = DEVELOPMENT_CONTRACT_SALARY
	player.source_data["dev_demote_hold"] = true


# CPU 自動: 戦力外候補のうち、release ではなく育成降格 (org 残留) に回すべきか判定する。
# **長期故障のリハビリ型のみ** (2026-07-03 ユーザー方針「怪我以外での育成落ちはなくす」)。
# 越冬で治らない長期故障 (injury_days >= DEMOTE_INJURY_DAYS_LONG) で、復帰すれば戦力になる
# 将来価値が残る選手だけを育成で抱える。年齢は問わない。
# 旧・類型1 素材保持型 (24-26歳の将来性) と旧・類型3 ベテラン確率降格は撤廃
# (CPU が育成へ落とす選手が多すぎたため。手動の育成降格と育成ドラフトは従来どおり)。
# 育成枠の空きは呼び出し側 (process_cpu_releases / has_development_room) で確認済み。
static func _should_demote_to_development(player: PSPlayer) -> bool:
	if player == null or player.foreign_player:
		return false
	if player.injury_days < DEMOTE_INJURY_DAYS_LONG:
		return false
	# 全球団が同一評価にならないよう、比較閾値を ±DEMOTE_JITTER 揺らす (marginal 層のみ)。
	var jitter: float = 1.0 + (Rng.roll_float() - 0.5) * 2.0 * DEMOTE_JITTER
	return future_value_score(player) >= DEMOTE_INJURY_MIN_FUTURE_VALUE * jitter


# 出身が高卒か (育成放出の猶予年数を長くする)。生成選手は source_data["draft_source"]、
# 初期シードはデビュー年齢から PSPlayer.default_fa_eligible_years が推定する (==8 が高卒)。
static func _is_high_school_origin(player: PSPlayer) -> bool:
	if player == null:
		return false
	var eligible: int = PSPlayer.default_fa_eligible_years(player.foreign_player, player.age, player.years, player.source_data)
	return eligible == PSPlayer.FA_ELIGIBLE_YEARS_HIGH_SCHOOL


# roadmap #3: 支配下登録 (昇格)。育成選手を支配下に戻す。一軍登録可・70枠を消費する。
static func _apply_promotion_to_shienka(player: PSPlayer, year: int = 0) -> void:
	PSCareerLog.log_dev_promote(player, year, player.team_id)
	player.development_player = false
	player.registered_roster = "支配下"
	player.salary = maxi(player.salary, SALARY_MIN)


# CPU 自動: 育成選手のうち value が閾値以上の者を、支配下に空きがある範囲で昇格する。
# excluded_team_id (自軍) は対話プレイではユーザーが手動昇格するため除外する。
static func process_development_promotions(players: Array, teams: Array, excluded_team_id: int = 0, year: int = 0) -> Dictionary:
	var promoted: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == excluded_team_id:
			continue
		# 即戦力基準は球団ごとの相対値 (一軍下位レベル)。1度だけ算出して使い回す。
		var ready_threshold: float = first_team_ready_threshold(players, team.id)
		var devs: Array = []
		for player_row in players:
			var player: PSPlayer = player_row as PSPlayer
			if player == null or player.team_id != team.id:
				continue
			if player.is_retired() or not player.development_player:
				continue
			if float(player_value_score(player)) < ready_threshold:
				continue
			devs.append(player)
		devs.sort_custom(func(a, b) -> bool:
			return player_value_score(a as PSPlayer) > player_value_score(b as PSPlayer)
		)
		for dev_row in devs:
			var dev: PSPlayer = dev_row as PSPlayer
			# オフの自動昇格は soft 目標 (67) で止め、シーズン中の昇格用に枠を残す。
			if not TeamFinance.has_shienka_soft_room(players, team.id):
				break
			_apply_promotion_to_shienka(dev, year)
			promoted.append({
				"player_id": dev.id,
				"name": dev.name,
				"age": dev.age,
				"team_id": team.id,
				"position": dev.position,
				"role": dev.role,
				"overall": player_value_score(dev),
				"years": dev.years,
				"salary": dev.salary,
			})
	return {
		"promoted": promoted,
		"promoted_count": promoted.size(),
	}


# 育成整理の保持/放出判定 (非破壊)。true なら放出対象。
# 保持: 1年目 (years<=1) / 降格・育成track獲得の同オフ (dev_demote_hold、ここでは見るだけで
# 消費しない) / 故障リハビリ中。素材年齢 (<=DEMOTE_PROSPECT_MAX_AGE) はさらに
# 即戦力の満枠待ち・出身別猶予・projected_ceiling (成長予測) でも保持する。
# 中堅以上 (素材年齢超) は「育成での再調整は1年」: 上記の常時保持以外は無条件で放出対象
# (ベテランの育成降格・戦力外獲得の育成track を含む。2026-07-02 ユーザー要望)。
static func _should_release_development_player(dev: PSPlayer, ready_threshold: float) -> bool:
	if dev.years <= 1:
		return false
	if bool(dev.source_data.get("dev_demote_hold", false)):
		return false
	if dev.injury_days >= DEMOTE_INJURY_DAYS_LONG:
		return false
	if dev.age <= DEMOTE_PROSPECT_MAX_AGE:
		# 即戦力 (現在能力が相対基準以上) は満枠で昇格できなかっただけなので保持。
		var current_value: float = float(player_value_score(dev))
		if current_value >= ready_threshold:
			return false
		# 出身別の猶予年数未満は projected を問わず保持 (高卒は長め)。
		var grace: int = DEV_RELEASE_GRACE_HS if _is_high_school_origin(dev) else DEV_RELEASE_GRACE_OTHER
		if dev.years < grace:
			return false
		# 一軍昇格見込み: 残り成長期待の楽観側まで見込んだ projected_ceiling が
		# 即戦力基準に届かないなら「昇格見込みほぼ無し」で放出。
		var growth: float = maxf(0.0, expected_development_score_bonus(dev.age, 6, dev.position))
		if current_value + growth * DEV_PROJECTION_OPTIMISM >= ready_threshold:
			return false
	return true


# 自軍の戦力外エディタ推奨用: CPU の育成整理 (process_development_releases) と同じ基準で
# 放出対象になる自軍育成選手の id を返す (非破壊、dev_demote_hold は消費しない)。
# 自軍は process_development_releases から除外されるため、この候補を戦力外推奨に
# 合流させないと「条件を満たす育成選手が自軍だけ永久に残る」ことになる (2026-07-02)。
static func compute_development_release_candidates_for_team(players: Array, team_id: int) -> Array:
	var ready_threshold: float = first_team_ready_threshold(players, team_id)
	var ids: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or not player.development_player:
			continue
		if _should_release_development_player(player, ready_threshold):
			ids.append(player.id)
	return ids


# CPU 自動: 育成選手の整理 (pipeline 循環)。「一軍に上がれる見込み」を成長予測から推定し、
# projected_ceiling (現在能力+残り成長期待の楽観側) が球団の即戦力基準に届かない選手を放出する。
# 高卒は猶予4年/大社3年は projected を問わず保持し、猶予明け以降 (25歳前後の中堅) は
# 昇格見込みが無くなった時点で放出される。中堅以上 (>DEMOTE_PROSPECT_MAX_AGE) は
# 「育成1年で昇格が無ければ放出」で、これらの keep 判定を適用しない。昇格処理の直後に実行。
# excluded_team_id (自軍) は放出しないが、dev_demote_hold の消費だけは行う
# (hold=「1オフ分の保持」。自軍の整理は戦力外エディタの推奨経由で行うため、ここで
# 消費しないと自軍の hold が永久に残り翌オフ以降も保持され続けてしまう)。
static func process_development_releases(players: Array, teams: Array, excluded_team_id: int = 0, year: int = 0) -> Dictionary:
	var released: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var devs: Array = []
		for player_row in players:
			var player: PSPlayer = player_row as PSPlayer
			if player == null or player.team_id != team.id:
				continue
			if player.is_retired() or not player.development_player:
				continue
			devs.append(player)
		if team.id == excluded_team_id:
			for dev_row in devs:
				(dev_row as PSPlayer).source_data.erase("dev_demote_hold")
			continue
		# 即戦力基準は球団ごとの相対値 (一軍下位レベル)。1度だけ算出して使い回す。
		var ready_threshold: float = first_team_ready_threshold(players, team.id)
		for dev_row in devs:
			var dev: PSPlayer = dev_row as PSPlayer
			# 降格/獲得した同オフは保持 (「降格年の保持」保証)。フラグはここで消費し、翌オフから通常判定。
			if bool(dev.source_data.get("dev_demote_hold", false)):
				dev.source_data.erase("dev_demote_hold")
				continue
			if not _should_release_development_player(dev, ready_threshold):
				continue
			_apply_release_mutation(dev, year)
			released.append({
				"player_id": dev.id,
				"name": dev.name,
				"age": dev.age,
				"team_id": team.id,
				"position": dev.position,
				"role": dev.role,
				"overall": player_value_score(dev),
				"years": dev.years,
				"salary": dev.salary,
			})
	return {
		"released": released,
		"released_count": released.size(),
	}


# 自軍の指定選手を育成降格する (戦力外エディタの「育成降格」選択)。育成は人数無制限なので枠制限なし。
static func process_demotion(players: Array, team_id: int, player_ids: Array, year: int = 0) -> Dictionary:
	var demote_set: Dictionary = {}
	for id_value in player_ids:
		demote_set[int(id_value)] = true

	var demoted: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not demote_set.has(player.id):
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired() or player.development_player:
			continue
		_apply_demotion_to_development(player, year)
		demoted.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": team_id,
			"position": player.position,
			"role": player.role,
			"overall": player_value_score(player),
			"years": player.years,
			"salary": player.salary,
		})

	return {
		"demoted": demoted,
		"demoted_count": demoted.size(),
	}


# --- 引退 (Step 0): 年齢 + 出場ベース ---
# 38歳以上で「役割別少試合」(戦力外 Phase 1 と同じ基準) を満たす選手を引退。
# 強制引退 (hard age) は無し。試合に出続ける限り何歳でも続行。

static func process_retirement(players: Array, season: PSSeason) -> Dictionary:
	var retired: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if _should_retire(player, record):
			# 引退表示のため元の所属を捕捉してから team_id をクリア。
			# _apply_release_mutation (戦力外側) と対称な扱いにすることで、
			# team_id == X で集計する画面に引退選手が残らないようにする。
			var original_team_id: int = player.team_id
			PSCareerLog.log_retired(player, season.year if season != null else 0, original_team_id, player.age)
			player.source_data["retired"] = true
			player.source_data["retired_age"] = player.age
			player.team_id = 0
			# 当季レコード自身にも「このシーズンの終わりに引退した」印を残す。record.source_data は
			# from_player() 時点の player.source_data の複製で、以後 player 側を更新しても自動追随
			# しないため、レコード側にも明示的に立てる必要がある。RecordStore.get_team_player_records
			# は既定でこの印を持つレコードを除外する (現ロスター集計に引退者を含めないため)。
			if record != null:
				record.source_data[RecordStore.RETIRED_AT_SEASON_END_KEY] = true
			retired.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": original_team_id,
				"position": player.position,
				"role": player.role,
				"overall": player_value_score(player),
				"years": player.years,
			})

	retired.sort_custom(func(a, b) -> bool:
		var data_a: Dictionary = a as Dictionary
		var data_b: Dictionary = b as Dictionary
		if int(data_a["team_id"]) == int(data_b["team_id"]):
			return int(data_a["age"]) > int(data_b["age"])
		return int(data_a["team_id"]) < int(data_b["team_id"])
	)

	return {
		"retired": retired,
		"retired_count": retired.size(),
	}


static func _should_retire(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	# (1) 段階的強制引退: 40歳から確率上昇、48歳で確実。出場数に関係なく適用。
	if player.age >= FORCED_RETIREMENT_CERTAIN_AGE:
		return true
	if player.age >= FORCED_RETIREMENT_RAMP_START_AGE:
		if Rng.roll_float() < _forced_retirement_chance(player.age):
			return true
	# (2) 少出場引退: 38歳以上 かつ 役割別少試合。
	if player.age < RETIREMENT_AGE_THRESHOLD:
		return false
	return _has_low_appearance_for_retirement(record)


static func _has_low_appearance_for_retirement(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return true
	if record.is_pitcher():
		if record.is_starter_pitcher():
			return record.pitcher_stats.starts <= RETIREMENT_LOW_STARTER_MAX
		return record.pitcher_stats.games <= RETIREMENT_LOW_RELIEVER_MAX
	return record.batter_stats.games <= RETIREMENT_LOW_FIELDER_MAX


# 段階的強制引退の確率。39歳以下=0、40歳から線形に上昇し48歳で1.0(確実)。
# 例: 40=0.11, 42=0.33, 44=0.56, 46=0.78, 48=1.0。期待引退年齢 ≒ 44。
static func _forced_retirement_chance(age: int) -> float:
	if age < FORCED_RETIREMENT_RAMP_START_AGE:
		return 0.0
	if age >= FORCED_RETIREMENT_CERTAIN_AGE:
		return 1.0
	return clampf(float(age - (FORCED_RETIREMENT_RAMP_START_AGE - 1)) / float(FORCED_RETIREMENT_CERTAIN_AGE - (FORCED_RETIREMENT_RAMP_START_AGE - 1)), 0.0, 1.0)


static func player_value_score(player: PSPlayer) -> int:
	if player == null:
		return 0
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	return PlayerValueEvaluator.overall_score(record)


# 球団×ポジションの補強需要 = max(0, リーグ平均戦力 - 自軍戦力)。value 単位 (概ね0〜20)。
# 野手 (position 2〜9) は各ポジション「最良1人」= その枠のレギュラーを戦力とする。
# 投手 (position 1) は全員が同一 position に集約されるため、最良1枚 (=エース) で測るとどの球団も
# 同水準で需要がゼロになる。ロスターの投手 depth を反映させるため上位 NEED_PITCHER_DEPTH_SLOTS 枚の
# 平均を投手戦力とし、投手が手薄な球団に position 1 の需要が立つようにする。
# 戦力外獲得・現役ドラフト・FA の各補強AIが共有する単一ソース (以前は FaMarketService と
# ReleasedMarketService に同一実装が重複していた)。
static func position_need(players: Array, teams: Array) -> Dictionary:
	var best_by_team: Dictionary = {}
	var pitcher_values_by_team: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			best_by_team[team.id] = {}
			pitcher_values_by_team[team.id] = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired():
			continue
		if not best_by_team.has(player.team_id):
			continue
		var overall: int = player_value_score(player)
		if player.is_pitcher():
			(pitcher_values_by_team[player.team_id] as Array).append(overall)
		else:
			var pos_map: Dictionary = best_by_team[player.team_id] as Dictionary
			if overall > int(pos_map.get(player.position, 0)):
				pos_map[player.position] = overall
	# 投手 depth (上位 K 枚平均) を各球団の position 1 戦力として best_by_team に載せる。
	for team_id in pitcher_values_by_team.keys():
		(best_by_team[team_id] as Dictionary)[1] = _top_k_mean(pitcher_values_by_team[team_id] as Array, NEED_PITCHER_DEPTH_SLOTS)
	var league_avg: Dictionary = {}
	for pos in range(1, 10):
		var total: float = 0.0
		var count: int = 0
		for team_id in best_by_team.keys():
			total += float((best_by_team[team_id] as Dictionary).get(pos, 0))
			count += 1
		league_avg[pos] = total / float(maxi(1, count))
	var need: Dictionary = {}
	for team_id in best_by_team.keys():
		var pos_need: Dictionary = {}
		var pos_map: Dictionary = best_by_team[team_id] as Dictionary
		for pos in range(1, 10):
			pos_need[pos] = max(0.0, float(league_avg[pos]) - float(pos_map.get(pos, 0)))
		need[team_id] = pos_need
	return need


# 上位 k 枚の value 平均。手薄な球団ほど低くなる (少数しか居なければその平均、空なら0)。
static func _top_k_mean(values: Array, k: int) -> float:
	if values.is_empty() or k <= 0:
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort_custom(func(a, b) -> bool: return int(a) > int(b))
	var take: int = mini(k, sorted.size())
	var total: float = 0.0
	for i in range(take):
		total += float(sorted[i])
	return total / float(take)


# 「今後2〜3年の期待価値」を 1 スカラーに統一したスコア。
# = 現在能力 + 成長期待 (年齢ベース) − 故障リスク。育成降格 / 育成整理の判定軸に使う。
# 出場ベースの戦力外 *選定* (compute_release_candidates_for_team) はこれを使わず従来どおり
# (主力を1年の不振で切らない方針を維持)。
static func future_value_score(player: PSPlayer) -> float:
	if player == null:
		return 0.0
	var current: float = float(player_value_score(player))
	var growth: float = expected_development_score_bonus(player.age, 6, player.position) * FUTURE_GROWTH_WEIGHT
	return current + growth - injury_value_penalty(player)


# 即戦力 (支配下昇格相当) の球団別**相対**基準。支配下 (非育成・非引退) を value 降順に並べ、
# 一軍枠 FIRST_TEAM_SIZE 番目 (= 一軍下位レベル) の value を基準にする。育成の value がこれ以上なら
# 「自軍の一軍選手たちと比べて即戦力」。支配下が枠数未満なら最弱の value。floor/ceiling でクランプ。
# 同オフの昇格/降格判定中は球団構成がほぼ不変なので、各 process_* で球団ごとに1度算出して使い回す。
static func first_team_ready_threshold(players: Array, team_id: int) -> float:
	var values: Array = []
	for player_row in players:
		var p: PSPlayer = player_row as PSPlayer
		if p == null or p.team_id != team_id:
			continue
		if p.is_retired() or p.development_player:
			continue
		values.append(player_value_score(p))
	if values.is_empty():
		return float(PROMOTE_TO_SHIENKA_MIN_VALUE)
	values.sort()  # 昇順
	# 上位 FIRST_TEAM_SIZE の最下位 = 昇順 index (size - FIRST_TEAM_SIZE)。
	var idx: int = max(0, values.size() - FIRST_TEAM_SIZE)
	return clampf(float(values[idx]), PROMOTE_READY_FLOOR, PROMOTE_READY_CEILING)


# 故障リスク減点。残存離脱日数 (injury_days) 30日ごとに ~1 点、上限 INJURY_PENALTY_CAP。
# 恒久能力低下は既に z 能力へ反映済みなので二重減点しない。
static func injury_value_penalty(player: PSPlayer) -> float:
	if player == null or player.injury_days <= 0:
		return 0.0
	return min(float(player.injury_days) / 30.0 * INJURY_PENALTY_PER_30D, INJURY_PENALTY_CAP)


static func development_kind_label(kind: String) -> String:
	return str(GROWTH_KIND_LABELS.get(kind, kind))


static func expected_development_score_bonus(age: int, horizon: int = 6, _position: int = 0) -> float:
	var total: float = 0.0
	var future_weight: float = 1.0
	for offset in range(max(0, horizon)):
		var projected_age: int = age + offset
		var probabilities: Dictionary = _growth_kind_probabilities(projected_age)
		var year_bonus: float = 0.0
		year_bonus += float(probabilities.get(GROWTH_KIND_AWAKENING, 0.0)) * 8.0
		year_bonus += float(probabilities.get(GROWTH_KIND_GROWTH, 0.0)) * 2.6
		year_bonus -= float(probabilities.get(GROWTH_KIND_DECLINE, 0.0)) * 2.0
		year_bonus -= float(probabilities.get(GROWTH_KIND_MAJOR_DECLINE, 0.0)) * 6.0
		total += (year_bonus / 100.0) * future_weight
		future_weight *= 0.86
	return clamp(total, -8.0, 12.0)


# 守備スペクトラムの打撃テール制約。捕手/遊撃 (守備負荷最重量の2位置) の打撃合成
# (Bat_Impact + 0.5*Bat_Loft + Bat_KAvoid + Bat_BBCreate) に上限を置く。
# 現実 (NPB) では C/SS の打撃テールは坂本勇人/阿部慎之助のピーク級 (リーグ4-8位の打力) が上限で、
# 「リーグ最強打者が守備位置補正+守備ランをフルに積む」状況は起きない。上限超過分は
# 4チャンネルを比例縮小して吸収する (WAR テール監査 2026-07-06)。
const FIELDER_BAT_SPECTRUM_CAP_BY_POSITION: Dictionary = {2: 8.0, 6: 8.0}

# 二刀流フロンティア: 打撃合成が高いほど、捕手/内野の守備合成の上限を下げる。
# 現実では打撃 +3σ と premium 守備 +3σ の共存はほぼ存在しない (Witt Jr. 級で10年に1人)。
# 打撃合成 BAT_PIVOT 以下は守備上限 DEF_BASE、超過 1.0 ごとに上限が SLOPE 下がる (下限 DEF_FLOOR)。
const TWO_WAY_DEF_BASE: float = 3.5
const TWO_WAY_BAT_PIVOT: float = 4.0
const TWO_WAY_SLOPE: float = 0.5
const TWO_WAY_DEF_FLOOR: float = 0.8
const TWO_WAY_IF_KEYS: Array = ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange"]
const TWO_WAY_C_KEYS: Array = ["C_Framing", "C_Blocking", "C_Throw", "C_FieldSecure"]
const TWO_WAY_OF_KEYS: Array = ["OF_Reach", "OF_Route", "OF_Secure"]


static func _fielder_bat_spectrum_score(z: Dictionary) -> float:
	return float(z.get("Bat_Impact", 0.0)) + 0.5 * float(z.get("Bat_Loft", 0.0)) \
		+ float(z.get("Bat_KAvoid", 0.0)) + float(z.get("Bat_BBCreate", 0.0))


static func apply_fielder_bat_spectrum_cap(z: Dictionary, position: int) -> void:
	if position == 1:
		return
	if FIELDER_BAT_SPECTRUM_CAP_BY_POSITION.has(position):
		var cap: float = float(FIELDER_BAT_SPECTRUM_CAP_BY_POSITION[position])
		var score: float = _fielder_bat_spectrum_score(z)
		if score > cap and score > 0.0:
			var factor: float = cap / score
			z["Bat_Impact"] = float(z.get("Bat_Impact", 0.0)) * factor
			z["Bat_Loft"] = float(z.get("Bat_Loft", 0.0)) * factor
			z["Bat_KAvoid"] = float(z.get("Bat_KAvoid", 0.0)) * factor
			z["Bat_BBCreate"] = float(z.get("Bat_BBCreate", 0.0)) * factor
	_apply_two_way_frontier(z)


# 打撃合成に応じた premium 守備 (捕手/内野) の上限。超過グループは比例縮小する。
# 守備配置 AI は打撃+守備ブレンドで遊撃などへ動的に置くため、position 列ではなく
# 全野手の z 自体に制約を掛ける必要がある。
static func _apply_two_way_frontier(z: Dictionary) -> void:
	var bat_score: float = _fielder_bat_spectrum_score(z)
	var def_cap: float = TWO_WAY_DEF_BASE - TWO_WAY_SLOPE * max(0.0, bat_score - TWO_WAY_BAT_PIVOT)
	def_cap = max(def_cap, TWO_WAY_DEF_FLOOR)
	for keys_row in [TWO_WAY_IF_KEYS, TWO_WAY_C_KEYS, TWO_WAY_OF_KEYS]:
		var keys: Array = keys_row as Array
		var total: float = 0.0
		for key in keys:
			total += float(z.get(key, 0.0))
		var composite: float = total / float(keys.size())
		if composite <= def_cap or composite <= 0.0:
			continue
		var factor: float = def_cap / composite
		for key in keys:
			z[key] = float(z.get(key, 0.0)) * factor


static func generated_z_abilities(position: int, center: int, max_display: int = 88, ability_variance: int = 12) -> Dictionary:
	var z: Dictionary = {}
	var batting_center: int = center - 12 if position == 1 else center
	var core_variance: int = max(1, ability_variance)
	var secondary_variance: int = max(1, ability_variance - 2)
	var style_variance: int = max(1, ability_variance - 4)
	z["Bat_KAvoid"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_BBCreate"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Impact"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Loft"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Barrel"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Spray"] = _rand_z(batting_center, secondary_variance, 25, max_display)
	z["Bat_Aggression"] = _rand_z(50, style_variance, 25, max_display)
	z["Bat_Platoon"] = _rand_z(50, style_variance, 25, max_display)

	z["Run_Speed"] = _rand_z(batting_center + 5, core_variance, 25, max_display)
	z["Run_Judgment"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Run_Steal"] = _rand_z(batting_center, core_variance, 25, max_display)

	if position == 1:
		z["Pit_KCreate"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_BBPrevent"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_ImpactLimit"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_LoftControl"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_BarrelDeny"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_Efficiency"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_Stamina"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_FatigueResist"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_HoldRunner"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_EdgeRate"] = _rand_z(50, style_variance, 25, max_display)
		z["PF_Reach"] = _rand_z(center, secondary_variance, 25, max_display)
		z["PF_Secure"] = _rand_z(center, secondary_variance, 25, max_display)
		z["PF_Throw"] = _rand_z(center, secondary_variance, 25, max_display)

	z["C_Framing"] = _rand_z(center, core_variance, 25, max_display)
	z["C_Blocking"] = _rand_z(center, core_variance, 25, max_display)
	z["C_Throw"] = _rand_z(center, core_variance, 25, max_display)
	z["C_GameCall"] = _rand_z(center, secondary_variance, 25, max_display)
	z["C_FieldSecure"] = _rand_z(center, core_variance, 25, max_display)

	z["IF_Reach"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_Secure"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_ThrowPower"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_ThrowAccuracy"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_Exchange"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_PositionFit"] = _rand_z(center, secondary_variance, 25, max_display)

	z["OF_Reach"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Route"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Secure"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_ArmPower"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_ArmAccuracy"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Release"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_PositionFit"] = _rand_z(center, secondary_variance, 25, max_display)
	apply_fielder_bat_spectrum_cap(z, position)
	return z


static func generated_raw_abilities(position: int, z_abilities: Dictionary) -> Dictionary:
	var raw: Dictionary = {}
	if position != 1:
		return raw
	raw["max_velocity"] = _generated_max_velocity_from_z(z_abilities)
	return raw


# 投手の変化球アーセナルを生成する。[{ "type": <String>, "mastery": <float z> }, ...]。
#  - 球種数: 持久(=先発度)が高いほど多い (3〜6本)。
#  - 直球を必ず1本含み、残りは投手リーン(K vs ムーブ)に応じた変化球から割当 (PSPitchTypes.assign_types)。
#  - mastery は投手の stuff 系 z (KCreate/BarrelDeny/EdgeRate) にアンカーしノイズを足す
#    (→ エースは良い球種を持ちやすく z と矛盾しない)。スケールは synth mastery と同じ [-2.0, 2.8]。
static func generated_arsenal(position: int, z_abilities: Dictionary) -> Array:
	if position != 1:
		return []
	var k: float = float(z_abilities.get("Pit_KCreate", 0.0))
	var move: float = float(z_abilities.get("Pit_LoftControl", 0.0))
	var barrel_deny: float = float(z_abilities.get("Pit_BarrelDeny", 0.0))
	var edge: float = float(z_abilities.get("Pit_EdgeRate", 0.0))
	var stamina: float = float(z_abilities.get("Pit_Stamina", 0.0))
	# 球種数: 持久連動 (z 0 で約4本、先発級で5〜6、短いリリーフで3) + 軽いジッター。
	var pitch_count: int = clampi(int(round(4.0 + stamina * 0.7 + float(Rng.range_int(-1, 1)))), 3, 6)
	var lean: float = k - move
	var types: Array = PSPitchTypes.assign_types(pitch_count, lean, Rng.range_int(0, 1000000))
	# 出し球(0本目)を最良に、以降は逓減。mastery は stuff 系 z にアンカー。
	var anchor: float = k * 0.5 + barrel_deny * 0.3 + edge * 0.2
	var arsenal: Array = []
	for i in range(pitch_count):
		var noise: float = (Rng.roll_float() - 0.5) * 0.9
		var mastery: float = anchor + 0.35 - float(i) * 0.5 + noise
		arsenal.append({
			"type": str(types[i]) if i < types.size() else PSPitchTypes.FOUR_SEAM,
			"mastery": clampf(mastery, -2.0, 2.8),
		})
	return arsenal


# --- 怪我の繰り越し (越冬回復) ---

# オフシーズンの怪我繰り越し: 当季終了時点の record.injury_days から越冬回復分 (OFFSEASON_RECOVERY_DAYS)
# を引き、残りを持続 player へ書き戻す。翌季の PSPlayerSeasonRecord.from_player が
# injury_days / injury_type / injury_severity をシードするので、長期離脱が翌季へ持ち越される。
# 恒久能力低下は発生時 (PSInjuryModel) に適用済みのため、ここは怪我状態の簿記のみ。
static func process_injury_carryover(players: Array, season: PSSeason) -> Dictionary:
	if season == null:
		return {"carried": 0}
	var carried: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var current_days: int = record.injury_days if record != null else player.injury_days
		var remaining: int = maxi(0, current_days - OFFSEASON_RECOVERY_DAYS)
		player.injury_days = remaining
		if remaining > 0:
			carried += 1
			if record != null:
				player.injury_type = record.injury_type
				player.injury_severity = record.injury_severity
		else:
			player.injury_type = ""
			player.injury_severity = 0
	return {"carried": carried}


# --- STEP 2: Growth / Decay ---

# 全選手を成長/衰え mutate する。集計 (changes/kind_counts/growers/decayers/pitchers/fielders) は
# user_team_id でスコープを絞る:
#   user_team_id <= 0: 全球団を集計 (= 旧挙動。長期オートプレイ等のレポート用呼び出しと後方互換)
#   user_team_id  > 0: その球団のみ集計し、各選手の表示能力 before/after を abilities[] に持たせる
static func process_growth_decay(players: Array, user_team_id: int = 0, season: PSSeason = null) -> Dictionary:
	var want_abilities: bool = user_team_id > 0
	var changes: Array = []
	var kind_counts: Dictionary = _empty_growth_kind_counts()
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var aggregated: bool = user_team_id <= 0 or player.team_id == user_team_id
		var before: int = 0
		var before_ratings: Dictionary = {}
		var before_pitch_changes: Array = []
		var before_aptitudes: Dictionary = {}
		if aggregated:
			before = player_value_score(player)
			if want_abilities:
				before_ratings = _capture_display_ratings(player)
				if player.is_pitcher():
					before_pitch_changes = _capture_pitch_mastery_values(player)
				else:
					before_aptitudes = _capture_position_aptitude_values(player)
		var mutation: Dictionary = _mutate_abilities(player)
		# 守備適性の成長 (本職キャンプ + 試合イニング)。season から当該シーズンの record を引いて
		# 守備イニングを参照する。season 無し (レポート/smoke 等) では適性成長はスキップ。
		if season != null:
			var apt_record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
			apply_position_aptitude_growth(player, apt_record)
		if not aggregated:
			continue
		var growth_kind: String = str(mutation.get("kind", GROWTH_KIND_STAGNATION))
		kind_counts[growth_kind] = int(kind_counts.get(growth_kind, 0)) + 1
		var after: int = player_value_score(player)
		var pitch_changes: Array = []
		var aptitude_changes: Dictionary = {}
		if want_abilities:
			if player.is_pitcher():
				pitch_changes = _build_pitch_mastery_changes(before_pitch_changes, _capture_pitch_mastery_values(player))
			else:
				aptitude_changes = _build_position_aptitude_changes(before_aptitudes, _capture_position_aptitude_values(player))
		var detail_changed: bool = _detail_array_has_delta(pitch_changes) or _detail_dict_has_delta(aptitude_changes)
		if before == after and not detail_changed:
			continue
		var change: Dictionary = {
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": player.team_id,
			"position": player.position,
			"is_pitcher": player.is_pitcher(),
			"before": before,
			"after": after,
			"delta": after - before,
			"growth_kind": growth_kind,
			"growth_label": development_kind_label(growth_kind),
			"changed_keys": int(mutation.get("changed_keys", 0)),
			"net_z_delta": float(mutation.get("net_z_delta", 0.0)),
		}
		if want_abilities:
			change["abilities"] = _build_ability_changes(before_ratings, _capture_display_ratings(player))
			if player.is_pitcher():
				change["pitch_changes"] = pitch_changes
			else:
				change["aptitude_changes"] = aptitude_changes
		changes.append(change)

	var growers: Array = []
	var decayers: Array = []
	var pitchers: Array = []
	var fielders: Array = []
	for change_row in changes:
		var change: Dictionary = change_row as Dictionary
		if int(change["delta"]) > 0:
			growers.append(change)
		elif int(change["delta"]) < 0:
			decayers.append(change)
		if bool(change.get("is_pitcher", false)):
			pitchers.append(change)
		else:
			fielders.append(change)

	var delta_desc: Callable = func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) > int((b as Dictionary)["delta"])
	growers.sort_custom(delta_desc)
	decayers.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) < int((b as Dictionary)["delta"])
	)
	pitchers.sort_custom(delta_desc)
	fielders.sort_custom(delta_desc)

	return {
		"growers": growers.slice(0, 20),
		"decayers": decayers.slice(0, 20),
		"growers_count": growers.size(),
		"decayers_count": decayers.size(),
		"growth_kind_counts": kind_counts,
		"pitchers": pitchers,
		"fielders": fielders,
	}


# 守備適性のオフシーズン成長を player.position_aptitudes に書き戻す。
#  - 本職: 毎オフ +CAMP_PRIMARY_APTITUDE_GAIN (上限 100)。
#  - 各ポジ: そのシーズンに守った守備イニング × APTITUDE_GAIN_PER_INNING (上限 100)。
# record が無い (= 試合をしていない) 場合は本職キャンプ分のみ。投手 (pos 1) は対象外。
static func apply_position_aptitude_growth(player: PSPlayer, record: PSPlayerSeasonRecord) -> void:
	if player == null or player.position == 1:
		return
	var apt: Dictionary = player.position_aptitudes
	var primary_key: String = str(POSITION_NAME_BY_ID.get(player.position, ""))
	if not primary_key.is_empty():
		apt[primary_key] = mini(APTITUDE_MAX, int(apt.get(primary_key, 0)) + CAMP_PRIMARY_APTITUDE_GAIN)
	if record == null:
		return
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var innings: float = record.defensive_innings_at(position)
		if innings <= 0.0:
			continue
		var key: String = str(POSITION_NAME_BY_ID.get(position, ""))
		if key.is_empty():
			continue
		var gain: int = int(round(innings * APTITUDE_GAIN_PER_INNING))
		if gain <= 0:
			continue
		apt[key] = mini(APTITUDE_MAX, int(apt.get(key, 0)) + gain)


# 選手の表示能力 (球速/球質/巧打/長打…) を key -> {label, suffix, value} のマップにする。
static func _capture_display_ratings(player: PSPlayer) -> Dictionary:
	var result: Dictionary = PSPlayerVisibleRatings.ratings_for_player(player)
	var map: Dictionary = {}
	for row_value in result.get("display_ratings", []) as Array:
		var row: Dictionary = row_value as Dictionary
		map[str(row.get("key", ""))] = {
			"label": str(row.get("label", "")),
			"suffix": str(row.get("suffix", "")),
			"value": int(row.get("display_value", row.get("value", 0))),
		}
	return map


# before/after の表示能力マップから [{label, suffix, after, delta}, ...] を after の定義順で組む。
static func _build_ability_changes(before_map: Dictionary, after_map: Dictionary) -> Array:
	var out: Array = []
	for key_value in after_map.keys():
		var key: String = str(key_value)
		var after_entry: Dictionary = after_map[key_value] as Dictionary
		var after_val: int = int(after_entry.get("value", 0))
		var before_val: int = int((before_map.get(key, {}) as Dictionary).get("value", after_val))
		out.append({
			"key": key,
			"label": str(after_entry.get("label", "")),
			"suffix": str(after_entry.get("suffix", "")),
			"after": after_val,
			"delta": after_val - before_val,
		})
	return out


static func _capture_pitch_mastery_values(player: PSPlayer) -> Array:
	var mastery_by_type: Dictionary = {}
	for entry_value in player.arsenal:
		var entry: Dictionary = entry_value as Dictionary
		mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
	var out: Array = []
	for type_value in PSPitchTypes.ALL_TYPES:
		var type_key: String = str(type_value)
		out.append(PSAbilityScale.z_to_display(float(mastery_by_type[type_key])) if mastery_by_type.has(type_key) else -1)
	return out


static func _build_pitch_mastery_changes(before_values: Array, after_values: Array) -> Array:
	var out: Array = []
	for i in range(after_values.size()):
		var after: int = int(after_values[i])
		var before: int = int(before_values[i]) if i < before_values.size() else after
		out.append({"after": after, "delta": (after - before) if after >= 0 and before >= 0 else 0})
	return out


static func _capture_position_aptitude_values(player: PSPlayer) -> Dictionary:
	var out: Dictionary = {}
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var key: String = str(POSITION_NAME_BY_ID.get(position, ""))
		out[position] = int(player.position_aptitudes.get(key, 0)) if not key.is_empty() else 0
	return out


static func _build_position_aptitude_changes(before_values: Dictionary, after_values: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var after: int = int(after_values.get(position, 0))
		var before: int = int(before_values.get(position, after))
		if after > 0 or after != before:
			out[position] = {"after": after, "delta": after - before}
	return out


static func _detail_array_has_delta(rows: Array) -> bool:
	for row_value in rows:
		if int((row_value as Dictionary).get("delta", 0)) != 0:
			return true
	return false


static func _detail_dict_has_delta(rows: Dictionary) -> bool:
	for row_value in rows.values():
		if int((row_value as Dictionary).get("delta", 0)) != 0:
			return true
	return false


static func _mutate_abilities(player: PSPlayer) -> Dictionary:
	var growth_kind: String = _choose_growth_kind(player)
	var keys_to_mutate: Array = _development_keys_for_player(player)
	var changed_keys: int = 0
	var net_z_delta: float = 0.0
	var raw_velocity_delta: int = 0
	for key_variant in keys_to_mutate:
		var key: String = str(key_variant)
		var d_z: float = _growth_delta_z(growth_kind, player.age, key)
		if absf(d_z) < 0.005:
			continue
		var current: float = float(player.z_abilities.get(key, 0.0))
		player.z_abilities[key] = clamp(current + d_z, Z_ABILITY_MIN, Z_ABILITY_MAX)
		changed_keys += 1
		net_z_delta += d_z
	if player.is_pitcher():
		raw_velocity_delta = _growth_delta_velocity(growth_kind, player.age)
		if raw_velocity_delta != 0:
			var current_velocity: int = int(round(float(player.raw_abilities.get("max_velocity", _generated_max_velocity_from_z(player.z_abilities)))))
			player.raw_abilities["max_velocity"] = clampi(current_velocity + raw_velocity_delta, RAW_MAX_VELOCITY_MIN, RAW_MAX_VELOCITY_MAX)
			changed_keys += 1
	else:
		# 成長で守備 z が上がり続けると、生成時の二刀流フロンティア (打撃エリートは premium 守備
		# を持てない) を数年で突き破り、10+ WAR の両刀スターが再発する。成長後にも同じ上限を保つ。
		# 位置別の打撃キャップ (C/SS) は既存スターの打撃を削る方向なので成長時には適用しない。
		_apply_two_way_frontier(player.z_abilities)
	return {
		"kind": growth_kind,
		"label": development_kind_label(growth_kind),
		"changed_keys": changed_keys,
		"net_z_delta": net_z_delta,
		"raw_velocity_delta": raw_velocity_delta,
	}


static func _development_keys_for_player(player: PSPlayer) -> Array:
	var keys_to_mutate: Array = []
	if player.is_pitcher():
		keys_to_mutate.append_array(PSPlayer.Z_PITCHER_ABILITY_KEYS.keys())
	else:
		keys_to_mutate.append_array(PSPlayer.Z_BATTER_ABILITY_KEYS.keys())
		keys_to_mutate.append_array(PSPlayer.Z_RUNNING_ABILITY_KEYS.keys())
	var category: String = PSPlayer.fielding_ability_category_for_position(player.position)
	match category:
		"catcher":
			keys_to_mutate.append_array(PSPlayer.Z_CATCHER_ABILITY_KEYS.keys())
		"infield":
			keys_to_mutate.append_array(PSPlayer.Z_INFIELD_ABILITY_KEYS.keys())
		"outfield":
			keys_to_mutate.append_array(PSPlayer.Z_OUTFIELD_ABILITY_KEYS.keys())
	return keys_to_mutate


static func _choose_growth_kind(player: PSPlayer) -> String:
	var age: int = 0 if player == null else player.age
	var probabilities: Dictionary = _growth_kind_probabilities(age)
	var roll: float = Rng.roll_float() * 100.0
	var acc: float = 0.0
	for kind in GROWTH_KIND_ORDER:
		acc += float(probabilities.get(kind, 0.0))
		if roll <= acc:
			return str(kind)
	return GROWTH_KIND_STAGNATION


static func _growth_kind_probabilities(age: int) -> Dictionary:
	var normalized_age: int = _growth_curve_age(age)
	var major_decline: float = _major_decline_chance(normalized_age)
	var decline: float = _decline_chance(normalized_age)
	var stagnation: float = _stagnation_chance(normalized_age)
	var growth: float = _growth_chance(normalized_age)
	var awakening: float = _awakening_chance(normalized_age)
	return {
		GROWTH_KIND_AWAKENING: awakening,
		GROWTH_KIND_GROWTH: growth,
		GROWTH_KIND_STAGNATION: stagnation,
		GROWTH_KIND_DECLINE: decline,
		GROWTH_KIND_MAJOR_DECLINE: major_decline,
	}


static func _growth_curve_age(age: int) -> int:
	return 19 if age <= 18 else age


static func _major_decline_chance(age: int) -> float:
	if age >= 40:
		return 35.0
	match age:
		29:
			return 1.0
		30:
			return 3.0
		31:
			return 5.0
		32:
			return 8.0
		33:
			return 13.0
		34:
			return 15.0
		35:
			return 18.0
		36:
			return 20.0
		37:
			return 23.0
		38:
			return 27.0
		39:
			return 30.0
	return 0.0


static func _decline_chance(age: int) -> float:
	if age >= 40:
		return 60.0
	match age:
		27:
			return 5.0
		28:
			return 12.0
		29:
			return 19.0
		30:
			return 24.0
		31:
			return 31.0
		32:
			return 37.0
		33:
			return 42.0
		34:
			return 47.0
		35:
			return 50.0
		36, 37, 38, 39:
			return 65.0
	return 0.0


static func _stagnation_chance(age: int) -> float:
	if age >= 40:
		return 5.0
	match age:
		23, 24, 25:
			return 39.0
		27:
			return 45.0
		28:
			return 49.0
		29, 30:
			return 50.0
		31:
			return 49.0
		32:
			return 45.0
		33:
			return 40.0
		34:
			return 35.0
		35:
			return 30.0
		36:
			return 14.0
		37:
			return 12.0
		38:
			return 8.0
		39:
			return 5.0
	return 40.0


static func _growth_chance(age: int) -> float:
	if age >= 40:
		return 0.0
	match age:
		23, 24, 25:
			return 60.0
		27:
			return 49.0
		28:
			return 38.0
		29:
			return 29.0
		30:
			return 23.0
		31:
			return 15.0
		32:
			return 10.0
		33:
			return 5.0
		34:
			return 3.0
		35:
			return 2.0
		36:
			return 1.0
		37, 38, 39:
			return 0.0
	return 59.0


static func _awakening_chance(age: int) -> float:
	return 1.0 if age <= 29 else 0.0


static func _growth_delta_z(kind: String, age: int, key: String) -> float:
	var roll: int = Rng.roll_percent()
	var delta: float = 0.0
	match kind:
		GROWTH_KIND_AWAKENING:
			if roll <= 8:
				delta = -_range_float(0.02, 0.08)
			else:
				delta = _range_float(0.08, 0.28)
				if Rng.roll_percent() <= 20:
					delta += _range_float(0.06, 0.16)
		GROWTH_KIND_GROWTH:
			if roll <= 12:
				delta = -_range_float(0.02, 0.08)
			elif roll <= 28:
				delta = _range_float(-0.015, 0.035)
			elif roll <= 78:
				delta = _range_float(0.035, 0.12)
			else:
				delta = _range_float(0.12, 0.22)
		GROWTH_KIND_STAGNATION:
			if roll <= 12:
				delta = -_range_float(0.01, 0.04)
			elif roll <= 24:
				delta = _range_float(0.01, 0.04)
			else:
				delta = 0.0
		GROWTH_KIND_DECLINE:
			if roll <= 10:
				delta = _range_float(0.01, 0.05)
			elif roll <= 28:
				delta = _range_float(-0.03, 0.02)
			else:
				delta = -_range_float(0.05, 0.18)
		GROWTH_KIND_MAJOR_DECLINE:
			if roll <= 8:
				delta = _range_float(0.01, 0.04)
			elif roll <= 20:
				delta = -_range_float(0.04, 0.10)
			else:
				delta = -_range_float(0.12, 0.36)
		_:
			delta = 0.0
	delta *= _growth_key_multiplier(kind, age, key)
	delta *= GROWTH_DELTA_SCALE
	if absf(delta) < 0.005:
		return 0.0
	return delta


static func _growth_delta_velocity(kind: String, age: int) -> int:
	var roll: int = Rng.roll_percent()
	match kind:
		GROWTH_KIND_AWAKENING:
			if age <= 23 and roll <= 20:
				return 3
			if age <= 25 and roll <= 48:
				return 2
			return 1
		GROWTH_KIND_GROWTH:
			if age <= 26 and roll <= 24:
				return 2
			if age <= 28 and roll <= 18:
				return 1
			if age >= 31 and roll <= 16:
				return -1
		GROWTH_KIND_DECLINE:
			if age >= 33 and roll <= 18:
				return -2
			if age >= 30 and roll <= 34:
				return -1
		GROWTH_KIND_MAJOR_DECLINE:
			if age >= 33 and roll <= 28:
				return -3
			if age >= 29 and roll <= 60:
				return -2
			return -1
	return 0


static func _generated_max_velocity_from_z(z_abilities: Dictionary) -> int:
	# 球速生成: エース度 (Pit_KCreate) を基準に 140 起点で緩やかに上げる。
	# 大半が 140〜150 に収まり、上振れロールでのみ 150台、稀に 155〜160 に届く。
	var k_create_display: int = PSAbilityScale.z_to_display(float(z_abilities.get("Pit_KCreate", 0.0)))
	var velocity: float = 140.0 + float(max(0, k_create_display - 50)) * 0.18 + float(Rng.range_int(-1, 3))
	# 中程度の上振れ: 約12%で +3〜7 (150台前半をそこそこ出す)。
	if Rng.roll_percent() <= 12:
		velocity += float(Rng.range_int(3, 7))
	# 強い上振れ: 約2%で +8〜17 (155〜160 を稀に出す。160 は中程度上振れと重なった時のみ)。
	if Rng.roll_percent() <= 2:
		velocity += float(Rng.range_int(8, 17))
	return clampi(int(round(velocity)), GEN_MAX_VELOCITY_MIN, GEN_MAX_VELOCITY_MAX)


static func _growth_key_multiplier(kind: String, age: int, key: String) -> float:
	var multiplier: float = 1.0
	var is_decline_kind: bool = [GROWTH_KIND_DECLINE, GROWTH_KIND_MAJOR_DECLINE].has(kind)
	if ["Bat_Aggression", "Bat_Platoon", "Pit_EdgeRate", "C_GameCall", "IF_PositionFit", "OF_PositionFit"].has(key):
		multiplier *= 0.75
	if key.begins_with("Run_") and age >= 28:
		multiplier *= 1.25 if is_decline_kind else 0.85
	if ["Pit_Stamina", "Pit_FatigueResist"].has(key) and age >= 31:
		multiplier *= 1.15 if is_decline_kind else 0.90
	if kind == GROWTH_KIND_AWAKENING and ["Bat_Barrel", "Bat_Impact", "Bat_BBCreate", "Pit_KCreate", "Pit_BBPrevent", "Pit_BarrelDeny"].has(key):
		multiplier *= 1.10
	return multiplier


static func _empty_growth_kind_counts() -> Dictionary:
	var counts: Dictionary = {}
	for kind in GROWTH_KIND_ORDER:
		counts[str(kind)] = 0
	return counts


# --- 契約更新: 延長交渉 (国内選手の複数年契約、契約市場/FA複数年オファーの発生源に続く3本目) ---
# 対象は contract_status が「FA権間近」「FA可能」の非外国人・非育成・非ロック選手のうち、
# player_value_score がこの水準以上の主力級。1球団あたりプールは価値降順で上限までに絞る。
const EXTENSION_MIN_VALUE: int = 60
const EXTENSION_POOL_MAX_PER_TEAM: int = 5
# 提示年俸 = 市場価値 (foreign_market_salary) × (1 + プレミアム×(年数-1))。外国人契約市場の
# FOREIGN_MULTI_YEAR_PREMIUM と同じ考え方 (複数年ほど選手側に有利な年俸を積む)。
const EXTENSION_SALARY_PREMIUM: float = 0.05
# 受諾確率の基準値。年数ボーナス/年俸プレミアム加点、FA宣言意欲ペナルティを加減して clamp する。
const EXTENSION_BASE_ACCEPT: float = 0.55
const EXTENSION_ACCEPT_CHANCE_MIN: float = 0.05
const EXTENSION_ACCEPT_CHANCE_MAX: float = 0.95
# 提示年俸が市場価値を上回る分の加点上限 (FaMarketService._contract_success_chance の同種加点と同スケール)。
const EXTENSION_SALARY_BONUS_MAX: float = 0.10
const EXTENSION_SALARY_BONUS_DIVISOR: float = 50000.0
# FA宣言意欲 (FaMarketService._declaration_chance) が高い選手ほど、引き留めても心変わりしやすい
# と見なして受諾確率から差し引く係数。declaration_chance (0.02〜0.30 程度) にそのまま乗じる。
const EXTENSION_DECLARE_PENALTY: float = 1.0
# CPU球団が1オフに提示できる延長件数の上限 (自球団もこの基準で自動判断されうる、下記参照)。
const CPU_EXTENSION_MAX_PER_YEAR: int = 2


# 延長交渉候補プール ({player_id, team_id, name, age, position, role, value, current_salary,
# market_salary, max_years, declare_chance, user_offer:{}, resolved:false, accepted:false}) を
# value 降順・1球団あたり EXTENSION_POOL_MAX_PER_TEAM 件までに絞って構築する。
static func _build_extension_pool(players: Array, teams: Array, season: PSSeason, year: int) -> Array:
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var entries: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired() or player.foreign_player or player.development_player:
			continue
		if player.team_id <= 0:
			continue
		if player.contract_status != "FA権間近" and player.contract_status != "FA可能":
			continue
		if player.is_multi_year_locked_offseason(year):
			continue
		if int(player.source_data.get("extension_refused_year", 0)) == year:
			continue
		var max_years: int = FaMarketService.fa_offer_max_years(player.age)
		if max_years < 2:
			continue
		var value: int = player_value_score(player)
		if value < EXTENSION_MIN_VALUE:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var war: float = _season_war(record, league_ctx)
		entries.append({
			"player_id": player.id,
			"team_id": player.team_id,
			"name": player.name,
			"age": player.age,
			"position": player.position,
			"role": player.role,
			"value": value,
			"current_salary": player.salary,
			"market_salary": foreign_market_salary(player, record, war),
			"max_years": max_years,
			"declare_chance": FaMarketService._declaration_chance(player, year),
			"user_offer": {},
			"resolved": false,
			"accepted": false,
		})
	entries.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) != int(db.get("value", 0)):
			return int(da.get("value", 0)) > int(db.get("value", 0))
		return float(da.get("declare_chance", 0.0)) > float(db.get("declare_chance", 0.0))
	)
	var per_team_count: Dictionary = {}
	var limited: Array = []
	for entry_row in entries:
		var entry: Dictionary = entry_row as Dictionary
		var team_id: int = int(entry.get("team_id", 0))
		var count: int = int(per_team_count.get(team_id, 0))
		if count >= EXTENSION_POOL_MAX_PER_TEAM:
			continue
		per_team_count[team_id] = count + 1
		limited.append(entry)
	return limited


static func _extension_offer_salary(market_salary: int, years: int) -> int:
	var raw: int = int(round(float(market_salary) * (1.0 + EXTENSION_SALARY_PREMIUM * float(maxi(1, years) - 1))))
	return round_salary_2sig(raw)


# 受諾確率 = 基準値 + 年数ボーナス (FaMarketService.FA_SIGN_YEARS_BONUS と同係数を共用) +
# 提示年俸の市場価値超過分の加点 − FA宣言意欲ペナルティ。
static func _extension_success_chance(years: int, offer_salary: int, market_salary: int, declare_chance: float) -> float:
	var chance: float = EXTENSION_BASE_ACCEPT
	chance += min(FaMarketService.FA_SIGN_YEARS_BONUS_MAX, float(maxi(1, years) - 1) * FaMarketService.FA_SIGN_YEARS_BONUS)
	chance += min(EXTENSION_SALARY_BONUS_MAX, max(0.0, float(offer_salary - market_salary)) / EXTENSION_SALARY_BONUS_DIVISOR)
	chance -= declare_chance * EXTENSION_DECLARE_PENALTY
	return clampf(chance, EXTENSION_ACCEPT_CHANCE_MIN, EXTENSION_ACCEPT_CHANCE_MAX)


# CPU (自球団含む、下記 finalize_contract_extensions 参照) の既定提示年数。年齢上限まで提示する
# (長期保証で主力を確実に引き留める想定)。
static func _cpu_extension_years(entry: Dictionary) -> int:
	return maxi(2, int(entry.get("max_years", 2)))


static func _extension_entry_by_player_id(state: Dictionary, player_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("player_id", 0)) == player_id:
			return entry
	return {}


# ユーザーの延長提示。自球団の候補のみ、年数は [2, max_years] にクランプする。1回勝負
# (resolved 後の再提示は拒否、拒否された選手は同オフ中 candidates に戻らない)。
static func submit_extension_offer(state: Dictionary, players: Array, teams: Array, user_team_id: int, player_id: int, years: int) -> Dictionary:
	if str(state.get("phase", "extension")) != "extension":
		return {"ok": false, "message": "延長交渉は既に終了しています。", "state": state}
	var entry: Dictionary = _extension_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は延長交渉の対象ではありません。", "state": state}
	if bool(entry.get("resolved", false)):
		return {"ok": false, "message": "その選手との交渉は既に終了しています。", "state": state}
	if int(entry.get("team_id", 0)) != user_team_id:
		return {"ok": false, "message": "自球団の選手のみ延長交渉できます。", "state": state}
	var max_years: int = int(entry.get("max_years", 2))
	var clamped_years: int = clampi(years, 2, maxi(2, max_years))
	var offer_salary: int = _extension_offer_salary(int(entry.get("market_salary", 0)), clamped_years)
	var player: PSPlayer = _find_player_by_id(players, player_id)
	var team: PSTeam = _find_team_by_id(teams, user_team_id)
	var delta: int = maxi(0, offer_salary - (player.salary if player != null else 0))
	if not TeamFinance.can_afford_addition(players, team, delta):
		return {"ok": false, "message": "予算が不足しているため延長を提示できません。", "state": state}
	entry["user_offer"] = {"years": clamped_years, "salary": offer_salary}
	return {"ok": true, "state": state}


static func withdraw_extension_offer(state: Dictionary, player_id: int) -> Dictionary:
	var entry: Dictionary = _extension_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は延長交渉の対象ではありません。", "state": state}
	entry["user_offer"] = {}
	return {"ok": true, "state": state}


static func _apply_extension(player: PSPlayer, years: int, salary: int, year: int) -> void:
	player.salary = salary
	player.source_data["contract_end_year"] = year + years
	player.source_data["contract_total_years"] = years
	player.source_data["contract_signed_year"] = year
	player.source_data.erase("extension_refused_year")
	PSCareerLog.log_contract_extension(player, year, player.team_id, salary, years)


# 未解決の候補 (ユーザー提示済み、または未提示=CPU基準で自動判断) を一括解決する。
# 自球団の未提示候補も含め全球団を同じ基準で扱う (外国人契約市場 finalize と同じ設計、
# 何もしなければCPU同様に自動判断される穏当なデフォルト)。CPU提示は1球団あたり
# CPU_EXTENSION_MAX_PER_YEAR件までで、候補は value 降順・declare_chance 降順の優先順で消費する。
static func _resolve_remaining_extension_candidates(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	var year: int = int(state.get("year", season.year if season != null else 0))
	var candidates: Array = state.get("candidates", []) as Array
	var extension_signings: Array = state.get("extension_signings", []) as Array
	var cpu_counts: Dictionary = {}
	for entry_row in candidates:
		var entry: Dictionary = entry_row as Dictionary
		if bool(entry.get("resolved", false)):
			continue
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if player == null:
			entry["resolved"] = true
			continue
		var team_id: int = int(entry.get("team_id", 0))
		var user_offer: Dictionary = entry.get("user_offer", {}) as Dictionary
		var years: int
		var offer_salary: int
		var method: String
		if not user_offer.is_empty():
			years = maxi(2, int(user_offer.get("years", 2)))
			offer_salary = int(user_offer.get("salary", entry.get("market_salary", 0)))
			method = "user"
		else:
			if int(cpu_counts.get(team_id, 0)) >= CPU_EXTENSION_MAX_PER_YEAR:
				entry["resolved"] = true
				continue
			years = _cpu_extension_years(entry)
			offer_salary = _extension_offer_salary(int(entry.get("market_salary", 0)), years)
			var team: PSTeam = _find_team_by_id(teams, team_id)
			var delta: int = maxi(0, offer_salary - player.salary)
			if team == null or not TeamFinance.can_afford_addition(players, team, delta):
				entry["resolved"] = true
				continue
			cpu_counts[team_id] = int(cpu_counts.get(team_id, 0)) + 1
			method = "cpu"
		var chance: float = _extension_success_chance(years, offer_salary, int(entry.get("market_salary", 0)), float(entry.get("declare_chance", 0.0)))
		entry["resolved"] = true
		entry["offer_years"] = years
		entry["offer_salary"] = offer_salary
		entry["success_chance"] = chance
		entry["method"] = method
		if Rng.roll_float() <= chance:
			_apply_extension(player, years, offer_salary, year)
			entry["accepted"] = true
			extension_signings.append({
				"player_id": player.id, "name": player.name, "age": player.age,
				"position": player.position, "role": player.role,
				"team_id": team_id, "from_team": team_id, "to_team": team_id,
				"salary": player.salary, "offer_salary": player.salary, "contract_years": years,
				"value": int(entry.get("value", 0)), "method": method, "success_chance": chance,
			})
		else:
			entry["accepted"] = false
			player.source_data["extension_refused_year"] = year
	state["candidates"] = candidates
	state["extension_signings"] = extension_signings


# 契約更新state (延長候補プール構築済み) を受け取り、未解決分を解決してから年俸再査定+予算会計を行う。
# 二重実行防止: finalized なら結果をキャッシュから返す (再査定・延長解決は一度だけ)。
static func finalize_contract_extensions(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	if str(state.get("phase", "extension")) == "extension":
		_resolve_remaining_extension_candidates(state, players, teams, season)
	var result: Dictionary = _finalize_salary_and_budget(state, players, teams, season)
	state["phase"] = "done"
	state["complete"] = true
	state["finalized"] = true
	state["final_result"] = result
	return result


# 延長解決後の年俸再査定 (ロック中=延長成立済み含むはスキップ) + 予算会計。
static func _finalize_salary_and_budget(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var year: int = int(state.get("year", season.year if season != null else 0))
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var changes: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var war: float = _season_war(record, league_ctx)
		var old_salary: int = player.salary
		var skip_salary_update: bool = _contract_salary_is_locked(player, year)
		if not skip_salary_update:
			var new_salary: int = _compute_new_salary(player, record, war)
			if new_salary != old_salary:
				player.salary = new_salary
				PSCareerLog.log_salary(player, year, new_salary)
				changes.append({
					"player_id": player.id,
					"name": player.name,
					"age": player.age,
					"team_id": player.team_id,
					"position": player.position,
					"role": player.role,
					"old_salary": old_salary,
					"new_salary": new_salary,
					"delta": new_salary - old_salary,
				})

	var raises: Array = []
	var cuts: Array = []
	for change_row in changes:
		var change: Dictionary = change_row as Dictionary
		if int(change["delta"]) > 0:
			raises.append(change)
		else:
			cuts.append(change)

	raises.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) > int((b as Dictionary)["delta"])
	)
	cuts.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) < int((b as Dictionary)["delta"])
	)

	var new_fa: Array = (state.get("new_fa", []) as Array).duplicate(true)
	new_fa.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["team_id"]) == int(db["team_id"]):
			return int(da["age"]) > int(db["age"])
		return int(da["team_id"]) < int(db["team_id"])
	)

	var team_budgets: Array = []
	var over_budget_count: int = 0
	if teams != null:
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			var payroll: int = TeamFinance.team_payroll(players, team.id)
			var over: bool = TeamFinance.is_over_budget(team.funds, payroll)
			if over:
				over_budget_count += 1
			team_budgets.append({
				"team_id": team.id,
				"name": team.name,
				"funds": team.funds,
				"payroll": payroll,
				"room": TeamFinance.budget_room(team.funds, payroll),
				"over_budget": over,
			})
		team_budgets.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary)["team_id"]) < int((b as Dictionary)["team_id"])
		)

	var extension_signings: Array = state.get("extension_signings", []) as Array
	var extension_accepted: int = 0
	for row in extension_signings:
		if bool((row as Dictionary).get("accepted", true)):
			extension_accepted += 1
	var extension_offers: int = 0
	for row in state.get("candidates", []) as Array:
		if bool((row as Dictionary).get("resolved", false)):
			extension_offers += 1

	return {
		"raises": raises.slice(0, 20),
		"cuts": cuts.slice(0, 20),
		"raises_count": raises.size(),
		"cuts_count": cuts.size(),
		"new_fa": new_fa,
		"new_fa_count": new_fa.size(),
		"team_budgets": team_budgets,
		"over_budget_count": over_budget_count,
		"extension_signings": extension_signings,
		"extension_signings_count": extension_signings.size(),
		"extension_offers_count": extension_offers,
		"extension_accepted_count": extension_accepted,
	}


# 契約更新state: Phase A (FA日数accrue + contract_status遷移 + 延長交渉候補プール構築) を実行する。
# 候補ゼロなら Phase B (年俸再査定+予算会計) を即実行し phase="done" で返す (対話パネル不要)。
# 候補があれば phase="extension" で停止し、submit_extension_offer / finalize_contract_extensions
# を経て確定する (外国人契約市場の contract/scout 2フェーズ設計と同じパターン)。
static func create_contract_update_state(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var year: int = season.year if season != null else 0
	if season != null and teams != null:
		var team_ids: Array = []
		for team_row in teams:
			var team_for_days: PSTeam = team_row as PSTeam
			if team_for_days != null:
				team_ids.append(team_for_days.id)
		season.accrue_all_active_roster_days(team_ids, season.current_day)
	var new_fa: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		_apply_fa_service_days(player, record, season)
		var was_fa: bool = player.contract_status == "FA可能"
		var new_status: String = _contract_status_for(player)
		if new_status != player.contract_status:
			player.contract_status = new_status
		if new_status == "FA可能" and not was_fa:
			player.source_data["fa_eligible_year"] = year
			player.source_data["fa_pass_count"] = 0
			new_fa.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": player.team_id,
				"position": player.position,
				"role": player.role,
				"years": player.years,
				"fa_eligible_years": player.fa_eligible_years,
				"fa_nissuu": player.fa_service_days(),
			})
		elif new_status == "FA可能" and not player.source_data.has("fa_eligible_year"):
			var years_since_eligible: int = int(floor(float(maxi(0, player.fa_service_days() - player.fa_service_days_required())) / float(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))
			player.source_data["fa_eligible_year"] = year - years_since_eligible
			player.source_data["fa_pass_count"] = maxi(0, years_since_eligible)

	var candidates: Array = _build_extension_pool(players, teams, season, year)
	var state: Dictionary = {
		"version": 1,
		"phase": "extension" if not candidates.is_empty() else "done",
		"year": year,
		"user_team_id": user_team_id,
		"complete": candidates.is_empty(),
		"finalized": false,
		"new_fa": new_fa,
		"candidates": candidates,
		"extension_signings": [],
	}
	if candidates.is_empty():
		var result: Dictionary = _finalize_salary_and_budget(state, players, teams, season)
		state["finalized"] = true
		state["final_result"] = result
	return state


# 完全自動ラッパー (CPU長期検証/レポーター/旧テスト互換用)。延長交渉は候補全員をCPU基準で
# 自動解決してから年俸再査定+予算会計まで一括で終える。
static func process_contract_update(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_contract_update_state(players, teams, season, user_team_id)
	return finalize_contract_extensions(state, players, teams, season)


# --- STEP 5 (R4): 契約更新 (年俸再査定 + FA権遷移 + 予算会計) ---
# 実装は create_contract_update_state / finalize_contract_extensions / process_contract_update
# (上記「契約更新: 延長交渉」節) に集約。ここには契約ロック判定など共有ヘルパーのみ残す。

# 年俸再査定をスキップすべきか。FA移籍・戦力外獲得で今オフに合意した単年ロック (翌オフには
# 通常の成績査定へ戻る) と、複数年契約でカバーされている年 (契約満了年の
# オフは対象外、PSPlayer.is_multi_year_locked_offseason 参照) の OR。
static func _contract_salary_is_locked(player: PSPlayer, year: int) -> bool:
	if year <= 0:
		return false
	var fa_locked: bool = int(player.source_data.get("fa_signed_year", 0)) == year and player.source_data.has("fa_contract_salary")
	var released_locked: bool = int(player.source_data.get("released_signed_year", 0)) == year and player.source_data.has("released_contract_salary")
	return fa_locked or released_locked or player.is_multi_year_locked_offseason(year)


# 1軍登録日数と FA閾値から contract_status を決める。
#   fa_nissuu >= fa_eligible_years*145 → "FA可能" (FA権取得済み = 保有権消滅)
#   残り1年相当以下                    → "FA権間近" (延長交渉の起点)
#   それ以外                           → "通常"
static func _contract_status_for(player: PSPlayer) -> String:
	if player.is_fa_eligible():
		return "FA可能"
	if player.fa_remaining_years() == 1:
		return "FA権間近"
	return "通常"


static func _apply_fa_service_days(player: PSPlayer, record: PSPlayerSeasonRecord, season: PSSeason) -> void:
	if player == null:
		return
	if not player.source_data.has("fa_nissuu"):
		var completed_years_estimate: int = maxi(0, player.years)
		if season != null:
			completed_years_estimate = maxi(0, player.years - 1)
		player.source_data["fa_nissuu"] = completed_years_estimate * PSPlayer.FA_SERVICE_DAYS_PER_YEAR
	if season == null or season.year <= 0:
		return
	if int(player.source_data.get("fa_days_accrued_year", 0)) == season.year:
		return
	var service_team_id: int = player.team_id
	if record != null and record.team_id > 0:
		service_team_id = record.team_id
	if service_team_id <= 0:
		player.source_data["fa_days_accrued_year"] = season.year
		player.source_data["fa_active_days_last_season"] = 0
		return
	# NPB は1年あたり最大145日分しか一軍登録日数を積めない。フルシーズン(≈190日)を
	# そのまま加算すると、フル出場選手のFA権取得が現実より1.5〜2年早まってしまう。
	var season_days: int = mini(season.get_active_roster_days(service_team_id, player.id), PSPlayer.FA_SERVICE_DAYS_PER_YEAR)
	player.source_data["fa_nissuu"] = int(player.source_data.get("fa_nissuu", 0)) + season_days
	player.source_data["fa_days_accrued_year"] = season.year
	player.source_data["fa_active_days_last_season"] = season_days


# --- 年俸モデル (R4 調整): WAR + 出場試合数ベースの裁定型、現実的スケール (万円) ---
# 参考 (NPB 2024-25 実データ): 支配下平均≈4700万 / 中央値≈1900万 / 最低420万 /
#   1億超≈17% / 上限7-8億。ドラフト1位初年度≈1500万、ブレイクで1500→7000万級。
# 旧モデルは base=overall*1000 で全員 ≈5億になり現実から著しく乖離していたため作り直し。
#
# 仕組み:
#   1. 今季の「市場価値」target を WAR(質) + 出場試合数/投球回(出場) + 主要成績 から算出。
#   2. 前年俸から target へ裁定移動。昇給は速く (ブレイク再現)、減給は NPB 減額制限
#      (1億以下25% / 1億超40%) を上限に緩やかに。これで多年の累積でスター年俸が形成される。
const SALARY_MIN: int = 440              # 支配下最低年俸
const FOREIGN_SALARY_MIN: int = 3000     # 外国人は高め
const SALARY_MAX: int = 80000            # 8億
const SALARY_MARKET_FLOOR: float = 800.0
# 育成契約は一軍成績に連動させず、育成在籍中は契約額を据え置く。支配下から育成へ
# 切り替わる場合だけ新しい育成契約としてこの額へ再設定し、支配下昇格後は通常査定へ戻す。
const DEVELOPMENT_CONTRACT_SALARY: int = 350
# 在籍年数 (年功): 出場が少ないベテランも年数に応じてある程度の年俸を得る (NPB の年功的な底上げ)。
# これで中央値が現実 (≈1900万) 寄りに上がる (新人の下限は据え置き)。
const TENURE_PER_YEAR: float = 220.0
const TENURE_CAP_YEARS: int = 12
# 出場 (durability): 出場試合数・投球回で評価 (ユーザー要望: WAR だけでなく出場でも評価)。
const DUR_PER_GAME_BAT: float = 16.0     # 野手 143 試合 ≈ 2288
const DUR_PER_START: float = 44.0
const DUR_PER_IP: float = 11.0
const DUR_PER_RELIEF: float = 32.0
# WAR (質)。スター域は凸加速。
const WAR_LINEAR: float = 2100.0
const WAR_CONVEX_KNEE: float = 4.0
const WAR_CONVEX_EXP: float = 1.8
const WAR_CONVEX_SCALE: float = 550.0
const NEG_WAR_PENALTY: float = 1200.0
# 裁定 (前年俸からの移動量と減額制限)。
const SALARY_RAISE_ALPHA: float = 0.8
const SALARY_CUT_ALPHA: float = 0.5
const SALARY_CUT_LIMIT_LOW: float = 0.25      # 1億以下は最大25%減
const SALARY_CUT_LIMIT_HIGH: float = 0.40     # 1億超は最大40%減
const SALARY_CUT_LIMIT_THRESHOLD: int = 10000 # 1億
const FOREIGN_MARKET_MULT: float = 1.25


# 年俸 (万円) を有効数字2桁へ丸める (NPBの契約が概ね丸い数字であることに合わせる)。
# 100万未満はそのまま (既に2桁以下)。負値は年俸では発生しない前提。
# 例: 18602→19000 / 9242→9200 / 440→440。年俸を確定する全経路 (年次再査定/FA/延長/
# 外国人契約/戦力外再契約/初期シード) がこの関数を通す。
static func round_salary_2sig(man: int) -> int:
	if man <= 0:
		return 0
	if man < 100:
		return man
	var digits: int = str(man).length()
	var factor: int = int(pow(10, digits - 2))
	return int(round(float(man) / float(factor))) * factor


# 今季記録の WAR (野手/投手)。記録なしや未出場は 0。
static func _season_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	if record.is_pitcher():
		return float(WarCalculator.calculate_pitcher_war(record, league_ctx).get("war", 0.0))
	return float(WarCalculator.calculate_batter_war(record, league_ctx).get("war", 0.0))


# 今季の市場価値 (万円)。出場・WAR・主要成績の合算。
static func _season_market_value(record: PSPlayerSeasonRecord, war: float, is_foreign: bool) -> int:
	if record == null:
		return int(SALARY_MARKET_FLOOR)
	var w: float = maxf(-1.5, war)
	var durability: float = 0.0
	var stats_value: float = 0.0
	if record.is_pitcher():
		var ps: PSPitcherStats = record.pitcher_stats
		var ip: float = ps.innings_pitched()
		if record.is_starter_pitcher():
			durability = float(ps.starts) * DUR_PER_START + ip * DUR_PER_IP
		else:
			durability = float(ps.relief_appearances) * DUR_PER_RELIEF + ip * DUR_PER_IP
		stats_value = float(ps.wins) * 150.0 + float(ps.saves) * 140.0 + float(ps.holds) * 60.0 + float(ps.strikeouts) * 4.0
		if ip >= 140.0 and ps.era() < 3.5:
			stats_value += (3.5 - ps.era()) * 1800.0
	else:
		var bs: PSBatterStats = record.batter_stats
		durability = float(bs.games) * DUR_PER_GAME_BAT
		stats_value = float(bs.home_runs) * 45.0 + float(bs.runs_batted_in) * 6.0 + float(bs.hits) * 3.0 + float(bs.stolen_bases) * 6.0
		if bs.at_bats >= 300 and bs.batting_average() >= 0.300:
			stats_value += (bs.batting_average() - 0.300) * 25000.0
	var war_value: float = 0.0
	if w > 0.0:
		war_value = w * WAR_LINEAR
		if w > WAR_CONVEX_KNEE:
			war_value += pow(w - WAR_CONVEX_KNEE, WAR_CONVEX_EXP) * WAR_CONVEX_SCALE
	else:
		war_value = w * NEG_WAR_PENALTY
	var tenure_value: float = float(mini(record.years, TENURE_CAP_YEARS)) * TENURE_PER_YEAR
	var market: float = SALARY_MARKET_FLOOR + tenure_value + durability + war_value + stats_value
	if is_foreign:
		market *= FOREIGN_MARKET_MULT
	return int(maxf(0.0, market))


# 前年俸 (player.salary) を今季市場価値へ裁定移動する。
static func _compute_new_salary(player: PSPlayer, record: PSPlayerSeasonRecord, war: float) -> int:
	if player.development_player:
		return player.salary
	var target: int = _season_market_value(record, war, player.foreign_player)
	var old_salary: int = player.salary
	var new_salary: int
	if target >= old_salary:
		new_salary = old_salary + int(round(float(target - old_salary) * SALARY_RAISE_ALPHA))
	else:
		var blended: int = old_salary - int(round(float(old_salary - target) * SALARY_CUT_ALPHA))
		var cut_rate: float = SALARY_CUT_LIMIT_HIGH if old_salary > SALARY_CUT_LIMIT_THRESHOLD else SALARY_CUT_LIMIT_LOW
		var floor_cut: int = int(round(float(old_salary) * (1.0 - cut_rate)))
		new_salary = maxi(blended, floor_cut)
	var min_sal: int = FOREIGN_SALARY_MIN if player.foreign_player else SALARY_MIN
	var clamped: int = clampi(new_salary, min_sal, SALARY_MAX)
	# 丸めは最終値(裁定移動+減額制限+clamp後)に対して1回だけ行い、丸めで下限/上限を
	# 割らないよう丸め後に再度同じ clamp を通す (SALARY_MIN/FOREIGN_SALARY_MIN/SALARY_MAX は
	# いずれも既に2桁有効数字の値なのでこの再clampは通常は no-op)。
	return clampi(round_salary_2sig(clamped), min_sal, SALARY_MAX)


# 外国人契約市場向けの市場年俸算定。前年俸からの裁定移動 (急落制限込み) は
# _compute_new_salary と共通で、外国人契約市場はこれをベース年俸として複数年プレミアムを乗せる。
static func foreign_market_salary(player: PSPlayer, record: PSPlayerSeasonRecord, war: float) -> int:
	return _compute_new_salary(player, record, war)


static func _rand_z(center: int, variance: int = 12, min_value: int = 25, max_value: int = 88) -> float:
	# center/variance/min/max は 1-100 の talent authoring 入力。生成される能力値そのものは
	# z 空間で直接抽選し、1-100 の中間能力値を作らない (シミュは z 能力のみ使用)。
	var center_z: float = PSAbilityScale.display_to_z(center)
	var variance_z: float = float(variance) / PSAbilityScale.DISPLAY_STDEV
	var value_z: float = center_z + (Rng.roll_float() * 2.0 - 1.0) * variance_z
	return clampf(value_z, PSAbilityScale.display_to_z(min_value), PSAbilityScale.display_to_z(max_value))


static func _range_float(min_value: float, max_value: float) -> float:
	return min_value + (max_value - min_value) * Rng.roll_float()
