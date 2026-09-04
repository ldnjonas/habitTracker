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
