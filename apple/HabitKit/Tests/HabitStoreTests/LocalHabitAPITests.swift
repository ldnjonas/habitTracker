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

// MARK: - Kaskadierte Löschung

import GRDB

/// Rohzugriff auf die Grabsteine — von außen ist nicht sichtbar, ob eine Zeile
/// weich gelöscht wurde oder nie existiert hat, und genau das ist hier die Frage.
private extension LocalHabitAPI {
    func tombstones(_ table: String) async throws -> [String: String?] {
        try await dbQueue.read { db in
            var result: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT rowid, deleted_with FROM "\(table)" WHERE deleted_at IS NOT NULL
                """) {
                result["\(row["rowid"] as Int64)"] = row["deleted_with"] as String?
            }
            return result
        }
    }

    func liveCount(_ table: String) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM "\(table)" WHERE deleted_at IS NULL
                """) ?? 0
        }
    }
}

/// Ein Habit, an dem jede abhängige Tabelle etwas hängen hat.
private func makeFullyPopulatedHabit(_ store: LocalHabitAPI) async throws -> (Habit, HabitCore.Tag) {
    let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
    var habit = try await store.createHabit(dailyDraft("Sport", tracksTime: true))
    habit = try await store.setTags(habitId: habit.id, tagIds: [tag.id])
    // Zweite Regel, damit habit_rule mehr als eine Zeile hat.
    habit = try await store.setRule(habitId: habit.id,
                                    HabitRule(effectiveFrom: CalendarDate(iso: "2026-09-01")!,
                                              schedule: .weekdays([.monday, .friday])))

    _ = try await store.setEvent(EntryEvent(habitId: habit.id,
                                            date: CalendarDate(iso: "2026-09-03")!,
                                            at: Date(), value: 1))
    try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: "2026-09-02")!,
                             value: 1, note: nil, source: .manual)
    _ = try await store.addException(DayException(habitId: habit.id,
                                                  date: CalendarDate(iso: "2026-09-01")!,
                                                  kind: .frozen))
    return (habit, tag)
}

@Suite("Kaskadierte Löschung")
struct CascadeTests {

