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
# 見込みドラフト人数。**放出数はこの見込みを含む「余り」で決まる**ので、
# `DraftService.MAIN_DRAFT_TARGET_MIN/MAX`(6〜7) の中央値と合わせておく
# (2026-08-03: 指名数が固定枠になったため、この見込みが実際の指名数とほぼ一致するようになった)。
const RELEASE_PLAN_DRAFT_ESTIMATE: int = 7
# ※ 旧 `RELEASE_PLAN_SIGNING_RESERVE`(=2、FA/戦力外獲得の見込み) は 2026-08-03 に撤廃。
#   「毎年必ず2人補強する」前提は現実と乖離しており (誰も獲らない年が普通)、その2人分だけ
#   毎年余計に戦力外を出していた。実際に補強した分は翌オフの在籍に乗り、そこで自然に放出へ回る。
# 育成昇格見込みとして計画に足す上限 (昇格はオフの後段で起こり支配下を増やす)。
const RELEASE_PLAN_PROMO_CAP: int = 2
# 1球団が1オフに放出できる上限 (計画暴走の安全弁)。
const RELEASE_PLAN_MAX_PER_TEAM: int = 15
# 編成計画に対して許容する上振れ。下限は設けず、該当者が少なければその人数で止める。
# 2026-08-03 に 2→1: FA/戦力外獲得の見込み枠を撤廃して補強が入らない年が普通になったため、
# 計画+2 まで切ると開幕支配下が目標 (68) を大きく割る球団が出た (実測 post_team_shienka_min 63)。
const RECONCILE_UPPER_SLACK: int = 1
# 入団1年目のみ rookie 保護する。
const CPU_RELEASE_ROOKIE_PROTECTION_YEARS: int = 1
# 同一CSV・seed=20260714 の比較レポートで、日本人 years<=2 の projected_value 中央値は60.34。
# 長期較正で新人中央値より約8点低い52に置き、上げるほど戦力外候補が増える。
const RELEASE_REPLACEMENT_VALUE: float = 52.0

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

# --- 支配下→育成 降格 ---
# NPB の実手続きは**「一度自由契約 (戦力外通告) にしてから育成契約を結び直す」**で、シーズン中の
# 切替は禁止 ([[reference_npb_development_player_rules]])。よって降格は2経路とも戦力外フェーズに置く:
#
# ① **当落線上の若手の育成契約** (`compute_prospect_demotion_candidates_for_team`、2026-08-02 再導入):
#    **戦力外を免れて支配下に残った**素材年齢 (<=DEMOTE_PROSPECT_MAX_AGE) の選手のうち、
#    来季の一軍にはまだ遠いが育成で伸ばす価値がある選手を育成契約へ回し、支配下枠を空ける。
#    「戦力外候補を降格へ振り替える」形ではない (放出される予定の選手ではなく、残したうえで
#    枠を空けたい選手が対象)。**判定は全て球団相対** — 絶対値の閾値は置かない (下記)。
#    量の目安: 実データ (2023-24の支配下登録リスト) では育成から支配下へ戻った支配下経験者が
#    年16〜26人おり、降格の母数は**年20〜30人規模**。中身は故障離脱中に枠を空ける目的が主。
# ② **長期故障のリハビリ型** (`_should_demote_to_development`): 越冬で治らない長期故障
#    (injury_days≥DEMOTE_INJURY_DAYS_LONG) で future_value が残る選手。**戦力外候補かどうかと独立**
#    (怪我人は候補に上がらないよう保護されるため。2026-08-02 修正)。年齢は問わない。
#
# どちらも育成契約は「支配下経験者」= 1年 (DEV_CONTRACT_MAX_SEASONS_FROM_SHIENKA)。
# 旧・類型3 ベテラン確率降格 (`VETERAN_DEMOTE_*`) は撤廃済み。
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
# のみ、即戦力 (現在能力>=相対基準、満枠待ち) と育成契約の猶予シーズン数でも保持する。
# **中堅以上 (素材年齢超) は「育成での再調整は1年」**: 昇格ステップで支配下に戻れなければ
# 即戦力水準や成長予測を問わずその年のオフに放出する (ベテラン育成降格・戦力外獲得育成track含む)。
#
# **育成契約の年数上限 (2026-08-02)**。NPB「日本プロ野球育成選手に関する規約」準拠:
#   - 新規の育成選手 (育成ドラフト入団): 契約期間は3年。3年間同一球団と育成契約した選手が翌年度に
#     支配下契約されない場合は自由契約 (実際は11月30日付、本ゲームはオフの育成整理で処理)。
#   - **支配下経験者が育成契約した場合は「次年度に支配下契約されなければ自由契約」= 1年**
#     (育成降格・戦力外からの育成track再契約が該当。`dev_from_shienka` フラグで判別する)。
# `PSPlayer.development_seasons_completed` がこの値に達したら、即戦力水準・成長予測・年齢を問わず
# 無条件に自由契約とする。**これが育成人数の発散を止める構造的な歯止め** — これが無いと
# 「支配下70が埋まっていて昇格できない即戦力の育成」が満枠待ちのまま無期限に滞留し、
# 実測で育成年数 最大8年・球団あたり27人まで膨らんだ (2026-08-02、目標人数を外した状態での計測)。
# 保有数 ≒ 年間の育成指名数 × この年数 で自然に頭打ちになるので、目標人数は持たせない。
const DEV_CONTRACT_MAX_SEASONS: int = 3
const DEV_CONTRACT_MAX_SEASONS_FROM_SHIENKA: int = 1
# 育成契約のうち、成長予測を問わず無条件に保持するシーズン数 (最初の N シーズン)。
# 上限までの残り期間が「将来性 (projected_ceiling) で判断される区間」になるので、
# DEV_CONTRACT_MAX_SEASONS より小さくしないと将来性判定が一度も効かない。
const DEV_RELEASE_GRACE_SEASONS: int = 2
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


