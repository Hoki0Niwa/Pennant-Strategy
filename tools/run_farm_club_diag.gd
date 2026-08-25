extends Node

# ファーム専用球団の投手が弱すぎるときの切り分けツール。
# 「能力水準が低いだけ」なのか「役割/起用の構成が壊れているのか」を分けて見るために、
#   (a) 14球団それぞれの二軍投手の z 能力分布 (試合前 = 起用の影響を受けない)
#   (b) 役割の内訳 (先発/中継/抑え) と、その日実際に組まれるブルペンの人数
#   (c) 二軍戦での起用実態 (使用投手・先発した人数・完投・BB/9・K/9・ERA) と打線側の成績
# を並べて出す。専用球団には `*` が付く。
#
# 実行: godot --headless res://tools/run_farm_club_diag.tscn -- --days=45 --seed=12345
#   --roles を付けると試合を回さず、**役割判定が能力水準に依らないか**だけを
#   水準別1000人の生成で測る (PSPitcherRoleModel.STARTER_DECISION_MARGIN を決めるための実測)。
#
# 読み方 (詳細は docs/agent_memory/project_farm_system_design.md):
#   - (b) の先発判定が専用球団だけ極端に少なければ、役割判定が能力の**水準**に依存している
#     (判定は starter_shape_advantage = 水準を打ち消した差で行う)。
#   - (a) の質 z が専用球団だけ 12球団より大きく低ければ、生成水準の問題。
#   - (c) の「完投」列が他球団 0-5 に対して専用球団だけ 30 超なら、ブルペンが全員疲労上限を
#     超えて継投先が null になり先発が投げ続けている (`relief_reserve` と非常時の継投を疑う)。

const PIT_KEYS: Array = [
	"Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_BarrelDeny", "Pit_LoftControl",
	"Pit_Efficiency", "Pit_Stamina", "Pit_FatigueResist",
]
const BAT_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Barrel", "Bat_Loft", "Bat_Spray",
	"Bat_Aggression",
]
const CATCHER_KEYS: Array = [
	"C_Framing", "C_Blocking", "C_Throw", "C_GameCall", "C_FieldSecure",
]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var day_limit: int = int(args.get("days", 45))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	if bool(args.get("roles", false)):
		Rng.set_seed_value(seed_value)
		_sample_role_split()
		get_tree().quit(0)
		return

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	# --- (a) 生成時点の能力分布 (試合前に測る = 起用の影響を受けない) ---
	print("=== 投手の z 能力 (二軍参加14球団) ===")
	print("team                       n   " + " ".join(PIT_KEYS.map(func(k): return "%12s" % k)) + "  overall")
	for team_id_value in PSFarmLeague.all_team_ids(_first_team_ids()):
		_print_pitcher_abilities(int(team_id_value), season)
	print("")
	print("=== 野手の z 能力 (二軍参加14球団) ===")
	print("team                       n   " + " ".join(BAT_KEYS.map(func(k): return "%12s" % k)) + "  overall")
	for team_id_value in PSFarmLeague.all_team_ids(_first_team_ids()):
		_print_fielder_abilities(int(team_id_value), season)
	print("")
	print("=== 捕手の z 能力 (二軍参加14球団) ===")
	print("team                       n   " + " ".join(CATCHER_KEYS.map(func(k): return "%12s" % k)))
	for team_id_value in PSFarmLeague.all_team_ids(_first_team_ids()):
		_print_catcher_abilities(int(team_id_value), season)

	# --- (a2) 役割の内訳と二軍ローテの人数 ---
	print("")
	print("=== 役割の内訳 / 二軍ローテ ===")
	print("team                      先発  中継  抑え   当日ブルペン")
	for team_id_value in PSFarmLeague.all_team_ids(_first_team_ids()):
		_print_roles(int(team_id_value), season)

	# --- 試合を回す ---
	var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
	var days: int = 0
	while days < day_limit and _has_unplayed_game(season):
		GameSimulator.simulate_current_day(season, false, ctx)
		days += 1

	# --- (b) 起用の実態 ---
	print("")
	print("=== 二軍での投手起用 (%d日) ===" % days)
	print("team                      使用投手  先発した投手  完投  総投球回  最多IP  BB/9   K/9    ERA   得点  失点  打率  OPS")
	for team_id_value in PSFarmLeague.all_team_ids(_first_team_ids()):
		_print_usage(int(team_id_value), season)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	get_tree().quit(0)


