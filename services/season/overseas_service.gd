extends RefCounted
class_name OverseasService

# メジャー挑戦 (海外移籍) の単一ソース。オフの「メジャー挑戦」ステップ 1 つで、海外への流出・
# 海外からの復帰・海外組の年次変動をまとめて解決する。
#
# ## 流出は 2 経路 (資格と補償が違うだけの同じ判定)
#   ポスティング — **国内FA権の 1 年前** (大卒 6 年 / 高卒 7 年) で一律に判定する。
#                  成立すると譲渡金が元球団へ入る。FA で失う前に対価を得る、という球団側の動機に対応する。
#   海外FA       — 一軍登録 145日 × OVERSEAS_FA_YEARS。補償は無い。
# **志願すれば必ず成立する** (自軍も CPU も球団は承認するものとする — ユーザー決定)。
# 国内FA権を得てから海外FA権までの間 (大卒 7〜8 年 / 高卒 8 年) は海外へ出る経路が無い
# (国内FA宣言はできる)。
# 誰に声が掛かるかは経路に依らず MLB の関心 (mlb_interest = 能力 × 年齢) で決まる。若いうちに窓が
# 来るポスティング組が自然に有利になり、実 NPB と同じくポスティングが主流になる。
#
# ## 海外にいる間の表現
# `source_data.overseas_year` を立てて `retired=true` / `team_id=0` にする
# (外国人の帰国 = ForeignPlayerService._apply_contract_departure と同じ形)。`is_retired()` の
# ガードが既に全コードで「NPB に居ない」として効くので、ロースター・予算・起用・保存のどれにも
# 追加のガードが要らない。「引退」と区別したい箇所だけが `PSPlayer.is_overseas()` を見る。
#
# その代償として **加齢と成長が止まる** (`GameDb.advance_players_one_year` も
# `OffseasonService.process_growth_decay` も retired を除外する)。海外組の年次変動は
# 本サービスの `_advance_overseas_players` が肩代わりする — ここを消すと、5 年後に同じ年齢の
# 選手が帰ってくる。
#
# ## ステップ内の順序 (加齢が 1 年 1 回になる条件)
#   1. 復帰 / 海外での引退 — 復帰者はこの時点で NPB 側へ戻るので、以後は通常の経路
#      (成長ステップ・`advance_players_one_year`) が年次変動を担当する。
#   2. 流出 (ポスティング → 海外FA)
#   3. 海外組の加齢・成長 — **この時点で海外にいる全員**が対象。今オフ流出した選手を含めるのは、
#      彼らがオフ終端の `advance_players_one_year` から外れるため。ここを 2 より前に置くと
#      新規流出組が 1 年ぶん取り残される。
#
# ## 置き場所
# `AppState.OFFSEASON_STEP_ORDER` の FA宣言の直後 = 戦力外・ドラフトより前。放出数は
# 「在籍 + 見込み流入 − 目標」(`OffseasonService._release_plan_count`) で決まるので、先に
# 抜けた/戻った人数がそのまま編成計画に乗り、穴埋めが制度側で回る。
# 国内FA宣言が離脱を FA市場まで遅らせているのとは逆の扱いで、理由は
# 「宣言者の多くは残留するので先に抜くと計画がズレる」に対し、海外移籍は確定離脱だから。