# 戦力外/育成降格にできない選手 (空文字=可能)。ユーザーの手動選択 (戦力外エディタ) は
# compute_release_candidates_for_team を経由しないため、確定時点でここを単独のガード地点にする。
#  - 複数年契約中 (契約満了年のオフは除く)
#  - 今オフ FA権を新規取得した選手 (取得したてで手放すのは不自然)
#  - 今オフ FA宣言した選手 (FA市場ステップで離脱するまで在籍が続くだけ)
static func release_block_reason(player: PSPlayer, offseason_year: int) -> String:
	if player == null:
		return ""
	if player.is_multi_year_locked_offseason(offseason_year):
		return "複数年契約中(残%d年)" % player.contract_years_remaining(offseason_year)
	if player.is_fa_declared(offseason_year):
		return "今オフFA宣言済み"
	if player.is_new_fa_holder(offseason_year):
		return "今オフFA権を新規取得"
	return ""


static func reject_locked_release_or_demote(players: Array, release_ids: Array, demote_ids: Array, offseason_year: int) -> Dictionary:
	for id_value in release_ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		var reason: String = release_block_reason(player, offseason_year)
		if not reason.is_empty():
			return {"ok": false, "message": "%s は%sのため戦力外にできません" % [player.name, reason]}
	for id_value in demote_ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		var reason: String = release_block_reason(player, offseason_year)
		if not reason.is_empty():
			return {"ok": false, "message": "%s は%sのため育成降格にできません" % [player.name, reason]}
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

# 戦力外/育成降格の結果行 (release/demote で同じ shape)。**mutation の前に**作ること
# (_apply_release_mutation は team_id をクリアするため、後から作ると所属が消える)。
static func _roster_move_entry(player: PSPlayer, team_id: int) -> Dictionary:
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"team_id": team_id,
		"position": player.position,
		"role": player.role,
		"overall": player_value_score(player),
		"years": player.years,
		"salary": player.salary,
	}

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
		var year: int = season.year if season != null else 0
		# 長期故障の育成降格は**戦力外候補の選定より前**に行う。支配下枠がその分空き、
		# 放出数 (在籍 + 見込み補強 − 開幕目標) も自動的に1人少なく計画される。
		for injured_id in compute_long_injury_demotion_candidates_for_team(players, team.id, year):
			var injured: PSPlayer = _find_player_by_id(players, int(injured_id))
			if injured == null:
				continue
			demoted.append(_roster_move_entry(injured, team.id))
			_apply_demotion_to_development(injured, year)
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
			var release_entry: Dictionary = _roster_move_entry(player, team.id)
			_apply_release_mutation(player, year)
			team_released_count += 1
			released.append(release_entry)
		if team_released_count > 0:
			by_team_counts[team.id] = team_released_count
		# 戦力外を免れた当落線上の若手を育成契約へ (放出後の在籍でデプスチャートを取り直す)。
		for prospect_id in compute_prospect_demotion_candidates_for_team(players, team.id, season):
			var prospect: PSPlayer = _find_player_by_id(players, int(prospect_id))
			if prospect == null:
				continue
			demoted.append(_roster_move_entry(prospect, team.id))
			_apply_demotion_to_development(prospect, year)

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
# ドラフトの外国人枠予約 (FOREIGN_ROSTER_RESERVE_TARGET) と、放出計画の支配下限定目標
# (DOMESTIC_ROSTER_TARGET) の両方が外国人保有上限として参照する。
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
		# 複数年契約中・今オフFA権新規取得・今オフFA宣言済みは、常時カット・計画カットどちらの
		# 候補にもしない (release_block_reason が単一ソース)。これは _should_demote_to_development
		# 経由の育成降格保護も兼ねる (呼び出し元 process_cpu_releases がこの関数の返す cut_ids から
		# しか降格判定を行わないため)。
		if not release_block_reason(player, offseason_year).is_empty():
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
	var plan_count: int = _release_plan_count(players, team_id, _domestic_roster_count(players, team_id))
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


# **支配下 (国内・非外国人) 限定の開幕目標** (2026-08-03)。外国人の去就は戦力外通告ではなく
# 外国人契約市場が別途決めるため ([[project_foreign_contract_market]])、放出計画は外国人を
# 一切見ない。OPENING_ROSTER_TARGET(68、支配下+外国人の合計目標) から外国人保有上限
# (FOREIGN_ROSTER_LIMIT=4、最終的に埋まる前提) を引いた 64 が支配下だけの目標になる。
# ※ 旧実装は在籍数に外国人を含めたまま「外国人不足 (4−現外国人数)」を見込み流入へ足しており、
#   数式上は現外国人数の項が打ち消し合って結果は同じだったが、意図が読み取れず外国人数が
#   4を超える異常系 (通常は起きない) でも打ち消しが崩れる作りだった。ここで明示的に切り離す。
const DOMESTIC_ROSTER_TARGET: int = TeamFinance.OPENING_ROSTER_TARGET - FOREIGN_ROSTER_LIMIT