    @Test("Ein gelöschter Habit nimmt alles mit, was an ihm hängt")
    func deleteCascades() async throws {
        let store = try makeStore()
        let (habit, _) = try await makeFullyPopulatedHabit(store)

        for table in LocalHabitAPI.habitOwnedTables {
            #expect(try await store.liveCount(table) > 0, "\(table) war schon vorher leer")
        }

        try await store.deleteHabit(id: habit.id)

        // Ohne Grabstein wäre die Löschung für den Sync unsichtbar und die
        // Zeilen blieben auf einem zweiten Gerät stehen.
        for table in LocalHabitAPI.habitOwnedTables {
            #expect(try await store.liveCount(table) == 0, "\(table) hat lebende Zeilen behalten")
            let marks = try await store.tombstones(table)
            #expect(!marks.isEmpty, "\(table) hat keine Grabsteine")
            #expect(marks.values.allSatisfy { $0 == habit.id.uuidString },
                    "\(table) trägt nicht die Herkunft des Habits")
        }
    }

    @Test("Wiederherstellen holt die kaskadierten Zeilen zurück")
    func restoreBringsBackCascade() async throws {
        let store = try makeStore()
        let (habit, tag) = try await makeFullyPopulatedHabit(store)
        try await store.deleteHabit(id: habit.id)

        let item = try #require(try await store.trash().first { $0.table == .habit })
        try await store.restore(item)

        let restored = try #require(try await store.habit(id: habit.id))
        #expect(restored.rules.count == 2, "die Zeitplan-Historie fehlt")
        #expect(restored.tagIds == [tag.id])

        let entries = try await store.entries(habitId: habit.id,
                                              from: CalendarDate(iso: "2026-09-01")!, to: today)
        #expect(entries.count == 2, "Tageswert und abgeleiteter Event-Tag fehlen")
        #expect(try await store.events(habitId: habit.id,
                                       from: CalendarDate(iso: "2026-09-01")!, to: today).count == 1)
        #expect(try await store.exceptions(from: CalendarDate(iso: "2026-09-01")!,
                                           to: today).count == 1)

        for table in LocalHabitAPI.habitOwnedTables {
            #expect(try await store.tombstones(table).isEmpty, "\(table) blieb gelöscht")
        }
    }

    /// Der Grund, warum die Herkunft überhaupt festgehalten wird.
    @Test("Ein vorher einzeln gelöschter Eintrag bleibt nach dem Wiederherstellen weg")
    func individualDeletionSurvivesRestore() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let verworfen = CalendarDate(iso: "2026-09-02")!
        let behalten = CalendarDate(iso: "2026-09-03")!
        for date in [verworfen, behalten] {
            try await store.setEntry(habitId: habit.id, date: date, value: 1,
                                     note: nil, source: .manual)
        }

        // Der Nutzer räumt einen Tag selbst weg …
        try await store.deleteEntry(habitId: habit.id, date: verworfen)
        // … und löscht später den ganzen Habit.
        try await store.deleteHabit(id: habit.id)

        let item = try #require(try await store.trash().first { $0.table == .habit })
        try await store.restore(item)

        let entries = try await store.entries(habitId: habit.id,
                                              from: CalendarDate(iso: "2026-09-01")!, to: today)
        #expect(entries.map(\.date) == [behalten],
                "der eigenhändig gelöschte Tag ist zurückgekommen")
    }

    @Test("Der Papierkorb listet den Habit einmal, nicht jeden Eintrag")
    func trashListsHabitOnce() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft("Sport"))
        for day in ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }
        try await store.deleteHabit(id: habit.id)

        let items = try await store.trash()
        #expect(items.count == 1, "statt eines Habits steht sein ganzer Verlauf im Papierkorb")
        #expect(items[0].table == .habit)
        #expect(items[0].label == "Sport")
    }

    @Test("Eine globale Ausnahme überlebt das Löschen eines Habits")
    func globalExceptionSurvives() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        // Urlaub gilt für alle Habits und gehört keinem.
        _ = try await store.addException(DayException(habitId: nil,
                                                      date: CalendarDate(iso: "2026-09-02")!,
                                                      kind: .paused, reason: "Urlaub"))
        _ = try await store.addException(DayException(habitId: habit.id,
                                                      date: CalendarDate(iso: "2026-09-03")!,
                                                      kind: .frozen))

        try await store.deleteHabit(id: habit.id)

        let remaining = try await store.exceptions(from: CalendarDate(iso: "2026-09-01")!, to: today)
        #expect(remaining.count == 1)
        #expect(remaining.first?.habitId == nil)
        #expect(remaining.first?.reason == "Urlaub")
    }

    @Test("Ein zweites Löschen stempelt die Herkunft nicht neu")
    func deletingTwiceIsHarmless() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let date = CalendarDate(iso: "2026-09-02")!
        try await store.setEntry(habitId: habit.id, date: date, value: 1,
                                 note: nil, source: .manual)
        try await store.deleteEntry(habitId: habit.id, date: date)

        try await store.deleteHabit(id: habit.id)
        try await store.deleteHabit(id: habit.id)

        // Der eigenhändig gelöschte Eintrag darf nicht nachträglich zur
        // Kaskade erklärt werden — sonst käme er beim Wiederherstellen zurück.
        #expect(try await store.tombstones("entry").values.allSatisfy { $0 == nil })

        let item = try #require(try await store.trash().first { $0.table == .habit })
        try await store.restore(item)
        #expect(try await store.entries(habitId: habit.id,
                                        from: CalendarDate(iso: "2026-09-01")!, to: today).isEmpty)
    }

    /// Auf `habit_tag` wirken zwei Ursachen — deshalb reicht ein bloßes
    /// „wurde kaskadiert" nicht aus.
    @Test("Ein Habit holt keine Zuordnung zurück, deren Tag noch gelöscht ist")
    func restoringHabitKeepsDeletedTagUnlinked() async throws {
        let store = try makeStore()
        let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
        var habit = try await store.createHabit(dailyDraft())
        habit = try await store.setTags(habitId: habit.id, tagIds: [tag.id])

        try await store.deleteTag(id: tag.id)
        try await store.deleteHabit(id: habit.id)

        let item = try #require(try await store.trash().first { $0.table == .habit })
        try await store.restore(item)

        let restored = try #require(try await store.habit(id: habit.id))
        #expect(restored.tagIds.isEmpty, "der Habit trägt einen Tag, den es nicht mehr gibt")
    }

    @Test("Ein wiederhergestellter Tag bringt seine Zuordnungen zurück")
    func restoringTagRelinksHabits() async throws {
        let store = try makeStore()
        let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
        var habit = try await store.createHabit(dailyDraft())
        habit = try await store.setTags(habitId: habit.id, tagIds: [tag.id])

        try await store.deleteTag(id: tag.id)
        #expect(try await store.habit(id: habit.id)?.tagIds.isEmpty == true)

        let item = try #require(try await store.trash().first { $0.table == .tag })
        try await store.restore(item)

        #expect(try await store.habit(id: habit.id)?.tagIds == [tag.id])
    }

    @Test("Ein neu vergebener Tag hebt einen kaskadierten Grabstein auf")
    func retaggingClearsCascadeMark() async throws {
        let store = try makeStore()
        let tag = try await store.createTag(name: "Gesundheit", colorHex: "#34C759")
        var habit = try await store.createHabit(dailyDraft())
        habit = try await store.setTags(habitId: habit.id, tagIds: [tag.id])

        try await store.deleteHabit(id: habit.id)
        let item = try #require(try await store.trash().first { $0.table == .habit })
        try await store.restore(item)

        // Ab- und wieder anhängen: die Zuordnung darf keine alte Herkunft behalten.
        _ = try await store.setTags(habitId: habit.id, tagIds: [])
        _ = try await store.setTags(habitId: habit.id, tagIds: [tag.id])

        #expect(try await store.habit(id: habit.id)?.tagIds == [tag.id])
        #expect(try await store.tombstones("habit_tag").values.allSatisfy { $0 == nil })
    }
}

