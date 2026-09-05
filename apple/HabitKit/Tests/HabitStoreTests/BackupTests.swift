import Testing
import Foundation
import HabitCore
@testable import HabitStore

private let today = CalendarDate(iso: "2026-09-04")!
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func makeStore() throws -> LocalHabitAPI {
    try LocalHabitAPI.inMemory(currentDate: { today })
}

private func draft(_ name: String, from: String = "2026-08-01") -> HabitDraft {
    HabitDraft(name: name,
               rules: [HabitRule(effectiveFrom: d(from), schedule: .daily)])
}

/// Legt einen Bestand an, der jede Tabelle berührt.
@discardableResult
private func seed(_ store: LocalHabitAPI) async throws -> (sport: Habit, lesen: Habit) {
    let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
    var sport = try await store.createHabit(HabitDraft(
        name: "Sport", kind: .quantity,
        rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily,
                          target: Target(value: 30, unit: "min", comparison: .atLeast))],
        notes: "auch kurz zählt", colorHex: "#FF9500", symbol: "figure.run",
        timeOfDay: .morning, tracksTime: true))
    sport = try await store.setTags(habitId: sport.id, tagIds: [tag.id])

    let lesen = try await store.createHabit(draft("Lesen"))

    try await store.setEntry(habitId: sport.id, date: d("2026-09-02"),
                             value: 45, note: "Laufband", source: .manual)
    try await store.setEntry(habitId: sport.id, date: d("2026-09-03"),
                             value: 30, note: nil, source: .manual)
    try await store.setEntry(habitId: lesen.id, date: d("2026-09-03"),
                             value: 1, note: nil, source: .manual)

    _ = try await store.setEvent(EntryEvent(habitId: sport.id, date: d("2026-09-02"),
                                            at: Date(timeIntervalSince1970: 1_788_000_000),
                                            value: 45))
    _ = try await store.addException(DayException(habitId: lesen.id, date: d("2026-09-01"),
                                                  kind: .frozen, reason: "krank"))
    _ = try await store.setDayLog(DayLog(date: d("2026-09-03"), mood: 4, energy: 3,
                                         sleepHours: 7.5, note: "gut geschlafen"))
    return (sport, lesen)
}

@Suite("Sicherung: Export")
struct BackupExportTests {

    @Test("Ein Vollexport enthält jede Tabelle")
    func fullExport() async throws {
        let store = try makeStore()
        try await seed(store)

        let file = try await store.exportBackup(generator: "Test/1.0")
        #expect(file.scope == .full)
        #expect(file.formatVersion == BackupFile.currentFormatVersion)
        #expect(file.habits.count == 2)
        #expect(file.tags.count == 1)
        #expect(file.entries.count == 3)
        #expect(file.events.count == 1)
        #expect(file.exceptions.count == 1)
        #expect(file.dayLogs.count == 1)
        #expect(file.dateRange?.from == d("2026-09-01"))
        #expect(file.dateRange?.to == d("2026-09-03"))
    }

    @Test("Ein Einzelexport nimmt nur den gewählten Habit mit")
    func singleHabitExport() async throws {
        let store = try makeStore()
        let (sport, _) = try await seed(store)

        let file = try await store.exportBackup(habitIds: [sport.id], generator: "Test/1.0")
        #expect(file.scope == .habits)
        #expect(file.habits.map(\.name) == ["Sport"])
        #expect(file.entries.allSatisfy { $0.habitId == sport.id })
        #expect(file.entries.count == 2)
        #expect(file.events.count == 1)
        // Die Ausnahme hing an „Lesen“ …
        #expect(file.exceptions.isEmpty)
        // … und das Journal gehört zu keinem Habit.
        #expect(file.dayLogs.isEmpty)
        // Nur der tatsächlich benutzte Tag wandert mit.
        #expect(file.tags.map(\.name) == ["Gesundheit"])
    }

    @Test("Gelöschte Zeilen bleiben draußen")
    func tombstonesExcluded() async throws {
        let store = try makeStore()
        let (_, lesen) = try await seed(store)
        try await store.deleteHabit(id: lesen.id)

        let file = try await store.exportBackup(generator: "Test/1.0")
        #expect(file.habits.map(\.name) == ["Sport"])
        #expect(file.entries.allSatisfy { $0.habitId != lesen.id })
    }

