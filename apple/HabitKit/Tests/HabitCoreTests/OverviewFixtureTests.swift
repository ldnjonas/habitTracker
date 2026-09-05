import Testing
import Foundation
@testable import HabitCore

@Suite("Golden Fixtures: Übersicht")
struct OverviewFixtureTests {

    @Test("spec/fixtures/overview liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try OverviewFixture.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("overview").path)")
    }

    @Test("Jedes Übersichts-Fixture wird exakt reproduziert",
          arguments: try OverviewFixture.loadAll())
    func matchesExpectation(fixture: OverviewFixture) throws {
        let habits = fixture.builtHabits
        let entries = try fixture.builtEntries()
        let exceptions = try fixture.builtExceptions()
        let label = fixture.name

        let summaries = overview(habits: habits, entries: entries, exceptions: exceptions,
                                 from: fixture.range.from, to: fixture.range.to,
                                 today: fixture.today)
        let e = fixture.expected

        for (iso, erwartet) in e.days ?? [:] {
            let date = try #require(CalendarDate(iso: iso), "\(label): ungültiges Datum \(iso)")
            let summary = try #require(summaries[date], "\(label): \(iso) fehlt im Zeitraum")

            if let expected = erwartet.completed {
                #expect(summary.completed == expected,
                        "\(label): \(iso) completed — erwartet \(expected), war \(summary.completed)")
            }
            if let expected = erwartet.scheduled {
                #expect(summary.scheduled == expected,
                        "\(label): \(iso) scheduled — erwartet \(expected), war \(summary.scheduled)")
            }
            if let expected = erwartet.isPerfect {
                #expect(summary.isPerfect == expected, "\(label): \(iso) isPerfect")
            }
            if let expectedShare = erwartet.share {
                if let expected = expectedShare {
                    let actual = try #require(summary.share, "\(label): \(iso) share fehlt")
                    #expect(abs(actual - expected) < 1e-9,
                            "\(label): \(iso) share — erwartet \(expected), war \(actual)")
                } else {
                    #expect(summary.share == nil, "\(label): \(iso) share müsste nil sein")
                }
            }
        }

        if let expected = e.stats {
            let actual = overviewStats(summaries: summaries, from: fixture.range.from,
                                       to: fixture.range.to, today: fixture.today)
            if let v = expected.perfectDays {
                #expect(actual.perfectDays == v,
                        "\(label): perfectDays — erwartet \(v), war \(actual.perfectDays)")
            }
            if let v = expected.daysWithPlan {
                #expect(actual.daysWithPlan == v,
                        "\(label): daysWithPlan — erwartet \(v), war \(actual.daysWithPlan)")
            }
            if let v = expected.totalCompletions {
                #expect(actual.totalCompletions == v,
                        "\(label): totalCompletions — erwartet \(v), war \(actual.totalCompletions)")
            }
            if let v = expected.perfectStreak {
                #expect(actual.perfectStreak == v,
                        "\(label): perfectStreak — erwartet \(v), war \(actual.perfectStreak)")
            }
            if let v = expected.busiestDay {
                #expect(actual.busiestDay == v,
                        "\(label): busiestDay — erwartet \(v), war \(actual.busiestDay)")
            }
        }

        for fall in e.intensity ?? [] {
            let summary = try #require(summaries[fall.date],
                                       "\(label): \(fall.date) fehlt im Zeitraum")
            let actual = intensityLevel(summary, scale: fall.scale, busiestDay: fall.busiestDay)
            #expect(actual == fall.level,
                    "\(label): Farbstufe \(fall.date) nach \(fall.scale.rawValue) — erwartet \(fall.level), war \(actual)")
        }

        for fall in e.levels ?? [] {
            let summary = DaySummary(date: fixture.today,
                                     completed: fall.completed, scheduled: fall.scheduled)
            let actual = intensityLevel(summary, scale: fall.scale, busiestDay: fall.busiestDay)
            #expect(actual == fall.level,
                    "\(label): Farbstufe \(fall.completed)/\(fall.scheduled) nach \(fall.scale.rawValue) bei busiestDay \(fall.busiestDay) — erwartet \(fall.level), war \(actual)")
        }

        for fall in e.spans ?? [] {
            if let expected = fall.range {
                let actual = fall.span.range(containing: fall.anchor)
                #expect(actual.from == expected.from,
                        "\(label): \(fall.span.rawValue) ab \(fall.anchor) — from")
                #expect(actual.to == expected.to,
                        "\(label): \(fall.span.rawValue) ab \(fall.anchor) — to")
            }
            if let expected = fall.shifted {
                let steps = try #require(fall.shiftBy, "\(label): shifted ohne shiftBy")
                let actual = fall.span.shift(fall.anchor, by: steps)
                #expect(actual == expected,
                        "\(label): \(fall.span.rawValue) \(fall.anchor) um \(steps) — erwartet \(expected), war \(actual)")
            }
            if let expected = fall.maximumDays {
                #expect(fall.span.maximumDays == expected,
                        "\(label): \(fall.span.rawValue) maximumDays")
            }
        }
    }
}