# 見込み流入はドラフト (固定枠) と即戦力の育成昇格のみで構成する。**外国人は含めない**
# (放出計画自体が支配下限定のため)。FA/戦力外獲得も**見込みに入れない** (2026-08-03) —
# 獲るかどうかは年と球団によるので、見込みで先に枠を空けると「補強しなかった年に人数が
# 足りない」状態になる。
static func _release_expected_inflow(players: Array, team_id: int) -> int:
	var promo_ready: int = 0
	var ready_threshold: float = first_team_ready_threshold(players, team_id)
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired():
			continue
		if player.development_player and float(player_value_score(player)) >= ready_threshold:
			promo_ready += 1
	return RELEASE_PLAN_DRAFT_ESTIMATE + mini(promo_ready, RELEASE_PLAN_PROMO_CAP)


# 支配下 (非外国人・非育成・非引退) の在籍数。放出計画・スロット予算はすべてこれを母数にする。
static func _domestic_roster_count(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or player.development_player or player.foreign_player:
			continue
		count += 1
	return count


# 支配下目標から見込み流入を引いた放出後ロスターへ、快適水準の比率を比例縮小して割り当てる。
# **役割バケツ (fielder:N / pitcher:starter|reliever) は外国人選手も一緒に数える**
# (release_depth_chart_evaluations が foreign_player を除外せずグループ化するため、
# 外国人投手も domestic の投手と同じ "pitcher:starter" 枠を奪い合う)。よって post_target は
# 「支配下の放出後見込み (DOMESTIC_ROSTER_TARGET 基準、外国人非依存)」に**現在の外国人保有数**を
# 足し戻した総人数にする — ここを外国人抜きのままにすると、外国人を多く抱える球団ほど
# バケツ内の実際の枠消費 (外国人ぶん) を budget が見込まなくなり、支配下選手が余分に
# 「余剰」判定されて過剰放出される (2026-08-03、実測で post_team_shienka_min が悪化して発覚)。
static func _release_slot_budgets(players: Array, team_id: int) -> Dictionary:
	var domestic_post_target: int = DOMESTIC_ROSTER_TARGET - _release_expected_inflow(players, team_id)
	var post_target: int = maxi(1, domestic_post_target + TeamFinance.foreign_player_count(players, team_id))
	var scale: float = float(post_target) / RELEASE_COMFORT_TOTAL
	var budgets: Dictionary = {}
	for position_v in RELEASE_POSITION_COMFORT.keys():
		var position: int = int(position_v)
		budgets["fielder:%d" % position] = maxi(1, roundi(float(RELEASE_POSITION_COMFORT[position]) * scale))
	for role_v in RELEASE_PITCHER_ROLE_COMFORT.keys():
		var role: String = str(role_v)
		budgets["pitcher:%s" % role] = maxi(1, roundi(float(RELEASE_PITCHER_ROLE_COMFORT[role]) * scale))
	return budgets


# 編成計画はガードレール用であり、実際の放出数を強制しない。roster_count は**支配下限定**
# (_domestic_roster_count) で渡すこと — 呼び出し元の release_depth_chart_evaluations は
# 外国人も含む全在籍を評価するため、そのまま渡すと外国人ぶん過大にカウントされる。
static func _release_plan_count(players: Array, team_id: int, domestic_roster_count: int) -> int:
	var inflow: int = _release_expected_inflow(players, team_id)
	return clampi(domestic_roster_count + inflow - DOMESTIC_ROSTER_TARGET, 0, RELEASE_PLAN_MAX_PER_TEAM)


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
	# 育成契約の年数カウンタの起点 (PSPlayer.development_seasons_completed)。昇格でリセットされる。
	player.source_data["development_since_year"] = year
	# 降格は定義上「支配下経験者の育成契約」= 契約は1年 (DEV_CONTRACT_MAX_SEASONS_FROM_SHIENKA)。
	player.source_data["dev_from_shienka"] = true


# CPU 自動: 戦力外候補のうち、release ではなく育成降格 (org 残留) に回すべきか判定する。
# **長期故障のリハビリ型のみ** (2026-07-03 ユーザー方針「怪我以外での育成落ちはなくす」)。
# 越冬で治らない長期故障 (injury_days >= DEMOTE_INJURY_DAYS_LONG) で、復帰すれば戦力になる
# 将来価値が残る選手だけを育成で抱える。年齢は問わない。
# 旧・類型1 素材保持型 (24-26歳の将来性) と旧・類型3 ベテラン確率降格は撤廃
# (CPU が育成へ落とす選手が多すぎたため。手動の育成降格と育成ドラフトは従来どおり)。

# 長期故障による育成降格の対象 (非破壊、value 降順ではなく player 順)。**戦力外候補かどうかとは独立**に
# 判定する — 怪我人は戦力外候補になる前に保護される (_can_claim_release_slot は30歳未満を無条件、
# 30歳以上も season_injury_days の excuse でスロット保持者にし、ReleaseValueProjector も usage を底上げする)
# ため、release の振り分けとしてだけ実装していた頃はこの経路が一度も発火しなかった (2026-08-02 修正)。
# 育成の人数上限は無い (2026-08-02 撤廃) ので、対象者は全員降格させる。
static func compute_long_injury_demotion_candidates_for_team(players: Array, team_id: int, offseason_year: int) -> Array:
	var candidates: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or player.development_player:
			continue
		if not release_block_reason(player, offseason_year).is_empty():
			continue
		if not _should_demote_to_development(player):
			continue
		candidates.append(player.id)
	return candidates


# 当落線上の若手の育成降格候補 (非破壊)。**戦力外を免れて支配下に残った**選手が対象で、
# 戦力外候補は exclude_ids で除く (CPU は放出後に呼ぶので自然に外れる。自軍推奨は推奨放出リストを渡す)。
# **判定は絶対値を使わず、既存の相対評価2つの組み合わせだけで決める**:
#   1. `surplus` かつ `projected_value < RELEASE_REPLACEMENT_VALUE` — `would_release_player_for_team`
#      (=「その球団なら戦力外相当」) と同じ AND 条件で、戦力外通告・外国人スカウト・戦力外市場と
#      同じデプスチャート判定を共有する。ここを満たすのに放出されなかった選手 = 放出枠 (計画数) や
#      保護 (23歳以下/rookie) で生き残った、まさに当落線上の選手。
#      ※ `would_release_player_for_team` を選手ごとに呼ぶとデプスチャートを毎回作り直して O(n²)
#        になるため (実測で長期オートプレイが数十分単位に悪化)、評価は1球団1回だけ作って使い回す。
#   2. `development_projected_ceiling` >= `first_team_ready_threshold` — 成長期待の楽観側まで見れば
#      その球団の一軍下位水準に届く = 育成で伸ばす価値がある。昇格 (育成→支配下) と同じ物差し。
# どちらも球団相対なので、強豪は基準が上がり再建球団は下がる (他の編成AIと同じ挙動)。
# 量のノブは持たない — デプスチャートの余剰と放出計画の差で自然に決まる。
static func compute_prospect_demotion_candidates_for_team(
	players: Array, team_id: int, season: PSSeason, exclude_ids: Dictionary = {}
) -> Array:
	var offseason_year: int = season.year if season != null else 0
	var evaluations: Dictionary = release_depth_chart_evaluations(players, team_id, season)
	if evaluations.is_empty():
		return []
	var ready_threshold: float = first_team_ready_threshold(players, team_id)
	var candidates: Array = []
	for row in evaluations.values():
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if player == null or player.foreign_player:
			continue
		if exclude_ids.has(player.id):
			continue
		if player.age > DEMOTE_PROSPECT_MAX_AGE:
			continue
		if not release_block_reason(player, offseason_year).is_empty():
			continue
		if not bool(data.get("surplus", false)):
			continue
		if float(data.get("projected_value", 0.0)) >= RELEASE_REPLACEMENT_VALUE:
			continue
		# 全球団が同一評価にならないよう比較閾値を ±DEMOTE_JITTER 揺らす (marginal 層のみに効く)。
		var jitter: float = 1.0 + (Rng.roll_float() - 0.5) * 2.0 * DEMOTE_JITTER
		if development_projected_ceiling(player) < ready_threshold * jitter:
			continue
		candidates.append(player.id)
	return candidates


static func _should_demote_to_development(player: PSPlayer) -> bool:
	if player == null or player.foreign_player:
		return false
	if player.injury_days < DEMOTE_INJURY_DAYS_LONG:
		return false
	# 全球団が同一評価にならないよう、比較閾値を ±DEMOTE_JITTER 揺らす (marginal 層のみ)。
	var jitter: float = 1.0 + (Rng.roll_float() - 0.5) * 2.0 * DEMOTE_JITTER
	return future_value_score(player) >= DEMOTE_INJURY_MIN_FUTURE_VALUE * jitter


# roadmap #3: 支配下登録 (昇格)。育成選手を支配下に戻す。一軍登録可・70枠を消費する。
static func _apply_promotion_to_shienka(player: PSPlayer, year: int = 0) -> void:
	PSCareerLog.log_dev_promote(player, year, player.team_id)
	player.development_player = false
	player.registered_roster = "支配下"
	player.salary = maxi(player.salary, SALARY_MIN)
	# 育成年数のカウンタは支配下登録でリセットする (再降格したらそこから数え直し)。
	player.source_data.erase("development_since_year")
	player.source_data.erase("dev_from_shienka")


# CPU 自動: 育成選手のうち value が閾値以上の者を、支配下に空きがある範囲で昇格する。
# excluded_team_id (自軍) は対話プレイではユーザーが手動昇格するため除外する。
# オフの昇格は soft 目標 (67) で止め、残り3枠はシーズン中に使う。
static func process_development_promotions(players: Array, teams: Array, excluded_team_id: int = 0, year: int = 0) -> Dictionary:
	return _promote_ready_development(players, teams, excluded_team_id, year, false)


# 支配下登録期限 (7/31、交換期限と同日) の昇格。オフで空けておいた soft 目標 (67) と
# hard 上限 (70) の差を、ここで使い切る。期限を過ぎると FA も外国人もトレードも無く、
# 空き枠は翌オフまで死に枠になるため (2026-08-01 ユーザー要望)。
# 昇格基準はオフと同じ球団相対の即戦力基準で、満たさない育成は昇格させない
# (枠を埋めること自体は目的にせず、育成制度と人数収支を壊さない)。
static func process_registration_deadline_promotions(players: Array, teams: Array, excluded_team_id: int, season: PSSeason) -> Dictionary:
	var year: int = season.year if season != null else 0
	var result: Dictionary = _promote_ready_development(players, teams, excluded_team_id, year, true)
	# シーズン中の昇格は当季レコードも支配下へ同期する。一軍登録の可否は
	# record.development_player で判定されるため、ここを更新しないと昇格しても出場できない。
	if season != null:
		for row in result.get("promoted", []) as Array:
			var record: PSPlayerSeasonRecord = RecordStore.get_player_record(
				int((row as Dictionary).get("player_id", 0)), season.year, season.season_number
			)
			if record == null:
				continue
			record.development_player = false
			record.registered_roster = "支配下"
	return result


# use_hard_limit=false → SHIENKA_SOFT_TARGET(67) で止める / true → SHIENKA_LIMIT(70) まで埋める。
static func _promote_ready_development(players: Array, teams: Array, excluded_team_id: int, year: int, use_hard_limit: bool) -> Dictionary:
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
			var has_room: bool = (
				TeamFinance.has_shienka_room(players, team.id) if use_hard_limit
				else TeamFinance.has_shienka_soft_room(players, team.id)
			)
			if not has_room:
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


# 育成整理の保持/放出判定 (非破壊)。true なら放出対象。offseason_year は育成契約の年数判定に使う。
# 判定順:
#  1. **育成契約の年数上限**: 新規=DEV_CONTRACT_MAX_SEASONS(3) / 支配下経験者=
#     DEV_CONTRACT_MAX_SEASONS_FROM_SHIENKA(1)。達したら他の保持理由を問わず放出。
#     即戦力の満枠待ち保持を打ち切る唯一の経路で、育成人数が発散しないのはこれのおかげ。
#  2. 常時保持: 1年目 (years<=1) / 降格・育成track獲得の同オフ (dev_demote_hold、ここでは
#     見るだけで消費しない) / 故障リハビリ中。
#  3. 素材年齢 (<=DEMOTE_PROSPECT_MAX_AGE): 即戦力の満枠待ち・猶予シーズン・
#     projected_ceiling (成長予測) で保持。中堅以上は「育成での再調整は1年」で無条件放出
#     (ベテランの育成降格・戦力外獲得の育成track を含む。2026-07-02 ユーザー要望)。
static func _should_release_development_player(dev: PSPlayer, ready_threshold: float, offseason_year: int) -> bool:
	var max_seasons: int = DEV_CONTRACT_MAX_SEASONS_FROM_SHIENKA if dev.is_development_from_shienka() else DEV_CONTRACT_MAX_SEASONS
	if dev.development_seasons_completed(offseason_year) >= max_seasons:
		return true
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
		# 育成契約の最初の数シーズンは成長予測を問わず保持。
		if dev.development_seasons_completed(offseason_year) < DEV_RELEASE_GRACE_SEASONS:
			return false
		# 一軍昇格見込み: 残り成長期待の楽観側まで見込んだ projected_ceiling が
		# 即戦力基準に届かないなら「昇格見込みほぼ無し」で放出。
		if development_projected_ceiling(dev) >= ready_threshold:
			return false
	return true


# 育成選手の「一軍に上がれる見込み」= 現在能力 + 残り成長期待の楽観側 (DEV_PROJECTION_OPTIMISM 倍)。
# 育成整理の判定と、保有目安超過分のトリム順 (低い順に放出) で同じ尺度を使う。
static func development_projected_ceiling(dev: PSPlayer) -> float:
	if dev == null:
		return 0.0
	var growth: float = maxf(0.0, expected_development_score_bonus(dev.age, 6, dev.position))
	return float(player_value_score(dev)) + growth * DEV_PROJECTION_OPTIMISM


# 育成整理の放出対象 id (非破壊、dev_demote_hold は消費しない)。CPU (process_development_releases) と
# 自軍の戦力外エディタ推奨が**同じ関数**を使う — 自軍は process_development_releases から除外されるため、
# ここを共有しないと「条件を満たす育成選手が自軍だけ永久に残る」ことになる (2026-07-02)。
static func compute_development_release_candidates_for_team(players: Array, team_id: int, offseason_year: int) -> Array:
	var ready_threshold: float = first_team_ready_threshold(players, team_id)
	var ids: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or not player.development_player:
			continue
		if _should_release_development_player(player, ready_threshold, offseason_year):
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
		# 判定は非破壊の共有関数へ委譲する (自軍の推奨と同じ基準)。dev_demote_hold を見るので、
		# **フラグの消費より前**に呼ぶこと。
		var release_ids: Dictionary = {}
		for id_value in compute_development_release_candidates_for_team(players, team.id, year):
			release_ids[int(id_value)] = true
		# 「降格年の保持」フラグはこのオフで消費し、翌オフから通常判定に戻す。
		for dev_row in devs:
			(dev_row as PSPlayer).source_data.erase("dev_demote_hold")
		for dev_row in devs:
			var dev: PSPlayer = dev_row as PSPlayer
			if not release_ids.has(dev.id):
				continue
			var entry: Dictionary = _roster_move_entry(dev, team.id)
			_apply_release_mutation(dev, year)
			released.append(entry)
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
	var year: int = season.year if season != null else 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		# 直前のFA宣言ステップで宣言した選手は今オフ引退しない (宣言した本人が数日後に
		# 引退するのは不自然で、FA市場の候補が消える事故も防げる)。
		if player.is_fa_declared(year):
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


# 球団×ポジションの補強需要 {team_id: {1..9: need}}。**実体は TeamDepthChart** (年齢・ポジション・
# 能力の単一デプスチャート、2026-08-03 に統合)。ここは position 番号のマップを期待する既存呼び出し元
# (FA / 戦力外獲得 / 現役ドラフト / 外国人) のための互換ビューで、投手 (position 1) は
# 先発/救援スロットの need の大きい方を返す。
# 旧実装 (球団ごとに「野手は最良1人・投手は上位12枚平均」を数え直す) は TeamDepthChart へ移した。
static func position_need(players: Array, teams: Array) -> Dictionary:
	return TeamDepthChart.position_need_view(TeamDepthChart.build_league(players, teams))


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
# 生成ロジック本体は PSPitchTypes.generate_arsenal (初期シードの backfill と共有)。ここは
# 「野手には付けない」判定と、世界 Rng から生成 seed を1つ引く役割だけを持つ。
static func generated_arsenal(position: int, z_abilities: Dictionary) -> Array:
	if position != 1:
		return []
	return PSPitchTypes.generate_arsenal(z_abilities, Rng.range_int(0, 1000000000))


# --- 怪我の繰り越し (越冬回復) ---

# オフシーズンの怪我繰り越し: 当季終了時点の record.injury_days から越冬回復分 (OFFSEASON_RECOVERY_DAYS)
# を引き、残りを持続 player へ書き戻す。翌季の PSPlayerSeasonRecord.from_player が
# injury_days / injury_type / injury_severity をシードするので、長期離脱が翌季へ持ち越される。
# 恒久能力低下は発生時 (PSInjuryModel) に適用済みのため、ここは怪我状態の簿記のみ。
# **実行位置はオフ冒頭 (引退判定ステップ) 固定** — `player.injury_days` を書き換えるのはこの関数だけで、
# シーズン中は record 側しか動かない。戦力外/育成降格 (_should_demote_to_development) や
# injury_value_penalty はこの player 側を読むため、キャンプステップに置いていた頃 (〜2026-08-02) は
# 判定が常に1年前の怪我状態を見ており、今季の大怪我による育成降格が事実上発火しなかった。
# record から計算するので冪等 (同じオフに複数回呼んでも二重に回復しない)。
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


# --- 契約年数の決定 (FA市場の直後、国内選手の複数年契約の発生源) ---
# 対象は日本人 (非外国人・非育成) の在籍選手のうち、
#   ① 今オフ FA権を新規取得し、FA宣言しなかった選手 (fa_eligible_year == year)
#   ② 複数年契約が今オフ満了した選手 (contract_total_years >= 2 かつ contract_end_year == year)
#   ③ FA宣言したが引き取り手がなく元球団に残留した選手 (fa_returned_year == year)
# の3種。それ以外は自動的に単年契約で、年俸は契約更改 (このステップの手前) の査定額で確定する。
# **宣言しなかった (=残留が確定した) 選手が年数を拒否することはないので、決めた年数は必ず成立する。**
# 年俸 = base × (1 + プレミアム×(年数-1))。外国人契約市場の FOREIGN_MULTI_YEAR_PREMIUM と同じ考え方
# (複数年ほど選手側に有利な年俸を積む)。base は3種とも契約更改後の現年俸 (player.salary)。
const CONTRACT_YEARS_PREMIUM: float = 0.05
# CPU球団の既定年数。value がこの水準以上なら対応する年数を基準にし、年齢上限
# (FaMarketService.fa_offer_max_years) と予算で切り下げる。リーグ全体の複数年契約の量を決める
# 唯一の調整ノブなので、long_autoplay の multi_year_active 列で張り付きを監視する。
const CONTRACT_YEARS_VALUE_TIERS: Array = [
	{"min_value": 75, "years": 4},
	{"min_value": 68, "years": 3},
	{"min_value": 62, "years": 2},
]


# 契約年数を決める対象か (空文字=対象外)。判定順は fa_returned が先 — FA宣言して残留した選手は
# 新規取得年と重なりうるが、区分表示 (FA残留) を分けるため先に拾う。
static func _contract_years_reason(player: PSPlayer, year: int) -> String:
	if int(player.source_data.get("fa_returned_year", 0)) == year:
		return "fa_returned"
	if player.is_fa_declared(year):
		# 宣言して他球団と契約した選手は、その交渉で年数まで決まっている。
		return ""
	if player.is_multi_year_locked_offseason(year):
		# 複数年契約の期間中は年数を決め直さない (満了年のオフだけ contract_end で拾う)。
		return ""
	if int(player.source_data.get("fa_eligible_year", 0)) == year:
		return "new_fa"
	if int(player.source_data.get("contract_total_years", 0)) >= 2 and int(player.source_data.get("contract_end_year", 0)) == year:
		return "contract_end"
	return ""


# 契約年数の決定候補プール ({player_id, team_id, name, age, position, role, value, current_salary,
# base_salary, max_years, reason, decided:false, years:0, salary:0}) を value 降順で構築する。
# 全球団分を持ち、UI は自軍だけを表示する (CPU分は確定時にまとめて決まる)。
# 年齢上限が1年の選手 (36歳以上) は選べる年数が単年しかないので、ここで単年として確定させて
# プールには入れない (満了した複数年契約のキーもこの時点で消える)。
static func _build_contract_years_pool(players: Array, year: int) -> Array:
	var entries: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired() or player.foreign_player or player.development_player:
			continue
		if player.team_id <= 0:
			continue
		var reason: String = _contract_years_reason(player, year)
		if reason.is_empty():
			continue
		# 複数年の年俸ベースは現年俸。このステップは契約更改 (年俸再査定) の後に走るので、
		# player.salary は既に来季の査定額 = 単年契約ならそのまま確定する額になっている
		# (FA残留組も査定額のまま戻ってくる)。ここで再査定すると二重に昇給する。
		var base_salary: int = player.salary
		var max_years: int = FaMarketService.fa_offer_max_years(player.age)
		if max_years < 2:
			_apply_contract_years(player, 1, base_salary, year)
			continue
		entries.append({
			"player_id": player.id,
			"team_id": player.team_id,
			"name": player.name,
			"age": player.age,
			"position": player.position,
			"role": player.role,
			"value": player_value_score(player),
			"current_salary": player.salary,
			"base_salary": base_salary,
			"max_years": max_years,
			"reason": reason,
			"decided": false,
			"years": 0,
			"salary": 0,
		})
	entries.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) != int(db.get("value", 0)):
			return int(da.get("value", 0)) > int(db.get("value", 0))
		return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
	)
	return entries


