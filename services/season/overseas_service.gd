extends RefCounted
class_name OverseasService

# メジャー挑戦 (海外移籍) の単一ソース。オフの「メジャー挑戦」ステップ 1 つで、海外への流出・
# 海外からの復帰・海外組の年次変動をまとめて解決する。
#
# ## 流出は 2 経路 (資格と補償が違うだけの同じ判定)
#   ポスティング — 入団 POSTING_MIN_YEARS 年目を終え、NPB でトップクラスの働き (先発/救援それぞれの順位が
#                  POSTING_MAX_RANK 位以内、救援は RELIEVER_POSTING_MAX_RANK 位以内。野手は下の打撃の前提) をした
#                  選手が、国内FA権の有無や時期に関係なく同じ条件で挑戦できる。成立すると譲渡金が元球団へ入る。
#   海外FA       — 一軍登録 145日 × OVERSEAS_FA_YEARS。投手は成績の条件が無い。補償は無い。
# **志願すれば必ず成立する** (自軍も CPU も球団は承認するものとする — ユーザー決定)。
# 野手は経路に依らず NPB の打撃がトップクラス (BATTER_BATTING_RANK_LIMIT 位以内) であることが前提。
# 誰に声が掛かるかは経路に依らず MLB の関心 (mlb_interest = 能力 × NPB での働き × 年齢 × 投手の上乗せ) で
# 決まる。実際に MLB へ移った日本人と同じく、NPB の野手/投手の上位 10 人が 7 割を占め、投手が 3 分の 2、
# 投手の 2 割前後が救援になる (下の「MLB の関心」)。
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
#   0. 海外での今季の成績 (PSMlbSeasonSimulator) — 今季を海外で過ごした全員。復帰より前に作るので、
#      戻る選手も今季の MLB 成績を持って帰ってくる。能力は今オフの成長の前のもの。
#   1. 復帰 / 海外での引退 — 0 で作った今季を含む MLB の成績で決まる (確率・年俸・MLB での引退)。
#      復帰者はこの時点で NPB 側へ戻るので、以後は通常の経路
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
# ポスティングの条件: 入団 POSTING_MIN_YEARS 年目を終え、NPB での働きの順位 (npb_performance、先発/救援
# それぞれ) が POSTING_MAX_RANK 位以内 (救援は RELIEVER_POSTING_MAX_RANK 位以内)。野手の順位の条件は
# BATTER_BATTING_RANK_LIMIT (経路に依らない前提) が担う。国内FA権の有無や時期は問わない
# (実際のポスティングは 5〜14 年目と幅があり、大谷・佐々木は 5 年目、山本・ダルビッシュ・田中は 7 年目を終えて、
# 岡本・今井は国内FA権を得た後に移籍した)。
# 実際の移籍組は移籍前の季に NPB の上位 10 位以内が 7 割、上位 20 位以内が 8 割。救援の移籍は抑え・セットアッパーの
# 上位に限られ、ほとんどが海外FA (平野・澤村・松井。ポスティングは牧田だけ) なので、救援の順位の条件は狭い。
# RANK を広げる / YEARS を下げるほど流出が増え、若い選手・中堅の主力も出ていく。
# NPB の成績が全く無いとき (順位 0、テストなど) は順位の条件を見ない。
const POSTING_MIN_YEARS: int = 5
const POSTING_MAX_RANK: int = 20
const RELIEVER_POSTING_MAX_RANK: int = 3
# 野手の前提: NPB の打撃 (wRAA を今季と前季で PERFORMANCE_SEASON_WEIGHTS の平均) の順位 (npb_performance の bat_rank) が
# BATTER_BATTING_RANK_LIMIT 位以内でなければ、経路 (ポスティング・海外FA) に関係なく MLB から声が掛からない。
# 実際の移籍組の野手は移籍前の季に全員 NPB の wRAA 上位 10 位以内 (2018〜2025 の 6 人)。この前提を満たした選手の中で
# 誰に声が掛かるかは、守備 (MLB で守る位置・サブポジション) まで含めた MLB の目で見た働き (mlb_view_war) の順位で決まる。
# 広げるほど野手の流出が増え、打撃が一段落ちる捕手・二遊間も出ていく。
const BATTER_BATTING_RANK_LIMIT: int = 10
# 志願の足切り (MLB の目で見た評価 mlb_view_value)。これ未満の選手には MLB から声が掛からない。
# 誰が行くかを決めているのは下の関心 (NPB での働きが主) で、足切りは「能力の低い選手が 1 年の好成績だけで
# 行く」のを止める下限。上げると能力の高い選手だけに絞られ、流出も減る。
const MIN_CHALLENGE_VALUE: int = 75
# MLB の関心の基準点 (この評価・プライム年齢・NPB の最上位で関心 1.0)。主力級の目安を
# ForeignPlayerService.CPU_FOREIGN_MULTI_YEAR_VALUE と揃えてある。
const INTEREST_REFERENCE_VALUE: int = 70
# これを超える年齢では挑戦しない (実際の移籍組は移籍前の季に 22〜34 歳、32 歳以上は 1 割強)。
const MAX_CHALLENGE_AGE: int = 34
# **MLB が見ているのはリーグの上澄みだけ**。資格・年齢・足切りを通った選手を MLB の関心
# (mlb_interest) の高い順に並べ、上位この人数だけを志願の母集団にする。
# 母集団相対にしてあるのは、能力スケールが年々動いても (成長/ドラフトの較正、世界再生成)
# 流出量が勝手に膨らまないようにするため (絶対閾値だけで絞ると資格者が数十人に膨れる)。
const CHALLENGE_POOL_SIZE: int = 20

