extends RefCounted
class_name PSContactQualityModel

# 投球がインプレー(BIP)になった後に、打球の質(初速・角度・方向)を生成するモデル。
# 飛距離・滞空時間・守備・最終結果は後段の別モデルが解決する。

# 打球初速(EV)の基準値と、能力・球速・状況による各種補正の重み。
# EV_BASE は打者長打力と投手球威の固定基準値を代数的に畳み込んだ値。
# 同じ z カーブと重みを打者は加点、投手は減点に使うため、両者の水準が一緒に下がる環境でも
# 対戦の相対差が維持される。正側の最上位だけは打者・投手別の固定上限で飽和させる。
# 基準値と上限は母集団から動的に算出しない。
const EV_BASE: float = 94.25                 # 打球初速の基準値(mph)。
const EV_CONTACT_WEAK_PENALTY: float = 1.40  # 芯を外すほど EV を下げる重み。
# 長打力カーブが高いほど EV を上げる量(mph)。
# パワーによるHR差は、このEV経路と理想角(power_ideal_*)で表現する。
const EV_HOME_RUN_POWER_WEIGHT: float = 5.6
const EV_PITCH_VELOCITY_WEIGHT: float = 0.08 # 投球速度が基準より速いほど EV を上げる重み。
const EV_STUFF_WEIGHT: float = 5.6          # 投手球威カーブが高いほど EV を下げる量(mph)。
const EV_FATIGUE_WEIGHT: float = 0.035
const EV_CHASE_PENALTY: float = 3.50
const EV_TWO_STRIKE_PENALTY: float = 1.25
const EV_PROTECTIVE_AVOID_K_PENALTY: float = 2.60
const EV_FORCED_PROTECTIVE_OUT_PENALTY: float = 8.0
const EV_RANDOM_SPREAD: float = 9.5
const EV_MIN: float = 48.0
const EV_MAX: float = 119.0
# 芯で捉えた打球(perfect contact)の発生率と、その際のEV上昇・角度をバレル角へ寄せる強さ。
const PERFECT_CONTACT_BASE_RATE: float = 0.064
const PERFECT_CONTACT_EV_BOOST: float = 8.5
const PERFECT_CONTACT_LA_PULL_TO_BARREL: float = 0.10

# ギャップを破るライナーの目標角度と、そこへ角度を寄せる強さ。
const GAP_LINER_TARGET_LA: float = 16.0
const GAP_LINER_LA_PULL: float = 0.34

# 本塁打向きの理想打球角(ideal power)の発生率・目標角・EV上乗せ・飛距離ボーナス。
const POWER_IDEAL_LA_BASE_RATE: float = 0.045
const POWER_IDEAL_LA_PULL: float = 0.52
const POWER_IDEAL_LA_TARGET: float = 28.0
const POWER_IDEAL_LA_EV_BOOST: float = 1.4
const POWER_IDEAL_LA_EXTRA_EV: float = 1.45
const POWER_IDEAL_CARRY_BONUS: float = 0.070

# 詰まり/芯外し(mishit)の発生率と、その際のEV低下・角度の散らばり。
const MISHIT_BASE_RATE: float = 0.100
const MISHIT_EV_PENALTY: float = 7.5
const MISHIT_LA_SCATTER: float = 7.0

# 投手の球威(stuff)が EV・芯・詰まり・理想角の各判定に効く重み。
const STUFF_PERFECT_LOGIT_WEIGHT: float = 0.7
const STUFF_MISHIT_LOGIT_WEIGHT: float = 0.65
const STUFF_IDEAL_POWER_LOGIT_WEIGHT: float = 1.2
# 長打力カーブが本塁打向きの理想角を引く確率へ効く強さ。EV 経路と合わせて「本塁打はパワーの
# 上位へ集まる」形を作る。リーグ HR 総量は hr_wall_clearance 側で決め、こちらは分布の集中度を持つ。
const IDEAL_POWER_CURVE_WEIGHT: float = 1.6

