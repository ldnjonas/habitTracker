import Testing
import Foundation
@testable import HabitCore

/// Ein Summen-Fixture aus `spec/fixtures/totals/`.
struct TotalsFixture: Decodable, Sendable {

    struct Range: Decodable, Sendable { let from: CalendarDate; let to: CalendarDate }

    struct EntrySpec: Decodable, Sendable {
        let date: CalendarDate
        let value: Double
        /// Gehört einem anderen Habit — muss draußen bleiben.
        let foreign: Bool?
        let deleted: Bool?
    }

    struct EventSpec: Decodable, Sendable {
        let date: CalendarDate
        /// ISO-8601 mit Millisekunden, wie im Dateiformat.
        let at: String
        let endsAt: String?
        let value: Double
    }

    struct EventExpectation: Decodable, Sendable {
        let date: CalendarDate
        /// Doppelt optional: Schlüssel fehlt = nicht prüfen, null = muss nil sein.
        let durationMinutes: Double??
        let effectiveValue: Double?
        let hasValidInterval: Bool?

        private enum CodingKeys: String, CodingKey {
            case date, durationMinutes, effectiveValue, hasValidInterval
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(CalendarDate.self, forKey: .date)
            effectiveValue = try c.decodeIfPresent(Double.self, forKey: .effectiveValue)
            hasValidInterval = try c.decodeIfPresent(Bool.self, forKey: .hasValidInterval)
            durationMinutes = c.contains(.durationMinutes)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .durationMinutes))
                : nil
        }
    }

    struct SessionExpectation: Decodable, Sendable {
        let date: CalendarDate
        let count: Int
        let starts: [String]?
    }

    struct Expected: Decodable, Sendable {
        let total: Double?
        let activeDays: Int?
        let dayCount: Int?
        /// Doppelt optional wie überall.
        let averagePerActiveDay: Double??
        let byDay: [String: Double]?
        let byWeek: [String: Double]?
        let sessionCount: Int?
        let sessions: SessionExpectation?
        let events: [EventExpectation]?

        private enum CodingKeys: String, CodingKey {
            case total, activeDays, dayCount, averagePerActiveDay
            case byDay, byWeek, sessionCount, sessions, events
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = try c.decodeIfPresent(Double.self, forKey: .total)
            activeDays = try c.decodeIfPresent(Int.self, forKey: .activeDays)
            dayCount = try c.decodeIfPresent(Int.self, forKey: .dayCount)
            byDay = try c.decodeIfPresent([String: Double].self, forKey: .byDay)
            byWeek = try c.decodeIfPresent([String: Double].self, forKey: .byWeek)
            sessionCount = try c.decodeIfPresent(Int.self, forKey: .sessionCount)
            sessions = try c.decodeIfPresent(SessionExpectation.self, forKey: .sessions)
            events = try c.decodeIfPresent([EventExpectation].self, forKey: .events)
            averagePerActiveDay = c.contains(.averagePerActiveDay)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .averagePerActiveDay))
                : nil
        }
    }

    struct HabitSpec: Decodable, Sendable {
        let key: String?
        let name: String?
        let kind: HabitKind
        let rules: [HabitRule]
        let tracksTime: Bool?
    }

    let name: String
    let habit: HabitSpec
    let range: Range
    let entries: [EntrySpec]
    let events: [EventSpec]
    let expected: Expected

    static let habitId = OverviewFixture.id(at: 0)
    static let fremdId = OverviewFixture.id(at: 99)

    var builtHabit: Habit {
        Habit(id: TotalsFixture.habitId, name: habit.name ?? habit.key ?? name,
              kind: habit.kind, rules: habit.rules, tracksTime: habit.tracksTime ?? false)
    }

    var builtEntries: [Entry] {
        entries.map {
            Entry(habitId: ($0.foreign ?? false) ? TotalsFixture.fremdId : TotalsFixture.habitId,
                  date: $0.date, value: $0.value,
                  deletedAt: ($0.deleted ?? false) ? Date(timeIntervalSince1970: 0) : nil)
        }
    }

    func builtEvents() throws -> [EntryEvent] {
        try events.map {
            EntryEvent(habitId: TotalsFixture.habitId, date: $0.date,
                       at: try TotalsFixture.zeit($0.at),
                       endsAt: try $0.endsAt.map(TotalsFixture.zeit),
                       value: $0.value)
        }
    }

    /// Dieselbe Kodierung wie im Dateiformat: ISO-8601 mit Millisekunden.
    static func zeit(_ iso: String) throws -> Date {
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
    }

    static func loadAll() throws -> [TotalsFixture] { try FixtureFiles.load("totals") }
}