static func _contract_years_salary(base_salary: int, years: int) -> int:
	var raw: int = int(round(float(base_salary) * (1.0 + CONTRACT_YEARS_PREMIUM * float(maxi(1, years) - 1))))
	return round_salary_2sig(raw)


# CPU球団の年数決定。value のティアを年齢上限でクランプし、増額分が予算に収まらない間は
# 1年ずつ削る (最終的に単年へ落ちる)。
static func _cpu_contract_years(entry: Dictionary, players: Array, team: PSTeam) -> int:
	var years: int = 1
	var value: int = int(entry.get("value", 0))
	for tier_row in CONTRACT_YEARS_VALUE_TIERS:
		var tier: Dictionary = tier_row as Dictionary
		if value >= int(tier.get("min_value", 0)):
			years = int(tier.get("years", 1))
			break
	years = mini(years, maxi(1, int(entry.get("max_years", 1))))
	var base_salary: int = int(entry.get("base_salary", 0))
	var current_salary: int = int(entry.get("current_salary", 0))
	while years >= 2:
		var delta: int = maxi(0, _contract_years_salary(base_salary, years) - current_salary)
		if team != null and TeamFinance.can_afford_addition(players, team, delta):
			break
		years -= 1
	return maxi(1, years)


static func _contract_years_entry_by_player_id(state: Dictionary, player_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("player_id", 0)) == player_id:
			return entry
	return {}


