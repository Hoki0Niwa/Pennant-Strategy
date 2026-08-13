extends Node

# UI 刷新作業用: セーブをロードして主要画面を順に開き、各画面のスクリーンショットを
# reports/ui_shots/ へ書き出す手動調査ツール。ウィンドウ描画が必要なので --headless では動かない。
# 実行: godot --path . res://tools/run_ui_screenshots.tscn
# 画面を絞る: -- --screens=home,standings
# 撮影前にシーズンを進める: -- --simdays=60 (開幕直後の全ゼロ表を避けて実データで確認する用。
#   auto_save_enabled を無効化した上で進めるためセーブデータへは書き込まれない)
# 既存セーブを使わない: -- --newsave (使い捨てセーブを作って撮り、終了時に削除して元のアクティブ
#   セーブへ戻す。**保存形式を変えた直後は旧セーブが読めない**ので (互換は持たない方針)、
#   その場合はこれで撮る。ユーザーのセーブに一切触れない点でも安全)
#
# 状態別撮影モード: -- --states
#   通常の画面単位撮影とは別に、選手詳細/能力・成績一覧/チーム詳細のタブ・絞り込み違いや、
#   シーズン履歴の4ビュー切替(年度別/歴代記録/タイトル履歴/スタメン履歴)、
#   シーズン終了後〜ポストシーズン〜表彰〜オフシーズン各ステップまで、これまで撮っていなかった
#   UI 状態を reports/ui_shots/states/ へ撮影する (崩れ調査用)。--simdays 未指定なら
#   STATES_DEFAULT_SIMDAYS 日分を内部で自動進行する (全ゼロ表を避けるため)。
#   セーブ・user:// への書き込みは行わない不変条件は --states でも維持する
#   (AppState.auto_save_enabled を明示的に false へ固定してから進める)。

const SaveContext = preload("res://services/storage/save_context.gd")

const OUTPUT_DIR: String = "res://reports/ui_shots"
const STATES_DIR: String = "res://reports/ui_shots/states"
const STATES_DEFAULT_SIMDAYS: int = 60

const DEFAULT_SCREENS: Array = [
	"home",
	"game_results",
	"standings",
	"rankings",
	"ability_stats",
	"farm",
	"history",
	"team_detail",
	"player_detail",
	"lineup_editor",
	"rotation_editor",
	"active_roster",
	"trade",
	"options",
]

const PLAYER_DETAIL_SCRIPT: String = "res://ui/screens/player_detail_screen.gd"
const ABILITY_STATS_SCRIPT: String = "res://ui/screens/ability_stats_screen.gd"
const TEAM_DETAIL_SCRIPT: String = "res://ui/screens/team_detail_screen.gd"
const HISTORY_SCRIPT: String = "res://ui/screens/history_screen.gd"
const FARM_SCRIPT: String = "res://ui/screens/farm_screen.gd"

# シーズン履歴: 右上チップで切り替える4ビュー (画面側 VIEW_CHIPS の key と一致させる)。
const HISTORY_VIEWS: Array = ["year", "career", "titles", "lineup"]

# 選手詳細: 下部タブ全種 (id はそのまま画面側 TABS の id と一致させる)。
const PD_TABS: Array = ["season", "games", "monthly", "usage", "stats", "farm", "advanced", "abilities", "career"]
# 投手/野手それぞれ「候補が非空になるまで」試す絞り込み id の優先順。
const PD_PITCHER_FILTER_TRY: Array = ["starter", "reliever"]
const PD_BATTER_FILTER_TRY: Array = ["pos2", "pos3", "pos4", "pos5", "pos6", "pos7", "pos8", "pos9"]

# 能力・成績一覧: 絞り込み(野手/投手) x タブ3種。
const ABILITY_FILTERS: Array = ["b_all", "p_all"]
const ABILITY_TABS: Array = ["abilities", "stats", "advanced"]

# ファーム情報: 順位ビュー + 成績ビュー(野手/投手)。
const FARM_STAT_FILTERS: Array = ["b_all", "p_all"]