@Suite("Golden Fixtures: Summen")
struct TotalsFixtureTests {

    @Test("spec/fixtures/totals liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try TotalsFixture.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("totals").path)")
    }

    @Test("Jedes Summen-Fixture wird exakt reproduziert", arguments: try TotalsFixture.loadAll())
    func matchesExpectation(fixture: TotalsFixture) throws {
        let label = fixture.name
        let habit = fixture.builtHabit
        let events = try fixture.builtEvents()
        let summe = periodTotal(for: habit, entries: fixture.builtEntries, events: events,
                                from: fixture.range.from, to: fixture.range.to)
        let e = fixture.expected

        if let expected = e.total {
            #expect(abs(summe.total - expected) < 1e-9,
                    "\(label): total — erwartet \(expected), war \(summe.total)")
        }
        if let expected = e.activeDays {
            #expect(summe.activeDays == expected,
                    "\(label): activeDays — erwartet \(expected), war \(summe.activeDays)")
        }
        if let expected = e.dayCount {
            #expect(summe.dayCount == expected,
                    "\(label): dayCount — erwartet \(expected), war \(summe.dayCount)")
        }
        if let expected = e.sessionCount {
            #expect(summe.sessionCount == expected,
                    "\(label): sessionCount — erwartet \(expected), war \(summe.sessionCount)")
        }

        if let expectedSchnitt = e.averagePerActiveDay {
            if let expected = expectedSchnitt {
                let actual = try #require(summe.averagePerActiveDay,
                                          "\(label): averagePerActiveDay fehlt")
                #expect(abs(actual - expected) < 1e-9,
                        "\(label): averagePerActiveDay — erwartet \(expected), war \(actual)")
            } else {
                #expect(summe.averagePerActiveDay == nil,
                        "\(label): averagePerActiveDay müsste nil sein")
            }
        }

        for (iso, wert) in e.byDay ?? [:] {
            let date = try #require(CalendarDate(iso: iso), "\(label): ungültiges Datum \(iso)")
            let actual = try #require(summe.byDay[date], "\(label): byDay \(iso) fehlt")
            #expect(abs(actual - wert) < 1e-9, "\(label): byDay \(iso) — war \(actual)")
        }
        for (iso, wert) in e.byWeek ?? [:] {
            let date = try #require(CalendarDate(iso: iso), "\(label): ungültiges Datum \(iso)")
            let actual = try #require(summe.byWeek[date], "\(label): byWeek \(iso) fehlt")
            #expect(abs(actual - wert) < 1e-9, "\(label): byWeek \(iso) — war \(actual)")
        }

        if let expected = e.sessions {
            let tages = sessions(of: habit, on: expected.date, events: events)
            #expect(tages.count == expected.count,
                    "\(label): Zahl der Sitzungen — erwartet \(expected.count), war \(tages.count)")
            if let starts = expected.starts {
                let erwartet = try starts.map(TotalsFixture.zeit)
                #expect(tages.map(\.at) == erwartet, "\(label): Startzeiten sortiert")
            }
        }

        for erwartet in e.events ?? [] {
            let event = try #require(events.first { $0.date == erwartet.date },
                                     "\(label): Kein Event am \(erwartet.date)")
            if let expectedDauer = erwartet.durationMinutes {
                if let expected = expectedDauer {
                    let actual = try #require(event.durationMinutes,
                                              "\(label): \(erwartet.date) durationMinutes fehlt")
                    #expect(abs(actual - expected) < 1e-9,
                            "\(label): \(erwartet.date) durationMinutes — war \(actual)")
                } else {
                    #expect(event.durationMinutes == nil,
                            "\(label): \(erwartet.date) durationMinutes müsste nil sein")
                }
            }
            if let expected = erwartet.effectiveValue {
                #expect(abs(event.effectiveValue - expected) < 1e-9,
                        "\(label): \(erwartet.date) effectiveValue — war \(event.effectiveValue)")
            }
            if let expected = erwartet.hasValidInterval {
                #expect(event.hasValidInterval == expected,
                        "\(label): \(erwartet.date) hasValidInterval")
            }
        }
    }
}
