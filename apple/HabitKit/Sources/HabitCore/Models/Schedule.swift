/// Wann ein Habit fällig ist.
public enum Schedule: Hashable, Sendable {
    /// Jeden Tag.
    case daily
    /// An festen Wochentagen.
    case weekdays(Set<Weekday>)
    /// n-mal pro Woche, der Tag ist egal. Wird wochenweise ausgewertet.
    case timesPerWeek(Int)
    /// Alle n Tage, gerechnet ab `anchor`.
    case everyNDays(n: Int, anchor: CalendarDate)

    /// Ob ein einzelner Tag verpflichtend ist.
    ///
    /// Bei `timesPerWeek` ist er das nicht: der Habit darf an jedem Tag erledigt
    /// werden, deshalb ist ein Tag ohne Eintrag dort kein verpasster Tag, sondern
    /// gar kein geplanter. Bewertet wird die Woche, nicht der Tag.
    public var requiresSpecificDays: Bool {
        if case .timesPerWeek = self { false } else { true }
    }
}

extension Schedule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, days, n, anchor }
    private enum Kind: String, Codable { case daily, weekdays, timesPerWeek, everyNDays }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .daily:
            self = .daily
        case .weekdays:
            self = .weekdays(Set(try c.decode([Weekday].self, forKey: .days)))
        case .timesPerWeek:
            self = .timesPerWeek(try c.decode(Int.self, forKey: .n))
        case .everyNDays:
            self = .everyNDays(n: try c.decode(Int.self, forKey: .n),
                               anchor: try c.decode(CalendarDate.self, forKey: .anchor))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily:
            try c.encode(Kind.daily, forKey: .kind)
        case .weekdays(let days):
            try c.encode(Kind.weekdays, forKey: .kind)
            try c.encode(days.sorted(), forKey: .days)
        case .timesPerWeek(let n):
            try c.encode(Kind.timesPerWeek, forKey: .kind)
            try c.encode(n, forKey: .n)
        case .everyNDays(let n, let anchor):
            try c.encode(Kind.everyNDays, forKey: .kind)
            try c.encode(n, forKey: .n)
            try c.encode(anchor, forKey: .anchor)
        }
    }
}

/// Wie ein Zielwert zu lesen ist.
public enum Comparison: String, Codable, Sendable, Hashable {
    /// „mindestens" — 2 Liter Wasser trinken.
    case atLeast
    /// „höchstens" — maximal 30 Minuten Social Media.
    case atMost
}

public struct Target: Codable, Hashable, Sendable {
    public var value: Double
    public var unit: String
    public var comparison: Comparison

    public init(value: Double, unit: String, comparison: Comparison = .atLeast) {
        self.value = value
        self.unit = unit
        self.comparison = comparison
    }
}

/// Zeitplan und Ziel gelten ab einem Datum.
///
/// Vergangene Tage werden mit der damals gültigen Regel bewertet. Ohne diese
/// Versionierung würde eine Zielerhöhung von 2 L auf 3 L rückwirkend alle
/// erfüllten Tage als verfehlt erscheinen lassen.
public struct HabitRule: Codable, Hashable, Sendable {
    public var effectiveFrom: CalendarDate
    public var schedule: Schedule
    public var target: Target?

    public init(effectiveFrom: CalendarDate, schedule: Schedule, target: Target? = nil) {
        self.effectiveFrom = effectiveFrom
        self.schedule = schedule
        self.target = target
    }
}
