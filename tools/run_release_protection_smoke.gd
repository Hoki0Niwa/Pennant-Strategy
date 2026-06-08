extends Node

# 戦力外プロテクト (R4) のスモークテスト。
#  - 出場数プロテクト: 野手>=80 games / 先発>=8 starts / 中継ぎ>=15 relief は全フェーズで保護。
#  - 能力プロテクト: 高能力(総合>=70) かつ 累積怪我>=30日 のみ保護。怪我無しの高能力控えは非保護。
#  - 若手/伸びしろは切りにくく、未出場低評価の中堅は優先して候補化される。

const Offseason = preload("res://services/season/offseason_service.gd")


func _ready() -> void:
	Rng.set_seed_value(20260531)
	var ok: bool = true

	ok = _test_protection_helper() and ok
	ok = _test_phase2_sort() and ok
	ok = _test_compute_release_excludes_protected() and ok
	ok = _test_rookie_protection_requires_draft_entry() and ok
	ok = _test_midcareer_noshow_before_young_upside() and ok
	ok = _test_forced_retirement() and ok

	print("Release protection smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


# --- 単体: _is_protected_from_release ---
func _test_protection_helper() -> bool:
	var ok: bool = true

	# 野手 80 試合 → 保護
	var f_player: PSPlayer = _make_player(1, 31, 5, 5, 80)
	var f_rec: PSPlayerSeasonRecord = _record_for(f_player)
	f_rec.batter_stats.games = 80
	ok = _expect(Offseason._is_protected_from_release(f_player, f_rec), "fielder80 protected", ok)

	# 野手 79 試合 + 怪我無し + 低能力 → 非保護
	var f2_rec: PSPlayerSeasonRecord = _record_for(f_player)
	f2_rec.batter_stats.games = 79
	ok = _expect(not Offseason._is_protected_from_release(f_player, f2_rec), "fielder79 not protected", ok)

	# 能力下限: 総合30未満なら 143 試合フル出場でも非保護 (居座り防止)
	var scrub: PSPlayer = _make_player(10, 38, 5, 12, 8)
	var scrub_overall: int = Offseason.player_value_score(scrub)
	var scrub_rec: PSPlayerSeasonRecord = _record_for(scrub)
	scrub_rec.batter_stats.games = 143
	ok = _expect(scrub_overall < 30, "scrub overall < 30 (got %d)" % scrub_overall, ok)
	ok = _expect(not Offseason._is_protected_from_release(scrub, scrub_rec), "low-ability 143-game scrub not protected", ok)

	# 先発 8 登板 → 保護 / 7 登板 → 非保護
	var s_player: PSPlayer = _make_player(2, 31, 1, 5, 85)
	var s_rec: PSPlayerSeasonRecord = _record_for(s_player)
	s_rec.pitcher_stats.starts = 8
	ok = _expect(Offseason._is_protected_from_release(s_player, s_rec), "starter8 protected", ok)
	var s2_rec: PSPlayerSeasonRecord = _record_for(s_player)
	s2_rec.pitcher_stats.starts = 7
	ok = _expect(not Offseason._is_protected_from_release(s_player, s2_rec), "starter7 not protected", ok)

	# 中継ぎ 15 救援 (starts 0) → 保護 / 14 → 非保護
	var r_player: PSPlayer = _make_player(3, 31, 1, 5, 85)
	r_player.role = "reliever"
	var r_rec: PSPlayerSeasonRecord = _record_for(r_player)
	r_rec.role = "reliever"
	r_rec.pitcher_stats.starts = 0
	r_rec.pitcher_stats.relief_appearances = 15
	ok = _expect(Offseason._is_protected_from_release(r_player, r_rec), "reliever15 protected", ok)

	var r2_rec: PSPlayerSeasonRecord = _record_for(r_player)
	r2_rec.role = "reliever"
	r2_rec.pitcher_stats.starts = 0
	r2_rec.pitcher_stats.relief_appearances = 14
	ok = _expect(not Offseason._is_protected_from_release(r_player, r2_rec), "reliever14 not protected", ok)

	# 投手 26歳 登板ゼロ → no-show (Phase1 最優先カット対象)
	var ns_player: PSPlayer = _make_player(5, 26, 1, 5, 85)
	var ns_rec: PSPlayerSeasonRecord = _record_for(ns_player)
	ns_rec.pitcher_stats.games = 0
	ok = _expect(Offseason._is_pitcher_noshow(ns_player, ns_rec), "pitcher26 no-show", ok)
	# 25歳 登板ゼロ → no-show 対象外
	var ns25_player: PSPlayer = _make_player(6, 25, 1, 5, 85)
	var ns25_rec: PSPlayerSeasonRecord = _record_for(ns25_player)
	ns25_rec.pitcher_stats.games = 0
	ok = _expect(not Offseason._is_pitcher_noshow(ns25_player, ns25_rec), "pitcher25 not no-show", ok)
	# 26歳 1登板 → no-show 対象外
	var ns1_rec: PSPlayerSeasonRecord = _record_for(ns_player)
	ns1_rec.pitcher_stats.games = 1
	ok = _expect(not Offseason._is_pitcher_noshow(ns_player, ns1_rec), "pitcher26 with appearance not no-show", ok)

	# 高能力 + 怪我40日 + 低出場 → 保護
	var star_player: PSPlayer = _make_player(4, 29, 5, 5, 95)
	var star_overall: int = Offseason.player_value_score(star_player)
	var inj_rec: PSPlayerSeasonRecord = _record_for(star_player)
	inj_rec.batter_stats.games = 20
	inj_rec.season_injury_days = 40
	ok = _expect(star_overall >= 70, "injured star overall>=70 (got %d)" % star_overall, ok)
	ok = _expect(Offseason._is_protected_from_release(star_player, inj_rec), "injured star protected", ok)

	# 高能力 + 怪我無し + 低出場 → 非保護 (怪我ゲートのため)
	var healthy_rec: PSPlayerSeasonRecord = _record_for(star_player)
	healthy_rec.batter_stats.games = 20
	healthy_rec.season_injury_days = 0
	ok = _expect(not Offseason._is_protected_from_release(star_player, healthy_rec), "healthy bench star not protected", ok)

	return ok


# --- 単体: 段階的強制引退 ---
func _test_forced_retirement() -> bool:
	var ok: bool = true
	# 確率カーブ: 39以下=0, 48で1.0, 単調増加
	ok = _expect(is_equal_approx(Offseason._forced_retirement_chance(39), 0.0), "retire chance age39 = 0", ok)
	ok = _expect(Offseason._forced_retirement_chance(48) >= 1.0, "retire chance age48 = 1.0", ok)
	ok = _expect(Offseason._forced_retirement_chance(60) >= 1.0, "retire chance age60 = 1.0", ok)
	ok = _expect(Offseason._forced_retirement_chance(44) > Offseason._forced_retirement_chance(41), "retire chance increases with age", ok)

	# 48歳以上は出場数に関係なく確実に引退 (フル出場でも)
	var old_star: PSPlayer = _make_player(8001, 60, 5, 20, 90)
	var old_rec: PSPlayerSeasonRecord = _record_for(old_star)
	old_rec.batter_stats.games = 143
	ok = _expect(Offseason._should_retire(old_star, old_rec), "age60 full-season retires", ok)

	# 35歳フル出場は引退しない
	var prime: PSPlayer = _make_player(8002, 35, 5, 12, 85)
	var prime_rec: PSPlayerSeasonRecord = _record_for(prime)
	prime_rec.batter_stats.games = 143
	ok = _expect(not Offseason._should_retire(prime, prime_rec), "age35 full-season stays", ok)
	return ok


# --- 単体: Phase 2 ソート (zero_app desc, cut_score asc) ---
func _test_phase2_sort() -> bool:
	var ok: bool = true
	var lo: Dictionary = {"zero_app": false, "cut_score": 10.0}
	var hi: Dictionary = {"zero_app": false, "cut_score": 90.0}
	var zero: Dictionary = {"zero_app": true, "cut_score": 99.0}
	# 未出場が最優先で前 (= 先に切られる)
	ok = _expect(Offseason._phase2_sort_cmp(zero, hi), "zero_app before non-zero", ok)
	# 同 zero_app なら cut_score 低い方が前
	ok = _expect(Offseason._phase2_sort_cmp(lo, hi), "lower cut_score first", ok)
	ok = _expect(not Offseason._phase2_sort_cmp(hi, lo), "higher cut_score not first", ok)
	return ok


# --- 結合: compute_release_candidates_for_team が保護選手を切らない ---
func _test_compute_release_excludes_protected() -> bool:
	var ok: bool = true
	var team_id: int = 77
	var year: int = 2099
	var season_number: int = 1
	var season: PSSeason = PSSeason.new()
	season.year = year
	season.season_number = season_number

	var players: Array = []
	RecordStore.player_records.clear()

	# 保護対象 (5名): 出場数3種 + 怪我ありスター + ドラフト2年以内
	var protected_ids: Array = [9001, 9002, 9003, 9004, 9005]

	var pf: PSPlayer = _make_player(9001, 31, 5, 6, 70)      # 野手 100 試合
	var rf: PSPlayerSeasonRecord = _seed_record(pf, year, season_number)
	rf.batter_stats.games = 100
	players.append(pf)

	var ps: PSPlayer = _make_player(9002, 32, 1, 6, 85)      # 先発 20 登板
	ps.role = "starter"
	var rs: PSPlayerSeasonRecord = _seed_record(ps, year, season_number)
	rs.role = "starter"
	rs.pitcher_stats.starts = 20
	players.append(ps)

	var pr: PSPlayer = _make_player(9003, 33, 1, 6, 85)      # 中継ぎ 30 救援
	pr.role = "reliever"
	var rr: PSPlayerSeasonRecord = _seed_record(pr, year, season_number)
	rr.role = "reliever"
	rr.pitcher_stats.starts = 0
	rr.pitcher_stats.relief_appearances = 30
	players.append(pr)

	var pi: PSPlayer = _make_player(9004, 34, 4, 6, 95)      # 高能力 + 怪我40日 + 低出場
	var ri: PSPlayerSeasonRecord = _seed_record(pi, year, season_number)
	ri.batter_stats.games = 15
	ri.season_injury_days = 40
	players.append(pi)

	# ドラフト2年以内 (years=2): 低能力・少出場・年齢高でも切られないこと
	var pd: PSPlayer = _make_player(9005, 31, 5, 2, 35)
	var rd: PSPlayerSeasonRecord = _seed_record(pd, year, season_number)
	rd.batter_stats.games = 4
	players.append(pd)

	# 切られるべき fodder を 68名 → team 72名。
	# 年齢 28 (< Phase1 の 30) なので Phase1 では切られず、Phase2 が 60 まで削る。
	# (保護対象は age>=30 なので Phase1 で切られるはずだが、保護されてスキップされることを検証する)
	for i in range(68):
		var fp: PSPlayer = _make_player(10000 + i, 28, _filler_position(i), 6, 35)
		var fr: PSPlayerSeasonRecord = _seed_record(fp, year, season_number)
		fr.batter_stats.games = 5
		fr.pitcher_stats.starts = 0
		fr.pitcher_stats.relief_appearances = 0
		fr.season_injury_days = 0
		players.append(fp)

	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, team_id, season)

	# 保護選手が cut_ids に含まれないこと
	for pid in protected_ids:
		if cut_ids.has(pid):
			push_error("Protected player %d was released" % pid)
			ok = false

	# 実際にカットが発生し、60 まで削れていること (保護4名は残るので残数 >= 60)
	var remaining: int = players.size() - cut_ids.size()
	ok = _expect(cut_ids.size() > 0, "some players were cut (got %d)" % cut_ids.size(), ok)
	ok = _expect(remaining >= 60, "roster trimmed to >=60 (remaining=%d)" % remaining, ok)

	RecordStore.player_records.clear()
	return ok