# --- MLB の関心 (mlb_interest = 能力 × NPB での働き × 年齢 × 投手の上乗せ) ---
# 母集団の順位・志願確率・譲渡金はすべてこの 1 つの値から決まる。
# 実測 (2018〜2025 に MLB へ移った日本人 20 人の移籍前の季、FanGraphs): NPB の野手 (wRAA) / 投手
# (FIP 基準の失点抑止) の中の順位は 1〜5 位 40% / 6〜10 位 30% / 11〜20 位 10% / 51 位以下 20%
# (51 位以下は救援と、能力を買われた先発)。投手は 2010〜2025 の 34 人の 68%。
# 能力: MLB の目で見た評価 (mlb_view_value) が基準点 (INTEREST_REFERENCE_VALUE) を超えた 1 点ごとに関心が
# VALUE_INTEREST_PER_POINT ずつ増える (基準点ちょうど = 1.0)。
const VALUE_INTEREST_PER_POINT: float = 0.15
# NPB での働き: 今季と前季の WAR (野手は MLB の目で見た値、mlb_view_war) を
# PERFORMANCE_SEASON_WEIGHTS で平均し、野手 / 先発 / 救援それぞれの中で付けた
# 順位 (npb_performance) の関数。1 位で 1.0、PERFORMANCE_RANK_SCALE 位の少し下で半分になり、
# 下位は PERFORMANCE_FLOOR まで。EXPONENT を上げると上位 10 人とそれ以下の差が急になる。
# 今季の NPB のレコードが全く無いとき (テストなど) は働きを見ない (1.0)。
const PERFORMANCE_SEASON_WEIGHTS: Array[float] = [2.0, 1.0]
const PERFORMANCE_RANK_SCALE: float = 8.0
const PERFORMANCE_RANK_EXPONENT: float = 3.0
const PERFORMANCE_FLOOR: float = 0.02
# NPB で出場していない選手の順位 (performance_rank)。関心は PERFORMANCE_FLOOR 近くになる。
const PERFORMANCE_UNRANKED: int = 999
# 働きの順位を付ける群 (npb_performance)。投手は今季 (無ければ前季) の登板の半分以上が先発なら先発。
const GROUP_BATTER: String = "batter"
const GROUP_STARTER: String = "starter"
const GROUP_RELIEVER: String = "reliever"
# MLB の目で見た働き (mlb_view_war) で、MLB が日本人の守備を割り引く量 (162 試合あたりの得点、MLB で守る位置ごと)。
# 捕手・二遊間で使われる選手は、NPB での守備が良くても働きをこれだけ低く見積もられる。難しい位置ほど大きい
# (遊撃は守備位置補正 +7.5 と同じ、二塁は +2.5 の倍)。捕手は投手陣との意思疎通まで含めて最も信用されず
# (実際の日本人捕手の移籍は 2005 年オフの城島が最後)、守備位置補正 +12.5 を打ち消して両翼並み (−7.5) に見られる。
# 上げるとその位置の選手に声が掛かりにくくなるが、打撃の前提を満たす捕手は NPB の打撃の最上位級 (WAR 7〜9) なので、
# 捕手の 10 → 20 で捕手の流出は 25〜40% 減にとどまる (長期自動プレイ 12 季 × 2 本の資格者で見積もり)。
const MLB_DEFENSE_DOUBT_RUNS: Dictionary = {2: 20.0, 6: 7.5, 4: 5.0}
# 投手への上乗せ。MLB は NPB の投手をより多く獲る (上の実測で移籍組の 3 分の 2 が投手)。
# 野手は打撃の前提 (BATTER_BATTING_RANK_LIMIT) で母集団が絞られるので、上乗せ 2.0 で投手 7 割 / 野手 3 割になる。
# 救援は RELIEVER_INTEREST_MULT。救援の働きは先発より小さいので、同じ群で並べると救援の最上位でも投手全体の
# 30 位前後にしかならず声が掛からない。順位を救援の中で付けたうえで上乗せを別にし、実際の日本人投手の移籍の
# 2 割前後 (2017〜2025 の 16 人中 平野・牧田・澤村・松井の 4 人) が救援になるよう合わせてある。救援の上位は
# 評価も先発の上位と大差ない (80 前後) ので、野手より小さい上乗せ (0.8) で流出投手の 2 割になる
# (長期自動プレイ 12 季 × 2 本の資格者で見積もり)。上げるほど救援の割合が増える (1.0 で 25%)。
const PITCHER_INTEREST_MULT: float = 2.0
const RELIEVER_INTEREST_MULT: float = 0.8
# 年齢: MLB は長く使える若手を強く評価する (実例の移籍年齢は大谷 23 / 佐々木 23 / 山本 25 /
# 鈴木誠也 27 / 吉田正尚 29 / 今永 30)。プライム以下は上乗せ、超えると 1 歳ごとに目減りする。
# これが無いと、能力だけで勝るピーク期のベテラン (海外FA 組) が関心を独占し、若いうちに出ていく選手
# (大谷・佐々木・山本型) が作れない。1 歳若いごとに +0.15 (24 歳以下で上限 1.3)、30 歳で 0.64、33 歳で 0.28。
# 減衰を強くすると海外FA組 (大卒なら 30 歳前後で権利) がほぼ出ていかなくなる。
const MLB_PRIME_AGE: int = 27
const YOUTH_INTEREST_PER_YEAR: float = 0.15
const AGE_INTEREST_DECAY_PER_YEAR: float = 0.12
const MIN_AGE_INTEREST: float = 0.15
const MAX_AGE_INTEREST: float = 1.3

