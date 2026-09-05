import Testing
import Foundation
@testable import HabitCore

/// Ein Fokus-Fixture aus `spec/fixtures/focus/`.
///
/// Zwei Sorten in einer Form: entweder ein `run`, der gegen Einträge ausgewertet
/// wird, oder fertige `outcomes` für die Bilanz — die braucht keine Einträge.
struct FocusFixture: Decodable, Sendable {

    struct RunSpec: Decodable, Sendable {
        let startsOn: CalendarDate
        let endsOn: CalendarDate
        /// Schlüssel der beteiligten Habits; fehlt = alle.
        let habits: [String]?
        let abandonedOn: CalendarDate?
        let title: String?
    }

    /// `FocusOutcome` ist kein `Codable` — die Fixtures beschreiben es über
    /// denselben `code`, den die Domäne für die Serialisierung vorsieht.
    struct OutcomeSpec: Decodable, Sendable {
        let code: String
        let on: CalendarDate?
        let dayNumber: Int?
        let totalDays: Int?

        func built() throws -> FocusOutcome {
            switch code {
            case "upcoming": return .upcoming
            case "completed": return .completed
            case "running":
                return .running(dayNumber: dayNumber ?? 0, totalDays: totalDays ?? 0)
            case "failed":
                guard let on else { throw FixtureError.unknownOutcome("failed ohne on") }
                return .failed(on: on)
            case "abandoned":
                guard let on else { throw FixtureError.unknownOutcome("abandoned ohne on") }
                return .abandoned(on: on)
            default: throw FixtureError.unknownOutcome(code)
            }
        }
    }

    struct RecordExpectation: Decodable, Sendable {
        let completed: Int?
        let failed: Int?
        let abandoned: Int?
        let finished: Int?
        let longestWinStreak: Int?
        /// Wie überall doppelt optional: Schlüssel fehlt = nicht prüfen,
        /// Schlüssel mit null = es muss nil herauskommen.
        let successRate: Double??

        private enum CodingKeys: String, CodingKey {
            case completed, failed, abandoned, finished, longestWinStreak, successRate
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            completed = try c.decodeIfPresent(Int.self, forKey: .completed)
            failed = try c.decodeIfPresent(Int.self, forKey: .failed)
            abandoned = try c.decodeIfPresent(Int.self, forKey: .abandoned)
            finished = try c.decodeIfPresent(Int.self, forKey: .finished)
            longestWinStreak = try c.decodeIfPresent(Int.self, forKey: .longestWinStreak)
            successRate = c.contains(.successRate)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .successRate))
                : nil
        }
    }

    struct Expected: Decodable, Sendable {
        let outcome: String?
        /// Bei `failed` und `abandoned`: der Tag.
        let on: CalendarDate?
        let dayNumber: Int?
        let totalDays: Int?
        let perfectDays: Int?
        let plannedDays: Int?
        let elapsedDays: Int?
        let fraction: Double?
        let record: RecordExpectation?
    }

    let name: String
    let today: CalendarDate
    let habits: [OverviewFixture.HabitSpec]
    let entries: [OverviewFixture.EntrySpec]
    let exceptions: [OverviewFixture.ExceptionSpec]
    let run: RunSpec?
    let outcomes: [OutcomeSpec]?
    let expected: Expected

    static let runId = UUID(uuidString: "00000000-0000-0000-0000-00000000F0C0")!

    var habitIds: [String: UUID] {
        var result: [String: UUID] = [:]
        for (index, spec) in habits.enumerated() {
            result[spec.key] = OverviewFixture.id(at: index)
        }
        return result
    }

    var builtHabits: [Habit] {
        habits.enumerated().map { index, spec in
            Habit(id: OverviewFixture.id(at: index), name: spec.name ?? spec.key,
                  kind: spec.kind, rules: spec.rules,
                  startsOn: spec.startsOn, endsOn: spec.endsOn, archivedOn: spec.archivedOn)
        }
    }

    func builtRun() throws -> FocusRun? {
        guard let run else { return nil }
        let ids = habitIds
        let beteiligte = try (run.habits ?? []).map { key -> UUID in
            guard let id = ids[key] else { throw FixtureError.unknownHabit(key) }
            return id
        }
        return FocusRun(id: FocusFixture.runId, title: run.title,
                        startsOn: run.startsOn, endsOn: run.endsOn,
                        habitIds: beteiligte, abandonedOn: run.abandonedOn)
    }

    func builtEntries() throws -> [Entry] {
        let ids = habitIds
        return try entries.map {
            guard let id = ids[$0.habit] else { throw FixtureError.unknownHabit($0.habit) }
            return Entry(habitId: id, date: $0.date, value: $0.value)
        }
    }

    func builtExceptions() throws -> [DayException] {
        let ids = habitIds
        return try exceptions.map { spec in
            var habitId: UUID?
            if let key = spec.habit {
                guard let id = ids[key] else { throw FixtureError.unknownHabit(key) }
                habitId = id
            }
            return DayException(habitId: habitId, date: spec.date, kind: spec.kind)
        }
    }

    static func loadAll() throws -> [FocusFixture] { try FixtureFiles.load("focus") }
}

