extends RefCounted
class_name OffseasonService

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

# 引退は「年齢による自然減」と「高齢かつ低稼働」を併用する。
# 出場機会を維持している選手でも40歳以降は毎年確率が上がり、48歳で必ず引退する。
# 38歳以上で役割別の少試合基準を満たす選手は、強制年齢に達する前でも引退候補になる。
const RETIREMENT_AGE_THRESHOLD: int = 38
const FORCED_RETIREMENT_RAMP_START_AGE: int = 40
const FORCED_RETIREMENT_CERTAIN_AGE: int = 48

# 自動戦力外通告(CPU/自軍ボタン共通)は **編成計画ベース** (2026-07-03 全面刷新):
# NPB の実運用どおり「来季開幕支配下の目標 (TeamFinance.OPENING_ROSTER_TARGET=68) から逆算」する。
#   放出数 = 現在籍 + 見込み補強 (ドラフト見込み+外国人不足分+補強予約+育成昇格見込み) − 目標(±jitter)
# 誰を切るかは cut_score 昇順 (各種保護は従来どおり尊重)。旧方式 (リーグ全体パーセンタイル
# + ソフト上限 + 年齢ティア表) は、保護の被覆率とロスター収支に振り回されて調整困難だったため全廃。
# 計画ベースの利点: ドラフト (同じ目標との差分埋め) と収支が連動して現実の人数感に落ち着く /
# 再実行しても目標到達済みなら追加カット 0 (冪等 = セーブ再開系の事故に強い) /
# 成績データが欠損していても人数が計画値に収まる (選定の質だけが落ちる)。
# 見込みドラフト人数 (draft_service の目標と桁を合わせる。厳密一致は不要で、実際の指名数は
# ドラフト時点の在籍から自動で再計算されるため誤差は自己補正される)。
const RELEASE_PLAN_DRAFT_ESTIMATE: int = 7
# FA/戦力外獲得など後段補強の見込み (draft_service.DRAFT_SIGNING_RESERVE と同じ桁)。
const RELEASE_PLAN_SIGNING_RESERVE: int = 2
# 育成昇格見込みとして計画に足す上限 (昇格はオフの後段で起こり支配下を増やす)。
const RELEASE_PLAN_PROMO_CAP: int = 2
# 開幕目標の球団別ゆらぎ (±)。全球団が同じ人数に収束しないための味付け。
const RELEASE_PLAN_TARGET_JITTER: int = 1
# 1球団が1オフに放出できる上限 (計画暴走の安全弁)。
const RELEASE_PLAN_MAX_PER_TEAM: int = 15
# 常時カット (無出場ベテラン等) が計画数を超えて切れる上限。健全なデータなら該当は 0〜3 人で
# 実質無制限だが、成績レコード欠損時 (全員出場ゼロに見える) に大量放出へ暴走しないための安全弁。
const RELEASE_ALWAYS_CUT_MAX: int = 6
# 入団1年目のみ rookie 保護 (2026-07-03、旧2年)。age<=23 の若手保護は別に残るので、
# 実質露出するのは大卒/社会人入団の2年目 (24歳+) だけ。
const CPU_RELEASE_ROOKIE_PROTECTION_YEARS: int = 1
const CPU_RELEASE_PHASE1_AGE: int = 30
# 常時カットの役割別「少試合」上限 (出場0も含む)。
const CPU_RELEASE_PHASE1_STARTER_MAX: int = 3
const CPU_RELEASE_PHASE1_RELIEVER_MAX: int = 10
const CPU_RELEASE_PHASE1_FIELDER_MAX: int = 20