# --- 志願確率 = 経路の基礎確率 × mlb_interest (上限 MAX_CHALLENGE_CHANCE) ---
# ポスティングは条件を満たす限り入団 5 年目から海外FA権までの毎年が機会になるので 1 年あたりの確率を低く、
# 海外FA は 30 歳前後からの数年だけなので高くしてある (実際の移籍組はポスティングが 7 割前後で、
# 上位の選手でも海外FA まで待つ例がある)。評価 85・27 歳の選手の 1 年あたりの確率 (野手は打撃の前提を満たした場合):
# ポスティングは NPB 1 位で野手 0.28 / 投手 0.5 (上限)、10 位で 0.12 / 0.23、20 位で 0.02 / 0.05 (24 歳以下は 1.3 倍)。
# 海外FA (31 歳) は 1 位の野手 0.5 / 10 位で 0.28。流出の期待値は年 2.45 人 (野手 0.68 人)
# (2012〜2026 の実際は年 2.1 人、2018〜2026 は 2.6 人)。基礎確率に比例して増減する。
const POSTING_BASE_CHANCE: float = 0.085
const OVERSEAS_FA_BASE_CHANCE: float = 0.39
const MAX_CHALLENGE_CHANCE: float = 0.5
# リーグ全体の年間流出上限。**安全弁であって目標ではない** — ここに毎年張り付いていたら
# 確率側が高すぎる (同じ失敗が FA 宣言率で起きた → project_fa_market_v1_5)。
# 実 NPB のポスティング + 海外FA は年 0〜4 人 (2023〜2026 は 3 / 4 / 3 / 3 人)。
const MAX_DEPARTURES_PER_YEAR: int = 4

# --- 頻度 (オプション設定 AppState.overseas_challenge_frequency) ---
# 志願確率に掛ける倍率と、年間上限。"off" は**新規の流出だけ**を止める — 海外にいる選手の
# 加齢と復帰は続けるので、途中で切っても海外組は取り残されずに帰ってくる。
# 倍率は上限クランプ (MAX_CHALLENGE_CHANCE) の**後**に掛ける (challenge_chance) ので、上限に当たっていない
# 選手の確率はそのまま倍率倍になる (「多め」でも上位の選手は MAX_SCALED_CHALLENGE_CHANCE で頭打ち)。
# 年間上限も同じ比率で広げないと「多め」で上限に張り付く。
const FREQUENCY_OFF: String = "off"
const FREQUENCY_LOW: String = "low"
const FREQUENCY_STANDARD: String = "standard"
const FREQUENCY_HIGH: String = "high"
const FREQUENCY_ORDER: Array[String] = [FREQUENCY_OFF, FREQUENCY_LOW, FREQUENCY_STANDARD, FREQUENCY_HIGH]
const FREQUENCY_SETTINGS: Dictionary = {
	FREQUENCY_OFF: {"chance_mult": 0.0, "max_departures": 0},
	FREQUENCY_LOW: {"chance_mult": 0.5, "max_departures": 2},
	FREQUENCY_STANDARD: {"chance_mult": 1.0, "max_departures": MAX_DEPARTURES_PER_YEAR},
	FREQUENCY_HIGH: {"chance_mult": 2.0, "max_departures": 8},
}
# 倍率を掛けた後の上限 (1 人の志願確率が 1 に張り付かないように)。
const MAX_SCALED_CHALLENGE_CHANCE: float = 0.9

# --- 譲渡金 ---
# 元球団の funds へ加算する。FA の金銭補償と同じ「そのオフの補強予算だけが動く」性質で
# (ロード時に TeamFinance.apply_fixed_budget が固定額へ戻す)、予算設計を跨がない。
# 実際の譲渡金は球団予算を超える規模になるため、star 帯の外国人 1 人ぶんに収めてある。
# 実際の譲渡金は MLB での契約総額に比例し、契約は若くて良い選手ほど大きい — ので mlb_interest に
# 比例させる (関心 1.0 で POSTING_FEE_MIN。NPB の上位の選手・投手ほど高く、上位 5 人の投手はほぼ上限)。
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

# --- MLB の成績との連動 ---
# 直近の MLB 成績 (mlb_recent_war) = 今の滞在の直近の季の WAR を新しい順にこの重みで平均したもの。
const MLB_FORM_WEIGHTS: Array[float] = [3.0, 2.0, 1.0]
# 復帰確率の中立点。直近 WAR がこの値なら年齢だけで決まる確率のまま、1 WAR 下がるごとに
# RETURN_CHANCE_PER_WAR ぶん (倍率で) 上がり、上がれば下がる。中立点は渡米組の MLB 1 年目の
# WAR の中央値 (初期世界の評価 80 以上・33 歳以下を回して 1.0)。
# 活躍する選手ほど長く MLB に残り、不振の選手は早く帰ってくる。
# 初期世界の評価 80 以上・33 歳以下を回した実測で、滞在は中央値 4 季 (10〜90% で 2〜8 季)、
# 1 季で戻るのは 9%、復帰年齢の中央値 34 歳。RETURN_CHANCE_PER_WAR を上げると成績による差が開く。
const RETURN_NEUTRAL_WAR: float = 1.0
const RETURN_CHANCE_PER_WAR: float = 0.4
const RETURN_PERFORMANCE_MIN_MULT: float = 0.2
const RETURN_PERFORMANCE_MAX_MULT: float = 2.2
# 直近 WAR がこれ未満の不振の選手は、最低滞在 (RETURN_MIN_SEASONS) を待たずに
# STRUGGLING_MIN_SEASONS 季目から復帰の抽選に入る (実例でも 1〜2 年で戻る選手が多い)。
const STRUGGLING_WAR: float = 0.0
const STRUGGLING_MIN_SEASONS: int = 1
# MLB で大きな功績を残した選手は、MLB を去るときに古巣へ戻らず MLB で引退することがある。
# 確率は MLB 通算 WAR が START から FULL へ増えるにつれて 0 → 1 (上限 MAX)。通算 20 で 1/3、30 で 2/3。
# この年齢未満で MLB を去る選手は引退せずに戻る (まだ NPB で先がある)。
# 同じ実測で、渡米組の 4% がこの判定で、5% が年齢上限 (RETURN_GIVEUP_AGE) で MLB で現役を終える。
# MLB 通算 20 WAR 以上で MLB を去った選手に限ると 6 割強が MLB で引退する (残りは古巣へ戻る)。
const MLB_FAREWELL_MIN_AGE: int = 35
const MLB_FAREWELL_WAR_START: float = 10.0
const MLB_FAREWELL_WAR_FULL: float = 40.0
const MLB_FAREWELL_MAX_CHANCE: float = 0.95
# 復帰時の年俸 = max(MLB での査定額 × RETURN_SALARY_MULT, 離脱時の年俸 × RETURN_SALARY_FLOOR_MULT)。
# 査定額は今の滞在の直近の季を NPB の契約更改と同じ式 (OffseasonService._season_market_value) にかけ、
# MLB_FORM_WEIGHTS で平均したもの。倍率はメジャー帰りのプレミアムで、MLB の WAR が NPB より強い相手に
# 対して測った値であるぶんも含む。下限は「NPB での実績の評価は残る」ことの表現で、MLB で不振でも
# メジャー帰りとして一定の額で迎えられる。初期世界の評価 80 以上・33 歳以下を回した実測で、
# 復帰年俸は離脱時の中央値 0.94 倍・平均 1.24 倍 (下限に当たるのは不振組の約 1/4)。
# 倍率を上げると活躍組だけが上がり、下限を上げると不振組だけが上がる。
# MLB の成績が無い選手は査定額の代わりに離脱時の年俸を使う。
const RETURN_SALARY_MULT: float = 1.5
const RETURN_SALARY_FLOOR_MULT: float = 0.7

