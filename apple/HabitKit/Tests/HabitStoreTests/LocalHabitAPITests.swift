import Testing
import Foundation
import HabitCore
@testable import HabitStore

/// Fester Stichtag, damit nichts vom echten Datum abhängt.
private let today = CalendarDate(iso: "2026-09-04")!

private func makeStore(today fixed: CalendarDate = today) throws -> LocalHabitAPI {
    try LocalHabitAPI.inMemory(currentDate: { fixed })
}

private func dailyDraft(
    _ name: String = "Sport",
    kind: HabitKind = .binary,
    from: String = "2026-08-01",
    target: Target? = nil,
    tracksTime: Bool = false
) -> HabitDraft {
    HabitDraft(
        name: name, kind: kind,
        rules: [HabitRule(effectiveFrom: CalendarDate(iso: from)!,
                          schedule: .daily, target: target)],
        tracksTime: tracksTime
    )
}

@Suite("Habits: anlegen, ändern, archivieren")
struct HabitCrudTests {

    @Test("Anlegen und wieder auslesen erhält alle Felder")
    func roundTrip() async throws {
        let store = try makeStore()
        let created = try await store.createHabit(HabitDraft(
            name: "Wasser trinken", kind: .quantity,
            rules: [HabitRule(effectiveFrom: CalendarDate(iso: "2026-08-01")!,
                              schedule: .weekdays([.monday, .wednesday, .friday]),
                              target: Target(value: 2, unit: "L", comparison: .atLeast))],
            notes: "mit Sprudel", colorHex: "#00AAFF", symbol: "drop.fill",
            timeOfDay: .morning, preferredTime: "07:30",
            startsOn: CalendarDate(iso: "2026-08-01")!,
            endsOn: CalendarDate(iso: "2026-12-31")!
        ))

        let loaded = try #require(try await store.habit(id: created.id))
        #expect(loaded.name == "Wasser trinken")
        #expect(loaded.notes == "mit Sprudel")
        #expect(loaded.kind == .quantity)
        #expect(loaded.colorHex == "#00AAFF")
        #expect(loaded.symbol == "drop.fill")
        #expect(loaded.timeOfDay == .morning)
        #expect(loaded.preferredTime == "07:30")
        #expect(loaded.startsOn?.description == "2026-08-01")
        #expect(loaded.endsOn?.description == "2026-12-31")
        #expect(loaded.rules.count == 1)
        #expect(loaded.rules[0].schedule == .weekdays([.monday, .wednesday, .friday]))
        #expect(loaded.rules[0].target == Target(value: 2, unit: "L", comparison: .atLeast))
    }

    @Test("Ein Habit ohne Regel wird abgelehnt")
    func requiresRule() async throws {
        let store = try makeStore()
        await #expect(throws: HabitStoreError.needsAtLeastOneRule) {
            try await store.createHabit(HabitDraft(name: "Leer", rules: []))
        }
    }

    @Test("Archiviert verschwindet aus der Liste, bleibt aber abrufbar")
    func archiving() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())

        _ = try await store.updateHabit(id: habit.id, HabitPatch(archivedOn: .some(today)))

        #expect(try await store.listHabits(includeArchived: false).isEmpty)
        #expect(try await store.listHabits(includeArchived: true).count == 1)
        // Archiviert ist nicht gelöscht: der Verlauf bleibt auswertbar.
        #expect(try await store.habit(id: habit.id) != nil)
    }

    @Test("Gelöscht ist überall unsichtbar, aber nur mit Grabstein")
    func softDelete() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        try await store.deleteHabit(id: habit.id)

        #expect(try await store.listHabits(includeArchived: true).isEmpty)
        #expect(try await store.habit(id: habit.id) == nil)

        let rows = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM habit WHERE deleted_at IS NOT NULL")
        }
        #expect(rows == 1, "Die Zeile muss als Grabstein erhalten bleiben, sonst käme die Löschung beim Sync nie an")
    }

    @Test("Teiländerung fasst nur gesetzte Felder an")
    func patchIsPartial() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft("Lesen"))

        let patched = try await store.updateHabit(id: habit.id, HabitPatch(name: "Mehr lesen"))
        #expect(patched.name == "Mehr lesen")
        #expect(patched.symbol == habit.symbol)
        #expect(patched.colorHex == habit.colorHex)

        // Doppelt optional: .some(nil) leert, nil lässt in Ruhe.
        let cleared = try await store.updateHabit(id: habit.id, HabitPatch(notes: .some(nil)))
        #expect(cleared.notes == nil)
        #expect(cleared.name == "Mehr lesen")
    }
}

