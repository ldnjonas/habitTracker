import Testing
import Foundation
import HabitCore
@testable import HabitStore

private let today = CalendarDate(iso: "2026-09-04")!
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

/// Ein Zeitpunkt an einem Tag, in UTC gerechnet — die Tests sollen nicht von
/// der Zeitzone des Rechners abhängen.
private func at(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents(year: Int(iso.prefix(4)), month: Int(iso.dropFirst(5).prefix(2)),
                           day: Int(iso.suffix(2)), hour: hour, minute: minute)
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}

private func makeStore() throws -> LocalHabitAPI {
    try LocalHabitAPI.inMemory(currentDate: { today })
}

private func timedHabit(_ store: LocalHabitAPI, target: Double? = nil) async throws -> Habit {
    try await store.createHabit(HabitDraft(
        name: "Lesen", kind: .quantity,
        rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily,
                          target: target.map { Target(value: $0, unit: "min") })],
        tracksTime: true))
}

@Suite("Sitzungen mit Start und Ende")
struct SessionStoreTests {

    @Test("Die Dauer bestimmt den Wert, nicht der mitgeschickte")
    func durationWins() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)

        // 7:30 bis 8:15 sind 45 Minuten — die 999 sind Unsinn und werden verworfen.
        let saved = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 7, 30), endsAt: at("2026-09-03", 8, 15), value: 999))
        #expect(saved.value == 45)

        let entries = try await store.entries(habitId: habit.id,
                                              from: d("2026-09-03"), to: d("2026-09-03"))
        #expect(entries.first?.value == 45, "der Tageswert folgt der Sitzung")
    }

    @Test("Ohne Ende bleibt der gesetzte Wert stehen")
    func valueWithoutEnd() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        let saved = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 7, 30), value: 20))
        #expect(saved.value == 20)
        #expect(saved.durationMinutes == nil)
    }

    @Test("Ein Ende vor dem Start wird abgewiesen")
    func rejectsInvertedInterval() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        await #expect(throws: HabitStoreError.self) {
            try await store.setEvent(EntryEvent(
                habitId: habit.id, date: d("2026-09-03"),
                at: at("2026-09-03", 9, 0), endsAt: at("2026-09-03", 8, 0), value: 0))
        }
        #expect(try await store.events(habitId: habit.id,
                                       from: d("2026-09-03"), to: d("2026-09-03")).isEmpty)
    }

    @Test("Mehrere Sitzungen an einem Tag summieren sich")
    func sessionsAddUp() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        for (start, ende) in [(7, 8), (12, 13), (20, 21)] {
            _ = try await store.setEvent(EntryEvent(
                habitId: habit.id, date: d("2026-09-03"),
                at: at("2026-09-03", start), endsAt: at("2026-09-03", ende), value: 0))
        }
        let entries = try await store.entries(habitId: habit.id,
                                              from: d("2026-09-03"), to: d("2026-09-03"))
        #expect(entries.first?.value == 180)
        #expect(try await store.events(habitId: habit.id,
                                       from: d("2026-09-03"), to: d("2026-09-03")).count == 3)
    }

    /// Eine Sitzung über Mitternacht zählt zum Starttag. `date` ist
    /// denormalisiert und bleibt maßgeblich — sonst hinge die Zuordnung an der
    /// Zeitzone des Lesers.
    @Test("Eine Sitzung über Mitternacht zählt zum Starttag")
    func sessionAcrossMidnight() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        _ = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 23, 30), endsAt: at("2026-09-04", 0, 30), value: 0))

        let am3 = try await store.entries(habitId: habit.id,
                                          from: d("2026-09-03"), to: d("2026-09-03"))
        let am4 = try await store.entries(habitId: habit.id,
                                          from: d("2026-09-04"), to: d("2026-09-04"))
        #expect(am3.first?.value == 60)
        #expect(am4.isEmpty, "der Folgetag bekommt nichts ab")
    }

    @Test("Das Löschen einer Sitzung senkt den Tageswert")
    func deletingLowersTotal() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        let erste = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 7), endsAt: at("2026-09-03", 8), value: 0))
        _ = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 12), endsAt: at("2026-09-03", 12, 30), value: 0))

        try await store.deleteEvent(habitId: habit.id, eventId: erste.id)
        let entries = try await store.entries(habitId: habit.id,
                                              from: d("2026-09-03"), to: d("2026-09-03"))
        #expect(entries.first?.value == 30)
    }

    @Test("Die letzte gelöschte Sitzung nimmt den Tageseintrag mit")
    func lastDeletionRemovesEntry() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        let event = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"),
            at: at("2026-09-03", 7), endsAt: at("2026-09-03", 8), value: 0))

        try await store.deleteEvent(habitId: habit.id, eventId: event.id)
        #expect(try await store.entries(habitId: habit.id,
                                        from: d("2026-09-03"), to: d("2026-09-03")).isEmpty)
    }

    @Test("Das Ende überlebt Schreiben und Lesen")
    func endSurvivesRoundTrip() async throws {
        let store = try makeStore()
        let habit = try await timedHabit(store)
        let start = at("2026-09-03", 7, 30)
        let ende = at("2026-09-03", 8, 15)
        _ = try await store.setEvent(EntryEvent(
            habitId: habit.id, date: d("2026-09-03"), at: start, endsAt: ende, value: 0))

        let gelesen = try #require(try await store.events(
            habitId: habit.id, from: d("2026-09-03"), to: d("2026-09-03")).first)
        #expect(abs(gelesen.at.timeIntervalSince(start)) < 0.001)
        #expect(abs((gelesen.endsAt ?? .distantPast).timeIntervalSince(ende)) < 0.001)
        #expect(gelesen.durationMinutes == 45)
    }
}

