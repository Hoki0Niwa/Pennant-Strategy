extends Node

# セーブをロードして主要画面を順に開き、各画面のスクリーンショットを
# reports/ui_shots/ へ書き出す手動調査ツール。ウィンドウ描画が必要なので --headless では動かない。
# 実行: godot --path . res://tools/run_ui_screenshots.tscn
# 画面を絞る: -- --screens=home,standings
# 撮影前にシーズンを進める: -- --simdays=60 (開幕直後の全ゼロ表を避けて実データで確認する用。
#   auto_save_enabled を無効化した上で進めるためセーブデータへは書き込まれない)
# 既存セーブを使わない: -- --newsave (使い捨てセーブを作って撮り、終了時に削除して元のアクティブ
#   セーブへ戻す。**保存形式を変えた直後は旧セーブが読めない**ので (互換は持たない方針)、
#   その場合はこれで撮る。ユーザーのセーブに一切触れない点でも安全)
# 返事待ちのトレード提案がある状態で撮る: -- --tradeoffer
# 共通選手表だけを2解像度で撮る: -- --newsave --player-tables
# シーズン総括の状態別撮影: -- --newsave --season-reviews
# ドラフト回顧の状態別撮影: -- --draft-reviews (使い捨てセーブ、APPDATA scratch 必須)
#
# 状態別撮影モード: -- --states
#   通常の画面単位撮影とは別に、選手詳細/能力・成績一覧/チーム詳細のタブ・絞り込み違いや、
#   シーズン履歴の4ビュー切替(年度別/歴代記録/タイトル履歴/スタメン履歴)、順位表の貯金グラフのホバー、
#   シーズン終了後〜ポストシーズン〜表彰〜オフシーズン各ステップまで、これまで撮っていなかった
#   UI 状態を reports/ui_shots/states/ へ撮影する (崩れ調査用)。--simdays 未指定なら
#   STATES_DEFAULT_SIMDAYS 日分を内部で自動進行する (全ゼロ表を避けるため)。
#   セーブ・user:// への書き込みは行わない不変条件は --states でも維持する
#   (AppState.auto_save_enabled を明示的に false へ固定してから進める)。

const SaveContext = preload("res://services/storage/save_context.gd")

const OUTPUT_DIR: String = "res://reports/ui_shots"
const STATES_DIR: String = "res://reports/ui_shots/states"
const STATES_DEFAULT_SIMDAYS: int = 60
const PLAYER_TABLES_DIR: String = "res://reports/ui_shots/player_tables"
const SEASON_REVIEWS_DIR: String = "res://reports/ui_shots/season_reviews"
const DRAFT_REVIEWS_DIR: String = "res://reports/ui_shots/draft_reviews"


class PlayerTablePreview extends "res://ui/screens/offseason_screen.gd":
	var fixture: Dictionary = {}

	func _ready() -> void:
		_init_chrome()
		_build_nav_buttons()

	func _draw() -> void:
		_update_transform()
		draw_rect(Rect2(Vector2.ZERO, size), BG, true)
		_row_hits.clear()
		_scroll_zones.clear()
		_draw_shell(str(fixture.get("title", "Player tables")), GameDb.get_team(AppState.selected_team_id), AppState.current_season)
		var rows: Array = fixture.get("rows", []) as Array
		var pitcher: bool = bool(fixture.get("pitcher", false))
		var historical: bool = bool(fixture.get("historical", false))
		var mode: String = str(fixture.get("mode", ""))
		var selection_kind: String = str(fixture.get("selection", ""))
		_draw_player_record_table(BODY, str(fixture.get("title", "")), rows, pitcher,
			selection_kind, "preview", "", 0, Loc.t("offseason.empty.players"), false,
			false, mode, not historical, bool(fixture.get("offer_years", false)), historical)

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
const STANDINGS_SCRIPT: String = "res://ui/screens/standings_screen.gd"
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

	if _has_flag("--newsave") or _has_flag("--draft-reviews"):
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

	if _has_flag("--draft-reviews"):
		await _capture_draft_reviews()
		_delete_throwaway_save()
		get_tree().quit(0)
		return

	if _has_flag("--season-reviews"):
		await _capture_season_reviews()
		_delete_throwaway_save()
		get_tree().quit(0)
		return

	if _has_flag("--player-tables"):
		await _capture_player_tables()
		_delete_throwaway_save()
		get_tree().quit(0)
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

	if _has_flag("--tradeoffer"):
		_inject_trade_offer()

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