@Suite("Golden Fixtures: Fokus")
struct FocusFixtureTests {

    @Test("spec/fixtures/focus liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try FocusFixture.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("focus").path)")
    }

    @Test("Jedes Fokus-Fixture wird exakt reproduziert", arguments: try FocusFixture.loadAll())
    func matchesExpectation(fixture: FocusFixture) throws {
        let label = fixture.name
        let e = fixture.expected

        if let run = try fixture.builtRun() {
            let progress = evaluate(run, habits: fixture.builtHabits,
                                    entries: try fixture.builtEntries(),
                                    exceptions: try fixture.builtExceptions(),
                                    today: fixture.today)

            if let expected = e.outcome {
                #expect(progress.outcome.code == expected,
                        "\(label): outcome — erwartet \(expected), war \(progress.outcome.code)")
            }
            if let expected = e.on {
                switch progress.outcome {
                case .failed(let on), .abandoned(let on):
                    #expect(on == expected, "\(label): outcome.on — erwartet \(expected), war \(on)")
                default:
                    Issue.record("\(label): \(progress.outcome.code) trägt keinen Tag")
                }
            }
            if let expected = e.dayNumber {
                if case .running(let dayNumber, _) = progress.outcome {
                    #expect(dayNumber == expected,
                            "\(label): dayNumber — erwartet \(expected), war \(dayNumber)")
                } else {
                    Issue.record("\(label): dayNumber gibt es nur bei running")
                }
            }
            if let expected = e.totalDays {
                #expect(progress.totalDays == expected,
                        "\(label): totalDays — erwartet \(expected), war \(progress.totalDays)")
            }
            if let expected = e.perfectDays {
                #expect(progress.perfectDays == expected,
                        "\(label): perfectDays — erwartet \(expected), war \(progress.perfectDays)")
            }
            if let expected = e.plannedDays {
                #expect(progress.plannedDays == expected,
                        "\(label): plannedDays — erwartet \(expected), war \(progress.plannedDays)")
            }
            if let expected = e.elapsedDays {
                #expect(progress.elapsedDays == expected,
                        "\(label): elapsedDays — erwartet \(expected), war \(progress.elapsedDays)")
            }
            if let expected = e.fraction {
                #expect(abs(progress.fraction - expected) < 1e-9,
                        "\(label): fraction — erwartet \(expected), war \(progress.fraction)")
            }
        }

        if let expected = e.record {
            let specs = try #require(fixture.outcomes,
                                     "\(label): record erwartet, aber keine outcomes im Fixture")
            let bilanz = record(of: try specs.map { try $0.built() })

            if let v = expected.completed {
                #expect(bilanz.completed == v,
                        "\(label): completed — erwartet \(v), war \(bilanz.completed)")
            }
            if let v = expected.failed {
                #expect(bilanz.failed == v, "\(label): failed — erwartet \(v), war \(bilanz.failed)")
            }
            if let v = expected.abandoned {
                #expect(bilanz.abandoned == v,
                        "\(label): abandoned — erwartet \(v), war \(bilanz.abandoned)")
            }
            if let v = expected.finished {
                #expect(bilanz.finished == v,
                        "\(label): finished — erwartet \(v), war \(bilanz.finished)")
            }
            if let v = expected.longestWinStreak {
                #expect(bilanz.longestWinStreak == v,
                        "\(label): longestWinStreak — erwartet \(v), war \(bilanz.longestWinStreak)")
            }
            if let expectedRate = expected.successRate {
                if let v = expectedRate {
                    let actual = try #require(bilanz.successRate, "\(label): successRate fehlt")
                    #expect(abs(actual - v) < 1e-9,
                            "\(label): successRate — erwartet \(v), war \(actual)")
                } else {
                    #expect(bilanz.successRate == nil, "\(label): successRate müsste nil sein")
                }
            }
        }
    }
}