@Suite("Fokus durch den Store")
struct StoreFocusTests {

    @Test("Ein Fokus beginnt heute und läuft die gewünschte Zahl Tage")
    func startsToday() async throws {
        let store = try makeStore()
        _ = try await store.createHabit(dailyDraft())
        let run = try await store.startFocus(days: 7)

        #expect(run.startsOn == today)
        #expect(run.endsOn == CalendarDate(iso: "2026-09-10")!)
        #expect(run.totalDays == 7)
        #expect(run.habitIds.isEmpty, "leer heißt: alle Habits")
        #expect(run.displayTitle == "7-Tage-Fokus")
    }

    @Test("Ein zweiter Fokus verdrängt keinen heilen ersten")
    func onlyOneOpenRun() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        try await store.setEntry(habitId: habit.id, date: today, value: 1,
                                 note: nil, source: .manual)
        try await store.startFocus(days: 7)

        await #expect(throws: HabitStoreError.self) {
            try await store.startFocus(days: 7)
        }
        #expect(try await store.focusRuns().count == 1)
    }

    /// Nach einem gerissenen Lauf sofort neu anfangen zu dürfen ist der Sinn
    /// der Sache — nicht bis zum Fensterende warten zu müssen.
    @Test("Nach einem gerissenen Lauf lässt sich sofort neu starten")
    func canRestartAfterFailure() async throws {
        let store = try LocalHabitAPI.inMemory(currentDate: { CalendarDate(iso: "2026-09-01")! })
        _ = try await store.createHabit(dailyDraft(from: "2026-08-01"))
        try await store.startFocus(days: 7)

        // Zwei Tage später, nichts erledigt: der Lauf ist gerissen.
        let later = try LocalHabitAPI(dbQueue: store.dbQueue,
                                      currentDate: { CalendarDate(iso: "2026-09-03")! })
        let progress = try #require(try await later.focusProgress().first)
        #expect(progress.outcome == .failed(on: CalendarDate(iso: "2026-09-01")!))
        #expect(try await later.activeFocus() == nil)

        try await later.startFocus(days: 3)
        #expect(try await later.focusRuns().count == 2)
    }

    @Test("Ein abgebrochener Lauf gibt den Platz frei")
    func abandonReleasesSlot() async throws {
        let store = try makeStore()
        _ = try await store.createHabit(dailyDraft())
        let run = try await store.startFocus(days: 7)

        try await store.abandonFocus(id: run.id)
        let progress = try #require(try await store.focusProgress().first)
        #expect(progress.outcome == .abandoned(on: today))

        try await store.startFocus(days: 3)
        #expect(try await store.focusRuns().count == 2)
    }

    @Test("Ein Lauf ohne Tage wird abgelehnt")
    func rejectsEmptyRun() async throws {
        let store = try makeStore()
        await #expect(throws: HabitStoreError.self) {
            try await store.startFocus(days: 0)
        }
    }

    @Test("Der Verlauf überlebt das Löschen eines beteiligten Habits")
    func historySurvivesHabitDeletion() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft())
        let run = try await store.startFocus(days: 3, habitIds: [habit.id])

        try await store.deleteHabit(id: habit.id)

        // Der Lauf hat stattgefunden; ein Fremdschlüssel hätte ihn mitgerissen.
        let runs = try await store.focusRuns()
        #expect(runs.count == 1)
        #expect(runs[0].id == run.id)
        #expect(runs[0].habitIds == [habit.id])
    }

    @Test("Die Bilanz zählt nur abgeschlossene Läufe")
    func recordCountsFinishedOnly() async throws {
        let store = try LocalHabitAPI.inMemory(currentDate: { CalendarDate(iso: "2026-09-20")! })
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-01"))
        _ = try await store.setBackfillLimitDays(0)     // Grenze aus, wir tragen nach

        // Ein geschaffter Lauf: 01.–03.09. lückenlos.
        try await store.dbQueue.write { db in
            var row = try FocusRunRow(FocusRun(startsOn: CalendarDate(iso: "2026-09-01")!,
                                               endsOn: CalendarDate(iso: "2026-09-03")!))
            try row.insert(db)
            // Ein gerissener: 10.–12.09. ohne Einträge.
            var second = try FocusRunRow(FocusRun(startsOn: CalendarDate(iso: "2026-09-10")!,
                                                  endsOn: CalendarDate(iso: "2026-09-12")!))
            try second.insert(db)
        }
        for day in ["2026-09-01", "2026-09-02", "2026-09-03"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }

        let outcomes = try await store.focusProgress().map(\.outcome)
        let result = record(of: outcomes)
        #expect(result.completed == 1)
        #expect(result.failed == 1)
        #expect(result.successRate == 0.5)
    }
}

