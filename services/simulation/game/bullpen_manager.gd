extends RefCounted
class_name PSBullpenManager

# 試合中の投手起用と登板記録を管理する。
# setup は GameLoop が持つ試合中状態で、現在投手、使用済み投手、pitcher_usage、リリーフ役割表を含む。
# ここで登板数・疲労・怪我判定まで更新し、試合後集計が同じ状態を参照できるようにする。

# 役割別の登板可能イニング (ユーザー指定)。セットは7回以降、クローザーは9回以降に限定する。
const SETUP_EARLIEST_INNING: int = 7
const CLOSER_EARLIEST_INNING: int = 9
# 4点差リードは「前日(直前のチーム試合)に登板していなければ」クローザー、連投ならミドルへ回す (ユーザー指定)。
const CLOSER_FOUR_RUN_MARGIN: int = 4
# 5点差以上はどの回でもセット/クローザーを温存し、ミドルリリーフに任せる (ユーザー指定)。
const BLOWOUT_LEAD_MARGIN: int = 5
# 5回以前の先発降板は長い穴埋めを優先し、6回以降は通常の中継ぎリレーへ渡す。
const LONG_RELIEF_PREFERRED_BEFORE_INNING: int = 6
# 昇格した救援は、クローザー/セットの役割優先を崩さない範囲で最初の登板機会を得やすくする。
# 上げたまま一度も使わず再抹消するロスター運用を防ぐための場面スコア加点。
const CALLUP_AUDITION_BONUS: float = 75.0

# 試合開始時の先発投手とスタメン野手の出場記録を付ける。
# DH は守備負荷が軽いので疲労/怪我 exposure を下げ、守備についた野手とは分けて扱う。
static func mark_games_started(setup: Dictionary) -> void:
	var pitcher: PSPlayerSeasonRecord = setup["pitcher"] as PSPlayerSeasonRecord
	pitcher.pitcher_stats.games += 1
	pitcher.pitcher_stats.starts += 1
	mark_pitcher_used(setup, pitcher)
	pitcher_usage_for(setup, pitcher, PSPitcherUsageModel.ROLE_STARTER)
	var fielder_ids: Dictionary = _fielder_ids_for_setup(setup)
	var batters: Array = setup["batters"] as Array
	for batter_row in batters:
		var batter: PSPlayerSeasonRecord = batter_row as PSPlayerSeasonRecord
		if batter == null or batter.is_pitcher():
			continue
		batter.batter_stats.games += 1
		var is_fielder: bool = fielder_ids.has(batter.player_id)
		var fatigue_gain: int = GameSimulator.FIELDER_START_FATIGUE_GAIN if is_fielder else GameSimulator.DH_START_FATIGUE_GAIN
		var exposure: float = 1.0 if is_fielder else 0.65
		batter.fatigue = int(min(GameSimulator.FATIGUE_MAX, batter.fatigue + fatigue_gain))
		PSScoringHelpers.maybe_injure_for_setup(setup, batter, false, exposure)


# イニング間の継投。usage と inning から続投可否を判定し、必要なら文脈に合うリリーフへ差し替える。
# 先発が早い回で降りる場合は prefer_long を立て、ロングリリーフを強く優先する。
static func substitute_reliever(setup: Dictionary, inning: int, game_result: Dictionary = {}) -> void:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if current == null:
		return
	var already_relieved: bool = bool(setup.get("starter_relieved", false))
	var usage: Dictionary = pitcher_usage_for(setup, current, PSPitcherUsageModel.ROLE_STARTER if current == starter else "")
	var should_pull: bool = PSPitcherUsageModel.should_pull_for_next_half(
		current,
		usage,
		inning,
		int(setup.get("game_runs_allowed", 0))
	)
	if already_relieved and starter != null and current == starter:
		should_pull = true

	if not should_pull:
		return

	var prefer_long: bool = current == starter and should_prefer_long_relief_for_starter_exit(inning)
	var reliever: PSPlayerSeasonRecord = pick_reliever_for_context(setup, inning, game_result, prefer_long)
	if reliever == null:
		return
	if setup.get("pitcher", null) == reliever:
		return
	if not already_relieved and starter != null and current == starter:
		mark_starter_relieved(setup)
	setup["pitcher"] = reliever
	var role: String = _outing_role_for_reliever(setup, reliever, prefer_long)
	mark_reliever_appeared(setup, reliever, int(setup.get("team_games_played_before", 0)), role)


