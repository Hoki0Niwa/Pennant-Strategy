extends RefCounted
class_name PSCareerLog

# 選手の経歴イベント (R7 記録・履歴基盤)。`player.source_data["career_log"]` に append-only で
# 保存し、セーブは player 本体と一緒に永続化される (スキーマ変更なし)。トレードで球団を移っても
# ログは選手に付いて回る。エントリはサイズ節約のため短縮キー:
#   y=年 / t=種別 / f=元球団id / o=先球団id / v=数値 (順位・年俸・日数など) / s=文字列 (怪我名など) / d=育成フラグ
# 表示整形は describe() に集約 (player_detail の経歴タブが使う)。

const KEY: String = "career_log"

const TYPE_DRAFT: String = "draft"
const TYPE_TRADE: String = "trade"
const TYPE_GENEKI_DRAFT: String = "geneki_draft"
const TYPE_COMPENSATION: String = "compensation"
const TYPE_FA_MOVE: String = "fa_move"
const TYPE_FA_STAY: String = "fa_stay"
const TYPE_RELEASED: String = "released"
const TYPE_RELEASED_SIGNED: String = "released_signed"
const TYPE_FOREIGN_JOIN: String = "foreign_join"
const TYPE_FOREIGN_STAY: String = "foreign_stay"
const TYPE_FOREIGN_MOVE: String = "foreign_move"
const TYPE_FOREIGN_DEPART: String = "foreign_depart"
const TYPE_DEV_DEMOTE: String = "dev_demote"
const TYPE_DEV_PROMOTE: String = "dev_promote"
const TYPE_RETIRED: String = "retired"
const TYPE_SALARY: String = "salary"
const TYPE_INJURY: String = "injury"
const TYPE_CONTRACT_EXTENSION: String = "contract_extension"

# 怪我はこの日数以上の長期離脱だけ記録する (軽傷まで記録するとログが肥大する)。
const INJURY_LOG_MIN_DAYS: int = 20


static func append(player: PSPlayer, entry: Dictionary) -> void:
	if player == null:
		return
	var log: Array = player.source_data.get(KEY, []) as Array
	log.append(entry)
	player.source_data[KEY] = log


# ドラフト時は player 構築前に source_data 辞書へ直接シードする。
static func seed_draft_entry(source: Dictionary, year: int, team_id: int, round_no: int, development: bool) -> void:
	var log: Array = source.get(KEY, []) as Array
	log.append({"y": year, "t": TYPE_DRAFT, "o": team_id, "v": round_no, "d": development})
	source[KEY] = log


static func entries(player: PSPlayer) -> Array:
	if player == null:
		return []
	return player.source_data.get(KEY, []) as Array


static func log_trade(player: PSPlayer, year: int, from_team: int, to_team: int) -> void:
	append(player, {"y": year, "t": TYPE_TRADE, "f": from_team, "o": to_team})


static func log_geneki_draft(player: PSPlayer, year: int, from_team: int, to_team: int) -> void:
	append(player, {"y": year, "t": TYPE_GENEKI_DRAFT, "f": from_team, "o": to_team})


static func log_compensation(player: PSPlayer, year: int, from_team: int, to_team: int) -> void:
	append(player, {"y": year, "t": TYPE_COMPENSATION, "f": from_team, "o": to_team})


static func log_fa_move(player: PSPlayer, year: int, from_team: int, to_team: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_FA_MOVE, "f": from_team, "o": to_team, "v": salary})


static func log_fa_stay(player: PSPlayer, year: int, team_id: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_FA_STAY, "o": team_id, "v": salary})


static func log_released(player: PSPlayer, year: int, team_id: int) -> void:
	append(player, {"y": year, "t": TYPE_RELEASED, "f": team_id})


static func log_released_signed(player: PSPlayer, year: int, from_team: int, to_team: int, development: bool) -> void:
	append(player, {"y": year, "t": TYPE_RELEASED_SIGNED, "f": from_team, "o": to_team, "d": development})


static func log_foreign_join(player: PSPlayer, year: int, team_id: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_FOREIGN_JOIN, "o": team_id, "v": salary})


# 外国人契約市場での残留 (元球団と再契約)。
static func log_foreign_stay(player: PSPlayer, year: int, team_id: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_FOREIGN_STAY, "o": team_id, "v": salary})


# 外国人契約市場での引き抜き移籍。
static func log_foreign_move(player: PSPlayer, year: int, from_team: int, to_team: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_FOREIGN_MOVE, "f": from_team, "o": to_team, "v": salary})


# 外国人契約市場でどこからも提示が無く退団 (帰国) した。
static func log_foreign_depart(player: PSPlayer, year: int, team_id: int) -> void:
	append(player, {"y": year, "t": TYPE_FOREIGN_DEPART, "f": team_id})


static func log_dev_demote(player: PSPlayer, year: int, team_id: int) -> void:
	append(player, {"y": year, "t": TYPE_DEV_DEMOTE, "o": team_id})


static func log_dev_promote(player: PSPlayer, year: int, team_id: int) -> void:
	append(player, {"y": year, "t": TYPE_DEV_PROMOTE, "o": team_id})


