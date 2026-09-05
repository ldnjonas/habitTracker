import Foundation
import GRDB
import HabitCore

extension LocalHabitAPI {

    // MARK: - Zusammensetzen

    static func habitRow(_ id: UUID, db: Database) throws -> HabitRow? {
        try HabitRow.fetchOne(db, sql: """
            SELECT * FROM habit WHERE id = ? AND deleted_at IS NULL
            """, arguments: [id.uuidString])
    }

    /// Ein Habit liegt über drei Tabellen verteilt.
    static func assemble(_ row: HabitRow, db: Database) throws -> Habit {
        let habitId = row.id
        let rules = try HabitRuleRow.fetchAll(db, sql: """
            SELECT * FROM habit_rule
            WHERE habit_id = ? AND deleted_at IS NULL
            ORDER BY effective_from
            """, arguments: [habitId]).map { try $0.rule }

        let tagIds = try String.fetchAll(db, sql: """
            SELECT tag_id FROM habit_tag
            WHERE habit_id = ? AND deleted_at IS NULL
            """, arguments: [habitId]).compactMap(UUID.init(uuidString:))

        return try row.habit(rules: rules, tagIds: tagIds)
    }

    /// Ersetzt die Tag-Menge vollständig.
    ///
    /// Entfernte Zuordnungen werden mit Grabstein versehen statt gelöscht — sonst
    /// käme ein Ent-Taggen beim Sync auf anderen Geräten nie an.
    static func replaceTags(habitId: UUID, tagIds: [UUID], now: Date, db: Database) throws {
        let wanted = Set(tagIds.map(\.uuidString))

        let existing = try HabitTagRow.fetchAll(db, sql: """
            SELECT * FROM habit_tag WHERE habit_id = ?
            """, arguments: [habitId.uuidString])

        for row in existing where row.deletedAt == nil && !wanted.contains(row.tagId) {
            try db.execute(sql: """
                UPDATE habit_tag SET deleted_at = ?, updated_at = ?, dirty = 1
                WHERE habit_id = ? AND tag_id = ?
                """, arguments: [now, now, habitId.uuidString, row.tagId])
        }

        for tagId in wanted {
            var row = HabitTagRow(habitId: habitId.uuidString, tagId: tagId,
                                  createdAt: now, updatedAt: now, deletedAt: nil,
                                  serverSeq: nil, dirty: true)
            try row.upsert(db)   // hebt einen früheren Grabstein wieder auf
        }

        try touchHabit(habitId, at: now, db: db)
    }

    /// Hebt `updated_at` des Habits an und markiert ihn als zu übertragen.
    ///
    /// Nötig, weil Regeln und Tag-Zuordnungen beim Abgleich **mit** dem Habit
    /// wandern und keine eigene Sequenznummer tragen (siehe server/README.md).
    /// Ohne diesen Anstoß bliebe eine Zeitplanänderung für den Server
    /// unsichtbar: der Habit sähe unverändert aus, und das zweite Gerät bekäme
    /// weiter den alten Zeitplan.
    static func touchHabit(_ habitId: UUID, at now: Date, db: Database) throws {
        try db.execute(sql: """
            UPDATE habit SET updated_at = ?, dirty = 1 WHERE id = ? AND deleted_at IS NULL
            """, arguments: [now, habitId.uuidString])
    }

    // MARK: - Kaskadierte Löschung

    /// Die Tabellen, deren Zeilen ohne ihren Habit sinnlos sind.
    ///
    /// Bewusst eine Liste und keine fünf ausgeschriebenen Anweisungen: Kaskade
    /// und Rücknahme müssen sich über dieselbe Menge einig sein, sonst bliebe
    /// beim Wiederherstellen eine Tabelle zurück.
    static let habitOwnedTables = ["entry", "entry_event", "day_exception",
                                   "habit_rule", "habit_tag"]

    /// Setzt Grabsteine auf alles, was an diesem Habit hängt.
    ///
    /// `WHERE habit_id = ?` schließt globale Ausnahmen (Urlaub, `habit_id IS
    /// NULL`) automatisch aus — die gehören keinem Habit und überleben ihn.
    ///
    /// Bereits gelöschte Zeilen bleiben unangetastet: sie hat der Nutzer selbst
    /// weggeräumt, und ein späteres Wiederherstellen des Habits soll sie nicht
    /// zurückholen.
    static func cascadeDelete(habitId: UUID, at now: Date, db: Database) throws {
        for table in habitOwnedTables {
            try db.execute(sql: """
                UPDATE "\(table)"
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = ?
                WHERE habit_id = ? AND deleted_at IS NULL
                """, arguments: [now, now, habitId.uuidString, habitId.uuidString])
        }
    }