# 打球角度(LA)の基準値・投球コース別オフセット・ばらつき範囲とクランプ。
# LA_RANDOM_SPREAD は _gaussian の係数(実効σ ≈ spread×0.577)。Statcast 実測の打球角は
# 平均≈11-12° / σ≈25°(2017-19: 25.0-25.3)なので spread 42 で σ≈24 を実現し、
# バケット比率(ゴロ<10° ≈44% / ライナー10-25° ≈24% / フライ25-50° ≈24% / ポップ>50° ≈7%)を再現する。
const LA_BASE: float = 11.5
const LA_HEIGHT_LOW_OFFSET: float = -7.0
const LA_HEIGHT_MIDDLE_OFFSET: float = 1.0
const LA_HEIGHT_HIGH_OFFSET: float = 8.0
const LA_RANDOM_SPREAD: float = 42.0
const LA_CHASE_NOISE_BOOST: float = 2.75
const LA_MIN: float = -60.0
const LA_MAX: float = 78.0
# EV-LA 結合(Statcast 実測のドーム形状): EVはLD帯(≈10-30°)で最大、帯から離れるほど低下(≈2mph/5°)。
# ポップフライや極端なチョッパーが平均EVのまま飛びすぎるのを防ぐ。
const LA_EV_HIGH_FALLOFF: float = 0.20  # LA が30°を超えた1°あたりのEV低下(mph)。
const LA_EV_LOW_FALLOFF: float = 0.12   # LA が-5°を下回った1°あたりのEV低下(mph)。

# 球種構成の傾向(集計済み・中心化済み)による打球補正。**いずれも微差**(較正フェーズで強める前提)。
const LA_GB_WEIGHT: float = 1.2          # ゴロ寄り球種ほど打球角度(LA)をわずかに下げ、フライ率を下げる。
const ARSENAL_HR_PERFECT_WEIGHT: float = 0.05 # 被弾寄り球種でわずかに芯(perfect)を許す。
const ARSENAL_HR_IDEAL_WEIGHT: float = 0.06   # 被弾寄り球種でわずかに本塁打向き理想角を許す。

# 打球方向(spray角)の基準・プル/流しの振り分け・ギャップ狙い・ばらつきの各係数。
const SPRAY_BASE: float = 0.0
const SPRAY_PULL_BASE: float = 22.0
const SPRAY_OPPOSITE_BASE: float = 14.0
const SPRAY_PULL_PROBABILITY_BASE: float = 0.50
const SPRAY_PULL_INSIDE_BIAS: float = 0.20
const SPRAY_PULL_OUTSIDE_BIAS: float = -0.18
const SPRAY_PULL_TENDENCY_WEIGHT: float = 0.15
const SPRAY_GAP_TARGET_ANGLE: float = 18.0
const SPRAY_GAP_INTENT_BASE: float = 0.20
const SPRAY_GAP_INTENT_WEIGHT: float = 0.26
const SPRAY_GAP_ALIGNMENT_WEIGHT: float = 0.32
const SPRAY_GAP_NOISE_REDUCTION: float = 0.22
const SPRAY_RANDOM_SPREAD: float = 8.5
const SPRAY_CHASE_RANDOM_BOOST: float = 4.0
const SPRAY_MIN: float = -52.0
const SPRAY_MAX: float = 52.0

# 球速補正の基準球速(km/h)。これより速い球ほど EV が上がる。
const PITCH_VELOCITY_BASE: float = 145.0