static func log_retired(player: PSPlayer, year: int, team_id: int, age: int) -> void:
	append(player, {"y": year, "t": TYPE_RETIRED, "f": team_id, "v": age})


# 契約更改。年俸が変わらなかった年は記録しない (呼び出し側で判定)。
static func log_salary(player: PSPlayer, year: int, salary: int) -> void:
	append(player, {"y": year, "t": TYPE_SALARY, "v": salary})


static func log_injury(player: PSPlayer, year: int, days: int, label: String) -> void:
	if days < INJURY_LOG_MIN_DAYS:
		return
	append(player, {"y": year, "t": TYPE_INJURY, "v": days, "s": label})


# 契約更新ステップの延長交渉で複数年契約が成立した (team_id は在籍球団のまま、移籍は伴わない)。
# 契約年数は v に、年俸は s に文字列格納せず別キー "w" (years) を使う。
static func log_contract_extension(player: PSPlayer, year: int, team_id: int, salary: int, years: int) -> void:
	append(player, {"y": year, "t": TYPE_CONTRACT_EXTENSION, "o": team_id, "v": salary, "w": years})


# 表示用整形。{year, label, detail} を返す。球団名は GameDb から解決する。
static func describe(entry: Dictionary) -> Dictionary:
	var year_text: String = "%d年" % int(entry.get("y", 0)) if int(entry.get("y", 0)) > 0 else "-"
	var from_name: String = _team_name(int(entry.get("f", 0)))
	var to_name: String = _team_name(int(entry.get("o", 0)))
	var value: int = int(entry.get("v", 0))
	match str(entry.get("t", "")):
		TYPE_DRAFT:
			var dev_suffix: String = " (育成)" if bool(entry.get("d", false)) else ""
			return {"year": year_text, "label": "ドラフト入団", "detail": "%s %d位%s" % [to_name, value, dev_suffix]}
		TYPE_TRADE:
			return {"year": year_text, "label": "トレード移籍", "detail": "%s → %s" % [from_name, to_name]}
		TYPE_GENEKI_DRAFT:
			return {"year": year_text, "label": "現役ドラフト移籍", "detail": "%s → %s" % [from_name, to_name]}
		TYPE_COMPENSATION:
			return {"year": year_text, "label": "人的補償移籍", "detail": "%s → %s" % [from_name, to_name]}
		TYPE_FA_MOVE:
			return {"year": year_text, "label": "FA移籍", "detail": "%s → %s (%s)" % [from_name, to_name, _money(value)]}
		TYPE_FA_STAY:
			return {"year": year_text, "label": "FA残留", "detail": "%s (%s)" % [to_name, _money(value)]}
		TYPE_RELEASED:
			return {"year": year_text, "label": "戦力外", "detail": from_name}
		TYPE_RELEASED_SIGNED:
			var track: String = "育成契約" if bool(entry.get("d", false)) else "支配下契約"
			return {"year": year_text, "label": "移籍 (戦力外獲得)", "detail": "%s → %s (%s)" % [from_name, to_name, track]}
		TYPE_FOREIGN_JOIN:
			return {"year": year_text, "label": "入団 (外国人)", "detail": "%s (%s)" % [to_name, _money(value)]}
		TYPE_FOREIGN_STAY:
			return {"year": year_text, "label": "外国人残留", "detail": "%s (%s)" % [to_name, _money(value)]}
		TYPE_FOREIGN_MOVE:
			return {"year": year_text, "label": "外国人移籍", "detail": "%s → %s (%s)" % [from_name, to_name, _money(value)]}
		TYPE_FOREIGN_DEPART:
			return {"year": year_text, "label": "退団 (外国人)", "detail": from_name}
		TYPE_DEV_DEMOTE:
			return {"year": year_text, "label": "育成降格", "detail": to_name}
		TYPE_DEV_PROMOTE:
			return {"year": year_text, "label": "支配下登録", "detail": to_name}
		TYPE_RETIRED:
			return {"year": year_text, "label": "引退", "detail": "%s (%d歳)" % [from_name, value]}
		TYPE_SALARY:
			return {"year": year_text, "label": "契約更改", "detail": _money(value)}
		TYPE_INJURY:
			return {"year": year_text, "label": "長期離脱", "detail": "%s (%d日)" % [str(entry.get("s", "故障")), value]}
		TYPE_CONTRACT_EXTENSION:
			return {"year": year_text, "label": "複数年延長", "detail": "%s %d年 (%s)" % [to_name, int(entry.get("w", 1)), _money(value)]}
	return {"year": year_text, "label": str(entry.get("t", "")), "detail": ""}


static func _team_name(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	return team.name if team != null else "球団%d" % team_id


static func _money(man_value: int) -> String:
	if man_value <= 0:
		return "-"
	var oku: int = int(float(man_value) / 10000.0)
	var man: int = man_value - oku * 10000
	if oku > 0:
		return "%d億%d万円" % [oku, man] if man > 0 else "%d億円" % oku
	return "%d万円" % man
