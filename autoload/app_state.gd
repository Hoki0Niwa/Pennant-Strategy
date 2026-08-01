extends Node

signal screen_change_requested(screen_name: String)
signal selected_team_changed(team_id: int)
signal season_started(season: PSSeason)
signal season_skip_progress(done: int, total: int, label: String)
signal season_skip_finished(result: Dictionary)

const CAMP_SERVICE_PATH: String = "res://services/season/camp_service.gd"
const SeasonCalendar = preload("res://services/season/season_calendar.gd")
# オフシーズン進行はステップID (String) で管理する。順序は OFFSEASON_STEP_ORDER が単一ソースで、
# ステップの挿入・並べ替えはこの配列の編集だけで完結する (番号の振り直しは存在しない)。
# offseason_results のキーもこのIDをそのまま使う。
const OFFSEASON_STEP_FA_DECLARATION: String = "fa_declaration"
const OFFSEASON_STEP_RETIREMENT: String = "retirement"
const OFFSEASON_STEP_RELEASE_EDIT: String = "release_edit"
const OFFSEASON_STEP_RELEASE_COMMIT: String = "release_commit"
const OFFSEASON_STEP_DRAFT_MAIN: String = "draft_main"
const OFFSEASON_STEP_DRAFT_DEVELOPMENT: String = "draft_development"
const OFFSEASON_STEP_RELEASED_MARKET: String = "released_market"
const OFFSEASON_STEP_GENEKI_DRAFT: String = "geneki_draft"
const OFFSEASON_STEP_FA_MARKET: String = "fa_market"
const OFFSEASON_STEP_CONTRACT_YEARS: String = "contract_years"
const OFFSEASON_STEP_FOREIGN_MARKET: String = "foreign_market"
const OFFSEASON_STEP_CAMP: String = "camp"
const OFFSEASON_STEP_GROWTH: String = "growth"
const OFFSEASON_STEP_CONTRACT_RENEWAL: String = "contract_renewal"
const OFFSEASON_STEP_ORDER: Array[String] = [
	OFFSEASON_STEP_FA_DECLARATION,
	OFFSEASON_STEP_RETIREMENT,
	OFFSEASON_STEP_RELEASE_EDIT,
	OFFSEASON_STEP_RELEASE_COMMIT,
	OFFSEASON_STEP_DRAFT_MAIN,
	OFFSEASON_STEP_DRAFT_DEVELOPMENT,
	OFFSEASON_STEP_RELEASED_MARKET,
	OFFSEASON_STEP_GENEKI_DRAFT,
	OFFSEASON_STEP_FA_MARKET,
	OFFSEASON_STEP_CONTRACT_YEARS,
	OFFSEASON_STEP_FOREIGN_MARKET,
	OFFSEASON_STEP_CAMP,
	OFFSEASON_STEP_GROWTH,
	OFFSEASON_STEP_CONTRACT_RENEWAL,
]

const OFFSEASON_PANEL_NONE: String = "none"
const OFFSEASON_PANEL_RESULTS: String = "results"
const OFFSEASON_PANEL_RELEASE: String = "release"
const OFFSEASON_PANEL_DRAFT: String = "draft"
const OFFSEASON_PANEL_RELEASED_MARKET: String = "released_market"
const OFFSEASON_PANEL_GENEKI_DRAFT: String = "geneki_draft"
const OFFSEASON_PANEL_FA: String = "fa"
const OFFSEASON_PANEL_FOREIGN: String = "foreign"
const OFFSEASON_PANEL_FOREIGN_CONTRACT: String = "foreign_contract"
const OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT: String = "foreign_contract_result"
const OFFSEASON_PANEL_FOREIGN_RESULT: String = "foreign_result"
const OFFSEASON_PANEL_CAMP: String = "camp"
const OFFSEASON_PANEL_CONTRACT_YEARS: String = "contract_years"

var current_screen: String = "start"
# 画面遷移の戻る/進む用スタック。各要素は画面名と選択中 player_id のスナップショット。
var _screen_history: Array = []  # 戻る用 (過去)
var _forward_history: Array = []  # 進む用 (go_back で退避した先)
var _navigating_history: bool = false
const MAX_SCREEN_HISTORY: int = 50
# フロー専用画面は戻る先にすると進行状態と UI がずれるため、履歴に積まない。
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
# 月末・残り全試合のスキップは順位表を表示したまま進める。進捗値は画面再生成時にも
# 復元できるよう AppState 側へ保持し、完了後は通常の順位表操作へ戻す。
var season_skip_active: bool = false
var season_skip_cancel_pending: bool = false
var season_skip_done: int = 0
var season_skip_total: int = 0
var season_skip_label: String = ""
var season_skip_kind: String = "season"
var _season_skip_cancel_token: Dictionary = {}
# 7日スキップはホーム画面内で進捗を表示する。画面ノード上の coroutine を途中で
# 破棄しないよう、完了までは履歴・画面遷移だけをロックする。
var short_skip_active: bool = false
var offseason_step: String = OFFSEASON_STEP_RETIREMENT
var offseason_results: Dictionary = {}
var draft_state: Dictionary = {}
var released_market_state: Dictionary = {}
var geneki_draft_state: Dictionary = {}
var fa_state: Dictionary = {}
var foreign_state: Dictionary = {}
var camp_state: Dictionary = {}
var contract_years_state: Dictionary = {}
var offseason_active: bool = false
var postseason_active: bool = false
var current_postseason: PSPostseasonResult = null
var current_awards: PSAwards = null
# 通常プレイ中に自軍も成績ベースの自動入替を行うか。active_roster_screenから操作。
var auto_roster_swap_for_user_team: bool = false
# スキップ操作中に自軍も成績ベースの自動入替を行うか。オプション画面から操作。
var auto_roster_swap_during_skip: bool = true
# 週次の自動トレード判断に自軍も参加させるか (有効時は自軍宛て提案を作らず、CPU間
# マッチングと同じ基準で自軍のトレードもAIが自動成立させる)。オプション画面から操作。
var auto_trade_for_user_team: bool = false
# ドラフト完全ウェーバー制。ON のとき1巡目の入札・抽選を行わず、本指名の全巡を
# 前年下位球団から順 (スネークなし) に指名する。次回のドラフト生成から適用。
var draft_full_waiver: bool = false
# 進行消失を避けるため、新規ゲームの自動セーブは既定で有効。
const DEFAULT_AUTO_SAVE_ENABLED: bool = true
var auto_save_enabled: bool = DEFAULT_AUTO_SAVE_ENABLED
var league_dh_enabled: Dictionary = {
	"league1": true,
	"league2": true,
}