# 2年以内保護はドラフト入団者だけ。FA/外国人/途中加入系にはかけない。
func _test_rookie_protection_requires_draft_entry() -> bool:
	var ok: bool = true
	var team_id: int = 77
	var year: int = 2101
	var season_number: int = 1
	var season: PSSeason = PSSeason.new()
	season.year = year
	season.season_number = season_number
	RecordStore.player_records.clear()

	var players: Array = []
	var draft_young: PSPlayer = _make_player(9401, 31, 6, 2, 35)
	draft_young.source_data["draft_year"] = year - 1
	draft_young.source_data["rookie_year"] = true
	var draft_rec: PSPlayerSeasonRecord = _seed_record(draft_young, year, season_number)
	draft_rec.batter_stats.games = 4
	players.append(draft_young)

	var fa_young: PSPlayer = _make_player(9402, 31, 7, 2, 35)
	fa_young.draft_round = 0
	fa_young.source_data = {"fa_signed_year": year - 1}
	var fa_rec: PSPlayerSeasonRecord = _seed_record(fa_young, year, season_number)
	fa_rec.batter_stats.games = 4
	players.append(fa_young)

	for i in range(59):
		var fp: PSPlayer = _make_player(9500 + i, 28, _filler_position(i), 6, 70)
		var fr: PSPlayerSeasonRecord = _seed_record(fp, year, season_number)
		fr.batter_stats.games = 100
		players.append(fp)

	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, team_id, season)
	ok = _expect(Offseason._has_rookie_release_protection(draft_young), "draft entrant has two-year protection", ok)
	ok = _expect(not Offseason._has_rookie_release_protection(fa_young), "non-draft young signing has no two-year protection", ok)
	ok = _expect(cut_ids.has(fa_young.id), "non-draft two-year player can be cut", ok)
	ok = _expect(not cut_ids.has(draft_young.id), "draft two-year player remains protected", ok)

	RecordStore.player_records.clear()
	return ok


