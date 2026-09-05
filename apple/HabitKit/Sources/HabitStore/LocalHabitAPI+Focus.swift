import Foundation
import GRDB
import HabitCore

extension LocalHabitAPI {

    /// Alle Läufe, der jüngste zuerst.
    public func focusRuns() async throws -> [FocusRun] {
        try await dbQueue.read { [userId] db in
            try FocusRunRow.fetchAll(db, sql: """
                SELECT * FROM focus_run
                WHERE user_id = ? AND deleted_at IS NULL
                ORDER BY starts_on DESC
                """, arguments: [userId]).map { try $0.focus }
        }
    }

    /// Alle Läufe ausgewertet, der jüngste zuerst.
    ///
    /// Die Einträge werden **einmal** über das umspannende Fenster aller Läufe
    /// geladen, nicht je Lauf: bei zwanzig Läufen wären das sonst zwanzig
    /// Abfragen für weitgehend dieselben Zeilen.
    public func focusProgress() async throws -> [FocusProgress] {
        let runs = try await focusRuns()
        guard let from = runs.map(\.startsOn).min(),
              let to = runs.map(\.endsOn).max() else { return [] }

        let today = currentDate()
        let habits = try await listHabits(includeArchived: true)
        let entries = try await entries(habitId: nil, from: from, to: to)
        let exceptions = try await exceptions(from: from, to: to)

        return runs.map {
            HabitCore.evaluate($0, habits: habits, entries: entries,
                               exceptions: exceptions, today: today)
        }
    }

    /// Der offene Lauf, falls einer existiert.
    public func activeFocus() async throws -> FocusProgress? {
        try await focusProgress().first { $0.outcome.isOpen }
    }

    /// Startet einen Lauf ab heute.
    ///
    /// Bewusst nicht rückwirkend startbar: sonst trüge man sich nachträglich
    /// eine geschaffte Woche ein, und die Bilanz wäre nichts wert. Aus demselben
    /// Grund gibt es keinen Weg, das Ergebnis von Hand zu setzen.
    @discardableResult
    public func startFocus(
        days: Int = 7,
        habitIds: [UUID] = [],
        title: String? = nil
    ) async throws -> FocusRun {
        guard days >= 1 else { throw HabitStoreError.invalidFocusLength(days) }

        // Einen noch heilen Lauf darf ein neuer nicht still verdrängen. Einen
        // bereits gerissenen schon — sofort neu anfangen zu dürfen ist der
        // Sinn eines Fokus, nicht bis zum Fensterende warten zu müssen.
        if let open = try await activeFocus() {
            throw HabitStoreError.focusAlreadyRunning(id: open.run.id,
                                                      endsOn: open.run.endsOn)
        }

        let today = currentDate()
        let run = FocusRun(userId: userId, title: title,
                           startsOn: today, endsOn: today.adding(days: days - 1),
                           habitIds: habitIds)
        try await dbQueue.write { db in
            var row = try FocusRunRow(run)
            try row.insert(db)
        }
        return run
    }

    /// Beendet einen Lauf vorzeitig.
    public func abandonFocus(id: UUID) async throws {
        let today = currentDate()
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE focus_run SET abandoned_on = ?, updated_at = ?, dirty = 1
                WHERE id = ? AND abandoned_on IS NULL
                """, arguments: [today.description, Date(), id.uuidString])
        }
    }

    /// Entfernt einen Lauf aus dem Verlauf.
    public func deleteFocusRun(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE focus_run SET deleted_at = ?, updated_at = ?, dirty = 1
                WHERE id = ? AND deleted_at IS NULL
                """, arguments: [Date(), Date(), id.uuidString])
        }
    }
}