func _camp_service() -> GDScript:
	return load(CAMP_SERVICE_PATH) as GDScript


# 自動セーブ設定を見て SaveService.save_state を呼ぶ共通ラッパー。
func _save_if_enabled() -> void:
	if auto_save_enabled:
		SaveService.save_state(self)


func show_player_detail(player_id: int) -> void:
	# 現在画面を履歴へ積んでから選手詳細へ遷移する。player_id も履歴スナップショットに含める。
	_record_history_snapshot("player_detail")
	current_player_id = player_id
	request_screen("player_detail", false)


# 現在の画面状態を戻る履歴へ積む。連続重複・フロー専用画面・履歴操作中の再記録は抑止する。
func _record_history_snapshot(next_screen: String) -> void:
	if _navigating_history:
		return
	# 新しい通常遷移が入ったら、戻る操作で退避していた進む履歴は破棄する。
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
	if season_skip_active or short_skip_active:
		return false
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
	if season_skip_active or short_skip_active:
		return false
	return _navigate_history(_forward_history, _screen_history)


func request_screen(screen_name: String, record_history: bool = true) -> void:
	if season_skip_active and screen_name != "standings":
		return
	if short_skip_active and screen_name != current_screen:
		return
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
		"league1": bool(league_dh_enabled.get("league1", true)),
		"league2": bool(league_dh_enabled.get("league2", true)),
	}


# 現在のステップが OFFSEASON_STEP_ORDER の何番目か (-1=不明)。順序比較はこれ経由でのみ行う。
func offseason_step_index() -> int:
	return OFFSEASON_STEP_ORDER.find(offseason_step)


# 全ステップ消化済み (=最終ステップに到達) かどうか。「翌年開始」可否の判定に使う。
func offseason_steps_complete() -> bool:
	return offseason_step == OFFSEASON_STEP_ORDER[OFFSEASON_STEP_ORDER.size() - 1]


