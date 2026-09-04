extension Habit {
    /// Die an diesem Tag gültige Regel: die letzte, deren `effectiveFrom` nicht
    /// in der Zukunft liegt.
    ///
    /// `nil` bedeutet, dass der Tag vor der ersten Regel liegt — dann gab es den
    /// Habit an diesem Tag schlicht noch nicht.
    public func rule(on date: CalendarDate) -> HabitRule? {
        var result: HabitRule?
        for rule in rules where rule.effectiveFrom <= date {
            // `rules` ist aufsteigend sortiert, die letzte passende gewinnt.
            result = rule
        }
        return result
    }

    /// Das an diesem Tag gültige Ziel.
    public func target(on date: CalendarDate) -> Target? {
        rule(on: date)?.target
    }

    /// Ob der Habit an diesem Tag überhaupt zur Debatte steht — ohne Ausnahmen.
    ///
    /// Bei `timesPerWeek` ist das jeder Tag: erledigt werden darf an jedem, die
    /// Bewertung passiert wochenweise.
    public func isScheduled(on date: CalendarDate) -> Bool {
        if let startsOn, date < startsOn { return false }
        if let endsOn, date > endsOn { return false }
        if let archivedOn, date > archivedOn { return false }
        guard let rule = rule(on: date) else { return false }

        switch rule.schedule {
        case .daily:
            return true
        case .weekdays(let days):
            return days.contains(date.weekday)
        case .timesPerWeek:
            return true
        case .everyNDays(let n, let anchor):
            guard n > 0, date >= anchor else { return false }
            return anchor.days(until: date) % n == 0
        }
    }

    /// Ob ein Tag ohne Erfüllung als verpasst gilt.
    ///
    /// Trennt `timesPerWeek` ab: dort ist ein leerer Dienstag kein Versäumnis,
    /// wenn Montag, Mittwoch und Freitag erledigt wurden.
    public func isRequired(on date: CalendarDate) -> Bool {
        guard isScheduled(on: date) else { return false }
        return rule(on: date)?.schedule.requiresSpecificDays ?? false
    }

    /// Ob der Wert eines Tages das damals gültige Ziel erfüllt.
    public func isFulfilled(value: Double, on date: CalendarDate) -> Bool {
        switch kind {
        case .binary:
            return value >= 1
        case .avoid:
            // Kein Eintrag heißt Erfolg — gemeldet werden nur Verstöße.
            return value == 0
        case .quantity:
            guard let target = target(on: date) else { return value > 0 }
            switch target.comparison {
            case .atLeast: return value >= target.value
            case .atMost: return value <= target.value
            }
        }
    }

    /// Fortschritt eines Tages als 0...1 — für den Ring in der Heute-Ansicht.
    public func progress(value: Double, on date: CalendarDate) -> Double {
        switch kind {
        case .binary:
            return value >= 1 ? 1 : 0
        case .avoid:
            return value == 0 ? 1 : 0
        case .quantity:
            guard let target = target(on: date), target.value > 0 else {
                return value > 0 ? 1 : 0
            }
            switch target.comparison {
            case .atLeast:
                return min(1, max(0, value / target.value))
            case .atMost:
                // Beim Limit ist „weniger" besser: voll, solange nichts verbraucht ist.
                return value <= target.value ? 1 : 0
            }
        }
    }
}

extension Schedule {
    /// Wie viele Tage einer Woche erledigt sein müssen. Nur bei `timesPerWeek`
    /// von Null verschieden.
    public var weeklyTarget: Int? {
        if case .timesPerWeek(let n) = self { n } else { nil }
    }
}