# 能力値(z-score)を計算へ投入するための変換定数。
# 各能力カーブの中心値。raw z の分布平均は能力ごとに異なるため、カーブが最も敏感に反応する
# 位置(中心)をここで個別に指定する(player_value_evaluator.gd の _ability_curve(center=0.4) と
# 同種の、ただのチューニング定数。母集団の実測値を追跡・更新する仕組みではない)。
const BAT_CONTACT_CURVE_CENTER: float = 0.9995
const BAT_GAP_CURVE_CENTER: float = 1.3568
const BAT_HR_CURVE_CENTER: float = 2.0017
const BAT_AVOID_K_CURVE_CENTER: float = 0.7213
const PIT_STUFF_CURVE_CENTER: float = 1.5804
const CURVE_WIDTH_Z: float = 1.6          # 能力カーブの標準的な幅（z スケール）。
const AVOID_K_CURVE_WIDTH_Z: float = 1.44 # 三振回避カーブだけ少し狭めの幅。
# 打球品質を直接動かすカーブの正側上位だけを漸近圧縮し、強打者・エースの差が無制限に重ならないようにする。
# 低〜中位と負側は同じカーブ・重みのままなので、能力帯が下がった環境での投打相殺は維持される。
# 投手側は K/BB の差も別経路で重なるため、stuff の正側上限を打者側より低くする。
const BATTER_QUALITY_CURVE_TAIL_PIVOT: float = 0.65
const BATTER_QUALITY_CURVE_TAIL_SPAN: float = 0.25
const PITCHER_STUFF_CURVE_TAIL_PIVOT: float = 0.4
const PITCHER_STUFF_CURVE_TAIL_SPAN: float = 0.2
# 打球品質を動かす「打者カーブ - 投手カーブ」の飽和点。上のテール圧縮が能力の絶対値に掛かるのに対し、
# こちらは**対戦の差**に掛かる。両者が同じだけ弱くなれば差は動かないので得点環境は移動せず
# (レベル不変)、同水準どうしの能力差も残り、極端なミスマッチだけが飽和する。
# EV / 芯 / 詰まり / 理想角の4経路は投打の重みが対称なので同じ差を共有する。
#
# **天井は投打で非対称** (差が正 = 打者優位)。打者優位側 (0.55+0.25=0.80) を投手優位側
# (0.28+0.12=0.40) より高くしてある。同じ天井にすると、本塁打王を実勢 (30-40本) へ戻したときに
# 規定 ERA 1点台の投手が帯 (3人以下) を超える — 失点は 0 で下げ止まるが打撃の上振れには
# 同じ頭打ちが無いという実勢の非対称を、そのまま天井の差として持たせている。
# 検証は tools/run_balance_report の 3 シードと tools/run_farm_report --seasons=3 の勝率ゲート。
const MATCHUP_CURVE_PIVOT: float = 0.55
const MATCHUP_CURVE_SPAN: float = 0.25
const MATCHUP_CURVE_PITCHER_PIVOT: float = 0.28
const MATCHUP_CURVE_PITCHER_SPAN: float = 0.12