    @Test("Archivierte Habits sind Teil der Sicherung")
    func archivedIncluded() async throws {
        let store = try makeStore()
        let (_, lesen) = try await seed(store)
        _ = try await store.updateHabit(id: lesen.id, HabitPatch(archivedOn: .some(today)))

        let file = try await store.exportBackup(generator: "Test/1.0")
        #expect(file.habits.count == 2)
        #expect(file.habits.first { $0.name == "Lesen" }?.archivedOn == today)
    }
}

@Suite("Sicherung: Dateiformat")
struct BackupCodingTests {

    @Test("Die Datei überlebt eine Runde durch JSON unverändert")
    func jsonRoundTrip() async throws {
        let store = try makeStore()
        try await seed(store)
        let file = try await store.exportBackup(generator: "Test/1.0")

        // Einmal kodiert, ist die Datei ein Fixpunkt: Dekodieren und erneutes
        // Kodieren muss dasselbe Byte-für-Byte ergeben. Ein Vergleich der
        // Objekte selbst würde hier scheitern, weil `Date()` Mikrosekunden
        // trägt, das Format aber bewusst auf Millisekunden festgelegt ist.
        let once = try BackupCoding.encode(file)
        let decoded = try BackupCoding.decode(once)
        #expect(try BackupCoding.encode(decoded) == once)

        #expect(decoded.habits == file.habits)
        #expect(decoded.entries.map(\.value) == file.entries.map(\.value))
        #expect(decoded.dayLogs.first?.sleepHours == 7.5)
        #expect(decoded.exceptions.first?.reason == "krank")
    }

    @Test("Zeitstempel behalten ihre Millisekunden")
    func millisecondPrecision() throws {
        // Auf Sekunden gerundet wären zwei Änderungen in derselben Sekunde
        // ununterscheidbar — und Last-Write-Wins damit ein Münzwurf.
        let precise = Date(timeIntervalSince1970: 1_788_000_000.123)
        let file = BackupFile(exportedAt: precise, generator: "Test/1.0", scope: .full)

        let decoded = try BackupCoding.decode(try BackupCoding.encode(file))
        #expect(abs(decoded.exportedAt.timeIntervalSince(precise)) < 0.002)
    }

    @Test("Wiederholtes Exportieren erzeugt dieselbe Datei")
    func encodingIsAFixedPoint() throws {
        // Regression: `ISO8601FormatStyle` schneidet Bruchteile ab, statt zu
        // runden. Ohne eigene Formatierung wanderte jeder Zeitstempel pro
        // Export-Runde eine Millisekunde zurück — zwei Sicherungen desselben
        // unveränderten Bestands wären nie byte-gleich gewesen.
        for offset in [0.0, 0.123, 0.456, 0.999, 0.0005] {
            let stamp = Date(timeIntervalSince1970: 1_788_000_000 + offset)
            let file = BackupFile(exportedAt: stamp, generator: "Test/1.0", scope: .full,
                                  habits: [], entries: [
                                      Entry(habitId: UUID(), date: d("2026-09-03"), value: 1,
                                            createdAt: stamp, updatedAt: stamp)])
            let first = try BackupCoding.encode(file)
            let second = try BackupCoding.encode(try BackupCoding.decode(first))
            let third = try BackupCoding.encode(try BackupCoding.decode(second))
            #expect(first == second, "Abweichung bei Offset \(offset)")
            #expect(second == third)
        }
    }

    @Test("Zeitstempel ohne Bruchteile werden trotzdem gelesen")
    func acceptsPlainISO8601() throws {
        let json = """
        {"formatVersion":1,"exportedAt":"2026-09-04T12:00:00Z","generator":"fremd",
         "scope":"full","habits":[],"tags":[],"entries":[],"events":[],
         "exceptions":[],"dayLogs":[]}
        """
        let file = try BackupCoding.decode(Data(json.utf8))
        #expect(file.generator == "fremd")
    }