# --- 資格 ---
# 海外FA権。実 NPB は国内FA (7/8年) と別枠で一律 9 年。台帳は国内FAと同じ source_data.fa_nissuu。
const OVERSEAS_FA_YEARS: int = 9
# ポスティングを判定する時期 = 国内FA権 (PSPlayer.fa_eligible_years = 高卒8 / その他7) の何年前か。
# 資格は国内FA権を得るまでの 1 年ぶんの窓で、選手ごとの出身に従う。
# 実 NPB のポスティングに年数要件は無い (球団の同意だけ) が、ここを増やすほど若手の流出が増える
# 唯一のノブなので、まずは「国内FA の 1 年前」に固定して量を読みやすくしてある。
const POSTING_YEARS_BEFORE_DOMESTIC_FA: int = 1
# 志願の足切り (OffseasonService.player_value_score)。これ未満の選手には MLB から声が掛からない。
# 流出量を絞るノブで、上げても**残った選手の志願確率は変わらない** (関心の基準は
# INTEREST_REFERENCE_VALUE で別に持つ) — 「基準を厳しく = 並の主力は行かなくなる」の意味になる。
# 較正 (2026-09-21): 球団承認の抽選を廃止 (全員自動承認) して期待流出が年 2.3 人に増えたぶんを、
# ここを 70 → 80 に上げて年 1.76 人 (ポスティング 70%) へ戻した。この値の前後で急峻に効く
# (79: 1.99 / 81: 1.48 人) うえ、定常では資格者が 8〜19 人と母集団 20 人を下回るので、
# **流出量を実際に決めているのはこの足切り**。能力スケールが動いたら (世界再生成など) 測り直すこと。
const MIN_CHALLENGE_VALUE: int = 80
# MLB の関心の基準点 (この評価・プライム年齢で関心 1.0)。主力級の目安を
# ForeignPlayerService.CPU_FOREIGN_MULTI_YEAR_VALUE と揃えてある。
const INTEREST_REFERENCE_VALUE: int = 70
# これを超える年齢では挑戦しない (実 NPB の移籍も 20 代後半〜30 代前半に集中する)。
const MAX_CHALLENGE_AGE: int = 33
# **MLB が見ているのはリーグの上澄みだけ**。資格・年齢・足切りを通った選手を MLB の関心
# (mlb_interest) の高い順に並べ、上位この人数だけを志願の母集団にする。
# 母集団相対にしてあるのは、能力スケールが年々動いても (成長/ドラフトの較正、世界再生成)
# 流出量が勝手に膨らまないようにするため — 絶対閾値だけで絞ると、実測で 31〜61 人が
# 資格を持ち、期待流出が年 8〜16 人まで膨れた (2026-09-21 の計測)。
const CHALLENGE_POOL_SIZE: int = 20

# --- MLB の関心 (mlb_interest = 能力 × 年齢) ---
# 母集団の順位・志願確率・譲渡金はすべてこの 1 つの値から決まる。
# 能力: 基準点 (INTEREST_REFERENCE_VALUE) を超えた 1 点ごとに関心が VALUE_INTEREST_PER_POINT ずつ
# 増える (基準点ちょうど = 1.0)。
const VALUE_INTEREST_PER_POINT: float = 0.15
# 年齢: MLB は長く使える若手を強く評価する (実例の移籍年齢は大谷 23 / 佐々木 23 / 山本 25 /
# 鈴木誠也 27 / 吉田正尚 29 / 今永 30)。プライム以下は上乗せ、超えると 1 歳ごとに目減りする。
# これが無いと、能力だけで勝るピーク期のベテラン (海外FA 組) が関心を独占し、
# ピーク前に窓が来るポスティング組 (大卒 6 年目≒28 歳 / 高卒 7 年目≒25 歳) が出ていかない
# (年齢なしの版は、初期シードでポスティングが 5 年間 0 件だった)。
# 形は実例の移籍年齢 (23〜31 歳が大半、32 歳以上は稀) に合わせる: 27 歳まで 1.0 以上、
# 30 歳で 0.64、33 歳で 0.28。減衰を 0.14 にした版は海外FA組 (大卒なら 30 歳前後で権利) が
# ほぼ出ていかず、ポスティング 100% / 年 0.67 人まで落ちた (2026-09-21)。
const MLB_PRIME_AGE: int = 27
const YOUTH_INTEREST_PER_YEAR: float = 0.05
const AGE_INTEREST_DECAY_PER_YEAR: float = 0.12
const MIN_AGE_INTEREST: float = 0.15
const MAX_AGE_INTEREST: float = 1.3