# 海外での引退の理由 (結果表の entry の "reason")。
const RETIRE_REASON_AGE: String = "age"
const RETIRE_REASON_FAREWELL: String = "farewell"

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

# 海外での年度成績 [{"y": 年, "b": 打撃成績, "p": 投手成績, "m": 指標}] (年の古い順、成績は 0 のキーを省いた
# PSBatterStats / PSPitcherStats.to_dict()、指標は PSMlbSeasonSimulator の metrics)。
# **RecordStore には入れない** — NPB のタイトル・ランキング・通算記録に混ざらないように、選手本人の
# source_data に持つ。復帰後も残す。
const SOURCE_KEY_MLB_SEASONS: String = "mlb_seasons"


# オフの「メジャー挑戦」ステップ本体。players / teams を直接書き換え、結果サマリを返す。
# frequency は FREQUENCY_* (オプション設定)。未知の値は標準として扱う。
# diagnostics = true なら較正用に、挑戦の経路がある全員の {評価 (MLB の目で見た値), 年齢, 経路, NPB での順位} を
# eligible_details に入れる (長期自動プレイのレポート用)。
static func process_overseas_challenge(players: Array, teams: Array, season: PSSeason, frequency: String = FREQUENCY_STANDARD, diagnostics: bool = false) -> Dictionary:
	var year: int = season.year if season != null else 0
	var returned: Array = []
	var overseas_retired: Array = []
	var departed: Array = []
	var setting: Dictionary = frequency_setting(frequency)
	if year <= 0:
		return _result(departed, returned, overseas_retired, 0, 0)

	var mlb_played: int = _record_mlb_seasons(players, year, season.season_number)
	_resolve_returns(players, year, returned, overseas_retired)
	var performance: Dictionary = npb_performance(year, season.season_number)
	var eligible_details: Array = _eligible_details(players, year, performance) if diagnostics else []
	var departure_stats: Dictionary = _resolve_departures(players, teams, year, departed, setting, performance)
	var abroad: int = _advance_overseas_players(players)

	var result: Dictionary = _result(departed, returned, overseas_retired, int(departure_stats.get("fee_total", 0)), abroad)
	departure_stats.erase("fee_total")
	result.merge(departure_stats, true)
	result["frequency"] = normalize_frequency(frequency)
	result["mlb_played_count"] = mlb_played
	if diagnostics:
		result["eligible_details"] = eligible_details
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
# performance_rank は npb_performance の順位 (0 = 成績を見ない)、reliever は救援の群で順位を付けた投手か。
static func challenge_route(player: PSPlayer, performance_rank: int = 0, reliever: bool = false) -> String:
	if player == null:
		return ""
	if player.fa_service_days() >= OVERSEAS_FA_YEARS * PSPlayer.FA_SERVICE_DAYS_PER_YEAR:
		return ROUTE_FA
	if is_posting_eligible(player, performance_rank, reliever):
		return ROUTE_POSTING
	return ""


# ポスティングの条件 (POSTING_MIN_YEARS 年目を終え、NPB の順位が POSTING_MAX_RANK 位以内。救援は
# RELIEVER_POSTING_MAX_RANK 位以内)。順位 0 は順位の条件を見ない (NPB の成績が無いときと、打撃の前提で見る野手)。
static func is_posting_eligible(player: PSPlayer, performance_rank: int, reliever: bool = false) -> bool:
	if player == null or player.years < POSTING_MIN_YEARS:
		return false
	var max_rank: int = RELIEVER_POSTING_MAX_RANK if reliever else POSTING_MAX_RANK
	return performance_rank == 0 or (performance_rank > 0 and performance_rank <= max_rank)


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
	return mlb_view_value(player) >= MIN_CHALLENGE_VALUE


# MLB の目で見た評価。MLB で別の位置 (PSMlbSeasonSimulator.mlb_position) を守る野手は、その位置で守る前提で
# 評価し直す (二遊間の守備の上手さは乗らず、打力とサブポジションの守備で決まる)。投手と、NPB の位置のまま
# MLB で守る野手は NPB の評価 (OffseasonService.player_value_score) のまま。捕手・二遊間の守備の割り引き
# (MLB_DEFENSE_DOUBT_RUNS) は働きの側 (mlb_view_war) で見る。
static func mlb_view_value(player: PSPlayer) -> int:
	if player == null:
		return 0
	var mlb_position: int = PSMlbSeasonSimulator.mlb_position(player)
	if player.is_pitcher() or mlb_position == player.position:
		return OffseasonService.player_value_score(player)
	return PSPlayerValueEvaluator.overall_score_at_position(PSPlayerSeasonRecord.from_player(player, 0, 0), mlb_position)