var _main_node: Node = null
var _state_manifest: Array = []  # [{name, file}] 撮影順の対応表 (最後にまとめて出力)
var _throwaway_save_id: String = ""   # --newsave で作った使い捨てセーブ (終了時に削除)
var _previous_save_id: String = ""


func _ready() -> void:
	if not GameDb.data_loaded_ok:
		await GameDb.data_loaded

	if _has_flag("--newsave"):
		if not _start_throwaway_save():
			get_tree().quit(1)
			return
	else:
		var save_data: Dictionary = SaveService.load_state()
		if save_data.is_empty():
			push_error("セーブデータがありません (アクティブセーブが必要)")
			get_tree().quit(1)
			return
		if not AppState.restore_from_save(save_data):
			push_error("セーブの復元に失敗しました")
			get_tree().quit(1)
			return

	var states_mode: bool = _has_flag("--states")
	var simdays: int = _requested_simdays()
	if simdays <= 0 and states_mode:
		# --states は全ゼロ表を避けるため、--simdays 未指定でも内部で適当に進めておく。
		simdays = STATES_DEFAULT_SIMDAYS
		print("[sim] --states 指定時のデフォルトとして %d 日分を進行します (--simdays 未指定)" % simdays)
	if simdays > 0:
		# AppState.simulate_days は auto_save_enabled 経由 (persist_progress / _save_if_enabled)
		# でのみ永続化するため、無効化しておけば進行はメモリ上だけで完結しセーブへ書かれない。
		AppState.auto_save_enabled = false
		print("[sim] %d日分を進行します (auto_save 無効 = セーブへは書き込まない)" % simdays)
		var done: int = 0
		while done < simdays:
			var step: int = min(10, simdays - done)
			var result: Dictionary = AppState.simulate_days(step)
			done += step
			print("[sim] %d/%d日  %s" % [done, simdays, str(result.get("message", ""))])
			if not bool(result.get("ok", false)):
				break

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))

	var main_scene: PackedScene = load("res://ui/main.tscn") as PackedScene
	var main_node: Node = main_scene.instantiate()
	add_child(main_node)
	_main_node = main_node

	if states_mode:
		await _run_state_capture()
		_delete_throwaway_save()
		get_tree().quit(0)
		return

	var screens: Array = _requested_screens()
	for screen_value in screens:
		var screen_name: String = str(screen_value)
		AppState.request_screen(screen_name)
		# 画面の _ready / _refresh 後の描画が確定するまで数フレーム待つ。
		await _wait_frames()
		var image: Image = get_viewport().get_texture().get_image()
		var out_path: String = "%s/%s.png" % [OUTPUT_DIR, screen_name]
		var err: int = image.save_png(ProjectSettings.globalize_path(out_path))
		print("[shot] %s -> %s (%s)" % [screen_name, out_path, "ok" if err == OK else ("err %d" % err)])

	_delete_throwaway_save()
	get_tree().quit(0)


# --newsave: 既存セーブを読まず、その場で新規シーズンを作って撮る。
# 保存形式を変えたあと (旧セーブは互換を持たない方針) でも撮影ループを回せるようにするための逃げ道。
# 撮り終わったら _delete_throwaway_save で消し、元のアクティブセーブへ戻す。
func _start_throwaway_save() -> bool:
	_previous_save_id = SaveContext.active_save_id()
	var team: PSTeam = GameDb.teams[0] as PSTeam
	if team == null:
		push_error("球団データが読み込めていません")
		return false
	AppState.select_team(team.id)
	if not AppState.start_new_season():
		push_error("新規シーズンの作成に失敗しました")
		return false
	_throwaway_save_id = SaveContext.active_save_id()
	print("[save] --newsave: 使い捨てセーブ %s を作成しました (撮影後に削除します)" % _throwaway_save_id)
	return true


func _delete_throwaway_save() -> void:
	if _throwaway_save_id.is_empty():
		return
	SaveContext.delete_current_save_data()
	if _previous_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(_previous_save_id)
	print("[save] --newsave: 使い捨てセーブ %s を削除しました" % _throwaway_save_id)
	_throwaway_save_id = ""