# --- 志願確率 = 経路の基礎確率 × mlb_interest ---
# 基礎確率は同じ水準。ポスティングの窓の選手は若くて (関心が高く) 数も多いので、
# 量ではポスティングが主流になる。
# 較正 (2026-09-21, seed 20260528 の 12 季): 経路別の期待流出は基礎確率に比例するので、
# 実測の期待値 (ポスティング 1.33 / 海外FA 0.31 人/年、基礎確率 0.06 / 0.04 のとき) から
# 「年 1.7〜1.8 人・ポスティング 7 割強」になるよう海外FA側を 1.5 倍にした。
# 初期シードの溜まりが抜けた後はポスティング 8 割強になる。
const POSTING_BASE_CHANCE: float = 0.06
const OVERSEAS_FA_BASE_CHANCE: float = 0.06
const MAX_CHALLENGE_CHANCE: float = 0.35
# リーグ全体の年間流出上限。**安全弁であって目標ではない** — ここに毎年張り付いていたら
# 確率側が高すぎる (同じ失敗が FA 宣言率で起きた → project_fa_market_v1_5)。
# 実 NPB のポスティング + 海外FA は年 0〜4 人。
const MAX_DEPARTURES_PER_YEAR: int = 3

# --- 頻度 (オプション設定 AppState.overseas_challenge_frequency) ---
# 志願確率に掛ける倍率と、年間上限。"off" は**新規の流出だけ**を止める — 海外にいる選手の
# 加齢と復帰は続けるので、途中で切っても海外組は取り残されずに帰ってくる。
# 倍率は上限クランプ (MAX_CHALLENGE_CHANCE) の**後**に掛ける (challenge_chance) ので、
# 期待流出がそのまま倍率倍になる。年間上限も同じ比率で広げないと「多め」で上限に張り付く。
const FREQUENCY_OFF: String = "off"
const FREQUENCY_LOW: String = "low"
const FREQUENCY_STANDARD: String = "standard"
const FREQUENCY_HIGH: String = "high"
const FREQUENCY_ORDER: Array[String] = [FREQUENCY_OFF, FREQUENCY_LOW, FREQUENCY_STANDARD, FREQUENCY_HIGH]
const FREQUENCY_SETTINGS: Dictionary = {
	FREQUENCY_OFF: {"chance_mult": 0.0, "max_departures": 0},
	FREQUENCY_LOW: {"chance_mult": 0.5, "max_departures": 2},
	FREQUENCY_STANDARD: {"chance_mult": 1.0, "max_departures": MAX_DEPARTURES_PER_YEAR},
	FREQUENCY_HIGH: {"chance_mult": 2.0, "max_departures": 6},
}
# 倍率を掛けた後の上限 (1 人の志願確率が 1 に張り付かないように)。
const MAX_SCALED_CHALLENGE_CHANCE: float = 0.9

# --- 譲渡金 ---
# 元球団の funds へ加算する。FA の金銭補償と同じ「そのオフの補強予算だけが動く」性質で
# (ロード時に TeamFinance.apply_fixed_budget が固定額へ戻す)、予算設計を跨がない。
# 実際の譲渡金は球団予算を超える規模になるため、star 帯の外国人 1 人ぶんに収めてある。
# 実際の譲渡金は MLB での契約総額に比例し、契約は若くて良い選手ほど大きい — ので mlb_interest に
# 比例させる (関心 1.0 = 基準点ちょうどのプライム年齢で POSTING_FEE_MIN)。
const POSTING_FEE_PER_INTEREST: int = 7000
const POSTING_FEE_MIN: int = 10000
const POSTING_FEE_MAX: int = 30000

# --- 復帰 ---
# 最低滞在シーズン数。離脱したオフの翌シーズンが海外 1 年目。
const RETURN_MIN_SEASONS: int = 3
const RETURN_BASE_CHANCE: float = 0.18
# この年齢を超えたぶんだけ復帰確率が上がる (実 NPB の復帰も 30 代半ばに集中する)。
const RETURN_AGE_RAMP_START: int = 32
const RETURN_CHANCE_PER_AGE: float = 0.12
const RETURN_MAX_CHANCE: float = 0.75
# ここまでに戻らなければ海外で現役を終える。
const RETURN_GIVEUP_AGE: int = 38
# 復帰時の年俸 = 離脱時の年俸 × この倍率。海外での実績ぶんのプレミアム。
const RETURN_SALARY_MULT: float = 1.2