@Suite("Ausnahmen durch den Store")
struct ExceptionTests {

    /// Der Grund, warum es Ausnahmen überhaupt gibt.
    @Test("Urlaub über mehrere Tage rettet den Streak")
    func vacationKeepsStreak() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-25"))
        _ = try await store.setBackfillLimitDays(0)
        for day in ["2026-08-25", "2026-08-26", "2026-09-03", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }

        // Ohne Ausnahme reicht die Serie nur bis zur Lücke zurück.
        let davor = try await store.stats(habitId: habit.id,
                                          from: CalendarDate(iso: "2026-08-25")!, to: today)
        #expect(davor.currentStreak == 2)

        // 27.08. bis 02.09. als Urlaub eintragen.
        for date in CalendarDate(iso: "2026-08-27")!.through(CalendarDate(iso: "2026-09-02")!) {
            _ = try await store.addException(
                DayException(habitId: nil, date: date, kind: .paused, reason: "Urlaub"))
        }

        let danach = try await store.stats(habitId: habit.id,
                                           from: CalendarDate(iso: "2026-08-25")!, to: today)
        #expect(danach.currentStreak == 4, "die pausierten Tage dürfen die Serie nicht trennen")
        // Pausierte Tage fallen ganz heraus, statt die Quote zu drücken.
        #expect(danach.completionRate == 1.0)
    }

    @Test("Das Aufheben stellt den alten Stand wieder her")
    func removingRestoresPreviousState() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-08-25"))
        _ = try await store.setBackfillLimitDays(0)
        for day in ["2026-09-01", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }
        let exception = try await store.addException(
            DayException(habitId: nil, date: CalendarDate(iso: "2026-09-02")!, kind: .paused))
        _ = try await store.addException(
            DayException(habitId: nil, date: CalendarDate(iso: "2026-09-03")!, kind: .paused))

        #expect(try await store.stats(habitId: habit.id,
                                      from: CalendarDate(iso: "2026-09-01")!,
                                      to: today).currentStreak == 2)

        try await store.deleteException(id: exception.id)
        let danach = try await store.stats(habitId: habit.id,
                                           from: CalendarDate(iso: "2026-09-01")!, to: today)
        #expect(danach.currentStreak == 1, "der 02.09. zählt wieder als verpasst")
    }

    @Test("Eine globale Ausnahme wirkt auf alle Habits, eine gezielte nur auf ihren")
    func scopeIsRespected() async throws {
        let store = try makeStore()
        let sport = try await store.createHabit(dailyDraft("Sport", from: "2026-09-01"))
        let lesen = try await store.createHabit(dailyDraft("Lesen", from: "2026-09-01"))
        let date = CalendarDate(iso: "2026-09-02")!

        _ = try await store.addException(DayException(habitId: sport.id, date: date, kind: .skipped))
        var sportTage = try await store.stats(habitId: sport.id, from: date, to: date).days
        var lesenTage = try await store.stats(habitId: lesen.id, from: date, to: date).days
        #expect(sportTage[date] == .excepted(.skipped))
        #expect(lesenTage[date] == .missed, "die gezielte Ausnahme darf nicht überschwappen")

        _ = try await store.addException(DayException(habitId: nil, date: date, kind: .paused))
        lesenTage = try await store.stats(habitId: lesen.id, from: date, to: date).days
        sportTage = try await store.stats(habitId: sport.id, from: date, to: date).days
        #expect(lesenTage[date] == .excepted(.paused))
        // Die habit-eigene Ausnahme ist die genauere Aussage und behält den Vorrang.
        #expect(sportTage[date] == .excepted(.skipped))
    }

    /// Ein Freeze rettet den Streak, schönt die Statistik aber nicht — sonst
    /// wäre die Quote nichts wert.
    @Test("Ein Freeze hält den Streak, drückt aber die Quote")
    func freezeKeepsStreakButNotRate() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(dailyDraft(from: "2026-09-01"))
        _ = try await store.setBackfillLimitDays(0)
        for day in ["2026-09-01", "2026-09-03", "2026-09-04"] {
            try await store.setEntry(habitId: habit.id, date: CalendarDate(iso: day)!,
                                     value: 1, note: nil, source: .manual)
        }
        _ = try await store.addException(
            DayException(habitId: habit.id, date: CalendarDate(iso: "2026-09-02")!, kind: .frozen))

        let stats = try await store.stats(habitId: habit.id,
                                          from: CalendarDate(iso: "2026-09-01")!, to: today)
        // Drei, nicht vier: eine Ausnahme unterbricht die Serie nicht, verlängert
        // sie aber auch nicht. Der Freeze überbrückt die Lücke, ohne sich einen
        // erledigten Tag anzurechnen — sonst könnte man sich Streak kaufen.
        #expect(stats.currentStreak == 3)
        #expect(stats.completionRate == 0.75, "der eingefrorene Tag bleibt im Nenner")
    }

    @Test("Ein Urlaubstag nimmt auch die Übersicht aus dem Nenner")
    func vacationLeavesOverviewDenominator() async throws {
        let store = try makeStore()
        let sport = try await store.createHabit(dailyDraft("Sport", from: "2026-09-01"))
        let lesen = try await store.createHabit(dailyDraft("Lesen", from: "2026-09-01"))
        let date = CalendarDate(iso: "2026-09-02")!
        try await store.setEntry(habitId: sport.id, date: date, value: 1,
                                 note: nil, source: .manual)

        let habits = try await store.listHabits(includeArchived: false)
        let entries = try await store.entries(habitId: nil, from: date, to: date)

        var summaries = overview(habits: habits, entries: entries, exceptions: [],
                                 from: date, to: date, today: today)
        #expect(summaries[date]?.scheduled == 2)
        #expect(summaries[date]?.isPerfect == false)

        _ = try await store.addException(DayException(habitId: lesen.id, date: date, kind: .paused))
        let exceptions = try await store.exceptions(from: date, to: date)
        summaries = overview(habits: habits, entries: entries, exceptions: exceptions,
                             from: date, to: date, today: today)
        #expect(summaries[date]?.scheduled == 1, "„Lesen“ stand an diesem Tag nicht an")
        #expect(summaries[date]?.isPerfect == true)
    }
}

