extends RefCounted
class_name PSPennantRace

# 優勝マジックと自力優勝の可能性を求める純粋計算 (season を変更しない)。順位表 UI から呼ぶ。
#
# 順位は勝率 = 勝 / (勝 + 敗) で決まり引き分けは分母に含まれない (PSStats.win_rate と同じ規約)
# ため、マジックも単純な勝利数比較ではなく「全試合消化後の勝率」の比較で求める。
# 見積もりの前提: 各球団の未消化試合はすべて決着する (引き分けは既消化分のみ数える)。
#
# ranked 引数は勝率降順に並べた {"team_id", "wins", "losses", "remaining"} の配列
# (先頭が首位)。同一リーグ内の球団だけを渡すこと。

# 未消化試合数を全球団分まとめて数える。{team_id: 残り試合数}。
static func remaining_by_team(season: PSSeason) -> Dictionary:
	var out: Dictionary = {}
	for team_id in season.standings.keys():
		out[int(team_id)] = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		for tid in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			if out.has(tid):
				out[tid] = int(out[tid]) + 1
	return out


# 未消化の直接対決数。{team_id: {opponent_id: 残り直接対決数}}。自力優勝判定で使う。
static func head_to_head_remaining(season: PSSeason) -> Dictionary:
	var out: Dictionary = {}
	for team_id in season.standings.keys():
		out[int(team_id)] = {}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		var away: int = int(game.get("away_team_id", 0))
		var home: int = int(game.get("home_team_id", 0))
		if not out.has(away) or not out.has(home):
			continue
		var away_map: Dictionary = out[away] as Dictionary
		away_map[home] = int(away_map.get(home, 0)) + 1
		var home_map: Dictionary = out[home] as Dictionary
		home_map[away] = int(home_map.get(away, 0)) + 1
	return out


# 首位球団の優勝マジックを求める。戻り値:
#   magic    ... 首位が残りを全敗しても他球団の最大到達勝率を上回るために必要な勝利数。
#                対象球団が 1 敗しても 1 減る (一般的なマジックナンバーと同じ意味)。0 なら優勝決定。
#   clinched ... 他球団に追い付かれる目が無い (= 優勝決定)。
#   lit      ... マジック点灯。首位以外の全球団が自力優勝の可能性を失った状態を指す
#                (点灯前は数字を表示しない運用)。
static func magic_number(ranked: Array, head_to_head: Dictionary) -> Dictionary:
	var out: Dictionary = {"magic": 0, "lit": false, "clinched": false}
	if ranked.size() < 2:
		return out

	var leader: Dictionary = ranked[0] as Dictionary
	var leader_wins: int = int(leader.get("wins", 0))
	var leader_remaining: int = int(leader.get("remaining", 0))
	# 首位が残りを全敗した場合の決着数 (= 勝率の分母。残りの勝敗配分では変わらない)。
	var leader_decisions: int = leader_wins + int(leader.get("losses", 0)) + leader_remaining
	if leader_decisions <= 0:
		return out

	var magic: int = 0
	var rival_self_clinch: bool = false
	var all_played: bool = leader_remaining == 0
	for i in range(1, ranked.size()):
		var rival: Dictionary = ranked[i] as Dictionary
		var rival_remaining: int = int(rival.get("remaining", 0))
		if rival_remaining > 0:
			all_played = false
		var rival_best_wins: int = int(rival.get("wins", 0)) + rival_remaining
		var rival_decisions: int = rival_best_wins + int(rival.get("losses", 0))
		if rival_decisions <= 0:
			continue
		# 首位が残りを k 勝すると勝率は最低でも (leader_wins + k) / leader_decisions。
		# これが相手の最大勝率 rival_best_wins / rival_decisions を上回る最小の k を交差乗算で解く。
		@warning_ignore("integer_division")
		var threshold: int = (rival_best_wins * leader_decisions) / rival_decisions
		magic = maxi(magic, threshold + 1 - leader_wins)
		if has_self_clinch_chance(ranked, i, head_to_head):
			rival_self_clinch = true

	# 全球団が全試合を消化していれば、勝率同率で magic が 1 残る場合でも首位が優勝。
	out["clinched"] = magic <= 0 or all_played
	out["magic"] = maxi(0, magic)
	out["lit"] = not bool(out["clinched"]) and not rival_self_clinch
	return out


# 自力優勝の可能性: 対象が残り全勝したとき、他球団が直接対決を全て落としたうえで残りを
# 全勝しても勝率で上回られないか。勝率同率は「可能性あり」として扱う。
static func has_self_clinch_chance(ranked: Array, index: int, head_to_head: Dictionary) -> bool:
	if index < 0 or index >= ranked.size():
		return false
	var target: Dictionary = ranked[index] as Dictionary
	var target_id: int = int(target.get("team_id", 0))
	var best_wins: int = int(target.get("wins", 0)) + int(target.get("remaining", 0))
	var decisions: int = best_wins + int(target.get("losses", 0))
	if decisions <= 0:
		return true

	var direct: Dictionary = head_to_head.get(target_id, {}) as Dictionary
	for i in range(ranked.size()):
		if i == index:
			continue
		var other: Dictionary = ranked[i] as Dictionary
		var other_remaining: int = int(other.get("remaining", 0))
		var other_decisions: int = int(other.get("wins", 0)) + int(other.get("losses", 0)) + other_remaining
		if other_decisions <= 0:
			continue
		var other_best_wins: int = int(other.get("wins", 0)) + other_remaining - int(direct.get(int(other.get("team_id", 0)), 0))
		if best_wins * other_decisions < other_best_wins * decisions:
			return false
	return true