# 年齢による関心の倍率。プライム以下は若いほど上乗せ、超えると 1 歳ごとに目減りする。
static func age_interest(age: int) -> float:
	var years_from_prime: int = age - MLB_PRIME_AGE
	if years_from_prime <= 0:
		return minf(MAX_AGE_INTEREST, 1.0 - float(years_from_prime) * YOUTH_INTEREST_PER_YEAR)
	return maxf(MIN_AGE_INTEREST, 1.0 - float(years_from_prime) * AGE_INTEREST_DECAY_PER_YEAR)


# MLB の関心 = 能力 × NPB での働き × 年齢 × 投手の上乗せ。基準点ちょうどのプライム年齢の野手で、
# NPB の最上位 (performance_rank 1) なら 1.0。performance_rank は npb_performance の順位 (救援は救援の中の順位) で、
# 0 は「NPB の成績を見ない」(レコードが全く無いとき)。
static func mlb_interest(value: int, age: int, performance_rank: int = 0, pitcher: bool = false, reliever: bool = false) -> float:
	var ability: float = 1.0 + float(maxi(0, value - INTEREST_REFERENCE_VALUE)) * VALUE_INTEREST_PER_POINT
	var interest: float = ability * age_interest(age) * performance_interest(performance_rank)
	if not pitcher:
		return interest
	return interest * (RELIEVER_INTEREST_MULT if reliever else PITCHER_INTEREST_MULT)


# NPB での働きの倍率 (1 位で 1.0、下位は PERFORMANCE_FLOOR まで)。rank 0 は 1.0 (成績を見ない)。
static func performance_interest(rank: int) -> float:
	if rank <= 0:
		return 1.0
	var tail: float = pow(float(rank - 1) / PERFORMANCE_RANK_SCALE, PERFORMANCE_RANK_EXPONENT)
	return PERFORMANCE_FLOOR + (1.0 - PERFORMANCE_FLOOR) / (1.0 + tail)


static func posting_fee_for_interest(interest: float) -> int:
	var raw: int = POSTING_FEE_MIN + int(round(maxf(0.0, interest - 1.0) * float(POSTING_FEE_PER_INTEREST)))
	return clampi(OffseasonService.round_salary_2sig(raw), POSTING_FEE_MIN, POSTING_FEE_MAX)


# 志願確率 (= 成立確率。球団は必ず承認する)。
# frequency_mult (オプションの頻度) はクランプ後に掛けるので、期待流出がそのまま倍率倍になる。
static func challenge_chance(route: String, interest: float, frequency_mult: float = 1.0) -> float:
	var base: float = POSTING_BASE_CHANCE if route == ROUTE_POSTING else OVERSEAS_FA_BASE_CHANCE
	var chance: float = clampf(base * interest, 0.0, MAX_CHALLENGE_CHANCE)
	return clampf(chance * frequency_mult, 0.0, MAX_SCALED_CHALLENGE_CHANCE)


# MLB を去る (復帰の抽選が当たる) 確率。年齢で決まる確率に直近の MLB 成績の倍率を掛ける。
# recent_war の既定値は中立点 (= 年齢だけ)。
static func return_chance(age: int, recent_war: float = RETURN_NEUTRAL_WAR) -> float:
	var ramp: float = float(maxi(0, age - RETURN_AGE_RAMP_START)) * RETURN_CHANCE_PER_AGE
	var by_age: float = minf(RETURN_BASE_CHANCE + ramp, RETURN_MAX_CHANCE)
	var performance: float = clampf(
		1.0 + (RETURN_NEUTRAL_WAR - recent_war) * RETURN_CHANCE_PER_WAR,
		RETURN_PERFORMANCE_MIN_MULT, RETURN_PERFORMANCE_MAX_MULT
	)
	return clampf(by_age * performance, 0.0, RETURN_MAX_CHANCE)


# 復帰の抽選に入るまでの滞在シーズン数。不振の選手は最低滞在を待たない。
static func return_min_seasons(recent_war: float) -> int:
	return STRUGGLING_MIN_SEASONS if recent_war < STRUGGLING_WAR else RETURN_MIN_SEASONS


# MLB を去るときに古巣へ戻らず MLB で引退する確率 (MLB 通算 WAR と年齢)。
static func mlb_farewell_chance(age: int, career_war: float) -> float:
	if age < MLB_FAREWELL_MIN_AGE:
		return 0.0
	var progress: float = (career_war - MLB_FAREWELL_WAR_START) / (MLB_FAREWELL_WAR_FULL - MLB_FAREWELL_WAR_START)
	return clampf(progress, 0.0, MLB_FAREWELL_MAX_CHANCE)


# --- NPB での成績 ---