# 打席終了直後のイニング途中継投。現在イニングの失点と塁状況を加味して、
# 危険域なら次打者前に投手を替える。替えた場合だけ true。
static func substitute_reliever_mid_inning(
	setup: Dictionary,
	inning: int,
	outs: int,
	bases: Array,
	current_half_runs: int,
	game_result: Dictionary = {}
) -> bool:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if current == null:
		return false
	var usage: Dictionary = pitcher_usage_for(setup, current, PSPitcherUsageModel.ROLE_STARTER if current == starter else "")
	var runs_allowed: int = int(setup.get("game_runs_allowed", 0)) + current_half_runs
	var defense_lead: int = score_margin_for_setup(setup, game_result) - current_half_runs
	if not PSPitcherUsageModel.should_pull_after_plate_appearance(current, usage, inning, outs, bases, runs_allowed, defense_lead):
		return false

	var prefer_long: bool = current == starter and should_prefer_long_relief_for_starter_exit(inning)
	var reliever: PSPlayerSeasonRecord = pick_reliever_for_context(setup, inning, game_result, prefer_long)
	if reliever == null or reliever == current:
		return false
	if starter != null and current == starter:
		mark_starter_relieved(setup, int(setup.get("game_outs", 0)) + outs, runs_allowed)
	setup["pitcher"] = reliever
	var role: String = _outing_role_for_reliever(setup, reliever, prefer_long)
	mark_reliever_appeared(setup, reliever, int(setup.get("team_games_played_before", 0)), role)
	return true


# 救援登板時の公式出場記録と連投カウンタを更新する。
# last_pitched_team_game はチーム試合数ベースなので、雨天/休養日を挟んでも連投判定がぶれない。
static func mark_reliever_appeared(setup: Dictionary, reliever: PSPlayerSeasonRecord, team_games_played_before: int, role: String) -> void:
	reliever.pitcher_stats.games += 1
	reliever.pitcher_stats.relief_appearances += 1

	var farm: bool = _is_farm_setup(setup)
	var consecutive_count: int = 0
	var last_game: int = reliever.farm_last_pitched_team_game if farm else reliever.last_pitched_team_game
	if last_game == team_games_played_before and team_games_played_before > 0:
		consecutive_count = reliever.farm_consecutive_appearances if farm else reliever.consecutive_appearances
	else:
		if farm:
			reliever.farm_consecutive_appearances = 0
		else:
			reliever.consecutive_appearances = 0
	if farm:
		reliever.farm_consecutive_appearances = consecutive_count + 1
		reliever.farm_last_pitched_team_game = team_games_played_before + 1
	else:
		reliever.consecutive_appearances = consecutive_count + 1
		reliever.last_pitched_team_game = team_games_played_before + 1
	mark_pitcher_used(setup, reliever)
	var usage: Dictionary = pitcher_usage_for(setup, reliever, role)
	usage["consecutive_count"] = consecutive_count


