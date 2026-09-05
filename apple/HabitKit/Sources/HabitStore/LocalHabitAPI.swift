import Foundation
import GRDB
import HabitCore

/// `HabitAPI` gegen eine lokale SQLite-Datenbank.
///
/// Auf Mac und iPhone die dauerhafte Implementierung, nicht nur ein Platzhalter
/// bis zum Server: ein Telefon ist regelmäßig offline, und eine App, die dann
/// nichts anzeigt, ist unbrauchbar. Der Server kommt später *daneben* als
/// Abgleich, nicht davor als Vorbedingung.
public final class LocalHabitAPI: HabitAPI {
    let dbQueue: DatabaseQueue
    let userId: String
    /// Injizierbar, damit Tests einen festen Stichtag setzen können.
    let currentDate: @Sendable () -> CalendarDate

    public init(
        dbQueue: DatabaseQueue,
        userId: String = Habit.localUserId,
        currentDate: @escaping @Sendable () -> CalendarDate = { CalendarDate.today() }
    ) throws {
        self.dbQueue = dbQueue
        self.userId = userId
        self.currentDate = currentDate
        try Schema.migrator.migrate(dbQueue)
    }

    /// Datenbank an der Standardstelle im Anwendungsordner.
    public convenience init(
        url: URL,
        userId: String = Habit.localUserId,
        currentDate: @escaping @Sendable () -> CalendarDate = { CalendarDate.today() }
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(dbQueue: try DatabaseQueue(path: url.path),
                      userId: userId, currentDate: currentDate)
    }

    /// Für Tests: Datenbank nur im Speicher.
    public static func inMemory(
        userId: String = Habit.localUserId,
        currentDate: @escaping @Sendable () -> CalendarDate = { CalendarDate.today() }
    ) throws -> LocalHabitAPI {
        try LocalHabitAPI(dbQueue: try DatabaseQueue(),
                          userId: userId, currentDate: currentDate)
    }

    // MARK: - Habits

    public func listHabits(includeArchived: Bool = false) async throws -> [Habit] {
        try await dbQueue.read { [userId] db in
            var request = HabitRow
                .filter(sql: "deleted_at IS NULL AND user_id = ?", arguments: [userId])
            if !includeArchived {
                request = request.filter(sql: "archived_on IS NULL")
            }
            let rows = try request.order(sql: "sort_order, name").fetchAll(db)
            return try rows.map { try Self.assemble($0, db: db) }
        }
    }

    public func habit(id: UUID) async throws -> Habit? {
        try await dbQueue.read { db in
            guard let row = try Self.habitRow(id, db: db) else { return nil }
            return try Self.assemble(row, db: db)
        }
    }