# 戦力外プロテクト: 一定以上稼働した選手は全フェーズで保護対象 (cut 候補から除外)。
# 野手=出場試合数、先発=先発登板数、中継ぎ=救援登板数 (どちらか満たせば投手は保護)。
# 2026-07-03: 旧値 (先発8/救援15) は野手80試合に比べ極端に緩く、戦力外が野手に偏る
# (投手:野手≈1:2) 一因だったため、現実水準 (半ローテ/主力中継ぎ級) へ引き上げ。
# NPB では20登板前後の中継ぎも普通に戦力外になる。
const RELEASE_PROTECT_FIELDER_GAMES: int = 80
const RELEASE_PROTECT_STARTER_STARTS: int = 13
const RELEASE_PROTECT_RELIEVER_APPEARANCES: int = 30
# 出場数プロテクトの能力下限。総合がこれ未満なら、いくら出場しても保護しない (居座り防止)。
const RELEASE_PROTECT_MIN_OVERALL: int = 30
# 投手は「26歳以上で登板ゼロ」を最優先で戦力外にする (Phase 1 で年齢30未満でもカット)。
const CPU_RELEASE_PITCHER_NOSHOW_AGE: int = 26
# 能力プロテクトは「高能力 かつ 怪我で出場できなかった」場合のみ発動 (無条件の総合値フロアは設けない)。
const RELEASE_PROTECT_INJURY_OVERALL: int = 70
const RELEASE_PROTECT_INJURY_DAYS: int = 30

# 本職保護: 各守備位置で戦力外から守る上位人数 (overall 順)。野手 2 / 捕手 6。
const PRIMARY_PROTECT_FIELDER: int = 2
const PRIMARY_PROTECT_CATCHER: int = 6
const PRIMARY_PROTECT_MIN_OVERALL: int = 45
const RELEASE_YOUNG_PROTECT_AGE: int = 23
# 24-26歳の育成降格候補向けスコア加点(_release_cut_score)の対象年齢上限。
const RELEASE_DEVELOPMENT_PROTECT_MAX_AGE: int = 26
const RELEASE_DEVELOPMENT_SCORE_WEIGHT: float = 5.0
const RELEASE_MIDCAREER_NOSHOW_MIN_AGE: int = 27
const RELEASE_MIDCAREER_NOSHOW_MAX_AGE: int = 32
const RELEASE_MIDCAREER_NOSHOW_MAX_OVERALL: int = 55
const RELEASE_MIDCAREER_NOSHOW_PENALTY: float = 24.0

# roadmap #3 育成制度に合わせたロスター判定 (支配下→育成 / 育成→戦力外 / 育成→支配下)。
# 「今後2〜3年の期待価値」を future_value_score に一本化し、相対値・代替差で段階判定する。
#
# 統一スコア future_value_score = 現在能力 (player_value_score)
#   + 成長期待 (expected_development_score_bonus * FUTURE_GROWTH_WEIGHT) − 故障リスク (injury_value_penalty)。
# 希少性・編成適合は本職プロテクト (_compute_primary_protected_ids) / draft の need で構造的に担保し、
# スコアには混ぜない (二重評価回避)。
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


# --- 外国人の戦力外 (通常とは別基準) ---
# 支配下 70 = 日本人 66 枠 + 外国人 4 枠。外国人は「即戦力前提の高年俸枠」なので、通常の
# 年齢・出場数ベースではなく value (能力) ベースで判定する:
#   - value 上位 FOREIGN_ROSTER_LIMIT(4) を超える外国人は放出 (枠オーバー)。
#   - value が FOREIGN_RELEASE_MIN_VALUE 未満の外国人は枠内でも放出 (当たり外れの「外れ」)。
#   - 外国人枠は即戦力前提なので、野手150PA以下 / 先発10登板以下 / 救援20登板以下の
#     低稼働シーズンも放出候補にする。
# CPU は自動。自軍は戦力外エディタの自動選択に候補として出し、確定時は選択された選手だけ切る。
const FOREIGN_ROSTER_LIMIT: int = TeamFinance.FOREIGN_HELD_TARGET
const FOREIGN_RELEASE_MIN_VALUE: int = 52
const FOREIGN_RELEASE_FIELDER_MAX_PA: int = 150
const FOREIGN_RELEASE_STARTER_MAX_STARTS: int = 10
const FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES: int = 20

