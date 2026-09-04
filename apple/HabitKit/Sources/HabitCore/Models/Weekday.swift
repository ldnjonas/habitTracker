/// ISO-8601-Wochentag: Montag ist 1, Sonntag ist 7.
public enum Weekday: Int, Codable, CaseIterable, Sendable, Comparable, Hashable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var isWeekend: Bool { self == .saturday || self == .sunday }
}

/// Grober Tagesabschnitt. Sortiert die Heute-Ansicht und ist später die
/// Grundlage dafür, wann ein Reminder feuert.
public enum TimeOfDay: String, Codable, CaseIterable, Sendable, Comparable {
    case morning, afternoon, evening, night

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    private var sortIndex: Int {
        switch self {
        case .morning: 0
        case .afternoon: 1
        case .evening: 2
        case .night: 3
        }
    }
}