# --- 海外での成長 ---
# 伸びにだけ掛かる係数 (衰えは NPB と同じ)。1.0 未満にすると「行ったきり伸びずに年を取る」ため、
# 復帰組が離脱時より小さくなって戻る。
const OVERSEAS_GROWTH_SCALE: float = 0.7

# --- source_data キー ---
# 離脱中を表す印は PSPlayer.SOURCE_KEY_OVERSEAS_YEAR (is_overseas() が読む)。残りは本サービス専用。
const SOURCE_KEY_OVERSEAS_TEAM: String = "overseas_from_team_id"
const SOURCE_KEY_OVERSEAS_ROUTE: String = "overseas_route"
const SOURCE_KEY_OVERSEAS_SALARY: String = "overseas_salary"
# 復帰したオフの年。契約更改の査定ロック (OffseasonService._contract_salary_is_locked) が読む —
# 前年の NPB 成績が無いので、査定に通すと市場価値 floor まで落ちる (ドラフト新人と同じ罠)。
const SOURCE_KEY_OVERSEAS_RETURN_YEAR: String = "overseas_return_year"

const ROUTE_POSTING: String = "posting"
const ROUTE_FA: String = "fa"


# オフの「メジャー挑戦」ステップ本体。players / teams を直接書き換え、結果サマリを返す。
# frequency は FREQUENCY_* (オプション設定)。未知の値は標準として扱う。
static func process_overseas_challenge(players: Array, teams: Array, season: PSSeason, frequency: String = FREQUENCY_STANDARD) -> Dictionary:
	var year: int = season.year if season != null else 0
	var returned: Array = []
	var overseas_retired: Array = []
	var departed: Array = []
	var setting: Dictionary = frequency_setting(frequency)
	if year <= 0:
		return _result(departed, returned, overseas_retired, 0, 0)

	_resolve_returns(players, year, returned, overseas_retired)
	var departure_stats: Dictionary = _resolve_departures(players, teams, year, departed, setting)
	var abroad: int = _advance_overseas_players(players)

	var result: Dictionary = _result(departed, returned, overseas_retired, int(departure_stats.get("fee_total", 0)), abroad)
	departure_stats.erase("fee_total")
	result.merge(departure_stats, true)
	result["frequency"] = normalize_frequency(frequency)
	return result


static func normalize_frequency(frequency: String) -> String:
	return frequency if FREQUENCY_SETTINGS.has(frequency) else FREQUENCY_STANDARD


static func frequency_setting(frequency: String) -> Dictionary:
	return FREQUENCY_SETTINGS[normalize_frequency(frequency)] as Dictionary


static func _result(departed: Array, returned: Array, overseas_retired: Array, fee_total: int, abroad: int) -> Dictionary:
	return {
		"departed": departed,
		"departed_count": departed.size(),
		"returned": returned,
		"returned_count": returned.size(),
		"overseas_retired": overseas_retired,
		"overseas_retired_count": overseas_retired.size(),
		"posting_fee_total": fee_total,
		"overseas_active_count": abroad,
		# 較正用。expected_departures (= 志願確率の合計) が MAX_DEPARTURES_PER_YEAR を
		# 超えていたら上限が binding = 確率側が高すぎる。
		"candidates_count": 0,
		"expected_departures": 0.0,
	}


# 海外滞在シーズン数 (離脱したオフの翌シーズンが 1 年目)。
static func seasons_abroad(player: PSPlayer, year: int) -> int:
	if player == null or year <= 0 or not player.is_overseas():
		return 0
	return maxi(0, year - int(player.source_data.get(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR, 0)))


