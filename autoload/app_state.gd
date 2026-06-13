extends Node

signal screen_change_requested(screen_name: String)
signal selected_team_changed(team_id: int)
signal season_started(season: PSSeason)

const DraftService = preload("res://services/season/draft_service.gd")
const FaMarketService = preload("res://services/season/fa_market_service.gd")
const ForeignPlayerService = preload("res://services/season/foreign_player_service.gd")
const ReleasedMarketService = preload("res://services/season/released_market_service.gd")
const CAMP_SERVICE_PATH: String = "res://services/season/camp_service.gd"

var current_screen: String = "start"
var selected_team_id: int = 0
var current_season: PSSeason = null
var last_status_message: String = ""
var current_player_id: int = 0
var offseason_step: int = 0
var offseason_results: Dictionary = {}
var draft_state: Dictionary = {}
var released_market_state: Dictionary = {}
var fa_state: Dictionary = {}
var foreign_state: Dictionary = {}
var camp_state: Dictionary = {}
var offseason_active: bool = false
var postseason_active: bool = false
var current_postseason: PSPostseasonResult = null
var current_awards: PSAwards = null
# 通常プレイ中に自軍も成績ベースの自動入替を行うか。active_roster_screenから操作。
var auto_roster_swap_for_user_team: bool = false
# スキップ操作中に自軍も成績ベースの自動入替を行うか。skip_options_screenから操作。
var auto_roster_swap_during_skip: bool = true
# 自動セーブを有効にするか。デフォルトは false (手動セーブのみ)。
var auto_save_enabled: bool = false
var league_dh_enabled: Dictionary = {
	"central": true,
	"pacific": true,
}


func _camp_service() -> GDScript:
	return load(CAMP_SERVICE_PATH) as GDScript


# 自動セーブが有効なときだけ SaveService.save_state を呼ぶラッパー。
func _save_if_enabled() -> void:
	if auto_save_enabled:
		SaveService.save_state(self)


func show_player_detail(player_id: int) -> void:
	current_player_id = player_id
	request_screen("player_detail")


func request_screen(screen_name: String) -> void:
	current_screen = screen_name
	screen_change_requested.emit(screen_name)


func select_team(team_id: int) -> void:
	selected_team_id = team_id
	selected_team_changed.emit(team_id)


func is_dh_enabled_for_league(league: String) -> bool:
	return bool(league_dh_enabled.get(_normalize_league_key(league), true))


func set_dh_enabled_for_league(league: String, enabled: bool) -> void:
	var league_key: String = _normalize_league_key(league)
	league_dh_enabled[league_key] = enabled
	_apply_dh_settings_to_current_schedule()
	_save_if_enabled()


func dh_settings_for_schedule() -> Dictionary:
	return {
		"central": bool(league_dh_enabled.get("central", true)),
		"pacific": bool(league_dh_enabled.get("pacific", true)),
	}


func start_new_season() -> bool:
	if selected_team_id <= 0:
		push_warning("Cannot start a season without a selected team.")
		return false

	current_season = SeasonService.create_new_season(GameDb.teams, selected_team_id, SeasonService.DEFAULT_START_YEAR, dh_settings_for_schedule())
	RecordStore.clear_records()
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	# 新シーズンは現在のロースター/能力でスタメン・打順を選び直すため、テンプレキャッシュをリセット。
	PSDefenseAlignmentProfile.reset_cache()
	PSBattingOrderProfile.reset_cache()
	last_status_message = ""
	draft_state = {}
	released_market_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	request_screen("home")
	season_started.emit(current_season)
	return true


func start_next_season() -> bool:
	if current_season == null:
		push_warning("Cannot advance without a current season.")
		return false

	GameDb.advance_players_one_year()
	current_season = SeasonService.create_next_season(current_season, GameDb.teams, dh_settings_for_schedule())
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	# 新シーズンは現在のロースター/能力でスタメン・打順を選び直すため、テンプレキャッシュをリセット。
	PSDefenseAlignmentProfile.reset_cache()
	PSBattingOrderProfile.reset_cache()
	last_status_message = ""
	offseason_step = 0
	offseason_results = {}
	draft_state = {}
	released_market_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	offseason_active = false
	postseason_active = false
	current_postseason = null
	current_awards = null
	request_screen("home")
	season_started.emit(current_season)
	return true


