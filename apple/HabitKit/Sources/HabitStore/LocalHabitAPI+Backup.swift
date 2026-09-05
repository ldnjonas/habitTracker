import Foundation
import GRDB
import HabitCore

// MARK: - Export

extension LocalHabitAPI {

    /// Wer die Datei geschrieben hat — landet zur Nachvollziehbarkeit in der Datei.
    public static var defaultGenerator: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        #if os(macOS)
        let platform = "macOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "unknown"
        #endif
        return "HabitTracker/\(version) (\(platform))"
    }

    /// Schreibt den Bestand in eine Sicherungsdatei.
    ///
    /// `habitIds == nil` sichert alles, sonst nur die genannten Habits samt
    /// ihrem Verlauf. Archivierte Habits sind immer dabei — sie sind der Grund,
    /// warum man eine Sicherung überhaupt aufhebt.
    ///
    /// Gelöschte Zeilen bleiben draußen: eine Sicherung beschreibt den Bestand,
    /// nicht seine Geschichte.
    public func exportBackup(
        habitIds: Set<UUID>? = nil,
        generator: String = LocalHabitAPI.defaultGenerator
    ) async throws -> BackupFile {
        try await dbQueue.read { [userId] db in
            let habitRows = try HabitRow.fetchAll(db, sql: """
                SELECT * FROM habit
                WHERE user_id = ? AND deleted_at IS NULL
                ORDER BY sort_order, name
                """, arguments: [userId])

            let selected = habitRows.filter { row in
                guard let habitIds, let id = UUID(uuidString: row.id) else { return habitIds == nil }
                return habitIds.contains(id)
            }
            let habits = try selected.map { try LocalHabitAPI.assemble($0, db: db) }
            let ids = Set(habits.map(\.id.uuidString))

            // Nur die Tags mitnehmen, die von den ausgewählten Habits benutzt
            // werden — eine Einzel-Habit-Sicherung soll nicht die ganze
            // Tag-Sammlung mitschleppen.
            let usedTagIds = Set(habits.flatMap(\.tagIds).map(\.uuidString))
            let tags = try TagRow.fetchAll(db, sql: """
                SELECT * FROM tag WHERE user_id = ? AND deleted_at IS NULL ORDER BY sort_order, name
                """, arguments: [userId])
                .filter { habitIds == nil || usedTagIds.contains($0.id) }
                .map(\.tag)

            // Ein Datensatz kommt nur mit, wenn sein Habit ebenfalls in der
            // Datei steht. Das gilt auch beim Vollexport: ein gelöschter Habit
            // lässt seine Einträge zurück (sie tragen keinen eigenen Grabstein),
            // und die gehören nicht in eine Sicherung — beim Einspielen fänden
            // sie keinen Bezugspunkt mehr.
            func belongs(_ habitId: String?) -> Bool {
                guard let habitId else { return habitIds == nil }   // global gilt nur beim Vollexport
                return ids.contains(habitId)
            }

            let entries = try EntryRow.fetchAll(db, sql: """
                SELECT * FROM entry WHERE user_id = ? AND deleted_at IS NULL ORDER BY habit_id, date
                """, arguments: [userId])
                .filter { belongs($0.habitId) }.map(\.entry)

            let events = try EntryEventRow.fetchAll(db, sql: """
                SELECT * FROM entry_event WHERE deleted_at IS NULL ORDER BY habit_id, at
                """).filter { belongs($0.habitId) }.map(\.event)

            let exceptions = try DayExceptionRow.fetchAll(db, sql: """
                SELECT * FROM day_exception WHERE user_id = ? AND deleted_at IS NULL ORDER BY date
                """, arguments: [userId])
                .filter { belongs($0.habitId) }.map(\.exception)

            // Das Journal hängt an keinem Habit und gehört deshalb nur in eine
            // vollständige Sicherung.
            let dayLogs = habitIds == nil
                ? try DayLogRow.fetchAll(db, sql: """
                    SELECT * FROM day_log WHERE user_id = ? AND deleted_at IS NULL ORDER BY date
                    """, arguments: [userId]).map(\.log)
                : []

            return BackupFile(
                generator: generator,
                scope: habitIds == nil ? .full : .habits,
                habits: habits, tags: tags, entries: entries,
                events: events, exceptions: exceptions, dayLogs: dayLogs)
        }
    }
}

