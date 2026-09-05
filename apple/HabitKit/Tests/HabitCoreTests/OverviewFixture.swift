import Foundation
@testable import HabitCore

/// Ein Übersichts-Fixture aus `spec/fixtures/overview/`.
///
/// Anders als ein Statistik-Fixture beschreibt es **mehrere** Habits — die
/// Nenner-Regel der Übersicht lässt sich an einem einzelnen gar nicht zeigen.
/// Einträge und Ausnahmen verweisen deshalb über einen kurzen Schlüssel auf
/// ihren Habit; beide Seiten machen daraus dieselbe UUID.
struct OverviewFixture: Decodable, Sendable {
    struct Range: Decodable, Sendable { let from: CalendarDate; let to: CalendarDate }

    struct HabitSpec: Decodable, Sendable {
        let key: String
        let name: String?
        let kind: HabitKind
        let rules: [HabitRule]
        var startsOn: CalendarDate?
        var endsOn: CalendarDate?
        var archivedOn: CalendarDate?
    }

    struct EntrySpec: Decodable, Sendable {
        let habit: String
        let date: CalendarDate
        let value: Double
    }

    struct ExceptionSpec: Decodable, Sendable {
        /// `nil` heißt: gilt für alle Habits (Urlaub).
        let habit: String?
        let date: CalendarDate
        let kind: ExceptionKind
    }

    struct DayExpectation: Decodable, Sendable {
        let completed: Int?
        let scheduled: Int?
        let isPerfect: Bool?
        /// Wie überall: Schlüssel fehlt = nicht prüfen, `null` = muss nil sein.
        let share: Double??

        private enum CodingKeys: String, CodingKey { case completed, scheduled, isPerfect, share }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            completed = try c.decodeIfPresent(Int.self, forKey: .completed)
            scheduled = try c.decodeIfPresent(Int.self, forKey: .scheduled)
            isPerfect = try c.decodeIfPresent(Bool.self, forKey: .isPerfect)
            share = c.contains(.share)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .share))
                : nil
        }
    }

    struct StatsExpectation: Decodable, Sendable {
        let perfectDays: Int?
        let daysWithPlan: Int?
        let totalCompletions: Int?
        let perfectStreak: Int?
        let busiestDay: Int?
    }

    /// Farbstufe für einen Tag aus dem Zeitraum.
    struct IntensityCase: Decodable, Sendable {
        let date: CalendarDate
        let scale: IntensityScale
        let busiestDay: Int
        let level: Int
    }

    /// Farbstufe für eine frei gesetzte Tagesbilanz — ohne Habits.
    struct LevelCase: Decodable, Sendable {
        let completed: Int
        let scheduled: Int
        let scale: IntensityScale
        let busiestDay: Int
        let level: Int
    }

    struct SpanCase: Decodable, Sendable {
        let span: OverviewSpan
        let anchor: CalendarDate
        let range: Range?
        let shiftBy: Int?
        let shifted: CalendarDate?
        let maximumDays: Int?
    }

    struct Expected: Decodable, Sendable {
        /// Nur die aufgeführten Tage werden geprüft, nicht der ganze Zeitraum.
        let days: [String: DayExpectation]?
        let stats: StatsExpectation?
        let intensity: [IntensityCase]?
        let levels: [LevelCase]?
        let spans: [SpanCase]?
    }

    let name: String
    let today: CalendarDate
    let range: Range
    let habits: [HabitSpec]
    let entries: [EntrySpec]
    let exceptions: [ExceptionSpec]
    let expected: Expected

    // MARK: - Aufbau

    /// Schlüssel → ID, aus der Position abgeleitet wie auf der TypeScript-Seite.
    var habitIds: [String: UUID] {
        var result: [String: UUID] = [:]
        for (index, spec) in habits.enumerated() {
            result[spec.key] = OverviewFixture.id(at: index)
        }
        return result
    }

    static func id(at index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!
    }

    var builtHabits: [Habit] {
        habits.enumerated().map { index, spec in
            Habit(id: OverviewFixture.id(at: index),
                  name: spec.name ?? spec.key,
                  kind: spec.kind,
                  rules: spec.rules,
                  startsOn: spec.startsOn,
                  endsOn: spec.endsOn,
                  archivedOn: spec.archivedOn)
        }
    }

    func builtEntries() throws -> [Entry] {
        let ids = habitIds
        return try entries.map {
            guard let id = ids[$0.habit] else {
                throw FixtureError.unknownHabit($0.habit)
            }
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

    static func loadAll() throws -> [OverviewFixture] {
        try FixtureFiles.load("overview")
    }
}
