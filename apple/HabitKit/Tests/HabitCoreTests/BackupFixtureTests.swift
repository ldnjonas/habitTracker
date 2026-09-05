import Testing
import Foundation
@testable import HabitCore

/// Die Erwartung neben einer Sicherungsdatei — `<name>.expected.json`.
///
/// Getrennt von der Datei selbst, weil die Datei das echte Format ist und keine
/// Testfelder tragen darf: sie muss Byte für Byte das sein, was die App
/// schreibt.
struct BackupExpectation: Decodable, Sendable {
    struct Range: Decodable, Sendable { let from: CalendarDate; let to: CalendarDate }
    struct ProblemExpectation: Decodable, Sendable { let code: String; let fatal: Bool }

    let name: String
    /// Ob die Datei Byte für Byte wieder herauskommen muss. Falsch bei einer von
    /// Hand geschriebenen Datei — die ist absichtlich unaufgeräumt.
    let canonical: Bool
    let summary: String?
    /// Doppelt optional: Schlüssel fehlt = nicht prüfen, null = muss nil sein.
    let dateRange: Range??
    let formatVersion: Int?
    let scope: BackupFile.Scope?
    let exportedAt: String?
    let counts: [String: Int]?
    let problems: [ProblemExpectation]?

    private enum CodingKeys: String, CodingKey {
        case name, canonical, summary, dateRange, formatVersion, scope
        case exportedAt, counts, problems
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        canonical = try c.decode(Bool.self, forKey: .canonical)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
        scope = try c.decodeIfPresent(BackupFile.Scope.self, forKey: .scope)
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts)
        problems = try c.decodeIfPresent([ProblemExpectation].self, forKey: .problems)
        dateRange = c.contains(.dateRange)
            ? .some(try c.decodeIfPresent(Range.self, forKey: .dateRange))
            : nil
    }
}

/// Eine Sicherungsdatei samt ihrer Erwartung.
struct BackupCase: Sendable, CustomStringConvertible {
    let datei: String
    let inhalt: String
    let erwartet: BackupExpectation

    var description: String { "\(datei) — \(erwartet.name)" }

    static func loadAll() throws -> [BackupCase] {
        let verzeichnis = FixtureFiles.directory("backup")
        let dateien = try FileManager.default
            .contentsOfDirectory(at: verzeichnis, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".expected.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try dateien.map { url in
            let erwartung = url.deletingPathExtension()
                .appendingPathExtension("expected")
                .appendingPathExtension("json")
            do {
                return BackupCase(
                    datei: url.lastPathComponent,
                    inhalt: try String(contentsOf: url, encoding: .utf8),
                    erwartet: try JSONDecoder().decode(BackupExpectation.self,
                                                       from: Data(contentsOf: erwartung)))
            } catch {
                throw FixtureError.undecodable(url.lastPathComponent, error)
            }
        }
    }
}

@Suite("Golden Fixtures: Sicherungsdateien")
struct BackupFixtureTests {

    @Test("spec/fixtures/backup liegt am erwarteten Ort und ist nicht leer")
    func fixturesFound() throws {
        #expect(!(try BackupCase.loadAll()).isEmpty,
                "Keine Fixtures unter \(FixtureFiles.directory("backup").path)")
    }

    /// Hier geht es ausnahmsweise nicht um Zahlen, sondern um **Bytes**: die als
    /// `canonical` markierten Dateien müssen Zeichen für Zeichen wieder
    /// herauskommen — in beiden Fassungen. Damit ist eine Sicherung dieselbe
    /// Datei, gleich welche der beiden sie exportiert hat.
    @Test("Jede Sicherungsdatei wird exakt reproduziert", arguments: try BackupCase.loadAll())
    func matchesExpectation(fall: BackupCase) throws {
        let label = fall.erwartet.name
        let daten = Data(fall.inhalt.utf8)
        let file = try BackupCoding.decode(daten)
        let e = fall.erwartet

        if e.canonical {
            let neu = try BackupCoding.encode(file)
            #expect(String(data: neu, encoding: .utf8) == fall.inhalt,
                    "\(label): Die Datei kommt nicht Zeichen für Zeichen wieder heraus")
        }

        if let expected = e.formatVersion {
            #expect(file.formatVersion == expected, "\(label): formatVersion")
        }
        if let expected = e.scope { #expect(file.scope == expected, "\(label): scope") }
        if let expected = e.exportedAt {
            #expect(BackupCoding.string(from: file.exportedAt) == expected,
                    "\(label): exportedAt")
        }
        if let expected = e.summary {
            #expect(file.summary == expected,
                    "\(label): summary — erwartet \(expected), war \(file.summary)")
        }

        if let expectedRange = e.dateRange {
            if let expected = expectedRange {
                let actual = try #require(file.dateRange, "\(label): dateRange fehlt")
                #expect(actual.from == expected.from, "\(label): dateRange.from")
                #expect(actual.to == expected.to, "\(label): dateRange.to")
            } else {
                #expect(file.dateRange == nil, "\(label): dateRange müsste nil sein")
            }
        }

        for (tabelle, anzahl) in e.counts ?? [:] {
            let actual: Int
            switch tabelle {
            case "habits": actual = file.habits.count
            case "tags": actual = file.tags.count
            case "entries": actual = file.entries.count
            case "events": actual = file.events.count
            case "exceptions": actual = file.exceptions.count
            case "dayLogs": actual = file.dayLogs.count
            case "focusRuns": actual = file.focusRuns.count
            case "freezes": actual = file.freezes.count
            default:
                Issue.record("\(label): unbekannte Tabelle \(tabelle)")
                continue
            }
            #expect(actual == anzahl, "\(label): \(tabelle) — erwartet \(anzahl), war \(actual)")
        }

        if let expected = e.problems {
            let probleme = validate(file)
            let actual = probleme.map { ($0.code, $0.isFatal) }
            #expect(actual.map(\.0) == expected.map(\.code), "\(label): problems")
            #expect(actual.map(\.1) == expected.map(\.fatal), "\(label): problems — fatal")
        }
    }
}