func start_postseason() -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not current_season.is_finished():
		return {"ok": false, "message": "シーズンがまだ完了していません(残り%d試合)" % current_season.games_remaining()}
	if current_postseason != null and PostseasonService.is_complete(current_postseason):
		return {"ok": false, "message": "ポストシーズンは既に完了しています"}
	if current_postseason == null:
		current_postseason = PostseasonService.build_initial_state(current_season, GameDb.teams)
	# 表彰はレギュラーシーズン成績で計算するため、ポストシーズン開始時にスナップショットする。
	if current_awards == null:
		current_awards = AwardsService.calculate(current_season, GameDb.teams)
	postseason_active = true
	_save_if_enabled()
	request_screen("postseason")
	return {"ok": true}


func advance_postseason_stage(stage_key: String) -> Dictionary:
	if current_season == null or current_postseason == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	var result: Dictionary = PostseasonService.advance_stage(current_postseason, stage_key, current_season)
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func advance_next_postseason_stage() -> Dictionary:
	if current_postseason == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	var stage_key: String = current_postseason.next_pending_stage()
	if stage_key.is_empty():
		return {"ok": false, "message": "すべてのシリーズが消化済みです"}
	return advance_postseason_stage(stage_key)


func finalize_postseason_to_awards() -> Dictionary:
	if current_postseason == null or not PostseasonService.is_complete(current_postseason):
		return {"ok": false, "message": "日本シリーズが未終了です"}
	if current_awards == null:
		current_awards = AwardsService.calculate(current_season, GameDb.teams)
	# 履歴アーカイブを追加
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.year = current_season.year
	archive.season_number = current_season.season_number
	archive.standings = _snapshot_standings(current_season)
	archive.postseason = current_postseason
	archive.awards = current_awards
	if not _archive_exists(archive.year, archive.season_number):
		RecordStore.add_season_archive(archive)
	_save_if_enabled()
	request_screen("awards")
	return {"ok": true}


func _snapshot_standings(season: PSSeason) -> Dictionary:
	var out: Dictionary = {}
	for team_id in season.standings.keys():
		var stats: PSStats = season.standings[team_id] as PSStats
		out[str(team_id)] = {
			"wins": stats.wins,
			"losses": stats.losses,
			"draws": stats.draws,
			"runs_scored": stats.runs_scored,
			"runs_allowed": stats.runs_allowed,
		}
	return out


func _archive_exists(year: int, season_number: int) -> bool:
	for archive_row in RecordStore.season_archives:
		var archive: PSSeasonArchive = archive_row as PSSeasonArchive
		if archive.year == year and archive.season_number == season_number:
			return true
	return false


func start_offseason() -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not current_season.is_finished():
		return {"ok": false, "message": "シーズンがまだ完了していません(残り%d試合)" % current_season.games_remaining()}
	if current_postseason != null and not PostseasonService.is_complete(current_postseason):
		return {"ok": false, "message": "先にポストシーズンを完了してください"}
	# 表彰未計算なら計算する。
	if current_awards == null:
		current_awards = AwardsService.calculate(current_season, GameDb.teams)
	postseason_active = false
	# Step 0: 引退判定を即時実行して結果を保存する。
	var retirement_result: Dictionary = OffseasonService.process_retirement(GameDb.players, current_season)
	retirement_result["title"] = "引退判定"
	offseason_step = 0
	offseason_results = {"step_0": retirement_result}
	draft_state = {}
	released_market_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	offseason_active = true
	last_status_message = str(retirement_result.get("title", ""))
	_save_if_enabled()
	# 年に一度の節目で、肥大化していれば DB ファイルを切り詰める (freelist 回収)。
	SaveService.compact_storage()
	request_screen("offseason")
	return {"ok": true}