    public func createHabit(_ draft: HabitDraft) async throws -> Habit {
        guard !draft.rules.isEmpty else { throw HabitStoreError.needsAtLeastOneRule }
        let now = Date()
        let habit = Habit(
            userId: userId, name: draft.name, notes: draft.notes, kind: draft.kind,
            rules: draft.rules, colorHex: draft.colorHex, symbol: draft.symbol,
            sortOrder: 0, tagIds: draft.tagIds, timeOfDay: draft.timeOfDay,
            preferredTime: draft.preferredTime, tracksTime: draft.tracksTime,
            startsOn: draft.startsOn, endsOn: draft.endsOn,
            createdAt: now, updatedAt: now
        )

        return try await dbQueue.write { db in
            var row = try HabitRow(habit)
            // Ans Ende der Liste, nicht an den Anfang.
            row.sortOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM habit WHERE deleted_at IS NULL
                """) ?? 0
            try row.insert(db)

            for rule in habit.rules {
                var ruleRow = try HabitRuleRow(habitId: habit.id, rule: rule, now: now)
                try ruleRow.insert(db)
            }
            try Self.replaceTags(habitId: habit.id, tagIds: draft.tagIds, now: now, db: db)
            return try Self.assemble(row, db: db)
        }
    }

    public func updateHabit(id: UUID, _ patch: HabitPatch) async throws -> Habit {
        try await dbQueue.write { db in
            guard var row = try Self.habitRow(id, db: db) else {
                throw HabitStoreError.habitNotFound(id)
            }
            if let v = patch.name { row.name = v }
            if let v = patch.notes { row.notes = v }
            if let v = patch.colorHex { row.colorHex = v }
            if let v = patch.symbol { row.symbol = v }
            if let v = patch.sortOrder { row.sortOrder = v }
            if let v = patch.timeOfDay { row.timeOfDay = v }
            if let v = patch.preferredTime { row.preferredTime = v }
            if let v = patch.tracksTime { row.tracksTime = v }
            if let v = patch.startsOn { row.startsOn = v }
            if let v = patch.endsOn { row.endsOn = v }
            if let v = patch.archivedOn { row.archivedOn = v }
            if let v = patch.healthKitLink { row.healthKitLink = try v.map(JSONColumn.encode) }
            row.updatedAt = Date()
            row.dirty = true
            try row.update(db)
            return try Self.assemble(row, db: db)
        }
    }

    /// Löscht einen Habit weich — samt allem, was an ihm hängt.
    ///
    /// Die Fremdschlüssel tragen zwar `ON DELETE CASCADE`, das greift aber nur
    /// bei einer harten Löschung. Hier wird weich gelöscht, also müssen die
    /// Grabsteine der abhängigen Zeilen von Hand gesetzt werden: eine Löschung
    /// ohne Grabstein ist für den Sync unsichtbar und käme auf einem zweiten
    /// Gerät nie an — dort stünden die Einträge eines längst gelöschten Habits.
    ///
    /// Alle Zeilen bekommen denselben Zeitstempel und in `deleted_with` die id
    /// des Habits. Daran erkennt `restore` später genau die Zeilen, die mit
    /// diesem Habit gefallen sind — und lässt die in Ruhe, die der Nutzer vorher
    /// einzeln gelöscht hatte.
    public func deleteHabit(id: UUID) async throws {
        try await dbQueue.write { db in
            let now = Date()
            try db.execute(sql: """
                UPDATE habit SET deleted_at = ?, updated_at = ?, dirty = 1
                WHERE id = ? AND deleted_at IS NULL
                """, arguments: [now, now, id.uuidString])
            // War der Habit schon gelöscht, darf ein zweiter Aufruf die
            // Herkunft der Kinder nicht neu stempeln.
            guard db.changesCount > 0 else { return }
            try Self.cascadeDelete(habitId: id, at: now, db: db)
        }
    }

    public func setRule(habitId: UUID, _ rule: HabitRule) async throws -> Habit {
        try await dbQueue.write { db in
            guard let row = try Self.habitRow(habitId, db: db) else {
                throw HabitStoreError.habitNotFound(habitId)
            }
            var ruleRow = try HabitRuleRow(habitId: habitId, rule: rule)
            // Upsert über den natürlichen Schlüssel (habit_id, effective_from):
            // „Ziel ab heute ändern" legt an, „Tippfehler korrigieren" ersetzt.
            try ruleRow.upsert(db)
            return try Self.assemble(row, db: db)
        }
    }

    public func deleteRule(habitId: UUID, effectiveFrom: CalendarDate) async throws -> Habit {
        try await dbQueue.write { db in
            guard let row = try Self.habitRow(habitId, db: db) else {
                throw HabitStoreError.habitNotFound(habitId)
            }
            let remaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM habit_rule
                WHERE habit_id = ? AND deleted_at IS NULL AND effective_from <> ?
                """, arguments: [habitId.uuidString, effectiveFrom.description]) ?? 0
            // Ohne Regel wäre der Habit an keinem Tag mehr auswertbar.
            guard remaining > 0 else { throw HabitStoreError.needsAtLeastOneRule }

            try db.execute(sql: """
                UPDATE habit_rule
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE habit_id = ? AND effective_from = ? AND deleted_at IS NULL
                """, arguments: [Date(), Date(), habitId.uuidString, effectiveFrom.description])
            guard db.changesCount > 0 else {
                throw HabitStoreError.ruleNotFound(habitId: habitId, effectiveFrom: effectiveFrom)
            }
            return try Self.assemble(row, db: db)
        }
    }

    // MARK: - Tags

    public func tags() async throws -> [Tag] {
        try await dbQueue.read { [userId] db in
            try TagRow
                .filter(sql: "deleted_at IS NULL AND user_id = ?", arguments: [userId])
                .order(sql: "sort_order, name")
                .fetchAll(db)
                .map(\.tag)
        }
    }

    public func createTag(name: String, colorHex: String = "#8E8E93") async throws -> Tag {
        let tag = Tag(userId: userId, name: name, colorHex: colorHex)
        return try await dbQueue.write { db in
            var row = TagRow(tag)
            row.sortOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tag WHERE deleted_at IS NULL
                """) ?? 0
            try row.insert(db)
            return row.tag
        }
    }

    public func updateTag(_ tag: Tag) async throws -> Tag {
        try await dbQueue.write { db in
            var row = TagRow(tag)
            row.updatedAt = Date()
            try row.update(db)
            return row.tag
        }
    }

    public func deleteTag(id: UUID) async throws {
        try await dbQueue.write { db in
            let now = Date()
            try db.execute(sql: """
                UPDATE tag SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE id = ?
                """, arguments: [now, now, id.uuidString])
            // Die Zuordnungen brauchen eigene Grabsteine, sonst käme das
            // Entfernen auf anderen Geräten nie an. `deleted_with` trennt sie
            // von Zuordnungen, die mit einem Habit gefallen sind.
            try db.execute(sql: """
                UPDATE habit_tag
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = ?
                WHERE tag_id = ? AND deleted_at IS NULL
                """, arguments: [now, now, id.uuidString, id.uuidString])
        }
    }

    public func setTags(habitId: UUID, tagIds: [UUID]) async throws -> Habit {
        try await dbQueue.write { db in
            guard let row = try Self.habitRow(habitId, db: db) else {
                throw HabitStoreError.habitNotFound(habitId)
            }
            try Self.replaceTags(habitId: habitId, tagIds: tagIds, now: Date(), db: db)
            return try Self.assemble(row, db: db)
        }
    }

    // MARK: - Einträge

    public func entries(habitId: UUID? = nil, from: CalendarDate, to: CalendarDate) async throws -> [Entry] {
        try await dbQueue.read { [userId] db in
            var sql = """
                SELECT * FROM entry
                WHERE deleted_at IS NULL AND user_id = ? AND date BETWEEN ? AND ?
                """
            var args: [any DatabaseValueConvertible] = [userId, from.description, to.description]
            if let habitId {
                sql += " AND habit_id = ?"
                args.append(habitId.uuidString)
            }
            sql += " ORDER BY date"
            return try EntryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map(\.entry)
        }
    }

    @discardableResult
    public func setEntry(
        habitId: UUID, date: CalendarDate, value: Double,
        note: String? = nil, source: EntrySource = .manual
    ) async throws -> Entry {
        let today = currentDate()
        return try await dbQueue.write { [userId] db in
            try Self.checkBackfill(date: date, today: today, db: db)
            guard let habitRow = try Self.habitRow(habitId, db: db) else {
                throw HabitStoreError.habitNotFound(habitId)
            }

            // Bei Habits mit Zeitstempeln ist der Tageswert abgeleitet. Ihn direkt
            // zu setzen heißt: die Events dieses Tages werden ersetzt, sonst
            // widersprächen sich Summe und Tageswert.
            if habitRow.tracksTime {
                try db.execute(sql: """
                    UPDATE entry_event SET deleted_at = ?, updated_at = ?, dirty = 1
                    WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
                    """, arguments: [Date(), Date(), habitId.uuidString, date.description])
            }

            return try Self.upsertEntry(habitId: habitId, date: date, value: value,
                                        note: note, source: source, userId: userId, db: db)
        }
    }

    public func deleteEntry(habitId: UUID, date: CalendarDate) async throws {
        let today = currentDate()
        try await dbQueue.write { db in
            try Self.checkBackfill(date: date, today: today, db: db)
            let now = Date()
            try db.execute(sql: """
                UPDATE entry
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
                """, arguments: [now, now, habitId.uuidString, date.description])
            try db.execute(sql: """
                UPDATE entry_event
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE habit_id = ? AND date = ? AND deleted_at IS NULL
                """, arguments: [now, now, habitId.uuidString, date.description])
        }
    }

    // MARK: - Zeitstempel-Detail

    public func events(habitId: UUID, from: CalendarDate, to: CalendarDate) async throws -> [EntryEvent] {
        try await dbQueue.read { db in
            try EntryEventRow.fetchAll(db, sql: """
                SELECT * FROM entry_event
                WHERE deleted_at IS NULL AND habit_id = ? AND date BETWEEN ? AND ?
                ORDER BY at
                """, arguments: [habitId.uuidString, from.description, to.description])
                .map(\.event)
        }
    }

    @discardableResult
    public func setEvent(_ event: EntryEvent) async throws -> EntryEvent {
        let today = currentDate()
        return try await dbQueue.write { [userId] db in
            try Self.checkBackfill(date: event.date, today: today, db: db)
            var row = EntryEventRow(event)
            row.updatedAt = Date()
            try row.upsert(db)
            try Self.recomputeEntry(habitId: event.habitId, date: event.date,
                                    userId: userId, db: db)
            return row.event
        }
    }

    public func deleteEvent(habitId: UUID, eventId: UUID) async throws {
        try await dbQueue.write { [userId] db in
            guard let row = try EntryEventRow.fetchOne(db, sql: """
                SELECT * FROM entry_event WHERE id = ? AND deleted_at IS NULL
                """, arguments: [eventId.uuidString]) else { return }
            try db.execute(sql: """
                UPDATE entry_event
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE id = ?
                """, arguments: [Date(), Date(), eventId.uuidString])
            try Self.recomputeEntry(habitId: habitId, date: row.date, userId: userId, db: db)
        }
    }

    // MARK: - Journal und Ausnahmen

    public func dayLogs(from: CalendarDate, to: CalendarDate) async throws -> [DayLog] {
        try await dbQueue.read { [userId] db in
            try DayLogRow.fetchAll(db, sql: """
                SELECT * FROM day_log
                WHERE deleted_at IS NULL AND user_id = ? AND date BETWEEN ? AND ?
                ORDER BY date
                """, arguments: [userId, from.description, to.description])
                .map(\.log)
        }
    }

    @discardableResult
    public func setDayLog(_ log: DayLog) async throws -> DayLog {
        try await dbQueue.write { db in
            var row = DayLogRow(log)
            row.updatedAt = Date()
            row.deletedAt = nil
            try row.upsert(db)
            return row.log
        }
    }

    public func exceptions(from: CalendarDate, to: CalendarDate) async throws -> [DayException] {
        try await dbQueue.read { [userId] db in
            try DayExceptionRow.fetchAll(db, sql: """
                SELECT * FROM day_exception
                WHERE deleted_at IS NULL AND user_id = ? AND date BETWEEN ? AND ?
                ORDER BY date
                """, arguments: [userId, from.description, to.description])
                .map(\.exception)
        }
    }

    @discardableResult
    public func addException(_ exception: DayException) async throws -> DayException {
        try await dbQueue.write { [userId] db in
            var row = DayExceptionRow(exception, userId: userId)
            try row.upsert(db)
            return row.exception
        }
    }

    public func deleteException(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE day_exception
                SET deleted_at = ?, updated_at = ?, dirty = 1, deleted_with = NULL
                WHERE id = ?
                """, arguments: [Date(), Date(), id.uuidString])
        }
    }

    // MARK: - Auswertung

    public func stats(habitId: UUID, from: CalendarDate, to: CalendarDate) async throws -> HabitStats {
        guard let habit = try await habit(id: habitId) else {
            throw HabitStoreError.habitNotFound(habitId)
        }
        let entries = try await entries(habitId: habitId, from: from, to: to)
        let exceptions = try await exceptions(from: from, to: to)
        return HabitCore.stats(for: habit, entries: entries, exceptions: exceptions,
                               from: from, to: to, today: currentDate())
    }

    public func trend(habitId: UUID) async throws -> Trend? {
        guard let habit = try await habit(id: habitId) else {
            throw HabitStoreError.habitNotFound(habitId)
        }
        let today = currentDate()
        // Der Trend vergleicht zwei 14-Tage-Fenster, endend gestern.
        let from = today.adding(days: -28)
        let entries = try await entries(habitId: habitId, from: from, to: today)
        let exceptions = try await exceptions(from: from, to: today)
        return HabitCore.trend(for: habit, entries: entries, exceptions: exceptions, today: today)
    }
}
