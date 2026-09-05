import Testing
import Foundation
@testable import HabitCore

/// Ein Korrelations-Fixture aus `spec/fixtures/correlations/`.
///
/// Der eigentliche Gegenstand ist die **Zurückhaltung**: die meisten dieser
/// Fixtures erwarten keinen Befund, und genau das ist die Aussage.
struct CorrelationFixture: Decodable, Sendable {

    struct Range: Decodable, Sendable { let from: CalendarDate; let to: CalendarDate }

    struct LogSpec: Decodable, Sendable {
        let date: CalendarDate
        let mood: Int?
        let energy: Int?
        let sleepHours: Double?
    }

    struct FindingExpectation: Decodable, Sendable {
        let habit: String
        let metric: JournalMetric
        let strength: CorrelationStrength?
        let coefficientAbove: Double?
        let coefficientBelow: Double?
        let completedAverage: Double?
        let missedAverage: Double?
        let difference: Double?
        let dayCount: Int?
        let completedDays: Int?
    }

    struct PearsonCase: Decodable, Sendable {
        let completed: [Double]
        let missed: [Double]
        /// Doppelt optional: Schlüssel fehlt = nicht prüfen, null = muss nil sein.
        let value: Double??
        let above: Double?
        let belowRequiredForDays: Int?

        private enum CodingKeys: String, CodingKey {
            case completed, missed, value, above, belowRequiredForDays
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            completed = try c.decode([Double].self, forKey: .completed)
            missed = try c.decode([Double].self, forKey: .missed)
            above = try c.decodeIfPresent(Double.self, forKey: .above)
            belowRequiredForDays = try c.decodeIfPresent(Int.self, forKey: .belowRequiredForDays)
            value = c.contains(.value)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .value))
                : nil
        }
    }

    struct RequiredCase: Decodable, Sendable {
        let days: Int
        let value: Double
        let tolerance: Double
    }

    struct MonotoneCase: Decodable, Sendable {
        let from: Int
        let to: Int
        let step: Int
    }

    struct StrengthCase: Decodable, Sendable {
        let coefficient: Double
        /// Doppelt optional: null heißt „unter der Schwelle, also keine Stärke".
        let strength: CorrelationStrength??

        private enum CodingKeys: String, CodingKey { case coefficient, strength }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            coefficient = try c.decode(Double.self, forKey: .coefficient)
            strength = c.contains(.strength)
                ? .some(try c.decodeIfPresent(CorrelationStrength.self, forKey: .strength))
                : nil
        }
    }

    struct Expected: Decodable, Sendable {
        let count: Int?
        let minimumCount: Int?
        let findings: [FindingExpectation]?
        /// Größen, zu denen ausdrücklich **nichts** berichtet werden darf.
        let absent: [JournalMetric]?
        let first: FirstExpectation?
        let pearson: [PearsonCase]?
        let required: [RequiredCase]?
        let requiredIsMonotone: MonotoneCase?
        let strengths: [StrengthCase]?
        let minimumDays: Int?
        let minimumPerGroup: Int?

        struct FirstExpectation: Decodable, Sendable { let metric: JournalMetric }
    }

    let name: String
    let today: CalendarDate
    let range: Range
    let habits: [OverviewFixture.HabitSpec]
    let entries: [OverviewFixture.EntrySpec]
    let dayLogs: [LogSpec]
    let exceptions: [OverviewFixture.ExceptionSpec]
    let expected: Expected

    var habitIds: [String: UUID] {
        var result: [String: UUID] = [:]
        for (index, spec) in habits.enumerated() { result[spec.key] = OverviewFixture.id(at: index) }
        return result
    }

    var builtHabits: [Habit] {
        habits.enumerated().map { index, spec in
            Habit(id: OverviewFixture.id(at: index), name: spec.name ?? spec.key,
                  kind: spec.kind, rules: spec.rules,
                  startsOn: spec.startsOn, endsOn: spec.endsOn, archivedOn: spec.archivedOn)
        }
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

    var builtLogs: [DayLog] {
        dayLogs.map { DayLog(date: $0.date, mood: $0.mood, energy: $0.energy,
                             sleepHours: $0.sleepHours) }
    }

    static func loadAll() throws -> [CorrelationFixture] { try FixtureFiles.load("correlations") }
}

@Suite("Golden Fixtures: Korrelationen")
struct CorrelationFixtureTests {