func get_offseason_view_state() -> Dictionary:
	var step: String = offseason_step
	var active_panel: String = OFFSEASON_PANEL_RESULTS
	var title: String = ""
	var interactive: bool = false
	var result: Dictionary = {}

	if not offseason_active:
		return {
			"active": false,
			"step": step,
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
		OFFSEASON_STEP_GENEKI_DRAFT:
			if not geneki_draft_state.is_empty() and not bool(geneki_draft_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_GENEKI_DRAFT
				title = "現役ドラフト"
				interactive = true
		OFFSEASON_STEP_FA_MARKET:
			if not fa_state.is_empty() and not bool(fa_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_FA
				title = "FA市場"
				interactive = true
		OFFSEASON_STEP_FOREIGN_MARKET:
			if not foreign_state.is_empty() and not bool(foreign_state.get("complete", false)):
				match str(foreign_state.get("phase", "scout")):
					"contract":
						active_panel = OFFSEASON_PANEL_FOREIGN_CONTRACT
						title = "外国人契約市場"
					"contract_result":
						active_panel = OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT
						title = "外国人契約市場: 結果"
					"scout_result":
						active_panel = OFFSEASON_PANEL_FOREIGN_RESULT
						title = "外国人スカウト: 結果"
					_:
						active_panel = OFFSEASON_PANEL_FOREIGN
						title = "外国人補強"
				interactive = true
		OFFSEASON_STEP_CAMP:
			if not camp_state.is_empty() and not bool(camp_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_CAMP
				title = "キャンプ"
				interactive = true
		OFFSEASON_STEP_CONTRACT_YEARS:
			if not contract_years_state.is_empty() and not bool(contract_years_state.get("complete", false)):
				active_panel = OFFSEASON_PANEL_CONTRACT_YEARS
				title = "契約年数の決定"
				interactive = true

	if not interactive:
		result = offseason_results.get(step, {}) as Dictionary
		title = str(result.get("title", "")) if not result.is_empty() else "結果データがありません"

	return {
		"active": true,
		"step": step,
		"title": title,
		"status": title,
		"active_panel": active_panel,
		"is_interactive": interactive,
		"can_advance": (not interactive) and not offseason_steps_complete(),
		"can_finalize": (not interactive) and offseason_steps_complete(),
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
	_prewarm_lineup_profiles()
	last_status_message = ""
	offseason_step = OFFSEASON_STEP_RETIREMENT
	offseason_results = {}
	draft_state = {}
	released_market_state = {}
	geneki_draft_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	contract_years_state = {}
	offseason_active = false
	postseason_active = false
	current_postseason = null
	current_awards = null
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
	RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, auto_save_enabled)
	# 新シーズンは現在のロースター/能力でスタメン・打順を選び直すため、テンプレキャッシュをリセット。
	PSDefenseAlignmentProfile.reset_cache()
	PSBattingOrderProfile.reset_cache()
	_prewarm_lineup_profiles()
	last_status_message = ""
	offseason_step = OFFSEASON_STEP_RETIREMENT
	offseason_results = {}
	draft_state = {}
	released_market_state = {}
	geneki_draft_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	contract_years_state = {}
	offseason_active = false
	postseason_active = false
	current_postseason = null
	current_awards = null
	_screen_history.clear()
	_forward_history.clear()
	request_screen("home")
	season_started.emit(current_season)
	return true


# BattingOrderProfile/DefenseAlignmentProfile のチーム別キャッシュを事前に埋める。
# 試合シミュレーションを並列実行する際、初回アクセス時の遅延書き込み(static var _cache)が
# 複数スレッドから同時に発生するとDictionary構造変更のレースになるため、メインスレッドの
# シーズン開始時点で全チーム分を読み切っておき、以後は読み取り専用アクセスにする。
func _prewarm_lineup_profiles() -> void:
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		if team == null:
			continue
		PSBattingOrderProfile.load_for_team(team.id, true)
		PSBattingOrderProfile.load_for_team(team.id, false)
		PSDefenseAlignmentProfile.load_for_team(team.id)


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
	var sync_result: Dictionary = PostseasonService.sync_to_next_postseason_day(current_postseason, current_season)
	if not bool(sync_result.get("ok", false)):
		return sync_result
	postseason_active = true
	_save_if_enabled()
	# ポストシーズン中はホーム画面をポストシーズン用ダッシュボードへ差し替える (main.gd でルーティング)。
	request_screen("home")
	return {"ok": true}


# 1日進める: 進行中ステージグループ(第1/第2リーグ)の試合を同時に1試合ずつ消化する。
func advance_postseason_day() -> Dictionary:
	if current_season == null or current_postseason == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	var result: Dictionary = PostseasonService.advance_one_day(current_postseason, current_season, auto_save_enabled)
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
	_archive_current_season_if_needed()
	_save_if_enabled()
	request_screen("awards")
	return {"ok": true}


func _archive_current_season_if_needed() -> bool:
	if current_season == null or current_awards == null:
		return false
	if _archive_exists(current_season.year, current_season.season_number):
		return false
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.year = current_season.year
	archive.season_number = current_season.season_number
	archive.standings = _snapshot_standings(current_season)
	archive.postseason = current_postseason
	archive.awards = current_awards
	RecordStore.add_season_archive(archive, auto_save_enabled)
	return true


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
	_archive_current_season_if_needed()
	postseason_active = false
	# Step 0: FA宣言を即時実行して結果を保存する (FA日数の締めと contract_status 遷移もここで
	# 済ませる)。宣言は事実の記録だけで、ロースター離脱は FA市場ステップまで起こらない。
	var declaration_result: Dictionary = FaMarketService.create_declaration_state(GameDb.players, GameDb.teams, current_season)
	declaration_result["title"] = "FA宣言"
	offseason_step = OFFSEASON_STEP_FA_DECLARATION
	offseason_results = {OFFSEASON_STEP_FA_DECLARATION: declaration_result}
	draft_state = {}
	released_market_state = {}
	geneki_draft_state = {}
	fa_state = {}
	foreign_state = {}
	camp_state = {}
	contract_years_state = {}
	offseason_active = true
	last_status_message = str(declaration_result.get("title", ""))
	_save_if_enabled()
	# 年に一度の節目で、肥大化していれば DB ファイルを切り詰める (freelist 回収)。
	if auto_save_enabled:
		SaveService.compact_storage()
	# オフシーズン画面はホームを上書きする (main.gd が offseason_active 中は "home" をここへルーティング)。
	request_screen("home")
	return {"ok": true}


func commit_release(player_ids: Array, demote_ids: Array = []) -> Dictionary:
	if current_season == null:
		return {"ok": false, "message": "シーズンが開始されていません"}
	if not offseason_active:
		return {"ok": false, "message": "オフシーズンが開始されていません"}
	if offseason_step != OFFSEASON_STEP_RELEASE_EDIT:
		return {"ok": false, "message": "戦力外通告は戦力外エディタでのみ確定できます"}

	var offseason_year: int = current_season.year if current_season != null else 0
	var lock_check: Dictionary = OffseasonService.reject_locked_release_or_demote(GameDb.players, player_ids, demote_ids, offseason_year)
	if not bool(lock_check.get("ok", true)):
		return lock_check

	# 外国人の去就 (残留/引き抜き/退団) は戦力外通告ではなく外国人契約市場 (オフステップ7) が
	# 一括で決める ([[foreign_player_service.gd]])。ここでは日本人選手だけを扱う。
	# roadmap #3: 自軍の育成降格 (release ではなく育成化) を release より先に適用し支配下枠を空ける。
	var demote_result: Dictionary = OffseasonService.process_demotion(GameDb.players, selected_team_id, demote_ids, offseason_year)
	var user_result: Dictionary = OffseasonService.process_release(GameDb.players, selected_team_id, player_ids, offseason_year)
	var cpu_result: Dictionary = OffseasonService.process_cpu_releases(GameDb.players, GameDb.teams, selected_team_id, current_season)

	# 自軍と CPU 全球団を合算した結果を release_commit ステップ結果として保存する。
	var merged_released: Array = []
	merged_released.append_array(user_result.get("released", []) as Array)
	merged_released.append_array(cpu_result.get("released", []) as Array)
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
		# 外国人の去就は外国人契約市場ステップで決まるため、この時点では常に0。
		"foreign_released_count": 0,
		"demoted": merged_demoted,
		"demoted_count": merged_demoted.size(),
		"user_demoted_count": int(demote_result.get("demoted_count", 0)),
		"cpu_demoted_count": int(cpu_result.get("demoted_count", 0)),
	}
	step_result["title"] = "戦力外通告"
	offseason_step = OFFSEASON_STEP_RELEASE_COMMIT
	offseason_results[OFFSEASON_STEP_RELEASE_COMMIT] = step_result
	GameDb.rebuild_player_indices()
	last_status_message = str(step_result.get("title", ""))
	_save_if_enabled()
	return {"ok": true, "step": OFFSEASON_STEP_RELEASE_COMMIT, "result": step_result}


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
	if offseason_step == OFFSEASON_STEP_GENEKI_DRAFT and not _is_geneki_draft_complete():
		return {"ok": false, "message": "現役ドラフトが進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_FA_MARKET and not _is_fa_complete():
		return {"ok": false, "message": "FA市場が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_FOREIGN_MARKET and not _is_foreign_complete():
		return {"ok": false, "message": "外国人補強が進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_CAMP and not _is_camp_complete():
		return {"ok": false, "message": "キャンプが進行中です。先に完了してください"}
	if offseason_step == OFFSEASON_STEP_CONTRACT_YEARS and not _is_contract_years_complete():
		return {"ok": false, "message": "契約年数の決定が進行中です。先に完了してください"}
	if offseason_steps_complete():
		return {"ok": false, "message": "オフシーズン処理は完了しています。「翌年開始」で次シーズンへ進んでください"}
	var current_index: int = offseason_step_index()
	if current_index < 0:
		return {"ok": false, "message": "不正なステップID: %s" % offseason_step}

	var next_step: String = OFFSEASON_STEP_ORDER[current_index + 1]
	var step_result: Dictionary = {}
	var has_result_to_store: bool = true

	match next_step:
		OFFSEASON_STEP_RETIREMENT:
			# 引退者を除外した後の payroll で年次予算を算定するため、予算再計算はこの直後に行う。
			step_result = OffseasonService.process_retirement(GameDb.players, current_season)
			step_result["title"] = "引退判定"
			var champion_id: int = current_postseason.champion_team_id if current_postseason != null else 0
			step_result["budgets"] = TeamFinance.recompute_annual_budgets(GameDb.players, GameDb.teams, current_season, champion_id)
			GameDb.rebuild_player_indices()
		OFFSEASON_STEP_RELEASE_EDIT:
			# 引退結果から戦力外エディタへのナビゲートのみ。
			# 戦力外エディタは editor 表示なので結果データは持たない。
			has_result_to_store = false
		OFFSEASON_STEP_DRAFT_MAIN:
			# R4/R5 調整: 戦力外 → ドラフト → 戦力外獲得 → FA → 外国人 → 成長 の順。
			# ドラフトを先に行い、残り枠を戦力外獲得・FA・外国人へ回す。
			draft_state = DraftService.create_draft_state(GameDb.players, GameDb.teams, current_season, selected_team_id, false, draft_full_waiver)
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
				offseason_results.get(OFFSEASON_STEP_RELEASE_COMMIT, {}) as Dictionary,
				selected_team_id
			)
			if _is_released_market_complete():
				step_result = _finalize_released_market_if_complete()
			else:
				step_result = {"title": "戦力外獲得", "released_market_in_progress": true}
		OFFSEASON_STEP_GENEKI_DRAFT:
			geneki_draft_state = GenekiDraftService.create_geneki_draft_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_geneki_draft_complete():
				step_result = _finalize_geneki_draft_if_complete()
			else:
				step_result = {"title": "現役ドラフト", "geneki_draft_in_progress": true}
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
			var promo: Dictionary = OffseasonService.process_development_promotions(GameDb.players, GameDb.teams, selected_team_id, current_season.year if current_season != null else 0)
			step_result["promoted"] = promo.get("promoted", [])
			step_result["promoted_count"] = int(promo.get("promoted_count", 0))
			# 続けて CPU 球団の育成を整理 (失敗プロスペクト/枠超過を放出し pipeline を循環)。
			var dev_rel: Dictionary = OffseasonService.process_development_releases(GameDb.players, GameDb.teams, selected_team_id, current_season.year if current_season != null else 0)
			step_result["dev_released_count"] = int(dev_rel.get("released_count", 0))
			GameDb.rebuild_player_indices()
		OFFSEASON_STEP_CONTRACT_YEARS:
			contract_years_state = OffseasonService.create_contract_years_state(GameDb.players, GameDb.teams, current_season, selected_team_id)
			if _is_contract_years_complete():
				step_result = _finalize_contract_years_if_complete()
			else:
				step_result = {"title": "契約年数", "contract_years_in_progress": true}
		OFFSEASON_STEP_CONTRACT_RENEWAL:
			step_result = OffseasonService.process_contract_renewal(GameDb.players, GameDb.teams, current_season)
			step_result["title"] = "契約更改"
		_:
			return {"ok": false, "message": "不正なステップID: %s" % next_step}

	offseason_step = next_step
	if has_result_to_store:
		offseason_results[next_step] = step_result
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


# 1巡目入札の対話フロー: stage="first_round_reveal"(公開済み入札→抽選) /
# "first_round_result"(抽選結果確定→次wave) のどちらかを1ステップだけ進める。
# UI の「抽選へ」「次へ」ボタンから呼ばれる想定。
func proceed_draft_first_round() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_DRAFT_MAIN:
		return {"ok": false, "message": "ドラフトは現在有効ではありません"}
	if draft_state.is_empty():
		return {"ok": false, "message": "ドラフトが初期化されていません"}
	var stage: String = str(draft_state.get("stage", ""))
	var result: Dictionary
	if stage == "first_round_reveal":
		result = DraftService.resolve_first_round_reveal(draft_state)
	elif stage == "first_round_result":
		result = DraftService.continue_first_round(draft_state)
	else:
		return {"ok": false, "message": "入札公開の段階ではありません"}
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
	offseason_results[OFFSEASON_STEP_DRAFT_MAIN] = result
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
	offseason_results[OFFSEASON_STEP_DRAFT_DEVELOPMENT] = result
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
	offseason_results[OFFSEASON_STEP_RELEASED_MARKET] = result
	last_status_message = "戦力外獲得"
	return result


# ---------------------------------------------------------------- 現役ドラフト

func submit_geneki_list(player_ids: Array) -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.submit_user_list(geneki_draft_state, GameDb.players, GameDb.teams, current_season, player_ids)
	)


func auto_geneki_list() -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.auto_submit_user_list(geneki_draft_state, GameDb.players, GameDb.teams, current_season)
	)


func submit_geneki_pick(player_id: int) -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.submit_user_pick(geneki_draft_state, GameDb.players, GameDb.teams, current_season, player_id)
	)


func pass_geneki_pick() -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.pass_user_pick(geneki_draft_state, GameDb.players, GameDb.teams, current_season)
	)


func set_geneki_round2_mode(mode: String) -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.set_user_round2_mode(geneki_draft_state, GameDb.players, GameDb.teams, current_season, mode)
	)


