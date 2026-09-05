import Testing
import Foundation
@testable import HabitCore

/// Ein Freeze-Fixture aus `spec/fixtures/freeze/`.
///
/// Läufe und Buchungen tragen Schlüssel statt UUIDs — eine Buchung verweist
/// über denselben Schlüssel auf den Lauf, der eingezahlt hat.
struct FreezeFixture: Decodable, Sendable {

    struct RunSpec: Decodable, Sendable {
        let key: String
        let startsOn: CalendarDate
        let endsOn: CalendarDate
        let outcome: FocusFixture.OutcomeSpec
    }

    struct LedgerSpec: Decodable, Sendable {
        let amount: Int
        let reason: FreezeReason
        /// Schlüssel des Laufs, der eingezahlt hat.
        let focusRun: String?
    }

    struct FreezableCase: Decodable, Sendable {
        let status: String
        let date: CalendarDate
        let can: Bool

        /// Aus dem `code` einen Status bauen. `partial` trägt einen Fortschritt,
        /// den `canFreeze` nicht ansieht — null genügt.
        func builtStatus() throws -> DayStatus {
            switch status {
            case "completed": return .completed
            case "missed": return .missed
            case "notScheduled": return .notScheduled
            case "future": return .future
            case "partial": return .partial(0)
            case "frozen", "paused", "skipped":
                return .excepted(ExceptionKind(rawValue: status)!)
            default: throw FixtureError.unknownOutcome(status)
            }
        }
    }

    struct Expected: Decodable, Sendable {
        let balance: Int?
        /// Schlüssel der Läufe, die noch einzahlen dürfen — in dieser Reihenfolge.
        let pendingAwards: [String]?
        let freezable: [FreezableCase]?
    }

    let name: String
    let today: CalendarDate
    let runs: [RunSpec]
    let ledger: [LedgerSpec]
    let expected: Expected

    var runIds: [String: UUID] {
        var result: [String: UUID] = [:]
        for (index, spec) in runs.enumerated() {
            result[spec.key] = OverviewFixture.id(at: index)
        }
        return result
    }

    func builtOutcomes() throws -> [(run: FocusRun, outcome: FocusOutcome)] {
        let ids = runIds
        return try runs.map { spec in
            (FocusRun(id: ids[spec.key]!, startsOn: spec.startsOn, endsOn: spec.endsOn),
             try spec.outcome.built())
        }
    }

    func builtLedger() throws -> [FreezeEntry] {
        let ids = runIds
        return try ledger.map { spec in
            var focusRunId: UUID?
            if let key = spec.focusRun {
                guard let id = ids[key] else { throw FixtureError.unknownHabit(key) }
                focusRunId = id
            }
            return FreezeEntry(amount: spec.amount, reason: spec.reason, focusRunId: focusRunId)
        }
    }

    static func loadAll() throws -> [FreezeFixture] { try FixtureFiles.load("freeze") }
}

@Suite("Golden Fixtures: Freeze-Konto")
struct FreezeFixtureTests {

    @Test("spec/fixtures/freeze liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try FreezeFixture.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("freeze").path)")
    }

    @Test("Jedes Freeze-Fixture wird exakt reproduziert", arguments: try FreezeFixture.loadAll())
    func matchesExpectation(fixture: FreezeFixture) throws {
        let label = fixture.name
        let ledger = try fixture.builtLedger()
        let e = fixture.expected

        if let expected = e.balance {
            let actual = freezeBalance(ledger)
            #expect(actual == expected, "\(label): balance — erwartet \(expected), war \(actual)")
        }

        if let expected = e.pendingAwards {
            let ids = fixture.runIds
            let faellig = pendingFreezeAwards(outcomes: try fixture.builtOutcomes(),
                                              ledger: ledger)
            let schluessel = faellig.map { run in
                ids.first { $0.value == run.id }?.key ?? run.id.uuidString
            }
            #expect(schluessel == expected,
                    "\(label): pendingAwards — erwartet \(expected), war \(schluessel)")
        }

        for fall in e.freezable ?? [] {
            let actual = canFreeze(try fall.builtStatus(), on: fall.date, today: fixture.today)
            #expect(actual == fall.can,
                    "\(label): canFreeze(\(fall.status), \(fall.date)) — erwartet \(fall.can)")
        }
    }
}
