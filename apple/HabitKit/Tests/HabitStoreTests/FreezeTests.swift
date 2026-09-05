import Testing
import Foundation
import GRDB
import HabitCore
@testable import HabitStore

private let today = CalendarDate(iso: "2026-09-04")!
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func makeStore(today fixed: CalendarDate = today) throws -> LocalHabitAPI {
    try LocalHabitAPI.inMemory(currentDate: { fixed })
}

private func daily(_ name: String = "Sport", from: String = "2026-08-01") -> HabitDraft {
    HabitDraft(name: name, rules: [HabitRule(effectiveFrom: d(from), schedule: .daily)])
}

/// Legt einen durchgezogenen Lauf an: Fenster plus lückenlose Einträge.
@discardableResult
private func completedRun(_ store: LocalHabitAPI, _ habit: Habit,
                          from: String, to: String, title: String) async throws -> FocusRun {
    let run = FocusRun(title: title, startsOn: d(from), endsOn: d(to), habitIds: [habit.id])
    try await store.dbQueue.write { db in
        var row = try FocusRunRow(run); try row.insert(db)
    }
    for date in d(from).through(d(to)) {
        try await store.setEntry(habitId: habit.id, date: date, value: 1,
                                 note: nil, source: .manual)
    }
    return run
}

@Suite("Freeze-Guthaben")
struct FreezeLedgerTests {

    @Test("Der Kontostand ist die Summe der Buchungen")
    func balanceIsSum() {
        let ledger = [
            FreezeEntry(amount: 1, reason: .focusCompleted),
            FreezeEntry(amount: 1, reason: .focusCompleted),
            FreezeEntry(amount: -1, reason: .applied),
        ]
        #expect(freezeBalance(ledger) == 1)
        #expect(freezeBalance([]) == 0)
    }

    @Test("Ein durchgezogener Lauf zahlt ein, ein gerissener nicht")
    func onlyCompletedRunsPay() {
        let geschafft = FocusRun(startsOn: d("2026-08-01"), endsOn: d("2026-08-07"))
        let gerissen = FocusRun(startsOn: d("2026-08-10"), endsOn: d("2026-08-16"))
        let offen = FocusRun(startsOn: d("2026-09-01"), endsOn: d("2026-09-07"))

        let faellig = pendingFreezeAwards(
            outcomes: [(geschafft, .completed),
                       (gerissen, .failed(on: d("2026-08-11"))),
                       (offen, .running(dayNumber: 4, totalDays: 7))],
            ledger: [])
        #expect(faellig.map(\.id) == [geschafft.id])
    }

    /// Der Kern der Sache: `evaluate` rechnet bei jedem Aufruf neu, die
    /// Einzahlung darf trotzdem nur einmal geschehen.
    @Test("Derselbe Lauf zahlt nicht zweimal ein")
    func awardIsIdempotent() {
        let run = FocusRun(startsOn: d("2026-08-01"), endsOn: d("2026-08-07"))
        let ledger = [FreezeEntry(amount: 1, reason: .focusCompleted, focusRunId: run.id)]
        #expect(pendingFreezeAwards(outcomes: [(run, .completed)], ledger: ledger).isEmpty)
    }

    @Test("Die Obergrenze deckelt und der Anspruch darüber verfällt")
    func capIsRespected() {
        let runs = (0..<5).map {
            FocusRun(startsOn: d("2026-08-01").adding(days: $0 * 10),
                     endsOn: d("2026-08-07").adding(days: $0 * 10))
        }
        let faellig = pendingFreezeAwards(
            outcomes: runs.map { ($0, .completed) }, ledger: [])
        #expect(faellig.count == FreezeRule.maximum)
        // Die ältesten zuerst: wer früher durchgezogen hat, bekommt zuerst.
        #expect(faellig.first?.id == runs.first?.id)

        // Bei vollem Konto kommt nichts mehr dazu — der Anspruch wird nicht
        // aufgespart, sonst wäre die Grenze wirkungslos.
        let voll = (0..<FreezeRule.maximum).map { _ in
            FreezeEntry(amount: 1, reason: .granted)
        }
        #expect(pendingFreezeAwards(outcomes: runs.map { ($0, .completed) },
                                    ledger: voll).isEmpty)
    }

    @Test("Nur ein vergangener, verpasster Tag lässt sich einfrieren")
    func freezableDays() {
        let gestern = d("2026-09-03")
        #expect(canFreeze(.missed, on: gestern, today: today))
        #expect(!canFreeze(.completed, on: gestern, today: today), "erfüllt braucht keine Rettung")
        #expect(!canFreeze(.notScheduled, on: gestern, today: today))
        #expect(!canFreeze(.excepted(.frozen), on: gestern, today: today), "schon eingefroren")
        // Heute ist noch nicht verloren, morgen erst recht nicht.
        #expect(!canFreeze(.missed, on: today, today: today))
        #expect(!canFreeze(.missed, on: d("2026-09-05"), today: today))
    }
}