# 使用済み投手と登板不可投手を除外し、残り候補を文脈スコアで並べて最上位を返す。
# まず疲労制限を守り、候補ゼロのときだけ allow_tired=true で非常時登板を許す。
# 役割別のハードな登板可否 (セット=7回以降/クローザー=9回以降、ともにビハインド除外、
# 同点延長のクローザーはビジターなら12回まで温存) を絞り込んでから選ぶ。
static func pick_reliever_for_context(setup: Dictionary, inning: int, game_result: Dictionary = {}, prefer_long: bool = false) -> PSPlayerSeasonRecord:
	var relievers: Array = setup.get("relievers", []) as Array
	if relievers.is_empty():
		return null
	var used_ids: Dictionary = setup.get("used_pitcher_ids", {}) as Dictionary
	var close_game: bool = is_close_game_for_setup(setup, game_result)
	var score_margin: int = score_margin_for_setup(setup, game_result)
	var game_day: int = int(setup.get("game_day", 0))
	var team_games_played_before: int = int(setup.get("team_games_played_before", 0))
	var is_visitor: bool = _is_visitor_setup(setup, game_result)
	var farm: bool = _is_farm_setup(setup)
	var candidates: Array = []
	for allow_tired in [false, true]:
		candidates.clear()
		for reliever_row in relievers:
			var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
			if reliever == null:
				continue
			if used_ids.has(reliever.player_id):
				continue
			if not PSPitcherUsageModel.is_reliever_available(reliever, bool(allow_tired), game_day, team_games_played_before, farm):
				if bool(allow_tired) or not _can_relax_availability_for_late_role(setup, reliever, inning, score_margin, game_day, team_games_played_before):
					continue
			candidates.append(reliever)
		if not candidates.is_empty():
			break
	if candidates.is_empty():
		# **最終手段。** ここで null を返すと呼び出し側は継投を諦め、先発が投げ続ける。
		# 当日のブルペンは疲労を見ずに能力上位6人で固定されるため、その6人が全員
		# 緊急疲労上限を超えると「健康な救援がロスターに残っているのに誰も投げられない」
		# 状態になり、**1試合370球を投げる先発** が生まれる (二軍のファーム専用球団で
		# 起きやすい)。実野球では誰かが必ず投げるので、疲労上限を無視して
		# 最も疲労の少ない健康な投手を上げる。
		return _emergency_reliever(setup, used_ids)

	# 役割別のハードな登板可否で絞り込む。全滅する非常時 (適性役割しか残っていない等) は
	# 元の候補に戻し、試合が止まらないようにする。
	var eligible: Array = []
	for reliever_row in candidates:
		var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
		if _role_eligible_in_spot(setup, reliever, inning, score_margin, is_visitor, team_games_played_before):
			eligible.append(reliever)
	if eligible.is_empty():
		eligible = candidates

	# 同点で9回以降に入った延長戦の継投方針 (ユーザー指定):
	#   ビジター: クローザーを12回(最終回)まで温存し、残りリリーフを評価順に逆算配置。
	#   ホーム: 9回からクローザーを通常どおり投入し、以降は能力の高いリリーフ順。
	if not prefer_long and score_margin == 0 and inning >= GameSimulator.REGULATION_INNINGS:
		if is_visitor and inning < GameSimulator.MAX_INNINGS:
			return _pick_bridge_reliever(eligible, inning, close_game, game_day, team_games_played_before, farm)
		var closer: PSPlayerSeasonRecord = _find_role_in(setup, eligible, PSRotationPlanner.RELIEF_ROLE_CLOSER)
		if closer != null:
			return closer
		return _highest_ability_reliever(eligible, inning, close_game, game_day, team_games_played_before, farm)

	# 選抜スコアは登板可否・役割ボーナス・疲労を含む合成値で、1試合の継投判断ごとに引かれる。
	# comparator の中で計算すると 1 回の sort で O(n log n) 回走るので先に 1 人 1 回だけ引く
	# (並びは同じ — 同点時の解決順も sort に任せたままにしてある)。
	var score_by_id: Dictionary = {}
	for reliever_row in eligible:
		var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
		if reliever != null and not score_by_id.has(reliever.player_id):
			score_by_id[reliever.player_id] = reliever_selection_score_for_setup(
				setup, reliever, prefer_long, inning, close_game, score_margin,
				game_day, team_games_played_before
			)
	eligible.sort_custom(func(a, b) -> bool:
		var pitcher_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var pitcher_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return (
			float(score_by_id.get(pitcher_a.player_id, 0.0))
			> float(score_by_id.get(pitcher_b.player_id, 0.0))
		)
	)
	return eligible[0] as PSPlayerSeasonRecord


# 疲労上限を無視した非常時の継投先。当日のブルペン + 控え (relief_reserve) から、
# **この試合でまだ投げていない健康な投手のうち最も疲労が少ない者**を選ぶ。
# 同疲労は player_id で決める (並列実行でも結果が揺れないように)。
static func _emergency_reliever(setup: Dictionary, used_ids: Dictionary) -> PSPlayerSeasonRecord:
	var pool: Array = (setup.get("relievers", []) as Array).duplicate()
	pool.append_array(setup.get("relief_reserve", []) as Array)
	var best: PSPlayerSeasonRecord = null
	for row in pool:
		var pitcher: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
		if pitcher == null or used_ids.has(pitcher.player_id) or pitcher.injury_days > 0:
			continue
		if best == null:
			best = pitcher
			continue
		if pitcher.fatigue < best.fatigue:
			best = pitcher
		elif pitcher.fatigue == best.fatigue and pitcher.player_id < best.player_id:
			best = pitcher
	return best