static func generate(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	pitch_outcome: Dictionary,
	_state: Dictionary,
	precomp: Dictionary = {}
) -> Dictionary:
	# 打者・投手の能力(z)と打者疲労・投手の被弾傾向などを precomp から取り出す。
	var rules: Dictionary = precomp.get("_contact_quality_rules", {}) as Dictionary
	var batter_hr_z: float = float(precomp.get("batter_hr_z", 0.0))
	var pitcher_stuff_z: float = float(precomp.get("pitcher_stuff_z", 0.0))
	var batter_fatigue: int = int(precomp.get("batter_fatigue", 0))
	var batter_is_pitcher: bool = bool(precomp.get("batter_is_pitcher", false))
	var pitcher_contact_damage: float = float(precomp.get("pitcher_contact_damage", 0.0))
	# 球種傾向(微差): ゴロ寄り→LA微減 / 被弾寄り→芯・理想角を微増。
	var arsenal_gb_bias: float = float(precomp.get("pitcher_gb_bias", 0.0))
	var arsenal_hr_bias: float = float(precomp.get("pitcher_hr_bias", 0.0))
	var bat_contact_curve_center: float = _rule_float(rules, "bat_contact_curve_center", BAT_CONTACT_CURVE_CENTER)
	var bat_gap_curve_center: float = _rule_float(rules, "bat_gap_curve_center", BAT_GAP_CURVE_CENTER)
	var bat_hr_curve_center: float = _rule_float(rules, "bat_hr_curve_center", BAT_HR_CURVE_CENTER)
	var bat_avoid_k_curve_center: float = _rule_float(rules, "bat_avoid_k_curve_center", BAT_AVOID_K_CURVE_CENTER)
	var pit_stuff_curve_center: float = _rule_float(rules, "pit_stuff_curve_center", PIT_STUFF_CURVE_CENTER)
	var curve_width_z: float = _rule_float(rules, "curve_width_z", CURVE_WIDTH_Z)
	# 各能力 z を [-1, 1] のカーブへ変換する（接触/ギャップ/本塁打/三振回避/球威）。
	var contact_curve: float = PSBalanceProfile.ability_curve_z(float(precomp.get("batter_contact_z", 0.0)), bat_contact_curve_center, curve_width_z)
	var gap_curve: float = PSBalanceProfile.ability_curve_z(float(precomp.get("batter_gap_z", 0.0)), bat_gap_curve_center, curve_width_z)
	var home_run_curve: float = PSBalanceProfile.ability_curve_z(batter_hr_z, bat_hr_curve_center, curve_width_z)
	var avoid_k_curve: float = PSBalanceProfile.ability_curve_z(float(precomp.get("batter_avoid_k_z", 0.0)), bat_avoid_k_curve_center, _rule_float(rules, "avoid_k_curve_width_z", AVOID_K_CURVE_WIDTH_Z))
	var stuff_curve: float = PSBalanceProfile.ability_curve_z(pitcher_stuff_z, pit_stuff_curve_center, curve_width_z)
	var batter_tail_pivot: float = _rule_float(rules, "batter_quality_curve_tail_pivot", BATTER_QUALITY_CURVE_TAIL_PIVOT)
	var batter_tail_span: float = _rule_float(rules, "batter_quality_curve_tail_span", BATTER_QUALITY_CURVE_TAIL_SPAN)
	var pitcher_tail_pivot: float = _rule_float(rules, "pitcher_stuff_curve_tail_pivot", PITCHER_STUFF_CURVE_TAIL_PIVOT)
	var pitcher_tail_span: float = _rule_float(rules, "pitcher_stuff_curve_tail_span", PITCHER_STUFF_CURVE_TAIL_SPAN)
	contact_curve = PSBalanceProfile.compress_z_tail(contact_curve, batter_tail_pivot, batter_tail_span)
	home_run_curve = PSBalanceProfile.compress_z_tail(home_run_curve, batter_tail_pivot, batter_tail_span)
	stuff_curve = PSBalanceProfile.compress_z_tail(stuff_curve, pitcher_tail_pivot, pitcher_tail_span)
	# 打球品質へ効く投打の差を1度だけ作り、飽和させてから各経路で使い回す。
	# power 系 (EV / 理想角) は長打力 vs 球威、contact 系 (芯 / 詰まり) は接触 vs 球威。
	var matchup_pivot: float = _rule_float(rules, "matchup_curve_pivot", MATCHUP_CURVE_PIVOT)
	var matchup_span: float = _rule_float(rules, "matchup_curve_span", MATCHUP_CURVE_SPAN)
	var matchup_pitcher_pivot: float = _rule_float(rules, "matchup_curve_pitcher_pivot", MATCHUP_CURVE_PITCHER_PIVOT)
	var matchup_pitcher_span: float = _rule_float(rules, "matchup_curve_pitcher_span", MATCHUP_CURVE_PITCHER_SPAN)
	var power_delta: float = PSBalanceProfile.compress_matchup_advantage(
		home_run_curve - stuff_curve, matchup_pivot, matchup_span, matchup_pitcher_pivot, matchup_pitcher_span
	)
	var contact_delta: float = PSBalanceProfile.compress_matchup_advantage(
		contact_curve - stuff_curve, matchup_pivot, matchup_span, matchup_pitcher_pivot, matchup_pitcher_span
	)

	# 投球結果(球速・コース・ゾーン内外・2ストライク防御・強制アウト)を取り出す。
	var pitch_velocity: int = int(pitch_outcome.get("pitch_velocity", 142))
	var in_zone: bool = bool(pitch_outcome.get("in_zone", true))
	var location_height: String = str(pitch_outcome.get("location_height", "middle"))
	var two_strike: bool = bool(pitch_outcome.get("two_strike_protective", false))
	var protective_out: bool = bool(pitch_outcome.get("protective_out", false))
	# ゾーン外の球を打った場合は「追いかけ(chase)」とみなす。
	var chase: bool = not in_zone
	# 打球のばらつき倍率（現在は常に 1.0）。
	var variance_multiplier: float = 1.0

	# EV(打球初速)を基準値から組み立てる。
	var ev: float = _rule_float(rules, "ev_base", EV_BASE)
	# 打者の長打力と投手の球威を同じカーブ・同じ重みで相殺し、球速・疲労・被弾傾向を加える。
	# 投打の重みは対称であることが前提。平均を取って圧縮済みの差へ掛ける。
	ev += power_delta * _symmetric_weight(
		_rule_float(rules, "ev_home_run_power_weight", EV_HOME_RUN_POWER_WEIGHT),
		_rule_float(rules, "ev_stuff_weight", EV_STUFF_WEIGHT)
	)
	ev += (float(pitch_velocity) - _rule_float(rules, "pitch_velocity_base", PITCH_VELOCITY_BASE)) * _rule_float(rules, "ev_pitch_velocity_weight", EV_PITCH_VELOCITY_WEIGHT)
	ev -= float(batter_fatigue) * _rule_float(rules, "ev_fatigue_weight", EV_FATIGUE_WEIGHT)
	ev += pitcher_contact_damage * _rule_float(rules, "pitcher_contact_damage_ev_weight", 0.75)
	# 追いかけ・2ストライク防御・強制アウト・投手打者の各状況で EV を減らす。
	if chase:
		ev -= _rule_float(rules, "ev_chase_penalty", EV_CHASE_PENALTY)
	if two_strike:
		ev -= _rule_float(rules, "ev_two_strike_penalty", EV_TWO_STRIKE_PENALTY)
		ev -= max(0.0, avoid_k_curve) * _rule_float(rules, "ev_protective_avoid_k_penalty", EV_PROTECTIVE_AVOID_K_PENALTY)
	if protective_out:
		ev -= _rule_float(rules, "ev_forced_protective_out_penalty", EV_FORCED_PROTECTIVE_OUT_PENALTY)
	if batter_is_pitcher:
		ev -= _rule_float(rules, "pitcher_batter_ev_penalty", 4.0)
	# 接触で投手に押されているほど EV を下げる。
	# ⚠️ **contact_curve ではなく contact_delta (投打の差) を使う。** 能力の絶対値で見ると
	# 「打者が弱い側にだけ発火する片側減点」になり、リーグ全体の水準が下がっただけで
	# 打球品質が落ちる (投手側に対応する加点が無いため)。差で見れば両者が同じだけ弱くなっても
	# 発火せず、「投手に力負けしている打席」でだけ効くという本来の意図が保たれる。
	var contact_weakness: float = max(0.0, -contact_delta)
	ev -= contact_weakness * _rule_float(rules, "ev_contact_weak_penalty", EV_CONTACT_WEAK_PENALTY)
	# ギャップ能力に応じて、後で打球角度をライナーへ寄せる量を先に算出しておく。
	var gap_liner_pull: float = clamp(max(0.0, gap_curve) * _rule_float(rules, "gap_liner_la_pull", GAP_LINER_LA_PULL), 0.0, 0.42)
	# 最後に正規乱数で EV を散らばらせる。
	ev += _gaussian(_rule_float(rules, "ev_random_spread", EV_RANDOM_SPREAD) * variance_multiplier)

	# LA(打球角度)を基準値から組み立て、投球コースの高さでオフセットを加える。
	var la: float = _rule_float(rules, "la_base", LA_BASE)
	match location_height:
		"low":
			la += _rule_float(rules, "la_height_low_offset", LA_HEIGHT_LOW_OFFSET)
		"middle":
			la += _rule_float(rules, "la_height_middle_offset", LA_HEIGHT_MIDDLE_OFFSET)
		"high":
			la += _rule_float(rules, "la_height_high_offset", LA_HEIGHT_HIGH_OFFSET)
	# 球種のゴロ寄り傾向で打球角度をわずかに下げる(微差)。
	la -= arsenal_gb_bias * _rule_float(rules, "la_gb_weight", LA_GB_WEIGHT)
	# 接触能力が高いほど角度のばらつきを抑え、低い・追いかけ・2ストライク・強制アウトで広げる。
	# 実測の打者間 LA σ は ~22-28° の幅なので、能力による増減は ±1割程度に留める。
	var la_spread: float = _rule_float(rules, "la_random_spread", LA_RANDOM_SPREAD)
	# こちらも同じ理由で contact_delta 基準 (絶対値で見ると弱いリーグほど角度が散る)。
	la_spread *= 1.0 - max(0.0, contact_delta) * _rule_float(rules, "contact_la_control_weight", 0.12) + contact_weakness * _rule_float(rules, "contact_weak_la_spread_weight", 0.08)
	if chase:
		la_spread += _rule_float(rules, "la_chase_noise_boost", LA_CHASE_NOISE_BOOST)
	if two_strike:
		la_spread += max(0.0, avoid_k_curve) * _rule_float(rules, "two_strike_la_avoid_k_weight", 1.8)
	if protective_out:
		la_spread += _rule_float(rules, "protective_out_la_spread", 4.0)
	# 乱数で角度を散らばらせ、ライナー帯(8〜24度)ならギャップ狙いの角度へ寄せる。
	la += _gaussian(la_spread * variance_multiplier)
	if gap_liner_pull > 0.0 and la >= 8.0 and la <= 24.0:
		la = lerp(la, _rule_float(rules, "gap_liner_target_la", GAP_LINER_TARGET_LA), gap_liner_pull)

	# 芯で捉える確率(perfect)を、基準率＋接触能力・球威・状況のロジットから算出する。
	var perfect_logit: float = PSBalanceProfile.logit(_rule_float(rules, "perfect_contact_base_rate", PERFECT_CONTACT_BASE_RATE))
	perfect_logit += contact_delta * _symmetric_weight(
		_rule_float(rules, "perfect_contact_curve_weight", 0.70),
		_rule_float(rules, "stuff_perfect_logit_weight", STUFF_PERFECT_LOGIT_WEIGHT)
	)
	perfect_logit += pitcher_contact_damage * _rule_float(rules, "pitcher_contact_damage_perfect_weight", 0.05)
	perfect_logit += arsenal_hr_bias * _rule_float(rules, "arsenal_hr_perfect_weight", ARSENAL_HR_PERFECT_WEIGHT)  # 被弾寄り球種で芯を微増(微差)。
	if two_strike:
		perfect_logit -= _rule_float(rules, "perfect_two_strike_penalty", 0.35)
	if chase:
		perfect_logit -= _rule_float(rules, "perfect_chase_penalty", 0.25)
	var perfect_chance: float = clamp(PSBalanceProfile.sigmoid(perfect_logit), 0.015, 0.22)

	# 詰まり/芯外し(mishit)の確率を、同様にロジットから算出する。
	var mishit_logit: float = PSBalanceProfile.logit(_rule_float(rules, "mishit_base_rate", MISHIT_BASE_RATE))
	mishit_logit -= contact_delta * _symmetric_weight(
		_rule_float(rules, "mishit_contact_curve_weight", 0.65),
		_rule_float(rules, "stuff_mishit_logit_weight", STUFF_MISHIT_LOGIT_WEIGHT)
	)
	mishit_logit -= pitcher_contact_damage * _rule_float(rules, "pitcher_contact_damage_mishit_weight", 0.04)
	if two_strike:
		mishit_logit += _rule_float(rules, "mishit_two_strike_penalty", 0.28)
		mishit_logit += max(0.0, avoid_k_curve) * _rule_float(rules, "mishit_two_strike_avoid_k_weight", 0.20)
	if protective_out:
		mishit_logit += _rule_float(rules, "mishit_protective_out_penalty", 1.10)
	if chase:
		mishit_logit += _rule_float(rules, "mishit_chase_penalty", 0.42)
	var mishit_chance: float = clamp(PSBalanceProfile.sigmoid(mishit_logit), 0.025, 0.30)

	# 1回の抽選で perfect / mishit / 通常 を判定し、EV と角度を補正する。
	var was_mishit: bool = false
	var quality_roll: float = Rng.roll_float()
	if quality_roll < perfect_chance:
		ev += _rule_float(rules, "perfect_contact_ev_boost", PERFECT_CONTACT_EV_BOOST)
		var barrel_angle: float = 18.0
		la = lerp(la, barrel_angle, _rule_float(rules, "perfect_contact_la_pull_to_barrel", PERFECT_CONTACT_LA_PULL_TO_BARREL))
	elif quality_roll < perfect_chance + mishit_chance:
		was_mishit = true
		ev -= _rule_float(rules, "mishit_ev_penalty", MISHIT_EV_PENALTY)
		la += _gaussian(_rule_float(rules, "mishit_la_scatter", MISHIT_LA_SCATTER) * variance_multiplier)

	# 本塁打向きの理想角(ideal power)を引く確率を、長打力・球威・状況から算出する。
	var ideal_power_logit: float = PSBalanceProfile.logit(_rule_float(rules, "power_ideal_la_base_rate", POWER_IDEAL_LA_BASE_RATE))
	# 長打力ゲート。上げると上位打者ほど本塁打向きの理想角に入りやすくなる。
	ideal_power_logit += power_delta * _symmetric_weight(
		_rule_float(rules, "ideal_power_curve_weight", IDEAL_POWER_CURVE_WEIGHT),
		_rule_float(rules, "stuff_ideal_power_logit_weight", STUFF_IDEAL_POWER_LOGIT_WEIGHT)
	)
	ideal_power_logit += pitcher_contact_damage * _rule_float(rules, "pitcher_contact_damage_ideal_weight", 0.04)
	ideal_power_logit += arsenal_hr_bias * _rule_float(rules, "arsenal_hr_ideal_weight", ARSENAL_HR_IDEAL_WEIGHT)  # 被弾寄り球種で理想角を微増(微差)。
	if chase:
		ideal_power_logit -= _rule_float(rules, "ideal_power_chase_penalty", 0.38)
	if two_strike:
		ideal_power_logit -= _rule_float(rules, "ideal_power_two_strike_penalty", 0.22)
	if was_mishit:
		ideal_power_logit -= _rule_float(rules, "ideal_power_mishit_penalty", 1.25)
	var ideal_power_chance: float = clamp(PSBalanceProfile.sigmoid(ideal_power_logit), 0.006, 0.26)
	# 理想角を引いたら EV を上乗せし、角度を理想角へ寄せる。
	var ideal_power_launch: bool = Rng.roll_float() < ideal_power_chance
	if ideal_power_launch:
		ev += _rule_float(rules, "power_ideal_la_ev_boost", POWER_IDEAL_LA_EV_BOOST) + max(0.0, home_run_curve) * _rule_float(rules, "power_ideal_la_extra_ev", POWER_IDEAL_LA_EXTRA_EV)
		var ideal_angle: float = _rule_float(rules, "power_ideal_la_target", POWER_IDEAL_LA_TARGET)
		la = lerp(la, ideal_angle, _rule_float(rules, "power_ideal_la_pull", POWER_IDEAL_LA_PULL))

	# LA を確定してから EV-LA 結合(ドーム形状)を適用し、両方を物理的に妥当な範囲へクランプする。
	la = clamp(la, _rule_float(rules, "la_min", LA_MIN), _rule_float(rules, "la_max", LA_MAX))
	ev -= max(0.0, la - 30.0) * _rule_float(rules, "la_ev_high_falloff", LA_EV_HIGH_FALLOFF)
	ev -= max(0.0, -5.0 - la) * _rule_float(rules, "la_ev_low_falloff", LA_EV_LOW_FALLOFF)
	ev = clamp(ev, _rule_float(rules, "ev_min", EV_MIN), _rule_float(rules, "ev_max", EV_MAX))

	# 打球方向(spray角)を生成し、理想角ヒット時は飛距離(carry)を伸ばす。
	var spray_gap_curve: float = gap_curve if la >= 8.0 and la <= 24.0 else min(0.0, gap_curve)
	var spray: float = _generate_spray(batter, pitcher, location_height, spray_gap_curve, chase, variance_multiplier, rules)
	var carry_multiplier: float = 1.0
	if ideal_power_launch:
		carry_multiplier += _rule_float(rules, "power_ideal_carry_bonus", POWER_IDEAL_CARRY_BONUS) + max(0.0, home_run_curve) * _rule_float(rules, "ideal_power_curve_carry_weight", 0.090)

	# 確定した打球の質(EV/LA/spray/carry と状況フラグ)を辞書で返す。
	return {
		"exit_velocity": _round_float(ev, 2),
		"launch_angle": _round_float(la, 2),
		"spray_angle": _round_float(spray, 2),
		"carry_multiplier": _round_float(clamp(carry_multiplier, 0.76, 1.10), 3),
		"gap_liner_pull": _round_float(gap_liner_pull, 3),
		"ideal_power_launch": ideal_power_launch,
		"protective_out": protective_out,
		"in_zone": in_zone,
		"chase": chase,
		"two_strike": two_strike,
		"location_height": location_height,
		"pitch_velocity": pitch_velocity,
	}


