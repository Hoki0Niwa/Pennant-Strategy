extends Node

signal screen_change_requested(screen_name: String)
signal selected_team_changed(team_id: int)
signal season_started(season: PSSeason)

const CAMP_SERVICE_PATH: String = "res://services/season/camp_service.gd"
const SeasonCalendar = preload("res://services/season/season_calendar.gd")
const OFFSEASON_STEP_RETIREMENT: int = 0
const OFFSEASON_STEP_RELEASE_EDIT: int = 1
const OFFSEASON_STEP_RELEASE_COMMIT: int = 2
const OFFSEASON_STEP_DRAFT_MAIN: int = 3
const OFFSEASON_STEP_DRAFT_DEVELOPMENT: int = 4
const OFFSEASON_STEP_RELEASED_MARKET: int = 5
const OFFSEASON_STEP_FA_MARKET: int = 6
const OFFSEASON_STEP_FOREIGN_MARKET: int = 7
const OFFSEASON_STEP_CAMP: int = 8
const OFFSEASON_STEP_GROWTH: int = 9
const OFFSEASON_STEP_CONTRACT_UPDATE: int = 10
const OFFSEASON_TOTAL_STEPS: int = OFFSEASON_STEP_CONTRACT_UPDATE

const OFFSEASON_PANEL_NONE: String = "none"
const OFFSEASON_PANEL_RESULTS: String = "results"
const OFFSEASON_PANEL_RELEASE: String = "release"
const OFFSEASON_PANEL_DRAFT: String = "draft"
const OFFSEASON_PANEL_RELEASED_MARKET: String = "released_market"
const OFFSEASON_PANEL_FA: String = "fa"
const OFFSEASON_PANEL_FOREIGN: String = "foreign"
const OFFSEASON_PANEL_CAMP: String = "camp"

var current_screen: String = "start"
# 「前に開いていた画面」に戻る/進むためのナビゲーション履歴スタック。
# 各要素は {"screen": String, "player_id": int} のスナップショット。
var _screen_history: Array = []  # 戻る用 (過去)
var _forward_history: Array = []  # 進む用 (go_back で退避した先)
var _navigating_history: bool = false
const MAX_SCREEN_HISTORY: int = 50
# 履歴に積まない画面 (フロー専用 / 戻る対象にすると壊れる画面)。
const NON_HISTORY_SCREENS: Dictionary = {
	"start": true,
	"team_select": true,
	"offseason": true,
	"postseason": true,
	"awards": true,
}
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
# スキップ操作中に自軍も成績ベースの自動入替を行うか。オプション画面から操作。
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
	# player_id を更新する前に現在画面を履歴へ積む (順序が重要)。
	_record_history_snapshot("player_detail")
	current_player_id = player_id
	request_screen("player_detail", false)


# 現在の画面状態を履歴スタックへ積む。連続重複・フロー専用画面・戻る/進む操作中は積まない。
func _record_history_snapshot(next_screen: String) -> void:
	if _navigating_history:
		return
	# 新規ナビゲーションなので「進む」履歴は無効化する (ブラウザと同様)。
	_forward_history.clear()
	if NON_HISTORY_SCREENS.has(current_screen):
		return
	if current_screen == next_screen and current_screen != "player_detail":
		return
	_screen_history.append({"screen": current_screen, "player_id": current_player_id})
	if _screen_history.size() > MAX_SCREEN_HISTORY:
		_screen_history.pop_front()


# 現在画面を退避スタックへ積んでから、別スタックから取り出した画面へ遷移する共通処理。
func _navigate_history(pop_stack: Array, push_stack: Array) -> bool:
	if pop_stack.is_empty():
		return false
	var snapshot: Dictionary = pop_stack.pop_back() as Dictionary
	push_stack.append({"screen": current_screen, "player_id": current_player_id})
	if push_stack.size() > MAX_SCREEN_HISTORY:
		push_stack.pop_front()
	_navigating_history = true
	current_player_id = int(snapshot.get("player_id", current_player_id))
	request_screen(str(snapshot.get("screen", "home")), false)
	_navigating_history = false
	return true