# 役割判定 (PSPitcherRoleModel.is_starter_record) が **能力水準に依らず** 同じ先発比率を
# 出すかを確かめる。水準ごとに投手を生成し、先発と判定される割合と shape advantage の
# 分位点を出す。STARTER_DECISION_MARGIN を決めるための実測。
func _sample_role_split() -> void:
	print("=== 役割判定の水準依存 (各水準1000人生成) ===")
	_sample_role_split_for("ドラフト候補相当 (max=70, var=12)", 70, 12)
	_sample_role_split_for("専用球団相当 (max=62, var=11)", 62, 11)


func _sample_role_split_for(label: String, max_display: int, variance: int) -> void:
	print("--- %s ---" % label)
	print("center  質z平均   先発率   advantage: p10    p25    p50    p75    p90")
	for center in [40, 46, 52, 58, 64, 70]:
		var advantages: Array = []
		var quality_total: float = 0.0
		var starters: int = 0
		for i in range(1000):
			var z: Dictionary = OffseasonService.generated_z_abilities(1, int(center), max_display, variance)
			var record: PSPlayerSeasonRecord = _synth_pitcher_record(z, i)
			var advantage: float = PSPitcherRoleModel.starter_shape_advantage(record)
			advantages.append(advantage)
			quality_total += PSPitcherRoleModel.quality_level(record)
			if PSPitcherRoleModel.is_starter_record(record):
				starters += 1
		advantages.sort()
		print("%6d %8.2f %8.1f%%           %6.2f %6.2f %6.2f %6.2f %6.2f" % [
			center, quality_total / 1000.0, float(starters) / 10.0,
			advantages[100], advantages[250], advantages[500], advantages[750], advantages[900],
		])


func _synth_pitcher_record(z: Dictionary, index: int) -> PSPlayerSeasonRecord:
	var player: PSPlayer = PSPlayer.from_dict({
		"id": 900000 + index,
		"name": "probe",
		"team_id": 0,
		"age": 22,
		"position": 1,
		"role": "",
		"z_abilities": z,
		"raw_abilities": OffseasonService.generated_raw_abilities(1, z),
		"arsenal": OffseasonService.generated_arsenal(1, z),
	})
	return PSPlayerSeasonRecord.from_player(player, 2026, 1)


func _first_team_ids() -> Array:
	var ids: Array = []
	for team_row in GameDb.teams:
		ids.append((team_row as PSTeam).id)
	return ids


func _print_pitcher_abilities(team_id: int, season: PSSeason) -> void:
	var sums: Dictionary = {}
	for key in PIT_KEYS:
		sums[key] = 0.0
	var overall: float = 0.0
	var count: int = 0
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher():
			continue
		count += 1
		for key in PIT_KEYS:
			sums[key] = float(sums[key]) + float(record.z_abilities_snapshot.get(key, 0.0))
		overall += float(PSPlayerValueEvaluator.overall_score(record))
	if count == 0:
		return
	var cells: Array = []
	for key in PIT_KEYS:
		cells.append("%12.2f" % (float(sums[key]) / float(count)))
	print("%-24s %3d   %s  %6.1f" % [_team_label(team_id), count, " ".join(cells), overall / float(count)])


func _print_fielder_abilities(team_id: int, season: PSSeason) -> void:
	var sums: Dictionary = {}
	for key in BAT_KEYS:
		sums[key] = 0.0
	var overall: float = 0.0
	var count: int = 0
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			continue
		count += 1
		for key in BAT_KEYS:
			sums[key] = float(sums[key]) + float(record.z_abilities_snapshot.get(key, 0.0))
		overall += float(PSPlayerValueEvaluator.overall_score(record))
	if count == 0:
		return
	var cells: Array = []
	for key in BAT_KEYS:
		cells.append("%12.2f" % (float(sums[key]) / float(count)))
	print("%-24s %3d   %s  %6.1f" % [_team_label(team_id), count, " ".join(cells), overall / float(count)])


