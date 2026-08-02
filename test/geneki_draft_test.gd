extends GdUnitTestSuite

# 現役ドラフト (GenekiDraftService) の回帰。
# ルール不変条件: 1巡目は各参加球団が必ず1人獲得・1人放出 (同一球団から2人指名されない)、
# 自球団選手は指名不可、金銭移動なし (年俸据え置き)。state は JSON-safe。

const SaveContext = preload("res://services/storage/save_context.gd")

const TEST_YEAR: int = 2026


func _make_player(id: int, team_id: int, position: int, salary: int, overrides: Dictionary = {}) -> PSPlayer:
	var source: Dictionary = {"fa_nissuu": 100}
	for key in (overrides.get("source_data", {}) as Dictionary).keys():
		source[key] = (overrides.get("source_data", {}) as Dictionary)[key]
	var role: String = "fielder"
	if position == 1:
		role = str(overrides.get("role", "starter"))
	var data: Dictionary = {
		"id": id,
		"name": "選手%d" % id,
		"team_id": team_id,
		"position": position,
		"role": role,
		"age": int(overrides.get("age", 25)),
		"years": int(overrides.get("years", 3)),
		"salary": salary,
		"z_abilities": {},
		"raw_abilities": {},
		"source_data": source,
	}
	if overrides.has("foreign_player"):
		data["foreign_player"] = bool(overrides["foreign_player"])
	if overrides.has("development_player"):
		data["development_player"] = bool(overrides["development_player"])
	return PSPlayer.from_dict(data)


