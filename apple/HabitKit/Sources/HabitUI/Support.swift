import SwiftUI
import HabitCore
import UniformTypeIdentifiers
/// Eine Sicherungsdatei für `.fileExporter` und `.fileImporter`.
///
/// In `HabitUI` und nicht im App-Target: Mac und iPhone exportieren dieselbe
/// Datei, und zwei Kopien wären zwei Gelegenheiten, sie verschieden zu
/// schreiben.
public struct BackupDocument: FileDocument {
    public static let readableContentTypes = [UTType.json]

    public var data: Data

    public init(data: Data) { self.data = data }

    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


/// Damit `.sheet(item:)` einen Tag tragen kann.
extension CalendarDate: Identifiable {
    public var id: String { description }
}

// MARK: - Dauern

/// Minuten als „45 min“, „1 h 25 min“, „2 h“.
///
/// Nicht als Dezimalzahl: „1,42 h“ muss man im Kopf umrechnen, bevor man weiß,
/// ob man sein Ziel erreicht hat.
public func formatMinutes(_ minutes: Double) -> String {
    let gesamt = Int(minutes.rounded())
    let stunden = gesamt / 60
    let rest = gesamt % 60
    if stunden == 0 { return "\(rest) min" }
    if rest == 0 { return "\(stunden) h" }
    return "\(stunden) h \(rest) min"
}

/// Uhrzeit ohne Datum, für Sitzungszeilen.
public func formatClock(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

// MARK: - Farben

public extension Color {
    /// Farbe aus `#RRGGBB`. Fällt bei Unsinn auf Grau zurück, statt zu stürzen —
    /// eine kaputte Farbe darf die Liste nicht unbenutzbar machen.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Darstellung des Tagesstatus

public extension DayStatus {
    /// Deckkraft der Habit-Farbe in Heatmap und Kalender.
    ///
    /// Ein eingefrorener Tag bekommt bewusst eine eigene, schwache Färbung statt
    /// der vollen: der Streak läuft weiter, erledigt war er trotzdem nicht.
    func fillOpacity(progress: Double = 0) -> Double {
        switch self {
        case .completed: 1.0
        case .partial(let value): value > 0 ? 0.25 + value * 0.5 : 0.0
        case .excepted(.frozen): 0.3
        case .missed, .excepted, .notScheduled, .future: 0.0
        }
    }

    var symbolName: String? {
        switch self {
        case .completed: "checkmark"
        case .excepted(.frozen): "snowflake"
        case .excepted(.paused): "pause"
        case .excepted(.skipped): "minus"
        case .missed, .partial, .notScheduled, .future: nil
        }
    }

    var label: String {
        switch self {
        case .completed: "Erledigt"
        case .partial: "Offen"
        case .missed: "Verpasst"
        case .excepted(.frozen): "Eingefroren"
        case .excepted(.paused): "Pausiert"
        case .excepted(.skipped): "Übersprungen"
        case .notScheduled: "Nicht geplant"
        case .future: "Noch nicht"
        }
    }
}

public extension ExceptionKind {
    var label: String {
        switch self {
        case .frozen: "Eingefroren"
        case .paused: "Urlaub"
        case .skipped: "Ruhetag"
        }
    }
}

// MARK: - Beschriftungen

public extension Weekday {
    /// Zweibuchstabige Abkürzung für die Wochentagsleiste.
    var shortLabel: String {
        switch self {
        case .monday: "Mo"
        case .tuesday: "Di"
        case .wednesday: "Mi"
        case .thursday: "Do"
        case .friday: "Fr"
        case .saturday: "Sa"
        case .sunday: "So"
        }
    }
}

public extension TimeOfDay {
    var label: String {
        switch self {
        case .morning: "Morgens"
        case .afternoon: "Mittags"
        case .evening: "Abends"
        case .night: "Nachts"
        }
    }

    var symbolName: String {
        switch self {
        case .morning: "sunrise"
        case .afternoon: "sun.max"
        case .evening: "sunset"
        case .night: "moon.stars"
        }
    }
}

public extension Schedule {
    var label: String {
        switch self {
        case .daily:
            "Täglich"
        case .weekdays(let days):
            days.count == 7 ? "Täglich"
                : days.sorted().map(\.shortLabel).joined(separator: ", ")
        case .timesPerWeek(let n):
            "\(n)× pro Woche"
        case .everyNDays(let n, _):
            n == 1 ? "Täglich" : "Alle \(n) Tage"
        }
    }
}

public extension CalendarDate {
    /// „4. September 2026"
    var longLabel: String {
        "\(day). \(CalendarDate.monthNames[month - 1]) \(year)"
    }

    /// „4. Sep."
    var shortLabel: String {
        "\(day). \(CalendarDate.monthNames[month - 1].prefix(3))."
    }

    static let monthNames = [
        "Januar", "Februar", "März", "April", "Mai", "Juni",
        "Juli", "August", "September", "Oktober", "November", "Dezember",
    ]
}

/// Prozentanzeige ohne Nachkommastellen — „83 %" statt „82,8 %".
public func percent(_ value: Double?) -> String {
    guard let value else { return "–" }
    return "\(Int((value * 100).rounded())) %"
}

/// Zahl ohne unnötige Nachkommastellen: 2 statt 2,0, aber 2,5 bleibt 2,5.
public func number(_ value: Double) -> String {
    value == value.rounded()
        ? String(Int(value))
        : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
}