func _requested_screens() -> Array:
	for arg_value in OS.get_cmdline_user_args():
		var arg: String = str(arg_value)
		if arg.begins_with("--screens="):
			var names: Array = []
			for token in arg.get_slice("=", 1).split(","):
				var trimmed: String = str(token).strip_edges()
				if not trimmed.is_empty():
					names.append(trimmed)
			if not names.is_empty():
				return names
	return DEFAULT_SCREENS.duplicate()


func _requested_simdays() -> int:
	for arg_value in OS.get_cmdline_user_args():
		var arg: String = str(arg_value)
		if arg.begins_with("--simdays="):
			return max(0, int(arg.get_slice("=", 1)))
	return 0


func _has_flag(flag: String) -> bool:
	for arg_value in OS.get_cmdline_user_args():
		if str(arg_value) == flag:
			return true
	return false


# ============================================================ state capture (--states)

func _wait_frames(n: int = 6) -> void:
	for i in range(n):
		await RenderingServer.frame_post_draw


# main.tscn ツリーから script パス一致でノードを探す (main.gd は画面切替のたび子を全部作り直すため
# 都度呼び出し側で再取得すること)。
func _find_screen_node(node: Node, script_path: String) -> Node:
	var scr: Script = node.get_script() as Script
	if scr != null and scr.resource_path == script_path:
		return node
	for child in node.get_children():
		var found: Node = _find_screen_node(child, script_path)
		if found != null:
			return found
	return null


func _shot(states_dir: String, name: String) -> void:
	var image: Image = get_viewport().get_texture().get_image()
	var out_path: String = "%s/%s.png" % [states_dir, name]
	var err: int = image.save_png(ProjectSettings.globalize_path(out_path))
	print("[state] %s -> %s (%s)" % [name, out_path, "ok" if err == OK else ("err %d" % err)])
	_state_manifest.append({"name": name, "file": out_path})


func _run_state_capture() -> void:
	# 不変条件の再確認: --states 中も一切セーブへ書き込まない。
	AppState.auto_save_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STATES_DIR))

	await _capture_player_detail(STATES_DIR)
	await _capture_ability_stats(STATES_DIR)
	await _capture_farm_views(STATES_DIR)
	await _capture_team_detail(STATES_DIR)
	await _capture_history_views(STATES_DIR)
	await _capture_season_progression(STATES_DIR)

	print("[state] 撮影完了: %d 枚" % _state_manifest.size())
	_print_state_manifest()


# --- 1. 選手詳細 (投手/野手 x 下部タブ全種) ---

func _capture_player_detail(states_dir: String) -> void:
	AppState.request_screen("player_detail")
	await _wait_frames()
	var pd: Node = _find_screen_node(_main_node, PLAYER_DETAIL_SCRIPT)
	if pd == null:
		print("[state] player_detail 画面ノードが見つかりません。スキップします")
		return
	await _capture_player_detail_role(pd, states_dir, "pitcher", PD_PITCHER_FILTER_TRY)
	await _capture_player_detail_role(pd, states_dir, "batter", PD_BATTER_FILTER_TRY)


func _capture_player_detail_role(pd: Node, states_dir: String, role_label: String, filters_to_try: Array) -> void:
	var chosen_filter: String = ""
	for filter_id in filters_to_try:
		pd.set("_filter_id", filter_id)
		pd.call("_rebuild_candidates")
		var candidates: Array = pd.get("_candidates") as Array
		if not candidates.is_empty():
			chosen_filter = filter_id
			break
	if chosen_filter.is_empty():
		print("[state] player_detail: %s の候補が見つからずスキップします" % role_label)
		return
	var pid: int = int(pd.call("_first_candidate_id"))
	pd.set("_player_id", pid)
	pd.call("_refresh")
	pd.call("_build_buttons")
	pd.queue_redraw()
	await _wait_frames()
	for tab_id in PD_TABS:
		pd.set("_active_tab", tab_id)
		pd.call("_build_buttons")
		pd.queue_redraw()
		await _wait_frames()
		_shot(states_dir, "player_detail_%s_%s" % [role_label, tab_id])