# 挑戦の経路。"" = 資格なし。日数台帳は国内FAと共有 (PSPlayer.fa_service_days)。
static func challenge_route(player: PSPlayer) -> String:
	if player == null:
		return ""
	var days: int = player.fa_service_days()
	if days >= OVERSEAS_FA_YEARS * PSPlayer.FA_SERVICE_DAYS_PER_YEAR:
		return ROUTE_FA
	# ポスティングの窓は国内FA権の手前まで。国内FA権を得た後は海外FA権まで経路が無い。
	var domestic_required: int = player.fa_service_days_required()
	var posting_from: int = domestic_required - POSTING_YEARS_BEFORE_DOMESTIC_FA * PSPlayer.FA_SERVICE_DAYS_PER_YEAR
	if days >= posting_from and days < domestic_required:
		return ROUTE_POSTING
	return ""


# 志願の母集団。FA宣言者を外すのは、国内FA市場と海外挑戦で同じ選手を二重に動かさないため
# (宣言した時点で国内市場に出ると決めた選手、という扱い)。
static func is_challenge_candidate(player: PSPlayer, year: int) -> bool:
	if player == null or player.is_retired() or player.development_player:
		return false
	if player.foreign_player:
		return false
	if player.team_id <= 0 or PSFarmLeague.is_farm_club_id(player.team_id):
		return false
	if player.is_fa_declared(year):
		return false
	if player.is_multi_year_locked_offseason(year):
		return false
	if player.age > MAX_CHALLENGE_AGE:
		return false
	return OffseasonService.player_value_score(player) >= MIN_CHALLENGE_VALUE


# 年齢による関心の倍率。プライム以下は若いほど上乗せ、超えると 1 歳ごとに目減りする。
static func age_interest(age: int) -> float:
	var years_from_prime: int = age - MLB_PRIME_AGE
	if years_from_prime <= 0:
		return minf(MAX_AGE_INTEREST, 1.0 - float(years_from_prime) * YOUTH_INTEREST_PER_YEAR)
	return maxf(MIN_AGE_INTEREST, 1.0 - float(years_from_prime) * AGE_INTEREST_DECAY_PER_YEAR)


# MLB の関心 = 能力 × 年齢。基準点ちょうどのプライム年齢が 1.0。
static func mlb_interest(value: int, age: int) -> float:
	var ability: float = 1.0 + float(maxi(0, value - INTEREST_REFERENCE_VALUE)) * VALUE_INTEREST_PER_POINT
	return ability * age_interest(age)


static func posting_fee_for_interest(interest: float) -> int:
	var raw: int = POSTING_FEE_MIN + int(round(maxf(0.0, interest - 1.0) * float(POSTING_FEE_PER_INTEREST)))
	return clampi(OffseasonService.round_salary_2sig(raw), POSTING_FEE_MIN, POSTING_FEE_MAX)


# 志願確率 (= 成立確率。球団は必ず承認する)。
# frequency_mult (オプションの頻度) はクランプ後に掛けるので、期待流出がそのまま倍率倍になる。
static func challenge_chance(route: String, interest: float, frequency_mult: float = 1.0) -> float:
	var base: float = POSTING_BASE_CHANCE if route == ROUTE_POSTING else OVERSEAS_FA_BASE_CHANCE
	var chance: float = clampf(base * interest, 0.0, MAX_CHALLENGE_CHANCE)
	return clampf(chance * frequency_mult, 0.0, MAX_SCALED_CHALLENGE_CHANCE)


static func return_chance(age: int) -> float:
	var ramp: float = float(maxi(0, age - RETURN_AGE_RAMP_START)) * RETURN_CHANCE_PER_AGE
	return clampf(RETURN_BASE_CHANCE + ramp, 0.0, RETURN_MAX_CHANCE)


# --- 流出 ---

