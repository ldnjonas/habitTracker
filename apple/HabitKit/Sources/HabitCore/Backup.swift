import Foundation

/// Eine Sicherungsdatei — der vollständige Bestand oder einzelne Habits.
///
/// Bewusst JSON aus genau den Domänentypen, die auch die API überträgt: die
/// Datei ist dadurch lesbar, diffbar und vom späteren Node-Server ohne
/// Übersetzungsschicht verwertbar. Ein SQLite-Abzug wäre einfacher zu
/// erzeugen, aber an Apple gebunden und für einen Menschen undurchsichtig.
///
/// **Enthalten sind nur lebende Zeilen.** Grabsteine (`deletedAt`) sind eine
/// Angelegenheit des Sync-Protokolls, nicht der Sicherung — eine Sicherung
/// beschreibt den Bestand, nicht seine Geschichte.
public struct BackupFile: Codable, Hashable, Sendable {
    /// Erhöht sich, sobald sich das Format so ändert, dass ältere Leser
    /// scheitern würden. Der Import weist unbekannte Versionen ab, statt zu raten.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    /// Wer die Datei geschrieben hat, z. B. `"HabitTracker/1.0 (macOS)"`.
    public var generator: String
    public var scope: Scope

    public var habits: [Habit]
    public var tags: [Tag]
    public var entries: [Entry]
    public var events: [EntryEvent]
    public var exceptions: [DayException]
    public var dayLogs: [DayLog]
    public var focusRuns: [FocusRun]
    public var freezes: [FreezeEntry]

    public enum Scope: String, Codable, Sendable, Hashable {
        /// Der gesamte Bestand.
        case full
        /// Eine Auswahl einzelner Habits samt ihrem Verlauf.
        case habits
    }

    public init(
        formatVersion: Int = BackupFile.currentFormatVersion,
        exportedAt: Date = Date(),
        generator: String,
        scope: Scope,
        habits: [Habit] = [],
        tags: [Tag] = [],
        entries: [Entry] = [],
        events: [EntryEvent] = [],
        exceptions: [DayException] = [],
        dayLogs: [DayLog] = [],
        focusRuns: [FocusRun] = [],
        freezes: [FreezeEntry] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.generator = generator
        self.scope = scope
        self.habits = habits
        self.tags = tags
        self.entries = entries
        self.events = events
        self.exceptions = exceptions
        self.dayLogs = dayLogs
        self.focusRuns = focusRuns
        self.freezes = freezes
    }

    /// Von Hand, weil die synthetisierte Fassung fehlende Schlüssel als Fehler
    /// wertet und Vorgabewerte ignoriert.
    ///
    /// Eine Sicherung, die vor einer neuen Tabelle geschrieben wurde, muss
    /// weiter lesbar bleiben — sonst wäre jede Erweiterung ein Bruch. Aus
    /// demselben Grund darf eine fremd erzeugte Datei leere Listen weglassen.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        generator = try c.decodeIfPresent(String.self, forKey: .generator) ?? "unbekannt"
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .full
        habits = try c.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        events = try c.decodeIfPresent([EntryEvent].self, forKey: .events) ?? []
        exceptions = try c.decodeIfPresent([DayException].self, forKey: .exceptions) ?? []
        dayLogs = try c.decodeIfPresent([DayLog].self, forKey: .dayLogs) ?? []
        focusRuns = try c.decodeIfPresent([FocusRun].self, forKey: .focusRuns) ?? []
        freezes = try c.decodeIfPresent([FreezeEntry].self, forKey: .freezes) ?? []
    }

    /// Zusammenfassung für die Bestätigung vor dem Import.
    public var summary: String {
        var parts: [String] = []
        if !habits.isEmpty { parts.append("\(habits.count) Habits") }
        if !tags.isEmpty { parts.append("\(tags.count) Tags") }
        if !entries.isEmpty { parts.append("\(entries.count) Einträge") }
        if !events.isEmpty { parts.append("\(events.count) Zeitstempel") }
        if !exceptions.isEmpty { parts.append("\(exceptions.count) Ausnahmen") }
        if !dayLogs.isEmpty { parts.append("\(dayLogs.count) Journaltage") }
        if !focusRuns.isEmpty { parts.append("\(focusRuns.count) Fokus-Läufe") }
        if !freezes.isEmpty { parts.append("\(freezes.count) Freeze-Buchungen") }
        return parts.isEmpty ? "leer" : parts.joined(separator: " · ")
    }

    /// Früheste und späteste Datumsangabe über alle Datensätze.
    public var dateRange: (from: CalendarDate, to: CalendarDate)? {
        let dates = entries.map(\.date) + events.map(\.date)
            + exceptions.map(\.date) + dayLogs.map(\.date)
            + focusRuns.map(\.startsOn) + focusRuns.map(\.endsOn)
        guard let from = dates.min(), let to = dates.max() else { return nil }
        return (from, to)
    }
}