    @Test("Kalendertage bleiben Tage, keine Zeitstempel")
    func datesStayCalendarDays() async throws {
        let store = try makeStore()
        try await seed(store)
        let json = String(decoding: try BackupCoding.encode(
            try await store.exportBackup(generator: "Test/1.0")), as: UTF8.self)
        #expect(json.contains("\"date\" : \"2026-09-02\""))
    }
}

@Suite("Sicherung: Import")
struct BackupImportTests {

    @Test("Wiederherstellung in eine leere Datenbank stellt den Bestand her")
    func restoreIntoEmpty() async throws {
        let source = try makeStore()
        try await seed(source)
        let file = try await source.exportBackup(generator: "Test/1.0")

        let target = try makeStore()
        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.habits.inserted == 2)
        #expect(report.entries.inserted == 3)
        #expect(report.totalSkipped == 0)

        // Der zweite Export muss dem ersten gleichen — sonst ist unterwegs
        // etwas verloren gegangen.
        let again = try await target.exportBackup(generator: "Test/1.0")
        #expect(Set(again.habits.map(\.name)) == Set(file.habits.map(\.name)))
        #expect(again.entries.count == file.entries.count)
        #expect(again.events.count == file.events.count)
        #expect(again.exceptions.count == file.exceptions.count)
        #expect(again.dayLogs.count == file.dayLogs.count)