func _capture_draft_reviews() -> void:
	AppState.auto_save_enabled = false
	var old_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var was_suspended: bool = RecordStore.is_persistence_suspended()
	RecordStore.suspend_persistence()
	var old_view: Dictionary = AppState.draft_review_view_state.duplicate(true)
	var old_screen: String = AppState.current_screen
	var statuses: Array = []
	for index in 6:
		var player: PSPlayer = GameDb.players[index] as PSPlayer
		statuses.append({"player": player, "team_id": player.team_id, "source_data": player.source_data.duplicate(true)})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DRAFT_REVIEWS_DIR))
	var viewport: SubViewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	for dimensions: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		viewport.size = dimensions
		for scenario: String in ["normal", "just_drafted", "unplayed", "missing_roster", "zero_picks", "transferred", "overseas", "retired", "long_name", "many_rows", "other_team"]:
			RecordStore.clear_records()
			for status: Dictionary in statuses:
				var player: PSPlayer = status["player"] as PSPlayer
				player.team_id = int(status["team_id"])
				player.source_data = (status["source_data"] as Dictionary).duplicate(true)
			_draft_review_fixture(scenario)
			AppState.current_screen = "draft_retrospective"
			AppState.draft_review_view_state = {"save_id": SaveContext.active_save_id(), "year": 2040, "season_number": 15,
				"team_id": (GameDb.teams[1] as PSTeam).id if scenario == "other_team" else AppState.selected_team_id,
				"kind": "main", "scope": "all", "scroll": {}}
			var screen: Control = load("res://ui/screens/draft_retrospective_screen.gd").new()
			screen.size = Vector2(dimensions)
			viewport.add_child(screen)
			await get_tree().process_frame
			await get_tree().process_frame
			if scenario != "missing_roster" and scenario != "zero_picks" and scenario != "other_team":
				screen.call("_select_player", (GameDb.players[0] as PSPlayer).id)
			await RenderingServer.frame_post_draw
			var shot_name: String = "%s_%dx%d" % [scenario, dimensions.x, dimensions.y]
			var path: String = "%s/%s.png" % [DRAFT_REVIEWS_DIR, shot_name]
			var err: Error = viewport.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
			print("[draft-review] %s: %s" % [path, error_string(err)])
			_state_manifest.append({"name": shot_name, "file": path})
			if scenario == "many_rows":
				screen._scroll["main"] = 5
				screen.queue_redraw()
				await RenderingServer.frame_post_draw
				screen.call("_remember_view")
				var scrolled_path: String = "%s/many_rows_scrolled_%dx%d.png" % [DRAFT_REVIEWS_DIR, dimensions.x, dimensions.y]
				viewport.get_texture().get_image().save_png(ProjectSettings.globalize_path(scrolled_path))
				_state_manifest.append({"name": "many_rows_scrolled", "file": scrolled_path})
			if scenario == "normal" or scenario == "long_name" or scenario == "many_rows" or scenario == "transferred":
				for variant: String in (["draft_team"] if scenario == "transferred" else ["development", "draft_team"]):
					if variant == "draft_team":
						screen.call("_set_scope", "team")
					else:
						screen.call("_set_kind", variant)
					await get_tree().process_frame
					await RenderingServer.frame_post_draw
					var variant_name: String = "%s_%s_%dx%d" % [scenario, variant, dimensions.x, dimensions.y]
					var variant_path: String = "%s/%s.png" % [DRAFT_REVIEWS_DIR, variant_name]
					var variant_err: Error = viewport.get_texture().get_image().save_png(ProjectSettings.globalize_path(variant_path))
					print("[draft-review] %s: %s" % [variant_path, error_string(variant_err)])
					_state_manifest.append({"name": variant_name, "file": variant_path})
			screen.queue_free()
			await get_tree().process_frame
	viewport.queue_free()
	for status: Dictionary in statuses:
		var player: PSPlayer = status["player"] as PSPlayer
		player.team_id = int(status["team_id"])
		player.source_data = status["source_data"] as Dictionary
	RecordStore.load_from_dict(old_records)
	if not was_suspended:
		RecordStore.resume_persistence()
	AppState.draft_review_view_state = old_view
	AppState.current_screen = old_screen
	await get_tree().process_frame
	_print_state_manifest()