func complete_geneki_draft_automatically() -> Dictionary:
	return _geneki_action(func() -> Dictionary:
		return GenekiDraftService.complete_automatically(geneki_draft_state, GameDb.players, GameDb.teams, current_season)
	)


# 現役ドラフトの各ユーザー操作の共通ラッパー: ステップガード → サービス呼び出し →
# 完了していれば移籍を確定 → 保存。
func _geneki_action(action: Callable) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_GENEKI_DRAFT:
		return {"ok": false, "message": "現役ドラフトは現在有効ではありません"}
	if geneki_draft_state.is_empty():
		return {"ok": false, "message": "現役ドラフトが初期化されていません"}
	var result: Dictionary = action.call()
	geneki_draft_state = result.get("state", geneki_draft_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_geneki_draft_complete():
		_finalize_geneki_draft_if_complete()
	_save_if_enabled()
	return {"ok": true, "state": geneki_draft_state}


func _is_geneki_draft_complete() -> bool:
	return not geneki_draft_state.is_empty() and bool(geneki_draft_state.get("complete", false))


func _finalize_geneki_draft_if_complete() -> Dictionary:
	if not _is_geneki_draft_complete():
		return {"title": "現役ドラフト", "geneki_draft_in_progress": true}
	var result: Dictionary = GenekiDraftService.finalize_geneki_draft(geneki_draft_state, GameDb.players, GameDb.teams, current_season)
	GameDb.rebuild_player_indices()
	result["title"] = "現役ドラフト"
	offseason_results[OFFSEASON_STEP_GENEKI_DRAFT] = result
	last_status_message = "現役ドラフト"
	return result


func submit_fa_candidate(candidate_id: int, offer_years: int = 0) -> Dictionary:
	return _submit_fa_decision(candidate_id, "sign", offer_years)


func skip_fa_candidate(candidate_id: int) -> Dictionary:
	return _submit_fa_decision(candidate_id, "skip")


func _submit_fa_decision(candidate_id: int, action: String, offer_years: int = 0) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FA_MARKET:
		return {"ok": false, "message": "FA市場は現在有効ではありません"}
	if fa_state.is_empty():
		return {"ok": false, "message": "FA市場が初期化されていません"}
	var result: Dictionary = FaMarketService.submit_user_fa_decision(fa_state, GameDb.players, GameDb.teams, current_season, candidate_id, action, offer_years)
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
	offseason_results[OFFSEASON_STEP_FA_MARKET] = result
	last_status_message = "FA市場"
	return result


func submit_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "sign")