    /// Nimmt genau die Löschungen zurück, die mit `originId` zusammen geschahen.
    static func cascadeRestore(originId: String, tables: [String], db: Database) throws {
        let now = Date()
        for table in tables {
            try db.execute(sql: """
                UPDATE "\(table)"
                SET deleted_at = NULL, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE deleted_with = ?
                """, arguments: [now, originId])
        }
    }

    // MARK: - Einträge

    static func upsertEntry(
        habitId: UUID, date: CalendarDate, value: Double, note: String?,
        source: EntrySource, userId: String, db: Database
    ) throws -> Entry {
        let now = Date()
        // Adressiert über den natürlichen Schlüssel (habit_id, date), nicht über
        // die ID — deshalb ist ein wiederholter Aufruf unschädlich.
        if var existing = try EntryRow.fetchOne(db, sql: """
            SELECT * FROM entry WHERE habit_id = ? AND date = ?
            """, arguments: [habitId.uuidString, date.description]) {
            existing.value = value
            existing.note = note
            existing.source = source
            existing.updatedAt = now
            existing.deletedAt = nil       // ein Wiedereintrag hebt den Grabstein auf
            existing.deletedWith = nil
            existing.dirty = true
            try existing.update(db)
            return existing.entry
        }

        var row = EntryRow(Entry(habitId: habitId, date: date, value: value,
                                 note: note, source: source,
                                 createdAt: now, updatedAt: now),
                           userId: userId)
        try row.insert(db)
        return row.entry
    }