# 12球団 (GameDb.teams) それぞれに投手4+野手8の適格ロスターを作る。
func _build_league_players() -> Array:
	var players: Array = []
	var next_id: int = 910000
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		for pos in [1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
			players.append(_make_player(next_id, team.id, int(pos), 2500))
			next_id += 1
	return players


func _make_season() -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = TEST_YEAR
	return season


func _assert_json_safe(value: Variant, path: String = "state") -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for key in (value as Dictionary).keys():
				_assert_json_safe((value as Dictionary)[key], "%s.%s" % [path, str(key)])
		TYPE_ARRAY:
			for i in range((value as Array).size()):
				_assert_json_safe((value as Array)[i], "%s[%d]" % [path, i])
		TYPE_OBJECT:
			assert_bool(false).override_failure_message("state に Object が混入: %s" % path).is_true()
		_:
			pass


func test_is_eligible_rules() -> void:
	var base: PSPlayer = _make_player(900001, 1, 3, 2500)
	assert_bool(GenekiDraftService.is_eligible(base, TEST_YEAR)).is_true()

	var foreign: PSPlayer = _make_player(900002, 1, 3, 2500, {"foreign_player": true})
	assert_bool(GenekiDraftService.is_eligible(foreign, TEST_YEAR)).is_false()

	var dev: PSPlayer = _make_player(900003, 1, 3, 2500, {"development_player": true})
	assert_bool(GenekiDraftService.is_eligible(dev, TEST_YEAR)).is_false()

	# 年俸: 5000万未満は通常対象、5000万〜1億未満は例外枠として適格、1億以上は不可。
	var mid_salary: PSPlayer = _make_player(900004, 1, 3, 6000)
	assert_bool(GenekiDraftService.is_eligible(mid_salary, TEST_YEAR)).is_true()
	var high_salary: PSPlayer = _make_player(900005, 1, 3, 12000)
	assert_bool(GenekiDraftService.is_eligible(high_salary, TEST_YEAR)).is_false()

	# 複数年契約: 契約最終年のオフ (end==year) は満了扱いで対象、翌年以降まで残る契約は対象外。
	var locked: PSPlayer = _make_player(900006, 1, 3, 2500, {"source_data": {"contract_end_year": TEST_YEAR + 1}})
	assert_bool(GenekiDraftService.is_eligible(locked, TEST_YEAR)).is_false()
	var expiring: PSPlayer = _make_player(900007, 1, 3, 2500, {"source_data": {"contract_end_year": TEST_YEAR}})
	assert_bool(GenekiDraftService.is_eligible(expiring, TEST_YEAR)).is_true()

	# FA権保有者 / FA権行使経験者は対象外。
	var fa_holder: PSPlayer = _make_player(900008, 1, 3, 2500, {"source_data": {"fa_nissuu": 99999}})
	assert_bool(GenekiDraftService.is_eligible(fa_holder, TEST_YEAR)).is_false()
	var fa_used: PSPlayer = _make_player(900009, 1, 3, 2500, {"source_data": {"fa_signed_year": TEST_YEAR - 3}})
	assert_bool(GenekiDraftService.is_eligible(fa_used, TEST_YEAR)).is_false()

	# 当年ドラフト入団の新人・当年トレード獲得選手は対象外。
	var rookie: PSPlayer = _make_player(900010, 1, 3, 2500, {"source_data": {"rookie_year": true, "draft_year": TEST_YEAR}})
	assert_bool(GenekiDraftService.is_eligible(rookie, TEST_YEAR)).is_false()
	# 初期シードが持ち込む未来年 draft_year + 生涯 rookie_year=true の在籍中堅は対象
	# (>= 比較で全球団対象者ゼロになった 2026-07-20 の回帰)。
	var seed_veteran: PSPlayer = _make_player(900013, 1, 3, 2500, {"years": 5, "source_data": {"rookie_year": true, "draft_year": TEST_YEAR + 18}})
	assert_bool(GenekiDraftService.is_eligible(seed_veteran, TEST_YEAR)).is_true()
	# 今オフ入団 (在籍0年) の rookie_year 持ちは draft_year が欠けていても新人扱い。
	var fresh_rookie: PSPlayer = _make_player(900014, 1, 3, 2500, {"years": 0, "source_data": {"rookie_year": true}})
	assert_bool(GenekiDraftService.is_eligible(fresh_rookie, TEST_YEAR)).is_false()
	var traded: PSPlayer = _make_player(900011, 1, 3, 2500, {"source_data": {"traded_year": TEST_YEAR}})
	assert_bool(GenekiDraftService.is_eligible(traded, TEST_YEAR)).is_false()
	var traded_old: PSPlayer = _make_player(900012, 1, 3, 2500, {"source_data": {"traded_year": TEST_YEAR - 1}})
	assert_bool(GenekiDraftService.is_eligible(traded_old, TEST_YEAR)).is_true()


func test_all_cpu_resolution_each_team_gains_one_and_loses_one_in_round1() -> void:
	var players: Array = _build_league_players()
	var season: PSSeason = _make_season()
	var state: Dictionary = GenekiDraftService.create_geneki_draft_state(players, GameDb.teams, season, 0)

	assert_bool(bool(state.get("complete", false))).is_true()
	_assert_json_safe(state)

	var participants: Array = []
	for team_key in (state.get("team_lists", {}) as Dictionary).keys():
		if not ((state.get("team_lists", {}) as Dictionary)[team_key] as Array).is_empty():
			participants.append(int(str(team_key)))
	assert_int(participants.size()).is_equal(GameDb.teams.size())

	# 各球団のリストは2人以上・全員が年俸1億未満・例外枠 (5000万以上) は1人まで。
	for team_key in (state.get("team_lists", {}) as Dictionary).keys():
		var entries: Array = (state.get("team_lists", {}) as Dictionary)[team_key] as Array
		assert_int(entries.size()).is_greater_equal(2)
		var exception_count: int = 0
		for entry_row in entries:
			var entry: Dictionary = entry_row as Dictionary
			assert_int(int(entry.get("salary", 0))).is_less(10000)
			if bool(entry.get("exception", false)):
				exception_count += 1
		assert_int(exception_count).is_less_equal(1)

	# 1巡目: 参加球団数と同数の指名があり、獲得も放出も各球団ちょうど1人
	# (= 同一球団から1巡目に2人指名されることはない)。自球団の選手は指名できない。
	var round1_picks: Array = []
	var picked_ids: Dictionary = {}
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		assert_int(int(pick.get("team_id", 0))).is_not_equal(int(pick.get("from_team_id", 0)))
		var pid: int = int(pick.get("player_id", 0))
		assert_bool(picked_ids.has(pid)).override_failure_message("同一選手が二重指名された id=%d" % pid).is_false()
		picked_ids[pid] = true
		if int(pick.get("round", 0)) == 1:
			round1_picks.append(pick)
	assert_int(round1_picks.size()).is_equal(participants.size())
	assert_int((state.get("picked_round1", {}) as Dictionary).size()).is_equal(participants.size())
	assert_int((state.get("lost_round1", {}) as Dictionary).size()).is_equal(participants.size())

	# 2巡目でも各球団の放出は1人まで (lost_round2 は球団キーなので構造上1人)。
	for team_key in (state.get("lost_round2", {}) as Dictionary).keys():
		assert_bool((state.get("lost_round1", {}) as Dictionary).has(team_key)).is_true()


func test_finalize_moves_players_without_money_and_is_idempotent() -> void:
	var players: Array = _build_league_players()
	var season: PSSeason = _make_season()
	var state: Dictionary = GenekiDraftService.create_geneki_draft_state(players, GameDb.teams, season, 0)
	assert_bool(bool(state.get("complete", false))).is_true()

	var salary_before: Dictionary = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		salary_before[player.id] = player.salary

	var result: Dictionary = GenekiDraftService.finalize_geneki_draft(state, players, GameDb.teams, season)
	var moves: Array = result.get("moves", []) as Array
	assert_int(moves.size()).is_equal((state.get("picks", []) as Array).size())
	for move_row in moves:
		var move: Dictionary = move_row as Dictionary
		var player: PSPlayer = null
		for player_row in players:
			if (player_row as PSPlayer).id == int(move.get("player_id", 0)):
				player = player_row as PSPlayer
				break
		assert_object(player).is_not_null()
		assert_int(player.team_id).is_equal(int(move.get("to_team", 0)))
		assert_int(player.salary).is_equal(int(salary_before.get(player.id, -1)))
		assert_int(int(player.source_data.get("geneki_draft_year", 0))).is_equal(TEST_YEAR)
		var log_entries: Array = PSCareerLog.entries(player)
		assert_bool(log_entries.is_empty()).is_false()
		var last_entry: Dictionary = log_entries[log_entries.size() - 1] as Dictionary
		assert_str(str(last_entry.get("t", ""))).is_equal(PSCareerLog.TYPE_GENEKI_DRAFT)

	# 二重確定しても移籍は再適用されない (finalized ガード)。
	var second: Dictionary = GenekiDraftService.finalize_geneki_draft(state, players, GameDb.teams, season)
	assert_int((second.get("moves", []) as Array).size()).is_equal(moves.size())
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		var log_count: int = 0
		for entry_row in PSCareerLog.entries(player):
			if str((entry_row as Dictionary).get("t", "")) == PSCareerLog.TYPE_GENEKI_DRAFT:
				log_count += 1
		assert_int(log_count).is_less_equal(1)


func test_user_interactive_flow_completes() -> void:
	var players: Array = _build_league_players()
	var season: PSSeason = _make_season()
	var user_team_id: int = (GameDb.teams[0] as PSTeam).id
	var state: Dictionary = GenekiDraftService.create_geneki_draft_state(players, GameDb.teams, season, user_team_id)

	assert_bool(bool(state.get("waiting_user", false))).is_true()
	assert_str(str(state.get("phase", ""))).is_equal("submit")

	# 1人だけのリストは規定人数不足で却下される。
	var eligible_ids: Array = state.get("user_eligible_ids", []) as Array
	var short_result: Dictionary = GenekiDraftService.submit_user_list(state, players, GameDb.teams, season, [eligible_ids[0]])
	assert_bool(bool(short_result.get("ok", true))).is_false()

	# 推奨リストで提出 → 進行はユーザー手番か完了まで進む。
	var submit_result: Dictionary = GenekiDraftService.auto_submit_user_list(state, players, GameDb.teams, season)
	assert_bool(bool(submit_result.get("ok", false))).is_true()
	state = submit_result.get("state", state) as Dictionary

	var guard: int = 0
	while not bool(state.get("complete", false)) and guard < 20:
		guard += 1
		assert_bool(bool(state.get("waiting_user", false))).is_true()
		var phase: String = str(state.get("phase", ""))
		if phase == "round1":
			# 自球団の選手は指名できない。
			var own_pick: Dictionary = GenekiDraftService.submit_user_pick(state, players, GameDb.teams, season, int(eligible_ids[0]))
			assert_bool(bool(own_pick.get("ok", true))).is_false()
			var targets: Array = GenekiDraftService.round1_targets(state, user_team_id)
			assert_bool(targets.is_empty()).is_false()
			var pick_result: Dictionary = GenekiDraftService.submit_user_pick(state, players, GameDb.teams, season, int((targets[0] as Dictionary).get("player_id", 0)))
			assert_bool(bool(pick_result.get("ok", false))).is_true()
			state = pick_result.get("state", state) as Dictionary
		elif phase == "round2_entry":
			var mode_result: Dictionary = GenekiDraftService.set_user_round2_mode(state, players, GameDb.teams, season, GenekiDraftService.ROUND2_MODE_OFFER_ONLY)
			assert_bool(bool(mode_result.get("ok", false))).is_true()
			state = mode_result.get("state", state) as Dictionary
		elif phase == "round2":
			var pass_result: Dictionary = GenekiDraftService.pass_user_pick(state, players, GameDb.teams, season)
			assert_bool(bool(pass_result.get("ok", false))).is_true()
			state = pass_result.get("state", state) as Dictionary
		else:
			assert_bool(false).override_failure_message("想定外の待機フェーズ: %s" % phase).is_true()
	assert_bool(bool(state.get("complete", false))).is_true()
	# ユーザーも1巡目で必ず1人獲得・1人放出している。
	assert_bool((state.get("picked_round1", {}) as Dictionary).has(str(user_team_id))).is_true()
	assert_bool((state.get("lost_round1", {}) as Dictionary).has(str(user_team_id))).is_true()


# 実運用データの回帰: 初期シードCSV (GameDb.players) で全球団にリスト規定数以上の適格選手が
# いること。「全球団対象者ゼロ」(未来年 draft_year の巻き込み除外) の再発監視。
func test_initial_seed_world_every_team_has_eligible_players() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = SeasonService.DEFAULT_START_YEAR
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var eligible: Array = GenekiDraftService._eligible_entries_for_team(GameDb.players, team.id, season)
		assert_int(eligible.size()).override_failure_message(
			"球団 %s の現役ドラフト適格選手が %d 人しかいません" % [team.name, eligible.size()]
		).is_greater_equal(2)


# リスト選定は NPB実績どおり「能力はあるが出場機会に恵まれない中堅」を優先して晒す。
# 主力 (高出場) と主力級能力は保護、能力の低い選手より blocked talent を上位に置く。
func test_cpu_list_exposes_blocked_talent_over_regular_and_scrub() -> void:
	var eligible: Array = [
		_geneki_entry(1, 0.70, 0.1, 24),   # 役割内で上位・出場少・若い = blocked talent → 最有力
		_geneki_entry(2, 0.75, 0.9, 27),   # 主力 (出場率0.9) → 保護され晒されない
		_geneki_entry(3, 0.15, 0.1, 31),   # 役割内で下位 → appeal 低
		_geneki_entry(4, 0.65, 0.15, 25),  # 2番手の blocked talent
	]
	var selected: Array = GenekiDraftService._cpu_select_list(eligible)
	var ids: Dictionary = {}
	for entry_row in selected:
		ids[int((entry_row as Dictionary).get("player_id", 0))] = true
	assert_int(selected.size()).is_equal(GenekiDraftService.CPU_LIST_SIZE)
	assert_bool(ids.has(1)).override_failure_message("blocked talent が晒されていない").is_true()
	assert_bool(ids.has(4)).override_failure_message("2番手 blocked talent が晒されていない").is_true()
	assert_bool(ids.has(2)).override_failure_message("主力(高出場)を晒してはいけない").is_false()
	assert_bool(ids.has(3)).override_failure_message("能力の低い選手より talent を優先すべき").is_false()


# 回帰: 指名スコアにポジション需要を足していた頃は投手 need~0 のため自軍(=どの球団も)が毎回
# 野手を指名していた (実測 30ドラフトで自軍獲得 投手0/野手30)。need を外し、自軍も投手を普通に
# 指名する (=野手ばかりにならない) ことを保証する。GameDb.players は複製して共有状態を汚さない。
func test_user_team_picks_are_not_all_fielders() -> void:
	var team_id: int = (GameDb.teams[0] as PSTeam).id
	var season: PSSeason = _make_season()
	var user_pitchers: int = 0
	var user_total: int = 0
	for sv in range(10):
		Rng.set_seed_value(7000 + sv)
		var players: Array = []
		for row in GameDb.players:
			players.append(PSPlayer.from_dict((row as PSPlayer).to_dict()))
		var state: Dictionary = GenekiDraftService.create_geneki_draft_state(players, GameDb.teams, season, team_id)
		state = GenekiDraftService.complete_automatically(state, players, GameDb.teams, season).get("state", state)
		var result: Dictionary = GenekiDraftService.finalize_geneki_draft(state, players, GameDb.teams, season)
		for row in result.get("moves", []) as Array:
			var d: Dictionary = row as Dictionary
			if int(d.get("to_team", 0)) == team_id:
				user_total += 1
				if int(d.get("position", 0)) == 1:
					user_pitchers += 1
	assert_int(user_pitchers).override_failure_message(
		"自軍の現役ドラフト獲得が野手偏重 (10ドラフトで投手 %d / 総獲得 %d)" % [user_pitchers, user_total]
	).is_greater(0)


func _geneki_entry(id: int, role_pct: float, ratio: float, age: int) -> Dictionary:
	return {
		"player_id": id, "name": "P%d" % id, "from_team_id": 1,
		"salary": 3000, "exception": false,
		"age": age, "is_pitcher": true,
		"playing_time_ratio": ratio, "value": int(40.0 + role_pct * 60.0), "role_pct": role_pct,
	}


# AppState 配線の E2E: 戦力外獲得ステップ完了状態から advance すると現役ドラフトステップに入り、
# 対話パネルが開き、AI一任で完了して結果が保存され、次の FA ステップへ進める。
func test_appstate_advances_into_geneki_step_and_completes() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_active: bool = AppState.offseason_active
	var old_step: String = AppState.offseason_step
	var old_results: Dictionary = AppState.offseason_results.duplicate(true)
	var old_released_state: Dictionary = AppState.released_market_state.duplicate(true)
	var old_geneki_state: Dictionary = AppState.geneki_draft_state.duplicate(true)
	var old_fa_state: Dictionary = AppState.fa_state.duplicate(true)
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_RELEASED_MARKET
	AppState.released_market_state = {"complete": true, "finalized": true, "signings": [], "candidates": []}

	var adv: Dictionary = AppState.advance_offseason()
	assert_bool(bool(adv.get("ok", false))).is_true()
	assert_str(AppState.offseason_step).is_equal(AppState.OFFSEASON_STEP_GENEKI_DRAFT)
	var view: Dictionary = AppState.get_offseason_view_state()
	assert_str(str(view.get("active_panel", ""))).is_equal(AppState.OFFSEASON_PANEL_GENEKI_DRAFT)
	assert_bool(bool(view.get("is_interactive", false))).is_true()

	var auto_result: Dictionary = AppState.complete_geneki_draft_automatically()
	assert_bool(bool(auto_result.get("ok", false))).is_true()
	assert_bool(bool(AppState.geneki_draft_state.get("complete", false))).is_true()
	var stored: Dictionary = AppState.offseason_results.get(AppState.OFFSEASON_STEP_GENEKI_DRAFT, {}) as Dictionary
	assert_bool(stored.is_empty()).is_false()
	assert_str(str(stored.get("title", ""))).is_equal("現役ドラフト")

	# 現役ドラフトの次は契約更改 (年俸再査定)。FA市場はその後。
	var adv_renewal: Dictionary = AppState.advance_offseason()
	assert_bool(bool(adv_renewal.get("ok", false))).is_true()
	assert_str(AppState.offseason_step).is_equal(AppState.OFFSEASON_STEP_CONTRACT_RENEWAL)

	# 後始末 (startup_test の save cleanup パターン)。
	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	AppState.offseason_active = old_active
	AppState.offseason_step = old_step
	AppState.offseason_results = old_results
	AppState.released_market_state = old_released_state
	AppState.geneki_draft_state = old_geneki_state
	AppState.fa_state = old_fa_state
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_user_list_exception_salary_rules() -> void:
	var players: Array = []
	var teams: Array = GameDb.teams
	var user_team_id: int = (teams[0] as PSTeam).id
	var next_id: int = 920000
	# ユーザー球団: 5000万未満2人 + 例外枠 (5000万以上1億未満) 2人。
	var std1: int = next_id
	players.append(_make_player(next_id, user_team_id, 3, 2500)); next_id += 1
	var std2: int = next_id
	players.append(_make_player(next_id, user_team_id, 4, 3000)); next_id += 1
	var exc1: int = next_id
	players.append(_make_player(next_id, user_team_id, 5, 6000)); next_id += 1
	var exc2: int = next_id
	players.append(_make_player(next_id, user_team_id, 6, 7000)); next_id += 1
	for i in range(1, teams.size()):
		var team: PSTeam = teams[i] as PSTeam
		for pos in [1, 1, 2, 3, 7]:
			players.append(_make_player(next_id, team.id, int(pos), 2500))
			next_id += 1
	var season: PSSeason = _make_season()
	var state: Dictionary = GenekiDraftService.create_geneki_draft_state(players, teams, season, user_team_id)
	assert_str(str(state.get("phase", ""))).is_equal("submit")

	# 例外枠2人は不可。
	var two_exceptions: Dictionary = GenekiDraftService.submit_user_list(state, players, teams, season, [exc1, exc2])
	assert_bool(bool(two_exceptions.get("ok", true))).is_false()
	# 例外枠を含む2人リストは不可 (3人以上必要)。
	var short_with_exception: Dictionary = GenekiDraftService.submit_user_list(state, players, teams, season, [std1, exc1])
	assert_bool(bool(short_with_exception.get("ok", true))).is_false()
	# 5000万未満2人 + 例外枠1人 = 3人は可。
	var valid: Dictionary = GenekiDraftService.submit_user_list(state, players, teams, season, [std1, std2, exc1])
	assert_bool(bool(valid.get("ok", false))).is_true()