func skip_foreign_candidate(candidate_id: int) -> Dictionary:
	return _submit_foreign_decision(candidate_id, "skip")


func configure_foreign_scout_request(position: String, archetype: String, budget_band: String) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.configure_user_scout_request(foreign_state, position, archetype, budget_band)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# 外国人契約市場 (残留/引き抜き、スカウトの前段フェーズ): 自軍満了者への残留提示、
# または他球団満了者への引き抜き提示。年数は entry.max_years でクランプされる。
func submit_foreign_contract_offer(player_id: int, years: int) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.submit_user_contract_offer(foreign_state, GameDb.players, GameDb.teams, current_season, player_id, years)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func withdraw_foreign_contract_offer(player_id: int) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.withdraw_user_contract_offer(foreign_state, player_id)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# 契約市場を確定する: ユーザー球団は明示提示 (submit_foreign_contract_offer) した選手のみを扱い、
# 未提示の自軍満了者へはCPU残留提示を生成しない (auto_user_team=false)。他球団はCPUが従来どおり
# 自動で残留/引き抜きを判断する。解決後は結果パネル (OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT) を
# 経てから scout フェーズへ進む。
func finalize_foreign_contract_market() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	if str(foreign_state.get("phase", "contract")) != "contract":
		return {"ok": false, "message": "外国人契約市場は既に確定しています"}
	var result: Dictionary = ForeignPlayerService.resolve_foreign_contract_market(foreign_state, GameDb.players, GameDb.teams, current_season, selected_team_id, false, true)
	foreign_state = result.get("state", foreign_state) as Dictionary
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


