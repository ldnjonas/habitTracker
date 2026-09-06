import Testing
import Foundation
import HabitCore
@testable import HabitStore

private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func tempOrdner() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sicherungen-\(UUID().uuidString)", isDirectory: true)
    return url
}

private func daily(_ name: String) -> HabitDraft {
    HabitDraft(name: name, rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)])
}

@Suite("Automatische Sicherung")
struct AutoBackupTests {

    private func lauf(
        _ store: LocalHabitAPI, _ ordner: URL, _ tag: String
    ) async throws -> AutoBackup.Ergebnis {
        try await AutoBackup.lauf(store: store, ordner: ordner,
                                  today: d(tag), generator: "Test/1")
    }

    @Test("Der erste Lauf legt eine Datei an")
    func writesFirst() async throws {
        let store = try LocalHabitAPI.inMemory()
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        _ = try await store.createHabit(daily("Sport"))

        let ergebnis = try await lauf(store, ordner, "2026-09-06")
        #expect(ergebnis == .geschrieben(ordner.appendingPathComponent("habits-2026-09-06.json")))

        let datei = try #require(ergebnis.url)
        let inhalt = try BackupCoding.decode(Data(contentsOf: datei))
        #expect(inhalt.habits.count == 1)
        #expect(inhalt.scope == .full, "gesichert wird alles, nicht eine Auswahl")
    }

    @Test("Zweimal am selben Tag ist einmal")
    func onlyOncePerDay() async throws {
        let store = try LocalHabitAPI.inMemory()
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        _ = try await store.createHabit(daily("Sport"))

        _ = try await lauf(store, ordner, "2026-09-06")
        let zweiter = try await lauf(store, ordner, "2026-09-06")
        if case .schonVorhanden = zweiter {} else {
            Issue.record("erwartet: schonVorhanden, war \(zweiter)")
        }
        #expect(try AutoBackup.vorhandene(in: ordner).count == 1)
    }

    /// Eine Reihe gleicher Dateien sagt nichts, was nicht schon im Datum steht —
    /// und verdrängt beim Aufräumen die Stände, die sich unterscheiden.
    @Test("Ohne Änderung wird nichts geschrieben")
    func skipsUnchanged() async throws {
        let store = try LocalHabitAPI.inMemory()
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        _ = try await store.createHabit(daily("Sport"))

        _ = try await lauf(store, ordner, "2026-09-06")
        let zweiter = try await lauf(store, ordner, "2026-09-07")
        if case .unveraendert = zweiter {} else {
            Issue.record("erwartet: unveraendert, war \(zweiter)")
        }
        #expect(try AutoBackup.vorhandene(in: ordner).count == 1)
    }

    @Test("Mit Änderung kommt eine neue Datei dazu")
    func writesAfterChange() async throws {
        let store = try LocalHabitAPI.inMemory()
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        let habit = try await store.createHabit(daily("Sport"))

        _ = try await lauf(store, ordner, "2026-09-06")
        try await store.setEntry(habitId: habit.id, date: d("2026-09-06"), value: 1,
                                 note: nil, source: .manual)

        let zweiter = try await lauf(store, ordner, "2026-09-07")
        if case .geschrieben = zweiter {} else {
            Issue.record("erwartet: geschrieben, war \(zweiter)")
        }
        #expect(try AutoBackup.vorhandene(in: ordner).count == 2)
    }

    @Test("Ausgeschaltet passiert nichts")
    func respectsSwitch() async throws {
        let store = try LocalHabitAPI.inMemory()
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        _ = try await store.createHabit(daily("Sport"))

        #expect(try await store.automatischeSicherung(), "Vorgabe ist an")
        try await store.setzeAutomatischeSicherung(false)
        #expect(try await lauf(store, ordner, "2026-09-06") == .aus)
        #expect(try AutoBackup.vorhandene(in: ordner).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ordner.path),
                "ein ausgeschaltetes Backup legt nicht einmal den Ordner an")
    }

    // MARK: - Aufräumen

    private func dateien(_ tage: [String]) -> [URL] {
        tage.map { URL(fileURLWithPath: "/x/habits-\($0).json") }
    }

    @Test("Die letzten vierzehn Tage bleiben vollständig")
    func keepsRecentDays() {
        let heute = d("2026-09-30")
        let tage = (0..<20).map { heute.adding(days: -$0).description }.sorted()
        let behalten = AutoBackup.zuBehalten(dateien(tage), bis: heute)

        // 17.09. bis 30.09. sind vierzehn Tage.
        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2026-09-30.json")))
        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2026-09-17.json")))
        #expect(!behalten.contains(URL(fileURLWithPath: "/x/habits-2026-09-16.json")),
                "der fünfzehnte Tag fällt in die Monatsregel")
    }

    @Test("Darüber hinaus bleibt je Monat die älteste")
    func thinsOlderMonths() {
        let heute = d("2026-09-30")
        let tage = ["2026-06-03", "2026-06-11", "2026-06-28",
                    "2026-07-05", "2026-07-19",
                    "2026-09-30"]
        let behalten = AutoBackup.zuBehalten(dateien(tage), bis: heute)

        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2026-06-03.json")))
        #expect(!behalten.contains(URL(fileURLWithPath: "/x/habits-2026-06-11.json")))
        #expect(!behalten.contains(URL(fileURLWithPath: "/x/habits-2026-06-28.json")))
        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2026-07-05.json")))
        #expect(!behalten.contains(URL(fileURLWithPath: "/x/habits-2026-07-19.json")))
        #expect(behalten.count == 3)
    }

    @Test("Was älter als zwölf Monate ist, fällt weg")
    func dropsAncient() {
        let heute = d("2026-09-30")
        let behalten = AutoBackup.zuBehalten(
            dateien(["2025-08-01", "2025-10-01", "2026-09-30"]), bis: heute)

        #expect(!behalten.contains(URL(fileURLWithPath: "/x/habits-2025-08-01.json")))
        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2025-10-01.json")))
        #expect(behalten.contains(URL(fileURLWithPath: "/x/habits-2026-09-30.json")))
    }

    @Test("Fremde Dateien im Ordner bleiben unangetastet")
    func ignoresForeignFiles() async throws {
        let ordner = tempOrdner()
        defer { try? FileManager.default.removeItem(at: ordner) }
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

        let fremd = ordner.appendingPathComponent("notizen.txt")
        try Data("hallo".utf8).write(to: fremd)
        let alt = ordner.appendingPathComponent("habits-2020-01-01.json")
        try Data("{}".utf8).write(to: alt)

        try AutoBackup.raeumeAuf(in: ordner, bis: d("2026-09-30"))
        #expect(FileManager.default.fileExists(atPath: fremd.path),
                "was nicht nach dem Muster heißt, gehört jemand anderem")
        #expect(!FileManager.default.fileExists(atPath: alt.path))
    }
}