# 61人ロスターから1人だけ削る状況で、出場なし中堅が若手より先に候補になる。
func _test_midcareer_noshow_before_young_upside() -> bool:
	var ok: bool = true
	var team_id: int = 77
	var year: int = 2100
	var season_number: int = 1
	var season: PSSeason = PSSeason.new()
	season.year = year
	season.season_number = season_number
	RecordStore.player_records.clear()

	var players: Array = []
	var mid: PSPlayer = _make_player(9201, 29, 5, 6, 44)
	var mid_rec: PSPlayerSeasonRecord = _seed_record(mid, year, season_number)
	mid_rec.batter_stats.games = 0
	players.append(mid)

	var young: PSPlayer = _make_player(9202, 23, 6, 6, 44)
	var young_rec: PSPlayerSeasonRecord = _seed_record(young, year, season_number)
	young_rec.batter_stats.games = 0
	players.append(young)

	# 周囲の59人は十分に稼働しており、1人だけ削るなら mid が候補になるはず。
	for i in range(59):
		var fp: PSPlayer = _make_player(9300 + i, 28, _filler_position(i), 6, 70)
		var fr: PSPlayerSeasonRecord = _seed_record(fp, year, season_number)
		fr.batter_stats.games = 100
		players.append(fp)

	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, team_id, season)
	ok = _expect(cut_ids.has(mid.id), "midcareer no-show is cut", ok)
	ok = _expect(not cut_ids.has(young.id), "young upside player is protected", ok)
	ok = _expect(cut_ids.size() == 1, "only one player cut from 61-man roster (got %d)" % cut_ids.size(), ok)

	RecordStore.player_records.clear()
	return ok