    /// Hält die Invariante `entry.value == Σ events` für Habits mit `tracksTime`.
    ///
    /// Bewusst hier und nicht beim Aufrufer: die Summe darf nie auseinanderlaufen,
    /// und die Streak-Engine liest ausschließlich `entry.value`.
    static func recomputeEntry(
        habitId: UUID, date: CalendarDate, userId: String, db: Database
    ) throws {
        let sum = try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(value), 0) FROM entry_event
            WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
            """, arguments: [habitId.uuidString, date.description]) ?? 0

        let remaining = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry_event
            WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
            """, arguments: [habitId.uuidString, date.description]) ?? 0

        if remaining == 0 {
            // Ohne Events gibt es auch keinen abgeleiteten Tageswert mehr.
            try db.execute(sql: """
                UPDATE entry SET deleted_at = ?, updated_at = ?, dirty = 1
                WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
                """, arguments: [Date(), Date(), habitId.uuidString, date.description])
            return
        }

        _ = try upsertEntry(habitId: habitId, date: date, value: sum, note: nil,
                            source: .manual, userId: userId, db: db)
    }

    // MARK: - Nachtrage-Grenze

    /// Wirft, wenn ein Datum weiter zurückliegt als erlaubt.
    ///
    /// Ohne diese Grenze trägt man sich rückwirkend einen perfekten Monat ein
    /// und die eigenen Zahlen sind nichts mehr wert. Zukünftige Daten sind
    /// ebenfalls tabu — ein Habit lässt sich nicht im Voraus abhaken.
    static func checkBackfill(date: CalendarDate, today: CalendarDate, db: Database) throws {
        let limit = try readSetting(Self.backfillKey, db: db).flatMap(Int.init)
            ?? Self.defaultBackfillLimitDays
        if date > today {
            throw HabitStoreError.backfillLimitExceeded(date: date, limitDays: limit)
        }
        guard limit > 0 else { return }        // 0 heißt: unbegrenzt
        if date < today.adding(days: -limit) {
            throw HabitStoreError.backfillLimitExceeded(date: date, limitDays: limit)
        }
    }

    static let backfillKey = "backfill_limit_days"
    static let serverKey = "server_url"

    /// Die Serveradresse. **Nicht** das Token — das liegt im Schlüsselbund.
    public func serverURL() throws -> String? {
        try dbQueue.read { db in try Self.readSetting(Self.serverKey, db: db) }
    }

    public func setServerURL(_ url: String?) throws {
        try dbQueue.write { db in
            if let url {
                try db.execute(sql: """
                    INSERT INTO app_setting (key, value, updated_at, dirty) VALUES (?, ?, ?, 1)
                    ON CONFLICT (key) DO UPDATE SET value = excluded.value,
                                                    updated_at = excluded.updated_at, dirty = 1
                    """, arguments: [Self.serverKey, url, Date()])
            } else {
                try db.execute(sql: "DELETE FROM app_setting WHERE key = ?",
                               arguments: [Self.serverKey])
            }
        }
    }
    static let defaultBackfillLimitDays = 7

    static func readSetting(_ key: String, db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = ?",
                            arguments: [key])
    }

    public func backfillLimitDays() async throws -> Int {
        try await dbQueue.read { db in
            try Self.readSetting(Self.backfillKey, db: db).flatMap(Int.init)
                ?? Self.defaultBackfillLimitDays
        }
    }

    public func setBackfillLimitDays(_ days: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting (key, value, updated_at, dirty) VALUES (?, ?, ?, 1)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                    updated_at = excluded.updated_at, dirty = 1
                """, arguments: [Self.backfillKey, String(days), Date()])
        }
    }

    // MARK: - Papierkorb

    /// Wiederherstellbar sind die letzten 30 Tage.
    ///
    /// Grabsteine leben 90 Tage, weil der Sync sie so lange braucht. Etwas
    /// zurückzuholen, das andere Geräte vor Monaten verarbeitet haben, wäre
    /// aber verwirrend — deshalb zeigt der Papierkorb nur das jüngere Drittel.
    public static let trashWindowDays = 30

    public func trash() async throws -> [TrashItem] {
        let cutoff = Date().addingTimeInterval(-Double(Self.trashWindowDays) * 86400)
        return try await dbQueue.read { db in
            var items: [TrashItem] = []

            for row in try HabitRow.fetchAll(db, sql: """
                SELECT * FROM habit WHERE deleted_at IS NOT NULL AND deleted_at >= ?
                ORDER BY deleted_at DESC
                """, arguments: [cutoff]) {
                items.append(TrashItem(table: .habit, rowId: row.id,
                                       deletedAt: row.deletedAt!, label: row.name))
            }

            // `deleted_with IS NULL` lässt die Einträge weg, die mit ihrem
            // Habit gefallen sind: sie kommen mit ihm zurück, nicht einzeln.
            // Sonst stünde statt eines gelöschten Habits dessen ganzer Verlauf
            // im Papierkorb.
            for row in try EntryRow.fetchAll(db, sql: """
                SELECT * FROM entry
                WHERE deleted_at IS NOT NULL AND deleted_at >= ? AND deleted_with IS NULL
                ORDER BY deleted_at DESC
                """, arguments: [cutoff]) {
                items.append(TrashItem(table: .entry, rowId: row.id,
                                       deletedAt: row.deletedAt!,
                                       label: "Eintrag vom \(row.date)"))
            }

            for row in try TagRow.fetchAll(db, sql: """
                SELECT * FROM tag WHERE deleted_at IS NOT NULL AND deleted_at >= ?
                ORDER BY deleted_at DESC
                """, arguments: [cutoff]) {
                items.append(TrashItem(table: .tag, rowId: row.id,
                                       deletedAt: row.deletedAt!, label: row.name))
            }

            return items.sorted { $0.deletedAt > $1.deletedAt }
        }
    }

    /// Holt eine Zeile zurück — und mit ihr, was mit ihr zusammen gefallen ist.
    ///
    /// Maßgeblich ist `deleted_with`, nicht die Zugehörigkeit: ein Eintrag, den
    /// der Nutzer vor dem Löschen des Habits einzeln weggeräumt hatte, bleibt
    /// weg. Zurück kommt nur, was ohne sein Zutun verschwunden ist.
    public func restore(_ item: TrashItem) async throws {
        try await dbQueue.write { db in
            let table = item.table.rawValue
            try db.execute(sql: """
                UPDATE "\(table)" SET deleted_at = NULL, updated_at = ?, dirty = 1
                WHERE id = ?
                """, arguments: [Date(), item.rowId])

            switch item.table {
            case .habit:
                try Self.cascadeRestore(originId: item.rowId,
                                        tables: Self.habitOwnedTables, db: db)
            case .tag:
                // Ein Tag reißt nur seine Zuordnungen mit.
                try Self.cascadeRestore(originId: item.rowId,
                                        tables: ["habit_tag"], db: db)
            case .entry, .entryEvent, .dayException, .dayLog:
                break
            }
        }
    }
}