# 「すべてAIに任せる」: ユーザー球団も他球団と同じ基準 (_cpu_retain_offer) で自動残留判断させる
# (auto_user_team=true)。確定ボタンと同様に結果パネル (contract_result) を経てから scout へ進む
# (show_result=true。2ボタンの違いは自軍を自動判断に含めるか否かだけで、結果表示は共通)。
func auto_complete_foreign_contract_market() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	if str(foreign_state.get("phase", "contract")) != "contract":
		return {"ok": false, "message": "外国人契約市場は既に確定しています"}
	var result: Dictionary = ForeignPlayerService.resolve_foreign_contract_market(foreign_state, GameDb.players, GameDb.teams, current_season, selected_team_id, true, true)
	foreign_state = result.get("state", foreign_state) as Dictionary
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


# 契約市場の結果パネルの「次へ」: phase を "contract_result" → "scout" へ進める。
func advance_foreign_contract_result() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.advance_foreign_contract_result(foreign_state)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# 外国人スカウトの結果パネルの「次へ」: phase "scout_result" を終え、外国人ステップを完了させる。
func advance_foreign_scout_result() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.advance_foreign_scout_result(foreign_state)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	if _is_foreign_complete():
		_finalize_foreign_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


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


# 「補強を終了」: 自軍の残り候補は打ち切り、他球団だけCPUが自動補強する。show_result=true なので
# 即完了はせず phase="scout_result" の結果パネル ("次へ" は advance_foreign_scout_result) を挟む。
func complete_foreign_automatically() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.complete_foreign_market_automatically(foreign_state, GameDb.players, GameDb.teams, current_season, selected_team_id, true)
	foreign_state = result.get("state", foreign_state) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_finalize_foreign_if_complete()
	GameDb.rebuild_player_indices()
	_save_if_enabled()
	return {"ok": true, "state": foreign_state}


func complete_all_foreign_automatically() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_FOREIGN_MARKET:
		return {"ok": false, "message": "外国人補強は現在有効ではありません"}
	if foreign_state.is_empty():
		return {"ok": false, "message": "外国人補強が初期化されていません"}
	var result: Dictionary = ForeignPlayerService.complete_all_foreign_market_automatically(
		foreign_state, GameDb.players, GameDb.teams, current_season
	)
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
	offseason_results[OFFSEASON_STEP_FOREIGN_MARKET] = result
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
	offseason_results[OFFSEASON_STEP_CAMP] = result
	last_status_message = "キャンプ"
	return result