func _print_catcher_abilities(team_id: int, season: PSSeason) -> void:
	var sums: Dictionary = {}
	for key in CATCHER_KEYS:
		sums[key] = 0.0
	var count: int = 0
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.position != 2:
			continue
		count += 1
		for key in CATCHER_KEYS:
			sums[key] = float(sums[key]) + float(record.z_abilities_snapshot.get(key, 0.0))
	if count == 0:
		return
	var cells: Array = []
	for key in CATCHER_KEYS:
		cells.append("%12.2f" % (float(sums[key]) / float(count)))
	print("%-24s %3d   %s" % [_team_label(team_id), count, " ".join(cells)])


func _print_roles(team_id: int, season: PSSeason) -> void:
	var starters: int = 0
	var relievers: int = 0
	var closers: int = 0
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher():
			continue
		match record.role:
			"starter":
				starters += 1
			"closer":
				closers += 1
			_:
				relievers += 1
	# 実際に組まれる二軍のセットアップから、その日のブルペン人数を見る
	# (ここが 0 だと継投できず先発が投げ切ってしまう)。
	var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(
		season, team_id, true, false, PSPerformanceReference.LEVEL_FARM)
	var bullpen: int = (setup.get("relievers", []) as Array).size() if bool(setup.get("ok", false)) else -1
	print("%-24s %4d %5d %5d %10d" % [_team_label(team_id), starters, relievers, closers, bullpen])


func _print_usage(team_id: int, season: PSSeason) -> void:
	var used: int = 0
	var started: int = 0
	var complete_games: int = 0
	var outs: int = 0
	var max_outs: int = 0
	var walks: int = 0
	var strikeouts: int = 0
	var earned: int = 0
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var stats: PSPitcherStats = (record_row as PSPlayerSeasonRecord).farm_pitcher_stats
		if stats.games <= 0:
			continue
		used += 1
		if stats.starts > 0:
			started += 1
		complete_games += stats.complete_games
		outs += stats.outs_pitched
		max_outs = max(max_outs, stats.outs_pitched)
		walks += stats.walks
		strikeouts += stats.strikeouts
		earned += stats.earned_runs
	var innings: float = float(outs) / 3.0
	if innings <= 0.0:
		print("%-24s (登板なし)" % _team_label(team_id))
		return
	# 打線側も並べる (投手だけが原因なのか、得点力も足りていないのかを分けるため)。
	var batting: PSBatterStats = PSBatterStats.new()
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		batting.add_from((record_row as PSPlayerSeasonRecord).farm_batter_stats)
	var stats: PSStats = season.farm_standings.get(team_id) as PSStats
	print("%-24s %6d %11d %6d %9.1f %7.1f %6.2f %6.2f %6.2f %5d %5d %6.3f %6.3f" % [
		_team_label(team_id), used, started, complete_games, innings, float(max_outs) / 3.0,
		float(walks) * 9.0 / innings, float(strikeouts) * 9.0 / innings, float(earned) * 9.0 / innings,
		stats.runs_scored if stats != null else 0, stats.runs_allowed if stats != null else 0,
		batting.batting_average(), batting.ops(),
	])


func _team_label(team_id: int) -> String:
	var team: PSTeam = GameDb.get_any_team(team_id)
	var mark: String = "*" if PSFarmLeague.is_farm_club_id(team_id) else " "
	return "%s%s" % [mark, team.name if team != null else str(team_id)]


func _has_unplayed_game(season: PSSeason) -> bool:
	for game_value in season.schedule:
		if not bool((game_value as Dictionary).get("played", false)):
			return true
	return false


func _parse_args() -> Dictionary:
	var out: Dictionary = {}
	for arg in OS.get_cmdline_user_args():
		var text: String = str(arg)
		if not text.begins_with("--"):
			continue
		var body: String = text.substr(2)
		var eq: int = body.find("=")
		if eq < 0:
			out[body] = true
		else:
			out[body.substr(0, eq)] = body.substr(eq + 1)
	return out
