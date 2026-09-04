import Foundation
@testable import HabitCore

/// Ein Golden-Fixture aus `spec/fixtures/`.
///
/// Dieselben Dateien werden später von der TypeScript-Portierung gelesen — das
/// ist der Vertrag, der Swift und TS davon abhält, auseinanderzulaufen.
struct Fixture: Decodable, Sendable {
    struct Range: Decodable, Sendable { let from: CalendarDate; let to: CalendarDate }

    struct HabitSpec: Decodable, Sendable {
        let kind: HabitKind
        let rules: [HabitRule]
        var startsOn: CalendarDate?
        var endsOn: CalendarDate?
        var archivedOn: CalendarDate?
    }

    struct EntrySpec: Decodable, Sendable { let date: CalendarDate; let value: Double }

    struct ExceptionSpec: Decodable, Sendable { let date: CalendarDate; let kind: ExceptionKind }

    struct Expected: Decodable, Sendable {
        let streakUnit: StreakUnit?
        let currentStreak: Int?
        let longestStreak: Int?
        let completedCount: Int?
        let evaluatedCount: Int?
        let completionRate: Double?
        /// Nur die aufgeführten Tage werden geprüft, nicht der ganze Zeitraum.
        let days: [String: String]?
        let weekdayBreakdown: [String: Double]?
        /// Zwei Ebenen von „fehlt": Schlüssel nicht vorhanden = nicht prüfen,
        /// Schlüssel mit `null` = es muss `nil` herauskommen.
        ///
        /// Der synthetisierte Decoder kann das nicht: er bildet einen fehlenden
        /// Schlüssel und `null` beide auf das äußere `nil` ab, wodurch die
        /// Prüfung auf „kein Trend" stillschweigend ausfiele.
        let trend: String??

        private enum CodingKeys: String, CodingKey {
            case streakUnit, currentStreak, longestStreak, completedCount
            case evaluatedCount, completionRate, days, weekdayBreakdown, trend
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            streakUnit = try c.decodeIfPresent(StreakUnit.self, forKey: .streakUnit)
            currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak)
            longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak)
            completedCount = try c.decodeIfPresent(Int.self, forKey: .completedCount)
            evaluatedCount = try c.decodeIfPresent(Int.self, forKey: .evaluatedCount)
            completionRate = try c.decodeIfPresent(Double.self, forKey: .completionRate)
            days = try c.decodeIfPresent([String: String].self, forKey: .days)
            weekdayBreakdown = try c.decodeIfPresent([String: Double].self, forKey: .weekdayBreakdown)
            trend = c.contains(.trend)
                ? .some(try c.decodeIfPresent(String.self, forKey: .trend))
                : nil
        }
    }

    let name: String
    let today: CalendarDate
    let range: Range
    let habit: HabitSpec
    let entries: [EntrySpec]
    let exceptions: [ExceptionSpec]
    let expected: Expected

    /// Feste ID, damit Einträge und Habit zueinander finden.
    static let habitId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    var builtHabit: Habit {
        Habit(
            id: Fixture.habitId,
            name: name,
            kind: habit.kind,
            rules: habit.rules,
            startsOn: habit.startsOn,
            endsOn: habit.endsOn,
            archivedOn: habit.archivedOn
        )
    }

    var builtEntries: [Entry] {
        entries.map { Entry(habitId: Fixture.habitId, date: $0.date, value: $0.value) }
    }

    var builtExceptions: [DayException] {
        exceptions.map { DayException(habitId: nil, date: $0.date, kind: $0.kind) }
    }

    // MARK: - Laden

    /// `spec/fixtures/` relativ zu dieser Quelldatei — vier Ebenen hoch zum Repo-Wurzelverzeichnis.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/HabitCoreTests/Fixture.swift
            .deletingLastPathComponent()          // …/Tests/HabitCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/HabitKit
            .deletingLastPathComponent()          // …/apple
            .deletingLastPathComponent()          // Repo-Wurzel
            .appendingPathComponent("spec/fixtures")
    }

    static func loadAll() throws -> [Fixture] {
        let urls = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        return try urls.map { url in
            do {
                return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
            } catch {
                throw FixtureError.undecodable(url.lastPathComponent, error)
            }
        }
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case undecodable(String, any Error)

    var description: String {
        switch self {
        case .undecodable(let file, let error): "\(file): \(error)"
        }
    }
}