# setup の守備チームがビジター (away) なら true。同点延長の継投方針 (温存 vs 即投入) を分岐する。
static func _is_visitor_setup(setup: Dictionary, game_result: Dictionary) -> bool:
	if game_result.is_empty():
		return false
	return int(setup.get("team_id", 0)) == int(game_result.get("away_team_id", 0))


# 役割別のハードな登板可否 (ユーザー指定):
# - セット: 7回以降かつビハインドでない。5点差以上のリードでは温存 (ミドルへ)。
# - クローザー: 9回以降かつビハインドでない。同点はホームなら9回から、ビジターは12回(最終回)まで温存。
#   5点差以上では温存。4点差は前日(直前のチーム試合)に登板していなければ可、連投ならミドルへ回す。
# - ミドル/ロング/未設定: 常時可。
static func _role_eligible_in_spot(setup: Dictionary, reliever: PSPlayerSeasonRecord, inning: int, score_margin: int, is_visitor: bool, team_games_played_before: int) -> bool:
	match _relief_role_for_pitcher(setup, reliever):
		PSRotationPlanner.RELIEF_ROLE_SETUP:
			if score_margin >= BLOWOUT_LEAD_MARGIN:
				return false
			return inning >= SETUP_EARLIEST_INNING and score_margin >= 0
		PSRotationPlanner.RELIEF_ROLE_CLOSER:
			if score_margin < 0 or inning < CLOSER_EARLIEST_INNING:
				return false
			if score_margin >= BLOWOUT_LEAD_MARGIN:
				return false
			if score_margin == 0 and is_visitor and inning < GameSimulator.MAX_INNINGS:
				return false
			if score_margin == CLOSER_FOUR_RUN_MARGIN and _pitched_previous_game(reliever, team_games_played_before, _is_farm_setup(setup)):
				return false
			return true
		_:
			return true


# 前日(直前のチーム試合)に登板していたら true。今登板すると連投になる場合を指す。
static func _pitched_previous_game(
	reliever: PSPlayerSeasonRecord, team_games_played_before: int, farm: bool = false
) -> bool:
	return PSPitcherUsageModel.next_consecutive_appearance_count(reliever, team_games_played_before, farm) >= 2


# ビジターが同点で延長に入ったときの逆算継投。クローザーは12回まで温存されここには来ないので、
# 残り候補を評価(能力)降順に並べ、最終回(12回)直前に最良が来るよう逆算インデックスで選ぶ。
# 例: 9回=3番手, 10回=2番手, 11回=最良, 12回=クローザー。候補が足りなければ末尾(最弱)に丸める。
static func _pick_bridge_reliever(
	candidates: Array, inning: int, close_game: bool, game_day: int,
	team_games_played_before: int, farm: bool = false
) -> PSPlayerSeasonRecord:
	if candidates.is_empty():
		return null
	var ordered: Array = candidates.duplicate()
	var ability_by_id: Dictionary = {}
	for reliever_row in ordered:
		var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
		if reliever != null and not ability_by_id.has(reliever.player_id):
			ability_by_id[reliever.player_id] = _reliever_ability_score(
				reliever, inning, close_game, game_day, team_games_played_before, farm
			)
	ordered.sort_custom(func(a, b) -> bool:
		return (
			float(ability_by_id.get((a as PSPlayerSeasonRecord).player_id, 0.0))
			> float(ability_by_id.get((b as PSPlayerSeasonRecord).player_id, 0.0))
		)
	)
	var index: int = clampi(GameSimulator.MAX_INNINGS - 1 - inning, 0, ordered.size() - 1)
	return ordered[index] as PSPlayerSeasonRecord