# --- 2. 能力・成績一覧 (絞り込み x タブ3種) ---

func _capture_ability_stats(states_dir: String) -> void:
	AppState.request_screen("ability_stats")
	await _wait_frames()
	var asc: Node = _find_screen_node(_main_node, ABILITY_STATS_SCRIPT)
	if asc == null:
		print("[state] ability_stats 画面ノードが見つかりません。スキップします")
		return
	for filter_id in ABILITY_FILTERS:
		asc.call("_on_filter_pressed", filter_id)
		await _wait_frames()
		for tab_id in ABILITY_TABS:
			asc.call("_on_tab_pressed", tab_id)
			await _wait_frames()
			_shot(states_dir, "ability_stats_%s_%s" % [filter_id, tab_id])


# --- 2b. ファーム情報 (順位 / 成績の野手・投手) ---

func _capture_farm_views(states_dir: String) -> void:
	AppState.request_screen("farm")
	await _wait_frames()
	var fs: Node = _find_screen_node(_main_node, FARM_SCRIPT)
	if fs == null:
		print("[state] farm 画面ノードが見つかりません。スキップします")
		return
	fs.call("_on_view_pressed", fs.get("VIEW_STANDINGS"))
	await _wait_frames()
	_shot(states_dir, "farm_standings")
	fs.call("_on_view_pressed", fs.get("VIEW_STATS"))
	await _wait_frames()
	for filter_id in FARM_STAT_FILTERS:
		fs.call("_on_filter_pressed", filter_id)
		await _wait_frames()
		_shot(states_dir, "farm_stats_%s" % filter_id)


# --- 3. チーム詳細 (自軍以外を各リーグ1球団ずつ) ---

func _capture_team_detail(states_dir: String) -> void:
	AppState.request_screen("team_detail")
	await _wait_frames()
	var td: Node = _find_screen_node(_main_node, TEAM_DETAIL_SCRIPT)
	if td == null:
		print("[state] team_detail 画面ノードが見つかりません。スキップします")
		return
	var team_ids: Array = td.get("_team_ids") as Array
	var picked_leagues: Dictionary = {}
	var targets: Array = []
	for id_value in team_ids:
		var tid: int = int(id_value)
		if tid == AppState.selected_team_id:
			continue
		var team: PSTeam = GameDb.get_team(tid)
		if team == null or picked_leagues.has(team.league):
			continue
		picked_leagues[team.league] = true
		targets.append(tid)
		if targets.size() >= 2:
			break
	if targets.is_empty():
		for id_value in team_ids:
			if int(id_value) != AppState.selected_team_id:
				targets.append(int(id_value))
				break
	# 自軍のデプスチャートページ (獲得判断用の2ページ目)。
	td.call("_set_page", "depth")
	await _wait_frames()
	_shot(states_dir, "team_detail_depth_self")
	td.call("_set_page", "overview")
	await _wait_frames()

	for tid in targets:
		td.call("_on_team_selected", tid)
		await _wait_frames()
		var team: PSTeam = GameDb.get_team(tid)
		var league: String = team.league if team != null else "unknown"
		_shot(states_dir, "team_detail_team%d_%s" % [tid, league])
		td.call("_set_page", "depth")
		await _wait_frames()
		_shot(states_dir, "team_detail_depth_team%d" % tid)
		td.call("_set_page", "overview")
		await _wait_frames()


# --- 4. シーズン履歴 (4ビュー切替) ---

func _capture_history_views(states_dir: String) -> void:
	AppState.request_screen("history")
	await _wait_frames()
	var hs: Node = _find_screen_node(_main_node, HISTORY_SCRIPT)
	if hs == null:
		print("[state] history 画面ノードが見つかりません。スキップします")
		return
	for view_key in HISTORY_VIEWS:
		hs.call("_set_view", view_key)
		await _wait_frames()
		_shot(states_dir, "history_%s" % view_key)


# --- 5. シーズン終了 -> ポストシーズン -> 表彰 -> オフシーズン ---