static func process_foreign_releases(players: Array, teams: Array, season: PSSeason, excluded_team_id: int = 0) -> Dictionary:
	var released: Array = []
	var by_team_counts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if excluded_team_id > 0 and team.id == excluded_team_id:
			continue
		var team_released: int = 0
		for entry_row in _foreign_release_entries_for_team(players, team.id, season):
			var entry: Dictionary = entry_row as Dictionary
			var player: PSPlayer = entry["player"] as PSPlayer
			_apply_release_mutation(player, season.year if season != null else 0)
			team_released += 1
			released.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": team.id,
				"position": player.position,
				"role": player.role,
				"overall": int(entry["value"]),
				"years": player.years,
				"salary": player.salary,
				"reason": str(entry.get("reason", "")),
			})
		if team_released > 0:
			by_team_counts[team.id] = team_released

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)
	return {
		"released": released,
		"released_count": released.size(),
		"by_team": by_team_counts,
	}


static func compute_foreign_release_candidates_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var ids: Array = []
	for entry_row in _foreign_release_entries_for_team(players, team_id, season):
		var entry: Dictionary = entry_row as Dictionary
		var player: PSPlayer = entry.get("player", null) as PSPlayer
		if player != null:
			ids.append(player.id)
	return ids


static func _foreign_release_entries_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var foreigners: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or not player.foreign_player:
			continue
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		foreigners.append({"player": player, "value": player_value_score(player), "record": record})
	if foreigners.is_empty():
		return []
	foreigners.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["value"]) > int((b as Dictionary)["value"])
	)
	var entries: Array = []
	for i in range(foreigners.size()):
		var entry: Dictionary = foreigners[i] as Dictionary
		var player: PSPlayer = entry["player"] as PSPlayer
		var over_slot: bool = i >= FOREIGN_ROSTER_LIMIT
		var underperform: bool = int(entry["value"]) < FOREIGN_RELEASE_MIN_VALUE
		var low_usage: bool = _is_low_usage_foreign(player, entry.get("record", null) as PSPlayerSeasonRecord)
		if not (over_slot or underperform or low_usage):
			continue
		var reason: String = "低稼働"
		if over_slot:
			reason = "枠超過"
		elif underperform:
			reason = "能力不足"
		var copy: Dictionary = entry.duplicate()
		copy["reason"] = reason
		entries.append(copy)
	return entries


