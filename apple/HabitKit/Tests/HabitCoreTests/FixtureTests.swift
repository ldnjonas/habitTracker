import Testing
import Foundation
@testable import HabitCore

@Suite("Golden Fixtures")
struct FixtureTests {

    @Test("spec/fixtures liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        let all = try Fixture.loadAll()
        #expect(!all.isEmpty, "Keine Fixtures unter \(Fixture.directory.path)")
    }

    @Test("Jedes Fixture wird exakt reproduziert", arguments: try Fixture.loadAll())
    func matchesExpectation(fixture: Fixture) throws {
        let habit = fixture.builtHabit
        let result = stats(
            for: habit,
            entries: fixture.builtEntries,
            exceptions: fixture.builtExceptions,
            from: fixture.range.from,
            to: fixture.range.to,
            today: fixture.today
        )
        let e = fixture.expected
        let label = fixture.name

        if let unit = e.streakUnit {
            #expect(result.streakUnit == unit, "\(label): streakUnit")
        }
        if let expected = e.currentStreak {
            #expect(result.currentStreak == expected,
                    "\(label): currentStreak — erwartet \(expected), war \(result.currentStreak)")
        }
        if let expected = e.longestStreak {
            #expect(result.longestStreak == expected,
                    "\(label): longestStreak — erwartet \(expected), war \(result.longestStreak)")
        }
        if let expected = e.completedCount {
            #expect(result.completedCount == expected,
                    "\(label): completedCount — erwartet \(expected), war \(result.completedCount)")
        }
        if let expected = e.evaluatedCount {
            #expect(result.evaluatedCount == expected,
                    "\(label): evaluatedCount — erwartet \(expected), war \(result.evaluatedCount)")
        }
        // Wie bei `trend` zwei Ebenen von „fehlt": Schlüssel nicht vorhanden =
        // nicht prüfen, Schlüssel mit null = es muss nil herauskommen.
        if let expectedRate = e.completionRate {
            if let expected = expectedRate {
                let actual = try #require(result.completionRate, "\(label): completionRate fehlt")
                #expect(abs(actual - expected) < 1e-9,
                        "\(label): completionRate — erwartet \(expected), war \(actual)")
            } else {
                #expect(result.completionRate == nil, "\(label): completionRate müsste nil sein")
            }
        } else if e.evaluatedCount == 0 {
            #expect(result.completionRate == nil, "\(label): completionRate müsste nil sein")
        }

        for (iso, expectedCode) in e.days ?? [:] {
            let date = try #require(CalendarDate(iso: iso), "\(label): ungültiges Datum \(iso)")
            let actual = try #require(result.days[date], "\(label): \(iso) fehlt im Zeitraum")
            #expect(actual.code == expectedCode,
                    "\(label): \(iso) — erwartet \(expectedCode), war \(actual.code)")
        }

        for (raw, expectedShare) in e.weekdayBreakdown ?? [:] {
            let weekday = try #require(Int(raw).flatMap(Weekday.init(rawValue:)),
                                       "\(label): ungültiger Wochentag \(raw)")
            let actual = try #require(result.weekdayBreakdown[weekday],
                                      "\(label): Wochentag \(raw) fehlt")
            #expect(abs(actual - expectedShare) < 1e-9,
                    "\(label): Wochentag \(raw) — erwartet \(expectedShare), war \(actual)")
        }

        // `trend` doppelt optional: Schlüssel fehlt = nicht prüfen,
        // Schlüssel mit null = es muss nil herauskommen.
        if let expectedTrend = e.trend {
            let actual = trend(for: habit, entries: fixture.builtEntries,
                               exceptions: fixture.builtExceptions, today: fixture.today)
            #expect(actual?.code == expectedTrend,
                    "\(label): trend — erwartet \(expectedTrend ?? "nil"), war \(actual?.code ?? "nil")")
        }
    }
}