# ユーザーの年数決定。自球団の候補のみ、[1, max_years] にクランプする。決定は state に記録するだけで、
# 選手への適用は finalize_contract_years でまとめて行う (取り消しできるようにするため)。
static func submit_contract_years(state: Dictionary, players: Array, teams: Array, user_team_id: int, player_id: int, years: int) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "契約年数の決定は既に終了しています。", "state": state}
	var entry: Dictionary = _contract_years_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は契約年数の決定対象ではありません。", "state": state}
	if int(entry.get("team_id", 0)) != user_team_id:
		return {"ok": false, "message": "自球団の選手のみ契約年数を決められます。", "state": state}
	var clamped_years: int = clampi(years, 1, maxi(1, int(entry.get("max_years", 1))))
	var salary: int = _contract_years_salary(int(entry.get("base_salary", 0)), clamped_years)
	if clamped_years >= 2:
		var player: PSPlayer = _find_player_by_id(players, player_id)
		var team: PSTeam = _find_team_by_id(teams, user_team_id)
		var delta: int = maxi(0, salary - (player.salary if player != null else 0))
		if not TeamFinance.can_afford_addition(players, team, delta):
			return {"ok": false, "message": "予算が不足しているためこの年数では契約できません。", "state": state}
	entry["decided"] = true
	entry["years"] = clamped_years
	entry["salary"] = salary
	entry["method"] = "user"
	return {"ok": true, "state": state}