    @Test("spec/fixtures/correlations liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try CorrelationFixture.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("correlations").path)")
    }

    @Test("Jedes Korrelations-Fixture wird exakt reproduziert",
          arguments: try CorrelationFixture.loadAll())
    func matchesExpectation(fixture: CorrelationFixture) throws {
        let label = fixture.name
        let ergebnis = correlations(habits: fixture.builtHabits,
                                    entries: try fixture.builtEntries(),
                                    dayLogs: fixture.builtLogs,
                                    exceptions: try fixture.builtExceptions(),
                                    from: fixture.range.from, to: fixture.range.to,
                                    today: fixture.today)
        let e = fixture.expected

        if let expected = e.count {
            #expect(ergebnis.count == expected,
                    "\(label): Zahl der Befunde — erwartet \(expected), war \(ergebnis.count)")
        }
        if let expected = e.minimumCount {
            #expect(ergebnis.count >= expected,
                    "\(label): mindestens \(expected) Befunde, waren \(ergebnis.count)")
        }
        for metrik in e.absent ?? [] {
            #expect(ergebnis.first { $0.metric == metrik } == nil,
                    "\(label): \(metrik.rawValue) dürfte nicht berichtet werden")
        }
        if let expected = e.first {
            #expect(ergebnis.first?.metric == expected.metric,
                    "\(label): der deutlichste steht vorn")
        }

        let ids = fixture.habitIds
        for erwartet in e.findings ?? [] {
            let id = try #require(ids[erwartet.habit], "\(label): unbekannter Habit")
            let befund = try #require(
                ergebnis.first { $0.habitId == id && $0.metric == erwartet.metric },
                "\(label): Kein Befund für \(erwartet.habit)/\(erwartet.metric.rawValue)")

            if let v = erwartet.strength { #expect(befund.strength == v, "\(label): strength") }
            if let v = erwartet.coefficientAbove {
                #expect(befund.coefficient > v,
                        "\(label): coefficient \(befund.coefficient) > \(v)")
            }
            if let v = erwartet.coefficientBelow {
                #expect(befund.coefficient < v,
                        "\(label): coefficient \(befund.coefficient) < \(v)")
            }
            if let v = erwartet.completedAverage {
                #expect(abs(befund.completedAverage - v) < 1e-9, "\(label): completedAverage")
            }
            if let v = erwartet.missedAverage {
                #expect(abs(befund.missedAverage - v) < 1e-9, "\(label): missedAverage")
            }
            if let v = erwartet.difference {
                #expect(abs(befund.difference - v) < 1e-9,
                        "\(label): difference — erwartet \(v), war \(befund.difference)")
            }
            if let v = erwartet.dayCount { #expect(befund.dayCount == v, "\(label): dayCount") }
            if let v = erwartet.completedDays {
                #expect(befund.completedDays == v, "\(label): completedDays")
            }
        }

        for fall in e.pearson ?? [] {
            let r = pearson(erledigt: fall.completed, verpasst: fall.missed)
            if let expectedValue = fall.value, expectedValue == nil {
                #expect(r == nil, "\(label): pearson müsste nil sein")
                continue
            }
            let actual = try #require(r, "\(label): pearson fehlt")
            if let expectedValue = fall.value, let v = expectedValue {
                #expect(abs(actual - v) < 1e-9, "\(label): pearson — erwartet \(v), war \(actual)")
            }
            if let v = fall.above { #expect(actual > v, "\(label): pearson \(actual) > \(v)") }
            if let tage = fall.belowRequiredForDays {
                let huerde = CorrelationRule.requiredCoefficient(forDays: tage)
                #expect(actual < huerde, "\(label): pearson \(actual) < Hürde \(huerde)")
            }
        }

        for fall in e.required ?? [] {
            let actual = CorrelationRule.requiredCoefficient(forDays: fall.days)
            #expect(abs(actual - fall.value) < fall.tolerance,
                    "\(label): Hürde bei \(fall.days) Tagen — erwartet \(fall.value), war \(actual)")
        }

        if let monoton = e.requiredIsMonotone {
            for tage in stride(from: monoton.from, to: monoton.to, by: monoton.step) {
                #expect(CorrelationRule.requiredCoefficient(forDays: tage)
                        >= CorrelationRule.requiredCoefficient(forDays: tage + monoton.step),
                        "\(label): Mehr Daten dürfen die Hürde nie anheben: \(tage)")
            }
        }

        for fall in e.strengths ?? [] {
            let actual = CorrelationStrength(coefficient: fall.coefficient)
            if let expected = fall.strength {
                #expect(actual == expected,
                        "\(label): Stärke bei \(fall.coefficient) — erwartet \(String(describing: expected)), war \(String(describing: actual))")
            }
        }

        if let v = e.minimumDays {
            #expect(CorrelationRule.minimumDays == v, "\(label): minimumDays")
        }
        if let v = e.minimumPerGroup {
            #expect(CorrelationRule.minimumPerGroup == v, "\(label): minimumPerGroup")
        }
    }
}