@Suite("Reihenfolge")
struct SortOrderTests {

    @Test("Die Liste folgt der gesetzten Reihenfolge")
    func listFollowsSortOrder() async throws {
        let store = try makeStore()
        var angelegt: [Habit] = []
        for name in ["Anton", "Berta", "Cäsar"] {
            angelegt.append(try await store.createHabit(dailyDraft(name)))
        }
        // Beim Anlegen zählt die Reihenfolge hoch.
        #expect(try await store.listHabits(includeArchived: false).map(\.name)
                == ["Anton", "Berta", "Cäsar"])

        // Umdrehen.
        for (index, habit) in angelegt.reversed().enumerated() {
            _ = try await store.updateHabit(id: habit.id, HabitPatch(sortOrder: index))
        }
        #expect(try await store.listHabits(includeArchived: false).map(\.name)
                == ["Cäsar", "Berta", "Anton"])
    }

    @Test("Gleiche Reihenfolge entscheidet der Name")
    func nameBreaksTies() async throws {
        let store = try makeStore()
        for name in ["Zebra", "Ameise"] {
            let habit = try await store.createHabit(dailyDraft(name))
            _ = try await store.updateHabit(id: habit.id, HabitPatch(sortOrder: 0))
        }
        // Ohne diesen zweiten Schlüssel wäre die Liste bei gleichem Wert
        // beliebig sortiert und spränge zwischen zwei Aufrufen.
        #expect(try await store.listHabits(includeArchived: false).map(\.name)
                == ["Ameise", "Zebra"])
    }
}