func _draft_review_fixture(scenario: String) -> void:
	var picks: Array = []
	var teams: Array = []
	for team: PSTeam in GameDb.teams:
		if not team.farm_only:
			teams.append({"team_id": team.id, "team_name": team.name, "controlled_count": 0, "development_count": 0})
	var count: int = 48 if scenario == "many_rows" else 6
	for index in count:
		var player: PSPlayer = GameDb.players[index % 6] as PSPlayer
		var team: PSTeam = GameDb.teams[1 if index == 5 else 0] as PSTeam
		if scenario == "zero_picks":
			team = GameDb.teams[1] as PSTeam
		var pitcher: bool = index % 3 == 2
		var development: bool = index % 2 == 1
		picks.append({"player_id": player.id if index < 6 else -98000 - index, "team_id": team.id, "team_name": team.name,
			"round": int(float(index) / 2.0) + 1, "overall_pick": index + 1, "development": development,
			"name": "東西南北大和武蔵相模太郎".repeat(5) + str(index) if scenario == "long_name" else player.name,
			"age": 18 + index % 6, "role": "starter" if pitcher else "fielder", "position": 1 if pitcher else 6,
			"source_type": "high_school", "first_eligible_year": 2041, "first_eligible_season_number": 16})
		for row: Dictionary in teams:
			if int(row["team_id"]) == team.id:
				var key: String = "development_count" if development else "controlled_count"
				row[key] = int(row[key]) + 1
	if scenario != "missing_roster":
		RecordStore.add_draft_class(PSDraftClass.from_dict({"year": 2040, "season_number": 15,
			"first_eligible_year": 2041, "first_eligible_season_number": 16, "teams": teams, "picks": picks}))
	var selected: PSPlayer = GameDb.players[0] as PSPlayer
	if scenario == "transferred":
		selected.team_id = (GameDb.teams[1] as PSTeam).id
	elif scenario == "overseas" or scenario == "retired":
		selected.team_id = 0
		selected.source_data["retired"] = true
		selected.source_data[PSPlayer.SOURCE_KEY_OVERSEAS_YEAR] = 2042 if scenario == "overseas" else 0
	if scenario == "just_drafted":
		return
	for year in [2041, 2042]:
		var facts: Array = []
		for pick: Dictionary in picks:
			if scenario == "unplayed":
				continue
			var pitcher: bool = str(pick["role"]) == "starter"
			var total: Dictionary = {"war": 1.25, "batter_stats": {} if pitcher else {"games": 100, "plate_appearances": 400,
				"at_bats": 350, "hits": 100, "doubles": 20, "home_runs": 10, "walks": 45, "runs_batted_in": 50},
				"pitcher_stats": {"games": 20, "outs_pitched": 300, "earned_runs": 32, "strikeouts": 95,
					"walks": 30, "hits_allowed": 85, "wins": 8} if pitcher else {}}
			var by_team: Dictionary = {str(pick["team_id"]): total.duplicate(true)}
			if scenario == "transferred":
				by_team[str(pick["team_id"])] = {"war": 0.25, "batter_stats": {"games": 10, "plate_appearances": 40, "at_bats": 35, "hits": 10}, "pitcher_stats": {}}
			facts.append({"player_id": pick["player_id"], "name": pick["name"], "role": pick["role"], "position": pick["position"],
				"age": int(pick["age"]) + year - 2040, "team_id": pick["team_id"], "total": total, "teams": by_team})
		RecordStore.add_season_review(PSSeasonReview.from_dict({"year": year, "season_number": year - 2025,
			"completion_kind": "regular_season", "teams": [], "player_facts": facts}))