# 能力(基礎リリーフ評価)が最も高い候補を返す。同点でホームがクローザー投入後の継投に使う。
static func _highest_ability_reliever(
	candidates: Array, inning: int, close_game: bool, game_day: int,
	team_games_played_before: int, farm: bool = false
) -> PSPlayerSeasonRecord:
	var best: PSPlayerSeasonRecord = null
	var best_score: float = -INF
	for reliever_row in candidates:
		var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
		if reliever == null:
			continue
		var ability: float = _reliever_ability_score(reliever, inning, close_game, game_day, team_games_played_before, farm)
		if best == null or ability > best_score:
			best = reliever
			best_score = ability
	return best


# 役割補正を含まない基礎リリーフ評価 (能力 - 疲労等)。同点延長の「評価の高い順」並べ替えに使う。
static func _reliever_ability_score(
	reliever: PSPlayerSeasonRecord, inning: int, close_game: bool, game_day: int,
	team_games_played_before: int, farm: bool = false
) -> float:
	return PSPitcherUsageModel.reliever_selection_score(
		reliever, false, inning, close_game, game_day, team_games_played_before, farm
	)


# 指定役割の候補を1人返す (なければ null)。
static func _find_role_in(setup: Dictionary, candidates: Array, role: String) -> PSPlayerSeasonRecord:
	for reliever_row in candidates:
		var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
		if reliever != null and _relief_role_for_pitcher(setup, reliever) == role:
			return reliever
	return null


# 基礎スコア(能力・疲労・登板間隔)に、ユーザーが設定したリリーフ役割の場面補正を足す。
static func reliever_selection_score_for_setup(
	setup: Dictionary,
	reliever: PSPlayerSeasonRecord,
	prefer_long: bool,
	inning: int,
	close_game: bool,
	score_margin: int,
	game_day: int,
	team_games_played_before: int
) -> float:
	var farm: bool = _is_farm_setup(setup)
	var score: float = PSPitcherUsageModel.reliever_selection_score(
		reliever, prefer_long, inning, close_game, game_day, team_games_played_before, farm
	)
	var role_by_pitcher: Dictionary = setup.get("relief_role_by_pitcher", {}) as Dictionary
	var role: String = str(role_by_pitcher.get(reliever.player_id, role_by_pitcher.get(str(reliever.player_id), "")))
	var baselines: Dictionary = setup.get("callup_appearance_baseline", {}) as Dictionary
	var baseline_key: String = str(reliever.player_id)
	if baselines.has(baseline_key) \
			and reliever.pitcher_stats.games <= int(baselines[baseline_key]):
		score += CALLUP_AUDITION_BONUS
	return score + relief_role_context_bonus(role, prefer_long, inning, close_game, score_margin)


# 保存された役割と試合状況の噛み合わせ (リード時などの優先度付け)。セットは7-8回の4点以内リード/同点、
# クローザーは9回以降の4点以内リード/同点、ロングは早期降板/敗戦処理、ミドルはそれ以外を担当する。
# 回・ビハインドのハードな登板可否 (セット7回以降/クローザー9回以降/ビハインド除外/ビジター同点温存) は
# pick_reliever_for_context の _role_eligible_in_spot 側が担うので、ここは絞り込み後の優先度のみ扱う。
# close_game は基礎スコア用に使われ、この補正側では参照しない (符号付き score_margin で判定するため)。
static func relief_role_context_bonus(role: String, prefer_long: bool, inning: int, _close_game: bool, score_margin: int) -> float:
	var setup_spot: bool = _is_setup_spot(inning, score_margin)
	var setup_tie_spot: bool = _is_setup_tie_spot(inning, score_margin)
	var closer_save_spot: bool = _is_closer_save_spot(inning, score_margin)
	var closer_four_run_spot: bool = _is_closer_four_run_spot(inning, score_margin)
	var closer_spot: bool = closer_save_spot or closer_four_run_spot
	var closer_tie_spot: bool = _is_closer_tie_spot(inning, score_margin)
	var mop_up_spot: bool = _is_mop_up_spot(inning, score_margin)
	match role:
		PSRotationPlanner.RELIEF_ROLE_CLOSER:
			# 9回未満/ビハインド/ビジター同点はハードフィルタで除外済み。ここはリード時の優先度のみ。
			if prefer_long or mop_up_spot:
				return -180.0
			if closer_save_spot:
				return 320.0
			if closer_four_run_spot:
				return 235.0
			if closer_tie_spot:
				return 175.0
			return -35.0
		PSRotationPlanner.RELIEF_ROLE_SETUP:
			if prefer_long or mop_up_spot:
				return -130.0
			if setup_spot:
				return 215.0
			if setup_tie_spot:
				return 165.0
			if closer_save_spot:
				return 15.0
			if closer_four_run_spot:
				return 45.0
			if closer_tie_spot:
				return 80.0
			if score_margin < 0:
				return -60.0
			return -10.0
		PSRotationPlanner.RELIEF_ROLE_MIDDLE:
			if prefer_long:
				return -40.0
			if setup_spot or setup_tie_spot or closer_spot or closer_tie_spot:
				return -45.0
			if mop_up_spot:
				return -20.0
			return 85.0
		PSRotationPlanner.RELIEF_ROLE_LONG:
			if prefer_long:
				return 230.0
			if mop_up_spot:
				return 190.0
			if setup_spot or setup_tie_spot or closer_spot or closer_tie_spot:
				return -160.0
			if inning <= 5 and score_margin <= 0:
				return 90.0
			return -50.0
		_:
			return 0.0