# NPB での今季の働き。今季と前季の MLB の目で見た WAR (mlb_view_war) を PERFORMANCE_SEASON_WEIGHTS で
# 平均した値 (前季のレコードが無ければ今季だけ) で、野手 / 先発 / 救援 (GROUP_*) それぞれの中の順位 (1 始まり) を付ける。
# 投手の群は今季 (無ければ前季) の登板の内訳で決める。野手は同じ重みで平均した打撃 (wRAA) の順位 bat_rank も付ける
# (BATTER_BATTING_RANK_LIMIT の前提に使う)。
# {player_id: {"war": float, "rank": int, "pitcher": bool, "group": String, (野手のみ) "bat_runs": float, "bat_rank": int}}。
# 今季のレコードが無ければ空。
static func npb_performance(year: int, season_number: int) -> Dictionary:
	var totals: Dictionary = {}
	for i in range(PERFORMANCE_SEASON_WEIGHTS.size()):
		var weight: float = PERFORMANCE_SEASON_WEIGHTS[i]
		for row_value in PSWarCalculator.season_war_table(year - i, season_number - i):
			var row: Dictionary = row_value as Dictionary
			var player_id: int = int(row.get("player_id", 0))
			if player_id <= 0:
				continue
			var total: Dictionary = totals.get(player_id, {"sum": 0.0, "bat_sum": 0.0, "weight": 0.0, "group": _war_row_group(row)}) as Dictionary
			total["sum"] = float(total["sum"]) + mlb_view_war(row, GameDb.get_player(player_id)) * weight
			total["bat_sum"] = float(total["bat_sum"]) + float(row.get("wraa", 0.0)) * weight
			total["weight"] = float(total["weight"]) + weight
			totals[player_id] = total
		if i == 0 and totals.is_empty():
			return {}
	var groups: Dictionary = {GROUP_BATTER: [], GROUP_STARTER: [], GROUP_RELIEVER: []}
	for player_id in totals.keys():
		var total: Dictionary = totals[player_id] as Dictionary
		(groups[str(total["group"])] as Array).append({
			"id": player_id,
			"war": float(total["sum"]) / float(total["weight"]),
			"bat_runs": float(total["bat_sum"]) / float(total["weight"]),
		})
	var performance: Dictionary = {}
	for group in groups.keys():
		var rows: Array = groups[group] as Array
		rows.sort_custom(func(a: Variant, b: Variant) -> bool:
			return float((a as Dictionary)["war"]) > float((b as Dictionary)["war"])
		)
		for i in range(rows.size()):
			var row: Dictionary = rows[i] as Dictionary
			performance[int(row["id"])] = {"war": float(row["war"]), "rank": i + 1, "pitcher": group != GROUP_BATTER, "group": group}
	var batters: Array = (groups[GROUP_BATTER] as Array).duplicate()
	batters.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float((a as Dictionary)["bat_runs"]) > float((b as Dictionary)["bat_runs"])
	)
	for i in range(batters.size()):
		var batter: Dictionary = batters[i] as Dictionary
		var entry: Dictionary = performance[int(batter["id"])] as Dictionary
		entry["bat_runs"] = float(batter["bat_runs"])
		entry["bat_rank"] = i + 1
	return performance


static func _war_row_group(war_row: Dictionary) -> String:
	if str(war_row.get("role", "")) != "pitcher":
		return GROUP_BATTER
	return GROUP_STARTER if float(war_row.get("gs_share", 0.0)) >= 0.5 else GROUP_RELIEVER


# MLB の目で見た 1 季の働き (WAR)。野手は MLB で守る位置 (PSMlbSeasonSimulator.mlb_position) で数え直す:
# - NPB の位置と違えば、NPB での守備位置補正と守備得点を外し、MLB で守る位置の守備位置補正に置き換える
#   (守備イニングの割合は NPB の守備位置補正から逆算する)。二遊間から一塁・両翼へ移る選手ほど失う補正が大きい。
# - MLB で守る位置が捕手・二遊間なら、MLB_DEFENSE_DOUBT_RUNS を同じ割合で引く。
# 投手と、それ以外の位置のまま MLB で守る野手は WAR のまま。
static func mlb_view_war(war_row: Dictionary, player: PSPlayer) -> float:
	var war: float = float(war_row.get("war", 0.0))
	if player == null or str(war_row.get("role", "")) == "pitcher":
		return war
	var mlb_position: int = PSMlbSeasonSimulator.mlb_position(player)
	var doubt: float = float(MLB_DEFENSE_DOUBT_RUNS.get(mlb_position, 0.0))
	var npb_runs: float = float(PSMlbSeasonSimulator.POSITIONAL_RUNS.get(player.position, 0.0))
	var rpw: float = float(war_row.get("rpw", 0.0))
	if (mlb_position == player.position and doubt == 0.0) or npb_runs == 0.0 or rpw <= 0.0:
		return war
	var npb_positional: float = float(war_row.get("pos_adj", 0.0))
	var defensive_share: float = clampf(npb_positional / npb_runs, 0.0, 1.0)
	var lost_runs: float = doubt * defensive_share
	if mlb_position != player.position:
		var mlb_positional: float = float(PSMlbSeasonSimulator.POSITIONAL_RUNS.get(mlb_position, 0.0)) * defensive_share
		lost_runs += npb_positional + float(war_row.get("fielding_runs", 0.0)) - mlb_positional
	return war - lost_runs / rpw


# 関心に使う順位。npb_performance が空 (今季の NPB のレコードが全く無い) なら 0 = 成績を見ない。
# 今季も前季も NPB で出場していない選手は最下位扱い。
static func performance_rank(performance: Dictionary, player_id: int) -> int:
	if performance.is_empty():
		return 0
	if not performance.has(player_id):
		return PERFORMANCE_UNRANKED
	return int((performance[player_id] as Dictionary).get("rank", PERFORMANCE_UNRANKED))


# 順位を付けた群 (GROUP_*)。NPB で出場していない (npb_performance に無い) 投手は役割で決める。
static func performance_group(performance: Dictionary, player: PSPlayer) -> String:
	if player == null:
		return GROUP_BATTER
	if performance.has(player.id):
		return str((performance[player.id] as Dictionary).get("group", GROUP_BATTER))
	if not player.is_pitcher():
		return GROUP_BATTER
	return GROUP_RELIEVER if player.role == "reliever" else GROUP_STARTER