func _capture_season_reviews() -> void:
	AppState.auto_save_enabled = false
	RecordStore.suspend_persistence()
	var old_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var old_view: Dictionary = AppState.season_review_view_state.duplicate(true)
	var old_screen: String = AppState.current_screen
	var old_locale: Dictionary = Loc._table.duplicate(true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SEASON_REVIEWS_DIR))
	var viewport: SubViewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	for dimensions: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		viewport.size = dimensions
		for scenario: String in ["normal", "previous", "no_postseason", "empty", "no_awards", "negative_war", "long_text", "many_awards", "other_team", "pitcher"]:
			RecordStore.clear_records()
			Loc._table = old_locale.duplicate(true)
			if scenario != "empty":
				var review: PSSeasonReview = _season_review_fixture(scenario)
				RecordStore.add_season_review(review)
			if scenario == "long_text":
				Loc._table["season_review.fact.record"] = "{team} ".repeat(90) + "{rank} / {wins} / {losses} / {draws}"
			AppState.current_screen = "season_review"
			AppState.season_review_view_state = {"save_id": SaveContext.active_save_id(), "team_id": AppState.selected_team_id,
				"tab": "pitcher" if scenario == "pitcher" else "fielder", "scroll": {}}
			if scenario == "other_team":
				AppState.season_review_view_state["team_id"] = (GameDb.teams[1] as PSTeam).id
			var screen: Control = load("res://ui/screens/season_review_screen.gd").new()
			screen.size = Vector2(dimensions)
			viewport.add_child(screen)
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var shot_name: String = "%s_%dx%d" % [scenario, dimensions.x, dimensions.y]
			var path: String = "%s/%s.png" % [SEASON_REVIEWS_DIR, shot_name]
			var err: Error = viewport.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
			print("[season-review] %s: %s" % [path, error_string(err)])
			_state_manifest.append({"name": shot_name, "file": path})
			screen.queue_free()
			await get_tree().process_frame
	viewport.queue_free()
	Loc._table = old_locale
	RecordStore.load_from_dict(old_records)
	RecordStore.resume_persistence()
	AppState.season_review_view_state = old_view
	AppState.current_screen = old_screen
	await get_tree().process_frame
	_print_state_manifest()