// MARK: - Kodierung

/// Die Kodierung ist Teil des Dateiformats, nicht Geschmackssache — der
/// Node-Server muss dieselben Dateien schreiben und lesen können.
public enum BackupCoding {
    /// ISO-8601 **mit Millisekunden**.
    ///
    /// Die Bruchteile sind nicht Kosmetik: `updatedAt` entscheidet beim
    /// Zusammenführen, welche Version gewinnt. Auf Sekunden gerundet wären
    /// zwei Änderungen innerhalb derselben Sekunde nicht mehr unterscheidbar.
    /// `Date.toISOString()` in JavaScript erzeugt exakt dieses Format.
    static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// Für Dateien aus anderen Werkzeugen, die keine Bruchteile schreiben.
    static let styleWithoutFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Zeitstempel als ISO-8601 mit exakt drei Nachkommastellen.
    ///
    /// Der Bruchteil wird bewusst selbst aus ganzzahligen Millisekunden gesetzt,
    /// statt `ISO8601FormatStyle` mit `includingFractionalSeconds` zu überlassen:
    /// die schneidet ab, statt zu runden. `…:00.123Z` käme als `…:00.122Z` heraus
    /// und verlöre bei jeder Export-Runde eine weitere Millisekunde — die Datei
    /// wäre nie zweimal dieselbe, obwohl sich nichts geändert hat.
    static func string(from date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        return String(styleWithoutFraction.format(Date(timeIntervalSince1970: seconds)).dropLast())
            + String(format: ".%03dZ", fraction)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sortierte Schlüssel und Einrückung: eine Sicherung soll sich in Git
        // oder einem Diff-Werkzeug sinnvoll vergleichen lassen.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? style.parse(raw) { return date }
            if let date = try? styleWithoutFraction.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Kein ISO-8601-Zeitstempel: \(raw)"))
        }
        return decoder
    }

    public static func encode(_ file: BackupFile) throws -> Data {
        try encoder().encode(file)
    }

    public static func decode(_ data: Data) throws -> BackupFile {
        try decoder().decode(BackupFile.self, from: data)
    }
}

// MARK: - Prüfung

/// Was an einer Sicherungsdatei nicht stimmt.
///
/// Getrennt nach „Import unmöglich" und „Import möglich, aber erwähnenswert" —
/// eine Wiederherstellung soll nicht an einer Kleinigkeit scheitern, aber auch
/// nichts stillschweigend verschlucken.
public enum BackupProblem: Hashable, Sendable, CustomStringConvertible {
    case unsupportedVersion(found: Int, supported: Int)
    case habitWithoutRules(name: String)
    case duplicateHabitId(UUID)
    case duplicateEntry(habitId: UUID, date: CalendarDate)
    case orphanedRows(table: String, count: Int)

    /// Ob dieses Problem den Import verhindert.
    public var isFatal: Bool {
        switch self {
        case .unsupportedVersion, .habitWithoutRules, .duplicateHabitId: true
        case .duplicateEntry, .orphanedRows: false
        }
    }

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            "Dateiformat \(found) ist neuer als unterstützt (\(supported)) — bitte die App aktualisieren"
        case .habitWithoutRules(let name):
            "Habit „\(name)“ hat keinen Zeitplan"
        case .duplicateHabitId(let id):
            "Habit \(id) kommt mehrfach vor"
        case .duplicateEntry(let habitId, let date):
            "Mehrere Einträge für Habit \(habitId) am \(date) — der letzte gewinnt"
        case .orphanedRows(let table, let count):
            "\(count) Zeile(n) in \(table) verweisen auf einen Habit, der weder in der Datei noch in der Datenbank steht — sie werden übersprungen"
        }
    }
}

