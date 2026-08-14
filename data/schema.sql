-- PennantStrategy persistent record schema draft
-- Target engine: SQLite 3. Derby相当のローカル永続DBとして、GodotではSQLite導入を想定する。

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS teams (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  short_name TEXT NOT NULL,
  league TEXT NOT NULL,
  color TEXT NOT NULL,
  previous_rank INTEGER NOT NULL DEFAULT 0,
  funds INTEGER NOT NULL DEFAULT 0,
  ratings_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS players (
  id INTEGER PRIMARY KEY,
  sensyu_num INTEGER NOT NULL DEFAULT 0,
  jersey_number INTEGER NOT NULL DEFAULT 0,
  development_player INTEGER NOT NULL DEFAULT 0,
  team_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  age INTEGER NOT NULL,
  years INTEGER NOT NULL,
  height INTEGER NOT NULL DEFAULT 0,
  weight INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL,
  role TEXT NOT NULL,
  throwing_hand TEXT NOT NULL,
  batting_side TEXT NOT NULL,
  salary INTEGER NOT NULL DEFAULT 0,
  draft_round INTEGER NOT NULL DEFAULT 0,
  hometown TEXT NOT NULL DEFAULT '',
  registered_roster TEXT NOT NULL DEFAULT '支配下',
  contract_status TEXT NOT NULL DEFAULT '通常',
  foreign_player INTEGER NOT NULL DEFAULT 0,
  position_aptitudes_json TEXT NOT NULL DEFAULT '{}',
  position_experience_json TEXT NOT NULL DEFAULT '{}',
  source_data_json TEXT NOT NULL DEFAULT '{}',
  fatigue INTEGER NOT NULL DEFAULT 0,
  injury_days INTEGER NOT NULL DEFAULT 0,
  injury_type TEXT NOT NULL DEFAULT '',
  injury_severity INTEGER NOT NULL DEFAULT 0,
  batting_abilities_json TEXT NOT NULL DEFAULT '{}',
  pitching_abilities_json TEXT NOT NULL DEFAULT '{}',
  fielding_abilities_json TEXT NOT NULL DEFAULT '{}',
  legacy_abilities_json TEXT NOT NULL DEFAULT '{}',
  CHECK(team_id >= 0)
);

CREATE TABLE IF NOT EXISTS seasons (
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  selected_team_id INTEGER NOT NULL,
  current_day INTEGER NOT NULL,
  PRIMARY KEY(year, season_number),
  FOREIGN KEY(selected_team_id) REFERENCES teams(id)
);

CREATE TABLE IF NOT EXISTS player_season_records (
  player_id INTEGER NOT NULL,
  sensyu_num INTEGER NOT NULL DEFAULT 0,
  jersey_number INTEGER NOT NULL DEFAULT 0,
  development_player INTEGER NOT NULL DEFAULT 0,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  team_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  age INTEGER NOT NULL,
  years INTEGER NOT NULL,
  height INTEGER NOT NULL DEFAULT 0,
  weight INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL,
  role TEXT NOT NULL,
  throwing_hand TEXT NOT NULL DEFAULT 'R',
  batting_side TEXT NOT NULL DEFAULT 'R',
  salary INTEGER NOT NULL DEFAULT 0,
  draft_round INTEGER NOT NULL DEFAULT 0,
  hometown TEXT NOT NULL DEFAULT '',
  registered_roster TEXT NOT NULL DEFAULT '支配下',
  contract_status TEXT NOT NULL DEFAULT '通常',
  foreign_player INTEGER NOT NULL DEFAULT 0,
  fatigue INTEGER NOT NULL DEFAULT 0,
  injury_days INTEGER NOT NULL DEFAULT 0,
  injury_type TEXT NOT NULL DEFAULT '',
  injury_severity INTEGER NOT NULL DEFAULT 0,
  position_aptitudes_json TEXT NOT NULL DEFAULT '{}',
  position_experience_json TEXT NOT NULL DEFAULT '{}',
  source_data_json TEXT NOT NULL DEFAULT '{}',
  batting_abilities_json TEXT NOT NULL DEFAULT '{}',
  pitching_abilities_json TEXT NOT NULL DEFAULT '{}',
  fielding_abilities_json TEXT NOT NULL DEFAULT '{}',
  legacy_abilities_json TEXT NOT NULL DEFAULT '{}',
  farm_advanced_stats_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY(player_id, year, season_number),
  FOREIGN KEY(player_id) REFERENCES players(id),
  CHECK(team_id >= 0),
  FOREIGN KEY(year, season_number) REFERENCES seasons(year, season_number)
);

CREATE TABLE IF NOT EXISTS batter_stats (
  player_id INTEGER NOT NULL,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  games INTEGER NOT NULL DEFAULT 0,
  plate_appearances INTEGER NOT NULL DEFAULT 0,
  at_bats INTEGER NOT NULL DEFAULT 0,
  hits INTEGER NOT NULL DEFAULT 0,
  doubles INTEGER NOT NULL DEFAULT 0,
  triples INTEGER NOT NULL DEFAULT 0,
  home_runs INTEGER NOT NULL DEFAULT 0,
  runs_batted_in INTEGER NOT NULL DEFAULT 0,
  runs INTEGER NOT NULL DEFAULT 0,
  walks INTEGER NOT NULL DEFAULT 0,
  hit_by_pitches INTEGER NOT NULL DEFAULT 0,
  strikeouts INTEGER NOT NULL DEFAULT 0,
  stolen_base_attempts INTEGER NOT NULL DEFAULT 0,
  stolen_bases INTEGER NOT NULL DEFAULT 0,
  sacrifices INTEGER NOT NULL DEFAULT 0,
  sacrifice_flies INTEGER NOT NULL DEFAULT 0,
  double_plays INTEGER NOT NULL DEFAULT 0,
  errors INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(player_id, year, season_number),
  FOREIGN KEY(player_id, year, season_number)
    REFERENCES player_season_records(player_id, year, season_number)
);

CREATE TABLE IF NOT EXISTS pitcher_stats (
  player_id INTEGER NOT NULL,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  games INTEGER NOT NULL DEFAULT 0,
  starts INTEGER NOT NULL DEFAULT 0,
  relief_appearances INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  holds INTEGER NOT NULL DEFAULT 0,
  saves INTEGER NOT NULL DEFAULT 0,
  outs_pitched INTEGER NOT NULL DEFAULT 0,
  batters_faced INTEGER NOT NULL DEFAULT 0,
  hits_allowed INTEGER NOT NULL DEFAULT 0,
  home_runs_allowed INTEGER NOT NULL DEFAULT 0,
  walks INTEGER NOT NULL DEFAULT 0,
  hit_batters INTEGER NOT NULL DEFAULT 0,
  strikeouts INTEGER NOT NULL DEFAULT 0,
  runs_allowed INTEGER NOT NULL DEFAULT 0,
  earned_runs INTEGER NOT NULL DEFAULT 0,
  complete_games INTEGER NOT NULL DEFAULT 0,
  shutouts INTEGER NOT NULL DEFAULT 0,
  quality_starts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(player_id, year, season_number),
  FOREIGN KEY(player_id, year, season_number)
    REFERENCES player_season_records(player_id, year, season_number)
);

-- 二軍 (ファーム) 成績。一軍と同じ列構成だが専用テーブルにする。
-- batter_stats / pitcher_stats に level 列を足す案は、リーダーボード系の SELECT が複数あり
-- そのすべてに WHERE level = 0 を書き忘れる余地が残るため採らない。テーブルを分ければ
-- 既存クエリは構造的に二軍成績を見られない。
CREATE TABLE IF NOT EXISTS farm_batter_stats (
  player_id INTEGER NOT NULL,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  games INTEGER NOT NULL DEFAULT 0,
  plate_appearances INTEGER NOT NULL DEFAULT 0,
  at_bats INTEGER NOT NULL DEFAULT 0,
  hits INTEGER NOT NULL DEFAULT 0,
  doubles INTEGER NOT NULL DEFAULT 0,
  triples INTEGER NOT NULL DEFAULT 0,
  home_runs INTEGER NOT NULL DEFAULT 0,
  runs_batted_in INTEGER NOT NULL DEFAULT 0,
  runs INTEGER NOT NULL DEFAULT 0,
  walks INTEGER NOT NULL DEFAULT 0,
  hit_by_pitches INTEGER NOT NULL DEFAULT 0,
  strikeouts INTEGER NOT NULL DEFAULT 0,
  pitches_seen INTEGER NOT NULL DEFAULT 0,
  stolen_base_attempts INTEGER NOT NULL DEFAULT 0,
  stolen_bases INTEGER NOT NULL DEFAULT 0,
  sacrifices INTEGER NOT NULL DEFAULT 0,
  sacrifice_flies INTEGER NOT NULL DEFAULT 0,
  double_plays INTEGER NOT NULL DEFAULT 0,
  errors INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(player_id, year, season_number),
  FOREIGN KEY(player_id, year, season_number)
    REFERENCES player_season_records(player_id, year, season_number)
);

CREATE TABLE IF NOT EXISTS farm_pitcher_stats (
  player_id INTEGER NOT NULL,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  games INTEGER NOT NULL DEFAULT 0,
  starts INTEGER NOT NULL DEFAULT 0,
  relief_appearances INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  holds INTEGER NOT NULL DEFAULT 0,
  saves INTEGER NOT NULL DEFAULT 0,
  outs_pitched INTEGER NOT NULL DEFAULT 0,
  batters_faced INTEGER NOT NULL DEFAULT 0,
  pitches_thrown INTEGER NOT NULL DEFAULT 0,
  hits_allowed INTEGER NOT NULL DEFAULT 0,
  home_runs_allowed INTEGER NOT NULL DEFAULT 0,
  walks INTEGER NOT NULL DEFAULT 0,
  hit_batters INTEGER NOT NULL DEFAULT 0,
  strikeouts INTEGER NOT NULL DEFAULT 0,
  ground_balls_allowed INTEGER NOT NULL DEFAULT 0,
  line_drives_allowed INTEGER NOT NULL DEFAULT 0,
  infield_flies_allowed INTEGER NOT NULL DEFAULT 0,
  outfield_flies_allowed INTEGER NOT NULL DEFAULT 0,
  runs_allowed INTEGER NOT NULL DEFAULT 0,
  earned_runs INTEGER NOT NULL DEFAULT 0,
  complete_games INTEGER NOT NULL DEFAULT 0,
  shutouts INTEGER NOT NULL DEFAULT 0,
  quality_starts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(player_id, year, season_number),
  FOREIGN KEY(player_id, year, season_number)
    REFERENCES player_season_records(player_id, year, season_number)
);

CREATE TABLE IF NOT EXISTS team_season_records (
  team_id INTEGER NOT NULL,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  name TEXT NOT NULL,
  league TEXT NOT NULL,
  games INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  runs_scored INTEGER NOT NULL DEFAULT 0,
  runs_allowed INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(team_id, year, season_number),
  FOREIGN KEY(team_id) REFERENCES teams(id),
  FOREIGN KEY(year, season_number) REFERENCES seasons(year, season_number)
);

CREATE TABLE IF NOT EXISTS games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  year INTEGER NOT NULL,
  season_number INTEGER NOT NULL,
  day INTEGER NOT NULL,
  away_team_id INTEGER NOT NULL,
  home_team_id INTEGER NOT NULL,
  away_score INTEGER NOT NULL DEFAULT 0,
  home_score INTEGER NOT NULL DEFAULT 0,
  played INTEGER NOT NULL DEFAULT 0,
  dh_enabled INTEGER NOT NULL DEFAULT 0,
  innings_json TEXT NOT NULL DEFAULT '[]',
  result_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY(year, season_number) REFERENCES seasons(year, season_number),
  FOREIGN KEY(away_team_id) REFERENCES teams(id),
  FOREIGN KEY(home_team_id) REFERENCES teams(id)
);

CREATE TABLE IF NOT EXISTS runtime_blobs (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_player_records_player_year
  ON player_season_records(player_id, year, season_number);

CREATE INDEX IF NOT EXISTS idx_player_records_team_year
  ON player_season_records(team_id, year, season_number);

CREATE INDEX IF NOT EXISTS idx_games_day
  ON games(year, season_number, day);