static func withdraw_contract_years(state: Dictionary, player_id: int) -> Dictionary:
	var entry: Dictionary = _contract_years_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は契約年数の決定対象ではありません。", "state": state}
	entry["decided"] = false
	entry["years"] = 0
	entry["salary"] = 0
	entry.erase("method")
	return {"ok": true, "state": state}


# 自球団の未決定分をCPUと同じ基準で埋める (UI の「自動で決める」)。
static func auto_decide_contract_years(state: Dictionary, players: Array, teams: Array, user_team_id: int) -> Dictionary:
	var decided_count: int = 0
	for entry_row in state.get("candidates", []) as Array:
		var entry: Dictionary = entry_row as Dictionary
		if bool(entry.get("decided", false)) or int(entry.get("team_id", 0)) != user_team_id:
			continue
		var team: PSTeam = _find_team_by_id(teams, user_team_id)
		var years: int = _cpu_contract_years(entry, players, team)
		entry["decided"] = true
		entry["years"] = years
		entry["salary"] = _contract_years_salary(int(entry.get("base_salary", 0)), years)
		entry["method"] = "auto"
		decided_count += 1
	return {"ok": true, "decided_count": decided_count, "state": state}


# 契約年数を選手へ適用する。単年 (years<=1) は契約キーを消すだけで年俸は触らない
# (3区分とも直前の契約更改で査定済みなので、単年ならその額がそのまま来季の年俸)。
# キーを消すことで「複数年契約が今オフ満了」の検出が翌年以降に誤爆しない。
static func _apply_contract_years(player: PSPlayer, years: int, salary: int, year: int) -> void:
	if player == null:
		return
	if years <= 1:
		player.source_data.erase("contract_end_year")
		player.source_data.erase("contract_total_years")
		player.source_data.erase("contract_signed_year")
		return
	player.salary = salary
	player.source_data["contract_end_year"] = year + years
	player.source_data["contract_total_years"] = years
	player.source_data["contract_signed_year"] = year
	PSCareerLog.log_contract_extension(player, year, player.team_id, salary, years)