@Suite("Freezes durch den Store")
struct FreezeStoreTests {

    @Test("Ein durchgezogener Lauf füllt das Konto")
    func completedRunFillsAccount() async throws {
        let store = try makeStore()
        _ = try await store.setBackfillLimitDays(0)
        let habit = try await store.createHabit(daily())
        try await completedRun(store, habit, from: "2026-08-20", to: "2026-08-26",
                               title: "Sportwoche")

        #expect(try await store.freezeBalance() == 0, "vor dem Buchen leer")
        #expect(try await store.awardPendingFreezes() == 1)
        #expect(try await store.freezeBalance() == 1)

        // Zweimal buchen ändert nichts — sonst füllte sich das Konto bei
        // jedem Nachladen.
        #expect(try await store.awardPendingFreezes() == 0)
        #expect(try await store.freezeBalance() == 1)
    }

    @Test("Einlösen rettet den Streak und zieht ab")
    func applyingSavesStreak() async throws {
        let store = try makeStore()
        _ = try await store.setBackfillLimitDays(0)
        let habit = try await store.createHabit(daily(from: "2026-09-01"))
        for day in ["2026-09-01", "2026-09-03", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: d(day), value: 1,
                                     note: nil, source: .manual)
        }
        try await store.dbQueue.write { db in
            var row = FreezeRow(FreezeEntry(amount: 1, reason: .granted)); try row.insert(db)
        }

        #expect(try await store.stats(habitId: habit.id,
                                      from: d("2026-09-01"), to: today).currentStreak == 2)

        _ = try await store.applyFreeze(habitId: habit.id, date: d("2026-09-02"))

        let stats = try await store.stats(habitId: habit.id, from: d("2026-09-01"), to: today)
        #expect(stats.currentStreak == 3, "die Lücke ist überbrückt")
        #expect(stats.completionRate == 0.75, "die Quote bleibt ehrlich")
        #expect(try await store.freezeBalance() == 0)
    }

    @Test("Ohne Guthaben geht nichts")
    func requiresBalance() async throws {
        let store = try makeStore()
        _ = try await store.setBackfillLimitDays(0)
        let habit = try await store.createHabit(daily(from: "2026-09-01"))
        try await store.setEntry(habitId: habit.id, date: d("2026-09-01"), value: 1,
                                 note: nil, source: .manual)

        await #expect(throws: HabitStoreError.noFreezeAvailable) {
            try await store.applyFreeze(habitId: habit.id, date: d("2026-09-02"))
        }
        #expect(try await store.exceptions(from: d("2026-09-02"), to: d("2026-09-02")).isEmpty)
    }

    @Test("Ein erfüllter oder heutiger Tag wird abgewiesen")
    func rejectsUnsuitableDays() async throws {
        let store = try makeStore()
        _ = try await store.setBackfillLimitDays(0)
        let habit = try await store.createHabit(daily(from: "2026-09-01"))
        try await store.setEntry(habitId: habit.id, date: d("2026-09-02"), value: 1,
                                 note: nil, source: .manual)
        try await store.dbQueue.write { db in
            var row = FreezeRow(FreezeEntry(amount: 2, reason: .granted)); try row.insert(db)
        }

        await #expect(throws: HabitStoreError.self) {
            try await store.applyFreeze(habitId: habit.id, date: d("2026-09-02"))
        }
        await #expect(throws: HabitStoreError.self) {
            try await store.applyFreeze(habitId: habit.id, date: today)
        }
        // Nichts abgebucht, wenn nichts passiert ist.
        #expect(try await store.freezeBalance() == 2)
    }

    @Test("Das Konto überlebt Sicherung und Wiederherstellung")
    func ledgerSurvivesBackup() async throws {
        let quelle = try makeStore()
        _ = try await quelle.setBackfillLimitDays(0)
        let habit = try await quelle.createHabit(daily())
        try await completedRun(quelle, habit, from: "2026-08-20", to: "2026-08-26",
                               title: "Sportwoche")
        try await quelle.awardPendingFreezes()

        let datei = try await quelle.exportBackup(generator: "Test/1.0")
        #expect(datei.freezes.count == 1)

        let ziel = try makeStore()
        let bericht = try await ziel.importBackup(datei, mode: .merge)
        #expect(bericht.freezes.inserted == 1)
        #expect(try await ziel.freezeBalance() == 1)

        // Und der Lauf zahlt danach nicht erneut ein.
        #expect(try await ziel.awardPendingFreezes() == 0)
    }
}