# マウスの戻るボタンなどから呼ぶ。直前に開いていた画面へ戻る。戻れたら true。
func go_back() -> bool:
	if _navigate_history(_screen_history, _forward_history):
		return true
	# 履歴が無い場合のフォールバック: シーズン開始前の画面 (タイトルから来た
	# オプション/チーム選択など) からはタイトルへ戻る。
	if current_season == null and current_screen != "start":
		request_screen("start", false)
		return true
	return false


# マウスの進むボタンなどから呼ぶ。go_back で戻る前の画面へ進む。進めたら true。
func go_forward() -> bool:
	return _navigate_history(_forward_history, _screen_history)


func request_screen(screen_name: String, record_history: bool = true) -> void:
	if record_history:
		_record_history_snapshot(screen_name)
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


func get_offseason_view_state() -> Dictionary:
	var step: int = offseason_step
	var active_panel: String = OFFSEASON_PANEL_RESULTS
	var title: String = ""
	var interactive: bool = false
	var result: Dictionary = {}

	if not offseason_active:
		return {
			"active": false,
			"step": step,
			"total_steps": OFFSEASON_TOTAL_STEPS,
			"phase": step,
			"title": "オフシーズン未開始",
			"status": "オフシーズンが開始されていません",
			"active_panel": OFFSEASON_PANEL_NONE,
			"is_interactive": false,
			"can_advance": false,
			"can_finalize": false,
			"result": {},
		}

	match step:
		OFFSEASON_STEP_RELEASE_EDIT:
			active_panel = OFFSEASON_PANEL_RELEASE
			title = "戦力外通告(編集)"
			interactive = true
		OFFSEASON_STEP_DRAFT_MAIN:
			if not draft_state.is_empty() and not bool(draft_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_DRAFT
				title = "本指名"
				interactive = true
		OFFSEASON_STEP_DRAFT_DEVELOPMENT:
			if not draft_state.is_empty() and not bool(draft_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_DRAFT
				title = "育成指名"
				interactive = true
		OFFSEASON_STEP_RELEASED_MARKET:
			if not released_market_state.is_empty() and not bool(released_market_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_RELEASED_MARKET
				title = "戦力外獲得"
				interactive = true
		OFFSEASON_STEP_FA_MARKET:
			if not fa_state.is_empty() and not bool(fa_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_FA
				title = "FA市場"
				interactive = true
		OFFSEASON_STEP_FOREIGN_MARKET:
			if not foreign_state.is_empty() and not bool(foreign_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_FOREIGN
				title = "外国人補強"
				interactive = true
		OFFSEASON_STEP_CAMP:
			if not camp_state.is_empty() and not bool(camp_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_CAMP
				title = "キャンプ"
				interactive = true

	if not interactive:
		var step_key: String = "step_%d" % step
		result = offseason_results.get(step_key, {}) as Dictionary
		title = str(result.get("title", "")) if not result.is_empty() else "結果データがありません"

	return {
		"active": true,
		"step": step,
		"total_steps": OFFSEASON_TOTAL_STEPS,
		"phase": step,
		"title": title,
		"status": title,
		"active_panel": active_panel,
		"is_interactive": interactive,
		"can_advance": (not interactive) and step < OFFSEASON_TOTAL_STEPS,
		"can_finalize": (not interactive) and step >= OFFSEASON_TOTAL_STEPS,
		"result": result,
	}


func start_new_season() -> bool:
	if selected_team_id <= 0:
		push_warning("Cannot start a season without a selected team.")
		return false

	if not SaveService.begin_new_game():
		push_warning("Could not create a new save folder.")
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
	_screen_history.clear()
	_forward_history.clear()
	request_screen("home")
	season_started.emit(current_season)
	SaveService.save_state(self)
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
	offseason_step = OFFSEASON_STEP_RETIREMENT
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
	_screen_history.clear()
	_forward_history.clear()
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
	# ポストシーズン中はホーム画面をポストシーズン用ダッシュボードへ差し替える (main.gd でルーティング)。
	request_screen("home")
	return {"ok": true}


# 1日進める: 進行中ステージグループ(第1/第2リーグ)の試合を同時に1試合ずつ消化する。
func advance_postseason_day() -> Dictionary:
	if current_season == null or current_postseason == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	var result: Dictionary = PostseasonService.advance_one_day(current_postseason, current_season)
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


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
	offseason_step = OFFSEASON_STEP_RETIREMENT
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


func commit_release(player_ids: Array, demote_ids: Array = []) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not offseason_active:
		return {"ok": false, "message": "オフシーズンが開始されていません"}
	if offseason_step != OFFSEASON_STEP_RELEASE_EDIT:
		return {"ok": false, "message": "戦力外通告は戦力外エディタ(step 1)でのみ確定できます"}

	# R4 Step3: CPU球団の外国人を別基準 (4枠 + 能力バー + 低稼働) で自動戦力外。
	# 自軍外国人は戦力外エディタの選択だけを尊重し、確定時に裏で追加解雇しない。
	var foreign_result: Dictionary = OffseasonService.process_foreign_releases(GameDb.players, GameDb.teams, current_season, selected_team_id)
	# roadmap #3: 自軍の育成降格 (release ではなく育成化) を release より先に適用し支配下枠を空ける。
	var demote_result: Dictionary = OffseasonService.process_demotion(GameDb.players, selected_team_id, demote_ids)
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

	# 育成降格 (自軍 + CPU 自動) を合算。
	var merged_demoted: Array = []
	merged_demoted.append_array(demote_result.get("demoted", []) as Array)
	merged_demoted.append_array(cpu_result.get("demoted", []) as Array)

	var step_result: Dictionary = {
		"released": merged_released,
		"released_count": merged_released.size(),
		"by_team": cpu_result.get("by_team", {}),
		"user_released_count": int(user_result.get("released_count", 0)),
		"cpu_released_count": int(cpu_result.get("released_count", 0)),
		"foreign_released_count": int(foreign_result.get("released_count", 0)),
		"demoted": merged_demoted,
		"demoted_count": merged_demoted.size(),
		"user_demoted_count": int(demote_result.get("demoted_count", 0)),
		"cpu_demoted_count": int(cpu_result.get("demoted_count", 0)),
	}
	step_result["title"] = "戦力外通告"
	offseason_step = OFFSEASON_STEP_RELEASE_COMMIT
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
	if offseason_step == OFFSEASON_STEP_RELEASE_EDIT:
		return {"ok": false, "message": "先に戦力外通告を確定してください"}
	if offseason_step == OFFSEASON_STEP_DRAFT_MAIN and not _is_main_draft_complete():
		return {"ok": false, "message": "本指名が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_DRAFT_DEVELOPMENT and not _is_development_draft_complete():
		return {"ok": false, "message": "育成指名が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_RELEASED_MARKET and not _is_released_market_complete():
		return {"ok": false, "message": "戦力外獲得市場が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_FA_MARKET and not _is_fa_complete():
		return {"ok": false, "message": "FA市場が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_FOREIGN_MARKET and not _is_foreign_complete():
		return {"ok": false, "message": "外国人補強が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_CAMP and not _is_camp_complete():
		return {"ok": false, "message": "キャンプが進行中です。先に完了してください"}
	if offseason_step >= OFFSEASON_TOTAL_STEPS:
		return {"ok": false, "message": "オフシーズン処理は完了しています。「翌年開始」で次シーズンへ進んでください"}

	var next_step: int = offseason_step + 1
	var step_result: Dictionary = {}
	var has_result_to_store: bool = true

	match next_step:
		OFFSEASON_STEP_RELEASE_EDIT:
			# 引退結果 (step 0) から戦力外エディタ (step 1) へのナビゲートのみ。
			# step 1 は editor 表示なので結果データは持たない。
			has_result_to_store = false
		OFFSEASON_STEP_DRAFT_MAIN:
			# R4/R5 調整: 戦力外 → ドラフト → 戦力外獲得 → FA → 外国人 → 成長 の順。
			# ドラフトを先に行い、残り枠を戦力外獲得・FA・外国人へ回す。
			draft_state = DraftService.create_draft_state(GameDb.players, GameDb.teams, current_season, selected_team_id, false)
			if _is_main_draft_complete():
				step_result = _store_main_draft_if_complete()
			else:
				step_result = {"title": "本指名", "draft_in_progress": true}
		OFFSEASON_STEP_DRAFT_DEVELOPMENT:
			draft_state = DraftService.begin_development_draft(draft_state)
			if _is_development_draft_complete():
				step_result = _finalize_draft_if_complete()
			else:
				step_result = {"title": "育成指名", "draft_in_progress": true}
		OFFSEASON_STEP_RELEASED_MARKET:
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
		OFFSEASON_STEP_FA_MARKET:
			fa_state = FaMarketService.create_fa_market_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_fa_complete():
				step_result = _finalize_fa_if_complete()
			else:
				step_result = {"title": "FA市場", "fa_in_progress": true}
				GameDb.rebuild_player_indices()
		OFFSEASON_STEP_FOREIGN_MARKET:
			foreign_state = ForeignPlayerService.create_foreign_market_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_foreign_complete():
				step_result = _finalize_foreign_if_complete()
			else:
				step_result = {"title": "外国人補強", "foreign_in_progress": true}
		OFFSEASON_STEP_CAMP:
			camp_state = _camp_service().create_camp_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_camp_complete():
				step_result = _finalize_camp_if_complete()
			else:
				step_result = {"title": "キャンプ", "camp_in_progress": true}
		OFFSEASON_STEP_GROWTH:
			step_result = OffseasonService.process_growth_decay(GameDb.players, selected_team_id, current_season)
			step_result["title"] = "成長 / 衰え"
			# roadmap #3: 成長で育った育成選手を CPU 球団は自動で支配下登録 (自軍は手動)。
			var promo: Dictionary = OffseasonService.process_development_promotions(GameDb.players, GameDb.teams, selected_team_id)
			step_result["promoted"] = promo.get("promoted", [])
			step_result["promoted_count"] = int(promo.get("promoted_count", 0))
			# 続けて CPU 球団の育成を整理 (失敗プロスペクト/枠超過を放出し pipeline を循環)。
			var dev_rel: Dictionary = OffseasonService.process_development_releases(GameDb.players, GameDb.teams, selected_team_id)
			step_result["dev_released_count"] = int(dev_rel.get("released_count", 0))
			GameDb.rebuild_player_indices()
		OFFSEASON_STEP_CONTRACT_UPDATE:
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
	if not offseason_active or (offseason_step != OFFSEASON_STEP_DRAFT_MAIN and offseason_step != OFFSEASON_STEP_DRAFT_DEVELOPMENT):
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.submit_user_candidate(draft_state, candidate_id)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_after_draft_action()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func auto_draft_user_pick() -> Dictionary:
	if not offseason_active or (offseason_step != OFFSEASON_STEP_DRAFT_MAIN and offseason_step != OFFSEASON_STEP_DRAFT_DEVELOPMENT):
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.auto_pick_for_user(draft_state)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_after_draft_action()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func skip_draft_pick() -> Dictionary:
	if not offseason_active or (offseason_step != OFFSEASON_STEP_DRAFT_MAIN and offseason_step != OFFSEASON_STEP_DRAFT_DEVELOPMENT):
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.skip_user_pick(draft_state)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_after_draft_action()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func complete_draft_automatically() -> Dictionary:
	if not offseason_active or (offseason_step != OFFSEASON_STEP_DRAFT_MAIN and offseason_step != OFFSEASON_STEP_DRAFT_DEVELOPMENT):
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var result: Dictionary = DraftService.complete_automatically(draft_state)
	draft_state = result.get("state", draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_after_draft_action()
	_save_if_enabled()
	return {"ok": true, "state": draft_state}


func _after_draft_action() -> void:
	if offseason_step == OFFSEASON_STEP_DRAFT_MAIN:
		_store_main_draft_if_complete()
	elif offseason_step == OFFSEASON_STEP_DRAFT_DEVELOPMENT:
		_finalize_draft_if_complete()


func _is_main_draft_complete() -> bool:
	return not draft_state.is_empty() and bool(draft_state.get("complete", false)) and str(draft_state.get("segment", "main")) == "main"


func _is_development_draft_complete() -> bool:
	return not draft_state.is_empty() and bool(draft_state.get("complete", false)) and str(draft_state.get("segment", "main")) == "development"


func _draft_result_snapshot(title: String, picks: Array, rookies: Array = []) -> Dictionary:
	return {
		"draft_complete": true,
		"draft_picks": picks.duplicate(true),
		"rookies": rookies.duplicate(true),
		"rookies_count": rookies.size(),
		"logs": (draft_state.get("logs", []) as Array).duplicate(true),
		"priority_league": str(draft_state.get("priority_league", "")),
		"title": title,
	}


func _store_main_draft_if_complete() -> Dictionary:
	if not _is_main_draft_complete():
		return {"title": "本指名", "draft_in_progress": true}
	var picks: Array = []
	for pick_row in draft_state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if not bool(pick.get("development", false)):
			picks.append(pick)
	var result: Dictionary = _draft_result_snapshot("本指名", picks)
	offseason_results["step_3"] = result
	last_status_message = "本指名"
	return result


func _finalize_draft_if_complete() -> Dictionary:
	if not _is_development_draft_complete():
		return {"title": "育成指名", "draft_in_progress": true}
	var final_result: Dictionary = DraftService.finalize_draft(draft_state, GameDb.players)
	GameDb.rebuild_player_indices()
	var result: Dictionary = final_result.duplicate(true)
	result["all_draft_picks"] = (final_result.get("draft_picks", []) as Array).duplicate(true)
	result["all_rookies"] = (final_result.get("rookies", []) as Array).duplicate(true)
	result["draft_picks"] = _filter_development_picks(final_result.get("draft_picks", []) as Array)
	result["rookies"] = _filter_development_rookies(final_result.get("rookies", []) as Array)
	result["rookies_count"] = (result.get("rookies", []) as Array).size()
	result["title"] = "育成指名"
	offseason_results["step_4"] = result
	last_status_message = "育成指名"
	return result


func _filter_development_picks(picks: Array) -> Array:
	var filtered: Array = []
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		if bool(pick.get("development", false)):
			filtered.append(pick.duplicate(true))
	return filtered


func _filter_development_rookies(rookies: Array) -> Array:
	var filtered: Array = []
	for rookie_row in rookies:
		var rookie: Dictionary = rookie_row as Dictionary
		if bool(rookie.get("development_player", false)):
			filtered.append(rookie.duplicate(true))
	return filtered


func submit_released_candidate(candidate_id: int) -> Dictionary:
	return _submit_released_decision(candidate_id, "sign")


func skip_released_candidate(candidate_id: int) -> Dictionary:
	return _submit_released_decision(candidate_id, "skip")


func _submit_released_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_RELEASED_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_RELEASED_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_RELEASED_MARKET:
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
	offseason_results["step_5"] = result
	last_status_message = "戦力外獲得"
	return result


func submit_fa_candidate(candidate_id: int) -> Dictionary:
	return _submit_fa_decision(candidate_id, "sign")


func skip_fa_candidate(candidate_id: int) -> Dictionary:
	return _submit_fa_decision(candidate_id, "skip")


func _submit_fa_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FA_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_FA_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_FA_MARKET:
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
	offseason_results["step_6"] = result
	last_status_message = "FA市場"
	return result


func submit_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "sign")


func skip_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "skip")


func _submit_foreign_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
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
	offseason_results["step_7"] = result
	last_status_message = "外国人補強"
	return result


func submit_camp_candidate(candidate_id: int) -> Dictionary:
	return _submit_camp_decision(candidate_id, "train")


func skip_camp_candidate(candidate_id: int) -> Dictionary:
	return _submit_camp_decision(candidate_id, "skip")


func submit_camp_player_training(player_id: int, training_type: String, target_position: int = 0) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CAMP:
		return {"ok": false, "message": "キャンプは現在有効ではありません"}
	if camp_state.is_empty():
		return {"ok": false, "message": "キャンプが初期化されていません"}
	var result: Dictionary = _camp_service().submit_user_player_training(
		camp_state,
		GameDb.players,
		GameDb.teams,
		current_season,
		player_id,
		training_type,
		target_position
	)
	camp_state = result.get("state", camp_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_camp_complete():
		_finalize_camp_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": camp_state}


func _submit_camp_decision(candidate_id: int, action: String) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CAMP:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_CAMP:
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
	if not offseason_active or offseason_step != OFFSEASON_STEP_CAMP:
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
	offseason_results["step_8"] = result
	last_status_message = "キャンプ"
	return result


func finalize_offseason() -> bool:
	if offseason_step < OFFSEASON_TOTAL_STEPS:
		push_warning("Offseason not fully processed before finalize")
	return start_next_season()


func simulate_next_game(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = GameSimulator.simulate_next_unplayed_game(current_season, persist_progress, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_current_day(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = GameSimulator.simulate_current_day(current_season, persist_progress, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_remaining_season(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = GameSimulator.simulate_remaining_season(current_season, persist_progress, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	request_screen("home")
	return result


func simulate_days(days: int, during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = GameSimulator.simulate_days(current_season, days, persist_progress, _build_auto_swap_ctx(during_skip))
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func simulate_until_team_game(during_skip: bool = false) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if selected_team_id <= 0:
		return {"ok": false, "message": "自軍が選択されていません"}

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = GameSimulator.simulate_until_team_game(current_season, selected_team_id, persist_progress, _build_auto_swap_ctx(during_skip))
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

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = await GameSimulator.simulate_current_day_async(
		current_season, persist_progress, _build_auto_swap_ctx(during_skip),
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

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = await GameSimulator.simulate_remaining_season_async(
		current_season, persist_progress, _build_auto_swap_ctx(during_skip),
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

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = await GameSimulator.simulate_days_async(
		current_season, days, persist_progress, _build_auto_swap_ctx(during_skip),
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

	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = await GameSimulator.simulate_until_team_game_async(
		current_season, selected_team_id, persist_progress, _build_auto_swap_ctx(during_skip),
		tree, progress_cb, cancel_token
	)
	last_status_message = str(result.get("message", ""))
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# 現在日が属する月の最終日まで(その日の試合を含む)消化する。
func simulate_to_month_end_async(
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	during_skip: bool = false
) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}

	var end_date: String = SeasonCalendar.last_day_of_month(SeasonCalendar.current_date(current_season))
	var end_day: int = SeasonCalendar.season_day_for_date(current_season, end_date)
	var persist_progress: bool = auto_save_enabled
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, persist_progress)
	var result: Dictionary = await GameSimulator.simulate_until_day_async(
		current_season, end_day, persist_progress, _build_auto_swap_ctx(during_skip),
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
	_screen_history.clear()
	_forward_history.clear()
	request_screen(next_screen, false)
	return true