func commit_release(player_ids: Array) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not offseason_active:
		return {"ok": false, "message": "オフシーズンが開始されていません"}
	if offseason_step != 1:
		return {"ok": false, "message": "戦力外通告は戦力外エディタ(step 1)でのみ確定できます"}

	# R4 Step3: CPU球団の外国人を別基準 (4枠 + 能力バー + 低稼働) で自動戦力外。
	# 自軍外国人は戦力外エディタの選択だけを尊重し、確定時に裏で追加解雇しない。
	var foreign_result: Dictionary = OffseasonService.process_foreign_releases(GameDb.players, GameDb.teams, current_season, selected_team_id)
	var user_result: Dictionary = OffseasonService.process_release(GameDb.players, selected_team_id, player_ids)
	var cpu_result: Dictionary = OffseasonService.process_cpu_releases(GameDb.players, GameDb.teams, selected_team_id, current_season)

	# 自軍と CPU 全球団を合算した結果を step_2 として保存する。
	var merged_released: Array = []
	merged_released.append_array(user_result.get("released", []) as Array)
	merged_released.append_array(cpu_result.get("released", []) as Array)
	merged_released.append_array(foreign_result.get("released", []) as Array)
	merged_released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)

	var step_result: Dictionary = {
		"released": merged_released,
		"released_count": merged_released.size(),
		"by_team": cpu_result.get("by_team", {}),
		"user_released_count": int(user_result.get("released_count", 0)),
		"cpu_released_count": int(cpu_result.get("released_count", 0)),
		"foreign_released_count": int(foreign_result.get("released_count", 0)),
	}
	step_result["title"] = "戦力外通告"
	offseason_step = 2
	offseason_results["step_2"] = step_result
	GameDb.rebuild_player_indices()
	last_status_message = str(step_result.get("title", ""))
	_save_if_enabled()
	return {"ok": true, "step": 2, "result": step_result}


func advance_offseason() -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not offseason_active:
		return {"ok": false, "message": "オフシーズンが開始されていません"}
	if offseason_step == 1:
		return {"ok": false, "message": "先に戦力外通告を確定してください"}
	if offseason_step == 3 and not _is_draft_complete():
		return {"ok": false, "message": "ドラフトが進行中です。先に完了してください"}
	if offseason_step == 4 and not _is_released_market_complete():
		return {"ok": false, "message": "戦力外獲得市場が進行中です。先に完了してください"}
	if offseason_step == 5 and not _is_fa_complete():
		return {"ok": false, "message": "FA市場が進行中です。先に完了してください"}
	if offseason_step == 6 and not _is_foreign_complete():
		return {"ok": false, "message": "外国人補強が進行中です。先に完了してください"}
	if offseason_step == 7 and not _is_camp_complete():
		return {"ok": false, "message": "キャンプが進行中です。先に完了してください"}
	if offseason_step >= 9:
		return {"ok": false, "message": "オフシーズン処理は完了しています。「翌年開始」で次シーズンへ進んでください"}

	var next_step: int = offseason_step + 1
	var step_result: Dictionary = {}
	var has_result_to_store: bool = true

	match next_step:
		1:
			# 引退結果 (step 0) から戦力外エディタ (step 1) へのナビゲートのみ。
			# step 1 は editor 表示なので結果データは持たない。
			has_result_to_store = false
		3:
			# R4/R5 調整: 戦力外 → ドラフト → 戦力外獲得 → FA → 外国人 → 成長 の順。
			# ドラフトを先に行い、残り枠を戦力外獲得・FA・外国人へ回す。
			draft_state = DraftService.create_draft_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_draft_complete():
				step_result = _finalize_draft_if_complete()
			else:
				step_result = {"title": "ドラフト", "draft_in_progress": true}
		4:
			released_market_state = ReleasedMarketService.create_released_market_state(
				GameDb.players,
				GameDb.teams,
				current_season,
				offseason_results.get("step_2", {}) as Dictionary,
				selected_team_id
			)
			if _is_released_market_complete():
				step_result = _finalize_released_market_if_complete()
			else:
				step_result = {"title": "戦力外獲得", "released_market_in_progress": true}
		5:
			fa_state = FaMarketService.create_fa_market_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_fa_complete():
				step_result = _finalize_fa_if_complete()
			else:
				step_result = {"title": "FA市場", "fa_in_progress": true}
				GameDb.rebuild_player_indices()
		6:
			foreign_state = ForeignPlayerService.create_foreign_market_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_foreign_complete():
				step_result = _finalize_foreign_if_complete()
			else:
				step_result = {"title": "外国人補強", "foreign_in_progress": true}
		7:
			camp_state = _camp_service().create_camp_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_camp_complete():
				step_result = _finalize_camp_if_complete()
			else:
				step_result = {"title": "キャンプ", "camp_in_progress": true}
		8:
			step_result = OffseasonService.process_growth_decay(GameDb.players, selected_team_id, current_season)
			step_result["title"] = "成長 / 衰え"
		9:
			step_result = OffseasonService.process_contract_update(GameDb.players, GameDb.teams, current_season)
			step_result["title"] = "契約更新"
		_:
			return {"ok": false, "message": "不正なステップ番号"}

	offseason_step = next_step
	if has_result_to_store:
		offseason_results["step_%d" % next_step] = step_result
		last_status_message = str(step_result.get("title", ""))
	else:
		last_status_message = "戦力外通告"
	_save_if_enabled()
	return {"ok": true, "step": next_step, "result": step_result}