/// Strukturprüfung ohne Datenbankzugriff.
///
/// Ob referenzierte Habits *existieren*, kann erst der Store beurteilen — er
/// kennt den vorhandenen Bestand. Hier steht nur, was die Datei aus sich heraus
/// widerlegt.
public func validate(_ file: BackupFile) -> [BackupProblem] {
    var problems: [BackupProblem] = []

    if file.formatVersion > BackupFile.currentFormatVersion {
        problems.append(.unsupportedVersion(found: file.formatVersion,
                                            supported: BackupFile.currentFormatVersion))
    }

    var seenHabits: Set<UUID> = []
    for habit in file.habits {
        if !seenHabits.insert(habit.id).inserted {
            problems.append(.duplicateHabitId(habit.id))
        }
        if habit.rules.isEmpty {
            problems.append(.habitWithoutRules(name: habit.name))
        }
    }

    // Der natürliche Schlüssel muss eindeutig sein, sonst ist unklar, welcher
    // Tageswert gilt.
    var seenEntries: Set<[String]> = []
    for entry in file.entries {
        let key = [entry.habitId.uuidString, entry.date.description]
        if !seenEntries.insert(key).inserted {
            problems.append(.duplicateEntry(habitId: entry.habitId, date: entry.date))
        }
    }

    return problems
}

// MARK: - Import

/// Wie eine Sicherung eingespielt wird.
public enum ImportMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Zusammenführen: Bekanntes wird aktualisiert, wenn die Datei neuer ist,
    /// Unbekanntes angelegt. Nichts wird gelöscht.
    ///
    /// Das ist die Betriebsart für „einen einzelnen Habit dazuholen" und
    /// dieselbe Regel, nach der später auch der Sync entscheidet.
    case merge
    /// Ersetzen: Der bisherige Bestand wird verworfen und durch die Datei
    /// ersetzt. Für die Wiederherstellung nach einer Neuinstallation.
    case replace

    public var label: String {
        switch self {
        case .merge: "Zusammenführen"
        case .replace: "Ersetzen"
        }
    }

    public var explanation: String {
        switch self {
        case .merge:
            "Vorhandenes wird nur überschrieben, wenn die Datei neuer ist. Nichts geht verloren."
        case .replace:
            "Der gesamte bisherige Bestand wird gelöscht und durch die Datei ersetzt."
        }
    }
}

/// Was ein Import tatsächlich getan hat.
public struct ImportReport: Hashable, Sendable {
    public struct Counts: Hashable, Sendable {
        public var inserted = 0
        public var updated = 0
        /// Übersprungen, weil der vorhandene Datensatz neuer war.
        public var skipped = 0

        public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0) {
            self.inserted = inserted
            self.updated = updated
            self.skipped = skipped
        }

        public var total: Int { inserted + updated + skipped }
    }

    public var mode: ImportMode
    public var habits = Counts()
    public var tags = Counts()
    public var entries = Counts()
    public var events = Counts()
    public var exceptions = Counts()
    public var dayLogs = Counts()
    public var focusRuns = Counts()
    public var freezes = Counts()
    /// Nicht fatale Auffälligkeiten, die dem Nutzer angezeigt werden sollten.
    public var problems: [BackupProblem] = []

    public init(mode: ImportMode) { self.mode = mode }

    private var allCounts: [Counts] {
        [habits, tags, entries, events, exceptions, dayLogs, focusRuns, freezes]
    }

    public var totalInserted: Int {
        allCounts.reduce(0) { $0 + $1.inserted }
    }
    public var totalUpdated: Int {
        allCounts.reduce(0) { $0 + $1.updated }
    }
    public var totalSkipped: Int {
        allCounts.reduce(0) { $0 + $1.skipped }
    }

    public var summary: String {
        var parts: [String] = []
        if totalInserted > 0 { parts.append("\(totalInserted) neu") }
        if totalUpdated > 0 { parts.append("\(totalUpdated) aktualisiert") }
        if totalSkipped > 0 { parts.append("\(totalSkipped) unverändert") }
        return parts.isEmpty ? "Nichts zu tun" : parts.joined(separator: " · ")
    }
}

public enum BackupError: Error, CustomStringConvertible {
    case invalidFile([BackupProblem])

    public var description: String {
        switch self {
        case .invalidFile(let problems):
            "Die Datei kann nicht eingespielt werden:\n"
                + problems.map { "• \($0.description)" }.joined(separator: "\n")
        }
    }
}
