extends RefCounted
class_name PSAwards

const BATTING_CATEGORIES: Array = ["average", "home_runs", "rbi", "stolen_bases", "hits"]
const PITCHING_CATEGORIES: Array = ["wins", "era", "strikeouts", "saves", "holds", "win_rate"]

# ベストナイン/ゴールデングラブのスロット構成 (canonical order)。各要素は守備位置番号
# (1=投 2=捕 3=一 4=二 5=三 6=遊 7=外 10=DH)。ベストナインは守備6 + 外野3 + DH の10枠、
# ゴールデングラブは DH を除く9枠。UI とサービスがこの順で配列を並べる。
const BEST_NINE_SLOT_POSITIONS: Array = [1, 2, 3, 4, 5, 6, 7, 7, 7, 10]
const GOLDEN_GLOVE_SLOT_POSITIONS: Array = [1, 2, 3, 4, 5, 6, 7, 7, 7]

var year: int
var season_number: int
var mvp_league1_player_id: int = 0
var mvp_league2_player_id: int = 0
var rookie_league1_player_id: int = 0
var rookie_league2_player_id: int = 0
# league key ("league1" / "league2") → category key → player_id
var batting_titles: Dictionary = {}
var pitching_titles: Dictionary = {}
# league key → Array[{pid:int, value:String}]。スロット順は BEST_NINE_SLOT_POSITIONS /
# GOLDEN_GLOVE_SLOT_POSITIONS に一致 (ベストナイン10枠 / ゴールデングラブ9枠)。
# 該当者なし・DH非採用リーグの DH 枠は {pid:0, value:""}。
var best_nine: Dictionary = {}
var golden_glove: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		"mvp_league1_player_id": mvp_league1_player_id,
		"mvp_league2_player_id": mvp_league2_player_id,
		"rookie_league1_player_id": rookie_league1_player_id,
		"rookie_league2_player_id": rookie_league2_player_id,
		"batting_titles": batting_titles,
		"pitching_titles": pitching_titles,
		"best_nine": best_nine,
		"golden_glove": golden_glove,
	}


static func from_dict(data: Dictionary) -> PSAwards:
	var awards: PSAwards = PSAwards.new()
	awards.year = int(data.get("year", 0))
	awards.season_number = int(data.get("season_number", 1))
	# 旧セーブ/旧シーズンアーカイブはリーグを "central"/"pacific" で保存している。
	# 読み込み時だけ引き継ぎ、保存は常に新キー ("league1"/"league2") で行う。
	awards.mvp_league1_player_id = int(data.get("mvp_league1_player_id", data.get("mvp_central_player_id", 0)))
	awards.mvp_league2_player_id = int(data.get("mvp_league2_player_id", data.get("mvp_pacific_player_id", 0)))
	awards.rookie_league1_player_id = int(data.get("rookie_league1_player_id", data.get("rookie_central_player_id", 0)))
	awards.rookie_league2_player_id = int(data.get("rookie_league2_player_id", data.get("rookie_pacific_player_id", 0)))
	awards.batting_titles = _migrate_league_keys(data.get("batting_titles", {}) as Dictionary)
	awards.pitching_titles = _migrate_league_keys(data.get("pitching_titles", {}) as Dictionary)
	awards.best_nine = _migrate_league_keys(data.get("best_nine", {}) as Dictionary)
	awards.golden_glove = _migrate_league_keys(data.get("golden_glove", {}) as Dictionary)
	return awards


# リーグ別辞書の旧キー ("central"/"pacific") を新キーへ寄せる。新キーが既にあればそちらを優先。
static func _migrate_league_keys(source: Dictionary) -> Dictionary:
	var out: Dictionary = source.duplicate(true)
	for legacy_key in {"central": "league1", "pacific": "league2"}:
		if not out.has(legacy_key):
			continue
		var new_key: String = "league1" if legacy_key == "central" else "league2"
		if not out.has(new_key):
			out[new_key] = out[legacy_key]
		out.erase(legacy_key)
	return out