@Suite("Regelversionierung durch den Store")
struct RuleVersioningTests {

    @Test("Eine zweite Regel ab Datum lässt alte Tage unberührt")
    func addVersion() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Wasser", kind: .quantity, from: "2026-08-30",
            target: Target(value: 2, unit: "L")))

        for (date, value) in [("2026-08-30", 2.0), ("2026-08-31", 2.0), ("2026-09-01", 2.0),
                              ("2026-09-02", 2.0), ("2026-09-03", 3.0)] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: date)!,
                                     value: value, note: nil, source: .manual)
        }

        // Ziel ab dem 2. September erhöhen.
        _ = try await store.setRule(habitId: habit.id, HabitRule(
            effectiveFrom: CalendarDate(iso: "2026-09-02")!,
            schedule: .daily, target: Target(value: 3, unit: "L")))

        let result = try await store.stats(habitId: habit.id,
                                           from: CalendarDate(iso: "2026-08-30")!, to: today)
        // 08-30 bis 09-01 galten noch 2 L und bleiben erfüllt.
        #expect(result.days[CalendarDate(iso: "2026-09-01")!]?.code == "completed")
        // Am 09-02 gilt schon 3 L, 2 L reichen nicht mehr.
        #expect(result.days[CalendarDate(iso: "2026-09-02")!]?.code == "missed")
        #expect(result.longestStreak == 3)
    }

    @Test("Dieselbe Regel erneut setzen ersetzt, statt zu häufen")
    func upsertsInPlace() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Wasser", kind: .quantity, from: "2026-08-01",
            target: Target(value: 2, unit: "L")))

        // Zweimal dasselbe Datum: die Korrektur eines Tippfehlers darf keine
        // zweite Version anlegen, sonst wird der Verlauf zum Flickenteppich.
        for value in [3.0, 4.0] {
            _ = try await store.setRule(habitId: habit.id, HabitRule(
                effectiveFrom: CalendarDate(iso: "2026-09-01")!,
                schedule: .daily, target: Target(value: value, unit: "L")))
        }

        let loaded = try #require(try await store.habit(id: habit.id))
        #expect(loaded.rules.count == 2)
        #expect(loaded.rules.last?.target?.value == 4)
    }

    @Test("Die letzte Regel lässt sich nicht entfernen")
    func cannotRemoveLastRule() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-01"))
        await #expect(throws: HabitStoreError.needsAtLeastOneRule) {
            _ = try await store.deleteRule(habitId: habit.id,
                                           effectiveFrom: CalendarDate(iso: "2026-08-01")!)
        }
    }
}

@Suite("Einträge")
struct EntryTests {

    @Test("Zweimal dasselbe Schreiben erzeugt eine Zeile, nicht zwei")
    func upsertIsIdempotent() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let date = CalendarDate(iso: "2026-09-03")!

        let first = try await store.setEntry(habitId: habit.id, date: date, value: 1,
                                             note: nil, source: .manual)
        let second = try await store.setEntry(habitId: habit.id, date: date, value: 1,
                                              note: nil, source: .manual)