func submit_draft_candidate(candidate_id: int) -> Dictionary:
	if not offseason_active or offseason_step != 3:
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.submit_user_candidate(draft_state, candidate_id)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_draft_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func auto_draft_user_pick() -> Dictionary:
	if not offseason_active or offseason_step != 3:
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.auto_pick_for_user(draft_state)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_draft_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func complete_draft_automatically() -> Dictionary:
	if not offseason_active or offseason_step != 3:
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.complete_automatically(draft_state)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_draft_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func _is_draft_complete() -> bool:
	return not draft_state.is_empty() and bool(draft_state.get("complete", false))


func _finalize_draft_if_complete() -> Dictionary:
	if not _is_draft_complete():
		return {"title": "ドラフト", "draft_in_progress": true}
	var result: Dictionary = DraftService.finalize_draft(draft_state, GameDb.players)
	GameDb.rebuild_player_indices()
	result["title"] = "ドラフト"
	offseason_results["step_3"] = result
	last_status_message = "ドラフト"
	return result


func submit_released_candidate(candidate_id: int) -> Dictionary:
	return _submit_released_decision(candidate_id, "sign")


func skip_released_candidate(candidate_id: int) -> Dictionary:
	return _submit_released_decision(candidate_id, "skip")


func _submit_released_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != 4:
		return {"ok": false, "message": "戦力外獲得市場は現在有効ではありません"}
	if released_market_state.is_empty():
		return {"ok": false, "message": "戦力外獲得市場が初期化されていません"}
	var result: Dictionary = ReleasedMarketService.submit_user_released_decision(
		released_market_state,
		GameDb.players,
		GameDb.teams,
		current_season,
		candidate_id,
		action
	)
	released_market_state = result.get("state", released_market_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_released_market_complete():
		_finalize_released_market_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": released_market_state}


func auto_released_user_pick() -> Dictionary:
	if not offseason_active or offseason_step != 4:
		return {"ok": false, "message": "戦力外獲得市場は現在有効ではありません"}
	if released_market_state.is_empty():
		return {"ok": false, "message": "戦力外獲得市場が初期化されていません"}
	var result: Dictionary = ReleasedMarketService.auto_pick_for_user(released_market_state, GameDb.players, GameDb.teams, current_season)
	released_market_state = result.get("state", released_market_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_released_market_complete():
		_finalize_released_market_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": released_market_state}


func complete_released_market_automatically() -> Dictionary:
	if not offseason_active or offseason_step != 4:
		return {"ok": false, "message": "戦力外獲得市場は現在有効ではありません"}
	if released_market_state.is_empty():
		return {"ok": false, "message": "戦力外獲得市場が初期化されていません"}
	var result: Dictionary = ReleasedMarketService.complete_released_market_automatically(
		released_market_state,
		GameDb.players,
		GameDb.teams,
		current_season,
		selected_team_id
	)
	released_market_state = result.get("state", released_market_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_released_market_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": released_market_state}


func _is_released_market_complete() -> bool:
	return not released_market_state.is_empty() and bool(released_market_state.get("complete", false))


func _finalize_released_market_if_complete() -> Dictionary:
	if not _is_released_market_complete():
		return {"title": "戦力外獲得", "released_market_in_progress": true}
	var result: Dictionary = ReleasedMarketService.finalize_released_market(released_market_state)
	GameDb.rebuild_player_indices()
	result["title"] = "戦力外獲得"
	offseason_results["step_4"] = result
	last_status_message = "戦力外獲得"
	return result


func submit_fa_candidate(candidate_id: int) -> Dictionary:
	return _submit_fa_decision(candidate_id, "sign")


func skip_fa_candidate(candidate_id: int) -> Dictionary:
	return _submit_fa_decision(candidate_id, "skip")


func _submit_fa_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != 5:
		return {"ok": false, "message": "FA市場は現在有効ではありません"}
	if fa_state.is_empty():
		return {"ok": false, "message": "FA市場が初期化されていません"}
	var result: Dictionary = FaMarketService.submit_user_fa_decision(fa_state, GameDb.players, GameDb.teams, current_season, candidate_id, action)
	fa_state = result.get("state", fa_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_fa_complete():
		_finalize_fa_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": fa_state}


func auto_fa_user_pick() -> Dictionary:
	if not offseason_active or offseason_step != 5:
		return {"ok": false, "message": "FA市場は現在有効ではありません"}
	if fa_state.is_empty():
		return {"ok": false, "message": "FA市場が初期化されていません"}
	var result: Dictionary = FaMarketService.auto_pick_for_user(fa_state, GameDb.players, GameDb.teams, current_season)
	fa_state = result.get("state", fa_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_fa_complete():
		_finalize_fa_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": fa_state}


func complete_fa_automatically() -> Dictionary:
	if not offseason_active or offseason_step != 5:
		return {"ok": false, "message": "FA市場は現在有効ではありません"}
	if fa_state.is_empty():
		return {"ok": false, "message": "FA市場が初期化されていません"}
	var result: Dictionary = FaMarketService.complete_fa_market_automatically(fa_state, GameDb.players, GameDb.teams, current_season, selected_team_id)
	fa_state = result.get("state", fa_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_fa_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": fa_state}


func _is_fa_complete() -> bool:
	return not fa_state.is_empty() and bool(fa_state.get("complete", false))


func _finalize_fa_if_complete() -> Dictionary:
	if not _is_fa_complete():
		return {"title": "FA市場", "fa_in_progress": true}
	var result: Dictionary = FaMarketService.finalize_fa_market(fa_state, GameDb.players, current_season)
	GameDb.rebuild_player_indices()
	result["title"] = "FA市場"
	offseason_results["step_5"] = result
	last_status_message = "FA市場"
	return result


func submit_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "sign")


func skip_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "skip")


func _submit_foreign_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != 6:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.submit_user_foreign_decision(foreign_state, GameDb.players, GameDb.teams, current_season, candidate_id, action)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_foreign_complete():
		_finalize_foreign_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


func auto_foreign_user_pick() -> Dictionary:
	if not offseason_active or offseason_step != 6:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.auto_pick_for_user(foreign_state, GameDb.players, GameDb.teams, current_season)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_foreign_complete():
		_finalize_foreign_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


func complete_foreign_automatically() -> Dictionary:
	if not offseason_active or offseason_step != 6:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.complete_foreign_market_automatically(foreign_state, GameDb.players, GameDb.teams, current_season, selected_team_id)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_foreign_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


func _is_foreign_complete() -> bool:
	return not foreign_state.is_empty() and bool(foreign_state.get("complete", false))


func _finalize_foreign_if_complete() -> Dictionary:
	if not _is_foreign_complete():
		return {"title": "外国人補強", "foreign_in_progress": true}
	var result: Dictionary = ForeignPlayerService.finalize_foreign_market(foreign_state)
	GameDb.rebuild_player_indices()
	result["title"] = "外国人補強"
	offseason_results["step_6"] = result
	last_status_message = "外国人補強"
	return result


func submit_camp_candidate(candidate_id: int) -> Dictionary:
	return _submit_camp_decision(candidate_id, "train")


func skip_camp_candidate(candidate_id: int) -> Dictionary:
	return _submit_camp_decision(candidate_id, "skip")


func _submit_camp_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != 7:
		return {"ok": false, "message": "キャンプは現在有効ではありません"}
	if camp_state.is_empty():
		return {"ok": false, "message": "キャンプが初期化されていません"}
	var result: Dictionary = _camp_service().submit_user_camp_action(camp_state, GameDb.players, GameDb.teams, current_season, candidate_id, action)
	camp_state = result.get("state", camp_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_camp_complete():
		_finalize_camp_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": camp_state}


func auto_camp_user_pick() -> Dictionary:
	if not offseason_active or offseason_step != 7:
		return {"ok": false, "message": "キャンプは現在有効ではありません"}
	if camp_state.is_empty():
		return {"ok": false, "message": "キャンプが初期化されていません"}
	var result: Dictionary = _camp_service().auto_pick_for_user(camp_state, GameDb.players, GameDb.teams, current_season)
	camp_state = result.get("state", camp_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_camp_complete():
		_finalize_camp_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": camp_state}


func finish_camp() -> Dictionary:
	if not offseason_active or offseason_step != 7:
		return {"ok": false, "message": "キャンプは現在有効ではありません"}
	if camp_state.is_empty():
		return {"ok": false, "message": "キャンプが初期化されていません"}
	var result: Dictionary = _camp_service().finish_user_camp(camp_state, GameDb.players, GameDb.teams, current_season)
	camp_state = result.get("state", camp_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_camp_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": camp_state}


func _is_camp_complete() -> bool:
	return not camp_state.is_empty() and bool(camp_state.get("complete", false))


func _finalize_camp_if_complete() -> Dictionary:
	if not _is_camp_complete():
		return {"title": "キャンプ", "camp_in_progress": true}
	var result: Dictionary = _camp_service().finalize_camp(camp_state, GameDb.players, current_season)
	GameDb.rebuild_player_indices()
	result["title"] = "キャンプ"
	offseason_results["step_7"] = result
	last_status_message = "キャンプ"
	return result


func finalize_offseason() -> bool:
	if offseason_step < 9:
		push_warning("Offseason not fully processed before finalize")
	return start_next_season()


func simulate_next_game(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = GameSimulator.simulate_next_unplayed_game(current_season, true, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_current_day(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = GameSimulator.simulate_current_day(current_season, true, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_remaining_season(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = GameSimulator.simulate_remaining_season(current_season, true, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_days(days: int, during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = GameSimulator.simulate_days(current_season, days, true, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func simulate_until_team_game(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if selected_team_id <= 0:
		return {"ok": false, "message": "自軍が選択されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = GameSimulator.simulate_until_team_game(current_season, selected_team_id, true, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# --- async 版 (UI フリーズ対策) ---
# tree / progress_cb / cancel_token を渡して、GameSimulator の async 版を await する。
# 同期版のラッパーと同じ事前条件チェックを行い、結果も message などの形式を揃える。

func simulate_current_day_async(
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	during_skip: bool = false
) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = await GameSimulator.simulate_current_day_async(
		current_season, true, _build_auto_swap_ctx(during_skip),
		tree, progress_cb, cancel_token
	)
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	# キャンセル時はユーザを現画面に留め、途中経過を確認できるようにする
	if not bool(result.get("cancelled", false)):
		request_screen("home")
	return result


func simulate_remaining_season_async(
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	during_skip: bool = false
) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = await GameSimulator.simulate_remaining_season_async(
		current_season, true, _build_auto_swap_ctx(during_skip),
		tree, progress_cb, cancel_token
	)
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	if not bool(result.get("cancelled", false)):
		request_screen("home")
	return result


func simulate_days_async(
	days: int,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	during_skip: bool = false
) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = await GameSimulator.simulate_days_async(
		current_season, days, true, _build_auto_swap_ctx(during_skip),
		tree, progress_cb, cancel_token
	)
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func simulate_until_team_game_async(
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	during_skip: bool = false
) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if selected_team_id <= 0:
		return {"ok": false, "message": "自軍が選択されていません"}

	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)
	var result: Dictionary = await GameSimulator.simulate_until_team_game_async(
		current_season, selected_team_id, true, _build_auto_swap_ctx(during_skip),
		tree, progress_cb, cancel_token
	)
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# GameSimulator に渡す自動入替コンテキストを構築する。
func _build_auto_swap_ctx(during_skip: bool) -> Dictionary:
	var include_user: bool = auto_roster_swap_during_skip if during_skip else auto_roster_swap_for_user_team
	return {
		"user_team_id": selected_team_id,
		"include_user_team": include_user,
	}


func _normalize_league_key(league: String) -> String:
	return "pacific" if league == "pacific" else "central"


func _apply_dh_settings_to_current_schedule() -> void:
	if current_season == null:
		return
	for game_value in current_season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		var home_team: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
		var league_key: String = "central" if home_team == null else _normalize_league_key(home_team.league)
		game["dh_enabled"] = is_dh_enabled_for_league(league_key)


func restore_from_save(data: Dictionary) -> bool:
	if data.is_empty():
		return false

	var player_rows: Array = data.get("players", []) as Array
	if not player_rows.is_empty():
		GameDb.replace_players_from_rows(player_rows)

	# R4 Step1: チーム予算 (funds) を復元。teams 本体は初期シードから再ロードされるため、
	# funds だけ id 一致で上書きする (キー欠落 = 旧セーブ は初期値のまま)。
	var saved_funds: Dictionary = data.get("team_funds", {}) as Dictionary
	for funds_key in saved_funds.keys():
		var team: PSTeam = GameDb.get_team(int(funds_key))
		if team != null:
			team.funds = int(saved_funds[funds_key])

	selected_team_id = int(data.get("selected_team_id", 0))
	offseason_step = int(data.get("offseason_step", 0))
	offseason_results = (data.get("offseason_results", {}) as Dictionary).duplicate(true)
	draft_state = (data.get("draft_state", {}) as Dictionary).duplicate(true)
	released_market_state = (data.get("released_market_state", {}) as Dictionary).duplicate(true)
	fa_state = (data.get("fa_state", {}) as Dictionary).duplicate(true)
	foreign_state = (data.get("foreign_state", {}) as Dictionary).duplicate(true)
	camp_state = (data.get("camp_state", {}) as Dictionary).duplicate(true)
	offseason_active = bool(data.get("offseason_active", false))
	postseason_active = bool(data.get("postseason_active", false))
	auto_roster_swap_for_user_team = bool(data.get("auto_roster_swap_for_user_team", false))
	auto_roster_swap_during_skip = bool(data.get("auto_roster_swap_during_skip", true))
	auto_save_enabled = bool(data.get("auto_save_enabled", false))
	var saved_dh_settings: Dictionary = data.get("league_dh_enabled", {}) as Dictionary
	league_dh_enabled = {
		"central": bool(saved_dh_settings.get("central", true)),
		"pacific": bool(saved_dh_settings.get("pacific", true)),
	}
	var post_data: Dictionary = data.get("current_postseason", {}) as Dictionary
	current_postseason = PSPostseasonResult.from_dict(post_data) if not post_data.is_empty() else null
	var awards_data: Dictionary = data.get("current_awards", {}) as Dictionary
	current_awards = PSAwards.from_dict(awards_data) if not awards_data.is_empty() else null
	var season_data: Dictionary = data.get("season", {}) as Dictionary
	current_season = PSSeason.from_dict(season_data) if not season_data.is_empty() else null
	_apply_dh_settings_to_current_schedule()
	# records は record_store blob / 正規化テーブルに独立永続化されている
	# (game_state には含めない)。専用ストアから hydrate する。
	RecordStore.load_records()
	if current_season != null:
		RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players)

	var next_screen: String = str(data.get("current_screen", "home"))
	last_status_message = ""
	if current_season != null:
		next_screen = "home"
	request_screen(next_screen)
	return true