func _season_review_fixture(scenario: String) -> PSSeasonReview:
	var year: int = 2041
	var number: int = 16
	var season: PSSeason = PSSeason.new()
	season.year = year
	season.season_number = number
	var records: Array = []
	for index in 6:
		var team: PSTeam = GameDb.teams[index % 2] as PSTeam
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		record.player_id = (GameDb.players[index] as PSPlayer).id
		record.name = "Very long frozen player name %d" % index if scenario == "long_text" else "Contributor %d" % index
		record.team_id = team.id
		record.year = year
		record.season_number = number
		record.role = "starter" if index >= 4 else "fielder"
		record.position = 1 if index >= 4 else 6
		record.age = 22 + index
		if index >= 4:
			record.pitcher_stats = PSPitcherStats.from_dict({"games": 25, "starts": 25, "outs_pitched": 450, "earned_runs": 35,
				"strikeouts": 140, "walks": 40, "hits_allowed": 120, "home_runs_allowed": 10, "wins": 12, "losses": 5})
		else:
			record.batter_stats = PSBatterStats.from_dict({"games": 140, "plate_appearances": 550, "at_bats": 480, "hits": 145,
				"doubles": 30, "home_runs": 22, "walks": 60, "runs_batted_in": 80, "strikeouts": 80})
		records.append(record.to_dict())
	RecordStore.load_from_dict({"player_records": records})
	for team: PSTeam in GameDb.teams:
		season.standings[team.id] = PSStats.from_dict({"games": 143, "wins": 82 if team.id == AppState.selected_team_id else 65,
			"losses": 58 if team.id == AppState.selected_team_id else 75, "draws": 3, "runs_scored": 580, "runs_allowed": 510})
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.year = year
	archive.season_number = number
	archive.awards = PSAwards.new()
	if scenario != "no_postseason":
		archive.postseason = PSPostseasonResult.new()
		archive.postseason.champion_team_id = AppState.selected_team_id
	if scenario != "no_awards":
		archive.awards.mvp_league1_player_id = (GameDb.players[0] as PSPlayer).id
		archive.awards.rookie_league1_player_id = (GameDb.players[0] as PSPlayer).id
		if scenario == "many_awards":
			for category: String in PSAwards.BATTING_CATEGORIES:
				if not archive.awards.batting_titles.has("league1"):
					archive.awards.batting_titles["league1"] = {}
				archive.awards.batting_titles["league1"][category] = (GameDb.players[0] as PSPlayer).id
			archive.awards.best_nine["league1"] = []
			for slot in PSAwards.BEST_NINE_SLOT_POSITIONS:
				archive.awards.best_nine["league1"].append({"pid": (GameDb.players[0] as PSPlayer).id, "value": str(slot)})
	var previous: PSSeasonReview = null
	if scenario == "previous":
		var previous_season: PSSeason = PSSeason.from_dict(season.to_dict())
		previous_season.year -= 1
		previous_season.season_number -= 1
		previous = PSSeasonReviewService.build(previous_season, GameDb.teams)
	var review: PSSeasonReview = PSSeasonReviewService.build(season, GameDb.teams, previous,
		"regular_season" if scenario == "no_postseason" else "postseason", archive)
	var payload: Dictionary = review.to_dict()
	if scenario == "negative_war":
		for team: Dictionary in payload["teams"]:
			for kind: String in ["contributors_fielder", "contributors_pitcher"]:
				for contributor: Dictionary in team[kind]:
					contributor["war"] = -2.0
					contributor["stats"]["war"] = -2.0
			team["facts"] = PSSeasonReviewService._sentence_facts(team)
	return PSSeasonReview.from_dict(JSON.parse_string(JSON.stringify(payload)) as Dictionary)


func _capture_player_tables() -> void:
	AppState.auto_save_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PLAYER_TABLES_DIR))
	var preview: PlayerTablePreview = PlayerTablePreview.new()
	var viewport: SubViewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.add_child(preview)
	var fixtures: Array = _player_table_fixtures(preview)
	for dimensions: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		viewport.size = dimensions
		preview.size = Vector2(dimensions)
		for fixture_value: Dictionary in fixtures:
			preview.fixture = fixture_value
			preview.selected_release_ids.clear()
			preview.selected_demote_ids.clear()
			var fixture_rows: Array = fixture_value.get("rows", []) as Array
			if str(fixture_value.get("selection", "")) == "release" and fixture_rows.size() > 1:
				preview.selected_release_ids[(fixture_rows[0]["record"] as PSPlayerSeasonRecord).player_id] = true
				preview.selected_demote_ids[(fixture_rows[1]["record"] as PSPlayerSeasonRecord).player_id] = true
			preview.set("_scroll", {"preview": int(fixture_value.get("offset", 0))})
			preview.queue_redraw()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var shot_name: String = "%s_%dx%d" % [str(fixture_value["id"]), dimensions.x, dimensions.y]
			var out_path: String = "%s/%s.png" % [PLAYER_TABLES_DIR, shot_name]
			var image: Image = viewport.get_texture().get_image()
			var err: int = image.save_png(ProjectSettings.globalize_path(out_path))
			print("[player-table] %s -> %s (%s)" % [shot_name, out_path, "ok" if err == OK else ("err %d" % err)])
			_state_manifest.append({"name": shot_name, "file": out_path})
	viewport.queue_free()
	await get_tree().process_frame
	_print_state_manifest()