        // Genau das ist der Grund für den natürlichen Schlüssel: ein nach einem
        // Verbindungsabbruch wiederholter Aufruf darf nichts kaputt machen.
        #expect(first.id == second.id)
        let all = try await store.entries(habitId: habit.id, from: date, to: date)
        #expect(all.count == 1)
    }

    @Test("Ein neuer Wert am selben Tag überschreibt")
    func overwrites() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(kind: .quantity,
                                                           target: Target(value: 2, unit: "L")))
        let date = CalendarDate(iso: "2026-09-03")!
        try await store.setEntry(habitId: habit.id, date: date, value: 1, note: nil, source: .manual)
        try await store.setEntry(habitId: habit.id, date: date, value: 2.5,
                                 note: "nachgetragen", source: .manual)

        let entries = try await store.entries(habitId: habit.id, from: date, to: date)
        #expect(entries.count == 1)
        #expect(entries[0].value == 2.5)
        #expect(entries[0].note == "nachgetragen")
    }

    @Test("Nach dem Löschen ist der Tag wieder frei und neu belegbar")
    func deleteThenRewrite() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let date = CalendarDate(iso: "2026-09-03")!

        try await store.setEntry(habitId: habit.id, date: date, value: 1, note: nil, source: .manual)
        try await store.deleteEntry(habitId: habit.id, date: date)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date).isEmpty)

        // Der Grabstein darf ein erneutes Abhaken nicht blockieren.
        try await store.setEntry(habitId: habit.id, date: date, value: 1, note: nil, source: .manual)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date).count == 1)
    }

    @Test("Zu weit zurück wird abgelehnt")
    func backfillLimit() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-01-01"))

        // Standard ist sieben Tage.
        try await store.setEntry(habitId: habit.id, date: today.adding(days: -7),
                                 value: 1, note: nil, source: .manual)

        await #expect(throws: HabitStoreError.self) {
            try await store.setEntry(habitId: habit.id, date: today.adding(days: -8),
                                     value: 1, note: nil, source: .manual)
        }
    }

    @Test("In der Zukunft abhaken geht nicht")
    func noFutureEntries() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-01-01"))
        await #expect(throws: HabitStoreError.self) {
            try await store.setEntry(habitId: habit.id, date: today.adding(days: 1),
                                     value: 1, note: nil, source: .manual)
        }
    }

    @Test("Grenze auf 0 hebt sie auf")
    func unlimitedBackfill() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-01-01"))
        try await store.setBackfillLimitDays(0)
        #expect(try await store.backfillLimitDays() == 0)

        try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: "2026-02-01")!,
                                 value: 1, note: nil, source: .manual)
        let entries = try await store.entries(habitId: habit.id,
                                              from: CalendarDate(iso: "2026-01-01")!, to: today)
        #expect(entries.count == 1)
    }
}

@Suite("Zeitstempel-Events und die Tageswert-Invariante")
struct EntryEventTests {

    @Test("Events summieren sich zum Tageswert")
    func eventsSumIntoEntry() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Wasser", kind: .quantity, from: "2026-08-01",
            target: Target(value: 2, unit: "L"), tracksTime: true))
        let date = CalendarDate(iso: "2026-09-03")!

        for value in [0.5, 0.75, 0.75] {
            try await store.setEvent(EntryEvent(habitId: habit.id, date: date,
                                                at: Date(), value: value))
        }

        let entries = try await store.entries(habitId: habit.id, from: date, to: date)
        #expect(entries.count == 1)
        #expect(entries[0].value == 2.0)

        // Die Streak-Engine liest nur den Tageswert und sieht Events nie.
        let result = try await store.stats(habitId: habit.id, from: date, to: date)
        #expect(result.days[date]?.code == "completed")
    }

    @Test("Ein gelöschtes Event senkt den Tageswert")
    func deletingEventRecomputes() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Wasser", kind: .quantity, from: "2026-08-01",
            target: Target(value: 2, unit: "L"), tracksTime: true))
        let date = CalendarDate(iso: "2026-09-03")!

        let first = EntryEvent(habitId: habit.id, date: date, at: Date(), value: 1.5)
        try await store.setEvent(first)
        try await store.setEvent(EntryEvent(habitId: habit.id, date: date, at: Date(), value: 0.5))
        #expect(try await store.entries(habitId: habit.id, from: date, to: date)[0].value == 2.0)

        try await store.deleteEvent(habitId: habit.id, eventId: first.id)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date)[0].value == 0.5)
    }

    @Test("Ohne Events bleibt kein Tageswert übrig")
    func lastEventRemovesEntry() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Rauchen", kind: .avoid, from: "2026-08-01", tracksTime: true))
        let date = CalendarDate(iso: "2026-09-03")!

        let event = EntryEvent(habitId: habit.id, date: date, at: Date(), value: 1)
        try await store.setEvent(event)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date).count == 1)

        try await store.deleteEvent(habitId: habit.id, eventId: event.id)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date).isEmpty)
    }

    @Test("Den Tageswert direkt zu setzen ersetzt die Events")
    func directWriteReplacesEvents() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(
            "Wasser", kind: .quantity, from: "2026-08-01",
            target: Target(value: 2, unit: "L"), tracksTime: true))
        let date = CalendarDate(iso: "2026-09-03")!

        try await store.setEvent(EntryEvent(habitId: habit.id, date: date, at: Date(), value: 0.5))
        try await store.setEntry(habitId: habit.id, date: date, value: 2, note: nil, source: .manual)

        // Sonst widersprächen sich Summe und Tageswert dauerhaft.
        #expect(try await store.events(habitId: habit.id, from: date, to: date).isEmpty)
        #expect(try await store.entries(habitId: habit.id, from: date, to: date)[0].value == 2)
    }
}

@Suite("Tags")
struct TagTests {