func _capture_season_progression(states_dir: String) -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		print("[state] current_season がありません。シーズン終了以降の撮影をスキップします")
		return

	if not season.is_finished():
		print("[sim] --states: シーズン最終日まで消化します (数分かかる場合があります)")
		var sim_result: Dictionary = AppState.simulate_remaining_season()
		if not bool(sim_result.get("ok", false)):
			print("[state] シーズン消化に失敗したため以降の撮影を打ち切ります: %s" % str(sim_result.get("message", "")))
			return

	AppState.request_screen("home")
	await _wait_frames()
	_shot(states_dir, "season_end_home")

	# --- ポストシーズン ---
	# このセーブが以前のプレイで既にポストシーズンを完了済み (current_postseason が complete) の場合、
	# start_postseason() は「既に完了しています」で失敗する。これはロード時点の正常な状態でありエラー
	# ではないため、開始/進行中の状態撮影はスキップしつつ、既存の完了済みポストシーズンのまま
	# 表彰・オフシーズンの撮影へ進む (ここでロジックをハックして状態をリセットすることはしない)。
	var postseason_already_complete: bool = AppState.current_postseason != null and PostseasonService.is_complete(AppState.current_postseason)
	if not postseason_already_complete:
		var ps_result: Dictionary = AppState.start_postseason()
		if not bool(ps_result.get("ok", false)):
			print("[state] ポストシーズン開始に失敗したため以降の撮影を打ち切ります: %s" % str(ps_result.get("message", "")))
			return
		await _wait_frames()
		_shot(states_dir, "postseason_initial_home")

		var captured_stages: int = 0
		while captured_stages < 3 and not PostseasonService.is_complete(AppState.current_postseason):
			var adv: Dictionary = AppState.advance_next_postseason_stage()
			if not bool(adv.get("ok", false)):
				print("[state] ポストシーズン進行が停止しました (%d件撮影済み): %s" % [captured_stages, str(adv.get("message", ""))])
				break
			AppState.request_screen("home")
			await _wait_frames()
			captured_stages += 1
			_shot(states_dir, "postseason_stage%d_home" % captured_stages)

		# 撮影は2〜3件で打ち切るが、表彰・オフシーズンへ進むため裏で完了まで進行させる (無撮影)。
		var guard: int = 0
		while not PostseasonService.is_complete(AppState.current_postseason) and guard < 10:
			guard += 1
			var adv2: Dictionary = AppState.advance_next_postseason_stage()
			if not bool(adv2.get("ok", false)):
				print("[state] ポストシーズン完了処理に失敗しました: %s" % str(adv2.get("message", "")))
				break
	else:
		print("[state] このセーブは既にポストシーズンが完了済みのため、開始/進行中の状態撮影はスキップします")

	if not PostseasonService.is_complete(AppState.current_postseason):
		print("[state] ポストシーズンが完了しなかったため 表彰/オフシーズン の撮影を打ち切ります")
		return

	# --- 表彰 ---
	var final_result: Dictionary = AppState.finalize_postseason_to_awards()
	if not bool(final_result.get("ok", false)):
		print("[state] 表彰確定に失敗したためオフシーズンの撮影を打ち切ります: %s" % str(final_result.get("message", "")))
		return
	await _wait_frames()
	_shot(states_dir, "awards")

	# --- オフシーズン ---
	var off_result: Dictionary = AppState.start_offseason()
	if not bool(off_result.get("ok", false)):
		print("[state] オフシーズン開始に失敗しました: %s" % str(off_result.get("message", "")))
		return
	await _wait_frames()
	await _capture_offseason_steps(states_dir)