static func _is_low_usage_foreign(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player == null or not player.foreign_player:
		return false
	if record == null:
		return false
	if record.is_pitcher():
		if record.is_starter_pitcher():
			return record.pitcher_stats.starts <= FOREIGN_RELEASE_STARTER_MAX_STARTS
		return record.pitcher_stats.relief_appearances <= FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES
	return record.batter_stats.plate_appearances <= FOREIGN_RELEASE_FIELDER_MAX_PA


# 指定球団について戦力外候補を選んで player_ids[] を返す。
# 自軍「自動で決める」ボタンと CPU 自動戦力外 (process_cpu_releases) 共通アルゴリズム。
#
# 設計 (2026-07-03 編成計画ベースへ全面刷新): NPB の実運用どおり「来季開幕支配下の目標
# (TeamFinance.OPENING_ROSTER_TARGET) から逆算」して切る人数を決める。
#   放出数 = 現在籍 + 見込み補強 (_release_plan_count) − 目標(±jitter)
# 誰を切るかは 2 段:
#   (A) 常時カット: 出場ゼロ/極少のベテラン (age>=30 AND 少試合、投手は26歳以上登板ゼロ)。
#       計画数と独立に必ず切るが、成績データ欠損時の暴走防止に RELEASE_ALWAYS_CUT_MAX で上限。
#   (B) 計画カット: 残り計画数を cut_score 昇順 (未出場優先) で切る。
# 保護 (両段共通): is_retired / rookie (入団 years<=1) / 若手 age<=23 / 出場実績
# (_is_protected_from_release) / 本職上位 (_compute_primary_protected_ids) / 外国人 (別基準)。
# 保護が計画数より多く残る球団は計画未達で止まる (数値目標より安全重視)。その分は
# ドラフト目標 (同じ開幕目標との差分埋め) が小さくなる形で自己補正される。
static func compute_release_candidates_for_team(players: Array, team_id: int, season: PSSeason, include_foreign_release_candidates: bool = false) -> Array:
	# (1) チーム全員 (非引退非マネージャー候補) を集める。rookie protection はここでは適用しない。
	var roster_records_all: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		# roadmap #3: 育成選手は支配下枠外。戦力外候補には含めない。
		if player.development_player:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		roster_records_all.append({"player": player, "record": record})
	if roster_records_all.is_empty():
		return []

	var foreign_release_set: Dictionary = {}
	if include_foreign_release_candidates:
		for pid_v in compute_foreign_release_candidates_for_team(players, team_id, season):
			foreign_release_set[int(pid_v)] = true

	# 本職保護: 各守備位置の上位 (野手2 / 捕手6) 名のうち、能力/年齢の実力基準を満たす選手だけを
	# 戦力外対象から除外する (draft_service の本職補強と対)。頭数が少ないだけでは保護しない
	# (2026-07-02: 旧実装は在籍数が keep 以下なら無条件保護しており、捕手が事実上聖域化していた)。
	var protected_primary_ids: Dictionary = _compute_primary_protected_ids(roster_records_all)
	# 外国人は通常の戦力外では基本的に保護する。ただし自軍自動選択では、外国人専用条件
	# (4枠超過 / 能力不足 / 低稼働) に該当する選手だけ候補に入れる。
	for row in roster_records_all:
		var fp: PSPlayer = (row as Dictionary)["player"] as PSPlayer
		if fp.foreign_player and not foreign_release_set.has(fp.id):
			protected_primary_ids[fp.id] = true

	var cut_ids: Array = []
	var cut_set: Dictionary = {}
	if include_foreign_release_candidates:
		for row in roster_records_all:
			var fp: PSPlayer = (row as Dictionary)["player"] as PSPlayer
			if not foreign_release_set.has(fp.id):
				continue
			cut_ids.append(fp.id)
			cut_set[fp.id] = true

	# ポジション構成: 本職の在籍数が快適水準を超えるポジションの選手は切られやすくする
	# (cut_score へ減点)。打撃偏重の総合値だけで切ると守備型 (SS/CF/2B) が先に消えて
	# コーナー (1B/LF) が蓄積するため、現実の球団運用どおり構成バランスを考慮する。
	var primary_position_counts: Dictionary = {}
	for row in roster_records_all:
		var count_player: PSPlayer = (row as Dictionary)["player"] as PSPlayer
		if count_player != null and not count_player.is_pitcher():
			primary_position_counts[count_player.position] = int(primary_position_counts.get(count_player.position, 0)) + 1

	# (2) 保護されていない選手を「常時カット該当」と「通常プール」に振り分ける。
	var always_cut_pool: Array = []
	var normal_pool: Array = []
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
		if cut_set.has(player.id):
			continue
		if _has_rookie_release_protection(player):
			continue
		if _is_young_development_protected(player):
			continue
		if _is_protected_from_release(player, record) or protected_primary_ids.has(player.id):
			continue
		var entry: Dictionary = {
			"player": player,
			"zero_app": _zero_appearances(record),
			"cut_score": _release_cut_score(player, record) - _position_surplus_release_penalty(primary_position_counts, player),
		}
		if _is_always_cut_candidate(player, record):
			always_cut_pool.append(entry)
		else:
			normal_pool.append(entry)

	# (3) 常時カット: 無出場/極少出場のベテランは計画数と独立に切る (cut_score 昇順、
	# 成績欠損時の暴走防止に RELEASE_ALWAYS_CUT_MAX まで)。
	var score_asc: Callable = func(a, b) -> bool:
		var ea: Dictionary = a as Dictionary
		var eb: Dictionary = b as Dictionary
		if bool(ea["zero_app"]) != bool(eb["zero_app"]):
			return bool(ea["zero_app"])
		return float(ea["cut_score"]) < float(eb["cut_score"])
	always_cut_pool.sort_custom(score_asc)
	for i in range(min(always_cut_pool.size(), RELEASE_ALWAYS_CUT_MAX)):
		var pid: int = int(((always_cut_pool[i] as Dictionary)["player"] as PSPlayer).id)
		cut_ids.append(pid)
		cut_set[pid] = true
	# 上限を超えた常時カット該当者は通常プールへ回す (計画数の範囲でなら追加で切れる)。
	for i in range(RELEASE_ALWAYS_CUT_MAX, always_cut_pool.size()):
		normal_pool.append(always_cut_pool[i])

	# (4) 計画カット: 開幕目標から逆算した残り人数を cut_score 昇順 (未出場優先) で切る。
	var plan_count: int = _release_plan_count(players, team_id, roster_records_all.size())
	normal_pool.sort_custom(score_asc)
	for entry_row in normal_pool:
		if cut_ids.size() >= plan_count or cut_ids.size() >= RELEASE_PLAN_MAX_PER_TEAM:
			break
		var pid: int = int(((entry_row as Dictionary)["player"] as PSPlayer).id)
		if cut_set.has(pid):
			continue
		cut_ids.append(pid)
		cut_set[pid] = true

	if cut_ids.is_empty():
		return []

	# (7) UI 表示用に cut_score 昇順で並び替えて返す
	var scored: Array = []
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if not cut_set.has(player.id):
			continue
		var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
		scored.append({"player_id": player.id, "score": _release_cut_score(player, record)})
	scored.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["score"]) < float((b as Dictionary)["score"])
	)
	var result_ids: Array = []
	for entry in scored:
		result_ids.append(int((entry as Dictionary)["player_id"]))
	return result_ids