# 打球方向(spray角)を、打者の利き・投球コース・プル傾向・ギャップ狙い・乱数から生成する。
static func _generate_spray(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	location_height: String,
	gap_curve: float,
	chase: bool,
	variance_multiplier: float,
	rules: Dictionary
) -> float:
	# プル(引っ張り)になる確率を基準値から組み立てる。
	var pull_chance: float = _rule_float(rules, "spray_pull_probability_base", SPRAY_PULL_PROBABILITY_BASE)

	# 内角ならプルしやすく、外角ならしにくく、ギャップ能力でも増減させる。
	var batting_side: int = _batting_side(batter)
	var inside_to_batter: bool = _is_inside_pitch(location_height, batting_side, pitcher)
	if inside_to_batter:
		pull_chance += _rule_float(rules, "spray_pull_inside_bias", SPRAY_PULL_INSIDE_BIAS)
	else:
		pull_chance += _rule_float(rules, "spray_pull_outside_bias", SPRAY_PULL_OUTSIDE_BIAS)
	pull_chance += clamp(gap_curve, -1.0, 1.0) * _rule_float(rules, "spray_pull_tendency_weight", SPRAY_PULL_TENDENCY_WEIGHT)
	pull_chance = clamp(pull_chance, 0.10, 0.92)

	# プルするか・ギャップを狙うかを抽選し、打球方向の大きさ(magnitude)を決める。
	var pulling: bool = Rng.roll_float() < pull_chance
	var gap_intent_chance: float = _rule_float(rules, "spray_gap_intent_base", SPRAY_GAP_INTENT_BASE) + max(0.0, gap_curve) * _rule_float(rules, "spray_gap_intent_weight", SPRAY_GAP_INTENT_WEIGHT)
	if chase:
		gap_intent_chance -= 0.08
	gap_intent_chance = clamp(gap_intent_chance, 0.06, 0.52)
	var gap_intent: bool = Rng.roll_float() < gap_intent_chance
	var magnitude: float
	if gap_intent:
		magnitude = _rule_float(rules, "spray_gap_target_angle", SPRAY_GAP_TARGET_ANGLE) + _gaussian(2.0 * variance_multiplier)
	else:
		magnitude = _rule_float(rules, "spray_pull_base", SPRAY_PULL_BASE) if pulling else _rule_float(rules, "spray_opposite_base", SPRAY_OPPOSITE_BASE)
	# プルなら左方向(負)、流しなら右方向(正)に向け、打者の左右・スイッチで符号を反転する。
	var sign_dir: float = -1.0 if pulling else 1.0
	var spray: float = _rule_float(rules, "spray_base", SPRAY_BASE) + sign_dir * magnitude
	if batting_side == 2:
		spray = -spray
	if batting_side == 3 and _throwing_hand(pitcher) == 2:
		spray = -spray

	# 乱数で方向を散らばらせ（ギャップ能力が高いほど抑制）、ギャップ狙い分だけ目標角へ寄せてクランプする。
	var noise_spread: float = _rule_float(rules, "spray_random_spread", SPRAY_RANDOM_SPREAD) + (_rule_float(rules, "spray_chase_random_boost", SPRAY_CHASE_RANDOM_BOOST) if chase else 0.0)
	noise_spread *= 1.0 - max(0.0, gap_curve) * _rule_float(rules, "spray_gap_noise_reduction", SPRAY_GAP_NOISE_REDUCTION)
	spray += _gaussian(noise_spread * variance_multiplier)
	var gap_alignment: float = max(0.0, gap_curve) * _rule_float(rules, "spray_gap_alignment_weight", SPRAY_GAP_ALIGNMENT_WEIGHT)
	if gap_alignment > 0.0:
		var spray_sign: float = -1.0 if spray < 0.0 else 1.0
		var aligned_abs: float = lerp(absf(spray), _rule_float(rules, "spray_gap_target_angle", SPRAY_GAP_TARGET_ANGLE), clamp(gap_alignment, 0.0, 0.45))
		spray = spray_sign * aligned_abs
	return clamp(spray, _rule_float(rules, "spray_min", SPRAY_MIN), _rule_float(rules, "spray_max", SPRAY_MAX))


