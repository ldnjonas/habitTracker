-- Das Serverschema. Bewusst dieselben Tabellen und Spaltennamen wie im Client
-- (apple/HabitKit/Sources/HabitStore/Schema.swift), damit ein Abgleich der
-- beiden eine Textprüfung bleibt und keine Auslegungsfrage wird.
--
-- Zwei Unterschiede, beide beabsichtigt:
--   * `dirty` fehlt — das ist eine reine Client-Markierung.
--   * `server_seq` ist hier NOT NULL und wird vom Server vergeben. Der Client
--     führt dieselbe Spalte, aber nur als Kopie dessen, was er bekommen hat.

CREATE TABLE IF NOT EXISTS habit (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  notes TEXT,
  kind TEXT NOT NULL,
  color_hex TEXT NOT NULL,
  symbol TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  time_of_day TEXT,
  preferred_time TEXT,
  tracks_time INTEGER NOT NULL DEFAULT 0,
  starts_on TEXT,
  ends_on TEXT,
  archived_on TEXT,
  health_kit_link TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_seq INTEGER NOT NULL
);

-- Regeln und Tag-Zuordnungen gehören zum Habit und wandern mit ihm: sie tragen
-- keine eigene `server_seq`. Deshalb muss jede Änderung an ihnen das
-- `updated_at` des Habits anheben, sonst bliebe sie beim Abgleich unsichtbar.
CREATE TABLE IF NOT EXISTS habit_rule (
  habit_id TEXT NOT NULL REFERENCES habit(id) ON DELETE CASCADE,
  effective_from TEXT NOT NULL,
  schedule_kind TEXT NOT NULL,
  schedule_payload TEXT NOT NULL,
  target_value REAL,
  target_unit TEXT,
  target_comparison TEXT,
  PRIMARY KEY (habit_id, effective_from)
);

CREATE TABLE IF NOT EXISTS habit_tag (
  habit_id TEXT NOT NULL REFERENCES habit(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL,
  PRIMARY KEY (habit_id, tag_id)
);

CREATE TABLE IF NOT EXISTS tag (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  color_hex TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_seq INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS entry (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  habit_id TEXT NOT NULL,
  date TEXT NOT NULL,
  value REAL NOT NULL,
  note TEXT,
  source TEXT NOT NULL DEFAULT 'manual',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  deleted_with TEXT,
  server_seq INTEGER NOT NULL
);
-- Der natürliche Schlüssel, auf dem die ganze Idempotenz beruht.
CREATE UNIQUE INDEX IF NOT EXISTS entry_habit_date ON entry(habit_id, date);

CREATE TABLE IF NOT EXISTS entry_event (
  id TEXT PRIMARY KEY,
  habit_id TEXT NOT NULL,
  date TEXT NOT NULL,
  at TEXT NOT NULL,
  ends_at TEXT,
  value REAL NOT NULL,
  note TEXT,
  source TEXT NOT NULL DEFAULT 'manual',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  deleted_with TEXT,
  server_seq INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS entry_event_habit_date ON entry_event(habit_id, date);

CREATE TABLE IF NOT EXISTS day_exception (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  habit_id TEXT,
  date TEXT NOT NULL,
  kind TEXT NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  deleted_with TEXT,
  server_seq INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS day_exception_date ON day_exception(date);

CREATE TABLE IF NOT EXISTS day_log (
  user_id TEXT NOT NULL,
  date TEXT NOT NULL,
  mood INTEGER,
  energy INTEGER,
  sleep_hours REAL,
  note TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_seq INTEGER NOT NULL,
  PRIMARY KEY (user_id, date)
);

CREATE TABLE IF NOT EXISTS focus_run (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  title TEXT,
  starts_on TEXT NOT NULL,
  ends_on TEXT NOT NULL,
  habit_ids TEXT NOT NULL DEFAULT '[]',
  abandoned_on TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_seq INTEGER NOT NULL
);

-- Nur anhängen: keine `updated_at`, kein Grabstein. Eine Buchung wird nicht
-- geändert und nicht zurückgenommen, eine Korrektur ist eine Gegenbuchung.
CREATE TABLE IF NOT EXISTS freeze_ledger (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  amount INTEGER NOT NULL,
  reason TEXT NOT NULL,
  habit_id TEXT,
  date TEXT,
  focus_run_id TEXT,
  created_at TEXT NOT NULL,
  server_seq INTEGER NOT NULL
);

-- Eine einzige, lückenlos steigende Folge über alle Tabellen hinweg. Der
-- Cursor eines Clients ist genau diese Zahl — dadurch braucht er sich nicht je
-- Tabelle etwas zu merken, und die Reihenfolge bleibt über alle Tabellen
-- hinweg eindeutig.
CREATE TABLE IF NOT EXISTS sync_sequence (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  value INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO sync_sequence (id, value) VALUES (1, 0);