# 評価の高い順に志願を抽選し、成立したぶんだけ上限を消費する。
# 返り値は {fee_total, candidates_count, expected_departures} (後ろ2つは較正用の診断)。
static func _resolve_departures(players: Array, teams: Array, year: int, departed: Array, setting: Dictionary) -> Dictionary:
	var frequency_mult: float = float(setting.get("chance_mult", 1.0))
	var eligible: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not is_challenge_candidate(player, year):
			continue
		var route: String = challenge_route(player)
		if route.is_empty():
			continue
		var value: int = OffseasonService.player_value_score(player)
		eligible.append({"player": player, "route": route, "value": value, "interest": mlb_interest(value, player.age)})
	eligible.sort_custom(func(a: Variant, b: Variant) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if float(da["interest"]) != float(db["interest"]):
			return float(da["interest"]) > float(db["interest"])
		return int((da["player"] as PSPlayer).id) < int((db["player"] as PSPlayer).id)
	)
	# 関心の高い上位だけが MLB から声が掛かる (母集団相対の絞り込み)。
	var candidates: Array = eligible.slice(0, CHALLENGE_POOL_SIZE)

	var expected: float = 0.0
	var expected_posting: float = 0.0
	var posting_candidates: int = 0
	for candidate_row in candidates:
		var candidate_stat: Dictionary = candidate_row as Dictionary
		var stat_chance: float = challenge_chance(str(candidate_stat["route"]), float(candidate_stat["interest"]), frequency_mult)
		if str(candidate_stat["route"]) == ROUTE_POSTING:
			posting_candidates += 1
			expected_posting += stat_chance
		expected += stat_chance
	var stats: Dictionary = {
		"fee_total": 0,
		"candidates_count": candidates.size(),
		"candidates_posting_count": posting_candidates,
		"eligible_count": eligible.size(),
		"eligible_posting_count": eligible.filter(func(row: Variant) -> bool: return str((row as Dictionary)["route"]) == ROUTE_POSTING).size(),
		"expected_departures": expected,
		# 経路別の期待値。確率は経路の基礎確率に比例するので、ここからポスティング比率と
		# 総量の両方を満たす基礎確率を逆算できる (上限クランプに当たらない範囲で)。
		"expected_posting_departures": expected_posting,
	}
	if candidates.is_empty():
		return stats

	var slots: int = int(setting.get("max_departures", MAX_DEPARTURES_PER_YEAR))
	var fee_total: int = 0
	for candidate_row in candidates:
		if slots <= 0:
			break
		var candidate: Dictionary = candidate_row as Dictionary
		var player: PSPlayer = candidate["player"] as PSPlayer
		var route: String = str(candidate["route"])
		var value: int = int(candidate["value"])
		var interest: float = float(candidate["interest"])
		if Rng.roll_float() >= challenge_chance(route, interest, frequency_mult):
			continue
		var fee: int = posting_fee_for_interest(interest) if route == ROUTE_POSTING else 0
		var from_team: int = player.team_id
		if fee > 0:
			var team: PSTeam = _team_by_id(teams, from_team)
			if team != null:
				team.funds += fee
			else:
				fee = 0
		departed.append(_entry(player, from_team, value, {"route": route, "fee": fee}))
		_apply_departure(player, year, route, fee)
		fee_total += fee
		slots -= 1
	stats["fee_total"] = fee_total
	return stats


static func _apply_departure(player: PSPlayer, year: int, route: String, fee: int) -> void:
	PSCareerLog.log_overseas_depart(player, year, player.team_id, route, fee)
	player.source_data[PSPlayer.SOURCE_KEY_OVERSEAS_YEAR] = year
	player.source_data[SOURCE_KEY_OVERSEAS_TEAM] = player.team_id
	player.source_data[SOURCE_KEY_OVERSEAS_ROUTE] = route
	player.source_data[SOURCE_KEY_OVERSEAS_SALARY] = player.salary
	# 複数年契約の残りは移籍で消える (契約満了の誤検出を防ぐため 3 キーとも落とす)。
	player.source_data.erase("contract_end_year")
	player.source_data.erase("contract_total_years")
	player.source_data.erase("contract_signed_year")
	# retired は「NPB に居ない」の印。引退と区別するのは is_overseas() 側の役目。
	player.source_data["retired"] = true
	player.team_id = 0
	player.fatigue = 0
	player.injury_days = 0
	player.injury_type = ""
	player.injury_severity = 0