# 投球が打者にとって内角かどうかを、コースの高さと投打の左右関係から判定する。
static func _is_inside_pitch(location_height: String, batting_side: int, pitcher: PSPlayerSeasonRecord) -> bool:
	if location_height == "high":
		return true
	if location_height == "low":
		return false
	var same_side: bool = _throwing_hand(pitcher) == batting_side or batting_side == 3
	return not same_side


# 打者の打席左右を数値化する（右=1 / 左=2 / スイッチ=3）。
static func _batting_side(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 1
	match record.batting_side:
		"L":
			return 2
		"S":
			return 3
	return 1


# 投手の利き腕を数値化する（右=1 / 左=2）。
static func _throwing_hand(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 1
	return 2 if record.throwing_hand == "L" else 1


# 一様乱数4つの和を中心化した擬似正規乱数を、指定の広がり(spread)で返す。
static func _gaussian(spread: float) -> float:
	if spread <= 0.0:
		return 0.0
	var total: float = 0.0
	for _i in range(4):
		total += Rng.roll_float()
	return (total - 2.0) * spread


# 値を指定した小数桁で四捨五入する。
static func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale


# 投打で対称であるべき重みの組を1本にまとめる。Mod がわずかに崩しても平均で受ける。
static func _symmetric_weight(batter_weight: float, pitcher_weight: float) -> float:
	return (batter_weight + pitcher_weight) * 0.5


static func _rule_float(rules: Dictionary, name: String, fallback: float) -> float:
	if rules.has(name):
		var value: Variant = rules[name]
		if value is int or value is float:
			return float(value)
		if value is String and str(value).is_valid_float():
			return float(value)
		return fallback
	if not rules.is_empty():
		return fallback
	return ModManager.rule_group_float(ModManager.RULE_GROUP_CONTACT_QUALITY, name, fallback)