// MARK: - Import

extension LocalHabitAPI {

    /// Spielt eine Sicherungsdatei ein.
    ///
    /// Läuft in **einer** Transaktion: entweder ist am Ende alles drin oder
    /// nichts. Ein halb eingespieltes Backup wäre schlimmer als ein fehlgeschlagenes.
    ///
    /// Die `userId` aus der Datei wird verworfen und durch die lokale ersetzt —
    /// dadurch lässt sich eine Sicherung in ein anderes Konto einspielen.
    @discardableResult
    public func importBackup(_ file: BackupFile, mode: ImportMode) async throws -> ImportReport {
        let problems = HabitCore.validate(file)
        if problems.contains(where: \.isFatal) {
            throw BackupError.invalidFile(problems.filter(\.isFatal))
        }

        return try await dbQueue.write { [userId] db in
            var report = ImportReport(mode: mode)
            report.problems = problems
            let now = Date()

            if mode == .replace {
                // Harte Löschung, kein Grabstein: „Ersetzen" heißt, dass der
                // bisherige Bestand nicht mehr existiert — auch nicht als Rest,
                // den ein späterer Sync wieder ans Licht holt.
                for table in ["entry_event", "entry", "day_exception", "habit_tag",
                              "habit_rule", "habit", "tag", "day_log"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }

            // --- Tags zuerst: habit_tag verweist auf sie.
            for tag in file.tags {
                var row = TagRow(tag)
                row.userId = userId
                let existing = try TagRow.fetchOne(
                    db, sql: "SELECT * FROM tag WHERE id = ?", arguments: [row.id])
                switch merge(existing?.updatedAt, row.updatedAt, mode) {
                case .insert: try row.insert(db); report.tags.inserted += 1
                case .update: try row.upsert(db); report.tags.updated += 1
                case .skip: report.tags.skipped += 1
                }
            }

            // Welche Tags nach dem Einspielen wirklich existieren.
            let knownTags = Set(try String.fetchAll(db, sql: "SELECT id FROM tag"))

            // --- Habits samt Regeln und Tag-Zuordnung.
            var droppedTagLinks = 0
            for habit in file.habits {
                var row = try HabitRow(habit)
                row.userId = userId
                let existing = try HabitRow.fetchOne(
                    db, sql: "SELECT * FROM habit WHERE id = ?", arguments: [row.id])
                let decision = merge(existing?.updatedAt, row.updatedAt, mode)
                guard decision != .skip else { report.habits.skipped += 1; continue }

                try row.upsert(db)
                decision == .insert ? (report.habits.inserted += 1) : (report.habits.updated += 1)

                // Regeln und Tags gehören zum Habit und werden mit ihm als
                // Einheit ersetzt — eine teilweise übernommene Zeitplan-Historie
                // wäre schwerer zu erklären als eine ersetzte.
                try db.execute(sql: "DELETE FROM habit_rule WHERE habit_id = ?",
                               arguments: [row.id])
                for rule in habit.rules {
                    var ruleRow = try HabitRuleRow(habitId: habit.id, rule: rule, now: now)
                    ruleRow.createdAt = habit.createdAt
                    ruleRow.updatedAt = habit.updatedAt
                    try ruleRow.insert(db)
                }

                let usable = habit.tagIds.filter { knownTags.contains($0.uuidString) }
                droppedTagLinks += habit.tagIds.count - usable.count
                try LocalHabitAPI.replaceTags(habitId: habit.id, tagIds: usable, now: now, db: db)
            }
            if droppedTagLinks > 0 {
                report.problems.append(.orphanedRows(table: "habit_tag", count: droppedTagLinks))
            }

            // Bezugspunkt für alles Weitere: ein Eintrag ohne Habit ist nicht
            // speicherbar — die Fremdschlüsselbedingung würde ihn ohnehin abweisen.
            let knownHabits = Set(try String.fetchAll(db, sql: "SELECT id FROM habit"))

            // --- Einträge: über den natürlichen Schlüssel, nicht über die id.
            //
            // Zwei Geräte, die denselben Tag abgehakt haben, erzeugen zwei
            // verschiedene ids für denselben Sachverhalt. Würde hier nach id
            // gesucht, liefe der Import in die Eindeutigkeitsbedingung von
            // (habit_id, date). Die vorhandene id bleibt deshalb bestehen.
            var orphanedEntries = 0
            for entry in file.entries {
                guard knownHabits.contains(entry.habitId.uuidString) else {
                    orphanedEntries += 1; continue
                }
                var row = EntryRow(entry, userId: userId)
                let existing = try EntryRow.fetchOne(db, sql: """
                    SELECT * FROM entry WHERE habit_id = ? AND date = ?
                    """, arguments: [row.habitId, row.date])
                switch merge(existing?.updatedAt, row.updatedAt, mode) {
                case .insert: try row.insert(db); report.entries.inserted += 1
                case .update:
                    row.id = existing?.id ?? row.id
                    try row.upsert(db); report.entries.updated += 1
                case .skip: report.entries.skipped += 1
                }
            }
            if orphanedEntries > 0 {
                report.problems.append(.orphanedRows(table: "entry", count: orphanedEntries))
            }

            // --- Zeitstempel-Detail.
            var orphanedEvents = 0
            for event in file.events {
                guard knownHabits.contains(event.habitId.uuidString) else {
                    orphanedEvents += 1; continue
                }
                var row = EntryEventRow(event)
                let existing = try EntryEventRow.fetchOne(
                    db, sql: "SELECT * FROM entry_event WHERE id = ?", arguments: [row.id])
                switch merge(existing?.updatedAt, row.updatedAt, mode) {
                case .insert: try row.insert(db); report.events.inserted += 1
                case .update: try row.upsert(db); report.events.updated += 1
                case .skip: report.events.skipped += 1
                }
            }
            if orphanedEvents > 0 {
                report.problems.append(.orphanedRows(table: "entry_event", count: orphanedEvents))
            }

            // --- Ausnahmen. Über die id, nicht über (habitId, date): an einem
            // Tag können ein Freeze und eine Pause nebeneinander stehen.
            var orphanedExceptions = 0
            for exception in file.exceptions {
                if let habitId = exception.habitId,
                   !knownHabits.contains(habitId.uuidString) {
                    orphanedExceptions += 1; continue
                }
                var row = DayExceptionRow(exception, userId: userId)
                let existing = try DayExceptionRow.fetchOne(
                    db, sql: "SELECT * FROM day_exception WHERE id = ?", arguments: [row.id])
                switch merge(existing?.updatedAt, row.updatedAt, mode) {
                case .insert: try row.insert(db); report.exceptions.inserted += 1
                case .update: try row.upsert(db); report.exceptions.updated += 1
                case .skip: report.exceptions.skipped += 1
                }
            }
            if orphanedExceptions > 0 {
                report.problems.append(.orphanedRows(table: "day_exception",
                                                     count: orphanedExceptions))
            }

            // --- Journal, Schlüssel (user_id, date).
            for log in file.dayLogs {
                var row = DayLogRow(log)
                row.userId = userId
                let existing = try DayLogRow.fetchOne(db, sql: """
                    SELECT * FROM day_log WHERE user_id = ? AND date = ?
                    """, arguments: [userId, row.date])
                switch merge(existing?.updatedAt, row.updatedAt, mode) {
                case .insert: try row.insert(db); report.dayLogs.inserted += 1
                case .update: try row.upsert(db); report.dayLogs.updated += 1
                case .skip: report.dayLogs.skipped += 1
                }
            }

            return report
        }
    }
}

// MARK: - Konfliktregel

private enum MergeDecision { case insert, update, skip }

/// Wer gewinnt, wenn eine Zeile schon da ist.
///
/// Beim Zusammenführen entscheidet `updatedAt` — dieselbe Last-Write-Wins-Regel,
/// nach der später auch der Sync arbeitet. Beim Ersetzen ist die Tabelle vorher
/// leer, dort kann es keinen Konflikt geben.
private func merge(_ existing: Date?, _ incoming: Date, _ mode: ImportMode) -> MergeDecision {
    guard let existing else { return .insert }
    if mode == .replace { return .update }
    return incoming > existing ? .update : .skip
}