        let sport = try #require(again.habits.first { $0.name == "Sport" })
        #expect(sport.kind == .quantity)
        #expect(sport.target(on: today)?.value == 30)
        #expect(sport.notes == "auch kurz zählt")
        #expect(sport.timeOfDay == .morning)
        #expect(sport.tracksTime)
        #expect(sport.tagIds.count == 1)
    }

    @Test("Zweimal dasselbe einspielen ändert beim zweiten Mal nichts")
    func importIsIdempotent() async throws {
        let source = try makeStore()
        try await seed(source)
        let file = try await source.exportBackup(generator: "Test/1.0")

        let target = try makeStore()
        try await target.importBackup(file, mode: .merge)
        let second = try await target.importBackup(file, mode: .merge)

        #expect(second.totalInserted == 0)
        #expect(second.totalUpdated == 0)
        #expect(second.totalSkipped > 0)
        #expect(try await target.listHabits(includeArchived: true).count == 2)
    }

    /// Der Fall, an dem ein id-basierter Import scheitern würde.
    @Test("Ein Eintrag wird über (habitId, date) erkannt, nicht über seine id")
    func entriesMatchOnNaturalKey() async throws {
        let target = try makeStore()
        let habit = try await target.createHabit(draft("Sport"))
        try await target.setEntry(habitId: habit.id, date: d("2026-09-03"),
                                  value: 10, note: "alt", source: .manual)

        // Dieselbe Sache, aber mit anderer id — so entsteht sie, wenn ein
        // zweites Gerät denselben Tag abgehakt hat.
        let foreign = Entry(id: UUID(), habitId: habit.id, date: d("2026-09-03"),
                            value: 42, note: "neu",
                            updatedAt: Date().addingTimeInterval(60))
        let file = BackupFile(generator: "Test/1.0", scope: .habits,
                              habits: [habit], entries: [foreign])

        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.entries.updated == 1)
        #expect(report.entries.inserted == 0)

        let entries = try await target.entries(habitId: habit.id,
                                               from: d("2026-09-01"), to: today)
        #expect(entries.count == 1, "kein Duplikat für denselben Tag")
        #expect(entries.first?.value == 42)
        #expect(entries.first?.note == "neu")
    }

    @Test("Beim Zusammenführen gewinnt der neuere Stand")
    func mergeKeepsNewer() async throws {
        let target = try makeStore()
        let habit = try await target.createHabit(draft("Sport"))
        try await target.setEntry(habitId: habit.id, date: d("2026-09-03"),
                                  value: 99, note: "lokal neuer", source: .manual)

        let stale = Entry(habitId: habit.id, date: d("2026-09-03"), value: 1,
                          note: "aus der Datei",
                          updatedAt: Date().addingTimeInterval(-3600))
        let file = BackupFile(generator: "Test/1.0", scope: .habits,
                              habits: [habit], entries: [stale])

        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.entries.skipped == 1)

        let entries = try await target.entries(habitId: habit.id,
                                               from: d("2026-09-01"), to: today)
        #expect(entries.first?.value == 99, "der lokale, neuere Wert bleibt stehen")
    }

    @Test("Ersetzen verwirft den bisherigen Bestand vollständig")
    func replaceWipesExisting() async throws {
        let source = try makeStore()
        try await seed(source)
        let file = try await source.exportBackup(generator: "Test/1.0")

        let target = try makeStore()
        let obsolete = try await target.createHabit(draft("Alter Habit"))
        try await target.setEntry(habitId: obsolete.id, date: d("2026-09-03"),
                                  value: 1, note: nil, source: .manual)

        try await target.importBackup(file, mode: .replace)

        let habits = try await target.listHabits(includeArchived: true)
        #expect(Set(habits.map(\.name)) == ["Sport", "Lesen"])
        #expect(!habits.contains { $0.name == "Alter Habit" })
        // Auch der Papierkorb bleibt leer: Ersetzen heißt weg, nicht verschoben.
        #expect(try await target.trash().isEmpty)
    }

    @Test("Ersetzen spielt die Datei auch ein, wenn sie älter ist")
    func replaceIgnoresTimestamps() async throws {
        let target = try makeStore()
        let habit = try await target.createHabit(draft("Sport"))
        try await target.setEntry(habitId: habit.id, date: d("2026-09-03"),
                                  value: 99, note: nil, source: .manual)

        let stale = Entry(habitId: habit.id, date: d("2026-09-03"), value: 1,
                          updatedAt: Date().addingTimeInterval(-99_999))
        let file = BackupFile(generator: "Test/1.0", scope: .full,
                              habits: [habit], entries: [stale])

        try await target.importBackup(file, mode: .replace)
        let entries = try await target.entries(habitId: habit.id,
                                               from: d("2026-09-01"), to: today)
        #expect(entries.first?.value == 1)
    }

    @Test("Einträge ohne zugehörigen Habit werden übersprungen und gemeldet")
    func orphanedEntriesReported() async throws {
        let target = try makeStore()
        let habit = try await target.createHabit(draft("Sport"))
        let ghost = UUID()
        let file = BackupFile(
            generator: "Test/1.0", scope: .habits, habits: [habit],
            entries: [Entry(habitId: habit.id, date: d("2026-09-03"), value: 1),
                      Entry(habitId: ghost, date: d("2026-09-03"), value: 1)])

        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.entries.inserted == 1)
        #expect(report.problems.contains(.orphanedRows(table: "entry", count: 1)))
    }

    @Test("Eine Datei aus der Zukunft wird abgewiesen, nicht geraten")
    func rejectsNewerFormat() async throws {
        let target = try makeStore()
        let file = BackupFile(formatVersion: BackupFile.currentFormatVersion + 1,
                              generator: "Zukunft/9.0", scope: .full)
        await #expect(throws: BackupError.self) {
            try await target.importBackup(file, mode: .merge)
        }
    }

    @Test("Ein fehlgeschlagener Import verändert nichts")
    func failedImportLeavesNoTrace() async throws {
        let target = try makeStore()
        let habit = try await target.createHabit(draft("Sport"))

        // Ein Habit ohne Regel ist ungültig — der Import muss vorher abbrechen.
        var broken = habit
        broken.rules = []
        broken.name = "Kaputt"
        let file = BackupFile(generator: "Test/1.0", scope: .full,
                              habits: [Habit(name: "Neu", rules: [HabitRule(
                                  effectiveFrom: d("2026-08-01"), schedule: .daily)]),
                                       broken])

        await #expect(throws: BackupError.self) {
            try await target.importBackup(file, mode: .merge)
        }
        let habits = try await target.listHabits(includeArchived: true)
        #expect(habits.map(\.name) == ["Sport"], "nichts von der Datei ist angekommen")
    }

    @Test("Die Datei-userId wird durch die lokale ersetzt")
    func userIdIsRewritten() async throws {
        let target = try LocalHabitAPI.inMemory(userId: "jonas", currentDate: { today })
        let habit = Habit(userId: "jemand-anders", name: "Sport",
                          rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)])
        let file = BackupFile(generator: "Test/1.0", scope: .full, habits: [habit],
                              entries: [Entry(habitId: habit.id, date: d("2026-09-03"), value: 1)])

        try await target.importBackup(file, mode: .merge)
        // Ohne die Umschreibung fände die nach user_id filternde Abfrage nichts.
        #expect(try await target.listHabits(includeArchived: true).count == 1)
        #expect(try await target.entries(habitId: habit.id,
                                         from: d("2026-09-01"), to: today).count == 1)
    }

    @Test("Ein einzelner Habit lässt sich in einen fremden Bestand holen")
    func mergeSingleHabitIntoOtherDatabase() async throws {
        let source = try makeStore()
        let (sport, _) = try await seed(source)
        let file = try await source.exportBackup(habitIds: [sport.id], generator: "Test/1.0")

        let target = try makeStore()
        _ = try await target.createHabit(draft("Meditation"))

        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.habits.inserted == 1)

        let habits = try await target.listHabits(includeArchived: true)
        #expect(Set(habits.map(\.name)) == ["Meditation", "Sport"])
        // Der Verlauf kommt mit — darum geht es beim Übertragen eines Streaks.
        let stats = try await target.stats(habitId: sport.id,
                                           from: d("2026-09-01"), to: today)
        #expect(stats.currentStreak == 2)
    }
}