# --- helpers ---
func _filler_position(i: int) -> int:
	var positions: Array = [2, 3, 4, 5, 6, 7, 8, 9]
	return int(positions[i % positions.size()])


func _record_for(player: PSPlayer) -> PSPlayerSeasonRecord:
	return PSPlayerSeasonRecord.from_player(player, 2099, 1)


func _seed_record(player: PSPlayer, year: int, season_number: int) -> PSPlayerSeasonRecord:
	var rec: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, year, season_number)
	RecordStore.player_records["%d:%d:%d" % [player.id, year, season_number]] = rec
	return rec


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[release_protection] FAIL: %s" % label)
		return false
	return running_ok


func _make_player(player_id: int, age: int, position: int, years: int, center: int) -> PSPlayer:
	return PSPlayer.from_dict({
		"id": player_id,
		"sensyu_num": player_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": 77,
		"name": "Smoke%d" % player_id,
		"age": age,
		"years": years,
		"height": 180,
		"weight": 80,
		"position": position,
		"role": "starter" if position == 1 else "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 1000,
		"draft_round": 1,
		"hometown": "",
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"position_aptitudes": {Offseason.POSITION_NAME_BY_ID.get(position, "first"): 100},
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, center, min(center + 8, 99)),
		"fatigue": 0,
		"injury_days": 0,
	})