# 野手の前提 (打撃の順位が BATTER_BATTING_RANK_LIMIT 位以内)。投手と、npb_performance が空 (成績を見ない) のときは
# 満たす扱い。NPB で打席に立っていない野手は満たさない。
static func meets_batting_bar(performance: Dictionary, player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.is_pitcher() or performance.is_empty():
		return true
	var bat_rank: int = int((performance.get(player.id, {}) as Dictionary).get("bat_rank", 0))
	return bat_rank > 0 and bat_rank <= BATTER_BATTING_RANK_LIMIT


# 較正用: 挑戦できるかもしれない全員 (年齢上限の少し上まで、評価の足切り前・野手の打撃の前提の前) の {評価, 年齢,
# 入団年数, 海外FA権があれば route = "fa" (無ければ ""), NPB での順位, 野手の打撃の順位 bat_rank}。ポスティングの条件
# (POSTING_* / BATTER_BATTING_RANK_LIMIT) をオフラインで振れるよう、海外FA権が無くても NPB の順位か打撃の順位が
# DIAGNOSTIC_RANK_LIMIT 位以内・入団 3 年目以降なら入れる。
const DIAGNOSTIC_RANK_LIMIT: int = 30

static func _eligible_details(players: Array, year: int, performance: Dictionary) -> Array:
	var details: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired() or player.development_player or player.foreign_player:
			continue
		if player.team_id <= 0 or PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		if player.is_fa_declared(year) or player.is_multi_year_locked_offseason(year) or player.age > MAX_CHALLENGE_AGE + 2:
			continue
		var route: String = ROUTE_FA if player.fa_service_days() >= OVERSEAS_FA_YEARS * PSPlayer.FA_SERVICE_DAYS_PER_YEAR else ""
		var perf: Dictionary = performance.get(player.id, {}) as Dictionary
		var rank: int = int(perf.get("rank", 0))
		var bat_rank: int = int(perf.get("bat_rank", 0))
		var ranked: bool = (rank > 0 and rank <= DIAGNOSTIC_RANK_LIMIT) or (bat_rank > 0 and bat_rank <= DIAGNOSTIC_RANK_LIMIT)
		if route.is_empty() and (not ranked or player.years < 3):
			continue
		details.append({
			"value": mlb_view_value(player), "age": player.age, "years": player.years, "route": route,
			"pitcher": player.is_pitcher(), "role": player.role, "position": player.position,
			"mlb_position": PSMlbSeasonSimulator.mlb_position(player) if not player.is_pitcher() else 1,
			"group": performance_group(performance, player),
			"rank": rank, "bat_rank": bat_rank, "war": snappedf(float(perf.get("war", 0.0)), 0.01),
		})
	return details


# --- 流出 ---

# 関心の高い順に志願を抽選し、成立したぶんだけ上限を消費する。performance は npb_performance。
# 返り値は {fee_total, candidates_count, expected_departures} (後ろ2つは較正用の診断)。
static func _resolve_departures(players: Array, teams: Array, year: int, departed: Array, setting: Dictionary, performance: Dictionary) -> Dictionary:
	var frequency_mult: float = float(setting.get("chance_mult", 1.0))
	var eligible: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not is_challenge_candidate(player, year):
			continue
		if not meets_batting_bar(performance, player):
			continue
		var rank: int = performance_rank(performance, player.id)
		var group: String = performance_group(performance, player)
		var reliever: bool = group == GROUP_RELIEVER
		# 野手のポスティングの順位の条件は打撃の前提 (meets_batting_bar) が担うので、経路には順位を渡さない。
		var route: String = challenge_route(player, 0 if group == GROUP_BATTER else rank, reliever)
		if route.is_empty():
			continue
		var value: int = OffseasonService.player_value_score(player)
		var interest: float = mlb_interest(mlb_view_value(player), player.age, rank, player.is_pitcher(), reliever)
		eligible.append({"player": player, "route": route, "value": value, "interest": interest})
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
			_retire_abroad(player, year, RETIRE_REASON_AGE, overseas_retired)
			continue
		var recent_war: float = mlb_recent_war(player)
		if seasons_abroad(player, year) < return_min_seasons(recent_war):
			continue
		if Rng.roll_float() >= return_chance(player.age, recent_war):
			continue
		# MLB を去る。大きな功績を残したベテランは古巣へ戻らず MLB で引退することがある。
		var farewell: float = mlb_farewell_chance(player.age, mlb_career_war(player))
		if farewell > 0.0 and Rng.roll_float() < farewell:
			_retire_abroad(player, year, RETIRE_REASON_FAREWELL, overseas_retired)
			continue
		var home_id: int = int(player.source_data.get(SOURCE_KEY_OVERSEAS_TEAM, 0))
		if home_id <= 0:
			continue
		# 古巣の支配下が埋まっていれば復帰は翌オフへ持ち越す (枠を溢れさせない)。
		if not TeamFinance.has_controlled_room(players, home_id):
			continue
		var salary: int = return_salary(player)
		returned.append(_entry(player, home_id, OffseasonService.player_value_score(player), {
			"salary": salary,
			"departure_salary": int(player.source_data.get(SOURCE_KEY_OVERSEAS_SALARY, 0)),
			"seasons_abroad": seasons_abroad(player, year),
			"mlb_recent_war": recent_war,
		}))
		_apply_return(player, home_id, year, salary)


static func _retire_abroad(player: PSPlayer, year: int, reason: String, overseas_retired: Array) -> void:
	var extra: Dictionary = {"reason": reason, "seasons_abroad": seasons_abroad(player, year), "mlb_career_war": mlb_career_war(player)}
	overseas_retired.append(_entry(player, int(player.source_data.get(SOURCE_KEY_OVERSEAS_TEAM, 0)), OffseasonService.player_value_score(player), extra))
	_apply_overseas_retirement(player, year)


# 復帰時の年俸 (RETURN_SALARY_MULT の説明を参照)。海外にいる間 (離脱時の年俸が残っている間) に呼ぶ。
static func return_salary(player: PSPlayer) -> int:
	var departure: int = maxi(1, int(player.source_data.get(SOURCE_KEY_OVERSEAS_SALARY, player.salary)))
	var appraisal: int = mlb_market_value(player)
	if appraisal < 0:
		appraisal = departure
	var salary: float = maxf(float(appraisal) * RETURN_SALARY_MULT, float(departure) * RETURN_SALARY_FLOOR_MULT)
	var clamped: int = clampi(int(round(salary)), OffseasonService.SALARY_MIN, OffseasonService.SALARY_MAX)
	return clampi(OffseasonService.round_salary_2sig(clamped), OffseasonService.SALARY_MIN, OffseasonService.SALARY_MAX)


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


# --- 海外での成績 ---

# 今季を海外で過ごした選手 (今オフより前に出た全員) の MLB 成績を作って残す。復帰・海外での引退の判定より
# 前に走らせるので、今オフ戻る選手も今季の MLB 成績を持って帰ってくる。今オフ出ていく選手は今季を
# NPB で過ごしたので対象外。MLB のリーグ平均は今季の NPB 一軍の能力平均から作る。返り値は成績を作った人数。
static func _record_mlb_seasons(players: Array, year: int, season_number: int) -> int:
	var abroad: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or not player.is_overseas():
			continue
		if int(player.source_data.get(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR, year)) < year:
			abroad.append(player)
	if abroad.is_empty():
		return 0
	var league: Dictionary = PSMlbSeasonSimulator.build_league(RecordStore.get_player_records_for_season(year, season_number))
	var seasons: Dictionary = PSMlbSeasonSimulator.simulate_season(abroad, year, league)
	for player_value in abroad:
		var player: PSPlayer = player_value as PSPlayer
		var season_result: Dictionary = seasons.get(player.id, {}) as Dictionary
		if not season_result.is_empty():
			append_mlb_season(
				player, year, season_result.get("batting") as PSBatterStats, season_result.get("pitching") as PSPitcherStats,
				season_result.get("metrics", {}) as Dictionary
			)
	return abroad.size()


# 1 季ぶんの MLB 成績を選手に残す。同じ年が既にあれば差し替える。
static func append_mlb_season(player: PSPlayer, year: int, batting: PSBatterStats, pitching: PSPitcherStats, metrics: Dictionary = {}) -> void:
	var entry: Dictionary = {"y": year}
	if batting != null:
		entry["b"] = _nonzero_stats(batting.to_dict())
	if pitching != null:
		entry["p"] = _nonzero_stats(pitching.to_dict())
	if not metrics.is_empty():
		entry["m"] = metrics.duplicate()
	var kept: Array = []
	for season_value in player.source_data.get(SOURCE_KEY_MLB_SEASONS, []) as Array:
		if int((season_value as Dictionary).get("y", 0)) != year:
			kept.append(season_value)
	kept.append(entry)
	kept.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int((a as Dictionary).get("y", 0)) < int((b as Dictionary).get("y", 0))
	)
	player.source_data[SOURCE_KEY_MLB_SEASONS] = kept