static func _can_relax_availability_for_late_role(
	setup: Dictionary,
	reliever: PSPlayerSeasonRecord,
	inning: int,
	score_margin: int,
	game_day: int,
	team_games_played_before: int
) -> bool:
	var role: String = _relief_role_for_pitcher(setup, reliever)
	if role == PSRotationPlanner.RELIEF_ROLE_CLOSER:
		# 4点差は連投なら回避する方針なので relax (連投上限の緩和) 対象から外す。本物のセーブ場面
		# (1〜3点差) と同点 (ホーム9回/ビジター12回) のみ 3連投目まで候補に残す。
		if not (_is_closer_save_spot(inning, score_margin) or _is_closer_tie_spot(inning, score_margin)):
			return false
	elif role == PSRotationPlanner.RELIEF_ROLE_SETUP:
		if not (_is_setup_spot(inning, score_margin) or _is_setup_tie_spot(inning, score_margin)):
			return false
	else:
		return false
	return PSPitcherUsageModel.is_reliever_available(
		reliever, true, game_day, team_games_played_before, _is_farm_setup(setup)
	)


static func _is_farm_setup(setup: Dictionary) -> bool:
	return int(setup.get("level", PSTeamSetupBuilder.LEVEL_FIRST)) == PSTeamSetupBuilder.LEVEL_FARM


static func _relief_role_for_pitcher(setup: Dictionary, reliever: PSPlayerSeasonRecord) -> String:
	if reliever == null:
		return ""
	var role_by_pitcher: Dictionary = setup.get("relief_role_by_pitcher", {}) as Dictionary
	return str(role_by_pitcher.get(reliever.player_id, role_by_pitcher.get(str(reliever.player_id), "")))


static func _is_setup_spot(inning: int, score_margin: int) -> bool:
	return score_margin > 0 and score_margin <= 4 and inning >= 7 and inning <= 8


static func _is_setup_tie_spot(inning: int, score_margin: int) -> bool:
	return score_margin == 0 and inning >= 7 and inning <= 8


static func _is_closer_save_spot(inning: int, score_margin: int) -> bool:
	return score_margin > 0 and score_margin <= 3 and inning >= 9


static func _is_closer_four_run_spot(inning: int, score_margin: int) -> bool:
	return score_margin == 4 and inning >= 9


static func _is_closer_tie_spot(inning: int, score_margin: int) -> bool:
	return score_margin == 0 and inning >= 9


static func _is_mop_up_spot(inning: int, score_margin: int) -> bool:
	return score_margin <= -4 or (inning >= 7 and score_margin <= -3)


# setup のチーム視点で3点差以内なら close game とみなす。
static func is_close_game_for_setup(setup: Dictionary, game_result: Dictionary) -> bool:
	if game_result.is_empty():
		return false
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if team_id == away_team_id:
		return abs(away_score - home_score) <= 3
	if team_id == home_team_id:
		return abs(home_score - away_score) <= 3
	return false


static func should_prefer_long_relief_for_starter_exit(inning: int) -> bool:
	return inning < LONG_RELIEF_PREFERRED_BEFORE_INNING