# 契約年数ステップ: 自軍の候補に年数 (1〜entry.max_years) を決める。決めた年数は必ず成立する。
func submit_contract_years(player_id: int, years: int) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CONTRACT_YEARS:
		return {"ok": false, "message": "契約年数の決定は現在有効ではありません"}
	if contract_years_state.is_empty():
		return {"ok": false, "message": "契約年数の決定が初期化されていません"}
	var result: Dictionary = OffseasonService.submit_contract_years(contract_years_state, GameDb.players, GameDb.teams, selected_team_id, player_id, years)
	contract_years_state = result.get("state", contract_years_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


func withdraw_contract_years(player_id: int) -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CONTRACT_YEARS:
		return {"ok": false, "message": "契約年数の決定は現在有効ではありません"}
	if contract_years_state.is_empty():
		return {"ok": false, "message": "契約年数の決定が初期化されていません"}
	var result: Dictionary = OffseasonService.withdraw_contract_years(contract_years_state, player_id)
	contract_years_state = result.get("state", contract_years_state) as Dictionary
	if bool(result.get("ok", false)):
		_save_if_enabled()
	return result


# 自軍の未決定分をCPUと同じ基準 (価値/年齢/予算) で一括決定する (UIの「自動で決める」)。
func auto_decide_contract_years() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CONTRACT_YEARS:
		return {"ok": false, "message": "契約年数の決定は現在有効ではありません"}
	if contract_years_state.is_empty():
		return {"ok": false, "message": "契約年数の決定が初期化されていません"}
	var result: Dictionary = OffseasonService.auto_decide_contract_years(contract_years_state, GameDb.players, GameDb.teams, selected_team_id)
	contract_years_state = result.get("state", contract_years_state) as Dictionary
	_save_if_enabled()
	return result


# 契約年数を確定する。自軍に未決定が残っていたら拒否 (UI側でもボタンを無効化している)。
# CPU球団の未決定分はここで一括決定される。
func finalize_contract_years() -> Dictionary:
	if not offseason_active or offseason_step != OFFSEASON_STEP_CONTRACT_YEARS:
		return {"ok": false, "message": "契約年数の決定は現在有効ではありません"}
	if contract_years_state.is_empty():
		return {"ok": false, "message": "契約年数の決定が初期化されていません"}
	var pending: int = pending_contract_years_count()
	if pending > 0:
		return {"ok": false, "message": "契約年数が未決定の選手が %d 人います" % pending}
	_finalize_contract_years_force()
	_save_if_enabled()
	return {"ok": true, "state": contract_years_state}


func pending_contract_years_count() -> int:
	if contract_years_state.is_empty():
		return 0
	return OffseasonService.pending_contract_years_count(contract_years_state, selected_team_id)


func _is_contract_years_complete() -> bool:
	return not contract_years_state.is_empty() and bool(contract_years_state.get("complete", false))


func _finalize_contract_years_if_complete() -> Dictionary:
	if not _is_contract_years_complete():
		return {"title": "契約年数", "contract_years_in_progress": true}
	return _finalize_contract_years_force()


# ユーザーが確定ボタンを押す経路は complete==false のまま呼ばれるので、_is_contract_years_complete
# を経ずに直接サービス層を呼ぶ。OffseasonService.finalize_contract_years 自体は finalized フラグで
# 二重実行を防ぐ。
func _finalize_contract_years_force() -> Dictionary:
	var result: Dictionary = OffseasonService.finalize_contract_years(contract_years_state, GameDb.players, GameDb.teams)
	GameDb.rebuild_player_indices()
	result["title"] = "契約年数"
	offseason_results[OFFSEASON_STEP_CONTRACT_YEARS] = result
	last_status_message = "契約年数"
	return result


func finalize_offseason() -> bool:
	if not offseason_steps_complete():
		push_warning("Offseason not fully processed before finalize")
	return start_next_season()


# セーブ値のステップを現行IDへ正規化する (未知のIDは先頭ステップへ倒す)。
func _normalize_saved_offseason_step(raw_step: Variant) -> String:
	if raw_step is String and OFFSEASON_STEP_ORDER.has(raw_step):
		return raw_step
	return OFFSEASON_STEP_ORDER[0]


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
	during_skip: bool = false,
	return_to_home: bool = true
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
	if return_to_home and not bool(result.get("cancelled", false)):
		request_screen("home")
	return result


# 処理主体を破棄されるホーム画面ではなく Autoload に置き、順位表へ遷移した後も
# シミュレーションと進捗通知を継続する。
func start_remaining_season_skip(tree: SceneTree) -> void:
	if not _begin_standings_skip("season", current_season.games_remaining() if current_season != null else 0):
		return
	var result: Dictionary = await simulate_remaining_season_async(
		tree,
		_on_remaining_season_skip_progress,
		_season_skip_cancel_token,
		true,
		false
	)
	_finish_standings_skip(result)


func start_month_end_skip(tree: SceneTree) -> void:
	if current_season == null:
		return
	var end_date: String = SeasonCalendar.last_day_of_month(SeasonCalendar.current_date(current_season))
	var end_day: int = SeasonCalendar.season_day_for_date(current_season, end_date)
	if not _begin_standings_skip("month", _count_unplayed_games_through_day(end_day)):
		return
	var result: Dictionary = await simulate_to_month_end_async(
		tree,
		_on_remaining_season_skip_progress,
		_season_skip_cancel_token,
		true
	)
	_finish_standings_skip(result)


func _begin_standings_skip(kind: String, total: int) -> bool:
	if season_skip_active or current_season == null:
		return false
	season_skip_active = true
	season_skip_cancel_pending = false
	season_skip_done = 0
	season_skip_total = total
	season_skip_label = SeasonCalendar.day_status_label(current_season, current_season.current_day)
	season_skip_kind = kind
	_season_skip_cancel_token = {"cancelled": false}
	# 順位表はスキップ中だけの一時画面なので、画面履歴には積まない。
	request_screen("standings", false)
	season_skip_progress.emit(season_skip_done, season_skip_total, season_skip_label)
	return true


func _finish_standings_skip(result: Dictionary) -> void:
	season_skip_active = false
	season_skip_cancel_pending = false
	_season_skip_cancel_token = {}
	last_status_message = str(result.get("message", ""))
	season_skip_finished.emit(result)
	request_screen("home", false)


func cancel_remaining_season_skip() -> void:
	if not season_skip_active or season_skip_cancel_pending:
		return
	season_skip_cancel_pending = true
	_season_skip_cancel_token["cancelled"] = true
	season_skip_progress.emit(season_skip_done, season_skip_total, season_skip_label)


func _on_remaining_season_skip_progress(done: int, total: int, _label: String) -> void:
	season_skip_done = done
	season_skip_total = total
	if current_season != null:
		season_skip_label = SeasonCalendar.day_status_label(current_season, current_season.current_day)
	season_skip_progress.emit(season_skip_done, season_skip_total, season_skip_label)


func _count_unplayed_games_through_day(end_day: int) -> int:
	if current_season == null:
		return 0
	var total: int = 0
	for game_value in current_season.schedule:
		var game: Dictionary = game_value as Dictionary
		var day: int = int(game.get("day", 0))
		if not bool(game.get("played", false)) and day >= current_season.current_day and day <= end_day:
			total += 1
	return total


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
		# トレードは一二軍入替と別トグルで自軍参加を制御できる (どちらか一方が有効でも
		# 自軍をCPU間マッチングへ含める)。未使用の呼び出し元では include_user_team にフォールバックする。
		"include_user_trade": include_user or auto_trade_for_user_team,
	}


func _normalize_league_key(league: String) -> String:
	return "league2" if league == "league2" else "league1"


func _apply_dh_settings_to_current_schedule() -> void:
	if current_season == null:
		return
	for game_value in current_season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		var home_team: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
		var league_key: String = "league1" if home_team == null else _normalize_league_key(home_team.league)
		game["dh_enabled"] = is_dh_enabled_for_league(league_key)


# 当該シーズンが 50 試合以上消化済みなのに、シーズン成績レコードの出場が全選手 0 なら
# 「成績消失セーブ」とみなす (restore_from_save の破損検知用)。
func _season_records_look_wiped(season: PSSeason) -> bool:
	if season == null:
		return false
	var played: int = 0
	for game_value in season.schedule:
		if bool((game_value as Dictionary).get("played", false)):
			played += 1
	if played < 50:
		return false
	var checked_any: bool = false
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year != season.year or record.season_number != season.season_number:
			continue
		checked_any = true
		if record.is_pitcher():
			if record.pitcher_stats.games > 0:
				return false
		elif record.batter_stats.games > 0:
			return false
	return checked_any


