import Foundation

/// Was in einem Zeitraum zusammengekommen ist.
///
/// Beantwortet „wie viel habe ich diese Woche gemacht?" — eine andere Frage als
/// der Streak („wie lange schon?") und als die Quote („wie verlässlich?").
/// Bei einer Mengen- oder Zeit-Erfassung ist es oft die einzige, die zählt:
/// ob die fünf Stunden auf drei oder fünf Tage fielen, ist gleichgültig.
public struct PeriodTotal: Hashable, Sendable {
    public let from: CalendarDate
    public let to: CalendarDate
    /// Summe in der Einheit des Habits — bei Zeiterfassung Minuten.
    public let total: Double
    public let byDay: [CalendarDate: Double]
    /// Schlüssel ist der Montag der jeweiligen Woche.
    public let byWeek: [CalendarDate: Double]
    /// Tage mit einem Wert größer als null.
    public let activeDays: Int
    /// Zahl der Sitzungen, falls der Habit welche führt.
    public let sessionCount: Int

    public init(
        from: CalendarDate, to: CalendarDate, total: Double,
        byDay: [CalendarDate: Double], byWeek: [CalendarDate: Double],
        activeDays: Int, sessionCount: Int
    ) {
        self.from = from
        self.to = to
        self.total = total
        self.byDay = byDay
        self.byWeek = byWeek
        self.activeDays = activeDays
        self.sessionCount = sessionCount
    }

    public var dayCount: Int { from.days(until: to) + 1 }

    /// Schnitt über die Tage **mit** Aktivität, nicht über alle.
    ///
    /// Ein Schnitt über alle Tage beantwortet nichts: er sinkt, sobald man den
    /// Zeitraum vergrößert, ohne dass sich am Verhalten etwas geändert hat.
    public var averagePerActiveDay: Double? {
        activeDays > 0 ? total / Double(activeDays) : nil
    }
}

/// Summiert die Tageswerte eines Habits über einen Zeitraum.
///
/// Gelesen wird `Entry.value` und nicht die Sitzungen: der Store hält
/// `entry.value == Σ events` ohnehin aufrecht, und nur so zählen auch Habits
/// mit, die ihre Werte direkt eintragen statt über Sitzungen.
public func periodTotal(
    for habit: Habit,
    entries: [Entry],
    events: [EntryEvent] = [],
    from: CalendarDate,
    to: CalendarDate
) -> PeriodTotal {
    var byDay: [CalendarDate: Double] = [:]
    for entry in entries
    where entry.deletedAt == nil && entry.habitId == habit.id
        && entry.date >= from && entry.date <= to {
        byDay[entry.date, default: 0] += entry.value
    }

    var byWeek: [CalendarDate: Double] = [:]
    for (date, value) in byDay {
        byWeek[date.weekStart, default: 0] += value
    }

    let relevanteSitzungen = events.filter {
        $0.deletedAt == nil && $0.habitId == habit.id && $0.date >= from && $0.date <= to
    }

    return PeriodTotal(
        from: from, to: to,
        total: byDay.values.reduce(0, +),
        byDay: byDay,
        byWeek: byWeek,
        activeDays: byDay.values.filter { $0 > 0 }.count,
        sessionCount: relevanteSitzungen.count)
}

/// Die Sitzungen eines Tages, nach Startzeit sortiert.
public func sessions(
    of habit: Habit,
    on date: CalendarDate,
    events: [EntryEvent]
) -> [EntryEvent] {
    events
        .filter { $0.deletedAt == nil && $0.habitId == habit.id && $0.date == date }
        .sorted { $0.at < $1.at }
}