func _player_table_fixtures(preview: PlayerTablePreview) -> Array:
	var fixtures: Array = []
	for pitcher: bool in [false, true]:
		var current_rows: Array = []
		for player_value in GameDb.players:
			var player: PSPlayer = player_value as PSPlayer
			if player == null or player.is_retired() or player.team_id != AppState.selected_team_id or player.is_pitcher() != pitcher:
				continue
			var record: PSPlayerSeasonRecord = preview.call("_record_for_people_entry", {"player_id": player.id}) as PSPlayerSeasonRecord
			if record == null:
				continue
			current_rows.append({"record": record, "player": player, "entry": {
				"player_id": player.id, "team_id": player.team_id, "new_salary": record.salary,
				"salary_delta": 500, "contract_years": 3, "fgc_years": 3, "offer_years": 3,
				"market_salary_text": "1.20", "fgc_current_salary_text": "0.85",
				"offer_text": Loc.t("offseason.single_year"), "offer_color": Color(0.4, 0.7, 1.0),
			}})
			if current_rows.size() >= 8:
				break
		var suffix: String = "pitcher" if pitcher else "fielder"
		for profile: Dictionary in [
			{"id": "contract", "title": "契約更改", "mode": "contract", "selection": ""},
			{"id": "fa", "title": "FA 提示", "mode": "", "selection": "fa", "offer_years": true},
			{"id": "release", "title": "戦力外", "mode": "", "selection": "release"},
		]:
			var fixture: Dictionary = profile.duplicate(true)
			fixture["id"] = "current_%s_%s" % [str(profile["id"]), suffix]
			fixture["rows"] = current_rows
			fixture["pitcher"] = pitcher
			fixtures.append(fixture)

		var history_rows: Array = []
		for index in range(42):
			var identity: Dictionary = {
				"player_id": 900000 + index + (100 if pitcher else 0), "team_id": AppState.selected_team_id,
				"team_name": "指名球団", "source_type": "high_school" if index % 2 == 0 else "farm_club",
				"name": "非常に長い名前の選手アルベルト・フェルナンデス" if index == 0 else "回顧 選手%02d" % index,
				"age": 18 + index % 7, "position": 1 if pitcher else 2 + index % 8,
				"role": "starter" if pitcher else "", "round": index + 1,
				"development": index % 3 == 0, "year": 2027, "season_number": 2,
			}
			var totals: Dictionary = {}
			if index != 1:
				if pitcher:
					totals = {"pitcher_stats": {"games": 45, "starts": 30, "wins": 17, "losses": 8,
						"outs_pitched": 617, "earned_runs": 61, "hits_allowed": 174, "walks": 45, "strikeouts": 192},
						"war": 5.7, "fip": 2.82}
				else:
					totals = {"batter_stats": {"games": 140, "plate_appearances": 600, "at_bats": 520,
						"hits": 160, "doubles": 32, "triples": 4, "home_runs": 24, "runs_batted_in": 88,
						"walks": 68, "hit_by_pitches": 6, "sacrifice_flies": 6, "stolen_bases": 15},
						"war": 4.8, "wrc_plus": 142.0, "woba": 0.382, "oaa": 5.6}
			history_rows.append(PSPlayerRecordTableRow.from_history(identity, totals))
		for profile: Dictionary in [
			{"id": "rows", "rows": history_rows.slice(0, 4), "offset": 0},
			{"id": "many", "rows": history_rows, "offset": 0},
			{"id": "scroll", "rows": history_rows, "offset": 17},
			{"id": "empty", "rows": [], "offset": 0},
		]:
			var fixture: Dictionary = profile.duplicate()
			fixture.merge({"id": "history_%s_%s" % [str(profile["id"]), suffix],
				"title": "2027–2031 指名選手の期間成績", "mode": "draft_history",
				"pitcher": pitcher, "historical": true}, true)
			fixtures.append(fixture)
	return fixtures