func restore_from_save(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	season_skip_active = false
	season_skip_cancel_pending = false
	season_skip_done = 0
	season_skip_total = 0
	season_skip_label = ""
	season_skip_kind = "season"
	_season_skip_cancel_token = {}
	short_skip_active = false

	var mod_warnings: Array[String] = ModManager.check_save_compatibility(data.get("active_mods", []) as Array)
	for warning in mod_warnings:
		push_warning(warning)

	var player_rows: Array = data.get("players", []) as Array
	if not player_rows.is_empty():
		GameDb.replace_players_from_rows(player_rows)

	# R4 Step1: チーム予算 (funds) を復元。teams 本体は初期シードから再ロードされるため、
	# funds だけ id 一致で上書きする。
	var saved_funds: Dictionary = data.get("team_funds", {}) as Dictionary
	for funds_key in saved_funds.keys():
		var team: PSTeam = GameDb.get_team(int(funds_key))
		if team != null:
			team.funds = int(saved_funds[funds_key])

	# 年次予算キャップ導入 (2026-07-12): previous_rank も毎オフ更新されるため funds と同様に復元する。
	var saved_ranks: Dictionary = data.get("team_previous_ranks", {}) as Dictionary
	for rank_key in saved_ranks.keys():
		var ranked_team: PSTeam = GameDb.get_team(int(rank_key))
		if ranked_team != null:
			ranked_team.previous_rank = int(saved_ranks[rank_key])

	var saved_auto_lineup: Dictionary = data.get("team_auto_lineup", {}) as Dictionary
	for lineup_key in saved_auto_lineup.keys():
		var lineup_team: PSTeam = GameDb.get_team(int(lineup_key))
		if lineup_team != null:
			lineup_team.auto_lineup = bool(saved_auto_lineup[lineup_key])

	selected_team_id = int(data.get("selected_team_id", 0))
	offseason_step = _normalize_saved_offseason_step(data.get("offseason_step", OFFSEASON_STEP_RETIREMENT))
	offseason_results = (data.get("offseason_results", {}) as Dictionary).duplicate(true)
	draft_state = (data.get("draft_state", {}) as Dictionary).duplicate(true)
	released_market_state = (data.get("released_market_state", {}) as Dictionary).duplicate(true)
	geneki_draft_state = (data.get("geneki_draft_state", {}) as Dictionary).duplicate(true)
	fa_state = (data.get("fa_state", {}) as Dictionary).duplicate(true)
	foreign_state = (data.get("foreign_state", {}) as Dictionary).duplicate(true)
	camp_state = (data.get("camp_state", {}) as Dictionary).duplicate(true)
	contract_years_state = (data.get("contract_years_state", {}) as Dictionary).duplicate(true)
	offseason_active = bool(data.get("offseason_active", false))
	postseason_active = bool(data.get("postseason_active", false))
	auto_roster_swap_for_user_team = bool(data.get("auto_roster_swap_for_user_team", false))
	auto_roster_swap_during_skip = bool(data.get("auto_roster_swap_during_skip", true))
	auto_trade_for_user_team = bool(data.get("auto_trade_for_user_team", false))
	draft_full_waiver = bool(data.get("draft_full_waiver", false))
	auto_save_enabled = bool(data.get("auto_save_enabled", DEFAULT_AUTO_SAVE_ENABLED))
	var saved_dh_settings: Dictionary = data.get("league_dh_enabled", {}) as Dictionary
	league_dh_enabled = {
		"league1": bool(saved_dh_settings.get("league1", true)),
		"league2": bool(saved_dh_settings.get("league2", true)),
	}
	var post_data: Dictionary = data.get("current_postseason", {}) as Dictionary
	current_postseason = PSPostseasonResult.from_dict(post_data) if not post_data.is_empty() else null
	var awards_data: Dictionary = data.get("current_awards", {}) as Dictionary
	current_awards = PSAwards.from_dict(awards_data) if not awards_data.is_empty() else null
	var season_data: Dictionary = data.get("season", {}) as Dictionary
	current_season = PSSeason.from_dict(season_data) if not season_data.is_empty() else null
	# 選手履歴は blob ではなく season_history テーブル側にある。
	SaveService.hydrate_season_history(current_season)
	_apply_dh_settings_to_current_schedule()
	PSDefenseAlignmentProfile.reset_cache()
	PSBattingOrderProfile.reset_cache()
	# records は record_store blob / 正規化テーブルに独立永続化されている
	# (game_state には含めない)。専用ストアから hydrate する。
	RecordStore.load_records()
	if current_season != null:
		RecordStore.ensure_season_records(current_season, GameDb.teams, GameDb.players, false)
		_prewarm_lineup_profiles()
		# 破損検知: シーズンが進んでいるのに当該シーズンの選手成績が全て0なら、過去に成績
		# レコードが空白上書きで失われたセーブの可能性が高い (2026-07-03 実発生)。ロスターは
		# 無事なので続行は可能だが、出場実績ベースの判定の質が落ちるため痕跡を警告する。
		if _season_records_look_wiped(current_season):
			push_warning("Saved season stats are all zero despite played games; this save likely lost its record data earlier.")
		if postseason_active and current_postseason != null and not PostseasonService.is_complete(current_postseason):
			PostseasonService.sync_to_next_postseason_day(current_postseason, current_season)

	var next_screen: String = str(data.get("current_screen", "home"))
	last_status_message = ""
	if current_season != null:
		next_screen = "home"
	_screen_history.clear()
	_forward_history.clear()
	SaveService.mark_state_loaded(self)
	request_screen(next_screen, false)
	return true