# オフシーズンの各ステップを、対話ステップは AppState の complete_*_automatically / finish_camp で
# 自動消化しながら advance_offseason() で進め、ステップごとに (対話UI/結果UIそれぞれ) 撮影する。
func _capture_offseason_steps(states_dir: String) -> void:
	var guard: int = 0
	while guard < 40:
		guard += 1
		AppState.request_screen("home")
		await _wait_frames()
		var view: Dictionary = AppState.get_offseason_view_state()
		if not bool(view.get("active", false)):
			print("[state] オフシーズンが非アクティブになったため撮影を打ち切ります")
			return
		var step: String = str(view.get("step", ""))
		var interactive: bool = bool(view.get("is_interactive", false))
		var panel: String = str(view.get("active_panel", ""))
		# ステップID自体をファイル名ラベルに使う。番号順は AppState.OFFSEASON_STEP_ORDER の index。
		var label: String = step
		# 外国人ステップは契約市場/契約結果/スカウト/スカウト結果の4フェーズが同じ step なので、
		# ファイル名が衝突して前段の撮影が上書きされないようラベルを分ける。
		if interactive and panel == AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT:
			label = "foreign_contract"
		elif interactive and panel == AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT:
			label = "foreign_contract_result"
		elif interactive and panel == AppState.OFFSEASON_PANEL_FOREIGN_RESULT:
			label = "foreign_scout_result"
		var suffix: String = "editor" if interactive else "result"
		var step_number: int = AppState.OFFSEASON_STEP_ORDER.find(step)
		_shot(states_dir, "offseason_step%02d_%s_%s" % [step_number, label, suffix])

		if interactive:
			var action_result: Dictionary = {"ok": false, "message": "未対応の active_panel"}
			if panel == AppState.OFFSEASON_PANEL_RELEASE:
				action_result = AppState.commit_release([])
			elif panel == AppState.OFFSEASON_PANEL_DRAFT:
				action_result = AppState.complete_draft_automatically()
			elif panel == AppState.OFFSEASON_PANEL_RELEASED_MARKET:
				action_result = AppState.complete_released_market_automatically()
			elif panel == AppState.OFFSEASON_PANEL_GENEKI_DRAFT:
				action_result = AppState.complete_geneki_draft_automatically()
			elif panel == AppState.OFFSEASON_PANEL_FA:
				action_result = AppState.complete_fa_automatically()
			elif panel == AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT:
				action_result = AppState.finalize_foreign_contract_market()
			elif panel == AppState.OFFSEASON_PANEL_FOREIGN_CONTRACT_RESULT:
				action_result = AppState.advance_foreign_contract_result()
			elif panel == AppState.OFFSEASON_PANEL_FOREIGN:
				action_result = AppState.complete_foreign_automatically()
			elif panel == AppState.OFFSEASON_PANEL_FOREIGN_RESULT:
				action_result = AppState.advance_foreign_scout_result()
			elif panel == AppState.OFFSEASON_PANEL_CONTRACT_YEARS:
				# 自軍分をAI基準で埋めてから確定する (UI の「自動で決めて次へ」と同じ経路)。
				AppState.auto_decide_contract_years()
				action_result = AppState.finalize_contract_years()
			elif panel == AppState.OFFSEASON_PANEL_CAMP:
				action_result = AppState.finish_camp()
			if not bool(action_result.get("ok", false)):
				print("[state] ステップ%s (%s) の自動消化に失敗したため打ち切ります: %s" % [step, panel, str(action_result.get("message", ""))])
				return
			continue

		if bool(view.get("can_finalize", false)):
			print("[state] オフシーズン最終ステップまで撮影しました (「翌年開始」は行いません)")
			return
		if bool(view.get("can_advance", false)):
			var adv: Dictionary = AppState.advance_offseason()
			if not bool(adv.get("ok", false)):
				print("[state] advance_offseason に失敗したため打ち切ります: %s" % str(adv.get("message", "")))
				return
			continue

		print("[state] オフシーズンの進行が停止しました (advance/finalize いずれも不可)")
		return
	print("[state] オフシーズン撮影がガード回数の上限に達したため打ち切ります")


func _print_state_manifest() -> void:
	print("---- state screenshot manifest (%d) ----" % _state_manifest.size())
	for entry_value in _state_manifest:
		var entry: Dictionary = entry_value as Dictionary
		print("%s :: %s" % [str(entry.get("name", "")), str(entry.get("file", ""))])