@Suite("Summen über einen Zeitraum")
struct PeriodTotalTests {

    private func habit() -> Habit {
        Habit(name: "Lesen", kind: .quantity,
              rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily,
                                target: Target(value: 30, unit: "min"))],
              tracksTime: true)
    }

    @Test("Die Wochensumme fasst nach Montagen zusammen")
    func weeklyBuckets() {
        let lesen = habit()
        // 31.08. ist ein Montag, 07.09. der nächste.
        let entries = [("2026-08-31", 30.0), ("2026-09-02", 45.0), ("2026-09-06", 15.0),
                       ("2026-09-07", 60.0)]
            .map { Entry(habitId: lesen.id, date: d($0.0), value: $0.1) }

        let result = periodTotal(for: lesen, entries: entries,
                                 from: d("2026-08-31"), to: d("2026-09-13"))
        #expect(result.total == 150)
        #expect(result.byWeek[d("2026-08-31")] == 90, "31.08. bis 06.09.")
        #expect(result.byWeek[d("2026-09-07")] == 60)
        #expect(result.activeDays == 4)
    }

    @Test("Der Schnitt zählt nur Tage mit Aktivität")
    func averageIgnoresEmptyDays() {
        let lesen = habit()
        let entries = [Entry(habitId: lesen.id, date: d("2026-09-01"), value: 60),
                       Entry(habitId: lesen.id, date: d("2026-09-03"), value: 20)]
        // Ein Schnitt über alle 30 Tage sänke, sobald man den Zeitraum
        // vergrößert — ohne dass sich am Verhalten etwas geändert hätte.
        let result = periodTotal(for: lesen, entries: entries,
                                 from: d("2026-09-01"), to: d("2026-09-30"))
        #expect(result.averagePerActiveDay == 40)
        #expect(result.dayCount == 30)
    }

    @Test("Fremde Habits und gelöschte Zeilen bleiben draußen")
    func filtersProperly() {
        let lesen = habit()
        let fremd = UUID()
        let entries = [
            Entry(habitId: lesen.id, date: d("2026-09-01"), value: 10),
            Entry(habitId: fremd, date: d("2026-09-01"), value: 99),
            Entry(habitId: lesen.id, date: d("2026-09-02"), value: 99, deletedAt: Date()),
            Entry(habitId: lesen.id, date: d("2026-08-01"), value: 99),   // außerhalb
        ]
        let result = periodTotal(for: lesen, entries: entries,
                                 from: d("2026-09-01"), to: d("2026-09-30"))
        #expect(result.total == 10)
        #expect(result.activeDays == 1)
    }

    @Test("Ohne Werte gibt es keinen Schnitt, nicht null")
    func noAverageWithoutData() {
        let result = periodTotal(for: habit(), entries: [],
                                 from: d("2026-09-01"), to: d("2026-09-30"))
        #expect(result.total == 0)
        #expect(result.averagePerActiveDay == nil)
    }

    @Test("Sitzungen eines Tages kommen sortiert zurück")
    func sessionsAreSorted() {
        let lesen = habit()
        let events = [
            EntryEvent(habitId: lesen.id, date: d("2026-09-03"),
                       at: at("2026-09-03", 20), endsAt: at("2026-09-03", 21), value: 60),
            EntryEvent(habitId: lesen.id, date: d("2026-09-03"),
                       at: at("2026-09-03", 7), endsAt: at("2026-09-03", 8), value: 60),
            EntryEvent(habitId: lesen.id, date: d("2026-09-02"),
                       at: at("2026-09-02", 9), value: 30),
        ]
        let result = sessions(of: lesen, on: d("2026-09-03"), events: events)
        #expect(result.count == 2)
        #expect(result[0].at < result[1].at)
    }
}