# 未決定の候補 (CPU球団分、および自動確定経路での自球団分) をCPU基準で埋めてから、
# 全候補を選手へ適用する。宣言しなかった=残留確定なので拒否判定は無く、決めた年数は必ず成立する。
static func _resolve_contract_years(state: Dictionary, players: Array, teams: Array) -> Array:
	var year: int = int(state.get("year", 0))
	var decisions: Array = []
	for entry_row in state.get("candidates", []) as Array:
		var entry: Dictionary = entry_row as Dictionary
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if player == null:
			continue
		if not bool(entry.get("decided", false)):
			var team: PSTeam = _find_team_by_id(teams, int(entry.get("team_id", 0)))
			var cpu_years: int = _cpu_contract_years(entry, players, team)
			entry["decided"] = true
			entry["years"] = cpu_years
			entry["salary"] = _contract_years_salary(int(entry.get("base_salary", 0)), cpu_years)
			entry["method"] = "cpu"
		var years: int = maxi(1, int(entry.get("years", 1)))
		var old_salary: int = player.salary
		_apply_contract_years(player, years, int(entry.get("salary", player.salary)), year)
		decisions.append({
			"player_id": player.id, "name": player.name, "age": player.age,
			"position": player.position, "role": player.role,
			"team_id": player.team_id, "from_team": player.team_id, "to_team": player.team_id,
			"old_salary": old_salary, "salary": player.salary, "offer_salary": player.salary,
			"contract_years": years, "reason": str(entry.get("reason", "")),
			"value": int(entry.get("value", 0)), "method": str(entry.get("method", "cpu")),
		})
	return decisions