@Suite("Sicherung: Fokus-Läufe")
struct BackupFocusTests {

    @Test("Fokus-Läufe wandern mit und überstehen die Wiederherstellung")
    func focusRunsRoundTrip() async throws {
        let source = try makeStore()
        let (sport, _) = try await seed(source)
        try await source.startFocus(days: 7, habitIds: [sport.id], title: "Saubere Woche")

        let file = try await source.exportBackup(generator: "Test/1.0")
        #expect(file.focusRuns.count == 1)
        #expect(file.summary.contains("1 Fokus-Läufe"))

        let target = try makeStore()
        let report = try await target.importBackup(file, mode: .merge)
        #expect(report.focusRuns.inserted == 1)

        let restored = try #require(try await target.focusRuns().first)
        #expect(restored.title == "Saubere Woche")
        #expect(restored.habitIds == [sport.id])
        #expect(restored.totalDays == 7)
    }

    @Test("Ein Einzelexport nimmt keine Fokus-Läufe mit")
    func focusRunsAreFullExportOnly() async throws {
        let store = try makeStore()
        let (sport, _) = try await seed(store)
        try await store.startFocus(days: 7)

        // Ein Lauf gehört keinem einzelnen Habit — er hat einen eigenen Umfang.
        let file = try await store.exportBackup(habitIds: [sport.id], generator: "Test/1.0")
        #expect(file.focusRuns.isEmpty)
    }

    /// Sonst wäre jede neue Tabelle ein Bruch für alte Sicherungen.
    @Test("Eine Datei ohne das Feld bleibt lesbar")
    func olderFilesStillDecode() throws {
        let json = """
        {"formatVersion":1,"exportedAt":"2026-09-04T12:00:00.000Z","generator":"alt",
         "scope":"full","habits":[],"tags":[],"entries":[],"events":[],
         "exceptions":[],"dayLogs":[]}
        """
        let file = try BackupCoding.decode(Data(json.utf8))
        #expect(file.focusRuns.isEmpty)
        #expect(file.generator == "alt")
    }

    @Test("Auch weggelassene Listen sind verzeihlich")
    func missingArraysDefaultToEmpty() throws {
        // Ein fremdes Werkzeug schreibt leere Listen womöglich gar nicht erst.
        let json = """
        {"formatVersion":1,"exportedAt":"2026-09-04T12:00:00.000Z","scope":"full"}
        """
        let file = try BackupCoding.decode(Data(json.utf8))
        #expect(file.habits.isEmpty)
        #expect(file.entries.isEmpty)
        #expect(file.generator == "unbekannt")
    }
}