# ポジション別の本職在籍「快適水準」。これを超える分だけ戦力外優先度が上がる。
# 捕手はブルペン捕手/第3捕手需要で多め、一塁は最少 (コンバート受け皿なので抱えすぎない)。
const RELEASE_POSITION_COMFORT: Dictionary = {2: 6, 3: 3, 4: 4, 5: 4, 6: 4, 7: 4, 8: 4, 9: 4}
const RELEASE_POSITION_SURPLUS_PENALTY: float = 6.0


static func _position_surplus_release_penalty(primary_position_counts: Dictionary, player: PSPlayer) -> float:
	if player == null or player.is_pitcher():
		return 0.0
	var comfort: int = int(RELEASE_POSITION_COMFORT.get(player.position, 4))
	var surplus: int = int(primary_position_counts.get(player.position, 0)) - comfort
	if surplus <= 0:
		return 0.0
	return float(surplus) * RELEASE_POSITION_SURPLUS_PENALTY


# 常時カット該当か: 出場ゼロ/極少のベテラン (age>=30 AND 少試合)、投手は26歳以上で登板ゼロ。
static func _is_always_cut_candidate(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if _is_pitcher_noshow(player, record):
		return true
	return player.age >= CPU_RELEASE_PHASE1_AGE and _has_low_appearance_phase1(record)


# 編成計画: 来季開幕支配下の目標 (TeamFinance.OPENING_ROSTER_TARGET±jitter) から逆算した放出数。
#   放出数 = 現在籍 + 見込み補強 (ドラフト見込み + 外国人4人確保の不足分 + 補強予約 + 育成昇格見込み) − 目標
# 見込み補強は概算でよい: 実際のドラフト指名数はドラフト時点の在籍から同じ目標との差分で
# 再計算されるため、ここの誤差は次工程で自己補正される。
static func _release_plan_count(players: Array, team_id: int, roster_count: int) -> int:
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
	var inflow: int = RELEASE_PLAN_DRAFT_ESTIMATE + foreign_shortfall + RELEASE_PLAN_SIGNING_RESERVE \
			+ mini(promo_ready, RELEASE_PLAN_PROMO_CAP)
	var target: int = TeamFinance.OPENING_ROSTER_TARGET \
			+ Rng.range_int(-RELEASE_PLAN_TARGET_JITTER, RELEASE_PLAN_TARGET_JITTER)
	return clampi(roster_count + inflow - target, 0, RELEASE_PLAN_MAX_PER_TEAM)


# 投手 = pitcher_stats.games == 0、野手 = batter_stats.games == 0、record null も true。
static func _zero_appearances(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return true
	if record.is_pitcher():
		return record.pitcher_stats.games <= 0
	return record.batter_stats.games <= 0


# 戦力外プロテクト判定。true なら全フェーズで cut 候補から除外する。
#  (1) 出場数プロテクト: 野手 games / 先発 starts / 中継ぎ relief_appearances が基準以上。
#      投手は starts か relief_appearances のどちらかを満たせば保護 (スイングマンも救済)。
#      **ただし能力下限 (総合 >= RELEASE_PROTECT_MIN_OVERALL) を満たす場合のみ**。
#      消去法で出続けるだけの能力一桁の老選手が「出場数で保護され続けて居座る」ループを防ぐ。
#  (2) 能力プロテクト: 高能力 (表示総合値 >= 閾値) かつ 累積怪我日数が閾値以上のときのみ。
#      = 本来レギュラー級だが怪我で出場が伸びなかった選手を救済。怪我無しの低出場控えは保護しない。
static func _is_protected_from_release(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return false
	var overall: int = player_value_score(player)
	# (1) 出場数プロテクト (能力下限を満たす場合のみ)
	if overall >= RELEASE_PROTECT_MIN_OVERALL:
		if record.is_pitcher():
			if record.pitcher_stats.starts >= RELEASE_PROTECT_STARTER_STARTS:
				return true
			if record.pitcher_stats.relief_appearances >= RELEASE_PROTECT_RELIEVER_APPEARANCES:
				return true
		elif record.batter_stats.games >= RELEASE_PROTECT_FIELDER_GAMES:
			return true
	# (2) 怪我ゲート能力プロテクト (高能力かつ累積怪我)
	if record.season_injury_days >= RELEASE_PROTECT_INJURY_DAYS:
		if overall >= RELEASE_PROTECT_INJURY_OVERALL:
			return true
	return false


# 24-26歳を条件付きで保護する分岐は、_should_demote_to_development (DEMOTE_PROSPECT_MAX_AGE=26)
# の判定と閾値がほぼ同じ形 (年齢+成長期待) で重複しており、両者の境界がわずかにずれていたせいで
# 「26歳未満で保護されない年齢」が実質1歳分しか残らず降格対象が特定の年齢に偏るバグがあった
# (2026-07-02)。ここでは純粋age<=23の保護のみ残し、24-26歳の去就は
# _should_demote_to_development に一本化する。
static func _is_young_development_protected(player: PSPlayer) -> bool:
	return player != null and player.age <= RELEASE_YOUNG_PROTECT_AGE


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


static func _release_cut_score(player: PSPlayer, record: PSPlayerSeasonRecord) -> float:
	var score: float = TeamAutoAI.cut_score(player, record)
	var development_bonus: float = expected_development_score_bonus(player.age, 6, player.position)
	if player.age <= RELEASE_DEVELOPMENT_PROTECT_MAX_AGE:
		score += development_bonus * RELEASE_DEVELOPMENT_SCORE_WEIGHT
	# 同程度の戦力なら高年俸ほど整理対象に近づけ、限られた予算を主力と補強へ回す。
	score -= TeamFinance.ai_acquisition_cost_penalty(player.salary)
	var overall: int = player_value_score(player)
	if player.age >= RELEASE_MIDCAREER_NOSHOW_MIN_AGE and player.age <= RELEASE_MIDCAREER_NOSHOW_MAX_AGE:
		if overall <= RELEASE_MIDCAREER_NOSHOW_MAX_OVERALL and _zero_appearances(record):
			score -= RELEASE_MIDCAREER_NOSHOW_PENALTY
	return score


# 各守備位置の本職 (primary position) 上位 N 名 (overall 順) のうち、実力基準
# (若手 age<=23 / overall>=45 かつ高齢無出場でない) を満たす選手を戦力外保護する。
# 野手は各位置 2 名、捕手は 6 名。draft_service の本職補強 (_primary_position_need_bonus) と対。
# 頭数の無条件保証はしない (位置の空洞化は need-driven ドラフトで補充する前提)。
static func _compute_primary_protected_ids(roster_records_all: Array) -> Dictionary:
	var by_position: Dictionary = {}
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if player == null or player.is_pitcher():
			continue
		var pos: int = player.position
		if not by_position.has(pos):
			by_position[pos] = []
		(by_position[pos] as Array).append({
			"id": player.id,
			"overall": player_value_score(player),
			"age": player.age,
			"record": data.get("record"),
		})
	var protected: Dictionary = {}
	for pos in by_position.keys():
		var arr: Array = by_position[pos] as Array
		arr.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
		)
		var keep: int = PRIMARY_PROTECT_CATCHER if int(pos) == 2 else PRIMARY_PROTECT_FIELDER
		for i in range(min(keep, arr.size())):
			var entry: Dictionary = arr[i] as Dictionary
			# 頭数が少ないだけでは保護しない (2026-07-02: 旧実装は在籍数が keep 以下なら無条件で
			# 全員保護しており、捕手のように保有数が少ないポジションが事実上聖域化していた=
			# 高齢・無出場でも切られない捕手が居座り、帳尻合わせで他ポジションの若手が余計に
			# 切られる原因になっていた)。能力/年齢の実力基準を満たす選手だけを保護する。
			if int(entry.get("age", 99)) <= RELEASE_YOUNG_PROTECT_AGE:
				protected[int(entry["id"])] = true
				continue
			if int(entry.get("overall", 0)) < PRIMARY_PROTECT_MIN_OVERALL:
				continue
			# 出場実績のない高齢選手は、本職上位でも潜在能力 (overall) だけでは保護しない
			# (Phase 1 の常時カット = age>=30 AND 少試合 をこの保護が妨げないようにする)。
			# 旧実装は record を一切見なかったため「出場ゼロの30代非捕手」が本職上位というだけで
			# 毎年生き残るバグがあった (2026-07-02)。怪我で出場が伸びなかった高能力選手は
			# _is_protected_from_release の怪我ゲート側で別途保護される。
			var rec: PSPlayerSeasonRecord = entry.get("record") as PSPlayerSeasonRecord
			if int(entry.get("age", 99)) >= CPU_RELEASE_PHASE1_AGE and _has_low_appearance_phase1(rec):
				continue
			protected[int(entry["id"])] = true
	return protected


# 投手 26歳以上で今季登板ゼロか。Phase 1 で年齢30未満でも最優先カットするための判定。
# record null (今季記録なし=登板ゼロ) でも投手かつ26歳以上なら true。
static func _is_pitcher_noshow(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player.age < CPU_RELEASE_PITCHER_NOSHOW_AGE:
		return false
	if record == null:
		return player.is_pitcher()
	if not record.is_pitcher():
		return false
	return record.pitcher_stats.games <= 0


# 常時カットの「少試合」判定。record null も true (出場ゼロ扱い)。
# 役割別: 先発 starts ≤ 3、リリーフ games ≤ 10、野手 games ≤ 20。
static func _has_low_appearance_phase1(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return true
	if record.is_pitcher():
		if record.is_starter_pitcher():
			return record.pitcher_stats.starts <= CPU_RELEASE_PHASE1_STARTER_MAX
		return record.pitcher_stats.games <= CPU_RELEASE_PHASE1_RELIEVER_MAX
	return record.batter_stats.games <= CPU_RELEASE_PHASE1_FIELDER_MAX


static func _find_player_by_id(players: Array, pid: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.id == pid:
			return player
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
	return _has_low_appearance_phase1(record)


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


# --- STEP 5 (R4): 契約更新 (年俸再査定 + FA権遷移 + 予算会計) ---

# 在籍年数モデルでは固定複数年契約の年俸ロックは持たず、毎オフの再査定で十分。
# このステップで以下を一括処理する:
#   (1) 年俸の再査定 (_compute_new_salary)
#   (2) FA権/保有権の contract_status 遷移 (1軍登録日数 vs fa_eligible_years * 145)
#   (3) チーム予算 (funds) に対する年俸総額の会計サマリ
# Step1 では FA権取得選手もそのまま球団に残す (auto-retain)。放出先は Step2 設計のみ。
#
# タイミング注意: このステップは finalize 前 (years 加算前) に走る。FA権はこの年の
# 1軍登録日数を source_data.fa_nissuu に加算してから判定する。
static func process_contract_update(players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var changes: Array = []
	var new_fa: Array = []
	# WAR 算出用のリーグコンテキストを 1 度だけ構築 (年俸査定で各選手の WAR を使う)。
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var year: int = season.year if season != null else 0
	if season != null and teams != null:
		var team_ids: Array = []
		for team_row in teams:
			var team_for_days: PSTeam = team_row as PSTeam
			if team_for_days != null:
				team_ids.append(team_for_days.id)
		season.accrue_all_active_roster_days(team_ids, season.current_day)
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		# (1) 年俸再査定: 今季の記録 (WAR + 出場試合数 + 成績) から前年俸を裁定。
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		_apply_fa_service_days(player, record, season)
		var war: float = _season_war(record, league_ctx)
		var old_salary: int = player.salary
		var skip_salary_update: bool = _market_contract_salary_is_locked(player, year)
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
		# (2) FA権/保有権の contract_status 遷移
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
	new_fa.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["team_id"]) == int(db["team_id"]):
			return int(da["age"]) > int(db["age"])
		return int(da["team_id"]) < int(db["team_id"])
	)

	# (3) チーム予算会計
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
		"new_fa": new_fa,
		"new_fa_count": new_fa.size(),
		"team_budgets": team_budgets,
		"over_budget_count": over_budget_count,
	}


# FA移籍・戦力外獲得で今オフに合意した年俸は、直後の契約更新では再査定しない。
# 翌オフからは通常の成績査定へ戻る。
static func _market_contract_salary_is_locked(player: PSPlayer, year: int) -> bool:
	if year <= 0:
		return false
	var fa_locked: bool = int(player.source_data.get("fa_signed_year", 0)) == year and player.source_data.has("fa_contract_salary")
	var released_locked: bool = int(player.source_data.get("released_signed_year", 0)) == year and player.source_data.has("released_contract_salary")
	return fa_locked or released_locked


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
	return clampi(new_salary, min_sal, SALARY_MAX)


static func _rand_z(center: int, variance: int = 12, min_value: int = 25, max_value: int = 88) -> float:
	# center/variance/min/max は 1-100 の talent authoring 入力。生成される能力値そのものは
	# z 空間で直接抽選し、1-100 の中間能力値を作らない (シミュは z 能力のみ使用)。
	var center_z: float = PSAbilityScale.display_to_z(center)
	var variance_z: float = float(variance) / PSAbilityScale.DISPLAY_STDEV
	var value_z: float = center_z + (Rng.roll_float() * 2.0 - 1.0) * variance_z
	return clampf(value_z, PSAbilityScale.display_to_z(min_value), PSAbilityScale.display_to_z(max_value))


static func _range_float(min_value: float, max_value: float) -> float:
	return min_value + (max_value - min_value) * Rng.roll_float()