# 選手の MLB 成績 (年の古い順)。
# [{"year": int, "batting": PSBatterStats, "pitching": PSPitcherStats, "metrics": Dictionary}]。
# metrics は野手 {woba, wrc_plus, bsr, fielding, war, pos}、投手 {fip, war} (PSMlbSeasonSimulator)。
static func mlb_seasons(player: PSPlayer) -> Array:
	var seasons: Array = []
	if player == null:
		return seasons
	for season_value in player.source_data.get(SOURCE_KEY_MLB_SEASONS, []) as Array:
		var season: Dictionary = season_value as Dictionary
		seasons.append({
			"year": int(season.get("y", 0)),
			"batting": PSBatterStats.from_dict(season.get("b", {}) as Dictionary),
			"pitching": PSPitcherStats.from_dict(season.get("p", {}) as Dictionary),
			"metrics": (season.get("m", {}) as Dictionary).duplicate(),
		})
	return seasons


# 直近の MLB 成績 = 今の滞在の直近の季の WAR を MLB_FORM_WEIGHTS で平均したもの。
# WAR の付いた季が無ければ中立点 (RETURN_NEUTRAL_WAR)。
static func mlb_recent_war(player: PSPlayer) -> float:
	var total: float = 0.0
	var weight_sum: float = 0.0
	var index: int = 0
	for season_value in _recent_stint_seasons(player):
		var metrics: Dictionary = (season_value as Dictionary).get("m", {}) as Dictionary
		if not metrics.has("war"):
			continue
		var weight: float = MLB_FORM_WEIGHTS[index]
		total += float(metrics["war"]) * weight
		weight_sum += weight
		index += 1
	return total / weight_sum if weight_sum > 0.0 else RETURN_NEUTRAL_WAR


# MLB 通算 WAR (過去の滞在も含む全季)。
static func mlb_career_war(player: PSPlayer) -> float:
	var total: float = 0.0
	if player == null:
		return total
	for season_value in player.source_data.get(SOURCE_KEY_MLB_SEASONS, []) as Array:
		total += float(((season_value as Dictionary).get("m", {}) as Dictionary).get("war", 0.0))
	return total


# MLB の成績を NPB の年俸査定にかけた額 (万円)。今の滞在の直近の季を MLB_FORM_WEIGHTS で平均する。
# MLB の成績が無ければ -1。
static func mlb_market_value(player: PSPlayer) -> int:
	var total: float = 0.0
	var weight_sum: float = 0.0
	var index: int = 0
	for season_value in _recent_stint_seasons(player):
		var season: Dictionary = season_value as Dictionary
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, int(season.get("y", 0)), 0)
		record.batter_stats = PSBatterStats.from_dict(season.get("b", {}) as Dictionary)
		record.pitcher_stats = PSPitcherStats.from_dict(season.get("p", {}) as Dictionary)
		var war: float = float((season.get("m", {}) as Dictionary).get("war", 0.0))
		var weight: float = MLB_FORM_WEIGHTS[index]
		total += float(OffseasonService._season_market_value(record, war, false)) * weight
		weight_sum += weight
		index += 1
	return int(round(total / weight_sum)) if weight_sum > 0.0 else -1


# 今の滞在 (最後に海外へ出た年より後) の MLB の季を新しい順に、最大 MLB_FORM_WEIGHTS の数だけ。
static func _recent_stint_seasons(player: PSPlayer) -> Array:
	var recent: Array = []
	if player == null:
		return recent
	var departed_year: int = int(player.source_data.get(PSPlayer.SOURCE_KEY_OVERSEAS_YEAR, 0))
	var seasons: Array = player.source_data.get(SOURCE_KEY_MLB_SEASONS, []) as Array
	for i in range(seasons.size() - 1, -1, -1):
		var season: Dictionary = seasons[i] as Dictionary
		if int(season.get("y", 0)) <= departed_year:
			break
		recent.append(season)
		if recent.size() >= MLB_FORM_WEIGHTS.size():
			break
	return recent


static func _nonzero_stats(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in source.keys():
		if int(source[key]) != 0:
			out[key] = source[key]
	return out


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
