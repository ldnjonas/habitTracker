import Foundation
import GRDB
import HabitCore

// HabitCore kennt GRDB nicht — die Brücke liegt bewusst hier, damit die Domäne
// abhängigkeitsfrei bleibt und nach TypeScript portierbar ist.

extension CalendarDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CalendarDate? {
        String.fromDatabaseValue(dbValue).flatMap(CalendarDate.init(iso:))
    }
}

// String-Enums bekommen ihre Konvertierung von GRDB geschenkt.
extension HabitKind: DatabaseValueConvertible {}
extension EntrySource: DatabaseValueConvertible {}
extension ExceptionKind: DatabaseValueConvertible {}
extension TimeOfDay: DatabaseValueConvertible {}
extension Comparison: DatabaseValueConvertible {}
extension FreezeReason: DatabaseValueConvertible {}

/// Aktueller Kalendertag in einer Zeitzone.
///
/// Diese Umrechnung ist bewusst *nicht* in HabitCore: die Domäne soll keine
/// Zeitzone kennen. Hier, an der Grenze zur Außenwelt, ist sie unvermeidlich —
/// und genau einmal vorhanden.
public extension CalendarDate {
    static func today(in timeZone: TimeZone = .current, now: Date = Date()) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return CalendarDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Der lokale Kalendertag, in den dieser Zeitstempel fällt.
    init(_ date: Date, in timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Ein Zeitstempel für diesen Tag — für `DatePicker` und ähnliche Steuerungen.
    ///
    /// Bewusst **12 Uhr** und nicht Mitternacht: bei einer Zeitzonen- oder
    /// Sommerzeitverschiebung kippt Mitternacht auf den Vortag, Mittag nicht.
    func asDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: 12)) ?? Date()
    }
}

/// JSON-Kodierung für die wenigen Felder, die als Text in einer Spalte liegen
/// (Zeitplan-Nutzlast, HealthKit-Verknüpfung).
enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // stabile Ausgabe für Diffs und Tests
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}