# --tradeoffer: 自軍宛ての返事待ちトレード提案を 1 件仕込む (サイドバーのバッジ、ホームの通知ボタン、
# トレード画面の提案カードの撮影用)。交換期限内でないと通知は出ないので --simdays は 120 未満にする。
func _inject_trade_offer() -> void:
	var season: PSSeason = AppState.current_season
	if season == null:
		return
	var user_player: PSPlayer = null
	var cpu_player: PSPlayer = null
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or not TradeService.is_tradeable(player, season.year):
			continue
		if player.team_id == AppState.selected_team_id:
			if user_player == null:
				user_player = player
		elif cpu_player == null:
			cpu_player = player
	if user_player == null or cpu_player == null:
		return
	var state: Dictionary = TradeService.trade_state(season)
	(state["user_offers"] as Array).append({
		"id": int(state.get("next_offer_id", 1)), "status": "pending",
		"day": season.current_day, "expires_day": season.current_day + TradeService.OFFER_EXPIRY_DAYS,
		"cpu_team_id": cpu_player.team_id,
		"cpu_player_ids": [cpu_player.id], "user_player_ids": [user_player.id],
		"cpu_player_names": [cpu_player.name], "user_player_names": [user_player.name],
	})
	state["next_offer_id"] = int(state.get("next_offer_id", 1)) + 1
	print("[trade] 返事待ちの提案を 1 件仕込みました")


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


func _shot(states_dir: String, shot_name: String) -> void:
	var image: Image = get_viewport().get_texture().get_image()
	var out_path: String = "%s/%s.png" % [states_dir, shot_name]
	var err: int = image.save_png(ProjectSettings.globalize_path(out_path))
	print("[state] %s -> %s (%s)" % [shot_name, out_path, "ok" if err == OK else ("err %d" % err)])
	_state_manifest.append({"name": shot_name, "file": out_path})


func _run_state_capture() -> void:
	# 不変条件の再確認: --states 中も一切セーブへ書き込まない。
	AppState.auto_save_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STATES_DIR))

	await _capture_player_detail(STATES_DIR)
	await _capture_ability_stats(STATES_DIR)
	await _capture_farm_views(STATES_DIR)
	await _capture_team_detail(STATES_DIR)
	await _capture_history_views(STATES_DIR)
	await _capture_standings_hover(STATES_DIR)
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


# --- 4b. 順位表 (貯金グラフのホバー) ---

# 貯金グラフのツールチップはマウス移動でしか出ないので、ホバー中の日付を直接入れて描かせる。
func _capture_standings_hover(states_dir: String) -> void:
	AppState.request_screen("standings")
	await _wait_frames()
	var st: Node = _find_screen_node(_main_node, STANDINGS_SCRIPT)
	if st == null:
		print("[state] standings 画面ノードが見つかりません。スキップします")
		return
	var geo: Dictionary = st.call("_chart_geometry") as Dictionary
	st.set("_chart_hover_day", max(1, int(float(geo.get("max_day", 7)) * 0.6)))
	st.call("queue_redraw")
	await _wait_frames()
	_shot(states_dir, "standings_balance_hover")
	st.set("_chart_hover_day", -1)
	st.call("queue_redraw")
	await _wait_frames()


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
		# 人的補償もプロテクト提出と指名の2フェーズが同じ step なのでラベルを分ける。
		elif interactive and panel == AppState.OFFSEASON_PANEL_COMPENSATION_PROTECT:
			label = "compensation_protect"
		elif interactive and panel == AppState.OFFSEASON_PANEL_COMPENSATION_PICK:
			label = "compensation_pick"
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
			elif panel == AppState.OFFSEASON_PANEL_COMPENSATION_PROTECT or panel == AppState.OFFSEASON_PANEL_COMPENSATION_PICK:
				action_result = AppState.complete_compensation_automatically()
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