    @Test("Tag-Menge setzen ersetzt und hinterlässt Grabsteine")
    func replaceLeavesTombstones() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let gesundheit = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
        let arbeit = try await store.createTag(name: "Arbeit", colorHex: "#FF9500")

        var updated = try await store.setTags(habitId: habit.id, tagIds: [gesundheit.id, arbeit.id])
        #expect(Set(updated.tagIds) == Set([gesundheit.id, arbeit.id]))

        updated = try await store.setTags(habitId: habit.id, tagIds: [gesundheit.id])
        #expect(updated.tagIds == [gesundheit.id])

        // Ohne Grabstein käme das Ent-Taggen beim Sync auf anderen Geräten nie an.
        let tombstones = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM habit_tag WHERE deleted_at IS NOT NULL
                """)
        }
        #expect(tombstones == 1)
    }

    @Test("Ein wieder vergebener Tag hebt seinen Grabstein auf")
    func retaggingRevives() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")

        _ = try await store.setTags(habitId: habit.id, tagIds: [tag.id])
        _ = try await store.setTags(habitId: habit.id, tagIds: [])
        let revived = try await store.setTags(habitId: habit.id, tagIds: [tag.id])
        #expect(revived.tagIds == [tag.id])
    }

    @Test("Ein gelöschter Tag verschwindet auch aus den Habits")
    func deletingTagUnlinks() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let tag = try await store.createTag(name: "Weg damit", colorHex: "#FF3B30")
        _ = try await store.setTags(habitId: habit.id, tagIds: [tag.id])

        try await store.deleteTag(id: tag.id)

        #expect(try await store.tags().isEmpty)
        let loaded = try #require(try await store.habit(id: habit.id))
        #expect(loaded.tagIds.isEmpty)
    }
}

@Suite("Papierkorb")
struct TrashTests {

    @Test("Gelöschtes taucht auf und lässt sich zurückholen")
    func restoreHabit() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft("Meditation"))
        try await store.deleteHabit(id: habit.id)

        let items = try await store.trash()
        #expect(items.count == 1)
        #expect(items[0].label == "Meditation")
        #expect(items[0].table == .habit)

        try await store.restore(items[0])
        #expect(try await store.listHabits(includeArchived: true).count == 1)
        #expect(try await store.trash().isEmpty)
    }

    @Test("Gelöschte Einträge landen ebenfalls im Papierkorb")
    func deletedEntry() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let date = CalendarDate(iso: "2026-09-03")!
        try await store.setEntry(habitId: habit.id, date: date, value: 1, note: nil, source: .manual)
        try await store.deleteEntry(habitId: habit.id, date: date)

        let items = try await store.trash()
        #expect(items.contains { $0.table == .entry && $0.label.contains("2026-09-03") })
    }
}

@Suite("Auswertung durch den Store")
struct StoreStatsTests {

    @Test("Streak und Quote entsprechen der Domäne")
    func statsMatchDomain() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-30"))
        for day in ["2026-08-30", "2026-08-31", "2026-09-02", "2026-09-03", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }

        let result = try await store.stats(habitId: habit.id,
                                           from: CalendarDate(iso: "2026-08-30")!, to: today)
        #expect(result.currentStreak == 3)
        #expect(result.longestStreak == 3)
        #expect(result.evaluatedCount == 6)
        #expect(result.completedCount == 5)
    }

    @Test("Eine Ausnahme rettet den Streak")
    func exceptionSavesStreak() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-30"))
        for day in ["2026-08-30", "2026-08-31", "2026-09-02", "2026-09-03", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }
        try await store.addException(DayException(date: CalendarDate(iso: "2026-09-01")!,
                                                  kind: .frozen))

        let result = try await store.stats(habitId: habit.id,
                                           from: CalendarDate(iso: "2026-08-30")!, to: today)
        #expect(result.currentStreak == 5)
        // Der Freeze rettet den Streak, schönt die Quote aber nicht.
        #expect(result.evaluatedCount == 6)
        #expect(result.completedCount == 5)
    }
}

@Suite("Migration")
struct MigrationTests {

    @Test("Zweimal öffnen läuft die Migration nicht doppelt")
    func idempotentMigration() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("habitkit-test-\(UUID().uuidString)")
            .appendingPathComponent("habits.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try LocalHabitAPI(url: url, currentDate: { today })
        let habit = try await first.createHabit(dailyDraft("Bleibt erhalten"))

        let second = try LocalHabitAPI(url: url, currentDate: { today })
        let habits = try await second.listHabits(includeArchived: false)
        #expect(habits.count == 1)
        #expect(habits[0].id == habit.id)
    }
}