# setup のチーム視点の得失点差。正ならリード、負ならビハインド。
static func score_margin_for_setup(setup: Dictionary, game_result: Dictionary) -> int:
	if game_result.is_empty():
		return 0
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if team_id == away_team_id:
		return away_score - home_score
	if team_id == home_team_id:
		return home_score - away_score
	return 0


# usage モデルへ渡す outing role を決める。保存役割 long は常に長い回の想定、
# それ以外でも先発早期降板の穴埋めでは long relief として疲労計算する。
static func _outing_role_for_reliever(setup: Dictionary, reliever: PSPlayerSeasonRecord, prefer_long: bool) -> String:
	if reliever == null:
		return PSPitcherUsageModel.ROLE_SHORT_RELIEF
	var role_by_pitcher: Dictionary = setup.get("relief_role_by_pitcher", {}) as Dictionary
	var assigned_role: String = str(role_by_pitcher.get(reliever.player_id, role_by_pitcher.get(str(reliever.player_id), "")))
	if assigned_role == PSRotationPlanner.RELIEF_ROLE_LONG:
		return PSPitcherUsageModel.ROLE_LONG_RELIEF
	return PSPitcherUsageModel.ROLE_LONG_RELIEF if prefer_long else PSPitcherUsageModel.ROLE_SHORT_RELIEF


# 投手ごとの当日 usage を遅延生成して返す。球数・失点・打者数などは GameLoop 側が同じ dict を更新する。
static func pitcher_usage_for(setup: Dictionary, pitcher: PSPlayerSeasonRecord, role: String = "") -> Dictionary:
	if pitcher == null:
		return {}
	var usage_by_id: Dictionary = setup.get("pitcher_usage", {}) as Dictionary
	var key: String = str(pitcher.player_id)
	if not usage_by_id.has(key):
		var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
		var resolved_role: String = role
		if resolved_role.is_empty():
			resolved_role = PSPitcherUsageModel.ROLE_STARTER if starter != null and starter.player_id == pitcher.player_id else PSPitcherUsageModel.ROLE_SHORT_RELIEF
		usage_by_id[key] = PSPitcherUsageModel.create_outing(pitcher, resolved_role)
		setup["pitcher_usage"] = usage_by_id
	return usage_by_id[key] as Dictionary


# 同一試合で同じ投手を再登板させないための使用済みセット。
static func mark_pitcher_used(setup: Dictionary, pitcher: PSPlayerSeasonRecord) -> void:
	if pitcher == null:
		return
	var used_ids: Dictionary = setup.get("used_pitcher_ids", {}) as Dictionary
	used_ids[pitcher.player_id] = true
	setup["used_pitcher_ids"] = used_ids


# 試合終了時に当日 usage から累積疲労を加算し、投手の怪我判定を行う。
# 登板していない投手は pitcher_usage に存在しないので対象外。
static func finalize_pitcher_usage(setup: Dictionary) -> void:
	var usage_by_id: Dictionary = setup.get("pitcher_usage", {}) as Dictionary
	for usage_value in usage_by_id.values():
		var usage: Dictionary = usage_value as Dictionary
		var pitcher: PSPlayerSeasonRecord = usage.get("record", null) as PSPlayerSeasonRecord
		if pitcher == null:
			continue
		var fatigue_gain: int = PSPitcherUsageModel.post_game_fatigue_gain(pitcher, usage)
		if fatigue_gain <= 0:
			continue
		pitcher.fatigue = int(min(GameSimulator.FATIGUE_MAX, pitcher.fatigue + fatigue_gain))
		PSScoringHelpers.maybe_injure_for_setup(setup, pitcher, true)


# 先発が降板した時点のアウト数と失点を固定する。
# 勝敗・完投・QS などの事後判定で「先発がどこまで投げたか」を読む。
static func mark_starter_relieved(setup: Dictionary, current_outs: int = -1, current_runs: int = -1) -> void:
	if int(setup.get("starter_outs", -1)) < 0:
		setup["starter_outs"] = int(setup.get("game_outs", 0)) if current_outs < 0 else current_outs
		setup["starter_runs"] = int(setup.get("game_runs_allowed", 0)) if current_runs < 0 else current_runs
	setup["starter_relieved"] = true


static func _fielder_ids_for_setup(setup: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	var fielders: Array = setup.get("fielders", []) as Array
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			ids[record.player_id] = true
	return ids
