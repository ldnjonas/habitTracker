import Foundation
import GRDB

/// Das lokale SQLite-Schema.
///
/// Bewusst explizites SQL und keine Ableitung aus den Typen: dieselben Tabellen
/// entstehen später in Postgres, und die Übersetzung soll ein Textvergleich
/// sein, keine Interpretationsaufgabe.
///
/// Zeitstempel liegen im GRDB-Standardformat (`YYYY-MM-DD HH:MM:SS.SSS`, UTC) —
/// textuell, sortierbar und von Postgres direkt lesbar. Kalendertage stehen als
/// `YYYY-MM-DD` daneben und sind bewusst etwas anderes.
///
/// **Jede synchronisierte Tabelle trägt vier Spalten:**
/// - `user_id` — ab Tag 1 gesetzt, damit der spätere Login keine Migration braucht
/// - `updated_at` — später vom Server gesetzt; entscheidet Last-Write-Wins
/// - `deleted_at` — Grabstein. Eine Löschung ohne Grabstein ist beim Sync
///   unsichtbar und käme auf anderen Geräten nie an.
/// - `server_seq` / `dirty` — Cursor und lokale Änderungsmarkierung
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "habit") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("notes", .text)
                t.column("kind", .text).notNull()
                t.column("color_hex", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("time_of_day", .text)
                t.column("preferred_time", .text)
                t.column("tracks_time", .boolean).notNull().defaults(to: false)
                t.column("starts_on", .text)
                t.column("ends_on", .text)
                t.column("archived_on", .text)
                t.column("health_kit_link", .text)          // JSON
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "habit_rule") { t in
                t.column("habit_id", .text).notNull()
                    .references("habit", onDelete: .cascade)
                t.column("effective_from", .text).notNull()
                t.column("schedule_kind", .text).notNull()
                t.column("schedule_payload", .text).notNull()   // JSON
                t.column("target_value", .double)
                t.column("target_unit", .text)
                t.column("target_comparison", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.primaryKey(["habit_id", "effective_from"])
            }

            try db.create(table: "tag") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }

            // Die Verknüpfungstabelle braucht eigene Grabsteine: ohne sie käme
            // ein Ent-Taggen beim Sync nie auf dem anderen Gerät an.
            try db.create(table: "habit_tag") { t in
                t.column("habit_id", .text).notNull()
                    .references("habit", onDelete: .cascade)
                t.column("tag_id", .text).notNull()
                    .references("tag", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.primaryKey(["habit_id", "tag_id"])
            }

            try db.create(table: "entry") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("habit_id", .text).notNull()
                    .references("habit", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("value", .double).notNull()
                t.column("note", .text)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            // Der natürliche Schlüssel. Er macht das Schreiben idempotent und
            // löst Sync-Konflikte am Tageseintrag von selbst auf.
            try db.create(index: "entry_habit_date", on: "entry",
                          columns: ["habit_id", "date"], unique: true)

            try db.create(table: "entry_event") { t in
                t.primaryKey("id", .text)
                t.column("habit_id", .text).notNull()
                    .references("habit", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("at", .text).notNull()
                t.column("value", .double).notNull()
                t.column("note", .text)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "entry_event_habit_date", on: "entry_event",
                          columns: ["habit_id", "date"])

            try db.create(table: "day_exception") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("habit_id", .text)                 // NULL = alle Habits
                    .references("habit", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("reason", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "day_exception_date", on: "day_exception",
                          columns: ["date"])

            try db.create(table: "day_log") { t in
                t.column("user_id", .text).notNull()
                t.column("date", .text).notNull()
                t.column("mood", .integer)
                t.column("energy", .integer)
                t.column("sleep_hours", .double)
                t.column("note", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.primaryKey(["user_id", "date"])
            }

            // v1 legt nur das Schema an. Der Kontostand ist die Summe der
            // Beträge — ein Ledger statt eines Zählers, weil er auditierbar ist
            // und beim Sync konfliktfrei bleibt (es wird nur angehängt).
            try db.create(table: "freeze_ledger") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("reason", .text).notNull()
                t.column("habit_id", .text)
                t.column("date", .text)
                t.column("created_at", .text).notNull()
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "app_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }

            // Rein lokal, wird nie übertragen.
            try db.create(table: "sync_state") { t in
                t.primaryKey("id", .integer)
                t.column("last_server_seq", .integer).notNull().defaults(to: 0)
                t.column("last_synced_at", .text)
                t.column("user_id", .text)
                t.check(sql: "id = 1")
            }
            try db.execute(sql: """
                INSERT INTO sync_state (id, last_server_seq) VALUES (1, 0)
                """)
        }

        // Löscht man einen Habit, verschwinden seine Einträge mit ihm. Weil weich
        // gelöscht wird, greift `ON DELETE CASCADE` dabei nicht — die Grabsteine
        // müssen von Hand gesetzt werden, sonst kommt die Löschung auf einem
        // zweiten Gerät nie an.
        //
        // `deleted_with` hält fest, *womit zusammen* eine Zeile gelöscht wurde.
        // Ein bloßes Ja/Nein reichte nicht: auf `habit_tag` wirken zwei
        // Ursachen — das Löschen des Habits und das Löschen des Tags. Ohne die
        // Herkunft holte das Wiederherstellen eines Habits auch Zuordnungen
        // zurück, deren Tag noch im Papierkorb liegt.
        //
        // Die Spalte ist nur aussagekräftig, solange `deleted_at` gesetzt ist:
        // jedes Wiederherstellen räumt sie mit ab.
        migrator.registerMigration("v2-cascade-marker") { db in
            for table in ["entry", "entry_event", "day_exception",
                          "habit_rule", "habit_tag"] {
                try db.alter(table: table) { t in
                    t.add(column: "deleted_with", .text)
                }
            }
        }

        migrator.registerMigration("v3-focus") { db in
            try db.create(table: "focus_run") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text).notNull()
                t.column("title", .text)
                t.column("starts_on", .text).notNull()
                t.column("ends_on", .text).notNull()
                // JSON statt Verknüpfungstabelle: die Auswahl ist eine
                // Momentaufnahme der Absicht und wird nie nach Habit abgefragt.
                // Ohne Fremdschlüssel reißt ein später gelöschter Habit den
                // Verlaufseintrag auch nicht mit — was richtig ist, denn der
                // Lauf hat stattgefunden.
                t.column("habit_ids", .text).notNull().defaults(to: "[]")
                t.column("abandoned_on", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
                t.column("server_seq", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "focus_run_starts_on", on: "focus_run",
                          columns: ["starts_on"])
        }

        // `at` war ein Zeitpunkt. Für „von 7:30 bis 8:15 gelaufen" braucht es
        // einen Zeitraum — und daraus leitet sich der Tageswert ab.
        migrator.registerMigration("v4-event-end") { db in
            try db.alter(table: "entry_event") { t in
                t.add(column: "ends_at", .text)
            }
        }

        return migrator
    }
}
