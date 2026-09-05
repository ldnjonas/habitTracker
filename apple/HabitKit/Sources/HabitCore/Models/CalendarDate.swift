import Foundation

/// Ein lokaler Kalendertag ohne Uhrzeit und ohne Zeitzone.
///
/// Bewusst kein `Date`: „Habe ich heute Sport gemacht?" ist eine Kalenderfrage.
/// Zeitstempel führen bei Zeitzonenwechseln und Sommerzeit zu falschen Streaks.
///
/// Die Arithmetik nutzt Howard Hinnants Zivilkalender-Algorithmen statt
/// `Foundation.Calendar` — dadurch ist sie deterministisch, unabhängig von der
/// Systemzeitzone und mechanisch nach TypeScript übersetzbar.
public struct CalendarDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month),
              (1...CalendarDate.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Ohne Gültigkeitsprüfung — nur für Werte, die schon aus der Arithmetik stammen.
    private init(uncheckedYear: Int, month: Int, day: Int) {
        self.year = uncheckedYear
        self.month = month
        self.day = day
    }

    // MARK: - ISO-Darstellung

    /// Erwartet exakt `YYYY-MM-DD`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        let y = String(format: "%04d", year)
        let m = String(format: "%02d", month)
        let d = String(format: "%02d", day)
        return "\(y)-\(m)-\(d)"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = CalendarDate(iso: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Kein gültiges YYYY-MM-DD: \(raw)"))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Zivilkalender-Arithmetik

    /// Tage seit 1970-01-01 (kann negativ sein).
    public var dayNumber: Int {
        CalendarDate.daysFromCivil(year: year, month: month, day: day)
    }

    public init(dayNumber: Int) {
        let (y, m, d) = CalendarDate.civilFromDays(dayNumber)
        self.init(uncheckedYear: y, month: m, day: d)
    }

    public func adding(days: Int) -> CalendarDate {
        CalendarDate(dayNumber: dayNumber + days)
    }

    /// Anzahl Tage von `self` bis `other` (positiv, wenn `other` später liegt).
    public func days(until other: CalendarDate) -> Int {
        other.dayNumber - self.dayNumber
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Alle Tage von `self` bis einschließlich `end`. Leer, wenn `end` davor liegt.
    public func through(_ end: CalendarDate) -> [CalendarDate] {
        guard self <= end else { return [] }
        return (dayNumber...end.dayNumber).map(CalendarDate.init(dayNumber:))
    }

    // MARK: - Wochentage

    public var weekday: Weekday {
        // dayNumber 0 ist der 1970-01-01, ein Donnerstag (ISO 4).
        let iso = ((dayNumber + 3) %% 7) + 1
        return Weekday(rawValue: iso)!
    }

    /// Montag der Woche, in der dieser Tag liegt (ISO-Woche).
    public var weekStart: CalendarDate {
        adding(days: -(weekday.rawValue - 1))
    }

    public var weekEnd: CalendarDate {
        weekStart.adding(days: 6)
    }

    // MARK: - Kalender-Hilfsfunktionen

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    public var monthStart: CalendarDate {
        CalendarDate(uncheckedYear: year, month: month, day: 1)
    }

    public var monthEnd: CalendarDate {
        CalendarDate(uncheckedYear: year, month: month,
                     day: CalendarDate.daysInMonth(year: year, month: month))
    }

    /// Denselben Tag `count` Monate später (oder früher).
    ///
    /// Fällt der Tag im Zielmonat aus, wird auf dessen letzten Tag gekürzt:
    /// vom 31. Januar einen Monat weiter ist der 28. Februar, nicht der 3. März.
    public func addingMonths(_ count: Int) -> CalendarDate {
        let total = year * 12 + (month - 1) + count
        let targetYear = Int((Double(total) / 12).rounded(.down))
        let targetMonth = total - targetYear * 12 + 1
        return CalendarDate(
            uncheckedYear: targetYear, month: targetMonth,
            day: min(day, CalendarDate.daysInMonth(year: targetYear, month: targetMonth)))
    }

    // MARK: - Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms"

    static func daysFromCivil(year y: Int, month m: Int, day d: Int) -> Int {
        let y = y - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                    // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1   // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        let z = z + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097                                 // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)          // [0, 365]
        let mp = (5 * doy + 2) / 153                               // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                       // [1, 31]
        let m = mp + (mp < 10 ? 3 : -9)                            // [1, 12]
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Modulo, das für negative Zahlen ein nicht-negatives Ergebnis liefert.
/// Swifts `%` tut das nicht, und `dayNumber` ist vor 1970 negativ.
infix operator %%: MultiplicationPrecedence
func %% (lhs: Int, rhs: Int) -> Int {
    let r = lhs % rhs
    return r < 0 ? r + rhs : r
}