# 契約年数ステップの state を作る。候補ゼロなら対話パネル不要なのでその場で確定させる。
static func create_contract_years_state(players: Array, _teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var year: int = season.year if season != null else 0
	var candidates: Array = _build_contract_years_pool(players, year)
	var state: Dictionary = {
		"version": 1,
		"year": year,
		"user_team_id": user_team_id,
		"complete": candidates.is_empty(),
		"finalized": false,
		"candidates": candidates,
	}
	if candidates.is_empty():
		state["finalized"] = true
		state["final_result"] = _contract_years_result(state, [])
	return state


# 自球団の未決定候補が残っているか (AppState が「次へ」をブロックするのに使う)。
static func pending_contract_years_count(state: Dictionary, user_team_id: int) -> int:
	var count: int = 0
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("team_id", 0)) == user_team_id and not bool(entry.get("decided", false)):
			count += 1
	return count


# 未決定分をCPU基準で埋めて全候補を適用し、ステップ結果を返す。
# 二重実行防止: finalized ならキャッシュを返す。
static func finalize_contract_years(state: Dictionary, players: Array, teams: Array) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var decisions: Array = _resolve_contract_years(state, players, teams)
	var result: Dictionary = _contract_years_result(state, decisions)
	state["complete"] = true
	state["finalized"] = true
	state["final_result"] = result
	return result


static func _contract_years_result(state: Dictionary, decisions: Array) -> Dictionary:
	var multi_year: Array = []
	for row in decisions:
		if int((row as Dictionary).get("contract_years", 1)) >= 2:
			multi_year.append(row)
	multi_year.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	return {
		"title": "契約年数",
		"year": int(state.get("year", 0)),
		"decisions": decisions,
		"decided_count": decisions.size(),
		"multi_year_signings": multi_year,
		"multi_year_count": multi_year.size(),
	}


# 契約更改 (現役ドラフトの直後・FA市場の直前): 全選手の年俸再査定 + 球団別の予算会計。
# FA日数の締めと contract_status 遷移はオフ冒頭の FA宣言ステップ
# (accrue_fa_days_and_update_status) が済ませているので、ここは年俸だけを扱う。
# **補強市場より前に置くのが重要** — ここを抜けた時点で player.salary が来季の確定額になるため、
# 以降の FA/外国人/トレードの予算ゲートが来季 payroll に対して正確に効く。
# 今オフ入団した選手 (ドラフト新人/戦力外獲得) は契約額のまま (_contract_salary_is_locked)。
static func process_contract_renewal(players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var year: int = season.year if season != null else 0
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

	return {
		"raises": raises.slice(0, 20),
		"cuts": cuts.slice(0, 20),
		"raises_count": raises.size(),
		"cuts_count": cuts.size(),
		"team_budgets": team_budgets,
		"over_budget_count": over_budget_count,
	}


# オフ冒頭 (FA宣言ステップ) の FA権処理: 当年の1軍登録日数を締めてから、全選手の
# contract_status を遷移させる。今オフ新しく「FA可能」になった選手の一覧を返す。
# FaMarketService.create_declaration_state から呼ばれ、宣言抽選より前に必ず1度だけ走る。
static func accrue_fa_days_and_update_status(players: Array, teams: Array, season: PSSeason) -> Array:
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
	new_fa.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["team_id"]) == int(db["team_id"]):
			return int(da["age"]) > int(db["age"])
		return int(da["team_id"]) < int(db["team_id"])
	)
	return new_fa

# 年俸再査定をスキップすべきか。「今オフ入団した選手は契約した金額のまま来季を迎える」
# (ドラフト指名・戦力外獲得・FA移籍で今オフに合意した単年ロック。翌オフには通常の成績査定へ戻る) と、
# 複数年契約でカバーされている年 (契約満了年のオフは対象外、
# PSPlayer.is_multi_year_locked_offseason 参照) の OR。
# ※ ドラフト新人は前年の成績を持たないため、査定を通すと市場価値 floor まで落ちて
#   1試合も出ないうちに減額される (指名時の年俸がそのまま1年目の年俸になるのが正しい)。
static func _contract_salary_is_locked(player: PSPlayer, year: int) -> bool:
	if year <= 0:
		return false
	var drafted_this_offseason: bool = int(player.source_data.get("draft_year", 0)) == year
	var fa_locked: bool = int(player.source_data.get("fa_signed_year", 0)) == year and player.source_data.has("fa_contract_salary")
	var released_locked: bool = int(player.source_data.get("released_signed_year", 0)) == year and player.source_data.has("released_contract_salary")
	return drafted_this_offseason or fa_locked or released_locked or player.is_multi_year_locked_offseason(year)


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