# --- 復帰 ---

static func _resolve_returns(players: Array, year: int, returned: Array, overseas_retired: Array) -> void:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or not player.is_overseas():
			continue
		if player.age >= RETURN_GIVEUP_AGE:
			overseas_retired.append(_entry(player, int(player.source_data.get(SOURCE_KEY_OVERSEAS_TEAM, 0)), OffseasonService.player_value_score(player), {}))
			_apply_overseas_retirement(player, year)
			continue
		if seasons_abroad(player, year) < RETURN_MIN_SEASONS:
			continue
		if Rng.roll_float() >= return_chance(player.age):
			continue
		var home_id: int = int(player.source_data.get(SOURCE_KEY_OVERSEAS_TEAM, 0))
		if home_id <= 0:
			continue
		# 古巣の支配下が埋まっていれば復帰は翌オフへ持ち越す (枠を溢れさせない)。
		if not TeamFinance.has_controlled_room(players, home_id):
			continue
		var salary: int = _return_salary(player)
		returned.append(_entry(player, home_id, OffseasonService.player_value_score(player), {"salary": salary}))
		_apply_return(player, home_id, year, salary)


static func _return_salary(player: PSPlayer) -> int:
	var base: int = int(player.source_data.get(SOURCE_KEY_OVERSEAS_SALARY, player.salary))
	return OffseasonService.round_salary_2sig(int(round(float(maxi(1, base)) * RETURN_SALARY_MULT)))


static func _apply_return(player: PSPlayer, team_id: int, year: int, salary: int) -> void:
	player.team_id = team_id
	player.salary = salary
	player.source_data["retired"] = false
	player.source_data.erase(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_TEAM)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_ROUTE)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_SALARY)
	player.source_data[SOURCE_KEY_OVERSEAS_RETURN_YEAR] = year
	player.registered_roster = "支配下"
	player.development_player = false
	player.fatigue = 0
	player.injury_days = 0
	player.injury_type = ""
	player.injury_severity = 0
	# 日数台帳は海外にいる間は増えないので、権利の有無は離脱時のまま。表示だけ追いつかせる
	# (次オフの accrue_fa_days_and_update_status が同じ式で上書きする)。
	if player.is_fa_eligible():
		player.contract_status = "FA可能"
	PSCareerLog.log_overseas_return(player, year, team_id, salary)


static func _apply_overseas_retirement(player: PSPlayer, year: int) -> void:
	var from_team: int = int(player.source_data.get(SOURCE_KEY_OVERSEAS_TEAM, 0))
	PSCareerLog.log_overseas_retired(player, year, from_team, player.age)
	player.source_data.erase(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_TEAM)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_ROUTE)
	player.source_data.erase(SOURCE_KEY_OVERSEAS_SALARY)
	player.source_data["retired"] = true
	player.source_data["retired_age"] = player.age
	player.team_id = 0


# --- 海外組の年次変動 ---

# 海外にいる全員の加齢と成長。通常経路 (advance_players_one_year / process_growth_decay) は
# retired を除外するので、ここが唯一の適用点になる。返り値は海外にいる人数。
static func _advance_overseas_players(players: Array) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or not player.is_overseas():
			continue
		player.age += 1
		player.years += 1
		OffseasonService.apply_overseas_growth(player, OVERSEAS_GROWTH_SCALE)
		count += 1
	return count


# --- 共通 ---

# 結果表の 1 行。引退判定 (OffseasonService.process_retirement) と同じ形にしてあるので、
# offseason_screen の汎用プレイヤー表がそのまま描ける。
static func _entry(player: PSPlayer, team_id: int, value: int, extra: Dictionary) -> Dictionary:
	var entry: Dictionary = {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"team_id": team_id,
		"position": player.position,
		"role": player.role,
		"overall": value,
		"years": player.years,
	}
	entry.merge(extra, true)
	return entry


static func _team_by_id(teams: Array, team_id: int) -> PSTeam:
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null
